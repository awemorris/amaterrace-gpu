/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Command pools and command buffers: their creation, Vulkan's lifecycle
 * (initial, recording, executable, invalid), and the finding of the
 * command buffer a recorded command goes into.  The first failure of a
 * recorded command is kept and is vkEndCommandBuffer's result, as the
 * Vulkan specification lets an implementation report it.
 */

#include "fw.h"

/* VkCommandBufferLevel and VkCommandBufferUsageFlags. */
#define CB_LEVEL_SECONDARY 1u
#define CB_USAGE_ONE_TIME 0x1u
#define CB_USAGE_RENDER_PASS_CONTINUE 0x2u

static void cb_reset(struct fw_object *cmdbuf);

/* CREATE_COMMAND_POOL: the create form with VkCommandPoolCreateInfo. */
void
fw_cmd_create_command_pool(
	struct fw_command *command)
{
	uint64_t device;
	uint64_t id;

	/* [sType][u64 0][flags][queue family]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The pool owns its command buffers. */
	(void)fw_cmd_new_object(command, device, id, FW_OBJ_CMD_POOL);
}

/* DESTROY_COMMAND_POOL: the destroy form; the pool's command buffers go with it. */
void
fw_cmd_destroy_command_pool(
	struct fw_command *command)
{
	/* Forgets the pool and its command buffers. */
	fw_cmd_destroy_object(command, FW_OBJ_CMD_POOL);
}

/* RESET_COMMAND_POOL: [device][pool][u32 flags]. */
void
fw_cmd_reset_command_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint64_t id;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Every command buffer of the pool back to the initial state. */
	pool = fw_object_find(command->tag, id, FW_OBJ_CMD_POOL);
	if (pool == NULL) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	fw_object_each_child(pool, cb_reset);
}

/* ALLOCATE_COMMAND_BUFFERS: [device][u64 1][VkCommandBufferAllocateInfo][u64 count][ids]. */
void
fw_cmd_allocate_command_buffers(
	struct fw_command *command)
{
	struct fw_object *pool;
	struct fw_object *cmdbuf;
	uint64_t device;
	uint64_t pool_id;
	uint64_t count;
	uint64_t index;
	uint64_t id;
	uint32_t level;

	/* [device][u64 1][sType][u64 0][pool][level][count] and the array's count. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	pool_id = fw_reader_u64(command->reader);
	level = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;

	/* An existing pool of the session. */
	pool = fw_object_find(command->tag, pool_id, FW_OBJ_CMD_POOL);
	if (pool == NULL)
		command->status = FW_VK_ERROR_UNKNOWN;

	/* One command buffer per identity; all are read even after a failure. */
	for (index = 0; index < count; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error || command->status != FW_VK_SUCCESS)
			continue;

		/* An initial command buffer of the pool. */
		cmdbuf = fw_cmd_new_object(command, device, id, FW_OBJ_CMDBUF);
		if (cmdbuf == NULL)
			continue;
		cmdbuf->parent = pool;
		cmdbuf->state = FW_CB_INITIAL;
		if (level == CB_LEVEL_SECONDARY)
			cmdbuf->flags |= FW_OBJF_SECONDARY;
	}
}

/* FREE_COMMAND_BUFFERS: [device][pool][u32 count][u64 count][ids]. */
void
fw_cmd_free_command_buffers(
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

	/* Frees each named command buffer (the null handle frees nothing). */
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
void
fw_cmd_begin_command_buffer(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint64_t id;
	uint64_t inheritance;
	uint64_t render_pass;
	uint64_t framebuffer;
	uint32_t subpass;
	uint32_t flags;
	int error;

	/* [cb][u64 1][sType][u64 0][flags][inheritance presence]. */
	render_pass = 0;
	framebuffer = 0;
	subpass = 0;
	id = fw_reader_u64(command->reader);
	fw_wire_expect(command, 1);
	fw_wire_head(command);
	flags = fw_reader_u32(command->reader);
	inheritance = fw_reader_u64(command->reader);

	/* A secondary command buffer's inheritance: its render pass, subpass and framebuffer. */
	if (inheritance == 1) {
		fw_wire_head(command);
		render_pass = fw_reader_u64(command->reader);
		subpass = fw_reader_u32(command->reader);
		framebuffer = fw_reader_u64(command->reader);
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
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* Begin resets the recording (every pool allows the implicit reset here). */
	cb_reset(cmdbuf);
	error = fw_rstate_begin(cmdbuf);
	if (error != 0) {
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* A secondary command buffer that continues a render pass records inside it. */
	state = fw_rstate(cmdbuf);
	if (state != NULL &&
	    (cmdbuf->flags & FW_OBJF_SECONDARY) != 0 &&
	    (flags & CB_USAGE_RENDER_PASS_CONTINUE) != 0) {
		state->in_pass = 1;
		state->render_pass = render_pass;
		state->framebuffer = framebuffer;
		state->subpass = subpass;
	}

	/* Recording, with the one-time flag for its submit. */
	cmdbuf->state = FW_CB_RECORDING;
	cmdbuf->c = (uint32_t)FW_VK_SUCCESS;
	cmdbuf->flags &= (uint16_t)~FW_OBJF_ONE_TIME;
	if ((flags & CB_USAGE_ONE_TIME) != 0)
		cmdbuf->flags |= FW_OBJF_ONE_TIME;
}

/* END_COMMAND_BUFFER: [command buffer]. */
void
fw_cmd_end_command_buffer(
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
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* Its recording state is no longer needed. */
	fw_rstate_end(cmdbuf);

	/* The first failure of a record is the result. */
	command->status = (int32_t)cmdbuf->c;
	cmdbuf->state = FW_CB_EXECUTABLE;
	if (command->status != FW_VK_SUCCESS)
		cmdbuf->state = FW_CB_INVALID;
}

/* RESET_COMMAND_BUFFER: [command buffer][u32 flags]. */
void
fw_cmd_reset_command_buffer(
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
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	cb_reset(cmdbuf);
}

/*
 * Finds the command buffer a recorded command goes into: one of the
 * session that is recording; another is the driver's error.
 *
 * Returns NULL (with the command's status) when there is none.
 */
struct fw_object *
fw_cmd_recording(
	struct fw_command *command,
	uint64_t id)
{
	struct fw_object *cmdbuf;

	/* The session's command buffer. */
	cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
	if (cmdbuf == NULL || cmdbuf->state != FW_CB_RECORDING) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return NULL;
	}

	/* Succeeded: records go into it. */
	return cmdbuf;
}

/*
 * Keeps the first failure of a recorded command, which ends the recording
 * as invalid.
 */
void
fw_cmd_record_error(
	struct fw_object *cmdbuf,
	int32_t status)
{
	/* An earlier failure stays the result. */
	if ((int32_t)cmdbuf->c != FW_VK_SUCCESS)
		return;
	cmdbuf->c = (uint32_t)status;
}

/* Puts a command buffer back into the initial state, its recording gone. */
static void
cb_reset(
	struct fw_object *cmdbuf)
{
	/* The recording and the recording state. */
	fw_record_clear(cmdbuf);
	fw_rstate_end(cmdbuf);

	/* Initial, without a failure. */
	cmdbuf->state = FW_CB_INITIAL;
	cmdbuf->c = (uint32_t)FW_VK_SUCCESS;
}
