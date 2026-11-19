/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_formats.c: format and image capabilities, read from the
 * per-format table of the capability block (ghci.md 3.2.5): one dword per
 * VkFormat 0..156, with the optimal-tiling bits in [8:0], the
 * linear-tiling bits in [17:9] and the buffer bits in [21:18].
 */

#include "ghcivk_private.h"

#include "util/log.h"
#include "util/u_math.h"
#include "vk_enum_defines.h"
#include "vk_format.h"
#include "vk_util.h"

/* The image bits of a per-format entry (ghci.md 3.2.5). */
#define GHCI_FMT_SAMPLED        (1u << 0)
#define GHCI_FMT_FILTER_LINEAR  (1u << 1)
#define GHCI_FMT_COLOR          (1u << 2)
#define GHCI_FMT_COLOR_BLEND    (1u << 3)
#define GHCI_FMT_DEPTH_STENCIL  (1u << 4)
#define GHCI_FMT_VERTEX         (1u << 5)
#define GHCI_FMT_BLIT_SRC       (1u << 6)
#define GHCI_FMT_BLIT_DST       (1u << 7)
#define GHCI_FMT_STORAGE        (1u << 8)
#define GHCI_FMT_OPTIMAL(e)     ((e) & 0x1ffu)
#define GHCI_FMT_LINEAR(e)      (((e) >> 9) & 0x1ffu)
/* The buffer bits are VkFormatFeatureFlagBits[6:3] (ghci.md 3.2.5). */
#define GHCI_FMT_BUFFER(e)      ((((e) >> 18) & 0xfu) << 3)

#define GHCI_FMT_VK_COUNT 157u

static uint32_t
ghcivk_format_entry(const struct ghcivk_physical_device *pdev, VkFormat format)
{
   if ((uint32_t)format >= GHCI_FMT_VK_COUNT)
      return 0;
   return ghci_dev_format_caps(&pdev->dev, format);
}

VkFormatFeatureFlags2
ghcivk_format_features(const struct ghcivk_physical_device *pdev,
                       VkFormat format, VkImageTiling tiling)
{
   uint32_t entry = ghcivk_format_entry(pdev, format);
   uint32_t bits = tiling == VK_IMAGE_TILING_LINEAR ? GHCI_FMT_LINEAR(entry)
                                                    : GHCI_FMT_OPTIMAL(entry);
   VkFormatFeatureFlags2 f = 0;

   if (bits & GHCI_FMT_SAMPLED)
      f |= VK_FORMAT_FEATURE_2_SAMPLED_IMAGE_BIT;
   if (bits & GHCI_FMT_FILTER_LINEAR)
      f |= VK_FORMAT_FEATURE_2_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
   if (bits & GHCI_FMT_COLOR)
      f |= VK_FORMAT_FEATURE_2_COLOR_ATTACHMENT_BIT;
   if (bits & GHCI_FMT_COLOR_BLEND)
      f |= VK_FORMAT_FEATURE_2_COLOR_ATTACHMENT_BLEND_BIT;
   if (bits & GHCI_FMT_DEPTH_STENCIL)
      f |= VK_FORMAT_FEATURE_2_DEPTH_STENCIL_ATTACHMENT_BIT;
   if (bits & GHCI_FMT_BLIT_SRC)
      f |= VK_FORMAT_FEATURE_2_BLIT_SRC_BIT;
   if (bits & GHCI_FMT_BLIT_DST)
      f |= VK_FORMAT_FEATURE_2_BLIT_DST_BIT;
   if (bits & GHCI_FMT_STORAGE)
      f |= VK_FORMAT_FEATURE_2_STORAGE_IMAGE_BIT;

   /* Copies are commands of the CP or shaders (ghci.md 7.3): an image the
    * GPU can read or write can be copied. */
   if (f)
      f |= VK_FORMAT_FEATURE_2_TRANSFER_SRC_BIT |
           VK_FORMAT_FEATURE_2_TRANSFER_DST_BIT;

   return f;
}

VkFormatFeatureFlags2
ghcivk_buffer_format_features(const struct ghcivk_physical_device *pdev,
                              VkFormat format)
{
   return GHCI_FMT_BUFFER(ghcivk_format_entry(pdev, format));
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetPhysicalDeviceFormatProperties2(
   VkPhysicalDevice physicalDevice, VkFormat format,
   VkFormatProperties2 *pFormatProperties)
{
   VK_FROM_HANDLE(ghcivk_physical_device, pdev, physicalDevice);

   VkFormatFeatureFlags2 linear =
      ghcivk_format_features(pdev, format, VK_IMAGE_TILING_LINEAR);
   VkFormatFeatureFlags2 optimal =
      ghcivk_format_features(pdev, format, VK_IMAGE_TILING_OPTIMAL);
   VkFormatFeatureFlags2 buffer = ghcivk_buffer_format_features(pdev, format);

   pFormatProperties->formatProperties = (VkFormatProperties) {
      .linearTilingFeatures = vk_format_features2_to_features(linear),
      .optimalTilingFeatures = vk_format_features2_to_features(optimal),
      .bufferFeatures = vk_format_features2_to_features(buffer),
   };

   vk_foreach_struct(stype, ext, pFormatProperties->pNext) {
      switch (stype) {
      case VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3: {
         VkFormatProperties3 *p3 = (void *)ext;
         p3->linearTilingFeatures = linear;
         p3->optimalTilingFeatures = optimal;
         p3->bufferFeatures = buffer;
         break;
      }
      default:
         vk_debug_ignored_stype(stype);
         break;
      }
   }
}

static VkFormatFeatureFlags2
ghcivk_usage_features(VkImageUsageFlags usage)
{
   VkFormatFeatureFlags2 need = 0;

   if (usage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
      need |= VK_FORMAT_FEATURE_2_TRANSFER_SRC_BIT;
   if (usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT)
      need |= VK_FORMAT_FEATURE_2_TRANSFER_DST_BIT;
   if (usage & VK_IMAGE_USAGE_SAMPLED_BIT)
      need |= VK_FORMAT_FEATURE_2_SAMPLED_IMAGE_BIT;
   if (usage & VK_IMAGE_USAGE_STORAGE_BIT)
      need |= VK_FORMAT_FEATURE_2_STORAGE_IMAGE_BIT;
   if (usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      need |= VK_FORMAT_FEATURE_2_COLOR_ATTACHMENT_BIT;
   if (usage & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
      need |= VK_FORMAT_FEATURE_2_DEPTH_STENCIL_ATTACHMENT_BIT;

   return need;
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_GetPhysicalDeviceImageFormatProperties2(
   VkPhysicalDevice physicalDevice,
   const VkPhysicalDeviceImageFormatInfo2 *pImageFormatInfo,
   VkImageFormatProperties2 *pImageFormatProperties)
{
   VK_FROM_HANDLE(ghcivk_physical_device, pdev, physicalDevice);
   const VkPhysicalDeviceImageFormatInfo2 *info = pImageFormatInfo;

   pImageFormatProperties->imageFormatProperties =
      (VkImageFormatProperties) { 0 };

   /* Only linear and optimal tiling, no DRM modifiers or external memory
    * yet. */
   if (info->tiling != VK_IMAGE_TILING_LINEAR &&
       info->tiling != VK_IMAGE_TILING_OPTIMAL)
      return VK_ERROR_FORMAT_NOT_SUPPORTED;

   vk_foreach_struct_const(stype, ext, info->pNext) {
      if (stype ==
          VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO) {
         const VkPhysicalDeviceExternalImageFormatInfo *e = (const void *)ext;
         if (e->handleType)
            return VK_ERROR_FORMAT_NOT_SUPPORTED;
      }
   }

   VkFormatFeatureFlags2 have =
      ghcivk_format_features(pdev, info->format, info->tiling);
   VkFormatFeatureFlags2 need = ghcivk_usage_features(info->usage);
   if (!have || (have & need) != need)
      return VK_ERROR_FORMAT_NOT_SUPPORTED;

   uint32_t ext_fmt = ghci_dev_caps(&pdev->dev, GHCI_CAPS_WORD_EXT_CAP_FMT0);
   VkExtent3D extent;
   uint32_t layers;

   switch (info->type) {
   case VK_IMAGE_TYPE_1D:
      extent = (VkExtent3D) { 16384, 1, 1 };
      layers = (ext_fmt & GHCI_EXT_FMT_TEX_ARRAY) ? 2048 : 1;
      break;
   case VK_IMAGE_TYPE_2D:
      extent = (VkExtent3D) { 16384, 16384, 1 };
      layers = (ext_fmt & GHCI_EXT_FMT_TEX_ARRAY) ? 2048 : 1;
      if ((info->flags & VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT) &&
          !(ext_fmt & GHCI_EXT_FMT_TEX_CUBE))
         return VK_ERROR_FORMAT_NOT_SUPPORTED;
      break;
   case VK_IMAGE_TYPE_3D:
      if (!(ext_fmt & GHCI_EXT_FMT_TEX_3D))
         return VK_ERROR_FORMAT_NOT_SUPPORTED;
      extent = (VkExtent3D) { 2048, 2048, 2048 };
      layers = 1;
      break;
   default:
      return VK_ERROR_FORMAT_NOT_SUPPORTED;
   }

   if (info->tiling == VK_IMAGE_TILING_LINEAR) {
      /* Linear images are for copies and scan-out: one level, one layer,
       * 2D. */
      if (info->type != VK_IMAGE_TYPE_2D)
         return VK_ERROR_FORMAT_NOT_SUPPORTED;
      layers = 1;
   }

   uint32_t levels = info->tiling == VK_IMAGE_TILING_LINEAR
                        ? 1
                        : util_logbase2(MAX3(extent.width, extent.height,
                                             extent.depth)) + 1;

   pImageFormatProperties->imageFormatProperties = (VkImageFormatProperties) {
      .maxExtent = extent,
      .maxMipLevels = levels,
      .maxArrayLayers = layers,
      .sampleCounts = VK_SAMPLE_COUNT_1_BIT,
      .maxResourceSize = UINT32_MAX,
   };

   return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetPhysicalDeviceSparseImageFormatProperties2(
   VkPhysicalDevice physicalDevice,
   const VkPhysicalDeviceSparseImageFormatInfo2 *pFormatInfo,
   uint32_t *pPropertyCount, VkSparseImageFormatProperties2 *pProperties)
{
   /* No sparse resources. */
   *pPropertyCount = 0;
}
