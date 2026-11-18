#!/usr/bin/env python3
# gsi1model.py: a reference model of GSI1 (design §3) for the SU testbenches.
# It runs a compute dispatch, workgroup by workgroup, each workgroup's warps
# (32 lanes each) one after the other until a bar or end (a bar releases when
# every warp that has not ended waits at it).  Units: the integer ALU, the FPU,
# the packed unit, the transcendental unit and the divider (bit-exact through
# tools/gsi1fp.py), lw/sw/atom/fence, lds/sts/atoms, lwc and the c operands, exec.*,
# kill, the branches, end, bar, wait and nop, and the lane unit (qd; shfl,
# vote and ballot with --subgroup).  Texture stops the model with an error,
# and lda without --prims; exp and lda only in --warps mode.  Programs must be free of races between
# warps (the model is sequentially consistent per warp).
#
#   gsi1model.py PROG.s --lanes N [--groups G] [--nregs 32] [--packed]
#                [--subgroup] [--data DATA.hex] -o PROG.exp [--mem-out PROG.mexp]
#                [--fault-out PROG.fault]
#   gsi1model.py PROG.s --warps W.hex --init I.hex [--nregs 32] [--vary 16] [...]
#                -o PROG.exp [--mem-out PROG.mexp] [--exp-out PROG.xexp]
#                [--pt-out PROG.pexp] [--ms-out PROG.msexp]
#
# --warps: graphics warps instead of a dispatch (sim/tb/atg_su_gfx_tb.v).
# W.hex has 5 words per slot 0..3: kind (0 vertex, 1 fragment, 2 none),
# the initial EXEC, the mask (operand 119: the coverage of a fragment warp,
# the valid vertices of a vertex warp), the sequence number and the front
# bit; I.hex (the -o format) holds the registers the VF or RX writes before
# the start.  wgx/nwgx are 0 and lidn is the lane (atg_su_sched's warp
# word).  The warps run one after the other in slot order.  Side effects
# (sw, atom, atoms, sts, exp) take the lanes in EXEC, in the mask and not KILLED
# (design §3.1, M10); sw.x takes every EXEC lane.  exp of a fragment
# warp: targets 0x100 + 16 k + c (colour attachment k, component c), 0x104 (DEPTH) and 0x105 (SAMPLE_MASK,
# docs/ghci.md section 12.11: the last value written, bits 3:0); a lane is
# exported once one of them ran for it.  The lane's sample mask is r6 as written before the start (the
# rasterizer's sample mask; 15 when the init file leaves r6 unset) ANDed
# with the last SAMPLE_MASK value.
# --exp-out: the beats the ROP gets (atg_su_exp), fragment warps in
# sequence order, the quads with coverage (packed from lane 0) in order,
# per quad one beat per colour attachment the warp exported (ascending), or
# one beat without colour: the number of beats, then per beat 22 words:
# {seq[15:0], 1'd0, rt[1:0], qlast, qfirst, nocol, 1'd0, last, 4'd0,
# mask[3:0]} with mask = covered and exported lanes whose sample mask is
# not 0 and last = the warp's last beat, {y, x} = floor of r4 and r5 of the
# quad's lane 0, and per lane 0..3 attachment rt's RGBA and the depth
# (exported, else r3 as written before the start; 0 for a lane not in
# mask).  exp of a vertex warp: targets 0x000-0x003 (PT words
# 0-3) and 0x010+v, v < --vary (PT word 4+v).  --ms-out: the same beats,
# one word each: {12'd0, zexp[3:0], smask[15:0]} (zexp: the lane exported
# DEPTH; smask bit 4 l + s: the sample mask of lane l, 0 for a lane not in
# mask).  --pt-out: for the one
# vertex warp, entry (lane) 0..31, word 0..3+VARY, the -o line format.
#
# The lane unit: qdx/qdy = v[lane|1] - v[lane&~1], v[lane|2] - v[lane&~2]
# (fp32, RNE), qswap1/2/3 = v[lane^1/2/3], qbcast = v[lane&~3] (partner
# lanes regardless of EXEC).  shfl: the source lane s of lane l is rs2 (idx),
# l ^ rs2 (xor), l - rs2 (up), l + rs2 (down), as integers without
# wraparound, or (l + rs2) mod 32 (rot); the result is rs1 of lane s when s is 0..31 and in EXEC, else
# the lane's own rs1; EXEC lanes are written.  ballot: the mask of the EXEC
# lanes whose rs1 is not 0; vote.any/all: whether that mask is not 0 / equals
# EXEC, as a Boolean; both write every lane (as exec.save).
# --prims P.hex: the primitive table lda reads in --warps mode, one 32-bit
# word per line: slot 0..3, vertex 0..2, PT word 0..127 (word 4 + w is
# varying word w, as atg_rx_frag copies it); lda (PT word imm[8:2], vertex
# imm[1:0]) of vertex 3, of PT words 0-3 (the position, not in the table)
# or past 4 + --vary reads 0.  Without --prims, lda stops the model with an
# error.
# --fault-out: an ISA fault is not an error; the file gets one line per
# faulting warp, "slot pc" in hex, and the warp stops.
# --scratch ADDR,BYTES: a program's scratch memory (docs/ghci.md section
# 12.10, kind 14) of BYTES bytes per warp at ADDR: every lw and sw from
# ADDR up to 64 warps' parts must be in the part of the warp that makes
# it, ADDR + slot x BYTES (the `warp` operand), or the model stops.
#
# Memory: DATA.hex (one 32-bit word per line) is the data image at DATA_BASE
# (0x8000, 4096 words); everything else reads 0.  The constant bank holds the
# image's first 256 words (the testbench's LOAD_CONST).  --mem-out writes the
# image after the dispatch, one word per line.
# Output: for slot 0..3, register 0..NREGS-1, lane 0..31 (slot-major), one
# line of 9 hex digits: 1 and the value when the program wrote that lane's
# register, 000000000 otherwise (sim/tb/atg_su_tb.v $readmemh's it).  With
# --groups above 1 nothing is checked in the registers (all lines 0).
# Warp k of a workgroup runs in slot k; lidn = 32 k + lane; EXEC starts with
# the lanes below the workgroup size; wgx is the workgroup's number.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402
import gsi1fp as FP  # noqa: E402

M32 = 0xFFFFFFFF
DATA_BASE = 0x8000
DATA_WORDS = 4096
CONST_WORDS = 256
LDS_WORDS = 1024


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def alu(op, a, b, c, imm):
    if op == 0: return a + b
    if op == 1: return a - b
    if op == 2: return a << (b & 31)
    if op == 3: return M32 if s32(a) < s32(b) else 0
    if op == 4: return M32 if a < b else 0
    if op == 5: return a ^ b
    if op == 6: return a >> (b & 31)
    if op == 7: return s32(a) >> (b & 31)
    if op == 8: return a | b
    if op == 9: return a & b
    if op == 10: return a if s32(a) < s32(b) else b
    if op == 11: return b if s32(a) < s32(b) else a
    if op == 12: return a if a < b else b
    if op == 13: return b if a < b else a
    if op == 14: return a & ~b
    if op == 15: return a | ~b
    if op == 16: return ~(a ^ b)
    if op == 17: return (a & b) | (~a & c)
    if op == 18: return imm
    raise ValueError("alu op %d" % op)


def atom(op, old, a, b):
    """The atomic operations, IR order (and or xor xchg add sub smax smin umax
    umin cmpxchg); b is cmpxchg's compare value."""
    if op == 0: return old & a
    if op == 1: return old | a
    if op == 2: return old ^ a
    if op == 3: return a
    if op == 4: return (old + a) & M32
    if op == 5: return (old - a) & M32
    if op == 6: return old if s32(old) > s32(a) else a
    if op == 7: return old if s32(old) < s32(a) else a
    if op == 8: return old if old > a else a
    if op == 9: return old if old < a else a
    return a if old == b else old


def fmod(v, neg, ab, unit):
    """The float modifiers of atg_su_opd: abs, then negate."""
    if unit in (A.U_FPU, A.U_XU):
        if ab:
            v &= 0x7FFFFFFF
        if neg:
            v ^= 0x80000000
    elif unit == A.U_PK:
        if ab:
            v &= 0x7FFF7FFF
        if neg:
            v ^= 0x80008000
    return v


class Machine:
    def __init__(self, words, lanes, nregs, mem, groups, packed, subgroup=False,
                 faults=None, gw=None, vary=16):
        self.words, self.lanes, self.nregs, self.groups = words, lanes, nregs, groups
        self.cfg = dict(NREGS=nregs, PACKED=int(packed), SUBGROUP=int(subgroup), HAS_SA=0)
        self.faults = faults
        self.mem = mem
        self.cbank = [mem.get(DATA_BASE // 4 + i, 0) for i in range(CONST_WORDS)]
        self.lds = [0] * LDS_WORDS
        self.regs = [[[None] * 32 for _ in range(nregs)] for _ in range(4)]
        self.gw = gw            # graphics warps (--warps), else None
        self.vary = vary
        self.xexp = {}          # slot -> (colour[lane][4], depth[lane], exported mask)
        self.pt = [[None] * (4 + vary) for _ in range(32)]
        self.prims = None       # --prims: [slot][vertex][word], words of the primitive table
        self.scratch = None     # --scratch: (address, bytes per warp)

    def check_scratch(self, k, addr):
        """Stops the model when warp k reaches another warp's scratch memory."""
        if self.scratch is None:
            return
        base, size = self.scratch
        addr &= M32 & ~3
        if base <= addr < base + 64 * size and not base + k * size <= addr < base + (k + 1) * size:
            raise SystemExit("gsi1model: warp %d reaches scratch address 0x%x outside its part "
                             "[0x%x, 0x%x)" % (k, addr, base + k * size, base + (k + 1) * size))

    def rd32(self, addr):
        return self.mem.get((addr & M32) >> 2, 0)

    def wr32(self, addr, v):
        self.mem[(addr & M32) >> 2] = v & M32

    def warp(self, k, wg, max_steps=200000):
        """Runs warp k of workgroup wg; yields at each bar."""
        g = self.gw[k] if self.gw is not None else None
        if g is None:
            exec_m = M32 if self.lanes - 32 * k >= 32 else (1 << (self.lanes - 32 * k)) - 1
            exec_init = exec_m
        else:
            exec_m, exec_init = g["exec"], g["mask"]
            col = [[0] * 16 for _ in range(32)]
            rtw = [0]
            dep = [None] * 32
            xp = 0
            smv = [None] * 32
        killed = 0
        pc = 0
        r = self.regs[k] if self.groups == 1 else [[None] * 32 for _ in range(self.nregs)]
        steps = 0

        def opv(n, lane):
            if n < 63:
                return r[n][lane]      # None: never written (X in the RF)
            if 64 <= n < 96:
                return self.cbank[n - 64]
            sp = {96: 0, 97: 0x3F800000, 98: 1, 99: 0x3F000000, 100: 0x40000000,
                  101: 0xBF800000, 102: lane, 103: k, 104: exec_m,
                  105: M32 if killed >> lane & 1 else 0, 106: wg, 107: 0, 108: 0,
                  109: 32 * k + lane, 110: 0, 111: 0, 112: 32 * k + lane, 113: 0, 114: 0,
                  115: self.groups, 116: 1, 117: 1, 118: 0x3C003C00,
                  119: exec_init}
            if g is not None:
                sp.update({106: 0, 109: lane, 112: lane, 114: M32 if g["front"] else 0,
                           115: 0, 116: 0, 117: 0})
            return sp.get(n, 0)

        while True:
            steps += 1
            if steps > max_steps:
                raise SystemExit("gsi1model: warp %d does not end" % k)
            u = A.decode(self.words[pc], self.cfg)
            f = {n: (u >> lo) & ((1 << nb) - 1) for n, (lo, nb) in A.F.items()}
            if f["ILL"]:
                if self.faults is None:
                    raise SystemExit("gsi1model: ISA fault at pc %d" % pc)
                self.faults.append((k, pc))
                return
            unit, op = f["UNIT"], f["OP"]
            imm = f["IMM"]
            n1, n2, n3, rd = f["RS1"], f["RS2"], f["RS3"], f["RD"]
            mod = f["MOD"]
            side = exec_m & exec_init & ~killed & M32
            npc = pc + 1

            def src(n, use, i, ln):
                if not use:
                    return 0
                v = opv(n, ln)
                if v is None:
                    raise SystemExit("gsi1model: warp %d pc %d lane %d reads an unwritten "
                                     "register r%d" % (k, pc, ln, n))
                return fmod(v, mod >> (2 * i) & 1, mod >> (2 * i + 1) & 1, unit)

            def operands(ln):
                return (src(n1, f["USE1"], 0, ln), src(n2, f["USE2"], 1, ln),
                        src(n1 + 1 if f["PAIR"] else n3, f["USE3"], 2, ln))

            def write(lanes_m, fn):
                res = {}
                for ln in range(32):
                    if lanes_m >> ln & 1:
                        res[ln] = fn(*operands(ln)) & M32
                if f["WRD"]:
                    for ln, v in res.items():
                        r[rd][ln] = v

            if unit == A.U_ALU:
                write(exec_m, lambda a, b, c: alu(op & 0x1F, a, imm if op & 0x80 else b, c, imm))
            elif unit == A.U_FPU:
                write(exec_m, lambda a, b, c: FP.fpu(op, a, b, c, f["RM"], mod >> 6 & 1))
            elif unit == A.U_PK:
                write(exec_m, lambda a, b, c: FP.pk(op, a, b, c, f["RM"], f["HSEL"], f["SUB"],
                                                    mod >> 6 & 1))
            elif unit == A.U_XU:
                write(exec_m, lambda a, b, c: FP.xu(op, a))
            elif unit == A.U_DIV:
                write(exec_m, lambda a, b, c: FP.div(op, a, b))
            elif unit == A.U_LSU:
                if op == 0:         # lw
                    for ln in range(32):
                        if exec_m >> ln & 1:
                            self.check_scratch(k, operands(ln)[0] + imm)
                    write(exec_m, lambda a, b, c: self.rd32(a + imm))
                elif op == 1:       # sw: lanes in order, the higher lane wins
                    # sw.x (sub 1, scratch memory): every EXEC lane, helper
                    # and killed lanes too.
                    lanes_m = exec_m if f["SUB"] & 1 else side
                    for ln in range(32):
                        if lanes_m >> ln & 1:
                            a, b, c = operands(ln)
                            self.check_scratch(k, a + imm)
                            self.wr32(a + imm, b)
                elif op == 2:       # atom: lanes in order
                    olds = {}
                    for ln in range(32):
                        if side >> ln & 1:
                            a, b, c = operands(ln)
                            old = self.rd32(a)
                            self.wr32(a, atom(f["SUB"], old, b, c))
                            olds[ln] = old
                    if f["WRD"]:
                        for ln, v in olds.items():
                            r[rd][ln] = v
                # fence: nothing to do in a sequentially consistent model
            elif unit == A.U_LDS:
                if op == 0:
                    write(exec_m, lambda a, b, c: self.lds[((a + imm) & M32) >> 2 &
                                                           (LDS_WORDS - 1)])
                elif op == 2:       # atoms: lanes in order, no immediate
                    olds = {}
                    for ln in range(32):
                        if side >> ln & 1:
                            a, b, c = operands(ln)
                            w = (a & M32) >> 2 & (LDS_WORDS - 1)
                            olds[ln] = self.lds[w]
                            self.lds[w] = atom(f["SUB"] & 15, olds[ln], b, c) & M32
                    if f["WRD"]:
                        for ln, v in olds.items():
                            r[rd][ln] = v
                else:
                    for ln in range(32):
                        if side >> ln & 1:
                            a, b, c = operands(ln)
                            self.lds[((a + imm) & M32) >> 2 & (LDS_WORDS - 1)] = b
            elif unit == A.U_CBANK:
                write(exec_m, lambda a, b, c: self.cbank[(a + imm) & (CONST_WORDS - 1)])
            elif unit == A.U_EXEC:
                bt = 0
                if f["USE1"]:
                    # A lane outside EXEC may be unwritten; exec.set/or read
                    # every lane, the others only the EXEC lanes.
                    need = M32 if op in (8, 10) else exec_m
                    for ln in range(32):
                        v = opv(n1, ln)
                        if v is None:
                            if need >> ln & 1:
                                raise SystemExit("gsi1model: warp %d pc %d lane %d: Boolean "
                                                 "of an unwritten register" % (k, pc, ln))
                            continue
                        if v:
                            bt |= 1 << ln
                if op <= 5:
                    tk = [bt & exec_m != 0, bt & exec_m == 0, ~bt & exec_m & M32 == 0, True,
                          exec_m != 0, exec_m == 0][op]
                    if tk:
                        npc = (pc + s32(imm)) & 0xFFFF
                elif op == 8:
                    exec_m = bt
                elif op == 9:
                    exec_m &= bt
                elif op == 10:
                    exec_m |= bt
                elif op == 11:
                    for ln in range(32):
                        r[rd][ln] = M32 if exec_m >> ln & 1 else 0
                elif op == 12:
                    killed |= bt & exec_m
                elif op == 13:
                    if g is not None and g["kind"] == 1:
                        self.xexp[k] = (col, dep, xp, smv, rtw[0])
                    return
                elif op == 14:
                    yield pc
                else:
                    raise SystemExit("gsi1model: exec op %d" % op)
            elif unit == A.U_LANE:
                self.lane(f, exec_m, r, src)
            elif unit == A.U_LDA and g is not None and self.prims is not None:
                vtx, wd = imm & 3, (imm >> 2) & 127
                v = self.prims[k][vtx][wd] if vtx < 3 and 4 <= wd < 4 + self.vary else 0
                write(exec_m, lambda a, b, c: v)
            elif unit == A.U_EXP and g is not None:
                t = imm & 0xFFF
                for ln in range(32):
                    if not side >> ln & 1:
                        continue
                    a, b, c = operands(ln)
                    if g["kind"] == 1 and (t in (0x104, 0x105) or
                                           (t >> 6 == 4 and not t & 12)):
                        if t == 0x104:
                            dep[ln] = b
                        elif t == 0x105:
                            smv[ln] = b & 15
                        else:
                            col[ln][4 * (t >> 4 & 3) + (t & 3)] = b
                            rtw[0] |= 1 << (t >> 4 & 3)
                        xp |= 1 << ln
                    elif g["kind"] == 0 and t < 4:
                        self.pt[ln][t] = b
                    elif g["kind"] == 0 and 0x10 <= t < 0x10 + self.vary:
                        self.pt[ln][4 + t - 0x10] = b
            elif unit in (A.U_NONE, A.U_CTL):
                pass
            else:
                raise SystemExit("gsi1model: unit %d not in the model (pc %d)" % (unit, pc))
            pc = npc

    def lane(self, f, exec_m, r, src):
        """qd, shfl, vote and ballot (the comment at the top)."""
        op, sub, rd = f["OP"], f["SUB"], f["RD"]
        res = {}
        if op == 0:
            for ln in range(32):
                if exec_m >> ln & 1:
                    p, q = [(ln | 1, ln & ~1), (ln | 2, ln & ~2), (ln ^ 1, None),
                            (ln ^ 2, None), (ln ^ 3, None), (ln & ~3, None)][sub]
                    a = src(f["RS1"], 1, 0, p)
                    res[ln] = a if q is None else FP.fpu(1, a, src(f["RS1"], 1, 0, q), 0, 0)
        elif op == 1:
            for ln in range(32):
                if exec_m >> ln & 1:
                    b = src(f["RS2"], 1, 1, ln)
                    s = [b, ln ^ b, ln - b, ln + b, (ln + b) % 32][sub]
                    ok = 0 <= s < 32 and exec_m >> s & 1
                    res[ln] = src(f["RS1"], 1, 0, s if ok else ln)
        else:
            bal = 0
            for ln in range(32):
                if exec_m >> ln & 1 and src(f["RS1"], 1, 0, ln):
                    bal |= 1 << ln
            v = bal if op == 3 else M32 if (bal == exec_m if sub else bal != 0) else 0
            res = {ln: v for ln in range(32)}
        if f["WRD"]:
            for ln, v in res.items():
                r[rd][ln] = v & M32

    def run(self):
        if self.gw is not None:
            for k in range(4):
                if self.gw[k] is not None:
                    for _ in self.warp(k, 0):
                        raise SystemExit("gsi1model: bar in a graphics warp")
            return self.regs
        nw = (self.lanes + 31) // 32
        for wg in range(self.groups):
            live = [self.warp(k, wg) for k in range(nw)]
            while live:
                waiting = []
                for g in live:
                    try:
                        next(g)
                        waiting.append(g)
                    except StopIteration:
                        pass
                live = waiting
        return self.regs


def load_hex(path):
    with open(path) as f:
        return [int(ln, 16) for ln in f if ln.strip()]


def floor_f32(v):
    """floor of a non-negative fp32 value, as an integer (r4/r5 of the RX)."""
    return int(struct.unpack("<f", struct.pack("<I", v & M32))[0])


def write_exports(path, m, gw, init, ms_path=None):
    """--exp-out and --ms-out (the comment at the top)."""
    out = []
    msw = []
    frags = sorted((g["seq"], k) for k, g in enumerate(gw) if g is not None and g["kind"] == 1)
    for seq, k in frags:
        col, dep, xp, smv, rtw = m.xexp[k]
        rts = [i for i in range(4) if rtw >> i & 1]
        cov = gw[k]["mask"]

        def smask(ln):
            r6 = init[k][6][ln] if len(init[k]) > 6 else None
            v = 15 if r6 is None else r6 & 15
            return v & (15 if smv[ln] is None else smv[ln])
        nq = 0
        while nq < 8 and cov >> (4 * nq) & 15:
            nq += 1
        for q in range(nq):
            mask = cov >> (4 * q) & xp >> (4 * q) & 15
            mask &= sum(1 << i for i in range(4) if smask(4 * q + i))
            sm = sum(smask(4 * q + i) << (4 * i) for i in range(4) if mask >> i & 1)
            ze = sum(1 << i for i in range(4) if mask >> i & 1 and dep[4 * q + i] is not None)
            x, y = floor_f32(init[k][4][4 * q]), floor_f32(init[k][5][4 * q])
            beats = rts if rts else [None]
            for bi, rt in enumerate(beats):
                qlast = 1 if bi == len(beats) - 1 else 0
                last = 1 if q == nq - 1 and qlast else 0
                msw.append(ze << 16 | sm)
                out.append(seq << 16 | (rt or 0) << 13 | qlast << 12 | (1 if bi == 0 else 0) << 11 |
                           (1 if rt is None else 0) << 10 | last << 8 | mask)
                out.append(y << 16 | x)
                for i in range(4):
                    ln = 4 * q + i
                    if mask >> i & 1:
                        d = dep[ln] if dep[ln] is not None else init[k][3][ln]
                        out += col[ln][4 * (rt or 0):4 * (rt or 0) + 4] + [d]
                    else:
                        out += [0] * 5
    with open(path, "w") as f:
        f.write("%08x\n" % (len(out) // 22))
        for v in out:
            f.write("%08x\n" % (v & M32))
    if ms_path:
        with open(ms_path, "w") as f:
            for v in msw:
                f.write("%08x\n" % v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--lanes", type=int, default=32)
    ap.add_argument("--groups", type=int, default=1)
    ap.add_argument("--nregs", type=int, default=32)
    ap.add_argument("--packed", action="store_true")
    ap.add_argument("--subgroup", action="store_true")
    ap.add_argument("--fault-out")
    ap.add_argument("--data")
    ap.add_argument("-o", dest="out", required=True)
    ap.add_argument("--mem-out")
    ap.add_argument("--warps")
    ap.add_argument("--init")
    ap.add_argument("--vary", type=int, default=16)
    ap.add_argument("--exp-out")
    ap.add_argument("--ms-out")
    ap.add_argument("--pt-out")
    ap.add_argument("--prims")
    ap.add_argument("--scratch")
    a = ap.parse_args()
    with open(a.src) as f:
        words = A.encode(f.read())
    mem = {}
    if a.data:
        for i, v in enumerate(load_hex(a.data)):
            mem[DATA_BASE // 4 + i] = v
    faults = [] if a.fault_out else None
    gw = None
    if a.warps:
        t = load_hex(a.warps)
        gw = [None if t[5 * k] == 2 else dict(kind=t[5 * k], exec=t[5 * k + 1],
                                              mask=t[5 * k + 2], seq=t[5 * k + 3],
                                              front=t[5 * k + 4]) for k in range(4)]
    m = Machine(words, a.lanes, a.nregs, mem, a.groups, a.packed, a.subgroup, faults, gw,
                a.vary)
    if a.scratch:
        base, size = a.scratch.split(",")
        m.scratch = (int(base, 0), int(size, 0))
    if a.prims:
        t = load_hex(a.prims)
        m.prims = [[[t[(k * 3 + v) * 128 + w] if (k * 3 + v) * 128 + w < len(t) else 0
                     for w in range(128)] for v in range(3)] for k in range(4)]
    if a.init:
        t = load_hex(a.init)
        for k in range(4):
            for n in range(a.nregs):
                for ln in range(32):
                    v = t[(k * a.nregs + n) * 32 + ln]
                    if v >> 32:
                        m.regs[k][n][ln] = v & M32
    init = [[list(rr) for rr in rk] for rk in m.regs]
    regs = m.run()
    if a.exp_out:
        write_exports(a.exp_out, m, gw, init, a.ms_out)
    if a.pt_out:
        with open(a.pt_out, "w") as f:
            for ln in range(32):
                for wd in range(4 + a.vary):
                    v = m.pt[ln][wd]
                    f.write("000000000\n" if v is None else "1%08x\n" % v)
    if a.fault_out:
        with open(a.fault_out, "w") as f:
            for k, pc in faults:
                f.write("%x %x\n" % (k, pc))
    with open(a.out, "w") as f:
        for k in range(4):
            for n in range(a.nregs):
                for ln in range(32):
                    v = regs[k][n][ln]
                    f.write("000000000\n" if v is None else "1%08x\n" % v)
    if a.mem_out:
        with open(a.mem_out, "w") as f:
            for i in range(DATA_WORDS):
                f.write("%08x\n" % m.mem.get(DATA_BASE // 4 + i, 0))


if __name__ == "__main__":
    main()
