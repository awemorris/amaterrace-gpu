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
 * include/atg_tu_fn.vh; tools/tumodel.py coord_t).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register between shift and add/clamp
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_coord #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	input wire [1:0] mode,
	output wire signed [29:0] c
);
	/* Stage 0: k = e - 126: 1.f << k (0 <= k < 25) or >> -k with the sticky (-24 < k < 0) */
	wire [9:0] k, nk;
	wire [28:0] qs;
	wire [1:0] carry_unused_0;
	am_sub #(.W(10)) u_k (.a({2'b00, f[30:23]}), .b(10'd126), .bi(1'b0), .d(k),
		.bo(carry_unused_0[0]));
	am_sub #(.W(10)) u_nk (.a(10'd0), .b(k), .bi(1'b0), .d(nk), .bo(carry_unused_0[1]));
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
	wire nan_0 = (f[30:23] == 8'hFF && f[22:0] != 23'd0);
	wire k_ge25_0 = (!k[9] && k >= 10'd25);

	/* Stage 1 Pipeline Registers (LAT >= 1) */
	reg [28:0] r_q;
	reg r_st;
	reg r_sign;
	reg [7:0] r_exp;
	reg r_nan;
	reg r_k_ge25;
	reg [1:0] r_mode;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_q      <= 29'd0;
			r_st     <= 1'b0;
			r_sign   <= 1'b0;
			r_exp    <= 8'd0;
			r_nan    <= 1'b0;
			r_k_ge25 <= 1'b0;
			r_mode   <= 2'd0;
		end else if (en) begin
			r_q      <= q;
			r_st     <= st;
			r_sign   <= f[31];
			r_exp    <= f[30:23];
			r_nan    <= nan_0;
			r_k_ge25 <= k_ge25_0;
			r_mode   <= mode;
		end
	end

	wire [28:0] s_q      = (LAT >= 1) ? r_q      : q;
	wire        s_st     = (LAT >= 1) ? r_st     : st;
	wire        s_sign   = (LAT >= 1) ? r_sign   : f[31];
	wire [7:0]  s_exp    = (LAT >= 1) ? r_exp    : f[30:23];
	wire        s_nan    = (LAT >= 1) ? r_nan    : nan_0;
	wire        s_k_ge25 = (LAT >= 1) ? r_k_ge25 : k_ge25_0;
	wire [1:0]  s_mode   = (LAT >= 1) ? r_mode   : mode;

	/* Stage 2: -(q + st) = ~q + !st, 30 bits (its low 25 bits: the repeat value t) & clamp */
	wire [29:0] tv;
	wire carry_unused_1;
	am_add #(.W(30)) u_tv (
		.a(s_sign ? ~{1'b0, s_q} : {1'b0, s_q}),
		.b(30'd0),
		.ci(s_sign && !s_st),
		.s(tv),
		.co(carry_unused_1)
	);
	wire [24:0] t = tv[24:0];
	wire signed [29:0] tvs = tv;
	assign c = s_exp == 8'd0 || s_nan ? 30'sd0 :
		s_mode[1] && s_exp >= 8'd131 ? (s_sign ? -30'sd268435456 : 30'sd285212672) :
		s_mode[1] ? (tvs < -30'sd268435456 ? -30'sd268435456 : tvs > 30'sd285212672 ? 30'sd285212672 : tvs) :
		s_exp == 8'hFF || s_k_ge25 ? 30'sd0 :
		s_mode[0] ? $signed({5'd0, t}) : $signed({6'd0, t[23:0]});

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, carry_unused_0, carry_unused_1, unused_lat0};
endmodule

`default_nettype wire
