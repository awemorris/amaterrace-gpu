/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_regs.h: the GHCI 1.0 host control registers (docs/ghci.md, draft).
 * An OS driver copies this file; it has no dependency but the C integer
 * constants.  include/ghci_regs.vh holds the same values for the RTL.
 */

#ifndef GHCI_REGS_H
#define GHCI_REGS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GHCI_MAGIC_VALUE         0x47484349u /* "GHCI" */
#define GHCI_VERSION_MAJOR       1u
#define GHCI_VERSION_MINOR       0u
#define GHCI_VERSION_VALUE       ((GHCI_VERSION_MAJOR << 16) | GHCI_VERSION_MINOR)

/* FourCCs as read from the ID registers (the first letter in bits 31:24). */
#define GHCI_FOURCC(a, b, c, d) \
	(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

/*
 * ============================================================================
 * GHCI 1.0 Canonical Host MMIO Registers (Page 0: 0x000 - 0x0FC)
 * ============================================================================
 */

/* Identification & Capabilities */
#define GHCI_REG_MAGIC           0x000u  /* RO: Magic identification ("GHCI", 0x47484349) */
#define GHCI_REG_VERSION         0x004u  /* RO: Major [31:16], Minor [15:0] -> 0x00010000 */
#define GHCI_REG_DEVICE_CAPS     0x008u  /* RO: Device capabilities bitfield (K05) */
#define GHCI_REG_EXTCAP_PTR      0x00Cu  /* RO: Extended capabilities list pointer (0x00000100) */

/* Control, Status & Faults */
#define GHCI_REG_STATUS          0x010u  /* RO: Hardware execution status (K03) */
#define GHCI_REG_CTRL            0x014u  /* RW: Core control bits (RUN, HALT, RESET, etc., K03) */
#define GHCI_REG_FAULT_INFO      0x018u  /* RO/W1C: Fault syndrome, kind, source unit, session ID (K04) */
#define GHCI_REG_FAULT_ADDR_LO   0x01Cu  /* RO: Faulting virtual/physical address [31:0] */
#define GHCI_REG_FAULT_ADDR_HI   0x020u  /* RO: Faulting virtual/physical address [63:32] */

/* Command Ring Buffer & Doorbell */
#define GHCI_REG_RING_BASE_LO    0x024u  /* RW: Command ring 64-bit base host DMA address [31:0] */
#define GHCI_REG_RING_BASE_HI    0x028u  /* RW: Command ring 64-bit base host DMA address [63:32] */
#define GHCI_REG_RING_SIZE       0x02Cu  /* RW: Command ring size in bytes (power of 2, e.g. 4 KiB..16 MiB) */
#define GHCI_REG_RING_WPTR       0x030u  /* RW: Host write pointer (Doorbell, dword index from BASE) */
#define GHCI_REG_RING_RPTR       0x034u  /* RO: GPU read pointer (dword index from BASE) */

/* Interrupt Management */
#define GHCI_REG_IRQ_STATUS      0x038u  /* RW1C: Interrupt status flags (write-1-to-clear) */
#define GHCI_REG_IRQ_ENABLE      0x03Cu  /* RW: Interrupt enable mask */
#define GHCI_REG_IRQ_SET         0x040u  /* W1S: Software interrupt trigger */

/* Diagnostics & Hardware Sizing */
#define GHCI_REG_SCRATCH0        0x044u  /* RW: 32-bit test/scratchpad register */
#define GHCI_REG_SCRATCH         GHCI_REG_SCRATCH0
#define GHCI_REG_WDT_CYCLES      0x048u  /* RW: Watchdog timeout limit in core clock cycles */
#define GHCI_REG_RESIDENT_WARPS  0x04Cu  /* RO: [15:0] Active warps, [23:16] registers per lane */
#define GHCI_REG_CP_HEAP_BASE    0x050u  /* RW: Autonomous MMU heap base PA [31:0] */
#define GHCI_REG_CP_HEAP_LIMIT   0x054u  /* RW: Autonomous MMU heap limit PA (exclusive) */
#define GHCI_REG_SESSION_ACTIVE  0x058u  /* RO: Active session identifier bitmap */
#define GHCI_REG_TIMESTAMP_LO    0x05Cu  /* RO: 64-bit GPU cycle timestamp [31:0] */
#define GHCI_REG_TIMESTAMP_HI    0x060u  /* RO: 64-bit GPU cycle timestamp [63:32] */
#define GHCI_REG_GCLK_HZ         0x064u  /* RO: Core clock frequency in Hz (timestampPeriod = 1e9 / GCLK_HZ, K06) */

/* Command Processor Diagnostics */
#define GHCI_REG_DIAG_CP_PC      0x074u  /* RO: Current RV32IM Program Counter of CP firmware */
#define GHCI_REG_DIAG_CP_STATUS  0x078u  /* RO: CP internal FSM state & in-flight draw counter */

/* Fast Extended Capability Mirrors */
#define GHCI_REG_EXT_CAP_FMT0    0x080u  /* RO: Fast texture compression format bitmap shortcut */
#define GHCI_REG_EXT_CAP_FEATURE 0x084u  /* RO: Fast rendering feature detail bitmap shortcut */

#define GHCI_CANONICAL_MMIO_BYTES 0x100u /* 256 bytes active MMIO in Page 0 */

/*
 * ============================================================================
 * Register Bitfield Definitions
 * ============================================================================
 */

/* DEVICE_CAPS bits (0x008, K05) */
#define GHCI_CAP_UMA             (1u << 0)  /* 1 = Unified Memory (Shared DRAM), 0 = Discrete */
#define GHCI_CAP_IOMMU           (1u << 1)  /* 1 = Platform / System IOMMU active */
#define GHCI_CAP_HW_WALKER       (1u << 2)  /* 1 = Autonomous HW Page Table Walker present */
#define GHCI_CAP_INDIRECT_DRAW   (1u << 3)  /* 1 = MultiDrawIndirect supported */
#define GHCI_CAP_SECONDARY_RING  (1u << 4)  /* 1 = CMD_EXECUTE_COMMANDS supported */
#define GHCI_CAP_DUAL_SOURCE     (1u << 5)  /* 1 = Dual-source color blending supported */
#define GHCI_CAP_FP16            (1u << 6)  /* 1 = Packed FP16 arithmetic supported */
#define GHCI_CAP_GSI1            (1u << 7)  /* 1 = GSI1 standard shader ISA native */
#define GHCI_CAP_PHYS_LANES(caps)(((caps) >> 8) & 0xFFu)  /* Physical execution lanes (default 8) */
#define GHCI_CAP_NUM_SU(caps)    (((caps) >> 16) & 0xFFu) /* Number of Shader Units (1..4) */
#define GHCI_CAP_PROT            (1u << 24) /* 1 = Session protection hardware present */
#define GHCI_CAP_TEX_FFILT       (1u << 25) /* 1 = Hardware floating-point texture filter present */
#define GHCI_CAP_ROP_PACK        (1u << 26) /* 1 = ROP Path 2 integer/float RT packer present */
#define GHCI_CAP_TASK_SHADER     (1u << 27) /* 1 = VK_EXT Task Shader supported (K05) */
#define GHCI_CAP_MESH_SHADER     (1u << 28) /* 1 = VK_EXT Mesh Shader supported (K05) */
#define GHCI_CAP_BLT             (1u << 29) /* 1 = Blitter 2D engine present (K05) */
#define GHCI_CAP_DISP            (1u << 30) /* 1 = Display controller present (K05) */
#define GHCI_CAP_MSAA            (1u << 31) /* 1 = MSAA 4x multisampling supported (K05) */

/* CTRL bits (0x014, K03) */
#define GHCI_CTRL_RESET          (1u << 0)  /* Soft reset GPU (self-clearing) */
#define GHCI_CTRL_RUN            (1u << 1)  /* Enable ring processing */
#define GHCI_CTRL_HALT           (1u << 2)  /* Request CP to halt after current packet */
#define GHCI_CTRL_STEP           (1u << 3)  /* Single step */
#define GHCI_CTRL_TLB_FLUSH      (1u << 4)  /* Invalidate CP L1/L2 TLBs */
#define GHCI_CTRL_WDT_EN         (1u << 5)  /* Enable watchdog timer */
#define GHCI_CTRL_IRQ_GLOBAL     (1u << 6)  /* Master interrupt enable */

/* STATUS bits (0x010, K03) */
#define GHCI_STATUS_RUNNING      (1u << 0)  /* 1 = GPU command processor running */
#define GHCI_STATUS_HALTED       (1u << 1)  /* 1 = GPU halted */
#define GHCI_STATUS_FAULTED      (1u << 2)  /* 1 = Hardware / MMU fault active (device-wide) */
#define GHCI_STATUS_MC_IDLE      (1u << 8)  /* 1 = Memory controller idle */
#define GHCI_STATUS_RING_EMPTY   (1u << 11) /* 1 = Ring buffer empty */
#define GHCI_STATUS_MEM_READY    (1u << 12) /* 1 = DRAM / memory calibration complete */
#define GHCI_STATUS_AXI_STUCK    (1u << 13) /* 1 = AXI bus transaction timeout / stuck */
#define GHCI_STATUS_QUIESCE      (1u << 14) /* 1 = GPU memory access quiesced */
#define GHCI_STATUS_CP_STATE(s)  (((s) >> 16) & 0x0Fu) /* [19:16] CP FSM state (K03) */

#define GHCI_CP_STATE_IDLE       0u
#define GHCI_CP_STATE_FETCH      1u
#define GHCI_CP_STATE_DECODE     2u
#define GHCI_CP_STATE_EXEC       3u
#define GHCI_CP_STATE_WAIT_FENCE 4u
#define GHCI_CP_STATE_WAIT_MEM   5u
#define GHCI_CP_STATE_BLIT       6u
#define GHCI_CP_STATE_FAULT      7u

/* IRQ_STATUS & IRQ_ENABLE bits (0x038, 0x03C) */
#define GHCI_IRQ_FENCE           (1u << 0)  /* Fence completed */
#define GHCI_IRQ_FAULT           (1u << 1)  /* Hardware / memory translation fault */
#define GHCI_IRQ_WATCHDOG        (1u << 2)  /* Execution timeout / hang */
#define GHCI_IRQ_DISPLAY         (1u << 3)  /* Display scanout / VSYNC event */
#define GHCI_IRQ_SOFT            (1u << 5)  /* Software interrupt (triggered via IRQ_SET) */

/* FAULT_INFO decoding (0x018, K04, N50) */
#define GHCI_FAULT_KIND(info)      ((info) & 0x0Fu)        /* [3:0] Fault kind */
#define GHCI_FAULT_UNIT(info)      (((info) >> 4) & 0x0Fu) /* [7:4] Source unit */
#define GHCI_FAULT_SESSION(info)   (((info) >> 8) & 0xFFu) /* [15:8] Session ID (0..15) */
#define GHCI_FAULT_STAGE(info)     (((info) >> 16) & 0x0Fu) /* [19:16] Active shader stage (N50) */
#define GHCI_FAULT_SYNDROME(info)  (((info) >> 20) & 0x0FFFu) /* [31:20] 12-bit subunit syndrome (N50) */

/* Fault Kinds [3:0] (K04, N50) */
#define GHCI_FAULT_KIND_NONE            0u
#define GHCI_FAULT_KIND_INVALID_OP      1u /* Unrecognized packet opcode or illegal operation */
#define GHCI_FAULT_KIND_INVALID_ARG     1u /* Alias: invalid argument */
#define GHCI_FAULT_KIND_KICK_ABSENT     2u /* Kick directed to absent hardware unit */
#define GHCI_FAULT_KIND_RING_OOB        2u /* Alias: command ring address out-of-bounds */
#define GHCI_FAULT_KIND_BAD_REG         3u /* Malformed packet header, length mismatch, or bad register */
#define GHCI_FAULT_KIND_PAGE_READ       3u /* Alias: page read translation fault */
#define GHCI_FAULT_KIND_TIMEOUT         4u /* Watchdog execution timeout / hang */
#define GHCI_FAULT_KIND_WATCHDOG        4u /* Alias: watchdog timer expired */
#define GHCI_FAULT_KIND_FENCE_ERROR     5u /* Memory / fence response error */
#define GHCI_FAULT_KIND_AXI_ERROR       5u /* Alias: interconnect / bus DECERR/SLVERR */
#define GHCI_FAULT_KIND_PAGE_WRITE      6u /* MMU page write fault */
#define GHCI_FAULT_KIND_PROT_FAULT      6u /* Session protection violation */
#define GHCI_FAULT_KIND_TLB_ERROR       7u /* TLB translation fault */
#define GHCI_FAULT_KIND_LOCKED_REG      7u /* Write to locked register */
#define GHCI_FAULT_KIND_MMU_OOM         8u /* Dynamic page table allocation heap exhausted */
#define GHCI_FAULT_KIND_ISA_FAULT       8u /* Shader ISA execution fault */
#define GHCI_FAULT_KIND_PAGE_FAULT      9u /* Unmapped virtual page address */
#define GHCI_FAULT_KIND_PERM_FAULT      10u /* Memory access permission violation */
#define GHCI_FAULT_KIND_MEMORY_FAULT    10u /* Alias: memory protection / alignment fault */

/* Source Units [7:4] (K04) */
#define GHCI_UNIT_CP             0u
#define GHCI_UNIT_VF             1u
#define GHCI_UNIT_SU             2u
#define GHCI_UNIT_RX             3u
#define GHCI_UNIT_TU             4u
#define GHCI_UNIT_ROP            5u
#define GHCI_UNIT_BLT            6u

/* Extended Capability Registers (0x080+) & Feature Field Decoding (K07) */
#define GHCI_FEATURE_VA_BITS(f)   ((f) & 0x0Fu)        /* [3:0] Virtual Address bits (32..40) */
#define GHCI_FEATURE_PA_BITS(f)   (((f) >> 4) & 0x0Fu) /* [7:4] Physical Address bits (40..48) */

/* PCI Identification Constants (K06) */
#define GHCI_PCI_VENDOR_ID_XILINX 0x10EEu
#define GHCI_PCI_DEVICE_ID_KC705  0x7024u
#define GHCI_PCI_VENDOR_ID_ATG    0x5441u /* "AT" */
#define GHCI_PCI_DEVICE_ID_ATG    0x4748u /* "GH" */

/*
 * ============================================================================
 * Legacy GHCI 1.1 Host Control Register Map (128 KiB window)
 * ============================================================================
 */
#define GHCI_MAGIC 0x000u
#define GHCI_VERSION 0x004u
#define GHCI_VENDOR_ID 0x008u
#define GHCI_DEVICE_ID 0x00Cu
#define GHCI_ISA_ID 0x010u
#define GHCI_DEVICE_VERSION 0x014u
#define GHCI_EXTCAP 0x018u
#define GHCI_GCLK_HZ 0x01Cu
#define GHCI_CAPS 0x020u
#define GHCI_CAPS2 0x024u
#define GHCI_SCRATCH 0x028u
#define GHCI_COUNTER 0x02Cu
#define GHCI_CTRL 0x030u
#define GHCI_STATUS 0x034u
#define GHCI_IRQ_STATUS 0x038u
#define GHCI_IRQ_ENABLE 0x03Cu
#define GHCI_IRQ_SET 0x040u
#define GHCI_WDT_CYCLES 0x044u
#define GHCI_RESIDENT_WARPS 0x04Cu	/* R: [15:0] the warps the GPU runs at once (NSU x NWARPS), [23:16] registers per lane */
#define GHCI_RESIDENT_WARPS_COUNT(v) ((v) & 0xFFFFu)
#define GHCI_RESIDENT_WARPS_NREGS(v) (((v) >> 16) & 0xFFu) /* general registers per lane (32 or 64) */

/* Pre-1.0 legacy prototype offsets; abolished in GHCI 1.0 Slim MMIO (N60). Do not use in 1.0 drivers. */
#define GHCI_LEGACY_RING_BASE 0x050u
#define GHCI_LEGACY_RING_SIZE 0x054u
#define GHCI_LEGACY_RING_WPTR 0x058u
#define GHCI_LEGACY_RING_RPTR 0x05Cu
#define GHCI_LEGACY_APERTURE_BASE 0x060u
#define GHCI_LEGACY_APERTURE_LIMIT 0x064u
#define GHCI_LEGACY_FAULT_ADDR 0x068u
#define GHCI_LEGACY_FAULT_INFO 0x06Cu
#define GHCI_FENCE_LAST 0x070u
#define GHCI_CP_PC 0x074u
#define GHCI_CP_STATUS 0x078u
#define GHCI_PIPE_FSM 0x07Cu
#define GHCI_PERF(n) (0x080u + 4u * (n))
#define GHCI_PERF_CTRL 0x090u
#define GHCI_DBG_ADDR 0x0A0u
#define GHCI_DBG_DATA 0x0A4u
#define GHCI_DBG_STATUS 0x0A8u
#define GHCI_CPFW_CTRL 0x120u /* the CPFW capability (id 6) */
#define GHCI_CPFW_STATUS 0x124u
#define GHCI_CPFW_IBASE 0x128u
#define GHCI_CPFW_IWORDS 0x12Cu
#define GHCI_CPFW_DBASE 0x130u
#define GHCI_CPFW_DWORDS 0x134u
#define GHCI_CPFW_VERSION 0x138u
#define GHCI_CPFW_MBOX(n) (0x150u + 4u * (n)) /* n = 0..3, after SA's 0x140-0x14F */
#define GHCI_KICK 0xF00u
#define GHCI_STATE(i) (0x1000u + 4u * (i))
#define GHCI_STATE_COUNT 512u

/* CPFW_CTRL and CPFW_STATUS. */
#define GHCI_CPFW_CTRL_LOAD (1u << 0)
#define GHCI_CPFW_CTRL_RUN (1u << 1)
#define GHCI_CPFW_CTRL_HALT (1u << 2)
#define GHCI_CPFW_STATUS_READY (1u << 0)
#define GHCI_CPFW_STATUS_FAULT (1u << 1)
#define GHCI_CPFW_STATUS_ALIVE (1u << 2)
#define GHCI_CPFW_STATUS_STOPPED (1u << 3) /* the core is stopped or held in reset */
#define GHCI_CPFW_STATUS_LOADING (1u << 4)
#define GHCI_CPFW_STATUS_STATE(s) (((s) >> 8) & 0xFFu)

/* CAPS. */
#define GHCI_CAPS_CP (1u << 0)
#define GHCI_CAPS_BLT (1u << 1)
#define GHCI_CAPS_SHADER (1u << 2)
#define GHCI_CAPS_DISP (1u << 3)
#define GHCI_CAPS_LANES_LOG2(c) (((c) >> 4) & 0xFu)
#define GHCI_CAPS_TU_BILINEAR (1u << 8)
#define GHCI_CAPS_ROP_STENCIL (1u << 9)
#define GHCI_CAPS_WAIT_VSYNC (1u << 10)
#define GHCI_CAPS_TILE4X4 (1u << 11)
#define GHCI_CAPS_STATE_VERSION(c) (((c) >> 12) & 0xFu)
#define GHCI_CAPS_MMU (1u << 16)
#define GHCI_CAPS_FIRMWARE (1u << 17)
#define GHCI_CAPS_FW_RELOAD (1u << 18)
#define GHCI_CAPS_NATIVE_ISA (1u << 19) /* ISA_ID differs from GSI1 */
#define GHCI_CAPS_LINE_LOG2(c) (((c) >> 20) & 0xFu)
#define GHCI_CAPS_SUBGROUP (1u << 24)
#define GHCI_CAPS_SA (1u << 25)
#define GHCI_CAPS_TU_FULL (1u << 26) /* the texture unit of section 8.4: Vulkan 1.0 core */
#define GHCI_CAPS_GRAPHICS (1u << 27)
#define GHCI_CAPS_PACKED (1u << 28)
#define GHCI_CAPS_MS4 (1u << 29) /* 4x multisampling (draft, section 12.11) */
#define GHCI_CAPS_CORE1 (1u << 30) /* Vulkan 1.0 core rendering (draft, section 8.5) */
#define GHCI_CAPS_TEX_ADV GHCI_CAPS_TU_FULL
#define GHCI_CAPS_PACKED_MATH GHCI_CAPS_PACKED
#define GHCI_CAPS_MSAA GHCI_CAPS_MS4

/* DEVICE_CAPS (0x008) bits */
#define GHCI_DEVICE_CAPS 0x008u
#define GHCI_DEV_CAP_UMA (1u << 0)
#define GHCI_DEV_CAP_IOMMU (1u << 1)
#define GHCI_DEV_CAP_HW_WALKER (1u << 2)
#define GHCI_DEV_CAP_INDIRECT_DRAW (1u << 3)
#define GHCI_DEV_CAP_SECONDARY_RING (1u << 4)
#define GHCI_DEV_CAP_DUAL_SOURCE (1u << 5)
#define GHCI_DEV_CAP_FP16 (1u << 6)
#define GHCI_DEV_CAP_GSI1 (1u << 7)
#define GHCI_DEV_CAP_PHYS_LANES(c) (((c) >> 8) & 0xFFu)
#define GHCI_DEV_CAP_NUM_SU(c) (((c) >> 16) & 0xFFu)
#define GHCI_DEV_CAP_TASK_SHADER (1u << 30)
#define GHCI_DEV_CAP_MESH_SHADER (1u << 31)

/* EXT_CAP_* registers (0x080+) */
#define GHCI_EXT_CAP_FMT0 0x080u
#define GHCI_EXT_CAP_FEATURE 0x084u

#define GHCI_EXT_FMT_BC1 (1u << 0)
#define GHCI_EXT_FMT_BC2 (1u << 1)
#define GHCI_EXT_FMT_BC3 (1u << 2)
#define GHCI_EXT_FMT_BC4 (1u << 3)
#define GHCI_EXT_FMT_BC5 (1u << 4)
#define GHCI_EXT_FMT_BC6H (1u << 5)
#define GHCI_EXT_FMT_BC7 (1u << 6)

#define GHCI_EXT_FEAT_LOGIC_OP (1u << 0)
#define GHCI_EXT_FEAT_EARLY_Z (1u << 1)
#define GHCI_EXT_FEAT_HW_CURSOR (1u << 2)
#define GHCI_EXT_FEAT_COLOR_LUT (1u << 3)
#define GHCI_EXT_FEAT_MAX_MRT(c) (((c) >> 4) & 0xFu)
#define GHCI_EXT_FEAT_DUAL_SOURCE (1u << 8)
#define GHCI_EXT_FEAT_COARSE_SCAN (1u << 9)
#define GHCI_EXT_FEAT_FAST_CLEAR (1u << 10)

/* CAPS2. */
#define GHCI_CAPS2_QUEUES(c) ((c) & 0xFFu)
#define GHCI_CAPS2_LDS_KIB(c) (((c) >> 8) & 0xFFu)
#define GHCI_CAPS2_CONST_WORDS(c) ((((c) >> 16) & 0xFFu) * 16u)
#define GHCI_CAPS2_TEX_SLOTS(c) ((((c) >> 24) & 0xFu) * 4u)
#define GHCI_CAPS2_ATTRS(c) ((((c) >> 28) & 0xFu) * 4u)



/* DBG_STATUS. */
#define GHCI_DBG_BUSY (1u << 0)
#define GHCI_DBG_ERROR (1u << 1)

/* KICK. */
#define GHCI_KICK_BLIT (1u << 0)
#define GHCI_KICK_DRAW (1u << 1)
#define GHCI_KICK_DISPATCH (1u << 2)

/* Extended capabilities: entry word 0 and the IDs. */
#define GHCI_XCAP_ID(w) ((w) & 0xFFu)
#define GHCI_XCAP_VERSION(w) (((w) >> 8) & 0xFFu)
#define GHCI_XCAP_NEXT(w) (((w) >> 16) & 0xFFFFu)
#define GHCI_XCAP_DISP 1u
#define GHCI_XCAP_DBG 2u
#define GHCI_XCAP_PERF 3u
#define GHCI_XCAP_VEND 4u
#define GHCI_XCAP_MMU 5u
#define GHCI_XCAP_CPFW 6u
#define GHCI_XCAP_SA 7u
#define GHCI_XCAP_MEM 8u
#define GHCI_XCAP_PROT 9u
#define GHCI_XCAP_FMT 10u
#define GHCI_XCAP_DISP2 11u /* draft */

/* The FMT capability's registers (from its register offset, section 4; draft). */
#define GHCI_FMT_INDEX 0x00u /* RW: a VkFormat value */
#define GHCI_FMT_OPTIMAL 0x04u /* R: VkFormatFeatureFlags, optimal tiling */
#define GHCI_FMT_LINEAR 0x08u /* R: the same, linear tiling */
#define GHCI_FMT_BUFFER 0x0Cu /* R: the buffer features */
#define GHCI_FMT_LIMITS 0x10u /* R: [3:0] colour attachments */

/* The MEM capability's registers (from its register offset, section 11.3). */
#define GHCI_MEM_LOCAL_BASE 0x0u
#define GHCI_MEM_LOCAL_SIZE 0x4u /* 0 = no local memory (unified) */
#define GHCI_MEM_WINDOW_SIZE 0x8u /* 0 = no local window */
#define GHCI_MEM_HOST_LIMIT 0xCu /* host addresses below it, outside local memory; 0 = all */
#define GHCI_MEM_WINDOW_CTRL 0x10u /* RW: [0] ENABLE, the local window is open (reset 1) */
#define GHCI_MEM_WINDOW_ENABLE (1u << 0)
#define GHCI_MEM_CACHE_CFG 0x14u /* R: Cache hierarchy status (MMIO 0x1F4) */
#define GHCI_MEM_CACHE_L2_SIZE_KB(cfg) ((cfg) & 0xFFFFu)
#define GHCI_MEM_CACHE_L2_WAYS(cfg) (((cfg) >> 16) & 0xFFu)
#define GHCI_MEM_CACHE_TEX_L1_KB(cfg) (((cfg) >> 24) & 0x0Fu)
#define GHCI_MEM_CACHE_VF_LINES(cfg) (((cfg) >> 28) & 0x0Fu)

/* The PROT capability's registers (from its register offset, section 11.6). */
#define GHCI_PROT_CAPS 0x0u
#define GHCI_PROT_SESSIONS(c) ((c) & 0xFFu)
#define GHCI_PROT_GRANULE_LOG2(c) (((c) >> 8) & 0xFFu)
#define GHCI_PROT_GRANTS(c) (((c) >> 16) & 0xFFFFu)
#define GHCI_PROT_TABLE 0x4u /* RW: the table's GPU address, 4 KiB aligned; 0 = none */
#define GHCI_PROT_TABLE_BYTES 0x8u /* R: the table's bytes for the current aperture */

/*
 * The PERF capability's registers (from its register offset): PERF_SRCn
 * says what PERFn counts: a STATUS busy bit number (0 CP .. 6 SU), the
 * memory (cycles with accesses outstanding) or nothing.
 */
#define GHCI_PERF_SRC(n) (4u * (n))
#define GHCI_PERF_SRC_MEM 8u
#define GHCI_PERF_SRC_NONE 0xFFu

/*
 * State register file.  Only the BLT range is defined in this draft; the
 * other ranges follow the command set (docs/ghci.md section 8).
 */
#define GHCI_S_BLT 0x000u
#define GHCI_S_VENDOR 0x1E0u

/* BLT. */
#define GHCI_S_BLT_OP (GHCI_S_BLT + 0u)
#define GHCI_S_BLT_DST_BASE (GHCI_S_BLT + 1u)
#define GHCI_S_BLT_DST_STRIDE (GHCI_S_BLT + 2u)
#define GHCI_S_BLT_SRC_BASE (GHCI_S_BLT + 3u)
#define GHCI_S_BLT_SRC_STRIDE (GHCI_S_BLT + 4u)
#define GHCI_S_BLT_DST_XY (GHCI_S_BLT + 5u)
#define GHCI_S_BLT_SRC_XY (GHCI_S_BLT + 6u)
#define GHCI_S_BLT_SIZE (GHCI_S_BLT + 7u)
#define GHCI_S_BLT_COLOR (GHCI_S_BLT + 8u)
#define GHCI_S_BLT_CLIP_MIN (GHCI_S_BLT + 9u)
#define GHCI_S_BLT_CLIP_MAX (GHCI_S_BLT + 10u)
#define GHCI_S_BLT_RESOLVE (GHCI_S_BLT + 11u) /* RESOLVE (draft, CAPS[29]) */
#define GHCI_S_BLT_COLOR1 (GHCI_S_BLT + 12u) /* CAPS[30]: bits 63:32 of a wide FILL */
#define GHCI_S_BLT_COLOR2 (GHCI_S_BLT + 13u)
#define GHCI_S_BLT_COLOR3 (GHCI_S_BLT + 14u)

/*
 * The other ranges.  docs/ghci.md section 8.3 defines the program range;
 * the VF, RX, ROP and TU ranges and the vendor words are Amaterrace's
 * layout until the draft defines them (design section 2.3).
 */
#define GHCI_S_VF 0x020u
#define GHCI_S_RX 0x050u
#define GHCI_S_ROP 0x070u
#define GHCI_S_TU 0x090u /* 16 slots of 16 words */
#define GHCI_S_PROG 0x190u
#define GHCI_S_SA 0x1B0u /* reserved */

/* Extended ROP for MRT 8 attachments (0x1B0-0x1BF, CAPS[30]). */
#define GHCI_S_RT_EXT 0x1B0u
#define GHCI_S_RT4_BASE (GHCI_S_RT_EXT + 0u)
#define GHCI_S_RT4_STRIDE (GHCI_S_RT_EXT + 1u)
#define GHCI_S_RT5_BASE (GHCI_S_RT_EXT + 2u)
#define GHCI_S_RT5_STRIDE (GHCI_S_RT_EXT + 3u)
#define GHCI_S_RT6_BASE (GHCI_S_RT_EXT + 4u)
#define GHCI_S_RT6_STRIDE (GHCI_S_RT_EXT + 5u)
#define GHCI_S_RT7_BASE (GHCI_S_RT_EXT + 6u)
#define GHCI_S_RT7_STRIDE (GHCI_S_RT_EXT + 7u)
#define GHCI_S_BLEND4 (GHCI_S_RT_EXT + 8u)
#define GHCI_S_BLEND5 (GHCI_S_RT_EXT + 9u)
#define GHCI_S_BLEND6 (GHCI_S_RT_EXT + 10u)
#define GHCI_S_BLEND7 (GHCI_S_RT_EXT + 11u)
#define GHCI_S_RT_FORMATS1 (GHCI_S_RT_EXT + 12u)
#define GHCI_S_WRITE_MASK1 (GHCI_S_RT_EXT + 13u)
#define GHCI_S_ATTR_DST 0x1C0u /* VF: ATTR_DST[0..15] */
#define GHCI_S_ATTR_LIMIT 0x1D0u /* VF: ATTR_LIMIT[0..15], draft, CAPS[30] */

/* VF. */
#define GHCI_S_TOPOLOGY (GHCI_S_VF + 0u)
#define GHCI_S_INDEX_BASE (GHCI_S_VF + 1u)
#define GHCI_S_INDEX_FORMAT (GHCI_S_VF + 2u)
#define GHCI_S_FIRST (GHCI_S_VF + 3u)
#define GHCI_S_COUNT (GHCI_S_VF + 4u)
#define GHCI_S_PRIM_RESTART (GHCI_S_VF + 5u)
#define GHCI_S_INSTANCE_COUNT (GHCI_S_VF + 6u)
#define GHCI_S_FIRST_INSTANCE (GHCI_S_VF + 7u)
#define GHCI_S_VERTEX_OFFSET (GHCI_S_VF + 8u)
#define GHCI_S_ATTR (GHCI_S_VF + 16u) /* ATTR[k]_BASE at +2k, ATTR[k]_DESC at +2k+1 */

/* RX. */
#define GHCI_S_VIEWPORT (GHCI_S_RX + 0u) /* 6 words: x/y scale, x/y offset, z scale, z offset */
#define GHCI_S_SCISSOR_MIN (GHCI_S_RX + 6u)
#define GHCI_S_SCISSOR_MAX (GHCI_S_RX + 7u)
#define GHCI_S_CULL (GHCI_S_RX + 8u)
#define GHCI_S_DEPTH_CLAMP (GHCI_S_RX + 9u)
#define GHCI_S_RAST_MODE (GHCI_S_RX + 10u)
#define GHCI_S_VARYING_COUNT (GHCI_S_RX + 11u)
#define GHCI_S_DEBUG_COLOR (GHCI_S_RX + 12u)
#define GHCI_S_PROVOKING (GHCI_S_RX + 13u)
#define GHCI_S_MS_CTRL (GHCI_S_RX + 14u) /* draft, CAPS[29] */
#define GHCI_S_SAMPLE_KILL (GHCI_S_RX + 15u) /* draft, CAPS[29] */
#define GHCI_S_DEPTH_BIAS_CONST (GHCI_S_RX + 16u) /* draft, CAPS[30] */
#define GHCI_S_DEPTH_BIAS_SLOPE (GHCI_S_RX + 17u) /* draft, CAPS[30] */
#define GHCI_S_DEPTH_BIAS_CLAMP (GHCI_S_RX + 18u) /* draft, CAPS[30] */
#define GHCI_S_LINE_WIDTH (GHCI_S_RX + 19u)
#define GHCI_S_POINT_SIZE (GHCI_S_RX + 20u)
#define GHCI_S_VIEWPORT_IDX (GHCI_S_RX + 21u)

/* ROP. */
#define GHCI_S_RT_BASE (GHCI_S_ROP + 0u)
#define GHCI_S_RT_STRIDE (GHCI_S_ROP + 1u)
#define GHCI_S_RT_FORMAT (GHCI_S_ROP + 2u)
#define GHCI_S_RT_SIZE (GHCI_S_ROP + 3u)
#define GHCI_S_DS_BASE (GHCI_S_ROP + 4u)
#define GHCI_S_DS_STRIDE (GHCI_S_ROP + 5u)
#define GHCI_S_DEPTH (GHCI_S_ROP + 6u)
#define GHCI_S_STENCIL_FRONT (GHCI_S_ROP + 7u)
#define GHCI_S_STENCIL_OPS (GHCI_S_ROP + 8u)
#define GHCI_S_STENCIL_BACK (GHCI_S_ROP + 9u)
#define GHCI_S_BLEND (GHCI_S_ROP + 10u)
#define GHCI_S_BLEND_CONST (GHCI_S_ROP + 11u)
#define GHCI_S_WRITE_MASK (GHCI_S_ROP + 12u)
#define GHCI_S_RT_FORMATS (GHCI_S_ROP + 13u) /* draft, CAPS[30]: the VkFormats of attachments 0-3 */
#define GHCI_S_RT1_BASE (GHCI_S_ROP + 14u) /* RTk_BASE at +2(k - 1), RTk_STRIDE at +1 */
#define GHCI_S_BLEND1 (GHCI_S_ROP + 20u) /* BLEND1-BLEND3 */
#define GHCI_S_BLEND_CONST_R (GHCI_S_ROP + 23u) /* BLEND_CONST_R, _G, _B, _A (fp32) */
#define GHCI_S_DEPTH_BOUNDS_MIN (GHCI_S_ROP + 27u)
#define GHCI_S_DEPTH_BOUNDS_MAX (GHCI_S_ROP + 28u)
#define GHCI_S_ROP_CTRL (GHCI_S_ROP + 29u) /* [0] occlusion count, [1] fp32 blend constants, [2] logic_op_en, [6:3] logic_op */
#define GHCI_S_LOGIC_OP (GHCI_S_ROP + 30u) /* [0] logic_op_en, [4:1] logic_op (VkLogicOp 0..15) */

/* TU (docs/ghci.md section 8.4): slot s's words, TEX_IMAGE, TEX_SAMPLER
 * and TEX_LOD. */
#define GHCI_S_TEX(s, w) (GHCI_S_TU + 16u * (s) + (w))
#define GHCI_S_TU_VS 0x200u /* CAPS[30]: the vertex stage's 16 slots */
#define GHCI_S_TEX_VS(s, w) (GHCI_S_TU_VS + 16u * (s) + (w))
#define GHCI_TEX_BASE 0u /* level 0 of layer 0, a multiple of 64 */
#define GHCI_TEX_SIZE 1u /* [15:0] width, [31:16] height */
#define GHCI_TEX_IMAGE 2u
#define GHCI_TEX_LAYER_STRIDE 3u /* bytes between layers, a multiple of 64 */
#define GHCI_TEX_SAMPLER 4u
#define GHCI_TEX_LOD 5u
#define GHCI_TEX_FORMAT 6u /* CAPS[30], docs/ghci.md section 8.5 */
#define GHCI_TEX_ROW 7u /* [1:0]: rows of w_l rounded up to 2^n texels (0: packed) */
#define GHCI_TROW_ALIGN(n) ((unsigned)(n) & 3u) /* 1: an attachment's even rows */
#define GHCI_TFMT_VKFORMAT(f) ((unsigned)(f) & 0xFFu) /* 0: TEX_IMAGE's format */
#define GHCI_TFMT_STENCIL (1u << 8) /* the stencil aspect of D24_UNORM_S8_UINT */
#define GHCI_TFMT_SWIZZLE(r, g, b, a) /* VkComponentSwizzle */ \
	((((unsigned)(r) & 7u) << 9) | (((unsigned)(g) & 7u) << 12) | \
	 (((unsigned)(b) & 7u) << 15) | (((unsigned)(a) & 7u) << 18))
#define GHCI_IMG_LEVELS(n) ((unsigned)(n) & 0xFu)
#define GHCI_IMG_FMT(f) (((unsigned)(f) & 0xFu) << 4)
#define GHCI_IMG_FMT_RGBA8 0u
#define GHCI_IMG_FMT_BGRA8 1u
#define GHCI_IMG_FMT_D24 2u
#define GHCI_IMG_FMT_D32F 3u
#define GHCI_IMG_TILED (1u << 8)
#define GHCI_IMG_TYPE(t) (((unsigned)(t) & 7u) << 9)
#define GHCI_IMG_TYPE_2D 0u
#define GHCI_IMG_TYPE_2D_ARRAY 1u
#define GHCI_IMG_TYPE_3D 2u
#define GHCI_IMG_TYPE_CUBE 3u
#define GHCI_IMG_SAMPLES(l) (((unsigned)(l) & 0xFu) << 12) /* log2(samples); reserved, 0 */
#define GHCI_IMG_COUNT(n) (((unsigned)(n) & 0xFFFFu) << 16) /* depth or layer count */
#define GHCI_SAMP_WRAP_U(m) ((unsigned)(m) & 3u) /* 0 repeat, 1 mirrored, 2 edge, 3 border */
#define GHCI_SAMP_WRAP_V(m) (((unsigned)(m) & 3u) << 2)
#define GHCI_SAMP_WRAP_W(m) (((unsigned)(m) & 3u) << 4)
#define GHCI_SAMP_MAG_LINEAR (1u << 6)
#define GHCI_SAMP_MIN_LINEAR (1u << 7)
#define GHCI_SAMP_MIP_LINEAR (1u << 8)
#define GHCI_SAMP_COMPARE (1u << 9)
#define GHCI_SAMP_COMPARE_OP(op) (((unsigned)(op) & 7u) << 10) /* VkCompareOp */
#define GHCI_SAMP_BORDER(b) (((unsigned)(b) & 7u) << 13) /* VkBorderColor */
#define GHCI_SAMP_UNNORM (1u << 16) /* unnormalizedCoordinates */
#define GHCI_SAMP_LOD_BIAS(x) (((unsigned)(x) & 0x1FFFu) << 19) /* mipLodBias x 256, signed */
#define GHCI_TEX_LOD_VAL(minl, maxl) /* minLod, maxLod x 256, <= 0xFFF */ \
	(((unsigned)(minl) & 0xFFFu) | ((0xFFFu - ((unsigned)(maxl) & 0xFFFu)) << 12))

/* The program range. */
#define GHCI_S_VS_BASE (GHCI_S_PROG + 0u)
#define GHCI_S_VS_WORDS (GHCI_S_PROG + 1u)
#define GHCI_S_FS_BASE (GHCI_S_PROG + 2u)
#define GHCI_S_FS_WORDS (GHCI_S_PROG + 3u)
#define GHCI_S_CS_BASE (GHCI_S_PROG + 4u)
#define GHCI_S_CS_WORDS (GHCI_S_PROG + 5u)
#define GHCI_S_CONST_BASE (GHCI_S_PROG + 6u)
#define GHCI_S_CONST_WORDS (GHCI_S_PROG + 7u)
#define GHCI_S_LDS_BYTES (GHCI_S_PROG + 8u)
#define GHCI_S_WG_SIZE (GHCI_S_PROG + 9u)
#define GHCI_S_VS_OUT_WORDS (GHCI_S_PROG + 10u)

/* Amaterrace's vendor words, written by the uop sequencer. */
#define GHCI_S_RAW (GHCI_S_VENDOR + 0u) /* DRAW_RAW's 9 words */
#define GHCI_S_GRID_X (GHCI_S_VENDOR + 9u) /* DISPATCH's grid */
#define GHCI_S_GRID_Y (GHCI_S_VENDOR + 10u)
#define GHCI_S_GRID_Z (GHCI_S_VENDOR + 11u)
#define GHCI_S_LC_REGION (GHCI_S_VENDOR + 12u) /* LOAD_CONST */
#define GHCI_S_LC_ADDR (GHCI_S_VENDOR + 13u)
#define GHCI_S_LC_WORDS (GHCI_S_VENDOR + 14u)
#define GHCI_S_DBG_MARK (GHCI_S_VENDOR + 31u)

/* BLT_OP. */
#define GHCI_BLT_FILL 0u
#define GHCI_BLT_COPY 1u
#define GHCI_BLT_TILE 2u
#define GHCI_BLT_UNTILE 3u
#define GHCI_BLT_RESOLVE 4u /* draft, CAPS[29] */
#define GHCI_BLT_RSV_SAMPLES4 2u /* BLT_RESOLVE[3:0]: log2 of 4 */
#define GHCI_BLT_RSV_UNORM8 (0u << 4) /* BLT_RESOLVE[7:4]: the average */
#define GHCI_BLT_RSV_UNORM565 (1u << 4)
#define GHCI_BLT_RSV_SAMPLE0 (2u << 4)
#define GHCI_BLT_RSV_SRGB8_A8 (3u << 4)
#define GHCI_BLT_RSV_SFLOAT16 (4u << 4)
#define GHCI_BLT_RSV_SFLOAT32 (5u << 4)
#define GHCI_BLT_RSV_UNORM2_10_10_10 (6u << 4) /* CAPS[30] */
#define GHCI_BLT_RSV_UNORM1555 (7u << 4) /* CAPS[30] */
#define GHCI_BLT_RSV_TILED (1u << 8)
#define GHCI_BLT_BLEND_OVER (1u << 4)
#define GHCI_BLT_BPP16 (1u << 8)
#define GHCI_BLT_BPP64 (2u << 8) /* CAPS[30] */
#define GHCI_BLT_BPP8 (3u << 8) /* CAPS[30] */
#define GHCI_BLT_BPP128 (1u << 13) /* CAPS[30], with [9:8] = 0 */
#define GHCI_BLT_KEEP(m) (((unsigned)(m) & 0xFu) << 16) /* CAPS[30]: bytes of a 32-bit pixel kept */
#define GHCI_BLT_REVERSE (1u << 12)
#define GHCI_XY(x, y) (((unsigned)(y) << 16) | ((unsigned)(x) & 0xFFFFu))

/* The display controller's registers (DISP capability, docs/ghci.md
 * section 13): offsets from the capability's register offset. */
#define GHCI_DC_ID_VALUE 0x41544443u /* "ATDC" */
#define GHCI_DC_ID 0x00u
#define GHCI_DC_VERSION 0x04u
#define GHCI_DC_CAPS 0x08u
#define GHCI_DC_CTRL 0x10u
#define GHCI_DC_STATUS 0x14u
#define GHCI_DC_IRQ_STATUS 0x18u
#define GHCI_DC_IRQ_ENABLE 0x1Cu
#define GHCI_DC_FB_BASE 0x20u
#define GHCI_DC_FB_NEXT 0x24u
#define GHCI_DC_FB_STRIDE 0x28u
#define GHCI_DC_FB_SIZE 0x2Cu
#define GHCI_DC_H_ACTIVE 0x30u
#define GHCI_DC_H_FP 0x34u
#define GHCI_DC_H_SYNC 0x38u
#define GHCI_DC_H_BP 0x3Cu
#define GHCI_DC_V_ACTIVE 0x40u
#define GHCI_DC_V_FP 0x44u
#define GHCI_DC_V_SYNC 0x48u
#define GHCI_DC_V_BP 0x4Cu
#define GHCI_DC_SYNC_POL 0x50u
#define GHCI_DC_FRAME_COUNT 0x54u
#define GHCI_DC_PCLK_SEL 0x58u
#define GHCI_DC_I2C_CTRL 0x60u
#define GHCI_DC_I2C_DATA 0x64u
#define GHCI_DC_I2C_STATUS 0x68u
#define GHCI_DC_SCAN_SUM 0x70u /* Amaterrace: sum of the last frame's pixel words */
#define GHCI_DC_SCAN_WORDS 0x74u /* Amaterrace: pixel words of the last frame */
#define GHCI_DC_CTRL_ENABLE (1u << 0)
#define GHCI_DC_CTRL_RESET (1u << 1)
#define GHCI_DC_CTRL_TEST_PATTERN (1u << 2)
#define GHCI_DC_CTRL_FORMAT(f) (((unsigned)(f) & 3u) << 4)
#define GHCI_DC_CTRL_OUTPUT_HDMI (1u << 6)
#define GHCI_DC_FMT_BGRA8 0u
#define GHCI_DC_FMT_RGBA8 1u
#define GHCI_DC_FMT_RGB565 2u
#define GHCI_DC_IRQ_VSYNC (1u << 0)
#define GHCI_DC_IRQ_FLIP_DONE (1u << 1)
#define GHCI_DC_IRQ_CURSOR_FLIP (1u << 2)
#define GHCI_DC_IRQ_HOTPLUG (1u << 3)
#define GHCI_DC_IRQ_UNDERFLOW (1u << 4)
#define GHCI_DC_IRQ_DISP_ERROR (1u << 5)

/* DISP2 (docs/ghci.md section 13.2, draft): the same offsets up to 0x68
 * (IRQ_STATUS/IRQ_ENABLE are DISP's only), and these. */
#define GHCI_DC2_WINDOW 0x100u /* bytes */
#define GHCI_DC_CONNECTED 0x6Cu
#define GHCI_DC_MODE_INDEX 0x80u
#define GHCI_DC_MODE_H0 0x84u /* [15:0] active, [31:16] sync */
#define GHCI_DC_MODE_H1 0x88u /* [15:0] front porch, [31:16] back porch */
#define GHCI_DC_MODE_V0 0x8Cu
#define GHCI_DC_MODE_V1 0x90u
#define GHCI_DC_MODE_CLOCK 0x94u /* kHz */
#define GHCI_DC_MODE_FLAGS 0x98u /* [0] hsync, [1] vsync high, [7:4] PCLK_SEL */
#define GHCI_DC_CURSOR_BASE 0xA0u
#define GHCI_DC_CURSOR_POS 0xA4u /* [15:0] x, [31:16] y, signed */
#define GHCI_DC_CURSOR_CTRL 0xA8u /* [0] shown */
#define GHCI_DC_TAKEN0 0xB0u
#define GHCI_DC_TAKEN1 0xB4u
#define GHCI_DC_CAPS_CURSOR (1u << 8)
#define GHCI_DC_CAPS_MODES(c) (((c) >> 9) & 7u)
#define GHCI_DC_CAPS_SENSE (1u << 12)
#define GHCI_DC_ST_RUNNING (1u << 0)
#define GHCI_DC_ST_UNDERFLOW (1u << 1)
#define GHCI_DC_ST_IDLE (1u << 2)
#define GHCI_DC_ST_READ_ERROR (1u << 3)
#define GHCI_DC_ST_RECORD_ERROR (1u << 4)
#define GHCI_DC_ST_BAD_WRITE (1u << 5)
#define GHCI_DC_ST_LINE(s) (((s) >> 16) & 0xFFFu)
#define GHCI_DC_ST_CONNECTED (1u << 28)
#define GHCI_DC_ST_PENDING0 (1u << 29)
#define GHCI_DC_ST_PENDING1 (1u << 30)
#define GHCI_DC_ST_RECORD (1u << 31)
#define GHCI_DC_MODE_PCLK_SEL(f) (((f) >> 4) & 0xFu)
#define GHCI_DC_CURSOR_SIZE 64u /* plane 1: 64 x 64 BGRA8, rows 256 bytes apart */


#ifdef __cplusplus
}
#endif

#endif /* GHCI_REGS_H */
