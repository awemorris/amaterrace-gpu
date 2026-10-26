#!/bin/sh
# The end-to-end test of the GHCI driver on the simulated KC705 GPU: libvulkan (as it is) and
# vkdemo's offscreen renderer, through a fake GPU core (ghci-e2e-core.c), the GHCI driver with its
# Vulkan executor and compiler on kernel stubs (ghci-e2e-kernel.c), to amaterrace-gpu's atg_top with
# the CP firmware in Verilator (sim/verilator/link.h, built by its link-build.sh).  One process, one
# thread, simulated time (ghci-e2e.h).  Then vkdemo's frame against the independent oracle
# (plan/ws014/tests/vkdemo_oracle.py), and that frame shown on the display controller (the link's
# controller names one test mode of vkdemo's size).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
#
# usage: plan/ws288/tests/ghci-e2e.sh [CASE...]   (from anywhere)
#        CASE: fill, copy, compute, vkdemo, display (default: all five, in that order; display shows
#        the frame vkdemo wrote, so it runs after vkdemo); build: only build
#        AMATERRACE_GPU=<checkout> picks the amaterrace-gpu tree (default ~/amaterrace-gpu).
#        GHCI_E2E_TRACE=1 builds the executor with its diagnostic trace (GHCI_VK_TRACE: every staged
#        record and every result that is not success, in the log).
#        GHCI_E2E_OUT=<dir> builds in that directory again (the Verilator build is then incremental)
#        instead of a new one.
# Needs cc, c++, glslc, python3 and verilator.  Everything goes in a new directory below build/tmp;
# nothing is removed.  Prints "PASS ghci-e2e" (and "PASS vkdemo-oracle" with vkdemo).  Timeouts:
# 1200 s for the Verilator build, 7200 s for the run (the vkdemo frame is the long one).
set -eu
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tests="$repo/plan/ws288/tests"
gpu=$(cd "${AMATERRACE_GPU:-$HOME/amaterrace-gpu}" && pwd)
mkdir -p "$repo/build/tmp"
if [ -n "${GHCI_E2E_OUT:-}" ]; then
	mkdir -p "$GHCI_E2E_OUT"
	out=$(cd "$GHCI_E2E_OUT" && pwd)
else
	out=$(mktemp -d "$repo/build/tmp/ghci-e2e.XXXXXX")
fi
# The compilers' own temporary files go there too, not to /tmp.
export TMPDIR="$out"
cases=${*:-fill copy compute vkdemo display}

# The GPU: atg_top in the KC705's shape with the committed firmware image.
"$gpu/sim/verilator/link-build.sh" "$out/link"
linkflags=$(cat "$out/link/link.flags")

# The compute case's module.
glslc --target-env=vulkan1.0 -o "$out/scale.spv" "$tests/ghci-e2e/scale.comp"

# The public Vulkan headers under the name libvulkan includes them by.
mkdir -p "$out/include" "$out/obj"
ln -sfn "$repo/include/libc/vulkan" "$out/include/vulkan"

sanitize="-fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer"
host="-std=gnu89 -D_GNU_SOURCE -O1 -g $sanitize -Wall -Wextra -Werror -I$out/include -I$repo/include"
kernel="-std=gnu11 -O1 -g $sanitize -DKERN_USER_ABI_LP64 -DCONFIG_GHCI_NATIVE=0 -I$repo/include -I$repo/src -I$repo \
-idirafter $repo/libc/include -Wall -Wextra -Werror -Wdeclaration-after-statement"
if [ -n "${GHCI_E2E_TRACE:-}" ]; then
	kernel="$kernel -DGHCI_VK_TRACE=1"
fi

# Compiles one source to an object named after its path (two sources share the name codec.c).
compile() {
	name=$(echo "$2" | sed "s|^$repo/||; s|/|_|g; s|\.c$|.o|")
	# shellcheck disable=SC2086
	cc $1 -c -o "$out/obj/$name" "$2"
	objects="$objects $out/obj/$name"
}
objects=

# libvulkan, as the system builds it, but its Wayland surface (ghci-e2e-wayland.c instead).
library="$repo/userland/desktop/libvulkan"
for source in $(grep -o 'userland/desktop/libvulkan/[a-z0-9-]*\.c' "$library/Makefile"); do
	case $source in
	*/wsi-wayland.c) ;;
	*) compile "$host -I$library" "$repo/$source" ;;
	esac
done
compile "$host" "$tests/ghci-e2e-wayland.c"

# vkdemo's renderer (offscreen) and what it links.
vkdemo="$repo/userland/tests/vkdemo"
for source in "$vkdemo/renderer.c" "$vkdemo/display.c" "$repo/userland/base/common/sha256.c"; do
	compile "$host -I$vkdemo" "$source"
done

# The driver, its executor, its compiler and the record codec the executor shares.
ghci="$repo/src/drivers/gpu/ghci"
for source in "$ghci/ghci.c" "$ghci/cp.c" "$ghci/firmware.c" "$ghci/memory.c" "$ghci/blit.c" "$ghci/native.c" "$ghci/check.c" \
	"$ghci/range.c" "$ghci/share.c" "$ghci/state.c" "$ghci/capset.c" "$ghci/jobs.c" "$ghci/isa.c" \
	"$ghci/display.c" "$ghci/display-scan.c" "$ghci/adv7511.c" \
	"$ghci"/vk/*.c "$ghci"/compiler/*.c "$repo/src/drivers/gpu/compiler/spirv.c" \
	"$repo/src/drivers/gpu/compiler/optimize.c" "$repo/src/drivers/gpu/i915/render/codec.c"; do
	compile "$kernel" "$source"
done

# The test's own parts: the kernel under the driver, the fake core, the cases.
compile "$kernel -I$gpu/sim/verilator" "$tests/ghci-e2e-kernel.c"
compile "$host -I$gpu/sim/verilator" "$tests/ghci-e2e-core.c"
compile "$host -I$gpu/sim/verilator -I$vkdemo" "$tests/ghci-e2e-main.c"

# One program; libvulkan's calls of the C library go to the fake core, and the cases' vkQueueSubmit
# (vkdemo's too) to the measure in ghci-e2e-main.c.
wrap="-Wl,--wrap=open,--wrap=close,--wrap=ioctl,--wrap=mmap,--wrap=munmap,--wrap=poll,--wrap=fcntl"
wrap="$wrap,--wrap=opendir,--wrap=readdir,--wrap=closedir,--wrap=clock_gettime,--wrap=nanosleep,--wrap=vkQueueSubmit"
# shellcheck disable=SC2086
c++ $sanitize -o "$out/ghci-e2e" $objects $linkflags $wrap -lm
if [ "$cases" = build ]; then
	echo "PASS ghci-e2e.sh build ($out)"
	exit 0
fi

# The cases.
arguments=
for name in $cases; do
	case $name in
	fill | copy) arguments="$arguments $name" ;;
	compute) arguments="$arguments compute=$out/scale.spv" ;;
	vkdemo) arguments="$arguments vkdemo=$out/vkdemo.ppm" ;;
	display) arguments="$arguments display=$out/vkdemo.ppm" ;;
	*) echo "FAIL ghci-e2e: unknown case $name"; exit 1 ;;
	esac
done
status=0
export ASAN_OPTIONS=detect_leaks=0
# shellcheck disable=SC2086
timeout 7200 "$out/ghci-e2e" $arguments >"$out/run.log" 2>&1 || status=1
cat "$out/run.log"

# vkdemo's frame against the oracle.
if [ -f "$out/vkdemo.ppm" ]; then
	PYTHONPATH="$repo/plan/ws014/tests" timeout 600 python3 -I -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import vkdemo_oracle
result = vkdemo_oracle.verify_pixels(vkdemo_oracle.read_ppm(sys.argv[2]), 1000)
print(json.dumps(result, sort_keys=True))
print(("PASS" if result["passed"] else "FAIL") + " vkdemo-oracle")
sys.exit(0 if result["passed"] else 1)
' "$repo/plan/ws014/tests" "$out/vkdemo.ppm" || status=1
fi

if [ "$status" -ne 0 ]; then
	echo "FAIL ghci-e2e.sh ($out)"
	exit 1
fi
echo "PASS ghci-e2e.sh ($out)"
