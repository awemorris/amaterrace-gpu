/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Graphics and compute pipelines.  The create command lists the create
 * infos first and the pipelines' identities last, and a pipeline's
 * programs (GHCI_PROGRAM, sent before) are found by its identity: so each
 * info is read into a heap block first (the pipeline's state as Vulkan
 * gives it, struct pipe_raw), and once the identities are known each
 * pipeline is finished from its block and its programs: the STATE words
 * it writes, its vertex attributes and its resources (struct
 * fw_pipeline).
 *
 * The state words follow docs/ghci.md section 8.5: Vulkan's clipping
 * (DEPTH_CLAMP[1]), fragments inside the viewport's rectangle
 * (RAST_MODE[3]) and fp32 blend constants (ROP_CTRL[1]).  Dynamic state,
 * the viewport, the scissor, the stencil masks and references, the
 * depth bias, the blend constants and the depth bounds are written at
 * each draw from the pipeline's or the command buffer's values.
 */

#include "fw.h"
#include "ghci_regs.h"
#include "gsi1_isa.h"

/* The pipelines one create command may make. */
#define PIPE_MAX_CREATE 16u

/* VkDynamicState values of Vulkan 1.0 (0-8), one FW_DYN_* bit each. */
#define PIPE_DYNAMIC_STATES 9u

/* VkShaderStageFlagBits. */
#define PIPE_STAGE_VERTEX 0x01u
#define PIPE_STAGE_FRAGMENT 0x10u
#define PIPE_STAGE_COMPUTE 0x20u

/* VkFrontFace COUNTER_CLOCKWISE, VkVertexInputRate INSTANCE. */
#define PIPE_FRONT_CCW 0u
#define PIPE_RATE_INSTANCE 1u

/* The STATE words of DEPTH (docs/ghci.md section 8.5). */
#define PIPE_DEPTH_TEST (1u << 0)
#define PIPE_DEPTH_WRITE (1u << 1)
#define PIPE_DEPTH_D24 (1u << 5)
#define PIPE_DEPTH_D32F (1u << 6)
#define PIPE_DEPTH_D16 (1u << 7)
#define PIPE_DEPTH_STENCIL (1u << 8)
#define PIPE_DEPTH_BOUNDS (1u << 9)

/* RAST_MODE, DEPTH_CLAMP, MS_CTRL (docs/ghci.md sections 8.5 and 12.11). */
#define PIPE_RAST_BIAS (1u << 0)
#define PIPE_RAST_VIEWPORT (1u << 3)
#define PIPE_RAST_DISCARD (1u << 6)
#define PIPE_CLAMP_DEPTH (1u << 0)
#define PIPE_CLAMP_CLIP (1u << 1)
#define PIPE_MS_CENTROID (1u << 4)
#define PIPE_MS_A2C (1u << 8)
#define PIPE_MS_A2O (1u << 9)

/* The STATE indices the vertex fetcher and the program range do not name. */
#define PIPE_S_ATTR_DESC(k) (GHCI_S_ATTR + 2u * (k) + 1u)

/*
 * A pipeline's state as its create info gives it, kept in its block until
 * the pipeline is finished.
 */
struct pipe_raw {
	uint64_t render_pass;
	uint32_t subpass;
	uint32_t topology;
	uint32_t restart;
	uint32_t clamp;
	uint32_t discard;
	uint32_t cull;
	uint32_t front;
	uint32_t bias;
	uint32_t samples;
	uint32_t sample_mask;
	uint32_t a2c;
	uint32_t a2o;
	uint32_t depth_test;
	uint32_t depth_write;
	uint32_t depth_op;
	uint32_t bounds;
	uint32_t stencil;
	uint32_t stencil_ops[2][3];	/* fail, pass, depth fail; front and back */
	uint32_t blends;
	uint32_t blend[FW_RP_COLORS][8];
	uint32_t bindings;
	uint32_t binding[FW_PIPE_BINDINGS][3];	/* number, stride, rate */
	uint32_t vertex_attributes;
	uint32_t vertex_attribute[FW_PIPE_ATTRIBUTES][4];	/* location, binding, format, offset */
};

/*
 * The pipeline being created or finished and its raw state (too large for
 * the stack; one command is decoded at a time).  pipe_block_bytes is the
 * size of a pipeline's block: the finished pipeline, then the raw state.
 */
static struct {
	struct fw_pipeline pipeline;
	struct pipe_raw raw;
} pipe_work;

/*
 * The blocks of the pipelines a create command has read, before their
 * identities are known.
 */
static uint32_t pipe_blocks[PIPE_MAX_CREATE];

static void pipe_skip_stage(struct fw_command *command);
static void pipe_read_graphics(struct fw_command *command);
static void pipe_read_compute(struct fw_command *command);
static void pipe_create(struct fw_command *command, int compute);
static int pipe_finish_graphics(struct fw_command *command, struct fw_object *object);
static int pipe_finish_compute(struct fw_command *command, uint64_t id);
static void pipe_pair(uint32_t index, uint32_t value);
static int pipe_place(struct fw_object *object);
static int pipe_program(uint32_t tag, uint64_t id, uint32_t kind, uint32_t *header, uint32_t *entries, uint32_t *code, uint32_t *words);
static void pipe_resources(const uint32_t *header, const uint32_t *entries, uint32_t stage);
static uint32_t pipe_depth_bits(uint32_t format);
static uint32_t pipe_bias_format(uint32_t format);

/*
 * The header and the interface table of a program being read (one at a
 * time).
 */
static uint32_t pipe_program_words[GSI1_HEADER_WORDS + 64u * GSI1_IFACE_WORDS];

/* CREATE_GRAPHICS_PIPELINES: [device][cache][u32 n][u64 n][infos][u64 0][u64 n][ids]. */
void
fw_cmd_create_graphics_pipelines(
	struct fw_command *command)
{
	/* Reads the infos, then makes the pipelines. */
	pipe_create(command, 0);
}

/* CREATE_COMPUTE_PIPELINES: the same with VkComputePipelineCreateInfo. */
void
fw_cmd_create_compute_pipelines(
	struct fw_command *command)
{
	/* Reads the infos, then makes the pipelines. */
	pipe_create(command, 1);
}

/* DESTROY_PIPELINE: the destroy form; the pipeline's programs go with it. */
void
fw_cmd_destroy_pipeline(
	struct fw_command *command)
{
	struct fw_object *object;
	uint64_t id;
	uint32_t kind;

	/* The destroy form. */
	id = fw_wire_destroy(command);
	if (command->reader->error)
		return;

	/* The pipeline and each of its stages' programs. */
	object = fw_object_find(command->tag, id, FW_OBJ_PIPELINE);
	if (object != NULL)
		fw_object_destroy(object);
	for (kind = FW_OBJ_PROGRAM_VS; kind <= FW_OBJ_PROGRAM_CS; kind++) {
		object = fw_object_find(command->tag, id, kind);
		if (object != NULL)
			fw_object_destroy(object);
	}
}

/*
 * Reads a pipeline's block (the finished part).
 *
 * Returns 0, or -1 when the pipeline is unknown or its block unread.
 */
int
fw_pipeline_get(
	uint32_t tag,
	uint64_t id,
	struct fw_pipeline *pipeline)
{
	struct fw_object *object;
	int error;

	/* The session's pipeline. */
	object = fw_object_find(tag, id, FW_OBJ_PIPELINE);
	if (object == NULL)
		return -1;

	/* Its block. */
	error = fw_copy_in(object->block, pipeline, sizeof(*pipeline));
	if (error != 0)
		return -1;

	/* Succeeded: the pipeline. */
	return 0;
}

/* Reads the infos into blocks, then each pipeline is made from its block and its programs. */
static void
pipe_create(
	struct fw_command *command,
	int compute)
{
	struct fw_object *object;
	uint64_t device;
	uint64_t count;
	uint64_t ids;
	uint64_t index;
	uint64_t id;
	uint32_t bytes;
	int error;

	/* [device][cache][u32 n][u64 n]. */
	device = fw_reader_u64(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > PIPE_MAX_CREATE) {
		command->reader->error = 1;
		return;
	}

	/* Each info into a block of its own. */
	bytes = sizeof(pipe_work);
	for (index = 0; index < count; index++)
		pipe_blocks[index] = 0;
	for (index = 0; index < count && !command->reader->error; index++) {
		memset(&pipe_work, 0, sizeof(pipe_work));
		if (compute) {
			pipe_read_compute(command);
		} else {
			pipe_read_graphics(command);
		}
		if (command->reader->error || command->status != FW_VK_SUCCESS)
			continue;
		pipe_blocks[index] = fw_heap_alloc(command->tag, bytes);
		if (pipe_blocks[index] == 0) {
			command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
			continue;
		}
		error = fw_copy_out(pipe_blocks[index], &pipe_work, bytes);
		if (error != 0)
			command->status = FW_VK_ERROR_DEVICE_LOST;
	}

	/* [u64 0, no allocator][u64 n][ids]. */
	fw_wire_expect(command, 0);
	ids = fw_reader_u64(command->reader);
	if (ids != count)
		command->reader->error = 1;

	/* Each pipeline: its object owns the block, finished with its programs. */
	for (index = 0; index < ids && !command->reader->error; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error || command->status != FW_VK_SUCCESS || pipe_blocks[index] == 0)
			continue;
		object = fw_cmd_new_object(command, device, id, FW_OBJ_PIPELINE);
		if (object == NULL)
			continue;
		object->block = pipe_blocks[index];
		object->lines = (uint16_t)((bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES);
		pipe_blocks[index] = 0;
		if (compute) {
			object->flags |= FW_OBJF_COMPUTE;
			error = pipe_finish_compute(command, id);
		} else {
			error = pipe_finish_graphics(command, object);
		}
		if (error == 0)
			error = pipe_place(object);
		if (error != 0) {
			fw_object_destroy(object);
			if (command->status == FW_VK_SUCCESS)
				command->status = FW_VK_ERROR_INITIALIZATION_FAILED;
		}
	}

	/* The blocks no pipeline took go back. */
	for (index = 0; index < count; index++)
		fw_heap_free(command->tag, pipe_blocks[index], bytes);
}

/*
 * Gives a finished pipeline its final block (the raw state is no longer
 * needed) and its programs' scratch memory, a visible block of its own
 * (a: its address, b: its bytes): the programs read and write it, the
 * pipeline's block is the firmware's.
 */
static int
pipe_place(
	struct fw_object *object)
{
	struct fw_pipeline *pipeline;
	uint32_t base;
	uint32_t index;
	int error;

	/* The new block replaces the one of the raw state. */
	pipeline = &pipe_work.pipeline;
	error = fw_object_block(object, sizeof(*pipeline));
	if (error != 0)
		return -1;

	/* The scratch memory, if the programs have any. */
	base = 0;
	if (pipeline->scratch_bytes != 0) {
		base = fw_heap_alloc_visible(object->tag, pipeline->scratch_bytes);
		if (base == 0)
			return -1;
		object->a = base;
		object->b = pipeline->scratch_bytes;
	}

	/* The scratch parts' addresses. */
	for (index = 0; index < pipeline->resources; index++) {
		if (pipeline->resource[index].kind == GSI1_KIND_SCRATCH)
			pipeline->resource[index].specific += base;
	}

	/* Succeeded once the pipeline is in its block. */
	error = fw_copy_out(object->block, pipeline, sizeof(*pipeline));
	if (error != 0)
		return -1;
	return 0;
}

/* Skips a VkPipelineShaderStageCreateInfo (the program came with GHCI_PROGRAM). */
static void
pipe_skip_stage(
	struct fw_command *command)
{
	uint64_t present;
	uint32_t bytes;

	/* [sType][u64 0][flags][stage][module][name]. */
	fw_wire_head(command);
	fw_reader_skip(command->reader, 16);
	fw_wire_skip_string(command);

	/* The specialization: [u32 n][u64 n][{id, offset, u64 size}][u64 bytes][u64 n][bytes]. */
	present = fw_reader_u64(command->reader);
	if (present == 0)
		return;
	fw_reader_skip(command->reader, 4);
	bytes = fw_reader_count(command->reader, 0x10000u);
	fw_reader_skip(command->reader, bytes * 16u + 8u);
	bytes = fw_reader_count(command->reader, 0x10000u);
	fw_reader_skip(command->reader, (bytes + 3u) & ~3u);
}

/* Reads a VkGraphicsPipelineCreateInfo into pipe_work. */
static void
pipe_read_graphics(
	struct fw_command *command)
{
	struct fw_pipeline *pipeline;
	struct fw_reader *reader;
	struct pipe_raw *raw;
	uint32_t words[16];
	uint32_t count;
	uint32_t index;
	uint64_t present;

	/* [sType][u64 0][flags][u32 n][u64 n][stages]. */
	pipeline = &pipe_work.pipeline;
	raw = &pipe_work.raw;
	reader = command->reader;
	fw_wire_head(command);
	fw_reader_skip(reader, 8);
	count = fw_reader_count(reader, 8);
	for (index = 0; index < count && !reader->error; index++)
		pipe_skip_stage(command);

	/* The vertex input: [u32 n][u64 n][{binding, stride, rate}][u32 n][u64 n][{location, binding, format, offset}]. */
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_skip(reader, 8);
		raw->bindings = fw_reader_count(reader, FW_PIPE_BINDINGS);
		fw_reader_words(reader, &raw->binding[0][0], 3u * raw->bindings);
		fw_reader_skip(reader, 4);
		raw->vertex_attributes = fw_reader_count(reader, FW_PIPE_ATTRIBUTES);
		fw_reader_words(reader, &raw->vertex_attribute[0][0], 4u * raw->vertex_attributes);
	}

	/* The input assembly: [flags][topology][primitive restart]. */
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_words(reader, words, 3);
		raw->topology = words[1];
		raw->restart = words[2];
	}

	/* No tessellation (the feature is not offered). */
	present = fw_reader_u64(reader);
	if (present != 0)
		reader->error = 1;

	/* The viewport state: one viewport and one scissor, unless they are dynamic. */
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_skip(reader, 8);
		count = fw_reader_count(reader, 1);
		fw_reader_words(reader, pipeline->viewport, 6u * count);
		fw_reader_skip(reader, 4);
		count = fw_reader_count(reader, 1);
		fw_reader_words(reader, pipeline->scissor, 4u * count);
	}

	/* The rasterization state (always there): [flags][clamp][discard][polygon][cull][front][bias][3 bias][width]. */
	fw_wire_expect(command, 1);
	fw_wire_head(command);
	fw_reader_words(reader, words, 11);
	raw->clamp = words[1];
	raw->discard = words[2];
	raw->cull = words[4];
	raw->front = words[5];
	raw->bias = words[6];
	memcpy(pipeline->depth_bias, &words[7], 3u * 4u);

	/* The multisample state: [flags][samples][shading][min][u64 n][mask][a2c][a2o]. */
	raw->samples = 1;
	raw->sample_mask = 0xFFFFFFFFu;
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_words(reader, words, 4);
		raw->samples = words[1];
		count = fw_reader_count(reader, 1);
		fw_reader_words(reader, &raw->sample_mask, count);
		fw_reader_words(reader, words, 2);
		raw->a2c = words[0];
		raw->a2o = words[1];
	}

	/* The depth/stencil state: [flags][test][write][op][bounds][stencil][front 7][back 7][min][max]. */
	pipeline->depth_bounds[1] = 0x3F800000u;
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_words(reader, words, 6);
		raw->depth_test = words[1];
		raw->depth_write = words[2];
		raw->depth_op = words[3];
		raw->bounds = words[4];
		raw->stencil = words[5];
		for (index = 0; index < 2u; index++) {
			fw_reader_words(reader, words, 7);
			memcpy(raw->stencil_ops[index], words, 3u * 4u);
			pipeline->stencil_op[index] = words[3];
			pipeline->stencil_compare[index] = words[4];
			pipeline->stencil_write[index] = words[5];
			pipeline->stencil_reference[index] = words[6];
		}
		fw_reader_words(reader, pipeline->depth_bounds, 2);
	}

	/* The colour blend state: [flags][logic enable][op][u32 n][u64 n][attachments][u64 4][constants]. */
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_skip(reader, 16);
		raw->blends = fw_reader_count(reader, FW_RP_COLORS);
		fw_reader_words(reader, &raw->blend[0][0], 8u * raw->blends);
		fw_wire_expect(command, 4);
		fw_reader_words(reader, pipeline->blend_constants, 4);
	}

	/* The dynamic states: [flags][u32 n][u64 n][states]. */
	present = fw_reader_u64(reader);
	if (present != 0) {
		fw_wire_head(command);
		fw_reader_skip(reader, 8);
		count = fw_reader_count(reader, 64);
		for (index = 0; index < count && !reader->error; index++) {
			words[0] = fw_reader_u32(reader);
			if (words[0] < PIPE_DYNAMIC_STATES)
				pipeline->dynamic |= 1u << words[0];
		}
	}

	/* [layout][render pass][subpass][base pipeline][base index]. */
	fw_reader_skip(reader, 8);
	raw->render_pass = fw_reader_u64(reader);
	raw->subpass = fw_reader_u32(reader);
	fw_reader_skip(reader, 12);
}

/* Reads a VkComputePipelineCreateInfo into pipe_work. */
static void
pipe_read_compute(
	struct fw_command *command)
{
	/* [sType][u64 0][flags][stage][layout][base pipeline][base index]. */
	fw_wire_head(command);
	fw_reader_skip(command->reader, 4);
	pipe_skip_stage(command);
	fw_reader_skip(command->reader, 20);
	pipe_work.pipeline.flags = FW_PIPE_COMPUTE;
}

/* Finishes a graphics pipeline from its raw state, its render pass and its programs. */
static int
pipe_finish_graphics(
	struct fw_command *command,
	struct fw_object *object)
{
	struct fw_render_pass pass;
	struct fw_pipeline *pipeline;
	struct pipe_raw *raw;
	struct fw_subpass *subpass;
	const struct fw_format *format;
	uint32_t *header;
	uint32_t *entry;
	uint32_t vs_code;
	uint32_t vs_words;
	uint32_t fs_code;
	uint32_t fs_words;
	uint32_t varyings;
	uint32_t exported;
	uint32_t fs_flags;
	uint32_t vs_bank;
	uint32_t index;
	uint32_t slot;
	uint32_t attribute;
	uint32_t binding;
	uint32_t word;
	uint32_t ds_format;
	uint32_t rt_formats;
	uint32_t write_mask;
	uint32_t value;
	uint64_t id;
	int error;

	/* The block as read. */
	pipeline = &pipe_work.pipeline;
	raw = &pipe_work.raw;
	header = pipe_program_words;
	entry = &pipe_program_words[GSI1_HEADER_WORDS];
	id = object->id;
	error = fw_copy_in(object->block, &pipe_work, sizeof(pipe_work));
	if (error != 0)
		return -1;

	/* The subpass the pipeline draws in. */
	error = fw_render_pass_get(command->tag, raw->render_pass, &pass);
	if (error != 0 || raw->subpass >= pass.subpasses)
		return -1;
	subpass = &pass.subpass[raw->subpass];
	ds_format = 0;
	if (subpass->depth != FW_RP_UNUSED)
		ds_format = pass.attachment[subpass->depth].format;
	pipeline->push_bank[0] = FW_PIPE_NO_PUSH;
	pipeline->push_bank[1] = FW_PIPE_NO_PUSH;

	/* The vertex program: its attributes, system inputs, outputs and resources. */
	error = pipe_program(command->tag, id, FW_OBJ_PROGRAM_VS, header, entry, &vs_code, &vs_words);
	if (error != 0)
		return -1;
	vs_bank = header[GSI1_H_CONST_WORDS];
	pipeline->bank_words = vs_bank;
	varyings = 0;
	slot = 0;
	for (index = 0; index < header[GSI1_H_IFACE_ENTRIES]; index++) {
		word = entry[index * GSI1_IFACE_WORDS + GSI1_IF_SPECIFIC];
		switch (entry[index * GSI1_IFACE_WORDS + GSI1_IF_KIND]) {
		case GSI1_KIND_ATTRIBUTE:
			/* The pipeline's attribute of the location, and its binding. */
			for (attribute = 0; attribute < raw->vertex_attributes; attribute++) {
				if (raw->vertex_attribute[attribute][0] == entry[index * GSI1_IFACE_WORDS + GSI1_IF_BINDING])
					break;
			}
			if (attribute == raw->vertex_attributes || slot == FW_PIPE_ATTRIBUTES)
				break;
			for (binding = 0; binding < raw->bindings; binding++) {
				if (raw->binding[binding][0] == raw->vertex_attribute[attribute][1])
					break;
			}
			if (binding == raw->bindings)
				break;
			format = fw_format_find(raw->vertex_attribute[attribute][2]);
			pipeline->attr[slot].binding = raw->vertex_attribute[attribute][1];
			pipeline->attr[slot].offset = raw->vertex_attribute[attribute][3];
			pipeline->attr[slot].desc = raw->binding[binding][1] & 0xFFFFu;
			if (raw->binding[binding][2] == PIPE_RATE_INSTANCE)
				pipeline->attr[slot].desc |= 1u << 20 | 1u << 24;
			pipeline->attr[slot].dst = (word & 0x3Fu) | ((((word >> 8) & 7u) - 1u) & 3u) << 6 |
			    (raw->vertex_attribute[attribute][2] & 0xFFu) << 24;
			pipeline->attr[slot].bytes = 4;
			if (format != NULL)
				pipeline->attr[slot].bytes = format->bytes;
			slot++;
			break;
		case GSI1_KIND_SYSTEM:
			/* The vertex or the instance index, from the identity buffer. */
			if (slot == FW_PIPE_ATTRIBUTES)
				break;
			pipeline->attr[slot].binding = FW_PIPE_SYSTEM_BINDING;
			pipeline->attr[slot].offset = 0;
			pipeline->attr[slot].desc = 4;
			if (entry[index * GSI1_IFACE_WORDS + GSI1_IF_BINDING] == GSI1_SYSTEM_INSTANCE_INDEX)
				pipeline->attr[slot].desc |= 1u << 20 | 1u << 24;
			pipeline->attr[slot].dst = (word & 0x3Fu) | (uint32_t)FW_VK_FORMAT_R32_UINT << 24;
			pipeline->attr[slot].bytes = 4;
			slot++;
			break;
		case GSI1_KIND_OUTPUT:
			/* The varying words the vertex program writes. */
			value = (word & GSI1_VARY_WORD_MASK) + ((word >> GSI1_VARY_COMPONENTS_SHIFT) & 7u);
			if (value > varyings)
				varyings = value;
			break;
		case GSI1_KIND_PUSH_CONSTANT:
			pipeline->push_bank[0] = word;
			pipeline->push_bytes[0] = header[GSI1_H_PUSH_BYTES];
			break;
		default:
			break;
		}
	}
	pipeline->attributes = slot;
	pipe_resources(header, entry, 0);

	/* The fragment program, or the built-in one that keeps every sample. */
	exported = 0;
	fs_flags = 0;
	error = pipe_program(command->tag, id, FW_OBJ_PROGRAM_FS, header, entry, &fs_code, &fs_words);
	if (error != 0) {
		fs_code = fw_builtin_program(FW_PROGRAM_MASK, &fs_words);
	} else {
		fs_flags = header[GSI1_H_FLAGS];
		if (header[GSI1_H_CONST_WORDS] > pipeline->bank_words)
			pipeline->bank_words = header[GSI1_H_CONST_WORDS];
		for (index = 0; index < header[GSI1_H_IFACE_ENTRIES]; index++) {
			word = entry[index * GSI1_IFACE_WORDS + GSI1_IF_SPECIFIC];
			switch (entry[index * GSI1_IFACE_WORDS + GSI1_IF_KIND]) {
			case GSI1_KIND_VARYING_IN:
				value = (word & GSI1_VARY_WORD_MASK) + ((word >> GSI1_VARY_COMPONENTS_SHIFT) & 7u);
				if (value > varyings)
					varyings = value;
				break;
			case GSI1_KIND_OUTPUT:
				binding = entry[index * GSI1_IFACE_WORDS + GSI1_IF_BINDING];
				if (binding < FW_RP_COLORS)
					exported |= 1u << binding;
				break;
			case GSI1_KIND_PUSH_CONSTANT:
				pipeline->push_bank[1] = word;
				pipeline->push_bytes[1] = header[GSI1_H_PUSH_BYTES];
				break;
			default:
				break;
			}
		}
		pipe_resources(header, entry, 1);
	}

	/* The vertex fetcher and the rasterizer. */
	pipeline->pairs = 0;
	pipe_pair(GHCI_S_TOPOLOGY, raw->topology & 7u);
	pipe_pair(GHCI_S_PRIM_RESTART, raw->restart & 1u);
	value = raw->cull & 3u;
	if (raw->front == PIPE_FRONT_CCW)
		value |= 1u << 2;
	pipe_pair(GHCI_S_CULL, value);
	value = PIPE_CLAMP_CLIP;
	if (raw->clamp != 0)
		value |= PIPE_CLAMP_DEPTH;
	pipe_pair(GHCI_S_DEPTH_CLAMP, value);
	value = PIPE_RAST_VIEWPORT | pipe_bias_format(ds_format) << 4;
	if (raw->bias != 0)
		value |= PIPE_RAST_BIAS;
	if (raw->discard != 0)
		value |= PIPE_RAST_DISCARD;
	pipe_pair(GHCI_S_RAST_MODE, value);
	pipe_pair(GHCI_S_VARYING_COUNT, varyings);
	pipe_pair(GHCI_S_PROVOKING, 0);
	value = 0;
	if (raw->samples == 4u)
		value = 2;
	if ((fs_flags & (1u << 5)) != 0)
		value |= PIPE_MS_CENTROID;
	if (raw->a2c != 0)
		value |= PIPE_MS_A2C;
	if (raw->a2o != 0)
		value |= PIPE_MS_A2O;
	pipe_pair(GHCI_S_MS_CTRL, value);
	value = 0;
	if (raw->samples == 4u)
		value = ~raw->sample_mask & 0xFu;
	pipe_pair(GHCI_S_SAMPLE_KILL, value);

	/* The depth and stencil tests, for the subpass's depth/stencil format. */
	value = pipe_depth_bits(ds_format);
	if (value != 0) {
		if (raw->depth_test != 0)
			value |= PIPE_DEPTH_TEST | (raw->depth_op & 7u) << 2;
		if (raw->depth_test != 0 && raw->depth_write != 0)
			value |= PIPE_DEPTH_WRITE;
		if (raw->stencil != 0 && ds_format == FW_VK_FORMAT_D24_UNORM_S8_UINT)
			value |= PIPE_DEPTH_STENCIL;
		if (raw->bounds != 0)
			value |= PIPE_DEPTH_BOUNDS;
	}
	pipe_pair(GHCI_S_DEPTH, value);
	value = (raw->stencil_ops[0][0] & 7u) | (raw->stencil_ops[0][1] & 7u) << 3 |
	    (raw->stencil_ops[0][2] & 7u) << 6 | (raw->stencil_ops[1][0] & 7u) << 16 |
	    (raw->stencil_ops[1][1] & 7u) << 19 | (raw->stencil_ops[1][2] & 7u) << 22;
	pipe_pair(GHCI_S_STENCIL_OPS, value);

	/* The colour attachments: formats, blending, write masks (only what the program exports). */
	rt_formats = 0;
	write_mask = 0;
	for (index = 0; index < FW_RP_COLORS; index++) {
		value = 0;
		if (index < raw->blends && raw->blend[index][0] != 0) {
			value = 1u | (raw->blend[index][1] & 0xFu) << 1 | (raw->blend[index][2] & 0xFu) << 5 |
			    (raw->blend[index][3] & 7u) << 9 | (raw->blend[index][4] & 0xFu) << 12 |
			    (raw->blend[index][5] & 0xFu) << 16 | (raw->blend[index][6] & 7u) << 20;
		}
		if (index == 0) {
			pipe_pair(GHCI_S_BLEND, value);
		} else {
			pipe_pair(GHCI_S_BLEND1 + index - 1u, value);
		}
		if (index >= subpass->colors || subpass->color[index] == FW_RP_UNUSED)
			continue;
		rt_formats |= (pass.attachment[subpass->color[index]].format & 0xFFu) << (8u * index);
		if (index < raw->blends && (exported & (1u << index)) != 0)
			write_mask |= (raw->blend[index][7] & 0xFu) << (4u * index);
	}
	pipe_pair(GHCI_S_WRITE_MASK, write_mask);
	pipe_pair(GHCI_S_RT_FORMATS, rt_formats);

	/* The programs. */
	pipe_pair(GHCI_S_VS_BASE, vs_code);
	pipe_pair(GHCI_S_VS_WORDS, vs_words);
	pipe_pair(GHCI_S_FS_BASE, fs_code);
	pipe_pair(GHCI_S_FS_WORDS, fs_words);
	pipe_pair(GHCI_S_VS_OUT_WORDS, varyings);

	/* Every attribute slot: those the program reads, the others off. */
	for (index = 0; index < FW_PIPE_ATTRIBUTES; index++) {
		value = 0;
		word = 0;
		if (index < pipeline->attributes) {
			value = pipeline->attr[index].dst;
			word = pipeline->attr[index].desc;
		}
		pipe_pair(GHCI_S_ATTR_DST + index, value);
		pipe_pair(PIPE_S_ATTR_DESC(index), word);
	}

	/* Succeeded: the pipeline is finished. */
	return 0;
}

/* Finishes a compute pipeline from its program. */
static int
pipe_finish_compute(
	struct fw_command *command,
	uint64_t id)
{
	struct fw_pipeline *pipeline;
	uint32_t *header;
	uint32_t *entry;
	uint32_t code;
	uint32_t words;
	uint32_t index;
	int error;

	/* The compute program. */
	pipeline = &pipe_work.pipeline;
	memset(pipeline, 0, sizeof(*pipeline));
	pipeline->flags = FW_PIPE_COMPUTE;
	pipeline->push_bank[0] = FW_PIPE_NO_PUSH;
	pipeline->push_bank[1] = FW_PIPE_NO_PUSH;
	header = pipe_program_words;
	entry = &pipe_program_words[GSI1_HEADER_WORDS];
	error = pipe_program(command->tag, id, FW_OBJ_PROGRAM_CS, header, entry, &code, &words);
	if (error != 0)
		return -1;

	/* Its bank, push constants and resources. */
	pipeline->bank_words = header[GSI1_H_CONST_WORDS];
	for (index = 0; index < header[GSI1_H_IFACE_ENTRIES]; index++) {
		if (entry[index * GSI1_IFACE_WORDS + GSI1_IF_KIND] == GSI1_KIND_PUSH_CONSTANT) {
			pipeline->push_bank[0] = entry[index * GSI1_IFACE_WORDS + GSI1_IF_SPECIFIC];
			pipeline->push_bytes[0] = header[GSI1_H_PUSH_BYTES];
		}
	}
	pipe_resources(header, entry, 2);

	/* The program range: the code, the shared memory, the workgroup. */
	pipeline->pairs = 0;
	pipe_pair(GHCI_S_CS_BASE, code);
	pipe_pair(GHCI_S_CS_WORDS, words);
	pipe_pair(GHCI_S_LDS_BYTES, header[GSI1_H_LDS_BYTES]);
	pipe_pair(GHCI_S_WG_SIZE, header[GSI1_H_WG_SIZE]);

	/* Succeeded: the pipeline is finished. */
	return 0;
}

/* Adds one STATE word the pipeline writes. */
static void
pipe_pair(
	uint32_t index,
	uint32_t value)
{
	struct fw_pipeline *pipeline;

	/* The pairs never pass their array: the pipeline writes a fixed set. */
	pipeline = &pipe_work.pipeline;
	if (pipeline->pairs == FW_PIPE_PAIRS)
		return;
	pipeline->pair[pipeline->pairs][0] = index;
	pipeline->pair[pipeline->pairs][1] = value;
	pipeline->pairs++;
}

/*
 * Reads a pipeline's program of a stage: its header and interface table,
 * and the code's address and words.
 *
 * Returns 0, or -1 when the stage has no program.
 */
static int
pipe_program(
	uint32_t tag,
	uint64_t id,
	uint32_t kind,
	uint32_t *header,
	uint32_t *entries,
	uint32_t *code,
	uint32_t *words)
{
	struct fw_object *program;
	int error;

	/* The program GHCI_PROGRAM gave the stage. */
	program = fw_object_find(tag, id, kind);
	if (program == NULL)
		return -1;

	/* Its header and table (the block holds them back to back). */
	(void)entries;
	error = fw_copy_in(program->block, header, (GSI1_HEADER_WORDS + program->c * GSI1_IFACE_WORDS) * 4u);
	if (error != 0)
		return -1;

	/* Succeeded: the code. */
	*code = program->a;
	*words = program->b;
	return 0;
}

/* Adds a program's resources (the entries the constant bank and the texture slots bind, and scratch). */
static void
pipe_resources(
	const uint32_t *header,
	const uint32_t *entries,
	uint32_t stage)
{
	struct fw_pipeline *pipeline;
	struct fw_pipe_resource *resource;
	uint32_t index;
	uint32_t kind;
	uint32_t bytes;

	/* Each entry of a resource kind, while there is room. */
	pipeline = &pipe_work.pipeline;
	for (index = 0; index < header[GSI1_H_IFACE_ENTRIES]; index++) {
		kind = entries[index * GSI1_IFACE_WORDS + GSI1_IF_KIND];
		if (kind < GSI1_KIND_UNIFORM_BLOCK || kind == GSI1_KIND_PUSH_CONSTANT ||
		    kind == GSI1_KIND_SHARED || kind == GSI1_KIND_SYSTEM)
			continue;
		if (pipeline->resources == FW_PIPE_RESOURCES)
			return;
		resource = &pipeline->resource[pipeline->resources];
		resource->kind = kind;
		resource->set = entries[index * GSI1_IFACE_WORDS + GSI1_IF_SET];
		resource->binding = entries[index * GSI1_IFACE_WORDS + GSI1_IF_BINDING];
		resource->specific = entries[index * GSI1_IFACE_WORDS + GSI1_IF_SPECIFIC];
		resource->stage = stage;
		pipeline->resources++;

		/*
		 * Scratch memory: each resident warp's part, in the
		 * pipeline's scratch block; `specific` becomes the part's
		 * offset there (the address once the block is known).
		 */
		if (kind == GSI1_KIND_SCRATCH) {
			bytes = resource->specific * fw_heap_warps();
			resource->specific = pipeline->scratch_bytes;
			pipeline->scratch_bytes += FW_ROUND_LINES(bytes);
		}
	}
}

/* The DEPTH format bit of a depth/stencil format (0: no depth test). */
static uint32_t
pipe_depth_bits(
	uint32_t format)
{
	/* One bit per format. */
	switch (format) {
	case FW_VK_FORMAT_D16_UNORM:
		return PIPE_DEPTH_D16;
	case FW_VK_FORMAT_X8_D24_UNORM_PACK32:
	case FW_VK_FORMAT_D24_UNORM_S8_UINT:
		return PIPE_DEPTH_D24;
	case FW_VK_FORMAT_D32_SFLOAT:
		return PIPE_DEPTH_D32F;
	default:
		return 0;
	}
}

/* RAST_MODE[5:4]: the depth format the bias is for. */
static uint32_t
pipe_bias_format(
	uint32_t format)
{
	/* 1 D16, 2 D24, 3 D32_SFLOAT, 0 none. */
	switch (format) {
	case FW_VK_FORMAT_D16_UNORM:
		return 1;
	case FW_VK_FORMAT_X8_D24_UNORM_PACK32:
	case FW_VK_FORMAT_D24_UNORM_S8_UINT:
		return 2;
	case FW_VK_FORMAT_D32_SFLOAT:
		return 3;
	default:
		return 0;
	}
}
