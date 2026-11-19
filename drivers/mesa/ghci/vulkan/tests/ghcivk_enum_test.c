/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghcivk_enum_test: the GHCI Vulkan driver finds the drm-shim's GHCI device
 * and describes it from the shim's capability block.  The test loads the
 * driver itself (argv[1]) through the ICD interface, without the Vulkan
 * loader; it runs with the shim preloaded (meson.build).
 */

#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan_core.h>

static int failures;

#define CHECK(cond)                                                          \
   do {                                                                      \
      if (!(cond)) {                                                         \
         fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,   \
                 #cond);                                                     \
         failures++;                                                         \
      }                                                                      \
   } while (0)

int
main(int argc, char **argv)
{
   if (argc != 2) {
      fprintf(stderr, "usage: %s libvulkan_ghci.so\n", argv[0]);
      return 2;
   }

   void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
   if (!lib) {
      fprintf(stderr, "%s\n", dlerror());
      return 1;
   }
   PFN_vkGetInstanceProcAddr gipa =
      (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
   CHECK(gipa);
   if (!gipa)
      return 1;

#define GET(inst, name) PFN_vk##name name = (PFN_vk##name)gipa(inst, "vk" #name)
   GET(NULL, CreateInstance);
   VkInstance instance;
   const VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .apiVersion = VK_API_VERSION_1_0,
   };
   const VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkResult r = CreateInstance(&ici, NULL, &instance);
   CHECK(r == VK_SUCCESS);
   if (r != VK_SUCCESS)
      return 1;

   GET(instance, EnumeratePhysicalDevices);
   GET(instance, GetPhysicalDeviceProperties);
   GET(instance, GetPhysicalDeviceQueueFamilyProperties);
   GET(instance, GetPhysicalDeviceMemoryProperties);
   GET(instance, GetPhysicalDeviceFormatProperties);
   GET(instance, EnumerateDeviceExtensionProperties);
   GET(instance, CreateDevice);
   GET(instance, DestroyInstance);

   uint32_t count = 0;
   CHECK(EnumeratePhysicalDevices(instance, &count, NULL) == VK_SUCCESS);
   CHECK(count == 1);
   VkPhysicalDevice pdev;
   count = 1;
   CHECK(EnumeratePhysicalDevices(instance, &count, &pdev) == VK_SUCCESS);

   VkPhysicalDeviceProperties props;
   GetPhysicalDeviceProperties(pdev, &props);
   CHECK(props.vendorID == 0x10ee);
   CHECK(props.deviceID == 0x7024);
   CHECK(strcmp(props.deviceName, "GHCI GPU 10ee:7024") == 0);
   CHECK(props.limits.maxColorAttachments == 1);
   CHECK(props.limits.maxComputeSharedMemorySize == 16384);
   CHECK(props.limits.timestampPeriod == 10.0f);

   uint32_t qcount = 0;
   GetPhysicalDeviceQueueFamilyProperties(pdev, &qcount, NULL);
   CHECK(qcount == 1);
   VkQueueFamilyProperties qf;
   qcount = 1;
   GetPhysicalDeviceQueueFamilyProperties(pdev, &qcount, &qf);
   CHECK(qf.queueCount == 1);
   CHECK((qf.queueFlags & VK_QUEUE_GRAPHICS_BIT) &&
         (qf.queueFlags & VK_QUEUE_COMPUTE_BIT));

   VkPhysicalDeviceMemoryProperties mem;
   GetPhysicalDeviceMemoryProperties(pdev, &mem);
   CHECK(mem.memoryTypeCount == 1 && mem.memoryHeapCount == 1);
   CHECK(mem.memoryTypes[0].propertyFlags &
         VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

   VkFormatProperties fp;
   GetPhysicalDeviceFormatProperties(pdev, VK_FORMAT_B8G8R8A8_UNORM, &fp);
   CHECK(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT);
   CHECK(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_TRANSFER_DST_BIT);
   GetPhysicalDeviceFormatProperties(pdev, VK_FORMAT_R16G16_SFLOAT, &fp);
   CHECK(fp.optimalTilingFeatures == 0 && fp.bufferFeatures == 0);
   GetPhysicalDeviceFormatProperties(pdev, VK_FORMAT_R32G32B32A32_SFLOAT, &fp);
   CHECK(fp.bufferFeatures & VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT);

   uint32_t ecount = 0;
   EnumerateDeviceExtensionProperties(pdev, NULL, &ecount, NULL);
   VkExtensionProperties *ext = calloc(ecount, sizeof(*ext));
   EnumerateDeviceExtensionProperties(pdev, NULL, &ecount, ext);
   bool has_drm = false;
   for (uint32_t i = 0; i < ecount; i++)
      has_drm |= strcmp(ext[i].extensionName,
                        VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME) == 0;
   CHECK(has_drm);
   free(ext);

   const float prio = 1.0f;
   const VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   const VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
   };
   VkDevice device;
   r = CreateDevice(pdev, &dci, NULL, &device);
   CHECK(r == VK_SUCCESS);
   if (r == VK_SUCCESS) {
      PFN_vkGetDeviceProcAddr gdpa =
         (PFN_vkGetDeviceProcAddr)gipa(instance, "vkGetDeviceProcAddr");
      PFN_vkCreateImage CreateImage =
         (PFN_vkCreateImage)gdpa(device, "vkCreateImage");
      PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements =
         (PFN_vkGetImageMemoryRequirements)gdpa(device,
                                               "vkGetImageMemoryRequirements");
      PFN_vkDestroyImage DestroyImage =
         (PFN_vkDestroyImage)gdpa(device, "vkDestroyImage");
      PFN_vkDestroyDevice DestroyDevice =
         (PFN_vkDestroyDevice)gdpa(device, "vkDestroyDevice");

      /* A 100x20 BGRA8 tiled image: 13 tiles of 256 bytes a row (aligned
       * to 256), 3 rows of tiles: 13 * 256 * 3 = 9984 bytes, a page
       * aligned resource of 12288 bytes (ghci.md 8.5.2). */
      const VkImageCreateInfo ii = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
         .imageType = VK_IMAGE_TYPE_2D,
         .format = VK_FORMAT_B8G8R8A8_UNORM,
         .extent = { 100, 20, 1 },
         .mipLevels = 1,
         .arrayLayers = 1,
         .samples = VK_SAMPLE_COUNT_1_BIT,
         .tiling = VK_IMAGE_TILING_OPTIMAL,
         .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
      };
      VkImage image;
      CHECK(CreateImage(device, &ii, NULL, &image) == VK_SUCCESS);
      VkMemoryRequirements req;
      GetImageMemoryRequirements(device, image, &req);
      CHECK(req.size == 12288);
      CHECK(req.memoryTypeBits == 1);
      DestroyImage(device, image, NULL);
      DestroyDevice(device, NULL);
   }

   DestroyInstance(instance, NULL);
   if (failures)
      fprintf(stderr, "%d checks failed\n", failures);
   else
      printf("ok\n");
   return failures ? 1 : 0;
}
