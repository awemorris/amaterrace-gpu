/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ghci_regs.vh: the GHCI 1.0 host control register offsets and fields
 * (docs/ghci.md), for the RTL.  Included inside a module body; every name
 * is a localparam.  include/ghci_regs.h holds the same values for C.
 * A module uses only some of them, so Verilator's unused-parameter
 * warning is off inside this file.
 */

/* verilator lint_off UNUSEDPARAM */

/* Identification. */
localparam [31:0] GHCI_MAGIC_VALUE = 32'h47484349;	/* "GHCI" */
localparam [15:0] GHCI_VERSION_MAJOR = 16'd1;
localparam [15:0] GHCI_VERSION_MINOR = 16'd0;

/* Host control register offsets (bytes in the 128 KiB decode). */
localparam [16:0] GHCI_MAGIC = 17'h00000;
localparam [16:0] GHCI_VERSION = 17'h00004;
localparam [16:0] GHCI_VENDOR_ID = 17'h00008;
localparam [16:0] GHCI_DEVICE_ID = 17'h0000C;
localparam [16:0] GHCI_ISA_ID = 17'h00010;
localparam [16:0] GHCI_DEVICE_VERSION = 17'h00014;
localparam [16:0] GHCI_EXTCAP = 17'h00018;
localparam [16:0] GHCI_GCLK_HZ = 17'h0001C;
localparam [16:0] GHCI_CAPS = 17'h00020;
localparam [16:0] GHCI_CAPS2 = 17'h00024;
localparam [16:0] GHCI_SCRATCH = 17'h00028;
localparam [16:0] GHCI_COUNTER = 17'h0002C;
localparam [16:0] GHCI_CTRL = 17'h00030;
localparam [16:0] GHCI_STATUS = 17'h00034;
localparam [16:0] GHCI_IRQ_STATUS = 17'h00038;
localparam [16:0] GHCI_IRQ_ENABLE = 17'h0003C;
localparam [16:0] GHCI_IRQ_SET = 17'h00040;
localparam [16:0] GHCI_WDT_CYCLES = 17'h00044;
localparam [16:0] GHCI_RING_BASE = 17'h00050;
localparam [16:0] GHCI_RING_SIZE = 17'h00054;
localparam [16:0] GHCI_RING_WPTR = 17'h00058;
localparam [16:0] GHCI_RING_RPTR = 17'h0005C;
localparam [16:0] GHCI_APERTURE_BASE = 17'h00060;
localparam [16:0] GHCI_APERTURE_LIMIT = 17'h00064;
localparam [16:0] GHCI_FAULT_ADDR = 17'h00068;
localparam [16:0] GHCI_FAULT_INFO = 17'h0006C;
localparam [16:0] GHCI_FENCE_LAST = 17'h00070;
localparam [16:0] GHCI_PERF0 = 17'h00080;
localparam [16:0] GHCI_PERF_CTRL = 17'h00090;
localparam [16:0] GHCI_DBG_ADDR = 17'h000A0;
localparam [16:0] GHCI_DBG_DATA = 17'h000A4;
localparam [16:0] GHCI_DBG_STATUS = 17'h000A8;
localparam [16:0] GHCI_EXTCAP_LIST = 17'h00100;	/* where EXTCAP points */
localparam [16:0] GHCI_PERF_SRC0 = 17'h00110;	/* the PERF capability's registers */
localparam [16:0] GHCI_CPFW_CTRL = 17'h00120;	/* the CPFW capability (id 6), p017 */
localparam [16:0] GHCI_CPFW_STATUS = 17'h00124;
localparam [16:0] GHCI_CPFW_IBASE = 17'h00128;
localparam [16:0] GHCI_CPFW_IWORDS = 17'h0012C;
localparam [16:0] GHCI_CPFW_DBASE = 17'h00130;
localparam [16:0] GHCI_CPFW_DWORDS = 17'h00134;
localparam [16:0] GHCI_CPFW_VERSION = 17'h00138;
localparam [16:0] GHCI_CPFW_MBOX0 = 17'h00150;	/* MBOX0-3, after SA's 0x140-0x14F */
localparam [16:0] GHCI_KICK = 17'h00F00;
localparam [16:0] GHCI_STATE_BASE = 17'h01000;	/* STATE[0..511] */
localparam [16:0] GHCI_DISP_KC705 = 17'h10000;	/* DC registers on the KC705 */

/* CPFW_CTRL and CPFW_STATUS bits. */
localparam GHCI_CPFW_CTRL_LOAD = 0;
localparam GHCI_CPFW_CTRL_RUN = 1;
localparam GHCI_CPFW_CTRL_HALT = 2;
localparam GHCI_CPFW_STATUS_READY = 0;
localparam GHCI_CPFW_STATUS_FAULT = 1;
localparam GHCI_CPFW_STATUS_ALIVE = 2;

/* CTRL bits. */
localparam GHCI_CTRL_RUN = 0;
localparam GHCI_CTRL_RESET = 1;
localparam GHCI_CTRL_HALT = 2;
localparam GHCI_CTRL_STEP = 3;
localparam GHCI_CTRL_WDT_EN = 4;

/* STATUS bits. */
localparam GHCI_STATUS_CP_BUSY = 0;
localparam GHCI_STATUS_BLT_BUSY = 1;
localparam GHCI_STATUS_VF_BUSY = 2;
localparam GHCI_STATUS_RX_BUSY = 3;
localparam GHCI_STATUS_ROP_BUSY = 4;
localparam GHCI_STATUS_TU_BUSY = 5;
localparam GHCI_STATUS_SU_BUSY = 6;
localparam GHCI_STATUS_AXI_IDLE = 8;
localparam GHCI_STATUS_FAULT = 9;
localparam GHCI_STATUS_HALTED = 10;
localparam GHCI_STATUS_RING_EMPTY = 11;
localparam GHCI_STATUS_MEM_READY = 12;
localparam GHCI_STATUS_AXI_STUCK = 13;
localparam GHCI_STATUS_QUIESCED = 14;
localparam GHCI_STATUS_STATE = 16;	/* [19:16] */

/* CP states (STATUS[19:16]). */
localparam [3:0] GHCI_ST_IDLE = 4'd0;
localparam [3:0] GHCI_ST_RUNNING = 4'd1;
localparam [3:0] GHCI_ST_HALTING = 4'd2;
localparam [3:0] GHCI_ST_HALTED = 4'd3;
localparam [3:0] GHCI_ST_FAULTED = 4'd4;
localparam [3:0] GHCI_ST_RESETTING = 4'd5;

/* IRQ_STATUS / IRQ_ENABLE bits. */
localparam GHCI_IRQ_FENCE = 0;
localparam GHCI_IRQ_FAULT = 1;
localparam GHCI_IRQ_RING_EMPTY = 2;
localparam GHCI_IRQ_WATCHDOG = 3;
localparam GHCI_IRQ_DBG_DONE = 4;
localparam GHCI_IRQ_SOFT = 5;
localparam GHCI_IRQ_HALTED = 6;

/* FAULT_INFO[15:12] kinds. */
localparam [3:0] GHCI_FAULT_APERTURE = 4'd1;
localparam [3:0] GHCI_FAULT_OPCODE = 4'd2;
localparam [3:0] GHCI_FAULT_RING = 4'd3;
localparam [3:0] GHCI_FAULT_WATCHDOG = 4'd4;
localparam [3:0] GHCI_FAULT_AXI = 4'd5;
localparam [3:0] GHCI_FAULT_KICK = 4'd6;
localparam [3:0] GHCI_FAULT_LOCKED = 4'd7;

/* KICK bits. */
localparam GHCI_KICK_BLIT = 0;
localparam GHCI_KICK_DRAW = 1;
localparam GHCI_KICK_DISPATCH = 2;

/* STATE indices of the BLT range (0x000-0x01F). */
localparam [8:0] GHCI_S_BLT_OP = 9'h000;
localparam [8:0] GHCI_S_BLT_DST_BASE = 9'h001;
localparam [8:0] GHCI_S_BLT_DST_STRIDE = 9'h002;
localparam [8:0] GHCI_S_BLT_SRC_BASE = 9'h003;
localparam [8:0] GHCI_S_BLT_SRC_STRIDE = 9'h004;
localparam [8:0] GHCI_S_BLT_DST_XY = 9'h005;
localparam [8:0] GHCI_S_BLT_SRC_XY = 9'h006;
localparam [8:0] GHCI_S_BLT_SIZE = 9'h007;
localparam [8:0] GHCI_S_BLT_COLOR = 9'h008;
localparam [8:0] GHCI_S_BLT_CLIP_MIN = 9'h009;
localparam [8:0] GHCI_S_BLT_CLIP_MAX = 9'h00A;

/* PERF_SRCn values: what PERFn counts. */
localparam [7:0] GHCI_PERF_SRC_MEM = 8'd8;	/* memory accesses outstanding */
localparam [7:0] GHCI_PERF_SRC_NONE = 8'hFF;

/* BLT_OP[1:0] and the option bits. */
localparam GHCI_BLT_OP_BLEND = 4;
localparam GHCI_BLT_OP_BPP16 = 8;	/* [9:8] = 1 */
localparam GHCI_BLT_OP_REVERSE = 12;
localparam [1:0] GHCI_BLT_FILL = 2'd0;
localparam [1:0] GHCI_BLT_COPY = 2'd1;
localparam [1:0] GHCI_BLT_TILE = 2'd2;
localparam [1:0] GHCI_BLT_UNTILE = 2'd3;

/* Extended capability IDs. */
localparam [7:0] GHCI_XCAP_DISP = 8'd1;
localparam [7:0] GHCI_XCAP_DBG = 8'd2;
localparam [7:0] GHCI_XCAP_PERF = 8'd3;
localparam [7:0] GHCI_XCAP_VEND = 8'd4;
localparam [7:0] GHCI_XCAP_MMU = 8'd5;

/* verilator lint_on UNUSEDPARAM */
