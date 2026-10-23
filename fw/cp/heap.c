/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The firmware's heap: fixed chunks of FW_CHUNK_WORDS words in DMEM,
 * handed out from a free list.  The recordings of the command buffers are
 * chains of chunks.  Design §2.4.7 puts the heap in GPU memory
 * (CP_HEAP_BASE/LIMIT); the window does not show those registers yet, so
 * this first heap is DMEM's (WS288 p017).
 */

#include "fw.h"

/* Chunks in the DMEM heap. */
#define HEAP_CHUNKS 48u

/*
 * The heap's chunks.
 *
 * A free chunk's first word links the next free one; the list is built at
 * start-up and a chunk is on it, or in exactly one recording.
 */
static uint32_t heap_chunks[HEAP_CHUNKS][FW_CHUNK_WORDS];

/*
 * The first free chunk, NULL when the heap is used up.
 */
static uint32_t *heap_free;

/*
 * Builds the free list of every chunk.
 */
void
fw_heap_init(void)
{
	uint32_t index;

	/* Links every chunk to the next one. */
	heap_free = NULL;
	for (index = HEAP_CHUNKS; index > 0; index--) {
		heap_chunks[index - 1u][0] = (uint32_t)(uintptr_t)heap_free;
		heap_free = heap_chunks[index - 1u];
	}
}

/*
 * Takes a chunk off the free list.
 *
 * Returns NULL when none is left.
 */
uint32_t *
fw_chunk_alloc(void)
{
	uint32_t *chunk;

	/* The heap is used up. */
	chunk = heap_free;
	if (chunk == NULL)
		return NULL;

	/* Unlinks it; the caller owns it with a cleared link. */
	heap_free = (uint32_t *)(uintptr_t)chunk[0];
	chunk[0] = 0;

	/* Succeeded: a chunk of FW_CHUNK_WORDS words. */
	return chunk;
}

/*
 * Puts a chunk back on the free list.
 */
void
fw_chunk_free(
	uint32_t *chunk)
{
	/* Links it in front of the list. */
	chunk[0] = (uint32_t)(uintptr_t)heap_free;
	heap_free = chunk;
}
