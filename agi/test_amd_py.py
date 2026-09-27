#!/usr/bin/env python3
"""
Unit tests for agi/amd.py (the EAGI client): the stock-Asterisk vocabulary
for no-audio, hangup and AMDSTATS, without Asterisk. Runs in < 5 s:

    python3 agi/test_amd_py.py

process_audio_stream() is driven with a pipe on fd 3 (EAGI audio), a fake
AGI object that records set_variable() calls and a fake WebSocket.
"""
import importlib.util
import os
import re
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load_amd():
    spec = importlib.util.spec_from_file_location("amd", os.path.join(HERE, "amd.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeAGI:
    def __init__(self):
        self.vars = {}
        self.log = []

    def set_variable(self, name, value):
        self.vars[name] = value

    def verbose(self, msg, level=1):
        self.log.append(msg)


class FakeWS:
    """Acks every binary chunk with `ack`, answers `result` on the Nth chunk."""

    def __init__(self, result="HUMAN", after=1, ack="ack", eof_reply=None):
        self.result, self.after, self.ack, self.eof_reply = result, after, ack, eof_reply
        self.sent_binary = []
        self.sent_text = []
        self._timeout = 10
        self._pending = []

    def send_binary(self, data):
        self.sent_binary.append(len(data))
        self._pending.append(self.result if len(self.sent_binary) >= self.after else self.ack)

    def send(self, text):
        self.sent_text.append(text)
        if '"eof"' in text and self.eof_reply is not None:
            self._pending.append(self.eof_reply)

    def recv(self):
        if self._pending:
            return self._pending.pop(0)
        raise TimeoutError("no reply")

    def settimeout(self, t):
        self._timeout = t

    def gettimeout(self):
        return self._timeout

    def close(self):
        pass


class Fd3:
    """Installs a pipe as fd 3 for the duration of a test."""

    def __enter__(self):
        r, self.w = os.pipe()
        self.saved = os.dup(3) if self._fd_open(3) else None
        if r != 3:                      # the pipe may already have landed on fd 3
            os.dup2(r, 3)
            os.close(r)
        return self

    def write(self, data):
        os.write(self.w, data)

    def close_write(self):
        if self.w is not None:
            os.close(self.w)
            self.w = None

    def __exit__(self, *a):
        self.close_write()
        if self.saved is not None:
            os.dup2(self.saved, 3)
            os.close(self.saved)
        else:
            os.close(3)

    @staticmethod
    def _fd_open(fd):
        try:
            os.fstat(fd)
            return True
        except OSError:
            return False


STATS_RE = re.compile(r"^\d+-\d+$")


class AmdPyStockVocabulary(unittest.TestCase):
    def setUp(self):
        self.amd = load_amd()
        self.amd.MAX_WAIT_TIME = 0.6           # keep the tests fast
        self.amd.SEND_TIMES = [0.2, 0.4]
        self.agi = FakeAGI()

    def run_stream(self, ws, feeder=None):
        with Fd3() as fd3:
            self.amd.setup_audio_stream()
            t = None
            if feeder:
                t = threading.Thread(target=feeder, args=(fd3,))
                t.start()
            self.amd.process_audio_stream(self.agi, ws, "Local/test", "VTEST")
            if t:
                t.join()
        return self.agi.vars

    def test_no_audio_is_stock_noaudiodata(self):
        v = self.run_stream(FakeWS())
        self.assertEqual(v["AMDSTATUS"], "NOTSURE")
        self.assertRegex(v["AMDCAUSE"], r"^NOAUDIODATA-\d+$")
        ms = int(v["AMDCAUSE"].split("-")[1])
        self.assertGreaterEqual(ms, 600)
        self.assertLess(ms, 1500)
        self.assertRegex(v["AMDSTATS"], STATS_RE)
        self.assertTrue(v["AMDSTATS"].endswith("-0"))     # no bytes received
        self.assertNotIn("AMDRESPONSE", v)
        # VD_amd.agi: AMDRESPONSE = AMDCAUSE with "-..." stripped -> "NOAUDIODATA"
        self.assertEqual(re.sub(r"-.*", "", v["AMDCAUSE"]), "NOAUDIODATA")

    def test_hangup_is_stock_hangup(self):
        def feeder(fd3):
            fd3.write(b"\x00" * 1600)       # 100 ms of audio
            time.sleep(0.1)
            fd3.close_write()               # channel hung up: FD3 EOF
        v = self.run_stream(FakeWS(result="ack", after=99), feeder)
        self.assertEqual(v["AMDSTATUS"], "HANGUP")
        self.assertEqual(v["AMDCAUSE"], "HANGUP")
        self.assertRegex(v["AMDSTATS"], STATS_RE)
        self.assertEqual(v["AMDSTATS"].split("-")[1], "1600")

    def test_human_result_keeps_numeric_stats_and_exports_response(self):
        def feeder(fd3):
            for _ in range(6):
                fd3.write(b"\x00" * 800)
                time.sleep(0.05)
            time.sleep(0.5)
            fd3.close_write()
        ws = FakeWS(result="HUMAN", after=1)
        v = self.run_stream(ws, feeder)
        self.assertEqual(v["AMDSTATUS"], "HUMAN")
        self.assertEqual(v["AMDCAUSE"], "HUMAN")
        self.assertRegex(v["AMDSTATS"], STATS_RE)          # was the word HUMAN before 2.2.1
        self.assertEqual(v["AMDRESPONSE"], "HUMAN")
        run_time = int(v["AMDSTATS"].split("-")[0])          # what VD_amd.agi stores as run_time
        self.assertGreater(run_time, 100)
        self.assertGreaterEqual(len(ws.sent_binary), 1)

    def test_machine_result_cause_is_raw_response(self):
        def feeder(fd3):
            for _ in range(6):
                fd3.write(b"\x00" * 800)
                time.sleep(0.05)
            time.sleep(0.5)
            fd3.close_write()
        v = self.run_stream(FakeWS(result="OTHERAMD-4.50-0.93", after=1), feeder)
        self.assertEqual(v["AMDSTATUS"], "MACHINE")
        self.assertEqual(v["AMDCAUSE"], "OTHERAMD-4.50-0.93")
        self.assertEqual(v["AMDRESPONSE"], "OTHERAMD-4.50-0.93")
        self.assertRegex(v["AMDSTATS"], STATS_RE)

    def test_config_json_shape_unchanged(self):
        # create_websocket_connection is not exercised (needs a socket); check the
        # builder's JSON contract by reading the constants that the server relies on.
        self.assertEqual(self.amd.SAMPLE_RATE, 8000)
        self.assertEqual(self.amd.FALLBACK_CHUNK_SIZE, 8000)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2).result.wasSuccessful() is False)
