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

/* Display Controller Commands (0x50..0x5F, Guarded by CAP_DISP) */
#define GHCI_CMD_DISP_SET               0x50u
#define GHCI_CMD_FLIP                   0x51u

/* Legacy/compatibility aliases */
#define GHCI_GPU_OP_VM_MAP              0x10110u
#define GHCI_GPU_OP_VM_UNMAP            0x10111u

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
	uint32_t flags;                 /* dw8: [2:0] topology, [3] prim restart, [4] depth clamp, [5] logic op enable, [9:6] logic op opcode, [10] alpha to coverage, [11] sample shading, [15:12] sample mask (N14, N32) */
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
 * In-Memory Resource Descriptors
 * ============================================================================
 */

/* Texture Descriptor (32 Bytes) */
typedef struct GhciTextureDescriptor {
	uint64_t base_address;          /* 0x00: GPU virtual address of texels (64-bit GPU VA) */
	uint16_t width;                 /* 0x08: Texel width (1..16384) */
	uint16_t height;                /* 0x0A: Texel height (1..16384) */
	uint16_t depth;                 /* 0x0C: 3D depth or array layers */
	uint8_t  format;                /* 0x0E: VkFormat enum (e.g. VK_FORMAT_R8G8B8A8_UNORM = 37, N23) */
	uint8_t  mip_levels;            /* 0x0F: Number of mip levels (1..15) */
	uint32_t row_pitch_bytes;       /* 0x10: Row pitch in bytes */
	uint32_t slice_pitch_bytes;     /* 0x14: 2D array / 3D slice pitch */
	uint8_t  sample_count;          /* 0x18: MSAA sample count (1, 2, 4) */
	uint8_t  dimension;             /* 0x19: 0=1D, 1=2D, 2=3D, 3=Cube */
	uint16_t flags;                 /* 0x1A: [0]=Tiled, [1]=sRGB */
	uint32_t reserved;              /* 0x1C: Padding to 32 bytes */
} GhciTextureDescriptor;

/* Sampler Descriptor (16 Bytes, N23) */
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
	uint8_t  reserved;              /* 0x0F: Padding to 16 bytes */
} GhciSamplerDescriptor;

/* Combined Image Sampler Descriptor (Option A: 32-bit Index Pair, K13) */
typedef struct GhciCombinedImageSampler {
	uint16_t texture_index;         /* Index into Texture Descriptor Table */
	uint16_t sampler_index;         /* Index into Sampler Descriptor Table */
} GhciCombinedImageSampler;

#define GHCI_MAKE_COMBINED_SAMPLER(tex, smp) \
	(((uint32_t)(smp) << 16) | ((uint32_t)(tex) & 0xFFFFu))

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
typedef struct GhciCmdBindDescriptorTable {
	uint32_t header;                /* GHCI_CMD_BIND_DESCRIPTOR_TABLE, size = 4 */
	uint32_t table_va_lo;
	uint32_t table_va_hi;
	uint16_t set_index;             /* Descriptor set binding slot (0..3) */
	uint16_t descriptor_count;      /* Number of descriptors in table */
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
#define GHCI_DYNAMIC_STATE_BLEND_ATTACHMENT_0 0x07u
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
			uint32_t blend_state;   /* Matches PSO dw11 format */
			uint32_t reserved[3];
		} blend_attachment;
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

/* CMD_DRAW_INDIRECT (0x29): 7 dwords (normal) or 8 dwords (count buffer, K10) */
#define GHCI_DRAW_INDIRECT_FLAG_COUNT_BUFFER (1u << 1) /* 1 = Read draw count from count_buffer_va */

typedef struct GhciCmdDrawIndirect {
	uint32_t header;                /* GHCI_CMD_DRAW_INDIRECT, size = 7 */
	uint32_t buffer_va_lo;          /* GPU virtual address of draw args [31:0] */
	uint32_t buffer_va_hi;          /* GPU virtual address of draw args [63:32] */
	uint32_t offset_bytes;          /* Byte offset inside buffer */
	uint32_t draw_count;            /* Direct draw count or maxDrawCount */
	uint32_t stride_bytes;          /* Stride in bytes between draw arguments */
	uint32_t flags;                 /* GHCI_DRAW_INDIRECT_FLAG_* */
} GhciCmdDrawIndirect;

typedef struct GhciCmdDrawIndirectCount {
	uint32_t header;                /* GHCI_CMD_DRAW_INDIRECT, size = 8 (K10) */
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
 * Autonomous Virtual Memory Management (VM_MAP / VM_UNMAP)
 * ============================================================================
 */
#define GHCI_VM_FLAG_READ       (1u << 0)
#define GHCI_VM_FLAG_WRITE      (1u << 1)
#define GHCI_VM_FLAG_EXEC       (1u << 2)
#define GHCI_VM_FLAG_COHERENT   (1u << 3)
#define GHCI_VM_FLAG_WC         (1u << 4)
#define GHCI_VM_FLAG_LOCAL      (1u << 5) /* 1 = Local VRAM, 0 = Host PCIe / IOVA */

/* CMD_VM_MAP (0x10110): 10 dwords (40 bytes) */
typedef struct GhciCmdVmMap {
	uint32_t header;                /* opcode: GHCI_CMD_VM_MAP, dwords: 10 */
	uint32_t session_id;            /* client session identifier */
	uint32_t flags;                 /* GHCI_VM_FLAG_* */
	uint32_t reserved;              /* alignment padding */
	uint32_t gpu_va_lo;             /* GPU virtual address (4KB aligned) [31:0] */
	uint32_t gpu_va_hi;             /* GPU virtual address [63:32] */
	uint32_t phys_lo;               /* IOVA / host physical address [31:0] */
	uint32_t phys_hi;               /* IOVA / host physical address [63:32] */
	uint32_t size_lo;               /* mapping size in bytes [31:0] */
	uint32_t size_hi;               /* mapping size in bytes [63:32] */
} GhciCmdVmMap;

/* CMD_VM_UNMAP (0x11): 8 dwords (32 bytes) */
typedef struct GhciCmdVmUnmap {
	uint32_t header;                /* opcode: GHCI_CMD_VM_UNMAP, dwords: 8 */
	uint32_t session_id;            /* client session identifier */
	uint32_t flags;                 /* unmap flags / options */
	uint32_t reserved;              /* alignment padding */
	uint32_t gpu_va_lo;             /* GPU virtual address (4KB aligned) [31:0] */
	uint32_t gpu_va_hi;             /* GPU virtual address [63:32] */
	uint32_t size_lo;               /* unmap size in bytes [31:0] */
	uint32_t size_hi;               /* unmap size in bytes [63:32] */
} GhciCmdVmUnmap;

/* CMD_SESSION_OPEN (0x12): 4 dwords (16 bytes, root page directory allocated autonomously by CP) */
typedef struct GhciCmdSessionOpen {
	uint32_t header;                /* opcode: GHCI_CMD_SESSION_OPEN, dwords: 4 */
	uint32_t session_id;            /* client session identifier (0..15) */
	uint32_t flags;                 /* session flags (e.g. protected, priority) */
	uint32_t reserved;              /* reserved (must be zero) */
} GhciCmdSessionOpen;

/* CMD_SESSION_CLOSE (0x13): 2 dwords (8 bytes) */
typedef struct GhciCmdSessionClose {
	uint32_t header;                /* opcode: GHCI_CMD_SESSION_CLOSE, dwords: 2 */
	uint32_t session_id;            /* client session identifier to destroy and flush */
} GhciCmdSessionClose;

/* CMD_BIND_SESSION (0x14): 2 dwords (8 bytes) */
typedef struct GhciCmdBindSession {
	uint32_t header;                /* opcode: GHCI_CMD_BIND_SESSION, dwords: 2 */
	uint32_t session_id;            /* client session identifier for subsequent draws/dispatches */
} GhciCmdBindSession;

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
	uint8_t  format;                /* VkFormat for texel buffer; 0 for storage/uniform */
	uint8_t  flags;                 /* [0] ReadOnly, [1] Coherent */
} GhciBufferDescriptor;

/*
 * ============================================================================
 * Additional Command Packet Definitions
 * ============================================================================
 */

/*
 * In-Memory Render Pass Descriptor (GhciRenderPassDesc) - 192 Bytes (64-byte aligned, K12, N03)
 * Pointed to by CMD_BEGIN_RENDER_PASS via render_pass_desc_va.
 */
typedef struct GhciColorAttachmentDesc {
	uint64_t image_va;              /* 0x00: Color attachment GPU virtual address (64-bit GPU VA) */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes (supports up to 4 GiB pitch) */
	uint8_t  format;                /* 0x0C: VkFormat enum (e.g. VK_FORMAT_R8G8B8A8_UNORM = 37) */
	uint8_t  ops;                   /* 0x0D: [1:0] LoadOp (0: Load, 1: Clear, 2: DontCare), [3:2] StoreOp (0: Store, 1: DontCare) */
	uint8_t  mip_level;             /* 0x0E: Target subresource mip level */
	uint8_t  base_array_layer;      /* 0x0F: Base array layer (0..255, N03) */
} GhciColorAttachmentDesc;

typedef struct GhciDepthStencilAttachmentDesc {
	uint64_t depth_stencil_va;      /* 0x00: Depth/stencil GPU virtual address */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes */
	uint8_t  format;                /* 0x0C: Depth/stencil VkFormat (D16_UNORM, D32_SFLOAT, D24S8) */
	uint8_t  ops;                   /* 0x0D: [1:0] DepthLoad, [3:2] DepthStore, [5:4] StencilLoad, [7:6] StencilStore */
	uint8_t  mip_level;             /* 0x0E: Target subresource mip level */
	uint8_t  base_array_layer;      /* 0x0F: Base array layer (0..255, N03) */
} GhciDepthStencilAttachmentDesc;

typedef struct GhciResolveAttachmentDesc {
	uint64_t resolve_va;            /* 0x00: Multisample resolve target GPU virtual address */
	uint32_t row_pitch_bytes;       /* 0x08: Row pitch in bytes */
	uint8_t  format;                /* 0x0C: Resolve destination format (VkFormat) */
	uint8_t  mode;                  /* 0x0D: [1:0] ResolveMode (0: Average, 1: Min, 2: Max, 3: Sample Zero) */
	uint8_t  mip_level;             /* 0x0E: Target subresource mip level */
	uint8_t  base_array_layer;      /* 0x0F: Base array layer (0..255, N03) */
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
	uint16_t layers;                /* 0xA4: Array layer count (1..2048) */
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

/* CMD_WAIT_FENCE (0x34): 5 dwords (64-bit wait value, K09) */
typedef struct GhciCmdWaitFence {
	uint32_t header;                /* opcode: GHCI_CMD_WAIT_FENCE, dwords: 5 */
	uint32_t fence_addr_lo;         /* Host memory address [31:0] */
	uint32_t fence_addr_hi;         /* Host memory address [63:32] */
	uint32_t wait_value_lo;         /* 64-bit value to compare [31:0] */
	uint32_t wait_value_hi;         /* 64-bit value to compare [63:32] ((int64_t)(mem - val) >= 0) */
} GhciCmdWaitFence;

/* CMD_WRITE_TIMESTAMP (0x35): 4 dwords */
typedef struct GhciCmdWriteTimestamp {
	uint32_t header;                /* opcode: GHCI_CMD_WRITE_TIMESTAMP, dwords: 4 */
	uint32_t dst_addr_lo;           /* 64-bit GPU VA or host memory address [31:0] */
	uint32_t dst_addr_hi;           /* 64-bit address [63:32] */
	uint32_t pipeline_stage;        /* Stage at which timestamp is latched (Top, Bottom, etc.) */
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
	uint32_t format_and_flags;      /* [7:0] format (VkFormat), [8] src_tiled, [9] dst_tiled */
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
	uint32_t format_and_flags;      /* [7:0] format (VkFormat), [8] tiled */
} GhciCmdCopyBufferToImage;

/* CMD_COPY_IMAGE_TO_BUFFER (0x46): 10 dwords (N13) */
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
	uint32_t format_and_flags;      /* [7:0] format (VkFormat), [8] tiled */
} GhciCmdCopyImageToBuffer;

/* DISP2 Interrupt Status / Enable Flags (0x218 / 0x21C, N21) */
#define GHCI_DISP_IRQ_BIT_VSYNC         (1u << 0)
#define GHCI_DISP_IRQ_BIT_FLIP_DONE     (1u << 1)
#define GHCI_DISP_IRQ_BIT_CURSOR_DONE   (1u << 2)
#define GHCI_DISP_IRQ_BIT_HOTPLUG       (1u << 3)
#define GHCI_DISP_IRQ_BIT_UNDERFLOW     (1u << 4)
#define GHCI_DISP_IRQ_BIT_ERROR         (1u << 5) /* Controller error: read error, record error, bad write */

/* CMD_FLIP (0x51): 8 dwords (N25) */
#define GHCI_FLIP_FLAG_VSYNC_WAIT       (1u << 0)
#define GHCI_FLIP_FLAG_IMMEDIATE        (1u << 1)
#define GHCI_FLIP_FLAG_PLANE_CURSOR     (1u << 2) /* 0 = Plane 0 (FB), 1 = Plane 1 (Cursor) */
#define GHCI_FLIP_FLAG_RECORD_ENABLE    (1u << 3)

typedef struct GhciCmdFlip {
	uint32_t header;                /* opcode: GHCI_CMD_FLIP, dwords: 8 */
	uint32_t display_id;            /* 0 = primary display, 1 = secondary display */
	uint32_t base_lo;               /* 32-bit GPU physical scanout address (< HOST_LIMIT or >= LOCAL_BASE) (N12, N25) */
	uint32_t base_hi;               /* Must be 0 (N12, N25) */
	uint32_t flags;                 /* GHCI_FLIP_FLAG_* */
	uint32_t value;                 /* Presentation sequence tag (latched to TAKEN0/TAKEN1) */
	uint32_t record_pa_lo;          /* 32-bit GPU physical address of 16-byte flip completion record (N12, N25) */
	uint32_t record_pa_hi;          /* Must be 0 (N12, N25) */
} GhciCmdFlip;


#ifdef __cplusplus
}
#endif

#endif /* GHCI_CMD_H */
