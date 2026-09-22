#!/usr/bin/env python3
"""Mock amdy.io AMD WebSocket server for the app_amd_ws test harness.

Protocol (mirrors /home/na/amd.py, the production EAGI client):
  client -> TEXT   {"config":{"sample_rate":8000,"VID":"..."[,"phone":..][,"country_code":..]}}
  client -> BINARY audio chunks (slin 8 kHz), one per schedule mark
  server -> TEXT   one reply per binary chunk: an ack or a RESULT
  client -> TEXT   {"eof":1}, then close(1000)

Behaviour is selected by the URL path (+ query string).  The module under test
always connects to "/", so when the path is "/" the server reads the *control
file* (--control FILE) and uses its first line as the effective path.  That is
how test/run.sh switches behaviour between scenarios.

Named paths (query parameters override the preset):
  /human?after=N     N acks, then "HUMAN" as the reply to chunk N+1 (default after=2)
  /machine           ... "MACHINE"            /amd        ... "AMD"
  /honeypot          ... "HONEYPOT"           /status?value=FAS  any token
  /json              result {"status":"HUMAN"} (status=... to change)
  /amdy              acks are "AMDY ack" (must NOT classify), result later
  /nothuman          ack "NOT_HUMAN", then "MACHINE"
  /silent            never replies (records everything)
  /slow?handshake=MS delays the HTTP upgrade by MS milliseconds
  /reject            refuses the upgrade with HTTP 403
  /close?after=N     server closes (code 1011) after N chunks, no result
  /big               result padded to 5 KB ("xxxx... HUMAN")
  /fragmented        result sent as several WebSocket fragments
  /ping?after=N      sends a WS ping before every reply, result after N acks
  /delay?reply=MS    every reply is delayed by MS ms (reading must not block audio)

Generic parameters usable on any path:
  after=N ack=TEXT status=TEXT json=1 pad=BYTES frag=N close=N closecode=C
  ping=1 handshake=MS reply=MS

Recording: one JSON object per line in --record FILE.  Connection records have
"event":"connection" and carry: vid, path, effective, t_connect (epoch ms),
config (parsed) / config_raw, chunks [{t, bytes}] (t = ms since connect),
total_bytes, eof, close_code, close_reason, texts (all text frames), replies,
result_sent, t_result, t_close, error.  Handshake-only events ("event":
"handshake") are written for delayed/rejected upgrades.

Usage:
  mock_amd_server.py [--host 127.0.0.1] [--port 0] [--record FILE] [--control FILE]
                     [--default /human?after=2] [--port-file FILE] [--ping-interval S] [-v]
With --port 0 the bound port is printed to stdout as "MOCK_PORT=<n>" (and to
--port-file) once the server is listening.
"""
import argparse
import asyncio
import json
import os
import signal
import ssl
import sys
import time
from http import HTTPStatus
from urllib.parse import parse_qs, urlsplit

import websockets

DEFAULT_PATH = "/human?after=2"

PRESETS = {
    "/human": {"status": "HUMAN"},
    "/machine": {"status": "MACHINE"},
    "/amd": {"status": "AMD"},
    "/honeypot": {"status": "HONEYPOT"},
    "/status": {"status": "HUMAN"},           # value=... overrides
    "/json": {"status": "HUMAN", "json": "1"},
    "/amdy": {"status": "HUMAN", "ack": "AMDY ack", "after": "3"},
    "/nothuman": {"status": "MACHINE", "ack": "NOT_HUMAN"},
    "/silent": {"silent": "1"},
    "/slow": {"handshake": "3000", "status": "HUMAN"},
    "/reject": {"reject": "1"},
    "/close": {"close": "2", "closecode": "1011"},
    "/big": {"status": "HUMAN", "pad": "5000"},
    "/fragmented": {"status": "HUMAN", "json": "1", "frag": "3"},
    "/ping": {"status": "HUMAN", "ping": "1"},
    "/delay": {"status": "HUMAN", "reply": "300"},
}

ARGS = None
RECORD_FH = None
LOG_FH = sys.stderr
T0 = time.monotonic()


def log(msg):
    if ARGS and ARGS.verbose:
        LOG_FH.write("[mock %8.3f] %s\n" % (time.monotonic() - T0, msg))
        LOG_FH.flush()


def record(obj):
    line = json.dumps(obj, separators=(",", ":"))
    if RECORD_FH:
        RECORD_FH.write(line + "\n")
        RECORD_FH.flush()
        os.fsync(RECORD_FH.fileno())
    log("record " + line[:200])


def read_control():
    """Return the effective path from the control file, or the default."""
    if ARGS.control:
        try:
            with open(ARGS.control) as fh:
                first = fh.readline().strip()
            if first:
                return first
        except OSError:
            pass
    return ARGS.default


def resolve(path):
    """Map a request path to (effective_path, behaviour dict)."""
    effective = path
    if urlsplit(path).path in ("", "/"):
        effective = read_control()
    parts = urlsplit(effective)
    beh = dict(PRESETS.get(parts.path, {"status": "HUMAN"}))
    for k, v in parse_qs(parts.query, keep_blank_values=True).items():
        beh[k] = v[-1]
    if parts.path == "/status" and "value" in beh:
        beh["status"] = beh["value"]
    beh.setdefault("after", "2")
    beh.setdefault("ack", "{}")
    return effective, beh


def build_result(beh):
    status = beh.get("status", "HUMAN")
    if beh.get("json"):
        text = json.dumps({"status": status, "confidence": 0.97, "engine": "mock"})
    else:
        text = status
    pad = int(beh.get("pad", "0") or 0)
    if pad > 0:
        # padding first so that a truncating reader misses the token
        text = ("x" * pad) + " " + text
    return text


async def process_request(path, request_headers):
    """Runs before the upgrade: implements /slow (delayed handshake) and /reject."""
    effective, beh = resolve(path)
    delay = int(beh.get("handshake", "0") or 0)
    if delay:
        log("handshake %s delayed %d ms" % (effective, delay))
        record({"event": "handshake", "path": path, "effective": effective,
                "delay_ms": delay, "t_wall": int(time.time() * 1000)})
        await asyncio.sleep(delay / 1000.0)
    if beh.get("reject"):
        record({"event": "handshake", "path": path, "effective": effective,
                "rejected": 403, "t_wall": int(time.time() * 1000)})
        return (HTTPStatus.FORBIDDEN, [("Content-Type", "text/plain")], b"rejected by mock\n")
    return None


async def handler(ws):
    t_conn = time.monotonic()
    path = getattr(ws, "path", "/")
    effective, beh = resolve(path)
    rec = {
        "event": "connection",
        "vid": None,
        "path": path,
        "effective": effective,
        "remote": list(ws.remote_address) if ws.remote_address else None,
        "t_connect": int(time.time() * 1000),
        "config": None,
        "config_raw": None,
        "t_config": None,
        "chunks": [],
        "total_bytes": 0,
        "texts": [],
        "replies": [],
        "eof": False,
        "t_eof": None,
        "result_sent": None,
        "t_result": None,
        "server_closed": False,
        "close_code": None,
        "close_reason": None,
        "t_close": None,
        "error": None,
    }
    ms = lambda: int((time.monotonic() - t_conn) * 1000)  # noqa: E731
    after = int(beh.get("after", "2") or 0)
    ack_text = beh.get("ack", "{}")
    silent = bool(beh.get("silent"))
    close_after = int(beh.get("close", "0") or 0)
    close_code = int(beh.get("closecode", "1011") or 1011)
    frag = int(beh.get("frag", "0") or 0)
    do_ping = bool(beh.get("ping"))
    reply_delay = int(beh.get("reply", "0") or 0)
    result_text = build_result(beh)
    nchunks = 0
    log("connection %s -> %s beh=%s" % (rec["remote"], effective, beh))

    pending = []   # delayed replies run as tasks so the receive loop keeps consuming eof/close

    async def send_reply(text):
        if do_ping:
            try:
                await ws.ping()
            except Exception:  # noqa: BLE001
                pass
        if frag > 1 and text is result_text:
            n = max(1, len(text) // frag)
            pieces = [text[i:i + n] for i in range(0, len(text), n)]
            await ws.send(pieces)
        else:
            await ws.send(text)
        rec["replies"].append({"t": ms(), "text": text if len(text) <= 300 else text[:60] + "...(%d bytes)" % len(text)})

    async def delayed_reply(text):
        await asyncio.sleep(reply_delay / 1000.0)
        try:
            await send_reply(text)
        except websockets.exceptions.ConnectionClosed:
            log("delayed reply dropped: client already closed")

    async def reply(text):
        # /delay: the reply is late but the server must keep READING meanwhile (a real server
        # does); sleeping inline would miss the client's eof/close and mis-record the session
        if reply_delay:
            pending.append(asyncio.ensure_future(delayed_reply(text)))
        else:
            await send_reply(text)

    try:
        async for msg in ws:
            if isinstance(msg, (bytes, bytearray)):
                nchunks += 1
                rec["chunks"].append({"t": ms(), "bytes": len(msg)})
                rec["total_bytes"] += len(msg)
                if silent:
                    continue
                if close_after and nchunks >= close_after:
                    rec["server_closed"] = True
                    log("closing after %d chunks code=%d" % (nchunks, close_code))
                    await ws.close(code=close_code, reason="mock close mid-stream")
                    break
                if rec["result_sent"] is None and nchunks > after:
                    await reply(result_text)
                    rec["result_sent"] = result_text if len(result_text) <= 300 else result_text[-40:]
                    rec["t_result"] = ms()
                elif rec["result_sent"] is None:
                    await reply(ack_text)
                else:
                    # audio after a result: keep acking, never re-classify
                    await reply(ack_text)
            else:
                text = msg
                rec["texts"].append({"t": ms(), "text": text[:300]})
                parsed = None
                try:
                    parsed = json.loads(text)
                except ValueError:
                    parsed = None
                if isinstance(parsed, dict) and "config" in parsed and rec["config"] is None:
                    rec["config"] = parsed
                    rec["config_raw"] = text
                    rec["t_config"] = ms()
                    cfg = parsed.get("config") or {}
                    if isinstance(cfg, dict):
                        rec["vid"] = cfg.get("VID")
                    log("config vid=%s raw=%s" % (rec["vid"], text))
                elif isinstance(parsed, dict) and "eof" in parsed:
                    rec["eof"] = True
                    rec["t_eof"] = ms()
                    log("eof")
                else:
                    log("unexpected text: %r" % text[:80])
    except websockets.exceptions.ConnectionClosed as exc:
        rec["error"] = "closed: %s" % exc
    except Exception as exc:  # noqa: BLE001
        rec["error"] = "%s: %s" % (type(exc).__name__, exc)
    finally:
        for t in pending:
            try:
                await t
            except Exception:  # noqa: BLE001
                pass
        try:
            await ws.wait_closed()
        except Exception:  # noqa: BLE001
            pass
        rec["close_code"] = ws.close_code
        rec["close_reason"] = ws.close_reason
        rec["t_close"] = ms()
        record(rec)


async def main_async():
    global RECORD_FH
    if ARGS.record:
        RECORD_FH = open(ARGS.record, "a")
    stop = asyncio.get_running_loop().create_future()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: (not stop.done()) and stop.set_result(None))
    kwargs = dict(
        process_request=process_request,
        ping_interval=ARGS.ping_interval,
        ping_timeout=None,
        max_size=4 * 1024 * 1024,
        close_timeout=2,
    )
    if ARGS.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(ARGS.tls_cert, ARGS.tls_key or ARGS.tls_cert)
        kwargs["ssl"] = ctx
    async with websockets.serve(handler, ARGS.host, ARGS.port, **kwargs) as server:
        port = server.sockets[0].getsockname()[1]
        if ARGS.port_file:
            with open(ARGS.port_file + ".tmp", "w") as fh:
                fh.write("%d\n" % port)
            os.replace(ARGS.port_file + ".tmp", ARGS.port_file)
        sys.stdout.write("MOCK_PORT=%d\n" % port)
        sys.stdout.flush()
        log("listening on %s:%d (%s) record=%s control=%s default=%s"
            % (ARGS.host, port, "wss" if ARGS.tls_cert else "ws", ARGS.record, ARGS.control, ARGS.default))
        await stop
    if RECORD_FH:
        RECORD_FH.close()


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = pick a free port and print it")
    ap.add_argument("--record", help="JSON-lines file for per-connection records")
    ap.add_argument("--control", help="file whose first line is the effective path for requests to '/'")
    ap.add_argument("--default", default=DEFAULT_PATH, help="effective path when no control file/line")
    ap.add_argument("--port-file", help="also write the bound port to this file")
    ap.add_argument("--tls-cert", help="serve wss:// with this PEM certificate (chain)")
    ap.add_argument("--tls-key", help="PEM private key for --tls-cert (default: in the cert file)")
    ap.add_argument("--ping-interval", type=float, default=None,
                    help="server keepalive ping interval in s (default: none)")
    ap.add_argument("-v", "--verbose", action="store_true")
    ARGS = ap.parse_args()
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
