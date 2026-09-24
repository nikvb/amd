# Architecture

`app_amd_ws` is a single-file Asterisk application module (`app_amd_ws.c`)
that registers the dialplan application `AMD_WS()`. This page describes how a
call flows through it, how it is threaded, why it is built on
`res_http_websocket`, and how that differs from the 1.x module.

## Call flow

```text
dialplan: AMD_WS(host,port,vid,timeout_ms,playfile,options)
   |
   v
[1] parse arguments + options, apply amd_ws.conf defaults
   |  invalid port -> warning + default; timeout <= 0 -> default; vid empty -> CALLERID(name) or "Unknown"
   |  verbose(3): AMD_WS: <chan> vid=... host=...:... play=...
   v
[2] answer the channel if not up          (default; option A: do not answer -> HUMAN/FATAL_ERROR if not up)
   |
   v
[3] set channel read format to slin (8 kHz 16-bit mono); remember the old format
   |  allocate the heap accumulator (sized for connect_timeout + largest schedule gap + 2 frames)
   v
[4] start the connect job on a helper thread (after a throw-away socket() probe: out of
   |  file descriptors -> FATAL_ERROR, because the core's client path would crash on that)
   |  max_pending_connects (64) helpers already PARKED for THIS host (their calls gave up on a server
   |  that never answers the handshake) -> fail fast, CONNECTION_ERROR; healthy bursts are never capped
   v
[5] helper thread: phone/country lookup (optional) right before the connect
   |  skipped with db=no, option n, p()/k(), or an unreadable astguiclient.conf; one persistent
   |  MySQL connection under a module mutex, socket timeouts ceil(db_timeout_ms/1000) s,
   |  fails soft -> continue without phone; never on the PBX thread
   |  then ast_websocket_client_create_with_options(.timeout = connect_timeout_ms), which blocks
   |  for DNS + TCP + HTTP upgrade (see "Threading model"); the PBX thread builds and sends the
   |  config TEXT frame {"config":{sample_rate,VID[,phone][,country_code][,caller_id]}} when the
   |  helper hands the socket over
   v
[6] main loop  (until result | timeout_ms | hangup | ws closed)
   |   ast_waitfor_nandfds(channel, ws fd, <= 20 ms)
   |   channel readable  -> ast_read(); NULL or ast_check_hangup -> HANGUP
   |                        voice frame -> append to heap accumulator (never dropped)
   |                        first frame starts the clock (t = 0 for the schedule and AMDELAPSED)
   |   CONNECT phase      -> poll the helper: connected -> send TEXT {"config":{...}}, flush what
   |                        was captured meanwhile (all due marks at once); failed, res_http_websocket
   |                        missing, connect_timeout_ms or the detection window over -> abandon the
   |                        job (the helper closes a late socket), HUMAN/CONNECTION_ERROR
   |   STREAM phase       -> schedule mark hit (500 ... 9000 ms): send everything accumulated as one
   |                        BINARY frame; an empty mark counts towards no_audio_streak (any captured
   |                        frame resets it); streak >= eof_no_audio_streak with audio sent before
   |                        -> EOF finalisation: TEXT {"eof":1}, wait <= eof_wait_ms for one reply
   |                        (HUMAN / MACHINE / EOF_INCONCLUSIVE / EOF_ERROR), channel still serviced
   |                        after the last mark: send when >= chunk_bytes accumulated or
   |                        fallback_interval_ms since the last send with a non-empty buffer
   |   ws fd readable     -> ast_websocket_read(); reassemble fragments; TEXT -> classify with
   |                        amd.py's rule ('HUMAN' in text -> HUMAN; 'AMD' (not 'AMDY') or 'MACHINE'
   |                        in text -> MACHINE with the text as cause; else ack);
   |                        then drain what is already buffered (<= 8 frames: a TLS record may hold
   |                        two frames poll() cannot see); core-initiated close -> ast_websocket_fd() < 0
   |                        CLOSE / read or write error / malformed frame -> HUMAN/PROCESSING_ERROR
   |                        (if no result yet)
   |   playback           -> after playdelay_ms (from application start) start the playfile list;
   |                        end of a file starts the next one; end of the list changes nothing
   v
[7] result grace (only after timeout_ms without result): send remaining audio,
   |  wait <= result_grace_ms (default 0) for a TEXT reply, still servicing the channel (frames
   |  read, counted, no longer accumulated: nothing is sent in this phase) -> NOTSURE/SERVER_TIMEOUT
   |  (no audio ever captured -> NOTSURE/NOAUDIODATA-<ms> immediately, no grace)
   v
[8] exit path (always the same, whatever the reason)
      stop playback (ast_stopstream)
      abandon a still-pending connect job
      TEXT {"eof":1} best effort, ast_websocket_close(ws, 1000), unref
      restore the channel read format
      set AMDSTATUS, AMDCAUSE, AMDSTATS (<elapsed>-<audio_ms>-<chunks>-<bytes>), AMDRESPONSE, AMDELAPSED
      verbose(3): AMD_WS: <chan> vid=<vid> status=... cause=... elapsed=... sent=... chunks=...; counters++
      return 0
```

Every wait in [6] and [7] is bounded by a deadline computed with
`ast_tvdiff_ms`; there are no fixed sleeps and no loops that count iterations
instead of time. The channel is read in every phase, including while the
connect is still pending, so a hangup is noticed within one iteration and the
Local channel's frame queue never overflows.

Clocks: the send schedule and `AMDELAPSED` start at the first captured voice
frame; the detection deadline is that instant (or the application start while
no audio has arrived) plus `timeout_ms`; the connect deadline is the
application start plus `connect_timeout_ms`, capped by the detection deadline
(a detection window that expires while still connecting ends in
`CONNECTION_ERROR`, so the dialplan fallback applies); `playdelay_ms` counts
from the application start.

## Threading model

- **The PBX thread does all the work on the channel.** Reading audio, sending
  chunks, reading replies, playback and every timeout run on the channel's PBX
  thread, like every other dialplan application. One `AMD_WS()` invocation =
  one call = one WebSocket connection.
- **One short-lived helper thread per connect.** `ast_websocket_client_create_with_options()`
  is blocking: only its TCP connect honours `.timeout`; the DNS lookup and the
  HTTP upgrade have no timeout, so a server that accepts TCP and never answers
  would block the caller for as long as the peer likes. The connect therefore
  runs on a detached helper thread (`ast_pthread_create_detached_background`)
  that holds a module reference; the PBX thread polls a reference-counted job
  while it services the channel, and abandons the job at its deadline. A late
  socket is closed by the helper. The optional DB lookup runs on the same
  helper right before the connect, so it can never stall the channel thread
  (a stalled DB costs that call its connect window instead). At most
  `max_pending_connects` (64) helpers per host may be parked in the core's
  handshake read after their call gave up (`amd_ws show settings` prints
  `connects in flight` and `parked connects` per host); beyond that a call to
  that host fails fast with `CONNECTION_ERROR`. A burst of healthy connects is never
  capped. Parked helpers end when the peer closes or Asterisk restarts
  ([troubleshooting.md, Known limitations](troubleshooting.md#4-known-limitations)).
  Running the connect on the PBX thread is not an
  option even as a fallback: the core's TCP/TLS client marks the calling
  thread with `ast_thread_inhibit_escalations()`, which would break a later
  `System()` in the same dialplan.
- **Per-call state** lives in a stack struct plus a heap-allocated audio
  accumulator and receive buffer. Per-call stack usage stays under 32 KB.
- **Shared state** is limited to counters (`ast_atomic_fetchadd_int`), the
  pending-connect count and the single MySQL connection (module mutex,
  `AST_MUTEX_DEFINE_STATIC`). Nothing else is global; 25 concurrent calls and
  a 300-call soak (no fd growth, RSS flat) are part of the test matrix.
- **Module lifecycle.** `load_module` reads `amd_ws.conf` and
  `astguiclient.conf`, initialises the MySQL client library once, registers the
  application and the CLI command, and returns `AST_MODULE_LOAD_DECLINE` on any
  failure (never `FAILURE`, which would abort Asterisk startup).
  `module reload app_amd_ws.so` re-reads both files. Unload relies on the
  core's use count (`pbx_exec` holds a module reference for the duration of
  each call, a pending connect helper holds another), so `module unload` is
  refused while any call is inside `AMD_WS()` and nothing is ever hung up to
  make room for an upgrade. The module declares
  `.requires = "res_http_websocket"` and `AST_MODULE_SUPPORT_EXTENDED`.

## Why `res_http_websocket`

Asterisk has shipped a WebSocket client in `res_http_websocket` since 13
(`include/asterisk/http_websocket.h`). It is an OPTIONAL_API, so the module
links nothing at build time and resolves the `ast_websocket_*` symbols when it
is loaded. What it gives the module:

| Need | `res_http_websocket` |
|---|---|
| Connect with a real timeout | `ast_websocket_client_create_with_options()` with `.timeout` in ms (present in 16.30.1, 18, 20) bounds the TCP connect; DNS and the HTTP upgrade are bounded by the module's helper-thread deadline |
| Wait on channel **and** socket together | `ast_websocket_fd()` plugs into `ast_waitfor_nandfds()`; the same pattern `res_agi` and `app_externalivr` use |
| Non-blocking reads, fragment handling | `ast_websocket_read()` reports opcode and fragmentation |
| TLS | `wss://` through Asterisk's own TLS configuration; no extra library build |
| Client masking, PING replies, CLOSE handshake | built in |
| Frame size | up to 65535 bytes per frame; the 8000-16000 byte audio chunks fit |
| Distribution | already installed on every ViciDial/ViciBox/distro Asterisk; nothing to compile or vendor |

If `res_http_websocket` is not loaded the OPTIONAL_API stubs return NULL and
`AMD_WS()` exits with `HUMAN` / `CONNECTION_ERROR` (the service cannot be
reached, whatever the reason) and a clear log line; the module's
`.requires` also makes the loader load `res_http_websocket` first when
autoload is on.

## v1 versus v2

Version 1 embedded libwebsockets (lws) and created one lws context per call on
the channel thread. The review of that code (measured in harnesses that copied
the module's loops verbatim, against the installer's lws 4.3.3 and Ubuntu's
4.0.20) found the following behaviours. They are listed here because each one
shaped a rule in the v2 design, not to assign blame.

| v1 behaviour (observed) | Effect on a dialer | v2 design |
|---|---|---|
| `lws_service(ctx, ms)` ignores its timeout argument in lws >= 3.2; each call blocked until a socket event or an internal lws timer (about 1 s on 4.0.20, up to 30 s on 4.3.3). Every `total_ms += 50` loop counted iterations, not time. | Audio loop stalled; "2000 ms" connect timeout was really 100 ms (false timeouts) or many minutes (dead air on an unreachable server). | Every wait is bounded by `ast_tvdiff_ms` against a deadline; the connect uses the API's own millisecond timeout; the channel is serviced while waiting. |
| Connect loop never exited on `CLIENT_CONNECTION_ERROR`. | An unreachable AMD server parked answered calls in silence. | Connect failure returns at `connect_timeout_ms` at the latest with `HUMAN` / `CONNECTION_ERROR` (as `amd.py`); repeated failures are logged once per 10 s per host. |
| One lws context per call, and the installer built lws without a build type (asserts on). lws' process-global log refcount raced between two concurrent contexts and `assert()` aborted the whole Asterisk process (reproduced with 2 threads in 0.23 s). | Asterisk crash under normal predictive-dialer concurrency. | No embedded event-loop library. Per-call state only; shared state is counters and one mutex-protected DB connection. |
| Each context allocated fd tables sized from `RLIMIT_NOFILE`: 16 MB and ~15 ms per call at `ulimit -n 1048576`. | Hundreds of MB of transient heap during call bursts, CPU on the channel thread right after answer. | Nothing per call beyond a small heap accumulator. |
| Static link recipe overwrote `LIBS` and dropped the MySQL client libraries; the published installer always used it. | The installed `.so` had undefined `mysql_*` symbols and could not be dlopen'ed. | No static libraries. `make check` runs `ldd -r` and fails the build on any unresolved symbol outside the Asterisk-provided set; the installer verifies the load and rolls back. |
| Result matched with `strstr()` in the order `HUMAN`, `MACHINE`, `AMD` on every frame: `"AMD"` matched the brand string `AMDY` in an ack; replies >= 256 bytes or fragmented were ignored. | Live humans hung up on (`MACHINE`) when the server's acks carried the brand name; long results silently lost. | `amd.py`'s rule and order (`HUMAN` first, then `AMD`/`MACHINE`, substring, case-sensitive) so verdicts match production, with one guard: `AMDY` is not `AMD` (see [protocol.md](protocol.md#classification-rule)); fragments reassembled. `NOT_HUMAN` still classifies `HUMAN`, exactly as in `amd.py`. |
| Per-call MySQL `connect + query` on the channel thread before anything else, with a connect timeout only (no read/write timeout); `astguiclient.conf` re-parsed on every call. | A slow DB delayed or froze the start of detection for every call. | One persistent connection, connect/read/write timeouts = `db_timeout_ms`, config parsed at load/reload, fails soft, skippable per call. |
| Hangup during detection was reported as `NOTSURE` / `TIMEOUT` and the code still flushed audio and waited the result grace on the dead channel. | Wrong statistics; h-extension and ViciDial hangup logging delayed. | `HANGUP` / `HANGUP` immediately; no grace wait after hangup. |
| Accumulator truncated frames that did not fit the 8000-byte chunk (30 ms and 60 ms packetisation lost 10-40 ms per chunk). | Periodic holes in the audio the classifier heard. | Carry-over accumulator; every byte is sent. |
| Fixed 500 ms chunks only; the documented 500/1000/1500/2000/3000/4000 ms schedule was not implemented; no `{"eof":1}`. | Diverged from `amd.py`. | Schedule implemented as configured (`send_schedule` with `amd.py`'s eleven marks, `chunk_bytes`, `fallback_interval_ms`); `{"eof":1}` sent on exit and for the early EOF finalisation. |
| No WebSocket close handshake. | Every call ended as an abnormal `1006` closure on the server. | `ast_websocket_close(ws, 1000)` on every exit path. |
| `AMDCAUSE` values (`CONNECT_FAILED`, `CONNECTION_TIMEOUT`, `CONTEXT_FAILED`, `TIMEOUT`, raw server text) did not match the `CONNECTION_ERROR`/`PROCESSING_ERROR`/`FATAL_ERROR` the production 8370 dialplan tests for, and `AMDSTATUS` was `NOTSURE` on errors. | The fallback to stock `AMD()` never triggered during an outage. | Frozen vocabulary identical to `amd.py` (`HUMAN` + `CONNECTION_ERROR`/`PROCESSING_ERROR`/`FATAL_ERROR`, `NOTSURE` + `SERVER_TIMEOUT`/`EOF_INCONCLUSIVE`/`EOF_ERROR`, the reply text as machine cause) plus stock `AMD()`'s `HANGUP` and `NOAUDIODATA-<ms>`; `AMDSTATS` set. Last reply also in `AMDRESPONSE`. |
| `load_module` returned `-1` (`AST_MODULE_LOAD_FAILURE`) on registration failure. | A duplicate `.so` in the modules directory would stop Asterisk from starting. | `AST_MODULE_LOAD_DECLINE`. |
| Channel not read during DB lookup, connect and result wait. | On Local channels the read queue overflowed after ~1.9 s and Asterisk discarded the oldest voice frames (the greeting). | The main loop starts as early as possible and the channel is serviced in every waiting phase. |
| Hand-rolled session counter and runtime-initialised mutex for unload safety. | Redundant with the core's use count; widened the unload race. | Core use count only; `AST_MUTEX_DEFINE_STATIC`. |
| Non-UTF-8 caller id names produced invalid TEXT frames. | Server could reject the config frame. | Invalid UTF-8 bytes replaced by `?`. |

The complete behaviour change list for operators is in
[migration-v1-to-v2.md](migration-v1-to-v2.md).

## Source layout

| Path | Role |
|---|---|
| `app_amd_ws.c` | The module. Sections: config loading, DB lookup (`#ifdef HAVE_MYSQL`), JSON helpers, classification, main loop, CLI, module glue. |
| `amd_ws.conf.sample` | Commented configuration reference. |
| `Makefile`, `ast-detect.sh` | Build: detect the running Asterisk and its headers, compile, gate, install. See [build-and-headers.md](build-and-headers.md). |
| `install.sh` | **Generated** by `tools/gen-installer.sh` from the four files above. Never edit by hand. See [installer.md](installer.md). |
| `tools/` | `gen-installer.sh`, `make-header-bundle.sh`, `check-embedded.sh`. |
| `test/` | Mock AMD server, minimal Asterisk configuration and `run.sh`. See [testing.md](testing.md). |
| `docs/` | This documentation. |
