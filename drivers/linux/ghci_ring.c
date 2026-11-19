// SPDX-License-Identifier: Zlib
/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_ring.c: the command ring (ghci.md 6) and its fences (ghci.md 9.1).
 *
 * The kernel alone writes the ring.  RING_WPTR is the doorbell; both
 * indices count dwords and one slot stays empty.  A packet never crosses
 * the end of the ring: the rest of the ring is filled with one-dword NOPs
 * first.  A fence is a CMD_FENCE that writes the next 64-bit sequence to
 * the fence page; sequences compare as signed 64-bit differences.
 *
 * When the function has no interrupt (the KC705's PCIe IP has neither MSI
 * nor INTx), waits poll the fence page.
 */

#include <linux/delay.h>
#include <linux/jiffies.h>

#include <drm/drm_print.h>

#include "ghci_drv.h"

/* How long a writer waits for the CP to free room in the ring. */
#define GHCI_RING_ROOM_MS	2000u

static u32 ghci_ring_room(struct ghci_device *gdev)
{
	u32 rptr = ghci_read(gdev, GHCI_REG_RING_RPTR);
	u32 n = gdev->ring_dwords;

	if (rptr >= n)
		return 0;	/* not a valid pointer: no room */
	return (rptr + n - gdev->wptr - 1) % n;
}

static int ghci_ring_wait_room(struct ghci_device *gdev, u32 need)
{
	unsigned long end = jiffies + msecs_to_jiffies(GHCI_RING_ROOM_MS);

	while (ghci_ring_room(gdev) < need) {
		if (time_after(jiffies, end))
			return -ETIMEDOUT;
		/* The doorbell lets the CP see what is already written. */
		ghci_write(gdev, GHCI_REG_RING_WPTR, gdev->wptr);
		usleep_range(100, 500);
	}
	return 0;
}

/* Fills the ring to its end with one-dword NOPs (ghci.md 6.2). */
static int ghci_ring_pad(struct ghci_device *gdev)
{
	u32 left = gdev->ring_dwords - gdev->wptr;
	int ret = ghci_ring_wait_room(gdev, left);

	if (ret)
		return ret;
	while (gdev->wptr < gdev->ring_dwords)
		gdev->ring[gdev->wptr++] =
			cpu_to_le32(GHCI_MAKE_HEADER(GHCI_CMD_NOP, 1, 0));
	gdev->wptr = 0;
	return 0;
}

/*
 * Writes whole packets to the ring and rings the doorbell.  The packets
 * come from the kernel; their lengths are checked all the same, so that a
 * bad one can not leave the ring out of step with the CP.
 */
static int ghci_ring_emit_locked(struct ghci_device *gdev, const u32 *packets,
				 u32 dwords)
{
	u32 i = 0;
	int ret;

	lockdep_assert_held(&gdev->ring_lock);
	if (!gdev->running)
		return -ENODEV;

	while (i < dwords) {
		u32 len = GHCI_HEADER_DWORDS(packets[i]);

		if (!len || len > dwords - i || len >= gdev->ring_dwords)
			return -EINVAL;
		if (gdev->ring_dwords - gdev->wptr < len) {
			ret = ghci_ring_pad(gdev);
			if (ret)
				return ret;
		}
		ret = ghci_ring_wait_room(gdev, len);
		if (ret)
			return ret;
		while (len--)
			gdev->ring[gdev->wptr++] = cpu_to_le32(packets[i++]);
		if (gdev->wptr == gdev->ring_dwords)
			gdev->wptr = 0;
	}

	/* The packets reach memory before the doorbell (ghci.md 6.3). */
	wmb();
	ghci_write(gdev, GHCI_REG_RING_WPTR, gdev->wptr);
	return 0;
}

int ghci_ring_emit(struct ghci_device *gdev, const u32 *packets, u32 dwords)
{
	int ret;

	mutex_lock(&gdev->ring_lock);
	ret = ghci_ring_emit_locked(gdev, packets, dwords);
	mutex_unlock(&gdev->ring_lock);
	return ret;
}

static void ghci_fence_packet(struct ghci_device *gdev, u32 *p, u64 seq)
{
	u32 flags = GHCI_FENCE_FLAG_MEM_WRITE | GHCI_FENCE_FLAG_HOST_FLUSH;

	if (!gdev->polled)
		flags |= GHCI_FENCE_FLAG_IRQ;
	p[0] = GHCI_MAKE_HEADER(GHCI_CMD_FENCE, 6, 0);
	p[1] = lower_32_bits(gdev->fence_dma);
	p[2] = upper_32_bits(gdev->fence_dma);
	p[3] = lower_32_bits(seq);
	p[4] = upper_32_bits(seq);
	p[5] = flags;
}

/*
 * Writes a fence of the next sequence after everything already in the
 * ring.  Returns the sequence, or 0 when the ring could not take it.
 */
u64 ghci_ring_emit_fence(struct ghci_device *gdev)
{
	u32 p[6];
	u64 seq;

	mutex_lock(&gdev->ring_lock);
	seq = gdev->fence_emitted + 1;
	ghci_fence_packet(gdev, p, seq);
	if (ghci_ring_emit_locked(gdev, p, ARRAY_SIZE(p)))
		seq = 0;
	else
		gdev->fence_emitted = seq;
	mutex_unlock(&gdev->ring_lock);
	return seq;
}

u64 ghci_fence_read(struct ghci_device *gdev)
{
	__le64 v = READ_ONCE(*gdev->fence);

	/* What the GPU wrote before the fence is visible after it. */
	dma_rmb();
	return le64_to_cpu(v);
}

static bool ghci_fence_passed(struct ghci_device *gdev, u64 seq)
{
	return (s64)(ghci_fence_read(gdev) - seq) >= 0;
}

int ghci_fence_wait(struct ghci_device *gdev, u64 seq, unsigned int timeout_ms)
{
	unsigned long end;

	if (!seq)
		return -EIO;

	if (!gdev->polled) {
		long left = wait_event_timeout(gdev->fence_wq,
					       ghci_fence_passed(gdev, seq),
					       msecs_to_jiffies(timeout_ms));
		return left ? 0 : -ETIMEDOUT;
	}

	end = jiffies + msecs_to_jiffies(timeout_ms);
	while (!ghci_fence_passed(gdev, seq)) {
		if (time_after(jiffies, end))
			return ghci_fence_passed(gdev, seq) ? 0 : -ETIMEDOUT;
		usleep_range(200, 1000);
	}
	return 0;
}

/*
 * Has the CP write its capability block (CMD_QUERY_CAPS, ghci.md 7.3) and
 * keeps a copy.
 */
int ghci_ring_query_caps(struct ghci_device *gdev)
{
	u32 p[5 + 6];
	unsigned int i;
	u64 seq;
	int ret;

	memset(gdev->caps_buf, 0, GHCI_CAPS_TOTAL_BYTES);

	p[0] = GHCI_MAKE_HEADER(GHCI_CMD_QUERY_CAPS, 5, 0);
	p[1] = lower_32_bits(gdev->caps_dma);
	p[2] = upper_32_bits(gdev->caps_dma);
	p[3] = GHCI_CAPS_TOTAL_BYTES;
	p[4] = 0;

	mutex_lock(&gdev->ring_lock);
	seq = gdev->fence_emitted + 1;
	ghci_fence_packet(gdev, &p[5], seq);
	ret = ghci_ring_emit_locked(gdev, p, ARRAY_SIZE(p));
	if (!ret)
		gdev->fence_emitted = seq;
	mutex_unlock(&gdev->ring_lock);
	if (ret)
		return ret;

	ret = ghci_fence_wait(gdev, seq, 1000);
	if (ret)
		return ret;

	for (i = 0; i < GHCI_CAPS_TOTAL_DWORDS; i++)
		gdev->caps[i] = le32_to_cpu(((__le32 *)gdev->caps_buf)[i]);
	return 0;
}
