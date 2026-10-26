/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The host test of the GHCI driver's Vulkan executor
 * (src/drivers/gpu/ghci/vk/) against the model GPU of
 * ghci-driver-host-test.c, whose command processor stands in for the
 * firmware: it takes the GHCI control gpu-ops and writes a result for
 * every record of a frame.
 *
 * Each case builds a frame of the Kei GPU command protocol the way
 * libvulkan frames it (the reply stream, the command, the seek to the
 * trailer, the trailer), submits it through the node's operations, and
 * compares what the driver staged for the firmware (the records after a
 * frame's result page) and what it wrote into the reply blob with what
 * libvulkan reads.  A case on a model with the PROT capability checks
 * session protection's side in the driver (docs/ghci.md section 11.6).
 */

#define GHCI_MODEL_ONLY 1
#define MODEL_LOCAL_BYTES		(64U << 20)
#define MODEL_WINDOW_BYTES		(32U << 20)
#define MODEL_HOST_BYTES		(64U << 20)

#include "ghci-driver-host-test.c"

#include "drivers/gpu/ghci/frame.h"
#include "drivers/gpu/ghci/vk/vk.h"
#include "uapi/gpu-job.h"

/* The reply blob's bytes, and where libvulkan puts the trailer: its last 20 bytes. */
#define REPLY_BYTES			4096U
#define TRAILER_AT			(REPLY_BYTES - 20U)

/* The most words of a frame a case builds. */
#define FRAME_WORDS			512U

/* The version the trailer reports. */
#define TRAILER_VERSION			((1U << 22) | (1U << 12))

/* The words of the stand-in program the fake compiler makes: a GSI1 header and one instruction. */
#define FAKE_PROGRAM_WORDS		18U

/* The identities the cases use. */
#define ID_INSTANCE			0x101U
#define ID_PHYSICAL			0x102U
#define ID_DEVICE			0x103U
#define ID_QUEUE			0x104U
#define ID_BUFFER			0x105U
#define ID_MEMORY			0x106U
#define ID_FENCE			0x107U
#define ID_POOL				0x108U
#define ID_COMMAND			0x109U
#define ID_MODULE			0x10aU
#define ID_PIPELINE			0x10bU
#define ID_EVENT			0x10cU
#define ID_HOST_MEMORY			0x10dU

/*
 * One frame being built: its words, and the identity of the reply blob
 * it selects.
 */
struct frame {
	uint32_t words[FRAME_WORDS];
	uint32_t count;
	uint32_t reply_id;
};

static void put32(struct frame *frame, uint32_t value);
static void put64(struct frame *frame, uint64_t value);
static void frame_begin(struct frame *frame, uint32_t reply_id);
static void frame_end(struct frame *frame);
static void command(struct frame *frame, uint32_t opcode, uint32_t flags);
static int submit(void *opaque, const struct frame *frame);
static uint32_t reply_word(const struct ghci_allocation *blob, uint32_t index);
static int trailer_ok(const struct ghci_allocation *blob);
static const uint32_t *staged(uint32_t *records);
static int fake_compile(const uint32_t *words, size_t word_count, enum drv_gpu_shader_stage stage, const struct ghci_gsi1_options *options, struct ghci_gsi1_program **program, struct ghci_gsi1_diagnostic *diagnostic);
static void fake_release(struct ghci_gsi1_program *program);
static void test_executor(void);
static void test_protection(void);
static const struct model_control *control_find(uint32_t opcode, unsigned from, unsigned *at);

/* The stand-in compiler: every module compiles to the same small program. */
static const struct ghci_isa_backend fake_isa = {
	GHCI_FOURCC('G', 'S', 'I', '1'), "GSI1", fake_compile, fake_release
};

/* How many programs the stand-in compiler made and gave back, and the words it was last given. */
static unsigned fake_compiles;
static uint32_t fake_registers;
static unsigned fake_releases;
static uint32_t fake_words[64];
static size_t fake_word_count;

/*
 * Runs the executor's cases on a discrete model GPU with firmware.
 */
int
main(void)
{
	/* The cases. */
	test_executor();
	test_protection();

	/* Reports the counts of the checks. */
	printf("ghci-vk-host-test: %u passed, %u failed\n", checks_passed, checks_failed);

	/* A failed check fails the test. */
	if (checks_failed != 0U)
		return 1;

	/* Succeeded: every check held. */
	return 0;
}

/* Appends a 32-bit word to a frame. */
static void
put32(
	struct frame *frame,
	uint32_t value)
{
	/* One more word, while the frame has room. */
	if (frame->count < FRAME_WORDS)
		frame->words[frame->count] = value;
	frame->count++;
}

/* Appends a 64-bit value to a frame, the low word first. */
static void
put64(
	struct frame *frame,
	uint64_t value)
{
	/* Two words. */
	put32(frame, (uint32_t)value);
	put32(frame, (uint32_t)(value >> 32));
}

/* Starts a frame: the reply stream in the reply blob, its whole region. */
static void
frame_begin(
	struct frame *frame,
	uint32_t reply_id)
{
	/* SET_REPLY_STREAM [u64 1][u32 resource][u64 0][u64 capacity]. */
	frame->count = 0U;
	frame->reply_id = reply_id;
	command(frame, GPU_OP_SET_REPLY_STREAM, 0U);
	put64(frame, 1U);
	put32(frame, reply_id);
	put64(frame, 0U);
	put64(frame, REPLY_BYTES);
}

/* Ends a frame: the seek to the trailer and the trailer. */
static void
frame_end(
	struct frame *frame)
{
	/* SEEK_REPLY_STREAM to the last 20 bytes, then ENUMERATE_INSTANCE_VERSION [u64 1] with a reply. */
	command(frame, GPU_OP_SEEK_REPLY_STREAM, 0U);
	put64(frame, TRAILER_AT);
	command(frame, GPU_OP_ENUMERATE_INSTANCE_VERSION, GPU_OP_FLAG_REPLY);
	put64(frame, 1U);
}

/* Appends a command's header. */
static void
command(
	struct frame *frame,
	uint32_t opcode,
	uint32_t flags)
{
	/* [u32 number][u32 flags]. */
	put32(frame, opcode);
	put32(frame, flags);
}

/* Submits a frame through the node as libvulkan does: with the context's fence. */
static int
submit(
	void *opaque,
	const struct frame *frame)
{
	int error;

	/* The core's call. */
	error = core_ops->commands->submit(core_private, opaque, frame->words, frame->count * 4U, GPU_COMMAND_CONTEXT_FENCE, 0U, (struct drv_gpu_completion *)(void *)&core_completions);

	/* Reports what the node said. */
	return error;
}

/* Reads a word of the reply blob. */
static uint32_t
reply_word(
	const struct ghci_allocation *blob,
	uint32_t index)
{
	uint32_t word;

	/* The word at its place. */
	memcpy(&word, blob->view + index * 4U, 4U);

	/* Reports it. */
	return word;
}

/* Reports whether the trailer is complete: [137][0][u64 1][version]. */
static int
trailer_ok(
	const struct ghci_allocation *blob)
{
	/* Each word of the trailer. */
	if (reply_word(blob, TRAILER_AT / 4U) != GPU_OP_ENUMERATE_INSTANCE_VERSION)
		return 0;
	if (reply_word(blob, TRAILER_AT / 4U + 1U) != 0U)
		return 0;
	if (reply_word(blob, TRAILER_AT / 4U + 2U) != 1U)
		return 0;
	if (reply_word(blob, TRAILER_AT / 4U + 3U) != 0U)
		return 0;
	if (reply_word(blob, TRAILER_AT / 4U + 4U) != TRAILER_VERSION)
		return 0;

	/* Succeeded: the trailer is complete. */
	return 1;
}

/* Reports the records of the last frame the model took, and their count. */
static const uint32_t *
staged(
	uint32_t *records)
{
	const uint8_t *bytes;

	/* The model's memory at the frame's staging address. */
	*records = model_frame_records;
	bytes = model_memory(model_frame_staging, model_frame_bytes);

	/* Reports the words. */
	return (const uint32_t *)(const void *)bytes;
}

/* The stand-in compiler: a GSI1 header of the stage, an empty interface table and one instruction. */
static int
fake_compile(
	const uint32_t *words,
	size_t word_count,
	enum drv_gpu_shader_stage stage,
	const struct ghci_gsi1_options *options,
	struct ghci_gsi1_program **program,
	struct ghci_gsi1_diagnostic *diagnostic)
{
	struct ghci_gsi1_program *made;

	(void)diagnostic;

	/* Keeps the registers it may use and the words it was given (the specialized module). */
	fake_registers = options->registers;
	fake_word_count = word_count;
	if (word_count <= 64U)
		memcpy(fake_words, words, word_count * 4U);

	/* The record and its words. */
	made = calloc(1U, sizeof(*made));
	made->words = calloc(FAKE_PROGRAM_WORDS, 4U);
	made->word_count = FAKE_PROGRAM_WORDS;
	made->stage = stage;
	made->words[0] = 0x47534931U;
	made->words[1] = 1U;
	made->words[2] = (uint32_t)stage;
	made->words[4] = 2U;
	made->words[5] = 16U;
	made->words[10] = 16U;
	made->words[11] = 0U;
	fake_compiles++;

	/* Succeeded: the program. */
	*program = made;
	return 0;
}

/* Frees a stand-in program. */
static void
fake_release(
	struct ghci_gsi1_program *program)
{
	/* The words and the record. */
	free(program->words);
	free(program);
	fake_releases++;
}

/*
 * The cases: the capset, the session's open, driver answers, relayed
 * objects, the memory and its blob, a submission and its fence and job,
 * a recording, a pipeline, refusals, a reset and the close.
 */
static void
test_executor(void)
{
	static struct ghci_device device;
	static struct frame frame;
	struct gpu_blob_create blob_request;
	struct gpu_capset capset;
	struct gpu_info info;
	struct drv_gpu_mapping mapping;
	struct ghci_allocation *reply;
	struct ghci_allocation *alias;
	struct ghci_allocation *stream;
	struct ghci_allocation *imported;
	struct ghci_allocation *second_reply;
	struct ghci_vk_object *object;
	struct ghci_session *session;
	const uint32_t *records;
	uint32_t record_count;
	uint32_t reply_id;
	uint32_t alias_id;
	uint32_t stream_id;
	uint32_t import_id;
	uint32_t slots[8];
	uint32_t second_reply_id;
	uint32_t memory_address;
	uint32_t memory_bytes;
	unsigned completions;
	unsigned frames;
	unsigned errors;
	unsigned index;
	void *object_pointer;
	void *opaque;
	void *second;
	void *shared;
	void *token;
	int error;

	/* A discrete model GPU whose command processor has firmware, with a shader unit. */
	model_setup_window(1);
	model_registers[GHCI_CAPS / 4U] |= GHCI_CAPS_FIRMWARE | GHCI_CAPS_SHADER | (5U << 4);
	model_registers[GHCI_CAPS2 / 4U] = 1U | (16U << 8) | (16U << 16) | (4U << 24) | (4U << 28);
	model_registers[GHCI_ISA_ID / 4U] = GHCI_FOURCC('G', 'S', 'I', '1');
	model_registers[GHCI_RESIDENT_WARPS / 4U] = (64U << 16) | 16U;
	model_isa = &fake_isa;
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;

	/* The start lends the firmware its heap and the resident warps. */
	error = ghci_device_start(&device);
	expect(error == 0, "vk start");
	expect(device.vk != NULL, "vk executor made");
	expect(model_last_control == GPU_OP_GHCI_HEAP, "vk heap lent to the firmware");
	expect(device.vk->warps == 16U, "vk resident warps read");
	expect(device.vk->registers == 64U, "vk registers per lane read");
	expect(device.vk->heap_ready, "vk heap taken");
	expect((model_irq_enable & GHCI_IRQ_RESULT) != 0U, "vk result interrupt enabled");

	/* The node's capabilities are what libvulkan needs, with the jobs. */
	error = core_ops->open(core_private, &opaque);
	session = opaque;
	expect(error == 0, "vk open");
	expect(session->vk != NULL && session->vk->opened, "vk session opened by the firmware");
	expect(model_last_control == GPU_OP_GHCI_SESSION_OPEN, "vk SESSION_OPEN sent");
	error = core_ops->get_info(core_private, opaque, &info);
	expect(error == 0, "vk info");
	expect((info.capabilities & (GPU_CAP_CAPSET | GPU_CAP_BLOB | GPU_CAP_TRANSFER | GPU_CAP_COMMAND | GPU_CAP_MAPPING)) ==
	    (GPU_CAP_CAPSET | GPU_CAP_BLOB | GPU_CAP_TRANSFER | GPU_CAP_COMMAND | GPU_CAP_MAPPING), "vk libvulkan's capabilities");
	expect((info.capabilities & (GPU_CAP_NOTIFICATION | GPU_CAP_JOB | GPU_CAP_JOB_CAPACITY)) ==
	    (GPU_CAP_NOTIFICATION | GPU_CAP_JOB | GPU_CAP_JOB_CAPACITY), "vk queued frames and jobs");

	/* The capset: id 4, the native renderer's 176 bytes, wire 1, timelines, the vendor suffix. */
	memset(&capset, 0, sizeof(capset));
	capset.capset_id = 4U;
	capset.capacity = GPU_CAPSET_MAX;
	error = core_ops->get_capset(core_private, opaque, &capset);
	expect(error == 0 && capset.bytes == 176U, "vk capset");
	expect(capset.data[0] == 1U && capset.data[152] == 1U, "vk capset wire and timelines");
	expect(capset.data[160] == 0x53U && capset.data[164] == 7U, "vk capset vendor suffix");

	/* The reply blob, mappable, as libvulkan makes it. */
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = REPLY_BYTES;
	blob_request.flags = GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &reply_id);
	reply = object_pointer;
	expect(error == 0 && reply->view != NULL, "vk reply blob");

	/* A frame of driver answers only completes at once: vkCreateInstance. */
	completions = core_completions;
	frames = model_frames;
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_INSTANCE, GPU_OP_FLAG_REPLY);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_INSTANCE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk instance frame taken");
	expect(core_completions == completions + 1U && core_last_completion_error == 0, "vk instance frame completed at once");
	expect(model_frames == frames, "vk instance frame not sent to the firmware");
	expect(reply_word(reply, 0U) == GPU_OP_CREATE_INSTANCE && reply_word(reply, 1U) == 0U, "vk instance reply result");
	expect(reply_word(reply, 2U) == 1U && reply_word(reply, 4U) == ID_INSTANCE, "vk instance reply identity");
	expect(trailer_ok(reply), "vk instance trailer");

	/* The physical device, its queue family and its memory. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_ENUMERATE_PHYSICAL_DEVICES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_INSTANCE);
	put64(&frame, 1U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put64(&frame, ID_PHYSICAL);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk enumerate taken");
	expect(reply_word(reply, 1U) == 0U && reply_word(reply, 4U) == 1U, "vk one physical device");
	expect(reply_word(reply, 7U) == ID_PHYSICAL, "vk physical identity echoed");

	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_PHYSICAL_DEVICE_QUEUE_FAMILY_PROPERTIES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_PHYSICAL);
	put64(&frame, 1U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk families taken");
	expect(reply_word(reply, 3U) == 1U && reply_word(reply, 6U) == 7U && reply_word(reply, 7U) == 1U, "vk one family of one queue that draws, computes and copies");

	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_PHYSICAL_DEVICE_MEMORY_PROPERTIES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_PHYSICAL);
	put64(&frame, 1U);
	put64(&frame, 32U);
	put64(&frame, 16U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk memory properties taken");
	expect(reply_word(reply, 3U) == 2U, "vk two memory types");
	expect(reply_word(reply, 6U) == 1U && reply_word(reply, 7U) == 0U, "vk type 0 is device local, in heap 0");
	expect(reply_word(reply, 8U) == 6U && reply_word(reply, 9U) == 1U, "vk type 1 is host visible and coherent, in heap 1");
	expect(reply_word(reply, 70U) == 2U, "vk two heaps on a discrete GPU");
	expect(reply_word(reply, 73U) == MODEL_LOCAL_BYTES && reply_word(reply, 75U) == 1U, "vk heap 0 is the local memory, device local");
	expect(reply_word(reply, 76U) == (uint32_t)GHCI_RESOURCE_MAX_BYTES && reply_word(reply, 78U) == 0U, "vk heap 1 is host memory");

	/* The device and its queue on timeline 1. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_DEVICE, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_PHYSICAL);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_DEVICE);
	command(&frame, GPU_OP_GET_DEVICE_QUEUE2, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 1000145003U);
	put64(&frame, 1U);
	put32(&frame, GPU_OP_RECORD_QUEUE_TIMELINE);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_QUEUE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk device and queue taken");
	expect(reply_word(reply, 1U) == 0U && reply_word(reply, 4U) == ID_DEVICE, "vk device made");
	expect(reply_word(reply, 6U) == GPU_OP_GET_DEVICE_QUEUE2 && reply_word(reply, 9U) == ID_QUEUE, "vk queue reported");
	expect((session->vk->timelines & 2U) != 0U, "vk queue's timeline 1 is the session's");

	/* A buffer is relayed: one record, the reply waits for the firmware's result. */
	memset(reply->view, 0, REPLY_BYTES);
	completions = core_completions;
	frames = model_frames;
	model_paused = 1;
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_BUFFER, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 12U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 4096U);
	put32(&frame, 0x82U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_BUFFER);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk buffer frame taken");
	expect(core_completions == completions, "vk buffer frame waits for the firmware");
	expect(reply_word(reply, 1U) == GHCI_VK_RESULT_PENDING, "vk buffer result pending");
	expect(reply_word(reply, 2U) == 1U && reply_word(reply, 4U) == ID_BUFFER, "vk buffer identity laid down");
	expect(!trailer_ok(reply), "vk buffer trailer not yet");
	model_paused = 0;
	model_run();
	ghci_vk_service(&device);
	expect(model_frames == frames + 1U, "vk buffer frame sent");
	records = staged(&record_count);
	expect(record_count == 1U && records != NULL, "vk buffer one record");
	if (records != NULL) {
		expect(records[0] == GPU_OP_CREATE_BUFFER && records[1] == GPU_OP_FLAG_REPLY && records[2] == 0U, "vk buffer record head");
		expect(memcmp(&records[3], &frame.words[11], 21U * 4U) == 0, "vk buffer arguments as they came");
		expect(model_frame_bytes == 12U + 21U * 4U, "vk buffer record's bytes");
	}
	expect(core_completions == completions + 1U && core_last_completion_error == 0, "vk buffer frame completed after the results");
	expect(reply_word(reply, 1U) == 0U, "vk buffer result filled");
	expect(trailer_ok(reply), "vk buffer trailer");
	object = ghci_vk_object_find(session->vk, GHCI_VK_BUFFER, ID_BUFFER);
	expect(object != NULL && object->as.buffer.size == 4096U, "vk buffer kept");

	/* Its memory requirements are the driver's. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_BUFFER_MEMORY_REQUIREMENTS, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_BUFFER);
	put64(&frame, 1U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk requirements taken");
	expect(reply_word(reply, 3U) == 4096U && reply_word(reply, 5U) == 64U && reply_word(reply, 7U) == 3U, "vk buffer requirements");

	/* Memory: the driver's allocation and GHCI_MEMORY instead of the command. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_ALLOCATE_MEMORY, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 5U);
	put64(&frame, 0U);
	put64(&frame, 8192U);
	put32(&frame, 1U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_MEMORY);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk memory frame taken");
	records = staged(&record_count);
	object = ghci_vk_object_find(session->vk, GHCI_VK_MEMORY, ID_MEMORY);
	expect(object != NULL && object->as.memory.allocation != NULL, "vk memory allocated");
	memory_address = 0U;
	memory_bytes = 0U;
	if (object != NULL && object->as.memory.allocation != NULL) {
		memory_address = object->as.memory.allocation->gpu_address;
		memory_bytes = object->as.memory.allocation->bytes;
	}
	expect(records != NULL && records[0] == GPU_OP_GHCI_MEMORY, "vk GHCI_MEMORY staged");
	if (records != NULL) {
		expect(records[3] == ID_MEMORY && records[4] == 0U && records[5] == memory_address, "vk GHCI_MEMORY names the memory and its address");
		expect(records[7] == memory_bytes && records[9] == 1U, "vk GHCI_MEMORY bytes and host visibility");
	}
	expect(reply_word(reply, 0U) == GPU_OP_ALLOCATE_MEMORY && reply_word(reply, 1U) == 0U && reply_word(reply, 4U) == ID_MEMORY, "vk memory reply");

	/* The memory's blob shows the same memory and keeps it. */
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = 8192U;
	blob_request.blob_id = ID_MEMORY;
	blob_request.flags = GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &alias_id);
	alias = object_pointer;
	expect(error == 0 && alias_id == memory_address, "vk memory blob named by the memory's address");
	error = core_ops->resource_map(core_private, opaque, alias, &mapping);
	expect(error == 0 && mapping.address == alias->view && alias->backing != NULL, "vk memory blob maps the memory");
	blob_request.blob_id = 0x999U;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &alias_id);
	expect(error == EINVAL, "vk blob of an unknown memory refused");

	/* A fence, a recorded fill, and the submission that signals the fence. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_FENCE, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 8U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_FENCE);
	command(&frame, GPU_OP_BEGIN_COMMAND_BUFFER, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_COMMAND);
	put64(&frame, 1U);
	put32(&frame, 42U);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put64(&frame, 0U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk fence and begin taken");
	records = staged(&record_count);
	expect(record_count == 1U && records != NULL && records[0] == GPU_OP_BEGIN_COMMAND_BUFFER, "vk only the begin is relayed");
	expect(reply_word(reply, 4U) == ID_FENCE && reply_word(reply, 6U) == GPU_OP_BEGIN_COMMAND_BUFFER && reply_word(reply, 7U) == 0U, "vk fence made, begin's result");

	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CMD_FILL_BUFFER, 0U);
	put64(&frame, ID_COMMAND);
	put64(&frame, ID_BUFFER);
	put64(&frame, 0U);
	put64(&frame, 4096U);
	put32(&frame, 0xdeadbeefU);
	command(&frame, GPU_OP_END_COMMAND_BUFFER, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_COMMAND);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk recording taken");
	records = staged(&record_count);
	expect(record_count == 2U && records != NULL, "vk recording: two records");
	if (records != NULL) {
		expect(records[0] == GPU_OP_CMD_FILL_BUFFER && records[2] == 0U && records[3] == ID_COMMAND, "vk recorded fill");
		expect(records[3U + 9U] == GPU_OP_END_COMMAND_BUFFER && records[3U + 9U + 2U] == 1U, "vk end after it, result 1");
	}
	expect(reply_word(reply, 0U) == GPU_OP_END_COMMAND_BUFFER && reply_word(reply, 1U) == 0U, "vk end's reply");

	error = core_ops->jobs->reserve(core_private, opaque, 1U, (struct drv_gpu_completion *)(void *)&core_completions, &token);
	expect(error == 0 && token != NULL, "vk job reserved on timeline 1");
	error = core_ops->jobs->reserve(core_private, opaque, 2U, (struct drv_gpu_completion *)(void *)&core_completions, &object_pointer);
	expect(error == EINVAL, "vk job on a timeline no queue has refused");

	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_QUEUE_SUBMIT, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_QUEUE);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, 4U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put64(&frame, ID_COMMAND);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, ID_FENCE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0, "vk submission taken");
	object = ghci_vk_object_find(session->vk, GHCI_VK_FENCE, ID_FENCE);
	expect(object != NULL && object->as.fence.pending, "vk fence bound to the submission");
	completions = core_completions;
	error = core_ops->jobs->commit(core_private, opaque, token, (struct drv_gpu_completion *)(void *)&core_completions);
	expect(error == 0, "vk job committed");
	ghci_vk_service(&device);
	expect(core_completions >= completions + 1U, "vk job completed once the fence passed");
	expect(reply_word(reply, 0U) == GPU_OP_QUEUE_SUBMIT && reply_word(reply, 1U) == 0U, "vk submission accepted");

	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_FENCE_STATUS, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_FENCE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0 && reply_word(reply, 1U) == 0U, "vk fence signaled");

	/* A pipeline: the module is the driver's, the program goes before the create. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_SHADER_MODULE, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 16U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 24U);
	put64(&frame, 6U);
	put32(&frame, 0x07230203U);
	put32(&frame, 0x00010000U);
	put32(&frame, 0U);
	put32(&frame, 8U);
	put32(&frame, 0U);
	put32(&frame, (3U << 16) | 50U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_MODULE);
	command(&frame, GPU_OP_CREATE_COMPUTE_PIPELINES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, 29U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 18U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0x20U);
	put64(&frame, ID_MODULE);
	put64(&frame, 5U);
	put32(&frame, 0x6e69616dU);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0x200U);
	put64(&frame, 0U);
	put32(&frame, 0xffffffffU);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_PIPELINE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk pipeline frame taken");
	expect(fake_compiles == 1U && fake_releases == 1U, "vk one stage compiled and its record freed");
	expect(fake_registers == 64U, "vk compile within the GPU's registers per lane");
	records = staged(&record_count);
	expect(record_count == 2U && records != NULL && records[0] == GPU_OP_GHCI_PROGRAM, "vk GHCI_PROGRAM before the create");
	if (records != NULL) {
		expect(records[3] == ID_PIPELINE && records[5] == 2U && records[6] == 0x47534931U, "vk program's pipeline, stage and ISA");
		expect(records[9] == FAKE_PROGRAM_WORDS * 4U, "vk program's bytes");
		expect(memcmp(model_memory(records[7], 8U), "1ISG", 4U) == 0, "vk program copied into GPU memory");
		expect(records[11] == GPU_OP_CREATE_COMPUTE_PIPELINES && records[13] == 1U, "vk create relayed after it");
	}
	expect(reply_word(reply, 4U) == ID_MODULE, "vk module made");
	expect(reply_word(reply, 6U) == GPU_OP_CREATE_COMPUTE_PIPELINES && reply_word(reply, 7U) == 0U, "vk pipeline result");
	expect(reply_word(reply, 8U) == 1U && reply_word(reply, 10U) == ID_PIPELINE, "vk pipeline identity");
	object = ghci_vk_object_find(session->vk, GHCI_VK_PIPELINE, ID_PIPELINE);
	expect(object != NULL && object->as.pipeline.program_count == 1U, "vk pipeline holds its program");

	/* A graphics pipeline of two stages: both programs before the create, the fragment one compiled first. */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_GRAPHICS_PIPELINES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, 28U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 2U);
	put64(&frame, 2U);
	for (index = 0U; index < 2U; index++) {
		put32(&frame, 18U);
		put64(&frame, 0U);
		put32(&frame, 0U);
		put32(&frame, index == 0U ? 0x1U : 0x10U);
		put64(&frame, ID_MODULE);
		put64(&frame, 5U);
		put32(&frame, 0x6e69616dU);
		put32(&frame, 0U);
		put64(&frame, 0U);
	}
	put64(&frame, 0U);
	put64(&frame, 1U);
	put32(&frame, 20U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put32(&frame, 23U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0x3f800000U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 0x200U);
	put64(&frame, 0x300U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put32(&frame, 0xffffffffU);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_PIPELINE + 0x100U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk graphics pipeline frame taken");
	expect(fake_compiles == 3U && fake_releases == 3U, "vk two stages compiled");
	records = staged(&record_count);
	expect(record_count == 3U && records != NULL, "vk two programs and the create");
	if (records != NULL) {
		expect(records[0] == GPU_OP_GHCI_PROGRAM && records[5] == 0U, "vk vertex program");
		expect(records[11] == GPU_OP_GHCI_PROGRAM && records[16] == 1U, "vk fragment program");
		expect(records[22] == GPU_OP_CREATE_GRAPHICS_PIPELINES, "vk graphics create relayed");
	}
	expect(reply_word(reply, 1U) == 0U && reply_word(reply, 4U) == ID_PIPELINE + 0x100U, "vk graphics pipeline made");

	/*
	 * Specialization: a module with OpDecorate %5 SpecId 7, %5 =
	 * OpSpecConstant %int 3 and %6 = OpSpecConstantTrue %bool, a compute
	 * pipeline that gives SpecId 7 the value 42; the compiler sees
	 * OpConstant %int 42 and OpConstantTrue.
	 */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_SHADER_MODULE, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 16U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 16U * 4U);
	put64(&frame, 16U);
	put32(&frame, 0x07230203U);
	put32(&frame, 0x00010000U);
	put32(&frame, 0U);
	put32(&frame, 8U);
	put32(&frame, 0U);
	put32(&frame, (4U << 16) | 71U);
	put32(&frame, 5U);
	put32(&frame, 1U);
	put32(&frame, 7U);
	put32(&frame, (4U << 16) | 50U);
	put32(&frame, 2U);
	put32(&frame, 5U);
	put32(&frame, 3U);
	put32(&frame, (3U << 16) | 48U);
	put32(&frame, 3U);
	put32(&frame, 6U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_MODULE + 0x200U);
	command(&frame, GPU_OP_CREATE_COMPUTE_PIPELINES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 0U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, 29U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 18U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0x20U);
	put64(&frame, ID_MODULE + 0x200U);
	put64(&frame, 5U);
	put32(&frame, 0x6e69616dU);
	put32(&frame, 0U);
	put64(&frame, 1U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, 7U);
	put32(&frame, 0U);
	put64(&frame, 4U);
	put64(&frame, 4U);
	put64(&frame, 4U);
	put32(&frame, 42U);
	put64(&frame, 0x200U);
	put64(&frame, 0U);
	put32(&frame, 0xffffffffU);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_PIPELINE + 0x200U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0 && reply_word(reply, 7U) == 0U, "vk specialized pipeline made");
	expect(fake_word_count == 16U, "vk compiler given the whole module");
	expect(fake_words[9] == ((4U << 16) | 43U) && fake_words[12] == 42U, "vk OpSpecConstant became OpConstant 42");
	expect(fake_words[13] == ((3U << 16) | 41U), "vk OpSpecConstantTrue became OpConstantTrue");

	/* Queries: the results are copied from the pool's slots in the heap when the frame completes. */
	memset(reply->view, 0, REPLY_BYTES);
	model_aux[0] = device.vk->heap->gpu_address + 1024U;
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_QUERY_POOL, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 11U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 0U);
	put32(&frame, 2U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_POOL + 0x100U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	model_aux[0] = 0U;
	expect(error == 0 && reply_word(reply, 1U) == 0U, "vk query pool made");
	memset(slots, 0, sizeof(slots));
	slots[0] = 123U;
	slots[2] = 1U;
	memcpy(device.vk->heap->view + 1024U, slots, sizeof(slots));
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_QUERY_POOL_RESULTS, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_POOL + 0x100U);
	put32(&frame, 0U);
	put32(&frame, 2U);
	put64(&frame, 16U);
	put64(&frame, 16U);
	put64(&frame, 8U);
	put32(&frame, 4U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0, "vk query results taken");
	expect(reply_word(reply, 1U) == 1U, "vk second query not ready");
	expect(reply_word(reply, 2U) == 16U && reply_word(reply, 4U) == 123U && reply_word(reply, 5U) == 1U, "vk first query's result and availability");
	expect(reply_word(reply, 7U) == 0U, "vk second query's availability");

	/* An event: the firmware's aux is its address in the heap, where the host sets it. */
	memset(reply->view, 0, REPLY_BYTES);
	model_aux[0] = device.vk->heap->gpu_address + 256U;
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_EVENT, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 10U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_EVENT);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	model_aux[0] = 0U;
	object = ghci_vk_object_find(session->vk, GHCI_VK_EVENT, ID_EVENT);
	expect(error == 0 && object != NULL && object->as.heap.known, "vk event placed by the firmware");
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_SET_EVENT, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_EVENT);
	command(&frame, GPU_OP_GET_EVENT_STATUS, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_EVENT);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0 && reply_word(reply, 1U) == 0U && reply_word(reply, 3U) == 3U, "vk event set and read set");
	expect(device.vk->heap->view[256] == 1U, "vk event's word in the heap");

	/* A stream in a blob is decoded as the frame's own commands. */
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = 4096U;
	blob_request.flags = GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &stream_id);
	stream = object_pointer;
	expect(error == 0, "vk stream blob");
	frame.count = 0U;
	command(&frame, GPU_OP_GET_FENCE_STATUS, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_FENCE);
	memcpy(stream->view, frame.words, frame.count * 4U);
	index = frame.count;
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_EXECUTE_STREAMS, 0U);
	put32(&frame, 1U);
	put64(&frame, 1U);
	put32(&frame, stream_id);
	put64(&frame, 0U);
	put64(&frame, index * 4U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	put64(&frame, 0U);
	put32(&frame, 0U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0 && reply_word(reply, 0U) == GPU_OP_GET_FENCE_STATUS && reply_word(reply, 1U) == 0U, "vk stream in a blob");

	/* Refusals: a number no route owns, the driver's own gpu-ops, a reply without a stream. */
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GET_PHYSICAL_DEVICE_VIDEO_CAPABILITIES, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_PHYSICAL);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == ENOTSUP, "vk video refused");
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_GHCI_MEMORY, 0U);
	put64(&frame, 0U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == EINVAL, "vk GHCI gpu-op from userland refused");
	frame.count = 0U;
	command(&frame, GPU_OP_CREATE_INSTANCE, GPU_OP_FLAG_REPLY);
	put64(&frame, 0U);
	error = submit(opaque, &frame);
	expect(error == EINVAL, "vk reply without a stream refused");
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CMD_DRAW, 0U);
	put64(&frame, ID_COMMAND);
	put32(&frame, 3U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == EINVAL, "vk short recording refused");

	/* The memory freed while its blob shows it: the blob keeps it, then lets it go. */
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_FREE_MEMORY, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_MEMORY);
	put64(&frame, 0U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	records = staged(&record_count);
	expect(error == 0 && records != NULL && records[0] == GPU_OP_FREE_MEMORY, "vk free relayed");
	expect(ghci_vk_object_find(session->vk, GHCI_VK_MEMORY, ID_MEMORY) == NULL, "vk memory forgotten");
	expect(alias->backing->released && alias->backing->holds == 1U, "vk freed memory held by its blob");
	core_ops->resource_destroy(core_private, opaque, alias);
	ghci_service_step(&device, GHCI_WORK_RECLAIM);

	/*
	 * Sharing: a second memory's blob exported, imported into a second
	 * session, which imports it as its own memory object.  The memory
	 * stays while any of them holds it.
	 */
	memset(reply->view, 0, REPLY_BYTES);
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_ALLOCATE_MEMORY, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 5U);
	put64(&frame, 1U);
	put32(&frame, 1000072002U);
	put64(&frame, 0U);
	put32(&frame, 0x201U);
	put64(&frame, 4096U);
	put32(&frame, 1U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_HOST_MEMORY);
	frame_end(&frame);
	error = submit(opaque, &frame);
	ghci_vk_service(&device);
	expect(error == 0 && reply_word(reply, 1U) == 0U, "vk exportable memory");
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = 4096U;
	blob_request.blob_id = ID_HOST_MEMORY;
	blob_request.flags = GPU_BLOB_SHAREABLE | GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &alias_id);
	alias = object_pointer;
	expect(error == 0, "vk shareable blob of the memory");
	error = core_ops->share->export_resource(core_private, opaque, alias, NULL, &shared);
	expect(error == 0 && shared != NULL, "vk memory exported");
	error = core_ops->open(core_private, &second);
	expect(error == 0, "vk second session");
	error = core_ops->share->import_resource(core_private, second, shared, 0U, &object_pointer, &import_id);
	imported = object_pointer;
	expect(error == 0 && import_id == alias_id && imported->backing == alias->backing, "vk import shows the same memory");
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = REPLY_BYTES;
	blob_request.flags = GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, second, &blob_request, &object_pointer, &second_reply_id);
	second_reply = object_pointer;
	expect(error == 0, "vk second reply blob");
	frame_begin(&frame, second_reply_id);
	command(&frame, GPU_OP_ALLOCATE_MEMORY, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, 1U);
	put32(&frame, 5U);
	put64(&frame, 1U);
	put32(&frame, GPU_OP_RECORD_IMPORT_RESOURCE);
	put64(&frame, 0U);
	put32(&frame, import_id);
	put64(&frame, 4096U);
	put32(&frame, 1U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_MEMORY);
	frame_end(&frame);
	error = submit(second, &frame);
	ghci_vk_service(&device);
	records = staged(&record_count);
	expect(error == 0 && records != NULL && records[0] == GPU_OP_GHCI_MEMORY, "vk imported memory announced");
	if (records != NULL)
		expect(records[5] == import_id && records[9] == 3U, "vk imported memory's address and import flag");
	expect(reply_word(second_reply, 1U) == 0U && reply_word(second_reply, 4U) == ID_MEMORY, "vk imported memory's reply");
	expect(alias->backing->holds == 4U, "vk memory held by the blob, the export, the import and its memory object");
	core_ops->commands->drain(core_private, second);
	core_ops->resource_destroy(core_private, second, second_reply);
	core_ops->resource_destroy(core_private, second, imported);
	core_ops->close(core_private, second);
	core_ops->share->release(core_private, shared);
	expect(alias->backing->holds == 1U && !alias->backing->released, "vk memory back with its blob only");
	core_ops->resource_destroy(core_private, opaque, alias);

	/* A reset: the frames in flight fail, the session is lost, the heap is lent again. */
	errors = core_session_errors;
	model_paused = 1;
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_DESTROY_BUFFER, GPU_OP_FLAG_REPLY);
	put64(&frame, ID_DEVICE);
	put64(&frame, ID_BUFFER);
	put64(&frame, 0U);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == 0 && session->vk->pending == 1U, "vk frame in flight before the reset");
	completions = core_completions;
	model_paused = 0;
	model_irq_status |= GHCI_IRQ_FAULT;
	model_state = GHCI_ST_FAULTED;
	model_interrupt();
	ghci_service_step(&device, GHCI_WORK_RECOVER);
	expect(core_completions == completions + 1U && core_last_completion_error == EIO, "vk frame in flight failed by the reset");
	expect(session->vk->lost && session->vk->pending == 0U, "vk session lost");
	expect(core_session_errors > errors, "vk session's loss reported");
	expect(model_last_control == GPU_OP_GHCI_HEAP && device.vk->heap_ready, "vk heap lent again");
	frame_begin(&frame, reply_id);
	command(&frame, GPU_OP_CREATE_INSTANCE, GPU_OP_FLAG_REPLY);
	put64(&frame, 0U);
	put64(&frame, 0U);
	put64(&frame, 1U);
	put64(&frame, ID_INSTANCE);
	frame_end(&frame);
	error = submit(opaque, &frame);
	expect(error == EIO, "vk lost session takes nothing");

	/* The close: the session's objects go, its memory comes back, the device stops. */
	core_ops->commands->drain(core_private, opaque);
	core_ops->resource_destroy(core_private, opaque, reply);
	core_ops->resource_destroy(core_private, opaque, stream);
	core_ops->close(core_private, opaque);
	ghci_service_step(&device, GHCI_WORK_RECLAIM);
	error = ghci_device_stop(&device);
	expect(error == 0, "vk stop");
	expect(device.vk == NULL, "vk executor gone");
	expect(model_guard_changed() == 0U, "vk driver did not touch the local window");
	model_device = NULL;

	/* A second open and close of a fresh device leaves the firmware's session closed. */
	model_setup_window(1);
	model_registers[GHCI_CAPS / 4U] |= GHCI_CAPS_FIRMWARE | GHCI_CAPS_SHADER;
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;
	error = ghci_device_start(&device);
	expect(error == 0 && device.vk != NULL, "vk second start");
	error = core_ops->open(core_private, &opaque);
	expect(error == 0, "vk second open");
	expect(core_ops->recovery != NULL && core_ops->recovery->stop_begin != NULL && core_ops->recovery->stop_poll != NULL,
	    "vk the core's stop contract (without it every close faults the device)");
	error = core_ops->recovery->stop_begin(core_private, opaque, 0);
	expect(error == 0, "vk stop begun");
	error = core_ops->recovery->stop_poll(core_private, opaque);
	expect(error == 0, "vk an idle session's stop is done at once");
	core_ops->commands->drain(core_private, opaque);
	core_ops->close(core_private, opaque);
	expect(model_last_control == GPU_OP_GHCI_SESSION_CLOSE, "vk SESSION_CLOSE sent at the close");
	error = ghci_device_stop(&device);
	expect(error == 0, "vk second stop");
	model_device = NULL;
}

/* Finds the first control packet of a gpu-op in the model's log from an index (NULL: none). */
static const struct model_control *
control_find(
	uint32_t opcode,
	unsigned from,
	unsigned *at)
{
	unsigned index;

	/* The log in the model's order. */
	for (index = from; index < model_control_count; index++) {
		if (model_controls[index].opcode == opcode) {
			if (at != NULL)
				*at = index;
			return &model_controls[index];
		}
	}

	/* No such packet. */
	return NULL;
}

/*
 * Session protection on a model GPU with the PROT capability: the table
 * lent in the driver's order (zeroed, PROT_TABLE, then GHCI_HEAP), a
 * session of a user who is not root opened PROTECTED and its resources
 * given to the firmware as its own (a GHCI_MEMORY of a synthetic identity,
 * FREE_MEMORY when they go), root's session unprotected, an import of
 * root's memory into the protected session granted and revoked, and a
 * client's memory identity of the synthetic kind refused.
 */
static void
test_protection(void)
{
	static struct ghci_device device;
	struct gpu_blob_create blob_request;
	const struct model_control *control;
	struct ghci_allocation *blob;
	struct ghci_allocation *root_blob;
	struct ghci_allocation *imported;
	struct ghci_session *session;
	uint32_t table_bytes;
	uint32_t blob_id;
	uint32_t root_id;
	uint32_t import_id;
	unsigned at;
	unsigned index;
	void *object_pointer;
	void *opaque;
	void *root;
	void *shared;
	int zero;
	int error;

	/* The model with firmware and a shader unit, and PROT after MEM: 31 sessions, 4 KiB, 64 grants. */
	model_setup_window(1);
	model_registers[GHCI_CAPS / 4U] |= GHCI_CAPS_FIRMWARE | GHCI_CAPS_SHADER | (5U << 4);
	model_registers[GHCI_CAPS2 / 4U] = 1U | (16U << 8) | (16U << 16) | (4U << 24) | (4U << 28);
	model_registers[GHCI_ISA_ID / 4U] = GHCI_FOURCC('G', 'S', 'I', '1');
	model_registers[GHCI_RESIDENT_WARPS / 4U] = (64U << 16) | 16U;
	model_registers[MODEL_EXTCAP / 4U] = GHCI_XCAP_MEM | (1U << 8) | (2U << 16);
	model_registers[MODEL_EXTCAP / 4U + 2U] = GHCI_XCAP_PROT | (1U << 8);
	model_registers[MODEL_EXTCAP / 4U + 3U] = MODEL_PROT_REGISTERS;
	model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_CAPS) / 4U] = 31U | (12U << 8) | (64U << 16);
	table_bytes = ((MODEL_LOCAL_BYTES >> 12) + 4095U) & ~4095U;
	model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_TABLE_BYTES) / 4U] = table_bytes;
	model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_TABLE) / 4U] = 0U;
	model_isa = &fake_isa;
	memset(model_local, 0xA5, sizeof(model_local));
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;
	model_control_count = 0U;
	core_superuser = 0;

	/* The start: the table zeroed and named before the heap is lent. */
	error = ghci_device_start(&device);
	expect(error == 0 && device.vk != NULL, "prot start");
	expect(device.protection && device.prot_table != NULL, "prot capability used");
	expect(device.prot_table != NULL && device.prot_table->bytes >= table_bytes, "prot table of PROT_TABLE_BYTES");
	expect(device.prot_table != NULL &&
	    model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_TABLE) / 4U] == device.prot_table->gpu_address, "prot PROT_TABLE written");
	zero = device.prot_table != NULL;
	for (index = 0U; zero && index < table_bytes; index++) {
		if (device.prot_table->view[index] != 0U)
			zero = 0;
	}
	expect(zero, "prot table zeroed");
	control = control_find(GPU_OP_GHCI_HEAP, 0U, NULL);
	expect(control != NULL && device.prot_table != NULL && control->table == device.prot_table->gpu_address,
	    "prot GHCI_HEAP after PROT_TABLE");
	expect((device.aperture_base & 4095U) == 0U, "prot aperture on a granule");

	/* A user's session: PROTECTED. */
	error = core_ops->open(core_private, &opaque);
	session = opaque;
	expect(error == 0 && session->protected, "prot user session protected");
	control = control_find(GPU_OP_GHCI_SESSION_OPEN, 0U, &at);
	expect(control != NULL && control->arguments[0] == session->tag && control->arguments[1] == GHCI_SESSION_PROTECTED,
	    "prot SESSION_OPEN PROTECTED");

	/* Its resource is its own memory to the firmware: GHCI_MEMORY of the synthetic identity. */
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = 8192U;
	blob_request.flags = GPU_BLOB_MAPPABLE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object_pointer, &blob_id);
	blob = object_pointer;
	expect(error == 0 && blob->prot_owned, "prot resource owned");
	control = control_find(GPU_OP_GHCI_MEMORY, at, &at);
	expect(control != NULL && control->tag == session->tag && control->arguments[0] == blob->gpu_address &&
	    control->arguments[1] == (uint32_t)(GHCI_VK_PROT_IDENTITY >> 32) && control->arguments[2] == blob->gpu_address &&
	    control->arguments[4] == blob->bytes && control->arguments[6] == 0U, "prot GHCI_MEMORY of the resource");

	/* Root's session is not protected, and its resource is not given. */
	core_superuser = 1;
	error = core_ops->open(core_private, &root);
	core_superuser = 0;
	expect(error == 0 && !((struct ghci_session *)root)->protected, "prot root session unprotected");
	control = control_find(GPU_OP_GHCI_SESSION_OPEN, at + 1U, &at);
	expect(control != NULL && control->arguments[1] == 0U, "prot root SESSION_OPEN not PROTECTED");
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = 4096U;
	blob_request.flags = GPU_BLOB_MAPPABLE | GPU_BLOB_SHAREABLE;
	error = core_ops->blob_create(core_private, root, &blob_request, &object_pointer, &root_id);
	root_blob = object_pointer;
	expect(error == 0 && !root_blob->prot_owned && control_find(GPU_OP_GHCI_MEMORY, at, NULL) == NULL,
	    "prot root resource not given");

	/* Root's export imported by the user: granted, read and write; its destroy revokes it. */
	error = core_ops->share->export_resource(core_private, root, root_blob, NULL, &shared);
	expect(error == 0, "prot root export");
	error = core_ops->share->import_resource(core_private, opaque, shared, 0U, &object_pointer, &import_id);
	imported = object_pointer;
	expect(error == 0 && imported->prot_granted, "prot import granted");
	control = control_find(GPU_OP_GHCI_BUFFER_GRANT, at, &at);
	expect(control != NULL && control->tag == 0U && control->arguments[0] == session->tag && control->arguments[1] == 3U &&
	    control->arguments[2] == root_blob->gpu_address && control->arguments[4] == root_blob->bytes, "prot BUFFER_GRANT");
	core_ops->resource_destroy(core_private, opaque, imported);
	control = control_find(GPU_OP_GHCI_BUFFER_REVOKE, at, &at);
	expect(control != NULL && control->arguments[0] == session->tag && control->arguments[1] == root_blob->gpu_address &&
	    control->arguments[3] == root_blob->bytes, "prot BUFFER_REVOKE at the import's destroy");

	/* The resource's destroy frees the synthetic identity (no result asked). */
	core_ops->resource_destroy(core_private, opaque, blob);
	control = control_find(GPU_OP_FREE_MEMORY, at, &at);
	expect(control != NULL && control->tag == session->tag && control->flags == 0U &&
	    control->arguments[3] == (uint32_t)(GHCI_VK_PROT_IDENTITY >> 32), "prot FREE_MEMORY of the resource");

	/* The close: SESSION_CLOSE, and nothing taken back after it (the firmware closed it all). */
	core_ops->commands->drain(core_private, opaque);
	core_ops->close(core_private, opaque);
	expect(model_last_control == GPU_OP_GHCI_SESSION_CLOSE, "prot SESSION_CLOSE");
	core_ops->share->release(core_private, shared);
	core_ops->commands->drain(core_private, root);
	core_ops->close(core_private, root);
	ghci_service_step(&device, GHCI_WORK_RECLAIM);
	error = ghci_device_stop(&device);
	expect(error == 0 && device.prot_table == NULL, "prot stop gives the table back");
	expect(model_guard_changed() == 0U, "prot driver did not touch the local window");
	model_device = NULL;
}
