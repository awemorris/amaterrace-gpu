/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The µops: the class N packets the firmware gives the sequencer through
 * the window's UOP_FIFO, and the recordings of the command buffers, which
 * are chains of heap chunks holding the µop packets that a QUEUE_SUBMIT
 * replays.  The buffer copies and fills become blits.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* Pixels per row of a linear fill or copy: a 4 KiB row of 32-bit pixels. */
#define UOP_ROW_PIXELS 1024u

/* The largest blit height. */
#define UOP_MAX_ROWS 0xFFFFu

/* Words of one blit: SET_REG of the 11 BLT words, then BLIT. */
#define UOP_BLIT_WORDS 24u

/*
 * Words of the µop packet being written to the FIFO that are still to
 * come; 0 means the next word is a header.
 */
static uint32_t uop_left;

static void uop_emit(uint32_t word);
static int uop_blit(struct fw_object *cmdbuf, uint32_t op, uint32_t src, uint32_t dst, uint32_t stride, uint32_t width, uint32_t rows, uint32_t color);
static void uop_set(uint32_t *words, uint32_t *count, uint32_t index, uint32_t value);

/*
 * Gives whole µop packets to the sequencer.
 */
void
fw_uop_send(
	const uint32_t *words,
	uint32_t count)
{
	uint32_t index;

	/* One FIFO write per word; the last of each packet is marked. */
	for (index = 0; index < count; index++)
		uop_emit(words[index]);
}

/*
 * Appends whole µop packets to a command buffer's recording.
 *
 * Returns 0, or -1 when the heap is used up.
 */
int
fw_uop_record(
	struct fw_object *cmdbuf,
	const uint32_t *words,
	uint32_t count)
{
	uint32_t *chunk;
	uint32_t index;

	/* Appends word by word, linking a new chunk when the last is full. */
	for (index = 0; index < count; index++) {
		if (cmdbuf->last == NULL || cmdbuf->used == FW_CHUNK_WORDS - 1u) {
			chunk = fw_chunk_alloc();
			if (chunk == NULL)
				return -1;

			/* The chunk ends the chain. */
			if (cmdbuf->last == NULL) {
				cmdbuf->first = chunk;
			} else {
				cmdbuf->last[0] = (uint32_t)(uintptr_t)chunk;
			}

			cmdbuf->last = chunk;
			cmdbuf->used = 0;
		}

		/* Word 0 of a chunk is its link. */
		cmdbuf->last[1u + cmdbuf->used] = words[index];
		cmdbuf->used++;
	}

	/* Succeeded: the packets are in the recording. */
	return 0;
}

/*
 * Gives a command buffer's recorded µops to the sequencer.
 */
void
fw_uop_replay(
	struct fw_object *cmdbuf)
{
	uint32_t *chunk;
	uint32_t words;
	uint32_t index;

	/* Walks the chain; only the last chunk is partly used. */
	for (chunk = cmdbuf->first;
	     chunk != NULL;
	     chunk = (uint32_t *)(uintptr_t)chunk[0]) {
		words = FW_CHUNK_WORDS - 1u;
		if (chunk == cmdbuf->last)
			words = cmdbuf->used;
		for (index = 0; index < words; index++)
			uop_emit(chunk[1u + index]);
	}
}

/*
 * Empties a command buffer's recording.
 */
void
fw_uop_clear(
	struct fw_object *cmdbuf)
{
	uint32_t *chunk;
	uint32_t *next;

	/* Returns every chunk of the chain. */
	chunk = cmdbuf->first;
	while (chunk != NULL) {
		next = (uint32_t *)(uintptr_t)chunk[0];
		fw_chunk_free(chunk);
		chunk = next;
	}

	/* The recording is empty. */
	cmdbuf->first = NULL;
	cmdbuf->last = NULL;
	cmdbuf->used = 0;
}

/*
 * Records the blits that fill words of linear memory with a value.
 *
 * Returns 0, or -1 when the heap is used up.
 */
int
fw_uop_fill(
	struct fw_object *cmdbuf,
	uint32_t address,
	uint32_t words,
	uint32_t data)
{
	uint32_t rows;
	int error;

	/* Whole rows of UOP_ROW_PIXELS, then the rest as one short row. */
	while (words > 0) {
		rows = words / UOP_ROW_PIXELS;
		if (rows > UOP_MAX_ROWS)
			rows = UOP_MAX_ROWS;
		if (rows > 0) {
			error = uop_blit(cmdbuf, GHCI_BLT_FILL, 0, address, UOP_ROW_PIXELS * 4u, UOP_ROW_PIXELS, rows, data);
			if (error != 0)
				return -1;
			address += rows * UOP_ROW_PIXELS * 4u;
			words -= rows * UOP_ROW_PIXELS;
			continue;
		}

		/* The short row. */
		error = uop_blit(cmdbuf, GHCI_BLT_FILL, 0, address, words * 4u, words, 1, data);
		if (error != 0)
			return -1;
		words = 0;
	}

	/* Succeeded: the fill is recorded. */
	return 0;
}

/*
 * Records the blits that copy bytes of linear memory (no overlap).
 *
 * Returns 0, -1 when the heap is used up, or -2 when the bytes are not in
 * 16-bit units (the blitter's smallest pixel).
 */
int
fw_uop_copy(
	struct fw_object *cmdbuf,
	uint32_t src,
	uint32_t dst,
	uint32_t bytes)
{
	uint32_t op;
	uint32_t unit;
	uint32_t pixels;
	uint32_t rows;
	uint32_t row_bytes;
	int error;

	/* 32-bit pixels when everything is word aligned, else 16-bit ones. */
	if (((src | dst | bytes) & 3u) == 0) {
		op = GHCI_BLT_COPY;
		unit = 4;
	} else if (((src | dst | bytes) & 1u) == 0) {
		op = GHCI_BLT_COPY | GHCI_BLT_BPP16;
		unit = 2;
	} else {
		/* An odd byte needs a copy the blitter cannot do. */
		return -2;
	}

	/* Whole rows, then the rest as one short row. */
	pixels = bytes / unit;
	row_bytes = UOP_ROW_PIXELS * unit;
	while (pixels > 0) {
		rows = pixels / UOP_ROW_PIXELS;
		if (rows > UOP_MAX_ROWS)
			rows = UOP_MAX_ROWS;
		if (rows > 0) {
			error = uop_blit(cmdbuf, op, src, dst, row_bytes, UOP_ROW_PIXELS, rows, 0);
			if (error != 0)
				return -1;
			src += rows * row_bytes;
			dst += rows * row_bytes;
			pixels -= rows * UOP_ROW_PIXELS;
			continue;
		}

		/* The short row. */
		error = uop_blit(cmdbuf, op, src, dst, pixels * unit, pixels, 1, 0);
		if (error != 0)
			return -1;
		pixels = 0;
	}

	/* Succeeded: the copy is recorded. */
	return 0;
}

/* Writes one µop dword to the FIFO, marking the last word of its packet. */
static void
uop_emit(
	uint32_t word)
{
	/* A header opens a packet of [7:0] payload words. */
	if (uop_left == 0) {
		uop_left = word & 0xFFu;
	} else {
		uop_left--;
	}

	/* The packet's last word goes to UOP_LAST. */
	if (uop_left == 0) {
		hw_write(HW_UOP_LAST, word);
	} else {
		hw_write(HW_UOP, word);
	}
}

/* Records (or, without a command buffer, sends) one blit: its BLT state and BLIT. */
static int
uop_blit(
	struct fw_object *cmdbuf,
	uint32_t op,
	uint32_t src,
	uint32_t dst,
	uint32_t stride,
	uint32_t width,
	uint32_t rows,
	uint32_t color)
{
	uint32_t words[UOP_BLIT_WORDS];
	uint32_t count;
	uint32_t tag;
	int error;

	/* The µops carry the session's tag (FAULT_INFO names it on a fault). */
	tag = 0;
	if (cmdbuf != NULL)
		tag = cmdbuf->tag;

	/* SET_REG of every BLT word, so no earlier blit's state is left over. */
	count = 0;
	words[count++] = GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_SET_REG, tag, 0, 22);
	uop_set(words, &count, GHCI_S_BLT_OP, op);
	uop_set(words, &count, GHCI_S_BLT_DST_BASE, dst);
	uop_set(words, &count, GHCI_S_BLT_DST_STRIDE, stride);
	uop_set(words, &count, GHCI_S_BLT_SRC_BASE, src);
	uop_set(words, &count, GHCI_S_BLT_SRC_STRIDE, stride);
	uop_set(words, &count, GHCI_S_BLT_DST_XY, 0);
	uop_set(words, &count, GHCI_S_BLT_SRC_XY, 0);
	uop_set(words, &count, GHCI_S_BLT_SIZE, rows << 16 | width);
	uop_set(words, &count, GHCI_S_BLT_COLOR, color);
	uop_set(words, &count, GHCI_S_BLT_CLIP_MIN, 0);
	uop_set(words, &count, GHCI_S_BLT_CLIP_MAX, 0);

	/* BLIT, waiting for its end: the next command may read what it wrote. */
	words[count++] = GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_BLIT, tag, GHCI_BLIT_WAIT, 0);

	/* Without a command buffer the blit goes out now. */
	if (cmdbuf == NULL) {
		fw_uop_send(words, count);
		return 0;
	}

	/* Appends it to the recording. */
	error = fw_uop_record(cmdbuf, words, count);
	if (error != 0)
		return -1;

	/* Succeeded: the blit is recorded. */
	return 0;
}

/* Appends one (index, value) pair of a SET_REG. */
static void
uop_set(
	uint32_t *words,
	uint32_t *count,
	uint32_t index,
	uint32_t value)
{
	/* The STATE index, then its value. */
	words[(*count)++] = index;
	words[(*count)++] = value;
}
