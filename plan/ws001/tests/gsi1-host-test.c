/*
 * zedBSD
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The GSI1 compiler's host test harness.  It compiles SPIR-V modules with
 * the GHCI backend, plays the command processor's part with the program's
 * interface table (it fills the constant bank and the attribute and
 * fragment registers as the table says), runs the IR on the reference
 * interpreter, and writes the files tools/gsi1model.py of amaterrace-gpu
 * takes and the results it must leave.  gsi1-host-test.py runs the model
 * and compares.
 *
 *   gsi1-host-test encode OUT                 the encoder's words of known instructions
 *   gsi1-host-test compile STAGE IN.spv OUT [OPTIONS]
 *   gsi1-host-test compute IN.spv OUT LANES GROUPS SEED [OPTIONS]
 *   gsi1-host-test fragment IN.spv OUT SEED [OPTIONS]
 *   gsi1-host-test vertex IN.spv OUT SEED [OPTIONS]
 *
 * OUT is a path prefix: OUT.bin is the program; OUT.data.hex, .warps.hex,
 * .init.hex, .prims.hex are the model's inputs; OUT.expect.* what it
 * must produce; OUT.args the model's other arguments.  OPTIONS are
 * comma-separated: samples=N, points, robust, w=WORD, regs=N, bank=N (the
 * first constant-bank word), mask (the
 * GPU writes r6), cover=HEX (the fragment warp's coverage), floats (the
 * buffers hold small floats), ia0=VKFORMAT (input attachment 0's format).
 */

#include "drivers/gpu/ghci/compiler/gsi1-compile.h"
#include "drivers/gpu/ghci/compiler/gsi1-encode.h"
#include "drivers/gpu/ghci/compiler/gsi1_isa.h"
#include "drivers/gpu/compiler/spirv.h"
#include "plan/ws288/tests/gsi1-reference.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The model's data image: its GPU address and words, and the constant bank's words at its start. */
#define MODEL_DATA_BASE		0x8000U
#define MODEL_DATA_WORDS	4096U
#define MODEL_BANK_WORDS	256U

/* The GPU address the harness gives a program's scratch memory (interface kind 14), outside the data image. */
#define MODEL_SCRATCH_BASE	0x00100000U

/* Each buffer or image of a test takes a region of 256 words after the bank. */
#define REGION_WORDS		256U
#define REGION_BYTES		(4U * REGION_WORDS)

/* The test images: 8 x 8 texels, and two layers when they fit. */
#define IMAGE_SIDE		8U

/* The varying words the model's primitive table keeps (PT words 4 to 67: CAPS[30]'s 64). */
#define MODEL_VARY		64U

/* The PT words of a vertex in the model's --prims file. */
#define MODEL_PT_WORDS		128U

/* One test's options. */
struct test_options {
	struct ghci_gsi1_options compile;
	uint32_t cover;
	int floats;
};

/* One run: the program, the IR, the model's memory and its expectation, and the reference. */
struct test_case {
	struct ghci_gsi1_program *program;
	struct drv_gpu_shader_ir *ir;
	struct test_options options;
	uint32_t data[MODEL_DATA_WORDS];
	uint32_t expect[MODEL_DATA_WORDS];
	uint8_t compare[MODEL_DATA_WORDS];
	uint32_t regions;
	uint32_t region_of[REF_UNIFORMS];
	uint32_t image_format[REF_UNIFORMS];
	uint32_t image_layers[REF_UNIFORMS];
	struct ref_run *run;
	uint32_t seed;
	uint32_t scratch_bytes;
};

static uint32_t *read_file(const char *path, size_t *words);
static int parse_options(const char *text, struct test_options *options);
static int compile_module(const char *path, enum drv_gpu_shader_stage stage, struct test_case *test);
static int write_words(const char *path, const uint32_t *words, uint32_t count);
static int write_binary(const char *prefix, const struct ghci_gsi1_program *program);
static uint32_t next_random(uint32_t *state);
static uint32_t random_float(uint32_t *state, float low, float high);
static int find_uniform(const struct drv_gpu_shader_ir *ir, uint32_t set, uint32_t binding, uint32_t *uniform);
static int bind_interface(struct test_case *test);
static int bind_buffer(struct test_case *test, uint32_t uniform, uint32_t bank, int is_storage);
static int bind_image(struct test_case *test, uint32_t uniform, uint32_t bank, uint32_t kind);
static uint32_t format_bytes(uint32_t format);
static void unpack_texel(uint32_t format, const uint8_t *bytes, uint32_t *texel);
static void pack_texel(uint32_t format, const uint32_t *texel, uint8_t *bytes);
static void store_images(struct test_case *test, uint32_t *memory);
static int run_compute(int argc, char **argv);
static int run_fragment(int argc, char **argv);
static int run_vertex(int argc, char **argv);
static int run_encode(int argc, char **argv);
static int run_compile(int argc, char **argv);
static int write_registers(const char *path, uint32_t nregs, uint32_t (*value)[32], uint8_t (*known)[32]);
static float as_float(uint32_t bits);
static uint32_t as_bits(float number);

void *kern_malloc(size_t size);
void *kern_calloc(size_t count, size_t size);
void kern_free(void *pointer);

/* The host's allocator stands in for the kernel's. */
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

/* Runs one mode. */
int
main(
	int argc,
	char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s encode|compile|compute|fragment|vertex ...\n", argv[0]);
		return 2;
	}
	if (strcmp(argv[1], "encode") == 0)
		return run_encode(argc, argv);
	if (strcmp(argv[1], "compile") == 0)
		return run_compile(argc, argv);
	if (strcmp(argv[1], "compute") == 0)
		return run_compute(argc, argv);
	if (strcmp(argv[1], "fragment") == 0)
		return run_fragment(argc, argv);
	if (strcmp(argv[1], "vertex") == 0)
		return run_vertex(argc, argv);
	fprintf(stderr, "%s: unknown mode %s\n", argv[0], argv[1]);
	return 2;
}

/*
 * Writes the encoder's words of known instructions, one per line: the 64
 * bits in hex, a tab, and the assembly gsi1asm.py makes the same words
 * from.
 */
static int
run_encode(
	int argc,
	char **argv)
{
	struct gsi1_extra extra;
	FILE *out;

	if (argc != 3)
		return 2;
	out = fopen(argv[2], "w");
	if (out == NULL)
		return 1;

#define EMIT(word, text) fprintf(out, "%016llx\t%s\n", (unsigned long long)(word), text)
	memset(&extra, 0, sizeof(extra));
	EMIT(gsi1_encode_r(GSI1_OP_OP, GSI1_F3_ADD, GSI1_F7_BASE, 1, 2, 3, NULL), "add r1, r2, r3");
	EMIT(gsi1_encode_r(GSI1_OP_OP, GSI1_F3_ADD, GSI1_F7_ALT, 40, 33, 62, NULL), "sub r40, r33, r62");
	EMIT(gsi1_encode_r(GSI1_OP_OP, GSI1_F3_SLTU, GSI1_F7_BASE, 5, GSI1_ZERO, 7, NULL), "sltu r5, zero, r7");
	EMIT(gsi1_encode_r(GSI1_OP_OP, GSI1_F3_MINU, GSI1_F7_MINMAX, 9, 10, GSI1_C(3), NULL), "minu r9, r10, c3");
	EMIT(gsi1_encode_r(GSI1_OP_OP, GSI1_F3_REM, GSI1_F7_MULDIV, 1, 2, 3, NULL), "rem r1, r2, r3");
	EMIT(gsi1_encode_i(GSI1_OP_OPIMM, GSI1_F3_ADD, 4, GSI1_ZERO, -1, 0), "addi r4, zero, -1");
	EMIT(gsi1_encode_i(GSI1_OP_OPIMM, GSI1_F3_ADD, 4, 5, 123456, 0), "addi r4, r5, 123456");
	EMIT(gsi1_encode_i(GSI1_OP_OPIMM, GSI1_F3_AND, 4, 5, 0xffff, 0), "andi r4, r5, 65535");
	EMIT(gsi1_encode_i(GSI1_OP_OPIMM, GSI1_F3_SLTU, 4, 5, 1, 0), "sltiu r4, r5, 1");
	EMIT(gsi1_encode_shift(GSI1_F3_SRL, GSI1_F7_ALT, 6, 7, 16), "srai r6, r7, 16");
	EMIT(gsi1_encode_shift(GSI1_F3_SLL, GSI1_F7_BASE, 6, 50, 31), "slli r6, r50, 31");
	EMIT(gsi1_encode_movi(12, 0x3f800001U), "movi r12, 0x3f800001");
	EMIT(gsi1_encode_movi(44, 0xdead0000U), "lui r44, 0xdead0");
	EMIT(gsi1_encode_i(GSI1_OP_LOAD, GSI1_F3_LW, 3, GSI1_C(1), 16, 0), "lw r3, 16(c1)");
	EMIT(gsi1_encode_i(GSI1_OP_LOAD, GSI1_F3_LWC, 3, GSI1_ZERO, 200, 0), "lwc r3, 200(zero)");
	EMIT(gsi1_encode_s(GSI1_OP_STORE, GSI1_F3_SW, 8, 9, -8), "sw r9, -8(r8)");
	EMIT(gsi1_encode_s(GSI1_OP_STORE, GSI1_F3_SW, 8, 9, 40000), "sw r9, 40000(r8)");
	EMIT(gsi1_encode_s(GSI1_OP_STORE, GSI1_F3_SW, 40, 9, 384) | ((uint64_t)(GSI1_SW_X << GSI1_W1_SUB_SHIFT) << 32), "sw.x r9, 384(r40)");
	EMIT(gsi1_encode_b(GSI1_F3_BEXNZ, 0, -5), "bexnz -5");
	EMIT(gsi1_encode_b(GSI1_F3_BNONE, 33, 3000), "bnone r33, 3000");
	EMIT(gsi1_encode_b(GSI1_F3_J, 0, 7), "j 7");
	extra.modifiers = GSI1_W1_N1 | GSI1_W1_N2;
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, 0, GSI1_F7_FSGNJ, 1, 2, 2, &extra), "fsgnj.s r1, -r2, -r2");
	extra.modifiers = GSI1_W1_SAT;
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, GSI1_RM_RNE, GSI1_F7_FADD, 1, 3, GSI1_ZERO, &extra), "fadd.s.sat r1, r3, zero");
	extra.modifiers = 0;
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, GSI1_RM_RTZ, GSI1_F7_FCVT_W_S, 1, 2, 1, &extra), "fcvt.wu.s r1, r2, rtz");
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, GSI1_RM_RDN, GSI1_F7_FROUND, 1, 2, GSI1_RS2_FROUND, &extra), "fround.s r1, r2, rdn");
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, GSI1_F3_FLE, GSI1_F7_FCMP, 1, 2, 3, &extra), "fle.s r1, r2, r3");
	EMIT(gsi1_encode_r(GSI1_OP_OPFP, GSI1_RM_RNE, GSI1_F7_FSQRT, 1, 2, 0, &extra), "fsqrt.s r1, r2");
	EMIT(gsi1_encode_r4(GSI1_OP_MADD, GSI1_RM_RNE, 1, 2, 3, 4, &extra), "fmadd.s r1, r2, r3, r4");
	EMIT(gsi1_encode_r4(GSI1_OP_NMSUB, GSI1_RM_RNE, 40, 41, 42, 43, &extra), "fnmsub.s r40, r41, r42, r43");
	extra.sub = GSI1_ATOM_CMPXCHG;
	EMIT(gsi1_encode_r4(GSI1_OP_CUSTOM0, GSI1_F3_ATOM, 1, 2, 3, 4, &extra), "atom.cmpxchg r1, (r2), r3, r4");
	extra.sub = GSI1_ATOM_ADD;
	EMIT(gsi1_encode_r4(GSI1_OP_CUSTOM0, GSI1_F3_ATOM, 1, 2, 3, 0, &extra), "atom.add r1, (r2), r3");
	extra.sub = GSI1_ATOM_UMIN | GSI1_ATOM_SHARED;
	EMIT(gsi1_encode_r4(GSI1_OP_CUSTOM0, GSI1_F3_ATOM, 40, 41, 42, 0, &extra), "atoms.umin r40, (r41), r42");
	extra.sub = GSI1_ATOM_CMPXCHG | GSI1_ATOM_SHARED;
	EMIT(gsi1_encode_r4(GSI1_OP_CUSTOM0, GSI1_F3_ATOM, 1, 2, 3, 4, &extra), "atoms.cmpxchg r1, (r2), r3, r4");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM0, GSI1_F3_LDS, 5, 6, 64, 0), "lds r5, 64(r6)");
	EMIT(gsi1_encode_s(GSI1_OP_CUSTOM0, GSI1_F3_STS, GSI1_ZERO, 7, 128), "sts r7, 128(zero)");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM0, GSI1_F3_FENCE, 0, 0, 5, 0), "fence 5");
	extra.sub = 0;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM0, GSI1_F3_BAR, 0, 0, 0, 0, &extra), "bar");
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM0, GSI1_F3_END, 0, 0, 0, 0, &extra), "end");
	extra.sub = 3;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM1, GSI1_F3_TEXB, 0x20 | 1, 8, 12, GSI1_ZERO, &extra), "texb.3.c r8, r12, zero, 3");
	extra.sub = 15;
	extra.offset_u = -1;
	extra.offset_v = 7;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM1, GSI1_F3_TEXL, 0, 20, 24, 26, &extra), "texl r20, r24, r26, 15, off(-1, 7)");
	extra.offset_u = 0;
	extra.offset_v = 0;
	extra.sub = 2;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM1, GSI1_F3_TEXL, GSI1_TEX_F7_GATHER | (2U << 2), 20, 24, 0, &extra), "texg.b r20, r24, 2");
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM1, GSI1_F3_TEXF, 0, 20, 24, 25, &extra), "texf r20, r24, r25, 2");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM1, GSI1_F3_TEXSZ, 9, 10, GSI1_TEXSZ_SIZE, 4), "texsz r9, r10, 4");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM1, GSI1_F3_TEXSZ, 9, 0, GSI1_TEXSZ_LEVELS, 4), "texsz.l r9, 4");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM1, GSI1_F3_TEXSZ, 9, 0, GSI1_TEXSZ_SAMPLES, 4), "texsz.s r9, 4");
	EMIT(gsi1_encode_s(GSI1_OP_CUSTOM1, GSI1_F3_EXP, 0, 5, GSI1_EXP_SAMPLE_MASK), "exp r5, 0x105");
	EMIT(gsi1_encode_s(GSI1_OP_CUSTOM1, GSI1_F3_EXP, 0, GSI1_ONE, GSI1_EXP_COLOR(3, 2)), "exp one, 0x132");
	EMIT(gsi1_encode_i(GSI1_OP_CUSTOM1, GSI1_F3_LDA, 7, 0, GSI1_LDA(GSI1_PT_VARYING(5), 2), 0), "lda r7, 38");
	extra.sub = GSI1_QD_BCAST;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM1, GSI1_F3_QD, 0, 7, 8, 0, &extra), "qbcast r7, r8");
	extra.sub = 0;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM2, GSI1_F3_PACK, GSI1_F7_PACKH, 7, 8, 9, &extra), "packh r7, r8, r9");
	extra.sub = 1;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM2, GSI1_F3_PACK, GSI1_F7_UNPACKH, 7, 8, 0, &extra), "unpackh.hi r7, r8");
	extra.sub = 0;
	EMIT(gsi1_encode_r4(GSI1_OP_CUSTOM3, GSI1_F3_SEL, 1, 2, 3, GSI1_ZERO, &extra), "sel r1, r2, r3, zero");
	extra.sub = GSI1_EXEC_SAVE;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM3, GSI1_F3_EXEC, 0, 30, 0, 0, &extra), "exec.save r30");
	extra.sub = GSI1_EXEC_AND;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM3, GSI1_F3_EXEC, 0, 0, 31, 0, &extra), "exec.and r31");
	extra.sub = 0;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM3, GSI1_F3_KILL, 0, 0, 3, 0, &extra), "kill r3");
	extra.sub = GSI1_XU_LOG2;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM3, GSI1_F3_XU, 0, 3, 4, 0, &extra), "log2 r3, r4");
	extra.sub = GSI1_XU_FRACT;
	EMIT(gsi1_encode_r(GSI1_OP_CUSTOM3, GSI1_F3_XU, 0, 3, 4, 0, &extra), "fract r3, r4");
#undef EMIT
	fclose(out);
	return 0;
}

/* Compiles a module and writes its binary. */
static int
run_compile(
	int argc,
	char **argv)
{
	struct test_case *test;
	enum drv_gpu_shader_stage stage;
	int error;

	if (argc < 5)
		return 2;
	test = calloc(1U, sizeof(*test));
	if (test == NULL)
		return 1;
	if (parse_options(argc > 5 ? argv[5] : "", &test->options) != 0)
		return 2;
	if (strcmp(argv[2], "vertex") == 0) {
		stage = DRV_GPU_STAGE_VERTEX;
	} else if (strcmp(argv[2], "fragment") == 0) {
		stage = DRV_GPU_STAGE_FRAGMENT;
	} else {
		stage = DRV_GPU_STAGE_COMPUTE;
	}
	error = compile_module(argv[3], stage, test);
	if (error != 0)
		return 1;
	error = write_binary(argv[4], test->program);
	ghci_gsi1_program_free(test->program);
	drv_gpu_shader_ir_free(test->ir);
	free(test);
	return error;
}

/*
 * A compute dispatch: LANES invocations to a workgroup (1D), GROUPS
 * workgroups; the buffers hold random words, the reference runs each
 * workgroup, and the model must leave the same memory.
 */
static int
run_compute(
	int argc,
	char **argv)
{
	struct test_case *test;
	FILE *args;
	char path[1024];
	uint32_t lanes;
	uint32_t groups;
	uint32_t group;
	uint32_t uniform;
	uint32_t word;
	const char *why;

	if (argc < 7)
		return 2;
	test = calloc(1U, sizeof(*test));
	if (test == NULL)
		return 1;
	if (parse_options(argc > 7 ? argv[7] : "", &test->options) != 0)
		return 2;
	lanes = (uint32_t)strtoul(argv[4], NULL, 0);
	groups = (uint32_t)strtoul(argv[5], NULL, 0);
	test->seed = (uint32_t)strtoul(argv[6], NULL, 0) | 1U;
	if (compile_module(argv[2], DRV_GPU_STAGE_COMPUTE, test) != 0)
		return 1;
	if (test->ir->local_size[0] * test->ir->local_size[1] * test->ir->local_size[2] != lanes ||
	    test->ir->local_size[1] != 1U || lanes > REF_LANES) {
		fprintf(stderr, "%s: the workgroup is not %u invocations along x\n", argv[2], lanes);
		return 1;
	}

	/* The memory the interface table asks for. */
	test->run = calloc(1U, sizeof(*test->run));
	if (test->run == NULL)
		return 1;
	test->run->ir = test->ir;
	test->run->lanes = lanes;
	test->run->groups = groups;
	if (bind_interface(test) != 0)
		return 1;

	/* The reference, workgroup by workgroup. */
	for (group = 0U; group < groups; group++) {
		test->run->group = group;
		memset(test->run->shared, 0, sizeof(test->run->shared));
		why = ref_execute(test->run);
		free(test->run->values);
		test->run->values = NULL;
		if (why != NULL) {
			fprintf(stderr, "%s: the reference stops: %s\n", argv[2], why);
			return 1;
		}
	}

	/* What the model must leave: the regions as the reference left them. */
	memcpy(test->expect, test->data, sizeof(test->expect));
	for (uniform = 0U; uniform < test->ir->uniform_count && uniform < REF_UNIFORMS; uniform++) {
		if (test->run->bytes[uniform] == NULL || test->region_of[uniform] == UINT32_MAX)
			continue;
		if (test->ir->uniforms[uniform].kind != DRV_GPU_IR_UNIFORM_STORAGE)
			continue;
		for (word = 0U; word < REGION_WORDS; word++) {
			memcpy(&test->expect[test->region_of[uniform] + word], test->run->bytes[uniform] + 4U * word, 4U);
			test->compare[test->region_of[uniform] + word] = (uint8_t)(1U + (test->options.floats != 0));
		}
	}
	store_images(test, test->expect);

	/* The files. */
	if (write_binary(argv[3], test->program) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.data.hex", argv[3]);
	if (write_words(path, test->data, MODEL_DATA_WORDS) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.expect.hex", argv[3]);
	if (write_words(path, test->expect, MODEL_DATA_WORDS) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.compare", argv[3]);
	args = fopen(path, "w");
	if (args == NULL)
		return 1;
	for (word = 0U; word < MODEL_DATA_WORDS; word++)
		fprintf(args, "%u\n", test->compare[word]);
	fclose(args);
	snprintf(path, sizeof(path), "%s.args", argv[3]);
	args = fopen(path, "w");
	if (args == NULL)
		return 1;
	fprintf(args, "--lanes %u --groups %u --nregs %u", lanes, groups, test->program->words[GSI1_H_NREGS] > 32U ? 64U : 32U);
	if (test->scratch_bytes != 0U)
		fprintf(args, " --scratch %#x,%u", MODEL_SCRATCH_BASE, test->scratch_bytes);
	fprintf(args, "\n");
	fclose(args);
	return 0;
}

/*
 * One fragment warp in slot 0: the rasterizer's registers (random
 * barycentrics, depth, the pixel centres of 8 quads, the sample mask and
 * the centroid's barycentrics) and the primitive table's varyings; the
 * reference interpolates the inputs as ir.h says, and the model's exports
 * must be the reference's outputs.
 */
static int
run_fragment(
	int argc,
	char **argv)
{
	struct test_case *test;
	static uint32_t regs[4 * 64][32];
	static uint8_t known[4 * 64][32];
	static uint32_t prims[4 * 3 * MODEL_PT_WORDS];
	uint32_t warps[20];
	uint32_t exports[1 + 8 * 22];
	uint32_t ms[8];
	uint32_t vertex_value[3][64];
	float bary[32][3];
	float centroid[32][3];
	float weighted[3];
	float sum;
	const struct drv_gpu_shader_ir_io *io;
	struct ref_run *run;
	char path[1024];
	FILE *out;
	uint32_t lane;
	uint32_t index;
	uint32_t component;
	uint32_t vertex;
	uint32_t word;
	uint32_t quads;
	uint32_t quad;
	uint32_t mask;
	uint32_t exported;
	uint32_t smask;
	uint32_t zexp;
	uint32_t nregs;
	uint32_t count;
	uint32_t inner;
	uint32_t sample_out;
	uint32_t w_word;
	int centroid_input;
	const char *why;

	if (argc < 5)
		return 2;
	test = calloc(1U, sizeof(*test));
	if (test == NULL)
		return 1;
	test->options.cover = UINT32_MAX;
	if (parse_options(argc > 5 ? argv[5] : "", &test->options) != 0)
		return 2;
	test->seed = (uint32_t)strtoul(argv[4], NULL, 0) | 1U;
	if (compile_module(argv[2], DRV_GPU_STAGE_FRAGMENT, test) != 0)
		return 1;
	nregs = test->program->words[GSI1_H_NREGS] > 32U ? 64U : 32U;
	w_word = test->options.compile.has_w_word != 0U ? test->options.compile.w_word : UINT32_MAX;

	/* The reference's run. */
	test->run = calloc(1U, sizeof(*test->run));
	if (test->run == NULL)
		return 1;
	run = test->run;
	run->ir = test->ir;
	run->lanes = 32U;
	run->groups = 1U;
	if (bind_interface(test) != 0)
		return 1;

	/* The primitive table: each vertex's varying words. */
	memset(prims, 0, sizeof(prims));
	for (vertex = 0U; vertex < 3U; vertex++) {
		for (word = 0U; word < MODEL_VARY; word++) {
			vertex_value[vertex][word] = random_float(&test->seed, -2.0f, 2.0f);
			if (word == w_word)
				vertex_value[vertex][word] = random_float(&test->seed, 1.0f, 2.0f);
			prims[vertex * MODEL_PT_WORDS + 4U + word] = vertex_value[vertex][word];
		}
	}

	/* The rasterizer's registers of each lane. */
	memset(known, 0, sizeof(known));
	for (lane = 0U; lane < 32U; lane++) {
		float b0;
		float b1;

		b0 = as_float(random_float(&test->seed, 0.05f, 0.6f));
		b1 = as_float(random_float(&test->seed, 0.05f, 0.35f));
		bary[lane][0] = b0;
		bary[lane][1] = b1;
		bary[lane][2] = (1.0f - b0) - b1;
		b0 = as_float(random_float(&test->seed, 0.05f, 0.6f));
		b1 = as_float(random_float(&test->seed, 0.05f, 0.35f));
		centroid[lane][0] = b0;
		centroid[lane][1] = b1;
		centroid[lane][2] = (1.0f - b0) - b1;
		for (index = 0U; index < 3U; index++) {
			regs[GSI1_IN_B0 + index][lane] = as_bits(bary[lane][index]);
			regs[GSI1_IN_CENTROID_B0 + index][lane] = as_bits(centroid[lane][index]);
		}
		regs[GSI1_IN_Z][lane] = random_float(&test->seed, -0.25f, 1.25f);
		quad = lane / 4U;
		run->pixel_x[lane] = 2U * (quad % 4U) + (lane & 1U);
		run->pixel_y[lane] = 2U * (quad / 4U) + ((lane >> 1) & 1U);
		regs[GSI1_IN_X][lane] = as_bits((float)run->pixel_x[lane] + 0.5f);
		regs[GSI1_IN_Y][lane] = as_bits((float)run->pixel_y[lane] + 0.5f);
		regs[GSI1_IN_SAMPLE_MASK][lane] = (next_random(&test->seed) % 15U) + 1U;
		for (index = 0U; index <= GSI1_IN_CENTROID_B0 + 2U; index++)
			known[index][lane] = 1U;
		run->helper[lane] = (uint8_t)(((test->options.cover >> lane) & 1U) == 0U);
	}

	/* Each lane's inputs as the IR has them. */
	for (lane = 0U; lane < 32U; lane++) {
		weighted[0] = 0.0f;
		sum = 0.0f;
		for (index = 0U; index < test->ir->input_count; index++) {
			io = &test->ir->inputs[index];
			if (io->location >= 16U)
				continue;
			centroid_input = io->centroid != 0U && test->options.compile.samples > 1U;
			for (component = 0U; component < 4U; component++) {
				word = 4U * io->location + component;
				if (io->flat != 0U || test->options.compile.points != 0U) {
					run->input[lane][io->location][component] = vertex_value[0][word];
					continue;
				}
				for (vertex = 0U; vertex < 3U; vertex++) {
					weighted[vertex] = centroid_input ? centroid[lane][vertex] : bary[lane][vertex];
				}
				if (io->noperspective != 0U) {
					sum = 0.0f;
					for (vertex = 0U; vertex < 3U; vertex++) {
						weighted[vertex] *= as_float(vertex_value[vertex][w_word]);
						sum += weighted[vertex];
					}
					for (vertex = 0U; vertex < 3U; vertex++)
						weighted[vertex] /= sum;
				}
				run->input[lane][io->location][component] =
				    as_bits(as_float(vertex_value[0][word]) * weighted[0] +
					    as_float(vertex_value[1][word]) * weighted[1] +
					    as_float(vertex_value[2][word]) * weighted[2]);
			}
		}

		/* The built-ins. */
		run->input[lane][DRV_GPU_SHADER_LOCATION_FRAG_COORD][0] = regs[GSI1_IN_X][lane];
		run->input[lane][DRV_GPU_SHADER_LOCATION_FRAG_COORD][1] = regs[GSI1_IN_Y][lane];
		run->input[lane][DRV_GPU_SHADER_LOCATION_FRAG_COORD][2] = as_bits(fminf(fmaxf(as_float(regs[GSI1_IN_Z][lane]), 0.0f), 1.0f));
		if (w_word != UINT32_MAX) {
			sum = 0.0f;
			for (vertex = 0U; vertex < 3U; vertex++)
				sum += bary[lane][vertex] * as_float(vertex_value[vertex][w_word]);
			run->input[lane][DRV_GPU_SHADER_LOCATION_FRAG_COORD][3] = as_bits(1.0f / sum);
		}
		run->input[lane][DRV_GPU_SHADER_LOCATION_FRONT_FACING][0] = UINT32_MAX;
		run->input[lane][DRV_GPU_SHADER_LOCATION_SAMPLE_MASK][0] = test->options.compile.sample_mask_input != 0U ?
		    regs[GSI1_IN_SAMPLE_MASK][lane] : 1U;
		run->input[lane][DRV_GPU_SHADER_LOCATION_POINT_COORD][0] = regs[GSI1_IN_B0][lane];
		run->input[lane][DRV_GPU_SHADER_LOCATION_POINT_COORD][1] = regs[GSI1_IN_B1][lane];
	}

	/* The reference. */
	why = ref_execute(run);
	if (why != NULL) {
		fprintf(stderr, "%s: the reference stops: %s\n", argv[2], why);
		return 1;
	}

	/* The quads the model reports: those with coverage, from the first. */
	quads = 0U;
	while (quads < 8U && ((test->options.cover >> (4U * quads)) & 15U) != 0U)
		quads++;
	count = 0U;
	exports[count++] = quads;
	for (quad = 0U; quad < quads; quad++) {
		mask = 0U;
		smask = 0U;
		zexp = 0U;
		for (inner = 0U; inner < 4U; inner++) {
			lane = 4U * quad + inner;
			exported = 0U;
			if (run->helper[lane] != 0U || run->killed[lane] != 0U)
				continue;
			sample_out = UINT32_MAX;
			if (run->written[lane][REF_SLOT_SAMPLE_MASK][0] != 0U)
				sample_out = run->output[lane][REF_SLOT_SAMPLE_MASK][0];
			exported = 1U;
			if ((regs[GSI1_IN_SAMPLE_MASK][lane] & sample_out & 15U) == 0U)
				continue;
			mask |= 1U << inner;
			smask |= (regs[GSI1_IN_SAMPLE_MASK][lane] & sample_out & 15U) << (4U * inner);
			if (run->written[lane][REF_SLOT_DEPTH][0] != 0U)
				zexp |= 1U << inner;
			(void)exported;
		}

		/* The quad's one beat (attachment 0, its first and last): seq 0, qlast, qfirst, last, mask. */
		exports[count++] = (0U << 16) | (1U << 12) | (1U << 11) | ((quad == quads - 1U ? 1U : 0U) << 8) | mask;
		lane = 4U * quad;
		exports[count++] = (run->pixel_y[lane] << 16) | run->pixel_x[lane];
		for (inner = 0U; inner < 4U; inner++) {
			lane = 4U * quad + inner;
			for (component = 0U; component < 4U; component++) {
				word = 0U;
				if ((mask >> inner) & 1U && run->written[lane][0][component] != 0U)
					word = run->output[lane][0][component];
				exports[count++] = word;
			}
			word = 0U;
			if ((mask >> inner) & 1U) {
				word = regs[GSI1_IN_Z][lane];
				if (run->written[lane][REF_SLOT_DEPTH][0] != 0U)
					word = run->output[lane][REF_SLOT_DEPTH][0];
			}
			exports[count++] = word;
		}
		ms[quad] = (zexp << 16) | smask;
	}

	/* The files. */
	if (write_binary(argv[3], test->program) != 0)
		return 1;
	memset(warps, 0, sizeof(warps));
	warps[0] = 1U;
	warps[1] = UINT32_MAX;
	warps[2] = test->options.cover;
	warps[3] = 0U;
	warps[4] = 1U;
	for (index = 1U; index < 4U; index++)
		warps[5U * index] = 2U;
	snprintf(path, sizeof(path), "%s.warps.hex", argv[3]);
	if (write_words(path, warps, 20U) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.init.hex", argv[3]);
	if (write_registers(path, nregs, regs, known) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.prims.hex", argv[3]);
	if (write_words(path, prims, 4U * 3U * MODEL_PT_WORDS) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.data.hex", argv[3]);
	if (write_words(path, test->data, MODEL_DATA_WORDS) != 0)
		return 1;
	memcpy(test->expect, test->data, sizeof(test->expect));
	store_images(test, test->expect);
	for (index = 0U; index < test->ir->uniform_count && index < REF_UNIFORMS; index++) {
		if (test->run->bytes[index] == NULL || test->region_of[index] == UINT32_MAX)
			continue;
		if (test->ir->uniforms[index].kind != DRV_GPU_IR_UNIFORM_STORAGE)
			continue;
		for (word = 0U; word < REGION_WORDS; word++) {
			memcpy(&test->expect[test->region_of[index] + word], test->run->bytes[index] + 4U * word, 4U);
			test->compare[test->region_of[index] + word] = 1U;
		}
	}
	snprintf(path, sizeof(path), "%s.expect.hex", argv[3]);
	if (write_words(path, test->expect, MODEL_DATA_WORDS) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.compare", argv[3]);
	out = fopen(path, "w");
	if (out == NULL)
		return 1;
	for (word = 0U; word < MODEL_DATA_WORDS; word++)
		fprintf(out, "%u\n", test->compare[word]);
	fclose(out);
	snprintf(path, sizeof(path), "%s.expect-exp.hex", argv[3]);
	if (write_words(path, exports, count) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.expect-ms.hex", argv[3]);
	if (write_words(path, ms, quads) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.args", argv[3]);
	out = fopen(path, "w");
	if (out == NULL)
		return 1;
	fprintf(out, "--nregs %u --vary %u", nregs, MODEL_VARY);
	if (test->scratch_bytes != 0U)
		fprintf(out, " --scratch %#x,%u", MODEL_SCRATCH_BASE, test->scratch_bytes);
	fprintf(out, "\n");
	fclose(out);
	return 0;
}

/*
 * One vertex warp in slot 0: the attributes in the registers the
 * interface table names (random floats), the vertex and instance numbers;
 * the model's primitive-table entries must be the reference's outputs.
 */
static int
run_vertex(
	int argc,
	char **argv)
{
	struct test_case *test;
	static uint32_t regs[4 * 64][32];
	static uint8_t known[4 * 64][32];
	uint32_t warps[20];
	static uint32_t pt[32 * (4 + MODEL_VARY)];
	static uint8_t pt_known[32 * (4 + MODEL_VARY)];
	const uint32_t *entry;
	struct ref_run *run;
	char path[1024];
	FILE *out;
	uint32_t lane;
	uint32_t index;
	uint32_t component;
	uint32_t location;
	uint32_t first;
	uint32_t count;
	uint32_t nregs;
	uint32_t w_word;
	const char *why;

	if (argc < 5)
		return 2;
	test = calloc(1U, sizeof(*test));
	if (test == NULL)
		return 1;
	if (parse_options(argc > 5 ? argv[5] : "", &test->options) != 0)
		return 2;
	test->seed = (uint32_t)strtoul(argv[4], NULL, 0) | 1U;
	if (compile_module(argv[2], DRV_GPU_STAGE_VERTEX, test) != 0)
		return 1;
	nregs = test->program->words[GSI1_H_NREGS] > 32U ? 64U : 32U;
	w_word = test->options.compile.has_w_word != 0U ? test->options.compile.w_word : UINT32_MAX;
	test->run = calloc(1U, sizeof(*test->run));
	if (test->run == NULL)
		return 1;
	run = test->run;
	run->ir = test->ir;
	run->lanes = 32U;
	run->groups = 1U;
	if (bind_interface(test) != 0)
		return 1;

	/* The attributes and the numbers, where the interface table puts them. */
	memset(known, 0, sizeof(known));
	for (index = 0U; index < test->program->words[GSI1_H_IFACE_ENTRIES]; index++) {
		entry = &test->program->words[GSI1_HEADER_WORDS + 4U * index];
		if (entry[GSI1_IF_KIND] == GSI1_KIND_ATTRIBUTE) {
			location = entry[GSI1_IF_BINDING];
			first = entry[GSI1_IF_SPECIFIC] & 0xffU;
			count = (entry[GSI1_IF_SPECIFIC] >> 8) & 0xffU;
			for (lane = 0U; lane < 32U; lane++) {
				for (component = 0U; component < count; component++) {
					regs[first + component][lane] = random_float(&test->seed, -4.0f, 4.0f);
					known[first + component][lane] = 1U;
					run->input[lane][location][component] = regs[first + component][lane];
				}
			}
		} else if (entry[GSI1_IF_KIND] == GSI1_KIND_SYSTEM) {
			first = entry[GSI1_IF_SPECIFIC];
			for (lane = 0U; lane < 32U; lane++) {
				regs[first][lane] = entry[GSI1_IF_BINDING] == GSI1_SYSTEM_VERTEX_INDEX ? lane + 7U : 3U;
				known[first][lane] = 1U;
				run->input[lane][entry[GSI1_IF_BINDING] == GSI1_SYSTEM_VERTEX_INDEX ?
				    DRV_GPU_SHADER_LOCATION_VERTEX_INDEX : DRV_GPU_SHADER_LOCATION_INSTANCE_INDEX][0] = regs[first][lane];
			}
		}
	}

	/* The reference. */
	why = ref_execute(run);
	if (why != NULL) {
		fprintf(stderr, "%s: the reference stops: %s\n", argv[2], why);
		return 1;
	}

	/* The primitive-table words the model must leave. */
	memset(pt_known, 0, sizeof(pt_known));
	for (lane = 0U; lane < 32U; lane++) {
		for (component = 0U; component < 4U; component++) {
			if (run->written[lane][REF_SLOT_POSITION][component] == 0U)
				continue;
			pt[lane * (4U + MODEL_VARY) + component] = run->output[lane][REF_SLOT_POSITION][component];
			pt_known[lane * (4U + MODEL_VARY) + component] = 1U;
		}
		if (w_word != UINT32_MAX && run->written[lane][REF_SLOT_POSITION][3] != 0U) {
			pt[lane * (4U + MODEL_VARY) + 4U + w_word] = run->output[lane][REF_SLOT_POSITION][3];
			pt_known[lane * (4U + MODEL_VARY) + 4U + w_word] = 1U;
		}
		for (location = 0U; location < GHCI_GSI1_LOCATIONS; location++) {
			for (component = 0U; component < 4U; component++) {
				if (run->written[lane][location][component] == 0U)
					continue;
				pt[lane * (4U + MODEL_VARY) + 4U + 4U * location + component] = run->output[lane][location][component];
				pt_known[lane * (4U + MODEL_VARY) + 4U + 4U * location + component] = 1U;
			}
		}
	}

	/* The files. */
	if (write_binary(argv[3], test->program) != 0)
		return 1;
	memset(warps, 0, sizeof(warps));
	warps[0] = 0U;
	warps[1] = UINT32_MAX;
	warps[2] = UINT32_MAX;
	for (index = 1U; index < 4U; index++)
		warps[5U * index] = 2U;
	snprintf(path, sizeof(path), "%s.warps.hex", argv[3]);
	if (write_words(path, warps, 20U) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.init.hex", argv[3]);
	if (write_registers(path, nregs, regs, known) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.data.hex", argv[3]);
	if (write_words(path, test->data, MODEL_DATA_WORDS) != 0)
		return 1;
	snprintf(path, sizeof(path), "%s.expect-pt.hex", argv[3]);
	out = fopen(path, "w");
	if (out == NULL)
		return 1;
	for (index = 0U; index < 32U * (4U + MODEL_VARY); index++) {
		if (pt_known[index] != 0U) {
			fprintf(out, "1%08x\n", pt[index]);
		} else {
			fprintf(out, "000000000\n");
		}
	}
	fclose(out);
	snprintf(path, sizeof(path), "%s.args", argv[3]);
	out = fopen(path, "w");
	if (out == NULL)
		return 1;
	fprintf(out, "--nregs %u --vary %u", nregs, MODEL_VARY);
	if (test->scratch_bytes != 0U)
		fprintf(out, " --scratch %#x,%u", MODEL_SCRATCH_BASE, test->scratch_bytes);
	fprintf(out, "\n");
	fclose(out);
	return 0;
}

/* Reads a SPIR-V module. */
static uint32_t *
read_file(
	const char *path,
	size_t *words)
{
	FILE *file;
	uint32_t *data;
	long length;

	file = fopen(path, "rb");
	if (file == NULL)
		return NULL;
	fseek(file, 0, SEEK_END);
	length = ftell(file);
	fseek(file, 0, SEEK_SET);
	data = malloc((size_t)length + 4U);
	if (data == NULL || fread(data, 1U, (size_t)length, file) != (size_t)length) {
		fclose(file);
		free(data);
		return NULL;
	}
	fclose(file);
	*words = (size_t)length / 4U;
	return data;
}

/* Reads the comma-separated options. */
static int
parse_options(
	const char *text,
	struct test_options *options)
{
	char buffer[512];
	char *item;
	char *next;

	if (strlen(text) >= sizeof(buffer))
		return 1;
	strcpy(buffer, text);
	for (item = buffer; item != NULL && *item != '\0'; item = next) {
		next = strchr(item, ',');
		if (next != NULL)
			*next++ = '\0';
		if (strncmp(item, "samples=", 8) == 0) {
			options->compile.samples = (uint32_t)strtoul(item + 8, NULL, 0);
		} else if (strcmp(item, "points") == 0) {
			options->compile.points = 1U;
		} else if (strcmp(item, "robust") == 0) {
			options->compile.robust_buffer_access = 1U;
		} else if (strncmp(item, "w=", 2) == 0) {
			options->compile.has_w_word = 1U;
			options->compile.w_word = (uint32_t)strtoul(item + 2, NULL, 0);
		} else if (strncmp(item, "regs=", 5) == 0) {
			options->compile.registers = (uint32_t)strtoul(item + 5, NULL, 0);
		} else if (strncmp(item, "bank=", 5) == 0) {
			options->compile.bank_first = (uint32_t)strtoul(item + 5, NULL, 0);
		} else if (strcmp(item, "mask") == 0) {
			options->compile.sample_mask_input = 1U;
		} else if (strncmp(item, "cover=", 6) == 0) {
			options->cover = (uint32_t)strtoul(item + 6, NULL, 16);
		} else if (strcmp(item, "floats") == 0) {
			options->floats = 1;
		} else if (strncmp(item, "ia0=", 4) == 0) {
			options->compile.input_attachment_format[0] = (uint32_t)strtoul(item + 4, NULL, 0);
			options->compile.input_attachment_samples[0] = 1U;
		} else {
			fprintf(stderr, "unknown option %s\n", item);
			return 1;
		}
	}
	return 0;
}

/* Parses (for the reference) and compiles (for the model) a module. */
static int
compile_module(
	const char *path,
	enum drv_gpu_shader_stage stage,
	struct test_case *test)
{
	struct drv_gpu_compile_diagnostic parse_diagnostic;
	struct ghci_gsi1_diagnostic diagnostic;
	uint32_t *words;
	size_t count;
	int error;

	words = read_file(path, &count);
	if (words == NULL) {
		fprintf(stderr, "%s: cannot read\n", path);
		return 1;
	}
	memset(&parse_diagnostic, 0, sizeof(parse_diagnostic));
	error = drv_gpu_shader_parse_features(words, count, stage, DRV_GPU_SPIRV_FEATURES_GHCI, &test->ir, &parse_diagnostic);
	if (error != 0) {
		fprintf(stderr, "%s: the parser refuses (%d): %s at word %u\n", path, error,
			parse_diagnostic.reason != NULL ? parse_diagnostic.reason : "-", parse_diagnostic.word_offset);
		free(words);
		return 1;
	}
	memset(&diagnostic, 0, sizeof(diagnostic));
	error = ghci_gsi1_compile(words, count, stage, &test->options.compile, &test->program, &diagnostic);
	free(words);
	if (error != 0) {
		fprintf(stderr, "%s: the compiler refuses (%d): %s at %u\n", path, error,
			diagnostic.reason != NULL ? diagnostic.reason : "-", diagnostic.instruction);
		return 1;
	}
	return 0;
}

/* Writes 32-bit words, one per line, in hex. */
static int
write_words(
	const char *path,
	const uint32_t *words,
	uint32_t count)
{
	FILE *file;
	uint32_t index;

	file = fopen(path, "w");
	if (file == NULL)
		return 1;
	for (index = 0U; index < count; index++)
		fprintf(file, "%08x\n", words[index]);
	fclose(file);
	return 0;
}

/* Writes a program's binary (little endian). */
static int
write_binary(
	const char *prefix,
	const struct ghci_gsi1_program *program)
{
	char path[1024];
	FILE *file;

	snprintf(path, sizeof(path), "%s.bin", prefix);
	file = fopen(path, "wb");
	if (file == NULL)
		return 1;
	if (fwrite(program->words, 4U, program->word_count, file) != program->word_count) {
		fclose(file);
		return 1;
	}
	fclose(file);
	return 0;
}

/* Writes the model's register file of slot-major registers, one line per lane: known values or 0. */
static int
write_registers(
	const char *path,
	uint32_t nregs,
	uint32_t (*value)[32],
	uint8_t (*known)[32])
{
	FILE *file;
	uint32_t slot;
	uint32_t reg;
	uint32_t lane;

	file = fopen(path, "w");
	if (file == NULL)
		return 1;
	for (slot = 0U; slot < 4U; slot++) {
		for (reg = 0U; reg < nregs; reg++) {
			for (lane = 0U; lane < 32U; lane++) {
				if (slot == 0U && known[reg][lane] != 0U) {
					fprintf(file, "1%08x\n", value[reg][lane]);
				} else {
					fprintf(file, "000000000\n");
				}
			}
		}
	}
	fclose(file);
	return 0;
}

/* A xorshift step. */
static uint32_t
next_random(
	uint32_t *state)
{
	uint32_t x;

	x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return x;
}

/* A random float of [low, high), as its bits. */
static uint32_t
random_float(
	uint32_t *state,
	float low,
	float high)
{
	float unit;

	unit = (float)(next_random(state) >> 8) / 16777216.0f;
	return as_bits(low + (high - low) * unit);
}

/* Finds the uniform of a set and binding. */
static int
find_uniform(
	const struct drv_gpu_shader_ir *ir,
	uint32_t set,
	uint32_t binding,
	uint32_t *uniform)
{
	uint32_t index;

	for (index = 0U; index < ir->uniform_count; index++) {
		if (ir->uniforms[index].set == set && ir->uniforms[index].binding == binding) {
			*uniform = index;
			return 0;
		}
	}
	return 1;
}

/*
 * Plays the command processor: fills the constant bank and the regions as
 * the interface table asks, and gives the reference the same contents.
 */
static int
bind_interface(
	struct test_case *test)
{
	static uint8_t push[256];
	const uint32_t *words;
	const uint32_t *entry;
	uint32_t index;
	uint32_t uniform;
	uint32_t kind;
	uint32_t bank;
	uint32_t count;
	uint32_t first;
	uint32_t inner;
	uint32_t data;

	words = test->program->words;
	for (index = 0U; index < REF_UNIFORMS; index++)
		test->region_of[index] = UINT32_MAX;
	for (index = 0U; index < MODEL_DATA_WORDS; index++)
		test->data[index] = next_random(&test->seed);
	memset(test->data, 0, MODEL_BANK_WORDS * 4U);

	/* Each entry of the table. */
	for (index = 0U; index < words[GSI1_H_IFACE_ENTRIES]; index++) {
		entry = &words[words[GSI1_H_IFACE_OFFSET] + 4U * index];
		kind = entry[GSI1_IF_KIND];
		bank = entry[GSI1_IF_SPECIFIC];
		if (kind == GSI1_KIND_PUSH_CONSTANT) {
			for (inner = 0U; inner < words[GSI1_H_PUSH_BYTES] / 4U; inner++) {
				data = test->options.floats ? random_float(&test->seed, -8.0f, 8.0f) : next_random(&test->seed) % 1000U;
				test->data[bank + inner] = data;
				memcpy(push + 4U * inner, &data, 4U);
			}
			test->run->push = push;
			test->run->push_size = words[GSI1_H_PUSH_BYTES];
			continue;
		}
		if (kind == GSI1_KIND_SCRATCH) {
			test->data[entry[GSI1_IF_BINDING]] = MODEL_SCRATCH_BASE;
			test->scratch_bytes = entry[GSI1_IF_SPECIFIC];
			continue;
		}
		if (kind == GSI1_KIND_ATTRIBUTE || kind == GSI1_KIND_VARYING_IN || kind == GSI1_KIND_OUTPUT ||
		    kind == GSI1_KIND_SYSTEM || kind == GSI1_KIND_SHARED)
			continue;
		if (find_uniform(test->ir, entry[GSI1_IF_SET], entry[GSI1_IF_BINDING], &uniform) != 0) {
			fprintf(stderr, "an interface entry names no uniform of the module\n");
			return 1;
		}
		if (kind == GSI1_KIND_STORAGE_BUFFER || kind == GSI1_KIND_UNIFORM_MEMORY) {
			if (bind_buffer(test, uniform, bank, kind == GSI1_KIND_STORAGE_BUFFER) != 0)
				return 1;
		} else if (kind == GSI1_KIND_UNIFORM_BLOCK) {
			if (bind_buffer(test, uniform, UINT32_MAX, 0) != 0)
				return 1;
			first = (bank >> GSI1_UBO_FIRST_SHIFT) & GSI1_UBO_FIRST_MASK;
			count = (bank >> GSI1_UBO_WORDS_SHIFT) & GSI1_UBO_WORDS_MASK;
			for (inner = 0U; inner < count; inner++)
				memcpy(&test->data[(bank & GSI1_UBO_BANK_MASK) + inner], test->run->bytes[uniform] + 4U * (first + inner), 4U);
		} else if (kind == GSI1_KIND_STORAGE_IMAGE || kind == GSI1_KIND_TEXEL_BUFFER || kind == GSI1_KIND_INPUT_ATTACHMENT) {
			if (bind_image(test, uniform, bank, kind) != 0)
				return 1;
		} else if (kind == GSI1_KIND_SAMPLED_IMAGE) {
			fprintf(stderr, "a sampled image: the model has no texture unit\n");
			return 1;
		}
	}
	return 0;
}

/*
 * Gives a buffer a region (random words, or small floats) and, for one
 * read through the bank's descriptor words, its {address, bytes}.
 */
static int
bind_buffer(
	struct test_case *test,
	uint32_t uniform,
	uint32_t bank,
	int is_storage)
{
	uint32_t region;
	uint32_t word;

	(void)is_storage;
	if (test->regions >= (MODEL_DATA_WORDS - MODEL_BANK_WORDS) / REGION_WORDS)
		return 1;
	region = MODEL_BANK_WORDS + REGION_WORDS * test->regions;
	test->regions++;
	test->region_of[uniform] = region;
	for (word = 0U; word < REGION_WORDS; word++) {
		if (test->options.floats) {
			test->data[region + word] = random_float(&test->seed, -8.0f, 8.0f);
		} else {
			test->data[region + word] = next_random(&test->seed) % 4096U;
		}
	}
	test->run->bytes[uniform] = malloc(REGION_BYTES);
	if (test->run->bytes[uniform] == NULL)
		return 1;
	memcpy(test->run->bytes[uniform], &test->data[region], REGION_BYTES);
	test->run->size[uniform] = REGION_BYTES;
	if (bank != UINT32_MAX) {
		test->data[bank] = MODEL_DATA_BASE + 4U * region;
		test->data[bank + 1U] = REGION_BYTES;
	}
	return 0;
}

/*
 * Gives a storage image, a texel buffer or an input attachment a region:
 * random texels in the format, the descriptor words, and the reference's
 * image of the texels unpacked.
 */
static int
bind_image(
	struct test_case *test,
	uint32_t uniform,
	uint32_t bank,
	uint32_t kind)
{
	struct ref_image *image;
	uint32_t region;
	uint32_t format;
	uint32_t bytes;
	uint32_t texels;
	uint32_t index;
	uint8_t *memory;

	if (test->regions >= (MODEL_DATA_WORDS - MODEL_BANK_WORDS) / REGION_WORDS)
		return 1;
	region = MODEL_BANK_WORDS + REGION_WORDS * test->regions;
	test->regions++;
	test->region_of[uniform] = region;
	format = test->ir->uniforms[uniform].format;
	if (kind == GSI1_KIND_INPUT_ATTACHMENT)
		format = test->options.compile.input_attachment_format[test->ir->uniforms[uniform].input_attachment_index];
	bytes = format_bytes(format);
	if (bytes == 0U) {
		fprintf(stderr, "an image of format %u the test does not convert\n", format);
		return 1;
	}
	test->image_format[uniform] = format;
	image = &test->run->image[uniform];
	image->width = IMAGE_SIDE;
	image->height = IMAGE_SIDE;
	image->layers = REGION_BYTES / (IMAGE_SIDE * IMAGE_SIDE * bytes) >= 2U ? 2U : 1U;
	if (kind == GSI1_KIND_TEXEL_BUFFER) {
		image->width = REGION_BYTES / bytes;
		image->height = 1U;
		image->layers = 1U;
	}
	test->image_layers[uniform] = image->layers;
	texels = image->width * image->height * image->layers;
	image->texels = calloc(4U * texels, sizeof(uint32_t));
	if (image->texels == NULL)
		return 1;
	memory = (uint8_t *)&test->data[region];
	for (index = 0U; index < texels; index++)
		unpack_texel(format, memory + bytes * index, &image->texels[4U * index]);

	/* The descriptor. */
	test->data[bank] = MODEL_DATA_BASE + 4U * region;
	if (kind == GSI1_KIND_TEXEL_BUFFER) {
		test->data[bank + 1U] = image->width;
	} else if (kind == GSI1_KIND_INPUT_ATTACHMENT) {
		test->data[bank + 1U] = IMAGE_SIDE * bytes;
		test->data[bank + 2U] = 1U | (bytes << 8);
	} else {
		test->data[bank + 1U] = IMAGE_SIDE * bytes;
		test->data[bank + 2U] = IMAGE_SIDE | (IMAGE_SIDE << 16);
		test->data[bank + 3U] = image->layers;
		test->data[bank + 4U] = IMAGE_SIDE * IMAGE_SIDE * bytes;
	}
	return 0;
}

/* The bytes of a texel of the formats the test converts; 0 for others. */
static uint32_t
format_bytes(
	uint32_t format)
{
	switch (format) {
	case 37U:
	case 41U:
	case 98U:
	case 99U:
	case 100U:
		return 4U;
	case 97U:
		return 8U;
	case 109U:
	case 107U:
		return 16U;
	default:
		return 0U;
	}
}

/* Unpacks a texel into the IR's four words. */
static void
unpack_texel(
	uint32_t format,
	const uint8_t *bytes,
	uint32_t *texel)
{
	uint32_t word;
	uint32_t channel;
	uint16_t half;

	texel[0] = 0U;
	texel[1] = 0U;
	texel[2] = 0U;
	texel[3] = as_bits(1.0f);
	if (format == 37U || format == 41U) {
		for (channel = 0U; channel < 4U; channel++) {
			texel[channel] = bytes[channel];
			if (format == 37U)
				texel[channel] = as_bits((float)bytes[channel] / 255.0f);
		}
		return;
	}
	if (format == 98U || format == 99U || format == 100U) {
		memcpy(&word, bytes, 4U);
		texel[0] = word;
		if (format != 100U)
			texel[3] = 1U;
		return;
	}
	if (format == 97U) {
		for (channel = 0U; channel < 4U; channel++) {
			memcpy(&half, bytes + 2U * channel, 2U);
			texel[channel] = as_bits(ref_half_value(half));
		}
		return;
	}
	for (channel = 0U; channel < 4U; channel++)
		memcpy(&texel[channel], bytes + 4U * channel, 4U);
}

/* Packs the IR's four words into a texel of the format, as Vulkan converts. */
static void
pack_texel(
	uint32_t format,
	const uint32_t *texel,
	uint8_t *bytes)
{
	uint32_t channel;
	uint16_t half;
	float value;

	if (format == 37U || format == 41U) {
		for (channel = 0U; channel < 4U; channel++) {
			if (format == 41U) {
				bytes[channel] = (uint8_t)texel[channel];
				continue;
			}
			value = as_float(texel[channel]);
			if (!(value > 0.0f))
				value = 0.0f;
			if (value > 1.0f)
				value = 1.0f;
			value = value * 255.0f;
			bytes[channel] = (uint8_t)nearbyintf(value);
		}
		return;
	}
	if (format == 98U || format == 99U || format == 100U) {
		memcpy(bytes, &texel[0], 4U);
		return;
	}
	if (format == 97U) {
		for (channel = 0U; channel < 4U; channel++) {
			half = (uint16_t)ref_half_bits(as_float(texel[channel]));
			memcpy(bytes + 2U * channel, &half, 2U);
		}
		return;
	}
	for (channel = 0U; channel < 4U; channel++)
		memcpy(bytes + 4U * channel, &texel[channel], 4U);
}

/* Writes the reference's images into a memory image, packed, and marks their words to compare. */
static void
store_images(
	struct test_case *test,
	uint32_t *memory)
{
	struct ref_image *image;
	uint32_t uniform;
	uint32_t bytes;
	uint32_t texels;
	uint32_t index;
	uint32_t word;

	for (uniform = 0U; uniform < test->ir->uniform_count && uniform < REF_UNIFORMS; uniform++) {
		image = &test->run->image[uniform];
		if (image->texels == NULL)
			continue;
		if (test->ir->uniforms[uniform].kind == DRV_GPU_IR_UNIFORM_INPUT_ATTACHMENT)
			continue;
		bytes = format_bytes(test->image_format[uniform]);
		texels = image->width * image->height * image->layers;
		for (index = 0U; index < texels; index++)
			pack_texel(test->image_format[uniform], &image->texels[4U * index],
				   (uint8_t *)&memory[test->region_of[uniform]] + bytes * index);
		for (word = 0U; word < (texels * bytes + 3U) / 4U; word++)
			test->compare[test->region_of[uniform] + word] = 1U;
	}
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
