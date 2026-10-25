#!/usr/bin/env python3
# gsi1dis-test.py: the round trips of tools/gsi1dis.py against
# tools/gsi1asm.py (host only, no simulator).
#   gsi1dis-test.py [--seed N] [--count N]
# Prints "PASS gsi1dis.<case>" per case and "PASS gsi1dis" at the end:
#   programs  every sim/tb/su/*.s: asm -> dis -> asm gives the same words,
#             and the dis has no .inst line; the committed NAME.hex too
#   binary    the same programs as GHCI_PROGRAM binaries (header + code):
#             dis reads the header, asm --bin rebuilds the same bytes
#   table     every entry of gsi1asm's table T with random operands, source
#             modifiers, .sat, half selects, rounding modes, atomics (global
#             and shared) and
#             branch offsets (some to labels): asm -> dis -> asm, no .inst
#   raw       the decode vectors (sim/tb/su/dec_table.hex, random 64-bit
#             words): dis -> asm gives the same words (.inst allowed)
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import glob
import os
import random
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import gsi1asm as A  # noqa: E402
import gsi1dis as D  # noqa: E402

root = os.path.dirname(here)
fails = 0


def fail(msg):
    global fails
    fails += 1
    if fails <= 20:
        print("FAIL gsi1dis: " + msg)


def roundtrip(words, what, allow_inst=False):
    """dis then asm; the number of .inst lines."""
    lines = D.disassemble(words)
    back = A.encode("\n".join(lines))
    if back != words:
        for i, (a, b) in enumerate(zip(words, back)):
            if a != b:
                txt = D.disassemble([a], False)[0].strip()
                fail("%s: instruction %d %016x -> %r -> %016x" % (what, i, a, txt, b))
                break
        else:
            fail("%s: %d words came back as %d" % (what, len(words), len(back)))
    ni = sum(1 for ln in lines if ln.strip().startswith(".inst"))
    if ni and not allow_inst:
        bad = [ln for ln in lines if ln.strip().startswith(".inst")]
        fail("%s: %d .inst lines, first %s" % (what, ni, bad[0].strip()))
    return ni


def programs():
    n = 0
    for src in sorted(glob.glob(os.path.join(root, "sim/tb/su/*.s"))):
        with open(src) as f:
            words = A.encode(f.read())
        roundtrip(words, os.path.basename(src))
        hx = src[:-2] + ".hex"
        if os.path.exists(hx):
            with open(hx) as f:
                _, hw = D.from_words32(D.read_hex(f.read()))
            if hw != words:
                fail("%s: the committed hex is not the source's code" % hx)
            roundtrip(hw, os.path.basename(hx))
        n += 1
    print("PASS gsi1dis.programs: %d programs" % n)


def binary():
    n = 0
    for src in sorted(glob.glob(os.path.join(root, "sim/tb/su/*.s"))):
        with open(src) as f:
            words = A.encode(f.read())
        w32 = []
        for w in words:
            w32 += [w & 0xFFFFFFFF, w >> 32]
        img = A.header(words) + w32
        data = b"".join(x.to_bytes(4, "little") for x in img)
        head, got = D.from_words32(D.read_bin(data))
        if got != words or len(head) < 16:
            fail("%s: the binary's code is not found" % src)
            continue
        back = A.encode("\n".join(head + D.disassemble(got)))
        b32 = []
        for w in back:
            b32 += [w & 0xFFFFFFFF, w >> 32]
        bdata = b"".join(x.to_bytes(4, "little") for x in A.header(back) + b32)
        if bdata != data:
            fail("%s: the rebuilt binary differs" % src)
        n += 1
    print("PASS gsi1dis.binary: %d binaries" % n)


def rnd_reg(r):
    return D.reg_name(r.randrange(128))


def rnd_src(r, fp):
    t = rnd_reg(r)
    if fp:
        k = r.randrange(4)
        t = ["%s", "-%s", "|%s|", "-|%s|"][k] % t
    return t


def rnd_imm(r):
    return r.randrange(-(1 << 21), (1 << 21) - 2048)


def rnd_insn(r, n, e):
    fp = bool(e.get("fp"))
    if e["fmt"] == "U":
        if e.get("movi"):
            return "movi %s, %d" % (rnd_reg(r), r.getrandbits(32))
        return "lui %s, %d" % (rnd_reg(r), r.getrandbits(20))
    mn = n
    if n == "atom":
        mn = r.choice(["atom.", "atoms."]) + r.choice(A.ATOMS)
    cmpxchg = mn.endswith(".cmpxchg")
    if fp and r.random() < 0.3:
        mn += ".sat"
    if r.random() < 0.3:
        mn += "." + r.choice(sorted(A.HSEL))
    args = []
    for o in e["ops"]:
        if o == "d":
            args.append(rnd_reg(r))
        elif o in "123":
            args.append(rnd_src(r, fp))
        elif o == "a":
            args.append("(%s)" % rnd_reg(r))
        elif o == "m":
            args.append("%d(%s)" % (rnd_imm(r), rnd_reg(r)))
        elif o == "i":
            args.append("%d" % (r.randrange(32) if e.get("shift") else
                                r.randrange(512) if n == "lda" else rnd_imm(r)))
        elif o == "x":
            args.append("%d" % rnd_imm(r))
        elif o == "w":
            args += ["%d" % r.randrange(16) for _ in range(3)]
        elif o == "l":
            args.append("%d" % r.randrange(-40, 40))
        elif o == "t":
            args.append("%d" % r.randrange(16 if e["unit"] == A.U_TEX else 32))
    if cmpxchg:
        args.append(rnd_reg(r))
    if e["unit"] == A.U_TEX and e["fmt"] == "R" and r.random() < 0.5:
        args.append("off(%s)" % ", ".join("%d" % r.randrange(-8, 8)
                                          for _ in range(r.choice([2, 3]))))
    if e["f3"] == "rm" and r.random() < 0.7:
        args.append(r.choice(sorted(A.RM)))
    elif e["f3"] == "rm4" and r.random() < 0.7:
        args.append(r.choice(["rne", "rtz", "rdn", "rup"]))
    return mn + (" " + ", ".join(args) if args else "")


def table(seed, count):
    r = random.Random(seed)
    lines = []
    for n, e in A.T.items():
        for _ in range(count):
            lines.append(rnd_insn(r, n, e))
    r.shuffle(lines)
    words = A.encode("\n".join(lines))
    roundtrip(words, "table")
    nl = sum(1 for ln in D.disassemble(words) if ln.endswith(":"))
    print("PASS gsi1dis.table: %d entries x %d = %d instructions, %d labels" %
          (len(A.T), count, len(words), nl))


def raw():
    with open(os.path.join(root, "sim/tb/su/dec_table.hex")) as f:
        words = [int(ln[:16], 16) for ln in f if ln.strip()]
    ni = roundtrip(words, "raw", allow_inst=True)
    print("PASS gsi1dis.raw: %d words, %d as text, %d as .inst" % (len(words), len(words) - ni, ni))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=60)
    a = ap.parse_args()
    programs()
    binary()
    table(a.seed, a.count)
    raw()
    if fails:
        print("FAIL gsi1dis: %d failures" % fails)
        return 1
    print("PASS gsi1dis")
    return 0


if __name__ == "__main__":
    sys.exit(main())
