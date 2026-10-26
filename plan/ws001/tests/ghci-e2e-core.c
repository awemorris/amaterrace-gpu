/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The GPU core of the end-to-end test: the /dev/gpu0 node that libvulkan
 * opens, served by the GHCI driver's operations the way the kernel's core
 * (src/drivers/gpu/gpu.c, gpu-fence.c) serves them, reduced to what one
 * thread of one process needs: sessions, resources and their mappings,
 * queued commands and their completion records, job reservations bound to
 * fence payloads, fences, readiness for poll, and the display's query,
 * mode, claim, release, present (of ordinary storage and of a blob, with
 * the adoption wait of an ungated display) and wait.
 *
 * libvulkan's calls of the C library reach this file through the
 * linker's --wrap: open, close, ioctl, mmap, munmap, poll, fcntl,
 * opendir, readdir, closedir, clock_gettime and nanosleep.  A descriptor
 * of the node or of a fence is a number from FD_BASE; every other call
 * goes on to the C library.  The monotonic clock is the simulation's, and
 * every wait (a fence, a completion record, a poll, a sleep) runs the
 * board until its condition holds or its time is up.
 *
 * Deliberately simpler than the kernel's core: no credentials (every open
 * reads and writes), no supervision deadlines, no sharing between opens,
 * and a refusal for what the cases do not reach (the display's events,
 * cursor, power and overlays, export and import, placed blobs).
 */

#define _GNU_SOURCE 1

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>

#include <drivers/gpu/gpu.h>
#include <drivers/gpu/gpu-display.h>
#include <uapi/gpu.h>
#include <uapi/gpu-display.h>
#include <uapi/gpu-fence.h>
#include <uapi/gpu-job.h>

#include "ghci-e2e.h"
#include "link.h"

/* The first descriptor number of the fake node and its fences, and how many there are. */
#define FD_BASE				1000
#define FD_COUNT			256

/* The resources one open may hold. */
#define RESOURCE_COUNT			1024U

/* The node's path, and the name its directory lists. */
#define NODE_PATH			"/dev/gpu0"
#define NODE_NAME			"gpu0"

/* The monotonic clock's value at the board's start, so it never reads zero. */
#define CLOCK_BASE_NS			1000000000ULL

/* What a descriptor of this file names. */
enum fd_kind {
	FD_FREE,
	FD_NODE,
	FD_FENCE
};

/* The states of a job's reservation, as the kernel's core keeps them. */
enum job_state {
	JOB_NONE,
	JOB_RESERVED,
	JOB_COMMITTED
};

/*
 * A fence payload: one generation at a time, pending or terminal.
 *
 * It lives while a descriptor names it or a job is bound to it
 * (references); bound says a reserved or committed job will signal the
 * current generation, which keeps a reset from starting a new one.
 */
struct fence {
	unsigned references;
	uint64_t generation;
	unsigned state;
	int error;
	int bound;
};

struct node_open;

/*
 * One completion record of an open: a queued command's or a job's.
 *
 * The driver holds it from an accepted submit or reserve until it calls
 * drv_gpu_complete(); the open's caller consumes it with COMMAND_WAIT.  A
 * job's record carries the fence generation its completion signals.
 */
struct drv_gpu_completion {
	struct node_open *open;
	uint64_t sequence;
	int listed;
	int completed;
	int error;
	enum job_state job;
	void *reservation;
	struct fence *fence;
	uint64_t generation;
	uint64_t started;
};

/*
 * One resource of an open: the driver's object, whether it is a blob (or
 * ordinary storage), its bytes, its handle and its mapping token.
 */
struct resource {
	int used;
	void *object;
	int blob;
	uint64_t bytes;
	uint64_t handle;
	uint32_t resource_id;
	uint64_t map_offset;
	struct drv_gpu_mapping mapping;
};

/*
 * One open of the node: the driver's session and what the core keeps
 * for it.  It lives from open until close.
 */
struct node_open {
	void *backend;
	int error;
	struct drv_gpu_completion completions[GPU_SUBMIT_MAX];
	struct resource resources[RESOURCE_COUNT];
	uint64_t next_handle;
	uint64_t next_map_offset;
};

/* One descriptor of this file. */
struct descriptor {
	enum fd_kind kind;
	struct node_open *open;
	struct fence *fence;
};

/*
 * The driver's registration: its operations and private data, set by
 * drv_gpu_register() during the board's start and cleared by the
 * unregistration.
 */
static const struct drv_gpu_ops *core_ops;
static void *core_private;

/* The descriptors the fake node and its fences hold, by number - FD_BASE. */
static struct descriptor descriptors[FD_COUNT];

/*
 * The last sequence handed out: the kernel's sequences are global and
 * never reused, so they start at 1 and only grow.
 */
static uint64_t last_sequence;

/* What the core measured of the completions, since the start. */
static struct e2e_core_stats measured;

/* Whether readdir() of the fake /dev has listed the node yet (one directory stream at a time). */
static int directory_listed;

/* The fake directory stream of /dev: only its address is used. */
static char directory_stream;

/* The entry readdir() gives for the node. */
static struct dirent node_entry;

/* The C library's functions, for everything that is not the fake node's. */
int __real_open(const char *path, int flags, ...);
int __real_close(int fd);
int __real_ioctl(int fd, unsigned long request, ...);
void *__real_mmap(void *address, size_t length, int protection, int flags, int fd, off_t offset);
int __real_munmap(void *address, size_t length);
int __real_poll(struct pollfd *fds, nfds_t count, int timeout);
int __real_fcntl(int fd, int command, ...);
DIR *__real_opendir(const char *name);
struct dirent *__real_readdir(DIR *directory);
int __real_closedir(DIR *directory);
int __real_clock_gettime(clockid_t clock, struct timespec *time);

int __wrap_open(const char *path, int flags, ...);
int __wrap_close(int fd);
int __wrap_ioctl(int fd, unsigned long request, ...);
void *__wrap_mmap(void *address, size_t length, int protection, int flags, int fd, off_t offset);
int __wrap_munmap(void *address, size_t length);
int __wrap_poll(struct pollfd *fds, nfds_t count, int timeout);
int __wrap_fcntl(int fd, int command, ...);
DIR *__wrap_opendir(const char *name);
struct dirent *__wrap_readdir(DIR *directory);
int __wrap_closedir(DIR *directory);
int __wrap_clock_gettime(clockid_t clock, struct timespec *time);
int __wrap_nanosleep(const struct timespec *request, struct timespec *remaining);

static struct descriptor *descriptor_of(int fd);
static int descriptor_take(enum fd_kind kind, int *fd);
static struct fence *fence_make(unsigned signaled);
static void fence_put(struct fence *fence);
static void fence_end(struct fence *fence, uint64_t generation, int error);
static int node_open(int *fd);
static void node_close(struct node_open *open);
static int node_ioctl(struct node_open *open, unsigned long request, void *argument);
static struct resource *resource_find(struct node_open *open, uint64_t handle);
static int resource_add(struct node_open *open, void *object, int blob, uint64_t bytes, uint32_t resource_id, uint64_t *handle);
static int ioctl_blob_create(struct node_open *open, struct gpu_blob_create *request);
static int ioctl_resource_create(struct node_open *open, struct gpu_resource_create *request);
static int ioctl_resource_destroy(struct node_open *open, struct gpu_resource_destroy *request);
static int ioctl_resource_map(struct node_open *open, struct gpu_resource_map *request);
static int ioctl_transfer(struct node_open *open, unsigned long request, struct gpu_transfer *transfer);
static int ioctl_submit(struct node_open *open, struct gpu_command_submit *request);
static int ioctl_wait(struct node_open *open, struct gpu_command_wait *request);
static int ioctl_job_reserve(struct node_open *open, struct gpu_job_reserve *request);
static int ioctl_job_action(struct node_open *open, unsigned long command, struct gpu_job_action *request);
static int ioctl_job_capacity(struct node_open *open, struct gpu_job_capacity *request);
static int ioctl_fence_create(struct gpu_fence_create *request);
static int ioctl_fence_state(unsigned long command, struct gpu_fence_state *request);
static int ioctl_fence_bind(struct node_open *open, struct gpu_fence_bind *request);
static int ioctl_display(struct node_open *open, unsigned long request, void *argument);
static int ioctl_display_present(struct node_open *open, struct gpu_display_present *request);
static int completion_take(struct node_open *open, struct drv_gpu_completion **result);
static struct drv_gpu_completion *completion_find(struct node_open *open, uint64_t sequence);
static void completion_free(struct drv_gpu_completion *completion);
static uint64_t deadline_of(uint64_t timeout_ns);
static uint64_t cycles_now(void);
static short readiness(int fd, short events);

/*
 * Registers the node for the driver's operations.
 */
void
e2e_core_register(
	const struct drv_gpu_ops *ops,
	void *private_data)
{
	core_ops = ops;
	core_private = private_data;
}

/*
 * Withdraws the node.
 */
void
e2e_core_unregister(void)
{
	core_ops = NULL;
	core_private = NULL;
}

/*
 * Copies what the fake core measured.
 */
void
e2e_core_stats(
	struct e2e_core_stats *stats)
{
	*stats = measured;
}

/*
 * Registers a backend with the core, as the driver's start does.
 */
int
drv_gpu_register(
	const struct drv_gpu_ops *ops,
	void *private_data,
	struct drv_gpu_device **result)
{
	/* The node now serves the backend; its handle is only a token to the driver. */
	e2e_core_register(ops, private_data);
	*result = (struct drv_gpu_device *)(void *)&core_ops;
	return 0;
}

/*
 * Withdraws the backend, as the driver's stop does.
 */
int
drv_gpu_unregister(
	struct drv_gpu_device *device)
{
	(void)device;

	/* Gone: later opens fail. */
	e2e_core_unregister();
	return 0;
}

/*
 * Finishes one accepted request, from the driver's service thread.
 */
void
drv_gpu_complete(
	struct drv_gpu_completion *completion,
	int error)
{
	uint64_t cycles;

	/* The record is terminal; its open's poll and wait see it. */
	completion->completed = 1;
	completion->error = error;

	/* The round trip from the submission (a job's commit) to here. */
	cycles = cycles_now() - completion->started;
	if (completion->job == JOB_NONE) {
		measured.commands++;
		measured.command_cycles += cycles;
		if (cycles > measured.command_cycles_max)
			measured.command_cycles_max = cycles;
	} else {
		measured.jobs++;
		measured.job_cycles += cycles;
		if (cycles > measured.job_cycles_max)
			measured.job_cycles_max = cycles;
	}

	/* A job's fence payload ends with the job: signaled, or an error. */
	if (completion->fence != NULL) {
		fence_end(completion->fence, completion->generation, error);
		fence_put(completion->fence);
		completion->fence = NULL;
	}
}

/*
 * Records a session's failure: its open's later calls fail.
 */
void
drv_gpu_report_session_error(
	struct drv_gpu_device *device,
	void *session,
	int error)
{
	int index;

	(void)device;

	/* The open whose backend session failed. */
	printf("  e2e: the driver reports a session error (%d)\n", error);
	for (index = 0; index < FD_COUNT; index++) {
		if (descriptors[index].kind == FD_NODE && descriptors[index].open->backend == session)
			descriptors[index].open->error = error;
	}
}

/*
 * Notes that the backend has room again: the capacity waits look again.
 */
void
drv_gpu_capacity_changed(
	struct drv_gpu_device *device)
{
	(void)device;
}

/* Opens the node, or a file of the C library. */
int
__wrap_open(
	const char *path,
	int flags,
	...)
{
	va_list arguments;
	unsigned mode;
	int differs;
	int error;
	int fd;

	/* The node: a new session of the driver. */
	differs = strcmp(path, NODE_PATH);
	if (differs == 0) {
		error = node_open(&fd);
		if (error != 0) {
			errno = error;
			return -1;
		}

		/* Succeeded: the node's descriptor. */
		return fd;
	}

	/* Any other path, with the mode an O_CREAT carries. */
	mode = 0U;
	if ((flags & O_CREAT) != 0) {
		va_start(arguments, flags);
		mode = va_arg(arguments, unsigned);
		va_end(arguments);
	}
	fd = __real_open(path, flags, mode);
	return fd;
}

/* Closes a descriptor of the node or a fence, or a file of the C library. */
int
__wrap_close(
	int fd)
{
	struct descriptor *entry;
	int closed;

	/* A file of the C library. */
	entry = descriptor_of(fd);
	if (entry == NULL) {
		closed = __real_close(fd);
		return closed;
	}

	/* The node's open ends; a fence descriptor drops its reference. */
	if (entry->kind == FD_NODE)
		node_close(entry->open);
	if (entry->kind == FD_FENCE)
		fence_put(entry->fence);
	memset(entry, 0, sizeof(*entry));

	/* Succeeded: the descriptor is free. */
	return 0;
}

/* Serves an ioctl of the node or a fence, or passes it to the C library. */
int
__wrap_ioctl(
	int fd,
	unsigned long request,
	...)
{
	struct descriptor *entry;
	va_list arguments;
	void *argument;
	int error;

	/* The argument is a pointer for every request this file serves. */
	va_start(arguments, request);
	argument = va_arg(arguments, void *);
	va_end(arguments);

	/* A file of the C library. */
	entry = descriptor_of(fd);
	if (entry == NULL) {
		error = __real_ioctl(fd, request, argument);
		return error;
	}

	/* A fence descriptor takes no ioctl of its own: the node's fence ioctls name it. */
	if (entry->kind != FD_NODE) {
		errno = ENOTTY;
		return -1;
	}

	/* The node's request. */
	error = node_ioctl(entry->open, request, argument);
	if (error != 0) {
		errno = error;
		return -1;
	}

	/* Succeeded: the request's outputs are in its argument. */
	return 0;
}

/* Maps a resource of the node by its token, or passes the call to the C library. */
void *
__wrap_mmap(
	void *address,
	size_t length,
	int protection,
	int flags,
	int fd,
	off_t offset)
{
	struct descriptor *entry;
	struct resource *resource;
	unsigned index;
	void *mapped;

	/* A file of the C library, or anonymous memory. */
	entry = descriptor_of(fd);
	if (entry == NULL) {
		mapped = __real_mmap(address, length, protection, flags, fd, offset);
		return mapped;
	}

	/* The node's resource whose token this is: the driver's view of it (the local window). */
	if (entry->kind == FD_NODE) {
		for (index = 0U; index < RESOURCE_COUNT; index++) {
			resource = &entry->open->resources[index];
			if (!resource->used || resource->map_offset == 0U)
				continue;
			if (resource->map_offset == (uint64_t)offset && length <= resource->mapping.bytes)
				return resource->mapping.address;
		}
	}

	/* No such token. */
	errno = EINVAL;
	return MAP_FAILED;
}

/* Unmaps a view of the node (nothing to do: the window stays), or memory of the C library. */
int
__wrap_munmap(
	void *address,
	size_t length)
{
	struct node_open *open;
	unsigned index;
	unsigned slot;
	int error;

	/* A view of a resource of any open of the node. */
	for (slot = 0U; slot < FD_COUNT; slot++) {
		if (descriptors[slot].kind != FD_NODE)
			continue;

		/* The open's mapped resources. */
		open = descriptors[slot].open;
		for (index = 0U; index < RESOURCE_COUNT; index++) {
			if (open->resources[index].used && open->resources[index].mapping.address == address)
				return 0;
		}
	}

	/* Memory of the C library. */
	error = __real_munmap(address, length);
	return error;
}

/* Waits for readiness of the node's and fences' descriptors (and any others), in simulated time. */
int
__wrap_poll(
	struct pollfd *fds,
	nfds_t count,
	int timeout)
{
	struct descriptor *entry;
	uint64_t deadline;
	uint64_t now;
	nfds_t index;
	int fake;
	int ready;
	int other;

	/* Only files of the C library: its own poll. */
	fake = 0;
	for (index = 0U; index < count; index++) {
		entry = descriptor_of(fds[index].fd);
		if (entry != NULL)
			fake = 1;
	}
	if (!fake) {
		ready = __real_poll(fds, count, timeout);
		return ready;
	}

	/* The deadline in simulated time; a negative timeout waits for ever. */
	deadline = UINT64_MAX;
	if (timeout >= 0)
		deadline = e2e_board_now_ns() + (uint64_t)timeout * 1000000ULL;

	/* Looks at every descriptor, running the board between looks, until one is ready or the time is up. */
	for (;;) {
		ready = 0;
		for (index = 0U; index < count; index++) {
			fds[index].revents = 0;
			entry = descriptor_of(fds[index].fd);
			if (entry != NULL) {
				fds[index].revents = readiness(fds[index].fd, fds[index].events);
			} else if (fds[index].fd >= 0) {
				other = __real_poll(&fds[index], 1U, 0);
				if (other < 0)
					return other;
			}
			if (fds[index].revents != 0)
				ready++;
		}

		/* Something is ready, or the time is up. */
		now = e2e_board_now_ns();
		if (ready != 0 || now >= deadline)
			return ready;

		/* The board runs on. */
		e2e_board_pump();
	}
}

/* Duplicates a fence descriptor, or passes the call to the C library. */
int
__wrap_fcntl(
	int fd,
	int command,
	...)
{
	struct descriptor *entry;
	struct descriptor *copy;
	va_list arguments;
	long argument;
	int error;
	int duplicate;

	/* Every command libvulkan uses takes one integer argument or none. */
	va_start(arguments, command);
	argument = va_arg(arguments, long);
	va_end(arguments);

	/* A file of the C library. */
	entry = descriptor_of(fd);
	if (entry == NULL) {
		duplicate = __real_fcntl(fd, command, argument);
		return duplicate;
	}

	/* Only a fence descriptor is duplicated (F_DUPFD_CLOEXEC): the copy names the same payload. */
	if (entry->kind != FD_FENCE || (command != F_DUPFD_CLOEXEC && command != F_DUPFD)) {
		errno = EINVAL;
		return -1;
	}
	error = descriptor_take(FD_FENCE, &duplicate);
	if (error != 0) {
		errno = error;
		return -1;
	}
	copy = descriptor_of(duplicate);
	copy->fence = entry->fence;
	copy->fence->references++;

	/* Succeeded: the new descriptor. */
	return duplicate;
}

/* Opens /dev as a directory that lists the node, or another directory of the C library. */
DIR *
__wrap_opendir(
	const char *name)
{
	DIR *directory;
	int differs;

	/* The fake /dev. */
	differs = strcmp(name, "/dev");
	if (differs == 0) {
		directory_listed = 0;
		return (DIR *)(void *)&directory_stream;
	}

	/* Any other directory. */
	directory = __real_opendir(name);
	return directory;
}

/* Lists the node once in the fake /dev, or reads another directory. */
struct dirent *
__wrap_readdir(
	DIR *directory)
{
	struct dirent *entry;

	/* Another directory. */
	if (directory != (DIR *)(void *)&directory_stream) {
		entry = __real_readdir(directory);
		return entry;
	}

	/* The end of the listing. */
	if (directory_listed) {
		errno = 0;
		return NULL;
	}

	/* The node's entry. */
	directory_listed = 1;
	memset(&node_entry, 0, sizeof(node_entry));
	strcpy(node_entry.d_name, NODE_NAME);
	return &node_entry;
}

/* Closes the fake /dev, or another directory. */
int
__wrap_closedir(
	DIR *directory)
{
	int error;

	/* The fake /dev has nothing to release. */
	if (directory == (DIR *)(void *)&directory_stream)
		return 0;

	/* Another directory. */
	error = __real_closedir(directory);
	return error;
}

/* Reads the monotonic clock as the simulation's time; other clocks are the host's. */
int
__wrap_clock_gettime(
	clockid_t clock,
	struct timespec *time)
{
	uint64_t now;
	int error;

	/* The host's clocks other than the monotonic one. */
	if (clock != CLOCK_MONOTONIC) {
		error = __real_clock_gettime(clock, time);
		return error;
	}

	/* The simulation's nanoseconds, from a nonzero base. */
	now = CLOCK_BASE_NS + e2e_board_now_ns();
	time->tv_sec = (time_t)(now / 1000000000ULL);
	time->tv_nsec = (long)(now % 1000000000ULL);
	return 0;
}

/* Sleeps in simulated time: the board runs for the time asked. */
int
__wrap_nanosleep(
	const struct timespec *request,
	struct timespec *remaining)
{
	uint64_t deadline;
	uint64_t now;

	/* The end of the sleep. */
	deadline = e2e_board_now_ns() + (uint64_t)request->tv_sec * 1000000000ULL + (uint64_t)request->tv_nsec;

	/* The board runs until then. */
	do {
		e2e_board_pump();
		now = e2e_board_now_ns();
	} while (now < deadline);

	/* Slept the whole time. */
	if (remaining != NULL)
		memset(remaining, 0, sizeof(*remaining));
	return 0;
}

/* Reports the fake descriptor of a number, or NULL for a file of the C library. */
static struct descriptor *
descriptor_of(
	int fd)
{
	/* Outside the fake numbers. */
	if (fd < FD_BASE || fd >= FD_BASE + FD_COUNT)
		return NULL;

	/* A free number is not a descriptor. */
	if (descriptors[fd - FD_BASE].kind == FD_FREE)
		return NULL;

	/* Succeeded: the descriptor. */
	return &descriptors[fd - FD_BASE];
}

/* Takes the lowest free fake descriptor for a kind: 0 or EMFILE. */
static int
descriptor_take(
	enum fd_kind kind,
	int *fd)
{
	int index;

	/* The lowest free number. */
	for (index = 0; index < FD_COUNT; index++) {
		if (descriptors[index].kind == FD_FREE) {
			memset(&descriptors[index], 0, sizeof(descriptors[index]));
			descriptors[index].kind = kind;
			*fd = FD_BASE + index;
			return 0;
		}
	}

	/* All are taken. */
	return EMFILE;
}

/* Makes a fence payload of generation 1, signaled or pending, with one reference. */
static struct fence *
fence_make(
	unsigned signaled)
{
	struct fence *fence;

	/* The payload. */
	fence = calloc(1U, sizeof(*fence));
	if (fence == NULL)
		return NULL;

	/* Generation 1, in the state asked. */
	fence->references = 1U;
	fence->generation = 1U;
	fence->state = GPU_FENCE_PENDING;
	if (signaled)
		fence->state = GPU_FENCE_SIGNALED;

	/* Succeeded: the payload. */
	return fence;
}

/* Drops one reference of a fence payload; the last frees it. */
static void
fence_put(
	struct fence *fence)
{
	/* One reference fewer; zero means nothing names the payload. */
	fence->references--;
	if (fence->references == 0U)
		free(fence);
}

/* Ends the producer of a fence's generation: signaled without an error, ERROR with one. */
static void
fence_end(
	struct fence *fence,
	uint64_t generation,
	int error)
{
	/* A later generation is not this producer's. */
	if (generation != fence->generation)
		return;

	/* The terminal state, and the producer is gone. */
	fence->bound = 0;
	fence->state = GPU_FENCE_SIGNALED;
	fence->error = 0;
	if (error != 0) {
		fence->state = GPU_FENCE_ERROR;
		fence->error = error;
	}
}

/* Opens the node: a session of the driver behind a new descriptor. */
static int
node_open(
	int *fd)
{
	struct node_open *open;
	struct descriptor *entry;
	int error;

	/* The node exists only while the driver is registered. */
	if (core_ops == NULL)
		return ENODEV;

	/* The open's record. */
	open = calloc(1U, sizeof(*open));
	if (open == NULL)
		return ENOMEM;
	open->next_handle = 1U;
	open->next_map_offset = 4096U;

	/* The driver's session. */
	error = core_ops->open(core_private, &open->backend);
	if (error != 0) {
		free(open);
		return error;
	}

	/* The descriptor. */
	error = descriptor_take(FD_NODE, fd);
	if (error != 0) {
		core_ops->close(core_private, open->backend);
		free(open);
		return error;
	}
	entry = descriptor_of(*fd);
	entry->open = open;

	/* Succeeded: the open's descriptor. */
	return 0;
}

/* Closes an open as the core's release does: the queued work drains, the resources go, the session closes. */
static void
node_close(
	struct node_open *open)
{
	unsigned index;

	/* Every accepted callback ends before the session goes. */
	if (core_ops->commands != NULL)
		core_ops->commands->drain(core_private, open->backend);

	/* The resources the open still holds. */
	for (index = 0U; index < RESOURCE_COUNT; index++) {
		if (open->resources[index].used)
			core_ops->resource_destroy(core_private, open->backend, open->resources[index].object);
	}

	/* The session, then the records' fence references. */
	core_ops->close(core_private, open->backend);
	for (index = 0U; index < GPU_SUBMIT_MAX; index++) {
		if (open->completions[index].fence != NULL)
			fence_put(open->completions[index].fence);
	}
	free(open);
}

/* Serves one ioctl of an open of the node. */
static int
node_ioctl(
	struct node_open *open,
	unsigned long request,
	void *argument)
{
	struct gpu_capset *capset;
	struct gpu_info *info;
	int error;

	/* A failed session takes nothing more but its waits. */
	if (open->error != 0 && request != GPU_COMMAND_WAIT)
		return EIO;

	/* Each request the offscreen use of libvulkan makes. */
	switch (request) {
	case GPU_GET_INFO:
		info = argument;
		memset(info, 0, sizeof(*info));
		error = core_ops->get_info(core_private, open->backend, info);
		info->version = GPU_ABI_VERSION;
		info->size = sizeof(*info);
		info->capabilities = core_ops->capabilities;
		return error;

	case GPU_GET_CAPSET:
		capset = argument;
		error = core_ops->get_capset(core_private, open->backend, capset);
		return error;

	case GPU_BLOB_CREATE:
		error = ioctl_blob_create(open, argument);
		return error;

	case GPU_RESOURCE_CREATE:
		error = ioctl_resource_create(open, argument);
		return error;

	case GPU_RESOURCE_DESTROY:
		error = ioctl_resource_destroy(open, argument);
		return error;

	case GPU_RESOURCE_MAP:
		error = ioctl_resource_map(open, argument);
		return error;

	case GPU_RESOURCE_READ:
	case GPU_RESOURCE_WRITE:
		error = ioctl_transfer(open, request, argument);
		return error;

	case GPU_COMMAND_SUBMIT:
		error = ioctl_submit(open, argument);
		return error;

	case GPU_COMMAND_WAIT:
		error = ioctl_wait(open, argument);
		return error;

	case GPU_JOB_RESERVE:
		error = ioctl_job_reserve(open, argument);
		return error;

	case GPU_JOB_COMMIT:
	case GPU_JOB_CANCEL:
		error = ioctl_job_action(open, request, argument);
		return error;

	case GPU_JOB_CAPACITY:
		error = ioctl_job_capacity(open, argument);
		return error;

	case GPU_FENCE_CREATE:
		error = ioctl_fence_create(argument);
		return error;

	case GPU_FENCE_QUERY:
	case GPU_FENCE_WAIT:
	case GPU_FENCE_RESET:
	case GPU_FENCE_SIGNAL:
		error = ioctl_fence_state(request, argument);
		return error;

	case GPU_FENCE_BIND:
		error = ioctl_fence_bind(open, argument);
		return error;

	case GPU_DISPLAY_QUERY:
	case GPU_DISPLAY_MODE:
	case GPU_DISPLAY_CLAIM:
	case GPU_DISPLAY_RELEASE:
	case GPU_DISPLAY_PRESENT:
	case GPU_DISPLAY_WAIT:
		error = ioctl_display(open, request, argument);
		return error;

	default:
		break;
	}

	/* A request this node does not offer (the display's others, export and import, placed blobs). */
	return ENOTTY;
}

/* Reports an open's resource by its handle, or NULL. */
static struct resource *
resource_find(
	struct node_open *open,
	uint64_t handle)
{
	unsigned index;

	/* The used slot with the handle. */
	for (index = 0U; index < RESOURCE_COUNT; index++) {
		if (open->resources[index].used && open->resources[index].handle == handle)
			return &open->resources[index];
	}

	/* No such resource. */
	return NULL;
}

/* Records a resource the driver made, under a new handle: 0 or ENOMEM. */
static int
resource_add(
	struct node_open *open,
	void *object,
	int blob,
	uint64_t bytes,
	uint32_t resource_id,
	uint64_t *handle)
{
	unsigned index;

	/* A free slot. */
	for (index = 0U; index < RESOURCE_COUNT; index++) {
		if (!open->resources[index].used)
			break;
	}
	if (index == RESOURCE_COUNT)
		return ENOMEM;

	/* The slot names the object. */
	memset(&open->resources[index], 0, sizeof(open->resources[index]));
	open->resources[index].used = 1;
	open->resources[index].object = object;
	open->resources[index].blob = blob;
	open->resources[index].bytes = bytes;
	open->resources[index].resource_id = resource_id;
	open->resources[index].handle = open->next_handle;
	open->next_handle++;
	*handle = open->resources[index].handle;

	/* Succeeded: the handle names it. */
	return 0;
}

/* Creates a blob: the driver's allocation, mapped or a Vulkan memory's view. */
static int
ioctl_blob_create(
	struct node_open *open,
	struct gpu_blob_create *request)
{
	void *object;
	uint32_t resource_id;
	int error;

	/* The driver's blob. */
	error = core_ops->blob_create(core_private, open->backend, request, &object, &resource_id);
	if (error != 0)
		return error;

	/* Its handle. */
	error = resource_add(open, object, 1, request->bytes, resource_id, &request->handle);
	if (error != 0) {
		core_ops->resource_destroy(core_private, open->backend, object);
		return error;
	}
	request->resource_id = resource_id;

	/* Succeeded: the blob's handle and identity. */
	return 0;
}

/* Creates a storage resource. */
static int
ioctl_resource_create(
	struct node_open *open,
	struct gpu_resource_create *request)
{
	void *object;
	int error;

	/* The driver's storage. */
	error = core_ops->resource_create(core_private, open->backend, request, &object);
	if (error != 0)
		return error;

	/* Its handle. */
	error = resource_add(open, object, 0, request->bytes, 0U, &request->handle);
	if (error != 0) {
		core_ops->resource_destroy(core_private, open->backend, object);
		return error;
	}

	/* Succeeded: the resource's handle. */
	return 0;
}

/* Destroys a resource. */
static int
ioctl_resource_destroy(
	struct node_open *open,
	struct gpu_resource_destroy *request)
{
	struct resource *resource;

	/* The open's resource. */
	resource = resource_find(open, request->handle);
	if (resource == NULL)
		return ENOENT;

	/* The driver gives it back; the handle is gone. */
	core_ops->resource_destroy(core_private, open->backend, resource->object);
	memset(resource, 0, sizeof(*resource));

	/* Succeeded: the resource is gone. */
	return 0;
}

/* Gives a resource's mapping token, which mmap() takes. */
static int
ioctl_resource_map(
	struct node_open *open,
	struct gpu_resource_map *request)
{
	struct resource *resource;
	int error;

	/* The open's resource. */
	resource = resource_find(open, request->handle);
	if (resource == NULL)
		return ENOENT;

	/* The driver's view, once: its token never changes. */
	if (resource->map_offset == 0U) {
		error = core_ops->resource_map(core_private, open->backend, resource->object, &resource->mapping);
		if (error != 0)
			return error;
		resource->map_offset = open->next_map_offset;
		open->next_map_offset += (resource->mapping.bytes + 4095U) & ~(uint64_t)4095U;
	}

	/* The token and the view's bytes. */
	request->offset = resource->map_offset;
	request->bytes = resource->mapping.bytes;

	/* Succeeded: mmap() at the token gives the view. */
	return 0;
}

/* Copies between a resource and the caller's memory. */
static int
ioctl_transfer(
	struct node_open *open,
	unsigned long request,
	struct gpu_transfer *transfer)
{
	struct resource *resource;
	int error;

	/* The open's resource. */
	resource = resource_find(open, transfer->handle);
	if (resource == NULL)
		return ENOENT;

	/* The driver's copy in the direction asked. */
	if (request == GPU_RESOURCE_READ) {
		error = core_ops->resource_read(core_private, open->backend, resource->object, transfer->offset,
		    (void *)(uintptr_t)transfer->address, transfer->bytes);
	} else {
		error = core_ops->resource_write(core_private, open->backend, resource->object, transfer->offset,
		    (const void *)(uintptr_t)transfer->address, transfer->bytes);
	}
	return error;
}

/* Queues a command stream with a completion record. */
static int
ioctl_submit(
	struct node_open *open,
	struct gpu_command_submit *request)
{
	struct drv_gpu_completion *completion;
	int error;

	/* A record for the command's completion, from now. */
	error = completion_take(open, &completion);
	if (error != 0)
		return error;
	completion->started = cycles_now();

	/* The driver takes the stream (it copies what it keeps). */
	error = core_ops->commands->submit(core_private, open->backend, (const void *)(uintptr_t)request->address,
	    request->bytes, request->flags, request->timeline, completion);
	if (error != 0) {
		completion_free(completion);
		return error;
	}
	request->sequence = completion->sequence;

	/* Succeeded: the record's sequence. */
	return 0;
}

/* Waits for a completion record, and consumes it when asked. */
static int
ioctl_wait(
	struct node_open *open,
	struct gpu_command_wait *request)
{
	struct drv_gpu_completion *completion;
	uint64_t deadline;
	uint64_t now;

	/* The open's record. */
	completion = completion_find(open, request->sequence);
	if (completion == NULL)
		return ENOENT;

	/* The board runs until the record is terminal or the time is up. */
	deadline = deadline_of(request->timeout_ns);
	for (;;) {
		if (completion->completed)
			break;
		now = e2e_board_now_ns();
		if (now >= deadline)
			return ETIMEDOUT;
		e2e_board_pump();
	}

	/* The transport status, and the record goes when consumed. */
	request->status = (uint32_t)completion->error;
	if ((request->flags & GPU_WAIT_CONSUME) != 0U)
		completion_free(completion);

	/* Succeeded: the record's status. */
	return 0;
}

/* Reserves a job on a timeline, bound to a fence generation when one is given. */
static int
ioctl_job_reserve(
	struct node_open *open,
	struct gpu_job_reserve *request)
{
	struct drv_gpu_completion *completion;
	struct descriptor *entry;
	int error;

	/* The payload's descriptor, when there is one. */
	entry = NULL;
	if (request->fd != -1) {
		entry = descriptor_of(request->fd);
		if (entry == NULL || entry->kind != FD_FENCE)
			return EBADF;
		if (entry->fence->generation != request->generation)
			return ESTALE;
		if (entry->fence->bound)
			return EBUSY;
	}

	/* The job's record. */
	error = completion_take(open, &completion);
	if (error != 0)
		return error;

	/* The driver's reservation. */
	error = core_ops->jobs->reserve(core_private, open->backend, request->timeline, completion, &completion->reservation);
	if (error != 0) {
		completion_free(completion);
		return error;
	}

	/* The job is reserved and owns the payload's generation. */
	completion->job = JOB_RESERVED;
	if (entry != NULL) {
		completion->fence = entry->fence;
		completion->generation = request->generation;
		entry->fence->references++;
		entry->fence->bound = 1;
	}
	request->sequence = completion->sequence;

	/* Succeeded: the job's sequence. */
	return 0;
}

/* Commits a reserved job, or cancels it. */
static int
ioctl_job_action(
	struct node_open *open,
	unsigned long command,
	struct gpu_job_action *request)
{
	struct drv_gpu_completion *completion;
	unsigned fault;
	int error;

	/* The open's job. */
	completion = completion_find(open, request->sequence);
	if (completion == NULL || completion->job == JOB_NONE)
		return ENOENT;
	if (completion->job != JOB_RESERVED)
		return EALREADY;

	/* A commit publishes the job on its timeline. */
	if (command == GPU_JOB_COMMIT) {
		completion->started = cycles_now();
		error = core_ops->jobs->commit(core_private, open->backend, completion->reservation, completion);
		if (error != 0)
			return error;
		completion->job = JOB_COMMITTED;
		return 0;
	}

	/* A cancel withdraws it; an ordinary one frees its record and its payload. */
	fault = request->flags & GPU_JOB_CANCEL_FAULT;
	error = core_ops->jobs->cancel(core_private, open->backend, completion->reservation, completion, fault);
	if (error != 0)
		return error;
	if (!fault) {
		if (completion->fence != NULL) {
			completion->fence->bound = 0;
			fence_put(completion->fence);
			completion->fence = NULL;
		}
		completion_free(completion);
	}

	/* Succeeded: the job is withdrawn. */
	return 0;
}

/* Reports whether a job could be reserved now, waiting for room when asked. */
static int
ioctl_job_capacity(
	struct node_open *open,
	struct gpu_job_capacity *request)
{
	struct drv_gpu_completion *completion;
	uint64_t deadline;
	uint64_t now;
	unsigned available;
	int error;

	/* Looks, running the board between looks when a wait is asked, until room comes or the time is up. */
	deadline = deadline_of(request->timeout_ns);
	for (;;) {
		error = core_ops->jobs->capacity(core_private, open->backend, request->domain, &available);
		if (error != 0)
			return error;

		/* Room for a record too: one consumed or free slot. */
		error = completion_take(open, &completion);
		if (error == 0)
			completion_free(completion);
		if (error != 0)
			available = 0U;

		/* A snapshot, room, or the time up ends the wait. */
		now = e2e_board_now_ns();
		if ((request->flags & GPU_JOB_CAPACITY_QUERY) != 0U || available != 0U || now >= deadline)
			break;
		e2e_board_pump();
	}

	/* The answer: one observation sequence (the core's; one here), and the room. */
	request->sequence = 1U;
	request->available = available;

	/* Succeeded: the snapshot. */
	return 0;
}

/* Creates a fence payload of generation 1 behind a new descriptor. */
static int
ioctl_fence_create(
	struct gpu_fence_create *request)
{
	struct descriptor *entry;
	int error;
	int fd;

	/* The descriptor. */
	error = descriptor_take(FD_FENCE, &fd);
	if (error != 0)
		return error;
	entry = descriptor_of(fd);

	/* The payload, signaled or pending as asked. */
	entry->fence = fence_make(request->signaled);
	if (entry->fence == NULL) {
		memset(entry, 0, sizeof(*entry));
		return ENOMEM;
	}
	request->fd = fd;
	request->generation = 1U;

	/* Succeeded: the descriptor names the payload. */
	return 0;
}

/* Queries, waits for, resets or signals a fence generation. */
static int
ioctl_fence_state(
	unsigned long command,
	struct gpu_fence_state *request)
{
	struct descriptor *entry;
	struct fence *fence;
	uint64_t deadline;
	uint64_t now;

	/* The payload. */
	entry = descriptor_of(request->fd);
	if (entry == NULL || entry->kind != FD_FENCE)
		return EBADF;
	fence = entry->fence;

	/* Every operation but a query names the current generation. */
	if (request->generation != fence->generation) {
		if (command != GPU_FENCE_QUERY || request->generation != 0U)
			return ESTALE;
	}

	/* A reset starts a new pending generation, unless a job owns this one. */
	if (command == GPU_FENCE_RESET) {
		if (fence->bound)
			return EBUSY;
		fence->generation++;
		fence->state = GPU_FENCE_PENDING;
		fence->error = 0;
	}

	/* A signal ends the generation from the host. */
	if (command == GPU_FENCE_SIGNAL)
		fence_end(fence, request->generation, request->error);

	/* A wait runs the board until the generation is terminal or the time is up. */
	if (command == GPU_FENCE_WAIT) {
		deadline = deadline_of(request->timeout_ns);
		for (;;) {
			if (fence->state != GPU_FENCE_PENDING)
				break;
			now = e2e_board_now_ns();
			if (now >= deadline)
				return ETIMEDOUT;
			e2e_board_pump();
		}
	}

	/* The observation. */
	request->generation = fence->generation;
	request->state = fence->state;
	request->error = fence->error;

	/* Succeeded: the generation's state. */
	return 0;
}

/* Binds a fence generation to accepted work, or releases a reservation of it. */
static int
ioctl_fence_bind(
	struct node_open *open,
	struct gpu_fence_bind *request)
{
	struct drv_gpu_completion *completion;
	struct descriptor *entry;

	/* The payload, at its current generation. */
	entry = descriptor_of(request->fd);
	if (entry == NULL || entry->kind != FD_FENCE)
		return EBADF;
	if (entry->fence->generation != request->generation)
		return ESTALE;

	/* A release ends the host's own reservation. */
	if ((request->flags & GPU_FENCE_BIND_RELEASE) != 0U) {
		entry->fence->bound = 0;
		return 0;
	}

	/* The work whose completion signals the generation. */
	completion = completion_find(open, request->sequence);
	if (completion == NULL)
		return ENOENT;
	if (completion->fence != NULL)
		return EBUSY;

	/* A completed record ends the generation at once. */
	if (completion->completed) {
		fence_end(entry->fence, request->generation, completion->error);
		return 0;
	}

	/* The record signals the generation when it completes. */
	completion->fence = entry->fence;
	completion->generation = request->generation;
	entry->fence->references++;
	entry->fence->bound = 1;

	/* Succeeded: the generation waits for the work. */
	return 0;
}

/*
 * Serves a display request as the kernel's core does: the header, the
 * inputs the core checks itself, then the driver's operation.  The cases
 * use the one output's query, mode, claim, present, wait and release.
 */
static int
ioctl_display(
	struct node_open *open,
	unsigned long request,
	void *argument)
{
	const struct drv_gpu_display_ops *ops;
	struct gpu_display_info *query;
	struct gpu_display_mode *mode;
	struct gpu_display_claim *claim;
	struct gpu_display_release *release;
	struct gpu_display_wait *wait;
	uint32_t index;
	int error;

	/* A driver without a display offers none of these. */
	ops = core_ops->display;
	if (ops == NULL)
		return ENOTTY;

	switch (request) {
	case GPU_DISPLAY_QUERY:
		/* Only the ordinal is an input; the snapshot is the driver's. */
		query = argument;
		if (query->version != GPU_ABI_VERSION ||
		    query->size != sizeof(*query))
			return EINVAL;
		index = query->index;
		memset(query, 0, sizeof(*query));
		query->version = GPU_ABI_VERSION;
		query->size = sizeof(*query);
		query->index = index;
		error = ops->query(core_private, open->backend, query);
		if (error != 0)
			return error;
		if (index == GPU_DISPLAY_COUNT_ONLY)
			return 0;

		/* An output the driver names has an identity and a generation. */
		if (query->display_id == 0U)
			return EIO;
		if (query->generation == 0U)
			return EIO;
		return 0;

	case GPU_DISPLAY_MODE:
		/* Enumeration or validation of a display of a generation. */
		mode = argument;
		if (mode->version != GPU_ABI_VERSION ||
		    mode->size != sizeof(*mode))
			return EINVAL;
		if (mode->display_id == 0U ||
		    mode->generation == 0U ||
		    mode->count != 0U ||
		    mode->flags != 0U)
			return EINVAL;
		error = ops->mode(core_private, open->backend, mode);
		return error;

	case GPU_DISPLAY_CLAIM:
		/* A new lease, never zero. */
		claim = argument;
		if (claim->version != GPU_ABI_VERSION ||
		    claim->size != sizeof(*claim))
			return EINVAL;
		if (claim->display_id == 0U ||
		    claim->generation == 0U ||
		    claim->lease != 0U)
			return EINVAL;
		error = ops->claim(core_private, open->backend, claim);
		if (error != 0)
			return error;
		if (claim->lease == 0U)
			return EIO;
		return 0;

	case GPU_DISPLAY_RELEASE:
		/* The driver checks that the lease is this open's. */
		release = argument;
		if (release->version != GPU_ABI_VERSION ||
		    release->size != sizeof(*release) ||
		    release->lease == 0U)
			return EINVAL;
		error = ops->release(core_private, open->backend, release);
		return error;

	case GPU_DISPLAY_PRESENT:
		error = ioctl_display_present(open, argument);
		return error;

	case GPU_DISPLAY_WAIT:
		/* The outputs are zero on input. */
		wait = argument;
		if (wait->version != GPU_ABI_VERSION ||
		    wait->size != sizeof(*wait))
			return EINVAL;
		if (wait->lease == 0U ||
		    wait->completed_sequence != 0U ||
		    wait->present_time_ns != 0U ||
		    wait->generation != 0U)
			return EINVAL;
		error = ops->wait(core_private, open->backend, wait);
		return error;

	default:
		break;
	}

	/* Not a display request. */
	return ENOTTY;
}

/*
 * Serves a present: the frame's storage (a blob for a BLOB present,
 * ordinary storage otherwise) holds the whole image; the driver records
 * it, and for an ungated display the core then waits for its adoption.
 */
static int
ioctl_display_present(
	struct node_open *open,
	struct gpu_display_present *request)
{
	const struct drv_gpu_display_ops *ops;
	struct resource *resource;
	uint64_t image_bytes;
	int blob;
	int error;

	/* The header and the inputs: a lease of a generation, FIFO with or without BLOB, no sequence yet. */
	ops = core_ops->display;
	if (request->version != GPU_ABI_VERSION ||
	    request->size != sizeof(*request))
		return EINVAL;
	if (request->lease == 0U ||
	    request->generation == 0U ||
	    request->sequence != 0U)
		return EINVAL;
	if (request->flags != GPU_DISPLAY_PRESENT_FIFO &&
	    request->flags != (GPU_DISPLAY_PRESENT_FIFO | GPU_DISPLAY_PRESENT_BLOB))
		return EINVAL;

	/* Packed rows of one of the two formats. */
	if (request->width == 0U ||
	    request->width > UINT32_MAX / 4U ||
	    request->height == 0U ||
	    request->refresh_millihz == 0U)
		return EINVAL;
	if (request->format != GPU_PIXEL_BGRA8888 &&
	    request->format != GPU_PIXEL_RGBA8888)
		return EINVAL;
	if (request->stride < request->width * 4U ||
	    (request->stride & 3U) != 0U)
		return EINVAL;

	/* The open's storage of the kind the present names, holding the whole image. */
	resource = resource_find(open, request->handle);
	if (resource == NULL)
		return ENOENT;
	blob = 0;
	if ((request->flags & GPU_DISPLAY_PRESENT_BLOB) != 0U)
		blob = 1;
	if (resource->blob != blob)
		return EINVAL;
	if (request->offset > resource->bytes)
		return EINVAL;
	image_bytes = (uint64_t)request->stride * request->height;
	if (image_bytes > resource->bytes - request->offset)
		return EINVAL;

	/* The driver records the frame (an ungated one without waiting for it). */
	error = ops->present(core_private, open->backend, resource->object, request);
	if (error != 0)
		return error;

	/* An ungated present waits for its adoption, holding nothing. */
	if ((ops->flags & DRV_GPU_DISPLAY_UNGATED) != 0U) {
		error = ops->adoption_wait(core_private, open->backend, request->lease, &request->sequence, NULL);
		if (error != 0)
			return error;
	}

	/* A present names a frame of the lease's sequence. */
	if (request->sequence == 0U)
		return EIO;

	/* Succeeded: the frame is shown, or replaced by one that is. */
	return 0;
}

/* Takes a free completion record of an open under a new sequence: 0 or EAGAIN. */
static int
completion_take(
	struct node_open *open,
	struct drv_gpu_completion **result)
{
	unsigned index;

	/* A slot that no operation or observer holds. */
	for (index = 0U; index < GPU_SUBMIT_MAX; index++) {
		if (!open->completions[index].listed)
			break;
	}
	if (index == GPU_SUBMIT_MAX)
		return EAGAIN;

	/* The record, listed and pending. */
	memset(&open->completions[index], 0, sizeof(open->completions[index]));
	last_sequence++;
	open->completions[index].open = open;
	open->completions[index].sequence = last_sequence;
	open->completions[index].listed = 1;
	*result = &open->completions[index];

	/* Succeeded: the record. */
	return 0;
}

/* Reports an open's listed record of a sequence, or NULL. */
static struct drv_gpu_completion *
completion_find(
	struct node_open *open,
	uint64_t sequence)
{
	unsigned index;

	/* The listed record with the sequence. */
	for (index = 0U; index < GPU_SUBMIT_MAX; index++) {
		if (open->completions[index].listed && open->completions[index].sequence == sequence)
			return &open->completions[index];
	}

	/* No such record. */
	return NULL;
}

/* Frees a record: its slot is free for a new sequence. */
static void
completion_free(
	struct drv_gpu_completion *completion)
{
	memset(completion, 0, sizeof(*completion));
}

/* Reports the simulated time a wait of timeout_ns ends at (UINT64_MAX: never). */
static uint64_t
deadline_of(
	uint64_t timeout_ns)
{
	uint64_t now;

	/* A timeout past the clock's range waits for ever. */
	now = e2e_board_now_ns();
	if (timeout_ns > UINT64_MAX - now)
		return UINT64_MAX;

	/* The end of the wait. */
	return now + timeout_ns;
}

/* Reports the readiness of a fake descriptor for poll. */
static short
readiness(
	int fd,
	short events)
{
	struct descriptor *entry;
	unsigned index;
	short revents;

	/* A fence: readable once terminal, an error once failed. */
	entry = descriptor_of(fd);
	revents = 0;
	if (entry->kind == FD_FENCE) {
		if (entry->fence->state != GPU_FENCE_PENDING)
			revents |= events & (POLLIN | POLLRDNORM);
		if (entry->fence->state == GPU_FENCE_ERROR)
			revents |= POLLERR;
		return revents;
	}

	/* The node: an error once the session failed, readable while a terminal record waits to be consumed. */
	if (entry->open->error != 0)
		revents |= POLLERR;
	for (index = 0U; index < GPU_SUBMIT_MAX; index++) {
		if (entry->open->completions[index].listed && entry->open->completions[index].completed) {
			revents |= events & (POLLIN | POLLRDNORM);
			break;
		}
	}

	/* Succeeded: the readiness. */
	return revents;
}

/* Reports the GPU cycles run so far. */
static uint64_t
cycles_now(void)
{
	struct atg_link_stats stats;

	/* The link's count. */
	atg_link_stats(&stats);
	return stats.cycles;
}
