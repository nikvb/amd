# Changelog

All notable changes to `app_amd_ws` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

The 2.0.0 rewrite, until it is merged to `main` and tagged (`v2.0.0`; the
heading then gets its date). Complete rewrite of the module, build system and
installer. Operators upgrading from 1.x: read
[docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md).

### Vocabulary and protocol aligned with production `amd.py` (July 2026) and stock `app_amd` / `VD_amd.agi`

The status/cause vocabulary, the wire protocol and the timing defaults now
match the production EAGI client `amd.py` as shipped in July 2026
(`gw.724care.com/amdy.tar.gz`), and the two values ViciDial's own tooling
keys on are taken from stock `AMD()`. Earlier builds of this branch used a
vocabulary of their own; see the "was" table in
[docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md#channel-variables).

- **Trace option `v` / conf `trace=yes`** — one verbose-3 line per event
  (connect, first audio frame, each chunk sent, each server reply, result) with
  the millisecond offset from the start of `AMD_WS()`, to see where the time of
  a call goes (schedule granularity vs server decision time).
- **`extra_config`** conf key: a JSON object spliced into the config frame for
  `amd_server` options (`short_no_greeting`, `detection_mode`,
  `max_detection_time`, `stage_results`); `STAGE-` progress frames are treated
  as acks. Trace lines now include the DB lookup result, the full config sent
  and the variables set, like `amd.py`'s log.
- **`agi/amd.py`** — the production EAGI client (2.2, `gw.724care.com/amdy.tar.gz`,
  2026-07-14) is now in the repository as 2.2.1 with the same alignment for the
  two situations that differ from stock `app_amd`: FD3 EOF → `HANGUP`/`HANGUP`
  (was `NOAUDIO`/`NOAUDIO`, which `VD_amd.agi` routed down the machine path),
  no audio → `NOTSURE`/`NOAUDIODATA-<ms>` (was `NO_AUDIO_TIMEOUT`; enables the
  `NOAUDIODATA-Hangup-ENABLED` → ADAIR handling), `AMDSTATS` always
  `<elapsed_ms>-<bytes>` (was the word `HUMAN`), raw server text in
  `AMDRESPONSE`. Unit tests: `python3 agi/test_amd_py.py`. See
  [agi/README.md](agi/README.md).

- **Causes.** `HUMAN` / `CONNECTION_ERROR` (cannot connect, incl.
  `res_http_websocket` missing), `HUMAN` / `PROCESSING_ERROR` (WebSocket
  error after the connect), `HUMAN` / `FATAL_ERROR` (internal failure, option
  `A` on an unanswered channel), `NOTSURE` / `SERVER_TIMEOUT` (window elapsed
  with audio sent), `NOTSURE` / `EOF_INCONCLUSIVE` and `NOTSURE` /
  `EOF_ERROR` (EOF finalisation) — all as `amd.py`; `AMDSTATUS` is `HUMAN`
  on the three errors ("defaulting to HUMAN for safety"). `NOTSURE` /
  `NOAUDIODATA-<ms>` when no audio was ever captured and `HANGUP` /
  `HANGUP` on hangup or end of stream — as stock `AMD()`, so
  `VD_amd.agi`'s `NOAUDIODATA-Hangup-ENABLED` (`ADAIR`) option and its
  `HANGUP` handling apply. On a machine result `AMDCAUSE` is the server's
  reply text (sanitised), as with `amd.py`.
- **8370 fallback line** is the one used with `amd.py`:
  `GotoIf($["${AMDCAUSE}" = "CONNECTION_ERROR" | "${AMDCAUSE}" = "PROCESSING_ERROR" | "${AMDCAUSE}" = "FATAL_ERROR"]?amd_fallback:continue)`.
- **Classification** is `amd.py`'s rule in `amd.py`'s order (`HUMAN` in the
  text, else `AMD` or `MACHINE` in the text, else ack; substring,
  case-sensitive), with one guard: `AMDY` does not count as `AMD`. There is
  no configurable list of extra statuses; words such as `FAS` are
  acknowledgements, as with `amd.py`. `NOT_HUMAN` classifies `HUMAN`, as with
  `amd.py`.
- **`AMDSTATS`** is set on every exit as
  `<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>`; `VD_amd.agi`
  stores the first field as `run_time` (stock `AMD()` shape).
- **Config frame** gains `caller_id` (`${CALLERID(num)}`, sent when non-empty
  and not `Unknown`); new option `i(cid)` and key `send_caller_id=yes|no`.
  Keys in `amd.py`'s order: `sample_rate`, `VID`, `phone`, `country_code`,
  `caller_id`. The phone lookup query is unchanged
  (`SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid=... ORDER BY auto_call_id DESC LIMIT 1`).
- **Send schedule** default is `amd.py`'s eleven marks
  `500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000`; after the last
  mark a send happens at `chunk_bytes` (8000) **or** after
  `fallback_interval_ms` (new key, 1000) with a non-empty buffer.
- **EOF finalisation** (new): after `eof_no_audio_streak` (new key, 2; 0
  disables) consecutive schedule marks with no captured audio, once some
  audio was sent, the module sends `{"eof":1}` and waits `eof_wait_ms` (new
  key, 3000) for one reply, still detecting hangup.
- **Defaults**: `connect_timeout_ms` 2000 → 10000 (`amd.py`
  `CONNECTION_TIMEOUT`), `result_grace_ms` 1000 → 0 (`amd.py` has no grace;
  the key stays). `timeout_ms` stays 10000 (`MAX_WAIT_TIME`), measured from
  the first captured frame.
- **Removed**: the configurable extra-status key and the token parser of
  earlier 2.0 branch builds, together with their four error/timeout causes
  (mapped in the migration doc).
- **Parity audit against the July 2026 `amd.py`** (every behaviour of the
  script traced to the module, table in the pull request): `caller_id` is
  skipped on exactly `Unknown` (case-sensitive, as `amd.py`); an
  `astguiclient.conf` without `VARDB_` lines skips the lookup like `amd.py`'s
  "DB ERROR: no config" instead of trying the built-in defaults;
  `docs/protocol.md` now also states the two remaining wire-level details
  (JSON whitespace/escaping, sends over 16000 bytes split into frames) and
  what a server that never replies produces under each client.
- Docs: README (status matrix with sources, `VD_amd.agi` routing table,
  caller id, configuration reference), `docs/protocol.md` rewritten to the
  July 2026 protocol with the EOF finalisation exchange,
  `docs/troubleshooting.md` cause reference, `docs/migration-v1-to-v2.md`
  three-way mapping 1.x → `amd.py` → 2.0 with the reasons for the two stock
  `AMD()` values.

### Review round 2 (fixes to the unreleased 2.0.0 code)

- **Connect cap is per host and configurable** (`max_pending_connects=`,
  default 64, range 8..1024): a server that accepts TCP but never answers the
  handshake parks one helper thread per call in the core's handshake read
  (`res_http_websocket` gives it no timeout); the cap now applies per host
  and only to helpers whose call has already given up (a burst of healthy
  simultaneous connects was tripping the old global cap), so one dead host
  cannot fail production calls to another, and the "cap reached" WARNING has
  its own once-per-minute limit. `amd_ws show settings` prints `connects in
  flight` (all helpers) and `parked connects` per host. The sticky state and its
  recovery (peer closes, or Asterisk restart) are documented in
  [docs/troubleshooting.md, Known limitations](docs/troubleshooting.md#4-known-limitations);
  the harness reproduces it (`blackhole`, `blackhole_cap`, `blackhole_release`).
- **DB lookup moved to the connect helper thread**, right before the
  WebSocket connect: a stalled DB can cost that call its connect window
  (`CONNECTION_ERROR`) but never blocks the channel thread. The socket timeouts are
  whole seconds (`ceil(db_timeout_ms/1000)`), which the documentation now says
  instead of "bounded by `db_timeout_ms`". A connection the server dropped
  while idle (2006/2013) is reconnected once within the same budget instead
  of starting the 5 s backoff. An unreadable `astguiclient.conf` disables the
  lookup with one NOTICE at load/reload instead of connecting to
  `localhost` as `cron` every 5 s.
- Per-write socket bound raised from 100 ms to 500 ms (a multi-frame flush on
  a fresh connection over a >100 ms RTT could turn into a spurious
  `PROCESSING_ERROR`).
- After a readable socket the module drains frames already buffered
  (`ast_websocket_wait_for_input(ws, 0)`), so a TLS record carrying an ack
  and the result in one piece no longer leaves the result unread over
  `wss://`; a close initiated by the core itself (PONG write failure, bad
  opcode) is noticed through `ast_websocket_fd() < 0` instead of polling a
  stale descriptor.
- Out-of-file-descriptors probe before starting a connect: the core's client
  path would dereference NULL when `socket()` fails; the call now exits
  `FATAL_ERROR` with a rate-limited WARNING.
- IPv6 literal hosts are bracketed in the URI (`ws://[2001:db8::10]:2700/`).
- The connect deadline runs from the moment the connect starts (after the
  answer), not from application entry.
- Audio arriving during the result grace period is counted but no longer
  accumulated (nothing is sent in that phase; long `result_grace_ms` values
  logged a misleading "dropping audio" warning).
- The invalid-options warning masks digits (a `p(<phone>)` inside the option
  string never reaches the log through the module) and "ignored" now means
  all options are ignored, not the half parsed before the error.
- A connect that failed exactly at the deadline logs its real reason (DNS,
  4xx, TLS) instead of "timed out".
- Makefile: `make load`/`make reload` reported "not Running" after a
  successful load (nested `sh -c` quoting); `reload` is sequential under
  `-j`; the post-link gate strips the trailing comma of versioned undefined
  symbols and falls back to the name pattern when the core export list is
  empty.
- Installer: shellcheck-clean with 0.8.0 and 0.10.0 (CI was red);
  `AST_BUILDOPT_SUM`/version are re-read after installing binutils (bundle
  and tarball routes failed on a box without `strings`); `set -E` so the ERR
  trap reports the failing line and command; `rpm -V`/`dpkg --verify` no
  longer sit in a pipeline under `pipefail`; apt lists are refreshed when no
  `*_Packages` index exists; certified versions are named
  `asterisk-certified-<ver>` for bundles and cache dirs; `curl --retry 3
  --proto '=https,file' --proto-redir '=https'`; sha256 of the ViciDial
  tarballs (`16.30.1-vici`, `18.21.0-vici`) and upstream `16.30.1` pinned in
  the installer, `--allow-configure` refused for an unverifiable download;
  non-root runs use `mktemp` cache/log paths; the module version from
  `amd_ws show settings` is logged after load; `--uninstall` exit code 3
  documented.
- `tools/make-header-bundle.sh --configure` keeps the extracted tree only on
  failure (it leaked it on success and removed it on failure);
  `tools/gen-installer.sh` refuses a source without a final newline.
- Harness: `MYSQL_ROOT` has no baked-in path (use `test/local.env`);
  `db`-tagged rows SKIP without the MySQL build and `cli_show_settings`
  asserts the DB availability line; soak bursts use unique VIDs (they were
  reused, so per-burst results were stale); `log~` assertions anchored to the
  call's channel; `log_lines` counts one start + one end line per AMD_WS
  channel; `module_reload` verifies changed keys and runs a call on the new
  config; bursts check one mock connection per VID; `TEST_SLOW_FACTOR`;
  upper bounds with <=300 ms headroom widened by ~500 ms; new scenarios
  `opt_c_connto`, `hangup_in_connect`, `expire_in_connect`, `bad_options`,
  `vid_escape`, `blackhole`, `blackhole_fill`, `blackhole_cap`, `blackhole_release`,
  `reload_effect`; the mock imports the `websockets` legacy server API
  explicitly.
- Docs: install one-liners point at the branch until `v2.0.0` is tagged
  (`main` still serves the 1.x installer); header bundles are marked as not
  published yet; migration table corrections (1.x `host` default, detection
  window origin, new conf sample file, full flag list); loader message
  wording; synthesised
  `buildopts.h` shape; worst-case time formula.

### Added

- `playfile` argument (5th): play one or more sound files into the channel
  while audio is being captured (`Playback()` semantics; `&`-separated list),
  starting after `playdelay_ms`; stopped as soon as a result arrives, on
  hangup and on exit. End of file does not end detection.
- `options` argument (6th): `n` (no DB lookup), `s` (TLS `wss://`), `d(ms)`
  (playback delay), `c(ms)` (connect timeout), `p(phone)` and `k(code)`
  (explicit phone / country code), `i(cid)` (explicit caller id), `a`
  (answer, default) and `A` (do not answer; `FATAL_ERROR` if the channel is
  not up).
- Channel variable `AMDRESPONSE`: raw last server text (printable ASCII, max
  255 chars).
- Channel variable `AMDELAPSED`: milliseconds from the first captured audio
  frame to exit.
- `AMDSTATUS=HANGUP` / `AMDCAUSE=HANGUP` when the callee hangs up before a
  result (1.x documented but never set it; stock `AMD()` vocabulary).
- Channel variable `AMDSTATS` (`<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>`)
  on every exit.
- `caller_id` in the config frame (`${CALLERID(num)}`), as `amd.py` July 2026.
- EOF finalisation after consecutive schedule marks without audio
  (`eof_no_audio_streak`, `eof_wait_ms`), as `amd.py` July 2026.
- Configuration file `/etc/asterisk/amd_ws.conf` with `host`, `port`, `tls`,
  `tls_verify`, `tls_cafile`, `tls_check_hostname`, `timeout_ms`, `connect_timeout_ms`,
  `result_grace_ms`, `send_schedule`, `chunk_bytes`, `fallback_interval_ms`,
  `eof_no_audio_streak`, `eof_wait_ms`, `send_caller_id`,
  `playdelay_ms`, `db`, `db_timeout_ms`, `astguiclient_conf`,
  `max_pending_connects`; all optional; shipped as `amd_ws.conf.sample`
  (installed to `/etc/asterisk/amd_ws.conf.sample` by `make install` and the
  installer).
- `module reload app_amd_ws.so` re-reads `amd_ws.conf` and
  `/etc/astguiclient.conf`.
- CLI command `amd_ws show settings`: effective configuration, DB
  availability, per-outcome counters, the number of connects in flight and
  of parked connects per host.
- The blocking WebSocket connect (and the optional DB lookup) runs on a
  helper thread per call so the channel is serviced during the whole
  `connect_timeout_ms`, including a server that accepts TCP but never answers
  the handshake; at most `max_pending_connects` (64) such connects per host
  are in flight, further calls to that host fail fast with `CONNECTION_ERROR`.
- `core show application AMD_WS` shows a full synopsis and description.
- Two verbose-3 log lines per call (`AMD_WS: <chan> vid=... host=... play=...`
  and `AMD_WS: <chan> status=... cause=... elapsed=... sent=... chunks=...`).
- TLS (`wss://`) through Asterisk's own TLS support.
- Send `{"eof":1}` and a WebSocket CLOSE with code 1000 on every exit path.
- Result grace period (`result_grace_ms`, default 0 like `amd.py`) after
  `timeout_ms`: the remaining audio is sent and a reply awaited while still
  detecting hangup.
- `Makefile`: detection of the running Asterisk (binary, version, build-option
  sum) and validation of every header candidate via `ast-detect.sh`; every
  build runs four gates (headers only from the chosen tree, embedded
  build-option sum, `ldd -r` against the core's exported symbols); targets
  `check` (compile matrix against header bundles), `show-config`,
  `uninstall`, `installer`, `test`; header dependency tracking and a
  `.buildflags` stamp; `MYSQL=auto|1|0` with `pkg-config`/`mariadb_config`/
  `mysql_config` discovery; `install` backs up the previous `.so` to
  `.so.bak.<timestamp>`; `load`/`unload`/`reload` parse the CLI reply.
- `install.sh` is now generated (`tools/gen-installer.sh`, `make installer`)
  and self-contained; new flags `-y`, `--dry-run`, `--no-db`, `--no-load`,
  `--headers`, `--asterisk-src`, `--version`, `--allow-configure`,
  `--bundle-url`, `--tarball-file`, `--output`, `--keep-build`,
  `--remove-backups`, `--wait`, `--help`; exit codes 0-6 documented in
  [docs/installer.md](docs/installer.md); header resolution via local trees →
  pinned distro devel package → header bundle → tarball headers with a
  synthesised `buildopts.h`; backup and verified load; exit code 3 when the
  module swap must wait for idle; log in `/var/log/app_amd_ws-install.log`.
- `tools/make-header-bundle.sh` (build `asterisk-<ver>-headers.tar.gz` +
  `.sha256`), `tools/check-embedded.sh` (CI guard against a stale
  `install.sh`), GitHub Actions workflow.
- Test harness under `test/`: mock AMD server, minimal Asterisk configuration,
  data-driven `test/scenarios.txt`, `test/run.sh` with the scenario matrix in
  [docs/testing.md](docs/testing.md), including a 300-call fd/RSS soak and a
  log-noise check (no unexpected `WARNING`/`ERROR` lines).
- Documentation set under `docs/`, `CONTRIBUTING.md`, this changelog, and the
  GPL-2.0 `LICENSE` file.

### Changed

- **WebSocket client: `res_http_websocket` (Asterisk's own) replaces
  libwebsockets.** No lws build or package is needed; the module declares
  `.requires = "res_http_websocket"`.
- All arguments are optional: `AMD_WS([host[,port[,vid[,timeout_ms[,playfile[,options]]]]]])`.
- Default `port` 8080 → 2700; default `timeout_ms` 5000 → 10000; default
  `host` comes from `amd_ws.conf` (built-in 127.0.0.1; sample sets
  `api.amdy.io`).
- `vid` defaults to the caller id name only if it is valid and non-empty,
  else `Unknown`.
- `AMDSTATUS` / `AMDCAUSE` vocabulary is `amd.py`'s (`HUMAN` +
  `CONNECTION_ERROR` / `PROCESSING_ERROR` / `FATAL_ERROR`, `NOTSURE` +
  `SERVER_TIMEOUT` / `EOF_INCONCLUSIVE` / `EOF_ERROR`, `HUMAN`/`HUMAN`,
  `MACHINE`/reply text) plus stock `AMD()`'s `HANGUP`/`HANGUP` and
  `NOTSURE`/`NOAUDIODATA-<ms>`, instead of 1.x's own strings. This makes the
  ViciDial 8370 fallback on the three error causes work.
- Result classification follows `amd.py` exactly (substring, `HUMAN` before
  `AMD`/`MACHINE`, case-sensitive) with the single `AMDY` guard, so an ack
  carrying the brand name no longer yields `MACHINE`; results larger than
  255 bytes and fragmented results are handled.
- Audio send schedule implemented as `amd.py` does it:
  `500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000` ms from the first
  captured frame, then every `chunk_bytes` (8000) or `fallback_interval_ms`
  (1000); every captured byte is sent (carry-over accumulator, no truncation
  for 30/60 ms frames).
- Every wait is bounded by a real deadline; the channel is serviced during
  connect-wait and result-wait; connect uses the API's millisecond timeout
  (`connect_timeout_ms`, default 10000 = `amd.py`). Hangup is detected
  immediately and ends the call without a grace wait.
- MySQL lookup: optional at compile time (`HAVE_MYSQL`) and at run time
  (`db=no`, option `n`, `p()`/`k()`); one persistent connection under a
  module mutex; connect/read/write timeouts = `db_timeout_ms` (default 1000
  ms); `mysql_library_init()` once at load; fails soft with warnings
  rate-limited to one per minute; `astguiclient.conf` parsed at load/reload
  and tolerant to tabs, trailing spaces, inline `#`/`;` comments and `=>`
  inside values.
- `load_module` returns `AST_MODULE_LOAD_DECLINE` (never `FAILURE`) on
  failure; unload relies on the core's use count; module mutexes use
  `AST_MUTEX_DEFINE_STATIC`; support level `extended`.
- JSON escaping: valid UTF-8 passes through, invalid bytes become `?`, so the
  config frame is always a valid TEXT frame.
- Logging: `ast_debug()` for detail, rate-limited warnings for repeated
  connect failures (one per 10 s per host), no phone numbers at normal
  verbosity, never credentials.
- Installer: never adds package repositories, never upgrades Asterisk, never
  hangs up channels to unload the module; supports openSUSE/SLES (ViciBox
  9-13), RHEL family (CentOS 7, Alma/Rocky 8-9), Debian/Ubuntu; installs only
  `gcc make pkg-config binutils tar curl` plus the MariaDB/MySQL client dev
  package unless `--no-db`.
- `README.txt` replaced by `README.md`; `CLAUDE.md` rewritten.

### Removed

- libwebsockets dependency, the static link (`STATIC=1`) and the lws source
  build in the installer.
- 1.x `AMDCAUSE` values `ANSWER_FAILED`, `FORMAT_FAILED`, `CONTEXT_FAILED`,
  `CONNECT_FAILED`, `CONNECTION_TIMEOUT`, `TIMEOUT`.
- Hand-rolled active-session counter and runtime-initialised mutex.
- Installer behaviour that hung up channels containing `AMD_WS` before an
  upgrade, and the `./configure`-on-the-dialer fallback (now opt-in via
  `--allow-configure`).

### Fixed

- Connect and result waits that counted iterations instead of time (false
  connect timeouts after ~100 ms, or minutes of dead air on an unreachable
  server).
- Whole-Asterisk crash from concurrent lws contexts sharing a global refcount
  in an assert-enabled lws build.
- Module built by the published installer had undefined `mysql_*` symbols and
  could not be loaded.
- Audio loss with 30 ms and 60 ms packetisation; frames dropped while a chunk
  was pending.
- Hangup during detection reported as `NOTSURE`/`TIMEOUT` and followed by a
  grace wait on the dead channel.
- No WebSocket close handshake (servers logged abnormal `1006` closures).
- `Host` header omitted the non-default port (`res_http_websocket` sends
  `host:port`).
- Non-UTF-8 caller id names produced invalid TEXT frames.
- Header selection could pick a sound tarball or an alphabetically-first
  source tree; `/usr/include` was trusted without a build-option check;
  an empty `ASTMODDIR` installed to `/`.
- `install.sh` `--help` and other early exits returned status 1; installer
  success was reported even when the module failed to load.

## [1.0.0] - 2026-04-02

Initial module: `AMD_WS(host,port,vid,timeout_ms)` on libwebsockets, fixed
500 ms audio chunks, `strstr()` result matching, `AMDSTATUS`/`AMDCAUSE`,
MySQL lookup of `phone_number`/`phone_code` from `vicidial_auto_calls` using
`/etc/astguiclient.conf`, hand-maintained `install.sh` with embedded sources
(security and robustness fixes merged 2026-04-01; `/usr/src/asterisk/asterisk-*`
header search and `./configure` fallback added 2026-04-02).

[Unreleased]: https://github.com/nikvb/amd/compare/main...feat/v2-res-http-websocket
[1.0.0]: https://github.com/nikvb/amd/tree/main
