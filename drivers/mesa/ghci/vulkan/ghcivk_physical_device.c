/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_physical_device.c: a GHCI GPU found through its DRM render node.
 * The features, limits and memory come from the capability block that the
 * kernel read with CMD_QUERY_CAPS (ghci.md 3.2) and from the limits table
 * of ghci.md 8.6.  What the driver can not do yet is not advertised: the
 * driver grows its feature list as it grows.
 */

#include "ghcivk_private.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <xf86drm.h>

#include "git_sha1.h"
#include "util/mesa-blake3.h"
#include "util/os_misc.h"
#include "vk_drm_syncobj.h"
#include "vk_util.h"

static void
ghcivk_get_extensions(const struct ghcivk_physical_device *pdev,
                      struct vk_device_extension_table *ext)
{
   *ext = (struct vk_device_extension_table) {
      .EXT_physical_device_drm = true,
   };
}

static void
ghcivk_get_features(const struct ghcivk_physical_device *pdev,
                    struct vk_features *features)
{
   *features = (struct vk_features) {
      /* Required by Vulkan 1.0; the compiler bounds every buffer access by
       * its descriptor's size. */
      .robustBufferAccess = true,
   };
}

static void
ghcivk_hash_uuid(uint8_t uuid[VK_UUID_SIZE], const char *text)
{
   blake3_hash hash;

   _mesa_blake3_compute(text, strlen(text), hash);
   memcpy(uuid, hash, VK_UUID_SIZE);
}

static void
ghcivk_get_properties(const struct ghcivk_physical_device *pdev,
                      struct vk_properties *p)
{
   const struct ghci_dev *dev = &pdev->dev;
   uint32_t device_caps = ghci_dev_caps(dev, GHCI_CAPS_WORD_DEVICE_CAPS);
   uint32_t feature = ghci_dev_caps(dev, GHCI_CAPS_WORD_EXT_CAP_FEATURE);
   uint32_t vendor = ghci_dev_caps(dev, GHCI_CAPS_WORD_VENDOR_ID) & 0xffff;
   uint32_t device = ghci_dev_caps(dev, GHCI_CAPS_WORD_DEVICE_ID) & 0xffff;
   uint32_t gclk_hz = ghci_dev_caps(dev, GHCI_CAPS_WORD_GCLK_HZ);
   uint32_t max_mrt = GHCI_EXT_FEAT_MAX_MRT(feature);
   uint32_t lds_kb = GHCI_EXT_FEAT_LDS_KB(feature);

   if (max_mrt == 0)
      max_mrt = 1;

   *p = (struct vk_properties) {
      .apiVersion = VK_MAKE_API_VERSION(0, 1, 0, VK_HEADER_VERSION),
      .driverVersion = vk_get_driver_version(),
      .vendorID = vendor,
      .deviceID = device,
      .deviceType = (device_caps & GHCI_DEV_CAP_UMA)
                       ? VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
                       : VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU,

      /* ghci.md 8.6 */
      .maxImageDimension1D = 16384,
      .maxImageDimension2D = 16384,
      .maxImageDimension3D = 2048,
      .maxImageDimensionCube = 16384,
      .maxImageArrayLayers = 2048,
      .maxTexelBufferElements = 67108864,
      .maxUniformBufferRange = 65536,
      .maxStorageBufferRange = UINT32_MAX,
      .maxPushConstantsSize = 128,
      .maxMemoryAllocationCount = 4096,
      .maxSamplerAllocationCount = 4000,
      .bufferImageGranularity = 64,
      .sparseAddressSpaceSize = 0,
      .maxBoundDescriptorSets = 4,
      .maxPerStageDescriptorSamplers = 16,
      .maxPerStageDescriptorUniformBuffers = 16,
      .maxPerStageDescriptorStorageBuffers = 16,
      .maxPerStageDescriptorSampledImages = 16,
      .maxPerStageDescriptorStorageImages = 8,
      .maxPerStageDescriptorInputAttachments = max_mrt,
      .maxPerStageResources = 128,
      .maxDescriptorSetSamplers = 96,
      .maxDescriptorSetUniformBuffers = 72,
      .maxDescriptorSetUniformBuffersDynamic = 8,
      .maxDescriptorSetStorageBuffers = 24,
      .maxDescriptorSetStorageBuffersDynamic = 4,
      .maxDescriptorSetSampledImages = 96,
      .maxDescriptorSetStorageImages = 24,
      .maxDescriptorSetInputAttachments = max_mrt,
      .maxVertexInputAttributes = 16,
      .maxVertexInputBindings = 16,
      .maxVertexInputAttributeOffset = 524287,
      .maxVertexInputBindingStride = 4095,
      .maxVertexOutputComponents = 64,
      .maxFragmentInputComponents = 64,
      .maxFragmentOutputAttachments = max_mrt,
      .maxFragmentDualSrcAttachments =
         (device_caps & GHCI_DEV_CAP_DUAL_SOURCE) ? 1 : 0,
      .maxFragmentCombinedOutputResources = max_mrt + 8 + 16,
      .maxComputeSharedMemorySize = lds_kb * 1024,
      .maxComputeWorkGroupCount = { 65535, 65535, 65535 },
      .maxComputeWorkGroupInvocations = 256,
      .maxComputeWorkGroupSize = { 256, 256, 64 },
      .subPixelPrecisionBits = 4,
      .subTexelPrecisionBits = 4,
      .mipmapPrecisionBits = 4,
      .maxDrawIndexedIndexValue = UINT32_MAX,
      .maxDrawIndirectCount =
         (device_caps & GHCI_DEV_CAP_INDIRECT_DRAW) ? UINT32_MAX : 1,
      .maxSamplerLodBias = 16.0f,
      .maxSamplerAnisotropy = 1.0f,
      .maxViewports = 1,
      .maxViewportDimensions = { 16384, 16384 },
      .viewportBoundsRange = { -32768.0f, 32767.0f },
      .viewportSubPixelBits = 0,
      .minMemoryMapAlignment = 64,
      .minTexelBufferOffsetAlignment = 16,
      .minUniformBufferOffsetAlignment = 64,
      .minStorageBufferOffsetAlignment = 16,
      .minTexelOffset = -8,
      .maxTexelOffset = 7,
      .maxFramebufferWidth = 16384,
      .maxFramebufferHeight = 16384,
      .maxFramebufferLayers = 1,
      .framebufferColorSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .framebufferDepthSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .framebufferStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .framebufferNoAttachmentsSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .maxColorAttachments = max_mrt,
      .sampledImageColorSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .sampledImageIntegerSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .sampledImageDepthSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .sampledImageStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .storageImageSampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .maxSampleMaskWords = 1,
      .timestampComputeAndGraphics = true,
      .timestampPeriod = gclk_hz ? 1e9f / (float)gclk_hz : 1.0f,
      .maxClipDistances = 0,
      .maxCullDistances = 0,
      .maxCombinedClipAndCullDistances = 0,
      .discreteQueuePriorities = 2,
      .pointSizeRange = { 1.0f, 1.0f },
      .lineWidthRange = { 1.0f, 1.0f },
      .pointSizeGranularity = 0.0f,
      .lineWidthGranularity = 0.0f,
      .strictLines = false,
      .standardSampleLocations = true,
      .optimalBufferCopyOffsetAlignment = 64,
      .optimalBufferCopyRowPitchAlignment = 64,
      .nonCoherentAtomSize = 64,

      /* VK_EXT_physical_device_drm */
      .drmHasPrimary = false,
      .drmHasRender = true,
      .drmRenderMajor = major(pdev->render_dev),
      .drmRenderMinor = minor(pdev->render_dev),
   };

   snprintf(p->deviceName, sizeof(p->deviceName), "GHCI GPU %04x:%04x",
            vendor, device);

   char text[128];
   snprintf(text, sizeof(text), "ghci-pipeline-cache %s", MESA_GIT_SHA1);
   ghcivk_hash_uuid(p->pipelineCacheUUID, text);
   snprintf(text, sizeof(text), "ghci-driver %s", MESA_GIT_SHA1);
   ghcivk_hash_uuid(p->driverUUID, text);
   snprintf(text, sizeof(text), "ghci-device %04x:%04x %u:%u", vendor, device,
            major(pdev->render_dev), minor(pdev->render_dev));
   ghcivk_hash_uuid(p->deviceUUID, text);
}

VkResult
ghcivk_physical_device_try_create(struct vk_instance *vk_instance,
                                  struct _drmDevice *drm_device,
                                  struct vk_physical_device **out)
{
   struct ghcivk_instance *instance =
      container_of(vk_instance, struct ghcivk_instance, vk);
   VkResult result;

   if (!(drm_device->available_nodes & (1 << DRM_NODE_RENDER)))
      return VK_ERROR_INCOMPATIBLE_DRIVER;

   const char *path = drm_device->nodes[DRM_NODE_RENDER];
   int fd = open(path, O_RDWR | O_CLOEXEC);
   if (fd < 0)
      return VK_ERROR_INCOMPATIBLE_DRIVER;

   struct ghcivk_physical_device *pdev =
      vk_zalloc(&instance->vk.alloc, sizeof(*pdev), 8,
                VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE);
   if (!pdev) {
      close(fd);
      return vk_error(instance, VK_ERROR_OUT_OF_HOST_MEMORY);
   }

   int ret = ghci_dev_init(&pdev->dev, fd);
   if (ret == -ENODEV) {
      /* Another driver's device: not an error. */
      result = VK_ERROR_INCOMPATIBLE_DRIVER;
      goto fail_alloc;
   }
   if (ret) {
      result = vk_errorf(instance, VK_ERROR_INITIALIZATION_FAILED,
                         "%s: the ghci device query failed: %s", path,
                         strerror(-ret));
      goto fail_alloc;
   }
   if (ghci_dev_caps(&pdev->dev, GHCI_CAPS_WORD_NATIVE_ISA_ID) !=
       GHCI_CAPS_ISA_GSI1) {
      /* A display or blit-only GHCI device has no shader units. */
      result = VK_ERROR_INCOMPATIBLE_DRIVER;
      goto fail_alloc;
   }

   struct stat st;
   if (fstat(fd, &st)) {
      result = vk_errorf(instance, VK_ERROR_INITIALIZATION_FAILED,
                         "fstat %s: %m", path);
      goto fail_alloc;
   }
   pdev->render_dev = st.st_rdev;

   struct vk_physical_device_dispatch_table dispatch;
   vk_physical_device_dispatch_table_from_entrypoints(
      &dispatch, &ghcivk_physical_device_entrypoints, true);

   struct vk_device_extension_table extensions;
   struct vk_features features;
   struct vk_properties properties;
   ghcivk_get_extensions(pdev, &extensions);
   ghcivk_get_features(pdev, &features);
   ghcivk_get_properties(pdev, &properties);

   result = vk_physical_device_init(&pdev->vk, &instance->vk, &extensions,
                                    &features, &properties, &dispatch);
   if (result != VK_SUCCESS)
      goto fail_alloc;

   /* One heap of host memory that the GPU reaches by DMA (ghci.md 11.1).
    * x86 PCIe snoops the CPU caches, so the CPU maps it cached. */
   uint64_t total = 0;
   if (!os_get_total_physical_memory(&total))
      total = 1ull << 30;
   pdev->heap = (VkMemoryHeap) {
      .size = total * 3 / 4,
      .flags = VK_MEMORY_HEAP_DEVICE_LOCAL_BIT,
   };
   pdev->type = (VkMemoryType) {
      .propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT |
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                       VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                       VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
      .heapIndex = 0,
   };

   pdev->syncobj_type = vk_drm_syncobj_get_type(fd);
   pdev->sync_types[0] = &pdev->syncobj_type;
   pdev->sync_types[1] = NULL;
   pdev->vk.supported_sync_types = pdev->sync_types;

   vk_warn_non_conformant_implementation(GHCIVK_DRIVER_NAME);

   *out = &pdev->vk;
   return VK_SUCCESS;

fail_alloc:
   vk_free(&instance->vk.alloc, pdev);
   close(fd);
   return result;
}

void
ghcivk_physical_device_destroy(struct vk_physical_device *vk_pdev)
{
   struct ghcivk_physical_device *pdev =
      container_of(vk_pdev, struct ghcivk_physical_device, vk);

   close(pdev->dev.fd);
   vk_physical_device_finish(&pdev->vk);
   vk_free(&pdev->vk.instance->alloc, pdev);
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetPhysicalDeviceQueueFamilyProperties2(
   VkPhysicalDevice physicalDevice, uint32_t *pQueueFamilyPropertyCount,
   VkQueueFamilyProperties2 *pQueueFamilyProperties)
{
   VK_OUTARRAY_MAKE_TYPED(VkQueueFamilyProperties2, out,
                          pQueueFamilyProperties, pQueueFamilyPropertyCount);

   /* GHCI has one ring (ghci.md 6), so one queue of one family. */
   vk_outarray_append_typed(VkQueueFamilyProperties2, &out, p) {
      p->queueFamilyProperties = (VkQueueFamilyProperties) {
         .queueFlags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT |
                       VK_QUEUE_TRANSFER_BIT,
         .queueCount = 1,
         .timestampValidBits = 64,
         .minImageTransferGranularity = { 1, 1, 1 },
      };
   }
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetPhysicalDeviceMemoryProperties2(
   VkPhysicalDevice physicalDevice,
   VkPhysicalDeviceMemoryProperties2 *pMemoryProperties)
{
   VK_FROM_HANDLE(ghcivk_physical_device, pdev, physicalDevice);

   pMemoryProperties->memoryProperties = (VkPhysicalDeviceMemoryProperties) {
      .memoryTypeCount = 1,
      .memoryTypes = { pdev->type },
      .memoryHeapCount = 1,
      .memoryHeaps = { pdev->heap },
   };
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetPhysicalDeviceExternalBufferProperties(
   VkPhysicalDevice physicalDevice,
   const VkPhysicalDeviceExternalBufferInfo *pExternalBufferInfo,
   VkExternalBufferProperties *pExternalBufferProperties)
{
   /* External memory arrives with the memory objects. */
   pExternalBufferProperties->externalMemoryProperties =
      (VkExternalMemoryProperties) {
         .compatibleHandleTypes = pExternalBufferInfo->handleType,
      };
}
