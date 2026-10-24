#!/usr/bin/env python3
# msmodel.py: the reference model of 4x multisampling (docs/ghci.md section
# 12.11) for the testbenches: the rasterizer's sample coverage, the sample
# mask test, the fragment inputs r6-r9 and the per-sample depth slopes, the
# render output's per-sample operations (depth per sample, alpha to
# coverage, alpha to one, depth test and colour write per sample in the
# sample-interleaved layout), and the blitter's RESOLVE (section 8.2).  It
# is written from the formulas of the specification, on top of rxmodel.py
# (the same fp32 rules); rxmodel's single-sample functions are unchanged.
#
# Library use:
#   import msmodel as MS
#   quads = MS.scan_ms(r, ms4, kill)        r = rxmodel.setup(...)
#   lanes = MS.frag_lane_ms(r, x, y, ...)   r0-r9 of a lane
#   MS.rop_quad_ms(st, mem, x, y, smask, z, colors, zexp, zout, ds)
#   MS.resolve(mem, blt)                    blt: dict of the BLT STATE words
# Self-check: python3 -I tools/msmodel.py --selftest  ->  PASS msmodel.selftest
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402

S = 4
# Sample offsets from the pixel centre in subpixels (1/256 pixel), sample
# order 0..3.  Values referenced: Vulkan specification, Multisampling,
# standard sample locations (VK_SAMPLE_COUNT_4_BIT).
OFS = [(-32, -96), (96, -32), (-96, 32), (32, 96)]
LOC = [(0.375, 0.125), (0.875, 0.375), (0.125, 0.625), (0.625, 0.875)]
DXF = [M.f2b(dx / 256.0) for dx, _ in OFS]
DYF = [M.f2b(dy / 256.0) for _, dy in OFS]

S_MS_CTRL = 0x05E
S_SAMPLE_KILL = 0x05F

# ---------------------------------------------------------------- RX


def ms_log2(st):
    """MS_CTRL[3:0]: 2 means 4 samples, every other value 1 sample."""
    return 2 if st[S_MS_CTRL] & 15 == 2 else 0


def _edge(r, x, y, ox, oy):
    """True when the point (pixel (x, y) centre + (ox, oy) subpixels) is
    inside every edge (the edge test of atg_rx_scan, with the offset)."""
    bx0, by0 = r['bbox'][0], r['bbox'][1]
    for (A, B, E) in r['edges']:
        if E + 256 * (A * (x - bx0) + B * (y - by0)) + A * ox + B * oy < 0:
            return False
    return True


def scan_ms(r, ms4, kill):
    """The quads of a set-up triangle with sample coverage:
    list of (qx, qy, scov, ccov), scov bit 4 l + s = sample s of lane l
    covered after the sample mask test (kill = SAMPLE_KILL[3:0]), ccov bit
    l = the pixel centre of lane l inside the triangle.  With one sample
    (ms4 False) scov bit 4 l is the centre's coverage less kill[0].  A quad
    is kept when one of its lanes has a sample; with none, one empty quad
    at the bbox origin, as rxmodel.scan."""
    bx0, by0, bx1, by1 = r['bbox']
    if bx1 <= bx0 or by1 <= by0:
        return []
    keep = (~kill) & (15 if ms4 else 1)
    out = []
    for qy in range(by0 & ~1, by1, 2):
        for qx in range(bx0 & ~1, bx1, 2):
            scov = 0
            ccov = 0
            for ln in range(4):
                x, y = qx + (ln & 1), qy + (ln >> 1)
                if not (bx0 <= x < bx1 and by0 <= y < by1):
                    continue
                if _edge(r, x, y, 0, 0):
                    ccov |= 1 << ln
                if ms4:
                    for s in range(S):
                        if _edge(r, x, y, OFS[s][0], OFS[s][1]):
                            scov |= ((1 << s) & keep) << (4 * ln)
                elif ccov >> ln & 1:
                    scov |= (1 & keep) << (4 * ln)
            if scov:
                out.append((qx, qy, scov, ccov))
    if not out:
        out.append((bx0 & ~1, by0 & ~1, 0, 0))
    return out


def lane_mask(scov):
    """The lanes with a covered sample (fl_info's coverage)."""
    return sum(1 << ln for ln in range(4) if scov >> (4 * ln) & 15)


def warps_ms(r, ms4, kill):
    """Fragment warps: the kept quads in the walk's order, up to 8 per warp."""
    quads = [q for q in scan_ms(r, ms4, kill) if q[2]]
    return [quads[k:k + 8] for k in range(0, len(quads), 8)]


def _ev(r, p, fi, fj):
    a, b, c = r[p]
    return M.fadd(M.fadd(M.fmul(a, fi), M.fmul(b, fj)), c)


def _bary(r, fi, fj):
    rw = M.fdiv(M.ONE, _ev(r, 'w', fi, fj))
    b0 = M.fmul(_ev(r, 'b0', fi, fj), rw)
    b1 = M.fmul(_ev(r, 'b1', fi, fj), rw)
    return [b0, b1, M.fsub(M.fsub(M.ONE, b0), b1)]


def frag_lane_ms(r, x, y, ms4, s4, ccov, centroid):
    """r0-r9 of the lane at pixel (x, y) (r7-r9 None without centroid):
    b0-b2 and z at the centre (z clamped with one sample only), x + 0.5,
    y + 0.5, r6 = the lane's 4 bits of scov (s4; 0 in a helper lane),
    r7-r9 = the barycentrics at the centre when ccov, else at the covered
    sample of the lowest index (a helper lane: the centre)."""
    bx0, by0 = r['bbox'][0], r['bbox'][1]
    fi, fj = M.int2f(x - bx0), M.int2f(y - by0)
    zc = _ev(r, 'z', fi, fj)
    b = _bary(r, fi, fj)
    regs = b + [zc if ms4 else M.fclamp01(zc), M.centre(x), M.centre(y), s4]
    if not centroid:
        return regs + [None] * 3
    if ccov or not s4:
        return regs + b
    s = min(k for k in range(S) if s4 >> k & 1)
    return regs + _bary(r, M.fadd(fi, DXF[s]), M.fadd(fj, DYF[s]))


def dz_ms(r):
    """d_s, the depth of sample s minus the centre's: Az dx_s + Bz dy_s
    (fmul, fmul, fadd; once per triangle)."""
    az, bz = r['z'][0], r['z'][1]
    return [M.fadd(M.fmul(az, DXF[s]), M.fmul(bz, DYF[s])) for s in range(S)]

# ---------------------------------------------------------------- ROP

A2C_TH = [0x3E000000, 0x3EC00000, 0x3F200000, 0x3F600000]	# 0.125, 0.375, 0.625, 0.875
A2C_MASK = [0b0000, 0b0001, 0b1001, 0b1011, 0b1111]


def a2c(alpha, ms4):
    """Alpha to coverage of one lane (Amaterrace's table): NaN and
    negative alphas cover nothing."""
    if M._isnan(alpha) or alpha >> 31:
        return 0
    if not ms4:
        return 1 if alpha >= 0x3F000000 else 0
    return A2C_MASK[sum(1 for t in A2C_TH if alpha >= t)]


def ms_quad(ctrl, smask, z, colors, zexp, zout, ds):
    """atg_rop_ms: per-sample depth, alpha to coverage, alpha to one.
    ctrl = MS_CTRL; smask 16 bits; z[4] the lanes' r3; zexp 4 bits; zout[4]
    the exported depths; ds[4]; colors[4][4] (changed for alpha to one).
    Returns (smask, sz[4][4], colors)."""
    ms4 = ctrl & 15 == 2
    sz = [[0] * S for _ in range(4)]
    colors = [list(c) for c in colors]
    for ln in range(4):
        for s in range(S if ms4 else 1):
            if zexp >> ln & 1:
                sz[ln][s] = zout[ln]
            elif ms4:
                sz[ln][s] = M.fclamp01(M.fadd(z[ln], ds[s]))
            else:
                sz[ln][s] = z[ln]
        if ctrl >> 8 & 1:
            smask &= ~((15 & ~a2c(colors[ln][3], ms4)) << (4 * ln))
        if ctrl >> 9 & 1:
            colors[ln][3] = M.ONE
    return smask, sz, colors


def rop_quad_ms(st, mem, x, y, smask, z, colors, zexp=0, zout=(0, 0, 0, 0),
                ds=(0, 0, 0, 0)):
    """One quad in primitive order through atg_rop_ms, atg_rop_ds and
    atg_rop_wb with the sample-interleaved layout (S samples per pixel
    when MS_CTRL says 4, else 1): sample s of pixel (px, py) at
    base + py stride + (px S + s) ps.  Returns the samples written."""
    ctrl = st[S_MS_CTRL]
    ns = S if ms_log2(st) else 1
    smask, sz, colors = ms_quad(ctrl, smask, z, colors, zexp, zout, ds)
    dep = st[M.S_DEPTH]
    test = dep & 1 and dep & 0x60
    f32 = bool(dep & 0x40)
    func = (dep >> 2) & 7
    fmt = st[M.S_RT_FORMAT] & 3
    ps = 2 if fmt == 2 else 4
    out = 0
    for ln in range(4):
        px, py = x + (ln & 1), y + (ln >> 1)
        for s in range(ns):
            if not smask >> (4 * ln + s) & 1:
                continue
            if test:
                da = st[M.S_DS_BASE] + py * st[M.S_DS_STRIDE] + (px * ns + s) * 4
                stored = mem.rd32(da)
                if f32:
                    ok = M.depth_pass(func, sz[ln][s], stored, True)
                    nv = sz[ln][s]
                else:
                    ok = M.depth_pass(func, M.f2u24(sz[ln][s]), stored & 0xFFFFFF, False)
                    nv = (stored & 0xFF000000) | M.f2u24(sz[ln][s])
                if not ok:
                    continue
                if dep & 2:
                    mem.wr32(da, nv)
            out |= 1 << (4 * ln + s)
            ca = st[M.S_RT_BASE] + py * st[M.S_RT_STRIDE] + (px * ns + s) * ps
            dpx = mem.rd16(ca) if ps == 2 else mem.rd32(ca)
            p = M.blend_pixel(st, colors[ln], dpx)
            if ps == 2:
                mem.wr16(ca, p)
            else:
                mem.wr32(ca, p)
    return out

# ---------------------------------------------------------------- BLT RESOLVE

BLT_OP, BLT_DST_BASE, BLT_DST_STRIDE, BLT_SRC_BASE, BLT_SRC_STRIDE = 0, 1, 2, 3, 4
BLT_DST_XY, BLT_SRC_XY, BLT_SIZE, BLT_COLOR, BLT_CLIP_MIN, BLT_CLIP_MAX = 5, 6, 7, 8, 9, 10
BLT_RESOLVE = 11
F_UNORM8, F_UNORM565, F_SAMPLE0 = 0, 1, 2


def rne_div4(sm):
    """sm / 4 rounded to the nearest integer, ties to even."""
    q, rem = sm >> 2, sm & 3
    return q + (1 if rem > 2 or (rem == 2 and q & 1) else 0)


def avg_px(fmt, ps, samples):
    """The average of the S samples (integers of ps bytes) of one pixel."""
    if fmt == F_SAMPLE0:
        return samples[0]
    if fmt == F_UNORM565:
        out = 0
        for lo, w in ((0, 5), (5, 6), (11, 5)):
            m = (1 << w) - 1
            out |= rne_div4(sum((v >> lo) & m for v in samples)) << lo
        return out
    out = 0
    for b in range(ps):
        out |= rne_div4(sum((v >> (8 * b)) & 255 for v in samples)) << (8 * b)
    return out


def resolve_check(blt, ms4=True):
    """True when the blitter takes this RESOLVE (else a fault of kind 2)."""
    op, rs = blt[BLT_OP], blt[BLT_RESOLVE]
    bpp = (op >> 8) & 3
    fmt = (rs >> 4) & 15
    return (ms4 and op & 7 == 4 and not op >> 4 & 1 and not op >> 12 & 1 and
            bpp in (0, 1) and rs & 15 == 2 and
            (fmt in (F_UNORM8, F_SAMPLE0) or (fmt == F_UNORM565 and bpp == 1)))


def _clip(blt):
    dx, dy = blt[BLT_DST_XY] & 0xFFFF, blt[BLT_DST_XY] >> 16
    sx, sy = blt[BLT_SRC_XY] & 0xFFFF, blt[BLT_SRC_XY] >> 16
    w, h = blt[BLT_SIZE] & 0xFFFF, blt[BLT_SIZE] >> 16
    x0, y0, x1, y1 = dx, dy, dx + w, dy + h
    if blt[BLT_CLIP_MAX]:
        cmin, cmax = blt[BLT_CLIP_MIN], blt[BLT_CLIP_MAX]
        x0, y0 = max(x0, cmin & 0xFFFF), max(y0, cmin >> 16)
        x1, y1 = min(x1, cmax & 0xFFFF), min(y1, cmax >> 16)
    return x0, y0, x1, y1, sx + (x0 - dx), sy + (y0 - dy)


def dst_addr(base, stride, x, y, ps, tiled):
    if tiled:
        return base + (y // 4) * stride + (x // 4) * 16 * ps + ((y % 4) * 4 + x % 4) * ps
    return base + y * stride + x * ps


def resolve(mem, blt):
    """The blitter's RESOLVE on mem (rxmodel.Mem); returns the number of
    destination pixels written (None when refused).  Bases and strides
    lose the bits below the sample group (source) or the pixel
    (destination), as the RTL."""
    if not resolve_check(blt):
        return None
    ps = 2 if (blt[BLT_OP] >> 8) & 3 else 4
    fmt = (blt[BLT_RESOLVE] >> 4) & 15
    tiled = blt[BLT_RESOLVE] >> 8 & 1
    sg = S * ps
    sbase = blt[BLT_SRC_BASE] & ~(sg - 1)
    sstride = blt[BLT_SRC_STRIDE] & ~(sg - 1)
    dbase = blt[BLT_DST_BASE] & ~(ps - 1)
    dstride = blt[BLT_DST_STRIDE] & ~(ps - 1)
    x0, y0, x1, y1, sx0, sy0 = _clip(blt)
    n = 0
    rd = mem.rd16 if ps == 2 else mem.rd32
    wr = mem.wr16 if ps == 2 else mem.wr32
    for y in range(y0, y1):
        for x in range(x0, x1):
            sx, sy = sx0 + (x - x0), sy0 + (y - y0)
            a = (sbase + sy * sstride + sx * sg) & M.M32
            smp = [rd((a + s * ps) & M.M32) for s in range(S)]
            wr(dst_addr(dbase, dstride, x, y, ps, tiled) & M.M32, avg_px(fmt, ps, smp))
            n += 1
    return n

# ---------------------------------------------------------------- self-check


def selftest():
    import random
    rnd = random.Random(27)
    # The offsets are the standard locations, exact in 15.8 and fp32.
    for s in range(S):
        assert OFS[s] == (int((LOC[s][0] - 0.5) * 256), int((LOC[s][1] - 0.5) * 256))
        assert M.b2f(DXF[s]) * 256 == OFS[s][0] and M.b2f(DYF[s]) * 256 == OFS[s][1]
    # One sample: the coverage and the inputs equal rxmodel's.
    st = M.State()
    st.set(M.S_RT_SIZE, 64 | 48 << 16)
    tris = 0
    for _ in range(300):
        words = []
        for i in range(3):
            words += [M.f2b(rnd.uniform(-4, 68)), M.f2b(rnd.uniform(-4, 52)), M.f2b(rnd.random())]
        r = M.setup(st, M.raw_tri(words))
        ref = M.scan(r)
        got = scan_ms(r, False, 0)
        assert len(ref) == len(got)
        for (x, y, m, z), (gx, gy, sc, cc) in zip(ref, got):
            assert (x, y) == (gx, gy) and lane_mask(sc) == m and (m == 0 or cc == m)
            for ln in range(4):
                if m >> ln & 1:
                    px, py = x + (ln & 1), y + (ln >> 1)
                    a = M.frag_lane(r, px, py)
                    b = frag_lane_ms(r, px, py, False, 1, 1, False)
                    assert a == b[:6] and b[6] == 1
        if ref and ref[0][2]:
            tris += 1
        # Four samples: each sample's coverage is the edge test at its
        # location; the centre coverage is the one-sample coverage.
        for (gx, gy, sc, cc) in scan_ms(r, True, 0):
            for ln in range(4):
                px, py = gx + (ln & 1), gy + (ln >> 1)
                for s in range(S):
                    want = (r['bbox'][0] <= px < r['bbox'][2] and r['bbox'][1] <= py < r['bbox'][3]
                            and _exact_inside(r, px + LOC[s][0], py + LOC[s][1]))
                    assert bool(sc >> (4 * ln + s) & 1) == want
    assert tris > 50
    # Tie: two triangles sharing an edge cover every sample of the shared
    # square exactly once (the top-left rule at the sample locations).
    for _ in range(200):
        p = [(rnd.randint(0, 40) * 32, rnd.randint(0, 40) * 32) for _ in range(4)]

        def side(c):
            return ((p[2][0] - p[1][0]) * (c[1] - p[1][1]) - (p[2][1] - p[1][1]) * (c[0] - p[1][0]))
        if side(p[0]) * side(p[3]) >= 0:
            continue
        q = [M.f2b(v / 256.0) for xy in p for v in xy]
        t1 = M.setup(st, M.raw_tri([q[0], q[1], 0, q[2], q[3], 0, q[4], q[5], 0]))
        t3 = M.setup(st, M.raw_tri([q[2], q[3], 0, q[6], q[7], 0, q[4], q[5], 0]))
        cnt = {}
        for t in (t1, t3):
            for (gx, gy, sc, cc) in scan_ms(t, True, 0):
                for k in range(16):
                    if sc >> k & 1:
                        key = (gx + (k >> 2 & 1), gy + (k >> 3), k & 3)
                        cnt[key] = cnt.get(key, 0) + 1
        assert all(v == 1 for v in cnt.values())
    # The sample mask test removes exactly the killed samples.
    r = M.setup(st, M.raw_tri([M.f2b(v) for v in (1, 1, 0, 60, 3, 0, 20, 45, 0)]))
    full = scan_ms(r, True, 0)
    for kill in range(16):
        for (a, b) in zip(full, scan_ms(r, True, kill) + [None] * 64):
            if b is None or (a[0], a[1]) != (b[0], b[1]):
                assert a[2] & ~(0x1111 * kill) == 0
                break
            assert b[2] == a[2] & ~(0x1111 * kill) & 0xFFFF
    # Alpha to coverage: the table's steps.
    for alpha, n in ((0.0, 0), (0.1249, 0), (0.125, 1), (0.375, 2), (0.6249, 2), (0.625, 3),
                     (0.875, 4), (2.0, 4), (-0.5, 0)):
        assert a2c(M.f2b(alpha), True) == A2C_MASK[n]
    assert a2c(M.QNAN, True) == 0 and a2c(0x3F000000, False) == 1 and a2c(0x3EFFFFFF, False) == 0
    # Centroid: the location is inside the triangle (a perspective
    # triangle: the barycentric planes of DRAW_RAW are 0).
    for k, v in enumerate((M.f2b(32.0), M.f2b(24.0), M.f2b(32.0), M.f2b(24.0), M.ONE, 0)):
        st.set(M.S_VIEWPORT + k, v)
    pos = [[M.f2b(a) for a in xyzw] for xyzw in ((-0.9, -0.9, 0.2, 1.0), (1.3, -0.7, 0.5, 2.0),
                                                 (-0.2, 0.8, 0.1, 1.0))]
    r = M.setup(st, {'pos': pos, 'wt': [row[:] for row in M.IDW], 'pt': [0, 0, 0], 'free': 0,
                     'raw': 0})
    full = scan_ms(r, True, 0)
    edge_lanes = outside = 0
    for (gx, gy, sc, cc) in full:
        for ln in range(4):
            s4 = sc >> (4 * ln) & 15
            if s4 and not cc >> ln & 1:
                rr = frag_lane_ms(r, gx + (ln & 1), gy + (ln >> 1), True, s4, 0, True)
                assert all(M.b2f(v) >= -1e-5 for v in rr[7:10])
                edge_lanes += 1
                outside += any(M.b2f(v) < -1e-5 for v in rr[0:3])
    assert edge_lanes > 10 and outside > 5
    # The UNORM average: RNE of the exact mean, for every sum.
    for sm in range(0, 1021):
        q = rne_div4(sm)
        exact = sm / 4.0
        assert abs(q - exact) <= 0.5 and (abs(q - exact) < 0.5 or q % 2 == 0)
    # resolve: a 2-pixel image of known samples.
    mem = M.Mem()
    vals = [0x00000000, 0x01010101, 0x02020202, 0x03030303, 0xFF00FF00, 0xFF00FF00, 0xFE01FD02,
            0x00FFFF00]
    for i, v in enumerate(vals):
        mem.wr32(0x1000 + 4 * i, v)
    blt = [0] * 12
    blt[BLT_OP] = 4
    blt[BLT_DST_BASE], blt[BLT_DST_STRIDE] = 0x2000, 64
    blt[BLT_SRC_BASE], blt[BLT_SRC_STRIDE] = 0x1000, 32
    blt[BLT_SIZE] = 2 | 1 << 16
    blt[BLT_RESOLVE] = 2
    assert resolve(mem, blt) == 2
    assert mem.rd32(0x2000) == 0x02020202	# (0 + 1 + 2 + 3) / 4 = 1.5 -> 2
    assert mem.rd32(0x2004) == avg_px(0, 4, vals[4:8])
    blt[BLT_RESOLVE] = 2 | 1 << 4
    assert resolve(mem, blt) is None	# UNORM565 needs 16-bit pixels
    print('PASS msmodel.selftest')


def _exact_inside(r, fx, fy):
    """The edge test at the point (fx, fy) in pixels, exactly."""
    bx0, by0 = r['bbox'][0], r['bbox'][1]
    for (A, B, E) in r['edges']:
        v = E + A * round((fx - bx0 - 0.5) * 256) + B * round((fy - by0 - 0.5) * 256)
        if v < 0:
            return False
    return True


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest()
    else:
        sys.exit('usage: msmodel.py --selftest')
