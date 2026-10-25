/*
 * Link script of the atg_cpu test programs: .text in IMEM at 0, data in
 * DMEM at 0x0002_0000 (spec/gpu/cp/atg_cpu.md, address map).
 * Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
 */
ENTRY(_start)
SECTIONS
{
	. = 0;
	.text : { *(.text.start) *(.text*) }
	. = 0x20000;
	.data : { *(.data*) *(.rodata*) *(.sdata*) *(.bss*) *(.sbss*) }
}
