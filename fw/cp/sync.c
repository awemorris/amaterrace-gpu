/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Synchronization inside a queue: pipeline barriers, events, and the
 * secondary command buffers a primary executes.
 *
 * One queue runs in ring order, so a barrier needs only the earlier work
 * finished and the caches afresh: WAIT_IDLE of every unit, then
 * INVALIDATE of the data and texture caches (the constant bank is loaded
 * again by each draw, the programs by LOAD_PROGRAM).  An event is a word
 * in the heap (1 set, 0 reset; the driver reads and writes it for
 * vkGetEventStatus, vkSetEvent and vkResetEvent: CREATE_EVENT's result
 * gives its address in aux); vkCmdSetEvent writes it after the earlier
 * work (RESULT), vkCmdWaitEvents waits for it (WAIT_FENCE).
 */

#include "fw.h"
#include "ghci_packets.h"

/* An event's block: its status word first. */
#define SYNC_EVENT_BYTES 64u

static void sync_barrier(void);
static void sync_skip_barriers(struct fw_command *command);
static void sync_event(struct fw_command *command, uint32_t status);

/* CREATE_EVENT: the create form with VkEventCreateInfo; aux is the event's address. */
void
fw_cmd_create_event(
	struct fw_command *command)
{
	struct fw_object *event;
	uint32_t zeros[2];
	uint64_t device;
	uint64_t id;
	int error;

	/* [sType][u64 0][flags]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The event and its word (the work's µops write and wait on it: a visible block), reset. */
	event = fw_cmd_new_object(command, device, id, FW_OBJ_EVENT);
	if (event == NULL)
		return;
	zeros[0] = 0;
	zeros[1] = 0;
	error = fw_object_block_visible(event, SYNC_EVENT_BYTES);
	if (error == 0)
		error = fw_copy_out(event->block, zeros, sizeof(zeros));
	if (error != 0) {
		fw_object_destroy(event);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* The driver learns where the word is. */
	command->aux = event->block;
}

/* DESTROY_EVENT: the destroy form. */
void
fw_cmd_destroy_event(
	struct fw_command *command)
{
	/* Forgets the event. */
	fw_cmd_destroy_object(command, FW_OBJ_EVENT);
}

/* CMD_SET_EVENT: [cb][event][stage mask]. */
void
fw_cmd_set_event(
	struct fw_command *command)
{
	/* The word becomes 1 after the earlier work. */
	sync_event(command, 1);
}

/* CMD_RESET_EVENT: [cb][event][stage mask]. */
void
fw_cmd_reset_event(
	struct fw_command *command)
{
	/* The word becomes 0 after the earlier work. */
	sync_event(command, 0);
}

/*
 * CMD_WAIT_EVENTS: [cb][u32 n][u64 n][events][src stages][dst stages]
 * [memory, buffer and image barriers].
 */
void
fw_cmd_wait_events(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *event;
	uint64_t events[16];
	uint32_t payload[2];
	uint64_t id;
	uint64_t count;
	uint64_t index;
	int error;

	/* The arguments; the barriers are kept by the wait and a barrier. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > 16u)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		events[index] = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	sync_skip_barriers(command);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf == NULL)
		return;

	/* Each event's word reaches 1, then the barrier. */
	fw_emit_begin(cmdbuf, command->tag);
	for (index = 0; index < count; index++) {
		event = fw_object_find(command->tag, events[index], FW_OBJ_EVENT);
		if (event == NULL) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			continue;
		}
		payload[0] = event->block;
		payload[1] = 1;
		fw_emit_op(GHCI_OP_WAIT_FENCE, 0, payload, 2);
	}
	sync_barrier();
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/*
 * CMD_PIPELINE_BARRIER: [cb][src stages][dst stages][dependency flags]
 * [memory, buffer and image barriers].
 */
void
fw_cmd_pipeline_barrier(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t id;
	int error;

	/* The arguments (the layouts mean nothing to linear images). */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	sync_skip_barriers(command);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf == NULL)
		return;

	/* The earlier work done, the caches afresh. */
	fw_emit_begin(cmdbuf, command->tag);
	sync_barrier();
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_EXECUTE_COMMANDS: [cb][u32 n][u64 n][secondary command buffers]. */
void
fw_cmd_execute_commands(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *secondary;
	struct fw_rstate *state;
	uint64_t id;
	uint64_t count;
	uint64_t index;
	uint64_t secondary_id;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	state = NULL;
	cmdbuf = NULL;
	if (!command->reader->error)
		state = fw_cmd_record_state(command, id, &cmdbuf);

	/* Each secondary's recording, copied into the primary's. */
	for (index = 0; index < count && !command->reader->error; index++) {
		secondary_id = fw_reader_u64(command->reader);
		if (state == NULL)
			continue;
		secondary = fw_object_find(command->tag, secondary_id, FW_OBJ_CMDBUF);
		if (secondary == NULL || secondary->state != FW_CB_EXECUTABLE ||
		    (secondary->flags & FW_OBJF_SECONDARY) == 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			continue;
		}
		error = fw_record_append(cmdbuf, secondary);
		if (error != 0)
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
	}

	/* The secondaries wrote STATE: the next draw writes its pipeline's again. */
	if (state != NULL) {
		state->emitted[FW_BIND_GRAPHICS] = 0;
		state->emitted[FW_BIND_COMPUTE] = 0;
	}
}

/* Builds a barrier: the earlier work done, the data and texture caches afresh. */
static void
sync_barrier(void)
{
	/* WAIT_IDLE of every unit, then INVALIDATE of D$ and T$. */
	fw_emit_op(GHCI_OP_WAIT_IDLE, 0, NULL, 0);
	fw_emit_op(GHCI_OP_INVALIDATE, 0x3u, NULL, 0);
}

/*
 * Skips the three barrier arrays: [u32 n][u64 n][VkMemoryBarrier: sType,
 * u64 0, two masks], the buffer barriers (sType, u64 0, 4 words, buffer,
 * two u64) and the image barriers (sType, u64 0, 6 words, image, 5
 * words).
 */
static void
sync_skip_barriers(
	struct fw_command *command)
{
	static const uint32_t bytes[3] = { 4u + 8u + 8u, 4u + 8u + 16u + 8u + 16u, 4u + 8u + 24u + 8u + 20u };
	uint64_t count;
	uint32_t kind;

	/* Each array: its counts, then its fixed-size elements. */
	for (kind = 0; kind < 3u; kind++) {
		(void)fw_reader_u32(command->reader);
		count = fw_reader_u64(command->reader);
		if (count > 0x10000u) {
			command->reader->error = 1;
			return;
		}
		fw_reader_skip(command->reader, (uint32_t)count * bytes[kind]);
	}
}

/* Sets or resets an event when the earlier work is done: RESULT {status, 0} at its word. */
static void
sync_event(
	struct fw_command *command,
	uint32_t status)
{
	struct fw_object *cmdbuf;
	struct fw_object *event;
	uint32_t payload[3];
	uint64_t id;
	uint64_t event_id;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	event_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	if (cmdbuf == NULL)
		return;

	/* An event of the session. */
	event = fw_object_find(command->tag, event_id, FW_OBJ_EVENT);
	if (event == NULL) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The word, after the earlier work. */
	payload[0] = event->block;
	payload[1] = status;
	payload[2] = 0;
	fw_emit_begin(cmdbuf, command->tag);
	fw_emit_op(GHCI_OP_RESULT, 0, payload, 3);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}
