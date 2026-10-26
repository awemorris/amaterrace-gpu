/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The end-to-end test of the GHCI driver: libvulkan's API, through the
 * driver's Vulkan executor and the CP firmware, to the RTL of the KC705's
 * GPU in Verilator (ghci-e2e.h).
 *
 *   ghci-e2e CASE...
 *
 * The cases, in the order given:
 *
 *   fill            vkCmdFillBuffer on device-local and host-visible
 *                   buffers, overlapping fills, read back by a copy
 *   copy            vkCmdCopyBuffer with several regions between
 *                   host-visible and device-local buffers
 *   compute=SPV     a compute pipeline of the module SPV (the test's
 *                   scale.comp) dispatched over 1024 invocations, its
 *                   storage buffer read back by a copy
 *   vkdemo=PPM      one frame of vkdemo's offscreen renderer (the
 *                   textured cuboid at 1000 ms), written to PPM for the
 *                   independent oracle
 *   display=PPM     that frame (the PPM the vkdemo case wrote) shown on
 *                   the display controller: a copied present of ordinary
 *                   storage, then a shared present of a blob of the
 *                   GPU's local memory (written by a transfer: GHCI
 *                   section 11.3 scans out local memory only),
 *                   each checked by FB_BASE, plane 0's flip record, the
 *                   scanned memory and the next frame's SCAN_SUM
 *
 * Every case prints "PASS e2e.<case>" or "FAIL e2e.<case>: ..." and its
 * GPU cycles, the firmware's packet cycles, the µop words and the round
 * trips the fake core measured; the run ends with "PASS ghci-e2e" when
 * every case passed.  vkdemo's pixels are judged by the oracle the
 * script runs (vkdemo_oracle.py), not here.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <uapi/gpu.h>
#include <uapi/gpu-display.h>
#include <vulkan/vulkan.h>

#include "ghci-e2e.h"
#include "link.h"
#include "renderer.h"

/* The bytes of the buffers of the transfer cases. */
#define TRANSFER_BYTES			65536U

/* The invocations of the compute case, and its workgroup's size (scale.comp's local_size_x). */
#define COMPUTE_COUNT			1024U
#define COMPUTE_GROUP			64U

/* The words the fills write. */
#define FILL_WHOLE			0x12345678U
#define FILL_PART			0xcafef00dU

/* The vkdemo frame's shader time. */
#define VKDEMO_TIME_MS			1000U

/* The display case's frame: vkdemo's, rows of 4-byte pixels without padding, and its RGB bytes in the PPM. */
#define DISPLAY_STRIDE			(VKDEMO_WIDTH * 4U)
#define DISPLAY_FRAME_BYTES		(DISPLAY_STRIDE * VKDEMO_HEIGHT)
#define DISPLAY_RGB_BYTES		(VKDEMO_WIDTH * VKDEMO_HEIGHT * 3U)

/* A flip record's bit 31: the flip was cancelled (GHCI section 13.2). */
#define DISPLAY_RECORD_CANCELLED	0x80000000U

/* How long the display case waits for the controller's frames, in nanoseconds of simulated time. */
#define DISPLAY_FRAMES_TIMEOUT_NS	1000000000ULL

/* Waits for a fence for at most this many nanoseconds of simulated time. */
#define FENCE_TIMEOUT_NS		60000000000ULL

/*
 * The Vulkan objects the transfer and compute cases share: the instance,
 * the device and its queue, a command pool with one buffer, and a fence.
 * Made by vulkan_open(), released by vulkan_close().
 */
struct vulkan {
	VkInstance instance;
	VkPhysicalDevice physical;
	VkPhysicalDeviceMemoryProperties memory;
	VkDevice device;
	VkQueue queue;
	uint32_t family;
	VkCommandPool pool;
	VkCommandBuffer commands;
	VkFence fence;
};

/* One buffer with its own memory, mapped when host-visible. */
struct buffer {
	VkBuffer buffer;
	VkDeviceMemory memory;
	void *mapped;
};

/*
 * The calls of vkQueueSubmit (libvulkan's, wrapped: __wrap_vkQueueSubmit)
 * and the GPU cycles they took to return, in total and the longest.
 */
struct submit_stats {
	uint64_t calls;
	uint64_t cycles;
	uint64_t cycles_max;
};

/* The counts of a case's start, which its report subtracts. */
struct measure {
	struct atg_link_stats link;
	struct e2e_core_stats core;
	struct submit_stats submit;
};

/* The count of the cases that failed, which decides the run's result. */
static unsigned cases_failed;

/* The vkQueueSubmit calls so far; the longest is reset at each case's start. */
static struct submit_stats submits;

VkResult __real_vkQueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo *submit, VkFence fence);
VkResult __wrap_vkQueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo *submit, VkFence fence);

static int vulkan_open(struct vulkan *vulkan);
static void vulkan_close(struct vulkan *vulkan);
static int buffer_make(struct vulkan *vulkan, VkDeviceSize bytes, VkBufferUsageFlags usage, int host, struct buffer *buffer);
static void buffer_drop(struct vulkan *vulkan, struct buffer *buffer);
static int record_begin(struct vulkan *vulkan);
static int record_submit(struct vulkan *vulkan);
static void barrier(struct vulkan *vulkan, VkAccessFlags source, VkAccessFlags destination, VkPipelineStageFlags source_stage, VkPipelineStageFlags destination_stage);
static int case_run(const char *name);
static int case_fill(void);
static int case_copy(void);
static int case_compute(const char *path);
static int case_vkdemo(const char *path);
static int case_display(const char *path);
static int display_frame_read(const char *path, uint8_t *rgb);
static uint32_t display_image(const uint8_t *rgb, int bgra, uint8_t *image);
static int display_run(int fd, const uint8_t *bgra, uint32_t bgra_sum, const uint8_t *rgba, uint32_t rgba_sum);
static int display_present(int fd, const struct gpu_display_info *query, uint64_t lease, uint64_t handle, uint32_t format, int blob, uint64_t *sequence);
static int display_check(const char *what, int fd, uint64_t lease, uint64_t sequence, const uint8_t *image, uint32_t blob_address, uint32_t sum, const struct e2e_display_state *before, struct e2e_display_state *after);
static void measure_start(struct measure *measure);
static void measure_report(const char *name, const struct measure *measure);
static uint32_t *module_read(const char *path, size_t *bytes);

/*
 * Runs the cases named on the command line on one start of the board.
 */
int
main(
	int argc,
	char **argv)
{
	struct measure measure;
	const char *name;
	int index;
	int error;

	/* Lines reach a log as they are printed: a run is long. */
	setvbuf(stdout, NULL, _IOLBF, 0);

	/* The board and the driver on it. */
	measure_start(&measure);
	error = e2e_board_start();
	if (error != 0) {
		printf("FAIL ghci-e2e: the board did not start\n");
		return 1;
	}
	measure_report("start", &measure);

	/* Each case in turn. */
	for (index = 1; index < argc; index++) {
		name = argv[index];
		measure_start(&measure);
		error = case_run(name);
		if (error != 0)
			cases_failed++;
		measure_report(name, &measure);
	}

	/* The detach and the end of the simulation, with the check of where the driver kept its memory. */
	error = e2e_board_stop();
	if (error != 0)
		cases_failed++;

	/* A failed case fails the run. */
	if (cases_failed != 0U) {
		printf("FAIL ghci-e2e: %u cases failed\n", cases_failed);
		return 1;
	}

	/* Succeeded: every case passed. */
	printf("PASS ghci-e2e\n");
	return 0;
}

/* Runs the case a command-line word names: 0 when it passed. */
static int
case_run(
	const char *name)
{
	int fill;
	int copy;
	int compute;
	int vkdemo;
	int display;
	int error;

	/* Which case the word names (a nonzero comparison: not that case). */
	fill = strcmp(name, "fill");
	copy = strcmp(name, "copy");
	compute = strncmp(name, "compute=", 8U);
	vkdemo = strncmp(name, "vkdemo=", 7U);
	display = strncmp(name, "display=", 8U);

	/* The case, with what follows its '=' when it takes a path. */
	if (fill == 0) {
		error = case_fill();
	} else if (copy == 0) {
		error = case_copy();
	} else if (compute == 0) {
		error = case_compute(name + 8);
	} else if (vkdemo == 0) {
		error = case_vkdemo(name + 7);
	} else if (display == 0) {
		error = case_display(name + 8);
	} else {
		printf("FAIL ghci-e2e: unknown case %s\n", name);
		error = 1;
	}

	/* A failed case. */
	if (error != 0)
		return 1;

	/* Succeeded: the case passed. */
	return 0;
}

/* Makes the instance, the device and its queue, the command buffer and the fence of the transfer cases. */
static int
vulkan_open(
	struct vulkan *vulkan)
{
	VkApplicationInfo application;
	VkInstanceCreateInfo instance_info;
	VkDeviceQueueCreateInfo queue_info;
	VkDeviceCreateInfo device_info;
	VkCommandPoolCreateInfo pool_info;
	VkCommandBufferAllocateInfo buffer_info;
	VkFenceCreateInfo fence_info;
	VkQueueFamilyProperties families[8];
	uint32_t count;
	float priority;
	VkResult status;

	memset(vulkan, 0, sizeof(*vulkan));

	/* A Vulkan 1.0 instance. */
	memset(&application, 0, sizeof(application));
	application.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
	application.pApplicationName = "ghci-e2e";
	application.apiVersion = VK_API_VERSION_1_0;
	memset(&instance_info, 0, sizeof(instance_info));
	instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	instance_info.pApplicationInfo = &application;
	status = vkCreateInstance(&instance_info, NULL, &vulkan->instance);
	if (status != VK_SUCCESS) {
		printf("  vkCreateInstance: %d\n", (int)status);
		return 1;
	}

	/* The GPU: the only physical device. */
	count = 1U;
	status = vkEnumeratePhysicalDevices(vulkan->instance, &count, &vulkan->physical);
	if ((status != VK_SUCCESS && status != VK_INCOMPLETE) || count == 0U) {
		printf("  vkEnumeratePhysicalDevices: %d, %u devices\n", (int)status, count);
		return 1;
	}
	vkGetPhysicalDeviceMemoryProperties(vulkan->physical, &vulkan->memory);

	/* A queue family with graphics, compute and transfer. */
	count = 8U;
	vkGetPhysicalDeviceQueueFamilyProperties(vulkan->physical, &count, families);
	for (vulkan->family = 0U; vulkan->family < count; vulkan->family++) {
		if ((families[vulkan->family].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) ==
		    (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))
			break;
	}
	if (vulkan->family == count) {
		printf("  no queue family with graphics and compute\n");
		return 1;
	}

	/* The device with one queue. */
	priority = 1.0f;
	memset(&queue_info, 0, sizeof(queue_info));
	queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
	queue_info.queueFamilyIndex = vulkan->family;
	queue_info.queueCount = 1U;
	queue_info.pQueuePriorities = &priority;
	memset(&device_info, 0, sizeof(device_info));
	device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
	device_info.queueCreateInfoCount = 1U;
	device_info.pQueueCreateInfos = &queue_info;
	status = vkCreateDevice(vulkan->physical, &device_info, NULL, &vulkan->device);
	if (status != VK_SUCCESS) {
		printf("  vkCreateDevice: %d\n", (int)status);
		return 1;
	}
	vkGetDeviceQueue(vulkan->device, vulkan->family, 0U, &vulkan->queue);

	/* The command pool and its buffer, recorded again by every submission. */
	memset(&pool_info, 0, sizeof(pool_info));
	pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
	pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
	pool_info.queueFamilyIndex = vulkan->family;
	status = vkCreateCommandPool(vulkan->device, &pool_info, NULL, &vulkan->pool);
	if (status != VK_SUCCESS) {
		printf("  vkCreateCommandPool: %d\n", (int)status);
		return 1;
	}
	memset(&buffer_info, 0, sizeof(buffer_info));
	buffer_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
	buffer_info.commandPool = vulkan->pool;
	buffer_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
	buffer_info.commandBufferCount = 1U;
	status = vkAllocateCommandBuffers(vulkan->device, &buffer_info, &vulkan->commands);
	if (status != VK_SUCCESS) {
		printf("  vkAllocateCommandBuffers: %d\n", (int)status);
		return 1;
	}

	/* The fence each submission signals. */
	memset(&fence_info, 0, sizeof(fence_info));
	fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
	status = vkCreateFence(vulkan->device, &fence_info, NULL, &vulkan->fence);
	if (status != VK_SUCCESS) {
		printf("  vkCreateFence: %d\n", (int)status);
		return 1;
	}

	/* Succeeded: the objects are made. */
	return 0;
}

/* Releases what vulkan_open() made, after the device is idle. */
static void
vulkan_close(
	struct vulkan *vulkan)
{
	/* The device's work, then its objects, then the device and the instance. */
	if (vulkan->device != VK_NULL_HANDLE) {
		(void)vkDeviceWaitIdle(vulkan->device);
		if (vulkan->fence != VK_NULL_HANDLE)
			vkDestroyFence(vulkan->device, vulkan->fence, NULL);
		if (vulkan->pool != VK_NULL_HANDLE)
			vkDestroyCommandPool(vulkan->device, vulkan->pool, NULL);
		vkDestroyDevice(vulkan->device, NULL);
	}
	if (vulkan->instance != VK_NULL_HANDLE)
		vkDestroyInstance(vulkan->instance, NULL);
	memset(vulkan, 0, sizeof(*vulkan));
}

/* Makes a buffer with its own memory: host-visible and coherent (mapped), or device-local. */
static int
buffer_make(
	struct vulkan *vulkan,
	VkDeviceSize bytes,
	VkBufferUsageFlags usage,
	int host,
	struct buffer *buffer)
{
	VkBufferCreateInfo buffer_info;
	VkMemoryAllocateInfo memory_info;
	VkMemoryRequirements requirements;
	VkMemoryPropertyFlags wanted;
	uint32_t type;
	VkResult status;

	memset(buffer, 0, sizeof(*buffer));

	/* The buffer. */
	memset(&buffer_info, 0, sizeof(buffer_info));
	buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
	buffer_info.size = bytes;
	buffer_info.usage = usage;
	buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
	status = vkCreateBuffer(vulkan->device, &buffer_info, NULL, &buffer->buffer);
	if (status != VK_SUCCESS) {
		printf("  vkCreateBuffer: %d\n", (int)status);
		return 1;
	}

	/* A memory type it may live in with the properties asked. */
	vkGetBufferMemoryRequirements(vulkan->device, buffer->buffer, &requirements);
	wanted = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
	if (host)
		wanted = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
	for (type = 0U; type < vulkan->memory.memoryTypeCount; type++) {
		if ((requirements.memoryTypeBits & (1U << type)) != 0U &&
		    (vulkan->memory.memoryTypes[type].propertyFlags & wanted) == wanted)
			break;
	}
	if (type == vulkan->memory.memoryTypeCount) {
		printf("  no memory type for the buffer\n");
		return 1;
	}

	/* The memory, bound, and mapped when the host sees it. */
	memset(&memory_info, 0, sizeof(memory_info));
	memory_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	memory_info.allocationSize = requirements.size;
	memory_info.memoryTypeIndex = type;
	status = vkAllocateMemory(vulkan->device, &memory_info, NULL, &buffer->memory);
	if (status != VK_SUCCESS) {
		printf("  vkAllocateMemory: %d\n", (int)status);
		return 1;
	}
	status = vkBindBufferMemory(vulkan->device, buffer->buffer, buffer->memory, 0U);
	if (status != VK_SUCCESS) {
		printf("  vkBindBufferMemory: %d\n", (int)status);
		return 1;
	}
	if (host) {
		status = vkMapMemory(vulkan->device, buffer->memory, 0U, VK_WHOLE_SIZE, 0U, &buffer->mapped);
		if (status != VK_SUCCESS) {
			printf("  vkMapMemory: %d\n", (int)status);
			return 1;
		}
	}

	/* Succeeded: the buffer is bound. */
	return 0;
}

/* Releases a buffer and its memory. */
static void
buffer_drop(
	struct vulkan *vulkan,
	struct buffer *buffer)
{
	/* The buffer before its memory. */
	if (buffer->buffer != VK_NULL_HANDLE)
		vkDestroyBuffer(vulkan->device, buffer->buffer, NULL);
	if (buffer->memory != VK_NULL_HANDLE)
		vkFreeMemory(vulkan->device, buffer->memory, NULL);
	memset(buffer, 0, sizeof(*buffer));
}

/* Starts recording the command buffer for one submission. */
static int
record_begin(
	struct vulkan *vulkan)
{
	VkCommandBufferBeginInfo begin;
	VkResult status;

	/* One submission, then the buffer is recorded again. */
	memset(&begin, 0, sizeof(begin));
	begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
	begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
	status = vkBeginCommandBuffer(vulkan->commands, &begin);
	if (status != VK_SUCCESS) {
		printf("  vkBeginCommandBuffer: %d\n", (int)status);
		return 1;
	}

	/* Succeeded: recording. */
	return 0;
}

/* Ends the recording, submits it with the fence and waits for the fence. */
static int
record_submit(
	struct vulkan *vulkan)
{
	VkSubmitInfo submit;
	VkResult status;

	/* The end of the recording. */
	status = vkEndCommandBuffer(vulkan->commands);
	if (status != VK_SUCCESS) {
		printf("  vkEndCommandBuffer: %d\n", (int)status);
		return 1;
	}

	/* The submission, with the fence. */
	memset(&submit, 0, sizeof(submit));
	submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
	submit.commandBufferCount = 1U;
	submit.pCommandBuffers = &vulkan->commands;
	status = vkQueueSubmit(vulkan->queue, 1U, &submit, vulkan->fence);
	if (status != VK_SUCCESS) {
		printf("  vkQueueSubmit: %d\n", (int)status);
		return 1;
	}

	/* The work is done when the fence is signaled. */
	status = vkWaitForFences(vulkan->device, 1U, &vulkan->fence, VK_TRUE, FENCE_TIMEOUT_NS);
	if (status != VK_SUCCESS) {
		printf("  vkWaitForFences: %d\n", (int)status);
		return 1;
	}
	status = vkResetFences(vulkan->device, 1U, &vulkan->fence);
	if (status != VK_SUCCESS) {
		printf("  vkResetFences: %d\n", (int)status);
		return 1;
	}
	status = vkResetCommandBuffer(vulkan->commands, 0U);
	if (status != VK_SUCCESS) {
		printf("  vkResetCommandBuffer: %d\n", (int)status);
		return 1;
	}

	/* Succeeded: the submission's work is done. */
	return 0;
}

/* Records a global memory barrier between two stages. */
static void
barrier(
	struct vulkan *vulkan,
	VkAccessFlags source,
	VkAccessFlags destination,
	VkPipelineStageFlags source_stage,
	VkPipelineStageFlags destination_stage)
{
	VkMemoryBarrier memory;

	/* What the earlier commands wrote is visible to the later ones. */
	memset(&memory, 0, sizeof(memory));
	memory.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
	memory.srcAccessMask = source;
	memory.dstAccessMask = destination;
	vkCmdPipelineBarrier(vulkan->commands, source_stage, destination_stage, 0U, 1U, &memory, 0U, NULL, 0U, NULL);
}

/*
 * Fills a device-local buffer whole, then a part of it again, and a
 * host-visible buffer directly; copies the device-local one out and
 * compares both with what the fills wrote.
 */
static int
case_fill(void)
{
	struct vulkan vulkan;
	struct buffer local;
	struct buffer host;
	struct buffer readback;
	const uint32_t *words;
	uint32_t expected;
	unsigned index;
	unsigned wrong;
	int error;
	VkBufferCopy region;

	/* The device and three buffers. */
	error = vulkan_open(&vulkan);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, 0, &local);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, 1, &host);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, 1, &readback);
	if (error != 0) {
		printf("FAIL e2e.fill: the objects\n");
		vulkan_close(&vulkan);
		return 1;
	}
	memset(host.mapped, 0xa5, TRANSFER_BYTES);
	memset(readback.mapped, 0xa5, TRANSFER_BYTES);

	/*
	 * The fills: the device-local buffer whole, then its second 4 KiB
	 * again; the host-visible one from 1 KiB to its end; then the copy of
	 * the device-local one to the readback buffer.
	 */
	error = record_begin(&vulkan);
	if (error == 0) {
		vkCmdFillBuffer(vulkan.commands, local.buffer, 0U, VK_WHOLE_SIZE, FILL_WHOLE);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		vkCmdFillBuffer(vulkan.commands, local.buffer, 4096U, 4096U, FILL_PART);
		vkCmdFillBuffer(vulkan.commands, host.buffer, 1024U, TRANSFER_BYTES - 1024U, FILL_PART);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		region.srcOffset = 0U;
		region.dstOffset = 0U;
		region.size = TRANSFER_BYTES;
		vkCmdCopyBuffer(vulkan.commands, local.buffer, readback.buffer, 1U, &region);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT);
		error = record_submit(&vulkan);
	}
	if (error != 0) {
		printf("FAIL e2e.fill: the submission\n");
		vulkan_close(&vulkan);
		return 1;
	}

	/* The device-local buffer as the copy read it: the whole fill, its second 4 KiB filled again. */
	wrong = 0U;
	words = readback.mapped;
	for (index = 0U; index < TRANSFER_BYTES / 4U; index++) {
		expected = FILL_WHOLE;
		if (index >= 1024U && index < 2048U)
			expected = FILL_PART;
		if (words[index] != expected) {
			if (wrong < 4U)
				printf("  device-local word %u: %08x, expected %08x\n", index, words[index], expected);
			wrong++;
		}
	}

	/* The host-visible buffer: its first 1 KiB as the host left it, the rest filled. */
	words = host.mapped;
	for (index = 0U; index < TRANSFER_BYTES / 4U; index++) {
		expected = FILL_PART;
		if (index < 256U)
			expected = 0xa5a5a5a5U;
		if (words[index] != expected) {
			if (wrong < 8U)
				printf("  host-visible word %u: %08x, expected %08x\n", index, words[index], expected);
			wrong++;
		}
	}

	/* The objects go. */
	buffer_drop(&vulkan, &readback);
	buffer_drop(&vulkan, &host);
	buffer_drop(&vulkan, &local);
	vulkan_close(&vulkan);

	/* Every word as the fills wrote it. */
	if (wrong != 0U) {
		printf("FAIL e2e.fill: %u words differ\n", wrong);
		return 1;
	}

	/* Succeeded: the fills are right. */
	printf("PASS e2e.fill: %u words\n", 2U * TRANSFER_BYTES / 4U);
	return 0;
}

/*
 * Copies a host-visible pattern into a device-local buffer in three
 * regions (the second overlapping none, the third at an odd word), then
 * the device-local buffer back out in two regions, and compares.
 */
static int
case_copy(void)
{
	struct vulkan vulkan;
	struct buffer source;
	struct buffer local;
	struct buffer readback;
	VkBufferCopy into[3];
	VkBufferCopy out[2];
	uint32_t *pattern;
	uint32_t *words;
	uint32_t expected[TRANSFER_BYTES / 4U];
	unsigned index;
	unsigned region;
	unsigned wrong;
	int error;

	/* The device and three buffers. */
	error = vulkan_open(&vulkan);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, 1, &source);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, 0, &local);
	if (error == 0)
		error = buffer_make(&vulkan, TRANSFER_BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, 1, &readback);
	if (error != 0) {
		printf("FAIL e2e.copy: the objects\n");
		vulkan_close(&vulkan);
		return 1;
	}

	/* The pattern: every word different. */
	pattern = source.mapped;
	for (index = 0U; index < TRANSFER_BYTES / 4U; index++)
		pattern[index] = 0x9e3779b9U * (index + 1U);
	memset(readback.mapped, 0, TRANSFER_BYTES);

	/* The regions in: [0, 8 KiB) to 16 KiB, [8 KiB, 12 KiB) to 0, 100 words from word 5001 to word 3. */
	into[0].srcOffset = 0U;
	into[0].dstOffset = 16384U;
	into[0].size = 8192U;
	into[1].srcOffset = 8192U;
	into[1].dstOffset = 0U;
	into[1].size = 4096U;
	into[2].srcOffset = 4U * 5001U;
	into[2].dstOffset = 4U * 3U;
	into[2].size = 4U * 100U;

	/* The regions out: [0, 16 KiB) and [16 KiB, 32 KiB), swapped. */
	out[0].srcOffset = 0U;
	out[0].dstOffset = 16384U;
	out[0].size = 16384U;
	out[1].srcOffset = 16384U;
	out[1].dstOffset = 0U;
	out[1].size = 16384U;

	/* The device-local buffer starts as zeros, then the copies in, then the copies out. */
	error = record_begin(&vulkan);
	if (error == 0) {
		vkCmdFillBuffer(vulkan.commands, local.buffer, 0U, VK_WHOLE_SIZE, 0U);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		vkCmdCopyBuffer(vulkan.commands, source.buffer, local.buffer, 3U, into);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		vkCmdCopyBuffer(vulkan.commands, local.buffer, readback.buffer, 2U, out);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT);
		error = record_submit(&vulkan);
	}
	if (error != 0) {
		printf("FAIL e2e.copy: the submission\n");
		vulkan_close(&vulkan);
		return 1;
	}

	/* What the device-local buffer holds after the copies in, by the same regions on the host. */
	memset(expected, 0, sizeof(expected));
	for (region = 0U; region < 3U; region++)
		memcpy((uint8_t *)expected + into[region].dstOffset, (uint8_t *)pattern + into[region].srcOffset, into[region].size);

	/* The readback against it, through the swapped regions out. */
	wrong = 0U;
	words = readback.mapped;
	for (index = 0U; index < 8192U; index++) {
		if (words[index] != expected[(index + 4096U) % 8192U]) {
			if (wrong < 4U)
				printf("  readback word %u: %08x, expected %08x\n", index, words[index], expected[(index + 4096U) % 8192U]);
			wrong++;
		}
	}
	for (index = 8192U; index < TRANSFER_BYTES / 4U; index++) {
		if (words[index] != 0U) {
			if (wrong < 4U)
				printf("  readback word %u past the regions: %08x\n", index, words[index]);
			wrong++;
		}
	}

	/* The objects go. */
	buffer_drop(&vulkan, &readback);
	buffer_drop(&vulkan, &local);
	buffer_drop(&vulkan, &source);
	vulkan_close(&vulkan);

	/* Every word as the copies put it. */
	if (wrong != 0U) {
		printf("FAIL e2e.copy: %u words differ\n", wrong);
		return 1;
	}

	/* Succeeded: the copies are right. */
	printf("PASS e2e.copy: %u words\n", TRANSFER_BYTES / 4U);
	return 0;
}

/*
 * Dispatches scale.comp over COMPUTE_COUNT invocations: out[i] =
 * in[i] * 3 + (i ^ 0x5a), the input host-visible, the output
 * device-local and copied out.
 */
static int
case_compute(
	const char *path)
{
	struct vulkan vulkan;
	struct buffer input;
	struct buffer output;
	struct buffer readback;
	VkShaderModuleCreateInfo module_info;
	VkDescriptorSetLayoutBinding bindings[2];
	VkDescriptorSetLayoutCreateInfo set_layout_info;
	VkPipelineLayoutCreateInfo layout_info;
	VkComputePipelineCreateInfo pipeline_info;
	VkDescriptorPoolSize pool_size;
	VkDescriptorPoolCreateInfo pool_info;
	VkDescriptorSetAllocateInfo set_info;
	VkDescriptorBufferInfo buffer_infos[2];
	VkWriteDescriptorSet writes[2];
	VkShaderModule module;
	VkDescriptorSetLayout set_layout;
	VkPipelineLayout layout;
	VkPipeline pipeline;
	VkDescriptorPool pool;
	VkDescriptorSet set;
	VkBufferCopy region;
	VkResult status;
	uint32_t *code;
	uint32_t *values;
	uint32_t *words;
	uint32_t expected;
	size_t code_bytes;
	unsigned index;
	unsigned wrong;
	int error;

	/* The module's SPIR-V. */
	code = module_read(path, &code_bytes);
	if (code == NULL) {
		printf("FAIL e2e.compute: no module %s\n", path);
		return 1;
	}

	/* The device and the buffers. */
	error = vulkan_open(&vulkan);
	if (error == 0)
		error = buffer_make(&vulkan, 4U * COMPUTE_COUNT, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, 1, &input);
	if (error == 0)
		error = buffer_make(&vulkan, 4U * COMPUTE_COUNT, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT, 0, &output);
	if (error == 0)
		error = buffer_make(&vulkan, 4U * COMPUTE_COUNT, VK_BUFFER_USAGE_TRANSFER_DST_BIT, 1, &readback);
	if (error != 0) {
		printf("FAIL e2e.compute: the buffers\n");
		vulkan_close(&vulkan);
		free(code);
		return 1;
	}
	values = input.mapped;
	for (index = 0U; index < COMPUTE_COUNT; index++)
		values[index] = 7U * index + 11U;
	memset(readback.mapped, 0, 4U * COMPUTE_COUNT);

	/* The module, the layouts and the pipeline: binding 0 the input, binding 1 the output. */
	memset(&module_info, 0, sizeof(module_info));
	module_info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
	module_info.codeSize = code_bytes;
	module_info.pCode = code;
	status = vkCreateShaderModule(vulkan.device, &module_info, NULL, &module);
	free(code);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkCreateShaderModule %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}
	memset(bindings, 0, sizeof(bindings));
	for (index = 0U; index < 2U; index++) {
		bindings[index].binding = index;
		bindings[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		bindings[index].descriptorCount = 1U;
		bindings[index].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
	}
	memset(&set_layout_info, 0, sizeof(set_layout_info));
	set_layout_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
	set_layout_info.bindingCount = 2U;
	set_layout_info.pBindings = bindings;
	status = vkCreateDescriptorSetLayout(vulkan.device, &set_layout_info, NULL, &set_layout);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkCreateDescriptorSetLayout %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}
	memset(&layout_info, 0, sizeof(layout_info));
	layout_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
	layout_info.setLayoutCount = 1U;
	layout_info.pSetLayouts = &set_layout;
	status = vkCreatePipelineLayout(vulkan.device, &layout_info, NULL, &layout);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkCreatePipelineLayout %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}
	memset(&pipeline_info, 0, sizeof(pipeline_info));
	pipeline_info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
	pipeline_info.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
	pipeline_info.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
	pipeline_info.stage.module = module;
	pipeline_info.stage.pName = "main";
	pipeline_info.layout = layout;
	status = vkCreateComputePipelines(vulkan.device, VK_NULL_HANDLE, 1U, &pipeline_info, NULL, &pipeline);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkCreateComputePipelines %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}

	/* The descriptor set naming the two buffers. */
	pool_size.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
	pool_size.descriptorCount = 2U;
	memset(&pool_info, 0, sizeof(pool_info));
	pool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
	pool_info.maxSets = 1U;
	pool_info.poolSizeCount = 1U;
	pool_info.pPoolSizes = &pool_size;
	status = vkCreateDescriptorPool(vulkan.device, &pool_info, NULL, &pool);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkCreateDescriptorPool %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}
	memset(&set_info, 0, sizeof(set_info));
	set_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
	set_info.descriptorPool = pool;
	set_info.descriptorSetCount = 1U;
	set_info.pSetLayouts = &set_layout;
	status = vkAllocateDescriptorSets(vulkan.device, &set_info, &set);
	if (status != VK_SUCCESS) {
		printf("FAIL e2e.compute: vkAllocateDescriptorSets %d\n", (int)status);
		vulkan_close(&vulkan);
		return 1;
	}
	buffer_infos[0].buffer = input.buffer;
	buffer_infos[1].buffer = output.buffer;
	memset(writes, 0, sizeof(writes));
	for (index = 0U; index < 2U; index++) {
		buffer_infos[index].offset = 0U;
		buffer_infos[index].range = VK_WHOLE_SIZE;
		writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
		writes[index].dstSet = set;
		writes[index].dstBinding = index;
		writes[index].descriptorCount = 1U;
		writes[index].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		writes[index].pBufferInfo = &buffer_infos[index];
	}
	vkUpdateDescriptorSets(vulkan.device, 2U, writes, 0U, NULL);

	/* The dispatch, then the copy of the output to the readback buffer. */
	error = record_begin(&vulkan);
	if (error == 0) {
		barrier(&vulkan, VK_ACCESS_HOST_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
		vkCmdBindPipeline(vulkan.commands, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
		vkCmdBindDescriptorSets(vulkan.commands, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0U, 1U, &set, 0U, NULL);
		vkCmdDispatch(vulkan.commands, COMPUTE_COUNT / COMPUTE_GROUP, 1U, 1U);
		barrier(&vulkan, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
		region.srcOffset = 0U;
		region.dstOffset = 0U;
		region.size = 4U * COMPUTE_COUNT;
		vkCmdCopyBuffer(vulkan.commands, output.buffer, readback.buffer, 1U, &region);
		barrier(&vulkan, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT);
		error = record_submit(&vulkan);
	}

	/* Every invocation's word. */
	wrong = 0U;
	words = readback.mapped;
	for (index = 0U; error == 0 && index < COMPUTE_COUNT; index++) {
		expected = values[index] * 3U + (index ^ 0x5aU);
		if (words[index] != expected) {
			if (wrong < 4U)
				printf("  word %u: %08x, expected %08x\n", index, words[index], expected);
			wrong++;
		}
	}

	/* The objects go. */
	vkDestroyPipeline(vulkan.device, pipeline, NULL);
	vkDestroyDescriptorPool(vulkan.device, pool, NULL);
	vkDestroyPipelineLayout(vulkan.device, layout, NULL);
	vkDestroyDescriptorSetLayout(vulkan.device, set_layout, NULL);
	vkDestroyShaderModule(vulkan.device, module, NULL);
	buffer_drop(&vulkan, &readback);
	buffer_drop(&vulkan, &output);
	buffer_drop(&vulkan, &input);
	vulkan_close(&vulkan);

	/* The submission ran, and every word is the module's. */
	if (error != 0) {
		printf("FAIL e2e.compute: the submission\n");
		return 1;
	}
	if (wrong != 0U) {
		printf("FAIL e2e.compute: %u words differ\n", wrong);
		return 1;
	}

	/* Succeeded: the dispatch is right. */
	printf("PASS e2e.compute: %u invocations\n", COMPUTE_COUNT);
	return 0;
}

/*
 * Renders one frame of vkdemo's offscreen renderer and writes it out; the
 * script's oracle judges the pixels.
 */
static int
case_vkdemo(
	const char *path)
{
	struct measure frame;
	char digest[65];
	int error;

	/* The renderer's objects: the device, the texture's upload, the pipeline. */
	error = vkdemo_initialize(0U, 1, 1);
	if (error != 0) {
		printf("FAIL e2e.vkdemo: initialization at %s (%d)\n", vkdemo_error_operation(), (int)vkdemo_error_code());
		(void)vkdemo_close();
		return 1;
	}

	/* One frame: the recording, the submission, the wait and the readback. */
	measure_start(&frame);
	error = vkdemo_render(VKDEMO_TIME_MS, 1U, digest);
	measure_report("vkdemo frame", &frame);
	if (error != 0) {
		printf("FAIL e2e.vkdemo: the frame at %s (%d)\n", vkdemo_error_operation(), (int)vkdemo_error_code());
		(void)vkdemo_close();
		return 1;
	}

	/* The frame for the oracle. */
	error = vkdemo_write_frame(path);
	if (error != 0) {
		printf("FAIL e2e.vkdemo: the frame could not be written to %s\n", path);
		(void)vkdemo_close();
		return 1;
	}

	/* The renderer's objects go. */
	error = vkdemo_close();
	if (error != 0) {
		printf("FAIL e2e.vkdemo: the close at %s (%d)\n", vkdemo_error_operation(), (int)vkdemo_error_code());
		return 1;
	}

	/* Succeeded: the frame is written (the oracle decides). */
	printf("PASS e2e.vkdemo: frame %s sha256 %s\n", path, digest);
	return 0;
}

/*
 * Shows vkdemo's frame (the PPM the vkdemo case wrote) on the display:
 * a present of ordinary storage, which the blitter copies into a frame of
 * the driver's, then one of a blob of local memory (written by a
 * transfer), which the controller scans where it is, each checked against
 * the image (display_run).
 */
static int
case_display(
	const char *path)
{
	uint8_t *rgb;
	uint8_t *bgra;
	uint8_t *rgba;
	uint32_t bgra_sum;
	uint32_t rgba_sum;
	int fd;
	int error;

	/* The frame's pixels and the two images made of them. */
	rgb = malloc(DISPLAY_RGB_BYTES);
	bgra = malloc(DISPLAY_FRAME_BYTES);
	rgba = malloc(DISPLAY_FRAME_BYTES);
	error = 0;
	if (rgb == NULL)
		error = 1;
	if (bgra == NULL)
		error = 1;
	if (rgba == NULL)
		error = 1;
	if (error != 0) {
		printf("FAIL e2e.display: no memory for the images\n");
		free(rgb);
		free(bgra);
		free(rgba);
		return 1;
	}

	/* vkdemo's frame, as BGRA (the copied present) and RGBA (the blob) words with their sums. */
	error = display_frame_read(path, rgb);
	if (error != 0) {
		printf("FAIL e2e.display: vkdemo's frame %s could not be read (the vkdemo case runs first)\n", path);
		free(rgb);
		free(bgra);
		free(rgba);
		return 1;
	}
	bgra_sum = display_image(rgb, 1, bgra);
	rgba_sum = display_image(rgb, 0, rgba);
	free(rgb);

	/* An open of the node, as a compositor's. */
	fd = open("/dev/gpu0", O_RDWR);
	if (fd < 0) {
		printf("FAIL e2e.display: the node could not be opened (%d)\n", errno);
		free(bgra);
		free(rgba);
		return 1;
	}

	/* The lease, the two presents and the release. */
	error = display_run(fd, bgra, bgra_sum, rgba, rgba_sum);

	/* The open goes; the close ends a lease a failure left and destroys the resources. */
	(void)close(fd);
	free(bgra);
	free(rgba);

	/* A failed step (it printed why). */
	if (error != 0)
		return 1;

	/* Succeeded: both presents were shown as they were written. */
	printf("PASS e2e.display: a copied and a shared present of vkdemo's frame (FB_BASE, records, SCAN_SUM)\n");
	return 0;
}

/*
 * Reads vkdemo's frame from its PPM: 320 x 240 RGB bytes.  Returns 0, or
 * 1 when the file is not that.
 */
static int
display_frame_read(
	const char *path,
	uint8_t *rgb)
{
	FILE *file;
	unsigned width;
	unsigned height;
	unsigned maximum;
	size_t got;
	int fields;
	int separator;

	/* The file. */
	file = fopen(path, "rb");
	if (file == NULL)
		return 1;

	/* The header: P6, the size, the largest value, one whitespace byte. */
	fields = fscanf(file, "P6 %u %u %u", &width, &height, &maximum);
	separator = fgetc(file);
	if (fields != 3) {
		(void)fclose(file);
		return 1;
	}
	if (width != VKDEMO_WIDTH) {
		(void)fclose(file);
		return 1;
	}
	if (height != VKDEMO_HEIGHT) {
		(void)fclose(file);
		return 1;
	}
	if (maximum != 255U) {
		(void)fclose(file);
		return 1;
	}
	if (separator == EOF) {
		(void)fclose(file);
		return 1;
	}

	/* The pixels. */
	got = fread(rgb, 1U, DISPLAY_RGB_BYTES, file);
	(void)fclose(file);
	if (got != DISPLAY_RGB_BYTES)
		return 1;

	/* Succeeded: the frame's pixels. */
	return 0;
}

/*
 * Makes an image of the frame's pixels, opaque, in BGRA (bgra nonzero) or
 * RGBA byte order, rows of DISPLAY_STRIDE bytes; reports the 32-bit sum of
 * its little-endian pixel words, as the controller's SCAN_SUM sums a frame.
 */
static uint32_t
display_image(
	const uint8_t *rgb,
	int bgra,
	uint8_t *image)
{
	const uint8_t *source;
	uint8_t *target;
	uint32_t sum;
	uint32_t word;
	uint32_t index;

	/* Every pixel in order, its word added to the sum. */
	sum = 0U;
	for (index = 0U; index < VKDEMO_WIDTH * VKDEMO_HEIGHT; index++) {
		source = &rgb[index * 3U];
		target = &image[index * 4U];
		if (bgra) {
			target[0] = source[2];
			target[2] = source[0];
		} else {
			target[0] = source[0];
			target[2] = source[2];
		}
		target[1] = source[1];
		target[3] = 0xffU;
		word = (uint32_t)target[0];
		word |= (uint32_t)target[1] << 8;
		word |= (uint32_t)target[2] << 16;
		word |= (uint32_t)target[3] << 24;
		sum += word;
	}

	/* Succeeded: the image is made. */
	return sum;
}

/*
 * The display case's steps on an open of the node: the output and its one
 * mode, the claim, the copied present and its check, the blob (local
 * memory, written by a transfer) and its shared present and check, the
 * release.  Returns
 * 0, or 1 after printing the step that failed.
 */
static int
display_run(
	int fd,
	const uint8_t *bgra,
	uint32_t bgra_sum,
	const uint8_t *rgba,
	uint32_t rgba_sum)
{
	struct gpu_display_info query;
	struct gpu_display_mode mode;
	struct gpu_display_claim claim;
	struct gpu_display_release release;
	struct gpu_display_wait wait;
	struct gpu_resource_create storage;
	struct gpu_blob_create blob;
	struct gpu_transfer transfer;
	struct e2e_display_state before;
	struct e2e_display_state after;
	uint64_t sequence;
	int error;

	/* The one output: connected, with blobs, its preferred mode vkdemo's frame (the simulated controller's test mode). */
	memset(&query, 0, sizeof(query));
	query.version = GPU_ABI_VERSION;
	query.size = sizeof(query);
	query.index = 0U;
	error = ioctl(fd, GPU_DISPLAY_QUERY, &query);
	if (error != 0) {
		printf("FAIL e2e.display: the query (%d)\n", errno);
		return 1;
	}
	printf("  e2e.display: output %u, generation %llu, %ux%u at %u mHz, flags %08x\n", (unsigned)query.display_id,
	    (unsigned long long)query.generation, (unsigned)query.preferred_width, (unsigned)query.preferred_height,
	    (unsigned)query.refresh_millihz, (unsigned)query.flags);
	if ((query.flags & GPU_DISPLAY_CONNECTED) == 0U) {
		printf("FAIL e2e.display: the output is not connected\n");
		return 1;
	}
	if ((query.flags & GPU_DISPLAY_BLOB) == 0U) {
		printf("FAIL e2e.display: the output takes no blob\n");
		return 1;
	}
	if (query.preferred_width != VKDEMO_WIDTH) {
		printf("FAIL e2e.display: the preferred mode is not vkdemo's frame\n");
		return 1;
	}
	if (query.preferred_height != VKDEMO_HEIGHT) {
		printf("FAIL e2e.display: the preferred mode is not vkdemo's frame\n");
		return 1;
	}

	/* The controller names one mode, the frame's. */
	memset(&mode, 0, sizeof(mode));
	mode.version = GPU_ABI_VERSION;
	mode.size = sizeof(mode);
	mode.display_id = query.display_id;
	mode.operation = GPU_DISPLAY_MODE_ENUMERATE;
	mode.generation = query.generation;
	mode.index = 0U;
	error = ioctl(fd, GPU_DISPLAY_MODE, &mode);
	if (error != 0) {
		printf("FAIL e2e.display: the mode enumeration (%d)\n", errno);
		return 1;
	}
	if (mode.count != 1U) {
		printf("FAIL e2e.display: %u modes, not the test mode alone\n", (unsigned)mode.count);
		return 1;
	}
	if (mode.width != VKDEMO_WIDTH) {
		printf("FAIL e2e.display: mode 0 is %ux%u\n", (unsigned)mode.width, (unsigned)mode.height);
		return 1;
	}
	if (mode.height != VKDEMO_HEIGHT) {
		printf("FAIL e2e.display: mode 0 is %ux%u\n", (unsigned)mode.width, (unsigned)mode.height);
		return 1;
	}

	/* The lease on plane 0. */
	memset(&claim, 0, sizeof(claim));
	claim.version = GPU_ABI_VERSION;
	claim.size = sizeof(claim);
	claim.display_id = query.display_id;
	claim.plane_index = 0U;
	claim.generation = query.generation;
	error = ioctl(fd, GPU_DISPLAY_CLAIM, &claim);
	if (error != 0) {
		printf("FAIL e2e.display: the claim (%d)\n", errno);
		return 1;
	}

	/* Ordinary storage holding the BGRA image. */
	memset(&storage, 0, sizeof(storage));
	storage.version = GPU_ABI_VERSION;
	storage.size = sizeof(storage);
	storage.bytes = DISPLAY_FRAME_BYTES;
	storage.usage = GPU_RESOURCE_USAGE_STORAGE;
	error = ioctl(fd, GPU_RESOURCE_CREATE, &storage);
	if (error != 0) {
		printf("FAIL e2e.display: the storage (%d)\n", errno);
		return 1;
	}
	memset(&transfer, 0, sizeof(transfer));
	transfer.version = GPU_ABI_VERSION;
	transfer.size = sizeof(transfer);
	transfer.handle = storage.handle;
	transfer.offset = 0U;
	transfer.address = (uint64_t)(uintptr_t)bgra;
	transfer.bytes = DISPLAY_FRAME_BYTES;
	error = ioctl(fd, GPU_RESOURCE_WRITE, &transfer);
	if (error != 0) {
		printf("FAIL e2e.display: the storage's write (%d)\n", errno);
		return 1;
	}

	/* The copied present lights the controller and returns once adopted. */
	e2e_display_state(&before);
	error = display_present(fd, &query, claim.lease, storage.handle, GPU_PIXEL_BGRA8888, 0, &sequence);
	if (error != 0) {
		printf("FAIL e2e.display: the copied present (%d)\n", error);
		return 1;
	}
	error = display_check("copied", fd, claim.lease, sequence, bgra, 0U, bgra_sum, &before, &after);
	if (error != 0)
		return 1;

	/*
	 * A blob of the GPU's own (local) memory holding the RGBA image,
	 * written by a transfer (the driver's copy through host memory): the
	 * controller scans local memory only (GHCI section 11.3).
	 */
	memset(&blob, 0, sizeof(blob));
	blob.version = GPU_ABI_VERSION;
	blob.size = sizeof(blob);
	blob.bytes = DISPLAY_FRAME_BYTES;
	blob.flags = 0U;
	error = ioctl(fd, GPU_BLOB_CREATE, &blob);
	if (error != 0) {
		printf("FAIL e2e.display: the blob (%d)\n", errno);
		return 1;
	}
	memset(&transfer, 0, sizeof(transfer));
	transfer.version = GPU_ABI_VERSION;
	transfer.size = sizeof(transfer);
	transfer.handle = blob.handle;
	transfer.offset = 0U;
	transfer.address = (uint64_t)(uintptr_t)rgba;
	transfer.bytes = DISPLAY_FRAME_BYTES;
	error = ioctl(fd, GPU_RESOURCE_WRITE, &transfer);
	if (error != 0) {
		printf("FAIL e2e.display: the blob's write (%d)\n", errno);
		return 1;
	}

	/* The shared present: the controller flips to the blob where it is. */
	before = after;
	error = display_present(fd, &query, claim.lease, blob.handle, GPU_PIXEL_RGBA8888, 1, &sequence);
	if (error != 0) {
		printf("FAIL e2e.display: the shared present (%d)\n", error);
		return 1;
	}
	error = display_check("shared", fd, claim.lease, sequence, rgba, blob.resource_id, rgba_sum, &before, &after);
	if (error != 0)
		return 1;

	/* The release turns the controller dark and lets the blob go before it returns. */
	memset(&release, 0, sizeof(release));
	release.version = GPU_ABI_VERSION;
	release.size = sizeof(release);
	release.lease = claim.lease;
	error = ioctl(fd, GPU_DISPLAY_RELEASE, &release);
	if (error != 0) {
		printf("FAIL e2e.display: the release (%d)\n", errno);
		return 1;
	}
	e2e_display_state(&after);
	if (after.enabled) {
		printf("FAIL e2e.display: the controller is still lit after the release\n");
		return 1;
	}

	/* A wait on the ended lease is refused. */
	memset(&wait, 0, sizeof(wait));
	wait.version = GPU_ABI_VERSION;
	wait.size = sizeof(wait);
	wait.lease = claim.lease;
	wait.sequence = sequence;
	error = ioctl(fd, GPU_DISPLAY_WAIT, &wait);
	if (error == 0) {
		printf("FAIL e2e.display: a wait on the released lease succeeded\n");
		return 1;
	}
	if (errno != EBUSY) {
		printf("FAIL e2e.display: a wait on the released lease answered errno %d, not EBUSY\n", errno);
		return 1;
	}

	/* Succeeded: every step passed. */
	return 0;
}

/*
 * Presents a whole frame of the lease from a resource (a blob when blob
 * is nonzero, ordinary storage otherwise) and reports its sequence; the
 * call returns once the frame is adopted.  Returns 0 or the errno.
 */
static int
display_present(
	int fd,
	const struct gpu_display_info *query,
	uint64_t lease,
	uint64_t handle,
	uint32_t format,
	int blob,
	uint64_t *sequence)
{
	struct gpu_display_present present;
	int error;

	/* A FIFO present of the frame at the output's refresh. */
	memset(&present, 0, sizeof(present));
	present.version = GPU_ABI_VERSION;
	present.size = sizeof(present);
	present.lease = lease;
	present.handle = handle;
	present.offset = 0U;
	present.width = VKDEMO_WIDTH;
	present.height = VKDEMO_HEIGHT;
	present.stride = DISPLAY_STRIDE;
	present.format = format;
	present.refresh_millihz = query->refresh_millihz;
	present.flags = GPU_DISPLAY_PRESENT_FIFO;
	if (blob)
		present.flags |= GPU_DISPLAY_PRESENT_BLOB;
	present.generation = query->generation;
	error = ioctl(fd, GPU_DISPLAY_PRESENT, &present);
	if (error != 0) {
		error = errno;
		return error;
	}

	/* Succeeded: the frame's number. */
	*sequence = present.sequence;
	return 0;
}

/*
 * Checks what the controller shows after a present returned: it is lit
 * and scans the driver's image (a frame of the driver's holding the image,
 * or, shared, the blob's own memory at blob_address); plane 0's record is new
 * and not cancelled; the frame is adopted and a wait answers at once; and
 * the next whole frame scanned sums to the image's sum.  Fills after.
 * Returns 0, or 1 after printing what differs.
 */
static int
display_check(
	const char *what,
	int fd,
	uint64_t lease,
	uint64_t sequence,
	const uint8_t *image,
	uint32_t blob_address,
	uint32_t sum,
	const struct e2e_display_state *before,
	struct e2e_display_state *after)
{
	struct gpu_display_wait wait;
	const uint8_t *local;
	uint32_t local_base;
	uint32_t local_bytes;
	uint32_t window_bytes;
	uint32_t offset;
	uint32_t row;
	int differs;
	int error;

	/* What the display shows now. */
	e2e_display_state(after);
	printf("  e2e.display %s: sequence %llu adopted %llu, FB_BASE %08x stride %u, record %08x frame %u (count %u), copy frame %d\n",
	    what, (unsigned long long)sequence, (unsigned long long)after->adopted, (unsigned)after->fb_base,
	    (unsigned)after->fb_stride, (unsigned)after->record_value, (unsigned)after->record_frame,
	    (unsigned)after->frame_count, after->shown_copy_frame);

	/* Lit, scanning the image the driver says it shows, which is adopted. */
	if (!after->enabled) {
		printf("FAIL e2e.display %s: the controller is dark\n", what);
		return 1;
	}
	if (after->fb_base != after->shown_base) {
		printf("FAIL e2e.display %s: FB_BASE %08x is not the driver's image %08x\n", what, (unsigned)after->fb_base, (unsigned)after->shown_base);
		return 1;
	}
	if (after->adopted < sequence) {
		printf("FAIL e2e.display %s: the present returned before its adoption\n", what);
		return 1;
	}

	/* Plane 0's record: a new flip's, not cancelled, taken at a frame already begun. */
	if (after->record_value == before->record_value) {
		printf("FAIL e2e.display %s: no new record\n", what);
		return 1;
	}
	if ((after->record_value & DISPLAY_RECORD_CANCELLED) != 0U) {
		printf("FAIL e2e.display %s: the flip was cancelled\n", what);
		return 1;
	}
	if (after->record_value == 0U) {
		printf("FAIL e2e.display %s: the record is empty\n", what);
		return 1;
	}
	if (after->record_frame > after->frame_count) {
		printf("FAIL e2e.display %s: the record's frame %u is ahead of FRAME_COUNT %u\n", what, (unsigned)after->record_frame, (unsigned)after->frame_count);
		return 1;
	}

	/* The image lies in the local memory at FB_BASE: the blob's own bytes, or a copy of them. */
	local = atg_link_local(&local_base, &local_bytes, &window_bytes);
	offset = after->fb_base - local_base;
	if (offset > local_bytes - DISPLAY_STRIDE * VKDEMO_HEIGHT) {
		printf("FAIL e2e.display %s: FB_BASE %08x is outside the local memory\n", what, (unsigned)after->fb_base);
		return 1;
	}
	if (blob_address != 0U) {
		if (after->fb_base != blob_address) {
			printf("FAIL e2e.display %s: FB_BASE is not the session's blob %08x\n", what, (unsigned)blob_address);
			return 1;
		}
		if (after->shown_copy_frame >= 0) {
			printf("FAIL e2e.display %s: a shared present shows a frame of the driver's\n", what);
			return 1;
		}
	} else {
		if (after->shown_copy_frame < 0) {
			printf("FAIL e2e.display %s: a copied present shows no frame of the driver's\n", what);
			return 1;
		}
	}

	/* Every row of the scanned memory is the image's. */
	for (row = 0U; row < VKDEMO_HEIGHT; row++) {
		differs = memcmp(local + offset + row * after->fb_stride, image + row * DISPLAY_STRIDE, DISPLAY_STRIDE);
		if (differs != 0) {
			printf("FAIL e2e.display %s: row %u of the scanned memory is not the image's\n", what, (unsigned)row);
			return 1;
		}
	}

	/* The adoption is there already: a wait without time answers at once. */
	memset(&wait, 0, sizeof(wait));
	wait.version = GPU_ABI_VERSION;
	wait.size = sizeof(wait);
	wait.lease = lease;
	wait.sequence = sequence;
	wait.timeout_ns = 0U;
	error = ioctl(fd, GPU_DISPLAY_WAIT, &wait);
	if (error != 0) {
		printf("FAIL e2e.display %s: the wait (%d)\n", what, errno);
		return 1;
	}
	if (wait.completed_sequence < sequence) {
		printf("FAIL e2e.display %s: the wait reports %llu\n", what, (unsigned long long)wait.completed_sequence);
		return 1;
	}

	/* Two frames on, the last whole frame was the image's: its words and their sum. */
	error = e2e_display_frames(2U, DISPLAY_FRAMES_TIMEOUT_NS);
	if (error != 0) {
		printf("FAIL e2e.display %s: the controller began no frames\n", what);
		return 1;
	}
	e2e_display_state(after);
	printf("  e2e.display %s: SCAN_SUM %08x (image %08x), SCAN_WORDS %u, FRAME_COUNT %u\n", what,
	    (unsigned)after->scan_sum, (unsigned)sum, (unsigned)after->scan_words, (unsigned)after->frame_count);
	if (after->scan_words != VKDEMO_WIDTH * VKDEMO_HEIGHT) {
		printf("FAIL e2e.display %s: the frame had %u words\n", what, (unsigned)after->scan_words);
		return 1;
	}
	if (after->scan_sum != sum) {
		printf("FAIL e2e.display %s: the frame scanned is not the image\n", what);
		return 1;
	}
	if (after->fb_base != after->shown_base) {
		printf("FAIL e2e.display %s: FB_BASE moved\n", what);
		return 1;
	}

	/* Succeeded: the controller shows the image. */
	return 0;
}

/* Takes the counts at a case's start. */
static void
measure_start(
	struct measure *measure)
{
	atg_link_stats(&measure->link);
	e2e_core_stats(&measure->core);

	/* The case's longest vkQueueSubmit is its own. */
	submits.cycles_max = 0U;
	measure->submit = submits;
}

/* Prints what a case took: the GPU's cycles, the firmware's, the µops, the round trips. */
static void
measure_report(
	const char *name,
	const struct measure *measure)
{
	struct atg_link_stats link;
	struct e2e_core_stats core;
	uint64_t commands;
	uint64_t jobs;
	uint64_t command_average;
	uint64_t job_average;
	uint64_t calls;

	/* The counts now, and the averages of the round trips. */
	atg_link_stats(&link);
	e2e_core_stats(&core);
	commands = core.commands - measure->core.commands;
	jobs = core.jobs - measure->core.jobs;
	command_average = 0U;
	if (commands != 0U)
		command_average = (core.command_cycles - measure->core.command_cycles) / commands;
	job_average = 0U;
	if (jobs != 0U)
		job_average = (core.job_cycles - measure->core.job_cycles) / jobs;

	/* One line of the totals, and the round trips. */
	printf("  measure %s: %llu cycles, firmware in packets %llu, µop words %llu, register reads %llu writes %llu, stray %llu\n",
	    name,
	    (unsigned long long)(link.cycles - measure->link.cycles),
	    (unsigned long long)(link.fw_packet_cycles - measure->link.fw_packet_cycles),
	    (unsigned long long)(link.uop_words - measure->link.uop_words),
	    (unsigned long long)(link.register_reads - measure->link.register_reads),
	    (unsigned long long)(link.register_writes - measure->link.register_writes),
	    (unsigned long long)(link.stray_accesses - measure->link.stray_accesses));
	if (commands != 0U || jobs != 0U) {
		printf("  measure %s: %llu transactions, %llu cycles each on average; %llu jobs, %llu cycles each on average\n",
		    name,
		    (unsigned long long)commands,
		    (unsigned long long)command_average,
		    (unsigned long long)jobs,
		    (unsigned long long)job_average);
	}
	calls = submits.calls - measure->submit.calls;
	if (calls != 0U) {
		printf("  measure %s: %llu vkQueueSubmit, %llu cycles each to return on average, the longest %llu\n",
		    name,
		    (unsigned long long)calls,
		    (unsigned long long)((submits.cycles - measure->submit.cycles) / calls),
		    (unsigned long long)submits.cycles_max);
	}
	fflush(stdout);
}

/*
 * Calls libvulkan's vkQueueSubmit and counts the GPU cycles until it
 * returns (Vulkan's submit does not wait for the work).
 */
VkResult
__wrap_vkQueueSubmit(
	VkQueue queue,
	uint32_t count,
	const VkSubmitInfo *submit,
	VkFence fence)
{
	struct atg_link_stats before;
	struct atg_link_stats after;
	uint64_t cycles;
	VkResult result;

	/* The cycles around the call. */
	atg_link_stats(&before);
	result = __real_vkQueueSubmit(queue, count, submit, fence);
	atg_link_stats(&after);

	/* The counts. */
	cycles = after.cycles - before.cycles;
	submits.calls++;
	submits.cycles += cycles;
	if (cycles > submits.cycles_max)
		submits.cycles_max = cycles;

	/* Succeeded: libvulkan's answer. */
	return result;
}

/* Reads a SPIR-V module from a file into words the caller frees, or NULL. */
static uint32_t *
module_read(
	const char *path,
	size_t *bytes)
{
	FILE *file;
	uint32_t *words;
	long length;
	size_t got;

	/* The file and its length. */
	file = fopen(path, "rb");
	if (file == NULL)
		return NULL;
	(void)fseek(file, 0L, SEEK_END);
	length = ftell(file);
	(void)fseek(file, 0L, SEEK_SET);
	if (length <= 0 || (length % 4) != 0) {
		fclose(file);
		return NULL;
	}

	/* Its words. */
	words = malloc((size_t)length);
	if (words == NULL) {
		fclose(file);
		return NULL;
	}
	got = fread(words, 1U, (size_t)length, file);
	fclose(file);
	if (got != (size_t)length) {
		free(words);
		return NULL;
	}

	/* Succeeded: the module. */
	*bytes = (size_t)length;
	return words;
}
