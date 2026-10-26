/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The host test of the GHCI driver's arithmetic on words
 * (src/drivers/gpu/ghci/ghci-words.h): the fence comparison and its
 * wrap, the ring's room and padding (with a long run of a writer and a
 * reader around the ring), the walk of the extended capability list, the
 * allocator of GPU addresses (against a reference map of pages), the
 * packets the driver writes, the check of a native command stream, the
 * capability record and the table of job markers.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "drivers/gpu/ghci/ghci-words.h"
#include "drivers/gpu/ghci/hcr.h"
#include "drivers/gpu/ghci/packets.h"
#include "uapi/gpu-op.h"

/* The words of the fake register window the capability walk reads (128 KiB). */
#define WINDOW_WORDS			32768U

/* The pages of the allocator's stress range, and its page. */
#define STRESS_PAGES			256U
#define STRESS_PAGE			4096U

/* The most runs the stress keeps at once. */
#define STRESS_RUNS			64U

/* The allocations the native check's owner holds. */
#define OWNED_RUNS			2U

/*
 * The counts of the checks that held and that failed.  Every check adds
 * to one of them; main reports both and fails when any check failed.
 */
static unsigned checks_passed;
static unsigned checks_failed;

/* The fake register window that the capability walk reads through window_read. */
static uint32_t window[WINDOW_WORDS];

/*
 * The runs of GPU memory the native check's owner reports as the
 * session's: address and bytes of each.
 */
static uint32_t owned_address[OWNED_RUNS];
static uint32_t owned_bytes[OWNED_RUNS];

static void expect(int held, const char *name);
static uint32_t window_read(void *context, uint32_t offset);
static int owned(void *context, uint32_t address, uint32_t bytes);
static uint32_t next_random(uint32_t *state);
static void test_fences(void);
static void test_ring(void);
static void test_ring_stress(void);
static void test_extcap(void);
static void test_range(void);
static void test_range_stress(void);
static void test_packets(void);
static void test_native(void);
static void test_capset(void);
static void test_jobs(void);
static uint32_t native_stream(uint32_t *stream, const uint32_t *packets, uint32_t packet_count, uint32_t dwords);
static uint32_t fill_packets(uint32_t *out, uint32_t base, uint32_t stride, uint32_t xy, uint32_t size);

/*
 * Runs every test and reports the counts.
 */
int
main(void)
{
	/* Each part of the arithmetic in turn. */
	test_fences();
	test_ring();
	test_ring_stress();
	test_extcap();
	test_range();
	test_range_stress();
	test_packets();
	test_native();
	test_capset();
	test_jobs();

	/* Reports the counts of the checks. */
	printf("ghci-host-test: %u passed, %u failed\n", checks_passed, checks_failed);

	/* A failed check fails the test. */
	if (checks_failed != 0U)
		return 1;

	/* Succeeded: every check held. */
	return 0;
}

/* Counts one check, and names it when it failed. */
static void
expect(
	int held,
	const char *name)
{
	/* A check that held is only counted. */
	if (held) {
		checks_passed++;
		return;
	}

	/* A check that failed is counted and named. */
	checks_failed++;
	printf("FAIL %s\n", name);
}

/* Reads one word of the fake register window. */
static uint32_t
window_read(
	void *context,
	uint32_t offset)
{
	(void)context;

	/* Reports the word at the byte offset. */
	return window[offset / 4U];
}

/* Reports whether a run of GPU addresses lies inside one of the owner's runs. */
static int
owned(
	void *context,
	uint32_t address,
	uint32_t bytes)
{
	uint64_t end;
	unsigned index;

	(void)context;

	/* The run asked about ends where it ends, maybe at 2^32. */
	end = (uint64_t)address + bytes;

	/* Looks at each run of the owner. */
	for (index = 0U; index < OWNED_RUNS; index++) {
		/* The run starts inside this one... */
		if (address < owned_address[index])
			continue;

		/* ...and ends inside it. */
		if (end <= (uint64_t)owned_address[index] + owned_bytes[index])
			return 1;
	}

	/* No run of the owner holds it. */
	return 0;
}

/* Steps a 32-bit xorshift generator and reports its next value. */
static uint32_t
next_random(
	uint32_t *state)
{
	uint32_t value;

	/* The three shifts of the generator. */
	value = *state;
	value ^= value << 13;
	value ^= value >> 17;
	value ^= value << 5;
	*state = value;

	/* Reports the new value. */
	return value;
}

/* Checks the fence comparison, including its wrap around 2^32. */
static void
test_fences(void)
{
	/* Equal, ahead and behind. */
	expect(ghci_fence_passed(5U, 5U) == 1, "fence equal");
	expect(ghci_fence_passed(6U, 5U) == 1, "fence ahead");
	expect(ghci_fence_passed(4U, 5U) == 0, "fence behind");

	/* Across the wrap: 2 is ahead of 0xfffffffe, not behind it. */
	expect(ghci_fence_passed(2U, 0xfffffffeU) == 1, "fence ahead across the wrap");
	expect(ghci_fence_passed(0xfffffffeU, 2U) == 0, "fence behind across the wrap");

	/* Half a turn is the limit: just under is ahead, exactly half reads as behind. */
	expect(ghci_fence_passed(0x7fffffffU, 0U) == 1, "fence just under half a turn");
	expect(ghci_fence_passed(0x80000000U, 0U) == 0, "fence at half a turn");
}

/* Checks the ring's room and padding at chosen positions. */
static void
test_ring(void)
{
	uint32_t pad;
	int error;

	/* An empty ring takes a run at its start without padding. */
	pad = 99U;
	error = ghci_ring_plan(0U, 0U, 16U, 4U, &pad);
	expect(error == 0 && pad == 0U, "ring empty");

	/* An empty ring holds a run one dword short of its size, never its size. */
	error = ghci_ring_plan(0U, 0U, 16U, 15U, &pad);
	expect(error == 0 && pad == 0U, "ring largest run");
	error = ghci_ring_plan(0U, 0U, 16U, 16U, &pad);
	expect(error == EINVAL, "ring run of its size");

	/* A run that does not fit before the end is padded, and waits while the reader is close. */
	error = ghci_ring_plan(14U, 2U, 16U, 4U, &pad);
	expect(error == EAGAIN, "ring padded run waits");
	error = ghci_ring_plan(14U, 10U, 16U, 4U, &pad);
	expect(error == 0 && pad == 2U, "ring padded run");

	/* A run that ends exactly at the end is not padded. */
	error = ghci_ring_plan(12U, 0U, 16U, 4U, &pad);
	expect(error == EAGAIN, "ring run to the end waits for the reader at 0");
	error = ghci_ring_plan(12U, 1U, 16U, 4U, &pad);
	expect(error == 0 && pad == 0U, "ring run to the end");

	/* A full ring waits. */
	error = ghci_ring_plan(5U, 6U, 16U, 1U, &pad);
	expect(error == EAGAIN, "ring full");

	/* Positions outside the ring and an empty run are refused. */
	error = ghci_ring_plan(16U, 0U, 16U, 1U, &pad);
	expect(error == EINVAL, "ring writer outside");
	error = ghci_ring_plan(0U, 16U, 16U, 1U, &pad);
	expect(error == EINVAL, "ring reader outside");
	error = ghci_ring_plan(0U, 0U, 16U, 0U, &pad);
	expect(error == EINVAL, "ring empty run");
	error = ghci_ring_plan(0U, 0U, 0U, 1U, &pad);
	expect(error == EINVAL, "ring of no size");
}

/*
 * Runs a writer and a reader around a small ring many times: the writer
 * places runs of random length where the plan says, the reader consumes
 * them a random number of dwords at a time.  No run may cross the end,
 * and no dword the reader has not read may be overwritten.
 */
static void
test_ring_stress(void)
{
	uint32_t owner[64];
	uint32_t ring_dwords;
	uint32_t wptr;
	uint32_t rptr;
	uint32_t pad;
	uint32_t need;
	uint32_t step;
	uint32_t index;
	uint32_t written;
	uint32_t seed;
	unsigned round;
	int crossed;
	int overwritten;
	int error;

	/* The ring is empty and every dword is read. */
	ring_dwords = 64U;
	for (index = 0U; index < ring_dwords; index++)
		owner[index] = 0U;
	wptr = 0U;
	rptr = 0U;
	seed = 0x12345678U;
	crossed = 0;
	overwritten = 0;
	written = 0U;

	/* Many rounds of one write attempt and one read. */
	for (round = 0U; round < 200000U; round++) {
		/* A run of 1 to 20 dwords. */
		need = 1U + next_random(&seed) % 20U;
		error = ghci_ring_plan(wptr, rptr, ring_dwords, need, &pad);
		if (error == 0) {
			/* Padding dwords and the run's dwords become unread. */
			for (index = 0U; index < pad + need; index++) {
				/* A dword still unread must never be written again. */
				if (owner[(wptr + index) % ring_dwords] != 0U)
					overwritten = 1;
				owner[(wptr + index) % ring_dwords] = 1U;
			}

			/* The run after the padding stays inside the ring's end. */
			if (pad != 0U && wptr + pad != ring_dwords)
				crossed = 1;
			if (((wptr + pad) % ring_dwords) + need > ring_dwords)
				crossed = 1;

			/* The writer moves past the padding and the run. */
			wptr = (wptr + pad + need) % ring_dwords;
			written++;
		}

		/* The reader consumes up to 16 dwords that were written. */
		step = next_random(&seed) % 17U;
		while (step != 0U && rptr != wptr) {
			owner[rptr] = 0U;
			rptr = (rptr + 1U) % ring_dwords;
			step--;
		}
	}

	/* No run crossed the end, nothing unread was overwritten, and the writer made progress. */
	expect(crossed == 0, "ring stress no run crosses the end");
	expect(overwritten == 0, "ring stress no unread dword overwritten");
	expect(written > 10000U, "ring stress writes progress");
}

/* Checks the walk of the extended capability list over a fake window. */
static void
test_extcap(void)
{
	uint32_t registers;
	uint32_t version;
	uint32_t index;
	int error;

	/* Two entries: MEM (version 1) at 0x100 pointing at 0x108, DISP (version 2) the last. */
	memset(window, 0, sizeof(window));
	window[0x100U / 4U] = GHCI_XCAP_MEM | (1U << 8) | (2U << 16);
	window[0x104U / 4U] = 0x180U;
	window[0x108U / 4U] = GHCI_XCAP_DISP | (2U << 8);
	window[0x10cU / 4U] = 0x200U;

	/* Each entry is found with its registers and version. */
	error = ghci_extcap_find(window_read, NULL, 0x100U, sizeof(window), GHCI_XCAP_MEM, &registers, &version);
	expect(error == 0 && registers == 0x180U && version == 1U, "extcap first entry");
	error = ghci_extcap_find(window_read, NULL, 0x100U, sizeof(window), GHCI_XCAP_DISP, &registers, &version);
	expect(error == 0 && registers == 0x200U && version == 2U, "extcap last entry");

	/* An id that is not listed, and a list that is absent. */
	error = ghci_extcap_find(window_read, NULL, 0x100U, sizeof(window), GHCI_XCAP_PROT, &registers, &version);
	expect(error == ENOENT, "extcap id not listed");
	error = ghci_extcap_find(window_read, NULL, 0U, sizeof(window), GHCI_XCAP_MEM, &registers, &version);
	expect(error == ENOENT, "extcap no list");

	/* A misaligned start and an entry past the window are refused. */
	error = ghci_extcap_find(window_read, NULL, 0x102U, sizeof(window), GHCI_XCAP_MEM, &registers, &version);
	expect(error == EINVAL, "extcap misaligned entry");
	error = ghci_extcap_find(window_read, NULL, sizeof(window) - 4U, sizeof(window), GHCI_XCAP_MEM, &registers, &version);
	expect(error == EINVAL, "extcap entry past the window");

	/* A step that leaves the window is refused. */
	window[0x108U / 4U] = GHCI_XCAP_DISP | (0xffffU << 16);
	error = ghci_extcap_find(window_read, NULL, 0x100U, 0x200U, GHCI_XCAP_PROT, &registers, &version);
	expect(error == EINVAL, "extcap step past the window");

	/* A list longer than the bound is refused rather than walked for ever. */
	for (index = 0U; index < 40U; index++)
		window[(0x100U + 8U * index) / 4U] = GHCI_XCAP_VEND | (2U << 16);
	error = ghci_extcap_find(window_read, NULL, 0x100U, sizeof(window), GHCI_XCAP_MEM, &registers, &version);
	expect(error == EINVAL, "extcap list past the bound");
}

/* Checks the allocator at chosen requests. */
static void
test_range(void)
{
	struct ghci_range_extent extents[4];
	struct ghci_range_map map;
	uint32_t address;
	int error;

	/* A range of 64 KiB at 0x1000. */
	ghci_range_init(&map, 0x1000U, 0x11000U, extents, 4U);
	expect(ghci_range_free_bytes(&map) == 0x10000U, "range all free");

	/* First fit: the first two runs go at the start, in order. */
	error = ghci_range_alloc(&map, 0x1000U, 0x1000U, &address);
	expect(error == 0 && address == 0x1000U, "range first run");
	error = ghci_range_alloc(&map, 0x2000U, 0x1000U, &address);
	expect(error == 0 && address == 0x2000U, "range second run");

	/* A run aligned to 16 KiB skips the gap that is not aligned. */
	error = ghci_range_alloc(&map, 0x1000U, 0x4000U, &address);
	expect(error == 0 && address == 0x4000U, "range aligned run");

	/* A freed run is taken again by the next request that fits. */
	error = ghci_range_free(&map, 0x1000U);
	expect(error == 0, "range free first run");
	error = ghci_range_alloc(&map, 0x800U, 0x100U, &address);
	expect(error == 0 && address == 0x1000U, "range reuse of a freed run");

	/* Holding: inside a run, across its end, and inside a gap. */
	expect(ghci_range_holds(&map, 0x2000U, 0x2000U) == 1, "range holds a whole run");
	expect(ghci_range_holds(&map, 0x2100U, 0x100U) == 1, "range holds inside a run");
	expect(ghci_range_holds(&map, 0x3f00U, 0x200U) == 0, "range does not hold across a run's end");
	expect(ghci_range_holds(&map, 0x1800U, 0x10U) == 0, "range does not hold a gap");

	/* The table is full after four runs. */
	error = ghci_range_alloc(&map, 0x1000U, 0x1000U, &address);
	expect(error == 0, "range fourth run");
	error = ghci_range_alloc(&map, 0x1000U, 0x1000U, &address);
	expect(error == ENOSPC, "range table full");

	/* Bad requests and a free of an address that starts no run. */
	error = ghci_range_alloc(&map, 0U, 0x1000U, &address);
	expect(error == EINVAL, "range empty run");
	error = ghci_range_alloc(&map, 0x1000U, 0x3000U, &address);
	expect(error == EINVAL, "range alignment not a power of two");
	error = ghci_range_free(&map, 0x2100U);
	expect(error == ENOENT, "range free inside a run");

	/* A range that ends at 2^32 hands out its last page. */
	ghci_range_init(&map, 0xfffff000U, 0x100000000ULL, extents, 4U);
	error = ghci_range_alloc(&map, 0x1000U, 0x1000U, &address);
	expect(error == 0 && address == 0xfffff000U, "range last page of the address space");
	error = ghci_range_alloc(&map, 0x1000U, 0x1000U, &address);
	expect(error == ENOMEM, "range nothing left at the top");
	expect(ghci_range_holds(&map, 0xfffffffcU, 4U) == 1, "range holds the last word");
}

/*
 * Allocates and frees runs at random and compares every result with a
 * map of the pages in use.
 */
static void
test_range_stress(void)
{
	struct ghci_range_extent extents[STRESS_RUNS];
	struct ghci_range_map map;
	uint32_t run_address[STRESS_RUNS];
	uint32_t run_pages[STRESS_RUNS];
	unsigned char used[STRESS_PAGES];
	uint64_t free_pages;
	uint32_t address;
	uint32_t pages;
	uint32_t page;
	uint32_t seed;
	unsigned runs;
	unsigned round;
	unsigned pick;
	int overlap;
	int lost;
	int wrong_free;
	int error;

	/* An empty range of 256 pages at 1 MiB and an empty map. */
	ghci_range_init(&map, 0x100000U, 0x100000U + STRESS_PAGES * STRESS_PAGE, extents, STRESS_RUNS);
	memset(used, 0, sizeof(used));
	runs = 0U;
	seed = 0x9e3779b9U;
	overlap = 0;
	lost = 0;
	wrong_free = 0;

	/* Many rounds of one allocation or one free. */
	for (round = 0U; round < 100000U; round++) {
		/* Frees one run at random half of the time, when there is one. */
		if (runs != 0U && (next_random(&seed) & 1U) != 0U) {
			pick = next_random(&seed) % runs;
			error = ghci_range_free(&map, run_address[pick]);
			if (error != 0)
				lost = 1;

			/* Its pages are free again in the reference. */
			for (page = 0U; page < run_pages[pick]; page++)
				used[(run_address[pick] - 0x100000U) / STRESS_PAGE + page] = 0U;

			/* The last run takes its place in the list. */
			runs--;
			run_address[pick] = run_address[runs];
			run_pages[pick] = run_pages[runs];
			continue;
		}

		/* Allocates 1 to 16 pages. */
		pages = 1U + next_random(&seed) % 16U;
		error = ghci_range_alloc(&map, pages * STRESS_PAGE, STRESS_PAGE, &address);
		if (error != 0)
			continue;

		/* The run must not touch a page in use, and must stay in the range. */
		for (page = 0U; page < pages; page++) {
			/* A page past the range is an overlap with nothing, also wrong. */
			if ((address - 0x100000U) / STRESS_PAGE + page >= STRESS_PAGES) {
				overlap = 1;
				break;
			}

			/* A page already in use is an overlap. */
			if (used[(address - 0x100000U) / STRESS_PAGE + page] != 0U)
				overlap = 1;
			used[(address - 0x100000U) / STRESS_PAGE + page] = 1U;
		}

		/* Remembers the run for a later free. */
		run_address[runs] = address;
		run_pages[runs] = pages;
		runs++;

		/* The allocator's free bytes agree with the reference. */
		free_pages = 0U;
		for (page = 0U; page < STRESS_PAGES; page++) {
			if (used[page] == 0U)
				free_pages++;
		}
		if (ghci_range_free_bytes(&map) != free_pages * STRESS_PAGE)
			wrong_free = 1;
	}

	/* No overlap, no run lost and the free bytes always agreed. */
	expect(overlap == 0, "range stress no overlap");
	expect(lost == 0, "range stress every run freed");
	expect(wrong_free == 0, "range stress free bytes");
}

/* Checks the packets the driver writes. */
static void
test_packets(void)
{
	struct ghci_blit blit;
	uint32_t out[GHCI_BLIT_PACKET_DWORDS];
	uint32_t pairs[4];
	uint32_t dwords;
	int error;

	/* A fence with its interrupt: class 0, FENCE, the tag, flag 1, two dwords. */
	ghci_packet_fence(7U, 0x2000U, 42U, 1, out);
	expect(out[0] == ((5U << 24) | (7U << 16) | (1U << 8) | 2U), "packet fence header");
	expect(out[1] == 0x2000U && out[2] == 42U, "packet fence payload");

	/* A fence without its interrupt has no flag. */
	ghci_packet_fence(0U, 0x2000U, 43U, 0, out);
	expect(out[0] == ((5U << 24) | 2U), "packet fence without interrupt");

	/* A padding of four dwords: class 3, three dwords after the header, all zero. */
	out[1] = 0xffffffffU;
	out[2] = 0xffffffffU;
	out[3] = 0xffffffffU;
	ghci_packet_pad(4U, out);
	expect(out[0] == ((3U << 30) | 3U), "packet padding header");
	expect(out[1] == 0U && out[2] == 0U && out[3] == 0U, "packet padding zeroed");

	/* A padding of one dword is the header alone. */
	ghci_packet_pad(1U, out);
	expect(out[0] == (3U << 30), "packet padding of one dword");

	/* A wait for the blitter and an invalidation of the data and texture caches. */
	ghci_packet_wait_idle(3U, GHCI_STATUS_BLT_BUSY, out);
	expect(out[0] == ((6U << 24) | (3U << 16) | (2U << 8)), "packet wait idle");
	ghci_packet_invalidate(3U, 3U, out);
	expect(out[0] == ((12U << 24) | (3U << 16) | (3U << 8)), "packet invalidate");

	/* A blit: SET_REG of the eleven words in order, then BLIT. */
	memset(&blit, 0, sizeof(blit));
	blit.op = GHCI_BLT_COPY;
	blit.dst_base = 0x10000U;
	blit.dst_stride = 256U;
	blit.src_base = 0x20000U;
	blit.src_stride = 512U;
	blit.dst_x = 1U;
	blit.dst_y = 2U;
	blit.src_x = 3U;
	blit.src_y = 4U;
	blit.width = 5U;
	blit.height = 6U;
	error = ghci_packet_blit(&blit, 9U, out, GHCI_BLIT_PACKET_DWORDS, &dwords);
	expect(error == 0 && dwords == 24U, "packet blit size");
	expect(out[0] == ((1U << 24) | (9U << 16) | 22U), "packet blit SET_REG header");
	expect(out[1] == GHCI_S_BLT_OP && out[2] == GHCI_BLT_COPY, "packet blit op word");
	expect(out[11] == GHCI_S_BLT_DST_XY && out[12] == ((2U << 16) | 1U), "packet blit destination corner");
	expect(out[15] == GHCI_S_BLT_SIZE && out[16] == ((6U << 16) | 5U), "packet blit size word");
	expect(out[21] == GHCI_S_BLT_CLIP_MAX && out[22] == 0U, "packet blit no clip");
	expect(out[23] == ((2U << 24) | (9U << 16)), "packet blit BLIT");
	error = ghci_packet_blit(&blit, 9U, out, GHCI_BLIT_PACKET_DWORDS - 1U, &dwords);
	expect(error == ENOSPC, "packet blit without room");

	/* A DISP_SET of two pairs waiting for the controller's idle: op 15, flag 1, four dwords. */
	pairs[0] = 0x10U;
	pairs[1] = 0x41U;
	pairs[2] = 0x28U;
	pairs[3] = 2560U;
	error = ghci_packet_disp_set(0U, 1, pairs, 2U, out, &dwords);
	expect(error == 0 && dwords == 5U, "packet disp set size");
	expect(out[0] == ((15U << 24) | (1U << 8) | 4U), "packet disp set header");
	expect(out[1] == 0x10U && out[2] == 0x41U && out[3] == 0x28U && out[4] == 2560U, "packet disp set pairs in order");
	error = ghci_packet_disp_set(0U, 0, pairs, 0U, out, &dwords);
	expect(error == EINVAL, "packet disp set without a pair");
	error = ghci_packet_disp_set(0U, 0, pairs, GHCI_DISP_SET_PAIRS_MAX + 1U, out, &dwords);
	expect(error == EINVAL, "packet disp set past its payload count");

	/* A FLIP of the cursor's plane with COMPLETE: op 16, flag 1, four dwords. */
	ghci_packet_flip(4U, 1, 1U, 0x80001000U, 0x80000048U, 0x7fffffffU, out);
	expect(out[0] == ((16U << 24) | (4U << 16) | (1U << 8) | 4U), "packet flip header");
	expect(out[1] == 1U && out[2] == 0x80001000U && out[3] == 0x80000048U && out[4] == 0x7fffffffU, "packet flip payload");
	ghci_packet_flip(0U, 0, 0U, 0U, 0U, 1U, out);
	expect(out[0] == ((16U << 24) | 4U), "packet flip without COMPLETE");
}

/* Builds a native command stream from packets of dwords dwords in all. */
static uint32_t
native_stream(
	uint32_t *stream,
	const uint32_t *packets,
	uint32_t packet_count,
	uint32_t dwords)
{
	uint32_t index;

	/* The head: the gpu-op, no flags, the packet count. */
	stream[0] = GPU_OP_GHCI_NATIVE;
	stream[1] = 0U;
	stream[2] = packet_count;

	/* The packets after it. */
	for (index = 0U; index < dwords; index++)
		stream[GHCI_NATIVE_HEAD_DWORDS + index] = packets[index];

	/* Reports the stream's dwords. */
	return GHCI_NATIVE_HEAD_DWORDS + dwords;
}

/* Writes the packets of a 32-bit fill: a SET_REG of the five words a fill reads and a BLIT. */
static uint32_t
fill_packets(
	uint32_t *out,
	uint32_t base,
	uint32_t stride,
	uint32_t xy,
	uint32_t size)
{
	/* The SET_REG of the operation, the destination, the corner and the size. */
	out[0] = GHCI_PKT_N(0U, GHCI_OP_SET_REG, 0x55U, 0U, 10U);
	out[1] = GHCI_S_BLT_OP;
	out[2] = GHCI_BLT_FILL;
	out[3] = GHCI_S_BLT_DST_BASE;
	out[4] = base;
	out[5] = GHCI_S_BLT_DST_STRIDE;
	out[6] = stride;
	out[7] = GHCI_S_BLT_DST_XY;
	out[8] = xy;
	out[9] = GHCI_S_BLT_SIZE;
	out[10] = size;

	/* The BLIT, waited for. */
	out[11] = GHCI_PKT_N(0U, GHCI_OP_BLIT, 0x55U, GHCI_BLIT_WAIT, 0U);

	/* Reports the dwords written. */
	return 12U;
}

/* Checks the native command stream's check and copy. */
static void
test_native(void)
{
	struct ghci_native_check check;
	uint32_t packets[64];
	uint32_t stream[80];
	uint32_t out[80];
	uint32_t length;
	uint32_t dwords;
	uint32_t count;
	int error;

	/* The session owns 64 KiB at 0x100000 and one page at 0x200000. */
	owned_address[0] = 0x100000U;
	owned_bytes[0] = 0x10000U;
	owned_address[1] = 0x200000U;
	owned_bytes[1] = 0x1000U;
	check.owned = owned;
	check.context = NULL;
	check.tag = 7U;

	/* A fill of 64 x 64 pixels at a stride of 256 bytes, then a fence: every word copied, the tag the session's. */
	count = fill_packets(packets, 0x100000U, 256U, 0U, (64U << 16) | 64U);
	ghci_packet_fence(0x55U, 0x200000U, 1U, 1, &packets[count]);
	count += GHCI_FENCE_PACKET_DWORDS;
	length = native_stream(stream, packets, 3U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == 0 && dwords == count, "native fill and fence taken");
	expect(GHCI_PKT_GET_TAG(out[0]) == 7U && GHCI_PKT_GET_TAG(out[11]) == 7U, "native tag replaced");
	expect(out[4] == 0x100000U && out[13] == 0x200000U, "native payload copied");

	/* The same fill one row taller runs past the allocation. */
	count = fill_packets(packets, 0x100000U, 256U, 0U, (257U << 16) | 64U);
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native fill past the allocation");

	/* A corner that moves the fill past the allocation. */
	count = fill_packets(packets, 0x100000U, 256U, (0U << 16) | 1U, (256U << 16) | 64U);
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native fill moved past the allocation");

	/* A fill of memory the session does not own. */
	count = fill_packets(packets, 0x300000U, 256U, 0U, (1U << 16) | 1U);
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native fill of foreign memory");

	/* A BLIT whose size the stream did not set. */
	count = fill_packets(packets, 0x100000U, 256U, 0U, (1U << 16) | 1U);
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_SET_REG, 0U, 0U, 8U);
	packets[9] = packets[11];
	length = native_stream(stream, packets, 2U, 10U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native blit without its size");

	/* A copy needs its source, which must be the session's too. */
	count = fill_packets(packets, 0x100000U, 256U, 0U, (16U << 16) | 16U);
	packets[2] = GHCI_BLT_COPY;
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native copy without its source");
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_SET_REG, 0U, 0U, 16U);
	packets[11] = GHCI_S_BLT_SRC_BASE;
	packets[12] = 0x200000U;
	packets[13] = GHCI_S_BLT_SRC_STRIDE;
	packets[14] = 64U;
	packets[15] = GHCI_S_BLT_SRC_XY;
	packets[16] = 0U;
	packets[17] = GHCI_PKT_N(0U, GHCI_OP_BLIT, 0U, 0U, 0U);
	length = native_stream(stream, packets, 2U, 18U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == 0, "native copy from the session's page");
	packets[12] = 0x200c40U;
	length = native_stream(stream, packets, 2U, 18U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native copy from past the page");

	/* A tiling copy and an undefined op bit are refused. */
	count = fill_packets(packets, 0x100000U, 256U, 0U, (1U << 16) | 1U);
	packets[2] = GHCI_BLT_TILE;
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native tiling copy");
	packets[2] = GHCI_BLT_FILL | (1U << 20);
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native undefined op bit");

	/* A 16-bit fill of an odd width is taken; a base that is not a multiple of the pixel is not. */
	count = fill_packets(packets, 0x100002U, 2U, 0U, (1U << 16) | 3U);
	packets[2] = GHCI_BLT_FILL | GHCI_BLT_BPP16;
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == 0, "native 16-bit fill");
	packets[4] = 0x100001U;
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native 16-bit fill of an odd base");

	/* A register outside the blitter's range. */
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_SET_REG, 0U, 0U, 2U);
	packets[1] = GHCI_S_TOPOLOGY;
	packets[2] = 0U;
	length = native_stream(stream, packets, 1U, 3U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native register outside the blitter");

	/* A DRAW, a vendor micro-operation and a class 2 packet are refused. */
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_DRAW, 0U, 0U, 0U);
	length = native_stream(stream, packets, 1U, 1U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native draw");
	packets[0] = GHCI_PKT_N(1U, ATG_VOP_DBG_MARK, 0U, 0U, 1U);
	packets[1] = 0U;
	length = native_stream(stream, packets, 1U, 2U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native vendor micro-operation");
	packets[0] = GHCI_PKT_V(0U, 1U);
	length = native_stream(stream, packets, 1U, 2U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native class 2 packet");

	/* A fence word that is not aligned, or not the session's. */
	ghci_packet_fence(0U, 0x200002U, 1U, 0, packets);
	length = native_stream(stream, packets, 1U, 3U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native misaligned fence");
	ghci_packet_fence(0U, 0x300000U, 1U, 0, packets);
	length = native_stream(stream, packets, 1U, 3U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native foreign fence");

	/* The waits and invalidations are taken, with only their defined flags. */
	ghci_packet_wait_idle(0U, 0U, &packets[0]);
	ghci_packet_invalidate(0U, 0xfU, &packets[1]);
	packets[2] = GHCI_PKT_N(0U, GHCI_OP_NOP, 0U, 0U, 2U);
	packets[3] = 1U;
	packets[4] = 2U;
	length = native_stream(stream, packets, 3U, 5U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == 0 && dwords == 5U, "native waits, invalidation and nop");
	error = ghci_native_prepare(stream, 0U, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native empty stream");
	packets[1] = GHCI_PKT_N(0U, GHCI_OP_INVALIDATE, 0U, 0x10U, 0U);
	length = native_stream(stream, &packets[1], 1U, 1U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native undefined invalidation flag");

	/* The head: another gpu-op, flags, a count of zero, a count past the stream, a word after the last packet. */
	length = native_stream(stream, packets, 1U, 1U);
	stream[0] = GPU_OP_GHCI_FRAME;
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native another gpu-op");
	length = native_stream(stream, packets, 1U, 1U);
	stream[1] = 1U;
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native flags");
	length = native_stream(stream, packets, 0U, 1U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native no packet");
	length = native_stream(stream, packets, 2U, 1U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native count past the stream");
	length = native_stream(stream, packets, 1U, 2U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native word after the last packet");

	/* A payload that runs past the stream, and packets past the caller's room. */
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_NOP, 0U, 0U, 5U);
	length = native_stream(stream, packets, 1U, 3U);
	error = ghci_native_prepare(stream, length, &check, out, 80U, &dwords);
	expect(error == EINVAL, "native payload past the stream");
	count = fill_packets(packets, 0x100000U, 256U, 0U, (1U << 16) | 1U);
	length = native_stream(stream, packets, 2U, count);
	error = ghci_native_prepare(stream, length, &check, out, 11U, &dwords);
	expect(error == E2BIG, "native packets past the room");
}

/* Checks the capability record against the words libvulkan reads. */
static void
test_capset(void)
{
	uint8_t data[GHCI_CAPSET_BYTES];
	uint32_t word;

	/* The record over a buffer of stale bytes. */
	memset(data, 0xa5, sizeof(data));
	ghci_capset_fill(data);

	/* The wire version 1 and the XML version 1.3.269. */
	memcpy(&word, &data[0], 4U);
	expect(word == 1U, "capset wire version");
	memcpy(&word, &data[4], 4U);
	expect(word == ((1U << 22) | (3U << 12) | 269U), "capset XML version");

	/* The timelines word, the vendor suffix and its flags, the native word. */
	memcpy(&word, &data[152], 4U);
	expect(word != 0U, "capset timelines");
	memcpy(&word, &data[160], 4U);
	expect(word == 0x5a424453U, "capset vendor magic");
	memcpy(&word, &data[164], 4U);
	expect(word == 7U, "capset vendor flags");
	memcpy(&word, &data[168], 4U);
	expect(word == 0x5a4e4154U, "capset native magic");
	memcpy(&word, &data[172], 4U);
	expect(word == 0U, "capset native flags");

	/* Every other byte is zero. */
	memcpy(&word, &data[100], 4U);
	expect(word == 0U && data[8] == 0U && data[175] == 0U, "capset other bytes zero");
}

/* Checks the table of job markers. */
static void
test_jobs(void)
{
	struct ghci_job_table table;
	void *done[GHCI_JOB_MARKERS];
	int errors[GHCI_JOB_MARKERS];
	unsigned index;
	unsigned first;
	unsigned count;
	int tokens[GHCI_JOB_MARKERS + 1U];
	int failures;
	int passed;
	int error;

	/* An empty table has room for every marker. */
	ghci_jobs_init(&table);
	expect(ghci_jobs_capacity(&table) == GHCI_JOB_MARKERS, "jobs all free");

	/* Reserves every marker; one more waits. */
	failures = 0;
	for (index = 0U; index < GHCI_JOB_MARKERS; index++) {
		error = ghci_jobs_reserve(&table, &tokens[index], &first);
		if (error != 0)
			failures++;
	}
	error = failures;
	expect(error == 0 && ghci_jobs_capacity(&table) == 0U, "jobs every marker reserved");
	error = ghci_jobs_reserve(&table, &tokens[GHCI_JOB_MARKERS], &first);
	expect(error == EAGAIN, "jobs no marker left");

	/* A normal cancel frees a reservation; a commit with another completion is stale. */
	error = ghci_jobs_cancel(&table, 0U, &tokens[0], 0U);
	expect(error == 0 && ghci_jobs_capacity(&table) == 1U, "jobs cancel of a reservation");
	error = ghci_jobs_commit(&table, 1U, &tokens[2], 10U, 0U, &passed);
	expect(error == ESTALE, "jobs commit of another completion");
	error = ghci_jobs_commit(&table, 0U, &tokens[0], 10U, 0U, &passed);
	expect(error == ESTALE, "jobs commit of a freed marker");

	/* A commit to a fence that already passed frees the marker at once. */
	error = ghci_jobs_commit(&table, 1U, &tokens[1], 5U, 6U, &passed);
	expect(error == 0 && passed == 1 && ghci_jobs_capacity(&table) == 2U, "jobs commit of a passed fence");

	/* Commits to fences 10 and 20, which wait; a normal cancel of a committed marker is stale. */
	error = ghci_jobs_commit(&table, 2U, &tokens[2], 10U, 6U, &passed);
	expect(error == 0 && passed == 0, "jobs commit waits for fence 10");
	error = ghci_jobs_commit(&table, 3U, &tokens[3], 20U, 6U, &passed);
	expect(error == 0 && passed == 0, "jobs commit waits for fence 20");
	error = ghci_jobs_cancel(&table, 2U, &tokens[2], 0U);
	expect(error == ESTALE, "jobs normal cancel of a committed marker");
	expect(ghci_jobs_capacity(&table) == 2U, "jobs committed markers hold their room");

	/* Fence 15 completes the first only. */
	count = ghci_jobs_retire(&table, 15U, done, errors, GHCI_JOB_MARKERS);
	expect(count == 1U && done[0] == &tokens[2] && errors[0] == 0, "jobs retire up to fence 15");

	/* A fault cancel of a reservation and the failure of the device end both with an error. */
	error = ghci_jobs_cancel(&table, 4U, &tokens[4], 1U);
	expect(error == 0, "jobs fault cancel of a reservation");
	ghci_jobs_fail(&table);
	count = ghci_jobs_retire(&table, 15U, done, errors, GHCI_JOB_MARKERS);
	expect(count == 2U && errors[0] == EIO && errors[1] == EIO, "jobs failed markers end with an error");
	expect(ghci_jobs_capacity(&table) == 5U, "jobs room back after the failures");

	/* A retirement takes no more completions than the caller has room for. */
	error = ghci_jobs_commit(&table, 5U, &tokens[5], 30U, 15U, &passed);
	error |= ghci_jobs_commit(&table, 6U, &tokens[6], 31U, 15U, &passed);
	count = ghci_jobs_retire(&table, 40U, done, errors, 1U);
	expect(error == 0 && count == 1U, "jobs retire bounded by the room");
	count = ghci_jobs_retire(&table, 40U, done, errors, 1U);
	expect(count == 1U, "jobs retire the rest later");

	/* Tokens: a marker's address names it, any other pointer is stale. */
	error = ghci_jobs_index(&table, &table.markers[9], &index);
	expect(error == 0 && index == 9U, "jobs token of a marker");
	error = ghci_jobs_index(&table, &tokens[0], &index);
	expect(error == ESTALE, "jobs token of something else");

	/* Indices outside the table and a fault value that does not exist. */
	error = ghci_jobs_commit(&table, GHCI_JOB_MARKERS, &tokens[0], 1U, 0U, &passed);
	expect(error == ESTALE, "jobs commit outside the table");
	error = ghci_jobs_cancel(&table, 7U, &tokens[7], 2U);
	expect(error == EINVAL, "jobs cancel with an unknown fault value");
}
