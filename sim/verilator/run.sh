#!/bin/sh
# Builds and runs the Verilator system harness (harness.cpp around atg_top
# in the ZYBO's shape).  Output under build/verilator/ (not in git).
#   sim/verilator/run.sh
# Prints "PASS verilator" on success.  Timeout: 600 s for the build, 300 s
# for the run.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"
LC_ALL=C
export LC_ALL
out=$root/build/verilator
mkdir -p "$out"
command -v verilator >/dev/null || { echo "verilator: not installed" >&2; exit 1; }
timeout 600 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -Mdir "$out/obj" -o "$out/atg_top_sim" \
	-CFLAGS "-I$root/include -O1" \
	$(find rtl -name '*.v' | sort) sim/verilator/harness.cpp >"$out/build.log" 2>&1 || {
	tail -30 "$out/build.log" >&2
	echo "FAIL verilator (build, log $out/build.log)"
	exit 1
}
timeout 300 "$out/atg_top_sim"
