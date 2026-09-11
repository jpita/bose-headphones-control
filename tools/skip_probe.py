#!/usr/bin/env python3
"""Is a mismatched response a stale answer, or an unsolicited event?

If the device pushes asynchronous STATUS messages, the fix is to skip them
and keep reading until the requested address answers, not to raise.

Reads the raw socket after each request and prints every frame it sees.
"""

import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "vendor"))

import pybmap  # noqa: E402
from pybmap.protocol import bmap_packet, parse_all_responses  # noqa: E402
from pybmap.constants import OP_GET  # noqa: E402

PROBES = [("battery", 2, 2), ("firmware", 0, 5), ("name", 1, 2)]


def main():
    conn = pybmap.connect()
    print("connected on a fresh channel\n", flush=True)

    for label, fblock, func in PROBES:
        # drain=True collects everything the device sends, not just the first frame.
        raw = conn._transport.send_recv(
            bmap_packet(fblock, func, OP_GET), drain=True)
        frames = parse_all_responses(raw)
        print("asked %s [%d.%d] -> %d frame(s)" % (label, fblock, func, len(frames)))
        for f in frames:
            match = "MATCH" if (f.fblock, f.func) == (fblock, func) else "other"
            print("    [%d.%d] op=%d %-5s %s"
                  % (f.fblock, f.func, f.op, match, f.payload.hex()[:44]))
        print(flush=True)

    conn.close()


if __name__ == "__main__":
    main()
