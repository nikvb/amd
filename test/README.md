# app_amd_ws test harness

End-to-end tests for the `AMD_WS()` dialplan application, run against the
**real Asterisk binary on the box** (16.30.1-vici here) as an unprivileged
user, with a Python mock of the amdy.io AMD WebSocket service. No root, no
network listeners, nothing outside `test/run/` is written.

```
test/
  run.sh               the harness: build, start mock + Asterisk, run scenarios, PASS/FAIL table
  scenarios.txt        data-driven scenario table (add a line = add a test)
  mock_amd_server.py   mock AMD service (websockets legacy API, 10-12 tested with 12.0); behaviour by URL path or control file
  blackhole_server.py  accept-and-never-reply TCP listener (server that never finishes the handshake)
  local.env            OPTIONAL, gitignored: per-box settings such as MYSQL_ROOT=/path
  mock_client.py       amd.py-like client used to test the mock itself
  protocol_test.py     assertions over the mock's recordings (config JSON, chunk timing, bytes, eof, close)
  asterisk/            config templates for the test Asterisk instance
  run/                 scratch (gitignored): Asterisk dirs, results.txt, recordings, logs/
```

## Quick start

```sh
# 1. harness self-test - needs no module; proves originate, playback capture,
#    results file, mock server, sox RMS assertion, timing, clean shutdown (about 25 s)
test/run.sh --selftest

# 2. full suite - builds ../app_amd_ws.so with make and runs every scenario (about 2-3 min)
test/run.sh

# useful variants
test/run.sh --list                         # scenarios + checks
test/run.sh --only human,playback          # a subset (checks like unload_busy, soak_fd_rss, log_noise can be named too)
test/run.sh --keep                         # leave Asterisk + mock running for a look
test/run.sh --module /path/app_amd_ws.so   # test a prebuilt module (skips make)
test/run.sh --no-build                     # use ../app_amd_ws.so as it is
```

Exit status: `0` all PASS, `1` at least one FAIL, `2` harness problem
(Asterisk did not start, module missing in full mode, ...). Everything a run
produced is under `test/run/logs/run-<timestamp>/` (`latest` symlink):
`summary.txt`, `full` (Asterisk log, verbose 3 + debug 1), `mock.log`,
`mock-record.jsonl`, `results.txt`, `scenario-<VID>.log`, `build.log`.

The AMD_WS scenarios need the built v2 module (`app_amd_ws.c` using
`res_http_websocket`). Until it exists run.sh reports them as SKIP and exits 2;
`--selftest` is the mode to use meanwhile.

### Requirements

* `/usr/sbin/asterisk` runnable with `LD_LIBRARY_PATH=/usr/lib64`
  (override: `ASTERISK_BIN`, `AST_LD_LIBRARY_PATH`), its modules in
  `/usr/lib64/asterisk/modules` (`AST_MODULES_DIR`) and its XML documentation
  in `/var/lib/asterisk/documentation` (`AST_DATA_DIR`; the core refuses to
  boot without `core-en_US.xml`).
* python3 with `websockets` 10-12 (12.0 tested; the mock imports the legacy
  API from `websockets.legacy.server`, so 13+ works while that module ships),
  `sox`/`soxi`, GNU make, gcc.
* For the DB-enabled build: system MariaDB/MySQL client dev files, or a
  root-less staged copy pointed to by `MYSQL_ROOT` (a directory holding
  `include/mariadb` and `lib/x86_64-linux-gnu`); put
  `MYSQL_ROOT=/path` into the gitignored `test/local.env` so `test/run.sh`
  finds it every time. Without either, `build_mysql` and the `db`-tagged
  scenarios are SKIPped and a hint is printed (pass `MYSQL_CFLAGS`/`MYSQL_LIBS`
  through `MAKE_ARGS` for anything else).
* Slow box? `TEST_SLOW_FACTOR=2 test/run.sh` multiplies every upper timing
  bound (max wall, `elapsed<=`, burst launch, suite budget); lower bounds stay.

## How a call is made

```
asterisk -rx 'channel originate Local/0007@farside-human/n extension 0007@amdside-human'

  Local/0007@farside-human;2  ->  [farside-human]  Answer, Playback(amd-speech8), (MixMonitor)
  Local/0007@farside-human;1  ->  [amdside-human]  Set(T0), AMD_WS(127.0.0.1,${MOCK_PORT},0007_human,8000,,), Set(T1), Hangup
                                  h -> write-result: append one line to test/run/results.txt
```

* The **farside** (;2) is the callee: it plays a generated 8 kHz wav (speech
  sweep, 1.5 s speech then hangup, digital silence, or nothing at all) and,
  for the playback scenarios, records what it *hears* with
  `MixMonitor(mix.wav,Sr(heard.wav))`.
* The **amdside** (;1) runs the application under test and writes the result
  from the `h` extension, so a line appears on every exit path (normal return,
  hangup, even a missing application).
* `VID = <NNNN>_<scenario>` is unique per call (4-digit counter) and is what
  correlates results.txt, the mock recording, the recordings and the log.
  The scenario name travels in the *context* name because Asterisk pattern
  matching treats `n`/`x`/`z` (any case) as digit wildcards.
* Results line: `VID|AMDSTATUS|AMDCAUSE|AMDELAPSED|T0|T1|TA|base64("x"+AMDRESPONSE)|CHANNEL`
  (T0/T1 = ms epoch around the application, TA = when the farside started
  sending audio). AMDRESPONSE is base64 so quotes/JSON cannot break the shell
  `System(echo ... >> results.txt)`; run.sh decodes it.
* Timing note: `Answer()` on a ringing Local leg waits up to 500 ms for media
  from the other side. When the amdside sends no audio (no playfile) the
  farside's audio therefore starts ~500 ms after AMD_WS did, so wall-clock
  bounds in the table are ~500 ms wider than the pure AMD clock.

## The mock service (`mock_amd_server.py`)

Speaks the amd.py protocol: config JSON in, binary audio chunks in, one text
reply per chunk out (ack or result), `{"eof":1}` and close 1000 at the end.
The module always connects to `/`, so run.sh writes the wanted behaviour into
`test/run/mock.control` before each call (`--control FILE`); explicit paths
work too:

| path | behaviour |
|------|-----------|
| `/human?after=N` | N acks (`{}`), then `HUMAN` as reply to chunk N+1 |
| `/machine`, `/amd`, `/honeypot`, `/status?value=FAS` | other result tokens |
| `/json` | result `{"status": "HUMAN", ...}` |
| `/amdy` | acks are `AMDY ack` (must not classify), result later |
| `/nothuman` | ack `NOT_HUMAN`, then `MACHINE` |
| `/silent` | never replies |
| `/slow?handshake=MS` | delays the HTTP upgrade |
| `/reject` | HTTP 403 on upgrade |
| `/close?after=N` | server closes (1011) mid-stream |
| `/big` | result padded to 5 KB, token at the end |
| `/fragmented` | result in several WebSocket fragments |
| `/ping?after=N` | ping before each reply |
| `/delay?reply=MS` | replies delayed (reading must not stall the audio loop) |

Every connection is recorded as a JSON line (`mock-record.jsonl`): config
JSON, chunk sizes and arrival times (ms since connect), total bytes, eof seen,
close code, replies. `protocol_test.py --record FILE --vid VID --checks ...`
asserts on it (used by run.sh's `proto` assertions and usable by hand).

## Scenario table (`scenarios.txt`)

One `|`-separated line per scenario; run.sh generates the dialplan from it.
Columns: name, tags (`self` plumbing / `amd` needs module / `db` needs the MySQL build / `probe`), count
(simultaneous originates), farside behaviour, mock path, amdside spec
(`ws:<timeout>,<playfile>,<opts>` -> `AMD_WS(127.0.0.1,${MOCK_PORT},${VID},...)`;
`wsdead:` uses a port nothing listens on; `wstls:` the wss mock; `wshole:` the
accept-and-never-reply listener; `wsraw:` verbatim args; `app:` any
dialplan apps), post apps, expected AMDSTATUS/AMDCAUSE, min/max wall ms, and
assertions (`proto`, `chunks=N`, `noconn`, `resp~TEXT`, `elapsed<=N`,
`heard>THR`, `heard[start:len]<THR`, `heard_dur>S`, `mix>THR`, `log~REGEX`
anchored with `Local/%NUM%@farside-%NAME%-[0-9a-f]+;1`, `cli~REGEX` on
`amd_ws show settings`, `mockvid=TEXT`, `alive`). Bursts get `log~`/`cli~`
plus a one-connection-per-VID check against the mock records. The header of
the file documents every token. To add a case: add a line; no shell code
needed.

### What each scenario proves

Self-test (run in both modes, no module needed):

| scenario | proves |
|----------|--------|
| `sounds` | sox generated the 8 kHz/16-bit wavs; the RMS assertion distinguishes speech from silence |
| `no_listeners` | the test Asterisk has no TCP/UDP listeners (only its CLI unix socket) |
| `mock_paths` | every mock path with the amd.py-like client (19 runs incl. control-file routing, TCP abort -> close 1006, phone/country) + protocol_test on every record |
| `self_originate` | Local originate farside -> amdside works; results line is written; T0/T1 timing (Wait(1) ~= 1000 ms) |
| `self_playback_rec` | audio played by the amdside is captured on the farside with Record() (RMS > 0.05, ~3 s) |
| `self_echo` | Playback + Echo placeholder; farside hangup ends the amdside app |
| `self_mix` | MixMonitor `Sr()` captures what the farside hears, time-aligned: loud while the 1 s prompt plays, silent afterwards |
| `self_noaudio` | a farside that never sends a frame still yields a result line |
| `self_hangup` | result is written from `h` when the callee hangs up mid-application |
| `self_noanswer` | the un-answered Local leg used by the option-A scenario really is not Up |
| `self_burst` | 25 originates within 1 s -> 25 results, Asterisk alive |
| `shutdown_clean` | `core stop now` ends the daemon; `pgrep` shows nothing left |

AMD_WS (need the built module):

| scenario | expected | proves |
|----------|----------|--------|
| `human` | HUMAN/HUMAN < 3 s | happy path; config JSON shape, chunks at 500/1000/1500/2000 ms (+/-150), 16 kB/s, eof, close 1000; the two `AMD_WS:` verbose lines |
| `machine`, `amd_token`, `honeypot` | MACHINE, MACHINE, HONEYPOT | token rule: `AMD` -> MACHINE, extra statuses pass through verbatim |
| `json` | HUMAN | only the `status` value of a JSON reply is tokenised; AMDRESPONSE carries the raw text |
| `amdy_ack` | HUMAN after 4 chunks | `AMDY ack` must not be read as AMD |
| `nothuman` | MACHINE | `NOT_HUMAN` must not be read as HUMAN |
| `server_down` | NOTSURE/NETERR fast | connect refused; no mock connection |
| `slow_handshake` | NOTSURE/NETERR ~2 s | upgrade slower than connect_timeout_ms |
| `opt_c_connto` | NOTSURE/NETERR ~300 ms | `c(300)` overrides the connect timeout per call |
| `hangup_in_connect` | HANGUP/HANGUP ~1.5 s | callee hangs up while the handshake is pending: no grace, nothing sent, late socket discarded |
| `expire_in_connect` | NOTSURE/NETERR at timeout_ms | the detection window ends before a slow handshake: NETERR, not a timeout cause |
| `reject_upgrade` | NOTSURE/NETERR | HTTP 403 handshake |
| `silent_server` | NOTSURE/AUDIO_TIMEOUT at timeout+grace | 3000 ms timeout + 1000 ms grace; audio kept flowing (>= 4 chunks), eof + close 1000 still sent |
| `close_midstream` | NOTSURE/NETERR | server CLOSE before a result |
| `big_result`, `fragmented`, `ping_frames`, `slow_reply` | HUMAN | 5 KB frame, fragment reassembly, PING handling, delayed acks do not stall audio |
| `hangup` | HANGUP/HANGUP ~1.5 s | callee hangup mid-detection; AMDELAPSED counts from the first audio frame |
| `no_audio` | NOTSURE/NO_AUDIO_TIMEOUT | not a single frame captured; connection still opened/closed cleanly |
| `silence_frames` | NOTSURE/AUDIO_TIMEOUT | frames of digital silence are still audio |
| `schedule_full` | HUMAN after 9 chunks | all six schedule marks (500..4000 ms) then 8000-byte chunks every 500 ms |
| `playback` | HUMAN | playfile audible on the farside during detection (RMS), *stopped on result* (silence after ~2.7 s although the file is 6 s), mix has both sides |
| `playback_list` | HUMAN | `a&b` plays sequentially |
| `playdelay` | HUMAN | `d(1500)`: first 0.8 s heard is silent, audible later |
| `no_playback_quiet` | HUMAN | nothing leaks to the callee without a playfile |
| `opt_n_nodb` | HUMAN | option `n` skips the DB (no phone in the config frame) |
| `db_unreachable` (tag `db`) | HUMAN | with db=yes and a refused 127.0.0.1 port the call still completes quickly and the rate-limited `DB connect to 127.0.0.1:<port> failed` warning is in the log; SKIP without the MySQL build |
| `opt_p_k` | HUMAN | `p()`/`k()` appear as `phone`/`country_code` in the config JSON |
| `opt_a_unanswered` | NOTSURE/INTERR | option `A` on a not-Up channel refuses instead of answering |
| `bad_port_default` | HUMAN | invalid port -> warning + conf default (anchored to the call's channel) |
| `bad_options` | HUMAN | unbalanced `k(1`: warning with digits masked (`np(XXXXXXXXXX`), the phone never appears through the module, all options ignored |
| `vid_escape` | HUMAN | caller id name with `"`, `\` and a 0xFF byte round-trips through the config JSON (mock parses `<vid>"q"\z?`) |
| `default_vid` | HUMAN | vid defaults to CALLERID(name) |
| `tls_human` | HUMAN | option `s` -> `wss://` to a second mock instance with a self-signed certificate; `tls_verify=yes` with `tls_cafile=<that cert>` (chain verification on, hostname check off as on Asterisk 16). SKIP when `openssl` is missing |
| `tls_to_plain` | NOTSURE/NETERR fast | option `s` against the plaintext mock port: the TLS handshake fails, no hang, no connection record |
| `concurrent` | 25 x HUMAN | 25 simultaneous calls, all results, exactly one mock connection per VID, Asterisk alive |
| `blackhole` | NOTSURE/NETERR at c(700) | peer accepts TCP and never answers: the call returns at the connect timeout, the helper stays parked, `parked connects : 1` |
| `blackhole_fill` | 7 x NOTSURE/NETERR | a burst of 7 more is not refused (healthy bursts are never capped); afterwards 8 are parked = `max_pending_connects` (test conf) |
| `blackhole_cap` | NOTSURE/NETERR ~0 ms | a call starting at the cap fails fast with the `8 connects to 127.0.0.1 still pending` warning |
| `blackhole_release` | - | killing the peer releases the parked helpers: `parked connects` -> 0 within a second |
| `soak_fd_rss` | - | 100 warm-up + 200 measured calls (bursts of 25 through the `soak` probe row, unique VIDs, 300 result lines asserted): the daemon's fd count must not grow, RSS must grow < `SOAK_RSS_LIMIT_KB` (1024). The test daemon runs with `MALLOC_ARENA_MAX=1` so RSS tracks live allocations instead of per-thread malloc arena high-water marks (measured here: default malloc +3 MB/200 calls and still creeping, one arena +136 kB and flat) |
| `log_lines` | - | exactly one SPEC section 6 start and one end verbose line per AMD_WS channel; counts equal the number of AMD_WS calls made |
| `log_noise` | - | every WARNING/ERROR line in the Asterisk log matches `LOG_NOISE_ALLOW` in run.sh (intentionally provoked: unload busy, bad port, option A, connect refused/timeout, HTTP 403, TLS to the plain port, dead DB); anything else fails, listed in `log-noise-unexpected.txt` |
| `cli_show_application`, `cli_show_settings` | - | `core show application AMD_WS` is useful; `amd_ws show settings` reports the DB support the module was built with, `astguiclient.conf` read, `connects in flight`, `max_pending_connects` |
| `unload_busy_refused`, `unload_idle`, `load_again`, `module_reload`, `reload_effect` | - | unload refused while a call is inside AMD_WS, succeeds when idle, module works after load; a changed amd_ws.conf (timeout_ms, send_schedule=500, result_grace_ms=0, extra_statuses=+GOOGLE_VOICE, db=no, max_pending_connects) is read back after `module reload` and a call classifies GOOGLE_VOICE on 500 ms chunks; the config is restored afterwards |
| `build_nomysql`, `build_mysql` | - | `make MYSQL=0` and `make MYSQL=1 ...` both build; no undefined non-Asterisk symbols |

## Notes for the integrator

* run.sh builds with `make -C <repo>` twice: `MYSQL=0`, then `MYSQL=1` with
  `MYSQL_CFLAGS`/`MYSQL_LIBS` from `MYSQL_ROOT` when there are no system dev
  files. `LD_LIBRARY_PATH` for the test Asterisk then includes the staged
  `libmariadb.so.3` directory. The final `.so` under test is the MySQL build.
* The test `amd_ws.conf` (rendered from `asterisk/amd_ws.conf.in`) uses
  `connect_timeout_ms=2000`, `result_grace_ms=1000`, the default schedule,
  `tls_cafile=<run>/etc/tls.crt` (the wss mock's self-signed certificate,
  generated per run with `openssl req -x509`; a second mock instance serves
  `wss://` on `TLS_PORT`) and
  `astguiclient_conf=<run>/etc/astguiclient.conf`, which points VARDB_* at
  `127.0.0.1:<dead port>` with deliberately messy syntax (tabs, comments,
  `=>` in a value). Never the real DB credentials.
* Timing bounds were confirmed against the real module (all scenarios land
  within 1-3 ms of the expected AMD clock); `min_ms`/`max_ms` in
  `scenarios.txt` include the 500 ms Answer wait described above. The chunk
  schedule assertion is anchored on TA (`--audio-start` of protocol_test.py):
  the module clocks the schedule from its first captured frame, not from the
  WebSocket connect. The whole suite has a 240 s budget (`SUITE_BUDGET_S`);
  a full run takes about 150 s here.
* `TEST_MALLOC_ARENA_MAX` (default 1) is exported to the test daemon only;
  `SOAK_RSS_LIMIT_KB` (default 1024) is the allowed RSS growth of the soak.
* `test/run/` is gitignored; delete it to start clean. A unix socket path is
  limited to ~107 bytes, so for very deep checkouts run.sh moves only
  `astrundir` to `$TMPDIR/amd_ws_test-<uid>/run`.
* Lessons learned about this Asterisk (kept here so nobody rediscovers them):
  a `[directories]` section carrying the `(!)` template marker in asterisk.conf
  is ignored, the core needs
  its XML documentation dir to boot, `n`/`x`/`z` are wildcards in patterns,
  `channel originate` returns immediately (`AST_OUTGOING_NO_WAIT`), and
  `asterisk -rx` needs an absolute `-C` path.
