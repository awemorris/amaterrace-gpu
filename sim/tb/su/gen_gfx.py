#!/usr/bin/env python3
# Writes the warps of the SU graphics test (sim/tb/atg_su_gfx_tb.v,
# gfx.s): gen_gfx.py WARPS INIT.
#   WARPS: 5 words per slot 0..3 (tools/gsi1model.py --warps): slot 0 a
#     vertex warp (EXEC = mask = a random subset of lanes 0..27), slots 1-3
#     fragment warps of 8, 3 and 5 quads with sequence numbers 1, 0, 2
#     (EXEC = whole quads, mask = a random non-empty coverage per quad,
#     some quads partly covered: helper lanes).
#   INIT: the registers written before the start (the -o format of
#     gsi1model.py, NREGS 32): vertex r0-r5 of lanes 0..27 random floats;
#     fragment r0-r5 of the quads' lanes: b0, b1, b2, z in [0, 1) and
#     x + 0.5, y + 0.5 (lane l of a quad at (qx + l[0], qy + l[1]), qx, qy
#     even, below 64).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import random
import struct
import sys

NREGS = 32


def f32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def main(wpath, ipath):
    rnd = random.Random(288)
    regs = [[[None] * 32 for _ in range(NREGS)] for _ in range(4)]
    warps = []
    # Slot 0: the vertex warp.
    vm = 0
    while bin(vm).count("1") < 12:
        vm = rnd.getrandbits(28)
    warps.append((0, vm, vm, 0, 0))
    for ln in range(28):
        for n in range(6):
            regs[0][n][ln] = f32(rnd.uniform(-4.0, 4.0))
    # Slots 1-3: fragment warps.
    for k, (nq, seq) in enumerate([(8, 1), (3, 0), (5, 2)], start=1):
        cov = 0
        for q in range(nq):
            c = rnd.choice([15, 15, 1, 2, 4, 8, 3, 5, 6, 9, 10, 12, 7, 11, 13, 14])
            if q == 0:
                c = 6            # a partly covered quad in every warp
            cov |= c << (4 * q)
            qx, qy = 2 * rnd.randrange(32), 2 * rnd.randrange(32)
            for i in range(4):
                ln = 4 * q + i
                for n in range(4):
                    regs[k][n][ln] = f32(rnd.random())
                regs[k][4][ln] = f32(qx + (i & 1) + 0.5)
                regs[k][5][ln] = f32(qy + (i >> 1) + 0.5)
        # r6, the RX's sample mask (its own random stream: the other values
        # stay as they were); 0 in some lanes (not exported).
        r6r = random.Random(2880 + k)
        for ln in range(4 * nq):
            regs[k][6][ln] = r6r.choice([0, 1, 3, 5, 6, 8, 9, 10, 12, 15, 15, 15])
        ex = (1 << (4 * nq)) - 1 if nq < 8 else 0xFFFFFFFF
        warps.append((1, ex, cov, seq, rnd.getrandbits(1)))
    with open(wpath, "w") as f:
        for w in warps:
            for v in w:
                f.write("%08x\n" % v)
    with open(ipath, "w") as f:
        for k in range(4):
            for n in range(NREGS):
                for ln in range(32):
                    v = regs[k][n][ln]
                    f.write("000000000\n" if v is None else "1%08x\n" % v)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
