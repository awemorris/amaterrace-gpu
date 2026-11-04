/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_lod: the quad's level of detail of texb (part of atg_tu_addr,
 * tools/tumodel.py lod_quad is the reference, bit for bit).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register between magnitude calculation and log2/sum
 * - LAT = 2: 1 cycle in input fixed-point + 1 cycle in magnitude
 * - LAT = 3: 1 cycle in input + 1 cycle in magnitude + 1 cycle in log2/sum output
 * - LAT = 4: 1 cycle in input u_fx + 1 cycle in fa + 1 cycle in magnitude + 1 cycle in log2/sum
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_lod #(
	parameter LAT = 1
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [95:0] u,	/* lanes 0-2, lane 0 in the low bits */
	input wire [95:0] v,
	input wire [95:0] w,	/* the third coordinates (3D) */
	input wire [80:0] cs,	/* cube: s of lanes 0-2 on lane 0's face (27 bits each) */
	input wire [80:0] ct,
	input wire is3d,
	input wire cube,
	input wire [15:0] w0,	/* level 0: width, height, depth (3D) */
	input wire [15:0] h0,
	input wire [15:0] d0,
	input wire [1:0] ax,	/* the axis: 0 u, 1 v, 2 w */
	output wire signed [16:0] lam
);
	`include "atg_tu_fn.vh"
	localparam signed [16:0] LAM_MIN = -17'sd32768;

	wire rst_inv = !rst_n;

	/* Delay cs, ct, w0, h0, d0 for LAT >= 4 to match u_fx pipeline */
	reg [80:0] r_cs, r_ct, r2_cs, r2_ct;
	reg [15:0] r_w0_in, r_h0_in, r_d0_in, r2_w0_in, r2_h0_in, r2_d0_in;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_cs     <= 81'd0;
			r_ct     <= 81'd0;
			r_w0_in  <= 16'd0;
			r_h0_in  <= 16'd0;
			r_d0_in  <= 16'd0;
			r2_cs    <= 81'd0;
			r2_ct    <= 81'd0;
			r2_w0_in <= 16'd0;
			r2_h0_in <= 16'd0;
			r2_d0_in <= 16'd0;
		end else if (en) begin
			r_cs     <= cs;
			r_ct     <= ct;
			r_w0_in  <= w0;
			r_h0_in  <= h0;
			r_d0_in  <= d0;
			r2_cs    <= r_cs;
			r2_ct    <= r_ct;
			r2_w0_in <= r_w0_in;
			r2_h0_in <= r_h0_in;
			r2_d0_in <= r_d0_in;
		end
	end

	wire [80:0] cs_in = (LAT >= 5) ? r2_cs    : (LAT >= 4) ? r_cs    : cs;
	wire [80:0] ct_in = (LAT >= 5) ? r2_ct    : (LAT >= 4) ? r_ct    : ct;
	wire [15:0] w0_in = (LAT >= 5) ? r2_w0_in : (LAT >= 4) ? r_w0_in : w0;
	wire [15:0] h0_in = (LAT >= 5) ? r2_h0_in : (LAT >= 4) ? r_h0_in : h0;
	wire [15:0] d0_in = (LAT >= 5) ? r2_d0_in : (LAT >= 4) ? r_d0_in : d0;

	/* The axis' fixed-point lane values: floor(x × 2^16), or the cube's
	 * >> 8, and its size. */
	wire [95:0] fa_comb;
	genvar gi;
	generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : g_fa
		wire [31:0] fx;
		wire [3:0] ax1_in_s  = {4{ax[1]}};
		wire [3:0] ax0_in_s  = {4{ax[0]}};
		wire [3:0] cube_fa_s = {4{cube && !ax[1]}};
		wire [3:0] ax0_fa_s  = {4{ax[0]}};
		wire [31:0] f_in = {
			ax1_in_s[3] ? w[gi*32 + 24 +: 8] : ax0_in_s[3] ? v[gi*32 + 24 +: 8] : u[gi*32 + 24 +: 8],
			ax1_in_s[2] ? w[gi*32 + 16 +: 8] : ax0_in_s[2] ? v[gi*32 + 16 +: 8] : u[gi*32 + 16 +: 8],
			ax1_in_s[1] ? w[gi*32 + 8  +: 8] : ax0_in_s[1] ? v[gi*32 + 8  +: 8] : u[gi*32 + 8  +: 8],
			ax1_in_s[0] ? w[gi*32 + 0  +: 8] : ax0_in_s[0] ? v[gi*32 + 0  +: 8] : u[gi*32 + 0  +: 8]
		};
		atg_tu_fx32 #(.LAT(LAT >= 5 ? 2 : LAT >= 4 ? 1 : 0)) u_fx (.clk(clk), .rst_n(rst_n), .en(en),
			.f(f_in), .sh(5'd16),
			.q(fx));
		wire [31:0] ct_ext = {{13{ct_in[gi*27 + 26]}}, ct_in[gi*27 + 8 +: 19]};
		wire [31:0] cs_ext = {{13{cs_in[gi*27 + 26]}}, cs_in[gi*27 + 8 +: 19]};
		assign fa_comb[gi*32 + 0  +: 8] = cube_fa_s[0] ? (ax0_fa_s[0] ? ct_ext[7:0]   : cs_ext[7:0])   : fx[7:0];
		assign fa_comb[gi*32 + 8  +: 8] = cube_fa_s[1] ? (ax0_fa_s[1] ? ct_ext[15:8]  : cs_ext[15:8])  : fx[15:8];
		assign fa_comb[gi*32 + 16 +: 8] = cube_fa_s[2] ? (ax0_fa_s[2] ? ct_ext[23:16] : cs_ext[23:16]) : fx[23:16];
		assign fa_comb[gi*32 + 24 +: 8] = cube_fa_s[3] ? (ax0_fa_s[3] ? ct_ext[31:24] : cs_ext[31:24]) : fx[31:24];
	end
	endgenerate
	wire [15:0] n_comb = ax[1] ? d0_in : ax[0] && !cube ? h0_in : w0_in;
	reg [3:0] p_n_comb;
	integer b_n;
	always @(*) begin
		p_n_comb = 4'd0;
		for (b_n = 0; b_n < 16; b_n = b_n + 1)
			if (n_comb[b_n])
				p_n_comb = b_n[3:0];
	end

	/* --- Stage 0A -> Stage 0B Pipeline Registers (LAT >= 2) --- */
	reg [95:0] r_fa;
	reg [15:0] r_n0;
	reg [3:0]  r_p_n;
	reg        r_is3d0;

	always @(posedge clk) begin
		if (rst_inv) begin
			r_fa    <= 96'd0;
			r_n0    <= 16'd0;
			r_p_n   <= 4'd0;
			r_is3d0 <= 1'b0;
		end else if (en) begin
			r_fa    <= fa_comb;
			r_n0    <= n_comb;
			r_p_n   <= p_n_comb;
			r_is3d0 <= is3d;
		end
	end

	wire [95:0] fa       = (LAT >= 2) ? r_fa    : fa_comb;
	wire [15:0] n        = (LAT >= 2) ? r_n0    : n_comb;
	wire [3:0]  p_n      = (LAT >= 2) ? r_p_n   : p_n_comb;
	wire        is3d_s0b = (LAT >= 2) ? r_is3d0 : is3d;

	/* The axis: the lanes' differences to lane 0, the larger magnitude mx */
	wire [32:0] d1, d2, m1, m2;
	wire [6:0] lod_carry_unused;
	am_sub #(.W(33)) u_d1 (.a({fa[63], fa[63:32]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d1),
		.bo(lod_carry_unused[0]));
	am_sub #(.W(33)) u_d2 (.a({fa[95], fa[95:64]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d2),
		.bo(lod_carry_unused[1]));
	wire [23:0] n_ext = {n, 8'd0};
	reg [7:0] m_n_comb;
	integer mn;
	always @(*) begin
		m_n_comb = 8'd0;
		for (mn = 0; mn < 16; mn = mn + 1)
			if (p_n == mn[3:0])
				m_n_comb = n_ext[mn +: 8];
	end
	wire [13:0] nl2_comb = {2'b00, p_n, m_n_comb};

	/* Stage 0B1 -> Stage 0B2 Pipeline Registers (when LAT >= 5) */
	reg [32:0] r_d1, r_d2;
	reg [13:0] r_nl2;
	reg        r_is3d_b1;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_d1      <= 33'd0;
			r_d2      <= 33'd0;
			r_nl2     <= 14'd0;
			r_is3d_b1 <= 1'b0;
		end else if (en) begin
			r_d1      <= d1;
			r_d2      <= d2;
			r_nl2     <= nl2_comb;
			r_is3d_b1 <= is3d_s0b;
		end
	end

	wire [32:0] s_d1    = (LAT >= 5) ? r_d1      : d1;
	wire [32:0] s_d2    = (LAT >= 5) ? r_d2      : d2;
	wire [13:0] s_nl2   = (LAT >= 5) ? r_nl2     : nl2_comb;
	wire        is3d_b1 = (LAT >= 5) ? r_is3d_b1 : is3d_s0b;

	wire d1_s_lo = s_d1[32];
	wire d1_s_hi = s_d1[32];
	wire d2_s_lo = s_d2[32];
	wire d2_s_hi = s_d2[32];
	am_add #(.W(33)) u_m1 (
		.a(33'd0),
		.b({{17{d1_s_hi}} ^ s_d1[32:16], {16{d1_s_lo}} ^ s_d1[15:0]}),
		.ci(d1_s_lo),
		.s(m1),
		.co(lod_carry_unused[2])
	);
	am_add #(.W(33)) u_m2 (
		.a(33'd0),
		.b({{17{d2_s_hi}} ^ s_d2[32:16], {16{d2_s_lo}} ^ s_d2[15:0]}),
		.ci(d2_s_lo),
		.s(m2),
		.co(lod_carry_unused[3])
	);
	wire [4:0] n_bias_hi;
	am_sub #(.W(5)) u_nbias (.a({3'd0, s_nl2[13:12]}), .b(5'd1), .bi(1'b0), .d(n_bias_hi),
		.bo(lod_carry_unused[4]));
	wire [16:0] n_bias_comb = {n_bias_hi, s_nl2[11:0]};

	/* Stage 0B2 -> Stage 0B3 Pipeline Registers (when LAT >= 5) */
	reg [32:0] r_m1, r_m2;
	(* srl_style = "register" *) reg [16:0] r_nbias_b2;
	reg        r_is3d_b2;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_m1       <= 33'd0;
			r_m2       <= 33'd0;
			r_nbias_b2 <= 17'd0;
			r_is3d_b2  <= 1'b0;
		end else if (en) begin
			r_m1       <= m1;
			r_m2       <= m2;
			r_nbias_b2 <= n_bias_comb;
			r_is3d_b2  <= is3d_b1;
		end
	end

	wire [32:0] s_m1       = (LAT >= 5) ? r_m1       : m1;
	wire [32:0] s_m2       = (LAT >= 5) ? r_m2       : m2;
	wire [16:0] s_nbias_b2 = (LAT >= 5) ? r_nbias_b2 : n_bias_comb;
	wire        is3d_b2    = (LAT >= 5) ? r_is3d_b2  : is3d_b1;

	wire [32:0] m_cmp_d_unused;
	wire        m_cmp_bo;
	am_sub #(.W(33)) u_mcmp (.a(s_m1), .b(s_m2), .bi(1'b0), .d(m_cmp_d_unused), .bo(m_cmp_bo));

	/* Stage 0B3 -> Stage 0B4 Pipeline Registers (when LAT >= 5) */
	reg [32:0] r_m1_b3, r_m2_b3;
	reg        r_m1_ge_m2_lo, r_m1_ge_m2_hi;
	(* srl_style = "register" *) reg [16:0] r_nbias_b3;
	reg        r_is3d_b3;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_m1_b3       <= 33'd0;
			r_m2_b3       <= 33'd0;
			r_m1_ge_m2_lo <= 1'b0;
			r_m1_ge_m2_hi <= 1'b0;
			r_nbias_b3    <= 17'd0;
			r_is3d_b3     <= 1'b0;
		end else if (en) begin
			r_m1_b3       <= s_m1;
			r_m2_b3       <= s_m2;
			r_m1_ge_m2_lo <= !m_cmp_bo;
			r_m1_ge_m2_hi <= !m_cmp_bo;
			r_nbias_b3    <= s_nbias_b2;
			r_is3d_b3     <= is3d_b2;
		end
	end

	wire [32:0] s0_mx = (LAT >= 5) ? {
		r_m1_ge_m2_hi ? r_m1_b3[32:16] : r_m2_b3[32:16],
		r_m1_ge_m2_lo ? r_m1_b3[15:0]  : r_m2_b3[15:0]
	} : (!m_cmp_bo ? s_m1 : s_m2);
	wire [16:0] s0_nbias    = (LAT >= 5) ? r_nbias_b3 : s_nbias_b2;
	wire        s0_is3d_out = (LAT >= 5) ? r_is3d_b3  : is3d_b2;

	/* --- Stage 0B -> Stage 1 Pipeline Registers (LAT >= 1) --- */
	reg [32:0] r0_mx;
	(* srl_style = "register" *) reg [16:0] r0_nbias;
	reg        r0_is3d;

	always @(posedge clk) begin
		if (rst_inv) begin
			r0_mx    <= 33'd0;
			r0_nbias <= 17'd0;
			r0_is3d  <= 1'b0;
		end else if (en) begin
			r0_mx    <= s0_mx;
			r0_nbias <= s0_nbias;
			r0_is3d  <= s0_is3d_out;
		end
	end

	wire [32:0] s1_mx    = (LAT >= 1) ? r0_mx    : s0_mx;
	wire [16:0] s1_nbias = (LAT >= 1) ? r0_nbias : s0_nbias;
	wire        s1_is3d  = (LAT >= 1) ? r0_is3d  : s0_is3d_out;

	/* Stage 1A: leading position p of s1_mx (nibble-based priority encoder <= 3 LUTs) */
	reg [5:0] p_mx_comb;
	integer bi;
	always @(*) begin
		p_mx_comb = 6'd0;
		for (bi = 0; bi < 33; bi = bi + 1)
			if (s1_mx[bi])
				p_mx_comb = bi[5:0];
	end
	wire [5:0] p_mx_w = p_mx_comb;
	wire mx_zero_comb = (s1_mx == 33'd0);

	/* Stage 1A -> Stage 1B Pipeline Registers (when LAT >= 5) */
	reg [5:0]  r1a_p_mx_0, r1a_p_mx_1, r1a_p_mx_2, r1a_p_mx_3, r1a_p_mx_c;
	reg [32:0] r1a_mx;
	reg        r1a_mx_zero;
	(* srl_style = "register" *) reg [16:0] r1a_nbias;
	reg        r1a_is3d;
	always @(posedge clk) begin
		if (rst_inv) begin
			r1a_p_mx_0  <= 6'd0;
			r1a_p_mx_1  <= 6'd0;
			r1a_p_mx_2  <= 6'd0;
			r1a_p_mx_3  <= 6'd0;
			r1a_p_mx_c  <= 6'd0;
			r1a_mx      <= 33'd0;
			r1a_mx_zero <= 1'b0;
			r1a_nbias   <= 17'd0;
			r1a_is3d    <= 1'b0;
		end else if (en) begin
			r1a_p_mx_0  <= p_mx_w;
			r1a_p_mx_1  <= p_mx_w;
			r1a_p_mx_2  <= p_mx_w;
			r1a_p_mx_3  <= p_mx_w;
			r1a_p_mx_c  <= p_mx_w;
			r1a_mx      <= s1_mx;
			r1a_mx_zero <= mx_zero_comb;
			r1a_nbias   <= s1_nbias;
			r1a_is3d    <= s1_is3d;
		end
	end

	wire [5:0]  s1b_p_mx_0  = (LAT >= 5) ? r1a_p_mx_0  : p_mx_w;
	wire [5:0]  s1b_p_mx_1  = (LAT >= 5) ? r1a_p_mx_1  : p_mx_w;
	wire [5:0]  s1b_p_mx_2  = (LAT >= 5) ? r1a_p_mx_2  : p_mx_w;
	wire [5:0]  s1b_p_mx_3  = (LAT >= 5) ? r1a_p_mx_3  : p_mx_w;
	wire [5:0]  s1b_p_mx_c  = (LAT >= 5) ? r1a_p_mx_c  : p_mx_w;
	wire [32:0] s1b_mx      = (LAT >= 5) ? r1a_mx      : s1_mx;
	wire        s1b_mx_zero = (LAT >= 5) ? r1a_mx_zero : mx_zero_comb;
	wire [16:0] s1b_nbias   = (LAT >= 5) ? r1a_nbias   : s1_nbias;
	wire        s1b_is3d    = (LAT >= 5) ? r1a_is3d    : s1_is3d;

	wire [40:0] mx_ext = {s1b_mx, 8'd0};
	reg [7:0] m_mx_comb;
	integer mi;
	always @(*) begin
		m_mx_comb = 8'd0;
		for (mi = 0; mi < 33; mi = mi + 1) begin
			if (s1b_p_mx_0 == mi[5:0])
				m_mx_comb[1:0] = mx_ext[mi + 0 +: 2];
			if (s1b_p_mx_1 == mi[5:0])
				m_mx_comb[3:2] = mx_ext[mi + 2 +: 2];
			if (s1b_p_mx_2 == mi[5:0])
				m_mx_comb[5:4] = mx_ext[mi + 4 +: 2];
			if (s1b_p_mx_3 == mi[5:0])
				m_mx_comb[7:6] = mx_ext[mi + 6 +: 2];
		end
	end
	wire [13:0] l2_mx_comb = {s1b_p_mx_c, m_mx_comb};

	/* Stage 1B -> Stage 1C Pipeline Registers (when LAT >= 5) */
	reg [13:0] r1b_l2_mx;
	reg        r1b_mx_zero;
	(* srl_style = "register" *) reg [16:0] r1b_nbias;
	reg        r1b_is3d;
	always @(posedge clk) begin
		if (rst_inv) begin
			r1b_l2_mx   <= 14'd0;
			r1b_mx_zero <= 1'b0;
			r1b_nbias   <= 17'd0;
			r1b_is3d    <= 1'b0;
		end else if (en) begin
			r1b_l2_mx   <= l2_mx_comb;
			r1b_mx_zero <= s1b_mx_zero;
			r1b_nbias   <= s1b_nbias;
			r1b_is3d    <= s1b_is3d;
		end
	end

	wire [13:0] s1c_l2_mx   = (LAT >= 5) ? r1b_l2_mx   : l2_mx_comb;
	wire        s1c_mx_zero = (LAT >= 5) ? r1b_mx_zero : s1b_mx_zero;
	wire [16:0] s1c_nbias   = (LAT >= 5) ? r1b_nbias   : s1b_nbias;
	wire        s1c_is3d    = (LAT >= 5) ? r1b_is3d    : s1b_is3d;

	/* Stage 1C: log2(mx) + (log2(n) - 1.0) (Q8 in a signed 17-bit value). */
	wire [16:0] lsum;
	am_add #(.W(17)) u_lsum (.a({3'd0, s1c_l2_mx}), .b(s1c_nbias), .ci(1'b0), .s(lsum),
		.co(lod_carry_unused[5]));

	/* Stage 1C -> Stage 1D Pipeline Registers (when LAT >= 5) */
	reg [16:0] r1c_lsum;
	reg        r1c_mx_zero;
	reg        r1c_is3d;
	always @(posedge clk) begin
		if (rst_inv) begin
			r1c_lsum    <= 17'd0;
			r1c_mx_zero <= 1'b0;
			r1c_is3d    <= 1'b0;
		end else if (en) begin
			r1c_lsum    <= lsum;
			r1c_mx_zero <= s1c_mx_zero;
			r1c_is3d    <= s1c_is3d;
		end
	end

	wire [16:0] s1d_lsum    = (LAT >= 5) ? r1c_lsum    : lsum;
	wire        s1d_mx_zero = (LAT >= 5) ? r1c_mx_zero : s1c_mx_zero;
	wire        s1d_is3d    = (LAT >= 5) ? r1c_is3d    : s1c_is3d;

	wire signed [16:0] lam_comb = ax[1] && !s1d_is3d ? LAM_MIN : s1d_mx_zero ? LAM_MIN : s1d_lsum;

	/* --- Stage 1 -> Output Pipeline Register (LAT >= 3) --- */
	reg signed [16:0] r_lam;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_lam <= 17'sd0;
		end else if (en) begin
			r_lam <= lam_comb;
		end
	end

	assign lam = (LAT >= 3) ? r_lam : lam_comb;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, cs[7:0], cs[34:27], cs[61:54], ct[7:0], ct[34:27], ct[61:54], unused_lat0, m_cmp_d_unused, lod_carry_unused[6], mx_ext[40]};
endmodule

`default_nettype wire
