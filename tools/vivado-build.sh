#!/bin/bash
# Builds a board top with Vivado in non-project batch mode
# (tools/vivado-build.tcl).  Output stays under build/vivado/ (not in git).
#   tools/vivado-build.sh BOARD TOP     e.g. tools/vivado-build.sh kc705 atg_kc705_raster
# BOARD is a directory of boards/ with TOP.v and TOP.xdc; the part is the
# board's (kc705: xc7k325tffg900-2; PART overrides).
# VIVADO is the installation's settings64.sh (default
# $HOME/opt/amd/2026.1/Vivado/settings64.sh).  Vivado 2026.1 needs a
# license file even for the free parts: XILINXD_LICENSE_FILE, by default
# $HOME/Xilinx.lic when it exists.  Debian 13 has no libncurses.so.5,
# which Vivado's Tcl start-up loads; the installation's Ubuntu/24 directory
# has one, so it goes first on LD_LIBRARY_PATH when the host lacks it.
# Standard input is /dev/null (Vivado waits on it after an error).
# Prints the utilisation's main rows, WNS/WHS and the bitstream's hash.
# VIVADO_TIMEOUT (default 1800 s) bounds the run.  VIVADO_IP names a
# directory of generated IP cores (boards/BOARD/ip.tcl's OUT) that the
# build reads (kc705: the MIG, the PCIe bridge and the AXI cores).
# VIVADO_LOCK (default /tmp/zedbsd-vivado.lock): the run holds it, one
# Vivado at a time on the host.  VIVADO_OUT replaces the output directory
# (default build/vivado/TOP).  VIVADO_STRATEGY, VIVADO_*_DIRECTIVE and
# VIVADO_FROM_SYNTH: tools/vivado-build.tcl.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
[ $# -eq 2 ] || { echo "usage: vivado-build.sh BOARD TOP" >&2; exit 2; }
root=$(cd "$(dirname -- "$0")/.." && pwd)
board=$1
top=$2
topdir=$root/boards/$board
[ -f "$topdir/$top.v" ] && [ -f "$topdir/$top.xdc" ] || {
	echo "vivado-build: no $topdir/$top.v or .xdc" >&2
	exit 2
}
case $board in
kc705) part=${PART:-xc7k325tffg900-2} ;;
*) part=${PART:?PART is needed for board $board} ;;
esac
# A vivado on PATH is used as it is; otherwise VIVADO names settings64.sh.
if ! command -v vivado >/dev/null 2>&1; then
	settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
	[ -f "$settings" ] || { echo "vivado-build: no vivado on PATH and no $settings" >&2; exit 1; }
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
out=${VIVADO_OUT:-$root/build/vivado/$top}
mkdir -p "$out"
start=$(date +%s)
rc=0
# Vivado writes its .Xil scratch into the current directory.
(cd "$out" && flock "${VIVADO_LOCK:-/tmp/zedbsd-vivado.lock}" \
	timeout "${VIVADO_TIMEOUT:-1800}" vivado -mode batch -nojournal \
	-log vivado.log -source "$root/tools/vivado-build.tcl" \
	-tclargs "$root" "$topdir" "$top" "$out" "$part" "${VIVADO_IP:-}" </dev/null >/dev/null) || rc=$?
if [ $rc -ne 0 ]; then
	grep -E '^(ERROR|CRITICAL WARNING)' "$out/vivado.log" | head -20 >&2
	echo "vivado-build: failed rc $rc (log $out/vivado.log)" >&2
	exit 1
fi
grep -E '^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs|Bonded IOB|BUFGCTRL) ' \
	"$out/utilization.rpt" | head -8
grep -E '^vivado-build:' "$out/vivado.log" | tail -1
echo "vivado-build: $(grep -c '^WARNING' "$out/vivado.log") warnings, $(grep -c '^CRITICAL WARNING' "$out/vivado.log") critical, $(( $(date +%s) - start )) s"
echo "vivado-build: $out/$top.bit $(wc -c < "$out/$top.bit") bytes, sha256 $(sha256sum "$out/$top.bit" | cut -c1-16)"
