#!/bin/sh
# Builds the CP firmware (fw/cp/) into the BRAM init images of atg_cpu:
# fw/cp/images/atg1-cp-BOARD.imem.hex (.text, IMEM from 0, 8192 words)
# and .dmem.hex (.rodata and the original of .data, DMEM from 0x0001_0000,
# 4096 words), one 32-bit word per line ($readmemh), for BOARD zybo
# (32-byte AMB lines) and kc705 (64).  The images are committed, so the
# simulation and the Vivado build do not need a compiler; run this after
# changing the firmware.  Also writes atg1-cp-BOARD.bin (the IMEM image
# for CPFW_IBASE) next to the ELF.
#   tools/fw-build.sh          (CLANG_BIN=dir with clang, ld.lld, llvm-objcopy)
# Uses the shared LLVM read-only (no compiler-rt: fw/cp/lib.c has the
# helpers); intermediate files go to build/fw-cp/.  Prints each image's
# used bytes.  Each tool call has a 60 s timeout.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
bin=${CLANG_BIN:-/home/awe/zedBSD-claude1/build/llvm/bin}
src=$root/fw/cp
img=$src/images
out=$root/build/fw-cp
mkdir -p "$out" "$img"
flags="--target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -mno-relax -msmall-data-limit=0
	-O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -fno-common -std=c99
	-Wall -Wextra -Werror -I$root/include -I$src"
# hex FILE.bin WORDS OUT: little-endian words, padded with zero words.
hex() {
	size=$(wc -c <"$1")
	pad=$(( (4 - size % 4) % 4 ))
	[ "$pad" -gt 0 ] && head -c "$pad" /dev/zero >>"$1"
	words=$(( (size + pad) / 4 ))
	[ "$words" -le "$2" ] || { echo "fw-build: $1 has $words words, more than $2" >&2; exit 1; }
	od -An -v -tx4 -w4 "$1" | tr -d ' ' >"$3"
	[ "$words" -lt "$2" ] && yes 00000000 | head -n $(( $2 - words )) >>"$3"
	echo "$words"
}
for board in zybo kc705; do
	line=32
	[ $board = kc705 ] && line=64
	o=$out/$board
	mkdir -p "$o"
	objs=
	for c in "$src"/*.c "$src"/*.S; do
		n=$(basename "$c")
		# shellcheck disable=SC2086
		timeout 60 "$bin/clang" $flags -DFW_LINE_BYTES=${line}u -c "$c" -o "$o/$n.o"
		objs="$objs $o/$n.o"
	done
	# shellcheck disable=SC2086
	timeout 60 "$bin/ld.lld" -T "$src/link.ld" --gc-sections $objs -o "$o/atg1-cp.elf"
	timeout 60 "$bin/llvm-objcopy" -O binary --only-section=.text "$o/atg1-cp.elf" "$o/atg1-cp.bin"
	timeout 60 "$bin/llvm-objcopy" -O binary --only-section=.rodata --only-section=.data \
		"$o/atg1-cp.elf" "$o/atg1-cp.dmem.bin"
	cp "$o/atg1-cp.bin" "$o/imem.bin"
	iw=$(hex "$o/imem.bin" 8192 "$img/atg1-cp-$board.imem.hex")
	dw=$(hex "$o/atg1-cp.dmem.bin" 4096 "$img/atg1-cp-$board.dmem.hex")
	echo "fw-build: $board IMEM $((iw * 4)) bytes, DMEM image $((dw * 4)) bytes"
done
