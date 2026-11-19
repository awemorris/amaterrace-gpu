/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_ra.c: register allocation on the linear program.
 *
 * Every value gets one register for its live range, the instructions from
 * its first definition or use to its last.  A value that a loop reads but
 * that was defined before the loop, and a value with several definitions
 * (a NIR register after nir_convert_from_ssa()), stays live over the whole
 * loop.  Ranges are given registers first fit, in the order they start.
 *
 * GSI1 masks lanes with EXEC instead of branching per lane (ghci.md 12.2):
 * an instruction writes the lanes in EXEC only.  The ranges above stay
 * correct under that: a value is read only by the lanes that wrote it, and
 * a lane that leaves a loop early keeps its registers, because a value
 * that is used after the loop is defined before every break.
 *
 * There is no spilling yet: a program that needs more than max_regs
 * registers fails.
 */

#include <stdlib.h>
#include <string.h>

#include "util/macros.h"

#include "gsi1_ir.h"

struct range {
   int first;
   int last;
   int defs;
   int reg;
};

static void
touch(struct range *r, int i, bool def)
{
   if (r->first < 0 || i < r->first)
      r->first = i;
   if (i > r->last)
      r->last = i;
   if (def)
      r->defs++;
}

static bool
overlaps(const struct range *a, const struct range *b)
{
   /* A value may take the register of one whose last use is the
    * instruction that defines it. */
   return a->first < b->last && b->first < a->last;
}

unsigned
gsi1_ra(struct gsi1_program *p, unsigned max_regs)
{
   const unsigned nv = p->value_count;
   const unsigned ni = gsi1_instr_count(p);
   struct range *ranges = calloc(nv ? nv : 1, sizeof(*ranges));
   unsigned *order = calloc(nv ? nv : 1, sizeof(*order));
   unsigned used = 0;

   if (!ranges || !order)
      goto fail;

   for (unsigned v = 0; v < nv; v++)
      ranges[v] = (struct range) { .first = -1, .last = -1, .reg = -1 };

   for (unsigned i = 0; i < ni; i++) {
      struct gsi1_instr *in = gsi1_instr_at(p, i);
      if (in->form == GSI1_FORM_LABEL)
         continue;
      if (gsi1_is_value(in->dst))
         touch(&ranges[in->dst - GSI1_VALUE_BASE], i, true);
      for (unsigned s = 0; s < 3; s++)
         if (gsi1_is_value(in->srcs[s]))
            touch(&ranges[in->srcs[s] - GSI1_VALUE_BASE], i, false);
   }

   /* Registers filled before the start are live from it. */
   unsigned nfixed = util_dynarray_num_elements(&p->fixed, int8_t);
   for (unsigned v = 0; v < nv && v < nfixed; v++) {
      int8_t reg = *util_dynarray_element(&p->fixed, int8_t, v);
      if (reg >= 0 && ranges[v].first >= 0) {
         ranges[v].first = -1;
         ranges[v].reg = reg;
      }
   }

   /* Loops: extend the ranges of the values the next iteration needs.
    * Nested loops can extend a range twice, so repeat until stable. */
   bool progress = true;
   while (progress) {
      progress = false;
      util_dynarray_foreach(&p->loops, struct gsi1_loop_range, l) {
         const int a = l->first, b = l->last;
         for (unsigned v = 0; v < nv; v++) {
            struct range *r = &ranges[v];
            if (r->last < 0 && r->first < 0)
               continue;
            if (r->last < a || r->first > b)
               continue;
            if (r->first < a && r->last < b) {
               r->last = b;
               progress = true;
            }
            if (r->defs > 1 && (r->first > a || r->last < b)) {
               r->first = MIN2(r->first, a);
               r->last = MAX2(r->last, b);
               progress = true;
            }
         }
      }
   }

   /* First fit, by start. */
   unsigned n = 0;
   for (unsigned v = 0; v < nv; v++)
      if (ranges[v].first >= 0 || ranges[v].last >= 0)
         order[n++] = v;
   for (unsigned i = 1; i < n; i++) {
      unsigned v = order[i], j = i;
      while (j > 0 && ranges[order[j - 1]].first > ranges[v].first) {
         order[j] = order[j - 1];
         j--;
      }
      order[j] = v;
   }

   for (unsigned i = 0; i < n; i++) {
      struct range *r = &ranges[order[i]];
      if (r->reg >= 0) {
         used = MAX2(used, (unsigned)r->reg + 1);
         continue;
      }
      uint64_t busy = 0;
      for (unsigned j = 0; j < n; j++) {
         const struct range *o = &ranges[order[j]];
         if (o != r && o->reg >= 0 && overlaps(r, o))
            busy |= 1ull << o->reg;
      }
      int reg = -1;
      for (unsigned k = 0; k < max_regs; k++) {
         if (!(busy & (1ull << k))) {
            reg = k;
            break;
         }
      }
      if (reg < 0)
         goto fail;
      r->reg = reg;
      used = MAX2(used, (unsigned)reg + 1);
   }

   for (unsigned i = 0; i < ni; i++) {
      struct gsi1_instr *in = gsi1_instr_at(p, i);
      if (gsi1_is_value(in->dst))
         in->dst = ranges[in->dst - GSI1_VALUE_BASE].reg;
      for (unsigned s = 0; s < 3; s++)
         if (gsi1_is_value(in->srcs[s]))
            in->srcs[s] = ranges[in->srcs[s] - GSI1_VALUE_BASE].reg;
   }

   free(ranges);
   free(order);
   return MAX2(used, 1);

fail:
   free(ranges);
   free(order);
   return 0;
}
