/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_i2f: an integer magnitude n (< 2^32) with sign s to fp32 under
 * rm (atg_su_rnd's modes); 0 gives a zero of the sign (the former
 * function atg_su_i2f of include/atg_su_fp.vh; tools/gsi1fp.py).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_i2f (
	input wire s,
	input wire [31:0] n,
	input wire [2:0] rm,
	output wire [31:0] r
);
	reg [4:0] msb;
	integer i;
	always @(*) begin
		msb = 5'd0;
		for (i = 0; i < 32; i = i + 1)
			if (n[i])
				msb = i[4:0];
	end
	/* the MSB to bit 31 (by 31 - msb = ~msb); the exponent msb + 127 */
	wire [31:0] w;
	wire [11:0] e;
	wire carry_unused;
	am_shift #(.W(32), .SW(5)) u_w (.a(n), .amt(~msb), .left(1'b1), .arith(1'b0), .y(w));
	am_add #(.W(12)) u_e (.a({7'd0, msb}), .b(12'd127), .ci(1'b0), .s(e), .co(carry_unused));
	wire [31:0] rnd;
	atg_su_rnd u_rnd (.s(s), .e(e), .m(w[31:8]), .g(w[7]), .st(|w[6:0]), .rm(rm), .r(rnd));
	assign r = n == 32'd0 ? {s, 31'd0} : rnd;

	wire unused_ok = &{1'b0, carry_unused};
endmodule

`default_nettype wire
