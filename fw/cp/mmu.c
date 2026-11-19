/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * mmu.c: autonomous multi-level page table and TLB management in CP firmware.
 *
 * Supports both legacy 32-bit 2-level (4B entries) and 64-bit 2/3/4-level
 * (8B entries, 512 per 4 KiB page) formats matching rtl/gpu/mmu/atg_mmu_walker.v.
 * Dynamically inspects BOOT_CAPS (VA_BITS / PA_BITS) at init time, handles
 * VM_MAP and VM_UNMAP commands, in-flight memory draining, race-free TLB
 * invalidations, and session reclamation.
 * See spec/gpu/mmu/atg_mmu.md and docs/noc_and_mmu_architecture.md §3.1.
 */

#include "fw.h"
#include "hw.h"
#include "ghci_frame.h"
#include "ghci_regs.h"

/* Root Page Directory base addresses per session (4 KiB aligned GPU address) */
static uint32_t session_root_pt[FW_SESSIONS];
static int walker_present;
static uint32_t mmu_va_bits = 32u;
static uint32_t mmu_pa_bits = 40u;
static uint32_t mmu_levels = 3u;
static int mmu_64bit = 1;

int
fw_mmu_walker_present(void)
{
	return walker_present;
}

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

static uint64_t
mmu_read_entry(
	uint32_t address)
{
	uint32_t line;
	uint32_t offset;
	uint64_t val64;
	uint32_t val32;

	(void)fw_store_flush();
	line = address & ~(FW_LINE_BYTES - 1u);
	offset = address & (FW_LINE_BYTES - 1u);

	if (fw_dma_read(line, mmu_read_line, 1) != 0)
		return 0;

	if (mmu_64bit) {
		memcpy(&val64, &mmu_read_line[offset], 8);
		return val64;
	}
	memcpy(&val32, &mmu_read_line[offset], 4);
	return (uint64_t)val32;
}

static void
mmu_write_entry(
	uint32_t address,
	uint64_t val)
{
	uint32_t val32;

	if (mmu_64bit) {
		(void)fw_store(address, &val, 8);
	} else {
		val32 = (uint32_t)val;
		(void)fw_store(address, &val32, 4);
	}
	(void)fw_store_flush();
}

static uint32_t
mmu_level_index(
	uint64_t va,
	uint32_t lvl)
{
	uint32_t shift;
	uint32_t rem;

	if (!mmu_64bit) {
		shift = (lvl == 0u) ? 22u : 12u;
		return (uint32_t)(va >> shift) & 0x3FFu;
	}
	/* 64-bit: level 0 is root (top), level (mmu_levels-1) is leaf ([20:12]) */
	rem = (mmu_levels - 1u) - lvl;
	shift = 12u + rem * 9u;
	return (uint32_t)(va >> shift) & 0x1FFu;
}

void
fw_mmu_init(void)
{
	uint32_t i;
	uint32_t boot, caps, vpn_bits;

	memset(mmu_zero_line, 0, sizeof(mmu_zero_line));
	for (i = 0; i < FW_SESSIONS; i++)
		session_root_pt[i] = 0;

	boot = hw_read(HW_BOOT_CAPS);
#ifdef FW_HOST
	caps = hw_read(HW_DEVICE_CAPS);
	walker_present = (boot != 0) ? ((boot & 2u) != 0) : ((caps & GHCI_CAP_HW_WALKER) != 0);
#elif defined(CONFIG_CP_AUTONOMOUS_MMU)
	walker_present = (CONFIG_CP_AUTONOMOUS_MMU != 0);
#else
	caps = hw_read(HW_DEVICE_CAPS);
	walker_present = (boot != 0) ? ((boot & 2u) != 0) : ((caps & GHCI_CAP_HW_WALKER) != 0);
#endif

	if (boot != 0) {
		mmu_va_bits = 30u + ((boot >> 8) & 0xFu);
		mmu_pa_bits = 40u + ((boot >> 12) & 0xFu);
	} else {
		mmu_va_bits = 32u;
		mmu_pa_bits = 40u;
	}

	mmu_64bit = (mmu_pa_bits > 32u) ? 1 : 0;
	if (!mmu_64bit) {
		mmu_levels = 2u;
	} else {
		vpn_bits = (mmu_va_bits > 12u) ? (mmu_va_bits - 12u) : 18u;
		if (vpn_bits <= 18u)
			mmu_levels = 2u;
		else if (vpn_bits <= 27u)
			mmu_levels = 3u;
		else
			mmu_levels = 4u;
	}
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
	uint32_t lvl, idx, entry_sz;
	uint32_t cur_tbl, next_tbl;
	uint64_t entry;

	if (session_id >= FW_SESSIONS)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	/* 4 KiB alignment check */
	if ((gpu_va & 0xFFFu) != 0 || (phys_addr & 0xFFFu) != 0 ||
	    (size_bytes & 0xFFFu) != 0 || size_bytes == 0)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	entry_sz = mmu_64bit ? 8u : 4u;

	root = session_root_pt[session_id];
	if (root == 0) {
		/* Allocate root Page Directory (4 KiB) from firmware heap */
		root = fw_heap_alloc_aligned(session_id, 4096, 4096);
		if (root == 0)
			return FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;

		mmu_clear_page(root);
		session_root_pt[session_id] = root;

		/* Update Hardware MMU root pointer */
		hw_write(HW_MMU_SESSION, session_id);
		hw_write(HW_MMU_ROOT_PT_HI, 0u);
		hw_write(HW_MMU_ROOT_PT, root >> 12);
	}

	cur_va = gpu_va;
	cur_pa = phys_addr;
	end_va = gpu_va + size_bytes;

	while (cur_va < end_va) {
		cur_tbl = root;
		for (lvl = 0; lvl < mmu_levels - 1u; lvl++) {
			idx = mmu_level_index(cur_va, lvl);
			entry = mmu_read_entry(cur_tbl + idx * entry_sz);
			if ((entry & 1ull) == 0ull) {
				next_tbl = fw_heap_alloc_aligned(session_id, 4096, 4096);
				if (next_tbl == 0)
					return FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
				mmu_clear_page(next_tbl);
				entry = (uint64_t)(next_tbl & ~0xFFFu) | 1ull;
				mmu_write_entry(cur_tbl + idx * entry_sz, entry);
			} else {
				next_tbl = (uint32_t)(entry & ~0xFFFull);
			}
			cur_tbl = next_tbl;
		}

		/* Leaf PTE: [PA_BITS-1:12]=PFN, [11:6]=Session, [5:0]=Flags */
		idx = mmu_level_index(cur_va, mmu_levels - 1u);
		entry = (cur_pa & ~0xFFFull) | 1ull;	/* Valid */
		if (flags & GHCI_VM_FLAG_READ)     entry |= (1ull << 1);
		if (flags & GHCI_VM_FLAG_WRITE)    entry |= (1ull << 2);
		if (flags & GHCI_VM_FLAG_EXEC)     entry |= (1ull << 3);
		if (flags & GHCI_VM_FLAG_COHERENT) entry |= (1ull << 4);
		if (flags & GHCI_VM_FLAG_WC)       entry |= (1ull << 5);
		entry |= ((uint64_t)(session_id & 0x3Fu) << 6);

		mmu_write_entry(cur_tbl + idx * entry_sz, entry);

		cur_va += 4096ull;
		cur_pa += 4096ull;
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
	uint32_t lvl, idx, entry_sz, cur_tbl;
	uint64_t entry;

	(void)flags;

	if (session_id >= FW_SESSIONS)
		return FW_VK_ERROR_INITIALIZATION_FAILED;

	root = session_root_pt[session_id];
	if (root == 0)
		return FW_VK_SUCCESS;

	entry_sz = mmu_64bit ? 8u : 4u;
	cur_va = gpu_va;
	end_va = gpu_va + size_bytes;

	while (cur_va < end_va) {
		cur_tbl = root;
		for (lvl = 0; lvl < mmu_levels - 1u; lvl++) {
			idx = mmu_level_index(cur_va, lvl);
			entry = mmu_read_entry(cur_tbl + idx * entry_sz);
			if ((entry & 1ull) == 0ull) {
				cur_tbl = 0;
				break;
			}
			cur_tbl = (uint32_t)(entry & ~0xFFFull);
		}
		if (cur_tbl != 0) {
			idx = mmu_level_index(cur_va, mmu_levels - 1u);
			mmu_write_entry(cur_tbl + idx * entry_sz, 0ull);
		}

		cur_va += 4096ull;
	}

	/* Wait for all in-flight execution unit memory requests to drain */
	while (hw_read(HW_MMU_INFLIGHT) > 0) {
		/* Spin until memory pipeline is quiescent */
	}

	/* Trigger hardware TLB flush for this session */
	hw_write(HW_MMU_FLUSH, ((session_id & 0xFu) << 4) | 1u);

	return FW_VK_SUCCESS;
}

static void
mmu_free_tree(
	uint32_t session_id,
	uint32_t table_addr,
	uint32_t lvl)
{
	uint32_t n_ent, entry_sz, idx;
	uint64_t entry;
	uint32_t child;

	n_ent = mmu_64bit ? 512u : 1024u;
	entry_sz = mmu_64bit ? 8u : 4u;

	if (lvl + 1u < mmu_levels) {
		for (idx = 0; idx < n_ent; idx++) {
			entry = mmu_read_entry(table_addr + idx * entry_sz);
			if (entry & 1ull) {
				child = (uint32_t)(entry & ~0xFFFull);
				mmu_free_tree(session_id, child, lvl + 1u);
			}
		}
	}

	fw_heap_free(session_id, table_addr, 4096);
}

void
fw_mmu_session_close(
	uint32_t session_id)
{
	uint32_t root;

	if (session_id >= FW_SESSIONS)
		return;

	root = session_root_pt[session_id];
	if (root == 0)
		return;

	mmu_free_tree(session_id, root, 0u);
	session_root_pt[session_id] = 0;

	/* Clear Hardware MMU root pointer & flush TLB */
	hw_write(HW_MMU_SESSION, session_id);
	hw_write(HW_MMU_ROOT_PT_HI, 0u);
	hw_write(HW_MMU_ROOT_PT, 0u);
	hw_write(HW_MMU_FLUSH, ((session_id & 0xFu) << 4) | 1u);
}
