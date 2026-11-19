/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_device.c: the logical device and its one queue.  Each device has
 * its own VM (a GHCI session where the GPU has an MMU).  Submission is not
 * written yet: a queue submission marks the device lost, so that an
 * application sees an error and not a silent success.
 */

#include "ghcivk_private.h"

#include <string.h>

#include "vk_alloc.h"

static VkResult
ghcivk_queue_submit(struct vk_queue *queue, struct vk_queue_submit *submit)
{
   return vk_queue_set_lost(queue, "queue submission is not implemented");
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_CreateDevice(VkPhysicalDevice physicalDevice,
                    const VkDeviceCreateInfo *pCreateInfo,
                    const VkAllocationCallbacks *pAllocator,
                    VkDevice *pDevice)
{
   VK_FROM_HANDLE(ghcivk_physical_device, pdev, physicalDevice);
   VkResult result;

   struct ghcivk_device *device =
      vk_zalloc2(&pdev->vk.instance->alloc, pAllocator, sizeof(*device), 8,
                 VK_SYSTEM_ALLOCATION_SCOPE_DEVICE);
   if (!device)
      return vk_error(pdev, VK_ERROR_OUT_OF_HOST_MEMORY);

   struct vk_device_dispatch_table dispatch;
   vk_device_dispatch_table_from_entrypoints(
      &dispatch, &ghcivk_device_entrypoints, true);

   result = vk_device_init(&device->vk, &pdev->vk, &dispatch, pCreateInfo,
                           pAllocator);
   if (result != VK_SUCCESS)
      goto fail_alloc;

   int ret = ghci_vm_create(&pdev->dev, &device->vm_id);
   if (ret) {
      result = vk_errorf(device, VK_ERROR_INITIALIZATION_FAILED,
                         "VM creation failed: %s", strerror(-ret));
      goto fail_device;
   }

   /* One queue family with one queue
    * (ghcivk_GetPhysicalDeviceQueueFamilyProperties2). */
   for (uint32_t i = 0; i < pCreateInfo->queueCreateInfoCount; i++) {
      const VkDeviceQueueCreateInfo *qinfo =
         &pCreateInfo->pQueueCreateInfos[i];
      result = vk_queue_init(&device->queue.vk, &device->vk, qinfo, 0);
      if (result != VK_SUCCESS)
         goto fail_vm;
      device->queue.vk.driver_submit = ghcivk_queue_submit;
   }

   *pDevice = ghcivk_device_to_handle(device);
   return VK_SUCCESS;

fail_vm:
   ghci_vm_destroy(&pdev->dev, device->vm_id);
fail_device:
   vk_device_finish(&device->vk);
fail_alloc:
   vk_free2(&pdev->vk.instance->alloc, pAllocator, device);
   return result;
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_DestroyDevice(VkDevice _device, const VkAllocationCallbacks *pAllocator)
{
   VK_FROM_HANDLE(ghcivk_device, device, _device);

   if (!device)
      return;

   if (device->queue.vk.base.device)
      vk_queue_finish(&device->queue.vk);
   ghci_vm_destroy(&ghcivk_device_physical(device)->dev, device->vm_id);
   vk_device_finish(&device->vk);
   vk_free(&device->vk.alloc, device);
}
