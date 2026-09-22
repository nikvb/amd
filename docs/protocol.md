# Wire protocol

This is the protocol `AMD_WS()` speaks to the AMD service. It is the same
protocol as the production EAGI client `amd.py`; where the two differ in
*behaviour* (not in bytes on the wire) the difference is called out.

Transport: one WebSocket connection per call. Text frames carry JSON or plain
tokens; binary frames carry raw audio. Nothing else is sent.

## Sequence

```text
 Asterisk (AMD_WS)                                     AMD server
 ------------------                                    ----------
 TCP connect + HTTP Upgrade  GET / (ws:// or wss://)  --->
                                                       <---  101 Switching Protocols
 TEXT  {"config":{"sample_rate":8000,"VID":"..."}}     --->
                                                       <---  TEXT ack            (optional)
 (first audio frame read from the channel: t = 0)
 BINARY  audio accumulated during 0-500 ms             --->   at t = 500 ms
                                                       <---  TEXT ack
 BINARY  audio 500-1000 ms                             --->   at t = 1000 ms
                                                       <---  TEXT ack
 BINARY  audio 1000-1500 ms                            --->   at t = 1500 ms
                                                       <---  TEXT ack
 BINARY  audio 1500-2000 ms                            --->   at t = 2000 ms
                                                       <---  TEXT ack
 BINARY  audio 2000-3000 ms                            --->   at t = 3000 ms
                                                       <---  TEXT "HUMAN"        (result)
 TEXT  {"eof":1}                                       --->
 CLOSE 1000                                            --->
                                                       <---  CLOSE 1000
```

If no result arrives, sending continues at t = 4000 ms and then every time
`chunk_bytes` (8000 B = 500 ms) have accumulated, until `timeout_ms`.

## 1. Connection

- URL: `ws://<host>:<port>/` (path `/`), or `wss://` with option `s` /
  `tls=yes`.
- No WebSocket subprotocol is required. The client does not fail if the server
  echoes none.
- The connect (DNS, TCP, TLS, HTTP upgrade) is bounded by `connect_timeout_ms`
  (default 2000 ms; option `c(ms)`). A failure or timeout ends the call with
  `AMDSTATUS=NOTSURE`, `AMDCAUSE=NETERR`.

## 2. Config frame (client → server, TEXT)

Sent once, immediately after the upgrade.

Minimal form (no phone enrichment):

```json
{"config":{"sample_rate":8000,"VID":"V9211234560000123"}}
```

With ViciDial enrichment (from the DB lookup or the `p()` / `k()` options):

```json
{"config":{"sample_rate":8000,"VID":"V9211234560000123","phone":"3125551212","country_code":"1"}}
```

Rules:

| Field | Value |
|---|---|
| `sample_rate` | Always `8000`. |
| `VID` | The `vid` argument, else the channel's caller id name, else `Unknown`. |
| `phone` | Digits from `vicidial_auto_calls.phone_number` or `p(...)`. Omitted when unknown. |
| `country_code` | `vicidial_auto_calls.phone_code` or `k(...)`. Omitted when unknown. |

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
  connect.
- At each mark in `send_schedule` (default `500,1000,1500,2000,3000,4000` ms)
  everything accumulated since the previous send goes out as one binary frame.
- After the last mark, a frame is sent whenever at least `chunk_bytes`
  (default 8000) have accumulated.
- A `send_schedule` with a single value (for example `500`) means plain
  fixed-interval chunks of that length.

Expected frame sizes with the defaults and continuous 20 ms audio:

| Sent at | Contains | Bytes |
|---|---|---|
| 500 ms | 0-500 ms | ~8000 |
| 1000 ms | 500-1000 ms | ~8000 |
| 1500 ms | 1000-1500 ms | ~8000 |
| 2000 ms | 1500-2000 ms | ~8000 |
| 3000 ms | 2000-3000 ms | ~16000 |
| 4000 ms | 3000-4000 ms | ~16000 |
| afterwards | every 8000 B | 8000 |

Total throughput is 16000 B/s of audio plus WebSocket framing.

## 4. Server replies (server → client, TEXT)

After every binary frame the server sends one TEXT frame: either an
acknowledgement or a result. The client never blocks waiting for it; the
channel keeps being read and audio keeps being sent on schedule.

### Acknowledgements

Any text that contains no terminal status token. Examples the client treats
as "keep going":

```text
(empty frame)
{}
ack
AMDY ack
{"status":"ok"}
WAIT
```

### Results

Classification is done on **tokens**, never on substrings. The text is split on
every character outside `[A-Za-z0-9_]`, the tokens are uppercased, and the
first token that is a terminal status decides:

| First terminal token | `AMDSTATUS` | `AMDCAUSE` |
|---|---|---|
| `HUMAN` | `HUMAN` | `HUMAN` |
| `MACHINE` or `AMD` | `MACHINE` | `MACHINE` |
| any token listed in `extra_statuses` (default `HONEYPOT`, `FAS`, `FASAMD`, `AUDIO`, `NOTSURE`) | that token | that token |

If the text is JSON containing a `"status"`, `"result"` or `"classification"`
key, **only that key's value** is tokenised.

Examples:

| Server text | Outcome |
|---|---|
| `HUMAN` | `HUMAN` / `HUMAN` |
| `MACHINE` | `MACHINE` / `MACHINE` |
| `AMD` | `MACHINE` / `MACHINE` |
| `HONEYPOT` | `HONEYPOT` / `HONEYPOT` |
| `{"status":"HUMAN"}` | `HUMAN` / `HUMAN` |
| `{"result":"MACHINE","confidence":0.97}` | `MACHINE` / `MACHINE` |
| `{"classification":"fas","vid":"..."}` | `FAS` / `FAS` |
| `result: human` | `HUMAN` / `HUMAN` (token `HUMAN`) |
| `AMDY ack` | not a result (`AMDY` is not a terminal token) |
| `NOT_HUMAN` | not a result (`NOT_HUMAN` is one token) |
| `HUMANOID` | not a result |
| `{"error":"AMDY.IO: account suspended"}` | not a result |
| `OK`, `ACK`, `WAIT`, `{}` | not a result |

The raw text of the last frame received is stored, sanitised to printable
ASCII and cut at 255 characters, in `${AMDRESPONSE}`.

### Fragmented, large and control frames

- Fragmented TEXT frames are reassembled until the final fragment before being
  classified.
- Result sizes are not limited to 255 bytes; only the stored `AMDRESPONSE`
  copy is cut. **Keep replies small anyway** (well under one TCP segment,
  ~1400 bytes): once a frame has started to arrive, `res_http_websocket`
  waits for the rest of it on the channel thread, up to 10 s if the remainder
  never comes (see [troubleshooting.md, Known limitations](troubleshooting.md#4-known-limitations)).
  The token results are a few bytes; a JSON result with a long transcript
  should stay under that size.
- Two frames that arrive together (one TCP segment, or one TLS record over
  `wss://`) are both read in the same iteration.
- PING frames are answered by `res_http_websocket` itself.
- A CLOSE frame before any result ends the call with `NOTSURE` / `NETERR`.

## 5. End of call (client → server)

On every exit path, if the connection is up:

1. TEXT `{"eof":1}` (best effort, non-blocking).
2. WebSocket CLOSE with status code `1000`.
3. The socket is released. The WebSocket descriptor is never left open.

A server therefore sees a clean `1000` close for finished, timed-out and hung-up
calls alike, and an abnormal close (`1006`) only if Asterisk itself died.

## 6. Timeouts and the grace period

| Phase | Bound |
|---|---|
| Connect | `connect_timeout_ms` (2000 ms) from the moment the connect job starts (after answer / format setup) → `NETERR`; the optional DB lookup runs inside this window; cut earlier if the detection window ends first |
| Detection | `timeout_ms` (10000 ms) from the first captured audio frame (from application start while no frame has arrived) |
| Result grace | after `timeout_ms` without a result: the remaining accumulated audio is sent and the client waits up to `result_grace_ms` (1000 ms) for a reply, still detecting hangup; audio arriving during the grace period is no longer accumulated |
| Hangup | detected at any point, including during the connect; playback stopped, `{"eof":1}` + CLOSE, no grace wait; `HANGUP` / `HANGUP` |

If the grace period ends without a result: `AUDIO_TIMEOUT` when at least one
audio frame was captured, `NO_AUDIO_TIMEOUT` when none was. Time spent in
`AMD_WS()` is therefore about *(time until the first audio frame) +
`timeout_ms` + `result_grace_ms`*; the connect runs **inside** that window
and is cut at `connect_timeout_ms` (`NETERR`), it does not add to it. The
module does not bound the wait for the first frame beyond `timeout_ms`
(`NO_AUDIO_TIMEOUT` at `timeout_ms` from application start).

## Differences from `amd.py`

Bytes on the wire are identical (same config frame, same schedule, same
`{"eof":1}`). Behavioural differences:

| Aspect | `amd.py` (EAGI) | `AMD_WS()` |
|---|---|---|
| Waiting for the reply | blocks in `recv()` after every send | never blocks; channel is serviced with a bounded wait every iteration |
| Result matching | substring `'HUMAN' in text`, `'AMD' in text`, `'MACHINE' in text` | whole tokens only; JSON `status`/`result`/`classification` key honoured |
| Connection failure | `AMDSTATUS=HUMAN`, `AMDCAUSE=CONNECTION_ERROR` | `NOTSURE` / `NETERR` (the dialplan falls back to `AMD()`) |
| Processing error | `HUMAN` / `PROCESSING_ERROR` | `NOTSURE` / `NETERR` or `INTERR` |
| Hangup | `NOAUDIO` / `NOAUDIO` | `HANGUP` / `HANGUP` |
| Timeouts | `NOTSURE` / `AUDIO_TIMEOUT` or `NO_AUDIO_TIMEOUT` | same |
| Close | `{"eof":1}` then close | `{"eof":1}` then CLOSE `1000` |
| Extra output | `AMDSTATS` on HUMAN | `AMDRESPONSE`, `AMDELAPSED` on every exit |

See also: [architecture.md](architecture.md), [troubleshooting.md](troubleshooting.md).
