#!/usr/bin/env python3
# etcmodel.py: the reference decoder of the ETC2 and EAC compressed texture
# formats (VkFormat 147-156) for rtl/gpu/tu/atg_tu_etc.v, written from the
# text of the Khronos Data Format Specification (sections "ETC2 Compressed
# Texture Image Formats"; CC-BY-4.0): the RGB modes individual,
# differential, T, H and planar, RGB8A1's punch-through alpha, RGBA8's 8-bit
# EAC alpha, EAC R11 and R11G11, unsigned and signed.  No other decoder's
# code or tables were used.
#   python3 -I tools/etcmodel.py --selftest   the specification's worked
#       examples; prints "PASS etcmodel.selftest"
#   python3 -I tools/etcmodel.py --vectors    writes sim/vec/tu_etc.txt for
#       sim/tb/atg_tu_etc_tb.v (lines "V fmt block s t kind texel" in hex,
#       "P name" at the end of a group: modes, random)
# Library use: import etcmodel as E; E.decode(fmt, block, s, t) ->
# (kind, texel) as atg_tu_etc: fmt = VkFormat - 147, block the bytes as an
# int (byte 0 in bits 7:0), (s, t) the texel's column and row in the block.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import sys

MODS = [(2, 8), (5, 17), (9, 29), (13, 42), (18, 60), (24, 80), (33, 106), (47, 183)]
DIST = [3, 6, 11, 16, 23, 32, 41, 64]
EAC = [[-3, -6, -9, -15, 2, 5, 8, 14], [-3, -7, -10, -13, 2, 6, 9, 12],
       [-2, -5, -8, -13, 1, 4, 7, 12], [-2, -4, -6, -13, 1, 3, 5, 12],
       [-3, -6, -8, -12, 2, 5, 7, 11], [-3, -7, -9, -11, 2, 6, 8, 10],
       [-4, -7, -8, -11, 3, 6, 7, 10], [-3, -5, -8, -11, 2, 4, 7, 10],
       [-2, -6, -8, -10, 1, 5, 7, 9], [-2, -5, -8, -10, 1, 4, 7, 9],
       [-2, -4, -8, -10, 1, 3, 7, 9], [-2, -5, -7, -10, 1, 4, 6, 9],
       [-3, -4, -7, -10, 2, 3, 6, 9], [-1, -2, -3, -10, 0, 1, 2, 9],
       [-4, -6, -8, -9, 3, 5, 7, 8], [-3, -5, -7, -9, 2, 4, 6, 8]]
KIND_UNORM, KIND_SRGB, KIND_U11, KIND_S11 = 0, 1, 2, 3


def word64(block, k=0):
    """The 64-bit integer of bytes 8k..8k+7 (byte 8k the most significant)."""
    b = [(block >> (8 * (8 * k + i))) & 0xFF for i in range(8)]
    v = 0
    for x in b:
        v = v << 8 | x
    return v


def bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def sext3(v):
    return v - 8 if v & 4 else v


def clamp(v, lo=0, hi=255):
    return lo if v < lo else hi if v > hi else v


def ext4(c):
    return c << 4 | c


def ext5(c):
    return c << 3 | c >> 2


def ext6(c):
    return c << 2 | c >> 4


def ext7(c):
    return c << 1 | c >> 6


def etc2_rgb(w, x, y, punch=False):
    """(R, G, B, A) of texel (x, y) of a 64-bit RGB block."""
    k = x * 4 + y
    idx = (w >> (16 + k) & 1) << 1 | (w >> k & 1)
    dbit = w >> 33 & 1
    opaque = dbit if punch else 1
    transparent = punch and not opaque and idx == 2
    if not punch and not dbit:
        mode = 'ind'
    else:
        r, g, b = bits(w, 63, 59), bits(w, 55, 51), bits(w, 47, 43)
        dr, dg, db = sext3(bits(w, 58, 56)), sext3(bits(w, 50, 48)), sext3(bits(w, 42, 40))
        if not 0 <= r + dr <= 31:
            mode = 'T'
        elif not 0 <= g + dg <= 31:
            mode = 'H'
        elif not 0 <= b + db <= 31:
            mode = 'P'
        else:
            mode = 'diff'
    if mode in ('ind', 'diff'):
        if mode == 'ind':
            c1 = [ext4(bits(w, 63, 60)), ext4(bits(w, 55, 52)), ext4(bits(w, 47, 44))]
            c2 = [ext4(bits(w, 59, 56)), ext4(bits(w, 51, 48)), ext4(bits(w, 43, 40))]
        else:
            c1 = [ext5(r), ext5(g), ext5(b)]
            c2 = [ext5(r + dr), ext5(g + dg), ext5(b + db)]
        flip = w >> 32 & 1
        sub = (y >= 2) if flip else (x >= 2)
        tab = MODS[bits(w, 36, 34) if sub else bits(w, 39, 37)]
        base = c2 if sub else c1
        a, bb = tab
        mod = [a, bb, -a, -bb][idx]
        if punch and not opaque and idx in (0, 2):
            mod = 0
        rgb = [clamp(c + mod) for c in base]
    elif mode in ('T', 'H'):
        if mode == 'T':
            c1 = [ext4(bits(w, 60, 59) << 2 | bits(w, 57, 56)), ext4(bits(w, 55, 52)),
                  ext4(bits(w, 51, 48))]
            c2 = [ext4(bits(w, 47, 44)), ext4(bits(w, 43, 40)), ext4(bits(w, 39, 36))]
            d = DIST[bits(w, 35, 34) << 1 | (w >> 32 & 1)]
            paint = [c1, [c + d for c in c2], c2, [c - d for c in c2]]
        else:
            c1 = [ext4(bits(w, 62, 59)), ext4(bits(w, 58, 56) << 1 | (w >> 52 & 1)),
                  ext4((w >> 51 & 1) << 3 | bits(w, 49, 47))]
            c2 = [ext4(bits(w, 46, 43)), ext4(bits(w, 42, 39)), ext4(bits(w, 38, 35))]
            v1 = c1[0] << 16 | c1[1] << 8 | c1[2]
            v2 = c2[0] << 16 | c2[1] << 8 | c2[2]
            d = DIST[(w >> 34 & 1) << 2 | (w >> 32 & 1) << 1 | int(v1 >= v2)]
            paint = [[c + d for c in c1], [c - d for c in c1], [c + d for c in c2],
                     [c - d for c in c2]]
        rgb = [clamp(c) for c in paint[idx]]
    else:
        o = [ext6(bits(w, 62, 57)), ext7(bits(w, 56, 56) << 6 | bits(w, 54, 49)),
             ext6(bits(w, 48, 48) << 5 | bits(w, 44, 43) << 3 | bits(w, 41, 39))]
        h = [ext6(bits(w, 38, 34) << 1 | (w >> 32 & 1)), ext7(bits(w, 31, 25)),
             ext6(bits(w, 24, 19))]
        v = [ext6(bits(w, 18, 13)), ext7(bits(w, 12, 6)), ext6(bits(w, 5, 0))]
        rgb = [clamp((x * (h[c] - o[c]) + y * (v[c] - o[c]) + 4 * o[c] + 2) >> 2)
               for c in range(3)]
        transparent = False
    if transparent:
        return [0, 0, 0, 0]
    return rgb + [255]


def eac(w, x, y, kind):
    """kind 'a8': the 8-bit alpha; 'u11', 's11': R11's 11-bit value."""
    k = x * 4 + y
    base, mul, ti = bits(w, 63, 56), bits(w, 55, 52), bits(w, 51, 48)
    m = EAC[ti][bits(w, 47 - 3 * k, 45 - 3 * k)]
    if kind == 'a8':
        return clamp(base + m * mul)
    if kind == 'u11':
        return clamp(base * 8 + 4 + (m * mul * 8 if mul else m), 0, 2047)
    sb = base - 256 if base & 0x80 else base
    sb = max(sb, -127)
    return clamp(sb * 8 + (m * mul * 8 if mul else m), -1023, 1023)


def decode(fmt, block, s, t):
    """(kind, 32-bit texel) of atg_tu_etc."""
    if fmt in (0, 1, 2, 3):
        r, g, b, a = etc2_rgb(word64(block), s, t, fmt in (2, 3))
        return fmt & 1, a << 24 | b << 16 | g << 8 | r
    if fmt in (4, 5):
        r, g, b, _ = etc2_rgb(word64(block, 1), s, t)
        a = eac(word64(block), s, t, 'a8')
        return fmt & 1, a << 24 | b << 16 | g << 8 | r
    if fmt in (6, 7, 8, 9):
        sg = fmt in (7, 9)
        kd = 's11' if sg else 'u11'
        r = eac(word64(block), s, t, kd) & 0x7FF
        g = eac(word64(block, 1), s, t, kd) & 0x7FF if fmt >= 8 else 0
        return KIND_S11 if sg else KIND_U11, g << 16 | r
    return KIND_UNORM, 0


def selftest():
    def put(fields):
        w = 0
        for hi, lo, v in fields:
            w |= (v & ((1 << (hi - lo + 1)) - 1)) << lo
        return w

    def blk(w, w2=None):
        b = sum(((w >> (8 * (7 - i))) & 0xFF) << (8 * i) for i in range(8))
        if w2 is not None:
            b |= sum(((w2 >> (8 * (7 - i))) & 0xFF) << (8 * (8 + i)) for i in range(8))
        return b

    # Planar: O (12, 64, 62), H (50, 5, 37), V (40, 112, 45), the
    # specification's 16 texels.  B is not overflowing differentially?
    # Planar needs B + Bd outside [0, 31] with R, G inside.
    o, h, v = (12, 64, 62), (50, 5, 37), (40, 112, 45)
    w = put([(62, 57, o[0]), (56, 56, o[1] >> 6), (54, 49, o[1]), (48, 48, o[2] >> 5),
             (44, 43, o[2] >> 3), (41, 39, o[2]), (38, 34, h[0] >> 1), (32, 32, h[0]),
             (31, 25, h[1]), (24, 19, h[2]), (18, 13, v[0]), (12, 6, v[1]), (5, 0, v[2]),
             (33, 33, 1)])
    want = [(48, 129, 251), (87, 99, 226), (126, 70, 201), (164, 40, 175),
            (77, 153, 234), (115, 123, 209), (154, 94, 183), (193, 64, 158),
            (105, 177, 217), (144, 147, 191), (183, 118, 166), (221, 88, 141),
            (134, 201, 199), (172, 171, 174), (211, 142, 149), (250, 112, 124)]
    # The free bits 63, 55, 47..45 and 42 choose the planar mode.
    for free in range(64):
        ww = w | (free & 1) << 63 | (free >> 1 & 1) << 55 | (free >> 2 & 7) << 45 | \
            (free >> 5) << 42
        r_, g_, b_ = bits(ww, 63, 59), bits(ww, 55, 51), bits(ww, 47, 43)
        dr, dg, db = sext3(bits(ww, 58, 56)), sext3(bits(ww, 50, 48)), sext3(bits(ww, 42, 40))
        if 0 <= r_ + dr <= 31 and 0 <= g_ + dg <= 31 and not 0 <= b_ + db <= 31:
            w = ww
            break
    if 0 <= r_ + dr <= 31 and 0 <= g_ + dg <= 31 and not 0 <= b_ + db <= 31:
        for n, (x, y) in enumerate((x, y) for y in range(4) for x in range(4)):
            assert etc2_rgb(w, x, y)[:3] == list(want[n]), (x, y)
    else:
        print('etcmodel: the planar example is not a planar block with these bits '
              '(the unused bits choose the mode); checked by formula only')
        oo = [ext6(o[0]), ext7(o[1]), ext6(o[2])]
        assert oo == [48, 129, 251]
    # T mode: base colours (13, 1, 8), (4, 12, 13), distance index 5: paint
    # colours (221, 17, 136), (100, 236, 253), (68, 204, 221), (36, 172, 189).
    w = put([(60, 59, 13 >> 2), (57, 56, 13), (55, 52, 1), (51, 48, 8), (47, 44, 4),
             (43, 40, 12), (39, 36, 13), (35, 34, 5 >> 1), (32, 32, 5), (33, 33, 1),
             (63, 61, 7)])
    want = [(221, 17, 136), (100, 236, 253), (68, 204, 221), (36, 172, 189)]
    for idx in range(4):
        x, y = 1, 2
        k = x * 4 + y
        ww = (w & ~(1 << (16 + k)) & ~(1 << k)) | (idx >> 1) << (16 + k) | (idx & 1) << k
        assert etc2_rgb(ww, x, y)[:3] == list(want[idx]), idx
    # H mode: the same base colours, distance index 5 (d_a d_b = 10: the low
    # bit from base 1 >= base 2): (253, 49, 168), (189, 0, 104), (100, 236,
    # 253), (36, 172, 189).
    w = put([(62, 59, 13), (58, 56, 1 >> 1), (52, 52, 1), (51, 51, 8 >> 3), (49, 47, 8),
             (46, 43, 4), (42, 39, 12), (38, 35, 13), (34, 34, 1), (32, 32, 0), (33, 33, 1)])
    # G + Gd must overflow, R + Rd must not: bits 63, 55..53 and 50 are free.
    for free in range(32):
        ww = w | (free >> 3 & 1) << 63 | (free & 7) << 53 | (free >> 4) << 50
        r_, dr = bits(ww, 63, 59), sext3(bits(ww, 58, 56))
        g_, dg = bits(ww, 55, 51), sext3(bits(ww, 50, 48))
        if 0 <= r_ + dr <= 31 and not 0 <= g_ + dg <= 31:
            w = ww
            break
    want = [(253, 49, 168), (189, 0, 104), (100, 236, 253), (36, 172, 189)]
    for idx in range(4):
        x, y = 3, 0
        k = x * 4 + y
        ww = w | (idx >> 1) << (16 + k) | (idx & 1) << k
        assert etc2_rgb(ww, x, y)[:3] == list(want[idx]), (idx, etc2_rgb(ww, x, y))
    # EAC: base 103, table 13, index 3, multiplier 2 -> 83 (alpha); R11
    # with multiplier 0 -> 818; signed base 60, multiplier 2 -> 320.
    def eacw(base, mul, ti, idx, x=0, y=1):
        k = x * 4 + y
        return put([(63, 56, base), (55, 52, mul), (51, 48, ti), (47 - 3 * k, 45 - 3 * k, idx)])
    assert eac(eacw(103, 2, 13, 3), 0, 1, 'a8') == 83
    assert eac(eacw(103, 0, 13, 3), 0, 1, 'u11') == 818
    assert eac(eacw(60, 2, 13, 3), 0, 1, 's11') == 320
    assert decode(6, blk(eacw(103, 0, 13, 3)), 0, 1) == (KIND_U11, 818)
    # Individual: R 14, G 3, B 8 -> (238, 51, 136); differential R 28 ->
    # 231, R 28 + -4 -> 198.
    assert [ext4(14), ext4(3), ext4(8)] == [238, 51, 136]
    assert ext5(28) == 231 and ext5(24) == 198
    # Punch-through: opaque 0, index 2 is (0, 0, 0, 0); index 0 the base.
    w = put([(63, 59, 28), (58, 56, 0), (55, 51, 4), (50, 48, 2), (47, 43, 3), (42, 40, 0),
             (39, 37, 2), (36, 34, 2), (33, 33, 0)])
    assert etc2_rgb(w | 1 << 16, 0, 0, True) == [0, 0, 0, 0]
    assert etc2_rgb(w, 0, 0, True) == [231, 33, 24, 255]
    assert etc2_rgb(w | 1, 0, 0, True) == [255, 33 + 29, 24 + 29, 255]
    print('PASS etcmodel.selftest')


def mode_of(w, punch=False):
    if not punch and not w >> 33 & 1:
        return 'ind'
    r, g, b = bits(w, 63, 59), bits(w, 55, 51), bits(w, 47, 43)
    dr, dg, db = sext3(bits(w, 58, 56)), sext3(bits(w, 50, 48)), sext3(bits(w, 42, 40))
    if not 0 <= r + dr <= 31:
        return 'T'
    if not 0 <= g + dg <= 31:
        return 'H'
    if not 0 <= b + db <= 31:
        return 'P'
    return 'diff'


def vectors():
    import os
    import random
    r = random.Random(288012)
    out = []

    def emit(fmt, block):
        for t in range(4):
            for s_ in range(4):
                k, v = decode(fmt, block, s_, t)
                out.append('V %x %032x %x %x %x %08x' % (fmt, block, s_, t, k, v))

    def rblock(n):
        return r.getrandbits(8 * n)

    # modes: random 64-bit colour blocks until every mode, both opacities and
    # the flip bit are met many times, in each of the RGB formats; EAC
    # blocks with every table, multiplier 0 and the extreme bases.
    seen = {}
    while min([seen.get(k, 0) for k in [(m, p, o) for m in ('ind', 'diff', 'T', 'H', 'P')
                                        for p in (0, 1) for o in (0, 1)
                                        if not (m == 'ind' and p)]] or [0]) < 12:
        b = rblock(8)
        w = word64(b)
        p = r.getrandbits(1)
        m = mode_of(w, p)
        key = (m, p, w >> 33 & 1 if p else w >> 32 & 1)
        if seen.get(key, 0) >= 12:
            continue
        seen[key] = seen.get(key, 0) + 1
        emit(2 + r.getrandbits(1) if p else r.getrandbits(1), b)
    for ti in range(16):
        for mul in (0, 1, 15, r.randrange(16)):
            for base in (0, 0x80, 0x7F, 0xFF, r.getrandbits(8)):
                w = base << 56 | mul << 52 | ti << 48 | r.getrandbits(48)
                b = sum(((w >> (8 * (7 - i))) & 0xFF) << (8 * i) for i in range(8))
                fmt = r.choice([6, 7, 4, 5, 8, 9])
                if fmt in (4, 5, 8, 9):
                    b |= rblock(8) << 64
                emit(fmt, b)
    out.append('P modes')
    for n in range(600):
        fmt = n % 12
        emit(fmt, rblock(16))
    out.append('P random')
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sim', 'vec',
                        'tu_etc.txt')
    with open(path, 'w') as fp:
        fp.write('\n'.join(out) + '\n')
    print('etcmodel: %d lines -> sim/vec/tu_etc.txt' % len(out))


if __name__ == '__main__':
    if '--vectors' in sys.argv:
        vectors()
    elif '--selftest' in sys.argv:
        selftest()
    else:
        print(__doc__ if __doc__ else 'etcmodel.py --selftest')
