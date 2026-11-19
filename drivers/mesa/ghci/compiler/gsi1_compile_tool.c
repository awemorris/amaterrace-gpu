/*
 * GHCI GPU Driver
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci-gsi1c: compiles one SPIR-V shader with the GSI1 back end, without a
 * GPU, for tests and for looking at the code.
 *
 *   ghci-gsi1c [-S vert|frag|comp] [--max-regs N] [--attr LOC=COMPS]...
 *              [--nir] SHADER.spv -o OUT.hex
 *
 * OUT.hex has one 32-bit word per line, word0 then word1 of each
 * instruction (the form mk/gsi1asm.py writes and mk/gsi1dis.py reads).
 * The shader information goes to standard output as "name value" lines.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "compiler/glsl_types.h"
#include "compiler/nir/nir.h"
#include "compiler/spirv/nir_spirv.h"

#include "gsi1.h"

static void
usage(void)
{
   fprintf(stderr, "usage: ghci-gsi1c [-S vert|frag|comp] [--max-regs N] "
                   "[--attr LOC=COMPS]... [--nir] SHADER.spv -o OUT.hex\n");
   exit(2);
}

static uint32_t *
read_file(const char *path, size_t *words)
{
   FILE *f = fopen(path, "rb");
   if (!f) {
      fprintf(stderr, "ghci-gsi1c: %s: %s\n", path, strerror(errno));
      exit(1);
   }

   fseek(f, 0, SEEK_END);

   long size = ftell(f);
   fseek(f, 0, SEEK_SET);
   if (size <= 0 || size % 4) {
      fprintf(stderr, "ghci-gsi1c: %s: not SPIR-V\n", path);
      exit(1);
   }

   uint32_t *data = malloc(size);
   if (!data || fread(data, 1, size, f) != (size_t)size) {
      fprintf(stderr, "ghci-gsi1c: %s: read failed\n", path);
      exit(1);
   }

   fclose(f);

   *words = size / 4;

   return data;
}

int
main(int argc, char **argv)
{
   mesa_shader_stage stage = MESA_SHADER_COMPUTE;
   const char *in = NULL, *out = NULL;
   struct gsi1_compile_options options = { .max_regs = 32 };
   bool print_nir = false;

   for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "-S") && i + 1 < argc) {
         const char *s = argv[++i];
         if (!strcmp(s, "vert"))
            stage = MESA_SHADER_VERTEX;
         else if (!strcmp(s, "frag"))
            stage = MESA_SHADER_FRAGMENT;
         else if (!strcmp(s, "comp"))
            stage = MESA_SHADER_COMPUTE;
         else
            usage();
      } else if (!strcmp(argv[i], "--max-regs") && i + 1 < argc) {
         options.max_regs = atoi(argv[++i]);
      } else if (!strcmp(argv[i], "--attr") && i + 1 < argc) {
         unsigned loc, comps;
         if (sscanf(argv[++i], "%u=%u", &loc, &comps) != 2 || loc >= 16 ||
             comps < 1 || comps > 4)
            usage();
         options.attribute_components[loc] = comps;
      } else if (!strcmp(argv[i], "--nir")) {
         print_nir = true;
      } else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
         out = argv[++i];
      } else if (argv[i][0] != '-' && !in) {
         in = argv[i];
      } else {
         usage();
      }
   }
   if (!in || !out)
      usage();

   size_t words;
   uint32_t *spirv = read_file(in, &words);

   glsl_type_singleton_init_or_ref();

   struct spirv_to_nir_options spirv_options;
   gsi1_spirv_options(&spirv_options);
   nir_shader *nir = spirv_to_nir(spirv, words, NULL, stage, "main",
                                  &spirv_options, gsi1_nir_options());
   if (!nir) {
      fprintf(stderr, "ghci-gsi1c: %s: spirv_to_nir failed\n", in);
      return 1;
   }

   gsi1_lower_nir(nir, &options);
   if (print_nir)
      nir_print_shader(nir, stderr);

   struct gsi1_binary bin;
   char *error = NULL;
   if (!gsi1_compile(nir, &options, &bin, &error)) {
      fprintf(stderr, "ghci-gsi1c: %s: %s\n", in, error ? error : "failed");
      free(error);
      return 1;
   }

   FILE *f = fopen(out, "w");
   if (!f) {
      fprintf(stderr, "ghci-gsi1c: %s: %s\n", out, strerror(errno));
      return 1;
   }
   for (unsigned i = 0; i < bin.info.instr_count; i++)
      fprintf(f, "%08x\n%08x\n", (uint32_t)bin.code[i],
              (uint32_t)(bin.code[i] >> 32));
   fclose(f);

   printf("instructions %u\n", bin.info.instr_count);
   printf("used_regs %u\n", bin.info.used_regs);
   printf("varying_count %u\n", bin.info.varying_count);
   printf("local_size %u %u %u\n", bin.info.local_size[0],
          bin.info.local_size[1], bin.info.local_size[2]);
   printf("lds_bytes %u\n", bin.info.lds_bytes);
   printf("fs_centroid %d\nfs_depth_export %d\nfs_discard %d\n",
          bin.info.fs_centroid, bin.info.fs_depth_export,
          bin.info.fs_discard);

   gsi1_binary_finish(&bin);
   ralloc_free(nir);
   free(spirv);

   glsl_type_singleton_decref();

   return 0;
}
