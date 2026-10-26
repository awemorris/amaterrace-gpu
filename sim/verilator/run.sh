#!/bin/sh
# Builds and runs the Verilator system harness (harness.cpp around atg_top
# in the KC705's shape: 64-byte lines, 512-bit AXI, the KC705's SU) in
# seven modes: the basic one (registers, the blitter, the ring), the
# raster, shaded, textured, multisampling, compute and Vulkan 1.0 core
# scenes.  Output under build/verilator/ (not in git).
#   sim/verilator/run.sh [MODE...]   (no MODE: all; MODE basic, raster,
#                                     shade, tex, msaa, compute, core)
# Prints "PASS verilator" (basic) and "PASS verilator MODE" on success.
# Timeout: 900 s for each build, 600 s for each run.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"
LC_ALL=C
export LC_ALL
out=$root/build/verilator
mkdir -p "$out"
command -v verilator >/dev/null || { echo "verilator: not installed" >&2; exit 1; }

# The KC705's shape (boards/kc705/atg_kc705_top.v), without the CPU,
# the display and JTAG, which the harness does not drive.
KC="-GLINE_BYTES=64 -GLINE_SHIFT=6 -GDATA_W=512"
SU="-GNSU=1 -GSU_NPHYS=4 -GSU_GRP_W=3 -GSU_NREGS=64 -GSU_SB_ENTRIES=8 -GSU_SBE_W=3
	-GSU_PACKED=1 -GSU_SUBGROUP=1 -GSU_FRAG_RESERVE=2 -GSU_LDS_BYTES=16384 -GSU_VARY_WORDS=64"
GFX="-GHAS_VF=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 -GROP_STENCIL=1"

# build NAME DEFINE PARAMS...: the harness as build/verilator/atg_top_NAME, then its run.
build() {
	name=$1
	def=$2
	shift 2
	timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
		--top-module atg_top $KC "$@" -Mdir "$out/obj-$name" -o "$out/atg_top_$name" \
		-CFLAGS "-I$root/include -O1 $def" \
		$(find rtl -name '*.v' | grep -v 'rtl/bsp/xilinx7' | sort) "$root/sim/verilator/harness.cpp" \
		>"$out/build-$name.log" 2>&1 || {
		tail -30 "$out/build-$name.log" >&2
		echo "FAIL verilator $name (build, log $out/build-$name.log)"
		exit 1
	}
	timeout 600 "$out/atg_top_$name"
}

# $SU and $GFX are split on purpose: one word per -G.
for m in ${*:-basic raster shade tex msaa compute core}; do
	case $m in
	# The registers, a FILL and a COPY, the debug port, the ring.
	basic) build basic "" ;;
	# The raster scene: HAS_RX and HAS_ROP, the colour buffer to a PNG.
	raster) build raster -DRASTER -GHAS_RX=1 -GHAS_ROP=1 ;;
	# The shaded scene: VF, SU, RX, ROP, the colour buffer to a PNG.
	shade) build shade -DSHADE -GHAS_VF=1 -GHAS_RX=1 -GHAS_ROP=1 $SU ;;
	# The textured scene: VF, SU, RX, TU, ROP, the colour buffer to a PNG.
	tex) build tex -DTEX $GFX $SU ;;
	# The multisampling scene (MS4), the resolved image to a PNG.
	msaa) build msaa -DMSAA $GFX $SU -GMS4=1 ;;
	# The compute scene: GSI1 programs dispatched through the ring, the
	# memory against tools/gsi1model.py, an ISA fault.
	compute) build compute -DCOMPUTE $SU ;;
	# The Vulkan 1.0 core scene (CAPS[30], tools/rx-core-scene.py).
	core) build core -DCORE $GFX $SU -GMS4=1 ;;
	*) echo "verilator: no mode $m" >&2; exit 1 ;;
	esac
done
