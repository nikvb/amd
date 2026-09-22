#!/usr/bin/env python3
"""A python client that mimics amd.py / app_amd_ws against mock_amd_server.py.

Used by test/run.sh --selftest to exercise every mock path without Asterisk,
and handy for debugging the mock by hand:

  mock_client.py --url ws://127.0.0.1:PORT/human?after=3 --vid selftest-1 --duration 4

Behaviour (as amd.py): connect, send the config JSON, generate 16000 B/s of
fake slin audio in --frame-ms frames, send everything accumulated at each
schedule mark (--schedule, default 500,1000,1500,2000,3000,4000 ms) and every
--chunk-bytes afterwards, wait (non-blocking) for one text reply per send,
classify with the token rule of the spec, and on exit send {"eof":1} and
close(1000).  --abort-after N drops the TCP connection after N chunks with no
close frame (the mock must record close_code 1006).  Prints one JSON summary.
"""
import argparse
import asyncio
import json
import re
import sys
import time

import websockets

TERMINAL = {"HUMAN": "HUMAN", "MACHINE": "MACHINE", "AMD": "MACHINE"}


def classify(text, extra):
    """Token rule from SPEC section 3.5."""
    body = text
    m = re.search(r'"(?:status|result|classification)"\s*:\s*"([^"]*)"', text)
    if m:
        body = m.group(1)
    for tok in re.split(r"[^A-Za-z0-9_]+", body):
        up = tok.upper()
        if not up:
            continue
        if up in TERMINAL:
            return TERMINAL[up]
        if up in extra:
            return up
    return None


async def run(a):
    schedule = [int(x) for x in a.schedule.split(",") if x]
    extra = set(x.upper() for x in a.extra.split(",") if x)
    out = {"vid": a.vid, "url": a.url, "status": None, "cause": None, "chunks": 0,
           "bytes": 0, "replies": [], "elapsed_ms": None, "error": None}
    t_start = time.monotonic()
    try:
        ws = await asyncio.wait_for(
            websockets.connect(a.url, open_timeout=a.connect_timeout / 1000.0,
                               ping_interval=None, max_size=4 * 1024 * 1024),
            timeout=a.connect_timeout / 1000.0 + 0.5)
    except Exception as exc:  # noqa: BLE001
        out.update(status="NOTSURE", cause="NETERR", error="connect: %s" % exc,
                   elapsed_ms=int((time.monotonic() - t_start) * 1000))
        print(json.dumps(out))
        return 0
    cfg = {"config": {"sample_rate": 8000, "VID": a.vid}}
    if a.phone:
        cfg["config"]["phone"] = a.phone
    if a.country:
        cfg["config"]["country_code"] = a.country
    await ws.send(json.dumps(cfg, separators=(",", ":")))

    frame_bytes = 16 * a.frame_ms
    acc = bytearray()
    sent_total = 0
    idx = 0
    t_first = time.monotonic()
    deadline = t_first + a.timeout / 1000.0
    pending_reply = None
    result = None
    aborted = False

    def elapsed_ms():
        return int((time.monotonic() - t_first) * 1000)

    async def poll_reply(budget):
        nonlocal result
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=budget)
        except asyncio.TimeoutError:
            return
        if isinstance(msg, bytes):
            return
        out["replies"].append({"t": elapsed_ms(), "text": msg if len(msg) < 200 else msg[:40] + "...(%d)" % len(msg)})
        c = classify(msg, extra)
        if c:
            result = c

    try:
        next_frame = t_first
        while result is None:
            now = time.monotonic()
            if now >= deadline:
                break
            # produce audio at real-time pace
            while next_frame <= now and not a.no_audio:
                acc.extend(b"\x10\x00" * (frame_bytes // 2))
                next_frame += a.frame_ms / 1000.0
            el = elapsed_ms()
            due = False
            if idx < len(schedule) and el >= schedule[idx]:
                due = True
                idx += 1
            elif idx >= len(schedule) and len(acc) >= a.chunk_bytes:
                due = True
            if due and acc:
                if a.abort_after and out["chunks"] >= a.abort_after:
                    aborted = True
                    ws.transport.abort()
                    break
                await ws.send(bytes(acc))
                out["chunks"] += 1
                sent_total += len(acc)
                acc = bytearray()
                pending_reply = time.monotonic()
            await poll_reply(0.02)
            if a.duration and elapsed_ms() >= a.duration * 1000:
                break
        if result is None and not aborted and sent_total and not a.no_grace:
            if acc:
                await ws.send(bytes(acc))
                out["chunks"] += 1
                sent_total += len(acc)
                acc = bytearray()
            g_end = time.monotonic() + a.grace / 1000.0
            while result is None and time.monotonic() < g_end:
                await poll_reply(0.02)
    except websockets.exceptions.ConnectionClosed as exc:
        out["error"] = "closed: %s" % exc
        result = None
        out.update(status="NOTSURE", cause="NETERR")
    out["bytes"] = sent_total
    out["elapsed_ms"] = elapsed_ms()
    if result:
        out.update(status=result, cause=result)
    elif out["status"] is None:
        if sent_total:
            out.update(status="NOTSURE", cause="AUDIO_TIMEOUT")
        else:
            out.update(status="NOTSURE", cause="NO_AUDIO_TIMEOUT")
    if not aborted:
        try:
            if not a.no_eof:
                await ws.send('{"eof":1}')
            await ws.close(code=1000)
        except Exception as exc:  # noqa: BLE001
            out["error"] = out["error"] or ("close: %s" % exc)
    print(json.dumps(out))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--vid", default="client-1")
    ap.add_argument("--phone")
    ap.add_argument("--country")
    ap.add_argument("--timeout", type=int, default=10000, help="detection window ms")
    ap.add_argument("--grace", type=int, default=1000, help="result grace ms after timeout")
    ap.add_argument("--connect-timeout", type=int, default=2000)
    ap.add_argument("--schedule", default="500,1000,1500,2000,3000,4000")
    ap.add_argument("--chunk-bytes", type=int, default=8000)
    ap.add_argument("--frame-ms", type=int, default=20)
    ap.add_argument("--duration", type=float, default=0, help="stop producing after N s (0 = until timeout)")
    ap.add_argument("--extra", default="HONEYPOT,FAS,FASAMD,AUDIO,NOTSURE")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--no-eof", action="store_true")
    ap.add_argument("--no-grace", action="store_true")
    ap.add_argument("--abort-after", type=int, default=0, help="drop TCP after N chunks (no close frame)")
    a = ap.parse_args()
    sys.exit(asyncio.run(run(a)))


if __name__ == "__main__":
    main()
