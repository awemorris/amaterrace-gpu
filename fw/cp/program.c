/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * GHCI_PROGRAM: a pipeline stage's program binary (docs/ghci.md section
 * 12.10).  Before it is accepted, the header and the interface table are
 * checked against the GPU (the magic, the version, the stage, the
 * registers, the code's place, every entry's slots, bank words and
 * registers); a program that fails gets VK_ERROR_INITIALIZATION_FAILED.
 * The program object keeps the header and the interface table in its
 * block and the code's address for the program range.
 */

#include "fw.h"
#include "ghci_frame.h"
#include "gsi1_isa.h"

/* The interface entries a program may have. */
#define PROGRAM_MAX_ENTRIES 64u

/* The GPU's limits a program is checked against. */
#define PROGRAM_NREGS 64u		/* registers per lane (KC705) */
#define PROGRAM_BANK_WORDS 256u		/* the constant bank */
#define PROGRAM_SLOTS 16u		/* texture slots per stage */
#define PROGRAM_LDS_BYTES 16384u	/* shared memory per workgroup (KC705) */
#define PROGRAM_KINDS 14u		/* the highest interface kind */

/*
 * The header and the interface table of the program being checked (too
 * large for the stack; one command is decoded at a time).
 */
static uint32_t program_table[GSI1_HEADER_WORDS + PROGRAM_MAX_ENTRIES * GSI1_IFACE_WORDS];

static int program_check(const uint32_t *header, uint32_t stage, uint32_t bytes);
static int program_check_entry(const uint32_t *entry, const uint32_t *header);

/* GHCI_PROGRAM: [u64 pipeline][u32 stage][u32 ISA][u64 address][u32 bytes][u32 flags]. */
void
fw_cmd_program(
	struct fw_command *command)
{
	uint32_t *table;
	struct fw_reader binary;
	struct fw_object *program;
	struct fw_object *old;
	uint64_t pipeline;
	uint32_t stage;
	uint32_t isa;
	uint32_t address;
	uint32_t bytes;
	uint32_t words;
	uint32_t index;
	uint32_t kind;
	uint32_t mode;
	int error;

	/* The arguments. */
	table = program_table;
	pipeline = fw_reader_u64(command->reader);
	stage = fw_reader_u32(command->reader);
	isa = fw_reader_u32(command->reader);
	address = fw_reader_address(command->reader);
	bytes = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* GSI1 is the GPU's own ISA; any other is not this driver's to give. */
	if (isa != GSI1_MAGIC) {
		command->status = FW_VK_ERROR_INCOMPATIBLE_DRIVER;
		return;
	}

	/* A stage the GPU runs, a binary of whole words that holds a header. */
	if (stage > GSI1_STAGE_COMPUTE || (address & 7u) != 0 || (bytes & 3u) != 0 ||
	    bytes < GSI1_HEADER_WORDS * 4u) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		return;
	}

	/*
	 * The header, then the interface table: the session's memory, so the
	 * reads are checked for its slot (no other cursor reads meanwhile).
	 */
	mode = fw_dma_mode(FW_DMA_CHK);
	fw_reader_init(&binary, address, bytes);
	for (index = 0; index < GSI1_HEADER_WORDS; index++)
		table[index] = fw_reader_u32(&binary);
	error = program_check(table, stage, bytes);
	if (binary.error || error != 0) {
		(void)fw_dma_mode(mode);
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		return;
	}

	/* The interface table, each entry checked. */
	fw_reader_init(&binary, address + table[GSI1_H_IFACE_OFFSET] * 4u,
		       table[GSI1_H_IFACE_ENTRIES] * GSI1_IFACE_WORDS * 4u);
	words = table[GSI1_H_IFACE_ENTRIES] * GSI1_IFACE_WORDS;
	for (index = 0; index < words; index++)
		table[GSI1_HEADER_WORDS + index] = fw_reader_u32(&binary);
	(void)fw_dma_mode(mode);
	if (binary.error) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		return;
	}
	for (index = 0; index < table[GSI1_H_IFACE_ENTRIES]; index++) {
		error = program_check_entry(&table[GSI1_HEADER_WORDS + index * GSI1_IFACE_WORDS], table);
		if (error != 0) {
			command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
			return;
		}
	}

	/* A new program of the stage replaces an earlier one of the pipeline. */
	kind = FW_OBJ_PROGRAM_VS + stage;
	old = fw_object_find(command->tag, pipeline, kind);
	if (old != NULL)
		fw_object_destroy(old);

	/* The program object: its block holds the header and the table. */
	program = fw_cmd_new_object(command, 0, pipeline, kind);
	if (program == NULL)
		return;
	error = fw_object_block(program, (GSI1_HEADER_WORDS + words) * 4u);
	if (error == 0)
		error = fw_copy_out(program->block, table, (GSI1_HEADER_WORDS + words) * 4u);
	if (error != 0) {
		fw_object_destroy(program);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* The code from the entry point, as the program range takes it. */
	program->a = address + table[GSI1_H_CODE_OFFSET] * 4u + table[GSI1_H_ENTRY] * 8u;
	program->b = table[GSI1_H_CODE_WORDS] - table[GSI1_H_ENTRY] * 2u;
	program->c = table[GSI1_H_IFACE_ENTRIES];
}

/* Checks a program's header against the stage, its binary's size and the GPU. */
static int
program_check(
	const uint32_t *header,
	uint32_t stage,
	uint32_t bytes)
{
	uint32_t words;
	uint32_t end;

	/* The magic, the version, the stage, the ISA version. */
	if (header[GSI1_H_MAGIC] != GSI1_MAGIC || header[GSI1_H_VERSION] != GSI1_VERSION)
		return -1;
	if (header[GSI1_H_STAGE] != stage || header[GSI1_H_ISA_MIN_VERSION] > GSI1_VERSION)
		return -1;

	/* The registers and the shared memory the GPU has. */
	if (header[GSI1_H_NREGS] > PROGRAM_NREGS || header[GSI1_H_LDS_BYTES] > PROGRAM_LDS_BYTES)
		return -1;
	if (header[GSI1_H_CONST_WORDS] > PROGRAM_BANK_WORDS)
		return -1;

	/* The flags the GPU knows (the systolic array is not there). */
	if ((header[GSI1_H_FLAGS] & ~0x7EFu) != 0)
		return -1;

	/* The code: whole instructions inside the binary, the entry inside the code. */
	words = bytes / 4u;
	end = header[GSI1_H_CODE_OFFSET] + header[GSI1_H_CODE_WORDS];
	if ((header[GSI1_H_CODE_OFFSET] & 1u) != 0 || (header[GSI1_H_CODE_WORDS] & 1u) != 0)
		return -1;
	if (header[GSI1_H_CODE_WORDS] == 0 || end < header[GSI1_H_CODE_OFFSET] || end > words)
		return -1;
	if (header[GSI1_H_ENTRY] >= header[GSI1_H_CODE_WORDS] / 2u)
		return -1;

	/* The interface table: at word 16, inside the binary, not too long for the firmware. */
	if (header[GSI1_H_IFACE_OFFSET] != GSI1_HEADER_WORDS ||
	    header[GSI1_H_IFACE_ENTRIES] > PROGRAM_MAX_ENTRIES ||
	    GSI1_HEADER_WORDS + header[GSI1_H_IFACE_ENTRIES] * GSI1_IFACE_WORDS > words)
		return -1;

	/* Succeeded: the header fits the GPU. */
	return 0;
}

/* Checks one interface entry: its kind, and its slots, bank words and registers. */
static int
program_check_entry(
	const uint32_t *entry,
	const uint32_t *header)
{
	uint32_t specific;
	uint32_t bank;
	uint32_t words;

	/* A known kind. */
	specific = entry[GSI1_IF_SPECIFIC];
	if (entry[GSI1_IF_KIND] == 0 || entry[GSI1_IF_KIND] > PROGRAM_KINDS)
		return -1;

	/* Per kind, what it names must exist. */
	bank = specific;
	words = 0;
	switch (entry[GSI1_IF_KIND]) {
	case GSI1_KIND_ATTRIBUTE:
	case GSI1_KIND_SYSTEM:
		if ((specific & 0x3Fu) >= header[GSI1_H_NREGS])
			return -1;
		return 0;
	case GSI1_KIND_UNIFORM_BLOCK:
		bank = specific & GSI1_UBO_BANK_MASK;
		words = (specific >> GSI1_UBO_WORDS_SHIFT) & GSI1_UBO_WORDS_MASK;
		break;
	case GSI1_KIND_SAMPLED_IMAGE:
		if ((specific & GSI1_TEX_SLOT_MASK) >= PROGRAM_SLOTS)
			return -1;
		if ((specific & GSI1_TEX_BUFFER) == 0)
			return 0;
		bank = (specific >> GSI1_TEX_COUNT_SHIFT) & GSI1_TEX_COUNT_MASK;
		words = 1;
		break;
	case GSI1_KIND_STORAGE_BUFFER:
	case GSI1_KIND_TEXEL_BUFFER:
	case GSI1_KIND_UNIFORM_MEMORY:
		words = 2;
		break;
	case GSI1_KIND_INPUT_ATTACHMENT:
		words = 3;
		break;
	case GSI1_KIND_STORAGE_IMAGE:
		words = 5;
		break;
	case GSI1_KIND_PUSH_CONSTANT:
		words = (header[GSI1_H_PUSH_BYTES] + 3u) / 4u;
		break;
	case GSI1_KIND_SCRATCH:
		/* The bank word of the address; the bytes per warp in 128-byte units. */
		if (specific == 0 || (specific & 127u) != 0 || specific > 0x100000u)
			return -1;
		bank = entry[GSI1_IF_BINDING];
		words = 1;
		break;
	default:
		return 0;
	}

	/* The bank words inside the bank. */
	if (bank >= PROGRAM_BANK_WORDS || words > PROGRAM_BANK_WORDS - bank)
		return -1;

	/* Succeeded: the entry fits the GPU. */
	return 0;
}
