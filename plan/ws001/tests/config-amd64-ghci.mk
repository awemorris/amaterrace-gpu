# The amd64 image with the generic GHCI GPU driver, for a KC705 GHCI board passed through to a QEMU guest
# (VFIO): the CI amd64 image with the driver, its root-only native command, the GHCI tools and tests, and the
# kernel's lines on the screen.
# Build:  plan/tools/guest/test-image.sh plan/ws288/tests/config-amd64-ghci.mk build/<dir>
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
include config/ci/config-amd64.mk

CONFIG_DRIVER_PCI_GHCI := y
CONFIG_GHCI_NATIVE := y
ZEDBSD_USER_PROGRAMS += ghcictl ghci-blit ghci-display

ZEDBSD_GRAPHICAL_BOOT := n
ZEDBSD_BOOT_KERNEL_MESSAGES := y
