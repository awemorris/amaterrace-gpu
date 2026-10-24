/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * fwtest.c: the CP firmware's host tests (fw/cp/tests/run.sh).  Each case
 * stages commands as the driver does, runs the frame through the
 * firmware built for the host, and checks the result records, the µops,
 * the STATE they leave and the memory the blits wrote.  Prints "PASS
 * fwtest.<case>" per case and "PASS fwtest" at the end.
 */

#include "fwhost.h"

#include <stdio.h>
#include <string.h>

#include "../fw.h"
#include "ghci_frame.h"
#include "ghci_packets.h"
#include "ghci_regs.h"

/* The session the cases use, its device and its memory object. */
#define TAG 5u
#define DEVICE 0x10ull
#define MEMORY 0x100ull
#define MEMORY_BASE 0x01000000u
#define MEMORY_BYTES 0x00800000u

/* sTypes the staged structures carry (the firmware does not look at most). */
#define ST_BUFFER 12u
#define ST_IMAGE 14u
#define ST_IMAGE_VIEW 15u
#define ST_SAMPLER 31u
#define ST_POOL 39u
#define ST_ALLOCATE 40u
#define ST_BEGIN 42u
#define ST_SUBMIT 4u

static int test_case(const char *name, int failures_before);
static void open_session(void);
static void stage_memory(uint32_t index);
static void stage_buffer(uint32_t index, uint64_t id, uint64_t size, uint32_t usage);
static void stage_bind_buffer(uint32_t index, uint64_t buffer, uint64_t offset);
static void stage_pool_and_buffer(uint32_t index, uint64_t pool, uint64_t cmdbuf);
static void stage_begin(uint32_t index, uint64_t cmdbuf);
static void stage_end(uint32_t index, uint64_t cmdbuf);
static void stage_submit(uint32_t index, uint64_t cmdbuf);
static void test_sessions(void);
static void test_buffers(void);
static void test_images(void);

int
main(void)
{
	/* Each case on a fresh bench and firmware. */
	test_sessions();
	test_buffers();
	test_images();

	if (host_failures != 0) {
		printf("FAIL fwtest: %d failures\n", host_failures);
		return 1;
	}
	printf("PASS fwtest\n");
	return 0;
}

/* Prints a case's result. */
static int
test_case(
	const char *name,
	int failures_before)
{
	if (host_failures == failures_before) {
		printf("PASS fwtest.%s\n", name);
		return 1;
	}
	printf("FAIL fwtest.%s\n", name);
	return 0;
}

/* Starts the firmware's state and lends the heap; opens the session. */
static void
open_session(void)
{
	uint32_t args[4];

	host_reset();
	fw_heap_init();
	fw_object_init();
	fw_uop_reset();
	args[0] = HOST_HEAP;
	args[1] = 0;
	args[2] = HOST_HEAP_BYTES;
	args[3] = 0;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 4);
	host_check(host_ring_result() == 0, "GHCI_HEAP");
	args[0] = TAG;
	args[1] = 0;
	args[2] = 0;
	args[3] = 0;
	host_ring(TAG, GHCI_GPU_OP_SESSION_OPEN, args, 4);
	host_check(host_ring_result() == 0, "GHCI_SESSION_OPEN");
}

/* GHCI_MEMORY of the cases' memory. */
static void
stage_memory(
	uint32_t index)
{
	host_record(GHCI_GPU_OP_MEMORY, index);
	host_u64(MEMORY);
	host_u64(MEMORY_BASE);
	host_u64(MEMORY_BYTES);
	host_u32(0);
}

/* CREATE_BUFFER. */
static void
stage_buffer(
	uint32_t index,
	uint64_t id,
	uint64_t size,
	uint32_t usage)
{
	host_record(GHCI_VK_CREATE_BUFFER, index);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_BUFFER);
	host_u64(0);
	host_u32(0);
	host_u64(size);
	host_u32(usage);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u64(0);
	host_u64(1);
	host_u64(id);
}

/* BIND_BUFFER_MEMORY. */
static void
stage_bind_buffer(
	uint32_t index,
	uint64_t buffer,
	uint64_t offset)
{
	host_record(GHCI_VK_BIND_BUFFER_MEMORY, index);
	host_u64(DEVICE);
	host_u64(buffer);
	host_u64(MEMORY);
	host_u64(offset);
}

/* CREATE_COMMAND_POOL and ALLOCATE_COMMAND_BUFFERS of one primary command buffer. */
static void
stage_pool_and_buffer(
	uint32_t index,
	uint64_t pool,
	uint64_t cmdbuf)
{
	host_record(GHCI_VK_CREATE_COMMAND_POOL, index);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_POOL);
	host_u64(0);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(pool);
	host_record(GHCI_VK_ALLOCATE_COMMAND_BUFFERS, index + 1u);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_ALLOCATE);
	host_u64(0);
	host_u64(pool);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(cmdbuf);
}

/* BEGIN_COMMAND_BUFFER (one-time submit, no inheritance). */
static void
stage_begin(
	uint32_t index,
	uint64_t cmdbuf)
{
	host_record(GHCI_VK_BEGIN_COMMAND_BUFFER, index);
	host_u64(cmdbuf);
	host_u64(1);
	host_u32(ST_BEGIN);
	host_u64(0);
	host_u32(1);
	host_u64(0);
}

/* END_COMMAND_BUFFER. */
static void
stage_end(
	uint32_t index,
	uint64_t cmdbuf)
{
	host_record(GHCI_VK_END_COMMAND_BUFFER, index);
	host_u64(cmdbuf);
}

/* QUEUE_SUBMIT of one command buffer. */
static void
stage_submit(
	uint32_t index,
	uint64_t cmdbuf)
{
	host_record(GHCI_VK_QUEUE_SUBMIT, index);
	host_u64(0x9);
	host_u32(1);
	host_u64(1);
	host_u32(ST_SUBMIT);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u64(0);
	host_u32(1);
	host_u64(1);
	host_u64(cmdbuf);
	host_u32(0);
	host_u64(0);
	host_u64(0);
}

/* The ring-only gpu-ops and the session rules (docs/ghci.md sections 7.2, 11.6). */
static void
test_sessions(void)
{
	uint32_t args[4];
	uint32_t status;
	int before;

	before = host_failures;
	open_session();

	/* A second open of the session fails; a flag (PROTECTED) is not present. */
	args[0] = TAG;
	args[1] = 0;
	args[2] = 0;
	args[3] = 0;
	host_ring(TAG, GHCI_GPU_OP_SESSION_OPEN, args, 4);
	host_check(host_ring_result() == FW_VK_ERROR_INITIALIZATION_FAILED, "a second SESSION_OPEN");
	args[0] = 6;
	args[1] = GHCI_SESSION_PROTECTED;
	host_ring(6, GHCI_GPU_OP_SESSION_OPEN, args, 4);
	host_check(host_ring_result() == FW_VK_ERROR_FEATURE_NOT_PRESENT, "SESSION_OPEN PROTECTED");

	/* The heap cannot change while a session is open. */
	args[0] = HOST_HEAP;
	args[1] = 0;
	args[2] = HOST_HEAP_BYTES;
	args[3] = 0;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 4);
	host_check(host_ring_result() == FW_VK_ERROR_INITIALIZATION_FAILED, "GHCI_HEAP with a session open");

	/* SESSION_OPEN, SESSION_CLOSE, GRANT inside a frame end it. */
	host_frame_begin();
	stage_memory(0);
	host_record(GHCI_GPU_OP_SESSION_CLOSE, 1);
	host_u32(TAG);
	stage_buffer(2, 0x200, 64, 3);
	status = host_frame_run(TAG, 3);
	host_check(status == (uint32_t)FW_VK_ERROR_FEATURE_NOT_PRESENT, "SESSION_CLOSE in a frame: the frame's status");
	host_check(host_peek(HOST_FRAME_RESULT + 4u) == 2, "SESSION_CLOSE in a frame: decoded records");
	host_check(host_result(0) == 0 && host_result(1) == FW_VK_ERROR_FEATURE_NOT_PRESENT, "the records");
	host_check(fw_session_is_open(TAG), "the session is still open");
	host_frame_begin();
	host_record(GHCI_GPU_OP_BUFFER_GRANT, 0);
	host_u32(TAG);
	host_u32(1);
	host_u64(0);
	host_u64(0);
	status = host_frame_run(TAG, 1);
	host_check(status == (uint32_t)FW_VK_ERROR_FEATURE_NOT_PRESENT, "BUFFER_GRANT");

	/* A frame of an unopened session makes no object. */
	host_frame_begin();
	stage_buffer(0, 0x300, 64, 3);
	(void)host_frame_run(9, 1);
	host_check(host_result(0) == FW_VK_ERROR_INITIALIZATION_FAILED, "an object of a closed session");

	/* Closing returns every object: the heap is whole again. */
	host_frame_begin();
	stage_memory(0);
	stage_pool_and_buffer(1, 0x500, 0x600);
	stage_begin(3, 0x600);
	(void)host_frame_run(TAG, 4);
	host_check(fw_object_find(TAG, 0x600, FW_OBJ_CMDBUF) != NULL, "the command buffer exists");
	args[0] = TAG;
	host_ring(TAG, GHCI_GPU_OP_SESSION_CLOSE, args, 1);
	host_check(fw_object_find(TAG, 0x600, FW_OBJ_CMDBUF) == NULL, "SESSION_CLOSE returned the objects");
	host_check(fw_heap_alloc(TAG, 64) == 0, "a closed session has no heap");
	args[0] = HOST_HEAP;
	args[1] = 0;
	args[2] = HOST_HEAP_BYTES;
	args[3] = 0;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 4);
	host_check(host_ring_result() == 0, "GHCI_HEAP after the close");
	(void)test_case("sessions", before);
}

/* vkCmdFillBuffer, vkCmdCopyBuffer (odd sizes), vkCmdUpdateBuffer, through a submit. */
static void
test_buffers(void)
{
	uint32_t index;
	uint32_t base_a;
	uint32_t base_b;
	uint32_t ok;
	int before;

	before = host_failures;
	open_session();
	for (index = 0; index < 0x4000u; index++)
		host_mem[MEMORY_BASE + index] = (uint8_t)(index * 7u + 3u);

	/* Two buffers, a command buffer recording fill, copy, update. */
	host_frame_begin();
	stage_memory(0);
	stage_buffer(1, 0x200, 0x2000, 3);
	stage_buffer(2, 0x201, 0x2000, 3);
	stage_bind_buffer(3, 0x200, 0);
	stage_bind_buffer(4, 0x201, 0x2000);
	stage_pool_and_buffer(5, 0x300, 0x400);
	stage_begin(7, 0x400);
	host_cmd(GHCI_VK_CMD_FILL_BUFFER);
	host_u64(0x400);
	host_u64(0x200);
	host_u64(0x10);
	host_u64(5200);
	host_u32(0xC0DE1234u);
	host_cmd(GHCI_VK_CMD_COPY_BUFFER);
	host_u64(0x400);
	host_u64(0x200);
	host_u64(0x201);
	host_u32(1);
	host_u64(1);
	host_u64(3);
	host_u64(1);
	host_u64(4097);
	host_cmd(GHCI_VK_CMD_UPDATE_BUFFER);
	host_u64(0x400);
	host_u64(0x201);
	host_u64(0x1800);
	host_u64(1200);
	host_u64(1200);
	for (index = 0; index < 300u; index++)
		host_u32(0xAB000000u | index);
	stage_end(8, 0x400);
	stage_submit(9, 0x400);
	host_check(host_frame_run(TAG, 13) == 0, "the frame's status");
	host_check(host_peek(HOST_FRAME_RESULT + 4u) == 13, "every record decoded");
	for (index = 0; index < 10u; index++) {
		if (host_result(index) != 0) {
			printf("  record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* The memory: the fill, then the copy of 4097 bytes from A+3 to B+1, then the update. */
	base_a = MEMORY_BASE;
	base_b = MEMORY_BASE + 0x2000u;
	ok = 1;
	for (index = 0x10; index < 0x10u + 5200u; index += 4u) {
		if (host_peek(base_a + index) != 0xC0DE1234u)
			ok = 0;
	}
	host_check(ok, "the fill");
	host_check(host_mem[base_a + 0x0F] == (uint8_t)(0x0Fu * 7u + 3u), "the fill's start");
	ok = 1;
	for (index = 0; index < 4097u; index++) {
		if (host_mem[base_b + 1u + index] != host_mem[base_a + 3u + index])
			ok = 0;
	}
	host_check(ok, "the copy of bytes");
	host_check(host_mem[base_b] == (uint8_t)(0x2000u * 7u + 3u), "the copy's start");
	ok = 1;
	for (index = 0; index < 300u; index++) {
		if (host_peek(base_b + 0x1800u + index * 4u) != (0xAB000000u | index))
			ok = 0;
	}
	host_check(ok, "the update");
	host_check(host_uops_of(GHCI_OP_BLIT) >= 4u, "blits went to the FIFO");
	host_check(host_dones == 3, "DONE after each packet");
	host_check(host_results == 3, "RESULT after each packet");

	/* The one-time command buffer cannot be submitted again. */
	host_frame_begin();
	stage_submit(0, 0x400);
	(void)host_frame_run(TAG, 1);
	host_check(host_result(0) == FW_VK_ERROR_UNKNOWN, "a one-time command buffer submitted twice");
	(void)test_case("buffers", before);
}

/* Images, views and samplers: the layout and the texture slot's words. */
static void
test_images(void)
{
	struct fw_object *view;
	struct fw_object *sampler;
	struct fw_object *image;
	uint32_t words[16];
	int before;

	before = host_failures;
	open_session();
	host_frame_begin();
	stage_memory(0);

	/* A 2D RGBA8 image of 100 x 50 with 3 levels and 2 layers, sampled and an attachment. */
	host_record(GHCI_VK_CREATE_IMAGE, 1);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_IMAGE);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u32(FW_VK_FORMAT_R8G8B8A8_UNORM);
	host_u32(101);
	host_u32(50);
	host_u32(1);
	host_u32(3);
	host_u32(2);
	host_u32(1);
	host_u32(0);
	host_u32(0x14);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x700);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 2);
	host_u64(DEVICE);
	host_u64(0x700);
	host_u64(MEMORY);
	host_u64(0x10000);

	/* A view of level 1, layer 1, swizzled B G R A. */
	host_record(GHCI_VK_CREATE_IMAGE_VIEW, 3);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_IMAGE_VIEW);
	host_u64(0);
	host_u32(0);
	host_u64(0x700);
	host_u32(1);
	host_u32(FW_VK_FORMAT_R8G8B8A8_UNORM);
	host_u32(5);
	host_u32(4);
	host_u32(3);
	host_u32(6);
	host_u32(FW_ASPECT_COLOR);
	host_u32(1);
	host_u32(0xFFFFFFFFu);
	host_u32(1);
	host_u32(1);
	host_u64(0);
	host_u64(1);
	host_u64(0x800);

	/* A sampler: linear, clamp to edge, compare less, lod 0.5 to 4.25, bias -1.5. */
	host_record(GHCI_VK_CREATE_SAMPLER, 4);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_SAMPLER);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u32(1);
	host_u32(1);
	host_u32(2);
	host_u32(2);
	host_u32(0);
	host_u32(0xBFC00000u);
	host_u32(0);
	host_u32(0x3F800000u);
	host_u32(1);
	host_u32(1);
	host_u32(0x3F000000u);
	host_u32(0x40880000u);
	host_u32(3);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x900);
	host_check(host_frame_run(TAG, 5) == 0, "the frame's status");

	/*
	 * The image: rows of 102 texels at level 0 (an attachment rounds the
	 * width to even): 408 x 50 = 20400 -> 20416; level 1 50 x 25: 5000 ->
	 * 5056; level 2 25 -> 26 x 12: 1248 -> 1280; the layer 26752.
	 */
	image = fw_object_find(TAG, 0x700, FW_OBJ_IMAGE);
	host_check(image != NULL && image->a == MEMORY_BASE + 0x10000u, "the bound image");
	if (image != NULL) {
		memcpy(words, &host_mem[image->block], 64);
		host_check(words[13] == 20416u + 5056u + 1280u, "the layer stride");
	}
	view = fw_object_find(TAG, 0x800, FW_OBJ_IMAGE_VIEW);
	host_check(view != NULL, "the view");
	if (view != NULL) {
		memcpy(words, &host_mem[view->block], 64);
		host_check(words[0] == MEMORY_BASE + 0x10000u + 26752u + 20416u, "the view's base");
		host_check(words[1] == 50u * 4u, "the view's row");
		host_check(words[9] == (25u << 16 | 50u), "TEX_SIZE");
		host_check(words[10] == (GHCI_IMG_LEVELS(2) | GHCI_IMG_TYPE(GHCI_IMG_TYPE_2D)), "TEX_IMAGE");
		host_check(words[11] == (GHCI_TFMT_VKFORMAT(37) | GHCI_TFMT_SWIZZLE(5, 4, 3, 6)), "TEX_FORMAT");
	}
	sampler = fw_object_find(TAG, 0x900, FW_OBJ_SAMPLER);
	host_check(sampler != NULL, "the sampler");
	if (sampler != NULL) {
		host_check(sampler->a == (GHCI_SAMP_WRAP_U(2) | GHCI_SAMP_WRAP_V(2) | GHCI_SAMP_MAG_LINEAR |
		    GHCI_SAMP_MIN_LINEAR | GHCI_SAMP_MIP_LINEAR | GHCI_SAMP_COMPARE | GHCI_SAMP_COMPARE_OP(1) |
		    GHCI_SAMP_BORDER(3) | GHCI_SAMP_LOD_BIAS((uint32_t)-384)), "TEX_SAMPLER");
		host_check(sampler->b == GHCI_TEX_LOD_VAL(128, 1088), "TEX_LOD");
	}
	(void)test_case("images", before);
}
