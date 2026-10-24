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
	(void)payload;
	(void)count;

	/* No marker is defined yet but the data, which the replay skips. */
	switch (code) {
	default:
		return -1;
	}
}
