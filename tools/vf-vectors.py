#!/usr/bin/env python3
# vf-vectors.py: writes the expected-value file of the atg_vf_conv unit
# testbench (sim/vec/vf_conv.txt) from the reference conversion below
# (design §2.3 ATTR_DESC formats, spec/gpu/vf/atg_vf_conv.md).  The file
# is in git; run this after changing the model or the cases, and check
# that `git diff sim/vec` shows only what was meant.
#   python3 -I tools/vf-vectors.py
# Format: "B n" starts a batch of n attributes (distinct k, sent back to
# back, the last with af_last), then n lines
#   kind k fmt dst lane raw nwords word...
# kind F (formats) or L (fill), raw 32 hex digits (byte 0 last), the words
# in order (register ATTR_DST[5:0] + c).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')

NCOMP = {0: 1, 1: 2, 2: 3, 3: 4, 4: 4, 5: 4, 6: 2, 7: 4, 8: 1, 9: 2}
SIZE = {0: 4, 1: 8, 2: 12, 3: 16, 4: 4, 5: 4, 6: 4, 7: 8, 8: 4, 9: 8}
INT = (5, 8, 9)
HALVES = [0x0000, 0x8000, 0x0001, 0x8001, 0x03FF, 0x0200, 0x0400, 0x3C00, 0x7BFF,
          0xFBFF, 0x7C00, 0xFC00, 0x7E00, 0x7C01, 0xFE00, 0x3555, 0x0155]


def f32(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def h2f(h):
    if (h >> 10) & 0x1F == 0x1F and h & 0x3FF:
        return 0x7FC00000
    return f32(struct.unpack('<e', struct.pack('<H', h))[0])


def unorm8(b):
    # b / 255 rounded to fp32; the double is never on an fp32 midpoint.
    return f32(b / 255.0)


def words(fmt, dst, raw):
    if dst == 0:
        return []
    out = []
    n = NCOMP.get(fmt, 0)
    for c in range((dst >> 6) + 1):
        if c >= n:
            w = (1 if fmt in INT else 0x3F800000) if c == 3 else 0
        elif fmt == 4:
            w = unorm8((raw >> (8 * c)) & 0xFF)
        elif fmt == 5:
            w = (raw >> (8 * c)) & 0xFF
        elif fmt in (6, 7):
            w = h2f((raw >> (16 * c)) & 0xFFFF)
        else:
            w = (raw >> (32 * c)) & 0xFFFFFFFF
        out.append(w)
    return out


def rand_raw(r, fmt, ub):
    raw = r.getrandbits(128)
    if fmt in (6, 7) and r.random() < 0.6:
        raw = 0
        for c in range(8):
            raw |= (r.choice(HALVES) if r.random() < 0.5 else r.getrandbits(16)) << (16 * c)
    if fmt == 4 and ub:
        raw = (raw & ~0xFFFFFFFF) | ub.pop(0) | ub.pop(0) << 8 | ub.pop(0) << 16 | ub.pop(0) << 24
    return raw


def main():
    r = random.Random(288009)
    ub = list(range(256))
    r.shuffle(ub)
    cases = []
    # formats: every format, ATTR_DST count = the format's components
    for fmt in range(10):
        for _ in range(64 if fmt == 4 else 24):
            n = NCOMP[fmt]
            dst = ((n - 1) << 6) | r.randrange(1, 64)
            cases.append(('F', fmt, dst, rand_raw(r, fmt, ub)))
    # formats: fewer words than components, and disabled attributes
    for _ in range(40):
        fmt = r.randrange(10)
        dst = r.randrange(0, 4) << 6 | r.randrange(64)
        if r.random() < 0.15:
            dst = 0
        cases.append(('F', fmt, dst, rand_raw(r, fmt, ub)))
    # fill: more ATTR_DST components than the format has (and reserved formats)
    for _ in range(120):
        fmt = r.choice([0, 1, 2, 6, 8, 9, 0, 6, 8, 9, 10, 15])
        n = NCOMP.get(fmt, 0)
        dst = (r.randrange(n, 4) << 6) | r.randrange(1, 64) if n < 4 else (3 << 6) | 1
        cases.append(('L', fmt, dst, rand_raw(r, fmt, ub)))
    assert not ub
    r.shuffle(cases)
    # the formats cases first, then fill (the testbench reports each part)
    cases = [c for c in cases if c[0] == 'F'] + [c for c in cases if c[0] == 'L']
    lines = []
    i = 0
    while i < len(cases):
        kind = cases[i][0]
        n = 1 + r.randrange(16)
        batch = [c for c in cases[i:i + n] if c[0] == kind]
        i += len(batch)
        ks = r.sample(range(16), len(batch))
        lines.append('B %d' % len(batch))
        for (kd, fmt, dst, raw), k in zip(batch, ks):
            ws = words(fmt, dst, raw)
            lines.append('%s %x %x %02x %02x %032x %d%s' % (
                kd, k, fmt, dst, r.randrange(32), raw, len(ws),
                ''.join(' %08x' % w for w in ws)))
    os.makedirs(VEC, exist_ok=True)
    with open(os.path.join(VEC, 'vf_conv.txt'), 'w') as fp:
        for ln in lines:
            fp.write(ln + '\n')
    print('vf-vectors: vf_conv.txt (%d lines)' % len(lines))


if __name__ == '__main__':
    main()
