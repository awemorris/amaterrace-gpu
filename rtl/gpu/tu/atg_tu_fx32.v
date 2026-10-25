/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fx32: floor(f × 2^sh), saturated to 32 bits; zero, denormal and
 * NaN give 0 (the former function tu_fx32 of include/atg_tu_fn.vh;
 * tools/tumodel.py fx32).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fx32 (
	input wire [31:0] f,
	input wire [4:0] sh,
	output wire [31:0] q
);
	/* k = e - 150 + sh: 1.f << k (0 <= k < 8) or >> -k with the sticky (-24 < k < 0) */
	wire [9:0] es, k, nk;
	wire [31:0] qs, r;
	wire [3:0] carry_unused;
	am_add #(.W(10)) u_es (.a({2'b00, f[30:23]}), .b({5'd0, sh}), .ci(1'b0), .s(es),
		.co(carry_unused[0]));
	am_sub #(.W(10)) u_k (.a(es), .b(10'd150), .bi(1'b0), .d(k), .bo(carry_unused[1]));
	am_sub #(.W(10)) u_nk (.a(10'd0), .b(k), .bi(1'b0), .d(nk), .bo(carry_unused[2]));
	wire kl = !k[9] && k < 10'd8;	/* a left shift */
	wire kr = k[9] && nk < 10'd24;	/* a right shift */
	am_shift #(.W(32), .SW(5)) u_qs (.a({8'd0, 1'b1, f[22:0]}), .amt(kl ? k[4:0] : nk[4:0]), .left(kl),
		.arith(1'b0), .y(qs));
	reg st;
	integer b;
	always @(*) begin
		st = k[9] && !kr;
		for (b = 0; b < 23; b = b + 1)
			if (kr && b < nk)
				st = st | f[b];
	end
	wire [31:0] qv = kl || kr ? qs : 32'd0;
	/* the negative value -(q + st) = ~q + !st */
	am_add #(.W(32)) u_r (.a(f[31] ? ~qv : qv), .b(32'd0), .ci(f[31] && !st), .s(r),
		.co(carry_unused[3]));
	assign q = f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ? 32'd0 :
		f[30:23] == 8'hFF || (!k[9] && k >= 10'd8) ? (f[31] ? 32'h80000000 : 32'h7FFFFFFF) : r;
endmodule

`default_nettype wire
