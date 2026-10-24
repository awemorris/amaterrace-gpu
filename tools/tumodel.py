#!/usr/bin/env python3
# tumodel.py: the reference model of the texture unit (spec/gpu/tu/*.md),
# bit for bit: the descriptor and the level offsets of atg_tu_desc, the cube
# face selection and division of atg_tu_cube, the addressing of atg_tu_addr
# (LOD, mip levels, the passes of mip linear and 3D linear filtering, the
# layer, wrap on integer texel coordinates after the texel offsets, clamp to
# border, cube edges, bilinear footprint, linear or 4x4 tiled addresses,
# texsz), the border texels of atg_tu_cache, the texel conversion, depth
# compare and filter of atg_tu_filter.  Used by tools/tu-vectors.py (unit
# vectors) and tools/rx-tex-scene.py (the textured scene).  A module only;
# it has no command line.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as RX  # noqa: E402

M32 = 0xFFFFFFFF
LAM_MIN = -32768
ONE = 0x3F800000

OP_TEXL, OP_TEXB, OP_TEXF, OP_TEXSZ = 0, 1, 2, 3
# tx_op (8 bits): [1:0] the operation, [2] the .c form (Dref in word 3; the TU
# compares by the sampler), [3] gather (texl) or the depth query (texsz.d),
# [5:4] gather's component, [6] query (texb: texqlod; texsz: texsz.l), [7] 0.
OPB_CFORM, OPB_GATHER, OPB_COMP, OPB_QUERY = 2, 3, 4, 6
OPB_DEPTHQ = 3
# tx_coord lane words: 0 u (x), 1 v (y), 2 rs2 (lod, bias, texf's level),
# 3 Dref, 4 the third coordinate (layer, w, cube z; rs1+2 of a .3 form).
# tx_off: [3:0] du, [7:4] dv, [11:8] dw (signed texel offsets).

# Descriptor words (docs/ghci.md section 8.4: STATE 0x090 + 16 s + word).
D_BASE, D_SIZE, D_IMAGE, D_STRIDE, D_SAMPLER, D_LOD = 0, 1, 2, 3, 4, 5
# TEX_IMAGE: [3:0] level count, [7:4] format (0 RGBA8, 1 BGRA8, 2 D24,
# 3 D32_SFLOAT), [8] 4x4 tiled, [11:9] view type, [15:12] log2(samples)
# (reserved, 0), [31:16] depth (3D) or layer count (2D array).
IMG_FMT, IMG_TILED, IMG_TYPE, IMG_COUNT = 4, 8, 9, 16
FMT_RGBA8, FMT_BGRA8, FMT_D24, FMT_D32F = 0, 1, 2, 3
TYPE_2D, TYPE_ARRAY, TYPE_3D, TYPE_CUBE = 0, 1, 2, 3
# TEX_SAMPLER: wrap u [1:0], v [3:2], w [5:4] (0 repeat, 1 mirrored repeat,
# 2 clamp to edge, 3 clamp to border), mag linear [6], min linear [7], mip
# linear [8], compare [9], compare op [12:10] (VkCompareOp), border colour
# [15:13] (VkBorderColor), unnormalized coordinates [16], mipLodBias [31:19]
# (s5.8).
SAMP_WRAP_W, SAMP_MAG_LIN, SAMP_MIN_LIN, SAMP_MIP_LIN, SAMP_CMP = 4, 6, 7, 8, 9
SAMP_CMP_OP, SAMP_BORDER, SAMP_UNNORM, SAMP_LOD_BIAS = 10, 13, 16, 19
# TEX_LOD: [11:0] minLod, [23:12] 15.996 - maxLod (4.8 fixed, so that a word
# of 0 does not clamp).
LOD_NONE = 0
WRAP_REPEAT, WRAP_MIRROR, WRAP_EDGE, WRAP_BORDER = 0, 1, 2, 3

# ta_ctl / tc_ctl bits (24): [0] bilinear, [1] format low bit, [2] no fetch
# (texsz, texqlod), [3] texf, [4] a later pass follows (the filter keeps its
# sums), [5] not the first pass (the filter adds to its sums), [7:6] border
# colour class, [8] depth format, [9] compare, [12:10] its op, [13] gather,
# [15:14] its component, [16] texqlod, [17] the pass's second slice (3D
# linear), [18] the pass's second level (mip linear).
CTL_BIL, CTL_FMT, CTL_SZ, CTL_TEXF, CTL_MORE, CTL_ACC = 0, 1, 2, 3, 4, 5
CTL_BORDER, CTL_DEPTH, CTL_CMP, CTL_CMP_OP = 6, 8, 9, 10
CTL_GATHER, CTL_COMP, CTL_QLOD, CTL_P0, CTL_P1 = 13, 14, 16, 17, 18

# Cube faces (Vulkan's table): (major axis, sign), s_c, t_c as (axis, sign).
CUBE_FACES = [((0, 1), (2, -1), (1, -1)), ((0, -1), (2, 1), (1, -1)),
              ((1, 1), (0, 1), (2, 1)), ((1, -1), (0, 1), (2, -1)),
              ((2, 1), (0, 1), (1, -1)), ((2, -1), (0, -1), (1, -1))]
# A texel beyond one edge of face f (edge 0: i < 0, 1: i >= n, 2: j < 0,
# 3: j >= n; a the coordinate along the edge): (face, i', j') with the
# expressions 0 '0', 1 'n-1', 2 'a', 3 'n-1-a' (from the geometry).
CUBE_ADJ = [[(4, 1, 2), (5, 0, 2), (2, 1, 3), (3, 1, 2)],
            [(5, 1, 2), (4, 0, 2), (2, 0, 2), (3, 0, 3)],
            [(1, 2, 0), (0, 3, 0), (5, 3, 0), (4, 2, 0)],
            [(1, 3, 1), (0, 2, 1), (4, 2, 1), (5, 3, 1)],
            [(1, 1, 2), (0, 0, 2), (2, 2, 1), (3, 2, 0)],
            [(0, 1, 2), (1, 0, 2), (2, 3, 0), (3, 3, 1)]]


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def sat(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def s16(v):
    v &= 0xFFFF
    return v - (1 << 16) if v >> 15 else v


def s4(v):
    v &= 0xF
    return v - 16 if v >> 3 else v


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


def coord_t(f, mode):
    """The normalized coordinate with 24 fraction bits before the texel
    coordinate: repeat floor(u 2^24) mod 2^24, mirrored repeat mod 2^25 (a
    translation by whole periods), clamp to edge and border floor(u 2^24)
    clamped to [-16, 17] (no texel offset reaches back into the level from
    beyond).  Zeros, denormals and NaN give 0; infinities 0 (repeat,
    mirror) or the ends."""
    s, e, m = _fields(f)
    if e == 0 or (e == 255 and f & 0x7FFFFF):
        return 0
    if mode in (WRAP_EDGE, WRAP_BORDER):
        if e >= 131:	# |u| >= 16
            return -(16 << 24) if s else 17 << 24
        k = e - 126	# u * 2^24 = m * 2^k, k <= 4
        if k >= 0:
            q, st = m << k, 0
        elif k > -24:
            q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
        else:
            q, st = 0, 1
        v = -(q + st) if s else q
        return sat(v, -(16 << 24), 17 << 24)
    if e == 255:
        return 0
    k = e - 126
    if k >= 0:
        q, st = (m << k) & ((1 << 25) - 1) if k < 25 else 0, 0
    else:
        q, st = m >> -k, 1 if m & ((1 << -k) - 1) else 0
    t = (-(q + st) if s else q) & ((1 << 25) - 1)
    return t & ((1 << 24) - 1) if mode == WRAP_REPEAT else t


def unnorm_c(f):
    """An unnormalized coordinate in texels with 8 fraction bits (floor),
    clamped to [-2^28, 2^28]."""
    return sat(fx32(f, 8), -(1 << 28), 1 << 28)


def wrap_idx(i, n, mode):
    """An integer texel coordinate (after the offset) into the level:
    (index, border texel).  Repeat and mirrored repeat by Vulkan's formulas
    (the index is within 9 texels of [0, n) or [0, 2n))."""
    if mode == WRAP_REPEAT:
        return i % n, 0
    if mode == WRAP_MIRROR:
        m = i % (2 * n)
        return (m if m < n else 2 * n - 1 - m), 0
    if mode == WRAP_BORDER:
        return sat(i, 0, n - 1), int(i < 0 or i >= n)
    return sat(i, 0, n - 1), 0


def rne_layer(f, cnt):
    """Vulkan's layer: clamp(RNE(a), 0, count - 1); NaN, zeros, denormals
    and negative values give 0."""
    s, e, m = _fields(f)
    if e == 0 or (e == 255 and f & 0x7FFFFF) or s:
        return 0
    if e >= 150 + 16:
        return cnt - 1
    if e >= 150:
        v = m << (e - 150)
    else:
        k = 150 - e
        if k > 24:
            v = 0
        else:
            q, rem, half = m >> k, m & ((1 << k) - 1), 1 << (k - 1)
            v = q + (1 if rem > half or (rem == half and q & 1) else 0)
    return min(v, cnt - 1)


def l2(x):
    """log2 with 8 fraction bits: the msb's position and the 8 bits below."""
    p = x.bit_length() - 1
    return p * 256 + (((x << 8) >> p) & 0xFF)


# ---------------------------------------------------------------------------
# The descriptor (atg_tu_desc).

def img(d, pos, n):
    return d[D_IMAGE] >> pos & ((1 << n) - 1)


def levels(d):
    n = img(d, 0, 4)
    return 1 if n == 0 else 13 if n > 13 else n


def fmt(d):
    f = img(d, IMG_FMT, 4)
    return f if f < 4 else FMT_RGBA8


def vtype(d):
    """The view type as sampled (unnormalized coordinates: 2D)."""
    t = img(d, IMG_TYPE, 3)
    if d[D_SAMPLER] >> SAMP_UNNORM & 1 or t > 3:
        return TYPE_2D
    return t


def count(d):
    c = img(d, IMG_COUNT, 16)
    return c if c else 1


def size(d, lv):
    w, h = d[D_SIZE] & 0xFFFF, d[D_SIZE] >> 16
    w, h = w if w else 1, h if h else 1
    return max(1, w >> lv), max(1, h >> lv)


def depth_l(d, lv):
    """The depth of level lv (view type 3D as written; 1 for the others)."""
    return max(1, count(d) >> lv) if img(d, IMG_TYPE, 3) == TYPE_3D else 1


def plane(d, lv):
    """The bytes of a 2D plane of level lv, rounded up to 64 (a slice of a
    3D level, a level of the other types)."""
    w, h = size(d, lv)
    if img(d, IMG_TILED, 1):
        return ((w + 3) >> 2) * ((h + 3) >> 2) * 64 & M32
    return (w * h * 4 + 63) & ~63 & M32


def level_offset(d, lv):
    """The byte offset of level lv from the layer's base: the levels back to
    back, each plane x depth bytes."""
    off = 0
    for k in range(lv):
        off = (off + plane(d, k) * depth_l(d, k)) & M32
    return off


def texel_addr(d, lv, i, j, layer=0, k=0):
    w, _ = size(d, lv)
    b = (d[D_BASE] + layer * d[D_STRIDE] + level_offset(d, lv) + k * plane(d, lv)) & M32
    if img(d, IMG_TILED, 1):
        a = b + (j >> 2) * ((w + 3) >> 2) * 64 + (i >> 2) * 64 + ((j & 3) * 4 + (i & 3)) * 4
    else:
        a = b + (j * w + i) * 4
    return a & M32 & ~3	# bits 1:0 are 0 (bit 0 marks a border texel)


# ---------------------------------------------------------------------------
# Cube maps (atg_tu_cube).

def _cube_comp(f):
    """A direction component: zeros, denormals and NaN +0, infinities the
    largest finite value."""
    e = (f >> 23) & 0xFF
    if e == 0 or (e == 255 and f & 0x7FFFFF):
        return 0
    if e == 255:
        return (f & 0x80000000) | 0x7F7FFFFF
    return f


def cube_face(x, y, z):
    """Vulkan's face selection: the largest magnitude, z before y before x
    on ties."""
    c = [_cube_comp(v) for v in (x, y, z)]
    a = [v & 0x7FFFFFFF for v in c]
    ax = 2 if a[2] >= a[0] and a[2] >= a[1] else 1 if a[1] >= a[0] else 0
    return 2 * ax + (c[ax] >> 31)


def cube_scaled(v, neg_t, em, mm):
    """floor(v 2^(150 - em)) (the sign flipped by neg_t) clamped to
    [-3 mm, 3 mm]."""
    e = (v >> 23) & 0xFF
    if e == 0:
        return 0
    neg = (v >> 31) ^ neg_t
    mv = (v & 0x7FFFFF) | 0x800000
    sh = e - em
    if sh > 2:
        return -3 * mm if neg else 3 * mm
    if sh >= 0:
        q, st = mv << sh, 0
    elif sh > -24:
        q, st = mv >> -sh, 1 if mv & ((1 << -sh) - 1) else 0
    else:
        q, st = 0, 1
    return sat(-(q + st) if neg else q, -3 * mm, 3 * mm)


def cube_proj(x, y, z, face=None):
    """(face, s, t): the face (Vulkan's selection, or the given one) and the
    face coordinates with 24 fraction bits, s = floor(2^23 (sc' + 3 m) / m)
    - 2^24 with m the major axis's significand and sc' = floor(sc 2^(150 -
    e)) clamped to [-3 m, 3 m] (in [0, 2^24] on the selected face, wider on
    a given one).  A zero major axis gives the centre."""
    c = [_cube_comp(v) for v in (x, y, z)]
    if face is None:
        face = cube_face(x, y, z)
    (ma, _), (sa, ss), (ta, ts) = CUBE_FACES[face]
    em = (c[ma] >> 23) & 0xFF
    if em == 0:
        return face, 1 << 23, 1 << 23
    mm = (c[ma] & 0x7FFFFF) | 0x800000
    s = ((cube_scaled(c[sa], int(ss < 0), em, mm) + 3 * mm) << 23) // mm - (1 << 24)
    t = ((cube_scaled(c[ta], int(ts < 0), em, mm) + 3 * mm) << 23) // mm - (1 << 24)
    return face, s, t


def cube_texel(face, i, j, n):
    """A texel of a bilinear footprint on a cube face (i, j in [-1, n]):
    (face, i, j) on the face, beyond one edge from the adjacent face, beyond
    two (a corner: Vulkan allows a replacement that keeps three equal
    texels' value) the face's own corner texel."""
    oi, oj = i < 0 or i >= n, j < 0 or j >= n
    if oi and oj:
        return face, sat(i, 0, n - 1), sat(j, 0, n - 1)
    if not oi and not oj:
        return face, i, j
    e, a = (0 if i < 0 else 1, j) if oi else (2 if j < 0 else 3, i)
    g, xi, xj = CUBE_ADJ[face][e]
    ex = (0, n - 1, a, n - 1 - a)
    return g, ex[xi], ex[xj]


# ---------------------------------------------------------------------------
# The level of detail (atg_tu_addr).

def opbase(op):
    """The tx_op's operation (0 texl, 1 texb, 2 texf, 3 texsz) and its
    modifiers: gather (texl), component, query (texb: the LOD; texsz: the
    level count)."""
    base = op & 3
    return (base, int(base == OP_TEXL and op >> OPB_GATHER & 1), op >> OPB_COMP & 3,
            int(base in (OP_TEXB, OP_TEXSZ) and op >> OPB_QUERY & 1))


def samp_mode(d, op):
    """(depth format, compare, filtering allowed, mip linear) of a quad."""
    samp = d[D_SAMPLER]
    base, gather, _, query = opbase(op)
    depth = fmt(d) >> 1
    cmp = int(depth and samp >> SAMP_CMP & 1 and base in (OP_TEXL, OP_TEXB) and not query)
    filt = int(not depth or cmp)
    unn = samp >> SAMP_UNNORM & 1
    return depth, cmp, filt, int(filt and not gather and not unn and samp >> SAMP_MIP_LIN & 1)


def lod_clamps(d):
    """(minLod, maxLod, mipLodBias) with 8 fraction bits."""
    lv, samp = d[D_LOD], d[D_SAMPLER]
    bias = samp >> SAMP_LOD_BIAS & 0x1FFF
    return lv & 0xFFF, 0xFFF - (lv >> 12 & 0xFFF), bias - (1 << 13) if bias >> 12 else bias


def lod_axis(a, n):
    mx = max(abs(a[1] - a[0]), abs(a[2] - a[0]))
    return l2(mx) + l2(n) - 4096 if mx else LAM_MIN


def lod_quad(d, coords):
    """texb: the quad's LOD from lanes 0, 1 (x + 1) and 2 (y + 1): u, v (and
    w of a 3D image) as floor(x 2^16), or a cube's face coordinates of the
    three lanes on lane 0's face (>> 8), against the level-0 size."""
    t = vtype(d)
    w, h = size(d, 0)
    if t == TYPE_CUBE:
        f0 = cube_face(coords[0][0], coords[0][1], coords[0][4])
        st = [cube_proj(c[0], c[1], c[4], f0) for c in coords[:3]]
        lam = [lod_axis([x[1] >> 8 for x in st], w), lod_axis([x[2] >> 8 for x in st], w)]
    else:
        lam = [lod_axis([fx32(c[0], 16) for c in coords[:3]], w),
               lod_axis([fx32(c[1], 16) for c in coords[:3]], h)]
    if t == TYPE_3D:
        lam.append(lod_axis([fx32(c[4], 16) for c in coords[:3]], count(d)))
    return sat16(max(lam))


def lane_lambda(op, d, c, lam_q):
    """texl/texb: (lambda', lambda): the LOD with the shader's and the
    sampler's bias, and that clamped to [minLod, maxLod]; both 0 with
    unnormalized coordinates."""
    if d[D_SAMPLER] >> SAMP_UNNORM & 1:
        return 0, 0
    base, _, _, query = opbase(op)
    mn, mx, sb = lod_clamps(d)
    if base == OP_TEXB:
        lam = lam_q if query else sat16(lam_q + sat16(fx32(c[2], 8)))
    else:
        lam = sat16(fx32(c[2], 8))
    lam = sat16(lam + sb)
    lc = mx if lam > mx else lam
    return lam, mn if lc < mn else lc	# max(min(lambda', maxLod), minLod)


def lane_lod(op, d, c, lam_q):
    """One lane of texl/texb: (linear, level of the first level's passes,
    level of the second's, the 8-bit weight fl of the second level)."""
    samp = d[D_SAMPLER]
    _, gather, _, _ = opbase(op)
    _, _, filt, miplin = samp_mode(d, op)
    if gather:
        return 1, 0, 0, 0
    _, lam = lane_lambda(op, d, c, lam_q)
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


# ---------------------------------------------------------------------------
# Addressing (atg_tu_addr).

def wraps(d):
    """The address modes (u, v, w); unnormalized coordinates read repeat and
    mirrored repeat as clamp to edge."""
    samp = d[D_SAMPLER]
    m = [samp & 3, samp >> 2 & 3, samp >> SAMP_WRAP_W & 3]
    if samp >> SAMP_UNNORM & 1:
        m = [x if x >= WRAP_EDGE else WRAP_EDGE for x in m]
    return m


def axis_c(f, mode, n, unn):
    """The texel coordinate of one axis with 8 fraction bits (floor)."""
    return unnorm_c(f) if unn else (coord_t(f, mode) * n) >> 16


def lane_layer(op, d, c):
    """The lane's layer: a 2D array's RNE(w4) clamped, texf's integer layer
    of an array or a cube; 0 otherwise (a cube's face is chosen per
    texel)."""
    t = vtype(d)
    if op & 3 == OP_TEXF:
        if t == TYPE_ARRAY:
            return sat(s32(c[4]), 0, count(d) - 1)
        if t == TYPE_CUBE:
            return sat(s32(c[4]), 0, 5)
        return 0
    return rne_layer(c[4], count(d)) if t == TYPE_ARRAY else 0


def lane_addr(op, d, c, lam_q, pas, off, cube=None):
    """One lane in pass pas (bit 0: the second slice of 3D linear filtering,
    bit 1: the second level of mip linear filtering): (addresses of texels
    0-3, fu, fv, fl, fw, linear, value).  c is the lane's five coordinate
    words (u, v, rs2, Dref, the third coordinate); lam_q the quad LOD
    (texb); off the 12-bit texel offsets; cube the lane's (face, s, t).
    Bit 0 of an address marks a border texel."""
    base, gather, _, query = opbase(op)
    t = vtype(d)
    if base == OP_TEXSZ:
        lv = min(c[0] & M32, 15)
        if query:
            return [0] * 4, 0, 0, 0, 0, 0, levels(d)
        if op >> OPB_DEPTHQ & 1:
            r = count(d) if t == TYPE_ARRAY else depth_l(d, lv) if t == TYPE_3D else 1
            return [0] * 4, 0, 0, 0, 0, 0, r
        w, h = size(d, lv)
        return [0] * 4, 0, 0, 0, 0, 0, (h & 0xFFFF) << 16 | (w & 0xFFFF)
    du, dv, dw = s4(off), s4(off >> 4), s4(off >> 8)
    if t == TYPE_CUBE:
        du = dv = dw = 0
    if base == OP_TEXF:
        lev = s32(c[2])
        lv = 0 if lev < 0 else min(lev, levels(d) - 1)
        w, h = size(d, lv)
        i = sat(s32(c[0]) + du, 0, w - 1)
        j = sat(s32(c[1]) + dv, 0, h - 1)
        k = sat(s32(c[4]) + dw, 0, depth_l(d, lv) - 1) if t == TYPE_3D else 0
        return [texel_addr(d, lv, i, j, lane_layer(op, d, c), k)] * 4, 0, 0, 0, 0, 0, 0
    if query:
        lp, lam = lane_lambda(op, d, c, lam_q)
        dq = sat(lam, 0, (levels(d) - 1) << 8)
        return [0] * 4, 0, 0, 0, 0, 0, (lp & 0xFFFF) << 16 | dq
    _, cmp, _, _ = samp_mode(d, op)
    val = c[3] & M32 if cmp else 0
    lin, lv0, lv1, fl = lane_lod(op, d, c, lam_q)
    lv = lv1 if pas >> 1 else lv0
    w, h = size(d, lv)
    mu, mv, mw = wraps(d)
    unn = d[D_SAMPLER] >> SAMP_UNNORM & 1
    layer = lane_layer(op, d, c)
    face = 0
    if t == TYPE_CUBE:
        face, s, tt = cube
        h = w
        cu, cv = (s * w) >> 16, (tt * w) >> 16
    else:
        cu, cv = axis_c(c[0], mu, w, unn), axis_c(c[1], mv, h, unn)
    # The slice of a 3D level: nearest, or linear in depth (gather nearest).
    k, bk, fw = 0, 0, 0
    if t == TYPE_3D:
        dl = depth_l(d, lv)
        cw = axis_c(c[4], mw, dl, 0)
        if lin and not gather:
            cw -= 128
            fw = cw & 0xFF
            k, bk = wrap_idx((cw >> 8) + dw + (pas & 1), dl, mw)
        else:
            k, bk = wrap_idx((cw >> 8) + dw, dl, mw)

    def tex(i, j, bi, bj):
        if t == TYPE_CUBE:
            g, ii, jj = cube_texel(face, i, j, w)
            return texel_addr(d, lv, ii, jj, g, 0)
        return texel_addr(d, lv, i, j, layer, k) | (bi | bj | bk)

    if not lin:
        i, j = (cu >> 8) + du, (cv >> 8) + dv
        if t == TYPE_CUBE:
            return [tex(sat(i, 0, w - 1), sat(j, 0, w - 1), 0, 0)] * 4, 0, 0, fl, 0, 0, val
        i, bi = wrap_idx(i, w, mu)
        j, bj = wrap_idx(j, h, mv)
        return [tex(i, j, bi, bj)] * 4, 0, 0, fl, 0, 0, val
    cu, cv = cu - 128, cv - 128
    i0, j0 = (cu >> 8) + du, (cv >> 8) + dv
    fu, fv = cu & 0xFF, cv & 0xFF
    if t == TYPE_CUBE:
        return ([tex(i0, j0, 0, 0), tex(i0 + 1, j0, 0, 0), tex(i0, j0 + 1, 0, 0),
                 tex(i0 + 1, j0 + 1, 0, 0)], fu, fv, fl, 0, 1, val)
    i1, bi1 = wrap_idx(i0 + 1, w, mu)
    j1, bj1 = wrap_idx(j0 + 1, h, mv)
    i0, bi0 = wrap_idx(i0, w, mu)
    j0, bj0 = wrap_idx(j0, h, mv)
    return ([tex(i0, j0, bi0, bj0), tex(i1, j0, bi1, bj0), tex(i0, j1, bi0, bj1),
             tex(i1, j1, bi1, bj1)], fu, fv, fl, fw, 1, val)


def border_class(d):
    """VkBorderColor >> 1: 0 transparent black, 1 opaque black, 2 opaque
    white (6 and 7 read as 0)."""
    b = d[D_SAMPLER] >> SAMP_BORDER & 7
    return 0 if b >= 6 else b >> 1


def quad_cube(op, d, coords):
    """The lanes' (face, s, t) of a cube quad that samples, else None."""
    base, _, _, query = opbase(op)
    if vtype(d) != TYPE_CUBE or base in (OP_TEXF, OP_TEXSZ) or query:
        return [None] * 4
    return [cube_proj(c[0], c[1], c[4]) for c in coords]


def quad_addr(op, d, coords, mask, off=0):
    """atg_tu_addr on one quad: op the 8-bit tx_op, coords[l] = (w0, w1, w2,
    w3, w4) of lane l, off the 12-bit tx_off.  Returns the passes, each
    (addr[l][t], wts[l], ctl, value[l]) with wts lane l = fu | fv << 8 |
    fl << 16 | fw << 24: pass 0; pass 1 (the second slice) when a lane of
    the mask has fw != 0; pass 2 (the second level) when one has fl != 0;
    pass 3 (both) when a lane's fw at the second level is not 0."""
    base, gather, comp, query = opbase(op)
    coords = [tuple(c) + (0,) * (5 - len(c)) for c in coords]
    lam_q = lod_quad(d, coords) if base == OP_TEXB else 0
    samp = d[D_SAMPLER]
    depth, cmp, _, _ = samp_mode(d, op)
    nofetch = base == OP_TEXSZ or query
    cube = quad_cube(op, d, coords)
    on = [ln for ln in range(4) if mask >> ln & 1]
    passes = []
    pas = 0
    while True:
        out = [lane_addr(op, d, coords[ln], lam_q, pas, off, cube[ln]) for ln in range(4)]
        dep = any(out[ln][4] for ln in on)
        mip = any(out[ln][3] for ln in on)
        lin = any(out[ln][5] for ln in on)
        nxt = {0: 1 if dep else 2 if mip else None, 1: 2 if mip else None,
               2: 3 if dep else None, 3: None}[pas]
        ctl = (lin << CTL_BIL | (fmt(d) & 1) << CTL_FMT | nofetch << CTL_SZ |
               (base == OP_TEXF) << CTL_TEXF | (nxt is not None) << CTL_MORE |
               (pas != 0) << CTL_ACC | border_class(d) << CTL_BORDER | depth << CTL_DEPTH |
               cmp << CTL_CMP | (samp >> SAMP_CMP_OP & 7) << CTL_CMP_OP |
               gather << CTL_GATHER | (comp if gather else 0) << CTL_COMP |
               (query and base == OP_TEXB) << CTL_QLOD | (pas & 1) << CTL_P0 |
               (pas >> 1) << CTL_P1)
        passes.append(([o[0] for o in out],
                       [o[1] | o[2] << 8 | o[3] << 16 | o[4] << 24 for o in out], ctl,
                       [o[6] for o in out]))
        if nxt is None:
            return passes
        pas = nxt


# ---------------------------------------------------------------------------
# The cache's border texels and the filter (atg_tu_cache, atg_tu_filter).

def rnd_f32(p, sh):
    """p * 2^-sh as fp32 (p > 0 an integer, the result normal), rounded to
    nearest even; 0 for p = 0."""
    if p == 0:
        return 0
    n = p.bit_length() - 1
    e = 127 + n - sh
    if n <= 23:     # exact
        return e << 23 | ((p << (23 - n)) & 0x7FFFFF)
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
    even (R < 2^24; R = a << 16 gives exactly the correctly rounded a / 255)."""
    return rnd_f32(r * 0x0101010101, 56)


def conv40(a):
    """An accumulated sum A = sum of R x W (the pass weights W sum to 2^16):
    A / (255 * 2^32) as A * 0x0101010101 / 2^72 (conv40(R << 16) ==
    conv(R))."""
    return rnd_f32(a * 0x0101010101, 72)


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


def channels(t, fm):
    b = [(t >> (8 * k)) & 0xFF for k in range(4)]
    return [b[2], b[1], b[0], b[3]] if fm else b


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


def pass_weight(wts, ctl):
    """The lane's weight in this pass (16 fraction bits): (fw or 256 - fw)
    x (fl or 256 - fl) by the pass's slice and level bits."""
    fl, fw = wts >> 16 & 0xFF, wts >> 24 & 0xFF
    a = fw if ctl >> CTL_P0 & 1 else 256 - fw
    b = fl if ctl >> CTL_P1 & 1 else 256 - fl
    return a * b


def fix8(v):
    """A signed value with 8 fraction bits as fp32 (exact)."""
    return 0 if v == 0 else rnd_f32(abs(v), 8) | (0x80000000 if v < 0 else 0)


def gather_lane(texels, ctl, dref):
    """Gather: component C of texels (i0, j1), (i1, j1), (i1, j0), (i0, j0)."""
    comp = ctl >> CTL_COMP & 3
    order = [texels[2], texels[3], texels[1], texels[0]]
    if ctl >> CTL_CMP & 1:
        return [ONE if c[0] else 0 for c in lane_texels(order, ctl, dref)]
    if ctl >> CTL_DEPTH & 1:
        if comp == 0:
            return [t if ctl >> CTL_FMT & 1 else conv24(t & 0xFFFFFF) for t in order]
        return [ONE if comp == 3 else 0] * 4
    return [conv(channels(t, ctl >> CTL_FMT & 1)[comp] << 16) for t in order]


class Filter:
    """atg_tu_filter: one quad a call; a pass with ctl[4] (more to follow)
    returns None and keeps its weighted sums for the next."""

    def __init__(self):
        self.acc = [[0] * 4 for _ in range(4)]

    def quad(self, texels, wts, ctl, mask, value):
        """tr_data's 16 words (lane-major RGBA), or None (ctl[4])."""
        words = []
        for ln in range(4):
            on = mask >> ln & 1
            if ctl >> CTL_SZ & 1 and ctl >> CTL_QLOD & 1:
                # texqlod: (the level accessed, lambda'), both / 256
                v = value[ln]
                words += [fix8(s16(v)), fix8(s16(v >> 16)), 0, 0] if on else [0] * 4
                continue
            if ctl >> CTL_SZ & 1:
                words += [value[ln] if on else 0, 0, 0, 0]
                continue
            if ctl >> CTL_GATHER & 1:
                words += gather_lane(texels[ln], ctl, value[ln]) if on else [0] * 4
                continue
            if ctl >> CTL_DEPTH & 1 and not ctl >> CTL_CMP & 1:
                # a depth format without compare: texel 0 as (D, 0, 0, 1)
                t = texels[ln][0]
                dv = t if ctl >> CTL_FMT & 1 else conv24(t & 0xFFFFFF)
                words += [dv, 0, 0, ONE] if on else [0] * 4
                continue
            r = lane_sums(texels[ln], wts[ln], ctl, value[ln])
            w = pass_weight(wts[ln], ctl)
            acc = self.acc[ln] if ctl >> CTL_ACC & 1 else [0] * 4
            self.acc[ln] = [acc[k] + r[k] * w for k in range(4)]
            if not ctl >> CTL_MORE & 1:
                words += [conv40(x) for x in self.acc[ln]] if on else [0] * 4
        return None if ctl >> CTL_MORE & 1 else words


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


def sample(mem, op, d, coords, mask, off=0):
    """A whole quad through the TU: 16 words (lane-major RGBA)."""
    flt = Filter()
    words = None
    for a, wts, ctl, val in quad_addr(op, d, coords, mask, off):
        words = flt.quad(fetch(mem, a, ctl, mask), wts, ctl, mask, val)
    return words
