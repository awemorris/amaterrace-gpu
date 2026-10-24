#!/usr/bin/env python3
# gsi1model.py: a reference model of GSI1 (design §3) for the SU testbenches.
# It runs a compute dispatch, workgroup by workgroup, each workgroup's warps
# (32 lanes each) one after the other until a bar or end (a bar releases when
# every warp that has not ended waits at it).  Units: the integer ALU, the FPU,
# the packed unit, the transcendental unit and the divider (bit-exact through
# tools/gsi1fp.py), lw/sw/atom/fence, lds/sts, lwc and the c operands, exec.*,
# kill, the branches, end, bar, wait and nop, and the lane unit (qd; shfl,
# vote and ballot with --subgroup).  Texture, export and lda stop the model
# with an error.  Programs must be free of races between warps (the model is
# sequentially consistent per warp).
#
#   gsi1model.py PROG.s --lanes N [--groups G] [--nregs 32] [--packed]
#                [--subgroup] [--data DATA.hex] -o PROG.exp [--mem-out PROG.mexp]
#                [--fault-out PROG.fault]
#
# The lane unit: qdx/qdy = v[lane|1] - v[lane&~1], v[lane|2] - v[lane&~2]
# (fp32, RNE), qswap1/2/3 = v[lane^1/2/3], qbcast = v[lane&~3] (partner
# lanes regardless of EXEC).  shfl: the source lane s of lane l is rs2 (idx),
# l ^ rs2 (xor, bfly), l - rs2 (up), l + rs2 (down), as integers without
# wraparound; the result is rs1 of lane s when s is 0..31 and in EXEC, else
# the lane's own rs1; EXEC lanes are written.  ballot: the mask of the EXEC
# lanes whose rs1 is not 0; vote.any/all: whether that mask is not 0 / equals
# EXEC, as a Boolean; both write every lane (design M13, as exec.save).
# --fault-out: an ISA fault is not an error; the file gets one line per
# faulting warp, "slot pc" in hex, and the warp stops.
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
                 faults=None):
        self.words, self.lanes, self.nregs, self.groups = words, lanes, nregs, groups
        self.cfg = dict(NREGS=nregs, PACKED=int(packed), SUBGROUP=int(subgroup), HAS_SA=0)
        self.faults = faults
        self.mem = mem
        self.cbank = [mem.get(DATA_BASE // 4 + i, 0) for i in range(CONST_WORDS)]
        self.lds = [0] * LDS_WORDS
        self.regs = [[[None] * 32 for _ in range(nregs)] for _ in range(4)]

    def rd32(self, addr):
        return self.mem.get((addr & M32) >> 2, 0)

    def wr32(self, addr, v):
        self.mem[(addr & M32) >> 2] = v & M32

    def warp(self, k, wg, max_steps=200000):
        """Runs warp k of workgroup wg; yields at each bar."""
        exec_m = M32 if self.lanes - 32 * k >= 32 else (1 << (self.lanes - 32 * k)) - 1
        exec_init = exec_m
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
                    write(exec_m, lambda a, b, c: self.rd32(a + imm))
                elif op == 1:       # sw: lanes in order, the higher lane wins
                    for ln in range(32):
                        if side >> ln & 1:
                            a, b, c = operands(ln)
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
                    return
                elif op == 14:
                    yield pc
                else:
                    raise SystemExit("gsi1model: exec op %d" % op)
            elif unit == A.U_LANE:
                self.lane(f, exec_m, r, src)
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
                    s = [b, ln ^ b, ln - b, ln + b, ln ^ b][sub]
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
    a = ap.parse_args()
    with open(a.src) as f:
        words = A.encode(f.read())
    mem = {}
    if a.data:
        for i, v in enumerate(load_hex(a.data)):
            mem[DATA_BASE // 4 + i] = v
    faults = [] if a.fault_out else None
    m = Machine(words, a.lanes, a.nregs, mem, a.groups, a.packed, a.subgroup, faults)
    regs = m.run()
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
