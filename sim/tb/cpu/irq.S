# atg_cpu_core interrupt test.  The testbench raises irq N cycles after a
# store of N to IRQ_REQ and drops it on a store to IRQ_ACK.  The handler
# at 0x10 counts in x27 (x26 is its scratch).  Each part compares the
# result of code run under interrupts with the expected value, and the
# count of handler entries.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
	.equ TOHOST, 0
	.equ IRQ_REQ, 4
	.equ IRQ_ACK, 8

	.section .text.start
	.globl _start
_start:
	j main
	.org 0x10
handler:
	addi x27, x27, 1
	nop
	nop
	nop
	lui x26, 0xF0000
	sw x0, IRQ_ACK(x26)
	nop
	mret

main:
	li x27, 0
	lui x25, 0xF0000
	# 1: an interrupt in a loop.
	li x30, 1
	li x1, 5
	sw x1, IRQ_REQ(x25)
	li x2, 0
	li x3, 200
1:	add x2, x2, x3
	addi x3, x3, -1
	bnez x3, 1b
	li x31, 20100
	bne x2, x31, fail
	li x31, 1
2:	bne x27, x31, 2b
	# 2: WFI waits for the interrupt; the handler returns after it.
	li x30, 2
	li x1, 40
	sw x1, IRQ_REQ(x25)
	wfi
	li x31, 2
	bne x27, x31, fail
	# 3: interrupts at every distance from 1 to 40 cycles into a block
	# of jumps, branches, loads, stores and multiply/divide; the block's
	# result must equal the result without interrupts (x20).
	li x30, 3
	li x21, 0
	jal x1, block
	mv x20, x10
	li x22, 1
3:	sw x22, IRQ_REQ(x25)
	jal x1, block
	bne x10, x20, fail
	addi x31, x22, 2
4:	bne x27, x31, 4b
	addi x22, x22, 1
	li x31, 41
	bne x22, x31, 3b
	# 4: the block itself is right.
	li x30, 4
	li x31, 0x162c4952
	bne x20, x31, fail
	lui x29, 0xF0000
	li x31, 1
	sw x31, TOHOST(x29)
5:	j 5b
fail:
	lui x29, 0xF0000
	slli x30, x30, 1
	ori x30, x30, 1
	sw x30, TOHOST(x29)
6:	j 6b

# x10 = a checksum of mixed work; uses x10-x19, returns through x1.
block:
	li x10, 0x1234
	li x11, 0x10300
	li x12, 7
7:	sw x10, 0(x11)
	lh x13, 2(x11)
	lbu x14, 1(x11)
	add x10, x10, x13
	xor x10, x10, x14
	mul x15, x10, x12
	divu x16, x15, x12
	slli x17, x10, 5
	srai x18, x10, 3
	add x10, x17, x18
	add x10, x10, x16
	jal x19, 9f
	addi x10, x10, 1	# skipped
9:	addi x10, x10, 0x55
	addi x12, x12, -1
	bnez x12, 7b
	ret
