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
#define GHCI_REG_BOOT_CAPS       0x008u  /* RO: Boot capabilities (CP, HW_WALKER, PROT, VA/PA enc) */
#define GHCI_REG_EXTCAP_PTR      0x00Cu  /* RO: Extended capabilities list pointer (0x00000100) */

/* Capability Block Word Indices (accessed via CMD_QUERY_CAPS packet) */
#define GHCI_CAP_WORD_BLOCK_ID        0u
#define GHCI_CAP_WORD_BLOCK_INFO      1u
#define GHCI_CAP_WORD_DEVICE_CAPS     2u
#define GHCI_CAP_WORD_EXT_CAP_FEATURE 3u
#define GHCI_CAP_WORD_EXT_CAP_FMT0    4u
#define GHCI_CAP_WORD_RESIDENT_WARPS  5u
#define GHCI_CAP_WORD_NATIVE_ISA_ID   6u
#define GHCI_CAP_WORD_GCLK_HZ         7u
#define GHCI_CAP_WORD_VENDOR_ID       8u
#define GHCI_CAP_WORD_DEVICE_ID       9u
#define GHCI_CAP_WORD_SUBSYSTEM       10u
#define GHCI_CAP_WORD_DEVICE_VERSION  11u
#define GHCI_CAP_WORD_MEM_CACHE_CFG   12u
#define GHCI_CAP_WORD_PROT_CAPS       13u
#define GHCI_CAP_WORD_PERF_SRC        14u
#define GHCI_CAP_WORD_FMT_LIMITS      15u
#define GHCI_CAP_WORD_FMT_FIRST_REG   16u
#define GHCI_CAP_WORD_FMT_COUNT       17u
#define GHCI_CAP_WORD_EXTCAP_PRESENT  18u
#define GHCI_CAP_WORD_SHADER_STAGES   19u /* Pipeline shader stage capabilities (Geometry, Tess, Mesh, Task) */
#define GHCI_CAP_WORD_STAGE_LIMITS    20u /* Stage limits (maxGeometryOutputVertices, maxPatchSize, etc.) */
#define GHCI_CAP_WORD_FMT_BASE        32u

#define GHCI_CAP_DEVICE_CAPS          GHCI_CAP_WORD_DEVICE_CAPS

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
#define GHCI_REG_RESERVED_04C    0x04Cu  /* Reserved (formerly RESIDENT_WARPS) */
#define GHCI_REG_RESIDENT_WARPS  GHCI_REG_RESERVED_04C
#define GHCI_REG_CP_HEAP_BASE    0x050u  /* RW: Autonomous MMU heap base PA [31:0] */
#define GHCI_REG_CP_HEAP_LIMIT   0x054u  /* RW: Autonomous MMU heap limit PA (exclusive) */
#define GHCI_REG_SESSION_ACTIVE  0x058u  /* RO: Active session identifier bitmap */
#define GHCI_REG_TIMESTAMP_LO    0x05Cu  /* RO: 64-bit GPU cycle timestamp [31:0] */
#define GHCI_REG_TIMESTAMP_HI    0x060u  /* RO: 64-bit GPU cycle timestamp [63:32] */
#define GHCI_REG_RESERVED_064    0x064u  /* Reserved (formerly GCLK_HZ) */
#define GHCI_REG_GCLK_HZ         GHCI_REG_RESERVED_064
#define GHCI_REG_RESERVED_068    0x068u  /* Reserved (formerly NATIVE_ISA_ID) */
#define GHCI_REG_NATIVE_ISA_ID   GHCI_REG_RESERVED_068

/* Command Processor Diagnostics */
#define GHCI_REG_DIAG_CP_PC      0x074u  /* RO: Current RV32IM Program Counter of CP firmware */
#define GHCI_REG_DIAG_CP_STATUS  0x078u  /* RO: CP internal FSM state & in-flight draw counter */

/* Fast Extended Capability Mirrors (Reserved) */
#define GHCI_REG_RESERVED_080    0x080u  /* Reserved (formerly EXT_CAP_FMT0) */
#define GHCI_REG_EXT_CAP_FMT0    GHCI_REG_RESERVED_080
#define GHCI_REG_RESERVED_084    0x084u  /* Reserved (formerly EXT_CAP_FEATURE) */
#define GHCI_REG_EXT_CAP_FEATURE GHCI_REG_RESERVED_084

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

/* Driver-Visible Lifecycle States (§5.2) */
#define GHCI_LC_IDLE             0u
#define GHCI_LC_RUNNING          1u
#define GHCI_LC_HALTING          2u
#define GHCI_LC_HALTED           3u
#define GHCI_LC_FAULTED          4u
#define GHCI_LC_RESETTING        5u

/* IRQ_STATUS & IRQ_ENABLE bits (0x038, 0x03C) */
#define GHCI_IRQ_FENCE           (1u << 0)  /* Fence completed */
#define GHCI_IRQ_FAULT           (1u << 1)  /* Hardware / memory translation fault */
#define GHCI_IRQ_WATCHDOG        (1u << 2)  /* Execution timeout / hang */
#define GHCI_IRQ_DISPLAY         (1u << 3)  /* Display scanout / VSYNC event */
#define GHCI_IRQ_SOFT            (1u << 5)  /* Software interrupt (triggered via IRQ_SET) */
#define GHCI_IRQ_HALTED          (1u << 6)  /* Core execution halted following CTRL.HALT (N69) */

/* FAULT_INFO decoding (0x018, K04, N50, N63) */
#define GHCI_FAULT_KIND(info)      ((info) & 0x0Fu)        /* [3:0] Fault kind (1:1 mapped) */
#define GHCI_FAULT_UNIT(info)      (((info) >> 4) & 0x0Fu) /* [7:4] Source unit */
#define GHCI_FAULT_SESSION(info)   (((info) >> 8) & 0xFFu) /* [15:8] Session ID (0..15) */
#define GHCI_FAULT_STAGE(info)     (((info) >> 16) & 0x0Fu) /* [19:16] Active shader stage */
#define GHCI_FAULT_SYNDROME(info)  (((info) >> 20) & 0x0FFFu) /* [31:20] 12-bit subunit syndrome (FAULT_INFO[20] / SYNDROME[0]: 0=Read, 1=Write) */

/* Fault Kinds [3:0] (Strict 1:1 Semantics, N63, N73) */
#define GHCI_FAULT_KIND_NONE            0u
#define GHCI_FAULT_KIND_INVALID_OP      1u /* Unrecognized packet opcode, illegal argument, nested secondary, or shader ISA fault */
#define GHCI_FAULT_KIND_INVALID_ARG     1u /* Alias: invalid argument */
#define GHCI_FAULT_KIND_KICK_ABSENT     2u /* Kick directed to absent hardware unit, or ring out-of-bounds */
#define GHCI_FAULT_KIND_RING_OOB        2u /* Alias: ring out-of-bounds */
#define GHCI_FAULT_KIND_BAD_REG         3u /* Malformed packet header, length mismatch, or bad register */
#define GHCI_FAULT_KIND_WATCHDOG        4u /* Watchdog execution timeout / hang */
#define GHCI_FAULT_KIND_TIMEOUT         4u /* Alias: watchdog timeout */
#define GHCI_FAULT_KIND_AXI_ERROR       5u /* Interconnect / AXI bus DECERR/SLVERR, or fence response error */
#define GHCI_FAULT_KIND_FENCE_ERROR     5u /* Alias: fence response error */
#define GHCI_FAULT_KIND_PROT_FAULT      6u /* Session isolation violation, or secondary privilege violation */
#define GHCI_FAULT_KIND_PRIVILEGED_OP   6u /* Alias: privileged command in secondary buffer (N73) */
#define GHCI_FAULT_KIND_LOCKED_REG      7u /* Write to locked register while running */
#define GHCI_FAULT_KIND_MMU_OOM         8u /* Dynamic page table allocation heap exhausted */
#define GHCI_FAULT_KIND_PAGE_FAULT      9u /* Unmapped virtual page address (FAULT_INFO[20] differentiates read vs write) */
#define GHCI_FAULT_KIND_PERM_FAULT      10u /* VM page access permission violation (read/write/exec flags; FAULT_INFO[20] differentiates read vs write) */
#define GHCI_FAULT_KIND_MEMORY_FAULT    10u /* Alias: memory protection fault */

/* Source Units [7:4] (K04) */
#define GHCI_UNIT_CP             0u
#define GHCI_UNIT_VF             1u
#define GHCI_UNIT_SU             2u
#define GHCI_UNIT_RX             3u
#define GHCI_UNIT_TU             4u
#define GHCI_UNIT_ROP            5u
#define GHCI_UNIT_BLT            6u

/* Shader Stages for FAULT_INFO[19:16] */
#define GHCI_FAULT_STAGE_VS      0u
#define GHCI_FAULT_STAGE_FS      1u
#define GHCI_FAULT_STAGE_CS      2u
#define GHCI_FAULT_STAGE_MS      3u
#define GHCI_FAULT_STAGE_TS      4u
#define GHCI_FAULT_STAGE_TCS     5u
#define GHCI_FAULT_STAGE_TES     6u
#define GHCI_FAULT_STAGE_GS      7u

/* Extended Capability Registers (0x080+) & Feature Field Decoding (K07) */
#define GHCI_FEATURE_VA_BITS(f)   ((f) & 0x0Fu)        /* [3:0] Virtual Address bits (32..40) */
#define GHCI_FEATURE_PA_BITS(f)   (((f) >> 4) & 0x0Fu) /* [7:4] Physical Address bits (40..48) */

/*
 * ============================================================================
 * Legacy GHCI Host Control Register Map (128 KiB window, pre-1.0 prototype)
 * ============================================================================
 */
#define GHCI_LEGACY_MAGIC 0x000u
#define GHCI_LEGACY_VERSION 0x004u
#define GHCI_LEGACY_VENDOR_ID 0x008u
#define GHCI_LEGACY_DEVICE_ID 0x00Cu
#define GHCI_LEGACY_ISA_ID 0x010u
#define GHCI_LEGACY_DEVICE_VERSION 0x014u
#define GHCI_LEGACY_EXTCAP 0x018u
#define GHCI_LEGACY_GCLK_HZ 0x01Cu
#define GHCI_LEGACY_CAPS 0x020u
#define GHCI_LEGACY_CAPS2 0x024u
#define GHCI_LEGACY_SCRATCH 0x028u
#define GHCI_LEGACY_COUNTER 0x02Cu
#define GHCI_LEGACY_CTRL 0x030u
#define GHCI_LEGACY_STATUS 0x034u
#define GHCI_LEGACY_IRQ_STATUS 0x038u
#define GHCI_LEGACY_IRQ_ENABLE 0x03Cu
#define GHCI_LEGACY_IRQ_SET 0x040u
#define GHCI_LEGACY_WDT_CYCLES 0x044u
#define GHCI_LEGACY_RESIDENT_WARPS 0x04Cu	/* R: [15:0] the warps the GPU runs at once (NSU x NWARPS), [23:16] registers per lane */
#define GHCI_RESIDENT_WARPS_COUNT(v) ((v) & 0xFFFFu)
#define GHCI_RESIDENT_WARPS_NREGS(v) (((v) >> 16) & 0xFFu) /* general registers per lane (32 or 64) */

/* Pre-1.0 legacy prototype offsets; abolished in GHCI 1.0 Page 0 MMIO (N60). Do not use in 1.0 drivers. */
#define GHCI_LEGACY_RING_BASE 0x050u
#define GHCI_LEGACY_RING_SIZE 0x054u
#define GHCI_LEGACY_RING_WPTR 0x058u
#define GHCI_LEGACY_RING_RPTR 0x05Cu
#define GHCI_LEGACY_APERTURE_BASE 0x060u
#define GHCI_LEGACY_APERTURE_LIMIT 0x064u
#define GHCI_LEGACY_FAULT_ADDR 0x068u
#define GHCI_LEGACY_FAULT_INFO 0x06Cu
#define GHCI_LEGACY_FENCE_LAST 0x070u
#define GHCI_LEGACY_CP_PC 0x074u
#define GHCI_LEGACY_CP_STATUS 0x078u
#define GHCI_LEGACY_PIPE_FSM 0x07Cu
#define GHCI_LEGACY_PERF0 0x080u
#define GHCI_LEGACY_PERF(n) (0x080u + 4u * (n))
#define GHCI_LEGACY_PERF_CTRL 0x090u
#define GHCI_LEGACY_DBG_ADDR 0x0A0u
#define GHCI_LEGACY_DBG_DATA 0x0A4u
#define GHCI_LEGACY_DBG_STATUS 0x0A8u
#define GHCI_CP_PC GHCI_REG_DIAG_CP_PC
#define GHCI_CP_STATUS GHCI_REG_DIAG_CP_STATUS
#define GHCI_DIAG_CP_PC GHCI_REG_DIAG_CP_PC
#define GHCI_DIAG_CP_STATUS GHCI_REG_DIAG_CP_STATUS
#define GHCI_PIPE_FSM GHCI_LEGACY_PIPE_FSM
#define GHCI_DBG_ADDR GHCI_LEGACY_DBG_ADDR
#define GHCI_DBG_DATA GHCI_LEGACY_DBG_DATA
#define GHCI_DBG_STATUS GHCI_LEGACY_DBG_STATUS
#define GHCI_PERF_CTRL GHCI_LEGACY_PERF_CTRL
#define GHCI_LEGACY_KICK 0xF00u
#define GHCI_KICK GHCI_LEGACY_KICK

/* Short register aliases mapped to GHCI 1.0 canonical registers */
#define GHCI_MAGIC           GHCI_REG_MAGIC
#define GHCI_VERSION         GHCI_REG_VERSION
#define GHCI_BOOT_CAPS       GHCI_REG_BOOT_CAPS
#define GHCI_EXTCAP          GHCI_REG_EXTCAP_PTR
#define GHCI_EXTCAP_PTR      GHCI_REG_EXTCAP_PTR
#define GHCI_STATUS          GHCI_REG_STATUS
#define GHCI_CTRL            GHCI_REG_CTRL
#define GHCI_FAULT_INFO      GHCI_REG_FAULT_INFO
#define GHCI_FAULT_ADDR      GHCI_REG_FAULT_ADDR_LO
#define GHCI_RING_BASE       GHCI_REG_RING_BASE_LO
#define GHCI_RING_SIZE       GHCI_REG_RING_SIZE
#define GHCI_RING_WPTR       GHCI_REG_RING_WPTR
#define GHCI_RING_RPTR       GHCI_REG_RING_RPTR
#define GHCI_IRQ_STATUS      GHCI_REG_IRQ_STATUS
#define GHCI_IRQ_ENABLE      GHCI_REG_IRQ_ENABLE
#define GHCI_IRQ_SET         GHCI_REG_IRQ_SET
#define GHCI_SCRATCH         GHCI_REG_SCRATCH
#define GHCI_WDT_CYCLES      GHCI_REG_WDT_CYCLES
#define GHCI_RESIDENT_WARPS  GHCI_REG_RESIDENT_WARPS
#define GHCI_CP_HEAP_BASE    GHCI_REG_CP_HEAP_BASE
#define GHCI_CP_HEAP_LIMIT   GHCI_REG_CP_HEAP_LIMIT
#define GHCI_SESSION_ACTIVE  GHCI_REG_SESSION_ACTIVE
#define GHCI_TIMESTAMP_LO    GHCI_REG_TIMESTAMP_LO
#define GHCI_TIMESTAMP_HI    GHCI_REG_TIMESTAMP_HI
#define GHCI_GCLK_HZ         GHCI_REG_GCLK_HZ
#define GHCI_NATIVE_ISA_ID   GHCI_REG_NATIVE_ISA_ID
#define GHCI_VENDOR_ID       0x180u
#define GHCI_DEVICE_ID       0x184u

#define GHCI_PERF_SRC0 0x160u
#define GHCI_CPFW_CTRL 0x170u /* the CPFW capability (id 6) */
#define GHCI_CPFW_STATUS 0x174u
#define GHCI_CPFW_VERSION 0x178u
#define GHCI_CPFW_IBASE 0x1A0u
#define GHCI_CPFW_IWORDS 0x1A4u
#define GHCI_CPFW_DBASE 0x1A8u
#define GHCI_CPFW_DWORDS 0x1ACu
#define GHCI_CPFW_MBOX(n) (0x1B0u + 4u * (n)) /* n = 0..3 */
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

/* DEVICE_CAPS (0x008) bits */
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
#define GHCI_DEV_CAP_PROT (1u << 24)
#define GHCI_DEV_CAP_TEX_FFILT (1u << 25)
#define GHCI_DEV_CAP_ROP_PACK (1u << 26)
#define GHCI_DEV_CAP_TASK_SHADER (1u << 27)
#define GHCI_DEV_CAP_MESH_SHADER (1u << 28)
#define GHCI_DEV_CAP_BLT (1u << 29)
#define GHCI_DEV_CAP_DISP (1u << 30)
#define GHCI_DEV_CAP_MSAA (1u << 31)

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
#define GHCI_EXT_FMT_TU_BILINEAR (1u << 16)
#define GHCI_EXT_FMT_BLT_BLEND   (1u << 17)
#define GHCI_EXT_FMT_BLT_TILE    (1u << 18)
#define GHCI_EXT_FMT_TEX_ARRAY   (1u << 19)
#define GHCI_EXT_FMT_TEX_3D      (1u << 20)
#define GHCI_EXT_FMT_TEX_CUBE    (1u << 21)
#define GHCI_EXT_FMT_TEX_TRILINEAR (1u << 22)

/* SHADER_STAGES bits (Capability Block Word 19: GHCI_CAP_WORD_SHADER_STAGES) */
/* Note: Bits [0] and [1] mirror DEVICE_CAPS[27] and DEVICE_CAPS[28] for unified stage query */
#define GHCI_STAGE_CAP_TASK_SHADER       (1u << 0)  /* 1 = Task Shader supported (mirrors DEVICE_CAPS[27]) */
#define GHCI_STAGE_CAP_MESH_SHADER       (1u << 1)  /* 1 = Mesh Shader supported (mirrors DEVICE_CAPS[28]) */
#define GHCI_STAGE_CAP_GEOMETRY_SHADER   (1u << 2)  /* 1 = Geometry Shader supported (VkPhysicalDeviceFeatures::geometryShader) */
#define GHCI_STAGE_CAP_TESSELLATION      (1u << 3)  /* 1 = Tessellation supported (VkPhysicalDeviceFeatures::tessellationShader) */
#define GHCI_STAGE_CAP_STREAM_OUT        (1u << 4)  /* 1 = Transform Feedback Stream Out supported */

#define GHCI_CAP_GEOMETRY_SHADER         GHCI_STAGE_CAP_GEOMETRY_SHADER
#define GHCI_CAP_TESSELLATION            GHCI_STAGE_CAP_TESSELLATION

/* STAGE_LIMITS fields (Capability Block Word 20: GHCI_CAP_WORD_STAGE_LIMITS) */
/* Hardware reports RTL configuration-dependent maximum limits. All stages guaranteed to meet or exceed Vulkan minimums. */
#define GHCI_LIMIT_MAX_GEOM_OUTPUT_VTX(w)  ((w) & 0x1FFu)         /* [8:0]: maxGeometryOutputVertices (e.g. 256) */
#define GHCI_LIMIT_MAX_GEOM_INVOCATIONS(w) (((w) >> 9) & 0x3Fu)   /* [14:9]: maxGeometryShaderInvocations (e.g. 32) */
#define GHCI_LIMIT_MAX_TESS_PATCH_SIZE(w)  (((w) >> 15) & 0x3Fu)  /* [20:15]: maxTessellationPatchSize (e.g. 32) */
#define GHCI_LIMIT_MAX_TESS_GEN_LEVEL(w)   (((w) >> 21) & 0x7Fu)  /* [27:21]: maxTessellationGenerationLevel (e.g. 64) */

/* BOOT_CAPS bits (internal capability register / boot) */
#define GHCI_BOOT_CAP_CP                (1u << 0)
#define GHCI_BOOT_CAP_HW_WALKER         (1u << 1)
#define GHCI_BOOT_CAP_PROT              (1u << 2)
#define GHCI_BOOT_CAP_VA_BITS_MASK      (0xFu << 8)
#define GHCI_BOOT_CAP_VA_BITS_SHIFT     8u
#define GHCI_BOOT_CAP_VA_BITS(c)        (((c) >> 8) & 0xFu)
#define GHCI_BOOT_CAP_PA_BITS_MASK      (0xFu << 12)
#define GHCI_BOOT_CAP_PA_BITS_SHIFT     12u
#define GHCI_BOOT_CAP_PA_BITS(c)        (((c) >> 12) & 0xFu)

#define GHCI_EXT_FEAT_VA_BITS(f)       ((f) & 0x0Fu)
#define GHCI_EXT_FEAT_PA_BITS(f)       (((f) >> 4) & 0x0Fu)
#define GHCI_EXT_FEAT_DUAL_SOURCE      (1u << 8)
#define GHCI_EXT_FEAT_COARSE_SCAN      (1u << 9)
#define GHCI_EXT_FEAT_FAST_CLEAR       (1u << 10)
#define GHCI_EXT_FEAT_LOGIC_OP         (1u << 11)
#define GHCI_EXT_FEAT_EARLY_Z          (1u << 12)
#define GHCI_EXT_FEAT_HW_CURSOR        (1u << 13)
#define GHCI_EXT_FEAT_COLOR_LUT        (1u << 14)
#define GHCI_EXT_FEAT_MRT_BLEND        (1u << 15)
#define GHCI_EXT_FEAT_MAX_MRT(c)       (((c) >> 16) & 0xFu)
#define GHCI_EXT_FEAT_LDS_KB(c)        (((c) >> 20) & 0xFFu)
#define GHCI_EXT_FEAT_FP16             (1u << 28)
#define GHCI_EXT_FEAT_SUBGROUP         (1u << 29)
#define GHCI_EXT_FEAT_CLIP_POLY        (1u << 30)
#define GHCI_EXT_FEAT_BLT_SCALE        (1u << 31)

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
#define GHCI_XCAP_DISP 1u /* reserved: not defined in GHCI 1.0 (section 13.1) */
#define GHCI_XCAP_DBG 2u
#define GHCI_XCAP_PERF 3u
#define GHCI_XCAP_VEND 4u
#define GHCI_XCAP_MMU 5u
#define GHCI_XCAP_CPFW 6u
#define GHCI_XCAP_SA 7u
#define GHCI_XCAP_MEM 8u
#define GHCI_XCAP_PROT 9u
#define GHCI_XCAP_FMT 10u /* EXTCAP_PRESENT Word 18 bit 10 (format table); MMIO window removed */
#define GHCI_XCAP_DISP2 11u

/* The MEM capability's registers (from its register offset, section 11.3). */
#define GHCI_MEM_LOCAL_BASE 0x0u
#define GHCI_MEM_LOCAL_SIZE 0x4u /* 0 = no local memory (unified) */
#define GHCI_MEM_WINDOW_SIZE 0x8u /* 0 = no local window */
#define GHCI_MEM_HOST_LIMIT 0xCu /* host addresses below it, outside local memory; 0 = all */
#define GHCI_MEM_WINDOW_CTRL 0x10u /* RW: [0] ENABLE, the local window is open (reset 1) */
#define GHCI_MEM_WINDOW_ENABLE (1u << 0)
/* CMD_QUERY_CAPS Word 12 (GHCI_CAP_WORD_MEM_CACHE_CFG) field decoders */
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

/* ATG1 internal state register file and PCI IDs live in include/atg1_regs.h. */

/* The display controller's registers (DISP2 capability, ghci.md
 * section 13.2): offsets from the capability's register offset. */
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

/* DISP2 (ghci.md section 13.2), continued; 0x18/0x1C above are
 * DISP_IRQ_STATUS/DISP_IRQ_ENABLE. */
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
