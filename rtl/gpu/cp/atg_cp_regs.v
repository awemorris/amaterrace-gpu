/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_regs: the GHCI register bus decoder of the CP: identification,
 * CAPS, the extended capability list, VEND, SCRATCH, COUNTER and the PERF
 * registers, plus the HCR snoop bus and the STATE alias that the other CP
 * modules (and atg_cpu) use for their own registers.
 *
 * Writes to 0x000-0xFFC go out on hcr_* in the cycle of reg_wr (every
 * module takes the writes of its own word indices); whole-word writes to
 * 0x1000-0x1BFC go out on alias_* (a partial-strobe alias write is
 * dropped here).  Reads: the answer is due the cycle after reg_rd; the
 * index is registered (hcr_ridx) and every module answers its own
 * registers combinationally from it, this module ORs them with its own,
 * or returns the state RAM's word for the alias, or 0 elsewhere
 * (0x1800-0x1FFFF).
 *
 * The extended capability list at 0x100: one two-word entry per set bit
 * of XCAP_MASK in id order; the first two entries at 0x100 and 0x108, the
 * rest from 0x180 (0x110-0x17F hold the PERF, CPFW, SA and FMT registers).
 * The PROT capability's registers (atg_cp_prot's, through x_rdata) are at
 * 0x1D0, after the room of a full list; the MEM capability's five words
 * (LOCAL_BASE, LOCAL_SIZE, WINDOW_SIZE, HOST_LIMIT, WINDOW_CTRL) at 0x1E0.
 * DISP2 points to its window at 0x200 (atg_cp_disp answers it through
 * x_rdata).  At most ten entries fit in the list (0x100-0x10F and
 * 0x180-0x1BF): DISP and DISP2 are not listed together.
 * WINDOW_CTRL.ENABLE (win_en, docs/ghci.md section 11.1) is 1 after rst_n
 * (the board's reset, not CTRL.RESET) and takes host writes only when the
 * GPU has a local window (WINDOW_BYTES != 0); without one it reads 0 and
 * win_en stays 0.
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

`define ATG_DEF_DEVICE_CAPS { \
	`ATG_DEF_MSAA, 1'b1, 1'b1, `ATG_DEF_MESH, `ATG_DEF_MESH, \
	1'b1, `ATG_DEF_TRILINEAR, `ATG_DEF_SA, \
	8'd1, `ATG_DEF_PHYS_LANES, \
	1'b1, `ATG_DEF_FP16, `ATG_DEF_DUAL_SRC, `ATG_DEF_RV32, `ATG_DEF_RV32, `ATG_DEF_HW_WALKER, 1'b0, 1'b0 \
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
	25'd0, `ATG_DEF_BC, 1'b0, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC, `ATG_DEF_BC \
}

`define ATG_DEF_EXT_CAP_FEATURE { \
	21'd0, `ATG_DEF_FAST_CLEAR, `ATG_DEF_COARSE_SCAN, `ATG_DEF_DUAL_SRC, `ATG_DEF_MRT_COUNT, \
	1'b1, `ATG_DEF_CURSOR, `ATG_DEF_EARLY_Z, `ATG_DEF_LOGICOP \
}

module atg_cp_regs #(
	parameter GCLK_HZ = 32'd100000000,	/* GCLK_HZ register */
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
	parameter [31:0] DEVICE_CAPS = 32'd0,	/* 0: dynamic from config macros */
	parameter CAPS = 32'h00500002,	/* CAPS value (design §2.2), set by atg_top from its parameters */
	parameter CAPS2 = 32'h00000003,	/* CAPS2 value: [7:0] = 3 independent queues (Graphics, Compute, Copy/DMA) */
	parameter [31:0] EXT_CAP_FMT0 = `ATG_DEF_EXT_CAP_FMT0,
	parameter [31:0] EXT_CAP_FEATURE = `ATG_DEF_EXT_CAP_FEATURE,
	parameter VEND = 256'd0,	/* The 8 VEND words (0x0C0-0x0DF), word 0 in bits 31:0 */
	parameter [10:0] XCAP_MASK = 11'h004,	/* Which extended capabilities are listed: bit id-1 (DISP 1, DBG 2, PERF 3, VEND 4, CPFW 6, SA 7, MEM 8, PROT 9, FMT 10, DISP2 11) */
	parameter DISP_OFFSET = 32'h00010000,	/* Where the DISP entry points (KC705 +0x10000) */
	parameter PERF_SRC = 32'hFFFFFFFF,	/* PERF_SRC0..3 (byte n = PERF_SRCn) */
	parameter SLIM_MMIO = 1		/* 1: GHCI 1.0 Slim 19 MMIO registers (0x00..0x48), eliminating STATE from host MMIO */
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

	function [9:0] slim_widx;
		input [16:0] addr;
		case (addr)
		GHCI_REG_CTRL: slim_widx = GHCI_CTRL[11:2];
		GHCI_REG_IRQ_STATUS: slim_widx = GHCI_IRQ_STATUS[11:2];
		GHCI_REG_IRQ_ENABLE: slim_widx = GHCI_IRQ_ENABLE[11:2];
		GHCI_REG_IRQ_SET: slim_widx = GHCI_IRQ_SET[11:2];
		GHCI_REG_RING_BASE_LO: slim_widx = GHCI_RING_BASE[11:2];
		GHCI_REG_RING_BASE_HI: slim_widx = GHCI_REG_RING_BASE_HI[11:2];
		GHCI_REG_RING_SIZE: slim_widx = GHCI_RING_SIZE[11:2];
		GHCI_REG_RING_WPTR: slim_widx = GHCI_RING_WPTR[11:2];
		GHCI_REG_WDT_CYCLES: slim_widx = GHCI_WDT_CYCLES[11:2];
		GHCI_REG_CP_HEAP_BASE: slim_widx = GHCI_APERTURE_BASE[11:2];
		GHCI_REG_CP_HEAP_LIMIT: slim_widx = GHCI_APERTURE_LIMIT[11:2];
		default: slim_widx = addr[11:2];
		endcase
	endfunction

	wire slim_we_ok = (reg_waddr == GHCI_REG_CTRL) ||
	                  (reg_waddr == GHCI_REG_IRQ_STATUS) ||
	                  (reg_waddr == GHCI_REG_IRQ_ENABLE) ||
	                  (reg_waddr == GHCI_REG_IRQ_SET) ||
	                  (reg_waddr == GHCI_REG_RING_BASE_LO) ||
	                  (reg_waddr == GHCI_REG_RING_BASE_HI) ||
	                  (reg_waddr == GHCI_REG_RING_SIZE) ||
	                  (reg_waddr == GHCI_REG_RING_WPTR) ||
	                  (reg_waddr == GHCI_REG_WDT_CYCLES) ||
	                  (reg_waddr == GHCI_REG_CP_HEAP_BASE) ||
	                  (reg_waddr == GHCI_REG_CP_HEAP_LIMIT);

	/* Writes. */
	assign hcr_we = SLIM_MMIO ? (reg_wr && slim_we_ok) :
	                            (reg_wr && reg_waddr[16:12] == 5'd0);
	assign hcr_widx = SLIM_MMIO ? slim_widx(reg_waddr) : reg_waddr[11:2];
	assign hcr_wdata = reg_wdata;
`ifdef SYNTH_KINTEX7
	wire [3:0] reg_wstrb_m;
	genvar g_sb;
	generate
		for (g_sb = 0; g_sb < 4; g_sb = g_sb + 1) begin : g_sb_gen
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_sb (.I0(reg_wstrb[g_sb]), .O(reg_wstrb_m[g_sb]));
		end
	endgenerate
	assign hcr_wmask = {{8{reg_wstrb_m[3]}}, {8{reg_wstrb_m[2]}}, {8{reg_wstrb_m[1]}}, {8{reg_wstrb_m[0]}}};
`else
	assign hcr_wmask = {{8{reg_wstrb[3]}}, {8{reg_wstrb[2]}}, {8{reg_wstrb[1]}}, {8{reg_wstrb[0]}}};
`endif
	/* 0x1000-0x1BFC: STATE[0..0x2FF]. Eliminated in SLIM_MMIO mode. */
	assign alias_we = !SLIM_MMIO && (reg_wr && reg_waddr[16:12] == 5'b00001 && reg_waddr[11:10] != 2'b11 &&
		reg_wstrb == 4'hF);
	assign alias_idx = reg_waddr[11:2];
	assign alias_ridx = reg_raddr[11:2];

	wire is_scratch_wr = SLIM_MMIO ?
		(reg_wr && reg_waddr == GHCI_REG_SCRATCH) :
		(hcr_we && hcr_widx == I_SCRATCH);

	reg [31:0] scratch;
	reg win_q;
	reg [31:0] counter;
	reg [127:0] perf;	/* PERF0..3, PERFn in bits 32n+31:32n */
	wire perf_clear_raw = perf_reset ||
		(hcr_we && hcr_widx == I_PERF_CTRL && hcr_wmask[0] && hcr_wdata[0]);
`ifdef SYNTH_KINTEX7
	wire [3:0] perf_clear_b;
	genvar g_pc;
	generate
		for (g_pc = 0; g_pc < 4; g_pc = g_pc + 1) begin : g_perf_clr
			(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_pc (.I0(perf_clear_raw), .O(perf_clear_b[g_pc]));
		end
	endgenerate
	wire perf_clear = perf_clear_raw;
`else
	wire perf_clear = perf_clear_raw;
`endif
	integer i;

	/* COUNTER + 1 and PERFn + busy: one incrementer each. */
	wire [31:0] counter_n;
	wire [127:0] perf_n;
	wire [4:0] inc_co;

	am_add #(.W(32)) counter_add (
		.a(counter), .b(32'd0), .ci(1'b1), .s(counter_n), .co(inc_co[4])
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
		if (!rst_n) begin
			scratch <= 32'd0;
			counter <= 32'd0;
			win_q <= HAS_WINDOW;
		end else begin
			counter <= counter_n;
			if (is_scratch_wr)
				scratch <= (scratch & ~hcr_wmask) | (hcr_wdata & hcr_wmask);
			if (HAS_WINDOW && hcr_we && hcr_widx == I_WINDOW_CTRL && hcr_wmask[0])
				win_q <= hcr_wdata[0];
		end
		for (i = 0; i < 4; i = i + 1)
`ifdef SYNTH_KINTEX7
			if (!rst_n || perf_clear_b[i])
`else
			if (!rst_n || perf_clear)
`endif
				perf[i * 32 +: 32] <= 32'd0;
			else
				perf[i * 32 +: 32] <= perf_n[i * 32 +: 32];
	end

	function [9:0] slim_ridx;
		input [16:0] addr;
		case (addr)
		GHCI_REG_STATUS: slim_ridx = GHCI_STATUS[11:2];
		GHCI_REG_CTRL: slim_ridx = GHCI_CTRL[11:2];
		GHCI_REG_FAULT_INFO: slim_ridx = GHCI_FAULT_INFO[11:2];
		GHCI_REG_FAULT_ADDR_LO: slim_ridx = GHCI_FAULT_ADDR[11:2];
		GHCI_REG_RING_BASE_LO: slim_ridx = GHCI_RING_BASE[11:2];
		GHCI_REG_RING_BASE_HI: slim_ridx = GHCI_REG_RING_BASE_HI[11:2];
		GHCI_REG_RING_SIZE: slim_ridx = GHCI_RING_SIZE[11:2];
		GHCI_REG_RING_RPTR: slim_ridx = GHCI_RING_RPTR[11:2];
		GHCI_REG_RING_WPTR: slim_ridx = GHCI_RING_WPTR[11:2];
		GHCI_REG_IRQ_STATUS: slim_ridx = GHCI_IRQ_STATUS[11:2];
		GHCI_REG_IRQ_ENABLE: slim_ridx = GHCI_IRQ_ENABLE[11:2];
		GHCI_REG_WDT_CYCLES: slim_ridx = GHCI_WDT_CYCLES[11:2];
		GHCI_REG_RESIDENT_WARPS: slim_ridx = GHCI_RESIDENT_WARPS[11:2];
		GHCI_REG_CP_HEAP_BASE: slim_ridx = GHCI_APERTURE_BASE[11:2];
		GHCI_REG_CP_HEAP_LIMIT: slim_ridx = GHCI_APERTURE_LIMIT[11:2];
		default: slim_ridx = addr[11:2];
		endcase
	endfunction

	/* Reads: the registered index, answered the next cycle. */
	reg [9:0] ridx_q;
	reg [16:0] raddr_q;
	reg rd_hcr_q;
	reg rd_state_q;

`ifdef SYNTH_KINTEX7
	wire [3:0] reg_rd_b;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb0 (.I0(reg_rd), .O(reg_rd_b[0]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb1 (.I0(reg_rd), .O(reg_rd_b[1]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb2 (.I0(reg_rd), .O(reg_rd_b[2]));
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h2)) u_rdb3 (.I0(reg_rd), .O(reg_rd_b[3]));

	always @(posedge clk) begin
		if (!rst_n) begin
			ridx_q <= 10'd0;
			raddr_q <= 17'd0;
			rd_hcr_q <= 1'b0;
			rd_state_q <= 1'b0;
		end else begin
			if (reg_rd_b[0]) raddr_q <= reg_raddr;
			if (reg_rd_b[1]) ridx_q <= SLIM_MMIO ? slim_ridx(reg_raddr) : reg_raddr[11:2];
			if (reg_rd_b[2]) rd_hcr_q <= SLIM_MMIO ? (reg_raddr <= 17'h00084 ||
			                         (reg_raddr >= 17'h00100 && reg_raddr <= 17'h003FF)) : (reg_raddr[16:12] == 5'd0);
			if (reg_rd_b[3]) rd_state_q <= !SLIM_MMIO && (reg_raddr[16:12] == 5'b00001 && reg_raddr[11:10] != 2'b11);
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
			ridx_q <= SLIM_MMIO ? slim_ridx(reg_raddr) : reg_raddr[11:2];
			rd_hcr_q <= SLIM_MMIO ? (reg_raddr <= 17'h00084 ||
			                         (reg_raddr >= 17'h00100 && reg_raddr <= 17'h003FF)) : (reg_raddr[16:12] == 5'd0);
			rd_state_q <= !SLIM_MMIO && (reg_raddr[16:12] == 5'b00001 && reg_raddr[11:10] != 2'b11);
		end
	end
`endif

	assign hcr_ridx = ridx_q;
	assign win_en = win_q;

	/* The extended capability list: entry k's byte offset. */
	function integer xcap_off;
		input integer k;
		xcap_off = k < 2 ? 256 + k * 8 : 384 + (k - 2) * 8;
	endfunction

	function [31:0] xcap_ptr;
		input integer id;
		case (id)
		1: xcap_ptr = DISP_OFFSET;
		3: xcap_ptr = {15'd0, GHCI_PERF_SRC0};
		4: xcap_ptr = 32'h000000C0;
		6: xcap_ptr = 32'h00000120;
		7: xcap_ptr = 32'h00000140;
		8: xcap_ptr = {20'd0, MEM_OFF};
		9: xcap_ptr = 32'h000001D0;	/* PROT: atg_cp_prot answers its registers */
		10: xcap_ptr = 32'h00000160;
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

	wire [31:0] eff_dev_caps = (DEVICE_CAPS != 32'd0) ? DEVICE_CAPS : `ATG_DEF_DEVICE_CAPS;
	wire [31:0] eff_caps = (CAPS != 32'h00500002) ? CAPS : `ATG_DEF_CAPS;

	reg [31:0] own;
	wire [11:0] roff = {ridx_q, 2'b00};

	always @(*) begin
		if (SLIM_MMIO) begin
			own = 32'd0;
			case (raddr_q)
			GHCI_REG_MAGIC: own = GHCI_MAGIC_VALUE;
			GHCI_REG_VERSION: own = 32'h00010000;
			GHCI_REG_DEVICE_CAPS: own = eff_dev_caps;
			GHCI_REG_EXTCAP_PTR: own = (XCAP_MASK != 11'd0) ? 32'h00000100 : 32'd0;
			GHCI_REG_FAULT_ADDR_HI: own = 32'd0;
			GHCI_REG_RING_BASE_HI: own = 32'd0;
			GHCI_REG_SCRATCH: own = scratch;
			GHCI_REG_SESSION_ACTIVE: own = 32'd0;
			GHCI_REG_TIMESTAMP_LO: own = counter;
			GHCI_REG_TIMESTAMP_HI: own = 32'd0;
			GHCI_REG_DIAG_CP_PC: own = diag_cp_pc;
			GHCI_REG_DIAG_CP_STATUS: own = diag_cp_status;
			GHCI_REG_EXT_CAP_FMT0: own = EXT_CAP_FMT0;
			GHCI_REG_EXT_CAP_FEATURE: own = EXT_CAP_FEATURE;
			default: own = (raddr_q >= 17'h00100) ? xcap_word(roff) : 32'd0;
			endcase
		end else begin
			own = xcap_word(roff);
			case (roff)
			GHCI_MAGIC[11:0]: own = GHCI_MAGIC_VALUE;
			GHCI_VERSION[11:0]: own = {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR};
			GHCI_VENDOR_ID[11:0]: own = VENDOR_ID;
			GHCI_DEVICE_ID[11:0]: own = DEVICE_ID;
			GHCI_ISA_ID[11:0]: own = ISA_ID;
			GHCI_DEVICE_VERSION[11:0]: own = DEVICE_VERSION;
			GHCI_EXTCAP[11:0]: own = XCAP_MASK != 11'd0 ? {15'd0, GHCI_EXTCAP_LIST} : 32'd0;
			GHCI_GCLK_HZ[11:0]: own = GCLK_HZ;
			GHCI_CAPS[11:0]: own = eff_caps;
			GHCI_CAPS2[11:0]: own = CAPS2;
			GHCI_SCRATCH[11:0]: own = scratch;
			GHCI_COUNTER[11:0]: own = counter;
			12'h048: own = NATIVE_ISA_ID;
			GHCI_RESIDENT_WARPS[11:0]: own = {8'd0, NREGS, RESIDENT_WARPS};
			12'h080, 12'h084, 12'h088, 12'h08c:
				own = (roff == 12'h080 && !XCAP_MASK[2]) ? EXT_CAP_FMT0 :
				      (roff == 12'h084 && !XCAP_MASK[2]) ? EXT_CAP_FEATURE :
				      perf[roff[3:2] * 32 +: 32];
			12'h090, 12'h094, 12'h098, 12'h09c:
				if (XCAP_MASK[2]) own = {24'd0, PERF_SRC[roff[3:2] * 8 +: 8]};
			12'h0c0, 12'h0c4, 12'h0c8, 12'h0cc, 12'h0d0, 12'h0d4, 12'h0d8, 12'h0dc:
				own = VEND[roff[4:2] * 32 +: 32];
			A_LOCAL_BASE: if (XCAP_MASK[7]) own = LOCAL_BASE;
			A_LOCAL_SIZE: if (XCAP_MASK[7]) own = LOCAL_BYTES;
			A_WINDOW_SIZE: if (XCAP_MASK[7]) own = WINDOW_BYTES;
			A_HOST_LIMIT: if (XCAP_MASK[7]) own = HOST_LIMIT;
			A_WINDOW_CTRL: if (XCAP_MASK[7]) own = {31'd0, win_q};
			GHCI_CP_PC[11:0]: own = diag_cp_pc;
			GHCI_CP_STATUS[11:0]: own = diag_cp_status;
			GHCI_PIPE_FSM[11:0]: own = diag_pipe_fsm;
			default: ;
			endcase
		end
	end

`ifdef SYNTH_KINTEX7
	wire [11:0] roff_pre = {reg_raddr[11:2], 2'b00};
	reg [31:0] own_pre;
	always @(*) begin
		own_pre = xcap_word(roff_pre);
		case (roff_pre)
		GHCI_MAGIC[11:0]: own_pre = GHCI_MAGIC_VALUE;
		GHCI_VERSION[11:0]: own_pre = {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR};
		GHCI_VENDOR_ID[11:0]: own_pre = VENDOR_ID;
		GHCI_DEVICE_ID[11:0]: own_pre = DEVICE_ID;
		GHCI_ISA_ID[11:0]: own_pre = ISA_ID;
		GHCI_DEVICE_VERSION[11:0]: own_pre = DEVICE_VERSION;
		GHCI_EXTCAP[11:0]: own_pre = XCAP_MASK != 11'd0 ? {15'd0, GHCI_EXTCAP_LIST} : 32'd0;
		GHCI_GCLK_HZ[11:0]: own_pre = GCLK_HZ;
		GHCI_CAPS[11:0]: own_pre = eff_caps;
		GHCI_CAPS2[11:0]: own_pre = CAPS2;
		GHCI_SCRATCH[11:0]: own_pre = scratch;
		GHCI_COUNTER[11:0]: own_pre = counter;
		12'h048: own_pre = NATIVE_ISA_ID;
		GHCI_RESIDENT_WARPS[11:0]: own_pre = {8'd0, NREGS, RESIDENT_WARPS};
		12'h080, 12'h084, 12'h088, 12'h08c:
			own_pre = (roff_pre == 12'h080 && !XCAP_MASK[2]) ? EXT_CAP_FMT0 :
			          (roff_pre == 12'h084 && !XCAP_MASK[2]) ? EXT_CAP_FEATURE :
			          perf[roff_pre[3:2] * 32 +: 32];
		12'h090, 12'h094, 12'h098, 12'h09c:
			if (XCAP_MASK[2]) own_pre = {24'd0, PERF_SRC[roff_pre[3:2] * 8 +: 8]};
		12'h0c0, 12'h0c4, 12'h0c8, 12'h0cc, 12'h0d0, 12'h0d4, 12'h0d8, 12'h0dc:
			own_pre = VEND[roff_pre[4:2] * 32 +: 32];
		A_LOCAL_BASE: if (XCAP_MASK[7]) own_pre = LOCAL_BASE;
		A_LOCAL_SIZE: if (XCAP_MASK[7]) own_pre = LOCAL_BYTES;
		A_WINDOW_SIZE: if (XCAP_MASK[7]) own_pre = WINDOW_BYTES;
		A_HOST_LIMIT: if (XCAP_MASK[7]) own_pre = HOST_LIMIT;
		A_WINDOW_CTRL: if (XCAP_MASK[7]) own_pre = {31'd0, win_q};
		GHCI_CP_PC[11:0]: own_pre = diag_cp_pc;
		GHCI_CP_STATUS[11:0]: own_pre = diag_cp_status;
		GHCI_PIPE_FSM[11:0]: own_pre = diag_pipe_fsm;
		default: ;
		endcase
	end

	(* max_fanout = 16 *) reg [31:0] own_q;
	always @(posedge clk) begin
		if (!rst_n)
			own_q <= 32'd0;
		else
			own_q <= own_pre;
	end

	wire [31:0] sub_grp0 = (ridx_q[9:7] == 3'b000) ? (ctl_rdata | irq_rdata) : ring_rdata;
	wire [31:0] sub_grp1 = (ridx_q[8] == 1'b1) ? x_rdata : (fence_rdata | dbg_rdata);
	wire [31:0] hcr_sub  = (ridx_q[9] || ridx_q[8]) ? sub_grp1 : sub_grp0;
	assign reg_rdata = rd_state_q ? state_rdata :
		rd_hcr_q ? (own_q | hcr_sub) :
		32'd0;
`else
	assign reg_rdata = rd_state_q ? state_rdata :
		rd_hcr_q ? (own | ctl_rdata | irq_rdata | ring_rdata | fence_rdata | dbg_rdata | x_rdata) :
		32'd0;
`endif

	wire unused_ok = &{1'b0, reg_waddr[1:0], reg_raddr[1:0], inc_co, raddr_q[1:0]};

endmodule

`default_nettype wire
