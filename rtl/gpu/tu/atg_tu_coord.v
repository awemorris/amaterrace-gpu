/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_coord: the normalized coordinate with 24 fraction bits before
 * the texel coordinate: repeat floor(u × 2^24) mod 2^24, mirrored repeat
 * mod 2^25, clamp to edge and border floor(u × 2^24) clamped to
 * [−16, 17] × 2^24 (the former function tu_coord of
 * include/atg_tu_fn.vh; tools/tumodel.py coord_t).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_coord (
	input wire [31:0] f,
	input wire [1:0] mode,
	output wire signed [29:0] c
);
	/* k = e - 126: 1.f << k (0 <= k < 25) or >> -k with the sticky (-24 < k < 0) */
	wire [9:0] k, nk;
	wire [28:0] qs;
	wire [29:0] tv;
	wire [2:0] carry_unused;
	am_sub #(.W(10)) u_k (.a({2'b00, f[30:23]}), .b(10'd126), .bi(1'b0), .d(k),
		.bo(carry_unused[0]));
	am_sub #(.W(10)) u_nk (.a(10'd0), .b(k), .bi(1'b0), .d(nk), .bo(carry_unused[1]));
	wire kl = !k[9] && k < 10'd25;
	wire kr = k[9] && nk < 10'd24;
	am_shift #(.W(29), .SW(5)) u_qs (.a({5'd0, 1'b1, f[22:0]}), .amt(kl ? k[4:0] : nk[4:0]), .left(kl),
		.arith(1'b0), .y(qs));
	reg st;
	integer b;
	always @(*) begin
		st = k[9] && !kr;
		for (b = 0; b < 23; b = b + 1)
			if (kr && b < nk)
				st = st | f[b];
	end
	wire [28:0] q = kl || kr ? qs : 29'd0;
	/* -(q + st) = ~q + !st, 30 bits (its low 25 bits: the repeat value t) */
	am_add #(.W(30)) u_tv (.a(f[31] ? ~{1'b0, q} : {1'b0, q}), .b(30'd0), .ci(f[31] && !st), .s(tv),
		.co(carry_unused[2]));
	wire [24:0] t = tv[24:0];
	wire signed [29:0] tvs = tv;
	assign c = f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ? 30'sd0 :
		mode[1] && f[30:23] >= 8'd131 ? (f[31] ? -30'sd268435456 : 30'sd285212672) :
		mode[1] ? (tvs < -30'sd268435456 ? -30'sd268435456 : tvs > 30'sd285212672 ? 30'sd285212672 : tvs) :
		f[30:23] == 8'hFF || (!k[9] && k >= 10'd25) ? 30'sd0 :
		mode[0] ? $signed({5'd0, t}) : $signed({6'd0, t[23:0]});
endmodule

`default_nettype wire
