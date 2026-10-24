#!/usr/bin/env python3
# tu-vectors.py: writes the expected-value files of the atg_tu_addr and
# atg_tu_filter unit testbenches (sim/vec/tu_addr.txt, sim/vec/tu_filter.txt)
# from the reference model tools/tumodel.py.  The files are in git; run this
# after changing the model or the cases, and check that `git diff sim/vec`
# shows only what was meant.
#   python3 -I tools/tu-vectors.py
# tu_addr.txt lines (hex):
#   S idx value                      STATE write (TU range)
#   Q op slot mask tag last off coord n   one quad (op 8 bits, off 12, coord 640:
#                                    lane 0 in the low bits, 5 words a lane),
#                                    then its n outputs (1 to 4 passes of
#                                    mip and 3D linear filtering):
#   A addr bord wts ctl value        one ta_* output (addr 512, bord 16,
#                                    wts 128, ctl 48, value 128)
#   P name                           end of the group (PASS atg_tu_addr.name)
# tu_filter.txt lines (hex):
#   H texels wts mask ctl value      a pass with more to follow
#                                    (no output: its sums are kept)
#   F texels wts mask ctl value tag last data   one quad and its output
#   P name                           as above.
# tu_quad.txt lines (hex), the whole TU (sim/tb/atg_tu_tb.v; memory word
# at a is (a >> 2) x 0x9E3779B1 mod 2^32):
#   S idx value                      STATE write
#   Q op slot mask off coord data    one quad and its 16 returned words
#   P name                           as above.
# tu_ffilt.txt lines (hex), the fp32 path (atg_tu_ffilt):
#   H texels bord lo wts mask ctl    a pass with more to follow (lo: the
#                                    slots' address bits 1:0, 32 bits)
#   F texels bord lo wts mask ctl tag last data   one quad and its output
#   P name                           as above.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import math
import os
import random
import struct
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as RX  # noqa: E402
import tumodel as T  # noqa: E402
import fmtmodel as FM  # noqa: E402

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


# SAMPLER bits: wrap u and v, mag and min linear (the basic sampler).
SAMP_BASIC = 0xCF
SAMP_BORDER_MASK = 7 << T.SAMP_BORDER


def img_word(levels, fmt=0, tiled=0, typ=0, cnt=0):
    return (levels & 15 | (fmt & 15) << T.IMG_FMT | (tiled & 1) << T.IMG_TILED |
            (typ & 7) << T.IMG_TYPE | (cnt & 0xFFFF) << T.IMG_COUNT)


def rdesc(r, tiled=None, samp_mask=SAMP_BASIC, samp_set=0, clamps=False, fmt=None, typ=0,
          cnt=None, square=False):
    """A random slot descriptor (16 words); without clamps minLod 0, maxLod
    15.996 (the field 0) and no sampler bias."""
    w = r.choice([1, 2, 3, 4, 5, 7, 8, 16, 33, 64, 100, 256, 1000, 4096, 0, r.randrange(1, 70000)])
    h = r.choice([1, 2, 3, 4, 6, 8, 16, 31, 64, 128, 1024, 0, r.randrange(1, 70000)])
    w, h = min(w, 65535), min(h, 65535)
    if square:
        h = w
    samp = (r.getrandbits(19) & samp_mask) | samp_set
    if fmt is None:
        fmt = r.getrandbits(1)
    if tiled is None:
        tiled = r.getrandbits(1)
    lev = r.randrange(16)
    lod = T.LOD_NONE
    if clamps:
        mn = r.choice([0, 0, 0x80, 0x100, 0x2C0, r.getrandbits(12)])
        mx = 0xFFF - r.choice([0xFFF, 0xFFF, 0, 0x100, 0x380, mn, r.getrandbits(12)])
        lev = r.choice([5, 9, 13, r.randrange(16)])
        lod = mn | mx << 12
        samp |= r.choice([0, 0x100, 0x1F00, 0x40, 0x1000, r.getrandbits(13)]) << T.SAMP_LOD_BIAS
    if cnt is None:
        cnt = r.choice([0, 1, 2, 3, 6, 17, 100, r.getrandbits(16)])
    d = [r.getrandbits(32) & ~63, h << 16 | w, img_word(lev, fmt, tiled, typ, cnt),
         r.choice([r.getrandbits(32) & ~63, r.getrandbits(20) & ~63, 0x10000]), samp, lod]
    d += [r.getrandbits(32) if r.random() < 0.3 else 0 for _ in range(10)]	# reserved
    d[T.D_FORMAT] = 0	# TEX_FORMAT 0: the earlier formats
    return d


def set_desc(out, slot, d):
    for k, v in enumerate(d):
        out.append('S %03x %08x' % (S_TU + 16 * slot + k, v))


def quad(out, r, op, slot, d, coords, mask, stats, off=0):
    coords = [tuple(c) + (r.getrandbits(32),) * (5 - len(c)) for c in coords]
    passes = T.quad_addr(op, d, coords, mask, off)
    crd = pack([w for c in coords for w in c])
    tag = r.getrandbits(16)
    last = r.getrandbits(1)
    out.append('Q %02x %x %x %04x %x %03x %0160x %x' % (op, slot, mask, tag, last, off, crd,
                                                       len(passes)))
    for a, bo, wts, ctl, val in passes:
        out.append('A %0128x %04x %032x %013x %032x' %
                   (pack([x for ln in range(4) for x in a[ln]]),
                    pack([x for ln in range(4) for x in bo[ln]], 1), pack(wts), ctl, pack(val)))
        stats['border'] += sum(1 for ln in range(4) for x in bo[ln] if x and mask >> ln & 1)
    stats['passes'] += len(passes)
    stats['np%d' % len(passes)] = stats.get('np%d' % len(passes), 0) + 1


def lod_coords(r, scale_lo=-14, scale_hi=3, third=None):
    """A quad's (u, v, rs2, Dref, w) with derivatives over 2^scale (w too
    when third is 'w')."""
    u0, v0, w0 = r.uniform(-2, 2), r.uniform(-2, 2), r.uniform(-2, 2)
    sx = 2.0 ** r.uniform(scale_lo, scale_hi) * r.choice([1, -1])
    sy = 2.0 ** r.uniform(scale_lo, scale_hi) * r.choice([1, -1])
    dd = [sx * r.uniform(-1, 1), sy * r.uniform(-1, 1), sx * r.uniform(-1, 1),
          sy * r.uniform(-1, 1), sx * r.uniform(-1, 1), sy * r.uniform(-1, 1)]
    if r.random() < 0.05:
        dd = [0.0] * 6
    coords = []
    for ln in range(4):
        x, y = ln & 1, ln >> 1
        t = r.choice([0, f32(r.uniform(-4, 4)), f32(r.uniform(-40, 40)), rcoord(r)])
        dr = r.choice([f32(r.uniform(0, 1)), rcoord(r), f32(r.uniform(-0.5, 1.5))])
        wv = f32(w0 + x * dd[4] + y * dd[5]) if third == 'w' else rcoord(r)
        coords.append((f32(u0 + x * dd[0] + y * dd[1]), f32(v0 + x * dd[2] + y * dd[3]), t, dr,
                       wv))
    return coords


def layer_coord(r, cnt):
    return r.choice([f32(r.uniform(-1, cnt + 1)), f32(r.randrange(-1, cnt + 2) + 0.5),
                     f32(r.randrange(0, cnt + 1)), rcoord(r), f32(r.uniform(0, 3)),
                     f32(r.randrange(0, 8) + 0.5)])


def cube_dir(r):
    """A direction near a face's edge or corner, a tie, or anywhere."""
    k = r.random()
    if k < 0.15:
        a = r.uniform(0.1, 2)
        v = [a * r.choice([1, -1]) for _ in range(3)]
        if r.getrandbits(1):
            v[r.randrange(3)] = r.uniform(-a, a)
        return v
    if k < 0.2:
        return [r.choice([0.0, -0.0, 1e-40, r.uniform(-1, 1)]) for _ in range(3)]
    face = r.randrange(6)
    (ma, ms), (sa, ss), (ta, ts) = T.CUBE_FACES[face]
    m = r.uniform(0.2, 4)
    v = [0.0] * 3
    v[ma] = ms * m
    v[sa] += ss * m * r.choice([r.uniform(-1.05, 1.05), r.uniform(0.9, 1.02), -r.uniform(0.9, 1.02)])
    v[ta] += ts * m * r.choice([r.uniform(-1.05, 1.05), r.uniform(0.9, 1.02), -r.uniform(0.9, 1.02)])
    return v


def cube_coords(r, scale_lo=-12, scale_hi=-2):
    d0 = cube_dir(r)
    sx = 2.0 ** r.uniform(scale_lo, scale_hi)
    dx = [sx * r.uniform(-1, 1) for _ in range(3)]
    dy = [sx * r.uniform(-1, 1) for _ in range(3)]
    coords = []
    for ln in range(4):
        x, y = ln & 1, ln >> 1
        v = [d0[i] + x * dx[i] + y * dy[i] for i in range(3)]
        if r.random() < 0.05:
            v = [r.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, f32(1.0),
                           rcoord(r)]) for _ in range(3)]
            fv = v
        else:
            fv = [f32(c) for c in v]
        coords.append((fv[0], fv[1], r.choice([0, f32(r.uniform(-1, 8)), rcoord(r)]),
                       r.choice([f32(r.uniform(0, 1)), rcoord(r)]), fv[2]))
    return coords


def addr_vectors(r):
    out = []
    descs = {}
    stats = {'border': 0, 'passes': 0}

    def new_descs(**kw):
        for s in range(16):
            descs[s] = rdesc(r, **kw)
            set_desc(out, s, descs[s])

    def plain_coords(op):
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
        return coords

    # wrap: texl, texf and texsz on random descriptors (linear and tiled).
    for n in range(500):
        if n % 50 == 0:
            new_descs(tiled=r.getrandbits(1) if n else 0)
        slot = r.randrange(16)
        op = r.choice([0, 0, 0, 0, 2, 3])
        quad(out, r, op, slot, descs[slot], plain_coords(op),
             r.choice([15, 15, 15, r.randrange(16)]), stats)
    out.append('P wrap')
    # lod: texb quads with derivatives over 2^-14 .. 2^3 and random biases.
    for n in range(400):
        if n % 40 == 0:
            for s in range(16):
                d = rdesc(r, tiled=0)
                d[T.D_IMAGE] = (d[T.D_IMAGE] & ~15) | r.choice([0, 1, 5, 9, 13, 14, 15,
                                                                r.randrange(16)])
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
                d = rdesc(r, samp_mask=SAMP_BASIC | SAMP_BORDER_MASK,
                          samp_set=1 << T.SAMP_MIP_LIN)
                d[T.D_IMAGE] = (d[T.D_IMAGE] & ~15) | r.choice([0, 1, 2, 5, 9, 13, 15,
                                                                r.randrange(16)])
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
                d = rdesc(r, samp_mask=0xFF | 1 << T.SAMP_MIP_LIN | SAMP_BORDER_MASK)
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
    # word 3 is the reference.
    for n in range(300):
        if n % 50 == 0:
            for s in range(16):
                descs[s] = rdesc(r, samp_mask=0x1FFF | SAMP_BORDER_MASK, fmt=r.choice([2, 3]))
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 1, 2, 3])
        if op in (0, 1):
            coords = lod_coords(r, -10, 2)
        elif op == 2:
            coords = [(r.randrange(-4, 70) & T.M32, r.randrange(-4, 70) & T.M32,
                       r.randrange(-1, 14) & T.M32) for _ in range(4)]
        else:
            coords = [(r.randrange(0, 18), r.getrandbits(32), r.getrandbits(32))
                      for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, r.randrange(16)]), stats)
    out.append('P compare')
    # lodclamp: the sampler's minLod, maxLod and mipLodBias on texl and texb,
    # mip nearest and linear.
    for n in range(300):
        if n % 30 == 0:
            new_descs(samp_mask=SAMP_BASIC | 1 << T.SAMP_MIP_LIN, clamps=True)
        slot = r.randrange(16)
        if r.getrandbits(1):
            coords = [(rcoord(r), rcoord(r), r.choice([f32(r.uniform(-4, 14)), rcoord(r), 0]))
                      for _ in range(4)]
            quad(out, r, 0, slot, descs[slot], coords, r.choice([15, r.randrange(16)]), stats)
        else:
            quad(out, r, 1, slot, descs[slot], lod_coords(r, -10, 2),
                 r.choice([15, r.randrange(16)]), stats)
    out.append('P lodclamp')
    # gather: every component, colour and depth formats, compare (DrefGather),
    # border; the footprint at level 0.
    for n in range(300):
        if n % 30 == 0:
            for s in range(16):
                descs[s] = rdesc(r, samp_mask=0x1FFF | SAMP_BORDER_MASK, clamps=r.getrandbits(1),
                                 fmt=r.randrange(4))
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        op = T.OP_TEXL | 1 << T.OPB_GATHER | r.randrange(4) << T.OPB_COMP
        if r.random() < 0.2:
            op |= 1 << T.OPB_CFORM
        coords = [(r.choice([rcoord(r), f32(r.uniform(-1.2, 2.2))]),
                   r.choice([rcoord(r), f32(r.uniform(-1.2, 2.2))]), r.getrandbits(32),
                   r.choice([f32(r.uniform(0, 1)), rcoord(r)])) for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, r.randrange(16)]), stats)
    out.append('P gather')
    # query: texqlod (the level accessed and lambda'), texsz.l (the level
    # count) and texsz.d (layers, depth) with the sampler's clamps and bias.
    for n in range(200):
        if n % 25 == 0:
            for s in range(16):
                descs[s] = rdesc(r, samp_mask=0x1FFF | SAMP_BORDER_MASK, clamps=True,
                                 typ=r.randrange(5))
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        k = r.random()
        if k < 0.5:
            quad(out, r, T.OP_TEXB | 1 << T.OPB_QUERY, slot, descs[slot], lod_coords(r, -12, 3),
                 r.choice([15, r.randrange(16)]), stats)
        else:
            op = T.OP_TEXSZ | (1 << T.OPB_QUERY if k < 0.75 else 1 << T.OPB_DEPTHQ)
            quad(out, r, op, slot, descs[slot],
                 [(r.choice([r.randrange(16), r.getrandbits(32)]), r.getrandbits(32),
                   r.getrandbits(32)) for _ in range(4)],
                 r.choice([15, r.randrange(16)]), stats)
    out.append('P query')
    # layout: the level offsets of atg_tu_desc: texf at every level of 2D
    # (linear, tiled) and 3D images, the slot written just before.
    for n in range(240):
        slot = r.randrange(16)
        typ = r.choice([0, 0, 2, 2, 1])
        d = rdesc(r, typ=typ, cnt=r.choice([0, 1, 2, 5, 16, 33, 300, r.getrandbits(16)]))
        d[T.D_SIZE] = (r.choice([1, 2, 3, 7, 16, 64, 129, 1000, r.getrandbits(16)]) << 16 |
                       r.choice([1, 2, 5, 8, 31, 64, 256, 4096, r.getrandbits(16)]))
        d[T.D_IMAGE] = (d[T.D_IMAGE] & ~15) | r.choice([13, 13, 9, r.randrange(16)])
        descs[slot] = d
        if r.random() < 0.5:
            set_desc(out, slot, d)
        else:
            for k in (T.D_SIZE, T.D_IMAGE, T.D_BASE):
                out.append('S %03x %08x' % (S_TU + 16 * slot + k, d[k]))
            for k in (T.D_STRIDE, T.D_SAMPLER, T.D_LOD):
                out.append('S %03x %08x' % (S_TU + 16 * slot + k, d[k]))
        for _ in range(2):
            coords = [(r.randrange(0, 4), r.randrange(0, 4), r.randrange(0, 14),
                       0, r.randrange(0, 4)) for _ in range(4)]
            quad(out, r, 2, slot, d, coords, 15, stats)
    out.append('P layout')
    # array: the layer (RNE, clamped), its stride; texl, texb, gather, compare,
    # texf, texsz.d.
    for n in range(300):
        if n % 30 == 0:
            for s in range(16):
                descs[s] = rdesc(r, typ=1, samp_mask=0x1FFF | SAMP_BORDER_MASK,
                                 cnt=r.choice([0, 1, 2, 3, 6, 7, 64, 300]), fmt=r.randrange(4))
                set_desc(out, s, descs[s])
        slot = r.randrange(16)
        cnt = T.count(descs[slot])
        op = r.choice([0, 0, 1, 1, 2, 0x08 | r.randrange(4) << 4, 0x0C, 4, 5, 3 | 1 << 3])
        coords = lod_coords(r, -10, 1)
        if op & 3 == 2:
            coords = [(r.randrange(-2, 40) & T.M32, r.randrange(-2, 40) & T.M32,
                       r.randrange(-1, 14) & T.M32, 0,
                       r.choice([r.randrange(-2, cnt + 2), r.getrandbits(32)]) & T.M32)
                      for _ in range(4)]
        else:
            coords = [c[:4] + (layer_coord(r, cnt),) for c in coords]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats)
    out.append('P array')
    # volume: 3D images: the slice, 3D linear and mip linear (up to four
    # passes), the w address mode, texb's w derivative, texf, gather.
    p4 = stats.get('np4', 0)
    for n in range(400):
        if n % 25 == 0:
            for s in range(16):
                d = rdesc(r, typ=2, samp_mask=0xFF | SAMP_BORDER_MASK | 1 << T.SAMP_MIP_LIN,
                          cnt=r.choice([0, 1, 2, 3, 4, 5, 8, 16, 33, 64]))
                d[T.D_SIZE] = (r.choice([1, 2, 3, 8, 16, 33]) << 16 |
                               r.choice([1, 2, 5, 8, 16, 64]))
                if r.random() < 0.7:
                    d[T.D_SAMPLER] |= 3 << T.SAMP_MAG_LIN
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        op = r.choice([0, 0, 0, 1, 1, 2, 0x08])
        if op == 2:
            coords = [(r.randrange(-2, 40) & T.M32, r.randrange(-2, 40) & T.M32,
                       r.randrange(-1, 8) & T.M32, 0, r.randrange(-2, 70) & T.M32)
                      for _ in range(4)]
        elif op == 1:
            coords = lod_coords(r, -8, 1, third='w')
        else:
            coords = [(rcoord(r), rcoord(r), r.choice([f32(r.uniform(-1, 7)), 0,
                                                       f32(r.randrange(0, 1536) / 256.0)]),
                       0, r.choice([rcoord(r), f32(r.uniform(-1.2, 2.2))])) for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats,
             off=r.choice([0, 0, r.getrandbits(12)]))
    assert stats.get('np4', 0) - p4 > 30, stats
    out.append('P volume')
    # cube: the face, the face coordinates, edges and corners (bilinear),
    # texb's LOD on lane 0's face, gather, compare, texqlod.
    for n in range(400):
        if n % 25 == 0:
            for s in range(16):
                d = rdesc(r, typ=3, samp_mask=0x1FFF | SAMP_BORDER_MASK, square=True,
                          fmt=r.choice([0, 1, 0, 2, 3]))
                d[T.D_SIZE] = r.choice([1, 2, 3, 4, 8, 16, 64, 1024]) * 0x10001
                if r.random() < 0.6:
                    d[T.D_SAMPLER] |= 3 << T.SAMP_MAG_LIN
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        op = r.choice([0, 0, 0, 1, 1, 0x08 | r.randrange(4) << 4, 4, 0x41, 0x0C, 5, 2])
        quad(out, r, op, slot, descs[slot], cube_coords(r, r.choice([-14, -8]), -1),
             r.choice([15, 15, r.randrange(16)]), stats, off=r.getrandbits(12))
    out.append('P cube')
    # offset: texel offsets on texl, texb, texf and gather, every address mode
    # on small and larger levels.
    for n in range(400):
        if n % 25 == 0:
            for s in range(16):
                d = rdesc(r, samp_mask=0xFF | SAMP_BORDER_MASK | 1 << T.SAMP_MIP_LIN)
                d[T.D_SIZE] = (r.choice([1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 100]) << 16 |
                               r.choice([1, 2, 3, 4, 6, 7, 8, 13, 16, 31, 64]))
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 2, 0x08 | r.randrange(4) << 4])
        if op == 2:
            coords = [(r.randrange(-12, 40) & T.M32, r.randrange(-12, 40) & T.M32,
                       r.randrange(-1, 6) & T.M32) for _ in range(4)]
        elif op == 1:
            coords = lod_coords(r, -8, 1)
        else:
            coords = [(r.choice([rcoord(r), f32(r.uniform(-3, 3))]),
                       r.choice([rcoord(r), f32(r.uniform(-3, 3))]),
                       r.choice([0, f32(r.uniform(-1, 6))])) for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats,
             off=r.choice([r.getrandbits(12), 0x777, 0x888, 0x878, 0x787]))
    out.append('P offset')
    # unnorm: unnormalized coordinates (texel units, level 0, the mag filter,
    # repeat and mirror read as clamp to edge), every op.
    for n in range(240):
        if n % 30 == 0:
            for s in range(16):
                d = rdesc(r, samp_mask=0x1FFF | SAMP_BORDER_MASK | 1 << T.SAMP_MIP_LIN,
                          samp_set=1 << T.SAMP_UNNORM, typ=r.randrange(4), clamps=r.getrandbits(1),
                          fmt=r.choice([0, 1, 2, 3, 0]))
                d[T.D_SIZE] = (r.choice([1, 2, 3, 8, 16, 100]) << 16 |
                               r.choice([1, 2, 5, 8, 16, 64]))
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        op = r.choice([0, 0, 1, 2, 0x08 | r.randrange(4) << 4, 0x41, 4])
        coords = [(r.choice([f32(r.uniform(-3, 110)), rcoord(r), f32(r.randrange(-2, 20) + 0.5)]),
                   r.choice([f32(r.uniform(-3, 70)), rcoord(r)]),
                   r.choice([0, f32(r.uniform(-1, 6))])) for _ in range(4)]
        if op == 2:
            coords = [(r.randrange(-2, 20) & T.M32, r.randrange(-2, 20) & T.M32, 0)
                      for _ in range(4)]
        quad(out, r, op, slot, descs[slot], coords, r.choice([15, 15, r.randrange(16)]), stats,
             off=r.choice([0, r.getrandbits(12)]))
    out.append('P unnorm')
    print('tu-vectors: addr passes %s' % {k: v for k, v in stats.items() if k[:2] == 'np'})
    return out


def ms_addr_vectors(r):
    """The multisampled images and RGB565 (a separate random stream: the
    sections above stay as they were): texf of 4-sample images (2D and 2D
    array, the sample mod 4, RGBA8 and RGB565, odd widths), texsz.s and
    texsz of them, RGB565 texf (linear and tiled, levels) and texl."""
    out = []
    stats = {'border': 0, 'passes': 0}
    descs = {}
    for n in range(300):
        if n % 25 == 0:
            for s in range(16):
                ms = s < 10
                f = r.choice([0, 1, 4]) if ms else 4
                w = r.choice([1, 2, 3, 5, 7, 16, 63, 64, 100, r.randrange(1, 16382)])
                h = r.choice([1, 2, 3, 8, 47, r.randrange(1, 4000)])
                typ = r.choice([0, 0, 1]) if ms else r.choice([0, 1])
                lev = 1 if ms else r.randrange(1, 14)
                tiled = 0 if ms else r.getrandbits(1)
                cnt = r.choice([0, 1, 2, 5]) if typ == 1 else 0
                im = (lev | f << T.IMG_FMT | tiled << T.IMG_TILED | typ << T.IMG_TYPE |
                      (2 if ms else 0) << T.IMG_SAMPLES | cnt << T.IMG_COUNT)
                d = [r.getrandbits(32) & ~63, h << 16 | w, im,
                     r.choice([r.getrandbits(20) & ~63, 0x10000]),
                     r.getrandbits(19) & 0xCF, T.LOD_NONE] + [0] * 10
                descs[s] = d
                set_desc(out, s, d)
        slot = r.randrange(16)
        d = descs[slot]
        op = r.choice([2, 2, 2, 0x22, 0x4B, 3, 0x43] if slot < 10 else [2, 2, 0x22, 0, 1, 3])
        coords = []
        for _ in range(4):
            if op & 3 == 2:
                coords.append((r.choice([r.randrange(-2, 70), r.getrandbits(32)]) & T.M32,
                               r.choice([r.randrange(-2, 50), r.getrandbits(32)]) & T.M32,
                               r.choice([0, 1, 2, 3, 4, 7, r.getrandbits(32)]) & T.M32,
                               r.getrandbits(32),
                               r.choice([0, 1, 2, 5, r.getrandbits(32)]) & T.M32))
            else:
                coords.append((r.choice([0, 1, 3, r.getrandbits(32)]) & T.M32, rcoord(r),
                               r.choice([0, f32(r.uniform(-1, 6))])))
        quad(out, r, op, slot, d, coords, r.choice([15, 15, r.randrange(16)]), stats,
             off=r.choice([0, 0, r.getrandbits(12)]))
    out.append('P ms')
    return out


def ms_filter_vectors(r):
    """RGB565: texf exact (every 16-bit value's channels across the quads),
    texl and texb as RGBA8 (nearest and bilinear), gather."""
    out = []
    flt = T.Filter()

    def one(texels, wts, mask, ctl, value):
        data = flt.quad(texels, wts, ctl, mask, value)
        tx = pack([t for row in texels for t in row])
        out.append('F %0128x %032x %x %013x %032x %04x %x %0128x' %
                   (tx, pack(wts), mask, ctl, pack(value), r.getrandbits(16),
                    r.getrandbits(1), pack(data)))

    c565 = 1 << T.CTL_565
    for n in range(256):
        tex = [[(n * 256 + 64 * ln + t * 16 + r.getrandbits(4)) & 0xFFFF for t in range(4)]
               for ln in range(4)]
        one(tex, [0] * 4, 15, c565 | 1 << T.CTL_TEXF, [0] * 4)
    for n in range(200):
        tex = [[r.getrandbits(16) for _ in range(4)] for _ in range(4)]
        ctl = c565 | r.choice([0, 1, 1 << T.CTL_GATHER | r.randrange(4) << T.CTL_COMP])
        one(tex, [r.getrandbits(16) for _ in range(4)], r.choice([15, r.randrange(16)]), ctl,
            [0] * 4)
    out.append('P rgb565')
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
            out.append('H %0128x %032x %x %013x %032x' % (tx, pack(wts), mask, ctl,
                                                          pack(value)))
            return
        out.append('F %0128x %032x %x %013x %032x %04x %x %0128x' %
                   (tx, pack(wts), mask, ctl, pack(value), r.getrandbits(16),
                    r.getrandbits(1), pack(data)))

    def rwts(fl=0, fw=0):
        return [r.choice([0, 255, 128, 1, r.getrandbits(8)]) |
                r.choice([0, 255, 128, 1, r.getrandbits(8)]) << 8 |
                (r.getrandbits(8) if fl is None else fl) << 16 |
                (r.getrandbits(8) if fw is None else fw) << 24 for _ in range(4)]

    # nearest: every byte value in every channel and format, texsz, masks.
    for n in range(64):
        tex = [[(4 * n + ln) * 0x01010101 for _ in range(4)] for ln in range(4)]
        one(tex, [r.getrandbits(16)] * 4, 15, r.choice([0, 2]), [0] * 4)
    for n in range(200):
        tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
        ctl = r.choice([0, 2, 4, 6, 8, 10]) | (r.getrandbits(2) << 6)
        one(tex, [r.getrandbits(16) for _ in range(4)], r.randrange(16), ctl,
            [r.getrandbits(32) for _ in range(4)])
    out.append('P nearest')
    for n in range(400):
        tex = [[r.choice([r.getrandbits(32), 0xFFFFFFFF, 0, 0x80808080]) for _ in range(4)]
               for _ in range(4)]
        one(tex, rwts(), r.choice([15, 15, r.randrange(16)]), 1 | r.choice([0, 2]),
            [r.getrandbits(32) for _ in range(4)])
    out.append('P bilinear')
    # trilinear: the passes of mip linear and 3D linear filtering (2 to 4),
    # nearest or bilinear, weights fl and fw 0-255.
    for n in range(400):
        mask = r.choice([15, 15, r.randrange(16)])
        fm = r.choice([0, 2])
        bil = r.getrandbits(1)
        seq = r.choice([[0, 2], [0, 1], [0, 1, 2], [0, 2, 3], [0, 1, 2, 3], [0]])
        w = rwts(r.choice([None, 0, 255, 128, 1]), r.choice([None, 0, 255, 128, 1]))
        for k, pas in enumerate(seq):
            tex = [[r.choice([r.getrandbits(32), 0xFFFFFFFF, 0, 0x80808080, 0xFF000000])
                    for _ in range(4)] for _ in range(4)]
            more = k + 1 < len(seq)
            one(tex, w, mask, bil | fm | more << T.CTL_MORE | (k > 0) << T.CTL_ACC |
                (pas & 1) << T.CTL_P0 | (pas >> 1) << T.CTL_P1, [0] * 4)
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
        w = rwts(r.choice([None, 0, 255]) if tri else None, 0)
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
                   fn << T.CTL_CMP_OP | (((pas == 0) << T.CTL_MORE | pas << T.CTL_ACC |
                                          pas << T.CTL_P1) if tri else 0))
            one(tex, w, mask, ctl, dref)
    out.append('P compare')
    # gather: components of the four texels; colour, depth and compare.
    for n in range(300):
        kind = r.choice(['rgba', 'rgba', 'depth', 'cmp'])
        ctl = 1 | 1 << T.CTL_GATHER | r.randrange(4) << T.CTL_COMP | r.choice([0, 2])
        dref = [r.choice([f32(r.uniform(0, 1)), 0x7FC00000, 0, f32(1.0)]) for _ in range(4)]
        if kind == 'depth':
            ctl |= 1 << T.CTL_DEPTH
        if kind == 'cmp':
            ctl |= 1 << T.CTL_DEPTH | 1 << T.CTL_CMP | r.randrange(8) << T.CTL_CMP_OP
        tex = [[depth_word(r) if kind != 'rgba' else r.getrandbits(32) for _ in range(4)]
               for _ in range(4)]
        one(tex, rwts(), r.choice([15, 15, r.randrange(16)]), ctl,
            dref if kind == 'cmp' else [r.getrandbits(32) for _ in range(4)])
    out.append('P gather')
    # query: texqlod's two values (no fetch) and texsz.l's word.
    for n in range(200):
        tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
        q = r.getrandbits(1)
        ctl = 1 << T.CTL_SZ | q << T.CTL_QLOD
        val = [r.choice([0, 0x7FFF, 0x8000 << 16, 0xFFFF0000 | r.getrandbits(16),
                         r.getrandbits(32)]) for _ in range(4)]
        one(tex, rwts(), r.choice([15, r.randrange(16)]), ctl, val)
    out.append('P query')
    return out


# The formats of TEX_FORMAT (a third random stream: the sections above
# stay as they were).
SAMPLED = sorted(v for v, f in FM.FORMATS.items() if 'S' in f.feat.partition('|')[0])
BLOCKS = [v for v in SAMPLED if FM.info(v).block]
NONE = [91, 104, 106, 131, 157, 200, 0xFF, 1]


def rswz(r):
    """A random component swizzle (mostly identity)."""
    if r.random() < 0.5:
        return 0
    return sum(r.choice([0, 0, 1, 2, 3, 4, 5, 6, 7]) << (3 * c) for c in range(4))


def rtfmt(r, vk=None):
    if vk is None:
        vk = r.choice(SAMPLED + SAMPLED + NONE)
    st = 1 if vk == 129 and r.random() < 0.5 else r.getrandbits(1) if r.random() < 0.05 else 0
    return vk | st << T.TF_STENCIL | rswz(r) << T.TF_SWZ


def fmt_addr_vectors(r):
    """TEX_FORMAT: texel sizes of 1-16 bytes (linear; tiled only 4 bytes),
    the path and the fp32 path's fields of ta_ctl, the slots of 8- and
    16-byte texels, the row passes of 8-byte bilinear quads (with 3D and
    mip linear), gather's word, depth formats filtered without compare,
    integer formats nearest, the stencil aspect, D16 compare."""
    out = []
    stats = {'border': 0, 'passes': 0}
    descs = {}

    def new_descs(only=None, typ=None):
        for sl in range(16):
            t = typ if typ is not None else r.choice([0, 0, 0, 1, 2, 3])
            d = rdesc(r, typ=t, square=t == 3, samp_mask=0x1FFFF,
                      cnt=r.choice([0, 1, 2, 3, 5, 9]) if t in (1, 2) else 0)
            d[T.D_IMAGE] = (d[T.D_IMAGE] & ~(15 << T.IMG_FMT)) | r.randrange(16) << T.IMG_FMT
            if r.random() < 0.7:
                d[T.D_IMAGE] = (d[T.D_IMAGE] & ~15) | r.choice([1, 2, 5, 13])
            d[T.D_FORMAT] = rtfmt(r, r.choice(only) if only else None)
            descs[sl] = d
            set_desc(out, sl, d)

    def coords(op, third=None):
        if op & 3 == 2:
            return [(r.choice([r.randrange(-4, 80), r.getrandbits(32)]) & T.M32,
                     r.choice([r.randrange(-4, 80), r.getrandbits(32)]) & T.M32,
                     r.choice([r.randrange(-1, 14), 0]) & T.M32, r.getrandbits(32),
                     r.choice([r.randrange(-1, 9), 0]) & T.M32) for _ in range(4)]
        if op & 3 == 1:
            return lod_coords(r, third=third)
        return [(rcoord(r), rcoord(r), r.choice([0, f32(r.uniform(-2, 8)), rcoord(r)]),
                 r.choice([f32(r.uniform(0, 1)), rcoord(r)]),
                 r.choice([f32(r.uniform(-1, 3)), rcoord(r)])) for _ in range(4)]

    ops = [0, 0, 0, 1, 1, 2, 2, 3, 0x43, 0x0B, 0x08, 0x18, 0x28, 0x38, 0x04, 0x05, 0x41]
    for n in range(1200):
        if n % 60 == 0:
            new_descs()
        sl = r.randrange(16)
        op = r.choice(ops)
        quad(out, r, op, sl, descs[sl], coords(op, 'w'), r.choice([15, 15, r.randrange(16)]),
             stats, off=r.choice([0, 0, r.getrandbits(12)]))
    out.append('P formats')
    # 8- and 16-byte texels: slots, the row passes, 3D and mip linear.
    for n in range(600):
        if n % 40 == 0:
            new_descs([97, 97, 95, 96, 101, 102, 103, 107, 108, 109], r.choice([None, 2, 0]))
        sl = r.randrange(16)
        op = r.choice([0, 0, 1, 1, 2, 0x08, 0x18, 0x28, 0x38])
        quad(out, r, op, sl, descs[sl], coords(op, 'w'), r.choice([15, 15, r.randrange(16)]),
             stats, off=r.choice([0, r.getrandbits(12)]))
    out.append('P wide')
    # Depth formats without and with compare, D16, the stencil aspect.
    for n in range(500):
        if n % 40 == 0:
            new_descs([124, 125, 126, 129, 129])
        sl = r.randrange(16)
        op = r.choice([0, 1, 4, 5, 0x0C, 0x08, 2, 0x38])
        quad(out, r, op, sl, descs[sl], coords(op), r.choice([15, r.randrange(16)]), stats)
    out.append('P depthfmt')
    # Small 1- and 2-byte images and clamp to border, tiled bit set.
    for n in range(500):
        if n % 40 == 0:
            for sl in range(16):
                d = rdesc(r, typ=0, samp_mask=0x1FFFF, tiled=1)
                d[T.D_SIZE] = r.randrange(1, 9) | r.randrange(1, 9) << 16
                d[T.D_SAMPLER] |= 0x3F
                d[T.D_FORMAT] = rtfmt(r, r.choice([3, 4, 8, 9, 10, 13, 16, 17, 20, 21, 70, 74,
                                                   76, 124, 37, 44]))
                descs[sl] = d
                set_desc(out, sl, d)
        sl = r.randrange(16)
        op = r.choice([0, 0, 1, 2, 0x08, 0x28])
        quad(out, r, op, sl, descs[sl], coords(op), r.choice([15, r.randrange(16)]), stats,
             off=r.choice([0, r.getrandbits(12)]))
    out.append('P small')
    # The ETC2 and EAC blocks: a block per texel, the texel's position in
    # the block, the row passes of 8-byte blocks, the four passes of
    # 16-byte blocks (with mip and 3D linear), gather, arrays and cubes.
    for n in range(500):
        if n % 40 == 0:
            new_descs(BLOCKS, r.choice([None, 0, 1, 3]))
        sl = r.randrange(16)
        op = r.choice([0, 0, 1, 1, 2, 0x08, 0x18, 0x28, 0x38, 3])
        quad(out, r, op, sl, descs[sl], coords(op, 'w'), r.choice([15, 15, r.randrange(16)]),
             stats, off=r.choice([0, r.getrandbits(12)]))
    out.append('P blocks')
    print('tu-vectors: format addr passes %s' %
          {k: v for k, v in stats.items() if k[:2] == 'np'})
    return out


def rtexel(r, vk, sten):
    """A random raw texel word of a format (special values often)."""
    f = FM.info(vk)
    w = r.getrandbits(32)
    if f is not None and f.ty == FM.SFLOAT and r.random() < 0.3:
        if f.chans[0][1] == 16:
            w = pack([r.choice([0x7C00, 0xFC00, 0x7E01, 0x0001, 0x8000, 0x3C00, 0x03FF,
                                r.getrandbits(16)]) for _ in range(2)], 16)
        else:
            w = r.choice([0x7F800000, 0x7FC00001, 0x00000001, 0x80000000, f32(1.0),
                          f32(r.uniform(-1e3, 1e3)), 0x00800000])
    return w


def ffilt_vectors(r):
    """atg_tu_ffilt: every sampled format of the fp32 path (and none) with
    random texels; nearest, bilinear, the passes of mip and 3D linear
    filtering, the row passes of 8-byte texels, border texels of every
    colour class, gather with its word, the swizzle, the stencil aspect."""
    out = []
    ff = T.FFilter()

    def one(tex, bord, wts, mask, ctl, lo):
        data = ff.quad(tex, bord, wts, ctl, mask, lo)
        tx = pack([t for row in tex for t in row])
        bo = pack([b for row in bord for b in row], 1)
        lw = pack([x for row in lo for x in row], 2)
        if data is None:
            out.append('H %0128x %04x %08x %032x %x %013x' % (tx, bo, lw, pack(wts), mask, ctl))
            return
        out.append('F %0128x %04x %08x %032x %x %013x %04x %x %0128x' %
                   (tx, bo, lw, pack(wts), mask, ctl, r.getrandbits(16), r.getrandbits(1),
                    pack(data)))

    def rwts():
        return [r.choice([0, 255, 128, 1, r.getrandbits(8)]) |
                r.choice([0, 255, 128, 1, r.getrandbits(8)]) << 8 |
                r.choice([0, 255, 128, 1, r.getrandbits(8)]) << 16 |
                r.choice([0, 255, 128, 1, r.getrandbits(8)]) << 24 for _ in range(4)]

    fmts = [v for v in SAMPLED if v not in T.U8_FORMATS] + [0]
    for kind in ('nearest', 'bilinear', 'passes', 'gather', 'border'):
        for n in range(len(fmts) * (6 if kind != 'passes' else 4)):
            vk = fmts[n % len(fmts)]
            f = FM.info(vk)
            nb = f.nbytes if f else 4
            sten = int(vk == 129 and r.random() < 0.5)
            z = rswz(r)
            mask = r.choice([15, 15, r.randrange(16)])
            base = (1 << T.CTL_F32 | vk << T.CTL_VKF | sten << T.CTL_STEN | z << T.CTL_SWZ |
                    r.randrange(3) << T.CTL_BORDER |
                    {8: 1, 16: 2}.get(nb, 0) << T.CTL_NSL)
            blk = f is not None and f.block
            lin = kind in ('bilinear', 'passes') and f is not None and 'F' in f.feat and \
                (nb <= 8 or blk)
            gat = kind == 'gather'
            if gat:
                base |= 1 | 1 << T.CTL_GATHER | r.randrange(4) << T.CTL_COMP
                lin = False
            if lin:
                base |= 1
            if kind == 'passes':
                seq = r.choice([[0, 2], [0, 1], [0, 1, 2], [0, 2, 3], [0, 1, 2, 3], [0]])
            else:
                seq = [0]
            split = (lin or (gat and blk)) and nb == 8
            quad = (lin or gat) and blk and nb == 16
            if split:
                base |= 1 << T.CTL_SPLIT
                seq = [p | rw << 2 for p in seq for rw in (0, 1)]
            if quad:
                base |= 1 << T.CTL_QUAD
                seq = [p | rw << 2 | cl << 3 for p in seq for rw in (0, 1) for cl in (0, 1)]
            w = rwts()
            for k, pas in enumerate(seq):
                tex = [[rtexel(r, vk, sten) for _ in range(4)] for _ in range(4)]
                pb = 0.5 if kind == 'border' else 0.08
                bord = [[int(r.random() < pb) for _ in range(4)] for _ in range(4)]
                ctl = (base | (k + 1 < len(seq)) << T.CTL_MORE | (k > 0) << T.CTL_ACC |
                       (pas & 1) << T.CTL_P0 | (pas >> 1 & 1) << T.CTL_P1 |
                       (pas >> 2 & 1) << T.CTL_ROW | (pas >> 3) << T.CTL_COL)
                if blk:
                    tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
                lo = [[r.getrandbits(2) for _ in range(4)] for _ in range(4)]
                one(tex, bord, w, mask, ctl, lo)
        out.append('P ' + kind)
    return out


def u8_fmt_vectors(r):
    """atg_tu_filter with TEX_FORMAT: R8 and R8G8 (texels and border
    texels), D16 compare, the swizzle after filtering and compare, gather
    through the swizzle."""
    out = []
    flt = T.Filter()

    def one(texels, wts, mask, ctl, value):
        data = flt.quad(texels, wts, ctl, mask, value)
        tx = pack([t for row in texels for t in row])
        if data is None:
            out.append('H %0128x %032x %x %013x %032x' % (tx, pack(wts), mask, ctl,
                                                          pack(value)))
            return
        out.append('F %0128x %032x %x %013x %032x %04x %x %0128x' %
                   (tx, pack(wts), mask, ctl, pack(value), r.getrandbits(16),
                    r.getrandbits(1), pack(data)))

    for n in range(600):
        vk = r.choice([9, 16, 37, 44, 51, 124, 125, 126, 129])
        mask = r.choice([15, 15, r.randrange(16)])
        z = rswz(r)
        dep = vk >= 124
        ctl = (vk << T.CTL_VKF | z << T.CTL_SWZ | int(vk in (44, 126)) << T.CTL_FMT |
               r.getrandbits(1) | r.randrange(3) << T.CTL_BORDER)
        dref = [r.choice([f32(r.uniform(0, 1)), f32(r.uniform(-1, 2)), 0x7FC00000, 0,
                          f32(1.0), f32(0.5)]) for _ in range(4)]
        if dep:
            ctl |= 1 << T.CTL_DEPTH | 1 << T.CTL_CMP | r.randrange(8) << T.CTL_CMP_OP
        if r.random() < 0.25:
            ctl |= 1 | 1 << T.CTL_GATHER | r.randrange(4) << T.CTL_COMP
        tex = []
        for ln in range(4):
            row = []
            for _ in range(4):
                if vk == 124:
                    u = FM.f32_unorm(dref[ln], 16)
                    row.append(r.choice([u, max(u - 1, 0), min(u + 1, 0xFFFF),
                                         r.getrandbits(16), 0xFFFF]))
                elif vk == 9:
                    row.append(r.choice([r.getrandbits(8), 0xFFFFFFFF, 0xFF]))
                elif vk == 16:
                    row.append(r.choice([r.getrandbits(16), 0xFFFFFFFF, 0xFFFF]))
                else:
                    row.append(r.getrandbits(32))
            tex.append(row)
        wts = [r.getrandbits(16) for _ in range(4)]
        one(tex, wts, mask, ctl, dref if dep else [r.getrandbits(32) for _ in range(4)])
    out.append('P vkformat')
    return out


class HashMem:
    """The memory of atg_tu_tb: word a is (a >> 2) x 0x9E3779B1."""

    def rd32(self, a):
        return ((a >> 2) * 0x9E3779B1) & T.M32

    def rd16(self, a):
        return self.rd32(a & ~3) >> (8 * (a & 2)) & 0xFFFF

    def rd8(self, a):
        return self.rd32(a & ~3) >> (8 * (a & 3)) & 0xFF


def quad_vectors(r):
    """Whole quads through atg_tu (addressing, cache, both filter paths,
    their order): random descriptors of the earlier codes and of
    TEX_FORMAT's formats, every op."""
    out = []
    mem = HashMem()
    descs = {}
    for n in range(1500):
        if n % 50 == 0:
            for sl in range(16):
                t = r.choice([0, 0, 1, 2, 3])
                d = rdesc(r, typ=t, square=t == 3, samp_mask=0x1FFFF,
                          cnt=r.choice([0, 1, 2, 5]) if t in (1, 2) else 0)
                d[T.D_BASE] &= 0x00FFFFC0
                d[T.D_STRIDE] &= 0xFFFC0
                d[T.D_SIZE] = r.randrange(1, 40) | r.randrange(1, 40) << 16
                if t == 3:	# a cube's faces are squares (docs/ghci.md section 8.4)
                    d[T.D_SIZE] = (d[T.D_SIZE] & 0xFFFF) * 0x10001
                if r.random() < 0.6:
                    d[T.D_FORMAT] = rtfmt(r, r.choice(SAMPLED + [91]))
                descs[sl] = d
                set_desc(out, sl, d)
        sl = r.randrange(16)
        d = descs[sl]
        op = r.choice([0, 0, 0, 1, 1, 2, 3, 0x08, 0x28, 0x0C, 0x41])
        if op & 3 == 2:
            coords = [(r.randrange(-2, 42) & T.M32, r.randrange(-2, 42) & T.M32,
                       r.randrange(0, 3), 0, r.randrange(0, 4)) for _ in range(4)]
        elif op & 3 == 1:
            coords = lod_coords(r, -8, 0, third='w')
        else:
            coords = [(f32(r.uniform(-1, 2)), f32(r.uniform(-1, 2)), f32(r.uniform(-1, 4)),
                       f32(r.uniform(0, 1)), f32(r.uniform(0, 3))) for _ in range(4)]
        mask = r.choice([15, 15, r.randrange(16)])
        off = r.choice([0, 0, r.getrandbits(12)])
        coords = [tuple(c) + (0,) * (5 - len(c)) for c in coords]
        words = T.sample(mem, op, d, coords, mask, off)
        out.append('Q %02x %x %x %03x %0160x %0128x' %
                   (op, sl, mask, off, pack([w for c in coords for w in c]), pack(words)))
    out.append('P quads')
    return out


def ffilt_checks(r):
    """The fp32 path against plain floating point: bilinear weights sum to
    1, the result is within 2^-20 of the exact blend of the converted
    texels (finite values), sRGB is decoded before filtering."""
    def fl(b):
        return struct.unpack('<f', struct.pack('<I', b))[0]
    ff = T.FFilter()
    for _ in range(3000):
        vk = r.choice([4, 8, 3, 38, 43, 50, 64, 76, 83, 97, 122, 123, 124, 126])
        f = FM.info(vk)
        tex = [[r.getrandbits(32) for _ in range(4)] for _ in range(4)]
        if f.ty == FM.SFLOAT:
            tex = [[f32(r.uniform(-4, 4)) if f.chans[0][1] == 32 else
                    pack([struct.unpack('<H', struct.pack('<e', r.uniform(-4, 4)))[0]
                          for _ in range(2)], 16) for _ in range(4)] for _ in range(4)]
        wts = [r.getrandbits(16) for _ in range(4)]
        nb = f.nbytes
        if nb == 8:
            continue
        ctl = 1 | 1 << T.CTL_F32 | vk << T.CTL_VKF
        data = ff.quad(tex, [[0] * 4] * 4, wts, ctl, 15)
        for ln in range(4):
            fu, fv = wts[ln] & 0xFF, wts[ln] >> 8
            w = [(256 - fu) * (256 - fv), fu * (256 - fv), (256 - fu) * fv, fu * fv]
            vals = [FM.unpack(t, vk)[0] for t in tex[ln]]
            for c in range(len(f.chans)):
                xs = [fl(vals[t][c]) for t in range(4)]
                if not all(math.isfinite(x) and abs(x) < 1e30 for x in xs):
                    continue
                want = sum(w[t] * xs[t] for t in range(4)) / 65536.0
                got = fl(data[ln * 4 + c])
                assert abs(got - want) <= 2.0 ** -20 * max(1.0, abs(want)), (vk, ln, c, got, want)


def model_checks(r):
    """The model against plain floating point: the cube face coordinates,
    the seamless footprint (its texels' centres next to the direction), the
    integer wrap with offsets (Vulkan's formulas on u x size), the layer."""
    def fl(b):
        return struct.unpack('<f', struct.pack('<I', b))[0]
    for _ in range(3000):
        fv = [f32(r.uniform(-3, 3)) for _ in range(3)]
        v = [fl(x) for x in fv]
        face, s, t = T.cube_proj(*fv)
        (ma, ms), (sa, ss), (ta, ts) = T.CUBE_FACES[face]
        assert (v[ma] >= 0) == (ms > 0) and abs(v[ma]) == max(abs(x) for x in v), (v, face)
        assert abs(s / 2.0 ** 24 - (ss * v[sa] / abs(v[ma]) + 1) / 2) < 2e-6, (v, s)
        assert abs(t / 2.0 ** 24 - (ts * v[ta] / abs(v[ma]) + 1) / 2) < 2e-6, (v, t)

    def tex_dir(face, i, j, n):
        (ma, ms), (sa, ss), (ta, ts) = T.CUBE_FACES[face]
        d = [0.0] * 3
        d[ma] = ms
        d[sa] += ss * (2 * (i + 0.5) / n - 1)
        d[ta] += ts * (2 * (j + 0.5) / n - 1)
        n2 = math.sqrt(sum(x * x for x in d))
        return [x / n2 for x in d]
    for _ in range(3000):
        n = r.choice([2, 3, 4, 8, 16])
        (ma, ms), (sa, ss), (ta, ts) = T.CUBE_FACES[r.randrange(6)]
        v = [0.0] * 3
        v[ma], v[sa], v[ta] = ms, ss * r.uniform(-1, 1), ts * r.uniform(-1, 1)
        fc, s, t = T.cube_proj(*[f32(x) for x in v])
        i0, j0 = ((s * n >> 16) - 128) >> 8, ((t * n >> 16) - 128) >> 8
        vn = [x / math.sqrt(sum(y * y for y in v)) for x in v]
        for i, j in ((i0, j0), (i0 + 1, j0), (i0, j0 + 1), (i0 + 1, j0 + 1)):
            dd = tex_dir(*T.cube_texel(fc, i, j, n), n)
            ang = math.acos(max(-1.0, min(1.0, sum(a * b for a, b in zip(dd, vn)))))
            assert ang * n < 2.8, (v, n, i, j)
    for _ in range(20000):
        n = r.choice([1, 2, 3, 5, 7, 8, 9, 16, 17, 100])
        mode, du, lin = r.randrange(4), r.randrange(-8, 8), r.getrandbits(1)
        u = fl(f32(r.uniform(-5, 5)))
        x = u * n - 0.5 * lin
        if min(x % 1, 1 - x % 1) < 1e-4:
            continue
        c = T.axis_c(f32(u), mode, n, 0) - 128 * lin
        for k in range(1 + lin):
            i = math.floor(x) + du + k
            if mode == T.WRAP_REPEAT:
                want = (i % n, 0)
            elif mode == T.WRAP_MIRROR:
                m = i % (2 * n)
                want = (m if m < n else 2 * n - 1 - m, 0)
            else:
                want = (min(max(i, 0), n - 1), int(mode == T.WRAP_BORDER and not 0 <= i < n))
            assert T.wrap_idx((c >> 8) + du + k, n, mode) == want, (n, mode, u, du, lin)
    for _ in range(3000):
        a, cnt = fl(f32(r.choice([r.uniform(-2, 40), r.randrange(40) + 0.5]))), r.randrange(1, 40)
        assert T.rne_layer(f32(a), cnt) == min(max(round(a), 0), cnt - 1), (a, cnt)


def main():
    r = random.Random(288009)
    model_checks(r)
    ffilt_checks(random.Random(288031))
    # The filter's exactness for nearest texels: c << 16 is c / 255 rounded.
    for c in range(256):
        assert T.conv(c << 16) == f32(c / 255.0), c
        assert T.conv40(c << 32) == T.conv(c << 16), c
    # unorm24 to fp32 is the correctly rounded c / (2^24 - 1): checked for
    # every c once (2 minutes); here the ends and a sample.
    for c in list(range(300)) + [r.randrange(1 << 24) for _ in range(3000)] + \
            list(range((1 << 24) - 300, 1 << 24)):
        assert T.conv24(c) == RX.round_f32(Fraction(c, (1 << 24) - 1)), c
    # RGB565's texf is the correctly rounded c / 31, c / 63.
    for c in range(64):
        s5 = sum(1 << (5 * i) for i in range(16))
        s6 = sum(1 << (6 * i) for i in range(13))
        if c < 32:
            assert T.rnd_f32(c * s5, 80) == RX.round_f32(Fraction(c, 31)), c
        assert T.rnd_f32(c * s6, 78) == RX.round_f32(Fraction(c, 63)), c
    os.makedirs(VEC, exist_ok=True)
    r2 = random.Random(288027)
    r3 = random.Random(288030)
    for name, lines in (('tu_addr.txt', addr_vectors(r) + ms_addr_vectors(r2) +
                         fmt_addr_vectors(r3)),
                        ('tu_filter.txt', filter_vectors(r) + ms_filter_vectors(r2) +
                         u8_fmt_vectors(r3)),
                        ('tu_ffilt.txt', ffilt_vectors(r3)),
                        ('tu_quad.txt', quad_vectors(r3))):
        with open(os.path.join(VEC, name), 'w') as fp:
            fp.write('\n'.join(lines) + '\n')
        print('tu-vectors: %d lines -> sim/vec/%s' % (len(lines), name))


if __name__ == '__main__':
    main()
