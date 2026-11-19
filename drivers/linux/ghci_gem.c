// SPDX-License-Identifier: Zlib
/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_gem.c: buffer objects.  Every object is host memory from the GEM
 * shmem helper; the GPU reaches it by DMA (ghci.md 11.1).  In the flat
 * model (no GPU MMU) the GPU address of an object is its bus address, so
 * the object must be one run of bus addresses: the system IOMMU makes the
 * scattered pages one run of IOVA.  Without an IOMMU only an object whose
 * pages happen to be contiguous gets an address; contiguous allocation
 * (CMA) for such hosts is not written yet.
 *
 * The CPU maps objects cached: the PCIe hosts the driver is for snoop the
 * CPU caches (ghci.md 11.4).
 */

#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>

#include <drm/drm_print.h>

#include "ghci_drv.h"

static void ghci_bo_free(struct drm_gem_object *obj)
{
	struct ghci_bo *bo = to_ghci_bo(obj);

	mutex_destroy(&bo->lock);
	/* Frees the object too: the shmem object is the first member. */
	drm_gem_shmem_free(&bo->base);
}

static const struct drm_gem_object_funcs ghci_gem_funcs = {
	.free = ghci_bo_free,
	.print_info = drm_gem_shmem_object_print_info,
	.pin = drm_gem_shmem_object_pin,
	.unpin = drm_gem_shmem_object_unpin,
	.get_sg_table = drm_gem_shmem_object_get_sg_table,
	.vmap = drm_gem_shmem_object_vmap,
	.vunmap = drm_gem_shmem_object_vunmap,
	.mmap = drm_gem_shmem_object_mmap,
	.vm_ops = &drm_gem_shmem_vm_ops,
};

struct drm_gem_object *ghci_gem_create_object(struct drm_device *drm,
					      size_t size)
{
	struct ghci_bo *bo;

	BUILD_BUG_ON(offsetof(struct ghci_bo, base) != 0);

	bo = kzalloc(sizeof(*bo), GFP_KERNEL);
	if (!bo)
		return ERR_PTR(-ENOMEM);
	mutex_init(&bo->lock);
	bo->base.base.funcs = &ghci_gem_funcs;
	bo->base.map_wc = false;
	return &bo->base.base;
}

struct ghci_bo *ghci_bo_create(struct ghci_device *gdev, size_t size,
			       u32 flags)
{
	struct drm_gem_shmem_object *shmem;
	struct ghci_bo *bo;

	shmem = drm_gem_shmem_create(&gdev->drm, size);
	if (IS_ERR(shmem))
		return ERR_CAST(shmem);
	bo = to_ghci_bo(&shmem->base);
	bo->flags = flags;
	return bo;
}

/*
 * The bus address of byte 0 of a flat-model object, mapping and pinning
 * its pages the first time.  The pages stay mapped until the object is
 * freed, so the address stays valid for every job that lists the object.
 */
int ghci_bo_gpu_addr(struct ghci_device *gdev, struct ghci_bo *bo, u64 *addr)
{
	struct drm_gem_object *obj = &bo->base.base;
	struct scatterlist *sg;
	struct sg_table *sgt;
	dma_addr_t start = 0;
	u64 run = 0;
	unsigned int i;
	int ret = 0;

	if (ghci_has_walker(gdev))
		return -EOPNOTSUPP;

	mutex_lock(&bo->lock);
	if (bo->gpu_mapped) {
		*addr = bo->gpu_addr;
		goto out;
	}

	sgt = drm_gem_shmem_get_pages_sgt(&bo->base);
	if (IS_ERR(sgt)) {
		ret = PTR_ERR(sgt);
		goto out;
	}

	for_each_sgtable_dma_sg(sgt, sg, i) {
		if (i == 0)
			start = sg_dma_address(sg);
		else if (sg_dma_address(sg) != start + run)
			break;
		run += sg_dma_len(sg);
	}
	if (run < obj->size) {
		drm_dbg_driver(&gdev->drm,
			       "object of %zu bytes is not one run of bus addresses\n",
			       obj->size);
		ret = -ENOSPC;
		goto out;
	}

	bo->gpu_addr = start;
	bo->gpu_mapped = true;
	*addr = start;
out:
	mutex_unlock(&bo->lock);
	return ret;
}
