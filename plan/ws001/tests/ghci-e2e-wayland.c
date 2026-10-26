/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The Wayland surface of libvulkan in the end-to-end test of the GHCI
 * driver: libvulkan's wsi-wayland.c needs the generated Keiland protocol
 * header, which a host build does not have, and the test draws offscreen.
 * These two entry points stand in for it and refuse.
 */

#include <stdint.h>
#include <vulkan/vulkan.h>

VKAPI_ATTR VkResult VKAPI_CALL vkCreateWaylandSurfaceKHR(VkInstance instance, const void *info, const VkAllocationCallbacks *allocator, VkSurfaceKHR *result);
VKAPI_ATTR VkBool32 VKAPI_CALL vkGetPhysicalDeviceWaylandPresentationSupportKHR(VkPhysicalDevice physical, uint32_t family, void *display);

/*
 * Refuses a Wayland surface: the test has no compositor.
 */
VKAPI_ATTR VkResult VKAPI_CALL
vkCreateWaylandSurfaceKHR(
	VkInstance instance,
	const void *info,
	const VkAllocationCallbacks *allocator,
	VkSurfaceKHR *result)
{
	(void)instance;
	(void)info;
	(void)allocator;
	(void)result;

	/* No Wayland surface. */
	return VK_ERROR_EXTENSION_NOT_PRESENT;
}

/*
 * Reports no Wayland presentation.
 */
VKAPI_ATTR VkBool32 VKAPI_CALL
vkGetPhysicalDeviceWaylandPresentationSupportKHR(
	VkPhysicalDevice physical,
	uint32_t family,
	void *display)
{
	(void)physical;
	(void)family;
	(void)display;

	/* None. */
	return VK_FALSE;
}
