# app_amd_ws — `AMD_WS()` for Asterisk / ViciDial

`AMD_WS()` is an Asterisk dialplan application that performs Answering Machine
Detection by streaming the first seconds of an answered call to the amdy.io AMD
service over WebSocket and setting `${AMDSTATUS}` / `${AMDCAUSE}` /
`${AMDSTATS}` for the dialplan, with the same vocabulary as the production
EAGI client `amd.py` (July 2026) and stock `AMD()`, exactly where ViciDial's
extension 8370 and `VD_amd.agi` expect them.

Version 2 is a rewrite. It uses Asterisk's own WebSocket client
(`res_http_websocket`, shipped with every Asterisk since 13) instead of an
embedded libwebsockets, so there is nothing to compile from source apart from
the module itself, every wait is bounded by a real clock, hangups are detected
immediately, and a sound file can be played into the call while detection runs.
See [docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md) if you are
upgrading from 1.x.

## Contents

- [Requirements](#requirements)
- [Install (one command)](#install-one-command)
- [Manual build](#manual-build)
- [Dialplan usage](#dialplan-usage)
- [Channel variables](#channel-variables)
- [ViciDial integration](#vicidial-integration)
- [Configuration reference](#configuration-reference)
- [Parallel playback](#parallel-playback)
- [TLS](#tls)
- [CLI and logging](#cli-and-logging)
- [Troubleshooting quick table](#troubleshooting-quick-table)
- [Compatibility](#compatibility)
- [Documentation](#documentation)
- [License](#license)

## Requirements

| Item | Requirement |
|---|---|
| Asterisk | 16 or newer (ViciDial `16.30.1-vici`, `18.21.0-vici`, ViciBox `18.26.4-vici`, upstream 18/20/21/22). Asterisk 13 is not supported. |
| Asterisk module | `res_http_websocket.so` must be loadable (`module show like res_http_websocket`). It is part of every stock Asterisk build. |
| Headers | The `include/` tree of the **running** Asterisk build (or a header bundle for that version). Asterisk itself is never recompiled. See [docs/build-and-headers.md](docs/build-and-headers.md). |
| Toolchain | `gcc`, `make`, `pkg-config`, `binutils` (`strings`), `tar`, `curl`. |
| Optional | MariaDB/MySQL client development files for the ViciDial phone/country lookup (`libmariadb-dev`, `mariadb-devel`, `libmariadb-devel` or equivalent). Without them the module builds and runs with the DB lookup reported as unavailable. |
| Network | Outbound TCP to the AMD endpoint (default `api.amdy.io:2700`) from the telephony server. |
| Not required | libwebsockets (removed in 2.0.0), Asterisk source build, Asterisk restart. |

## Install (one command)

> **Which URL.** Until 2.0.0 is merged to `main` and tagged, `raw.githubusercontent.com/nikvb/amd/main/install.sh`
> still serves the **1.x installer** (libwebsockets build, repository changes, hangs up calls to unload).
> Use the branch URL below, or `sudo ./install.sh -y` from a checkout of the branch. After the release the
> URL becomes `https://raw.githubusercontent.com/nikvb/amd/v2.0.0/install.sh` (an immutable tag; its sha256 is
> published in the release notes).

As root on the ViciDial telephony server:

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- -y
```

The installer detects the running Asterisk, obtains matching headers, installs
the build dependencies (never touching Asterisk itself or your package
repositories), builds the module, backs up any previous `app_amd_ws.so`, loads
the new module without hanging up calls, and prints the dialplan snippet.
Everything it prints is also written to `/var/log/app_amd_ws-install.log`.

Common variants:

```bash
# see what would happen, change nothing
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- --dry-run

# no MySQL dependency, no DB lookup
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- -y --no-db

# remove the module again
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/feat/v2-res-http-websocket/install.sh | sudo bash -s -- --uninstall
```

All flags, exit codes and the header-resolution order are in
[docs/installer.md](docs/installer.md).

## Manual build

```bash
git clone -b feat/v2-res-http-websocket https://github.com/nikvb/amd.git && cd amd   # -b v2.0.0 once tagged
make show-config     # what Asterisk, version, headers and MySQL client were detected
make                 # builds app_amd_ws.so against the detected headers; the gates run here:
                     #   no unresolved symbols Asterisk cannot provide, correct build-option sum
make check           # the build plus a compile-only matrix against header bundles under ./bundles
sudo make install    # backs up the old .so, installs into the module directory, and puts
                     #   amd_ws.conf.sample into /etc/asterisk (an existing amd_ws.conf is never touched)
sudo make load       # or: make reload (unload + load, refused by Asterisk while a call is inside AMD_WS)
```

Useful overrides (all optional):

| Variable | Purpose |
|---|---|
| `ASTINCDIR=/path/to/include` | Use this header directory. |
| `ASTTOPDIR=/usr/src/asterisk/asterisk-18.21.0-vici` | Use `include/` of this configured and built source tree. |
| `ASTMODDIR=/usr/lib64/asterisk/modules` | Install here instead of the detected module directory. |
| `ASTNOCHECK=1` | Downgrade a build-option-sum mismatch from error to warning (not recommended). |
| `MYSQL=auto\|1\|0` | Detect / require / disable the MySQL client (default `auto`). |
| `MYSQL_CFLAGS=... MYSQL_LIBS=...` | Explicit MySQL client flags. |

More overrides (`WERROR=1`, `BUNDLES=`, `DESTDIR=`, `ASTETCDIR=`, `EXTRA_CPPFLAGS=`, `EXTRA_LIBS=`,
`AST_TIMEOUT=`, `ASTERISK=`, `ASTVERSION=`, `ASTBUILDSUM=`, `AST_SRC_ROOTS=`, `AST_INC_ROOTS=`) are listed
by `make help` and in [docs/build-and-headers.md](docs/build-and-headers.md).

Targets: `all`, `check`, `install`, `uninstall`, `clean`, `distclean`, `show-config`,
`installer` (regenerates `install.sh`), `test` (runs `test/run.sh`), `load`,
`unload`, `reload`, `help`. Details: [docs/build-and-headers.md](docs/build-and-headers.md).

## Dialplan usage

```text
AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])
```

| Parameter | Default | Meaning |
|---|---|---|
| `host` | `host=` from `amd_ws.conf` (built-in default `127.0.0.1`; the shipped sample sets `api.amdy.io`) | AMD server hostname or IP (an IPv6 literal such as `2001:db8::10` is accepted). |
| `port` | `port=` from `amd_ws.conf` (default `2700`) | TCP port. An invalid value logs a warning and uses the default. |
| `vid` | `${CALLERID(name)}` if valid and non-empty, else `Unknown` | Call tracking id sent to the server as `VID`. ViciDial puts its call id in the caller id name. |
| `timeout_ms` | `timeout_ms=` from `amd_ws.conf` (default `10000`, `amd.py`'s `MAX_WAIT_TIME`) | Overall detection window, measured from the first captured audio frame. Values `<= 0` use the default. |
| `playfile` | none | Sound file(s) to play into the channel while audio is captured. `Playback()` semantics: relative to the sounds directory, no extension, `&`-separated list plays in order, language taken from the channel. See [Parallel playback](#parallel-playback). |
| `options` | none | Flags, Asterisk application option style, see below. |

### Options

| Option | Meaning |
|---|---|
| `n` | No DB lookup for this call (phone/country are not sent unless given with `p()`/`k()`). |
| `s` | TLS: connect with `wss://` (needs Asterisk built with TLS; certificate verification per `tls_verify`). |
| `d(ms)` | Start playback `ms` milliseconds after the application starts (overrides `playdelay_ms`). |
| `c(ms)` | Connect timeout in milliseconds (overrides `connect_timeout_ms`, default 10000). |
| `p(phone)` | Send this phone number as `phone` (skips the DB lookup for the phone). |
| `k(code)` | Send this country/phone code as `country_code`. |
| `i(cid)` | Send this value as `caller_id` instead of the channel's `${CALLERID(num)}` (see [Caller id](#caller-id)). |
| `a` | Answer the channel if it is not up. This is the default. |
| `A` | Do **not** answer. If the channel is not up the application exits with `HUMAN` / `FATAL_ERROR`. |

The application always returns 0 to the dialplan; use the channel variables to
branch. `core show application AMD_WS` prints the same reference.

## Channel variables

Set on every exit path:

| Variable | Values |
|---|---|
| `AMDSTATUS` | `HUMAN`, `MACHINE`, `NOTSURE` or `HANGUP` — the four values stock `AMD()` uses and `VD_amd.agi` tests for. |
| `AMDCAUSE` | `HUMAN` on a human result; the server's raw reply text on a machine result (`MACHINE`, `AMD`, `AMD_DETECTED`, ...); otherwise one of `CONNECTION_ERROR`, `PROCESSING_ERROR`, `FATAL_ERROR`, `SERVER_TIMEOUT`, `NOAUDIODATA-<ms>`, `HANGUP`, `EOF_INCONCLUSIVE`, `EOF_ERROR`. Sanitised to printable ASCII, at most 255 characters. |
| `AMDSTATS` | `<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>`, four integers, on every exit. `VD_amd.agi` stores the part before the first `-` as `run_time` in `vicidial_amd_log`, exactly as it does for stock `AMD()`. |
| `AMDRESPONSE` | Raw last text the server sent, sanitised to printable ASCII, at most 255 characters. New in 2.0.0. Note that `VD_amd.agi` has its **own** `$AMDRESPONSE` (it is `AMDCAUSE` cut at the first `-`, see the next section) and never reads this variable. |
| `AMDELAPSED` | Milliseconds from the first captured audio frame to exit (from the application start when no audio was ever captured). New in 2.0.0. |

Status/cause matrix (frozen; each row names where the value comes from):

| Situation | `AMDSTATUS` | `AMDCAUSE` | Same as |
|---|---|---|---|
| Server replied `HUMAN` | `HUMAN` | `HUMAN` | `amd.py` |
| Server replied `MACHINE` or `AMD` (any text containing one of them; the brand string `AMDY` does not count) | `MACHINE` | the raw reply text | `amd.py` |
| Cannot connect: DNS, TCP, TLS or WebSocket upgrade failure, connect timeout, `res_http_websocket` not loaded | `HUMAN` | `CONNECTION_ERROR` | `amd.py` ("defaulting to HUMAN for safety") |
| WebSocket error after the connect: server closed before a result, read/write error, malformed frame | `HUMAN` | `PROCESSING_ERROR` | `amd.py` |
| Internal failure: allocation, channel read format, thread creation, option `A` on an unanswered channel, unusable configuration | `HUMAN` | `FATAL_ERROR` | `amd.py` |
| `timeout_ms` elapsed, audio was sent, no result | `NOTSURE` | `SERVER_TIMEOUT` | `amd.py` |
| `timeout_ms` elapsed and **no audio was ever captured** | `NOTSURE` | `NOAUDIODATA-<ms>` (`<ms>` = the elapsed window) | stock `AMD()`; `VD_amd.agi` keys its `ADAIR` handling on it |
| Channel hung up (or the audio stream ended) before a result | `HANGUP` | `HANGUP` | stock `AMD()` status; `VD_amd.agi` |
| EOF finalisation (two schedule marks with no audio after audio had been sent) answered with something that is neither `HUMAN` nor `MACHINE` | `NOTSURE` | `EOF_INCONCLUSIVE` | `amd.py` |
| EOF finalisation send/receive error or no reply within `eof_wait_ms` | `NOTSURE` | `EOF_ERROR` | `amd.py` |

`CONNECTION_ERROR`, `PROCESSING_ERROR` and `FATAL_ERROR` are the three values
the ViciDial dialplan uses to fall back to the stock `AMD()` application (next
section). They come with `AMDSTATUS=HUMAN`, exactly as `amd.py` sets them, so
that a call is never lost because the AMD service was unreachable. Two rows
deliberately differ from `amd.py` in favour of stock `AMD()` / `VD_amd.agi`
vocabulary: `amd.py`'s `NOAUDIO`/`NOAUDIO` on end of stream is `HANGUP`/`HANGUP`
here, and its no-audio timeout cause is `NOAUDIODATA-<ms>`; the reasons are in
[docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md#why-two-values-follow-stock-amd-instead-of-amdpy).

## ViciDial integration

### Extension 8370

This is the canonical ViciDial AI-AMD block with the `EAGI(amd.py)` line
replaced by `AMD_WS()`. Everything else (call logging, the fallback to stock
`AMD()` on the three error causes, `VD_amd.agi`) stays as it is.

If you keep the EAGI script instead of the module, use
[`agi/amd.py`](agi/README.md): the production `amd.py` (2.2) with the same
stock-`app_amd` vocabulary for no-audio (`NOAUDIODATA-<ms>`) and hangup
(`HANGUP`) and a numeric `AMDSTATS`, so both integrations behave the same in
`VD_amd.agi`.

```text
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000)
exten => 8370,n,GotoIf($["${AMDCAUSE}" = "CONNECTION_ERROR" | "${AMDCAUSE}" = "PROCESSING_ERROR" | "${AMDCAUSE}" = "FATAL_ERROR"]?amd_fallback:continue)
exten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)
exten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
```

On the three error causes `AMD_WS()` has already set `AMDSTATUS=HUMAN` (as
`amd.py` does); the `GotoIf` line then lets stock `AMD()` overwrite
`AMDSTATUS`, `AMDCAUSE` and `AMDSTATS` with its own result. That fallback is
the dialplan's choice, not the module's: without the line, error calls stay
`HUMAN` and are routed as described under
[How `VD_amd.agi` routes each outcome](#how-vd_amdagi-routes-each-outcome).

Parallel-playback variant (plays `/var/lib/asterisk/sounds/amdy/insert.wav`
into the call 2 s after AMD_WS starts, while audio keeps streaming to the
AMD service):

```text
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000,amdy/insert,d(2000))
```

Do not add a separate `Playback(amdy/insert)` line: it would play before
detection starts. Let `AMD_WS()` play it.

After editing the dialplan: `asterisk -rx 'dialplan reload'`. In ViciDial set
the campaign's **Routing Extension** to `8370`, **AMD Agent Route Options** to
`ENABLED`, and the `AMD_AGENT_OPT_<campaign>` container entry to exactly
`HUMAN,HUMAN`, then rebuild the telephony server config. No dialplan
branching on `AMDSTATUS` is needed beyond the fallback line.

### How `VD_amd.agi` routes each outcome

`VD_amd.agi` reads `AMDSTATUS`, `AMDCAUSE` and `AMDSTATS`, builds its own
`$AMDRESPONSE` = `AMDCAUSE` cut at the first `-` (so `NOAUDIODATA-10000`
becomes `NOAUDIODATA`), logs all of them to `vicidial_amd_log` (with the
first field of `AMDSTATS` as `run_time`), and then decides:

- **No `AMD_AGENT_OPT_<campaign>` container entry**: the built-in rule sends
  `AMDSTATUS` matching `PERSON|HUMAN|NOTSURE|HANGUP` to an agent; only
  `MACHINE` takes the answering-machine path.
- **With a container entry**: only lines that match both fields,
  `<AMDSTATUS>,<$AMDRESPONSE>`, send the call to an agent; everything else
  takes the answering-machine path. `HUMAN,HUMAN` therefore matches a human
  result and nothing else. A line `NOAUDIODATA-Hangup-ENABLED` additionally
  makes `VD_amd.agi` set the lead and log status to `ADAIR` (dead air) and
  hang up when `$AMDRESPONSE` starts with `NOAUDIODATA`.

| `AMD_WS()` result | Built-in rule (no container) | Container `HUMAN,HUMAN` | Notes |
|---|---|---|---|
| `HUMAN` / `HUMAN` | agent | agent | |
| `MACHINE` / `<reply>` | machine path | machine path | Lead status `AA` (or `AM`/`UNKAM` when a voicemail message is configured), hangup. |
| `HUMAN` / `CONNECTION_ERROR`, `PROCESSING_ERROR`, `FATAL_ERROR` | agent | **machine path** (the second field does not match) | With the canonical block stock `AMD()` runs first and its result decides. Without the fallback line, add `HUMAN,CONNECTION_ERROR` (etc.) to the container if error calls should reach agents, as `amd.py` intends. |
| `NOTSURE` / `SERVER_TIMEOUT`, `EOF_INCONCLUSIVE`, `EOF_ERROR` | agent | machine path | Add `NOTSURE,SERVER_TIMEOUT` (etc.) to the container to send them to agents. |
| `NOTSURE` / `NOAUDIODATA-<ms>` | agent | machine path; with `NOAUDIODATA-Hangup-ENABLED`: status `ADAIR`, hangup | Same as stock `AMD()` with no audio. |
| `HANGUP` / `HANGUP` | agent path (the channel is already gone) | machine path (channel gone) | Same as stock `AMD()` on hangup. |

### Where the VID comes from

ViciDial sets the caller id name of the outbound leg to its call identifier
(the `callerid` column of `vicidial_auto_calls`). `AMD_WS()` uses
`${CALLERID(name)}` as the `VID` by default, so the third argument can also be
left empty: `AMD_WS(api.amdy.io,2700,,10000)`. If the caller id name is empty
or invalid, `Unknown` is sent.

### Caller id

The config frame also carries `caller_id`: the channel's `${CALLERID(num)}`,
which on a ViciDial outbound leg is the outbound caller id the campaign
presents. It is sent only when it is non-empty and not `Unknown` — the same
rule `amd.py` (July 2026) applies to `agi_callerid`; the service logs it with
the detection. Option `i(cid)` sends a different value, `send_caller_id=no` in
`amd_ws.conf` turns it off.

### Phone / country enrichment

When built with the MySQL client and `db=yes` (the default), the module looks up
`phone_code` and `phone_number` for the VID in `vicidial_auto_calls`
(`SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid='<vid>'
ORDER BY auto_call_id DESC LIMIT 1`) using the `VARDB_*` credentials in
`/etc/astguiclient.conf`, and sends them as `phone` and `country_code` in the
config frame. The file is parsed once at module load and on
`module reload app_amd_ws.so`; if it cannot be read, or contains no `VARDB_`
line, the lookup is skipped (one NOTICE in the log, `amd_ws show settings`
says `NOT READ` or `NO VARDB_ LINES`), exactly as `amd.py` skips it on
"DB ERROR: no config". The query
runs on the per-call connect helper thread, right before the WebSocket
connect, never on the channel thread; it uses one persistent connection and
fails soft: on any DB problem the call proceeds without `phone`, and a warning
is logged at most once per minute. Time budget: waiting for the shared
connection is bounded by `db_timeout_ms` (default 1000 ms); the connect, read
and write socket timeouts are each `db_timeout_ms` rounded **up** to whole
seconds (minimum 1 s), so a DB that accepts TCP but stalls can hold one lookup
for a few seconds, once per 5 s backoff. Because the lookup sits inside the
connect window, such a stall costs that call its connect (`CONNECTION_ERROR`,
`AMD()` fallback) rather than audio. Credentials are never logged. The query
is the one `amd.py` runs; `phone` and `country_code` are omitted from the
config frame when the row is missing or the column is empty.

Ways to skip the lookup: `db=no` in `amd_ws.conf`, option `n` per call, or
supply the values yourself with `p(<phone>)` / `k(<code>)`.

## Configuration reference

`/etc/asterisk/amd_ws.conf` is optional; every key is optional. A commented
copy is shipped as `amd_ws.conf.sample`. Changes are picked up by
`module reload app_amd_ws.so`.

```ini
[general]
host=api.amdy.io
port=2700
tls=no
tls_verify=yes
tls_cafile=
tls_check_hostname=no
timeout_ms=10000
connect_timeout_ms=10000
result_grace_ms=0
send_schedule=500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000
chunk_bytes=8000
fallback_interval_ms=1000
eof_no_audio_streak=2
eof_wait_ms=3000
send_caller_id=yes
playdelay_ms=0
db=yes
db_timeout_ms=1000
astguiclient_conf=/etc/astguiclient.conf
max_pending_connects=64
```

The timing and transport defaults are `amd.py`'s constants (`MAX_WAIT_TIME`,
`CONNECTION_TIMEOUT`, `SEND_TIMES`, `FALLBACK_CHUNK_SIZE`, the 1 s fallback
interval, the 2-mark / 3 s EOF finalisation).

| Key | Built-in default | Meaning |
|---|---|---|
| `host` | `127.0.0.1` | Default AMD server when the dialplan gives none. The sample sets `api.amdy.io`. |
| `port` | `2700` | Default TCP port. |
| `tls` | `no` | `yes` connects with `wss://` for every call (same as option `s`). |
| `tls_verify` | `yes` | Verify the server certificate when TLS is used. |
| `tls_cafile` | empty | CA bundle used to verify the server certificate when TLS is on. Empty = the first existing system bundle (`/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`, `/etc/ssl/ca-bundle.pem`, `/etc/ssl/cert.pem`), else the directory `/etc/ssl/certs`. |
| `tls_check_hostname` | `no` | Also require the certificate's CN/subjectAltName to match `host`. Keep `no` on Asterisk 16 (its WebSocket client does not hand the hostname to the check, so every `wss://` connect would fail with `did not match ()`); works on 18+. |
| `timeout_ms` | `10000` | Default detection window, measured from the first captured audio frame (`amd.py` measures from its stream start, which on a leg that delivers audio at once is the same instant). |
| `connect_timeout_ms` | `10000` | WebSocket connect (DNS + TCP + handshake) timeout, `amd.py`'s `CONNECTION_TIMEOUT`; the optional DB lookup runs inside this window. Trade-off: a lower value (2000-3000 ms) returns `CONNECTION_ERROR`, and therefore the `AMD()` fallback, sooner when the service is unreachable, at the price of false errors on a slow DNS or a high-RTT path; the connect never adds to the detection window because it is cut at the detection deadline anyway. |
| `result_grace_ms` | `0` | After `timeout_ms` with no result, the remaining audio is sent and the module waits this long for a reply (still detecting hangup) before `SERVER_TIMEOUT`. `amd.py` has no grace period, hence `0`; the key stays for sites that want one. |
| `send_schedule` | `500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000` | Milliseconds from the first captured frame at which everything accumulated so far is sent (`amd.py` `SEND_TIMES`). A single value such as `500` means plain fixed-interval chunks. |
| `chunk_bytes` | `8000` | After the last schedule mark, send whenever this many bytes have accumulated (8000 B = 500 ms of 8 kHz 16-bit audio). |
| `fallback_interval_ms` | `1000` | After the last schedule mark, also send whenever this much time has passed since the last send and the buffer is not empty. |
| `eof_no_audio_streak` | `2` | Number of consecutive schedule marks at which **no audio at all** had been captured since the previous send that triggers the EOF finalisation (`{"eof":1}`, then wait for one reply), provided some audio was sent earlier. `0` disables it. Digital silence is audio; only a channel that delivers no frames counts. |
| `eof_wait_ms` | `3000` | How long the EOF finalisation waits for the server's reply (hangup still detected). No reply in time = `EOF_ERROR`. |
| `send_caller_id` | `yes` | Send `${CALLERID(num)}` as `caller_id` in the config frame (when non-empty and not `Unknown`). Option `i(cid)` overrides the value. |
| `playdelay_ms` | `0` | Delay from the application start before `playfile` starts. |
| `db` | `yes` | Enable the ViciDial phone/country lookup (only when compiled with MySQL support). |
| `db_timeout_ms` | `1000` | Time budget for the lookup: bound for waiting on the shared connection; connect/read/write socket timeouts are this value rounded up to whole seconds (minimum 1). |
| `astguiclient_conf` | `/etc/astguiclient.conf` | Where to read `VARDB_*` credentials. Unreadable file, or no `VARDB_` line in it = lookup skipped (NOTICE once), as `amd.py` does. |
| `max_pending_connects` | `64` | Per-host cap on connect helper threads left parked by a server that accepts TCP but never answers the handshake (counted only after their call gave up; healthy bursts are never capped); beyond it calls to that host fail fast with `CONNECTION_ERROR` (range 8..1024). See [docs/troubleshooting.md](docs/troubleshooting.md#4-known-limitations). |

There is no list of "extra" server statuses any more: like `amd.py`, the module
treats every reply that contains neither `HUMAN` nor `MACHINE`/`AMD` as an
acknowledgement and keeps streaming (see [docs/protocol.md](docs/protocol.md#4-server-replies-server--client-text)).

## Parallel playback

The optional fifth argument plays sound into the channel *while* the callee's
audio is being captured and sent, so a greeting or an ambiguous prompt can mask
the detection window without blinding detection:

- `Playback()` semantics: path relative to the sounds directory, no extension,
  `&` separates several files, language from the channel
  (`amdy/insert`, `custom/hello&custom/pause`).
- Playback starts after `playdelay_ms` / `d(ms)` (default 0).
- Playback is stopped the moment a terminal result arrives, on hangup, and when
  the application exits.
- The end of the file(s) does **not** end detection; detection continues until
  result, timeout or hangup.
- Keep the file 8 kHz mono 16-bit (`sox in.wav -r 8000 -c 1 -b 16 out.wav`) to
  avoid transcoding on the channel thread.

## TLS

Option `s` or `tls=yes` connects with `wss://` using Asterisk's own TLS support;
`tls_verify`, `tls_cafile` and `tls_check_hostname` control certificate
verification (chain verification works on every supported Asterisk; hostname
matching only on 18+, see the table above). Use TLS only
against an endpoint that offers it; the production endpoint documented for the
amdy.io service is plain `ws://api.amdy.io:2700`. If Asterisk was built
without TLS, a `wss://` connection cannot be made; the call ends `HUMAN` /
`CONNECTION_ERROR` with a log line saying why, and the dialplan fallback
applies.

## CLI and logging

| Command | Shows |
|---|---|
| `asterisk -rx 'module show like app_amd_ws'` | Module loaded, use count (calls currently inside `AMD_WS`). |
| `asterisk -rx 'core show application AMD_WS'` | Syntax, parameters, options, variables. |
| `asterisk -rx 'amd_ws show settings'` | Effective configuration, DB availability, whether `astguiclient.conf` was read, per-outcome counters since module load (calls, human, machine, and one per error / timeout / hangup cause, named as the command prints them), `connects in flight` (helper threads currently connecting) and `parked connects` per host (helpers left behind by a server that never finishes the handshake; capped by `max_pending_connects`). |
| `asterisk -rx 'module reload app_amd_ws.so'` | Re-read `amd_ws.conf` and `astguiclient.conf`. |
| `asterisk -rx 'module unload app_amd_ws.so'` | Refused by the core while a call is inside `AMD_WS` (this is intended). |

At verbose level 3 every call writes exactly two lines:

```text
AMD_WS: <channel> vid=<vid> host=<host>:<port> play=<file|none>
AMD_WS: <channel> status=<AMDSTATUS> cause=<AMDCAUSE> elapsed=<ms> sent=<bytes> chunks=<n>
```

Repeated connect failures to the same host are logged as warnings at most once
per 10 s; DB problems at most once per minute. `core set debug 3 app_amd_ws`
adds per-frame detail.

## Troubleshooting quick table

| `AMDCAUSE` (`AMDSTATUS`) | Meaning | Check | Fix |
|---|---|---|---|
| `CONNECTION_ERROR` (`HUMAN`) | Could not connect: DNS, TCP, TLS, WebSocket upgrade, connect timeout (`connect_timeout_ms`, 10 s), `res_http_websocket` not loaded | `timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo open`; `grep 'AMD_WS' /var/log/asterisk/full \| grep -c CONNECTION_ERROR`; `dig +short api.amdy.io`; `module show like res_http_websocket` | Open outbound TCP 2700 (all AMD service addresses) on the firewall; fix DNS; `module load res_http_websocket.so`. The dialplan fallback to `AMD()` keeps calls classified meanwhile. |
| `PROCESSING_ERROR` (`HUMAN`) | Connected, then the server closed or errored before a result, or a frame could not be read/written | `${AMDRESPONSE}` (last server text); `grep 'AMD_WS' /var/log/asterisk/full \| grep -c PROCESSING_ERROR`; server-side logs for the VID | Server-side incident, or a middlebox cutting idle WebSockets. The `AMD()` fallback applies. |
| `FATAL_ERROR` (`HUMAN`) | Module-internal: allocation, read format could not be set, thread could not be created, channel not up with option `A`, configuration unusable | `module show like app_amd_ws`; `AMD_WS` warnings in the log; `core show translation` | If the channel is not answered before `AMD_WS`, drop option `A` or answer first; fix the codec path; fix `amd_ws.conf`. The `AMD()` fallback applies. |
| `SERVER_TIMEOUT` (`NOTSURE`) | Audio was sent for `timeout_ms` (10 s) but the server never returned `HUMAN` or `MACHINE` | `${AMDRESPONSE}`; `amd_ws show settings` counters; server-side logs for the VID | Server-side (still connected, not classifying). No dialplan fallback; `VD_amd.agi` treats `NOTSURE` per its container rule. |
| `NOAUDIODATA-<ms>` (`NOTSURE`) | No audio frame was ever read from the channel within `timeout_ms` | Is the channel answered and is RTP flowing? `rtp set debug on`; check `Playback(sip-silence)` succeeded | Fix the media path (NAT, carrier, codec). Not an AMD-service problem. `VD_amd.agi` can dispo these `ADAIR` and hang up (`NOAUDIODATA-Hangup-ENABLED` container line). |
| `EOF_INCONCLUSIVE` / `EOF_ERROR` (`NOTSURE`) | The callee's audio stopped after some had been sent; the module asked the server to finalise (`{"eof":1}`) and got no usable answer within `eof_wait_ms` (3 s) | `${AMDRESPONSE}`; how many chunks were sent (`AMDSTATS`); RTP silence suppression on the trunk | Server-side for `EOF_INCONCLUSIVE`; for `EOF_ERROR` check the server and the network. Only a channel that delivers **no frames** triggers this; digital silence does not. |
| `HANGUP` (`HANGUP`) | Callee hung up, or the audio stream ended, before a result | none | Normal. |
| `HUMAN` or a machine reply, but wrong | Classification quality | `${AMDRESPONSE}`, recording of the call, `AMDELAPSED` | Review with the AMD service; check that the audio reaching the server is 8 kHz clean speech (no early `Playback` in the dialplan). |
| variables empty | `AMD_WS()` never ran | `dialplan show 8370@default`; `module show like app_amd_ws`; ViciDial Routing Extension and rebuilt config | Load the module, fix the dialplan, rebuild the telephony config. |

Full playbook, log lines to grep and module-load errors:
[docs/troubleshooting.md](docs/troubleshooting.md).

## Compatibility

| Asterisk | Status | Notes |
|---|---|---|
| 16.x (`16.30.1-vici`) | Supported, primary target | Reference tree used for development and the test harness. |
| 18.x (`18.21.0-vici`, `18.26.4-vici`, distro 18) | Supported | `res_http_websocket` API identical to 16. |
| 20 / 21 / 22 | Supported | The module compiles warning-free against 20.x headers; the client-options API used is present. |
| 13 and older | Not supported | Different `struct ast_module_info` layout; out of scope. |

Where the headers come from, per install type:

| Install type | Typical Asterisk | Headers used by the build | Notes |
|---|---|---|---|
| ViciDial scratch install (tarball from `download.vicidial.com/required-apps`, `./configure && make install`) | `16.30.1-vici`, `18.21.0-vici` | `/usr/include` (installed by `make install`) and the configured source tree, usually `/usr/src/asterisk/asterisk-<ver>-vici` or `/usr/src/asterisk-<ver>-vici` | Both contain `autoconfig.h` and `buildopts.h`; detected automatically. |
| ViciBox (openSUSE RPM from OBS `home:vicidial`) | `18.26.4-vici` | `asterisk-devel` RPM pinned to the exact installed version | The OBS `asterisk-18` project publishes `asterisk-devel`; the `asterisk-13`/`asterisk-16` projects publish nothing any more, so those boxes need a header bundle or the vendor tarball. **No header bundles are published at `download.amdy.io` yet**; until they are, such a box needs `--asterisk-src DIR`, `--headers DIR`, or `--allow-configure` (the `-vici` tarball has no `autoconfig.h`; `./configure` needs the extra `-devel` packages the installer names). Never install an unpinned `asterisk-devel`: it pulls a different Asterisk. |
| Debian / Ubuntu distro package | `16.28` (bullseye), `18.10` (jammy), `20.6` (noble) | `asterisk-dev=<exact installed version>` | Only correct when the running Asterisk **is** the distro package. A scratch-installed `-vici` binary with a distro `asterisk-dev` present is a mismatch; detection rejects it by build-option sum / version. |
| RHEL family scratch install (CentOS 7, Alma/Rocky 8-9) | `18.21.0-vici` | Same as ViciDial scratch install | |
| Anything else (upstream source, custom prefix, GIT builds) | 16-22 | `ASTTOPDIR=`/`ASTINCDIR=` override, `<prefix>/include`, or a header bundle (none published yet) | For unknown versions pass `--version` / `--headers` to the installer. |

Details and the detection algorithm: [docs/build-and-headers.md](docs/build-and-headers.md).

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Call flow, threading model, why `res_http_websocket`, v1 failure modes. |
| [docs/protocol.md](docs/protocol.md) | Wire protocol (`amd.py`, July 2026) with an example of every frame, the EOF finalisation and the classification rule. |
| [docs/build-and-headers.md](docs/build-and-headers.md) | Why no Asterisk recompile is needed, what must match, header detection, bundles, distro matrix. |
| [docs/installer.md](docs/installer.md) | `install.sh` flags, exit codes, system changes, upgrade, rollback, uninstall. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause → check → fix playbook, log lines, CLI. |
| [docs/testing.md](docs/testing.md) | Test harness overview. |
| [docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md) | Behaviour changes from 1.x; status/cause mapping 1.x → `amd.py` → 2.0. |
| [agi/README.md](agi/README.md) | The EAGI client `agi/amd.py` (production 2.2 + stock-Asterisk no-audio/hangup vocabulary), its unit tests, how to rebuild `amdy.tar.gz`. |
| [CHANGELOG.md](CHANGELOG.md) | Release notes. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branching, pull requests, regenerating the installer, running tests. |

## License

GNU General Public License version 2 (GPL-2.0), the same license as Asterisk.
See [LICENSE](LICENSE).
