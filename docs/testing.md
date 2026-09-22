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
| `test/mock_amd_server.py` | Python 3 `asyncio` WebSocket server (`websockets` 12) speaking the `amd.py` protocol; `--tls-cert/--tls-key` make it serve `wss://` (`run.sh` starts a second, TLS instance). Behaviour is selected by URL path or, because the module always connects to `/`, by a control file that `run.sh` rewrites before every call. Records, per connection, the config JSON, every chunk's size and arrival time, total bytes, replies, `{"eof":1}` and the close code as JSON lines. |
| `test/protocol_test.py` | Assertions over those recordings: config JSON shape (with/without `phone`/`country_code`), chunk schedule (anchored on the first captured frame, ± 150 ms), bytes per chunk and total (16 000 B/s ± 10 %), `eof`, close code. |
| `test/mock_client.py` | An `amd.py`-like client used to test the mock itself (`mock_paths` check). |
| `test/asterisk/` | Configuration templates for the private Asterisk: `asterisk.conf` (all directories under `test/run/`), `modules.conf` (`autoload=no` + explicit loads), `logger.conf` (full log, verbose 3, debug 1), `extensions.conf.in` (far-side behaviours and the result writer), `amd_ws.conf.in`, `astguiclient.conf.in` (deliberately messy syntax, dead DB port). The module directory is a directory of symlinks to the system modules plus the freshly built `app_amd_ws.so`. |
| `test/run/` | Scratch (gitignored): the Asterisk tree, recordings, `results.txt`, `logs/run-<timestamp>/` with the full Asterisk log, mock log and records, per-scenario logs, build logs and CLI captures. |

The result of every call is written from the `h` extension (so it exists on
every exit path) as
`VID|AMDSTATUS|AMDCAUSE|AMDELAPSED|T0|T1|TA|base64("x"+AMDRESPONSE)|CHANNEL`;
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
directory, `python3` with `websockets` >= 10, `sox`, `gcc`, `make`, and either
system MariaDB/MySQL client dev files or a staged copy (`MYSQL_ROOT`). No root,
no listening ports other than the mock server's on loopback, no AMI/HTTP/SIP
binds (the `no_listeners` check verifies it). On the reference box the binary
needs `LD_LIBRARY_PATH=/usr/lib64`; `run.sh` takes care of it. Environment
knobs (`ASTERISK_BIN`, `AST_MODULES_DIR`, `MYSQL_ROOT`, `MAKE_ARGS`,
`SUITE_BUDGET_S`, ...) are listed in `test/README.md`.

Mock server behaviours (URL path or control file):

| Path | Server behaviour |
|---|---|
| `/human?after=N` | Ack `N` chunks (`{}`), then send `HUMAN` as the reply to chunk `N+1`. |
| `/machine`, `/amd`, `/honeypot`, `/status?value=X` | Other result tokens (`AMD` must classify as `MACHINE`, extra statuses pass through). |
| `/json` | Result as JSON `{"status": "HUMAN", ...}`. |
| `/amdy` | Acks are `AMDY ack` (must **not** classify), result later. |
| `/nothuman` | Ack `NOT_HUMAN` (must **not** classify), then `MACHINE`. |
| `/silent` | Never replies. |
| `/slow?handshake=MS` | Delays the HTTP upgrade by `MS` ms. |
| `/reject` | Answers the upgrade with HTTP 403. |
| `/close?after=N` | Closes the connection (1011) after `N` chunks, no result. |
| `/big` | Result padded to 5 KB, token at the end. |
| `/fragmented` | Result sent as several WebSocket fragments. |
| `/ping?after=N` | Sends a PING before each reply. |
| `/delay?reply=MS` | Replies delayed by `MS` ms (reading must not stall the audio loop). |

## Scenarios and what each proves

Names are the rows of `test/scenarios.txt` and the checks of `run.sh`
(`test/run.sh --list`). Wall-clock bounds include the ~500 ms that
`Answer()` on the far side waits for media before its audio starts.

| Scenario | Expected `AMDSTATUS` / `AMDCAUSE` | Proves |
|---|---|---|
| `human` | `HUMAN` / `HUMAN` < 3 s | Happy path; config JSON shape; chunks at 500/1000/1500/2000 ms after the first frame (± 150, measured ± 2 ms); 16 kB/s; `eof`; close 1000; both `AMD_WS:` verbose lines. |
| `machine`, `amd_token`, `honeypot` | `MACHINE`, `MACHINE`, `HONEYPOT` | Token rule: `AMD` → `MACHINE`; `extra_statuses` pass through verbatim. |
| `json` | `HUMAN` | Only the JSON `status` value is tokenised; `AMDRESPONSE` carries the raw text. |
| `amdy_ack` | `HUMAN` after 4 chunks | `AMDY ack` is not read as `AMD`. |
| `nothuman` | `MACHINE` | `NOT_HUMAN` is not read as `HUMAN`. |
| `server_down` | `NOTSURE` / `NETERR` in ~20 ms | Connect refused handled fast; no mock connection. |
| `slow_handshake` | `NOTSURE` / `NETERR` at `connect_timeout_ms` | A stalled handshake is bounded by the connect timeout (the channel keeps being serviced meanwhile). |
| `reject_upgrade` | `NOTSURE` / `NETERR` | HTTP 403 on the upgrade. |
| `silent_server` | `NOTSURE` / `AUDIO_TIMEOUT` at `timeout_ms` + `result_grace_ms` | Timeout and grace are real time; audio kept flowing (>= 4 chunks); `eof` and close 1000 still sent. |
| `close_midstream` | `NOTSURE` / `NETERR` | Server CLOSE before a result. |
| `big_result`, `fragmented`, `ping_frames`, `slow_reply` | `HUMAN` | 5 KB frame; fragment reassembly; PING handling; delayed acks do not stall the audio schedule. |
| `hangup` | `HANGUP` / `HANGUP` at ~1.5 s | Callee hangup mid-detection, no grace wait; `AMDELAPSED` counts from the first audio frame. |
| `no_audio` | `NOTSURE` / `NO_AUDIO_TIMEOUT` | Not one frame captured; connection still opened and closed cleanly, 0 chunks. |
| `silence_frames` | `NOTSURE` / `AUDIO_TIMEOUT` | Frames of digital silence are still audio (5 chunks on schedule). |
| `schedule_full` | `HUMAN` after 9 chunks | All six schedule marks (500 ... 4000 ms), then 8000-byte chunks every 500 ms. |
| `playback` | `HUMAN` | The playfile is audible on the far side *while* chunks are being sent (MixMonitor RMS), stopped on result (silence afterwards although the file is 6 s), mix has both sides. |
| `playback_list`, `playdelay`, `no_playback_quiet` | `HUMAN` | `a&b` plays sequentially; `d(1500)` delays; nothing leaks to the callee without a playfile. |
| `opt_n_nodb`, `db_unreachable` | `HUMAN` | Option `n` skips the DB; with `db=yes` and a dead DB port the call completes in the same time as without DB (one rate-limited warning). |
| `opt_p_k` | `HUMAN` | `p()`/`k()` appear as `phone`/`country_code` in the config JSON. |
| `opt_a_unanswered` | `NOTSURE` / `INTERR` in 0 ms | Option `A` on a not-Up channel refuses instead of answering. |
| `bad_port_default`, `default_vid` | `HUMAN` | Invalid port → warning + configured default; VID defaults to `CALLERID(name)`. |
| `tls_human` | `HUMAN` | Option `s`: `wss://` to a second mock instance with a self-signed certificate, verified through `tls_cafile` (chain verification on). Skipped without `openssl`. |
| `tls_to_plain` | `NOTSURE` / `NETERR` in ~20 ms | Option `s` against the plaintext port fails fast instead of hanging. |
| `concurrent` | 25 × `HUMAN` | 25 simultaneous calls, all results, Asterisk alive. |
| `soak_fd_rss` | — | 100 warm-up + 200 measured calls in bursts of 25: the daemon's fd count does not grow, RSS grows less than 1 MB (the test daemon runs with `MALLOC_ARENA_MAX=1` so RSS reflects live allocations rather than per-thread arena high-water marks). |
| `log_lines` | — | The two mandatory verbose lines exist for every call. |
| `log_noise` | — | Every `WARNING`/`ERROR` in the Asterisk log matches an allow-list of intentionally provoked lines (unload busy, bad port, option `A`, connect refused/timeout, 403, TLS to the plain port, dead DB). |
| `cli_show_application`, `cli_show_settings` | — | `core show application AMD_WS` and `amd_ws show settings` are useful. |
| `unload_busy_refused`, `unload_idle`, `load_again`, `module_reload` | — | Unload refused while a call is inside `AMD_WS()`, succeeds when idle, module works after load, `module reload` succeeds. |
| `build_nomysql`, `build_mysql` | — | `make MYSQL=0` and `make MYSQL=1 ...` both build and pass the Makefile gates. |
| `sounds`, `no_listeners`, `mock_paths`, `self_*`, `shutdown_clean` | — | Harness plumbing (also run by `--selftest`). |

## Continuous integration

`.github/workflows/ci.yml` (ubuntu-22.04) installs `asterisk-dev` and
`libmariadb-dev`, runs `make` and `make check` with `ASTNOCHECK=1 WERROR=1`
(no daemon in CI, so the build-option sum cannot be read from a running core),
`tools/check-embedded.sh` (fails if `install.sh` is stale relative to its
sources), `shellcheck`, and `python3 -m py_compile test/*.py`. The
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
