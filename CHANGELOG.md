# Changelog

All notable changes to `app_amd_ws` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

The 2.0.0 rewrite, until it is merged to `main` and tagged (`v2.0.0`; the
heading then gets its date). Complete rewrite of the module, build system and
installer. Operators upgrading from 1.x: read
[docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md).

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
  (`NETERR`) but never blocks the channel thread. The socket timeouts are
  whole seconds (`ceil(db_timeout_ms/1000)`), which the documentation now says
  instead of "bounded by `db_timeout_ms`". A connection the server dropped
  while idle (2006/2013) is reconnected once within the same budget instead
  of starting the 5 s backoff. An unreadable `astguiclient.conf` disables the
  lookup with one NOTICE at load/reload instead of connecting to
  `localhost` as `cron` every 5 s.
- Per-write socket bound raised from 100 ms to 500 ms (a multi-frame flush on
  a fresh connection over a >100 ms RTT could turn into a spurious `NETERR`).
- After a readable socket the module drains frames already buffered
  (`ast_websocket_wait_for_input(ws, 0)`), so a TLS record carrying an ack
  and the result in one piece no longer leaves the result unread over
  `wss://`; a close initiated by the core itself (PONG write failure, bad
  opcode) is noticed through `ast_websocket_fd() < 0` instead of polling a
  stale descriptor.
- Out-of-file-descriptors probe before starting a connect: the core's client
  path would dereference NULL when `socket()` fails; the call now exits
  `INTERR` with a rate-limited WARNING.
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
  window origin, `NOTSURE`→token for non-HUMAN/MACHINE results, new conf
  sample file, full flag list); loader message wording; synthesised
  `buildopts.h` shape; worst-case time formula.

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
  `tls_verify`, `tls_cafile`, `tls_check_hostname`, `timeout_ms`, `connect_timeout_ms`,
  `result_grace_ms`, `send_schedule`, `chunk_bytes`, `extra_statuses`,
  `playdelay_ms`, `db`, `db_timeout_ms`, `astguiclient_conf`,
  `max_pending_connects`; all optional; shipped as `amd_ws.conf.sample`
  (installed to `/etc/asterisk/amd_ws.conf.sample` by `make install` and the
  installer).
- `module reload app_amd_ws.so` re-reads `amd_ws.conf` and
  `/etc/astguiclient.conf`.
- CLI command `amd_ws show settings`: effective configuration, DB
  availability, counters (calls, human, machine, other, neterr, interr,
  timeouts, hangups), the number of connects in flight and of parked
  connects per host.
- The blocking WebSocket connect (and the optional DB lookup) runs on a
  helper thread per call so the channel is serviced during the whole
  `connect_timeout_ms`, including a server that accepts TCP but never answers
  the handshake; at most `max_pending_connects` (64) such connects per host
  are in flight, further calls to that host fail fast with `NETERR`.
- `core show application AMD_WS` shows a full synopsis and description.
- Two verbose-3 log lines per call (`AMD_WS: <chan> vid=... host=... play=...`
  and `AMD_WS: <chan> status=... cause=... elapsed=... sent=... chunks=...`).
- TLS (`wss://`) through Asterisk's own TLS support.
- Send `{"eof":1}` and a WebSocket CLOSE with code 1000 on every exit path.
- Result grace period (`result_grace_ms`) after `timeout_ms`: the remaining
  audio is sent and a reply awaited while still detecting hangup.
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

[Unreleased]: https://github.com/nikvb/amd/compare/main...feat/v2-res-http-websocket
[1.0.0]: https://github.com/nikvb/amd/tree/main
