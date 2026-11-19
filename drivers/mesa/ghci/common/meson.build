# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib

libghci_common = static_library(
  'ghci_common',
  files('ghci_dev.c'),
  include_directories : [inc_include, inc_src, inc_ghci],
  dependencies : [dep_libdrm],
  gnu_symbol_visibility : 'hidden',
  build_by_default : false,
)

idep_ghci_common = declare_dependency(
  link_with : libghci_common,
  include_directories : [inc_ghci],
  dependencies : [dep_libdrm],
)
