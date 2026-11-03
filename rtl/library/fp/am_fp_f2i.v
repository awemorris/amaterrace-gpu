/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_f2i: fcvt.w.s / fcvt.wu.s (uns) of the flushed x from its
 * rounded integer n (am_fp_rint, shared with fround in atg_su_fpu):
 * RISC-V saturation, NaN as +inf, negatives to unsigned give 0.
 * Supports LAT = 0 (combinational) and LAT = 1 (pipelined).
 * See spec/library/fp/am_fp_f2i.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_f2i #(
	parameter LAT = 0
) (
	/* verilator lint_off UNUSEDSIGNAL */
	input wire clk,
	input wire rst_n,
	input wire en,
	/* verilator lint_on UNUSEDSIGNAL */
	input wire [31:0] x,
	input wire [24:0] n,
	input wire uns,
	output wire [31:0] r
);
	wire nan = x[30:23] == 8'hFF && x[22:0] != 0;
	wire s = x[31] && !nan;
	wire big = x[30:23] >= 8'd159;
	/* e >= 150: the significand shifted left by e - 150 (0..8 when not
	 * big; the low 5 bits of the difference are e[4:0] - 22) */
	wire [4:0] sh;
	wire [31:0] mw;
	wire [0:0] carry_unused_sh;
	am_sub #(.W(5)) u_sh (.a(x[27:23]), .b(5'd22), .bi(1'b0), .d(sh), .bo(carry_unused_sh[0]));
	am_shift #(.W(32), .SW(5), .DIR(2)) u_mw (.a({8'd0, 1'b1, x[22:0]}), .amt(sh), .left(1'b1), .arith(1'b0), .y(mw));
	wire [31:0] mag = x[30:23] >= 8'd150 ? mw : {7'd0, n};

	generate
	if (LAT == 0) begin : g_lat0
		wire [31:0] neg;
		wire [0:0] carry_unused_neg;
		am_sub #(.W(32)) u_neg (.a(32'd0), .b(mag), .bi(1'b0), .d(neg), .bo(carry_unused_neg[0]));
		assign r = uns ? (s ? 32'd0 : big ? 32'hFFFFFFFF : mag) :
			big || (!s && mag[31]) || (s && mag > 32'h80000000) ? (s ? 32'h80000000 : 32'h7FFFFFFF) :
			s ? neg : mag;
		wire unused_ok0 = &{1'b0, carry_unused_sh, carry_unused_neg};
	end else begin : g_lat1
		reg [31:0] mag_r;
		reg        s_r;
		reg        big_r;
		reg        uns_r;

		always @(posedge clk) begin
			if (!rst_n) begin
				mag_r <= 32'd0;
				s_r   <= 1'b0;
				big_r <= 1'b0;
				uns_r <= 1'b0;
			end else if (en) begin
				mag_r <= mag;
				s_r   <= s;
				big_r <= big;
				uns_r <= uns;
			end
		end

		wire [31:0] neg;
		wire [0:0] carry_unused_neg;
		am_sub #(.W(32)) u_neg (.a(32'd0), .b(mag_r), .bi(1'b0), .d(neg), .bo(carry_unused_neg[0]));
		assign r = uns_r ? (s_r ? 32'd0 : big_r ? 32'hFFFFFFFF : mag_r) :
			big_r || (!s_r && mag_r[31]) || (s_r && mag_r > 32'h80000000) ? (s_r ? 32'h80000000 : 32'h7FFFFFFF) :
			s_r ? neg : mag_r;
		wire unused_ok1 = &{1'b0, carry_unused_sh, carry_unused_neg};
	end
	endgenerate
endmodule

`default_nettype wire
