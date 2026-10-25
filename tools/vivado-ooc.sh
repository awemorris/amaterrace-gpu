#!/bin/bash
# Out-of-context Vivado synthesis of the GPU core (atg_top) in the KC705's
# shape, for its area: LUT, FF, BRAM and DSP in total and per module
# (tools/vivado-ooc.tcl).  No board top, MIG or I/O, no place and route.
#   tools/vivado-ooc.sh [NAME=VALUE ...]
# The shape is the KC705 board top's atg_top parameters (NSU 1) with
# MS4=1; each NAME=VALUE replaces or adds a parameter (NSU=4, SU_NPHYS=16 SU_GRP_W=1).
# TOP (default atg_top) synthesizes another module instead, with only the
# NAME=VALUE parameters given.  The firmware images are not loaded (the
# IMEM and DMEM are writable RAMs, so their size does not depend on them).
# Output: build/vivado/ooc-NAME/ (OOC_NAME, default kc705):
# utilization.rpt, utilization_hier.rpt, timing_summary.rpt (the
# synthesis estimate at PERIOD ns, default 5), timing_paths.rpt (its 5
# worst paths), TOP.dcp, vivado.log; with OOC_IMPL=1 also placed and
# routed (route_*.rpt, TOP.routed.dcp; hours for the whole core).
# Prints the utilisation's main rows and the run's time.
# VIVADO, XILINXD_LICENSE_FILE and the libncurses.so.5 fallback as in
# tools/vivado-build.sh.  VIVADO_TIMEOUT (default 7200 s) bounds the run;
# VIVADO_THREADS (default 8) is Vivado's general.maxThreads; OOC_FLATTEN
# (none) keeps each module's logic in its own row of utilization_hier.rpt
# (the default, rebuilt, optimizes across modules and the rows are only
# approximate).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
part=${PART:-xc7k325tffg900-2}
top=${TOP:-atg_top}
name=${OOC_NAME:-kc705}
period=${PERIOD:-5}
if [ "$top" = atg_top ]; then
	shape="S_ID_W=4 S_LEN_W=8 LINE_BYTES=64 LINE_SHIFT=6 DATA_W=512
		HAS_CPU=1 CPU_IMEM_WORDS=16384 CPU_DMEM_WORDS=8192 NSU=1
		HAS_VF=1 HAS_RX=1 HAS_TU=1 HAS_ROP=1 EXT_CLIENT=1 HAS_JTAG=1 HAS_DISP=1
		ROP_STENCIL=1 MS4=1 SU_NPHYS=8 SU_NWARPS=4 SU_WARP_W=2 SU_GRP_W=2
		SU_NREGS=64 SU_SB_ENTRIES=8 SU_SBE_W=3 SU_PACKED=1 SU_SUBGROUP=1
		SU_FRAG_RESERVE=2 SU_LDS_BYTES=16384 SU_VARY_WORDS=64"
else
	shape=
fi
for arg in "$@"; do
	case $arg in
	*=*) ;;
	*) echo "usage: vivado-ooc.sh [NAME=VALUE ...]" >&2; exit 2 ;;
	esac
done
generics=
for kv in $shape; do
	keep=1
	for arg in "$@"; do
		[ "${arg%%=*}" = "${kv%%=*}" ] && keep=0
	done
	[ $keep -eq 1 ] && generics="$generics $kv"
done
generics="$generics $*"
if ! command -v vivado >/dev/null 2>&1; then
	settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
	[ -f "$settings" ] || { echo "vivado-ooc: no vivado on PATH and no $settings" >&2; exit 1; }
	. "$settings"
fi
if [ -z "${XILINXD_LICENSE_FILE:-}" ] && [ -f "$HOME/Xilinx.lic" ]; then
	XILINXD_LICENSE_FILE=$HOME/Xilinx.lic
	export XILINXD_LICENSE_FILE
fi
: "${XILINX_VIVADO:=$(dirname -- "$(dirname -- "$(command -v vivado)")")}"
if ! /sbin/ldconfig -p | grep -q 'libncurses\.so\.5 '; then
	LD_LIBRARY_PATH=$XILINX_VIVADO/lib/lnx64.o/Ubuntu/24${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
	export LD_LIBRARY_PATH
fi
out=$root/build/vivado/ooc-$name
mkdir -p "$out"
echo "vivado-ooc: $top$generics" > "$out/params.txt"
VIVADO_THREADS=${VIVADO_THREADS:-8}
export VIVADO_THREADS
start=$(date +%s)
rc=0
# Vivado writes its .Xil scratch into the current directory.
# shellcheck disable=SC2086
(cd "$out" && timeout "${VIVADO_TIMEOUT:-7200}" vivado -mode batch -nojournal \
	-log vivado.log -source "$root/tools/vivado-ooc.tcl" \
	-tclargs "$root" "$out" "$part" "$top" "$period" $generics </dev/null >/dev/null) || rc=$?
if [ $rc -ne 0 ]; then
	grep -E '^(ERROR|CRITICAL WARNING)' "$out/vivado.log" | head -20 >&2
	echo "vivado-ooc: failed rc $rc (log $out/vivado.log)" >&2
	exit 1
fi
grep -E '^\| (Slice LUTs\*? |  LUT as (Logic|Memory) |Slice Registers |Block RAM Tile |DSPs )' \
	"$out/utilization.rpt" | head -8
grep -E '^vivado-ooc:' "$out/vivado.log" | tail -2
echo "vivado-ooc: $(grep -c '^WARNING' "$out/vivado.log") warnings, $(grep -c '^CRITICAL WARNING' "$out/vivado.log") critical, $(( $(date +%s) - start )) s, $out"
