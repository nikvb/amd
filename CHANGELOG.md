# Changelog

All notable changes to `app_amd_ws` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [2.0.0] - unreleased

Complete rewrite of the module, build system and installer. Operators
upgrading from 1.x: read [docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md).

### Added

- `playfile` argument (5th): play one or more sound files into the channel
  while audio is being captured (`Playback()` semantics; `&`-separated list),
  starting after `playdelay_ms`; stopped as soon as a result arrives, on
  hangup and on exit. End of file does not end detection.
- `options` argument (6th): `n` (no DB lookup), `s` (TLS `wss://`), `d(ms)`
  (playback delay), `c(ms)` (connect timeout), `p(phone)` and `k(code)`
  (explicit phone / country code), `a` (answer, default) and `A` (do not
  answer; `INTERR` if the channel is not up).
- Channel variable `AMDRESPONSE`: raw last server text (printable ASCII, max
  255 chars).
- Channel variable `AMDELAPSED`: milliseconds from the first captured audio
  frame to exit.
- `AMDSTATUS=HANGUP` / `AMDCAUSE=HANGUP` when the callee hangs up before a
  result (1.x documented but never set it).
- Server classifications other than `HUMAN`/`MACHINE` are passed through
  verbatim as `AMDSTATUS` and `AMDCAUSE` (`HONEYPOT`, `FAS`, `FASAMD`,
  `AUDIO`, `NOTSURE`; configurable with `extra_statuses`).
- JSON results (`{"status":...}`, `{"result":...}`, `{"classification":...}`)
  are recognised.
- Configuration file `/etc/asterisk/amd_ws.conf` with `host`, `port`, `tls`,
  `tls_verify`, `tls_cafile`, `timeout_ms`, `connect_timeout_ms`,
  `result_grace_ms`, `send_schedule`, `chunk_bytes`, `extra_statuses`,
  `playdelay_ms`, `db`, `db_timeout_ms`, `astguiclient_conf`; all optional;
  shipped as `amd_ws.conf.sample`.
- `module reload app_amd_ws.so` re-reads `amd_ws.conf` and
  `/etc/astguiclient.conf`.
- CLI command `amd_ws show settings`: effective configuration, DB
  availability, counters (calls, human, machine, other, neterr, interr,
  timeouts, hangups).
- `core show application AMD_WS` shows a full synopsis and description.
- Two verbose-3 log lines per call (`AMD_WS: <chan> vid=... host=... play=...`
  and `AMD_WS: <chan> status=... cause=... elapsed=... sent=... chunks=...`).
- TLS (`wss://`) through Asterisk's own TLS support.
- Send `{"eof":1}` and a WebSocket CLOSE with code 1000 on every exit path.
- Result grace period (`result_grace_ms`) after `timeout_ms`: the remaining
  audio is sent and a reply awaited while still detecting hangup.
- `Makefile`: detection of the running Asterisk (binary, version, build-option
  sum) and validation of every header candidate via `ast-detect.sh`; targets
  `check` (post-link symbol gate + embedded build-option sum), `show-config`,
  `uninstall`, `installer`, `test`; header dependency tracking and a
  `.buildflags` stamp; `MYSQL=auto|1|0` with `pkg-config`/`mariadb_config`/
  `mysql_config` discovery; `install` backs up the previous `.so` to
  `.so.bak.<timestamp>`; `load`/`unload`/`reload` parse the CLI reply.
- `install.sh` is now generated (`tools/gen-installer.sh`, `make installer`)
  and self-contained; new flags `-y`, `--dry-run`, `--no-db`, `--no-load`,
  `--headers`, `--asterisk-src`, `--version`, `--allow-configure`,
  `--bundle-url`, `--wait`, `--help`; header resolution via local trees →
  pinned distro devel package → header bundle → tarball headers with a
  synthesised `buildopts.h`; backup and verified load; exit code 3 when the
  module swap must wait for idle; log in `/var/log/app_amd_ws-install.log`.
- `tools/make-header-bundle.sh` (build `asterisk-<ver>-headers.tar.gz` +
  `.sha256`), `tools/check-embedded.sh` (CI guard against a stale
  `install.sh`), GitHub Actions workflow.
- Test harness under `test/`: mock AMD server, minimal Asterisk configuration,
  `test/run.sh` with the scenario matrix in [docs/testing.md](docs/testing.md).
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
- `AMDCAUSE` vocabulary is now `INTERR`, `NETERR`, `AUDIO_TIMEOUT`,
  `NO_AUDIO_TIMEOUT`, `HANGUP`, or the classification token; it no longer
  carries raw server text (see `AMDRESPONSE`). This makes the ViciDial 8370
  fallback `GotoIf($["${AMDCAUSE}" = "NETERR" | "${AMDCAUSE}" = "INTERR"]?amd_fallback)`
  work.
- Result classification matches whole tokens (split on non `[A-Za-z0-9_]`,
  uppercased) instead of substrings: `AMDY` no longer yields `MACHINE`,
  `NOT_HUMAN` no longer yields `HUMAN`; results larger than 255 bytes and
  fragmented results are handled.
- Audio send schedule implemented as documented: `500,1000,1500,2000,3000,4000`
  ms from the first captured frame, then every `chunk_bytes` (8000), matching
  `amd.py`; every captured byte is sent (carry-over accumulator, no
  truncation for 30/60 ms frames).
- Every wait is bounded by a real deadline; the channel is serviced during
  connect-wait and result-wait; connect uses the API's millisecond timeout
  (`connect_timeout_ms`, default 2000). Hangup is detected immediately and
  ends the call without a grace wait.
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

[2.0.0]: https://github.com/nikvb/amd/compare/main...feat/v2-res-http-websocket
[1.0.0]: https://github.com/nikvb/amd/tree/main
