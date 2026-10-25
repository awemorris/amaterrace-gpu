/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The sessions' Vulkan objects.  An object is named by (tag, identity,
 * kind) and found through a hash of the identity; another session's
 * identities are never seen.  An object may own a block of the heap.
 * Destroying an object returns what it owns: a pool its command buffers
 * or descriptor sets, a command buffer its recording, a device every
 * object made on it.
 */

#include "fw.h"

/* Objects the table holds, and its hash buckets (a power of two). */
#define OBJECT_MAX 512u
#define OBJECT_BUCKETS 128u

/*
 * The object table.
 *
 * A slot is in use when its kind is not FW_OBJ_FREE, and then it is on the
 * chain of exactly one bucket; a free slot is on no chain.
 */
static struct fw_object object_table[OBJECT_MAX];

/*
 * The chains of the hash buckets, indexed by object_hash().
 */
static struct fw_object *object_buckets[OBJECT_BUCKETS];

static uint32_t object_hash(uint64_t id);
static void object_unlink(struct fw_object *object);
static void object_release(struct fw_object *object);
static void object_children(struct fw_object *parent);
static int object_block(struct fw_object *object, uint32_t bytes, uint32_t visible);
static void object_free_block(struct fw_object *object);

/*
 * Empties the object table.
 */
void
fw_object_init(void)
{
	/* Every slot free, every chain empty. */
	memset(object_table, 0, sizeof(object_table));
	memset(object_buckets, 0, sizeof(object_buckets));
}

/*
 * Finds a session's object of one kind.
 *
 * Returns NULL when the session has no such object.
 */
struct fw_object *
fw_object_find(
	uint32_t tag,
	uint64_t id,
	uint32_t kind)
{
	struct fw_object *object;
	uint32_t bucket;

	/* The null handle names no object. */
	if (id == 0)
		return NULL;

	/* Walks the identity's chain. */
	bucket = object_hash(id);
	for (object = object_buckets[bucket];
	     object != NULL;
	     object = object->next) {
		if (object->id == id && object->tag == tag && object->kind == kind)
			return object;
	}

	/* No such object. */
	return NULL;
}

/*
 * Creates a session's object.
 *
 * Returns NULL when the table is full, the identity is the null handle or
 * it already names an object of the kind in the session.
 */
struct fw_object *
fw_object_create(
	uint32_t tag,
	uint64_t id,
	uint32_t kind)
{
	struct fw_object *object;
	struct fw_object *found;
	uint32_t bucket;
	uint32_t index;

	/* An identity names one object of a kind (libvulkan never reuses one). */
	found = fw_object_find(tag, id, kind);
	if (found != NULL || id == 0)
		return NULL;

	/* Takes a free slot. */
	object = NULL;
	for (index = 0; index < OBJECT_MAX; index++) {
		if (object_table[index].kind == FW_OBJ_FREE) {
			object = &object_table[index];
			break;
		}
	}

	/* The table is full. */
	if (object == NULL)
		return NULL;

	/* Initializes the object and puts it on its chain. */
	bucket = object_hash(id);
	memset(object, 0, sizeof(*object));
	object->id = id;
	object->tag = (uint8_t)tag;
	object->kind = (uint8_t)kind;
	object->next = object_buckets[bucket];
	object_buckets[bucket] = object;

	/* Succeeded: the new object, its fields zero. */
	return object;
}

/*
 * Gives an object a heap block of at least `bytes` (an earlier block is
 * returned first).
 *
 * Returns 0, or -1 when the heap or the session's limit has no room.
 */
int
fw_object_block(
	struct fw_object *object,
	uint32_t bytes)
{
	/* A block of the firmware's own. */
	return object_block(object, bytes, 0);
}

/*
 * Gives an object a heap block of at least `bytes` that its session's
 * work reaches (fw_heap_alloc_visible: an event's word, a query pool's
 * slots); an earlier block is returned first.
 *
 * Returns 0, or -1 when the heap or the session's limit has no room.
 */
int
fw_object_block_visible(
	struct fw_object *object,
	uint32_t bytes)
{
	/* A visible block, which goes back as one. */
	return object_block(object, bytes, FW_OBJF_VISIBLE);
}

/*
 * Destroys an object and what it owns.
 */
void
fw_object_destroy(
	struct fw_object *object)
{
	/* A pool takes its command buffers or descriptor sets with it. */
	if (object->kind == FW_OBJ_CMD_POOL || object->kind == FW_OBJ_DESC_POOL)
		object_children(object);

	/* The object itself. */
	object_release(object);
}

/*
 * Calls a function for each object whose parent is a pool.
 */
void
fw_object_each_child(
	struct fw_object *parent,
	void (*visit)(struct fw_object *child))
{
	uint32_t index;

	/* Each slot that names the pool as its parent. */
	for (index = 0; index < OBJECT_MAX; index++) {
		if (object_table[index].kind != FW_OBJ_FREE && object_table[index].parent == parent)
			visit(&object_table[index]);
	}
}

/*
 * Destroys every object of a session.
 */
void
fw_object_close(
	uint32_t tag)
{
	uint32_t index;

	/* Releases each of the session's slots. */
	for (index = 0; index < OBJECT_MAX; index++) {
		if (object_table[index].kind != FW_OBJ_FREE && object_table[index].tag == tag)
			object_release(&object_table[index]);
	}
}

/*
 * Destroys a device of a session and every object made on it.
 */
void
fw_object_close_device(
	uint32_t tag,
	uint64_t device)
{
	struct fw_object *found;
	uint32_t slot;
	uint32_t index;

	/* A device the firmware never saw has no objects. */
	found = fw_object_find(tag, device, FW_OBJ_DEVICE);
	if (found == NULL)
		return;

	/* Releases the device's objects, then the device. */
	slot = (uint32_t)(found - object_table);
	for (index = 0; index < OBJECT_MAX; index++) {
		if (object_table[index].kind != FW_OBJ_FREE &&
		    object_table[index].kind != FW_OBJ_DEVICE &&
		    object_table[index].tag == tag &&
		    object_table[index].device == slot)
			object_release(&object_table[index]);
	}
	object_release(found);
}

/*
 * Gives the slot of a session's device, which a create command names: the
 * first command that names a device makes its object (the driver keeps
 * vkCreateDevice to itself).
 *
 * Returns the slot, or -1 when the table is full.
 */
int
fw_object_device(
	uint32_t tag,
	uint64_t device)
{
	struct fw_object *found;

	/* An existing device. */
	found = fw_object_find(tag, device, FW_OBJ_DEVICE);
	if (found != NULL)
		return (int)(found - object_table);

	/* The first time the device is named. */
	found = fw_object_create(tag, device, FW_OBJ_DEVICE);
	if (found == NULL)
		return -1;

	/* Succeeded: the new device's slot. */
	return (int)(found - object_table);
}

/* Folds a 64-bit identity into a bucket index. */
static uint32_t
object_hash(
	uint64_t id)
{
	uint32_t folded;

	/* Mixes both halves; libvulkan's identities count up from small values. */
	folded = (uint32_t)id ^ (uint32_t)(id >> 32);
	folded ^= folded >> 16;
	folded *= 0x45D9F3Bu;
	folded ^= folded >> 16;

	/* Succeeded: the bucket. */
	return folded & (OBJECT_BUCKETS - 1u);
}

/* Takes an object off its chain. */
static void
object_unlink(
	struct fw_object *object)
{
	struct fw_object **link;

	/* Finds the link that points at the object. */
	link = &object_buckets[object_hash(object->id)];
	while (*link != NULL && *link != object)
		link = &(*link)->next;

	/* Unlinks it. */
	if (*link == object)
		*link = object->next;
}

/* Frees what an object owns and its slot. */
static void
object_release(
	struct fw_object *object)
{
	/* A command buffer's recording goes back to the heap. */
	if (object->kind == FW_OBJ_CMDBUF)
		fw_record_clear(object);

	/* A pipeline's scratch memory (a: its address, b: its bytes). */
	if (object->kind == FW_OBJ_PIPELINE) {
		fw_heap_free_visible(object->tag, object->a, object->b);
		object->a = 0;
		object->b = 0;
	}

	/* A protected session's own memory leaves the protection table. */
	if (object->kind == FW_OBJ_MEMORY && (object->flags & FW_OBJF_OWNED) != 0)
		fw_prot_disown(object->tag, object->a, object->b);

	/* So does the object's block. */
	object_free_block(object);

	/* The slot is free again. */
	object_unlink(object);
	object->kind = FW_OBJ_FREE;
	object->next = NULL;
	object->parent = NULL;
}

/* Gives an object a new block, visible (FW_OBJF_VISIBLE) or not; 0 or -1. */
static int
object_block(
	struct fw_object *object,
	uint32_t bytes,
	uint32_t visible)
{
	uint32_t block;

	/* The earlier block goes back. */
	object_free_block(object);

	/* A new block of whole lines. */
	if (visible != 0) {
		block = fw_heap_alloc_visible(object->tag, bytes);
	} else {
		block = fw_heap_alloc(object->tag, bytes);
	}
	if (block == 0)
		return -1;

	/* Succeeded: the object owns the block. */
	object->block = block;
	object->lines = (uint16_t)((bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES);
	object->flags |= (uint16_t)visible;
	return 0;
}

/* Gives an object's block back to the heap, as the kind of block it is. */
static void
object_free_block(
	struct fw_object *object)
{
	uint32_t bytes;

	/* A visible block goes back through its slab. */
	bytes = (uint32_t)object->lines * FW_LINE_BYTES;
	if ((object->flags & FW_OBJF_VISIBLE) != 0) {
		fw_heap_free_visible(object->tag, object->block, bytes);
	} else {
		fw_heap_free(object->tag, object->block, bytes);
	}

	/* The object has no block. */
	object->block = 0;
	object->lines = 0;
	object->flags &= (uint16_t)~FW_OBJF_VISIBLE;
}

/* Releases the objects whose parent is a pool. */
static void
object_children(
	struct fw_object *parent)
{
	uint32_t index;

	/* Each slot that names the pool as its parent. */
	for (index = 0; index < OBJECT_MAX; index++) {
		if (object_table[index].kind != FW_OBJ_FREE && object_table[index].parent == parent)
			object_release(&object_table[index]);
	}
}
