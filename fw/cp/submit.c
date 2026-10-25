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
 *
 * vkQueueSubmit does not wait for the work.  The decoder checks the
 * command buffers and keeps them in a list; the replays run after the
 * packet's results are written and RESULT is raised (packet.c), or
 * before the next record of the frame that is not a submit, so every
 * other command still sees the work of the submits before it.  DONE
 * follows the replays, so the driver's FENCE after the packet still
 * follows the work.  A replay that fails then (the memory refused a
 * line of a recording, a marker failed) loses its session: the
 * session's later submits answer VK_ERROR_DEVICE_LOST and run nothing.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_frame.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* The command buffers whose replays wait in the list at most. */
#define SUBMIT_PENDING 16u

/*
 * One command buffer waiting for its replay: the command buffer, its
 * session, and whether the submit made it invalid (a one-time command
 * buffer), which a malformed submit undoes.
 */
struct submit_entry {
	struct fw_object *cmdbuf;
	uint32_t tag;
	int spent;
};

/*
 * The last value written to the firmware's wait word (fw_wait_units); it
 * only grows, so a value read is never an earlier wait's.
 */
static uint32_t submit_wait_value;

/*
 * The replays waiting in submit order, how many wait, and the first
 * entry of the submit being decoded (a malformed submit drops its own
 * entries from there).  The firmware decodes one packet at a time, and
 * the list is empty between packets.
 */
static struct submit_entry submit_list[SUBMIT_PENDING];
static uint32_t submit_count;
static uint32_t submit_first;

static void submit_defer(uint32_t tag, struct fw_object *cmdbuf);
static void submit_drop(void);
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
	int lost;

	/* A session whose earlier replay failed runs no more work. */
	lost = fw_session_lost(command->tag);

	/* The command's entries start at the end of the list. */
	submit_first = submit_count;

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
			if (command->reader->error) {
				/* A malformed submit runs nothing of its own. */
				submit_drop();
				return;
			}

			/* Only an executable primary command buffer of the session runs. */
			cmdbuf = fw_object_find(command->tag, id, FW_OBJ_CMDBUF);
			if (cmdbuf == NULL ||
			    cmdbuf->state != FW_CB_EXECUTABLE ||
			    (cmdbuf->flags & FW_OBJF_SECONDARY) != 0) {
				command->status = FW_VK_ERROR_UNKNOWN;
				continue;
			}

			/* A lost session's command buffer runs no more. */
			if (lost) {
				command->status = FW_VK_ERROR_DEVICE_LOST;
				continue;
			}

			/* Its replay waits for the packet's results (fw_submit_run). */
			submit_defer(command->tag, cmdbuf);
		}

		/* The signal semaphores. */
		(void)fw_reader_u32(command->reader);
		fw_wire_skip_u64s(command);
	}

	/* The fence (the driver's, signalled by its FENCE after the packet). */
	(void)fw_reader_u64(command->reader);

	/* A malformed submit runs nothing of its own. */
	if (command->reader->error)
		submit_drop();
}

/*
 * Runs the replays waiting in the list, in submit order, and empties it.
 * A replay that fails loses its session; the others still run.
 */
void
fw_submit_run(void)
{
	struct submit_entry *entry;
	uint32_t count;
	uint32_t index;
	int error;

	/* The list is empty from here on (a replay adds nothing to it). */
	count = submit_count;
	submit_count = 0;
	submit_first = 0;

	/* Each command buffer's µops to the sequencer, and its markers. */
	for (index = 0; index < count; index++) {
		entry = &submit_list[index];
		error = fw_record_replay(entry->cmdbuf, 0);
		if (error != 0) {
			/* Its submit has answered: the session is lost instead. */
			fw_session_lose(entry->tag);
		}
	}

	/* What the markers stored (query results) is written and answered. */
	if (count != 0) {
		error = fw_store_flush();
		if (error != 0)
			fw_session_lose(submit_list[0].tag);
	}
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
	(void)fw_emit_end();

	/*
	 * The RESULT is the firmware's own (its wait word is no session's): SELF
	 * keeps session protection from checking it for the packet's session.
	 */
	hw_write(HW_UOP_SELF, 1u);
	fw_emit_begin(NULL, 0);
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
	uint32_t lines;
	uint32_t mode;
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
		/*
		 * Only the lines that hold them (a line past the buffer may be
		 * no memory of the session's); they are the session's memory, so
		 * the reads are checked for its slot.
		 */
		base = address & ~(FW_LINE_BYTES - 1u);
		lines = (address + words * 4u - 1u - base) / FW_LINE_BYTES + 1u;
		mode = fw_dma_mode(FW_DMA_CHK);
		error = fw_dma_read(base, line, lines);
		(void)fw_dma_mode(mode);
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

/*
 * Adds a command buffer to the list of waiting replays; a full list
 * runs the waiting replays first (they are then older than the submit's
 * error, as when the firmware replayed while it decoded).
 */
static void
submit_defer(
	uint32_t tag,
	struct fw_object *cmdbuf)
{
	struct submit_entry *entry;

	/* A full list makes room by running what waits. */
	if (submit_count == SUBMIT_PENDING)
		fw_submit_run();

	/* The entry, after the earlier ones. */
	entry = &submit_list[submit_count];
	entry->cmdbuf = cmdbuf;
	entry->tag = tag;
	entry->spent = 0;
	submit_count++;

	/* A one-time command buffer is spent by its submit. */
	if ((cmdbuf->flags & FW_OBJF_ONE_TIME) != 0) {
		cmdbuf->state = FW_CB_INVALID;
		entry->spent = 1;
	}
}

/*
 * Drops the entries of the submit being decoded (it is malformed): its
 * one-time command buffers are executable again.
 */
static void
submit_drop(void)
{
	uint32_t index;

	/* Each entry of the submit, back to its state before it. */
	for (index = submit_first; index < submit_count; index++) {
		if (submit_list[index].spent)
			submit_list[index].cmdbuf->state = FW_CB_EXECUTABLE;
	}

	/* The earlier submits' entries stay. */
	submit_count = submit_first;
}
