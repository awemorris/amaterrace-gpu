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
static void test_draw(void);
static void test_compute(void);
static void test_transfer(void);
static void stage_compute_pipeline(uint32_t index, uint64_t id);
static void stage_image(uint32_t index, uint64_t id, uint32_t format, uint32_t width, uint32_t height, uint32_t usage);
static void stage_view(uint32_t index, uint64_t id, uint64_t image, uint32_t format);
static void put_program(uint32_t address, uint32_t stage, const uint32_t *entries, uint32_t count, uint32_t push);

int
main(void)
{
	/* Each case on a fresh bench and firmware. */
	test_sessions();
	test_buffers();
	test_images();
	test_draw();
	test_compute();
	test_transfer();

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
	uint32_t args[5];

	host_reset();
	fw_heap_init();
	fw_object_init();
	fw_uop_reset();
	args[0] = HOST_HEAP;
	args[1] = 0;
	args[2] = HOST_HEAP_BYTES;
	args[3] = 0;
	args[4] = 4;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 5);
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
	uint32_t args[5];
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
	args[4] = 4;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 5);
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
	args[4] = 4;
	host_ring(0, GHCI_GPU_OP_HEAP, args, 5);
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

/* CREATE_IMAGE of a 2D image with one level and layer, and BIND_IMAGE_MEMORY at its offset. */
static void
stage_image(
	uint32_t index,
	uint64_t id,
	uint32_t format,
	uint32_t width,
	uint32_t height,
	uint32_t usage)
{
	host_record(GHCI_VK_CREATE_IMAGE, index);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_IMAGE);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u32(format);
	host_u32(width);
	host_u32(height);
	host_u32(1);
	host_u32(1);
	host_u32(1);
	host_u32(1);
	host_u32(0);
	host_u32(usage);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(id);
}

/* CREATE_IMAGE_VIEW of a whole 2D image, identity swizzle. */
static void
stage_view(
	uint32_t index,
	uint64_t id,
	uint64_t image,
	uint32_t format)
{
	host_record(GHCI_VK_CREATE_IMAGE_VIEW, index);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_IMAGE_VIEW);
	host_u64(0);
	host_u32(0);
	host_u64(image);
	host_u32(1);
	host_u32(format);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(FW_ASPECT_COLOR);
	host_u32(0);
	host_u32(1);
	host_u32(0);
	host_u32(1);
	host_u64(0);
	host_u64(1);
	host_u64(id);
}

/* A GSI1 binary at an address: the header, the interface entries, one `end`. */
static void
put_program(
	uint32_t address,
	uint32_t stage,
	const uint32_t *entries,
	uint32_t count,
	uint32_t push)
{
	uint32_t header[16];
	uint32_t index;

	memset(header, 0, sizeof(header));
	header[0] = 0x47534931u;
	header[1] = 1;
	header[2] = stage;
	header[4] = 2;
	header[5] = 16u + 4u * count;
	header[6] = 8;
	header[9] = 8;
	header[10] = 16;
	header[11] = count;
	header[13] = 1;
	header[14] = push;
	for (index = 0; index < 16u; index++)
		host_poke(address + index * 4u, header[index]);
	for (index = 0; index < 4u * count; index++)
		host_poke(address + 64u + index * 4u, entries[index]);
	host_poke(address + 64u + 16u * count, 0x0000700Bu);
	host_poke(address + 68u + 16u * count, 0);
}

/*
 * A draw: a render pass that clears a 64x32 RGBA8 target, a pipeline of
 * a vertex program (one attribute, a uniform block, push constants) and
 * a fragment program (a sampled image), a descriptor set, a vertex
 * buffer: the STATE the draw leaves, the constant bank, the clear.
 */
static void
test_draw(void)
{
	static const uint32_t vs_entries[] = {
		1, 0, 0, 0x0400u,			/* attribute: location 0, r0, 4 components */
		4, 0, 0, 4u | 4u << 8,			/* uniform block: set 0, binding 0, bank 4, 4 words */
		7, 0, 0, 0,				/* push constants at bank 0 */
		3, 0, 0, 0x0400u,			/* output: location 0, word 0, 4 components */
	};
	static const uint32_t fs_entries[] = {
		2, 0, 0, 0x0400u,			/* input: location 0 */
		5, 0, 1, 0,				/* sampled image: set 0, binding 1, slot 0 */
		3, 0, 0, 0x100u | 0xFu << 16,		/* output: attachment 0 */
	};
	uint32_t index;
	uint32_t uop;
	uint32_t bank;
	uint32_t base;
	uint32_t ok;
	struct fw_object *view;
	uint32_t view_words[16];
	int before;

	before = host_failures;
	open_session();

	/* The programs, in the memory object (the driver puts them there). */
	put_program(MEMORY_BASE + 0x700000u, 0, vs_entries, 4, 16);
	put_program(MEMORY_BASE + 0x701000u, 1, fs_entries, 3, 0);
	for (index = 0; index < 4u; index++)
		host_poke(MEMORY_BASE + 0x8000u + index * 4u, 0x51000000u | index);

	/* Frame 1: memory, the target and a texture, buffers, the sampler. */
	host_frame_begin();
	stage_memory(0);
	stage_image(1, 0x700, FW_VK_FORMAT_R8G8B8A8_UNORM, 64, 32, 0x14);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 2);
	host_u64(DEVICE);
	host_u64(0x700);
	host_u64(MEMORY);
	host_u64(0x100000);
	stage_view(3, 0x701, 0x700, FW_VK_FORMAT_R8G8B8A8_UNORM);
	stage_image(4, 0x710, FW_VK_FORMAT_B8G8R8A8_UNORM, 16, 16, 0x4);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 5);
	host_u64(DEVICE);
	host_u64(0x710);
	host_u64(MEMORY);
	host_u64(0x200000);
	stage_view(6, 0x711, 0x710, FW_VK_FORMAT_B8G8R8A8_UNORM);
	stage_buffer(7, 0x720, 0x1000, 0x80);
	stage_bind_buffer(8, 0x720, 0x4000);
	stage_buffer(9, 0x721, 0x100, 0x10);
	stage_bind_buffer(10, 0x721, 0x8000);
	host_record(GHCI_VK_CREATE_SAMPLER, 11);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(ST_SAMPLER);
	host_u64(0);
	for (index = 0; index < 16u; index++)
		host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x730);
	host_check(host_frame_run(TAG, 12) == 0, "frame 1");
	for (index = 0; index < 12u; index++) {
		if (host_result(index) != 0) {
			printf("  frame 1 record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* Frame 2: the set layout, pool, set and its update; the pipeline layout; render pass; framebuffer. */
	host_frame_begin();
	host_record(GHCI_VK_CREATE_DESCRIPTOR_SET_LAYOUT, 0);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(32);
	host_u64(0);
	host_u32(0);
	host_u32(2);
	host_u64(2);
	host_u32(0);
	host_u32(6);
	host_u32(1);
	host_u32(1);
	host_u64(0);
	host_u32(1);
	host_u32(1);
	host_u32(1);
	host_u32(0x10);
	host_u64(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x740);
	host_record(GHCI_VK_CREATE_DESCRIPTOR_POOL, 1);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(33);
	host_u64(0);
	host_u32(0);
	host_u32(4);
	host_u32(1);
	host_u64(1);
	host_u32(6);
	host_u32(16);
	host_u64(0);
	host_u64(1);
	host_u64(0x741);
	host_record(GHCI_VK_ALLOCATE_DESCRIPTOR_SETS, 2);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(34);
	host_u64(0);
	host_u64(0x741);
	host_u32(1);
	host_u64(1);
	host_u64(0x740);
	host_u64(1);
	host_u64(0x742);
	host_record(GHCI_VK_UPDATE_DESCRIPTOR_SETS, 3);
	host_u64(DEVICE);
	host_u32(2);
	host_u64(2);
	host_u32(35);
	host_u64(0);
	host_u64(0x742);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u32(6);
	host_u64(0);
	host_u64(1);
	host_u64(0x721);
	host_u64(0);
	host_u64(~0ull);
	host_u64(0);
	host_u32(35);
	host_u64(0);
	host_u64(0x742);
	host_u32(1);
	host_u32(0);
	host_u32(1);
	host_u32(1);
	host_u64(1);
	host_u64(0x730);
	host_u64(0x711);
	host_u32(5);
	host_u64(0);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_record(GHCI_VK_CREATE_PIPELINE_LAYOUT, 4);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(30);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(0x740);
	host_u32(1);
	host_u64(1);
	host_u32(1);
	host_u32(0);
	host_u32(16);
	host_u64(0);
	host_u64(1);
	host_u64(0x750);
	host_record(GHCI_VK_CREATE_RENDER_PASS, 5);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(38);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(FW_VK_FORMAT_R8G8B8A8_UNORM);
	host_u32(1);
	host_u32(1);
	host_u32(0);
	host_u32(2);
	host_u32(1);
	host_u32(0);
	host_u32(2);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(2);
	host_u64(0);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x760);
	host_record(GHCI_VK_CREATE_FRAMEBUFFER, 6);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(37);
	host_u64(0);
	host_u32(0);
	host_u64(0x760);
	host_u32(1);
	host_u64(1);
	host_u64(0x701);
	host_u32(64);
	host_u32(32);
	host_u32(1);
	host_u64(0);
	host_u64(1);
	host_u64(0x761);

	/* The two programs, then the pipeline. */
	host_record(GHCI_GPU_OP_PROGRAM, 7);
	host_u64(0x770);
	host_u32(0);
	host_u32(0x47534931u);
	host_u64(MEMORY_BASE + 0x700000u);
	host_u32(0x1000);
	host_u32(0);
	host_record(GHCI_GPU_OP_PROGRAM, 8);
	host_u64(0x770);
	host_u32(1);
	host_u32(0x47534931u);
	host_u64(MEMORY_BASE + 0x701000u);
	host_u32(0x1000);
	host_u32(0);
	host_record(GHCI_VK_CREATE_GRAPHICS_PIPELINES, 9);
	host_u64(DEVICE);
	host_u64(0);
	host_u32(1);
	host_u64(1);
	host_u32(28);
	host_u64(0);
	host_u32(0);
	host_u32(2);
	host_u64(2);
	for (index = 0; index < 2u; index++) {
		host_u32(18);
		host_u64(0);
		host_u32(0);
		host_u32(index == 0 ? 1u : 0x10u);
		host_u64(0x100 + index);
		host_u64(5);
		host_u32(0x6E69616Du);
		host_u32(0);
		host_u64(0);
	}
	host_u64(1);
	host_u32(19);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(16);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(0);
	host_u32(109);
	host_u32(0);
	host_u64(1);
	host_u32(20);
	host_u64(0);
	host_u32(0);
	host_u32(3);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u32(22);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(0);
	host_u32(0x42800000u);
	host_u32(0x42000000u);
	host_u32(0);
	host_u32(0x3F800000u);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(0);
	host_u32(64);
	host_u32(32);
	host_u64(1);
	host_u32(23);
	host_u64(0);
	for (index = 0; index < 11u; index++)
		host_u32(index == 10u ? 0x3F800000u : (index == 4u ? 2u : 0u));
	host_u64(1);
	host_u32(24);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u32(0);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u32(26);
	host_u64(0);
	host_u32(0);
	host_u32(0);
	host_u32(3);
	host_u32(1);
	host_u64(1);
	for (index = 0; index < 8u; index++)
		host_u32(index == 7u ? 0xFu : 0u);
	host_u64(4);
	for (index = 0; index < 4u; index++)
		host_u32(0);
	host_u64(0);
	host_u64(0x750);
	host_u64(0x760);
	host_u32(0);
	host_u64(0);
	host_u32(0xFFFFFFFFu);
	host_u64(0);
	host_u64(1);
	host_u64(0x770);
	host_check(host_frame_run(TAG, 10) == 0, "frame 2");
	for (index = 0; index < 10u; index++) {
		if (host_result(index) != 0) {
			printf("  frame 2 record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* Frame 3: the recording and its submit. */
	host_frame_begin();
	stage_pool_and_buffer(0, 0x780, 0x781);
	stage_begin(2, 0x781);
	host_cmd(GHCI_VK_CMD_BEGIN_RENDER_PASS);
	host_u64(0x781);
	host_u64(1);
	host_u32(43);
	host_u64(0);
	host_u64(0x760);
	host_u64(0x761);
	host_u32(0);
	host_u32(0);
	host_u32(64);
	host_u32(32);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(2);
	host_u64(4);
	host_u32(0x3F800000u);
	host_u32(0);
	host_u32(0);
	host_u32(0x3F800000u);
	host_u32(0);
	host_cmd(GHCI_VK_CMD_BIND_PIPELINE);
	host_u64(0x781);
	host_u32(0);
	host_u64(0x770);
	host_cmd(GHCI_VK_CMD_BIND_DESCRIPTOR_SETS);
	host_u64(0x781);
	host_u32(0);
	host_u64(0x750);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(0x742);
	host_u32(0);
	host_u64(0);
	host_cmd(GHCI_VK_CMD_BIND_VERTEX_BUFFERS);
	host_u64(0x781);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(0x720);
	host_u64(1);
	host_u64(0x40);
	host_cmd(GHCI_VK_CMD_PUSH_CONSTANTS);
	host_u64(0x781);
	host_u64(0x750);
	host_u32(1);
	host_u32(0);
	host_u32(16);
	host_u64(16);
	for (index = 0; index < 4u; index++)
		host_u32(0xC0000000u | index);
	host_cmd(GHCI_VK_CMD_DRAW);
	host_u64(0x781);
	host_u32(3);
	host_u32(1);
	host_u32(0);
	host_u32(0);
	host_cmd(GHCI_VK_CMD_END_RENDER_PASS);
	host_u64(0x781);
	stage_end(10, 0x781);
	stage_submit(11, 0x781);
	host_check(host_frame_run(TAG, 12) == 0, "frame 3");
	for (index = 0; index < 12u; index++) {
		if (host_result(index) != 0 && host_result(index) != -1) {
			printf("  frame 3 record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* The clear: every texel of the target R = 1, A = 1. */
	ok = 1;
	for (index = 0; index < 64u * 32u; index++) {
		if (host_peek(MEMORY_BASE + 0x100000u + index * 4u) != 0xFF0000FFu)
			ok = 0;
	}
	host_check(ok, "the render pass's clear");

	/* The render target, the pipeline's words, the attribute, the texture slot, the viewport. */
	view = fw_object_find(TAG, 0x711, FW_OBJ_IMAGE_VIEW);
	memset(view_words, 0, sizeof(view_words));
	if (view != NULL)
		memcpy(view_words, &host_mem[view->block], 64);
	host_check(host_state[GHCI_S_RT_BASE] == MEMORY_BASE + 0x100000u, "RT_BASE");
	host_check(host_state[GHCI_S_RT_STRIDE] == 256u, "RT_STRIDE");
	host_check(host_state[GHCI_S_RT_SIZE] == (32u << 16 | 64u), "RT_SIZE");
	host_check(host_state[GHCI_S_RT_FORMATS] == FW_VK_FORMAT_R8G8B8A8_UNORM, "RT_FORMATS");
	host_check(host_state[GHCI_S_WRITE_MASK] == 0xFu, "WRITE_MASK");
	host_check(host_state[GHCI_S_TOPOLOGY] == 3u, "TOPOLOGY");
	host_check(host_state[GHCI_S_CULL] == (2u | 4u), "CULL");
	host_check(host_state[GHCI_S_VS_BASE] == MEMORY_BASE + 0x700000u + 64u + 64u, "VS_BASE");
	host_check(host_state[GHCI_S_FS_BASE] == MEMORY_BASE + 0x701000u + 64u + 48u, "FS_BASE");
	host_check(host_state[GHCI_S_ATTR_DST] == (0u | 3u << 6 | 109u << 24), "ATTR_DST[0]");
	host_check(host_state[GHCI_S_ATTR] == MEMORY_BASE + 0x4000u + 0x40u, "ATTR_BASE[0]");
	host_check(host_state[GHCI_S_ATTR + 1u] == 16u, "ATTR_DESC[0]");
	host_check(host_state[GHCI_S_ATTR_LIMIT] == (0x80000000u | (0x1000u - 0x40u)), "ATTR_LIMIT[0]");
	host_check(host_state[GHCI_S_TEX(0, GHCI_TEX_BASE)] == view_words[0], "TEX_BASE");
	host_check(host_state[GHCI_S_TEX(0, GHCI_TEX_SIZE)] == (16u << 16 | 16u), "TEX_SIZE");
	host_check(host_state[GHCI_S_TEX(0, GHCI_TEX_FORMAT)] == FW_VK_FORMAT_B8G8R8A8_UNORM, "TEX_FORMAT");
	host_check(host_state[GHCI_S_VIEWPORT + 0u] == 0x42000000u, "VIEWPORT x scale");
	host_check(host_state[GHCI_S_VIEWPORT + 1u] == 0x41800000u, "VIEWPORT y scale");
	host_check(host_state[GHCI_S_VIEWPORT + 2u] == 0x42000000u, "VIEWPORT x offset");
	host_check(host_state[GHCI_S_VIEWPORT + 3u] == 0x41800000u, "VIEWPORT y offset");
	host_check(host_state[GHCI_S_VIEWPORT + 4u] == 0x3F800000u, "VIEWPORT z scale");
	host_check(host_state[GHCI_S_SCISSOR_MAX] == (32u << 16 | 64u), "SCISSOR_MAX");
	host_check(host_state[GHCI_S_COUNT] == 3u && host_state[GHCI_S_INSTANCE_COUNT] == 1u, "COUNT");
	host_check(host_uops_of(GHCI_OP_DRAW) == 1u, "one DRAW");

	/* The bank: push constants at 0-3, the uniform block's words at 4-7 (copied by a blit). */
	uop = host_uop_find(GHCI_OP_LOAD_CONST, 0);
	host_check(uop < host_uop_count, "LOAD_CONST");
	if (uop < host_uop_count) {
		bank = host_uops[uop + 2u];
		host_check(host_uops[uop + 3u] == 8u, "LOAD_CONST words");
		ok = 1;
		for (index = 0; index < 4u; index++) {
			if (host_peek(bank + index * 4u) != (0xC0000000u | index))
				ok = 0;
			if (host_peek(bank + 16u + index * 4u) != (0x51000000u | index))
				ok = 0;
		}
		host_check(ok, "the bank's words");
	}
	base = 0;
	(void)base;
	(void)test_case("draw", before);
}

/* CREATE_COMPUTE_PIPELINES of one pipeline (its program came with GHCI_PROGRAM). */
static void
stage_compute_pipeline(
	uint32_t index,
	uint64_t id)
{
	host_record(GHCI_VK_CREATE_COMPUTE_PIPELINES, index);
	host_u64(DEVICE);
	host_u64(0);
	host_u32(1);
	host_u64(1);
	host_u32(29);
	host_u64(0);
	host_u32(0);
	host_u32(18);
	host_u64(0);
	host_u32(0);
	host_u32(0x20);
	host_u64(0x100);
	host_u64(5);
	host_u32(0x6E69616Du);
	host_u32(0);
	host_u64(0);
	host_u64(0x750);
	host_u64(0);
	host_u32(0xFFFFFFFFu);
	host_u64(0);
	host_u64(1);
	host_u64(id);
}

/*
 * A dispatch, an indirect dispatch, an event, an occlusion query and the
 * copy of its result: the program range, the bank (a storage buffer, push
 * constants, scratch memory), the indirect parameters, the event's word
 * and the query's copy.
 */
static void
test_compute(void)
{
	static const uint32_t cs_entries[] = {
		6, 0, 0, 0,		/* storage buffer: set 0, binding 0, bank 0 */
		7, 0, 0, 2,		/* push constants at bank 2 */
		14, 0, 4, 128,		/* scratch: bank word 4, 128 bytes per warp */
	};
	uint32_t index;
	uint32_t uop;
	uint32_t bank;
	uint32_t event;
	uint32_t pool;
	int before;

	before = host_failures;
	open_session();
	put_program(MEMORY_BASE + 0x700000u, 2, cs_entries, 3, 8);
	host_poke(MEMORY_BASE + 0x700000u + 32u, 64);
	host_poke(MEMORY_BASE + 0x6010u, 3);
	host_poke(MEMORY_BASE + 0x6014u, 2);
	host_poke(MEMORY_BASE + 0x6018u, 1);

	/* The objects. */
	host_frame_begin();
	stage_memory(0);
	stage_buffer(1, 0x720, 0x1000, 0x20);
	stage_bind_buffer(2, 0x720, 0x4000);
	stage_buffer(3, 0x721, 0x100, 0x100);
	stage_bind_buffer(4, 0x721, 0x6000);
	host_record(GHCI_VK_CREATE_DESCRIPTOR_SET_LAYOUT, 5);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(32);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u32(0);
	host_u32(7);
	host_u32(1);
	host_u32(0x20);
	host_u64(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x740);
	host_record(GHCI_VK_CREATE_DESCRIPTOR_POOL, 6);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(33);
	host_u64(0);
	host_u32(1);
	host_u32(4);
	host_u32(1);
	host_u64(1);
	host_u32(7);
	host_u32(4);
	host_u64(0);
	host_u64(1);
	host_u64(0x741);
	host_record(GHCI_VK_ALLOCATE_DESCRIPTOR_SETS, 7);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(34);
	host_u64(0);
	host_u64(0x741);
	host_u32(1);
	host_u64(1);
	host_u64(0x740);
	host_u64(1);
	host_u64(0x742);
	host_record(GHCI_VK_UPDATE_DESCRIPTOR_SETS, 8);
	host_u64(DEVICE);
	host_u32(1);
	host_u64(1);
	host_u32(35);
	host_u64(0);
	host_u64(0x742);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u32(7);
	host_u64(0);
	host_u64(1);
	host_u64(0x720);
	host_u64(0x100);
	host_u64(0x200);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_record(GHCI_VK_CREATE_PIPELINE_LAYOUT, 9);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(30);
	host_u64(0);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(0x740);
	host_u32(1);
	host_u64(1);
	host_u32(0x20);
	host_u32(0);
	host_u32(8);
	host_u64(0);
	host_u64(1);
	host_u64(0x750);
	host_record(GHCI_GPU_OP_PROGRAM, 10);
	host_u64(0x800);
	host_u32(2);
	host_u32(0x47534931u);
	host_u64(MEMORY_BASE + 0x700000u);
	host_u32(0x1000);
	host_u32(0);
	stage_compute_pipeline(11, 0x800);
	host_record(GHCI_VK_CREATE_EVENT, 12);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(10);
	host_u64(0);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x810);
	host_record(GHCI_VK_CREATE_QUERY_POOL, 13);
	host_u64(DEVICE);
	host_u64(1);
	host_u32(11);
	host_u64(0);
	host_u32(0);
	host_u32(0);
	host_u32(2);
	host_u32(0);
	host_u64(0);
	host_u64(1);
	host_u64(0x820);
	host_check(host_frame_run(TAG, 14) == 0, "the objects' frame");
	for (index = 0; index < 14u; index++) {
		if (host_result(index) != 0) {
			printf("  record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}
	event = host_result_aux(12);
	pool = host_result_aux(13);

	/* The recording: dispatch, indirect dispatch, event, query and its copy. */
	host_frame_begin();
	stage_pool_and_buffer(0, 0x780, 0x781);
	stage_begin(2, 0x781);
	host_cmd(GHCI_VK_CMD_BIND_PIPELINE);
	host_u64(0x781);
	host_u32(1);
	host_u64(0x800);
	host_cmd(GHCI_VK_CMD_BIND_DESCRIPTOR_SETS);
	host_u64(0x781);
	host_u32(1);
	host_u64(0x750);
	host_u32(0);
	host_u32(1);
	host_u64(1);
	host_u64(0x742);
	host_u32(0);
	host_u64(0);
	host_cmd(GHCI_VK_CMD_PUSH_CONSTANTS);
	host_u64(0x781);
	host_u64(0x750);
	host_u32(0x20);
	host_u32(0);
	host_u32(8);
	host_u64(8);
	host_u32(0xAAAA0001u);
	host_u32(0xAAAA0002u);
	host_cmd(GHCI_VK_CMD_DISPATCH);
	host_u64(0x781);
	host_u32(4);
	host_u32(1);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_DISPATCH_INDIRECT);
	host_u64(0x781);
	host_u64(0x721);
	host_u64(0x10);
	host_cmd(GHCI_VK_CMD_SET_EVENT);
	host_u64(0x781);
	host_u64(0x810);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_RESET_QUERY_POOL);
	host_u64(0x781);
	host_u64(0x820);
	host_u32(0);
	host_u32(2);
	host_cmd(GHCI_VK_CMD_BEGIN_QUERY);
	host_u64(0x781);
	host_u64(0x820);
	host_u32(1);
	host_u32(0);
	host_cmd(GHCI_VK_CMD_END_QUERY);
	host_u64(0x781);
	host_u64(0x820);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_COPY_QUERY_POOL_RESULTS);
	host_u64(0x781);
	host_u64(0x820);
	host_u32(0);
	host_u32(2);
	host_u64(0x721);
	host_u64(0x40);
	host_u64(16);
	host_u32(1u | 4u);
	stage_end(13, 0x781);
	stage_submit(14, 0x781);
	host_check(host_frame_run(TAG, 15) == 0, "the recording's frame");
	for (index = 0; index < 15u; index++) {
		if (host_result(index) != 0 && host_result(index) != -1) {
			printf("  record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* The program range and the two dispatches. */
	host_check(host_state[GHCI_S_CS_BASE] == MEMORY_BASE + 0x700000u + 64u + 48u, "CS_BASE");
	host_check(host_state[GHCI_S_WG_SIZE] == 64u, "WG_SIZE");
	uop = host_uop_find(GHCI_OP_DISPATCH, 0);
	host_check(uop < host_uop_count && host_uops[uop + 1u] == 4u, "the first DISPATCH");
	uop = host_uop_find(GHCI_OP_DISPATCH, uop + 1u);
	host_check(uop < host_uop_count && host_uops[uop + 1u] == 3u && host_uops[uop + 2u] == 2u &&
		   host_uops[uop + 3u] == 1u, "the indirect DISPATCH");

	/* The bank: {address, bytes} of the storage buffer, the push words, scratch. */
	uop = host_uop_find(GHCI_OP_LOAD_CONST, 0);
	host_check(uop < host_uop_count, "LOAD_CONST");
	if (uop < host_uop_count) {
		bank = host_uops[uop + 2u];
		host_check(host_peek(bank) == MEMORY_BASE + 0x4100u && host_peek(bank + 4u) == 0x200u, "the storage buffer's words");
		host_check(host_peek(bank + 8u) == 0xAAAA0001u && host_peek(bank + 12u) == 0xAAAA0002u, "the push words");
		host_check(host_peek(bank + 16u) != 0 && (host_peek(bank + 16u) & 63u) == 0, "the scratch address");
	}

	/* The event is set; the query's {count, availability} copied. */
	host_check(event != 0 && host_peek(event) == 1u, "the event's word");
	host_check(pool != 0, "the query pool's slots");
	host_check(host_peek(MEMORY_BASE + 0x6040u + 16u) == 7u && host_peek(MEMORY_BASE + 0x6040u + 24u) == 1u,
		   "the query's copy");
	host_check(host_peek(MEMORY_BASE + 0x6040u + 8u) == 0u, "the unavailable query's availability");
	(void)test_case("compute", before);
}

/*
 * The transfers of images: a depth/stencil clear, the stencil aspect to a
 * buffer (the built-in compute program), a scaled blit (the built-in
 * draw), a copy into an image.
 */
static void
test_transfer(void)
{
	uint32_t index;
	uint32_t ok;
	uint32_t words;
	uint32_t code;
	struct fw_object *image;
	int before;

	before = host_failures;
	open_session();
	host_frame_begin();
	stage_memory(0);
	stage_image(1, 0x700, FW_VK_FORMAT_D24_UNORM_S8_UINT, 16, 8, 0x23);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 2);
	host_u64(DEVICE);
	host_u64(0x700);
	host_u64(MEMORY);
	host_u64(0x100000);
	stage_image(3, 0x701, FW_VK_FORMAT_R8G8B8A8_UNORM, 32, 16, 0x7);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 4);
	host_u64(DEVICE);
	host_u64(0x701);
	host_u64(MEMORY);
	host_u64(0x200000);
	stage_image(5, 0x702, FW_VK_FORMAT_B8G8R8A8_UNORM, 64, 32, 0x16);
	host_record(GHCI_VK_BIND_IMAGE_MEMORY, 6);
	host_u64(DEVICE);
	host_u64(0x702);
	host_u64(MEMORY);
	host_u64(0x300000);
	stage_buffer(7, 0x720, 0x10000, 3);
	stage_bind_buffer(8, 0x720, 0x400000);
	stage_pool_and_buffer(9, 0x780, 0x781);
	stage_begin(11, 0x781);
	host_cmd(GHCI_VK_CMD_CLEAR_DEPTH_STENCIL_IMAGE);
	host_u64(0x781);
	host_u64(0x700);
	host_u32(7);
	host_u64(1);
	host_u32(0x3F800000u);
	host_u32(5);
	host_u32(1);
	host_u64(1);
	host_u32(FW_ASPECT_DEPTH | FW_ASPECT_STENCIL);
	host_u32(0);
	host_u32(1);
	host_u32(0);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_COPY_IMAGE_TO_BUFFER);
	host_u64(0x781);
	host_u64(0x700);
	host_u32(6);
	host_u64(0x720);
	host_u32(1);
	host_u64(1);
	host_u64(0x100);
	host_u32(0);
	host_u32(0);
	host_u32(FW_ASPECT_STENCIL);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(16);
	host_u32(8);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_COPY_BUFFER_TO_IMAGE);
	host_u64(0x781);
	host_u64(0x720);
	host_u64(0x701);
	host_u32(7);
	host_u32(1);
	host_u64(1);
	host_u64(0x1000);
	host_u32(0);
	host_u32(0);
	host_u32(FW_ASPECT_COLOR);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(32);
	host_u32(16);
	host_u32(1);
	host_cmd(GHCI_VK_CMD_BLIT_IMAGE);
	host_u64(0x781);
	host_u64(0x701);
	host_u32(6);
	host_u64(0x702);
	host_u32(7);
	host_u32(1);
	host_u64(1);
	host_u32(FW_ASPECT_COLOR);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u64(2);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(32);
	host_u32(16);
	host_u32(1);
	host_u32(FW_ASPECT_COLOR);
	host_u32(0);
	host_u32(0);
	host_u32(1);
	host_u64(2);
	host_u32(64);
	host_u32(0);
	host_u32(0);
	host_u32(0);
	host_u32(32);
	host_u32(1);
	host_u32(1);
	stage_end(16, 0x781);
	stage_submit(17, 0x781);
	for (index = 0; index < 32u * 16u; index++)
		host_poke(MEMORY_BASE + 0x401000u + index * 4u, 0x01020300u + index);
	host_check(host_frame_run(TAG, 18) == 0, "the frame");
	for (index = 0; index < 18u; index++) {
		if (host_result(index) != 0 && host_result(index) != -1) {
			printf("  record %u: %d\n", index, host_result(index));
			host_check(0, "a record failed");
		}
	}

	/* The clear: depth 1.0 (0xFFFFFF) and stencil 5 in every texel (rows of 16). */
	image = fw_object_find(TAG, 0x700, FW_OBJ_IMAGE);
	ok = image != NULL;
	for (index = 0; ok && index < 16u * 8u; index++) {
		if (host_peek(image->a + index * 4u) != 0x05FFFFFFu)
			ok = 0;
	}
	host_check(ok, "the depth/stencil clear");

	/* The stencil copy is the built-in compute program; the blit the built-in draw. */
	code = fw_builtin_program(FW_PROGRAM_S8_FROM_IMAGE, &words);
	host_check(host_uops_of(GHCI_OP_DISPATCH) == 1u, "one DISPATCH");
	host_check(host_state[GHCI_S_CS_BASE] == code, "the stencil program");
	code = fw_builtin_program(FW_PROGRAM_BLIT_VS, &words);
	host_check(host_uops_of(GHCI_OP_DRAW) == 1u, "one DRAW for the blit");
	host_check(host_state[GHCI_S_VS_BASE] == code, "the blit's vertex program");
	host_check(host_state[GHCI_S_RT_FORMATS] == FW_VK_FORMAT_B8G8R8A8_UNORM, "the blit's target format");
	host_check(host_state[GHCI_S_TEX(0, GHCI_TEX_FORMAT)] == FW_VK_FORMAT_R8G8B8A8_UNORM, "the blit's source format");
	host_check((host_state[GHCI_S_TEX(0, GHCI_TEX_SAMPLER)] & (GHCI_SAMP_UNNORM | GHCI_SAMP_MAG_LINEAR)) ==
		   (GHCI_SAMP_UNNORM | GHCI_SAMP_MAG_LINEAR), "the blit's sampler");

	/* The copy into the colour image. */
	image = fw_object_find(TAG, 0x701, FW_OBJ_IMAGE);
	ok = image != NULL;
	for (index = 0; ok && index < 32u * 16u; index++) {
		if (host_peek(image->a + index * 4u) != 0x01020300u + index)
			ok = 0;
	}
	host_check(ok, "the copy into the image");
	(void)test_case("transfer", before);
}
