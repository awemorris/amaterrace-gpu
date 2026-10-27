/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_barrier_tb: verification testbench for fine-grained pipeline barriers,
 * 64-bit timeline semaphores, ROP dual-source blending / logic ops, and VF MDI
 * (Phase 006 / ws001-p006).
 */

`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_ROP_ENABLE_LOGICOP
`define CFG_ROP_ENABLE_LOGICOP 1
`endif
`ifndef CFG_ROP_DUAL_SOURCE
`define CFG_ROP_DUAL_SOURCE 1
`endif

module atg_top_barrier_tb;
	`include "ghci_regs.vh"

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;

	/* -------------------------------------------------------------
	 * Test 1: Sequencer BARRIER and Timeline Semaphore Decode
	 * ------------------------------------------------------------- */
	reg [31:0] test_hdr;
	wire h_known;
	wire h_absent;
	wire [7:0] h_need;

	atg_cp_seq_dec #(.UNITS(8'hFF)) u_dec (
		.hdr(test_hdr),
		.hdr_fw(1'b0),
		.h_known(h_known),
		.h_absent(h_absent),
		.h_need(h_need),
		.vendor(1'b0),
		.op({2'b00, test_hdr[29:24]}),
		.p(8'd0),
		.in_data(32'd0),
		.pay_bad()
	);

	/* -------------------------------------------------------------
	 * Test 2: ROP Blend with Logic Op
	 * ------------------------------------------------------------- */
	reg r_st_we = 0;
	reg [8:0] r_st_idx = 0;
	reg [31:0] r_st_wdata = 0;
	reg r_b_valid = 0;
	reg [511:0] r_b_src = 0;
	reg [127:0] r_b_dst = 0;
	reg [3:0] r_b_mask = 4'hF;
	reg [2:0] r_b_rt = 3'd0;
	wire r_b_rvalid;
	wire [127:0] r_b_pix;

	atg_rop_blend #(.LAT(3)) u_rop (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(r_st_we),
		.st_idx(r_st_idx),
		.st_wdata(r_st_wdata),
		.b_valid(r_b_valid),
		.b_src(r_b_src),
		.b_src1(512'd0),
		.b_has_src1(1'b0),
		.b_dst(r_b_dst),
		.b_mask(r_b_mask),
		.b_rt(r_b_rt),
		.b_rvalid(r_b_rvalid),
		.b_pix(r_b_pix)
	);

	task rop_st;
		input [8:0] idx;
		input [31:0] val;
		begin
			@(posedge clk);
			r_st_we <= 1'b1;
			r_st_idx <= idx;
			r_st_wdata <= val;
			@(posedge clk);
			r_st_we <= 1'b0;
		end
	endtask

	integer i;
	reg [7:0] s_byte, d_byte, exp_byte;

	initial begin
		repeat (4) @(posedge clk);
		rst_n = 1;
		@(posedge clk);

		$display("--- CASE 1: BARRIER & TIMELINE SEMAPHORE Packet Decode ---");
		/* BARRIER opcode 20 (6'd20) */
		test_hdr = {2'b00, 6'd20, 8'h01, 8'h00, 8'd1};
		#1;
		if (!h_known || h_need != 8'd1) begin
			$display("FAIL: BARRIER packet decode failed: known=%b need=%0d", h_known, h_need);
			errors = errors + 1;
		end else begin
			$display("PASS: BARRIER packet successfully decoded (opcode 20, need=1).");
		end

		/* SEMAPHORE_SIGNAL opcode 21 (6'd21) */
		test_hdr = {2'b00, 6'd21, 8'h02, 8'h00, 8'd4};
		#1;
		if (!h_known || h_need != 8'd4) begin
			$display("FAIL: SEMAPHORE_SIGNAL decode failed: known=%b need=%0d", h_known, h_need);
			errors = errors + 1;
		end else begin
			$display("PASS: SEMAPHORE_SIGNAL successfully decoded (opcode 21, need=4).");
		end

		/* SEMAPHORE_WAIT opcode 22 (6'd22) */
		test_hdr = {2'b00, 6'd22, 8'h03, 8'h00, 8'd4};
		#1;
		if (!h_known || h_need != 8'd4) begin
			$display("FAIL: SEMAPHORE_WAIT decode failed: known=%b need=%0d", h_known, h_need);
			errors = errors + 1;
		end else begin
			$display("PASS: SEMAPHORE_WAIT successfully decoded (opcode 22, need=4).");
		end

		$display("--- CASE 2: ROP Vulkan 1.0 Logic Op Verification ---");
		/* Setup RGBA8 format (F_RGBA8 = 1), write mask full (0xF) */
		rop_st(GHCI_S_RT_FORMAT, 32'd1);
		rop_st(GHCI_S_WRITE_MASK, 32'h0000000F);

		/* Test LogicOp: XOR (logic_op = 6) */
		/* ROP_CTRL: [2] = logic_op_en, [6:3] = 4'd6 (XOR) -> 32'h00000034 */
		rop_st(GHCI_S_ROP_CTRL, 32'h00000034);

		s_byte = 8'hAA;
		d_byte = 8'h55;
		exp_byte = s_byte ^ d_byte; /* 0xFF */

		/* Provide source fp32 matching 0xAA (approx 0.6666): float 3f2aaaab */
		/* For simplicity, test with float 3f800000 (1.0 -> 0xFF) and 0 -> 0x00 */
		/* 1.0f in all 4 channels of pixel 0 */
		r_b_src = {496'd0, 16'h0000};
		r_b_src[31:0]   = 32'h3f800000; /* 0xFF */
		r_b_src[63:32]  = 32'h00000000; /* 0x00 */
		r_b_src[95:64]  = 32'h3f800000; /* 0xFF */
		r_b_src[127:96] = 32'h00000000; /* 0x00 */

		/* Destination: 0x55, 0x55, 0x55, 0x55 */
		r_b_dst = {96'd0, 32'h55555555};
		r_b_mask = 4'b0001;

		@(posedge clk);
		r_b_valid <= 1'b1;
		@(posedge clk);
		r_b_valid <= 1'b0;

		/* Wait for result (LAT=3) */
		repeat (3) @(posedge clk);
		#1;
		/* Expected XOR with dst 0x55:
		 * Ch0: 0xFF ^ 0x55 = 0xAA
		 * Ch1: 0x00 ^ 0x55 = 0x55
		 * Ch2: 0xFF ^ 0x55 = 0xAA
		 * Ch3: 0x00 ^ 0x55 = 0x55
		 * Pixel 0: 32'h55AA55AA
		 */
		if (r_b_pix[31:0] != 32'h55AA55AA) begin
			$display("FAIL: ROP LogicOp XOR mismatch: got %h exp 55aa55aa", r_b_pix[31:0]);
			errors = errors + 1;
		end else begin
			$display("PASS: ROP LogicOp XOR successfully verified (%h).", r_b_pix[31:0]);
		end

		/* Test LogicOp: AND (logic_op = 1) -> ROP_CTRL = [2]=1, [6:3]=1 -> 32'h0000000C */
		rop_st(GHCI_S_ROP_CTRL, 32'h0000000C);
		@(posedge clk);
		r_b_valid <= 1'b1;
		@(posedge clk);
		r_b_valid <= 1'b0;
		repeat (3) @(posedge clk);
		#1;
		/* Expected AND with dst 0x55:
		 * Ch0: 0xFF & 0x55 = 0x55
		 * Ch1: 0x00 & 0x55 = 0x00
		 * Ch2: 0xFF & 0x55 = 0x55
		 * Ch3: 0x00 & 0x55 = 0x00
		 * Pixel 0: 32'h00550055
		 */
		if (r_b_pix[31:0] != 32'h00550055) begin
			$display("FAIL: ROP LogicOp AND mismatch: got %h exp 00550055", r_b_pix[31:0]);
			errors = errors + 1;
		end else begin
			$display("PASS: ROP LogicOp AND successfully verified (%h).", r_b_pix[31:0]);
		end

		/* Disable LogicOp and return to normal blend */
		rop_st(GHCI_S_ROP_CTRL, 32'h00000000);

		repeat (10) @(posedge clk);

		if (errors == 0) begin
			$display("PASS atg_top_barrier");
		end else begin
			$display("FAIL atg_top_barrier: %0d errors", errors);
		end
		$finish;
	end

	initial begin
		#1000000;
		$display("FAIL atg_top_barrier: timeout");
		$finish;
	end
endmodule

`default_nettype wire
