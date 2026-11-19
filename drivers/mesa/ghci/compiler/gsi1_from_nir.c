/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_from_nir.c: GSI1 instruction selection from lowered NIR
 * (gsi1_lower_nir()), then register allocation and encoding.
 *
 * Values.  Every scalar of a NIR def is a reference: a virtual value, or a
 * physical operand (c0..c31, the special operands, ghci.md 12.3) when the
 * def is one, as a constant 0, 1.0 or a workgroup ID is.  A NIR Boolean is
 * a 32-bit word that is all ones or zero, which is what the GSI1 compares
 * write and what sel needs.
 *
 * Control flow (ghci.md 12.2: branches are per warp and the hardware does
 * not reconverge).  Every if is divergent:
 *
 *      s = exec.save; exec.and c; bexz else
 *      then ...
 *   else:
 *      exec.set s; exec.and !c; bexz end
 *      else ...
 *   end:
 *      exec.set s
 *
 * A loop keeps the lanes it started with in s, and two lane flags: live
 * (cleared by break) and cont (cleared by continue); an if inside a loop
 * masks EXEC with them again when it restores EXEC, so that a lane that
 * left stays out.  The loop repeats while a live lane is left.
 *
 * The approach and the I/O conventions follow the GSI1 compiler of zedBSD
 * (src/drivers/gpu/ghci/compiler, Zlib, same author), rewritten on NIR.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "amaterrace/gsi1_isa.h"
#include "compiler/nir/nir.h"
#include "util/u_math.h"

#include "gsi1_ir.h"

struct gsi1_loop {
   struct gsi1_loop *outer;
   uint32_t live;
   uint32_t cont;
   bool has_continue;
};

struct ctx {
   nir_shader *nir;
   const struct gsi1_compile_options *o;
   struct gsi1_program p;
   struct gsi1_shader_info *info;

   /* NIR def index -> the references of its components. */
   uint32_t *defs;
   /* NIR barycentric defs: 0 none, 1 pixel, 2 centroid. */
   uint8_t *bary;

   struct gsi1_loop *loop;

   /* Registers the hardware fills before the start: register -> value. */
   uint32_t fixed_values[GSI1_MAX_REGS];

   /* Vertex attributes: the first register and the components. */
   uint8_t attr_base[16];
   uint8_t attr_comps[16];

   bool wrote_sample_mask;
   char *error;
};

static void PRINTFLIKE(2, 3)
fail(struct ctx *c, const char *fmt, ...)
{
   if (c->error)
      return;
   va_list ap;
   va_start(ap, fmt);
   if (vasprintf(&c->error, fmt, ap) < 0)
      c->error = NULL;
   va_end(ap);
   if (!c->error)
      c->error = strdup("gsi1: error");
}

/* Instructions --------------------------------------------------------- */

static uint32_t
new_value(struct ctx *c)
{
   int8_t none = -1;
   util_dynarray_append_typed(&c->p.fixed, int8_t, none);
   return GSI1_VALUE_BASE + c->p.value_count++;
}

static uint32_t
fixed_value(struct ctx *c, unsigned reg)
{
   if (c->fixed_values[reg] == GSI1_NONE) {
      uint32_t v = new_value(c);
      *util_dynarray_element(&c->p.fixed, int8_t, v - GSI1_VALUE_BASE) = reg;
      c->fixed_values[reg] = v;
   }
   return c->fixed_values[reg];
}

static void
emit(struct ctx *c, struct gsi1_instr in)
{
   util_dynarray_append_typed(&c->p.instrs, struct gsi1_instr, in);
}

static void
emit_r(struct ctx *c, unsigned opcode, unsigned f3, unsigned f7, uint32_t d,
       uint32_t a, uint32_t b, uint32_t w1)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_R, .opcode = opcode, .funct3 = f3, .funct7 = f7,
      .dst = d, .srcs = { a, b, GSI1_NONE }, .w1 = w1,
   });
}

static void
emit_r4(struct ctx *c, unsigned opcode, unsigned f3, uint32_t d, uint32_t a,
        uint32_t b, uint32_t s3, uint32_t w1)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_R4, .opcode = opcode, .funct3 = f3,
      .dst = d, .srcs = { a, b, s3 }, .w1 = w1,
   });
}

static void
emit_i(struct ctx *c, unsigned opcode, unsigned f3, uint32_t d, uint32_t a,
       int32_t imm, uint32_t w1)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_I, .opcode = opcode, .funct3 = f3,
      .dst = d, .srcs = { a, GSI1_NONE, GSI1_NONE }, .imm = imm, .w1 = w1,
   });
}

static void
emit_s(struct ctx *c, unsigned opcode, unsigned f3, uint32_t base,
       uint32_t value, int32_t imm, uint32_t w1)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_S, .opcode = opcode, .funct3 = f3,
      .dst = GSI1_NONE, .srcs = { base, value, GSI1_NONE }, .imm = imm,
      .w1 = w1,
   });
}

static unsigned
new_label(struct ctx *c)
{
   return c->p.label_count++;
}

static void
emit_label(struct ctx *c, unsigned label)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_LABEL, .dst = GSI1_NONE,
      .srcs = { GSI1_NONE, GSI1_NONE, GSI1_NONE }, .imm = label,
   });
}

static void
emit_branch(struct ctx *c, unsigned f3, uint32_t cond, unsigned label)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_B, .opcode = GSI1_OP_BRANCH, .funct3 = f3,
      .dst = GSI1_NONE, .srcs = { cond, GSI1_NONE, GSI1_NONE },
      .imm = label,
   });
}

#define SUB(s) ((uint32_t)(s) << GSI1_W1_SUB_SHIFT)

/* custom-3 with funct3 and sub (exec.*, kill, transcendentals, sel). */
static void
emit_c3(struct ctx *c, unsigned f3, unsigned sub, uint32_t d, uint32_t a)
{
   emit_r(c, GSI1_OP_CUSTOM3, f3, 0, d, a, GSI1_NONE, SUB(sub));
}

static void
emit_exec(struct ctx *c, unsigned sub, uint32_t a)
{
   emit_c3(c, 1, sub, GSI1_NONE, a);
}

enum { EXEC_SET = 0, EXEC_AND = 1, EXEC_OR = 2, EXEC_SAVE = 3 };

static void
emit_mov(struct ctx *c, uint32_t d, uint32_t a)
{
   emit_i(c, GSI1_OP_OPIMM, GSI1_F3_ADD, d, a, 0, 0);
}

static uint32_t
special_for(uint32_t bits)
{
   switch (bits) {
   case 0x00000000: return GSI1_ZERO;
   case 0x3f800000: return GSI1_ONE;
   case 0x00000001: return GSI1_ONEI;
   case 0x3f000000: return GSI1_HALF;
   case 0x40000000: return GSI1_TWO;
   case 0xbf800000: return GSI1_MONE;
   default: return GSI1_NONE;
   }
}

static uint32_t
imm32(struct ctx *c, uint32_t bits)
{
   uint32_t s = special_for(bits);
   if (s != GSI1_NONE)
      return s;
   uint32_t v = new_value(c);
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_U, .opcode = GSI1_OP_LUI, .dst = v,
      .srcs = { GSI1_NONE, GSI1_NONE, GSI1_NONE }, .imm = (int32_t)bits,
   });
   return v;
}

/* References ------------------------------------------------------------ */

static uint32_t *
def_refs(struct ctx *c, const nir_def *def)
{
   return &c->defs[def->index * NIR_MAX_VEC_COMPONENTS];
}

static uint32_t
src_ref(struct ctx *c, nir_src src, unsigned comp)
{
   uint32_t r = def_refs(c, src.ssa)[comp];
   if (r == GSI1_NONE)
      fail(c, "gsi1: a source without a value");
   return r;
}

static uint32_t
alu_src(struct ctx *c, const nir_alu_instr *alu, unsigned i)
{
   return src_ref(c, alu->src[i].src, alu->src[i].swizzle[0]);
}

/* Each component of a def gets a new value. */
static uint32_t
def_value(struct ctx *c, const nir_def *def, unsigned comp)
{
   uint32_t v = new_value(c);
   def_refs(c, def)[comp] = v;
   return v;
}

/* ALU ------------------------------------------------------------------ */

static void
emit_op(struct ctx *c, unsigned f3, unsigned f7, uint32_t d, uint32_t a,
        uint32_t b)
{
   emit_r(c, GSI1_OP_OP, f3, f7, d, a, b, 0);
}

static void
emit_fp(struct ctx *c, unsigned f7, unsigned f3, uint32_t d, uint32_t a,
        uint32_t b, uint32_t w1)
{
   emit_r(c, GSI1_OP_OPFP, f3, f7, d, a, b, w1);
}

/* rm 0: round to nearest even (ghci.md 12.7). */
#define RM_RNE 0
#define RM_RTZ 1
#define RM_RDN 2
#define RM_RUP 3

static void
emit_not(struct ctx *c, uint32_t d, uint32_t a)
{
   emit_i(c, GSI1_OP_OPIMM, GSI1_F3_XOR, d, a, -1, 0);
}

static void
emit_alu(struct ctx *c, nir_alu_instr *alu)
{
   const nir_def *def = &alu->def;
   const unsigned bits = def->bit_size;

   switch (alu->op) {
   case nir_op_vec2:
   case nir_op_vec3:
   case nir_op_vec4:
      for (unsigned i = 0; i < def->num_components; i++)
         def_refs(c, def)[i] = alu_src(c, alu, i);
      return;
   default:
      break;
   }

   if (def->num_components != 1) {
      fail(c, "gsi1: vector %s", nir_op_infos[alu->op].name);
      return;
   }
   if (bits != 32 && bits != 1) {
      fail(c, "gsi1: %u-bit %s", bits, nir_op_infos[alu->op].name);
      return;
   }
   for (unsigned i = 0; i < nir_op_infos[alu->op].num_inputs; i++) {
      unsigned sb = alu->src[i].src.ssa->bit_size;
      if (sb != 32 && sb != 1) {
         fail(c, "gsi1: %s with a %u-bit source", nir_op_infos[alu->op].name,
              sb);
         return;
      }
   }

   uint32_t a = nir_op_infos[alu->op].num_inputs > 0 ? alu_src(c, alu, 0)
                                                      : GSI1_NONE;
   uint32_t b = nir_op_infos[alu->op].num_inputs > 1 ? alu_src(c, alu, 1)
                                                      : GSI1_NONE;
   uint32_t s3 = nir_op_infos[alu->op].num_inputs > 2 ? alu_src(c, alu, 2)
                                                       : GSI1_NONE;

   /* Copies of a reference need no instruction. */
   switch (alu->op) {
   case nir_op_mov:
   case nir_op_i2i32:
   case nir_op_u2u32:
   case nir_op_f2f32:
   case nir_op_b2b1:
   case nir_op_b2b32:
      def_refs(c, def)[0] = a;
      return;
   default:
      break;
   }

   uint32_t d = def_value(c, def, 0);
   uint32_t t;

   switch (alu->op) {
   case nir_op_iadd: emit_op(c, GSI1_F3_ADD, 0, d, a, b); break;
   case nir_op_isub: emit_op(c, GSI1_F3_ADD, GSI1_F7_ALT, d, a, b); break;
   case nir_op_ineg: emit_op(c, GSI1_F3_ADD, GSI1_F7_ALT, d, GSI1_ZERO, a); break;
   case nir_op_iabs:
      t = new_value(c);
      emit_op(c, GSI1_F3_ADD, GSI1_F7_ALT, t, GSI1_ZERO, a);
      emit_op(c, GSI1_F3_MAX, GSI1_F7_MINMAX, d, a, t);
      break;
   case nir_op_imul: emit_op(c, GSI1_F3_MUL, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_imul_high: emit_op(c, GSI1_F3_MULH, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_umul_high: emit_op(c, GSI1_F3_MULHU, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_idiv: emit_op(c, GSI1_F3_DIV, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_udiv: emit_op(c, GSI1_F3_DIVU, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_irem: emit_op(c, GSI1_F3_REM, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_umod: emit_op(c, GSI1_F3_REMU, GSI1_F7_MULDIV, d, a, b); break;
   case nir_op_imin: emit_op(c, GSI1_F3_MIN, GSI1_F7_MINMAX, d, a, b); break;
   case nir_op_imax: emit_op(c, GSI1_F3_MAX, GSI1_F7_MINMAX, d, a, b); break;
   case nir_op_umin: emit_op(c, GSI1_F3_MINU, GSI1_F7_MINMAX, d, a, b); break;
   case nir_op_umax: emit_op(c, GSI1_F3_MAXU, GSI1_F7_MINMAX, d, a, b); break;
   case nir_op_iand: emit_op(c, GSI1_F3_AND, 0, d, a, b); break;
   case nir_op_ior: emit_op(c, GSI1_F3_OR, 0, d, a, b); break;
   case nir_op_ixor: emit_op(c, GSI1_F3_XOR, 0, d, a, b); break;
   case nir_op_inot: emit_not(c, d, a); break;
   case nir_op_ishl: emit_op(c, GSI1_F3_SLL, 0, d, a, b); break;
   case nir_op_ishr: emit_op(c, GSI1_F3_SRL, GSI1_F7_ALT, d, a, b); break;
   case nir_op_ushr: emit_op(c, GSI1_F3_SRL, 0, d, a, b); break;

   /* Compares write all ones or zero (ghci.md 12.2). */
   case nir_op_ilt: emit_op(c, GSI1_F3_SLT, 0, d, a, b); break;
   case nir_op_ult: emit_op(c, GSI1_F3_SLTU, 0, d, a, b); break;
   case nir_op_ige:
      t = new_value(c);
      emit_op(c, GSI1_F3_SLT, 0, t, a, b);
      emit_not(c, d, t);
      break;
   case nir_op_uge:
      t = new_value(c);
      emit_op(c, GSI1_F3_SLTU, 0, t, a, b);
      emit_not(c, d, t);
      break;
   case nir_op_ine:
      t = new_value(c);
      emit_op(c, GSI1_F3_XOR, 0, t, a, b);
      emit_op(c, GSI1_F3_SLTU, 0, d, GSI1_ZERO, t);
      break;
   case nir_op_ieq: {
      t = new_value(c);
      uint32_t ne = new_value(c);
      emit_op(c, GSI1_F3_XOR, 0, t, a, b);
      emit_op(c, GSI1_F3_SLTU, 0, ne, GSI1_ZERO, t);
      emit_not(c, d, ne);
      break;
   }

   case nir_op_fadd: emit_fp(c, GSI1_F7_FADD, RM_RNE, d, a, b, 0); break;
   case nir_op_fsub: emit_fp(c, GSI1_F7_FSUB, RM_RNE, d, a, b, 0); break;
   case nir_op_fmul: emit_fp(c, GSI1_F7_FMUL, RM_RNE, d, a, b, 0); break;
   case nir_op_fmin: emit_fp(c, GSI1_F7_FMINMAX, 0, d, a, b, 0); break;
   case nir_op_fmax: emit_fp(c, GSI1_F7_FMINMAX, 1, d, a, b, 0); break;
   case nir_op_fneg:
      /* The sign of -a, the magnitude of a. */
      emit_fp(c, GSI1_F7_FSGNJ, 0, d, a, a, GSI1_W1_N2);
      break;
   case nir_op_fabs:
      emit_fp(c, GSI1_F7_FSGNJ, 0, d, a, GSI1_ZERO, 0);
      break;
   case nir_op_fsat:
      emit_fp(c, GSI1_F7_FADD, RM_RNE, d, a, GSI1_ZERO, GSI1_W1_SAT);
      break;
   case nir_op_ffma:
      emit_r4(c, GSI1_OP_MADD, RM_RNE, d, a, b, s3, 0);
      break;
   case nir_op_fsqrt:
      emit_fp(c, GSI1_F7_FSQRT, RM_RNE, d, a, 0, 0);
      break;
   case nir_op_frcp: emit_c3(c, 3, 0, d, a); break;
   case nir_op_frsq: emit_c3(c, 3, 1, d, a); break;
   case nir_op_fexp2: emit_c3(c, 3, 2, d, a); break;
   case nir_op_flog2: emit_c3(c, 3, 3, d, a); break;
   case nir_op_fsin: emit_c3(c, 3, 4, d, a); break;
   case nir_op_fcos: emit_c3(c, 3, 5, d, a); break;
   case nir_op_ffract: emit_c3(c, 3, 6, d, a); break;
   case nir_op_ffloor:
      emit_fp(c, GSI1_F7_FROUND, RM_RDN, d, a, GSI1_RS2_FROUND, 0);
      break;
   case nir_op_fceil:
      emit_fp(c, GSI1_F7_FROUND, RM_RUP, d, a, GSI1_RS2_FROUND, 0);
      break;
   case nir_op_ftrunc:
      emit_fp(c, GSI1_F7_FROUND, RM_RTZ, d, a, GSI1_RS2_FROUND, 0);
      break;
   case nir_op_fround_even:
      emit_fp(c, GSI1_F7_FROUND, RM_RNE, d, a, GSI1_RS2_FROUND, 0);
      break;
   case nir_op_f2i32: emit_fp(c, GSI1_F7_FCVT_W_S, RM_RTZ, d, a, 0, 0); break;
   case nir_op_f2u32: emit_fp(c, GSI1_F7_FCVT_W_S, RM_RTZ, d, a, 1, 0); break;
   case nir_op_i2f32: emit_fp(c, GSI1_F7_FCVT_S_W, RM_RNE, d, a, 0, 0); break;
   case nir_op_u2f32: emit_fp(c, GSI1_F7_FCVT_S_W, RM_RNE, d, a, 1, 0); break;

   case nir_op_feq: emit_fp(c, GSI1_F7_FCMP, 2, d, a, b, 0); break;
   case nir_op_fneu: emit_fp(c, GSI1_F7_FCMP, 3, d, a, b, 0); break;
   case nir_op_flt: emit_fp(c, GSI1_F7_FCMP, 1, d, a, b, 0); break;
   case nir_op_fge: emit_fp(c, GSI1_F7_FCMP, 0, d, b, a, 0); break;

   case nir_op_bcsel:
      /* sel: (a & b) | (~a & c), bitwise. */
      emit_r4(c, GSI1_OP_CUSTOM3, 0, d, a, b, s3, 0);
      break;
   case nir_op_b2f32: emit_op(c, GSI1_F3_AND, 0, d, a, GSI1_ONE); break;
   case nir_op_b2i32: emit_op(c, GSI1_F3_AND, 0, d, a, GSI1_ONEI); break;
   default:
      fail(c, "gsi1: ALU op %s", nir_op_infos[alu->op].name);
      break;
   }
}

static void
emit_load_const(struct ctx *c, nir_load_const_instr *lc)
{
   for (unsigned i = 0; i < lc->def.num_components; i++) {
      uint32_t bits;
      switch (lc->def.bit_size) {
      case 1: bits = lc->value[i].b ? ~0u : 0; break;
      case 32: bits = lc->value[i].u32; break;
      default:
         fail(c, "gsi1: %u-bit constant", lc->def.bit_size);
         return;
      }
      def_refs(c, &lc->def)[i] = imm32(c, bits);
   }
}

static void
emit_undef(struct ctx *c, nir_undef_instr *u)
{
   for (unsigned i = 0; i < u->def.num_components; i++)
      def_refs(c, &u->def)[i] = GSI1_ZERO;
}

/* I/O ------------------------------------------------------------------ */

static void
setup_attributes(struct ctx *c)
{
   uint8_t comps[16];
   bool given = false;

   memcpy(comps, c->o->attribute_components, sizeof(comps));
   for (unsigned i = 0; i < 16; i++)
      given |= comps[i] != 0;

   if (!given) {
      /* The attribute formats are not known: take the shader's types. */
      nir_foreach_function_impl(impl, c->nir) {
         nir_foreach_block(block, impl) {
            nir_foreach_instr(instr, block) {
               if (instr->type != nir_instr_type_intrinsic)
                  continue;
               nir_intrinsic_instr *intr = nir_instr_as_intrinsic(instr);
               if (intr->intrinsic != nir_intrinsic_load_input)
                  continue;
               unsigned loc = nir_intrinsic_io_semantics(intr).location -
                              VERT_ATTRIB_GENERIC0;
               unsigned need = nir_intrinsic_component(intr) +
                               intr->def.num_components;
               if (loc < 16)
                  comps[loc] = MAX2(comps[loc], need);
            }
         }
      }
   }

   unsigned base = 0;
   for (unsigned i = 0; i < 16; i++) {
      c->attr_base[i] = base;
      c->attr_comps[i] = MIN2(comps[i], 4);
      base += c->attr_comps[i];
   }
   if (base > 60)
      fail(c, "gsi1: %u attribute registers; at most 60", base);
   c->info->used_regs = MAX2(c->info->used_regs, base);
}

/* An interpolated input: b0 lda(w,0) + b1 lda(w,1) + b2 lda(w,2), with the
 * perspective-correct barycentrics the rasterizer leaves in r0..r2 (or the
 * centroid ones in r7..r9), ghci.md 12.10.3. */
static uint32_t
lda(struct ctx *c, unsigned word, unsigned vertex)
{
   uint32_t v = new_value(c);
   emit_i(c, GSI1_OP_CUSTOM1, 5, v, GSI1_NONE,
          GSI1_LDA(GSI1_PT_VARYING(word), vertex), 0);
   return v;
}

static void
emit_fs_input(struct ctx *c, nir_intrinsic_instr *intr, bool interpolated)
{
   nir_io_semantics sem = nir_intrinsic_io_semantics(intr);
   unsigned first_reg = 0;

   if (sem.location < VARYING_SLOT_VAR0 ||
       sem.location >= VARYING_SLOT_VAR0 + 16) {
      fail(c, "gsi1: fragment input %s",
           gl_varying_slot_name_for_stage(sem.location, MESA_SHADER_FRAGMENT));
      return;
   }
   if (interpolated) {
      nir_def *bary = intr->src[0].ssa;
      if (c->bary[bary->index] == 0) {
         fail(c, "gsi1: an interpolation the rasterizer does not give");
         return;
      }
      first_reg = c->bary[bary->index] == 2 ? GSI1_IN_CENTROID_B0 : GSI1_IN_B0;
   }

   unsigned loc = sem.location - VARYING_SLOT_VAR0;
   for (unsigned i = 0; i < intr->def.num_components; i++) {
      unsigned word = 4 * loc + nir_intrinsic_component(intr) + i;
      if (!interpolated) {
         /* Flat: the provoking vertex, vertex 0. */
         def_refs(c, &intr->def)[i] = lda(c, word, 0);
         continue;
      }
      uint32_t acc = new_value(c);
      emit_fp(c, GSI1_F7_FMUL, RM_RNE, acc, fixed_value(c, first_reg),
              lda(c, word, 0), 0);
      for (unsigned k = 1; k < 3; k++) {
         uint32_t n = new_value(c);
         emit_r4(c, GSI1_OP_MADD, RM_RNE, n, fixed_value(c, first_reg + k),
                 lda(c, word, k), acc, 0);
         acc = n;
      }
      def_refs(c, &intr->def)[i] = acc;
   }
}

static void
emit_exp(struct ctx *c, uint32_t value, unsigned target)
{
   emit_s(c, GSI1_OP_CUSTOM1, 4, GSI1_NONE, value, target, 0);
}

static void
emit_store_output(struct ctx *c, nir_intrinsic_instr *intr)
{
   nir_io_semantics sem = nir_intrinsic_io_semantics(intr);
   unsigned comp = nir_intrinsic_component(intr);
   unsigned mask = nir_intrinsic_write_mask(intr);
   unsigned n = intr->src[0].ssa->num_components;

   for (unsigned i = 0; i < n; i++) {
      if (!(mask & (1u << i)))
         continue;
      uint32_t v = src_ref(c, intr->src[0], i);
      unsigned cc = comp + i;
      int target = -1;

      if (c->nir->info.stage == MESA_SHADER_VERTEX) {
         if (sem.location == VARYING_SLOT_POS) {
            target = GSI1_EXP_POS(cc);
         } else if (sem.location == VARYING_SLOT_PSIZ) {
            /* The point size is fixed at 1.0 (ghci.md 12.10.3). */
            continue;
         } else if (sem.location >= VARYING_SLOT_VAR0 &&
                    sem.location < VARYING_SLOT_VAR0 + 16) {
            unsigned loc = sem.location - VARYING_SLOT_VAR0;
            target = GSI1_EXP_VARYING(4 * loc + cc);
            c->info->varying_count = MAX2(c->info->varying_count, loc + 1);
         }
      } else if (c->nir->info.stage == MESA_SHADER_FRAGMENT) {
         if (sem.location >= FRAG_RESULT_DATA0 &&
             sem.location < FRAG_RESULT_DATA0 + GSI1_COLOR_ATTACHMENTS) {
            unsigned k = sem.location - FRAG_RESULT_DATA0;
            if (sem.dual_source_blend_index)
               target = k == 0 ? (int)GSI1_EXP_COLOR0_SRC1(cc) : -1;
            else
               target = GSI1_EXP_COLOR(k, cc);
         } else if (sem.location == FRAG_RESULT_DEPTH) {
            target = GSI1_EXP_DEPTH;
            c->info->fs_depth_export = true;
         } else if (sem.location == FRAG_RESULT_SAMPLE_MASK) {
            target = GSI1_EXP_SAMPLE_MASK;
            c->wrote_sample_mask = true;
         }
      }

      if (target < 0) {
         fail(c, "gsi1: output %s",
              gl_varying_slot_name_for_stage(sem.location,
                                             c->nir->info.stage));
         return;
      }
      emit_exp(c, v, target);
   }
}

/* Memory --------------------------------------------------------------- */

static void
emit_load_global(struct ctx *c, nir_intrinsic_instr *intr)
{
   uint32_t d = def_value(c, &intr->def, 0);
   emit_i(c, GSI1_OP_LOAD, GSI1_F3_LW, d, src_ref(c, intr->src[0], 0), 0, 0);
}

static void
emit_store_global(struct ctx *c, nir_intrinsic_instr *intr)
{
   emit_s(c, GSI1_OP_STORE, GSI1_F3_SW, src_ref(c, intr->src[1], 0),
          src_ref(c, intr->src[0], 0), 0, SUB(GSI1_SW_PLAIN));
}

static void
emit_load_push_constant(struct ctx *c, nir_intrinsic_instr *intr)
{
   unsigned base = nir_intrinsic_base(intr);

   if (nir_src_is_const(intr->src[0])) {
      unsigned word = (base + nir_src_as_uint(intr->src[0])) / 4;
      if (word < GSI1_C_COUNT) {
         def_refs(c, &intr->def)[0] = GSI1_C(word);
         return;
      }
      uint32_t d = def_value(c, &intr->def, 0);
      emit_i(c, GSI1_OP_LOAD, GSI1_F3_LWC, d, GSI1_ZERO, word, 0);
      return;
   }

   /* lwc reads word rs1 + imm of the bank. */
   uint32_t idx = new_value(c);
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_SHIFT, .opcode = GSI1_OP_OPIMM, .funct3 = GSI1_F3_SRL,
      .dst = idx, .srcs = { src_ref(c, intr->src[0], 0), GSI1_NONE, GSI1_NONE },
      .imm = 2,
   });
   uint32_t d = def_value(c, &intr->def, 0);
   emit_i(c, GSI1_OP_LOAD, GSI1_F3_LWC, d, idx, base / 4, 0);
}

static void
emit_load_shared(struct ctx *c, nir_intrinsic_instr *intr)
{
   uint32_t d = def_value(c, &intr->def, 0);
   emit_i(c, GSI1_OP_CUSTOM0, 0, d, src_ref(c, intr->src[0], 0),
          nir_intrinsic_base(intr), 0);
}

static void
emit_store_shared(struct ctx *c, nir_intrinsic_instr *intr)
{
   emit_s(c, GSI1_OP_CUSTOM0, 1, src_ref(c, intr->src[1], 0),
          src_ref(c, intr->src[0], 0), nir_intrinsic_base(intr), 0);
}

static int
atomic_sub(nir_atomic_op op)
{
   /* ghci.md 12.5: the atom sub-operations. */
   switch (op) {
   case nir_atomic_op_iand: return 0;
   case nir_atomic_op_ior: return 1;
   case nir_atomic_op_ixor: return 2;
   case nir_atomic_op_xchg: return 3;
   case nir_atomic_op_iadd: return 4;
   case nir_atomic_op_isub: return 5;
   case nir_atomic_op_imax: return 6;
   case nir_atomic_op_imin: return 7;
   case nir_atomic_op_umax: return 8;
   case nir_atomic_op_umin: return 9;
   case nir_atomic_op_cmpxchg: return 10;
   default: return -1;
   }
}

static void
emit_atomic(struct ctx *c, nir_intrinsic_instr *intr, bool shared, bool swap)
{
   int sub = atomic_sub(nir_intrinsic_atomic_op(intr));
   if (sub < 0) {
      fail(c, "gsi1: atomic operation %d", nir_intrinsic_atomic_op(intr));
      return;
   }
   if (shared && nir_intrinsic_base(intr) != 0) {
      fail(c, "gsi1: a shared atomic with a base");
      return;
   }
   uint32_t d = def_value(c, &intr->def, 0);
   uint32_t addr = src_ref(c, intr->src[0], 0);
   /* cmpxchg: the new value in rs2, the compare value in rs3. */
   uint32_t data = src_ref(c, intr->src[swap ? 2 : 1], 0);
   uint32_t cmp = swap ? src_ref(c, intr->src[1], 0) : GSI1_NONE;
   emit_r4(c, GSI1_OP_CUSTOM0, 2, d, addr, data, cmp,
           SUB(sub | (shared ? 16 : 0)));
}

/* Intrinsics ------------------------------------------------------------ */

static void
set_operand(struct ctx *c, nir_intrinsic_instr *intr, const uint32_t *ops)
{
   for (unsigned i = 0; i < intr->def.num_components; i++)
      def_refs(c, &intr->def)[i] = ops[i];
}

static void emit_jump_flags(struct ctx *c, uint32_t flag);

static void
emit_intrinsic(struct ctx *c, nir_intrinsic_instr *intr)
{
   const mesa_shader_stage stage = c->nir->info.stage;

   switch (intr->intrinsic) {
   case nir_intrinsic_decl_reg: {
      if (nir_intrinsic_bit_size(intr) != 32 &&
          nir_intrinsic_bit_size(intr) != 1) {
         fail(c, "gsi1: a %u-bit register", nir_intrinsic_bit_size(intr));
         return;
      }
      for (unsigned i = 0; i < nir_intrinsic_num_components(intr); i++)
         def_refs(c, &intr->def)[i] = new_value(c);
      return;
   }
   case nir_intrinsic_load_reg:
      for (unsigned i = 0; i < intr->def.num_components; i++)
         emit_mov(c, def_value(c, &intr->def, i), src_ref(c, intr->src[0], i));
      return;
   case nir_intrinsic_store_reg: {
      unsigned mask = nir_intrinsic_write_mask(intr);
      for (unsigned i = 0; i < intr->src[0].ssa->num_components; i++)
         if (mask & (1u << i))
            emit_mov(c, src_ref(c, intr->src[1], i),
                     src_ref(c, intr->src[0], i));
      return;
   }

   case nir_intrinsic_load_input:
      if (stage == MESA_SHADER_VERTEX) {
         unsigned loc = nir_intrinsic_io_semantics(intr).location -
                        VERT_ATTRIB_GENERIC0;
         if (loc >= 16) {
            fail(c, "gsi1: vertex input %u", loc);
            return;
         }
         for (unsigned i = 0; i < intr->def.num_components; i++) {
            unsigned cc = nir_intrinsic_component(intr) + i;
            if (cc < c->attr_comps[loc])
               def_refs(c, &intr->def)[i] =
                  fixed_value(c, c->attr_base[loc] + cc);
            else
               /* What the format does not have: (0, 0, 0, 1). */
               def_refs(c, &intr->def)[i] = cc == 3 ? GSI1_ONE : GSI1_ZERO;
         }
      } else if (stage == MESA_SHADER_FRAGMENT) {
         emit_fs_input(c, intr, false);
      } else {
         fail(c, "gsi1: load_input in this stage");
      }
      return;
   case nir_intrinsic_load_interpolated_input:
      emit_fs_input(c, intr, true);
      return;
   case nir_intrinsic_load_barycentric_pixel:
   case nir_intrinsic_load_barycentric_sample:
   case nir_intrinsic_load_barycentric_centroid:
      if (nir_intrinsic_interp_mode(intr) == INTERP_MODE_NOPERSPECTIVE) {
         /* The rasterizer gives perspective-correct barycentrics only. */
         fail(c, "gsi1: noperspective interpolation");
         return;
      }
      if (intr->intrinsic == nir_intrinsic_load_barycentric_centroid) {
         c->bary[intr->def.index] = 2;
         c->info->fs_centroid = true;
      } else {
         c->bary[intr->def.index] = 1;
      }
      for (unsigned i = 0; i < intr->def.num_components; i++)
         def_refs(c, &intr->def)[i] = GSI1_ZERO;
      return;
   case nir_intrinsic_store_output:
      emit_store_output(c, intr);
      return;

   case nir_intrinsic_load_frag_coord: {
      if (nir_def_components_read(&intr->def) & 0x8) {
         fail(c, "gsi1: gl_FragCoord.w");
         return;
      }
      uint32_t ops[4] = { fixed_value(c, GSI1_IN_X), fixed_value(c, GSI1_IN_Y),
                          fixed_value(c, GSI1_IN_Z), GSI1_ONE };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_front_face: {
      uint32_t ops[1] = { GSI1_FRONT };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_sample_mask_in: {
      uint32_t ops[1] = { fixed_value(c, GSI1_IN_SAMPLE_MASK) };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_vertex_id: {
      uint32_t ops[1] = { GSI1_VTX_INDEX };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_instance_id: {
      uint32_t ops[1] = { GSI1_INST_INDEX };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_workgroup_id: {
      uint32_t ops[3] = { GSI1_WGX, GSI1_WGY, GSI1_WGZ };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_local_invocation_id: {
      uint32_t ops[3] = { GSI1_LIDX, GSI1_LIDY, GSI1_LIDZ };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_local_invocation_index: {
      uint32_t ops[1] = { GSI1_LIDN };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_num_workgroups: {
      uint32_t ops[3] = { GSI1_NWGX, GSI1_NWGY, GSI1_NWGZ };
      set_operand(c, intr, ops);
      return;
   }
   case nir_intrinsic_load_subgroup_invocation: {
      uint32_t ops[1] = { GSI1_LANE };
      set_operand(c, intr, ops);
      return;
   }

   case nir_intrinsic_load_global:
   case nir_intrinsic_load_global_constant:
      emit_load_global(c, intr);
      return;
   case nir_intrinsic_store_global:
      emit_store_global(c, intr);
      return;
   case nir_intrinsic_load_push_constant:
      emit_load_push_constant(c, intr);
      return;
   case nir_intrinsic_load_shared:
      emit_load_shared(c, intr);
      return;
   case nir_intrinsic_store_shared:
      emit_store_shared(c, intr);
      return;
   case nir_intrinsic_global_atomic:
      emit_atomic(c, intr, false, false);
      return;
   case nir_intrinsic_global_atomic_swap:
      emit_atomic(c, intr, false, true);
      return;
   case nir_intrinsic_shared_atomic:
      emit_atomic(c, intr, true, false);
      return;
   case nir_intrinsic_shared_atomic_swap:
      emit_atomic(c, intr, true, true);
      return;

   case nir_intrinsic_barrier: {
      unsigned modes = nir_intrinsic_memory_modes(intr);
      unsigned fence = 0;
      if (modes & (nir_var_mem_ssbo | nir_var_mem_global | nir_var_image))
         fence |= 1;
      if (modes & nir_var_mem_shared)
         fence |= 2;
      if (fence && (nir_intrinsic_memory_semantics(intr) & NIR_MEMORY_ACQUIRE))
         fence |= 4;
      if (fence)
         emit_i(c, GSI1_OP_CUSTOM0, 4, GSI1_NONE, GSI1_NONE, fence, 0);
      if (nir_intrinsic_execution_scope(intr) >= SCOPE_WORKGROUP &&
          stage == MESA_SHADER_COMPUTE)
         emit_r(c, GSI1_OP_CUSTOM0, 5, 0, GSI1_NONE, GSI1_NONE, GSI1_NONE, 0);
      return;
   }

   case nir_intrinsic_terminate:
   case nir_intrinsic_demote:
      c->info->fs_discard = true;
      emit_c3(c, 2, 0, GSI1_NONE, GSI1_ONEI);
      return;
   case nir_intrinsic_terminate_if:
   case nir_intrinsic_demote_if:
      c->info->fs_discard = true;
      emit_c3(c, 2, 0, GSI1_NONE, src_ref(c, intr->src[0], 0));
      return;

   default:
      fail(c, "gsi1: intrinsic %s", nir_intrinsic_infos[intr->intrinsic].name);
      return;
   }
}

/* Control flow ---------------------------------------------------------- */

static void emit_cf_list(struct ctx *c, struct exec_list *list);

/* Clears a lane flag (live or cont) for the lanes in EXEC and takes them
 * out of EXEC. */
static void
emit_jump_flags(struct ctx *c, uint32_t flag)
{
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_U, .opcode = GSI1_OP_LUI, .dst = flag,
      .srcs = { GSI1_NONE, GSI1_NONE, GSI1_NONE }, .imm = 0,
   });
   emit_exec(c, EXEC_AND, flag);
}

static void
emit_jump(struct ctx *c, nir_jump_instr *jump)
{
   if (!c->loop) {
      fail(c, "gsi1: a jump outside a loop");
      return;
   }
   switch (jump->type) {
   case nir_jump_break:
      emit_jump_flags(c, c->loop->live);
      break;
   case nir_jump_continue:
      emit_jump_flags(c, c->loop->cont);
      break;
   default:
      fail(c, "gsi1: jump type %d", jump->type);
      break;
   }
}

static void
emit_block(struct ctx *c, nir_block *block)
{
   nir_foreach_instr(instr, block) {
      if (c->error)
         return;
      switch (instr->type) {
      case nir_instr_type_alu:
         emit_alu(c, nir_instr_as_alu(instr));
         break;
      case nir_instr_type_load_const:
         emit_load_const(c, nir_instr_as_load_const(instr));
         break;
      case nir_instr_type_undef:
         emit_undef(c, nir_instr_as_undef(instr));
         break;
      case nir_instr_type_intrinsic:
         emit_intrinsic(c, nir_instr_as_intrinsic(instr));
         break;
      case nir_instr_type_jump:
         emit_jump(c, nir_instr_as_jump(instr));
         break;
      default:
         fail(c, "gsi1: NIR instruction type %d", instr->type);
         break;
      }
   }
}

/* EXEC = s, then without the lanes that left the enclosing loop. */
static void
restore_exec(struct ctx *c, uint32_t saved)
{
   emit_exec(c, EXEC_SET, saved);
   if (c->loop) {
      emit_exec(c, EXEC_AND, c->loop->live);
      if (c->loop->has_continue)
         emit_exec(c, EXEC_AND, c->loop->cont);
   }
}

static void
emit_if(struct ctx *c, nir_if *nif)
{
   uint32_t cond = src_ref(c, nif->condition, 0);
   bool has_else = !nir_cf_list_is_empty_block(&nif->else_list);
   uint32_t saved = new_value(c);
   uint32_t not_cond = GSI1_NONE;
   unsigned l_else = new_label(c);

   if (has_else) {
      not_cond = new_value(c);
      emit_not(c, not_cond, cond);
   }
   emit_c3(c, 1, EXEC_SAVE, saved, GSI1_NONE);
   emit_exec(c, EXEC_AND, cond);
   emit_branch(c, GSI1_F3_BEXZ, GSI1_NONE, l_else);
   emit_cf_list(c, &nif->then_list);
   emit_label(c, l_else);
   restore_exec(c, saved);

   if (has_else) {
      unsigned l_end = new_label(c);
      emit_exec(c, EXEC_AND, not_cond);
      emit_branch(c, GSI1_F3_BEXZ, GSI1_NONE, l_end);
      emit_cf_list(c, &nif->else_list);
      emit_label(c, l_end);
      restore_exec(c, saved);
   }
}

static bool
list_has_continue(struct exec_list *list)
{
   foreach_list_typed(nir_cf_node, node, node, list) {
      switch (node->type) {
      case nir_cf_node_block:
         nir_foreach_instr(instr, nir_cf_node_as_block(node)) {
            if (instr->type == nir_instr_type_jump &&
                nir_instr_as_jump(instr)->type == nir_jump_continue)
               return true;
         }
         break;
      case nir_cf_node_if: {
         nir_if *nif = nir_cf_node_as_if(node);
         if (list_has_continue(&nif->then_list) ||
             list_has_continue(&nif->else_list))
            return true;
         break;
      }
      default:
         /* A nested loop's continues are its own. */
         break;
      }
   }
   return false;
}

static void
emit_loop(struct ctx *c, nir_loop *nloop)
{
   struct gsi1_loop loop = {
      .outer = c->loop,
      .live = new_value(c),
      .cont = new_value(c),
      .has_continue = list_has_continue(&nloop->body),
   };
   uint32_t saved = new_value(c);
   unsigned l_top = new_label(c);
   unsigned first = gsi1_instr_count(&c->p);

   if (nir_loop_has_continue_construct(nloop)) {
      fail(c, "gsi1: a loop continue construct");
      return;
   }

   emit_c3(c, 1, EXEC_SAVE, saved, GSI1_NONE);
   emit(c, (struct gsi1_instr) {
      .form = GSI1_FORM_U, .opcode = GSI1_OP_LUI, .dst = loop.live,
      .srcs = { GSI1_NONE, GSI1_NONE, GSI1_NONE }, .imm = -1,
   });
   emit_label(c, l_top);
   if (loop.has_continue)
      emit(c, (struct gsi1_instr) {
         .form = GSI1_FORM_U, .opcode = GSI1_OP_LUI, .dst = loop.cont,
         .srcs = { GSI1_NONE, GSI1_NONE, GSI1_NONE }, .imm = -1,
      });

   c->loop = &loop;
   emit_cf_list(c, &nloop->body);
   c->loop = loop.outer;

   /* The lanes still in the loop go round again. */
   emit_exec(c, EXEC_SET, saved);
   emit_exec(c, EXEC_AND, loop.live);
   emit_branch(c, GSI1_F3_BEXNZ, GSI1_NONE, l_top);
   unsigned last = gsi1_instr_count(&c->p) - 1;
   emit_exec(c, EXEC_SET, saved);

   struct gsi1_loop_range range = { first, last };
   util_dynarray_append_typed(&c->p.loops, struct gsi1_loop_range, range);
}

static void
emit_cf_list(struct ctx *c, struct exec_list *list)
{
   foreach_list_typed(nir_cf_node, node, node, list) {
      if (c->error)
         return;
      switch (node->type) {
      case nir_cf_node_block:
         emit_block(c, nir_cf_node_as_block(node));
         break;
      case nir_cf_node_if:
         emit_if(c, nir_cf_node_as_if(node));
         break;
      case nir_cf_node_loop:
         emit_loop(c, nir_cf_node_as_loop(node));
         break;
      default:
         fail(c, "gsi1: control flow node %d", node->type);
         break;
      }
   }
}

/* The program ----------------------------------------------------------- */

bool
gsi1_compile(nir_shader *nir, const struct gsi1_compile_options *options,
             struct gsi1_binary *binary, char **error)
{
   nir_function_impl *impl = nir_shader_get_entrypoint(nir);
   struct ctx c = {
      .nir = nir,
      .o = options,
      .info = &binary->info,
   };
   const unsigned max_regs =
      MIN2(options->max_regs ? options->max_regs : 32, GSI1_MAX_REGS);
   bool ok = false;

   memset(binary, 0, sizeof(*binary));
   binary->info.stage = nir->info.stage;
   for (unsigned i = 0; i < GSI1_MAX_REGS; i++)
      c.fixed_values[i] = GSI1_NONE;

   util_dynarray_init(&c.p.instrs, NULL);
   util_dynarray_init(&c.p.fixed, NULL);
   util_dynarray_init(&c.p.loops, NULL);

   nir_index_ssa_defs(impl);
   c.defs = malloc(sizeof(*c.defs) * NIR_MAX_VEC_COMPONENTS *
                   MAX2(impl->ssa_alloc, 1));
   c.bary = calloc(MAX2(impl->ssa_alloc, 1), 1);
   if (!c.defs || !c.bary) {
      fail(&c, "gsi1: out of memory");
      goto out;
   }
   for (unsigned i = 0; i < NIR_MAX_VEC_COMPONENTS * impl->ssa_alloc; i++)
      c.defs[i] = GSI1_NONE;

   if (nir->info.stage == MESA_SHADER_VERTEX)
      setup_attributes(&c);
   if (nir->info.stage == MESA_SHADER_COMPUTE) {
      for (unsigned i = 0; i < 3; i++)
         binary->info.local_size[i] = nir->info.workgroup_size[i];
      binary->info.lds_bytes = nir->info.shared_size;
   }

   emit_cf_list(&c, &impl->body);

   if (nir->info.stage == MESA_SHADER_FRAGMENT && !c.wrote_sample_mask) {
      /* Every fragment shader exports a sample mask (ghci.md 12.10.3);
       * the rasterizer's coverage ANDs it. */
      emit_exp(&c, imm32(&c, ~0u), GSI1_EXP_SAMPLE_MASK);
   }
   emit_r(&c, GSI1_OP_CUSTOM0, 7, 0, GSI1_NONE, GSI1_NONE, GSI1_NONE, 0);

   if (c.error)
      goto out;

   unsigned regs = gsi1_ra(&c.p, max_regs);
   if (!regs) {
      fail(&c, "gsi1: the program needs more than %u registers "
               "(there is no spilling yet)", max_regs);
      goto out;
   }
   binary->info.used_regs = MAX2(binary->info.used_regs, regs);

   binary->code = gsi1_encode(&c.p, &binary->info.instr_count);
   if (!binary->code) {
      fail(&c, "gsi1: out of memory");
      goto out;
   }
   ok = true;

out:
   if (error)
      *error = c.error;
   else
      free(c.error);
   free(c.defs);
   free(c.bary);
   util_dynarray_fini(&c.p.instrs);
   util_dynarray_fini(&c.p.fixed);
   util_dynarray_fini(&c.p.loops);
   return ok;
}

void
gsi1_binary_finish(struct gsi1_binary *binary)
{
   free(binary->code);
   binary->code = NULL;
}
