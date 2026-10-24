/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The recorded render pass commands: vkCmdBeginRenderPass,
 * vkCmdNextSubpass, vkCmdEndRenderPass and vkCmdClearAttachments.
 *
 * The subpasses run one after the other: before each, the earlier work
 * is waited for (WAIT_IDLE of every unit, so that what one subpass wrote
 * is in memory before the next reads it as an input attachment, and the
 * caches start afresh); its colour and depth/stencil attachments become
 * the render targets.  The attachments a render pass clears are filled
 * by the blitter when it begins (the first subpass that uses an
 * attachment comes after, so the result is the same); a subpass's
 * resolve attachments are the blitter's RESOLVE when it ends, after
 * WAIT_IDLE (the render output alone can be idle between two quads,
 * docs/ghci.md section 12.11).  A clear inside a subpass waits for the
 * draws before it in the same way.
 */

#include "fw.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* VkAttachmentLoadOp CLEAR. */
#define PASS_LOAD_CLEAR 1u

/* The clear value's union tags on the wire: colour, depth/stencil. */
#define PASS_CLEAR_COLOR 0u
#define PASS_CLEAR_DEPTH 1u

/* The render pass being recorded (one command is decoded at a time). */
static struct fw_render_pass passrec_pass;

static int passrec_subpass(struct fw_command *command, struct fw_rstate *state);
static int passrec_resolve(struct fw_command *command, struct fw_rstate *state);
static void passrec_clear_value(struct fw_command *command, uint32_t *value, uint32_t *depth);
static void passrec_wait(void);


/* CMD_BEGIN_RENDER_PASS: [cb][u64 1][VkRenderPassBeginInfo][contents]. */
void
fw_cmd_begin_render_pass(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	struct fw_rp_attachment *attachment;
	struct fw_view view;
	uint32_t clears[FW_RP_ATTACHMENTS][4];
	uint32_t depth[FW_RP_ATTACHMENTS][2];
	uint32_t raw[4];
	uint32_t size[3];
	uint32_t area[4];
	uint32_t aspects;
	uint32_t keep;
	uint64_t id;
	uint64_t pass_id;
	uint64_t framebuffer_id;
	uint64_t count;
	uint64_t index;
	uint32_t layer;
	uint32_t contents;
	int packed;
	int error;

	/* [cb][u64 1][sType][u64 0][render pass][framebuffer][area][u32 n][u64 n][clears][contents]. */
	id = fw_reader_u64(command->reader);
	fw_wire_expect(command, 1);
	fw_wire_head(command);
	pass_id = fw_reader_u64(command->reader);
	framebuffer_id = fw_reader_u64(command->reader);
	for (index = 0; index < 4u; index++)
		area[index] = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > FW_RP_ATTACHMENTS)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		passrec_clear_value(command, clears[index], depth[index]);
	contents = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* The render pass, outside another. */
	error = fw_render_pass_get(command->tag, pass_id, &passrec_pass);
	if (error != 0 || state->in_pass) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}
	state->in_pass = 1;
	state->render_pass = pass_id;
	state->framebuffer = framebuffer_id;
	state->subpass = 0;
	state->contents = contents;
	memcpy(state->area, area, sizeof(area));

	/* The clears of the attachments that load with CLEAR, after the earlier work. */
	fw_emit_begin(cmdbuf, command->tag);
	passrec_wait();
	for (index = 0; index < passrec_pass.attachments && index < count; index++) {
		attachment = &passrec_pass.attachment[index];
		error = fw_framebuffer_view(command->tag, framebuffer_id, (uint32_t)index, &view, size);
		if (error != 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			break;
		}

		/* A colour attachment's value, or the aspects of a depth/stencil one that clear. */
		keep = 0;
		packed = fw_format_pack_color(attachment->format, clears[index], raw);
		if (packed == 0) {
			if (attachment->load != PASS_LOAD_CLEAR)
				continue;
		} else {
			aspects = 0;
			if (attachment->load == PASS_LOAD_CLEAR)
				aspects |= FW_ASPECT_DEPTH;
			if (attachment->stencil_load == PASS_LOAD_CLEAR)
				aspects |= FW_ASPECT_STENCIL;
			if (aspects == 0)
				continue;
			memset(raw, 0, sizeof(raw));
			error = fw_format_pack_depth(attachment->format, depth[index][0], depth[index][1], aspects,
						     raw, &keep);
			if (error != 0)
				continue;
		}

		/* Every layer of the framebuffer, the render area of each. */
		for (layer = 0; layer < size[2] && layer < view.layers; layer++)
			fw_blt_fill_rect(view.base + layer * view.layer_stride, view.row, view.texel_bytes, view.samples,
					 area, raw, keep);
	}

	/* The first subpass's render targets. */
	error = passrec_subpass(command, state);
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_NEXT_SUBPASS: [cb][contents]. */
void
fw_cmd_next_subpass(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint64_t id;
	uint32_t contents;
	int error;

	/* The arguments. */
	id = fw_reader_u64(command->reader);
	contents = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* A next subpass of the render pass. */
	error = fw_render_pass_get(command->tag, state->render_pass, &passrec_pass);
	if (error != 0 || !state->in_pass || state->subpass + 1u >= passrec_pass.subpasses) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* This subpass's resolves, then the next one's render targets. */
	fw_emit_begin(cmdbuf, command->tag);
	error = passrec_resolve(command, state);
	state->subpass++;
	state->contents = contents;
	if (error == 0) {
		passrec_wait();
		error = passrec_subpass(command, state);
	}
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_END_RENDER_PASS: [cb]. */
void
fw_cmd_end_render_pass(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	uint64_t id;
	int error;

	/* The argument. */
	id = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state == NULL)
		return;

	/* Inside a render pass. */
	error = fw_render_pass_get(command->tag, state->render_pass, &passrec_pass);
	if (error != 0 || !state->in_pass) {
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		return;
	}

	/* The last subpass's resolves. */
	fw_emit_begin(cmdbuf, command->tag);
	error = passrec_resolve(command, state);
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
	state->in_pass = 0;
}

/*
 * CMD_CLEAR_ATTACHMENTS: [cb][u32 n][u64 n][{aspect, colour attachment,
 * clear value}][u32 n][u64 n][{rect, base layer, layers}].
 */
void
fw_cmd_clear_attachments(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct fw_rstate *state;
	struct fw_subpass *subpass;
	struct fw_view view;
	uint32_t aspect[FW_RP_ATTACHMENTS];
	uint32_t color[FW_RP_ATTACHMENTS];
	uint32_t clears[FW_RP_ATTACHMENTS][4];
	uint32_t depth[FW_RP_ATTACHMENTS][2];
	uint32_t rect[6];
	uint32_t raw[4];
	uint32_t size[3];
	uint32_t keep;
	uint32_t attachment;
	uint32_t format;
	uint32_t layer;
	uint64_t id;
	uint64_t count;
	uint64_t rects;
	uint64_t index;
	uint64_t item;
	uint32_t field;
	int error;

	/* The attachments and their values. */
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > FW_RP_ATTACHMENTS)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++) {
		aspect[index] = fw_reader_u32(command->reader);
		color[index] = fw_reader_u32(command->reader);
		passrec_clear_value(command, clears[index], depth[index]);
	}
	(void)fw_reader_u32(command->reader);
	rects = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	error = -1;
	state = fw_cmd_record_state(command, id, &cmdbuf);
	if (state != NULL && state->in_pass)
		error = fw_render_pass_get(command->tag, state->render_pass, &passrec_pass);
	if (error != 0) {
		if (state != NULL)
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
		for (item = 0; item < rects && !command->reader->error; item++)
			fw_reader_skip(command->reader, 6u * 4u);
		return;
	}

	/* Each rectangle, each attachment, each layer: the draws before it done first. */
	subpass = &passrec_pass.subpass[state->subpass];
	fw_emit_begin(cmdbuf, command->tag);
	passrec_wait();
	for (item = 0; item < rects && !command->reader->error; item++) {
		for (field = 0; field < 6u; field++)
			rect[field] = fw_reader_u32(command->reader);
		for (index = 0; index < count; index++) {
			/* The subpass's attachment. */
			attachment = subpass->depth;
			if ((aspect[index] & FW_ASPECT_COLOR) != 0) {
				attachment = FW_RP_UNUSED;
				if (color[index] < subpass->colors)
					attachment = subpass->color[color[index]];
			}
			if (attachment == FW_RP_UNUSED)
				continue;
			error = fw_framebuffer_view(command->tag, state->framebuffer, attachment, &view, size);
			if (error != 0)
				continue;

			/* Its bits (and the bytes the blitter keeps for one aspect of D24S8). */
			keep = 0;
			format = passrec_pass.attachment[attachment].format;
			if ((aspect[index] & FW_ASPECT_COLOR) != 0) {
				error = fw_format_pack_color(format, clears[index], raw);
			} else {
				memset(raw, 0, sizeof(raw));
				error = fw_format_pack_depth(format, depth[index][0], depth[index][1], aspect[index], raw, &keep);
			}
			if (error != 0)
				continue;

			/* The layers of the rectangle. */
			for (layer = rect[4]; layer < rect[4] + rect[5] && layer < view.layers; layer++)
				fw_blt_fill_rect(view.base + layer * view.layer_stride, view.row, view.texel_bytes,
						 view.samples, rect, raw, keep);
		}
	}

	/* The clears; the next draw finds the render targets as they were. */
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* Writes the render targets of the state's subpass (its colour and depth/stencil views). */
static int
passrec_subpass(
	struct fw_command *command,
	struct fw_rstate *state)
{
	struct fw_subpass *subpass;
	struct fw_view view;
	uint32_t size[3];
	uint32_t index;
	uint32_t attachment;
	int error;

	/* Each colour attachment k: RT_BASE and RT_STRIDE, or RTk_BASE and RTk_STRIDE. */
	subpass = &passrec_pass.subpass[state->subpass];
	size[0] = 0;
	size[1] = 0;
	for (index = 0; index < FW_RP_COLORS; index++) {
		attachment = FW_RP_UNUSED;
		if (index < subpass->colors)
			attachment = subpass->color[index];
		memset(&view, 0, sizeof(view));
		if (attachment != FW_RP_UNUSED) {
			error = fw_framebuffer_view(command->tag, state->framebuffer, attachment, &view, size);
			if (error != 0)
				return -1;
		}
		if (index == 0) {
			fw_emit_set(GHCI_S_RT_BASE, view.base);
			fw_emit_set(GHCI_S_RT_STRIDE, view.row);
			fw_emit_set(GHCI_S_RT_FORMAT, 0);
		} else {
			fw_emit_set(GHCI_S_RT1_BASE + 2u * (index - 1u), view.base);
			fw_emit_set(GHCI_S_RT1_BASE + 2u * (index - 1u) + 1u, view.row);
		}
	}

	/* The depth/stencil attachment. */
	memset(&view, 0, sizeof(view));
	if (subpass->depth != FW_RP_UNUSED) {
		error = fw_framebuffer_view(command->tag, state->framebuffer, subpass->depth, &view, size);
		if (error != 0)
			return -1;
	}
	fw_emit_set(GHCI_S_DS_BASE, view.base);
	fw_emit_set(GHCI_S_DS_STRIDE, view.row);

	/* The targets' size: the framebuffer's (read with any attachment, or none). */
	if (size[0] == 0) {
		error = fw_framebuffer_view(command->tag, state->framebuffer, 0, &view, size);
		if (error != 0) {
			size[0] = 0;
			size[1] = 0;
		}
	}
	fw_emit_set(GHCI_S_RT_SIZE, size[1] << 16 | (size[0] & 0xFFFFu));

	/* The pipelines' STATE words name formats of this subpass: they are written again. */
	state->emitted[FW_BIND_GRAPHICS] = 0;

	/* Succeeded: the subpass can draw. */
	return 0;
}

/* Resolves the state's subpass's multisampled colour attachments into their resolve attachments. */
static int
passrec_resolve(
	struct fw_command *command,
	struct fw_rstate *state)
{
	struct fw_subpass *subpass;
	struct fw_view src;
	struct fw_view dst;
	struct fw_blt blt;
	uint32_t size[3];
	uint32_t index;
	uint32_t layer;
	uint32_t waited;
	int error;

	/* Each colour attachment with a resolve attachment. */
	subpass = &passrec_pass.subpass[state->subpass];
	waited = 0;
	for (index = 0; index < subpass->colors && index < FW_RP_COLORS; index++) {
		if (subpass->color[index] == FW_RP_UNUSED || subpass->resolve[index] == FW_RP_UNUSED)
			continue;
		error = fw_framebuffer_view(command->tag, state->framebuffer, subpass->color[index], &src, size);
		if (error == 0)
			error = fw_framebuffer_view(command->tag, state->framebuffer, subpass->resolve[index], &dst, size);
		if (error != 0)
			return -1;

		/* The draws' writes are in memory first. */
		if (!waited) {
			passrec_wait();
			waited = 1;
		}

		/* RESOLVE of the render area, layer by layer (4 samples). */
		memset(&blt, 0, sizeof(blt));
		blt.op = GHCI_BLT_RESOLVE | fw_blt_pixel(src.texel_bytes);
		blt.src_stride = src.row;
		blt.dst_stride = dst.row;
		blt.dst_xy = state->area[1] << 16 | (state->area[0] & 0xFFFFu);
		blt.src_xy = blt.dst_xy;
		blt.size = state->area[3] << 16 | (state->area[2] & 0xFFFFu);
		blt.resolve = GHCI_BLT_RSV_SAMPLES4 | fw_resolve_average(src.format) << 4;
		for (layer = 0; layer < size[2] && layer < src.layers && layer < dst.layers; layer++) {
			blt.src = src.base + layer * src.layer_stride;
			blt.dst = dst.base + layer * dst.layer_stride;
			fw_blt_emit(&blt);
		}
	}

	/* Succeeded: the resolves are built. */
	return 0;
}

/* Reads a clear value: colour [u32 0][u32 2][u64 4][4 words], or depth [u32 1][f32 depth][u32 stencil]. */
static void
passrec_clear_value(
	struct fw_command *command,
	uint32_t *value,
	uint32_t *depth)
{
	uint32_t tag;
	uint32_t index;

	/* The union's tag. */
	memset(value, 0, 16);
	depth[0] = 0;
	depth[1] = 0;
	tag = fw_reader_u32(command->reader);
	if (tag == PASS_CLEAR_DEPTH) {
		depth[0] = fw_reader_u32(command->reader);
		depth[1] = fw_reader_u32(command->reader);
		return;
	}
	if (tag != PASS_CLEAR_COLOR) {
		command->reader->error = 1;
		return;
	}

	/* The colour's four words. */
	(void)fw_reader_u32(command->reader);
	fw_wire_expect(command, 4);
	for (index = 0; index < 4u; index++)
		value[index] = fw_reader_u32(command->reader);
}

/* Waits for every unit and starts the caches afresh (between the draws and the blitter). */
static void
passrec_wait(void)
{
	/* WAIT_IDLE of every unit, then the data and texture caches. */
	fw_emit_op(GHCI_OP_WAIT_IDLE, 0, NULL, 0);
	fw_emit_op(GHCI_OP_INVALIDATE, 0x3u, NULL, 0);
}

/*
 * Gives the blitter's RESOLVE average of a colour format (docs/ghci.md
 * section 8.2).
 */
uint32_t
fw_resolve_average(
	uint32_t format)
{
	const struct fw_format *info;

	/* The packed formats with their own averages. */
	if (format == FW_VK_FORMAT_R5G6B5_UNORM_PACK16)
		return 1;
	if (format == 8u)
		return 7;
	if (format == 64u)
		return 6;

	/* By the type: UNORM8, sRGB, the floats; the integers take sample 0. */
	info = fw_format_find(format);
	if (info == NULL)
		return 2;
	switch (info->type) {
	case FW_FMT_UNORM:
		return 0;
	case FW_FMT_SRGB:
		return 3;
	case FW_FMT_SFLOAT:
		if (info->comp[0].width == 16u)
			return 4;
		return 5;
	default:
		return 2;
	}
}
