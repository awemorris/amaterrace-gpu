// SPDX-License-Identifier: Zlib
/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 */

/*
 * ghci_ioctl.c: the ioctls of include/uapi/drm/ghci_drm.h.  Job submission
 * and the binding of GPU virtual addresses come with the scheduler; until
 * then DRM_IOCTL_GHCI_SUBMIT and DRM_IOCTL_GHCI_VM_BIND fail with
 * EOPNOTSUPP.
 */

#include <linux/dma-resv.h>
#include <linux/ktime.h>
#include <linux/sched.h>
#include <linux/uaccess.h>

#include <drm/drm_drv.h>
#include <drm/drm_gem.h>
#include <drm/drm_ioctl.h>
#include <drm/drm_print.h>
#include <drm/drm_utils.h>

#include "ghci_drv.h"

/* The most VMs one file may hold. */
#define GHCI_VMS_PER_FILE	64u

static int ghci_ioctl_dev_query(struct drm_device *drm, void *data,
				struct drm_file *file)
{
	struct ghci_device *gdev = to_ghci(drm);
	struct drm_ghci_dev_query *q = data;
	struct drm_ghci_dev_info info;
	const void *src;
	u32 size;

	switch (q->type) {
	case DRM_GHCI_DEV_QUERY_INFO:
		info = (struct drm_ghci_dev_info) {
			.ghci_version = gdev->version,
			.boot_caps = gdev->boot_caps,
			.device_caps = ghci_caps_word(gdev,
						      GHCI_CAPS_WORD_DEVICE_CAPS),
			.ext_cap_feature =
				ghci_caps_word(gdev,
					       GHCI_CAPS_WORD_EXT_CAP_FEATURE),
			.address_mode = ghci_has_walker(gdev) ?
						DRM_GHCI_ADDRESS_MMU :
						DRM_GHCI_ADDRESS_FLAT,
			.protection = ghci_protection(gdev),
			.pci_vendor = gdev->pdev->vendor,
			.pci_device = gdev->pdev->device,
			.flags = gdev->polled ? 0 : DRM_GHCI_DEV_INFO_IRQ,
			.caps_bytes = GHCI_CAPS_TOTAL_BYTES,
			.gclk_hz = ghci_caps_word(gdev, GHCI_CAPS_WORD_GCLK_HZ),
			.max_chunks = GHCI_MAX_CHUNKS,
			.max_chunk_dwords = GHCI_MAX_CHUNK_DWORDS,
			.host_limit = gdev->host_limit,
			.local_base = gdev->local_base,
			.local_size = gdev->local_size,
		};
		src = &info;
		size = sizeof(info);
		break;
	case DRM_GHCI_DEV_QUERY_CAPS:
		src = gdev->caps;
		size = sizeof(gdev->caps);
		break;
	default:
		return -EINVAL;
	}

	if (q->size &&
	    copy_to_user(u64_to_user_ptr(q->pointer), src, min(q->size, size)))
		return -EFAULT;

	q->size = size;

	return 0;
}

static int ghci_ioctl_bo_create(struct drm_device *drm, void *data,
				struct drm_file *file)
{
	struct ghci_device *gdev = to_ghci(drm);
	struct drm_ghci_bo_create *args = data;
	struct ghci_bo *bo;
	u64 addr = 0;
	int ret;

	if (!args->size || args->size > SIZE_MAX ||
	    (args->flags & ~DRM_GHCI_BO_FLAGS))
		return -EINVAL;

	bo = ghci_bo_create(gdev, args->size, args->flags);
	if (IS_ERR(bo))
		return PTR_ERR(bo);

	if (!ghci_has_walker(gdev)) {
		ret = ghci_bo_gpu_addr(gdev, bo, &addr);
		if (ret)
			goto out;
	}

	ret = drm_gem_handle_create(file, &bo->base.base, &args->handle);
	if (!ret)
		args->gpu_addr = addr;

out:
	/* The handle holds the object now, or nothing does. */
	drm_gem_object_put(&bo->base.base);

	return ret;
}

static int ghci_ioctl_bo_mmap_offset(struct drm_device *drm, void *data,
				     struct drm_file *file)
{
	struct drm_ghci_bo_mmap_offset *args = data;
	struct drm_gem_object *obj;
	int ret;

	if (args->pad)
		return -EINVAL;

	obj = drm_gem_object_lookup(file, args->handle);
	if (!obj)
		return -ENOENT;

	if (to_ghci_bo(obj)->flags & DRM_GHCI_BO_NO_MMAP) {
		ret = -EPERM;
		goto out;
	}

	ret = drm_gem_create_mmap_offset(obj);
	if (!ret)
		args->offset = drm_vma_node_offset_addr(&obj->vma_node);

out:
	drm_gem_object_put(obj);

	return ret;
}

static int ghci_ioctl_bo_info(struct drm_device *drm, void *data,
			      struct drm_file *file)
{
	struct ghci_device *gdev = to_ghci(drm);
	struct drm_ghci_bo_info *args = data;
	struct drm_gem_object *obj;
	u64 addr = 0;
	int ret = 0;

	obj = drm_gem_object_lookup(file, args->handle);
	if (!obj)
		return -ENOENT;

	if (!ghci_has_walker(gdev))
		ret = ghci_bo_gpu_addr(gdev, to_ghci_bo(obj), &addr);

	if (!ret) {
		args->flags = to_ghci_bo(obj)->flags;
		args->size = obj->size;
		args->gpu_addr = addr;
	}

	drm_gem_object_put(obj);

	return ret;
}

static int ghci_ioctl_bo_wait(struct drm_device *drm, void *data,
			      struct drm_file *file)
{
	struct drm_ghci_bo_wait *args = data;
	struct drm_gem_object *obj;
	unsigned long timeout;
	long ret;

	if (args->flags & ~DRM_GHCI_BO_WAIT_WRITE)
		return -EINVAL;

	timeout = drm_timeout_abs_to_jiffies(args->timeout_ns);

	obj = drm_gem_object_lookup(file, args->handle);
	if (!obj)
		return -ENOENT;

	ret = dma_resv_wait_timeout(obj->resv,
				    (args->flags & DRM_GHCI_BO_WAIT_WRITE) ?
					    DMA_RESV_USAGE_WRITE :
					    DMA_RESV_USAGE_READ,
				    true, timeout);

	drm_gem_object_put(obj);
	if (ret == 0)
		return timeout ? -ETIMEDOUT : -EBUSY;

	return ret < 0 ? ret : 0;
}

static int ghci_ioctl_vm_create(struct drm_device *drm, void *data,
				struct drm_file *file)
{
	struct ghci_file *gfile = file->driver_priv;
	struct drm_ghci_vm_create *args = data;
	struct ghci_vm *vm;
	u32 id;
	int ret;

	if (args->flags)
		return -EINVAL;

	vm = kzalloc(sizeof(*vm), GFP_KERNEL);
	if (!vm)
		return -ENOMEM;

	vm->state = DRM_GHCI_VM_USABLE;

	ret = xa_alloc(&gfile->vms, &id, vm, XA_LIMIT(1, GHCI_VMS_PER_FILE),
		       GFP_KERNEL);
	if (ret) {
		kfree(vm);
		return ret == -EBUSY ? -ENOSPC : ret;
	}

	vm->id = id;
	args->vm_id = id;

	return 0;
}

static int ghci_ioctl_vm_destroy(struct drm_device *drm, void *data,
				 struct drm_file *file)
{
	struct ghci_file *gfile = file->driver_priv;
	struct drm_ghci_vm_destroy *args = data;
	struct ghci_vm *vm;

	if (args->pad)
		return -EINVAL;

	vm = xa_erase(&gfile->vms, args->vm_id);
	if (!vm)
		return -ENOENT;

	kfree(vm);

	return 0;
}

static int ghci_ioctl_vm_get_state(struct drm_device *drm, void *data,
				   struct drm_file *file)
{
	struct ghci_file *gfile = file->driver_priv;
	struct drm_ghci_vm_get_state *args = data;
	struct ghci_vm *vm;

	xa_lock(&gfile->vms);
	vm = xa_load(&gfile->vms, args->vm_id);
	if (vm)
		args->state = READ_ONCE(vm->state);
	xa_unlock(&gfile->vms);

	return vm ? 0 : -ENOENT;
}

static int ghci_ioctl_not_yet(struct drm_device *drm, void *data,
			      struct drm_file *file)
{
	return -EOPNOTSUPP;
}

#define GHCI_IOCTL(n, func) \
	DRM_IOCTL_DEF_DRV(GHCI_##n, ghci_ioctl_##func, DRM_RENDER_ALLOW)

const struct drm_ioctl_desc ghci_ioctls[GHCI_NUM_IOCTLS] = {
	GHCI_IOCTL(DEV_QUERY, dev_query),
	GHCI_IOCTL(BO_CREATE, bo_create),
	GHCI_IOCTL(BO_MMAP_OFFSET, bo_mmap_offset),
	GHCI_IOCTL(BO_INFO, bo_info),
	GHCI_IOCTL(VM_CREATE, vm_create),
	GHCI_IOCTL(VM_DESTROY, vm_destroy),
	GHCI_IOCTL(VM_BIND, not_yet),
	GHCI_IOCTL(SUBMIT, not_yet),
	GHCI_IOCTL(VM_GET_STATE, vm_get_state),
	GHCI_IOCTL(BO_WAIT, bo_wait),
};

int ghci_file_open(struct drm_device *drm, struct drm_file *file)
{
	struct ghci_file *gfile = kzalloc(sizeof(*gfile), GFP_KERNEL);

	if (!gfile)
		return -ENOMEM;

	gfile->gdev = to_ghci(drm);
	xa_init_flags(&gfile->vms, XA_FLAGS_ALLOC1);
	file->driver_priv = gfile;

	return 0;
}

void ghci_file_close(struct drm_device *drm, struct drm_file *file)
{
	struct ghci_file *gfile = file->driver_priv;
	struct ghci_vm *vm;
	unsigned long id;

	xa_for_each(&gfile->vms, id, vm)
		kfree(vm);
	xa_destroy(&gfile->vms);
	kfree(gfile);
}
