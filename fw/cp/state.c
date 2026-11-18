/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The recorded commands that only change what the next draw or dispatch
 * is made with: the bound pipelines, descriptor sets, vertex and index
 * buffers, the push constants and the dynamic state.  They record no µop;
 * draw.c reads the recording state they leave.
 */

#include "fw.h"

/* VkPipelineBindPoint. */
#define STATE_BIND_COMPUTE 1u

/* VkStencilFaceFlags. */
#define STATE_FACE_FRONT 0x1u
#define STATE_FACE_BACK 0x2u

/* VkIndexType: UINT16, UINT32; the vertex fetcher's INDEX_FORMAT. */
#define STATE_INDEX_UINT16 0u
#define STATE_INDEX_UINT32 1u

static void state_stencil(struct fw_command *command, uint32_t dynamic);

/* CMD_BIND_PIPELINE: [cb][bind point][pipeline]. */
void
fw_cmd_bind_pipeline(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	struct fw_object *pipeline;
	uint64_t id;
	uint64_t pipeline_id;
	uint32_t point;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	point = fw_reader_u32(command->reader);
	pipeline_id = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* A pipeline of the session for its bind point. */
	pipeline = fw_object_find(command->tag, pipeline_id, FW_OBJ_PIPELINE);
	if (pipeline == NULL || ((pipeline->flags & FW_OBJF_COMPUTE) != 0) != (point == STATE_BIND_COMPUTE)) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}
	state->pipeline[point & 1u] = pipeline_id;
}

/* CMD_BIND_DESCRIPTOR_SETS: [cb][bind point][layout][first][u32 n][u64 n][sets][u32 n][u64 n][offsets]. */
void
fw_cmd_bind_descriptor_sets(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *set;
	struct fw_rstate *state;
	uint64_t sets[FW_SETS];
	uint32_t offsets[FW_SETS * FW_SET_DYNAMIC];
	uint64_t id;
	uint64_t count;
	uint64_t dynamic;
	uint64_t index;
	uint32_t point;
	uint32_t first;
	uint32_t taken;
	uint32_t element;

	/* The arguments: the sets, then the dynamic offsets. */
	id = fw_reader_u64(command->reader);
	point = fw_reader_u32(command->reader) & 1u;
	(void)fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (first > FW_SETS || count > FW_SETS - first)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		sets[index] = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	dynamic = fw_reader_u64(command->reader);
	if (dynamic > FW_SETS * FW_SET_DYNAMIC)
		command->reader->error = 1;
	for (index = 0; index < dynamic && !command->reader->error; index++)
		offsets[index] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* Each set, and its share of the dynamic offsets (its dynamic descriptors in order). */
	taken = 0;
	for (index = 0; index < count; index++) {
		set = fw_object_find(command->tag, sets[index], FW_OBJ_DESC_SET);
		if (set == NULL || set->b > FW_SET_DYNAMIC || taken + set->b > dynamic) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			return;
		}
		state->sets[point][first + index] = sets[index];
		state->dynamic_count[point][first + index] = set->b;
		for (element = 0; element < set->b; element++)
			state->dynamic[point][first + index][element] = offsets[taken + element];
		taken += set->b;
	}
}

/* CMD_BIND_VERTEX_BUFFERS: [cb][first][u32 n][u64 n][buffers][u64 n][u64 offsets]. */
void
fw_cmd_bind_vertex_buffers(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	struct fw_rstate *state;
	uint64_t buffers[FW_VERTEX_BUFFERS];
	uint64_t offsets[FW_VERTEX_BUFFERS];
	uint64_t id;
	uint64_t count;
	uint64_t elements;
	uint64_t index;
	uint32_t first;
	uint32_t binding;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (first > FW_VERTEX_BUFFERS || count > FW_VERTEX_BUFFERS - first)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		buffers[index] = fw_reader_u64(command->reader);
	elements = fw_reader_u64(command->reader);
	if (elements != count)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		offsets[index] = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* Each binding: the buffer's address with the offset, the bytes after it. */
	for (index = 0; index < count; index++) {
		binding = first + (uint32_t)index;
		buffer = fw_object_find(command->tag, buffers[index], FW_OBJ_BUFFER);
		if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offsets[index] > buffer->b) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			return;
		}
		state->vb_address[binding] = buffer->a + (uint32_t)offsets[index];
		state->vb_bytes[binding] = buffer->b - (uint32_t)offsets[index];
	}
}

/* CMD_BIND_INDEX_BUFFER: [cb][buffer][u64 offset][index type]. */
void
fw_cmd_bind_index_buffer(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	struct fw_rstate *state;
	uint64_t id;
	uint64_t buffer_id;
	uint64_t offset;
	uint32_t type;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	offset = fw_reader_u64(command->reader);
	type = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* A bound buffer; 16- or 32-bit indices. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offset > buffer->b ||
	    (type != STATE_INDEX_UINT16 && type != STATE_INDEX_UINT32)) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}
	state->ib_address = buffer->a + (uint32_t)offset;
	state->ib_bytes = buffer->b - (uint32_t)offset;
	state->ib_format = 1u + type;
}

/* CMD_PUSH_CONSTANTS: [cb][layout][stages][offset][size][u64 n][bytes]. */
void
fw_cmd_push_constants(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t words[FW_PUSH_BYTES / 4u];
	uint64_t id;
	uint64_t bytes;
	uint32_t offset;
	uint32_t size;
	uint32_t index;

	/* The arguments: whole words inside the push-constant range. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	offset = fw_reader_u32(command->reader);
	size = fw_reader_u32(command->reader);
	bytes = fw_reader_u64(command->reader);
	if (bytes != size || (offset & 3u) != 0 || (size & 3u) != 0 || offset > FW_PUSH_BYTES ||
	    size > FW_PUSH_BYTES - offset) {
		command->reader->error = 1;
		return;
	}
	for (index = 0; index < size / 4u; index++)
		words[index] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* The words in the state; the next draw puts them in the bank. */
	memcpy(&state->push[offset / 4u], words, size);
}

/* CMD_SET_VIEWPORT: [cb][first][u32 n][u64 n][viewports]. */
void
fw_cmd_set_viewport(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t viewport[6];
	uint64_t id;
	uint64_t count;
	uint32_t first;
	uint32_t field;

	/* The arguments: viewport 0 only (multiViewport is not offered). */
	id = fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (first != 0 || count != 1)
		command->reader->error = 1;
	for (field = 0; field < 6u; field++)
		viewport[field] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	memcpy(state->viewport, viewport, sizeof(viewport));
	state->dynamic_set |= FW_DYN_VIEWPORT;
}

/* CMD_SET_SCISSOR: [cb][first][u32 n][u64 n][rects]. */
void
fw_cmd_set_scissor(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t scissor[4];
	uint64_t id;
	uint64_t count;
	uint32_t first;
	uint32_t field;

	/* The arguments: scissor 0 only. */
	id = fw_reader_u64(command->reader);
	first = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (first != 0 || count != 1)
		command->reader->error = 1;
	for (field = 0; field < 4u; field++)
		scissor[field] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	memcpy(state->scissor, scissor, sizeof(scissor));
	state->dynamic_set |= FW_DYN_SCISSOR;
}

/* CMD_SET_LINE_WIDTH: [cb][width]; only 1.0 (wideLines is not offered). */
void
fw_cmd_set_line_width(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint64_t id;
	uint32_t width;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	width = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	state->line_width = width;
	state->dynamic_set |= FW_DYN_LINE_WIDTH;
}

/* CMD_SET_DEPTH_BIAS: [cb][constant][clamp][slope]. */
void
fw_cmd_set_depth_bias(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t bias[3];
	uint64_t id;
	uint32_t field;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	for (field = 0; field < 3u; field++)
		bias[field] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	memcpy(state->depth_bias, bias, sizeof(bias));
	state->dynamic_set |= FW_DYN_DEPTH_BIAS;
}

/* CMD_SET_BLEND_CONSTANTS: [cb][u64 4][four constants]. */
void
fw_cmd_set_blend_constants(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t constants[4];
	uint64_t id;
	uint32_t field;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	fw_wire_expect(command, 4);
	for (field = 0; field < 4u; field++)
		constants[field] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	memcpy(state->blend_constants, constants, sizeof(constants));
	state->dynamic_set |= FW_DYN_BLEND_CONSTANTS;
}

/* CMD_SET_DEPTH_BOUNDS: [cb][min][max]. */
void
fw_cmd_set_depth_bounds(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint64_t id;
	uint32_t bounds[2];

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	bounds[0] = fw_reader_u32(command->reader);
	bounds[1] = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;
	memcpy(state->depth_bounds, bounds, sizeof(bounds));
	state->dynamic_set |= FW_DYN_DEPTH_BOUNDS;
}

/* CMD_SET_STENCIL_COMPARE_MASK: [cb][face mask][value]. */
void
fw_cmd_set_stencil_compare(
	struct fw_command *command)
{
	/* The faces' compare masks. */
	state_stencil(command, FW_DYN_STENCIL_COMPARE_MASK);
}

/* CMD_SET_STENCIL_WRITE_MASK: [cb][face mask][value]. */
void
fw_cmd_set_stencil_write(
	struct fw_command *command)
{
	/* The faces' write masks. */
	state_stencil(command, FW_DYN_STENCIL_WRITE_MASK);
}

/* CMD_SET_STENCIL_REFERENCE: [cb][face mask][value]. */
void
fw_cmd_set_stencil_reference(
	struct fw_command *command)
{
	/* The faces' references. */
	state_stencil(command, FW_DYN_STENCIL_REFERENCE);
}

/* Sets one stencil value of the faces the mask names. */
static void
state_stencil(
	struct fw_command *command,
	uint32_t dynamic)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint32_t *values;
	uint64_t id;
	uint32_t faces;
	uint32_t value;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	faces = fw_reader_u32(command->reader);
	value = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* The state's array of the value: compare, write or reference. */
	values = state->stencil_reference;
	if (dynamic == FW_DYN_STENCIL_COMPARE_MASK)
		values = state->stencil_compare;
	if (dynamic == FW_DYN_STENCIL_WRITE_MASK)
		values = state->stencil_write;

	/* Front, back or both. */
	if ((faces & STATE_FACE_FRONT) != 0)
		values[0] = value & 0xFFu;
	if ((faces & STATE_FACE_BACK) != 0)
		values[1] = value & 0xFFu;
	state->dynamic_set |= dynamic;
}
