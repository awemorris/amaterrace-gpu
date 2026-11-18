#!/usr/bin/env python3
# cs-scene.py: the compute scene of sim/tb/atg_top_cs_tb.v and the
# Verilator harness's COMPUTE mode: GSI1 programs of sim/tb/su run as
# compute dispatches through the ring (class 0 micro-ops, docs/ghci.md §7.3),
# one segment per program, with the memory the reference model
# (tools/gsi1model.py) gives after each.
#   cs-scene.py [-o sim/vec/cs_scene.txt]
# Each segment: the program's GHCI_PROGRAM binary (§12.10, gsi1asm's header)
# at CODE, its data image (sim/tb/su/NAME.dat, gen_data.py) at 0x8000, and the
# ring words
#   SET_REG    CS_BASE (0x194) = the code after the header, CS_WORDS (0x195),
#              WG_SIZE (0x199) = lanes x 1 x 1
#   INVALIDATE flags 1 (the data cache: the testbench rewrote the data)
#   LOAD_PROGRAM 2 (compute: the instruction cache)
#   LOAD_CONST region 0, 0x8000, 256 words
#   DISPATCH   groups, 1, 1
#   FENCE      FENCES, segment number, flags 1 (IRQ_STATUS.FENCE)
# then the words the model leaves in the data image and the fence word.
# The last segment ("fault") is a warp that stores lidn for 32 lanes, waits
# for the stores and reaches an undefined instruction (an ISA fault, §12.6):
# the CP must go to FAULTED with FAULT_ADDR = its PC and FAULT_INFO kind 8,
# block 6 (SU), and the FENCE after the DISPATCH must not be written.
# Format (read by the testbenches):
#   N segments          first line
#   S name              a segment starts
#   I addr value        a memory word before the segment's ring words run
#   R word              the next ring word
#   F value             ring the doorbell; wait until FENCE_LAST = value
#   E addr value        a memory word after the fence
#   X addr info         ring the doorbell; wait for FAULTED; FAULT_ADDR = addr,
#                       FAULT_INFO = info
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
import argparse
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import gsi1asm as A  # noqa: E402
import gsi1model as M  # noqa: E402

root = os.path.dirname(here)
CODE = 0x00001000
FENCES = 0x0005EF00
# (program, lanes per workgroup, workgroups)
PROGRAMS = [("vadd", 128, 2), ("reduce", 128, 1), ("mem", 128, 1)]
FAULT_SRC = """
	slli r1, lidn, 2
	movi r2, 0x9000
	add r2, r2, r1
	sw lidn, 0(r2)
	fence 1
	wait 0, 0, 0
	.inst 0x0000000000000000    # word0[1:0] = 00: an ISA fault at PC 6
	end
"""
FAULT_PC = 6
FAULT_INFO = 0x00068000         # block 6 (SU), kind 8 (ISA), job tag 0 (v1)


def hdr(op, tag, flags, n):
    return (op << 24) | (tag << 16) | (flags << 8) | n


def binary(words):
    w32 = []
    for w in words:
        w32 += [w & 0xFFFFFFFF, w >> 32]
    return A.header(words) + w32


def ring_words(k, img, lanes, groups):
    tag = 0x10 + k
    ring = [hdr(1, tag, 0, 6), 0x194, CODE + 4 * img[5], 0x195, img[4], 0x199,
            lanes | 1 << 8 | 1 << 16,
            hdr(12, tag, 1, 0),
            hdr(8, tag, 0, 1), 2,
            hdr(7, tag, 0, 3), 0, M.DATA_BASE, M.CONST_WORDS,
            hdr(4, tag, 0, 3), groups, 1, 1,
            hdr(5, tag, 1, 2), FENCES, k]
    return ring


def segment(fp, k, name, lanes, groups):
    src = os.path.join(root, "sim/tb/su", name + ".s")
    with open(src) as f:
        words = A.encode(f.read())
    img = binary(words)
    dat = M.load_hex(os.path.join(root, "sim/tb/su", name + ".dat"))
    mem = {M.DATA_BASE // 4 + i: v for i, v in enumerate(dat)}
    m = M.Machine(words, lanes, 32, mem, groups, False)
    m.run()
    fp.write("S %s\n" % name)
    for i, v in enumerate(img):
        fp.write("I %08x %08x\n" % (CODE + 4 * i, v))
    for i, v in enumerate(dat):
        fp.write("I %08x %08x\n" % (M.DATA_BASE + 4 * i, v))
    ring = ring_words(k, img, lanes, groups)
    for v in ring:
        fp.write("R %08x\n" % v)
    fp.write("F %08x\n" % k)
    for i in range(M.DATA_WORDS):
        fp.write("E %08x %08x\n" % (M.DATA_BASE + 4 * i, m.mem.get(M.DATA_BASE // 4 + i, 0)))
    fp.write("E %08x %08x\n" % (FENCES, k))
    return len(ring)


def fault_segment(fp, k):
    img = binary(A.encode(FAULT_SRC))
    fp.write("S fault\n")
    for i, v in enumerate(img):
        fp.write("I %08x %08x\n" % (CODE + 4 * i, v))
    for i in range(32):
        fp.write("I %08x 00000000\n" % (0x9000 + 4 * i))
    ring = ring_words(k, img, 32, 1)
    for v in ring:
        fp.write("R %08x\n" % v)
    fp.write("X %08x %08x\n" % (FAULT_PC, FAULT_INFO))
    for i in range(32):
        fp.write("E %08x %08x\n" % (0x9000 + 4 * i, i))
    fp.write("E %08x %08x\n" % (FENCES, k - 1))
    return len(ring)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", dest="out", default=os.path.join(root, "sim/vec/cs_scene.txt"))
    a = ap.parse_args()
    n = 0
    with open(a.out, "w") as fp:
        fp.write("N %d\n" % (len(PROGRAMS) + 1))
        for k, (name, lanes, groups) in enumerate(PROGRAMS, 1):
            n += segment(fp, k, name, lanes, groups)
        n += fault_segment(fp, len(PROGRAMS) + 1)
    print("cs-scene: %d segments, %d ring words in %s" % (len(PROGRAMS) + 1, n, a.out))


if __name__ == "__main__":
    sys.exit(main())
