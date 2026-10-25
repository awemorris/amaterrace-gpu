/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * fwhost.h: the host test bench of the CP firmware.  The firmware's C is
 * built for the host with FW_HOST: the control window and the line DMA
 * are fwhost.c's, over a GPU memory array; the µops the firmware gives
 * the FIFO are kept, applied to a STATE array, and the blits run on the
 * memory, so a test checks the µops, the STATE and the memory.  A test
 * writes a frame of staged commands (as a driver does), runs it, and
 * reads the result records.  A trace writes the cases as a scene for the
 * Verilator firmware harness.
 */

#ifndef FW_CP_TESTS_FWHOST_H
#define FW_CP_TESTS_FWHOST_H

#include <stdint.h>

/* The test GPU memory: 32 MiB from address 0. */
#define HOST_MEM_BYTES (32u << 20)

/* Where the bench keeps the ring packets, the staging, the results and the heap. */
#define HOST_PACKET 0x00010000u
#define HOST_STAGING 0x00020000u
#define HOST_RESULTS 0x00100000u
#define HOST_FRAME_RESULT 0x00101000u
#define HOST_HEAP 0x00400000u
#define HOST_HEAP_BYTES (8u << 20)

/* The µops the firmware gave, at most this many words in a run. */
#define HOST_UOP_WORDS (1u << 20)

/* The STATE words the bench keeps (with CAPS[30]: to 0x2FF). */
#define HOST_STATE_WORDS 0x300u

extern uint8_t host_mem[HOST_MEM_BYTES];
extern uint32_t host_uops[HOST_UOP_WORDS];
extern uint32_t host_uop_count;
extern uint32_t host_state[HOST_STATE_WORDS];
extern uint32_t host_results;
extern uint32_t host_result_uops;	/* the µop words given before the last RESULT */
extern uint32_t host_dones;
extern int host_failures;

/* The grant entries the protection model has. */
#define HOST_PROT_CAM 64u

/*
 * Session protection (host_prot_enable): the invalidations, the SELF µop
 * packets, the checked DMAs, the refused DMA lines and the last one's
 * address.
 */
extern uint32_t host_prot_invs;
extern uint32_t host_prot_selfs;
extern uint32_t host_prot_checked;
extern uint32_t host_prot_refused;
extern uint32_t host_prot_fault;

void host_reset(void);
uint32_t host_peek(uint32_t address);
void host_poke(uint32_t address, uint32_t value);

void host_frame_begin(void);
void host_u32(uint32_t value);
void host_u64(uint64_t value);
void host_record(uint32_t number, uint32_t index);
void host_cmd(uint32_t number);
uint32_t host_frame_run(uint32_t tag, uint32_t records);
void host_ring(uint32_t tag, uint32_t number, const uint32_t *args, uint32_t count);
int32_t host_result(uint32_t index);
uint32_t host_result_aux(uint32_t index);
int32_t host_ring_result(void);

int host_trace_open(const char *path);
void host_trace_case(const char *name);
int host_trace_close(void);

void host_prot_enable(uint32_t slots, uint32_t grants);
void host_prot_table(uint32_t tbase, uint32_t g0, uint32_t g1);
uint32_t host_prot_table_bytes(void);
uint32_t host_prot_byte(uint32_t address);
uint32_t host_prot_slot(uint32_t tag);
uint32_t host_prot_cam(uint32_t slot, uint32_t address, uint32_t bytes);
int host_prot_allowed(uint32_t slot, uint32_t address, int write);

void host_check(int condition, const char *what);
uint32_t host_uop_find(uint32_t op, uint32_t from);
uint32_t host_uops_of(uint32_t op);

#endif
