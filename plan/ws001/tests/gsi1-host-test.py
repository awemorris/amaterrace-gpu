#!/usr/bin/env python3
# The GSI1 compiler's host test (ws288-p010), driven by gsi1-host-test.sh.
#
#   gsi1-host-test.py HARNESS AMATERRACE_TOOLS SPV_DIR OUT_DIR
#
# 1. The encoder's words of known instructions (HARNESS encode) are what
#    amaterrace-gpu's tools/gsi1asm.py makes of the same assembly, and
#    tools/gsi1dis.py disassembles each to text that assembles back to it.
# 2. Every module is compiled; its code disassembles without an
#    undefined or inexpressible word and reassembles to the same words
#    (the round trip), and its interface table names what the module binds.
# 3. The modules the model can run (compute, vertex, fragment without
#    textures) run on tools/gsi1model.py with the memory, registers and
#    primitive table the harness laid out from the interface table, and
#    leave what the harness's IR reference left (floats to a tolerance).
# 4. The modules the model cannot run (textures) contain the instructions
#    their lowering must have.
# Prints PASS/FAIL per case and a count; exit status 1 on any failure.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import os
import struct
import subprocess
import sys

HARNESS, TOOLS, SPV, OUT = sys.argv[1:5]
sys.path.insert(0, TOOLS)
import gsi1asm as A  # noqa: E402
import gsi1dis as D  # noqa: E402

TIMEOUT = 300
failures = []
passes = []


def fail(name, why):
    failures.append(name)
    print("FAIL %s: %s" % (name, why))


def ok(name, what):
    passes.append(name)
    print("PASS %s: %s" % (name, what))


def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUT)
    return r.returncode, r.stdout.decode(errors="replace")


def f32(w):
    return struct.unpack("<f", struct.pack("<I", w & 0xFFFFFFFF))[0]


def close(a, b, tol):
    if a == b:
        return True
    fa, fb = f32(a), f32(b)
    if fa != fa and fb != fb:
        return True         # NaN either way (GSI1 makes every NaN 0x7FC00000)
    if fa != fa or fb != fb:
        return False
    if abs(fa) < 1e-30 and abs(fb) < 1e-30:
        return True
    return abs(fa - fb) <= tol * max(1.0, abs(fa), abs(fb))


def load_hex(path):
    with open(path) as f:
        return [int(x, 16) for x in f.read().split()]


def round_trip(name, prefix):
    """The code disassembles and reassembles to itself; returns the .s path or None."""
    with open(prefix + ".bin", "rb") as f:
        w32 = D.read_bin(f.read())
    head, words = D.from_words32(w32)
    lines = D.disassemble(words)
    bad = [ln for ln in lines if ".inst" in ln]
    if bad:
        fail(name, "the disassembly has words gsi1asm cannot write: %s" % bad[:3])
        return None
    again = A.encode("\n".join(lines))
    if again != words:
        fail(name, "the reassembled code differs from the compiled code")
        return None
    with open(prefix + ".s", "w") as f:
        f.write("\n".join(head + lines) + "\n")
    return prefix + ".s", w32, lines


# 1. The encoder.
enc = os.path.join(OUT, "encode.txt")
code, text = run([HARNESS, "encode", enc])
if code != 0:
    fail("encode", text)
else:
    bad = 0
    count = 0
    with open(enc) as f:
        for ln in f:
            hexw, asm = ln.rstrip("\n").split("\t")
            w = int(hexw, 16)
            count += 1
            try:
                want = A.encode(asm)[0]
            except SystemExit as ex:
                bad += 1
                print("  %s: gsi1asm refuses: %s" % (asm, ex))
                continue
            if want != w:
                bad += 1
                print("  %s: encoder %016x, gsi1asm %016x" % (asm, w, want))
                continue
            dis = D.disassemble([w], use_labels=False)[0].strip()
            if ".inst" in dis or A.encode(dis)[0] != w:
                bad += 1
                print("  %s: gsi1dis gives %r" % (asm, dis))
    if bad:
        fail("encode", "%d of %d words differ" % (bad, count))
    else:
        ok("encode", "%d known words match gsi1asm and round-trip through gsi1dis" % count)

# 2-4. The modules: (name, mode, harness arguments, options, tolerance, mnemonics the code must
# have, or with "!" must not have).
CASES = [
    ("integer.comp", "compute", ["64", "4"], "", 0, ["div", "remu", "srai", "slt"]),
    ("float.comp", "compute", ["32", "1"], "floats", 2e-6, ["fround.s", "fract", "fcvt.w.s"]),
    ("trig.comp", "compute", ["32", "1"], "floats", 2e-4, ["rcp", "log2", "sin", "fsqrt.s"]),
    ("loop.comp", "compute", ["64", "1"], "", 0, ["exec.save", "exec.and", "bexnz", "exec.set"]),
    ("control.comp", "compute", ["64", "1"], "", 0, ["sw"]),
    ("atomic.comp", "compute", ["32", "1"], "", 0, ["atom.add", "atom.cmpxchg", "atom.xchg"]),
    ("shared.comp", "compute", ["128", "2"], "", 0, ["lds", "sts", "bar"]),
    ("sharedatomic.comp", "compute", ["64", "1"], "", 0,
     ["atoms.add", "atoms.umax", "atoms.umin", "atoms.or", "atoms.and", "atoms.xor",
      "atoms.smax", "atoms.smin", "atoms.xchg", "atoms.cmpxchg"]),
    ("uniform.comp", "compute", ["32", "1"], "", 0, []),
    ("uniform.comp:robust", "compute", ["32", "1"], "robust", 0, ["minu"]),
    ("uniform.comp:bank", "compute", ["32", "1"], "bank=40", 0, []),
    ("basic.frag:bank", "fragment", [], "w=56,bank=20", 2e-6, ["lda"]),
    ("groups.comp", "compute", ["32", "4"], "", 0, []),
    ("half.comp", "compute", ["32", "1"], "floats", 1e-6, ["packh", "unpackh.lo"]),
    ("image.comp", "compute", ["64", "1"], "", 1e-6, ["lw", "sw"]),
    ("basic.frag", "fragment", [], "w=56", 2e-6, ["lda", "fmadd.s", "rcp"]),
    ("basic.frag:points", "fragment", [], "w=56,points", 2e-6, ["lda"]),
    ("discard.frag", "fragment", [], "cover=ffff7f3f", 2e-6, ["kill", "exp"]),
    ("samplemask.frag", "fragment", [], "samples=4,mask", 2e-6, ["exp"]),
    ("samplemask.frag:1x", "fragment", [], "mask", 2e-6, ["exp"]),
    ("derivative.frag", "fragment", [], "", 2e-5, ["qdx", "qdy", "qbcast"]),
    ("subpass.frag", "fragment", [], "ia0=37", 2e-6, ["fcvt.w.s", "lw"]),
    ("store.frag", "fragment", [], "cover=f3ff3fff", 0, ["sw"]),
    ("basic.vert", "vertex", [], "w=56", 2e-6, ["exp"]),
    ("image.vert", "vertex", [], "", 2e-6, ["lw"]),
    ("varying64.vert", "vertex", [], "", 2e-6, ["exp"]),
    ("varying64.frag", "fragment", [], "", 2e-6, ["lda"]),
    ("varying64all.vert", "vertex", [], "", 2e-6, ["exp"]),
    ("varyingloop.vert", "vertex", [], "", 2e-6, ["exp", "exec.save", "bexnz"]),
    ("late.vert", "vertex", [], "", 2e-6, ["exp", "!sw.x"]),
    ("spill.vert", "vertex", [], "", 2e-6, ["exp", "sw.x", "lw"]),
    ("spill.comp", "compute", ["64", "2"], "", 0, ["sw.x", "lw", "bexnz"]),
    ("spill.frag", "fragment", [], "cover=ffff7f3f,floats", 2e-5, ["sw.x", "lw", "qdx", "qbcast"]),
    ("mrt.frag", "compile-fragment", [], "", 0, ["exp"]),
    ("texture.frag", "compile-fragment", [], "regs=64", 0,
     ["texb", "texl", "texg.b", "texb.c", "texb.3", "texf", "texsz", "texsz.s", "texsz.l"]),
    ("msarray.frag", "compile-fragment", [], "", 0, ["texf.3"]),
    ("texelbuffer.comp", "compute", ["32", "1"], "", 0, ["lw", "sw"]),
    ("imageatomic.comp", "compute", ["32", "1"], "", 0, ["atom.add", "atom.umax", "atom.cmpxchg"]),
    ("cubegrad.frag", "compile-fragment", [], "regs=64", 0, ["texl.3", "log2", "texsz.d", "exec.save"]),
]

for name, mode, extra, options, tol, mnemonics in CASES:
    spv_name = name.split(":")[0]
    prefix = os.path.join(OUT, name.replace(":", "-"))
    spv = os.path.join(SPV, spv_name + ".spv")
    if mode.startswith("compile-"):
        stage = mode.split("-", 1)[1]
        code, text = run([HARNESS, "compile", stage, spv, prefix, options])
    else:
        code, text = run([HARNESS, mode, spv, prefix] + extra + ["1"] + [options])
    if code != 0:
        fail(name, text.strip())
        continue
    rt = round_trip(name, prefix)
    if rt is None:
        continue
    asm, w32, lines = rt
    used = set(ln.split()[0] for ln in lines if ln.startswith("\t"))
    missing = [m for m in mnemonics if not m.startswith("!") and m not in used]
    missing += [m for m in mnemonics if m.startswith("!") and m[1:] in used]
    if missing:
        fail(name, "the code lacks %s" % missing)
        continue
    if w32[6] > 64 or w32[0] != A.MAGIC or w32[1] != 1 or w32[10] != 16:
        fail(name, "the header is wrong: %s" % w32[:16])
        continue
    if mode.startswith("compile-"):
        ok(name, "%d instructions, round trip, %d interface entries" % (w32[4] // 2, w32[11]))
        continue
    with open(prefix + ".args") as f:
        margs = f.read().split()
    model = [sys.executable, "-I", os.path.join(TOOLS, "gsi1model.py"), asm] + margs + \
        ["--data", prefix + ".data.hex", "-o", prefix + ".regs", "--mem-out", prefix + ".mem"]
    if mode == "fragment":
        model += ["--warps", prefix + ".warps.hex", "--init", prefix + ".init.hex",
                  "--prims", prefix + ".prims.hex", "--exp-out", prefix + ".exp",
                  "--ms-out", prefix + ".ms"]
    if mode == "vertex":
        model += ["--warps", prefix + ".warps.hex", "--init", prefix + ".init.hex",
                  "--pt-out", prefix + ".pt"]
    code, text = run(model)
    if code != 0:
        fail(name, "the model stops: " + text.strip()[-400:])
        continue
    bad = []
    if mode in ("compute", "fragment"):
        mem = load_hex(prefix + ".mem")
        want = load_hex(prefix + ".expect.hex")
        cmp = load_hex(prefix + ".compare")
        for i, c in enumerate(cmp):
            if c == 0:
                continue
            t = tol if c == 2 or tol else 0
            if (t == 0 and mem[i] != want[i]) or (t and not close(mem[i], want[i], t)):
                bad.append("word %d: model %08x reference %08x" % (i, mem[i], want[i]))
    if mode == "fragment":
        got = load_hex(prefix + ".exp")
        want = load_hex(prefix + ".expect-exp.hex")
        if len(got) != len(want):
            bad.append("%d export words, the reference %d" % (len(got), len(want)))
        else:
            for i, (g, w) in enumerate(zip(got, want)):
                q = (i - 1) % 22
                exact = i == 0 or q in (0, 1)
                if (exact and g != w) or (not exact and not close(g, w, tol)):
                    bad.append("export word %d: model %08x reference %08x" % (i, g, w))
        got = load_hex(prefix + ".ms")
        want = load_hex(prefix + ".expect-ms.hex")
        if got != want:
            bad.append("sample masks: model %s reference %s" % (got, want))
    if mode == "vertex":
        with open(prefix + ".pt") as f:
            got = f.read().split()
        with open(prefix + ".expect-pt.hex") as f:
            want = f.read().split()
        for i, (g, w) in enumerate(zip(got, want)):
            if w == "000000000":
                continue
            if g[0] != "1" or not close(int(g[1:], 16), int(w[1:], 16), tol):
                bad.append("PT word %d: model %s reference %s" % (i, g, w))
    if bad:
        fail(name, "%d differences: %s" % (len(bad), "; ".join(bad[:4])))
        continue
    ok(name, "%d instructions; the model's results are the reference's" % (w32[4] // 2))

print("%d passed, %d failed" % (len(passes), len(failures)))
sys.exit(1 if failures else 0)
