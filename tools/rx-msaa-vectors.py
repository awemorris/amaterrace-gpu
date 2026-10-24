#!/usr/bin/env python3
# rx-msaa-vectors.py: writes the multisampling expected-value files of the
# RX unit testbenches into sim/vec/ from the reference model
# (tools/msmodel.py on tools/rxmodel.py):
#   rx_scan_ms.txt  atg_rx_scan_tb's warp-path cases: per triangle
#                   "T sp_tri MS_CTRL SAMPLE_KILL quads", per quad
#                   "Q x y scov ccov" (the quads with a covered sample)
#   rx_frag_ms.txt  atg_rx_frag_tb's multisampling cases: per triangle
#                   "T sp_tri VARYING_COUNT warps MS_CTRL", with 4 samples
#                   "D d0 d1 d2 d3", per warp "W quads", per quad
#                   "Q x y scov ccov" and 4 lines "L" of r0-r6 (r0-r9 with
#                   MS_CTRL[4])
#   rop_ms.txt      atg_rop_ms_tb (atg_rop as a whole: order, ms, ds, wb,
#                   blend): per run "R MS_CTRL DEPTH RT_FORMAT BLEND
#                   WRITE_MASK DEBUG_COLOR quads", the RT and DS images
#                   before ("I" + the words), per quad "Q dbg x y mask
#                   ex_ms color depth" (hex; ex_ms 148 bits, color 512,
#                   depth 128), the images after ("F" + the words)
# The single-sample files (tools/rx-vectors.py) are not changed by the
# multisampling work: the testbenches read them as before.
# The files are in git; run this after changing the model or the cases.
#   tools/rx-msaa-vectors.py       (a few seconds)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402
import msmodel as MS  # noqa: E402

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
    print('rx-msaa-vectors: %s (%d lines)' % (name, len(lines)))


def raw_words(r, cx, cy, s):
    return [w for _ in range(3) for w in (f(cx + r.uniform(-s, s)), f(cy + r.uniform(-s, s)),
                                           f(r.random()))]


def scan_vectors(r):
    out = []
    st = M.State()
    st.set(M.S_RT_SIZE, (48 << 16) | 64)
    tris = []
    for n in range(24):
        tris.append(raw_words(r, r.uniform(0, 64), r.uniform(0, 48), r.choice([1.0, 3.0, 9.0, 30.0])))
    # shared edges through sample locations (vertices on 1/8 pixels)
    for (ax, ay, bx, by, cx, cy, dx, dy) in ((2.375, 2.125, 20.875, 2.375, 20.625, 20.875, 2.125, 20.625),
                                             (40.0, 10.0, 60.0, 30.0, 40.0, 46.0, 20.0, 30.0)):
        tris.append([f(ax), f(ay), 0, f(bx), f(by), 0, f(dx), f(dy), 0])
        tris.append([f(bx), f(by), 0, f(cx), f(cy), 0, f(dx), f(dy), 0])
    # a thin sliver: the skip of empty quads must not drop samples
    tris.append([f(1.0), f(1.0), 0, f(62.0), f(46.0), 0, f(1.3), f(1.2), 0])
    tris.append([f(5.5), f(5.5), 0, f(5.6), f(5.5), 0, f(5.5), f(5.6), 0])
    for i, words in enumerate(tris):
        ctrl = 2 if i % 5 else 0
        kill = [0, 0, 5, 8, 15, 2][i % 6]
        rs = M.setup(st, M.raw_tri(words))
        quads = [q for q in MS.scan_ms(rs, ctrl == 2, kill) if q[2]]
        rs['raw'] = 0	# the warp path
        out.append('T %s %x %x %d' % (hexw(M.pack_sp(rs), 768), ctrl, kill, len(quads)))
        for (x, y, sc, cc) in quads:
            out.append('Q %04x %04x %04x %x' % (x, y, sc, cc))
    out.append('E')
    return out


def frag_vectors(r):
    out = []
    st = M.State()
    for k, v in enumerate((16.0, 12.0, 16.0, 12.0, 1.0, 0.0)):
        st.set(M.S_VIEWPORT + k, f(v))
    st.set(M.S_RT_SIZE, (24 << 16) | 32)
    for n in range(16):
        pos = [[f(r.uniform(-1.2, 1.2)), f(r.uniform(-1.2, 1.2)), f(r.uniform(-0.2, 1.2)),
                f(r.uniform(0.5, 2.0))] for _ in range(3)]
        wt = [[f(r.uniform(0, 1)) for _ in range(3)] for _ in range(3)]
        tri = {'pos': pos, 'wt': wt, 'pt': [r.randrange(64) for _ in range(3)],
               'free': r.randrange(8), 'raw': 0}
        ctrl = [2, 0x12, 2, 0x12, 0x10][n % 5]
        kill = 0 if n % 3 else 4
        ms4 = ctrl & 15 == 2
        cent = bool(ctrl & 0x10)
        rs = M.setup(st, tri)
        ws = MS.warps_ms(rs, ms4, kill)
        vc = [0, 1, 4, 32][n % 4]
        out.append('T %s %d %d %x %x' % (hexw(M.pack_sp(rs), 768), vc, len(ws), ctrl, kill))
        if ms4:
            out.append('D ' + ' '.join('%08x' % v for v in MS.dz_ms(rs)))
        for w in ws:
            out.append('W %d' % len(w))
            for (x, y, sc, cc) in w:
                out.append('Q %04x %04x %04x %x' % (x, y, sc, cc))
                for ln in range(4):
                    regs = MS.frag_lane_ms(rs, x + (ln & 1), y + (ln >> 1), ms4,
                                           sc >> (4 * ln) & 15, cc >> ln & 1, cent)
                    n_r = 10 if cent else 7
                    out.append('L ' + ' '.join('%08x' % v for v in regs[:n_r]))
    out.append('E')
    return out


RT_BASE, DS_BASE, W, H = 0x1000, 0x5000, 16, 8


def rnd_alpha(r):
    k = r.random()
    if k < 0.2:
        return r.choice([0, 0x80000000, 0x3E000000, 0x3DFFFFFF, 0x3EC00000, 0x3F200000, 0x3F1FFFFF,
                         0x3F600000, 0x3F000000, 0x3EFFFFFF, M.ONE, 0x7FC00000, 0xBF000000,
                         0x7F800000])
    return f(r.uniform(-0.1, 1.2))


def rop_vectors(r):
    out = []
    runs = [
        # MS_CTRL, DEPTH, RT_FORMAT, BLEND, WRITE_MASK
        (2, 0x1 | 1 << 2 | 2 | 0x40, 1, 0, 0xF),		# 4x, D32F LESS + write
        (2, 0x1 | 3 << 2 | 2 | 0x20, 0, 0, 0xF),		# 4x, D24S8 LEQUAL + write, BGRA8
        (2, 0x1 | 6 << 2 | 2 | 0x40, 2, 0, 0x7),		# 4x, D32F GEQUAL, RGB565
        (0x102, 0x1 | 1 << 2 | 2 | 0x40, 1, 0, 0xF),	# 4x, alpha to coverage
        (0x302, 0, 1, 0, 0xF),				# 4x, a2c + alpha to one, no depth
        (0x202, 0x1 | 7 << 2 | 0x40, 1, 1 | 6 << 1 | 7 << 5 | 1 << 12 | 7 << 16, 0xF),	# blend
        (0x100, 0x1 | 1 << 2 | 2 | 0x40, 1, 0, 0xF),	# 1x with a2c (bypass)
        (0, 0x1 | 3 << 2 | 2 | 0x20, 2, 0, 0x5),		# 1x, D24S8, RGB565, partial mask
    ]
    for (ctrl, dep, fmt, blend, wm) in runs:
        ms4 = ctrl & 15 == 2
        ns = 4 if ms4 else 1
        ps = 2 if fmt == 2 else 4
        st = M.State()
        st.set(MS.S_MS_CTRL, ctrl)
        st.set(M.S_DEPTH, dep)
        st.set(M.S_RT_FORMAT, fmt)
        st.set(M.S_BLEND, blend)
        st.set(M.S_BLEND_CONST, r.getrandbits(32))
        st.set(M.S_WRITE_MASK, wm)
        dbgc = r.getrandbits(32)
        st.set(M.S_DEBUG_COLOR, dbgc)
        st.set(M.S_RT_BASE, RT_BASE)
        st.set(M.S_RT_STRIDE, W * ns * ps)
        st.set(M.S_DS_BASE, DS_BASE)
        st.set(M.S_DS_STRIDE, W * ns * 4)
        mem = M.Mem()
        rtw = W * ns * ps * H // 4
        dsw = W * ns * 4 * H // 4
        for i in range(rtw):
            mem.wr32(RT_BASE + 4 * i, r.getrandbits(32))
        for i in range(dsw):
            v = r.getrandbits(32) if dep & 0x20 else f(r.uniform(0, 1))
            mem.wr32(DS_BASE + 4 * i, v)
        quads = []
        for n in range(60):
            dbg = r.random() < 0.15
            x, y = 2 * r.randrange(W // 2), 2 * r.randrange(H // 2)
            mask = r.randrange(1, 16)
            sm = 0
            zexp = 0
            for ln in range(4):
                if mask >> ln & 1:
                    sm |= r.randrange(1, 16) << (4 * ln)
                    if r.random() < 0.25:
                        zexp |= 1 << ln
            ds = [f(r.uniform(-0.05, 0.05)) for _ in range(4)]
            col = [[f(r.uniform(-0.1, 1.2)) for _ in range(3)] + [rnd_alpha(r)] for _ in range(4)]
            z = [f(r.uniform(-0.1, 1.1)) for _ in range(4)]
            quads.append((dbg, x, y, mask, sm, zexp, ds, col, z))
        out.append('R %x %x %x %x %x %x %d' % (ctrl, dep, fmt, blend, wm, dbgc, len(quads)))
        out.append('I ' + ' '.join('%08x' % mem.rd32(RT_BASE + 4 * i) for i in range(rtw)) + ' ' +
                   ' '.join('%08x' % mem.rd32(DS_BASE + 4 * i) for i in range(dsw)))
        for (dbg, x, y, mask, sm, zexp, ds, col, z) in quads:
            if dbg:
                # the direct path: every sample of a lane, the lane's depth, DEBUG_COLOR
                smd = sum(15 << (4 * ln) for ln in range(4) if mask >> ln & 1)
                MS.rop_quad_ms(st, mem, x, y, smd if ms4 else sum(1 << (4 * ln) for ln in range(4)
                                                                 if mask >> ln & 1),
                               z, [M.debug_rgba(st)] * 4, 15, z, (0, 0, 0, 0), dbg=True)
                exms = 0
            else:
                MS.rop_quad_ms(st, mem, x, y, sm, z, col, zexp, z, ds)
                exms = (ds[3] << 116 | ds[2] << 84 | ds[1] << 52 | ds[0] << 20) | zexp << 16 | sm
            cw = 0
            for ln in range(4):
                for c in range(4):
                    cw |= col[ln][c] << (128 * ln + 32 * c)
            zw = z[0] | z[1] << 32 | z[2] << 64 | z[3] << 96
            out.append('Q %d %04x %04x %x %s %s %s' % (dbg, x, y, mask, hexw(exms, 148),
                                                    hexw(cw, 512), hexw(zw, 128)))
        out.append('F ' + ' '.join('%08x' % mem.rd32(RT_BASE + 4 * i) for i in range(rtw)) + ' ' +
                   ' '.join('%08x' % mem.rd32(DS_BASE + 4 * i) for i in range(dsw)))
    out.append('E')
    return out


def main():
    put('rx_scan_ms.txt', scan_vectors(random.Random(288027)))
    put('rx_frag_ms.txt', frag_vectors(random.Random(288028)))
    put('rop_ms.txt', rop_vectors(random.Random(288029)))


if __name__ == '__main__':
    main()
