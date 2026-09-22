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
| Outcome distribution today | `grep 'AMD_WS:.*status=' /var/log/asterisk/full \| sed 's/.*status=\([A-Z_]*\) cause=\([A-Z_]*\).*/\1 \2/' \| sort \| uniq -c \| sort -rn` |
| Are we falling back to `AMD()`? | `grep -c 'cause=NETERR\|cause=INTERR' /var/log/asterisk/full` |
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
| `asterisk -rx 'amd_ws show settings'` | Effective configuration (after `amd_ws.conf`), DB `available`/`unavailable`, counters: calls, human, machine, other, neterr, interr, timeouts, hangups. Counters are since module load. |
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
| `Error loading module 'app_amd_ws.so', missing res_http_websocket` or `AMD_WS` exits `INTERR` with a log line about `res_http_websocket` | `res_http_websocket.so` is not loaded (`noload` in `modules.conf`, or autoload off). | `asterisk -rx 'module load res_http_websocket.so'`; remove any `noload => res_http_websocket.so`; with `autoload=no` add `load => res_http_websocket.so` before `app_amd_ws.so`. |
| `module load app_amd_ws.so` answers `Unable to load module`, or `module show like app_amd_ws` shows `Not Running` | `load_module` declined: could not register the application (name already registered by another `.so`) or the CLI command. Asterisk keeps running; the module is simply not active. | `asterisk -rx 'core show application AMD_WS'` — if another module provides it, remove the duplicate `.so` (old copies/backups must not end in `.so`). Check the log for the reason. |
| Old code still running after an upgrade | The swap was refused because calls were inside `AMD_WS()`; installer exited 3. | Wait for idle, then `asterisk -rx 'module unload app_amd_ws.so'; asterisk -rx 'module load app_amd_ws.so'`, or restart Asterisk in a maintenance window. See [installer.md](installer.md#exit-codes). |

### `${AMDSTATUS}` and `${AMDCAUSE}` are empty

`AMD_WS()` never executed.

| Check | Fix |
|---|---|
| `asterisk -rx 'dialplan show 8370@default'` shows no `AMD_WS` line | ViciDial rebuilt the dialplan from its own template, or the edit was made in the wrong file. Re-add the line and `dialplan reload`, or fix the ViciDial dialplan entry and rebuild the telephony config. |
| `module show like app_amd_ws` shows nothing | Load the module (previous section). Asterisk logs `No application 'AMD_WS' for extension` when the app is missing. |
| Campaign Routing Extension is not `8370` | Set it in ViciDial and rebuild the telephony server config. Without the rebuild nothing changes. |

### `AMDCAUSE=NETERR`

Meaning: DNS, TCP connect, TLS or WebSocket handshake failed or timed out
(`connect_timeout_ms`, default 2000 ms), or the server closed / errored the
connection before sending a result. The dialplan falls back to stock `AMD()`,
so calls are still classified, but by the local algorithm.

| Check | Command | Fix |
|---|---|---|
| Is TCP 2700 reachable from this box? | `timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo open \|\| echo blocked` | Open **outbound TCP 2700 to all addresses the service name resolves to** plus an `ESTABLISHED,RELATED` rule. Allowing only some of the service's addresses produces intermittent `NETERR` (only some calls fail). |
| Does the name resolve? | `dig +short api.amdy.io` (or `getent hosts api.amdy.io`) | Fix `/etc/resolv.conf`; a resolver that answers slowly also eats into the 2 s connect budget. |
| Are all calls failing or only some? | `grep -c 'cause=NETERR' /var/log/asterisk/full` vs total `status=` lines | All: firewall/DNS/service down. Some: partial firewall allow-list, or the server closing under load. Look at `${AMDRESPONSE}` of failing calls. |
| Is the connect budget too small for your RTT? | ping the host; compare with `connect_timeout_ms` | Raise `connect_timeout_ms` in `amd_ws.conf` or `c(ms)` per call. Do not go beyond a few seconds; the callee is waiting. |
| Wrong host/port in the dialplan? | `dialplan show 8370@default` | Fix the `AMD_WS(host,port,...)` arguments or `amd_ws.conf`. |
| Using `s` / `tls=yes` against a plain `ws://` endpoint? | log shows TLS/handshake failure | Remove `s` / set `tls=no`. |

### `AMDCAUSE=INTERR`

Meaning: something inside Asterisk, not the network: `res_http_websocket` not
loaded, the channel read format could not be set to `slin`, an allocation
failed, a bad internal state, or the channel was not up and option `A` (do not
answer) was given. The dialplan falls back to `AMD()`.

| Check | Fix |
|---|---|
| `module show like res_http_websocket` | Load it (see "Module does not load"). |
| Dialplan uses option `A` before the channel is answered | Answer first (`Answer()`) or drop `A` so `AMD_WS()` answers (the default). |
| `grep -i 'AMD_WS' /var/log/asterisk/full \| grep -i 'format\|alloc'` | Codec on the channel cannot be translated to `slin` — check `core show translation` and the channel's codec. |
| `INTERR` on every call right after an upgrade | Header mismatch that the loader accepted (`ASTNOCHECK=1` was used). Rebuild properly. |

### `AMDCAUSE=AUDIO_TIMEOUT`

Meaning: audio was captured and sent for the whole `timeout_ms` (default
10 s) plus `result_grace_ms`, and the server never sent a terminal status.

| Check | Fix |
|---|---|
| `${AMDRESPONSE}` — what did the server last say? | If it is a status token you expect (`GOOGLE_VOICE`, ...) that is not in `extra_statuses`, add it: `extra_statuses=HONEYPOT,FAS,FASAMD,AUDIO,NOTSURE,GOOGLE_VOICE` and `module reload app_amd_ws.so`. Tokens are matched whole, uppercased. |
| Response looks like an error or account message | Contact the AMD service with the VID; the module does not treat error text as a result on purpose. |
| `sent=` bytes in the end line is much lower than `16000 * elapsed/1000` | The channel delivered little audio (silence suppression, one-way audio). Check the media path. |
| Happens on every call | The server is accepting connections but not classifying. Server-side incident; the `AMD()` fallback does not trigger for `AUDIO_TIMEOUT`, so consider temporarily routing the campaign to extension 8369. |

### `AMDCAUSE=NO_AUDIO_TIMEOUT`

Meaning: not one voice frame was read from the channel within `timeout_ms`.

| Check | Fix |
|---|---|
| Was the channel answered? | `AMD_WS()` answers by default; with `A` it does not. |
| Is RTP flowing? `asterisk -rx 'rtp set debug on'` during one call, then `rtp set debug off` | No incoming RTP: NAT, carrier, or SDP problem on the trunk. Not an AMD issue. |
| Is the `sip-silence` playback before `AMD_WS` working? | A broken sounds directory shows up here first. |

### `AMDSTATUS=HANGUP`

Normal: the callee hung up before a result. Frequent `HANGUP` at very low
`AMDELAPSED` means callees hang up on silence; consider the playback feature
(a short greeting in the detection window).

### Wrong classifications

| Symptom | Check | Fix |
|---|---|---|
| Machines reach agents | `amd_ws show settings` counters (`human` vs `machine`) and ViciDial's `AMD_AGENT_OPT_<campaign>` container | The container entry must be exactly `HUMAN,HUMAN`. With no container entry `VD_amd.agi` also sends `NOTSURE` and `HANGUP` to agents. |
| Humans hung up on | `${AMDRESPONSE}` of those calls | The server returned `MACHINE`/`AMD`; review recordings with the service. The module never infers `MACHINE` from anything but a whole `MACHINE` or `AMD` token. |
| Everything `NOTSURE` with a classification-looking `AMDRESPONSE` | Token not in `extra_statuses` | Add it (see `AUDIO_TIMEOUT`). |
| Audio the server hears is garbled | Playback file not 8 kHz mono; early `Playback(...)` in the dialplan | Convert with `sox in.wav -r 8000 -c 1 -b 16 out.wav`; remove stray `Playback` lines, let `AMD_WS()` play. |

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
| `amd_ws show settings` says `db: unavailable` | Built without the MySQL client (`MYSQL=0`, `--no-db`, or dev package missing at build time). Rebuild with the client dev package installed, or accept: detection works without enrichment. |
| `db=no` in `amd_ws.conf`, or option `n` / `p()` / `k()` in the dialplan | Intentional skip. |
| Warning in the log about the DB (at most once per minute) | Credentials or host in `/etc/astguiclient.conf` (`VARDB_server`, `VARDB_database`, `VARDB_user`, `VARDB_pass`, `VARDB_port`) wrong for this box, or the DB is unreachable. Test: `mysql -h "$(sed -n 's/^VARDB_server *=> *//p' /etc/astguiclient.conf)" -u "$(sed -n 's/^VARDB_user *=> *//p' /etc/astguiclient.conf)" -p asterisk -e 'SELECT 1'`. After fixing the file: `module reload app_amd_ws.so` (it is parsed at load/reload, not per call). |
| Lookups slow down calls | They are bounded by `db_timeout_ms` (default 1000 ms) and fail soft, but a slow DB still adds up to that per call. Lower `db_timeout_ms`, or set `db=no` and let the server work without `phone`. |

### Concurrency / performance

| Symptom | Check | Fix |
|---|---|---|
| `Exceptionally long voice queue length queuing to Local/...` around `AMD_WS` | This meant the channel was not read for ~2 s. In 2.x the channel is serviced in every phase; if you see it, look for a DB stall (`db_timeout_ms`) or a very slow DNS resolver. | Fix DNS / DB, or `db=no`. |
| CPU or memory grows with call volume | `module show like app_amd_ws` use count vs `core show channels count` | 2.x keeps no per-call global state; report with `amd_ws show settings` output and a `core show channels concise` sample. |

## 4. When to escalate to the AMD service

Have ready: the VID, `${AMDRESPONSE}`, the two `AMD_WS:` log lines of the
call, `amd_ws show settings`, the Asterisk version (`core show version`) and
the module version from the install log. Network reachability from the
telephony server (section "NETERR") is the customer's side; classification
quality and account status are the service's side.

See also: [README](../README.md#troubleshooting-quick-table),
[protocol.md](protocol.md), [installer.md](installer.md).
