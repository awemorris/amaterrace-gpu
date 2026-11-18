/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_dot: fp32 2-term dot product / plane evaluator.
 * Computes:
 *   r = a0 * b0 + a1 * b1 + c
 *
 * Supports IEEE-754 single precision, denormals flushed, canonical NaN.
 * Under SYNTH_KINTEX7:
 *   Multiplier mantissas mapped to DSP48E1 via am_fp_mul / am_mul.
 * Under ASIC:
 *   Standard PDK synthesis via am_fp_mul and am_fp_add.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module am_fp_dot #(
	parameter LAT = 12
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a0,
	input wire [31:0] i_b0,
	input wire [31:0] i_a1,
	input wire [31:0] i_b1,
	input wire [31:0] i_c,
	output wire o_valid,
	output wire [31:0] o_r
);
	generate
	if (LAT == 0) begin : g_lat0
		wire v_m0, v_m1, v_a0;
		wire [31:0] p0, p1, sum0, r_out;

		am_fp_mul #(.LAT(0)) u_mul0 (
			.clk(clk), .rst_n(rst_n), .i_valid(i_valid),
			.i_a(i_a0), .i_b(i_b0), .o_valid(v_m0), .o_r(p0)
		);
		am_fp_mul #(.LAT(0)) u_mul1 (
			.clk(clk), .rst_n(rst_n), .i_valid(i_valid),
			.i_a(i_a1), .i_b(i_b1), .o_valid(v_m1), .o_r(p1)
		);
		am_fp_add #(.LAT(0)) u_add0 (
			.clk(clk), .rst_n(rst_n), .i_valid(v_m0 && v_m1),
			.i_a(p0), .i_b(p1), .i_sub(1'b0), .o_valid(v_a0), .o_r(sum0)
		);
		am_fp_add #(.LAT(0)) u_add1 (
			.clk(clk), .rst_n(rst_n), .i_valid(v_a0),
			.i_a(sum0), .i_b(i_c), .i_sub(1'b0), .o_valid(o_valid), .o_r(r_out)
		);
		assign o_r = r_out;
	end else begin : g_lat12
		/* Pipelined implementation: 4 cycles mul + 4 cycles add0 + 4 cycles add1 */
		wire v_m0, v_m1, v_a0;
		wire [31:0] p0, p1, sum0;

		/* Shift register to delay i_c by 8 cycles (to match sum0 arrival at u_add1) */
		reg [31:0] c_pipe [0:7];
		integer i;
		always @(posedge clk) begin
			if (rst_n) begin
				c_pipe[0] <= i_c;
				for (i = 1; i < 8; i = i + 1)
					c_pipe[i] <= c_pipe[i-1];
			end
		end

		am_fp_mul #(.LAT(4)) u_mul0 (
			.clk(clk), .rst_n(rst_n), .i_valid(i_valid),
			.i_a(i_a0), .i_b(i_b0), .o_valid(v_m0), .o_r(p0)
		);
		am_fp_mul #(.LAT(4)) u_mul1 (
			.clk(clk), .rst_n(rst_n), .i_valid(i_valid),
			.i_a(i_a1), .i_b(i_b1), .o_valid(v_m1), .o_r(p1)
		);
		am_fp_add #(.LAT(4)) u_add0 (
			.clk(clk), .rst_n(rst_n), .i_valid(v_m0 && v_m1),
			.i_a(p0), .i_b(p1), .i_sub(1'b0), .o_valid(v_a0), .o_r(sum0)
		);
		am_fp_add #(.LAT(4)) u_add1 (
			.clk(clk), .rst_n(rst_n), .i_valid(v_a0),
			.i_a(sum0), .i_b(c_pipe[7]), .i_sub(1'b0), .o_valid(o_valid), .o_r(o_r)
		);
	end
	endgenerate
endmodule

`default_nettype wire
