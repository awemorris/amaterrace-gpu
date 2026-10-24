/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The command decoder: the table of the gpu-ops the firmware takes, the
 * readers of the wire form of zedBSD's GPU command protocol (u32/u64
 * little endian, an object as its u64 identity, a pointer as a u64
 * presence word, an array as its u32 count and a u64 count before the
 * elements, a structure as sType, the pNext presence and the fields), and
 * the GHCI gpu-ops of the sessions, the heap and the memory.
 *
 * Every argument of a command is read before it acts, so a malformed
 * command changes nothing.
 */

#include "fw.h"
#include "ghci_frame.h"

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
static void cmd_heap(struct fw_command *command);
static void cmd_memory(struct fw_command *command);
static void cmd_free_memory(struct fw_command *command);
static void cmd_destroy_device(struct fw_command *command);
static void cmd_create_semaphore(struct fw_command *command);
static void cmd_destroy_semaphore(struct fw_command *command);
static void cmd_unsupported(struct fw_command *command);

/*
 * The gpu-ops this firmware decodes.
 */
static const struct cmd_entry cmd_table[] = {
	{ GHCI_GPU_OP_SESSION_OPEN, cmd_session_open },
	{ GHCI_GPU_OP_SESSION_CLOSE, cmd_session_close },
	{ GHCI_GPU_OP_HEAP, cmd_heap },
	{ GHCI_GPU_OP_MEMORY, cmd_memory },
	{ GHCI_GPU_OP_PROGRAM, fw_cmd_program },
	{ GHCI_GPU_OP_BUFFER_GRANT, cmd_unsupported },
	{ GHCI_GPU_OP_BUFFER_REVOKE, cmd_unsupported },
	{ GHCI_VK_DESTROY_DEVICE, cmd_destroy_device },
	{ GHCI_VK_QUEUE_SUBMIT, fw_cmd_queue_submit },
	{ GHCI_VK_FREE_MEMORY, cmd_free_memory },
	{ GHCI_VK_BIND_BUFFER_MEMORY, fw_cmd_bind_buffer },
	{ GHCI_VK_BIND_IMAGE_MEMORY, fw_cmd_bind_image },
	{ GHCI_VK_CREATE_SEMAPHORE, cmd_create_semaphore },
	{ GHCI_VK_DESTROY_SEMAPHORE, cmd_destroy_semaphore },
	{ GHCI_VK_CREATE_BUFFER, fw_cmd_create_buffer },
	{ GHCI_VK_DESTROY_BUFFER, fw_cmd_destroy_buffer },
	{ GHCI_VK_CREATE_BUFFER_VIEW, fw_cmd_create_buffer_view },
	{ GHCI_VK_DESTROY_BUFFER_VIEW, fw_cmd_destroy_buffer_view },
	{ GHCI_VK_CREATE_IMAGE, fw_cmd_create_image },
	{ GHCI_VK_DESTROY_IMAGE, fw_cmd_destroy_image },
	{ GHCI_VK_CREATE_IMAGE_VIEW, fw_cmd_create_image_view },
	{ GHCI_VK_DESTROY_IMAGE_VIEW, fw_cmd_destroy_image_view },
	{ GHCI_VK_CREATE_SAMPLER, fw_cmd_create_sampler },
	{ GHCI_VK_DESTROY_SAMPLER, fw_cmd_destroy_sampler },
	{ GHCI_VK_CREATE_COMMAND_POOL, fw_cmd_create_command_pool },
	{ GHCI_VK_DESTROY_COMMAND_POOL, fw_cmd_destroy_command_pool },
	{ GHCI_VK_RESET_COMMAND_POOL, fw_cmd_reset_command_pool },
	{ GHCI_VK_ALLOCATE_COMMAND_BUFFERS, fw_cmd_allocate_command_buffers },
	{ GHCI_VK_FREE_COMMAND_BUFFERS, fw_cmd_free_command_buffers },
	{ GHCI_VK_BEGIN_COMMAND_BUFFER, fw_cmd_begin_command_buffer },
	{ GHCI_VK_END_COMMAND_BUFFER, fw_cmd_end_command_buffer },
	{ GHCI_VK_RESET_COMMAND_BUFFER, fw_cmd_reset_command_buffer },
	{ GHCI_VK_CMD_COPY_BUFFER, fw_cmd_copy_buffer },
	{ GHCI_VK_CMD_UPDATE_BUFFER, fw_cmd_update_buffer },
	{ GHCI_VK_CMD_FILL_BUFFER, fw_cmd_fill_buffer },
};

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
	uint32_t count;

	/* Starts from success. */
	command->status = FW_VK_SUCCESS;
	command->aux = 0;
	command->stop = 0;

	/* Finds the number's handler. */
	count = sizeof(cmd_table) / sizeof(cmd_table[0]);
	for (index = 0; index < count; index++) {
		if (cmd_table[index].number == command->number)
			break;
	}

	/* An unknown number: its end cannot be found. */
	if (index == count) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return;
	}

	/* Carries the command out. */
	cmd_table[index].handler(command);

	/* A malformed or unsupported wire (a chain, an allocator): also no end. */
	if (command->reader->error) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
	}
}

/*
 * Reads a u64 that must have one value (a presence word, a null
 * allocator); anything else is a wire the firmware does not decode.
 */
void
fw_wire_expect(
	struct fw_command *command,
	uint64_t value)
{
	uint64_t found;

	/* The value, and the error when it differs. */
	found = fw_reader_u64(command->reader);
	if (found != value)
		command->reader->error = 1;
}

/*
 * Reads a structure's sType and its pNext, which must be absent: the
 * structures the firmware decodes carry no chain (libvulkan adds none
 * to the Vulkan 1.0 structures it encodes).
 */
void
fw_wire_head(
	struct fw_command *command)
{
	/* The sType; the decoder knows which structure stands here. */
	(void)fw_reader_u32(command->reader);

	/* No chain. */
	fw_wire_expect(command, 0);
}

/*
 * Skips an array of u64 (identities): its u64 count and the elements.
 */
void
fw_wire_skip_u64s(
	struct fw_command *command)
{
	uint64_t count;

	/* The elements are 8 bytes each (the reader checks the range). */
	count = fw_reader_u64(command->reader);
	if (count > 0x10000000u) {
		command->reader->error = 1;
		return;
	}
	fw_reader_skip(command->reader, (uint32_t)count * 8u);
}

/*
 * Skips an array of u32: its u64 count and the elements.
 */
void
fw_wire_skip_u32s(
	struct fw_command *command)
{
	uint64_t count;

	/* The elements are 4 bytes each (the reader checks the range). */
	count = fw_reader_u64(command->reader);
	if (count > 0x10000000u) {
		command->reader->error = 1;
		return;
	}
	fw_reader_skip(command->reader, (uint32_t)count * 4u);
}

/*
 * Skips a string: its u64 length (with the terminator; 0 for none) and
 * the characters, padded to whole u32.
 */
void
fw_wire_skip_string(
	struct fw_command *command)
{
	uint64_t bytes;

	/* The padded characters. */
	bytes = fw_reader_u64(command->reader);
	if (bytes > 0x10000000u) {
		command->reader->error = 1;
		return;
	}
	fw_reader_skip(command->reader, ((uint32_t)bytes + 3u) & ~3u);
}

/*
 * Reads the head of the create form, [device][u64 1], and gives the
 * device.
 */
uint64_t
fw_wire_create_begin(
	struct fw_command *command)
{
	uint64_t device;

	/* The device the object is made on, and the create info's presence. */
	device = fw_reader_u64(command->reader);
	fw_wire_expect(command, 1);

	/* Succeeded: the device. */
	return device;
}

/*
 * Reads the tail of the create form, [u64 0, no allocator][u64 1][the new
 * object's identity], and gives the identity.
 */
uint64_t
fw_wire_create_end(
	struct fw_command *command)
{
	uint64_t id;

	/* No allocator, then the identity libvulkan chose. */
	fw_wire_expect(command, 0);
	fw_wire_expect(command, 1);
	id = fw_reader_u64(command->reader);

	/* Succeeded: the identity. */
	return id;
}

/*
 * Reads the destroy form, [device][the object's identity][u64 0], and
 * gives the identity.
 */
uint64_t
fw_wire_destroy(
	struct fw_command *command)
{
	uint64_t id;

	/* The device, the object, no allocator. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	fw_wire_expect(command, 0);

	/* Succeeded: the identity (0 for the null handle, which destroys nothing). */
	return id;
}

/*
 * Makes a session's object on a device for a create command; sets the
 * command's status when it cannot.
 *
 * Returns NULL when the session is not open or the table is full.
 */
struct fw_object *
fw_cmd_new_object(
	struct fw_command *command,
	uint64_t device,
	uint64_t id,
	uint32_t kind)
{
	struct fw_object *object;
	int slot;
	int open;

	/* Objects belong to an open session. */
	open = fw_session_is_open(command->tag);
	if (!open) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		return NULL;
	}

	/*
	 * The device's slot (its first object makes it); an object named on
	 * no device (the driver's MEMORY) belongs to none.
	 */
	slot = FW_NO_DEVICE;
	if (device != 0) {
		slot = fw_object_device(command->tag, device);
		if (slot < 0) {
			command->status = FW_VK_ERROR_OUT_OF_HOST_MEMORY;
			return NULL;
		}
	}

	/* The object; an identity in use is the driver's error. */
	object = fw_object_create(command->tag, id, kind);
	if (object == NULL) {
		command->status = FW_VK_ERROR_OUT_OF_HOST_MEMORY;
		return NULL;
	}

	/* Succeeded: the new object of the device. */
	object->device = (uint8_t)slot;
	return object;
}

/*
 * Destroys a session's object named by a destroy command (the null handle
 * and an unknown identity destroy nothing).
 */
void
fw_cmd_destroy_object(
	struct fw_command *command,
	uint32_t kind)
{
	struct fw_object *object;
	uint64_t id;

	/* The destroy form. */
	id = fw_wire_destroy(command);
	if (command->reader->error)
		return;

	/* The object, if the session has it. */
	object = fw_object_find(command->tag, id, kind);
	if (object != NULL)
		fw_object_destroy(object);
}

/* GHCI_SESSION_OPEN: [u32 tag][u32 flags][u64 heap limit]; a packet in the ring only. */
static void
cmd_session_open(
	struct fw_command *command)
{
	uint32_t tag;
	uint32_t flags;
	uint64_t limit;
	int error;

	/* The arguments. */
	tag = fw_reader_u32(command->reader);
	flags = fw_reader_u32(command->reader);
	limit = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* Not a staged command: a frame belongs to a session already. */
	if (command->in_frame) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return;
	}

	/* No flag is known: PROTECTED needs the PROT capability, which Amaterrace lacks. */
	if (flags != 0 || tag > 255u) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		return;
	}

	/* A session is opened once; the slots may be used up. */
	error = fw_session_open(tag, limit);
	if (error == -1) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
	} else if (error != 0) {
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
	}
}

/* GHCI_SESSION_CLOSE: [u32 tag]; a packet in the ring only. */
static void
cmd_session_close(
	struct fw_command *command)
{
	uint32_t tag;

	/* The argument. */
	tag = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Not a staged command. */
	if (command->in_frame) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return;
	}

	/* Returns the session's objects (closing a closed session does nothing). */
	if (tag <= 255u)
		fw_session_close(tag);
}

/* GHCI_HEAP: [u64 GPU address][u64 bytes]; a packet in the ring only, no session open. */
static void
cmd_heap(
	struct fw_command *command)
{
	uint32_t base;
	uint32_t bytes;
	int error;

	/* The arguments. */
	base = fw_reader_address(command->reader);
	bytes = fw_reader_address(command->reader);
	if (command->reader->error)
		return;

	/* Not a staged command. */
	if (command->in_frame) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return;
	}

	/* The heap, while no object lives in the old one. */
	error = fw_heap_set(base, bytes);
	if (error != 0)
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
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

	/* The allocation the driver made (MEMORY names no device). */
	memory = fw_cmd_new_object(command, 0, id, FW_OBJ_MEMORY);
	if (memory == NULL)
		return;
	memory->a = address;
	memory->b = bytes;
}

/* FREE_MEMORY: [device][memory][u64 0]. */
static void
cmd_free_memory(
	struct fw_command *command)
{
	/* Forgets the allocation (the driver frees it after the session's fence). */
	fw_cmd_destroy_object(command, FW_OBJ_MEMORY);
}

/* DESTROY_DEVICE: [device][u64 0]. */
static void
cmd_destroy_device(
	struct fw_command *command)
{
	uint64_t device;

	/* The arguments. */
	device = fw_reader_u64(command->reader);
	fw_wire_expect(command, 0);
	if (command->reader->error)
		return;

	/* Returns every object made on the device. */
	fw_object_close_device(command->tag, device);
}

/* CREATE_SEMAPHORE: the create form with VkSemaphoreCreateInfo [sType][u64 0][flags]. */
static void
cmd_create_semaphore(
	struct fw_command *command)
{
	uint64_t device;
	uint64_t id;

	/* The create form. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* One queue in ring order: a semaphore needs only to exist. */
	(void)fw_cmd_new_object(command, device, id, FW_OBJ_SEMAPHORE);
}

/* DESTROY_SEMAPHORE: the destroy form. */
static void
cmd_destroy_semaphore(
	struct fw_command *command)
{
	/* Forgets the semaphore. */
	fw_cmd_destroy_object(command, FW_OBJ_SEMAPHORE);
}

/* BUFFER_GRANT, BUFFER_REVOKE: Amaterrace has no PROT capability. */
static void
cmd_unsupported(
	struct fw_command *command)
{
	/* The arguments are skipped by the command's end: the packet ends here. */
	command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
	command->stop = 1;
}
