/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * mmu.c: autonomous 2-level page table and TLB management in CP firmware.
 *
 * Implements standard 4 KiB 2-level page tables allocated dynamically from
 * the firmware heap. Handles VM_MAP and VM_UNMAP commands, in-flight
 * memory draining, race-free TLB invalidations, and session reclamation.
 * See spec/gpu/mmu/atg_mmu.md.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_frame.h"

/* Root Page Directory base addresses per session (4 KiB aligned GPU address) */
static uint32_t session_root_pt[FW_SESSIONS];

/* Aligned buffers for line-aligned DMA transfers */
static uint8_t mmu_zero_line[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));
static uint8_t mmu_read_line[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));

static void
mmu_clear_page(
	uint32_t base_addr)
{
	uint32_t offset;

	(void)fw_store_flush();
	for (offset = 0; offset < 4096u; offset += FW_LINE_BYTES)
		(void)fw_dma_write(base_addr + offset, mmu_zero_line, 1);
}

static uint32_t
mmu_read_u32(
	uint32_t address)
{
	uint32_t line;
	uint32_t offset;
	uint32_t val;

	(void)fw_store_flush();
	line = address & ~(FW_LINE_BYTES - 1u);
	offset = address & (FW_LINE_BYTES - 1u);

	if (fw_dma_read(line, mmu_read_line, 1) != 0)
		return 0;

	memcpy(&val, &mmu_read_line[offset], 4);
	return val;
}

static void
mmu_write_u32(
	uint32_t address,
	uint32_t val)
{
	(void)fw_store(address, &val, 4);
	(void)fw_store_flush();
}

void
fw_mmu_init(void)
{
	uint32_t i;

	memset(mmu_zero_line, 0, sizeof(mmu_zero_line));
	for (i = 0; i < FW_SESSIONS; i++)
		session_root_pt[i] = 0;
}

int
fw_mmu_map(
	uint32_t session_id,
	uint32_t flags,
	uint64_t gpu_va,
	uint64_t phys_addr,
	uint64_t size_bytes)
{
	uint32_t root;
	uint64_t cur_va, cur_pa, end_va;
	uint32_t pdi, pti;
	uint32_t pde, pte, l2_pt;

	if (session_id >= FW_SESSIONS)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	/* 4 KiB alignment check */
	if ((gpu_va & 0xFFFu) != 0 || (phys_addr & 0xFFFu) != 0 ||
	    (size_bytes & 0xFFFu) != 0 || size_bytes == 0)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	root = session_root_pt[session_id];
	if (root == 0) {
		/* Allocate root Page Directory (4 KiB) from firmware heap */
		root = fw_heap_alloc_aligned(session_id, 4096, 4096);
		if (root == 0)
			return FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;

		/* Clear 1024 PDE entries */
		mmu_clear_page(root);
		session_root_pt[session_id] = root;

		/* Update Hardware MMU root pointer */
		hw_write(HW_MMU_SESSION, session_id);
		hw_write(HW_MMU_ROOT_PT, root >> 12);
	}

	cur_va = gpu_va;
	cur_pa = phys_addr;
	end_va = gpu_va + size_bytes;

	while (cur_va < end_va) {
		pdi = ((uint32_t)cur_va >> 22) & 0x3FFu;
		pti = ((uint32_t)cur_va >> 12) & 0x3FFu;

		/* Read Page Directory Entry */
		pde = mmu_read_u32(root + pdi * 4u);

		if ((pde & 1u) == 0) {
			/* Allocate Level 2 Page Table (4 KiB) */
			l2_pt = fw_heap_alloc_aligned(session_id, 4096, 4096);
			if (l2_pt == 0)
				return FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;

			/* Clear L2 Page Table */
			mmu_clear_page(l2_pt);

			pde = (l2_pt & ~0xFFFu) | 1u;
			mmu_write_u32(root + pdi * 4u, pde);
		} else {
			l2_pt = pde & ~0xFFFu;
		}

		/* Build Page Table Entry: [31:12]=PFN, [11:6]=Session, [5:0]=Flags */
		pte = ((uint32_t)cur_pa & ~0xFFFu) | 1u;	/* Valid */
		if (flags & GHCI_VM_FLAG_READ)     pte |= (1u << 1);
		if (flags & GHCI_VM_FLAG_WRITE)    pte |= (1u << 2);
		if (flags & GHCI_VM_FLAG_EXEC)     pte |= (1u << 3);
		if (flags & GHCI_VM_FLAG_COHERENT) pte |= (1u << 4);
		if (flags & GHCI_VM_FLAG_WC)       pte |= (1u << 5);
		pte |= ((session_id & 0x3Fu) << 6);

		mmu_write_u32(l2_pt + pti * 4u, pte);

		cur_va += 4096;
		cur_pa += 4096;
	}

	return FW_VK_SUCCESS;
}

int
fw_mmu_unmap(
	uint32_t session_id,
	uint32_t flags,
	uint64_t gpu_va,
	uint64_t size_bytes)
{
	uint32_t root;
	uint64_t cur_va, end_va;
	uint32_t pdi, pti;
	uint32_t pde, l2_pt;

	(void)flags;

	if (session_id >= FW_SESSIONS)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	root = session_root_pt[session_id];
	if (root == 0)
		return FW_VK_SUCCESS;

	cur_va = gpu_va;
	end_va = gpu_va + size_bytes;

	/* Invalidate Level 2 PTE entries */
	while (cur_va < end_va) {
		pdi = ((uint32_t)cur_va >> 22) & 0x3FFu;
		pti = ((uint32_t)cur_va >> 12) & 0x3FFu;

		pde = mmu_read_u32(root + pdi * 4u);
		if (pde & 1u) {
			l2_pt = pde & ~0xFFFu;
			mmu_write_u32(l2_pt + pti * 4u, 0);
		}

		cur_va += 4096;
	}

	/* Wait for all in-flight execution unit memory requests to drain */
	while (hw_read(HW_MMU_INFLIGHT) > 0) {
		/* Spin until memory pipeline is quiescent */
	}

	/* Trigger hardware TLB flush for this session */
	hw_write(HW_MMU_FLUSH, (session_id << 4) | 1u);

	return FW_VK_SUCCESS;
}

void
fw_mmu_session_close(
	uint32_t session_id)
{
	uint32_t root, pdi, pde, l2_pt;

	if (session_id >= FW_SESSIONS)
		return;

	root = session_root_pt[session_id];
	if (root == 0)
		return;

	/* Free all allocated Level 2 Page Tables */
	for (pdi = 0; pdi < 1024; pdi++) {
		pde = mmu_read_u32(root + pdi * 4u);
		if (pde & 1u) {
			l2_pt = pde & ~0xFFFu;
			fw_heap_free(session_id, l2_pt, 4096);
		}
	}

	/* Free root Page Directory */
	fw_heap_free(session_id, root, 4096);
	session_root_pt[session_id] = 0;

	/* Clear Hardware MMU root pointer & flush TLB */
	hw_write(HW_MMU_SESSION, session_id);
	hw_write(HW_MMU_ROOT_PT, 0);
	hw_write(HW_MMU_FLUSH, (session_id << 4) | 1u);
}
