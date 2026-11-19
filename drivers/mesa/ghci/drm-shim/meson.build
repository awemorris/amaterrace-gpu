# GHCI GPU Driver
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib

libghci_noop_drm_shim = shared_library(
  'ghci_noop_drm_shim',
  files('ghci_noop_drm_shim.c'),
  include_directories : [inc_include, inc_src],
  dependencies : [dep_drm_shim, idep_mesautil],
  gnu_symbol_visibility : 'hidden',
  install : true,
)
