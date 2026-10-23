/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The sessions and their Vulkan objects.  A session is a JOB_TAG the
 * driver opened (GHCI_SESSION_OPEN); its objects are named by (tag,
 * identity) and found through a hash of the identity.  Another session's
 * identities are never seen.
 */

#include "fw.h"

/* Objects the table holds, and its hash buckets (a power of two). */
#define OBJECT_MAX 96u
#define OBJECT_BUCKETS 64u

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

/*
 * The open sessions, one bit per JOB_TAG.
 */
static uint32_t session_open[8];

static uint32_t object_hash(uint64_t id);
static void object_unlink(struct fw_object *object);
static void object_release(struct fw_object *object);

/*
 * Empties the object table and closes every session.
 */
void
fw_object_init(void)
{
	/* Every slot free, every chain empty, no session open. */
	memset(object_table, 0, sizeof(object_table));
	memset(object_buckets, 0, sizeof(object_buckets));
	memset(session_open, 0, sizeof(session_open));
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
 * Returns NULL when the table is full or the identity is already in use
 * in the session.
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

	/* An identity names one object of a session (libvulkan never reuses one). */
	bucket = object_hash(id);
	for (found = object_buckets[bucket];
	     found != NULL;
	     found = found->next) {
		if (found->id == id && found->tag == tag)
			return NULL;
	}

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
 * Destroys an object and what it owns (a pool's command buffers, a
 * command buffer's recording).
 */
void
fw_object_destroy(
	struct fw_object *object)
{
	uint32_t index;

	/* A pool takes its command buffers with it. */
	if (object->kind == FW_OBJ_POOL) {
		for (index = 0; index < OBJECT_MAX; index++) {
			if (object_table[index].kind == FW_OBJ_CMDBUF &&
			    object_table[index].tag == object->tag &&
			    object_table[index].pool == object->id)
				object_release(&object_table[index]);
		}
	}

	/* The object itself. */
	object_release(object);
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
 * Opens a session.
 *
 * Returns 0, or -1 when it is open already.
 */
int
fw_session_open(
	uint32_t tag)
{
	uint32_t bit;

	/* A session is opened once until it is closed. */
	bit = 1u << (tag & 31u);
	if ((session_open[(tag >> 5) & 7u] & bit) != 0)
		return -1;

	/* Succeeded: the tag's objects can be made. */
	session_open[(tag >> 5) & 7u] |= bit;
	return 0;
}

/*
 * Reports whether a session is open.
 */
int
fw_session_is_open(
	uint32_t tag)
{
	uint32_t bit;

	/* The tag's bit. */
	bit = 1u << (tag & 31u);
	if ((session_open[(tag >> 5) & 7u] & bit) != 0)
		return 1;

	/* Not open. */
	return 0;
}

/*
 * Closes a session and returns its objects.
 */
void
fw_session_close(
	uint32_t tag)
{
	/* The objects, then the session's bit. */
	fw_object_close(tag);
	session_open[(tag >> 5) & 7u] &= ~(1u << (tag & 31u));
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

/* Frees an object's recording and its slot. */
static void
object_release(
	struct fw_object *object)
{
	/* A command buffer's chunks go back to the heap. */
	if (object->kind == FW_OBJ_CMDBUF)
		fw_uop_clear(object);

	/* The slot is free again. */
	object_unlink(object);
	object->kind = FW_OBJ_FREE;
	object->next = NULL;
}
