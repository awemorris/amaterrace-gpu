#!/bin/sh
# Host test of the GHCI driver's arithmetic on words (src/drivers/gpu/ghci/ghci-words.h):
# fences and their wrap, the ring's room and padding, the extended capability list, the
# allocator of GPU addresses, the driver's packets, the native command check, the capset
# record and the job markers (plan/ws288/tests/ghci-host-test.c); then the driver's device, ring,
# memory, transfers, faults, hangs, native command and display (DISP2) against a model of a GHCI GPU
# (plan/ws288/tests/ghci-driver-host-test.c); then the Vulkan executor's frames, staging, replies, fences, jobs
# and reset against the same model with a stand-in firmware (plan/ws288/tests/ghci-vk-host-test.c).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
#
# usage: plan/ws288/tests/ghci-host-test.sh   (from anywhere)
# Needs cc.  The program goes in a new directory below build/tmp; nothing is removed.
# A few seconds.
set -eu
repo=$(cd "$(dirname "$0")/../../.." && pwd)
tests="$repo/plan/ws288/tests"
ghci="$repo/src/drivers/gpu/ghci"
mkdir -p "$repo/build/tmp"
out=$(mktemp -d "$repo/build/tmp/ghci-host.XXXXXX")
# The compiler's own temporary files go there too, not to /tmp.
export TMPDIR="$out"
flags="-std=gnu11 -O1 -g -DKERN_USER_ABI_LP64 -I$repo/include -I$repo/src -idirafter $repo/libc/include \
-fsanitize=address,undefined -fno-sanitize=alignment -Wall -Wextra -Werror -Wdeclaration-after-statement"

cc $flags -o "$out/ghci-host-test" "$tests/ghci-host-test.c" "$ghci/check.c" "$ghci/range.c" \
	"$ghci/state.c" "$ghci/capset.c" "$ghci/jobs.c"

# The driver's files, with its Vulkan executor and the record codec the executor shares.
driver="$ghci/ghci.c $ghci/cp.c $ghci/firmware.c $ghci/memory.c $ghci/blit.c $ghci/native.c $ghci/check.c $ghci/range.c $ghci/share.c \
$ghci/display.c $ghci/display-scan.c $ghci/adv7511.c \
$ghci/state.c $ghci/capset.c $ghci/jobs.c $ghci/vk/vk-engine.c $ghci/vk/vk-node.c $ghci/vk/vk-session.c \
$ghci/vk/vk-stream.c $ghci/vk/vk-device.c $ghci/vk/vk-format.c $ghci/vk/vk-memory.c $ghci/vk/vk-program.c \
$ghci/vk/vk-relay.c $repo/src/drivers/gpu/i915/render/codec.c"

cc $flags -DCONFIG_GHCI_NATIVE=1 -o "$out/ghci-driver-host-test" "$tests/ghci-driver-host-test.c" $driver

cc $flags -DCONFIG_GHCI_NATIVE=1 -I"$tests" -o "$out/ghci-vk-host-test" "$tests/ghci-vk-host-test.c" $driver

status=0
timeout 120 "$out/ghci-host-test" || status=1
timeout 120 "$out/ghci-driver-host-test" || status=1
timeout 120 "$out/ghci-vk-host-test" || status=1
if [ "$status" -ne 0 ]; then
	echo "FAIL ghci-host-test ($out)"
	exit 1
fi
echo "PASS ghci-host-test ($out)"
