#!/usr/bin/env python3
"""Probe for RFCOMM response desync after a headphone reconnect.

Sends GETs to known addresses and prints the address each response actually
carries. If a response carries a different (fblock, func) than the request,
the stream is out of step and pybmap would parse it with the wrong parser.

Run it, then disconnect and reconnect the headphones while it loops.
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vendor"))

import pybmap  # noqa: E402
from pybmap.protocol import bmap_packet, parse_response  # noqa: E402
from pybmap.constants import OP_GET  # noqa: E402

# (label, fblock, func) for reads that exist on the QC45.
PROBES = [
    ("battery", 2, 2),
    ("firmware", 0, 5),
    ("name", 1, 2),
]

DURATION = int(os.environ.get("PROBE_SECONDS", "240"))


def main():
    print("connecting...", flush=True)
    conn = pybmap.connect()
    print("connected. Disconnect and reconnect the headphones now.", flush=True)
    print("%-9s %-8s %-8s %-4s %s" % ("LABEL", "ASKED", "GOT", "OP", "PAYLOAD"), flush=True)

    deadline = time.time() + DURATION
    mismatches = 0

    while time.time() < deadline:
        for label, fblock, func in PROBES:
            stamp = time.strftime("%H:%M:%S")
            try:
                raw = conn._transport.send_recv(bmap_packet(fblock, func, OP_GET))
            except Exception as exc:
                print("%s %-9s SEND FAILED: %s: %s"
                      % (stamp, label, type(exc).__name__, exc), flush=True)
                continue

            parsed = parse_response(raw)
            if parsed is None:
                print("%s %-9s short response: %s" % (stamp, label, raw.hex()), flush=True)
                continue

            asked = "%d.%d" % (fblock, func)
            got = "%d.%d" % (parsed.fblock, parsed.func)
            flag = ""
            if (parsed.fblock, parsed.func) != (fblock, func):
                mismatches += 1
                flag = "  <== MISMATCH"

            print("%s %-9s %-8s %-8s %-4s %s%s"
                  % (stamp, label, asked, got, parsed.op,
                     parsed.payload.hex()[:40], flag), flush=True)
        time.sleep(2)

    print("done. mismatches: %d" % mismatches, flush=True)
    conn.close()


if __name__ == "__main__":
    main()
