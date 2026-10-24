#!/bin/sh
# Builds and runs the Verilator system harness (harness.cpp around atg_top
# in its default shape: 32-byte lines, 64-bit AXI).  Output under
# build/verilator/ (not in git).
#   sim/verilator/run.sh
# Prints "PASS verilator" on success.  Timeout: 600 s for the build, 300 s
# for the run.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../.." && pwd)
cd "$root"
LC_ALL=C
export LC_ALL
out=$root/build/verilator
mkdir -p "$out"
command -v verilator >/dev/null || { echo "verilator: not installed" >&2; exit 1; }
timeout 600 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -Mdir "$out/obj" -o "$out/atg_top_sim" \
	-CFLAGS "-I$root/include -O1" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build.log" 2>&1 || {
	tail -30 "$out/build.log" >&2
	echo "FAIL verilator (build, log $out/build.log)"
	exit 1
}
timeout 300 "$out/atg_top_sim"

# The raster scene: HAS_RX and HAS_ROP, the colour buffer to a PNG.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GHAS_RX=1 -GHAS_ROP=1 -Mdir "$out/obj-raster" -o "$out/atg_top_raster" \
	-CFLAGS "-I$root/include -O1 -DRASTER" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build-raster.log" 2>&1 || {
	tail -30 "$out/build-raster.log" >&2
	echo "FAIL verilator raster (build, log $out/build-raster.log)"
	exit 1
}
timeout 600 "$out/atg_top_raster"

# The shaded scene: HAS_VF, NSU 1, HAS_RX, HAS_ROP, the colour buffer to a PNG.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GHAS_VF=1 -GNSU=1 -GHAS_RX=1 -GHAS_ROP=1 -Mdir "$out/obj-shade" \
	-o "$out/atg_top_shade" -CFLAGS "-I$root/include -O1 -DSHADE" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build-shade.log" 2>&1 || {
	tail -30 "$out/build-shade.log" >&2
	echo "FAIL verilator shade (build, log $out/build-shade.log)"
	exit 1
}
timeout 600 "$out/atg_top_shade"

# The textured scene: HAS_VF, NSU 1, HAS_RX, HAS_TU, HAS_ROP, the colour buffer to a PNG.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GHAS_VF=1 -GNSU=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 \
	-Mdir "$out/obj-tex" -o "$out/atg_top_tex" -CFLAGS "-I$root/include -O1 -DTEX" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build-tex.log" 2>&1 || {
	tail -30 "$out/build-tex.log" >&2
	echo "FAIL verilator tex (build, log $out/build-tex.log)"
	exit 1
}
timeout 600 "$out/atg_top_tex"

# The multisampling scene: HAS_VF, NSU 1, HAS_RX, HAS_TU, HAS_ROP, MS4, the
# resolved image to a PNG.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GHAS_VF=1 -GNSU=1 -GHAS_RX=1 -GHAS_TU=1 -GHAS_ROP=1 -GMS4=1 \
	-Mdir "$out/obj-msaa" -o "$out/atg_top_msaa" -CFLAGS "-I$root/include -O1 -DMSAA" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build-msaa.log" 2>&1 || {
	tail -30 "$out/build-msaa.log" >&2
	echo "FAIL verilator msaa (build, log $out/build-msaa.log)"
	exit 1
}
timeout 600 "$out/atg_top_msaa"

# The compute scene: NSU 1, GSI1 programs dispatched through
# the ring, the memory against tools/gsi1model.py, an ISA fault.
timeout 900 verilator --cc --exe --build -j 4 -Wall -Iinclude \
	--top-module atg_top -GNSU=1 -Mdir "$out/obj-compute" -o "$out/atg_top_compute" \
	-CFLAGS "-I$root/include -O1 -DCOMPUTE" \
	$(find rtl -name '*.v' | sort) "$root/sim/verilator/harness.cpp" >"$out/build-compute.log" 2>&1 || {
	tail -30 "$out/build-compute.log" >&2
	echo "FAIL verilator compute (build, log $out/build-compute.log)"
	exit 1
}
timeout 600 "$out/atg_top_compute"
