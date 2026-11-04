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
	wire rst_inv = !rst_n;

	/* Stage 0: k = e - 126: 1.f << k (0 <= k < 25) or >> -k with the sticky (-24 < k < 0) */
	(* keep = "true" *) wire [9:0] k_s0, nk_s0;
	wire [1:0] carry_unused_0;
	am_sub #(.W(10)) u_k (.a({2'b00, f[30:23]}), .b(10'd126), .bi(1'b0), .d(k_s0),
		.bo(carry_unused_0[0]));
	am_sub #(.W(10)) u_nk (.a(10'd126), .b({2'b00, f[30:23]}), .bi(1'b0), .d(nk_s0), .bo(carry_unused_0[1]));

	/* Stage 0A -> Stage 0B Pipeline Registers (when LAT >= 2) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  r0_k_a, r0_k_b, r0_k_c;
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  r0_nk_a, r0_nk_b, r0_nk_c;
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r0_f_l, r0_f_r, r0_f_s;
	(* keep = "true", equivalent_register_removal = "no" *) reg [1:0]  r0_mode;
	always @(posedge clk) begin
		if (rst_inv) begin
			r0_k_a  <= 10'd0;
			r0_k_b  <= 10'd0;
			r0_k_c  <= 10'd0;
			r0_nk_a <= 10'd0;
			r0_nk_b <= 10'd0;
			r0_nk_c <= 10'd0;
			r0_f_l  <= 32'd0;
			r0_f_r  <= 32'd0;
			r0_f_s  <= 32'd0;
			r0_mode <= 2'd0;
		end else if (en) begin
			r0_k_a  <= k_s0;
			r0_k_b  <= k_s0;
			r0_k_c  <= k_s0;
			r0_nk_a <= nk_s0;
			r0_nk_b <= nk_s0;
			r0_nk_c <= nk_s0;
			r0_f_l  <= f;
			r0_f_r  <= f;
			r0_f_s  <= f;
			r0_mode <= mode;
		end
	end

	wire [9:0]  k_a    = (LAT >= 2) ? r0_k_a  : k_s0;
	wire [9:0]  k_b    = (LAT >= 2) ? r0_k_b  : k_s0;
	wire [9:0]  k      = (LAT >= 2) ? r0_k_c  : k_s0;
	wire [9:0]  nk_a   = (LAT >= 2) ? r0_nk_a : nk_s0;
	wire [9:0]  nk_b   = (LAT >= 2) ? r0_nk_b : nk_s0;
	wire [9:0]  nk     = (LAT >= 2) ? r0_nk_c : nk_s0;
	wire [31:0] f_s_l  = (LAT >= 2) ? r0_f_l  : f;
	wire [31:0] f_s_r  = (LAT >= 2) ? r0_f_r  : f;
	wire [31:0] f_s    = (LAT >= 2) ? r0_f_s  : f;
	wire [1:0]  mode_s = (LAT >= 2) ? r0_mode : mode;

	wire kl_lo = !k[9] && k[8:5] == 4'd0 && (k[4:3] != 2'b11 || k[2:0] == 3'd0);
	wire kl_hi = !k[9] && k[8:5] == 4'd0 && (k[4:3] != 2'b11 || k[2:0] == 3'd0);
	wire kr_lo = k[9] && nk[9:5] == 5'd0 && (nk[4:3] != 2'b11);
	wire kr_hi = k[9] && nk[9:5] == 5'd0 && (nk[4:3] != 2'b11);
	wire kr_st = k[9] && nk[9:5] == 5'd0 && (nk[4:3] != 2'b11);
	wire [28:0] qs_l_lo, qs_l_hi, qs_r_lo, qs_r_hi;
	am_shift #(.W(29), .SW(5)) u_qs_l_lo (.a({5'd0, 1'b1, f_s_l[22:0]}), .amt(k_a[4:0]), .left(1'b1),
		.arith(1'b0), .y(qs_l_lo));
	am_shift #(.W(29), .SW(5)) u_qs_l_hi (.a({5'd0, 1'b1, f_s_l[22:0]}), .amt(k_b[4:0]), .left(1'b1),
		.arith(1'b0), .y(qs_l_hi));
	am_shift #(.W(29), .SW(5)) u_qs_r_lo (.a({5'd0, 1'b1, f_s_r[22:0]}), .amt(nk_a[4:0]), .left(1'b0),
		.arith(1'b0), .y(qs_r_lo));
	am_shift #(.W(29), .SW(5)) u_qs_r_hi (.a({5'd0, 1'b1, f_s_r[22:0]}), .amt(nk_b[4:0]), .left(1'b0),
		.arith(1'b0), .y(qs_r_hi));
	wire [28:0] qs_l = {qs_l_hi[28:15], qs_l_lo[14:0]};
	wire [28:0] qs_r = {5'd0, qs_r_hi[23:12], qs_r_lo[11:0]};
	reg st;
	integer b;
	always @(*) begin
		st = k[9] && !kr_st;
		for (b = 0; b < 23; b = b + 1)
			if (kr_st && {27'd0, nk[4:0]} > b)
				st = st | f_s[b];
	end
	wire [14:0] q_lo = kl_lo ? qs_l[14:0]  : kr_lo ? qs_r[14:0]  : 15'd0;
	wire [13:0] q_hi = kl_hi ? qs_l[28:15] : kr_hi ? qs_r[28:15] : 14'd0;
	wire [28:0] q = {q_hi, q_lo};
	wire nan_0 = (f_s[30:23] == 8'hFF && f_s[22:0] != 23'd0);
	wire k_ge25_0 = (!k[9] && !kl_lo);

	/* Stage 1 Pipeline Registers (LAT >= 1) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [14:0] r_q_lo;
	(* keep = "true", equivalent_register_removal = "no" *) reg [13:0] r_q_hi;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_st;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_sign_lo, r_sign_hi;
	(* keep = "true", equivalent_register_removal = "no" *) reg [7:0] r_exp;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_nan;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_k_ge25;
	(* keep = "true", equivalent_register_removal = "no" *) reg [1:0] r_mode;

	always @(posedge clk) begin
		if (rst_inv) begin
			r_q_lo    <= 15'd0;
			r_q_hi    <= 14'd0;
			r_st      <= 1'b0;
			r_sign_lo <= 1'b0;
			r_sign_hi <= 1'b0;
			r_exp     <= 8'd0;
			r_nan     <= 1'b0;
			r_k_ge25  <= 1'b0;
			r_mode    <= 2'd0;
		end else if (en) begin
			r_q_lo    <= q_lo;
			r_q_hi    <= q_hi;
			r_st      <= st;
			r_sign_lo <= f_s[31];
			r_sign_hi <= f_s[31];
			r_exp     <= f_s[30:23];
			r_nan     <= nan_0;
			r_k_ge25  <= k_ge25_0;
			r_mode    <= mode_s;
		end
	end

	wire [28:0] s_q      = (LAT >= 1) ? {r_q_hi, r_q_lo} : q;
	wire        s_st     = (LAT >= 1) ? r_st      : st;
	(* keep = "true" *) wire s_sign_lo = (LAT >= 1) ? r_sign_lo : f_s[31];
	(* keep = "true" *) wire s_sign_hi = (LAT >= 1) ? r_sign_hi : f_s[31];
	wire [7:0]  s_exp    = (LAT >= 1) ? r_exp     : f_s[30:23];
	wire        s_nan    = (LAT >= 1) ? r_nan     : nan_0;
	wire        s_k_ge25 = (LAT >= 1) ? r_k_ge25  : k_ge25_0;
	wire [1:0]  s_mode   = (LAT >= 1) ? r_mode    : mode_s;

	/* Stage 2: -(q + st) = ~q + !st, 30 bits (its low 25 bits: the repeat value t) & clamp */
	wire [29:0] tv_s1;
	wire carry_unused_1;
	am_add #(.W(30)) u_tv (
		.a({s_sign_hi ? ~{1'b0, s_q[28:15]} : {1'b0, s_q[28:15]}, s_sign_lo ? ~s_q[14:0] : s_q[14:0]}),
		.b(30'd0),
		.ci(s_sign_lo && !s_st),
		.s(tv_s1),
		.co(carry_unused_1)
	);

	/* Stage 2A -> Stage 2B Pipeline Registers (when LAT >= 2) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [29:0] r2_tv;
	(* keep = "true", equivalent_register_removal = "no" *) reg        r2_sign, r2_nan, r2_k_ge25;
	(* keep = "true", equivalent_register_removal = "no" *) reg [7:0]  r2_exp;
	(* keep = "true", equivalent_register_removal = "no" *) reg [1:0]  r2_mode;
	always @(posedge clk) begin
		if (rst_inv) begin
			r2_tv     <= 30'd0;
			r2_sign   <= 1'b0;
			r2_nan    <= 1'b0;
			r2_k_ge25 <= 1'b0;
			r2_exp    <= 8'd0;
			r2_mode   <= 2'd0;
		end else if (en) begin
			r2_tv     <= tv_s1;
			r2_sign   <= s_sign_lo;
			r2_nan    <= s_nan;
			r2_k_ge25 <= s_k_ge25;
			r2_exp    <= s_exp;
			r2_mode   <= s_mode;
		end
	end

	wire [29:0] tv       = (LAT >= 2) ? r2_tv     : tv_s1;
	wire        f_sign   = (LAT >= 2) ? r2_sign   : s_sign_lo;
	wire        f_nan    = (LAT >= 2) ? r2_nan    : s_nan;
	wire        f_k_ge25 = (LAT >= 2) ? r2_k_ge25 : s_k_ge25;
	wire [7:0]  f_exp    = (LAT >= 2) ? r2_exp    : s_exp;
	wire [1:0]  f_mode   = (LAT >= 2) ? r2_mode   : s_mode;

	wire [24:0] t = tv[24:0];
	wire signed [29:0] tvs = tv;
	wire tv_lt_min = tvs[29] && !tvs[28];
	wire tv_gt_max = !tvs[29] && (tvs[28] && tvs[27:24] != 4'd0 && (tvs[27:24] != 4'd1 || tvs[23:0] != 24'd0));
	wire exp_ge131 = f_exp[7] && (f_exp[6:2] != 5'd0 || f_exp[1:0] == 2'b11);
	(* keep = "true" *) wire zero_nan_lo = (f_exp == 8'd0 || f_nan);
	(* keep = "true" *) wire zero_nan_hi = (f_exp == 8'd0 || f_nan);
	(* keep = "true" *) wire mode1_lo = f_mode[1];
	(* keep = "true" *) wire mode1_hi = f_mode[1];
	(* keep = "true" *) wire mode0_hi = f_mode[0];
	(* keep = "true" *) wire clamp_min_lo = (exp_ge131 ? f_sign : tv_lt_min);
	(* keep = "true" *) wire clamp_min_hi = (exp_ge131 ? f_sign : tv_lt_min);
	(* keep = "true" *) wire clamp_max_lo = (exp_ge131 ? !f_sign : tv_gt_max);
	(* keep = "true" *) wire clamp_max_hi = (exp_ge131 ? !f_sign : tv_gt_max);
	(* keep = "true" *) wire wrap_zero_lo = (f_exp == 8'hFF || f_k_ge25);
	(* keep = "true" *) wire wrap_zero_hi = (f_exp == 8'hFF || f_k_ge25);
	wire [29:0] c_min = -30'sd268435456;
	wire [29:0] c_max =  30'sd285212672;
	wire [29:0] c_wrap = {5'd0, mode0_hi ? t[24] : 1'b0, t[23:0]};

	assign c[14:0] = zero_nan_lo ? 15'd0 :
		mode1_lo ? (clamp_min_lo ? c_min[14:0] : clamp_max_lo ? c_max[14:0] : tvs[14:0]) :
		wrap_zero_lo ? 15'd0 : c_wrap[14:0];
	assign c[29:15] = zero_nan_hi ? 15'd0 :
		mode1_hi ? (clamp_min_hi ? c_min[29:15] : clamp_max_hi ? c_max[29:15] : tvs[29:15]) :
		wrap_zero_hi ? 15'd0 : c_wrap[29:15];

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en, f_s_l[31:23], f_s_r[31:23]} : &{1'b0, f_s_l[31:23], f_s_r[31:23]};
	wire unused_ok = &{1'b0, carry_unused_0, carry_unused_1, unused_lat0, k_a[9:5], k_b[9:5], nk_a[9:5], nk_b[9:5], qs_l_lo[28:15], qs_l_hi[14:0], qs_r_lo[28:12], qs_r_hi[28:24], qs_r_hi[11:0]};
endmodule

`default_nettype wire
