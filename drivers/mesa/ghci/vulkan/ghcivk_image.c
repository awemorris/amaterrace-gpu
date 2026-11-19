/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_image.c: images and buffers, and the memory they need.  The image
 * layout is the one of ghci.md 8.5.2:
 *
 *  - linear: rows aligned to 64 bytes (GHCI_LAYOUT_ALIGN);
 *  - optimal: 8x8-texel tiles (2x2 blocks of a compressed format), a row of
 *    tiles aligned to 256 bytes, each level at a 256-byte aligned offset;
 *  - a layer holds its levels one after another; the layer stride
 *    (slice_pitch_bytes) is the aligned size of one layer.
 */

#include "ghcivk_private.h"

#include "util/format/u_format.h"
#include "util/u_math.h"
#include "vk_buffer.h"
#include "vk_format.h"
#include "vk_image.h"

#define GHCIVK_LINEAR_ALIGN  64u
#define GHCIVK_TILED_ALIGN   256u
#define GHCIVK_TILE_TEXELS   8u
/* The alignment of a whole resource: a page, so that a resource can be
 * scanned out or shared alone. */
#define GHCIVK_RESOURCE_ALIGN 4096u

struct ghcivk_image_level {
   uint64_t offset;      /* from the start of the layer */
   uint32_t row_pitch;   /* bytes; for tiled images, of one row of tiles */
   uint64_t slice_size;  /* bytes of one depth slice of the level */
};

struct ghcivk_image {
   struct vk_image vk;
   bool tiled;
   uint64_t layer_stride;
   uint64_t size;
   struct ghcivk_image_level levels[15];
};

VK_DEFINE_NONDISP_HANDLE_CASTS(ghcivk_image, vk.base, VkImage,
                               VK_OBJECT_TYPE_IMAGE)

struct ghcivk_buffer {
   struct vk_buffer vk;
};

VK_DEFINE_NONDISP_HANDLE_CASTS(ghcivk_buffer, vk.base, VkBuffer,
                               VK_OBJECT_TYPE_BUFFER)

static void
ghcivk_image_layout(struct ghcivk_image *image)
{
   enum pipe_format pf = vk_format_to_pipe_format(image->vk.format);
   const uint32_t bw = util_format_get_blockwidth(pf);
   const uint32_t bh = util_format_get_blockheight(pf);
   const uint32_t bpb = util_format_get_blocksize(pf);
   const uint32_t level_align = image->tiled ? GHCIVK_TILED_ALIGN
                                             : GHCIVK_LINEAR_ALIGN;
   uint64_t offset = 0;

   for (uint32_t l = 0; l < image->vk.mip_levels; l++) {
      const VkExtent3D e = vk_image_mip_level_extent(&image->vk, l);
      const uint32_t bx = DIV_ROUND_UP(e.width, bw);
      const uint32_t by = DIV_ROUND_UP(e.height, bh);
      struct ghcivk_image_level *lv = &image->levels[l];

      if (image->tiled) {
         /* An 8x8-texel tile is (8 / block width)^2 blocks. */
         const uint32_t tile_blocks_x = GHCIVK_TILE_TEXELS / bw;
         const uint32_t tile_blocks_y = GHCIVK_TILE_TEXELS / bh;
         const uint32_t tile_bytes = tile_blocks_x * tile_blocks_y * bpb;
         const uint32_t tiles_x = DIV_ROUND_UP(bx, tile_blocks_x);
         const uint32_t tiles_y = DIV_ROUND_UP(by, tile_blocks_y);

         lv->row_pitch = align(tiles_x * tile_bytes, GHCIVK_TILED_ALIGN);
         lv->slice_size = (uint64_t)lv->row_pitch * tiles_y;
      } else {
         lv->row_pitch = align(bx * bpb, GHCIVK_LINEAR_ALIGN);
         lv->slice_size = align64((uint64_t)lv->row_pitch * by,
                                  GHCIVK_LINEAR_ALIGN);
      }

      offset = align64(offset, level_align);
      lv->offset = offset;
      offset += lv->slice_size * e.depth * image->vk.samples;
   }

   image->layer_stride = align64(offset, level_align);
   image->size = image->layer_stride * image->vk.array_layers;
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_CreateImage(VkDevice _device, const VkImageCreateInfo *pCreateInfo,
                   const VkAllocationCallbacks *pAllocator, VkImage *pImage)
{
   VK_FROM_HANDLE(ghcivk_device, device, _device);

   /* Formats the hardware does not know, DRM modifiers and multi-planar
    * images come later. */
   if (pCreateInfo->tiling != VK_IMAGE_TILING_LINEAR &&
       pCreateInfo->tiling != VK_IMAGE_TILING_OPTIMAL)
      return vk_error(device, VK_ERROR_FEATURE_NOT_PRESENT);
   if (vk_format_get_plane_count(pCreateInfo->format) != 1 ||
       vk_format_to_pipe_format(pCreateInfo->format) == PIPE_FORMAT_NONE)
      return vk_error(device, VK_ERROR_FORMAT_NOT_SUPPORTED);
   if (pCreateInfo->mipLevels > 15)
      return vk_error(device, VK_ERROR_FEATURE_NOT_PRESENT);

   struct ghcivk_image *image =
      vk_image_create(&device->vk, pCreateInfo, pAllocator, sizeof(*image));
   if (!image)
      return vk_error(device, VK_ERROR_OUT_OF_HOST_MEMORY);

   image->tiled = pCreateInfo->tiling == VK_IMAGE_TILING_OPTIMAL;
   ghcivk_image_layout(image);

   *pImage = ghcivk_image_to_handle(image);
   return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_DestroyImage(VkDevice _device, VkImage _image,
                    const VkAllocationCallbacks *pAllocator)
{
   VK_FROM_HANDLE(ghcivk_device, device, _device);
   VK_FROM_HANDLE(ghcivk_image, image, _image);

   if (image)
      vk_image_destroy(&device->vk, pAllocator, &image->vk);
}

static void
ghcivk_fill_requirements(VkMemoryRequirements2 *req, uint64_t size,
                         uint64_t alignment)
{
   req->memoryRequirements = (VkMemoryRequirements) {
      .size = align64(size, alignment),
      .alignment = alignment,
      /* The one memory type (ghcivk_physical_device.c). */
      .memoryTypeBits = 1,
   };
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetImageMemoryRequirements2(VkDevice _device,
                                   const VkImageMemoryRequirementsInfo2 *pInfo,
                                   VkMemoryRequirements2 *pMemoryRequirements)
{
   VK_FROM_HANDLE(ghcivk_image, image, pInfo->image);

   ghcivk_fill_requirements(pMemoryRequirements, image->size,
                            GHCIVK_RESOURCE_ALIGN);
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetImageSubresourceLayout(VkDevice _device, VkImage _image,
                                 const VkImageSubresource *pSubresource,
                                 VkSubresourceLayout *pLayout)
{
   VK_FROM_HANDLE(ghcivk_image, image, _image);
   const struct ghcivk_image_level *lv =
      &image->levels[pSubresource->mipLevel];
   const VkExtent3D e =
      vk_image_mip_level_extent(&image->vk, pSubresource->mipLevel);

   *pLayout = (VkSubresourceLayout) {
      .offset = image->layer_stride * pSubresource->arrayLayer + lv->offset,
      .size = lv->slice_size * e.depth,
      .rowPitch = lv->row_pitch,
      .arrayPitch = image->layer_stride,
      .depthPitch = lv->slice_size,
   };
}

VKAPI_ATTR VkResult VKAPI_CALL
ghcivk_CreateBuffer(VkDevice _device, const VkBufferCreateInfo *pCreateInfo,
                    const VkAllocationCallbacks *pAllocator, VkBuffer *pBuffer)
{
   VK_FROM_HANDLE(ghcivk_device, device, _device);

   struct ghcivk_buffer *buffer =
      vk_buffer_create(&device->vk, pCreateInfo, pAllocator, sizeof(*buffer));
   if (!buffer)
      return vk_error(device, VK_ERROR_OUT_OF_HOST_MEMORY);

   *pBuffer = ghcivk_buffer_to_handle(buffer);
   return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_DestroyBuffer(VkDevice _device, VkBuffer _buffer,
                     const VkAllocationCallbacks *pAllocator)
{
   VK_FROM_HANDLE(ghcivk_device, device, _device);
   VK_FROM_HANDLE(ghcivk_buffer, buffer, _buffer);

   if (buffer)
      vk_buffer_destroy(&device->vk, pAllocator, &buffer->vk);
}

VKAPI_ATTR void VKAPI_CALL
ghcivk_GetBufferMemoryRequirements2(
   VkDevice _device, const VkBufferMemoryRequirementsInfo2 *pInfo,
   VkMemoryRequirements2 *pMemoryRequirements)
{
   VK_FROM_HANDLE(ghcivk_buffer, buffer, pInfo->buffer);

   /* 64 bytes: the uniform buffer offset alignment and the line size. */
   ghcivk_fill_requirements(pMemoryRequirements, MAX2(buffer->vk.size, 1),
                            64);
}
