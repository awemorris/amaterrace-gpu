/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The firmware's heap and the sessions.
 *
 * The heap is a range of GPU memory the driver lends the firmware with
 * the GHCI_HEAP gpu-op (docs/ghci.md section 7.2); no other client is
 * given it.  It is handed out in whole lines, first fit, from a sorted
 * list of free extents kept in DMEM; neighbouring extents merge when a
 * block comes back.  The firmware reaches it only through the line DMA.
 *
 * A session is a JOB_TAG the driver opened (GHCI_SESSION_OPEN); each holds
 * the heap lines its objects use and may be given a limit.
 */

#include "fw.h"

/* Free extents the list can hold (fragmentation past this fails an allocation). */
#define HEAP_EXTENTS 128u

/*
 * One free extent of the heap, in lines from the heap's base.
 */
struct heap_extent {
	uint32_t first;
	uint32_t lines;
};

/*
 * One open session: its tag, the heap lines its objects hold, its limit
 * in lines (0: none), and whether a replay of its work failed after its
 * submit had answered (lost: its later submits run nothing).
 */
struct heap_session {
	uint32_t tag;
	uint32_t used;
	uint32_t limit;
	uint32_t open;
	uint32_t lost;
};

/*
 * The heap's base and size in lines; 0 lines until the driver lends it.
 */
static uint32_t heap_base;
static uint32_t heap_lines;

/*
 * The warps the GPU runs at once over its shader units (NSU x NWARPS),
 * which the driver reads from the GPU's registers and gives with
 * GHCI_HEAP: a program's scratch memory has a part for each.
 */
static uint32_t heap_warps = FW_RESIDENT_WARPS;

/*
 * The free extents, sorted by their first line and never touching each
 * other (a freed block merges with its neighbours), and how many are in
 * use.  An extent of 0 lines is never kept.
 */
static struct heap_extent heap_free_list[HEAP_EXTENTS];
static uint32_t heap_free_count;

/*
 * The open sessions; a slot whose `open` is 0 is free.
 */
static struct heap_session heap_sessions[FW_SESSIONS];

static struct heap_session *heap_session_of(uint32_t tag);
static void heap_insert(uint32_t first, uint32_t lines);
static void heap_remove(uint32_t index);

/*
 * Forgets the heap and every session (at start-up).
 */
void
fw_heap_init(void)
{
	/* No heap until GHCI_HEAP, no session. */
	heap_base = 0;
	heap_lines = 0;
	heap_free_count = 0;
	memset(heap_sessions, 0, sizeof(heap_sessions));
}

/*
 * Takes the range the driver lends as the heap, all of it free (but the
 * firmware's own part), and the warps the GPU runs at once.
 *
 * Returns 0, or -1 when the range is not whole lines or a session is open
 * (its objects would point into the old heap).
 */
int
fw_heap_set(
	uint32_t base,
	uint32_t bytes,
	uint32_t warps)
{
	int open;
	int error;

	/* The heap can change only while no object lives in it. */
	open = fw_session_any();
	if (open)
		return -1;

	/* Whole lines, not wrapping the address space. */
	if ((base & (FW_LINE_BYTES - 1u)) != 0 || (bytes & (FW_LINE_BYTES - 1u)) != 0)
		return -1;
	if (bytes == 0 || base + bytes < base)
		return -1;

	/* The firmware's own part first, then one free extent of the rest. */
	if (bytes <= FW_BUILTIN_BYTES)
		return -1;
	error = fw_builtin_init(base);
	if (error != 0)
		return -1;
	heap_base = base;
	heap_lines = bytes / FW_LINE_BYTES;
	heap_warps = FW_RESIDENT_WARPS;
	if (warps != 0)
		heap_warps = warps;
	heap_free_list[0].first = FW_BUILTIN_BYTES / FW_LINE_BYTES;
	heap_free_list[0].lines = heap_lines - heap_free_list[0].first;
	heap_free_count = 1;

	/* Succeeded: the heap is ready. */
	return 0;
}

/*
 * Gives the warps the GPU runs at once (for scratch memory).
 */
uint32_t
fw_heap_warps(void)
{
	/* As GHCI_HEAP said. */
	return heap_warps;
}

/*
 * Reports whether the driver has lent the heap.
 */
int
fw_heap_ready(void)
{
	/* A heap of no lines is no heap. */
	if (heap_lines == 0)
		return 0;

	/* Succeeded: objects can be made. */
	return 1;
}

/*
 * Takes a block of whole lines for a session's object.
 *
 * Returns the block's GPU address, or 0 when the heap or the session's
 * limit has no room for it.
 */
uint32_t
fw_heap_alloc(
	uint32_t tag,
	uint32_t bytes)
{
	struct heap_session *session;
	uint32_t lines;
	uint32_t index;
	uint32_t first;

	/* The session pays for the lines. */
	session = heap_session_of(tag);
	if (session == NULL || bytes == 0)
		return 0;
	lines = (bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES;
	if (session->limit != 0 && session->used + lines > session->limit)
		return 0;

	/* The first extent that is large enough. */
	for (index = 0; index < heap_free_count; index++) {
		if (heap_free_list[index].lines >= lines)
			break;
	}

	/* No extent has room. */
	if (index == heap_free_count)
		return 0;

	/* Takes the extent's first lines; an extent used up leaves the list. */
	first = heap_free_list[index].first;
	heap_free_list[index].first += lines;
	heap_free_list[index].lines -= lines;
	if (heap_free_list[index].lines == 0) {
		heap_remove(index);
	}

	/* The session holds them. */
	session->used += lines;

	/* Succeeded: the block's address. */
	return heap_base + first * FW_LINE_BYTES;
}

/*
 * Takes a block of whole lines for a session's object at an address
 * aligned to `align` bytes (a power of two of at least a line: the 4 KiB
 * granules of session protection).
 *
 * Returns the block's GPU address, or 0 when the heap or the session's
 * limit has no room for it.
 */
uint32_t
fw_heap_alloc_aligned(
	uint32_t tag,
	uint32_t bytes,
	uint32_t align)
{
	struct heap_session *session;
	uint32_t lines;
	uint32_t index;
	uint32_t start;
	uint32_t aligned;
	uint32_t before;
	uint32_t after;
	uint32_t first;

	/* The session pays for the lines. */
	session = heap_session_of(tag);
	if (session == NULL || bytes == 0)
		return 0;
	lines = (bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES;
	if (session->limit != 0 && session->used + lines > session->limit)
		return 0;

	/* The first extent with room for the block after its aligned start. */
	before = 0;
	for (index = 0; index < heap_free_count; index++) {
		start = heap_base + heap_free_list[index].first * FW_LINE_BYTES;
		aligned = (start + align - 1u) & ~(align - 1u);
		before = (aligned - start) / FW_LINE_BYTES;
		if (heap_free_list[index].lines >= before + lines)
			break;
	}

	/* No extent has room. */
	if (index == heap_free_count)
		return 0;

	/* The lines before the block stay free; the ones after it are a new extent. */
	first = heap_free_list[index].first + before;
	after = heap_free_list[index].lines - before - lines;
	if (before == 0) {
		heap_free_list[index].first += lines;
		heap_free_list[index].lines -= lines;
		if (heap_free_list[index].lines == 0)
			heap_remove(index);
	} else {
		heap_free_list[index].lines = before;
		if (after != 0)
			heap_insert(first + lines, after);
	}

	/* The session holds them. */
	session->used += lines;

	/* Succeeded: the block's address. */
	return heap_base + first * FW_LINE_BYTES;
}

/*
 * Gives a session's block back to the heap.
 */
void
fw_heap_free(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes)
{
	struct heap_session *session;
	uint32_t lines;

	/* Nothing to give back. */
	if (address == 0 || bytes == 0)
		return;

	/* The session no longer pays for the lines. */
	lines = (bytes + FW_LINE_BYTES - 1u) / FW_LINE_BYTES;
	session = heap_session_of(tag);
	if (session != NULL && session->used >= lines)
		session->used -= lines;

	/* The lines are free again. */
	heap_insert((address - heap_base) / FW_LINE_BYTES, lines);
}

/*
 * Opens a session with a limit of heap bytes (0: no limit).
 *
 * Returns 0, -1 when it is open already, or -2 when no slot is free.
 */
int
fw_session_open(
	uint32_t tag,
	uint64_t limit)
{
	struct heap_session *session;
	uint32_t index;

	/* A session is opened once until it is closed. */
	session = heap_session_of(tag);
	if (session != NULL)
		return -1;

	/* A free slot. */
	for (index = 0; index < FW_SESSIONS; index++) {
		if (!heap_sessions[index].open)
			break;
	}

	/* Every slot is in use. */
	if (index == FW_SESSIONS)
		return -2;

	/* The session, with its limit in lines (a limit above the heap is none). */
	session = &heap_sessions[index];
	session->tag = tag;
	session->used = 0;
	session->limit = 0;
	if (limit != 0 && limit < (uint64_t)heap_lines * FW_LINE_BYTES)
		session->limit = (uint32_t)(limit / FW_LINE_BYTES);
	session->lost = 0;
	session->open = 1;

	/* Succeeded: the tag's objects can be made. */
	return 0;
}

/*
 * Reports whether a session is open.
 */
int
fw_session_is_open(
	uint32_t tag)
{
	struct heap_session *session;

	/* The tag's slot. */
	session = heap_session_of(tag);
	if (session == NULL)
		return 0;

	/* Succeeded: it is open. */
	return 1;
}

/*
 * Marks a session lost: a replay of its work failed after its submit had
 * answered.
 */
void
fw_session_lose(
	uint32_t tag)
{
	struct heap_session *session;

	/* The tag's slot; a closed session has nothing to lose. */
	session = heap_session_of(tag);
	if (session == NULL)
		return;

	/* Its later submits answer VK_ERROR_DEVICE_LOST. */
	session->lost = 1;
}

/*
 * Reports whether a session is lost (fw_session_lose).
 */
int
fw_session_lost(
	uint32_t tag)
{
	struct heap_session *session;

	/* The tag's slot; a session that is not open is not lost. */
	session = heap_session_of(tag);
	if (session == NULL)
		return 0;
	if (!session->lost)
		return 0;

	/* Succeeded: the session is lost. */
	return 1;
}

/*
 * Closes a session and returns its objects.
 */
void
fw_session_close(
	uint32_t tag)
{
	struct heap_session *session;

	/* The objects first: they give their blocks back while the session pays. */
	fw_object_close(tag);

	/* The slot is free. */
	session = heap_session_of(tag);
	if (session != NULL)
		session->open = 0;
}

/*
 * Reports whether any session is open.
 */
int
fw_session_any(void)
{
	uint32_t index;

	/* Looks at each slot. */
	for (index = 0; index < FW_SESSIONS; index++) {
		if (heap_sessions[index].open)
			return 1;
	}

	/* No session is open. */
	return 0;
}

/* Finds an open session's slot, or NULL. */
static struct heap_session *
heap_session_of(
	uint32_t tag)
{
	uint32_t index;

	/* Looks for the tag among the open slots. */
	for (index = 0; index < FW_SESSIONS; index++) {
		if (heap_sessions[index].open && heap_sessions[index].tag == tag)
			return &heap_sessions[index];
	}

	/* The session is not open. */
	return NULL;
}

/* Puts lines back on the free list, merging them with their neighbours. */
static void
heap_insert(
	uint32_t first,
	uint32_t lines)
{
	uint32_t index;
	struct heap_extent *before;
	struct heap_extent *after;

	/* The place in the sorted list: the first extent after the lines. */
	for (index = 0; index < heap_free_count; index++) {
		if (heap_free_list[index].first > first)
			break;
	}

	/* The neighbours. */
	before = NULL;
	after = NULL;
	if (index > 0)
		before = &heap_free_list[index - 1u];
	if (index < heap_free_count)
		after = &heap_free_list[index];

	/* Joins the extent before, and the one after through it. */
	if (before != NULL && before->first + before->lines == first) {
		before->lines += lines;
		if (after != NULL && before->first + before->lines == after->first) {
			before->lines += after->lines;
			heap_remove(index);
		}
		return;
	}

	/* Joins the extent after. */
	if (after != NULL && first + lines == after->first) {
		after->first = first;
		after->lines += lines;
		return;
	}

	/* A list without room loses the lines (the heap shrinks; it cannot fail here). */
	if (heap_free_count == HEAP_EXTENTS)
		return;

	/* A new extent between its neighbours: the later ones move up by one. */
	for (after = &heap_free_list[heap_free_count];
	     after > &heap_free_list[index];
	     after--) {
		*after = *(after - 1);
	}
	heap_free_list[index].first = first;
	heap_free_list[index].lines = lines;
	heap_free_count++;
}

/* Takes an extent off the list: the later ones move down by one. */
static void
heap_remove(
	uint32_t index)
{
	uint32_t next;

	/* Moves each later extent into the place before it. */
	for (next = index + 1u; next < heap_free_count; next++)
		heap_free_list[next - 1u] = heap_free_list[next];
	heap_free_count--;
}
