#!/bin/sh
# Builds and runs the Verilator firmware harness (fw_harness.cpp): atg_top
# with the CPU and the committed firmware image (64-byte lines, NSU 1, VF,
# RX, TU, ROP with stencil), replaying the scene that the host build of
# the firmware writes (fw/cp/tests/fwtest -t).  Output under
# build/verilator-fw/ (not in git).
#   sim/verilator/fw-run.sh
# Prints "PASS fw.<case>" per case and "PASS verilator fw" on success.
# Needs cc, verilator and the images of tools/fw-build.sh (run it first
# after changing fw/cp/).  Timeouts: 120 s for the host build and run,
# 900 s for the Verilator build, 1800 s for the run.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"
LC_ALL=C
export LC_ALL
out=$root/build/verilator-fw
mkdir -p "$out"
command -v verilator >/dev/null || { echo "verilator: not installed" >&2; exit 1; }

# The scene: the host tests of the firmware with their trace.
srcs=
for c in fw/cp/*.c; do
	case $(basename "$c") in
	main.c | lib.c) ;;
	*) srcs="$srcs $c" ;;
	esac
done
# shellcheck disable=SC2086
timeout 120 cc -std=c99 -O1 -DFW_HOST -DFW_LINE_BYTES=64u -Iinclude -Ifw/cp \
	-Wall -Wextra -Werror -Wno-unused-parameter -o "$out/fwtest" $srcs fw/cp/tests/fwhost.c \
	fw/cp/tests/fwtest.c
timeout 120 "$out/fwtest" -t "$out/fw_scene.txt" >"$out/fwtest.log" || {
	cat "$out/fwtest.log"
	echo "FAIL verilator fw (the host tests)"
	exit 1
}

# The GPU with the firmware.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GHAS_CPU=1 -GLINE_BYTES=64 -GLINE_SHIFT=6 \
	-GCPU_IMEM_WORDS=32768 -GCPU_DMEM_WORDS=16384 \
	'-GCPU_IMEM_INIT="fw/cp/images/atg1-cp-kc705.imem.hex"' \
	'-GCPU_DMEM_INIT="fw/cp/images/atg1-cp-kc705.dmem.hex"' \
	-GNSU=1 -GHAS_VF=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 -GROP_STENCIL=1 \
	-Mdir "$out/obj" -o "$out/atg_top_fw_sim" -CFLAGS "-I$root/include -O1" \
	"$root/sim/verilator/fw_harness.vlt" $(find rtl -name '*.v' | sort) \
	"$root/sim/verilator/fw_harness.cpp" >"$out/build.log" 2>&1 || {
	tail -30 "$out/build.log" >&2
	echo "FAIL verilator fw (build, log $out/build.log)"
	exit 1
}
timeout 1800 "$out/atg_top_fw_sim" "$out/fw_scene.txt"
