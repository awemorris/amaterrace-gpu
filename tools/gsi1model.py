#!/usr/bin/env python3
# gsi1model.py: a reference model of GSI1 (design §3) for the SU testbenches.
# It runs one compute workgroup, warp by warp (32 lanes each), for the
# subset that p008's SU executes so far: the integer ALU (OP, OP-IMM, LUI/movi,
# sel), exec.*, kill, the branches, end, bar, wait and nop.  Other units stop
# the model with an error.
#
#   gsi1model.py PROG.s --lanes N [--nregs 32] -o PROG.exp
#
# Output: for slot 0..3, register 0..NREGS-1, lane 0..31 (slot-major), one
# line of 9 hex digits: 1 and the value when the program wrote that lane's
# register, 000000000 otherwise (sim/tb/atg_su_tb.v $readmemh's it).
# Warp k of the workgroup runs in slot k; lidn = 32 k + lane; EXEC starts with
# the lanes below the workgroup size.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402

M32 = 0xFFFFFFFF


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


def run(words, lanes, nregs, wg=(0, 0, 0), nwg=(1, 1, 1), max_steps=100000):
    nw = (lanes + 31) // 32
    regs = [[[None] * 32 for _ in range(nregs)] for _ in range(4)]
    for k in range(nw):
        exec_m = M32 if lanes - 32 * k >= 32 else (1 << (lanes - 32 * k)) - 1
        killed = 0
        pc = 0
        r = regs[k]

        def opv(n, lane):
            if n < 63:
                return r[n][lane]      # None: never written (X in the RF)
            if 64 <= n < 96:
                return 0            # the constant bank is a stub (zeros) in p008
            sp = {96: 0, 97: 0x3F800000, 98: 1, 99: 0x3F000000, 100: 0x40000000,
                  101: 0xBF800000, 102: lane, 103: k, 104: exec_m,
                  105: M32 if killed >> lane & 1 else 0, 106: wg[0], 107: wg[1], 108: wg[2],
                  109: 32 * k + lane, 110: 0, 111: 0, 112: 32 * k + lane, 113: 0, 114: 0,
                  115: nwg[0], 116: nwg[1], 117: nwg[2], 118: 0x3C003C00,
                  119: exec_init}
            return sp.get(n, 0)

        exec_init = exec_m
        steps = 0
        while True:
            steps += 1
            if steps > max_steps:
                raise SystemExit("gsi1model: warp %d does not end" % k)
            w = words[pc]
            u = A.decode(w, dict(NREGS=nregs, PACKED=0, SUBGROUP=0, HAS_SA=0))
            f = {n: (u >> lo) & ((1 << nb) - 1) for n, (lo, nb) in A.F.items()}
            if f["ILL"]:
                raise SystemExit("gsi1model: ISA fault at pc %d" % pc)
            unit, op = f["UNIT"], f["OP"]
            imm = f["IMM"]
            n1, n2, n3, rd = f["RS1"], f["RS2"], f["RS3"], f["RD"]
            npc = pc + 1
            if unit == A.U_ALU:
                res = [None] * 32
                for ln in range(32):
                    if not exec_m >> ln & 1:
                        continue
                    a = opv(n1, ln) if f["USE1"] else 0
                    b = imm if op & 0x80 else (opv(n2, ln) if f["USE2"] else 0)
                    c = opv(n3, ln) if f["USE3"] else 0
                    if a is None or b is None or c is None:
                        raise SystemExit("gsi1model: warp %d pc %d lane %d reads an unwritten "
                                         "register" % (k, pc, ln))
                    res[ln] = alu(op & 0x1F, a, b, c, imm) & M32
                for ln in range(32):
                    if exec_m >> ln & 1:
                        r[rd][ln] = res[ln]
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
                    break
                elif op == 14:
                    pass            # bar: warps are independent without shared memory
                else:
                    raise SystemExit("gsi1model: exec op %d" % op)
            elif unit in (A.U_NONE, A.U_CTL):
                pass
            else:
                raise SystemExit("gsi1model: unit %d not in the model (pc %d)" % (unit, pc))
            pc = npc
    return regs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--lanes", type=int, default=32)
    ap.add_argument("--nregs", type=int, default=32)
    ap.add_argument("-o", dest="out", required=True)
    a = ap.parse_args()
    with open(a.src) as f:
        words = A.encode(f.read())
    regs = run(words, a.lanes, a.nregs)
    with open(a.out, "w") as f:
        for k in range(4):
            for n in range(a.nregs):
                for ln in range(32):
                    v = regs[k][n][ln]
                    f.write("000000000\n" if v is None else "1%08x\n" % v)


if __name__ == "__main__":
    main()
