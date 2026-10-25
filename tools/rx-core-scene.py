#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/core_scene.txt for sim/tb/atg_top_core_tb.v and the
Verilator harness's CORE mode: Vulkan 1.0 core rendering (CAPS[30],
docs/ghci.md sections 8.5 and 12.12) through the whole pipeline, VF ->
vertex warps -> PT -> RX (clip, setup, scan, fragment warps) -> fragment
warps (TU) -> ROP, the blitter and QUERY, in the KC705's shape.  Each case
draws into its own memory; its images, depth/stencil images and query
words must equal the reference models' word for word:

  stencil       two passes on D24_UNORM_S8_UINT: front faces INCR_WRAP,
                back faces DECR_WRAP, REPLACE and INVERT on a depth fail
                (WRITE_MASK 0); then colour where the stencil is odd
  d16           crossing triangles on D16_UNORM, LESS with write
  mrt           four attachments R8G8B8A8_UNORM, R16G16B16A16_SFLOAT,
                R32_UINT, R5G6B5_UNORM_PACK16 with their own blend and
                write masks
  fblend        R8G8B8A8_SRGB, A2B10G10R10_UNORM_PACK32 and
                R16G16B16A16_SFLOAT blended (the fp32 path) with the fp32
                blend constants (ROP_CTRL[1])
  lines_points  lines (x major, y major, equal) and points (PointCoord)
  lines_4x      lines and points with four samples
  bias          depth bias on D24 and D32_SFLOAT with the clamp's signs,
                the viewport's rectangle inside a larger scissor
  clamp_far     depth clamp (DEPTH_CLAMP[0]) and the far plane
                (DEPTH_CLAMP[1]); D32_SFLOAT
  occlusion     the occlusion counter (ROP_CTRL[0]) and QUERY with one
                sample and four samples, clear only and clear after

The expected memory is the reference models' (tools/rxmodel.py: clip2,
setup2, dtest, the blend; tools/msmodel.py: coverage and fragment inputs;
tools/fmtmodel.py: the formats; tools/gsi1fp.py: the shader arithmetic;
tools/tumodel.py: the TU; tools/blt-vectors.py: the blitter).  The F
lines are the FMT capability's words of every VkFormat value 0-255.

Lines of the file (as tools/rx-msaa-scene.py, plus F):
  N count        the number of R words (first line)
  I addr value   initial memory word (before the ring runs)
  F vk opt lin buf lim   the FMT capability's words for VkFormat vk
  R word         a ring word, in order
  C name         the start of a case's E lines
  E addr value   expected memory word after the final fence

  python3 -I tools/rx-core-scene.py [SEED] [CASE...]   (CASE: only those,
                                                        for debugging)
"""

import importlib.util
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fmtmodel as F  # noqa: E402
import gsi1asm as A  # noqa: E402
import gsi1fp as FP  # noqa: E402
import msmodel as MS  # noqa: E402
import rxmodel as M  # noqa: E402
import tumodel as T  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'sim', 'vec', 'core_scene.txt')


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ROPV = _load('rop_vectors', 'rop-vectors.py')	# mrt_pixel, ms_depth
BLTV = _load('blt_vectors', 'blt-vectors.py')	# blit2d, resolve

W, H = 32, 24
HEAP, HEAP_END = 0x00020000, 0x0004C000	# images and textures
VB, VB_END = 0x0004C000, 0x00054000	# vertex buffers
PROG, PROG_END = 0x00054000, 0x00058000	# programs
RING, RING_LOG2 = 0x00058000, 14	# 4096 words
FENCES = 0x0005FF00

# STATE (docs/ghci.md section 8.5).
S_TOPOLOGY, S_INDEX_FORMAT, S_FIRST, S_COUNT = 0x020, 0x022, 0x023, 0x024
S_PRIM_RESTART, S_INSTANCE_COUNT, S_FIRST_INSTANCE, S_VERTEX_OFFSET = 0x025, 0x026, 0x027, 0x028
S_ATTR_BASE, S_ATTR_DESC, S_ATTR_DST, S_ATTR_LIMIT = 0x030, 0x031, 0x1C0, 0x1D0
S_VARYING_COUNT, S_PROVOKING = 0x05B, 0x05D
S_VS_BASE, S_FS_BASE = 0x190, 0x192
S_STENCIL_FRONT, S_STENCIL_OPS, S_STENCIL_BACK = 0x077, 0x078, 0x079
S_RT_FORMATS, S_RT1_BASE, S_BLEND1, S_BLEND_CONST_F = 0x07D, 0x07E, 0x084, 0x087
S_DEPTH_BOUNDS_MIN, S_DEPTH_BOUNDS_MAX, S_ROP_CTRL = 0x08B, 0x08C, 0x08D
S_TU_FS, S_TU_VS = 0x090, 0x200
VP = M.S_VIEWPORT

# DEPTH (0x076).
D_TEST, D_WRITE, D24, D32F, D16, D_STENCIL, D_BOUNDS = 1, 2, 1 << 5, 1 << 6, 1 << 7, 1 << 8, 1 << 9
NEVER, LESS, EQUAL, LEQUAL, GREATER, NOTEQUAL, GEQUAL, ALWAYS = range(8)
KEEP, ZERO, REPLACE, INC_CLAMP, DEC_CLAMP, INVERT, INC_WRAP, DEC_WRAP = range(8)
# VkFormat values.
VK_RGB565, VK_R8, VK_RGBA8, VK_SRGBA8, VK_BGRA8 = 4, 9, 37, 43, 44
VK_A2B10G10R10, VK_RGBA16F, VK_R32U, VK_RGBA32U, VK_RGBA32F = 64, 97, 98, 107, 109
# BLEND: [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] op,
# [15:12] src alpha, [19:16] dst alpha, [22:20] op (VkBlendFactor, VkBlendOp).
BF_ZERO, BF_ONE, BF_SRC_ALPHA, BF_ONE_MINUS_SRC_ALPHA = 0, 1, 6, 7
BF_CONST_COLOR, BF_ONE_MINUS_CONST_COLOR, BF_CONST_ALPHA = 10, 11, 12
OP_ADD, OP_SUB, OP_RSUB, OP_MIN, OP_MAX = range(5)


def blend(sc, dc, cop, sa, da, aop):
    return 1 | sc << 1 | dc << 5 | cop << 9 | sa << 12 | da << 16 | aop << 20


def f(x):
    return M.f2b(x)


def hdr(vendor, op, tag, flags, n):
    return (vendor << 30) | (op << 24) | (tag << 16) | (flags << 8) | n


def unorm8(b):
    return f(b / 255.0)


def stencil_word(ref, cmask, wmask, op):
    return ref | cmask << 8 | wmask << 16 | op << 24


def stencil_ops(ff, fp, fd, bf, bp, bd):
    return ff | fp << 3 | fd << 6 | bf << 16 | bp << 19 | bd << 22

# ---------------------------------------------------------------- programs


def interp_src(b, dst, words, tmp=20):
    """dst+c = sum_v lda(word c, vertex v) x r[b+v] (the barycentrics in
    r[b], r[b+1], r[b+2]) for each varying word of words."""
    s = []
    for c, w in enumerate(words):
        pw = 4 + w	# the PT word
        s += ['lda r%d, %d' % (tmp, pw << 2 | 0), 'lda r%d, %d' % (tmp + 1, pw << 2 | 1),
              'lda r%d, %d' % (tmp + 2, pw << 2 | 2),
              'fmul.s r%d, r%d, r%d' % (dst + c, tmp, b),
              'fmadd.s r%d, r%d, r%d, r%d' % (dst + c, tmp + 1, b + 1, dst + c),
              'fmadd.s r%d, r%d, r%d, r%d' % (dst + c, tmp + 2, b + 2, dst + c)]
    return s


def interp(cv, words, b0, b1, b2):
    """The model of interp_src: cv[v][w] the varying words of the
    primitive's vertices."""
    out = []
    for w in words:
        t = FP.fpu(FP.FMUL, cv[0][w], b0, 0, 0)
        t = FP.fpu(FP.FMADD, cv[1][w], b1, t, 0)
        t = FP.fpu(FP.FMADD, cv[2][w], b2, t, 0)
        out.append(t)
    return out


def exp_rt(k, regs):
    """Export registers (names) to colour attachment k's components."""
    return ['exp %s, 0x%03x' % (r, 0x100 + 16 * k + c) for c, r in enumerate(regs)]


TAIL = ['movi r30, -1', 'exp r30, 0x105', 'end']

# The vertex programs: position (attribute 0, r0-r3), varying words from
# r4 up (attribute 1 and later).
VS = ['exp r0, 0x000', 'exp r1, 0x001', 'exp r2, 0x002', 'exp r3, 0x003'] + \
     ['exp r%d, 0x%03x' % (4 + k, 0x010 + k) for k in range(4)] + ['end']

# Fragment programs (asm, model).  A model takes the lane L (dict: regs
# r0-r9, px, py, cv the vertices' varyings, front) and returns the
# exports {attachment: [4 words]}.
FS_COL = interp_src(0, 12, range(4)) + exp_rt(0, ['r12', 'r13', 'r14', 'r15']) + TAIL


def m_col(L):
    return {0: interp(L['cv'], range(4), *L['regs'][0:3])}


# MRT: 0 the colour, 1 (b0, b1, b2, 1), 2 (x, y) as integers, 3 the colour
# reversed (b, g, r, a).
FS_MRT = interp_src(0, 12, range(4)) + exp_rt(0, ['r12', 'r13', 'r14', 'r15']) + \
    exp_rt(1, ['r0', 'r1', 'r2', 'one']) + \
    ['fcvt.w.s r23, r4, rtz', 'fcvt.w.s r24, r5, rtz'] + exp_rt(2, ['r23', 'r24', 'zero', 'zero']) + \
    exp_rt(3, ['r14', 'r13', 'r12', 'r15']) + TAIL


def m_mrt(L):
    c = interp(L['cv'], range(4), *L['regs'][0:3])
    return {0: c, 1: [L['regs'][0], L['regs'][1], L['regs'][2], M.ONE],
            2: [L['px'], L['py'], 0, 0], 3: [c[2], c[1], c[0], c[3]]}


# fblend: the colour to attachments 0-2.
FS_COL3 = interp_src(0, 12, range(4)) + exp_rt(0, ['r12', 'r13', 'r14', 'r15']) + \
    exp_rt(1, ['r12', 'r13', 'r14', 'r15']) + exp_rt(2, ['r15', 'r14', 'r13', 'r12']) + TAIL


def m_col3(L):
    c = interp(L['cv'], range(4), *L['regs'][0:3])
    return {0: c, 1: c, 2: [c[3], c[2], c[1], c[0]]}


# Points: PointCoord (r0, r1) and vertex 0's colour (blue, alpha).
FS_POINT = ['lda r20, %d' % ((4 + 2) << 2), 'lda r21, %d' % ((4 + 3) << 2)] + \
    exp_rt(0, ['r0', 'r1', 'r20', 'r21']) + TAIL


def m_point(L):
    cv = L['cv']
    return {0: [L['regs'][0], L['regs'][1], cv[0][2], cv[0][3]]}


PROGRAMS = [('vs', VS), ('col', FS_COL), ('mrt', FS_MRT), ('col3', FS_COL3),
            ('point', FS_POINT)]
MODELS = {'col': m_col, 'mrt': m_mrt, 'col3': m_col3, 'point': m_point}

# ---------------------------------------------------------------- the scene


class Scene:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.st = M.State()
        self.mem = M.Mem()
        self.init = []
        self.ring = []
        self.heap = HEAP
        self.vb = VB
        self.cases = []	# (name, [(base, bytes)])
        self.prog = {}
        self.tag = 0x40
        self.occ = 0
        self.nquads = 0
        self.nprims = 0

    # memory
    def alloc(self, size, align=256):
        base = (self.heap + align - 1) & ~(align - 1)
        self.heap = base + size
        assert self.heap <= HEAP_END, 'heap'
        return base

    def poke(self, a, v):
        self.init.append((a, v & M.M32))
        self.mem.wr32(a, v)

    def image(self, size, fill, align=256):
        base = self.alloc(size, align)
        for k in range((size + 3) // 4):
            self.poke(base + 4 * k, fill(k))
        return base

    def vbuf(self, words):
        base = self.vb
        for k, v in enumerate(words):
            self.poke(base + 4 * k, v)
        self.vb = (base + 4 * len(words) + 63) & ~63
        assert self.vb <= VB_END, 'vertex buffers'
        return base

    # the ring
    def next_tag(self):
        self.tag = (self.tag + 1) & 0xFF
        return self.tag

    def set_regs(self, pairs):
        for k in range(0, len(pairs), 60):
            part = pairs[k:k + 60]
            self.ring.append(hdr(0, 1, self.next_tag(), 0, 2 * len(part)))
            for idx, v in part:
                self.ring.append(idx)
                self.ring.append(v & M.M32)
                self.st.set(idx, v)

    def packet(self, op, flags=0, words=()):
        self.ring.append(hdr(0, op, self.next_tag(), flags, len(words)))
        self.ring.extend(words)

    def wait_idle(self):
        self.packet(6)

    def query(self, addr, flags):
        """QUERY (micro-op 14): flags[0] clear only, [1] clear after."""
        self.packet(14, flags, (addr,))
        if not flags & 1:
            self.mem.wr32(addr, self.occ & M.M32)
            self.mem.wr32(addr + 4, self.occ >> 32 & 0xFF)
        if flags & 3:
            self.occ = 0

    # state
    def target(self, w, h, rts, ms=0, ds=0, ds_stride=0, depth=0, wmask=0xF, blends=(0,) * 4,
               ctrl=0, kill=0):
        """rts: up to four (base, stride, vkformat)."""
        rts = list(rts) + [(0, 0, 0)] * (4 - len(rts))
        blends = list(blends) + [0] * (4 - len(blends))
        pairs = [(MS.S_MS_CTRL, ms), (MS.S_SAMPLE_KILL, kill), (M.S_RT_BASE, rts[0][0]),
                 (M.S_RT_STRIDE, rts[0][1]), (M.S_RT_FORMAT, 0), (M.S_RT_SIZE, h << 16 | w),
                 (M.S_DS_BASE, ds), (M.S_DS_STRIDE, ds_stride), (M.S_DEPTH, depth),
                 (M.S_BLEND, blends[0]), (M.S_WRITE_MASK, wmask), (S_ROP_CTRL, ctrl),
                 (S_RT_FORMATS, rts[0][2] | rts[1][2] << 8 | rts[2][2] << 16 | rts[3][2] << 24)]
        for k in range(1, 4):
            pairs += [(S_RT1_BASE + 2 * (k - 1), rts[k][0]), (S_RT1_BASE + 2 * k - 1, rts[k][1]),
                      (S_BLEND1 + k - 1, blends[k])]
        self.set_regs(pairs)

    def raster(self, vp=None, scissor=None, cull=0, dc=0, rm=0, bias=(0, 0, 0)):
        vp = vp or (W / 2, H / 2, W / 2, H / 2, 1.0, 0.0)
        pairs = [(VP + k, f(v)) for k, v in enumerate(vp)]
        smin, smax = scissor or (0, 0)
        pairs += [(M.S_SCISSOR_MIN, smin), (M.S_SCISSOR_MAX, smax), (M.S_CULL, cull),
                  (M.S_DEPTH_CLAMP, dc), (M.S_RAST_MODE, rm),
                  (M.S_DEPTH_BIAS_CONST, f(bias[0])), (M.S_DEPTH_BIAS_SLOPE, f(bias[1])),
                  (M.S_DEPTH_BIAS_CLAMP, f(bias[2]))]
        self.set_regs(pairs)

    # drawing
    def draw(self, kind, prims, fs, cvs=None):
        """A DRAW of a list topology: kind 0 points, 1 lines, 2 triangles;
        prims: per primitive its vertices' clip positions (floats) and
        RGBA8 colours ((pos, col) pairs).  The colour is attribute 1
        (R8G8B8A8_UNORM, varying words 0-3).  Runs the model."""
        nv = (1, 2, 3)[kind]
        pos, col = [], []
        for pr in prims:
            assert len(pr) == nv
            for p, c in pr:
                pos += [f(v) for v in p]
                col.append(c[0] | c[1] << 8 | c[2] << 16 | c[3] << 24)
        pb = self.vbuf(pos)
        cb = self.vbuf(col)
        self.set_regs([(S_TOPOLOGY, (0, 1, 3)[kind]), (S_FIRST, 0), (S_COUNT, nv * len(prims)),
                       (S_ATTR_BASE, pb), (S_ATTR_DESC, 16 | 3 << 16), (S_ATTR_BASE + 2, cb),
                       (S_ATTR_DESC + 2, 4 | 4 << 16), (S_ATTR_DST, 0xC0),
                       (S_ATTR_DST + 1, 0xC4), (S_ATTR_DST + 2, 0), (S_ATTR_LIMIT, 0),
                       (S_ATTR_LIMIT + 1, 0), (S_FS_BASE, self.prog[fs])])
        self.packet(3)
        lane = MODELS[fs]
        for pr in prims:
            vpos = [[f(v) for v in p] for p, _ in pr]
            vcol = [[unorm8(c[k]) for k in range(4)] for _, c in pr]
            idx = (0, 0, 0) if kind == 0 else (0, 1, 1) if kind == 1 else (0, 1, 2)
            self.prim(kind, [vpos[i] for i in idx], [vcol[i] for i in idx], lane)

    def prim(self, kind, pos, cv, lane):
        st = self.st
        ms4 = MS.ms_log2(st) == 2
        kill = st[MS.S_SAMPLE_KILL] & 15
        dc = st[M.S_DEPTH_CLAMP]
        self.nprims += 1
        for cl in M.clip2(st, kind, pos, [0, 1, 2], 7):
            for rs in M.setup2(st, cl):
                ds = MS.dz_ms(rs) if ms4 else [0, 0, 0, 0]
                for wp in MS.warps_ms(rs, ms4, kill):
                    for (x, y, scov, ccov) in wp:
                        self.nquads += 1
                        zs, outs = [], []
                        for ln in range(4):
                            px, py = x + (ln & 1), y + (ln >> 1)
                            regs = frag_regs(rs, px, py, ms4, dc)
                            zs.append(regs[3])
                            outs.append(lane({'regs': regs, 'px': px, 'py': py, 'cv': cv,
                                              'front': rs['front']}))
                        self.rop(x, y, scov, zs, outs, rs['front'], ds, ms4)

    def rop(self, x, y, smask, zl, outs, front, ds, ms4):
        """atg_rop with CAPS[30]: per-sample depth (atg_rop_ms), bounds,
        stencil and depth (atg_rop_dtest), the occlusion counter, then
        every exported attachment (atg_rop_wpix)."""
        st, mem = self.st, self.mem
        ns = 4 if ms4 else 1
        zd = ROPV.ms_depth(st[M.S_DEPTH_CLAMP], st[VP + 4], st[VP + 5], ms4, zl, ds, 0)
        depth = st[M.S_DEPTH]
        fb = (depth >> 5) & 7
        tests = fb in (1, 2, 4) and (depth & 1 or (fb == 1 and depth >> 8 & 1) or
                                     depth >> 9 & 1)
        dps = 2 if fb == 4 else 4
        passm = 0
        for ln in range(4):
            px, py = x + (ln & 1), y + (ln >> 1)
            for s in range(ns):
                if not smask >> (4 * ln + s) & 1:
                    continue
                if tests:
                    a = st[M.S_DS_BASE] + py * st[M.S_DS_STRIDE] + (px * ns + s) * dps
                    stored = sum(mem.rd8(a + i) << (8 * i) for i in range(dps))
                    p, ww, be = M.dtest(depth, st[S_STENCIL_FRONT], st[S_STENCIL_BACK],
                                        st[S_STENCIL_OPS], st[S_DEPTH_BOUNDS_MIN],
                                        st[S_DEPTH_BOUNDS_MAX], 1, front, zd[4 * ln + s], stored)
                    for i in range(dps):
                        if be >> i & 1:
                            mem.wr8(a + i, ww >> (8 * i))
                    if not p:
                        continue
                passm |= 1 << (4 * ln + s)
        if st[S_ROP_CTRL] & 1:
            self.occ += bin(passm).count('1')
        fmts = st[S_RT_FORMATS]
        kcf = [st[S_BLEND_CONST_F + c] for c in range(4)]
        for k in range(4):
            if not any(k in o for o in outs):
                continue
            vk = fmts >> (8 * k) & 255
            if k == 0 and not vk:
                vk = (VK_BGRA8, VK_RGBA8, VK_RGB565, VK_BGRA8)[st[M.S_RT_FORMAT] & 3]
            fi = F.info(vk) if vk else None
            if fi is None or not F.features(vk, False)[0] & F.F_COLOR:
                continue
            wm = (st[M.S_WRITE_MASK] >> (4 * k)) & 15
            if not wm & ((1 << len(fi.chans)) - 1):
                continue
            base = st[M.S_RT_BASE] if k == 0 else st[S_RT1_BASE + 2 * (k - 1)]
            stride = st[M.S_RT_STRIDE] if k == 0 else st[S_RT1_BASE + 2 * k - 1]
            bl = st[M.S_BLEND] if k == 0 else st[S_BLEND1 + k - 1]
            ps = fi.nbytes
            for ln in range(4):
                px, py = x + (ln & 1), y + (ln >> 1)
                color = outs[ln].get(k, [0, 0, 0, 0])
                for s in range(ns):
                    if not passm >> (4 * ln + s) & 1:
                        continue
                    a = base + py * stride + (px * ns + s) * ps
                    old = sum(mem.rd8(a + i) << (8 * i) for i in range(ps))
                    new = ROPV.mrt_pixel(vk, bl, st[M.S_BLEND_CONST], kcf, st[S_ROP_CTRL], wm,
                                         color, old)
                    for i in range(ps):
                        mem.wr8(a + i, new >> (8 * i))


def frag_regs(r, x, y, ms4, dc):
    """r0-r5 of a lane (msmodel.frag_lane_ms, without centroid): with one
    sample r3 is clamped to [0, 1] unless DEPTH_CLAMP[1]."""
    bx0, by0 = r['bbox'][0], r['bbox'][1]
    fi, fj = M.int2f(x - bx0), M.int2f(y - by0)
    zc = MS._ev(r, 'z', fi, fj)
    b = MS._bary(r, fi, fj)
    z = zc if ms4 or dc & 2 else M.fclamp01(zc)
    return b + [z, M.centre(x), M.centre(y)]


def pitch(w, ps, ns=1):
    """Row bytes of an attachment: roundup(w, 2) x samples x pixel bytes."""
    return ((w + 1) & ~1) * ns * ps


def rcol(r, alpha=None):
    return [r.randrange(256) for _ in range(3)] + [r.randrange(256) if alpha is None else alpha]


def rtri(r, cx, cy, s, z=(0.1, 0.9), persp=False, alpha=None):
    out = []
    for _ in range(3):
        w = r.uniform(1.0, 2.0) if persp else 1.0
        out.append((((cx + r.uniform(-s, s)) * w, (cy + r.uniform(-s, s)) * w,
                     r.uniform(*z) * w, w), rcol(r, alpha)))
    return out

# ---------------------------------------------------------------- cases


def case_stencil(sc):
    r = sc.r
    P = pitch(W, 4)
    c = sc.image(P * H, lambda k: 0xFF203040)
    d = sc.image(P * H, lambda k: (0, 255, 128, 1)[k % 4] << 24 | 0xFFFFFF)
    sc.raster()
    # pass 1: no colour; depth LESS without write (z = 1 fails: the depth-fail op)
    sc.target(W, H, [(c, P, VK_BGRA8)], ds=d, ds_stride=P,
              depth=D_TEST | LESS << 2 | D24 | D_STENCIL, wmask=0)
    sc.set_regs([(S_STENCIL_FRONT, stencil_word(0x33, 0xFF, 0xFF, ALWAYS)),
                 (S_STENCIL_BACK, stencil_word(0x44, 0xFF, 0x7F, ALWAYS)),
                 (S_STENCIL_OPS, stencil_ops(KEEP, INC_WRAP, REPLACE, KEEP, DEC_WRAP, INVERT))])
    tris = []
    for k in range(8):
        t = rtri(r, r.uniform(-0.5, 0.5), r.uniform(-0.5, 0.5), 0.7)
        if k % 3 == 2:
            t = [((p[0], p[1], 1.0, 1.0), cl) for p, cl in t]	# depth fails
        tris.append(t)
    sc.draw(2, tris, 'col')
    # pass 2: colour where the stencil is odd (front and back alike)
    odd = stencil_word(0x01, 0x01, 0x00, EQUAL)
    sc.target(W, H, [(c, P, VK_BGRA8)], ds=d, ds_stride=P, depth=D24 | D_STENCIL)
    sc.set_regs([(S_STENCIL_FRONT, odd), (S_STENCIL_BACK, odd), (S_STENCIL_OPS, 0)])
    full = [((-1.0, -1.0, 0.5, 1.0), rcol(r, 255)), ((3.0, -1.0, 0.5, 1.0), rcol(r, 255)),
            ((-1.0, 3.0, 0.5, 1.0), rcol(r, 255))]
    sc.draw(2, [full], 'col')
    sc.cases.append(('stencil', [(c, P * H), (d, P * H)]))


def case_d16(sc):
    r = sc.r
    P, PD = pitch(W, 4), pitch(W, 2)
    c = sc.image(P * H, lambda k: 0xFF102030)
    d = sc.image(PD * H, lambda k: 0xFFFFFFFF)
    sc.raster()
    sc.target(W, H, [(c, P, VK_RGBA8)], ds=d, ds_stride=PD, depth=D_TEST | D_WRITE | LESS << 2 | D16)
    tris = [[((-0.9, -0.8, 0.1, 1.0), rcol(r)), ((0.95, -0.3, 0.9, 1.0), rcol(r)),
             ((-0.6, 0.9, 0.5, 1.0), rcol(r))],
            [((-0.95, 0.2, 0.9, 1.0), rcol(r)), ((0.8, -0.9, 0.2, 1.0), rcol(r)),
             ((0.7, 0.85, 0.3, 1.0), rcol(r))],
            rtri(r, 0.1, 0.0, 0.8, persp=True)]
    sc.draw(2, tris, 'col')
    sc.cases.append(('d16', [(c, P * H), (d, PD * H)]))


def case_mrt(sc):
    r = sc.r
    fm = [VK_RGBA8, VK_RGBA16F, VK_R32U, VK_RGB565]
    rts, regions = [], []
    for vk in fm:
        ps = F.info(vk).nbytes
        P = pitch(W, ps)
        b = sc.image(P * H, lambda k: r.getrandbits(32), 64)
        rts.append((b, P, vk))
        regions.append((b, P * H))
    sc.raster()
    bl = [blend(BF_SRC_ALPHA, BF_ONE_MINUS_SRC_ALPHA, OP_ADD, BF_ONE, BF_ZERO, OP_ADD),
          blend(BF_ONE, BF_ONE, OP_ADD, BF_ONE, BF_ONE, OP_MAX),
          blend(BF_ONE, BF_ONE, OP_ADD, BF_ONE, BF_ONE, OP_ADD),	# integer: not blended
          blend(BF_CONST_COLOR, BF_ONE, OP_SUB, BF_ONE, BF_ZERO, OP_ADD)]
    sc.target(W, H, rts, wmask=0xF | 0x7 << 4 | 0x1 << 8 | 0x5 << 12, blends=bl)
    sc.set_regs([(M.S_BLEND_CONST, 0x80C04020)])
    tris = [rtri(r, -0.2, -0.1, 1.3), rtri(r, 0.3, 0.2, 1.2), rtri(r, 0.0, 0.0, 1.4)]
    sc.draw(2, tris, 'mrt')
    sc.cases.append(('mrt', regions))


def case_fblend(sc):
    r = sc.r
    fm = [VK_SRGBA8, VK_A2B10G10R10, VK_RGBA16F]
    rts, regions = [], []
    for vk in fm:
        ps = F.info(vk).nbytes
        P = pitch(W, ps)
        b = sc.image(P * H, lambda k: r.getrandbits(32) & 0x3BFF3BFF if ps == 8 else
                     r.getrandbits(32), 64)
        rts.append((b, P, vk))
        regions.append((b, P * H))
    sc.raster()
    bl = [blend(BF_SRC_ALPHA, BF_ONE_MINUS_SRC_ALPHA, OP_ADD, BF_ONE, BF_ONE_MINUS_SRC_ALPHA,
                OP_ADD),
          blend(BF_CONST_COLOR, BF_ONE_MINUS_CONST_COLOR, OP_ADD, BF_CONST_ALPHA, BF_ONE,
                OP_RSUB),
          blend(BF_ONE, BF_ONE, OP_ADD, BF_SRC_ALPHA, BF_ONE, OP_MIN)]
    sc.target(W, H, rts, blends=bl, ctrl=2, wmask=0xF | 0xB << 4 | 0xF << 8)
    sc.set_regs([(S_BLEND_CONST_F + c, f(v)) for c, v in enumerate((0.25, 0.75, 1.5, -0.125))])
    tris = [rtri(r, -0.2, -0.1, 1.3), rtri(r, 0.3, 0.2, 1.2), rtri(r, 0.0, 0.0, 1.4)]
    sc.draw(2, tris, 'col3')
    sc.cases.append(('fblend', regions))


def lines_and_points(sc, ms, name):
    r = sc.r
    ns = 4 if ms else 1
    P = pitch(W, 4, ns)
    c = sc.image(P * H, lambda k: 0xFF101010)
    sc.raster()
    sc.target(W, H, [(c, P, VK_RGBA8)], ms=ms,
              blends=[blend(BF_ONE, BF_ONE, OP_ADD, BF_ONE, BF_ONE, OP_ADD)])
    lines = []
    for k in range(9):
        a = (r.uniform(-0.9, 0.9), r.uniform(-0.9, 0.9))
        m = k % 3
        if m == 0:
            b = (a[0] + r.choice([-1, 1]) * r.uniform(0.6, 1.2), a[1] + r.uniform(-0.2, 0.2))
        elif m == 1:
            b = (a[0] + r.uniform(-0.2, 0.2), a[1] + r.choice([-1, 1]) * r.uniform(0.6, 1.2))
        else:	# equal: |dx| = |dy| in pixels
            d = r.choice([6, 9, -7]) / 16.0
            b = (a[0] + d, a[1] + r.choice([d, -d]) * W / H)
        lines.append([((a[0], a[1], 0.5, 1.0), rcol(r, 64)),
                      ((b[0], b[1], 0.5, 1.0), rcol(r, 64))])
    sc.draw(1, lines, 'col')
    pts = []
    for k in range(10):
        pts.append([((r.uniform(-1.0, 1.0), r.uniform(-1.0, 1.0), 0.5, 1.0), rcol(r))])
    sc.target(W, H, [(c, P, VK_RGBA8)], ms=ms)
    sc.draw(0, pts, 'point')
    sc.cases.append((name, [(c, P * H)]))


def case_lines_points(sc):
    lines_and_points(sc, 0, 'lines_points')


def case_lines_4x(sc):
    lines_and_points(sc, 2, 'lines_4x')


def case_bias(sc):
    r = sc.r
    P = pitch(W, 4)
    regions = []
    # D24 (format 2) and D32_SFLOAT (format 3), each with two clamps
    for fmt, dfmt in ((2, D24), (3, D32F)):
        c = sc.image(P * H, lambda k: 0xFF000000)
        d = sc.image(P * H, lambda k: 0x00800000 if dfmt == D24 else f(0.5))
        regions += [(c, P * H), (d, P * H)]
        sc.target(W, H, [(c, P, VK_RGBA8)], ds=d, ds_stride=P,
                  depth=D_TEST | D_WRITE | LEQUAL << 2 | dfmt)
        for cl in (0.0, 1e-3, -1e-3):
            # the viewport's rectangle (RAST_MODE[3]) inside a larger scissor
            vp = (W / 2 - 3, H / 2 - 2, W / 2 + 1, H / 2, 0.8, 0.1)
            sc.raster(vp=vp, scissor=(0, (H << 16) | W), rm=1 | fmt << 4 | 8,
                      bias=(r.choice([2.0, -3.0, 1000.0]), r.choice([0.5, -1.0, 2.0]), cl))
            sc.draw(2, [rtri(r, 0.0, 0.0, 1.1, z=(0.3, 0.7), persp=True),
                        rtri(r, 0.2, -0.2, 1.0, z=(0.3, 0.7))], 'col')
    sc.cases.append(('bias', regions))


def case_clamp_far(sc):
    r = sc.r
    P = pitch(W, 4)
    c = sc.image(P * H, lambda k: 0xFF000000)
    d = sc.image(P * H, lambda k: f(2.0))
    sc.target(W, H, [(c, P, VK_RGBA8)], ds=d, ds_stride=P,
              depth=D_TEST | D_WRITE | LESS << 2 | D32F)
    vp = (W / 2, H / 2, W / 2, H / 2, 0.5, 0.25)	# depth range [0.25, 0.75]
    # depth clamp: z beyond far and near clamped, not clipped
    sc.raster(vp=vp, dc=1)
    sc.draw(2, [[((-0.9, -0.9, -0.5, 1.0), rcol(r)), ((0.9, -0.7, 1.6, 1.0), rcol(r)),
                 ((0.0, 0.2, 0.5, 1.0), rcol(r))]], 'col')
    # depth clipping (DEPTH_CLIP): near and far planes cut, r3 not clamped
    sc.raster(vp=vp, dc=2)
    sc.draw(2, [[((-0.8, 0.0, 1.5, 1.0), rcol(r)), ((0.9, 0.3, -0.4, 1.0), rcol(r)),
                 ((-0.2, 0.95, 0.4, 1.0), rcol(r))],
                [((0.1, -0.95, 1.8, 1.5), rcol(r)), ((0.95, 0.9, 0.2, 1.0), rcol(r)),
                 ((-0.95, 0.6, 0.9, 1.2), rcol(r))]], 'col')
    # both: clamp wins (no clipping)
    sc.raster(vp=vp, dc=3)
    sc.draw(2, [rtri(r, 0.0, 0.0, 1.0, z=(-0.6, 1.6))], 'col')
    sc.raster()
    sc.cases.append(('clamp_far', [(c, P * H), (d, P * H)]))


def case_occlusion(sc):
    r = sc.r
    q = sc.image(64, lambda k: 0xA5A5A5A5, 64)
    P = pitch(W, 4)
    c = sc.image(P * H, lambda k: 0xFF000000)
    d = sc.image(P * H, lambda k: f(0.6))
    sc.wait_idle()
    sc.query(0, 1)	# clear only
    sc.raster()
    sc.target(W, H, [(c, P, VK_RGBA8)], ds=d, ds_stride=P,
              depth=D_TEST | D_WRITE | LESS << 2 | D32F, ctrl=1)
    sc.draw(2, [rtri(r, 0.0, 0.0, 1.0), rtri(r, 0.2, 0.1, 0.8)], 'col')
    sc.query(q, 2)	# write, then clear
    # counting off: not counted
    sc.target(W, H, [(c, P, VK_RGBA8)], ds=d, ds_stride=P,
              depth=D_TEST | D_WRITE | LESS << 2 | D32F, ctrl=0)
    sc.draw(2, [rtri(r, 0.0, 0.0, 1.0)], 'col')
    sc.query(q + 8, 0)	# 0
    # four samples
    P4 = pitch(W, 4, 4)
    c4 = sc.image(P4 * H, lambda k: 0xFF000000)
    d4 = sc.image(P4 * H, lambda k: f(0.5))
    sc.target(W, H, [(c4, P4, VK_RGBA8)], ms=2, ds=d4, ds_stride=P4,
              depth=D_TEST | D_WRITE | LESS << 2 | D32F, ctrl=1)
    sc.draw(2, [rtri(r, -0.1, 0.0, 0.9), rtri(r, 0.2, -0.1, 0.9)], 'col')
    sc.query(q + 16, 0)
    sc.target(W, H, [(c4, P4, VK_RGBA8)], ms=2, ds=d4, ds_stride=P4,
              depth=D_TEST | D_WRITE | LESS << 2 | D32F, ctrl=1)
    sc.draw(2, [rtri(r, 0.0, 0.1, 0.9)], 'col')
    sc.query(q + 24, 2)	# both draws
    sc.target(W, H, [(c4, P4, VK_RGBA8)], ms=2, ctrl=0)
    sc.cases.append(('occlusion', [(q, 32), (c, P * H), (d, P * H), (c4, P4 * H),
                                   (d4, P4 * H)]))


CASES = [('stencil', case_stencil), ('d16', case_d16), ('mrt', case_mrt),
         ('fblend', case_fblend), ('lines_points', case_lines_points),
         ('lines_4x', case_lines_4x), ('bias', case_bias), ('clamp_far', case_clamp_far),
         ('occlusion', case_occlusion)]


def build(sc, only):
    pa = PROG
    for name, src in PROGRAMS:
        words = A.encode('\n'.join(src) + '\n')
        sc.prog[name] = pa
        for i, w in enumerate(words):
            sc.poke(pa + 8 * i, w & M.M32)
            sc.poke(pa + 8 * i + 4, w >> 32)
        pa = (pa + 8 * len(words) + 255) & ~255
        assert pa <= PROG_END, 'programs'
    # The fixed state of every case.
    sc.set_regs([(S_VARYING_COUNT, 4), (S_PROVOKING, 0), (S_VS_BASE, sc.prog['vs']),
                 (S_INDEX_FORMAT, 0), (S_PRIM_RESTART, 0), (S_INSTANCE_COUNT, 1),
                 (S_FIRST_INSTANCE, 0), (S_VERTEX_OFFSET, 0)])
    for name, fn in CASES:
        if not only or name in only:
            fn(sc)
    sc.wait_idle()
    sc.packet(5, 1, (FENCES, 1))	# the final fence: value 1 to FENCES
    sc.mem.wr32(FENCES, 1)


def main():
    args = sys.argv[1:]
    seed = int(args.pop(0)) if args and args[0].isdigit() else 1
    sc = Scene(seed)
    build(sc, args)
    assert len(sc.ring) < (1 << RING_LOG2) // 4, 'ring'
    n = 0
    with open(OUT, 'w') as fp:
        fp.write('N %d\n' % len(sc.ring))
        for a, v in sc.init:
            fp.write('I %08x %08x\n' % (a, v))
        for vk in range(256):
            o, b = F.features(vk, True)
            fp.write('F %02x %08x %08x %08x %08x\n' % (vk, o, o, b, 4))
        for w in sc.ring:
            fp.write('R %08x\n' % w)
        fp.write('E %08x %08x\n' % (FENCES, 1))
        for name, regions in sc.cases:
            fp.write('C %s\n' % name)
            for base, size in regions:
                for a in range(base, base + size, 4):
                    fp.write('E %08x %08x\n' % (a, sc.mem.rd32(a)))
                    n += 1
    print('rx-core-scene: %d cases, %d primitives, %d quads, %d ring words, %d words checked, '
          'heap to %05x -> %s' % (len(sc.cases), sc.nprims, sc.nquads, len(sc.ring), n,
                                  sc.heap, OUT))


if __name__ == '__main__':
    main()
