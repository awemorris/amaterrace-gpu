# atg_cpu integration test, the image loaded through CPFW LOAD: shows its
# .data word (from the DMEM image) in MBOX3, a sign in MBOX2, then waits
# for MBOX0 = 1 and faults at 0x28 (the zero word after the loop).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
	.equ MBOX0, 0x84
	.equ MBOX2, 0x8C
	.equ MBOX3, 0x90

	.section .text.start
	.globl _start
_start:
	lui x31, 0xF0000
	lui x1, 0x10
	lw x2, 0(x1)
	sw x2, MBOX3(x31)
	li x3, 0x600D0002
	sw x3, MBOX2(x31)
	li x5, 1
1:	lw x4, MBOX0(x31)
	bne x4, x5, 1b
	.word 0

	.data
	.word 0xDA7A0001
