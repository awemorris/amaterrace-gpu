/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Render passes and framebuffers.  A render pass keeps its attachments'
 * formats, samples and load and store operations and its subpasses'
 * attachment indices; a framebuffer keeps a copy of each attachment's
 * view (a view may be destroyed while its framebuffer is not used, and
 * the render targets need only the view's words).
 */

#include "fw.h"

/*
 * The render pass or framebuffer being created (too large for the stack;
 * one command is decoded at a time).
 */
static union {
	struct fw_render_pass pass;
	struct fw_framebuffer framebuffer;
} pass_work;

static void pass_reference(struct fw_command *command, uint32_t *attachment);
static void pass_references(struct fw_command *command, uint32_t *attachments, uint32_t limit, uint32_t *count);

/* CREATE_RENDER_PASS: the create form with VkRenderPassCreateInfo. */
void
fw_cmd_create_render_pass(
	struct fw_command *command)
{
	struct fw_render_pass *pass;
	struct fw_rp_attachment *attachment;
	struct fw_subpass *subpass;
	struct fw_object *object;
	uint64_t device;
	uint64_t count;
	uint64_t index;
	uint64_t present;
	uint64_t id;
	uint32_t resolves;
	uint32_t unused;
	int error;

	/* [sType][u64 0][flags][u32 n][u64 n][attachments]. */
	pass = &pass_work.pass;
	memset(pass, 0, sizeof(*pass));
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > FW_RP_ATTACHMENTS)
		command->reader->error = 1;

	/* Each attachment: [flags][format][samples][load][store][stencil load][stencil store][layouts]. */
	for (index = 0; index < count && !command->reader->error; index++) {
		attachment = &pass->attachment[index];
		(void)fw_reader_u32(command->reader);
		attachment->format = fw_reader_u32(command->reader);
		attachment->samples = fw_reader_u32(command->reader);
		attachment->load = fw_reader_u32(command->reader);
		attachment->store = fw_reader_u32(command->reader);
		attachment->stencil_load = fw_reader_u32(command->reader);
		attachment->stencil_store = fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
	}
	pass->attachments = (uint32_t)count;

	/* [u32 n][u64 n][subpasses]. */
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count == 0 || count > FW_RP_SUBPASSES)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++) {
		/* [flags][bind point], the input and the colour references. */
		subpass = &pass->subpass[index];
		(void)fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
		pass_references(command, subpass->input, FW_RP_INPUTS, &subpass->inputs);
		pass_references(command, subpass->color, FW_RP_COLORS, &subpass->colors);

		/* The resolve references, as many as the colours, or none. */
		for (unused = 0; unused < FW_RP_COLORS; unused++)
			subpass->resolve[unused] = FW_RP_UNUSED;
		resolves = (uint32_t)fw_reader_u64(command->reader);
		if (resolves != 0 && resolves != subpass->colors)
			command->reader->error = 1;
		for (unused = 0; unused < resolves && !command->reader->error; unused++)
			pass_reference(command, &subpass->resolve[unused]);

		/* The depth/stencil reference, if any. */
		subpass->depth = FW_RP_UNUSED;
		present = fw_reader_u64(command->reader);
		if (present == 1)
			pass_reference(command, &subpass->depth);
		else if (present != 0)
			command->reader->error = 1;

		/* The preserve attachments mean nothing to a GPU that keeps memory. */
		(void)fw_reader_u32(command->reader);
		fw_wire_skip_u32s(command);
	}
	pass->subpasses = (uint32_t)count;

	/* The dependencies: the firmware waits between subpasses anyway. */
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	for (index = 0; index < count && !command->reader->error; index++)
		fw_reader_skip(command->reader, 7u * 4u);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The references name attachments of the pass. */
	for (index = 0; index < pass->subpasses; index++) {
		subpass = &pass->subpass[index];
		for (unused = 0; unused < FW_RP_COLORS; unused++) {
			if ((subpass->color[unused] != FW_RP_UNUSED && unused < subpass->colors &&
			     subpass->color[unused] >= pass->attachments) ||
			    (subpass->resolve[unused] != FW_RP_UNUSED && subpass->resolve[unused] >= pass->attachments))
				command->status = FW_VK_ERROR_UNKNOWN;
		}
		if (subpass->depth != FW_RP_UNUSED && subpass->depth >= pass->attachments)
			command->status = FW_VK_ERROR_UNKNOWN;
	}
	if (command->status != FW_VK_SUCCESS)
		return;

	/* The render pass and its block. */
	object = fw_cmd_new_object(command, device, id, FW_OBJ_RENDER_PASS);
	if (object == NULL)
		return;
	error = fw_object_block(object, sizeof(*pass));
	if (error == 0)
		error = fw_copy_out(object->block, pass, sizeof(*pass));
	if (error != 0) {
		fw_object_destroy(object);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
	}
}

/* DESTROY_RENDER_PASS: the destroy form. */
void
fw_cmd_destroy_render_pass(
	struct fw_command *command)
{
	/* Forgets the render pass. */
	fw_cmd_destroy_object(command, FW_OBJ_RENDER_PASS);
}

/* CREATE_FRAMEBUFFER: the create form with VkFramebufferCreateInfo. */
void
fw_cmd_create_framebuffer(
	struct fw_command *command)
{
	struct fw_framebuffer *framebuffer;
	struct fw_object *object;
	struct fw_object *view;
	uint64_t views[FW_RP_ATTACHMENTS];
	uint64_t device;
	uint64_t count;
	uint64_t index;
	uint64_t id;
	int error;

	/* [sType][u64 0][flags][render pass][u32 n][u64 n][views][width][height][layers]. */
	framebuffer = &pass_work.framebuffer;
	memset(framebuffer, 0, sizeof(*framebuffer));
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > FW_RP_ATTACHMENTS)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		views[index] = fw_reader_u64(command->reader);
	framebuffer->width = fw_reader_u32(command->reader);
	framebuffer->height = fw_reader_u32(command->reader);
	framebuffer->layers = fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* A copy of each attachment's view. */
	framebuffer->attachments = (uint32_t)count;
	for (index = 0; index < count; index++) {
		view = fw_object_find(command->tag, views[index], FW_OBJ_IMAGE_VIEW);
		if (view == NULL) {
			command->status = FW_VK_ERROR_UNKNOWN;
			return;
		}
		error = fw_copy_in(view->block, &framebuffer->view[index], sizeof(struct fw_view));
		if (error != 0) {
			command->status = FW_VK_ERROR_DEVICE_LOST;
			return;
		}
	}

	/* The framebuffer and its block. */
	object = fw_cmd_new_object(command, device, id, FW_OBJ_FRAMEBUFFER);
	if (object == NULL)
		return;
	error = fw_object_block(object, sizeof(*framebuffer));
	if (error == 0)
		error = fw_copy_out(object->block, framebuffer, sizeof(*framebuffer));
	if (error != 0) {
		fw_object_destroy(object);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
	}
}

/* DESTROY_FRAMEBUFFER: the destroy form. */
void
fw_cmd_destroy_framebuffer(
	struct fw_command *command)
{
	/* Forgets the framebuffer. */
	fw_cmd_destroy_object(command, FW_OBJ_FRAMEBUFFER);
}

/*
 * Reads a render pass's block.
 *
 * Returns 0, or -1 when the render pass is unknown or its block unread.
 */
int
fw_render_pass_get(
	uint32_t tag,
	uint64_t id,
	struct fw_render_pass *pass)
{
	struct fw_object *object;
	int error;

	/* The session's render pass. */
	object = fw_object_find(tag, id, FW_OBJ_RENDER_PASS);
	if (object == NULL)
		return -1;

	/* Its block. */
	error = fw_copy_in(object->block, pass, sizeof(*pass));
	if (error != 0)
		return -1;

	/* Succeeded: the render pass. */
	return 0;
}

/*
 * Reads one attachment view of a framebuffer, and the framebuffer's size.
 *
 * Returns 0, or -1 when the framebuffer is unknown or has no such
 * attachment.
 */
int
fw_framebuffer_view(
	uint32_t tag,
	uint64_t id,
	uint32_t attachment,
	struct fw_view *view,
	uint32_t *size)
{
	struct fw_object *object;
	uint32_t head[16];
	int error;

	/* The session's framebuffer and its head. */
	object = fw_object_find(tag, id, FW_OBJ_FRAMEBUFFER);
	if (object == NULL)
		return -1;
	error = fw_copy_in(object->block, head, sizeof(head));
	if (error != 0 || attachment >= head[3])
		return -1;

	/* The view's copy: a line of its own after the head. */
	error = fw_copy_in(object->block + sizeof(head) + attachment * sizeof(struct fw_view), view,
			   sizeof(struct fw_view));
	if (error != 0)
		return -1;

	/* Succeeded: the view, and {width, height, layers}. */
	size[0] = head[0];
	size[1] = head[1];
	size[2] = head[2];
	return 0;
}

/* Reads one VkAttachmentReference: [attachment][layout]. */
static void
pass_reference(
	struct fw_command *command,
	uint32_t *attachment)
{
	/* The index (VK_ATTACHMENT_UNUSED stays itself); the layout means nothing here. */
	*attachment = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
}

/* Reads [u32 count][u64 count][references], at most `limit`. */
static void
pass_references(
	struct fw_command *command,
	uint32_t *attachments,
	uint32_t limit,
	uint32_t *count)
{
	uint64_t elements;
	uint32_t index;

	/* The count, then each reference; the rest are unused. */
	(void)fw_reader_u32(command->reader);
	elements = fw_reader_u64(command->reader);
	if (elements > limit) {
		command->reader->error = 1;
		return;
	}
	for (index = 0; index < limit; index++)
		attachments[index] = FW_RP_UNUSED;
	for (index = 0; index < elements; index++)
		pass_reference(command, &attachments[index]);
	*count = (uint32_t)elements;
}
