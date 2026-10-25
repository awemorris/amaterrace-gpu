/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The control window of atg_cpu (spec/gpu/cp/atg_cpu.md): word registers
 * at 0xF000_0000 + 4 x index.  Every access takes two cycles; a UOP store
 * waits while the µop FIFO is full.
 */

#ifndef FW_CP_HW_H
#define FW_CP_HW_H

#include <stdint.h>

#define HW_WINDOW 0xF0000000u

/* Window word indices. */
#define HW_PKT_ADDR 0x00u	/* R: GPU address of the class V packet's dword1 */
#define HW_PKT_DWORDS 0x01u	/* R: its n */
#define HW_PKT_INFO 0x02u	/* R: [7:0] tag, [31] waiting; the read takes it */
#define HW_DONE 0x03u	/* W: the packet is finished */
#define HW_UOP 0x04u	/* W: a µop dword */
#define HW_UOP_LAST 0x05u	/* W: the last dword of a µop packet */
#define HW_UOP_FREE 0x06u	/* R: free FIFO entries */
#define HW_STATE_IDX 0x07u	/* W: STATE index to read */
#define HW_STATE_DATA 0x08u	/* R: STATE[STATE_IDX] */
#define HW_FENCE_LAST 0x09u	/* R */
#define HW_CYCLE 0x0Au	/* R: cycle counter */
#define HW_RESULT 0x0Bu	/* W: raise IRQ_STATUS.RESULT */
#define HW_IRQ 0x0Cu	/* R: [0] packet, [1] fence, [2] halt request */
#define HW_IRQ_EN 0x0Du	/* RW: interrupt enables */
#define HW_DMA_AMB 0x10u	/* RW: GPU address (line aligned) */
#define HW_DMA_MEM 0x11u	/* RW: DMEM byte offset (line aligned) */
#define HW_DMA_GO 0x12u	/* W: [15:0] lines, [16] DMEM to memory */
#define HW_DMA_STATUS 0x13u	/* R: [0] busy, [1] error, [15:8] writes unanswered */
#define HW_FW_STATUS 0x20u	/* W: [15:8] state, [16] PARK; R: CPFW_STATUS */
#define HW_MBOX0 0x21u	/* RW: CPFW_MBOX0..3 at 0x21-0x24 */
#define HW_FW_VERSION 0x25u	/* RW: CPFW_VERSION */
#define HW_PROT_SLOT 0x28u	/* W: [7:0] tag, [13:8] slot (0: unmapped) */
#define HW_PROT_INV_G 0x29u	/* W: the first granule of an invalidation */
#define HW_PROT_GIDX 0x2Au	/* W: the CAM entry GCTL writes */
#define HW_PROT_GBASE 0x2Bu	/* W: its first granule */
#define HW_PROT_GLIMIT 0x2Cu	/* W: its end granule (exclusive) */
#define HW_PROT_GCTL 0x2Du	/* W: [0] valid, [1] read, [2] write, [13:8] slot; writes the entry */
#define HW_PROT_INFO 0x2Eu	/* R: [0] PROT, [1] a table, [2] drained, [3] invalidation pending, [13:8] slots, [31:16] grants */
#define HW_PROT_TBASE 0x2Fu	/* R: PROT_TABLE */
#define HW_PROT_G0 0x30u	/* R: the table's first granule */
#define HW_PROT_G1 0x31u	/* R: its end granule */
#define HW_UOP_SELF 0x32u	/* W: [0] the next µop packet is the firmware's own wait */
#define HW_PROT_INV_N 0x33u	/* W: granules of the invalidation (0: all); starts it */

#define HW_PKT_INFO_WAITING 0x80000000u
#define HW_IRQ_HALT 0x4u
#define HW_DMA_GO_WRITE 0x10000u
#define HW_DMA_GO_CHK 0x20000u	/* the copy is checked for the packet's protected session */
#define HW_DMA_GO_TBL 0x40000u	/* the copy writes the protection table */
#define HW_PROT_INFO_HAS 0x1u
#define HW_PROT_INFO_TABLE 0x2u
#define HW_PROT_INFO_DRAINED 0x4u
#define HW_PROT_INFO_PENDING 0x8u
#define HW_PROT_GCTL_VALID 0x1u
#define HW_PROT_GCTL_READ 0x2u
#define HW_PROT_GCTL_WRITE 0x4u
#define HW_DMA_BUSY 0x1u
#define HW_DMA_ERROR 0x2u
#define HW_DMA_WRITES 0xFF00u
#define HW_FW_PARK 0x10000u

/* The DMEM's place in the core's address space. */
#define HW_DMEM_BASE 0x00010000u

#ifdef FW_HOST

/*
 * A host build (the firmware's tests in fw/cp/tests/): the window and the
 * line DMA are the test's functions, and the DMA takes DMEM by pointer
 * (`go`: DMA_GO's bits above the lines, the direction and the protection).
 */
uint32_t hw_read(uint32_t index);
void hw_write(uint32_t index, uint32_t value);
int hw_host_dma(uint32_t address, void *dmem, uint32_t lines, uint32_t go);

#else

/*
 * Reads one window register.
 */
static inline uint32_t
hw_read(
	uint32_t index)
{
	volatile uint32_t *word;

	/* The window decodes the word index from the address. */
	word = (volatile uint32_t *)(HW_WINDOW + index * 4u);

	/* Succeeded: the register's value. */
	return *word;
}

/*
 * Writes one window register.
 */
static inline void
hw_write(
	uint32_t index,
	uint32_t value)
{
	volatile uint32_t *word;

	/* The window decodes the word index from the address. */
	word = (volatile uint32_t *)(HW_WINDOW + index * 4u);
	*word = value;
}

#endif

#endif
