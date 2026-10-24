#!/usr/bin/env python3
# tu-vectors.py: writes the expected-value files of the atg_tu_addr and
# atg_tu_filter unit testbenches (sim/vec/tu_addr.txt, sim/vec/tu_filter.txt)
# from the reference model tools/tumodel.py.  The files are in git; run this
# after changing the model or the cases, and check that `git diff sim/vec`
# shows only what was meant.
#   python3 -I tools/tu-vectors.py
# tu_addr.txt lines:
#   S idx value                      STATE write (TU range)
#   Q op slot mask tag last coord addr wts ctl value   one quad (hex; coord
#                                    384 bits lane 0 in the low bits, addr 512,
#                                    wts 64, ctl 8, value 128)
#   P name                           end of the group (PASS atg_tu_addr.name)
# tu_filter.txt lines:
#   F texels wts mask ctl value tag last data   one quad (hex), P name as above.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tumodel as T  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')
S_TU = 0x090


def f32(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


SPECIAL = [0, 0x80000000, 1, 0x80000001, 0x007FFFFF, f32(1.0), f32(-1.0), f32(0.5),
           f32(-0.5), f32(2.0), 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC12345,
           f32(1e30), f32(-1e30), f32(1e-30), f32(0.9999999), f32(1.0000001), f32(3.0),
           f32(-3.0), f32(255.75), f32(65536.5), f32(-0.0000001)]


def pack(words, bits=32):
    v = 0
    for i, w in enumerate(words):
        v |= (w & ((1 << bits) - 1)) << (bits * i)
    return v


def rcoord(r):
    p = r.random()
    if p < 0.12:
        return r.choice(SPECIAL)
    if p < 0.2:
        return f32(r.randrange(-64, 64) / 16.0)
    return f32(r.uniform(-3.0, 3.0) * (2.0 ** r.randrange(-6, 2)))


def rdesc(r, tiled=None):
    """A random slot descriptor (16 words)."""
    w = r.choice([1, 2, 3, 4, 5, 7, 8, 16, 33, 64, 100, 256, 1000, 4096, 0, r.randrange(1, 70000)])
    h = r.choice([1, 2, 3, 4, 6, 8, 16, 31, 64, 128, 1024, 0, r.randrange(1, 70000)])
    w, h = min(w, 65535), min(h, 65535)
    samp = r.getrandbits(14)
    if tiled is not None:
        samp = (samp & ~(1 << 13)) | (tiled << 13)
    d = [r.getrandbits(32) & ~3, h << 16 | w, r.randrange(16), samp]
    d += [r.getrandbits(20) & ~3 for _ in range(12)]
    return d


def set_desc(out, slot, d):
    for k, v in enumerate(d):
        out.append('S %03x %08x' % (S_TU + 16 * slot + k, v))


def quad(out, r, op, slot, d, coords, mask):
    a, fu, fv, ctl, val = T.quad_addr(op, d, coords, mask)
    crd = pack([w for c in coords for w in c])
    addr = pack([x for l in range(4) for x in a[l]])
    wts = pack([fu[l] | fv[l] << 8 for l in range(4)], 16)
    tag = r.getrandbits(16)
    last = r.getrandbits(1)
    out.append('Q %x %x %x %04x %x %096x %0128x %016x %02x %032x' %
               (op, slot, mask, tag, last, crd, addr, wts, ctl, pack(val)))


def addr_vectors(r):
    out = []
    descs = {}
    # wrap: texl, texf and texsz on random descriptors (linear and tiled).
    for n in range(500):
        if n % 50 == 0:
            for s in range(16):
                descs[s] = rdesc(r, tiled=r.getrandbits(1) if n else 0)
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        op = r.choice([0, 0, 0, 0, 2, 3])
        coords = []
        for _ in range(4):
            if op == 0:
                lod = r.choice([rcoord(r), f32(r.uniform(-2, 14)), 0, f32(0.5), f32(0.50390625)])
                coords.append((rcoord(r), rcoord(r), lod))
            elif op == 2:
                coords.append((r.choice([r.randrange(-8, 80), r.getrandbits(32)]) & T.M32,
                               r.choice([r.randrange(-8, 80), r.getrandbits(32)]) & T.M32,
                               r.choice([r.randrange(-2, 15), r.getrandbits(32)]) & T.M32))
            else:
                coords.append((r.choice([r.randrange(0, 18), r.getrandbits(32)]),
                               r.getrandbits(32), r.getrandbits(32)))
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, 15, r.randrange(16)]))
    out.append('P wrap')
    # lod: texb quads with derivatives over 2^-14 .. 2^3 and random biases.
    for n in range(400):
        if n % 40 == 0:
            for s in range(16):
                d = rdesc(r, tiled=0)
                d[T.D_LEVELS] = r.choice([0, 1, 5, 9, 13, 14, 15, r.randrange(16)])
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        u0, v0 = r.uniform(-2, 2), r.uniform(-2, 2)
        sx = 2.0 ** r.uniform(-14, 3) * r.choice([1, -1])
        sy = 2.0 ** r.uniform(-14, 3) * r.choice([1, -1])
        dux, duy = sx * r.uniform(-1, 1), sy * r.uniform(-1, 1)
        dvx, dvy = sx * r.uniform(-1, 1), sy * r.uniform(-1, 1)
        if r.random() < 0.05:
            dux = duy = dvx = dvy = 0.0
        coords = []
        for ln in range(4):
            x, y = ln & 1, ln >> 1
            bias = r.choice([0, f32(r.uniform(-4, 4)), f32(r.uniform(-40, 40)), rcoord(r)])
            coords.append((f32(u0 + x * dux + y * duy), f32(v0 + x * dvx + y * dvy), bias))
        quad(out, r, 1, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]))
    out.append('P lod')
    # tile: 4x4 tiled levels, every op.
    for n in range(300):
        if n % 50 == 0:
            for s in range(16):
                descs[s] = rdesc(r, tiled=1)
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 2])
        coords = []
        for ln in range(4):
            if op == 2:
                coords.append((r.randrange(-4, 300) & T.M32, r.randrange(-4, 300) & T.M32,
                               r.randrange(-1, 14) & T.M32))
            else:
                coords.append((rcoord(r), rcoord(r), f32(r.uniform(-3, 13))))
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, r.randrange(16)]))
    out.append('P tile')
    return out


def filter_vectors(r):
    out = []

    def one(texels, fu, fv, mask, ctl, value):
        data = T.filt_quad(texels, fu, fv, ctl, mask, value)
        out.append('F %0128x %016x %x %02x %032x %04x %x %0128x' %
                   (pack([t for row in texels for t in row]),
                    pack([fu[l] | fv[l] << 8 for l in range(4)], 16), mask, ctl, pack(value),
                    r.getrandbits(16), r.getrandbits(1), pack(data)))
    # nearest: every byte value in every channel and format, texsz, masks.
    for n in range(64):
        tex = [[(4 * n + l) * 0x01010101 for _ in range(4)] for l in range(4)]
        one(tex, [r.getrandbits(8)] * 4, [r.getrandbits(8)] * 4, 15, r.choice([0, 2]), [0] * 4)
    for n in range(200):
        tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
        ctl = r.choice([0, 2, 4, 6, 8, 10]) | (r.getrandbits(4) << 4)
        one(tex, [r.getrandbits(8) for _ in range(4)], [r.getrandbits(8) for _ in range(4)],
            r.randrange(16), ctl, [r.getrandbits(32) for _ in range(4)])
    out.append('P nearest')
    for n in range(400):
        tex = [[r.choice([r.getrandbits(32), 0xFFFFFFFF, 0, 0x80808080]) for _ in range(4)]
               for _ in range(4)]
        fu = [r.choice([0, 255, 128, 1, r.getrandbits(8)]) for _ in range(4)]
        fv = [r.choice([0, 255, 128, 1, r.getrandbits(8)]) for _ in range(4)]
        one(tex, fu, fv, r.choice([15, 15, r.randrange(16)]), 1 | r.choice([0, 2]),
            [r.getrandbits(32) for _ in range(4)])
    out.append('P bilinear')
    return out


def main():
    r = random.Random(288009)
    # The filter's exactness for nearest texels: c << 16 is c / 255 rounded.
    for c in range(256):
        assert T.conv(c << 16) == f32(c / 255.0), c
    os.makedirs(VEC, exist_ok=True)
    for name, lines in (('tu_addr.txt', addr_vectors(r)), ('tu_filter.txt', filter_vectors(r))):
        with open(os.path.join(VEC, name), 'w') as fp:
            fp.write('\n'.join(lines) + '\n')
        print('tu-vectors: %d lines -> sim/vec/%s' % (len(lines), name))


if __name__ == '__main__':
    main()
