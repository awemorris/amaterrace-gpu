/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

#include "ghci_dev.h"

#include <errno.h>
#include <string.h>
#include <sys/mman.h>

#include <xf86drm.h>

static int
ghci_ioctl(int fd, unsigned long request, void *arg)
{
   return drmIoctl(fd, request, arg) ? -errno : 0;
}

static int
ghci_dev_query(struct ghci_dev *dev, uint32_t type, void *buf, uint32_t size)
{
   struct drm_ghci_dev_query q = {
      .type = type,
      .size = size,
      .pointer = (uint64_t)(uintptr_t)buf,
   };
   int ret = ghci_ioctl(dev->fd, DRM_IOCTL_GHCI_DEV_QUERY, &q);
   if (ret)
      return ret;
   /* An older kernel may answer with less; the rest stays zero. */
   return 0;
}

int
ghci_dev_init(struct ghci_dev *dev, int fd)
{
   memset(dev, 0, sizeof(*dev));
   dev->fd = fd;

   drmVersionPtr version = drmGetVersion(fd);
   if (!version)
      return -ENODEV;
   bool ours = strcmp(version->name, DRM_GHCI_DRIVER_NAME) == 0;
   drmFreeVersion(version);
   if (!ours)
      return -ENODEV;

   int ret = ghci_dev_query(dev, DRM_GHCI_DEV_QUERY_INFO, &dev->info,
                            sizeof(dev->info));
   if (ret)
      return ret;
   if ((dev->info.ghci_version >> 16) != GHCI_VERSION_MAJOR)
      return -ENODEV;

   ret = ghci_dev_query(dev, DRM_GHCI_DEV_QUERY_CAPS, dev->caps,
                        sizeof(dev->caps));
   if (ret)
      return ret;
   if (dev->caps[GHCI_CAPS_WORD_BLOCK_ID] != GHCI_CAPS_BLOCK_MAGIC)
      return -EINVAL;

   return 0;
}

uint32_t
ghci_dev_format_caps(const struct ghci_dev *dev, unsigned vk_format)
{
   uint32_t first = ghci_dev_caps(dev, GHCI_CAPS_WORD_FMT_FIRST_REG);
   uint32_t count = ghci_dev_caps(dev, GHCI_CAPS_WORD_FMT_COUNT_REG);

   if (vk_format >= count || first + vk_format >= GHCI_CAPS_TOTAL_DWORDS)
      return 0;
   return dev->caps[first + vk_format];
}

int
ghci_bo_create(struct ghci_dev *dev, uint64_t size, uint32_t flags,
               struct ghci_bo *bo)
{
   struct drm_ghci_bo_create req = {
      .size = size,
      .flags = flags,
   };
   int ret = ghci_ioctl(dev->fd, DRM_IOCTL_GHCI_BO_CREATE, &req);
   if (ret)
      return ret;

   *bo = (struct ghci_bo) {
      .handle = req.handle,
      .flags = flags,
      .size = size,
      .gpu_addr = req.gpu_addr,
   };
   return 0;
}

int
ghci_bo_map(struct ghci_dev *dev, struct ghci_bo *bo)
{
   if (bo->map)
      return 0;

   struct drm_ghci_bo_mmap_offset req = { .handle = bo->handle };
   int ret = ghci_ioctl(dev->fd, DRM_IOCTL_GHCI_BO_MMAP_OFFSET, &req);
   if (ret)
      return ret;

   void *map = mmap(NULL, bo->size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    dev->fd, req.offset);
   if (map == MAP_FAILED)
      return -errno;
   bo->map = map;
   return 0;
}

void
ghci_bo_unmap(struct ghci_bo *bo)
{
   if (bo->map) {
      munmap(bo->map, bo->size);
      bo->map = NULL;
   }
}

int
ghci_bo_close(struct ghci_dev *dev, struct ghci_bo *bo)
{
   ghci_bo_unmap(bo);
   struct drm_gem_close req = { .handle = bo->handle };
   int ret = ghci_ioctl(dev->fd, DRM_IOCTL_GEM_CLOSE, &req);
   bo->handle = 0;
   return ret;
}

int
ghci_vm_create(struct ghci_dev *dev, uint32_t *vm_id)
{
   struct drm_ghci_vm_create req = { 0 };
   int ret = ghci_ioctl(dev->fd, DRM_IOCTL_GHCI_VM_CREATE, &req);
   if (ret)
      return ret;
   *vm_id = req.vm_id;
   return 0;
}

int
ghci_vm_destroy(struct ghci_dev *dev, uint32_t vm_id)
{
   struct drm_ghci_vm_destroy req = { .vm_id = vm_id };
   return ghci_ioctl(dev->fd, DRM_IOCTL_GHCI_VM_DESTROY, &req);
}
