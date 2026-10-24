/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The recordings of the command buffers: chains of heap chunks holding
 * the µop packets the recorded commands became, and markers for the work
 * the replay does itself.  A packet never spans two chunks.
 *
 * The last chunk of the command buffer being recorded is cached in DMEM
 * and written back when another chunk or another command buffer is
 * needed, before a replay and at the end of a frame.  The replay reads a
 * chain a few lines at a time and gives the class N packets to the FIFO.
 *
 * Also the recording state of the command buffer being recorded (the
 * bound pipelines, descriptor sets, buffers, dynamic state and render
 * pass): one in DMEM at a time, the others in their command buffers'
 * blocks.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_packets.h"

/* Lines of a chunk the replay reads at a time. */
#define REPLAY_LINES 4u
#define REPLAY_WORDS (REPLAY_LINES * FW_LINE_BYTES / 4u)

/*
 * The cached chunk: its words, its GPU address, the command buffer whose
 * last chunk it is (NULL: none), and whether it differs from memory.
 */
static uint32_t record_chunk[FW_CHUNK_WORDS] __attribute__((aligned(FW_LINE_BYTES)));
static uint32_t record_address;
static struct fw_object *record_owner;
static int record_dirty;

/*
 * The replay's lines of the chunk being replayed.
 */
static uint32_t replay_words[REPLAY_WORDS] __attribute__((aligned(FW_LINE_BYTES)));

/*
 * The recording state in DMEM and the command buffer it belongs to (NULL:
 * none); the other recording command buffers keep theirs in their blocks.
 */
static union {
	struct fw_rstate state;
	uint8_t lines[FW_ROUND_LINES(sizeof(struct fw_rstate))];
} record_state_lines __attribute__((aligned(FW_LINE_BYTES)));
static struct fw_object *record_state_owner;


static int record_cache(struct fw_object *cmdbuf);
static int record_new_chunk(struct fw_object *cmdbuf);
static int replay_chunk(uint32_t chunk, uint32_t *next);

/*
 * Appends whole µop packets (or one marker) to a command buffer's
 * recording.
 *
 * Returns 0, or -1 when the heap has no room for a new chunk.
 */
int
fw_record_words(
	struct fw_object *cmdbuf,
	const uint32_t *words,
	uint32_t count)
{
	uint32_t address;
	int error;

	/* The packet, wherever it lands. */
	error = fw_record_words_at(cmdbuf, words, count, &address);
	if (error != 0)
		return -1;

	/* Succeeded: the packet is recorded. */
	return 0;
}

/*
 * Appends data to a command buffer's recording, where the units can read
 * it when the recording runs (the source of an update, a constant bank):
 * a padding packet [FW_MARK_DATA][words] that the replay skips.  `address`
 * gets the GPU address of the first word.
 *
 * Returns 0, or -1 when the data is longer than a chunk holds or the heap
 * has no room.
 */
int
fw_record_data(
	struct fw_object *cmdbuf,
	const uint32_t *words,
	uint32_t count,
	uint32_t *address)
{
	uint32_t head[2];
	uint32_t used;
	uint32_t packet;
	int error;

	/* The header and the code before the data, in one chunk. */
	if (count + 2u > FW_CHUNK_PAYLOAD)
		return -1;
	error = record_cache(cmdbuf);
	if (error != 0)
		return -1;
	used = record_chunk[1];
	if (used + count + 2u > FW_CHUNK_PAYLOAD) {
		error = record_new_chunk(cmdbuf);
		if (error != 0)
			return -1;
	}

	/* The header, the code, then the data. */
	head[0] = GHCI_PKT_PAD(count + 1u);
	head[1] = FW_MARK_DATA;
	error = fw_record_words_at(cmdbuf, head, 2, &packet);
	if (error != 0)
		return -1;
	used = record_chunk[1];
	memcpy(&record_chunk[FW_CHUNK_HEAD + used], words, count * 4u);
	record_chunk[1] = used + count;
	record_dirty = 1;

	/* Succeeded: the data follows the two words. */
	*address = packet + 8u;
	return 0;
}

/*
 * Appends whole µop packets to a command buffer's recording and gives the
 * GPU address of the first word.
 *
 * Returns 0, or -1 when the heap has no room for a new chunk.
 */
int
fw_record_words_at(
	struct fw_object *cmdbuf,
	const uint32_t *words,
	uint32_t count,
	uint32_t *address)
{
	uint32_t used;
	int error;

	/* A packet longer than a chunk cannot be recorded. */
	if (count > FW_CHUNK_PAYLOAD)
		return -1;

	/* The command buffer's last chunk in the cache. */
	error = record_cache(cmdbuf);
	if (error != 0)
		return -1;

	/* A packet that does not fit the chunk starts the next one. */
	used = record_chunk[1];
	if (used + count > FW_CHUNK_PAYLOAD) {
		error = record_new_chunk(cmdbuf);
		if (error != 0)
			return -1;
		used = 0;
	}

	/* Appends the words. */
	memcpy(&record_chunk[FW_CHUNK_HEAD + used], words, count * 4u);
	record_chunk[1] = used + count;
	record_dirty = 1;

	/* Succeeded: the packet is recorded at its place in the chunk. */
	*address = record_address + (FW_CHUNK_HEAD + used) * 4u;
	return 0;
}

/*
 * Empties a command buffer's recording and gives its chunks back.
 */
void
fw_record_clear(
	struct fw_object *cmdbuf)
{
	uint32_t chunk;
	uint32_t next;
	int error;

	/* The cache's copy of the last chunk is dropped, not written. */
	if (record_owner == cmdbuf) {
		record_owner = NULL;
		record_dirty = 0;
	}

	/* So is the recording state. */
	if (record_state_owner == cmdbuf)
		record_state_owner = NULL;

	/*
	 * Walks the chain; each chunk's first line links the next.  The last
	 * chunk's link is not read: it may never have been written back.
	 */
	chunk = cmdbuf->a;
	while (chunk != 0) {
		next = 0;
		if (chunk != cmdbuf->b) {
			error = fw_dma_read(chunk, replay_words, 1);
			if (error == 0)
				next = replay_words[0];
		}
		fw_heap_free(cmdbuf->tag, chunk, FW_CHUNK_BYTES);
		chunk = next;
	}

	/* The recording is empty. */
	cmdbuf->a = 0;
	cmdbuf->b = 0;
}

/*
 * Writes the cached chunk back to memory.
 *
 * Returns 0, or -1 when the write was refused.
 */
int
fw_record_flush(void)
{
	int error;

	/* Nothing changed since the last write. */
	if (record_owner == NULL || !record_dirty)
		return 0;

	/* Writes the whole chunk and waits for its answers. */
	record_dirty = 0;
	error = fw_mem_write(record_address, record_chunk, FW_CHUNK_BYTES);
	if (error != 0)
		return -1;

	/* Succeeded: the chunk in memory is current. */
	return 0;
}

/*
 * Gives a command buffer's recorded µops to the sequencer and runs its
 * markers.
 *
 * Returns 0, or -1 when a chunk could not be read or a marker failed.
 */
int
fw_record_replay(
	struct fw_object *cmdbuf,
	uint32_t depth)
{
	uint32_t chunk;
	uint32_t next;
	int error;

	/* The chain in memory is complete once the cache is written back. */
	(void)depth;
	error = fw_record_flush();
	if (error != 0)
		return -1;

	/* Each chunk in order. */
	for (chunk = cmdbuf->a; chunk != 0; chunk = next) {
		error = replay_chunk(chunk, &next);
		if (error != 0)
			return -1;
	}

	/* Succeeded: the recording went to the FIFO. */
	return 0;
}

/*
 * Appends a secondary command buffer's recording to a primary's: every
 * packet but the data, which the copied packets still find in the
 * secondary's chunks (Vulkan makes the primary invalid when the secondary
 * is reset or freed).
 *
 * Returns 0, or -1 when a chunk could not be read or the heap is full.
 */
int
fw_record_append(
	struct fw_object *cmdbuf,
	struct fw_object *secondary)
{
	uint32_t packet[FW_EMIT_PAYLOAD + 4u + 2u * 64u];
	uint32_t chunk;
	uint32_t next;
	uint32_t used;
	uint32_t position;
	uint32_t base;
	uint32_t word;
	uint32_t left;
	uint32_t taken;
	int skipping;
	int error;

	/* The secondary's chunks in memory are complete once the cache is written back. */
	error = fw_record_flush();
	if (error != 0)
		return -1;

	/* Each chunk, a few lines at a time, each packet whole. */
	left = 0;
	taken = 0;
	skipping = 0;
	for (chunk = secondary->a; chunk != 0; chunk = next) {
		error = fw_mem_read(chunk, replay_words, sizeof(replay_words));
		if (error != 0)
			return -1;
		next = replay_words[0];
		used = replay_words[1];
		base = 0;
		for (position = FW_CHUNK_HEAD; position < FW_CHUNK_HEAD + used; position++) {
			if (position - base == REPLAY_WORDS) {
				base = position;
				error = fw_mem_read(chunk + base * 4u, replay_words, sizeof(replay_words));
				if (error != 0)
					return -1;
			}
			word = replay_words[position - base];

			/* A header: its length, and whether it is data (skipped). */
			if (left == 0) {
				left = word & 0xFFu;
				if (GHCI_PKT_GET_CLASS(word) == GHCI_PKT_CLASS_PAD)
					left = word & 0xFFFFu;
				taken = 0;
				skipping = 0;
				packet[taken++] = word;
			} else {
				left--;
				if (taken == 1u && GHCI_PKT_GET_CLASS(packet[0]) == GHCI_PKT_CLASS_PAD && word == FW_MARK_DATA)
					skipping = 1;
				if (!skipping) {
					if (taken == sizeof(packet) / sizeof(packet[0]))
						return -1;
					packet[taken++] = word;
				}
			}

			/* A whole packet goes into the primary's recording. */
			if (left == 0 && !skipping) {
				error = fw_record_words(cmdbuf, packet, taken);
				if (error != 0)
					return -1;
			}
		}

	}

	/* Succeeded: the secondary's work follows in the primary. */
	return 0;
}

/*
 * Gives the recording state of a command buffer that is recording, in
 * DMEM; the state of another command buffer is put back into its block
 * first.
 *
 * Returns NULL when a block could not be read or written.
 */
struct fw_rstate *
fw_rstate(
	struct fw_object *cmdbuf)
{
	int error;

	/* The state in DMEM is the command buffer's already. */
	if (record_state_owner == cmdbuf)
		return &record_state_lines.state;

	/* Another command buffer's state goes back to its block. */
	if (record_state_owner != NULL) {
		error = fw_mem_write(record_state_owner->block, &record_state_lines, sizeof(record_state_lines));
		if (error != 0)
			return NULL;
		record_state_owner = NULL;
	}

	/* This command buffer's state from its block. */
	error = fw_mem_read(cmdbuf->block, &record_state_lines, sizeof(record_state_lines));
	if (error != 0)
		return NULL;

	/* Succeeded: the state in DMEM. */
	record_state_owner = cmdbuf;
	return &record_state_lines.state;
}

/*
 * Starts the recording state of a command buffer that begins recording:
 * its block, all zero, in DMEM.
 *
 * Returns 0, or -1 when the heap has no room for the block.
 */
int
fw_rstate_begin(
	struct fw_object *cmdbuf)
{
	int error;

	/* Another command buffer's state goes back to its block. */
	if (record_state_owner != NULL && record_state_owner != cmdbuf) {
		error = fw_mem_write(record_state_owner->block, &record_state_lines, sizeof(record_state_lines));
		if (error != 0)
			return -1;
	}
	record_state_owner = NULL;

	/* The block. */
	error = fw_object_block(cmdbuf, sizeof(record_state_lines));
	if (error != 0)
		return -1;

	/* An empty state: nothing bound, nothing set. */
	memset(&record_state_lines, 0, sizeof(record_state_lines));
	record_state_owner = cmdbuf;

	/* Succeeded: the command buffer can record. */
	return 0;
}

/*
 * Ends the recording state of a command buffer that stopped recording:
 * its block goes back to the heap.
 */
void
fw_rstate_end(
	struct fw_object *cmdbuf)
{
	/* The DMEM copy is no longer the command buffer's. */
	if (record_state_owner == cmdbuf)
		record_state_owner = NULL;

	/* The block. */
	fw_heap_free(cmdbuf->tag, cmdbuf->block, (uint32_t)cmdbuf->lines * FW_LINE_BYTES);
	cmdbuf->block = 0;
	cmdbuf->lines = 0;
}

/* Puts a command buffer's last chunk in the cache (a new chain gets its first chunk). */
static int
record_cache(
	struct fw_object *cmdbuf)
{
	int error;

	/* The cache holds it already. */
	if (record_owner == cmdbuf && record_address == cmdbuf->b)
		return 0;

	/* Another chunk goes back to memory first. */
	error = fw_record_flush();
	if (error != 0)
		return -1;
	record_owner = NULL;

	/* An empty recording: its first chunk. */
	if (cmdbuf->b == 0) {
		error = record_new_chunk(cmdbuf);
		if (error != 0)
			return -1;
		return 0;
	}

	/* The last chunk from memory. */
	error = fw_mem_read(cmdbuf->b, record_chunk, FW_CHUNK_BYTES);
	if (error != 0)
		return -1;

	/* Succeeded: the cache holds the last chunk. */
	record_owner = cmdbuf;
	record_address = cmdbuf->b;
	record_dirty = 0;
	return 0;
}

/* Links a new empty chunk after the cached one (or as the first) and caches it. */
static int
record_new_chunk(
	struct fw_object *cmdbuf)
{
	uint32_t chunk;
	int error;

	/* The new chunk. */
	chunk = fw_heap_alloc(cmdbuf->tag, FW_CHUNK_BYTES);
	if (chunk == 0)
		return -1;

	/* The chunk before links it and goes back to memory. */
	if (record_owner == cmdbuf) {
		record_chunk[0] = chunk;
		record_dirty = 1;
		error = fw_record_flush();
		if (error != 0) {
			fw_heap_free(cmdbuf->tag, chunk, FW_CHUNK_BYTES);
			return -1;
		}
	}

	/* The first chunk of the chain. */
	if (cmdbuf->a == 0)
		cmdbuf->a = chunk;

	/* The cache holds the new, empty last chunk. */
	cmdbuf->b = chunk;
	record_chunk[0] = 0;
	record_chunk[1] = 0;
	record_owner = cmdbuf;
	record_address = chunk;
	record_dirty = 1;

	/* Succeeded: the chunk is ready for packets. */
	return 0;
}

/* Replays one chunk: its class N packets to the FIFO, its markers run. */
static int
replay_chunk(
	uint32_t chunk,
	uint32_t *next)
{
	uint32_t marker[FW_EMIT_PAYLOAD + 1u];
	uint32_t used;
	uint32_t position;
	uint32_t base;
	uint32_t word;
	uint32_t left;
	uint32_t taken;
	int in_marker;
	int error;

	/* The first lines: the link, the words used and the first payload. */
	error = fw_mem_read(chunk, replay_words, sizeof(replay_words));
	if (error != 0)
		return -1;
	*next = replay_words[0];
	used = replay_words[1];
	if (used > FW_CHUNK_PAYLOAD)
		return -1;

	/* Walks the payload, reading the next lines when the buffer is used up. */
	base = 0;
	left = 0;
	taken = 0;
	in_marker = 0;
	for (position = FW_CHUNK_HEAD; position < FW_CHUNK_HEAD + used; position++) {
		if (position - base == REPLAY_WORDS) {
			base = position;
			error = fw_mem_read(chunk + base * 4u, replay_words, sizeof(replay_words));
			if (error != 0)
				return -1;
		}
		word = replay_words[position - base];

		/* A header: a marker is collected, a µop goes to the FIFO. */
		if (left == 0) {
			if (GHCI_PKT_GET_CLASS(word) == GHCI_PKT_CLASS_PAD) {
				left = word & 0xFFFFu;
				in_marker = 1;
				taken = 0;
				if (left == 0)
					return -1;
				continue;
			}
			left = word & 0xFFu;
			in_marker = 0;
			fw_uop_send(&word, 1);
			continue;
		}

		/* A payload word. */
		left--;
		if (!in_marker) {
			fw_uop_send(&word, 1);
			continue;
		}

		/* A data packet's words are for the units; a marker's are collected. */
		if (taken == 0 && word == FW_MARK_DATA)
			in_marker = 2;
		if (in_marker == 2)
			continue;
		if (taken == FW_EMIT_PAYLOAD + 1u)
			return -1;

		/* A marker's word; the last one runs it. */
		marker[taken++] = word;
		if (left == 0) {
			error = fw_marker_run(marker[0], &marker[1], taken - 1u);
			if (error != 0)
				return -1;
		}
	}

	/* A packet cut at the chunk's end is a firmware fault. */
	if (left != 0)
		return -1;

	/* Succeeded: the chunk is replayed. */
	return 0;
}
