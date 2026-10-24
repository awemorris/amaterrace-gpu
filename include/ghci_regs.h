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

#define GHCI_MAGIC_VALUE 0x47484349u /* "GHCI" */
#define GHCI_VERSION_MAJOR 1u
#define GHCI_VERSION_MINOR 0u

/* FourCCs as read from the ID registers (the first letter in bits 31:24). */
#define GHCI_FOURCC(a, b, c, d) \
	(((unsigned)(a) << 24) | ((unsigned)(b) << 16) | ((unsigned)(c) << 8) | (unsigned)(d))

/* Host control register offsets (bytes). */
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
#define GHCI_RING_BASE 0x050u
#define GHCI_RING_SIZE 0x054u
#define GHCI_RING_WPTR 0x058u
#define GHCI_RING_RPTR 0x05Cu
#define GHCI_APERTURE_BASE 0x060u
#define GHCI_APERTURE_LIMIT 0x064u
#define GHCI_FAULT_ADDR 0x068u
#define GHCI_FAULT_INFO 0x06Cu
#define GHCI_FENCE_LAST 0x070u
#define GHCI_PERF(n) (0x080u + 4u * (n))
#define GHCI_PERF_CTRL 0x090u
#define GHCI_DBG_ADDR 0x0A0u
#define GHCI_DBG_DATA 0x0A4u
#define GHCI_DBG_STATUS 0x0A8u
#define GHCI_CPFW_CTRL 0x120u /* the CPFW capability (id 6), p017 */
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
#define GHCI_CAPS_LINE_LOG2(c) (((c) >> 20) & 0xFu)

/* CAPS2. */
#define GHCI_CAPS2_QUEUES(c) ((c) & 0xFFu)
#define GHCI_CAPS2_LDS_KIB(c) (((c) >> 8) & 0xFFu)
#define GHCI_CAPS2_CONST_WORDS(c) ((((c) >> 16) & 0xFFu) * 16u)
#define GHCI_CAPS2_TEX_SLOTS(c) ((((c) >> 24) & 0xFu) * 4u)
#define GHCI_CAPS2_ATTRS(c) ((((c) >> 28) & 0xFu) * 4u)

/* CTRL. */
#define GHCI_CTRL_RUN (1u << 0)
#define GHCI_CTRL_RESET (1u << 1)
#define GHCI_CTRL_HALT (1u << 2)
#define GHCI_CTRL_STEP (1u << 3)
#define GHCI_CTRL_WDT_EN (1u << 4)

/* STATUS. */
#define GHCI_STATUS_CP_BUSY (1u << 0)
#define GHCI_STATUS_BLT_BUSY (1u << 1)
#define GHCI_STATUS_VF_BUSY (1u << 2)
#define GHCI_STATUS_RX_BUSY (1u << 3)
#define GHCI_STATUS_ROP_BUSY (1u << 4)
#define GHCI_STATUS_TU_BUSY (1u << 5)
#define GHCI_STATUS_SU_BUSY (1u << 6)
#define GHCI_STATUS_AXI_IDLE (1u << 8)
#define GHCI_STATUS_FAULT (1u << 9)
#define GHCI_STATUS_HALTED (1u << 10)
#define GHCI_STATUS_RING_EMPTY (1u << 11)
#define GHCI_STATUS_MEM_READY (1u << 12)
#define GHCI_STATUS_AXI_STUCK (1u << 13)
#define GHCI_STATUS_QUIESCED (1u << 14)
#define GHCI_STATUS_STATE(s) (((s) >> 16) & 0xFu)

/* CP states (STATUS[19:16]). */
#define GHCI_ST_IDLE 0u
#define GHCI_ST_RUNNING 1u
#define GHCI_ST_HALTING 2u
#define GHCI_ST_HALTED 3u
#define GHCI_ST_FAULTED 4u
#define GHCI_ST_RESETTING 5u

/* IRQ_STATUS, IRQ_ENABLE, IRQ_SET. */
#define GHCI_IRQ_FENCE (1u << 0)
#define GHCI_IRQ_FAULT (1u << 1)
#define GHCI_IRQ_RING_EMPTY (1u << 2)
#define GHCI_IRQ_WATCHDOG (1u << 3)
#define GHCI_IRQ_DBG_DONE (1u << 4)
#define GHCI_IRQ_SOFT (1u << 5)
#define GHCI_IRQ_HALTED (1u << 6)
#define GHCI_IRQ_RESULT (1u << 7)
#define GHCI_IRQ_RETIRE (1u << 8)

/* FAULT_INFO. */
#define GHCI_FAULT_CLIENT(f) ((f) & 0xFFu)
#define GHCI_FAULT_WRITE (1u << 8)
#define GHCI_FAULT_KIND(f) (((f) >> 12) & 0xFu)
#define GHCI_FAULT_BLOCK(f) (((f) >> 16) & 0xFFu)
#define GHCI_FAULT_JOB_TAG(f) (((f) >> 24) & 0xFFu)
#define GHCI_FAULT_APERTURE 1u
#define GHCI_FAULT_OPCODE 2u
#define GHCI_FAULT_RING 3u
#define GHCI_FAULT_WATCHDOG 4u
#define GHCI_FAULT_AXI 5u
#define GHCI_FAULT_KICK 6u
#define GHCI_FAULT_LOCKED 7u

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

/* The MEM capability's registers (from its register offset, section 11.3). */
#define GHCI_MEM_LOCAL_BASE 0x0u
#define GHCI_MEM_LOCAL_SIZE 0x4u /* 0 = no local memory (unified) */
#define GHCI_MEM_WINDOW_SIZE 0x8u /* 0 = no local window */

/* The PROT capability's register (from its register offset, section 11.6). */
#define GHCI_PROT_CAPS 0x0u
#define GHCI_PROT_SESSIONS(c) ((c) & 0xFFu)
#define GHCI_PROT_GRANULE_LOG2(c) (((c) >> 8) & 0xFFu)
#define GHCI_PROT_RANGES(c) (((c) >> 16) & 0xFFFFu)

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
#define GHCI_BLT_FILL 0u
#define GHCI_BLT_COPY 1u
#define GHCI_BLT_TILE 2u
#define GHCI_BLT_UNTILE 3u
#define GHCI_BLT_BLEND_OVER (1u << 4)
#define GHCI_BLT_BPP16 (1u << 8)
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
#define GHCI_DC_STANDALONE_DISP 0x200u /* DISP of a DC-only window */
#define GHCI_DC_CTRL_ENABLE (1u << 0)
#define GHCI_DC_CTRL_RESET (1u << 1)
#define GHCI_DC_CTRL_TEST_PATTERN (1u << 2)
#define GHCI_DC_CTRL_FORMAT(f) (((unsigned)(f) & 3u) << 4)
#define GHCI_DC_CTRL_OUTPUT_HDMI (1u << 6)
#define GHCI_DC_FMT_BGRA8 0u
#define GHCI_DC_FMT_RGBA8 1u
#define GHCI_DC_FMT_RGB565 2u
#define GHCI_DC_IRQ_VSYNC (1u << 0)
#define GHCI_DC_IRQ_UNDERFLOW (1u << 1)
#define GHCI_DC_IRQ_FLIP_DONE (1u << 2)

#endif /* GHCI_REGS_H */
