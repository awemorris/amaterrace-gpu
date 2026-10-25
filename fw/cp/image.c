/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The transfers of images, as blits: copies between images and between
 * buffers and images, clears of colour and depth/stencil images, and
 * resolves.  A subresource is a level and a layer of an image laid out by
 * include/ghci_layout.h (a 3D level's slice z at z planes past the
 * level); a multisampled image's rows hold every sample of a texel side
 * by side, so its blits are S times as wide.  One aspect of
 * D24_UNORM_S8_UINT is written with the blitter's KEEP mask; a copy
 * between the stencil aspect and a buffer of 1-byte stencil values
 * changes the texel size and is a built-in compute program.
 */

#include "fw.h"
#include "ghci_layout.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* KEEP masks of D24_UNORM_S8_UINT: write the depth bytes, write the stencil byte. */
#define IMG_KEEP_DEPTH_ONLY 0x8u
#define IMG_KEEP_STENCIL_ONLY 0x7u

/* VK_REMAINING_*. */
#define IMG_REMAINING 0xFFFFFFFFu

/*
 * One subresource being blitted: the image's description and object, the
 * level, and the level's row, extent and plane.
 */
struct img_sub {
	struct fw_image image;
	uint32_t address;
	uint32_t level;
	uint32_t row;
	uint32_t width;
	uint32_t height;
	uint32_t depth;
	uint32_t plane;
	uint32_t address_level;	/* the level's offset from its layer's start */
};

static int img_get(struct fw_command *command, uint64_t id, struct img_sub *sub);
static void img_level(struct img_sub *sub, uint32_t level);
static uint32_t img_slice(const struct img_sub *sub, uint32_t layer, uint32_t z);
static uint32_t img_keep(uint32_t format, uint32_t aspect);
static void img_read_layers(struct fw_command *command, uint32_t *layers);
static void img_read3(struct fw_command *command, uint32_t *values);
static void img_s8_dispatch(struct img_sub *sub, uint32_t layer, const uint32_t *offset, const uint32_t *extent, uint32_t buffer, uint32_t row_length, int to_image);
static int img_blit_draw(struct img_sub *src, struct img_sub *dst, const uint32_t *src_layers, const uint32_t *dst_layers, const uint32_t *src_box, const uint32_t *dst_box, uint32_t linear);

/*
 * CMD_COPY_BUFFER_TO_IMAGE and CMD_COPY_IMAGE_TO_BUFFER: [cb][buffer]
 * [image][layout] (the image first for the copy to the buffer) [u32
 * n][u64 n][{u64 buffer offset, row length, image height, layers, offset,
 * extent}].
 */
static void
img_buffer_copy(
	struct fw_command *command,
	int to_image)
{
	struct fw_object *cmdbuf;
	struct fw_object *buffer;
	struct img_sub sub;
	struct fw_blt blt;
	uint32_t layers[4];
	uint32_t offset[3];
	uint32_t extent[3];
	uint32_t row_length;
	uint32_t image_height;
	uint32_t texel;
	uint32_t block;
	uint32_t buffer_row;
	uint32_t buffer_slice;
	uint32_t layer;
	uint32_t z;
	uint64_t id;
	uint64_t buffer_id;
	uint64_t image_id;
	uint64_t buffer_offset;
	uint64_t count;
	uint64_t region;
	struct fw_rstate *state;
	int stencil;
	int failed;
	int error;

	/* The command buffer, the buffer and the image. */
	stencil = 0;
	id = fw_reader_u64(command->reader);
	if (to_image) {
		buffer_id = fw_reader_u64(command->reader);
		image_id = fw_reader_u64(command->reader);
		(void)fw_reader_u32(command->reader);
	} else {
		image_id = fw_reader_u64(command->reader);
		(void)fw_reader_u32(command->reader);
		buffer_id = fw_reader_u64(command->reader);
	}
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	failed = cmdbuf == NULL;
	if (!failed) {
		error = img_get(command, image_id, &sub);
		if (error != 0 || buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			failed = 1;
		}
	}

	/* Each region. */
	if (!failed)
		fw_emit_begin(cmdbuf, command->tag);
	for (region = 0; region < count && !command->reader->error; region++) {
		buffer_offset = fw_reader_u64(command->reader);
		row_length = fw_reader_u32(command->reader);
		image_height = fw_reader_u32(command->reader);
		img_read_layers(command, layers);
		img_read3(command, offset);
		img_read3(command, extent);
		if (failed || command->reader->error)
			continue;

		/* The level; texels or 4x4 blocks; the buffer's rows (0: the extent's). */
		img_level(&sub, layers[1]);
		texel = sub.image.texel_bytes;
		block = 1;
		if (sub.image.block)
			block = 4;
		if (row_length == 0)
			row_length = extent[0];
		if (image_height == 0)
			image_height = extent[1];
		buffer_row = (row_length + block - 1u) / block * texel;
		buffer_slice = buffer_row * ((image_height + block - 1u) / block);
		if (layers[3] == IMG_REMAINING)
			layers[3] = sub.image.layers - layers[2];

		/* The stencil aspect of D24S8 against 1-byte values: the built-in compute program. */
		if (sub.image.format == FW_VK_FORMAT_D24_UNORM_S8_UINT && layers[0] == FW_ASPECT_STENCIL) {
			for (layer = 0; layer < layers[3]; layer++)
				img_s8_dispatch(&sub, layers[2] + layer, offset, extent,
						buffer->a + (uint32_t)buffer_offset + layer * buffer_slice / 4u, row_length,
						to_image);
			stencil = 1;
			continue;
		}

		/* A blit per layer and slice. */
		memset(&blt, 0, sizeof(blt));
		blt.op = GHCI_BLT_COPY | fw_blt_pixel(texel);
		if (to_image)
			blt.op |= img_keep(sub.image.format, layers[0]) << 16;
		blt.size = ((extent[1] + block - 1u) / block) << 16 | ((extent[0] + block - 1u) / block);
		for (layer = 0; layer < layers[3]; layer++) {
			for (z = 0; z < extent[2]; z++) {
				if (to_image) {
					blt.src = buffer->a + (uint32_t)buffer_offset + (layer * extent[2] + z) * buffer_slice;
					blt.src_stride = buffer_row;
					blt.dst = img_slice(&sub, layers[2] + layer, offset[2] + z);
					blt.dst_stride = sub.row;
					blt.dst_xy = (offset[1] / block) << 16 | (offset[0] / block);
				} else {
					blt.src = img_slice(&sub, layers[2] + layer, offset[2] + z);
					blt.src_stride = sub.row;
					blt.src_xy = (offset[1] / block) << 16 | (offset[0] / block);
					blt.dst = buffer->a + (uint32_t)buffer_offset + (layer * extent[2] + z) * buffer_slice;
					blt.dst_stride = buffer_row;
				}
				fw_blt_emit(&blt);
			}
		}
	}
	if (failed)
		return;
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);

	/* A dispatch wrote the program range: the next one writes its pipeline's again. */
	state = fw_rstate(cmdbuf);
	if (stencil && state != NULL)
		state->emitted[FW_BIND_COMPUTE] = 0;
}

/* CMD_COPY_BUFFER_TO_IMAGE. */
void
fw_cmd_copy_buffer_to_image(
	struct fw_command *command)
{
	/* The buffer's texels into the image. */
	img_buffer_copy(command, 1);
}

/* CMD_COPY_IMAGE_TO_BUFFER. */
void
fw_cmd_copy_image_to_buffer(
	struct fw_command *command)
{
	/* The image's texels into the buffer. */
	img_buffer_copy(command, 0);
}

/*
 * CMD_COPY_IMAGE and CMD_RESOLVE_IMAGE: [cb][src][layout][dst][layout][u32
 * n][u64 n][{src layers, src offset, dst layers, dst offset, extent}].
 */
static void
img_image_copy(
	struct fw_command *command,
	int resolve)
{
	struct fw_object *cmdbuf;
	struct img_sub src;
	struct img_sub dst;
	struct fw_blt blt;
	uint32_t src_layers[4];
	uint32_t dst_layers[4];
	uint32_t src_offset[3];
	uint32_t dst_offset[3];
	uint32_t extent[3];
	uint32_t block;
	uint32_t wide;
	uint32_t layer;
	uint32_t z;
	uint64_t id;
	uint64_t src_id;
	uint64_t dst_id;
	uint64_t count;
	uint64_t region;
	int failed;
	int error;

	/* The command buffer and the two images. */
	id = fw_reader_u64(command->reader);
	src_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	dst_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	failed = cmdbuf == NULL;
	if (!failed) {
		error = img_get(command, src_id, &src);
		if (error == 0)
			error = img_get(command, dst_id, &dst);
		if (error != 0 || src.image.texel_bytes != dst.image.texel_bytes) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			failed = 1;
		}
	}

	/* A resolve reads what earlier draws wrote: they are finished first. */
	if (!failed) {
		fw_emit_begin(cmdbuf, command->tag);
		if (resolve) {
			fw_emit_op(GHCI_OP_WAIT_IDLE, 0, NULL, 0);
		}
	}

	/* Each region, layer by layer and slice by slice. */
	for (region = 0; region < count && !command->reader->error; region++) {
		img_read_layers(command, src_layers);
		img_read3(command, src_offset);
		img_read_layers(command, dst_layers);
		img_read3(command, dst_offset);
		img_read3(command, extent);
		if (failed || command->reader->error)
			continue;
		img_level(&src, src_layers[1]);
		img_level(&dst, dst_layers[1]);

		/* Texels (blocks of a compressed format; every sample of a multisampled copy). */
		block = 1;
		if (src.image.block)
			block = 4;
		wide = 1;
		if (!resolve)
			wide = src.image.samples;
		memset(&blt, 0, sizeof(blt));
		if (resolve) {
			blt.op = GHCI_BLT_RESOLVE | fw_blt_pixel(src.image.texel_bytes);
			blt.resolve = GHCI_BLT_RSV_SAMPLES4 | fw_resolve_average(src.image.format) << 4;
		} else {
			blt.op = GHCI_BLT_COPY | fw_blt_pixel(src.image.texel_bytes) |
			    img_keep(dst.image.format, dst_layers[0]) << 16;
		}
		blt.src_stride = src.row;
		blt.dst_stride = dst.row;
		blt.src_xy = (src_offset[1] / block) << 16 | ((src_offset[0] / block) * wide);
		blt.dst_xy = (dst_offset[1] / block) << 16 | ((dst_offset[0] / block) * wide);
		blt.size = ((extent[1] + block - 1u) / block) << 16 | ((extent[0] + block - 1u) / block) * wide;
		if (src_layers[3] == IMG_REMAINING)
			src_layers[3] = src.image.layers - src_layers[2];
		for (layer = 0; layer < src_layers[3]; layer++) {
			for (z = 0; z < extent[2]; z++) {
				blt.src = img_slice(&src, src_layers[2] + layer, src_offset[2] + z);
				blt.dst = img_slice(&dst, dst_layers[2] + layer, dst_offset[2] + z);
				fw_blt_emit(&blt);
			}
		}
	}
	if (failed)
		return;
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_COPY_IMAGE. */
void
fw_cmd_copy_image(
	struct fw_command *command)
{
	/* Texels between two images of the same texel size. */
	img_image_copy(command, 0);
}

/* CMD_RESOLVE_IMAGE. */
void
fw_cmd_resolve_image(
	struct fw_command *command)
{
	/* The samples of a multisampled image averaged into another. */
	img_image_copy(command, 1);
}

/*
 * CMD_CLEAR_COLOR_IMAGE: [cb][image][layout][u64 1][u32 2][u64 4][four
 * words][u32 n][u64 n][ranges]; CMD_CLEAR_DEPTH_STENCIL_IMAGE: [cb][image]
 * [layout][u64 1][f32 depth][u32 stencil][u32 n][u64 n][ranges].
 */
static void
img_clear(
	struct fw_command *command,
	int depth_stencil)
{
	struct fw_object *cmdbuf;
	struct img_sub sub;
	uint32_t color[4];
	uint32_t raw[4];
	uint32_t range[5];
	uint32_t rect[4];
	uint32_t keep;
	uint32_t level;
	uint32_t layer;
	uint32_t z;
	uint32_t field;
	uint64_t id;
	uint64_t image_id;
	uint64_t count;
	uint64_t index;
	int failed;
	int error;

	/* The command buffer, the image, the value. */
	id = fw_reader_u64(command->reader);
	image_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	fw_wire_expect(command, 1);
	memset(color, 0, sizeof(color));
	if (depth_stencil) {
		color[0] = fw_reader_u32(command->reader);
		color[1] = fw_reader_u32(command->reader);
	} else {
		(void)fw_reader_u32(command->reader);
		fw_wire_expect(command, 4);
		for (field = 0; field < 4u; field++)
			color[field] = fw_reader_u32(command->reader);
	}
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	failed = cmdbuf == NULL;
	if (!failed) {
		error = img_get(command, image_id, &sub);
		if (error != 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			failed = 1;
		}
	}

	/* Each range: every level and layer of it, filled whole. */
	if (!failed)
		fw_emit_begin(cmdbuf, command->tag);
	for (index = 0; index < count && !command->reader->error; index++) {
		for (field = 0; field < 5u; field++)
			range[field] = fw_reader_u32(command->reader);
		if (failed || command->reader->error)
			continue;

		/* The texel's bits for the aspects the range clears. */
		keep = 0;
		memset(raw, 0, sizeof(raw));
		if (depth_stencil) {
			error = fw_format_pack_depth(sub.image.format, color[0], color[1], range[0], raw, &keep);
		} else {
			error = fw_format_pack_color(sub.image.format, color, raw);
		}
		if (error != 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			continue;
		}
		if (range[2] == IMG_REMAINING)
			range[2] = sub.image.levels - range[1];
		if (range[4] == IMG_REMAINING)
			range[4] = sub.image.layers - range[3];

		/* Each level, layer and slice. */
		for (level = range[1]; level < range[1] + range[2] && level < sub.image.levels; level++) {
			img_level(&sub, level);
			rect[0] = 0;
			rect[1] = 0;
			rect[2] = sub.width;
			rect[3] = sub.height;
			for (layer = range[3]; layer < range[3] + range[4] && layer < sub.image.layers; layer++) {
				for (z = 0; z < sub.depth; z++)
					fw_blt_fill_rect(img_slice(&sub, layer, z), sub.row, sub.image.texel_bytes,
							 sub.image.samples, rect, raw, keep);
			}
		}
	}
	if (failed)
		return;
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/* CMD_CLEAR_COLOR_IMAGE. */
void
fw_cmd_clear_color_image(
	struct fw_command *command)
{
	/* Every texel of the ranges takes the colour. */
	img_clear(command, 0);
}

/* CMD_CLEAR_DEPTH_STENCIL_IMAGE. */
void
fw_cmd_clear_depth_stencil_image(
	struct fw_command *command)
{
	/* Every texel of the ranges takes the depth and the stencil value. */
	img_clear(command, 1);
}

/*
 * CMD_BLIT_IMAGE: [cb][src][layout][dst][layout][u32 n][u64 n][{src
 * layers, u64 2, two offsets, dst layers, u64 2, two offsets}][filter].
 * A region of the same size in both images and the same format is a
 * copy; a scaled, flipped or converting blit is the built-in draw.
 */
void
fw_cmd_blit_image(
	struct fw_command *command)
{
	struct fw_object *cmdbuf;
	struct img_sub src;
	struct img_sub dst;
	struct fw_blt blt;
	uint32_t src_layers[4];
	uint32_t dst_layers[4];
	uint32_t src_box[6];
	uint32_t dst_box[6];
	uint32_t layer;
	uint32_t z;
	uint64_t id;
	uint64_t src_id;
	uint64_t dst_id;
	uint64_t count;
	uint64_t region;
	struct fw_reader saved;
	struct fw_rstate *state;
	uint32_t filter_linear;
	int failed;
	int error;

	/* The command buffer and the two images. */
	id = fw_reader_u64(command->reader);
	src_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	dst_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (command->reader->error)
		return;
	cmdbuf = fw_cmd_recording(command, id);
	failed = cmdbuf == NULL;
	if (!failed) {
		error = img_get(command, src_id, &src);
		if (error == 0)
			error = img_get(command, dst_id, &dst);
		if (error != 0) {
			fw_cmd_record_error(cmdbuf, FW_VK_ERROR_UNKNOWN);
			failed = 1;
		}
	}
	if (!failed)
		fw_emit_begin(cmdbuf, command->tag);

	/* The filter comes after the regions (each 24 words): it is looked at first. */
	saved = *command->reader;
	fw_reader_skip(command->reader, (uint32_t)count * 96u);
	filter_linear = fw_reader_u32(command->reader);
	*command->reader = saved;
	if (count > 0x10000u)
		command->reader->error = 1;

	/* Each region: its two boxes. */
	for (region = 0; region < count && !command->reader->error; region++) {
		img_read_layers(command, src_layers);
		fw_wire_expect(command, 2);
		img_read3(command, &src_box[0]);
		img_read3(command, &src_box[3]);
		img_read_layers(command, dst_layers);
		fw_wire_expect(command, 2);
		img_read3(command, &dst_box[0]);
		img_read3(command, &dst_box[3]);
		if (failed || command->reader->error)
			continue;

		/* A scaled, flipped or converting blit is the built-in draw. */
		img_level(&src, src_layers[1]);
		img_level(&dst, dst_layers[1]);
		if (src_layers[3] == IMG_REMAINING)
			src_layers[3] = src.image.layers - src_layers[2];
		if (src.image.format != dst.image.format ||
		    src_box[3] < src_box[0] || src_box[4] < src_box[1] || src_box[5] < src_box[2] ||
		    dst_box[3] - dst_box[0] != src_box[3] - src_box[0] ||
		    dst_box[4] - dst_box[1] != src_box[4] - src_box[1] ||
		    dst_box[5] - dst_box[2] != src_box[5] - src_box[2]) {
			error = img_blit_draw(&src, &dst, src_layers, dst_layers, src_box, dst_box, filter_linear);
			if (error != 0)
				fw_cmd_record_error(cmdbuf, FW_VK_ERROR_FEATURE_NOT_PRESENT);
			continue;
		}

		/* The copy, layer by layer and slice by slice. */
		memset(&blt, 0, sizeof(blt));
		blt.op = GHCI_BLT_COPY | fw_blt_pixel(src.image.texel_bytes);
		blt.src_stride = src.row;
		blt.dst_stride = dst.row;
		blt.src_xy = src_box[1] << 16 | src_box[0];
		blt.dst_xy = dst_box[1] << 16 | dst_box[0];
		blt.size = (src_box[4] - src_box[1]) << 16 | (src_box[3] - src_box[0]);
		for (layer = 0; layer < src_layers[3]; layer++) {
			for (z = 0; z < src_box[5] - src_box[2]; z++) {
				blt.src = img_slice(&src, src_layers[2] + layer, src_box[2] + z);
				blt.dst = img_slice(&dst, dst_layers[2] + layer, dst_box[2] + z);
				fw_blt_emit(&blt);
			}
		}
	}

	/* The filter. */
	(void)fw_reader_u32(command->reader);
	if (failed)
		return;

	/* A blit draw wrote STATE: the next draw writes its pipeline's again. */
	state = fw_rstate(cmdbuf);
	if (state != NULL) {
		state->emitted[FW_BIND_GRAPHICS] = 0;
		state->emitted[FW_BIND_COMPUTE] = 0;
	}
	error = fw_emit_end();
	if (error != 0)
		fw_cmd_record_error(cmdbuf, FW_VK_ERROR_OUT_OF_DEVICE_MEMORY);
}

/*
 * The built-in blit draw of one region: for each layer (and each slice of
 * a 3D destination, the source's nearest slice), a triangle strip over
 * the destination box whose fragments read the source box with the
 * blit's filter (unnormalized coordinates, clamped to the edge).  The
 * render output converts the format; nothing of the draw is counted by
 * an occlusion query.
 *
 * Returns 0, or -1 for images the draw cannot blit (depth/stencil,
 * multisampled, a destination without colour attachments).
 */
static int
img_blit_draw(
	struct img_sub *src,
	struct img_sub *dst,
	const uint32_t *src_layers,
	const uint32_t *dst_layers,
	const uint32_t *src_box,
	const uint32_t *dst_box,
	uint32_t linear)
{
	const struct fw_format *src_format;
	const struct fw_format *dst_format;
	uint32_t bank[8];
	uint32_t payload[3];
	uint32_t vs_words;
	uint32_t fs_words;
	uint32_t vs_code;
	uint32_t fs_code;
	uint32_t sampler;
	uint32_t layer;
	uint32_t z;
	uint32_t slices;
	uint32_t src_slice;
	uint32_t index;

	/* Colour images of one sample, a destination that can be rendered. */
	src_format = fw_format_find(src->image.format);
	dst_format = fw_format_find(dst->image.format);
	if (src_format == NULL || dst_format == NULL || (dst_format->flags & FW_FMT_COLOR) == 0 ||
	    (src_format->flags & (FW_FMT_DEPTH | FW_FMT_STENCIL)) != 0 ||
	    src->image.samples != 1u || dst->image.samples != 1u)
		return -1;

	/* The bank: the destination's corners and the source's, in pixels and texels. */
	for (index = 0; index < 2u; index++) {
		bank[index] = fw_f32_from_int((int32_t)dst_box[index]);
		bank[2u + index] = fw_f32_from_int((int32_t)dst_box[3u + index]);
		bank[4u + index] = fw_f32_from_int((int32_t)src_box[index]);
		bank[6u + index] = fw_f32_from_int((int32_t)src_box[3u + index]);
	}

	/* The draw's fixed state: no test, no blend, no cull, a strip, the identity viewport. */
	vs_code = fw_builtin_program(FW_PROGRAM_BLIT_VS, &vs_words);
	fs_code = fw_builtin_program(FW_PROGRAM_BLIT_FS, &fs_words);
	fw_emit_set(GHCI_S_TOPOLOGY, 4);
	fw_emit_set(GHCI_S_PRIM_RESTART, 0);
	fw_emit_set(GHCI_S_CULL, 0);
	fw_emit_set(GHCI_S_DEPTH_CLAMP, 2);
	fw_emit_set(GHCI_S_RAST_MODE, 0);
	fw_emit_set(GHCI_S_VARYING_COUNT, 2);
	fw_emit_set(GHCI_S_VS_OUT_WORDS, 2);
	fw_emit_set(GHCI_S_PROVOKING, 0);
	fw_emit_set(GHCI_S_MS_CTRL, 0);
	fw_emit_set(GHCI_S_SAMPLE_KILL, 0);
	fw_emit_set(GHCI_S_DEPTH, 0);
	fw_emit_set(GHCI_S_BLEND, 0);
	for (index = 0; index < 3u; index++)
		fw_emit_set(GHCI_S_BLEND1 + index, 0);
	fw_emit_set(GHCI_S_WRITE_MASK, 0xFu);
	fw_emit_set(GHCI_S_RT_FORMATS, dst->image.format & 0xFFu);
	fw_emit_set(GHCI_S_ROP_CTRL, 2);
	fw_emit_set(GHCI_S_VIEWPORT + 0u, 0x3F800000u);
	fw_emit_set(GHCI_S_VIEWPORT + 1u, 0x3F800000u);
	fw_emit_set(GHCI_S_VIEWPORT + 2u, 0);
	fw_emit_set(GHCI_S_VIEWPORT + 3u, 0);
	fw_emit_set(GHCI_S_VIEWPORT + 4u, 0x3F800000u);
	fw_emit_set(GHCI_S_VIEWPORT + 5u, 0);
	fw_emit_set(GHCI_S_SCISSOR_MIN, 0);
	fw_emit_set(GHCI_S_SCISSOR_MAX, 0);
	fw_emit_set(GHCI_S_RT_SIZE, dst->height << 16 | dst->width);
	fw_emit_set(GHCI_S_RT_STRIDE, dst->row);
	fw_emit_set(GHCI_S_RT_FORMAT, 0);
	fw_emit_set(GHCI_S_DS_BASE, 0);
	fw_emit_set(GHCI_S_VS_BASE, vs_code);
	fw_emit_set(GHCI_S_VS_WORDS, vs_words);
	fw_emit_set(GHCI_S_FS_BASE, fs_code);
	fw_emit_set(GHCI_S_FS_WORDS, fs_words);

	/* The vertex index from the identity buffer in r0; no other attribute. */
	for (index = 0; index < FW_PIPE_ATTRIBUTES; index++)
		fw_emit_set(GHCI_S_ATTR_DST + index, 0);
	fw_emit_set(GHCI_S_ATTR_DST, (uint32_t)FW_VK_FORMAT_R32_UINT << 24);
	fw_emit_set(GHCI_S_ATTR + 1u, 4);
	fw_emit_set(GHCI_S_ATTR, fw_builtin_identity());
	fw_emit_set(GHCI_S_ATTR_LIMIT, 0x80000000u | FW_IDENTITY_WORDS * 4u);
	fw_emit_set(GHCI_S_FIRST, 0);
	fw_emit_set(GHCI_S_COUNT, 4);
	fw_emit_set(GHCI_S_INSTANCE_COUNT, 1);
	fw_emit_set(GHCI_S_FIRST_INSTANCE, 0);
	fw_emit_set(GHCI_S_VERTEX_OFFSET, 0);
	fw_emit_set(GHCI_S_INDEX_FORMAT, 0);

	/* The source's slot: a 2D level, the sampler of the blit's filter. */
	sampler = GHCI_SAMP_WRAP_U(2) | GHCI_SAMP_WRAP_V(2) | GHCI_SAMP_WRAP_W(2) | GHCI_SAMP_UNNORM;
	if (linear != 0)
		sampler |= GHCI_SAMP_MAG_LINEAR | GHCI_SAMP_MIN_LINEAR;
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_SIZE), src->height << 16 | src->width);
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_IMAGE), GHCI_IMG_LEVELS(1));
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_LAYER_STRIDE), 0);
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_SAMPLER), sampler);
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_LOD), GHCI_TEX_LOD_VAL(0, 0));
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_FORMAT), GHCI_TFMT_VKFORMAT(src->image.format));
	fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_ROW), (src->image.attachment && !src->image.block) ? 1u : 0u);
	index = 0;
	fw_emit_op(GHCI_OP_LOAD_PROGRAM, 0, &index, 1);
	payload[0] = 0;
	payload[1] = fw_emit_data(bank, 8);
	payload[2] = 8;
	fw_emit_op(GHCI_OP_LOAD_CONST, 0, payload, 3);

	/* Each layer, and each destination slice of a 3D image from the nearest source slice. */
	slices = dst_box[5] - dst_box[2];
	if (dst_box[5] < dst_box[2])
		slices = 0;
	for (layer = 0; layer < src_layers[3]; layer++) {
		for (z = 0; z < slices; z++) {
			src_slice = src_box[2] + (uint32_t)(((uint64_t)(2u * z + 1u) * (src_box[5] - src_box[2])) / (2u * slices));
			fw_emit_set(GHCI_S_TEX(0, GHCI_TEX_BASE), img_slice(src, src_layers[2] + layer, src_slice));
			fw_emit_set(GHCI_S_RT_BASE, img_slice(dst, dst_layers[2] + layer, dst_box[2] + z));
			fw_emit_op(GHCI_OP_DRAW, 0, NULL, 0);
		}
	}

	/* Succeeded: the draws are built (the caller's state is written again later). */
	return 0;
}

/*
 * The copy of a region of stencil bytes between a buffer and one layer of
 * a D24S8 image: the built-in compute program, a lane per texel (the
 * stencil of a D24S8 buffer copy is tightly packed: one byte per texel).
 */
static void
img_s8_dispatch(
	struct img_sub *sub,
	uint32_t layer,
	const uint32_t *offset,
	const uint32_t *extent,
	uint32_t buffer,
	uint32_t row_length,
	int to_image)
{
	uint32_t bank[8];
	uint32_t payload[3];
	uint32_t groups[3];
	uint32_t code;
	uint32_t words;
	uint32_t texels;
	uint32_t program;

	/* The program of the direction. */
	program = FW_PROGRAM_S8_FROM_IMAGE;
	if (to_image)
		program = FW_PROGRAM_S8_TO_IMAGE;
	code = fw_builtin_program(program, &words);

	/* The bank: width, texels, the buffer's start and row, the image's first texel and row. */
	texels = extent[0] * extent[1];
	bank[0] = extent[0];
	bank[1] = texels;
	bank[2] = buffer;
	bank[3] = row_length;
	bank[4] = img_slice(sub, layer, offset[2]) + offset[1] * sub->row + offset[0] * 4u;
	bank[5] = sub->row;
	bank[6] = 0;
	bank[7] = 0;

	/* The program range, the bank, then DISPATCH of 64-lane workgroups. */
	fw_emit_set(GHCI_S_CS_BASE, code);
	fw_emit_set(GHCI_S_CS_WORDS, words);
	fw_emit_set(GHCI_S_LDS_BYTES, 0);
	fw_emit_set(GHCI_S_WG_SIZE, 64);
	groups[0] = 0;
	fw_emit_op(GHCI_OP_LOAD_PROGRAM, 0, groups, 1);
	payload[0] = 0;
	payload[1] = fw_emit_data(bank, 8);
	payload[2] = 8;
	fw_emit_op(GHCI_OP_LOAD_CONST, 0, payload, 3);
	fw_emit_op(GHCI_OP_INVALIDATE, 0x3u, NULL, 0);
	groups[0] = (texels + 63u) / 64u;
	groups[1] = 1;
	groups[2] = 1;
	fw_emit_op(GHCI_OP_DISPATCH, 0, groups, 3);
}

/* Reads a bound image of the session into a subresource (level 0). */
static int
img_get(
	struct fw_command *command,
	uint64_t id,
	struct img_sub *sub)
{
	struct fw_object *image;
	int error;

	/* The image and its description. */
	image = fw_object_find(command->tag, id, FW_OBJ_IMAGE);
	if (image == NULL || (image->flags & FW_OBJF_BOUND) == 0)
		return -1;
	error = fw_copy_in(image->block, &sub->image, sizeof(sub->image));
	if (error != 0)
		return -1;

	/* Succeeded: level 0 of the image. */
	sub->address = image->a;
	img_level(sub, 0);
	return 0;
}

/* Moves a subresource to a level: its row, extent and plane. */
static void
img_level(
	struct img_sub *sub,
	uint32_t level)
{
	struct ghci_layout_image layout;

	/* The image's layout. */
	layout.texel_bytes = sub->image.texel_bytes;
	layout.block = sub->image.block;
	layout.width = sub->image.width;
	layout.height = sub->image.height;
	layout.depth = sub->image.depth;
	layout.levels = sub->image.levels;
	layout.layers = sub->image.layers;
	layout.samples = sub->image.samples;
	layout.attachment = sub->image.attachment;

	/* The level's numbers. */
	sub->level = level;
	sub->row = ghci_layout_row(&layout, level);
	sub->width = ghci_layout_extent(sub->image.width, level);
	sub->height = ghci_layout_extent(sub->image.height, level);
	sub->depth = ghci_layout_extent(sub->image.depth, level);
	sub->plane = ghci_layout_plane(&layout, level);
	sub->address_level = ghci_layout_level_offset(&layout, level);
}

/* The GPU address of a slice of a layer of the subresource's level. */
static uint32_t
img_slice(
	const struct img_sub *sub,
	uint32_t layer,
	uint32_t z)
{
	/* The image, the layer, the level, the slice. */
	return sub->address + layer * sub->image.layer_stride + sub->address_level + z * sub->plane;
}

/* The KEEP mask for one aspect of a D24S8 destination (0 otherwise). */
static uint32_t
img_keep(
	uint32_t format,
	uint32_t aspect)
{
	/* Only D24_UNORM_S8_UINT has two aspects in one texel. */
	if (format != FW_VK_FORMAT_D24_UNORM_S8_UINT)
		return 0;
	if (aspect == FW_ASPECT_DEPTH)
		return IMG_KEEP_DEPTH_ONLY;
	if (aspect == FW_ASPECT_STENCIL)
		return IMG_KEEP_STENCIL_ONLY;

	/* Both aspects: the whole texel. */
	return 0;
}

/* Reads a VkImageSubresourceLayers: [aspect][level][base layer][layers]. */
static void
img_read_layers(
	struct fw_command *command,
	uint32_t *layers)
{
	uint32_t field;

	/* Four words. */
	for (field = 0; field < 4u; field++)
		layers[field] = fw_reader_u32(command->reader);
}

/* Reads an offset or an extent of three words. */
static void
img_read3(
	struct fw_command *command,
	uint32_t *values)
{
	uint32_t field;

	/* x, y, z. */
	for (field = 0; field < 3u; field++)
		values[field] = fw_reader_u32(command->reader);
}
