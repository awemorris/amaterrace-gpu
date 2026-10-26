/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The CP firmware's internal interfaces: the line DMA and the staging
 * reader, the result store, the heap in GPU memory, the object table, the
 * recordings of the command buffers and their replay, the µop output and
 * the command decoder.
 */

#ifndef FW_CP_FW_H
#define FW_CP_FW_H

#include <stddef.h>
#include <stdint.h>

#include "gsi1_isa.h"

/* The interface kind of scratch memory (docs/ghci.md section 12.10, draft). */
#ifndef GSI1_KIND_SCRATCH
#define GSI1_KIND_SCRATCH 14u
#endif

/* The AMB line, set per board by tools/fw-build.sh (64 KC705). */
#ifndef FW_LINE_BYTES
#define FW_LINE_BYTES 64u
#endif

/* The firmware's version in CPFW_VERSION: [31:16] major, [15:0] minor. */
#define FW_VERSION 0x00020001u

/* The firmware's git commit hash (or 0 if unversioned). */
#ifndef FW_COMMIT_HASH
#define FW_COMMIT_HASH 0x00000000u
#endif

/* The firmware states in CPFW_STATUS[15:8]. */
#define FW_STATE_BOOT 0x01u	/* start-up */
#define FW_STATE_IDLE 0x02u	/* waiting for a packet */
#define FW_STATE_PACKET 0x03u	/* decoding a packet */
#define FW_STATE_PARKED 0x04u	/* stopped for a halt request */
#define FW_STATE_TRAP 0xEEu	/* an interrupt came although none is enabled */

/* The value of MBOX3 at start-up: a .data word, restored on every boot. */
#define FW_DATA_CHECK 0x0DA7A001u

/* Lines the staging reader keeps (its buffer is this many lines). */
#define FW_READER_LINES 8u

/*
 * A recording chunk in the heap: word 0 links the next chunk (0 at the
 * end), word 1 counts the payload words used, the rest is payload.
 */
#define FW_CHUNK_BYTES 1024u
#define FW_CHUNK_WORDS (FW_CHUNK_BYTES / 4u)
#define FW_CHUNK_HEAD 2u
#define FW_CHUNK_PAYLOAD (FW_CHUNK_WORDS - FW_CHUNK_HEAD)

/*
 * A recording's data chunk (fw_record_data): the data the units read,
 * line by line, in a visible block (a protected session's granule); no
 * header (the µop chunks list the data chunks).
 */
#define FW_DATA_CHUNK_BYTES 4096u

/* Bytes rounded up to whole lines (a DMEM buffer the DMA reads or writes). */
#define FW_ROUND_LINES(bytes) (((bytes) + FW_LINE_BYTES - 1u) / FW_LINE_BYTES * FW_LINE_BYTES)

/* The sessions the firmware can hold open at once. */
#define FW_SESSIONS 32u

/* The VkResult values the firmware reports (Vulkan's numbers). */
#define FW_VK_SUCCESS 0
#define FW_VK_ERROR_OUT_OF_HOST_MEMORY (-1)
#define FW_VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
#define FW_VK_ERROR_INITIALIZATION_FAILED (-3)
#define FW_VK_ERROR_DEVICE_LOST (-4)
#define FW_VK_ERROR_FEATURE_NOT_PRESENT (-8)
#define FW_VK_ERROR_INCOMPATIBLE_DRIVER (-9)
#define FW_VK_ERROR_FORMAT_NOT_SUPPORTED (-11)
#define FW_VK_ERROR_FRAGMENTED_POOL (-12)
#define FW_VK_ERROR_UNKNOWN (-13)
#define FW_VK_ERROR_OUT_OF_POOL_MEMORY (-1000069000)

/* The object kinds of the object table (the fields a-c per kind). */
enum fw_object_kind {
	FW_OBJ_FREE = 0,
	FW_OBJ_DEVICE,		/* a VkDevice; the session's objects carry its slot */
	FW_OBJ_MEMORY,		/* a: GPU address, b: bytes */
	FW_OBJ_BUFFER,		/* a: GPU address once bound, b: bytes, c: usage */
	FW_OBJ_BUFFER_VIEW,	/* a: GPU address, b: bytes, c: VkFormat */
	FW_OBJ_IMAGE,		/* a: GPU address once bound, block: struct fw_image */
	FW_OBJ_IMAGE_VIEW,	/* block: struct fw_view */
	FW_OBJ_SAMPLER,		/* a: TEX_SAMPLER, b: TEX_LOD */
	FW_OBJ_SET_LAYOUT,	/* block: struct fw_set_layout */
	FW_OBJ_DESC_POOL,	/* a: sets left, b: descriptors left */
	FW_OBJ_DESC_SET,	/* parent: its pool; block: the descriptors; a: their count */
	FW_OBJ_PIPE_LAYOUT,	/* a: push-constant bytes */
	FW_OBJ_PROGRAM_VS,	/* id: the pipeline; block: the program's header and interface table */
	FW_OBJ_PROGRAM_FS,
	FW_OBJ_PROGRAM_CS,
	FW_OBJ_PIPELINE,	/* block: struct fw_pipeline; a, b: its scratch memory's address and bytes */
	FW_OBJ_RENDER_PASS,	/* block: struct fw_render_pass */
	FW_OBJ_FRAMEBUFFER,	/* block: struct fw_framebuffer */
	FW_OBJ_CMD_POOL,
	FW_OBJ_CMDBUF,		/* parent: its pool; a: first chunk, b: last chunk */
	FW_OBJ_SEMAPHORE,
	FW_OBJ_EVENT,		/* block: its status word */
	FW_OBJ_QUERY_POOL,	/* block: the slots; a: queries */
	FW_OBJ_KINDS
};

/* The recording states of a command buffer (Vulkan's lifecycle). */
enum fw_cmdbuf_state {
	FW_CB_INITIAL = 0,
	FW_CB_RECORDING,
	FW_CB_EXECUTABLE,
	FW_CB_INVALID
};

/* The device slot of an object made on no device. */
#define FW_NO_DEVICE 0xFF

/* Object flags. */
#define FW_OBJF_BOUND 0x01u		/* a buffer or an image has memory */
#define FW_OBJF_SECONDARY 0x02u		/* a secondary command buffer */
#define FW_OBJF_ONE_TIME 0x04u		/* begun ONE_TIME_SUBMIT: invalid after its submit */
#define FW_OBJF_FREE_SET 0x08u		/* a descriptor pool whose sets may be freed one by one */
#define FW_OBJF_COMPUTE 0x10u		/* a compute pipeline */
#define FW_OBJF_OWNED 0x4000u		/* a memory object whose range the protection table gives its session */
#define FW_OBJF_VISIBLE 0x8000u		/* the block is visible to the session's work (fw_heap_alloc_visible) */

/*
 * A cursor over a byte range of GPU memory (a frame in the staging buffer,
 * or a class V packet).
 *
 * A refill reads in the protection mode of the moment (fw_dma_mode).
 * Reads that pass the end or meet a DMA error set the sticky error and
 * return 0, so a decoder reads a whole command and looks at the error
 * once; the shared line buffer is refilled as the cursor moves.
 */
struct fw_reader {
	uint32_t addr;
	uint32_t end;
	int error;
};

/*
 * One Vulkan object of a session, named by the identity libvulkan chose.
 *
 * Objects live in a fixed table in DMEM and are chained per hash bucket;
 * what does not fit in the slot lives in a heap block the object owns
 * (`block`, `lines` lines of FW_LINE_BYTES).  A session's close, a
 * device's destruction and a pool's destruction return their objects.
 */
struct fw_object {
	uint64_t id;
	struct fw_object *next;
	struct fw_object *parent;
	uint8_t tag;
	uint8_t kind;
	uint8_t state;
	uint8_t device;
	uint32_t a;
	uint32_t b;
	uint32_t c;
	uint32_t block;
	uint16_t lines;
	uint16_t flags;
};

/*
 * The decoding of one command: its session, its arguments, and what the
 * decoder reports.
 *
 * `stop` is set when the command's end cannot be found (an unknown number
 * or a malformed wire), so the frame cannot go on.  `in_frame` is set for
 * a staged command: the ring-only gpu-ops refuse to run there.  `reply` is
 * the packet's result address when the packet asked for a result (INIT
 * and the diagnostics write their reply's words after the first two
 * there), else 0; a staged command has none.
 */
struct fw_command {
	uint32_t number;
	uint32_t tag;
	struct fw_reader *reader;
	int32_t status;
	uint32_t aux;
	int stop;
	int in_frame;
	uint32_t reply;
};

/*
 * One format the GPU has (formats.inc): its VkFormat, the bytes of a texel
 * (or of a 4x4 block), its components, its type (FW_FMT_*), its flags and
 * where each component lies in the texel.
 */
struct fw_format_component {
	uint8_t position;
	uint8_t width;
};
struct fw_format {
	uint8_t format;
	uint8_t bytes;
	uint8_t components;
	uint8_t type;
	uint8_t flags;
	struct fw_format_component comp[4];
};

/* The types and flags of struct fw_format (tools/fmtmodel.py's numbers). */
#define FW_FMT_UNORM 0u
#define FW_FMT_SNORM 1u
#define FW_FMT_UINT 2u
#define FW_FMT_SINT 3u
#define FW_FMT_SFLOAT 4u
#define FW_FMT_SRGB 5u
#define FW_FMT_UFLOAT 6u
#define FW_FMT_E5 7u
#define FW_FMT_DEPTH 0x01u
#define FW_FMT_STENCIL 0x02u
#define FW_FMT_BLOCK 0x04u
#define FW_FMT_COLOR 0x08u	/* a colour attachment format */
#define FW_FMT_LINEAR 0x10u	/* linear filtering */

/* The VkFormats the firmware names. */
#define FW_VK_FORMAT_R5G6B5_UNORM_PACK16 4u
#define FW_VK_FORMAT_R8G8B8A8_UNORM 37u
#define FW_VK_FORMAT_R8G8B8A8_SRGB 43u
#define FW_VK_FORMAT_B8G8R8A8_UNORM 44u
#define FW_VK_FORMAT_B8G8R8A8_SRGB 50u
#define FW_VK_FORMAT_R32_UINT 98u
#define FW_VK_FORMAT_D16_UNORM 124u
#define FW_VK_FORMAT_X8_D24_UNORM_PACK32 125u
#define FW_VK_FORMAT_D32_SFLOAT 126u
#define FW_VK_FORMAT_S8_UINT 127u
#define FW_VK_FORMAT_D24_UNORM_S8_UINT 129u

/* VkImageAspectFlags. */
#define FW_ASPECT_COLOR 0x1u
#define FW_ASPECT_DEPTH 0x2u
#define FW_ASPECT_STENCIL 0x4u

/*
 * An image (its object's block): what its create info said and its
 * layout (include/ghci_layout.h).
 */
struct fw_image {
	uint32_t format;
	uint32_t type;		/* VkImageType */
	uint32_t width;
	uint32_t height;
	uint32_t depth;
	uint32_t levels;
	uint32_t layers;
	uint32_t samples;
	uint32_t usage;
	uint32_t create_flags;
	uint32_t texel_bytes;
	uint32_t block;		/* a compressed format of 4x4 blocks */
	uint32_t attachment;	/* may be a colour or depth/stencil attachment */
	uint32_t layer_stride;
	uint32_t size;
	uint32_t reserved;
};

/*
 * An image view (its object's block): the view's first level and layer
 * as the units see them, and the words of a texture slot.
 */
struct fw_view {
	uint32_t base;		/* GPU address of the first level and layer */
	uint32_t row;		/* bytes of a row of that level */
	uint32_t width;		/* of that level */
	uint32_t height;
	uint32_t layers;	/* layers of the view (a 3D level's depth) */
	uint32_t layer_stride;
	uint32_t format;
	uint32_t samples;
	uint32_t texel_bytes;
	uint32_t tex_size;	/* TEX_SIZE, TEX_IMAGE and TEX_FORMAT of a slot */
	uint32_t tex_image;
	uint32_t tex_format;
	uint32_t aspect;
	uint32_t levels;
	uint32_t view_type;
	uint32_t tex_row;	/* TEX_ROW: the rows' rounding (1: an attachment's even rows) */
};

/*
 * A descriptor set layout's table (its block, and the head of each set's
 * block): per binding its number, type, count, its first descriptor in
 * the set, its first dynamic offset and its first immutable sampler.
 */
#define FW_LAYOUT_BINDINGS 16u
#define FW_NO_IMMUTABLE 0xFFFFFFFFu
struct fw_layout_binding {
	uint32_t binding;
	uint32_t type;
	uint32_t count;
	uint32_t first;
	uint32_t dynamic_first;
	uint32_t immutable;
};
struct fw_set_layout {
	uint32_t count;
	uint32_t descriptors;
	uint32_t dynamic;
	uint32_t immutable;
	struct fw_layout_binding bindings[FW_LAYOUT_BINDINGS];
};

/*
 * One descriptor of a set (32 bytes): its type, the image view (image
 * types) or the address and bytes (buffers, texel buffers with their
 * format in `object`), the sampler's words.
 */
struct fw_descriptor {
	uint32_t type;
	uint32_t flags;		/* FW_DESC_* */
	uint64_t object;	/* the image view; a texel buffer's VkFormat */
	uint32_t sampler;	/* TEX_SAMPLER */
	uint32_t lod;		/* TEX_LOD */
	uint32_t address;
	uint32_t bytes;
};
#define FW_DESC_IMMUTABLE 0x1u

/* The sets one ALLOCATE_DESCRIPTOR_SETS may make. */
#define FW_MAX_ALLOCATE 64u

/* A render pass's attachments and subpasses (v1 limits). */
#define FW_RP_ATTACHMENTS 12u
#define FW_RP_SUBPASSES 4u
#define FW_RP_COLORS 4u		/* maxColorAttachments */
#define FW_RP_INPUTS 4u
#define FW_RP_UNUSED 0xFFFFFFFFu	/* VK_ATTACHMENT_UNUSED */

/* One attachment of a render pass. */
struct fw_rp_attachment {
	uint32_t format;
	uint32_t samples;
	uint32_t load;
	uint32_t store;
	uint32_t stencil_load;
	uint32_t stencil_store;
};

/* One subpass: its attachment indices (FW_RP_UNUSED for none). */
struct fw_subpass {
	uint32_t colors;
	uint32_t inputs;
	uint32_t color[FW_RP_COLORS];
	uint32_t resolve[FW_RP_COLORS];
	uint32_t input[FW_RP_INPUTS];
	uint32_t depth;
};

/* A render pass (its object's block). */
struct fw_render_pass {
	uint32_t attachments;
	uint32_t subpasses;
	struct fw_rp_attachment attachment[FW_RP_ATTACHMENTS];
	struct fw_subpass subpass[FW_RP_SUBPASSES];
};

/* A framebuffer (its object's block): its size and its attachments' views. */
struct fw_framebuffer {
	uint32_t width;
	uint32_t height;
	uint32_t layers;
	uint32_t attachments;
	uint32_t reserved[12];
	struct fw_view view[FW_RP_ATTACHMENTS];
};

/* A pipeline's vertex input, its attributes and its resources (v1 limits). */
#define FW_PIPE_BINDINGS 16u
#define FW_PIPE_ATTRIBUTES 16u
#define FW_PIPE_RESOURCES 40u
#define FW_PIPE_PAIRS 64u
#define FW_PIPE_SYSTEM_BINDING 0xFFFFu	/* an attribute read from the identity buffer */

/* One vertex attribute slot of a pipeline, ready for the VF's words. */
struct fw_pipe_attr {
	uint32_t binding;	/* the vertex buffer (FW_PIPE_SYSTEM_BINDING: the identity buffer) */
	uint32_t offset;	/* added to the binding's address */
	uint32_t desc;		/* ATTR_DESC */
	uint32_t dst;		/* ATTR_DST */
	uint32_t bytes;		/* the attribute's bytes (for ATTR_LIMIT) */
};

/*
 * One resource of a pipeline's programs (an interface entry of kinds 4-12
 * and 14): the kind, the set and binding, the kind-specific word and the
 * stage (the texture slots are per stage).
 */
struct fw_pipe_resource {
	uint32_t kind;
	uint32_t set;
	uint32_t binding;
	uint32_t specific;
	uint32_t stage;
};

/*
 * A pipeline (its object's block): the state the draws need beyond the
 * STATE words it writes (`pair`), its vertex attributes and its
 * resources.
 */
struct fw_pipeline {
	uint32_t flags;			/* FW_PIPE_* */
	uint32_t dynamic;		/* FW_DYN_* */
	uint32_t viewport[6];
	uint32_t scissor[4];
	uint32_t stencil_compare[2];
	uint32_t stencil_write[2];
	uint32_t stencil_reference[2];
	uint32_t stencil_op[2];		/* compareOp, front and back */
	uint32_t depth_bias[3];
	uint32_t blend_constants[4];
	uint32_t depth_bounds[2];
	uint32_t bank_words;		/* the constant bank's words the programs use */
	uint32_t push_bank[2];		/* the bank word of the push constants (vertex/compute, fragment; ~0 none) */
	uint32_t push_bytes[2];
	uint32_t attributes;
	struct fw_pipe_attr attr[FW_PIPE_ATTRIBUTES];
	uint32_t resources;
	struct fw_pipe_resource resource[FW_PIPE_RESOURCES];
	uint32_t pairs;
	uint32_t pair[FW_PIPE_PAIRS][2];
	uint32_t scratch_bytes;		/* the programs' scratch memory (the object's a and b) */
};
#define FW_PIPE_COMPUTE 0x1u
#define FW_RESIDENT_WARPS 4u		/* the warps that run at once when GHCI_HEAP does not say */
#define FW_PIPE_NO_PUSH 0xFFFFFFFFu

/* The texture slot's word +7 (CAPS[30], draft): the rows' rounding, log2 of the texels. */
#ifndef GHCI_TEX_ROW
#define GHCI_TEX_ROW 7u
#endif

/* VkImageUsageFlags the firmware looks at. */
#define FW_USAGE_COLOR_ATTACHMENT 0x10u
#define FW_USAGE_DEPTH_STENCIL_ATTACHMENT 0x20u

/* The bind points of a command buffer's state. */
#define FW_BIND_GRAPHICS 0u
#define FW_BIND_COMPUTE 1u

/* What a command buffer may bind (Vulkan 1.0's minimum limits or more). */
#define FW_SETS 4u		/* maxBoundDescriptorSets */
#define FW_SET_DYNAMIC 8u	/* dynamic buffers per set */
#define FW_VERTEX_BUFFERS 16u	/* maxVertexInputBindings */
#define FW_PUSH_BYTES 128u	/* maxPushConstantsSize */

/* The dynamic states of the recording state (VkDynamicState bits). */
#define FW_DYN_VIEWPORT (1u << 0)
#define FW_DYN_SCISSOR (1u << 1)
#define FW_DYN_LINE_WIDTH (1u << 2)
#define FW_DYN_DEPTH_BIAS (1u << 3)
#define FW_DYN_BLEND_CONSTANTS (1u << 4)
#define FW_DYN_DEPTH_BOUNDS (1u << 5)
#define FW_DYN_STENCIL_COMPARE_MASK (1u << 6)
#define FW_DYN_STENCIL_WRITE_MASK (1u << 7)
#define FW_DYN_STENCIL_REFERENCE (1u << 8)

/*
 * What a command buffer has bound while it records: the state the next
 * draw or dispatch is translated with.  One is in DMEM at a time
 * (fw_rstate); a command buffer that records keeps its own in its block.
 */
struct fw_rstate {
	uint64_t pipeline[2];
	uint64_t sets[2][FW_SETS];
	uint32_t dynamic[2][FW_SETS][FW_SET_DYNAMIC];
	uint32_t dynamic_count[2][FW_SETS];
	uint32_t vb_address[FW_VERTEX_BUFFERS];
	uint32_t vb_bytes[FW_VERTEX_BUFFERS];
	uint32_t ib_address;
	uint32_t ib_bytes;
	uint32_t ib_format;
	uint32_t push[FW_PUSH_BYTES / 4u];
	uint32_t viewport[6];		/* x, y, width, height, minDepth, maxDepth (fp32) */
	uint32_t scissor[4];		/* x, y, width, height */
	uint32_t line_width;		/* fp32 */
	uint32_t depth_bias[3];		/* constant, clamp, slope (fp32) */
	uint32_t blend_constants[4];	/* fp32 */
	uint32_t depth_bounds[2];	/* fp32 */
	uint32_t stencil_compare[2];	/* front, back */
	uint32_t stencil_write[2];
	uint32_t stencil_reference[2];
	uint32_t dynamic_set;		/* FW_DYN_* given since the begin */
	uint64_t render_pass;
	uint64_t framebuffer;
	uint32_t subpass;
	uint32_t area[4];		/* x, y, width, height */
	uint32_t in_pass;
	uint32_t contents;		/* the subpass contents (secondary command buffers) */
	uint64_t query_pool;		/* the active occlusion query (0: none) */
	uint32_t query;
	uint64_t emitted[2];		/* the pipelines whose STATE words the recording last wrote */
	uint32_t occlusion;		/* 1 while an occlusion query is active (ROP_CTRL[0]) */
	uint32_t data_chunk;		/* the recording's last data chunk (0: none yet) */
	uint32_t data_used;		/* its lines in use */
};

/* The replay's markers: work in a recording that the firmware does itself. */
#define FW_MARK_INDIRECT 1u	/* [kind][address][count][stride][bytes]: indirect draw or dispatch */
#define FW_MARK_QUERY_COPY 2u	/* [slots][queries][destination][stride][flags]: query results */
#define FW_MARK_WAIT_EVENT 3u	/* reserved */
#define FW_MARK_DATA 4u		/* [address]: a data chunk of the recording; the replay skips it, the clear frees it */

void *memcpy(void *dst, const void *src, size_t bytes);
void *memset(void *dst, int value, size_t bytes);
int memcmp(const void *a, const void *b, size_t bytes);

/* dma.c: the line DMA, the reader, the result store. */
int fw_dma_read(uint32_t address, void *dmem, uint32_t lines);
int fw_dma_write(uint32_t address, const void *dmem, uint32_t lines);
int fw_mem_read(uint32_t address, void *dmem, uint32_t bytes);
int fw_mem_write(uint32_t address, const void *dmem, uint32_t bytes);
#define FW_BOUNCE_BYTES 256u
int fw_copy_in(uint32_t address, void *dst, uint32_t bytes);
int fw_copy_out(uint32_t address, const void *src, uint32_t bytes);
void fw_reader_init(struct fw_reader *reader, uint32_t address, uint32_t bytes);
uint32_t fw_reader_u32(struct fw_reader *reader);
uint64_t fw_reader_u64(struct fw_reader *reader);
uint32_t fw_reader_address(struct fw_reader *reader);
void fw_reader_skip(struct fw_reader *reader, uint32_t bytes);
void fw_reader_words(struct fw_reader *reader, uint32_t *dst, uint32_t count);
uint32_t fw_reader_count(struct fw_reader *reader, uint32_t limit);
int fw_store(uint32_t address, const void *src, uint32_t bytes);
int fw_store_flush(void);
#define FW_DMA_CHK 0x1u		/* the copies reach the packet's session's memory (checked) */
#define FW_DMA_TBL 0x2u		/* the copies write the protection table */
uint32_t fw_dma_mode(uint32_t mode);

/* prot.c: session protection (docs/ghci.md section 11.6). */
void fw_prot_init(void);
int fw_prot_present(void);
uint32_t fw_prot_slot(uint32_t tag);
int fw_prot_open(uint32_t tag);
int fw_prot_own(uint32_t tag, uint32_t address, uint32_t bytes, int read_only);
void fw_prot_disown(uint32_t tag, uint32_t address, uint32_t bytes);
int fw_prot_public(uint32_t address, uint32_t bytes);
int fw_prot_grant(uint32_t tag, uint32_t access, uint32_t address, uint32_t bytes);
int fw_prot_revoke(uint32_t tag, uint32_t address, uint32_t bytes);
void fw_prot_close(uint32_t tag);
int fw_prot_drain(void);

/* heap.c: the heap in GPU memory and the sessions. */
void fw_heap_init(void);
int fw_heap_set(uint32_t base, uint32_t bytes, uint32_t warps);
uint32_t fw_heap_warps(void);
int fw_heap_ready(void);
uint32_t fw_heap_alloc(uint32_t tag, uint32_t bytes);
uint32_t fw_heap_alloc_aligned(uint32_t tag, uint32_t bytes, uint32_t align);
void fw_heap_free(uint32_t tag, uint32_t address, uint32_t bytes);
int fw_session_open(uint32_t tag, uint64_t limit);
int fw_session_is_open(uint32_t tag);
void fw_session_lose(uint32_t tag);
int fw_session_lost(uint32_t tag);
void fw_session_close(uint32_t tag);
int fw_session_any(void);

/* visible.c: the heap blocks a session's work reaches. */
uint32_t fw_heap_alloc_visible(uint32_t tag, uint32_t bytes);
void fw_heap_free_visible(uint32_t tag, uint32_t address, uint32_t bytes);
void fw_heap_close_visible(uint32_t tag);
void fw_heap_init_visible(void);

/* builtin.c: the firmware's own part of the heap. */
#define FW_IDENTITY_WORDS 65536u		/* the identity buffer: vertex and instance indices */
#define FW_BUILTIN_PROGRAM_BYTES 1024u
enum fw_builtin_program {
	FW_PROGRAM_MASK = 0,		/* a fragment stage that keeps every sample */
	FW_PROGRAM_BLIT_VS,		/* the blit draw's vertex program */
	FW_PROGRAM_BLIT_FS,		/* the blit draw's fragment program */
	FW_PROGRAM_S8_TO_IMAGE,		/* stencil bytes from a buffer into D24S8 texels */
	FW_PROGRAM_S8_FROM_IMAGE,	/* stencil bytes of D24S8 texels into a buffer */
	FW_BUILTIN_PROGRAMS
};
/*
 * The firmware's part: the identity buffer and the programs, public to the
 * protected sessions and so whole 4 KiB granules, then the wait word in a
 * granule of its own (private), from which the heap's free lines start.
 */
#define FW_BUILTIN_PUBLIC_BYTES ((FW_IDENTITY_WORDS * 4u + FW_BUILTIN_PROGRAMS * FW_BUILTIN_PROGRAM_BYTES + 4095u) & ~4095u)
#define FW_BUILTIN_BYTES (FW_BUILTIN_PUBLIC_BYTES + FW_LINE_BYTES)
int fw_builtin_init(uint32_t base);
uint32_t fw_builtin_identity(void);
uint32_t fw_builtin_program(uint32_t program, uint32_t *words);
uint32_t fw_builtin_wait_word(void);

/* object.c: the object table. */
void fw_object_init(void);
struct fw_object *fw_object_find(uint32_t tag, uint64_t id, uint32_t kind);
struct fw_object *fw_object_create(uint32_t tag, uint64_t id, uint32_t kind);
int fw_object_block(struct fw_object *object, uint32_t bytes);
int fw_object_block_visible(struct fw_object *object, uint32_t bytes);
void fw_object_destroy(struct fw_object *object);
void fw_object_each_child(struct fw_object *parent, void (*visit)(struct fw_object *child));
void fw_object_close(uint32_t tag);
void fw_object_close_device(uint32_t tag, uint64_t device);
int fw_object_device(uint32_t tag, uint64_t device);

/*
 * One blit: the BLT words (docs/ghci.md section 8.2, with CAPS[30]'s
 * pixel sizes, KEEP and colour words).
 */
struct fw_blt {
	uint32_t op;
	uint32_t dst;
	uint32_t dst_stride;
	uint32_t src;
	uint32_t src_stride;
	uint32_t dst_xy;
	uint32_t src_xy;
	uint32_t size;
	uint32_t color[4];
	uint32_t clip_min;
	uint32_t clip_max;
	uint32_t resolve;
};

/* transfer.c: blits. */
uint32_t fw_blt_pixel(uint32_t bytes);
void fw_blt_emit(const struct fw_blt *blt);
void fw_blt_fill_rect(uint32_t base, uint32_t stride, uint32_t texel_bytes, uint32_t samples, const uint32_t *rect, const uint32_t *raw, uint32_t keep);

/* uop.c: µops to the FIFO or into a recording. */
#define FW_EMIT_PAYLOAD 32u	/* the longest payload of fw_emit_op and fw_emit_marker */
void fw_uop_send(const uint32_t *words, uint32_t count);
void fw_uop_reset(void);
void fw_emit_begin(struct fw_object *cmdbuf, uint32_t tag);
int fw_emit_end(void);
void fw_emit_set(uint32_t index, uint32_t value);
void fw_emit_op(uint32_t op, uint32_t flags, const uint32_t *payload, uint32_t count);
void fw_emit_marker(uint32_t code, const uint32_t *payload, uint32_t count);
int fw_emit_error(void);
uint32_t fw_emit_data(const uint32_t *words, uint32_t count);

/* record.c: the command buffers' recordings and their replay. */
int fw_record_words(struct fw_object *cmdbuf, const uint32_t *words, uint32_t count);
int fw_record_words_at(struct fw_object *cmdbuf, const uint32_t *words, uint32_t count, uint32_t *address);
int fw_record_data(struct fw_object *cmdbuf, const uint32_t *words, uint32_t count, uint32_t *address);
void fw_record_clear(struct fw_object *cmdbuf);
int fw_record_flush(void);
int fw_record_replay(struct fw_object *cmdbuf, uint32_t depth);
int fw_record_append(struct fw_object *cmdbuf, struct fw_object *secondary);
struct fw_rstate *fw_rstate(struct fw_object *cmdbuf);
int fw_rstate_begin(struct fw_object *cmdbuf);
void fw_rstate_end(struct fw_object *cmdbuf);

/* submit.c: the replays of the submits, their markers, and waiting for the units. */
void fw_submit_run(void);
int fw_marker_run(uint32_t code, const uint32_t *payload, uint32_t count);
int fw_wait_units(void);

/* query.c: the copy of query results (a marker). */
int fw_query_copy(const uint32_t *payload, uint32_t count);

/* format.c: the formats. */
const struct fw_format *fw_format_find(uint32_t format);
int fw_format_pack_color(uint32_t format, const uint32_t *color, uint32_t *raw);
int fw_format_pack_depth(uint32_t format, uint32_t depth, uint32_t stencil, uint32_t aspects, uint32_t *raw, uint32_t *keep);

/* float.c: fp32 arithmetic on IEEE bits. */
int32_t fw_f32_fixed(uint32_t bits, uint32_t fraction, int32_t minimum, int32_t maximum);
uint32_t fw_f32_from_int(int32_t value);
uint32_t fw_f32_add(uint32_t a, uint32_t b);

/* cmd.c, packet.c: the commands, their wire, and the packets. */
void fw_command_decode(struct fw_command *command);
void fw_packet_run(uint32_t info);
void fw_wire_expect(struct fw_command *command, uint64_t value);
void fw_wire_head(struct fw_command *command);
void fw_wire_skip_u64s(struct fw_command *command);
void fw_wire_skip_u32s(struct fw_command *command);
void fw_wire_skip_string(struct fw_command *command);
uint64_t fw_wire_create_begin(struct fw_command *command);
uint64_t fw_wire_create_end(struct fw_command *command);
uint64_t fw_wire_destroy(struct fw_command *command);
struct fw_object *fw_cmd_new_object(struct fw_command *command, uint64_t device, uint64_t id, uint32_t kind);
void fw_cmd_destroy_object(struct fw_command *command, uint32_t kind);

/* The handlers of the command table, by file. */
void fw_cmd_init(struct fw_command *command);
void fw_cmd_diag_echo(struct fw_command *command);
void fw_cmd_diag_write(struct fw_command *command);
void fw_cmd_diag_sum(struct fw_command *command);
void fw_cmd_program(struct fw_command *command);
void fw_cmd_queue_submit(struct fw_command *command);
void fw_cmd_bind_buffer(struct fw_command *command);
void fw_cmd_bind_image(struct fw_command *command);
void fw_cmd_create_buffer(struct fw_command *command);
void fw_cmd_destroy_buffer(struct fw_command *command);
void fw_cmd_create_buffer_view(struct fw_command *command);
void fw_cmd_destroy_buffer_view(struct fw_command *command);
void fw_cmd_create_image(struct fw_command *command);
void fw_cmd_destroy_image(struct fw_command *command);
void fw_cmd_create_image_view(struct fw_command *command);
void fw_cmd_destroy_image_view(struct fw_command *command);
void fw_cmd_create_sampler(struct fw_command *command);
void fw_cmd_destroy_sampler(struct fw_command *command);
void fw_cmd_create_command_pool(struct fw_command *command);
void fw_cmd_destroy_command_pool(struct fw_command *command);
void fw_cmd_reset_command_pool(struct fw_command *command);
void fw_cmd_allocate_command_buffers(struct fw_command *command);
void fw_cmd_free_command_buffers(struct fw_command *command);
void fw_cmd_begin_command_buffer(struct fw_command *command);
void fw_cmd_end_command_buffer(struct fw_command *command);
void fw_cmd_reset_command_buffer(struct fw_command *command);
void fw_cmd_create_set_layout(struct fw_command *command);
void fw_cmd_destroy_set_layout(struct fw_command *command);
void fw_cmd_create_descriptor_pool(struct fw_command *command);
void fw_cmd_destroy_descriptor_pool(struct fw_command *command);
void fw_cmd_reset_descriptor_pool(struct fw_command *command);
void fw_cmd_allocate_descriptor_sets(struct fw_command *command);
void fw_cmd_free_descriptor_sets(struct fw_command *command);
void fw_cmd_update_descriptor_sets(struct fw_command *command);
void fw_cmd_create_pipeline_layout(struct fw_command *command);
void fw_cmd_destroy_pipeline_layout(struct fw_command *command);
void fw_cmd_create_render_pass(struct fw_command *command);
void fw_cmd_destroy_render_pass(struct fw_command *command);
void fw_cmd_create_framebuffer(struct fw_command *command);
void fw_cmd_destroy_framebuffer(struct fw_command *command);
void fw_cmd_create_graphics_pipelines(struct fw_command *command);
void fw_cmd_create_compute_pipelines(struct fw_command *command);
void fw_cmd_destroy_pipeline(struct fw_command *command);
void fw_cmd_copy_buffer(struct fw_command *command);
void fw_cmd_bind_pipeline(struct fw_command *command);
void fw_cmd_bind_descriptor_sets(struct fw_command *command);
void fw_cmd_bind_vertex_buffers(struct fw_command *command);
void fw_cmd_bind_index_buffer(struct fw_command *command);
void fw_cmd_push_constants(struct fw_command *command);
void fw_cmd_set_viewport(struct fw_command *command);
void fw_cmd_set_scissor(struct fw_command *command);
void fw_cmd_set_line_width(struct fw_command *command);
void fw_cmd_set_depth_bias(struct fw_command *command);
void fw_cmd_set_blend_constants(struct fw_command *command);
void fw_cmd_set_depth_bounds(struct fw_command *command);
void fw_cmd_set_stencil_compare(struct fw_command *command);
void fw_cmd_set_stencil_write(struct fw_command *command);
void fw_cmd_set_stencil_reference(struct fw_command *command);
void fw_cmd_draw(struct fw_command *command);
void fw_cmd_draw_indexed(struct fw_command *command);
void fw_cmd_draw_indirect(struct fw_command *command);
void fw_cmd_draw_indexed_indirect(struct fw_command *command);
void fw_cmd_dispatch(struct fw_command *command);
void fw_cmd_dispatch_indirect(struct fw_command *command);
void fw_cmd_begin_render_pass(struct fw_command *command);
void fw_cmd_next_subpass(struct fw_command *command);
void fw_cmd_end_render_pass(struct fw_command *command);
void fw_cmd_clear_attachments(struct fw_command *command);
void fw_cmd_create_event(struct fw_command *command);
void fw_cmd_destroy_event(struct fw_command *command);
void fw_cmd_set_event(struct fw_command *command);
void fw_cmd_reset_event(struct fw_command *command);
void fw_cmd_wait_events(struct fw_command *command);
void fw_cmd_pipeline_barrier(struct fw_command *command);
void fw_cmd_execute_commands(struct fw_command *command);
void fw_cmd_create_query_pool(struct fw_command *command);
void fw_cmd_destroy_query_pool(struct fw_command *command);
void fw_cmd_begin_query(struct fw_command *command);
void fw_cmd_end_query(struct fw_command *command);
void fw_cmd_reset_query_pool(struct fw_command *command);
void fw_cmd_copy_query_pool_results(struct fw_command *command);
void fw_cmd_write_timestamp(struct fw_command *command);
void fw_cmd_copy_buffer_to_image(struct fw_command *command);
void fw_cmd_copy_image_to_buffer(struct fw_command *command);
void fw_cmd_copy_image(struct fw_command *command);
void fw_cmd_resolve_image(struct fw_command *command);
void fw_cmd_clear_color_image(struct fw_command *command);
void fw_cmd_clear_depth_stencil_image(struct fw_command *command);
void fw_cmd_blit_image(struct fw_command *command);
void fw_cmd_update_buffer(struct fw_command *command);
void fw_cmd_fill_buffer(struct fw_command *command);

/* pass.c: render passes and framebuffers. */
int fw_render_pass_get(uint32_t tag, uint64_t id, struct fw_render_pass *pass);
int fw_framebuffer_view(uint32_t tag, uint64_t id, uint32_t attachment, struct fw_view *view, uint32_t *size);

/* passrec.c: the RESOLVE average of a format. */
uint32_t fw_resolve_average(uint32_t format);

/* pipeline.c: a pipeline's block. */
int fw_pipeline_get(uint32_t tag, uint64_t id, struct fw_pipeline *pipeline);

/* descriptor.c: a set's descriptors. */
int fw_descriptor_get(struct fw_object *set, uint32_t index, struct fw_descriptor *descriptor);
#define FW_NO_DYNAMIC 0xFFFFFFFFu
int fw_descriptor_lookup(struct fw_object *set, uint32_t binding, uint32_t element, uint32_t *index, uint32_t *dynamic);

/* cmdbuf.c: the command buffer a recorded command goes into. */
struct fw_object *fw_cmd_recording(struct fw_command *command, uint64_t id);
void fw_cmd_record_error(struct fw_object *cmdbuf, int32_t status);
struct fw_rstate *fw_cmd_record_state(struct fw_command *command, uint64_t id, struct fw_object **cmdbuf);

#endif
