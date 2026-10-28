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

	/* Delay cs, ct, w0, h0, d0 for LAT >= 4 to match u_fx pipeline */
	reg [80:0] r_cs, r_ct;
	reg [15:0] r_w0_in, r_h0_in, r_d0_in;
	always @(posedge clk) begin
		if (!rst_n) begin
			r_cs    <= 81'd0;
			r_ct    <= 81'd0;
			r_w0_in <= 16'd0;
			r_h0_in <= 16'd0;
			r_d0_in <= 16'd0;
		end else if (en) begin
			r_cs    <= cs;
			r_ct    <= ct;
			r_w0_in <= w0;
			r_h0_in <= h0;
			r_d0_in <= d0;
		end
	end

	wire [80:0] cs_in = (LAT >= 4) ? r_cs    : cs;
	wire [80:0] ct_in = (LAT >= 4) ? r_ct    : ct;
	wire [15:0] w0_in = (LAT >= 4) ? r_w0_in : w0;
	wire [15:0] h0_in = (LAT >= 4) ? r_h0_in : h0;
	wire [15:0] d0_in = (LAT >= 4) ? r_d0_in : d0;

	/* The axis' fixed-point lane values: floor(x × 2^16), or the cube's
	 * >> 8, and its size. */
	wire [95:0] fa_comb;
	genvar gi;
	generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : g_fa
		wire [31:0] fx;
		atg_tu_fx32 #(.LAT(LAT >= 4 ? 1 : 0)) u_fx (.clk(clk), .rst_n(rst_n), .en(en),
			.f(ax[1] ? w[gi*32 +: 32] : ax[0] ? v[gi*32 +: 32] : u[gi*32 +: 32]), .sh(5'd16),
			.q(fx));
		assign fa_comb[gi*32 +: 32] = cube && !ax[1] ? (ax[0] ? {{13{ct_in[gi*27 + 26]}}, ct_in[gi*27 + 8 +: 19]} :
			{{13{cs_in[gi*27 + 26]}}, cs_in[gi*27 + 8 +: 19]}) : fx;
	end
	endgenerate
	wire [15:0] n_comb = ax[1] ? d0_in : ax[0] && !cube ? h0_in : w0_in;

	/* --- Stage 0A -> Stage 0B Pipeline Registers (LAT >= 2) --- */
	reg [95:0] r_fa;
	reg [15:0] r_n0;
	reg        r_is3d0;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_fa    <= 96'd0;
			r_n0    <= 16'd0;
			r_is3d0 <= 1'b0;
		end else if (en) begin
			r_fa    <= fa_comb;
			r_n0    <= n_comb;
			r_is3d0 <= is3d;
		end
	end

	wire [95:0] fa       = (LAT >= 2) ? r_fa    : fa_comb;
	wire [15:0] n        = (LAT >= 2) ? r_n0    : n_comb;
	wire        is3d_s0b = (LAT >= 2) ? r_is3d0 : is3d;

	/* The axis: the lanes' differences to lane 0, the larger magnitude mx */
	wire [32:0] d1, d2, m1, m2;
	wire [5:0] lod_carry_unused;
	am_sub #(.W(33)) u_d1 (.a({fa[63], fa[63:32]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d1),
		.bo(lod_carry_unused[0]));
	am_sub #(.W(33)) u_d2 (.a({fa[95], fa[95:64]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d2),
		.bo(lod_carry_unused[1]));
	am_addsub #(.W(33)) u_m1 (.a(33'd0), .b(d1), .sub(d1[32]), .s(m1), .co(lod_carry_unused[2]));
	am_addsub #(.W(33)) u_m2 (.a(33'd0), .b(d2), .sub(d2[32]), .s(m2), .co(lod_carry_unused[3]));
	wire [32:0] s0_mx = m1 > m2 ? m1 : m2;

	/* --- Stage 0B -> Stage 1 Pipeline Registers (LAT >= 1) --- */
	wire [16:0] n_bias_comb;
	am_sub #(.W(17)) u_nbias (.a({3'd0, tu_l2({17'd0, n})}), .b(17'd4096), .bi(1'b0), .d(n_bias_comb),
		.bo(lod_carry_unused[4]));

	reg [32:0] r0_mx;
	reg [16:0] r0_nbias;
	reg        r0_is3d;

	always @(posedge clk) begin
		if (!rst_n) begin
			r0_mx    <= 33'd0;
			r0_nbias <= 17'd0;
			r0_is3d  <= 1'b0;
		end else if (en) begin
			r0_mx    <= s0_mx;
			r0_nbias <= n_bias_comb;
			r0_is3d  <= is3d_s0b;
		end
	end

	wire [32:0] s1_mx    = (LAT >= 1) ? r0_mx    : s0_mx;
	wire [16:0] s1_nbias = (LAT >= 1) ? r0_nbias : n_bias_comb;
	wire        s1_is3d  = (LAT >= 1) ? r0_is3d  : is3d_s0b;

	/* Stage 1: log2(mx) + (log2(n) - 1.0) (Q8 in a signed 17-bit value). */
	wire [16:0] lsum;
	am_add #(.W(17)) u_lsum (.a({3'd0, tu_l2(s1_mx)}), .b(s1_nbias), .ci(1'b0), .s(lsum),
		.co(lod_carry_unused[5]));
	wire signed [16:0] lam_comb = ax[1] && !s1_is3d ? LAM_MIN : s1_mx == 33'd0 ? LAM_MIN : lsum;

	/* --- Stage 1 -> Output Pipeline Register (LAT >= 3) --- */
	reg signed [16:0] r_lam;
	always @(posedge clk) begin
		if (!rst_n) begin
			r_lam <= 17'sd0;
		end else if (en) begin
			r_lam <= lam_comb;
		end
	end

	assign lam = (LAT >= 3) ? r_lam : lam_comb;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, cs[7:0], cs[34:27], cs[61:54], ct[7:0], ct[34:27], ct[61:54], unused_lat0};
endmodule

`default_nettype wire
