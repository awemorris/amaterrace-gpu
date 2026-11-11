/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_regs: the GHCI register bus decoder of the CP: identification,
 * DEVICE_CAPS, extended capabilities, SCRATCH, TIMESTAMP and diagnostics,
 * plus the HCR snoop bus for other CP modules (and atg_cpu).
 *
 * Writes to valid GHCI register addresses go out on hcr_* in the cycle
 * of reg_wr. Reads: the answer is due the cycle after reg_rd; the address
 * is registered and decoded combinationally, this module ORs them with its own,
 * returning 0 elsewhere.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifdef CFG_SU_NPHYS
`define ATG_DEF_PHYS_LANES ((`CFG_SU_NPHYS == 4) ? 8'd4 : (`CFG_SU_NPHYS == 8) ? 8'd8 : (`CFG_SU_NPHYS == 16) ? 8'd16 : 8'd32)
`else
`define ATG_DEF_PHYS_LANES 8'd8
`endif

`ifdef CFG_ENABLE_FP16
`define ATG_DEF_FP16 ((`CFG_ENABLE_FP16 != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_FP16 1'b0
`endif

`ifdef CFG_CP_AUTONOMOUS_MMU
`define ATG_DEF_HW_WALKER ((`CFG_CP_AUTONOMOUS_MMU != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_HW_WALKER 1'b0
`endif

`ifdef CFG_CP_USE_RV32_CORE
`define ATG_DEF_RV32 ((`CFG_CP_USE_RV32_CORE != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_RV32 1'b0
`endif

`ifdef CFG_ROP_DUAL_SOURCE
`define ATG_DEF_DUAL_SRC ((`CFG_ROP_DUAL_SOURCE != 0) ? 1'b1 : 1'b0)
`elsif defined(CFG_ENABLE_DUAL_SOURCE)
`define ATG_DEF_DUAL_SRC ((`CFG_ENABLE_DUAL_SOURCE != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_DUAL_SRC 1'b0
`endif

`ifdef CFG_ENABLE_MESH
`define ATG_DEF_MESH ((`CFG_ENABLE_MESH != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_MESH 1'b0
`endif

`ifdef CFG_ENABLE_SUBGROUP
`define ATG_DEF_SUBGROUP ((`CFG_ENABLE_SUBGROUP != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_SUBGROUP 1'b0
`endif

`ifdef CFG_ENABLE_SA
`define ATG_DEF_SA ((`CFG_ENABLE_SA != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_SA 1'b0
`endif

`ifdef CFG_ENABLE_TRILINEAR
`define ATG_DEF_TRILINEAR ((`CFG_ENABLE_TRILINEAR != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_TRILINEAR 1'b0
`endif

`ifdef CFG_ENABLE_MSAA
`define ATG_DEF_MSAA ((`CFG_ENABLE_MSAA != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_MSAA 1'b0
`endif

`ifdef CFG_ENABLE_BC
`define ATG_DEF_BC ((`CFG_ENABLE_BC != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_BC 1'b0
`endif

`ifdef CFG_ROP_ENABLE_LOGICOP
`define ATG_DEF_LOGICOP ((`CFG_ROP_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0)
`elsif defined(CFG_ENABLE_LOGICOP)
`define ATG_DEF_LOGICOP ((`CFG_ENABLE_LOGICOP != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_LOGICOP 1'b0
`endif

`ifdef CFG_ENABLE_EARLY_Z
`define ATG_DEF_EARLY_Z ((`CFG_ENABLE_EARLY_Z != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_EARLY_Z 1'b0
`endif

`ifdef CFG_DC_ENABLE_CURSOR
`define ATG_DEF_CURSOR ((`CFG_DC_ENABLE_CURSOR != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_CURSOR 1'b0
`endif

`ifdef CFG_ROP_MRT_COUNT
`define ATG_DEF_MRT_COUNT ((`CFG_ROP_MRT_COUNT == 8) ? 4'd8 : (`CFG_ROP_MRT_COUNT == 4) ? 4'd4 : (`CFG_ROP_MRT_COUNT == 2) ? 4'd2 : 4'd1)
`else
`define ATG_DEF_MRT_COUNT 4'd1
`endif

`ifdef CFG_COARSE_SCAN
`define ATG_DEF_COARSE_SCAN ((`CFG_COARSE_SCAN != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_COARSE_SCAN 1'b0
`endif

`ifdef CFG_ROP_FAST_CLEAR
`define ATG_DEF_FAST_CLEAR ((`CFG_ROP_FAST_CLEAR != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_FAST_CLEAR 1'b0
`endif

`ifdef CFG_RX_ENABLE_CPOLY
`define ATG_DEF_CLIP_POLY ((`CFG_RX_ENABLE_CPOLY != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_CLIP_POLY 1'b1
`endif

`ifdef CFG_HAS_BLT
`define ATG_DEF_HAS_BLT ((`CFG_HAS_BLT != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_HAS_BLT 1'b1
`endif

`ifdef CFG_BLT_ENABLE_SCALE
`define ATG_DEF_BLT_SCALE ((`ATG_DEF_HAS_BLT && (`CFG_BLT_ENABLE_SCALE != 0)) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_BLT_SCALE `ATG_DEF_HAS_BLT
`endif

`ifdef CFG_BLT_ENABLE_BLEND
`define ATG_DEF_BLT_BLEND ((`ATG_DEF_HAS_BLT && (`CFG_BLT_ENABLE_BLEND != 0)) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_BLT_BLEND `ATG_DEF_HAS_BLT
`endif

`ifdef CFG_BLT_ENABLE_TILE
`define ATG_DEF_BLT_TILE ((`ATG_DEF_HAS_BLT && (`CFG_BLT_ENABLE_TILE != 0)) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_BLT_TILE `ATG_DEF_HAS_BLT
`endif

`ifdef CFG_TU_ENABLE_BILINEAR
`define ATG_DEF_TU_BILINEAR ((`CFG_TU_ENABLE_BILINEAR != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_TU_BILINEAR 1'b1
`endif

`ifdef CFG_HAS_DISP
`define ATG_DEF_DISP ((`CFG_HAS_DISP != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_DISP 1'b1
`endif

`ifdef CFG_ENABLE_TASK
`define ATG_DEF_TASK ((`CFG_ENABLE_TASK != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_TASK 1'b0
`endif

`ifdef CFG_ROP_ENABLE_PACK
`define ATG_DEF_ROP_PACK ((`CFG_ROP_ENABLE_PACK != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_ROP_PACK 1'b0
`endif

`ifdef CFG_TU_ENABLE_FFILT
`define ATG_DEF_FFILT ((`CFG_TU_ENABLE_FFILT != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_FFILT 1'b0
`endif

`ifdef CFG_MC_ENABLE_PROT
`define ATG_DEF_PROT ((`CFG_MC_ENABLE_PROT != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_PROT 1'b0
`endif

`ifdef CFG_HAS_INDIRECT_DRAW
`define ATG_DEF_INDIRECT_DRAW ((`CFG_HAS_INDIRECT_DRAW != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_INDIRECT_DRAW 1'b0
`endif

`ifdef CFG_HAS_SECONDARY_RING
`define ATG_DEF_SECONDARY_RING ((`CFG_HAS_SECONDARY_RING != 0) ? 1'b1 : 1'b0)
`else
`define ATG_DEF_SECONDARY_RING 1'b0
`endif

`define ATG_DEF_COLOR_LUT 1'b0
`define ATG_DEF_MRT_BLEND ((`ATG_DEF_MRT_COUNT >= 4'd2) ? 1'b1 : 1'b0)

`ifdef CFG_SU_LDS_KB
`define ATG_DEF_LDS_KB 8'd`CFG_SU_LDS_KB
`else
`define ATG_DEF_LDS_KB 8'd0
`endif

`ifdef CFG_HOST_PA_BITS
`define ATG_DEF_PA_BITS_ENC ((`CFG_HOST_PA_BITS == 48) ? 4'h8 : 4'h0)
`else
`define ATG_DEF_PA_BITS_ENC 4'h0
`endif

`ifdef CFG_GPU_VA_BITS
`define ATG_DEF_VA_BITS_ENC ((`CFG_GPU_VA_BITS == 40) ? 4'hA : (`CFG_GPU_VA_BITS == 32) ? 4'h2 : 4'h0)
`else
`define ATG_DEF_VA_BITS_ENC 4'h0
`endif

`define ATG_DEF_DEVICE_CAPS { \
	`ATG_DEF_MSAA, `ATG_DEF_DISP, `ATG_DEF_HAS_BLT, `ATG_DEF_MESH, `ATG_DEF_TASK, \
	`ATG_DEF_ROP_PACK, `ATG_DEF_FFILT, `ATG_DEF_PROT, \
	8'd1, `ATG_DEF_PHYS_LANES, \
	1'b1, `ATG_DEF_FP16, `ATG_DEF_DUAL_SRC, `ATG_DEF_SECONDARY_RING, `ATG_DEF_INDIRECT_DRAW, `ATG_DEF_HW_WALKER, 1'b0, 1'b0 \
}

`define ATG_DEF_LANES_LOG2 ( \
	(`ATG_DEF_PHYS_LANES == 8'd4)  ? 4'd2 : \
	(`ATG_DEF_PHYS_LANES == 8'd8)  ? 4'd3 : \
	(`ATG_DEF_PHYS_LANES == 8'd16) ? 4'd4 : \
	(`ATG_DEF_PHYS_LANES == 8'd32) ? 4'd5 : 4'd3 \
)

`define ATG_DEF_CAPS { \
	1'b0, 1'b0, `ATG_DEF_MSAA, `ATG_DEF_FP16, 1'b1, `ATG_DEF_TRILINEAR, `ATG_DEF_SA, `ATG_DEF_SUBGROUP, \
	4'd6, 1'b0, 1'b0, `ATG_DEF_RV32, `ATG_DEF_HW_WALKER, 4'd0, 1'b0, 1'b0, \
	1'b1, 1'b1, `ATG_DEF_LANES_LOG2, 1'b1, 1'b1, 1'b1, 1'b1 \
}

`define ATG_DEF_EXT_CAP_FMT0 { \
	13'd0, `ATG_DEF_BLT_TILE, `ATG_DEF_BLT_BLEND, `ATG_DEF_TU_BILINEAR, `ATG_DEF_MRT_COUNT, 2'b00, 1'b1, 2'b00, `ATG_DEF_BC, 1'b0, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC \
}

`define ATG_DEF_EXT_CAP_FEATURE { \
	`ATG_DEF_BLT_SCALE, `ATG_DEF_CLIP_POLY, `ATG_DEF_SUBGROUP, `ATG_DEF_FP16, `ATG_DEF_LDS_KB, `ATG_DEF_MRT_COUNT, \
	`ATG_DEF_MRT_BLEND, `ATG_DEF_COLOR_LUT, `ATG_DEF_CURSOR, `ATG_DEF_EARLY_Z, `ATG_DEF_LOGICOP, `ATG_DEF_FAST_CLEAR, `ATG_DEF_COARSE_SCAN, `ATG_DEF_DUAL_SRC, \
	`ATG_DEF_PA_BITS_ENC, `ATG_DEF_VA_BITS_ENC \
}

module atg_cp_regs #(
	parameter GCLK_HZ = 32'd200000000,	/* GCLK_HZ register */
	parameter VENDOR_ID = 32'h414D4154,	/* "AMAT" */
	parameter DEVICE_ID = 32'h41544731,	/* "ATG1" */
	parameter DEVICE_VERSION = 32'h00000002,	/* Implementation version */
	parameter ISA_ID = 32'h47534931,	/* "GSI1"; 0 when there is no SU */
	parameter NATIVE_ISA_ID = 32'h47534931,	/* NATIVE_ISA_ID (0x048) */
	parameter [15:0] RESIDENT_WARPS = 16'd0,	/* RESIDENT_WARPS (0x04C) [15:0]: warps run at once over the SUs */
	parameter [7:0] NREGS = 8'd0,	/* RESIDENT_WARPS [23:16]: general registers per lane (0: no SU) */
	parameter [31:0] LOCAL_BASE = 32'd0,	/* MEM: GPU address of local memory */
	parameter [31:0] LOCAL_BYTES = 32'd0,	/* MEM: bytes of local memory */
	parameter [31:0] WINDOW_BYTES = 32'd0,	/* MEM: bytes the local window shows */
	parameter [31:0] HOST_LIMIT = 32'd0,	/* MEM: host addresses below it (0: all) */
	parameter [3:0] MRT_COUNT = 4'd1,
	parameter HAS_INDIRECT_DRAW = 0,
	parameter HAS_SECONDARY_RING = 0,
	parameter [31:0] DEVICE_CAPS = 32'd0,	/* 0: dynamic from config macros */
	parameter CAPS = 32'h00500002,	/* CAPS value (design §2.2), set by atg_top from its parameters */
	parameter CAPS2 = 32'h00000003,	/* CAPS2 value: [7:0] = 3 independent queues (Graphics, Compute, Copy/DMA) */
	parameter [31:0] EXT_CAP_FMT0 = `ATG_DEF_EXT_CAP_FMT0,
	parameter [31:0] EXT_CAP_FEATURE = `ATG_DEF_EXT_CAP_FEATURE,
	parameter VEND = 256'd0,	/* The 8 VEND words (0x0C0-0x0DF), word 0 in bits 31:0 */
	parameter [10:0] XCAP_MASK = 11'h004,	/* Which extended capabilities are listed: bit id-1 (DISP 1, DBG 2, PERF 3, VEND 4, CPFW 6, SA 7, MEM 8, PROT 9, FMT 10, DISP2 11) */
	parameter DISP_OFFSET = 32'h00010000,	/* Where the DISP entry points (KC705 +0x10000) */
	parameter PERF_SRC = 32'hFFFFFFFF	/* PERF_SRC0..3 (byte n = PERF_SRCn) */
) (
	input wire clk,
	input wire rst_n,
	/* Register bus (from am_axi_regs or am_jtag_regs) */
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,
	/* HCR snoop bus (to the other CP modules and atg_cpu) */
	output wire hcr_we,
	output wire [9:0] hcr_widx,
	output wire [31:0] hcr_wdata,
	output wire [31:0] hcr_wmask,
	output wire [9:0] hcr_ridx,
	/* STATE alias (0x1000-0x1BFC, to atg_cp_state) */
	output wire alias_we,
	output wire [9:0] alias_idx,
	output wire [9:0] alias_ridx,
	/* Read data of the other modules (0 outside their registers) */
	input wire [31:0] ctl_rdata,
	input wire [31:0] irq_rdata,
	input wire [31:0] ring_rdata,
	input wire [31:0] fence_rdata,
	input wire [31:0] dbg_rdata,
	input wire [31:0] state_rdata,
	input wire [31:0] x_rdata,
	/* PERF */
	input wire [3:0] perf_busy,
	input wire perf_reset,
	/* MEM: WINDOW_CTRL.ENABLE, the local window is open (to the board's window path) */
	output wire win_en,
	/* Diagnostics (0x074, 0x078, 0x07C) */
	input wire [31:0] diag_cp_pc,
	input wire [31:0] diag_cp_status,
	input wire [31:0] diag_pipe_fsm
);
	`include "ghci_regs.vh"

	localparam [9:0] I_SCRATCH = GHCI_SCRATCH[11:2];
	localparam [9:0] I_PERF_CTRL = GHCI_PERF_CTRL[11:2];
	localparam [11:0] MEM_OFF = 12'h1E0;	/* the MEM capability's registers */
	localparam [11:0] A_LOCAL_BASE = MEM_OFF + GHCI_MEM_LOCAL_BASE[11:0];
	localparam [11:0] A_LOCAL_SIZE = MEM_OFF + GHCI_MEM_LOCAL_SIZE[11:0];
	localparam [11:0] A_WINDOW_SIZE = MEM_OFF + GHCI_MEM_WINDOW_SIZE[11:0];
	localparam [11:0] A_HOST_LIMIT = MEM_OFF + GHCI_MEM_HOST_LIMIT[11:0];
	localparam [11:0] A_WINDOW_CTRL = MEM_OFF + GHCI_MEM_WINDOW_CTRL[11:0];
	localparam [9:0] I_WINDOW_CTRL = A_WINDOW_CTRL[11:2];
	localparam [0:0] HAS_WINDOW = XCAP_MASK[7] && WINDOW_BYTES != 32'd0;

	function [9:0] hcr_reg_widx;
		input [16:0] addr;
		case (addr)
		GHCI_REG_CTRL:          hcr_reg_widx = HCR_IDX_CTRL;
		GHCI_REG_FAULT_INFO:    hcr_reg_widx = HCR_IDX_FAULT_INFO;
		GHCI_REG_RING_BASE_LO:  hcr_reg_widx = HCR_IDX_RING_BASE_LO;
		GHCI_REG_RING_BASE_HI:  hcr_reg_widx = HCR_IDX_RING_BASE_HI;
		GHCI_REG_RING_SIZE:     hcr_reg_widx = HCR_IDX_RING_SIZE;
		GHCI_REG_RING_WPTR:     hcr_reg_widx = HCR_IDX_RING_WPTR;
		GHCI_REG_IRQ_STATUS:    hcr_reg_widx = HCR_IDX_IRQ_STATUS;
		GHCI_REG_IRQ_ENABLE:    hcr_reg_widx = HCR_IDX_IRQ_ENABLE;
		GHCI_REG_IRQ_SET:       hcr_reg_widx = HCR_IDX_IRQ_SET;
		GHCI_REG_SCRATCH:       hcr_reg_widx = HCR_IDX_SCRATCH;
		GHCI_REG_WDT_CYCLES:    hcr_reg_widx = HCR_IDX_WDT_CYCLES;
		GHCI_REG_CP_HEAP_BASE:  hcr_reg_widx = HCR_IDX_CP_HEAP_BASE;
		GHCI_REG_CP_HEAP_LIMIT: hcr_reg_widx = HCR_IDX_CP_HEAP_LIMIT;
		default:                hcr_reg_widx = (addr >= 17'h00140 && addr <= 17'h003FF) ? addr[11:2] : HCR_IDX_INVALID;
		endcase
	endfunction

	wire hcr_we_ok = (reg_waddr == GHCI_REG_CTRL) ||
	                  (reg_waddr == GHCI_REG_FAULT_INFO) ||
	                  (reg_waddr == GHCI_REG_IRQ_STATUS) ||
	                  (reg_waddr == GHCI_REG_IRQ_ENABLE) ||
	                  (reg_waddr == GHCI_REG_IRQ_SET) ||
	                  (reg_waddr == GHCI_REG_RING_BASE_LO) ||
	                  (reg_waddr == GHCI_REG_RING_BASE_HI) ||
	                  (reg_waddr == GHCI_REG_RING_SIZE) ||
	                  (reg_waddr == GHCI_REG_RING_WPTR) ||
	                  (reg_waddr == GHCI_REG_WDT_CYCLES) ||
	                  (reg_waddr == GHCI_REG_CP_HEAP_BASE) ||
	                  (reg_waddr == GHCI_REG_CP_HEAP_LIMIT) ||
	                  (reg_waddr >= 17'h00140 && reg_waddr <= 17'h003FF);

	/* Writes. */
	assign hcr_we = reg_wr && hcr_we_ok;
	assign hcr_widx = hcr_reg_widx(reg_waddr);
	assign hcr_wdata = reg_wdata;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire regs_rst_high;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_regs_rst (.I0(rst_n), .O(regs_rst_high));

	wire [3:0] reg_wstrb_m;
	wire [31:0] hcr_wmask_b;
	genvar g_sb, g_sbit;
	generate
		for (g_sb = 0; g_sb < 4; g_sb = g_sb + 1) begin : g_sb_gen
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sb (.I0(reg_wstrb[g_sb]), .O(reg_wstrb_m[g_sb]));
			for (g_sbit = 0; g_sbit < 8; g_sbit = g_sbit + 1) begin : g_sbit_gen
				(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sbit (.I0(reg_wstrb_m[g_sb]), .O(hcr_wmask_b[g_sb*8 + g_sbit]));
			end
		end
	endgenerate
	assign hcr_wmask = hcr_wmask_b;
`else
	assign hcr_wmask = {{8{reg_wstrb[3]}}, {8{reg_wstrb[2]}}, {8{reg_wstrb[1]}}, {8{reg_wstrb[0]}}};
`endif
	/* 0x1000-0x1BFC: STATE[0..0x2FF]. Eliminated in GHCI 1.0. */
	assign alias_we = 1'b0;
	assign alias_idx = 10'd0;
	assign alias_ridx = 10'd0;

	wire is_scratch_wr = (reg_wr && reg_waddr == GHCI_REG_SCRATCH);

	reg [31:0] scratch;
	reg win_q;
	reg [31:0] counter;
	reg [31:0] counter_hi;
	reg [127:0] perf;	/* PERF0..3, PERFn in bits 32n+31:32n */
	wire perf_clear_raw = perf_reset ||
		(hcr_we && hcr_widx == I_PERF_CTRL && reg_wstrb[0] && hcr_wdata[0]);
`ifdef SYNTH_KINTEX7
	wire [1:0] scratch_we_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_scwe0 (.I0(is_scratch_wr), .O(scratch_we_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_scwe1 (.I0(is_scratch_wr), .O(scratch_we_b[1]));

	(* keep = "true", dont_touch = "true" *) wire [7:0] perf_rst_b;
	genvar g_pc;
	generate
		for (g_pc = 0; g_pc < 8; g_pc = g_pc + 1) begin : g_perf_clr
			(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hE)) u_pc (.I0(regs_rst_high), .I1(perf_clear_raw), .O(perf_rst_b[g_pc]));
		end
	endgenerate
	wire perf_clear = perf_clear_raw;
`else
	wire perf_clear = perf_clear_raw;
`endif
	integer i;

	/* COUNTER + 1 and PERFn + busy: one incrementer each. */
	wire [31:0] counter_n;
	wire [31:0] counter_hi_n;
	wire counter_hi_co;
	wire [127:0] perf_n;
	wire [4:0] inc_co;

	am_add #(.W(32)) counter_add (
		.a(counter), .b(32'd0), .ci(1'b1), .s(counter_n), .co(inc_co[4])
	);
	am_add #(.W(32)) counter_hi_add (
		.a(counter_hi), .b(32'd0), .ci(inc_co[4]), .s(counter_hi_n), .co(counter_hi_co)
	);

	genvar g;
	generate
		for (g = 0; g < 4; g = g + 1) begin : perf_inc
			am_add #(.W(32)) perf_add (
				.a(perf[g*32 +: 32]), .b(32'd0), .ci(perf_busy[g]), .s(perf_n[g*32 +: 32]),
				.co(inc_co[g])
			);
		end
	endgenerate

	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		if (regs_rst_high) begin
			scratch <= 32'd0;
			counter <= 32'd0;
			counter_hi <= 32'd0;
			win_q <= HAS_WINDOW;
		end else begin
			counter <= counter_n;
			counter_hi <= counter_hi_n;
			if (scratch_we_b[0])
				scratch[15:0] <= (scratch[15:0] & ~hcr_wmask[15:0]) | (hcr_wdata[15:0] & hcr_wmask[15:0]);
			if (scratch_we_b[1])
				scratch[31:16] <= (scratch[31:16] & ~hcr_wmask[31:16]) | (hcr_wdata[31:16] & hcr_wmask[31:16]);
			if (HAS_WINDOW && hcr_we && hcr_widx == I_WINDOW_CTRL && reg_wstrb[0])
				win_q <= hcr_wdata[0];
		end
		for (i = 0; i < 8; i = i + 1)
			if (perf_rst_b[i])
				perf[i * 16 +: 16] <= 16'd0;
			else
				perf[i * 16 +: 16] <= perf_n[i * 16 +: 16];
`else
		if (!rst_n) begin
			scratch <= 32'd0;
			counter <= 32'd0;
			counter_hi <= 32'd0;
			win_q <= HAS_WINDOW;
		end else begin
			counter <= counter_n;
			counter_hi <= counter_hi_n;
			if (is_scratch_wr)
				scratch <= (scratch & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (HAS_WINDOW && hcr_we && hcr_widx == I_WINDOW_CTRL && reg_wstrb[0])
				win_q <= hcr_wdata[0];
		end
		for (i = 0; i < 4; i = i + 1)
			if (!rst_n || perf_clear)
				perf[i * 32 +: 32] <= 32'd0;
			else
				perf[i * 32 +: 32] <= perf_n[i * 32 +: 32];
`endif
	end

	function [9:0] hcr_reg_ridx;
		input [16:0] addr;
		case (addr)
		GHCI_REG_MAGIC:          hcr_reg_ridx = HCR_IDX_MAGIC;
		GHCI_REG_VERSION:        hcr_reg_ridx = HCR_IDX_VERSION;
		GHCI_REG_DEVICE_CAPS:    hcr_reg_ridx = HCR_IDX_DEVICE_CAPS;
		GHCI_REG_EXTCAP_PTR:     hcr_reg_ridx = HCR_IDX_EXTCAP_PTR;
		GHCI_REG_STATUS:         hcr_reg_ridx = HCR_IDX_STATUS;
		GHCI_REG_CTRL:           hcr_reg_ridx = HCR_IDX_CTRL;
		GHCI_REG_FAULT_INFO:     hcr_reg_ridx = HCR_IDX_FAULT_INFO;
		GHCI_REG_FAULT_ADDR_LO:  hcr_reg_ridx = HCR_IDX_FAULT_ADDR_LO;
		GHCI_REG_FAULT_ADDR_HI:  hcr_reg_ridx = HCR_IDX_FAULT_ADDR_HI;
		GHCI_REG_RING_BASE_LO:   hcr_reg_ridx = HCR_IDX_RING_BASE_LO;
		GHCI_REG_RING_BASE_HI:   hcr_reg_ridx = HCR_IDX_RING_BASE_HI;
		GHCI_REG_RING_SIZE:      hcr_reg_ridx = HCR_IDX_RING_SIZE;
		GHCI_REG_RING_WPTR:      hcr_reg_ridx = HCR_IDX_RING_WPTR;
		GHCI_REG_RING_RPTR:      hcr_reg_ridx = HCR_IDX_RING_RPTR;
		GHCI_REG_IRQ_STATUS:     hcr_reg_ridx = HCR_IDX_IRQ_STATUS;
		GHCI_REG_IRQ_ENABLE:     hcr_reg_ridx = HCR_IDX_IRQ_ENABLE;
		GHCI_REG_IRQ_SET:        hcr_reg_ridx = HCR_IDX_IRQ_SET;
		GHCI_REG_SCRATCH:        hcr_reg_ridx = HCR_IDX_SCRATCH;
		GHCI_REG_WDT_CYCLES:     hcr_reg_ridx = HCR_IDX_WDT_CYCLES;
		GHCI_REG_RESIDENT_WARPS: hcr_reg_ridx = HCR_IDX_RESIDENT_WARPS;
		GHCI_REG_CP_HEAP_BASE:   hcr_reg_ridx = HCR_IDX_CP_HEAP_BASE;
		GHCI_REG_CP_HEAP_LIMIT:  hcr_reg_ridx = HCR_IDX_CP_HEAP_LIMIT;
		GHCI_REG_SESSION_ACTIVE: hcr_reg_ridx = HCR_IDX_SESSION_ACTIVE;
		GHCI_REG_TIMESTAMP_LO:   hcr_reg_ridx = HCR_IDX_TIMESTAMP_LO;
		GHCI_REG_TIMESTAMP_HI:   hcr_reg_ridx = HCR_IDX_TIMESTAMP_HI;
		GHCI_REG_GCLK_HZ:        hcr_reg_ridx = HCR_IDX_GCLK_HZ;
		GHCI_REG_NATIVE_ISA_ID:  hcr_reg_ridx = HCR_IDX_NATIVE_ISA_ID;
		GHCI_REG_DIAG_CP_PC:     hcr_reg_ridx = HCR_IDX_DIAG_CP_PC;
		GHCI_REG_DIAG_CP_STATUS: hcr_reg_ridx = HCR_IDX_DIAG_CP_STATUS;
		GHCI_REG_EXT_CAP_FMT0:   hcr_reg_ridx = HCR_IDX_EXT_CAP_FMT0;
		GHCI_REG_EXT_CAP_FEATURE:hcr_reg_ridx = HCR_IDX_EXT_CAP_FEATURE;
		default:                 hcr_reg_ridx = (addr >= 17'h00100 && addr <= 17'h003FF) ? addr[11:2] : HCR_IDX_INVALID;
		endcase
	endfunction

	/* Reads: the registered index, answered the next cycle. */
	(* max_fanout = 12 *) reg [9:0] ridx_q;
	reg [16:0] raddr_q;
	reg rd_hcr_q;
	reg rd_state_q;

`ifdef SYNTH_KINTEX7
	wire [3:0] reg_rd_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb0 (.I0(reg_rd), .O(reg_rd_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb1 (.I0(reg_rd), .O(reg_rd_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb2 (.I0(reg_rd), .O(reg_rd_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb3 (.I0(reg_rd), .O(reg_rd_b[3]));

	wire [16:0] raddr_b0;
	wire [11:2] raddr_b1_lo, raddr_b1_hi;
	genvar g_ra;
	generate
		for (g_ra = 0; g_ra < 17; g_ra = g_ra + 1) begin : g_raddr_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rab0 (.I0(reg_raddr[g_ra]), .O(raddr_b0[g_ra]));
		end
		for (g_ra = 2; g_ra < 12; g_ra = g_ra + 1) begin : g_raddr_b1_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rab1l (.I0(reg_raddr[g_ra]), .O(raddr_b1_lo[g_ra]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rab1h (.I0(reg_raddr[g_ra]), .O(raddr_b1_hi[g_ra]));
		end
	endgenerate

	wire [9:0] ridx_next = hcr_reg_ridx(raddr_b0);
	wire rd_hcr_next = (ridx_next != HCR_IDX_INVALID);
	reg rd_hcr_lo_q, rd_hcr_hi_q;

	always @(posedge clk) begin
		if (regs_rst_high) begin
			ridx_q <= 10'd0;
			raddr_q <= 17'd0;
			rd_hcr_q <= 1'b0;
			rd_hcr_lo_q <= 1'b0;
			rd_hcr_hi_q <= 1'b0;
			rd_state_q <= 1'b0;
		end else begin
			if (reg_rd_b[0]) raddr_q <= raddr_b0;
			if (reg_rd_b[1]) ridx_q <= ridx_next;
			if (reg_rd_b[2]) begin
				rd_hcr_q <= rd_hcr_next;
				rd_hcr_lo_q <= rd_hcr_next && (ridx_next[9:6] == 4'd0);
				rd_hcr_hi_q <= rd_hcr_next && (ridx_next[9:6] != 4'd0);
			end
			if (reg_rd_b[3]) rd_state_q <= 1'b0;
		end
	end
`else
	always @(posedge clk) begin
		if (!rst_n) begin
			ridx_q <= 10'd0;
			raddr_q <= 17'd0;
			rd_hcr_q <= 1'b0;
			rd_state_q <= 1'b0;
		end else if (reg_rd) begin
			raddr_q <= reg_raddr;
			ridx_q <= hcr_reg_ridx(reg_raddr);
			rd_hcr_q <= (hcr_reg_ridx(reg_raddr) != HCR_IDX_INVALID);
			rd_state_q <= 1'b0;
		end
	end
`endif

	assign hcr_ridx = ridx_q;
	assign win_en = win_q;

	/* The extended capability list: entry k's byte offset. */
	function integer xcap_off;
		input integer k;
		xcap_off = 256 + k * 8;
	endfunction

	function [31:0] xcap_ptr;
		input integer id;
		case (id)
		1: xcap_ptr = DISP_OFFSET;
		2: xcap_ptr = 32'd0;
		3: xcap_ptr = 32'h00000160;
		4: xcap_ptr = 32'h00000180;
		6: xcap_ptr = 32'h00000170;
		7: xcap_ptr = 32'h00000140;
		8: xcap_ptr = {20'd0, MEM_OFF};
		9: xcap_ptr = 32'h000001D0;	/* PROT: atg_cp_prot answers its registers */
		10: xcap_ptr = 32'h00000140;
		11: xcap_ptr = {15'd0, GHCI_DISP2_BASE};
		default: xcap_ptr = 32'd0;
		endcase
	endfunction

	/* The list word at byte offset off (0 if none). */
	function [31:0] xcap_word;
		input [11:0] off;
		integer id, id2, k, k2, o;
		reg [15:0] nxt;
		begin
			xcap_word = 32'd0;
			o = {20'd0, off};
			k = 0;
			for (id = 1; id <= 11; id = id + 1)
				if (XCAP_MASK[id - 1]) begin
					/* The next entry, in dwords from this one. */
					nxt = 16'd0;
					k2 = k + 1;
					for (id2 = 11; id2 > id; id2 = id2 - 1)
						if (XCAP_MASK[id2 - 1])
							/* verilator lint_off WIDTHTRUNC */
							nxt = (xcap_off(k2) - xcap_off(k)) / 4;	/* < 2^16 */
							/* verilator lint_on WIDTHTRUNC */
					if (o == xcap_off(k))
						xcap_word = {nxt, 8'd1, id[7:0]};
					if (o == xcap_off(k) + 4)
						xcap_word = xcap_ptr(id);
					k = k + 1;
				end
		end
	endfunction

	wire [31:0] def_fmt0 = `ATG_DEF_EXT_CAP_FMT0;
	wire [31:0] def_feat = `ATG_DEF_EXT_CAP_FEATURE;
	wire [31:0] eff_dev_caps = (DEVICE_CAPS != 32'd0) ? DEVICE_CAPS : `ATG_DEF_DEVICE_CAPS;
	wire [31:0] eff_caps = (CAPS != 32'h00500002) ? CAPS : `ATG_DEF_CAPS;
	wire [31:0] eff_fmt0 = (EXT_CAP_FMT0 != 32'd0) ? EXT_CAP_FMT0 :
		{def_fmt0[31:16], MRT_COUNT, def_fmt0[11:0]};
	wire [31:0] eff_feat = (EXT_CAP_FEATURE != 32'd0) ? EXT_CAP_FEATURE :
		{def_feat[31:20], MRT_COUNT, (MRT_COUNT >= 4'd2 ? 1'b1 : 1'b0), def_feat[14:0]};

	reg [31:0] own;
	wire [11:0] roff = {ridx_q, 2'b00};

	always @(*) begin
		own = 32'd0;
		case (raddr_q)
		GHCI_REG_MAGIC: own = GHCI_MAGIC_VALUE;
		GHCI_REG_VERSION: own = 32'h00010000;
		GHCI_REG_DEVICE_CAPS: own = eff_dev_caps;
		GHCI_REG_EXTCAP_PTR: own = (XCAP_MASK != 11'd0) ? 32'h00000100 : 32'd0;
		GHCI_REG_FAULT_ADDR_HI: own = 32'd0;
		GHCI_REG_RING_BASE_HI: own = 32'd0;
		GHCI_REG_SCRATCH: own = scratch;
		GHCI_REG_RESIDENT_WARPS: own = {8'd0, NREGS, RESIDENT_WARPS};
		GHCI_REG_SESSION_ACTIVE: own = 32'h00000001;
		GHCI_REG_TIMESTAMP_LO: own = counter;
		GHCI_REG_TIMESTAMP_HI: own = counter_hi;
		GHCI_REG_GCLK_HZ: own = GCLK_HZ;
		GHCI_REG_NATIVE_ISA_ID: own = 32'h47534931;
		GHCI_REG_DIAG_CP_PC: own = diag_cp_pc;
		GHCI_REG_DIAG_CP_STATUS: own = diag_cp_status;
		GHCI_REG_EXT_CAP_FMT0: own = eff_fmt0;
		GHCI_REG_EXT_CAP_FEATURE: own = eff_feat;
		17'h00160: own = {24'd0, PERF_SRC[7:0]};
		17'h00164: own = {24'd0, PERF_SRC[15:8]};
		17'h00168: own = {24'd0, PERF_SRC[23:16]};
		17'h0016C: own = {24'd0, PERF_SRC[31:24]};
		17'h00180: own = VENDOR_ID;
		17'h00184: own = DEVICE_ID;
		17'h00190: own = GCLK_HZ;
		default: own = (raddr_q >= 17'h00100) ? xcap_word(roff) : 32'd0;
		endcase
	end

`ifdef SYNTH_KINTEX7
	wire [11:0] roff_pre_lo = {raddr_b1_lo[11:2], 2'b00};
	wire [11:0] roff_pre_hi = {raddr_b1_hi[11:2], 2'b00};
	wire [11:0] roff_sel_in = {reg_raddr[11:2], 2'b00};
	wire sel_scr_raw = (roff_sel_in == GHCI_REG_SCRATCH[11:0]);
	wire sel_cnt_raw = (roff_sel_in == GHCI_REG_TIMESTAMP_LO[11:0]);
	wire sel_prf_raw = 1'b0;
	wire sel_pc_raw  = (roff_sel_in == GHCI_REG_DIAG_CP_PC[11:0]);
	wire sel_st_raw  = (roff_sel_in == GHCI_REG_DIAG_CP_STATUS[11:0]);
	wire sel_cnthi_raw = (roff_sel_in == GHCI_REG_TIMESTAMP_HI[11:0]);

	wire [1:0] sel_scr_b, sel_cnt_b, sel_prf_b, sel_pc_b, sel_st_b, sel_cnthi_b;
	genvar g_os;
	generate
		for (g_os = 0; g_os < 2; g_os = g_os + 1) begin : g_own_sel_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sscr (.I0(sel_scr_raw), .O(sel_scr_b[g_os]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_scnt (.I0(sel_cnt_raw), .O(sel_cnt_b[g_os]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sprf (.I0(sel_prf_raw), .O(sel_prf_b[g_os]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_spc  (.I0(sel_pc_raw),  .O(sel_pc_b[g_os]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sst  (.I0(sel_st_raw),  .O(sel_st_b[g_os]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_scnth (.I0(sel_cnthi_raw), .O(sel_cnthi_b[g_os]));
		end
	endgenerate
	wire [1:0] prf_idx_lo, prf_idx_hi;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pilo0 (.I0(reg_raddr[2]), .O(prf_idx_lo[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pilo1 (.I0(reg_raddr[3]), .O(prf_idx_lo[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pihi0 (.I0(reg_raddr[2]), .O(prf_idx_hi[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pihi1 (.I0(reg_raddr[3]), .O(prf_idx_hi[1]));

	function [31:0] calc_own_const;
		input [11:0] roff_in;
		input win_in;
		reg [31:0] v;
		begin
			v = (roff_in >= 12'h100) ? xcap_word(roff_in) : 32'd0;
			case ({5'd0, roff_in})
			GHCI_REG_MAGIC: v = GHCI_MAGIC_VALUE;
			GHCI_REG_VERSION: v = 32'h00010000;
			GHCI_REG_DEVICE_CAPS: v = eff_dev_caps;
			GHCI_REG_EXTCAP_PTR: v = (XCAP_MASK != 11'd0) ? 32'h00000100 : 32'd0;
			GHCI_REG_RESIDENT_WARPS: v = {8'd0, NREGS, RESIDENT_WARPS};
			GHCI_REG_SESSION_ACTIVE: v = 32'h00000001;
			GHCI_REG_GCLK_HZ: v = GCLK_HZ;
			GHCI_REG_NATIVE_ISA_ID: v = 32'h47534931;
			GHCI_REG_EXT_CAP_FMT0: v = eff_fmt0;
			GHCI_REG_EXT_CAP_FEATURE: v = eff_feat;
			17'h00160: v = {24'd0, PERF_SRC[7:0]};
			17'h00164: v = {24'd0, PERF_SRC[15:8]};
			17'h00168: v = {24'd0, PERF_SRC[23:16]};
			17'h0016C: v = {24'd0, PERF_SRC[31:24]};
			17'h00180: v = VENDOR_ID;
			17'h00184: v = DEVICE_ID;
			17'h00190: v = GCLK_HZ;
			default: ;
			endcase
			calc_own_const = v | {32{win_in & 1'b0}};
		end
	endfunction

	wire [31:0] own_const_lo_w = calc_own_const(roff_pre_lo, win_q);
	wire [31:0] own_const_hi_w = calc_own_const(roff_pre_hi, win_q);

	wire [31:0] prf_word_all = {
		perf[{prf_idx_hi, 5'd0} + 16 +: 16],
		perf[{prf_idx_lo, 5'd0} +: 16]
	};

	wire [31:0] own_a_pre, own_b_pre, own_c_pre;
	genvar g_ob;
	generate
		for (g_ob = 0; g_ob < 32; g_ob = g_ob + 1) begin : g_own_ab_lut
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_oa (
				.I0(scratch[g_ob]),       .I1(sel_scr_b[g_ob >> 4]),
				.I2(counter[g_ob]),       .I3(sel_cnt_b[g_ob >> 4]),
				.I4(prf_word_all[g_ob]),  .I5(sel_prf_b[g_ob >> 4]),
				.O(own_a_pre[g_ob])
			);
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFFFFF888F888F888)) u_ob (
				.I0(diag_cp_pc[g_ob]),     .I1(sel_pc_b[g_ob >> 4]),
				.I2(diag_cp_status[g_ob]), .I3(sel_st_b[g_ob >> 4]),
				.I4(counter_hi[g_ob]),     .I5(sel_cnthi_b[g_ob >> 4]),
				.O(own_b_pre[g_ob])
			);
		end
	endgenerate
	assign own_c_pre = {own_const_hi_w[31:16], own_const_lo_w[15:0]};

	(* dont_touch = "true" *) reg [31:0] own_a_q, own_b_q, own_c_q;
	always @(posedge clk) begin
		if (regs_rst_high) begin
			own_a_q <= 32'd0;
			own_b_q <= 32'd0;
			own_c_q <= 32'd0;
		end else begin
			own_a_q <= own_a_pre;
			own_b_q <= own_b_pre;
			own_c_q <= own_c_pre;
		end
	end

	wire [3:0] rd_st_b, rd_hcr_b, rd_hcr_lo_b, rd_hcr_hi_b;
	genvar g_rb;
	generate
		for (g_rb = 0; g_rb < 4; g_rb = g_rb + 1) begin : g_rd_sel_buf
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rst   (.I0(rd_state_q),  .O(rd_st_b[g_rb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rhc   (.I0(rd_hcr_q),    .O(rd_hcr_b[g_rb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rhclo (.I0(rd_hcr_lo_q), .O(rd_hcr_lo_b[g_rb]));
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rhchi (.I0(rd_hcr_hi_q), .O(rd_hcr_hi_b[g_rb]));
		end
	endgenerate

	wire [31:0] own_x_hcr, other_hcr;
	genvar g_rd;
	generate
		for (g_rd = 0; g_rd < 32; g_rd = g_rd + 1) begin : g_rdata_mux
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFAAAFAAAFAAAF888)) u_ox (
				.I0(rd_hcr_b[g_rd >> 3]),
				.I1(own_a_q[g_rd]),
				.I2(rd_hcr_hi_b[g_rd >> 3]),
				.I3(x_rdata[g_rd]),
				.I4(own_b_q[g_rd]),
				.I5(own_c_q[g_rd]),
				.O(own_x_hcr[g_rd])
			);
			(* DONT_TOUCH = "TRUE" *) LUT5 #(.INIT(32'hFFFFFE00)) u_ohcr (
				.I0(fence_rdata[g_rd]),
				.I1(dbg_rdata[g_rd]),
				.I2(irq_rdata[g_rd]),
				.I3(rd_hcr_lo_b[g_rd >> 3]),
				.I4(own_x_hcr[g_rd]),
				.O(other_hcr[g_rd])
			);
			(* DONT_TOUCH = "TRUE" *) LUT6 #(.INIT(64'hFF00FF00FEFEF0F0)) u_rrd (
				.I0(ring_rdata[g_rd]),
				.I1(ctl_rdata[g_rd]),
				.I2(other_hcr[g_rd]),
				.I3(state_rdata[g_rd]),
				.I4(rd_hcr_lo_b[g_rd >> 3]),
				.I5(rd_st_b[g_rd >> 3]),
				.O(reg_rdata[g_rd])
			);
		end
	endgenerate
`else
	assign reg_rdata = rd_state_q ? state_rdata :
		rd_hcr_q ? (own | ctl_rdata | irq_rdata | ring_rdata | fence_rdata | dbg_rdata | x_rdata) :
		32'd0;
`endif

	wire unused_ok = &{1'b0, reg_waddr[1:0], reg_raddr[1:0], inc_co, raddr_q[1:0],
		def_fmt0[15:12], def_feat[19:15], eff_caps, diag_pipe_fsm,
		(HAS_INDIRECT_DRAW != 0), (HAS_SECONDARY_RING != 0)};

endmodule

`default_nettype wire
