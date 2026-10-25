#!/usr/bin/env python3
# gsi1asm.py: the GSI1 assembler (design §3.3, §3.4) and the reference
# decode table of the SU (the "ISA model" side of atg_su_dec's testbench).
#
#   gsi1asm.py SRC.s -o OUT.hex          one 32-bit word per line (word0, word1, ...),
#                                        for $readmemh; code only, no header
#   gsi1asm.py SRC.s -o OUT.bin --bin    the GHCI_PROGRAM binary (§3.4.4 header + code)
#   gsi1asm.py --dec-table OUT           the decode vectors of sim/tb/atg_su_dec_tb.v
#
# As a module: encode(text) -> list of 64-bit words, decode(word, cfg) -> uop.
# The op codes and uop field positions are those of include/atg_su_uop.vh.
# Syntax: one instruction per line, '#' or ';' comments, "label:" lines.
# Operands: r0-r62, rq, c0-c31, the special names of §3.2 (zero one onei half
# two mone lane warp exec killed wgx wgy wgz lidx lidy lidz lidn prim front
# nwgx nwgy nwgz oneh2 mask qstat sastat qtag), or o<n> for operand number n.
# Float sources take "-x", "|x|", "-|x|"; ".sat" on a float mnemonic saturates.
# Rounding: an optional last operand rne/rtz/rdn/rup/rmm/dyn (default rne; dyn
# is rm 7, which GSI1 runs as RNE).  Half select (word1[16:15], packed): a last
# mnemonic suffix .hlo (01, low half only), .hhi (10) or .hswap (11, rs2's
# halves swapped), after .sat.  ".inst 0x<64 bits>" puts a raw instruction
# (tools/gsi1dis.py writes it for words that have no other text).
# Atomics: atom.<op> on global memory, atoms.<op> on shared memory (sub[4]).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import random
import re
import sys

SPECIAL = ["zero", "one", "onei", "half", "two", "mone", "lane", "warp", "exec", "killed",
           "wgx", "wgy", "wgz", "lidx", "lidy", "lidz", "lidn", "prim", "front",
           "nwgx", "nwgy", "nwgz", "oneh2", "mask", "qstat", "sastat", "qtag"]
RM = {"rne": 0, "rtz": 1, "rdn": 2, "rup": 3, "rmm": 4, "dyn": 7}
HSEL = {"hlo": 1, "hhi": 2, "hswap": 3}
MAGIC = 0x47534931      # "GSI1", word 0 of a program binary

# Units, classes (include/atg_su_uop.vh).
U_NONE, U_ALU, U_FPU, U_PK, U_XU, U_DIV, U_LSU, U_LDS, U_CBANK, U_TEX, U_EXP, U_LDA, \
    U_LANE, U_EXEC, U_CTL, U_RQ = range(16)
C_A, C_F, C_M, C_T, C_X = range(5)
ALU_IMMB = 0x80

# Field positions of the uop.
F = dict(UNIT=(0, 4), OP=(4, 8), RD=(12, 7), RS1=(19, 7), RS2=(26, 7), RS3=(33, 7),
         IMM=(40, 32), MOD=(72, 7), HSEL=(79, 2), SUB=(81, 5), RM=(86, 3), CLS=(89, 3),
         NDST=(92, 3), USE1=(95, 1), USE2=(96, 1), USE3=(97, 1), WRD=(98, 1), PAIR=(99, 1),
         ILL=(100, 1), RQS=(101, 1), RQD=(102, 1), SIDE=(103, 1))
UOP_W = 104

OPC = dict(OP=0x33, OPIMM=0x13, LUI=0x37, LOAD=0x03, STORE=0x23, BRANCH=0x63, OPFP=0x53,
           MADD=0x43, MSUB=0x47, NMSUB=0x4B, NMADD=0x4F, C0=0x0B, C1=0x2B, C2=0x5B, C3=0x7B)

# The instruction table: mnemonic -> (format, opcode, funct3, funct7 (or rs2 / None),
# unit, op, class, operands).  Formats: R, R4, I, S, B, U.  The operand string lists
# the assembly operands: d rd, 1/2/3 sources, i immediate, m imm(rs1), a (rs1),
# l label, t sub (texture slot), x export target (S immediate; a number or
# color0.r-color3.a, 0x100 + 16 k + c).
T = {}


def ins(name, fmt, opc, f3, f7, unit, op, cls, ops, **kw):
    T[name] = dict(fmt=fmt, opc=opc, f3=f3, f7=f7, unit=unit, op=op, cls=cls, ops=ops, **kw)


for n, f3, f7, op in [("add", 0, 0, 0), ("sub", 0, 0x20, 1), ("sll", 1, 0, 2), ("slt", 2, 0, 3),
                      ("sltu", 3, 0, 4), ("xor", 4, 0, 5), ("srl", 5, 0, 6), ("sra", 5, 0x20, 7),
                      ("or", 6, 0, 8), ("and", 7, 0, 9), ("min", 4, 5, 10), ("max", 6, 5, 11),
                      ("minu", 5, 5, 12), ("maxu", 7, 5, 13), ("andn", 7, 0x20, 14),
                      ("orn", 6, 0x20, 15), ("xnor", 4, 0x20, 16)]:
    ins(n, "R", OPC["OP"], f3, f7, U_ALU, op, C_A, "d12")
for n, f3, op in [("mul", 0, 20), ("mulh", 1, 21), ("mulhsu", 2, 22), ("mulhu", 3, 23)]:
    ins(n, "R", OPC["OP"], f3, 1, U_FPU, op, C_F, "d12")
for n, f3, op in [("div", 4, 0), ("divu", 5, 1), ("rem", 6, 2), ("remu", 7, 3)]:
    ins(n, "R", OPC["OP"], f3, 1, U_DIV, op, C_X, "d12")
for n, f3, op in [("addi", 0, 0), ("slti", 2, 3), ("sltiu", 3, 4), ("xori", 4, 5),
                  ("ori", 6, 8), ("andi", 7, 9)]:
    ins(n, "I", OPC["OPIMM"], f3, None, U_ALU, op | ALU_IMMB, C_A, "d1i")
for n, f3, hi, op in [("slli", 1, 0, 2), ("srli", 5, 0, 6), ("srai", 5, 0x20, 7)]:
    ins(n, "I", OPC["OPIMM"], f3, hi, U_ALU, op | ALU_IMMB, C_A, "d1i", shift=True)
ins("lui", "U", OPC["LUI"], None, None, U_ALU, 18, C_A, "di")
ins("movi", "U", OPC["LUI"], None, None, U_ALU, 18, C_A, "di", movi=True)
ins("lw", "I", OPC["LOAD"], 2, None, U_LSU, 0, C_M, "dm")
ins("lwc", "I", OPC["LOAD"], 6, None, U_CBANK, 0, C_M, "dm")
ins("sw", "S", OPC["STORE"], 2, None, U_LSU, 1, C_M, "2m", side=True, subv=0)
# sw.x: the store of every EXEC lane, helper and killed lanes too (a warp's
# scratch memory, docs/ghci.md section 12.8); the uop's sub[0].
ins("sw.x", "S", OPC["STORE"], 2, None, U_LSU, 1, C_M, "2m", side=True, subv=1)
for n, f3, ops in [("bany", 0, "1l"), ("bnone", 1, "1l"), ("ball", 2, "1l"), ("j", 3, "l"),
                   ("bexnz", 4, "l"), ("bexz", 5, "l")]:
    ins(n, "B", OPC["BRANCH"], f3, None, U_EXEC, f3, C_A, ops)
for n, f7, op in [("fadd.s", 0x00, 0), ("fsub.s", 0x04, 1), ("fmul.s", 0x08, 2)]:
    ins(n, "R", OPC["OPFP"], "rm", f7, U_FPU, op, C_F, "d12", fp=True)
ins("fsgnj.s", "R", OPC["OPFP"], 0, 0x10, U_FPU, 7, C_F, "d12", fp=True)
ins("fmin.s", "R", OPC["OPFP"], 0, 0x14, U_FPU, 8, C_F, "d12", fp=True)
ins("fmax.s", "R", OPC["OPFP"], 1, 0x14, U_FPU, 9, C_F, "d12", fp=True)
ins("fsqrt.s", "R", OPC["OPFP"], "rm", 0x2C, U_XU, 6, C_X, "d1", fp=True, rs2=0)
ins("fcvt.w.s", "R", OPC["OPFP"], "rm", 0x60, U_FPU, 10, C_F, "d1", fp=True, rs2=0)
ins("fcvt.wu.s", "R", OPC["OPFP"], "rm", 0x60, U_FPU, 11, C_F, "d1", fp=True, rs2=1)
ins("fcvt.s.w", "R", OPC["OPFP"], "rm", 0x68, U_FPU, 12, C_F, "d1", fp=True, rs2=0)
ins("fcvt.s.wu", "R", OPC["OPFP"], "rm", 0x68, U_FPU, 13, C_F, "d1", fp=True, rs2=1)
for n, f3, op in [("feq.s", 2, 14), ("flt.s", 1, 15), ("fle.s", 0, 16), ("fne.s", 3, 17)]:
    ins(n, "R", OPC["OPFP"], f3, 0x50, U_FPU, op, C_F, "d12", fp=True)
ins("fround.s", "R", OPC["OPFP"], "rm4", 0x20, U_FPU, 18, C_F, "d1", fp=True, rs2=4)
for n, op in [("fmadd.s", 3), ("fmsub.s", 4), ("fnmsub.s", 5), ("fnmadd.s", 6)]:
    opc = {"fmadd.s": "MADD", "fmsub.s": "MSUB", "fnmsub.s": "NMSUB", "fnmadd.s": "NMADD"}[n]
    ins(n, "R4", OPC[opc], "rm", 0, U_FPU, op, C_F, "d123", fp=True)
ins("lds", "I", OPC["C0"], 0, None, U_LDS, 0, C_M, "dm")
ins("sts", "S", OPC["C0"], 1, None, U_LDS, 1, C_M, "2m", side=True)
ins("atom", "R4", OPC["C0"], 2, None, U_LSU, 2, C_M, "da2", side=True, sub="atom")
ins("fence", "I", OPC["C0"], 4, None, U_LSU, 3, C_A, "i")
ins("bar", "R", OPC["C0"], 5, 0, U_EXEC, 14, C_A, "")
ins("wait", "I", OPC["C0"], 6, None, U_CTL, 0, C_A, "w")
ins("end", "R", OPC["C0"], 7, 0, U_EXEC, 13, C_A, "")
# Texture (docs/ghci.md section 12.9).  The modifiers are in funct7 of texl and
# texb and become bits of the TEX op: [0] compare (.c: Dref in rs1+2, the uop's
# rs3, read in a second operand pass) -> op[2]; texl [1] gather (texg: the
# footprint's four texels, component funct7[3:2], no rs2) -> op[3], op[5:4];
# texb [4] the LOD query (texqlod, no rs2) -> op[6]; [5] the .3 forms (a third
# coordinate in rs1+2, Dref then in rs1+3; the uop's sub[4]).  texsz's
# immediate 1 (texsz.l) returns the level count -> op[6], 2 (texsz.d) the
# layer count or depth -> op[3], 3 (texsz.s, CAPS[29]) the sample count ->
# op[6] and op[3] together.  The R forms take a last operand
# off(du, dv[, dw]): the texel offsets, word1 [25:22], [29:26], [13:10]
# (signed 4 bits), the uop's imm[11:0] (du | dv << 4 | dw << 8).
for n, f3, f7, op, ops in [("texl", 0, 0, 0, "d12t"), ("texb", 1, 0, 1, "d12t"),
                           ("texf", 2, 0, 2, "d12t"), ("texl.c", 0, 1, 4, "d12t"),
                           ("texb.c", 1, 1, 5, "d12t"), ("texg.r", 0, 2, 8, "d1t"),
                           ("texg.g", 0, 6, 0x18, "d1t"), ("texg.b", 0, 10, 0x28, "d1t"),
                           ("texg.a", 0, 14, 0x38, "d1t"), ("texg.c", 0, 3, 0x0C, "d1t"),
                           ("texqlod", 1, 0x10, 0x41, "d1t")]:
    for three in (0, 1):
        base, _, rest = n.partition(".")
        nm = base + (".3" if three else "") + ("." + rest if rest else "")
        ins(nm, "R", OPC["C1"], f3, f7 | three << 5, U_TEX, op, C_T, ops, side=True, pair=True,
            ndst=4, cmp=bool(f7 & 1), three=bool(three))
ins("texsz", "I", OPC["C1"], 3, None, U_TEX, 3, C_T, "d1t", side=True, immv=0)
ins("texsz.l", "I", OPC["C1"], 3, None, U_TEX, 0x43, C_T, "dt", side=True, immv=1)
ins("texsz.d", "I", OPC["C1"], 3, None, U_TEX, 0x0B, C_T, "d1t", side=True, immv=2)
ins("texsz.s", "I", OPC["C1"], 3, None, U_TEX, 0x4B, C_T, "dt", side=True, immv=3, ms4=True)
ins("exp", "S", OPC["C1"], 4, None, U_EXP, 0, C_A, "2x", side=True)
ins("lda", "I", OPC["C1"], 5, None, U_LDA, 0, C_A, "di")
for n, s in [("qdx", 0), ("qdy", 1), ("qswap1", 2), ("qswap2", 3), ("qswap3", 4), ("qbcast", 5)]:
    ins(n, "R", OPC["C1"], 6, 0, U_LANE, 0, C_A, "d1", subv=s)
for n, s in [("shfl.idx", 0), ("shfl.xor", 1), ("shfl.up", 2), ("shfl.down", 3),
             ("shfl.rot", 4)]:
    ins(n, "R", OPC["C1"], 7, 0, U_LANE, 1, C_A, "d12", subv=s, subgroup=True)
for n, f3, f7, op in [("fadd2", 0, 0, 0), ("fsub2", 1, 0, 1), ("fmul2", 2, 0, 2),
                      ("fmin2", 4, 0, 4), ("fmax2", 4, 1, 5), ("iadd2", 5, 0, 6),
                      ("isub2", 5, 1, 7), ("imul2", 5, 2, 8), ("fcmp2.lt", 6, 0, 9),
                      ("fcmp2.ge", 6, 1, 10), ("fcmp2.eq", 6, 2, 11), ("fcmp2.ne", 6, 3, 12)]:
    ins(n, "R", OPC["C2"], f3, f7, U_PK, op, C_F, "d12", fp=True, packed=True)
ins("ffma2", "R4", OPC["C2"], 3, 0, U_PK, 3, C_F, "d123", fp=True, packed=True)
ins("packh", "R", OPC["C2"], 7, 0, U_PK, 13, C_F, "d12", fp=True)
ins("unpackh.lo", "R", OPC["C2"], 7, 1, U_PK, 14, C_F, "d1", fp=True, subv=0)
ins("unpackh.hi", "R", OPC["C2"], 7, 1, U_PK, 14, C_F, "d1", fp=True, subv=1)
ins("swaph", "R", OPC["C2"], 7, 2, U_PK, 15, C_F, "d1", packed=True)
ins("sel", "R4", OPC["C3"], 0, 0, U_ALU, 17, C_A, "d123")
for n, s, ops in [("exec.set", 0, "1"), ("exec.and", 1, "1"), ("exec.or", 2, "1"),
                  ("exec.save", 3, "d")]:
    ins(n, "R", OPC["C3"], 1, 0, U_EXEC, 8 + s, C_A, ops, subv=s)
ins("kill", "R", OPC["C3"], 2, 0, U_EXEC, 12, C_A, "1")
for n, s in [("rcp", 0), ("rsq", 1), ("exp2", 2), ("log2", 3), ("sin", 4), ("cos", 5)]:
    ins(n, "R", OPC["C3"], 3, 0, U_XU, s, C_X, "d1", fp=True, subv=s)
ins("fract", "R", OPC["C3"], 3, 0, U_FPU, 19, C_F, "d1", fp=True, subv=6)
ins("vote.any", "R", OPC["C3"], 4, 0, U_LANE, 2, C_A, "d1", subv=0, subgroup=True)
ins("vote.all", "R", OPC["C3"], 4, 0, U_LANE, 2, C_A, "d1", subv=1, subgroup=True)
ins("ballot", "R", OPC["C3"], 5, 0, U_LANE, 3, C_A, "d1", subgroup=True)
ins("sactl", "R", OPC["C3"], 6, 0, U_RQ, 0, C_A, "1t")
ins("nop", "R", OPC["C3"], 7, 0, U_NONE, 0, C_A, "", subv=0)

ATOMS = ["and", "or", "xor", "xchg", "add", "sub", "smax", "smin", "umax", "umin", "cmpxchg"]


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def bits(v, lo, n):
    return (v >> lo) & ((1 << n) - 1)


# ---------------------------------------------------------------------------
# Decode (the reference for atg_su_dec).  cfg = dict(NREGS, PACKED, SUBGROUP, HAS_SA).

def decode_fields(w):
    """The instruction's fields that do not depend on the opcode."""
    w0, w1 = w & 0xFFFFFFFF, w >> 32
    opc, rd5, f3, rs15, rs25, f7, rs35 = (bits(w0, 0, 7), bits(w0, 7, 5), bits(w0, 12, 3),
                                         bits(w0, 15, 5), bits(w0, 20, 5), bits(w0, 25, 7),
                                         bits(w0, 27, 5))
    return dict(w0=w0, w1=w1, opc=opc, f3=f3, f7=f7, rs2f=rs25,
                rd=rd5 | bits(w1, 0, 2) << 5, rs1=rs15 | bits(w1, 2, 2) << 5,
                rs2=rs25 | bits(w1, 4, 2) << 5, rs3=rs35 | bits(w1, 6, 2) << 5,
                mod=bits(w1, 8, 7), hsel=bits(w1, 15, 2), sub=bits(w1, 17, 5),
                hi=sext(bits(w1, 22, 10), 10))


def match(w):
    """The table entry of an instruction, or None (undefined)."""
    d = decode_fields(w)
    if d["w0"] & 3 != 3:
        return None, d
    for n, e in T.items():
        if e["opc"] != d["opc"]:
            continue
        if e["fmt"] != "U":
            f3 = e["f3"]
            if f3 == "rm":
                if d["f3"] in (5, 6):
                    continue
            elif f3 == "rm4":
                if d["f3"] > 3:
                    continue
            elif f3 != d["f3"]:
                continue
        if e["fmt"] == "R" and e["f7"] is not None and e["f7"] != d["f7"]:
            continue
        if e["fmt"] == "R4" and e["opc"] != OPC["C0"] and bits(d["w0"], 25, 2) != 0:
            continue
        if e.get("shift") and bits(d["w0"], 25, 7) != e["f7"]:
            continue
        if "rs2" in e and d["rs2f"] != e["rs2"]:
            continue
        if "immv" in e and bits(d["w0"], 20, 12) != e["immv"]:
            continue
        if "subv" in e and d["sub"] != e["subv"]:
            continue
        if e.get("movi"):
            continue        # movi is lui's alias
        return (n, e), d
    return None, d


def imm_of(e, d):
    w0 = d["w0"]
    if e["fmt"] == "I":
        return sext(bits(w0, 20, 12), 12) + (d["hi"] << 12)
    if e["fmt"] == "S":
        return sext(bits(w0, 25, 7) << 5 | bits(w0, 7, 5), 12) + (d["hi"] << 12)
    if e["fmt"] == "B":
        v = bits(w0, 31, 1) << 11 | bits(w0, 7, 1) << 10 | bits(w0, 25, 6) << 4 | bits(w0, 8, 4)
        return sext(v, 12) + (d["hi"] << 12)
    if e["fmt"] == "U":
        return (bits(w0, 12, 20) << 12) | bits(d["w1"], 2, 12)
    if e["unit"] == U_TEX:
        return tex_off(d["w1"])
    return 0


def tex_off(w1):
    """The texel offsets of a texture R form: du | dv << 4 | dw << 8."""
    return bits(w1, 22, 4) | bits(w1, 26, 4) << 4 | bits(w1, 10, 4) << 8


def uses(e, d):
    """(use1, use2, use3, wrd) of an entry."""
    ops = e["ops"]
    u1 = "1" in ops or "m" in ops or "a" in ops
    u2 = "2" in ops
    u3 = "3" in ops or (e.get("sub") == "atom" and d["sub"] & 15 == 10)
    return u1, u2, u3, "d" in ops


def decode(w, cfg):
    """The uop (an int of UOP_W bits) of a 64-bit instruction."""
    m, d = match(w)
    ill = m is None
    if not ill:
        n, e = m
        u1, u2, u3, wrd = uses(e, d)
        pair = bool(e.get("pair"))
        if e.get("cmp") or e.get("three"):
            # The third coordinate or Dref in rs1+2: the uop's rs3, range-checked
            # like the pair; .3 with Dref also rs1+3.
            d = dict(d, rs3=(d["rs1"] + 2) & 127)
            u3 = True
            k = 3 if e.get("cmp") and e.get("three") else 2
            if d["rs1"] < 64:
                if d["rs1"] + k >= min(cfg["NREGS"], 63):
                    ill = True
            elif d["rs1"] in (96 - k, 95, 94, 127, 126, 128 - k):
                ill = True
        if e.get("sub") == "atom":
            if d["sub"] & 15 > 10:
                ill = True
            if d["sub"] & 16:
                # The shared-memory form (atoms): the LDS unit.
                e = dict(e, unit=U_LDS)
        if e["unit"] == U_TEX and d["sub"] > 15:
            ill = True
        if e.get("packed") and not cfg["PACKED"]:
            ill = True
        if e.get("subgroup") and not cfg["SUBGROUP"]:
            ill = True
        if e.get("ms4") and not cfg["MS4"]:
            ill = True
        if e["unit"] == U_RQ and not cfg["HAS_SA"]:
            ill = True
        srcs = [s for s, u in ((d["rs1"], u1), (d["rs2"], u2), (d["rs3"], u3)) if u]
        if pair:
            if d["rs1"] < 64:
                if d["rs1"] + 1 >= min(cfg["NREGS"], 63):
                    ill = True
            elif d["rs1"] in (95, 127):
                ill = True
        rqs = any(s == 63 for s in srcs)
        for s in srcs:
            if s == 63:
                if not cfg["HAS_SA"]:
                    ill = True
            elif s < 64 and s >= cfg["NREGS"]:
                ill = True
        ndst = e.get("ndst", 1) if wrd else 0
        rqd = wrd and d["rd"] == 63
        if wrd:
            if d["rd"] >= 64:
                ill = True
            elif d["rd"] == 63:
                if not cfg["HAS_SA"] or e["cls"] != C_A or ndst != 1:
                    ill = True
            elif d["rd"] + ndst > cfg["NREGS"] or d["rd"] + ndst > 63:
                ill = True
    if ill:
        return 1 << F["ILL"][0]
    v = dict(UNIT=e["unit"], OP=e["op"], RD=d["rd"], RS1=d["rs1"], RS2=d["rs2"], RS3=d["rs3"],
             IMM=imm_of(e, d) & 0xFFFFFFFF, MOD=d["mod"], HSEL=d["hsel"],
             SUB=d["sub"] | (16 if e.get("three") else 0),
             RM=d["f3"] if e["fmt"] != "U" else 0, CLS=e["cls"], NDST=ndst, USE1=int(u1),
             USE2=int(u2), USE3=int(u3), WRD=int(wrd), PAIR=int(pair), ILL=0, RQS=int(rqs),
             RQD=int(rqd), SIDE=int(bool(e.get("side"))))
    if e["fmt"] == "U":
        v["RS1"] = v["RS2"] = v["RS3"] = 0
        v["MOD"] = v["HSEL"] = v["SUB"] = 0
    u = 0
    for k, (lo, nb) in F.items():
        u |= (v[k] & ((1 << nb) - 1)) << lo
    return u


# ---------------------------------------------------------------------------
# Assembler.

def reg_num(t):
    t = t.strip()
    if t == "rq":
        return 63
    if re.fullmatch(r"r\d+", t) and int(t[1:]) <= 62:
        return int(t[1:])
    if re.fullmatch(r"c\d+", t) and int(t[1:]) <= 31:
        return 64 + int(t[1:])
    if t in SPECIAL:
        return 96 + SPECIAL.index(t)
    if re.fullmatch(r"o\d+", t) and int(t[1:]) <= 127:
        return int(t[1:])
    raise ValueError("bad operand %r" % t)


def src_num(t):
    """A source with float modifiers: returns (number, neg, abs)."""
    t = t.strip()
    neg = t.startswith("-")
    if neg:
        t = t[1:].strip()
    ab = t.startswith("|") and t.endswith("|")
    if ab:
        t = t[1:-1]
    return reg_num(t), neg, ab


def num(t):
    return int(t.strip(), 0)


# Export targets by name (docs/ghci.md section 12.12): colourK.c is
# 0x100 + 16 K + c, K = 0-3, c = r, g, b, a.
EXP_NAMES = {"color%d.%s" % (k, ch): 0x100 + 16 * k + c
             for k in range(4) for c, ch in enumerate("rgba")}


def exp_target(t):
    t = t.strip()
    return EXP_NAMES[t] if t in EXP_NAMES else num(t)


def split_imm(v, bits_lo=12):
    lo = sext(v, bits_lo)
    hi = (v - lo) >> bits_lo
    if not -512 <= hi < 512:
        raise ValueError("immediate %d out of range" % v)
    return lo & 0xFFF, hi & 0x3FF


def assemble_one(mn, args, pc, labels):
    hsel = 0
    if mn.rpartition(".")[2] in HSEL:
        mn, _, hs = mn.rpartition(".")
        hsel = HSEL[hs]
    sat = False
    if mn.endswith(".sat"):
        sat, mn = True, mn[:-4]
    atom = None
    shared = mn.startswith("atoms.")
    if mn.startswith("atom.") or shared:
        atom, mn = mn.partition(".")[2], "atom"
    if mn not in T:
        raise ValueError("unknown mnemonic %r" % mn)
    e = T[mn]
    rm = 0
    if args and args[-1].strip() in RM and (e["f3"] in ("rm", "rm4")):
        rm = RM[args.pop().strip()]
    rd = rs1 = rs2 = rs3 = 0
    mods = 0
    imm = 0
    sub = e.get("subv", 0)
    toff = 0
    if e["unit"] == U_TEX and e["fmt"] == "R" and args and args[-1].strip().startswith("off("):
        t = args.pop().strip()
        if not t.endswith(")"):
            raise ValueError("bad offsets %r" % t)
        ds = [num(x) for x in t[4:-1].split(",")]
        if not 2 <= len(ds) <= 3 or any(not -8 <= x <= 7 for x in ds):
            raise ValueError("offsets %r: two or three in -8..7" % t)
        ds += [0] * (3 - len(ds))
        toff = (ds[0] & 15) << 22 | (ds[1] & 15) << 26 | (ds[2] & 15) << 10
    ai = 0
    ops = e["ops"]
    for o in ops:
        if ai >= len(args):
            raise ValueError("%s: too few operands" % mn)
        a = args[ai].strip()
        ai += 1
        if o == "d":
            rd = reg_num(a)
        elif o in "123":
            n, ng, ab = src_num(a)
            k = int(o) - 1
            mods |= (int(ng) | int(ab) << 1) << (2 * k)
            if o == "1":
                rs1 = n
            elif o == "2":
                rs2 = n
            else:
                rs3 = n
        elif o == "a":
            rs1 = reg_num(a.strip("()"))
        elif o == "x":
            imm = exp_target(a)
        elif o in "iw":
            imm = num(a)
        elif o == "m":
            mm = re.fullmatch(r"(.*)\((.*)\)", a)
            imm = num(mm.group(1)) if mm.group(1).strip() else 0
            rs1 = reg_num(mm.group(2))
        elif o == "l":
            imm = (labels[a] - pc) if a in labels else num(a)
        elif o == "t":
            sub = num(a)
    if mn == "atom":
        if atom not in ATOMS:
            raise ValueError("unknown atomic operation %r" % atom)
        sub = ATOMS.index(atom) | (16 if shared else 0)
        if atom == "cmpxchg":
            if ai >= len(args):
                raise ValueError("atom.cmpxchg: no compare value")
            rs3 = reg_num(args[ai].strip())
            ai += 1
    if mn == "wait":
        cm, ct, cx = (num(x) for x in args)
        imm = cm | ct << 4 | cx << 8
        ai = 3
    if ai != len(args):
        raise ValueError("%s: too many operands" % mn)
    if mn == "lda" and not 0 <= imm < 512:
        raise ValueError("lda: immediate %d: 4 x PT word (0-127) + vertex" % imm)
    if mods and not e.get("fp"):
        raise ValueError("%s: modifiers on an integer instruction" % mn)
    if sat and not e.get("fp"):
        raise ValueError("%s: .sat on an integer instruction" % mn)
    f3 = rm if e["f3"] in ("rm", "rm4") else (e["f3"] or 0)
    w1 = 0
    fmt = e["fmt"]
    if fmt == "U":
        if hsel or sat:
            raise ValueError("%s: no half select or .sat in the U form" % mn)
        if e.get("movi"):
            v = imm & 0xFFFFFFFF
            w0 = (v >> 12) << 12 | (rd & 31) << 7 | e["opc"]
            w1 = (rd >> 5) | (v & 0xFFF) << 2
        else:
            w0 = (imm & 0xFFFFF) << 12 | (rd & 31) << 7 | e["opc"]
            w1 = rd >> 5
        return w0 | w1 << 32
    w1 = (rd >> 5) | (rs1 >> 5) << 2 | (rs2 >> 5) << 4 | (rs3 >> 5) << 6 | mods << 8 | \
        int(sat) << 14 | hsel << 15 | (sub & 31) << 17 | toff
    if fmt == "R":
        r2 = e["rs2"] if "rs2" in e else rs2
        f7 = e["f7"] or 0
        w0 = f7 << 25 | (r2 & 31) << 20 | (rs1 & 31) << 15 | f3 << 12 | (rd & 31) << 7 | e["opc"]
    elif fmt == "R4":
        w0 = (rs3 & 31) << 27 | (rs2 & 31) << 20 | (rs1 & 31) << 15 | f3 << 12 | \
            (rd & 31) << 7 | e["opc"]
    elif fmt == "I":
        if "immv" in e:
            lo, hi = e["immv"], 0
        elif e.get("shift"):
            lo, hi = (imm & 31) | e["f7"] << 5, 0
        else:
            lo, hi = split_imm(imm)
        w0 = lo << 20 | (rs1 & 31) << 15 | f3 << 12 | (rd & 31) << 7 | e["opc"]
        w1 |= hi << 22
    elif fmt == "S":
        lo, hi = split_imm(imm)
        w0 = (lo >> 5) << 25 | (rs2 & 31) << 20 | (rs1 & 31) << 15 | f3 << 12 | \
            (lo & 31) << 7 | e["opc"]
        w1 |= hi << 22
    else:   # B: imm is an instruction count
        lo, hi = split_imm(imm)
        w0 = (lo >> 11 & 1) << 31 | (lo >> 4 & 63) << 25 | (rs1 & 31) << 15 | f3 << 12 | \
            (lo & 15) << 8 | (lo >> 10 & 1) << 7 | e["opc"]
        w1 |= hi << 22
    return w0 | w1 << 32


def tokenize(text):
    lines = []
    for ln in text.splitlines():
        ln = re.split(r"[#;]", ln)[0].strip()
        if ln:
            lines.append(ln)
    return lines


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
            continue
        depth += ch == "("
        depth -= ch == ")"
        cur += ch
    if cur.strip():
        out.append(cur)
    return out


def encode(text):
    labels, prog = {}, []
    for ln in tokenize(text):
        while ":" in ln:
            lab, ln = ln.split(":", 1)
            labels[lab.strip()] = len(prog)
            ln = ln.strip()
        if ln:
            prog.append(ln)
    words = []
    for pc, ln in enumerate(prog):
        mn, _, rest = ln.partition(" ")
        try:
            if mn.strip() == ".inst":
                words.append(num(rest) & ((1 << 64) - 1))
                continue
            words.append(assemble_one(mn.strip(), split_args(rest), pc, labels))
        except (ValueError, KeyError, AttributeError) as ex:
            raise SystemExit("gsi1asm: line %d %r: %s" % (pc, ln, ex))
    return words


def header(words, stage=2, nregs=32):
    h = [MAGIC, 1, stage, 0, 2 * len(words), 16, nregs, 0, 1, 0, 16, 0, 0, 1, 0, 0]
    return h


# ---------------------------------------------------------------------------
# The decode table for sim/tb/atg_su_dec_tb.v.

CFGS = [dict(NREGS=32, PACKED=0, SUBGROUP=0, HAS_SA=0, MS4=0),
        dict(NREGS=64, PACKED=1, SUBGROUP=1, HAS_SA=1, MS4=1)]


def dec_table(path, seed=1):
    rnd = random.Random(seed)
    vec = []
    # Every table entry with random fields, plus raw random words.
    for n, e in T.items():
        for _ in range(24):
            w0 = rnd.getrandbits(32)
            w0 = (w0 & ~0x7F) | e["opc"]
            if e["fmt"] != "U" and isinstance(e["f3"], int):
                w0 = (w0 & ~(7 << 12)) | e["f3"] << 12
            if e["fmt"] == "R" and e["f7"] is not None:
                w0 = (w0 & ~(0x7F << 25)) | e["f7"] << 25
            if e.get("shift"):
                w0 = (w0 & ~(0x7F << 25)) | e["f7"] << 25
            if "rs2" in e:
                w0 = (w0 & ~(31 << 20)) | e["rs2"] << 20
            if e["fmt"] == "R4" and rnd.random() < 0.8:
                w0 &= ~(3 << 25)
            w1 = rnd.getrandbits(32)
            if rnd.random() < 0.5:
                w1 &= ~0xFF          # low registers: mostly legal
            if "subv" in e and rnd.random() < 0.8:
                w1 = (w1 & ~(31 << 17)) | e["subv"] << 17
            if e.get("sub") == "atom" and rnd.random() < 0.8:
                # sub[4] (global or shared memory) stays random.
                w1 = (w1 & ~(15 << 17)) | rnd.randrange(11) << 17
            if e["unit"] == U_TEX and rnd.random() < 0.8:
                w1 &= ~(16 << 17)
            if e["unit"] == U_TEX and rnd.random() < 0.5:
                # rs1 at the ends of the GPRs, constants and specials (rs1+1..rs1+3)
                rs1 = rnd.choice([28, 29, 30, 31, 59, 60, 61, 62, 92, 93, 94, 95, 124, 125, 126,
                                  127, rnd.randrange(128)])
                w0 = (w0 & ~(31 << 15)) | (rs1 & 31) << 15
                w1 = (w1 & ~(3 << 2)) | (rs1 >> 5) << 2
            vec.append(w0 | w1 << 32)
    for _ in range(2000):
        vec.append(rnd.getrandbits(64))
    with open(path, "w") as f:
        for w in vec:
            f.write("%016x%026x%026x\n" % (w, decode(w, CFGS[0]), decode(w, CFGS[1])))
    return len(vec)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?")
    ap.add_argument("-o", dest="out")
    ap.add_argument("--bin", action="store_true")
    ap.add_argument("--dec-table")
    a = ap.parse_args()
    if a.dec_table:
        n = dec_table(a.dec_table)
        print("gsi1asm: %d decode vectors in %s" % (n, a.dec_table))
        return
    if not a.src or not a.out:
        ap.error("SRC and -o OUT are needed")
    with open(a.src) as f:
        words = encode(f.read())
    w32 = []
    for w in words:
        w32 += [w & 0xFFFFFFFF, w >> 32]
    if a.bin:
        w32 = header(words) + w32
        with open(a.out, "wb") as f:
            for x in w32:
                f.write(x.to_bytes(4, "little"))
    else:
        with open(a.out, "w") as f:
            for x in w32:
                f.write("%08x\n" % x)


if __name__ == "__main__":
    sys.exit(main())
