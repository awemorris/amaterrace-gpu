#!/bin/sh
# Builds the link (link.h, link.cpp): atg_top in the KC705's shape (the
# board top's parameters: the CPU with the committed firmware image,
# 64-byte lines, 512-bit AXI, one SU of the board's shape, VF, RX, TU, ROP
# with stencil, the MEM capability: 1 GiB of local memory at 0x8000_0000,
# a 64 MiB window, the display controller without its I2C master) as a
# static library for a host program.  The display controller names one
# small test mode (DC_TEST_MODE: 320 x 240 at 25 MHz) instead of the
# board's 640 x 480 and 720p, so that a frame is about 85,000 pixel clocks;
# link.cpp runs the pixel clock at a quarter of the core clock.  The
# board's own build (DC_TEST_MODE 0) is not this one.
#   sim/verilator/link-build.sh [OUTDIR]   (default build/verilator-link)
# Writes OUTDIR/link.o, OUTDIR/obj/Vatg_top__ALL.a, OUTDIR/obj/libverilated.a
# and OUTDIR/link.flags: what a C++ linker needs after the program's
# objects.  The firmware images are read when the model starts, from this
# tree (their absolute paths are in the build).  Prints "PASS link-build" on success.  Needs verilator and a
# C++ compiler, and the images of tools/fw-build.sh.  Timeout: 1200 s for
# the Verilator build.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"
LC_ALL=C
export LC_ALL
out=${1:-$root/build/verilator-link}
mkdir -p "$out"
out=$(cd "$out" && pwd)
command -v verilator >/dev/null || { echo "verilator: not installed" >&2; exit 1; }
base=0x80000000
bytes=0x40000000
window=0x04000000
timeout 1200 verilator --cc --build -j 8 -Wall -Iinclude \
	--top-module atg_top -GLINE_BYTES=64 -GLINE_SHIFT=6 -GDATA_W=512 -GS_ID_W=4 -GS_LEN_W=8 \
	-GHAS_CPU=1 -GCPU_IMEM_WORDS=32768 -GCPU_DMEM_WORDS=8192 \
	"-GCPU_IMEM_INIT=\"$root/fw/cp/images/atg1-cp-kc705.imem.hex\"" \
	"-GCPU_DMEM_INIT=\"$root/fw/cp/images/atg1-cp-kc705.dmem.hex\"" \
	-GNSU=1 -GHAS_VF=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 -GROP_STENCIL=1 \
	-GSU_NPHYS=8 -GSU_GRP_W=2 -GSU_NREGS=64 -GSU_SB_ENTRIES=8 \
	-GSU_SBE_W=3 -GSU_PACKED=1 -GSU_SUBGROUP=1 -GSU_FRAG_RESERVE=2 -GSU_LDS_BYTES=16384 \
	-GSU_VARY_WORDS=64 -GHAS_DISP=1 -GDC_HAS_I2C=0 -GDC_TEST_MODE=1 \
	"-GLOCAL_BASE=32'h80000000" "-GLOCAL_BYTES=32'h40000000" "-GWINDOW_BYTES=32'h04000000" \
	-Mdir "$out/obj" -CFLAGS "-O2" \
	"$root/sim/verilator/link.vlt" $(find rtl -name '*.v' | sort) >"$out/build.log" 2>&1 || {
	tail -30 "$out/build.log" >&2
	echo "FAIL link-build (Verilator, log $out/build.log)"
	exit 1
}
# The interface, compiled against the model's headers.
vinc=$(verilator --getenv VERILATOR_ROOT)/include
timeout 300 ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Werror -isystem "$out/obj" -isystem "$vinc" -isystem "$vinc/vltstd" \
	-DLINK_LOCAL_BASE=${base}u -DLINK_LOCAL_BYTES=${bytes}u -DLINK_WINDOW_BYTES=${window}u \
	-DLINK_GCLK_HZ=100000000u -c -o "$out/link.o" "$root/sim/verilator/link.cpp"
echo "$out/link.o $out/obj/Vatg_top__ALL.a $out/obj/libverilated.a -lpthread -latomic" >"$out/link.flags"
echo "PASS link-build"
