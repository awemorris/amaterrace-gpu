#!/usr/bin/env python3
# Writes the data image of an SU test program (gen_data.py NAME OUT): 4096
# words at 0x8000 for $readmemh, the first 256 also the constant bank.
#   mem, sub: random integers;
#   vadd, reduce: random integers in the first 256 words, fp32 values in
#           [-100, 100) from word 256 (0x8400) on;
#   others: zeros.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import random
import struct
import sys


def main(name, out):
    rnd = random.Random(sum(map(ord, name)))
    w = [0] * 4096
    if name in ("mem", "sub", "vadd", "reduce"):
        for i in range(4096):
            w[i] = rnd.getrandbits(32)
    if name in ("vadd", "reduce"):
        for i in range(256, 4096):
            w[i] = struct.unpack("<I", struct.pack("<f", rnd.uniform(-100, 100)))[0]
    with open(out, "w") as f:
        for v in w:
            f.write("%08x\n" % v)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
