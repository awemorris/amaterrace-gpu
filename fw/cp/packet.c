/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * One class V packet: dword1 the gpu-op, dword2 its flags, dword3 the
 * result record's address, then the arguments.  A GHCI_FRAME packet names
 * a frame of staged records instead; each record's result goes to the
 * frame's result page as it is decoded.  At the end the packet's result
 * is stored, every write is answered and IRQ_STATUS.RESULT is raised;
 * then the submits' replays run (vkQueueSubmit has answered while the
 * units work), and DONE lets the ring move on (the µops given meanwhile
 * run first: DONE waits for the FIFO to drain).
 */

#include "fw.h"
#include "hw.h"
#include "ghci_frame.h"

/* Bytes of one result record {VkResult, aux}. */
#define PACKET_RESULT_BYTES 8u

static void packet_frame(struct fw_reader *packet, uint32_t tag, int32_t *status, uint32_t *aux);
static int packet_result(uint32_t address, int32_t status, uint32_t aux);

/*
 * Decodes the waiting class V packet and finishes it.
 */
void
fw_packet_run(
	uint32_t info)
{
	struct fw_reader packet;
	struct fw_command command;
	uint32_t number;
	uint32_t flags;
	uint32_t result;
	uint32_t tag;
	int32_t status;
	uint32_t aux;
	int error;
	int flushed;

	/* The packet's dwords after dword0. */
	tag = info & 0xFFu;
	fw_reader_init(&packet, hw_read(HW_PKT_ADDR), hw_read(HW_PKT_DWORDS) * 4u);

	/* dword1-3: the gpu-op, its flags, the result's address. */
	number = fw_reader_u32(&packet);
	flags = fw_reader_u32(&packet);
	result = fw_reader_u32(&packet);
	status = FW_VK_SUCCESS;
	aux = 0;

	/* A frame, one command carried in the packet, or a packet too short. */
	if (packet.error) {
		status = FW_VK_ERROR_UNKNOWN;
		flags = 0;
	} else if (number == GHCI_GPU_OP_FRAME) {
		packet_frame(&packet, tag, &status, &aux);
	} else {
		command.number = number;
		command.tag = tag;
		command.reader = &packet;
		command.in_frame = 0;

		/* INIT and the diagnostics write their reply where the packet's result goes. */
		command.reply = 0;
		if ((flags & GHCI_V_RESULT) != 0)
			command.reply = result;

		/* Carries the command out. */
		fw_command_decode(&command);
		status = command.status;
		aux = command.aux;
	}

	/*
	 * The packet's result when the sender asked for one, after the
	 * frame's records; then every stored line is written and answered,
	 * and RESULT tells the host.
	 */
	error = 0;
	if ((flags & GHCI_V_RESULT) != 0)
		error = packet_result(result, status, aux);
	flushed = fw_store_flush();
	if ((flags & GHCI_V_RESULT) != 0 && error == 0 && flushed == 0)
		hw_write(HW_RESULT, 1);

	/*
	 * The submits' replays, after the host has the results; DONE comes
	 * after them, so the driver's FENCE after the packet follows the work.
	 */
	fw_submit_run();

	/* The ring moves on once the µops of the packet are taken. */
	hw_write(HW_DONE, 1);
}

/* Decodes the staged records of a GHCI_FRAME; status and aux are the frame's result. */
static void
packet_frame(
	struct fw_reader *packet,
	uint32_t tag,
	int32_t *status,
	uint32_t *aux)
{
	struct fw_reader frame;
	struct fw_command command;
	uint32_t staging;
	uint32_t bytes;
	uint32_t page;
	uint32_t records;
	uint32_t record;
	uint32_t index;
	int32_t pair[2];
	int error;

	/* dword4-8: the staging address, the frame's bytes, the result page, the records. */
	staging = fw_reader_address(packet);
	bytes = fw_reader_u32(packet);
	page = fw_reader_u32(packet);
	records = fw_reader_u32(packet);
	if (packet->error) {
		*status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* Each record: [number][flags][result index][arguments]. */
	fw_reader_init(&frame, staging, bytes);
	*status = FW_VK_SUCCESS;
	for (record = 0; record < records; record++) {
		command.number = fw_reader_u32(&frame);
		(void)fw_reader_u32(&frame);
		index = fw_reader_u32(&frame);
		if (frame.error) {
			*status = FW_VK_ERROR_UNKNOWN;
			break;
		}

		/* A command other than a submit sees the work of the submits before it. */
		if (command.number != GHCI_VK_QUEUE_SUBMIT)
			fw_submit_run();

		/* Carries the command out. */
		command.tag = tag;
		command.reader = &frame;
		command.in_frame = 1;
		command.reply = 0;
		fw_command_decode(&command);

		/* Its result record, at once (the driver reads them after RESULT). */
		if (index != GHCI_FRAME_NO_RESULT && index < records) {
			pair[0] = command.status;
			pair[1] = (int32_t)command.aux;
			error = fw_store(page + index * PACKET_RESULT_BYTES, pair, PACKET_RESULT_BYTES);
			if (error != 0) {
				*status = FW_VK_ERROR_DEVICE_LOST;
				break;
			}
		}

		/* A command whose end is unknown ends the frame with its result. */
		if (command.stop) {
			*status = command.status;
			record++;
			break;
		}
	}

	/* The frame's aux: how many records were decoded. */
	*aux = record;
}

/* Stores a packet's result record (the caller flushes it). */
static int
packet_result(
	uint32_t address,
	int32_t status,
	uint32_t aux)
{
	int32_t pair[2];
	int error;

	/* The record after the frame's own records (the store keeps the order). */
	pair[0] = status;
	pair[1] = (int32_t)aux;
	error = fw_store(address, pair, PACKET_RESULT_BYTES);
	if (error != 0)
		return -1;

	/* Succeeded: the record is in the store's line. */
	return 0;
}
