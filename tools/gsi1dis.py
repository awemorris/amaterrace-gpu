#!/usr/bin/env python3
# gsi1dis.py: the GSI1 disassembler.  It turns 64-bit instructions back into
# the assembly that tools/gsi1asm.py takes, from gsi1asm's own table (T, the
# operand names, decode_fields/match/imm_of): nothing of the ISA is kept here.
#
#   gsi1dis.py IN [-o OUT.s] [--hex | --bin] [--no-labels]
#
# Input: a $readmemh image (gsi1asm's .hex: one 32-bit word per line, word0
# then word1; a line of 16 hex digits is one 64-bit instruction; '//' and '#'
# comments and '@' address lines are skipped) or a binary (little endian; a
# GHCI_PROGRAM binary, §12.10 of docs/ghci.md, starts with the magic "GSI1":
# its header and interface table become comments and only the code is
# disassembled).  The format is guessed from the content unless --hex/--bin.
#
# Output: one instruction per line.  Branch targets inside the program get
# labels (L<index>:).  Every line is checked by assembling it again: a word
# that gsi1asm cannot produce from text (an ISA fault, a field the syntax has
# no place for) is written as ".inst 0x<64 bits>" with the reason in a
# comment, so that gsi1asm(gsi1dis(x)) == x for every x.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsi1asm as A  # noqa: E402

M64 = (1 << 64) - 1
RM_NAME = {v: k for k, v in A.RM.items()}
HSEL_NAME = {v: k for k, v in A.HSEL.items()}
ATOM_SUB = "atom"


def reg_name(n):
    """The assembler's name of operand number n (0-127)."""
    if n <= 62:
        return "r%d" % n
    if n == 63:
        return "rq"
    if n < 96:
        return "c%d" % (n - 64)
    if n - 96 < len(A.SPECIAL):
        return A.SPECIAL[n - 96]
    return "o%d" % n


def src_text(n, mods, k):
    t = reg_name(n)
    neg, ab = mods >> (2 * k) & 1, mods >> (2 * k + 1) & 1
    if ab:
        t = "|%s|" % t
    if neg:
        t = "-" + t
    return t


def num_text(v):
    return "%d" % v if -4096 < v < 4096 else ("-0x%x" % -v if v < 0 else "0x%x" % v)


def branch_targets(words):
    """Instruction indices that a branch of the program jumps to."""
    tg = set()
    for pc, w in enumerate(words):
        m, d = A.match(w)
        if m and "l" in m[1]["ops"]:
            t = pc + A.imm_of(m[1], d)
            if 0 <= t <= len(words):
                tg.add(t)
    return tg


def guess(w, pc, labels):
    """The assembly text of one instruction (not yet checked), or None."""
    m, d = A.match(w)
    if m is None:
        return None
    n, e = m
    mods = d["mod"] & 0x3F
    sat = d["mod"] >> 6 & 1
    tex_r = e["unit"] == A.U_TEX and e["fmt"] == "R"
    if tex_r:
        mods &= 3	# word1 [13:10] is the w offset of a texture R form
    if e["fmt"] == "U":
        v = A.bits(d["w0"], 12, 20) << 12 | A.bits(d["w1"], 2, 12)
        return "movi %s, %s" % (reg_name(d["rd"]), num_text(A.sext(v, 32)))
    mn = n
    if mn == "atom":
        if d["sub"] & 15 >= len(A.ATOMS):
            return None
        mn = ("atoms." if d["sub"] & 16 else "atom.") + A.ATOMS[d["sub"] & 15]
    cmpxchg = mn.endswith(".cmpxchg")
    if sat:
        mn += ".sat"
    if d["hsel"]:
        mn += "." + HSEL_NAME[d["hsel"]]
    imm = A.imm_of(e, d)
    args = []
    for o in e["ops"]:
        if o == "d":
            args.append(reg_name(d["rd"]))
        elif o in "123":
            k = int(o) - 1
            args.append(src_text(d[("rs1", "rs2", "rs3")[k]], mods, k))
        elif o == "a":
            args.append("(%s)" % reg_name(d["rs1"]))
        elif o == "m":
            args.append("%s(%s)" % (num_text(imm), reg_name(d["rs1"])))
        elif o in "ix":
            if e.get("shift"):
                imm &= 31
            args.append(num_text(imm))
        elif o == "w":
            args += ["%d" % (imm >> s & 15) for s in (0, 4, 8)]
        elif o == "l":
            t = pc + imm
            args.append(labels[t] if t in labels else num_text(imm))
        elif o == "t":
            args.append("%d" % d["sub"])
    if cmpxchg:
        args.append(reg_name(d["rs3"]))
    if tex_r and A.tex_off(d["w1"]):
        o = A.tex_off(d["w1"])
        args.append("off(%s)" % ", ".join("%d" % A.sext(o >> k, 4) for k in (0, 4, 8)))
    if e["f3"] in ("rm", "rm4") and d["f3"] != 0:
        args.append(RM_NAME.get(d["f3"], "rm%d" % d["f3"]))
    return mn + (" " + ", ".join(args) if args else "")


def check(text, w, pc, labels_pc):
    """Whether text assembles back to w."""
    mn, _, rest = text.partition(" ")
    try:
        return A.assemble_one(mn, A.split_args(rest), pc, labels_pc) == w
    except (ValueError, KeyError, AttributeError, IndexError):
        return False


def disassemble(words, use_labels=True):
    """Lines of assembly for a list of 64-bit words."""
    labels = {t: "L%d" % t for t in branch_targets(words)} if use_labels else {}
    labels_pc = {v: k for k, v in labels.items()}
    out = []
    for pc, w in enumerate(words):
        if pc in labels:
            out.append("%s:" % labels[pc])
        t = guess(w, pc, labels)
        if t is not None and check(t, w, pc, labels_pc):
            out.append("\t" + t)
            continue
        why = "undefined" if t is None else "not expressible: " + t
        if t is not None and A.decode(w, A.CFGS[1]) >> A.F["ILL"][0] & 1:
            why = "ISA fault: " + t
        out.append("\t.inst 0x%016x\t# %s" % (w, why))
    if len(words) in labels:
        out.append("%s:" % labels[len(words)])
    return out


HDR_NAMES = ["magic", "version", "stage", "flags", "code words", "code offset", "registers",
             "LDS bytes", "workgroup", "constant words", "interface offset",
             "interface entries", "entry", "minimum ISA", "push-constant bytes", "reserved"]


def from_words32(w32):
    """(header comment lines, 64-bit words) of a list of 32-bit words."""
    head = []
    if w32 and w32[0] == A.MAGIC:
        if len(w32) < 16:
            raise SystemExit("gsi1dis: a GSI1 header needs 16 words")
        h = w32[:16]
        for i, v in enumerate(h):
            head.append("# header %2d %-18s 0x%08x" % (i, HDR_NAMES[i], v))
        io, ni = h[10], h[11]
        for k in range(ni):
            ent = w32[io + 4 * k:io + 4 * k + 4]
            head.append("# interface %d: kind %d set %d binding %d word 0x%x" % ((k,) + tuple(ent)))
        co, cw = h[5], h[4]
        if co + cw > len(w32) or cw % 2:
            raise SystemExit("gsi1dis: code words %d at %d do not fit" % (cw, co))
        if h[12]:
            head.append("# entry point: instruction %d" % h[12])
        w32 = w32[co:co + cw]
    if len(w32) % 2:
        raise SystemExit("gsi1dis: an odd number of 32-bit words")
    return head, [w32[i] | w32[i + 1] << 32 for i in range(0, len(w32), 2)]


def read_hex(text):
    w32 = []
    for ln in text.splitlines():
        ln = re.split(r"//|#", ln)[0].strip()
        if not ln or ln.startswith("@"):
            continue
        for tok in ln.split():
            v = int(tok, 16)
            if len(tok) == 16:
                w32 += [v & 0xFFFFFFFF, v >> 32]
            elif len(tok) <= 8:
                w32.append(v)
            else:
                raise SystemExit("gsi1dis: %r is neither 8 nor 16 hex digits" % tok)
    return w32


def read_bin(data):
    if len(data) % 4:
        raise SystemExit("gsi1dis: the binary is not a whole number of words")
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


def load(path, fmt=None):
    with open(path, "rb") as f:
        data = f.read()
    if fmt is None:
        text = all(b in b"\t\n\r" or 32 <= b < 127 for b in data)
        fmt = "bin" if data[:4] == A.MAGIC.to_bytes(4, "little") or not text else "hex"
    return read_bin(data) if fmt == "bin" else read_hex(data.decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", dest="out")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--hex", action="store_const", const="hex", dest="fmt")
    g.add_argument("--bin", action="store_const", const="bin", dest="fmt")
    ap.add_argument("--no-labels", action="store_true")
    a = ap.parse_args()
    head, words = from_words32(load(a.src, a.fmt))
    lines = head + disassemble(words, not a.no_labels)
    text = "\n".join(lines) + "\n"
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    sys.exit(main())
