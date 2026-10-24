/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * fwhost.c: the host side of the firmware's test bench (fwhost.h): the
 * control window, the line DMA and a model of the sequencer for the µops
 * the tests look at (SET_REG into STATE, BLIT of linear FILL, COPY and
 * the KEEP mask on the memory, the others only kept), and the writing of
 * frames as the driver stages them.
 */

#include "fwhost.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../fw.h"
#include "../hw.h"
#include "ghci_frame.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

uint8_t host_mem[HOST_MEM_BYTES];
uint32_t host_uops[HOST_UOP_WORDS];
uint32_t host_uop_count;
uint32_t host_state[HOST_STATE_WORDS];
uint32_t host_results;
uint32_t host_dones;
int host_failures;

/* The packet the window shows (PKT_ADDR, PKT_DWORDS). */
static uint32_t host_pkt_addr;
static uint32_t host_pkt_dwords;

/* The µop packet being collected from the FIFO: where it starts in host_uops. */
static uint32_t host_uop_start;

/* The staging's write pointer, in words. */
static uint32_t host_sp;

static void host_run_uop(const uint32_t *packet, uint32_t count);
static void host_blit(void);

/* Empties the memory, the µops and the STATE. */
void
host_reset(void)
{
	memset(host_mem, 0, sizeof(host_mem));
	memset(host_state, 0, sizeof(host_state));
	host_uop_count = 0;
	host_uop_start = 0;
	host_results = 0;
	host_dones = 0;
}

/* Reads a word of the memory. */
uint32_t
host_peek(
	uint32_t address)
{
	uint32_t value;

	memcpy(&value, &host_mem[address], 4);
	return value;
}

/* Writes a word of the memory. */
void
host_poke(
	uint32_t address,
	uint32_t value)
{
	memcpy(&host_mem[address], &value, 4);
}

/* The window: the registers the firmware reads. */
uint32_t
hw_read(
	uint32_t index)
{
	switch (index) {
	case HW_PKT_ADDR:
		return host_pkt_addr;
	case HW_PKT_DWORDS:
		return host_pkt_dwords;
	case HW_UOP_FREE:
		return 64;
	case HW_DMA_STATUS:
		return 0;
	default:
		return 0;
	}
}

/* The window: the registers the firmware writes. */
void
hw_write(
	uint32_t index,
	uint32_t value)
{
	switch (index) {
	case HW_UOP:
	case HW_UOP_LAST:
		if (host_uop_count == HOST_UOP_WORDS) {
			host_check(0, "the µop log is full");
			return;
		}
		host_uops[host_uop_count++] = value;
		if (index == HW_UOP_LAST) {
			host_run_uop(&host_uops[host_uop_start], host_uop_count - host_uop_start);
			host_uop_start = host_uop_count;
		}
		return;
	case HW_RESULT:
		host_results++;
		return;
	case HW_DONE:
		host_dones++;
		return;
	default:
		return;
	}
}

/* The line DMA on the memory. */
int
hw_host_dma(
	uint32_t address,
	void *dmem,
	uint32_t lines,
	int write)
{
	uint32_t bytes;

	bytes = lines * FW_LINE_BYTES;
	if ((address & (FW_LINE_BYTES - 1u)) != 0 || ((uintptr_t)dmem & (FW_LINE_BYTES - 1u)) != 0) {
		host_check(0, "a DMA of an unaligned line");
		return -1;
	}
	if (address >= HOST_MEM_BYTES || bytes > HOST_MEM_BYTES - address) {
		host_check(0, "a DMA outside the memory");
		return -1;
	}
	if (write) {
		memcpy(&host_mem[address], dmem, bytes);
	} else {
		memcpy(dmem, &host_mem[address], bytes);
	}
	return 0;
}

/* Starts a frame in the staging. */
void
host_frame_begin(void)
{
	host_sp = 0;
	memset(&host_mem[HOST_RESULTS], 0xFF, 0x1000);
}

/* A staged word. */
void
host_u32(
	uint32_t value)
{
	host_poke(HOST_STAGING + host_sp * 4u, value);
	host_sp++;
}

/* A staged u64, low word first. */
void
host_u64(
	uint64_t value)
{
	host_u32((uint32_t)value);
	host_u32((uint32_t)(value >> 32));
}

/* A staged command's envelope with a result record. */
void
host_record(
	uint32_t number,
	uint32_t index)
{
	host_u32(number);
	host_u32(GHCI_V_REPLY);
	host_u32(index);
}

/* A staged recorded command's envelope (no result). */
void
host_cmd(
	uint32_t number)
{
	host_u32(number);
	host_u32(0);
	host_u32(GHCI_FRAME_NO_RESULT);
}

/* Runs the staged frame as one GHCI_FRAME packet; gives the frame's status. */
uint32_t
host_frame_run(
	uint32_t tag,
	uint32_t records)
{
	uint32_t packet[8];
	uint32_t index;

	packet[0] = GHCI_GPU_OP_FRAME;
	packet[1] = GHCI_V_RESULT;
	packet[2] = HOST_FRAME_RESULT;
	packet[3] = HOST_STAGING;
	packet[4] = 0;
	packet[5] = host_sp * 4u;
	packet[6] = HOST_RESULTS;
	packet[7] = records;
	for (index = 0; index < 8u; index++)
		host_poke(HOST_PACKET + index * 4u, packet[index]);
	host_pkt_addr = HOST_PACKET;
	host_pkt_dwords = 8;
	fw_packet_run(tag);
	return host_peek(HOST_FRAME_RESULT);
}

/* Runs one ring packet of a gpu-op with its arguments; its result goes to HOST_FRAME_RESULT + 16. */
void
host_ring(
	uint32_t tag,
	uint32_t number,
	const uint32_t *args,
	uint32_t count)
{
	uint32_t index;

	host_poke(HOST_PACKET, number);
	host_poke(HOST_PACKET + 4u, GHCI_V_RESULT);
	host_poke(HOST_PACKET + 8u, HOST_FRAME_RESULT + 16u);
	for (index = 0; index < count; index++)
		host_poke(HOST_PACKET + 12u + index * 4u, args[index]);
	host_pkt_addr = HOST_PACKET;
	host_pkt_dwords = 3u + count;
	fw_packet_run(tag);
}

/* A staged command's result status. */
int32_t
host_result(
	uint32_t index)
{
	return (int32_t)host_peek(HOST_RESULTS + index * 8u);
}

/* A staged command's result aux word. */
uint32_t
host_result_aux(
	uint32_t index)
{
	return host_peek(HOST_RESULTS + index * 8u + 4u);
}

/* The last ring packet's status. */
int32_t
host_ring_result(void)
{
	return (int32_t)host_peek(HOST_FRAME_RESULT + 16u);
}

/* Counts a failed check. */
void
host_check(
	int condition,
	const char *what)
{
	if (condition)
		return;
	host_failures++;
	printf("  FAIL %s\n", what);
}

/* The index of the next µop packet header of an op (class 0) from a word, or the count. */
uint32_t
host_uop_find(
	uint32_t op,
	uint32_t from)
{
	uint32_t index;
	uint32_t word;

	index = 0;
	while (index < host_uop_count) {
		word = host_uops[index];
		if (index >= from && GHCI_PKT_GET_CLASS(word) == GHCI_PKT_CLASS_STD && ((word >> 24) & 0x3Fu) == op)
			return index;
		index += 1u + (word & 0xFFu);
	}
	return host_uop_count;
}

/* The number of µop packets of an op. */
uint32_t
host_uops_of(
	uint32_t op)
{
	uint32_t index;
	uint32_t count;

	count = 0;
	index = host_uop_find(op, 0);
	while (index < host_uop_count) {
		count++;
		index = host_uop_find(op, index + 1u);
	}
	return count;
}

/* The sequencer's model of one µop packet. */
static void
host_run_uop(
	const uint32_t *packet,
	uint32_t count)
{
	uint32_t op;
	uint32_t index;

	if (GHCI_PKT_GET_CLASS(packet[0]) != GHCI_PKT_CLASS_STD) {
		host_check(0, "a µop packet of another class in the FIFO");
		return;
	}
	if ((packet[0] & 0xFFu) + 1u != count) {
		host_check(0, "a µop packet's length");
		return;
	}
	op = (packet[0] >> 24) & 0x3Fu;
	if (op == GHCI_OP_SET_REG) {
		for (index = 1; index + 1u < count; index += 2u) {
			if (packet[index] >= HOST_STATE_WORDS) {
				host_check(0, "SET_REG past the STATE");
				continue;
			}
			host_state[packet[index]] = packet[index + 1u];
		}
		return;
	}
	if (op == GHCI_OP_BLIT)
		host_blit();
}

/* The blitter's model: linear FILL and COPY of 1-16 byte pixels, KEEP. */
static void
host_blit(void)
{
	uint32_t op;
	uint32_t ps;
	uint32_t width;
	uint32_t height;
	uint32_t x;
	uint32_t y;
	uint32_t byte;
	uint32_t keep;
	uint32_t dst;
	uint32_t src;
	uint8_t pixel[16];
	uint8_t *to;

	op = host_state[GHCI_S_BLT_OP];
	ps = 4;
	switch ((op >> 8) & 3u) {
	case 1:
		ps = 2;
		break;
	case 2:
		ps = 8;
		break;
	case 3:
		ps = 1;
		break;
	default:
		if ((op >> 13) & 1u)
			ps = 16;
		break;
	}
	keep = (op >> 16) & 0xFu;
	width = host_state[GHCI_S_BLT_SIZE] & 0xFFFFu;
	height = host_state[GHCI_S_BLT_SIZE] >> 16;
	memcpy(pixel, &host_state[GHCI_S_BLT_COLOR], 4);
	memcpy(pixel + 4, &host_state[0x00C], 12);
	if ((op & 7u) > 1u)
		return;
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			dst = host_state[GHCI_S_BLT_DST_BASE] +
			    (y + (host_state[GHCI_S_BLT_DST_XY] >> 16)) * host_state[GHCI_S_BLT_DST_STRIDE] +
			    (x + (host_state[GHCI_S_BLT_DST_XY] & 0xFFFFu)) * ps;
			src = host_state[GHCI_S_BLT_SRC_BASE] +
			    (y + (host_state[GHCI_S_BLT_SRC_XY] >> 16)) * host_state[GHCI_S_BLT_SRC_STRIDE] +
			    (x + (host_state[GHCI_S_BLT_SRC_XY] & 0xFFFFu)) * ps;
			if (dst + ps > HOST_MEM_BYTES || src + ps > HOST_MEM_BYTES) {
				host_check(0, "a blit outside the memory");
				return;
			}
			to = &host_mem[dst];
			for (byte = 0; byte < ps; byte++) {
				if (ps == 4u && ((keep >> byte) & 1u) != 0)
					continue;
				if ((op & 7u) == GHCI_BLT_FILL) {
					to[byte] = pixel[byte];
				} else {
					to[byte] = host_mem[src + byte];
				}
			}
		}
	}
}
