/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_ir.h: the back end's intermediate form.  A program is one list of
 * GSI1 instructions in final order, with labels for the branches.  A
 * register operand is a virtual value until gsi1_ra() gives it one of
 * r0..r62; the operands 64..127 (c0..c31 and the special operands of
 * ghci.md 12.3) are physical from the start.  Every instruction carries
 * its encoding fields (major opcode, funct3, funct7, the word-1 bits), so
 * the encoder needs no table of its own.
 */

#ifndef GSI1_IR_H
#define GSI1_IR_H

#include <stdbool.h>
#include <stdint.h>

#include "util/u_dynarray.h"

#include "gsi1.h"

/* A reference to an operand: below 128 a physical operand number, from
 * GSI1_VALUE_BASE a virtual value, GSI1_NONE none. */
#define GSI1_VALUE_BASE 0x100u
#define GSI1_NONE       0xffffffffu

static inline bool
gsi1_is_value(uint32_t ref)
{
   return ref != GSI1_NONE && ref >= GSI1_VALUE_BASE;
}

/* The instruction forms of ghci.md 12.4. */
enum gsi1_form {
   GSI1_FORM_R,
   GSI1_FORM_R4,
   GSI1_FORM_I,
   GSI1_FORM_S,
   GSI1_FORM_B,
   GSI1_FORM_U,      /* movi */
   GSI1_FORM_SHIFT,  /* the I-form shifts: amount and funct7 in imm */
   GSI1_FORM_LABEL,  /* not an instruction: a branch target */
};

struct gsi1_instr {
   enum gsi1_form form;
   uint8_t opcode;
   uint8_t funct3;
   uint8_t funct7;
   /* R-form instructions without rs2 (fsqrt, fcvt, ...) put a fixed
    * value there; the others GSI1_NONE in srcs[1]. */
   uint32_t dst;
   uint32_t srcs[3];
   /* I, S, U and shift immediates; for a branch, its target label. */
   int32_t imm;
   /* word1 bits other than the register high bits and the immediate:
    * source modifiers, sat, hsel, sub. */
   uint32_t w1;
};

struct gsi1_program {
   struct util_dynarray instrs;  /* struct gsi1_instr */
   uint32_t value_count;
   unsigned label_count;

   /* Values whose register is fixed (the registers the vertex fetcher or
    * the rasterizer fills before the program starts): value -> register,
    * or -1. */
   struct util_dynarray fixed;   /* int8_t, by value - GSI1_VALUE_BASE */

   /* Loops, as instruction ranges [first, last], for the live ranges. */
   struct util_dynarray loops;   /* struct gsi1_loop_range */
};

struct gsi1_loop_range {
   unsigned first;
   unsigned last;
};

static inline unsigned
gsi1_instr_count(const struct gsi1_program *p)
{
   return util_dynarray_num_elements(&p->instrs, struct gsi1_instr);
}

static inline struct gsi1_instr *
gsi1_instr_at(struct gsi1_program *p, unsigned i)
{
   return util_dynarray_element(&p->instrs, struct gsi1_instr, i);
}

/* gsi1_ra.c: replaces every value with a register; returns the number of
 * registers used, or 0 when the program does not fit max_regs. */
unsigned gsi1_ra(struct gsi1_program *p, unsigned max_regs);

/* gsi1_encode.c: the 64-bit instructions of a program after gsi1_ra(). */
uint64_t *gsi1_encode(const struct gsi1_program *p, unsigned *count);

#endif /* GSI1_IR_H */
