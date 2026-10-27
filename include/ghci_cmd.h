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

typedef struct GhciPipelineState {
	/* 0x00: Shader Stages (64-bit GPU virtual addresses) */
	uint64_t vs_code_va;            /* Vertex Shader instruction base */
	uint64_t fs_code_va;            /* Fragment Shader instruction base */
	uint64_t cs_code_va;            /* Compute Shader instruction base */

	/* 0x18: Vertex Input & Assembly */
	uint16_t vertex_stride;         /* Stride in bytes */
	uint8_t  topology;              /* GHCI_TOPOLOGY_* */
	uint8_t  primitive_restart;     /* 1 = enable restart index */
	uint32_t attribute_mask;        /* Active attributes bitmask (0..15) */

	/* 0x20: Vertex Attribute Formats & Offsets */
	uint32_t attr_formats_lo;       /* Formats for attrs 0..7 */
	uint32_t attr_formats_hi;       /* Formats for attrs 8..15 */
	uint32_t attr_offsets_0_3;      /* Packed 8-bit offsets for attrs 0..3 */
	uint32_t attr_offsets_4_7;      /* Packed 8-bit offsets for attrs 4..7 */

	/* 0x30: Rasterization State */
	uint8_t  cull_mode;             /* GHCI_CULL_* */
	uint8_t  front_face;            /* GHCI_FRONT_* */
	uint8_t  polygon_mode;          /* GHCI_POLYGON_* */
	uint8_t  depth_clamp_enable;    /* 1 = clamp depth */
	uint32_t depth_bias_constant;   /* Constant depth bias (fixed-point/float) */
	uint32_t depth_bias_slope;      /* Slope-scaled depth bias */
	uint32_t depth_bias_clamp;      /* Depth bias clamp */

	/* 0x40: Depth & Stencil State */
	uint8_t  depth_test_enable;     /* 1 = depth test active */
	uint8_t  depth_write_enable;    /* 1 = depth writes enabled */
	uint8_t  depth_compare_op;      /* GHCI_COMPARE_* */
	uint8_t  stencil_test_enable;   /* 1 = stencil test active */
	uint32_t stencil_front;         /* [7:0] fail, [15:8] pass, [23:16] zfail, [31:24] func */
	uint32_t stencil_back;          /* Back-face stencil ops */
	uint16_t stencil_compare_mask;  /* Stencil comparison mask */
	uint16_t stencil_write_mask;    /* Stencil buffer write mask */

	/* 0x50: Color Blend State */
	uint8_t  blend_enable;          /* 1 = blending active */
	uint8_t  src_color_factor;      /* GHCI_BLEND_FACTOR_* */
	uint8_t  dst_color_factor;      /* GHCI_BLEND_FACTOR_* */
	uint8_t  color_blend_op;        /* GHCI_BLEND_OP_* */
	uint8_t  src_alpha_factor;      /* GHCI_BLEND_FACTOR_* */
	uint8_t  dst_alpha_factor;      /* GHCI_BLEND_FACTOR_* */
	uint8_t  alpha_blend_op;        /* GHCI_BLEND_OP_* */
	uint8_t  color_write_mask;      /* [0]=R, [1]=G, [2]=B, [3]=A */
	uint8_t  dual_source_blend;     /* 1 = Dual-source blend active */
	uint8_t  logic_op_enable;       /* 1 = Logic op enabled */
	uint8_t  logic_op;              /* 0..15 Vulkan LogicOp */
	uint8_t  sample_count;          /* 1, 2, 4, 8 MSAA samples */

	/* 0x5C: Dynamic State Override Mask & Reserved */
	uint32_t dynamic_state_mask;    /* States overridden by dynamic commands */
	uint32_t reserved[8];           /* Padding out to exactly 128 bytes */
} GhciPipelineState;

/*
 * ============================================================================
 * In-Memory Resource Descriptors
 * ============================================================================
 */

/* Texture Descriptor (32 Bytes) */
typedef struct GhciTextureDescriptor {
	uint64_t base_address;          /* 0x00: GPU virtual address of texels */
	uint16_t width;                 /* 0x08: Texel width */
	uint16_t height;                /* 0x0A: Texel height */
	uint16_t depth;                 /* 0x0C: 3D depth or array layers */
	uint8_t  format;                /* 0x0E: Texture format */
	uint8_t  mip_levels;            /* 0x0F: Number of mip levels */
	uint32_t row_pitch_bytes;       /* 0x10: Row pitch in bytes */
	uint32_t slice_pitch_bytes;     /* 0x14: 2D array / 3D slice pitch */
	uint8_t  sample_count;          /* 0x18: MSAA sample count */
	uint8_t  dimension;             /* 0x19: 0=1D, 1=2D, 2=3D, 3=Cube */
	uint16_t flags;                 /* 0x1A: [0]=Tiled, [1]=sRGB */
	uint32_t reserved;              /* 0x1C: Padding to 32 bytes */
} GhciTextureDescriptor;

/* Sampler Descriptor (16 Bytes) */
typedef struct GhciSamplerDescriptor {
	uint8_t  min_filter;            /* 0x00: 0=Nearest, 1=Linear */
	uint8_t  mag_filter;            /* 0x01: 0=Nearest, 1=Linear */
	uint8_t  mipmap_mode;           /* 0x02: 0=Nearest, 1=Linear */
	uint8_t  address_mode_u;        /* 0x03: 0=Repeat, 1=Mirrored, 2=ClampToEdge, 3=ClampBorder */
	uint8_t  address_mode_v;        /* 0x04: Address mode V */
	uint8_t  address_mode_w;        /* 0x05: Address mode W */
	uint8_t  compare_enable;        /* 0x06: 1=Depth compare active */
	uint8_t  compare_op;            /* 0x07: Compare op */
	int16_t  lod_bias_fx8;          /* 0x08: Fixed-point 8.8 LOD bias */
	uint8_t  min_lod_fx4;           /* 0x0A: Fixed-point 4.4 min LOD */
	uint8_t  max_lod_fx4;           /* 0x0B: Fixed-point 4.4 max LOD */
	uint32_t border_color;          /* 0x0C: Packed RGBA8 border color */
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

/* CMD_DRAW_INDIRECT (0x29): 6 dwords */
typedef struct GhciCmdDrawIndirect {
	uint32_t header;                /* GHCI_CMD_DRAW_INDIRECT, size = 6 */
	uint32_t args_buffer_va_lo;
	uint32_t args_buffer_va_hi;
	uint32_t draw_count;
	uint32_t stride_bytes;
	uint32_t flags;                 /* [0] = 0 (direct count), 1 (count from buffer) */
} GhciCmdDrawIndirect;

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

#define GHCI_BARRIER_FLUSH_L2C          (1u << 0)
#define GHCI_BARRIER_INVAL_L1           (1u << 1)
#define GHCI_BARRIER_INVAL_TLB          (1u << 2)

typedef struct GhciCmdBarrier {
	uint32_t header;                /* GHCI_CMD_BARRIER, size = 4 */
	uint32_t src_stage_mask;
	uint32_t dst_stage_mask;
	uint32_t flags;                 /* GHCI_BARRIER_* */
} GhciCmdBarrier;

/* CMD_EXECUTE_COMMANDS (0x32): 4 dwords (UMA Secondary Buffer Fetch) */
typedef struct GhciCmdExecuteCommands {
	uint32_t header;                /* GHCI_CMD_EXECUTE_COMMANDS, size = 4 */
	uint32_t secondary_ring_va_lo;
	uint32_t secondary_ring_va_hi;
	uint32_t command_dwords;
} GhciCmdExecuteCommands;

/* CMD_FENCE (0x33): 5 dwords */
#define GHCI_FENCE_FLAG_IRQ             (1u << 0)

typedef struct GhciCmdFence {
	uint32_t header;                /* GHCI_CMD_FENCE, size = 5 */
	uint32_t fence_addr_lo;
	uint32_t fence_addr_hi;
	uint32_t fence_seq_lo;
	uint16_t fence_seq_hi;
	uint16_t flags;                 /* GHCI_FENCE_FLAG_* */
} GhciCmdFence;

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

/* CMD_SESSION_OPEN (0x12): 4 dwords (16 bytes) */
typedef struct GhciCmdSessionOpen {
	uint32_t header;                /* opcode: GHCI_CMD_SESSION_OPEN, dwords: 4 */
	uint32_t session_id;            /* client session identifier (0..15) */
	uint32_t flags;                 /* session flags (e.g. protected, priority) */
	uint32_t root_pt_phys;          /* 4KB-aligned physical address of Page Directory root (0=CP allocates) */
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

/* CMD_BEGIN_RENDER_PASS (0x2B): 10 dwords */
typedef struct GhciCmdBeginRenderPass {
	uint32_t header;                /* opcode: GHCI_CMD_BEGIN_RENDER_PASS, dwords: 10 */
	uint32_t color_attachment_mask; /* Active color attachments bitmask (0..7) */
	uint32_t color_clear_rgba;      /* Packed RGBA8 or float clear value */
	uint32_t depth_clear_value;     /* 32-bit float or 24-bit depth clear */
	uint32_t stencil_clear_value;   /* [7:0] Stencil clear value */
	uint32_t load_op_mask;          /* [1:0] Color0 LoadOp, [3:2] Color1, ..., [17:16] Depth, [19:18] Stencil */
	uint32_t store_op_mask;         /* StoreOp bits matching LoadOp layout */
	uint32_t render_area_offset;    /* [15:0] X, [31:16] Y */
	uint32_t render_area_extent;    /* [15:0] Width, [31:16] Height */
	uint32_t flags;                 /* [0] Inline secondary buffers */
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

/* CMD_WAIT_FENCE (0x34): 4 dwords */
typedef struct GhciCmdWaitFence {
	uint32_t header;                /* opcode: GHCI_CMD_WAIT_FENCE, dwords: 4 */
	uint32_t fence_addr_lo;         /* Host memory address [31:0] */
	uint32_t fence_addr_hi;         /* Host memory address [63:32] */
	uint32_t wait_value;            /* Value to compare (passes when (int32)(mem - value) >= 0) */
} GhciCmdWaitFence;

/* CMD_WRITE_TIMESTAMP (0x35): 4 dwords */
typedef struct GhciCmdWriteTimestamp {
	uint32_t header;                /* opcode: GHCI_CMD_WRITE_TIMESTAMP, dwords: 4 */
	uint32_t dst_addr_lo;           /* 64-bit GPU VA or host memory address [31:0] */
	uint32_t dst_addr_hi;           /* 64-bit address [63:32] */
	uint32_t pipeline_stage;        /* Stage at which timestamp is latched (Top, Bottom, etc.) */
} GhciCmdWriteTimestamp;

/* CMD_COPY_BUFFER (0x40): 7 dwords */
typedef struct GhciCmdCopyBuffer {
	uint32_t header;                /* opcode: GHCI_CMD_COPY_BUFFER, dwords: 7 */
	uint32_t src_va_lo;             /* Source GPU VA [31:0] */
	uint32_t src_va_hi;             /* Source GPU VA [63:32] */
	uint32_t dst_va_lo;             /* Destination GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination GPU VA [63:32] */
	uint32_t size_bytes;            /* Transfer size in bytes */
	uint32_t flags;                 /* Transfer options */
} GhciCmdCopyBuffer;

/* CMD_FILL_BUFFER (0x43): 5 dwords */
typedef struct GhciCmdFillBuffer {
	uint32_t header;                /* opcode: GHCI_CMD_FILL_BUFFER, dwords: 5 */
	uint32_t dst_va_lo;             /* Destination GPU VA [31:0] */
	uint32_t dst_va_hi;             /* Destination GPU VA [63:32] */
	uint32_t size_bytes;            /* Buffer size to fill in bytes (4-byte multiple) */
	uint32_t pattern_data;          /* 32-bit fill pattern */
} GhciCmdFillBuffer;

#ifdef __cplusplus
}
#endif

#endif /* GHCI_CMD_H */
