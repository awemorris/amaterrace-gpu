# atg_mmu: Autonomous GPU Memory Management Unit

RTL: `rtl/gpu/mmu/atg_mmu.v`, `rtl/gpu/mmu/atg_tlb_l1.v`, `rtl/gpu/mmu/atg_tlb_l2.v`, `rtl/gpu/mmu/atg_mmu_walker.v`.
Parent: `rtl/gpu/top/atg_top.v` (or interposed in front of `atg_mc.v`).
Specification: docs/ghci.md §11.2; plan/ws001/phase004/phase.md.

## 1. Architectural Purpose & Motivation

`atg_mmu` implements an autonomous virtual-to-physical address translation engine for Amaterrace GPU architectures under Unified Memory Architecture (UMA) and commercial operating system environments.

### Core Architectural Decisions:
1. **Ultra-Thin Host Abstraction:** The host OS kernel and UMD never see or manipulate raw page tables or issue low-level TLB invalidation commands. Host drivers submit high-level `VM_MAP` (0x10110) and `VM_UNMAP` (0x10111) packets over the command ring.
2. **CP Autonomous 2-Level Page Table Management:** The on-chip RV32IM Command Processor (CP) dynamically allocates, populates, and unmaps 4 KiB 2-level page tables from its internal firmware heap.
3. **Autonomous Hardware Page Table Walker:** On an L2 TLB miss, a dedicated hardware state machine walks the 2-level page directory and page table in memory, reloading TLBs without CPU/host interrupts.
4. **Internal Fault Trapping:** Illegal address translations (unmapped page or permission violation) are trapped internally inside the GPU. The access is strictly suppressed from reaching the external system bus/interconnect, preventing host IOMMU panics, and is logged in `FAULT_INFO` / `FAULT_ADDR` with session and GPU VA attribution.

## 2. Multi-Level TLB Hierarchy

```
+--------------------------------------------------------------------------+
|                        GPU Execution Units (Clients)                     |
|    VF (Vertex)       SU (Shader)      TU (Texture)   ROP (Pixel)   BLT   |
+--------+------------------+----------------+--------------+---------+----+
         |                  |                |              |         |
     +---+----+         +---+----+       +---+----+     +---+----+ +--+---+
     | L1 TLB |         | L1 TLB |       | L1 TLB |     | L1 TLB | |L1 TLB|  (1-cycle hit)
     +---+----+         +---+----+       +---+----+     +---+----+ +--+---+
         |                  |                |              |         |
         +------------------+-------+--------+--------------+---------+
                                    |
                           +--------v--------+
                           |  Shared L2 TLB  |  (256-512 entries, multi-way)
                           +--------+--------+
                                    | (Miss)
                           +--------v--------+
                           | Hardware Walker |  (2-level Sv32-like PT walk)
                           +--------+--------+
                                    | (DMA / Read)
                           +--------v--------+
                           | Memory Control  |  (atg_mc.v / UMA DRAM)
                           +-----------------+
```

- **L1 TLB (`atg_tlb_l1.v`):**
  - Fully-associative 16-entry CAM per client channel.
  - 1-cycle hit translation for high throughput.
  - Tag: `{session_id[3:0], vpn[31:12]}`.
  - Data: `{pfn[31:12], flags[5:0]}` (R, W, X, C, WC, V).
- **L2 TLB (`atg_tlb_l2.v`):**
  - 256-entry 4-way set-associative cache.
  - Hit latency: 2 clock cycles.
  - Serves L1 refill requests upon L1 miss.
- **Hardware Page Table Walker (`atg_mmu_walker.v`):**
  - Reads Level 1 Page Directory Entry (PDE) from memory:
    $\text{PDE\_ADDR} = \text{ROOT\_PT}[\text{session\_id}] + (\text{vpn}[31:22] \times 4)$.
  - Checks PDE validity (`bit 0`). If invalid $\to$ Page Fault.
  - Reads Level 2 Page Table Entry (PTE) from memory:
    $\text{PTE\_ADDR} = (\text{PDE}[31:12] \ll 12) + (\text{vpn}[21:12] \times 4)$.
  - Validates PTE (`bit 0`) and access permissions (Read/Write/Exec).
  - Automatically installs translation into L2 and L1 TLBs upon successful walk.

## 3. CP Firmware & Internal MMIO Interface

The CP interacts with the MMU via a private control interface:
- **`MMU_REG_ROOT_PT(session_id)`:** Sets the 4 KiB-aligned base address of the session's Page Directory.
- **`MMU_REG_TLB_FLUSH`:**
  - `[3:0] session_id`
  - `[4] flush_all_sessions`
  - `[5] flush_by_range`
  - `[31:12] flush_vpn`
- **`MMU_REG_INFLIGHT` (Read-Only):**
  - Current number of memory transactions in flight across all execution units.
  - Allows CP to ensure full memory quiescence before unmapping and invalidating TLBs during `VM_UNMAP`.
- **`MMU_REG_FAULT_STATUS` / `MMU_REG_FAULT_ADDR`:**
  - Captures faulting GPU VA, session ID, client ID, and fault kind (`FAULT_GPU_PAGE_FAULT = 9`, `FAULT_GPU_PERM_VIOLATION = 10`).

## 4. Hardware Constraints & RTL Standards

- **Verilog-2005 compliant.**
- **Signal arithmetic operators:** All address calculation adders ($+4$, offset calculation) use `am_add` / `am_sub` from `rtl/library/arith/`. Strictly 0 operators outside library.
- **Clock domains:** Single synchronous clock (`clk`), no logic clock dividers (`plan/fpga.md`).
