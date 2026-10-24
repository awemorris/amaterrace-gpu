/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Descriptor set layouts, descriptor pools and sets, their updates and
 * copies, and pipeline layouts.
 *
 * A layout's block holds its bindings in a table (struct fw_set_layout)
 * and the words of its immutable samplers.  A set's block holds a copy of
 * that table (a layout may be destroyed while its sets live) and then one
 * struct fw_descriptor per descriptor, binding by binding.  An update
 * writes the descriptors through the result store's line, so the set's
 * memory is current once the store is flushed (at the end of each
 * command that changes a set).
 */

#include "fw.h"

/* VkDescriptorType. */
#define DESC_SAMPLER 0u
#define DESC_COMBINED 1u
#define DESC_SAMPLED_IMAGE 2u
#define DESC_STORAGE_IMAGE 3u
#define DESC_UNIFORM_TEXEL 4u
#define DESC_STORAGE_TEXEL 5u
#define DESC_UNIFORM_BUFFER 6u
#define DESC_STORAGE_BUFFER 7u
#define DESC_UNIFORM_DYNAMIC 8u
#define DESC_STORAGE_DYNAMIC 9u
#define DESC_INPUT_ATTACHMENT 10u

/* VkDescriptorPoolCreateFlags: FREE_DESCRIPTOR_SET. */
#define DESC_POOL_FREE_SET 0x1u

/* Vulkan's VK_WHOLE_SIZE. */
#define DESC_WHOLE_SIZE (~(uint64_t)0)

/* Where a set's descriptors start in its block: the line after the table (a descriptor never spans two lines). */
#define DESC_FIRST FW_ROUND_LINES(sizeof(struct fw_set_layout))

/* The bindings and the immutable samplers a layout may have. */
#define DESC_MAX_BINDINGS 32u
#define DESC_MAX_IMMUTABLE 32u

/*
 * The layout being created or the set being allocated (too large for the
 * stack; one command is decoded at a time): the table and the immutable
 * sampler words after it.
 */
static struct {
	struct fw_set_layout layout;
	uint32_t immutable[2u * DESC_MAX_IMMUTABLE];
} desc_work;

/*
 * One write of an update: its set (NULL: unknown), the first binding and
 * element, the count and the descriptor type.
 */
struct desc_write {
	struct fw_object *set;
	uint32_t binding;
	uint32_t element;
	uint32_t count;
	uint32_t type;
};

static void desc_write_images(struct fw_command *command, const struct desc_write *write);
static void desc_write_buffers(struct fw_command *command, const struct desc_write *write);
static void desc_write_texels(struct fw_command *command, const struct desc_write *write);
static void desc_copy(struct fw_command *command);
static void desc_release(struct fw_object *set);
static int desc_find(struct fw_object *set, uint32_t binding, uint32_t element, uint32_t *index);
static int desc_put(struct fw_object *set, uint32_t index, const struct fw_descriptor *descriptor);
static int desc_layout_bytes(const struct fw_set_layout *layout);

/* CREATE_DESCRIPTOR_SET_LAYOUT: the create form with VkDescriptorSetLayoutCreateInfo. */
void
fw_cmd_create_set_layout(
	struct fw_command *command)
{
	struct fw_set_layout *layout;
	struct fw_layout_binding *entry;
	struct fw_object *object;
	struct fw_object *sampler;
	uint64_t device;
	uint64_t count;
	uint64_t samplers;
	uint64_t index;
	uint64_t element;
	uint64_t sampler_id;
	uint64_t id;
	uint32_t bytes;
	uint32_t first;
	int error;

	/* [sType][u64 0][flags][u32 count][u64 count][bindings]. */
	layout = &desc_work.layout;
	memset(&desc_work, 0, sizeof(desc_work));
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > DESC_MAX_BINDINGS)
		command->reader->error = 1;

	/* Each binding: [binding][type][count][stages][u64 count][immutable samplers]. */
	for (index = 0; index < count && !command->reader->error; index++) {
		entry = &layout->bindings[index];
		entry->binding = fw_reader_u32(command->reader);
		entry->type = fw_reader_u32(command->reader);
		entry->count = fw_reader_u32(command->reader);
		(void)fw_reader_u32(command->reader);
		entry->immutable = FW_NO_IMMUTABLE;
		samplers = fw_reader_u64(command->reader);
		if (samplers != 0 && (samplers != entry->count ||
		    layout->immutable + samplers > DESC_MAX_IMMUTABLE)) {
			command->reader->error = 1;
			break;
		}
		if (samplers != 0)
			entry->immutable = layout->immutable;

		/* The immutable samplers' words, kept in the layout. */
		for (element = 0; element < samplers; element++) {
			sampler_id = fw_reader_u64(command->reader);
			sampler = fw_object_find(command->tag, sampler_id, FW_OBJ_SAMPLER);
			if (sampler == NULL) {
				command->status = FW_VK_ERROR_UNKNOWN;
				continue;
			}
			desc_work.immutable[2u * layout->immutable] = sampler->a;
			desc_work.immutable[2u * layout->immutable + 1u] = sampler->b;
			layout->immutable++;
		}
	}
	id = fw_wire_create_end(command);
	if (command->reader->error || command->status != FW_VK_SUCCESS)
		return;
	layout->count = (uint32_t)count;

	/*
	 * The descriptors of each binding follow each other in the set in the
	 * order of the bindings given; the dynamic buffers count in binding
	 * number order (Vulkan's order of the dynamic offsets).
	 */
	first = 0;
	for (index = 0; index < count; index++) {
		layout->bindings[index].first = first;
		first += layout->bindings[index].count;
	}
	layout->descriptors = first;
	for (index = 0; index < count; index++) {
		entry = &layout->bindings[index];
		entry->dynamic_first = 0;
		for (element = 0; element < count; element++) {
			if (layout->bindings[element].binding >= entry->binding)
				continue;
			if (layout->bindings[element].type == DESC_UNIFORM_DYNAMIC ||
			    layout->bindings[element].type == DESC_STORAGE_DYNAMIC)
				entry->dynamic_first += layout->bindings[element].count;
		}
		if (entry->type == DESC_UNIFORM_DYNAMIC || entry->type == DESC_STORAGE_DYNAMIC)
			layout->dynamic += entry->count;
	}

	/* The layout and its block. */
	object = fw_cmd_new_object(command, device, id, FW_OBJ_SET_LAYOUT);
	if (object == NULL)
		return;
	bytes = (uint32_t)desc_layout_bytes(layout);
	error = fw_object_block(object, bytes);
	if (error == 0)
		error = fw_copy_out(object->block, &desc_work, bytes);
	if (error != 0) {
		fw_object_destroy(object);
		command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
	}
}

/* DESTROY_DESCRIPTOR_SET_LAYOUT: the destroy form (its sets keep their copies). */
void
fw_cmd_destroy_set_layout(
	struct fw_command *command)
{
	/* Forgets the layout. */
	fw_cmd_destroy_object(command, FW_OBJ_SET_LAYOUT);
}

/* CREATE_DESCRIPTOR_POOL: the create form with VkDescriptorPoolCreateInfo. */
void
fw_cmd_create_descriptor_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint64_t device;
	uint64_t count;
	uint64_t index;
	uint64_t id;
	uint32_t flags;
	uint32_t sets;
	uint32_t descriptors;

	/* [sType][u64 0][flags][max sets][u32 count][u64 count][{type, count}...]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	flags = fw_reader_u32(command->reader);
	sets = fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	descriptors = 0;
	for (index = 0; index < count && !command->reader->error; index++) {
		(void)fw_reader_u32(command->reader);
		descriptors += fw_reader_u32(command->reader);
	}
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The pool counts the sets and descriptors left. */
	pool = fw_cmd_new_object(command, device, id, FW_OBJ_DESC_POOL);
	if (pool == NULL)
		return;
	pool->a = sets;
	pool->b = descriptors;
	if ((flags & DESC_POOL_FREE_SET) != 0)
		pool->flags |= FW_OBJF_FREE_SET;
}

/* DESTROY_DESCRIPTOR_POOL: the destroy form; the pool's sets go with it. */
void
fw_cmd_destroy_descriptor_pool(
	struct fw_command *command)
{
	/* Forgets the pool and its sets. */
	fw_cmd_destroy_object(command, FW_OBJ_DESC_POOL);
}

/* Gives a set's room back to its pool (for a reset of the pool). */
static void
desc_release(
	struct fw_object *set)
{
	/* The pool gets the set's count back, then the set goes. */
	if (set->parent != NULL) {
		set->parent->a++;
		set->parent->b += set->a;
	}
	fw_object_destroy(set);
}

/* RESET_DESCRIPTOR_POOL: [device][pool][u32 flags]. */
void
fw_cmd_reset_descriptor_pool(
	struct fw_command *command)
{
	struct fw_object *pool;
	uint64_t id;

	/* The arguments. */
	(void)fw_reader_u64(command->reader);
	id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Every set of the pool is freed. */
	pool = fw_object_find(command->tag, id, FW_OBJ_DESC_POOL);
	if (pool == NULL) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}
	fw_object_each_child(pool, desc_release);
}

/* ALLOCATE_DESCRIPTOR_SETS: [device][u64 1][VkDescriptorSetAllocateInfo][u64 count][ids]. */
void
fw_cmd_allocate_descriptor_sets(
	struct fw_command *command)
{
	uint64_t layouts_id[FW_MAX_ALLOCATE];
	struct fw_descriptor descriptor;
	struct fw_layout_binding *entry;
	struct fw_object *pool;
	struct fw_object *layout;
	struct fw_object *set;
	uint64_t device;
	uint64_t pool_id;
	uint64_t count;
	uint64_t ids;
	uint64_t index;
	uint64_t id;
	uint32_t bytes;
	uint32_t binding;
	uint32_t element;
	int error;

	/* [device][u64 1][sType][u64 0][pool][u32 count][u64 count][layouts]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	pool_id = fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);
	if (count > FW_MAX_ALLOCATE)
		command->reader->error = 1;
	for (index = 0; index < count && !command->reader->error; index++)
		layouts_id[index] = fw_reader_u64(command->reader);

	/* [u64 count][the sets' identities]. */
	ids = fw_reader_u64(command->reader);
	if (ids != count)
		command->reader->error = 1;
	pool = fw_object_find(command->tag, pool_id, FW_OBJ_DESC_POOL);
	if (pool == NULL)
		command->status = FW_VK_ERROR_UNKNOWN;

	/* Each set: its layout's table copied, its descriptors empty (immutable samplers set). */
	for (index = 0; index < ids && !command->reader->error; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error || command->status != FW_VK_SUCCESS)
			continue;

		/* The layout's table and immutable samplers. */
		layout = fw_object_find(command->tag, layouts_id[index], FW_OBJ_SET_LAYOUT);
		if (layout == NULL) {
			command->status = FW_VK_ERROR_UNKNOWN;
			continue;
		}
		error = fw_copy_in(layout->block, &desc_work, (uint32_t)layout->lines * FW_LINE_BYTES);
		if (error != 0) {
			command->status = FW_VK_ERROR_DEVICE_LOST;
			continue;
		}

		/* Room in the pool. */
		if (pool->a == 0 || pool->b < desc_work.layout.descriptors) {
			command->status = FW_VK_ERROR_OUT_OF_POOL_MEMORY;
			continue;
		}

		/* The set and its block: the table, then the descriptors. */
		set = fw_cmd_new_object(command, device, id, FW_OBJ_DESC_SET);
		if (set == NULL)
			continue;
		set->parent = pool;
		bytes = DESC_FIRST + desc_work.layout.descriptors * sizeof(struct fw_descriptor);
		error = fw_object_block(set, bytes);
		if (error == 0)
			error = fw_copy_out(set->block, &desc_work.layout, sizeof(struct fw_set_layout));
		if (error != 0) {
			fw_object_destroy(set);
			command->status = FW_VK_ERROR_OUT_OF_DEVICE_MEMORY;
			continue;
		}
		set->a = desc_work.layout.descriptors;
		set->b = desc_work.layout.dynamic;
		pool->a--;
		pool->b -= desc_work.layout.descriptors;

		/* Every descriptor empty; an immutable sampler's words already there. */
		for (binding = 0; binding < desc_work.layout.count; binding++) {
			entry = &desc_work.layout.bindings[binding];
			for (element = 0; element < entry->count; element++) {
				memset(&descriptor, 0, sizeof(descriptor));
				descriptor.type = entry->type;
				if (entry->immutable != FW_NO_IMMUTABLE) {
					descriptor.sampler = desc_work.immutable[2u * (entry->immutable + element)];
					descriptor.lod = desc_work.immutable[2u * (entry->immutable + element) + 1u];
					descriptor.flags |= FW_DESC_IMMUTABLE;
				}
				error = desc_put(set, entry->first + element, &descriptor);
				if (error != 0)
					command->status = FW_VK_ERROR_DEVICE_LOST;
			}
		}
	}

	/* The sets are in memory before any later command reads them. */
	error = fw_store_flush();
	if (error != 0)
		command->status = FW_VK_ERROR_DEVICE_LOST;

}

/* FREE_DESCRIPTOR_SETS: [device][pool][u32 count][u64 count][sets]. */
void
fw_cmd_free_descriptor_sets(
	struct fw_command *command)
{
	struct fw_object *set;
	uint64_t count;
	uint64_t index;
	uint64_t id;

	/* [device][pool][u32 count] and the array's count. */
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	count = fw_reader_u64(command->reader);

	/* Frees each named set; its pool gets the room back. */
	for (index = 0; index < count; index++) {
		id = fw_reader_u64(command->reader);
		if (command->reader->error)
			return;
		set = fw_object_find(command->tag, id, FW_OBJ_DESC_SET);
		if (set != NULL)
			desc_release(set);
	}
}

/*
 * UPDATE_DESCRIPTOR_SETS: [device][u32 count][u64 count][writes][u32
 * count][u64 count][copies].  A write: [sType][u64 0][set][binding][array
 * element][count][type][u64 n][n x {sampler, view, layout}][u64 n][n x
 * {buffer, u64 offset, u64 range}][u64 n][n x texel buffer view]; only
 * the array of the type has elements.  The writes come before the copies
 * (Vulkan's order).
 */
void
fw_cmd_update_descriptor_sets(
	struct fw_command *command)
{
	struct desc_write write;
	uint64_t set_id;
	uint64_t writes;
	uint64_t copies;
	uint64_t index;
	uint64_t images;
	uint64_t buffers;
	uint64_t texels;
	int error;

	/* The writes. */
	(void)fw_reader_u64(command->reader);
	(void)fw_reader_u32(command->reader);
	writes = fw_reader_u64(command->reader);
	for (index = 0; index < writes && !command->reader->error; index++) {
		/* The destination of the write. */
		fw_wire_head(command);
		set_id = fw_reader_u64(command->reader);
		write.set = fw_object_find(command->tag, set_id, FW_OBJ_DESC_SET);
		write.binding = fw_reader_u32(command->reader);
		write.element = fw_reader_u32(command->reader);
		write.count = fw_reader_u32(command->reader);
		write.type = fw_reader_u32(command->reader);
		if (write.set == NULL)
			command->status = FW_VK_ERROR_UNKNOWN;

		/* Each array; a count other than 0 or the write's is a malformed wire. */
		images = fw_reader_u64(command->reader);
		if (images != 0 && images != write.count)
			command->reader->error = 1;
		if (images != 0)
			desc_write_images(command, &write);
		buffers = fw_reader_u64(command->reader);
		if (buffers != 0 && buffers != write.count)
			command->reader->error = 1;
		if (buffers != 0)
			desc_write_buffers(command, &write);
		texels = fw_reader_u64(command->reader);
		if (texels != 0 && texels != write.count)
			command->reader->error = 1;
		if (texels != 0)
			desc_write_texels(command, &write);
	}

	/* The copies. */
	(void)fw_reader_u32(command->reader);
	copies = fw_reader_u64(command->reader);
	for (index = 0; index < copies && !command->reader->error; index++)
		desc_copy(command);

	/* The sets are in memory before any later command reads them. */
	error = fw_store_flush();
	if (error != 0)
		command->status = FW_VK_ERROR_DEVICE_LOST;
}

/* CREATE_PIPELINE_LAYOUT: the create form with VkPipelineLayoutCreateInfo. */
void
fw_cmd_create_pipeline_layout(
	struct fw_command *command)
{
	struct fw_object *layout;
	uint64_t device;
	uint64_t ranges;
	uint64_t index;
	uint64_t id;
	uint32_t offset;
	uint32_t size;
	uint32_t push;

	/* [sType][u64 0][flags][u32 n][u64 n][set layouts][u32 n][u64 n][{stages, offset, size}]. */
	device = fw_wire_create_begin(command);
	fw_wire_head(command);
	(void)fw_reader_u32(command->reader);
	(void)fw_reader_u32(command->reader);
	fw_wire_skip_u64s(command);
	(void)fw_reader_u32(command->reader);
	ranges = fw_reader_u64(command->reader);
	push = 0;
	for (index = 0; index < ranges && !command->reader->error; index++) {
		(void)fw_reader_u32(command->reader);
		offset = fw_reader_u32(command->reader);
		size = fw_reader_u32(command->reader);
		if (offset + size > push)
			push = offset + size;
	}
	id = fw_wire_create_end(command);
	if (command->reader->error)
		return;

	/* The layout: its push-constant bytes (the sets are bound by number). */
	layout = fw_cmd_new_object(command, device, id, FW_OBJ_PIPE_LAYOUT);
	if (layout == NULL)
		return;
	layout->a = push;
}

/* DESTROY_PIPELINE_LAYOUT: the destroy form. */
void
fw_cmd_destroy_pipeline_layout(
	struct fw_command *command)
{
	/* Forgets the layout. */
	fw_cmd_destroy_object(command, FW_OBJ_PIPE_LAYOUT);
}

/*
 * Reads one descriptor of a set.
 *
 * Returns 0, or -1 when the index is past the set or the memory refused.
 */
int
fw_descriptor_get(
	struct fw_object *set,
	uint32_t index,
	struct fw_descriptor *descriptor)
{
	uint8_t line[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));
	uint32_t address;
	int error;

	/* Inside the set. */
	if (index >= set->a)
		return -1;

	/* The store's line first, so the memory is current. */
	error = fw_store_flush();
	if (error != 0)
		return -1;

	/* The line that holds the descriptor (32 bytes never span two lines). */
	address = set->block + DESC_FIRST + index * sizeof(struct fw_descriptor);
	error = fw_dma_read(address & ~(FW_LINE_BYTES - 1u), line, 1);
	if (error != 0)
		return -1;
	memcpy(descriptor, &line[address & (FW_LINE_BYTES - 1u)], sizeof(*descriptor));

	/* Succeeded: the descriptor. */
	return 0;
}

/* Writes the image descriptors of a write: [sampler][view][layout] each. */
static void
desc_write_images(
	struct fw_command *command,
	const struct desc_write *write)
{
	struct fw_descriptor descriptor;
	struct fw_object *sampler;
	struct fw_object *view;
	uint64_t sampler_id;
	uint64_t view_id;
	uint32_t item;
	uint32_t index;
	int error;

	/* Each descriptor of the write. */
	for (item = 0; item < write->count && !command->reader->error; item++) {
		sampler_id = fw_reader_u64(command->reader);
		view_id = fw_reader_u64(command->reader);
		(void)fw_reader_u32(command->reader);
		if (write->set == NULL)
			continue;

		/* The descriptor as it is (its immutable sampler stays). */
		error = desc_find(write->set, write->binding, write->element + item, &index);
		if (error == 0)
			error = fw_descriptor_get(write->set, index, &descriptor);
		if (error != 0) {
			command->status = FW_VK_ERROR_UNKNOWN;
			continue;
		}

		/* The sampler's words, unless immutable. */
		sampler = fw_object_find(command->tag, sampler_id, FW_OBJ_SAMPLER);
		if (sampler != NULL && (descriptor.flags & FW_DESC_IMMUTABLE) == 0) {
			descriptor.sampler = sampler->a;
			descriptor.lod = sampler->b;
		}

		/* The view, which a sampler-only descriptor does not have. */
		view = fw_object_find(command->tag, view_id, FW_OBJ_IMAGE_VIEW);
		descriptor.type = write->type;
		descriptor.object = view_id;
		if (write->type != DESC_SAMPLER && view == NULL) {
			command->status = FW_VK_ERROR_UNKNOWN;
			continue;
		}

		/* Into the set. */
		error = desc_put(write->set, index, &descriptor);
		if (error != 0)
			command->status = FW_VK_ERROR_DEVICE_LOST;
	}
}

/* Writes the buffer descriptors of a write: [buffer][u64 offset][u64 range] each. */
static void
desc_write_buffers(
	struct fw_command *command,
	const struct desc_write *write)
{
	struct fw_descriptor descriptor;
	struct fw_object *buffer;
	uint64_t buffer_id;
	uint64_t offset;
	uint64_t range;
	uint32_t item;
	uint32_t index;
	int error;

	/* Each descriptor of the write. */
	for (item = 0; item < write->count && !command->reader->error; item++) {
		buffer_id = fw_reader_u64(command->reader);
		offset = fw_reader_u64(command->reader);
		range = fw_reader_u64(command->reader);
		if (write->set == NULL)
			continue;

		/* A bound buffer of the session; the range clamped to it (VK_WHOLE_SIZE too). */
		buffer = fw_object_find(command->tag, buffer_id, FW_OBJ_BUFFER);
		if (buffer == NULL || (buffer->flags & FW_OBJF_BOUND) == 0 || offset > buffer->b) {
			command->status = FW_VK_ERROR_UNKNOWN;
			continue;
		}
		if (range > buffer->b - offset)
			range = buffer->b - offset;

		/* The descriptor: the address with the offset, the range's bytes. */
		memset(&descriptor, 0, sizeof(descriptor));
		descriptor.type = write->type;
		descriptor.address = buffer->a + (uint32_t)offset;
		descriptor.bytes = (uint32_t)range;
		error = desc_find(write->set, write->binding, write->element + item, &index);
		if (error == 0)
			error = desc_put(write->set, index, &descriptor);
		if (error != 0)
			command->status = FW_VK_ERROR_UNKNOWN;
	}
}

/* Writes the texel buffer descriptors of a write: one buffer view each. */
static void
desc_write_texels(
	struct fw_command *command,
	const struct desc_write *write)
{
	struct fw_descriptor descriptor;
	struct fw_object *view;
	uint64_t view_id;
	uint32_t item;
	uint32_t index;
	int error;

	/* Each descriptor of the write. */
	for (item = 0; item < write->count && !command->reader->error; item++) {
		view_id = fw_reader_u64(command->reader);
		if (write->set == NULL)
			continue;

		/* A buffer view of the session: its address, bytes and format. */
		view = fw_object_find(command->tag, view_id, FW_OBJ_BUFFER_VIEW);
		if (view == NULL) {
			command->status = FW_VK_ERROR_UNKNOWN;
			continue;
		}
		memset(&descriptor, 0, sizeof(descriptor));
		descriptor.type = write->type;
		descriptor.address = view->a;
		descriptor.bytes = view->b;
		descriptor.object = view->c;
		error = desc_find(write->set, write->binding, write->element + item, &index);
		if (error == 0)
			error = desc_put(write->set, index, &descriptor);
		if (error != 0)
			command->status = FW_VK_ERROR_UNKNOWN;
	}
}

/* Copies descriptors: [sType][u64 0][src set][binding][element][dst set][binding][element][count]. */
static void
desc_copy(
	struct fw_command *command)
{
	struct fw_descriptor descriptor;
	struct fw_object *src;
	struct fw_object *dst;
	uint64_t src_id;
	uint64_t dst_id;
	uint32_t src_binding;
	uint32_t src_element;
	uint32_t dst_binding;
	uint32_t dst_element;
	uint32_t count;
	uint32_t item;
	uint32_t src_index;
	uint32_t dst_index;
	int error;

	/* The copy's fields. */
	fw_wire_head(command);
	src_id = fw_reader_u64(command->reader);
	src_binding = fw_reader_u32(command->reader);
	src_element = fw_reader_u32(command->reader);
	dst_id = fw_reader_u64(command->reader);
	dst_binding = fw_reader_u32(command->reader);
	dst_element = fw_reader_u32(command->reader);
	count = fw_reader_u32(command->reader);
	if (command->reader->error)
		return;

	/* Both sets of the session. */
	src = fw_object_find(command->tag, src_id, FW_OBJ_DESC_SET);
	dst = fw_object_find(command->tag, dst_id, FW_OBJ_DESC_SET);
	if (src == NULL || dst == NULL) {
		command->status = FW_VK_ERROR_UNKNOWN;
		return;
	}

	/* Each descriptor read from the source and written to the destination. */
	for (item = 0; item < count; item++) {
		error = desc_find(src, src_binding, src_element + item, &src_index);
		if (error == 0)
			error = fw_descriptor_get(src, src_index, &descriptor);
		if (error == 0)
			error = desc_find(dst, dst_binding, dst_element + item, &dst_index);
		if (error == 0)
			error = desc_put(dst, dst_index, &descriptor);
		if (error != 0)
			command->status = FW_VK_ERROR_UNKNOWN;
	}
}

/*
 * Finds the descriptor of a binding's element in a set, following
 * Vulkan's rule that an update past a binding's count continues with the
 * next binding: gives the descriptor's index.
 *
 * Returns 0, or -1 when there is no such descriptor.
 */
static int
desc_find(
	struct fw_object *set,
	uint32_t binding,
	uint32_t element,
	uint32_t *index)
{
	struct fw_set_layout *layout;
	uint32_t entry;
	uint32_t next;
	int error;

	/* The set's table. */
	layout = &desc_work.layout;
	error = fw_store_flush();
	if (error == 0)
		error = fw_copy_in(set->block, layout, sizeof(*layout));
	if (error != 0)
		return -1;

	/* Walks from the binding, moving to the next binding number past its count. */
	for (;;) {
		next = 0xFFFFFFFFu;
		for (entry = 0; entry < layout->count; entry++) {
			if (layout->bindings[entry].binding == binding)
				break;
		}
		if (entry == layout->count)
			return -1;
		if (element < layout->bindings[entry].count) {
			*index = layout->bindings[entry].first + element;
			return 0;
		}

		/* The next binding number of the layout. */
		element -= layout->bindings[entry].count;
		for (entry = 0; entry < layout->count; entry++) {
			if (layout->bindings[entry].binding > binding && layout->bindings[entry].binding < next)
				next = layout->bindings[entry].binding;
		}
		if (next == 0xFFFFFFFFu)
			return -1;
		binding = next;
	}
}

/*
 * Finds the descriptor of a binding's element in a set for a draw: its
 * index and, for a dynamic buffer, its place among the set's dynamic
 * offsets (FW_NO_DYNAMIC otherwise).
 *
 * Returns 0, or -1 when the set has no such descriptor.
 */
int
fw_descriptor_lookup(
	struct fw_object *set,
	uint32_t binding,
	uint32_t element,
	uint32_t *index,
	uint32_t *dynamic)
{
	struct fw_layout_binding *entry;
	uint32_t number;
	int error;

	/* The descriptor's index (desc_find leaves the set's table in desc_work). */
	error = desc_find(set, binding, element, index);
	if (error != 0)
		return -1;

	/* Its binding's entry, for the dynamic offset's place. */
	*dynamic = FW_NO_DYNAMIC;
	for (number = 0; number < desc_work.layout.count; number++) {
		entry = &desc_work.layout.bindings[number];
		if (*index < entry->first || *index >= entry->first + entry->count)
			continue;
		if (entry->type == DESC_UNIFORM_DYNAMIC || entry->type == DESC_STORAGE_DYNAMIC)
			*dynamic = entry->dynamic_first + (*index - entry->first);
	}

	/* Succeeded: the descriptor's place. */
	return 0;
}

/* Writes one descriptor of a set through the store. */
static int
desc_put(
	struct fw_object *set,
	uint32_t index,
	const struct fw_descriptor *descriptor)
{
	uint32_t address;
	int error;

	/* Inside the set. */
	if (index >= set->a)
		return -1;

	/* The descriptor's bytes. */
	address = set->block + DESC_FIRST + index * sizeof(struct fw_descriptor);
	error = fw_store(address, descriptor, sizeof(*descriptor));
	if (error != 0)
		return -1;

	/* Succeeded: the descriptor is in the store's line. */
	return 0;
}

/* The bytes of a layout's block: the table and its immutable sampler words. */
static int
desc_layout_bytes(
	const struct fw_set_layout *layout)
{
	/* The table, then two words per immutable sampler. */
	return (int)(sizeof(struct fw_set_layout) + layout->immutable * 8u);
}
