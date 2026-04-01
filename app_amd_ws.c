/*
 * Asterisk -- An open source telephony toolkit.
 *
 * Copyright (C) 2024
 *
 * See http://www.asterisk.org for more information about
 * the Asterisk project. Please do not directly contact
 * any of the maintainers of this project for assistance;
 * the project provides a web site, mailing lists and IRC
 * channels for your use.
 *
 * This program is free software, distributed under the terms of
 * the GNU General Public License Version 2. See the LICENSE file
 * at the top of the source tree.
 */

/*! \file
 *
 * \brief Answering machine detection via WebSocket
 *
 * \ingroup applications
 */

/*** MODULEINFO
	<support_level>extended</support_level>
 ***/

#include "asterisk.h"

#include "asterisk/module.h"
#include "asterisk/lock.h"
#include "asterisk/channel.h"
#include "asterisk/pbx.h"
#include "asterisk/app.h"
#include "asterisk/format_cache.h"

/* Undef Asterisk's pthread type overrides before including libwebsockets */
#undef pthread_mutex_t
#undef pthread_cond_t

#include <libwebsockets.h>

/*** DOCUMENTATION
	<application name="AMD_WS" language="en_US">
		<synopsis>
			Attempt to detect answering machines via external WebSocket server.
		</synopsis>
		<syntax>
			<parameter name="host" required="false">
				<para>WebSocket server hostname or IP (default: 127.0.0.1)</para>
			</parameter>
			<parameter name="port" required="false">
				<para>WebSocket server port (default: 8080)</para>
			</parameter>
			<parameter name="vid" required="false">
				<para>VID identifier sent to server (default: caller ID name)</para>
			</parameter>
			<parameter name="timeout" required="false">
				<para>Maximum detection time in milliseconds (default: 5000)</para>
			</parameter>
		</syntax>
		<description>
			<para>This application connects to an external AMD WebSocket server,
			streams audio, and receives detection results.</para>
			<para>This application sets the following channel variables:</para>
			<variablelist>
				<variable name="AMDSTATUS">
					<para>This is the status of the answering machine detection</para>
					<value name="MACHINE" />
					<value name="HUMAN" />
					<value name="NOTSURE" />
					<value name="HANGUP" />
				</variable>
				<variable name="AMDCAUSE">
					<para>Raw response from server or error cause</para>
				</variable>
			</variablelist>
		</description>
	</application>
 ***/

static const char app[] = "AMD_WS";

#define SAMPLE_RATE 8000
#define FRAME_MS 20
#define MAX_AUDIO_BUFFER (SAMPLE_RATE * 2 * 5)  /* 5 seconds max buffer */

/* Send times in milliseconds - matching amd.py */
static int send_times[] = {500, 1000, 1500, 2000, 3000, 4000};
#define NUM_SEND_TIMES 6
#define FALLBACK_CHUNK_SIZE 8000

/* Default values */
static char dfltHost[256] = "127.0.0.1";
static int dfltPort = 8080;
static int dfltTimeout = 5000;

/* Track active sessions to prevent crash on unload */
static int active_sessions = 0;
static ast_mutex_t session_lock;

struct amd_ws_session {
	struct lws *wsi;
	struct lws_context *context;
	unsigned char audio_buffer[LWS_PRE + MAX_AUDIO_BUFFER];
	unsigned char config_buffer[LWS_PRE + 512];
	int buffer_pos;
	int config_len;
	char result[256];
	int got_result;
	int connected;
	int config_sent;
	int connection_error;
	char error_msg[256];
	int chunk_count;
	int send_time_index;
};

static int ws_callback(struct lws *wsi, enum lws_callback_reasons reason,
                       void *user, void *in, size_t len)
{
	struct amd_ws_session *session;
	struct lws_context *ctx;

	ctx = lws_get_context(wsi);
	if (!ctx) {
		ast_log(LOG_ERROR, "AMD_WS: ws_callback - no context!\n");
		return -1;
	}

	session = (struct amd_ws_session *)lws_context_user(ctx);
	if (!session) {
		ast_log(LOG_ERROR, "AMD_WS: ws_callback - no session!\n");
		return -1;
	}

	switch (reason) {
	case LWS_CALLBACK_CLIENT_ESTABLISHED:
		ast_verb(3, "AMD_WS: WebSocket connection established\n");
		ast_debug(1, "AMD_WS: LWS_CALLBACK_CLIENT_ESTABLISHED\n");
		session->connected = 1;
		session->connection_error = 0;
		/* Request write callback to send config */
		lws_callback_on_writable(wsi);
		break;

	case LWS_CALLBACK_CLIENT_RECEIVE:
		ast_debug(1, "AMD_WS: LWS_CALLBACK_CLIENT_RECEIVE len=%zu\n", len);
		if (len == 0 || (in && len == 1 && ((char *)in)[0] == '\0')) {
			/* Empty response = acknowledgment, keep sending audio */
			ast_debug(2, "AMD_WS: Received empty ack, continuing...\n");
		} else if (in && len > 0 && len < sizeof(session->result)) {
			memcpy(session->result, in, len);
			session->result[len] = '\0';
			ast_verb(3, "AMD_WS: Received response: [%s]\n", session->result);
			ast_debug(1, "AMD_WS: Raw response: [%s]\n", session->result);
			/* Check if we got a definitive result */
			if (strstr(session->result, "HUMAN") ||
			    strstr(session->result, "MACHINE") ||
			    strstr(session->result, "AMD")) {
				ast_verb(3, "AMD_WS: Got definitive result\n");
				session->got_result = 1;
			}
		}
		break;

	case LWS_CALLBACK_CLIENT_WRITEABLE:
		ast_debug(1, "AMD_WS: LWS_CALLBACK_CLIENT_WRITEABLE config_sent=%d buffer_pos=%d\n",
			session->config_sent, session->buffer_pos);
		/* First send config, then audio */
		if (!session->config_sent && session->config_len > 0) {
			int n;
			ast_verb(3, "AMD_WS: Sending config JSON (%d bytes)\n", session->config_len);
			ast_debug(1, "AMD_WS: Config: %.*s\n", session->config_len,
				(char *)&session->config_buffer[LWS_PRE]);
			n = lws_write(wsi, &session->config_buffer[LWS_PRE],
				session->config_len, LWS_WRITE_TEXT);
			if (n < 0) {
				ast_log(LOG_ERROR, "AMD_WS: Failed to write config, n=%d\n", n);
				return -1;
			}
			ast_debug(1, "AMD_WS: Config sent, wrote %d bytes\n", n);
			session->config_sent = 1;
		} else if (session->buffer_pos > 0) {
			int n;
			session->chunk_count++;
			ast_verb(3, "AMD_WS: SENDING CHUNK #%d size=%d bytes\n",
				session->chunk_count, session->buffer_pos);
			n = lws_write(wsi, &session->audio_buffer[LWS_PRE],
				session->buffer_pos, LWS_WRITE_BINARY);
			if (n < 0) {
				ast_log(LOG_ERROR, "AMD_WS: Failed to write audio chunk #%d, n=%d\n",
					session->chunk_count, n);
				return -1;
			}
			ast_verb(3, "AMD_WS: SENT CHUNK #%d complete, wrote %d bytes\n",
				session->chunk_count, n);
			session->buffer_pos = 0;
		}
		break;

	case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
		ast_log(LOG_ERROR, "AMD_WS: Connection error: %s\n",
			in ? (char *)in : "unknown");
		ast_debug(1, "AMD_WS: LWS_CALLBACK_CLIENT_CONNECTION_ERROR\n");
		session->connected = 0;
		session->connection_error = 1;
		if (in && len < sizeof(session->error_msg)) {
			ast_copy_string(session->error_msg, (char *)in, sizeof(session->error_msg));
		} else {
			ast_copy_string(session->error_msg, "CONNECTION_ERROR", sizeof(session->error_msg));
		}
		break;

	case LWS_CALLBACK_CLOSED:
	case LWS_CALLBACK_CLIENT_CLOSED:
		ast_verb(3, "AMD_WS: Connection closed\n");
		ast_debug(1, "AMD_WS: LWS_CALLBACK_CLIENT_CLOSED\n");
		session->connected = 0;
		break;

	case LWS_CALLBACK_WSI_DESTROY:
		ast_debug(1, "AMD_WS: LWS_CALLBACK_WSI_DESTROY\n");
		break;

	default:
		ast_debug(3, "AMD_WS: Unhandled callback reason: %d\n", reason);
		break;
	}
	return 0;
}

static const struct lws_protocols protocols[] = {
	{ "amd", ws_callback, 0, MAX_AUDIO_BUFFER + LWS_PRE },
	{ NULL, NULL, 0, 0 }
};

static void amd_ws_detect(struct ast_channel *chan, const char *data)
{
	char *parse;
	struct ast_frame *f = NULL;
	struct amd_ws_session session;
	struct lws_context_creation_info ctx_info;
	struct lws_client_connect_info conn_info;
	RAII_VAR(struct ast_format *, readFormat, NULL, ao2_cleanup);
	int timeout_ms = dfltTimeout;
	int total_ms = 0;
	int iTotalTime = 0;
	int audioFrameCount = 0;
	char ws_host[256];
	int ws_port = dfltPort;
	char vid[256] = "";
	char config_json[512];
	char amdStatus[256] = "";
	char amdCause[256] = "";
	int res = 0;
	int i;

	/* Track this session */
	ast_mutex_lock(&session_lock);
	active_sessions++;
	ast_mutex_unlock(&session_lock);

	AST_DECLARE_APP_ARGS(args,
		AST_APP_ARG(host);
		AST_APP_ARG(port);
		AST_APP_ARG(vid);
		AST_APP_ARG(timeout);
	);

	ast_verb(3, "AMD_WS: %s %s %s (Fmt: %s)\n", ast_channel_name(chan),
		S_COR(ast_channel_caller(chan)->ani.number.valid, ast_channel_caller(chan)->ani.number.str, "(N/A)"),
		S_COR(ast_channel_redirecting(chan)->from.number.valid, ast_channel_redirecting(chan)->from.number.str, "(N/A)"),
		ast_format_get_name(ast_channel_readformat(chan)));

	/* Initialize session */
	memset(&session, 0, sizeof(session));
	memset(&ctx_info, 0, sizeof(ctx_info));
	memset(&conn_info, 0, sizeof(conn_info));

	/* Set defaults */
	ast_copy_string(ws_host, dfltHost, sizeof(ws_host));

	/* Parse arguments */
	if (!ast_strlen_zero(data)) {
		parse = ast_strdupa(data);
		AST_STANDARD_APP_ARGS(args, parse);

		if (!ast_strlen_zero(args.host)) {
			ast_copy_string(ws_host, args.host, sizeof(ws_host));
		}
		if (!ast_strlen_zero(args.port)) {
			ws_port = atoi(args.port);
		}
		if (!ast_strlen_zero(args.vid)) {
			ast_copy_string(vid, args.vid, sizeof(vid));
		}
		if (!ast_strlen_zero(args.timeout)) {
			timeout_ms = atoi(args.timeout);
		}
	}

	/* If VID not provided, try to get caller ID name */
	if (ast_strlen_zero(vid)) {
		const char *cid_name = NULL;
		ast_channel_lock(chan);
		if (ast_channel_caller(chan)->id.name.valid) {
			cid_name = ast_channel_caller(chan)->id.name.str;
		}
		if (!ast_strlen_zero(cid_name)) {
			ast_copy_string(vid, cid_name, sizeof(vid));
		} else {
			ast_copy_string(vid, "Unknown", sizeof(vid));
		}
		ast_channel_unlock(chan);
	}

	ast_verb(3, "AMD_WS: Parameters - host [%s] port [%d] vid [%s] timeout [%d]\n",
		ws_host, ws_port, vid, timeout_ms);
	ast_debug(1, "AMD_WS: Starting detection for channel [%s]\n", ast_channel_name(chan));

	/* Build JSON config */
	snprintf(config_json, sizeof(config_json),
		"{\"config\":{\"sample_rate\":%d,\"VID\":\"%s\"}}", SAMPLE_RATE, vid);
	ast_debug(1, "AMD_WS: Config JSON: %s\n", config_json);

	/* Copy config to buffer with LWS_PRE prefix space */
	session.config_len = strlen(config_json);
	memcpy(&session.config_buffer[LWS_PRE], config_json, session.config_len);

	/* Set read format to signed linear so we get signed linear frames in */
	readFormat = ao2_bump(ast_channel_readformat(chan));
	if (ast_set_read_format(chan, ast_format_slin) < 0) {
		ast_log(LOG_WARNING, "AMD_WS: Channel [%s]. Unable to set to linear mode, giving up\n",
			ast_channel_name(chan));
		pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
		pbx_builtin_setvar_helper(chan, "AMDCAUSE", "SETFORMAT_FAILED");
		return;
	}
	ast_debug(1, "AMD_WS: Read format set to slin\n");

	/* Suppress libwebsockets logging */
	lws_set_log_level(0, NULL);

	/* Create WebSocket context */
	ctx_info.port = CONTEXT_PORT_NO_LISTEN;
	ctx_info.protocols = protocols;
	ctx_info.user = &session;
	ctx_info.gid = -1;
	ctx_info.uid = -1;

	ast_debug(1, "AMD_WS: Creating LWS context\n");
	session.context = lws_create_context(&ctx_info);
	if (!session.context) {
		ast_log(LOG_ERROR, "AMD_WS: Channel [%s]. Failed to create WS context\n",
			ast_channel_name(chan));
		pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
		pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONTEXT_FAILED");
		if (readFormat) {
			ast_set_read_format(chan, readFormat);
		}
		return;
	}
	ast_debug(1, "AMD_WS: LWS context created successfully\n");

	/* Connect to server */
	conn_info.context = session.context;
	conn_info.address = ws_host;
	conn_info.port = ws_port;
	conn_info.path = "/";
	conn_info.host = ws_host;
	conn_info.origin = ws_host;
	conn_info.protocol = protocols[0].name;
	conn_info.ssl_connection = 0;

	ast_verb(3, "AMD_WS: Connecting to ws://%s:%d/\n", ws_host, ws_port);
	ast_debug(1, "AMD_WS: lws_client_connect_via_info: address=%s port=%d path=%s\n",
		conn_info.address, conn_info.port, conn_info.path);

	session.wsi = lws_client_connect_via_info(&conn_info);
	if (!session.wsi) {
		ast_log(LOG_ERROR, "AMD_WS: Channel [%s]. Failed to connect to %s:%d\n",
			ast_channel_name(chan), ws_host, ws_port);
		pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
		pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONNECT_FAILED");
		lws_context_destroy(session.context);
		if (readFormat) {
			ast_set_read_format(chan, readFormat);
		}
		return;
	}
	ast_debug(1, "AMD_WS: lws_client_connect_via_info returned wsi=%p\n", session.wsi);

	/* Wait for connection */
	ast_debug(1, "AMD_WS: Waiting for connection...\n");
	total_ms = 0;
	while (!session.connected && !session.connection_error && total_ms < 3000) {
		lws_service(session.context, 50);
		total_ms += 50;
		if (total_ms % 500 == 0) {
			ast_debug(1, "AMD_WS: Still waiting for connection... %d ms\n", total_ms);
		}
	}

	if (session.connection_error) {
		ast_log(LOG_ERROR, "AMD_WS: Channel [%s]. Connection error: %s\n",
			ast_channel_name(chan), session.error_msg);
		strcpy(amdStatus, "NOTSURE");
		snprintf(amdCause, sizeof(amdCause), "CONNECTION_ERROR-%s", session.error_msg);
		goto cleanup;
	}

	if (!session.connected) {
		ast_log(LOG_ERROR, "AMD_WS: Channel [%s]. Connection timeout after %d ms\n",
			ast_channel_name(chan), total_ms);
		strcpy(amdStatus, "NOTSURE");
		strcpy(amdCause, "CONNECTION_TIMEOUT");
		goto cleanup;
	}

	ast_verb(3, "AMD_WS: Connected successfully after %d ms\n", total_ms);

	/* Wait for config to be sent */
	ast_debug(1, "AMD_WS: Waiting for config to be sent...\n");
	total_ms = 0;
	while (!session.config_sent && session.connected && total_ms < 2000) {
		lws_service(session.context, 50);
		total_ms += 50;
	}

	if (!session.config_sent) {
		ast_log(LOG_WARNING, "AMD_WS: Channel [%s]. Config not sent after %d ms\n",
			ast_channel_name(chan), total_ms);
	} else {
		ast_verb(3, "AMD_WS: Config sent after %d ms\n", total_ms);
	}

	/* Main loop - read audio and send at scheduled times (like amd.py) */
	ast_verb(3, "AMD_WS: Starting audio capture loop (timeout=%d ms)\n", timeout_ms);
	ast_verb(3, "AMD_WS: Send schedule: 500ms, 1000ms, 1500ms, 2000ms, 3000ms, 4000ms\n");
	session.buffer_pos = 0;
	session.send_time_index = 0;
	iTotalTime = 0;

	while (iTotalTime < timeout_ms && !session.got_result && session.connected) {
		int ms = 0;
		int should_send = 0;

		res = ast_waitfor(chan, 50);
		if (res < 0) {
			ast_verb(3, "AMD_WS: Channel [%s]. ast_waitfor returned %d\n",
				ast_channel_name(chan), res);
			break;
		}
		ms = 50 - res;

		f = ast_read(chan);
		if (!f) {
			ast_verb(3, "AMD_WS: Channel [%s]. HANGUP\n", ast_channel_name(chan));
			ast_debug(1, "AMD_WS: Got hangup\n");
			strcpy(amdStatus, "HANGUP");
			strcpy(amdCause, "HANGUP");
			goto cleanup;
		}

		if (f->frametype == AST_FRAME_VOICE) {
			int framelength;
			int copy_bytes;

			audioFrameCount++;
			framelength = (ast_codec_samples_count(f) / (SAMPLE_RATE / 1000));
			iTotalTime += framelength;

			ast_debug(3, "AMD_WS: Frame %d: len=%d samples=%ld framelength=%d iTotalTime=%d\n",
				audioFrameCount, f->datalen, ast_codec_samples_count(f),
				framelength, iTotalTime);

			/* Copy audio to buffer */
			copy_bytes = f->datalen;
			if (session.buffer_pos + copy_bytes > MAX_AUDIO_BUFFER) {
				copy_bytes = MAX_AUDIO_BUFFER - session.buffer_pos;
			}

			if (copy_bytes > 0) {
				memcpy(&session.audio_buffer[LWS_PRE + session.buffer_pos],
					f->data.ptr, copy_bytes);
				session.buffer_pos += copy_bytes;
			}

			/* Check if we should send based on scheduled times */
			if (session.send_time_index < NUM_SEND_TIMES &&
			    iTotalTime >= send_times[session.send_time_index]) {
				should_send = 1;
				session.send_time_index++;
			}
			/* Fallback: send every 8000 bytes after scheduled times exhausted */
			else if (session.send_time_index >= NUM_SEND_TIMES &&
			         session.buffer_pos >= FALLBACK_CHUNK_SIZE) {
				should_send = 1;
			}

			if (should_send && session.buffer_pos > 0) {
				ast_verb(3, "AMD_WS: Time %d ms - sending %d bytes (schedule #%d)\n",
					iTotalTime, session.buffer_pos, session.send_time_index);
				lws_callback_on_writable(session.wsi);
				lws_service(session.context, 0);
			}
		} else {
			iTotalTime += ms;
		}

		ast_frfree(f);
		f = NULL;

		/* Service WebSocket to receive responses */
		lws_service(session.context, 0);

		/* Check for result */
		if (session.got_result) {
			ast_verb(3, "AMD_WS: Got result at %d ms\n", iTotalTime);
			break;
		}
	}

	/* Send any remaining audio */
	if (session.buffer_pos > 0 && session.connected) {
		ast_debug(1, "AMD_WS: Sending remaining audio (%d bytes)\n", session.buffer_pos);
		lws_callback_on_writable(session.wsi);
		lws_service(session.context, 100);
	}

	/* Wait a bit more for result if we haven't gotten one */
	if (!session.got_result && session.connected) {
		ast_debug(1, "AMD_WS: Waiting for final result...\n");
		for (i = 0; i < 40 && !session.got_result && session.connected; i++) {
			lws_service(session.context, 50);
		}
	}

	/* Determine result */
	if (amdStatus[0] == '\0') {
		if (session.got_result) {
			ast_verb(3, "AMD_WS: Final response: [%s]\n", session.result);
			if (strstr(session.result, "HUMAN")) {
				strcpy(amdStatus, "HUMAN");
				ast_verb(3, "AMD_WS: Channel [%s]. HUMAN detected\n", ast_channel_name(chan));
			} else if (strstr(session.result, "MACHINE") || strstr(session.result, "AMD")) {
				strcpy(amdStatus, "MACHINE");
				ast_verb(3, "AMD_WS: Channel [%s]. MACHINE detected\n", ast_channel_name(chan));
			} else {
				strcpy(amdStatus, "NOTSURE");
				ast_verb(3, "AMD_WS: Channel [%s]. NOTSURE (unknown response)\n", ast_channel_name(chan));
			}
			ast_copy_string(amdCause, session.result, sizeof(amdCause));
		} else {
			strcpy(amdStatus, "NOTSURE");
			snprintf(amdCause, sizeof(amdCause), "TIMEOUT-%d", iTotalTime);
			ast_verb(3, "AMD_WS: Channel [%s]. NOTSURE (timeout after %d ms, %d frames)\n",
				ast_channel_name(chan), iTotalTime, audioFrameCount);
		}
	}

cleanup:
	ast_debug(1, "AMD_WS: Cleanup - destroying context\n");

	/* Clean up */
	if (session.context) {
		lws_context_destroy(session.context);
	}

	/* Set channel variables */
	ast_verb(3, "AMD_WS: Channel [%s]. Setting AMDSTATUS=%s AMDCAUSE=%s\n",
		ast_channel_name(chan), amdStatus, amdCause);
	pbx_builtin_setvar_helper(chan, "AMDSTATUS", amdStatus);
	pbx_builtin_setvar_helper(chan, "AMDCAUSE", amdCause);

	/* Restore channel read format */
	if (readFormat && ast_set_read_format(chan, readFormat)) {
		ast_log(LOG_WARNING, "AMD_WS: Unable to restore read format on '%s'\n",
			ast_channel_name(chan));
	}

	ast_debug(1, "AMD_WS: Detection complete for channel [%s]\n", ast_channel_name(chan));

	/* Decrement session count */
	ast_mutex_lock(&session_lock);
	active_sessions--;
	ast_mutex_unlock(&session_lock);

	return;
}

static int amd_ws_exec(struct ast_channel *chan, const char *data)
{
	ast_debug(1, "AMD_WS: amd_ws_exec called with data=[%s]\n", data ? data : "(null)");
	amd_ws_detect(chan, data);
	return 0;
}

static int unload_module(void)
{
	int sessions;

	ast_verb(3, "AMD_WS: Unloading module\n");

	ast_mutex_lock(&session_lock);
	sessions = active_sessions;
	ast_mutex_unlock(&session_lock);

	if (sessions > 0) {
		ast_log(LOG_WARNING, "AMD_WS: Cannot unload - %d active sessions\n", sessions);
		return -1;
	}

	ast_mutex_destroy(&session_lock);
	return ast_unregister_application(app);
}

static int load_module(void)
{
	ast_verb(3, "AMD_WS: Loading module\n");
	ast_verb(3, "AMD_WS: Defaults - host [%s] port [%d] timeout [%d]\n",
		dfltHost, dfltPort, dfltTimeout);

	ast_mutex_init(&session_lock);

	if (ast_register_application_xml(app, amd_ws_exec)) {
		ast_log(LOG_ERROR, "AMD_WS: Failed to register application\n");
		ast_mutex_destroy(&session_lock);
		return AST_MODULE_LOAD_DECLINE;
	}

	ast_verb(3, "AMD_WS: Module loaded successfully\n");
	return AST_MODULE_LOAD_SUCCESS;
}

AST_MODULE_INFO(ASTERISK_GPL_KEY, AST_MODFLAG_DEFAULT, "AMD via WebSocket",
	.support_level = AST_MODULE_SUPPORT_EXTENDED,
	.load = load_module,
	.unload = unload_module,
);
