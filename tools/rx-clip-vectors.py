#!/usr/bin/env python3
# rx-clip-vectors.py: writes sim/vec/rx_clip2.txt, the CAPS[30] cases of
# the atg_rx_clip unit testbench (points, lines, the w, far and guard-band
# planes, DEPTH_CLAMP, rasterizer discard), from tools/rxmodel.py (clip2),
# and sim/vec/rx_cpoly.txt for atg_rx_cpoly_tb (single cuts, sequences of
# the seven planes, line segments).  The earlier near-plane cases stay in
# sim/vec/rx_clip.txt (tools/rx-vectors.py).  Both files are in git; check
# `git diff sim/vec` after a change.
#   python3 -I tools/rx-clip-vectors.py
# rx_clip2.txt lines:
#   S idx val                      a STATE write (hex)
#   P sect kind w0..w11 e0 e1 e2 free last n
#                                  a primitive: sect (0 line, 1 point,
#                                  2 clampw, 3 wneg, 4 guard, 5 guardline,
#                                  6 lastuse, 7 discard), the kind, 3 x
#                                  xyzw (a line's third vertex is its
#                                  second, a point's three are the vertex),
#                                  PT entries, prim_free, prim_last, then n
#   C cl_tri                       702-bit hex, one per output
# rx_cpoly.txt lines:
#   V vp0 vp1 vp2 vp3              the viewport words
#   L n line                       a polygon of n vertices, then n lines
#   X w0..w6                       a vertex (7 words)
#   K sect plane n                 a cut (sect 0 planes, 1 seq, 2 line) and
#                                  the n vertices after it, as X lines
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


VPS = [(0.0, 0.0, 0.0, 0.0), (320.0, 240.0, 320.0, 240.0), (320.0, -240.0, 320.0, 240.0),
       (2048.0, 1024.0, 2048.0, 1024.0), (3000.0, 240.0, 3000.0, 240.0)]


def vtx(r, u=1.2, zlo=0.01, zhi=1.0, wlo=0.5, whi=4.0):
    w = r.uniform(wlo, whi)
    return [f(r.uniform(-u, u) * w), f(r.uniform(-u, u) * w), f(r.uniform(zlo, zhi) * w), f(w)]


def hexw(v, bits):
    return '%0*x' % ((bits + 3) // 4, v)


def clip_cases(r):
    cases = []

    def add(sect, kind, pos, dc, rm=0, vp=None):
        cases.append((sect, kind, pos, dc, rm, vp if vp is not None else r.choice(VPS)))
    # lines: across the near, far and w planes, inside, with DEPTH_CLIP or not
    for n in range(48):
        a = vtx(r, zlo=-0.6, zhi=1.6)
        b = vtx(r, zlo=-0.6, zhi=1.6)
        if n % 6 == 5:
            b[3] = f(r.uniform(-1.0, 0.0))	# behind the camera
        add(0, 1, [a, b, b], r.choice([0, 2, 2, 3]))
    # points: inside and outside each depth plane, w below 2^-16
    for n in range(40):
        p = vtx(r, zlo=-0.5, zhi=1.5)
        if n % 8 == 7:
            p[3] = f(r.choice([1e-6, -1.0, 0.0]))
        add(1, 0, [p, p, p], r.choice([0, 1, 2, 3]))
    # clampw: DEPTH_CLAMP[0] (no near or far cut), the w plane still
    for n in range(24):
        pos = [vtx(r, zlo=-0.8, zhi=1.8) for _ in range(3)]
        if n % 3 == 0:
            pos[n % 3][3] = f(r.uniform(-0.5, 1e-6))
        add(2, 2, pos, r.choice([1, 3]))
    # wneg: a vertex with z > 0 and w < 0 (reversed-Z behind the camera)
    for n in range(16):
        pos = [vtx(r, zlo=0.1, zhi=0.9) for _ in range(3)]
        w = r.uniform(-3.0, -0.1)
        pos[n % 3] = [f(r.uniform(-1, 1)), f(r.uniform(-1, 1)), f(r.uniform(0.1, 2.0)), f(w)]
        add(3, 2, pos, 2)
    # guard: large triangles leaving the guard band
    for n in range(32):
        pos = [vtx(r, u=r.choice([1.2, 80.0, 400.0])) for _ in range(3)]
        add(4, 2, pos, r.choice([0, 2]), vp=VPS[1 + n % 4])
    # guardline: lines leaving the guard band
    for n in range(24):
        a = vtx(r, u=300.0)
        b = vtx(r, u=r.choice([1.0, 300.0]))
        add(5, 1, [a, b, b], r.choice([0, 2]), vp=VPS[1 + n % 4])
    # lastuse: many planes at once; the 24 of 3000 candidates with the most
    # outputs (fans up to 8 triangles), and 16 others
    cand = []
    for n in range(3000):
        vp = VPS[1 + n % 3]
        pos = [vtx(r, u=r.choice([60.0, 200.0]), zlo=-1.0, zhi=2.0) for _ in range(3)]
        st = St()
        for k in range(4):
            st[M.S_VIEWPORT + k] = f(vp[k])
        st[M.S_DEPTH_CLAMP] = 2
        cand.append((len(M.clip2(st, 2, pos, [0, 1, 2], 7)), n, pos, vp))
    cand.sort(key=lambda c: (-c[0], c[1]))
    for c in cand[:24] + r.sample(cand[24:], 16):
        add(6, 2, c[2], 2, vp=c[3])
    # discard: RAST_MODE[6], every kind
    for n in range(12):
        pos = [vtx(r) for _ in range(3)]
        k = n % 3
        if k == 0:
            pos = [pos[0]] * 3
        elif k == 1:
            pos[2] = pos[1]
        add(7, k, pos, 2, rm=0x40)
    return cases


def clip2_lines(r):
    out = []
    counts = [0] * 8
    for i, (sect, kind, pos, dc, rm, vp) in enumerate(clip_cases(r)):
        st = St()
        for k in range(4):
            st[M.S_VIEWPORT + k] = f(vp[k])
        st[M.S_DEPTH_CLAMP] = dc
        st[M.S_RAST_MODE] = rm
        for k in range(4):
            out.append('S %03x %08x' % (M.S_VIEWPORT + k, st[M.S_VIEWPORT + k]))
        out.append('S %03x %08x' % (M.S_DEPTH_CLAMP, dc))
        out.append('S %03x %08x' % (M.S_RAST_MODE, rm))
        e = r.sample(range(256), 3)
        if kind == 0:
            e = [e[0]] * 3
        elif kind == 1:
            e[2] = e[1]
        free = r.randrange(8)
        last = i & 1
        tris = M.clip2(st, kind, pos, e, free)
        counts[sect] += 1
        out.append('P %d %d %s %02x %02x %02x %x %d %d' % (
            sect, kind, ' '.join('%08x' % w for v in pos for w in v), e[0], e[1], e[2],
            free, last, len(tris)))
        for t in tris:
            out.append('C %s' % hexw(M.pack_cl2(t), 702))
    out.append('E')
    return out, counts


def cpoly_lines(r):
    out = []
    for n in range(120):
        vp = r.choice(VPS[1:])
        out.append('V %s' % ' '.join('%08x' % f(x) for x in vp))
        sect = 0 if n < 60 else 1 if n < 100 else 2
        line = sect == 2
        nv = 2 if line else 3
        u = r.choice([1.2, 100.0, 400.0])
        best = None
        for _ in range(1 if sect != 1 else 200):
            cand = [vtx(r, u=u, zlo=-1.0, zhi=2.0, wlo=-0.5) + M.IDW[i] for i in range(nv)]
            pp, mx = cand, 0
            for pl in range(7):
                pp = M.clip_cut(pp, pl, tuple(f(x) for x in vp), False)
                mx = max(mx, len(pp))
            if best is None or mx > best[0]:
                best = (mx, cand)
        poly = best[1]
        if line and n % 3 == 0:
            poly[1] = vtx(r) + M.IDW[1]	# one end inside
        out.append('L %d %d' % (nv, 1 if line else 0))
        for v in poly:
            out.append('X %s' % ' '.join('%08x' % w for w in v))
        planes = [r.randrange(7)] if sect == 0 else list(range(7)) if sect == 1 else \
            sorted(r.sample(range(7), 3))
        for pl in planes:
            poly = M.clip_cut(poly, pl, tuple(f(x) for x in vp), line)
            out.append('K %d %d %d' % (sect, pl, len(poly)))
            for v in poly:
                out.append('X %s' % ' '.join('%08x' % w for w in v))
            if not poly:
                break
    out.append('E')
    return out


def main():
    r = random.Random(288030)
    lines, counts = clip2_lines(r)
    with open(os.path.join(VEC, 'rx_clip2.txt'), 'w') as fp:
        fp.write('\n'.join(lines) + '\n')
    lines = cpoly_lines(random.Random(288031))
    with open(os.path.join(VEC, 'rx_cpoly.txt'), 'w') as fp:
        fp.write('\n'.join(lines) + '\n')
    print('rx-clip-vectors: rx_clip2.txt (primitives per section %s), rx_cpoly.txt' %
          ' '.join(str(c) for c in counts))


if __name__ == '__main__':
    main()
