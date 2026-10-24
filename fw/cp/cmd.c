/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The command decoder: one gpu-op's arguments in the wire form of zedBSD's
 * GPU command protocol (u32/u64 little endian, an object as its u64
 * identity, a pointer as a u64 presence word, an array as its u32 count
 * and a u64 count before the elements, a structure as sType, the pNext
 * presence and the fields), and what it does to the session's objects.
 *
 * It decodes the first class V path: the GHCI session and memory
 * commands, buffers and their binding, command pools and buffers, the
 * recorded fill and copy of buffers, and QUEUE_SUBMIT, which replays the
 * recordings as blits.  Every argument of a command is read before it
 * acts, so a malformed command changes nothing.
 */

#include "fw.h"
#include "ghci_frame.h"

/* The sTypes the decoder meets in the chains it accepts. */
#define CMD_STYPE_EXTERNAL_MEMORY_BUFFER 1000072000u

/* Vulkan's VK_WHOLE_SIZE. */
#define CMD_WHOLE_SIZE (~(uint64_t)0)

/* The handler of one gpu-op number. */
typedef void (*cmd_handler)(struct fw_command *command);

/*
 * One row of the command table: a gpu-op number and its handler.
 */
struct cmd_entry {
	uint32_t number;
	cmd_handler handler;
};

static void cmd_session_open(struct fw_command *command);
static void cmd_session_close(struct fw_command *command);
static void cmd_memory(struct fw_command *command);
static void cmd_free_memory(struct fw_command *command);
static void cmd_create_buffer(struct fw_command *command);
static void cmd_destroy_buffer(struct fw_command *command);
static void cmd_bind_buffer(struct fw_command *command);
static void cmd_create_pool(struct fw_command *command);
static void cmd_destroy_pool(struct fw_command *command);
static void cmd_allocate_buffers(struct fw_command *command);
static void cmd_free_buffers(struct fw_command *command);
static void cmd_begin(struct fw_command *command);
static void cmd_end(struct fw_command *command);
static void cmd_reset(struct fw_command *command);
static void cmd_fill(struct fw_command *command);
static void cmd_copy(struct fw_command *command);
static void cmd_submit(struct fw_command *command);

/*
 * The gpu-ops this firmware decodes.
 */
static const struct cmd_entry cmd_table[] = {
	{ GHCI_GPU_OP_SESSION_OPEN, cmd_session_open },
	{ GHCI_GPU_OP_SESSION_CLOSE, cmd_session_close },
	{ GHCI_GPU_OP_MEMORY, cmd_memory },
	{ GHCI_VK_FREE_MEMORY, cmd_free_memory },
	{ GHCI_VK_CREATE_BUFFER, cmd_create_buffer },
	{ GHCI_VK_DESTROY_BUFFER, cmd_destroy_buffer },
	{ GHCI_VK_BIND_BUFFER_MEMORY, cmd_bind_buffer },
	{ GHCI_VK_CREATE_COMMAND_POOL, cmd_create_pool },
	{ GHCI_VK_DESTROY_COMMAND_POOL, cmd_destroy_pool },
	{ GHCI_VK_ALLOCATE_COMMAND_BUFFERS, cmd_allocate_buffers },
	{ GHCI_VK_FREE_COMMAND_BUFFERS, cmd_free_buffers },
	{ GHCI_VK_BEGIN_COMMAND_BUFFER, cmd_begin },
	{ GHCI_VK_END_COMMAND_BUFFER, cmd_end },
	{ GHCI_VK_RESET_COMMAND_BUFFER, cmd_reset },
	{ GHCI_VK_CMD_FILL_BUFFER, cmd_fill },
	{ GHCI_VK_CMD_COPY_BUFFER, cmd_copy },
	{ GHCI_VK_QUEUE_SUBMIT, cmd_submit },
};

static void cmd_expect(struct fw_command *command, uint64_t value);
static void cmd_skip_u64s(struct fw_command *command);
static void cmd_skip_u32s(struct fw_command *command);
static int cmd_session(struct fw_command *command);
static struct fw_object *cmd_recording(struct fw_command *command, uint64_t id);

/*
 * Decodes one command at the reader and carries it out.
 *
 * The status is the command's VkResult; `stop` is set when the reader
 * cannot be trusted to stand at the next command.
 */
void
fw_command_decode(
	struct fw_command *command)
{
	uint32_t index;

	/* Starts from success. */
	command->status = GHCI_VK_SUCCESS;
	command->aux = 0;
	command->stop = 0;

	/* Finds the number's handler. */
	for (index = 0; index < sizeof(cmd_table) / sizeof(cmd_table[0]); index++) {
		if (cmd_table[index].number == command->number) {
			cmd_table[index].handler(command);
			break;
		}
	}

	/* An unknown number: its end cannot be found. */
	if (index == sizeof(cmd_table) / sizeof(cmd_table[0])) {
		command->status = GHCI_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return;
	}

	/* A malformed or unsupported wire (a chain, an allocator): also no end. */
	if (command->reader->error) {
		command->status = GHCI_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
	}
}

/* GHCI_SESSION_OPEN: [u32 tag][u32 flags][u64 heap limit]. */
static void
cmd_session_open(
	struct fw_command *command)
{
	uint32_t tag;
	int error;

	/* The arguments; the flags and the limit are not used by the DMEM heap. */
	tag = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u64(command->reader);
	if (command->reader->error || tag > 255u)
		return;

	/* A session is opened once. */
	error = fw_session_open(tag);
	if (error != 0)
		command->status = GHCI_VK_ERROR_INITIALIZATION_FAILED;
}

/* GHCI_SESSION_CLOSE: [u32 tag]. */
static void
cmd_session_close(
	struct fw_command *command)
{
	uint32_t tag;

	/* The argument. */
	tag = fw_reader_u32(command->reader);
	if (command->reader->error || tag > 255u)
		return;

	/* Returns the session's objects. */
	fw_session_close(tag);
}

/* GHCI_MEMORY: [u64 memory][u64 GPU address][u64 bytes][u32 flags]. */
static void
cmd_memory(
	struct fw_command *command)
{
	struct fw_object *memory;
	uint64_t id;
	uint32_t address;
	uint32_t bytes;

	/* The arguments; the size is an address range, so it fits 32 bits. */
	id = fw_reader_u64(command->reader);
	address = fw_reader_address(command->reader);
	bytes = fw_reader_address(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Objects belong to an open session. */
	if (!cmd_session(command))
		return;

	/* Remembers the allocation the driver made. */
	memory = fw_object_create(command->tag, id, FW_OBJ_MEMORY);
	if (memory == NULL) {
		command->status = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
		return;
	}

	memory->address = address;
	memory->bytes = bytes;
}

/* FREE_MEMORY: [device][memory][u64 0]. */
static void
cmd_free_memory(
	struct fw_command *command)
{
	struct fw_object *memory;
	uint64_t id;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	cmd_expect(command, 0);
	if (command->reader->error)
		return;

	/* Forgets the allocation (the driver frees it after the session's fence). */
	memory = fw_object_find(command->tag, id, FW_OBJ_MEMORY);
	if (memory != NULL)
		fw_object_destroy(memory);
}

/* CREATE_BUFFER: the create form with VkBufferCreateInfo. */
static void
cmd_create_buffer(
	struct fw_command *command)
{
	struct fw_object *buffer;
	uint64_t chain;
	uint32_t stype;
	uint32_t size;
	uint64_t id;

	/* [device][u64 1] and the create info's sType. */
	(void)fw_reader_u64(command->reader);
	cmd_expect(command, 1);
	(void)fw_reader_u32(command->reader);

	/* The chain: none, or the external-memory record libvulkan adds. */
	chain = fw_reader_u64(command->reader);
	if (chain == 1) {
		/* [sType][u64 0, the end of the chain][handle types]: no effect here. */
		stype = fw_reader_u32(command->reader);
		if (stype != CMD_STYPE_EXTERNAL_MEMORY_BUFFER)
			command->reader->error = 1;
		cmd_expect(command, 0);
		(void)fw_reader_u32(command->reader);
	} else if (chain != 0) {
		command->reader->error = 1;
	}

	/* flags, size, usage, sharing mode, the queue family indices. */
	(void)fw_reader_u32(command->reader);
	size = fw_reader_address(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	cmd_skip_u64s(command);

	/* [u64 0, no allocator][u64 1][the identity]. */
	cmd_expect(command, 0);
	cmd_expect(command, 1);
	id = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* Objects belong to an open session. */
	if (!cmd_session(command))
		return;

	/* The buffer, without memory. */
	buffer = fw_object_create(command->tag, id, FW_OBJ_BUFFER);
	if (buffer == NULL) {
		command->status = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
		return;
	}

	buffer->bytes = size;
}

/* DESTROY_BUFFER: [device][buffer][u64 0]. */
static void
cmd_destroy_buffer(
	struct fw_command *command)
{
	struct fw_object *buffer;
	uint64_t id;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	cmd_expect(command, 0);
	if (command->reader->error)
		return;

	/* Forgets the buffer. */
	buffer = fw_object_find(command->tag, id, FW_OBJ_BUFFER);
	if (buffer != NULL)
		fw_object_destroy(buffer);
}

/* BIND_BUFFER_MEMORY: [device][buffer][memory][u64 offset]. */
static void
cmd_bind_buffer(
	struct fw_command *command)
{
	struct fw_object *buffer;
	struct fw_object *memory;
	uint64_t buffer_id;
	uint64_t memory_id;
	uint32_t offset;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	memory_id = fw_reader_u64(command->reader);
	offset = fw_reader_address(command->reader);
	if (command->reader->error)
		return;

	/* Both objects of the session. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	memory = fw_object_find(command->tag, memory_id, FW_OBJ_MEMORY);
	if (buffer == NULL || memory == NULL) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	/* The buffer must lie inside the memory. */
	if (offset > memory->bytes || buffer->bytes > memory->bytes - offset) {
		command->status = GHCI_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* The buffer's GPU address from now on. */
	buffer->address = memory->address + offset;
	buffer->bound = 1;
}

/* CREATE_COMMAND_POOL: the create form with VkCommandPoolCreateInfo. */
static void
cmd_create_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint64_t id;

	/* [device][u64 1][sType][u64 0, no chain][flags][queue family][u64 0][u64 1][id]. */
	(void)fw_reader_u64(command->reader);
	cmd_expect(command, 1);
	(void)fw_reader_u32(command->reader);
	cmd_expect(command, 0);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	cmd_expect(command, 0);
	cmd_expect(command, 1);
	id = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* Objects belong to an open session. */
	if (!cmd_session(command))
		return;

	/* The pool. */
	pool = fw_object_create(command->tag, id, FW_OBJ_POOL);
	if (pool == NULL)
		command->status = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
}

/* DESTROY_COMMAND_POOL: [device][pool][u64 0]. */
static void
cmd_destroy_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint64_t id;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	cmd_expect(command, 0);
	if (command->reader->error)
		return;

	/* The pool and its command buffers. */
	pool = fw_object_find(command->tag, id, FW_OBJ_POOL);
	if (pool != NULL)
		fw_object_destroy(pool);
}

/* ALLOCATE_COMMAND_BUFFERS: [device][u64 1][VkCommandBufferAllocateInfo][u64 count][ids]. */
static void
cmd_allocate_buffers(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t pool_id;
	uint64_t count;
	uint64_t index;
	uint64_t id;

	/* [device][u64 1][sType][u64 0][pool][level][count] and the array's count. */
	(void)fw_reader_u64(command->reader);
	cmd_expect(command, 1);
	(void)fw_reader_u32(command->reader);
	cmd_expect(command, 0);
	pool_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* Objects belong to an open session, and to an existing pool. */
	if (!cmd_session(command)) {
		command->status = GHCI_VK_ERROR_INITIALIZATION_FAILED;
	} else if (fw_object_find(command->tag, pool_id, FW_OBJ_POOL) == NULL) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
	}

	/* One command buffer per identity; all are read even after a failure. */
	for (index = 0; index < count; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error || command->status != GHCI_VK_SUCCESS)
			continue;

		/* An initial command buffer of the pool. */
		cmdbuf = fw_object_create(command->tag, id, FW_OBJ_CMDBUF);
		if (cmdbuf == NULL) {
			command->status = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
			continue;
		}

		cmdbuf->pool = pool_id;
		cmdbuf->state = FW_CB_INITIAL;
	}
}

/* FREE_COMMAND_BUFFERS: [device][pool][u32 count][u64 count][ids]. */
static void
cmd_free_buffers(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t count;
	uint64_t index;
	uint64_t id;

	/* [device][pool][u32 count] and the array's count. */
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);

	/* Frees each named command buffer. */
	for (index = 0; index < count; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error)
			return;
		cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
		if (cmdbuf != NULL)
			fw_object_destroy(cmdbuf);
	}
}

/* BEGIN_COMMAND_BUFFER: [command buffer][u64 1][VkCommandBufferBeginInfo]. */
static void
cmd_begin(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t id;
	uint64_t inheritance;

	/* [cb][u64 1][sType][u64 0][flags][inheritance presence]. */
	id = fw_reader_u64(command->reader);
	cmd_expect(command, 1);
	(void)fw_reader_u32(command->reader);
	cmd_expect(command, 0);
	(void)fw_reader_u32(command->reader);
	inheritance = fw_reader_u64(command->reader);

	/* A secondary buffer's inheritance: sType, no chain, 3 handles' worth of fields. */
	if (inheritance == 1) {
		(void)fw_reader_u32(command->reader);
		cmd_expect(command, 0);
		(void)fw_reader_u64(command->reader);
		(void)fw_reader_u32(command->reader);
		(void)fw_reader_u64(command->reader);
		(void)fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
	} else if (inheritance != 0) {
		command->reader->error = 1;
	}

	if (command->reader->error)
		return;

	/* The command buffer of the session. */
	cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
	if (cmdbuf == NULL) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	/* Begin resets the recording (the pools allow the implicit reset). */
	fw_uop_clear(cmdbuf);
	cmdbuf->state = FW_CB_RECORDING;
	cmdbuf->error = GHCI_VK_SUCCESS;
}

/* END_COMMAND_BUFFER: [command buffer]. */
static void
cmd_end(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t id;

	/* The argument. */
	id = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* A command buffer that is recording. */
	cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
	if (cmdbuf == NULL || cmdbuf->state != FW_CB_RECORDING) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	/* The first failure of a record is the result, as on bcm2711. */
	command->status = cmdbuf->error;
	cmdbuf->state = FW_CB_EXECUTABLE;
	if (cmdbuf->error != GHCI_VK_SUCCESS)
		cmdbuf->state = FW_CB_INVALID;
}

/* RESET_COMMAND_BUFFER: [command buffer][u32 flags]. */
static void
cmd_reset(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t id;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Empties the recording. */
	cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
	if (cmdbuf == NULL) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	fw_uop_clear(cmdbuf);
	cmdbuf->state = FW_CB_INITIAL;
	cmdbuf->error = GHCI_VK_SUCCESS;
}

/* CMD_FILL_BUFFER: [cb][buffer][u64 offset][u64 size][u32 data]. */
static void
cmd_fill(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	uint64_t cmdbuf_id;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t size;
	uint32_t data;
	uint32_t bytes;
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
	cmdbuf = cmd_recording(command, cmdbuf_id);
	if (cmdbuf == NULL)
		return;

	/* A bound buffer, the range inside it, in whole words. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	if (buffer == NULL || !buffer->bound || offset > buffer->bytes || (offset & 3u) != 0) {
		cmdbuf->error = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	/* VK_WHOLE_SIZE is the rest of the buffer, down to whole words. */
	if (size == CMD_WHOLE_SIZE)
		size = (buffer->bytes - offset) & ~(uint64_t)3;
	if (size > buffer->bytes - offset || (size & 3u) != 0) {
		cmdbuf->error = GHCI_VK_ERROR_UNKNOWN;
		return;
	}

	/* The blits of the fill. */
	bytes = (uint32_t)size;
	error = fw_uop_fill(cmdbuf, buffer->address + (uint32_t)offset, bytes / 4u, data);
	if (error != 0)
		cmdbuf->error = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
}

/* CMD_COPY_BUFFER: [cb][source][destination][u32 count][u64 count][VkBufferCopy...]. */
static void
cmd_copy(
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
	cmdbuf = cmd_recording(command, cmdbuf_id);
	src = fw_object_find(command->tag, src_id, FW_OBJ_BUFFER);
	dst = fw_object_find(command->tag, dst_id, FW_OBJ_BUFFER);
	if (cmdbuf != NULL && (src == NULL || dst == NULL || !src->bound || !dst->bound))
		cmdbuf->error = GHCI_VK_ERROR_UNKNOWN;

	/* Each region: read, check, record. */
	for (index = 0; index < count; index++) {
		src_offset = fw_reader_u64(command->reader);
		dst_offset = fw_reader_u64(command->reader);
		size = fw_reader_u64(command->reader);
		if (command->reader->error)
			return;
		if (cmdbuf == NULL || cmdbuf->error != GHCI_VK_SUCCESS)
			continue;

		/* Both ranges inside their buffers. */
		if (src_offset > src->bytes ||
		    size > src->bytes - src_offset ||
		    dst_offset > dst->bytes ||
		    size > dst->bytes - dst_offset) {
			cmdbuf->error = GHCI_VK_ERROR_UNKNOWN;
			continue;
		}

		/* The blits of the region. */
		error = fw_uop_copy(cmdbuf, src->address + (uint32_t)src_offset, dst->address + (uint32_t)dst_offset, (uint32_t)size);
		if (error == -1) {
			cmdbuf->error = GHCI_VK_ERROR_OUT_OF_HOST_MEMORY;
		} else if (error != 0) {
			cmdbuf->error = GHCI_VK_ERROR_FEATURE_NOT_PRESENT;
		}
	}
}

/* QUEUE_SUBMIT: [queue][u32 count][u64 count][VkSubmitInfo...][fence]. */
static void
cmd_submit(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t submits;
	uint64_t submit;
	uint64_t buffers;
	uint64_t buffer;
	uint64_t id;

	/* The queue (one queue) and the submit count. */
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	submits = fw_reader_u64(command->reader);

	/*
	 * Each VkSubmitInfo ([sType][u64 0][waits][stage masks][command
	 * buffers][signals]): the waits are in ring order already (one queue),
	 * the command buffers are replayed as they are read, the signals need
	 * nothing (the driver's FENCE after the packet completes the work).
	 */
	for (submit = 0; submit < submits; submit++) {
		(void)fw_reader_u32(command->reader);
		cmd_expect(command, 0);
		(void)fw_reader_u32(command->reader);
		cmd_skip_u64s(command);
		cmd_skip_u32s(command);
		(void)fw_reader_u32(command->reader);
		buffers = fw_reader_u64(command->reader);
		for (buffer = 0; buffer < buffers; buffer++) {
			id = fw_reader_u64(command->reader);
			if (command->reader->error)
				return;

			/* Only an executable command buffer of the session runs. */
			cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
			if (cmdbuf == NULL || cmdbuf->state != FW_CB_EXECUTABLE) {
				command->status = GHCI_VK_ERROR_UNKNOWN;
				continue;
			}

			fw_uop_replay(cmdbuf);
		}

		/* The signal semaphores. */
		(void)fw_reader_u32(command->reader);
		cmd_skip_u64s(command);
	}

	/* The fence (the driver's, signalled by its FENCE after the packet). */
	(void)fw_reader_u64(command->reader);
}

/* Reads a u64 that must have one value (a presence word, a null allocator). */
static void
cmd_expect(
	struct fw_command *command,
	uint64_t value)
{
	uint64_t found;

	/* Anything else is a wire this firmware does not decode. */
	found = fw_reader_u64(command->reader);
	if (found != value)
		command->reader->error = 1;
}

/* Skips an array of u64 (identities): its u64 count and the elements. */
static void
cmd_skip_u64s(
	struct fw_command *command)
{
	uint64_t count;
	uint64_t index;

	/* Reads past each element (the reader checks the range). */
	count = fw_reader_u64(command->reader);
	for (index = 0; index < count && !command->reader->error; index++)
		(void)fw_reader_u64(command->reader);
}

/* Skips an array of u32 (stage masks): its u64 count and the elements. */
static void
cmd_skip_u32s(
	struct fw_command *command)
{
	uint64_t count;
	uint64_t index;

	/* Reads past each element (the reader checks the range). */
	count = fw_reader_u64(command->reader);
	for (index = 0; index < count && !command->reader->error; index++)
		(void)fw_reader_u32(command->reader);
}

/* Reports whether the command's session is open; sets the status if not. */
static int
cmd_session(
	struct fw_command *command)
{
	int open;

	/* The packet's JOB_TAG names the session. */
	open = fw_session_is_open(command->tag);
	if (!open) {
		command->status = GHCI_VK_ERROR_INITIALIZATION_FAILED;
		return 0;
	}

	/* Succeeded: the session is open. */
	return 1;
}

/* Finds a command buffer that is recording; a recorded command into another is dropped. */
static struct fw_object *
cmd_recording(
	struct fw_command *command,
	uint64_t id)
{
	struct fw_object *cmdbuf;

	/* The session's command buffer. */
	cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
	if (cmdbuf == NULL || cmdbuf->state != FW_CB_RECORDING) {
		command->status = GHCI_VK_ERROR_UNKNOWN;
		return NULL;
	}

	/* Succeeded: records go into it. */
	return cmdbuf;
}
