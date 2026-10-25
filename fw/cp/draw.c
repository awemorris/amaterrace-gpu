/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Draws and dispatches: each becomes, in the recording, the bound
 * pipeline's STATE words (when another pipeline was last written), the
 * dynamic or static viewport, scissor, stencil, bias, blend constants and
 * depth bounds, the vertex attributes' addresses and limits, the texture
 * slots and the constant bank of the bound descriptor sets and push
 * constants, and DRAW or DISPATCH.
 *
 * The constant bank is composed when the command is recorded and kept in
 * the recording as data, with the descriptors' words and the push
 * constants in place; a uniform block's words, which the buffer holds
 * when the draw runs, are copied into the bank image by blits recorded
 * before its LOAD_CONST.  Descriptors may be snapshotted: Vulkan makes a
 * command buffer invalid when a set it bound is updated.
 */

#include "fw.h"
#include "ghci_packets.h"
#include "ghci_regs.h"
#include "gsi1_isa.h"

/* The constant bank's words, and the uniform blocks one draw may copy into it. */
#define DRAW_BANK_WORDS 256u
#define DRAW_COPIES 16u

/* STATE indices the shared header does not name. */
#define DRAW_S_VS_TEX 0x200u		/* the vertex stage's texture slots (CAPS[30]) */
#define DRAW_ROP_CTRL_FP32 (1u << 1)	/* ROP_CTRL: the fp32 blend constants */

/* The fp32 bits of 1.0. */
#define DRAW_ONE 0x3F800000u

/* The flags of the indirect marker: what the arguments are. */
#define DRAW_INDIRECT_DRAW 0u
#define DRAW_INDIRECT_INDEXED 1u
#define DRAW_INDIRECT_DISPATCH 2u

/* One uniform block copied into the bank when the draw runs. */
struct draw_copy {
	uint32_t source;
	uint32_t word;
	uint32_t words;
};

/*
 * The pipeline of the draw being recorded, its bank image and its block
 * copies (too large for the stack; one command is decoded at a time).
 */
static struct fw_pipeline draw_pipeline;
static uint32_t draw_bank[DRAW_BANK_WORDS];
static struct draw_copy draw_copies[DRAW_COPIES];
static uint32_t draw_copy_count;

static int draw_prepare(struct fw_command *command, struct fw_object *cmdbuf, struct fw_rstate *state, uint32_t point);
static void draw_dynamic(const struct fw_rstate *state);
static void draw_viewport(const uint32_t *viewport);
static void draw_scissor(const uint32_t *scissor);
static void draw_attributes(const struct fw_rstate *state);
static int draw_resources(struct fw_command *command, const struct fw_rstate *state, uint32_t point);
static int draw_resource(struct fw_command *command, const struct fw_pipe_resource *resource, const struct fw_rstate *state, uint32_t point);
static void draw_texture(uint32_t stage, uint32_t slot, const struct fw_view *view, uint32_t sampler, uint32_t lod);
static void draw_bank_emit(void);
static uint32_t draw_half(uint32_t bits);
static void draw_finish(struct fw_object *cmdbuf);

/* CMD_DRAW: [cb][vertices][instances][first vertex][first instance]. */
void
fw_cmd_draw(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t count;
	uint32_t instances;
	uint32_t first;
	uint32_t first_instance;
	uint64_t id;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	count = fw_reader_u32(command->reader);
	instances = fw_reader_u32(command->reader);
	first = fw_reader_u32(command->reader);
	first_instance = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* The draw's state, its parameters, DRAW. */
	fw_emit_begin(cmdbuf, command->tag);
	error = draw_prepare(command, cmdbuf, state, FW_BIND_GRAPHICS);
	if (error == 0) {
		fw_emit_set(GHCI_S_INDEX_FORMAT, 0);
		fw_emit_set(GHCI_S_FIRST, first);
		fw_emit_set(GHCI_S_COUNT, count);
		fw_emit_set(GHCI_S_INSTANCE_COUNT, instances);
		fw_emit_set(GHCI_S_FIRST_INSTANCE, first_instance);
		fw_emit_set(GHCI_S_VERTEX_OFFSET, 0);
		fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
	}
	draw_finish(cmdbuf);
}

/* CMD_DRAW_INDEXED: [cb][indices][instances][first index][vertex offset][first instance]. */
void
fw_cmd_draw_indexed(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t count;
	uint32_t instances;
	uint32_t first;
	uint32_t offset;
	uint32_t first_instance;
	uint64_t id;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	count = fw_reader_u32(command->reader);
	instances = fw_reader_u32(command->reader);
	first = fw_reader_u32(command->reader);
	offset = fw_reader_u32(command->reader);
	first_instance = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* An index buffer is bound. */
	if (state->ib_format == 0) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The draw's state, the indices, DRAW. */
	fw_emit_begin(cmdbuf, command->tag);
	error = draw_prepare(command, cmdbuf, state, FW_BIND_GRAPHICS);
	if (error == 0) {
		fw_emit_set(GHCI_S_INDEX_BASE, state->ib_address);
		fw_emit_set(GHCI_S_INDEX_FORMAT, state->ib_format);
		fw_emit_set(GHCI_S_FIRST, first);
		fw_emit_set(GHCI_S_COUNT, count);
		fw_emit_set(GHCI_S_INSTANCE_COUNT, instances);
		fw_emit_set(GHCI_S_FIRST_INSTANCE, first_instance);
		fw_emit_set(GHCI_S_VERTEX_OFFSET, offset);
		fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
	}
	draw_finish(cmdbuf);
}

/*
 * CMD_DRAW_INDIRECT and CMD_DRAW_INDEXED_INDIRECT: [cb][buffer][u64
 * offset][count][stride].  The parameters are in GPU memory when the
 * draw runs: a marker lets the replay read them then.
 */
static void
draw_indirect(
	struct fw_command *command,
	uint32_t kind)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	struct fw_rstate *state;
	uint32_t marker[5];
	uint64_t id;
	uint64_t buffer_id;
	uint64_t offset;
	uint32_t count;
	uint32_t stride;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	offset = fw_reader_u64(command->reader);
	count = 1;
	stride = 0;
	if (kind != DRAW_INDIRECT_DISPATCH) {
		count = fw_reader_u32(command->reader);
		stride = fw_reader_u32(command->reader);
	}
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* A bound buffer, the parameters word aligned inside it. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offset > buffer->b || (offset & 3u) != 0 ||
	    (kind == DRAW_INDIRECT_INDEXED && state->ib_format == 0)) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The draw's or dispatch's state, the index buffer, then the marker in place of DRAW. */
	fw_emit_begin(cmdbuf, command->tag);
	error = draw_prepare(command, cmdbuf, state, kind == DRAW_INDIRECT_DISPATCH ? FW_BIND_COMPUTE : FW_BIND_GRAPHICS);
	if (error == 0) {
		if (kind == DRAW_INDIRECT_INDEXED) {
			fw_emit_set(GHCI_S_INDEX_BASE, state->ib_address);
			fw_emit_set(GHCI_S_INDEX_FORMAT, state->ib_format);
		} else if (kind == DRAW_INDIRECT_DRAW) {
			fw_emit_set(GHCI_S_INDEX_FORMAT, 0);
		}
		marker[0] = kind;
		marker[1] = buffer->a + (uint32_t)offset;
		marker[2] = count;
		marker[3] = stride;
		marker[4] = buffer->b - (uint32_t)offset;
		fw_emit_marker(FW_MARK_INDIRECT, marker, 5);
	}
	draw_finish(cmdbuf);
}

/* CMD_DRAW_INDIRECT. */
void
fw_cmd_draw_indirect(
	struct fw_command *command)
{
	/* VkDrawIndirectCommand: vertices, instances, first vertex, first instance. */
	draw_indirect(command, DRAW_INDIRECT_DRAW);
}

/* CMD_DRAW_INDEXED_INDIRECT. */
void
fw_cmd_draw_indexed_indirect(
	struct fw_command *command)
{
	/* VkDrawIndexedIndirectCommand: indices, instances, first index, vertex offset, first instance. */
	draw_indirect(command, DRAW_INDIRECT_INDEXED);
}

/* CMD_DISPATCH_INDIRECT: [cb][buffer][u64 offset]. */
void
fw_cmd_dispatch_indirect(
	struct fw_command *command)
{
	/* VkDispatchIndirectCommand: x, y, z. */
	draw_indirect(command, DRAW_INDIRECT_DISPATCH);
}

/* CMD_DISPATCH: [cb][x][y][z]. */
void
fw_cmd_dispatch(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t groups[3];
	uint64_t id;
	uint32_t index;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	for (index = 0; index < 3u; index++)
		groups[index] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* The dispatch's state, then DISPATCH (which invalidates no cache: INVALIDATE first). */
	fw_emit_begin(cmdbuf, command->tag);
	error = draw_prepare(command, cmdbuf, state, FW_BIND_COMPUTE);
	if (error == 0)
		fw_emit_op(GHCI_OP_DISPATCH, 0, groups, 3);
	draw_finish(cmdbuf);
}

/*
 * Ends the recording of a draw or a dispatch: a failure to build its µops
 * fails the command buffer.
 */
static void
draw_finish(
	struct fw_object *cmdbuf)
{
	int error;

	/* The last packet goes into the recording. */
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/*
 * Builds the state of a draw (FW_BIND_GRAPHICS) or a dispatch
 * (FW_BIND_COMPUTE) from the recording state.
 *
 * Returns 0, or -1 (with the command buffer's failure) when the bound
 * state cannot draw.
 */
static int
draw_prepare(
	struct fw_command *command,
	struct fw_object *cmdbuf,
	struct fw_rstate *state,
	uint32_t point)
{
	uint32_t index;
	int error;

	/* The bound pipeline; a draw needs a render pass, a dispatch none. */
	error = fw_pipeline_get(command->tag, state->pipeline[point], &draw_pipeline);
	if (error != 0 || (point == FW_BIND_GRAPHICS && !state->in_pass) ||
	    (point == FW_BIND_COMPUTE && state->in_pass)) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return -1;
	}

	/* The pipeline's STATE words and the program change, unless written last. */
	if (state->emitted[point] != state->pipeline[point]) {
		for (index = 0; index < draw_pipeline.pairs; index++)
			fw_emit_set(draw_pipeline.pair[index][0], draw_pipeline.pair[index][1]);
		index = 0;
		fw_emit_op(GHCI_OP_LOAD_PROGRAM, 0, &index, 1);
		state->emitted[point] = state->pipeline[point];
	}

	/* A draw's dynamic or static state and its vertex attributes. */
	if (point == FW_BIND_GRAPHICS) {
		draw_dynamic(state);
		draw_attributes(state);
	}

	/* The texture slots and the constant bank. */
	error = draw_resources(command, state, point);
	if (error != 0) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return -1;
	}

	/* A dispatch reads memory written before it: the caches start afresh. */
	if (point == FW_BIND_COMPUTE)
		fw_emit_op(GHCI_OP_INVALIDATE, 0x3u, NULL, 0);

	/* Succeeded: DRAW or DISPATCH may follow. */
	return 0;
}

/* The viewport, scissor, stencil, depth bias, blend constants and depth bounds of a draw. */
static void
draw_dynamic(
	const struct fw_rstate *state)
{
	const uint32_t *values;
	uint32_t compare[2];
	uint32_t write[2];
	uint32_t reference[2];
	uint32_t dynamic;
	uint32_t face;
	uint32_t index;

	/* Each value from the command buffer when the pipeline makes it dynamic. */
	dynamic = draw_pipeline.dynamic;
	values = draw_pipeline.viewport;
	if ((dynamic & FW_DYN_VIEWPORT) != 0)
		values = state->viewport;
	draw_viewport(values);
	values = draw_pipeline.scissor;
	if ((dynamic & FW_DYN_SCISSOR) != 0)
		values = state->scissor;
	draw_scissor(values);

	/* The stencil faces: reference, compare mask, write mask, compare op. */
	for (face = 0; face < 2u; face++) {
		compare[face] = draw_pipeline.stencil_compare[face];
		if ((dynamic & FW_DYN_STENCIL_COMPARE_MASK) != 0)
			compare[face] = state->stencil_compare[face];
		write[face] = draw_pipeline.stencil_write[face];
		if ((dynamic & FW_DYN_STENCIL_WRITE_MASK) != 0)
			write[face] = state->stencil_write[face];
		reference[face] = draw_pipeline.stencil_reference[face];
		if ((dynamic & FW_DYN_STENCIL_REFERENCE) != 0)
			reference[face] = state->stencil_reference[face];
	}
	fw_emit_set(GHCI_S_STENCIL_FRONT, (reference[0] & 0xFFu) | (compare[0] & 0xFFu) << 8 |
		    (write[0] & 0xFFu) << 16 | (draw_pipeline.stencil_op[0] & 7u) << 24);
	fw_emit_set(GHCI_S_STENCIL_BACK, (reference[1] & 0xFFu) | (compare[1] & 0xFFu) << 8 |
		    (write[1] & 0xFFu) << 16 | (draw_pipeline.stencil_op[1] & 7u) << 24);

	/* The depth bias: constant, clamp, slope (the STATE order is constant, slope, clamp). */
	values = draw_pipeline.depth_bias;
	if ((dynamic & FW_DYN_DEPTH_BIAS) != 0)
		values = state->depth_bias;
	fw_emit_set(GHCI_S_DEPTH_BIAS_CONST, values[0]);
	fw_emit_set(GHCI_S_DEPTH_BIAS_SLOPE, values[2]);
	fw_emit_set(GHCI_S_DEPTH_BIAS_CLAMP, values[1]);

	/* The blend constants (fp32) and the depth bounds. */
	values = draw_pipeline.blend_constants;
	if ((dynamic & FW_DYN_BLEND_CONSTANTS) != 0)
		values = state->blend_constants;
	for (index = 0; index < 4u; index++)
		fw_emit_set(GHCI_S_BLEND_CONST_R + index, values[index]);
	values = draw_pipeline.depth_bounds;
	if ((dynamic & FW_DYN_DEPTH_BOUNDS) != 0)
		values = state->depth_bounds;
	fw_emit_set(GHCI_S_DEPTH_BOUNDS_MIN, values[0]);
	fw_emit_set(GHCI_S_DEPTH_BOUNDS_MAX, values[1]);

	/* The fp32 blend constants, and the occlusion counter while a query is active. */
	fw_emit_set(GHCI_S_ROP_CTRL, DRAW_ROP_CTRL_FP32 | (state->occlusion & 1u));
}

/*
 * The viewport transform: x, y, width and height rounded to whole pixels
 * first (viewportSubPixelBits is 0), then window = offset + scale x NDC.
 */
static void
draw_viewport(
	const uint32_t *viewport)
{
	int32_t x;
	int32_t y;
	int32_t width;
	int32_t height;

	/* The rectangle in whole pixels. */
	x = fw_f32_fixed(viewport[0], 0, -0x8000, 0x7FFF);
	y = fw_f32_fixed(viewport[1], 0, -0x8000, 0x7FFF);
	width = fw_f32_fixed(viewport[2], 0, -0x8000, 0x7FFF);
	height = fw_f32_fixed(viewport[3], 0, -0x8000, 0x7FFF);

	/* Scale w/2 and offset x + w/2, exactly (a negative height flips y). */
	fw_emit_set(GHCI_S_VIEWPORT + 0u, draw_half(fw_f32_from_int(width)));
	fw_emit_set(GHCI_S_VIEWPORT + 1u, draw_half(fw_f32_from_int(height)));
	fw_emit_set(GHCI_S_VIEWPORT + 2u, draw_half(fw_f32_from_int(2 * x + width)));
	fw_emit_set(GHCI_S_VIEWPORT + 3u, draw_half(fw_f32_from_int(2 * y + height)));

	/* Depth: scale maxDepth - minDepth, offset minDepth. */
	fw_emit_set(GHCI_S_VIEWPORT + 4u, fw_f32_add(viewport[5], viewport[4] ^ 0x80000000u));
	fw_emit_set(GHCI_S_VIEWPORT + 5u, viewport[4]);
}

/* The scissor rectangle; an empty one keeps nothing (0 would mean no scissor). */
static void
draw_scissor(
	const uint32_t *scissor)
{
	uint32_t x;
	uint32_t y;
	uint32_t right;
	uint32_t bottom;

	/* The corners, clamped to the 16-bit coordinates. */
	x = scissor[0];
	y = scissor[1];
	if (x > 0xFFFFu)
		x = 0xFFFFu;
	if (y > 0xFFFFu)
		y = 0xFFFFu;
	right = x + scissor[2];
	bottom = y + scissor[3];
	if (scissor[2] > 0xFFFFu || right > 0xFFFFu)
		right = 0xFFFFu;
	if (scissor[3] > 0xFFFFu || bottom > 0xFFFFu)
		bottom = 0xFFFFu;

	/* An empty rectangle at (1, 1). */
	if (right <= x || bottom <= y) {
		x = 1;
		y = 1;
		right = 1;
		bottom = 1;
	}
	fw_emit_set(GHCI_S_SCISSOR_MIN, y << 16 | x);
	fw_emit_set(GHCI_S_SCISSOR_MAX, bottom << 16 | right);
}

/* Each attribute slot's address and limit, from the bound vertex buffers. */
static void
draw_attributes(
	const struct fw_rstate *state)
{
	const struct fw_pipe_attr *attr;
	uint32_t index;
	uint32_t base;
	uint32_t bytes;
	uint32_t limit;

	/* The pipeline's slots; the identity buffer for the system inputs. */
	for (index = 0; index < draw_pipeline.attributes; index++) {
		attr = &draw_pipeline.attr[index];
		if (attr->binding == FW_PIPE_SYSTEM_BINDING) {
			base = fw_builtin_identity();
			bytes = FW_IDENTITY_WORDS * 4u;
		} else {
			base = state->vb_address[attr->binding & (FW_VERTEX_BUFFERS - 1u)];
			bytes = state->vb_bytes[attr->binding & (FW_VERTEX_BUFFERS - 1u)];
		}

		/* The limit past the attribute's offset: reads beyond it give (0, 0, 0, 1). */
		limit = 0;
		if (bytes > attr->offset)
			limit = bytes - attr->offset;
		fw_emit_set(GHCI_S_ATTR + 2u * index, base + attr->offset);
		fw_emit_set(GHCI_S_ATTR_LIMIT + index, 0x80000000u | (limit & 0x7FFFFFFFu));
	}
}

/* The texture slots and the constant bank of the bound sets and push constants. */
static int
draw_resources(
	struct fw_command *command,
	const struct fw_rstate *state,
	uint32_t point)
{
	uint32_t index;
	uint32_t stage;
	uint32_t bytes;
	int error;

	/* The bank starts at zero; the push constants of each stage at their words. */
	memset(draw_bank, 0, sizeof(draw_bank));
	draw_copy_count = 0;
	for (stage = 0; stage < 2u; stage++) {
		if (draw_pipeline.push_bank[stage] == FW_PIPE_NO_PUSH)
			continue;
		bytes = draw_pipeline.push_bytes[stage];
		if (bytes > FW_PUSH_BYTES)
			bytes = FW_PUSH_BYTES;
		if (draw_pipeline.push_bank[stage] + (bytes + 3u) / 4u > DRAW_BANK_WORDS)
			return -1;
		memcpy(&draw_bank[draw_pipeline.push_bank[stage]], state->push, bytes);
	}

	/* Each resource of the programs. */
	for (index = 0; index < draw_pipeline.resources; index++) {
		error = draw_resource(command, &draw_pipeline.resource[index], state, point);
		if (error != 0)
			return -1;
	}

	/* The bank image, its uniform blocks, LOAD_CONST. */
	if (draw_pipeline.bank_words != 0)
		draw_bank_emit();

	/* Succeeded: the draw's resources are bound. */
	return 0;
}

/* Binds one resource: its descriptor's words into the bank or a texture slot. */
static int
draw_resource(
	struct fw_command *command,
	const struct fw_pipe_resource *resource,
	const struct fw_rstate *state,
	uint32_t point)
{
	struct fw_descriptor descriptor;
	struct fw_object *set;
	struct fw_object *object;
	struct fw_view view;
	const struct fw_format *format;
	uint32_t bank;
	uint32_t index;
	uint32_t dynamic;
	uint32_t address;
	uint32_t elements;
	uint32_t words;
	int error;

	/* Scratch memory is the pipeline's own: its address in the bank word. */
	if (resource->kind == GSI1_KIND_SCRATCH) {
		if (resource->binding >= DRAW_BANK_WORDS)
			return -1;
		draw_bank[resource->binding] = resource->specific;
		return 0;
	}

	/* The descriptor of the bound set (element 0 of the binding). */
	if (resource->set >= FW_SETS)
		return -1;
	set = fw_object_find(command->tag, state->sets[point][resource->set], FW_OBJ_DESC_SET);
	if (set == NULL)
		return -1;
	error = fw_descriptor_lookup(set, resource->binding, 0, &index, &dynamic);
	if (error == 0)
		error = fw_descriptor_get(set, index, &descriptor);
	if (error != 0)
		return -1;

	/* A dynamic buffer's offset. */
	address = descriptor.address;
	if (dynamic != FW_NO_DYNAMIC && dynamic < FW_SET_DYNAMIC)
		address += state->dynamic[point][resource->set][dynamic];

	/* An image: its view's words. */
	memset(&view, 0, sizeof(view));
	if (resource->kind == GSI1_KIND_SAMPLED_IMAGE ||
	    resource->kind == GSI1_KIND_INPUT_ATTACHMENT ||
	    resource->kind == GSI1_KIND_STORAGE_IMAGE) {
		if ((resource->specific & GSI1_TEX_BUFFER) == 0 || resource->kind != GSI1_KIND_SAMPLED_IMAGE) {
			object = fw_object_find(command->tag, descriptor.object, FW_OBJ_IMAGE_VIEW);
			if (object == NULL)
				return -1;
			error = fw_copy_in(object->block, &view, sizeof(view));
			if (error != 0)
				return -1;
		}
	}

	/* The words of each kind. */
	bank = resource->specific;
	switch (resource->kind) {
	case GSI1_KIND_UNIFORM_BLOCK:
		/* The block's words, copied into the bank when the draw runs. */
		bank = resource->specific & GSI1_UBO_BANK_MASK;
		words = (resource->specific >> GSI1_UBO_WORDS_SHIFT) & GSI1_UBO_WORDS_MASK;
		if (draw_copy_count == DRAW_COPIES || bank + words > DRAW_BANK_WORDS)
			return -1;
		draw_copies[draw_copy_count].source = address +
		    ((resource->specific >> GSI1_UBO_FIRST_SHIFT) & GSI1_UBO_FIRST_MASK) * 4u;
		draw_copies[draw_copy_count].word = bank;
		draw_copies[draw_copy_count].words = words;
		draw_copy_count++;
		return 0;
	case GSI1_KIND_SAMPLED_IMAGE:
		if ((resource->specific & GSI1_TEX_BUFFER) == 0) {
			draw_texture(resource->stage, resource->specific & GSI1_TEX_SLOT_MASK, &view,
				     descriptor.sampler, descriptor.lod);
			return 0;
		}

		/* A uniform texel buffer: a 2D image 256 texels wide, and its element count. */
		format = fw_format_find((uint32_t)descriptor.object);
		elements = 0;
		if (format != NULL)
			elements = descriptor.bytes / format->bytes;
		view.base = address;
		view.tex_size = ((elements + GSI1_TEXEL_BUFFER_WIDTH - 1u) / GSI1_TEXEL_BUFFER_WIDTH) << 16 |
		    GSI1_TEXEL_BUFFER_WIDTH;
		view.tex_image = GHCI_IMG_LEVELS(1);
		view.tex_format = GHCI_TFMT_VKFORMAT(descriptor.object);
		draw_texture(resource->stage, resource->specific & GSI1_TEX_SLOT_MASK, &view, 0, 0);
		bank = (resource->specific >> GSI1_TEX_COUNT_SHIFT) & GSI1_TEX_COUNT_MASK;
		draw_bank[bank] = elements;
		return 0;
	case GSI1_KIND_STORAGE_BUFFER:
	case GSI1_KIND_UNIFORM_MEMORY:
		/* {address, bytes}. */
		if (bank + 2u > DRAW_BANK_WORDS)
			return -1;
		draw_bank[bank] = address;
		draw_bank[bank + 1u] = descriptor.bytes;
		return 0;
	case GSI1_KIND_TEXEL_BUFFER:
		/* {base, elements}. */
		format = fw_format_find((uint32_t)descriptor.object);
		if (bank + 2u > DRAW_BANK_WORDS || format == NULL)
			return -1;
		draw_bank[bank] = address;
		draw_bank[bank + 1u] = descriptor.bytes / format->bytes;
		return 0;
	case GSI1_KIND_INPUT_ATTACHMENT:
		/* {base, row bytes, samples | pixel bytes << 8}. */
		if (bank + 3u > DRAW_BANK_WORDS)
			return -1;
		draw_bank[bank] = view.base;
		draw_bank[bank + 1u] = view.row;
		draw_bank[bank + 2u] = view.samples | view.texel_bytes << 8;
		return 0;
	case GSI1_KIND_STORAGE_IMAGE:
		/* {base, row bytes, w | h << 16, layers, layer bytes}. */
		if (bank + 5u > DRAW_BANK_WORDS)
			return -1;
		draw_bank[bank] = view.base;
		draw_bank[bank + 1u] = view.row;
		draw_bank[bank + 2u] = view.width | view.height << 16;
		draw_bank[bank + 3u] = view.layers;
		draw_bank[bank + 4u] = view.layer_stride;
		return 0;
	default:
		return 0;
	}
}

/* Writes a texture slot of a stage (the vertex stage's slots are at 0x200, CAPS[30]). */
static void
draw_texture(
	uint32_t stage,
	uint32_t slot,
	const struct fw_view *view,
	uint32_t sampler,
	uint32_t lod)
{
	uint32_t first;

	/* The stage's slot. */
	first = GHCI_S_TU + 16u * slot;
	if (stage == 0)
		first = DRAW_S_VS_TEX + 16u * slot;

	/* Its seven words. */
	fw_emit_set(first + GHCI_TEX_BASE, view->base);
	fw_emit_set(first + GHCI_TEX_SIZE, view->tex_size);
	fw_emit_set(first + GHCI_TEX_IMAGE, view->tex_image);
	fw_emit_set(first + GHCI_TEX_LAYER_STRIDE, view->layer_stride);
	fw_emit_set(first + GHCI_TEX_SAMPLER, sampler);
	fw_emit_set(first + GHCI_TEX_LOD, lod);
	fw_emit_set(first + GHCI_TEX_FORMAT, view->tex_format);
	fw_emit_set(first + GHCI_TEX_ROW, view->tex_row);
}

/* The bank image as data in the recording, the blocks' copies into it, LOAD_CONST. */
static void
draw_bank_emit(void)
{
	struct fw_blt blt;
	uint32_t payload[3];
	uint32_t address;
	uint32_t index;
	uint32_t words;

	/* The image with the descriptors' words and the push constants. */
	words = draw_pipeline.bank_words;
	if (words > DRAW_BANK_WORDS)
		words = DRAW_BANK_WORDS;
	address = fw_emit_data(draw_bank, words);
	if (address == 0)
		return;

	/* Each uniform block's words, copied when the draw runs (one row of 32-bit pixels). */
	memset(&blt, 0, sizeof(blt));
	blt.op = GHCI_BLT_COPY;
	for (index = 0; index < draw_copy_count; index++) {
		blt.src = draw_copies[index].source;
		blt.dst = address + draw_copies[index].word * 4u;
		blt.src_stride = draw_copies[index].words * 4u;
		blt.dst_stride = blt.src_stride;
		blt.size = 1u << 16 | draw_copies[index].words;
		fw_blt_emit(&blt);
	}

	/* LOAD_CONST region 0 (it waits for the shader units). */
	payload[0] = 0;
	payload[1] = address;
	payload[2] = words;
	fw_emit_op(GHCI_OP_LOAD_CONST, 0, payload, 3);
}

/* Halves an fp32 value exactly (a zero stays zero; no value here is near the denormals). */
static uint32_t
draw_half(
	uint32_t bits)
{
	/* The exponent one lower, unless the value is zero. */
	if ((bits & 0x7F800000u) == 0)
		return bits;

	/* Succeeded: half the value. */
	return bits - (1u << 23);
}
