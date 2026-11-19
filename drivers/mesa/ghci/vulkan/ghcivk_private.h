/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_private.h: the objects of the GHCI Vulkan driver.  The driver
 * sits on Mesa's common Vulkan runtime (src/vulkan/runtime); the GHCI part
 * is the device description from the kernel (common/ghci_dev.h), the
 * memory, the command recording into GHCI packets and the GSI1 compiler.
 */

#ifndef GHCIVK_PRIVATE_H
#define GHCIVK_PRIVATE_H

#include <sys/types.h>

#include "ghci_dev.h"
#include "ghcivk_entrypoints.h"

#include "vk_alloc.h"
#include "vk_device.h"
#include "vk_instance.h"
#include "vk_log.h"
#include "vk_physical_device.h"
#include "vk_queue.h"
#include "vk_sync.h"

#define GHCIVK_DRIVER_NAME "ghci"

struct ghcivk_instance {
   struct vk_instance vk;
};

VK_DEFINE_HANDLE_CASTS(ghcivk_instance, vk.base, VkInstance,
                       VK_OBJECT_TYPE_INSTANCE)

struct ghcivk_physical_device {
   struct vk_physical_device vk;

   /* The render node, open for the life of the physical device. */
   struct ghci_dev dev;
   dev_t render_dev;

   VkMemoryHeap heap;
   VkMemoryType type;

   struct vk_sync_type syncobj_type;
   const struct vk_sync_type *sync_types[2];
};

VK_DEFINE_HANDLE_CASTS(ghcivk_physical_device, vk.base, VkPhysicalDevice,
                       VK_OBJECT_TYPE_PHYSICAL_DEVICE)

VkResult ghcivk_physical_device_try_create(struct vk_instance *vk_instance,
                                           struct _drmDevice *drm_device,
                                           struct vk_physical_device **out);
void ghcivk_physical_device_destroy(struct vk_physical_device *vk_pdev);

/* ghcivk_formats.c */
VkFormatFeatureFlags2
ghcivk_format_features(const struct ghcivk_physical_device *pdev,
                       VkFormat format, VkImageTiling tiling);
VkFormatFeatureFlags2
ghcivk_buffer_format_features(const struct ghcivk_physical_device *pdev,
                              VkFormat format);

struct ghcivk_queue {
   struct vk_queue vk;
};

struct ghcivk_device {
   struct vk_device vk;
   struct ghcivk_queue queue;
   uint32_t vm_id;
};

VK_DEFINE_HANDLE_CASTS(ghcivk_device, vk.base, VkDevice, VK_OBJECT_TYPE_DEVICE)

static inline struct ghcivk_physical_device *
ghcivk_device_physical(struct ghcivk_device *device)
{
   return container_of(device->vk.physical, struct ghcivk_physical_device, vk);
}

#endif /* GHCIVK_PRIVATE_H */
