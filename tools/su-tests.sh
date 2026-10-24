#!/bin/sh
# Builds the GSI1 programs of the SU testbench (sim/tb/su/*.s) into
# $readmemh images, one 32-bit word per line (NAME.hex), writes each
# program's data image (NAME.dat, gen_data.py) and runs the reference model
# (tools/gsi1model.py) for the expected registers (NAME.exp) and data
# memory (NAME.mexp).  sub.s uses the subgroup instructions: its model runs
# with --subgroup, and once more without for the ISA faults that an SU
# without SUBGROUP must report (sub.fault: "slot pc" per warp; sub.fexp: the
# registers written before them).  rand.s and frand.s are generated first (gen_rand.py,
# gen_frand.py).  The images are committed, so sim/run.sh needs no Python;
# run this after changing a program.  Lanes and workgroups per program: the
# table below (the same as in sim/tb/atg_su_tb.v).
#   tools/su-tests.sh
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
src=$root/sim/tb/su
export PYTHONDONTWRITEBYTECODE=1
timeout 60 python3 -I "$src/gen_rand.py" "$src/rand.s"
timeout 60 python3 -I "$src/gen_frand.py" "$src/frand.s"
for p in alu:128:1 branch:100:1 rand:128:1 frand:128:1 mem:128:1 vadd:128:2 reduce:128:1 \
	sub:100:1; do
	n=${p%%:*}
	rest=${p#*:}
	lanes=${rest%%:*}
	groups=${rest#*:}
	sg=
	[ "$n" = sub ] && sg=--subgroup
	timeout 60 python3 -I "$root/tools/gsi1asm.py" "$src/$n.s" -o "$src/$n.hex"
	timeout 60 python3 -I "$src/gen_data.py" "$n" "$src/$n.dat"
	timeout 300 python3 -I "$root/tools/gsi1model.py" "$src/$n.s" --lanes "$lanes" \
		--groups "$groups" $sg --data "$src/$n.dat" -o "$src/$n.exp" --mem-out "$src/$n.mexp"
done
timeout 60 python3 -I "$root/tools/gsi1model.py" "$src/sub.s" --lanes 100 --data "$src/sub.dat" \
	-o "$src/sub.fexp" --fault-out "$src/sub.fault"
