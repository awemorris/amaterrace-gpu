/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The IR reference interpreter of the GSI1 compiler's host test
 * (gsi1-reference.h).
 *
 * Every instruction runs for every lane still running before the next
 * one; a loop runs again while any lane's condition holds, each lane
 * leaving when its own is false.  Skippable blocks run for every lane, as
 * the IR allows.
 */

#include "plan/ws288/tests/gsi1-reference.h"

#include "drivers/gpu/compiler/spirv.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* The deepest loop nest the reference follows. */
#define REF_LOOP_DEPTH		16U

/* A pass over a loop that never ends is stopped after this many instructions. */
#define REF_STEP_LIMIT		10000000UL

static uint32_t *value_of(struct ref_run *run, uint32_t value, uint32_t lane);
static float as_float(uint32_t bits);
static uint32_t as_bits(float number);
static uint32_t truth(int condition);
static const char *execute(struct ref_run *run, const struct drv_gpu_shader_ir_inst *inst, const uint8_t *active);
static const char *execute_lane(struct ref_run *run, const struct drv_gpu_shader_ir_inst *inst, uint32_t lane, uint32_t *result);
static uint32_t storage_word(struct ref_run *run, uint32_t uniform, uint32_t offset);
static void storage_store(struct ref_run *run, uint32_t uniform, uint32_t offset, uint32_t word);
static uint32_t atomic_apply(uint32_t operation, uint32_t old, uint32_t data, uint32_t compare);
static uint32_t output_slot(const struct ref_run *run, const struct drv_gpu_shader_ir_inst *inst);
static uint32_t float_to_int(float number, int is_signed);
static const char *image_access(struct ref_run *run, const struct drv_gpu_shader_ir_inst *inst, uint32_t lane);

/* Runs the program for the run's lanes. */
const char *
ref_execute(
	struct ref_run *run)
{
	const struct drv_gpu_shader_ir *ir;
	const struct drv_gpu_shader_ir_inst *inst;
	uint8_t active[REF_LANES];
	uint8_t saved[REF_LOOP_DEPTH][REF_LANES];
	uint32_t start[REF_LOOP_DEPTH];
	uint32_t depth;
	uint32_t pc;
	uint32_t lane;
	unsigned long steps;
	const char *why;
	int any;

	/* The values of every lane. */
	ir = run->ir;
	run->values = calloc((size_t)(ir->value_count + 1U) * REF_LANES, sizeof(*run->values));
	if (run->values == NULL)
		return "out of memory";

	/* Every lane runs to start with. */
	memset(active, 0, sizeof(active));
	for (lane = 0U; lane < run->lanes; lane++)
		active[lane] = 1U;

	/* The instructions in order. */
	depth = 0U;
	steps = 0UL;
	why = NULL;
	for (pc = 0U; pc < ir->instruction_count && why == NULL; pc++) {
		inst = &ir->instructions[pc];
		steps++;
		if (steps > REF_STEP_LIMIT) {
			why = "the program does not end";
			break;
		}

		/* A loop's start saves the lanes running. */
		if (inst->op == DRV_GPU_IR_LOOP_BEGIN) {
			if (depth == REF_LOOP_DEPTH) {
				why = "loops nested too deep";
				break;
			}
			memcpy(saved[depth], active, sizeof(active));
			start[depth] = pc;
			depth++;
			continue;
		}

		/* A loop's end: the lanes whose condition is false leave; back while any is left. */
		if (inst->op == DRV_GPU_IR_LOOP_END) {
			if (depth == 0U) {
				why = "a loop's end without its start";
				break;
			}
			any = 0;
			for (lane = 0U; lane < run->lanes; lane++) {
				if (active[lane] == 0U)
					continue;
				if (*value_of(run, inst->src[0], lane) == 0U) {
					active[lane] = 0U;
				} else {
					any = 1;
				}
			}
			if (any != 0) {
				pc = start[depth - 1U];
				continue;
			}
			depth--;
			memcpy(active, saved[depth], sizeof(active));
			continue;
		}

		/* Anything else runs for each lane still running. */
		why = execute(run, inst, active);
	}

	/* Succeeded unless a lane could not run. */
	return why;
}

/* Converts a float to a 16-bit float's bits, rounded to nearest even. */
uint32_t
ref_half_bits(
	float number)
{
	_Float16 half;
	uint16_t bits;

	half = (_Float16)number;
	memcpy(&bits, &half, sizeof(bits));
	return bits;
}

/* Converts a 16-bit float's bits to a float. */
float
ref_half_value(
	uint32_t bits)
{
	_Float16 half;
	uint16_t low;

	low = (uint16_t)bits;
	memcpy(&half, &low, sizeof(half));
	return (float)half;
}

/* Names the place of a value of one lane. */
static uint32_t *
value_of(
	struct ref_run *run,
	uint32_t value,
	uint32_t lane)
{
	return &run->values[(size_t)value * REF_LANES + lane];
}

/* The float of a word's bits. */
static float
as_float(
	uint32_t bits)
{
	float number;

	memcpy(&number, &bits, sizeof(number));
	return number;
}

/* The bits of a float. */
static uint32_t
as_bits(
	float number)
{
	uint32_t bits;

	memcpy(&bits, &number, sizeof(bits));
	return bits;
}

/* The IR's Boolean of a condition. */
static uint32_t
truth(
	int condition)
{
	if (condition != 0)
		return UINT32_MAX;
	return 0U;
}

/*
 * Runs one instruction for each lane still running: the results go into
 * place only after every lane computed its own, so that a difference
 * across the quad reads the sources as they were.
 */
static const char *
execute(
	struct ref_run *run,
	const struct drv_gpu_shader_ir_inst *inst,
	const uint8_t *active)
{
	uint32_t result[REF_LANES][4];
	uint8_t defines[REF_LANES];
	uint32_t lane;
	uint32_t channel;
	uint32_t count;
	const char *why;

	/* How many values the instruction defines. */
	count = 1U;
	if (inst->op == DRV_GPU_IR_IMAGE_READ || inst->op == DRV_GPU_IR_TEXTURE)
		count = 4U;

	/* Each lane's result. */
	memset(defines, 0, sizeof(defines));
	for (lane = 0U; lane < run->lanes; lane++) {
		if (active[lane] == 0U)
			continue;
		why = execute_lane(run, inst, lane, result[lane]);
		if (why != NULL)
			return why;
		defines[lane] = 1U;
	}

	/* The operations without a result stop here. */
	switch (inst->op) {
	case DRV_GPU_IR_NOP:
	case DRV_GPU_IR_STORE_OUTPUT:
	case DRV_GPU_IR_STORE_STORAGE:
	case DRV_GPU_IR_STORE_SHARED:
	case DRV_GPU_IR_IMAGE_WRITE:
	case DRV_GPU_IR_IMAGE_READ:
	case DRV_GPU_IR_KILL:
	case DRV_GPU_IR_SKIP_BEGIN:
	case DRV_GPU_IR_SKIP_END:
	case DRV_GPU_IR_BARRIER:
	case DRV_GPU_IR_FENCE:
		return NULL;
	default:
		break;
	}

	/* Every result into place. */
	for (lane = 0U; lane < run->lanes; lane++) {
		if (defines[lane] == 0U)
			continue;
		for (channel = 0U; channel < count; channel++)
			*value_of(run, inst->dst + channel, lane) = result[lane][channel];
	}
	return NULL;
}

/* Runs one instruction for one lane. */
static const char *
execute_lane(
	struct ref_run *run,
	const struct drv_gpu_shader_ir_inst *inst,
	uint32_t lane,
	uint32_t *result)
{
	uint32_t a;
	uint32_t b;
	uint32_t c;
	uint32_t slot;
	uint32_t partner;
	uint32_t base;
	float fa;
	float fb;
	int predicated;

	/* The first three sources, read where they are values. */
	a = 0U;
	b = 0U;
	c = 0U;
	if (inst->src[0] < run->ir->value_count)
		a = *value_of(run, inst->src[0], lane);
	if (inst->src[1] < run->ir->value_count)
		b = *value_of(run, inst->src[1], lane);
	if (inst->src[2] < run->ir->value_count)
		c = *value_of(run, inst->src[2], lane);
	fa = as_float(a);
	fb = as_float(b);
	result[0] = 0U;

	/* The operation. */
	switch (inst->op) {
	case DRV_GPU_IR_NOP:
	case DRV_GPU_IR_SKIP_BEGIN:
	case DRV_GPU_IR_SKIP_END:
	case DRV_GPU_IR_BARRIER:
	case DRV_GPU_IR_FENCE:
		return NULL;
	case DRV_GPU_IR_CONST:
	case DRV_GPU_IR_ICONST:
	case DRV_GPU_IR_BOOL:
		result[0] = inst->immediate;
		return NULL;
	case DRV_GPU_IR_LOAD_INPUT:
		if (inst->location >= REF_INPUTS || inst->component > 3U)
			return "an input the reference does not have";
		result[0] = run->input[lane][inst->location][inst->component];
		return NULL;
	case DRV_GPU_IR_STORE_OUTPUT:
		slot = output_slot(run, inst);
		if (slot >= REF_SLOTS || inst->component > 3U)
			return "an output the reference does not have";
		run->output[lane][slot][inst->component] = a;
		run->written[lane][slot][inst->component] = 1U;
		return NULL;
	case DRV_GPU_IR_LOAD_PUSH:
		result[0] = 0U;
		if (run->push != NULL && inst->immediate + 4U <= run->push_size)
			memcpy(&result[0], run->push + inst->immediate, 4U);
		return NULL;
	case DRV_GPU_IR_LOAD_UBO:
		result[0] = storage_word(run, inst->location, inst->immediate);
		return NULL;
	case DRV_GPU_IR_LOAD_STORAGE:
		/* The system buffer holds the group counts. */
		if (run->ir->uniforms[inst->location].set == DRV_GPU_IR_SYSTEM_SET) {
			result[0] = 1U;
			if (a == 0U)
				result[0] = run->groups;
			return NULL;
		}
		predicated = 0;
		if (inst->component != 0U && b == 0U)
			predicated = 1;
		if (predicated != 0) {
			result[0] = *value_of(run, inst->dst, lane);
			return NULL;
		}
		result[0] = storage_word(run, inst->location, a);
		return NULL;
	case DRV_GPU_IR_STORE_STORAGE:
		if (inst->component != 0U && c == 0U)
			return NULL;
		if (run->helper[lane] != 0U || run->killed[lane] != 0U)
			return NULL;
		storage_store(run, inst->location, a, b);
		return NULL;
	case DRV_GPU_IR_STORAGE_SIZE:
		result[0] = run->size[inst->location];
		return NULL;
	case DRV_GPU_IR_ATOMIC:
		base = 2U;
		if (inst->immediate == DRV_GPU_IR_ATOMIC_CMPXCHG)
			base = 3U;
		if (inst->component == DRV_GPU_IR_ATOMIC_PREDICATED &&
		    *value_of(run, inst->src[base], lane) == 0U)
			return NULL;
		if (run->helper[lane] != 0U || run->killed[lane] != 0U)
			return NULL;
		if (inst->location < REF_UNIFORMS && run->image[inst->location].texels != NULL) {
			/* A texel of a 32-bit integer image: x, y, the layer. */
			struct ref_image *image = &run->image[inst->location];
			uint32_t x = a;
			uint32_t y = *value_of(run, inst->src[0] + 1U, lane);
			uint32_t layer = *value_of(run, inst->src[0] + 2U, lane);
			uint32_t *texel;

			if (x >= image->width || y >= image->height || layer >= image->layers)
				return NULL;
			texel = &image->texels[4U * ((layer * image->height + y) * image->width + x)];
			result[0] = texel[0];
			texel[0] = atomic_apply(inst->immediate, result[0], b, c);
			return NULL;
		}
		if (inst->location == DRV_GPU_IR_LOCATION_SHARED) {
			/* A word of the workgroup's shared memory. */
			result[0] = run->shared[(a / 4U) % 4096U];
			run->shared[(a / 4U) % 4096U] = atomic_apply(inst->immediate, result[0], b, c);
			return NULL;
		}
		result[0] = storage_word(run, inst->location, a);
		storage_store(run, inst->location, a, atomic_apply(inst->immediate, result[0], b, c));
		return NULL;
	case DRV_GPU_IR_LOAD_SHARED:
		if (inst->component != 0U && b == 0U) {
			result[0] = *value_of(run, inst->dst, lane);
			return NULL;
		}
		result[0] = run->shared[(a / 4U) % 4096U];
		return NULL;
	case DRV_GPU_IR_STORE_SHARED:
		if (inst->component != 0U && c == 0U)
			return NULL;
		run->shared[(a / 4U) % 4096U] = b;
		return NULL;
	case DRV_GPU_IR_LOAD_SYSTEM:
		if (inst->component == DRV_GPU_IR_SYSTEM_LOCAL_ID_X || inst->component == DRV_GPU_IR_SYSTEM_LOCAL_INDEX) {
			result[0] = lane;
		} else if (inst->component == DRV_GPU_IR_SYSTEM_GROUP_ID_X) {
			result[0] = run->group;
		} else {
			result[0] = 0U;
		}
		return NULL;
	case DRV_GPU_IR_FADD:
		result[0] = as_bits(fa + fb);
		return NULL;
	case DRV_GPU_IR_FSUB:
		result[0] = as_bits(fa - fb);
		return NULL;
	case DRV_GPU_IR_FMUL:
		result[0] = as_bits(fa * fb);
		return NULL;
	case DRV_GPU_IR_FNEG:
		result[0] = a ^ 0x80000000U;
		return NULL;
	case DRV_GPU_IR_FABS:
		result[0] = a & 0x7fffffffU;
		return NULL;
	case DRV_GPU_IR_RSQ:
		result[0] = as_bits(1.0f / sqrtf(fa));
		return NULL;
	case DRV_GPU_IR_RCP:
		result[0] = as_bits(1.0f / fa);
		return NULL;
	case DRV_GPU_IR_SQRT:
		result[0] = as_bits(sqrtf(fa));
		return NULL;
	case DRV_GPU_IR_EXP2:
		result[0] = as_bits(exp2f(fa));
		return NULL;
	case DRV_GPU_IR_LOG2:
		result[0] = as_bits(log2f(fa));
		return NULL;
	case DRV_GPU_IR_SIN:
		result[0] = as_bits(sinf(fa));
		return NULL;
	case DRV_GPU_IR_COS:
		result[0] = as_bits(cosf(fa));
		return NULL;
	case DRV_GPU_IR_FLOOR:
		result[0] = as_bits(floorf(fa));
		return NULL;
	case DRV_GPU_IR_FRACT:
		result[0] = as_bits(fa - floorf(fa));
		return NULL;
	case DRV_GPU_IR_FTRUNC:
		result[0] = as_bits(truncf(fa));
		return NULL;
	case DRV_GPU_IR_FROUND_EVEN:
		result[0] = as_bits(nearbyintf(fa));
		return NULL;
	case DRV_GPU_IR_FMIN:
		result[0] = as_bits(fminf(fa, fb));
		return NULL;
	case DRV_GPU_IR_FMAX:
		result[0] = as_bits(fmaxf(fa, fb));
		return NULL;
	case DRV_GPU_IR_FLT:
		result[0] = truth(fa < fb);
		return NULL;
	case DRV_GPU_IR_FGE:
		result[0] = truth(fa >= fb);
		return NULL;
	case DRV_GPU_IR_FEQ:
		result[0] = truth(fa == fb);
		return NULL;
	case DRV_GPU_IR_FNEU:
		result[0] = truth(!(fa == fb));
		return NULL;
	case DRV_GPU_IR_AND:
	case DRV_GPU_IR_IAND:
		result[0] = a & b;
		return NULL;
	case DRV_GPU_IR_OR:
	case DRV_GPU_IR_IOR:
		result[0] = a | b;
		return NULL;
	case DRV_GPU_IR_IXOR:
		result[0] = a ^ b;
		return NULL;
	case DRV_GPU_IR_NOT:
	case DRV_GPU_IR_INOT:
		result[0] = ~a;
		return NULL;
	case DRV_GPU_IR_SELECT:
		result[0] = (a & b) | (~a & c);
		return NULL;
	case DRV_GPU_IR_KILL:
		if (a != 0U)
			run->killed[lane] = 1U;
		return NULL;
	case DRV_GPU_IR_IADD:
		result[0] = a + b;
		return NULL;
	case DRV_GPU_IR_ISUB:
		result[0] = a - b;
		return NULL;
	case DRV_GPU_IR_IMUL:
		result[0] = a * b;
		return NULL;
	case DRV_GPU_IR_INEG:
		result[0] = 0U - a;
		return NULL;
	case DRV_GPU_IR_UDIV:
		result[0] = b == 0U ? UINT32_MAX : a / b;
		return NULL;
	case DRV_GPU_IR_UMOD:
		result[0] = b == 0U ? a : a % b;
		return NULL;
	case DRV_GPU_IR_IDIV:
		if (b == 0U) {
			result[0] = UINT32_MAX;
		} else if (a == 0x80000000U && b == UINT32_MAX) {
			result[0] = a;
		} else {
			result[0] = (uint32_t)((int32_t)a / (int32_t)b);
		}
		return NULL;
	case DRV_GPU_IR_IREM:
		if (b == 0U) {
			result[0] = a;
		} else if (a == 0x80000000U && b == UINT32_MAX) {
			result[0] = 0U;
		} else {
			result[0] = (uint32_t)((int32_t)a % (int32_t)b);
		}
		return NULL;
	case DRV_GPU_IR_SHL:
		result[0] = a << (b & 31U);
		return NULL;
	case DRV_GPU_IR_SHR:
		result[0] = a >> (b & 31U);
		return NULL;
	case DRV_GPU_IR_ASR:
		result[0] = (uint32_t)((int32_t)a >> (b & 31U));
		return NULL;
	case DRV_GPU_IR_I2F:
		result[0] = as_bits((float)(int32_t)a);
		return NULL;
	case DRV_GPU_IR_U2F:
		result[0] = as_bits((float)a);
		return NULL;
	case DRV_GPU_IR_F2I:
		result[0] = float_to_int(fa, 1);
		return NULL;
	case DRV_GPU_IR_F2U:
		result[0] = float_to_int(fa, 0);
		return NULL;
	case DRV_GPU_IR_ILT:
		result[0] = truth((int32_t)a < (int32_t)b);
		return NULL;
	case DRV_GPU_IR_IGE:
		result[0] = truth((int32_t)a >= (int32_t)b);
		return NULL;
	case DRV_GPU_IR_ULT:
		result[0] = truth(a < b);
		return NULL;
	case DRV_GPU_IR_UGE:
		result[0] = truth(a >= b);
		return NULL;
	case DRV_GPU_IR_IEQ:
		result[0] = truth(a == b);
		return NULL;
	case DRV_GPU_IR_INE:
		result[0] = truth(a != b);
		return NULL;
	case DRV_GPU_IR_MOVE:
		result[0] = a;
		return NULL;
	case DRV_GPU_IR_PACK_HALF:
		result[0] = ref_half_bits(fa) | (ref_half_bits(fb) << 16);
		return NULL;
	case DRV_GPU_IR_UNPACK_HALF:
		result[0] = as_bits(ref_half_value(a >> (16U * (inst->component & 1U))));
		return NULL;
	case DRV_GPU_IR_DDX:
	case DRV_GPU_IR_DDX_FINE:
	case DRV_GPU_IR_DDY:
	case DRV_GPU_IR_DDY_FINE:
		/* Right minus left, bottom minus top: of the quad's first row or column for the coarse ones. */
		partner = 1U;
		if (inst->op == DRV_GPU_IR_DDY || inst->op == DRV_GPU_IR_DDY_FINE)
			partner = 2U;
		base = lane;
		if (inst->op == DRV_GPU_IR_DDX || inst->op == DRV_GPU_IR_DDY)
			base = lane & ~3U;
		result[0] = as_bits(as_float(*value_of(run, inst->src[0], base | partner)) -
				    as_float(*value_of(run, inst->src[0], base & ~partner)));
		return NULL;
	case DRV_GPU_IR_IMAGE_READ:
	case DRV_GPU_IR_IMAGE_WRITE:
		return image_access(run, inst, lane);
	case DRV_GPU_IR_TEXTURE:
		/* Only a storage image's size query: width, height, layers, one level. */
		for (base = 0U; base < run->ir->uniform_count && base < REF_UNIFORMS; base++) {
			if (run->ir->uniforms[base].set != inst->location || run->ir->uniforms[base].binding != inst->immediate)
				continue;
			if (run->image[base].texels == NULL || (inst->component & DRV_GPU_IR_TEXTURE_MESSAGE_MASK) != DRV_GPU_IR_TEXTURE_RESINFO)
				break;
			result[0] = run->image[base].width;
			result[1] = run->image[base].height;
			result[2] = run->image[base].layers;
			result[3] = 1U;
			return NULL;
		}
		return "a texture instruction (the model has no texture unit)";
	default:
		return "an operation the reference does not run";
	}
}

/* Reads a word of a uniform's bytes: 0 past its end. */
static uint32_t
storage_word(
	struct ref_run *run,
	uint32_t uniform,
	uint32_t offset)
{
	uint32_t word;

	word = 0U;
	if (uniform < REF_UNIFORMS && (uint64_t)offset + 4U <= run->size[uniform])
		memcpy(&word, run->bytes[uniform] + (offset & ~3U), 4U);
	return word;
}

/* Writes a word of a uniform's bytes: nothing past its end. */
static void
storage_store(
	struct ref_run *run,
	uint32_t uniform,
	uint32_t offset,
	uint32_t word)
{
	if (uniform < REF_UNIFORMS && (uint64_t)offset + 4U <= run->size[uniform])
		memcpy(run->bytes[uniform] + (offset & ~3U), &word, 4U);
}

/* Applies an atomic operation of the IR. */
static uint32_t
atomic_apply(
	uint32_t operation,
	uint32_t old,
	uint32_t data,
	uint32_t compare)
{
	switch (operation) {
	case DRV_GPU_IR_ATOMIC_AND:
		return old & data;
	case DRV_GPU_IR_ATOMIC_OR:
		return old | data;
	case DRV_GPU_IR_ATOMIC_XOR:
		return old ^ data;
	case DRV_GPU_IR_ATOMIC_XCHG:
		return data;
	case DRV_GPU_IR_ATOMIC_ADD:
		return old + data;
	case DRV_GPU_IR_ATOMIC_SUB:
		return old - data;
	case DRV_GPU_IR_ATOMIC_SMAX:
		return (int32_t)old > (int32_t)data ? old : data;
	case DRV_GPU_IR_ATOMIC_SMIN:
		return (int32_t)old < (int32_t)data ? old : data;
	case DRV_GPU_IR_ATOMIC_UMAX:
		return old > data ? old : data;
	case DRV_GPU_IR_ATOMIC_UMIN:
		return old < data ? old : data;
	default:
		return old == compare ? data : old;
	}
}

/* The output slot of a write. */
static uint32_t
output_slot(
	const struct ref_run *run,
	const struct drv_gpu_shader_ir_inst *inst)
{
	(void)run;
	if (inst->location == DRV_GPU_IR_LOCATION_POSITION)
		return REF_SLOT_POSITION;
	if (inst->location == DRV_GPU_IR_LOCATION_POINT_SIZE)
		return REF_SLOT_POINT_SIZE;
	if (inst->location == DRV_GPU_IR_LOCATION_FRAG_DEPTH)
		return REF_SLOT_DEPTH;
	if (inst->location == DRV_GPU_IR_LOCATION_SAMPLE_MASK)
		return REF_SLOT_SAMPLE_MASK;
	if (inst->location < 16U)
		return inst->location;
	return REF_SLOTS;
}

/* Converts a float to an integer rounded toward zero, saturated (NaN as +infinity). */
static uint32_t
float_to_int(
	float number,
	int is_signed)
{
	if (is_signed != 0) {
		if (isnan(number) || number >= 2147483648.0f)
			return 0x7fffffffU;
		if (number <= -2147483648.0f)
			return 0x80000000U;
		return (uint32_t)(int32_t)truncf(number);
	}
	if (isnan(number) || number >= 4294967296.0f)
		return UINT32_MAX;
	if (number <= 0.0f)
		return 0U;
	return (uint32_t)truncf(number);
}

/*
 * Reads or writes a texel of a storage image, a texel buffer or an input
 * attachment (the texels are four words each, in the IR's terms); a texel
 * outside reads zero and is not written.
 */
static const char *
image_access(
	struct ref_run *run,
	const struct drv_gpu_shader_ir_inst *inst,
	uint32_t lane)
{
	const struct drv_gpu_shader_ir_uniform *uniform;
	struct ref_image *image;
	uint32_t *values;
	uint32_t x;
	uint32_t y;
	uint32_t layer;
	uint32_t index;
	uint32_t channel;
	uint32_t predicate;

	/* The image. */
	if (inst->location >= REF_UNIFORMS)
		return "an image the reference does not bind";
	uniform = &run->ir->uniforms[inst->location];
	image = &run->image[inst->location];
	if (image->texels == NULL)
		return "an image the reference does not bind";

	/* The coordinates: an input attachment's are the pixel's plus the offset, its sample the layer. */
	x = *value_of(run, inst->src[0], lane);
	y = *value_of(run, inst->src[0] + 1U, lane);
	layer = *value_of(run, inst->src[0] + 2U, lane);
	if (uniform->kind == DRV_GPU_IR_UNIFORM_INPUT_ATTACHMENT) {
		x += run->pixel_x[lane];
		y += run->pixel_y[lane];
		if (uniform->multisampled == 0U)
			layer = 0U;
	}

	/* The predicate. */
	predicate = 1U;
	if (inst->component != 0U) {
		if (inst->op == DRV_GPU_IR_IMAGE_READ) {
			predicate = *value_of(run, inst->src[2], lane);
		} else {
			predicate = *value_of(run, inst->src[3], lane);
		}
	}

	/* A read keeps the old values where the predicate is false; zero outside. */
	if (inst->op == DRV_GPU_IR_IMAGE_READ) {
		if (predicate == 0U)
			return NULL;
		for (channel = 0U; channel < 4U; channel++)
			*value_of(run, inst->dst + channel, lane) = 0U;
		if (x >= image->width || y >= image->height || layer >= image->layers)
			return NULL;
		index = (layer * image->height + y) * image->width + x;
		for (channel = 0U; channel < 4U; channel++)
			*value_of(run, inst->dst + channel, lane) = image->texels[4U * index + channel];
		return NULL;
	}

	/* A write inside, by a lane that writes. */
	if (predicate == 0U || run->helper[lane] != 0U || run->killed[lane] != 0U)
		return NULL;
	if (x >= image->width || y >= image->height || layer >= image->layers)
		return NULL;
	index = (layer * image->height + y) * image->width + x;
	values = &image->texels[4U * index];
	for (channel = 0U; channel < 4U; channel++)
		values[channel] = *value_of(run, inst->src[2] + channel, lane);
	return NULL;
}
