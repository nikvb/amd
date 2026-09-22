# Wire protocol

This is the protocol `AMD_WS()` speaks to the AMD service. It is the protocol
of the production EAGI client `amd.py` as shipped in July 2026
(`gw.724care.com/amdy.tar.gz`): the same frames, the same send schedule, the
same EOF finalisation and the same result vocabulary. Where the module differs
from `amd.py` in *behaviour* (not in bytes on the wire) the difference is
called out; the complete list is at the end.

Transport: one WebSocket connection per call. Text frames carry JSON or plain
text; binary frames carry raw audio. Nothing else is sent.

## Sequence (normal call)

```text
 Asterisk (AMD_WS)                                        AMD server
 ------------------                                       ----------
 TCP connect + HTTP Upgrade  GET / (ws:// or wss://)     --->
                                                          <---  101 Switching Protocols
 TEXT  {"config":{"sample_rate":8000,"VID":"...",
                  "phone":"...","country_code":"...",
                  "caller_id":"..."}}                     --->
                                                          <---  TEXT ack            (optional)
 (first audio frame read from the channel: t = 0)
 BINARY  audio accumulated during 0-500 ms                --->   at t = 500 ms
                                                          <---  TEXT ack
 BINARY  audio 500-1000 ms                                --->   at t = 1000 ms
                                                          <---  TEXT ack
 BINARY  audio 1000-1500 ms                               --->   at t = 1500 ms
                                                          <---  TEXT ack
 BINARY  audio 1500-2000 ms                               --->   at t = 2000 ms
                                                          <---  TEXT ack
 BINARY  audio 2000-3000 ms                               --->   at t = 3000 ms
                                                          <---  TEXT "HUMAN"        (result)
 TEXT  {"eof":1}                                          --->
 CLOSE 1000                                               --->
                                                          <---  CLOSE 1000
```

If no result arrives, sending continues at the remaining marks (4000, 5000,
... 9000 ms) and afterwards whenever `chunk_bytes` (8000 B = 500 ms) have
accumulated or `fallback_interval_ms` (1000 ms) have passed since the last
send, until `timeout_ms` (10 s) has elapsed since the first captured frame.

## 1. Connection

- URL: `ws://<host>:<port>/` (path `/`), or `wss://` with option `s` /
  `tls=yes`. `amd.py` uses `ws://api.amdy.io:2700`.
- No WebSocket subprotocol is required. The client does not fail if the server
  echoes none.
- The connect (DNS, TCP, TLS, HTTP upgrade) is bounded by `connect_timeout_ms`
  (default 10000 ms = `amd.py`'s `CONNECTION_TIMEOUT`; option `c(ms)`). A
  failure or timeout, and a missing `res_http_websocket`, end the call with
  `AMDSTATUS=HUMAN`, `AMDCAUSE=CONNECTION_ERROR` — `amd.py`'s "AMD service
  unavailable - defaulting to HUMAN for safety". Audio is captured while the
  connect is in progress and flushed once the socket is up.

## 2. Config frame (client → server, TEXT)

Sent once, immediately after the upgrade. Keys appear in exactly this order,
and optional keys are left out rather than sent empty:

```json
{"config":{"sample_rate":8000,"VID":"<vid>","phone":"<phone>","country_code":"<code>","caller_id":"<cid>"}}
```

Minimal form (no DB row, no caller id):

```json
{"config":{"sample_rate":8000,"VID":"V9211234560000123"}}
```

Full form on a ViciDial dialer:

```json
{"config":{"sample_rate":8000,"VID":"V9211234560000123","phone":"3125551212","country_code":"1","caller_id":"3125550100"}}
```

| Field | Value | Present when |
|---|---|---|
| `sample_rate` | Always `8000`. | always |
| `VID` | The `vid` argument, else the channel's caller id name, else `Unknown`. | always |
| `phone` | `vicidial_auto_calls.phone_number` for the VID (`SELECT phone_code,phone_number FROM vicidial_auto_calls WHERE callerid='<vid>' ORDER BY auto_call_id DESC LIMIT 1`, the query `amd.py` runs), or `p(...)`. | the row exists and the column is non-empty, or `p()` was given |
| `country_code` | `vicidial_auto_calls.phone_code` for the VID, or `k(...)`. | the row exists and the column is non-empty, or `k()` was given |
| `caller_id` | The channel's `${CALLERID(num)}` (`amd.py`: `agi_callerid`, the outbound caller id ViciDial presents), or `i(...)`. | non-empty, not `Unknown`, and `send_caller_id=yes` (default) |

JSON escaping of every string value: `"`, `\` and control characters are
escaped, valid UTF-8 passes through unchanged, and invalid UTF-8 bytes are
replaced by `?` so the TEXT frame is always valid UTF-8 (RFC 6455 requires it).

## 3. Audio frames (client → server, BINARY)

- Format: signed linear PCM, 8000 Hz, 16-bit little-endian, mono
  (Asterisk `slin`). The module sets the channel read format to `slin` for the
  duration of the call and restores it on exit.
- Every byte read from the channel is accumulated and eventually sent; nothing
  is dropped or truncated regardless of the frame size the channel delivers
  (10, 20, 30 or 60 ms frames all work).
- Timing is measured from the **first captured audio frame**, not from the
  connect. (`amd.py` starts its clock when its audio loop starts; on a leg
  that delivers audio immediately that is the same instant.)
- At each mark in `send_schedule` (default
  `500,1000,1500,2000,3000,4000,5000,6000,7000,8000,9000` ms = `amd.py`
  `SEND_TIMES`) everything accumulated since the previous send goes out as one
  binary frame. A mark at which nothing has been captured sends nothing (see
  [EOF finalisation](#5-eof-finalisation-no-audio-data-marks)).
- After the last mark a frame is sent whenever at least `chunk_bytes`
  (default 8000) have accumulated **or** `fallback_interval_ms` (default 1000)
  have passed since the last send and the buffer is not empty
  (`amd.py`'s "fallback send").
- A `send_schedule` with a single value (for example `500`) means plain
  fixed-interval chunks of that length.
- A single send larger than 16000 bytes (1 s of audio, which only happens
  when audio piled up during a slow connect) goes out as several binary
  frames of at most 16000 bytes each, back to back. `amd.py` sends one
  message of any size; the core's `ast_websocket_write()` copies each frame
  onto the calling thread's stack (`ast_alloca`), so the module bounds it.
  The audio is the same; a server that acknowledges per message replies
  once per piece, and `AMDSTATS` counts the pieces as chunks.

Expected frame sizes with the defaults and continuous 20 ms audio:

| Sent at | Contains | Bytes |
|---|---|---|
| 500 ms | 0-500 ms | ~8000 |
| 1000 ms | 500-1000 ms | ~8000 |
| 1500 ms | 1000-1500 ms | ~8000 |
| 2000 ms | 1500-2000 ms | ~8000 |
| 3000 ms | 2000-3000 ms | ~16000 |
| 4000 ... 9000 ms | the previous second | ~16000 each |
| afterwards | every 8000 B (500 ms), or after 1000 ms if less arrived | 8000 |

Total throughput is 16000 B/s of audio plus WebSocket framing.

## 4. Server replies (server → client, TEXT)

After every binary frame the server sends one TEXT frame: either an
acknowledgement or a result. `amd.py` blocks in `recv()` after each send (and,
once the schedule is exhausted and it has nothing to send, polls for 50 ms
once a second); the module instead reads whenever the socket is readable and
never blocks the audio loop, so a result is honoured the moment it arrives,
whether or not a chunk was just sent. This is a superset of `amd.py`'s
behaviour: every reply `amd.py` would see, the module sees too.

### Classification rule

The rule is `amd.py`'s, in `amd.py`'s order, with its substring semantics and
case sensitivity:

1. if the text contains `HUMAN` → `AMDSTATUS=HUMAN`, `AMDCAUSE=HUMAN`;
2. else if the text contains `AMD` or `MACHINE` → `AMDSTATUS=MACHINE`,
   `AMDCAUSE=<the reply text>` (sanitised to printable ASCII, cut at 255);
3. else the reply is an acknowledgement: keep streaming.

One guard that `amd.py` does not have: an `AMD` immediately followed by `Y`
(the brand string `AMDY`, as in an ack `AMDY ack`) does not count as `AMD`.
Everything else is identical, including the consequences of substring
matching: `NOT_HUMAN` contains `HUMAN` and therefore classifies as `HUMAN`,
exactly as it does with `amd.py`; lowercase `human` or `amd` does not match
(case-sensitive). There is no configurable list of extra statuses: a reply
such as `FAS` or `NOTSURE` is an acknowledgement and detection continues,
as with `amd.py`.

### Acknowledgements

Any text without `HUMAN`, `AMD` (other than `AMDY`) or `MACHINE`:

```text
(empty frame)
{}
ack
AMDY ack
{"status":"ok"}
WAIT
FAS
```

### Examples

| Server text | Outcome |
|---|---|
| `HUMAN` | `HUMAN` / `HUMAN` |
| `MACHINE` | `MACHINE` / `MACHINE` |
| `AMD` | `MACHINE` / `AMD` |
| `AMD_DETECTED` | `MACHINE` / `AMD_DETECTED` |
| `{"status":"HUMAN"}` | `HUMAN` / `HUMAN` |
| `{"result":"MACHINE","confidence":0.97}` | `MACHINE` / `{"result":"MACHINE","confidence":0.97}` |
| `result: HUMAN` | `HUMAN` / `HUMAN` |
| `NOT_HUMAN` | `HUMAN` / `HUMAN` (substring match, same as `amd.py`) |
| `AMDY ack` | ack (the `AMDY` guard) |
| `amd`, `human` | ack (case-sensitive, same as `amd.py`) |
| `FAS`, `OK`, `WAIT`, `{}` | ack |

The raw text of the last frame received is stored, sanitised to printable
ASCII and cut at 255 characters, in `${AMDRESPONSE}`.

### Fragmented, large and control frames

- Fragmented TEXT frames are reassembled until the final fragment before being
  classified.
- Result sizes are not limited to 255 bytes; only the stored `AMDRESPONSE` /
  `AMDCAUSE` copies are cut. **Keep replies small anyway** (well under one
  TCP segment, ~1400 bytes): once a frame has started to arrive,
  `res_http_websocket` waits for the rest of it on the channel thread, up to
  10 s if the remainder never comes (see
  [troubleshooting.md, Known limitations](troubleshooting.md#4-known-limitations)).
- Two frames that arrive together (one TCP segment, or one TLS record over
  `wss://`) are both read in the same iteration.
- PING frames are answered by `res_http_websocket` itself.
- A CLOSE frame, a read or write error, or a malformed frame before any result
  ends the call with `HUMAN` / `PROCESSING_ERROR` (`amd.py`: "Network/processing
  error - defaulting to HUMAN").

## 5. EOF finalisation ("NO AUDIO DATA" marks)

`amd.py` (July 2026) asks the server for a verdict early when the callee's
audio stops after some was sent. The module does the same:

- A schedule mark at which **nothing** has been captured since the previous
  send counts one towards `no_audio_streak`; any captured frame resets the
  streak to 0. Digital silence is audio (frames arrive, the streak stays 0);
  only a channel that delivers no frames at all counts — RTP silence
  suppression on the trunk, a carrier that stops sending RTP, a Local leg
  without a generator.
- When the streak reaches `eof_no_audio_streak` (default 2; `0` disables the
  feature) **and** at least one audio chunk was sent earlier, the module sends
  TEXT `{"eof":1}` and waits up to `eof_wait_ms` (default 3000 ms) for one
  TEXT reply, still servicing the channel (a hangup during the wait is
  `HANGUP` / `HANGUP`).
- The reply is classified with the rule above: `HUMAN` → `HUMAN` / `HUMAN`;
  `MACHINE`/`AMD` → `MACHINE` / `<reply>`; anything else → `NOTSURE` /
  `EOF_INCONCLUSIVE`; no reply within `eof_wait_ms`, or a send/receive error →
  `NOTSURE` / `EOF_ERROR`.
- Nothing is sent at an empty mark before the streak is reached; the server
  sees no frame and sends no ack for it.

Example: the callee says "hello?" for 1.2 s, then the carrier suppresses
silence and no more RTP arrives.

```text
 t = 0        first audio frame
 t = 500      BINARY 8000 B   (0-500 ms)          --->
                                                   <---  TEXT ack
 t = 1000     BINARY 8000 B   (500-1000 ms)       --->
                                                   <---  TEXT ack
 t = 1500     BINARY 3200 B   (1000-1200 ms)      --->
                                                   <---  TEXT ack
 t = 2000     mark, nothing captured: streak = 1   (nothing sent)
 t = 3000     mark, nothing captured: streak = 2
              TEXT {"eof":1}                       --->
              (wait <= 3000 ms for one reply)
                                                   <---  TEXT "HUMAN"
              AMDSTATUS=HUMAN AMDCAUSE=HUMAN
              TEXT {"eof":1}   (exit path, as amd.py's cleanup does)  --->
              CLOSE 1000                           --->
```

Had the server answered `ack` (or anything without `HUMAN`/`AMD`/`MACHINE`)
the call would end `NOTSURE` / `EOF_INCONCLUSIVE`; had it stayed silent for
3 s, `NOTSURE` / `EOF_ERROR`.

If the audio never stops, the streak never reaches 2 and the finalisation
never runs; the call ends with a result, `SERVER_TIMEOUT` at `timeout_ms`, or
`HANGUP`. If the channel delivered no audio at all, nothing was ever sent and
the finalisation is not attempted: the call ends `NOTSURE` /
`NOAUDIODATA-<ms>` at `timeout_ms`.

## 6. End of call (client → server)

On every exit path, if the connection is up:

1. TEXT `{"eof":1}` (best effort, non-blocking) — also after an EOF
   finalisation that already sent one, as `amd.py`'s `cleanup_websocket` does.
2. WebSocket CLOSE with status code `1000`.
3. The socket is released. The WebSocket descriptor is never left open.

A server therefore sees a clean `1000` close for finished, timed-out and hung-up
calls alike, and an abnormal close (`1006`) only if Asterisk itself died.

## 7. Timeouts

| Phase | Bound |
|---|---|
| Connect | `connect_timeout_ms` (10000 ms) from the moment the connect job starts (after answer / format setup) → `HUMAN` / `CONNECTION_ERROR`; the optional DB lookup runs inside this window; cut earlier if the detection window ends first |
| Detection | `timeout_ms` (10000 ms) from the first captured audio frame (from application start while no frame has arrived) → `NOTSURE` / `SERVER_TIMEOUT` if audio was sent, `NOTSURE` / `NOAUDIODATA-<ms>` if none was ever captured |
| Result grace | after `timeout_ms` without a result the remaining accumulated audio is sent and the client waits up to `result_grace_ms` for a reply, still detecting hangup; default `0` because `amd.py` returns at `MAX_WAIT_TIME` without waiting; audio arriving during the grace period is no longer accumulated |
| EOF finalisation | `eof_wait_ms` (3000 ms) for one reply after `{"eof":1}` → `NOTSURE` / `EOF_ERROR` |
| Hangup | detected at any point, including during the connect and the EOF wait; playback stopped, `{"eof":1}` + CLOSE, no grace wait; `HANGUP` / `HANGUP` |

Time spent in `AMD_WS()` is therefore at most about *(time until the first
audio frame) + `timeout_ms` + `result_grace_ms`*; the connect runs **inside**
that window and is cut at `connect_timeout_ms` (`CONNECTION_ERROR`), it does
not add to it. The module does not bound the wait for the first frame beyond
`timeout_ms` (`NOAUDIODATA-<ms>` at `timeout_ms` from application start).

## 8. `AMDSTATS`

Set on every exit as four integers joined by `-`:

```text
AMDSTATS=<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>
```

`elapsed_ms` is `AMDELAPSED` (from the first captured frame, or from the
application start when none was captured); `audio_ms_sent` is the sent audio
expressed in milliseconds (8 kHz 16-bit mono = 16 bytes per millisecond).
Stock `AMD()` sets a `-`-joined integer list in the same
variable and `VD_amd.agi` stores everything before the first `-` as
`run_time` in `vicidial_amd_log`, so the first field is the elapsed time in
both cases. `amd.py` put the server's reply text there, and only on `HUMAN`.

## Differences from `amd.py` (July 2026)

What goes on the wire is the same (same config frame incl. `caller_id`, same
schedule and fallback sends, same `{"eof":1}` finalisation and cleanup, same
result words). The only byte-level differences are in the config frame's
JSON encoding: `amd.py`'s `json.dumps` writes
`{"config": {"sample_rate": 8000, "VID": "..."}}` with a space after every
`:` and `,` and writes non-ASCII characters as `\uXXXX` escapes; the module
writes the compact form shown above and passes valid UTF-8 through (invalid
bytes become `?`). Any JSON parser reads both as the same document. Sends
larger than 16000 bytes are split into several frames (see section 3).
Behavioural differences:

| Aspect | `amd.py` (EAGI) | `AMD_WS()` |
|---|---|---|
| Waiting for the reply | blocks in `recv()` after every send; after the last mark polls 50 ms once a second when idle | never blocks; reads whenever the socket is readable, channel serviced with a bounded wait every iteration |
| Server stops replying altogether | the blocking `recv()` hits the 10 s socket timeout (`CONNECTION_TIMEOUT` doubles as the read timeout) → `HUMAN` / `PROCESSING_ERROR`, 10 s after the send that got no answer (10.5-19 s into the call) | `NOTSURE` / `SERVER_TIMEOUT` at `timeout_ms` (10 s), as `amd.py` reports a server that acknowledges but never classifies; no `AMD()` fallback line fires for it |
| DB configuration missing | file unreadable or without `VARDB_` lines: "DB ERROR: no config", no lookup | identical (one NOTICE at load/reload, `amd_ws show settings` says so) |
| Result matching | `'HUMAN' in text`, then `'AMD' in text or 'MACHINE' in text` | identical, plus the `AMDY` guard |
| Detection window anchor | its audio loop start | the first captured audio frame |
| Grace after the window | none | `result_grace_ms`, default 0 |
| End of audio stream / hangup | `NOAUDIO` / `NOAUDIO` | `HANGUP` / `HANGUP` (stock `AMD()` and `VD_amd.agi` vocabulary; see [migration-v1-to-v2.md](migration-v1-to-v2.md#why-two-values-follow-stock-amd-instead-of-amdpy)) |
| Window elapsed, no audio ever | `NOTSURE` / its own no-audio cause (listed in the migration table) | `NOTSURE` / `NOAUDIODATA-<ms>` (stock `AMD()` shape, so `VD_amd.agi`'s `ADAIR` handling applies) |
| Connect timeout | `CONNECTION_TIMEOUT = 10` s, fixed | `connect_timeout_ms` (10000), tunable per call with `c(ms)` |
| DB lookup | a new MySQL connection per call, 2 s connect timeout, runs before the WebSocket connect | one persistent connection, `db_timeout_ms`, on the connect helper thread |
| `AMDSTATS` | the reply text, on `HUMAN` only | `<elapsed_ms>-<audio_ms_sent>-<chunks_sent>-<bytes_sent>` on every exit |
| Extra output | — | `AMDRESPONSE`, `AMDELAPSED` on every exit |
| Close | `{"eof":1}` then `close()` | `{"eof":1}` then CLOSE `1000` |

See also: [architecture.md](architecture.md), [troubleshooting.md](troubleshooting.md).
