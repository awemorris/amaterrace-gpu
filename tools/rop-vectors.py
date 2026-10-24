#!/usr/bin/env python3
# rop-vectors.py: writes the CAPS[30] vectors of the render output's unit
# testbenches from tools/rxmodel.py and tools/fmtmodel.py:
#   sim/vec/rop_blend2.txt   atg_rop_blend_tb: the attachments' formats
#                            (R8, R8G8, A1R5G5B5 and the earlier ones by
#                            VkFormat), BLEND1-3, WRITE_MASK per attachment,
#                            the fp32 constants (ROP_CTRL[1])
#   sim/vec/rop_fblend.txt   atg_rop_fblend_tb: the fp32 blend path
# The earlier vectors stay in sim/vec/rop_blend.txt (tools/rx-vectors.py).
# The files are in git; check `git diff sim/vec` after a change.
#   python3 -I tools/rop-vectors.py
# rop_blend2.txt lines:
#   S idx val                    a STATE write (hex)
#   Q sect rt src*16 dst*4 mask res*4
#                                a quad: sect 0 r8rg8 (formats), 1 const;
#                                rt the attachment (b_rt)
# rop_fblend.txt lines:
#   F sect fmt blend const*4 wm lanes src*16 dst*4 raw*4 keep*4
#                                a beat: sect 0 ops, 1 srgb; dst, raw and
#                                keep 64 bits per lane
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rxmodel as M  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
VEC = os.path.join(ROOT, 'sim', 'vec')
f = M.f2b

S_RT_FORMATS, S_BLEND1, S_BLEND_CONST_R, S_ROP_CTRL = 0x07D, 0x084, 0x087, 0x08D
VK8 = [9, 16, 8, 37, 44, 51, 4]


def rnd_src(r):
    px = []
    for _ in range(4):
        k = r.random()
        if k < 0.1:
            px.append(r.choice([0, 0x80000000, M.ONE, 0x7FC00000, 0x7F800000, 0xBF800000,
                                0x3F7FFFFF, 0x3B800000]))
        elif k < 0.2:
            px.append(M.UNORM8[r.randrange(256)])
        else:
            px.append(f(r.uniform(-0.1, 1.1)))
    return px


def blend2_lines(r):
    out = []
    for n in range(1600):
        sect = 0 if n < 1000 else 1
        rt = r.randrange(4)
        vk = (VK8 + [100])[n % 8] if sect == 0 else r.choice(VK8)
        fmts = [r.choice(VK8 + [0, 100]) for _ in range(4)]
        fmts[rt] = vk
        if rt == 0 and n % 11 == 0:
            fmts[0] = 0	# attachment 0 by RT_FORMAT's code
        fmt0 = r.randrange(3)
        bls = [r.getrandbits(23) | 1 for _ in range(4)]
        if n % 5 == 0:
            bls[rt] = 1 | (6 << 1) | (7 << 5) | (1 << 12) | (7 << 16)
        if n % 7 == 0:
            bls[rt] = 0
        wms = r.getrandbits(16) if n % 3 == 0 else 0xFFFF
        kc8 = r.getrandbits(32)
        kcf = [r.choice([f(r.uniform(-0.2, 1.2)), 0x7FC00000, 0xBF800000, M.ONE,
                         M.UNORM8[r.randrange(256)]]) for _ in range(4)]
        ctrl = (r.getrandbits(1) << 1) if sect == 1 else 0
        st = [(M.S_RT_FORMAT, fmt0), (S_RT_FORMATS, fmts[0] | fmts[1] << 8 | fmts[2] << 16 |
                                     fmts[3] << 24),
              (M.S_BLEND, bls[0]), (S_BLEND1, bls[1]), (S_BLEND1 + 1, bls[2]),
              (S_BLEND1 + 2, bls[3]), (M.S_BLEND_CONST, kc8),
              (S_BLEND_CONST_R, kcf[0]), (S_BLEND_CONST_R + 1, kcf[1]),
              (S_BLEND_CONST_R + 2, kcf[2]), (S_BLEND_CONST_R + 3, kcf[3]),
              (S_ROP_CTRL, ctrl | r.getrandbits(1)), (M.S_WRITE_MASK, wms)]
        for k, v in st:
            out.append('S %03x %08x' % (k, v))
        evk = fmts[rt] if fmts[rt] or rt else [44, 37, 4][fmt0]
        kc = sum(M.f2u8(kcf[c]) << (8 * c) for c in range(4)) if ctrl else kc8
        src = [rnd_src(r) for _ in range(4)]
        dst = [r.getrandbits(32) for _ in range(4)]
        mask = r.getrandbits(4)
        wm = (wms >> (4 * rt)) & 15
        res = [M.blend_pixel8(evk, bls[rt], kc, wm, src[ln], dst[ln]) if mask >> ln & 1
               else dst[ln] for ln in range(4)]
        out.append('Q %d %d %s %s %x %s' % (
            sect, rt, ' '.join('%08x' % w for px in src for w in px),
            ' '.join('%08x' % d for d in dst), mask, ' '.join('%08x' % p for p in res)))
    out.append('E')
    return out


def fblend_lines(r):
    out = []
    fmts = list(M.FBLEND_FMTS)
    for n in range(900):
        sect = 0
        fmt = fmts[n % len(fmts)] if n % 50 else 100
        bl = r.getrandbits(23) | 1 if n % 9 else r.getrandbits(23) & ~1
        if n % 6 == 0:	# source-over
            bl = 1 | (6 << 1) | (7 << 5) | (1 << 12) | (7 << 16)
        kc = [r.choice([f(r.uniform(-0.3, 1.3)), M.ONE, 0, 0x7FC00000,
                        f(r.uniform(-100, 100))]) for _ in range(4)]
        wm = 15 if n % 4 else r.getrandbits(4)
        lanes = r.getrandbits(4) if n % 3 == 0 else 15
        src = []
        for _ in range(4):
            px = []
            for _ in range(4):
                k = r.random()
                if k < 0.12:
                    px.append(r.choice([0, 0x80000000, M.ONE, 0x7FC00000, 0x7F800000,
                                        0xFF800000, 0xBF800000, 0x00400000, 0x477FE000,
                                        0x47800000]))
                elif k < 0.5:
                    px.append(f(r.uniform(-0.2, 1.2)))
                else:
                    px.append(f(r.uniform(-1000.0, 1000.0)))
            src.append(px)
        dst = [r.getrandbits(64) for _ in range(4)]
        out.append(fbeat(sect, fmt, bl, kc, wm, lanes, src, dst))
    # srgb: ZERO x source + ONE x destination keeps every code
    codes = list(range(256))
    r.shuffle(codes)
    bl = 1 | (0 << 1) | (1 << 5) | (0 << 12) | (1 << 16)
    for n in range(64):
        fmt = (43, 50, 57)[n % 3]
        dst = []
        for ln in range(4):
            cs = [codes[4 * n + ln], r.randrange(256), r.randrange(256), r.randrange(256)]
            if fmt == 50:
                raw = cs[2] | cs[1] << 8 | cs[0] << 16 | cs[3] << 24
            else:
                raw = cs[0] | cs[1] << 8 | cs[2] << 16 | cs[3] << 24
            dst.append(raw | r.getrandbits(32) << 32)
        src = [[f(r.uniform(0, 1)) for _ in range(4)] for _ in range(4)]
        line = fbeat(1, fmt, bl, [0] * 4, 15, 15, src, dst)
        for ln in range(4):
            raw, _ = M.fblend_lane(fmt, bl, [0] * 4, 15, src[ln], dst[ln] & 0xFFFFFFFF)
            assert raw == dst[ln] & 0xFFFFFFFF, (fmt, hex(raw), hex(dst[ln]))
        out.append(line)
    out.append('E')
    return out


def fbeat(sect, fmt, bl, kc, wm, lanes, src, dst):
    raws, keeps = [], []
    for ln in range(4):
        if lanes >> ln & 1:
            raw, keep = M.fblend_lane(fmt, bl, kc, wm, src[ln], dst[ln])
        else:
            raw, keep = 0, (1 << 64) - 1
        raws.append(raw)
        keeps.append(keep)
    return 'F %d %d %06x %s %x %x %s %s %s %s' % (
        sect, fmt, bl, ' '.join('%08x' % k for k in kc), wm, lanes,
        ' '.join('%08x' % w for px in src for w in px), ' '.join('%016x' % d for d in dst),
        ' '.join('%016x' % v for v in raws), ' '.join('%016x' % v for v in keeps))


def main():
    r = random.Random(288035)
    with open(os.path.join(VEC, 'rop_blend2.txt'), 'w') as fp:
        fp.write('\n'.join(blend2_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_fblend.txt'), 'w') as fp:
        fp.write('\n'.join(fblend_lines(r)) + '\n')
    print('rop-vectors: rop_blend2.txt, rop_fblend.txt')


if __name__ == '__main__':
    main()
