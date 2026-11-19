# GHCI GPU Driver
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
#
# The GSI1 shader compiler (NIR to GSI1, ghci.md section 12) and its
# command-line front end for tests.

libgsi1 = static_library(
  'gsi1',
  files(
    'gsi1_encode.c',
    'gsi1_from_nir.c',
    'gsi1_nir.c',
    'gsi1_ra.c',
  ),
  include_directories : [inc_include, inc_src],
  dependencies : [idep_nir, idep_vtn, idep_mesautil],
  gnu_symbol_visibility : 'hidden',
  build_by_default : false,
)

idep_gsi1 = declare_dependency(
  link_with : libgsi1,
  include_directories : include_directories('.'),
  dependencies : [idep_nir, idep_vtn],
)

if with_tools.contains('ghci')
  executable(
    'ghci-gsi1c',
    files('gsi1_compile_tool.c'),
    include_directories : [inc_include, inc_src],
    dependencies : [idep_gsi1, idep_mesautil],
    install : true,
  )
endif
