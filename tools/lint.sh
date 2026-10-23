#!/bin/sh
# Lints the RTL with Verilator (-Wall, zero warnings expected): every module
# of rtl/ as its own top, and atg_top in the shapes of the bitstreams (the
# ZYBO's and the KC705's line and beat sizes, and the block sets of design
# §3.6 and §7.6).  Exit status 1 on any warning.
#   tools/lint.sh
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -u
root=$(cd "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1
LC_ALL=C
export LC_ALL
command -v verilator >/dev/null || { echo "lint: no verilator" >&2; exit 1; }
srcs=$(find rtl -name '*.v' | sort)
fail=0
run() {
	name=$1
	shift
	if out=$(verilator --lint-only -Wall -Iinclude $srcs "$@" 2>&1); then
		echo "lint: $name clean"
	else
		echo "$out" | grep -v '^- ' >&2
		echo "lint: $name FAILED" >&2
		fail=1
	fi
}
for f in $srcs; do
	m=$(basename "$f" .v)
	run "$m" --top-module "$m"
done
run "atg_top (ZYBO: 32-byte lines, 64-bit AXI)" --top-module atg_top
run "atg_top (KC705: 64-byte lines, 512-bit AXI)" --top-module atg_top \
	-GLINE_BYTES=64 -GLINE_SHIFT=6 -GDATA_W=512 -GS_ID_W=4 -GS_LEN_W=8
zybo="-GLINE_BYTES=32 -GLINE_SHIFT=5 -GDATA_W=64 -GS_ID_W=12 -GS_LEN_W=4"
run "atg_top (ZYBO 1': 2D + FW, HAS_CPU)" --top-module atg_top $zybo -GHAS_CPU=1
exit $fail
