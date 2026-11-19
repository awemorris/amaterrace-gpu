/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1_nir.c: the NIR options of the GSI1 back end and the lowering from
 * spirv_to_nir() to the form gsi1_compile() takes: scalar 32-bit ALU,
 * shader I/O as load_input/store_output with I/O semantics, memory as
 * 32-bit scalar load_global/store_global (buffers), load_shared/
 * store_shared (LDS) and load_push_constant (the constant bank), and the
 * phi webs out of SSA.
 *
 * Descriptors (ghci.md 12.10.2): set s's base address is constant-bank
 * word 24 + 2 s, a buffer descriptor is 16 bytes with the buffer's base
 * address in its first word.  A resource index is the address of its
 * descriptor; loading the descriptor gives the buffer's address.
 */

#include "gsi1.h"

#include "compiler/nir/nir.h"
#include "compiler/nir/nir_builder.h"
#include "compiler/spirv/nir_spirv.h"

static const nir_shader_compiler_options gsi1_options = {
   .lower_fdiv = true,
   .lower_fpow = true,
   .lower_fmod = true,
   .lower_flrp32 = true,
   .lower_fsign = true,
   .lower_isign = true,
   .lower_bitfield_extract = true,
   .lower_bitfield_insert = true,
   .lower_bitfield_reverse = true,
   .lower_bit_count = true,
   .lower_ifind_msb = true,
   .lower_find_lsb = true,
   .lower_uadd_carry = true,
   .lower_usub_borrow = true,
   .lower_hadd = true,
   .lower_uadd_sat = true,
   .lower_iadd_sat = true,
   .lower_scmp = true,
   .lower_extract_byte = true,
   .lower_extract_word = true,
   .lower_insert_byte = true,
   .lower_insert_word = true,
   .lower_pack_half_2x16 = true,
   .lower_pack_unorm_2x16 = true,
   .lower_pack_snorm_2x16 = true,
   .lower_pack_unorm_4x8 = true,
   .lower_pack_snorm_4x8 = true,
   .lower_unpack_half_2x16 = true,
   .lower_unpack_unorm_2x16 = true,
   .lower_unpack_snorm_2x16 = true,
   .lower_unpack_unorm_4x8 = true,
   .lower_unpack_snorm_4x8 = true,
   .lower_pack_split = true,
   .lower_to_scalar = true,
   .lower_int64_options = ~0,
   .lower_doubles_options = ~0,
   .vertex_id_zero_based = false,
   .max_unroll_iterations = 0,
};

const nir_shader_compiler_options *
gsi1_nir_options(void)
{
   return &gsi1_options;
}

void
gsi1_spirv_options(struct spirv_to_nir_options *o)
{
   *o = (struct spirv_to_nir_options) {
      .environment = NIR_SPIRV_VULKAN,
      .ubo_addr_format = nir_address_format_32bit_global,
      .ssbo_addr_format = nir_address_format_32bit_global,
      .phys_ssbo_addr_format = nir_address_format_32bit_global,
      .push_const_addr_format = nir_address_format_32bit_offset,
      .shared_addr_format = nir_address_format_32bit_offset,
      .global_addr_format = nir_address_format_32bit_global,
      .temp_addr_format = nir_address_format_32bit_offset,
      .constant_addr_format = nir_address_format_32bit_global,
   };
}

/* Constant-bank bytes: push constants, then the set base addresses. */
#define GSI1_SET_BASE_BYTES 96u

struct descriptor_state {
   const struct gsi1_compile_options *options;
};

static uint32_t
binding_offset(const struct gsi1_compile_options *o, unsigned set,
               unsigned binding)
{
   if (o->binding_offset)
      return o->binding_offset(o->binding_offset_data, set, binding);
   return binding * 16;
}

static bool
lower_descriptor(nir_builder *b, nir_intrinsic_instr *intr, void *data)
{
   const struct gsi1_compile_options *o = data;
   nir_def *res;

   b->cursor = nir_before_instr(&intr->instr);

   switch (intr->intrinsic) {
   case nir_intrinsic_vulkan_resource_index: {
      unsigned set = nir_intrinsic_desc_set(intr);
      unsigned binding = nir_intrinsic_binding(intr);
      nir_def *base =
         nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0),
                                .base = GSI1_SET_BASE_BYTES + 8 * set,
                                .range = 4);
      res = nir_iadd(b, base,
                     nir_iadd_imm(b, nir_imul_imm(b, intr->src[0].ssa, 16),
                                  binding_offset(o, set, binding)));
      break;
   }
   case nir_intrinsic_vulkan_resource_reindex:
      res = nir_iadd(b, intr->src[0].ssa,
                     nir_imul_imm(b, intr->src[1].ssa, 16));
      break;
   case nir_intrinsic_load_vulkan_descriptor:
      /* The buffer's address, the first word of its descriptor. */
      res = nir_load_global(b, 1, 32, intr->src[0].ssa, .align_mul = 4);
      break;
   default:
      return false;
   }

   nir_def_replace(&intr->def, res);
   return true;
}

static unsigned
type_size_vec4(const struct glsl_type *type, bool bindless)
{
   return glsl_count_attribute_slots(type, false);
}

static nir_mem_access_size_align
mem_access_size_align(nir_intrinsic_op intrin, uint8_t bytes,
                      uint8_t bit_size, uint32_t align_mul,
                      uint32_t align_offset, bool offset_is_const,
                      enum gl_access_qualifier access, const void *cb_data)
{
   /* GSI1 memory instructions move one 32-bit word (ghci.md 12.8). */
   return (nir_mem_access_size_align) {
      .num_components = 1,
      .bit_size = 32,
      .align = 4,
      .shift = nir_mem_access_shift_method_scalar,
   };
}

static void
optimize(nir_shader *nir)
{
   bool progress;

   do {
      progress = false;
      NIR_PASS(progress, nir, nir_opt_copy_prop);
      NIR_PASS(progress, nir, nir_opt_dce);
      NIR_PASS(progress, nir, nir_opt_cse);
      NIR_PASS(progress, nir, nir_opt_dead_cf);
      NIR_PASS(progress, nir, nir_opt_remove_phis);
      NIR_PASS(progress, nir, nir_opt_if, 0);
      NIR_PASS(progress, nir, nir_opt_algebraic);
      NIR_PASS(progress, nir, nir_opt_constant_folding);
      NIR_PASS(progress, nir, nir_opt_undef);
      NIR_PASS(progress, nir, nir_lower_alu_to_scalar, NULL, NULL);
      NIR_PASS(progress, nir, nir_lower_phis_to_scalar, NULL, NULL);
   } while (progress);
}

void
gsi1_lower_nir(nir_shader *nir, const struct gsi1_compile_options *o)
{
   NIR_PASS(_, nir, nir_lower_variable_initializers, nir_var_function_temp);
   NIR_PASS(_, nir, nir_lower_returns);
   NIR_PASS(_, nir, nir_inline_functions);
   nir_remove_non_entrypoints(nir);
   NIR_PASS(_, nir, nir_opt_copy_prop);
   NIR_PASS(_, nir, nir_opt_deref);
   NIR_PASS(_, nir, nir_lower_variable_initializers, ~0);
   NIR_PASS(_, nir, nir_split_var_copies);
   NIR_PASS(_, nir, nir_lower_var_copies);
   NIR_PASS(_, nir, nir_lower_global_vars_to_local);
   NIR_PASS(_, nir, nir_split_struct_vars, nir_var_function_temp);
   NIR_PASS(_, nir, nir_lower_vars_to_ssa);
   NIR_PASS(_, nir, nir_remove_dead_variables,
            nir_var_shader_in | nir_var_shader_out | nir_var_function_temp,
            NULL);

   /* Shader I/O by location; the back end reads the I/O semantics. */
   nir_foreach_variable_with_modes(var, nir,
                                   nir_var_shader_in | nir_var_shader_out)
      var->data.driver_location = var->data.location;
   NIR_PASS(_, nir, nir_lower_io_vars_to_temporaries,
            nir_shader_get_entrypoint(nir), nir_var_shader_out);
   NIR_PASS(_, nir, nir_split_var_copies);
   NIR_PASS(_, nir, nir_lower_var_copies);
   NIR_PASS(_, nir, nir_lower_global_vars_to_local);
   NIR_PASS(_, nir, nir_lower_vars_to_ssa);
   NIR_PASS(_, nir, nir_lower_io, nir_var_shader_in | nir_var_shader_out,
            type_size_vec4, nir_lower_io_use_interpolated_input_intrinsics);

   NIR_PASS(_, nir, nir_lower_system_values);
   const nir_lower_compute_system_values_options csv = {
      .global_id_is_32bit = true,
   };
   NIR_PASS(_, nir, nir_lower_compute_system_values, &csv);

   /* Memory. */
   NIR_PASS(_, nir, nir_lower_vars_to_explicit_types, nir_var_mem_shared,
            glsl_get_natural_size_align_bytes);
   NIR_PASS(_, nir, nir_shader_intrinsics_pass, lower_descriptor,
            nir_metadata_control_flow, (void *)o);
   NIR_PASS(_, nir, nir_lower_explicit_io,
            nir_var_mem_ubo | nir_var_mem_ssbo | nir_var_mem_global,
            nir_address_format_32bit_global);
   NIR_PASS(_, nir, nir_lower_explicit_io,
            nir_var_mem_push_const | nir_var_mem_shared,
            nir_address_format_32bit_offset);
   const nir_lower_mem_access_bit_sizes_options mem = {
      .callback = mem_access_size_align,
      .modes = nir_var_mem_global | nir_var_mem_shared |
               nir_var_mem_push_const | nir_var_mem_ubo | nir_var_mem_ssbo,
   };
   NIR_PASS(_, nir, nir_lower_mem_access_bit_sizes, &mem);
   NIR_PASS(_, nir, nir_lower_io_to_scalar,
            nir_var_shader_in | nir_var_shader_out, NULL, NULL);

   NIR_PASS(_, nir, nir_lower_continue_constructs);
   NIR_PASS(_, nir, nir_lower_alu_to_scalar, NULL, NULL);
   NIR_PASS(_, nir, nir_lower_load_const_to_scalar);
   optimize(nir);
   NIR_PASS(_, nir, nir_opt_algebraic_late);
   optimize(nir);

   NIR_PASS(_, nir, nir_convert_from_ssa, true, false);
   NIR_PASS(_, nir, nir_opt_dce);
   nir_index_ssa_defs(nir_shader_get_entrypoint(nir));
}
