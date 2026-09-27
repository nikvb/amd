# Testing

The repository ships an end-to-end harness under `test/` that drives the
**real** Asterisk binary with the freshly built module against a mock AMD
server, without root and without touching the system Asterisk configuration.
The authoritative, step-by-step description of the harness and of every
scenario is [`test/README.md`](../test/README.md); this page is the overview.

## What is in `test/`

| Path | Role |
|---|---|
| `test/run.sh` | The harness: builds the module twice (`make MYSQL=0`, then `make MYSQL=1 ...`; the DB build is the one under test), starts the mock server and a private Asterisk instance, originates one `Local/<NNNN>@farside-<scenario>` → `<NNNN>@amdside-<scenario>` call per scenario row, waits for the result line, asserts, prints a PASS/FAIL table and exits `0` (all pass), `1` (a failure) or `2` (harness problem). |
| `test/scenarios.txt` | Data-driven scenario table: one `\|`-separated line per call (far-side behaviour, mock behaviour, `AMD_WS()` arguments, expected `AMDSTATUS`/`AMDCAUSE`, wall-clock bounds, assertions). Adding a test is adding a line. |
| `test/mock_amd_server.py` | Python 3 `asyncio` WebSocket server (`websockets` legacy API, imported from `websockets.legacy.server`, so 10-12 and the 13+/14+ releases that still ship the legacy module work) speaking the `amd.py` protocol; `--tls-cert/--tls-key` make it serve `wss://` (`run.sh` starts a second, TLS instance). Behaviour is selected by URL path or, because the module always connects to `/`, by a control file that `run.sh` rewrites before every call. Records, per connection, the config JSON, every chunk's size and arrival time, total bytes, replies, `{"eof":1}` and the close code as JSON lines. |
| `test/protocol_test.py` | Assertions over those recordings: config JSON shape and key order (with/without `phone`/`country_code`/`caller_id`), chunk schedule (anchored on the first captured frame, ± 150 ms), bytes per chunk and total (16 000 B/s ± 10 %), `eof`, close code. |
| `test/classify_test.py` | Classification parity in pure Python: a table of server strings run through `amd.py`'s own rule (copied verbatim) and a re-implementation of the module's rule; they must agree on every string except the documented `AMDY` guard. |
| `test/mock_client.py` | An `amd.py`-like client used to test the mock itself (`mock_paths` check). |
| `test/blackhole_server.py` | Accept-and-never-reply TCP listener: models a server that completes TCP and ACKs the upgrade but never answers (`blackhole*` scenarios). |
| `test/asterisk/` | Configuration templates for the private Asterisk: `asterisk.conf` (all directories under `test/run/`), `modules.conf` (`autoload=no` + explicit loads), `logger.conf` (full log, verbose 3, debug 1), `extensions.conf.in` (far-side behaviours and the result writer), `amd_ws.conf.in`, `astguiclient.conf.in` (deliberately messy syntax, dead DB port). The module directory is a directory of symlinks to the system modules plus the freshly built `app_amd_ws.so`. |
| `test/run/` | Scratch (gitignored): the Asterisk tree, recordings, `results.txt`, `logs/run-<timestamp>/` with the full Asterisk log, mock log and records, per-scenario logs, build logs and CLI captures. |

The result of every call is written from the `h` extension (so it exists on
every exit path) as
`VID|AMDSTATUS|AMDCAUSE|AMDELAPSED|T0|T1|TA|base64("x"+AMDRESPONSE)|CHANNEL`
plus `AMDSTATS` (see `test/README.md` for the exact line);
`T0`/`T1` are epoch ms around the application, `TA` when the far side started
sending audio. Sound files (8 kHz mono 16-bit: an 8 s speech-like sweep, a
1.5 s speech burst, a prompt, a beep, digital silence) are generated with
`sox` at run time.

## Running it

```bash
test/run.sh --selftest        # harness plumbing only, no module needed (about 25 s)
make test                     # same as: test/run.sh  (full suite, about 2.5 min)
test/run.sh --only human,playback,soak_fd_rss     # a subset (scenarios and checks)
test/run.sh --keep            # leave Asterisk and the mock running for a look
test/run.sh --list            # every scenario and check
```

Requirements on the box: an Asterisk 16+ binary with `res_http_websocket.so`
and the modules listed in `test/asterisk/modules.conf`, its XML documentation
directory, `python3` with `websockets` 10-12 (legacy asyncio API; 13+ works as
long as `websockets.legacy.server` is importable), `sox`, `gcc`, `make`, and
either system MariaDB/MySQL client dev files or a staged copy
(`MYSQL_ROOT=/dir` with `include/mariadb` and `lib/x86_64-linux-gnu`, put it in
the gitignored `test/local.env`; without either the DB build and the `db`-tagged
scenarios are SKIPped with a hint). No root,
no listening ports other than the mock server's on loopback, no AMI/HTTP/SIP
binds (the `no_listeners` check verifies it). On the reference box the binary
needs `LD_LIBRARY_PATH=/usr/lib64`; `run.sh` takes care of it. Environment
knobs (`ASTERISK_BIN`, `AST_MODULES_DIR`, `MYSQL_ROOT`, `MAKE_ARGS`,
`SUITE_BUDGET_S`, `TEST_SLOW_FACTOR` — multiplies every upper timing bound on
a slow box, ...) are listed in `test/README.md`.

Mock server behaviours (URL path or control file):

| Path | Server behaviour |
|---|---|
| `/human?after=N` | Ack `N` chunks (`{}`), then send `HUMAN` as the reply to chunk `N+1`. |
| `/machine`, `/amd`, `/status?value=X` | Other replies: `MACHINE` and `AMD` (and `AMD_DETECTED`) must classify as `MACHINE` with the reply text as `AMDCAUSE`; lowercase `amd` and words such as `FAS` are acks and detection continues. |
| `/json` | Result as JSON `{"status": "HUMAN", ...}` (contains `HUMAN`, so it classifies). |
| `/amdy` | Acks are `AMDY ack` (must **not** classify: the `AMDY` guard), result later. |
| `/nothuman` | Replies `NOT_HUMAN`, which classifies as `HUMAN` — the same substring verdict `amd.py` gives; the scenario documents it. |
| `/eof_human`, `/eof_ack`, `/eof_silent` | Ack every chunk; on the client's `{"eof":1}` reply `HUMAN`, reply `ack`, or stay silent (EOF finalisation scenarios). |
| `/silent` | Never replies. |
| `/slow?handshake=MS` | Delays the HTTP upgrade by `MS` ms. |
| `/reject` | Answers the upgrade with HTTP 403. |
| `/close?after=N` | Closes the connection (1011) after `N` chunks, no result. |
| `/big` | Result padded to 5 KB, the word `HUMAN` at the end. |
| `/fragmented` | Result sent as several WebSocket fragments. |
| `/ping?after=N` | Sends a PING before each reply. |
| `/delay?reply=MS` | Replies delayed by `MS` ms (reading must not stall the audio loop). |

## Scenarios and what each proves

Names are the rows of `test/scenarios.txt` and the checks of `run.sh`
(`test/run.sh --list`). Wall-clock bounds include the ~500 ms that
`Answer()` on the far side waits for media before its audio starts, and leave
about 500 ms of headroom above what the reference box measures; multiply them
with `TEST_SLOW_FACTOR=2` on a slow CI runner. `log~` assertions are anchored
to the call's own channel (`Local/<NNNN>@farside-<scenario>-...;1`).

| Scenario | Expected `AMDSTATUS` / `AMDCAUSE` | Proves |
|---|---|---|
| `human` | `HUMAN` / `HUMAN` < 3 s | Happy path; config JSON shape and key order; chunks at 500/1000/1500/2000 ms after the first frame (± 150, measured ± 2 ms); 16 kB/s; `eof`; close 1000; both `AMD_WS:` verbose lines; `AMDSTATS` matches `^[0-9]+-[0-9]+-[0-9]+-[0-9]+$` and its first field is within ± 150 ms of `AMDELAPSED` (asserted on every scenario). |
| `machine`, `amd_token` | `MACHINE` / `MACHINE`, `MACHINE` / `AMD` | `amd.py`'s rule: a reply containing `AMD` or `MACHINE` is a machine and the reply text is the cause. Further rows exercise `AMD_DETECTED` (→ `MACHINE` / `AMD_DETECTED`) and lowercase `amd` (an ack: case-sensitive, like `amd.py`). |
| `json` | `HUMAN` | `{"status":"HUMAN"}` contains `HUMAN`; `AMDRESPONSE` carries the raw text. |
| `amdy_ack` | `HUMAN` after 4 chunks | `AMDY ack` is not read as `AMD` (the only deviation from `amd.py`'s rule). |
| `nothuman` | `HUMAN` / `HUMAN` | `NOT_HUMAN` contains `HUMAN` and classifies as `HUMAN`, exactly as with `amd.py`; documented, not "fixed". |
| `server_down` | `HUMAN` / `CONNECTION_ERROR` in ~20 ms | Connect refused handled fast; no mock connection; `AMDSTATUS=HUMAN` as `amd.py`. |
| `slow_handshake` | `HUMAN` / `CONNECTION_ERROR` at `connect_timeout_ms` | A stalled handshake is bounded by the connect timeout (the channel keeps being serviced meanwhile). |
| `opt_c_connto` | `HUMAN` / `CONNECTION_ERROR` at ~300 ms | `c(300)` overrides `connect_timeout_ms` per call. |
| `hangup_in_connect` | `HANGUP` / `HANGUP` at ~1.5 s | Callee hangs up while the handshake is still pending: no grace, `sent=0 chunks=0`, the late socket is discarded by the helper. |
| `expire_in_connect` | `HUMAN` / `CONNECTION_ERROR` at `timeout_ms` | The detection window (`1500` from the first frame) ends before a slow handshake completes: a connection error, not a timeout cause. |
| `reject_upgrade` | `HUMAN` / `CONNECTION_ERROR` | HTTP 403 on the upgrade. |
| `silent_server` | `NOTSURE` / `SERVER_TIMEOUT` at `timeout_ms` (+ `result_grace_ms`, default 0) | Timeout is real time; audio kept flowing (>= 4 chunks); `eof` and close 1000 still sent. |
| `close_midstream` | `HUMAN` / `PROCESSING_ERROR` | Server CLOSE before a result. |
| `big_result`, `fragmented`, `ping_frames`, `slow_reply` | `HUMAN` | 5 KB frame; fragment reassembly; PING handling; delayed acks do not stall the audio schedule. |
| `hangup` | `HANGUP` / `HANGUP` at ~1.5 s | Callee hangup mid-detection, no grace wait; `AMDELAPSED` counts from the first audio frame. |
| `no_audio` | `NOTSURE` / `NOAUDIODATA-<ms>` (regex `^NOAUDIODATA-[0-9]+$`) | Not one frame captured; connection still opened and closed cleanly, 0 chunks; the stock `AMD()` cause shape that `VD_amd.agi`'s `ADAIR` option keys on. |
| `silence_frames` | `NOTSURE` / `SERVER_TIMEOUT` | Frames of digital silence are still audio (chunks on schedule, no EOF finalisation). |
| `schedule_full` | `HUMAN` | All eleven schedule marks (500 ... 9000 ms), then 8000-byte / 1000-ms fallback sends. |
| `eof_finalization` (`/eof_human`, `/eof_ack`, `/eof_silent`) | `HUMAN` / `HUMAN`; `NOTSURE` / `EOF_INCONCLUSIVE`; `NOTSURE` / `EOF_ERROR` after 3 s | The far side plays 1.2 s of audio and then delivers no frames: the mock record shows exactly two empty marks before the client's `{"eof":1}`, and the reply to it decides. |
| caller-id rows (`test/scenarios.txt`) | `HUMAN` | `caller_id` is present in the config JSON when `CALLERID(num)` is set, absent when it is empty or `Unknown`; option `i(cid)` replaces it; `send_caller_id=no` removes it. |
| `playback` | `HUMAN` | The playfile is audible on the far side *while* chunks are being sent (MixMonitor RMS), stopped on result (silence afterwards although the file is 6 s), mix has both sides. |
| `playback_list`, `playdelay`, `no_playback_quiet` | `HUMAN` | `a&b` plays sequentially; `d(1500)` delays; nothing leaks to the callee without a playfile. |
| `opt_n_nodb` | `HUMAN` | Option `n` skips the DB (no `phone` in the config frame). |
| `db_unreachable` (tag `db`) | `HUMAN` | With `db=yes` and a dead DB port the call completes in the same time as without DB, and the rate-limited `AMD_WS: DB connect to 127.0.0.1:<port> failed` warning is asserted in the log. SKIPped when the module was built without MySQL; `cli_show_settings` asserts `db : Yes (available)` for a DB build and `unavailable` otherwise. |
| `opt_p_k` | `HUMAN` | `p()`/`k()` appear as `phone`/`country_code` in the config JSON. |
| `opt_a_unanswered` | `HUMAN` / `FATAL_ERROR` in 0 ms | Option `A` on a not-Up channel refuses instead of answering. |
| `bad_port_default`, `default_vid` | `HUMAN` | Invalid port → warning + configured default; VID defaults to `CALLERID(name)`. |
| `bad_options` | `HUMAN` | An unbalanced `k(1` makes the option string invalid: the module warns with digits masked (`np(XXXXXXXXXX`), the phone from `p()` never reaches the log through the module, and all options are ignored. |
| `vid_escape` | `HUMAN` | A caller id name containing `"`, `\` and a non-UTF-8 byte (0xFF) round-trips through the config JSON: the mock parses exactly `<vid>"q"\z?`. |
| `tls_human` | `HUMAN` | Option `s`: `wss://` to a second mock instance with a self-signed certificate, verified through `tls_cafile` (chain verification on). Skipped without `openssl`. |
| `tls_to_plain` | `HUMAN` / `CONNECTION_ERROR` in ~20 ms | Option `s` against the plaintext port fails fast instead of hanging. |
| `concurrent` | 25 × `HUMAN` | 25 simultaneous calls, all results, exactly one mock connection per VID, Asterisk alive. |
| `blackhole` | `HUMAN` / `CONNECTION_ERROR` at `c(700)` | Accept-and-never-reply peer (`test/blackhole_server.py`): the call returns `CONNECTION_ERROR` at the connect timeout while the helper thread stays parked in the core's handshake read; `amd_ws show settings` shows `parked connects : 1`. |
| `blackhole_fill` | 7 × `HUMAN` / `CONNECTION_ERROR` | A burst of 7 more: none is refused (healthy bursts are never capped), afterwards 8 are parked and the CLI shows the host at its cap (`max_pending_connects = 8` in the test `amd_ws.conf`). |
| `blackhole_cap` | `HUMAN` / `CONNECTION_ERROR` in ~0 ms | A call starting while 8 are parked fails fast (`8 connects to 127.0.0.1 still pending ...` WARNING, `sent=0 chunks=0`). |
| `blackhole_release` | — | Killing the peer releases every parked helper: `parked connects` drops to 0 within a second (so `module unload` works again). |
| `soak_fd_rss` | — | 100 warm-up + 200 measured calls in bursts of 25 with unique VIDs (300 result lines asserted): the daemon's fd count does not grow, RSS grows less than 1 MB (the test daemon runs with `MALLOC_ARENA_MAX=1` so RSS reflects live allocations rather than per-thread arena high-water marks). |
| `log_lines` | — | Exactly one start and one end verbose line per AMD_WS channel, and their counts equal the number of AMD_WS calls the suite made (soak included). |
| `log_noise` | — | Every `WARNING`/`ERROR` in the Asterisk log matches an allow-list of intentionally provoked lines (unload busy, bad port, option `A`, connect refused/timeout, 403, TLS to the plain port, dead DB). |
| `cli_show_application`, `cli_show_settings` | — | `core show application AMD_WS` and `amd_ws show settings` are useful. |
| `unload_busy_refused`, `unload_idle`, `load_again`, `module_reload`, `reload_effect` | — | Unload refused while a call is inside `AMD_WS()`, succeeds when idle, module works after load; `module reload` with a changed `amd_ws.conf` (`timeout_ms`, `send_schedule=500`, `db=no`, `max_pending_connects`, ...) is read back from `amd_ws show settings` and a call then runs on the new configuration (500 ms chunks); the original config is restored and verified. |
| `classify_parity` (`test/classify_test.py`) | — | Thirty server strings through `amd.py`'s verbatim rule and the module's rule agree on every one except the `AMDY` guard. |
| `build_nomysql`, `build_mysql` | — | `make MYSQL=0` and `make MYSQL=1 ...` both build and pass the Makefile gates. |
| `sounds`, `no_listeners`, `mock_paths`, `self_*`, `shutdown_clean` | — | Harness plumbing (also run by `--selftest`). |

## Continuous integration

`.github/workflows/ci.yml` (ubuntu-22.04) installs `asterisk-dev` and
`libmariadb-dev`, runs `make` and `make check` with `ASTNOCHECK=1 WERROR=1`
(no daemon in CI, so the build-option sum cannot be read from a running core),
`tools/check-embedded.sh` (fails if `install.sh` is stale relative to its
sources), `shellcheck -S warning` (Ubuntu 22.04 ships 0.8.0; the sources are
also kept clean with 0.10.0), and `python3 -m py_compile test/*.py`. The
classification parity test (`python3 test/classify_test.py`) needs no
Asterisk either. The
Asterisk-driving scenarios need a real binary and are run locally with
`make test`.

## Testing a build on a dialer without touching live calls

1. `make show-config && make` — nothing is installed yet; the gates run as part
   of the build.
2. `./install.sh --build-only --output /tmp/app_amd_ws.so` does the same from
   the installer's point of view, including header resolution (no root needed).
3. Install in a maintenance window or accept exit code 3 (see
   [installer.md](installer.md#exit-codes)).
4. Place one manual call through a test campaign routed to 8370 and check the
   two `AMD_WS:` log lines ([troubleshooting.md](troubleshooting.md#1-log-lines-to-grep)).

See also: [architecture.md](architecture.md), [protocol.md](protocol.md).
