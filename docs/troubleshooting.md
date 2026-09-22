# Troubleshooting playbook

Work top-down: first make sure the module is loaded and `AMD_WS()` actually
ran, then read `${AMDCAUSE}`, then follow the matching section. Every command
is meant to be pasted as-is on the telephony server as root.

## 0. Sixty-second health check

```bash
asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'module show like res_http_websocket'; asterisk -rx 'amd_ws show settings'; timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo "2700 open" || echo "2700 BLOCKED"; grep 'AMD_WS:' /var/log/asterisk/full | tail -5
```

Expected: both modules listed as `Running`, the settings dump with counters,
`2700 open`, and two `AMD_WS:` lines per recent call. Anything else points to
one of the sections below.

## 1. Log lines to grep

At verbose level 3 (`core set verbose 3`, or `verbose = 3` in `logger.conf`)
every call produces exactly two lines in `/var/log/asterisk/full` (or
`messages`, depending on `logger.conf`):

```text
AMD_WS: Local/8370@default-0000a1b2;1 vid=V9211234560000123 host=api.amdy.io:2700 play=amdy/insert
AMD_WS: Local/8370@default-0000a1b2;1 status=HUMAN cause=HUMAN elapsed=1830 sent=32000 chunks=4
```

| Question | Command |
|---|---|
| Outcome distribution today | `grep 'AMD_WS:.*status=' /var/log/asterisk/full \| sed 's/.*status=\([A-Z_]*\) cause=\([^ ]*\).*/\1 \2/' \| sort \| uniq -c \| sort -rn` (on a machine result the cause is the server's reply text, e.g. `MACHINE` or `AMD_DETECTED`) |
| Are we falling back to `AMD()`? | `grep -c 'cause=CONNECTION_ERROR\|cause=PROCESSING_ERROR\|cause=FATAL_ERROR' /var/log/asterisk/full` |
| What did ViciDial log for the call? | `mysql asterisk -e "SELECT AMDSTATUS,AMDRESPONSE,AMDCAUSE,run_time,AMDSTATS FROM vicidial_amd_log WHERE caller_code='V9211234560000123'"` (needs `AMD_LOG` 2 or 3 in `VD_amd.agi`; `AMDRESPONSE` there is `AMDCAUSE` cut at the first `-`, not the module's `${AMDRESPONSE}`) |
| One call, end to end | `grep 'V9211234560000123' /var/log/asterisk/full` (the VID) |
| Connect problems (rate-limited to one per 10 s per host) | `grep -i 'AMD_WS.*connect' /var/log/asterisk/full \| tail` |
| DB problems (rate-limited to one per minute) | `grep -i 'AMD_WS.*db\|AMD_WS.*mysql' /var/log/asterisk/full \| tail` |
| Module load errors | `grep -i 'app_amd_ws' /var/log/asterisk/full \| grep -i 'error\|not compiled\|undefined\|missing'` |
| Per-frame detail for one debugging session | `asterisk -rx 'core set debug 3 app_amd_ws'` then `asterisk -rx 'core set debug 0 app_amd_ws'` |

Phone numbers are not written to the log at normal verbosity; raise verbosity
only while debugging and lower it again. Credentials are never logged.

## 2. CLI commands

| Command | Use |
|---|---|
| `asterisk -rx 'module show like app_amd_ws'` | Is it loaded? The use-count column is the number of calls inside `AMD_WS()` right now. |
| `asterisk -rx 'core show application AMD_WS'` | Parameter and option reference from the running module. |
| `asterisk -rx 'amd_ws show settings'` | Effective configuration (after `amd_ws.conf`), `db : Yes (available)` / `No (available)` (disabled with `db=no`) / `No (unavailable (built without MySQL))`, whether `astguiclient.conf` was `read` (or `NOT READ - DB lookup skipped`), the DB server in use, `max_pending_connects`, per-outcome counters (calls, human, machine, and one per error / timeout / hangup cause, named as printed), `connects in flight` (helper threads currently connecting) and `parked connects` with a per-host breakdown (helper threads whose call already gave up, still waiting for a server that accepted TCP but never finished the WebSocket handshake; see [Known limitations](#4-known-limitations)). Counters are since module load. |
| `asterisk -rx 'module reload app_amd_ws.so'` | Re-read `/etc/asterisk/amd_ws.conf` and `/etc/astguiclient.conf`. |
| `asterisk -rx 'module load app_amd_ws.so'` | Load after install. Parse the reply, not the exit code (`asterisk -rx` always exits 0). |
| `asterisk -rx 'module unload app_amd_ws.so'` | Refused while a call is inside `AMD_WS()`. Retry when idle. |
| `asterisk -rx 'dialplan show 8370@default'` | Confirm the `AMD_WS(...)` line is what ViciDial's rebuilt dialplan actually contains. |
| `asterisk -rx 'core show channels concise' \| grep AMD_WS` | Calls currently in detection. |

## 3. Symptom → cause → check → fix

### Module does not load

| Log message | Cause | Fix |
|---|---|---|
| `Module 'app_amd_ws.so' was not compiled with the same compile-time options as this version of Asterisk` | The module was built against headers whose `AST_BUILDOPT_SUM` differs from the running core (wrong tree, distro `asterisk-dev` under a `-vici` core, `DEBUG_THREADS` build). | Rebuild with the matching headers: `make show-config` shows what was picked; pass `ASTTOPDIR=` or `--asterisk-src` to the exact tree. Never use `ASTNOCHECK=1` for production. See [build-and-headers.md](build-and-headers.md). |
| `Error loading module 'app_amd_ws.so': ... undefined symbol: <name>` | A library the module needs is not resolvable (e.g. the MySQL client library missing on this box). | `ldd -r $(asterisk -rx 'core show settings' \| awk -F': *' '/Module directory/{print $2}')/app_amd_ws.so \| grep undefined`. Install the MariaDB/MySQL client runtime, or rebuild with `MYSQL=0` / `--no-db`. `make check` catches this before install. |
| `Error loading module 'app_amd_ws.so', missing dependency: res_http_websocket` (the `.so` itself opens fine thanks to OPTIONAL_API; the loader then refuses to start it because of `.requires`) or `AMD_WS` exits `CONNECTION_ERROR` with a log line about `res_http_websocket` | `res_http_websocket.so` is not loaded (`noload` in `modules.conf`, or autoload off). | `asterisk -rx 'module load res_http_websocket.so'`; remove any `noload => res_http_websocket.so`; with `autoload=no` add `load => res_http_websocket.so` before `app_amd_ws.so`. |
| `module load app_amd_ws.so` answers `Unable to load module`, or `module show like app_amd_ws` shows `Not Running` | `load_module` declined: could not register the application (name already registered by another `.so`) or the CLI command. Asterisk keeps running; the module is simply not active. | `asterisk -rx 'core show application AMD_WS'` — if another module provides it, remove the duplicate `.so` (old copies/backups must not end in `.so`). Check the log for the reason. |
| Old code still running after an upgrade | The swap was refused because calls were inside `AMD_WS()`; installer exited 3. | Wait for idle, then `asterisk -rx 'module unload app_amd_ws.so'; asterisk -rx 'module load app_amd_ws.so'`, or restart Asterisk in a maintenance window. See [installer.md](installer.md#exit-codes). |

### `${AMDSTATUS}` and `${AMDCAUSE}` are empty

`AMD_WS()` never executed.

| Check | Fix |
|---|---|
| `asterisk -rx 'dialplan show 8370@default'` shows no `AMD_WS` line | ViciDial rebuilt the dialplan from its own template, or the edit was made in the wrong file. Re-add the line and `dialplan reload`, or fix the ViciDial dialplan entry and rebuild the telephony config. |
| `module show like app_amd_ws` shows nothing | Load the module (previous section). Asterisk logs `No application 'AMD_WS' for extension` when the app is missing. |
| Campaign Routing Extension is not `8370` | Set it in ViciDial and rebuild the telephony server config. Without the rebuild nothing changes. |

### Cause reference

Every `AMDCAUSE` the module can set, what it means, what `VD_amd.agi` does
with it, and where to look. The three error causes carry `AMDSTATUS=HUMAN`
on purpose: `amd.py` sets `HUMAN` when the service cannot be used
("defaulting to HUMAN for safety") so that a call is never dropped because of
an AMD problem, and the canonical 8370 block hands exactly these three to
stock `AMD()`. The detailed sections follow the table.

| `AMDCAUSE` | `AMDSTATUS` | Meaning | `VD_amd.agi` (see [README, routing table](../README.md#how-vd_amdagi-routes-each-outcome)) | Check | Fix |
|---|---|---|---|---|---|
| `HUMAN` | `HUMAN` | Server replied `HUMAN`. | Agent (`HUMAN,HUMAN` matches). | — | — |
| the reply text (`MACHINE`, `AMD`, ...) | `MACHINE` | Server replied with a text containing `MACHINE` or `AMD` (not `AMDY`). | Machine path: lead status `AA` (`AM`/`UNKAM` with a voicemail message), hangup. | `${AMDRESPONSE}` | Classification quality: review with the service. |
| `CONNECTION_ERROR` | `HUMAN` | No WebSocket: DNS, TCP, TLS or upgrade failed, connect timed out (`connect_timeout_ms`, 10 s), or `res_http_websocket` is not loaded. | With the 8370 fallback line: stock `AMD()` runs and its result decides. Without it: agent under the built-in rule; **machine path** under `HUMAN,HUMAN` (the second field is the cause). | [section below](#amdcauseconnection_error) | Firewall / DNS / service; load `res_http_websocket`. |
| `PROCESSING_ERROR` | `HUMAN` | Connected, then the server closed the connection before a result, a read or write failed, or a frame was malformed. | Same as `CONNECTION_ERROR`. | [section below](#amdcauseprocessing_error) | Server-side; middleboxes. |
| `FATAL_ERROR` | `HUMAN` | Inside Asterisk: allocation, read format, thread creation, option `A` on an unanswered channel, unusable configuration. | Same as `CONNECTION_ERROR`. | [section below](#amdcausefatal_error) | Dialplan / codec / config. |
| `SERVER_TIMEOUT` | `NOTSURE` | Audio was sent for `timeout_ms` (10 s) and the server never said `HUMAN` or `MACHINE`. | Agent under the built-in rule; machine path under `HUMAN,HUMAN` unless `NOTSURE,SERVER_TIMEOUT` is added. No `AMD()` fallback. | [section below](#amdcauseserver_timeout) | Server-side. |
| `NOAUDIODATA-<ms>` | `NOTSURE` | Not one audio frame was read from the channel in `timeout_ms`; `<ms>` is the elapsed window. Same shape as stock `AMD()`'s cause. | `$AMDRESPONSE` becomes `NOAUDIODATA`: with the container line `NOAUDIODATA-Hangup-ENABLED` the lead and log are set to `ADAIR` and the call is hung up; otherwise as `SERVER_TIMEOUT`. | [section below](#amdcausenoaudiodata-ms) | Media path. |
| `HANGUP` | `HANGUP` | The callee hung up, or the audio stream ended, before a result (stock `AMD()` sets the same status). | The channel is gone; `VD_amd.agi` exits on the built-in rule. | — | Normal. |
| `EOF_INCONCLUSIVE` | `NOTSURE` | The callee's audio stopped after some had been sent, the module sent `{"eof":1}` and the server answered with something that is neither `HUMAN` nor `MACHINE`. | As `SERVER_TIMEOUT`. | [section below](#amdcauseeof_inconclusive-and-eof_error) | Server-side. |
| `EOF_ERROR` | `NOTSURE` | Same trigger, but no reply within `eof_wait_ms` (3 s) or a send/receive error. | As `SERVER_TIMEOUT`. | [section below](#amdcauseeof_inconclusive-and-eof_error) | Server / network. |

### `AMDCAUSE=CONNECTION_ERROR`

Meaning: DNS, TCP connect, TLS or WebSocket handshake failed or timed out
(`connect_timeout_ms`, default 10000 ms), or `res_http_websocket` is not
loaded. `AMDSTATUS` is `HUMAN`; with the canonical block the dialplan falls
back to stock `AMD()`, so calls are still classified, but by the local
algorithm.

| Check | Command | Fix |
|---|---|---|
| Is TCP 2700 reachable from this box? | `timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo open \|\| echo blocked` | Open **outbound TCP 2700 to all addresses the service name resolves to** plus an `ESTABLISHED,RELATED` rule. Allowing only some of the service's addresses produces intermittent `CONNECTION_ERROR` (only some calls fail). |
| Does the name resolve? | `dig +short api.amdy.io` (or `getent hosts api.amdy.io`) | Fix `/etc/resolv.conf`; a resolver that answers slowly also eats into the connect budget. |
| Is `res_http_websocket` loaded? | `asterisk -rx 'module show like res_http_websocket'` | Load it (see "Module does not load"). |
| Are all calls failing or only some? | `grep -c 'cause=CONNECTION_ERROR' /var/log/asterisk/full` vs total `status=` lines | All: firewall/DNS/service down. Some: partial firewall allow-list, or the server refusing under load. |
| Every failing call takes exactly `connect_timeout_ms` | `AMDELAPSED` ≈ 10000 on those calls | The connect is black-holed (SYN dropped) rather than refused. With the default 10 s the callee waits about the whole detection window before `AMD()` runs; lower `connect_timeout_ms` (2000-3000 ms) if the service is often unreachable from this site, at the price of false errors on slow DNS or high RTT. |
| Wrong host/port in the dialplan? | `dialplan show 8370@default` | Fix the `AMD_WS(host,port,...)` arguments or `amd_ws.conf`. |
| Using `s` / `tls=yes` against a plain `ws://` endpoint? | log shows TLS/handshake failure | Remove `s` / set `tls=no`. |
| `wss://` fails with `did not match ()` | `tls_check_hostname=yes` on Asterisk 16, whose WebSocket client does not pass the hostname to the check | Set `tls_check_hostname=no` (the default); chain verification (`tls_verify`) still applies. |
| Log says `<N> connects to <host> still pending (max_pending_connects), failing fast with CONNECTION_ERROR` and `amd_ws show settings` shows `parked connects` at the cap for that host | The server accepts TCP but never completes the handshake (hung process, or a NAT/load balancer that black-holes the connection); each such call returned `CONNECTION_ERROR` at `connect_timeout_ms` but left a helper thread parked in the core's handshake read. Further calls to **that host** fail fast (other hosts are unaffected). | Fix or restart the server / firewall. The parked threads end the moment the peer closes the sockets (`parked connects` drops back to 0 by itself, one `Unable to retrieve HTTP status line.` ERROR each); if the old server never closes them (box dead, IP moved) they stay until Asterisk restarts, so `module unload` is refused and the cap stays reached — see [Known limitations](#4-known-limitations). `core show threads` lists them. |
| Calls fail at `connect_timeout_ms` in bursts of one every ~5 s while the WebSocket server is fine | The DB lookup, which runs inside the connect window, is stalling (see "DB lookup problems"). | Fix the DB path, lower `db_timeout_ms`, or `db=no`. |

### `AMDCAUSE=PROCESSING_ERROR`

Meaning: the WebSocket was up, and then the server closed it before sending a
result, a read or write on it failed, or a frame could not be parsed.
`AMDSTATUS` is `HUMAN`; the `AMD()` fallback applies with the canonical block.

| Check | Fix |
|---|---|
| `${AMDRESPONSE}` of the failing calls — the last text before the close | An error or account message: contact the AMD service with the VID. |
| Core log around the call: `Web socket closed abruptly` (server died without CLOSE), `Closing WS with 1011` (a write did not complete within the module's 500 ms bound) | Server-side incident, or a link whose RTT exceeds 500 ms while several frames are flushed at once (see [Known limitations](#4-known-limitations)). |
| Happens after a fixed number of seconds on every call | A proxy / NAT idle timer cutting the connection. Check the path between the dialer and the service. |

### `AMDCAUSE=FATAL_ERROR`

Meaning: something inside Asterisk, not the network: the channel read format
could not be set to `slin`, an allocation or the connect helper thread
failed, the configuration was unusable, or the channel was not up and option
`A` (do not answer) was given. `AMDSTATUS` is `HUMAN`; the `AMD()` fallback
applies.

| Check | Fix |
|---|---|
| Dialplan uses option `A` before the channel is answered | Answer first (`Answer()`) or drop `A` so `AMD_WS()` answers (the default). |
| `grep -i 'AMD_WS' /var/log/asterisk/full \| grep -i 'format\|alloc\|thread'` | Codec on the channel cannot be translated to `slin` — check `core show translation` and the channel's codec; a thread creation failure means the box is out of threads or memory. |
| `cannot open a socket: ... out of file descriptors?` | Asterisk is at its file-descriptor limit; the call exits `FATAL_ERROR` instead of risking the core's client code (which would crash on a failed `socket()`). Raise `maxfiles=` in `asterisk.conf` (`ulimit -n` for the Asterisk process) and look for the fd consumer (`ls /proc/$(pidof asterisk)/fd \| wc -l`, recordings, MixMonitor, leaks). |
| `FATAL_ERROR` on every call right after an upgrade | Header mismatch that the loader accepted (`ASTNOCHECK=1` was used). Rebuild properly. |

### `AMDCAUSE=SERVER_TIMEOUT`

Meaning: audio was captured and sent for the whole `timeout_ms` (default
10 s, plus `result_grace_ms`, default 0), and the server never sent a text
containing `HUMAN`, `MACHINE` or `AMD`. `AMDSTATUS` is `NOTSURE`.

| Check | Fix |
|---|---|
| `${AMDRESPONSE}` — what did the server last say? | Acks only (`{}`, `ack`): the server is connected but not classifying; server-side incident. A status word other than the three (for example `FAS`): the module, like `amd.py`, does not treat it as a result; the service decides what to send for such calls. |
| Response looks like an error or account message | Contact the AMD service with the VID; the module does not treat error text as a result on purpose. |
| `sent=` bytes in the end line is much lower than `16000 * elapsed/1000` | The channel delivered little audio (silence suppression, one-way audio). Check the media path. |
| Happens on every call | The server is accepting connections but not classifying. The `AMD()` fallback does not trigger for `SERVER_TIMEOUT` (it is not an error cause, `amd.py` behaves the same), so consider temporarily routing the campaign to extension 8369. |
| `${AMDRESPONSE}` is empty (not even an ack) | The server accepted the connection and never replied at all. The module reports this as `SERVER_TIMEOUT` at `timeout_ms`; `amd.py` would have sat in its blocking `recv()` for 10 s and reported `PROCESSING_ERROR` later (see [protocol.md](protocol.md#differences-from-amdpy-july-2026)). Same server-side incident either way. |

### `AMDCAUSE=NOAUDIODATA-<ms>`

Meaning: not one audio frame was read from the channel within `timeout_ms`;
`<ms>` is the elapsed window in milliseconds. This is the cause stock `AMD()`
sets in the same situation, and `VD_amd.agi` treats both the same: it strips
`-<ms>`, and if the campaign's `AMD_AGENT_OPT_<campaign>` container contains a
line `NOAUDIODATA-Hangup-ENABLED`, it sets the lead and `vicidial_log` status
to `ADAIR` (dead air) and hangs up; without that line the call follows the
normal `NOTSURE` routing. `AMDSTATS` and `AMDELAPSED` count from the
application start in this case.

| Check | Fix |
|---|---|
| Was the channel answered? | `AMD_WS()` answers by default; with `A` it does not. |
| Is RTP flowing? `asterisk -rx 'rtp set debug on'` during one call, then `rtp set debug off` | No incoming RTP: NAT, carrier, or SDP problem on the trunk. Not an AMD issue. |
| Is the `sip-silence` playback before `AMD_WS` working? | A broken sounds directory shows up here first. |
| Many `ADAIR` dispositions after switching from `amd.py` | Expected if the container has `NOAUDIODATA-Hangup-ENABLED`: `amd.py` never produced a `NOAUDIODATA` cause, so the option had no effect before. Remove the line to get the previous behaviour. |

### `AMDCAUSE=EOF_INCONCLUSIVE` and `EOF_ERROR`

Meaning: some audio had been sent, then the channel delivered **no frames at
all** across `eof_no_audio_streak` (2) consecutive schedule marks, so the
module sent `{"eof":1}` and waited `eof_wait_ms` (3 s) for the server's final
verdict ([protocol.md](protocol.md#5-eof-finalisation-no-audio-data-marks)).
`EOF_INCONCLUSIVE`: the server answered, but with neither `HUMAN` nor
`MACHINE`. `EOF_ERROR`: no answer in time, or the send/receive failed.
`AMDSTATUS` is `NOTSURE`. Digital silence does not trigger this; a trunk with
RTP silence suppression, or a carrier that stops sending RTP after the
greeting, does.

| Check | Fix |
|---|---|
| `AMDSTATS` third field (chunks sent) is small (2-3) and `AMDELAPSED` is between about 2 s and 6 s | Typical short greeting followed by no RTP: two empty marks, then up to 3 s waiting for the verdict. Nothing to fix on the dialer; the outcome is the server's. |
| `${AMDRESPONSE}` on `EOF_INCONCLUSIVE` | Acks only: the server did not finalise; contact the service with the VID. |
| `EOF_ERROR` on many calls | The server does not answer the `eof` within 3 s (server-side), or the network drops it. Raise `eof_wait_ms` only if the service asks for it. |
| You do not want the early finalisation | `eof_no_audio_streak=0` in `amd_ws.conf`: the call then runs to a result, `SERVER_TIMEOUT` or `HANGUP` (the behaviour of `amd.py` before July 2026). |

### `AMDSTATUS=HANGUP`

Normal: the callee hung up (or the audio stream ended) before a result.
Frequent `HANGUP` at very low `AMDELAPSED` means callees hang up on silence;
consider the playback feature (a short greeting in the detection window).
Stock `AMD()` sets the same status; `amd.py` reported this as `NOAUDIO`.

### Wrong classifications

| Symptom | Check | Fix |
|---|---|---|
| Machines reach agents | `amd_ws show settings` counters (`human` vs `machine`) and ViciDial's `AMD_AGENT_OPT_<campaign>` container | The container entry must be exactly `HUMAN,HUMAN`. With no container entry `VD_amd.agi` also sends `NOTSURE` and `HANGUP` to agents. |
| Error calls hung up as machines | `AMDCAUSE` is `CONNECTION_ERROR`/`PROCESSING_ERROR`/`FATAL_ERROR` and the 8370 block has no `AMD()` fallback line | With a container entry `HUMAN,HUMAN` those calls do not match (the second field is the cause). Add the fallback line from the README, or add `HUMAN,CONNECTION_ERROR`, `HUMAN,PROCESSING_ERROR`, `HUMAN,FATAL_ERROR` lines to the container. |
| Humans hung up on | `${AMDRESPONSE}` of those calls | The server returned a text containing `MACHINE` or `AMD`; review recordings with the service. A reply containing `NOT_HUMAN` classifies as `HUMAN` (substring rule, same as `amd.py`), never as `MACHINE`. |
| Audio the server hears is garbled | Playback file not 8 kHz mono; early `Playback(...)` in the dialplan | Convert with `sox in.wav -r 8000 -c 1 -b 16 out.wav`; remove stray `Playback` lines, let `AMD_WS()` play. |
| `vicidial_amd_log` insert fails on some calls | `VD_amd.agi` interpolates `AMDCAUSE` into SQL unquoted; a machine reply text containing `'` breaks it | Same exposure as with `amd.py` (which also puts the reply text in `AMDCAUSE`); ask the service to keep replies to plain words. |

### Playback problems

| Symptom | Cause | Fix |
|---|---|---|
| Nothing is heard | Wrong path or extension given | Path is relative to the sounds directory and has **no** extension: `amdy/insert`, not `/var/lib/asterisk/sounds/amdy/insert.wav`. Check `ls /var/lib/asterisk/sounds/amdy/` and the channel language directory. |
| Plays before detection starts | A `Playback()` line precedes `AMD_WS()` | Remove it; pass the file as the fifth argument. |
| Plays too early / too late | `playdelay_ms` / `d(ms)` | Adjust; `d(2000)` reproduces the 2 s of the EAGI playback variant. |
| Cut off mid-file | Result arrived | Intended: playback stops as soon as the server decides. |
| Garbled / chipmunk | Not 8 kHz mono 16-bit | `soxi file.wav` must say 8000 Hz, 1 channel; convert with `sox`. |

### DB lookup problems (phone / country not sent)

| Check | Fix |
|---|---|
| `amd_ws show settings` says `db : No (unavailable (built without MySQL))` | Built without the MySQL client (`MYSQL=0`, `--no-db`, or dev package missing at build time). Rebuild with the client dev package installed, or accept: detection works without enrichment. |
| `db=no` in `amd_ws.conf`, or option `n` / `p()` / `k()` in the dialplan | Intentional skip. |
| `AMD_WS: DB connect to <host>:<port> failed: ... (further DB warnings suppressed for 60 s)` in the log | Credentials or host in `/etc/astguiclient.conf` (`VARDB_server`, `VARDB_database`, `VARDB_user`, `VARDB_pass`, `VARDB_port`) wrong for this box, or the DB is unreachable. Test (prompts for `VARDB_pass`): `mysql -h "$(sed -n 's/^VARDB_server *=> *//p' /etc/astguiclient.conf)" -u "$(sed -n 's/^VARDB_user *=> *//p' /etc/astguiclient.conf)" -p asterisk -e 'SELECT 1'`. After fixing the file: `module reload app_amd_ws.so` (it is parsed at load/reload, not per call). |
| `AMD_WS: cannot read /etc/astguiclient.conf: ... lookup is skipped` NOTICE at load, `amd_ws show settings` says `NOT READ` | Not a ViciDial box, or `astguiclient_conf=` points elsewhere. No connection is attempted with built-in defaults. Fix the path in `amd_ws.conf` (or set `db=no`) and `module reload app_amd_ws.so`. |
| Calls end `CONNECTION_ERROR` at `connect_timeout_ms` in bursts of one every ~5 s while the WebSocket server is fine | The DB accepts TCP but stalls (firewall dropping after SYN-ACK, overloaded MySQL). The lookup runs on the connect helper thread inside the connect window; the socket timeouts are `db_timeout_ms` rounded up to whole seconds each, so a stall can eat the whole window, then the 5 s backoff skips the DB. The channel thread is never blocked by it. Fix the DB path, lower `db_timeout_ms`, or set `db=no` and let the server work without `phone`. |

### Concurrency / performance

| Symptom | Check | Fix |
|---|---|---|
| `Exceptionally long voice queue length queuing to Local/...` around `AMD_WS` | This meant the channel was not read for ~2 s. In 2.x the channel is serviced in every phase and neither DNS nor the DB lookup run on the channel thread; the only remaining ways are a partial server frame (up to 10 s, see [Known limitations](#4-known-limitations)) or a box under extreme load. | Keep server replies small; check `${AMDRESPONSE}` sizes and the box's load. |
| CPU or memory grows with call volume | `module show like app_amd_ws` use count vs `core show channels count` | 2.x keeps no per-call global state; report with `amd_ws show settings` output and a `core show channels concise` sample. |

## 4. Known limitations

Things the module cannot fix from its side; each is bounded and documented so
it is recognised quickly.

| Limitation | Where it comes from | What you see | Bound / mitigation |
|---|---|---|---|
| **Parked connect helpers.** A server that accepts TCP and ACKs the HTTP upgrade but never answers (hung process, SIGSTOP, OOM thrash) or a NAT/LB that black-holes the connection leaves one helper thread + one socket (~70 KB) per answered call parked in `res_http_websocket`'s handshake read, which has no timeout in 16, 18 and 20. The call itself returns `CONNECTION_ERROR` at `connect_timeout_ms`. | core `websocket_client_connect()`: the timeout covers only the TCP connect (`tcptls.c`), then the fd is blocking and the status line is read without a deadline. | `amd_ws show settings` → `parked connects` stays > 0 for that host after the calls ended; at `max_pending_connects` (64 per host; only helpers whose call already gave up count, a burst of healthy connects never trips it) new calls to that host fail fast with `CONNECTION_ERROR` and one WARNING per minute; `module unload app_amd_ws.so` is refused with 0 active channels (the helpers hold a module reference); `core show threads` lists them. | They are released the instant the peer closes (FIN/RST): server restart, firewall state flush. If the old host never closes (dead box, DNS failover to a new IP) they stay until `core restart`. The cap is per host, so a dead test host never disables production; size it with `max_pending_connects`. Core-side fix (for the `-vici` build or upstream): `ast_iostream_set_timeout_inactivity(ws->client->ser->stream, timeout)` before `websocket_client_handshake()` in `res_http_websocket.c`. The harness reproduces this (`blackhole`, `blackhole_fill`, `blackhole_cap`, `blackhole_release`). |
| **Partial server frame blocks the channel thread for up to 10 s.** | core `ws_safe_read()`: once the fd is readable it waits for the rest of a frame in 1 s steps, up to 10, then disconnects. | With a reply larger than one TCP segment and a lost segment (or a server dying mid-frame without RST), no channel frame is read for the TCP RTO or up to 10 s; on Local channels the read queue overflows after ~1.9 s and the oldest frames are dropped; hangup and playback timing are noticed late. No wrong result. | Keep server replies small (well under one MSS, ~1400 bytes; the one-word results are a few bytes). Not fixable for `wss://` from the module; for `ws://` a header-peek gate would be possible but is not implemented. |
| **Per-write bound 500 ms.** A WebSocket write that does not complete within 500 ms is turned into a CLOSE 1011 by the core → `PROCESSING_ERROR` for that call. | core `ast_websocket_write()` + the module's `WS_WRITE_TIMEOUT_MS`. | Only reachable when the connect took most of `connect_timeout_ms` and several 16 kB frames are flushed at once over a link whose RTT exceeds 500 ms, or the server stops reading. Logged as `Closing WS with 1011`. | The bound stays far below the ~1.9 s Local-channel queue limit; it was 100 ms in earlier 2.0 builds. Not covered by the harness: loopback socket buffers absorb any flush the module can produce, so a partial write cannot be provoked there. |
| **File-descriptor exhaustion.** `socket()` failing with EMFILE inside the core's client path dereferences NULL (`ast_tcptls_client_start_timeout(NULL, ...)` in `tcptls.c`, same in 16/18/20). | core. | The module probes with a throw-away `socket()` before starting the helper and exits `FATAL_ERROR` with a rate-limited WARNING instead; a probe that succeeds a few microseconds before the helper's own `socket()` fails cannot be excluded. | Raise `maxfiles=` in `asterisk.conf`; watch `ls /proc/<pid>/fd \| wc -l`. Core-side fix: NULL check at the top of `ast_tcptls_client_start_timeout()`. |
| **DB lookup budget is not a hard `db_timeout_ms` cap.** | MySQL client timeouts are whole seconds. | Waiting for the shared connection is bounded by `db_timeout_ms`; connect, read and write are each bounded by `ceil(db_timeout_ms / 1000)` s. A stalled DB can hold one lookup for a few seconds, once per 5 s backoff, and that call ends `CONNECTION_ERROR` (the lookup sits inside the connect window on the helper thread). | The channel thread is never blocked; lower `db_timeout_ms` or set `db=no`. |
| **Core log noise that is not a module bug.** | core | `WebSocket connection to ... closed` (verbose 2, every call), `Unable to retrieve HTTP status line.` (ERROR, when an abandoned helper's peer finally closes), `Web socket closed abruptly` (WARNING, server died without CLOSE), `SSL_shutdown() failed` (`wss://`, server closed first), `Missing closing parenthesis for argument ...` (WARNING from the core's option parser on a dialplan typo; it prints the unterminated argument). | Expected; grep for `AMD_WS:` lines for the module's own view. |

## 5. When to escalate to the AMD service

Have ready: the VID, `${AMDRESPONSE}`, the two `AMD_WS:` log lines of the
call, `amd_ws show settings`, the Asterisk version (`core show version`) and
the module version from the install log. Network reachability from the
telephony server (section "CONNECTION_ERROR") is the customer's side; classification
quality and account status are the service's side.

See also: [README](../README.md#troubleshooting-quick-table),
[protocol.md](protocol.md), [installer.md](installer.md).
