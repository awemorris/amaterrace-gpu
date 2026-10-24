#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/msaa_scene.txt for sim/tb/atg_top_msaa_tb.v and the
Verilator harness's MSAA mode: 4x multisampling (docs/ghci.md section
12.11) through the whole pipeline, VF -> vertex warps -> PT -> RX (sample
coverage, r6-r9, d_s) -> fragment warps (exp 0x105, texf of a
multisampled image, texsz.s) -> ROP (per-sample depth, alpha to coverage,
alpha to one, per-sample depth test and colour write), and the blitter's
RESOLVE (section 8.2).  Images of 32x24 pixels (the odd-width case 31x23)
in the sample-interleaved layout (row pitch P = roundup(w, 2) x 4 x ps),
each case in its own memory:

  1 shared_edge    a fan of six triangles sharing edges, additive blend
                   (a sample written twice or not at all shows)
  2 depth          triangles that cross in depth, D32F LESS with write;
                   one with depth 0 on an edge (the centres outside it
                   below 0: r3 is not clamped with 4 samples)
  3 a2c            an alpha ramp with alpha to coverage and alpha to one
  4 smask_out      exp 0x105 twice (0, then (x + 9) & 15: the last wins),
                   then r6 overwritten (the coverage keeps the RX's r6)
  5 centroid       perspective triangles, the colour from r7-r9
  6 resolve        two layers of a 4x image, then RESOLVE: layer 0 to a
                   linear image with source and destination offsets and a
                   clip, layer 1 to a 4x4 tiled image
  7 texf_depth     a 1x draw that reads case 2's 4x D32F depth with texf,
                   sample x & 3 of texel (x, y)
  8 rgb565         a 4x RGB565 target and its UNORM565 RESOLVE
  9 odd_width      a 31x23 4x target (P as for 32)
 10 after_4x       a 1x draw right after case 9's 4x draw (MS_CTRL changes
                   between them)
 11 kill_centroid  SAMPLE_KILL 0101 with CENTROID (the centroid is the
                   lowest sample left)
 12 depth_only     a program without colour outputs (movi -1; exp 0x105)
                   with WRITE_MASK 0, D24 LESS with write (the stencil
                   bytes stay)
 13 texsz_s        texsz.s of a 4x slot and a 1x slot as colours (S / 8)
 14 texf_odd       (after case 10) a 1x draw that reads case 9's 31x23 4x
                   image with texf (rows of roundup(31, 2) x 4 texels)

The expected memory is the reference models' (tools/msmodel.py on
tools/rxmodel.py; tools/gsi1fp.py for the shader arithmetic;
tools/tumodel.py for texf).

Lines of the file (as tools/rx-raster-scene.py, plus C):
  N count        the number of R words (first line)
  I addr value   initial memory word (before the ring runs)
  R word         a ring word, in order
  C name         the start of a case's E lines
  E addr value   expected memory word after the final fence

  python3 -I tools/rx-msaa-scene.py [SEED]    (a few seconds)
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402
import gsi1fp as FP  # noqa: E402
import msmodel as MS  # noqa: E402
import rxmodel as M  # noqa: E402
import tumodel as T  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'sim', 'vec', 'msaa_scene.txt')

W, H = 32, 24
S = MS.S
RING = 0x0005C000	# 2048 words (RING_SIZE 13)
RING_LOG2 = 13
FENCES = 0x0005BF00
POS = 0x00050000	# attribute 0: RGBA32F, stride 16
COL = 0x00052000	# attribute 1: RGBA8_UNORM, stride 4
PROG = 0x00054000	# the programs, 0x400 bytes each
HEAP = 0x00020000	# the images, from here up to POS

# STATE (design §2.3).
S_TOPOLOGY, S_INDEX_FORMAT, S_FIRST, S_COUNT = 0x020, 0x022, 0x023, 0x024
S_PRIM_RESTART, S_INSTANCE_COUNT, S_FIRST_INSTANCE, S_VERTEX_OFFSET = 0x025, 0x026, 0x027, 0x028
S_ATTR_BASE, S_ATTR_DESC, S_ATTR_DST = 0x030, 0x031, 0x1C0
S_VARYING_COUNT, S_PROVOKING = 0x05B, 0x05D
S_VS_BASE, S_FS_BASE = 0x190, 0x192
S_TU3, S_TU4 = 0x090 + 16 * 3, 0x090 + 16 * 4
CENTROID, A2C, A2ONE = 1 << 4, 1 << 8, 1 << 9
D_LESS_W = 1 | 1 << 1 | 1 << 2	# test, write, LESS
D24, D32F = 0x20, 0x40
ADD = 1 | 1 << 1 | 1 << 5 | 1 << 12 | 1 << 16	# ONE + ONE, colour and alpha

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


def interp_src(b):
    """The colour from the barycentrics in r[b], r[b+1], r[b+2] into
    r12-r15 (temporaries r20-r22: r6-r9 are inputs)."""
    s = []
    for c in range(4):
        w = 4 + c	# the PT word of colour component c
        s += ['lda r20, %d' % (w << 2 | 0), 'lda r21, %d' % (w << 2 | 1),
              'lda r22, %d' % (w << 2 | 2),
              'fmul.s r%d, r20, r%d' % (12 + c, b),
              'fmadd.s r%d, r21, r%d, r%d' % (12 + c, b + 1, 12 + c),
              'fmadd.s r%d, r22, r%d, r%d' % (12 + c, b + 2, 12 + c)]
    return s


EXPC = ['exp r12, 0x100', 'exp r13, 0x101', 'exp r14, 0x102', 'exp r15, 0x103']
# Every fragment program ends with the full SAMPLE_MASK unless it exports one.
TAIL = ['movi r30, -1', 'exp r30, 0x105', 'end']
FS_COL = interp_src(0) + EXPC + TAIL
FS_CEN = interp_src(7) + EXPC + TAIL
FS_MASK = interp_src(0) + EXPC + [
    'exp zero, 0x105', 'fcvt.w.s r23, r4, rtz', 'addi r24, r23, 9', 'exp r24, 0x105',
    'movi r6, 0', 'end']
# texf of slot 3: texel (x, y) = (r20, r21), sample x & 3.
FS_TEXF = ['fcvt.w.s r20, r4, rtz', 'fcvt.w.s r21, r5, rtz', 'andi r22, r20, 3',
           'texf r24, r20, r22, 3', 'exp r24, 0x100', 'exp r25, 0x101', 'exp r26, 0x102',
           'exp r27, 0x103'] + TAIL
FS_DEPTH = TAIL
FS_TEXSZ = ['texsz.s r20, 3', 'texsz.s r21, 4', 'fcvt.s.w r22, r20', 'fcvt.s.w r23, r21',
            'movi r24, 0x3E000000', 'fmul.s r22, r22, r24', 'fmul.s r23, r23, r24',
            'exp r22, 0x100', 'exp r23, 0x101', 'exp zero, 0x102', 'exp one, 0x103'] + TAIL
PROGRAMS = [('vs', VS_SRC), ('col', FS_COL), ('cen', FS_CEN), ('mask', FS_MASK),
            ('texf', FS_TEXF), ('depth', FS_DEPTH), ('texsz', FS_TEXSZ)]


def f(x):
    return M.f2b(x)


def hdr(vendor, op, tag, flags, n):
    return (vendor << 30) | (op << 24) | (tag << 16) | (flags << 8) | n


def unorm8(b):
    return f(b / 255.0)


def interp(col, b0, b1, b2):
    """The fragment program's colour on one lane: c0 b0 + c1 b1 + c2 b2."""
    out = []
    for c in range(4):
        t = FP.fpu(FP.FMUL, col[0][c], b0, 0, 0)
        t = FP.fpu(FP.FMADD, col[1][c], b1, t, 0)
        t = FP.fpu(FP.FMADD, col[2][c], b2, t, 0)
        out.append(t)
    return out


def pitch(w, ps, ns):
    """The row pitch of an image: roundup(w, 2) x samples x pixel bytes."""
    return ((w + 1) & ~1) * ns * ps


class Scene:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.st = M.State()
        self.mem = M.Mem()
        self.init = []
        self.ring = []
        self.heap = HEAP
        self.cases = []	# (name, [(base, bytes)])
        self.tris = []	# (positions, colours) of every vertex triple, in VF order
        self.prog = {}
        self.tag = 0x40
        self.nquads = 0
        self.nedge = 0	# lanes with a covered sample and the centre outside
        self.npart = 0	# lanes with some samples covered, not all

    def alloc(self, size):
        base = self.heap
        self.heap = (self.heap + size + 0xFFF) & ~0xFFF
        assert self.heap <= POS
        return base

    def image(self, size, fill):
        """An image of size bytes at a new base, its words set by fill(k)."""
        base = self.alloc(size)
        for k in range(size // 4):
            self.init.append((base + 4 * k, fill(k) & M.M32))
        return base

    def next_tag(self):
        self.tag = (self.tag + 1) & 0xFF
        return self.tag

    def set_regs(self, pairs):
        self.ring.append(hdr(0, 1, self.next_tag(), 0, 2 * len(pairs)))
        for idx, v in pairs:
            self.ring.append(idx)
            self.ring.append(v & M.M32)
            self.st.set(idx, v)

    def packet(self, op, flags=0, words=()):
        self.ring.append(hdr(0, op, self.next_tag(), flags, len(words)))
        self.ring.extend(words)

    def wait_idle(self):
        self.packet(6)

    def target(self, rt, rt_stride, fmt, w, h, ms_ctrl, kill=0, ds=0, ds_stride=0, depth=0,
               blend=0, wmask=0xF):
        self.set_regs([(MS.S_MS_CTRL, ms_ctrl), (MS.S_SAMPLE_KILL, kill), (M.S_RT_BASE, rt),
                       (M.S_RT_STRIDE, rt_stride), (M.S_RT_FORMAT, fmt),
                       (M.S_RT_SIZE, h << 16 | w), (M.S_DS_BASE, ds),
                       (M.S_DS_STRIDE, ds_stride), (M.S_DEPTH, depth), (M.S_BLEND, blend),
                       (M.S_WRITE_MASK, wmask)])

    def draw(self, tris, cols, fs, lane):
        """A DRAW of the triangles (clip-space vertices, RGBA8 colours) with
        the fragment program fs; lane(regs, x, y, col) is the program on one
        lane: (colour or None, SAMPLE_MASK out or None).  Runs the model."""
        first = 3 * len(self.tris)
        self.tris += list(zip(tris, cols))
        self.set_regs([(S_FS_BASE, self.prog[fs]), (S_FIRST, first), (S_COUNT, 3 * len(tris))])
        self.packet(3)
        st, mem = self.st, self.mem
        ms4 = MS.ms_log2(st) == 2
        kill = st[MS.S_SAMPLE_KILL] & 15
        cen = bool(st[MS.S_MS_CTRL] & CENTROID)
        nq = 0
        for vs, cs in zip(tris, cols):
            pos = [[f(c) for c in v] for v in vs]
            col = [[unorm8(c[k]) for k in range(4)] for c in cs]
            for cl in M.clip(pos, [0, 1, 2], 7):
                rs = M.setup(st, cl)
                ds = MS.dz_ms(rs) if ms4 else [0, 0, 0, 0]
                for wp in MS.warps_ms(rs, ms4, kill):
                    for (x, y, scov, ccov) in wp:
                        nq += 1
                        self.nquads += 1
                        smask, zs, colors = 0, [], []
                        for ln in range(4):
                            px, py = x + (ln & 1), y + (ln >> 1)
                            s4 = scov >> (4 * ln) & 15
                            self.nedge += bool(s4 and not ccov >> ln & 1)
                            self.npart += s4 not in (0, 15)
                            regs = MS.frag_lane_ms(rs, px, py, ms4, s4, ccov >> ln & 1, cen)
                            c, mo = lane(regs, px, py, col)
                            zs.append(regs[3])
                            colors.append(c if c is not None else [0, 0, 0, 0])
                            smask |= (s4 & (15 if mo is None else mo & 15)) << (4 * ln)
                        MS.rop_quad_ms(st, mem, x, y, smask, zs, colors, ds=ds)
        return nq

    def resolve(self, blt):
        """WAIT_IDLE, the blitter's STATE and BLIT, WAIT_IDLE; the model."""
        self.wait_idle()
        self.set_regs([(k, blt[k]) for k in range(12)])
        self.packet(2)
        self.wait_idle()
        assert MS.resolve(self.mem, blt) is not None


def tri_rand(r, cx, cy, s, persp=False):
    vs = []
    for _ in range(3):
        w = r.uniform(1.0, 2.5) if persp else 1.0
        vs.append(((cx + r.uniform(-s, s)) * w, (cy + r.uniform(-s, s)) * w,
                   r.uniform(0.1, 0.9) * w, w))
    return vs


def col_rand(r, alpha=255):
    return [[r.randrange(256) for _ in range(3)] + [alpha] for _ in range(3)]


def lane_col(regs, x, y, col):
    return interp(col, regs[0], regs[1], regs[2]), None


def lane_cen(regs, x, y, col):
    return interp(col, regs[7], regs[8], regs[9]), None


def texf_lane(mem, d):
    def lane(regs, x, y, col):
        # texel (x, y), sample x & 3: the lane's four words from the TU's model
        return T.sample(mem, T.OP_TEXF, d, [(x, y, x & 3, 0, 0)] * 4, 1)[0:4], None
    return lane


def lane_mask(regs, x, y, col):
    return interp(col, regs[0], regs[1], regs[2]), (x + 9) & 15


def build(sc):
    r = sc.r
    for k, (name, src) in enumerate(PROGRAMS):
        base = PROG + 0x400 * k
        sc.prog[name] = base
        text = src if isinstance(src, str) else '\n'.join(src) + '\n'
        words = A.encode(text)
        assert len(words) * 8 <= 0x400
        for i, w in enumerate(words):
            sc.init.append((base + 8 * i, w & M.M32))
            sc.init.append((base + 8 * i + 4, w >> 32))

    P4, P1 = pitch(W, 4, S), pitch(W, 4, 1)
    size4, size1 = P4 * H, P1 * H
    bg = 0xFF203040
    vp = (W / 2, H / 2, W / 2, H / 2, 1.0, 0.0)
    pairs = [(M.S_VIEWPORT + k, f(v)) for k, v in enumerate(vp)]
    pairs += [(M.S_CULL, 0), (S_VARYING_COUNT, 4), (S_PROVOKING, 0), (S_VS_BASE, sc.prog['vs']),
              (S_TOPOLOGY, 3), (S_INDEX_FORMAT, 0), (S_PRIM_RESTART, 0), (S_INSTANCE_COUNT, 1),
              (S_FIRST_INSTANCE, 0), (S_VERTEX_OFFSET, 0),
              (S_ATTR_BASE, POS), (S_ATTR_DESC, 16 | 3 << 16),
              (S_ATTR_BASE + 2, COL), (S_ATTR_DESC + 2, 4 | 4 << 16),
              (S_ATTR_DST, 0xC0), (S_ATTR_DST + 1, 0xC4)]
    sc.set_regs(pairs)

    # The resolved image of case 6 first, at HEAP (the Verilator harness's PNG).
    d6a = sc.image(size1, lambda k: 0xA5A5A5A5)
    assert d6a == HEAP

    # 1: a fan around an off-grid centre, flat colours, additive blend.
    c1 = sc.image(size4, lambda k: 0)
    sc.target(c1, P4, 0, W, H, 2, blend=ADD)
    cx, cy = 0.07, -0.11
    ring = []
    for i in range(6):
        a = (i + r.uniform(-0.3, 0.3)) * math.pi / 3
        rad = r.uniform(0.6, 0.95)
        ring.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    tris, cols = [], []
    for i in range(6):
        p, q = ring[i], ring[(i + 1) % 6]
        tris.append([(cx, cy, 0.5, 1.0), (p[0], p[1], 0.5, 1.0), (q[0], q[1], 0.5, 1.0)])
        c = [20 + 30 * (i % 3), 20 + 25 * (i % 4), 30 + 15 * i, 40]
        cols.append([c, c, c])
    sc.draw(tris, cols, 'col', lane_col)
    sc.cases.append(('shared_edge', [(c1, size4)]))

    # 2: two triangles crossing in depth, D32F LESS with write.
    c2 = sc.image(size4, lambda k: bg)
    d2 = sc.image(size4, lambda k: f(1.0))
    sc.target(c2, P4, 0, W, H, 2, ds=d2, ds_stride=P4, depth=D_LESS_W | D32F)
    tris = [[(-0.9, -0.8, 0.1, 1.0), (0.95, -0.3, 0.9, 1.0), (-0.6, 0.9, 0.5, 1.0)],
            [(-0.95, 0.2, 0.9, 1.0), (0.8, -0.9, 0.2, 1.0), (0.7, 0.85, 0.3, 1.0)],
            tri_rand(r, 0.1, 0.0, 0.7, True),
            # depth 0 on one edge, 1 at the far vertex: the centres outside
            # the edge are below 0 (r3 unclamped with 4 samples)
            [(-0.8, -0.95, 0.0, 1.0), (-0.9, 0.9, 0.0, 1.0), (0.95, 0.4, 1.0, 1.0)]]
    sc.draw(tris, [col_rand(r) for _ in tris], 'col', lane_col)
    sc.cases.append(('depth', [(c2, size4), (d2, size4)]))

    # 3: an alpha ramp with alpha to coverage and alpha to one.
    c3 = sc.image(size4, lambda k: bg)
    sc.target(c3, P4, 0, W, H, 2 | A2C | A2ONE)
    tris = [[(-0.95, -0.9, 0.5, 1.0), (0.95, -0.85, 0.5, 1.0), (-0.9, 0.95, 0.5, 1.0)],
            [(0.95, -0.8, 0.5, 1.0), (0.9, 0.95, 0.5, 1.0), (-0.85, 0.9, 0.5, 1.0)]]
    cols = [[[200, 40, 40, 0], [40, 200, 40, 128], [40, 40, 200, 255]],
            [[220, 220, 30, 30], [30, 220, 220, 255], [220, 30, 220, 160]]]
    sc.draw(tris, cols, 'col', lane_col)
    sc.cases.append(('a2c', [(c3, size4)]))

    # 4: SAMPLE_MASK out, the last export wins; r6 overwritten after.
    c4 = sc.image(size4, lambda k: bg)
    sc.target(c4, P4, 0, W, H, 2)
    tris = [[(-0.95, -0.9, 0.5, 1.0), (0.9, -0.5, 0.5, 1.0), (-0.4, 0.95, 0.5, 1.0)],
            tri_rand(r, 0.3, 0.3, 1.0)]
    sc.draw(tris, [col_rand(r) for _ in tris], 'mask', lane_mask)
    sc.cases.append(('smask_out', [(c4, size4)]))

    # 5: centroid barycentrics on perspective triangles.
    c5 = sc.image(size4, lambda k: bg)
    sc.target(c5, P4, 0, W, H, 2 | CENTROID)
    tris = [[(-1.4, -1.1, 0.3, 1.5), (1.9, -0.6, 0.6, 2.2), (-0.2, 1.3, 0.4, 1.0)],
            tri_rand(r, 0.35, -0.2, 0.9, True)]
    sc.draw(tris, [col_rand(r) for _ in tris], 'cen', lane_cen)
    sc.cases.append(('centroid', [(c5, size4)]))

    # 6: a two-layer 4x image, then RESOLVE of each layer.
    c6 = sc.image(2 * size4, lambda k: bg)
    tile_stride = (W // 4) * 16 * 4
    d6b = sc.image(tile_stride * (H // 4), lambda k: 0x5A5A5A5A)
    for layer in range(2):
        sc.target(c6 + layer * size4, P4, 0, W, H, 2)
        tris = [[(-0.8, -0.7 + 0.2 * layer, 0.5, 1.0), (0.85, -0.85, 0.5, 1.0),
                 (0.1 - 0.3 * layer, 0.9, 0.5, 1.0)], tri_rand(r, 0.2, -0.1, 0.6, True)]
        sc.draw(tris, [col_rand(r) for _ in tris], 'col', lane_col)
    blt = [0] * 12
    blt[MS.BLT_OP] = 4
    blt[MS.BLT_DST_BASE], blt[MS.BLT_DST_STRIDE] = d6a, P1
    blt[MS.BLT_SRC_BASE], blt[MS.BLT_SRC_STRIDE] = c6, P4
    blt[MS.BLT_DST_XY], blt[MS.BLT_SRC_XY] = 4 | 2 << 16, 2 | 1 << 16
    blt[MS.BLT_SIZE] = 26 | 20 << 16
    blt[MS.BLT_CLIP_MIN], blt[MS.BLT_CLIP_MAX] = 5 | 3 << 16, 28 | 21 << 16
    blt[MS.BLT_RESOLVE] = 2 | MS.F_UNORM8 << 4
    sc.resolve(blt)
    blt = [0] * 12
    blt[MS.BLT_OP] = 4
    blt[MS.BLT_DST_BASE], blt[MS.BLT_DST_STRIDE] = d6b, tile_stride
    blt[MS.BLT_SRC_BASE], blt[MS.BLT_SRC_STRIDE] = c6 + size4, P4
    blt[MS.BLT_SIZE] = W | H << 16
    blt[MS.BLT_RESOLVE] = 2 | MS.F_UNORM8 << 4 | 1 << 8
    sc.resolve(blt)
    sc.cases.append(('resolve', [(c6, 2 * size4), (d6a, size1), (d6b, tile_stride * (H // 4))]))

    # 7: texf of case 2's 4x D32F depth (slot 3) in a 1x draw.
    c7 = sc.image(size1, lambda k: bg)
    dsc = [d2, H << 16 | W, 1 | T.FMT_D32F << T.IMG_FMT | 2 << T.IMG_SAMPLES] + [0] * 13
    sc.packet(12, 2)	# INVALIDATE T$ (the WAIT_IDLE of case 6 is before it)
    sc.set_regs([(S_TU3 + k, dsc[k]) for k in range(16)])
    sc.target(c7, P1, 0, W, H, 0)
    full = [[(-1.0, -1.0, 0.5, 1.0), (3.0, -1.0, 0.5, 1.0), (-1.0, 3.0, 0.5, 1.0)]]

    sc.draw(full, [col_rand(r)], 'texf', texf_lane(sc.mem, dsc))
    sc.cases.append(('texf_depth', [(c7, size1)]))

    # 8: a 4x RGB565 target and its UNORM565 RESOLVE.
    P4h, P1h = pitch(W, 2, S), pitch(W, 2, 1)
    c8 = sc.image(P4h * H, lambda k: 0x18E318E3)
    d8 = sc.image(P1h * H, lambda k: 0xC3C3C3C3)
    sc.target(c8, P4h, 2, W, H, 2)
    tris = [tri_rand(r, -0.25, 0.1, 0.8), tri_rand(r, 0.3, -0.2, 0.7, True)]
    sc.draw(tris, [col_rand(r) for _ in tris], 'col', lane_col)
    blt = [0] * 12
    blt[MS.BLT_OP] = 4 | 1 << 8
    blt[MS.BLT_DST_BASE], blt[MS.BLT_DST_STRIDE] = d8, P1h
    blt[MS.BLT_SRC_BASE], blt[MS.BLT_SRC_STRIDE] = c8, P4h
    blt[MS.BLT_SIZE] = W | H << 16
    blt[MS.BLT_RESOLVE] = 2 | MS.F_UNORM565 << 4
    sc.resolve(blt)
    sc.cases.append(('rgb565', [(c8, P4h * H), (d8, P1h * H)]))

    # 9: a 31x23 4x target; 10: a 1x draw of the same triangles right after.
    W9, H9 = W - 1, H - 1
    P9 = pitch(W9, 4, S)
    c9 = sc.image(P9 * H9, lambda k: bg)
    c10 = sc.image(size1, lambda k: bg)
    sc.target(c9, P9, 0, W9, H9, 2)
    tris = [[(-0.5, -0.9, 0.5, 1.0), (1.2, 0.1, 0.5, 1.0), (0.2, 1.3, 0.5, 1.0)],
            tri_rand(r, -0.4, 0.3, 0.6)]
    cols = [col_rand(r) for _ in tris]
    sc.draw(tris, cols, 'col', lane_col)
    sc.target(c10, P1, 0, W, H, 0)
    sc.draw(tris, cols, 'col', lane_col)
    sc.cases.append(('odd_width', [(c9, P9 * H9)]))
    sc.cases.append(('after_4x', [(c10, size1)]))

    # 14: texf of case 9's 31x23 4x image (the odd width's rows) in a 1x draw.
    c14 = sc.image(size1, lambda k: bg)
    dsc9 = [c9, H9 << 16 | W9, 1 | T.FMT_BGRA8 << T.IMG_FMT | 2 << T.IMG_SAMPLES] + [0] * 13
    sc.wait_idle()
    sc.packet(12, 2)	# INVALIDATE T$
    sc.set_regs([(S_TU3 + k, dsc9[k]) for k in range(16)])
    sc.target(c14, P1, 0, W, H, 0)
    sc.draw(full, [col_rand(r)], 'texf', texf_lane(sc.mem, dsc9))
    sc.cases.append(('texf_odd', [(c14, size1)]))

    # 11: SAMPLE_KILL with CENTROID.
    c11 = sc.image(size4, lambda k: bg)
    sc.target(c11, P4, 0, W, H, 2 | CENTROID, kill=0b0101)
    tris = [[(-1.0, -1.3, 0.3, 1.3), (1.5, 0.2, 0.6, 1.8), (-0.7, 1.4, 0.4, 1.4)],
            tri_rand(r, 0.3, 0.3, 0.9, True)]
    sc.draw(tris, [col_rand(r) for _ in tris], 'cen', lane_cen)
    sc.cases.append(('kill_centroid', [(c11, size4)]))

    # 12: depth only (no colour outputs, WRITE_MASK 0), D24 with stencil bytes.
    c12 = sc.image(size4, lambda k: 0x11223344 + k)
    d12 = sc.image(size4, lambda k: (k * 37 & 0xFF) << 24 | 0xFFFFFF)
    sc.target(c12, P4, 0, W, H, 2, ds=d12, ds_stride=P4, depth=D_LESS_W | D24, wmask=0)
    tris = [[(-1.2, -1.0, 0.2, 1.2), (1.3, -0.4, 0.9, 1.6), (0.1, 1.1, 0.5, 1.1)],
            [(-0.9, 0.9, 0.7, 1.0), (0.95, 0.8, 0.1, 1.0), (0.2, -0.95, 0.3, 1.0)]]
    sc.draw(tris, [col_rand(r) for _ in tris], 'depth', lambda g, x, y, c: (None, None))
    sc.cases.append(('depth_only', [(c12, size4), (d12, size4)]))

    # 13: texsz.s of slot 3 (4 samples) and slot 4 (1 sample).
    c13 = sc.image(size1, lambda k: bg)
    dsc4 = [c7, H << 16 | W, 1] + [0] * 13
    sc.set_regs([(S_TU4 + k, dsc4[k]) for k in range(16)])
    sc.target(c13, P1, 0, W, H, 0)
    s3, s4 = T.samples(dsc9), T.samples(dsc4)
    assert (s3, s4) == (4, 1)
    out = [f(s3 / 8.0), f(s4 / 8.0), 0, M.ONE]
    sc.draw([[(-0.9, -0.95, 0.5, 1.0), (0.9, -0.6, 0.5, 1.0), (0.1, 0.9, 0.5, 1.0)]],
            [col_rand(r)], 'texsz', lambda g, x, y, c: (out, None))
    sc.cases.append(('texsz_s', [(c13, size1)]))

    sc.packet(5, 1, (FENCES, 1))	# the final fence: value 1 to FENCES
    sc.mem.wr32(FENCES, 1)


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    sc = Scene(seed)
    # The vertex data is written after the draws are known: build first
    # into the model memory, then the vertex words into init and the model.
    build_with_vertices(sc)
    assert len(sc.ring) < (1 << RING_LOG2) // 4
    with open(OUT, 'w') as fp:
        fp.write('N %d\n' % len(sc.ring))
        for a, v in sc.init:
            fp.write('I %08x %08x\n' % (a, v))
        for w in sc.ring:
            fp.write('R %08x\n' % w)
        fp.write('E %08x %08x\n' % (FENCES, 1))
        n = 0
        for name, regions in sc.cases:
            fp.write('C %s\n' % name)
            for base, size in regions:
                for a in range(base, base + size, 4):
                    fp.write('E %08x %08x\n' % (a, sc.mem.rd32(a)))
                    n += 1
    print('rx-msaa-scene: %d cases, %d triangles, %d quads (%d lanes partly covered, %d with '
          'the centre outside), %d ring words, %d words checked -> %s'
          % (len(sc.cases), len(sc.tris), sc.nquads, sc.npart, sc.nedge, len(sc.ring), n, OUT))


def build_with_vertices(sc):
    """The model memory holds the images and the programs before the
    draws; the vertex buffers are only read by the VF, so the model does
    not need them, but the scene file does."""
    orig_image = sc.image

    def image(size, fill):
        base = orig_image(size, fill)
        for k in range(size // 4):
            sc.mem.wr32(base + 4 * k, fill(k) & M.M32)
        return base
    sc.image = image
    build(sc)
    for a, v in sc.init:
        if a >= PROG:
            sc.mem.wr32(a, v)
    for i, (vs, cs) in enumerate(sc.tris):
        for k in range(3):
            v = 3 * i + k
            for c in range(4):
                sc.init.append((POS + 16 * v + 4 * c, f(vs[k][c])))
            c = cs[k]
            sc.init.append((COL + 4 * v, c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24))
    assert 3 * len(sc.tris) * 16 <= COL - POS


if __name__ == '__main__':
    main()
