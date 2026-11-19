# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib

ghcivk_entrypoints = custom_target(
  'ghcivk_entrypoints',
  input : [vk_entrypoints_gen, vk_api_xml],
  output : ['ghcivk_entrypoints.h', 'ghcivk_entrypoints.c'],
  command : [
    prog_python, '@INPUT0@', '--xml', '@INPUT1@', '--proto', '--weak',
    '--out-h', '@OUTPUT0@', '--out-c', '@OUTPUT1@', '--prefix', 'ghcivk',
    '--beta', with_vulkan_beta.to_string(),
  ],
  depend_files : vk_entrypoints_gen_depend_files,
)

ghcivk_files = files(
  'ghcivk_device.c',
  'ghcivk_formats.c',
  'ghcivk_image.c',
  'ghcivk_instance.c',
  'ghcivk_physical_device.c',
)

libvulkan_ghci = shared_library(
  'vulkan_ghci',
  [ghcivk_files, ghcivk_entrypoints, sha1_h],
  include_directories : [inc_include, inc_src],
  dependencies : [
    idep_ghci_common,
    idep_mesautil,
    idep_vulkan_runtime,
    idep_vulkan_util,
    dep_libdrm,
  ],
  c_args : [no_override_init_args],
  link_args : [vulkan_icd_link_args, ld_args_build_id, ld_args_bsymbolic,
               ld_args_gc_sections],
  link_depends : vulkan_icd_link_depends,
  gnu_symbol_visibility : 'hidden',
  install : true,
)

if with_symbols_check
  test(
    'ghcivk symbols check',
    symbols_check,
    args : [
      '--lib', libvulkan_ghci,
      '--symbols-file', vulkan_icd_symbols,
      symbols_check_args,
    ],
    suite : ['ghci'],
  )
endif

ghci_icd_file_name = libname_prefix + 'vulkan_ghci.' + libname_suffix

ghci_icd = custom_target(
  'ghci_icd',
  input : [vk_icd_gen, vk_api_xml],
  output : 'ghci_icd.' + vulkan_manifest_suffix,
  command : [
    prog_python, '@INPUT0@',
    '--api-version', '1.0', '--xml', '@INPUT1@',
    '--sizeof-pointer', sizeof_pointer,
    '--icd-lib-path', vulkan_icd_lib_path,
    '--icd-filename', ghci_icd_file_name,
    '--out', '@OUTPUT@',
  ],
  build_by_default : true,
  install_dir : with_vulkan_icd_dir,
  install_tag : 'runtime',
  install : true,
)

ghci_devenv_icd = custom_target(
  'ghci_devenv_icd',
  input : [vk_icd_gen, vk_api_xml],
  output : 'ghci_devenv_icd.@0@.json'.format(host_machine.cpu()),
  command : [
    prog_python, '@INPUT0@',
    '--api-version', '1.0', '--xml', '@INPUT1@',
    '--sizeof-pointer', sizeof_pointer,
    '--icd-lib-path', meson.current_build_dir(),
    '--icd-filename', ghci_icd_file_name,
    '--out', '@OUTPUT@',
  ],
  build_by_default : true,
)

devenv.append('VK_DRIVER_FILES', ghci_devenv_icd.full_path())
