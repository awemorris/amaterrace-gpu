/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 * SPDX-License-Identifier: Zlib
 *
 * The CP firmware's layout (spec/gpu/cp/atg_cpu.md, address map): .text
 * in IMEM from 0 (32 KiB), the rest in DMEM from 0x0001_0000 (16 KiB).
 * The DMEM image holds .rodata and the original of .data (__data_load);
 * boot.S copies that to .data's place on every start, because the BRAM
 * keeps a running firmware's changes over RESET.  .data's place is a
 * fixed 1 KiB after its original.  The stack is at the DMEM's top.
 */
ENTRY(_start)

MEMORY
{
	imem (rx) : ORIGIN = 0x00000000, LENGTH = 32K
	dmem (rw) : ORIGIN = 0x00010000, LENGTH = 16K
}

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		*(.text*)
	} > imem

	.rodata : {
		LONG(0x31475441)	/* "ATG1": the image starts at the DMEM's first word */
		*(.rodata*)
		*(.srodata*)
	} > dmem

	. = ALIGN(16);
	__data_load = .;
	.data (__data_load + 0x400) : AT(__data_load) {
		__data_start = .;
		*(.data*)
		*(.sdata*)
		. = ALIGN(4);
		__data_end = .;
	} > dmem

	.bss (NOLOAD) : {
		. = ALIGN(4);
		__bss_start = .;
		*(.bss*)
		*(.sbss*)
		*(COMMON)
		. = ALIGN(4);
		__bss_end = .;
	} > dmem

	__stack_top = ORIGIN(dmem) + LENGTH(dmem);
	ASSERT(SIZEOF(.data) <= 0x400, "fw/cp: .data larger than its 1 KiB place")
	ASSERT(__bss_end + 0x800 <= __stack_top, "fw/cp: less than 2 KiB of stack")

	/DISCARD/ : {
		*(.comment)
		*(.riscv.attributes)
	}
}
