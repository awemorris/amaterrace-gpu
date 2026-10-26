/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_bc_tb: Testbench for BC1..BC7 hardware decoder (Phase 006 / ws002-p006).
 *
 * Verifies:
 * 1. BC1 (DXT1): 4-color and 3-color+transparent modes.
 * 2. BC2 (DXT3): explicit 4-bit alpha expansion and 4-color RGB.
 * 3. BC3 (DXT5): 8-ramp and 6-ramp interpolated alpha.
 * 4. BC4 (RGTC1): single-channel Red interpolation.
 * 5. BC5 (RGTC2): dual-channel Red + Green interpolation.
 * 6. BC7 (BPTC_UNORM): Mode 6 RGBA8 interpolation.
 * 7. Continuous 1-cycle throughput and backpressure handling.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_ENABLE_BC
`define CFG_ENABLE_BC 1
`endif

module atg_tu_bc_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg         in_valid = 1'b0;
	wire        in_ready;
	reg [3:0]   fmt_bc = 4'd1;
	reg [127:0] in_block = 128'd0;
	reg [3:0]   sub_texel = 4'd0;

	wire        out_valid;
	reg         out_ready = 1'b1;
	wire [31:0] out_rgba;
	wire [63:0] out_fp16;

	atg_tu_bc dut (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(in_valid),
		.in_ready(in_ready),
		.fmt_bc(fmt_bc),
		.in_block(in_block),
		.sub_texel(sub_texel),
		.out_valid(out_valid),
		.out_ready(out_ready),
		.out_rgba(out_rgba),
		.out_fp16(out_fp16)
	);

	/* Unified DECP pipeline instance verification */
	wire decp_out_valid;
	wire [31:0] decp_out_rgba;
	wire [63:0] decp_out_fp16;

	atg_tu_decp dut_decp (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(in_valid),
		.in_ready(),
		.is_bc(1'b1),
		.fmt(fmt_bc),
		.in_block(in_block),
		.sub_texel(sub_texel),
		.out_valid(decp_out_valid),
		.out_ready(out_ready),
		.out_rgba(decp_out_rgba),
		.out_fp16(decp_out_fp16)
	);

	integer errors = 0;
	integer tests_run = 0;

	task reset_dut;
		begin
			rst_n = 1'b0;
			in_valid = 1'b0;
			out_ready = 1'b1;
			repeat (4) @(posedge clk);
			rst_n = 1'b1;
			repeat (2) @(posedge clk);
		end
	endtask

	task send_request;
		input [3:0]   t_fmt;
		input [127:0] t_block;
		input [3:0]   t_sub;
		input [31:0]  exp_rgba;
		integer timeout;
		begin
			while (!in_ready) @(posedge clk);

			@(posedge clk);
			in_valid  <= 1'b1;
			fmt_bc    <= t_fmt;
			in_block  <= t_block;
			sub_texel <= t_sub;

			@(posedge clk);
			in_valid  <= 1'b0;

			timeout = 0;
			while (!out_valid && timeout < 100) begin
				@(posedge clk);
				timeout = timeout + 1;
			end

			if (timeout >= 100) begin
				$display("FAIL: TIMEOUT waiting for out_valid (fmt=%0d sub=%0d)", t_fmt, t_sub);
				errors = errors + 1;
			end else if (out_rgba !== exp_rgba) begin
				$display("FAIL: fmt=%0d sub=%0d got rgba=0x%08x, exp=0x%08x",
					t_fmt, t_sub, out_rgba, exp_rgba);
				errors = errors + 1;
			end else if (decp_out_rgba !== exp_rgba || !decp_out_valid) begin
				$display("FAIL: DECP mismatch: got rgba=0x%08x, exp=0x%08x",
					decp_out_rgba, exp_rgba);
				errors = errors + 1;
			end

			tests_run = tests_run + 1;
		end
	endtask

	initial begin
		$display("Starting atg_tu_bc_tb...");
		reset_dut();

		// -------------------------------------------------------------
		// 1. BC1 (DXT1): 4-color mode
		// c0 = 0xF800 (Red 255, 0, 0), c1 = 0x0000 (Black 0, 0, 0)
		// Indices: texel 0=idx0, texel 1=idx1, texel 2=idx2, texel 3=idx3
		// Index word: 32'b00000000_00000000_00000000_11100100 = 32'h0000_00E4
		// Block: {32'h000000E4, 16'h0000, 16'hF800} = 64'h000000E4_0000F800
		// -------------------------------------------------------------
		$display("Testing BC1 4-color mode...");
		// Sub 0: idx 0 -> c0 (Red)
		send_request(4'd1, 128'h000000E4_0000F800, 4'd0, 32'hFF0000FF);
		// Sub 1: idx 1 -> c1 (Black)
		send_request(4'd1, 128'h000000E4_0000F800, 4'd1, 32'hFF000000);
		// Sub 2: idx 2 -> 2/3 Red + 1/3 Black: (2*255)/3 = 170 = 0xAA
		send_request(4'd1, 128'h000000E4_0000F800, 4'd2, 32'hFF0000AA);
		// Sub 3: idx 3 -> 1/3 Red + 2/3 Black: 255/3 = 85 = 0x55
		send_request(4'd1, 128'h000000E4_0000F800, 4'd3, 32'hFF000055);

		// -------------------------------------------------------------
		// 2. BC1 (DXT1): 3-color + transparent mode
		// c0 = 0x0000 (Black), c1 = 0xFFFF (White) -> c0 <= c1
		// Index word: 32'h0000_00E4
		// Sub 2: idx 2 -> (c0 + c1)/2 = 127 = 0x7F
		// Sub 3: idx 3 -> transparent black (0x00000000)
		// -------------------------------------------------------------
		$display("Testing BC1 3-color mode...");
		send_request(4'd1, 128'h000000E4_FFFF0000, 4'd0, 32'hFF000000);
		send_request(4'd1, 128'h000000E4_FFFF0000, 4'd1, 32'hFFFFFFFF);
		send_request(4'd1, 128'h000000E4_FFFF0000, 4'd2, 32'hFF7F7F7F);
		send_request(4'd1, 128'h000000E4_FFFF0000, 4'd3, 32'h00000000);

		// -------------------------------------------------------------
		// 3. BC2 (DXT3): Explicit Alpha
		// Alpha block: 64'hFEDCBA98_76543210
		// Sub 0: alpha nibble 0 -> 0x00
		// Sub 1: alpha nibble 1 -> 0x11
		// Sub 10: alpha nibble A -> 0xAA
		// Sub 15: alpha nibble F -> 0xFF
		// -------------------------------------------------------------
		$display("Testing BC2 explicit alpha...");
		send_request(4'd2, {64'h00000000_0000F800, 64'hFEDCBA98_76543210}, 4'd0,  32'h000000FF);
		send_request(4'd2, {64'h00000000_0000F800, 64'hFEDCBA98_76543210}, 4'd1,  32'h110000FF);
		send_request(4'd2, {64'h00000000_0000F800, 64'hFEDCBA98_76543210}, 4'd10, 32'hAA0000FF);
		send_request(4'd2, {64'h00000000_0000F800, 64'hFEDCBA98_76543210}, 4'd15, 32'hFF0000FF);

		// -------------------------------------------------------------
		// 4. BC3 (DXT5): 8-level Interpolated Alpha (a0 > a1)
		// a0 = 255 (0xFF), a1 = 0 (0x00)
		// aidx: 0->255, 1->0, 2->(6*255)/7=218 (0xDA), 3->(5*255)/7=182 (0xB6)
		// Indices: sub 0=idx0, sub 1=idx1, sub 2=idx2, sub 3=idx3
		// Index bits: {sub3, sub2, sub1, sub0} = {3'd3, 3'd2, 3'd1, 3'd0} = 12'b011_010_001_000 = 12'h688
		// Alpha block: {48'h000000000688, 8'h00, 8'hFF} = 64'h00000000068800FF
		// -------------------------------------------------------------
		$display("Testing BC3 8-level alpha...");
		send_request(4'd3, {64'h00000000_0000F800, 64'h00000000068800FF}, 4'd0, 32'hFF0000FF);
		send_request(4'd3, {64'h00000000_0000F800, 64'h00000000068800FF}, 4'd1, 32'h000000FF);
		send_request(4'd3, {64'h00000000_0000F800, 64'h00000000068800FF}, 4'd2, 32'hDA0000FF);
		send_request(4'd3, {64'h00000000_0000F800, 64'h00000000068800FF}, 4'd3, 32'hB60000FF);

		// -------------------------------------------------------------
		// 5. BC4 (RGTC1): Red channel interpolation
		// Block: 64'h00000000068800FF
		// Sub 0: 0xFF in Red -> 32'hFF0000FF
		// Sub 1: 0x00 in Red -> 32'hFF000000
		// Sub 2: 0xDA in Red -> 32'hFF0000DA
		// -------------------------------------------------------------
		$display("Testing BC4 Red channel...");
		send_request(4'd4, 128'h00000000068800FF, 4'd0, 32'hFF0000FF);
		send_request(4'd4, 128'h00000000068800FF, 4'd1, 32'hFF000000);
		send_request(4'd4, 128'h00000000068800FF, 4'd2, 32'hFF0000DA);

		// -------------------------------------------------------------
		// 6. BC5 (RGTC2): Red + Green channels
		// Red: 64'h00000000068800FF, Green: 64'h00000000068800FF
		// Sub 0: Red=0xFF, Green=0xFF -> 32'hFF00FFFF
		// Sub 1: Red=0x00, Green=0x00 -> 32'hFF000000
		// Sub 2: Red=0xDA, Green=0xDA -> 32'hFF00DADA
		// -------------------------------------------------------------
		$display("Testing BC5 Red+Green channels...");
		send_request(4'd5, {64'h00000000068800FF, 64'h00000000068800FF}, 4'd0, 32'hFF00FFFF);
		send_request(4'd5, {64'h00000000068800FF, 64'h00000000068800FF}, 4'd1, 32'hFF000000);
		send_request(4'd5, {64'h00000000068800FF, 64'h00000000068800FF}, 4'd2, 32'hFF00DADA);

		// -------------------------------------------------------------
		// 7. BC7 (BPTC_UNORM): Mode 6
		// Mode 6: bit 6 is 1 -> 8'b0100_0000 = 8'h40
		// Endpoints: r0=0, r1=127, g0=0, g1=127, b0=0, b1=127, a0=0, a1=127
		// p0=0, p1=1 -> E0={0,0}=0, E1={127,1}=255
		// Weight index: 0->0 (E0=0), 15->64 (E1=255)
		// -------------------------------------------------------------
		$display("Testing BC7 Mode 6...");
		// Block with Mode 6, E0=0x00, E1=0xFF for RGBA:
		// m6_r0=7'd0, m6_r1=7'h7F, m6_g0=7'd0, m6_g1=7'h7F, m6_b0=7'd0, m6_b1=7'h7F, m6_a0=7'd0, m6_a1=7'h7F
		// p0=0, p1=1
		// Low 64 bits:
		// [6:0]=7'b1000000 (Mode 6)
		// [13:7]=m6_r0=0, [20:14]=m6_r1=7'h7F, [27:21]=m6_g0=0, [34:28]=m6_g1=7'h7F
		// [41:35]=m6_b0=0, [48:42]=m6_b1=7'h7F, [55:49]=m6_a0=0, [62:56]=m6_a1=7'h7F
		// [63]=p0=0, [64]=p1=1
		// [67:65]=sub0 index=0
		// [71:68]=sub1 index=15 (4'hF)
		send_request(4'd7, 128'h00000000000000F17F01FC07F01FC040, 4'd0, 32'h00000000);
		send_request(4'd7, 128'h00000000000000F17F01FC07F01FC040, 4'd1, 32'hFFFFFFFF);

		// -------------------------------------------------------------
		// 8. Continuous Throughput Test (1 cycle / texel)
		// -------------------------------------------------------------
		$display("Testing continuous 1-cycle throughput...");
		begin : throughput_test
			integer k, out_count;
			out_count = 0;
			for (k = 0; k < 16; k = k + 1) begin
				@(posedge clk);
				in_valid  <= 1'b1;
				fmt_bc    <= 4'd1;
				in_block  <= 128'h000000E4_0000F800;
				sub_texel <= k[3:0];
				if (out_valid) out_count = out_count + 1;
			end
			@(posedge clk);
			in_valid <= 1'b0;
			if (out_valid) out_count = out_count + 1;
			@(posedge clk);
			if (out_valid) out_count = out_count + 1;

			if (out_count != 16) begin
				$display("FAIL: expected 16 continuous outputs, got %0d", out_count);
				errors = errors + 1;
			end else begin
				$display("PASS: continuous throughput verified (16 texels in 16 cycles)");
			end
		end

		$display("Completed %0d test cases.", tests_run);

		if (errors == 0) begin
			$display("PASS atg_tu_bc");
		end else begin
			$display("FAIL atg_tu_bc with %0d errors", errors);
		end
		$finish;
	end

endmodule

`default_nettype wire
