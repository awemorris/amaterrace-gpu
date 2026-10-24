#!/usr/bin/env python3
# blt-vectors.py: the reference model of the blitter's operations
# (docs/ghci.md sections 8.2 and 8.5: FILL and COPY of 8- to 128-bit
# pixels, KEEP, TILE and UNTILE, the clip rectangle, the reverse direction,
# RESOLVE with every average and pixel size) and the cases of
# sim/tb/atg_blt_tb.v, written to sim/vec/blt.txt (in git; check `git diff
# sim/vec` after a change).  The model is written from the GHCI text; the
# averages use tools/fmtmodel.py (sRGB tables and encoder, fp16) and
# tools/gsi1fp.py (the fused multiply-add of the GPU's fp32 rules).
#   python3 -I tools/blt-vectors.py
# blt.txt lines (hex): memory byte a of 0x0000-0x7FFF starts each case as
# ((a >> 2) x 0x9E3779B1 mod 2^32) >> 8 (a mod 4):
#   C                  a new case (the memory as above)
#   S idx value        STATE write
#   K ok kind          kick; done (ok 1) or error of that kind (ok 0)
#   E addr byte        a byte the blit leaves with this value (every byte
#                      the blit writes is listed; the others keep theirs)
#   P name             end of a group (PASS atg_blt.name)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fmtmodel as FM  # noqa: E402
import gsi1fp as FP  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MEM = 0x8000
ONE, QUARTER = 0x3F800000, 0x3E800000
S_OP, S_DBASE, S_DSTRIDE, S_SBASE, S_SSTRIDE, S_DXY, S_SXY, S_SIZE, S_COLOR = range(9)
S_CMIN, S_CMAX, S_RESOLVE, S_COLOR1 = 9, 10, 11, 12
FILL, COPY, TILE, UNTILE, RESOLVE = 0, 1, 2, 3, 4
KIND_OPCODE = 2
PSL_CODE = {2: 0, 1: 1 << 8, 3: 2 << 8, 0: 3 << 8, 4: 1 << 13}	# BLT_OP's pixel size
# RESOLVE's averages and their pixel sizes (log2 of the bytes).
AVG_SIZES = {0: (0, 1, 2), 1: (1,), 2: (0, 1, 2, 3, 4), 3: (2,), 4: (1, 2, 3), 5: (2, 3, 4),
             6: (2,), 7: (1,)}


def hbyte(a):
    return (((a >> 2) * 0x9E3779B1) & 0xFFFFFFFF) >> (8 * (a & 3)) & 0xFF


class Mem:
    def __init__(self):
        self.w = {}

    def rd(self, a, n):
        return sum(self.w.get(a + i, hbyte(a + i)) << (8 * i) for i in range(n))

    def wr(self, a, v, n, keep=0):
        for i in range(n):
            if not (keep >> (i % 4)) & 1:
                self.w[a + i] = v >> (8 * i) & 0xFF


def paddr(base, stride, x, y, ps, tiled):
    if tiled:
        return base + (y >> 2) * stride + (x >> 2) * 16 * ps + ((y & 3) * 4 + (x & 3)) * ps
    return base + y * stride + x * ps


def clip(st):
    dx, dy = st[S_DXY] & 0xFFFF, st[S_DXY] >> 16
    w, h = st[S_SIZE] & 0xFFFF, st[S_SIZE] >> 16
    x0, y0, x1, y1 = dx, dy, dx + w, dy + h
    cm = st[S_CMAX]
    if cm:
        x0, y0 = max(x0, st[S_CMIN] & 0xFFFF), max(y0, st[S_CMIN] >> 16)
        x1, y1 = min(x1, cm & 0xFFFF), min(y1, cm >> 16)
    return dx, dy, x0, y0, x1, y1


def op_psl(op):
    p128, bpp = op >> 13 & 1, op >> 8 & 3
    if p128:
        return 4 if bpp == 0 else None
    return {0: 2, 1: 1, 2: 3, 3: 0}[bpp]


def blit2d(mem, st):
    """FILL, COPY, TILE, UNTILE; True if taken (False: refused)."""
    op = st[S_OP]
    o, blend, rev, keep = op & 3, op >> 4 & 1, op >> 12 & 1, op >> 16 & 15
    psl = op_psl(op)
    if psl is None:
        return False
    tiled = o in (TILE, UNTILE)
    if (blend and (psl != 2 or tiled)) or (rev and tiled) or (tiled and psl not in (1, 2)) or \
            (keep and (tiled or blend or psl != 2)):
        return False
    ps = 1 << psl
    m = ~(ps - 1)
    db, ds, sb, ss = st[S_DBASE] & m, st[S_DSTRIDE] & m, st[S_SBASE] & m, st[S_SSTRIDE] & m
    dx, dy, x0, y0, x1, y1 = clip(st)
    sx0 = (st[S_SXY] & 0xFFFF) + x0 - dx
    sy0 = (st[S_SXY] >> 16) + y0 - dy
    color = st[S_COLOR] | st[S_COLOR1] << 32 | st[S_COLOR1 + 1] << 64 | st[S_COLOR1 + 2] << 96
    color &= (1 << (8 * ps)) - 1
    src = {}
    if o != FILL:
        for y in range(y0, y1):
            for x in range(x0, x1):
                src[x, y] = mem.rd(paddr(sb, ss, sx0 + x - x0, sy0 + y - y0, ps, o == UNTILE), ps)
    for y in range(y0, y1):
        for x in range(x0, x1):
            v = color if o == FILL else src[x, y]
            a = paddr(db, ds, x, y, ps, o == TILE)
            if blend:
                d = mem.rd(a, 4)
                inv = 255 - (v >> 24)
                out = 0
                for c in range(4):
                    t = (d >> (8 * c) & 0xFF) * inv + 128
                    t = (t + (t >> 8)) >> 8
                    out |= min(255, (v >> (8 * c) & 0xFF) + t) << (8 * c)
                v = out
            mem.wr(a, v, ps, keep)
    return True


def rne4(s):
    q = s >> 2
    return q + (1 if (s & 3) == 3 or ((s & 3) == 2 and q & 1) else 0)


FIELDS = {1: ((0, 5), (5, 6), (11, 5)), 6: ((0, 10), (10, 10), (20, 10), (30, 2)),
          7: ((0, 5), (5, 5), (10, 5), (15, 1))}


def favg4(x):
    """((s0 + s1) + (s2 + s3)) x 0.25 by the fused multiply-add."""
    r01 = FP.fma(FP.F32, x[0], ONE, x[1], 0)
    r23 = FP.fma(FP.F32, x[2], ONE, x[3], 0)
    s = FP.fma(FP.F32, r01, ONE, r23, 0)
    return FP.fma(FP.F32, s, QUARTER, 0x80000000, 0)


def average(fmt, psl, smp):
    """The average of four samples (integers of 2^psl bytes)."""
    ps = 1 << psl
    if fmt == 0:
        return sum(rne4(sum(s >> (8 * k) & 0xFF for s in smp)) << (8 * k) for k in range(ps))
    if fmt in FIELDS:
        out = 0
        for p, w in FIELDS[fmt]:
            out |= rne4(sum(s >> p & ((1 << w) - 1) for s in smp)) << p
        return out
    if fmt == 3:
        dec = FM._srgb_tables()[0]
        out = rne4(sum(s >> 24 for s in smp)) << 24
        for k in range(3):
            out |= FM.srgb_encode(favg4([dec[s >> (8 * k) & 0xFF] for s in smp])) << (8 * k)
        return out
    if fmt == 4:
        out = 0
        for k in range(ps // 2):
            f = favg4([FM.half_f32(s >> (16 * k) & 0xFFFF) for s in smp])
            out |= FM.f32_half(f) << (16 * k)
        return out
    if fmt == 5:
        return sum(favg4([s >> (32 * k) & 0xFFFFFFFF for s in smp]) << (32 * k)
                   for k in range(ps // 4))
    return smp[0]


def resolve(mem, st):
    op, rs = st[S_OP], st[S_RESOLVE]
    psl = op_psl(op)
    fmt, tiled = rs >> 4 & 15, rs >> 8 & 1
    if op & 7 != RESOLVE or op >> 4 & 1 or op >> 12 & 1 or op >> 16 & 15 or psl is None or \
            rs & 15 != 2 or fmt > 7 or psl not in AVG_SIZES[fmt] or \
            (tiled and psl not in (1, 2)):
        return False
    ps = 1 << psl
    db, ds = st[S_DBASE] & ~(ps - 1), st[S_DSTRIDE] & ~(ps - 1)
    sb, ss = st[S_SBASE] & ~(4 * ps - 1), st[S_SSTRIDE] & ~(4 * ps - 1)
    dx, dy, x0, y0, x1, y1 = clip(st)
    sx0 = (st[S_SXY] & 0xFFFF) + x0 - dx
    sy0 = (st[S_SXY] >> 16) + y0 - dy
    for y in range(y0, y1):
        for x in range(x0, x1):
            sx, sy = sx0 + x - x0, sy0 + y - y0
            smp = [mem.rd(sb + sy * ss + (4 * sx + s) * ps, ps) for s in range(4)]
            mem.wr(paddr(db, ds, x, y, ps, tiled), average(fmt, psl, smp), ps)
    return True


class Gen:
    def __init__(self, r):
        self.r = r
        self.out = []

    def case(self, st):
        st = dict(st)
        for k in range(15):
            st.setdefault(k, 0)
        mem = Mem()
        ok = resolve(mem, st) if st[S_OP] & 4 else blit2d(mem, st)
        self.out.append('C')
        for k in range(15):
            self.out.append('S %03x %08x' % (k, st[k]))
        self.out.append('K %x %x' % (int(ok), 0 if ok else KIND_OPCODE))
        for a in sorted(mem.w):
            assert 0 <= a < MEM, hex(a)
            self.out.append('E %04x %02x' % (a, mem.w[a]))

    def group(self, name):
        self.out.append('P ' + name)


def rect(r, maxw=24, maxh=6):
    w, h = r.randrange(1, maxw), r.randrange(1, maxh)
    return w, h


def vectors():
    r = random.Random(288030)
    g = Gen(r)

    def colors(st):
        st[S_COLOR] = r.getrandbits(32)
        for k in range(3):
            st[S_COLOR1 + k] = r.getrandbits(32)

    # ps: FILL and COPY of every pixel size, offsets, strides, the clip,
    # the reverse direction (no overlap), the wide FILL's colour words.
    for n in range(120):
        psl = n % 5
        ps = 1 << psl
        w, h = rect(r)
        st = {S_OP: r.choice([FILL, COPY]) | PSL_CODE[psl] | r.choice([0, 0, 1]) << 12,
              S_DBASE: 0x4000 + r.randrange(0, 256) * ps, S_SBASE: 0x0400 + r.randrange(64) * ps,
              S_DSTRIDE: (w + r.randrange(0, 8)) * ps + r.choice([0, 0, r.randrange(ps)]),
              S_SSTRIDE: (w + r.randrange(0, 8)) * ps,
              S_DXY: r.randrange(4) | r.randrange(3) << 16,
              S_SXY: r.randrange(4) | r.randrange(3) << 16, S_SIZE: w | h << 16}
        if r.random() < 0.3:
            st[S_CMIN] = r.randrange(6) | r.randrange(3) << 16
            st[S_CMAX] = r.randrange(4, 30) | r.randrange(2, 9) << 16
        colors(st)
        g.case(st)
    g.group('ps')
    # keep: 32-bit FILL and COPY that keep some bytes of each pixel (the
    # depth and the stencil of D24_UNORM_S8_UINT).
    for n in range(40):
        w, h = rect(r)
        st = {S_OP: r.choice([FILL, COPY]) | r.choice([8, 7, r.randrange(1, 16)]) << 16 |
              r.choice([0, 1]) << 12,
              S_DBASE: 0x4000 + 4 * r.randrange(64), S_SBASE: 0x0800 + 4 * r.randrange(64),
              S_DSTRIDE: 4 * (w + r.randrange(4)), S_SSTRIDE: 4 * (w + r.randrange(4)),
              S_DXY: r.randrange(3), S_SXY: r.randrange(3) << 16, S_SIZE: w | h << 16}
        colors(st)
        g.case(st)
    g.group('keep')
    # tile: TILE, UNTILE and blend-over of 16- and 32-bit pixels (as before).
    for n in range(20):
        psl = r.choice([1, 2])
        ps = 1 << psl
        w, h = rect(r, 16, 9)
        o = r.choice([TILE, UNTILE, FILL | 0x10, COPY | 0x10]) if psl == 2 else \
            r.choice([TILE, UNTILE])
        st = {S_OP: o | PSL_CODE[psl], S_DBASE: 0x4000, S_SBASE: 0x0800,
              S_DSTRIDE: 16 * ps * 8, S_SSTRIDE: 16 * ps * 8, S_DXY: r.randrange(5),
              S_SXY: r.randrange(5) | r.randrange(3) << 16, S_SIZE: w | h << 16}
        colors(st)
        g.case(st)
    g.group('tile')
    # refuse: combinations the blitter does not do (no access).
    bad = [FILL | 1 << 13 | 1 << 8, COPY | 1 << 13 | 2 << 8, TILE | 3 << 8, UNTILE | 2 << 8,
           TILE | 1 << 13, FILL | 0x10 | 1 << 8, FILL | 8 << 16 | 1 << 8, COPY | 7 << 16 | 0x10,
           TILE | 8 << 16, COPY | 8 << 16 | 2 << 8]
    for op in bad:
        g.case({S_OP: op, S_DBASE: 0x4000, S_SBASE: 0x0800, S_DSTRIDE: 64, S_SSTRIDE: 64,
                S_SIZE: 4 | 2 << 16})
    for op, rs in ((RESOLVE | 2 << 8, 0x02), (RESOLVE, 0x12), (RESOLVE | 3 << 8, 0x32),
                   (RESOLVE | 1 << 13, 0x62), (RESOLVE | 3 << 8, 0x42), (RESOLVE, 0x82),
                   (RESOLVE | 2 << 8, 0x122), (RESOLVE | 8 << 16, 0x02), (RESOLVE, 0x01)):
        g.case({S_OP: op, S_RESOLVE: rs, S_DBASE: 0x4000, S_SBASE: 0x0800, S_DSTRIDE: 64,
                S_SSTRIDE: 256, S_SIZE: 2 | 2 << 16})
    g.group('refuse')
    # resolve: every average with every pixel size it takes, tiled
    # destinations of 16- and 32-bit pixels, offsets, the clip.
    for n in range(160):
        fmt = n % 8
        psl = r.choice(AVG_SIZES[fmt])
        ps = 1 << psl
        tiled = int(psl in (1, 2) and r.random() < 0.25)
        w, h = rect(r, 12, 5)
        st = {S_OP: RESOLVE | PSL_CODE[psl], S_RESOLVE: 2 | fmt << 4 | tiled << 8,
              S_DBASE: 0x5000 + (0 if tiled else r.randrange(32) * ps),
              S_SBASE: 0x0400 + r.randrange(4) * 64,
              S_DSTRIDE: 16 * ps * 4 if tiled else (w + r.randrange(6)) * ps,
              S_SSTRIDE: ((w + 3) * 4 * ps + 63) & ~63 if r.random() < 0.7 else 4 * ps * (w + 1),
              S_DXY: r.randrange(4) | r.randrange(3) << 16,
              S_SXY: r.randrange(3) | r.randrange(2) << 16, S_SIZE: w | h << 16}
        if r.random() < 0.2:
            st[S_CMIN] = r.randrange(3)
            st[S_CMAX] = r.randrange(3, 14) | r.randrange(2, 7) << 16
        g.case(st)
    g.group('resolve')
    return g.out


def main():
    # The averages' arithmetic against plain values.
    assert average(5, 2, [0x3F800000, 0x40000000, 0x40400000, 0x40800000]) == 0x40200000
    assert average(4, 1, [0x3C00, 0x4000, 0x4200, 0x4400]) == 0x4100
    assert average(3, 2, [0xFF000000] * 2 + [0xFFFFFFFF] * 2) & 0xFFFFFF == \
        FM.srgb_encode(FP.fma(FP.F32, ONE, 0x3F000000, 0x80000000, 0)) * 0x010101
    lines = vectors()
    path = os.path.join(ROOT, 'sim', 'vec', 'blt.txt')
    with open(path, 'w') as fp:
        fp.write('\n'.join(lines) + '\n')
    print('blt-vectors: %d lines -> sim/vec/blt.txt' % len(lines))


if __name__ == '__main__':
    main()
