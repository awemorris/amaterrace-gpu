/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The host test of the GHCI driver's device, ring, memory, native
 * command and display (src/drivers/gpu/ghci/ghci.c, cp.c, memory.c,
 * blit.c, native.c, display.c, display-scan.c) against a model of a GHCI
 * GPU.
 *
 * The model is a register window, local memory with a window onto part
 * of it, and a command processor that parses the ring when the doorbell
 * rings: padding, SET_REG of the blitter, BLIT (fill and copy of 32-bit
 * pixels), FENCE, WAIT_IDLE, INVALIDATE and NOP; DRAW is taken as a
 * fault of an unknown operation.  It raises the interrupt by calling the
 * driver's handler.  The kernel's services the driver uses (locks, wait
 * queues, the clock, MMIO, RAM, the GPU core) are stubs: the test runs on
 * one thread, and every sleep advances a fake clock and lets the model run.
 *
 * With the FIRMWARE capability the model also takes class 2 packets as a
 * stand-in for the command processor's firmware: the GHCI control
 * gpu-ops succeed, and a GHCI_FRAME writes a result for each of its
 * records (model_aux gives their aux words) and the frame's result, then
 * raises RESULT.  GHCI_INIT answers with the token (model_init_mode
 * gives the wrong answers of the start's tests), and DIAG_ECHO,
 * DIAG_WRITE and DIAG_SUM work on the model's memory, as does the debug
 * port (DBG_ADDR, DBG_DATA).  The Vulkan executor's test (ghci-vk-host-test.c)
 * includes this file with GHCI_MODEL_ONLY, which leaves out this test's
 * own checks and main.
 *
 * With a DISP2 capability (model_setup_display) the model also has a
 * display controller that is a unit of the GPU: the gate of the host's
 * scan-out writes (refused while the processor runs, with BAD_WRITE),
 * DISP_SET and FLIP in the ring, one pending flip per plane taken at the
 * next vertical sync (every sleep of the test is one; model_dc_hold
 * holds them), at once while ENABLE is 0 (cancelled for the cursor), and
 * as cancelled when ENABLE falls; the record {value, FRAME_COUNT} and
 * IRQ_STATUS.FLIP at the take; TAKEN0 and TAKEN1; the mode table; and
 * CONNECTED with HOTPLUG.  A mutex locked twice is counted as an error:
 * on one thread it would never come back.
 */

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "drivers/gpu/ghci/ghci.h"
#include "kern/clock.h"
#include "kern/poll.h"
#include "drivers/gpu/ghci/frame.h"
#include "drivers/gpu/ghci/hcr.h"
#include "drivers/gpu/ghci/packets.h"
#include "uapi/gpu.h"
#include "uapi/gpu-allocation.h"
#include "uapi/gpu-op.h"
#include "uapi/gpu-display.h"
#include "uapi/gpu-scanout.h"
#include "drivers/gpu/gpu-display.h"

/* The model's register window (128 KiB) and the place of its extended capabilities. */
#define MODEL_WINDOW_WORDS		32768U
#define MODEL_EXTCAP			0x100U
#define MODEL_MEM_REGISTERS		0x180U

/*
 * The model's local memory: 32 MiB at 2 GiB, of which the window shows
 * the first 16 MiB (room for the display's two frames of 1280 x 720); a
 * test that includes the model may give it more.
 */
#define MODEL_LOCAL_BASE		0x80000000U
#ifndef MODEL_LOCAL_BYTES
#define MODEL_LOCAL_BYTES		(32U << 20)
#define MODEL_WINDOW_BYTES		(16U << 20)
#endif
#define MODEL_WINDOW_PHYSICAL		0xe0000000ULL

/*
 * The model's host RAM: 32 MiB at 256 MiB (a test that includes the
 * model may give it more), handed out by a bump allocator; the GPU
 * reaches the host below 2 GiB (MEM HOST_LIMIT).
 */
#define MODEL_HOST_BASE			0x10000000U
#ifndef MODEL_HOST_BYTES
#define MODEL_HOST_BYTES		(32U << 20)
#endif
#define MODEL_HOST_LIMIT		0x80000000U

/* What the stand-in of the local window holds; the driver must leave it alone. */
#define MODEL_GUARD_BYTE		0x3cU

/* The state words of the model's blitter. */
#define MODEL_STATE_WORDS		512U

/* The model's display controller: its window (256 bytes) in the register window, its two modes. */
#define MODEL_DISP2_REGISTERS		0x400U

/* Where the PROT capability's registers are (model_setup_protection). */
#define MODEL_PROT_REGISTERS		0x1C0U
#define MODEL_DC_WORDS			64U
#define MODEL_DC_MODES			2U

/*
 * The counts of the checks that held and that failed.  Every check adds
 * to one of them; main reports both and fails when any check failed.
 */
static unsigned checks_passed;
static unsigned checks_failed;

/* The model's register window, which the driver maps as its registers. */
static uint32_t model_registers[MODEL_WINDOW_WORDS];

/* The model's local memory; the driver's window is its first part. */
static uint8_t model_local[MODEL_LOCAL_BYTES];

/* The model's host RAM and the next free byte of it. */
static uint8_t model_host[MODEL_HOST_BYTES];
static uint32_t model_host_next;

/*
 * The stand-in of the local window's bus mapping: not the model's local
 * memory, so that any access of the driver through the window shows here
 * and never reaches the GPU (the driver does not use the window).
 */
static uint8_t model_window_guard[MODEL_WINDOW_BYTES];

/*
 * The model's command processor: its state, ring pointers, interrupt
 * registers, fault record, blitter state and whether it is paused (a
 * paused processor parses nothing until the test resumes it).
 */
static unsigned model_state;
static uint32_t model_rptr;
static uint32_t model_wptr;
static uint32_t model_irq_status;
static uint32_t model_irq_enable;
static uint32_t model_fault_info;
static uint32_t model_fault_address;
static uint32_t model_blt[MODEL_STATE_WORDS];
static int model_paused;
static int model_running_now;
static unsigned model_packets_crossing;
static unsigned model_doorbells;

/* The device under test, whose interrupt handler the model calls. */
static struct ghci_device *model_device;

/* The fake clock: one tick per sleep. */
static uint64_t fake_ticks;

/* What the GPU core stubs saw: the registered operations, session errors, capacity notes. */
static const struct drv_gpu_ops *core_ops;
static void *core_private;
static unsigned core_session_errors;
static unsigned core_capacity_notes;
static int core_superuser;

/*
 * What the core's completions saw: how many, and the error of the last;
 * and the compiler the driver gets (none unless a test gives one).
 */
static unsigned core_completions;
static int core_last_completion_error;
static const struct ghci_isa_backend *model_isa;

/*
 * The model firmware: the aux word of each record of the next frames
 * (by result index, 0 past the table), the frames it took, and the last
 * frame's staging address, bytes and record count.
 */
#define MODEL_AUX_WORDS			64U
static uint32_t model_aux[MODEL_AUX_WORDS];
static unsigned model_frames;
static uint32_t model_frame_staging;
static uint32_t model_frame_bytes;
static uint32_t model_frame_records;
static unsigned model_control_packets;
static uint32_t model_last_control;

/*
 * The model firmware's INIT: how it answers (MODEL_INIT_*), and the INITs
 * and diagnostics it took.  The debug port's address and status (error:
 * the last access was outside the memories).
 */
#define MODEL_INIT_RIGHT		0
#define MODEL_INIT_SILENT		1
#define MODEL_INIT_WRONG_TOKEN		2
#define MODEL_INIT_OLD_FIRMWARE		3
static int model_init_mode;
static unsigned model_inits;
static unsigned model_diags;
static uint32_t model_dbg_address;
static uint32_t model_dbg_status;

/*
 * The control packets (not frames) in the order the model ran them: the
 * gpu-op, the packet's tag and its first arguments; the log keeps the
 * first MODEL_CONTROL_LOG.
 */
#define MODEL_CONTROL_LOG		64U
#define MODEL_CONTROL_ARGUMENTS		7U
struct model_control {
	uint32_t opcode;
	uint32_t tag;
	uint32_t flags;
	uint32_t arguments[MODEL_CONTROL_ARGUMENTS];
	uint32_t table;		/* PROT_TABLE when it ran */
};
static struct model_control model_controls[MODEL_CONTROL_LOG];
static unsigned model_control_count;

/*
 * The model's display controller: whether it exists, its registers by
 * word, the sticky errors of STATUS, each plane's pending flip, a record
 * that waits for the processor to leave a state that does not write it,
 * the frame count, and whether the test holds the vertical syncs.
 * slot_busy counts flips placed on a plane that had one pending (the
 * driver never should), dc_flips the FLIP packets parsed, and
 * dc_bad_writes the host writes the gate refused.
 */
struct model_dc_flip {
	int pending;
	uint32_t base;
	uint32_t record;
	uint32_t value;
	int due;
	uint32_t due_words[2];
};
static int model_dc_present;
static uint32_t model_dc[MODEL_DC_WORDS];
static uint32_t model_dc_sticky;
static struct model_dc_flip model_dc_slot[2];
static uint32_t model_dc_frames;
static int model_dc_hold;
static unsigned model_dc_slot_busy;
static unsigned model_dc_flips;
static unsigned model_dc_bad_writes;
static unsigned model_dc_disp_sets;

/* The mutexes locked twice on the test's one thread (each would hang the kernel). */
static unsigned lock_errors;

/*
 * The uncached views of host RAM the driver made and removed: each view
 * is the run's own bytes in the model (the model has no cache), so only
 * the counts and the bytes still viewed show what the driver did.
 */
static unsigned uncached_maps;
static unsigned uncached_unmaps;
static uint64_t uncached_bytes;

/* The model's two modes, as MODE_H0 .. MODE_FLAGS read them: 640 x 480 and 1280 x 720 at 60 Hz. */
static const uint32_t model_dc_modes[MODEL_DC_MODES][6] = {
	{ (96U << 16) | 640U, (48U << 16) | 16U, (2U << 16) | 480U, (33U << 16) | 10U, 25200U, 0x00U },
	{ (40U << 16) | 1280U, (220U << 16) | 110U, (5U << 16) | 720U, (20U << 16) | 5U, 74250U, 0x13U }
};

static void expect(int held, const char *name);
static void model_reset(void);
static void model_run(void);
static uint8_t *model_memory(uint32_t address, uint32_t bytes);
static int model_packet(const uint32_t *ring, uint32_t ring_dwords, uint32_t at, uint32_t *length);
static void model_fault(uint32_t kind, uint32_t header);
static void model_blit(void);
static void model_interrupt(void);
static void model_setup_window(int discrete);
static unsigned model_guard_changed(void);
static int model_class_v(const uint32_t *ring, uint32_t at, uint32_t count);
static int model_firmware_op(const uint32_t *ring, uint32_t at, uint32_t count, uint32_t *reply);
static uint32_t model_dc_read(uint32_t offset);
static void model_dc_write(uint32_t offset, uint32_t value);
static int model_dc_scanout_register(uint32_t offset);
static void model_dc_apply(uint32_t offset, uint32_t value);
static void model_dc_take(unsigned plane, int cancelled);
static void model_dc_records_flush(void);
static int model_dc_packet(const uint32_t *ring, uint32_t at, uint32_t op, uint32_t flags, uint32_t count);
static void model_vsync(void);
#ifndef GHCI_MODEL_ONLY
static void model_setup_display(void);
static void test_discrete(void);
static void test_unified(void);
static void test_display(void);
static void test_polled_uncached(void);
static void test_firmware(void);
static void test_idle_frame(void);
static int firmware_start(struct ghci_device *device, int mode);
#endif

/* The kernel's MMIO: the register window is the model's. */
uint32_t
kern_mmio_read32(
	const volatile void *address)
{
	uint32_t offset;
	uint32_t value;

	/* The register's offset in the window. */
	offset = (uint32_t)((const volatile uint8_t *)address - (const volatile uint8_t *)model_registers);

	/* The display controller's window. */
	if (model_dc_present && offset >= MODEL_DISP2_REGISTERS && offset < MODEL_DISP2_REGISTERS + GHCI_DC2_WINDOW)
		return model_dc_read(offset - MODEL_DISP2_REGISTERS);

	/* The registers that the processor computes. */
	if (offset == GHCI_STATUS) {
		value = (model_state << 16) | GHCI_STATUS_MEM_READY | GHCI_STATUS_AXI_IDLE;
		if (model_state == GHCI_ST_HALTED)
			value |= GHCI_STATUS_HALTED;
		if (model_state == GHCI_ST_FAULTED)
			value |= GHCI_STATUS_FAULT;
		if (model_rptr == model_wptr)
			value |= GHCI_STATUS_RING_EMPTY;
		return value;
	}
	if (offset == GHCI_RING_RPTR)
		return model_rptr;
	if (offset == GHCI_RING_WPTR)
		return model_wptr;
	if (offset == GHCI_IRQ_STATUS)
		return model_irq_status;
	if (offset == GHCI_IRQ_ENABLE)
		return model_irq_enable;
	if (offset == GHCI_FAULT_INFO)
		return model_fault_info;
	if (offset == GHCI_FAULT_ADDR)
		return model_fault_address;
	if (offset == GHCI_DBG_STATUS)
		return model_dbg_status;
	if (offset == GHCI_CTRL)
		return model_registers[offset / 4U] & ~GHCI_CTRL_RESET;

	/* Every other register reads what is stored. */
	return model_registers[offset / 4U];
}

/* The kernel's MMIO writes: the model reacts to the control and ring registers. */
void
kern_mmio_write32(
	volatile void *address,
	uint32_t value)
{
	uint8_t *word;
	uint32_t offset;

	/* The register's offset in the window. */
	offset = (uint32_t)((volatile uint8_t *)address - (volatile uint8_t *)model_registers);

	/* The display controller's window. */
	if (model_dc_present && offset >= MODEL_DISP2_REGISTERS && offset < MODEL_DISP2_REGISTERS + GHCI_DC2_WINDOW) {
		model_dc_write(offset - MODEL_DISP2_REGISTERS, value);
		return;
	}

	/* IRQ_STATUS is write-1-to-clear; IRQ_ENABLE may raise a pending interrupt. */
	if (offset == GHCI_IRQ_STATUS) {
		model_irq_status &= ~value;
		return;
	}
	if (offset == GHCI_IRQ_ENABLE) {
		model_irq_enable = value;
		return;
	}

	/* CTRL: a reset, RUN and HALT. */
	if (offset == GHCI_CTRL) {
		if ((value & GHCI_CTRL_RESET) != 0U) {
			model_reset();
			return;
		}
		model_registers[offset / 4U] = value;
		if ((value & GHCI_CTRL_RUN) != 0U && model_state == GHCI_ST_IDLE)
			model_state = GHCI_ST_RUNNING;
		if ((value & GHCI_CTRL_HALT) != 0U && model_state == GHCI_ST_RUNNING)
			model_state = GHCI_ST_HALTED;
		return;
	}

	/* The doorbell: the processor parses up to the new write pointer. */
	if (offset == GHCI_RING_WPTR) {
		model_wptr = value;
		model_doorbells++;
		model_run();
		return;
	}

	/* The debug port: DBG_ADDR reads the word into DBG_DATA, a DBG_DATA write writes it. */
	if (offset == GHCI_DBG_ADDR || offset == GHCI_DBG_DATA) {
		if (offset == GHCI_DBG_ADDR)
			model_dbg_address = value;
		word = model_memory(model_dbg_address, 4U);
		model_dbg_status = 0U;
		if (word == NULL) {
			model_dbg_status = GHCI_DBG_ERROR;
		} else if (offset == GHCI_DBG_ADDR) {
			memcpy(&model_registers[GHCI_DBG_DATA / 4U], word, 4U);
		} else {
			memcpy(word, &value, 4U);
			model_registers[GHCI_DBG_DATA / 4U] = value;
		}
		return;
	}

	/* An aperture's write sets PROT_TABLE to 0 (section 11.6). */
	if (offset == GHCI_APERTURE_BASE || offset == GHCI_APERTURE_LIMIT)
		model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_TABLE) / 4U] = 0U;

	/* Every other register is stored. */
	model_registers[offset / 4U] = value;
}

/* The barriers do nothing on the host. */
void
kern_io_write_barrier(void)
{
}

void
kern_io_read_barrier(void)
{
}

/* The locks: the test runs on one thread. */
int
mutex_init(
	struct mutex *mutex,
	enum lock_rank rank,
	const char *name)
{
	(void)rank;
	(void)name;
	memset(mutex, 0, sizeof(*mutex));
	return 0;
}

void
mutex_lock(
	struct mutex *mutex)
{
	/* A second lock of the same mutex on one thread would never come back. */
	if (mutex->locked != 0U) {
		lock_errors++;
		printf("FAIL mutex locked twice\n");
	}
	mutex->locked = 1U;
}

void
mutex_unlock(
	struct mutex *mutex)
{
	mutex->locked = 0U;
}

void
spin_init(
	struct spinlock *lock,
	enum lock_rank rank,
	const char *name)
{
	(void)rank;
	(void)name;
	memset(lock, 0, sizeof(*lock));
}

unsigned long
spin_lock_irqsave(
	struct spinlock *lock)
{
	(void)lock;
	return 0;
}

void
spin_unlock_irqrestore(
	struct spinlock *lock,
	unsigned long enabled)
{
	(void)lock;
	(void)enabled;
}

/* The wait queues: a sleep is one tick of the fake clock in which the model runs. */
void
waitq_init(
	struct wait_queue *queue,
	const char *name)
{
	(void)name;
	memset(queue, 0, sizeof(*queue));
}

uint64_t
waitq_sequence(
	const struct wait_queue *queue)
{
	(void)queue;
	return 0;
}

int
waitq_sleep(
	struct wait_queue *queue,
	struct spinlock *condition_lock,
	uint64_t observed,
	uint64_t deadline,
	unsigned flags)
{
	(void)queue;
	(void)condition_lock;
	(void)observed;
	(void)deadline;
	(void)flags;
	fake_ticks++;
	model_vsync();
	model_run();
	return 0;
}

void
waitq_wake_all(
	struct wait_queue *queue)
{
	(void)queue;
}

/* The clock and the scheduler's sleep. */
uint64_t
clock_ticks(void)
{
	return fake_ticks;
}

void
sched_sleep(
	uint64_t timeout_tick)
{
	/* The clock jumps to the deadline (at least one tick), and the model runs. */
	if (timeout_tick > fake_ticks)
		fake_ticks = timeout_tick;
	else
		fake_ticks++;
	model_vsync();
	model_run();
}

/* Waiters on poll are woken: nothing waits in the test. */
void
poll_notify(void)
{
}

/* The log goes to standard output. */
int
kern_logf(
	const char *format,
	...)
{
	va_list arguments;
	int written;

	va_start(arguments, format);
	printf("  log: ");
	written = vprintf(format, arguments);
	va_end(arguments);
	return written;
}

/* The kernel's heap is the host's. */
void *
kern_malloc(
	size_t size)
{
	return malloc(size);
}

void *
kern_calloc(
	size_t count,
	size_t size)
{
	return calloc(count, size);
}

void
kern_free(
	void *pointer)
{
	free(pointer);
}

/* RAM below 4 GiB: the model's host RAM, a bump allocator that never reuses. */
int
kern_pmem_alloc_limited(
	size_t size,
	size_t alignment,
	uint64_t max_address,
	size_t boundary,
	struct kern_pmem *run)
{
	uint32_t start;

	(void)boundary;

	/* The next aligned run, if it fits and the device can name it. */
	start = (model_host_next + (uint32_t)alignment - 1U) & ~((uint32_t)alignment - 1U);
	if (start + size > MODEL_HOST_BYTES)
		return 4;
	if ((uint64_t)MODEL_HOST_BASE + start + size - 1U > max_address)
		return 4;
	model_host_next = start + (uint32_t)size;
	run->paddr = MODEL_HOST_BASE + start;
	run->size = size;
	return 0;
}

int
kern_pmem_free(
	struct kern_pmem *run)
{
	(void)run;
	return 0;
}

void *
kern_pmem_to_kernel(
	hal_physaddr_t address)
{
	return &model_host[address - MODEL_HOST_BASE];
}

/* An uncached view of a run: the run's bytes in the model, counted. */
int
kern_pmem_map_uncached(
	const struct kern_pmem *run,
	void **mapped)
{
	uncached_maps++;
	uncached_bytes += run->size;
	*mapped = &model_host[run->paddr - MODEL_HOST_BASE];
	return 0;
}

/* The removal of an uncached view, counted. */
int
kern_pmem_unmap_uncached(
	void *mapped,
	size_t size)
{
	(void)mapped;
	uncached_unmaps++;
	uncached_bytes -= size;
	return 0;
}

/* The GPU core: the registration is remembered; the reports are counted. */
int
drv_gpu_register(
	const struct drv_gpu_ops *ops,
	void *private_data,
	struct drv_gpu_device **result)
{
	core_ops = ops;
	core_private = private_data;
	*result = (struct drv_gpu_device *)&core_ops;
	return 0;
}

int
drv_gpu_unregister(
	struct drv_gpu_device *device)
{
	(void)device;
	core_ops = NULL;
	return 0;
}

void
drv_gpu_report_session_error(
	struct drv_gpu_device *device,
	void *session,
	int error)
{
	(void)device;
	(void)session;
	(void)error;
	core_session_errors++;
}

void
drv_gpu_capacity_changed(
	struct drv_gpu_device *device)
{
	(void)device;
	core_capacity_notes++;
}

void
drv_gpu_complete(
	struct drv_gpu_completion *completion,
	int error)
{
	(void)completion;
	core_completions++;
	core_last_completion_error = error;
}

/* The credentials: root or not, as the test says. */
const struct ucred *
cred_current(void)
{
	return NULL;
}

int
cred_is_superuser(
	const struct ucred *credentials)
{
	(void)credentials;
	return core_superuser;
}

/* The parts of the driver the test does not run: the thread and the compiler. */
int
ghci_service_start(
	struct ghci_device *device)
{
	(void)device;
	return 0;
}

/* The model raises its interrupt, so no device of the test is polled. */
int
ghci_poll_start(
	struct ghci_device *device)
{
	(void)device;
	return 0;
}

const struct ghci_isa_backend *
ghci_isa_select(
	uint32_t caps,
	uint32_t isa_id)
{
	(void)caps;
	(void)isa_id;
	return model_isa;
}

#ifndef GHCI_MODEL_ONLY
/*
 * Runs the GPUs: a discrete one with a window onto part of its local
 * memory, a unified one, and a discrete one with a display controller.
 */
int
main(void)
{
	/* The discrete GPU, the unified one, then a discrete one with a display controller. */
	test_discrete();
	test_unified();
	test_display();
	test_polled_uncached();
	test_firmware();
	test_idle_frame();
	expect(lock_errors == 0U, "no mutex locked twice");

	/* Reports the counts of the checks. */
	printf("ghci-driver-host-test: %u passed, %u failed\n", checks_passed, checks_failed);

	/* A failed check fails the test. */
	if (checks_failed != 0U)
		return 1;

	/* Succeeded: every check held. */
	return 0;
}
#endif

/* Counts one check, and names it when it failed. */
static void
expect(
	int held,
	const char *name)
{
	/* A check that held is only counted. */
	if (held) {
		checks_passed++;
		return;
	}

	/* A check that failed is counted and named. */
	checks_failed++;
	printf("FAIL %s\n", name);
}

/* Resets the model's processor: idle, empty ring, no interrupt, no fault (the aperture and ring base stay). */
static void
model_reset(void)
{
	model_state = GHCI_ST_IDLE;
	model_rptr = 0U;
	model_wptr = 0U;
	model_irq_status = 0U;
	model_fault_info = 0U;
	model_fault_address = 0U;
	model_registers[GHCI_FENCE_LAST / 4U] = 0U;
	model_registers[GHCI_CTRL / 4U] = 0U;

	/* The reset processor is idle: a record the display owed is written now. */
	model_dc_records_flush();
}

/* Reports the bytes of GPU memory at an address, or NULL outside the aperture or any memory. */
static uint8_t *
model_memory(
	uint32_t address,
	uint32_t bytes)
{
	uint64_t end;
	uint32_t base;
	uint32_t limit;

	/* Every access is checked against the aperture. */
	end = (uint64_t)address + bytes;
	base = model_registers[GHCI_APERTURE_BASE / 4U];
	limit = model_registers[GHCI_APERTURE_LIMIT / 4U];
	if (address < base || end > limit)
		return NULL;

	/* Local memory. */
	if (address >= MODEL_LOCAL_BASE && end <= (uint64_t)MODEL_LOCAL_BASE + MODEL_LOCAL_BYTES)
		return &model_local[address - MODEL_LOCAL_BASE];

	/* Host RAM. */
	if (address >= MODEL_HOST_BASE && end <= (uint64_t)MODEL_HOST_BASE + MODEL_HOST_BYTES)
		return &model_host[address - MODEL_HOST_BASE];

	/* Nothing is there. */
	return NULL;
}

/* Records the first fault and stops the processor. */
static void
model_fault(
	uint32_t kind,
	uint32_t header)
{
	if (model_state != GHCI_ST_FAULTED) {
		model_fault_info = (kind << 12) | (GHCI_PKT_GET_TAG(header) << 24);
		model_fault_address = 0U;
	}
	model_state = GHCI_ST_FAULTED;
	model_irq_status |= GHCI_IRQ_FAULT;
}

/* Runs the blitter on its state: a fill or a copy of 32-bit pixels. */
static void
model_blit(void)
{
	uint32_t op;
	uint32_t width;
	uint32_t height;
	uint32_t row;
	uint32_t column;
	uint8_t *dst;
	uint8_t *src;
	uint32_t dst_row;
	uint32_t src_row;
	uint32_t value;

	op = model_blt[GHCI_S_BLT_OP] & 7U;
	width = model_blt[GHCI_S_BLT_SIZE] & 0xffffU;
	height = model_blt[GHCI_S_BLT_SIZE] >> 16;

	/* One row at a time, each checked against the aperture. */
	for (row = 0U; row < height; row++) {
		dst_row = model_blt[GHCI_S_BLT_DST_BASE] +
		    ((model_blt[GHCI_S_BLT_DST_XY] >> 16) + row) * model_blt[GHCI_S_BLT_DST_STRIDE] +
		    (model_blt[GHCI_S_BLT_DST_XY] & 0xffffU) * 4U;
		dst = model_memory(dst_row, width * 4U);
		if (dst == NULL) {
			model_fault(GHCI_FAULT_APERTURE, 0U);
			return;
		}

		/* A fill writes the colour; a copy reads its source row. */
		if (op == GHCI_BLT_FILL) {
			for (column = 0U; column < width; column++) {
				value = model_blt[GHCI_S_BLT_COLOR];
				memcpy(&dst[column * 4U], &value, 4U);
			}
			continue;
		}
		src_row = model_blt[GHCI_S_BLT_SRC_BASE] +
		    ((model_blt[GHCI_S_BLT_SRC_XY] >> 16) + row) * model_blt[GHCI_S_BLT_SRC_STRIDE] +
		    (model_blt[GHCI_S_BLT_SRC_XY] & 0xffffU) * 4U;
		src = model_memory(src_row, width * 4U);
		if (src == NULL) {
			model_fault(GHCI_FAULT_APERTURE, 0U);
			return;
		}
		memmove(dst, src, width * 4U);
	}
}

/*
 * Parses one packet at a ring index: 0 with its length, or a fault.
 * ring_dwords is the ring's size; a packet may not run past its end or
 * past the write pointer.
 */
static int
model_packet(
	const uint32_t *ring,
	uint32_t ring_dwords,
	uint32_t at,
	uint32_t *length)
{
	uint32_t header;
	uint32_t class;
	uint32_t op;
	uint32_t flags;
	uint32_t count;
	uint32_t index;
	uint32_t available;
	uint8_t *word;

	header = ring[at];
	class = GHCI_PKT_GET_CLASS(header);
	op = (header >> 24) & 0x3fU;
	flags = (header >> 8) & 0xffU;
	count = header & 0xffU;
	if (class == GHCI_PKT_CLASS_PAD || class == GHCI_PKT_CLASS_V)
		count = header & 0xffffU;
	*length = 1U + count;

	/* A packet that crosses the end of the ring or the write pointer is a ring error. */
	available = model_wptr - at;
	if (model_wptr < at)
		available = ring_dwords - at;
	if (at + *length > ring_dwords) {
		model_packets_crossing++;
		model_fault(GHCI_FAULT_RING, header);
		return -1;
	}
	if (*length > available) {
		model_fault(GHCI_FAULT_RING, header);
		return -1;
	}

	/* Padding is skipped; a gpu-op goes to the model firmware, when there is one. */
	if (class == GHCI_PKT_CLASS_PAD)
		return 0;
	if (class == GHCI_PKT_CLASS_V && (model_registers[GHCI_CAPS / 4U] & GHCI_CAPS_FIRMWARE) != 0U)
		return model_class_v(ring, at, count);
	if (class != GHCI_PKT_CLASS_STD) {
		model_fault(GHCI_FAULT_OPCODE, header);
		return -1;
	}

	/* Each operation. */
	switch (op) {
	case GHCI_OP_NOP:
	case GHCI_OP_WAIT_IDLE:
	case GHCI_OP_INVALIDATE:
		break;

	case GHCI_OP_SET_REG:
		for (index = 0U; index + 1U < count; index += 2U)
			model_blt[ring[at + 1U + index] % MODEL_STATE_WORDS] = ring[at + 2U + index];
		break;

	case GHCI_OP_BLIT:
		model_blit();
		break;

	case GHCI_OP_DISP_SET:
	case GHCI_OP_FLIP:
		if (model_dc_packet(ring, at, op, flags, count) != 0)
			return -1;
		break;

	case GHCI_OP_FENCE:
		word = model_memory(ring[at + 1U], 4U);
		if (word == NULL) {
			model_fault(GHCI_FAULT_APERTURE, header);
			return -1;
		}
		memcpy(word, &ring[at + 2U], 4U);
		model_registers[GHCI_FENCE_LAST / 4U] = ring[at + 2U];
		if ((flags & GHCI_FENCE_IRQ) != 0U)
			model_irq_status |= GHCI_IRQ_FENCE;
		break;

	default:
		model_fault(GHCI_FAULT_OPCODE, header);
		return -1;
	}

	/* A fault of the blitter stops the parse too. */
	if (model_state == GHCI_ST_FAULTED)
		return -1;

	/* The packet was taken. */
	return 0;
}

/* Parses the ring up to the write pointer, unless the processor is paused or not running. */
static void
model_run(void)
{
	const uint32_t *ring;
	uint8_t *ring_bytes;
	uint32_t ring_dwords;
	uint32_t length;
	int error;

	/* A nested call (from the interrupt) does nothing. */
	if (model_running_now)
		return;
	model_running_now = 1;

	/* Parses packet after packet while running. */
	ring_dwords = (1U << model_registers[GHCI_RING_SIZE / 4U]) / 4U;
	ring_bytes = model_memory(model_registers[GHCI_RING_BASE / 4U], ring_dwords * 4U);
	while (!model_paused && model_state == GHCI_ST_RUNNING && model_rptr != model_wptr && ring_bytes != NULL) {
		ring = (const uint32_t *)ring_bytes;
		error = model_packet(ring, ring_dwords, model_rptr, &length);
		if (error != 0)
			break;
		model_rptr = (model_rptr + length) % ring_dwords;
	}

	/* The interrupt, when one is pending and enabled. */
	model_running_now = 0;
	model_interrupt();
}

/* Calls the driver's handler while a pending interrupt is enabled. */
static void
model_interrupt(void)
{
	unsigned rounds;

	/* The level stays while the handler leaves bits pending; a few rounds at most. */
	for (rounds = 0U; rounds < 4U; rounds++) {
		if ((model_irq_status & model_irq_enable) == 0U)
			return;
		if (model_device == NULL)
			return;
		(void)ghci_cp_interrupt(model_device);
	}
}

/* Counts the bytes of the window's stand-in that the driver changed. */
static unsigned
model_guard_changed(void)
{
	unsigned changed;
	uint32_t index;

	/* Looks at every byte of the stand-in. */
	changed = 0U;
	for (index = 0U; index < sizeof(model_window_guard); index++) {
		if (model_window_guard[index] != MODEL_GUARD_BYTE)
			changed++;
	}

	/* Succeeded: the number of changed bytes. */
	return changed;
}

/* Writes the identification, the capabilities and the extended capability list of the model. */
static void
model_setup_window(
	int discrete)
{
	/* An idle processor with nothing in its window yet. */
	memset(model_registers, 0, sizeof(model_registers));
	memset(model_local, 0x5a, sizeof(model_local));
	memset(model_host, 0xa5, sizeof(model_host));
	memset(model_window_guard, MODEL_GUARD_BYTE, sizeof(model_window_guard));
	model_host_next = 0U;
	model_dc_present = 0;
	model_reset();
	model_paused = 0;

	/* GHCI 1.0, Amaterrace's IDs, a processor, a blitter and 32-byte lines. */
	model_registers[GHCI_MAGIC / 4U] = GHCI_MAGIC_VALUE;
	model_registers[GHCI_VERSION / 4U] = 0x00010000U;
	model_registers[GHCI_VENDOR_ID / 4U] = GHCI_FOURCC('A', 'M', 'A', 'T');
	model_registers[GHCI_DEVICE_ID / 4U] = GHCI_FOURCC('A', 'T', 'G', '1');
	model_registers[GHCI_CAPS / 4U] = GHCI_CAPS_CP | GHCI_CAPS_BLT | (5U << 20);

	/* A discrete GPU lists its MEM capability; a unified one has no list. */
	if (!discrete)
		return;
	model_registers[GHCI_EXTCAP / 4U] = MODEL_EXTCAP;
	model_registers[MODEL_EXTCAP / 4U] = GHCI_XCAP_MEM | (1U << 8);
	model_registers[MODEL_EXTCAP / 4U + 1U] = MODEL_MEM_REGISTERS;
	model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_LOCAL_BASE) / 4U] = MODEL_LOCAL_BASE;
	model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_LOCAL_SIZE) / 4U] = MODEL_LOCAL_BYTES;
	model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_WINDOW_SIZE) / 4U] = MODEL_WINDOW_BYTES;
	model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_HOST_LIMIT) / 4U] = MODEL_HOST_LIMIT;
	model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_WINDOW_CTRL) / 4U] = GHCI_MEM_WINDOW_ENABLE;
}

#ifndef GHCI_MODEL_ONLY
/*
 * Writes a discrete GPU with a DISP2 display controller: 64-byte lines
 * (KC705's), the MEM capability followed by DISP2, and a controller with
 * a TMDS output, BGRA8 and RGBA8, a cursor plane, two modes and a sink
 * connected.
 */
static void
model_setup_display(void)
{
	/* The discrete GPU, then its display. */
	model_setup_window(1);
	model_registers[GHCI_CAPS / 4U] = GHCI_CAPS_CP | GHCI_CAPS_BLT | GHCI_CAPS_DISP | (6U << 20);
	model_registers[MODEL_EXTCAP / 4U] = GHCI_XCAP_MEM | (1U << 8) | (2U << 16);
	model_registers[MODEL_EXTCAP / 4U + 2U] = GHCI_XCAP_DISP2 | (1U << 8);
	model_registers[MODEL_EXTCAP / 4U + 3U] = MODEL_DISP2_REGISTERS;

	/* The controller, dark, with nothing pending. */
	memset(model_dc, 0, sizeof(model_dc));
	memset(model_dc_slot, 0, sizeof(model_dc_slot));
	model_dc[GHCI_DC_ID / 4U] = GHCI_FOURCC('A', 'T', 'D', 'C');
	model_dc[GHCI_DC_VERSION / 4U] = 0x00010000U;
	model_dc[GHCI_DC_CAPS / 4U] = 0x2U | 0x10U | 0x20U | GHCI_DC_CAPS_CURSOR | (MODEL_DC_MODES << 9);
	model_dc[GHCI_DC_CONNECTED / 4U] = 1U;
	model_dc_sticky = 0U;
	model_dc_frames = 0U;
	model_dc_hold = 0;
	model_dc_slot_busy = 0U;
	model_dc_flips = 0U;
	model_dc_bad_writes = 0U;
	model_dc_disp_sets = 0U;
	model_dc_present = 1;
}
#endif

/*
 * Runs a class 2 packet as the model firmware: [gpu-op][flags][result]
 * [arguments].  The control gpu-ops succeed; a frame writes each record's
 * result and the frame's own, then RESULT.
 */
static int
model_class_v(
	const uint32_t *ring,
	uint32_t at,
	uint32_t count)
{
	uint32_t pair[2];
	uint32_t reply[GHCI_REPLY_WORDS];
	uint32_t opcode;
	uint32_t flags;
	uint32_t result;
	uint32_t page;
	uint32_t records;
	uint32_t index;
	uint8_t *word;
	int answered;

	/* The head. */
	if (count < 3U) {
		model_fault(GHCI_FAULT_RING, ring[at]);
		return -1;
	}
	opcode = ring[at + 1U];
	flags = ring[at + 2U];
	result = ring[at + 3U];

	/* INIT and the diagnostics: a reply of 16 words (none for a silent INIT). */
	answered = model_firmware_op(ring, at, count, reply);
	if (answered >= 0) {
		if (answered == 0 || (flags & 2U) == 0U)
			return 0;
		word = model_memory(result, sizeof(reply));
		if (word == NULL) {
			model_fault(GHCI_FAULT_APERTURE, ring[at]);
			return -1;
		}
		memcpy(word, reply, sizeof(reply));
		model_irq_status |= GHCI_IRQ_RESULT;
		return 0;
	}

	/* A frame: each record's result, by index. */
	pair[0] = 0U;
	pair[1] = 0U;
	if (opcode == GPU_OP_GHCI_FRAME && count >= 8U) {
		model_frames++;
		model_frame_staging = ring[at + 4U];
		model_frame_bytes = ring[at + 6U];
		page = ring[at + 7U];
		records = ring[at + 8U];
		model_frame_records = records;
		for (index = 0U; index < records; index++) {
			pair[1] = 0U;
			if (index < MODEL_AUX_WORDS)
				pair[1] = model_aux[index];
			word = model_memory(page + 8U * index, 8U);
			if (word == NULL) {
				model_fault(GHCI_FAULT_APERTURE, ring[at]);
				return -1;
			}
			memcpy(word, pair, 8U);
		}
		pair[1] = records;
	} else {
		model_control_packets++;
		model_last_control = opcode;
		if (model_control_count < MODEL_CONTROL_LOG) {
			model_controls[model_control_count].opcode = opcode;
			model_controls[model_control_count].tag = (ring[at] >> 16) & 0xFFU;
			model_controls[model_control_count].flags = flags;
			for (index = 0U; index < MODEL_CONTROL_ARGUMENTS; index++)
				model_controls[model_control_count].arguments[index] = index + 3U < count ? ring[at + 4U + index] : 0U;
			model_controls[model_control_count].table =
			    model_registers[(MODEL_PROT_REGISTERS + GHCI_PROT_TABLE) / 4U];
			model_control_count++;
		}
	}

	/* The packet's own result, then RESULT. */
	if ((flags & 2U) != 0U) {
		word = model_memory(result, 8U);
		if (word == NULL) {
			model_fault(GHCI_FAULT_APERTURE, ring[at]);
			return -1;
		}
		memcpy(word, pair, 8U);
		model_irq_status |= GHCI_IRQ_RESULT;
	}

	/* The packet was taken. */
	return 0;
}

/*
 * Runs INIT or a diagnostic as the model firmware into a reply: 1 when
 * it answers, 0 when it stays silent, -1 for another gpu-op.
 */
static int
model_firmware_op(
	const uint32_t *ring,
	uint32_t at,
	uint32_t count,
	uint32_t *reply)
{
	uint32_t opcode;
	uint32_t address;
	uint32_t bytes;
	uint32_t index;
	uint32_t value;
	uint8_t *memory;

	/* Only these gpu-ops. */
	opcode = ring[at + 1U];
	memset(reply, 0, GHCI_REPLY_WORDS * 4U);
	if (opcode == GHCI_GPU_OP_INIT) {
		model_inits++;
		if (model_init_mode == MODEL_INIT_SILENT)
			return 0;
		if (model_init_mode == MODEL_INIT_OLD_FIRMWARE) {
			reply[0] = (uint32_t)-8;
			return 1;
		}
		reply[1] = ring[at + 4U];
		if (model_init_mode == MODEL_INIT_WRONG_TOKEN)
			reply[1] ^= 1U;
		reply[GHCI_INIT_NOT_TOKEN] = ~ring[at + 4U];
		reply[GHCI_INIT_VERSION] = 0x00020001U;
		reply[GHCI_INIT_PROTOCOL_WORD] = GHCI_INIT_PROTOCOL;
		reply[GHCI_INIT_FEATURES] = GHCI_INIT_F_DIAG | GHCI_INIT_F_VULKAN;
		reply[GHCI_INIT_LINE] = 64U;
		reply[GHCI_INIT_SESSIONS] = 32U;
		reply[GHCI_INIT_PACKET] = model_registers[GHCI_RING_BASE / 4U] + (at + 1U) * 4U;
		return 1;
	}
	if (opcode != GHCI_GPU_OP_DIAG_ECHO && opcode != GHCI_GPU_OP_DIAG_WRITE && opcode != GHCI_GPU_OP_DIAG_SUM)
		return -1;
	model_diags++;

	/* The echo. */
	if (opcode == GHCI_GPU_OP_DIAG_ECHO) {
		reply[1] = ring[at + 4U];
		for (index = 0U; index < reply[1] && index < GHCI_DIAG_ECHO_WORDS && 4U + index < count; index++)
			reply[2U + index] = ring[at + 5U + index];
		return 1;
	}

	/* A pattern written or summed, over the model's memory. */
	address = ring[at + 4U];
	bytes = ring[at + 6U];
	memory = model_memory(address, bytes);
	if (memory == NULL) {
		reply[0] = (uint32_t)-4;
		return 1;
	}
	reply[1] = bytes;
	for (index = 0U; index < bytes / 4U; index++) {
		if (opcode == GHCI_GPU_OP_DIAG_WRITE) {
			value = ring[at + 7U] + index * ring[at + 8U];
			memcpy(&memory[index * 4U], &value, 4U);
			continue;
		}
		memcpy(&value, &memory[index * 4U], 4U);
		reply[GHCI_DIAG_SUM_PLAIN] += value;
		reply[GHCI_DIAG_SUM_WEIGHTED] += (index + 1U) * value;
		if (index < 4U)
			reply[GHCI_DIAG_SUM_FIRST + index] = value;
		reply[GHCI_DIAG_SUM_LAST] = value;
	}
	return 1;
}

/* Reads a register of the display controller's window. */
static uint32_t
model_dc_read(
	uint32_t offset)
{
	uint32_t value;
	uint32_t index;

	/* STATUS: what the controller does now, its sticky errors and its pending flips. */
	if (offset == GHCI_DC_STATUS) {
		value = model_dc_sticky;
		if ((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) != 0U) {
			value |= GHCI_DC_ST_RUNNING;
		} else {
			value |= GHCI_DC_ST_IDLE;
		}
		if ((model_dc[GHCI_DC_CONNECTED / 4U] & 1U) != 0U)
			value |= GHCI_DC_ST_CONNECTED;
		if (model_dc_slot[0].pending)
			value |= GHCI_DC_ST_PENDING0;
		if (model_dc_slot[1].pending)
			value |= GHCI_DC_ST_PENDING1;
		if (model_dc_slot[0].due || model_dc_slot[1].due)
			value |= GHCI_DC_ST_RECORD;
		return value;
	}

	/* The mode the index selects. */
	if (offset >= GHCI_DC_MODE_H0 && offset <= GHCI_DC_MODE_FLAGS) {
		index = model_dc[GHCI_DC_MODE_INDEX / 4U];
		if (index >= MODEL_DC_MODES)
			return 0U;
		return model_dc_modes[index][(offset - GHCI_DC_MODE_H0) / 4U];
	}

	/* The frame count. */
	if (offset == GHCI_DC_FRAME_COUNT)
		return model_dc_frames;

	/* Every other register reads what is stored. */
	return model_dc[offset / 4U];
}

/* Writes a register of the display controller's window from the host, through the gate. */
static void
model_dc_write(
	uint32_t offset,
	uint32_t value)
{
	int scanout;

	/* STATUS clears the sticky errors it names. */
	if (offset == GHCI_DC_STATUS) {
		model_dc_sticky &= ~value;
		return;
	}

	/* CONNECTED raises HOTPLUG when it changes. */
	if (offset == GHCI_DC_CONNECTED) {
		if ((model_dc[offset / 4U] & 1U) != (value & 1U))
			model_irq_status |= GHCI_IRQ_HOTPLUG;
		model_dc[offset / 4U] = value & 1U;
		return;
	}

	/* The index, the cursor and the I2C registers are the host's in every state. */
	scanout = model_dc_scanout_register(offset);
	if (!scanout) {
		if (offset == GHCI_DC_MODE_INDEX ||
		    offset == GHCI_DC_CURSOR_POS ||
		    offset == GHCI_DC_CURSOR_CTRL ||
		    (offset >= GHCI_DC_I2C_CTRL && offset <= GHCI_DC_I2C_DATA))
			model_dc[offset / 4U] = value;
		return;
	}

	/* The scan-out registers are the ring's while the processor runs: the write is refused. */
	if (model_state == GHCI_ST_RUNNING || model_state == GHCI_ST_HALTING) {
		model_dc_sticky |= GHCI_DC_ST_BAD_WRITE;
		model_dc_bad_writes++;
		return;
	}

	/* FB_NEXT from the host replaces plane 0's pending flip, cancelled; with ENABLE 0 it shows at once. */
	if (offset == GHCI_DC_FB_NEXT) {
		if (model_dc_slot[0].pending)
			model_dc_take(0U, 1);
		if ((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U)
			model_dc[GHCI_DC_FB_BASE / 4U] = value;
		model_dc[offset / 4U] = value;
		return;
	}

	/* The rest as DISP_SET writes it. */
	model_dc_apply(offset, value);
}

/* Reports whether an offset is a scan-out register (kind S). */
static int
model_dc_scanout_register(
	uint32_t offset)
{
	if (offset == GHCI_DC_CTRL)
		return 1;
	if (offset >= GHCI_DC_FB_NEXT && offset <= GHCI_DC_SYNC_POL)
		return 1;
	if (offset == GHCI_DC_PCLK_SEL)
		return 1;
	return 0;
}

/* Writes a scan-out or cursor register as the controller takes it (DISP_SET, or the host through the gate). */
static void
model_dc_apply(
	uint32_t offset,
	uint32_t value)
{
	uint32_t old;
	int enabled;

	/* CTRL: the controller's reset, ENABLE falling (every pending flip cancelled), FORMAT kept while lit. */
	old = model_dc[GHCI_DC_CTRL / 4U];
	enabled = (old & GHCI_DC_CTRL_ENABLE) != 0U;
	if (offset == GHCI_DC_CTRL) {
		if ((value & GHCI_DC_CTRL_RESET) != 0U) {
			if (model_dc_slot[0].pending)
				model_dc_take(0U, 1);
			if (model_dc_slot[1].pending)
				model_dc_take(1U, 1);
			model_dc[GHCI_DC_CTRL / 4U] = 0U;
			model_dc[GHCI_DC_CONNECTED / 4U] = 1U;
			model_dc_frames = 0U;
			return;
		}
		if (enabled && (value & GHCI_DC_CTRL_ENABLE) != 0U && (value & 0x30U) != (old & 0x30U)) {
			model_dc_sticky |= GHCI_DC_ST_BAD_WRITE;
			model_dc_bad_writes++;
			value = (value & ~0x30U) | (old & 0x30U);
		}
		model_dc[GHCI_DC_CTRL / 4U] = value;
		if (enabled && (value & GHCI_DC_CTRL_ENABLE) == 0U) {
			if (model_dc_slot[0].pending)
				model_dc_take(0U, 1);
			if (model_dc_slot[1].pending)
				model_dc_take(1U, 1);
		}
		return;
	}

	/* The timing and the image's rows change only while ENABLE is 0. */
	if (enabled && offset != GHCI_DC_CURSOR_POS && offset != GHCI_DC_CURSOR_CTRL) {
		model_dc_sticky |= GHCI_DC_ST_BAD_WRITE;
		model_dc_bad_writes++;
		return;
	}
	model_dc[offset / 4U] = value;
}

/*
 * Takes a plane's pending flip: TAKENn, the image (unless cancelled),
 * the record {value, FRAME_COUNT} and FLIP; a record due while the
 * processor is halted or faulted waits until it leaves those states.
 */
static void
model_dc_take(
	unsigned plane,
	int cancelled)
{
	struct model_dc_flip *flip;
	uint32_t value;
	uint8_t *record;

	flip = &model_dc_slot[plane];
	flip->pending = 0;
	value = flip->value;
	if (cancelled)
		value |= GHCI_FLIP_CANCELLED;
	if (plane == 0U) {
		model_dc[GHCI_DC_TAKEN0 / 4U] = value;
		if (!cancelled)
			model_dc[GHCI_DC_FB_BASE / 4U] = flip->base;
	} else {
		model_dc[GHCI_DC_TAKEN1 / 4U] = value;
		if (!cancelled)
			model_dc[GHCI_DC_CURSOR_BASE / 4U] = flip->base;
	}

	/* The record, now or once the processor writes again. */
	flip->due_words[0] = value;
	flip->due_words[1] = model_dc_frames;
	flip->due = 1;
	if (model_state == GHCI_ST_HALTED || model_state == GHCI_ST_FAULTED)
		return;
	flip->due = 0;
	if (flip->record != 0U) {
		record = model_memory(flip->record, 8U);
		if (record == NULL) {
			model_dc_sticky |= GHCI_DC_ST_RECORD_ERROR;
		} else {
			memcpy(record, flip->due_words, 8U);
		}
	}
	model_irq_status |= GHCI_IRQ_FLIP;
}

/* Writes the records that waited for the processor to leave HALTED or FAULTED. */
static void
model_dc_records_flush(void)
{
	unsigned plane;
	uint8_t *record;

	for (plane = 0U; plane < 2U; plane++) {
		if (!model_dc_slot[plane].due)
			continue;
		model_dc_slot[plane].due = 0;
		if (model_dc_slot[plane].record != 0U) {
			record = model_memory(model_dc_slot[plane].record, 8U);
			if (record != NULL)
				memcpy(record, model_dc_slot[plane].due_words, 8U);
		}
		model_irq_status |= GHCI_IRQ_FLIP;
	}
}

/* Runs a DISP_SET or a FLIP: 0, or a fault. */
static int
model_dc_packet(
	const uint32_t *ring,
	uint32_t at,
	uint32_t op,
	uint32_t flags,
	uint32_t count)
{
	struct model_dc_flip *flip;
	uint32_t index;
	uint32_t offset;
	uint32_t plane;
	uint32_t line;

	(void)flags;

	/* A GPU without a display controller has no such operation. */
	if (!model_dc_present) {
		model_fault(GHCI_FAULT_OPCODE, ring[at]);
		return -1;
	}

	/* DISP_SET: (offset, value) pairs of scan-out and cursor registers, FB_NEXT not among them. */
	if (op == GHCI_OP_DISP_SET) {
		model_dc_disp_sets++;
		if ((count % 2U) != 0U || count == 0U) {
			model_fault(GHCI_FAULT_RING, ring[at]);
			return -1;
		}
		for (index = 0U; index < count; index += 2U) {
			offset = ring[at + 1U + index];
			if (offset >= GHCI_DC2_WINDOW || (offset % 4U) != 0U || offset == GHCI_DC_FB_NEXT ||
			    (!model_dc_scanout_register(offset) && offset != GHCI_DC_CURSOR_POS && offset != GHCI_DC_CURSOR_CTRL)) {
				model_fault(GHCI_FAULT_RING, ring[at]);
				return -1;
			}
			model_dc_apply(offset, ring[at + 2U + index]);
		}
		return 0;
	}

	/* FLIP: plane, base, record, value; the base on the line (64 bytes for the cursor), the record on 8 bytes. */
	model_dc_flips++;
	if (count != 4U) {
		model_fault(GHCI_FAULT_RING, ring[at]);
		return -1;
	}
	plane = ring[at + 1U];
	line = 1U << GHCI_CAPS_LINE_LOG2(model_registers[GHCI_CAPS / 4U]);
	if (plane == 1U)
		line = 64U;
	if (plane > 1U || (ring[at + 2U] % line) != 0U || (ring[at + 3U] % 8U) != 0U) {
		model_fault(GHCI_FAULT_RING, ring[at]);
		return -1;
	}
	flip = &model_dc_slot[plane];
	if (flip->pending)
		model_dc_slot_busy++;
	flip->pending = 1;
	flip->base = ring[at + 2U];
	flip->record = ring[at + 3U];
	flip->value = ring[at + 4U];

	/* With ENABLE 0 plane 0 takes it at once, and the cursor's is cancelled at once. */
	if ((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U)
		model_dc_take(plane, plane == 1U);
	return 0;
}

/* One vertical sync of a lit controller, unless the test holds them: each plane takes its pending flip. */
static void
model_vsync(void)
{
	/* A dark or absent controller, or a held one, has no sync. */
	if (!model_dc_present || model_dc_hold)
		return;
	if ((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U)
		return;

	/* The frame, and the flips it takes. */
	model_dc_frames++;
	if (model_dc_slot[0].pending)
		model_dc_take(0U, 0);
	if (model_dc_slot[1].pending)
		model_dc_take(1U, 0);
	model_irq_status |= GHCI_IRQ_VBLANK;
	model_interrupt();
}

#ifndef GHCI_MODEL_ONLY
/* Builds a native command of a fill and a fence into stream; returns its dwords. */
static uint32_t
native_fill(
	uint32_t *stream,
	uint32_t base,
	uint32_t pixels,
	uint32_t color,
	uint32_t fence_address,
	uint32_t fence_value)
{
	stream[0] = GPU_OP_GHCI_NATIVE;
	stream[1] = 0U;
	stream[2] = 3U;
	stream[3] = GHCI_PKT_N(0U, GHCI_OP_SET_REG, 0U, 0U, 12U);
	stream[4] = GHCI_S_BLT_OP;
	stream[5] = GHCI_BLT_FILL;
	stream[6] = GHCI_S_BLT_DST_BASE;
	stream[7] = base;
	stream[8] = GHCI_S_BLT_DST_STRIDE;
	stream[9] = pixels * 4U;
	stream[10] = GHCI_S_BLT_DST_XY;
	stream[11] = 0U;
	stream[12] = GHCI_S_BLT_SIZE;
	stream[13] = (1U << 16) | pixels;
	stream[14] = GHCI_S_BLT_COLOR;
	stream[15] = color;
	stream[16] = GHCI_PKT_N(0U, GHCI_OP_BLIT, 0U, 0U, 0U);
	ghci_packet_fence(0U, fence_address, fence_value, 0, &stream[17]);
	return 20U;
}

/* Runs the discrete GPU: start, memory, transfers, the ring's wrap, faults, hangs, the native command, the stop. */
static void
test_discrete(void)
{
	static struct ghci_device device;
	struct gpu_resource_create storage_request;
	struct gpu_blob_create blob_request;
	struct gpu_info info;
	struct drv_gpu_mapping mapping;
	struct ghci_ticket ticket;
	struct ghci_ticket first;
	struct ghci_allocation *storage;
	struct ghci_allocation *blob;
	struct ghci_allocation *other;
	struct ghci_session *session;
	uint32_t packets[GHCI_BLIT_PACKET_DWORDS + 1U];
	uint32_t stream[32];
	uint32_t pattern[1024];
	uint32_t readback[1024];
	uint32_t word;
	uint32_t dwords;
	uint32_t resource_id;
	uint32_t wraps;
	uint32_t previous_wptr;
	uint64_t free_before;
	unsigned index;
	unsigned resets;
	int failures;
	int error;
	void *object;
	void *opaque;

	/* The model and the device's bus fields, as the PCI glue fills them. */
	model_setup_window(1);
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;

	/* The start: identification, reset, memory, ring, registration. */
	error = ghci_device_start(&device);
	expect(error == 0, "discrete start");
	expect(strcmp(device.name, "ghci:AMAT:ATG1") == 0, "discrete name");
	expect(device.local_base == MODEL_LOCAL_BASE && device.local_size == MODEL_LOCAL_BYTES, "discrete local memory");
	expect(device.local_window == MODEL_WINDOW_BYTES, "discrete window");
	expect(device.host_limit == MODEL_HOST_LIMIT, "discrete host limit");
	expect(model_state == GHCI_ST_RUNNING, "discrete processor runs");
	expect(model_registers[GHCI_APERTURE_BASE / 4U] == 32U, "discrete aperture from the first line");
	expect(model_registers[GHCI_APERTURE_LIMIT / 4U] == MODEL_LOCAL_BASE + MODEL_LOCAL_BYTES, "discrete aperture covers the host and the local memory");
	expect((model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_WINDOW_CTRL) / 4U] & GHCI_MEM_WINDOW_ENABLE) == 0U, "discrete window closed");
	expect(device.ring != NULL && device.ring->kind == GHCI_MEMORY_HOST, "discrete ring in host memory");
	expect(device.ring->gpu_address >= MODEL_HOST_BASE && device.ring->gpu_address < MODEL_HOST_LIMIT, "discrete ring below the host limit");
	expect(device.fence_page != NULL && device.fence_page->kind == GHCI_MEMORY_HOST, "discrete fence page in host memory");
	expect(device.bounce != NULL && device.bounce->kind == GHCI_MEMORY_HOST, "discrete bounce buffer in host memory");
	expect(model_registers[GHCI_RING_BASE / 4U] == device.ring->gpu_address, "discrete ring base");
	expect(model_registers[GHCI_RING_SIZE / 4U] == GHCI_RING_SIZE_LOG2, "discrete ring size");
	expect(model_irq_enable == (GHCI_IRQ_FENCE | GHCI_IRQ_FAULT | GHCI_IRQ_WATCHDOG | GHCI_IRQ_RESULT | GHCI_IRQ_FLIP | GHCI_IRQ_DISP_ERROR | GHCI_IRQ_HOTPLUG), "discrete interrupts enabled");
	expect(core_ops != NULL && core_private == &device, "discrete registered");

	/* The device's capabilities: storage, blobs, transfers, mappings and the test's native command. */
	core_ops->open(core_private, &opaque);
	session = opaque;
	error = core_ops->get_info(core_private, opaque, &info);
	expect(error == 0, "discrete info");
	expect(info.capabilities == (GPU_CAP_RESOURCE | GPU_CAP_BLOB | GPU_CAP_TRANSFER | GPU_CAP_MAPPING | GPU_CAP_COMMAND | GPU_CAP_SHARE | GPU_CAP_ALLOCATION_SHARE), "discrete capabilities");
	expect(strcmp(info.driver_name, "ghci:AMAT:ATG1") == 0, "discrete driver name");
	expect(session->tag == 1U, "discrete first session takes tag 1");

	/* Storage the processor maps is host memory, cleared, and maps as RAM. */
	memset(&storage_request, 0, sizeof(storage_request));
	storage_request.bytes = 10000U;
	storage_request.usage = GPU_RESOURCE_USAGE_STORAGE;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	storage = object;
	expect(error == 0 && storage->kind == GHCI_MEMORY_HOST, "discrete storage in host memory");
	expect(storage->bytes == 12288U && storage->requested == 10000U, "discrete storage in whole pages");
	failures = 0;
	for (index = 0U; index < storage->bytes; index++) {
		if (storage->view[index] != 0U)
			failures++;
	}
	expect(failures == 0, "discrete storage cleared");
	error = core_ops->resource_map(core_private, opaque, object, &mapping);
	expect(error == 0 && mapping.attributes == 0U, "discrete storage maps as RAM");
	expect(mapping.physical == storage->gpu_address, "discrete storage's physical place is its bus address");

	/* A blob that is not mappable is the GPU's own local memory past the window, named by its address. */
	memset(&blob_request, 0, sizeof(blob_request));
	blob_request.bytes = sizeof(pattern);
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object, &resource_id);
	blob = object;
	expect(error == 0 && blob->kind == GHCI_MEMORY_UNWINDOWED, "discrete device blob past the window");
	expect(resource_id == blob->gpu_address && blob->view == NULL, "discrete blob named by its GPU address");
	error = core_ops->resource_map(core_private, opaque, object, &mapping);
	expect(error == EINVAL, "discrete hidden blob does not map");

	/* A write and a read of hidden memory go through the bounce buffer, by the blitter. */
	for (index = 0U; index < 1024U; index++)
		pattern[index] = 0x01020304U * (index + 1U);
	error = core_ops->resource_write(core_private, opaque, object, 0U, pattern, sizeof(pattern));
	expect(error == 0, "discrete write to hidden memory");
	expect(memcmp(&model_local[blob->gpu_address - MODEL_LOCAL_BASE], pattern, sizeof(pattern)) == 0, "discrete hidden memory holds the write");
	memset(readback, 0, sizeof(readback));
	error = core_ops->resource_read(core_private, opaque, object, 0U, readback, sizeof(readback));
	expect(error == 0 && memcmp(readback, pattern, sizeof(pattern)) == 0, "discrete read of hidden memory");
	error = core_ops->resource_read(core_private, opaque, object, 2U, readback, 8U);
	expect(error == EINVAL, "discrete unaligned read of hidden memory");
	error = core_ops->resource_read(core_private, opaque, object, 4090U, readback, 8U);
	expect(error == EINVAL, "discrete read past the blob");
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object, &resource_id);
	expect(error == 0, "discrete second blob");
	other = object;
	blob_request.flags = GPU_BLOB_SHAREABLE | GPU_BLOB_CROSS_DEVICE;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object, &resource_id);
	expect(error == ENOTSUP, "discrete blob for another device refused");
	blob_request.flags = 0U;
	blob_request.blob_id = 5U;
	error = core_ops->blob_create(core_private, opaque, &blob_request, &object, &resource_id);
	expect(error == EINVAL, "discrete blob of a Vulkan memory refused");
	blob_request.blob_id = 0U;

	/* The native command: refused for a user, taken for root, and the fill lands. */
	core_superuser = 0;
	dwords = native_fill(stream, storage->gpu_address, 256U, 0xdeadbeefU, storage->gpu_address + 4096U, 77U);
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	expect(error == EPERM, "discrete native command needs root");
	core_superuser = 1;
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	expect(error == 0, "discrete native command taken");
	memcpy(&word, &storage->view[1020], 4U);
	expect(word == 0xdeadbeefU, "discrete native fill landed");
	memcpy(&word, &storage->view[4096], 4U);
	expect(word == 77U, "discrete native fence landed");
	expect(session->outstanding == 1, "discrete session has work in flight");
	dwords = native_fill(stream, blob->gpu_address, 1025U, 0U, storage->gpu_address, 1U);
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	expect(error == EINVAL, "discrete native fill past its blob refused");

	/* The ring wraps many times: every submission's fence passes, no packet crosses the end. */
	wraps = 0U;
	failures = 0;
	model_packets_crossing = 0U;
	for (index = 0U; index < 5000U; index++) {
		/* Runs of 1 to 20 invalidations, so the padding falls in many places. */
		previous_wptr = device.wptr;
		dwords = 1U + index % 20U;
		for (word = 0U; word < dwords; word++)
			ghci_packet_invalidate(0U, 1U, &packets[word]);
		error = ghci_cp_submit(&device, NULL, packets, dwords, &ticket);
		if (error != 0)
			failures++;
		if (device.wptr < previous_wptr)
			wraps++;
		error = ghci_cp_wait(&device, &ticket, 100U);
		if (error != 0)
			failures++;
	}
	expect(failures == 0, "discrete ring stress submissions pass");
	expect(wraps >= 4U, "discrete ring wrapped four times");
	expect(model_packets_crossing == 0U, "discrete no packet crosses the ring's end");

	/* The fence wraps around 2^32. */
	device.fence_issued = 0xfffffff0U;
	device.completed = 0xfffffff0U;
	failures = 0;
	for (index = 0U; index < 40U; index++) {
		ghci_packet_invalidate(0U, 1U, &packets[0]);
		error = ghci_cp_submit(&device, NULL, packets, 1U, &ticket);
		if (error == 0)
			error = ghci_cp_wait(&device, &ticket, 100U);
		if (error != 0)
			failures++;
	}
	expect(failures == 0 && device.completed == 0x18U, "discrete fence wraps around 2^32");

	/* Deferred release: with the processor paused, a destroyed resource waits for the session's fence. */
	model_paused = 1;
	dwords = native_fill(stream, storage->gpu_address, 16U, 1U, storage->gpu_address + 4096U, 78U);
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	expect(error == 0, "discrete paused native command");
	free_before = ghci_range_free_bytes(&device.unwindowed);
	core_ops->resource_destroy(core_private, opaque, other);
	expect(device.deferred != NULL, "discrete destroyed blob deferred");
	expect(ghci_range_free_bytes(&device.unwindowed) == free_before, "discrete deferred blob still in use");
	ghci_service_step(&device, GHCI_WORK_RECLAIM);
	expect(device.deferred != NULL, "discrete reclaim waits for the fence");
	model_paused = 0;
	model_run();
	ghci_service_step(&device, GHCI_WORK_RECLAIM);
	expect(device.deferred == NULL, "discrete reclaim after the fence");
	expect(ghci_range_free_bytes(&device.unwindowed) == free_before + 4096U, "discrete blob memory back");
	expect(core_capacity_notes != 0U, "discrete capacity announced");

	/* A fault: the processor stops, the service resets it, old tickets end with an error, the ring runs again. */
	resets = device.resets;
	packets[0] = GHCI_PKT_N(0U, GHCI_OP_DRAW, session->tag, 0U, 0U);
	error = ghci_cp_submit(&device, session, packets, 1U, &first);
	expect(error == 0 && model_state == GHCI_ST_FAULTED, "discrete fault stops the processor");
	expect((device.service_work & GHCI_WORK_RECOVER) != 0U, "discrete fault wakes the recovery");
	expect(GHCI_FAULT_KIND(device.fault_info) == GHCI_FAULT_OPCODE && GHCI_FAULT_JOB_TAG(device.fault_info) == session->tag, "discrete fault recorded with the session's tag");
	ghci_service_step(&device, GHCI_WORK_RECOVER);
	expect(device.resets == resets + 1U && model_state == GHCI_ST_RUNNING, "discrete reset after the fault");
	expect(device.wptr == 0U && model_rptr == 0U, "discrete ring starts again at 0");
	error = ghci_cp_wait(&device, &first, 100U);
	expect(error == EIO, "discrete faulted ticket ends with an error");
	expect(core_session_errors == 1U && session->outstanding == 0, "discrete session told of its loss");
	ghci_packet_invalidate(0U, 1U, &packets[0]);
	error = ghci_cp_submit(&device, NULL, packets, 1U, &ticket);
	if (error == 0)
		error = ghci_cp_wait(&device, &ticket, 100U);
	expect(error == 0, "discrete work runs after the reset");

	/* A hang: the processor is paused with work outstanding until the hang time passes. */
	model_paused = 1;
	error = ghci_cp_submit(&device, NULL, packets, 1U, &first);
	expect(error == 0, "discrete submission that will hang");
	ghci_service_step(&device, 0U);
	expect(device.resets == resets + 1U, "discrete no reset before the hang time");
	fake_ticks += kern_ms_to_ticks(GHCI_HANG_MS) + 1U;
	ghci_service_step(&device, 0U);
	expect(device.resets == resets + 2U, "discrete reset after the hang time");
	model_paused = 0;
	error = ghci_cp_wait(&device, &first, 100U);
	expect(error == EIO, "discrete hung ticket ends with an error");

	/* The close gives everything back; the stop halts and resets the processor with an empty aperture. */
	core_ops->close(core_private, opaque);
	expect(device.session_count == 0U, "discrete session closed");
	error = ghci_device_stop(&device);
	expect(error == 0, "discrete stop");
	expect(model_state == GHCI_ST_IDLE, "discrete processor idle after the stop");
	expect(model_registers[GHCI_APERTURE_LIMIT / 4U] == 0U, "discrete aperture empty after the stop");
	expect(device.windowed.count == 0U && device.unwindowed.count == 0U, "discrete local memory all back");
	expect((model_registers[(MODEL_MEM_REGISTERS + GHCI_MEM_WINDOW_CTRL) / 4U] & GHCI_MEM_WINDOW_ENABLE) != 0U, "discrete window open again after the stop");
	expect(model_guard_changed() == 0U, "discrete driver did not touch the local window");
	model_device = NULL;
}

/* Runs the unified GPU: everything in host RAM, the aperture open. */
static void
test_unified(void)
{
	static struct ghci_device device;
	struct gpu_resource_create storage_request;
	struct drv_gpu_mapping mapping;
	struct ghci_allocation *storage;
	struct ghci_ticket ticket;
	uint32_t packets[1];
	uint32_t stream[32];
	uint32_t dwords;
	uint32_t word;
	int error;
	void *object;
	void *opaque;

	/* The model without local memory, and the device without a window. */
	model_setup_window(0);
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	model_device = &device;

	/* The start puts the ring in host RAM and opens the aperture but its first line. */
	error = ghci_device_start(&device);
	expect(error == 0, "unified start");
	expect(device.local_size == 0U && device.ring->kind == GHCI_MEMORY_HOST, "unified ring in host RAM");
	expect(model_registers[GHCI_APERTURE_BASE / 4U] == 32U, "unified aperture from the second line");
	expect(model_registers[GHCI_APERTURE_LIMIT / 4U] == 0xffffffe0U, "unified aperture to the last line");

	/* Storage is host RAM, maps as RAM, and the GPU writes into it. */
	core_ops->open(core_private, &opaque);
	memset(&storage_request, 0, sizeof(storage_request));
	storage_request.bytes = 8192U;
	storage_request.usage = GPU_RESOURCE_USAGE_STORAGE;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	storage = object;
	expect(error == 0 && storage->kind == GHCI_MEMORY_HOST, "unified storage in host RAM");
	expect(storage->view[0] == 0U && storage->view[8191] == 0U, "unified storage cleared");
	error = core_ops->resource_map(core_private, opaque, object, &mapping);
	expect(error == 0 && mapping.attributes == 0U && mapping.physical == storage->gpu_address, "unified storage maps as RAM");
	core_superuser = 1;
	dwords = native_fill(stream, storage->gpu_address, 64U, 0x11223344U, storage->gpu_address + 4096U, 9U);
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	memcpy(&word, &storage->view[252], 4U);
	expect(error == 0 && word == 0x11223344U, "unified native fill of host RAM");
	ghci_packet_invalidate(0U, 1U, &packets[0]);
	error = ghci_cp_submit(&device, NULL, packets, 1U, &ticket);
	if (error == 0)
		error = ghci_cp_wait(&device, &ticket, 100U);
	expect(error == 0, "unified fence in host RAM");

	/* The close and the stop. */
	core_ops->close(core_private, opaque);
	error = ghci_device_stop(&device);
	expect(error == 0, "unified stop");
	model_device = NULL;
}

/*
 * The unified GPU as the VisionFive 2 has it (ws288-p043): polled, with
 * no interrupt (IRQ_ENABLE stays 0 and the poll takes the enabled bits of
 * IRQ_STATUS), and with host memory reached through uncached views (the
 * user's mapping is uncached RAM, and every view goes at the stop).
 */
static void
test_polled_uncached(void)
{
	static struct ghci_device device;
	struct gpu_resource_create storage_request;
	struct drv_gpu_mapping mapping;
	struct ghci_allocation *storage;
	struct ghci_ticket ticket;
	uint32_t packets[1];
	uint32_t stream[32];
	uint32_t dwords;
	uint32_t word;
	unsigned maps;
	int error;
	void *object;
	void *opaque;

	/* The model without local memory, and a polled device that views host memory uncached. */
	model_setup_window(0);
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.polled = 1;
	device.host_uncached = 1;
	model_device = &device;
	uncached_maps = 0U;
	uncached_unmaps = 0U;
	uncached_bytes = 0U;

	/* The start keeps the interrupt off and views the ring, the fence page and the bounce buffer uncached. */
	error = ghci_device_start(&device);
	expect(error == 0, "polled start");
	expect(model_irq_enable == 0U, "polled: IRQ_ENABLE stays 0");
	expect(device.irq_mask != 0U, "polled: the driver still takes its interrupts by poll");
	expect(uncached_maps >= 3U, "uncached: ring, fence page and bounce buffer viewed uncached");
	expect(device.ring->view == &model_host[device.ring->physical - MODEL_HOST_BASE], "uncached: the ring's view is the uncached one");

	/* The GPU's work is seen through the uncached views: a fill of storage and a fence. */
	core_ops->open(core_private, &opaque);
	memset(&storage_request, 0, sizeof(storage_request));
	storage_request.bytes = 8192U;
	storage_request.usage = GPU_RESOURCE_USAGE_STORAGE;
	maps = uncached_maps;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	storage = object;
	expect(error == 0 && storage->kind == GHCI_MEMORY_HOST, "uncached: storage in host RAM");
	expect(uncached_maps == maps + 1U, "uncached: storage viewed uncached");
	error = core_ops->resource_map(core_private, opaque, object, &mapping);
	expect(error == 0 && mapping.attributes == DRV_GPU_MAPPING_UNCACHED_RAM, "uncached: storage maps as uncached RAM");
	core_superuser = 1;
	dwords = native_fill(stream, storage->gpu_address, 64U, 0x55667788U, storage->gpu_address + 4096U, 9U);
	error = core_ops->command(core_private, opaque, stream, dwords * 4U);
	memcpy(&word, &storage->view[252], 4U);
	expect(error == 0 && word == 0x55667788U, "polled: native fill without an interrupt");
	ghci_packet_invalidate(0U, 1U, &packets[0]);
	error = ghci_cp_submit(&device, NULL, packets, 1U, &ticket);
	if (error == 0)
		error = ghci_cp_wait(&device, &ticket, 100U);
	expect(error == 0, "polled: fence seen without an interrupt");
	expect(model_irq_enable == 0U, "polled: IRQ_ENABLE still 0 after work");

	/* A poll takes the enabled events and clears them, and leaves the interrupt off. */
	model_irq_status = GHCI_IRQ_FENCE | GHCI_IRQ_SOFT;
	(void)ghci_cp_interrupt(&device);
	expect(model_irq_status == GHCI_IRQ_SOFT, "polled: the poll clears what the driver takes, not the rest");
	expect(model_irq_enable == 0U, "polled: the poll does not enable the interrupt");
	model_irq_status = 0U;

	/* The close and the stop give every uncached view back. */
	core_ops->close(core_private, opaque);
	error = ghci_device_stop(&device);
	expect(error == 0, "polled stop");
	expect(uncached_unmaps == uncached_maps && uncached_bytes == 0U, "uncached: every view removed at the stop");
	core_superuser = 0;
	model_device = NULL;
}

/*
 * The firmware's handshake, diagnostics and reload on a discrete GPU with
 * firmware (no shader unit, so no executor) and a CPFW capability: a
 * start whose INIT is answered right, wrong or not at all, or by a
 * firmware older than INIT; the diagnostics from the driver and from
 * root's command; INIT again after a reset; a reload from host memory and
 * through local memory.
 */
static void
test_firmware(void)
{
	static struct ghci_device device;
	uint32_t stream[16];
	uint32_t inits;
	uint32_t word;
	uint8_t *memory;
	int error;
	void *opaque;

	/* The right answer starts the device, with the diagnostics. */
	error = firmware_start(&device, MODEL_INIT_RIGHT);
	expect(error == 0, "firmware: the start with INIT answered");
	expect(model_inits == 1U, "firmware: INIT sent once at the start");
	expect((device.fw_features & GHCI_INIT_F_DIAG) != 0U && device.fw_version == 0x00020001U, "firmware: INIT's version and features kept");

	/* The diagnostics pass on the model, with its firmware's steps. */
	model_diags = 0U;
	error = ghci_firmware_diag(&device, 3U);
	expect(error == 0, "firmware: the diagnostics pass");
	expect(model_diags == 3U * 6U, "firmware: six gpu-ops of the diagnostics a round (echo, write, sum through both views, local write and sum)");
	expect(device.diag_alias != NULL, "firmware: an uncached view of the host buffer beside the direct map");
	expect(model_registers[GHCI_SCRATCH / 4U] != 0U, "firmware: the register step wrote SCRATCH");
	error = ghci_firmware_diag(&device, 0U);
	expect(error == EINVAL, "firmware: no rounds refused");

	/* Root alone sends the command. */
	core_ops->open(core_private, &opaque);
	stream[0] = GPU_OP_GHCI_DIAG;
	stream[1] = 0U;
	stream[2] = 1U;
	core_superuser = 0;
	error = core_ops->command(core_private, opaque, stream, 12U);
	expect(error == EPERM, "firmware: the diagnostics refused to a user");
	core_superuser = 1;
	error = core_ops->command(core_private, opaque, stream, 12U);
	expect(error == 0, "firmware: the diagnostics from root's command");
	stream[1] = 4U;
	error = core_ops->command(core_private, opaque, stream, 12U);
	expect(error == EINVAL, "firmware: a diagnostics command with an unknown flag refused");

	/* A reset sends INIT again before the ring takes other work. */
	inits = model_inits;
	ghci_service_step(&device, GHCI_WORK_RECOVER);
	expect(model_inits == inits + 1U && !device.lost, "firmware: INIT after the reset");

	/* A reload from host memory: four IMEM words, two DMEM words, the load. */
	stream[0] = GPU_OP_GHCI_FIRMWARE;
	stream[1] = 0U;
	stream[2] = 0U;
	stream[3] = 0U;
	stream[4] = 4U;
	stream[5] = 0x00000013U;
	stream[6] = 0x11111111U;
	stream[7] = 0x22222222U;
	stream[8] = 0x33333333U;
	error = core_ops->command(core_private, opaque, stream, 9U * 4U);
	expect(error == 0, "firmware: IMEM staged");
	stream[1] = 1U;
	stream[2] = 1U;
	stream[4] = 2U;
	stream[5] = 0x44444444U;
	stream[6] = 0x55555555U;
	inits = model_inits;
	error = core_ops->command(core_private, opaque, stream, 7U * 4U);
	expect(error == 0, "firmware: the reload from host memory");
	expect(model_registers[GHCI_CPFW_IWORDS / 4U] == 4U && model_registers[GHCI_CPFW_DWORDS / 4U] == 2U, "firmware: the words loaded");
	expect(model_registers[GHCI_CPFW_IBASE / 4U] == device.fw_image->gpu_address, "firmware: IMEM loaded from the staged image");
	expect(model_registers[GHCI_CPFW_DBASE / 4U] == device.fw_image->gpu_address + 131072U, "firmware: DMEM after IMEM's room");
	expect((model_registers[GHCI_CPFW_CTRL / 4U] & GHCI_CPFW_CTRL_RUN) != 0U, "firmware: RUN after the load");
	expect(model_inits == inits + 1U && !device.lost, "firmware: INIT after the reload");

	/* A reload through local memory: the image copied there by the debug port. */
	stream[0] = GPU_OP_GHCI_FIRMWARE;
	stream[1] = 0U;
	stream[2] = 0U;
	stream[3] = 0U;
	stream[4] = 4U;
	stream[5] = 0x00000013U;
	stream[6] = 0x66666666U;
	stream[7] = 0x77777777U;
	stream[8] = 0x88888888U;
	error = core_ops->command(core_private, opaque, stream, 9U * 4U);
	stream[1] = 3U;
	stream[2] = 1U;
	stream[4] = 2U;
	stream[5] = 0x99999999U;
	stream[6] = 0xaaaaaaaaU;
	error = core_ops->command(core_private, opaque, stream, 7U * 4U);
	expect(error == 0, "firmware: the reload through local memory");
	expect(model_registers[GHCI_CPFW_IBASE / 4U] == device.fw_image_local->gpu_address, "firmware: IMEM loaded from local memory");
	memory = model_memory(device.fw_image_local->gpu_address + 12U, 4U);
	word = 0U;
	if (memory != NULL)
		memcpy(&word, memory, 4U);
	expect(word == 0x88888888U, "firmware: the debug port copied IMEM");
	memory = model_memory(device.fw_image_local->gpu_address + 131072U + 4U, 4U);
	word = 0U;
	if (memory != NULL)
		memcpy(&word, memory, 4U);
	expect(word == 0xaaaaaaaaU, "firmware: the debug port copied DMEM");

	/* A piece of a part that does not exist, or past its end, is refused; another session refuses a reload. */
	stream[1] = 0U;
	stream[2] = 2U;
	error = core_ops->command(core_private, opaque, stream, 7U * 4U);
	expect(error == EINVAL, "firmware: a third part refused");
	stream[2] = 1U;
	stream[3] = 16383U;
	error = core_ops->command(core_private, opaque, stream, 7U * 4U);
	expect(error == EINVAL, "firmware: DMEM past its end refused");
	core_ops->close(core_private, opaque);
	core_superuser = 0;
	error = ghci_device_stop(&device);
	expect(error == 0, "firmware: stop");
	model_device = NULL;

	/* A wrong token, and no answer at all, fail the start. */
	error = firmware_start(&device, MODEL_INIT_WRONG_TOKEN);
	expect(error == EIO, "firmware: a wrong token fails the start");
	model_device = NULL;
	error = firmware_start(&device, MODEL_INIT_SILENT);
	expect(error == EIO, "firmware: no answer fails the start");
	model_device = NULL;

	/* A firmware older than INIT starts the device without the diagnostics' firmware steps. */
	model_registers[GHCI_CPFW_VERSION / 4U] = 0x00020000U;
	error = firmware_start(&device, MODEL_INIT_OLD_FIRMWARE);
	expect(error == 0 && device.fw_features == 0U, "firmware: an older firmware starts without features");
	model_diags = 0U;
	error = ghci_firmware_diag(&device, 1U);
	expect(error == 0 && model_diags == 0U, "firmware: an older firmware's diagnostics skip its steps");
	error = ghci_device_stop(&device);
	expect(error == 0, "firmware: stop of the older firmware");
	model_init_mode = MODEL_INIT_RIGHT;
	model_device = NULL;
}

/*
 * The idle frame: a connected display with no lease is lit on the driver's
 * frame in 1280 x 720 at the first service round, once; a lease then
 * takes the display as from a lit one.
 */
static void
test_idle_frame(void)
{
	static struct ghci_device device;
	struct gpu_display_claim claim;
	uint8_t *memory;
	uint32_t word;
	int error;
	void *opaque;

	/* A display that is connected from the start. */
	model_setup_display();
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;
	error = ghci_device_start(&device);
	expect(error == 0 && device.display.idle_frame != NULL, "idle: start with an idle frame");
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U, "idle: dark before the service");

	/* The service lights it on the idle frame in 1280 x 720. */
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) != 0U, "idle: lit by the service");
	expect(model_dc[GHCI_DC_FB_BASE / 4U] == device.display.idle_frame->gpu_address, "idle: the idle frame scanned out");
	expect(model_dc[GHCI_DC_H_ACTIVE / 4U] == 1280U && model_dc[GHCI_DC_V_ACTIVE / 4U] == 720U, "idle: 1280 x 720");

	/* The picture in the idle frame, read back by the model firmware's sums. */
	model_registers[GHCI_CAPS / 4U] |= GHCI_CAPS_FIRMWARE;
	device.fw_features = GHCI_INIT_F_DIAG;
	error = ghci_firmware_paint(&device);
	expect(error == 0, "idle: the picture painted and read back");
	memory = model_memory(device.display.idle_frame->gpu_address + 5120U * 10U + 4U * 170U, 4U);
	word = 0U;
	if (memory != NULL)
		memcpy(&word, memory, 4U);
	expect(word == 0x00ffff00U, "idle: the second band is yellow");
	memory = model_memory(device.display.idle_frame->gpu_address + 5120U * 700U + 4U * 1279U, 4U);
	word = 0U;
	if (memory != NULL)
		memcpy(&word, memory, 4U);
	expect(word == 0x00ffffffU, "idle: the last grey step is white");
	model_registers[GHCI_CAPS / 4U] &= ~GHCI_CAPS_FIRMWARE;

	/* A lease is taken as from a lit display, and its release leaves it dark. */
	core_ops->open(core_private, &opaque);
	memset(&claim, 0, sizeof(claim));
	claim.display_id = 1U;
	claim.generation = 1U;
	error = core_ops->display->claim(core_private, opaque, &claim);
	expect(error == 0, "idle: a lease is taken");
	core_ops->close(core_private, opaque);
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U && !device.display.ending, "idle: dark after the lease, not lit again");
	error = ghci_device_stop(&device);
	expect(error == 0, "idle: stop");
	model_device = NULL;
}

/*
 * Starts a discrete GPU with firmware and a CPFW capability (after the
 * MEM capability) whose INIT answers as `mode` says.
 */
static int
firmware_start(
	struct ghci_device *device,
	int mode)
{
	uint32_t version;
	int error;

	/* The window with the MEM capability, then CPFW at its registers, READY. */
	version = model_registers[GHCI_CPFW_VERSION / 4U];
	model_setup_window(1);
	model_registers[GHCI_CAPS / 4U] |= GHCI_CAPS_FIRMWARE | (1U << 18);
	model_registers[MODEL_EXTCAP / 4U] |= 2U << 16;
	model_registers[MODEL_EXTCAP / 4U + 2U] = GHCI_XCAP_CPFW | (1U << 8);
	model_registers[MODEL_EXTCAP / 4U + 3U] = GHCI_CPFW_CTRL;
	model_registers[GHCI_CPFW_STATUS / 4U] = GHCI_CPFW_STATUS_READY;
	model_registers[GHCI_CPFW_VERSION / 4U] = version;
	model_init_mode = mode;
	model_inits = 0U;

	/* The device on it. */
	memset(device, 0, sizeof(*device));
	device->registers = (volatile uint8_t *)model_registers;
	device->register_bytes = sizeof(model_registers);
	device->window = model_window_guard;
	device->window_physical = MODEL_WINDOW_PHYSICAL;
	device->window_bytes = MODEL_WINDOW_BYTES;
	model_device = device;
	error = ghci_device_start(device);
	if (error != 0)
		return error;

	/* Succeeded: the device runs. */
	return 0;
}

/* Fills a present request of the lease's frame: the size, rows, format and flags, generation 1. */
static void
display_frame(
	struct gpu_display_present *present,
	uint64_t lease,
	uint32_t width,
	uint32_t height,
	uint32_t flags)
{
	memset(present, 0, sizeof(*present));
	present->lease = lease;
	present->width = width;
	present->height = height;
	present->stride = width * 4U;
	present->format = GPU_PIXEL_BGRA8888;
	present->refresh_millihz = 60000U;
	present->flags = flags;
	present->generation = 1U;
}

/* Makes a session's blob of local memory for a frame of 640 x 480. */
static struct ghci_allocation *
display_blob(
	void *opaque)
{
	struct gpu_blob_create request;
	uint32_t resource_id;
	void *object;
	int error;

	memset(&request, 0, sizeof(request));
	request.bytes = 640U * 480U * 4U;
	error = core_ops->blob_create(core_private, opaque, &request, &object, &resource_id);
	expect(error == 0, "display blob made");
	return object;
}

/*
 * Runs a discrete GPU with a display controller: the attach before the
 * processor runs, the copied and shared routes, the queue and its
 * mailbox, the scan holds, a new mode, the cursor, a reset that loses a
 * flip, the connection, the error mask, the lease's end and the stop.
 */
static void
test_display(void)
{
	static struct ghci_device device;
	const struct drv_gpu_display_ops *ops;
	struct gpu_display_info info;
	struct gpu_display_claim claim;
	struct gpu_display_release release;
	struct gpu_display_present present;
	struct gpu_display_wait wait;
	struct gpu_display_cursor_image cursor;
	struct gpu_display_cursor_move move;
	struct gpu_scanout_constraints constraints;
	struct gpu_resource_create storage_request;
	struct ghci_allocation *storage;
	struct ghci_allocation *large;
	struct ghci_allocation *small;
	struct ghci_allocation *blobs[4];
	struct ghci_allocation *alias;
	struct gpu_image_descriptor image;
	uint32_t resource_id;
	void *shared;
	uint64_t sequence;
	uint64_t replaced;
	uint64_t adopted;
	uint64_t lease;
	uint64_t topology;
	uint32_t word;
	unsigned flips;
	unsigned index;
	int error;
	void *object;
	void *opaque;
	void *other;

	/* The model and the device's bus fields. */
	model_setup_display();
	memset(&device, 0, sizeof(device));
	device.registers = (volatile uint8_t *)model_registers;
	device.register_bytes = sizeof(model_registers);
	device.window = model_window_guard;
	device.window_physical = MODEL_WINDOW_PHYSICAL;
	device.window_bytes = MODEL_WINDOW_BYTES;
	model_device = &device;

	/* The attach writes the controller before the processor runs; the display's operations are registered. */
	error = ghci_device_start(&device);
	expect(error == 0 && device.display.present, "display start");
	expect(device.display.mode_count == 2U, "display two modes from the controller's table");
	expect(device.display.modes[0].width == 640U && device.display.modes[0].refresh_millihz == 60000U, "display 640 x 480 at 60 Hz");
	expect(device.display.modes[1].width == 1280U && device.display.modes[1].refresh_millihz == 60000U, "display 1280 x 720 at 60 Hz");
	expect(device.display.modes[1].clock_select == 1U && device.display.modes[1].sync_polarity == 3U, "display mode flags read");
	expect(model_dc_bad_writes == 0U, "display attach writes before the processor runs");
	expect((model_irq_enable & (GHCI_IRQ_FLIP | GHCI_IRQ_DISP_ERROR | GHCI_IRQ_HOTPLUG)) == (GHCI_IRQ_FLIP | GHCI_IRQ_DISP_ERROR | GHCI_IRQ_HOTPLUG), "display interrupts enabled");
	expect((model_irq_enable & GHCI_IRQ_VBLANK) == 0U, "display vertical sync not taken");
	expect(core_ops->display == &ghci_display_cursor_ops && core_ops->scanout == &ghci_scanout_ops, "display operations with the cursor and the scan-out query");
	expect((core_ops->display->flags & DRV_GPU_DISPLAY_UNGATED) != 0U, "display presents are ungated");
	ops = core_ops->display;

	/* The output: connected, shared and copied frames, a cursor, the largest mode preferred. */
	core_ops->open(core_private, &opaque);
	core_ops->open(core_private, &other);
	memset(&info, 0, sizeof(info));
	error = ops->query(core_private, opaque, &info);
	expect(error == 0 && (info.flags & GPU_DISPLAY_CONNECTED) != 0U && (info.flags & GPU_DISPLAY_HAS_CURSOR) != 0U, "display query");
	expect(info.preferred_width == 1280U && info.generation == 1U, "display preferred mode and generation");
	memset(&constraints, 0, sizeof(constraints));
	constraints.display_id = 1U;
	constraints.generation = 1U;
	error = core_ops->scanout->constraints(core_private, opaque, &constraints);
	expect(error == 0 && constraints.flags == (GPU_SCANOUT_SHARED | GPU_SCANOUT_COPY), "display constraints: shared and copied");
	expect(constraints.stride_alignment == 64U && constraints.offset_alignment == 64U, "display constraints: the memory line");
	constraints.generation = 2U;
	error = core_ops->scanout->constraints(core_private, opaque, &constraints);
	expect(error == ESTALE, "display constraints of another generation");

	/* The lease, and another open refused while it is held. */
	memset(&claim, 0, sizeof(claim));
	claim.display_id = 1U;
	claim.generation = 1U;
	error = ops->claim(core_private, opaque, &claim);
	lease = claim.lease;
	expect(error == 0 && lease != 0U, "display claim");
	error = ops->claim(core_private, other, &claim);
	expect(error == EBUSY, "display second claim refused");

	/* A copied frame lights the controller: the run in the ring, the flip taken at once, the frame adopted. */
	memset(&storage_request, 0, sizeof(storage_request));
	storage_request.bytes = 640U * 480U * 4U;
	storage_request.usage = GPU_RESOURCE_USAGE_STORAGE;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	storage = object;
	expect(error == 0, "display storage");
	for (index = 0U; index < 640U * 480U; index++) {
		word = 0x00010203U + index;
		memcpy(&storage->view[index * 4U], &word, 4U);
	}
	display_frame(&present, lease, 640U, 480U, GPU_DISPLAY_PRESENT_FIFO);
	error = ops->present(core_private, opaque, storage, &present);
	sequence = present.sequence;
	expect(error == 0 && sequence == 1U, "display copied present recorded");
	error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && adopted == 1U, "display copied present adopted");
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) != 0U, "display lit by the ring");
	expect(model_dc[GHCI_DC_FB_BASE / 4U] == device.display.frames[0]->gpu_address, "display scans the first frame");
	expect(model_dc[GHCI_DC_H_ACTIVE / 4U] == 640U && model_dc[GHCI_DC_FB_STRIDE / 4U] == 2560U, "display timing and rows written by DISP_SET");
	expect(device.display.frames[0]->kind == GHCI_MEMORY_UNWINDOWED && device.display.frames[0]->view == NULL, "display frames in local memory");
	expect(memcmp(model_memory(device.display.frames[0]->gpu_address, 640U * 480U * 4U), storage->view, 640U * 480U * 4U) == 0, "display frame holds the copy");
	expect(model_dc_bad_writes == 0U && model_dc_slot_busy == 0U, "display no refused write, no busy slot");

	/* A second copied frame flips to the other frame at a vertical sync. */
	error = ops->present(core_private, opaque, storage, &present);
	sequence = present.sequence;
	expect(error == 0 && sequence == 2U, "display second copied present");
	error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == device.display.frames[1]->gpu_address, "display scans the second frame");
	memset(&wait, 0, sizeof(wait));
	wait.lease = lease;
	wait.sequence = 2U;
	error = ops->wait(core_private, opaque, &wait);
	expect(error == 0 && wait.completed_sequence == 2U && wait.generation == 1U, "display wait answers the adopted frame");
	wait.sequence = 9U;
	error = ops->wait(core_private, opaque, &wait);
	expect(error == EINVAL, "display wait for a frame not presented");

	/* A shared frame is scanned where it is and held while scanned. */
	for (index = 0U; index < 4U; index++)
		blobs[index] = display_blob(opaque);
	display_frame(&present, lease, 640U, 480U, GPU_DISPLAY_PRESENT_FIFO | GPU_DISPLAY_PRESENT_BLOB);
	error = ops->present(core_private, opaque, blobs[0], &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[0]->gpu_address, "display scans a shared frame");
	expect(blobs[0]->holds == 1U, "display holds the shared frame it scans");
	error = ops->present(core_private, opaque, blobs[1], &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[1]->gpu_address, "display scans the next shared frame");
	expect(blobs[0]->holds == 0U && blobs[1]->holds == 1U, "display lets the frame no longer scanned go");

	/* An import for the display: a frame of a mode imports; another size is refused, and imports for rendering. */
	memset(&image, 0, sizeof(image));
	image.width = 640U;
	image.height = 480U;
	image.stride = 2560U;
	image.format = GPU_PIXEL_BGRA8888;
	image.tiling = GPU_IMAGE_LINEAR;
	error = core_ops->share->export_resource(core_private, opaque, blobs[0], &image, &shared);
	expect(error == 0, "display export of a frame");
	error = core_ops->share->import_resource(core_private, opaque, shared, GPU_IMPORT_SCANOUT, &object, &resource_id);
	alias = object;
	expect(error == 0 && alias->backing == blobs[0], "display import of a frame the controller scans");
	error = ops->present(core_private, opaque, alias, &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[0]->gpu_address, "display scans an imported frame");
	expect(blobs[0]->holds == 3U, "display holds the imported frame's memory");
	core_ops->share->release(core_private, shared);
	core_ops->resource_destroy(core_private, opaque, alias);
	expect(blobs[0]->holds == 1U, "display's hold stays when the import goes");
	image.width = 100U;
	error = core_ops->share->export_resource(core_private, opaque, blobs[3], &image, &shared);
	expect(error == 0, "display export of an image of no mode");
	error = core_ops->share->import_resource(core_private, opaque, shared, GPU_IMPORT_SCANOUT, &object, &resource_id);
	expect(error == ENOTSUP, "display import refused for an image the controller cannot scan");
	error = core_ops->share->import_resource(core_private, opaque, shared, 0U, &object, &resource_id);
	expect(error == 0, "display same image imports for rendering");
	core_ops->resource_destroy(core_private, opaque, object);
	core_ops->share->release(core_private, shared);
	expect(blobs[3]->holds == 0U, "display rendering import let go");

	/* Frames the controller cannot scan, another lease, another generation. */
	present.stride = 640U * 4U + 4U;
	error = ops->present(core_private, opaque, blobs[2], &present);
	expect(error == EINVAL, "display shared rows off the memory line refused");
	present.stride = 640U * 4U;
	present.lease = lease + 1U;
	error = ops->present(core_private, opaque, blobs[2], &present);
	expect(error == EBUSY, "display present of another lease refused");
	present.lease = lease;
	present.generation = 7U;
	error = ops->present(core_private, opaque, blobs[2], &present);
	expect(error == ESTALE, "display present of another generation refused");
	present.generation = 1U;
	expect(blobs[2]->holds == 0U, "display refused presents hold nothing");

	/* The queue: one flip pending, one waiting, a mailbox present replacing the waiting one. */
	model_dc_hold = 1;
	error = ops->present(core_private, opaque, blobs[2], &present);
	expect(error == 0 && device.display.flips[0].placed && device.display.queue_count == 0U, "display queue: the flip is placed");
	error = ops->present(core_private, opaque, blobs[3], &present);
	replaced = present.sequence;
	expect(error == 0 && device.display.queue_count == 1U && blobs[3]->holds == 1U, "display queue: the next waits");
	present.flags = GPU_DISPLAY_PRESENT_BLOB;
	error = ops->present(core_private, opaque, blobs[0], &present);
	sequence = present.sequence;
	expect(error == 0 && device.display.queue_count == 1U && sequence == replaced + 1U, "display mailbox present replaces the waiting one");
	expect(blobs[3]->holds == 0U && blobs[0]->holds == 2U, "display replaced frame let go (the new one is held as shown and as waiting)");
	expect(model_dc_slot_busy == 0U, "display no flip placed on a busy slot");
	model_dc_hold = 0;
	error = ops->adoption_wait(core_private, opaque, lease, &replaced, &adopted);
	expect(error == 0 && adopted >= replaced, "display replaced present adopted with its replacement");
	error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[0]->gpu_address, "display mailbox frame shown");
	expect(blobs[1]->holds == 0U && blobs[2]->holds == 0U && blobs[0]->holds == 1U, "display holds only the frame shown");
	present.flags = GPU_DISPLAY_PRESENT_FIFO | GPU_DISPLAY_PRESENT_BLOB;

	/* A frame of the other mode lights the controller again on that mode. */
	storage_request.bytes = 1280U * 720U * 4U;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	large = object;
	expect(error == 0, "display large storage");
	display_frame(&present, lease, 1280U, 720U, GPU_DISPLAY_PRESENT_FIFO);
	error = ops->present(core_private, opaque, large, &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_H_ACTIVE / 4U] == 1280U && model_dc[GHCI_DC_FB_STRIDE / 4U] == 5120U, "display new mode lit");
	expect(model_dc[GHCI_DC_PCLK_SEL / 4U] == 1U && model_dc[GHCI_DC_SYNC_POL / 4U] == 3U, "display new mode's clock and syncs");
	expect(blobs[0]->holds == 0U && model_dc_bad_writes == 0U, "display new mode lets the old frame go");

	/* The cursor: RGBA rows put in BGRA order, the rest cleared, flipped and shown; a move by the host. */
	storage_request.bytes = 32U * 32U * 4U;
	error = core_ops->resource_create(core_private, opaque, &storage_request, &object);
	small = object;
	for (index = 0U; index < 32U * 32U; index++) {
		word = 0x11223344U;
		memcpy(&small->view[index * 4U], &word, 4U);
	}
	memset(&cursor, 0, sizeof(cursor));
	cursor.lease = lease;
	cursor.width = 32U;
	cursor.height = 32U;
	cursor.stride = 128U;
	cursor.format = GPU_PIXEL_RGBA8888;
	cursor.generation = 1U;
	error = ops->cursor_set(core_private, opaque, small, &cursor);
	expect(error == 0, "display cursor set");
	memcpy(&word, &device.display.surfaces[0]->view[0], 4U);
	expect(word == 0x11443322U, "display cursor red and blue swapped");
	memcpy(&word, &device.display.surfaces[0]->view[40U * 256U + 40U * 4U], 4U);
	expect(word == 0U, "display cursor cleared past the image");
	ghci_sleep_ms(1U);
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	expect(model_dc[GHCI_DC_CURSOR_BASE / 4U] == device.display.surfaces[0]->gpu_address && device.display.cursor_shown == 0, "display cursor surface taken");
	memset(&move, 0, sizeof(move));
	move.lease = lease;
	move.x = -5;
	move.y = 7;
	move.generation = 1U;
	error = ops->cursor_move(core_private, opaque, &move);
	expect(error == 0 && model_dc[GHCI_DC_CURSOR_POS / 4U] == 0x0007fffbU && model_dc[GHCI_DC_CURSOR_CTRL / 4U] == 1U, "display cursor moved by the host");
	model_dc_hold = 1;
	error = ops->cursor_set(core_private, opaque, small, &cursor);
	expect(error == 0 && device.display.flips[1].placed && device.display.flips[1].surface == 1, "display cursor's second surface flipped");
	error = ops->cursor_set(core_private, opaque, small, &cursor);
	expect(error == EBUSY, "display cursor busy while both surfaces are in use");
	model_dc_hold = 0;

	/* A reset loses a flip still in the ring: counted again, placed again, shown. */
	ghci_sleep_ms(1U);
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	model_paused = 1;
	display_frame(&present, lease, 640U, 480U, GPU_DISPLAY_PRESENT_FIFO | GPU_DISPLAY_PRESENT_BLOB);
	error = ops->present(core_private, opaque, blobs[1], &present);
	sequence = present.sequence;
	expect(error == 0 && device.display.flips[0].placed, "display flip in the ring before the reset");
	flips = model_dc_flips;
	ghci_service_step(&device, GHCI_WORK_RECOVER);
	expect(device.display.flips[0].placed && model_wptr != 0U && model_rptr == 0U, "display lost flip placed again in the new ring");
	expect(model_dc[GHCI_DC_CURSOR_CTRL / 4U] == 0U, "display cursor hidden by the reset");
	model_paused = 0;
	model_run();
	expect(model_dc_flips == flips + 1U, "display placed-again flip parsed once");
	error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[1]->gpu_address, "display lost flip shown after the reset");
	expect(model_dc_slot_busy == 0U && model_dc_bad_writes == 0U, "display reset: no busy slot, no refused write");

	/* Errors: too many in a second mask the error interrupt until the next second. */
	for (index = 0U; index < 32U; index++) {
		model_dc_sticky |= GHCI_DC_ST_UNDERFLOW;
		ghci_service_step(&device, GHCI_WORK_DISPLAY);
	}
	expect((model_irq_enable & GHCI_IRQ_DISP_ERROR) == 0U, "display error interrupt masked after a storm");
	fake_ticks += kern_ms_to_ticks(1000U) + 1U;
	ghci_service_step(&device, 0U);
	expect((model_irq_enable & GHCI_IRQ_DISP_ERROR) != 0U, "display error interrupt back the next second");

	/* A read error round after round turns the controller dark; the next present lights it. */
	for (index = 0U; index < 3U; index++) {
		model_dc_sticky |= GHCI_DC_ST_READ_ERROR;
		ghci_service_step(&device, GHCI_WORK_DISPLAY);
	}
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U && !device.display.enabled, "display dark after read errors");
	error = ops->present(core_private, opaque, blobs[2], &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && (model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) != 0U, "display lit again by the next present");

	/* The connection: lost (presents refused), back as a new generation. */
	topology = 0U;
	(void)ops->events(core_private, opaque, &topology);
	model_dc_write(GHCI_DC_CONNECTED, 0U);
	model_interrupt();
	ghci_service_step(&device, device.service_work);
	error = ops->present(core_private, opaque, blobs[3], &present);
	expect(error == ENXIO && !device.display.connected, "display present refused while disconnected");
	(void)ops->events(core_private, opaque, &sequence);
	expect(sequence == topology + 1U, "display topology moved at the disconnection");
	model_dc_write(GHCI_DC_CONNECTED, 1U);
	model_interrupt();
	ghci_service_step(&device, device.service_work);
	error = ops->present(core_private, opaque, blobs[3], &present);
	expect(error == ESTALE && device.display.generation == 2U, "display old generation refused after the reconnection");
	present.generation = 2U;
	error = ops->present(core_private, opaque, blobs[3], &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, opaque, lease, &sequence, &adopted);
	expect(error == 0 && model_dc[GHCI_DC_FB_BASE / 4U] == blobs[3]->gpu_address, "display present of the new generation shown");

	/* The release: dark, the frame let go, the lease free for another open. */
	memset(&release, 0, sizeof(release));
	release.lease = lease;
	error = ops->release(core_private, opaque, &release);
	expect(error == 0 && (model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U, "display release turns it dark");
	expect(blobs[3]->holds == 0U && !device.display.ending, "display release lets everything go");
	claim.generation = 2U;
	error = ops->claim(core_private, other, &claim);
	expect(error == 0, "display claimed by the other open");

	/* The other open lights it and closes: the service thread finishes the end; no claim before. */
	storage_request.bytes = 640U * 480U * 4U;
	error = core_ops->resource_create(core_private, other, &storage_request, &object);
	display_frame(&present, claim.lease, 640U, 480U, GPU_DISPLAY_PRESENT_FIFO);
	present.generation = 2U;
	error = ops->present(core_private, other, object, &present);
	sequence = present.sequence;
	if (error == 0)
		error = ops->adoption_wait(core_private, other, claim.lease, &sequence, &adopted);
	expect(error == 0 && device.display.enabled, "display lit by the other open");
	core_ops->close(core_private, other);
	error = ops->claim(core_private, opaque, &claim);
	expect(error == EBUSY && device.display.ending, "display claim waits for the closed lease's end");
	ghci_service_step(&device, GHCI_WORK_DISPLAY);
	expect(!device.display.ending && (model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U, "display closed lease ended by the service thread");
	error = ops->claim(core_private, opaque, &claim);
	expect(error == 0, "display claimed again");

	/* The stop: dark, every buffer back. */
	core_ops->close(core_private, opaque);
	error = ghci_device_stop(&device);
	expect(error == 0, "display stop");
	expect((model_dc[GHCI_DC_CTRL / 4U] & GHCI_DC_CTRL_ENABLE) == 0U, "display dark after the stop");
	expect(device.windowed.count == 0U && device.unwindowed.count == 0U, "display local memory all back");
	expect(model_guard_changed() == 0U, "display driver did not touch the local window");
	expect(model_dc_slot_busy == 0U && model_dc_bad_writes == 0U, "display: never a busy slot or a refused write");
	model_device = NULL;
}
#endif
