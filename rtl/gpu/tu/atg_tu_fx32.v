/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fx32: floor(f × 2^sh), saturated to 32 bits; zero, denormal and
 * NaN give 0 (the former function tu_fx32 of include/atg_tu_fn.vh;
 * tools/tumodel.py fx32).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register between barrel shift and negate/clamp
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fx32 #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	input wire [4:0] sh,
	output wire [31:0] q
);
	wire rst_inv = !rst_n;

	/* k = e - 150 + sh: 1.f << k (0 <= k < 8) or >> -k with the sticky (-24 < k < 0) */
	wire [9:0] k_bias;
	(* keep = "true" *) wire [9:0] k_s0, nk_s0;
	wire [31:0] r;
	wire [3:0] carry_unused;
	am_sub #(.W(10)) u_kbias (.a(10'd150), .b({5'd0, sh}), .bi(1'b0), .d(k_bias),
		.bo(carry_unused[0]));
	am_sub #(.W(10)) u_k (.a({2'b00, f[30:23]}), .b(k_bias), .bi(1'b0), .d(k_s0), .bo(carry_unused[1]));
	am_sub #(.W(10)) u_nk (.a(k_bias), .b({2'b00, f[30:23]}), .bi(1'b0), .d(nk_s0), .bo(carry_unused[2]));

	/* Stage 0A -> Stage 0B Pipeline Registers (when LAT >= 2) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  r0_k_a, r0_k_b, r0_k_c;
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  r0_nk_a, r0_nk_b, r0_nk_c;
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r0_f_l, r0_f_r, r0_f_s;
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
		end
	end

	wire [9:0]  k_a   = (LAT >= 2) ? r0_k_a  : k_s0;
	wire [9:0]  k_b   = (LAT >= 2) ? r0_k_b  : k_s0;
	wire [9:0]  k     = (LAT >= 2) ? r0_k_c  : k_s0;
	wire [9:0]  nk_a  = (LAT >= 2) ? r0_nk_a : nk_s0;
	wire [9:0]  nk_b  = (LAT >= 2) ? r0_nk_b : nk_s0;
	wire [9:0]  nk    = (LAT >= 2) ? r0_nk_c : nk_s0;
	wire [31:0] f_s_l = (LAT >= 2) ? r0_f_l  : f;
	wire [31:0] f_s_r = (LAT >= 2) ? r0_f_r  : f;
	wire [31:0] f_s   = (LAT >= 2) ? r0_f_s  : f;

	wire [3:0] kl_s = {4{!k[9] && k[8:3] == 6'd0}};	/* a left shift (0 <= k < 8) */
	wire [3:0] kr_s = {4{k[9] && nk[9:5] == 5'd0 && (nk[4:3] != 2'b11)}};	/* a right shift (-24 < k < 0) */
	wire kr_st = k[9] && nk[9:5] == 5'd0 && (nk[4:3] != 2'b11);
	wire [31:0] qs_l_lo, qs_l_hi, qs_r_lo, qs_r_hi;
	am_shift #(.W(32), .SW(3)) u_qs_l_lo (.a({8'd0, 1'b1, f_s_l[22:0]}), .amt(k_a[2:0]), .left(1'b1),
		.arith(1'b0), .y(qs_l_lo));
	am_shift #(.W(32), .SW(3)) u_qs_l_hi (.a({8'd0, 1'b1, f_s_l[22:0]}), .amt(k_b[2:0]), .left(1'b1),
		.arith(1'b0), .y(qs_l_hi));
	am_shift #(.W(32), .SW(5)) u_qs_r_lo (.a({8'd0, 1'b1, f_s_r[22:0]}), .amt(nk_a[4:0]), .left(1'b0),
		.arith(1'b0), .y(qs_r_lo));
	am_shift #(.W(32), .SW(5)) u_qs_r_hi (.a({8'd0, 1'b1, f_s_r[22:0]}), .amt(nk_b[4:0]), .left(1'b0),
		.arith(1'b0), .y(qs_r_hi));
	wire [31:0] qs_l = {qs_l_hi[31:16], qs_l_lo[15:0]};
	wire [31:0] qs_r = {8'd0, qs_r_hi[23:12], qs_r_lo[11:0]};
	reg st;
	integer b;
	always @(*) begin
		st = k[9] && !kr_st;
		for (b = 0; b < 23; b = b + 1)
			if (kr_st && {27'd0, nk[4:0]} > b)
				st = st | f_s[b];
	end
	(* keep = "true" *) wire [31:0] qv_s0 = {
		kl_s[3] ? qs_l[31:24] : kr_s[3] ? qs_r[31:24] : 8'd0,
		kl_s[2] ? qs_l[23:16] : kr_s[2] ? qs_r[23:16] : 8'd0,
		kl_s[1] ? qs_l[15:8]  : kr_s[1] ? qs_r[15:8]  : 8'd0,
		kl_s[0] ? qs_l[7:0]   : kr_s[0] ? qs_r[7:0]   : 8'd0
	};
	wire st_s0 = st;
	wire sign_s0 = f_s[31];
	wire zero_s0 = (f_s[30:23] == 8'd0) || (f_s[30:23] == 8'hFF && f_s[22:0] != 23'd0);
	wire ovf_s0  = (f_s[30:23] == 8'hFF) || (!k[9] && k[8:3] != 6'd0);

	/* Stage 0 -> Stage 1 Pipeline Registers (when LAT >= 1) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r_qv;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_st;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_sign_r_lo, r_sign_r_hi, r_sign_q_lo, r_sign_q_hi;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_zero_lo, r_zero_hi;
	(* keep = "true", equivalent_register_removal = "no" *) reg r_ovf_lo, r_ovf_hi;

	always @(posedge clk) begin
		if (rst_inv) begin
			r_qv        <= 32'd0;
			r_st        <= 1'b0;
			r_sign_r_lo <= 1'b0;
			r_sign_r_hi <= 1'b0;
			r_sign_q_lo <= 1'b0;
			r_sign_q_hi <= 1'b0;
			r_zero_lo   <= 1'b0;
			r_zero_hi   <= 1'b0;
			r_ovf_lo    <= 1'b0;
			r_ovf_hi    <= 1'b0;
		end else if (en) begin
			r_qv        <= qv_s0;
			r_st        <= st_s0;
			r_sign_r_lo <= sign_s0;
			r_sign_r_hi <= sign_s0;
			r_sign_q_lo <= sign_s0;
			r_sign_q_hi <= sign_s0;
			r_zero_lo   <= zero_s0;
			r_zero_hi   <= zero_s0;
			r_ovf_lo    <= ovf_s0;
			r_ovf_hi    <= ovf_s0;
		end
	end

	wire [31:0] s1_qv   = (LAT >= 1) ? r_qv        : qv_s0;
	wire        s1_st   = (LAT >= 1) ? r_st        : st_s0;
	wire s1_sign_r_lo = (LAT >= 1) ? r_sign_r_lo : sign_s0;
	wire s1_sign_r_hi = (LAT >= 1) ? r_sign_r_hi : sign_s0;
	wire s1_sign_q_lo = (LAT >= 1) ? r_sign_q_lo : sign_s0;
	wire s1_sign_q_hi = (LAT >= 1) ? r_sign_q_hi : sign_s0;
	wire s1_zero_lo   = (LAT >= 1) ? r_zero_lo   : zero_s0;
	wire s1_zero_hi   = (LAT >= 1) ? r_zero_hi   : zero_s0;
	wire s1_ovf_lo    = (LAT >= 1) ? r_ovf_lo    : ovf_s0;
	wire s1_ovf_hi    = (LAT >= 1) ? r_ovf_hi    : ovf_s0;

	/* the negative value -(q + st) = ~q + !st */
	am_add #(.W(32)) u_r (
		.a({s1_sign_r_hi ? ~s1_qv[31:16] : s1_qv[31:16], s1_sign_r_lo ? ~s1_qv[15:0] : s1_qv[15:0]}),
		.b(32'd0),
		.ci(s1_sign_r_lo && !s1_st),
		.s(r),
		.co(carry_unused[3])
	);
	(* keep = "true" *) wire [31:0] q_out;
	assign q_out[15:0]  = s1_zero_lo ? 16'd0 : s1_ovf_lo ? (s1_sign_q_lo ? 16'h0000 : 16'hFFFF) : r[15:0];
	assign q_out[31:16] = s1_zero_hi ? 16'd0 : s1_ovf_hi ? (s1_sign_q_hi ? 16'h8000 : 16'h7FFF) : r[31:16];
	assign q = q_out;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en, f_s_l[31:23], f_s_r[31:23]} : &{1'b0, f_s_l[31:23], f_s_r[31:23]};
	wire unused_ok = &{1'b0, unused_lat0, k_a[9:3], k_b[9:3], nk_a[9:5], nk_b[9:5], qs_l_lo[31:16], qs_l_hi[15:0], qs_r_lo[31:12], qs_r_hi[31:24], qs_r_hi[11:0]};
endmodule

`default_nettype wire
