/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The firmware's own part of the heap, written when the driver lends the
 * heap: the identity buffer (word i holds i), which a vertex attribute
 * reads to give a program the vertex or the instance index (an interface
 * entry of kind 13), the built-in GSI1 programs (programs.inc), and words
 * the firmware waits on.
 */

#include "fw.h"

#include "programs.inc"

/* The built-in programs, in the order of enum fw_builtin_program. */
static const uint32_t *const builtin_code[FW_BUILTIN_PROGRAMS] = {
	fw_program_mask,
	fw_program_blit_vs,
	fw_program_blit_fs,
	fw_program_s8_to_image,
	fw_program_s8_from_image,
};
static const uint32_t builtin_words[FW_BUILTIN_PROGRAMS] = {
	FW_PROGRAM_MASK_WORDS,
	FW_PROGRAM_BLIT_VS_WORDS,
	FW_PROGRAM_BLIT_FS_WORDS,
	FW_PROGRAM_S8_TO_IMAGE_WORDS,
	FW_PROGRAM_S8_FROM_IMAGE_WORDS,
};

/*
 * The GPU address of the firmware's part of the heap (0 until the heap is
 * lent).
 */
static uint32_t builtin_base;

/*
 * Whether the identity buffer has been written since the heap was lent.
 */
static int builtin_identity_ready;

/*
 * Writes the built-in programs into the firmware's part of the heap the
 * driver lent (the identity buffer waits until it is first needed).
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_builtin_init(
	uint32_t base)
{
	uint32_t program;
	uint32_t offset;
	int error;

	/* The identity buffer is written when a pipeline first needs it. */
	builtin_base = base;
	builtin_identity_ready = 0;

	/* The programs, each at its own place (FW_BUILTIN_PROGRAM_BYTES apart). */
	for (program = 0; program < FW_BUILTIN_PROGRAMS; program++) {
		offset = FW_IDENTITY_WORDS * 4u + program * FW_BUILTIN_PROGRAM_BYTES;
		error = fw_copy_out(base + offset, builtin_code[program], builtin_words[program] * 4u);
		if (error != 0)
			return -1;
	}

	/* Succeeded: the firmware's part of the heap is ready. */
	return 0;
}

/*
 * Gives the GPU address of the identity buffer, writing it the first time.
 *
 * Returns 0 when the memory refused a line.
 */
uint32_t
fw_builtin_identity(void)
{
	uint32_t words[FW_BOUNCE_BYTES / 4u];
	uint32_t first;
	uint32_t index;
	int error;

	/* Written once per heap. */
	if (builtin_identity_ready)
		return builtin_base;

	/* Word i holds i, a bounce buffer at a time. */
	for (first = 0; first < FW_IDENTITY_WORDS; first += FW_BOUNCE_BYTES / 4u) {
		for (index = 0; index < FW_BOUNCE_BYTES / 4u; index++)
			words[index] = first + index;
		error = fw_copy_out(builtin_base + first * 4u, words, FW_BOUNCE_BYTES);
		if (error != 0)
			return 0;
	}

	/* Succeeded: the first part of the heap. */
	builtin_identity_ready = 1;
	return builtin_base;
}

/*
 * Gives the GPU address of a built-in program's code and its words.
 */
uint32_t
fw_builtin_program(
	uint32_t program,
	uint32_t *words)
{
	/* After the identity buffer, each at its own place. */
	*words = builtin_words[program];
	return builtin_base + FW_IDENTITY_WORDS * 4u + program * FW_BUILTIN_PROGRAM_BYTES;
}

/*
 * Gives the GPU address of the words the firmware waits on (after the
 * programs, one line).
 */
uint32_t
fw_builtin_wait_word(void)
{
	/* The line after the programs. */
	return builtin_base + FW_IDENTITY_WORDS * 4u + FW_BUILTIN_PROGRAMS * FW_BUILTIN_PROGRAM_BYTES;
}
