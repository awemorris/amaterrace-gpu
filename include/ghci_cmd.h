/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_cmd.h: GHCI 1.0 Structured Command Packets, Immutable Pipeline State
 * Objects (PSO), and In-Memory Resource Descriptors (docs/ghci.md).
 *
 * All structures are defined with explicit sizing and fixed alignments
 * for zero-copy sharing between host drivers (UMD/KMD) and GPU hardware.
 */

#ifndef GHCI_CMD_H
#define GHCI_CMD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ============================================================================
 * GHCI 1.0 Command Opcodes
 * ============================================================================
 */
#define GHCI_CMD_NOP                    0x00u
/* Structured Virtual Memory & Session Commands (0x10..0x1F) */
#define GHCI_CMD_VM_MAP                 0x10u
#define GHCI_CMD_VM_UNMAP               0x11u
#define GHCI_CMD_SESSION_OPEN           0x12u
#define GHCI_CMD_SESSION_CLOSE          0x13u
#define GHCI_CMD_BIND_SESSION           0x14u
#define GHCI_CMD_QUERY_CAPS             0x15u
#define GHCI_CMD_FAULT_LOG_SETUP        0x16u
#define GHCI_CMD_VM_QUERY_PT_MEM        0x17u
#define GHCI_CMD_MMU_ENABLE             0x18u

/*
 * Capability block dword layout (CMD_QUERY_CAPS, 192 dwords / 768 bytes)
 */
#define GHCI_CAPS_BLOCK_ID              0u
#define GHCI_CAPS_BLOCK_INFO            1u
#define GHCI_CAPS_DEVICE_CAPS           2u
#define GHCI_CAPS_EXT_CAP_FEATURE       3u
#define GHCI_CAPS_EXT_CAP_FMT0          4u
#define GHCI_CAPS_RESIDENT_WARPS        5u
#define GHCI_CAPS_NATIVE_ISA_ID         6u
#define GHCI_CAPS_GCLK_HZ               7u
#define GHCI_CAPS_VENDOR_ID             8u
#define GHCI_CAPS_DEVICE_ID             9u
#define GHCI_CAPS_SUBSYSTEM             10u
#define GHCI_CAPS_DEVICE_VERSION        11u
#define GHCI_CAPS_MEM_CACHE_CFG         12u
#define GHCI_CAPS_PROT_CAPS             13u
#define GHCI_CAPS_PERF_SRC              14u
#define GHCI_CAPS_FMT_LIMITS            15u
#define GHCI_CAPS_FMT_FIRST_REG         16u
#define GHCI_CAPS_FMT_COUNT_REG         17u
#define GHCI_CAPS_EXTCAP_PRESENT        18u
#define GHCI_CAPS_SHADER_STAGES         19u
#define GHCI_CAPS_STAGE_LIMITS          20u
#define GHCI_CAPS_DISP_PCLK_MIN_KHZ     21u
#define GHCI_CAPS_DISP_PCLK_MAX_KHZ     22u
#define GHCI_CAPS_DISP_PCLK_INFO        23u
#define GHCI_CAPS_DISP_LIMITS_H         24u
#define GHCI_CAPS_DISP_LIMITS_V         25u
#define GHCI_CAPS_DESC_LIMITS           26u
#define GHCI_CAPS_TEX_LIMITS            27u
#define GHCI_CAPS_DISP_MIN_H_BLANK      28u
#define GHCI_CAPS_DISP_MIN_V_BLANK      29u
#define GHCI_CAPS_TIMESTAMP_HZ          30u
#define GHCI_CAPS_TEX_LIMITS_3D         31u
#define GHCI_CAPS_FMT_BASE              32u
#define GHCI_CAPS_MIN_QUERY_BYTES       64u
#define GHCI_CAPS_STD_FMT_COUNT         160u
#define GHCI_CAPS_MAX_FMT_COUNT         255u /* 0x00..0xFE; 0xFF (GHCI_FMT_INVALID) excluded */
#define GHCI_CAPS_STD_DWORDS            (32u + GHCI_CAPS_STD_FMT_COUNT) /* 192 */
#define GHCI_CAPS_STD_BYTES             (GHCI_CAPS_STD_DWORDS * 4u)     /* 768 */

/*
 * GHCI 1.0 Format Identifiers (GhciFormat, 8-bit: 0x00..0xFF)
 */
#define GHCI_FMT_NONE                   0x00u
/* Packed 16/32-bit color formats (0x01..0x0F) */
#define GHCI_FMT_B4G4R4A4_UNORM_P16     0x01u
#define GHCI_FMT_R5G6B5_UNORM_P16       0x02u
#define GHCI_FMT_A1R5G5B5_UNORM_P16     0x03u
#define GHCI_FMT_A2B10G10R10_UNORM_P32  0x04u
#define GHCI_FMT_A2B10G10R10_UINT_P32   0x05u
#define GHCI_FMT_B10G11R11_UFLOAT_P32   0x06u
#define GHCI_FMT_E5B9G9R9_UFLOAT_P32    0x07u
/* 8-bit/channel formats (0x10..0x2F, 8-slot group stride) */
#define GHCI_FMT_R8_UNORM               0x10u
#define GHCI_FMT_R8_SNORM               0x11u
#define GHCI_FMT_R8_UINT                0x12u
#define GHCI_FMT_R8_SINT                0x13u
#define GHCI_FMT_R8G8_UNORM             0x18u
#define GHCI_FMT_R8G8_SNORM             0x19u
#define GHCI_FMT_R8G8_UINT              0x1Au
#define GHCI_FMT_R8G8_SINT              0x1Bu
#define GHCI_FMT_R8G8B8A8_UNORM         0x20u
#define GHCI_FMT_R8G8B8A8_SNORM         0x21u
#define GHCI_FMT_R8G8B8A8_UINT          0x22u
#define GHCI_FMT_R8G8B8A8_SINT          0x23u
#define GHCI_FMT_R8G8B8A8_SRGB          0x24u
#define GHCI_FMT_B8G8R8A8_UNORM         0x28u
#define GHCI_FMT_B8G8R8A8_SRGB          0x2Cu
/* 16-bit/channel formats (0x30..0x4F, 8-slot group stride) */
#define GHCI_FMT_R16_UNORM              0x30u
#define GHCI_FMT_R16_SNORM              0x31u
#define GHCI_FMT_R16_UINT               0x32u
#define GHCI_FMT_R16_SINT               0x33u
#define GHCI_FMT_R16_SFLOAT             0x34u
#define GHCI_FMT_R16G16_UNORM           0x38u
#define GHCI_FMT_R16G16_SNORM           0x39u
#define GHCI_FMT_R16G16_UINT            0x3Au
#define GHCI_FMT_R16G16_SINT            0x3Bu
#define GHCI_FMT_R16G16_SFLOAT          0x3Cu
#define GHCI_FMT_R16G16B16A16_UNORM     0x40u
#define GHCI_FMT_R16G16B16A16_SNORM     0x41u
#define GHCI_FMT_R16G16B16A16_UINT      0x42u
#define GHCI_FMT_R16G16B16A16_SINT      0x43u
#define GHCI_FMT_R16G16B16A16_SFLOAT    0x44u
/* 32-bit/channel formats (0x50..0x6F, 8-slot group stride) */
#define GHCI_FMT_R32_UINT               0x52u
#define GHCI_FMT_R32_SINT               0x53u
#define GHCI_FMT_R32_SFLOAT             0x54u
#define GHCI_FMT_R32G32_UINT            0x5Au
#define GHCI_FMT_R32G32_SINT            0x5Bu
#define GHCI_FMT_R32G32_SFLOAT          0x5Cu
#define GHCI_FMT_R32G32B32_UINT         0x62u
#define GHCI_FMT_R32G32B32_SINT         0x63u
#define GHCI_FMT_R32G32B32_SFLOAT       0x64u
#define GHCI_FMT_R32G32B32A32_UINT      0x6Au
#define GHCI_FMT_R32G32B32A32_SINT      0x6Bu
#define GHCI_FMT_R32G32B32A32_SFLOAT    0x6Cu
/* Depth & Stencil formats (0x70..0x7F) */
#define GHCI_FMT_D16_UNORM              0x70u
#define GHCI_FMT_X8D24_UNORM_P32        0x71u
#define GHCI_FMT_D32_SFLOAT             0x72u
#define GHCI_FMT_S8_UINT                0x73u
#define GHCI_FMT_D24_UNORM_S8_UINT      0x74u
#define GHCI_FMT_D32_SFLOAT_S8_UINT     0x75u
/* Block-compressed formats BC1..BC7 (0x80..0x8F) */
#define GHCI_FMT_BC1_RGB_UNORM_BLK      0x80u
#define GHCI_FMT_BC1_RGB_SRGB_BLK       0x81u
#define GHCI_FMT_BC1_RGBA_UNORM_BLK     0x82u
#define GHCI_FMT_BC1_RGBA_SRGB_BLK      0x83u
#define GHCI_FMT_BC2_UNORM_BLK          0x84u
#define GHCI_FMT_BC2_SRGB_BLK           0x85u
#define GHCI_FMT_BC3_UNORM_BLK          0x86u
#define GHCI_FMT_BC3_SRGB_BLK           0x87u
#define GHCI_FMT_BC4_UNORM_BLK          0x88u
#define GHCI_FMT_BC4_SNORM_BLK          0x89u
#define GHCI_FMT_BC5_UNORM_BLK          0x8Au
#define GHCI_FMT_BC5_SNORM_BLK          0x8Bu
#define GHCI_FMT_BC6H_UFLOAT_BLK        0x8Cu
#define GHCI_FMT_BC6H_SFLOAT_BLK        0x8Du
#define GHCI_FMT_BC7_UNORM_BLK          0x8Eu
#define GHCI_FMT_BC7_SRGB_BLK           0x8Fu
/* Block-compressed formats ETC2/EAC (0x90..0x99) */
#define GHCI_FMT_ETC2_R8G8B8_UNORM_BLK  0x90u
#define GHCI_FMT_ETC2_R8G8B8_SRGB_BLK   0x91u
#define GHCI_FMT_ETC2_R8G8B8A1_UNORM_BLK 0x92u
#define GHCI_FMT_ETC2_R8G8B8A1_SRGB_BLK 0x93u
#define GHCI_FMT_ETC2_R8G8B8A8_UNORM_BLK 0x94u
#define GHCI_FMT_ETC2_R8G8B8A8_SRGB_BLK 0x95u
#define GHCI_FMT_EAC_R11_UNORM_BLK      0x96u
#define GHCI_FMT_EAC_R11_SNORM_BLK      0x97u
#define GHCI_FMT_EAC_R11G11_UNORM_BLK   0x98u
#define GHCI_FMT_EAC_R11G11_SNORM_BLK   0x99u
/* Invalid sentinel (excluded from CMD_QUERY_CAPS per-format table) */
#define GHCI_FMT_INVALID                0xFFu

/* Word-prefixed aliases */
#define GHCI_CAPS_WORD_BLOCK_ID         0u
#define GHCI_CAPS_WORD_BLOCK_INFO       1u
#define GHCI_CAPS_WORD_DEVICE_CAPS      2u
#define GHCI_CAPS_WORD_EXT_CAP_FEATURE  3u
#define GHCI_CAPS_WORD_EXT_CAP_FMT0     4u
#define GHCI_CAPS_WORD_RESIDENT_WARPS   5u
#define GHCI_CAPS_WORD_NATIVE_ISA_ID    6u
#define GHCI_CAPS_WORD_GCLK_HZ          7u
#define GHCI_CAPS_WORD_VENDOR_ID        8u
#define GHCI_CAPS_WORD_DEVICE_ID        9u
#define GHCI_CAPS_WORD_SUBSYSTEM        10u
#define GHCI_CAPS_WORD_DEVICE_VERSION   11u
#define GHCI_CAPS_WORD_MEM_CACHE_CFG    12u
#define GHCI_CAPS_WORD_PROT_CAPS        13u
#define GHCI_CAPS_WORD_PERF_SRC         14u
#define GHCI_CAPS_WORD_FMT_LIMITS       15u
#define GHCI_CAPS_WORD_FMT_FIRST_REG    16u
#define GHCI_CAPS_WORD_FMT_COUNT_REG    17u
#define GHCI_CAPS_WORD_EXTCAP_PRESENT   18u
#define GHCI_CAPS_WORD_SHADER_STAGES    19u
#define GHCI_CAPS_WORD_STAGE_LIMITS     20u
#define GHCI_CAPS_WORD_DISP_PCLK_MIN_KHZ 21u
#define GHCI_CAPS_WORD_DISP_PCLK_MAX_KHZ 22u
#define GHCI_CAPS_WORD_DISP_PCLK_INFO   23u
#define GHCI_CAPS_WORD_DISP_LIMITS_H    24u
#define GHCI_CAPS_WORD_DISP_LIMITS_V    25u
#define GHCI_CAPS_WORD_DESC_LIMITS      26u
#define GHCI_CAPS_WORD_TEX_LIMITS       27u
#define GHCI_CAPS_WORD_DISP_MIN_H_BLANK 28u
#define GHCI_CAPS_WORD_DISP_MIN_V_BLANK 29u
#define GHCI_CAPS_WORD_TIMESTAMP_HZ     30u
#define GHCI_CAPS_WORD_TEX_LIMITS_3D    31u
#define GHCI_CAPS_WORD_FMT_BASE         32u

/* Pipeline State & Execution Commands (0x20..0x2F) */
#define GHCI_CMD_BIND_PIPELINE          0x20u
#define GHCI_CMD_BIND_VERTEX_BUFFERS    0x21u
#define GHCI_CMD_BIND_INDEX_BUFFER      0x22u
#define GHCI_CMD_BIND_DESCRIPTOR_TABLE  0x23u
#define GHCI_CMD_SET_VIEWPORT           0x24u
#define GHCI_CMD_SET_SCISSOR            0x25u
#define GHCI_CMD_SET_DYNAMIC_STATE      0x26u
#define GHCI_CMD_DRAW                   0x27u
#define GHCI_CMD_DRAW_INDEXED           0x28u
#define GHCI_CMD_DRAW_INDIRECT          0x29u
#define GHCI_CMD_DRAW_MESH_TASKS        0x2Au
#define GHCI_CMD_BEGIN_RENDER_PASS      0x2Bu
#define GHCI_CMD_END_RENDER_PASS        0x2Cu
#define GHCI_CMD_LOAD_CONST             0x2Du

/* Compute & Synchronization Commands (0x30..0x3F) */
#define GHCI_CMD_DISPATCH_INDIRECT      0x2Eu
#define GHCI_CMD_DISPATCH               0x30u
#define GHCI_CMD_BARRIER                0x31u
#define GHCI_CMD_EXECUTE_COMMANDS       0x32u
#define GHCI_CMD_FENCE                  0x33u
#define GHCI_CMD_WAIT_FENCE             0x34u
#define GHCI_CMD_WRITE_TIMESTAMP        0x35u
#define GHCI_CMD_BEGIN_QUERY            0x36u
#define GHCI_CMD_END_QUERY              0x37u

/* Memory Transfer & Blit Commands (0x40..0x4F, Guarded by CAP_BLT) */
#define GHCI_CMD_COPY_BUFFER            0x40u
#define GHCI_CMD_COPY_IMAGE             0x41u
#define GHCI_CMD_BLIT                   0x42u
#define GHCI_CMD_FILL_BUFFER            0x43u
#define GHCI_CMD_RESOLVE_IMAGE          0x44u
#define GHCI_CMD_COPY_BUFFER_TO_IMAGE   0x45u
#define GHCI_CMD_COPY_IMAGE_TO_BUFFER   0x46u

/* Display Controller Commands (0x50..0x57, Guarded by CAP_DISP, Primary Ring Only) */
#define GHCI_CMD_DISP_SET               0x50u
#define GHCI_CMD_FLIP                   0x51u
#define GHCI_CMD_DISP_SET_MODE          0x52u
#define GHCI_CMD_DISP_QUERY_STATE       0x53u
#define GHCI_CMD_DISP_SET_CURSOR        0x54u
#define GHCI_CMD_DISP_QUERY_MODES       0x55u
#define GHCI_CMD_DISP_EVENT_SETUP       0x56u
#define GHCI_CMD_DISP_I2C_XFER          0x57u

/* Packet header helper */
#define GHCI_MAKE_HEADER(opcode, dwords, flags) \
	(((uint32_t)(opcode) & 0xFFu) | (((uint32_t)(dwords) & 0xFFu) << 8) | (((uint32_t)(flags) & 0xFFFFu) << 16))

#define GHCI_HEADER_OPCODE(hdr)         ((hdr) & 0xFFu)
#define GHCI_HEADER_DWORDS(hdr)         (((hdr) >> 8) & 0xFFu)
#define GHCI_HEADER_FLAGS(hdr)          (((hdr) >> 16) & 0xFFFFu)

/*
 * ============================================================================
 * In-Memory Immutable Pipeline State Object (GhciPipelineState) - 128 Bytes
 * ============================================================================
 */
#define GHCI_TOPOLOGY_POINT             0u
#define GHCI_TOPOLOGY_LINE              1u
#define GHCI_TOPOLOGY_LINE_STRIP        2u
#define GHCI_TOPOLOGY_TRIANGLE          3u
#define GHCI_TOPOLOGY_TRIANGLE_STRIP    4u
#define GHCI_TOPOLOGY_PATCH_LIST        7u

/* Geometry Shader Input Topologies (GhciPipelineStateExt.gs_state[3:0]) */
#define GHCI_GS_INPUT_POINTS                        0u
#define GHCI_GS_INPUT_LINES                         1u
#define GHCI_GS_INPUT_LINE_STRIP                    2u
#define GHCI_GS_INPUT_TRIANGLES                     3u
#define GHCI_GS_INPUT_TRIANGLE_STRIP                4u
#define GHCI_GS_INPUT_LINES_WITH_ADJACENCY          6u
#define GHCI_GS_INPUT_LINE_STRIP_WITH_ADJACENCY     7u
#define GHCI_GS_INPUT_TRIANGLES_WITH_ADJACENCY      8u
#define GHCI_GS_INPUT_TRIANGLE_STRIP_WITH_ADJACENCY 9u

/* Geometry Shader Output Topologies (GhciPipelineStateExt.gs_state[6:4]) */
#define GHCI_GS_OUTPUT_POINTS                       0u
#define GHCI_GS_OUTPUT_LINE_STRIP                   1u
#define GHCI_GS_OUTPUT_TRIANGLE_STRIP               2u

#define GHCI_GS_OUTPUT_STRIDE_WORDS(w)              (((uint32_t)(w) & 0x7Fu) << 24)
#define GHCI_GS_GET_OUTPUT_STRIDE_WORDS(g)          (((g) >> 24) & 0x7Fu)

/* Tessellation Domain & Spacing (GhciPipelineStateExt.tess_state) */
#define GHCI_TESS_DOMAIN_TRIANGLE                   0u
#define GHCI_TESS_DOMAIN_QUAD                       1u
#define GHCI_TESS_DOMAIN_ISOLINE                    2u

#define GHCI_TESS_SPACING_EQUAL                     0u
#define GHCI_TESS_SPACING_FRACTIONAL_EVEN           1u
#define GHCI_TESS_SPACING_FRACTIONAL_ODD            2u

#define GHCI_TESS_WINDING_CCW                       0u
#define GHCI_TESS_WINDING_CW                        1u

#define GHCI_TESS_CP_STRIDE_WORDS(w)                (((uint32_t)(w) & 0x7Fu) << 18)
#define GHCI_TESS_PATCH_STRIDE_128B(s)              (((uint32_t)(s) & 0x7Fu) << 25)
#define GHCI_TESS_GET_CP_STRIDE_WORDS(t)            (((t) >> 18) & 0x7Fu)
#define GHCI_TESS_GET_PATCH_STRIDE_BYTES(t)         ((((t) >> 25) & 0x7Fu) * 128u)

#define GHCI_CULL_NONE                  0u
#define GHCI_CULL_FRONT                 1u
#define GHCI_CULL_BACK                  2u
#define GHCI_CULL_FRONT_AND_BACK        3u

#define GHCI_FRONT_CCW                  0u
#define GHCI_FRONT_CW                   1u

#define GHCI_POLYGON_FILL               0u
#define GHCI_POLYGON_LINE               1u
#define GHCI_POLYGON_POINT              2u

#define GHCI_COMPARE_NEVER              0u
#define GHCI_COMPARE_LESS               1u
#define GHCI_COMPARE_EQUAL              2u
#define GHCI_COMPARE_LEQUAL             3u
#define GHCI_COMPARE_GREATER            4u
#define GHCI_COMPARE_NEQUAL             5u
#define GHCI_COMPARE_GEQUAL             6u
#define GHCI_COMPARE_ALWAYS             7u

#define GHCI_BLEND_OP_ADD               0u
#define GHCI_BLEND_OP_SUBTRACT          1u
#define GHCI_BLEND_OP_REVERSE_SUBTRACT  2u
#define GHCI_BLEND_OP_MIN               3u
#define GHCI_BLEND_OP_MAX               4u

#define GHCI_BLEND_FACTOR_ZERO                     0u
#define GHCI_BLEND_FACTOR_ONE                      1u
#define GHCI_BLEND_FACTOR_SRC_COLOR                2u
#define GHCI_BLEND_FACTOR_ONE_MINUS_SRC_COLOR      3u
#define GHCI_BLEND_FACTOR_DST_COLOR                4u
#define GHCI_BLEND_FACTOR_ONE_MINUS_DST_COLOR      5u
#define GHCI_BLEND_FACTOR_SRC_ALPHA                6u
#define GHCI_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA      7u
#define GHCI_BLEND_FACTOR_DST_ALPHA                8u
#define GHCI_BLEND_FACTOR_ONE_MINUS_DST_ALPHA      9u
#define GHCI_BLEND_FACTOR_CONSTANT_COLOR           10u
#define GHCI_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR 11u
#define GHCI_BLEND_FACTOR_CONSTANT_ALPHA           12u
#define GHCI_BLEND_FACTOR_ONE_MINUS_CONSTANT_ALPHA 13u
#define GHCI_BLEND_FACTOR_SRC_ALPHA_SATURATE       14u
#define GHCI_BLEND_FACTOR_SRC1_COLOR               15u
#define GHCI_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR     16u
#define GHCI_BLEND_FACTOR_SRC1_ALPHA               17u
#define GHCI_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA     18u

/*
 * Vertex Attribute High-Density Packing (K11):
 * 128-byte PSO allocates 64 bytes (0x40 - 0x7F) for 16 vertex attributes (4 bytes each):
 *   [7:0]   format:       VkFormat / Amaterrace internal format ID (0..255)
 *   [11:8]  binding_index: Vertex buffer binding slot (0..15)
 *   [12]    input_rate:   0 = PER_VERTEX, 1 = PER_INSTANCE
 *   [31:13] offset:       Byte offset within vertex buffer (0..524287 bytes, up to 512 KiB)
 */
#define GHCI_VERTEX_INPUT_RATE_VERTEX   0u
#define GHCI_VERTEX_INPUT_RATE_INSTANCE 1u

#define GHCI_VERTEX_ATTR_PACK(fmt, binding, rate, offset) \
	(((uint32_t)(fmt) & 0xFFu) | \
	 (((uint32_t)(binding) & 0x0Fu) << 8) | \
	 (((uint32_t)(rate) & 0x01u) << 12) | \
	 (((uint32_t)(offset) & 0x7FFFFu) << 13))

/*
 * ============================================================================
 * Shader Stage Interface & Register Conventions (N37)
 * ============================================================================
 */

/* Vertex Shader General Register Allocation ABI (§12.10.3 Consecutive Register Allocation) */
#define GHCI_VS_REG_ATTR_COMP(base, comp)   (((uint32_t)(base)) + ((uint32_t)(comp) & 3u))
#define GHCI_VS_REG_ATTR(base, comp)        GHCI_VS_REG_ATTR_COMP(base, comp)
/* Legacy fixed 4-component slot mapping (deprecated, provided for backward compatibility) */
#define GHCI_VS_REG_ATTR_LEGACY(loc, comp)  (((uint32_t)(loc) * 4u) + ((uint32_t)(comp) & 3u))
#define GHCI_VS_REG_VERTEX_INDEX        60u     /* gl_VertexIndex (uint32) */
#define GHCI_VS_REG_INSTANCE_INDEX      61u     /* gl_InstanceIndex (uint32) */
#define GHCI_VS_REG_SCRATCH             62u     /* Compiler scratchpad */

/* Vertex & Geometry Shader Export Targets (exp rs2, target) */
#define GHCI_EXP_POS(c)                 (0x000u + ((uint32_t)(c) & 3u))
#define GHCI_EXP_POINT_SIZE             0x004u
#define GHCI_EXP_LAYER                  0x005u  /* gl_Layer (GL 3.2, layered render targets) */
#define GHCI_EXP_VIEWPORT_INDEX         0x006u  /* gl_ViewportIndex (GL 4.1, multi-viewport) */
#define GHCI_EXP_PRIMITIVE_ID           0x007u  /* gl_PrimitiveID (Geometry Shader output) */
#define GHCI_EXP_VARYING(w)             (0x010u + ((uint32_t)(w) & 0x3Fu))
#define GHCI_EXP_GEOM_EMIT              0x200u  /* EmitVertex / primitive stream export */
#define GHCI_EXP_GEOM_CUT               0x201u  /* EndPrimitive / strip cut */

/* System Built-in Operands for Geometry and Tessellation Stages (§12.3, §12.10) */
/* Note: gl_PrimitiveID / gl_PrimitiveIDIn reuse GSI1 standard operand 113 (GSI1_PRIM). */
/* gl_TessCoord.z (tess_w) is derived by compiler as (1.0 - u - v), saving operand slots. */
#define GHCI_SYS_OPERAND_INVID          122u    /* gl_InvocationID */
#define GHCI_SYS_OPERAND_PATCH_VTX_IN   123u    /* gl_PatchVerticesIn */
#define GHCI_SYS_OPERAND_TESS_COORD_U   124u    /* gl_TessCoord.x */
#define GHCI_SYS_OPERAND_TESS_COORD_V   125u    /* gl_TessCoord.y */
/* Operands 126..127 are reserved (read 0) for future system built-ins */

/* Fragment Shader Input Registers */
#define GHCI_FS_REG_BARY_B0             0u
#define GHCI_FS_REG_BARY_B1             1u
#define GHCI_FS_REG_BARY_B2             2u
#define GHCI_FS_REG_DEPTH               3u
#define GHCI_FS_REG_FRAGCOORD_X         4u
#define GHCI_FS_REG_FRAGCOORD_Y         5u
#define GHCI_FS_REG_SAMPLE_MASK_IN      6u
#define GHCI_FS_REG_CENTROID_B0         7u
#define GHCI_FS_REG_CENTROID_B1         8u
#define GHCI_FS_REG_CENTROID_B2         9u
#define GHCI_FS_REG_POINT_S             0u
#define GHCI_FS_REG_POINT_T             1u

/* Fragment Shader Export Targets (exp rs2, target) */
#define GHCI_EXP_COLOR(k, c)            (0x100u + 16u * ((uint32_t)(k) & 7u) + ((uint32_t)(c) & 3u))
#define GHCI_EXP_DEPTH                  0x104u
#define GHCI_EXP_SAMPLE_MASK            0x105u
#define GHCI_EXP_COLOR0_SRC1(c)         (0x108u + ((uint32_t)(c) & 3u))

#define GHCI_VERTEX_ATTR_FORMAT(a)     ((a) & 0xFFu)
#define GHCI_VERTEX_ATTR_BINDING(a)    (((a) >> 8) & 0x0Fu)
#define GHCI_VERTEX_ATTR_RATE(a)       (((a) >> 12) & 0x01u)
#define GHCI_VERTEX_ATTR_OFFSET(a)     (((a) >> 13) & 0x7FFFFu)

typedef struct GhciVertexAttribute {
	uint32_t packed_attr; /* [7:0] format, [11:8] binding, [12] input_rate, [31:13] offset (K11) */
} GhciVertexAttribute;

typedef struct GhciPipelineState {
	/* 0x00: Shader Stages (64-bit GPU virtual addresses) */
	uint64_t vs_code_va;            /* dw0-1: Vertex Shader instruction base */
	uint64_t fs_code_va;            /* dw2-3: Fragment Shader instruction base */
	uint64_t cs_code_va;            /* dw4-5: Compute Shader instruction base */
	uint64_t ms_code_va;            /* dw6-7: Mesh/task Shader instruction base */

	/* 0x20: Pipeline Creation Flags & Rasterizer State */
	uint32_t flags;                 /* dw8: [2:0] topology, [3] prim restart, [4] depth clamp, [5] logic op enable, [9:6] logic op opcode, [10] alpha to coverage, [11] sample shading, [15:12] sample mask, [16] has_ext_stages (N14, N32) */
	uint32_t raster_state;          /* dw9: [1:0] cull mode, [2] front face CW, [4:3] polygon mode, [5] depth bias enable, [13:6] line width (N14) */
	uint32_t depth_stencil_state;   /* dw10: [0] depth test, [1] depth write, [4:2] depth op, [5] stencil test, [8:6] front fail op, [11:9] front pass op, [14:12] front depth fail op, [17:15] front compare op, [20:18] back fail op, [23:21] back pass op, [26:24] back depth fail op, [29:27] back compare op, [30] separate back stencil enable (N14) */
	uint32_t blend_state;           /* dw11: Color blend factors & ops */
	uint32_t vertex_strides;        /* dw12: Default packed strides for bindings 0..3 (used when CMD_BIND_VERTEX_BUFFERS stride is GHCI_STRIDE_FROM_PSO) (N14) */
	uint32_t shader_resource_limits;/* dw13: [7:0] used_regs_vs (1..63), [15:8] used_regs_fs (1..63), [23:16] used_regs_cs/ms (1..63), [31:24] varying_count (0..16) (N01) */
	uint32_t compute_local_size;    /* dw14: [9:0] local_size_x, [19:10] local_size_y, [29:20] local_size_z (N01) */
	uint32_t compute_lds_and_flags; /* dw15: [15:0] lds_bytes (0..16384), [16] fs_centroid, [17] fs_depth_export, [18] fs_discard (N01, N24) */

	/* 0x40: Vertex Attributes Descriptor (64 bytes: 16 attributes x 4 bytes, K11) */
	uint32_t attributes[16];        /* dw16-31: 16 packed vertex attributes */
} GhciPipelineState;

/*
 * ============================================================================
 * Extended Pipeline State Object (GhciPipelineStateExt) - 256 Bytes
 * Active when GhciPipelineState.flags[16] (GHCI_PSO_FLAG_HAS_EXT_STAGES) == 1.
 * Supports Tessellation (TCS/TES) and Geometry Shader (GS) pipeline stages.
 * Alignment: 64-byte aligned in GPU virtual address space.
 * ============================================================================
 */
#define GHCI_PSO_FLAG_HAS_EXT_STAGES    (1u << 16) /* 1 = 256-byte GhciPipelineStateExt */

typedef struct GhciPipelineStateExt {
	/* 0x00..0x7F: Core Pipeline State (128 Bytes, identical to GhciPipelineState) */
	GhciPipelineState core;

	/* 0x80: Extended Shader Stages (64-bit GPU virtual addresses) */
	uint64_t tcs_code_va;            /* dw32-33: Tessellation Control Shader instruction base */
	uint64_t tes_code_va;            /* dw34-35: Tessellation Evaluation Shader instruction base */
	uint64_t gs_code_va;             /* dw36-37: Geometry Shader instruction base */

	/* 0x98: Tessellation and Geometry Shader Pipeline State */
	uint32_t tess_state;             /* dw38: [5:0] input_patch_control_points (1..32), [11:6] output_patch_control_points (1..32), [13:12] domain (0: Tri, 1: Quad, 2: Iso), [15:14] spacing, [16] winding (0: CCW, 1: CW), [17] point_mode, [24:18] cp_stride_words (0..127 words per CP), [31:25] patch_stride_128b (1..127 x 128B patch LDS size; requires 0x220 + output_points*cp_stride_words*4 <= 16256) */
	uint32_t gs_state;               /* dw39: [3:0] input_topology (0..9), [6:4] output_topology (0: Points, 1: LineStrip, 2: TriangleStrip), [15:7] max_vertices (1..256), [21:16] invocations (1..32), [23:22] stream_count (0..3 -> 1..4 streams, reserved for GL 4.0), [30:24] output_stride_words (1..127 words per output vertex), [31] reserved */
	uint32_t shader_resource_limits_ext; /* dw40: [7:0] used_regs_tcs (1..63), [15:8] used_regs_tes (1..63), [23:16] used_regs_gs (1..63), [31:24] reserved */

	/* 0xA4: Geometry Shader Spill Memory Buffer (For Amplification Exceeding LDS) */
	uint64_t geom_spill_va;          /* dw41-42: 64-bit GPU virtual address of driver-allocated spill ring buffer (64-byte aligned; 0 = LDS only) */
	uint32_t geom_spill_size_bytes;  /* dw43: Size in bytes of spill ring buffer */
	uint32_t geom_spill_stride_bytes;/* dw44: Maximum per-invocation spill slice size */

	/* 0xB4..0xFF: Reserved for Future Extensions (76 Bytes / 19 Dwords) */
	uint32_t reserved_ext[19];       /* dw45-63: Must be 0 */
} GhciPipelineStateExt;

/*
 * ============================================================================
 * In-Memory Resource Descriptors
 * ============================================================================
 */

/* Texture Descriptor Dimensions and Flags (§8.3) */
#define GHCI_TEX_DIM_1D                 0u
#define GHCI_TEX_DIM_2D                 1u
#define GHCI_TEX_DIM_3D                 2u
#define GHCI_TEX_DIM_CUBE               3u

#define GHCI_TEX_FLAG_TILED             (1u << 0) /* 1 = Optimal tiled, 0 = Linear */
#define GHCI_TEX_FLAG_STENCIL_ASPECT    (1u << 2) /* 1 = Sample stencil aspect of depth-stencil format */
#define GHCI_TEX_FLAG_ROW_ALIGN_SHIFT   3u        /* [4:3] Linear row alignment log2 (0=packed/64B rule) */
#define GHCI_TEX_FLAG_ROW_ALIGN_MASK    (0x3u << 3)
#define GHCI_TEX_FLAG_ROW_ALIGN_LOG2(x) (((uint16_t)(x) & 0x3u) << 3)
#define GHCI_TEX_FLAG_ARRAY             (1u << 5) /* 1 = Arrayed (1D/2D/Cube); 3D with ARRAY=1 is INVALID_OP */

/* Texture Descriptor (32 Bytes) */
typedef struct GhciTextureDescriptor {
	uint64_t base_address;          /* 0x00: GPU virtual address of level 0 texels (64-bit GPU VA) */
	uint16_t width;                 /* 0x08: Texel width (1..MAX_TEX_EXTENT) */
	uint16_t height;                /* 0x0A: Texel height (1..MAX_TEX_EXTENT; 1 for 1D) */
	uint16_t depth;                 /* 0x0C: 1D/2D ARRAY=0: 1; ARRAY=1: layers; 3D: depth; Cube: 6 (ARRAY=0) or 6*cubes (ARRAY=1) */
	uint8_t  format;                /* 0x0E: GhciFormat ID (encoding sRGB/UNORM/INT/FLOAT directly) */
	uint8_t  mip_levels;            /* 0x0F: Number of mip levels (1..Word27[3:0] MAX_MIP_LEVELS) */
	uint32_t row_pitch_bytes;       /* 0x10: Level 0 row pitch in bytes */
	uint32_t slice_pitch_bytes;     /* 0x14: 2D/Cube array layer or 3D slice pitch in bytes */
	uint8_t  sample_count;          /* 0x18: MSAA sample count (1, 2, 4) */
	uint8_t  dimension;             /* 0x19: 0=1D, 1=2D, 2=3D, 3=Cube (GHCI_TEX_DIM_*) */
	uint16_t flags;                 /* 0x1A: [0]=TILED, [2]=STENCIL_ASPECT, [4:3]=ROW_ALIGN_LOG2, [5]=ARRAY (no SRGB bit) */
	uint32_t component_swizzle;     /* 0x1C: [2:0] R, [5:3] G, [8:6] B, [11:9] A, [31:12] reserved (0) */
} GhciTextureDescriptor;

/* Sampler Descriptor (16 Bytes, N23, N61) */
typedef struct GhciSamplerDescriptor {
	uint8_t  min_filter;            /* 0x00: 0=Nearest, 1=Linear */
	uint8_t  mag_filter;            /* 0x01: 0=Nearest, 1=Linear */
	uint8_t  mipmap_mode;           /* 0x02: 0=Nearest, 1=Linear */
	uint8_t  address_mode_u;        /* 0x03: 0=Repeat, 1=Mirrored, 2=ClampToEdge, 3=ClampBorder, 4=MirrorClampToEdge */
	uint8_t  address_mode_v;        /* 0x04: Address mode V */
	uint8_t  address_mode_w;        /* 0x05: Address mode W */
	uint8_t  compare_enable;        /* 0x06: 1=Depth compare active */
	uint8_t  compare_op;            /* 0x07: VkCompareOp: 0=NEVER, 1=LESS, 2=EQUAL, 3=LEQUAL, 4=GREATER, 5=NOTEQUAL, 6=GEQUAL, 7=ALWAYS (N23) */
	int16_t  lod_bias_fx8;          /* 0x08: Fixed-point 8.8 LOD bias */
	uint8_t  min_lod_fx4;           /* 0x0A: Fixed-point 4.4 min LOD */
	uint8_t  max_lod_fx4;           /* 0x0B: Fixed-point 4.4 max LOD */
	uint8_t  max_anisotropy;        /* 0x0C: Max anisotropy (1..16) (N23) */
	uint8_t  border_color_type;     /* 0x0D: 0=TransBlack, 1=OpaqueBlack, 2=OpaqueWhite, 3=Custom (N23) */
	uint8_t  border_color_idx;      /* 0x0E: Custom 128-bit border color table index (0..15) (N23) */
	uint8_t  unnormalized_coords;   /* 0x0F: [0] unnormalized_coordinates (0: norm [0,1], 1: unnorm [0,dim]), [7:1] res (N61) */
} GhciSamplerDescriptor;

/*
 * ============================================================================
 * Structured Command Packet Binary Layouts
 * ============================================================================
 */

/* CMD_BIND_PIPELINE (0x20): 3 dwords */
typedef struct GhciCmdBindPipeline {
	uint32_t header;                /* GHCI_CMD_BIND_PIPELINE, size = 3 */
	uint32_t pso_gpu_va_lo;
	uint32_t pso_gpu_va_hi;
} GhciCmdBindPipeline;

/* CMD_BIND_INDEX_BUFFER (0x22): 4 dwords */
typedef struct GhciCmdBindIndexBuffer {
	uint32_t header;                /* GHCI_CMD_BIND_INDEX_BUFFER, size = 4 */
	uint32_t buffer_va_lo;
	uint32_t buffer_va_hi;
	uint16_t index_type;            /* 0 = UINT16, 1 = UINT32 */
	uint16_t reserved;
} GhciCmdBindIndexBuffer;

/* CMD_BIND_DESCRIPTOR_TABLE (0x23): 4 dwords */
#define GHCI_MAX_DESCRIPTOR_SETS        8u
#define GHCI_BIND_DESC_FLAG_BIND_POINT  (1u << 0) /* 0 = Graphics, 1 = Compute */
#define GHCI_BIND_DESC_FLAG_INVAL_CACHE (1u << 1) /* 1 = Invalidate TU descriptor cache before subsequent draws/dispatches */
#define GHCI_BIND_DESC_FLAG_TABLE_KIND  (1u << 2) /* 0 = Texture table (32B entries), 1 = Sampler table (16B entries) */

typedef struct GhciCmdBindDescriptorTable {
	uint32_t header;                /* GHCI_CMD_BIND_DESCRIPTOR_TABLE, dwords = 4, flags = GHCI_BIND_DESC_FLAG_* */
	uint32_t table_va_lo;           /* 64-bit session GPU VA [31:0] (32B aligned if TABLE_KIND==0, 16B if 1; 0 unbinds) */
	uint32_t table_va_hi;           /* 64-bit session GPU VA [63:32] */
	uint16_t set_index;             /* Descriptor set binding slot (0..7) */
	uint16_t table_size_16b;        /* Table byte length divided by 16 (0 when unbinding) */
} GhciCmdBindDescriptorTable;

/* CMD_SET_VIEWPORT (0x24): 7 dwords */
typedef struct GhciCmdSetViewport {
	uint32_t header;                /* GHCI_CMD_SET_VIEWPORT, size = 7 */
	float    x;
	float    y;
	float    width;
	float    height;
	float    min_depth;
	float    max_depth;
} GhciCmdSetViewport;

/* CMD_SET_SCISSOR (0x25): 5 dwords */
typedef struct GhciCmdSetScissor {
	uint32_t header;                /* GHCI_CMD_SET_SCISSOR, size = 5 */
	int32_t  x;
	int32_t  y;
	uint32_t width;
	uint32_t height;
} GhciCmdSetScissor;

/* CMD_SET_DYNAMIC_STATE (0x26): 6 dwords (N14, N23) */
#define GHCI_DYNAMIC_STATE_DEPTH_BIAS        0x01u
#define GHCI_DYNAMIC_STATE_BLEND_CONSTANTS   0x02u
#define GHCI_DYNAMIC_STATE_STENCIL_PARAMS    0x03u
#define GHCI_DYNAMIC_STATE_LINE_WIDTH        0x04u
#define GHCI_DYNAMIC_STATE_BORDER_COLOR_TABLE 0x10u

#define GHCI_STRIDE_FROM_PSO                 0xFFFFFFFFu

typedef struct GhciCmdSetDynamicState {
	uint32_t header;                /* GHCI_CMD_SET_DYNAMIC_STATE, size = 6 */
	uint32_t state_id;              /* GHCI_DYNAMIC_STATE_* */
	union {
		struct {
			float    constant_factor;
			float    slope_factor;
			float    clamp;
			uint32_t reserved;
		} depth_bias;
		struct {
			float    rgba[4];
		} blend_constants;
		struct {
			uint32_t front;         /* [7:0] compare_mask, [15:8] write_mask, [23:16] ref */
			uint32_t back;          /* [7:0] compare_mask, [15:8] write_mask, [23:16] ref */
			uint32_t reserved[2];
		} stencil_params;
		struct {
			float    line_width;
			uint32_t reserved[3];
		} line_width;
		struct {
			uint32_t table_va_lo;   /* 64-bit GPU virtual address [31:0] */
			uint32_t table_va_hi;   /* 64-bit GPU virtual address [63:32] */
			uint32_t reserved[2];
		} border_color_table;
		uint32_t raw_payload[4];
	} data;
} GhciCmdSetDynamicState;

/* CMD_DRAW (0x27): 5 dwords */
typedef struct GhciCmdDraw {
	uint32_t header;                /* GHCI_CMD_DRAW, size = 5 */
	uint32_t vertex_count;
	uint32_t instance_count;
	uint32_t first_vertex;
	uint32_t first_instance;
} GhciCmdDraw;

/* CMD_DRAW_INDEXED (0x28): 6 dwords */
typedef struct GhciCmdDrawIndexed {
	uint32_t header;                /* GHCI_CMD_DRAW_INDEXED, size = 6 */
	uint32_t index_count;
	uint32_t instance_count;
	uint32_t first_index;
	int32_t  vertex_offset;
	uint32_t first_instance;
} GhciCmdDrawIndexed;

/* CMD_DRAW_INDIRECT (0x29): 7 dwords (normal) or 8 dwords (count buffer, header.flags[1] = 1) */
#define GHCI_DRAW_INDIRECT_HDR_FLAG_INDEXED      (1u << 0) /* Packet header.flags[0]: 1 = Indexed indirect arguments */
#define GHCI_DRAW_INDIRECT_HDR_FLAG_COUNT_BUFFER (1u << 1) /* Packet header.flags[1]: 1 = 8-dword form reading count from count_buffer_va */

typedef struct GhciCmdDrawIndirect {
	uint32_t header;                /* GHCI_CMD_DRAW_INDIRECT, size = 7, flags = 0 or INDEXED */
	uint32_t buffer_va_lo;          /* GPU virtual address of draw args [31:0] */
	uint32_t buffer_va_hi;          /* GPU virtual address of draw args [63:32] */
	uint32_t offset_bytes;          /* Byte offset inside buffer */
	uint32_t draw_count;            /* Direct draw count */
	uint32_t stride_bytes;          /* Stride in bytes between draw arguments */
	uint32_t reserved;              /* Must be 0 */
} GhciCmdDrawIndirect;

typedef struct GhciCmdDrawIndirectCount {
	uint32_t header;                /* GHCI_CMD_DRAW_INDIRECT, size = 8, flags |= GHCI_DRAW_INDIRECT_HDR_FLAG_COUNT_BUFFER */
	uint32_t buffer_va_lo;          /* GPU virtual address of draw args [31:0] */
	uint32_t buffer_va_hi;          /* GPU virtual address of draw args [63:32] */
	uint32_t offset_bytes;          /* Byte offset inside buffer */
	uint32_t max_draw_count;        /* Maximum draw count cap */
	uint32_t stride_bytes;          /* Stride in bytes between draw arguments */
	uint32_t count_buffer_va_lo;    /* GPU virtual address of draw count uint32 [31:0] */
	uint32_t count_buffer_va_hi;    /* GPU virtual address of draw count uint32 [63:32] */
} GhciCmdDrawIndirectCount;

/* CMD_DRAW_MESH_TASKS (0x2A): 4 dwords */
typedef struct GhciCmdDrawMeshTasks {
	uint32_t header;                /* GHCI_CMD_DRAW_MESH_TASKS, size = 4 */
	uint32_t group_count_x;
	uint32_t group_count_y;
	uint32_t group_count_z;
} GhciCmdDrawMeshTasks;

/* CMD_DISPATCH (0x30): 4 dwords */
typedef struct GhciCmdDispatch {
	uint32_t header;                /* GHCI_CMD_DISPATCH, size = 4 */
	uint32_t group_count_x;
	uint32_t group_count_y;
	uint32_t group_count_z;
} GhciCmdDispatch;

/* CMD_BARRIER (0x31): 4 dwords */
#define GHCI_STAGE_VF                   (1u << 0)
#define GHCI_STAGE_VS                   (1u << 1)
#define GHCI_STAGE_FS                   (1u << 2)
#define GHCI_STAGE_CS                   (1u << 3)
#define GHCI_STAGE_ROP                  (1u << 4)
#define GHCI_STAGE_BLT                  (1u << 5)
#define GHCI_STAGE_TCS                  (1u << 6)
#define GHCI_STAGE_TES                  (1u << 7)
#define GHCI_STAGE_GS                   (1u << 8)
#define GHCI_STAGE_TS                   (1u << 9)
#define GHCI_STAGE_MS                   (1u << 10)

#define GHCI_BARRIER_FLAG_WAIT_IDLE        (1u << 0)
#define GHCI_BARRIER_FLAG_INVAL_ICACHE     (1u << 1)
#define GHCI_BARRIER_FLAG_INVAL_TEX        (1u << 2)
#define GHCI_BARRIER_FLAG_FLUSH_L1_DATA    (1u << 3)
#define GHCI_BARRIER_FLAG_INVAL_L1_DATA    (1u << 4)
#define GHCI_BARRIER_FLAG_INVAL_DESCRIPTOR (1u << 5)
#define GHCI_BARRIER_FLAG_FLUSH_L2         (1u << 6)

typedef struct GhciCmdBarrier {
	uint32_t header;                /* GHCI_CMD_BARRIER, size = 4 */
	uint32_t src_stage_mask;
	uint32_t dst_stage_mask;
	uint32_t flags;                 /* GHCI_BARRIER_FLAG_* */
} GhciCmdBarrier;

/* CMD_EXECUTE_COMMANDS (0x32): 4 dwords (UMA Secondary Buffer Fetch) */
typedef struct GhciCmdExecuteCommands {
	uint32_t header;                /* GHCI_CMD_EXECUTE_COMMANDS, size = 4 */
	uint32_t secondary_ring_va_lo;
	uint32_t secondary_ring_va_hi;
	uint32_t command_dwords;
} GhciCmdExecuteCommands;

/* CMD_FENCE (0x33): 6 dwords (24 bytes, J13, N11, N32) */
#define GHCI_FENCE_FLAG_IRQ             (1u << 0)
#define GHCI_FENCE_FLAG_MEM_WRITE       (1u << 1)
#define GHCI_FENCE_FLAG_HOST_FLUSH      (1u << 2)

typedef struct GhciCmdFence {
	uint32_t header;                /* GHCI_CMD_FENCE, size = 6 */
	uint32_t fence_addr_lo;         /* 64-bit host DMA address or local DRAM PA [31:0] */
	uint32_t fence_addr_hi;         /* 64-bit host DMA address or local DRAM PA [63:32] */
	uint32_t fence_seq_lo;          /* 64-bit fence sequence value [31:0] */
	uint32_t fence_seq_hi;          /* 64-bit fence sequence value [63:32] */
	uint32_t flags;                 /* GHCI_FENCE_FLAG_* */
} GhciCmdFence;

/* CMD_BEGIN_QUERY (0x36) / CMD_END_QUERY (0x37): 4 dwords (J18, N17, N32) */
typedef struct GhciCmdQuery {
	uint32_t header;                /* GHCI_CMD_BEGIN_QUERY / END_QUERY, size = 4 */
	uint32_t query_pool_va_lo;      /* 64-bit session GPU VA [31:0] */
	uint32_t query_pool_va_hi;      /* 64-bit session GPU VA [63:32] */
	uint32_t query_index_and_flags; /* [23:0] query_index, [24] PRECISE, [25] AVAILABILITY */
} GhciCmdQuery;

/*
 * ============================================================================
 * Virtual Memory, MMU Bringup & Fault Log Commands (0x10..0x18)
 * ============================================================================
 */
#define GHCI_VM_FLAG_READ       (1u << 0)
#define GHCI_VM_FLAG_WRITE      (1u << 1)
#define GHCI_VM_FLAG_EXEC       (1u << 2)
#define GHCI_VM_FLAG_COHERENT   (1u << 3)
#define GHCI_VM_FLAG_WC         (1u << 4)
#define GHCI_VM_FLAG_LOCAL      (1u << 5) /* 1 = Local VRAM, 0 = Host PCIe / IOVA */

/* GhciVmPtMemInfo (64 bytes, 64-byte aligned, output of CMD_VM_QUERY_PT_MEM) */
typedef struct GhciVmPtMemInfo {
	uint32_t struct_bytes;          /* 0x00: 64 */
	uint32_t reserved0;             /* 0x04: 0 */
	uint32_t init_pt_bytes;         /* 0x08: Required bytes for initial session page table */
	uint32_t init_pt_align;         /* 0x0C: Required alignment (power of 2) for initial page table */
	uint32_t table_page_bytes;      /* 0x10: Bytes per intermediate page table unit */
	uint32_t table_page_align;      /* 0x14: Required alignment (power of 2) per intermediate unit */
	uint32_t reserved1;             /* 0x18: 0 */
	uint32_t reserved2;             /* 0x1C: 0 */
	uint32_t reserved[8];           /* 0x20..0x3F: 0 */
} GhciVmPtMemInfo;

/* CMD_VM_QUERY_PT_MEM (0x17): 5 dwords (20 bytes, primary ring only) */
typedef struct GhciCmdVmQueryPtMem {
	uint32_t header;                /* opcode: GHCI_CMD_VM_QUERY_PT_MEM, dwords: 5, flags: 0 */
	uint32_t dst_pa_lo;             /* Destination GhciVmPtMemInfo PA / IOVA [31:0] (64B aligned) */
	uint32_t dst_pa_hi;             /* Destination GhciVmPtMemInfo PA / IOVA [63:32] */
	uint32_t dst_bytes;             /* Buffer length (>= 64 and multiple of 64) */
	uint32_t reserved;              /* 0 */
} GhciCmdVmQueryPtMem;

/* CMD_MMU_ENABLE (0x18): 6 dwords (24 bytes, primary ring only) */
typedef struct GhciCmdMmuEnable {
	uint32_t header;                /* opcode: GHCI_CMD_MMU_ENABLE, dwords: 6, flags: 0 */
	uint32_t flags;                 /* Reserved (0) */
	uint32_t init_pt_pa_lo;         /* Session 0 initial PT PA [31:0] (init_pt_align aligned) */
	uint32_t init_pt_pa_hi;         /* Session 0 initial PT PA [63:32] */
	uint32_t init_pt_bytes;         /* Allocated bytes (>= info.init_pt_bytes) */
	uint32_t reserved;              /* 0 */
} GhciCmdMmuEnable;

/* GhciVmMapComp.status values */
#define GHCI_VM_MAP_OK              0u
#define GHCI_VM_MAP_NEED_PT_MEM     1u
#define GHCI_VM_MAP_COLLISION       2u
#define GHCI_VM_MAP_INVALID_SESSION 3u

/* GhciVmMapComp (32 bytes, 32-byte aligned, written by CMD_VM_MAP) */
typedef struct GhciVmMapComp {
	uint32_t status;                /* 0=OK, 1=NEED_PT_MEM, 2=COLLISION, 3=INVALID_SESSION */
	uint32_t used_bytes;            /* Bytes consumed from pt_mem (0 if none needed or error) */
	uint32_t required_bytes;        /* Minimum bytes needed when status == NEED_PT_MEM, else 0 */
	uint32_t required_align;        /* Required alignment when status == NEED_PT_MEM, else 0 */
	uint32_t reserved[4];           /* 0 */
} GhciVmMapComp;

/* CMD_VM_MAP (0x10): 16 dwords (64 bytes, primary ring only) */
typedef struct GhciCmdVmMap {
	uint32_t header;                /* opcode: GHCI_CMD_VM_MAP, dwords: 16, flags: 0 */
	uint32_t session_id;            /* Target session identifier (0..15) */
	uint32_t flags;                 /* [5:0] GHCI_VM_FLAG_*, [31:6] reserved (0) */
	uint32_t reserved0;             /* 0 */
	uint32_t gpu_va_lo;             /* GPU virtual address (4 KiB aligned) [31:0] */
	uint32_t gpu_va_hi;             /* GPU virtual address [63:32] */
	uint32_t phys_lo;               /* Backing PA / IOVA [31:0] */
	uint32_t phys_hi;               /* Backing PA / IOVA [63:32] */
	uint32_t size_lo;               /* Mapping size in bytes (4 KiB multiple, > 0) [31:0] */
	uint32_t size_hi;               /* Mapping size in bytes [63:32] */
	uint32_t pt_mem_pa_lo;          /* Intermediate PT memory PA [31:0] (ignored if pt_mem_bytes == 0) */
	uint32_t pt_mem_pa_hi;          /* Intermediate PT memory PA [63:32] */
	uint32_t pt_mem_bytes;          /* 0 or integer multiple of table_page_bytes */
	uint32_t reserved1;             /* 0 */
	uint32_t comp_pa_lo;            /* 32-byte GhciVmMapComp host PA / IOVA [31:0] (32B aligned) */
	uint32_t comp_pa_hi;            /* 32-byte GhciVmMapComp host PA / IOVA [63:32] */
} GhciCmdVmMap;

/* GhciVmUnmapComp.status values */
#define GHCI_VM_UNMAP_OK              0u
#define GHCI_VM_UNMAP_NEED_BUF        1u
#define GHCI_VM_UNMAP_INVALID_SESSION 2u

/* GhciVmUnmapEntry (16 bytes) */
typedef struct GhciVmUnmapEntry {
	uint64_t pa;                    /* Physical address of freed intermediate PT page */
	uint32_t bytes;                 /* Size in bytes (typically table_page_bytes) */
	uint32_t reserved;              /* 0 */
} GhciVmUnmapEntry;

/* GhciVmUnmapComp (16-byte header + entries[], minimum 64 bytes, 64-byte aligned) */
typedef struct GhciVmUnmapComp {
	uint32_t status;                /* 0=OK, 1=NEED_BUF, 2=INVALID_SESSION */
	uint32_t freed_count;           /* Total freed intermediate pages */
	uint32_t written_count;         /* Number of entries written into entries[] */
	uint32_t required_bytes;        /* Required comp_bytes when status == NEED_BUF */
	GhciVmUnmapEntry entries[];     /* Up to (comp_bytes - 16) / 16 entries */
} GhciVmUnmapComp;

/* CMD_VM_UNMAP (0x11): 12 dwords (48 bytes, primary ring only) */
typedef struct GhciCmdVmUnmap {
	uint32_t header;                /* opcode: GHCI_CMD_VM_UNMAP, dwords: 12, flags: 0 */
	uint32_t session_id;            /* Target session identifier (0..15) */
	uint32_t flags;                 /* Reserved (0) */
	uint32_t reserved0;             /* 0 */
	uint32_t gpu_va_lo;             /* GPU virtual address (4 KiB aligned) [31:0] */
	uint32_t gpu_va_hi;             /* GPU virtual address [63:32] */
	uint32_t size_lo;               /* Unmap size in bytes (4 KiB multiple, > 0) [31:0] */
	uint32_t size_hi;               /* Unmap size in bytes [63:32] */
	uint32_t comp_pa_lo;            /* GhciVmUnmapComp host PA / IOVA [31:0] (64B aligned) */
	uint32_t comp_pa_hi;            /* GhciVmUnmapComp host PA / IOVA [63:32] */
	uint32_t comp_bytes;            /* Buffer size (>= 64 and multiple of 64) */
	uint32_t reserved1;             /* 0 */
} GhciCmdVmUnmap;

#define GHCI_SESSION_FLAG_PROTECTED (1u << 0)

/* CMD_SESSION_OPEN (0x12): 6 dwords (24 bytes, primary ring only) */
typedef struct GhciCmdSessionOpen {
	uint32_t header;                /* opcode: GHCI_CMD_SESSION_OPEN, dwords: 6, flags: 0 */
	uint32_t session_id;            /* Client session identifier (1..15) */
	uint32_t flags;                 /* [0] PROTECTED, [31:1] reserved (0) */
	uint32_t init_pt_pa_lo;         /* Session initial PT PA [31:0] (ignored if CAP_BOOT_PROT == 0) */
	uint32_t init_pt_pa_hi;         /* Session initial PT PA [63:32] */
	uint32_t init_pt_bytes;         /* Allocated bytes (>= info.init_pt_bytes when CAP_BOOT_PROT == 1) */
} GhciCmdSessionOpen;

/* CMD_SESSION_CLOSE (0x13): 2 dwords (8 bytes) */
typedef struct GhciCmdSessionClose {
	uint32_t header;                /* opcode: GHCI_CMD_SESSION_CLOSE, dwords: 2 */
	uint32_t session_id;            /* Client session identifier to destroy and flush */
} GhciCmdSessionClose;

/* CMD_BIND_SESSION (0x14): 2 dwords (8 bytes) */
typedef struct GhciCmdBindSession {
	uint32_t header;                /* opcode: GHCI_CMD_BIND_SESSION, dwords: 2 */
	uint32_t session_id;            /* Session identifier (0..15) for subsequent commands */
} GhciCmdBindSession;

/* CMD_FAULT_LOG_SETUP (0x16): 7 dwords (28 bytes, primary ring only) */
#define GHCI_FAULT_LOG_FLAG_ENABLE     (1u << 0)
#define GHCI_FAULT_LOG_FLAG_COMP_WRITE (1u << 8)

typedef struct GhciCmdFaultLogSetup {
	uint32_t header;                /* opcode: GHCI_CMD_FAULT_LOG_SETUP, dwords: 7, flags: [0] ENABLE, [8] COMP_WRITE */
	uint32_t ring_pa_lo;            /* 32B-aligned fault ring host PA / IOVA [31:0] */
	uint32_t ring_pa_hi;            /* 32B-aligned fault ring host PA / IOVA [63:32] */
	uint32_t capacity_entries;      /* Power of 2 >= 2 when ENABLE == 1; 0 when ENABLE == 0 */
	uint32_t reserved;              /* 0 */
	uint32_t comp_pa_lo;            /* 8B-aligned next_seq writeback host PA [31:0] */
	uint32_t comp_pa_hi;            /* 8B-aligned next_seq writeback host PA [63:32] */
} GhciCmdFaultLogSetup;

/* GhciFaultRecord (32 bytes, 32-byte aligned) */
typedef struct GhciFaultRecord {
	uint64_t seq;                   /* 0x00: 1-based monotonic fault sequence number */
	uint64_t fault_addr;            /* 0x08: 64-bit faulting GPU VA, bus PA, or shader PC */
	uint64_t timestamp;             /* 0x10: Constant-rate TIMESTAMP value */
	uint32_t session_id;            /* 0x18: Client session ID (1..15) */
	uint32_t fault_info_word;       /* 0x1C: Same bit layout as MMIO FAULT_INFO */
} GhciFaultRecord;

/* CMD_QUERY_CAPS (0x15): 5 dwords (20 bytes, primary ring only) */
typedef struct GhciCmdQueryCaps {
	uint32_t header;                /* opcode: GHCI_CMD_QUERY_CAPS, dwords: 5, flags: 0 */
	uint32_t dst_pa_lo;             /* host physical / IOVA destination [31:0], 64B-aligned */
	uint32_t dst_pa_hi;             /* host physical / IOVA destination [63:32] */
	uint32_t dst_bytes;             /* destination buffer size in bytes (>= 64 and multiple of 64) */
	uint32_t reserved;              /* must be 0 */
} GhciCmdQueryCaps;

/*
 * ============================================================================
 * Buffer Descriptor (16 Bytes)
 * ============================================================================
 */
typedef struct GhciBufferDescriptor {
	uint32_t base_address_lo;       /* 64-bit GPU VA base [31:0] */
	uint32_t base_address_hi;       /* 64-bit GPU VA base [63:32] */
	uint32_t size_bytes;            /* Buffer size in bytes */
	uint16_t stride_bytes;          /* Element stride for texel buffer; 0 for raw/uniform */
	uint8_t  format;                /* GhciFormat ID for texel buffer; 0 for storage/uniform */
	uint8_t  flags;                 /* [0] ReadOnly, [1] Coherent */
} GhciBufferDescriptor;

/*
 * ============================================================================
 * Additional Command Packet Definitions
 * ============================================================================
 */

/*
 * In-Memory Render Pass Descriptor (GhciRenderPassDesc) - 192 Bytes (64-byte aligned, K12, N03, N47)
 * Pointed to by CMD_BEGIN_RENDER_PASS via render_pass_desc_va.
 * Attachments are strictly linear row layout (64-byte aligned row_pitch_bytes).
 * image_va points directly to the subresource slice base. mip_level and base_array_layer
 * must be 0 (reserved). layers must be 1.
 */
typedef struct GhciColorAttachmentDesc {
	uint64_t image_va;              /* 0x00: Color attachment GPU virtual address of subresource slice (64-bit GPU VA) */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes (64-byte aligned, linear layout) */
	uint8_t  format;                /* 0x0C: GhciFormat ID (e.g. GHCI_FMT_R8G8B8A8_UNORM = 0x20) */
	uint8_t  ops;                   /* 0x0D: [1:0] LoadOp (0: Load, 1: Clear, 2: DontCare), [3:2] StoreOp (0: Store, 1: DontCare) */
	uint8_t  mip_level;             /* 0x0E: Reserved (must be 0) */
	uint8_t  base_array_layer;      /* 0x0F: Reserved (must be 0) */
} GhciColorAttachmentDesc;

typedef struct GhciDepthStencilAttachmentDesc {
	uint64_t depth_stencil_va;      /* 0x00: Depth/stencil GPU virtual address of subresource slice */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes (64-byte aligned, linear layout) */
	uint8_t  format;                /* 0x0C: Depth/stencil GhciFormat (D16=0x70, D32F=0x72, D24S8=0x74) */
	uint8_t  ops;                   /* 0x0D: [1:0] DepthLoad, [3:2] DepthStore, [5:4] StencilLoad, [7:6] StencilStore */
	uint8_t  mip_level;             /* 0x0E: Reserved (must be 0) */
	uint8_t  base_array_layer;      /* 0x0F: Reserved (must be 0) */
} GhciDepthStencilAttachmentDesc;

typedef struct GhciResolveAttachmentDesc {
	uint64_t resolve_va;            /* 0x00: Multisample resolve target GPU virtual address of subresource slice */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes (64-byte aligned, linear layout) */
	uint8_t  format;                /* 0x0C: Resolve destination GhciFormat */
	uint8_t  mode;                  /* 0x0D: [1:0] ResolveMode (0: Average, 1: Min, 2: Max, 3: Sample Zero) */
	uint8_t  mip_level;             /* 0x0E: Reserved (must be 0) */
	uint8_t  base_array_layer;      /* 0x0F: Reserved (must be 0) */
} GhciResolveAttachmentDesc;

typedef struct GhciRenderPassDesc {
	/* 0x00 - 0x7F: 8 Color Attachments (16 bytes each = 128 bytes total) */
	GhciColorAttachmentDesc colors[8];
	/* 0x80 - 0x8F: Depth/Stencil Attachment (16 bytes) */
	GhciDepthStencilAttachmentDesc depth_stencil;
	/* 0x90 - 0x9F: Multisample Resolve Attachment (16 bytes) */
	GhciResolveAttachmentDesc resolve;
	/* 0xA0 - 0xBF: Framebuffer Dimensions & Sample/Clear Config (32 bytes) */
	uint16_t width;                 /* 0xA0: Framebuffer width in pixels (1..16384) */
	uint16_t height;                /* 0xA2: Framebuffer height in pixels (1..16384) */
	uint16_t layers;                /* 0xA4: Array layer count (must be 1 in GHCI 1.0, N47) */
	uint8_t  samples;               /* 0xA6: Sample count: 1, 2, or 4 (MSAA) */
	uint8_t  reserved0;             /* 0xA7: Reserved */
	uint64_t clear_color_table_va;  /* 0xA8: 64-bit GPU VA to 8 x 16-byte VkClearColorValue table (128 bytes total); 0 = default */
	uint64_t reserved1;             /* 0xB0: Reserved */
	uint64_t reserved2;             /* 0xB8: Reserved (total struct size = 192 bytes, 64-byte aligned) */
} GhciRenderPassDesc;

/* CMD_BEGIN_RENDER_PASS (0x2B): 10 dwords (K12) */
typedef struct GhciCmdBeginRenderPass {
	uint32_t header;                /* opcode: GHCI_CMD_BEGIN_RENDER_PASS, dwords: 10 */
	uint32_t render_pass_desc_va_lo;/* 64-bit GPU virtual address of GhciRenderPassDesc [31:0] */
	uint32_t render_pass_desc_va_hi;/* 64-bit GPU virtual address of GhciRenderPassDesc [63:32] */
	uint32_t render_area_offset;    /* [15:0] X, [31:16] Y */
	uint32_t render_area_extent;    /* [15:0] Width, [31:16] Height */
	uint32_t color_clear_rgba;      /* Packed RGBA8 or float clear color for attachment 0 */
	uint32_t depth_clear_value;     /* 32-bit float or 24-bit depth clear */
	uint32_t stencil_clear_value;   /* [7:0] Stencil clear value */
	uint32_t flags;                 /* dw8: [7:0] clear_color (attachments 0..7), [8] clear_depth, [9] clear_stencil, [16] inline_secondary (N03, N32) */
	uint32_t reserved;              /* Reserved padding to 10 dwords */
} GhciCmdBeginRenderPass;

/* CMD_END_RENDER_PASS (0x2C): 1 dword */
typedef struct GhciCmdEndRenderPass {
	uint32_t header;                /* opcode: GHCI_CMD_END_RENDER_PASS, dwords: 1 */
} GhciCmdEndRenderPass;

/* CMD_LOAD_CONST (0x2D): 3 + N dwords */
typedef struct GhciCmdLoadConst {
	uint32_t header;                /* opcode: GHCI_CMD_LOAD_CONST, dwords: 3 + count */
	uint32_t offset_dwords;         /* Start offset in constant bank (0..511) */
	uint32_t count_dwords;          /* Number of constant dwords to load (1..32) */
	/* Followed by uint32_t data[count_dwords] */
} GhciCmdLoadConst;

/* CMD_WAIT_FENCE (0x34): 5 dwords (64-bit wait value, K09, N11, N12) */
typedef struct GhciCmdWaitFence {
	uint32_t header;                /* opcode: GHCI_CMD_WAIT_FENCE, dwords: 5 */
	uint32_t fence_addr_lo;         /* 64-bit host DMA address or local DRAM PA [31:0] (N12) */
	uint32_t fence_addr_hi;         /* 64-bit host DMA address or local DRAM PA [63:32] (N12) */
	uint32_t wait_value_lo;         /* 64-bit value to compare [31:0] */
	uint32_t wait_value_hi;         /* 64-bit value to compare [63:32] ((int64_t)(mem - val) >= 0) */
} GhciCmdWaitFence;

/* CMD_WRITE_TIMESTAMP (0x35): 4 dwords */
#define GHCI_TIMESTAMP_FLAG_HOST_PA    (1u << 0) /* 1 = host PA (primary ring only), 0 = session GPU VA */
#define GHCI_TIMESTAMP_STAGE_TOP       0u
#define GHCI_TIMESTAMP_STAGE_POST_RASTER 1u
#define GHCI_TIMESTAMP_STAGE_BOTTOM    2u

typedef struct GhciCmdWriteTimestamp {
	uint32_t header;                /* opcode: GHCI_CMD_WRITE_TIMESTAMP, dwords: 4, flags: [0] HOST_PA */
	uint32_t dst_addr_lo;           /* 64-bit GPU VA or host PA [31:0] (8-byte aligned) */
	uint32_t dst_addr_hi;           /* 64-bit address [63:32] */
	uint32_t pipeline_stage;        /* 0=TOP, 1=POST_RASTER, 2=BOTTOM */
} GhciCmdWriteTimestamp;

/* CMD_COPY_BUFFER (0x40): 8 dwords (N13) */
#define GHCI_COPY_BUFFER_FLAG_ASYNC        (1u << 0)
#define GHCI_COPY_BUFFER_FLAG_FILL_PATTERN (1u << 1)
#define GHCI_COPY_BUFFER_FLAG_FLUSH_SRC    (1u << 2)
#define GHCI_COPY_BUFFER_FLAG_FLUSH_DST    (1u << 3)

typedef struct GhciCmdCopyBuffer {
	uint32_t header;                /* opcode: GHCI_CMD_COPY_BUFFER, dwords: 8 */
	uint32_t src_va_lo;             /* Source GPU VA [31:0] */
	uint32_t src_va_hi;             /* Source GPU VA [63:32] */
	uint32_t dst_va_lo;             /* Destination GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination GPU VA [63:32] */
	uint32_t size_bytes;            /* Transfer size in bytes (4-byte aligned) */
	uint32_t flags;                 /* GHCI_COPY_BUFFER_FLAG_* */
	uint32_t fill_data;             /* 32-bit fill pattern (used when flags[1] == 1) */
} GhciCmdCopyBuffer;

/* CMD_COPY_IMAGE (0x41): 11 dwords (J18, N13) */
typedef struct GhciCmdCopyImage {
	uint32_t header;                /* opcode: GHCI_CMD_COPY_IMAGE, dwords: 11 */
	uint32_t src_va_lo;             /* Source slice GPU VA [31:0] */
	uint32_t src_va_hi;             /* Source slice GPU VA [63:32] */
	uint32_t dst_va_lo;             /* Destination slice GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination slice GPU VA [63:32] */
	uint32_t src_pitch;             /* Source surface row pitch in bytes */
	uint32_t dst_pitch;             /* Destination surface row pitch in bytes */
	uint32_t src_xy;                /* [15:0] src_x, [31:16] src_y */
	uint32_t dst_xy;                /* [15:0] dst_x, [31:16] dst_y */
	uint32_t extent;                /* [15:0] width, [31:16] height */
	uint32_t format_and_flags;      /* [7:0] format (GhciFormat), [8] src_tiled, [9] dst_tiled */
} GhciCmdCopyImage;

/* CMD_BLIT (0x42): 12 dwords (J18, N13) */
typedef struct GhciCmdBlit {
	uint32_t header;                /* opcode: GHCI_CMD_BLIT, dwords: 12 */
	uint32_t src_va_lo;             /* Source slice GPU VA [31:0] */
	uint32_t src_va_hi;             /* Source slice GPU VA [63:32] */
	uint32_t dst_va_lo;             /* Destination slice GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination slice GPU VA [63:32] */
	uint32_t src_pitch;             /* Source surface row pitch in bytes */
	uint32_t dst_pitch;             /* Destination surface row pitch in bytes */
	uint32_t src_min_xy;            /* [15:0] x0, [31:16] y0 */
	uint32_t src_max_xy;            /* [15:0] x1, [31:16] y1 */
	uint32_t dst_min_xy;            /* [15:0] x0, [31:16] y0 */
	uint32_t dst_max_xy;            /* [15:0] x1, [31:16] y1 */
	uint32_t formats_and_filter;    /* [7:0] src_format, [15:8] dst_format, [16] filter, [17] src_tiled, [18] dst_tiled */
} GhciCmdBlit;

/* CMD_FILL_BUFFER (0x43): 5 dwords */
typedef struct GhciCmdFillBuffer {
	uint32_t header;                /* opcode: GHCI_CMD_FILL_BUFFER, dwords: 5 */
	uint32_t dst_va_lo;             /* Destination GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination GPU VA [63:32] */
	uint32_t size_bytes;            /* Buffer size to fill in bytes (4-byte multiple) */
	uint32_t pattern_data;          /* 32-bit fill pattern */
} GhciCmdFillBuffer;

/* CMD_RESOLVE_IMAGE (0x44): 11 dwords (N13) */
typedef struct GhciCmdResolveImage {
	uint32_t header;                /* opcode: GHCI_CMD_RESOLVE_IMAGE, dwords: 11 */
	uint32_t src_va_lo;             /* Source multisample slice GPU VA [31:0] */
	uint32_t src_va_hi;             /* Source multisample slice GPU VA [63:32] */
	uint32_t dst_va_lo;             /* Destination 1x resolve slice GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination 1x resolve slice GPU VA [63:32] */
	uint32_t src_pitch;             /* Source surface row pitch in bytes */
	uint32_t dst_pitch;             /* Destination surface row pitch in bytes */
	uint32_t src_offset_xy;         /* [15:0] src_x, [31:16] src_y */
	uint32_t dst_offset_xy;         /* [15:0] dst_x, [31:16] dst_y */
	uint32_t extent_xy;             /* [15:0] width, [31:16] height */
	uint32_t params;                /* [7:0] format, [9:8] resolve_mode, [11:10] samples */
} GhciCmdResolveImage;

/* CMD_COPY_BUFFER_TO_IMAGE (0x45): 10 dwords (N13) */
typedef struct GhciCmdCopyBufferToImage {
	uint32_t header;                /* opcode: GHCI_CMD_COPY_BUFFER_TO_IMAGE, dwords: 10 */
	uint32_t src_buffer_va_lo;      /* Source linear buffer GPU VA [31:0] */
	uint32_t src_buffer_va_hi;      /* Source linear buffer GPU VA [63:32] */
	uint32_t dst_image_va_lo;       /* Destination tiled image slice GPU VA [31:0] */
	uint32_t dst_image_va_hi;       /* Destination tiled image slice GPU VA [63:32] */
	uint32_t buffer_row_pitch;      /* Buffer row pitch in bytes */
	uint32_t image_row_pitch;       /* Destination image row pitch in bytes */
	uint32_t image_offset_xy;       /* [15:0] dst_x, [31:16] dst_y */
	uint32_t image_extent_xy;       /* [15:0] width, [31:16] height */
	uint32_t format_and_flags;      /* [7:0] format (GhciFormat), [8] tiled */
} GhciCmdCopyBufferToImage;

/* CMD_COPY_IMAGE_TO_BUFFER (0x46): 10 dwords */
typedef struct GhciCmdCopyImageToBuffer {
	uint32_t header;                /* opcode: GHCI_CMD_COPY_IMAGE_TO_BUFFER, dwords: 10 */
	uint32_t src_image_va_lo;       /* Source tiled image slice GPU VA [31:0] */
	uint32_t src_image_va_hi;       /* Source tiled image slice GPU VA [63:32] */
	uint32_t dst_buffer_va_lo;      /* Destination linear buffer GPU VA [31:0] */
	uint32_t dst_buffer_va_hi;      /* Destination linear buffer GPU VA [63:32] */
	uint32_t image_row_pitch;       /* Source image row pitch in bytes */
	uint32_t buffer_row_pitch;      /* Buffer row pitch in bytes */
	uint32_t image_offset_xy;       /* [15:0] src_x, [31:16] src_y */
	uint32_t image_extent_xy;       /* [15:0] width, [31:16] height */
	uint32_t format_and_flags;      /* [7:0] format (GhciFormat), [8] tiled */
} GhciCmdCopyImageToBuffer;

/*
 * ============================================================================
 * Display Service Queue (DSQ), Packets & Structures (0x50..0x57, §13.2)
 * ============================================================================
 */
#define GHCI_DSQ_MIN_DEPTH                  8u
#define GHCI_DISP_MAX_I2C_TIMEOUT_MS        25u

/* Common header.flags for non-flip display commands (0x50, 0x52, 0x53, 0x55, 0x56, 0x57) */
#define GHCI_DISP_FLAG_COMP_WRITE           (1u << 8)
#define GHCI_DISP_FLAG_COMP_IRQ             (1u << 9)

/* 64-bit completion writeback encoding: comp_val | (cancel << 63) | (status << 56) */
#define GHCI_DISP_COMP_CANCEL_BIT           (1ULL << 63)
#define GHCI_DISP_COMP_STATUS_SHIFT         56u
#define GHCI_DISP_COMP_STATUS_MASK          0x7Fu
#define GHCI_DISP_COMP_STATUS_OK            0u
#define GHCI_DISP_COMP_STATUS_INVALID_STATE 1u

/* CMD_DISP_SET (0x50) header.flags[2:0] */
#define GHCI_DISP_SET_FLAG_ENABLE           (1u << 0)
#define GHCI_DISP_SET_FLAG_RESET            (1u << 1)
#define GHCI_DISP_SET_FLAG_TEST_PATTERN     (1u << 2)

/* CMD_DISP_SET_MODE (0x52) header.flags[0] */
#define GHCI_DISP_SET_MODE_FLAG_CHECK_ONLY  (1u << 0)

/* GhciDisplayModeDesc.flags */
#define GHCI_DISP_MODE_FLAG_HSYNC_POS       (1u << 0)
#define GHCI_DISP_MODE_FLAG_VSYNC_POS       (1u << 1)
#define GHCI_DISP_MODE_ID_ARBITRARY         0xFFFFFFFFu

/* GhciDisplayModeDesc.status */
#define GHCI_DISP_MODE_STATUS_OK            0u
#define GHCI_DISP_MODE_STATUS_UNSUPPORTED   1u
#define GHCI_DISP_MODE_STATUS_ENABLED       2u
#define GHCI_DISP_MODE_STATUS_INVALID_DESC  3u
#define GHCI_DISP_MODE_STATUS_CANCELLED     4u

/* Unified 64-byte Display Mode Descriptor (64-byte aligned) */
typedef struct GhciDisplayModeDesc {
	uint32_t struct_bytes;          /* 0x00: 64 */
	uint32_t pixel_clock_khz;       /* 0x04: Pixel clock (kHz, > 0) */
	uint16_t hactive;               /* 0x08: Horizontal active pixels */
	uint16_t hsync_start;           /* 0x0A: Horizontal sync start */
	uint16_t hsync_end;             /* 0x0C: Horizontal sync end */
	uint16_t htotal;                /* 0x0E: Horizontal total pixels */
	uint16_t vactive;               /* 0x10: Vertical active lines */
	uint16_t vsync_start;           /* 0x12: Vertical sync start */
	uint16_t vsync_end;             /* 0x14: Vertical sync end */
	uint16_t vtotal;                /* 0x16: Vertical total lines */
	uint32_t flags;                 /* 0x18: [0] HSYNC_POS, [1] VSYNC_POS, [31:2] reserved (0) */
	uint32_t status;                /* 0x1C: 0=OK, 1=UNSUPPORTED, 2=ENABLED, 3=INVALID_DESC, 4=CANCELLED */
	uint32_t actual_pclk_khz;       /* 0x20: Actual generated pixel clock (kHz) */
	uint32_t mode_id;               /* 0x24: Fixed mode index or 0xFFFFFFFF */
	uint32_t reserved[6];           /* 0x28..0x3F: 0 */
} GhciDisplayModeDesc;

/* GhciDisplayState.state_flags */
#define GHCI_DISP_STATE_ENABLE                  (1u << 0)
#define GHCI_DISP_STATE_TEST_PATTERN            (1u << 1)
#define GHCI_DISP_STATE_SCANOUT_ACTIVE          (1u << 2)
#define GHCI_DISP_STATE_CURSOR_VISIBLE          (1u << 3)
#define GHCI_DISP_STATE_CONNECTED               (1u << 4)
#define GHCI_DISP_STATE_UNDERFLOW               (1u << 5)
#define GHCI_DISP_STATE_PRIMARY_FLIP_PENDING    (1u << 6)
#define GHCI_DISP_STATE_CURSOR_FLIP_PENDING     (1u << 7)
#define GHCI_DISP_STATE_FLIP_RECORD_PENDING     (1u << 8)
#define GHCI_DISP_STATE_FLIP_RECORD_WRITE_ERROR (1u << 9)
#define GHCI_DISP_STATE_HAS_IMAGE               (1u << 10)
#define GHCI_DISP_STATE_HAS_CURSOR_IMAGE        (1u << 11)

/* GhciDisplayState.event_status */
#define GHCI_DISP_EVENT_RING_ENABLED            (1u << 0)

/* Unified 128-byte Display State Snapshot (64-byte aligned) */
typedef struct GhciDisplayState {
	uint32_t struct_bytes;          /* 0x00: 128 */
	uint16_t reserved0;             /* 0x04: 0 */
	uint16_t state_flags;           /* 0x06: GHCI_DISP_STATE_* */
	uint32_t display_id;            /* 0x08: Target display identifier */
	uint8_t  scanout_format;        /* 0x0C: Active / last-taken Plane 0 GhciFormat ID */
	uint8_t  dc_id;                 /* 0x0D: Non-normative diagnostic controller ID */
	uint16_t event_status;          /* 0x0E: [0] EVENT_RING_ENABLED */
	uint32_t frame_count;           /* 0x10: VSYNC frame counter */
	uint16_t current_line;          /* 0x14: Vertical scan line at snapshot_timestamp */
	uint16_t reserved1;             /* 0x16: 0 */
	uint32_t last_flip_cookie_primary; /* 0x18: Last completed/cancelled Primary flip value */
	uint32_t last_flip_cookie_cursor;  /* 0x1C: Last completed/cancelled Cursor flip value */
	uint64_t active_fb_base;        /* 0x20: 64-bit physical scanout base (0 if !HAS_IMAGE) */
	uint32_t active_fb_stride_bytes;/* 0x28: Line stride in bytes (0 if !HAS_IMAGE) */
	uint32_t cursor_pos;            /* 0x2C: [15:0] int16_t x, [31:16] int16_t y */
	uint64_t last_event_seq;        /* 0x30: Sequence number of last written event record */
	uint64_t snapshot_timestamp;    /* 0x38: Constant-rate TIMESTAMP when snapshot was taken */
	GhciDisplayModeDesc active_mode;/* 0x40..0x7F: Embedded 64-byte GhciDisplayModeDesc */
} GhciDisplayState;

/* CMD_DISP_QUERY_MODES (0x55) output header (16 bytes, followed by GhciDisplayModeDesc[]) */
typedef struct GhciDisplayModesHeader {
	uint32_t total_modes;           /* Total fixed modes supported by display */
	uint32_t returned_modes;        /* Number of GhciDisplayModeDesc records written */
	uint32_t reserved[2];           /* 0 */
} GhciDisplayModesHeader;

/* Display Event Ring Record (32 bytes, 32-byte aligned) */
#define GHCI_DISP_EVENT_VSYNC           1u
#define GHCI_DISP_EVENT_HOTPLUG         2u
#define GHCI_DISP_EVENT_UNDERFLOW       3u
#define GHCI_DISP_EVENT_DISP_ERROR      4u

#define GHCI_DISP_EVENT_MASK_VSYNC      (1u << 0)
#define GHCI_DISP_EVENT_MASK_HOTPLUG    (1u << 1)
#define GHCI_DISP_EVENT_MASK_UNDERFLOW  (1u << 2)
#define GHCI_DISP_EVENT_MASK_DISP_ERROR (1u << 3)

#define GHCI_DISP_ERR_SCANOUT_READ      1u
#define GHCI_DISP_ERR_FLIP_RECORD_WRITE 2u
#define GHCI_DISP_ERR_COMP_WRITE        3u

typedef struct GhciDisplayEventRecord {
	uint64_t seq;                   /* 0x00: 1-based monotonic event sequence number */
	uint64_t timestamp;             /* 0x08: Constant-rate TIMESTAMP value */
	uint32_t event_type;            /* 0x10: GHCI_DISP_EVENT_* */
	uint32_t display_id;            /* 0x14: Target display identifier */
	uint32_t frame_count;           /* 0x18: Frame count at event occurrence */
	uint32_t payload;               /* 0x1C: Event payload (HOTPLUG[0]=connected, DISP_ERROR=code) */
} GhciDisplayEventRecord;

/* CMD_DISP_I2C_XFER (0x57) flags and buffer header (4 bytes + payload) */
#define GHCI_DISP_I2C_FLAG_WRITE        (1u << 0)
#define GHCI_DISP_I2C_FLAG_HAS_OFFSET   (1u << 1)
#define GHCI_DISP_I2C_FLAG_HAS_SEG      (1u << 2)

#define GHCI_DISP_I2C_STATUS_OK         0u
#define GHCI_DISP_I2C_STATUS_NACK       1u
#define GHCI_DISP_I2C_STATUS_BUS_ERROR  2u
#define GHCI_DISP_I2C_STATUS_TIMEOUT    3u
#define GHCI_DISP_I2C_STATUS_CANCELLED  4u

typedef struct GhciDisplayI2cBufHeader {
	uint16_t status;                /* 0x00: GHCI_DISP_I2C_STATUS_* */
	uint16_t bytes_done;            /* 0x02: Payload bytes transferred */
} GhciDisplayI2cBufHeader;

/* 16-byte Flip Completion Record */
typedef struct GhciFlipRecord {
	uint32_t value;                 /* 0x00: [30:0] flip_cookie, [31] 1 = CANCELLED */
	uint32_t frame_count;           /* 0x04: Frame count at take / cancellation */
	uint32_t timestamp_lo;          /* 0x08: Constant-rate TIMESTAMP [31:0] */
	uint32_t timestamp_hi;          /* 0x0C: Constant-rate TIMESTAMP [63:32] */
} GhciFlipRecord;

/* CMD_DISP_SET (0x50): 6 dwords (24 bytes) */
typedef struct GhciCmdDispSet {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_SET, dwords: 6, flags */
	uint32_t display_id;
	uint32_t comp_pa_lo;
	uint32_t comp_pa_hi;
	uint32_t comp_val_lo;
	uint32_t comp_val_hi;
} GhciCmdDispSet;

/* CMD_FLIP (0x51): 10 dwords (40 bytes) */
#define GHCI_FLIP_FLAG_VSYNC_WAIT       (1u << 0)
#define GHCI_FLIP_FLAG_IMMEDIATE        (1u << 1)
#define GHCI_FLIP_FLAG_PLANE_CURSOR     (1u << 2) /* 0 = Plane 0 (Primary), 1 = Plane 1 (Cursor) */
#define GHCI_FLIP_FLAG_RECORD_ENABLE    (1u << 3)
#define GHCI_FLIP_FLAG_WAIT_GPU_IDLE    (1u << 4)
#define GHCI_FLIP_FLAG_RECORD_IRQ       (1u << 5)

typedef struct GhciCmdFlip {
	uint32_t header;                /* opcode: GHCI_CMD_FLIP, dwords: 10, flags: 0 */
	uint32_t display_id;
	uint32_t base_lo;               /* 64-bit physical scanout address [31:0] (64B aligned) */
	uint32_t base_hi;               /* 64-bit physical scanout address [63:32] */
	uint32_t stride_bytes;          /* Primary: > 0 & 64B aligned; Cursor: must be 0 */
	uint32_t scanout_format;        /* [7:0] GhciFormat ID (Primary, FMT_SCANOUT==1); Cursor: 0 */
	uint32_t flags;                 /* GHCI_FLIP_FLAG_* */
	uint32_t value;                 /* [30:0] flip_cookie; [31] reserved (0 on input) */
	uint32_t record_pa_lo;          /* 16-byte GhciFlipRecord physical address [31:0] (8B aligned) */
	uint32_t record_pa_hi;          /* 64-bit physical address [63:32] */
} GhciCmdFlip;

/* CMD_DISP_SET_MODE (0x52): 8 dwords (32 bytes) */
typedef struct GhciCmdDispSetMode {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_SET_MODE, dwords: 8, flags */
	uint32_t display_id;
	uint32_t mode_pa_lo;            /* 64B-aligned PA of GhciDisplayModeDesc [31:0] */
	uint32_t mode_pa_hi;            /* [63:32] */
	uint32_t comp_pa_lo;
	uint32_t comp_pa_hi;
	uint32_t comp_val_lo;
	uint32_t comp_val_hi;
} GhciCmdDispSetMode;

/* CMD_DISP_QUERY_STATE (0x53): 9 dwords (36 bytes) */
typedef struct GhciCmdDispQueryState {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_QUERY_STATE, dwords: 9, flags */
	uint32_t display_id;
	uint32_t dst_pa_lo;             /* 64B-aligned PA for GhciDisplayState [31:0] */
	uint32_t dst_pa_hi;             /* [63:32] */
	uint32_t dst_bytes;             /* >= 128 and multiple of 64 */
	uint32_t comp_pa_lo;
	uint32_t comp_pa_hi;
	uint32_t comp_val_lo;
	uint32_t comp_val_hi;
} GhciCmdDispQueryState;

/* CMD_DISP_SET_CURSOR (0x54): 4 dwords (16 bytes) */
#define GHCI_DISP_CURSOR_SHOW           (1u << 0)

typedef struct GhciCmdDispSetCursor {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_SET_CURSOR, dwords: 4, flags: 0 */
	uint32_t display_id;
	uint32_t pos_xy;                /* [15:0] int16_t x, [31:16] int16_t y */
	uint32_t ctrl;                  /* [0] CURSOR_SHOW, [31:1] reserved (0) */
} GhciCmdDispSetCursor;

/* CMD_DISP_QUERY_MODES (0x55): 9 dwords (36 bytes) */
typedef struct GhciCmdDispQueryModes {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_QUERY_MODES, dwords: 9, flags */
	uint32_t display_id;
	uint32_t dst_pa_lo;             /* 64B-aligned PA for header + GhciDisplayModeDesc[] */
	uint32_t dst_pa_hi;
	uint32_t max_modes;             /* Max mode descriptors that fit after 16B header */
	uint32_t comp_pa_lo;
	uint32_t comp_pa_hi;
	uint32_t comp_val_lo;
	uint32_t comp_val_hi;
} GhciCmdDispQueryModes;

/* CMD_DISP_EVENT_SETUP (0x56): 7 dwords (28 bytes) */
#define GHCI_DISP_EVENT_FLAG_ENABLE     (1u << 0)

typedef struct GhciCmdDispEventSetup {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_EVENT_SETUP, dwords: 7, flags */
	uint32_t display_id;
	uint32_t event_ring_pa_lo;      /* 64B-aligned PA when ENABLE == 1 */
	uint32_t event_ring_pa_hi;
	uint32_t ring_cfg;              /* [15:0] capacity_entries, [19:16] event_enable_mask, [31:20] 0 */
	uint32_t comp_pa_lo;            /* 8B-aligned PA for 64-bit setup_next_seq */
	uint32_t comp_pa_hi;
} GhciCmdDispEventSetup;

/* CMD_DISP_I2C_XFER (0x57): 10 dwords (40 bytes) */
typedef struct GhciCmdDispI2cXfer {
	uint32_t header;                /* opcode: GHCI_CMD_DISP_I2C_XFER, dwords: 10, flags */
	uint32_t display_id;
	uint32_t addr_cfg;              /* [6:0] slave_addr_7b, [15:8] reg_offset, [23:16] segment */
	uint32_t xfer_bytes;            /* 1..256 */
	uint32_t buf_pa_lo;             /* 4B-aligned PA of GhciDisplayI2cBufHeader + payload */
	uint32_t buf_pa_hi;
	uint32_t comp_pa_lo;
	uint32_t comp_pa_hi;
	uint32_t comp_val_lo;
	uint32_t comp_val_hi;
} GhciCmdDispI2cXfer;


#ifdef __cplusplus
}
#endif

#endif /* GHCI_CMD_H */
