#!/usr/bin/env python3
# kernels.py: runs the firmware's built-in compute programs (fw/cp/programs)
# on tools/gsi1model.py and checks their results against Python: the copies
# of 1-byte stencil values to and from D24_UNORM_S8_UINT texels (a 7 x 5
# region, buffer rows of 8 bytes, image rows of 32 bytes).  Prints "PASS
# kernels.<name>" per program and "PASS kernels"; exit status 1 on a
# failure.  The model's files go to build/fw-host/k/.  A few seconds.
#   python3 -I fw/cp/tests/kernels.py
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..')
OUT = os.path.join(ROOT, 'build', 'fw-host', 'k')
BASE = 0x8000
WIDTH, HEIGHT, BROW, IROW = 7, 5, 8, 32
BUF, IMG = 0x100, 0x400


def run(name, words):
    data = os.path.join(OUT, name + '.dat')
    with open(data, 'w') as f:
        for w in words:
            f.write('%08x\n' % w)
    mem = os.path.join(OUT, name + '.mem')
    texels = WIDTH * HEIGHT
    groups = (texels + 63) // 64
    subprocess.run([sys.executable, '-I', os.path.join(ROOT, 'tools', 'gsi1model.py'),
                    os.path.join(ROOT, 'fw', 'cp', 'programs', name + '.s'), '--lanes', '64',
                    '--groups', str(groups), '--nregs', '64', '--data', data,
                    '-o', os.path.join(OUT, name + '.regs'), '--mem-out', mem],
                   check=True, timeout=120)
    with open(mem) as f:
        return [int(x, 16) for x in f.read().split()]


def main():
    os.makedirs(OUT, exist_ok=True)
    rnd = random.Random(5)
    bank = [WIDTH, WIDTH * HEIGHT, BASE + BUF, BROW, BASE + IMG, IROW, 0, 0]
    words = [0] * 4096
    words[:8] = bank
    for i in range(BUF // 4, BUF // 4 + 64):
        words[i] = rnd.getrandbits(32)
    for i in range(IMG // 4, IMG // 4 + 64):
        words[i] = rnd.getrandbits(32)
    fails = 0

    # To the image: each texel's byte 3 is the buffer's byte, bytes 0-2 stay.
    mem = run('s8_to_image', words)
    want = list(words)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            b = BUF + y * BROW + x
            s = (words[b // 4] >> (8 * (b % 4))) & 0xFF
            t = (IMG + y * IROW + 4 * x) // 4
            want[t] = (words[t] & 0xFFFFFF) | s << 24
    if mem != want:
        fails += 1
        print('FAIL kernels.s8_to_image')
    else:
        print('PASS kernels.s8_to_image')

    # From the image: each buffer byte of the region is the texel's byte 3, the others stay.
    mem = run('s8_from_image', words)
    want = list(words)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            b = BUF + y * BROW + x
            t = (IMG + y * IROW + 4 * x) // 4
            s = words[t] >> 24
            want[b // 4] = (want[b // 4] & ~(0xFF << (8 * (b % 4)))) | s << (8 * (b % 4))
    if mem != want:
        fails += 1
        print('FAIL kernels.s8_from_image')
    else:
        print('PASS kernels.s8_from_image')

    if fails:
        print('FAIL kernels')
        return 1
    print('PASS kernels')
    return 0


if __name__ == '__main__':
    sys.exit(main())
