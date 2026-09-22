#!/usr/bin/env python3
"""Pure-python assertions over mock_amd_server.py recordings (JSON lines).

Reusable from test/run.sh and by hand:

  protocol_test.py --record test/run/mock/record.jsonl --vid 0003_human \
      --checks config,schedule,bytes,eof,close [--expect-chunks 4] [--phone N] [--country C]

Checks (comma list, default: config,schedule,bytes,eof,close):
  config    exactly one connection for the VID; config JSON is the first text
            frame and has the shape {"config":{"sample_rate":8000,"VID":vid[,"phone"][,"country_code"]}}
            with no other keys; --phone/--country assert their presence/value,
            --no-phone asserts absence.
  schedule  chunk k arrives at t_config + schedule[k] +/- tol (default schedule
            500,1000,1500,2000,3000,4000, tol 150 ms); chunks after the last mark
            are >= chunk-bytes (8000) and spaced by about chunk-bytes/16 ms.
  bytes     every chunk carries ~16 B/ms of audio for its interval (+/- max(10 %,
            2 frames)) and the total is ~16000 B/s * covered duration (+/- 10 %).
  eof       the client sent {"eof":1} as its last text frame.
  close     close code == --close-code (default 1000) and the record has no error.
  chunks    exactly --expect-chunks binary chunks (or --min-chunks / --max-chunks).
  result    the mock did send a result (result_sent non-empty).
  noresult  the mock did NOT send a result.

Exit status 0 when all requested checks pass, 1 otherwise; prints one line per
check ("PASS <check>: detail" / "FAIL <check>: detail").  --json prints a JSON
summary instead.  Library use: load_records(), find_vid(), run_checks().
"""
import argparse
import json
import sys

DEFAULT_SCHEDULE = [500, 1000, 1500, 2000, 3000, 4000]
BYTES_PER_MS = 16          # 8000 Hz * 2 bytes / 1000
FRAME_BYTES = 320          # 20 ms frame


def load_records(path):
    recs = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                recs.append(json.loads(line))
            except ValueError:
                continue
    return recs


def find_vid(recs, vid):
    return [r for r in recs if r.get("event") == "connection" and r.get("vid") == vid]


def _first_text(rec):
    texts = rec.get("texts") or []
    return texts[0]["text"] if texts else None


def check_config(rec, vid, phone=None, country=None, no_phone=False):
    cfg = rec.get("config")
    if not isinstance(cfg, dict) or set(cfg.keys()) != {"config"}:
        return False, "top-level keys %r, expected exactly {'config'} (raw=%r)" % (
            sorted(cfg.keys()) if isinstance(cfg, dict) else cfg, rec.get("config_raw"))
    inner = cfg["config"]
    if not isinstance(inner, dict):
        return False, "config is not an object: %r" % (inner,)
    allowed = {"sample_rate", "VID", "phone", "country_code"}
    extra = set(inner.keys()) - allowed
    if extra:
        return False, "unexpected keys %s" % sorted(extra)
    if inner.get("sample_rate") != 8000:
        return False, "sample_rate=%r, expected 8000 (int)" % (inner.get("sample_rate"),)
    if inner.get("VID") != vid:
        return False, "VID=%r, expected %r" % (inner.get("VID"), vid)
    if no_phone and ("phone" in inner or "country_code" in inner):
        return False, "phone/country_code present but not expected: %r" % (inner,)
    if phone is not None and str(inner.get("phone")) != str(phone):
        return False, "phone=%r, expected %r" % (inner.get("phone"), phone)
    if country is not None and str(inner.get("country_code")) != str(country):
        return False, "country_code=%r, expected %r" % (inner.get("country_code"), country)
    first = _first_text(rec)
    if first != rec.get("config_raw"):
        return False, "config JSON was not the first text frame (first=%r)" % (first,)
    if rec.get("t_config") is None:
        return False, "no t_config"
    return True, "shape ok: %s" % rec.get("config_raw")


def check_schedule(rec, schedule, tol_ms, chunk_bytes):
    chunks = rec.get("chunks") or []
    t0 = rec.get("t_config")
    if t0 is None:
        return False, "no config frame, cannot anchor schedule"
    if not chunks:
        return False, "no chunks received"
    problems = []
    details = []
    for k, ch in enumerate(chunks):
        rel = ch["t"] - t0
        if k < len(schedule):
            exp = schedule[k]
            details.append("#%d@%d(%+d)" % (k + 1, rel, rel - exp))
            if abs(rel - exp) > tol_ms:
                problems.append("chunk %d at %d ms, expected %d +/- %d" % (k + 1, rel, exp, tol_ms))
        else:
            gap = ch["t"] - chunks[k - 1]["t"]
            exp_gap = chunk_bytes / BYTES_PER_MS
            details.append("#%d@%d(gap %d)" % (k + 1, rel, gap))
            if ch["bytes"] < chunk_bytes:
                problems.append("post-schedule chunk %d has %d B < chunk_bytes %d" % (k + 1, ch["bytes"], chunk_bytes))
            if abs(gap - exp_gap) > tol_ms + 40:
                problems.append("post-schedule chunk %d gap %d ms, expected ~%d" % (k + 1, gap, exp_gap))
    if problems:
        return False, "; ".join(problems) + " [" + " ".join(details) + "]"
    return True, "chunks at " + " ".join(details) + " ms after config"


def check_bytes(rec, schedule, tol_frac, chunk_bytes):
    chunks = rec.get("chunks") or []
    if not chunks:
        return False, "no chunks"
    problems = []
    prev_mark = 0
    covered = 0
    for k, ch in enumerate(chunks):
        if k < len(schedule):
            interval = schedule[k] - prev_mark
            prev_mark = schedule[k]
            exp = interval * BYTES_PER_MS
            covered += interval
        else:
            exp = chunk_bytes
            covered += chunk_bytes / BYTES_PER_MS
        tol = max(exp * tol_frac, 2 * FRAME_BYTES)
        # the very first chunk may include the frames captured before the schedule clock started
        if k == 0:
            tol += 2 * FRAME_BYTES
        if abs(ch["bytes"] - exp) > tol:
            problems.append("chunk %d: %d B, expected %d +/- %d" % (k + 1, ch["bytes"], exp, int(tol)))
    total = rec.get("total_bytes", 0)
    exp_total = covered * BYTES_PER_MS
    if abs(total - exp_total) > max(exp_total * tol_frac, 4 * FRAME_BYTES):
        problems.append("total %d B, expected ~%d (+/-10%%) for %d ms" % (total, int(exp_total), int(covered)))
    if problems:
        return False, "; ".join(problems)
    return True, "total %d B for ~%d ms of audio (%.0f B/s)" % (total, covered, total * 1000.0 / covered if covered else 0)


def check_eof(rec):
    texts = rec.get("texts") or []
    if not rec.get("eof"):
        return False, "no {\"eof\":1} seen (texts=%r)" % ([t["text"][:40] for t in texts],)
    last = texts[-1]["text"] if texts else None
    try:
        obj = json.loads(last)
    except (TypeError, ValueError):
        obj = None
    if not (isinstance(obj, dict) and "eof" in obj):
        return False, "eof was not the last text frame (last=%r)" % (last,)
    return True, "eof at %d ms" % rec.get("t_eof", -1)


def check_close(rec, code):
    if rec.get("close_code") != code:
        return False, "close_code=%r reason=%r error=%r, expected %d" % (
            rec.get("close_code"), rec.get("close_reason"), rec.get("error"), code)
    if code == 1000 and rec.get("error"):
        return False, "close code ok but connection error recorded: %r" % (rec.get("error"),)
    return True, "close %d at %d ms%s" % (code, rec.get("t_close", -1),
                                          " (%s)" % rec["error"] if rec.get("error") else "")


def check_chunks(rec, expect=None, min_chunks=None, max_chunks=None):
    n = len(rec.get("chunks") or [])
    if expect is not None and n != expect:
        return False, "%d chunks, expected %d" % (n, expect)
    if min_chunks is not None and n < min_chunks:
        return False, "%d chunks, expected >= %d" % (n, min_chunks)
    if max_chunks is not None and n > max_chunks:
        return False, "%d chunks, expected <= %d" % (n, max_chunks)
    return True, "%d chunks" % n


def run_checks(recs, vid, checks, *, schedule=DEFAULT_SCHEDULE, tol_ms=150, bytes_tol=0.10,
               chunk_bytes=8000, close_code=1000, phone=None, country=None, no_phone=False,
               expect_chunks=None, min_chunks=None, max_chunks=None):
    results = []
    mine = find_vid(recs, vid)
    if len(mine) != 1:
        results.append(("connection", False, "%d connection records for vid %r, expected 1" % (len(mine), vid)))
        return results
    rec = mine[0]
    for c in checks:
        if c == "config":
            ok, d = check_config(rec, vid, phone=phone, country=country, no_phone=no_phone)
        elif c == "schedule":
            ok, d = check_schedule(rec, schedule, tol_ms, chunk_bytes)
        elif c == "bytes":
            ok, d = check_bytes(rec, schedule, bytes_tol, chunk_bytes)
        elif c == "eof":
            ok, d = check_eof(rec)
        elif c == "close":
            ok, d = check_close(rec, close_code)
        elif c == "chunks":
            ok, d = check_chunks(rec, expect_chunks, min_chunks, max_chunks)
        elif c == "result":
            ok, d = (bool(rec.get("result_sent")), "result_sent=%r at %s ms" % (rec.get("result_sent"), rec.get("t_result")))
        elif c == "noresult":
            ok, d = (not rec.get("result_sent"), "result_sent=%r" % (rec.get("result_sent"),))
        else:
            ok, d = False, "unknown check %r" % c
        results.append((c, ok, d))
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--record", required=True)
    ap.add_argument("--vid", required=True)
    ap.add_argument("--checks", default="config,schedule,bytes,eof,close")
    ap.add_argument("--schedule", default=",".join(str(x) for x in DEFAULT_SCHEDULE))
    ap.add_argument("--tol-ms", type=int, default=150)
    ap.add_argument("--bytes-tol", type=float, default=0.10)
    ap.add_argument("--chunk-bytes", type=int, default=8000)
    ap.add_argument("--close-code", type=int, default=1000)
    ap.add_argument("--phone")
    ap.add_argument("--country")
    ap.add_argument("--no-phone", action="store_true")
    ap.add_argument("--expect-chunks", type=int)
    ap.add_argument("--min-chunks", type=int)
    ap.add_argument("--max-chunks", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    schedule = [int(x) for x in a.schedule.split(",") if x]
    checks = [c for c in a.checks.split(",") if c]
    recs = load_records(a.record)
    results = run_checks(recs, a.vid, checks, schedule=schedule, tol_ms=a.tol_ms, bytes_tol=a.bytes_tol,
                         chunk_bytes=a.chunk_bytes, close_code=a.close_code, phone=a.phone,
                         country=a.country, no_phone=a.no_phone, expect_chunks=a.expect_chunks,
                         min_chunks=a.min_chunks, max_chunks=a.max_chunks)
    ok_all = all(ok for _, ok, _ in results)
    if a.json:
        print(json.dumps({"vid": a.vid, "ok": ok_all,
                          "checks": [{"check": c, "ok": ok, "detail": d} for c, ok, d in results]}))
    else:
        for c, ok, d in results:
            print("%s %s: %s" % ("PASS" if ok else "FAIL", c, d))
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
