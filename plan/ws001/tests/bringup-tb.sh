#!/bin/sh
# Simulates platform/fpga/kc705/bringup against bringup-tb.v with Icarus
# Verilog (Debian iverilog) and prints PASS or FAIL.  The compiled model goes
# to BUILD (default build/kc705/sim).
#   plan/ws288/tests/bringup-tb.sh [BUILD]
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/../../.." && pwd)
build=${1:-$root/build/kc705/sim}
mkdir -p "$build"
iverilog -g2005 -Wall -o "$build/bringup-tb.vvp" \
	"$root/plan/ws288/tests/bringup-tb.v" "$root/platform/fpga/kc705/bringup/bringup.v"
out=$(timeout 60 vvp -n "$build/bringup-tb.vvp")
printf '%s\n' "$out"
case "$out" in
*"PASS bringup-tb"*) exit 0 ;;
*) exit 1 ;;
esac
