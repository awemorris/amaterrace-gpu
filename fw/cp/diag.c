/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * GHCI_INIT and the diagnostics (docs/ghci.md section 7.2): the driver's
 * handshake with the firmware, an echo of the packet's words, a pattern
 * written to GPU memory and the sums of the words read from it.  Each
 * answers with a reply of GHCI_REPLY_WORDS words at the packet's result
 * address; this file stores the words after the first two (the VkResult
 * and the aux, which packet.c stores), and every word the gpu-op does not
 * name as 0.  They change nothing in the firmware's state, and their
 * accesses are the driver's (no session's protection mode).
 */

#include "fw.h"
#include "hw.h"
#include "ghci_frame.h"

/* The lines of the buffer the pattern is made in and the words are read into. */
#define DIAG_LINES 8u

/* The bytes of that buffer. */
#define DIAG_BUFFER_BYTES (DIAG_LINES * FW_LINE_BYTES)

/* The words of one line. */
#define DIAG_LINE_WORDS (FW_LINE_BYTES / 4u)

/*
 * The lines a DIAG_WRITE makes its pattern in and a DIAG_SUM reads into.
 *
 * Only one gpu-op runs at a time, and neither keeps anything in it after
 * it answers.
 */
static uint32_t diag_buffer[DIAG_BUFFER_BYTES / 4u] __attribute__((aligned(FW_LINE_BYTES)));

static int diag_ready(struct fw_command *command);
static int diag_range(uint32_t address, uint32_t bytes);
static void diag_reply(struct fw_command *command, const uint32_t *words);

/*
 * Carries out GHCI_INIT: [u32 token][u32 protocol].
 *
 * The reply tells the driver which firmware runs and that the packet's
 * words came through: the token, its complement, the version, the
 * protocol, the features and where the packet was read from.
 */
void
fw_cmd_init(
	struct fw_command *command)
{
	uint32_t words[GHCI_REPLY_WORDS];
	uint32_t token;
	uint32_t protocol;
	uint32_t features;
	int ready;
	int present;

	/* The arguments. */
	token = fw_reader_u32(command->reader);
	protocol = fw_reader_u32(command->reader);
	ready = diag_ready(command);
	if (!ready)
		return;

	/* The features: the diagnostics always, the objects, the protection, the heap. */
	features = GHCI_INIT_F_DIAG | GHCI_INIT_F_VULKAN;
	present = fw_prot_present();
	if (present)
		features |= GHCI_INIT_F_PROT;
	present = fw_heap_ready();
	if (present)
		features |= GHCI_INIT_F_HEAP;

	/* The reply's words; the aux is the token. */
	memset(words, 0, sizeof(words));
	words[GHCI_INIT_NOT_TOKEN] = ~token;
	words[GHCI_INIT_VERSION] = FW_VERSION;
	words[GHCI_INIT_PROTOCOL_WORD] = GHCI_INIT_PROTOCOL;
	words[GHCI_INIT_FEATURES] = features;
	words[GHCI_INIT_LINE] = FW_LINE_BYTES;
	words[GHCI_INIT_SESSIONS] = FW_SESSIONS;
	words[GHCI_INIT_PACKET] = hw_read(HW_PKT_ADDR);
	words[GHCI_INIT_COMMIT_HASH] = FW_COMMIT_HASH;
	command->aux = token;

	/* A driver of another major version of the protocol is told so, with the rest of the reply. */
	if ((protocol >> 16) != (GHCI_INIT_PROTOCOL >> 16))
		command->status = FW_VK_ERROR_INCOMPATIBLE_DRIVER;

	/* The words after the result and the aux. */
	diag_reply(command, words);
}

/*
 * Carries out GHCI_DIAG_ECHO: [u32 count][count words], which the reply
 * gives back after the count.
 */
void
fw_cmd_diag_echo(
	struct fw_command *command)
{
	uint32_t words[GHCI_REPLY_WORDS];
	uint32_t count;
	uint32_t index;
	int ready;

	/* The count, then as many words as it says (at most the reply's room). */
	memset(words, 0, sizeof(words));
	count = fw_reader_u32(command->reader);
	if (count <= GHCI_DIAG_ECHO_WORDS) {
		for (index = 0; index < count; index++)
			words[2u + index] = fw_reader_u32(command->reader);
	}
	ready = diag_ready(command);
	if (!ready)
		return;

	/* A count the reply cannot hold echoes nothing. */
	if (count > GHCI_DIAG_ECHO_WORDS) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		memset(words, 0, sizeof(words));
		diag_reply(command, words);
		return;
	}

	/* The count, and the words as they came. */
	command->aux = count;
	diag_reply(command, words);
}

/*
 * Carries out GHCI_DIAG_WRITE: [u64 address][u32 bytes][u32 pattern]
 * [u32 step], word i being pattern + i x step.
 *
 * Every line's write is answered before the next is made (fw_dma_write
 * waits), so the reply comes after the whole pattern is in memory.
 */
void
fw_cmd_diag_write(
	struct fw_command *command)
{
	uint32_t words[GHCI_REPLY_WORDS];
	uint32_t address;
	uint32_t bytes;
	uint32_t pattern;
	uint32_t step;
	uint32_t done;
	uint32_t part;
	uint32_t index;
	uint32_t value;
	uint32_t mode;
	int ready;
	int usable;
	int error;

	/* The arguments. */
	address = fw_reader_address(command->reader);
	bytes = fw_reader_u32(command->reader);
	pattern = fw_reader_u32(command->reader);
	step = fw_reader_u32(command->reader);
	ready = diag_ready(command);
	if (!ready)
		return;

	/* A range of whole lines, not too long; otherwise nothing is written. */
	memset(words, 0, sizeof(words));
	usable = diag_range(address, bytes);
	if (!usable) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		diag_reply(command, words);
		return;
	}

	/* The pattern, a buffer of lines at a time, as the driver's own accesses. */
	mode = fw_dma_mode(0);
	value = pattern;
	done = 0;
	while (done < bytes) {
		/* The buffer's words of the pattern. */
		part = bytes - done;
		if (part > DIAG_BUFFER_BYTES)
			part = DIAG_BUFFER_BYTES;
		for (index = 0; index < part / 4u; index++) {
			diag_buffer[index] = value;
			value += step;
		}

		/* Their lines, answered before the next ones are made. */
		error = fw_dma_write(address + done, diag_buffer, part / FW_LINE_BYTES);
		if (error != 0) {
			command->status = FW_VK_ERROR_DEVICE_LOST;
			break;
		}
		done += part;
	}

	/* The protection mode of the packet again. */
	(void)fw_dma_mode(mode);

	/* The bytes written. */
	command->aux = done;
	diag_reply(command, words);
}

/*
 * Carries out GHCI_DIAG_SUM: [u64 address][u32 bytes]; the reply has the
 * sum of the words, the sum weighted by their place, the first four words
 * and the last.
 */
void
fw_cmd_diag_sum(
	struct fw_command *command)
{
	uint32_t words[GHCI_REPLY_WORDS];
	uint32_t address;
	uint32_t bytes;
	uint32_t done;
	uint32_t part;
	uint32_t index;
	uint32_t place;
	uint32_t word;
	uint32_t plain;
	uint32_t weighted;
	uint32_t mode;
	int ready;
	int usable;
	int error;

	/* The arguments. */
	address = fw_reader_address(command->reader);
	bytes = fw_reader_u32(command->reader);
	ready = diag_ready(command);
	if (!ready)
		return;

	/* A range of whole lines, not too long; otherwise nothing is read. */
	memset(words, 0, sizeof(words));
	usable = diag_range(address, bytes);
	if (!usable) {
		command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		diag_reply(command, words);
		return;
	}

	/* The words, a buffer of lines at a time, as the driver's own accesses. */
	mode = fw_dma_mode(0);
	plain = 0;
	weighted = 0;
	place = 0;
	done = 0;
	while (done < bytes) {
		/* The buffer's lines. */
		part = bytes - done;
		if (part > DIAG_BUFFER_BYTES)
			part = DIAG_BUFFER_BYTES;
		error = fw_dma_read(address + done, diag_buffer, part / FW_LINE_BYTES);
		if (error != 0) {
			command->status = FW_VK_ERROR_DEVICE_LOST;
			break;
		}

		/* Their words into the sums; the first four and the last are kept. */
		for (index = 0; index < part / 4u; index++) {
			word = diag_buffer[index];
			plain += word;
			place++;
			weighted += place * word;
			if (place <= 4u)
				words[GHCI_DIAG_SUM_FIRST + place - 1u] = word;
			words[GHCI_DIAG_SUM_LAST] = word;
		}
		done += part;
	}

	/* The protection mode of the packet again. */
	(void)fw_dma_mode(mode);

	/* The bytes read and the sums. */
	words[GHCI_DIAG_SUM_PLAIN] = plain;
	words[GHCI_DIAG_SUM_WEIGHTED] = weighted;
	command->aux = done;
	diag_reply(command, words);
}

/*
 * Reports whether a gpu-op of this file whose arguments were read can
 * run: a well-formed packet in the ring.
 */
static int
diag_ready(
	struct fw_command *command)
{
	/* The arguments were read whole. */
	if (command->reader->error)
		return 0;

	/* Not a staged command. */
	if (command->in_frame) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		command->stop = 1;
		return 0;
	}

	/* Succeeded: the gpu-op runs. */
	return 1;
}

/* Reports whether a DIAG_WRITE or DIAG_SUM range is whole lines, one line to the most: 1 when it is. */
static int
diag_range(
	uint32_t address,
	uint32_t bytes)
{
	/* The first byte starts a line. */
	if ((address & (FW_LINE_BYTES - 1u)) != 0)
		return 0;

	/* At least one line, whole lines, not past the most. */
	if (bytes == 0 || (bytes & (FW_LINE_BYTES - 1u)) != 0)
		return 0;
	if (bytes > GHCI_DIAG_BYTES_MAX)
		return 0;

	/* The range does not wrap the address space. */
	if (address + bytes < address)
		return 0;

	/* Succeeded: the range can be accessed line by line. */
	return 1;
}

/*
 * Stores the reply's words after the VkResult and the aux, when the
 * packet asked for a result (packet.c stores those two and flushes).
 */
static void
diag_reply(
	struct fw_command *command,
	const uint32_t *words)
{
	int error;

	/* A packet without a result, or a staged command, has no reply. */
	if (command->reply == 0)
		return;

	/* Words 2-15; a reply that cannot be stored is a lost device. */
	error = fw_store(command->reply + 8u, &words[2], (GHCI_REPLY_WORDS - 2u) * 4u);
	if (error != 0)
		command->status = FW_VK_ERROR_DEVICE_LOST;
}
