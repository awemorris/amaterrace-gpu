/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The link: atg_top in the KC705's shape (the CP's CPU with the committed
 * firmware image, 64-byte lines, an SU, VF, RX, TU and ROP with stencil,
 * the MEM capability) run by Verilator behind a C interface, for a host
 * program that drives it as a driver drives the board: the register
 * window (BAR0), the local memory with its window (BAR2: the first
 * WINDOW_BYTES of the local memory, which the host reads and writes
 * directly), the interrupt line and the clock.
 *
 * The host's accesses take simulated time: a register access is a
 * transaction on atg_top's register port, and the clock runs only in
 * the link's calls.  The GPU reaches the local memory (AXI ID 0) and the
 * host's memory below HOST_LIMIT (ID 1, as the KC705's PCIe bridge gives
 * it); an access outside both, or with the other ID, reads 0, is dropped
 * when it writes, and is counted.
 *
 * Built by sim/verilator/link-build.sh into a static library; the
 * program links it with a C++ linker.
 */

#ifndef ATG_LINK_H
#define ATG_LINK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What the link counted since it started. */
struct atg_link_stats {
	uint64_t cycles;		/* clock cycles */
	uint64_t fw_packet_cycles;	/* cycles the firmware spent in a packet (CPFW state 3) */
	uint64_t uop_words;		/* µop words the CPU gave the sequencer */
	uint64_t register_reads;	/* host reads of the register window */
	uint64_t register_writes;	/* host writes of the register window */
	uint64_t stray_accesses;	/* GPU beats outside the memories, or with the wrong AXI ID */
	uint64_t local_beats;		/* GPU beats to the local memory */
	uint64_t host_beats;		/* GPU beats to the host's memory */
};

/* Makes the GPU and resets it; 0, or -1 when the local memory cannot be had. */
int atg_link_start(void);

/* Ends the simulation. */
void atg_link_stop(void);

/* Reads and writes a 32-bit register of the window (offset < 0x20000). */
uint32_t atg_link_read(uint32_t offset);
void atg_link_write(uint32_t offset, uint32_t value);

/*
 * The local memory as the host sees it: its bytes, its GPU address, its
 * size and how many of its first bytes the window shows.
 */
uint8_t *atg_link_local(uint32_t *base, uint32_t *bytes, uint32_t *window);

/*
 * The host's memory the GPU reaches: its bytes from bus address 0, and
 * the end of it (HOST_LIMIT).
 */
uint8_t *atg_link_host(uint32_t *limit);

/* Whether the GPU's local window is open (MEM WINDOW_CTRL.ENABLE). */
int atg_link_window_open(void);

/* The interrupt line's level. */
int atg_link_irq(void);

/*
 * Runs the clock at most cycles cycles, stopping early when the interrupt
 * line is high (also before the first cycle) if stop_on_irq; reports the
 * cycles run.
 */
uint64_t atg_link_run(uint64_t cycles, int stop_on_irq);

/* The core clock in Hz (GCLK_HZ). */
uint32_t atg_link_clock_hz(void);

/* Copies the counts. */
void atg_link_stats(struct atg_link_stats *stats);

/*
 * Reads a word of the CP CPU's DMEM (offset in bytes from its base), for
 * looking at the firmware's state with its ELF's symbols.
 */
uint32_t atg_link_dmem(uint32_t offset);

#ifdef __cplusplus
}
#endif

#endif
