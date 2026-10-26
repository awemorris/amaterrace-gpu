/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * A reference interpreter of the shared scalar IR for the GSI1 compiler's
 * host test: it runs the lanes of one workgroup, or of one vertex or
 * fragment warp, in lockstep straight from the IR, as ir.h says, with the
 * host's floats.  It knows nothing of GSI1.
 */

#ifndef PLAN_WS288_TESTS_GSI1_REFERENCE_H
#define PLAN_WS288_TESTS_GSI1_REFERENCE_H

#include "drivers/gpu/compiler/ir.h"

#include <stdint.h>

/* The lanes the reference runs at once, and the uniforms it binds. */
#define REF_LANES		128U
#define REF_UNIFORMS		32U

/* The output slots: the user locations, then the position, the point size, the depth and the sample mask. */
#define REF_SLOT_POSITION	16U
#define REF_SLOT_POINT_SIZE	17U
#define REF_SLOT_DEPTH		18U
#define REF_SLOT_SAMPLE_MASK	19U
#define REF_SLOTS		20U

/* The input locations a lane is given: the user ones and the built-ins by their parser locations. */
#define REF_INPUTS		72U

/*
 * One image the reference reads and writes: its texels as words (each
 * texel `texel_words` words, already in the IR's terms: four floats or
 * integers), its size.
 */
struct ref_image {
	uint32_t *texels;
	uint32_t width;
	uint32_t height;
	uint32_t layers;
};

/*
 * What a run sees and leaves: each uniform's bytes (by its index in the
 * IR's list), the push constants, the shared memory, the lanes' inputs,
 * the outputs they wrote (with a mark per channel) and whether they were
 * discarded.
 */
struct ref_run {
	const struct drv_gpu_shader_ir *ir;
	uint32_t lanes;
	uint32_t group;
	uint32_t groups;
	uint8_t *bytes[REF_UNIFORMS];
	uint32_t size[REF_UNIFORMS];
	struct ref_image image[REF_UNIFORMS];
	const uint8_t *push;
	uint32_t push_size;
	uint32_t shared[4096];
	uint32_t input[REF_LANES][REF_INPUTS][4];
	uint8_t helper[REF_LANES];
	uint32_t output[REF_LANES][REF_SLOTS][4];
	uint8_t written[REF_LANES][REF_SLOTS][4];
	uint8_t killed[REF_LANES];
	uint32_t pixel_x[REF_LANES];
	uint32_t pixel_y[REF_LANES];
	uint32_t *values;
};

/* Runs the program for the run's lanes; NULL on success, else why it could not. */
const char *ref_execute(struct ref_run *run);

/* Converts a float to a 16-bit float's bits (round to nearest even), and back. */
uint32_t ref_half_bits(float value);
float ref_half_value(uint32_t bits);

#endif /* PLAN_WS288_TESTS_GSI1_REFERENCE_H */
