#!/usr/bin/env python3
# tumodel.py: the reference model of the texture unit (spec/gpu/tu/*.md),
# bit for bit: the addressing of atg_tu_addr (descriptor, LOD, mip levels
# and the two passes of mip linear filtering, wrap and clamp to border,
# bilinear footprint, linear or 4x4 tiled addresses, texsz), the border
# texels of atg_tu_cache, the texel conversion, depth compare and filter
# of atg_tu_filter.  Used by tools/tu-vectors.py (unit vectors) and
# tools/rx-tex-scene.py (the textured scene).  A module only; it has no
# command line.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as RX  # noqa: E402

M32 = 0xFFFFFFFF
LAM_MIN = -32768
ONE = 0x3F800000

OP_TEXL, OP_TEXB, OP_TEXF, OP_TEXSZ = 0, 1, 2, 3

# Descriptor words (design §2.3: STATE 0x090 + 16 s + word).
D_BASE, D_SIZE, D_LEVELS, D_SAMPLER = 0, 1, 2, 3
# SAMPLER bits: wrap u [1:0], wrap v [3:2] (0 repeat, 1 mirrored repeat,
# 2 clamp to edge, 3 clamp to border), mag linear [4], min linear [5], mip
# linear [6], compare [7], compare op [10:8] (VkCompareOp), format
# {[14], [12]} (0 RGBA8, 1 BGRA8, 2 D24, 3 D32_SFLOAT), 4x4 tiled [13],
# border colour [18:16] (VkBorderColor).
SAMP_MAG_LIN, SAMP_MIN_LIN, SAMP_MIP_LIN, SAMP_CMP = 4, 5, 6, 7
SAMP_CMP_OP, SAMP_FMT, SAMP_TILED, SAMP_DEPTH, SAMP_BORDER = 8, 12, 13, 14, 16
WRAP_REPEAT, WRAP_MIRROR, WRAP_EDGE, WRAP_BORDER = 0, 1, 2, 3

# ta_ctl / tc_ctl bits (16).
CTL_BIL, CTL_FMT, CTL_SZ, CTL_TEXF, CTL_TRI0, CTL_TRI1 = 0, 1, 2, 3, 4, 5
CTL_BORDER, CTL_DEPTH, CTL_CMP, CTL_CMP_OP = 6, 8, 9, 10


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def sat(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def sat16(v):
    return sat(v, -32768, 32767)


def _fields(f):
    return f >> 31, (f >> 23) & 0xFF, (f & 0x7FFFFF) | 0x800000


def fx32(f, sh):
    """floor(f * 2^sh) saturated to a signed 32-bit value; zeros, denormals
    and NaN give 0, infinities saturate."""
    s, e, m = _fields(f)
    if e == 0:
        return 0
    if e == 255:
        if f & 0x7FFFFF:
            return 0
        return -(1 << 31) if s else (1 << 31) - 1
    k = e - 150 + sh
    if k >= 8:
        return -(1 << 31) if s else (1 << 31) - 1
    if k >= 0:
        q, st = m << k, 0
    else:
        q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
    return -(q + st) if s else q


def fwrap(f, mode):
    """The wrapped coordinate (24 fraction bits) of a normalised coordinate:
    0 repeat, 1 mirrored repeat, 2 clamp to edge give [0, 2^24]; 3 clamp to
    border gives floor(u * 2^24) clamped to [-2^24, 2^25] (u in [-1, 2]).
    Zeros, denormals and NaN are 0; infinity is 0 (repeat, mirror)."""
    s, e, m = _fields(f)
    if e == 0 or (e == 255 and f & 0x7FFFFF):
        return 0
    if mode == WRAP_EDGE:
        if s:
            return 0
        if e >= 127:
            return 1 << 24
        return m >> (126 - e)
    if mode == WRAP_BORDER:
        if e >= 128:
            return -(1 << 24) if s else 1 << 25
        k = e - 126	# u * 2^24 = m * 2^k, k <= 1
        if k >= 0:
            q, st = m << k, 0
        elif k > -24:
            q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
        else:
            q, st = 0, 1
        return max(-(q + st), -(1 << 24)) if s else q
    if e == 255:
        t = 0
    else:
        k = e - 126	# u * 2^24 = m * 2^k
        if k >= 0:
            q, st = (m << k) & ((1 << 25) - 1) if k < 25 else 0, 0
        else:
            q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
        t = (-(q + st) if s else q) & ((1 << 25) - 1)
    if mode == WRAP_REPEAT:
        return t & ((1 << 24) - 1)
    if t >> 24:
        return (1 << 24) - (t & ((1 << 24) - 1))
    return t


def l2(x):
    """log2 with 8 fraction bits: the msb's position and the 8 bits below."""
    p = x.bit_length() - 1
    return p * 256 + (((x << 8) >> p) & 0xFF)


def levels(d):
    n = d[D_LEVELS] & 0xF
    return 1 if n == 0 else 13 if n > 13 else n


def size(d, lv):
    w, h = d[D_SIZE] & 0xFFFF, d[D_SIZE] >> 16
    return max(1, w >> lv), max(1, h >> lv)


def lod_quad(d, u, v):
    """texb: the quad's LOD from lanes 0, 1 (x + 1) and 2 (y + 1)."""
    U = [fx32(x, 16) for x in u[:3]]
    V = [fx32(x, 16) for x in v[:3]]
    w, h = size(d, 0)
    mu = max(abs(U[1] - U[0]), abs(U[2] - U[0]))
    mv = max(abs(V[1] - V[0]), abs(V[2] - V[0]))
    lu = l2(mu) + l2(w) - 4096 if mu else LAM_MIN
    lv = l2(mv) + l2(h) - 4096 if mv else LAM_MIN
    return sat16(max(lu, lv))


def level_base(d, lv):
    return (d[D_BASE] + (d[3 + lv] if lv else 0)) & M32


def texel_addr(d, lv, i, j):
    w, _ = size(d, lv)
    b = level_base(d, lv)
    if d[D_SAMPLER] >> SAMP_TILED & 1:
        a = b + (j >> 2) * ((w + 3) >> 2) * 64 + (i >> 2) * 64 + ((j & 3) * 4 + (i & 3)) * 4
    else:
        a = b + (j * w + i) * 4
    return a & M32 & ~3	# bits 1:0 are 0 (bit 0 marks a border texel)


def wrap_int(i, n, mode):
    """A texel index (bilinear: -1 .. n; border: any) back into the level,
    and whether it is a border texel."""
    if mode == WRAP_BORDER:
        return sat(i, 0, n - 1), int(i < 0 or i >= n)
    if i < 0:
        return (n - 1 if mode == WRAP_REPEAT else 0), 0
    if i >= n:
        return (0 if mode == WRAP_REPEAT else n - 1), 0
    return i, 0


def samp_mode(d, op):
    """(depth format, compare, filtering allowed, mip linear) of a quad."""
    samp = d[D_SAMPLER]
    depth = samp >> SAMP_DEPTH & 1
    cmp = int(depth and samp >> SAMP_CMP & 1 and op in (OP_TEXL, OP_TEXB))
    filt = int(not depth or cmp)
    return depth, cmp, filt, int(filt and samp >> SAMP_MIP_LIN & 1)


def lane_lod(op, d, c, lam_q):
    """One lane of texl/texb: (linear, level of pass 0, level of pass 1,
    the 8-bit weight of pass 1)."""
    samp = d[D_SAMPLER]
    _, cmp, filt, miplin = samp_mode(d, op)
    if cmp:
        lam = lam_q if op == OP_TEXB else 0	# rs2 is Dref: no bias, lod 0
    else:
        lam = sat16(fx32(c[2], 8))
        if op == OP_TEXB:
            lam = sat16(lam_q + lam)
    maxl = levels(d) - 1
    if lam <= 0:
        return filt & (samp >> SAMP_MAG_LIN & 1), 0, 0, 0
    lin = filt & (samp >> SAMP_MIN_LIN & 1)
    if miplin:
        dl = lam >> 8
        if dl >= maxl:
            return lin, maxl, maxl, 0
        return lin, dl, dl + 1, lam & 0xFF
    lv = min((lam + 127) >> 8, maxl)
    return lin, lv, lv, 0


def lane_addr(op, d, c, lam_q, pas):
    """One lane: (addresses of texels 0-3, fu, fv, fl, linear, value).  c is
    the lane's three coordinate words; lam_q the quad LOD (texb); pas the
    pass (0, or 1 for the second level of mip linear filtering).  Bit 0 of
    an address marks a border texel."""
    samp = d[D_SAMPLER]
    if op == OP_TEXSZ:
        lv = min(c[0] & M32, 15)
        w, h = size(d, lv)
        return [0] * 4, 0, 0, 0, 0, (h & 0xFFFF) << 16 | (w & 0xFFFF)
    if op == OP_TEXF:
        lev = s32(c[2])
        lv = 0 if lev < 0 else min(lev, levels(d) - 1)
        w, h = size(d, lv)
        i = sat(s32(c[0]), 0, w - 1)
        j = sat(s32(c[1]), 0, h - 1)
        return [texel_addr(d, lv, i, j)] * 4, 0, 0, 0, 0, 0
    _, cmp, _, _ = samp_mode(d, op)
    val = c[2] & M32 if cmp else 0
    lin, lv0, lv1, fl = lane_lod(op, d, c, lam_q)
    lv = lv1 if pas else lv0
    w, h = size(d, lv)
    mu, mv = samp & 3, samp >> 2 & 3
    cu = (fwrap(c[0], mu) * w) >> 16
    cv = (fwrap(c[1], mv) * h) >> 16
    if not lin:
        i, j = cu >> 8, cv >> 8
        if mu != WRAP_BORDER:
            i = min(i, w - 1)
        if mv != WRAP_BORDER:
            j = min(j, h - 1)
        i, bi = wrap_int(i, w, mu)
        j, bj = wrap_int(j, h, mv)
        return [texel_addr(d, lv, i, j) | (bi | bj)] * 4, 0, 0, fl, 0, val
    cu, cv = cu - 128, cv - 128
    i0, j0 = cu >> 8, cv >> 8
    fu, fv = cu & 0xFF, cv & 0xFF
    i1, bi1 = wrap_int(i0 + 1, w, mu)
    j1, bj1 = wrap_int(j0 + 1, h, mv)
    i0, bi0 = wrap_int(i0, w, mu)
    j0, bj0 = wrap_int(j0, h, mv)
    return ([texel_addr(d, lv, i0, j0) | (bi0 | bj0), texel_addr(d, lv, i1, j0) | (bi1 | bj0),
             texel_addr(d, lv, i0, j1) | (bi0 | bj1), texel_addr(d, lv, i1, j1) | (bi1 | bj1)],
            fu, fv, fl, 1, val)


def border_class(d):
    """VkBorderColor >> 1: 0 transparent black, 1 opaque black, 2 opaque
    white (6 and 7 read as 0)."""
    b = d[D_SAMPLER] >> SAMP_BORDER & 7
    return 0 if b >= 6 else b >> 1


def quad_addr(op, d, coords, mask):
    """atg_tu_addr on one quad: coords[l] = (w0, w1, w2) of lane l.
    Returns the passes, each (addr[l][t], wts[l], ctl, value[l]) with wts
    lane l = fu | fv << 8 | fl << 16: one pass, or two for mip linear
    filtering when a lane of the mask has a nonzero weight fl."""
    lam_q = 0
    if op == OP_TEXB:
        lam_q = lod_quad(d, [c[0] for c in coords], [c[1] for c in coords])
    samp = d[D_SAMPLER]
    depth, cmp, _, _ = samp_mode(d, op)
    passes = []
    tri = False
    for pas in range(2):
        out = [lane_addr(op, d, coords[ln], lam_q, pas) for ln in range(4)]
        if pas == 0:
            tri = any(out[ln][3] for ln in range(4) if mask >> ln & 1)
        lin = any(out[ln][4] for ln in range(4) if mask >> ln & 1)
        ctl = (lin << CTL_BIL | (samp >> SAMP_FMT & 1) << CTL_FMT | (op == OP_TEXSZ) << CTL_SZ |
               (op == OP_TEXF) << CTL_TEXF | (tri and pas == 0) << CTL_TRI0 |
               (pas == 1) << CTL_TRI1 | border_class(d) << CTL_BORDER | depth << CTL_DEPTH |
               cmp << CTL_CMP | (samp >> SAMP_CMP_OP & 7) << CTL_CMP_OP)
        passes.append(([o[0] for o in out], [o[1] | o[2] << 8 | o[3] << 16 for o in out], ctl,
                       [o[5] for o in out]))
        if not tri:
            break
    return passes


def rnd_f32(p, sh):
    """p * 2^-sh as fp32 (p > 0 an integer, the result normal), rounded to
    nearest even; 0 for p = 0."""
    if p == 0:
        return 0
    n = p.bit_length() - 1
    e = 127 + n - sh
    man = p >> (n - 23)
    rest = p & ((1 << (n - 23)) - 1)
    half = 1 << (n - 24)
    if rest > half or (rest == half and man & 1):
        man += 1
        if man >> 24:
            man >>= 1
            e += 1
    return e << 23 | (man & 0x7FFFFF)


def conv(r):
    """R / (255 * 65536) as fp32: R * 0x0101010101 / 2^56, rounded to nearest
    even (atg_tu_filter, R < 2^24)."""
    return rnd_f32(r * 0x0101010101, 56)


def conv32(r):
    """A mip linear sum R' < 2^32: R' / (255 * 2^24) as R' * 0x0101010101 /
    2^64 (conv32(R << 8) == conv(R))."""
    return rnd_f32(r * 0x0101010101, 64)


def conv24(c):
    """unorm24 to fp32: c / (2^24 - 1) as c * (2^48 + 2^24 + 1) / 2^72,
    rounded to nearest even (the correctly rounded quotient for every c)."""
    return rnd_f32(c * 0x1000001000001, 72)


# Border texels' raw words by format class (colour, D24, D32F) and class.
BORDER_RAW = {0: (0, 0xFF000000, 0xFFFFFFFF), 2: (0, 0, 0x00FFFFFF), 3: (0, 0, ONE)}


def border_raw(ctl):
    """The raw texel of a border texel (atg_tu_cache)."""
    fc = (ctl >> CTL_DEPTH & 1) << 1 | (ctl >> CTL_FMT & 1)
    k = ctl >> CTL_BORDER & 3
    return 0 if k == 3 else BORDER_RAW[0 if fc < 2 else fc][k]


def channels(t, fmt):
    b = [(t >> (8 * k)) & 0xFF for k in range(4)]
    return [b[2], b[1], b[0], b[3]] if fmt else b


def lane_texels(texels, ctl, dref):
    """The four texels' channel bytes (RGBA): colour formats, or for a
    depth compare its result as (255 or 0, 0, 0, 255)."""
    if ctl >> CTL_CMP & 1:
        f32 = ctl >> CTL_FMT & 1
        fn = ctl >> CTL_CMP_OP & 7
        out = []
        for t in texels:
            if f32:
                ok = RX.depth_pass(fn, dref, t, True)
            else:
                ok = RX.depth_pass(fn, RX.f2u24(dref), t & 0xFFFFFF, False)
            out.append([255 if ok else 0, 0, 0, 255])
        return out
    return [channels(t, ctl >> CTL_FMT & 1) for t in texels]


def lane_sums(texels, wts, ctl, dref):
    """The four channels' fixed-point sums R (< 2^24) of one lane."""
    fu, fv = wts & 0xFF, wts >> 8 & 0xFF
    ch = lane_texels(texels, ctl, dref)
    out = []
    for k in range(4):
        a, b, c, d = ch[0][k], ch[1][k], ch[2][k], ch[3][k]
        if ctl & 1:
            top = a * (256 - fu) + b * fu
            bot = c * (256 - fu) + d * fu
            out.append(top * (256 - fv) + bot * fv)
        else:
            out.append(a << 16)
    return out


class Filter:
    """atg_tu_filter: one quad a call; the first pass of a mip linear pair
    returns None and is kept for the second."""

    def __init__(self):
        self.hold = [[0] * 4 for _ in range(4)]

    def quad(self, texels, wts, ctl, mask, value):
        """tr_data's 16 words (lane-major RGBA), or None (ctl[4])."""
        words = []
        for ln in range(4):
            on = mask >> ln & 1
            if ctl >> CTL_SZ & 1:
                words += [value[ln] if on else 0, 0, 0, 0]
                continue
            if ctl >> CTL_DEPTH & 1 and not ctl >> CTL_CMP & 1:
                # a depth format without compare: texel 0 as (D, 0, 0, 1)
                t = texels[ln][0]
                dv = t if ctl >> CTL_FMT & 1 else conv24(t & 0xFFFFFF)
                words += [dv, 0, 0, ONE] if on else [0] * 4
                continue
            r = lane_sums(texels[ln], wts[ln], ctl, value[ln])
            if ctl >> CTL_TRI0 & 1:
                self.hold[ln] = r
                continue
            if ctl >> CTL_TRI1 & 1:
                fl = wts[ln] >> 16 & 0xFF
                res = [conv32(self.hold[ln][k] * (256 - fl) + r[k] * fl) for k in range(4)]
            else:
                res = [conv(x) for x in r]
            words += res if on else [0] * 4
        return None if ctl >> CTL_TRI0 & 1 else words


def fetch(mem, addrs, ctl, mask):
    """atg_tu_cache: the raw texels (only texel 0 without bilinear; masked
    lanes and texsz read nothing, 0; a border texel, address bit 0, is the
    border colour's raw texel)."""
    out = []
    for ln in range(4):
        row = []
        for t in range(4):
            use = mask >> ln & 1 and not ctl >> CTL_SZ & 1 and (t == 0 or ctl & 1)
            if not use:
                row.append(0)
            elif addrs[ln][t] & 1:
                row.append(border_raw(ctl))
            else:
                row.append(mem.rd32(addrs[ln][t] & ~3))
        out.append(row)
    return out


def sample(mem, op, d, coords, mask):
    """A whole quad through the TU: 16 words (lane-major RGBA)."""
    flt = Filter()
    words = None
    for a, wts, ctl, val in quad_addr(op, d, coords, mask):
        words = flt.quad(fetch(mem, a, ctl, mask), wts, ctl, mask, val)
    return words
