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
| Result matching | `strstr()` for `HUMAN`, `MACHINE`, `AMD` | Whole-token match; JSON `status`/`result`/`classification` key honoured; configurable `extra_statuses` | `AMDY` no longer means `MACHINE`; `NOT_HUMAN` no longer means `HUMAN`; large and fragmented results are not lost. |
| MySQL lookup | Compiled in unconditionally; `connect + query` on every call, before answering, connect timeout only; `astguiclient.conf` parsed per call | Optional at compile (`HAVE_MYSQL`) and run time (`db=`, option `n`); one persistent connection; connect/read/write timeouts = `db_timeout_ms`; config parsed at load/reload; fails soft | A slow DB no longer delays or freezes the start of detection. |

## Dialplan: arguments and options

| | 1.x | 2.0 |
|---|---|---|
| Syntax | `AMD_WS(host,port,vid,timeout_ms)` | `AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])` — every argument optional |
| `host` default | none (required) | `host=` from `amd_ws.conf`, built-in `127.0.0.1` |
| `port` default | `8080` | `port=` from `amd_ws.conf`, built-in `2700` |
| `vid` default | caller id name (validity flag not checked) | caller id name if valid and non-empty, else `Unknown` |
| `timeout_ms` default | `5000` | `10000` (matches `amd.py`'s 10 s) |
| `playfile` | not available | new: sound file(s) played while detecting, `Playback()` semantics |
| `options` | not available | new: `n`, `s`, `d(ms)`, `c(ms)`, `p(phone)`, `k(code)`, `a`, `A` |
| Answering | always answered | answered by default (`a`); `A` refuses to answer |
| Return value | 0 | 0 |

## Channel variables

| Variable | 1.x | 2.0 |
|---|---|---|
| `AMDSTATUS` | `HUMAN`, `MACHINE`, `NOTSURE` (`HANGUP` was documented but never set) | `HUMAN`, `MACHINE`, `NOTSURE`, `HANGUP`, or any other server classification uppercased (`HONEYPOT`, `FAS`, `FASAMD`, `AUDIO`, ...) |
| `AMDCAUSE` on result | raw server text | the classification token (`HUMAN`, `MACHINE`, `HONEYPOT`, ...) |
| `AMDCAUSE` on error | `ANSWER_FAILED`, `FORMAT_FAILED`, `CONTEXT_FAILED`, `CONNECT_FAILED`, `CONNECTION_TIMEOUT`, `TIMEOUT` | `INTERR`, `NETERR`, `AUDIO_TIMEOUT`, `NO_AUDIO_TIMEOUT`, `HANGUP` |
| `AMDRESPONSE` | — | new: raw last server text, printable ASCII, max 255 chars |
| `AMDELAPSED` | — | new: ms from first audio frame to exit |

Mapping of the old causes:

| 1.x `AMDCAUSE` | 2.0 `AMDCAUSE` |
|---|---|
| `CONNECT_FAILED`, `CONNECTION_TIMEOUT` | `NETERR` |
| `ANSWER_FAILED`, `FORMAT_FAILED`, `CONTEXT_FAILED` | `INTERR` |
| `TIMEOUT` (some audio sent) | `AUDIO_TIMEOUT` |
| `TIMEOUT` (no audio captured) | `NO_AUDIO_TIMEOUT` |
| `NOTSURE`/`TIMEOUT` after a hangup | `HANGUP` (status and cause) |
| raw server text | the token; raw text in `AMDRESPONSE` |

**Effect on the ViciDial 8370 block.** The canonical block falls back to stock
`AMD()` with `GotoIf($["${AMDCAUSE}" = "NETERR" | "${AMDCAUSE}" = "INTERR"]?amd_fallback:continue)`.
1.x never produced those two values, so the fallback never fired during an
outage; with 2.0 it does. If you wrote your own dialplan tests against the 1.x
strings (`CONNECTION_TIMEOUT`, `CONNECT_FAILED`, ...) replace them with
`NETERR`/`INTERR`. If you inspected raw server text in `AMDCAUSE`, use
`AMDRESPONSE`.

## Wire behaviour

| | 1.x | 2.0 |
|---|---|---|
| Send schedule | fixed 500 ms chunks (the documented 500/1000/1500/2000/3000/4000 ms schedule was not implemented) | `send_schedule=500,1000,1500,2000,3000,4000`, then every `chunk_bytes` (8000) — identical to `amd.py` |
| Audio integrity | frames that did not fit the chunk were truncated (30/60 ms packetisation lost 10-40 ms per chunk); frames arriving while a chunk was unsent were dropped | every byte is accumulated and sent |
| Waiting for the server | blocking | never blocks; channel serviced with a <= 20 ms budget per iteration |
| End of stream | none | TEXT `{"eof":1}` |
| Close | TCP drop (server saw `1006`) | WebSocket CLOSE `1000` |
| Grace after timeout | 20 iterations of `lws_service()` (0 ms to minutes, depending on lws) | `result_grace_ms` (1000 ms), still detecting hangup |
| Non-UTF-8 caller id name | sent raw (invalid TEXT frame) | invalid bytes replaced by `?` |
| TLS | not available (compiled out) | `wss://` via option `s` / `tls=yes`, `tls_verify`, `tls_cafile`, `tls_check_hostname` |

## Configuration file (new)

1.x had no configuration file; every default was compiled in.
2.0 reads the optional `/etc/asterisk/amd_ws.conf` (`[general]`) with the
keys `host`, `port`, `tls`, `tls_verify`, `tls_cafile`, `tls_check_hostname`, `timeout_ms`,
`connect_timeout_ms`, `result_grace_ms`, `send_schedule`, `chunk_bytes`,
`extra_statuses`, `playdelay_ms`, `db`, `db_timeout_ms`, `astguiclient_conf`.
All keys are optional; see `amd_ws.conf.sample` and the
[configuration reference](../README.md#configuration-reference).
`module reload app_amd_ws.so` re-reads it (and `astguiclient.conf`).

## Module behaviour

| | 1.x | 2.0 |
|---|---|---|
| Load failure | returned `AST_MODULE_LOAD_FAILURE` (Asterisk refuses to start if e.g. a duplicate `.so` registers `AMD_WS` first) | `AST_MODULE_LOAD_DECLINE` |
| Unload safety | hand-rolled session counter + runtime mutex | core use count only; `module unload` refused while in use |
| Dependencies | none declared | `.requires = "res_http_websocket"` |
| Support level | `core` | `extended` |
| CLI | none | `amd_ws show settings` (effective config, DB availability, counters) |
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
| Installer flags | `--deps-only --build-only --uninstall` | `-y --dry-run --deps-only --build-only --no-db --no-load --headers --asterisk-src --version --allow-configure --bundle-url --wait --uninstall --help` |
| MySQL dev package | hard requirement, undocumented | optional (`--no-db`, `MYSQL=0`) |
| Log | none | `/var/log/app_amd_ws-install.log` |

## Upgrade procedure

1. Check what you run today:

   ```bash
   asterisk -rx 'module show like app_amd_ws'; asterisk -rx 'dialplan show 8370@default' | grep -i amd
   ```

2. If your 8370 block already has the `NETERR`/`INTERR` fallback line, no
   dialplan change is needed. If it branches on 1.x cause strings, change them
   as described above. Optionally add the playback argument.
3. Run the installer:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/nikvb/amd/main/install.sh | sudo bash -s -- -y
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
and remember that 1.x never emits `NETERR`/`INTERR`.

See also: [CHANGELOG.md](../CHANGELOG.md), [README](../README.md).
