#!/usr/bin/env python3
"""Classification parity test: the module's rule against amd.py's rule.

The production EAGI client (amd.py, Jul 2026, gw.724care.com/amdy.tar.gz) decides
with two substring tests, in this order (amd.py:291-305, 418-428, 460-468):

    if 'HUMAN' in response:                          -> HUMAN
    elif 'AMD' in response or 'MACHINE' in response: -> MACHINE
    else:                                            -> ack, keep going

app_amd_ws.c (classify_text) re-implements that rule byte for byte, with ONE
documented guard: an "AMD" immediately followed by "Y" is the brand name in
acks such as "AMDY ack" and does not count.  amd.py would classify "AMDY ack"
as MACHINE; the module keeps going.

This file runs a table of server replies through BOTH rules and fails when they
disagree anywhere except on that guard.  Pure python, no Asterisk needed; run
by test/run.sh (row "classify_parity") and by hand:

    python3 test/classify_test.py [-v]
"""
import sys

# ---------------------------------------------------------------------------
# amd.py's rule, copied verbatim (process_audio_chunk, amd.py:291-305)
# ---------------------------------------------------------------------------


def amd_py_classify(response):
    if 'HUMAN' in response:
        return "HUMAN"
    elif 'AMD' in response or 'MACHINE' in response:
        return "MACHINE"
    return None   # "Continue processing for inconclusive responses"


# ---------------------------------------------------------------------------
# the module's rule (app_amd_ws.c classify_text): amd.py + the AMDY guard
# ---------------------------------------------------------------------------


def module_classify(text):
    if "HUMAN" in text:
        return "HUMAN"
    pos = 0
    while True:
        pos = text.find("AMD", pos)
        if pos < 0:
            break
        if pos + 3 >= len(text) or text[pos + 3] != "Y":
            return "MACHINE"
        pos += 3
    if "MACHINE" in text:
        return "MACHINE"
    return None


# (reply, expected module result, note); the amd.py result is computed, never hard-coded
TABLE = [
    ("HUMAN", "HUMAN", "plain"),
    ("MACHINE", "MACHINE", "plain"),
    ("AMD", "MACHINE", "amd.py: 'AMD' in text"),
    ("AMD_DETECTED", "MACHINE", "substring"),
    ("MACHINE_DETECTED", "MACHINE", "substring"),
    ("amd", None, "case-sensitive: lowercase is an ack"),
    ("human", None, "case-sensitive: lowercase is an ack"),
    ("Machine", None, "case-sensitive"),
    ("NOT_HUMAN", "HUMAN", "substring: HUMAN wins, exactly like amd.py (documented)"),
    ("HUMANOID", "HUMAN", "substring"),
    ("HUMAN MACHINE", "HUMAN", "HUMAN is tested first"),
    ("MACHINE HUMAN", "HUMAN", "HUMAN is tested first, position does not matter"),
    ('{"status": "HUMAN", "confidence": 0.97}', "HUMAN", "JSON reply"),
    ('{"status": "MACHINE", "confidence": 0.97, "engine": "mock"}', "MACHINE", "JSON reply -> AMDCAUSE is this text"),
    ('{"result":"AMD"}', "MACHINE", "JSON reply"),
    ("{}", None, "ack"),
    ("", None, "empty ack"),
    ("ack", None, "ack"),
    ("OK", None, "ack"),
    ("WAIT", None, "ack"),
    ("HONEYPOT", None, "not passed through any more: an ack for amd.py and the module"),
    ("FAS", None, "ack"),
    ("FASAMD", "MACHINE", "substring: AMD inside"),
    ("AUDIO", None, "ack"),
    ("NOTSURE", None, "ack (the server cannot make the module say NOTSURE)"),
    ("AMDY ack", None, "GUARD: the brand name does not count (amd.py says MACHINE)"),
    ("AMDY", None, "GUARD"),
    ("AMDY AMD", "MACHINE", "GUARD only skips the AMD followed by Y; the second AMD counts"),
    ("amdy AMD", "MACHINE", "lowercase brand, real token"),
    ("AMDYHUMAN", "HUMAN", "HUMAN first"),
    ("xxxxxxxx HUMAN", "HUMAN", "padded reply (big_result)"),
    ("PROCESSING", None, "ack"),
]

GUARD_CASES = {"AMDY ack", "AMDY"}   # where the module deliberately differs from amd.py


def main():
    verbose = "-v" in sys.argv[1:]
    fails = 0
    agree = 0
    documented = 0
    for text, expected, note in TABLE:
        got_py = amd_py_classify(text)
        got_mod = module_classify(text)
        line = "%-62r amd.py=%-8s module=%-8s %s" % (text, got_py, got_mod, note)
        if got_mod != expected:
            print("FAIL (module != expected %r): %s" % (expected, line))
            fails += 1
            continue
        if got_py == got_mod:
            agree += 1
            if verbose:
                print("ok   " + line)
        elif text in GUARD_CASES and got_py == "MACHINE" and got_mod is None:
            documented += 1
            if verbose:
                print("ok*  " + line + "  [documented AMDY guard]")
        else:
            print("FAIL (undocumented disagreement): " + line)
            fails += 1
    print("classify_test: %d replies, %d agree with amd.py, %d differ only by the documented AMDY guard, %d failures"
          % (len(TABLE), agree, documented, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
