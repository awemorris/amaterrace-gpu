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
 * See spec/library/fp/am_fp_f2i.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_f2i #(
	/* verilator lint_off UNUSEDPARAM */
	parameter LAT = 0
	/* verilator lint_on UNUSEDPARAM */
) (
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
	wire [31:0] mw, neg;
	wire [1:0] carry_unused;
	am_sub #(.W(5)) u_sh (.a(x[27:23]), .b(5'd22), .bi(1'b0), .d(sh), .bo(carry_unused[0]));
	am_shift #(.W(32), .SW(5)) u_mw (.a({8'd0, 1'b1, x[22:0]}), .amt(sh), .left(1'b1), .arith(1'b0), .y(mw));
	wire [31:0] mag = x[30:23] >= 8'd150 ? mw : {7'd0, n};
	am_sub #(.W(32)) u_neg (.a(32'd0), .b(mag), .bi(1'b0), .d(neg), .bo(carry_unused[1]));
	assign r = uns ? (s ? 32'd0 : big ? 32'hFFFFFFFF : mag) :
		big || (!s && mag[31]) || (s && mag > 32'h80000000) ? (s ? 32'h80000000 : 32'h7FFFFFFF) :
		s ? neg : mag;

	wire unused_ok = &{1'b0, carry_unused};
endmodule

`default_nettype wire
