/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The resources: buffers, buffer views, images, image views and samplers,
 * and the binding of buffers and images to memory.  An image is laid out
 * by include/ghci_layout.h, as the driver lays it out for its memory
 * requirements; a view keeps the words a texture slot, a render target
 * and the descriptors of the constant bank need.
 */

#include "fw.h"
#include "ghci_layout.h"
#include "ghci_regs.h"

/* The sType of the external-memory record libvulkan chains to buffers and images. */
#define RES_STYPE_EXTERNAL_MEMORY_BUFFER 1000072000u
#define RES_STYPE_EXTERNAL_MEMORY_IMAGE 1000072001u

/* Vulkan's VK_WHOLE_SIZE and VK_REMAINING_*. */
#define RES_WHOLE_SIZE (~(uint64_t)0)
#define RES_REMAINING 0xFFFFFFFFu

/* VkImageType, VkImageViewType and VkImageCreateFlags the firmware looks at. */
#define RES_IMAGE_3D 2u
#define RES_VIEW_1D 0u
#define RES_VIEW_2D 1u
#define RES_VIEW_3D 2u
#define RES_VIEW_CUBE 3u
#define RES_VIEW_1D_ARRAY 4u
#define RES_VIEW_2D_ARRAY 5u

/* The texture unit's limit on a view's mip levels. */
#define RES_MAX_LEVELS 13u

static void res_external_chain(struct fw_command *command, uint32_t stype);
static int res_view_slot(const struct fw_image *image, uint32_t view_type, uint32_t base_level, uint32_t levels, uint32_t layers, struct fw_view *view);
static uint32_t res_log2(uint32_t value);
static uint32_t res_lod_fixed(uint32_t bits);

/* CREATE_BUFFER: the create form with VkBufferCreateInfo. */
void
fw_cmd_create_buffer(
	struct fw_command *command)
{
	struct fw_object *buffer;
	uint64_t device;
	uint64_t id;
	uint32_t size;
	uint32_t usage;

	/* The create form: the info's head and its external-memory chain. */
	device = fw_wire_create_begin(command);
	(void)fw_reader_u32(command->reader);
	res_external_chain(command, RES_STYPE_EXTERNAL_MEMORY_BUFFER);

	/* flags, size, usage, sharing mode, the queue family indices. */
	(void)fw_reader_u32(command->reader);
	size = fw_reader_address(command->reader);
	usage = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	fw_wire_skip_u32s(command);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The buffer, without memory. */
	buffer = fw_cmd_new_object(command, device, id, FW_OBJ_BUFFER);
	if (buffer == NULL)
		return;
	buffer->b = size;
	buffer->c = usage;
}

/* DESTROY_BUFFER: the destroy form. */
void
fw_cmd_destroy_buffer(
	struct fw_command *command)
{
	/* Forgets the buffer. */
	fw_cmd_destroy_object(command, FW_OBJ_BUFFER);
}

/* BIND_BUFFER_MEMORY: [device][buffer][memory][u64 offset]. */
void
fw_cmd_bind_buffer(
	struct fw_command *command)
{
	struct fw_object *buffer;
	struct fw_object *memory;
	uint64_t buffer_id;
	uint64_t memory_id;
	uint32_t offset;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	memory_id = fw_reader_u64(command->reader);
	offset = fw_reader_address(command->reader);
	if (command->reader->error)
		return;

	/* Both objects of the session. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	memory = fw_object_find(command->tag, memory_id, FW_OBJ_MEMORY);
	if (buffer == NULL || memory == NULL) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* The buffer must lie inside the memory. */
	if (offset > memory->b || buffer->b > memory->b - offset) {
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* The buffer's GPU address from now on. */
	buffer->a = memory->a + offset;
	buffer->flags |= FW_OBJF_BOUND;
}

/* CREATE_BUFFER_VIEW: the create form with VkBufferViewCreateInfo. */
void
fw_cmd_create_buffer_view(
	struct fw_command *command)
{
	struct fw_object *view;
	struct fw_object *buffer;
	uint64_t device;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t range;
	uint32_t format;
	uint64_t id;

	/* [sType][u64 0][flags][buffer][format][u64 offset][u64 range]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	buffer_id = fw_reader_u64(command->reader);
	format = fw_reader_u32(command->reader);
	offset = fw_reader_u64(command->reader);
	range = fw_reader_u64(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* A bound buffer of the session, the range inside it. */
	buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
	if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offset > buffer->b) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	if (range == RES_WHOLE_SIZE)
		range = buffer->b - offset;
	if (range > buffer->b - offset) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* The view: its address, bytes and format. */
	view = fw_cmd_new_object(command, device, id, FW_OBJ_BUFFER_VIEW);
	if (view == NULL)
		return;
	view->a = buffer->a + (uint32_t)offset;
	view->b = (uint32_t)range;
	view->c = format;
}

/* DESTROY_BUFFER_VIEW: the destroy form. */
void
fw_cmd_destroy_buffer_view(
	struct fw_command *command)
{
	/* Forgets the view. */
	fw_cmd_destroy_object(command, FW_OBJ_BUFFER_VIEW);
}

/* CREATE_IMAGE: the create form with VkImageCreateInfo. */
void
fw_cmd_create_image(
	struct fw_command *command)
{
	const struct fw_format *info;
	struct ghci_layout_image layout;
	struct fw_object *object;
	struct fw_image image;
	uint64_t device;
	uint64_t id;
	int error;

	/* The head and the external-memory chain. */
	memset(&image, 0, sizeof(image));
	device = fw_wire_create_begin(command);
	(void)fw_reader_u32(command->reader);
	res_external_chain(command, RES_STYPE_EXTERNAL_MEMORY_IMAGE);

	/* flags, type, format, extent, levels, layers, samples, tiling, usage. */
	image.create_flags = fw_reader_u32(command->reader);
	image.type = fw_reader_u32(command->reader);
	image.format = fw_reader_u32(command->reader);
	image.width = fw_reader_u32(command->reader);
	image.height = fw_reader_u32(command->reader);
	image.depth = fw_reader_u32(command->reader);
	image.levels = fw_reader_u32(command->reader);
	image.layers = fw_reader_u32(command->reader);
	image.samples = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	image.usage = fw_reader_u32(command->reader);

	/* Sharing mode, the queue family indices, the initial layout. */
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	fw_wire_skip_u32s(command);
	(void)fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* A format the GPU has, with one or four samples and a sane extent. */
	info = fw_format_find(image.format);
	if (info == NULL ||
	    (image.samples != 1u && image.samples != 4u) ||
	    image.width == 0 || image.height == 0 || image.depth == 0 ||
	    image.levels == 0 || image.layers == 0) {
		command->status = FW_VK_ERROR_FORMAT_NOT_SUPPORTED;
		return;
	}

	/* The layout, as the driver's memory requirements computed it. */
	image.texel_bytes = info->bytes;
	image.block = (info->flags & FW_FMT_BLOCK) != 0;
	if ((image.usage & (FW_USAGE_COLOR_ATTACHMENT | FW_USAGE_DEPTH_STENCIL_ATTACHMENT)) != 0)
		image.attachment = 1;
	layout.texel_bytes = image.texel_bytes;
	layout.block = image.block;
	layout.width = image.width;
	layout.height = image.height;
	layout.depth = image.depth;
	layout.levels = image.levels;
	layout.layers = image.layers;
	layout.samples = image.samples;
	layout.attachment = image.attachment;
	image.layer_stride = ghci_layout_layer_stride(&layout);
	image.size = ghci_layout_size(&layout);

	/* The image and its block. */
	object = fw_cmd_new_object(command, device, id, FW_OBJ_IMAGE);
	if (object == NULL)
		return;
	error = fw_object_block(object, sizeof(image));
	if (error == 0)
		error = fw_copy_out(object->block, &image, sizeof(image));
	if (error != 0) {
		fw_object_destroy(object);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}
}

/* DESTROY_IMAGE: the destroy form. */
void
fw_cmd_destroy_image(
	struct fw_command *command)
{
	/* Forgets the image. */
	fw_cmd_destroy_object(command, FW_OBJ_IMAGE);
}

/* BIND_IMAGE_MEMORY: [device][image][memory][u64 offset]. */
void
fw_cmd_bind_image(
	struct fw_command *command)
{
	struct fw_object *image;
	struct fw_object *memory;
	struct fw_image desc;
	uint64_t image_id;
	uint64_t memory_id;
	uint32_t offset;
	int error;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	image_id = fw_reader_u64(command->reader);
	memory_id = fw_reader_u64(command->reader);
	offset = fw_reader_address(command->reader);
	if (command->reader->error)
		return;

	/* Both objects of the session, and the image's size. */
	image = fw_object_find(command->tag, image_id, FW_OBJ_IMAGE);
	memory = fw_object_find(command->tag, memory_id, FW_OBJ_MEMORY);
	if (image == NULL || memory == NULL) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	error = fw_copy_in(image->block, &desc, sizeof(desc));
	if (error != 0) {
		command->status = FW_VK_ERROR_DEVICE_LOST;
		return;
	}

	/* The image lies inside the memory, 64-byte aligned (its requirements). */
	if (offset > memory->b ||
	    desc.size > memory->b - offset ||
	    ((memory->a + offset) & (GHCI_LAYOUT_ALIGN - 1u)) != 0) {
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}

	/* The image's GPU address from now on. */
	image->a = memory->a + offset;
	image->flags |= FW_OBJF_BOUND;
}

/* CREATE_IMAGE_VIEW: the create form with VkImageViewCreateInfo. */
void
fw_cmd_create_image_view(
	struct fw_command *command)
{
	struct fw_object *object;
	struct fw_object *image;
	struct fw_image desc;
	struct fw_view view;
	uint64_t device;
	uint64_t image_id;
	uint64_t id;
	uint32_t view_type;
	uint32_t swizzle[4];
	uint32_t base_level;
	uint32_t levels;
	uint32_t base_layer;
	uint32_t layers;
	uint32_t index;
	int error;

	/* [sType][u64 0][flags][image][view type][format][components][range]. */
	memset(&view, 0, sizeof(view));
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	image_id = fw_reader_u64(command->reader);
	view_type = fw_reader_u32(command->reader);
	view.format = fw_reader_u32(command->reader);
	for (index = 0; index < 4u; index++)
		swizzle[index] = fw_reader_u32(command->reader);
	view.aspect = fw_reader_u32(command->reader);
	base_level = fw_reader_u32(command->reader);
	levels = fw_reader_u32(command->reader);
	base_layer = fw_reader_u32(command->reader);
	layers = fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* A bound image of the session (a view needs the image's memory). */
	image = fw_object_find(command->tag, image_id, FW_OBJ_IMAGE);
	if (image == NULL || (image->flags & FW_OBJF_BOUND) == 0) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	error = fw_copy_in(image->block, &desc, sizeof(desc));
	if (error != 0) {
		command->status = FW_VK_ERROR_DEVICE_LOST;
		return;
	}

	/* VK_REMAINING_* and the range inside the image. */
	if (levels == RES_REMAINING)
		levels = desc.levels - base_level;
	if (layers == RES_REMAINING)
		layers = desc.layers - base_layer;
	if (base_level >= desc.levels ||
	    levels == 0 || levels > desc.levels - base_level ||
	    base_layer >= desc.layers ||
	    layers == 0 || layers > desc.layers - base_layer) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* The view's level and layer as the units see them. */
	view.image_base = image->a;
	view.layer_stride = desc.layer_stride;
	view.base = image->a + base_layer * desc.layer_stride;
	error = res_view_slot(&desc, view_type, base_level, levels, layers, &view);
	if (error != 0) {
		command->status = FW_VK_ERROR_FEATURE_NOT_PRESENT;
		return;
	}

	/* The texture slot's format word: the VkFormat, the stencil aspect, the swizzle. */
	view.tex_format = GHCI_TFMT_VKFORMAT(view.format) |
	    GHCI_TFMT_SWIZZLE(swizzle[0], swizzle[1], swizzle[2], swizzle[3]);
	if (view.format == FW_VK_FORMAT_D24_UNORM_S8_UINT && view.aspect == FW_ASPECT_STENCIL)
		view.tex_format |= GHCI_TFMT_STENCIL;

	/* The view and its block. */
	object = fw_cmd_new_object(command, device, id, FW_OBJ_IMAGE_VIEW);
	if (object == NULL)
		return;
	error = fw_object_block(object, sizeof(view));
	if (error == 0)
		error = fw_copy_out(object->block, &view, sizeof(view));
	if (error != 0) {
		fw_object_destroy(object);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
		return;
	}
}

/* DESTROY_IMAGE_VIEW: the destroy form. */
void
fw_cmd_destroy_image_view(
	struct fw_command *command)
{
	/* Forgets the view. */
	fw_cmd_destroy_object(command, FW_OBJ_IMAGE_VIEW);
}

/* CREATE_SAMPLER: the create form with VkSamplerCreateInfo. */
void
fw_cmd_create_sampler(
	struct fw_command *command)
{
	struct fw_object *sampler;
	uint64_t device;
	uint64_t id;
	uint32_t mag;
	uint32_t min;
	uint32_t mipmap;
	uint32_t wrap[3];
	uint32_t bias;
	uint32_t compare;
	uint32_t compare_op;
	uint32_t min_lod;
	uint32_t max_lod;
	uint32_t border;
	uint32_t unnormalized;
	uint32_t index;
	uint32_t word;
	int32_t bias_fixed;

	/* [sType][u64 0][flags][mag][min][mipmap][u v w][bias][aniso][max aniso][compare][op][min max][border][unnormalized]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	mag = fw_reader_u32(command->reader);
	min = fw_reader_u32(command->reader);
	mipmap = fw_reader_u32(command->reader);
	for (index = 0; index < 3u; index++)
		wrap[index] = fw_reader_u32(command->reader);
	bias = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	compare = fw_reader_u32(command->reader);
	compare_op = fw_reader_u32(command->reader);
	min_lod = fw_reader_u32(command->reader);
	max_lod = fw_reader_u32(command->reader);
	border = fw_reader_u32(command->reader);
	unnormalized = fw_reader_u32(command->reader);
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* TEX_SAMPLER: the address modes, the filters, compare, border, the bias. */
	word = GHCI_SAMP_WRAP_U(wrap[0]) | GHCI_SAMP_WRAP_V(wrap[1]) | GHCI_SAMP_WRAP_W(wrap[2]);
	if (mag != 0)
		word |= GHCI_SAMP_MAG_LINEAR;
	if (min != 0)
		word |= GHCI_SAMP_MIN_LINEAR;
	if (mipmap != 0)
		word |= GHCI_SAMP_MIP_LINEAR;
	if (compare != 0)
		word |= GHCI_SAMP_COMPARE | GHCI_SAMP_COMPARE_OP(compare_op);
	word |= GHCI_SAMP_BORDER(border);
	if (unnormalized != 0)
		word |= GHCI_SAMP_UNNORM;
	bias_fixed = fw_f32_fixed(bias, 8, -4096, 4095);
	word |= GHCI_SAMP_LOD_BIAS((uint32_t)bias_fixed);

	/* The sampler's two words. */
	sampler = fw_cmd_new_object(command, device, id, FW_OBJ_SAMPLER);
	if (sampler == NULL)
		return;
	sampler->a = word;
	sampler->b = GHCI_TEX_LOD_VAL(res_lod_fixed(min_lod), res_lod_fixed(max_lod));
}

/* DESTROY_SAMPLER: the destroy form. */
void
fw_cmd_destroy_sampler(
	struct fw_command *command)
{
	/* Forgets the sampler. */
	fw_cmd_destroy_object(command, FW_OBJ_SAMPLER);
}

/*
 * Reads the external-memory record a buffer or an image may chain, or
 * none; any other chain is a wire the firmware does not decode.
 */
static void
res_external_chain(
	struct fw_command *command,
	uint32_t stype)
{
	uint64_t chain;
	uint32_t found;

	/* The chain's presence. */
	chain = fw_reader_u64(command->reader);
	if (chain == 0)
		return;
	if (chain != 1) {
		command->reader->error = 1;
		return;
	}

	/* [sType][u64 0, the end of the chain][handle types]: no effect on the GPU. */
	found = fw_reader_u32(command->reader);
	if (found != stype)
		command->reader->error = 1;
	fw_wire_expect(command, 0);
	(void)fw_reader_u32(command->reader);
}

/*
 * Fills a view's level, its row, its sizes and the words of its texture
 * slot (TEX_SIZE, TEX_IMAGE); view->base is its first layer's start.
 *
 * Returns 0, or -1 for a view the texture unit cannot sample (a cube
 * array).
 */
static int
res_view_slot(
	const struct fw_image *image,
	uint32_t view_type,
	uint32_t base_level,
	uint32_t levels,
	uint32_t layers,
	struct fw_view *view)
{
	struct ghci_layout_image layout;
	uint32_t type;
	uint32_t count;

	/* The image's layout. */
	layout.texel_bytes = image->texel_bytes;
	layout.block = image->block;
	layout.width = image->width;
	layout.height = image->height;
	layout.depth = image->depth;
	layout.levels = image->levels;
	layout.layers = image->layers;
	layout.samples = image->samples;
	layout.attachment = image->attachment;

	/* The first level's place, row and extent. */
	view->base += ghci_layout_level_offset(&layout, base_level);
	view->row = ghci_layout_row(&layout, base_level);
	view->width = ghci_layout_extent(image->width, base_level);
	view->height = ghci_layout_extent(image->height, base_level);
	view->layers = layers;
	if (image->type == RES_IMAGE_3D)
		view->layers = ghci_layout_extent(image->depth, base_level);
	view->samples = image->samples;
	view->texel_bytes = image->texel_bytes;
	view->levels = levels;
	view->view_type = view_type;

	/* The texture unit's view type and its count of layers (or depth). */
	count = 0;
	switch (view_type) {
	case RES_VIEW_1D:
	case RES_VIEW_2D:
		type = GHCI_IMG_TYPE_2D;
		break;
	case RES_VIEW_1D_ARRAY:
	case RES_VIEW_2D_ARRAY:
		type = GHCI_IMG_TYPE_2D_ARRAY;
		count = layers;
		break;
	case RES_VIEW_3D:
		type = GHCI_IMG_TYPE_3D;
		count = view->layers;
		break;
	case RES_VIEW_CUBE:
		type = GHCI_IMG_TYPE_CUBE;
		break;
	default:
		return -1;
	}

	/* TEX_SIZE and TEX_IMAGE (linear rows, the format in TEX_FORMAT). */
	if (levels > RES_MAX_LEVELS)
		levels = RES_MAX_LEVELS;
	view->tex_size = view->height << 16 | (view->width & 0xFFFFu);
	view->tex_image = GHCI_IMG_LEVELS(levels) | GHCI_IMG_TYPE(type) |
	    GHCI_IMG_SAMPLES(res_log2(image->samples)) | GHCI_IMG_COUNT(count);

	/* Succeeded: the view's words. */
	return 0;
}

/* log2 of a power of two. */
static uint32_t
res_log2(
	uint32_t value)
{
	uint32_t bits;

	/* Counts the halvings. */
	bits = 0;
	while (value > 1u) {
		value >>= 1;
		bits++;
	}

	/* Succeeded: the exponent. */
	return bits;
}

/* A level of detail (fp32) as the texture unit's unsigned 4.8 fixed point, saturated. */
static uint32_t
res_lod_fixed(
	uint32_t bits)
{
	int32_t value;

	/* RNE(lod x 256) in [0, 0xFFF]. */
	value = fw_f32_fixed(bits, 8, 0, 0xFFF);

	/* Succeeded: the fixed-point level. */
	return (uint32_t)value;
}
