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
#define GHCI_FAULT_ISA 8u

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
#define GHCI_S_ROP_CTRL (GHCI_S_ROP + 29u) /* [0] occlusion count, [1] fp32 blend constants */

/* TU (docs/ghci.md section 8.4): slot s's words, TEX_IMAGE, TEX_SAMPLER
 * and TEX_LOD. */
#define GHCI_S_TEX(s, w) (GHCI_S_TU + 16u * (s) + (w))
#define GHCI_TEX_BASE 0u /* level 0 of layer 0, a multiple of 64 */
#define GHCI_TEX_SIZE 1u /* [15:0] width, [31:16] height */
#define GHCI_TEX_IMAGE 2u
#define GHCI_TEX_LAYER_STRIDE 3u /* bytes between layers, a multiple of 64 */
#define GHCI_TEX_SAMPLER 4u
#define GHCI_TEX_LOD 5u
#define GHCI_TEX_FORMAT 6u /* CAPS[30], docs/ghci.md section 8.5 */
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
