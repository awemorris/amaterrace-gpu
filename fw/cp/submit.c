/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * QUEUE_SUBMIT: the command buffers of each submit are replayed in order
 * (one queue in ring order, so the semaphores order nothing; the
 * driver's FENCE after the packet completes the work and signals the
 * fence), and the work the recordings left to the firmware (markers).
 */

#include "fw.h"
#include "ghci_frame.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/*
 * The last value written to the firmware's wait word (fw_wait_units); it
 * only grows, so a value read is never an earlier wait's.
 */
static uint32_t submit_wait_value;

static int submit_indirect(const uint32_t *payload);

/* QUEUE_SUBMIT: [queue][u32 count][u64 count][VkSubmitInfo...][fence]. */
void
fw_cmd_queue_submit(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	uint64_t submits;
	uint64_t submit;
	uint64_t buffers;
	uint64_t buffer;
	uint64_t id;
	int error;

	/* The queue (one queue) and the submit count. */
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	submits = fw_reader_u64(command->reader);

	/*
	 * Each VkSubmitInfo: [sType][u64 0][wait count][waits][stage masks]
	 * [command buffer count][command buffers][signal count][signals].
	 */
	for (submit = 0; submit < submits; submit++) {
		fw_wire_head(command);
		(void)fw_reader_u32(command->reader);
		fw_wire_skip_u64s(command);
		fw_wire_skip_u32s(command);
		(void)fw_reader_u32(command->reader);
		buffers = fw_reader_u64(command->reader);
		for (buffer = 0; buffer < buffers; buffer++) {
			id = fw_reader_u64(command->reader);
			if (command->reader->error)
				return;

			/* Only an executable primary command buffer of the session runs. */
			cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
			if (cmdbuf == NULL ||
			    cmdbuf->state != FW_CB_EXECUTABLE ||
			    (cmdbuf->flags & FW_OBJF_SECONDARY) != 0) {
				command->status = FW_VK_ERROR_UNKNOWN;
				continue;
			}

			/* Its µops to the sequencer. */
			error = fw_record_replay(cmdbuf, 0);
			if (error != 0) {
				command->status = FW_VK_ERROR_DEVICE_LOST;
				continue;
			}

			/* A one-time command buffer is spent. */
			if ((cmdbuf->flags & FW_OBJF_ONE_TIME) != 0)
				cmdbuf->state = FW_CB_INVALID;
		}

		/* The signal semaphores. */
		(void)fw_reader_u32(command->reader);
		fw_wire_skip_u64s(command);
	}

	/* The fence (the driver's, signalled by its FENCE after the packet). */
	(void)fw_reader_u64(command->reader);
}

/*
 * Waits until the units have done every µop given before: RESULT writes
 * a new value to the firmware's wait word after the earlier work (as a
 * FENCE does), and the firmware reads the word until it is there.
 *
 * Returns 0, or -1 when the memory refused a line.
 */
int
fw_wait_units(void)
{
	uint32_t line[FW_LINE_BYTES / 4u] __attribute__((aligned(FW_LINE_BYTES)));
	uint32_t payload[3];
	uint32_t address;
	int error;

	/* The next value, written after the earlier work. */
	submit_wait_value++;
	address = fw_builtin_wait_word();
	payload[0] = address;
	payload[1] = submit_wait_value;
	payload[2] = 0;
	fw_emit_begin(NULL, 0);
	fw_emit_op(GHCI_OP_WAIT_IDLE, 0, NULL, 0);
	fw_emit_op(GHCI_OP_RESULT, 0, payload, 3);
	(void)fw_emit_end();

	/* Reads the word until the value is there (the watchdog bounds a GPU that hangs). */
	do {
		error = fw_dma_read(address, line, 1);
		if (error != 0)
			return -1;
	} while (line[0] != submit_wait_value);

	/* Succeeded: the earlier work is done and its writes are in memory. */
	return 0;
}

/*
 * Runs a marker of a recording being replayed.
 *
 * Returns 0, or -1 when the marker is unknown or its work failed.
 */
int
fw_marker_run(
	uint32_t code,
	const uint32_t *payload,
	uint32_t count)
{
	int error;

	/* Each marker's work. */
	switch (code) {
	case FW_MARK_INDIRECT:
		if (count < 5u)
			return -1;
		error = submit_indirect(payload);
		break;
	case FW_MARK_QUERY_COPY:
		error = fw_query_copy(payload, count);
		break;
	default:
		error = -1;
		break;
	}

	/* A failed marker stops the replay. */
	if (error != 0)
		return -1;

	/* Succeeded: the marker's work is done or given to the units. */
	return 0;
}

/*
 * An indirect draw or dispatch: [kind][address][count][stride][bytes].
 * The parameters are read once the units have done the earlier work
 * (which may have written them), then each draw's parameters and DRAW, or
 * DISPATCH, go to the FIFO.
 */
static int
submit_indirect(
	const uint32_t *payload)
{
	uint32_t line[2u * FW_LINE_BYTES / 4u] __attribute__((aligned(FW_LINE_BYTES)));
	uint32_t args[5];
	uint32_t kind;
	uint32_t address;
	uint32_t draw;
	uint32_t words;
	uint32_t index;
	uint32_t base;
	int error;

	/* The parameters are in memory once the earlier work is done. */
	error = fw_wait_units();
	if (error != 0)
		return -1;

	/* Each draw (or the one dispatch), its parameters from the buffer. */
	kind = payload[0];
	words = 4;
	if (kind == 1u)
		words = 5;
	if (kind == 2u)
		words = 3;
	fw_emit_begin(NULL, 0);
	for (draw = 0; draw < payload[2]; draw++) {
		/* Inside the buffer; the lines that hold them. */
		address = payload[1] + draw * payload[3];
		if (draw * payload[3] + words * 4u > payload[4])
			break;
		base = address & ~(FW_LINE_BYTES - 1u);
		error = fw_dma_read(base, line, 2);
		if (error != 0)
			return -1;
		for (index = 0; index < words; index++)
			args[index] = line[(address - base) / 4u + index];

		/* The parameters, then DRAW or DISPATCH. */
		if (kind == 2u) {
			fw_emit_op(GHCI_OP_DISPATCH, 0, args, 3);
			continue;
		}
		fw_emit_set(GHCI_S_COUNT, args[0]);
		fw_emit_set(GHCI_S_INSTANCE_COUNT, args[1]);
		fw_emit_set(GHCI_S_FIRST, args[2]);
		if (kind == 1u) {
			fw_emit_set(GHCI_S_VERTEX_OFFSET, args[3]);
			fw_emit_set(GHCI_S_FIRST_INSTANCE, args[4]);
		} else {
			fw_emit_set(GHCI_S_VERTEX_OFFSET, 0);
			fw_emit_set(GHCI_S_FIRST_INSTANCE, args[3]);
		}
		fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
	}
	(void)fw_emit_end();

	/* Succeeded: the draws went to the FIFO. */
	return 0;
}
