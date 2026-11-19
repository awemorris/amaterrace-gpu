# KC705 Vivado non-project build wrapper
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

ROOT         := $(abspath ../..)
TOP          ?= atg_kc705_top
CABLE        ?= digilent
FTDI_SERIAL  ?=
LOADER        = openFPGALoader -c $(CABLE) $(if $(FTDI_SERIAL),--ftdi-serial $(FTDI_SERIAL))

.PHONY: all ip prog

all:
	$(ROOT)/mk/vivado-build.sh kc705 $(TOP)

ip:
	$(ROOT)/mk/build-kc705-ip.sh

prog:
	$(LOADER) $(ROOT)/build/vivado/$(TOP)/$(TOP).bit
