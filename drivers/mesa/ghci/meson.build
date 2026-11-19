# GHCI GPU Driver
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
#
# The GHCI driver inside Mesa's build.  drivers/mesa/Makefile links this
# directory in as src/ghci, the kernel's ghci_drm.h as
# include/drm-uapi/ghci_drm.h and the GHCI headers as include/ghci.

inc_ghci = include_directories('common')

subdir('common')
subdir('compiler')

if with_ghci_vk
  subdir('vulkan')

  # The loader picks Zink (GL on Vulkan) for the ghci kernel driver.
  install_data(
    'drirc/00-ghci-loader.conf',
    install_dir : join_paths(get_option('datadir'), 'drirc.d'),
    install_tag : 'runtime',
  )
endif

if with_tools.contains('drm-shim')
  subdir('drm-shim')
endif

# The Vulkan driver against the drm-shim's GHCI device.
if with_ghci_vk and with_tools.contains('drm-shim') and with_tests
  test(
    'ghcivk_enum',
    executable(
      'ghcivk_enum_test',
      files('vulkan/tests/ghcivk_enum_test.c'),
      include_directories : [inc_include],
      dependencies : [dep_dl],
    ),
    args : [libvulkan_ghci.full_path()],
    env : ['LD_PRELOAD=' + libghci_noop_drm_shim.full_path()],
    depends : [libvulkan_ghci, libghci_noop_drm_shim],
    suite : ['ghci'],
  )
endif
