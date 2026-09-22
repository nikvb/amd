# Testing

The repository ships an end-to-end harness under `test/` that drives the
**real** Asterisk binary with the freshly built module against a mock AMD
server, without root and without touching the system Asterisk configuration.
The authoritative, step-by-step description of the harness and of every
scenario is [`test/README.md`](../test/README.md); this page is the overview.

## What is in `test/`

| Path | Role |
|---|---|
| `test/mock_amd_server.py` | Python 3 `asyncio` WebSocket server (`websockets` 12). The behaviour is selected by the URL path, so one server instance serves every scenario. Records, per connection, the config JSON, every chunk's size and arrival time (ms since connect), total bytes, whether `{"eof":1}` was seen and the close code, as JSON lines (`--record FILE`). `--port` selects the port. |
| `test/asterisk/` | Minimal configuration for the real Asterisk binary: `asterisk.conf` with every directory under a scratch run directory, `modules.conf` with `autoload=no` and an explicit load list (`pbx_config`, `res_timing_timerfd`, `res_http_websocket`, `app_playback`, `app_system`, `app_verbose`, `app_echo`, `app_mixmonitor`, `app_record`, `app_dial`, `app_originate`, `format_sln`, `format_wav`, codecs and functions), `logger.conf` (full log with verbose 3 and debug 1) and `extensions.conf` with a `farside` context (plays a generated file or stays silent, records what it hears) and an `amdside` context that runs `AMD_WS(127.0.0.1,${PORT},${VID},${TIMEOUT},${PLAYFILE},${OPTS})` and appends `VID AMDSTATUS AMDCAUSE AMDELAPSED AMDRESPONSE` to a results file. The module directory is a directory of symlinks to the system modules plus the freshly built `app_amd_ws.so`. |
| `test/run.sh` | Builds the module (with the MySQL client, and once more with `MYSQL=0`), starts the mock server and Asterisk, originates one `Local/<scenario>@farside` → `<scenario>@amdside` call per scenario, waits, asserts, prints a table and exits non-zero on any failure. |

Sound files (8 kHz mono 16-bit: an 8 s speech-like tone sweep, a 0.5 s beep,
silence) are generated with `sox` at run time.

## Running it

```bash
make test        # same as: test/run.sh
```

Requirements on the box: an Asterisk 16+ binary with `res_http_websocket.so`
and the modules listed above, `python3` with `websockets` 12, `sox`, `gcc`,
`make`. No root, no listening ports other than the mock server's, no AMI/HTTP/
SIP binds. Start/stop is `asterisk -C <cfg> -F` and `asterisk -C <cfg> -rx
'core stop now'`. On the reference box the binary needs
`LD_LIBRARY_PATH=/usr/lib64`; `run.sh` takes care of it.

Mock server paths and what they simulate:

| Path | Server behaviour |
|---|---|
| `/human?after=N` | Ack `N` chunks, then send `HUMAN`. |
| `/machine` | Result `MACHINE`. |
| `/honeypot` | Result `HONEYPOT` (extra status passthrough). |
| `/json` | Result as JSON `{"status":"HUMAN"}`. |
| `/amdy` | Acks are `AMDY ack` (must **not** classify), result later. |
| `/nothuman` | Ack `NOT_HUMAN` (must **not** classify), then `MACHINE`. |
| `/silent` | Never replies. |
| `/slow?handshake=MS` | Delays the HTTP upgrade by `MS` ms. |
| `/close?after=N` | Closes the connection after `N` chunks, no result. |
| `/big` | Result padded to 5 KB. |
| `/fragmented` | Result sent as several WebSocket fragments. |

## Scenarios and what each proves

| Scenario | Expected `AMDSTATUS` / `AMDCAUSE` | Proves |
|---|---|---|
| human | `HUMAN` / `HUMAN` within 3 s | Basic path, schedule, non-blocking result read. |
| machine | `MACHINE` / `MACHINE` | Machine token. |
| honeypot | `HONEYPOT` / `HONEYPOT` | `extra_statuses` passthrough verbatim. |
| json | `HUMAN` / `HUMAN` | JSON `status` key is honoured. |
| amdy-ack | not `MACHINE` before the real result | `AMDY` is not mis-read as `AMD`. |
| nothuman | `MACHINE` / `MACHINE` | `NOT_HUMAN` is not mis-read as `HUMAN`. |
| server-down | `NOTSURE` / `NETERR` within `connect_timeout_ms` + 500 ms | Real connect timeout, refused connect handled fast. |
| slow-handshake (> connect timeout) | `NOTSURE` / `NETERR` | Handshake delay is bounded by the connect timeout. |
| silent server | `NOTSURE` / `AUDIO_TIMEOUT` at `timeout_ms` + `result_grace_ms` ± 300 ms | Detection timeout and grace are real time. |
| close-mid-stream | `NOTSURE` / `NETERR` | Server CLOSE before result. |
| big result | classified | Results larger than 255 bytes are not dropped. |
| fragmented result | classified | Fragments are reassembled before classification. |
| hangup mid-detection (farside hangs up at 1.5 s) | `HANGUP` / `HANGUP` | Immediate hangup detection, no grace wait. |
| no-audio (farside sends no frames) | `NOTSURE` / `NO_AUDIO_TIMEOUT` | Distinction between "no audio" and "no result". |
| playback | result as configured; farside recording is non-silent (RMS above threshold); log shows playback stopped on result | Parallel playback does not blind detection and is stopped on result. |
| playdelay | playback starts after the configured delay | `playdelay_ms` / `d(ms)`. |
| option `n` | completes; config JSON has no `phone` | DB lookup skipped. |
| DB unreachable (no MySQL server: connect refused) | completes within `db_timeout_ms` | Fail-soft DB path. |
| option `A` on an un-answered channel | `NOTSURE` / `INTERR` | Do-not-answer semantics. |
| 25 concurrent calls | all results present, no crash | Thread safety, no shared per-call state. |
| protocol assertions (from the mock record) | config JSON exact shape; first chunk at 500 ± 150 ms and the following marks on schedule; total bytes ≈ 16000 B/s × duration ± 10 %; `eof` seen; close code 1000 | Wire compatibility with `amd.py`. |
| module unload | succeeds when idle, refused while a call runs | Core use count works. |
| CLI | `amd_ws show settings` prints; `core show application AMD_WS` non-empty | CLI and application registration. |
| `MYSQL=0` build | builds and passes the non-DB scenarios | Compile-time optional DB. |

## Continuous integration

`.github/workflows/ci.yml` (ubuntu-22.04) installs `asterisk-dev` and
`libmariadb-dev`, runs `make`, `make check` with `ASTNOCHECK=1` (no daemon in
CI, so the build-option sum cannot be read from a running core),
`tools/check-embedded.sh` (fails if `install.sh` is stale relative to its
sources), `shellcheck install.sh`, and `python3 -m py_compile test/*.py`. The
Asterisk-driving scenarios need a real binary and are run locally with
`make test`.

## Testing a build on a dialer without touching live calls

1. `make show-config && make && make check` — nothing is installed yet.
2. `sudo ./install.sh --build-only` does the same from the installer's point of
   view, including header resolution.
3. Install in a maintenance window or accept exit code 3 (see
   [installer.md](installer.md#exit-codes)).
4. Place one manual call through a test campaign routed to 8370 and check the
   two `AMD_WS:` log lines ([troubleshooting.md](troubleshooting.md#1-log-lines-to-grep)).

See also: [architecture.md](architecture.md), [protocol.md](protocol.md).
