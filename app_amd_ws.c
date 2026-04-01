/*
 * app_amd_ws.c - AMD via WebSocket
 * Sends audio chunks to external AMD server (compatible with amdy.io)
 */

#include "asterisk.h"
#include "asterisk/module.h"
#include "asterisk/channel.h"
#include "asterisk/pbx.h"
#include "asterisk/app.h"
#include "asterisk/format_cache.h"
#include "asterisk/callerid.h"
#include "asterisk/lock.h"

/* Undef Asterisk's pthread type overrides before including libwebsockets */
#undef pthread_mutex_t
#undef pthread_cond_t

#include <libwebsockets.h>

#define SAMPLE_RATE 8000
#define CHUNK_MS 500
#define CHUNK_SAMPLES (SAMPLE_RATE * CHUNK_MS / 1000)  /* 4000 samples */
#define CHUNK_BYTES (CHUNK_SAMPLES * 2)                 /* 8000 bytes */
#define FRAME_MS 20

#define DEFAULT_WS_PORT 8080
#define DEFAULT_TIMEOUT_MS 5000
#define CONNECT_TIMEOUT_MS 2000
#define CONFIG_SEND_TIMEOUT_MS 1000
#define RESULT_WAIT_ITERATIONS 20
#define SERVICE_INTERVAL_MS 50

static const char app[] = "AMD_WS";

/* Track active sessions for safe unload */
static int active_sessions = 0;
static ast_mutex_t session_lock;

struct amd_ws_session {
    struct lws *wsi;
    struct lws_context *context;
    unsigned char audio_buffer[LWS_PRE + CHUNK_BYTES];
    unsigned char config_buffer[LWS_PRE + 512];
    int buffer_pos;
    int config_len;
    int frames_collected;
    char result[256];
    int got_result;
    int connected;
    int config_sent;
};

/* Escape a string for safe JSON embedding. Writes to dst (including NUL).
 * Returns number of chars written (excluding NUL), or -1 if dst_size too small. */
static int json_escape(char *dst, size_t dst_size, const char *src)
{
    size_t pos = 0;
    unsigned char c;

    while ((c = (unsigned char)*src++)) {
        const char *esc;
        char hex[7];
        size_t elen;

        switch (c) {
        case '"':  esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\b': esc = "\\b";  break;
        case '\f': esc = "\\f";  break;
        case '\n': esc = "\\n";  break;
        case '\r': esc = "\\r";  break;
        case '\t': esc = "\\t";  break;
        default:
            if (c < 0x20) {
                snprintf(hex, sizeof(hex), "\\u%04x", c);
                esc = hex;
            } else {
                if (pos + 1 >= dst_size) return -1;
                dst[pos++] = (char)c;
                continue;
            }
        }
        elen = strlen(esc);
        if (pos + elen >= dst_size) return -1;
        memcpy(dst + pos, esc, elen);
        pos += elen;
    }

    dst[pos] = '\0';
    return (int)pos;
}

static int ws_callback(struct lws *wsi, enum lws_callback_reasons reason,
                       void *user, void *in, size_t len)
{
    struct amd_ws_session *session = (struct amd_ws_session *)lws_context_user(lws_get_context(wsi));

    switch (reason) {
    case LWS_CALLBACK_CLIENT_ESTABLISHED:
        session->connected = 1;
        lws_callback_on_writable(wsi);
        break;

    case LWS_CALLBACK_CLIENT_RECEIVE:
        if (len > 0 && len < sizeof(session->result)) {
            memcpy(session->result, in, len);
            session->result[len] = '\0';
            if (strstr(session->result, "HUMAN") ||
                strstr(session->result, "MACHINE") ||
                strstr(session->result, "AMD")) {
                session->got_result = 1;
            }
        }
        break;

    case LWS_CALLBACK_CLIENT_WRITEABLE:
        if (!session->config_sent && session->config_len > 0) {
            lws_write(wsi, &session->config_buffer[LWS_PRE],
                      session->config_len, LWS_WRITE_TEXT);
            session->config_sent = 1;
        } else if (session->buffer_pos > 0) {
            lws_write(wsi, &session->audio_buffer[LWS_PRE],
                      session->buffer_pos, LWS_WRITE_BINARY);
            session->buffer_pos = 0;
        }
        break;

    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR:
    case LWS_CALLBACK_CLIENT_CLOSED:
        session->connected = 0;
        break;

    default:
        break;
    }
    return 0;
}

static const struct lws_protocols protocols[] = {
    { "amd", ws_callback, 0, CHUNK_BYTES + LWS_PRE },
    { NULL, NULL, 0, 0 }
};

static int amd_ws_exec(struct ast_channel *chan, const char *data)
{
    char *parse;
    struct ast_format *readformat = NULL;
    struct ast_frame *f;
    struct amd_ws_session session = {0};
    struct lws_context_creation_info ctx_info = {0};
    struct lws_client_connect_info conn_info = {0};
    struct timeval start_time;
    int timeout_ms = DEFAULT_TIMEOUT_MS;
    int total_ms;
    int elapsed_ms;
    char ws_host[256] = "127.0.0.1";
    int ws_port = DEFAULT_WS_PORT;
    char vid[256] = "";
    char vid_escaped[512];
    char config_json[512];
    int i;
    int format_changed = 0;

    /* Track session */
    ast_mutex_lock(&session_lock);
    active_sessions++;
    ast_mutex_unlock(&session_lock);

    AST_DECLARE_APP_ARGS(args,
        AST_APP_ARG(host);
        AST_APP_ARG(port);
        AST_APP_ARG(vid);
        AST_APP_ARG(timeout);
    );

    if (!ast_strlen_zero(data)) {
        parse = ast_strdupa(data);
        AST_STANDARD_APP_ARGS(args, parse);

        if (!ast_strlen_zero(args.host))
            ast_copy_string(ws_host, args.host, sizeof(ws_host));
        if (!ast_strlen_zero(args.port)) {
            ws_port = atoi(args.port);
            if (ws_port <= 0 || ws_port > 65535) {
                ast_log(LOG_WARNING, "AMD_WS: Invalid port '%s', using default %d\n",
                        args.port, DEFAULT_WS_PORT);
                ws_port = DEFAULT_WS_PORT;
            }
        }
        if (!ast_strlen_zero(args.vid))
            ast_copy_string(vid, args.vid, sizeof(vid));
        if (!ast_strlen_zero(args.timeout)) {
            timeout_ms = atoi(args.timeout);
            if (timeout_ms <= 0) {
                ast_log(LOG_WARNING, "AMD_WS: Invalid timeout '%s', using default %d\n",
                        args.timeout, DEFAULT_TIMEOUT_MS);
                timeout_ms = DEFAULT_TIMEOUT_MS;
            }
        }
    }

    /* If VID not provided, try to get caller ID name */
    if (ast_strlen_zero(vid)) {
        const char *cid_name;
        ast_channel_lock(chan);
        cid_name = ast_channel_caller(chan)->id.name.str;
        if (!ast_strlen_zero(cid_name)) {
            ast_copy_string(vid, cid_name, sizeof(vid));
        } else {
            ast_copy_string(vid, "Unknown", sizeof(vid));
        }
        ast_channel_unlock(chan);
    }

    ast_verb(3, "AMD_WS: %s host=%s port=%d vid=%s timeout=%d\n",
        ast_channel_name(chan), ws_host, ws_port, vid, timeout_ms);

    /* Build JSON config with escaped VID */
    if (json_escape(vid_escaped, sizeof(vid_escaped), vid) < 0) {
        ast_copy_string(vid_escaped, "Unknown", sizeof(vid_escaped));
    }
    snprintf(config_json, sizeof(config_json),
        "{\"config\":{\"sample_rate\":%d,\"VID\":\"%s\"}}",
        SAMPLE_RATE, vid_escaped);

    session.config_len = strlen(config_json);
    memcpy(&session.config_buffer[LWS_PRE], config_json, session.config_len);

    /* Answer if not already */
    if (ast_channel_state(chan) != AST_STATE_UP) {
        if (ast_answer(chan)) {
            pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
            pbx_builtin_setvar_helper(chan, "AMDCAUSE", "ANSWER_FAILED");
            goto done;
        }
    }

    /* Set read format to slin (16-bit 8kHz) */
    readformat = ao2_bump(ast_channel_readformat(chan));
    if (ast_set_read_format(chan, ast_format_slin)) {
        ast_log(LOG_WARNING, "AMD_WS: Unable to set read format to slin\n");
        ao2_ref(readformat, -1);
        readformat = NULL;
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "FORMAT_FAILED");
        goto done;
    }
    format_changed = 1;

    /* Create WebSocket context */
    ctx_info.port = CONTEXT_PORT_NO_LISTEN;
    ctx_info.protocols = protocols;
    ctx_info.user = &session;
    ctx_info.gid = -1;
    ctx_info.uid = -1;

    /* Suppress libwebsockets logging */
    lws_set_log_level(0, NULL);

    session.context = lws_create_context(&ctx_info);
    if (!session.context) {
        ast_log(LOG_ERROR, "AMD_WS: Failed to create WS context\n");
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONTEXT_FAILED");
        goto cleanup;
    }

    /* Connect to server */
    conn_info.context = session.context;
    conn_info.address = ws_host;
    conn_info.port = ws_port;
    conn_info.path = "/";
    conn_info.host = ws_host;
    conn_info.protocol = "amd";
    conn_info.ssl_connection = 0;

    session.wsi = lws_client_connect_via_info(&conn_info);
    if (!session.wsi) {
        ast_log(LOG_ERROR, "AMD_WS: Failed to connect to %s:%d\n",
                ws_host, ws_port);
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONNECT_FAILED");
        goto cleanup;
    }

    /* Wait for connection */
    total_ms = 0;
    while (!session.connected && total_ms < CONNECT_TIMEOUT_MS) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
        total_ms += SERVICE_INTERVAL_MS;
    }

    if (!session.connected) {
        ast_log(LOG_ERROR, "AMD_WS: Connection timeout to %s:%d\n",
                ws_host, ws_port);
        pbx_builtin_setvar_helper(chan, "AMDSTATUS", "NOTSURE");
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", "CONNECTION_TIMEOUT");
        goto cleanup;
    }

    ast_verb(3, "AMD_WS: Connected to %s:%d\n", ws_host, ws_port);

    /* Wait for config to be sent */
    total_ms = 0;
    while (!session.config_sent && total_ms < CONFIG_SEND_TIMEOUT_MS) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
        total_ms += SERVICE_INTERVAL_MS;
    }

    /* Main loop - read audio and send chunks */
    session.buffer_pos = 0;
    session.frames_collected = 0;
    start_time = ast_tvnow();

    while (!session.got_result && session.connected) {
        int res;

        elapsed_ms = ast_tvdiff_ms(ast_tvnow(), start_time);
        if (elapsed_ms >= timeout_ms) {
            break;
        }

        res = ast_waitfor(chan, FRAME_MS);
        if (res < 0) {
            break;
        }
        if (res == 0) {
            lws_service(session.context, 0);
            continue;
        }

        f = ast_read(chan);
        if (!f) {
            break;
        }

        if (f->frametype == AST_FRAME_VOICE) {
            int copy_bytes = f->datalen;
            int space = CHUNK_BYTES - session.buffer_pos;

            if (copy_bytes > space) {
                copy_bytes = space;
            }

            memcpy(&session.audio_buffer[LWS_PRE + session.buffer_pos],
                   f->data.ptr, copy_bytes);
            session.buffer_pos += copy_bytes;
            session.frames_collected++;

            if (session.buffer_pos >= CHUNK_BYTES) {
                lws_callback_on_writable(session.wsi);
                lws_service(session.context, 0);
                session.frames_collected = 0;
            }
        }

        ast_frfree(f);
        lws_service(session.context, 0);
    }

    /* Send any remaining audio */
    if (session.buffer_pos > 0 && session.connected) {
        lws_callback_on_writable(session.wsi);
        lws_service(session.context, SERVICE_INTERVAL_MS);
    }

    /* Wait a bit more for result */
    for (i = 0; i < RESULT_WAIT_ITERATIONS && !session.got_result; i++) {
        lws_service(session.context, SERVICE_INTERVAL_MS);
    }

    /* Always capture final elapsed time for logging */
    elapsed_ms = ast_tvdiff_ms(ast_tvnow(), start_time);

    /* Set channel variables */
    {
        const char *status;
        const char *cause;

        if (session.got_result) {
            if (strstr(session.result, "HUMAN")) {
                status = "HUMAN";
            } else if (strstr(session.result, "MACHINE") || strstr(session.result, "AMD")) {
                status = "MACHINE";
            } else {
                status = "NOTSURE";
            }
            cause = session.result;
        } else {
            status = "NOTSURE";
            cause = "TIMEOUT";
        }

        pbx_builtin_setvar_helper(chan, "AMDSTATUS", status);
        pbx_builtin_setvar_helper(chan, "AMDCAUSE", cause);

        ast_verb(3, "AMD_WS: %s status=%s cause=%s elapsed=%dms\n",
            ast_channel_name(chan), status, cause, elapsed_ms);
    }

cleanup:
    if (session.context) {
        lws_context_destroy(session.context);
    }
    if (format_changed && readformat) {
        ast_set_read_format(chan, readformat);
    }
    if (readformat) {
        ao2_ref(readformat, -1);
    }

done:
    ast_mutex_lock(&session_lock);
    active_sessions--;
    ast_mutex_unlock(&session_lock);

    return 0;
}

static int load_module(void)
{
    ast_mutex_init(&session_lock);
    return ast_register_application_xml(app, amd_ws_exec);
}

static int unload_module(void)
{
    int sessions;

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

AST_MODULE_INFO_STANDARD(ASTERISK_GPL_KEY, "AMD via WebSocket");
