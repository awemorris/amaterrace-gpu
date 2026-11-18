/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The heap blocks a session's work reaches (docs/ghci.md section 11.6,
 * design §17.8): a program's scratch memory, a recording's data, a query
 * pool's slots, an event's word.  The rest of the heap is the firmware's
 * own (its bytes in the protection table are 0: no protected session's
 * work reaches it).
 *
 * For a session that is not protected a visible block is an ordinary
 * one.  A protected session's blocks are whole 4 KiB granules it owns in
 * the protection table, written with zeros before the table gives them
 * to it (no data of an earlier user is left): a block of one line (an
 * event's word, a small query pool) is a line of a slab, a granule the
 * session holds and lends out line by line (a granule per event would use
 * up the heap); a larger one is granules of its own.  An empty slab goes
 * back to the heap.  The firmware never trusts what the session's work leaves in
 * them: it keeps no link or count there.
 */

#include "fw.h"

#define VISIBLE_GRANULE 4096u
#define VISIBLE_LINES (VISIBLE_GRANULE / FW_LINE_BYTES)
#define VISIBLE_MAP_WORDS ((VISIBLE_LINES + 31u) / 32u)

/* The slabs the firmware keeps for all the protected sessions. */
#define VISIBLE_SLABS 48u

/*
 * One slab: its granule's address (0: the entry is free), its session,
 * and a bit per line lent out.
 */
struct visible_slab {
	uint32_t base;
	uint32_t tag;
	uint32_t map[VISIBLE_MAP_WORDS];
};

/*
 * The slabs, in no order.
 */
static struct visible_slab visible_slabs[VISIBLE_SLABS];

/*
 * A line of zeros, the source of the writes that clear a granule.
 */
static uint8_t visible_zero[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));

static uint32_t visible_granules(uint32_t tag, uint32_t bytes);
static uint32_t visible_take(struct visible_slab *slab);
static int visible_empty(const struct visible_slab *slab);
static void visible_drop(struct visible_slab *slab);
static void visible_release(uint32_t tag, uint32_t address, uint32_t bytes);

/*
 * Takes a block of whole lines that the session's work may read and write.
 *
 * Returns the block's GPU address, or 0 when the heap, the session's
 * limit, the slabs or the protection table has no room for it.
 */
uint32_t
fw_heap_alloc_visible(
	uint32_t tag,
	uint32_t bytes)
{
	struct visible_slab *slab;
	uint32_t index;
	uint32_t first;
	uint32_t base;

	/* A session that is not protected: an ordinary block. */
	if (fw_prot_slot(tag) == 0)
		return fw_heap_alloc(tag, bytes);

	/* More than a line: granules of its own (none for 0 bytes). */
	if (bytes - 1u >= FW_LINE_BYTES)
		return visible_granules(tag, bytes);

	/* A line of one of the session's slabs. */
	for (index = 0; index < VISIBLE_SLABS; index++) {
		slab = &visible_slabs[index];
		if (slab->base == 0 || slab->tag != tag)
			continue;
		first = visible_take(slab);
		if (first != VISIBLE_LINES)
			return slab->base + first * FW_LINE_BYTES;
	}

	/* A free entry for a new slab. */
	for (index = 0; index < VISIBLE_SLABS; index++) {
		if (visible_slabs[index].base == 0)
			break;
	}
	if (index == VISIBLE_SLABS)
		return 0;

	/* The slab's granule, cleared and given to the session. */
	base = visible_granules(tag, VISIBLE_GRANULE);
	if (base == 0)
		return 0;
	slab = &visible_slabs[index];
	memset(slab, 0, sizeof(*slab));
	slab->base = base;
	slab->tag = tag;

	/* Succeeded: the slab's first line. */
	first = visible_take(slab);
	return base + first * FW_LINE_BYTES;
}

/*
 * Gives a block of fw_heap_alloc_visible back (`bytes` as it was taken).
 */
void
fw_heap_free_visible(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes)
{
	struct visible_slab *slab;
	uint32_t index;
	uint32_t line;

	/* Nothing to give back. */
	if (address == 0 || bytes == 0)
		return;

	/* A session that is not protected: an ordinary block. */
	if (fw_prot_slot(tag) == 0) {
		fw_heap_free(tag, address, bytes);
		return;
	}

	/* Granules of its own: no longer the session's, then free. */
	if (bytes > FW_LINE_BYTES) {
		visible_release(tag, address, bytes);
		return;
	}

	/* The slab that lent the lines. */
	for (index = 0; index < VISIBLE_SLABS; index++) {
		slab = &visible_slabs[index];
		if (slab->base != 0 && slab->tag == tag && slab->base == (address & ~(VISIBLE_GRANULE - 1u)))
			break;
	}
	if (index == VISIBLE_SLABS)
		return;

	/* The line is free; an empty slab goes back to the heap. */
	line = (address - slab->base) / FW_LINE_BYTES;
	slab->map[line / 32u] &= ~(1u << (line % 32u));
	if (visible_empty(slab))
		visible_drop(slab);
}

/*
 * Gives back every slab a closing session still holds (its objects have
 * returned their blocks; a slab left is a block nothing returned).
 */
void
fw_heap_close_visible(
	uint32_t tag)
{
	struct visible_slab *slab;
	uint32_t index;

	/* Each of the session's slabs. */
	for (index = 0; index < VISIBLE_SLABS; index++) {
		slab = &visible_slabs[index];
		if (slab->base != 0 && slab->tag == tag)
			visible_drop(slab);
	}
}

/*
 * Forgets every slab (the heap is lent again: the firmware's state starts
 * over).
 */
void
fw_heap_init_visible(void)
{
	/* No slab. */
	memset(visible_slabs, 0, sizeof(visible_slabs));
}

/*
 * Takes whole granules for a protected session, writes them with zeros
 * and gives them to it in the table.  Returns the address, or 0.
 */
static uint32_t
visible_granules(
	uint32_t tag,
	uint32_t bytes)
{
	uint32_t granules;
	uint32_t base;
	uint32_t line;
	int error;

	/* Aligned granules of the heap (the session's limit pays for them). */
	granules = (bytes + VISIBLE_GRANULE - 1u) & ~(VISIBLE_GRANULE - 1u);
	base = fw_heap_alloc_aligned(tag, granules, VISIBLE_GRANULE);
	if (base == 0)
		return 0;

	/* Zeros first, while no session's work reaches them (their bytes are 0). */
	error = 0;
	for (line = 0; line < granules && error == 0; line += FW_LINE_BYTES)
		error = fw_dma_write(base + line, visible_zero, 1);

	/* Then the table gives them to the session. */
	if (error == 0)
		error = fw_prot_own(tag, base, granules, 0) - 1;	/* 1: owned */
	if (error != 0) {
		fw_heap_free(tag, base, granules);
		return 0;
	}

	/* Succeeded: the session's granules. */
	return base;
}

/* Marks a free line of a slab used; VISIBLE_LINES when none is free. */
static uint32_t
visible_take(
	struct visible_slab *slab)
{
	uint32_t line;

	/* The first free line. */
	for (line = 0; line < VISIBLE_LINES; line++) {
		if ((slab->map[line / 32u] & (1u << (line % 32u))) == 0)
			break;
	}

	/* It is used (none: the slab is full). */
	if (line < VISIBLE_LINES)
		slab->map[line / 32u] |= 1u << (line % 32u);
	return line;
}

/* Reports whether a slab lends no line. */
static int
visible_empty(
	const struct visible_slab *slab)
{
	uint32_t index;

	/* Any bit set is a line lent out. */
	for (index = 0; index < VISIBLE_MAP_WORDS; index++) {
		if (slab->map[index] != 0)
			return 0;
	}

	/* Succeeded: nothing is lent. */
	return 1;
}

/* Gives a slab's granule back to the heap; the entry is free. */
static void
visible_drop(
	struct visible_slab *slab)
{
	/* The granule, then the entry. */
	visible_release(slab->tag, slab->base, VISIBLE_GRANULE);
	slab->base = 0;
}

/* Gives whole granules back: no longer the session's in the table, then free. */
static void
visible_release(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes)
{
	uint32_t granules;

	/* The granules the block took. */
	granules = (bytes + VISIBLE_GRANULE - 1u) & ~(VISIBLE_GRANULE - 1u);
	fw_prot_disown(tag, address, granules);
	fw_heap_free(tag, address, granules);
}
