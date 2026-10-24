#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/tex_scene.txt for sim/tb/atg_top_tex_tb.v and the
Verilator harness's TEX mode: textured triangles drawn with twelve DRAWs
through the VF (attribute 0 the clip-space position RGBA32F, attribute 1
the texture coordinates RG32F) and the TU (slot 3; the textures laid out
as the TU's descriptor says, docs/ghci.md section 8.4).  Draw 1: a
16x16 RGBA8 texture with 5 mip levels, a fragment program that
interpolates (u, v) (three lda, fmul, two fmadd each) and samples with
texb (the LOD from the quad's derivatives), linear rows, repeat in u and
mirrored repeat in v, bilinear magnification, nearest minification.
Then SET_REG changes slot 3 (which waits until draw 1 is done) to a 4x4
tiled BGRA8 copy, clamp in u, repeat in v, nearest magnification,
bilinear minification, and the fragment program to one that samples with
texl at lod = 4 z; draw 2.  Draw 3: the linear copy again with texb,
clamp to border (opaque white) in u and v, bilinear and mip linear
(trilinear) filtering, minLod 0.5, maxLod 2.5 and mipLodBias 0.25.  Draw
4: a 16x16 D24 depth texture with 3 levels and a compare sampler
(LESS_OR_EQUAL, bilinear and mip linear: percentage closer filtering,
mipLodBias -0.25), texb.c with bias 0.5 and the fragment's z as Dref
(rs1+2).  Draw 5: a 16x16 D32_SFLOAT texture, compare GREATER, nearest,
clamp to border (opaque black), texl.c at lod 4 z with z as Dref.  Draw
6: texg.g (gather of G) from the linear copy, clamp to border (opaque
white) in u, repeat in v.  Draw 7: texqlod (the level accessed and
lambda' as the colour's R and G) with mipLodBias 0.5.  Draw 8: an 8x8 2D
array of 3 layers with 2 levels, texl.3 with the layer 4 z (RNE,
clamped) and the texel offsets (1, -1).  Draw 9: an 8x8x8 3D texture
with 3 levels, texb.3 with w = z, linear in all three axes and mip
linear (up to four passes), mirrored repeat in w.  Draw 10: a cube map
of 8x8 faces with 2 levels, texb.3 with the direction (2u - 1, 2v - 1,
0.35): bilinear across the faces' edges and corners, mip linear.  Draw
11: the linear copy with texl at lod 4 z and the offsets (3, -2), mirrored
repeat in u, repeat in v, bilinear.  Draw 12: unnormalized coordinates
(16 u, 16 v) on level 0, clamp to border (opaque white) in u, clamp to
edge in v, bilinear.  Depth LESS with write.  The colour and depth
buffers are what the reference models say (tools/rxmodel.py for the VF,
clip, setup, the fragment warps and the ROP; tools/gsi1fp.py for the
shader arithmetic; tools/tumodel.py for the TU).

Lines of the file (as tools/rx-raster-scene.py):
  N count        the number of R words (first line)
  I addr value   initial memory word (before the ring runs)
  R word         a ring word, in order
  E addr value   expected memory word after the final fence

  python3 -I tools/rx-tex-scene.py [SEED]
"""

import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402
import gsi1fp as FP  # noqa: E402
import rxmodel as M  # noqa: E402
import tumodel as T  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'sim', 'vec', 'tex_scene.txt')

W, H = 64, 48
RT = 0x00020000
RT_STRIDE = W * 4
DS = 0x00030000
DS_STRIDE = W * 4
POS = 0x00040000	# attribute 0: RGBA32F, stride 16
UV = 0x00041000	# attribute 1: RG32F, stride 8
VS = 0x00044000
FS1 = 0x00044400
FS2 = 0x00044800
FS3 = 0x00044C00
FS4 = 0x00044E00
FS5 = 0x00048800
FS6 = 0x00048C00
FS7 = 0x00049000
FS8 = 0x00049400
FS9 = 0x00049800
FS10 = 0x00049C00
FS11 = 0x0004A000
TEX1 = 0x00045000	# linear RGBA8, 5 levels
TEX2 = 0x00046000	# 4x4 tiled BGRA8, 5 levels
TEXD24 = 0x00047000	# D24 (stencil byte random), 3 levels
TEXD32 = 0x00048000	# D32_SFLOAT, 1 level
TEXA = 0x0004B000	# 2D array: 3 layers of 8x8 RGBA8, 2 levels
TEX3D = 0x0004C000	# 3D: 8x8x8 RGBA8, 3 levels
TEXC = 0x0004D000	# cube: 6 faces of 8x8 RGBA8, 2 levels
FENCES = 0x0005EF00
SLOT = 3
TW = 16
NLEV = 5

# STATE (design §2.3).
S_TOPOLOGY, S_INDEX_FORMAT, S_FIRST, S_COUNT = 0x020, 0x022, 0x023, 0x024
S_PRIM_RESTART, S_INSTANCE_COUNT, S_FIRST_INSTANCE, S_VERTEX_OFFSET = 0x025, 0x026, 0x027, 0x028
S_ATTR_BASE, S_ATTR_DESC, S_ATTR_DST = 0x030, 0x031, 0x1C0
S_VARYING_COUNT, S_PROVOKING = 0x05B, 0x05D
S_VS_BASE, S_FS_BASE = 0x190, 0x192
S_TU = 0x090 + 16 * SLOT

VS_SRC = """
	exp r0, 0x000
	exp r1, 0x001
	exp r2, 0x002
	exp r3, 0x003
	exp r4, 0x010
	exp r5, 0x011
	end
"""


def interp_src():
    s = []
    for c in range(2):
        w = 4 + c	# the PT word of varying component c (u, v)
        s += ['lda r8, %d' % (w << 2 | 0), 'lda r9, %d' % (w << 2 | 1),
              'lda r10, %d' % (w << 2 | 2),
              'fmul.s r%d, r8, r0' % (12 + c), 'fmadd.s r%d, r9, r1, r%d' % (12 + c, 12 + c),
              'fmadd.s r%d, r10, r2, r%d' % (12 + c, 12 + c)]
    return s


EXP = ['exp r16, 0x100', 'exp r17, 0x101', 'exp r18, 0x102', 'exp r19, 0x103', 'end']
FS1_SRC = '\n'.join(interp_src() + ['texb r16, r12, zero, %d' % SLOT] + EXP) + '\n'
FS2_SRC = '\n'.join(interp_src() + ['movi r20, 0x40800000', 'fmul.s r14, r3, r20',
                                    'texl r16, r12, r14, %d' % SLOT] + EXP) + '\n'
# Dref (rs1+2 = r14) is a copy of z.
FS3_SRC = '\n'.join(interp_src() + ['fsgnj.s r14, r3, r3', 'movi r20, 0x3F000000',
                                    'texb.c r16, r12, r20, %d' % SLOT] + EXP) + '\n'
FS4_SRC = '\n'.join(interp_src() + ['fsgnj.s r14, r3, r3', 'movi r20, 0x40800000',
                                    'fmul.s r21, r3, r20', 'texl.c r16, r12, r21, %d' % SLOT] +
                     EXP) + '\n'
FS5_SRC = '\n'.join(interp_src() + ['texg.g r16, r12, %d' % SLOT] + EXP) + '\n'
FS6_SRC = '\n'.join(interp_src() + ['texqlod r16, r12, %d' % SLOT] + EXP) + '\n'
# The layer (rs1+2 = r14) is 4 z.
FS7_SRC = '\n'.join(interp_src() + ['movi r20, 0x40800000', 'fmul.s r14, r3, r20',
                                    'texl.3 r16, r12, zero, %d, off(1, -1)' % SLOT] + EXP) + '\n'
# w (rs1+2) is z.
FS8_SRC = '\n'.join(interp_src() + ['fsgnj.s r14, r3, r3', 'texb.3 r16, r12, zero, %d' % SLOT] +
                     EXP) + '\n'
# The direction (2u - 1, 2v - 1, 0.35).
FS9_SRC = '\n'.join(interp_src() + ['fmadd.s r12, r12, two, mone', 'fmadd.s r13, r13, two, mone',
                                    'movi r14, 0x3EB33333', 'texb.3 r16, r12, zero, %d' % SLOT] +
                     EXP) + '\n'
FS10_SRC = '\n'.join(interp_src() + ['movi r20, 0x40800000', 'fmul.s r14, r3, r20',
                                     'texl r16, r12, r14, %d, off(3, -2)' % SLOT] + EXP) + '\n'
# Unnormalized: (16 u, 16 v).
FS11_SRC = '\n'.join(interp_src() + ['movi r20, 0x41800000', 'fmul.s r12, r12, r20',
                                     'fmul.s r13, r13, r20', 'texl r16, r12, zero, %d' % SLOT] +
                      EXP) + '\n'


def f(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def hdr(vendor, op, tag, flags, n):
    return (vendor << 30) | (op << 24) | (tag << 16) | (flags << 8) | n


def interp(vals, b0, b1, b2):
    t = FP.fpu(FP.FMUL, vals[0], b0, 0, 0)
    t = FP.fpu(FP.FMADD, vals[1], b1, t, 0)
    return FP.fpu(FP.FMADD, vals[2], b2, t, 0)


def texel(lv, i, j):
    """RGBA bytes of texel (i, j) of level lv: a checkerboard per level."""
    hue = [(230, 40, 40), (40, 200, 60), (50, 90, 230), (230, 200, 30), (200, 50, 200)][lv]
    cell = max(1, (TW >> lv) // 4)
    on = ((i // cell) + (j // cell)) & 1
    shade = 128 + (i * 127) // max(1, (TW >> lv) - 1)
    if on:
        return (hue[0], hue[1], hue[2], 255)
    return (shade, shade, shade, 255)


def rgba(c):
    return c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24


def desc(base, w, h, levels, fmt=0, tiled=0, typ=0, cnt=0, stride=0, samp=0, lod=T.LOD_NONE):
    """A slot's 16 words (docs/ghci.md section 8.4)."""
    img = (levels | fmt << T.IMG_FMT | tiled << T.IMG_TILED | typ << T.IMG_TYPE |
           cnt << T.IMG_COUNT)
    return [base, h << 16 | w, img, stride, samp, lod] + [0] * 10


def stride_of(d):
    """The bytes of one layer's levels (the layer stride a driver gives)."""
    return T.level_offset(d, T.levels(d))


def textures(init, d1, d2):
    """Both copies of the checkerboard (linear RGBA8 and tiled BGRA8)."""
    for lv in range(NLEV):
        w = TW >> lv
        for j in range(w):
            for i in range(w):
                r, g, b, al = texel(lv, i, j)
                init.append((T.texel_addr(d1, lv, i, j), rgba((r, g, b, al))))
                init.append((T.texel_addr(d2, lv, i, j), rgba((b, g, r, al))))


def depth_textures(init, r, d24, d32):
    """The depth textures: D24 with 3 levels and D32F with one level; slopes
    and steps in [0.05, 0.95]."""
    for lv in range(3):
        w = TW >> lv
        for j in range(w):
            for i in range(w):
                x = 0.05 + 0.9 * ((i + 2 * j) % (2 * w)) / (2 * w - 1)
                if lv == 1:
                    x = 1.0 - x
                c = int(round(x * ((1 << 24) - 1)))
                init.append((T.texel_addr(d24, lv, i, j), r.getrandbits(8) << 24 | c))
    for j in range(TW):
        for i in range(TW):
            x = 0.1 + 0.8 * (((i // 4) + (j // 4)) & 1) * 0.5 + 0.02 * i
            init.append((T.texel_addr(d32, 0, i, j), f(x)))


def new_textures(init, da, d3, dc):
    """The array (a colour per layer), the 3D texture (a colour gradient in
    depth) and the cube (a colour per face), each with a checker."""
    for lv in range(2):
        w = 8 >> lv
        for layer in range(3):
            for j in range(w):
                for i in range(w):
                    on = ((i >> (1 - lv)) + (j >> (1 - lv))) & 1
                    c = [(250, 60, 60), (60, 230, 90), (70, 110, 250)][layer]
                    init.append((T.texel_addr(da, lv, i, j, layer),
                                 rgba(c + (255,)) if on else rgba((40 + 60 * lv,) * 3 + (255,))))
    for lv in range(3):
        w = 8 >> lv
        for k in range(w):
            for j in range(w):
                for i in range(w):
                    on = (i + j + k) & 1
                    v = (k * 255) // max(1, w - 1)
                    init.append((T.texel_addr(d3, lv, i, j, 0, k),
                                 rgba((v, 255 - v, 128 if on else 30, 255))))
    hues = [(240, 50, 50), (60, 220, 220), (60, 230, 60), (230, 60, 230), (60, 60, 240),
            (240, 240, 60)]
    for lv in range(2):
        w = 8 >> lv
        for face in range(6):
            for j in range(w):
                for i in range(w):
                    on = (i + j) & 1
                    c = hues[face] if on else tuple(x // 2 for x in hues[face])
                    init.append((T.texel_addr(dc, lv, i, j, face), rgba(c + (255,))))


def triangles(r, n, big, u0r=(-1.0, 1.0), spans=(0.3, 1.0, 2.5, 6.0, 12.0)):
    tris = []
    for t in range(n):
        vs = []
        cx, cy = r.uniform(-0.6, 0.6), r.uniform(-0.6, 0.6)
        s = big if t < 2 else r.uniform(0.2, 0.6)
        for _ in range(3):
            w = r.uniform(1.0, 1.5)
            vs.append(((cx + r.uniform(-s, s)) * w, (cy + r.uniform(-s, s)) * w,
                       r.uniform(0.05, 0.95) * w, w))
        # texture coordinates: from a small range (magnified) to a large one (minified)
        span = r.choice(spans)
        u0, v0 = r.uniform(*u0r), r.uniform(*u0r)
        uvs = [(u0 + r.uniform(0, span), v0 + r.uniform(0, span)) for _ in range(3)]
        tris.append((vs, uvs))
    return tris


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    r = random.Random(seed)
    st = M.State()
    mem = M.Mem()
    init = []
    ring = []

    for y in range(H):
        for x in range(W):
            init.append((RT + y * RT_STRIDE + x * 4, 0xFF202020))
            init.append((DS + y * DS_STRIDE + x * 4, f(1.0)))
    # The samplers (TEX_SAMPLER, docs/ghci.md section 8.4).
    MAG, MIN, MIP = 1 << T.SAMP_MAG_LIN, 1 << T.SAMP_MIN_LIN, 1 << T.SAMP_MIP_LIN
    samp1 = 0 | 1 << 2 | MAG
    samp2 = 2 | 0 << 2 | MIN
    # clamp to border (FLOAT_OPAQUE_WHITE 4), bilinear, trilinear
    samp3 = 3 | 3 << 2 | MAG | MIN | MIP | 4 << T.SAMP_BORDER | 0x40 << T.SAMP_LOD_BIAS
    # D24, compare LESS_OR_EQUAL (3), clamp to edge, bilinear, mip linear
    samp4 = (2 | 2 << 2 | MAG | MIN | MIP | 1 << T.SAMP_CMP | 3 << T.SAMP_CMP_OP |
             (0x2000 - 0x40) << T.SAMP_LOD_BIAS)
    # D32F, compare GREATER (4), clamp to border (INT_OPAQUE_BLACK 3), nearest
    samp5 = 3 | 3 << 2 | 1 << T.SAMP_CMP | 4 << T.SAMP_CMP_OP | 3 << T.SAMP_BORDER
    # gather: clamp to border (FLOAT_OPAQUE_WHITE) in u, repeat in v
    samp6 = 3 | 4 << T.SAMP_BORDER
    samp7 = MIN | MIP | 0x80 << T.SAMP_LOD_BIAS
    desc1 = desc(TEX1, TW, TW, NLEV, samp=samp1)
    desc2 = desc(TEX2, TW, TW, NLEV, fmt=T.FMT_BGRA8, tiled=1, samp=samp2)
    desc3 = desc(TEX1, TW, TW, NLEV, samp=samp3, lod=0x80 | (0xFFF - 0x280) << 12)
    desc4 = desc(TEXD24, TW, TW, 3, fmt=T.FMT_D24, samp=samp4)
    desc5 = desc(TEXD32, TW, TW, 1, fmt=T.FMT_D32F, samp=samp5)
    desc6 = desc(TEX1, TW, TW, NLEV, samp=samp6)
    desc7 = desc(TEX1, TW, TW, NLEV, samp=samp7)
    # The array (repeat, bilinear), the 3D texture (mirrored repeat in w,
    # trilinear in three axes and mip linear), the cube (bilinear, mip linear,
    # mipLodBias 0.5), offsets (mirrored repeat in u), unnormalized (clamp to
    # border, opaque white, in u, clamp to edge in v).
    desc8 = desc(TEXA, 8, 8, 2, typ=T.TYPE_ARRAY, cnt=3, samp=MAG | MIN)
    desc8[T.D_STRIDE] = stride_of(desc8)
    desc9 = desc(TEX3D, 8, 8, 3, typ=T.TYPE_3D, cnt=8, samp=1 << T.SAMP_WRAP_W | MAG | MIN | MIP)
    desc10 = desc(TEXC, 8, 8, 2, typ=T.TYPE_CUBE, samp=MAG | MIN | MIP | 0x80 << T.SAMP_LOD_BIAS)
    desc10[T.D_STRIDE] = stride_of(desc10)
    desc11 = desc(TEX1, TW, TW, NLEV, samp=1 | MAG | MIN)
    desc12 = desc(TEX1, TW, TW, 1, samp=3 | 2 << 2 | MAG | MIN | 1 << T.SAMP_UNNORM |
                  4 << T.SAMP_BORDER)
    textures(init, desc1, desc2)
    depth_textures(init, r, desc4, desc5)
    new_textures(init, desc8, desc9, desc10)
    draws = [
        (triangles(r, 6, 0.9), desc1, FS1, T.OP_TEXB, 'bias', 0),
        (triangles(r, 5, 0.8), desc2, FS2, T.OP_TEXL, 'lod', 0),
        (triangles(r, 3, 0.8, (-0.4, 0.2), (1.4, 3.0, 6.0)), desc3, FS1, T.OP_TEXB, 'bias', 0),
        (triangles(r, 3, 0.7, (0.0, 0.3), (0.6, 3.0, 6.0)), desc4, FS3,
         T.OP_TEXB | 1 << T.OPB_CFORM, 'bias.5', 0),
        (triangles(r, 2, 0.7, (-0.1, 0.2), (0.8, 1.1)), desc5, FS4,
         T.OP_TEXL | 1 << T.OPB_CFORM, 'lod.c', 0),
        (triangles(r, 2, 0.7, (-0.3, 0.2), (0.3, 1.3)), desc6, FS5,
         T.OP_TEXL | 1 << T.OPB_GATHER | 1 << T.OPB_COMP, 'none', 0),
        (triangles(r, 2, 0.7, (-0.5, 0.5), (0.3, 3.0, 12.0)), desc7, FS6,
         T.OP_TEXB | 1 << T.OPB_QUERY, 'none', 0),
        (triangles(r, 2, 0.7, (-0.5, 0.5), (0.5, 1.5)), desc8, FS7, T.OP_TEXL, 'layer',
         1 | 15 << 4),
        (triangles(r, 3, 0.7, (-0.5, 0.5), (0.5, 4.0, 9.0)), desc9, FS8, T.OP_TEXB, 'w', 0),
        (triangles(r, 3, 0.8, (-0.3, 0.6), (0.6, 1.2)), desc10, FS9, T.OP_TEXB, 'cube', 0),
        (triangles(r, 2, 0.7, (-0.5, 0.5), (0.3, 2.0)), desc11, FS10, T.OP_TEXL, 'lod',
         3 | 14 << 4),
        (triangles(r, 2, 0.7, (-0.2, 0.8), (0.2, 1.4)), desc12, FS11, T.OP_TEXL, 'unnorm', 0)]
    tris = [t for dr in draws for t in dr[0]]
    for i, (vs, uvs) in enumerate(tris):
        for k in range(3):
            v = 3 * i + k
            for c in range(4):
                init.append((POS + 16 * v + 4 * c, f(vs[k][c])))
            init.append((UV + 8 * v, f(uvs[k][0])))
            init.append((UV + 8 * v + 4, f(uvs[k][1])))
    for base, src in ((VS, VS_SRC), (FS1, FS1_SRC), (FS2, FS2_SRC), (FS3, FS3_SRC),
                      (FS4, FS4_SRC), (FS5, FS5_SRC), (FS6, FS6_SRC), (FS7, FS7_SRC),
                      (FS8, FS8_SRC), (FS9, FS9_SRC), (FS10, FS10_SRC), (FS11, FS11_SRC)):
        for k, w in enumerate(A.encode(src)):
            init.append((base + 8 * k, w & 0xFFFFFFFF))
            init.append((base + 8 * k + 4, w >> 32))
    for a, v in init:
        mem.wr32(a, v)

    def set_regs(pairs):
        ring.append(hdr(0, 1, 0x40, 0, 2 * len(pairs)))
        for idx, v in pairs:
            ring.append(idx)
            ring.append(v & 0xFFFFFFFF)
            st.set(idx, v)

    vp = (W / 2, H / 2, W / 2, H / 2, 1.0, 0.0)
    pairs = [(M.S_VIEWPORT + k, f(v)) for k, v in enumerate(vp)]
    pairs += [(M.S_RT_BASE, RT), (M.S_RT_STRIDE, RT_STRIDE), (M.S_RT_FORMAT, 0),
              (M.S_RT_SIZE, (H << 16) | W), (M.S_DS_BASE, DS), (M.S_DS_STRIDE, DS_STRIDE),
              (M.S_DEPTH, 1 | (1 << 1) | (1 << 2) | 0x40), (M.S_WRITE_MASK, 0xF),
              (M.S_BLEND, 0), (M.S_CULL, 0), (S_VARYING_COUNT, 2), (S_PROVOKING, 0),
              (S_VS_BASE, VS), (S_FS_BASE, FS1)]
    pairs += [(S_TU + k, desc1[k]) for k in range(16)]
    pairs += [(S_TOPOLOGY, 3), (S_INDEX_FORMAT, 0), (S_FIRST, 0),
              (S_COUNT, 3 * len(draws[0][0])),
              (S_PRIM_RESTART, 0), (S_INSTANCE_COUNT, 1), (S_FIRST_INSTANCE, 0),
              (S_VERTEX_OFFSET, 0),
              (S_ATTR_BASE, POS), (S_ATTR_DESC, 16 | 3 << 16),
              (S_ATTR_BASE + 2, UV), (S_ATTR_DESC + 2, 8 | 1 << 16),
              (S_ATTR_DST, 0xC0), (S_ATTR_DST + 1, 0x44)]
    set_regs(pairs)
    ring.append(hdr(0, 3, 0x50, 0, 0))	# DRAW
    # The other draws: the TU's slot (only the words that change; the
    # SET_REG waits until the draw before is done), then the program.
    first = 3 * len(draws[0][0])
    cur = list(desc1)
    for k, (dr, d, fs, _, _, _) in enumerate(draws[1:]):
        set_regs([(S_TU + i, d[i]) for i in range(16) if d[i] != cur[i]] +
                 [(S_FS_BASE, fs), (S_FIRST, first), (S_COUNT, 3 * len(dr))])
        cur = list(d)
        ring.append(hdr(0, 3, 0x51 + k, 0, 0))	# DRAW
        first += 3 * len(dr)

    # The model: each triangle in order through clip, setup, the warps, the TU and the ROP.
    nwarps = nquads = 0
    four, two, mone = f(4.0), f(2.0), f(-1.0)
    for dr, d, _, op, kind, off in draws:
        for vs, uvs in dr:
            pos = [[f(c) for c in v] for v in vs]
            us = [f(uv[0]) for uv in uvs]
            vv = [f(uv[1]) for uv in uvs]
            for cl in M.clip(pos, [0, 1, 2], 7):
                rs = M.setup(st, cl)
                for wp in M.warps(rs):
                    nwarps += 1
                    for (x, y, m) in wp:
                        nquads += 1
                        zs, coords = [], []
                        for ln in range(4):
                            b0, b1, b2, z, _, _ = M.frag_lane(rs, x + (ln & 1), y + (ln >> 1))
                            zs.append(z)
                            u = interp(us, b0, b1, b2)
                            v = interp(vv, b0, b1, b2)
                            z4 = FP.fpu(FP.FMUL, z, four, 0, 0)
                            # (rs1, rs1+1, rs2, Dref, rs1+2) as the program has them
                            c = {'bias': (u, v, 0, 0, 0), 'none': (u, v, 0, 0, 0),
                                 'lod': (u, v, z4, 0, 0), 'bias.5': (u, v, f(0.5), z, 0),
                                 'lod.c': (u, v, z4, z, 0), 'layer': (u, v, 0, 0, z4),
                                 'w': (u, v, 0, 0, z),
                                 'cube': (FP.fpu(FP.FMADD, u, two, mone, 0),
                                          FP.fpu(FP.FMADD, v, two, mone, 0), 0, 0, 0x3EB33333),
                                 'unnorm': (FP.fpu(FP.FMUL, u, f(16.0), 0, 0),
                                            FP.fpu(FP.FMUL, v, f(16.0), 0, 0), 0, 0, 0)}[kind]
                            coords.append(c)
                        words = T.sample(mem, op, d, coords, 0xF, off)
                        colors = [words[4 * ln:4 * ln + 4] for ln in range(4)]
                        M.rop_quad(st, mem, x, y, m, zs, colors)

    ring.append(hdr(0, 5, 0x60, 1, 2))	# the final fence: value 1 to FENCES
    ring.append(FENCES)
    ring.append(1)
    mem.wr32(FENCES, 1)

    with open(OUT, 'w') as fp:
        fp.write('N %d\n' % len(ring))
        for a, v in init:
            fp.write('I %08x %08x\n' % (a, v))
        for w in ring:
            fp.write('R %08x\n' % w)
        for y in range(H):
            for x in range(W):
                for base, stride in ((RT, RT_STRIDE), (DS, DS_STRIDE)):
                    a = base + y * stride + x * 4
                    fp.write('E %08x %08x\n' % (a, mem.rd32(a)))
        fp.write('E %08x %08x\n' % (FENCES, 1))
    print('rx-tex-scene: %d triangles, %d warps, %d quads, %d ring words -> %s'
          % (len(tris), nwarps, nquads, len(ring), OUT))


if __name__ == '__main__':
    main()
