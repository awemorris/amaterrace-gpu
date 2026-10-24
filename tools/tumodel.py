#!/usr/bin/env python3
# tumodel.py: the reference model of the texture unit (spec/gpu/tu/*.md,
# WS288 p009), bit for bit: the addressing of atg_tu_addr (descriptor, LOD,
# mip level, wrap, bilinear footprint, linear or 4x4 tiled addresses,
# texsz), the texel conversion and filter of atg_tu_filter.  Used by
# tools/tu-vectors.py (unit vectors) and tools/rx-tex-scene.py (the
# textured scene).  A module only; it has no command line.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

M32 = 0xFFFFFFFF
LAM_MIN = -32768

OP_TEXL, OP_TEXB, OP_TEXF, OP_TEXSZ = 0, 1, 2, 3

# Descriptor words (design §2.3: STATE 0x090 + 16 s + word).
D_BASE, D_SIZE, D_LEVELS, D_SAMPLER = 0, 1, 2, 3
SAMP_MAG_LIN, SAMP_MIN_LIN, SAMP_FMT, SAMP_TILED = 4, 5, 12, 13


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
    """The wrapped coordinate in [0, 2^24] (24 fraction bits) of a
    normalised coordinate: 0 repeat, 1 mirrored repeat, 2 (and 3) clamp to
    edge.  Zeros, denormals and NaN are 0; infinity is 0 (repeat, mirror)."""
    s, e, m = _fields(f)
    if e == 0 or (e == 255 and f & 0x7FFFFF):
        return 0
    if mode >= 2:
        if s:
            return 0
        if e >= 127:
            return 1 << 24
        return m >> (126 - e)
    if e == 255:
        t = 0
    else:
        k = e - 126	# u * 2^24 = m * 2^k
        if k >= 0:
            q, st = (m << k) & ((1 << 25) - 1) if k < 25 else 0, 0
        else:
            q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
        t = (-(q + st) if s else q) & ((1 << 25) - 1)
    if mode == 0:
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
    return a & M32


def wrap_int(i, n, mode):
    """A bilinear neighbour (-1 .. n) back into the level."""
    if i < 0:
        return n - 1 if mode == 0 else 0
    if i >= n:
        return 0 if mode == 0 else n - 1
    return i


def lane_addr(op, d, c, lam_q):
    """One lane: (addresses of texels 0-3, fu, fv, linear, value).  c is the
    lane's three coordinate words; lam_q the quad LOD (texb)."""
    samp = d[D_SAMPLER]
    if op == OP_TEXSZ:
        lv = min(c[0] & M32, 15)
        w, h = size(d, lv)
        return [0] * 4, 0, 0, 0, (h & 0xFFFF) << 16 | (w & 0xFFFF)
    if op == OP_TEXF:
        lev = s32(c[2])
        lv = 0 if lev < 0 else min(lev, levels(d) - 1)
        w, h = size(d, lv)
        i = sat(s32(c[0]), 0, w - 1)
        j = sat(s32(c[1]), 0, h - 1)
        return [texel_addr(d, lv, i, j)] * 4, 0, 0, 0, 0
    lam = sat16(fx32(c[2], 8))
    if op == OP_TEXB:
        lam = sat16(lam_q + lam)
    if lam > 0:
        lin = samp >> SAMP_MIN_LIN & 1
        lv = min((lam + 127) >> 8, levels(d) - 1)
    else:
        lin = samp >> SAMP_MAG_LIN & 1
        lv = 0
    w, h = size(d, lv)
    mu, mv = samp & 3, samp >> 2 & 3
    cu = (fwrap(c[0], mu) * w) >> 16
    cv = (fwrap(c[1], mv) * h) >> 16
    if not lin:
        i, j = min(cu >> 8, w - 1), min(cv >> 8, h - 1)
        return [texel_addr(d, lv, i, j)] * 4, 0, 0, 0, 0
    cu, cv = cu - 128, cv - 128
    i0, j0 = cu >> 8, cv >> 8
    fu, fv = cu & 0xFF, cv & 0xFF
    i1, j1 = wrap_int(i0 + 1, w, mu), wrap_int(j0 + 1, h, mv)
    i0, j0 = wrap_int(i0, w, mu), wrap_int(j0, h, mv)
    return ([texel_addr(d, lv, i0, j0), texel_addr(d, lv, i1, j0),
             texel_addr(d, lv, i0, j1), texel_addr(d, lv, i1, j1)], fu, fv, 1, 0)


def quad_addr(op, d, coords, mask):
    """atg_tu_addr on one quad: coords[l] = (w0, w1, w2) of lane l.
    Returns (addr[l][t], fu[l], fv[l], ctl, value[l])."""
    lam_q = 0
    if op == OP_TEXB:
        lam_q = lod_quad(d, [c[0] for c in coords], [c[1] for c in coords])
    out = [lane_addr(op, d, coords[l], lam_q) for l in range(4)]
    lin = any(out[l][3] for l in range(4) if mask >> l & 1)
    ctl = (lin | (d[D_SAMPLER] >> SAMP_FMT & 1) << 1 | (op == OP_TEXSZ) << 2 |
           (op == OP_TEXF) << 3)
    return ([o[0] for o in out], [o[1] for o in out], [o[2] for o in out], ctl,
            [o[4] for o in out])


def conv(r):
    """R / (255 * 65536) as fp32: R * 0x0101010101 / 2^56, rounded to nearest
    even (atg_tu_filter)."""
    if r == 0:
        return 0
    p = r * 0x0101010101
    n = p.bit_length() - 1
    e = 127 + n - 56
    man = p >> (n - 23)
    rest = p & ((1 << (n - 23)) - 1)
    half = 1 << (n - 24)
    if rest > half or (rest == half and man & 1):
        man += 1
        if man >> 24:
            man >>= 1
            e += 1
    return e << 23 | (man & 0x7FFFFF)


def channels(t, fmt):
    b = [(t >> (8 * k)) & 0xFF for k in range(4)]
    return [b[2], b[1], b[0], b[3]] if fmt else b


def filt_lane(texels, fu, fv, ctl):
    """RGBA fp32 of one lane from its four raw texels."""
    fmt = ctl >> 1 & 1
    ch = [channels(t, fmt) for t in texels]
    out = []
    for k in range(4):
        a, b, c, d = ch[0][k], ch[1][k], ch[2][k], ch[3][k]
        if ctl & 1:
            top = a * (256 - fu) + b * fu
            bot = c * (256 - fu) + d * fu
            r = top * (256 - fv) + bot * fv
        else:
            r = a << 16
        out.append(conv(r))
    return out


def filt_quad(texels, fu, fv, ctl, mask, value):
    """atg_tu_filter: tr_data's 16 words (lane-major RGBA)."""
    words = []
    for l in range(4):
        if not mask >> l & 1:
            words += [0, 0, 0, 0]
        elif ctl >> 2 & 1:
            words += [value[l], 0, 0, 0]
        else:
            words += filt_lane(texels[l], fu[l], fv[l], ctl)
    return words


def fetch(mem, addrs, ctl, mask):
    """atg_tu_cache: the raw texels (only texel 0 without bilinear; masked
    lanes and texsz read nothing, 0)."""
    out = []
    for l in range(4):
        row = []
        for t in range(4):
            use = mask >> l & 1 and not ctl >> 2 & 1 and (t == 0 or ctl & 1)
            row.append(mem.rd32(addrs[l][t] & ~3) if use else 0)
        out.append(row)
    return out


def sample(mem, op, d, coords, mask):
    """A whole quad through the TU: 16 words (lane-major RGBA)."""
    a, fu, fv, ctl, val = quad_addr(op, d, coords, mask)
    return filt_quad(fetch(mem, a, ctl, mask), fu, fv, ctl, mask, val)
