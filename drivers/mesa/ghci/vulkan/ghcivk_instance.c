/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_instance.c: the Vulkan instance.  Physical devices are found by
 * the common runtime, which walks the DRM devices and hands each to
 * ghcivk_physical_device_try_create().
 */

#include "ghcivk_private.h"

#include "util/macros.h"
#include "vk_alloc.h"

static const struct vk_instance_extension_table ghcivk_instance_extensions = {
   .KHR_device_group_creation = true,
   .KHR_external_fence_capabilities = true,
   .KHR_external_memory_capabilities = true,
   .KHR_external_semaphore_capabilities = true,
   .KHR_get_physical_device_properties2 = true,
   .EXT_debug_report = true,
   .EXT_debug_utils = true,
};

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_EnumerateInstanceVersion(uint32_t *pApiVersion)
{
   *pApiVersion = VK_MAKE_API_VERSION(0, 1, 0, VK_HEADER_VERSION);
   return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_EnumerateInstanceExtensionProperties(const char *pLayerName,
                                            uint32_t *pPropertyCount,
                                            VkExtensionProperties *pProperties)
{
   if (pLayerName)
      return vk_error(NULL, VK_ERROR_LAYER_NOT_PRESENT);

   return vk_enumerate_instance_extension_properties(
      &ghcivk_instance_extensions, pPropertyCount, pProperties);
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_CreateInstance(const VkInstanceCreateInfo *pCreateInfo,
                      const VkAllocationCallbacks *pAllocator,
                      VkInstance *pInstance)
{
   if (!pAllocator)
      pAllocator = vk_default_allocator();

   struct ghcivk_instance *instance =
      vk_zalloc(pAllocator, sizeof(*instance), 8,
                VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE);
   if (!instance)
      return vk_error(NULL, VK_ERROR_OUT_OF_HOST_MEMORY);

   struct vk_instance_dispatch_table dispatch;
   vk_instance_dispatch_table_from_entrypoints(
      &dispatch, &ghcivk_instance_entrypoints, true);

   VkResult result = vk_instance_init(&instance->vk,
                                      &ghcivk_instance_extensions, &dispatch,
                                      pCreateInfo, pAllocator);
   if (result != VK_SUCCESS) {
      vk_free(pAllocator, instance);
      return result;
   }

   instance->vk.physical_devices.try_create_for_drm =
      ghcivk_physical_device_try_create;
   instance->vk.physical_devices.destroy = ghcivk_physical_device_destroy;

   *pInstance = ghcivk_instance_to_handle(instance);
   return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_DestroyInstance(VkInstance _instance,
                       const VkAllocationCallbacks *pAllocator)
{
   VK_FROM_HANDLE(ghcivk_instance, instance, _instance);

   if (!instance)
      return;

   vk_instance_finish(&instance->vk);
   vk_free(&instance->vk.alloc, instance);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
ghcivk_GetInstanceProcAddr(VkInstance _instance, const char *pName)
{
   VK_FROM_HANDLE(ghcivk_instance, instance, _instance);

   return vk_instance_get_proc_addr(instance ? &instance->vk : NULL,
                                    &ghcivk_instance_entrypoints, pName);
}

/* The loader-ICD interface (vk_icd.h); the common runtime provides
 * vk_icdGetPhysicalDeviceProcAddr. */
PUBLIC VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vk_icdGetInstanceProcAddr(VkInstance instance, const char *pName);

PUBLIC VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vk_icdGetInstanceProcAddr(VkInstance instance, const char *pName)
{
   return ghcivk_GetInstanceProcAddr(instance, pName);
}
