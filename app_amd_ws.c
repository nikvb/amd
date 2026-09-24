/*
 * app_amd_ws.c -- Answering Machine Detection over WebSocket for Asterisk
 *
 * Copyright (C) 2024-2026, amdy.io / Nik VB
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation (GPL-2.0).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

/*! \file
 *
 * \brief AMD_WS() -- stream call audio to an AMD classification service over
 *        WebSocket and set AMDSTATUS/AMDCAUSE like the stock AMD() application.
 *
 * \author amdy.io
 *
 * \ingroup applications
 */

/*
 * =====================================================================
 * Architecture
 * =====================================================================
 *
 * One dialplan application, AMD_WS(), executed on the channel's PBX thread.
 * Everything a call needs lives in a stack struct (struct amd_call) plus two
 * heap buffers (audio accumulator, server-text buffer).  There are no
 * per-call globals; shared state is limited to the configuration snapshot
 * (mutex), the optional persistent MySQL connection (mutex), rate-limit
 * timestamps (mutex) and statistics counters (atomic).
 *
 * Transport is Asterisk's own WebSocket client (res_http_websocket,
 * OPTIONAL_API).  It gives us a real connect timeout, wss:// through the
 * core's OpenSSL, RFC 6455 client masking, ping/pong handling and a file
 * descriptor that plugs straight into ast_waitfor_nandfds().  No third-party
 * library is linked.
 *
 * Phases of a call (all waits are bounded by ast_tvdiff_ms() deadlines):
 *
 *   1. SETUP      parse args + config snapshot, answer (unless 'A'),
 *                 set read format slin.
 *   2. CONNECT    ast_websocket_client_create_with_options() is *blocking*
 *                 (DNS, TCP, HTTP upgrade), so it runs on a short-lived helper
 *                 thread while the PBX thread keeps reading the channel:
 *                 audio is accumulated from the very first frame, hangup is
 *                 seen immediately and a stalled handshake cannot park the
 *                 call -- the PBX thread abandons the job at the connect
 *                 deadline and the helper disposes of whatever it produces.
 *                 The optional DB enrichment (bounded by db_timeout_ms) runs
 *                 on the same helper right before the connect, so a stalled
 *                 DB can cost that call its connect window (CONNECTION_ERROR)
 *                 but never stops the PBX thread from reading the channel.
 *                 The config JSON is built when the helper hands the socket
 *                 over.
 *   3. STREAM     ast_waitfor_nandfds(chan + ws fd, <= 20 ms budget).
 *                 Voice frames are appended to the accumulator (never
 *                 truncated).  Sends follow the time schedule measured from
 *                 the first captured frame (amd.py SEND_TIMES); after the
 *                 last mark a send happens whenever >= chunk_bytes are
 *                 pending or fallback_interval_ms passed since the last send
 *                 with something pending (amd.py's fallback rule).  A mark at
 *                 which nothing is pending is a "no audio data" mark; after
 *                 eof_no_audio_streak of them in a row, with audio sent
 *                 before, the EOF finalisation starts (phase 4).  Server TEXT
 *                 frames are classified as they arrive, exactly like amd.py:
 *                 'HUMAN' in text -> HUMAN, else 'AMD'/'MACHINE' in text ->
 *                 MACHINE (the brand "AMDY" does not count), else an ack.
 *   4. EOF_WAIT   {"eof":1} was sent to make the server finalise; wait up to
 *                 eof_wait_ms for ONE reply, still servicing the channel
 *                 (amd.py:404-435).  HUMAN/MACHINE are honoured, any other
 *                 reply is EOF_INCONCLUSIVE, no reply/error is EOF_ERROR.
 *   5. GRACE      when timeout_ms expires without a result and
 *                 result_grace_ms > 0 (default 0 = return at once like amd.py
 *                 at MAX_WAIT_TIME) the remaining audio is flushed and we wait
 *                 that long for the server's reply, still servicing the channel.
 *   6. EXIT       stop playback, send {"eof":1} (again, as amd.py's cleanup
 *                 does), CLOSE 1000, unref, restore the read format, set
 *                 AMDSTATUS/AMDCAUSE/AMDSTATS/AMDRESPONSE/AMDELAPSED, bump
 *                 counters, one verbose summary line.
 *
 * Outcome vocabulary (production amd.py Jul 2026 + stock app_amd/VD_amd.agi):
 *   HUMAN/HUMAN, MACHINE/<raw reply>, HUMAN/CONNECTION_ERROR (cannot connect),
 *   HUMAN/PROCESSING_ERROR (ws lost after connect), HUMAN/FATAL_ERROR
 *   (internal: alloc, format, thread, option A), NOTSURE/SERVER_TIMEOUT, NOTSURE/NOAUDIODATA-<ms>, HANGUP/HANGUP,
 *   NOTSURE/EOF_INCONCLUSIVE, NOTSURE/EOF_ERROR.  Errors default to HUMAN
 *   "for safety" (the call reaches an agent), as amd.py does.
 *
 * Parallel playback: the optional playfile list is started with
 * ast_streamfile() after playdelay_ms; the file stream is driven by the
 * channel's timing fd inside ast_read() (or by the channel scheduler which we
 * run ourselves), exactly like ast_waitstream() does, so audio capture and
 * playback share one loop.  Playback is stopped the moment a terminal result
 * arrives or the application exits.
 *
 * Timing model:
 *   t_app     application entry
 *   t_connect the moment the connect job is started (after answer/format)
 *   t_first   first captured voice frame (0 if none)
 *   marks     conf send_schedule, measured from t_first (amd.py measures from
 *             its stream start, which on a Local/SIP leg delivering audio at
 *             once is the same instant)
 *   t_last_send  last successful audio send (fallback interval runs from it)
 *   detection deadline  = (t_first ? t_first : t_app) + timeout_ms
 *   connect deadline    = min(t_connect + connect_timeout_ms, detection deadline)
 *   eof deadline        = t_eof + eof_wait_ms (not capped by the detection
 *                         deadline: amd.py's 3 s recv timeout is independent)
 *   grace deadline      = detection deadline + result_grace_ms
 *   playback start      = t_app + playdelay_ms
 *   AMDELAPSED          = exit - (t_first ? t_first : t_app)
 *   AMDSTATS            = <AMDELAPSED>-<ms of audio sent>-<chunks>-<bytes sent>
 *                         (VD_amd.agi reads the first field as run_time)
 *
 * File layout: config -> db -> json/escape -> ws helpers -> audio
 * accumulator -> playback helpers -> exec -> cli -> load/unload/reload.
 */

/*** MODULEINFO
	<depend>res_http_websocket</depend>
	<support_level>extended</support_level>
 ***/

#include "asterisk.h"

#include <ctype.h>
#include <limits.h>
#include <unistd.h>
#include <sys/socket.h>

/*
 * Asterisk 18/20 strings.h declares "static int force_inline ..." which trips
 * -Wold-style-declaration under -Wextra; that is the core's header, not ours.
 */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-declaration"
#include "asterisk/module.h"
#include "asterisk/channel.h"
#include "asterisk/pbx.h"
#include "asterisk/app.h"
#include "asterisk/file.h"
#include "asterisk/sched.h"
#include "asterisk/format_cache.h"
#include "asterisk/callerid.h"
#include "asterisk/lock.h"
#include "asterisk/config.h"
#include "asterisk/cli.h"
#include "asterisk/utils.h"
#include "asterisk/strings.h"
#include "asterisk/time.h"
#include "asterisk/tcptls.h"
#include "asterisk/http_websocket.h"
#pragma GCC diagnostic pop

#ifdef HAVE_MYSQL
#include <mysql.h>
#include <errmsg.h>
#endif

/*** DOCUMENTATION
	<application name="AMD_WS" language="en_US">
		<synopsis>
			Answering Machine Detection via an external WebSocket service (amdy.io).
		</synopsis>
		<syntax>
			<parameter name="host">
				<para>AMD service host name or IP. Default from amd_ws.conf <literal>host=</literal> (127.0.0.1).</para>
			</parameter>
			<parameter name="port">
				<para>AMD service TCP port. Default from amd_ws.conf <literal>port=</literal> (2700). Invalid values fall back to the default with a warning.</para>
			</parameter>
			<parameter name="vid">
				<para>Call tracking id sent as <literal>VID</literal>. Default: CALLERID(name) when valid and non-empty, else <literal>Unknown</literal>.</para>
			</parameter>
			<parameter name="timeout_ms">
				<para>Overall detection window in milliseconds. Default from amd_ws.conf <literal>timeout_ms=</literal> (10000). Values &lt;= 0 use the default.</para>
			</parameter>
			<parameter name="playfile">
				<para>Optional sound file(s) to play into the channel while audio is being captured, with Playback() semantics: path relative to the sounds directory, no extension, <literal>&amp;</literal>-separated list played sequentially, language taken from the channel. Playback starts after <literal>playdelay_ms</literal> and is stopped as soon as a terminal result arrives or the application exits. End of file does not end detection.</para>
			</parameter>
			<parameter name="options">
				<optionlist>
					<option name="n">
						<para>No DB lookup for this call (do not query vicidial_auto_calls for phone/country).</para>
					</option>
					<option name="s">
						<para>TLS: connect with <literal>wss://</literal>. Verification follows amd_ws.conf <literal>tls_verify</literal>.</para>
					</option>
					<option name="d">
						<argument name="ms" required="true" />
						<para>Override <literal>playdelay_ms</literal> for this call.</para>
					</option>
					<option name="c">
						<argument name="ms" required="true" />
						<para>Override the connect timeout (amd_ws.conf <literal>connect_timeout_ms</literal>, default 10000).</para>
					</option>
					<option name="p">
						<argument name="phone" required="true" />
						<para>Supply the phone number explicitly (sent as <literal>phone</literal>; p() or k() skips the DB lookup).</para>
					</option>
					<option name="k">
						<argument name="code" required="true" />
						<para>Supply the country/phone code explicitly (sent as <literal>country_code</literal>; p() or k() skips the DB lookup).</para>
					</option>
					<option name="i">
						<argument name="cid" required="true" />
						<para>Supply the caller id explicitly (sent as <literal>caller_id</literal>). Default: CALLERID(num) of the channel when non-empty and not "Unknown", unless amd_ws.conf <literal>send_caller_id=no</literal>.</para>
					</option>
					<option name="a">
						<para>Answer the channel if it is not up (default).</para>
					</option>
					<option name="A">
						<para>Do NOT answer; if the channel is not up, fail with AMDSTATUS=HUMAN, AMDCAUSE=FATAL_ERROR.</para>
					</option>
					<option name="v">
						<para>Trace: log one timeline line per event (connect, first audio, every chunk sent, every server reply, result) at verbose 3, with the millisecond offset from the start of the application. Same as amd_ws.conf <literal>trace=yes</literal> for every call.</para>
					</option>
				</optionlist>
			</parameter>
		</syntax>
		<description>
			<para>Streams 8 kHz signed-linear audio from the channel to the AMD service over a WebSocket and
			sets channel variables with the classification, using the vocabulary of the production amdy.io
			EAGI client (amd.py) and of the stock AMD() application. The connection is made with Asterisk's own
			WebSocket client (res_http_websocket).</para>
			<para>Channel variables set on every exit path:</para>
			<variablelist>
				<variable name="AMDSTATUS">
					<value name="HUMAN">the server said HUMAN, or an error occurred (errors default to HUMAN for safety, as amd.py does)</value>
					<value name="MACHINE">the server said MACHINE or AMD</value>
					<value name="NOTSURE">no decision (timeout, EOF finalisation inconclusive)</value>
					<value name="HANGUP">the channel hung up before a result</value>
				</variable>
				<variable name="AMDCAUSE">
					<value name="HUMAN">with AMDSTATUS=HUMAN: the server's decision</value>
					<value name="raw reply">with AMDSTATUS=MACHINE: the server's reply text (printable ASCII, max 255 chars), e.g. MACHINE or AMD</value>
					<value name="CONNECTION_ERROR">cannot connect: DNS/TCP/upgrade/TLS failure, connect timeout, per-host connect cap, res_http_websocket not loaded (AMDSTATUS=HUMAN)</value>
					<value name="PROCESSING_ERROR">WebSocket error or close after the connect, before a result (AMDSTATUS=HUMAN)</value>
					<value name="FATAL_ERROR">internal failure: allocation, read format, thread creation, config unusable, not answered with option A (AMDSTATUS=HUMAN)</value>
					<value name="SERVER_TIMEOUT">timeout_ms elapsed, audio was sent, no result (AMDSTATUS=NOTSURE)</value>
					<value name="NOAUDIODATA-ms">timeout_ms elapsed and no audio was ever captured, ms = the elapsed window (AMDSTATUS=NOTSURE; like the stock AMD())</value>
					<value name="HANGUP">channel hung up before a result</value>
					<value name="EOF_INCONCLUSIVE">no audio at eof_no_audio_streak consecutive schedule marks, {"eof":1} was sent and the server's reply was neither HUMAN nor MACHINE (AMDSTATUS=NOTSURE)</value>
					<value name="EOF_ERROR">as above, but no reply within eof_wait_ms or the WebSocket failed (AMDSTATUS=NOTSURE)</value>
				</variable>
				<variable name="AMDSTATS">
					<para><literal>elapsed_ms-audio_ms_sent-chunks_sent-bytes_sent</literal> (integers; ViciDial reads the first field as run_time).</para>
				</variable>
				<variable name="AMDRESPONSE">
					<para>Raw last server text (printable ASCII only, max 255 chars).</para>
				</variable>
				<variable name="AMDELAPSED">
					<para>Milliseconds from the first captured audio frame to exit (from application start when no audio was captured).</para>
				</variable>
			</variablelist>
			<para>Always returns 0; the PBX detects hangup itself.</para>
		</description>
		<see-also>
			<ref type="application">AMD</ref>
			<ref type="application">Playback</ref>
		</see-also>
	</application>
 ***/

#define AMD_WS_VERSION "2.0.0"

static const char app[] = "AMD_WS";

static const char synopsis[] = "Answering Machine Detection via an external WebSocket service (amdy.io)";

static const char description[] =
"  AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])\n"
"\n"
"Streams 8 kHz signed-linear audio from the channel to the AMD service over a\n"
"WebSocket (Asterisk's own res_http_websocket client, ws:// or wss://) and sets\n"
"channel variables with the classification.  Version " AMD_WS_VERSION ".\n"
"\n"
"Parameters (all optional, defaults from /etc/asterisk/amd_ws.conf):\n"
"  host        AMD service host name or IP (conf host=, default 127.0.0.1)\n"
"  port        AMD service TCP port (conf port=, default 2700)\n"
"  vid         Call tracking id sent as VID; default CALLERID(name) if valid and\n"
"              non-empty, else 'Unknown'\n"
"  timeout_ms  Overall detection window (conf timeout_ms=, default 10000)\n"
"  playfile    Sound file(s) played INTO the channel while audio is captured,\n"
"              Playback() semantics: relative to the sounds dir, no extension,\n"
"              '&'-separated list played in order, channel language.  Starts\n"
"              after playdelay_ms; stopped when a result arrives or on exit.\n"
"              End of file does not end detection.\n"
"  options     n         no DB lookup for this call\n"
"              s         TLS (wss://); verification per conf tls_verify\n"
"              d(ms)     playdelay_ms override\n"
"              c(ms)     connect timeout override (conf connect_timeout_ms, 10000)\n"
"              p(phone)  phone number sent as \"phone\" (p or k skips the DB lookup)\n"
"              k(code)   country/phone code sent as \"country_code\"\n"
"              i(cid)    caller id sent as \"caller_id\" (default: CALLERID(num)\n"
"                        when non-empty and not Unknown; conf send_caller_id=no\n"
"                        turns the default off)\n"
"              a         answer the channel if not up (default)\n"
"              A         do NOT answer; HUMAN/FATAL_ERROR if the channel is not up\n"
"              v         trace: one verbose-3 line per event (connect, first audio,\n"
"                        each chunk sent, each reply, result) with +ms offsets;\n"
"                        conf trace=yes does it for every call\n"
"\n"
"Channel variables set on EVERY exit path (vocabulary of the production amdy.io\n"
"EAGI client amd.py and of the stock AMD(); errors default to HUMAN for safety):\n"
"  AMDSTATUS / AMDCAUSE\n"
"    HUMAN   / HUMAN             the server said HUMAN\n"
"    MACHINE / <raw reply>       the server said MACHINE or AMD; AMDCAUSE is the\n"
"                                reply text itself (printable ASCII, max 255)\n"
"    HUMAN   / CONNECTION_ERROR  cannot connect: DNS, TCP, HTTP upgrade or TLS\n"
"                                failure, connect timeout, per-host connect cap,\n"
"                                res_http_websocket not loaded\n"
"    HUMAN   / PROCESSING_ERROR  WebSocket error or close after the connect,\n"
"                                before a result\n"
"    HUMAN   / FATAL_ERROR       internal failure: allocation, read format,\n"
"                                thread creation, config unusable, option A on\n"
"                                a channel that is not up\n"
"    NOTSURE / SERVER_TIMEOUT    timeout_ms elapsed, audio was sent, no result\n"
"    NOTSURE / NOAUDIODATA-<ms>  timeout_ms elapsed, no audio ever captured\n"
"                                (<ms> = elapsed window, like the stock AMD())\n"
"    HANGUP  / HANGUP            channel hung up before a result\n"
"    NOTSURE / EOF_INCONCLUSIVE  EOF finalisation reply was neither HUMAN nor\n"
"                                MACHINE\n"
"    NOTSURE / EOF_ERROR         EOF finalisation: no reply within eof_wait_ms\n"
"                                or WebSocket failure\n"
"  AMDSTATS     <elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>\n"
"               (ViciDial's VD_amd.agi reads the first field as run_time)\n"
"  AMDRESPONSE  raw last server text (printable ASCII, max 255 chars)\n"
"  AMDELAPSED   ms from the first captured audio frame to exit (from start if none)\n"
"\n"
"Wire protocol (amd.py, Jul 2026): on connect a TEXT frame\n"
"  {\"config\":{\"sample_rate\":8000,\"VID\":\"<vid>\"[,\"phone\":\"..\"][,\"country_code\":\"..\"]\n"
"   [,\"caller_id\":\"..\"]}}\n"
"then BINARY slin chunks at the conf send_schedule marks (default 500,1000,1500,\n"
"2000,3000,...,9000 ms from the first frame), then whenever chunk_bytes (8000)\n"
"are pending or fallback_interval_ms (1000) passed since the last send.  Each\n"
"server TEXT reply is classified exactly like amd.py: 'HUMAN' in the text ->\n"
"HUMAN; else 'AMD' or 'MACHINE' in the text -> MACHINE (the brand \"AMDY\" does\n"
"not count); anything else is an ack (case-sensitive; HONEYPOT etc. are acks).\n"
"When nothing was captured at eof_no_audio_streak (2) consecutive marks after\n"
"audio was sent, {\"eof\":1} is sent and ONE reply is awaited for eof_wait_ms\n"
"(3000) -> HUMAN / MACHINE / EOF_INCONCLUSIVE / EOF_ERROR.  {\"eof\":1} + CLOSE\n"
"1000 on exit.\n"
"\n"
"Always returns 0.  Fallback to the stock AMD() in the dialplan with\n"
"  GotoIf($[\"${AMDCAUSE}\"=\"CONNECTION_ERROR\" | \"${AMDCAUSE}\"=\"PROCESSING_ERROR\"\n"
"          | \"${AMDCAUSE}\"=\"FATAL_ERROR\"]?amd_fallback)\n"
"CLI: amd_ws show settings.   See also: AMD, Playback.\n";

/* ------------------------------------------------------------------------
 * Compile-time limits
 * ---------------------------------------------------------------------- */

#define SAMPLE_RATE            8000
#define BYTES_PER_MS           16          /* 8 kHz * 16 bit mono */
#define MAX_SCHEDULE           64          /* entries in send_schedule (a 0.5 s cadence to 30 s is 60) */
#define STATUS_TOKEN_LEN       32          /* AMDSTATUS */
#define LOOP_BUDGET_MS         20          /* max ast_waitfor_nandfds budget */
/*
 * Per-write bound on the socket.  res_http_websocket turns a write that does
 * not complete within this time into a CLOSE 1011 (= PROCESSING_ERROR for
 * us), so it must cover one RTT of ACK clocking for a multi-frame flush on a
 * fresh connection over a WAN, while staying far below the ~1.9 s after which
 * the Local channel's read queue overflows.
 */
#define WS_WRITE_TIMEOUT_MS    500
#define WS_MAX_FRAME_BYTES     16000       /* split larger sends (1 s of audio); the core alloca()s a frame copy */
#define WS_READ_DRAIN_MAX      8           /* frames read per readiness before the channel is serviced again */
#define ACC_HARD_CAP           (1024 * 1024)
#define RX_CAP                 16384       /* server text buffer */
#define MAX_RESPONSE           255         /* AMDRESPONSE length; also AMDCAUSE for MACHINE (raw reply) */
#define CAUSE_LEN              (MAX_RESPONSE + 1)
#define MAX_CALLERID_LEN       127         /* caller_id sent in the config JSON */
#define CONNECT_WARN_S         10          /* connect failure warning per host */
#define PENDING_WARN_S         60          /* "cap reached" warning per host */
#define DEF_MAX_PENDING        64          /* default max_pending_connects (per host) */
#define MAX_PENDING_HOSTS      16          /* distinct hosts tracked at once */
#define DB_WARN_S              60          /* DB warning rate limit */
#define DB_BACKOFF_S           5           /* skip the DB this long after a failure */
#define MAX_VID_LEN            255

/* ------------------------------------------------------------------------
 * Configuration
 * ---------------------------------------------------------------------- */

struct amd_ws_conf {
	char host[256];
	int port;
	int tls;
	int tls_verify;
	int tls_check_hostname;
	char tls_cafile[256];
	int timeout_ms;
	int connect_timeout_ms;
	int result_grace_ms;
	int schedule[MAX_SCHEDULE];
	int n_schedule;
	int chunk_bytes;
	int fallback_interval_ms;
	int eof_no_audio_streak;      /* 0 = EOF finalisation disabled */
	int eof_wait_ms;
	int send_caller_id;
	int trace;                    /* per-call event timeline at verbose 3 (option v) */
	int playdelay_ms;
	int db;
	int db_timeout_ms;
	char astguiclient_conf[256];
	char extra_config[512];        /* raw JSON object merged into the config frame, e.g. {"short_no_greeting":true} */
	int max_pending_connects;
};

static struct amd_ws_conf g_conf;
AST_MUTEX_DEFINE_STATIC(conf_lock);

/* Statistics (ast_atomic_fetchadd_int), one per outcome of the vocabulary */
static int cnt_calls, cnt_human, cnt_machine, cnt_hangups;
static int cnt_connection_error, cnt_processing_error, cnt_fatal_error;
static int cnt_server_timeout, cnt_noaudiodata, cnt_eof_inconclusive, cnt_eof_error;

/*
 * Connect helper threads.  inflight_helpers counts every live helper (a
 * legitimate burst of answers creates as many for a few milliseconds; that is
 * never capped).  A server that accepts TCP but never answers the HTTP
 * upgrade (and never closes) keeps its helper blocked in the core's handshake
 * read (res_http_websocket gives that read no timeout) after the call gave up
 * at connect_timeout_ms: such PARKED helpers are counted per host, and beyond
 * max_pending_connects new calls to THAT host fail fast with CONNECTION_ERROR
 * instead of piling up threads; one dead test host cannot disable production.
 * A parked helper ends only when the peer closes the socket or Asterisk
 * restarts.
 */
static int inflight_helpers;
struct pending_slot {
	char host[256];
	int count;             /* parked helpers for this host */
	time_t last_warn;      /* "cap reached" warning, once per PENDING_WARN_S */
};
static struct pending_slot pending_hosts[MAX_PENDING_HOSTS];
static int pending_total;  /* sum over the slots, for the CLI */
AST_MUTEX_DEFINE_STATIC(pending_lock);

/* Rate limiting of repeated warnings */
struct warn_slot {
	char host[256];
	time_t last;
};
static struct warn_slot connect_warns[8];
AST_MUTEX_DEFINE_STATIC(warn_lock);

static void conf_set_defaults(struct amd_ws_conf *c)
{
	/* amd.py SEND_TIMES (Jul 2026), MAX_WAIT_TIME, CONNECTION_TIMEOUT, FALLBACK_CHUNK_SIZE */
	static const int def_sched[] = { 500, 1000, 1500, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000 };
	int i;

	memset(c, 0, sizeof(*c));
	ast_copy_string(c->host, "127.0.0.1", sizeof(c->host));
	c->port = 2700;
	c->tls = 0;
	c->tls_verify = 1;
	c->tls_check_hostname = 0;
	c->timeout_ms = 10000;
	c->connect_timeout_ms = 10000;
	c->result_grace_ms = 0;
	for (i = 0; i < (int) ARRAY_LEN(def_sched); i++) {
		c->schedule[i] = def_sched[i];
	}
	c->n_schedule = ARRAY_LEN(def_sched);
	c->chunk_bytes = 8000;
	c->fallback_interval_ms = 1000;
	c->eof_no_audio_streak = 2;
	c->eof_wait_ms = 3000;
	c->send_caller_id = 1;
	c->trace = 0;
	c->playdelay_ms = 0;
#ifdef HAVE_MYSQL
	c->db = 1;
#else
	c->db = 0;
#endif
	c->db_timeout_ms = 1000;
	ast_copy_string(c->astguiclient_conf, "/etc/astguiclient.conf", sizeof(c->astguiclient_conf));
	c->extra_config[0] = '\0';
	c->max_pending_connects = DEF_MAX_PENDING;
}

/*! \brief Parse a positive int; returns 0 and leaves *out untouched on error */
static int parse_int(const char *val, int min, int max, int *out)
{
	char *end;
	long v;

	if (ast_strlen_zero(val)) {
		return 0;
	}
	v = strtol(val, &end, 10);
	while (*end && isspace((unsigned char) *end)) {
		end++;
	}
	if (*end || v < min || v > max) {
		return 0;
	}
	*out = (int) v;
	return 1;
}

/*! \brief "500,1000,1500" -> strictly increasing ms marks; returns 0 on error */
static int parse_schedule(const char *val, int *sched, int *n)
{
	char *copy = ast_strdupa(S_OR(val, ""));
	char *tok;
	int tmp[MAX_SCHEDULE];
	int count = 0, prev = 0;

	/* parse into a scratch array: on any error the caller's schedule stays untouched */
	while ((tok = strsep(&copy, ", "))) {
		int v;

		if (ast_strlen_zero(tok)) {
			continue;
		}
		if (count >= MAX_SCHEDULE) {
			ast_log(LOG_WARNING, "AMD_WS: send_schedule has more than %d entries\n", MAX_SCHEDULE);
			return 0;
		}
		if (!parse_int(tok, 1, 600000, &v) || v <= prev) {
			return 0;
		}
		tmp[count++] = v;
		prev = v;
	}
	if (!count) {
		return 0;
	}
	memcpy(sched, tmp, count * sizeof(*sched));
	*n = count;
	return 1;
}

/*! \brief Load amd_ws.conf into g_conf.  Missing file = defaults. */
static int load_config(int reload)
{
	struct ast_flags flags = { reload ? CONFIG_FLAG_FILEUNCHANGED : 0 };
	struct ast_config *cfg;
	struct ast_variable *v;
	struct amd_ws_conf c;

	cfg = ast_config_load("amd_ws.conf", flags);
	if (cfg == CONFIG_STATUS_FILEUNCHANGED) {
		return 0;
	}

	conf_set_defaults(&c);

	if (cfg == CONFIG_STATUS_FILEMISSING) {
		ast_debug(1, "AMD_WS: amd_ws.conf not found, using built-in defaults\n");
	} else if (cfg == CONFIG_STATUS_FILEINVALID) {
		ast_log(LOG_WARNING, "AMD_WS: amd_ws.conf is invalid, using built-in defaults\n");
		cfg = NULL;
	}

	for (v = cfg ? ast_variable_browse(cfg, "general") : NULL; v; v = v->next) {
		const char *name = v->name, *val = v->value;
		int ok = 1;

		if (!strcasecmp(name, "host")) {
			if (!ast_strlen_zero(val)) {
				ast_copy_string(c.host, val, sizeof(c.host));
			}
		} else if (!strcasecmp(name, "port")) {
			ok = parse_int(val, 1, 65535, &c.port);
		} else if (!strcasecmp(name, "tls")) {
			c.tls = ast_true(val) ? 1 : 0;
		} else if (!strcasecmp(name, "tls_verify")) {
			c.tls_verify = ast_false(val) ? 0 : 1;
		} else if (!strcasecmp(name, "tls_check_hostname")) {
			c.tls_check_hostname = ast_true(val) ? 1 : 0;
		} else if (!strcasecmp(name, "tls_cafile")) {
			ast_copy_string(c.tls_cafile, S_OR(val, ""), sizeof(c.tls_cafile));
		} else if (!strcasecmp(name, "timeout_ms")) {
			ok = parse_int(val, 1, 600000, &c.timeout_ms);
		} else if (!strcasecmp(name, "connect_timeout_ms")) {
			ok = parse_int(val, 1, 600000, &c.connect_timeout_ms);
		} else if (!strcasecmp(name, "result_grace_ms")) {
			ok = parse_int(val, 0, 600000, &c.result_grace_ms);
		} else if (!strcasecmp(name, "send_schedule")) {
			ok = parse_schedule(val, c.schedule, &c.n_schedule);
		} else if (!strcasecmp(name, "chunk_bytes")) {
			ok = parse_int(val, 320, 1000000, &c.chunk_bytes);
		} else if (!strcasecmp(name, "fallback_interval_ms")) {
			ok = parse_int(val, 1, 600000, &c.fallback_interval_ms);
		} else if (!strcasecmp(name, "eof_no_audio_streak")) {
			ok = parse_int(val, 0, MAX_SCHEDULE, &c.eof_no_audio_streak);
		} else if (!strcasecmp(name, "eof_wait_ms")) {
			ok = parse_int(val, 1, 600000, &c.eof_wait_ms);
		} else if (!strcasecmp(name, "send_caller_id")) {
			c.send_caller_id = ast_false(val) ? 0 : 1;
		} else if (!strcasecmp(name, "trace")) {
			c.trace = ast_true(val) ? 1 : 0;
		} else if (!strcasecmp(name, "playdelay_ms")) {
			ok = parse_int(val, 0, 600000, &c.playdelay_ms);
		} else if (!strcasecmp(name, "db")) {
			c.db = ast_true(val) ? 1 : 0;
#ifndef HAVE_MYSQL
			if (c.db) {
				ast_log(LOG_NOTICE, "AMD_WS: db=yes requested but the module was built without MySQL support\n");
				c.db = 0;
			}
#endif
		} else if (!strcasecmp(name, "db_timeout_ms")) {
			ok = parse_int(val, 1, 60000, &c.db_timeout_ms);
		} else if (!strcasecmp(name, "astguiclient_conf")) {
			if (!ast_strlen_zero(val)) {
				ast_copy_string(c.astguiclient_conf, val, sizeof(c.astguiclient_conf));
			}
		} else if (!strcasecmp(name, "extra_config")) {
			/* must be a JSON object: {"key":value,...}; spliced verbatim into "config" */
			const char *v0 = ast_skip_blanks(S_OR(val, ""));
			size_t vl = strlen(v0);

			while (vl > 0 && isspace((unsigned char) v0[vl - 1])) {
				vl--;
			}
			if (vl == 0) {
				c.extra_config[0] = '\0';
			} else if (vl >= 2 && v0[0] == '{' && v0[vl - 1] == '}' && vl < sizeof(c.extra_config)) {
				ast_copy_string(c.extra_config, v0, vl + 1);
			} else {
				ok = 0;
			}
		} else if (!strcasecmp(name, "max_pending_connects")) {
			ok = parse_int(val, 8, 1024, &c.max_pending_connects);
		} else {
			ast_log(LOG_WARNING, "AMD_WS: amd_ws.conf: unknown option '%s' at line %d, ignored (removed in 2.0? see amd_ws.conf.sample)\n", name, v->lineno);
		}
		if (!ok) {
			ast_log(LOG_WARNING, "AMD_WS: amd_ws.conf: invalid value '%s' for '%s' at line %d, ignored\n",
				S_OR(val, ""), name, v->lineno);
		}
	}
	if (cfg) {
		ast_config_destroy(cfg);
	}

	ast_mutex_lock(&conf_lock);
	g_conf = c;
	ast_mutex_unlock(&conf_lock);
	return 0;
}

static void conf_snapshot(struct amd_ws_conf *out)
{
	ast_mutex_lock(&conf_lock);
	*out = g_conf;
	ast_mutex_unlock(&conf_lock);
}

/*! \brief Return 1 if a warning for this host may be logged now (once per CONNECT_WARN_S) */
static int connect_warn_allowed(const char *host)
{
	time_t now = time(NULL);
	int i, oldest = 0, allowed = 0;

	ast_mutex_lock(&warn_lock);
	for (i = 0; i < (int) ARRAY_LEN(connect_warns); i++) {
		if (!strcmp(connect_warns[i].host, host)) {
			if (now - connect_warns[i].last >= CONNECT_WARN_S) {
				connect_warns[i].last = now;
				allowed = 1;
			}
			ast_mutex_unlock(&warn_lock);
			return allowed;
		}
		if (connect_warns[i].last < connect_warns[oldest].last) {
			oldest = i;
		}
	}
	ast_copy_string(connect_warns[oldest].host, host, sizeof(connect_warns[oldest].host));
	connect_warns[oldest].last = now;
	ast_mutex_unlock(&warn_lock);
	return 1;
}

/*! \brief Slot of host (pending_lock held); create one when create is set. -1 when none. */
static int pending_slot_of(const char *host, int create)
{
	int i, free_slot = -1;

	for (i = 0; i < MAX_PENDING_HOSTS; i++) {
		if (pending_hosts[i].count > 0 && !strcmp(pending_hosts[i].host, host)) {
			return i;
		}
		if (free_slot < 0 && pending_hosts[i].count == 0) {
			free_slot = i;
		}
	}
	if (!create || free_slot < 0) {
		return -1;   /* > MAX_PENDING_HOSTS hosts parked at once: never counted, never refused */
	}
	ast_copy_string(pending_hosts[free_slot].host, host, sizeof(pending_hosts[free_slot].host));
	pending_hosts[free_slot].last_warn = 0;
	return free_slot;
}

/*!
 * \brief Is the per-host cap of parked helpers reached?  *warn is set when the
 *        rate-limited (PENDING_WARN_S) warning may be logged.
 */
static int pending_cap_reached(const char *host, int max, int *warn)
{
	int slot, reached = 0;

	*warn = 0;
	ast_mutex_lock(&pending_lock);
	slot = pending_slot_of(host, 0);
	if (slot >= 0 && pending_hosts[slot].count >= max) {
		time_t now = time(NULL);

		reached = 1;
		if (now - pending_hosts[slot].last_warn >= PENDING_WARN_S) {
			pending_hosts[slot].last_warn = now;
			*warn = 1;
		}
	}
	ast_mutex_unlock(&pending_lock);
	return reached;
}

/*! \brief The call gave up on a still-pending connect: its helper is now parked. */
static void pending_park(const char *host)
{
	int slot;

	ast_mutex_lock(&pending_lock);
	slot = pending_slot_of(host, 1);
	if (slot >= 0) {
		pending_hosts[slot].count++;
		pending_total++;
	}
	ast_mutex_unlock(&pending_lock);
}

/*! \brief A parked helper ended (the peer closed, or the connect finally completed). */
static void pending_unpark(const char *host)
{
	int slot;

	ast_mutex_lock(&pending_lock);
	slot = pending_slot_of(host, 0);
	if (slot >= 0) {
		pending_hosts[slot].count--;
		pending_total--;
	}
	ast_mutex_unlock(&pending_lock);
}

/* ------------------------------------------------------------------------
 * DB lookup (ViciDial phone / country enrichment) -- optional
 * ---------------------------------------------------------------------- */

struct db_creds {
	char server[256];
	char database[128];
	char user[128];
	char pass[256];
	int port;
	int loaded;     /* 1 if the file was read */
	int keys;       /* VARDB_* lines found; 0 = no config, no lookup (amd.py:95-97) */
};

static struct db_creds g_db_creds;   /* protected by conf_lock */

/*!
 * \brief Parse /etc/astguiclient.conf VARDB_* lines the way ViciDial does.
 *
 * Tolerates tabs, trailing whitespace, inline '#'/';' comments (when preceded by
 * whitespace or at line start) and '=>' inside values (split on the first one).
 * Credentials are never logged.  When the file cannot be read, loaded stays 0;
 * when it has no VARDB_ line at all, keys stays 0.  Either way db_lookup()
 * skips the DB entirely (no connection attempts with the built-in defaults),
 * exactly as amd.py's "DB ERROR: no config" (amd.py:95-97); with the lookup
 * enabled this is said once at load/reload.
 */
static void load_db_creds(const char *path, int db_enabled)
{
	struct db_creds c;
	FILE *f;
	char line[1024];

	memset(&c, 0, sizeof(c));
	ast_copy_string(c.server, "localhost", sizeof(c.server));
	ast_copy_string(c.database, "asterisk", sizeof(c.database));
	ast_copy_string(c.user, "cron", sizeof(c.user));
	c.port = 3306;

	f = fopen(path, "r");
	if (f) {
		c.loaded = 1;
		while (fgets(line, sizeof(line), f)) {
			char *p, *arrow, *key, *val;

			line[strcspn(line, "\r\n")] = '\0';
			/* strip inline comments: '#' or ';' at line start or after whitespace */
			for (p = line; *p; p++) {
				if ((*p == '#' || *p == ';') && (p == line || isspace((unsigned char) p[-1]))) {
					*p = '\0';
					break;
				}
			}
			key = ast_skip_blanks(line);
			if (strncmp(key, "VARDB_", 6)) {
				continue;
			}
			arrow = strstr(key, "=>");
			if (!arrow) {
				continue;
			}
			*arrow = '\0';
			val = ast_strip(arrow + 2);
			key = ast_strip(key);
			c.keys++;

			if (!strcmp(key, "VARDB_server")) {
				ast_copy_string(c.server, val, sizeof(c.server));
			} else if (!strcmp(key, "VARDB_database")) {
				ast_copy_string(c.database, val, sizeof(c.database));
			} else if (!strcmp(key, "VARDB_user")) {
				ast_copy_string(c.user, val, sizeof(c.user));
			} else if (!strcmp(key, "VARDB_pass")) {
				ast_copy_string(c.pass, val, sizeof(c.pass));
			} else if (!strcmp(key, "VARDB_port")) {
				if (!parse_int(val, 1, 65535, &c.port)) {
					c.port = 3306;
				}
			}
		}
		fclose(f);
		if (!c.keys && db_enabled) {
			ast_log(LOG_NOTICE, "AMD_WS: %s has no VARDB_ lines - the phone/country DB lookup is skipped until they exist and the module is reloaded\n", path);
		}
	} else if (db_enabled) {
		ast_log(LOG_NOTICE, "AMD_WS: cannot read %s: %s - the phone/country DB lookup is skipped until the file is readable and the module reloaded\n",
			path, strerror(errno));
	} else {
		ast_debug(1, "AMD_WS: cannot read %s: %s (DB lookup disabled anyway)\n", path, strerror(errno));
	}

	ast_mutex_lock(&conf_lock);
	g_db_creds = c;
	ast_mutex_unlock(&conf_lock);
}

#ifdef HAVE_MYSQL

static MYSQL *db_conn;                 /* persistent connection, under db_lock */
static time_t db_last_warn;            /* under db_lock */
static time_t db_fail_until;           /* under db_lock: skip the DB until then */
AST_MUTEX_DEFINE_STATIC(db_lock);

static void db_warn(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void db_warn(const char *fmt, ...)
{
	/* called with db_lock held */
	time_t now = time(NULL);
	va_list ap;
	char buf[512];

	if (now - db_last_warn < DB_WARN_S) {
		return;
	}
	db_last_warn = now;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	ast_log(LOG_WARNING, "AMD_WS: %s (further DB warnings suppressed for %d s)\n", buf, DB_WARN_S);
}

/*! \brief Connect the persistent connection; db_lock held.  Returns 0 on success. */
static int db_connect_locked(int timeout_ms)
{
	struct db_creds creds;
	unsigned int secs = (timeout_ms + 999) / 1000;

	if (secs < 1) {
		secs = 1;
	}

	ast_mutex_lock(&conf_lock);
	creds = g_db_creds;
	ast_mutex_unlock(&conf_lock);

	db_conn = mysql_init(NULL);
	if (!db_conn) {
		db_warn("mysql_init failed");
		return -1;
	}
	mysql_options(db_conn, MYSQL_OPT_CONNECT_TIMEOUT, &secs);
	mysql_options(db_conn, MYSQL_OPT_READ_TIMEOUT, &secs);
	mysql_options(db_conn, MYSQL_OPT_WRITE_TIMEOUT, &secs);

	if (!mysql_real_connect(db_conn, creds.server, creds.user, creds.pass,
			creds.database, creds.port, NULL, 0)) {
		db_warn("DB connect to %s:%d failed: %s", creds.server, creds.port, mysql_error(db_conn));
		mysql_close(db_conn);
		db_conn = NULL;
		db_fail_until = time(NULL) + DB_BACKOFF_S;
		return -1;
	}
	ast_debug(1, "AMD_WS: DB connected to %s:%d/%s\n", creds.server, creds.port, creds.database);
	return 0;
}

/*!
 * \brief Look up phone_code/phone_number for a ViciDial callerid (VID).
 *
 * Runs on the connect helper thread, never on the PBX thread.  Bounded: the
 * mutex is acquired with a deadline of timeout_ms, the connection uses
 * connect/read/write timeouts of ceil(timeout_ms / 1000) s each, and after a
 * failure the DB is skipped for DB_BACKOFF_S so a dead DB costs at most one
 * timeout, not one per call.  A connection the server dropped meanwhile
 * (wait_timeout: CR_SERVER_GONE_ERROR / CR_SERVER_LOST) is reconnected once
 * within the same deadline instead of starting the backoff.  Any problem is
 * logged at WARNING once per minute and the call continues without phone.
 * Returns 0 when a row was found.
 */
static int db_lookup(const char *vid, int timeout_ms, char *phone, size_t phone_sz, char *code, size_t code_sz)
{
	struct timeval start = ast_tvnow();
	char escaped[2 * MAX_VID_LEN + 1];
	char query[sizeof(escaped) + 160];
	MYSQL_RES *res;
	MYSQL_ROW row;
	unsigned long elen;
	int found = -1, loaded;

	phone[0] = '\0';
	code[0] = '\0';

	ast_mutex_lock(&conf_lock);
	loaded = g_db_creds.loaded && g_db_creds.keys;
	ast_mutex_unlock(&conf_lock);
	if (!loaded) {
		return -1;   /* astguiclient.conf unreadable or without VARDB_ lines: said once at load/reload */
	}

	/* Acquire the lock with a deadline: never wait longer than db_timeout_ms */
	while (ast_mutex_trylock(&db_lock)) {
		if (ast_tvdiff_ms(ast_tvnow(), start) >= timeout_ms) {
			ast_debug(1, "AMD_WS: DB busy for %d ms, skipping lookup\n", timeout_ms);
			return -1;
		}
		usleep(1000);
	}

	if (db_fail_until && time(NULL) < db_fail_until) {
		ast_mutex_unlock(&db_lock);
		return -1;
	}

	mysql_thread_init();

	if (!db_conn && db_connect_locked(timeout_ms)) {
		goto done;
	}

	escaped[0] = '\0';
	elen = mysql_real_escape_string(db_conn, escaped, vid, strlen(vid));
	if (elen == (unsigned long) -1) {
		db_warn("mysql_real_escape_string failed");
		goto done;
	}
	snprintf(query, sizeof(query),
		"SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid='%s' ORDER BY auto_call_id DESC LIMIT 1",
		escaped);

	if (mysql_query(db_conn, query)) {
		unsigned int e = mysql_errno(db_conn);

		if ((e == CR_SERVER_GONE_ERROR || e == CR_SERVER_LOST)
			&& ast_tvdiff_ms(ast_tvnow(), start) < timeout_ms) {
			/* idle connection dropped by the server (wait_timeout): one reconnect, same deadline */
			ast_debug(1, "AMD_WS: DB connection gone (%u), reconnecting\n", e);
			mysql_close(db_conn);
			db_conn = NULL;
			if (db_connect_locked(timeout_ms)) {
				goto done;   /* backoff set by db_connect_locked */
			}
			if (!mysql_query(db_conn, query)) {
				goto fetch;
			}
		}
		db_warn("DB query failed: %s", mysql_error(db_conn));
		mysql_close(db_conn);      /* manual reconnect on the next call */
		db_conn = NULL;
		db_fail_until = time(NULL) + DB_BACKOFF_S;
		goto done;
	}
fetch:
	res = mysql_store_result(db_conn);
	if (res) {
		row = mysql_fetch_row(res);
		if (row) {
			if (row[0]) {
				ast_copy_string(code, row[0], code_sz);
			}
			if (row[1]) {
				ast_copy_string(phone, row[1], phone_sz);
			}
			found = 0;
		}
		mysql_free_result(res);
	}

done:
	mysql_thread_end();
	ast_mutex_unlock(&db_lock);
	return found;
}

static void db_shutdown(void)
{
	ast_mutex_lock(&db_lock);
	if (db_conn) {
		mysql_close(db_conn);
		db_conn = NULL;
	}
	ast_mutex_unlock(&db_lock);
	/* No mysql_library_end(): other modules (res_config_mysql, cdr_mysql) may share the library. */
}

#endif /* HAVE_MYSQL */

static const char *db_availability(void)
{
#ifdef HAVE_MYSQL
	return "available";
#else
	return "unavailable (built without MySQL)";
#endif
}

/* ------------------------------------------------------------------------
 * JSON escaping / classification / sanitising
 * ---------------------------------------------------------------------- */

/*!
 * \brief Length of a valid UTF-8 sequence starting at s (1..4), or 0 if invalid.
 */
static int utf8_seq_len(const unsigned char *s)
{
	unsigned char c = s[0];

	if (c < 0x80) {
		return 1;
	}
	if (c >= 0xC2 && c <= 0xDF) {
		return (s[1] & 0xC0) == 0x80 ? 2 : 0;
	}
	if (c >= 0xE0 && c <= 0xEF) {
		if ((s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80) {
			return 0;
		}
		if (c == 0xE0 && s[1] < 0xA0) {
			return 0; /* overlong */
		}
		if (c == 0xED && s[1] >= 0xA0) {
			return 0; /* UTF-16 surrogate */
		}
		return 3;
	}
	if (c >= 0xF0 && c <= 0xF4) {
		if ((s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80) {
			return 0;
		}
		if (c == 0xF0 && s[1] < 0x90) {
			return 0; /* overlong */
		}
		if (c == 0xF4 && s[1] >= 0x90) {
			return 0; /* > U+10FFFF */
		}
		return 4;
	}
	return 0;
}

/*!
 * \brief JSON-escape src into dst.
 *
 * Escapes '"', '\\' and control characters; passes valid UTF-8 through and
 * replaces invalid bytes with '?' so the TEXT frame is always valid UTF-8.
 * \retval length written (excluding NUL), -1 if dst is too small.
 */
static int json_escape(char *dst, size_t dst_size, const char *src)
{
	const unsigned char *s = (const unsigned char *) src;
	size_t pos = 0;

	while (*s) {
		const char *esc = NULL;
		char hex[8];
		int n;

		switch (*s) {
		case '"':  esc = "\\\""; break;
		case '\\': esc = "\\\\"; break;
		case '\b': esc = "\\b";  break;
		case '\f': esc = "\\f";  break;
		case '\n': esc = "\\n";  break;
		case '\r': esc = "\\r";  break;
		case '\t': esc = "\\t";  break;
		default:
			if (*s < 0x20) {
				snprintf(hex, sizeof(hex), "\\u%04x", *s);
				esc = hex;
			}
		}
		if (esc) {
			size_t elen = strlen(esc);

			if (pos + elen >= dst_size) {
				return -1;
			}
			memcpy(dst + pos, esc, elen);
			pos += elen;
			s++;
			continue;
		}
		n = utf8_seq_len(s);
		if (!n) {
			if (pos + 1 >= dst_size) {
				return -1;
			}
			dst[pos++] = '?';
			s++;
			continue;
		}
		if (pos + n >= dst_size) {
			return -1;
		}
		memcpy(dst + pos, s, n);
		pos += n;
		s += n;
	}
	dst[pos] = '\0';
	return (int) pos;
}

/*! \brief Case-sensitive substring search over a byte range (embedded NULs allowed, like python's "in") */
static const char *find_sub(const char *hay, size_t len, const char *needle)
{
	size_t nlen = strlen(needle);
	const char *p, *end;

	if (nlen > len) {
		return NULL;
	}
	for (p = hay, end = hay + len - nlen; p <= end; p++) {
		if (*p == needle[0] && !memcmp(p, needle, nlen)) {
			return p;
		}
	}
	return NULL;
}

enum classification {
	CLASS_ACK = 0,      /* keep going */
	CLASS_HUMAN,
	CLASS_MACHINE,
};

/*!
 * \brief Classify a server TEXT message exactly like amd.py (Jul 2026):
 *
 *   if 'HUMAN' in text:                       HUMAN
 *   elif 'AMD' in text or 'MACHINE' in text:  MACHINE
 *   else:                                     ack, keep going
 *
 * Case-sensitive substring semantics, so "NOT_HUMAN" is HUMAN and "amd" is an
 * ack, as in production.  One guard on top of amd.py: an "AMD" immediately
 * followed by 'Y' is the brand name ("AMDY ack") and does not count.  Any
 * other reply (HONEYPOT, "{}", "ack", ...) is an acknowledgement.
 */
static enum classification classify_text(const char *text, size_t len)
{
	const char *p = text, *end = text + len;

	/* amd_server "stage_results" progress frames (STAGE-<stage>-<CLS>-<dur>-<conf>) are interim */
	if (len >= 6 && !strncmp(text, "STAGE-", 6)) {
		return CLASS_ACK;
	}
	if (find_sub(text, len, "HUMAN")) {
		return CLASS_HUMAN;
	}
	while ((p = find_sub(p, end - p, "AMD"))) {
		if (p + 3 >= end || p[3] != 'Y') {
			return CLASS_MACHINE;
		}
		p += 3;
	}
	if (find_sub(text, len, "MACHINE")) {
		return CLASS_MACHINE;
	}
	return CLASS_ACK;
}

/*! \brief Copy printable ASCII only (max MAX_RESPONSE chars) for AMDRESPONSE */
static void sanitize_response(const char *text, size_t len, char *out, size_t out_sz)
{
	size_t i, o = 0;

	for (i = 0; i < len && o + 1 < out_sz && o < MAX_RESPONSE; i++) {
		unsigned char c = (unsigned char) text[i];

		if (c >= 0x20 && c <= 0x7E) {
			out[o++] = (char) c;
		}
	}
	out[o] = '\0';
}

/* ------------------------------------------------------------------------
 * WebSocket helpers
 * ---------------------------------------------------------------------- */

static const char *ws_result_str(enum ast_websocket_result r)
{
	switch (r) {
	case WS_OK:                 return "ok";
	case WS_ALLOCATE_ERROR:     return "allocation error";
	case WS_KEY_ERROR:          return "key error";
	case WS_URI_PARSE_ERROR:    return "URI parse error";
	case WS_URI_RESOLVE_ERROR:  return "DNS resolve error";
	case WS_BAD_STATUS:         return "bad HTTP status";
	case WS_INVALID_RESPONSE:   return "invalid HTTP response";
	case WS_BAD_REQUEST:        return "400 bad request";
	case WS_URL_NOT_FOUND:      return "404 not found";
	case WS_HEADER_MISMATCH:    return "handshake header mismatch";
	case WS_HEADER_MISSING:     return "handshake header missing";
	case WS_NOT_SUPPORTED:      return "not supported";
	case WS_WRITE_ERROR:        return "write error";
	case WS_CLIENT_START_ERROR: return "connect failed/timed out";
	default:                    break;   /* newer cores add values (e.g. WS_UNAUTHORIZED) */
	}
	return "unknown";
}

/*! \brief Free a TLS config that the WebSocket client did NOT take ownership of */
static void tls_cfg_free(struct ast_tls_config *tls)
{
	if (!tls) {
		return;
	}
	ast_free(tls->certfile);
	ast_free(tls->pvtfile);
	ast_free(tls->cipher);
	ast_free(tls->cafile);
	ast_free(tls->capath);
	ast_free(tls);
}

/*!
 * \brief Build the TLS config for wss://.
 *
 * The websocket client's session args take ownership of the struct and free
 * every member with ast_free(), so all members must be ast_strdup()ed or NULL.
 * Hostname verification is off by default: Asterisk 16's client never fills
 * the hostname used for the CN check, so it would always fail there.  Set
 * tls_check_hostname=yes on 18+ if wanted.
 */
static struct ast_tls_config *tls_cfg_create(const struct amd_ws_conf *conf)
{
	static const char *ca_bundles[] = {
		"/etc/ssl/certs/ca-certificates.crt",     /* Debian/Ubuntu, openSUSE */
		"/etc/pki/tls/certs/ca-bundle.crt",       /* RHEL family */
		"/etc/ssl/ca-bundle.pem",                 /* SLES/openSUSE */
		"/etc/ssl/cert.pem",
	};
	struct ast_tls_config *tls = ast_calloc(1, sizeof(*tls));
	size_t i;

	if (!tls) {
		return NULL;
	}
	tls->enabled = 1;
	if (conf->tls_verify) {
		if (!ast_strlen_zero(conf->tls_cafile)) {
			tls->cafile = ast_strdup(conf->tls_cafile);
		} else {
			for (i = 0; i < ARRAY_LEN(ca_bundles); i++) {
				if (!access(ca_bundles[i], R_OK)) {
					tls->cafile = ast_strdup(ca_bundles[i]);
					break;
				}
			}
			if (!tls->cafile) {
				tls->capath = ast_strdup("/etc/ssl/certs");
			}
		}
		if (!conf->tls_check_hostname) {
			ast_set_flag(&tls->flags, AST_SSL_IGNORE_COMMON_NAME);
		}
	} else {
		ast_set_flag(&tls->flags, AST_SSL_DONT_VERIFY_SERVER);
		ast_set_flag(&tls->flags, AST_SSL_IGNORE_COMMON_NAME);
	}
	return tls;
}

/*!
 * \brief A connect job handed to a helper thread.
 *
 * ast_websocket_client_create_with_options() blocks for DNS + TCP + handshake.
 * Only the TCP connect honours .timeout; a server that accepts the TCP
 * connection and never answers the HTTP upgrade would block forever.  The PBX
 * thread therefore waits on this job with its own deadline while servicing
 * the channel, and abandons it when the deadline passes.  Whoever drops the
 * last reference frees the job; an abandoned job's websocket is closed by
 * the helper.
 *
 * The optional DB enrichment runs on the helper right before the connect
 * (results in phone/country, valid once state == JOB_DONE), so a stalled DB
 * never blocks the channel thread.
 */
enum job_state {
	JOB_PENDING = 0,
	JOB_DONE,
	JOB_ABANDONED,
};

struct connect_job {
	ast_mutex_t lock;
	int refs;
	enum job_state state;
	struct ast_websocket *ws;
	enum ast_websocket_result wr;
	struct ast_tls_config *tls_cfg;   /* owned by the ws client once args are created */
	int timeout_ms;
	char host[256];                   /* for the parked-helper accounting */
	char uri[600];
	char chan_name[AST_CHANNEL_NAME];
	/* DB enrichment (helper thread) */
	int do_db;
	int db_timeout_ms;
	char vid[MAX_VID_LEN + 1];
	char phone[64];
	char country[32];
};

static void job_unref(struct connect_job *job)
{
	int left;

	ast_mutex_lock(&job->lock);
	left = --job->refs;
	ast_mutex_unlock(&job->lock);
	if (!left) {
		ast_mutex_destroy(&job->lock);
		ast_free(job);
	}
}

/*!
 * \brief Run the optional DB lookup and the blocking connect; result into job->ws / job->wr.
 * \retval JOB_DONE the outcome was handed to the call
 * \retval JOB_ABANDONED the call had given up meanwhile (a late socket was closed here)
 */
static enum job_state job_connect(struct connect_job *job)
{
	struct ast_websocket_client_options opts = {
		.uri = job->uri,
		.protocols = NULL,
		.timeout = job->timeout_ms,
		.tls_cfg = job->tls_cfg,
	};
	enum ast_websocket_result wr = (enum ast_websocket_result) -1; /* stays -1 if the OPTIONAL_API stub ran */
	struct ast_websocket *ws;

#ifdef HAVE_MYSQL
	if (job->do_db) {
		if (!db_lookup(job->vid, job->db_timeout_ms, job->phone, sizeof(job->phone), job->country, sizeof(job->country))) {
			ast_debug(2, "AMD_WS: %s DB phone=%s country=%s\n", job->chan_name, job->phone, job->country);
		} else {
			ast_debug(2, "AMD_WS: %s no DB row for vid=%s\n", job->chan_name, job->vid);
		}
	}
#endif

	ws = ast_websocket_client_create_with_options(&opts, &wr);

	if (!ws && job->tls_cfg) {
		/*
		 * Ownership of tls_cfg passes to the client's session args.  When the
		 * client failed before creating them (allocation, key, URI parse, or
		 * the API stub) nobody else frees it.
		 */
		if ((int) wr == -1 || wr == WS_ALLOCATE_ERROR || wr == WS_KEY_ERROR || wr == WS_URI_PARSE_ERROR) {
			tls_cfg_free(job->tls_cfg);
		}
	}
	job->tls_cfg = NULL;

	ast_mutex_lock(&job->lock);
	job->wr = wr;
	if (job->state == JOB_ABANDONED) {
		ast_mutex_unlock(&job->lock);
		if (ws) {
			ast_debug(1, "AMD_WS: %s late connect to %s discarded\n", job->chan_name, job->uri);
			ast_websocket_close(ws, 1000);
			ast_websocket_unref(ws);
		}
		return JOB_ABANDONED;
	}
	job->ws = ws;
	job->state = JOB_DONE;
	ast_mutex_unlock(&job->lock);
	return JOB_DONE;
}

static void *connect_thread(void *data)
{
	struct connect_job *job = data;

	if (job_connect(job) == JOB_ABANDONED) {
		pending_unpark(job->host);   /* always after job_abandon()'s pending_park(): see there */
	}
	job_unref(job);
	ast_atomic_fetchadd_int(&inflight_helpers, -1);
	ast_module_unref(AST_MODULE_SELF);
	return NULL;
}

/*!
 * \brief Poll the job: returns JOB_DONE (ws taken into *ws, may be NULL; *wr and
 *        job->phone/country valid) or JOB_PENDING.
 */
static enum job_state job_poll(struct connect_job *job, struct ast_websocket **ws, enum ast_websocket_result *wr)
{
	enum job_state st;

	ast_mutex_lock(&job->lock);
	st = job->state;
	if (st == JOB_DONE) {
		*ws = job->ws;
		*wr = job->wr;
		job->ws = NULL;
	}
	ast_mutex_unlock(&job->lock);
	return st;
}

/*!
 * \brief Give up on the job.  If it completed meanwhile the outcome is handed
 *        over exactly like job_poll() (JOB_DONE, ws may be NULL with the real
 *        failure in *wr); otherwise it is marked JOB_ABANDONED and the helper
 *        disposes of whatever it still produces.
 */
static enum job_state job_abandon(struct connect_job *job, struct ast_websocket **ws, enum ast_websocket_result *wr)
{
	enum job_state st;

	ast_mutex_lock(&job->lock);
	if (job->state == JOB_DONE) {
		*ws = job->ws;
		*wr = job->wr;
		job->ws = NULL;
	} else {
		job->state = JOB_ABANDONED;
		/*
		 * Counted while job->lock is held: the helper only sees ABANDONED
		 * after this unlock, so its pending_unpark() always follows this
		 * pending_park() (lock order job->lock -> pending_lock, nowhere else).
		 */
		pending_park(job->host);
	}
	st = job->state;
	ast_mutex_unlock(&job->lock);
	return st;
}

/* ------------------------------------------------------------------------
 * Per-call state
 * ---------------------------------------------------------------------- */

enum {
	OPT_NODB      = (1 << 0),
	OPT_TLS       = (1 << 1),
	OPT_PLAYDELAY = (1 << 2),
	OPT_CONNTO    = (1 << 3),
	OPT_PHONE     = (1 << 4),
	OPT_CODE      = (1 << 5),
	OPT_ANSWER    = (1 << 6),
	OPT_NOANSWER  = (1 << 7),
	OPT_CALLERID  = (1 << 8),
	OPT_TRACE     = (1 << 9),
};

enum {
	OPT_ARG_PLAYDELAY = 0,
	OPT_ARG_CONNTO,
	OPT_ARG_PHONE,
	OPT_ARG_CODE,
	OPT_ARG_CALLERID,
	OPT_ARG_ARRAY_SIZE,
};

AST_APP_OPTIONS(amd_ws_options, {
	AST_APP_OPTION('n', OPT_NODB),
	AST_APP_OPTION('s', OPT_TLS),
	AST_APP_OPTION_ARG('d', OPT_PLAYDELAY, OPT_ARG_PLAYDELAY),
	AST_APP_OPTION_ARG('c', OPT_CONNTO, OPT_ARG_CONNTO),
	AST_APP_OPTION_ARG('p', OPT_PHONE, OPT_ARG_PHONE),
	AST_APP_OPTION_ARG('k', OPT_CODE, OPT_ARG_CODE),
	AST_APP_OPTION_ARG('i', OPT_CALLERID, OPT_ARG_CALLERID),
	AST_APP_OPTION('a', OPT_ANSWER),
	AST_APP_OPTION('A', OPT_NOANSWER),
	AST_APP_OPTION('v', OPT_TRACE),
});

enum call_phase {
	PHASE_CONNECT = 0,   /* helper thread connecting; channel already read */
	PHASE_STREAM,        /* connected, config sent, sending on schedule */
	PHASE_EOF_WAIT,      /* {"eof":1} sent after empty marks; waiting eof_wait_ms for ONE reply */
	PHASE_GRACE,         /* timeout_ms elapsed; waiting result_grace_ms for a reply */
};

enum play_state {
	PLAY_NONE = 0,       /* no playfile given */
	PLAY_WAIT_DELAY,     /* waiting for playdelay_ms */
	PLAY_PLAYING,        /* a file stream is active */
	PLAY_DONE,           /* list exhausted or stopped */
};

struct amd_call {
	struct ast_channel *chan;
	struct amd_ws_conf conf;          /* snapshot for this call */

	/* effective parameters */
	char host[256];
	int port;
	char vid[MAX_VID_LEN + 1];
	int timeout_ms;
	int connect_timeout_ms;
	int playdelay_ms;
	int use_tls;
	char phone[64];
	char country[32];
	char caller_id[MAX_CALLERID_LEN + 1];
	char *playlist;                   /* '&'-separated, consumed by strsep */
	const char *playfile_display;

	/* transport */
	struct connect_job *job;
	struct ast_websocket *ws;
	int wsfd;
	int ws_lost;                      /* CLOSE/error seen */

	/* clocks */
	struct timeval t_app;
	struct timeval t_connect;         /* connect job started (connect deadline runs from here) */
	struct timeval t_first;           /* first voice frame; zero if none yet */
	struct timeval t_last_send;       /* last audio send (t_first until then): fallback interval */
	struct timeval t_eof;             /* EOF finalisation started */
	int have_audio;

	/* audio accumulator (heap) */
	unsigned char *acc;
	size_t acc_cap;
	size_t acc_len;
	int sched_idx;                    /* next schedule mark to fire */
	int no_audio_streak;              /* consecutive marks with nothing pending (amd.py no_audio_streak) */

	/* server text (heap) */
	char *rx;
	size_t rx_len;

	/* stats */
	long bytes_captured;
	long bytes_sent;
	long bytes_dropped;
	int chunks;                       /* binary frames sent */
	int acks;                         /* non-terminal replies */
	int replies;                      /* complete text replies of any kind */

	/* outcome */
	enum call_phase phase;
	int got_result;
	char status[STATUS_TOKEN_LEN];
	char cause[CAUSE_LEN];
	char response[MAX_RESPONSE + 1];

	/* playback */
	enum play_state play;

	int trace;                        /* option v / conf trace: timeline lines at verbose 3 */
};

/*!
 * \brief One timeline line per event: "AMD_WS: <chan> +<ms> <event>" at verbose 3 when
 * tracing is on (option v or conf trace=yes), otherwise at debug 2. The offset is
 * measured from the start of the application, so a call reads as a timeline.
 */
#define amd_trace(c, fmt, ...) do { \
	if ((c)->trace) { \
		ast_verb(3, "AMD_WS: %s vid=%s +%" PRId64 "ms " fmt "\n", ast_channel_name((c)->chan), (c)->vid, \
			ast_tvdiff_ms(ast_tvnow(), (c)->t_app), ##__VA_ARGS__); \
	} else { \
		ast_debug(2, "AMD_WS: %s vid=%s " fmt "\n", ast_channel_name((c)->chan), (c)->vid, ##__VA_ARGS__); \
	} \
} while (0)

/* ------------------------------------------------------------------------
 * Audio accumulator
 * ---------------------------------------------------------------------- */

/*!
 * \brief Append captured PCM; never truncates a frame.
 *
 * The accumulator is sized for connect_timeout + the largest schedule gap
 * (+ slack), so it only fills when something is badly wrong; then it grows
 * up to ACC_HARD_CAP and beyond that drops are counted and logged once.
 */
static void acc_append(struct amd_call *c, const unsigned char *data, size_t len)
{
	if (c->acc_len + len > c->acc_cap) {
		size_t ncap = c->acc_cap * 2;
		unsigned char *n;

		while (ncap < c->acc_len + len) {
			ncap *= 2;
		}
		if (ncap > ACC_HARD_CAP || !(n = ast_realloc(c->acc, ncap))) {
			if (!c->bytes_dropped) {
				ast_log(LOG_WARNING, "AMD_WS: %s audio backlog full (%zu bytes), dropping audio\n",
					ast_channel_name(c->chan), c->acc_len);
			}
			c->bytes_dropped += len;
			return;
		}
		c->acc = n;
		c->acc_cap = ncap;
	}
	memcpy(c->acc + c->acc_len, data, len);
	c->acc_len += len;
	c->no_audio_streak = 0;   /* amd.py: "Reset streak when audio arrives" */
}

/*!
 * \brief Send everything accumulated as BINARY frame(s).
 * \retval 0 ok, -1 write error (connection is lost).
 */
static int acc_flush(struct amd_call *c, struct timeval now)
{
	size_t off = 0;

	if (!c->ws || c->ws_lost) {
		return -1;
	}
	while (off < c->acc_len) {
		size_t n = c->acc_len - off;

		if (n > WS_MAX_FRAME_BYTES) {
			n = WS_MAX_FRAME_BYTES;
		}
		if (ast_websocket_write(c->ws, AST_WEBSOCKET_OPCODE_BINARY, (char *) c->acc + off, n)) {
			ast_debug(1, "AMD_WS: %s websocket write of %zu bytes failed\n", ast_channel_name(c->chan), n);
			c->ws_lost = 1;
			c->acc_len = 0;
			return -1;
		}
		c->bytes_sent += n;
		c->chunks++;
		off += n;
	}
	amd_trace(c, "sent chunk #%d: %zu bytes (audio %ld ms total, %ld bytes)",
		c->chunks, c->acc_len, c->bytes_sent / 16, c->bytes_sent);
	c->acc_len = 0;
	c->t_last_send = now;
	return 0;
}

enum sched_result {
	SCHED_OK = 0,        /* nothing decisive (sent or not) */
	SCHED_EOF = 1,       /* start the EOF finalisation */
	SCHED_LOST = -1,     /* write error: connection lost */
};

/*!
 * \brief Fire due schedule marks / fallback sends.  Called when connected.
 *
 * amd.py (Jul 2026) semantics: at each mark send everything accumulated so
 * far; a mark with nothing pending is a "NO AUDIO DATA" mark and counts
 * toward no_audio_streak (any captured audio resets it); when the streak
 * reaches eof_no_audio_streak and audio was sent before, the EOF
 * finalisation starts.  After the last mark a send happens whenever
 * >= chunk_bytes are pending, or fallback_interval_ms passed since the last
 * send with anything pending.
 *
 * Several marks can be due at once only right after a slow connect (the
 * schedule clock started at the first captured frame, before the socket was
 * up): they are one event then - one flush covers them all and none of them
 * is an empty mark.  In steady state the loop runs every <= 20 ms, so marks
 * are processed one at a time exactly like amd.py.
 */
static enum sched_result acc_service_schedule(struct amd_call *c, struct timeval now)
{
	int64_t since_first;
	int sent_now = 0;

	if (!c->have_audio) {
		return SCHED_OK;
	}
	since_first = ast_tvdiff_ms(now, c->t_first);
	while (c->sched_idx < c->conf.n_schedule && since_first >= c->conf.schedule[c->sched_idx]) {
		int mark = c->conf.schedule[c->sched_idx++];

		if (c->acc_len) {
			if (acc_flush(c, now)) {
				return SCHED_LOST;
			}
			sent_now = 1;
		} else if (!sent_now) {
			c->no_audio_streak++;
			ast_debug(2, "AMD_WS: %s mark %d ms: no audio data (streak %d, sent %ld)\n",
				ast_channel_name(c->chan), mark, c->no_audio_streak, c->bytes_sent);
			if (c->conf.eof_no_audio_streak && c->no_audio_streak >= c->conf.eof_no_audio_streak && c->bytes_sent > 0) {
				return SCHED_EOF;
			}
		}
	}
	if (c->sched_idx >= c->conf.n_schedule && c->acc_len
		&& (c->acc_len >= (size_t) c->conf.chunk_bytes
			|| ast_tvdiff_ms(now, c->t_last_send) >= c->conf.fallback_interval_ms)) {
		if (acc_flush(c, now)) {
			return SCHED_LOST;
		}
	}
	return SCHED_OK;
}

/*! \brief ms until the next time-driven send: schedule mark or fallback interval (-1 if none pending) */
static int acc_ms_to_next_mark(const struct amd_call *c, struct timeval now)
{
	int64_t ms;

	if (!c->have_audio) {
		return -1;
	}
	if (c->sched_idx < c->conf.n_schedule) {
		ms = c->conf.schedule[c->sched_idx] - ast_tvdiff_ms(now, c->t_first);
	} else if (c->acc_len) {
		ms = c->conf.fallback_interval_ms - ast_tvdiff_ms(now, c->t_last_send);
	} else {
		return -1;
	}
	return ms < 0 ? 0 : (int) ms;
}

/* ------------------------------------------------------------------------
 * Playback helpers (parallel to capture)
 * ---------------------------------------------------------------------- */

/*! \brief Start the next file of the list, or mark the list done */
static void play_start_next(struct amd_call *c)
{
	char *file;

	while ((file = strsep(&c->playlist, "&"))) {
		file = ast_strip(file);
		if (ast_strlen_zero(file)) {
			continue;
		}
		if (!ast_streamfile(c->chan, file, ast_channel_language(c->chan))) {
			c->play = PLAY_PLAYING;
			return;
		}
		ast_log(LOG_WARNING, "AMD_WS: %s cannot play '%s', skipping\n", ast_channel_name(c->chan), file);
	}
	c->play = PLAY_DONE;
}

/*!
 * \brief Drive the playback state machine once per loop iteration.
 *
 * End of file is detected exactly as ast_waitstream() does: the stream is
 * still attached but nothing is scheduled and no timing function is armed.
 */
static void play_service(struct amd_call *c, struct timeval now)
{
	struct ast_sched_context *sched;

	switch (c->play) {
	case PLAY_WAIT_DELAY:
		if (ast_tvdiff_ms(now, c->t_app) >= c->playdelay_ms) {
			play_start_next(c);
		}
		break;
	case PLAY_PLAYING:
		if (!ast_channel_stream(c->chan)) {
			play_start_next(c);   /* zero-length file or stopped elsewhere */
			break;
		}
		sched = ast_channel_sched(c->chan);
		if (sched) {
			ast_sched_runq(sched);
		}
		if ((!sched || ast_sched_wait(sched) < 0) && !ast_channel_timingfunc(c->chan)) {
			ast_stopstream(c->chan);
			play_start_next(c);
		}
		break;
	default:
		break;
	}
}

/*! \brief Upper bound for the wait budget imposed by playback timing */
static int play_ms_budget(const struct amd_call *c, struct timeval now)
{
	struct ast_sched_context *sched;
	int ms;

	switch (c->play) {
	case PLAY_WAIT_DELAY:
		ms = c->playdelay_ms - (int) ast_tvdiff_ms(now, c->t_app);
		return ms < 0 ? 0 : ms;
	case PLAY_PLAYING:
		sched = ast_channel_sched(c->chan);
		if (sched && !ast_channel_timingfunc(c->chan)) {
			ms = ast_sched_wait(sched);
			return ms < 0 ? -1 : ms;
		}
		return -1;
	default:
		return -1;
	}
}

static void play_stop(struct amd_call *c)
{
	if (c->play == PLAY_PLAYING) {
		ast_stopstream(c->chan);
	}
	if (c->play != PLAY_NONE) {
		c->play = PLAY_DONE;
	}
}

/* ------------------------------------------------------------------------
 * Exec helpers
 * ---------------------------------------------------------------------- */

static void set_outcome(struct amd_call *c, const char *status, const char *cause)
{
	ast_copy_string(c->status, status, sizeof(c->status));
	ast_copy_string(c->cause, cause, sizeof(c->cause));
}

/*! \brief Append ,"key":"<escaped value>" when value is non-empty; returns the new length or -1 */
static int json_append_kv(char *out, size_t out_sz, int n, const char *key, const char *value)
{
	char esc[MAX_VID_LEN * 6 + 1];   /* phone/country/caller_id are all shorter than a vid */
	int m;

	if (ast_strlen_zero(value) || json_escape(esc, sizeof(esc), value) < 0) {
		return n;   /* omitted, as amd.py omits a missing value */
	}
	m = snprintf(out + n, out_sz - n, ",\"%s\":\"%s\"", key, esc);
	if (m < 0 || (size_t) m >= out_sz - n) {
		return -1;
	}
	return n + m;
}

/*!
 * \brief Build the config JSON (amd.py Jul 2026, keys in this order):
 *   {"config":{"sample_rate":8000,"VID":"<vid>"[,"phone":".."][,"country_code":".."][,"caller_id":".."]}}
 * Returns 0 on success.
 */
static int build_config_json(struct amd_call *c, char *out, size_t out_sz)
{
	char vid_esc[MAX_VID_LEN * 6 + 1];
	int n;

	if (json_escape(vid_esc, sizeof(vid_esc), c->vid) < 0) {
		ast_copy_string(vid_esc, "Unknown", sizeof(vid_esc));
	}
	n = snprintf(out, out_sz, "{\"config\":{\"sample_rate\":%d,\"VID\":\"%s\"", SAMPLE_RATE, vid_esc);
	if (n < 0 || (size_t) n >= out_sz) {
		return -1;
	}
	if ((n = json_append_kv(out, out_sz, n, "phone", c->phone)) < 0
		|| (n = json_append_kv(out, out_sz, n, "country_code", c->country)) < 0
		|| (n = json_append_kv(out, out_sz, n, "caller_id", c->caller_id)) < 0) {
		return -1;
	}
	if (!ast_strlen_zero(c->conf.extra_config)) {
		/* {"a":1} -> ,"a":1  (the object braces are stripped, the rest is the operator's JSON) */
		size_t el = strlen(c->conf.extra_config);
		const char *inner = c->conf.extra_config + 1;
		size_t il = el - 2;

		while (il > 0 && isspace((unsigned char) inner[il - 1])) {
			il--;
		}
		if (il > 0) {
			if ((size_t) n + il + 4 > out_sz) {
				return -1;
			}
			out[n++] = ',';
			memcpy(out + n, inner, il);
			n += il;
		}
	}
	if ((size_t) n + 3 > out_sz) {
		return -1;
	}
	memcpy(out + n, "}}", 3);
	return 0;
}

/*!
 * \brief Attach a freshly connected websocket: non-blocking fd, write timeout,
 *        config TEXT frame.  Returns 0 on success (-1 = CONNECTION_ERROR: amd.py
 *        sends the config inside its connect try-block).
 */
static int ws_attach(struct amd_call *c, struct ast_websocket *ws, const char *config_json)
{
	c->ws = ws;
	ast_websocket_set_nonblock(ws);
	ast_websocket_set_timeout(ws, WS_WRITE_TIMEOUT_MS);
	c->wsfd = ast_websocket_fd(ws);
	if (c->wsfd < 0) {
		c->ws_lost = 1;
		return -1;
	}
	if (ast_websocket_write_string(ws, config_json)) {
		ast_debug(1, "AMD_WS: %s failed to send config frame\n", ast_channel_name(c->chan));
		c->ws_lost = 1;
		return -1;
	}
	ast_debug(2, "AMD_WS: %s connected, config sent\n", ast_channel_name(c->chan));
	return 0;
}

/*!
 * \brief Read one WebSocket frame (fd was reported readable) and act on it.
 *
 * ast_websocket_read() reconstructs fragmented messages internally up to
 * 64 KB and only reports fragmented=1 beyond that; we still concatenate such
 * pieces into rx.  PING is answered by res_http_websocket itself.  CLOSE or
 * any read error marks the connection lost.
 *
 * Bound: when only part of a frame has arrived the core's ws_safe_read()
 * waits for the rest in 1 s steps, up to 10 s (see docs/troubleshooting.md,
 * "Known limitations"); server replies are expected to be small.
 *
 * \retval 1 terminal result received, 0 nothing decisive, -1 connection lost
 */
static int ws_service_read(struct amd_call *c)
{
	char *payload = NULL;
	uint64_t payload_len = 0;
	enum ast_websocket_opcode opcode = 0;
	int fragmented = 0;

	if (ast_websocket_read(c->ws, &payload, &payload_len, &opcode, &fragmented)) {
		ast_debug(1, "AMD_WS: %s websocket read error/closed\n", ast_channel_name(c->chan));
		c->ws_lost = 1;
		return -1;
	}

	switch (opcode) {
	case AST_WEBSOCKET_OPCODE_CLOSE:
		ast_debug(1, "AMD_WS: %s server closed the websocket\n", ast_channel_name(c->chan));
		c->ws_lost = 1;
		return -1;
	case AST_WEBSOCKET_OPCODE_PING:
	case AST_WEBSOCKET_OPCODE_PONG:
		return 0;
	case AST_WEBSOCKET_OPCODE_BINARY:
		ast_debug(2, "AMD_WS: %s ignoring %" PRIu64 "-byte binary frame from server\n",
			ast_channel_name(c->chan), payload_len);
		return 0;
	case AST_WEBSOCKET_OPCODE_CONTINUATION:
		if (!payload_len) {
			return 0;   /* reconstruction in progress inside res_http_websocket */
		}
		/* fall through: a reconstructed piece */
	case AST_WEBSOCKET_OPCODE_TEXT:
		break;
	default:
		return 0;
	}

	if (payload_len) {
		size_t room = RX_CAP - 1 - c->rx_len;
		size_t n = payload_len > room ? room : (size_t) payload_len;

		memcpy(c->rx + c->rx_len, payload, n);
		c->rx_len += n;
	}
	if (fragmented) {
		return 0;   /* wait for the final piece */
	}
	c->rx[c->rx_len] = '\0';

	sanitize_response(c->rx, c->rx_len, c->response, sizeof(c->response));
	c->replies++;
	amd_trace(c, "reply #%d: \"%s\"", c->replies, c->response);

	switch (classify_text(c->rx, c->rx_len)) {
	case CLASS_HUMAN:
		/* amd.py:293 - AMDCAUSE is the literal HUMAN, the reply goes to AMDRESPONSE */
		set_outcome(c, "HUMAN", "HUMAN");
		c->got_result = 1;
		c->rx_len = 0;
		return 1;
	case CLASS_MACHINE:
		/* amd.py:298 - AMDCAUSE is the raw reply text (sanitised, <= 255) */
		set_outcome(c, "MACHINE", c->response);
		c->got_result = 1;
		c->rx_len = 0;
		return 1;
	case CLASS_ACK:
		break;
	}
	c->acks++;
	c->rx_len = 0;
	return 0;
}

/*!
 * \brief Service the websocket after poll reported it readable.
 *
 * Reads one frame, then drains what is already buffered: over wss:// a TLS
 * record may carry two frames of which the second sits decrypted inside
 * OpenSSL where poll() on the fd cannot see it (ast_websocket_wait_for_input()
 * checks SSL_pending()); over ws:// two coalesced frames are read in one
 * iteration instead of two.  Bounded by WS_READ_DRAIN_MAX so the channel is
 * serviced again quickly.  A close the core initiated itself (PONG write
 * failure, unknown opcode) is detected through ast_websocket_fd() < 0.
 *
 * \retval 1 terminal result received, 0 nothing decisive, -1 connection lost
 */
static int ws_service(struct amd_call *c)
{
	int n;

	for (n = 0; n < WS_READ_DRAIN_MAX; n++) {
		int r = ws_service_read(c);

		if (r) {
			return r;
		}
		if (ast_websocket_fd(c->ws) < 0) {
			ast_debug(1, "AMD_WS: %s websocket closed by the core\n", ast_channel_name(c->chan));
			c->ws_lost = 1;
			return -1;
		}
		if (ast_websocket_wait_for_input(c->ws, 0) <= 0) {
			break;
		}
	}
	return 0;
}

/*! \brief Best-effort protocol goodbye + close + unref.  Never leaves the fd open. */
static void ws_release(struct amd_call *c)
{
	if (!c->ws) {
		return;
	}
	if (!c->ws_lost) {
		ast_websocket_write_string(c->ws, "{\"eof\":1}");
	}
	ast_websocket_close(c->ws, 1000);
	ast_websocket_unref(c->ws);
	c->ws = NULL;
	c->wsfd = -1;
}

/*!
 * \brief Start the connect job on a helper thread.
 *
 * The connect is never run on the PBX thread: besides blocking it, the core's
 * tcptls client marks the calling thread with ast_thread_inhibit_escalations(),
 * which would break a later System() in the same dialplan.
 *
 * \retval 0 started, 1 refused because too many connects to this host are in
 *         flight (CONNECTION_ERROR), -1 internal failure (FATAL_ERROR)
 */
static int start_connect(struct amd_call *c, int do_db)
{
	struct connect_job *job;
	pthread_t tid;
	int warn, probe;
	const char *scheme = c->use_tls ? "wss" : "ws";

	/*
	 * File-descriptor probe.  The core's client path calls
	 * ast_tcptls_client_start_timeout(ast_tcptls_client_create(...)) and
	 * dereferences the NULL that ast_tcptls_client_create() returns when
	 * socket() fails (EMFILE/ENFILE) -- that would take the whole Asterisk
	 * down.  A socket we can open now is no guarantee for the helper a few
	 * microseconds later, but it catches sustained exhaustion.
	 */
	probe = socket(AF_INET, SOCK_STREAM, 0);
	if (probe < 0) {
		if (connect_warn_allowed(c->host)) {
			ast_log(LOG_WARNING, "AMD_WS: cannot open a socket: %s - out of file descriptors? (raise maxfiles in asterisk.conf; suppressed for %d s)\n",
				strerror(errno), CONNECT_WARN_S);
		}
		return -1;
	}
	close(probe);

	if (pending_cap_reached(c->host, c->conf.max_pending_connects, &warn)) {
		if (warn) {
			ast_log(LOG_WARNING, "AMD_WS: %d connects to %s still pending (max_pending_connects), failing fast with CONNECTION_ERROR until the server closes them (suppressed for %d s)\n",
				c->conf.max_pending_connects, c->host, PENDING_WARN_S);
		}
		return 1;
	}

	job = ast_calloc(1, sizeof(*job));
	if (!job) {
		return -1;
	}
	ast_mutex_init(&job->lock);
	job->refs = 2;   /* caller + thread */
	job->state = JOB_PENDING;
	job->timeout_ms = c->connect_timeout_ms;
	ast_copy_string(job->host, c->host, sizeof(job->host));
	ast_copy_string(job->chan_name, ast_channel_name(c->chan), sizeof(job->chan_name));
	if (strchr(c->host, ':') && c->host[0] != '[') {
		/* IPv6 literal: the URI parser needs brackets */
		snprintf(job->uri, sizeof(job->uri), "%s://[%s]:%d/", scheme, c->host, c->port);
	} else {
		snprintf(job->uri, sizeof(job->uri), "%s://%s:%d/", scheme, c->host, c->port);
	}
	job->do_db = do_db;
	job->db_timeout_ms = c->conf.db_timeout_ms;
	ast_copy_string(job->vid, c->vid, sizeof(job->vid));
	if (c->use_tls) {
		job->tls_cfg = tls_cfg_create(&c->conf);
		if (!job->tls_cfg) {
			ast_mutex_destroy(&job->lock);
			ast_free(job);
			return -1;
		}
	}

	/* The helper holds a module reference so an unload cannot race its tail. */
	ast_module_ref(AST_MODULE_SELF);
	ast_atomic_fetchadd_int(&inflight_helpers, 1);
	if (ast_pthread_create_detached_background(&tid, NULL, connect_thread, job)) {
		ast_log(LOG_ERROR, "AMD_WS: %s cannot create connect thread: %s\n", ast_channel_name(c->chan), strerror(errno));
		ast_module_unref(AST_MODULE_SELF);
		ast_atomic_fetchadd_int(&inflight_helpers, -1);
		tls_cfg_free(job->tls_cfg);
		ast_mutex_destroy(&job->lock);
		ast_free(job);
		return -1;
	}
	c->job = job;
	return 0;
}

/*! \brief Take the helper's DB enrichment (valid once the job is JOB_DONE) unless p()/k() gave values */
static void job_take_db(struct amd_call *c)
{
	if (!c->job || !c->job->do_db) {
		return;
	}
	if (ast_strlen_zero(c->phone)) {
		ast_copy_string(c->phone, c->job->phone, sizeof(c->phone));
	}
	if (ast_strlen_zero(c->country)) {
		ast_copy_string(c->country, c->job->country, sizeof(c->country));
	}
}

/*! \brief One counter per outcome of the vocabulary (MACHINE by status: its cause is the raw reply) */
static void count_outcome(const struct amd_call *c)
{
	static const struct {
		const char *cause;
		int *counter;
	} by_cause[] = {
		{ "HUMAN",            &cnt_human },
		{ "HANGUP",           &cnt_hangups },
		{ "CONNECTION_ERROR", &cnt_connection_error },
		{ "PROCESSING_ERROR", &cnt_processing_error },
		{ "FATAL_ERROR",      &cnt_fatal_error },
		{ "SERVER_TIMEOUT",   &cnt_server_timeout },
		{ "EOF_INCONCLUSIVE", &cnt_eof_inconclusive },
		{ "EOF_ERROR",        &cnt_eof_error },
	};
	size_t i;

	ast_atomic_fetchadd_int(&cnt_calls, 1);
	if (!strcmp(c->status, "MACHINE")) {
		ast_atomic_fetchadd_int(&cnt_machine, 1);
		return;
	}
	if (!strncmp(c->cause, "NOAUDIODATA-", 12)) {
		ast_atomic_fetchadd_int(&cnt_noaudiodata, 1);
		return;
	}
	for (i = 0; i < ARRAY_LEN(by_cause); i++) {
		if (!strcmp(c->cause, by_cause[i].cause)) {
			ast_atomic_fetchadd_int(by_cause[i].counter, 1);
			return;
		}
	}
}

/* ------------------------------------------------------------------------
 * The application
 * ---------------------------------------------------------------------- */

static int amd_ws_exec(struct ast_channel *chan, const char *data)
{
	struct amd_call c;
	struct ast_format *orig_readformat = NULL;
	struct ast_flags opts = { 0 };
	char *opt_args[OPT_ARG_ARRAY_SIZE] = { NULL };
	char *parse;
	char config_json[(MAX_VID_LEN + sizeof(c.phone) + sizeof(c.country) + sizeof(c.caller_id)) * 6 + 128];
	int64_t elapsed_ms;
	char elapsed_str[24];
	char stats_str[96];
	int v;
	AST_DECLARE_APP_ARGS(args,
		AST_APP_ARG(host);
		AST_APP_ARG(port);
		AST_APP_ARG(vid);
		AST_APP_ARG(timeout);
		AST_APP_ARG(playfile);
		AST_APP_ARG(options);
	);

	memset(&c, 0, sizeof(c));
	c.chan = chan;
	c.wsfd = -1;
	c.t_app = ast_tvnow();
	conf_snapshot(&c.conf);
	/* amd.py:537 - anything that goes wrong before the connect is FATAL_ERROR, and errors are HUMAN */
	set_outcome(&c, "HUMAN", "FATAL_ERROR");

	/* ---- arguments -------------------------------------------------- */
	parse = ast_strdupa(S_OR(data, ""));
	AST_STANDARD_APP_ARGS(args, parse);

	if (!ast_strlen_zero(args.options)
		&& ast_app_parse_options(amd_ws_options, &opts, opt_args, args.options)) {
		/* p(<phone>) may be inside: never write digits to the log at normal verbosity */
		char masked[128];
		size_t i;

		ast_copy_string(masked, args.options, sizeof(masked));
		for (i = 0; masked[i]; i++) {
			if (isdigit((unsigned char) masked[i])) {
				masked[i] = 'X';
			}
		}
		ast_log(LOG_WARNING, "AMD_WS: %s invalid options '%s' (digits masked; all options ignored)\n", ast_channel_name(chan), masked);
		/* "ignored" means ignored: not the half of them parsed before the error */
		memset(&opts, 0, sizeof(opts));
		memset(opt_args, 0, sizeof(opt_args));
	}

	ast_copy_string(c.host, !ast_strlen_zero(args.host) ? args.host : c.conf.host, sizeof(c.host));
	c.port = c.conf.port;
	if (!ast_strlen_zero(args.port) && !parse_int(args.port, 1, 65535, &c.port)) {
		ast_log(LOG_WARNING, "AMD_WS: %s invalid port '%s', using %d\n", ast_channel_name(chan), args.port, c.conf.port);
		c.port = c.conf.port;
	}
	if (!ast_strlen_zero(args.vid)) {
		ast_copy_string(c.vid, args.vid, sizeof(c.vid));
	} else {
		const char *cid_name;

		ast_channel_lock(chan);
		cid_name = S_COR(ast_channel_caller(chan)->id.name.valid, ast_channel_caller(chan)->id.name.str, NULL);
		ast_copy_string(c.vid, S_OR(cid_name, "Unknown"), sizeof(c.vid));
		ast_channel_unlock(chan);
	}
	c.timeout_ms = c.conf.timeout_ms;
	if (!ast_strlen_zero(args.timeout)) {
		if (parse_int(args.timeout, INT_MIN + 1, INT_MAX, &v)) {
			if (v > 0) {
				c.timeout_ms = v;   /* <= 0 means "use the default" */
			}
		} else {
			ast_log(LOG_WARNING, "AMD_WS: %s invalid timeout '%s', using %d\n",
				ast_channel_name(chan), args.timeout, c.conf.timeout_ms);
		}
	}
	c.connect_timeout_ms = c.conf.connect_timeout_ms;
	if (ast_test_flag(&opts, OPT_CONNTO) && !parse_int(opt_args[OPT_ARG_CONNTO], 1, 600000, &c.connect_timeout_ms)) {
		ast_log(LOG_WARNING, "AMD_WS: %s invalid c(%s), using %d\n",
			ast_channel_name(chan), S_OR(opt_args[OPT_ARG_CONNTO], ""), c.conf.connect_timeout_ms);
	}
	c.playdelay_ms = c.conf.playdelay_ms;
	if (ast_test_flag(&opts, OPT_PLAYDELAY) && !parse_int(opt_args[OPT_ARG_PLAYDELAY], 0, 600000, &c.playdelay_ms)) {
		ast_log(LOG_WARNING, "AMD_WS: %s invalid d(%s), using %d\n",
			ast_channel_name(chan), S_OR(opt_args[OPT_ARG_PLAYDELAY], ""), c.conf.playdelay_ms);
	}
	c.use_tls = ast_test_flag(&opts, OPT_TLS) ? 1 : c.conf.tls;
	c.trace = ast_test_flag(&opts, OPT_TRACE) ? 1 : c.conf.trace;
	if (ast_test_flag(&opts, OPT_PHONE) && !ast_strlen_zero(opt_args[OPT_ARG_PHONE])) {
		ast_copy_string(c.phone, opt_args[OPT_ARG_PHONE], sizeof(c.phone));
	}
	if (ast_test_flag(&opts, OPT_CODE) && !ast_strlen_zero(opt_args[OPT_ARG_CODE])) {
		ast_copy_string(c.country, opt_args[OPT_ARG_CODE], sizeof(c.country));
	}
	/*
	 * caller_id (amd.py:197-200): i(cid), else CALLERID(num) unless the conf says
	 * send_caller_id=no; sent only when non-empty and != "Unknown", exactly
	 * amd.py's test (a number the channel does not have is empty here, never
	 * the AGI environment's "unknown").
	 */
	if (ast_test_flag(&opts, OPT_CALLERID)) {
		ast_copy_string(c.caller_id, S_OR(opt_args[OPT_ARG_CALLERID], ""), sizeof(c.caller_id));
	} else if (c.conf.send_caller_id) {
		const char *cid_num;

		ast_channel_lock(chan);
		cid_num = S_COR(ast_channel_caller(chan)->id.number.valid, ast_channel_caller(chan)->id.number.str, NULL);
		ast_copy_string(c.caller_id, S_OR(cid_num, ""), sizeof(c.caller_id));
		ast_channel_unlock(chan);
	}
	if (!strcmp(c.caller_id, "Unknown")) {
		c.caller_id[0] = '\0';
	}
	if (!ast_strlen_zero(args.playfile)) {
		c.playlist = ast_strdupa(args.playfile);
		c.playfile_display = args.playfile;
		c.play = PLAY_WAIT_DELAY;
	}

	ast_verb(3, "AMD_WS: %s vid=%s host=%s:%d play=%s\n", ast_channel_name(chan), c.vid,
		c.host, c.port, S_OR(c.playfile_display, "none"));

	/* ---- answer / format -------------------------------------------- */
	if (ast_channel_state(chan) != AST_STATE_UP) {
		if (ast_test_flag(&opts, OPT_NOANSWER)) {
			ast_log(LOG_WARNING, "AMD_WS: %s channel not answered and option A given\n", ast_channel_name(chan));
			goto finish;
		}
		if (ast_answer(chan)) {
			ast_log(LOG_WARNING, "AMD_WS: %s failed to answer\n", ast_channel_name(chan));
			if (ast_check_hangup(chan)) {
				set_outcome(&c, "HANGUP", "HANGUP");
			}
			goto finish;
		}
	}

	orig_readformat = ao2_bump(ast_channel_readformat(chan));
	if (ast_set_read_format(chan, ast_format_slin)) {
		ast_log(LOG_WARNING, "AMD_WS: %s unable to set read format to slin\n", ast_channel_name(chan));
		goto finish;
	}

	/* ---- buffers ---------------------------------------------------- */
	{
		int gap = c.conf.schedule[0], i;

		for (i = 1; i < c.conf.n_schedule; i++) {
			if (c.conf.schedule[i] - c.conf.schedule[i - 1] > gap) {
				gap = c.conf.schedule[i] - c.conf.schedule[i - 1];
			}
		}
		if (c.conf.chunk_bytes / BYTES_PER_MS > gap) {
			gap = c.conf.chunk_bytes / BYTES_PER_MS;
		}
		/* connect wait + largest gap + 2 x 60 ms frames + slack */
		c.acc_cap = (size_t) (c.connect_timeout_ms + gap + 200) * BYTES_PER_MS + 2 * 960;
		if (c.acc_cap > ACC_HARD_CAP) {
			c.acc_cap = ACC_HARD_CAP;
		}
	}
	c.acc = ast_malloc(c.acc_cap);
	c.rx = ast_malloc(RX_CAP);
	if (!c.acc || !c.rx) {
		goto finish;
	}

	/* ---- connect (helper thread; the DB enrichment runs there too) --- */
	/* conf db=no, option n, or explicit p()/k() values skip the query (spec 5) */
	v = c.conf.db && !ast_test_flag(&opts, OPT_NODB | OPT_PHONE | OPT_CODE);
	c.t_connect = ast_tvnow();
	amd_trace(&c, "connecting to %s://%s:%d (connect timeout %d ms, window %d ms)",
		c.use_tls ? "wss" : "ws", c.host, c.port, c.connect_timeout_ms, c.timeout_ms);
	v = start_connect(&c, v);
	if (v) {
		if (v > 0) {
			set_outcome(&c, "HUMAN", "CONNECTION_ERROR");
		}
		goto finish;
	}

	/* ---- main loop -------------------------------------------------- */
	c.phase = PHASE_CONNECT;
	/* amd.py:214 - "AMD service unavailable - defaulting to HUMAN for safety" */
	set_outcome(&c, "HUMAN", "CONNECTION_ERROR");

	for (;;) {
		struct timeval now = ast_tvnow();
		struct timeval t_ref = c.have_audio ? c.t_first : c.t_app;
		int64_t detect_left = c.timeout_ms - ast_tvdiff_ms(now, t_ref);
		struct ast_channel *winner;
		struct ast_frame *f;
		int ms, m, outfd = -1;
		int fds[1];
		int nfds = 0;

		if (ast_check_hangup(chan)) {
			set_outcome(&c, "HANGUP", "HANGUP");
			break;
		}

		/* -- phase transitions -- */
		if (c.phase == PHASE_CONNECT) {
			struct ast_websocket *ws = NULL;
			enum ast_websocket_result wr = WS_OK;
			int64_t conn_left = c.connect_timeout_ms - ast_tvdiff_ms(now, c.t_connect);
			enum job_state st = job_poll(c.job, &ws, &wr);

			if (st != JOB_DONE && (conn_left <= 0 || detect_left <= 0)) {
				/* deadline: give up, unless it finished exactly now (then use the outcome) */
				st = job_abandon(c.job, &ws, &wr);
				if (st != JOB_DONE) {
					job_unref(c.job);
					c.job = NULL;
					if (connect_warn_allowed(c.host)) {
						ast_log(LOG_WARNING, "AMD_WS: connect to %s://%s:%d timed out after %d ms (suppressed for %d s)\n",
							c.use_tls ? "wss" : "ws", c.host, c.port, c.connect_timeout_ms, CONNECT_WARN_S);
					}
					break;
				}
			}
			if (st == JOB_DONE) {
				job_take_db(&c);
				if (c.job->do_db) {
					if (!ast_strlen_zero(c.job->phone) || !ast_strlen_zero(c.job->country)) {
						amd_trace(&c, "DB FOUND: phone=%s, code=%s", S_OR(c.job->phone, ""), S_OR(c.job->country, ""));
					} else {
						amd_trace(&c, "DB lookup: no row for vid=%s", c.vid);
					}
				}
				job_unref(c.job);
				c.job = NULL;
				if (!ws) {
					if ((int) wr == -1) {
						/* the OPTIONAL_API stub ran: no client at all = cannot connect (addendum table A) */
						ast_log(LOG_ERROR, "AMD_WS: %s res_http_websocket is not loaded, cannot connect\n", ast_channel_name(chan));
					} else if (connect_warn_allowed(c.host)) {
						ast_log(LOG_WARNING, "AMD_WS: connect to %s://%s:%d failed: %s (suppressed for %d s)\n",
							c.use_tls ? "wss" : "ws", c.host, c.port, ws_result_str(wr), CONNECT_WARN_S);
					}
					break;   /* CONNECTION_ERROR */
				}
				if (build_config_json(&c, config_json, sizeof(config_json))) {
					ast_log(LOG_WARNING, "AMD_WS: %s config JSON too large\n", ast_channel_name(chan));
					c.ws = ws;
					c.ws_lost = 1;   /* nothing was sent; ws_release() still closes it */
					set_outcome(&c, "HUMAN", "FATAL_ERROR");
					break;
				}
				if (ws_attach(&c, ws, config_json)) {
					break;   /* CONNECTION_ERROR */
				}
				c.phase = PHASE_STREAM;
				/* amd.py:310,476 - from here on a lost socket is a PROCESSING_ERROR */
				set_outcome(&c, "HUMAN", "PROCESSING_ERROR");
				amd_trace(&c, "connected to %s:%d after %" PRId64 " ms; config sent: sample_rate=%d, VID=%s, phone=%s, country=%s, caller_id=%s%s%s",
					c.host, c.port, ast_tvdiff_ms(now, c.t_connect), SAMPLE_RATE, c.vid,
					S_OR(c.phone, "N/A"), S_OR(c.country, "N/A"), S_OR(c.caller_id, "N/A"),
					ast_strlen_zero(c.conf.extra_config) ? "" : ", extra=", S_OR(c.conf.extra_config, ""));
			}
		}

		if (c.phase == PHASE_STREAM) {
			if (detect_left <= 0) {
				/* amd.py:377-388 - MAX_WAIT_TIME; stock app_amd vocabulary for the no-audio case */
				if (!c.have_audio) {
					char cause[STATUS_TOKEN_LEN];

					snprintf(cause, sizeof(cause), "NOAUDIODATA-%" PRId64, ast_tvdiff_ms(now, t_ref));
					set_outcome(&c, "NOTSURE", cause);
					break;
				}
				set_outcome(&c, "NOTSURE", "SERVER_TIMEOUT");
				if (c.conf.result_grace_ms <= 0) {
					break;   /* amd.py returns at once */
				}
				/* v2 extra: flush what is left and give the server result_grace_ms */
				if (c.acc_len && acc_flush(&c, now)) {
					set_outcome(&c, "HUMAN", "PROCESSING_ERROR");
					break;
				}
				c.phase = PHASE_GRACE;
				ast_debug(1, "AMD_WS: %s timeout, waiting %d ms grace for a result\n",
					ast_channel_name(chan), c.conf.result_grace_ms);
			} else {
				enum sched_result sr = acc_service_schedule(&c, now);

				if (sr == SCHED_LOST) {
					break;   /* PROCESSING_ERROR */
				}
				if (sr == SCHED_EOF) {
					/* amd.py:408-416 - force the server to finalise, then wait for ONE reply */
					ast_debug(1, "AMD_WS: %s no audio at %d consecutive marks after %ld bytes sent: sending eof to force finalisation\n",
						ast_channel_name(chan), c.no_audio_streak, c.bytes_sent);
					set_outcome(&c, "NOTSURE", "EOF_ERROR");
					if (ast_websocket_write_string(c.ws, "{\"eof\":1}")) {
						ast_debug(1, "AMD_WS: %s eof write failed\n", ast_channel_name(chan));
						c.ws_lost = 1;
						break;   /* EOF_ERROR */
					}
					c.phase = PHASE_EOF_WAIT;
					c.t_eof = now;
				}
			}
		}

		if (c.phase == PHASE_EOF_WAIT) {
			if (ast_tvdiff_ms(now, c.t_eof) >= c.conf.eof_wait_ms) {
				ast_debug(1, "AMD_WS: %s no eof finalisation reply within %d ms\n", ast_channel_name(chan), c.conf.eof_wait_ms);
				break;   /* EOF_ERROR */
			}
		}

		if (c.phase == PHASE_GRACE) {
			if (-detect_left >= c.conf.result_grace_ms) {
				break;   /* SERVER_TIMEOUT */
			}
		}

		/* -- playback -- */
		play_service(&c, now);

		/* -- wait budget: never more than LOOP_BUDGET_MS -- */
		ms = LOOP_BUDGET_MS;
		if (c.phase == PHASE_GRACE) {
			m = c.conf.result_grace_ms + (int) detect_left;
		} else if (c.phase == PHASE_EOF_WAIT) {
			m = c.conf.eof_wait_ms - (int) ast_tvdiff_ms(now, c.t_eof);
		} else {
			m = (int) detect_left;
		}
		if (m >= 0 && m < ms) {
			ms = m;
		}
		if (c.phase == PHASE_CONNECT) {
			m = c.connect_timeout_ms - (int) ast_tvdiff_ms(now, c.t_connect);
			if (m >= 0 && m < ms) {
				ms = m;
			}
		}
		if (c.phase == PHASE_STREAM) {
			m = acc_ms_to_next_mark(&c, now);
			if (m >= 0 && m < ms) {
				ms = m;
			}
		}
		m = play_ms_budget(&c, now);
		if (m >= 0 && m < ms) {
			ms = m;
		}
		if (ms < 0) {
			ms = 0;
		}

		if (c.ws && !c.ws_lost) {
			fds[0] = c.wsfd;
			nfds = 1;
		}

		winner = ast_waitfor_nandfds(&chan, 1, fds, nfds, NULL, &outfd, &ms);

		/* -- websocket readable -- */
		if (nfds && outfd == c.wsfd) {
			int r = ws_service(&c);

			if (r > 0) {
				break;   /* result (HUMAN / MACHINE), in any phase */
			}
			if (r < 0) {
				if (!c.got_result && c.phase != PHASE_EOF_WAIT) {
					set_outcome(&c, "HUMAN", "PROCESSING_ERROR");
				}
				break;   /* EOF_WAIT keeps EOF_ERROR (amd.py:431-433) */
			}
			/*
			 * amd.py's send->recv lockstep has consumed every chunk reply before
			 * it sends the eof, so the next reply is the finalisation answer.
			 * Replies are read asynchronously here: a text that is still owed
			 * for a chunk is a chunk ack; the first one beyond that answers
			 * the eof, and when it was not HUMAN/MACHINE it is inconclusive.
			 */
			if (c.phase == PHASE_EOF_WAIT && c.replies > c.chunks) {
				ast_debug(1, "AMD_WS: %s eof finalisation inconclusive: %s\n", ast_channel_name(chan), c.response);
				set_outcome(&c, "NOTSURE", "EOF_INCONCLUSIVE");
				break;
			}
		}

		/* -- channel frame -- */
		if (winner == chan) {
			f = ast_read(chan);
			if (!f) {
				set_outcome(&c, "HANGUP", "HANGUP");
				break;
			}
			if (f->frametype == AST_FRAME_CONTROL && f->subclass.integer == AST_CONTROL_HANGUP) {
				ast_frfree(f);
				set_outcome(&c, "HANGUP", "HANGUP");
				break;
			}
			if (f->frametype == AST_FRAME_VOICE && f->datalen > 0 && f->data.ptr) {
				if (!c.have_audio) {
					c.have_audio = 1;
					c.t_first = ast_tvnow();
					c.t_last_send = c.t_first;   /* amd.py last_send_time = 0 */
					amd_trace(&c, "first audio frame (%d bytes); schedule and detection window start here", f->datalen);
				}
				c.bytes_captured += f->datalen;
				/* in GRACE / EOF_WAIT nothing is sent any more: count, do not accumulate */
				if (c.phase != PHASE_GRACE && c.phase != PHASE_EOF_WAIT) {
					acc_append(&c, f->data.ptr, f->datalen);
				}
			}
			ast_frfree(f);
		} else if (!winner && ms < 0) {
			/* poll error (not EINTR) */
			if (ast_check_hangup(chan)) {
				set_outcome(&c, "HANGUP", "HANGUP");
				break;
			}
			ast_debug(1, "AMD_WS: %s ast_waitfor_nandfds error: %s\n", ast_channel_name(chan), strerror(errno));
		}
	}

	if (c.got_result) {
		amd_trace(&c, "result %s after %d acks", c.status, c.acks);
	}

finish:
	/* ---- teardown (order matters: playback, socket, thread, format) ---- */
	play_stop(&c);

	if (c.job) {
		struct ast_websocket *late = NULL;
		enum ast_websocket_result wr = WS_OK;

		job_abandon(c.job, &late, &wr);
		job_unref(c.job);
		c.job = NULL;
		if (late) {
			c.ws = late;
			c.ws_lost = 1;   /* nothing was ever sent on it */
		}
	}
	ws_release(&c);

	if (orig_readformat) {
		if (ast_set_read_format(chan, orig_readformat)) {
			ast_log(LOG_WARNING, "AMD_WS: %s unable to restore read format\n", ast_channel_name(chan));
		}
		ao2_ref(orig_readformat, -1);
	}

	elapsed_ms = ast_tvdiff_ms(ast_tvnow(), c.have_audio ? c.t_first : c.t_app);
	snprintf(elapsed_str, sizeof(elapsed_str), "%" PRId64, elapsed_ms);
	/* stock app_amd style dash-separated integers; VD_amd.agi takes the first field as run_time */
	snprintf(stats_str, sizeof(stats_str), "%" PRId64 "-%ld-%d-%ld",
		elapsed_ms, c.bytes_sent / BYTES_PER_MS, c.chunks, c.bytes_sent);

	pbx_builtin_setvar_helper(chan, "AMDSTATUS", c.status);
	pbx_builtin_setvar_helper(chan, "AMDCAUSE", c.cause);
	pbx_builtin_setvar_helper(chan, "AMDSTATS", stats_str);
	pbx_builtin_setvar_helper(chan, "AMDRESPONSE", c.response);
	pbx_builtin_setvar_helper(chan, "AMDELAPSED", elapsed_str);
	/* the number/country that were sent to the service (DB lookup or p()/k()): lets the
	 * dialplan redial the lead, e.g. after a call-screening verdict */
	if (!ast_strlen_zero(c.phone)) {
		pbx_builtin_setvar_helper(chan, "AMDPHONE", c.phone);
	}
	if (!ast_strlen_zero(c.country)) {
		pbx_builtin_setvar_helper(chan, "AMDCOUNTRYCODE", c.country);
	}
	amd_trace(&c, "Variables set - Status: %s, Cause: %s, Stats: %s", c.status, c.cause, stats_str);

	count_outcome(&c);

	ast_verb(3, "AMD_WS: %s vid=%s status=%s cause=%s elapsed=%" PRId64 " sent=%ld chunks=%d\n",
		ast_channel_name(chan), c.vid, c.status, c.cause, elapsed_ms, c.bytes_sent, c.chunks);
	if (c.bytes_dropped) {
		ast_log(LOG_WARNING, "AMD_WS: %s dropped %ld bytes of audio (backlog)\n", ast_channel_name(chan), c.bytes_dropped);
	}

	ast_free(c.acc);
	ast_free(c.rx);
	return 0;
}

/* ------------------------------------------------------------------------
 * CLI
 * ---------------------------------------------------------------------- */

static char *cli_show_settings(struct ast_cli_entry *e, int cmd, struct ast_cli_args *a)
{
	struct amd_ws_conf c;
	struct db_creds creds;
	char buf[256];
	int i, n;

	switch (cmd) {
	case CLI_INIT:
		e->command = "amd_ws show settings";
		e->usage =
			"Usage: amd_ws show settings\n"
			"       Show the effective AMD_WS configuration, DB availability and counters.\n";
		return NULL;
	case CLI_GENERATE:
		return NULL;
	}

	conf_snapshot(&c);
	ast_mutex_lock(&conf_lock);
	creds = g_db_creds;
	ast_mutex_unlock(&conf_lock);

	ast_cli(a->fd, "\nAMD_WS %s (res_http_websocket client)\n", AMD_WS_VERSION);
	ast_cli(a->fd, "----------------------------------------------------\n");
	ast_cli(a->fd, "  host                : %s\n", c.host);
	ast_cli(a->fd, "  port                : %d\n", c.port);
	ast_cli(a->fd, "  tls                 : %s\n", AST_CLI_YESNO(c.tls));
	ast_cli(a->fd, "  tls_verify          : %s\n", AST_CLI_YESNO(c.tls_verify));
	ast_cli(a->fd, "  tls_check_hostname  : %s\n", AST_CLI_YESNO(c.tls_check_hostname));
	ast_cli(a->fd, "  tls_cafile          : %s\n", S_OR(c.tls_cafile, "(system default)"));
	ast_cli(a->fd, "  timeout_ms          : %d\n", c.timeout_ms);
	ast_cli(a->fd, "  connect_timeout_ms  : %d\n", c.connect_timeout_ms);
	ast_cli(a->fd, "  result_grace_ms     : %d\n", c.result_grace_ms);
	buf[0] = '\0';
	for (i = 0, n = 0; i < c.n_schedule && n < (int) sizeof(buf) - 8; i++) {
		n += snprintf(buf + n, sizeof(buf) - n, "%s%d", i ? "," : "", c.schedule[i]);
	}
	ast_cli(a->fd, "  send_schedule       : %s\n", buf);
	ast_cli(a->fd, "  chunk_bytes         : %d\n", c.chunk_bytes);
	ast_cli(a->fd, "  fallback_interval_ms: %d\n", c.fallback_interval_ms);
	ast_cli(a->fd, "  eof_no_audio_streak : %d%s\n", c.eof_no_audio_streak, c.eof_no_audio_streak ? "" : " (EOF finalisation disabled)");
	ast_cli(a->fd, "  eof_wait_ms         : %d\n", c.eof_wait_ms);
	ast_cli(a->fd, "  send_caller_id      : %s\n", AST_CLI_YESNO(c.send_caller_id));
	ast_cli(a->fd, "  trace               : %s (per-call timeline at verbose 3; option v)\n", AST_CLI_YESNO(c.trace));
	ast_cli(a->fd, "  playdelay_ms        : %d\n", c.playdelay_ms);
	ast_cli(a->fd, "  db                  : %s (%s)\n", AST_CLI_YESNO(c.db), db_availability());
	ast_cli(a->fd, "  db_timeout_ms       : %d\n", c.db_timeout_ms);
	ast_cli(a->fd, "  astguiclient_conf   : %s (%s)\n", c.astguiclient_conf,
		!creds.loaded ? "NOT READ - DB lookup skipped"
		: !creds.keys ? "read, NO VARDB_ LINES - DB lookup skipped" : "read");
	ast_cli(a->fd, "  extra_config        : %s\n", S_OR(c.extra_config, "(none - amd.py-exact config frame)"));
	ast_cli(a->fd, "  db server           : %s:%d/%s user=%s\n", creds.server, creds.port, creds.database, creds.user);
	ast_cli(a->fd, "  max_pending_connects: %d (per host)\n", c.max_pending_connects);
	ast_cli(a->fd, "\nCounters (AMDSTATUS/AMDCAUSE)\n");
	ast_cli(a->fd, "  calls               : %d\n", cnt_calls);
	ast_cli(a->fd, "  human               : %d  (HUMAN/HUMAN)\n", cnt_human);
	ast_cli(a->fd, "  machine             : %d  (MACHINE/<reply>)\n", cnt_machine);
	ast_cli(a->fd, "  hangups             : %d  (HANGUP/HANGUP)\n", cnt_hangups);
	ast_cli(a->fd, "  connection_error    : %d  (HUMAN/CONNECTION_ERROR)\n", cnt_connection_error);
	ast_cli(a->fd, "  processing_error    : %d  (HUMAN/PROCESSING_ERROR)\n", cnt_processing_error);
	ast_cli(a->fd, "  fatal_error         : %d  (HUMAN/FATAL_ERROR)\n", cnt_fatal_error);
	ast_cli(a->fd, "  server_timeout      : %d  (NOTSURE/SERVER_TIMEOUT)\n", cnt_server_timeout);
	ast_cli(a->fd, "  noaudiodata         : %d  (NOTSURE/NOAUDIODATA-<ms>)\n", cnt_noaudiodata);
	ast_cli(a->fd, "  eof_inconclusive    : %d  (NOTSURE/EOF_INCONCLUSIVE)\n", cnt_eof_inconclusive);
	ast_cli(a->fd, "  eof_error           : %d  (NOTSURE/EOF_ERROR)\n", cnt_eof_error);
	ast_cli(a->fd, "  connects in flight  : %d (helper threads currently connecting)\n", inflight_helpers);
	ast_mutex_lock(&pending_lock);
	ast_cli(a->fd, "  parked connects     : %d (max %d per host: the call gave up, the thread waits for the peer to close)\n",
		pending_total, c.max_pending_connects);
	for (i = 0; i < MAX_PENDING_HOSTS; i++) {
		if (pending_hosts[i].count > 0) {
			ast_cli(a->fd, "    %-18s: %d%s\n", pending_hosts[i].host, pending_hosts[i].count,
				pending_hosts[i].count >= c.max_pending_connects ? "  (cap reached: calls to this host fail fast with CONNECTION_ERROR)" : "");
		}
	}
	ast_mutex_unlock(&pending_lock);
	ast_cli(a->fd, "\n");
	return CLI_SUCCESS;
}

static struct ast_cli_entry cli_amd_ws[] = {
	AST_CLI_DEFINE(cli_show_settings, "Show AMD_WS settings and counters"),
};

/* ------------------------------------------------------------------------
 * Module lifecycle
 * ---------------------------------------------------------------------- */

static void load_all_config(int reload)
{
	char path[sizeof(g_conf.astguiclient_conf)];
	int db;

	load_config(reload);
	ast_mutex_lock(&conf_lock);
	ast_copy_string(path, g_conf.astguiclient_conf, sizeof(path));
	db = g_conf.db;
	ast_mutex_unlock(&conf_lock);
	load_db_creds(path, db);
}

static int load_module(void)
{
	conf_set_defaults(&g_conf);
	load_all_config(0);

#ifdef HAVE_MYSQL
	if (mysql_library_init(0, NULL, NULL)) {
		ast_log(LOG_ERROR, "AMD_WS: mysql_library_init failed\n");
		return AST_MODULE_LOAD_DECLINE;
	}
#endif

	if (ast_register_application(app, amd_ws_exec, synopsis, description)) {
		ast_log(LOG_ERROR, "AMD_WS: unable to register application %s\n", app);
		return AST_MODULE_LOAD_DECLINE;
	}
	if (ast_cli_register_multiple(cli_amd_ws, ARRAY_LEN(cli_amd_ws))) {
		ast_log(LOG_WARNING, "AMD_WS: unable to register CLI commands\n");
	}

	ast_verb(2, "AMD_WS %s loaded (host %s:%d, db %s)\n", AMD_WS_VERSION, g_conf.host, g_conf.port, db_availability());
	return AST_MODULE_LOAD_SUCCESS;
}

static int unload_module(void)
{
	int res;

	ast_cli_unregister_multiple(cli_amd_ws, ARRAY_LEN(cli_amd_ws));
	res = ast_unregister_application(app);
#ifdef HAVE_MYSQL
	db_shutdown();
#endif
	return res;
}

static int reload_module(void)
{
	load_all_config(1);
	ast_verb(2, "AMD_WS configuration reloaded\n");
	return AST_MODULE_LOAD_SUCCESS;
}

AST_MODULE_INFO(ASTERISK_GPL_KEY, AST_MODFLAG_LOAD_ORDER, "AMD via WebSocket (amdy.io)",
	.support_level = AST_MODULE_SUPPORT_EXTENDED,
	.load = load_module,
	.unload = unload_module,
	.reload = reload_module,
	.load_pri = AST_MODPRI_DEFAULT,
	.requires = "res_http_websocket",
);
