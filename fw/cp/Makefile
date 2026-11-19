# Builds the CP firmware (fw/cp/) into the BRAM init images of atg_cpu:
# images/atg1-cp-kc705.imem.hex (32768 words) and .dmem.hex (16384 words).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

ROOT       := $(abspath ../..)
CLANG_BIN  ?= $(ROOT)/../zedBSD-claude1/build/llvm/bin
BOARD      := kc705
LINE_BYTES := 64
IMEM_WORDS := 32768
DMEM_WORDS := 16384

SRC := $(ROOT)/fw/cp
IMG := $(SRC)/images
OUT := $(ROOT)/build/fw-cp/$(BOARD)

C_SRCS := $(sort $(wildcard *.c))
S_SRCS := $(sort $(wildcard *.S))
OBJS   := $(addprefix $(OUT)/,$(addsuffix .o,$(C_SRCS) $(S_SRCS)))

CFLAGS := --target=riscv32-unknown-elf -march=rv32im -mabi=ilp32 -msmall-data-limit=0 \
	-Oz -ffreestanding -fno-builtin -nostdlib -fno-pic -fno-common -std=c99 \
	-Wall -Wextra -Werror -I$(ROOT)/include -I$(SRC) -DFW_LINE_BYTES=$(LINE_BYTES)u

.PHONY: all formats programs clean

all: $(IMG)/atg1-cp-$(BOARD).imem.hex $(IMG)/atg1-cp-$(BOARD).dmem.hex $(OUT)/atg1-cp-$(BOARD).bin

$(OUT)/%.c.o: %.c fw.h hw.h $(ROOT)/include/ghci_frame.h $(ROOT)/include/ghci_layout.h
	@mkdir -p $(OUT)
	timeout 60 $(CLANG_BIN)/clang $(CFLAGS) -c $< -o $@

$(OUT)/%.S.o: %.S
	@mkdir -p $(OUT)
	timeout 60 $(CLANG_BIN)/clang $(CFLAGS) -c $< -o $@

$(OUT)/format.c.o: formats.inc
$(OUT)/builtin.c.o: programs.inc

$(OUT)/atg1-cp.elf: $(OBJS) link.ld
	timeout 60 $(CLANG_BIN)/ld.lld -T $(SRC)/link.ld --gc-sections $(OBJS) -o $@

$(OUT)/atg1-cp.bin: $(OUT)/atg1-cp.elf
	timeout 60 $(CLANG_BIN)/llvm-objcopy -O binary --only-section=.text $< $@

$(OUT)/atg1-cp-$(BOARD).bin: $(OUT)/atg1-cp.bin
	cp $< $@

$(OUT)/imem.bin: $(OUT)/atg1-cp.bin
	cp $< $@

$(OUT)/atg1-cp.dmem.bin: $(OUT)/atg1-cp.elf
	timeout 60 $(CLANG_BIN)/llvm-objcopy -O binary --only-section=.rodata --only-section=.data $< $@

define pad_to_hex
	@mkdir -p $(IMG)
	@size=$$(wc -c <"$(1)"); \
	pad=$$(( (4 - size % 4) % 4 )); \
	[ "$$pad" -gt 0 ] && head -c "$$pad" /dev/zero >>"$(1)"; \
	words=$$(( (size + pad) / 4 )); \
	[ "$$words" -le "$(2)" ] || { echo "fw-build: $(1) has $$words words, more than $(2)" >&2; exit 1; }; \
	od -An -v -tx4 -w4 "$(1)" | tr -d ' ' >"$(3)"; \
	[ "$$words" -lt "$(2)" ] && yes 00000000 | head -n $$(( $(2) - words )) >>"$(3)"; \
	echo "fw-build: $(BOARD) $(4) $$((words * 4)) bytes"
endef

$(IMG)/atg1-cp-$(BOARD).imem.hex: $(OUT)/imem.bin
	$(call pad_to_hex,$<,$(IMEM_WORDS),$@,IMEM)

$(IMG)/atg1-cp-$(BOARD).dmem.hex: $(OUT)/atg1-cp.dmem.bin
	$(call pad_to_hex,$<,$(DMEM_WORDS),$@,DMEM image)

formats:
	python3 -I $(ROOT)/mk/fw-formats.py

programs:
	python3 -I $(ROOT)/mk/fw-programs.py

clean:
	rm -rf $(ROOT)/build/fw-cp
