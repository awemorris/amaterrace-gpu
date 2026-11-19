# SPDX-License-Identifier: Zlib

#
# GHCI GPU Driver
# Copyright (C) 2026 Awe Morris
#

#
# Builds the ghci kernel module out of the kernel tree:
#
#   make                       for the running kernel
#   make KDIR=/usr/src/linux-headers-6.12.117+deb13-amd64
#   make dkms-source           a DKMS source tree in $(DKMS_SRC)
#
# The module is also built by DKMS from that tree (dkms.conf).

TOP := $(abspath $(CURDIR)/../..)
KDIR ?= /lib/modules/$(shell uname -r)/build
JOBS ?= 4
GHCI_VERSION := 0.1
DKMS_SRC ?= $(TOP)/build/linux/ghci-$(GHCI_VERSION)

SOURCES := Kbuild dkms.conf $(filter-out %.mod.c,$(wildcard *.c *.h)) compat/stdint.h \
	include/uapi/drm/ghci_drm.h

.PHONY: all modules clean dkms-source

all: modules

modules:
	$(MAKE) -j$(JOBS) -C $(KDIR) M=$(CURDIR) W=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

# A tree that does not need the rest of amaterrace-gpu: the GHCI headers
# go to hw/.
dkms-source:
	mkdir -p $(DKMS_SRC)/hw $(DKMS_SRC)/compat $(DKMS_SRC)/include/uapi/drm
	for f in $(SOURCES); do cp $$f $(DKMS_SRC)/$$f; done
	cp $(TOP)/include/ghci_regs.h $(TOP)/include/ghci_cmd.h $(DKMS_SRC)/hw/
	sed -i 's/^PACKAGE_VERSION=.*/PACKAGE_VERSION="$(GHCI_VERSION)"/' \
		$(DKMS_SRC)/dkms.conf
