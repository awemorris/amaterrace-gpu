/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci2_regs.h: the GHCI 2.0 Host Control Registers (docs/ghci.md).
 *
 * GHCI 2.0 defines a slim 19-register host MMIO window (76 bytes total),
 * eliminating all STATE registers from MMIO. Dynamic state is baked into
 * in-memory Pipeline State Objects (PSO) or submitted via structured command
 * packets.
 */

#ifndef GHCI2_REGS_H
#define GHCI2_REGS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GHCI2_MAGIC_VALUE        0x47484349u /* ASCII "GHCI" */
#define GHCI2_VERSION_MAJOR      2u
#define GHCI2_VERSION_MINOR      0u
#define GHCI2_VERSION_VALUE      ((GHCI2_VERSION_MAJOR << 16) | GHCI2_VERSION_MINOR)

/* FourCC macro for capability and vendor identifiers */
#define GHCI2_FOURCC(a, b, c, d) \
	(((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

/*
 * ============================================================================
 * GHCI 2.0 Slim Host MMIO Registers (19 registers, 76 bytes: 0x00 - 0x48)
 * ============================================================================
 */

/* Identification & Capabilities */
#define GHCI_REG_MAGIC          0x000u  /* RO: Magic identification ("GHCI") */
#define GHCI_REG_VERSION        0x004u  /* RO: Major [31:16], Minor [15:0] */
#define GHCI_REG_DEVICE_CAPS    0x008u  /* RO: Device capabilities bitfield */
#define GHCI_REG_EXTCAP_PTR     0x00Cu  /* RO: Extended capabilities list pointer (0 = none) */

/* Control & Status */
#define GHCI_REG_CTRL           0x010u  /* RW: Core control bits (RUN, HALT, RESET, etc.) */
#define GHCI_REG_STATUS         0x014u  /* RO: Hardware execution status */
#define GHCI_REG_IRQ_STATUS     0x018u  /* RW1C: Interrupt status (write-1-to-clear) */
#define GHCI_REG_IRQ_ENABLE     0x01Cu  /* RW: Interrupt enable mask */

/* Command Ring Buffer & Doorbell */
#define GHCI_REG_RING_BASE_LO   0x020u  /* RW: Command ring 64-bit base address [31:0] */
#define GHCI_REG_RING_BASE_HI   0x024u  /* RW: Command ring 64-bit base address [63:32] */
#define GHCI_REG_RING_SIZE      0x028u  /* RW: Ring size in bytes (power of 2) */
#define GHCI_REG_RING_RPTR      0x02Cu  /* RO: GPU read pointer (byte offset from BASE) */
#define GHCI_REG_RING_WPTR      0x030u  /* RW: Host write pointer (Doorbell, byte offset) */

/* Fault Diagnostics & Reporting */
#define GHCI_REG_FAULT_INFO     0x034u  /* RO: Fault syndrome, kind, source unit */
#define GHCI_REG_FAULT_ADDR_LO  0x038u  /* RO: Faulting virtual/physical address [31:0] */
#define GHCI_REG_FAULT_ADDR_HI  0x03Cu  /* RO: Faulting virtual/physical address [63:32] */

/* Command Processor Diagnostics */
#define GHCI_REG_DIAG_CP_PC     0x040u  /* RO: Current RV32IM Program Counter */
#define GHCI_REG_DIAG_CP_STATUS 0x044u  /* RO: CP FSM state & in-flight draw counter */

/* Scratchpad */
#define GHCI_REG_SCRATCH        0x048u  /* RW: 32-bit test/scratchpad register */

#define GHCI_SLIM_MMIO_COUNT    19u
#define GHCI_SLIM_MMIO_BYTES    (GHCI_SLIM_MMIO_COUNT * 4u) /* 76 bytes */

/*
 * ============================================================================
 * Register Bitfield Definitions
 * ============================================================================
 */

/* DEVICE_CAPS bits (0x008) */
#define GHCI_CAP_UMA                (1u << 0)  /* 1 = Unified Memory (Shared DRAM), 0 = Discrete */
#define GHCI_CAP_IOMMU              (1u << 1)  /* 1 = Platform / System IOMMU active */
#define GHCI_CAP_HW_WALKER          (1u << 2)  /* 1 = Autonomous HW Page Table Walker present */
#define GHCI_CAP_INDIRECT_DRAW      (1u << 3)  /* 1 = MultiDrawIndirect supported */
#define GHCI_CAP_SECONDARY_RING     (1u << 4)  /* 1 = CMD_EXECUTE_COMMANDS supported */
#define GHCI_CAP_DUAL_SOURCE        (1u << 5)  /* 1 = Dual-source color blending supported */
#define GHCI_CAP_FP16               (1u << 6)  /* 1 = Packed FP16 arithmetic supported */
#define GHCI_CAP_GSI1               (1u << 7)  /* 1 = GSI1 standard shader ISA native */
#define GHCI_CAP_SIMD_LANES(caps)   (((caps) >> 8) & 0xFFu)  /* Physical lanes (4, 8, 16, 32) */
#define GHCI_CAP_NUM_SU(caps)       (((caps) >> 16) & 0xFFu) /* Number of Shader Units */
#define GHCI_CAP_TASK_SHADER        (1u << 30) /* 1 = VK_EXT Task Shader supported */
#define GHCI_CAP_MESH_SHADER        (1u << 31) /* 1 = VK_EXT Mesh Shader supported */

/* Extended Capability Registers (0x080+) */
#define GHCI_REG_EXT_CAP_FMT0       0x080u  /* Texture compression format bitmap (BC1-BC7) */
#define GHCI_REG_EXT_CAP_FEATURE    0x084u  /* Rendering feature detail bitmap */

/* CTRL bits (0x010) */
#define GHCI2_CTRL_RUN              (1u << 0)  /* Enable ring processing */
#define GHCI2_CTRL_HALT             (1u << 1)  /* Request CP to halt after current packet */
#define GHCI2_CTRL_RESET            (1u << 2)  /* Soft reset GPU (self-clearing) */
#define GHCI2_CTRL_IRQ_GLOBAL       (1u << 3)  /* Master interrupt enable */
#define GHCI2_CTRL_TLB_FLUSH        (1u << 4)  /* Invalidate CP L1/L2 TLBs */

/* STATUS bits (0x014) */
#define GHCI2_STATUS_READY          (1u << 0)  /* Hardware ready for commands */
#define GHCI2_STATUS_BUSY           (1u << 1)  /* GPU is executing commands or shaders */
#define GHCI2_STATUS_HALTED         (1u << 2)  /* CP halted */
#define GHCI2_STATUS_FAULT          (1u << 3)  /* Unrecoverable fault occurred */
#define GHCI2_STATUS_RESETTING      (1u << 4)  /* Reset sequence in progress */

/* IRQ_STATUS & IRQ_ENABLE bits (0x018, 0x01C) */
#define GHCI2_IRQ_FENCE             (1u << 0)  /* Fence completed */
#define GHCI2_IRQ_FAULT             (1u << 1)  /* Hardware / memory translation fault */
#define GHCI2_IRQ_WATCHDOG          (1u << 2)  /* Execution timeout / hang */
#define GHCI2_IRQ_DISPLAY           (1u << 3)  /* Display scanout / VSYNC event */

/* FAULT_INFO decoding (0x034) */
#define GHCI2_FAULT_KIND(info)      ((info) & 0xFFu)
#define GHCI2_FAULT_UNIT(info)      (((info) >> 8) & 0xFFu)
#define GHCI2_FAULT_SYNDROME(info)  (((info) >> 16) & 0xFFFFu)

#define GHCI2_FAULT_KIND_NONE       0u
#define GHCI2_FAULT_KIND_INVALID_OP 1u /* Unrecognized packet opcode */
#define GHCI2_FAULT_KIND_RING_OOB   2u /* Ring buffer overrun / bad pointer */
#define GHCI2_FAULT_KIND_PAGE_READ  3u /* MMU page fault on read */
#define GHCI2_FAULT_KIND_PAGE_WRITE 4u /* MMU page fault on write */
#define GHCI2_FAULT_KIND_TLB_ERROR  5u /* TLB translation / descriptor error */
#define GHCI2_FAULT_KIND_ISA_FAULT  6u /* Illegal instruction or shader exception */
#define GHCI2_FAULT_KIND_PROT_FAULT 7u /* Memory access violation */

#define GHCI2_UNIT_CP               0u
#define GHCI2_UNIT_VF               1u
#define GHCI2_UNIT_SU               2u
#define GHCI2_UNIT_RX               3u
#define GHCI2_UNIT_TU               4u
#define GHCI2_UNIT_ROP              5u
#define GHCI2_UNIT_BLT              6u

#ifdef __cplusplus
}
#endif

#endif /* GHCI2_REGS_H */
