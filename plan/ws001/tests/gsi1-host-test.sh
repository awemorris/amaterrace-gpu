#!/bin/sh
# Host test of the GHCI shader compiler (SPIR-V through the shared IR to GSI1):
# the encoder against amaterrace-gpu's assembler, every module's code through
# the disassembler and back, and the modules the model runs on
# tools/gsi1model.py against the IR reference (plan/ws288/tests/gsi1-host-test.py).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
#
# usage: plan/ws288/tests/gsi1-host-test.sh   (from anywhere)
#        AMATERRACE_GPU=<checkout> picks the amaterrace-gpu tree (default ~/amaterrace-gpu).
# Needs cc, glslc and python3.  Everything goes in a new directory below build/tmp; nothing is
# removed.  About a minute.
set -eu
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tests="$repo/plan/ws288/tests"
tools="${AMATERRACE_GPU:-$HOME/amaterrace-gpu}/tools"
mkdir -p "$repo/build/tmp"
out=$(mktemp -d "$repo/build/tmp/gsi1-host.XXXXXX")
flags="-std=gnu11 -O1 -g -DKERN_USER_ABI_LP64 -I$repo/include -I$repo/src -I$repo -idirafter $repo/libc/include \
-fsanitize=address,undefined -fno-sanitize=alignment -Wall -Wextra -Werror -Wdeclaration-after-statement"
compiler="$repo/src/drivers/gpu/ghci/compiler"

# The harness: the compiler, the shared frontend and optimizer, the reference.
cc $flags -Wno-declaration-after-statement -o "$out/gsi1-host-test" "$tests/gsi1-host-test.c" "$tests/gsi1-reference.c" \
	"$compiler/gsi1-compile.c" "$compiler/gsi1-encode.c" "$compiler/gsi1-io.c" "$compiler/gsi1-memory.c" \
	"$compiler/gsi1-texture.c" "$compiler/gsi1-image.c" "$compiler/gsi1-schedule.c" "$compiler/gsi1-spill.c" \
	"$repo/src/drivers/gpu/compiler/spirv.c" "$repo/src/drivers/gpu/compiler/optimize.c" -lm

# The modules.
for source in "$tests"/gsi1/*.comp "$tests"/gsi1/*.vert "$tests"/gsi1/*.frag; do
	glslc --target-env=vulkan1.0 -o "$out/$(basename "$source").spv" "$source"
done

status=0
export ASAN_OPTIONS=detect_leaks=0
timeout 600 python3 -I "$tests/gsi1-host-test.py" "$out/gsi1-host-test" "$tools" "$out" "$out" || status=1
if [ "$status" -ne 0 ]; then
	echo "FAIL gsi1-host-test ($out)"
	exit 1
fi
echo "PASS gsi1-host-test ($out)"
