# atg_cpu_core fault test.  The testbench writes the case number to DMEM
# 0x10000 before reset; the program jumps to case n at 0x100 + 16 n,
# whose first instruction faults (case 7: the jump lands outside IMEM).
# The store to TOHOST after each must never happen.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
	.section .text.start
	.globl _start
_start:
	lui x1, 0x10
	lw x2, 0(x1)
	lui x29, 0xF0000
	li x31, 3
	slli x3, x2, 4
	addi x3, x3, 0x100
	jr x3

	.macro case n, insn:vararg
	.org 0x100 + 16 * \n
	\insn
	sw x31, 0(x29)
	.endm

	case 0, .word 0x00000000	# illegal (all zero)
	case 1, ecall
	case 2, ebreak
	case 3, csrrw x0, mstatus, x0
	case 4, lw x5, 1(x1)	# misaligned load
	case 5, sh x0, 1(x1)	# misaligned store
	case 6, jalr x0, 2(x1)	# misaligned jump target
	case 7, jalr x0, 0(x1)	# target 0x10000: outside IMEM
	case 8, .word 0x40001033	# SLL with funct7 0x20
	case 9, .word 0x00003083	# LD (RV64)
	.org 0x100 + 16 * 10
	fence.i	# a no-op, then
	.word 0x0000000b	# custom-0: illegal at 0x1a4
	sw x31, 0(x29)
