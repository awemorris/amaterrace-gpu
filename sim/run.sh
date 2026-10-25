#!/bin/sh
# Runs the iverilog unit testbenches: sim/tb/NAME_tb.v with all of rtl/ and
# sim/models/.  A testbench prints "PASS NAME" at its end and "FAIL ..." on
# any mismatch; the run passes when PASS is printed and FAIL is not.
#   sim/run.sh [NAME[:+PLUSARG...]...]   (no NAME: every testbench)
#   sim/run.sh -q                        (the short run, below)
# NAME:+quick passes +quick to the testbench, NAME:+A:+B both plusargs
# (its log is NAME.quick.log).  Each result line ends with the run's seconds.
# Output (the vvp binary, the log) goes to build/sim/ (not in git).
# A testbench that needs files outside rtl/ (a board top) names them in a
# comment line " * sim-sources: FILE..." (paths from the repository root).
# SEED=n is passed to the testbench as +seed=n.  Timeout per run: 1500 s
# (SIM_TIMEOUT=s to change it; atg_top_core took 739 s on the host below).
#
# Every testbench (make sim) takes about 21 minutes, one after the other
# (2026-10-25, a 64-thread Linux host: atg_top_tex 382 s, atg_su 201,
# atg_top_shade 183, atg_top_cs 138, atg_top_raster 79, atg_dc_tgen 56,
# atg_top_fw 40, atg_top 30, atg_kc705_raster 25, the others about 120
# together); the default timeout leaves room for atg_top_tex (about 380 s) and atg_su on a
# slower or busy host too.  Those times are of the atg_top_* testbenches
# with two harnesses each; they now run the KC705's shape only, so their
# times are lower (not yet measured).
#
# The short run (-q, make sim-quick) touches every block (528 s on the same
# host with the former shapes): every testbench except the $LONG ones, and
# those of them that $QUICK lists, shortened:
#   atg_su +quick              NPHYS 8 and 32 and the no-SUBGROUP SU, no frand
#                              (58 s)
#   atg_top_tex                VF, SU, RX, TU and ROP through the ring (the
#                              KC705's shape alone took 173 s)
#   atg_top_cs                 compute through the ring
#   atg_top_fw                 the CP firmware (the KC705's shape alone: 19 s)
#   atg_dc_tgen +quick         the timing on a 64x16 mode instead of 640x480
#                              and 720p (1 s)
# atg_top_raster and atg_top_shade are left out: atg_top_tex runs the warp
# path through the same blocks and the RX/ROP unit testbenches the rest;
# atg_top_msaa too (about 5 minutes on that host, busy): the RX, ROP, TU
# and BLT unit testbenches run their multisampling cases; and atg_top_core
# (the Vulkan 1.0 core scene), whose blocks' unit testbenches run in the
# short run.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -u
root=$(cd "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1
out=$root/build/sim
mkdir -p "$out"
command -v iverilog >/dev/null || { echo "sim: no iverilog" >&2; exit 1; }
all=$(ls sim/tb/*_tb.v | sed 's|.*/||; s|_tb\.v$||')
LONG="atg_su atg_top_shade atg_top_cs atg_top_tex atg_top_msaa atg_top_core atg_top_raster atg_dc_tgen atg_top_fw"
QUICK="atg_su:+quick atg_top_tex atg_top_cs atg_top_fw atg_dc_tgen:+quick"
if [ "${1:-}" = -q ]; then
	set -- $(for n in $all; do
		case " $LONG " in *" $n "*) ;; *) echo "$n" ;; esac
	done) $QUICK
elif [ $# -eq 0 ]; then
	set -- $all
fi
rtl=$(find rtl sim/models -name '*.v' | sort)
fail=0
for ent in "$@"; do
	name=${ent%%:*}
	args=
	log=$out/$name.log
	if [ "$name" != "$ent" ]; then
		args=$(echo "${ent#*:}" | tr ':' ' ')
		log=$out/$name.quick.log
	fi
	tb=sim/tb/${name}_tb.v
	[ -f "$tb" ] || { echo "sim: no $tb" >&2; fail=1; continue; }
	t0=$(date +%s)
	extra=$(sed -n 's/^ \* sim-sources: //p' "$tb")
	if ! iverilog -g2005 -Wall -Wno-timescale -Iinclude -Isim/tb -s "${name}_tb" \
		-o "$out/$name.vvp" "$tb" $rtl $extra 2>"$out/$name.build"; then
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
	# $args is split on purpose: one word per plusarg.
	timeout "${SIM_TIMEOUT:-1500}" vvp -n "$out/$name.vvp" +seed="${SEED:-1}" $args \
		>"$log" 2>&1
	t=$(($(date +%s) - t0))
	if grep -q "^PASS $name\$" "$log" && ! grep -q 'FAIL\|ERROR' "$log"; then
		echo "PASS $name${args:+ $args} (${t} s)"
	else
		grep 'FAIL\|ERROR' "$log" | head -20
		echo "FAIL $name${args:+ $args} (${t} s, log $log)"
		fail=1
	fi
done
exit $fail
