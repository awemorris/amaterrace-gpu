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
run "atg_top (ZYBO 3: raster, RX + ROP)" --top-module atg_top $zybo -GHAS_RX=1 -GHAS_ROP=1
run "atg_top (ZYBO 4: compute, 1 SU)" --top-module atg_top $zybo -GNSU=1
kc="-GLINE_BYTES=64 -GLINE_SHIFT=6 -GDATA_W=512 -GS_ID_W=4 -GS_LEN_W=8"
kcsu="-GHAS_CPU=1 -GHAS_VF=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 -GEXT_CLIENT=1 -GHAS_JTAG=1
	-GROP_STENCIL=1 -GSU_NPHYS=16 -GSU_GRP_W=1 -GSU_NREGS=64 -GSU_SB_ENTRIES=8 -GSU_SBE_W=3
	-GSU_PACKED=1 -GSU_SUBGROUP=1 -GSU_FRAG_RESERVE=2 -GSU_LDS_BYTES=16384 -GSU_VARY_WORDS=32"
run "atg_top (KC705 raster/compute, 1 SU)" --top-module atg_top $kc $kcsu -GNSU=1
run "atg_top (KC705 raster/compute, 4 SUs)" --top-module atg_top $kc $kcsu -GNSU=4
run "atg_top (SA reserved: 1 SU + atg_sa)" --top-module atg_top $zybo -GNSU=1 -GHAS_SA=1
# The board tops, with lint-only stand-ins for the Xilinx primitives
# (sim/lint/xilinx_stubs.v).  PINMISSING: the PS7 has many pins left open
# on purpose; PINCONNECTEMPTY: atg_top outputs a board does not use.
# -fno-dedup: Verilator 5.032's V3Gate dedup aborts with an internal error
# ("Consumer doesn't match lhs of assign") on atg_kc705_raster once the
# SU <-> TU link is live (WS288 p009 part C); dedup is an optimisation, the
# lint checks are the same.
for f in boards/*/*.v; do
	t=$(basename "$f" .v)
	b=$(dirname "$f")
	run "$t (board top)" --top-module "$t" -Wno-PINMISSING -Wno-PINCONNECTEMPTY -fno-dedup \
		"$f" $(ls "$b"/lib/*.v 2>/dev/null) sim/lint/xilinx_stubs.v
done
exit $fail
