# atg_cpu integration test, run by sim/tb/atg_cpu_tb.v from the bitstream
# image (IMEM_INIT/DMEM_INIT).  It does what the CP firmware does with
# the control window: version and state, a class V packet taken by the
# interrupt, the packet's line read by DMA, its dwords (and a STATE word)
# sent as µops, DONE, a line written back by DMA to the address the host
# put in MBOX0, MBOX1 and RESULT, then the halt request parks it.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
	.equ PKT_ADDR, 0x00
	.equ PKT_DWORDS, 0x04
	.equ PKT_INFO, 0x08
	.equ DONE, 0x0C
	.equ UOP, 0x10
	.equ UOP_LAST, 0x14
	.equ STATE_IDX, 0x1C
	.equ STATE_DATA, 0x20
	.equ RESULT, 0x2C
	.equ IRQ, 0x30
	.equ IRQ_EN, 0x34
	.equ DMA_AMB, 0x40
	.equ DMA_MEM, 0x44
	.equ DMA_GO, 0x48
	.equ DMA_STATUS, 0x4C
	.equ FW_STATUS, 0x80
	.equ MBOX0, 0x84
	.equ MBOX1, 0x88
	.equ FW_VERSION, 0x94

	.section .text.start
	.globl _start
_start:
	j main
	.org 0x10
handler:
	lw x26, PKT_INFO(x31)	# takes the packet
	li x27, 1
	mret

main:
	lui x31, 0xF0000
	li x1, 0x00010002
	sw x1, FW_VERSION(x31)
	li x1, 0x100
	sw x1, FW_STATUS(x31)
	li x27, 0
	li x1, 1
	sw x1, IRQ_EN(x31)
1:	wfi
	beqz x27, 1b
	sw x0, IRQ_EN(x31)
	# The packet's line to DMEM 0x10100 (dword1 is line aligned here).
	lw x2, PKT_ADDR(x31)
	lw x3, PKT_DWORDS(x31)
	sw x2, DMA_AMB(x31)
	li x5, 0x100
	sw x5, DMA_MEM(x31)
	li x5, 1
	sw x5, DMA_GO(x31)
2:	lw x5, DMA_STATUS(x31)
	andi x6, x5, 1
	bnez x6, 2b
	andi x6, x5, 2
	bnez x6, fail
	# dwords 0..n-2 as UOP, a STATE word, the last dword as UOP_LAST.
	li x6, 0x10100
3:	addi x3, x3, -1
	lw x7, 0(x6)
	addi x6, x6, 4
	beqz x3, 4f
	sw x7, UOP(x31)
	j 3b
4:	li x8, 0x1E3
	sw x8, STATE_IDX(x31)
	lw x9, STATE_DATA(x31)
	sw x9, UOP(x31)
	sw x7, UOP_LAST(x31)
	sw x0, DONE(x31)
	# A line at DMEM 0x10200 to the host's address in MBOX0.
	li x6, 0x10200
	li x10, 8
	li x11, 0x5A000000
5:	sw x11, 0(x6)
	addi x11, x11, 0x111
	addi x6, x6, 4
	addi x10, x10, -1
	bnez x10, 5b
	lw x12, MBOX0(x31)
	sw x12, DMA_AMB(x31)
	li x5, 0x200
	sw x5, DMA_MEM(x31)
	li x5, 0x10001
	sw x5, DMA_GO(x31)
	li x13, 0xFF01
6:	lw x5, DMA_STATUS(x31)
	and x5, x5, x13
	bnez x5, 6b
	li x5, 0x600D0001
	sw x5, MBOX1(x31)
	sw x0, RESULT(x31)
	# Wait for the halt request, then park.
7:	lw x5, IRQ(x31)
	andi x5, x5, 4
	beqz x5, 7b
	li x5, 0x10200
	sw x5, FW_STATUS(x31)
8:	j 8b
fail:
	li x5, 0xBAD
	sw x5, MBOX1(x31)
9:	j 9b
