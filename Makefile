# Amaterrace GPU
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
#
# Builds and loads the GPU's bitstream for the KC705, with openXC7 or
# Vivado, and runs the RTL checks.  The tools are expected on PATH:
# yosys, nextpnr-himbaechel, bbasm, fpga-as (openXC7), vivado, and
# openFPGALoader; verilator and iverilog for the checks.  `make` alone
# prints the targets.

BOARD ?= kc705
TOP ?= atg_kc705_raster
PART ?= xc7k325tffg900-2
DIE ?= xc7k325t
# openXC7's data: the prjxray database and nextpnr's chip-database generator.
PRJXRAY_DB_DIR ?= $(HOME)/opt/openxc7/share/nextpnr/prjxray-db
OPENXC7_SHARE ?= $(HOME)/opt/openxc7/share
FAMILY ?= kintex7

BUILD := build
OXC := $(BUILD)/openxc7/$(TOP)
CHIPDB := $(BUILD)/openxc7/chipdb/$(DIE).bin
RTL := $(sort $(shell find rtl -name '*.v'))
BOARD_SRC := boards/$(BOARD)/$(TOP).v $(sort $(wildcard boards/$(BOARD)/lib/*.v))
XDC := boards/$(BOARD)/$(TOP).xdc
FW_IMAGES := $(wildcard fw/cp/images/*.hex)

.PHONY: help lint sim sim-quick verilator check oxc-synth oxc-core oxc vivado prog-oxc prog-vivado clean
.DEFAULT_GOAL := help

help:
	@echo 'Amaterrace GPU (BOARD=$(BOARD) TOP=$(TOP) PART=$(PART))'
	@echo ''
	@echo '  make lint         Verilator lint of every module and top (tools/lint.sh)'
	@echo '  make sim          the iverilog testbenches (sim/run.sh, about 17 minutes)'
	@echo '  make sim-quick    the short run of the testbenches (sim/run.sh -q, a few minutes)'
	@echo '  make verilator    the Verilator system harness (sim/verilator/run.sh)'
	@echo '  make check        lint, sim and verilator'
	@echo '  make oxc-synth    openXC7: yosys synthesis only -> $(OXC)/$(TOP).json'
	@echo '  make oxc-core     openXC7: yosys synthesis of the GPU core atg_top in the KC705 shape'
	@echo '                   (CORE_PARAMS; no board stubs, so the logic is kept) -> $(BUILD)/openxc7/core'
	@echo '  make oxc          openXC7: synthesis, nextpnr, fpga-as -> $(OXC)/$(TOP).bit'
	@echo '  make vivado       Vivado batch build -> $(BUILD)/vivado/$(TOP)/$(TOP).bit'
	@echo '  make prog-oxc     load the openXC7 bitstream with openFPGALoader'
	@echo '  make prog-vivado  load the Vivado bitstream with openFPGALoader'
	@echo '  make clean        remove $(BUILD)/openxc7 and $(BUILD)/vivado'
	@echo ''
	@echo 'Variables: BOARD, TOP, PART, DIE, FAMILY, PRJXRAY_DB_DIR, OPENXC7_SHARE,'
	@echo '  CABLE (openFPGALoader -c, default digilent), FTDI_SERIAL (selects the board).'

lint:
	tools/lint.sh

sim:
	sim/run.sh

sim-quick:
	sim/run.sh -q

verilator:
	sim/verilator/run.sh

check: lint sim verilator

# ---------------------------------------------------------------- openXC7

$(OXC)/$(TOP).json: $(RTL) $(BOARD_SRC) $(FW_IMAGES)
	mkdir -p $(OXC)
	cp $(FW_IMAGES) $(OXC)/
	cd $(OXC) && yosys -q -l yosys.log -p "read_verilog -I$(CURDIR)/include \
		$(addprefix $(CURDIR)/,$(RTL) $(BOARD_SRC)); \
		synth_xilinx -flatten -abc9 -arch xc7 -top $(TOP); write_json $(TOP).json"

oxc-synth: $(OXC)/$(TOP).json
	@grep -A40 'Number of cells' $(OXC)/yosys.log | grep -E 'LUT|FD|CARRY|RAMB|DSP' || true

# The GPU core alone (atg_top) in the KC705's shape: the board top's MIG,
# clock and JTAG are still port-only stubs, so synthesizing the board
# top removes all logic; this keeps it and reports the core's cells.
CORE_PARAMS ?= -set LINE_BYTES 64 -set LINE_SHIFT 6 -set DATA_W 512 -set HAS_CPU 1 \
	-set HAS_RX 1 -set HAS_ROP 1 -set NSU 1
CORE := $(BUILD)/openxc7/core

oxc-core: $(RTL) $(FW_IMAGES)
	mkdir -p $(CORE)
	cp $(FW_IMAGES) $(CORE)/
	cd $(CORE) && yosys -q -l yosys.log -p "read_verilog -I$(CURDIR)/include \
		$(addprefix $(CURDIR)/,$(RTL)); chparam $(CORE_PARAMS) atg_top; \
		synth_xilinx -flatten -abc9 -arch xc7 -top atg_top; tee -o stat.txt stat"
	@grep -E 'LUT|FD|CARRY|RAMB|DSP' $(CORE)/stat.txt || true

$(CHIPDB):
	mkdir -p $(dir $@)
	python3 $(OPENXC7_SHARE)/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py \
		--xray $(PRJXRAY_DB_DIR)/$(FAMILY) --device $(DIE) --bba $(@:.bin=.bba)
	bbasm -l $(@:.bin=.bba) $@

$(OXC)/$(TOP).bit: $(OXC)/$(TOP).json $(CHIPDB) $(XDC)
	nextpnr-himbaechel --chipdb $(CHIPDB) --device $(PART) --json $< \
		-o xdc=$(XDC) -o fasm=$(OXC)/$(TOP).fasm --log $(OXC)/nextpnr.log
	fpga-as --prjxray_db_path=$(PRJXRAY_DB_DIR)/$(FAMILY) --part $(PART) \
		$(OXC)/$(TOP).fasm > $@

oxc: $(OXC)/$(TOP).bit
	@grep 'Max frequency for clock' $(OXC)/nextpnr.log | tail -3 || true

# ---------------------------------------------------------------- Vivado

vivado:
	tools/vivado-build.sh $(BOARD) $(TOP)

# ---------------------------------------------------------------- loading

CABLE ?= digilent
FTDI_SERIAL ?=
LOADER = openFPGALoader -c $(CABLE) $(if $(FTDI_SERIAL),--ftdi-serial $(FTDI_SERIAL))

prog-oxc: $(OXC)/$(TOP).bit
	$(LOADER) $<

prog-vivado:
	$(LOADER) $(BUILD)/vivado/$(TOP)/$(TOP).bit

clean:
	rm -rf $(BUILD)/openxc7 $(BUILD)/vivado
