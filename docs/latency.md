# Detection latency — where the seconds go

Measured on a ViciDial test dialer (Asterisk 18.21.0-vici) against the
production service `api.amdy.io:2700` with the trace option (`v`), 2026-09-23.

## The timeline of one call

```
+0ms     connecting to ws://api.amdy.io:2700
+60ms    connected, config sent                      ← connect + handshake
+1501ms  first audio frame                           ← far end answered / RTP arrived
+2002ms  sent chunk #1 (0.52 s audio)   → ack +57 ms
+2501ms  sent chunk #2 (1.02 s)         → ack +26 ms
+3001ms  sent chunk #3 (1.52 s)         → ack +25 ms
+3501ms  sent chunk #4 (2.02 s)         → ack +26 ms
+4502ms  sent chunk #5 (3.02 s)         → ack +302 ms
+5501ms  sent chunk #6 (4.02 s)         → ack +49 ms
+6501ms  sent chunk #7 (5.02 s audio)   → "AMD-4.50-0.9491" +50 ms   ← verdict
status=MACHINE cause=AMD-4.50-0.9491 elapsed=5049 sent=80320 chunks=7
```

`AMDELAPSED` (5049 ms) and the first field of `AMDSTATS` run from the **first
audio frame**, not from the start of the application; the connect (60 ms here)
and the wait for the far end's audio are not counted.

## What decides the moment of the verdict

The service (`amd_server`) strips leading silence and runs its cascade on
*speech* samples: AMD stages at 4k, 8k, … 32k samples, then the **greeting
model at 36 000 stripped samples = 4.50 s of speech**. The final verdict is
the greeting stage — that is the `4.50` in every `<CLASS>-4.50-<confidence>`
reply. 4.5 s of speech takes at least 5 s of wall-clock audio, and the chunk
that carries it leaves the dialer at the next schedule mark.

So the verdict cannot arrive before ~5 s after the first audio frame, whatever
the client does. Four live runs with the same audio:

| Client configuration | Verdict arrived | Reply |
|---|---|---|
| defaults (`amd.py` schedule 0.5,1,1.5,2,3,…,9 s) | after the 5.02 s chunk | `AMD-4.50-0.9491` |
| `send_schedule` every 0.5 s | after the 5.02 s chunk | `AMD-4.50-0.9491` |
| 0.5 s + `extra_config={"short_no_greeting":true}` | after the 5.02 s chunk | `AMD-5.02-0.9518` |
| 0.5 s + `short_no_greeting` + `detection_mode=aggressive` | after the 5.02 s chunk | `AMD-5.02-0.9441` |

The module's own contribution is the schedule granularity: audio between two
marks waits for the next mark — up to 1 s with the default schedule after the
2 s mark, up to 0.5 s with a 0.5 s cadence. The server acknowledges every
chunk in 25–300 ms and answers 50–360 ms after the chunk that satisfies it.

The production EAGI client `amd.py` shows the same figures (its verdict for a
real call also arrives right after send #7 at the 5.0 s threshold).

## What you can change

| Knob | Where | Effect |
|---|---|---|
| `send_schedule=500,1000,…,9000` (0.5 s steps) | `amd_ws.conf` | up to 0.5 s earlier on calls whose speech threshold falls between marks; twice the messages, same bytes |
| `extra_config={"short_no_greeting":true}` | `amd_ws.conf` | server finalises at the 32k stage (4.0 s of speech) instead of the 36k greeting stage: the reply becomes plain `AMD-<dur>-<conf>` instead of `NUMBERSAMD`/`OTHERAMD`/… (you lose *which* machine) |
| `extra_config={"detection_mode":"aggressive"}` | `amd_ws.conf` | server threshold profile: latency vs leak |
| `extra_config={"max_detection_time":8.0}` | `amd_ws.conf` | server wall-clock deadline in seconds |
| `timeout_ms` | dialplan / conf | client-side window; when it expires without a verdict: `NOTSURE` / `SERVER_TIMEOUT` |

Anything below ~5 s for the greeting verdict is a change on the service side
(stage minimums, silence handling), not in this module.

## Reading a slow call

1. Add `v` to the `AMD_WS()` options (or `trace=yes` in `amd_ws.conf`) and
   `grep 'AMD_WS:' /var/log/asterisk/messages` for that channel.
2. Large gap before `first audio frame` → the far end / RTP, not AMD.
3. `connected … after N ms` large → network to the service (or DNS); see
   `connect_timeout_ms`.
4. Acks that arrive late (> 500 ms) or verdict long after the chunk with
   enough audio → the service is slow; escalate with the VID.
5. Verdict right after a chunk, but that chunk was the first with ≥ 4.5 s of
   speech → expected behaviour (above).
