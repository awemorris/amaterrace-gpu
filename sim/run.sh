#!/bin/sh
# Runs the iverilog unit testbenches: sim/tb/NAME_tb.v with all of rtl/ and
# sim/models/.  A testbench prints "PASS NAME" at its end and "FAIL ..." on
# any mismatch; the run passes when PASS is printed and FAIL is not.
#   sim/run.sh [NAME...]     (no NAME: every testbench)
# Output (the vvp binary, the log) goes to build/sim/ (not in git).
# SEED=n is passed to the testbench as +seed=n.  Timeout per run: 300 s
# (SIM_TIMEOUT=s to change it).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -u
root=$(cd "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1
out=$root/build/sim
mkdir -p "$out"
command -v iverilog >/dev/null || { echo "sim: no iverilog" >&2; exit 1; }
if [ $# -eq 0 ]; then
	set -- $(ls sim/tb/*_tb.v | sed 's|.*/||; s|_tb\.v$||')
fi
rtl=$(find rtl sim/models -name '*.v' | sort)
fail=0
for name in "$@"; do
	tb=sim/tb/${name}_tb.v
	[ -f "$tb" ] || { echo "sim: no $tb" >&2; fail=1; continue; }
	if ! iverilog -g2005 -Wall -Wno-timescale -Iinclude -Isim/tb -s "${name}_tb" \
		-o "$out/$name.vvp" "$tb" $rtl 2>"$out/$name.build"; then
		cat "$out/$name.build" >&2
		echo "FAIL $name (build)"
		fail=1
		continue
	fi
	if [ -s "$out/$name.build" ]; then
		cat "$out/$name.build" >&2
		echo "FAIL $name (iverilog warnings)"
		fail=1
		continue
	fi
	timeout "${SIM_TIMEOUT:-300}" vvp -n "$out/$name.vvp" +seed="${SEED:-1}" >"$out/$name.log" 2>&1
	if grep -q "^PASS $name\$" "$out/$name.log" && ! grep -q 'FAIL\|ERROR' "$out/$name.log"; then
		echo "PASS $name"
	else
		grep 'FAIL\|ERROR' "$out/$name.log" | head -20
		echo "FAIL $name (log $out/$name.log)"
		fail=1
	fi
done
exit $fail
