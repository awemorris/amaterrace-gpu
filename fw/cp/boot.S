# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
#
# The CP firmware's start: the core leaves reset at 0 (IMEM).  The DMEM
# BRAM keeps its contents over RESET, so every boot copies .data from
# its original in the image (__data_load) to its place, clears .bss,
# sets the stack at the DMEM's top and calls main.  The interrupt vector
# is at 0x10; the firmware polls and never enables an interrupt, so an
# entry there is reported as the TRAP state and the core waits.

	.section .text.start, "ax"
	.globl _start
_start:
	j boot

	.org 0x10
trap:
	lui t0, 0xF0000
	li t1, 0xEE00
	sw t1, 0x80(t0)
1:	j 1b

boot:
	la sp, __stack_top
	# .data from its original.
	la t0, __data_load
	la t1, __data_start
	la t2, __data_end
2:	bgeu t1, t2, 3f
	lw t3, 0(t0)
	sw t3, 0(t1)
	addi t0, t0, 4
	addi t1, t1, 4
	j 2b
	# .bss to zero.
3:	la t1, __bss_start
	la t2, __bss_end
4:	bgeu t1, t2, 5f
	sw zero, 0(t1)
	addi t1, t1, 4
	j 4b
5:	call main
6:	j 6b
