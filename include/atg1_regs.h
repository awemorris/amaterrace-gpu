/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg1_regs.h: Amaterrace GPU (ATG1) internal implementation definitions.
 *
 * Separated from the public GHCI 1.0 contract (ghci_regs.h): contains
 * board/reference PCI IDs and the internal Command Processor -> hardware unit
 * state register file constants used by CP firmware and ATG1 test harnesses.
 */

#ifndef ATG1_REGS_H
#define ATG1_REGS_H

#ifdef __cplusplus
extern "C" {
#endif

/* ATG1 / KC705 Reference PCI Identification Constants */
#define GHCI_PCI_VENDOR_ID_XILINX 0x10EEu
#define GHCI_PCI_DEVICE_ID_KC705  0x7024u
#define GHCI_PCI_VENDOR_ID_ATG    0x5441u /* "AT" */
#define GHCI_PCI_DEVICE_ID_ATG    0x4748u /* "GH" */

/*
 * State register file.  Only the BLT range is defined in this draft; the
 * other ranges follow the command set (docs/atg1/microarch.md).
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
 * The other ranges.  The VF, RX, ROP and TU ranges and the vendor words
 * are ATG1's internal state layout.
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

/* TU: slot s's words, TEX_IMAGE, TEX_SAMPLER and TEX_LOD. */
#define GHCI_S_TEX(s, w) (GHCI_S_TU + 16u * (s) + (w))
#define GHCI_S_TU_VS 0x200u /* CAPS[30]: the vertex stage's 16 slots */
#define GHCI_S_TEX_VS(s, w) (GHCI_S_TU_VS + 16u * (s) + (w))
#define GHCI_TEX_BASE 0u /* level 0 of layer 0, a multiple of 64 */
#define GHCI_TEX_SIZE 1u /* [15:0] width, [31:16] height */
#define GHCI_TEX_IMAGE 2u
#define GHCI_TEX_LAYER_STRIDE 3u /* bytes between layers, a multiple of 64 */
#define GHCI_TEX_SAMPLER 4u
#define GHCI_TEX_LOD 5u
#define GHCI_TEX_FORMAT 6u /* CAPS[30] */
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

/*
 * ATG1 Display Controller (DISP2 window, 0x0C0..0x0DC) vendor extensions.
 * Standard GHCI DISP2 registers (0x000..0x0BC) are in ghci_regs.h.
 */
#define ATG_DC_PLANE2_BASE     0x0C0u /* Secondary overlay plane framebuffer PA/VA */
#define ATG_DC_PLANE2_POS      0x0C4u /* [11:0] pos_x, [27:16] pos_y */
#define ATG_DC_PLANE2_SIZE     0x0C8u /* [11:0] width, [27:16] height */
#define ATG_DC_PLANE2_CTRL     0x0CCu /* [0] en, [15:8] alpha, [16] colorkey_en, [17] yuv_mode */
#define ATG_DC_PLANE2_COLORKEY 0x0D0u /* [23:0] RGB color key */
#define ATG_DC_VRR_CTRL        0x0D4u /* [0] vrr_en, [27:16] vrr_vmax */
#define ATG_DC_HDR_CTRL        0x0D8u /* [0] hdr_en */
#define ATG_DC_FLIP_READY      0x0DCu /* [0] flip_ready (set by W1S or flip submit) */

#define ATG_DC_CTRL_HDR        7u     /* GHCI_DC_CTRL bit 7: enable HDR path */
#define ATG_DC_CTRL_VRR        8u     /* GHCI_DC_CTRL bit 8: enable VRR vblank stretch */
#define ATG_DC_CTRL_PLANE2     9u     /* GHCI_DC_CTRL bit 9: enable Plane 2 overlay */
#define ATG_DC_FMT_A2B10G10R10 3u     /* GHCI_DC_CTRL.FORMAT (bits 5:4) = 3 (10-bpc packed) */

#define ATG_DC_PLANE2_CTRL_EN          (1u << 0)
#define ATG_DC_PLANE2_CTRL_ALPHA(a)    (((unsigned)(a) & 0xFFu) << 8)
#define ATG_DC_PLANE2_CTRL_COLORKEY_EN (1u << 16)
#define ATG_DC_PLANE2_CTRL_YUV         (1u << 17)
#define ATG_DC_VRR_CTRL_EN             (1u << 0)
#define ATG_DC_VRR_CTRL_VMAX(v)        (((unsigned)(v) & 0xFFFu) << 16)
#define ATG_DC_HDR_CTRL_EN             (1u << 0)

#ifdef __cplusplus
}
#endif

#endif /* ATG1_REGS_H */
