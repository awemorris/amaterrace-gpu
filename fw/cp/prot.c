/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * Session protection (docs/ghci.md section 11.6): the protected sessions'
 * slots, the protection table the driver lends (one byte per 4 KiB granule
 * of the aperture: [5:0] the owner's slot, [6] read-only, [7] public), the
 * grant CAM, and the drains that make a revoke or a close apply after the
 * earlier work.  The checks themselves are the GPU's (the MC's root, the
 * CP's atg_cp_prot); the firmware keeps their tables.
 *
 * The table is written only through the DMA with tbl (FW_DMA_TBL); after a
 * write's answer the firmware invalidates the MC's copy of the range
 * (PROT_INV), and it waits for PROT_INFO's pending bit to fall before its
 * next invalidation.
 */

#include "fw.h"
#include "ghci_frame.h"
#include "hw.h"

#define PROT_GRANULE_SHIFT 12u
#define PROT_GRANULE (1u << PROT_GRANULE_SHIFT)
#define PROT_OWNER 0x3Fu
#define PROT_READ_ONLY 0x40u
#define PROT_PUBLIC 0x80u

/* prot_table_write's value that only checks that every byte is 0. */
#define PROT_CHECK 0x100u

/* The grant entries the firmware keeps (the GPU's are PROT_INFO[31:16], at most these). */
#define PROT_CAM 64u

/*
 * One protected session: its tag and slot (0: the entry is free), how many
 * granules the table gives it, whether a write of its bytes failed part
 * way (its close then sweeps the whole table).
 *
 * The objects that own its granules (its memory objects, its visible
 * slabs and blocks) give them back as they are released, the last at its
 * close; a count left above 0 then also makes the close sweep.
 */
struct prot_session {
	uint32_t tag;
	uint32_t slot;
	uint32_t granules;
	uint32_t sweep;
};

/*
 * One grant entry as the firmware wrote it into the CAM: the slot (0: the
 * entry is free) and the granules [first, end).
 */
struct prot_grant {
	uint32_t slot;
	uint32_t first;
	uint32_t end;
};

/*
 * What the GPU has: the PROT capability (0: none, every protected request
 * is refused), its slots and its grant entries; read at start-up.
 */
static int prot_present;
static uint32_t prot_slots;
static uint32_t prot_grants;

/*
 * The protected sessions, by slot (entry 0 is never used); an entry whose
 * slot is 0 is free.  Kept until the session closes; RESET loses them with
 * the firmware's other state.  The firmware uses at most FW_SESSIONS - 1
 * slots (the GPU may have more).
 */
static struct prot_session prot_sessions[FW_SESSIONS];

/*
 * The grant entries, in the order of the CAM's.
 */
static struct prot_grant prot_cam[PROT_CAM];

/*
 * The slot the last open took: the next open tries the slots after it
 * first, so that a slot just closed is used again last.
 */
static uint32_t prot_last_slot;

/*
 * The bytes the last prot_table_write cleared for a slot.
 */
static uint32_t prot_cleared;

/*
 * The line of the table being read or changed.
 */
static uint8_t prot_line[FW_LINE_BYTES] __attribute__((aligned(FW_LINE_BYTES)));

static struct prot_session *prot_session_of(uint32_t tag);
static int prot_table_write(uint32_t first, uint32_t count, uint32_t slot, uint32_t value);
static void prot_invalidate(uint32_t first, uint32_t count);
static void prot_wait_pending(void);
static void prot_cam_write(uint32_t index, uint32_t slot, uint32_t access, uint32_t first, uint32_t end);
static int prot_range_of(uint32_t address, uint32_t bytes, uint32_t *first, uint32_t *count);

/*
 * Reads what session protection the GPU has (at start-up and after RESET).
 */
void
fw_prot_init(void)
{
	uint32_t info;

	/* PROT_INFO reads 0 on a GPU without the capability. */
	info = hw_read(HW_PROT_INFO);
	prot_present = 0;
	if ((info & HW_PROT_INFO_HAS) != 0)
		prot_present = 1;
	prot_slots = (info >> 8) & 0x3Fu;
	if (prot_slots > FW_SESSIONS - 1u)
		prot_slots = FW_SESSIONS - 1u;
	prot_grants = info >> 16;
	if (prot_grants > PROT_CAM)
		prot_grants = PROT_CAM;

	/* No session and no grant survives a reset. */
	memset(prot_sessions, 0, sizeof(prot_sessions));
	memset(prot_cam, 0, sizeof(prot_cam));
	prot_last_slot = 0;
}

/*
 * Reports whether the GPU has session protection.
 */
int
fw_prot_present(void)
{
	/* As PROT_INFO said at start-up. */
	return prot_present;
}

/*
 * Gives the slot of a protected session (0: the tag is not protected).
 */
uint32_t
fw_prot_slot(
	uint32_t tag)
{
	struct prot_session *session;

	/* The tag's entry. */
	session = prot_session_of(tag);
	if (session == NULL)
		return 0;

	/* Succeeded: its slot. */
	return session->slot;
}

/*
 * Opens a protected session: takes a slot and maps the tag to it.
 *
 * Returns 0, -1 without the capability or for tag 0, -2 without the table,
 * or -3 when every slot is in use.
 */
int
fw_prot_open(
	uint32_t tag)
{
	struct prot_session *session;
	uint32_t slot;
	uint32_t tried;

	/* Session 0 is the driver's own; a GPU without protection has none. */
	if (!prot_present || tag == 0)
		return -1;

	/* The table must be lent first. */
	if (hw_read(HW_PROT_TBASE) == 0)
		return -2;

	/* The slots after the last one taken first (round robin); each slot's entry is its own. */
	slot = 0;
	for (tried = 1; tried <= prot_slots; tried++) {
		slot = (prot_last_slot + tried - 1u) % prot_slots + 1u;
		if (prot_sessions[slot].slot == 0)
			break;
	}

	/* Every slot is in use. */
	if (tried > prot_slots)
		return -3;

	/* The session, with no granules and no grants yet. */
	session = &prot_sessions[slot];
	memset(session, 0, sizeof(*session));
	session->tag = tag;
	session->slot = slot;
	prot_last_slot = slot;

	/* SLOT_MAP: the tag's work is checked for the slot from here. */
	hw_write(HW_PROT_SLOT, (slot << 8) | tag);

	/* Succeeded: the session is protected. */
	return 0;
}

/*
 * Gives a protected session the range of a memory object it registers
 * (MEMORY): the range's bytes must belong to nobody.
 *
 * Returns 1 when the range is the session's, 0 for a session that is not
 * protected, or -1 when the range is not granule aligned or not free, or
 * the memory refused a line.
 */
int
fw_prot_own(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes,
	int read_only)
{
	struct prot_session *session;
	uint32_t first;
	uint32_t count;
	uint32_t value;
	int error;

	/* Only a protected session's memory is in the table. */
	session = prot_session_of(tag);
	if (session == NULL)
		return 0;

	/* Whole granules. */
	error = prot_range_of(address, bytes, &first, &count);
	if (error != 0)
		return -1;

	/* Every byte of the range must be free: the memory is nobody's yet. */
	error = prot_table_write(first, count, 0, PROT_CHECK);
	if (error != 0)
		return -1;

	/* The session owns the range, read-only when asked. */
	value = session->slot;
	if (read_only)
		value |= PROT_READ_ONLY;
	error = prot_table_write(first, count, 0, value);
	if (error != 0) {
		/* Some bytes may say the session: the close sweeps them. */
		session->sweep = 1;
		return -1;
	}

	/* Succeeded: the session's work reaches the range; its release gives it back. */
	session->granules += count;
	return 1;
}

/*
 * Ends a protected session's ownership of a range (a memory object's
 * release, a visible slab or block given back).
 */
void
fw_prot_disown(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes)
{
	struct prot_session *session;
	uint32_t first;
	uint32_t count;
	int error;

	/* Only a protected session's ranges are in the table. */
	session = prot_session_of(tag);
	if (session == NULL)
		return;
	error = prot_range_of(address, bytes, &first, &count);
	if (error != 0)
		return;

	/*
	 * The session's bytes of the range become free; a failed write leaves
	 * the close a sweep (so does a count that does not add up: it is not 0
	 * at the close).
	 */
	prot_cleared = 0;
	error = prot_table_write(first, count, session->slot, 0);
	if (error != 0)
		session->sweep = 1;
	session->granules -= prot_cleared;
}

/*
 * Makes a range public: every protected session may read it (the
 * firmware's identity buffer and built-in programs).
 *
 * Returns 0 (also without a table), or -1 when the memory refused a line.
 */
int
fw_prot_public(
	uint32_t address,
	uint32_t bytes)
{
	uint32_t first;
	uint32_t count;
	int error;

	/* Nothing to mark without the table (a GPU without the capability reads 0). */
	if (hw_read(HW_PROT_TBASE) == 0)
		return 0;

	/* Whole granules (the caller keeps the range aligned). */
	error = prot_range_of(address, bytes, &first, &count);
	if (error != 0)
		return -1;

	/* The range's bytes say public. */
	error = prot_table_write(first, count, 0, PROT_PUBLIC);
	if (error != 0)
		return -1;

	/* Succeeded: every protected session reads it. */
	return 0;
}

/*
 * Grants a protected session access to a range it does not own
 * (BUFFER_GRANT).  It applies to work after it (a grant needs no drain).
 *
 * Returns 0, -1 when the session is not protected or the range is not
 * granule aligned, or -2 when the CAM is full (its entries are one pool
 * for all the sessions, first come: a session may take every entry).
 */
int
fw_prot_grant(
	uint32_t tag,
	uint32_t access,
	uint32_t address,
	uint32_t bytes)
{
	struct prot_session *session;
	uint32_t first;
	uint32_t count;
	uint32_t index;
	int error;

	/* A grant to a session that is not protected means nothing. */
	session = prot_session_of(tag);
	if (session == NULL)
		return -1;

	/* Whole granules. */
	error = prot_range_of(address, bytes, &first, &count);
	if (error != 0)
		return -1;

	/* A free entry. */
	for (index = 0; index < prot_grants; index++) {
		if (prot_cam[index].slot == 0)
			break;
	}

	/* The CAM is full. */
	if (index == prot_grants)
		return -2;

	/* The entry: from the next request the MC judges, the range is the session's too. */
	prot_cam_write(index, session->slot, access, first, first + count);

	/* Succeeded: the grant is in the CAM. */
	return 0;
}

/*
 * Removes one grant of exactly a range (BUFFER_REVOKE), after the earlier
 * work has finished.
 *
 * Returns 0 (also when no such grant exists), or -1 when the session is not
 * protected or the units did not drain.
 */
int
fw_prot_revoke(
	uint32_t tag,
	uint32_t address,
	uint32_t bytes)
{
	struct prot_session *session;
	uint32_t first;
	uint32_t count;
	uint32_t index;
	int error;

	/* Only a protected session has grants. */
	session = prot_session_of(tag);
	if (session == NULL)
		return -1;
	error = prot_range_of(address, bytes, &first, &count);
	if (error != 0)
		return 0;

	/* The work before the revoke keeps its access until it is done. */
	error = fw_prot_drain();
	if (error != 0)
		return -1;

	/* One entry of the range, if any. */
	for (index = 0; index < prot_grants; index++) {
		if (prot_cam[index].slot == session->slot &&
		    prot_cam[index].first == first &&
		    prot_cam[index].end == first + count)
			break;
	}

	/* No such grant: nothing to do. */
	if (index == prot_grants)
		return 0;

	/* The entry is invalid in the CAM and free here. */
	prot_cam_write(index, 0, 0, 0, 0);

	/* Succeeded: the grant is gone. */
	return 0;
}

/*
 * Ends a protected session (SESSION_CLOSE), after its drain and after its
 * objects gave their granules back: the bytes still saying its slot (a
 * write that failed, a granule not given back) are swept from the whole
 * table, its grants go, and its slot is unmapped.
 */
void
fw_prot_close(
	uint32_t tag)
{
	struct prot_session *session;
	uint32_t index;
	uint32_t g0;
	uint32_t g1;

	/* Only a protected session has a slot. */
	session = prot_session_of(tag);
	if (session == NULL)
		return;

	/* The whole table, only when some of its bytes may be left (rare: about 10 ms for 1 MiB). */
	if (session->sweep || session->granules != 0) {
		g0 = hw_read(HW_PROT_G0);
		g1 = hw_read(HW_PROT_G1);
		(void)prot_table_write(g0, g1 - g0, session->slot, 0);
	}

	/* Its grants. */
	for (index = 0; index < prot_grants; index++) {
		if (prot_cam[index].slot == session->slot)
			prot_cam_write(index, 0, 0, 0, 0);
	}

	/* SLOT_MAP: the tag is unchecked again, and the slot's data in the units is foreign. */
	hw_write(HW_PROT_SLOT, tag);
	session->slot = 0;
	session->tag = 0;
}

/*
 * Waits until the units have finished the work before this point and no
 * checked request is left in the MC (a revoke's and a close's order).
 *
 * Returns 0, or -1 when the wait failed (the watchdog will fault).
 */
int
fw_prot_drain(void)
{
	uint32_t info;
	uint32_t polls;
	int error;

	/* The units' work and its memory accesses, through the firmware's own µops. */
	error = fw_wait_units();
	if (error != 0)
		return -1;

	/* No checked request in flight (PROT_INFO's drained bit). */
	for (polls = 0; polls < 0x100000u; polls++) {
		info = hw_read(HW_PROT_INFO);
		if ((info & HW_PROT_INFO_DRAINED) != 0)
			return 0;
	}

	/* The units did not drain. */
	return -1;
}

/* Finds a protected session's entry, or NULL. */
static struct prot_session *
prot_session_of(
	uint32_t tag)
{
	uint32_t index;

	/* The entry with the tag and a slot. */
	for (index = 0; index < FW_SESSIONS; index++) {
		if (prot_sessions[index].slot != 0 && prot_sessions[index].tag == tag)
			return &prot_sessions[index];
	}

	/* The tag is not protected. */
	return NULL;
}

/* Gives a byte range's granules; -1 when it is not granule aligned or empty. */
static int
prot_range_of(
	uint32_t address,
	uint32_t bytes,
	uint32_t *first,
	uint32_t *count)
{
	/* Whole granules only. */
	if ((address & (PROT_GRANULE - 1u)) != 0 || (bytes & (PROT_GRANULE - 1u)) != 0)
		return -1;
	if (bytes == 0)
		return -1;

	/* Succeeded: the granule numbers. */
	*first = address >> PROT_GRANULE_SHIFT;
	*count = bytes >> PROT_GRANULE_SHIFT;
	return 0;
}

/*
 * Writes the granules' bytes: every byte to value, or (slot not 0) the
 * bytes that slot owns to 0, counting them in prot_cleared;
 * then invalidates the MC's copy.  With PROT_CHECK, only checks that every
 * byte is 0.  -1 on a memory error (or a byte that is not 0).
 */
static int
prot_table_write(
	uint32_t first,
	uint32_t count,
	uint32_t slot,
	uint32_t value)
{
	uint32_t tbase;
	uint32_t g0;
	uint32_t g1;
	uint32_t index;
	uint32_t end;
	uint32_t line;
	uint32_t byte;
	uint32_t mode;
	uint32_t old;
	uint32_t new;
	int changed;
	int error;

	/* The table's place and the granules it covers. */
	tbase = hw_read(HW_PROT_TBASE);
	g0 = hw_read(HW_PROT_G0);
	g1 = hw_read(HW_PROT_G1);
	if (tbase == 0 || first < g0 || first + count > g1 || first + count < first)
		return -1;

	/* Each line: read, change, write back with tbl (the only writes the table takes). */
	error = 0;
	index = first - g0;
	end = index + count;
	while (index < end && error == 0) {
		line = (tbase + index) & ~(FW_LINE_BYTES - 1u);
		error = fw_dma_read(line, prot_line, 1);
		if (error != 0)
			break;
		changed = 0;
		for (byte = (tbase + index) - line; byte < FW_LINE_BYTES && index < end; byte++) {
			index++;
			old = prot_line[byte];
			if (value == PROT_CHECK) {
				if (old != 0)
					return -1;
				continue;
			}

			/* The new byte: the value, or 0 for a byte the slot owns (not a public one). */
			new = value;
			if (slot != 0) {
				new = old;
				if ((old & (PROT_PUBLIC | PROT_OWNER)) == slot)
					new = 0;
			}
			if (new != old) {
				prot_line[byte] = (uint8_t)new;
				changed = 1;
				prot_cleared += slot != 0;
			}
		}
		if (changed) {
			mode = fw_dma_mode(FW_DMA_TBL);
			error = fw_dma_write(line, prot_line, 1);
			(void)fw_dma_mode(mode);
		}
	}

	/* The MC's copy of the range, after the writes' answers (a check wrote none). */
	if (value != PROT_CHECK)
		prot_invalidate(first, count);

	/* A refused line. */
	if (error != 0)
		return -1;

	/* Succeeded: the table says it. */
	return 0;
}

/* Invalidates the MC's copy of the granules, one invalidation at a time. */
static void
prot_invalidate(
	uint32_t first,
	uint32_t count)
{
	/* The previous invalidation has finished (a walk it made stale was read again). */
	prot_wait_pending();

	/* The range; writing the count starts it. */
	hw_write(HW_PROT_INV_G, first);
	hw_write(HW_PROT_INV_N, count);
}

/* Waits until no invalidation is pending in the MC. */
static void
prot_wait_pending(void)
{
	uint32_t info;
	uint32_t polls;

	/* PROT_INFO[3] falls when the walk is read again; bounded (the watchdog is the net). */
	for (polls = 0; polls < 0x100000u; polls++) {
		info = hw_read(HW_PROT_INFO);
		if ((info & HW_PROT_INFO_PENDING) == 0)
			return;
	}
}

/* Writes one CAM entry and the firmware's copy (slot 0: invalid, free). */
static void
prot_cam_write(
	uint32_t index,
	uint32_t slot,
	uint32_t access,
	uint32_t first,
	uint32_t end)
{
	uint32_t control;

	/* The copy the firmware finds entries by. */
	prot_cam[index].slot = slot;
	prot_cam[index].first = first;
	prot_cam[index].end = end;

	/* The entry's range, then its control word, which writes it. */
	hw_write(HW_PROT_GIDX, index);
	hw_write(HW_PROT_GBASE, first);
	hw_write(HW_PROT_GLIMIT, end);
	control = slot << 8;
	if (slot != 0) {
		control |= HW_PROT_GCTL_VALID;
		if ((access & GHCI_GRANT_READ) != 0)
			control |= HW_PROT_GCTL_READ;
		if ((access & GHCI_GRANT_WRITE) != 0)
			control |= HW_PROT_GCTL_WRITE;
	}
	hw_write(HW_PROT_GCTL, control);
}
