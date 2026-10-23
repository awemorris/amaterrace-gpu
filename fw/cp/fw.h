/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The CP firmware's internal interfaces: the line DMA and the staging
 * reader, the result store, the µop output and the recordings, the chunk
 * heap, the object table and the command decoder.
 */

#ifndef FW_CP_FW_H
#define FW_CP_FW_H

#include <stddef.h>
#include <stdint.h>

/* The AMB line, set per board by tools/fw-build.sh (32 ZYBO, 64 KC705). */
#ifndef FW_LINE_BYTES
#define FW_LINE_BYTES 32u
#endif

/* The firmware's version in CPFW_VERSION: [31:16] major, [15:0] minor. */
#define FW_VERSION 0x00010000u

/* The firmware states in CPFW_STATUS[15:8]. */
#define FW_STATE_BOOT 0x01u	/* start-up */
#define FW_STATE_IDLE 0x02u	/* waiting for a packet */
#define FW_STATE_PACKET 0x03u	/* decoding a packet */
#define FW_STATE_PARKED 0x04u	/* stopped for a halt request */
#define FW_STATE_TRAP 0xEEu	/* an interrupt came although none is enabled */

/* The value of MBOX3 at start-up: a .data word, restored on every boot. */
#define FW_DATA_CHECK 0x0DA7A001u

/* Lines the staging reader keeps (its buffer is this many lines). */
#define FW_READER_LINES 8u

/* Words of one heap chunk; the first word links the next chunk. */
#define FW_CHUNK_WORDS 32u

/* The object kinds of the object table. */
enum fw_object_kind {
	FW_OBJ_FREE = 0,
	FW_OBJ_MEMORY,
	FW_OBJ_BUFFER,
	FW_OBJ_POOL,
	FW_OBJ_CMDBUF
};

/* The recording states of a command buffer (Vulkan's lifecycle). */
enum fw_cmdbuf_state {
	FW_CB_INITIAL = 0,
	FW_CB_RECORDING,
	FW_CB_EXECUTABLE,
	FW_CB_INVALID
};

/*
 * A cursor over a byte range of GPU memory (a frame in the staging buffer,
 * or a class V packet).
 *
 * Reads that pass the end or meet a DMA error set the sticky error and
 * return 0, so a decoder reads a whole command and looks at the error
 * once; the shared line buffer is refilled as the cursor moves.
 */
struct fw_reader {
	uint32_t addr;
	uint32_t end;
	int error;
};

/*
 * One Vulkan object of a session, named by the identity libvulkan chose.
 *
 * Objects live in a fixed table and are chained per hash bucket; a
 * session's close returns all of its objects.  The fields after `kind`
 * mean what the kind says: memory (address, bytes), buffer (size, bound
 * address, bound), pool (none), command buffer (pool, state, recording).
 */
struct fw_object {
	uint64_t id;
	struct fw_object *next;
	uint8_t tag;
	uint8_t kind;
	uint8_t state;
	uint8_t bound;
	uint32_t address;
	uint32_t bytes;
	uint64_t pool;
	uint32_t *first;
	uint32_t *last;
	uint32_t used;
	int32_t error;
};

/*
 * The decoding of one command: its session, its arguments, and what the
 * decoder reports.
 *
 * `stop` is set when the command's end cannot be found (an unknown number
 * or a malformed wire), so the frame cannot go on.
 */
struct fw_command {
	uint32_t number;
	uint32_t tag;
	struct fw_reader *reader;
	int32_t status;
	uint32_t aux;
	int stop;
};

void *memcpy(void *dst, const void *src, size_t bytes);
void *memset(void *dst, int value, size_t bytes);
int memcmp(const void *a, const void *b, size_t bytes);

int fw_dma_read(uint32_t address, void *dmem, uint32_t lines);
int fw_dma_write(uint32_t address, const void *dmem, uint32_t lines);
void fw_reader_init(struct fw_reader *reader, uint32_t address, uint32_t bytes);
uint32_t fw_reader_u32(struct fw_reader *reader);
uint64_t fw_reader_u64(struct fw_reader *reader);
uint32_t fw_reader_address(struct fw_reader *reader);
int fw_store(uint32_t address, const void *src, uint32_t bytes);
int fw_store_flush(void);

void fw_uop_send(const uint32_t *words, uint32_t count);
int fw_uop_record(struct fw_object *cmdbuf, const uint32_t *words, uint32_t count);
void fw_uop_replay(struct fw_object *cmdbuf);
void fw_uop_clear(struct fw_object *cmdbuf);
int fw_uop_fill(struct fw_object *cmdbuf, uint32_t address, uint32_t words, uint32_t data);
int fw_uop_copy(struct fw_object *cmdbuf, uint32_t src, uint32_t dst, uint32_t bytes);

void fw_heap_init(void);
uint32_t *fw_chunk_alloc(void);
void fw_chunk_free(uint32_t *chunk);

void fw_object_init(void);
struct fw_object *fw_object_find(uint32_t tag, uint64_t id, uint32_t kind);
struct fw_object *fw_object_create(uint32_t tag, uint64_t id, uint32_t kind);
void fw_object_destroy(struct fw_object *object);
void fw_object_close(uint32_t tag);
int fw_session_open(uint32_t tag);
int fw_session_is_open(uint32_t tag);
void fw_session_close(uint32_t tag);

void fw_command_decode(struct fw_command *command);
void fw_packet_run(uint32_t info);

#endif
