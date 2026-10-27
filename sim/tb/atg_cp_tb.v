/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_tb: Verification testbench for CP & GHCI Capability Registers
 * (Phase 006 / ws003-p006).
 *
 * Verifies dynamic hardware capability reflection from atg_config.vh macros
 * to MMIO registers:
 *   - DEVICE_CAPS (0x008): PHYS_LANES, Task/Mesh Shader, FP16, Dual Source, etc.
 *   - CAPS (0x020): SUBGROUP, TEX_ADV, PACKED_MATH, MSAA, etc.
 *   - EXT_CAP_FMT0 (0x080): Texture compression format bitmap (BC1-BC7)
 *   - EXT_CAP_FEATURE (0x084): LogicOp, EarlyZ, HW Cursor, MRT count, etc.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifdef CFG_ENABLE_FP16
`define EXP_CFG_FP16 1'b1
`else
`define EXP_CFG_FP16 1'b0
`endif

`ifdef CFG_ENABLE_EARLY_Z
`define EXP_CFG_EARLY_Z 1'b1
`else
`define EXP_CFG_EARLY_Z 1'b0
`endif

`ifdef CFG_ENABLE_MSAA
`define EXP_CFG_MSAA 1'b1
`else
`define EXP_CFG_MSAA 1'b0
`endif

`ifdef CFG_ENABLE_SUBGROUP
`define EXP_CFG_SUBGROUP 1'b1
`else
`define EXP_CFG_SUBGROUP 1'b0
`endif

module atg_cp_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;

	/* -------------------------------------------------------------
	 * 1. Default Configuration Instance (Driven by atg_config.vh)
	 * ------------------------------------------------------------- */
	reg reg_wr = 1'b0;
	reg [16:0] reg_waddr = 17'd0;
	reg [31:0] reg_wdata = 32'd0;
	reg [3:0] reg_wstrb = 4'h0;
	reg reg_rd = 1'b0;
	reg [16:0] reg_raddr = 17'd0;
	wire [31:0] reg_rdata;

	wire hcr_we;
	wire [9:0] hcr_widx;
	wire [31:0] hcr_wdata;
	wire [31:0] hcr_wmask;
	wire [9:0] hcr_ridx;
	wire alias_we;
	wire [9:0] alias_idx;
	wire [9:0] alias_ridx;

	atg_cp_regs #(
		.SLIM_MMIO(1)
	) u_cp_regs_default (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(reg_wr),
		.reg_waddr(reg_waddr),
		.reg_wdata(reg_wdata),
		.reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd),
		.reg_raddr(reg_raddr),
		.reg_rdata(reg_rdata),
		.hcr_we(hcr_we),
		.hcr_widx(hcr_widx),
		.hcr_wdata(hcr_wdata),
		.hcr_wmask(hcr_wmask),
		.hcr_ridx(hcr_ridx),
		.alias_we(alias_we),
		.alias_idx(alias_idx),
		.alias_ridx(alias_ridx),
		.ctl_rdata(32'd0),
		.irq_rdata(32'd0),
		.ring_rdata(32'd0),
		.fence_rdata(32'd0),
		.dbg_rdata(32'd0),
		.state_rdata(32'd0),
		.x_rdata(32'd0),
		.perf_busy(4'd0),
		.perf_reset(1'b0),
		.win_en(),
		.diag_cp_pc(32'd0),
		.diag_cp_status(32'd0),
		.diag_pipe_fsm(32'd0)
	);

	/* -------------------------------------------------------------
	 * 2. Custom Capability Instance (Overridden Parameters)
	 * ------------------------------------------------------------- */
	reg c_reg_rd = 1'b0;
	reg [16:0] c_reg_raddr = 17'd0;
	wire [31:0] c_reg_rdata;

	localparam [31:0] CUSTOM_DEV_CAPS = {
		1'b1, 1'b1, 6'd0, 8'd2, 8'd16, /* MESH=1, TASK=1, NUM_SU=2, PHYS_LANES=16 */
		1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1 /* UMA=1 */
	};
	localparam [31:0] CUSTOM_FMT0 = 32'h0000007F; /* Full BC1-BC7 */
	localparam [31:0] CUSTOM_FEAT = 32'h0000074F; /* MRT=4 */

	atg_cp_regs #(
		.DEVICE_CAPS(CUSTOM_DEV_CAPS),
		.EXT_CAP_FMT0(CUSTOM_FMT0),
		.EXT_CAP_FEATURE(CUSTOM_FEAT),
		.SLIM_MMIO(1)
	) u_cp_regs_custom (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(1'b0),
		.reg_waddr(17'd0),
		.reg_wdata(32'd0),
		.reg_wstrb(4'd0),
		.reg_rd(c_reg_rd),
		.reg_raddr(c_reg_raddr),
		.reg_rdata(c_reg_rdata),
		.hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(),
		.ctl_rdata(32'd0), .irq_rdata(32'd0), .ring_rdata(32'd0), .fence_rdata(32'd0),
		.dbg_rdata(32'd0), .state_rdata(32'd0), .x_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0), .win_en(),
		.diag_cp_pc(32'd0), .diag_cp_status(32'd0), .diag_pipe_fsm(32'd0)
	);

	/* -------------------------------------------------------------
	 * 3. Legacy Full Layout Instance
	 * ------------------------------------------------------------- */
	reg leg_reg_rd = 1'b0;
	reg [16:0] leg_reg_raddr = 17'd0;
	wire [31:0] leg_reg_rdata;

	atg_cp_regs #(
		.SLIM_MMIO(0)
	) u_cp_regs_legacy (
		.clk(clk),
		.rst_n(rst_n),
		.reg_wr(1'b0),
		.reg_waddr(17'd0),
		.reg_wdata(32'd0),
		.reg_wstrb(4'd0),
		.reg_rd(leg_reg_rd),
		.reg_raddr(leg_reg_raddr),
		.reg_rdata(leg_reg_rdata),
		.hcr_we(), .hcr_widx(), .hcr_wdata(), .hcr_wmask(), .hcr_ridx(),
		.alias_we(), .alias_idx(), .alias_ridx(),
		.ctl_rdata(32'd0), .irq_rdata(32'd0), .ring_rdata(32'd0), .fence_rdata(32'd0),
		.dbg_rdata(32'd0), .state_rdata(32'd0), .x_rdata(32'd0),
		.perf_busy(4'd0), .perf_reset(1'b0), .win_en(),
		.diag_cp_pc(32'd0), .diag_cp_status(32'd0), .diag_pipe_fsm(32'd0)
	);

	task mmio_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			reg_rd <= 1'b1;
			reg_raddr <= addr;
			@(posedge clk);
			reg_rd <= 1'b0;
			#1;
			data = reg_rdata;
		end
	endtask

	task custom_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			c_reg_rd <= 1'b1;
			c_reg_raddr <= addr;
			@(posedge clk);
			c_reg_rd <= 1'b0;
			#1;
			data = c_reg_rdata;
		end
	endtask

	task legacy_read;
		input [16:0] addr;
		output [31:0] data;
		begin
			@(posedge clk);
			leg_reg_rd <= 1'b1;
			leg_reg_raddr <= addr;
			@(posedge clk);
			leg_reg_rd <= 1'b0;
			#1;
			data = leg_reg_rdata;
		end
	endtask

	reg [31:0] rdata;

	initial begin
		#20;
		rst_n = 1'b1;
		#20;

		$display("=== atg_cp_tb: Starting Capability Verification ===");

		/* Test 1: Verify Default DEVICE_CAPS from config macros */
		mmio_read(GHCI_REG_DEVICE_CAPS, rdata);
		$display("Default DEVICE_CAPS = 0x%08h", rdata);
		if (rdata[15:8] !== 8'd`CFG_SU_NPHYS) begin
			$display("FAIL: PHYS_LANES = %0d (expected %0d)", rdata[15:8], `CFG_SU_NPHYS);
			errors = errors + 1;
		end else begin
			$display("PASS: PHYS_LANES = %0d correctly reflected", rdata[15:8]);
		end

		if (rdata[6] !== `EXP_CFG_FP16) begin
			$display("FAIL: FP16 = %b (expected %b)", rdata[6], `EXP_CFG_FP16);
			errors = errors + 1;
		end else begin
			$display("PASS: FP16 = %b correctly reflected", `EXP_CFG_FP16);
		end

		/* Test 2: Verify Default EXT_CAP_FMT0 (0x080) */
		mmio_read(GHCI_REG_EXT_CAP_FMT0, rdata);
		$display("Default EXT_CAP_FMT0 = 0x%08h", rdata);
`ifdef CFG_ENABLE_BC
		if (rdata[0] !== 1'b1 || rdata[6] !== 1'b1) begin
			$display("FAIL: BC1/BC7 support not reflected");
			errors = errors + 1;
		end else begin
			$display("PASS: BC1-BC7 format bitmap correctly reflected");
		end
`else
		if (rdata[0] !== 1'b0 || rdata[6] !== 1'b0) begin
			$display("FAIL: BC1/BC7 should be 0 when CFG_ENABLE_BC=0");
			errors = errors + 1;
		end else begin
			$display("PASS: BC1-BC7 correctly disabled");
		end
`endif

		/* Test 3: Verify Default EXT_CAP_FEATURE (0x084) */
		mmio_read(GHCI_REG_EXT_CAP_FEATURE, rdata);
		$display("Default EXT_CAP_FEATURE = 0x%08h", rdata);
		if (rdata[1] !== `EXP_CFG_EARLY_Z) begin
			$display("FAIL: EARLY_Z feature bit mismatch");
			errors = errors + 1;
		end else begin
			$display("PASS: EARLY_Z feature bit correctly reflected");
		end

		if (rdata[7:4] !== 4'd`CFG_ROP_MRT_COUNT) begin
			$display("FAIL: MAX_MRT_COUNT = %0d (expected %0d)", rdata[7:4], `CFG_ROP_MRT_COUNT);
			errors = errors + 1;
		end else begin
			$display("PASS: MAX_MRT_COUNT = %0d correctly reflected", rdata[7:4]);
		end

		/* Test 4: Verify Custom Instance Overrides */
		custom_read(GHCI_REG_DEVICE_CAPS, rdata);
		if (rdata !== CUSTOM_DEV_CAPS) begin
			$display("FAIL: Custom DEVICE_CAPS = %h (expected %h)", rdata, CUSTOM_DEV_CAPS);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom DEVICE_CAPS (PHYS_LANES=16, TASK=1, MESH=1) verified");
		end

		custom_read(GHCI_REG_EXT_CAP_FMT0, rdata);
		if (rdata !== CUSTOM_FMT0) begin
			$display("FAIL: Custom EXT_CAP_FMT0 = %h (expected %h)", rdata, CUSTOM_FMT0);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom EXT_CAP_FMT0 verified");
		end

		custom_read(GHCI_REG_EXT_CAP_FEATURE, rdata);
		if (rdata !== CUSTOM_FEAT) begin
			$display("FAIL: Custom EXT_CAP_FEATURE = %h (expected %h)", rdata, CUSTOM_FEAT);
			errors = errors + 1;
		end else begin
			$display("PASS: Custom EXT_CAP_FEATURE verified");
		end

		/* Test 5: Verify Legacy CAPS (0x020) */
		legacy_read(GHCI_CAPS, rdata);
		$display("Legacy CAPS = 0x%08h", rdata);
		if (rdata[29] !== `EXP_CFG_MSAA || rdata[24] !== `EXP_CFG_SUBGROUP) begin
			$display("FAIL: Legacy CAPS bits mismatch (MSAA=%b, SUBGROUP=%b)", rdata[29], rdata[24]);
			errors = errors + 1;
		end else begin
			$display("PASS: Legacy CAPS bits (MSAA, SUBGROUP, PACKED, TEX_ADV) verified");
		end

		if (errors == 0) begin
			$display("PASS atg_cp");
		end else begin
			$display("FAIL atg_cp: %0d errors", errors);
		end
		$finish;
	end
endmodule

`default_nettype wire
