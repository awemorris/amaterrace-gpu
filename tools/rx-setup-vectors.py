#!/usr/bin/env python3
# rx-setup-vectors.py: writes sim/vec/rx_setup2.txt, the CAPS[30] cases of
# the atg_rx_setup unit testbench (lines, points, the viewport's rectangle,
# depth bias), from tools/rxmodel.py (setup2).  The earlier triangle cases
# stay in sim/vec/rx_setup.txt (tools/rx-vectors.py), which the testbench
# also uses as the vec-diff check (setup2 gives the same sp_tri).  The file
# is in git; check `git diff sim/vec` after a change.
#   python3 -I tools/rx-setup-vectors.py
# Lines:
#   S idx val                      a STATE write (hex)
#   T sect cl_tri n                a primitive (sect 0 line, 1 point,
#                                  2 viewport, 3 bias), its 702-bit cl_tri
#                                  and the number of outputs, then n lines
#   O sp_tri last                  768-bit sp_tri, sp_last
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')
f = M.f2b


class St(dict):
    def __missing__(self, k):
        return 0


def hexw(v, bits):
    return '%0*x' % ((bits + 3) // 4, v)


def base_state():
    st = St()
    for k, v in enumerate((256.0, 256.0, 256.0, 256.0, 0.5, 0.25)):
        st[M.S_VIEWPORT + k] = f(v)
    st[M.S_RT_SIZE] = (512 << 16) | 512
    return st


def ndc(st, X, Y):
    """Clip x, y (w = 1) for window X, Y."""
    xs, ys = M.b2f(st[M.S_VIEWPORT]), M.b2f(st[M.S_VIEWPORT + 1])
    xo, yo = M.b2f(st[M.S_VIEWPORT + 2]), M.b2f(st[M.S_VIEWPORT + 3])
    return (X - xo) / xs, (Y - yo) / ys


def prim(st, kind, wins, r, wt=None, w=None):
    """A cl_tri of the kind from window positions (and random z, w)."""
    pos = []
    for i, (X, Y) in enumerate(wins):
        ww = w[i] if w else 1.0
        x, y = ndc(st, X, Y)
        pos.append([f(x * ww), f(y * ww), f(r.uniform(0.0, 1.0) * ww), f(ww)])
    if kind == 1:
        pos[2] = pos[1]
    if kind == 0:
        pos = [pos[0]] * 3
    if wt is None:
        wt = [row[:] for row in M.IDW]
        if kind == 1:
            wt[2] = wt[1]
        if kind == 0:
            wt = [wt[0]] * 3
    return {'pos': pos, 'wt': wt, 'pt': [r.randrange(256) for _ in range(3)],
            'free': r.randrange(1, 8), 'raw': 0, 'kind': kind}


def cases(r):
    out = []
    # lines: x-major, y-major, equal, short, empty, with scissor
    for n in range(48):
        st = base_state()
        ax, ay = r.uniform(20, 480) + r.choice([0, 0.5]), r.uniform(20, 480)
        m = n % 6
        if m == 0:
            b = (ax + r.uniform(5, 200), ay + r.uniform(-4, 4))
        elif m == 1:
            b = (ax + r.uniform(-4, 4), ay - r.uniform(5, 200))
        elif m == 2:
            d = r.choice([16.0, 40.0, -24.0])
            b = (ax + d, ay + r.choice([d, -d]))
        elif m == 3:
            b = (ax + r.uniform(-1.5, 1.5), ay + r.uniform(-1.5, 1.5))
        elif m == 4:
            b = (ax, ay)
        else:
            b = (r.uniform(0, 512), r.uniform(0, 512))
            st[M.S_SCISSOR_MIN] = (100 << 16) | 120
            st[M.S_SCISSOR_MAX] = (400 << 16) | 380
        w = [r.uniform(0.5, 3.0), r.uniform(0.5, 3.0), 1.0]
        wt = [[f(r.uniform(0, 1)) for _ in range(3)] for _ in range(3)]
        wt[2] = wt[1]
        out.append((0, st, prim(st, 1, [(ax, ay), b, b], r, wt, w)))
    # points
    for n in range(32):
        st = base_state()
        p = (r.uniform(0, 512), r.uniform(0, 512))
        if n % 4 == 1:
            p = (float(r.randrange(10, 500)), float(r.randrange(10, 500)) + 0.5)
        if n % 8 == 7:
            st[M.S_SCISSOR_MIN] = (200 << 16) | 200
            st[M.S_SCISSOR_MAX] = (300 << 16) | 300
        out.append((1, st, prim(st, 0, [p, p, p], r, w=[r.uniform(0.5, 2.0)] * 3)))
    # the viewport's rectangle: triangles, lines and points with a viewport
    # smaller than the scissor (and a DRAW_RAW triangle that ignores it)
    for n in range(32):
        st = base_state()
        cx, cy, hw, hh = (float(r.randrange(100, 400)), float(r.randrange(100, 400)),
                          float(r.randrange(10, 90)), float(r.randrange(10, 90)))
        st[M.S_VIEWPORT] = f(hw if n % 3 else -hw)
        st[M.S_VIEWPORT + 1] = f(-hh if n % 2 else hh)
        st[M.S_VIEWPORT + 2] = f(cx)
        st[M.S_VIEWPORT + 3] = f(cy)
        st[M.S_RAST_MODE] = 0x08
        k = [2, 2, 1, 0][n % 4]
        wins = [(cx + r.uniform(-1.5, 1.5) * hw, cy + r.uniform(-1.5, 1.5) * hh)
                for _ in range(3)]
        if n == 31:
            words = []
            for (X, Y) in wins:
                words += [f(X), f(Y), f(0.5)]
            t = M.raw_tri(words)
            t['kind'] = 2
            out.append((2, st, t))
        else:
            out.append((2, st, prim(st, k, wins, r)))
    # depth bias: the four formats, the clamp's signs, also lines (no bias)
    for n in range(40):
        st = base_state()
        fmt = n % 4
        st[M.S_RAST_MODE] = 1 | fmt << 4 | (0 if n % 9 else 0x08)
        st[M.S_DEPTH_BIAS_CONST] = f(r.choice([0.0, 1.0, 3.0, -2.0, 1000.0]))
        st[M.S_DEPTH_BIAS_SLOPE] = f(r.choice([0.0, 1.0, 2.5, -1.0]))
        st[M.S_DEPTH_BIAS_CLAMP] = f(r.choice([0.0, 0.001, -0.001, 1e-5, -1e-5]))
        if n % 10 == 9:
            st[M.S_VIEWPORT + 4] = f(r.uniform(1e-3, 40.0))
        wins = [(r.uniform(50, 450), r.uniform(50, 450)) for _ in range(3)]
        k = 1 if n % 13 == 12 else 2
        out.append((3, st, prim(st, k, wins, r, w=[r.uniform(0.3, 3.0) for _ in range(3)])))
    return out


def main():
    r = random.Random(288034)
    lines = []
    keys = [M.S_VIEWPORT + k for k in range(6)] + [M.S_SCISSOR_MIN, M.S_SCISSOR_MAX,
                                                  M.S_CULL, M.S_RAST_MODE,
                                                  M.S_DEPTH_BIAS_CONST, M.S_DEPTH_BIAS_SLOPE,
                                                  M.S_DEPTH_BIAS_CLAMP, M.S_RT_SIZE]
    counts = [0] * 4
    for sect, st, tri in cases(r):
        for k in keys:
            lines.append('S %03x %08x' % (k, st[k]))
        outs = M.setup2(st, tri)
        counts[sect] += 1
        lines.append('T %d %s %d' % (sect, hexw(M.pack_cl2(tri), 702), len(outs)))
        for o in outs:
            lines.append('O %s %d' % (hexw(M.pack_sp2(o), 768), 1 if o['last'] else 0))
    lines.append('E')
    with open(os.path.join(VEC, 'rx_setup2.txt'), 'w') as fp:
        fp.write('\n'.join(lines) + '\n')
    print('rx-setup-vectors: rx_setup2.txt (primitives per section %s)' %
          ' '.join(str(c) for c in counts))


if __name__ == '__main__':
    main()
