#!/usr/bin/env python3
# tu-vectors.py: writes the expected-value files of the atg_tu_addr and
# atg_tu_filter unit testbenches (sim/vec/tu_addr.txt, sim/vec/tu_filter.txt)
# from the reference model tools/tumodel.py.  The files are in git; run this
# after changing the model or the cases, and check that `git diff sim/vec`
# shows only what was meant.
#   python3 -I tools/tu-vectors.py
# tu_addr.txt lines (hex):
#   S idx value                      STATE write (TU range)
#   Q op slot mask tag last coord n  one quad (coord 384 bits, lane 0 in the
#                                    low bits), then its n outputs (1, or 2
#                                    for mip linear filtering):
#   A addr wts ctl value             one ta_* output (addr 512, wts 96,
#                                    ctl 16, value 128)
#   P name                           end of the group (PASS atg_tu_addr.name)
# tu_filter.txt lines (hex):
#   H texels wts mask ctl value      a first pass of mip linear filtering
#                                    (no output: kept for the next quad)
#   F texels wts mask ctl value tag last data   one quad and its output
#   P name                           as above.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import struct
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as RX  # noqa: E402
import tumodel as T  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')
S_TU = 0x090


def f32(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


SPECIAL = [0, 0x80000000, 1, 0x80000001, 0x007FFFFF, f32(1.0), f32(-1.0), f32(0.5),
           f32(-0.5), f32(2.0), 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC12345,
           f32(1e30), f32(-1e30), f32(1e-30), f32(0.9999999), f32(1.0000001), f32(3.0),
           f32(-3.0), f32(255.75), f32(65536.5), f32(-0.0000001), f32(-2.0), f32(1.9999999),
           f32(-1.0000001)]


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


# SAMPLER bits other than mip linear, compare, depth and the border colour.
SAMP_BASIC = 0x303F


def rdesc(r, tiled=None, samp_mask=SAMP_BASIC, samp_set=0):
    """A random slot descriptor (16 words)."""
    w = r.choice([1, 2, 3, 4, 5, 7, 8, 16, 33, 64, 100, 256, 1000, 4096, 0, r.randrange(1, 70000)])
    h = r.choice([1, 2, 3, 4, 6, 8, 16, 31, 64, 128, 1024, 0, r.randrange(1, 70000)])
    w, h = min(w, 65535), min(h, 65535)
    samp = (r.getrandbits(19) & samp_mask) | samp_set
    if tiled is not None:
        samp = (samp & ~(1 << 13)) | (tiled << 13)
    d = [r.getrandbits(32) & ~3, h << 16 | w, r.randrange(16), samp]
    d += [r.getrandbits(20) & ~3 for _ in range(12)]
    return d


def set_desc(out, slot, d):
    for k, v in enumerate(d):
        out.append('S %03x %08x' % (S_TU + 16 * slot + k, v))


def quad(out, r, op, slot, d, coords, mask, stats):
    passes = T.quad_addr(op, d, coords, mask)
    crd = pack([w for c in coords for w in c])
    tag = r.getrandbits(16)
    last = r.getrandbits(1)
    out.append('Q %x %x %x %04x %x %096x %x' % (op, slot, mask, tag, last, crd, len(passes)))
    for a, wts, ctl, val in passes:
        out.append('A %0128x %024x %04x %032x' %
                   (pack([x for ln in range(4) for x in a[ln]]), pack(wts, 24), ctl, pack(val)))
        stats['border'] += sum(1 for ln in range(4) for x in a[ln] if x & 1 and mask >> ln & 1)
    stats['passes'] += len(passes)


def lod_coords(r, scale_lo=-14, scale_hi=3, third=None):
    """A quad's (u, v, third) with derivatives over 2^scale."""
    u0, v0 = r.uniform(-2, 2), r.uniform(-2, 2)
    sx = 2.0 ** r.uniform(scale_lo, scale_hi) * r.choice([1, -1])
    sy = 2.0 ** r.uniform(scale_lo, scale_hi) * r.choice([1, -1])
    dux, duy = sx * r.uniform(-1, 1), sy * r.uniform(-1, 1)
    dvx, dvy = sx * r.uniform(-1, 1), sy * r.uniform(-1, 1)
    if r.random() < 0.05:
        dux = duy = dvx = dvy = 0.0
    coords = []
    for ln in range(4):
        x, y = ln & 1, ln >> 1
        t = third(ln) if third else r.choice([0, f32(r.uniform(-4, 4)), f32(r.uniform(-40, 40)),
                                              rcoord(r)])
        coords.append((f32(u0 + x * dux + y * duy), f32(v0 + x * dvx + y * dvy), t))
    return coords


def addr_vectors(r):
    out = []
    descs = {}
    stats = {'border': 0, 'passes': 0}

    def new_descs(**kw):
        for s in range(16):
            descs[s] = rdesc(r, **kw)
            set_desc(out, s, descs[s])

    # wrap: texl, texf and texsz on random descriptors (linear and tiled).
    for n in range(500):
        if n % 50 == 0:
            new_descs(tiled=r.getrandbits(1) if n else 0)
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
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, 15, r.randrange(16)]),
             stats)
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
        quad(out, r, 1, slot, descs[slot], lod_coords(r), r.choice([15, 15, r.randrange(16)]),
             stats)
    out.append('P lod')
    # tile: 4x4 tiled levels, every op.
    for n in range(300):
        if n % 50 == 0:
            new_descs(tiled=1)
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 2])
        coords = []
        for ln in range(4):
            if op == 2:
                coords.append((r.randrange(-4, 300) & T.M32, r.randrange(-4, 300) & T.M32,
                               r.randrange(-1, 14) & T.M32))
            else:
                coords.append((rcoord(r), rcoord(r), f32(r.uniform(-3, 13))))
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, r.randrange(16)]), stats)
    out.append('P tile')
    # trilinear: mip linear on, texl lods across the levels, and texb.
    n2 = stats['passes']
    for n in range(400):
        if n % 40 == 0:
            for s in range(16):
                d = rdesc(r, samp_mask=SAMP_BASIC | 0x70000, samp_set=1 << T.SAMP_MIP_LIN)
                d[T.D_LEVELS] = r.choice([0, 1, 2, 5, 9, 13, 15, r.randrange(16)])
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        if r.getrandbits(1):
            coords = [(rcoord(r), rcoord(r),
                       r.choice([f32(r.uniform(-1, 14)), f32(r.randrange(-2, 15)),
                                 f32(r.randrange(0, 3584) / 256.0), rcoord(r)]))
                      for _ in range(4)]
            quad(out, r, 0, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats)
        else:
            quad(out, r, 1, slot, descs[slot], lod_coords(r, -10, 2),
                 r.choice([15, 15, r.randrange(16)]), stats)
    assert stats['passes'] - n2 > 500, stats
    out.append('P trilinear')
    # border: clamp to border on u, v or both, coordinates around [-1, 2].
    b0 = stats['border']

    def bc():
        return r.choice([f32(r.uniform(-1.5, 2.5)), f32(r.uniform(-0.1, 0.1)),
                         f32(r.uniform(0.9, 1.1)), rcoord(r)])
    for n in range(400):
        if n % 40 == 0:
            for s in range(16):
                d = rdesc(r, tiled=r.getrandbits(1), samp_mask=0x7737F)
                d[T.D_SAMPLER] |= r.choice([3, 12, 15, 15])
                d[T.D_SIZE] = (r.choice([1, 2, 3, 5, 8, 16, 100]) << 16 |
                               r.choice([1, 2, 4, 7, 16, 64]))
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        op = r.choice([0, 0, 0, 1])
        if op == 0:
            coords = [(bc(), bc(), r.choice([0, f32(r.uniform(-1, 6))])) for _ in range(4)]
        else:
            coords = lod_coords(r, -8, 1)
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats)
    assert stats['border'] - b0 > 300, stats
    out.append('P border')
    # compare: depth formats (D24, D32F) with and without compare, every op;
    # rs2 is the reference.
    for n in range(300):
        if n % 50 == 0:
            new_descs(tiled=r.getrandbits(1), samp_mask=0x737FF, samp_set=1 << T.SAMP_DEPTH)
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 1, 2, 3])
        if op in (0, 1):
            coords = lod_coords(r, -10, 2, third=lambda ln: r.choice(
                [f32(r.uniform(0, 1)), rcoord(r), f32(r.uniform(-0.5, 1.5))]))
        elif op == 2:
            coords = [(r.randrange(-4, 70) & T.M32, r.randrange(-4, 70) & T.M32,
                       r.randrange(-1, 14) & T.M32) for _ in range(4)]
        else:
            coords = [(r.randrange(0, 18), r.getrandbits(32), r.getrandbits(32))
                      for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, r.randrange(16)]), stats)
    out.append('P compare')
    return out


def depth_word(r):
    return r.choice([0, 0xFFFFFF, 0x800000, 0xFF000000 | r.getrandbits(24), r.getrandbits(32),
                     f32(r.uniform(0, 1)), f32(1.0), 0x7FC00000, 0x80000000,
                     f32(r.uniform(-1, 2))])


def filter_vectors(r):
    out = []
    flt = T.Filter()

    def one(texels, wts, mask, ctl, value):
        data = flt.quad(texels, wts, ctl, mask, value)
        tx = pack([t for row in texels for t in row])
        if data is None:
            out.append('H %0128x %024x %x %04x %032x' % (tx, pack(wts, 24), mask, ctl,
                                                         pack(value)))
            return
        out.append('F %0128x %024x %x %04x %032x %04x %x %0128x' %
                   (tx, pack(wts, 24), mask, ctl, pack(value), r.getrandbits(16),
                    r.getrandbits(1), pack(data)))

    def rwts(fl=None):
        return [r.choice([0, 255, 128, 1, r.getrandbits(8)]) |
                r.choice([0, 255, 128, 1, r.getrandbits(8)]) << 8 |
                (r.getrandbits(8) if fl is None else fl) << 16 for _ in range(4)]

    # nearest: every byte value in every channel and format, texsz, masks.
    for n in range(64):
        tex = [[(4 * n + ln) * 0x01010101 for _ in range(4)] for ln in range(4)]
        one(tex, [r.getrandbits(24)] * 4, 15, r.choice([0, 2]), [0] * 4)
    for n in range(200):
        tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
        ctl = r.choice([0, 2, 4, 6, 8, 10]) | (r.getrandbits(2) << 6)
        one(tex, [r.getrandbits(24) for _ in range(4)], r.randrange(16), ctl,
            [r.getrandbits(32) for _ in range(4)])
    out.append('P nearest')
    for n in range(400):
        tex = [[r.choice([r.getrandbits(32), 0xFFFFFFFF, 0, 0x80808080]) for _ in range(4)]
               for _ in range(4)]
        one(tex, rwts(), r.choice([15, 15, r.randrange(16)]), 1 | r.choice([0, 2]),
            [r.getrandbits(32) for _ in range(4)])
    out.append('P bilinear')
    # trilinear: pairs of passes (nearest or bilinear), weights 0-255.
    for n in range(300):
        mask = r.choice([15, 15, r.randrange(16)])
        fmt = r.choice([0, 2])
        bil = r.getrandbits(1)
        w = rwts(r.choice([None, 0, 255, 128, 1]))
        for pas in range(2):
            tex = [[r.choice([r.getrandbits(32), 0xFFFFFFFF, 0, 0x80808080, 0xFF000000])
                    for _ in range(4)] for _ in range(4)]
            one(tex, w, mask, bil | fmt | (1 << (4 + pas)), [0] * 4)
    out.append('P trilinear')
    # depth: D24 and D32F without compare (texel 0 as (D, 0, 0, 1)).
    for n in range(300):
        tex = [[depth_word(r) for _ in range(4)] for _ in range(4)]
        if n < 64:
            for ln in range(4):
                tex[ln][0] = r.choice([n * 0x40000 + ln, 0xFFFFFF - n * 4 - ln, n * 4 + ln,
                                       0x800000 + n - 32 + ln])
        ctl = 1 << T.CTL_DEPTH | r.choice([0, 2]) | r.choice([0, 1, 8])
        one(tex, rwts(), r.choice([15, 15, r.randrange(16)]), ctl, [0] * 4)
    out.append('P depth')
    # compare: every op, both depth formats, references near the texels;
    # nearest, bilinear and trilinear pairs.
    for n in range(500):
        mask = r.choice([15, 15, r.randrange(16)])
        f32f = r.getrandbits(1)
        fn = r.randrange(8)
        tri = r.random() < 0.3
        w = rwts(r.choice([None, 0, 255]) if tri else None)
        dref = []
        for ln in range(4):
            if f32f:
                dref.append(r.choice([f32(r.uniform(0, 1)), f32(r.uniform(-1, 2)), 0x7FC00000,
                                      0x80000000, 0, f32(1.0), 0x7F800000, 1]))
            else:
                dref.append(r.choice([f32(r.uniform(0, 1)), f32(r.uniform(-1, 2)), 0x7FC00000,
                                      0, f32(1.0), f32(0.5)]))
        for pas in range(2 if tri else 1):
            tex = []
            for ln in range(4):
                row = []
                for _ in range(4):
                    if f32f:
                        near = (dref[ln] + r.choice([-1, 0, 1])) & T.M32
                        row.append(r.choice([near, dref[ln], depth_word(r),
                                             dref[ln] ^ 0x80000000]))
                    else:
                        u = RX.f2u24(dref[ln])
                        row.append(r.getrandbits(8) << 24 |
                                   r.choice([u, max(u - 1, 0), min(u + 1, 0xFFFFFF),
                                             r.getrandbits(24)]))
                tex.append(row)
            ctl = (r.getrandbits(1) | f32f << T.CTL_FMT | 1 << T.CTL_DEPTH | 1 << T.CTL_CMP |
                   fn << T.CTL_CMP_OP | ((1 << (4 + pas)) if tri else 0))
            one(tex, w, mask, ctl, dref)
    out.append('P compare')
    return out


def main():
    r = random.Random(288009)
    # The filter's exactness for nearest texels: c << 16 is c / 255 rounded.
    for c in range(256):
        assert T.conv(c << 16) == f32(c / 255.0), c
        assert T.conv32(c << 24) == T.conv(c << 16), c
    # unorm24 to fp32 is the correctly rounded c / (2^24 - 1): checked for
    # every c once (2 minutes); here the ends and a sample.
    for c in list(range(300)) + [r.randrange(1 << 24) for _ in range(3000)] + \
            list(range((1 << 24) - 300, 1 << 24)):
        assert T.conv24(c) == RX.round_f32(Fraction(c, (1 << 24) - 1)), c
    os.makedirs(VEC, exist_ok=True)
    for name, lines in (('tu_addr.txt', addr_vectors(r)), ('tu_filter.txt', filter_vectors(r))):
        with open(os.path.join(VEC, name), 'w') as fp:
            fp.write('\n'.join(lines) + '\n')
        print('tu-vectors: %d lines -> sim/vec/%s' % (len(lines), name))


if __name__ == '__main__':
    main()
