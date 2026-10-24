#!/bin/sh
# Builds the CP firmware for the host (FW_HOST: the window and the DMA are
# fwhost.c's) with the tests of fwtest.c and runs them; prints "PASS
# fwtest.<case>" per case and "PASS fwtest" at the end, exit status 1 on
# a failure.  Needs a host C compiler (cc); the build goes to
# build/fw-host/.  About ten seconds.
#   fw/cp/tests/run.sh
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../../.." && pwd)
src=$root/fw/cp
out=$root/build/fw-host
mkdir -p "$out"
srcs=
for c in "$src"/*.c; do
	case $(basename "$c") in
	main.c | lib.c) ;;
	*) srcs="$srcs $c" ;;
	esac
done
# shellcheck disable=SC2086
timeout 120 cc -std=c99 -O1 -g -DFW_HOST -DFW_LINE_BYTES=64u -I"$root/include" -I"$src" \
	-Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined \
	-fno-sanitize-recover=undefined -o "$out/fwtest" $srcs "$src/tests/fwhost.c" "$src/tests/fwtest.c"
timeout 120 "$out/fwtest"
