/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_f2unorm: 3-stage pipelined fp32 to W_CONST-bit UNORM (LAT = 3) for ROP pipeline.
 *   - Stage 1: Direct-from-register 36-bit subtraction p = (m << W_CONST) - m (Pre-LUTs = 1, Post-LUTs = 0),
 *              plus pure-LUT exponent shift decode sa = 22 - f[28:23], sa1 = 21 - f[28:23].
 *   - Stage 2: Pure-LUT barrel shift ps = p >> sa, guard bit g = p[sa1], and nibble sticky st (<= 3 LUT levels, 0 CARRY4s).
 *   - Stage 3: Pure-LUT 2-level RNE increment and [0, 1] clamp mux (<= 3 LUT levels, 0 CARRY4s).
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_f2unorm #(
	parameter integer W_CONST = 10
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	output wire [15:0] u
);
	localparam [15:0] ONES_CONST = (16'h0001 << W_CONST) - 16'h0001;
	(* keep = "true" *) wire rst_sync = !rst_n;

	wire [3:0] en_s1_buf = {4{en}};
	wire [3:0] en_s2_buf = {4{en}};
	wire [1:0] en_s3_buf = {2{en}};

	/* =========================================================================
	 * STAGE 1: Mantissa Scale Subtract & Shift Amount Decode
	 *          u_p has Pre-LUTs = 1 and Post-LUTs = 0 (registered directly into r1_p)
	 * ========================================================================= */
	wire [35:0] m_padded = {12'd0, 1'b1, f[22:0]};
	wire [35:0] pw = m_padded << W_CONST;
	wire [35:0] p_s1;
	wire p_bo_unused;

	am_sub #(.W(36)) u_p (
		.a(pw),
		.b(m_padded),
		.bi(1'b0),
		.d(p_s1),
		.bo(p_bo_unused)
	);

	wire [5:0] sa_s1, sa1_s1;
	wire sa_bo_unused, sa1_bo_unused;
	am_sub #(.W(6)) u_sub_sa  (.a(6'd22), .b(f[28:23]), .bi(1'b0), .d(sa_s1),  .bo(sa_bo_unused));
	am_sub #(.W(6)) u_sub_sa1 (.a(6'd21), .b(f[28:23]), .bi(1'b0), .d(sa1_s1), .bo(sa1_bo_unused));

	/* Pure-LUT exponent & NaN classification (0 CARRY4s, <= 3 LUT levels) */
	(* keep = "true" *) wire [3:0] f_mnz;
	assign f_mnz[0] = (f[5:0]   != 6'd0);
	assign f_mnz[1] = (f[11:6]  != 6'd0);
	assign f_mnz[2] = (f[17:12] != 6'd0);
	assign f_mnz[3] = (f[22:18] != 5'd0);
	(* keep = "true" *) wire is_nan_s1 = (f[30:23] == 8'hFF) && (|f_mnz);
	(* keep = "true" *) wire exp_lt_103 = (!f[30]) && ((f[29:28] != 2'b11) || (!f[27] && (!f[26] && !(&f[25:23]))));
	(* keep = "true" *) wire exp_ge_127 = f[30] || (&f[29:23]);
	wire is_zero_s1 = f[31] || is_nan_s1 || exp_lt_103;
	wire is_max_s1  = (!is_zero_s1) && exp_ge_127;

	/* Stage 1 -> Stage 2 Pipeline Registers */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [35:0] r1_p;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [5:0]  r1_sa_a, r1_sa_b;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [5:0]  r1_sa1_a, r1_sa1_b;
	reg r1_is_zero, r1_is_max;

	/* =========================================================================
	 * STAGE 2: Alignment Shift ps = p >> sa, Guard Bit g = p[sa1], Nibble Sticky st
	 *          (0 CARRY4s, strictly <= 3 LUT levels)
	 * ========================================================================= */
	wire [50:0] p51 = {15'd0, r1_p};

	/* 3-level 4:1 barrel right shifter for ps[15:0] (fanout <= 16) */
	(* keep = "true" *) wire [47:0] ps_s0;
	(* keep = "true" *) wire [35:0] ps_s1;
	(* keep = "true" *) wire [15:0] ps_s2;
	genvar gsi;
	generate
	for (gsi = 0; gsi < 48; gsi = gsi + 1) begin : g_ps_s0
		assign ps_s0[gsi] = (r1_sa_a[1:0] == 2'd0) ? p51[gsi] :
		                    (r1_sa_a[1:0] == 2'd1) ? p51[gsi + 1] :
		                    (r1_sa_a[1:0] == 2'd2) ? p51[gsi + 2] : p51[gsi + 3];
	end
	for (gsi = 0; gsi < 36; gsi = gsi + 1) begin : g_ps_s1
		assign ps_s1[gsi] = (r1_sa_a[3:2] == 2'd0) ? ps_s0[gsi] :
		                    (r1_sa_a[3:2] == 2'd1) ? ps_s0[gsi + 4] :
		                    (r1_sa_a[3:2] == 2'd2) ? ps_s0[gsi + 8] : ps_s0[gsi + 12];
	end
	for (gsi = 0; gsi < 16; gsi = gsi + 1) begin : g_ps_s2
		localparam integer IDX32 = (gsi < 4) ? (gsi + 32) : 35;
		wire hi32 = (gsi < 4) ? ps_s1[IDX32] : 1'b0;
		assign ps_s2[gsi] = (r1_sa_b[5:4] == 2'd0) ? ps_s1[gsi] :
		                    (r1_sa_b[5:4] == 2'd1) ? ps_s1[gsi + 16] :
		                    (r1_sa_b[5:4] == 2'd2) ? hi32 : 1'b0;
	end
	endgenerate

	/* 3-level mux for g = p48[r1_sa1_a] */
	(* keep = "true" *) wire [8:0] g_nib;
	genvar gn;
	generate
	for (gn = 0; gn < 9; gn = gn + 1) begin : g_guard_nib
		wire [3:0] pn = r1_p[4 * gn +: 4];
		assign g_nib[gn] = (r1_sa1_a[1:0] == 2'd0) ? pn[0] :
		                   (r1_sa1_a[1:0] == 2'd1) ? pn[1] :
		                   (r1_sa1_a[1:0] == 2'd2) ? pn[2] : pn[3];
	end
	endgenerate
	(* keep = "true" *) wire g_grp0 = (r1_sa1_a[3:2] == 2'd0) ? g_nib[0] :
	                                  (r1_sa1_a[3:2] == 2'd1) ? g_nib[1] :
	                                  (r1_sa1_a[3:2] == 2'd2) ? g_nib[2] : g_nib[3];
	(* keep = "true" *) wire g_grp1 = (r1_sa1_a[3:2] == 2'd0) ? g_nib[4] :
	                                  (r1_sa1_a[3:2] == 2'd1) ? g_nib[5] :
	                                  (r1_sa1_a[3:2] == 2'd2) ? g_nib[6] : g_nib[7];
	wire g_s2 = (r1_sa1_a[5:4] == 2'd0) ? g_grp0 :
	            (r1_sa1_a[5:4] == 2'd1) ? g_grp1 :
	            (r1_sa1_a[5:2] == 4'd8) ? g_nib[8] : 1'b0;

	/* Nibble-based sticky bit st = (p48 & ~({48{1'b1}} << r1_sa1_b)) != 0 (3 LUT levels) */
	(* keep = "true" *) wire [8:0] st_nib;
	generate
	for (gn = 0; gn < 9; gn = gn + 1) begin : g_st_nib
		localparam [3:0] N_IDX = gn[3:0];
		wire [3:0] pn = r1_p[4 * gn +: 4];
		(* keep = "true" *) wire nib_or = |pn;
		(* keep = "true" *) wire nib_part = (r1_sa1_b[1:0] == 2'd0) ? 1'b0 :
		                                    (r1_sa1_b[1:0] == 2'd1) ? pn[0] :
		                                    (r1_sa1_b[1:0] == 2'd2) ? (|pn[1:0]) : (|pn[2:0]);
		assign st_nib[gn] = (r1_sa1_b[5:2] > N_IDX) ? nib_or :
		                    (r1_sa1_b[5:2] == N_IDX) ? nib_part : 1'b0;
	end
	endgenerate
	wire st_lo_s2 = |st_nib[4:0];
	wire st_hi_s2 = |st_nib[8:5];

	/* Stage 2 -> Stage 3 Pipeline Registers */
	reg [15:0] r2_ps;
	reg        r2_g, r2_st_lo, r2_st_hi;
	reg        r2_is_zero, r2_is_max;

	/* =========================================================================
	 * STAGE 3: 2-Level Pure-LUT Increment & Clamp Output Register
	 *          (0 CARRY4s, <= 3 LUT levels)
	 * ========================================================================= */
	(* keep = "true" *) wire round_ci = r2_g && (r2_st_lo || r2_st_hi || r2_ps[0]);
	(* keep = "true" *) wire c_lo5 = round_ci & (&r2_ps[4:0]);
	(* keep = "true" *) wire c_mid10 = round_ci & (&r2_ps[4:0]) & (&r2_ps[9:5]);

	wire [15:0] r_s3;
	assign r_s3[0] = r2_ps[0] ^ round_ci;
	assign r_s3[1] = r2_ps[1] ^ (round_ci & r2_ps[0]);
	assign r_s3[2] = r2_ps[2] ^ (round_ci & (&r2_ps[1:0]));
	assign r_s3[3] = r2_ps[3] ^ (round_ci & (&r2_ps[2:0]));
	assign r_s3[4] = r2_ps[4] ^ (round_ci & (&r2_ps[3:0]));

	assign r_s3[5] = r2_ps[5] ^ c_lo5;
	assign r_s3[6] = r2_ps[6] ^ (c_lo5 & r2_ps[5]);
	assign r_s3[7] = r2_ps[7] ^ (c_lo5 & (&r2_ps[6:5]));
	assign r_s3[8] = r2_ps[8] ^ (c_lo5 & (&r2_ps[7:5]));
	assign r_s3[9] = r2_ps[9] ^ (c_lo5 & (&r2_ps[8:5]));

	assign r_s3[10] = r2_ps[10] ^ c_mid10;
	assign r_s3[11] = r2_ps[11] ^ (c_mid10 & r2_ps[10]);
	assign r_s3[12] = r2_ps[12] ^ (c_mid10 & (&r2_ps[11:10]));
	assign r_s3[13] = r2_ps[13] ^ (c_mid10 & (&r2_ps[12:10]));
	assign r_s3[14] = r2_ps[14] ^ (c_mid10 & (&r2_ps[13:10]));
	assign r_s3[15] = r2_ps[15] ^ (c_mid10 & (&r2_ps[14:10]));

	wire [15:0] u_s3 = r2_is_zero ? 16'd0 : r2_is_max ? ONES_CONST : r_s3;

	reg [15:0] r3_u;
	always @(posedge clk) begin
		if (rst_sync) begin
			r1_p       <= 36'd0;
			r1_sa_a    <= 6'd0;
			r1_sa_b    <= 6'd0;
			r1_sa1_a   <= 6'd0;
			r1_sa1_b   <= 6'd0;
			r1_is_zero <= 1'b0;
			r1_is_max  <= 1'b0;
			r2_ps      <= 16'd0;
			r2_g       <= 1'b0;
			r2_st_lo   <= 1'b0;
			r2_st_hi   <= 1'b0;
			r2_is_zero <= 1'b0;
			r2_is_max  <= 1'b0;
			r3_u       <= 16'd0;
		end else begin
			if (en_s1_buf[0])
				r1_p[17:0] <= p_s1[17:0];
			if (en_s1_buf[1])
				r1_p[35:18] <= p_s1[35:18];
			if (en_s1_buf[2]) begin
				r1_sa_a  <= sa_s1;
				r1_sa_b  <= sa_s1;
			end
			if (en_s1_buf[3]) begin
				r1_sa1_a   <= sa1_s1;
				r1_sa1_b   <= sa1_s1;
				r1_is_zero <= is_zero_s1;
				r1_is_max  <= is_max_s1;
			end
			if (en_s2_buf[0])
				r2_ps[7:0] <= ps_s2[7:0];
			if (en_s2_buf[1])
				r2_ps[15:8] <= ps_s2[15:8];
			if (en_s2_buf[2]) begin
				r2_g     <= g_s2;
				r2_st_lo <= st_lo_s2;
				r2_st_hi <= st_hi_s2;
			end
			if (en_s2_buf[3]) begin
				r2_is_zero <= r1_is_zero;
				r2_is_max  <= r1_is_max;
			end
			if (en_s3_buf[0])
				r3_u[7:0]  <= u_s3[7:0];
			if (en_s3_buf[1])
				r3_u[15:8] <= u_s3[15:8];
		end
	end

	assign u = r3_u;

	wire unused_ok = &{1'b0, p_bo_unused, sa_bo_unused, sa1_bo_unused, r1_sa_b[3:0], ps_s1[31:16]};
endmodule

`default_nettype wire
