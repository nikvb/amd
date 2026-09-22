#!/usr/bin/env python3
"""Accept-and-never-reply TCP listener for the app_amd_ws test harness.

Models an AMD server whose kernel completes the TCP handshake and ACKs the
client's HTTP upgrade request but whose application never answers and never
closes (hung process, SIGSTOP, black-holing middlebox).  res_http_websocket
gives the handshake read no timeout, so the module's connect helper thread
stays parked until this process exits (the kernel then sends FIN).  The
harness uses it to prove:

  * AMD_WS() itself returns HUMAN/CONNECTION_ERROR at connect_timeout_ms (the PBX thread never
    waits for the helper),
  * 'amd_ws show settings' counts the parked helper under "connects in flight",
  * max_pending_connects makes further calls to that host fail fast,
  * killing the peer releases every parked helper (in flight -> 0).

Usage: blackhole_server.py [--host 127.0.0.1] [--port 0] [--port-file FILE]
With --port 0 the bound port is printed as "BLACKHOLE_PORT=<n>" (and written
to --port-file) once listening.  Accepted sockets are drained (so the client's
request is ACKed) and kept open until SIGTERM/SIGINT.
"""
import argparse
import os
import selectors
import signal
import socket
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(128)
    port = srv.getsockname()[1]
    if args.port_file:
        with open(args.port_file + ".tmp", "w") as fh:
            fh.write("%d\n" % port)
        os.replace(args.port_file + ".tmp", args.port_file)
    sys.stdout.write("BLACKHOLE_PORT=%d\n" % port)
    sys.stdout.flush()

    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.append(1))

    sel = selectors.DefaultSelector()
    sel.register(srv, selectors.EVENT_READ)
    clients = []
    while not stop:
        for key, _ in sel.select(timeout=0.5):
            if key.fileobj is srv:
                c, _addr = srv.accept()
                c.setblocking(False)
                clients.append(c)
                sel.register(c, selectors.EVENT_READ)
                sys.stderr.write("[blackhole] accepted #%d from %s:%d\n" % (len(clients), _addr[0], _addr[1]))
            else:
                try:
                    data = key.fileobj.recv(65536)   # drain: the request is ACKed, never answered
                except (BlockingIOError, InterruptedError):
                    continue
                except OSError:
                    data = b""
                if not data:                          # client gave up (it never does while we live)
                    sel.unregister(key.fileobj)
                    key.fileobj.close()
                    clients.remove(key.fileobj)
    sys.stderr.write("[blackhole] exiting, closing %d parked connection(s)\n" % len(clients))
    for c in clients:
        try:
            c.close()
        except OSError:
            pass
    srv.close()


if __name__ == "__main__":
    main()
