#!/usr/bin/env python3
# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
"""Writes sim/vec/raster_scene.txt for sim/tb/atg_top_raster_tb.v: a scene
of overlapping triangles drawn with DRAW_RAW through the ring, and the
framebuffer and depth buffer the reference model (tools/rxmodel.py) says
they must hold afterwards.

Lines of the file:
  I addr value   initial memory word (before the ring runs)
  R word         a ring word, in order
  E addr value   expected memory word after the final fence
  N count        the number of R words (first line)

  python3 -I tools/rx-raster-scene.py [SEED]
"""

import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'sim', 'vec', 'raster_scene.txt')

W, H = 64, 48
RT = 0x00020000
RT_STRIDE = W * 4
DS = 0x00030000
DS_STRIDE = W * 4
FENCES = 0x0005EF00


def f(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def hdr(vendor, op, tag, flags, n):
    return (vendor << 30) | (op << 24) | (tag << 16) | (flags << 8) | n


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    r = random.Random(seed)
    st = M.State()
    mem = M.Mem()
    init = []
    ring = []

    # Colour buffer cleared to opaque dark grey, depth buffer to 1.0.
    for y in range(H):
        for x in range(W):
            init.append((RT + y * RT_STRIDE + x * 4, 0xFF202020))
            init.append((DS + y * DS_STRIDE + x * 4, f(1.0)))
    for a, v in init:
        mem.wr32(a, v)

    def set_regs(pairs):
        ring.append(hdr(0, 1, 0x40, 0, 2 * len(pairs)))
        for idx, v in pairs:
            ring.append(idx)
            ring.append(v & 0xFFFFFFFF)
            st.set(idx, v)

    # Render target RGBA8 (format 0 = BGRA8), D32F depth, LESS with write.
    vp = (W / 2, H / 2, W / 2, H / 2, 1.0, 0.0)
    pairs = [(M.S_VIEWPORT + k, f(v)) for k, v in enumerate(vp)]
    pairs += [(M.S_RT_BASE, RT), (M.S_RT_STRIDE, RT_STRIDE), (M.S_RT_FORMAT, 0),
              (M.S_RT_SIZE, (H << 16) | W), (M.S_DS_BASE, DS), (M.S_DS_STRIDE, DS_STRIDE),
              (M.S_DEPTH, 1 | (1 << 1) | (1 << 2) | 0x40), (M.S_WRITE_MASK, 0xF),
              (M.S_BLEND, 0), (M.S_CULL, 0)]
    set_regs(pairs)

    for t in range(10):
        color = r.randrange(1 << 24) | (0xFF << 24)
        blend = 0
        if t >= 7:
            # src alpha over dst: SRC_ALPHA (6), ONE_MINUS_SRC_ALPHA (7), ADD (0).
            color = (color & 0xFFFFFF) | (0x80 << 24)
            blend = 1 | (6 << 1) | (7 << 5) | (0 << 9) | (1 << 12) | (7 << 16) | (0 << 20)
        set_regs([(M.S_DEBUG_COLOR, color), (M.S_BLEND, blend)])
        words = []
        for _ in range(3):
            words += [f(r.uniform(-8.0, W + 8.0)), f(r.uniform(-8.0, H + 8.0)), f(r.uniform(0.05, 0.95))]
        ring.append(hdr(1, 0, 0x50 + t, 0, 9))
        ring.extend(words)
        M.draw_raw(st, mem, words)

    # The final fence: value 1 to FENCES.
    ring.append(hdr(0, 5, 0x60, 1, 2))
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
    print('rx-raster-scene: %d ring words, %d expected words -> %s'
          % (len(ring), 2 * W * H + 1, OUT))


if __name__ == '__main__':
    main()
