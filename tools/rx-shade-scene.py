#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/shade_scene.txt for sim/tb/atg_top_shade_tb.v and the
Verilator harness's SHADE mode: triangles with per-vertex colours drawn
with DRAW through the VF (a non-indexed triangle list; attribute 0 the
clip-space position RGBA32F, attribute 1 the colour RGBA8_UNORM), a
minimal GSI1 vertex program (the attributes out unchanged) and fragment
program (each colour component interpolated with the barycentrics: three
lda, fmul, two fmadd), depth LESS with write, one triangle through the
near plane; and the colour and depth buffers that the reference models
(tools/rxmodel.py for the VF's conversion, clip, setup, the fragment
warps' r0-r5 and the ROP; tools/gsi1fp.py for the shader arithmetic) say
they must hold.

Lines of the file (as tools/rx-raster-scene.py):
  N count        the number of R words (first line)
  I addr value   initial memory word (before the ring runs)
  R word         a ring word, in order
  E addr value   expected memory word after the final fence

  python3 -I tools/rx-shade-scene.py [SEED]
"""

import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402
import gsi1fp as FP  # noqa: E402
import rxmodel as M  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'sim', 'vec', 'shade_scene.txt')

W, H = 64, 48
RT = 0x00020000
RT_STRIDE = W * 4
DS = 0x00030000
DS_STRIDE = W * 4
POS = 0x00040000	# attribute 0: RGBA32F, stride 16
COL = 0x00041000	# attribute 1: RGBA8_UNORM, stride 4
VS = 0x00044000
FS = 0x00044400
FENCES = 0x0005EF00

# STATE (design §2.3).
S_TOPOLOGY, S_INDEX_FORMAT, S_FIRST, S_COUNT = 0x020, 0x022, 0x023, 0x024
S_PRIM_RESTART, S_INSTANCE_COUNT, S_FIRST_INSTANCE, S_VERTEX_OFFSET = 0x025, 0x026, 0x027, 0x028
S_ATTR_BASE, S_ATTR_DESC, S_ATTR_DST = 0x030, 0x031, 0x1C0
S_VARYING_COUNT, S_PROVOKING = 0x05B, 0x05D
S_VS_BASE, S_FS_BASE = 0x190, 0x192

VS_SRC = """
	exp r0, 0x000
	exp r1, 0x001
	exp r2, 0x002
	exp r3, 0x003
	exp r4, 0x010
	exp r5, 0x011
	exp r6, 0x012
	exp r7, 0x013
	end
"""


def fs_src():
    s = []
    for c in range(4):
        w = 4 + c	# the PT word of colour component c
        s += ['lda r8, %d' % (w << 2 | 0), 'lda r9, %d' % (w << 2 | 1),
              'lda r10, %d' % (w << 2 | 2),
              'fmul.s r%d, r8, r0' % (12 + c), 'fmadd.s r%d, r9, r1, r%d' % (12 + c, 12 + c),
              'fmadd.s r%d, r10, r2, r%d' % (12 + c, 12 + c), 'exp r%d, 0x%x' % (12 + c, 0x100 + c)]
    s.append('end')
    return '\n'.join(s) + '\n'


def f(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def hdr(vendor, op, tag, flags, n):
    return (vendor << 30) | (op << 24) | (tag << 16) | (flags << 8) | n


def unorm8(b):
    return f(b / 255.0)


def shade(col, b0, b1, b2):
    """The fragment program on one lane: per component c0 b0 + c1 b1 + c2 b2."""
    out = []
    for c in range(4):
        t = FP.fpu(FP.FMUL, col[0][c], b0, 0, 0)
        t = FP.fpu(FP.FMADD, col[1][c], b1, t, 0)
        t = FP.fpu(FP.FMADD, col[2][c], b2, t, 0)
        out.append(t)
    return out


def triangles(r):
    """Clip-space triangles (x, y, z, w per vertex) and RGBA8 colours."""
    tris = []
    for t in range(6):
        vs = []
        for _ in range(3):
            w = r.uniform(1.0, 2.0)
            vs.append((r.uniform(-0.95, 0.95) * w, r.uniform(-0.95, 0.95) * w,
                       r.uniform(0.05, 0.95) * w, w))
        tris.append(vs)
    # one through the near plane (z < 0 behind it)
    tris.append([(-0.8, -0.7, 0.4, 1.0), (0.9, -0.2, -0.3, 1.2), (-0.1, 0.9, 0.2, 1.1)])
    # small ones, so that the draw takes several vertex warps (10 triangles
    # each) and both PT blocks, taken again
    for t in range(17):
        cx, cy, w = r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9), r.uniform(1.0, 2.0)
        vs = []
        for _ in range(3):
            vs.append(((cx + r.uniform(-0.15, 0.15)) * w, (cy + r.uniform(-0.15, 0.15)) * w,
                       r.uniform(0.02, 0.5) * w, w))
        tris.append(vs)
    cols = [[r.randrange(256) for _ in range(4)] for _ in range(3 * len(tris))]
    for c in cols:
        c[3] = 255
    return tris, cols


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
    tris, cols = triangles(r)
    nv = 3 * len(tris)
    for i in range(nv):
        p = tris[i // 3][i % 3]
        for c in range(4):
            init.append((POS + 16 * i + 4 * c, f(p[c])))
        init.append((COL + 4 * i, cols[i][0] | cols[i][1] << 8 | cols[i][2] << 16 | cols[i][3] << 24))
    for base, src in ((VS, VS_SRC), (FS, fs_src())):
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
              (M.S_BLEND, 0), (M.S_CULL, 0), (S_VARYING_COUNT, 4), (S_PROVOKING, 0),
              (S_VS_BASE, VS), (S_FS_BASE, FS)]
    pairs += [(S_TOPOLOGY, 3), (S_INDEX_FORMAT, 0), (S_FIRST, 0), (S_COUNT, nv),
              (S_PRIM_RESTART, 0), (S_INSTANCE_COUNT, 1), (S_FIRST_INSTANCE, 0),
              (S_VERTEX_OFFSET, 0),
              (S_ATTR_BASE, POS), (S_ATTR_DESC, 16 | 3 << 16),
              (S_ATTR_BASE + 2, COL), (S_ATTR_DESC + 2, 4 | 4 << 16),
              (S_ATTR_DST, 0xC0), (S_ATTR_DST + 1, 0xC4)]
    set_regs(pairs)
    ring.append(hdr(0, 3, 0x50, 0, 0))	# DRAW

    # The model: each triangle in order through clip, setup, the warps and the ROP.
    nwarps = 0
    for t, vs in enumerate(tris):
        pos = [[f(c) for c in v] for v in vs]
        col = [[unorm8(cols[3 * t + i][c]) for c in range(4)] for i in range(3)]
        for cl in M.clip(pos, [0, 1, 2], 7):
            rs = M.setup(st, cl)
            for wp in M.warps(rs):
                nwarps += 1
                for (x, y, m) in wp:
                    zs, colors = [], []
                    for ln in range(4):
                        b0, b1, b2, z, _, _ = M.frag_lane(rs, x + (ln & 1), y + (ln >> 1))
                        zs.append(z)
                        colors.append(shade(col, b0, b1, b2))
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
    print('rx-shade-scene: %d triangles, %d warps, %d ring words -> %s'
          % (len(tris), nwarps, len(ring), OUT))


if __name__ == '__main__':
    main()
