/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Occlusion queries (docs/ghci.md section 7.3, micro-op QUERY).  A query
 * pool's slots are in the heap, 16 bytes each: {u64 result, u32
 * available, u32 0}; CREATE_QUERY_POOL's result gives their address in
 * aux, so the driver reads them for vkGetQueryPoolResults.
 *
 * vkCmdBeginQuery clears the counter and starts counting (ROP_CTRL[0]);
 * vkCmdEndQuery writes the counter to the slot after every earlier draw
 * has finished (QUERY), stops counting and marks the slot available
 * (RESULT); vkCmdResetQueryPool fills the slots with zeros;
 * vkCmdCopyQueryPoolResults is a marker: the replay waits for the units
 * and copies the slots as the flags say.  Pipeline statistics and
 * timestamps are not offered.
 */

#include "fw.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* A slot's bytes and fields. */
#define QUERY_SLOT_BYTES 16u
#define QUERY_TYPE_OCCLUSION 0u

/* VkQueryResultFlags. */
#define QUERY_64_BIT 0x1u
#define QUERY_WITH_AVAILABILITY 0x4u
#define QUERY_PARTIAL 0x8u

/* QUERY's flags: [0] only clear the counter. */
#define QUERY_CLEAR 0x1u

/* The ROP_CTRL words: fp32 blend constants, with or without counting. */
#define QUERY_ROP_CTRL 0x2u
#define QUERY_ROP_COUNT 0x1u

static struct fw_object *query_pool(struct fw_command *command, struct fw_object *cmdbuf, uint64_t id, uint32_t first, uint32_t count);

/* CREATE_QUERY_POOL: the create form with VkQueryPoolCreateInfo; aux is the slots' address. */
void
fw_cmd_create_query_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint32_t zeros[FW_BOUNCE_BYTES / 4u];
	uint64_t device;
	uint64_t id;
	uint32_t type;
	uint32_t queries;
	uint32_t bytes;
	uint32_t done;
	uint32_t part;
	int error;

	/* [sType][u64 0][flags][type][count][statistics]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	type = fw_reader_u32(command->reader);
	queries = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* Occlusion queries only. */
	if (type != QUERY_TYPE_OCCLUSION || queries == 0 || queries > 0x10000u) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		return;
	}

	/* The pool and its slots (the QUERY µops write them: a visible block), zero (unavailable). */
	pool = fw_cmd_new_object(command, device, id, FW_OBJ_QUERY_POOL);
	if (pool == NULL)
		return;
	bytes = queries * QUERY_SLOT_BYTES;
	error = fw_object_block_visible(pool, bytes);
	memset(zeros, 0, sizeof(zeros));
	for (done = 0; done < bytes && error == 0; done += part) {
		part = bytes - done;
		if (part > FW_BOUNCE_BYTES)
			part = FW_BOUNCE_BYTES;
		error = fw_copy_out(pool->block + done, zeros, part);
	}
	if (error != 0) {
		fw_object_destroy(pool);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}
	pool->a = queries;

	/* The driver learns where the slots are. */
	command->aux = pool->block;
}

/* DESTROY_QUERY_POOL: the destroy form. */
void
fw_cmd_destroy_query_pool(
	struct fw_command *command)
{
	/* Forgets the pool. */
	fw_cmd_destroy_object(command, FW_OBJ_QUERY_POOL);
}

/* CMD_BEGIN_QUERY: [cb][pool][query][flags]. */
void
fw_cmd_begin_query(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *pool;
	struct fw_rstate *state;
	uint32_t address;
	uint64_t id;
	uint64_t pool_id;
	uint32_t query;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	pool_id = fw_reader_u64(command->reader);
	query = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	pool = query_pool(command, cmdbuf, pool_id, query, 1);
	if (pool == NULL)
		return;

	/* The counter cleared (no wait: it does not move while not counting), counting on. */
	address = 0;
	fw_emit_begin(cmdbuf, command->tag);
	fw_emit_op(GHCI_OP_QUERY, QUERY_CLEAR, &address, 1);
	fw_emit_set(GHCI_S_ROP_CTRL, QUERY_ROP_CTRL | QUERY_ROP_COUNT);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
	state->occlusion = 1;
	state->query_pool = pool_id;
	state->query = query;
}

/* CMD_END_QUERY: [cb][pool][query]. */
void
fw_cmd_end_query(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *pool;
	struct fw_rstate *state;
	uint32_t payload[3];
	uint64_t id;
	uint64_t pool_id;
	uint32_t query;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	pool_id = fw_reader_u64(command->reader);
	query = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	pool = query_pool(command, cmdbuf, pool_id, query, 1);
	if (pool == NULL)
		return;

	/* The count after the earlier draws, counting off, then the slot available. */
	payload[0] = pool->block + query * QUERY_SLOT_BYTES;
	fw_emit_begin(cmdbuf, command->tag);
	fw_emit_op(GHCI_OP_QUERY, 0, payload, 1);
	fw_emit_set(GHCI_S_ROP_CTRL, QUERY_ROP_CTRL);
	payload[0] = pool->block + query * QUERY_SLOT_BYTES + 8u;
	payload[1] = 1;
	payload[2] = 0;
	fw_emit_op(GHCI_OP_RESULT, 0, payload, 3);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
	state->occlusion = 0;
	state->query_pool = 0;
}

/* CMD_RESET_QUERY_POOL: [cb][pool][first][count]. */
void
fw_cmd_reset_query_pool(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *pool;
	uint32_t rect[4];
	uint32_t zero[4];
	uint64_t id;
	uint64_t pool_id;
	uint32_t first;
	uint32_t count;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	pool_id = fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	count = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf == NULL)
		return;
	pool = query_pool(command, cmdbuf, pool_id, first, count);
	if (pool == NULL || count == 0)
		return;

	/* The slots zero: one row of 16-byte pixels. */
	memset(zero, 0, sizeof(zero));
	rect[0] = 0;
	rect[1] = 0;
	rect[2] = count;
	rect[3] = 1;
	fw_emit_begin(cmdbuf, command->tag);
	fw_blt_fill_rect(pool->block + first * QUERY_SLOT_BYTES, count * QUERY_SLOT_BYTES, QUERY_SLOT_BYTES, 1,
			 rect, zero, 0);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_COPY_QUERY_POOL_RESULTS: [cb][pool][first][count][buffer][u64 offset][u64 stride][flags]. */
void
fw_cmd_copy_query_pool_results(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *pool;
	struct fw_object *buffer;
	uint32_t payload[5];
	uint64_t id;
	uint64_t pool_id;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t stride;
	uint32_t first;
	uint32_t count;
	uint32_t flags;
	uint32_t bytes;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	pool_id = fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	count = fw_reader_u32(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	offset = fw_reader_u64(command->reader);
	stride = fw_reader_u64(command->reader);
	flags = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf == NULL)
		return;
	pool = query_pool(command, cmdbuf, pool_id, first, count);
	if (pool == NULL || count == 0)
		return;

	/* A bound buffer that holds every query's values. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	bytes = 4;
	if ((flags & QUERY_64_BIT) != 0)
		bytes = 8;
	if ((flags & QUERY_WITH_AVAILABILITY) != 0)
		bytes *= 2u;
	if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || (offset & 3u) != 0 ||
	    offset > buffer->b || stride > 0x10000u ||
	    (count - 1u) * stride + bytes > buffer->b - offset) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The marker: the replay copies once the units are done. */
	payload[0] = pool->block + first * QUERY_SLOT_BYTES;
	payload[1] = count;
	payload[2] = buffer->a + (uint32_t)offset;
	payload[3] = (uint32_t)stride;
	payload[4] = flags;
	fw_emit_begin(cmdbuf, command->tag);
	fw_emit_marker(FW_MARK_QUERY_COPY, payload, 5);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_WRITE_TIMESTAMP: timestamps are not offered (timestampValidBits 0). */
void
fw_cmd_write_timestamp(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t id;

	/* [cb][stage][pool][query]. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf != NULL)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_FEATURE_NOT_PRESENT);
}

/*
 * The replay's copy of query results: [slots][count][destination][stride]
 * [flags].  Every earlier query has ended once the units are done.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_query_copy(
	const uint32_t *payload,
	uint32_t count)
{
	uint32_t line[FW_LINE_BYTES / 4u] __attribute__((aligned(FW_LINE_BYTES)));
	uint32_t values[4];
	uint32_t query;
	uint32_t slot;
	uint32_t base;
	uint32_t words;
	uint32_t available;
	uint32_t flags;
	uint32_t mode;
	int error;

	/* The marker's words. */
	if (count < 5u)
		return -1;
	flags = payload[4];

	/* The units have finished the earlier queries. */
	error = fw_wait_units();
	if (error != 0)
		return -1;

	/* Each query: its value (if available, or PARTIAL), then its availability. */
	for (query = 0; query < payload[1]; query++) {
		slot = payload[0] + query * QUERY_SLOT_BYTES;
		base = slot & ~(FW_LINE_BYTES - 1u);
		error = fw_dma_read(base, line, 1);
		if (error != 0)
			return -1;
		available = line[(slot - base) / 4u + 2u];
		words = 0;
		values[words++] = line[(slot - base) / 4u];
		if ((flags & QUERY_64_BIT) != 0)
			values[words++] = line[(slot - base) / 4u + 1u];
		if ((flags & QUERY_WITH_AVAILABILITY) != 0) {
			values[words++] = available;
			if ((flags & QUERY_64_BIT) != 0)
				values[words++] = 0;
		}

		/*
		 * An unavailable value is not written without PARTIAL; the
		 * availability is.  The destination is the session's buffer, so
		 * the store's lines are checked for its slot.
		 */
		mode = fw_dma_mode(FW_DMA_CHK);
		if (available != 0 || (flags & QUERY_PARTIAL) != 0) {
			error = fw_store(payload[2] + query * payload[3], values, words * 4u);
		} else if ((flags & QUERY_WITH_AVAILABILITY) != 0) {
			error = fw_store(payload[2] + query * payload[3] + (words / 2u) * 4u, &values[words / 2u],
					 (words / 2u) * 4u);
		}
		(void)fw_dma_mode(mode);
		if (error != 0)
			return -1;
	}

	/* Succeeded once the values are in memory (the held line keeps its mode). */
	error = fw_store_flush();
	if (error != 0)
		return -1;
	return 0;
}

/* Finds a query pool of the session with the queries inside it; fails the recording otherwise. */
static struct fw_object *
query_pool(
	struct fw_command *command,
	struct fw_object *cmdbuf,
	uint64_t id,
	uint32_t first,
	uint32_t count)
{
	struct fw_object *pool;

	/* The pool, and first + count inside it. */
	pool = fw_object_find(command->tag, id, FW_OBJ_QUERY_POOL);
	if (pool == NULL || first > pool->a || count > pool->a - first) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return NULL;
	}

	/* Succeeded: the pool. */
	return pool;
}
