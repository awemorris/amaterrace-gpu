#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/tex_scene.txt for sim/tb/atg_top_tex_tb.v and the
Verilator harness's TEX mode: textured triangles drawn with two DRAWs
through the VF (attribute 0 the clip-space position RGBA32F, attribute 1
the texture coordinates RG32F) and the TU (slot 3, a 16x16 RGBA8 texture
with 5 mip levels).  Draw 1: a fragment program that interpolates (u, v)
(three lda, fmul, two fmadd each) and samples with texb (the LOD from the
quad's derivatives), linear rows, repeat in u and mirrored repeat in v,
bilinear magnification, nearest minification.  Then SET_REG changes slot
3 (which waits until draw 1 is done) to a 4x4 tiled BGRA8 copy, clamp in
u, repeat in v, nearest magnification, bilinear minification, and the
fragment program to one that samples with texl at lod = 4 z; draw 2.
Draw 3: the linear copy again with texb, clamp to border (opaque white)
in u and v, bilinear and mip linear (trilinear) filtering, minLod 0.5,
maxLod 2.5 and mipLodBias 0.25.  Draw 4: a 16x16 D24 depth texture with
3 levels and a compare sampler (LESS_OR_EQUAL, bilinear and mip linear:
percentage closer filtering, mipLodBias -0.25), texb.c with bias 0.5 and
the fragment's z as Dref (rs1+2).  Draw 5: a 16x16 D32_SFLOAT texture,
compare GREATER, nearest, clamp to border (opaque black), texl.c at lod
4 z with z as Dref.  Draw 6: texg.g (gather of G) from the linear copy,
clamp to border (opaque white) in u, repeat in v.  Draw 7: texqlod (the
level accessed and lambda' as the colour's R and G) with mipLodBias 0.5.
Depth LESS with write.  The colour and depth buffers are what the
reference models say (tools/rxmodel.py for the VF, clip, setup, the
fragment warps and the ROP; tools/gsi1fp.py for the shader arithmetic;
tools/tumodel.py for the TU).

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
TEX1 = 0x00045000	# linear RGBA8, 5 levels
TEX2 = 0x00046000	# 4x4 tiled BGRA8, 5 levels
TEXD24 = 0x00047000	# D24 (stencil byte random), 3 levels
TEXD32 = 0x00048000	# D32_SFLOAT, 1 level
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


def textures(init):
    """Writes both copies; returns their MIP_OFFSET[1..4]."""
    off1, off2 = [], []
    a1, a2 = 0, 0
    for lv in range(NLEV):
        w = h = TW >> lv
        if lv:
            off1.append(a1)
            off2.append(a2)
        for j in range(h):
            for i in range(w):
                r, g, b, al = texel(lv, i, j)
                init.append((TEX1 + a1 + (j * w + i) * 4, r | g << 8 | b << 16 | al << 24))
                ta = a2 + (j >> 2) * ((w + 3) >> 2) * 64 + (i >> 2) * 64 + ((j & 3) * 4 + (i & 3)) * 4
                init.append((TEX2 + ta, b | g << 8 | r << 16 | al << 24))
        a1 += w * h * 4
        a2 += ((w + 3) >> 2) * ((h + 3) >> 2) * 64
    return off1, off2


def depth_textures(init, r):
    """The depth textures: D24 with 3 levels (returns MIP_OFFSET[1..2]) and
    D32F with one level; slopes and steps in [0.05, 0.95]."""
    offs = []
    a = 0
    for lv in range(3):
        w = TW >> lv
        if lv:
            offs.append(a)
        for j in range(w):
            for i in range(w):
                x = 0.05 + 0.9 * ((i + 2 * j) % (2 * w)) / (2 * w - 1)
                if lv == 1:
                    x = 1.0 - x
                c = int(round(x * ((1 << 24) - 1)))
                init.append((TEXD24 + a + (j * w + i) * 4, r.getrandbits(8) << 24 | c))
        a += w * w * 4
    for j in range(TW):
        for i in range(TW):
            x = 0.1 + 0.8 * (((i // 4) + (j // 4)) & 1) * 0.5 + 0.02 * i
            init.append((TEXD32 + (j * TW + i) * 4, f(x)))
    return offs


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
    off1, off2 = textures(init)
    offd = depth_textures(init, r)
    draw1 = triangles(r, 6, 0.9)
    draw2 = triangles(r, 5, 0.8)
    draw3 = triangles(r, 3, 0.8, (-0.4, 0.2), (1.4, 3.0, 6.0))
    draw4 = triangles(r, 3, 0.7, (0.0, 0.3), (0.6, 3.0, 6.0))
    draw5 = triangles(r, 2, 0.7, (-0.1, 0.2), (0.8, 1.1))
    draw6 = triangles(r, 2, 0.7, (-0.3, 0.2), (0.3, 1.3))
    draw7 = triangles(r, 2, 0.7, (-0.5, 0.5), (0.3, 3.0, 12.0))
    tris = draw1 + draw2 + draw3 + draw4 + draw5 + draw6 + draw7
    for i, (vs, uvs) in enumerate(tris):
        for k in range(3):
            v = 3 * i + k
            for c in range(4):
                init.append((POS + 16 * v + 4 * c, f(vs[k][c])))
            init.append((UV + 8 * v, f(uvs[k][0])))
            init.append((UV + 8 * v + 4, f(uvs[k][1])))
    for base, src in ((VS, VS_SRC), (FS1, FS1_SRC), (FS2, FS2_SRC), (FS3, FS3_SRC),
                      (FS4, FS4_SRC), (FS5, FS5_SRC), (FS6, FS6_SRC)):
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

    samp1 = 0 | 1 << 2 | 1 << T.SAMP_MAG_LIN
    samp2 = 2 | 0 << 2 | 1 << T.SAMP_MIN_LIN | 1 << T.SAMP_FMT | 1 << T.SAMP_TILED
    # clamp to border (FLOAT_OPAQUE_WHITE 4), bilinear, trilinear
    samp3 = (3 | 3 << 2 | 1 << T.SAMP_MAG_LIN | 1 << T.SAMP_MIN_LIN | 1 << T.SAMP_MIP_LIN |
             4 << T.SAMP_BORDER | 0x40 << T.SAMP_LOD_BIAS)
    # D24, compare LESS_OR_EQUAL (3), clamp to edge, bilinear, mip linear
    samp4 = (2 | 2 << 2 | 1 << T.SAMP_MAG_LIN | 1 << T.SAMP_MIN_LIN | 1 << T.SAMP_MIP_LIN |
             1 << T.SAMP_CMP | 3 << T.SAMP_CMP_OP | 1 << T.SAMP_DEPTH |
             (0x2000 - 0x40) << T.SAMP_LOD_BIAS)
    # D32F, compare GREATER (4), clamp to border (INT_OPAQUE_BLACK 3), nearest
    samp5 = (3 | 3 << 2 | 1 << T.SAMP_CMP | 4 << T.SAMP_CMP_OP | 1 << T.SAMP_DEPTH |
             1 << T.SAMP_FMT | 3 << T.SAMP_BORDER)
    # gather: clamp to border (FLOAT_OPAQUE_WHITE) in u, repeat in v
    samp6 = 3 | 4 << T.SAMP_BORDER
    samp7 = 1 << T.SAMP_MIN_LIN | 1 << T.SAMP_MIP_LIN | 0x80 << T.SAMP_LOD_BIAS
    lv = NLEV | T.LOD_NONE
    desc1 = [TEX1, TW << 16 | TW, lv, samp1] + off1 + [0] * 8
    desc2 = [TEX2, TW << 16 | TW, lv, samp2] + off2 + [0] * 8
    desc3 = [TEX1, TW << 16 | TW, NLEV | 0x80 << 4 | (0xFFF - 0x280) << 16, samp3] + off1 + [0] * 8
    desc4 = [TEXD24, TW << 16 | TW, 3 | T.LOD_NONE, samp4] + offd + [0] * 10
    desc5 = [TEXD32, TW << 16 | TW, 1 | T.LOD_NONE, samp5] + [0] * 12
    desc6 = [TEX1, TW << 16 | TW, lv, samp6] + off1 + [0] * 8
    desc7 = [TEX1, TW << 16 | TW, lv, samp7] + off1 + [0] * 8

    vp = (W / 2, H / 2, W / 2, H / 2, 1.0, 0.0)
    pairs = [(M.S_VIEWPORT + k, f(v)) for k, v in enumerate(vp)]
    pairs += [(M.S_RT_BASE, RT), (M.S_RT_STRIDE, RT_STRIDE), (M.S_RT_FORMAT, 0),
              (M.S_RT_SIZE, (H << 16) | W), (M.S_DS_BASE, DS), (M.S_DS_STRIDE, DS_STRIDE),
              (M.S_DEPTH, 1 | (1 << 1) | (1 << 2) | 0x40), (M.S_WRITE_MASK, 0xF),
              (M.S_BLEND, 0), (M.S_CULL, 0), (S_VARYING_COUNT, 2), (S_PROVOKING, 0),
              (S_VS_BASE, VS), (S_FS_BASE, FS1)]
    pairs += [(S_TU + k, desc1[k]) for k in range(16)]
    pairs += [(S_TOPOLOGY, 3), (S_INDEX_FORMAT, 0), (S_FIRST, 0), (S_COUNT, 3 * len(draw1)),
              (S_PRIM_RESTART, 0), (S_INSTANCE_COUNT, 1), (S_FIRST_INSTANCE, 0),
              (S_VERTEX_OFFSET, 0),
              (S_ATTR_BASE, POS), (S_ATTR_DESC, 16 | 3 << 16),
              (S_ATTR_BASE + 2, UV), (S_ATTR_DESC + 2, 8 | 1 << 16),
              (S_ATTR_DST, 0xC0), (S_ATTR_DST + 1, 0x44)]
    set_regs(pairs)
    ring.append(hdr(0, 3, 0x50, 0, 0))	# DRAW
    # Draw 2: the TU's slot first (it waits until draw 1 is done), then the program.
    set_regs([(S_TU + k, desc2[k]) for k in range(16)] +
             [(S_FS_BASE, FS2), (S_FIRST, 3 * len(draw1)), (S_COUNT, 3 * len(draw2))])
    ring.append(hdr(0, 3, 0x51, 0, 0))	# DRAW
    # Draws 3-5: only the slot's words that change (the ring holds 256 words).
    first = 3 * (len(draw1) + len(draw2))
    cur = list(desc2)
    for k, (dr, desc, fs) in enumerate(((draw3, desc3, FS1), (draw4, desc4, FS3),
                                        (draw5, desc5, FS4), (draw6, desc6, FS5),
                                        (draw7, desc7, FS6))):
        set_regs([(S_TU + i, desc[i]) for i in range(16) if desc[i] != cur[i]] +
                 [(S_FS_BASE, fs), (S_FIRST, first), (S_COUNT, 3 * len(dr))])
        cur = list(desc)
        ring.append(hdr(0, 3, 0x52 + k, 0, 0))	# DRAW
        first += 3 * len(dr)

    # The model: each triangle in order through clip, setup, the warps, the TU and the ROP.
    nwarps = nquads = 0
    cform = 1 << T.OPB_CFORM
    kinds = ([(desc1, T.OP_TEXB, 'bias')] * len(draw1) +
             [(desc2, T.OP_TEXL, 'lod')] * len(draw2) +
             [(desc3, T.OP_TEXB, 'bias')] * len(draw3) +
             [(desc4, T.OP_TEXB | cform, 'bias.5')] * len(draw4) +
             [(desc5, T.OP_TEXL | cform, 'lod')] * len(draw5) +
             [(desc6, T.OP_TEXL | 1 << T.OPB_GATHER | 1 << T.OPB_COMP, 'none')] * len(draw6) +
             [(desc7, T.OP_TEXB | 1 << T.OPB_QUERY, 'none')] * len(draw7))
    for t, (vs, uvs) in enumerate(tris):
        d, op, kind = kinds[t]
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
                        third = (0 if kind in ('bias', 'none') else f(0.5) if kind == 'bias.5'
                                 else FP.fpu(FP.FMUL, z, f(4.0), 0, 0))
                        dref = z if op >> T.OPB_CFORM & 1 else 0
                        coords.append((u, v, third, dref))
                    words = T.sample(mem, op, d, coords, 0xF)
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
