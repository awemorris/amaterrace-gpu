/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * GPU memory for the firmware: the window's line DMA, a cursor that reads
 * a byte range through a buffer of lines (the staging buffer, a packet),
 * and the store of the result records, which writes whole lines and so
 * reads a line before changing part of it.
 *
 * Order (design §2.4.8, the MC keeps no order between clients): a write
 * is complete when DMA_STATUS counts no unanswered write; fw_dma_write
 * waits for that, so whatever the firmware wrote is visible to every
 * other client before the firmware goes on.
 */

#include "fw.h"
#include "hw.h"

/*
 * The staging reader's lines and the GPU address of its first byte.
 *
 * One reader is active at a time (a packet, then the frame it names);
 * reader_base is the address of reader_buffer[0], or 1 (never line
 * aligned) when the buffer holds nothing.  reader_valid counts the bytes
 * read in.
 */
static uint8_t reader_buffer[FW_READER_LINES * FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));
static uint32_t reader_base = 1;
static uint32_t reader_valid;

/*
 * The line the store is changing, its address and whether it differs
 * from memory.
 *
 * store_base is 1 (never line aligned) when no line is held; the line is
 * written back when another line is stored to and at fw_store_flush,
 * which also lets it go.
 */
static uint8_t store_line[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));
static uint32_t store_base = 1;
static int store_dirty;

/*
 * The bounce lines of fw_copy_in and fw_copy_out, which let a caller's
 * buffer be anywhere in DMEM (on the stack, unaligned).
 */
static uint8_t bounce_lines[FW_BOUNCE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));

static int dma_wait(void);
static int reader_fill(struct fw_reader *reader, uint32_t address);
static void reader_bytes(struct fw_reader *reader, void *dst, uint32_t bytes) __attribute__((noinline));

/*
 * Reads whole lines of GPU memory into DMEM.
 *
 * Returns 0, or -1 when the memory refused a line (aperture or bus error).
 */
int
fw_dma_read(
	uint32_t address,
	void *dmem,
	uint32_t lines)
{
	int error;

#ifdef FW_HOST
	/* A host build: the test's memory. */
	error = hw_host_dma(address, dmem, lines, 0);
	if (error != 0)
		return -1;
	return 0;
#endif

	/* Points the DMA at the lines and the DMEM place and starts it. */
	hw_write(HW_DMA_AMB, address);
	hw_write(HW_DMA_MEM, (uint32_t)(uintptr_t)dmem - HW_DMEM_BASE);
	hw_write(HW_DMA_GO, lines);

	/* Waits for the copy and reports a refused line. */
	error = dma_wait();
	if (error != 0)
		return -1;

	/* Succeeded: the lines are in DMEM. */
	return 0;
}

/*
 * Writes whole lines of DMEM to GPU memory and waits for their answers.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_dma_write(
	uint32_t address,
	const void *dmem,
	uint32_t lines)
{
	int error;

#ifdef FW_HOST
	/* A host build: the test's memory. */
	error = hw_host_dma(address, (void *)(uintptr_t)dmem, lines, 1);
	if (error != 0)
		return -1;
	return 0;
#endif

	/* Points the DMA at the lines and the DMEM place and starts the write. */
	hw_write(HW_DMA_AMB, address);
	hw_write(HW_DMA_MEM, (uint32_t)(uintptr_t)dmem - HW_DMEM_BASE);
	hw_write(HW_DMA_GO, HW_DMA_GO_WRITE | lines);

	/* Waits until every write is answered and reports a refused line. */
	error = dma_wait();
	if (error != 0)
		return -1;

	/* Succeeded: the lines are in memory, visible to the other clients. */
	return 0;
}

/*
 * Reads whole lines of GPU memory into a line-aligned DMEM buffer, `bytes`
 * rounded up to whole lines.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_mem_read(
	uint32_t address,
	void *dmem,
	uint32_t bytes)
{
	uint32_t lines;
	int error;

	/* The lines that hold the bytes. */
	lines = (bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES;
	error = fw_dma_read(address, dmem, lines);
	if (error != 0)
		return -1;

	/* Succeeded: the bytes are in DMEM. */
	return 0;
}

/*
 * Writes a line-aligned DMEM buffer to whole lines of GPU memory, `bytes`
 * rounded up to whole lines, and waits for the answers.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_mem_write(
	uint32_t address,
	const void *dmem,
	uint32_t bytes)
{
	uint32_t lines;
	int error;

	/* The lines that hold the bytes. */
	lines = (bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES;
	error = fw_dma_write(address, dmem, lines);
	if (error != 0)
		return -1;

	/* Succeeded: the bytes are in memory, visible to the other clients. */
	return 0;
}

/*
 * Reads bytes of GPU memory that start a line (a heap block) into any
 * DMEM buffer, through the bounce lines.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_copy_in(
	uint32_t address,
	void *dst,
	uint32_t bytes)
{
	uint8_t *to;
	uint32_t part;
	int error;

	/* A bounce buffer's worth at a time. */
	to = dst;
	while (bytes > 0) {
		part = bytes;
		if (part > FW_BOUNCE_BYTES)
			part = FW_BOUNCE_BYTES;
		error = fw_mem_read(address, bounce_lines, part);
		if (error != 0)
			return -1;
		memcpy(to, bounce_lines, part);
		to += part;
		address += part;
		bytes -= part;
	}

	/* Succeeded: the bytes are in the buffer. */
	return 0;
}

/*
 * Writes any DMEM buffer to GPU memory that starts a line (a heap block),
 * through the bounce lines; the last line's bytes past the buffer are
 * written as zeros.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_copy_out(
	uint32_t address,
	const void *src,
	uint32_t bytes)
{
	const uint8_t *from;
	uint32_t part;
	int error;

	/* A bounce buffer's worth at a time; the tail of the last line is zero. */
	from = src;
	while (bytes > 0) {
		part = bytes;
		if (part > FW_BOUNCE_BYTES)
			part = FW_BOUNCE_BYTES;
		memset(bounce_lines, 0, FW_ROUND_LINES(part));
		memcpy(bounce_lines, from, part);
		error = fw_mem_write(address, bounce_lines, part);
		if (error != 0)
			return -1;
		from += part;
		address += part;
		bytes -= part;
	}

	/* Succeeded: the bytes are in memory. */
	return 0;
}

/*
 * Starts a cursor over bytes of GPU memory.
 */
void
fw_reader_init(
	struct fw_reader *reader,
	uint32_t address,
	uint32_t bytes)
{
	/*
	 * The range.  The buffer is emptied: the host may have rewritten the
	 * memory since the last packet (the ring and the staging are reused).
	 */
	reader_base = 1;
	reader->addr = address;
	reader->end = address + bytes;
	reader->error = 0;

	/* A range that wraps the address space cannot be read. */
	if (reader->end < address)
		reader->error = 1;
}

/*
 * Reads a little-endian u32 at the cursor.
 */
uint32_t
fw_reader_u32(
	struct fw_reader *reader)
{
	uint32_t value;
	uint32_t offset;

	/* The common case: an aligned word inside the buffer and the range. */
	offset = reader->addr - reader_base;
	if (!reader->error &&
	    (reader->addr & 3u) == 0 &&
	    reader_base != 1 &&
	    reader->addr >= reader_base &&
	    offset + 4u <= reader_valid &&
	    reader->end - reader->addr >= 4u) {
		value = *(const uint32_t *)(const void *)&reader_buffer[offset];
		reader->addr += 4;
		return value;
	}

	/* Takes the next four bytes through the refill. */
	value = 0;
	reader_bytes(reader, &value, 4);

	/* Succeeded (or 0 with the sticky error): the word. */
	return value;
}

/*
 * Reads a little-endian u64 at the cursor.
 */
uint64_t
fw_reader_u64(
	struct fw_reader *reader)
{
	uint32_t low;
	uint32_t high;

	/* The low word comes first on the wire. */
	low = fw_reader_u32(reader);
	high = fw_reader_u32(reader);

	/* Succeeded (or 0 with the sticky error): the value. */
	return (uint64_t)high << 32 | low;
}

/*
 * Reads a u64 that names a GPU address, which must fit 32 bits.
 */
uint32_t
fw_reader_address(
	struct fw_reader *reader)
{
	uint64_t value;

	/* Takes the u64 of the wire. */
	value = fw_reader_u64(reader);

	/* An address above 4 GiB is a malformed command for this GPU. */
	if ((value >> 32) != 0) {
		reader->error = 1;
		return 0;
	}

	/* Succeeded: the address. */
	return (uint32_t)value;
}

/*
 * Reads consecutive little-endian u32 at the cursor into an array.
 */
void
fw_reader_words(
	struct fw_reader *reader,
	uint32_t *dst,
	uint32_t count)
{
	uint32_t index;

	/* One word after the other (0 with the sticky error). */
	for (index = 0; index < count; index++)
		dst[index] = fw_reader_u32(reader);
}

/*
 * Reads an array's u64 element count, which must not pass `limit`.
 *
 * Returns the count (0 with the error set when it passes the limit).
 */
uint32_t
fw_reader_count(
	struct fw_reader *reader,
	uint32_t limit)
{
	uint64_t count;

	/* The count as the wire gives it. */
	count = fw_reader_u64(reader);
	if (count > limit) {
		reader->error = 1;
		return 0;
	}

	/* Succeeded: the count. */
	return (uint32_t)count;
}

/*
 * Moves the cursor past bytes (a string's characters, an opaque payload).
 */
void
fw_reader_skip(
	struct fw_reader *reader,
	uint32_t bytes)
{
	/* Nothing more after an error. */
	if (reader->error)
		return;

	/* Skipping past the range is a malformed command. */
	if (bytes > reader->end - reader->addr) {
		reader->error = 1;
		return;
	}

	/* The cursor moves; the buffer is refilled when it is read next. */
	reader->addr += bytes;
}

/*
 * Stores bytes into GPU memory through the line the store holds.
 *
 * Returns 0, or -1 when a line could not be read or written.
 */
int
fw_store(
	uint32_t address,
	const void *src,
	uint32_t bytes)
{
	const uint8_t *from;
	uint32_t line;
	uint32_t offset;
	uint32_t part;
	int error;

	/* Changes one line at a time. */
	from = src;
	while (bytes > 0) {
		line = address & ~(FW_LINE_BYTES - 1u);
		offset = address - line;
		part = FW_LINE_BYTES - offset;
		if (part > bytes)
			part = bytes;

		/* Another line: writes the held one back and reads this one. */
		if (line != store_base) {
			error = fw_store_flush();
			if (error != 0)
				return -1;

			error = fw_dma_read(line, store_line, 1);
			if (error != 0)
				return -1;

			store_base = line;
		}

		/* Changes the bytes of this line. */
		memcpy(&store_line[offset], from, part);
		store_dirty = 1;
		from += part;
		address += part;
		bytes -= part;
	}

	/* Succeeded: the bytes are in the held line. */
	return 0;
}

/*
 * Writes the line the store holds back to memory.
 *
 * Returns 0, or -1 when the write was refused.
 */
int
fw_store_flush(void)
{
	uint32_t line;
	int error;

	/*
	 * The line is let go: the host may change the result page between
	 * frames, so the next store reads it again.
	 */
	line = store_base;
	store_base = 1;

	/* Nothing changed since the last write. */
	if (!store_dirty)
		return 0;

	/* Writes the line and waits for its answer. */
	store_dirty = 0;
	error = fw_dma_write(line, store_line, 1);
	if (error != 0)
		return -1;

	/* Succeeded: the stored bytes are in memory. */
	return 0;
}

/* Waits until the DMA is idle and every write answered; reports its error flag. */
static int
dma_wait(void)
{
	uint32_t status;

	/* Polls the status until no copy runs and no write is unanswered. */
	do {
		status = hw_read(HW_DMA_STATUS);
	} while ((status & (HW_DMA_BUSY | HW_DMA_WRITES)) != 0);

	/* A refused line. */
	if ((status & HW_DMA_ERROR) != 0)
		return -1;

	/* Succeeded: the copy is complete. */
	return 0;
}

/* Reads the lines from the one holding address up to the range's end into the buffer. */
static int
reader_fill(
	struct fw_reader *reader,
	uint32_t address)
{
	uint32_t line;
	uint32_t lines;
	uint32_t last;
	int error;

	/* The buffer's lines, but none past the line of the range's last byte. */
	line = address & ~(FW_LINE_BYTES - 1u);
	last = (reader->end - 1u) & ~(FW_LINE_BYTES - 1u);
	lines = (last - line) / FW_LINE_BYTES + 1u;
	if (lines > FW_READER_LINES)
		lines = FW_READER_LINES;

	/* Reads them; a refused line leaves the buffer empty. */
	reader_base = 1;
	error = fw_dma_read(line, reader_buffer, lines);
	if (error != 0)
		return -1;

	/* Succeeded: the buffer holds the lines. */
	reader_base = line;
	reader_valid = lines * FW_LINE_BYTES;
	return 0;
}

/*
 * Copies bytes at the cursor out of the buffer, refilling it, and moves the
 * cursor.  Not inlined: fw_reader_u32's fast path stays a leaf without the
 * register saves this path needs.
 */
static void
reader_bytes(
	struct fw_reader *reader,
	void *dst,
	uint32_t bytes)
{
	uint8_t *to;
	uint32_t offset;
	uint32_t part;
	int error;

	/* Nothing more after an error. */
	if (reader->error)
		return;

	/* Reading past the range is a malformed command. */
	if (bytes > reader->end - reader->addr) {
		reader->error = 1;
		return;
	}

	/* Takes the bytes from the buffer, a refill at a time. */
	to = dst;
	while (bytes > 0) {
		if (reader_base == 1 ||
		    reader->addr < reader_base ||
		    reader->addr - reader_base >= reader_valid) {
			error = reader_fill(reader, reader->addr);
			if (error != 0) {
				reader->error = 1;
				return;
			}
		}

		/* As much as the buffer holds from the cursor. */
		offset = reader->addr - reader_base;
		part = reader_valid - offset;
		if (part > bytes)
			part = bytes;
		memcpy(to, &reader_buffer[offset], part);
		to += part;
		reader->addr += part;
		bytes -= part;
	}
}
