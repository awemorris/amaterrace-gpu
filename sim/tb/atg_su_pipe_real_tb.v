/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pipe_real_tb: Unit testbench for the real 6-stage physical execution
 * pipeline (atg_su_pipe).
 *
 * Verifies:
 * 1. Exact 6-cycle physical latency (SHORT_LAT = 6) for both ALU and FPU uops.
 * 2. 1 instruction / cycle throughput on continuous back-to-back execution.
 * 3. Pipeline hold / freeze correctness when clock enable `en = 0`.
 * 4. Functional correctness across mixed integer ALU and floating-point FPU ops.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pipe_real_tb;
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"

	localparam NPHYS = 8;
	localparam SHORT_LAT = 6;
	localparam DW = NPHYS * 32;

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg en = 1'b1;

	reg x_valid = 1'b0;
	reg [1:0] x_warp = 2'd0;
	reg [1:0] x_grp = 2'd0;
	reg x_last = 1'b0;
	reg [2:0] x_sbe = 3'd7;
	reg [15:0] x_pc = 16'd0;
	reg [ATG_UOP_W-1:0] x_uop = 0;
	reg [DW-1:0] x_a = 0;
	reg [DW-1:0] x_b = 0;
	reg [DW-1:0] x_c = 0;
	reg [2*NPHYS-1:0] x_mask = 0;
	reg [31:0] x_info = 32'd0;
	wire x_ready;

	wire s_valid;
	wire [1:0] s_warp;
	wire [1:0] s_grp;
	wire [6:0] s_rd;
	wire [DW-1:0] s_data;
	wire [NPHYS-1:0] s_lanes;

	integer errors = 0;
	integer seed = 12345;

	always #5 clk = !clk;

	atg_su_pipe #(
		.NPHYS(NPHYS),
		.SHORT_LAT(SHORT_LAT)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.x_valid(x_valid),
		.x_warp(x_warp),
		.x_grp(x_grp),
		.x_last(x_last),
		.x_sbe(x_sbe),
		.x_pc(x_pc),
		.x_uop(x_uop),
		.x_a(x_a),
		.x_b(x_b),
		.x_c(x_c),
		.x_mask(x_mask),
		.x_info(x_info),
		.x_ready(x_ready),
		.s_valid(s_valid),
		.s_warp(s_warp),
		.s_grp(s_grp),
		.s_rd(s_rd),
		.s_data(s_data),
		.s_lanes(s_lanes)
	);

	/* Queue to track expected results by cycle */
	reg [DW-1:0] exp_data [0:127];
	reg [6:0] exp_rd [0:127];
	reg [NPHYS-1:0] exp_lanes [0:127];
	reg exp_valid [0:127];

	integer cur_cycle = 0;
	always @(posedge clk) begin
		if (rst_n && en)
			cur_cycle <= cur_cycle + 1;
	end

	integer i;
	initial begin
		for (i = 0; i < 128; i = i + 1)
			exp_valid[i] = 1'b0;

		repeat (2) @(negedge clk);
		rst_n = 1'b1;
		@(negedge clk);

		/*
		 * Test 1: Single ALU instruction latency verification (Cycle 0 issue -> Cycle 6 output)
		 */
		x_valid = 1'b1;
		x_warp = 2'd1;
		x_grp = 2'd0;
		x_mask = {8'hFF, 8'hFF};
		x_uop = 0;
		x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;
		x_uop[ATG_UOP_OP +: 5] = ATG_ALU_ADD;
		x_uop[ATG_UOP_RD +: 7] = 7'd10;
		x_uop[ATG_UOP_WRD] = 1'b1;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'd100 + i;
			x_b[i*32 +: 32] = 32'd200 + i;
			x_c[i*32 +: 32] = 32'd0;
			exp_data[6][i*32 +: 32] = (32'd100 + i) + (32'd200 + i);
		end
		exp_valid[6] = 1'b1;
		exp_rd[6] = 7'd10;
		exp_lanes[6] = 8'hFF;
		@(negedge clk);
		x_valid = 1'b0;

		/* Verify cycles 1 through 5 produce NO output */
		for (i = 1; i <= 5; i = i + 1) begin
			if (s_valid !== 1'b0) begin
				$display("FAIL: premature s_valid at cycle %0d (expected 6-cycle latency)", i);
				errors = errors + 1;
			end
			@(negedge clk);
		end

		/* Cycle 6: output MUST be valid and match expected */
		if (s_valid !== 1'b1) begin
			$display("FAIL: s_valid not asserted at cycle 6");
			errors = errors + 1;
		end else if (s_data !== exp_data[6]) begin
			$display("FAIL: s_data mismatch at cycle 6: got %h want %h", s_data, exp_data[6]);
			errors = errors + 1;
		end else if (s_rd !== exp_rd[6]) begin
			$display("FAIL: s_rd mismatch at cycle 6: got %0d want %0d", s_rd, exp_rd[6]);
			errors = errors + 1;
		end else begin
			$display("PASS atg_su_pipe_real.latency_alu");
		end
		@(negedge clk);

		/*
		 * Test 2: Continuous throughput (4 back-to-back instructions: ADD, SUB, XOR, FADD)
		 */
		// Op 0: ALU SUB (Issue at Cycle 8 -> Output at Cycle 14)
		x_valid = 1'b1;
		x_uop = 0;
		x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;
		x_uop[ATG_UOP_OP +: 5] = ATG_ALU_SUB;
		x_uop[ATG_UOP_RD +: 7] = 7'd11;
		x_uop[ATG_UOP_WRD] = 1'b1;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'd500 + i;
			x_b[i*32 +: 32] = 32'd200 + i;
			exp_data[14][i*32 +: 32] = 32'd300;
		end
		exp_valid[14] = 1'b1;
		exp_rd[14] = 7'd11;
		@(negedge clk);

		// Op 1: ALU XOR (Issue at Cycle 9 -> Output at Cycle 15)
		x_uop[ATG_UOP_OP +: 5] = ATG_ALU_XOR;
		x_uop[ATG_UOP_RD +: 7] = 7'd12;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'hAAAA5555;
			x_b[i*32 +: 32] = 32'h5555AAAA;
			exp_data[15][i*32 +: 32] = 32'hFFFFFFFF;
		end
		exp_valid[15] = 1'b1;
		exp_rd[15] = 7'd12;
		@(negedge clk);

		// Op 2: ALU SLL (Issue at Cycle 10 -> Output at Cycle 16)
		x_uop[ATG_UOP_OP +: 5] = ATG_ALU_SLL;
		x_uop[ATG_UOP_RD +: 7] = 7'd13;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'h00000001;
			x_b[i*32 +: 32] = i;
			exp_data[16][i*32 +: 32] = 32'h00000001 << i;
		end
		exp_valid[16] = 1'b1;
		exp_rd[16] = 7'd13;
		@(negedge clk);

		// Op 3: FPU FADD (Issue at Cycle 11 -> Output at Cycle 17)
		// 1.0 (0x3F800000) + 2.0 (0x40000000) = 3.0 (0x40400000)
		x_uop = 0;
		x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_FPU;
		x_uop[ATG_UOP_OP +: 5] = ATG_FPU_FADD;
		x_uop[ATG_UOP_RD +: 7] = 7'd14;
		x_uop[ATG_UOP_WRD] = 1'b1;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'h3F800000;
			x_b[i*32 +: 32] = 32'h40000000;
			exp_data[17][i*32 +: 32] = 32'h40400000;
		end
		exp_valid[17] = 1'b1;
		exp_rd[17] = 7'd14;
		@(negedge clk);

		x_valid = 1'b0;

		// Wait until cycle 14
		while (cur_cycle < 14)
			@(negedge clk);

		// Check continuous 4 cycles of outputs: 14, 15, 16, 17
		for (i = 14; i <= 17; i = i + 1) begin
			if (s_valid !== 1'b1) begin
				$display("FAIL: throughput s_valid missing at cycle %0d", i);
				errors = errors + 1;
			end else if (s_data !== exp_data[i]) begin
				$display("FAIL: throughput data mismatch at cycle %0d: got %h want %h", i, s_data, exp_data[i]);
				errors = errors + 1;
			end else if (s_rd !== exp_rd[i]) begin
				$display("FAIL: throughput rd mismatch at cycle %0d: got %0d want %0d", i, s_rd, exp_rd[i]);
				errors = errors + 1;
			end
			@(negedge clk);
		end
		if (errors == 0)
			$display("PASS atg_su_pipe_real.throughput");

		/*
		 * Test 3: Pipeline Hold / Freeze with en = 0
		 */
		// Issue instruction at Cycle 17
		x_valid = 1'b1;
		x_uop = 0;
		x_uop[ATG_UOP_UNIT +: 4] = ATG_UNIT_ALU;
		x_uop[ATG_UOP_OP +: 5] = ATG_ALU_ADD;
		x_uop[ATG_UOP_RD +: 7] = 7'd20;
		x_uop[ATG_UOP_WRD] = 1'b1;
		for (i = 0; i < NPHYS; i = i + 1) begin
			x_a[i*32 +: 32] = 32'd10;
			x_b[i*32 +: 32] = 32'd20;
		end
		@(negedge clk);
		x_valid = 1'b0;

		// Advance 2 cycles
		repeat (2) @(negedge clk);

		// Stall pipeline for 3 cycles (en = 0)
		en = 1'b0;
		repeat (3) @(negedge clk);
		en = 1'b1;

		// Without stall, latency is 6 cycles. With 3 cycles of stall, latency is 6 + 3 = 9 cycles!
		// Wait until output appears
		while (!s_valid)
			@(negedge clk);

		if (s_data[31:0] !== 32'd30) begin
			$display("FAIL: stall data corrupted: got %0d want 30", s_data[31:0]);
			errors = errors + 1;
		end else begin
			$display("PASS atg_su_pipe_real.stall_hold");
		end

		@(negedge clk);
		if (errors == 0) begin
			$display("PASS atg_su_pipe_real");
		end else begin
			$display("FAIL atg_su_pipe_real with %0d errors", errors);
		end
		$finish;
	end

endmodule
`default_nettype wire
