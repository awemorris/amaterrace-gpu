/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_encode.c: the 64-bit GSI1 instructions of a program (ghci.md 12.4).
 * word0 is the RISC-V layout of the instruction's form; word1 holds the
 * high two bits of each register operand, the source modifiers, sat, hsel,
 * sub and the high part of the immediate.  Branch offsets count
 * instructions.
 *
 * The field placement follows the GSI1 encoder of zedBSD
 * (src/drivers/gpu/ghci/compiler/gsi1-encode.c, Zlib, same author) and is
 * checked against mk/gsi1asm.py.
 */

#include <assert.h>
#include <stdlib.h>

#include "util/macros.h"

#include "amaterrace/gsi1_isa.h"

#include "gsi1_ir.h"

static uint32_t
reg_lo(uint32_t r)
{
   return r == GSI1_NONE ? 0 : r & 0x1f;
}

static uint32_t
reg_hi(uint32_t r)
{
   return r == GSI1_NONE ? 0 : (r >> 5) & 0x3;
}

/* An I, S or B immediate: sext(imm[11:0]) + (sext(imm_hi[9:0]) << 12). */
static void
split_imm(int32_t imm, uint32_t *lo, uint32_t *hi)
{
   int32_t l = imm & 0xfff;

   if (l >= 0x800)
      l -= 0x1000;
   *lo = (uint32_t)l & 0xfff;
   *hi = (uint32_t)((imm - l) / 0x1000) & 0x3ff;
}

static uint64_t
encode_one(const struct gsi1_instr *in, int32_t branch_offset)
{
   const uint32_t rd = in->dst, rs1 = in->srcs[0], rs2 = in->srcs[1],
                  rs3 = in->srcs[2];
   uint32_t w0 = in->opcode & 0x7f;
   uint32_t w1 = reg_hi(rd) << GSI1_W1_RD_SHIFT |
                 reg_hi(rs1) << GSI1_W1_RS1_SHIFT |
                 reg_hi(rs2) << GSI1_W1_RS2_SHIFT | in->w1;
   uint32_t lo, hi;

   switch (in->form) {
   case GSI1_FORM_R:
      w0 |= reg_lo(rd) << GSI1_W0_RD_SHIFT | (uint32_t)in->funct3 << 12 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT |
            reg_lo(rs2) << GSI1_W0_RS2_SHIFT |
            (uint32_t)in->funct7 << GSI1_W0_FUNCT7_SHIFT;
      break;
   case GSI1_FORM_R4:
      w0 |= reg_lo(rd) << GSI1_W0_RD_SHIFT | (uint32_t)in->funct3 << 12 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT |
            reg_lo(rs2) << GSI1_W0_RS2_SHIFT |
            reg_lo(rs3) << GSI1_W0_RS3_SHIFT;
      w1 |= reg_hi(rs3) << GSI1_W1_RS3_SHIFT;
      break;
   case GSI1_FORM_I:
      split_imm(in->imm, &lo, &hi);
      w0 |= reg_lo(rd) << GSI1_W0_RD_SHIFT | (uint32_t)in->funct3 << 12 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT | lo << GSI1_W0_IMM_SHIFT;
      w1 |= hi << GSI1_W1_IMM_HI_SHIFT;
      break;
   case GSI1_FORM_SHIFT:
      w0 |= reg_lo(rd) << GSI1_W0_RD_SHIFT | (uint32_t)in->funct3 << 12 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT |
            (((uint32_t)in->imm & 0x1f) | (uint32_t)in->funct7 << 5)
               << GSI1_W0_IMM_SHIFT;
      break;
   case GSI1_FORM_S:
      split_imm(in->imm, &lo, &hi);
      w0 |= (lo & 0x1f) << GSI1_W0_RD_SHIFT | (uint32_t)in->funct3 << 12 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT |
            reg_lo(rs2) << GSI1_W0_RS2_SHIFT | (lo >> 5) << 25;
      w1 |= hi << GSI1_W1_IMM_HI_SHIFT;
      break;
   case GSI1_FORM_B:
      split_imm(branch_offset, &lo, &hi);
      w0 |= ((lo >> 11) & 1) << 31 | ((lo >> 4) & 0x3f) << 25 |
            reg_lo(rs1) << GSI1_W0_RS1_SHIFT | (uint32_t)in->funct3 << 12 |
            (lo & 0xf) << 8 | ((lo >> 10) & 1) << 7;
      w1 |= hi << GSI1_W1_IMM_HI_SHIFT;
      break;
   case GSI1_FORM_U:
      /* movi: imm[31:12] in word0, imm[11:0] in word1[13:2]. */
      w0 |= reg_lo(rd) << GSI1_W0_RD_SHIFT |
            ((uint32_t)in->imm >> 12) << GSI1_W0_UIMM_SHIFT;
      w1 = reg_hi(rd) | ((uint32_t)in->imm & 0xfff) << GSI1_W1_MOVI_SHIFT;
      break;
   case GSI1_FORM_LABEL:
      UNREACHABLE("labels are not encoded");
   }

   return (uint64_t)w1 << 32 | w0;
}

uint64_t *
gsi1_encode(const struct gsi1_program *p, unsigned *count)
{
   const unsigned n = gsi1_instr_count(p);
   int32_t *label_pc = calloc(p->label_count + 1, sizeof(*label_pc));
   uint64_t *code = malloc(sizeof(*code) * (n + 1));
   unsigned pc = 0;

   if (!label_pc || !code) {
      free(label_pc);
      free(code);
      return NULL;
   }

   /* Where each label is: the index of the next instruction. */
   util_dynarray_foreach(&p->instrs, struct gsi1_instr, in) {
      if (in->form == GSI1_FORM_LABEL)
         label_pc[in->imm] = pc;
      else
         pc++;
   }

   pc = 0;
   util_dynarray_foreach(&p->instrs, struct gsi1_instr, in) {
      if (in->form == GSI1_FORM_LABEL)
         continue;
      int32_t off = in->form == GSI1_FORM_B ? label_pc[in->imm] - (int32_t)pc
                                            : 0;
      code[pc++] = encode_one(in, off);
   }

   free(label_pc);
   *count = pc;
   return code;
}
