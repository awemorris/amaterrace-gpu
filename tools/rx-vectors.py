#!/usr/bin/env python3
# rx-vectors.py: writes the expected-value files of the RX and ROP unit
# testbenches into sim/vec/ from the reference model (tools/rxmodel.py).
# The files are in git; run this after changing the model or the cases,
# and check that `git diff sim/vec` shows only what was meant.
#   tools/rx-vectors.py
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')


def f(x):
    return M.f2b(x)


def hexw(v, bits):
    return '%0*x' % ((bits + 3) // 4, v & ((1 << bits) - 1))


def put(name, lines):
    os.makedirs(VEC, exist_ok=True)
    with open(os.path.join(VEC, name), 'w') as fp:
        for ln in lines:
            fp.write(ln + '\n')
    print('rx-vectors: %s (%d lines)' % (name, len(lines)))


def rnd_fp(r):
    k = r.random()
    if k < 0.15:
        return r.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7FA00001,
                         0x00000001, 0x807FFFFF, 0x00800000, 0x7F7FFFFF, 0xFF7FFFFF, M.ONE,
                         0xBF800000, 0x3F7FFFFF])
    if k < 0.45:
        return r.getrandbits(32)
    if k < 0.8:
        return f(r.uniform(-4096.0, 4096.0))
    e = r.choice([1, 2, 3, 125, 126, 127, 128, 252, 253, 254])
    return (r.getrandbits(1) << 31) | (e << 23) | r.getrandbits(23)


def fp_vectors(r):
    ops = (M.fadd, M.fsub, M.fmul, M.fdiv)
    out = []
    for n in range(6000):
        a = rnd_fp(r)
        b = rnd_fp(r)
        if n % 5 == 0:
            # near cancellation
            b = (a ^ 0x80000000) + r.randint(-3, 3) & M.M32
        op = n % 4
        out.append('%x %08x %08x %08x' % (op, a, b, ops[op](a, b)))
    return out


def st_default():
    st = M.State()
    # viewport 640x480, z [0, 1]
    for k, v in enumerate((320.0, 240.0, 320.0, 240.0, 1.0, 0.0)):
        st.set(M.S_VIEWPORT + k, f(v))
    st.set(M.S_RT_SIZE, (480 << 16) | 640)
    return st


def rnd_raw(r, w=640, h=480, big=False):
    span = 2000.0 if big else 1.0
    words = []
    for _ in range(3):
        if big:
            x, y = r.uniform(-span, w + span), r.uniform(-span, h + span)
        else:
            x, y = r.uniform(-20, w + 20), r.uniform(-20, h + 20)
        words += [f(x), f(y), f(r.uniform(0.0, 1.0))]
    return words


def rnd_small_raw(r, cx, cy, s):
    words = []
    for _ in range(3):
        words += [f(cx + r.uniform(-s, s)), f(cy + r.uniform(-s, s)), f(r.uniform(0.0, 1.0))]
    return words


def rnd_clip_tri(r, near_mix=True):
    pos = []
    for _ in range(3):
        w = r.uniform(0.5, 4.0)
        z = r.uniform(-1.0, 1.0) * w if near_mix else r.uniform(0.01, 1.0) * w
        pos.append([f(r.uniform(-1.2, 1.2) * w), f(r.uniform(-1.2, 1.2) * w), f(z), f(w)])
    return pos


def setup_vectors(r):
    """atg_rx_setup: per case one line of STATE words then cl_tri then sp_tri."""
    out = []
    cases = []
    st = st_default()
    for n in range(160):
        st = st_default()
        st.set(M.S_CULL, [0, 1, 2, 3, 4, 5, 6, 7][n % 8] if n >= 40 else 0)
        if n % 7 == 3:
            st.set(M.S_SCISSOR_MIN, (100 << 16) | 50)
            st.set(M.S_SCISSOR_MAX, (300 << 16) | 400)
        if n < 60:
            tri = M.raw_tri(rnd_raw(r, big=(n % 6 == 5)) if n % 3 else
                            rnd_small_raw(r, r.uniform(0, 640), r.uniform(0, 480), 6.0))
        else:
            pos = rnd_clip_tri(r, near_mix=False)
            wt = [[f(r.uniform(0, 1)) for _ in range(3)] for _ in range(3)]
            tri = {'pos': pos, 'wt': wt, 'pt': [r.randrange(256) for _ in range(3)],
                   'free': r.randrange(8), 'raw': 0}
        if n == 7:
            # zero area
            tri = M.raw_tri([f(10.0), f(10.0), 0, f(20.0), f(20.0), 0, f(30.0), f(30.0), 0])
        cases.append((st, tri))
    for st, tri in cases:
        sp = M.pack_sp(M.setup(st, tri))
        words = [st[M.S_VIEWPORT + k] for k in range(6)] + [st[M.S_SCISSOR_MIN],
                 st[M.S_SCISSOR_MAX], st[M.S_CULL], st[M.S_RT_SIZE]]
        out.append(' '.join('%08x' % w for w in words) + ' ' + hexw(M.pack_cl(tri), 700) +
                   ' ' + hexw(sp, 768))
    return out


def scan_vectors(r):
    """atg_rx_scan: per triangle the sp_tri line, then its quads."""
    out = []
    st = st_default()
    st.set(M.S_RT_SIZE, (96 << 16) | 128)
    tris = []
    for n in range(40):
        if n % 4 == 0:
            words = rnd_raw(r, 128, 96)
        else:
            words = rnd_small_raw(r, r.uniform(0, 128), r.uniform(0, 96), r.choice([1.5, 4.0, 12.0]))
        tris.append(M.raw_tri(words))
    # empty and culled ones
    tris.append(M.raw_tri([f(10.0), f(10.0), 0, f(20.0), f(20.0), 0, f(30.0), f(30.0), 0]))
    tris.append(M.raw_tri([f(-50.0), f(-50.0), 0, f(-40.0), f(-50.0), 0, f(-45.0), f(-40.0), 0]))
    # vertices on pixel centres: shared edges through samples (top-left rule);
    # each split quadrilateral covers each pixel once
    for (ax, ay, bx, by, cx, cy, dx, dy) in ((2.5, 2.5, 20.5, 2.5, 20.5, 20.5, 2.5, 20.5),
                                             (40.5, 10.5, 60.5, 30.5, 40.5, 50.5, 20.5, 30.5),
                                             (70.5, 5.5, 100.5, 15.5, 90.5, 40.5, 75.5, 30.5)):
        t1 = M.raw_tri([f(ax), f(ay), 0, f(bx), f(by), 0, f(dx), f(dy), 0])
        t2 = M.raw_tri([f(bx), f(by), 0, f(cx), f(cy), 0, f(dx), f(dy), 0])
        seen = {}
        for t in (t1, t2):
            for (qx, qy, mask, z) in M.scan(M.setup(st, t)):
                for ln in range(4):
                    if mask >> ln & 1:
                        p = (qx + (ln & 1), qy + (ln >> 1))
                        assert p not in seen, ('double coverage', p)
                        seen[p] = 1
        tris += [t1, t2]
    # a sliver: one covered quad or none
    tris.append(M.raw_tri([f(5.5), f(5.5), 0, f(5.6), f(5.5), 0, f(5.5), f(5.6), 0]))
    for i, tri in enumerate(tris):
        tri['pt'] = [i, i + 1, i + 2]
        tri['free'] = i & 7
        rs = M.setup(st, tri)
        rs['raw'] = i & 1	# the scan frees PT entries of non-raw ones
        quads = M.scan(rs)
        out.append('T %s %d' % (hexw(M.pack_sp(rs), 768), len(quads)))
        for k, (x, y, mask, z) in enumerate(quads):
            out.append('Q %04x %04x %x %d %08x %08x %08x %08x' %
                       (x, y, mask, 1 if k == len(quads) - 1 else 0, z[0], z[1], z[2], z[3]))
    out.append('E')
    return out


def clip_vectors(r):
    """atg_rx_clip: per primitive the 3 PT vertices (xyzw), entries and
    flags, then the expected cl_tri words."""
    out = []
    for n in range(60):
        pos = rnd_clip_tri(r)
        if n < 4:
            # all inside, all outside, one, two
            for i in range(3):
                z = M.b2f(pos[i][2])
                inside = [[1, 1, 1], [0, 0, 0], [1, 0, 0], [0, 1, 1]][n][i]
                pos[i][2] = f(abs(z) + 0.01) if inside else f(-abs(z) - 0.01)
        pt = r.sample(range(256), 3)
        free = r.randrange(8)
        tris = M.clip(pos, pt, free)
        out.append('P %s %02x %02x %02x %x %d' % (' '.join('%08x' % w for v in pos for w in v),
                                                   pt[0], pt[1], pt[2], free, len(tris)))
        for t in tris:
            out.append('C %s' % hexw(M.pack_cl(t), 700))
    for n in range(4):
        words = rnd_raw(r)
        out.append('R %s' % ' '.join('%08x' % w for w in words))
        out.append('C %s' % hexw(M.pack_cl(M.raw_tri(words)), 700))
    out.append('E')
    return out


def blend_vectors(r):
    """atg_rop_blend: STATE words, 4 sources, 4 destinations, mask, result."""
    out = []
    for n in range(3000):
        st = M.State()
        fmt = n % 3
        bl = r.getrandbits(23) | 1 if n % 7 else 0
        if n % 5 == 0:	# source-over, the common case
            bl = 1 | (6 << 1) | (7 << 5) | (1 << 12) | (7 << 16)
        st.set(M.S_RT_FORMAT, fmt)
        st.set(M.S_BLEND, bl)
        st.set(M.S_BLEND_CONST, r.getrandbits(32))
        st.set(M.S_WRITE_MASK, 15 if n % 3 else r.getrandbits(4))
        src = []
        for _ in range(4):
            px = []
            for _ in range(4):
                k = r.random()
                if k < 0.1:
                    px.append(r.choice([0, 0x80000000, M.ONE, 0x7FC00000, 0x7F800000, 0xBF800000,
                                        0x3F7FFFFF, 0x3B800000, 0x3A800000, 0x00400000]))
                elif k < 0.2:
                    px.append(M.UNORM8[r.randrange(256)])
                else:
                    px.append(f(r.uniform(-0.1, 1.1)))
            src.append(px)
        dst = [r.getrandbits(32 if fmt < 2 else 16) for _ in range(4)]
        mask = r.getrandbits(4)
        res = [M.blend_pixel(st, src[ln], dst[ln]) if mask >> ln & 1 else dst[ln] for ln in range(4)]
        out.append('%x %06x %08x %x %s %s %x %s' % (
            fmt, bl, st[M.S_BLEND_CONST], st[M.S_WRITE_MASK],
            ' '.join('%08x' % w for px in src for w in px), ' '.join('%08x' % d for d in dst),
            mask, ' '.join('%08x' % p for p in res)))
    return out


DS_BASE = 0x1000
DS_STRIDE = 64	# 16 pixels


def ds_vectors(r):
    """atg_rop_ds: per run the STATE (DEPTH, DEBUG_COLOR), the initial
    16x16 buffer at DS_BASE, then quads 'Q x y mask z0..z3 pass', then the
    final buffer."""
    out = []
    runs = [(f32, func, wr) for f32 in (1, 0) for func in range(8) for wr in (1, 0)]
    runs += [(1, 1, 1)] * 4 + [(0, 3, 1)] * 2
    for n, (f32, func, wr) in enumerate(runs):
        st = M.State()
        st.set(M.S_DS_BASE, DS_BASE)
        st.set(M.S_DS_STRIDE, DS_STRIDE)
        test = 0 if n == len(runs) - 1 else 1
        st.set(M.S_DEPTH, test | (wr << 1) | (func << 2) | (0x40 if f32 else 0x20))
        st.set(M.S_DEBUG_COLOR, r.getrandbits(32))
        mem = M.Mem()
        init = []
        for i in range(256):
            v = f(r.uniform(0, 1)) if f32 else r.getrandbits(32)
            if r.random() < 0.05:
                v = r.choice([0, M.ONE, 0x7FC00000, 0x80000000]) if f32 else v
            mem.wr32(DS_BASE + 4 * i, v)
            init.append(v)
        out.append('R %02x %08x %s' % (st[M.S_DEPTH], st[M.S_DEBUG_COLOR],
                                       ' '.join('%08x' % v for v in init)))
        for k in range(60):
            x, y = 2 * r.randrange(8), 2 * r.randrange(8)
            mask = r.getrandbits(4)
            z = []
            for _ in range(4):
                if r.random() < 0.15:
                    # equal to what is stored, or the same z twice
                    z.append(mem.rd32(DS_BASE + 4 * (x + y * 16)) if f32 else f(0.5))
                else:
                    z.append(f(r.uniform(0, 1)))
            p = M.ds_quad(st, mem, x, y, mask, z)
            out.append('Q %04x %04x %x %s %x' % (x, y, mask, ' '.join('%08x' % v for v in z), p))
        out.append('F %s' % ' '.join('%08x' % mem.rd32(DS_BASE + 4 * i) for i in range(256)))
    out.append('E')
    return out


RT_BASE = 0x2000


def wb_vectors(r):
    """atg_rop_wb + atg_rop_blend: per run the STATE (RT_FORMAT, BLEND,
    BLEND_CONST, WRITE_MASK, RT_STRIDE), the initial 32x16 target at
    RT_BASE, quads 'Q x y mask colour x 16', and the final target."""
    out = []
    runs = []
    for fmt in (0, 1, 2):
        runs.append((fmt, 0, 15))	# plain writes
        runs.append((fmt, 1 | (6 << 1) | (7 << 5) | (1 << 12) | (7 << 16), 15))	# source-over
        runs.append((fmt, r.getrandbits(23) | 1, 15))
        runs.append((fmt, 0, r.choice([1, 2, 4, 8, 5, 0])))	# partial WRITE_MASK
    for n, (fmt, bl, wm) in enumerate(runs):
        st = M.State()
        ps = 2 if fmt == 2 else 4
        st.set(M.S_RT_BASE, RT_BASE)
        st.set(M.S_RT_STRIDE, 32 * ps)
        st.set(M.S_RT_FORMAT, fmt)
        st.set(M.S_BLEND, bl)
        st.set(M.S_BLEND_CONST, r.getrandbits(32))
        st.set(M.S_WRITE_MASK, wm)
        mem = M.Mem()
        init = [r.getrandbits(8 * ps) for _ in range(32 * 16)]
        for i, v in enumerate(init):
            (mem.wr16 if ps == 2 else mem.wr32)(RT_BASE + ps * i, v)
        out.append('R %x %06x %08x %x %x %s' % (fmt, bl, st[M.S_BLEND_CONST], wm, 32 * ps,
                                               ' '.join('%08x' % v for v in init)))
        for k in range(80):
            # mostly walking along rows, sometimes jumping
            if k % 10 == 0:
                x, y = 2 * r.randrange(16), 2 * r.randrange(8)
            else:
                x = (x + 2) % 32
            mask = r.getrandbits(4) | (1 if k % 3 == 0 else 0)
            col = [[f(r.uniform(-0.05, 1.05)) for _ in range(4)] for _ in range(4)]
            for ln in range(4):
                if mask >> ln & 1:
                    a = RT_BASE + ((y + (ln >> 1)) * 32 + x + (ln & 1)) * ps
                    d = mem.rd16(a) if ps == 2 else mem.rd32(a)
                    p = M.blend_pixel(st, col[ln], d)
                    (mem.wr16 if ps == 2 else mem.wr32)(a, p)
            out.append('Q %04x %04x %x %s' % (x, y, mask, ' '.join('%08x' % w for c in col for w in c)))
        fin = [(mem.rd16 if ps == 2 else mem.rd32)(RT_BASE + ps * i) for i in range(32 * 16)]
        out.append('F %s' % ' '.join('%08x' % v for v in fin))
    out.append('E')
    return out


def main():
    r = random.Random(288007)
    put('rx_fp.hex', fp_vectors(r))
    put('rx_setup.txt', setup_vectors(r))
    put('rx_scan.txt', scan_vectors(r))
    put('rx_clip.txt', clip_vectors(r))
    put('rop_blend.txt', blend_vectors(r))
    put('rop_ds.txt', ds_vectors(r))
    put('rop_wb.txt', wb_vectors(r))


if __name__ == '__main__':
    main()
