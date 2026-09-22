# app_amd_ws — `AMD_WS()` for Asterisk / ViciDial

`AMD_WS()` is an Asterisk dialplan application that performs Answering Machine
Detection by streaming the first seconds of an answered call to the amdy.io AMD
service over WebSocket and setting `${AMDSTATUS}` / `${AMDCAUSE}` for the
dialplan, exactly where ViciDial's extension 8370 expects them.

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

As root on the ViciDial telephony server:

```bash
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/main/install.sh | sudo bash -s -- -y
```

The installer detects the running Asterisk, obtains matching headers, installs
the build dependencies (never touching Asterisk itself or your package
repositories), builds the module, backs up any previous `app_amd_ws.so`, loads
the new module without hanging up calls, and prints the dialplan snippet.
Everything it prints is also written to `/var/log/app_amd_ws-install.log`.

Common variants:

```bash
# see what would happen, change nothing
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/main/install.sh | sudo bash -s -- --dry-run

# no MySQL dependency, no DB lookup
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/main/install.sh | sudo bash -s -- -y --no-db

# remove the module again
curl -fsSL https://raw.githubusercontent.com/nikvb/amd/main/install.sh | sudo bash -s -- --uninstall
```

All flags, exit codes and the header-resolution order are in
[docs/installer.md](docs/installer.md).

## Manual build

```bash
git clone https://github.com/nikvb/amd.git && cd amd
make show-config     # what Asterisk, version, headers and MySQL client were detected
make                 # builds app_amd_ws.so against the detected headers
make check           # post-link gates: no unresolved symbols, correct build-option sum
sudo make install    # backs up the old .so, installs into the module directory
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

Targets: `all`, `check`, `install`, `uninstall`, `clean`, `show-config`,
`installer` (regenerates `install.sh`), `test` (runs `test/run.sh`), `load`,
`unload`, `reload`. Details: [docs/build-and-headers.md](docs/build-and-headers.md).

## Dialplan usage

```text
AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])
```

| Parameter | Default | Meaning |
|---|---|---|
| `host` | `host=` from `amd_ws.conf` (built-in default `127.0.0.1`; the shipped sample sets `api.amdy.io`) | AMD server hostname or IP. |
| `port` | `port=` from `amd_ws.conf` (default `2700`) | TCP port. An invalid value logs a warning and uses the default. |
| `vid` | `${CALLERID(name)}` if valid and non-empty, else `Unknown` | Call tracking id sent to the server as `VID`. ViciDial puts its call id in the caller id name. |
| `timeout_ms` | `timeout_ms=` from `amd_ws.conf` (default `10000`) | Overall detection window. Values `<= 0` use the default. |
| `playfile` | none | Sound file(s) to play into the channel while audio is captured. `Playback()` semantics: relative to the sounds directory, no extension, `&`-separated list plays in order, language taken from the channel. See [Parallel playback](#parallel-playback). |
| `options` | none | Flags, Asterisk application option style, see below. |

### Options

| Option | Meaning |
|---|---|
| `n` | No DB lookup for this call (phone/country are not sent unless given with `p()`/`k()`). |
| `s` | TLS: connect with `wss://` (needs Asterisk built with TLS; certificate verification per `tls_verify`). |
| `d(ms)` | Start playback `ms` milliseconds after detection starts (overrides `playdelay_ms`). |
| `c(ms)` | Connect timeout in milliseconds (overrides `connect_timeout_ms`, default 2000). |
| `p(phone)` | Send this phone number as `phone` (skips the DB lookup for the phone). |
| `k(code)` | Send this country/phone code as `country_code`. |
| `a` | Answer the channel if it is not up. This is the default. |
| `A` | Do **not** answer. If the channel is not up the application exits with `NOTSURE` / `INTERR`. |

The application always returns 0 to the dialplan; use the channel variables to
branch. `core show application AMD_WS` prints the same reference.

## Channel variables

Set on every exit path:

| Variable | Values |
|---|---|
| `AMDSTATUS` | `HUMAN`, `MACHINE`, `NOTSURE`, `HANGUP`, or any other classification the server returned, uppercased (`HONEYPOT`, `FAS`, `FASAMD`, `AUDIO`). |
| `AMDCAUSE` | The classification token on a result (`HUMAN`, `MACHINE`, `HONEYPOT`, ...), otherwise one of `INTERR`, `NETERR`, `AUDIO_TIMEOUT`, `NO_AUDIO_TIMEOUT`, `HANGUP`. |
| `AMDRESPONSE` | Raw last text the server sent, sanitised to printable ASCII, at most 255 characters. New in 2.0.0. |
| `AMDELAPSED` | Milliseconds from the first captured audio frame to exit. New in 2.0.0. |

Status/cause matrix:

| Situation | `AMDSTATUS` | `AMDCAUSE` |
|---|---|---|
| Server returned `HUMAN` | `HUMAN` | `HUMAN` |
| Server returned `MACHINE` or `AMD` | `MACHINE` | `MACHINE` |
| Server returned another configured status (`extra_statuses`) | that token | that token |
| `res_http_websocket` not loaded, or internal failure (format, allocation, bad state, not answered with option `A`) | `NOTSURE` | `INTERR` |
| DNS / connect / handshake failure, connect timeout, WebSocket error or close before a result | `NOTSURE` | `NETERR` |
| `timeout_ms` elapsed, audio was sent, no result | `NOTSURE` | `AUDIO_TIMEOUT` |
| `timeout_ms` elapsed and no audio was ever captured | `NOTSURE` | `NO_AUDIO_TIMEOUT` |
| Channel hung up before a result | `HANGUP` | `HANGUP` |

`NETERR` and `INTERR` are the two values the ViciDial dialplan uses to fall
back to the stock `AMD()` application (next section).

## ViciDial integration

### Extension 8370

This is the canonical ViciDial AI-AMD block with the `EAGI(amd.py)` line
replaced by `AMD_WS()`. Everything else (call logging, the `NETERR`/`INTERR`
fallback to stock `AMD()`, `VD_amd.agi`) stays as it is.

```text
exten => 8370,1,AGI(agi://127.0.0.1:4577/call_log)
exten => 8370,n,Playback(sip-silence)
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000)
exten => 8370,n,GotoIf($["${AMDCAUSE}" = "NETERR" | "${AMDCAUSE}" = "INTERR"]?amd_fallback:continue)
exten => 8370,n(amd_fallback),AMD(2000,2000,1000,5000,120,50,4,256)
exten => 8370,n(continue),AGI(VD_amd.agi,${EXTEN})
exten => 8370,n,AGI(agi-VDAD_ALL_outbound.agi,NORMAL-----LB-----${CONNECTEDLINE(name)})
```

Parallel-playback variant (plays `/var/lib/asterisk/sounds/amdy/insert.wav`
into the call 2 s after detection starts, while audio keeps streaming to the
AMD service):

```text
exten => 8370,n,AMD_WS(api.amdy.io,2700,${CALLERID(name)},10000,amdy/insert,d(2000))
```

Do not add a separate `Playback(amdy/insert)` line: it would play before
detection starts. Let `AMD_WS()` play it.

After editing the dialplan: `asterisk -rx 'dialplan reload'`. In ViciDial set
the campaign's **Routing Extension** to `8370`, **AMD Agent Route Options** to
`ENABLED`, and the `AMD_AGENT_OPT_<campaign>` container entry to exactly
`HUMAN,HUMAN`, then rebuild the telephony server config. With that container
entry `VD_amd.agi` sends only `HUMAN` calls to agents; every other status
(`MACHINE`, `NOTSURE`, `HANGUP`, `HONEYPOT`, ...) takes the answering-machine
path. (Without a container entry, `VD_amd.agi`'s built-in rule sends `HUMAN`,
`NOTSURE` and `HANGUP` to agents.) No dialplan branching on `AMDSTATUS` is
needed beyond the fallback line.

### Where the VID comes from

ViciDial sets the caller id name of the outbound leg to its call identifier
(the `callerid` column of `vicidial_auto_calls`). `AMD_WS()` uses
`${CALLERID(name)}` as the `VID` by default, so the third argument can also be
left empty: `AMD_WS(api.amdy.io,2700,,10000)`. If the caller id name is empty
or invalid, `Unknown` is sent.

### Phone / country enrichment

When built with the MySQL client and `db=yes` (the default), the module looks up
`phone_code` and `phone_number` for the VID in `vicidial_auto_calls`
(`SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid='<vid>'
ORDER BY auto_call_id DESC LIMIT 1`) using the `VARDB_*` credentials in
`/etc/astguiclient.conf`, and sends them as `phone` and `country_code` in the
config frame. The file is parsed once at module load and on
`module reload app_amd_ws.so`. The query uses one persistent connection, is
bounded by `db_timeout_ms` (default 1000 ms), and fails soft: on any DB problem
the call proceeds without `phone`, and a warning is logged at most once per
minute. Credentials are never logged.

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
timeout_ms=10000
connect_timeout_ms=2000
result_grace_ms=1000
send_schedule=500,1000,1500,2000,3000,4000
chunk_bytes=8000
extra_statuses=HONEYPOT,FAS,FASAMD,AUDIO,NOTSURE
playdelay_ms=0
db=yes
db_timeout_ms=1000
astguiclient_conf=/etc/astguiclient.conf
```

| Key | Built-in default | Meaning |
|---|---|---|
| `host` | `127.0.0.1` | Default AMD server when the dialplan gives none. The sample sets `api.amdy.io`. |
| `port` | `2700` | Default TCP port. |
| `tls` | `no` | `yes` connects with `wss://` for every call (same as option `s`). |
| `tls_verify` | `yes` | Verify the server certificate when TLS is used. |
| `tls_cafile` | empty | CA file used to verify the server certificate when TLS is on; see `amd_ws.conf.sample`. |
| `timeout_ms` | `10000` | Default detection window. |
| `connect_timeout_ms` | `2000` | WebSocket connect (DNS + TCP + handshake) timeout. |
| `result_grace_ms` | `1000` | After `timeout_ms` with no result, the remaining audio is sent and the module waits this long for a reply (still detecting hangup). |
| `send_schedule` | `500,1000,1500,2000,3000,4000` | Milliseconds from the first captured frame at which everything accumulated so far is sent. A single value such as `500` means plain fixed-interval chunks. |
| `chunk_bytes` | `8000` | After the last schedule mark, send whenever this many bytes have accumulated (8000 B = 500 ms of 8 kHz 16-bit audio). |
| `extra_statuses` | `HONEYPOT,FAS,FASAMD,AUDIO,NOTSURE` | Server statuses other than `HUMAN`/`MACHINE`/`AMD` that end detection and are passed through verbatim. |
| `playdelay_ms` | `0` | Delay before `playfile` starts. |
| `db` | `yes` | Enable the ViciDial phone/country lookup (only when compiled with MySQL support). |
| `db_timeout_ms` | `1000` | Connect/read/write timeout for the lookup (rounded up to whole seconds, minimum 1). |
| `astguiclient_conf` | `/etc/astguiclient.conf` | Where to read `VARDB_*` credentials. |

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
`tls_verify` and `tls_cafile` control certificate verification. Use TLS only
against an endpoint that offers it; the production endpoint documented for the
amdy.io service is plain `ws://api.amdy.io:2700`. If Asterisk was built
without TLS, a `wss://` connection cannot be made; the call ends `NOTSURE`
with a log line saying why, and the dialplan fallback applies.

## CLI and logging

| Command | Shows |
|---|---|
| `asterisk -rx 'module show like app_amd_ws'` | Module loaded, use count (calls currently inside `AMD_WS`). |
| `asterisk -rx 'core show application AMD_WS'` | Syntax, parameters, options, variables. |
| `asterisk -rx 'amd_ws show settings'` | Effective configuration, DB availability, counters (calls, human, machine, other, neterr, interr, timeouts, hangups). |
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

| `AMDCAUSE` | Meaning | Check | Fix |
|---|---|---|---|
| `NETERR` | Could not connect, connect timed out, or the server closed/errored before a result | `timeout 5 bash -c 'exec 3<>/dev/tcp/api.amdy.io/2700' && echo open`; `grep 'AMD_WS' /var/log/asterisk/full \| grep -c NETERR`; `dig +short api.amdy.io` | Open outbound TCP 2700 (all AMD service addresses) on the firewall; fix DNS; raise `c(ms)`/`connect_timeout_ms` if the RTT is very high. The dialplan fallback to `AMD()` keeps calls classified meanwhile. |
| `INTERR` | Module-internal: `res_http_websocket` not loaded, read format could not be set, allocation failed, or channel not up with option `A` | `module show like res_http_websocket`; `module show like app_amd_ws`; look for `AMD_WS` warnings in the log | `module load res_http_websocket.so`; if the channel is not answered before `AMD_WS`, drop option `A` or answer first. |
| `AUDIO_TIMEOUT` | Audio was sent for `timeout_ms` but the server never returned a result | `${AMDRESPONSE}` (last server text); `amd_ws show settings` counters; server-side logs for the VID | Usually server-side or a status token not in `extra_statuses`. Add the token or raise `timeout_ms`. |
| `NO_AUDIO_TIMEOUT` | No audio frame was ever read from the channel within `timeout_ms` | Is the channel answered and is RTP flowing? `rtp set debug on`; check `Playback(sip-silence)` succeeded | Fix the media path (NAT, carrier, codec). Not an AMD-service problem. |
| `HANGUP` | Callee hung up before a result | none | Normal. |
| `HUMAN`/`MACHINE`/other token but wrong | Classification quality | `${AMDRESPONSE}`, recording of the call, `AMDELAPSED` | Review with the AMD service; check that the audio reaching the server is 8 kHz clean speech (no early `Playback` in the dialplan). |
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
| ViciBox (openSUSE RPM from OBS `home:vicidial`) | `18.26.4-vici` | `asterisk-devel` RPM pinned to the exact installed version | The OBS `asterisk-18` project publishes `asterisk-devel`; the `asterisk-13`/`asterisk-16` projects publish nothing any more, so those boxes use a header bundle or the vendor tarball. Never install an unpinned `asterisk-devel`: it pulls a different Asterisk. |
| Debian / Ubuntu distro package | `16.28` (bullseye), `18.10` (jammy), `20.6` (noble) | `asterisk-dev=<exact installed version>` | Only correct when the running Asterisk **is** the distro package. A scratch-installed `-vici` binary with a distro `asterisk-dev` present is a mismatch; detection rejects it by build-option sum / version. |
| RHEL family scratch install (CentOS 7, Alma/Rocky 8-9) | `18.21.0-vici` | Same as ViciDial scratch install | |
| Anything else (upstream source, custom prefix, GIT builds) | 16-22 | `ASTTOPDIR=`/`ASTINCDIR=` override, `<prefix>/include`, or a header bundle | For unknown versions pass `--version` / `--headers` to the installer. |

Details and the detection algorithm: [docs/build-and-headers.md](docs/build-and-headers.md).

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Call flow, threading model, why `res_http_websocket`, v1 failure modes. |
| [docs/protocol.md](docs/protocol.md) | Wire protocol with an example of every frame. |
| [docs/build-and-headers.md](docs/build-and-headers.md) | Why no Asterisk recompile is needed, what must match, header detection, bundles, distro matrix. |
| [docs/installer.md](docs/installer.md) | `install.sh` flags, exit codes, system changes, upgrade, rollback, uninstall. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause → check → fix playbook, log lines, CLI. |
| [docs/testing.md](docs/testing.md) | Test harness overview. |
| [docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md) | Behaviour changes from 1.x. |
| [CHANGELOG.md](CHANGELOG.md) | Release notes. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branching, pull requests, regenerating the installer, running tests. |

## License

GNU General Public License version 2 (GPL-2.0), the same license as Asterisk.
See [LICENSE](LICENSE).
