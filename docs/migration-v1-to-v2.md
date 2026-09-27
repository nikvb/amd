# Migrating from app_amd_ws 1.x to 2.0

2.0.0 is a rewrite of the module, the build system and the installer. The
dialplan application keeps its name and its first four arguments, so an
existing `AMD_WS(host,port,vid,timeout_ms)` line keeps working. Everything
around it changed. Read the tables, then follow the upgrade procedure at the
end.

## Summary of what changed and why

| Area | 1.x | 2.0 | Why |
|---|---|---|---|
| WebSocket client | Embedded libwebsockets, statically linked, one lws context per call | Asterisk's own `res_http_websocket` (present since Asterisk 13) | `lws_service()` ignored its timeout in lws >= 3.2, so the audio loop stalled and timeouts were fictional; per-call contexts raced on lws' global log refcount and could `assert()`-abort Asterisk; per-call fd tables cost up to 16 MB and ~15 ms each. `res_http_websocket` has a real connect timeout and an fd that plugs into `ast_waitfor_nandfds`. Details: [architecture.md](architecture.md#v1-versus-v2). |
| Build dependency | libwebsockets dev package or a source build of lws 4.3.3 by the installer | None beyond gcc/make/pkg-config and the Asterisk headers | No more compiling lws on every dialer; no static-link recipe that could drop libraries. |
| Wait loops | Counted `lws_service()` iterations as milliseconds | Every wait bounded by a deadline (`ast_tvdiff_ms`) | Real timeouts; hangup noticed within one iteration. |
| Result matching | `strstr()` for `HUMAN`, `MACHINE`, `AMD`; replies >= 256 bytes or fragmented ignored | `amd.py`'s rule, in its order (`HUMAN` first, then `AMD`/`MACHINE`), with one guard: `AMDY` does not count as `AMD`; fragments reassembled, any size | Same verdicts as the production EAGI client on every reply; the brand string in an ack (`AMDY ack`) no longer hangs up humans; large and fragmented results are not lost. |
| Status / cause vocabulary | `NOTSURE` + module-specific causes, raw server text on results | `amd.py` (July 2026) vocabulary, with `HANGUP` and `NOAUDIODATA-<ms>` taken from stock `AMD()` | The 8370 fallback line and `VD_amd.agi`'s container / `ADAIR` options work unchanged; see [Channel variables](#channel-variables). |
| MySQL lookup | Compiled in unconditionally; `connect + query` on every call, before answering, connect timeout only; `astguiclient.conf` parsed per call | Optional at compile (`HAVE_MYSQL`) and run time (`db=`, option `n`); one persistent connection; connect/read/write timeouts = `db_timeout_ms`; config parsed at load/reload; fails soft | A slow DB no longer delays or freezes the start of detection. |

## Dialplan: arguments and options

| | 1.x | 2.0 |
|---|---|---|
| Syntax | `AMD_WS(host,port,vid,timeout_ms)` | `AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])` — every argument optional |
| `host` default | `127.0.0.1` (built-in) | `host=` from `amd_ws.conf`, built-in `127.0.0.1` (the shipped sample sets `api.amdy.io`) |
| `port` default | `8080` | `port=` from `amd_ws.conf`, built-in `2700` |
| `vid` default | caller id name (validity flag not checked) | caller id name if valid and non-empty, else `Unknown` |
| `timeout_ms` default | `5000` | `10000` (matches `amd.py`'s `MAX_WAIT_TIME`) |
| `playfile` | not available | new: sound file(s) played while detecting, `Playback()` semantics |
| `options` | not available | new: `n`, `s`, `d(ms)`, `c(ms)`, `p(phone)`, `k(code)`, `i(cid)`, `a`, `A` |
| Answering | always answered | answered by default (`a`); `A` refuses to answer |
| Return value | 0 | 0 |

## Channel variables

| Variable | 1.x | 2.0 |
|---|---|---|
| `AMDSTATUS` | `HUMAN`, `MACHINE`, `NOTSURE` (`HANGUP` was documented but never set) | `HUMAN`, `MACHINE`, `NOTSURE`, `HANGUP` — the four values of stock `AMD()` and `amd.py` |
| `AMDCAUSE` on result | raw server text | `HUMAN` on a human result; the raw server text on a machine result (as `amd.py`) |
| `AMDCAUSE` on error | `ANSWER_FAILED`, `FORMAT_FAILED`, `CONTEXT_FAILED`, `CONNECT_FAILED`, `CONNECTION_TIMEOUT`, `TIMEOUT` | `CONNECTION_ERROR`, `PROCESSING_ERROR`, `FATAL_ERROR`, `SERVER_TIMEOUT`, `NOAUDIODATA-<ms>`, `HANGUP`, `EOF_INCONCLUSIVE`, `EOF_ERROR` |
| `AMDSTATS` | — | new: `<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>` on every exit (`VD_amd.agi` logs the first field as `run_time`, as with stock `AMD()`) |
| `AMDRESPONSE` | — | new: raw last server text, printable ASCII, max 255 chars (not the `AMDRESPONSE` column `VD_amd.agi` writes, which it derives from `AMDCAUSE`) |
| `AMDELAPSED` | — | new: ms from first audio frame to exit |

Mapping of every status/cause, three ways. The middle column is what the
production EAGI client `amd.py` (July 2026, `gw.724care.com/amdy.tar.gz`)
sets today; 2.0 is identical to it except for the two rows marked with a
star, which follow stock `AMD()` instead (reasons in the next section).
"was" values in the first two columns are historical and appear nowhere else.

| Situation | 1.x module (was) | `amd.py` July 2026 (was, where 2.0 differs) | 2.0 module |
|---|---|---|---|
| Server replied `HUMAN` | `HUMAN` / `<raw text>` | `HUMAN` / `HUMAN` | `HUMAN` / `HUMAN` |
| Server replied with `MACHINE` or `AMD` in the text | `MACHINE` / `<raw text>` | `MACHINE` / `<raw text>` | `MACHINE` / `<raw text>` |
| Ack containing the brand string `AMDY` | `MACHINE` / `<raw text>` (`strstr` hit on `AMD`) | `MACHINE` / `<raw text>` (same substring hit) | ack, detection continues (the one deliberate guard) |
| Server replied `NOT_HUMAN` | `HUMAN` / `<raw text>` | `HUMAN` / `HUMAN` | `HUMAN` / `HUMAN` (same substring rule as `amd.py`) |
| Server replied another word (`FAS`, `NOTSURE`, ...) | ignored; `NOTSURE` / `TIMEOUT` at the end | ack, detection continues | ack, detection continues |
| Cannot connect (DNS, TCP, TLS, upgrade, connect timeout), `res_http_websocket` missing | `NOTSURE` / `CONNECT_FAILED` or `CONNECTION_TIMEOUT` (the loop often never exited) | `HUMAN` / `CONNECTION_ERROR` | `HUMAN` / `CONNECTION_ERROR` |
| Server closed or errored after the connect, before a result | `NOTSURE` / `TIMEOUT` | `HUMAN` / `PROCESSING_ERROR` | `HUMAN` / `PROCESSING_ERROR` |
| Internal failure (answer, format, allocation, thread, option `A` on an unanswered channel, bad config) | `NOTSURE` / `ANSWER_FAILED`, `FORMAT_FAILED`, `CONTEXT_FAILED` | `HUMAN` / `FATAL_ERROR` | `HUMAN` / `FATAL_ERROR` |
| Window elapsed, audio was sent, no result | `NOTSURE` / `TIMEOUT` | `NOTSURE` / `SERVER_TIMEOUT` (`AUDIO_TIMEOUT` before July 2026) | `NOTSURE` / `SERVER_TIMEOUT` |
| Window elapsed, no audio ever captured * | `NOTSURE` / `TIMEOUT` | `NOTSURE` / `NO_AUDIO_TIMEOUT` | `NOTSURE` / `NOAUDIODATA-<ms>` (stock `AMD()`) |
| Callee hung up / audio stream ended before a result * | `NOTSURE` / `TIMEOUT` (after flushing audio and waiting the grace on the dead channel) | `NOAUDIO` / `NOAUDIO` | `HANGUP` / `HANGUP` (stock `AMD()`) |
| EOF finalisation reply neither `HUMAN` nor `MACHINE` | — (no finalisation) | `NOTSURE` / `EOF_INCONCLUSIVE` | `NOTSURE` / `EOF_INCONCLUSIVE` |
| EOF finalisation error or 3 s timeout | — | `NOTSURE` / `EOF_ERROR` | `NOTSURE` / `EOF_ERROR` |
| `AMDSTATS` | — | the reply text, on `HUMAN` only | `<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>`, always |

If you installed a 2.0 build from the feature branch before this alignment,
its vocabulary was different; nothing of it exists in the released module, so
a dialplan or container entry written against it must be changed:

| Earlier 2.0 branch build (was) | 2.0 released |
|---|---|
| `NOTSURE` / `NETERR` | `HUMAN` / `CONNECTION_ERROR` (connect) or `PROCESSING_ERROR` (after the connect) |
| `NOTSURE` / `INTERR` | `HUMAN` / `FATAL_ERROR` |
| `NOTSURE` / `AUDIO_TIMEOUT` | `NOTSURE` / `SERVER_TIMEOUT` |
| `NOTSURE` / `NO_AUDIO_TIMEOUT` | `NOTSURE` / `NOAUDIODATA-<ms>` |
| `HONEYPOT` / `HONEYPOT` etc. (server word passed through via `extra_statuses`) | ack; detection continues; no such configuration key exists |
| `GotoIf(... "NETERR" \| ... "INTERR" ...)` | the three-cause `GotoIf` line below |

### Why two values follow stock `AMD()` instead of `amd.py`

- **`HANGUP`/`HANGUP` instead of `NOAUDIO`/`NOAUDIO`.** `amd.py` sees a hangup
  as "FD 3 returned 0 bytes" and calls it `NOAUDIO`. Stock `AMD()`
  (`app_amd.c`) sets `AMDSTATUS=HANGUP` for the same event, and `VD_amd.agi`
  tests `AMDSTATUS =~ /PERSON|HUMAN|NOTSURE|HANGUP/`: `HANGUP` is a status
  ViciDial knows and exits on; `NOAUDIO` is not. A dialplan module runs
  inside Asterisk and sees the hangup directly, so it reports it the way the
  built-in application does. (Stock `AMD()` leaves `AMDCAUSE` empty on
  hangup; `AMD_WS()` sets it to `HANGUP` too so the cause is never blank.)
- **`NOAUDIODATA-<ms>` instead of `amd.py`'s no-audio value.** Stock `AMD()`
  sets `AMDCAUSE=NOAUDIODATA-<ms>` when it received no audio in the window.
  `VD_amd.agi` strips `-<ms>` and, when the campaign's `AMD_AGENT_OPT`
  container has a `NOAUDIODATA-Hangup-ENABLED` line (ViciDial issue #1459,
  "dispo NOAUDIODATA as ADAIR"), sets the lead to `ADAIR` (dead air) and
  hangs up. Using the stock shape makes that existing ViciDial option work
  with `AMD_WS()` exactly as it does with `AMD()`; `amd.py`'s own value never
  matched it. Note that this means a container with that line will now
  produce `ADAIR` dispositions for dead-air calls that `amd.py` sent down the
  `NOTSURE` path.
- **`AMDSTATS` as `<elapsed_ms>-...`.** `VD_amd.agi` takes everything before
  the first `-` of `AMDSTATS` as `run_time` for `vicidial_amd_log`; with
  stock `AMD()` that is the total analysis time in ms. `amd.py` put the
  server's reply text there (on `HUMAN` only), so `run_time` was a word, or
  `0`. The four-integer form gives ViciDial a real run time and keeps the
  audio/chunk/byte counts available for support.

Everything else — `HUMAN` on the three error causes, the raw reply text as
the machine cause, `SERVER_TIMEOUT`, the EOF causes, substring matching — is
`amd.py` as it runs in production, so that switching a dialer from
`EAGI(amd.py)` to `AMD_WS()` changes nothing in `vicidial_amd_log` or in the
`VD_amd.agi` routing except the three points above.

**Effect on the ViciDial 8370 block.** The canonical block falls back to stock
`AMD()` with
`GotoIf($["${AMDCAUSE}" = "CONNECTION_ERROR" | "${AMDCAUSE}" = "PROCESSING_ERROR" | "${AMDCAUSE}" = "FATAL_ERROR"]?amd_fallback:continue)`
— the same line that works with `amd.py`. 1.x never produced those values,
so the fallback never fired during an outage; with 2.0 it does. If you wrote
your own dialplan tests against the 1.x strings (`CONNECTION_TIMEOUT`,
`CONNECT_FAILED`, ...) replace them with the three error causes. If you
inspected raw server text in `AMDCAUSE`, it is still there on machine results;
`AMDRESPONSE` has the last reply on every exit. If your `AMD_AGENT_OPT`
container lists anything other than `HUMAN,HUMAN`, check it against the
[routing table in the README](../README.md#how-vd_amdagi-routes-each-outcome).

## Wire behaviour

| | 1.x | 2.0 |
|---|---|---|
| Config frame | `sample_rate`, `VID`, `phone`, `country_code` | plus `caller_id` (`${CALLERID(num)}`, when set and not `Unknown`) — the July 2026 `amd.py` frame; `i(cid)` / `send_caller_id=no` control it |
| Send schedule | fixed 500 ms chunks (the documented 500/1000/1500/2000/3000/4000 ms schedule was not implemented) | `send_schedule=500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000`, then every `chunk_bytes` (8000) or `fallback_interval_ms` (1000) — identical to `amd.py` July 2026 |
| Audio integrity | frames that did not fit the chunk were truncated (30/60 ms packetisation lost 10-40 ms per chunk); frames arriving while a chunk was unsent were dropped | every byte is accumulated and sent |
| Waiting for the server | blocking | never blocks; channel serviced with a <= 20 ms budget per iteration; a result is honoured whenever it arrives |
| Early finalisation | none | after `eof_no_audio_streak` (2) schedule marks with no captured audio, `{"eof":1}` is sent and one reply awaited for `eof_wait_ms` (3 s) — `amd.py` July 2026 |
| End of stream | none | TEXT `{"eof":1}` |
| Close | TCP drop (server saw `1006`) | WebSocket CLOSE `1000` |
| Connect timeout | `2000` ms (fictional: counted iterations) | `connect_timeout_ms` (10000, `amd.py`'s `CONNECTION_TIMEOUT`), real time, tunable with `c(ms)` |
| Detection window start | after connect + config were done (`timeout_ms` counted from there) | the first captured audio frame (application start if no frame ever arrives); the connect runs inside the window |
| Grace after timeout | 20 iterations of `lws_service()` (0 ms to minutes, depending on lws) | `result_grace_ms`, default 0 (`amd.py` has none); still detecting hangup when set |
| Non-UTF-8 caller id name | sent raw (invalid TEXT frame) | invalid bytes replaced by `?` |
| TLS | not available (compiled out) | `wss://` via option `s` / `tls=yes`, `tls_verify`, `tls_cafile`, `tls_check_hostname` |

## Configuration file (new)

1.x had no configuration file; every default was compiled in.
2.0 reads the optional `/etc/asterisk/amd_ws.conf` (`[general]`) with the
keys `host`, `port`, `tls`, `tls_verify`, `tls_cafile`, `tls_check_hostname`, `timeout_ms`,
`connect_timeout_ms`, `result_grace_ms`, `send_schedule`, `chunk_bytes`,
`fallback_interval_ms`, `eof_no_audio_streak`, `eof_wait_ms`, `send_caller_id`,
`playdelay_ms`, `db`, `db_timeout_ms`, `astguiclient_conf`,
`max_pending_connects`. All keys are optional; see `amd_ws.conf.sample` and the
[configuration reference](../README.md#configuration-reference).
`module reload app_amd_ws.so` re-reads it (and `astguiclient.conf`).
`make install` and the installer put a commented copy at
`/etc/asterisk/amd_ws.conf.sample` (new file; an existing `amd_ws.conf` is
never touched).

## Module behaviour

| | 1.x | 2.0 |
|---|---|---|
| Load failure | returned `AST_MODULE_LOAD_FAILURE` (Asterisk refuses to start if e.g. a duplicate `.so` registers `AMD_WS` first) | `AST_MODULE_LOAD_DECLINE` |
| Unload safety | hand-rolled session counter + runtime mutex | core use count only; `module unload` refused while in use |
| Dependencies | none declared | `.requires = "res_http_websocket"` |
| Support level | `core` | `extended` |
| CLI | none | `amd_ws show settings` (effective config, DB availability, per-outcome counters) |
| Logging | assorted verbose lines, phone numbers at verbose 3, `ast_log(LOG_DEBUG)` | exactly two verbose-3 lines per call; rate-limited warnings (connect: 1 per 10 s per host; DB: 1 per minute); `ast_debug()` for detail; no phone numbers at normal verbosity; never credentials |
| `core show application AMD_WS` | "Not available" | full synopsis/description |
| `astguiclient.conf` parsing | per call; tabs, trailing spaces and inline comments broke it | at load/reload; tolerant to tabs, trailing spaces, `#`/`;` comments, `=>` inside values |

## Build system and installer

| | 1.x | 2.0 |
|---|---|---|
| `make` variables | `ASTTOPDIR`, `ASTINCDIR`, `STATIC=1` | `ASTINCDIR`, `ASTTOPDIR`, `ASTMODDIR`, `ASTNOCHECK`, `MYSQL=auto\|1\|0`, `MYSQL_CFLAGS`/`MYSQL_LIBS`, `BUNDLES`. `STATIC` is gone. |
| Header selection | `/usr/include` first, else the alphabetically first `/usr/src/asterisk-*` (matched sound tarballs) | detects the **running** Asterisk (binary, version, build-option sum) and validates each candidate; see [build-and-headers.md](build-and-headers.md) |
| Post-link checks | none (an unloadable `.so` could be installed) | `make check`: `ldd -r` symbol gate + embedded build-option sum |
| `make reload` | trusted the exit code of `asterisk -rx` (always 0) | parses the reply |
| Targets | `all install clean reload load unload` | plus `check show-config uninstall installer test` |
| `install.sh` | hand-maintained script with embedded copies of the sources; built lws 4.3.3 from source; could add openSUSE repositories; could hang up live calls to unload | generated by `tools/gen-installer.sh` (CI fails when stale); never adds repos, never upgrades Asterisk, never hangs up calls; backs up the old module; exit code 3 when the swap must wait |
| Installer header fallback | `./configure` inside a downloaded tarball (never produced `buildopts.h`) | pinned distro devel package (only when Asterisk is the distro package) → header bundle → tarball headers + synthesised `buildopts.h`; `./configure` only with `--allow-configure` |
| Installer flags | `--deps-only --build-only --uninstall` | `-y --dry-run --deps-only --build-only --output --no-db --no-load --headers --asterisk-src --version --allow-configure --bundle-url --tarball-file --wait --keep-build --uninstall --remove-backups --help` |
| MySQL dev package | hard requirement, undocumented | optional (`--no-db`, `MYSQL=0`) |
| Log | none | `/var/log/app_amd_ws-install.log` |

## Upgrade procedure

1. Check what you run today:

   ```bash
   asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'dialplan show 8370@default' | grep -i amd
   ```

2. If your 8370 block already has the three-cause fallback line
   (`CONNECTION_ERROR` / `PROCESSING_ERROR` / `FATAL_ERROR`, the one used with
   `amd.py`), no dialplan change is needed. If it branches on 1.x cause
   strings, change them as described above. Optionally add the playback
   argument. Check the campaign's `AMD_AGENT_OPT` container: `HUMAN,HUMAN`
   is fine; a `NOAUDIODATA-Hangup-ENABLED` line now takes effect (see above).
3. Run the **2.0** installer. Until 2.0.0 is merged to `main` and tagged,
   the `main` URL still serves the 1.x installer (which builds lws, may add
   repositories and hangs up calls to unload), so take it from the branch (or
   the `v2.0.0` tag once it exists), or run `sudo ./install.sh -y` from a
   checkout of the branch:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/nikvb/amd/v2.0.0/install.sh | sudo bash -s -- -y
   ```

   It backs up the 1.x module to `app_amd_ws.so.bak.<timestamp>`, builds
   2.0 against your running Asterisk (no lws build, no repository changes),
   and swaps the module without hanging up calls. Exit code 3 means the swap is
   pending until the dialer is idle; see [installer.md](installer.md#exit-codes).
4. Optionally create `/etc/asterisk/amd_ws.conf` from `amd_ws.conf.sample`
   and `asterisk -rx 'module reload app_amd_ws.so'`.
5. Verify with one call: two `AMD_WS:` lines in the log, and
   `asterisk -rx 'amd_ws show settings'` counting it.
6. libwebsockets is no longer needed by this module. If 1.x's installer built
   it under `/usr/local` (`/usr/local/lib/libwebsockets.a`,
   `/usr/local/include/libwebsockets*`, `/etc/ld.so.conf.d/libwebsockets.conf`,
   `/usr/src/libwebsockets-4.3.3`), you may remove those files once nothing
   else uses them; 2.0's uninstall does not touch them. Likewise any openSUSE
   repositories the 1.x installer added (`zypper lr`) can be removed.

## Rolling back to 1.x

Not recommended: 1.x's timeouts and concurrency behaviour are the reason for
the rewrite, and the backup `.so` only loads if the lws build it was linked
against is still present. If you must, copy the `app_amd_ws.so.bak.<timestamp>`
back over `app_amd_ws.so` and unload/load the module ([installer.md](installer.md#rollback)),
and remember that 1.x never emits the three error causes the fallback line
tests for, nor `HANGUP`, `NOAUDIODATA-<ms>` or `AMDSTATS`.

See also: [CHANGELOG.md](../CHANGELOG.md), [README](../README.md).
