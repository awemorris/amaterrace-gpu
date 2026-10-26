/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The parts of the end-to-end test of the GHCI driver on the simulated
 * GPU, and what they give each other.
 *
 * The test is one host process on one thread: libvulkan as it is, its
 * device node, ioctls, mappings, polls and clock stood in by a fake GPU
 * core (ghci-e2e-core.c) that calls the GHCI driver's operations as the
 * kernel's core does; the driver with its Vulkan executor and compiler on
 * stubs of the kernel (ghci-e2e-kernel.c); and amaterrace-gpu's
 * Verilator model of the KC705 board behind the link (sim/verilator/
 * link.h), whose register window, local memory and interrupt line take
 * the place of the PCI function.  Time is the simulation's: every wait of
 * the driver, of the core and of libvulkan runs the GPU's clock.
 */

#ifndef GHCI_E2E_H
#define GHCI_E2E_H

#include <stdint.h>

struct drv_gpu_ops;

/*
 * What the fake core measured: the queued commands (each libvulkan
 * transaction) and the jobs (each vkQueueSubmit's fence), how many
 * completed, and the GPU cycles from their submission (a job's: its
 * commit) to their completion, summed and the longest.
 */
struct e2e_core_stats {
	uint64_t commands;
	uint64_t command_cycles;
	uint64_t command_cycles_max;
	uint64_t jobs;
	uint64_t job_cycles;
	uint64_t job_cycles_max;
};

/*
 * What the display shows, as the display case checks it: the display
 * controller's registers (read through the DISP2 window), plane 0's flip
 * record in the record page, and the driver's own view of the image it
 * shows (copy_frame -1: a session's blob scanned where it is, 0 or 1: one
 * of the driver's two frames a copied present filled).
 */
struct e2e_display_state {
	int present;
	uint32_t fb_base;
	uint32_t fb_stride;
	uint32_t ctrl;
	uint32_t status;
	uint32_t frame_count;
	uint32_t scan_sum;
	uint32_t scan_words;
	uint32_t record_value;
	uint32_t record_frame;
	uint32_t shown_base;
	uint32_t shown_stride;
	int shown_copy_frame;
	int enabled;
	uint64_t adopted;
};

/* Starts the simulated board and the driver on it: 0, or an error. */
int e2e_board_start(void);

/* Stops the driver and the simulation: 0, or EIO when the driver's memory was not where GHCI puts it. */
int e2e_board_stop(void);

/*
 * Runs the board for a while as the kernel would between two looks of a
 * waiting thread: the GPU's clock, its interrupt, and the service
 * thread's work when no thread holds the device.
 */
void e2e_board_pump(void);

/* The simulated time in nanoseconds since the board started. */
uint64_t e2e_board_now_ns(void);

/* Reads what the display shows. */
void e2e_display_state(struct e2e_display_state *state);

/*
 * Runs the board (as a waiting thread would) until the display controller
 * has begun frames more frames, at most timeout_ns of simulated time:
 * 0, or ETIMEDOUT.
 */
int e2e_display_frames(uint32_t frames, uint64_t timeout_ns);

/* Registers the fake core's /dev/gpu0 node for the driver's operations. */
void e2e_core_register(const struct drv_gpu_ops *ops, void *private_data);

/* Withdraws the node. */
void e2e_core_unregister(void);

/* Copies what the fake core measured. */
void e2e_core_stats(struct e2e_core_stats *stats);

#endif
