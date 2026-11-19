// SPDX-License-Identifier: Zlib
/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_hw.c: bringing a GHCI GPU up and down, following ghci.md
 * Appendix A: identify the window, read BOOT_CAPS and the extended
 * capability list, reset and wait for the memory, check SCRATCH, set the
 * ring, start the command processor, write one fence and read the
 * capability block.
 *
 * The order and the waits follow the GHCI driver of zedBSD
 * (src/drivers/gpu/ghci/ghci.c, cp.c and caps.c, Zlib, same author),
 * rewritten for Linux.
 */

#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/iopoll.h>
#include <linux/iommu.h>

#include <drm/drm_print.h>

#include "ghci_drv.h"

/* The waits before the core clock is known, and their bounds (ghci.md 10). */
#define GHCI_WAIT_UNKNOWN_MS	10000u
#define GHCI_WAIT_MIN_MS	1000u
#define GHCI_WAIT_MARGIN_MS	500u
#define GHCI_QUIESCE_PERIODS	4u
#define GHCI_MEMORY_WAIT_MS	1000u
#define GHCI_FIRST_FENCE_MS	1000u

/* The capability entries a window may hold (ghci.md 4.1: 8 of them). */
#define GHCI_EXTCAP_MAX		8u

static int ghci_wait_reg(struct ghci_device *gdev, u32 reg, u32 mask,
			 u32 value, u32 timeout_ms)
{
	u32 v;

	return read_poll_timeout(ghci_read, v, (v & mask) == value, 1000,
				 (u64)timeout_ms * 1000, false, gdev, reg);
}

/*
 * A wait that covers a watchdog period (HALTING ends with the packet in
 * flight) or several (a quiesce ends within 4 x WDT_CYCLES), with a margin.
 */
static u32 ghci_period_ms(struct ghci_device *gdev, u32 periods)
{
	u32 gclk_hz = ghci_caps_word(gdev, GHCI_CAPS_WORD_GCLK_HZ);
	u64 ms;

	if (!gclk_hz)
		return GHCI_WAIT_UNKNOWN_MS;

	ms = div_u64((u64)periods * gdev->wdt_cycles * 1000, gclk_hz);
	ms += GHCI_WAIT_MARGIN_MS;

	return clamp_t(u64, ms, GHCI_WAIT_MIN_MS, U32_MAX);
}

static void ghci_set_waits(struct ghci_device *gdev)
{
	gdev->wdt_cycles = ghci_read(gdev, GHCI_REG_WDT_CYCLES);
	gdev->halt_wait_ms = ghci_period_ms(gdev, 1);
	gdev->reset_wait_ms = ghci_period_ms(gdev, GHCI_QUIESCE_PERIODS);
}

static int ghci_identify(struct ghci_device *gdev)
{
	u32 magic = ghci_read(gdev, GHCI_REG_MAGIC);

	gdev->version = ghci_read(gdev, GHCI_REG_VERSION);
	if (magic != GHCI_MAGIC_VALUE ||
	    (gdev->version >> 16) != GHCI_VERSION_MAJOR) {
		drm_err(&gdev->drm, "not GHCI 1.0 (magic %08x, version %08x)\n",
			magic, gdev->version);
		return -ENODEV;
	}

	return 0;
}

/*
 * BOOT_CAPS, the extended capability list (ghci.md 4) and the MEM
 * registers (ghci.md 11.3).  The list is walked with bounds: a broken
 * list ends the walk, it does not loop.
 */
static int ghci_read_boot_caps(struct ghci_device *gdev)
{
	u32 ptr = ghci_read(gdev, GHCI_REG_EXTCAP_PTR);
	unsigned int n;

	gdev->boot_caps = ghci_read(gdev, GHCI_REG_BOOT_CAPS);
	if (!(gdev->boot_caps & GHCI_BOOT_CAP_CP)) {
		drm_info(&gdev->drm,
			 "no command processor (BOOT_CAPS %08x); not driven\n",
			 gdev->boot_caps);
		return -ENODEV;
	}

	for (n = 0; ptr && n < GHCI_EXTCAP_MAX; n++) {
		u32 w0, regs;

		if ((ptr & 3) || ptr + 8 > GHCI_WINDOW_BYTES)
			break;

		w0 = ghci_read(gdev, ptr);

		regs = ghci_read(gdev, ptr + 4);
		if (regs < GHCI_CANONICAL_MMIO_BYTES ||
		    regs >= GHCI_WINDOW_BYTES || (regs & 3))
			regs = 0;

		switch (GHCI_XCAP_ID(w0)) {
		case GHCI_XCAP_MEM:
			gdev->mem_regs = regs;
			break;
		case GHCI_XCAP_PROT:
			gdev->prot_regs = regs;
			break;
		case GHCI_XCAP_DISP2:
			gdev->disp2_regs = regs;
			break;
		default:
			break;
		}

		if (!GHCI_XCAP_NEXT(w0))
			break;

		ptr += GHCI_XCAP_NEXT(w0) * 4;
	}

	if (gdev->mem_regs) {
		gdev->local_base = ghci_read(gdev, gdev->mem_regs +
					     GHCI_MEM_LOCAL_BASE);
		gdev->local_size = ghci_read(gdev, gdev->mem_regs +
					     GHCI_MEM_LOCAL_SIZE);
		gdev->host_limit = ghci_read(gdev, gdev->mem_regs +
					     GHCI_MEM_HOST_LIMIT);
	}

	return 0;
}

/*
 * The DMA mask: the GPU's physical address width (BOOT_CAPS PA_BITS) and,
 * when MEM gives one, HOST_LIMIT, which a 32-bit PCIe window (the KC705's
 * is 2 GiB) sets lower.  CP_HEAP and the scan-out registers hold 32 bits,
 * so the coherent mask stays at 32 bits at most.
 */
static int ghci_set_dma_mask(struct ghci_device *gdev)
{
	unsigned int bits = 40 + GHCI_BOOT_CAP_PA_BITS(gdev->boot_caps);
	int ret;

	if (gdev->host_limit)
		bits = min_t(unsigned int, bits, fls64(gdev->host_limit - 1));

	gdev->dma_bits = bits;

	ret = dma_set_mask(&gdev->pdev->dev, DMA_BIT_MASK(bits));
	if (ret)
		return ret;

	ret = dma_set_coherent_mask(&gdev->pdev->dev,
				    DMA_BIT_MASK(min(bits, 32u)));
	if (ret)
		return ret;

	/* One buffer object is one run of bus addresses where the system
	 * IOMMU can make it so. */
	dma_set_max_seg_size(&gdev->pdev->dev, UINT_MAX);

	return 0;
}

static int ghci_reset(struct ghci_device *gdev)
{
	u32 status;
	int ret;

	ghci_write(gdev, GHCI_REG_CTRL, GHCI_CTRL_RESET);
	ret = ghci_wait_reg(gdev, GHCI_REG_CTRL, GHCI_CTRL_RESET, 0,
			    gdev->reset_wait_ms);
	status = ghci_read(gdev, GHCI_REG_STATUS);
	if (ret || (status & GHCI_STATUS_AXI_STUCK)) {
		drm_err(&gdev->drm, "reset did not end (status %08x)\n",
			status);
		return -EIO;
	}

	ret = ghci_wait_reg(gdev, GHCI_REG_STATUS, GHCI_STATUS_MEM_READY,
			    GHCI_STATUS_MEM_READY, GHCI_MEMORY_WAIT_MS);
	if (ret) {
		drm_err(&gdev->drm, "memory not ready (status %08x)\n",
			ghci_read(gdev, GHCI_REG_STATUS));
		return -EIO;
	}

	return 0;
}

static int ghci_check_scratch(struct ghci_device *gdev)
{
	u32 first, second;

	ghci_write(gdev, GHCI_REG_SCRATCH, GHCI_SCRATCH_FIRST);
	first = ghci_read(gdev, GHCI_REG_SCRATCH);
	ghci_write(gdev, GHCI_REG_SCRATCH, GHCI_SCRATCH_SECOND);
	second = ghci_read(gdev, GHCI_REG_SCRATCH);
	if (first != GHCI_SCRATCH_FIRST || second != GHCI_SCRATCH_SECOND) {
		drm_err(&gdev->drm, "SCRATCH reads %08x and %08x\n", first,
			second);
		return -EIO;
	}

	return 0;
}

/*
 * The ring, the fence page, the capability buffer and CP_HEAP.  They are
 * not device-managed: a GPU that does not stop may still write them, and
 * then they are kept rather than freed (ghci_free_memory()).
 */
static void ghci_free_memory(struct ghci_device *gdev)
{
	struct device *dev = &gdev->pdev->dev;

	if (gdev->cp_heap) {
		dma_free_coherent(dev, GHCI_CP_HEAP_BYTES, gdev->cp_heap,
				  gdev->cp_heap_dma);
	}

	if (gdev->caps_buf) {
		dma_free_coherent(dev, GHCI_CAPS_TOTAL_BYTES, gdev->caps_buf,
				  gdev->caps_dma);
	}

	if (gdev->fence) {
		dma_free_coherent(dev, PAGE_SIZE, gdev->fence, gdev->fence_dma);
	}

	if (gdev->ring) {
		dma_free_coherent(dev, gdev->ring_bytes, gdev->ring,
				  gdev->ring_dma);
	}

	gdev->cp_heap = NULL;
	gdev->caps_buf = NULL;
	gdev->fence = NULL;
	gdev->ring = NULL;
}

static int ghci_alloc_memory(struct ghci_device *gdev)
{
	struct device *dev = &gdev->pdev->dev;

	gdev->ring = dma_alloc_coherent(dev, gdev->ring_bytes, &gdev->ring_dma,
					GFP_KERNEL);

	gdev->fence = dma_alloc_coherent(dev, PAGE_SIZE, &gdev->fence_dma,
					 GFP_KERNEL);

	gdev->caps_buf = dma_alloc_coherent(dev, GHCI_CAPS_TOTAL_BYTES,
					    &gdev->caps_dma, GFP_KERNEL);

	if (ghci_has_walker(gdev)) {
		gdev->cp_heap = dma_alloc_coherent(dev, GHCI_CP_HEAP_BYTES,
						   &gdev->cp_heap_dma,
						   GFP_KERNEL);
	}

	if (!gdev->ring || !gdev->fence || !gdev->caps_buf ||
	    (ghci_has_walker(gdev) && !gdev->cp_heap)) {
		ghci_free_memory(gdev);
		return -ENOMEM;
	}

	return 0;
}

static void ghci_irq_enable(struct ghci_device *gdev)
{
	gdev->irq_mask = GHCI_IRQ_FENCE | GHCI_IRQ_FAULT | GHCI_IRQ_WATCHDOG;
	ghci_write(gdev, GHCI_REG_IRQ_STATUS, ~0u);
	ghci_write(gdev, GHCI_REG_IRQ_ENABLE, gdev->polled ? 0 : gdev->irq_mask);
}

/*
 * Sets the ring and CP_HEAP while the CP is idle, then runs it
 * (Appendix A steps 4 to 6).
 */
static void ghci_cp_run(struct ghci_device *gdev)
{
	u32 ctrl = GHCI_CTRL_RUN | GHCI_CTRL_WDT_EN;

	gdev->ring_dwords = gdev->ring_bytes / 4;
	gdev->wptr = 0;
	gdev->fence_emitted = 0;
	WRITE_ONCE(*gdev->fence, cpu_to_le64(0));

	ghci_write(gdev, GHCI_REG_RING_BASE_LO, lower_32_bits(gdev->ring_dma));
	ghci_write(gdev, GHCI_REG_RING_BASE_HI, upper_32_bits(gdev->ring_dma));
	ghci_write(gdev, GHCI_REG_RING_SIZE, gdev->ring_bytes);
	ghci_write(gdev, GHCI_REG_RING_WPTR, 0);

	if (gdev->cp_heap) {
		ghci_write(gdev, GHCI_REG_CP_HEAP_BASE,
			   lower_32_bits(gdev->cp_heap_dma));
		ghci_write(gdev, GHCI_REG_CP_HEAP_LIMIT,
			   lower_32_bits(gdev->cp_heap_dma +
					 GHCI_CP_HEAP_BYTES));
	}

	ghci_irq_enable(gdev);
	if (!gdev->polled)
		ctrl |= GHCI_CTRL_IRQ_GLOBAL;

	/* The GPU makes no memory access before Bus Master Enable
	 * (ghci.md 15.2). */
	pci_set_master(gdev->pdev);
	wmb();
	ghci_write(gdev, GHCI_REG_CTRL, ctrl);
	gdev->running = true;
}

static void ghci_log_fault(struct ghci_device *gdev, const char *what)
{
	drm_err(&gdev->drm,
		"%s: STATUS %08x CTRL %08x FAULT_INFO %08x FAULT_ADDR %08x%08x RPTR %u WPTR %u CP_PC %08x CP_STATUS %08x\n",
		what, ghci_read(gdev, GHCI_REG_STATUS),
		ghci_read(gdev, GHCI_REG_CTRL),
		ghci_read(gdev, GHCI_REG_FAULT_INFO),
		ghci_read(gdev, GHCI_REG_FAULT_ADDR_HI),
		ghci_read(gdev, GHCI_REG_FAULT_ADDR_LO),
		ghci_read(gdev, GHCI_REG_RING_RPTR), gdev->wptr,
		ghci_read(gdev, GHCI_REG_DIAG_CP_PC),
		ghci_read(gdev, GHCI_REG_DIAG_CP_STATUS));
}

/*
 * Stops the CP: halt, then reset, so that it makes no more memory
 * accesses.  Returns false when the GPU did not stop: the caller must then
 * keep the memory the GPU may still write.
 */
static bool ghci_cp_stop(struct ghci_device *gdev)
{
	bool stopped = true;

	if (!gdev->running)
		return true;

	ghci_write(gdev, GHCI_REG_IRQ_ENABLE, 0);
	ghci_write(gdev, GHCI_REG_CTRL, GHCI_CTRL_HALT);
	if (ghci_wait_reg(gdev, GHCI_REG_STATUS, GHCI_STATUS_HALTED,
			  GHCI_STATUS_HALTED, gdev->halt_wait_ms))
		drm_warn(&gdev->drm, "the CP did not halt; resetting it\n");

	if (ghci_reset(gdev))
		stopped = false;

	ghci_write(gdev, GHCI_REG_CTRL, 0);
	pci_clear_master(gdev->pdev);
	gdev->running = false;

	return stopped;
}

/*
 * The protection the hardware gives (enum drm_ghci_protection): the GPU
 * MMU, the PROT unit, the system IOMMU, or nothing.
 */
u32 ghci_protection(const struct ghci_device *gdev)
{
	if (ghci_has_walker(gdev))
		return DRM_GHCI_PROTECTION_MMU;

	if (gdev->boot_caps & GHCI_BOOT_CAP_PROT)
		return DRM_GHCI_PROTECTION_PROT;

	if (device_iommu_mapped(&gdev->pdev->dev))
		return DRM_GHCI_PROTECTION_IOMMU;

	return DRM_GHCI_PROTECTION_NONE;
}

irqreturn_t ghci_irq_handler(int irq, void *arg)
{
	struct ghci_device *gdev = arg;
	u32 status = ghci_read(gdev, GHCI_REG_IRQ_STATUS) & gdev->irq_mask;

	if (!status)
		return IRQ_NONE;

	ghci_write(gdev, GHCI_REG_IRQ_STATUS, status);

	if (status & GHCI_IRQ_FENCE)
		wake_up_all(&gdev->fence_wq);

	if (status & (GHCI_IRQ_FAULT | GHCI_IRQ_WATCHDOG)) {
		drm_err_ratelimited(&gdev->drm,
				    "fault: IRQ_STATUS %08x FAULT_INFO %08x\n",
				    status,
				    ghci_read(gdev, GHCI_REG_FAULT_INFO));
		wake_up_all(&gdev->fence_wq);
	}

	return IRQ_HANDLED;
}

static void ghci_log_caps(struct ghci_device *gdev)
{
	u32 dc = ghci_caps_word(gdev, GHCI_CAPS_WORD_DEVICE_CAPS);
	u32 feat = ghci_caps_word(gdev, GHCI_CAPS_WORD_EXT_CAP_FEATURE);
	static const char * const prot[] = {
		[DRM_GHCI_PROTECTION_NONE] = "none",
		[DRM_GHCI_PROTECTION_IOMMU] = "system IOMMU",
		[DRM_GHCI_PROTECTION_PROT] = "PROT",
		[DRM_GHCI_PROTECTION_MMU] = "GPU MMU",
	};

	drm_info(&gdev->drm,
		 "GHCI %u.%u, %04x:%04x, %u SU x %u lanes, %u MHz, %s, %s, DMA %u bits, protection: %s\n",
		 gdev->version >> 16, gdev->version & 0xffff,
		 ghci_caps_word(gdev, GHCI_CAPS_WORD_VENDOR_ID) & 0xffff,
		 ghci_caps_word(gdev, GHCI_CAPS_WORD_DEVICE_ID) & 0xffff,
		 GHCI_DEV_CAP_NUM_SU(dc), GHCI_DEV_CAP_PHYS_LANES(dc),
		 ghci_caps_word(gdev, GHCI_CAPS_WORD_GCLK_HZ) / 1000000,
		 ghci_has_walker(gdev) ? "GPU MMU" : "flat addresses",
		 gdev->polled ? "polled" : "interrupt", gdev->dma_bits,
		 prot[ghci_protection(gdev)]);

	drm_dbg_driver(&gdev->drm, "DEVICE_CAPS %08x EXT_CAP_FEATURE %08x\n",
		       dc, feat);

	if (ghci_protection(gdev) == DRM_GHCI_PROTECTION_NONE) {
		drm_warn(&gdev->drm,
			 "neither a GPU MMU nor a system IOMMU: a client of the GPU can reach all host memory below %#llx\n",
			 gdev->host_limit ? gdev->host_limit : DMA_BIT_MASK(gdev->dma_bits));
	}
}

int ghci_hw_init(struct ghci_device *gdev)
{
	int ret;

	init_waitqueue_head(&gdev->fence_wq);
	ret = devm_mutex_init(gdev->drm.dev, &gdev->ring_lock);
	if (ret)
		return ret;

	ret = ghci_identify(gdev);
	if (ret)
		return ret;

	ret = ghci_read_boot_caps(gdev);
	if (ret)
		return ret;

	ret = ghci_set_dma_mask(gdev);
	if (ret)
		return ret;

	/* The clock is not known before the capability block: the waits
	 * take their long defaults. */
	ghci_set_waits(gdev);
	ret = ghci_reset(gdev);
	if (ret)
		return ret;

	ret = ghci_check_scratch(gdev);
	if (ret)
		return ret;

	ret = ghci_alloc_memory(gdev);
	if (ret)
		return ret;

	ghci_cp_run(gdev);

	/* One fence must be written before anything else is trusted. */
	ret = ghci_fence_wait(gdev, ghci_ring_emit_fence(gdev),
			      GHCI_FIRST_FENCE_MS);
	if (ret) {
		ghci_log_fault(gdev, "first fence not written");
		goto fail;
	}

	ret = ghci_ring_query_caps(gdev);
	if (ret) {
		ghci_log_fault(gdev, "capability block not written");
		goto fail;
	}
	if (gdev->caps[GHCI_CAPS_WORD_BLOCK_ID] != GHCI_CAPS_MAGIC) {
		drm_err(&gdev->drm,
			"capability block not readable (id %08x, info %08x)\n",
			gdev->caps[GHCI_CAPS_WORD_BLOCK_ID],
			gdev->caps[GHCI_CAPS_WORD_BLOCK_INFO]);
		ret = -EIO;
		goto fail;
	}
	gdev->caps_blob.data = gdev->caps;
	gdev->caps_blob.size = sizeof(gdev->caps);

	/* The clock is known now. */
	ghci_set_waits(gdev);
	ghci_log_caps(gdev);

	return 0;

fail:
	ghci_hw_fini(gdev);
	return ret;
}

void ghci_hw_fini(struct ghci_device *gdev)
{
	if (ghci_cp_stop(gdev)) {
		ghci_free_memory(gdev);
	} else {
		/* The GPU may still write the ring and the fence page: they
		 * stay allocated for the life of the system. */
		drm_err(&gdev->drm, "the GPU did not stop; its memory is kept\n");
	}
}
