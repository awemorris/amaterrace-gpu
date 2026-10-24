/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The transfers of buffers: vkCmdFillBuffer, vkCmdCopyBuffer and
 * vkCmdUpdateBuffer as blits, and the blit µops every transfer uses.  A
 * blit writes every BLT word (CTRL.RESET forgets the blitter's state) and
 * waits for its end, so the next µop sees what it wrote.
 */

#include "fw.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* Pixels per row of a linear fill or copy. */
#define XFER_ROW_PIXELS 1024u

/* The largest blit height. */
#define XFER_MAX_ROWS 0xFFFFu

/* Words of an update's data per data packet. */
#define XFER_UPDATE_WORDS 240u

/* Vulkan's VK_WHOLE_SIZE. */
#define XFER_WHOLE_SIZE (~(uint64_t)0)

/* The STATE indices of the blitter's colour words above the first (CAPS[30]). */
#define XFER_S_BLT_COLOR1 0x00Cu

static int xfer_linear(uint32_t op, uint32_t src, uint32_t dst, uint32_t bytes, uint32_t pixel, uint32_t color);
static uint32_t xfer_pixel_bytes(uint32_t src, uint32_t dst, uint32_t bytes);

/*
 * Gives the BLT_OP bits of a pixel size (1, 2, 4, 8 or 16 bytes).
 */
uint32_t
fw_blt_pixel(
	uint32_t bytes)
{
	/* [9:8] 0 32 bits, 1 16, 2 64, 3 8; 128 bits are [13] with [9:8] 0. */
	switch (bytes) {
	case 1:
		return 3u << 8;
	case 2:
		return 1u << 8;
	case 8:
		return 2u << 8;
	case 16:
		return 1u << 13;
	default:
		return 0;
	}
}

/*
 * Builds one blit: every BLT word, then BLIT waiting for its end.
 */
void
fw_blt_emit(
	const struct fw_blt *blt)
{
	uint32_t index;

	/* The blitter's words 0x000-0x00B, and the colour's upper words. */
	fw_emit_set(GHCI_S_BLT_OP, blt->op);
	fw_emit_set(GHCI_S_BLT_DST_BASE, blt->dst);
	fw_emit_set(GHCI_S_BLT_DST_STRIDE, blt->dst_stride);
	fw_emit_set(GHCI_S_BLT_SRC_BASE, blt->src);
	fw_emit_set(GHCI_S_BLT_SRC_STRIDE, blt->src_stride);
	fw_emit_set(GHCI_S_BLT_DST_XY, blt->dst_xy);
	fw_emit_set(GHCI_S_BLT_SRC_XY, blt->src_xy);
	fw_emit_set(GHCI_S_BLT_SIZE, blt->size);
	fw_emit_set(GHCI_S_BLT_COLOR, blt->color[0]);
	fw_emit_set(GHCI_S_BLT_CLIP_MIN, blt->clip_min);
	fw_emit_set(GHCI_S_BLT_CLIP_MAX, blt->clip_max);
	fw_emit_set(GHCI_S_BLT_RESOLVE, blt->resolve);
	for (index = 1; index < 4u; index++)
		fw_emit_set(XFER_S_BLT_COLOR1 + index - 1u, blt->color[index]);

	/* BLIT, waiting for its end: the next command may read what it wrote. */
	fw_emit_op(GHCI_OP_BLIT, GHCI_BLIT_WAIT, NULL, 0);
}

/* CMD_FILL_BUFFER: [cb][buffer][u64 offset][u64 size][u32 data]. */
void
fw_cmd_fill_buffer(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	uint64_t cmdbuf_id;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t size;
	uint32_t data;
	int error;

	/* The arguments. */
	cmdbuf_id = fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	offset = fw_reader_u64(command->reader);
	size = fw_reader_u64(command->reader);
	data = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Records only into a recording command buffer. */
	cmdbuf = fw_cmd_recording(command, cmdbuf_id);
	if (cmdbuf == NULL)
		return;

	/* A bound buffer, the range inside it, in whole words. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offset > buffer->b || (offset & 3u) != 0) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* VK_WHOLE_SIZE is the rest of the buffer, down to whole words. */
	if (size == XFER_WHOLE_SIZE)
		size = (buffer->b - offset) & ~(uint64_t)3;
	if (size > buffer->b - offset || (size & 3u) != 0) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The blits of the fill. */
	fw_emit_begin(cmdbuf, command->tag);
	(void)xfer_linear(GHCI_BLT_FILL, 0, buffer->a + (uint32_t)offset, (uint32_t)size, 4, data);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_COPY_BUFFER: [cb][source][destination][u32 count][u64 count][VkBufferCopy...]. */
void
fw_cmd_copy_buffer(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *src;
	struct fw_object *dst;
	uint64_t cmdbuf_id;
	uint64_t src_id;
	uint64_t dst_id;
	uint64_t count;
	uint64_t index;
	uint64_t src_offset;
	uint64_t dst_offset;
	uint64_t size;
	uint32_t from;
	uint32_t to;
	uint32_t pixel;
	int error;

	/* The command buffer, the buffers and the region count. */
	cmdbuf_id = fw_reader_u64(command->reader);
	src_id = fw_reader_u64(command->reader);
	dst_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* Records only into a recording command buffer; the regions are read anyway. */
	cmdbuf = fw_cmd_recording(command, cmdbuf_id);
	src = fw_object_find(command->tag, src_id, FW_OBJ_BUFFER);
	dst = fw_object_find(command->tag, dst_id, FW_OBJ_BUFFER);
	if (cmdbuf != NULL &&
	    (src == NULL || dst == NULL ||
	     (src->flags & FW_OBJF_BOUND) == 0 || (dst->flags & FW_OBJF_BOUND) == 0))
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);

	/* Each region: read, check, record. */
	if (cmdbuf != NULL)
		fw_emit_begin(cmdbuf, command->tag);
	for (index = 0; index < count; index++) {
		src_offset = fw_reader_u64(command->reader);
		dst_offset = fw_reader_u64(command->reader);
		size = fw_reader_u64(command->reader);
		if (command->reader->error)
			break;
		if (cmdbuf == NULL || (int32_t)cmdbuf->c != FW_VK_SUCCESS)
			continue;

		/* Both ranges inside their buffers. */
		if (src_offset > src->b ||
		    size > src->b - src_offset ||
		    dst_offset > dst->b ||
		    size > dst->b - dst_offset) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			continue;
		}

		/* The widest pixel the addresses and the size allow. */
		from = src->a + (uint32_t)src_offset;
		to = dst->a + (uint32_t)dst_offset;
		pixel = xfer_pixel_bytes(from, to, (uint32_t)size);
		(void)xfer_linear(GHCI_BLT_COPY, from, to, (uint32_t)size, pixel, 0);
	}

	/* The blits of the regions. */
	if (cmdbuf == NULL)
		return;
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_UPDATE_BUFFER: [cb][buffer][u64 offset][u64 size][u64 size][the bytes]. */
void
fw_cmd_update_buffer(
	struct fw_command *command)
{
	uint32_t words[XFER_UPDATE_WORDS];
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	uint64_t cmdbuf_id;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t size;
	uint64_t bytes;
	uint32_t address;
	uint32_t data;
	uint32_t part;
	uint32_t index;
	int failed;
	int error;

	/* The command buffer, the buffer, the range and the data's size. */
	cmdbuf_id = fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	offset = fw_reader_u64(command->reader);
	size = fw_reader_u64(command->reader);
	bytes = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* At most 65536 bytes in whole words (Vulkan's rule); the wire's size agrees. */
	if (bytes != size || size > 65536u || (size & 3u) != 0 || (offset & 3u) != 0) {
		command->reader->error = 1;
		return;
	}

	/* Records only into a recording command buffer, a bound buffer, the range inside it. */
	cmdbuf = fw_cmd_recording(command, cmdbuf_id);
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	failed = 0;
	if (cmdbuf == NULL) {
		failed = 1;
	} else if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 ||
		   offset > buffer->b || size > buffer->b - offset) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		failed = 1;
	}

	/* The data, a packet of words at a time, each copied by a blit. */
	if (!failed)
		fw_emit_begin(cmdbuf, command->tag);
	address = 0;
	if (buffer != NULL)
		address = buffer->a + (uint32_t)offset;
	while (size > 0) {
		part = (uint32_t)size;
		if (part > XFER_UPDATE_WORDS * 4u)
			part = XFER_UPDATE_WORDS * 4u;
		for (index = 0; index < part / 4u; index++)
			words[index] = fw_reader_u32(command->reader);
		size -= part;
		if (command->reader->error || failed)
			continue;

		/* The words in the recording, and the blit that copies them. */
		data = fw_emit_data(words, part / 4u);
		if (data != 0)
			(void)xfer_linear(GHCI_BLT_COPY, data, address, part, 4, 0);
		address += part;
	}

	/* The recorded data and blits. */
	if (failed)
		return;
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/*
 * Builds the blits that fill or copy linear bytes (no overlap) in pixels
 * of `pixel` bytes: rows of XFER_ROW_PIXELS, then the rest as one row.
 */
static int
xfer_linear(
	uint32_t op,
	uint32_t src,
	uint32_t dst,
	uint32_t bytes,
	uint32_t pixel,
	uint32_t color)
{
	struct fw_blt blt;
	uint32_t pixels;
	uint32_t rows;
	uint32_t row_bytes;

	/* The blit that does not change from row to row. */
	memset(&blt, 0, sizeof(blt));
	blt.op = op | fw_blt_pixel(pixel);
	blt.color[0] = color;

	/* Whole rows, then the short row. */
	pixels = bytes / pixel;
	row_bytes = XFER_ROW_PIXELS * pixel;
	while (pixels > 0) {
		rows = pixels / XFER_ROW_PIXELS;
		if (rows > XFER_MAX_ROWS)
			rows = XFER_MAX_ROWS;
		blt.src = src;
		blt.dst = dst;
		if (rows > 0) {
			blt.dst_stride = row_bytes;
			blt.src_stride = row_bytes;
			blt.size = rows << 16 | XFER_ROW_PIXELS;
			fw_blt_emit(&blt);
			src += rows * row_bytes;
			dst += rows * row_bytes;
			pixels -= rows * XFER_ROW_PIXELS;
			continue;
		}

		/* The short row. */
		blt.dst_stride = pixels * pixel;
		blt.src_stride = pixels * pixel;
		blt.size = 1u << 16 | pixels;
		fw_blt_emit(&blt);
		pixels = 0;
	}

	/* Succeeded: the blits are built. */
	return 0;
}

/* The widest pixel (16, 8, 4, 2 or 1 bytes) both addresses and the size are multiples of. */
static uint32_t
xfer_pixel_bytes(
	uint32_t src,
	uint32_t dst,
	uint32_t bytes)
{
	uint32_t bits;
	uint32_t pixel;

	/* The common low bits. */
	bits = src | dst | bytes;

	/* From 16 bytes down. */
	for (pixel = 16; pixel > 1u; pixel /= 2u) {
		if ((bits & (pixel - 1u)) == 0)
			return pixel;
	}

	/* Bytes. */
	return 1;
}
