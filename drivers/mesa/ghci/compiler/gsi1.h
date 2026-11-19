/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * gsi1.h: the GSI1 back end of NIR (ghci.md section 12).
 *
 * gsi1_lower_nir() brings a shader from spirv_to_nir() (with
 * gsi1_spirv_options()) to the form the back end takes; gsi1_compile()
 * selects GSI1 instructions, allocates registers and encodes the program:
 * raw 64-bit instructions with no container (ghci.md 12.10.1).  What the
 * pipeline state needs (used_regs, the local size, the LDS bytes, the
 * fragment flags of PSO dw15) comes back in struct gsi1_shader_info.
 *
 * The resource ABI (ghci.md 12.10.2):
 *  - push constants: c0..c23 (bytes 0..95), read as operands or with lwc;
 *  - descriptor set s: its 32-bit base address in c[24 + 2 s] (the CP
 *    mirrors the set bases there on CMD_BIND_DESCRIPTOR_TABLE); a buffer
 *    descriptor is 16 bytes, base address in its first word;
 *  - buffers are reached with 32-bit GPU addresses (lw, sw), which suits
 *    GPUs whose VA_BITS is 32 or less; 64-bit addresses (ld.64) are not
 *    generated yet.
 */

#ifndef GSI1_H
#define GSI1_H

#include <stdbool.h>
#include <stdint.h>

#include "compiler/shader_enums.h"

#ifdef __cplusplus
extern "C" {
#endif

struct nir_shader;
struct nir_shader_compiler_options;
struct spirv_to_nir_options;

/* The operand count of the GSI1 register file (r0..r62). */
#define GSI1_MAX_REGS 63u

struct gsi1_compile_options {
   /* The registers the GPU gives a lane (CMD_QUERY_CAPS word 5 [23:16]);
    * the program must fit them: there is no spilling yet. */
   unsigned max_regs;

   /*
    * The byte offset of (set, binding) in its descriptor set, from the
    * pipeline layout; NULL means binding x 16 (one buffer descriptor per
    * binding).
    */
   uint32_t (*binding_offset)(void *data, unsigned set, unsigned binding);
   void *binding_offset_data;

   /* Vertex shaders: the components of the format of each vertex
    * attribute location (1..4), which set the registers the vertex
    * fetcher fills (ghci.md 12.10.3); 0 takes the shader's type. */
   uint8_t attribute_components[16];
};

struct gsi1_shader_info {
   mesa_shader_stage stage;
   /* PSO dw13: the registers r0..used_regs-1 the program uses (1..63). */
   unsigned used_regs;
   /* Vertex shaders: the varying vec4s exported (PSO dw13 [31:24]). */
   unsigned varying_count;
   /* Compute: PSO dw14 and dw15[15:0]. */
   uint16_t local_size[3];
   uint32_t lds_bytes;
   /* Fragment: PSO dw15 flags. */
   bool fs_centroid;
   bool fs_depth_export;
   bool fs_discard;
   /* The instructions of the program. */
   unsigned instr_count;
};

struct gsi1_binary {
   uint64_t *code;   /* malloc'ed, instr_count instructions */
   struct gsi1_shader_info info;
};

const struct nir_shader_compiler_options *gsi1_nir_options(void);
void gsi1_spirv_options(struct spirv_to_nir_options *options);

/* Lowers a shader from spirv_to_nir() for gsi1_compile(). */
void gsi1_lower_nir(struct nir_shader *nir,
                    const struct gsi1_compile_options *options);

/*
 * Compiles a lowered shader.  Returns false, with a message in *error
 * (malloc'ed) when error is not NULL, for a shader the back end can not
 * compile yet.
 */
bool gsi1_compile(struct nir_shader *nir,
                  const struct gsi1_compile_options *options,
                  struct gsi1_binary *binary, char **error);

void gsi1_binary_finish(struct gsi1_binary *binary);

#ifdef __cplusplus
}
#endif

#endif /* GSI1_H */
