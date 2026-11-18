/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The µops: the class N packets the firmware gives the sequencer through
 * the window's UOP_FIFO, built into a command buffer's recording (which a
 * QUEUE_SUBMIT replays) or sent at once.
 *
 * The builder keeps one packet open: consecutive STATE writes share one
 * SET_REG packet, and any other µop closes it first, so the order of the
 * writes and the µops is the order of the calls.  A recording may also
 * hold markers: class 3 packets whose first payload word names work the
 * replay does itself (record.c), never given to the FIFO.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_packets.h"

/* The (index, value) pairs of one SET_REG packet. */
#define UOP_SET_PAIRS 60u

/*
 * Words of the µop packet being written to the FIFO that are still to
 * come; 0 means the next word is a header.
 */
static uint32_t uop_left;

/*
 * The packet being built: its words, how many there are, and how many
 * SET_REG pairs it holds (0: it is not a SET_REG packet).
 */
static uint32_t emit_words[1u + 2u * UOP_SET_PAIRS];
static uint32_t emit_count;
static uint32_t emit_pairs;

/*
 * Where the packets go (a recording, or the FIFO when NULL), the JOB_TAG
 * the µops carry, and the first failure (a full heap) since
 * fw_emit_begin.
 */
static struct fw_object *emit_cmdbuf;
static uint32_t emit_tag;
static int emit_failed;

static void uop_emit(uint32_t word);
static void emit_close(void);

/*
 * Gives whole µop packets to the sequencer.
 */
void
fw_uop_send(
	const uint32_t *words,
	uint32_t count)
{
	uint32_t index;

	/* One FIFO write per word; the last of each packet is marked. */
	for (index = 0; index < count; index++)
		uop_emit(words[index]);
}

/*
 * Forgets a packet left half written to the FIFO (at start-up).
 */
void
fw_uop_reset(void)
{
	/* The next word is a header. */
	uop_left = 0;
}

/*
 * Starts building µops into a command buffer's recording, or for the FIFO
 * (NULL), with the JOB_TAG of a session.
 */
void
fw_emit_begin(
	struct fw_object *cmdbuf,
	uint32_t tag)
{
	/* A new target, nothing built yet, no failure. */
	emit_cmdbuf = cmdbuf;
	emit_tag = tag;
	emit_count = 0;
	emit_pairs = 0;
	emit_failed = 0;
}

/*
 * Ends building: the open packet goes out.
 *
 * Returns 0, or -1 when a packet did not fit the heap since
 * fw_emit_begin.
 */
int
fw_emit_end(void)
{
	/* The open packet. */
	emit_close();

	/* A failure on the way. */
	if (emit_failed)
		return -1;

	/* Succeeded: every packet is recorded or sent. */
	return 0;
}

/*
 * Writes one STATE word (SET_REG).
 */
void
fw_emit_set(
	uint32_t index,
	uint32_t value)
{
	/* A packet of another µop, or a full one, is closed first. */
	if (emit_count != 0 && (emit_pairs == 0 || emit_pairs == UOP_SET_PAIRS))
		emit_close();

	/* Opens a SET_REG packet. */
	if (emit_count == 0) {
		emit_words[0] = 0;
		emit_count = 1;
	}

	/* The pair; the header is written when the packet closes. */
	emit_words[emit_count++] = index;
	emit_words[emit_count++] = value;
	emit_pairs++;
}

/*
 * Adds a class N µop with its payload (at most FW_EMIT_PAYLOAD words).
 */
void
fw_emit_op(
	uint32_t op,
	uint32_t flags,
	const uint32_t *payload,
	uint32_t count)
{
	uint32_t index;

	/* The open packet goes first; a payload too long is a firmware fault. */
	emit_close();
	if (count > FW_EMIT_PAYLOAD) {
		emit_failed = 1;
		return;
	}

	/* The header and the payload. */
	emit_words[0] = GHCI_PKT_N(GHCI_PKT_CLASS_STD, op, emit_tag, flags, count);
	for (index = 0; index < count; index++)
		emit_words[1u + index] = payload[index];
	emit_count = 1u + count;
	emit_close();
}

/*
 * Adds a marker for the replay: a class 3 packet whose first payload word
 * is the code, then fewer than FW_EMIT_PAYLOAD words for it.
 */
void
fw_emit_marker(
	uint32_t code,
	const uint32_t *payload,
	uint32_t count)
{
	uint32_t index;

	/* Markers are for recordings only: the FIFO takes class N alone. */
	emit_close();
	if (emit_cmdbuf == NULL || count >= FW_EMIT_PAYLOAD) {
		emit_failed = 1;
		return;
	}

	/* The padding header, the code and the payload. */
	emit_words[0] = GHCI_PKT_PAD(count + 1u);
	emit_words[1] = code;
	for (index = 0; index < count; index++)
		emit_words[2u + index] = payload[index];
	emit_count = 2u + count;
	emit_close();
}

/*
 * Puts data into the recording for the units to read when it runs.
 *
 * Returns the data's GPU address, or 0 (and the failure) when there is no
 * recording or no room.
 */
uint32_t
fw_emit_data(
	const uint32_t *words,
	uint32_t count)
{
	uint32_t address;
	int error;

	/* The data goes after the packets before it. */
	emit_close();
	if (emit_cmdbuf == NULL) {
		emit_failed = 1;
		return 0;
	}

	/* Into the recording. */
	error = fw_record_data(emit_cmdbuf, words, count, &address);
	if (error != 0) {
		emit_failed = 1;
		return 0;
	}

	/* Succeeded: the data's address. */
	return address;
}

/*
 * Reports whether building has failed since fw_emit_begin.
 */
int
fw_emit_error(void)
{
	/* The sticky failure. */
	if (emit_failed)
		return 1;

	/* Nothing failed. */
	return 0;
}

/* Writes one µop dword to the FIFO, marking the last word of its packet. */
static void
uop_emit(
	uint32_t word)
{
	/* A header opens a packet of [7:0] payload words. */
	if (uop_left == 0) {
		uop_left = word & 0xFFu;
	} else {
		uop_left--;
	}

	/* The packet's last word goes to UOP_LAST. */
	if (uop_left == 0) {
		hw_write(HW_UOP_LAST, word);
	} else {
		hw_write(HW_UOP, word);
	}
}

/* Closes the packet being built and puts it into the recording or the FIFO. */
static void
emit_close(void)
{
	int error;

	/* Nothing open. */
	if (emit_count == 0)
		return;

	/* A SET_REG packet's header counts its pairs. */
	if (emit_pairs != 0)
		emit_words[0] = GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_SET_REG, emit_tag, 0, 2u * emit_pairs);

	/* Into the recording, or to the FIFO now. */
	if (emit_cmdbuf != NULL) {
		error = fw_record_words(emit_cmdbuf, emit_words, emit_count);
		if (error != 0)
			emit_failed = 1;
	} else {
		fw_uop_send(emit_words, emit_count);
	}

	/* The next call opens a new packet. */
	emit_count = 0;
	emit_pairs = 0;
}
