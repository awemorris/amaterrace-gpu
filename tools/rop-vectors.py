#!/usr/bin/env python3
# rop-vectors.py: writes the CAPS[30] vectors of the render output's unit
# testbenches from tools/rxmodel.py and tools/fmtmodel.py:
#   sim/vec/rop_blend2.txt   atg_rop_blend_tb: the attachments' formats
#                            (R8, R8G8, A1R5G5B5 and the earlier ones by
#                            VkFormat), BLEND1-3, WRITE_MASK per attachment,
#                            the fp32 constants (ROP_CTRL[1])
#   sim/vec/rop_fblend.txt   atg_rop_fblend_tb: the fp32 blend path
#   sim/vec/rop_dtest.txt    atg_rop_dtest_tb: bounds, stencil and depth
#   sim/vec/rop_ds2.txt      atg_rop_ds_tb: stencil, D16 and bounds runs
#   sim/vec/rop_msz.txt      atg_rop_msz_tb: atg_rop_ms's depth (DEPTH_CLAMP)
#   sim/vec/rop_mrt.txt      atg_rop_mrt_tb: atg_rop_wb, atg_rop_wpix and
#                            atg_rop_blend: four attachments of every
#                            colour-attachment format, one and four samples
# The earlier vectors stay in sim/vec/rop_blend.txt (tools/rx-vectors.py).
# The files are in git; check `git diff sim/vec` after a change.
#   python3 -I tools/rop-vectors.py
# rop_blend2.txt lines:
#   S idx val                    a STATE write (hex)
#   Q sect rt src*16 dst*4 mask res*4
#                                a quad: sect 0 r8rg8 (formats), 1 const;
#                                rt the attachment (b_rt)
# rop_dtest.txt lines:
#   D sect depth sfront sback sops bmin bmax cov front zf stored pass wword wbe
#                                sect 0 stencil, 1 d16, 2 bounds, 3 order
# rop_ds2.txt lines (as rop_ds.txt's, with the CAPS[30] STATE and facing):
#   R sect depth sfront sback sops bmin bmax debug stride word*256
#   Q x y mask front z0..z3 pass
#   F word*256                   the buffer at the end
#                                sect 0 stencil, 1 d16, 2 bounds
# rop_msz.txt lines:
#   Z sect dc zscale zoff ms4 mask zexp z0..z3 ds0..ds3 sdepth*16
#                                sect 0 clamp, 1 legacy (DEPTH_CLAMP 0)
# rop_fblend.txt lines:
#   F sect fmt blend const*4 wm lanes src*16 dst*4 raw*4 keep*4
#                                a beat: sect 0 ops, 1 srgb; dst, raw and
#                                keep 64 bits per lane
# rop_mrt.txt lines:
#   R ms4 ctrl fmts bl0..bl3 kc8 kcf0..kcf3 fmt0 wms base0..3 stride0..3 nw
#                                a run: the ROP state (RT_FORMATS, BLEND,
#                                BLEND1-3, BLEND_CONST, BLEND_CONST_R-A,
#                                RT_FORMAT, WRITE_MASK, RTk_BASE/STRIDE,
#                                ROP_CTRL, MS_CTRL) and the region's words
#   M word*nw                    the region at 0x2000 before the run
#   B x y rt nocol smask col*16  a beat (atg_rop_wb's d_*)
#   F word*nw                    the region at the end
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


def rnd_z(r):
    k = r.random()
    if k < 0.15:
        return r.choice([0, 0x80000000, M.ONE, 0x7FC00000, 0x7F800000, 0xBF800000,
                         0x00400000, 0x3F7FFFFF, 0x3F800001])
    return f(r.uniform(-0.1, 1.1))


def dtest_lines(r):
    import fmtmodel as F
    out = []
    for n in range(6000):
        sect = 0 if n < 3000 else 1 if n < 4000 else 2 if n < 5000 else 3
        cov = int(r.random() < 0.9)
        front = r.getrandbits(1)
        sf = r.getrandbits(27)
        sb = r.getrandbits(27)
        sops = r.getrandbits(9) | r.getrandbits(9) << 16
        zf = rnd_z(r)
        stored = r.getrandbits(32)
        bmin, bmax = sorted([f(r.uniform(0, 1)) for _ in range(2)])
        if r.random() < 0.05:
            bmin = r.choice([0x7FC00000, 0x80000000, 0])
        if sect == 0:
            fmt = 1 << 5
            depth = r.getrandbits(5) | fmt | 1 << 8 | (r.getrandbits(1) << 9)
            if n % 7 == 0:
                # small references and stored values: the clamp and wrap edges
                stored = (stored & 0xFFFFFF) | r.choice([0, 1, 254, 255, 128]) << 24
                sf = (sf & ~255) | r.choice([0, 1, 255])
                sb = (sb & ~255) | r.choice([0, 1, 255])
        elif sect == 1:
            fmt = 1 << 7
            depth = r.getrandbits(5) | fmt | (r.getrandbits(1) << 8) | (r.getrandbits(1) << 9)
            stored &= 0xFFFF
            if n % 3 == 0:
                # the stored value next to the new depth's code
                stored = (F.f32_unorm(zf, 16) + r.choice([-1, 0, 1])) & 0xFFFF
        elif sect == 2:
            fmt = r.choice([1, 2, 4]) << 5
            depth = r.getrandbits(5) | fmt | 1 << 9 | (r.getrandbits(1) << 8)
            if fmt == 1 << 7:
                stored &= 0xFFFF
            if fmt == 2 << 5:
                stored = r.choice([f(r.uniform(-0.2, 1.2)), bmin, bmax, 0x7FC00000, 0x80000000])
            if n % 4 == 0:
                # the stored depth at a bound
                za = bmin if r.getrandbits(1) else bmax
                if fmt == 2 << 5:
                    stored = za
        else:
            fmt = r.choice([1, 2, 4, 0, 3, 5]) << 5
            depth = r.getrandbits(5) | fmt | r.getrandbits(2) << 8
            if (fmt >> 5) == 4:
                stored &= 0xFFFF
        p, ww, be = M.dtest(depth, sf, sb, sops, bmin, bmax, cov, front, zf, stored)
        out.append('D %d %03x %07x %07x %07x %08x %08x %d %d %08x %08x %d %08x %x' % (
            sect, depth, sf, sb, sops, bmin, bmax, cov, front, zf, stored, int(bool(p)), ww, be))
    out.append('E')
    return out


DS_BASE = 0x1000


def ds_quad2(st, mem, x, y, mask, z, front):
    """atg_rop_ds with CAPS[30] (one sample): every lane through dtest,
    the written bytes by its byte enables; returns the passing lanes."""
    depth = st['depth']
    d16 = (depth >> 5) & 7 == 4
    ps = 2 if d16 else 4
    out = 0
    for ln in range(4):
        if not mask >> ln & 1:
            continue
        px, py = x + (ln & 1), y + (ln >> 1)
        a = DS_BASE + py * st['stride'] + px * ps
        stored = sum(mem.rd8(a + i) << (8 * i) for i in range(ps))
        p, ww, be = M.dtest(depth, st['sf'], st['sb'], st['sops'], st['bmin'], st['bmax'], 1,
                            front, z[ln], stored)
        if p:
            out |= 1 << ln
        for i in range(4):
            if be >> i & 1:
                mem.wr8(a + i, ww >> (8 * i))
    return out


def ds2_lines(r):
    out = []
    runs = [0] * 12 + [1] * 10 + [2] * 8
    for n, sect in enumerate(runs):
        st = {'sf': r.getrandbits(27), 'sb': r.getrandbits(27),
              'sops': r.getrandbits(9) | r.getrandbits(9) << 16}
        st['bmin'], st['bmax'] = sorted([f(r.uniform(0, 1)) for _ in range(2)])
        func, wr = r.randrange(8), int(r.random() < 0.8)
        if sect == 0:
            st['depth'] = int(r.random() < 0.7) | wr << 1 | func << 2 | 1 << 5 | 1 << 8
            st['stride'] = 64
        elif sect == 1:
            st['depth'] = 1 | wr << 1 | func << 2 | 1 << 7 | r.getrandbits(1) << 9
            st['stride'] = 32
        else:
            fmt = (1, 2, 4)[n % 3]
            st['depth'] = r.getrandbits(1) | wr << 1 | func << 2 | fmt << 5 | 1 << 9 | \
                (r.getrandbits(1) << 8 if fmt == 1 else 0)
            st['stride'] = 32 if fmt == 4 else 64
        dbg = r.getrandbits(32)
        mem = M.Mem()
        init = []
        f32 = (st['depth'] >> 5) & 7 == 2
        for i in range(256):
            v = f(r.uniform(0, 1)) if f32 else r.getrandbits(32)
            if sect == 0 and r.random() < 0.3:
                v = (v & 0xFFFFFF) | r.choice([0, 1, 255, 254]) << 24
            mem.wr32(DS_BASE + 4 * i, v)
            init.append(v)
        out.append('R %d %03x %07x %07x %07x %08x %08x %08x %x %s' % (
            sect, st['depth'], st['sf'], st['sb'], st['sops'], st['bmin'], st['bmax'], dbg,
            st['stride'], ' '.join('%08x' % v for v in init)))
        for k in range(60):
            x, y = 2 * r.randrange(8), 2 * r.randrange(8)
            mask = r.getrandbits(4)
            front = r.getrandbits(1)
            z = [f(r.uniform(0, 1)) if r.random() < 0.9 else
                 r.choice([0, M.ONE, 0x7FC00000, st['bmin'], st['bmax']]) for _ in range(4)]
            p = ds_quad2(st, mem, x, y, mask, z, front)
            out.append('Q %04x %04x %x %d %s %x' % (x, y, mask, front,
                                                    ' '.join('%08x' % v for v in z), p))
        out.append('F %s' % ' '.join('%08x' % mem.rd32(DS_BASE + 4 * i) for i in range(256)))
    out.append('E')
    return out


def ms_depth(dc, zs, zo, ms4, z, ds, zexp):
    """atg_rop_ms's depths of the samples (spec atg_rop_ms §4, CAPS[30])."""
    zf = M.fadd(zo, zs)
    zmin, zmax = (zo, zf) if M.fle(zo, zf) else (zf, zo)

    def clamp(x):
        if M._isnan(x) or M.fle(x, zmin):
            return zmin
        return zmax if M.fle(zmax, x) else x
    out = [0] * 16
    for ln in range(4):
        for smp in range(4 if ms4 else 1):
            if ms4 and zexp >> ln & 1:
                v = z[ln]
            elif ms4:
                v = M.fadd(z[ln], ds[smp])
                if not dc & 2:
                    v = M.fclamp01(v)
            else:
                v = z[ln]
            out[4 * ln + smp] = clamp(v) if dc & 1 else v
    return out


def msz_lines(r):
    out = []
    for n in range(1200):
        sect = 0 if n < 900 else 1
        dc = r.randrange(4) if sect == 0 else 0
        zs = r.choice([f(r.uniform(-1, 1)), 0, f(1.0), f(-1.0)])
        zo = f(r.uniform(0, 1))
        ms4 = r.getrandbits(1)
        mask = r.randrange(1, 16)
        zexp = r.getrandbits(4) if r.random() < 0.3 else 0
        z = [r.choice([f(r.uniform(-0.5, 1.5)), 0x7FC00000, 0x80000000, M.ONE,
                       f(r.uniform(0, 1))]) for _ in range(4)]
        ds = [f(r.uniform(-0.05, 0.05)) for _ in range(4)]
        sd = ms_depth(dc, zs, zo, ms4, z, ds, zexp)
        out.append('Z %d %d %08x %08x %d %x %x %s %s %s' % (
            sect, dc, zs, zo, ms4, mask, zexp, ' '.join('%08x' % v for v in z),
            ' '.join('%08x' % v for v in ds), ' '.join('%08x' % v for v in sd)))
    out.append('E')
    return out


RT_REG = 0x2000         # the targets' region in atg_rop_mrt_tb's memory
MRT_W, MRT_H = 8, 4     # pixels of each attachment


def mrt_fmts():
    import fmtmodel as F
    return sorted(v for v in F.FORMATS if F.features(v, False)[0] & F.F_COLOR)


def mrt_pixel(vk, bl, kc8, kcf, ctrl, wm, color, old):
    """atg_rop_wpix's new pixel (an integer of ps bytes) for one sample."""
    import fmtmodel as F
    fi = F.info(vk)
    ps = fi.nbytes
    allb = (1 << (8 * ps)) - 1
    if vk in (44, 37, 51, 4, 9, 16, 8):
        kc = sum(M.f2u8(kcf[c]) << (8 * c) for c in range(4)) if ctrl & 2 else kc8
        return M.blend_pixel8(vk, bl, kc, wm, color, old) & allb
    if vk in M.FBLEND_FMTS:
        k = kcf if ctrl & 2 else [M.UNORM8[(kc8 >> (8 * c)) & 255] for c in range(4)]
        raw, keep = M.fblend_lane(vk, bl, k, wm, color, old)
    else:
        raw, keep = F.pack(color, vk, wm)
    return ((raw & ~keep) | (old & keep)) & allb


def mrt_lines(r):
    """rop_mrt.txt (the comment at the top)."""
    import fmtmodel as F
    cfmts = mrt_fmts()
    out = []
    for run in range(72):
        ms4 = run % 2
        S = 4 if ms4 else 1
        fmt0 = r.randrange(3)
        fmts = []
        for k in range(4):
            c = r.random()
            if k == 0 and c < 0.15:
                fmts.append(0)
            elif k > 0 and c < 0.15:
                fmts.append(0)
            elif c < 0.35:
                fmts.append(r.choice([97, 109, 103, 83, 64, 43, 50]))
            else:
                fmts.append(r.choice(cfmts))
        evk = [fmts[0] or [44, 37, 4][fmt0]] + fmts[1:]
        bls = [(r.getrandbits(23) | 1) if r.random() < 0.6 else 0 for _ in range(4)]
        wms = r.getrandbits(16) if run % 3 == 0 else 0xFFFF
        kc8 = r.getrandbits(32)
        kcf = [r.choice([f(r.uniform(-0.2, 1.2)), M.ONE, M.UNORM8[r.randrange(256)]])
               for _ in range(4)]
        ctrl = r.getrandbits(1) << 1
        bases, strides = [], []
        a = RT_REG
        for k in range(4):
            ps = F.info(evk[k]).nbytes if evk[k] else 4
            unit = 2 * S * ps
            st = MRT_W * S * ps + unit * r.randrange(3)
            bases.append(a)
            strides.append(st)
            a += (MRT_H * st + 63) // 64 * 64 + 64 * r.randrange(2)
        nw = (a - RT_REG) // 4
        mem = bytearray(r.getrandbits(8) for _ in range(4 * nw))
        out.append('R %d %x %08x %06x %06x %06x %06x %08x %08x %08x %08x %08x %x %04x %s %s %x' % (
            ms4, ctrl, fmts[0] | fmts[1] << 8 | fmts[2] << 16 | fmts[3] << 24, bls[0], bls[1],
            bls[2], bls[3], kc8, kcf[0], kcf[1], kcf[2], kcf[3], fmt0, wms,
            ' '.join('%08x' % b for b in bases), ' '.join('%08x' % s for s in strides), nw))
        out.append('M ' + ' '.join('%08x' % int.from_bytes(mem[4 * i:4 * i + 4], 'little')
                                   for i in range(nw)))
        for q in range(24):
            x, y = 2 * r.randrange(MRT_W // 2), 2 * r.randrange(MRT_H // 2)
            smask = r.getrandbits(16) if ms4 else sum(r.getrandbits(1) << (4 * l)
                                                       for l in range(4))
            if not smask:
                smask = 1
            rts = [k for k in range(4) if r.random() < 0.6] if q % 7 else []
            beats = rts if rts else [None]
            for rt in beats:
                color = [rnd_src(r) if r.random() < 0.7 else
                         [r.getrandbits(32) for _ in range(4)] for _ in range(4)]
                out.append('B %x %x %d %d %04x %s' % (
                    x, y, rt or 0, 1 if rt is None else 0, smask,
                    ' '.join('%08x' % w for px in color for w in px)))
                if rt is None or not evk[rt]:
                    continue
                vk = evk[rt]
                fi = F.info(vk)
                ps = fi.nbytes
                if not F.features(vk, False)[0] & F.F_COLOR:
                    continue
                wm = (wms >> (4 * rt)) & 15
                if not wm & ((1 << len(fi.chans)) - 1):
                    continue
                for ln in range(4):
                    for smp in range(S):
                        if not smask >> (4 * ln + smp) & 1:
                            continue
                        px, py = x + (ln & 1), y + (ln >> 1)
                        o = bases[rt] - RT_REG + py * strides[rt] + (S * px + smp) * ps
                        old = int.from_bytes(mem[o:o + ps], 'little')
                        new = mrt_pixel(vk, bls[rt], kc8, kcf, ctrl, wm, color[ln], old)
                        mem[o:o + ps] = new.to_bytes(ps, 'little')
        out.append('F ' + ' '.join('%08x' % int.from_bytes(mem[4 * i:4 * i + 4], 'little')
                                   for i in range(nw)))
    out.append('E')
    return out


def main():
    r = random.Random(288035)
    with open(os.path.join(VEC, 'rop_blend2.txt'), 'w') as fp:
        fp.write('\n'.join(blend2_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_fblend.txt'), 'w') as fp:
        fp.write('\n'.join(fblend_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_dtest.txt'), 'w') as fp:
        fp.write('\n'.join(dtest_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_ds2.txt'), 'w') as fp:
        fp.write('\n'.join(ds2_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_msz.txt'), 'w') as fp:
        fp.write('\n'.join(msz_lines(r)) + '\n')
    with open(os.path.join(VEC, 'rop_mrt.txt'), 'w') as fp:
        fp.write('\n'.join(mrt_lines(r)) + '\n')
    print('rop-vectors: rop_blend2.txt, rop_fblend.txt, rop_dtest.txt, rop_ds2.txt, rop_msz.txt,'
          ' rop_mrt.txt')


if __name__ == '__main__':
    main()
