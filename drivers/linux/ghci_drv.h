/* SPDX-License-Identifier: Zlib */
/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_drv.h: the Linux DRM driver for GHCI 1.0 GPUs (ghci.md).  The
 * driver owns the one command ring (ghci.md 6) and gives user space buffer
 * objects, VMs and job submission through include/uapi/drm/ghci_drm.h.
 */

#ifndef GHCI_DRV_H
#define GHCI_DRV_H

#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/wait.h>
#include <linux/xarray.h>

#include <drm/drm_device.h>
#include <drm/drm_file.h>
#include <drm/drm_gem_shmem_helper.h>

#include "ghci_cmd.h"
#include "ghci_regs.h"

#include "include/uapi/drm/ghci_drm.h"

#define GHCI_DRIVER_DESC	"GHCI 1.0 GPU"
#define GHCI_DRIVER_DATE	"20261120"
#define GHCI_DRIVER_MAJOR	1
#define GHCI_DRIVER_MINOR	0

/* The register window GHCI 1.0 uses: page 0 and the capability list. */
#define GHCI_WINDOW_BYTES	0x400u

/* The ring: a power of two between 4 KiB and 16 MiB (ghci.md 6.1). */
#define GHCI_RING_BYTES_MIN	(4u << 10)
#define GHCI_RING_BYTES_MAX	(16u << 20)
#define GHCI_RING_BYTES		(256u << 10)

/* The two SCRATCH patterns of the liveness check (ghci.md 14). */
#define GHCI_SCRATCH_FIRST	0x5a5a5a5au
#define GHCI_SCRATCH_SECOND	0xa5a5a5a5u

/* Word 0 of the capability block, "GCAP" (ghci.md 3.2.5). */
#define GHCI_CAPS_MAGIC		0x50414347u

/* The page table heap of a GPU with a walker (ghci.md 11.2). */
#define GHCI_CP_HEAP_BYTES	(4u << 20)

/* The command chunks of one job, and the dwords of one chunk. */
#define GHCI_MAX_CHUNKS		64u
#define GHCI_MAX_CHUNK_DWORDS	(1u << 20)

struct ghci_device {
	struct drm_device drm;
	struct pci_dev *pdev;
	void __iomem *mmio;

	/* From the register window, before the ring runs. */
	u32 version;
	u32 boot_caps;
	u32 mem_regs;		/* offset of the MEM capability, 0 if none */
	u32 prot_regs;		/* offset of the PROT capability, 0 if none */
	u32 disp2_regs;		/* offset of the DISP2 capability, 0 if none */
	u64 local_base;
	u64 local_size;
	u64 host_limit;
	unsigned int dma_bits;

	/* The capability block CMD_QUERY_CAPS wrote (ghci.md 3.2.5). */
	u32 caps[GHCI_CAPS_TOTAL_DWORDS];
	struct debugfs_blob_wrapper caps_blob;

	/* The waits the watchdog period sets (ghci.md 10). */
	u32 wdt_cycles;
	u32 halt_wait_ms;
	u32 reset_wait_ms;

	/* The ring, which only the kernel writes (ghci.md 6). */
	struct mutex ring_lock;
	__le32 *ring;
	dma_addr_t ring_dma;
	u32 ring_bytes;
	u32 ring_dwords;
	u32 wptr;

	/* The fence page: the 64-bit sequence CMD_FENCE writes (ghci.md 9.1). */
	__le64 *fence;
	dma_addr_t fence_dma;
	u64 fence_emitted;
	wait_queue_head_t fence_wq;

	/* The buffer CMD_QUERY_CAPS writes. */
	void *caps_buf;
	dma_addr_t caps_dma;

	/* CP_HEAP, only on a GPU with a walker. */
	void *cp_heap;
	dma_addr_t cp_heap_dma;

	/* Interrupt, or polling when the function has none. */
	bool polled;
	int irq;
	u32 irq_mask;

	bool running;
};

static inline struct ghci_device *to_ghci(struct drm_device *drm)
{
	return container_of(drm, struct ghci_device, drm);
}

/* What one open DRM file owns. */
struct ghci_file {
	struct ghci_device *gdev;
	struct xarray vms;
};

struct ghci_vm {
	u32 id;
	u32 state;		/* enum drm_ghci_vm_state */
};

struct ghci_bo {
	struct drm_gem_shmem_object base;
	u32 flags;		/* DRM_GHCI_BO_* */
	/* Flat: the bus address of byte 0, once mapped. */
	bool gpu_mapped;
	u64 gpu_addr;
	struct mutex lock;
};

static inline struct ghci_bo *to_ghci_bo(struct drm_gem_object *obj)
{
	return container_of(to_drm_gem_shmem_obj(obj), struct ghci_bo, base);
}

static inline u32 ghci_read(struct ghci_device *gdev, u32 reg)
{
	return readl(gdev->mmio + reg);
}

static inline void ghci_write(struct ghci_device *gdev, u32 reg, u32 value)
{
	writel(value, gdev->mmio + reg);
}

static inline bool ghci_has_walker(const struct ghci_device *gdev)
{
	return gdev->boot_caps & GHCI_BOOT_CAP_HW_WALKER;
}

static inline u32 ghci_caps_word(const struct ghci_device *gdev, unsigned int w)
{
	return w < GHCI_CAPS_TOTAL_DWORDS ? gdev->caps[w] : 0;
}

/* ghci_hw.c */
int ghci_hw_init(struct ghci_device *gdev);
void ghci_hw_fini(struct ghci_device *gdev);
irqreturn_t ghci_irq_handler(int irq, void *arg);
u32 ghci_protection(const struct ghci_device *gdev);

/* ghci_ring.c */
int ghci_ring_emit(struct ghci_device *gdev, const u32 *packets, u32 dwords);
u64 ghci_ring_emit_fence(struct ghci_device *gdev);
int ghci_fence_wait(struct ghci_device *gdev, u64 seq, unsigned int timeout_ms);
u64 ghci_fence_read(struct ghci_device *gdev);
int ghci_ring_query_caps(struct ghci_device *gdev);

/* ghci_gem.c */
struct drm_gem_object *ghci_gem_create_object(struct drm_device *drm,
					      size_t size);
struct ghci_bo *ghci_bo_create(struct ghci_device *gdev, size_t size,
			       u32 flags);
int ghci_bo_gpu_addr(struct ghci_device *gdev, struct ghci_bo *bo, u64 *addr);

/* ghci_ioctl.c */
#define GHCI_NUM_IOCTLS		(DRM_GHCI_BO_WAIT + 1)
extern const struct drm_ioctl_desc ghci_ioctls[GHCI_NUM_IOCTLS];
int ghci_file_open(struct drm_device *drm, struct drm_file *file);
void ghci_file_close(struct drm_device *drm, struct drm_file *file);

#endif /* GHCI_DRV_H */
