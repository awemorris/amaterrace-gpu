#!/bin/bash
# Standalone equivalence test for am_mul: generic vs DSP48E1 cascade
# Checks all 19 operand shapes x LAT=0..3 (76 instance pairs).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu

root=$(cd "$(dirname -- "$0")/.." && pwd)
out="$root/build/sim"
mkdir -p "$out"

VIVADO_DIR="${XILINX_VIVADO:-/home/awe/opt/amd/2026.1/Vivado}"
GLBL="$VIVADO_DIR/data/verilog/src/glbl.v"
DSP48="$VIVADO_DIR/data/verilog/src/unisims/DSP48E1.v"

if [ ! -f "$GLBL" ] || [ ! -f "$DSP48" ]; then
	echo "mul-dsp-test: Xilinx Unisims not found at $VIVADO_DIR" >&2
	exit 1
fi

iverilog -g2005 -DSYNTH_KINTEX7 -I"$root/rtl/library/arith" \
	"$GLBL" "$DSP48" \
	"$root/rtl/library/arith/am_mul.v" \
	"$root/sim/tb/am_mul_dsp_tb.v" \
	-s am_mul_dsp_tb -s glbl -o "$out/am_mul_dsp_tb.vvp" 2>/dev/null

vvp "$out/am_mul_dsp_tb.vvp"
