/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_i2f: an integer magnitude n (< 2^32) with sign s to fp32 under
 * rm (am_fp_rnd's modes); 0 gives a zero of the sign.
 * See spec/library/fp/am_fp_i2f.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_i2f #(
	/* verilator lint_off UNUSEDPARAM */
	parameter LAT = 0
	/* verilator lint_on UNUSEDPARAM */
) (
	input wire s,
	input wire [31:0] n,
	input wire [2:0] rm,
	output wire [31:0] r
);
	wire [4:0] msb;
	wire nz;
	am_msb #(.W(32), .SW(5)) u_msb (.a(n), .n(msb), .nz(nz));
	/* the MSB to bit 31 (by 31 - msb = ~msb); the exponent msb + 127 */
	wire [31:0] w;
	wire [11:0] e;
	wire carry_unused;
	am_shift #(.W(32), .SW(5)) u_w (.a(n), .amt(~msb), .left(1'b1), .arith(1'b0), .y(w));
	am_add #(.W(12)) u_e (.a({7'd0, msb}), .b(12'd127), .ci(1'b0), .s(e), .co(carry_unused));
	wire [31:0] rnd;
	am_fp_rnd #(.LAT(0)) u_rnd (.s(s), .e(e), .m(w[31:8]), .g(w[7]), .st(|w[6:0]), .rm(rm), .r(rnd));
	assign r = !nz ? {s, 31'd0} : rnd;

	wire unused_ok = &{1'b0, carry_unused};
endmodule

`default_nettype wire
