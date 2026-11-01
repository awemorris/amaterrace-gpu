/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_fadd: optimized fp32 adder / subtractor for ROP pipeline (LAT = 4).
 * Dual-path normalisation & rounding architecture compliant with ASIC 5nm 1.5 GHz
 * timing, primitive budget (Pre-CARRY4 <= 1, Post-CARRY4 <= 1, <= 4 LUTs/stage),
 * and fanout limits.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_fadd #(
	parameter integer LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	input wire i_sub,
	output wire o_valid,
	output wire [31:0] o_r
);
	wire [8:0]  en_s1 = {9{en}};
	wire [8:0]  en_s2 = {9{en}};
	wire [11:0] en_s3 = {12{en}};
	wire [2:0]  en_s4 = {3{en}};

	/* =========================================================================
	 * Stage 1: Pure-LUT unpack, specials, exponent diff, and magnitude order
	 * (0 CARRY4s, <= 4 LUT levels, fanout <= 10).
	 * ========================================================================= */
	wire b_sign = i_b[31] ^ i_sub;
	wire [31:0] b_in = {b_sign, i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];

	(* keep = "true" *) wire [3:0] a_mnz, b_mnz;
	assign a_mnz[0] = (i_a[5:0]   != 6'd0);
	assign a_mnz[1] = (i_a[11:6]  != 6'd0);
	assign a_mnz[2] = (i_a[17:12] != 6'd0);
	assign a_mnz[3] = (i_a[22:18] != 5'd0);
	assign b_mnz[0] = (b_in[5:0]   != 6'd0);
	assign b_mnz[1] = (b_in[11:6]  != 6'd0);
	assign b_mnz[2] = (b_in[17:12] != 6'd0);
	assign b_mnz[3] = (b_in[22:18] != 5'd0);

	wire za    = (ea[7:4] == 4'd0) && (ea[3:0] == 4'd0);
	wire zb    = (eb[7:4] == 4'd0) && (eb[3:0] == 4'd0);
	wire ea_ff = (&ea[7:4]) && (&ea[3:0]);
	wire eb_ff = (&eb[7:4]) && (&eb[3:0]);
	wire nan_a = ea_ff && (|a_mnz);
	wire nan_b = eb_ff && (|b_mnz);
	wire inf_a = ea_ff && !(|a_mnz);
	wire inf_b = eb_ff && !(|b_mnz);

	/* Pure-LUT 8-bit exponent differences dab = ea - eb, dba = eb - ea (3 LUT levels) */
	(* keep = "true" *) wire [3:0] eq_e2, lt_e2, gt_e2;
	genvar gc;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_exp_cmp2
		wire [1:0] sa = ea[2 * gc +: 2];
		wire [1:0] sb = eb[2 * gc +: 2];
		assign eq_e2[gc] = (sa == sb);
		assign lt_e2[gc] = (~sa[1] & sb[1]) | ((sa[1] ~^ sb[1]) & (~sa[0] & sb[0]));
		assign gt_e2[gc] = (sa[1] & ~sb[1]) | ((sa[1] ~^ sb[1]) & (sa[0] & ~sb[0]));
	end
	endgenerate

	(* keep = "true" *) wire [3:0] bo_ab, bo_ba;
	assign bo_ab[0] = 1'b0;
	assign bo_ab[1] = lt_e2[0];
	assign bo_ab[2] = lt_e2[1] | (eq_e2[1] & lt_e2[0]);
	assign bo_ab[3] = lt_e2[2] | (eq_e2[2] & lt_e2[1]) | (eq_e2[2] & eq_e2[1] & lt_e2[0]);

	assign bo_ba[0] = 1'b0;
	assign bo_ba[1] = gt_e2[0];
	assign bo_ba[2] = gt_e2[1] | (eq_e2[1] & gt_e2[0]);
	assign bo_ba[3] = gt_e2[2] | (eq_e2[2] & gt_e2[1]) | (eq_e2[2] & eq_e2[1] & gt_e2[0]);

	(* keep = "true" *) wire [7:0] dab, dba;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_exp_diff2
		wire a0 = ea[2 * gc];
		wire a1 = ea[2 * gc + 1];
		wire b0 = eb[2 * gc];
		wire b1 = eb[2 * gc + 1];
		wire bab = bo_ab[gc];
		wire bba = bo_ba[gc];
		wire b0_ab = (~a0 & b0) | ((~a0 | b0) & bab);
		wire b0_ba = (~b0 & a0) | ((~b0 | a0) & bba);
		assign dab[2 * gc]     = a0 ^ b0 ^ bab;
		assign dab[2 * gc + 1] = a1 ^ b1 ^ b0_ab;
		assign dba[2 * gc]     = b0 ^ a0 ^ bba;
		assign dba[2 * gc + 1] = b1 ^ a1 ^ b0_ba;
	end
	endgenerate

	(* keep = "true" *) wire ea_lt_eb = lt_e2[3] | (eq_e2[3] & bo_ab[3]);

	/* Pure-LUT 31-bit magnitude comparison (Level 1..3 -> folded into Level 4 muxes) */
	(* keep = "true" *) wire [10:0] lt0, eq0;
	generate
	for (gc = 0; gc < 10; gc = gc + 1) begin : g_cmp_s0
		wire [2:0] sa = i_a[3 * gc +: 3];
		wire [2:0] sb = i_b[3 * gc +: 3];
		assign eq0[gc] = (sa == sb);
		assign lt0[gc] = (~sa[2] & sb[2]) |
			((sa[2] ~^ sb[2]) & ((~sa[1] & sb[1]) | ((sa[1] ~^ sb[1]) & (~sa[0] & sb[0]))));
	end
	endgenerate
	assign eq0[10] = (i_a[30] == i_b[30]);
	assign lt0[10] = (~i_a[30] & i_b[30]);

	(* keep = "true" *) wire [3:0] lt1, eq1;
	generate
	for (gc = 0; gc < 3; gc = gc + 1) begin : g_cmp_s1
		assign eq1[gc] = eq0[3 * gc + 2] & eq0[3 * gc + 1] & eq0[3 * gc];
		assign lt1[gc] = lt0[3 * gc + 2] | (eq0[3 * gc + 2] & lt0[3 * gc + 1]) |
			(eq0[3 * gc + 2] & eq0[3 * gc + 1] & lt0[3 * gc]);
	end
	endgenerate
	assign eq1[3] = eq0[10] & eq0[9];
	assign lt1[3] = lt0[10] | (eq0[10] & lt0[9]);

	/* Replicated Level-3 comparator terms (each <= 5 inputs in Level 3, fanout <= 9) */
	(* keep = "true", dont_touch = "true" *) wire [6:0] lt_hi_r, lt_lo_r;
	generate
	for (gc = 0; gc < 7; gc = gc + 1) begin : g_cmp_s2_rep
		assign lt_hi_r[gc] = lt1[3] | (eq1[3] & lt1[2]);
		assign lt_lo_r[gc] = eq1[3] & eq1[2] & (lt1[1] | (eq1[1] & lt1[0]));
	end
	endgenerate

	wire v1_w       = rst_n && i_valid;
	wire sp_nan1_w  = nan_a || nan_b || (inf_a && inf_b && (i_a[31] != b_sign));
	wire sp_inf1_w  = !sp_nan1_w && (inf_a || inf_b);
	wire sp_zero1_w = !sp_nan1_w && !sp_inf1_w && (za && zb);
	wire sp1_w      = sp_nan1_w || sp_inf1_w || sp_zero1_w;

	(* keep = "true", dont_touch = "true" *) wire sx_norm1_w = (lt_hi_r[6] | lt_lo_r[6]) ? b_sign : i_a[31];
	wire sp_sx1_w   = !sp_nan1_w && (inf_a ? i_a[31] : inf_b ? b_sign : (i_a[31] && b_sign));
	wire sub1_w     = (i_a[31] != b_sign);
	wire y_zero1_w  = za || zb;

	(* keep = "true", dont_touch = "true" *) wire [7:0] ex1_w;
	(* keep = "true", dont_touch = "true" *) wire [23:0] mx1_w, my1_w;
	assign mx1_w[23] = 1'b1;
	assign my1_w[23] = 1'b1;
	generate
	for (gc = 0; gc < 8; gc = gc + 1) begin : g_ex1_mux
		assign ex1_w[gc] = (lt_hi_r[6] | lt_lo_r[6]) ? eb[gc] : ea[gc];
	end
	for (gc = 0; gc < 23; gc = gc + 1) begin : g_m1_mux
		localparam integer R_MX = gc / 8;
		localparam integer R_MY = 3 + (gc / 8);
		assign mx1_w[gc] = (lt_hi_r[R_MX] | lt_lo_r[R_MX]) ? b_in[gc] : i_a[gc];
		assign my1_w[gc] = (lt_hi_r[R_MY] | lt_lo_r[R_MY]) ? i_a[gc] : b_in[gc];
	end
	endgenerate

	wire [4:0] d1_w = ea_lt_eb ? dba[4:0] : dab[4:0];
	wire d1_bit0_w  = ea[0] ^ eb[0];
	wire ealtb1_w   = ea_lt_eb;
	wire dab_hi1_w  = (dab[7:5] != 3'd0);
	wire dba_hi1_w  = (dba[7:5] != 3'd0);
	wire dab_cc1_w  = (dab[4:1] == 4'd0);
	wire dba_cc1_w  = (dba[4:1] == 4'd0);
	wire cc_en1_w   = (i_a[31] != b_sign) && !za && !zb;

	(* keep = "true" *) reg r_v1, r_sp1, r_sp_nan1, r_sp_inf1, r_sx_norm1, r_sp_sx1;
	(* keep = "true" *) reg r_ealtb1, r_dab_hi1, r_dba_hi1, r_dab_cc1, r_dba_cc1, r_cc_en1;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r_y_zero1_a, r_y_zero1_b;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r_sub1_a, r_sub1_b, r_sub1_c;
	reg [7:0] r_ex1;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [4:0] r_d1_a, r_d1_b, r_d1_c, r_d1_d;
	(* equivalent_register_removal = "no", max_fanout = 14 *) reg r_d1_e0, r_d1_f0;
	reg [23:0] r_mx1, r_my1;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_v1 <= 1'b0;
		end else if (en_s1[0]) begin
			r_v1 <= v1_w;
		end
	end

	always @(posedge clk) begin
		if (en_s1[0]) begin
			r_sp1       <= sp1_w;
			r_sp_nan1   <= sp_nan1_w;
			r_sp_inf1   <= sp_inf1_w;
			r_sx_norm1  <= sx_norm1_w;
			r_sp_sx1    <= sp_sx1_w;
			r_sub1_a    <= sub1_w;
			r_sub1_b    <= sub1_w;
			r_sub1_c    <= sub1_w;
		end
		if (en_s1[1]) begin
			r_y_zero1_a <= y_zero1_w;
			r_y_zero1_b <= y_zero1_w;
			r_ealtb1    <= ealtb1_w;
			r_dab_hi1   <= dab_hi1_w;
			r_dba_hi1   <= dba_hi1_w;
			r_dab_cc1   <= dab_cc1_w;
			r_dba_cc1   <= dba_cc1_w;
			r_cc_en1    <= cc_en1_w;
			r_d1_e0     <= d1_bit0_w;
			r_d1_f0     <= d1_bit0_w;
		end
		if (en_s1[2]) begin
			r_ex1  <= ex1_w;
			r_d1_a <= d1_w;
		end
		if (en_s1[3]) begin
			r_d1_b <= d1_w;
			r_d1_c <= d1_w;
		end
		if (en_s1[4]) begin
			r_d1_d       <= d1_w;
			r_mx1[6:0]   <= mx1_w[6:0];
		end
		if (en_s1[5]) r_mx1[18:7]  <= mx1_w[18:7];
		if (en_s1[6]) begin
			r_mx1[23:19] <= mx1_w[23:19];
			r_my1[6:0]   <= my1_w[6:0];
		end
		if (en_s1[7]) r_my1[18:7]  <= my1_w[18:7];
		if (en_s1[8]) r_my1[23:19] <= my1_w[23:19];
	end

	wire v1          = r_v1;
	wire sp1         = r_sp1;
	wire sp_nan1     = r_sp_nan1;
	wire sp_inf1     = r_sp_inf1;
	wire sx1         = r_sp1 ? r_sp_sx1 : r_sx_norm1;
	wire sub1_a      = r_sub1_a;
	wire sub1_b      = r_sub1_b;
	wire sub1_c      = r_sub1_c;
	wire y_zero1_a   = r_y_zero1_a;
	wire y_zero1_b   = r_y_zero1_b;
	wire ealtb1      = r_ealtb1;
	wire dab_hi1     = r_dab_hi1;
	wire dba_hi1     = r_dba_hi1;
	wire close_cand1 = r_cc_en1 && (r_ealtb1 ? (!r_dba_hi1 && r_dba_cc1) : (!r_dab_hi1 && r_dab_cc1));
	wire [7:0] ex1   = r_ex1;
	wire [23:0] mx1  = r_mx1;
	wire [23:0] my1  = r_my1;
	wire [4:0] d1_a  = r_d1_a;
	wire [4:0] d1_b  = r_d1_b;
	wire [4:0] d1_c  = r_d1_c;
	wire [4:0] d1_d  = r_d1_d;
	wire d1_e0       = r_d1_e0;
	wire d1_f0       = r_d1_f0;

	/* =========================================================================
	 * Stage 2:
	 * - Far path: align smaller operand, 3-level sticky bit, and XOR with sub1.
	 * - Close path: dual 25-bit exact subtractors directly from FFs (Pre-LUTs = 1,
	 *   Post-LUTs = 1).
	 * - Pure-LUT ex1 + 1 and ex1 - 1 (0 CARRY4s).
	 * ========================================================================= */
	wire [26:0] shi = {my1, 3'b000};
	wire [26:0] shr_0, shr_1, shr_2;
	am_shift #(.W(27), .SW(5)) u_shr_0 (.a(shi), .amt(d1_a), .left(1'b0), .arith(1'b0), .y(shr_0));
	am_shift #(.W(27), .SW(5)) u_shr_1 (.a(shi), .amt(d1_d), .left(1'b0), .arith(1'b0), .y(shr_1));
	am_shift #(.W(27), .SW(5)) u_shr_2 (.a(shi), .amt(d1_b), .left(1'b0), .arith(1'b0), .y(shr_2));

	(* keep = "true", dont_touch = "true" *) wire [5:0] st_full, st_part;
	genvar gs;
	generate
	for (gs = 0; gs < 6; gs = gs + 1) begin : g_stk_chunk
		wire [3:0] ch = my1[4 * gs +: 4];
		assign st_full[gs] = |ch;
		assign st_part[gs] = (d1_c[1:0] == 2'd3) ? ch[0] :
		                     (d1_c[1:0] == 2'd0) ? (|ch[1:0]) :
		                     (d1_c[1:0] == 2'd1) ? (|ch[2:0]) : (|ch[3:0]);
	end
	endgenerate

	/* 3-LUT-level sticky reduction (Level 1: st_full/st_part/st_mode -> Level 2: stk_pair -> Level 3: py2_w[0]) */
	(* keep = "true", dont_touch = "true" *) wire [1:0] st_mode0 = (d1_c < 5'd3)  ? 2'd0 : (d1_c < 5'd7)  ? 2'd1 : (d1_c < 5'd11) ? 2'd2 : 2'd3;
	(* keep = "true", dont_touch = "true" *) wire [1:0] st_mode1 = (d1_c < 5'd11) ? 2'd0 : (d1_c < 5'd15) ? 2'd1 : (d1_c < 5'd19) ? 2'd2 : 2'd3;
	(* keep = "true", dont_touch = "true" *) wire [1:0] st_mode2 = (d1_c < 5'd19) ? 2'd0 : (d1_c < 5'd23) ? 2'd1 : (d1_c < 5'd27) ? 2'd2 : 2'd3;

	(* keep = "true", dont_touch = "true" *) wire [2:0] stk_pair;
	assign stk_pair[0] = (st_mode0 == 2'd0) ? 1'b0 :
	                     (st_mode0 == 2'd1) ? st_part[0] :
	                     (st_mode0 == 2'd2) ? (st_full[0] | st_part[1]) : (st_full[0] | st_full[1]);
	assign stk_pair[1] = (st_mode1 == 2'd0) ? 1'b0 :
	                     (st_mode1 == 2'd1) ? st_part[2] :
	                     (st_mode1 == 2'd2) ? (st_full[2] | st_part[3]) : (st_full[2] | st_full[3]);
	assign stk_pair[2] = (st_mode2 == 2'd0) ? 1'b0 :
	                     (st_mode2 == 2'd1) ? st_part[4] :
	                     (st_mode2 == 2'd2) ? (st_full[4] | st_part[5]) : (st_full[4] | st_full[5]);

	(* keep = "true", dont_touch = "true" *) wire clr_sel_0 = ealtb1 ? dba_hi1 : dab_hi1;
	(* keep = "true", dont_touch = "true" *) wire [3:0] y_clr_rep;
	assign y_clr_rep[0] = y_zero1_a || (ealtb1 ? dba_hi1 : dab_hi1);
	assign y_clr_rep[1] = y_zero1_a || (ealtb1 ? dba_hi1 : dab_hi1);
	assign y_clr_rep[2] = y_zero1_b || (ealtb1 ? dba_hi1 : dab_hi1);
	assign y_clr_rep[3] = y_zero1_b || (ealtb1 ? dba_hi1 : dab_hi1);

	wire py2_bit0 = !y_zero1_a && (clr_sel_0 || stk_pair[0] || stk_pair[1] || stk_pair[2]);
	wire [13:0] py2_raw_lo = {
		y_clr_rep[1] ? 6'd0 : shr_1[13:8],
		y_clr_rep[0] ? 7'd0 : shr_0[7:1],
		py2_bit0
	};
	wire [26:14] py2_raw_hi = {
		y_clr_rep[3] ? 7'd0 : shr_2[26:20],
		y_clr_rep[2] ? 6'd0 : {shr_2[19:15], shr_1[14]}
	};
	wire [26:0] py2_raw = {py2_raw_hi, py2_raw_lo};

	/* Close path subtractors driven directly from r_mx1 / r_my1 (Pre-LUTs = 1, Post-LUTs = 1) */
	wire [24:0] close_diff_d0, close_diff_d1;
	wire close_bo0_unused, close_bo1_unused;
	am_sub #(.W(25)) u_close_sub_d0 (
		.a({mx1, 1'b0}), .b({my1, 1'b0}), .bi(1'b0), .d(close_diff_d0), .bo(close_bo0_unused)
	);
	am_sub #(.W(25)) u_close_sub_d1 (
		.a({mx1, 1'b0}), .b({1'b0, my1}), .bi(1'b0), .d(close_diff_d1), .bo(close_bo1_unused)
	);
	wire [24:0] close_diff2_w = {
		d1_f0 ? close_diff_d1[24:13] : close_diff_d0[24:13],
		d1_e0 ? close_diff_d1[12:0]  : close_diff_d0[12:0]
	};

	/* Pure-LUT 8-bit ex1 + 1 and ex1 - 1 (0 CARRY4s, 2 LUT levels) */
	(* keep = "true" *) wire ex_p1_c4  = &ex1[3:0];
	(* keep = "true" *) wire ex_m1_b4  = (ex1[3:0] == 4'd0);
	wire [7:0] ex2_p1_w, ex2_sub1_w;
	assign ex2_p1_w[0] = ~ex1[0];
	assign ex2_p1_w[1] = ex1[1] ^ ex1[0];
	assign ex2_p1_w[2] = ex1[2] ^ (&ex1[1:0]);
	assign ex2_p1_w[3] = ex1[3] ^ (&ex1[2:0]);
	assign ex2_p1_w[4] = ex1[4] ^ ex_p1_c4;
	assign ex2_p1_w[5] = ex1[5] ^ (ex_p1_c4 & ex1[4]);
	assign ex2_p1_w[6] = ex1[6] ^ (ex_p1_c4 & (&ex1[5:4]));
	assign ex2_p1_w[7] = ex1[7] ^ (ex_p1_c4 & (&ex1[6:4]));

	assign ex2_sub1_w[0] = ~ex1[0];
	assign ex2_sub1_w[1] = ex1[1] ^ ~ex1[0];
	assign ex2_sub1_w[2] = ex1[2] ^ (ex1[1:0] == 2'd0);
	assign ex2_sub1_w[3] = ex1[3] ^ (ex1[2:0] == 3'd0);
	assign ex2_sub1_w[4] = ex1[4] ^ ex_m1_b4;
	assign ex2_sub1_w[5] = ex1[5] ^ (ex_m1_b4 & ~ex1[4]);
	assign ex2_sub1_w[6] = ex1[6] ^ (ex_m1_b4 & (ex1[5:4] == 2'd0));
	assign ex2_sub1_w[7] = ex1[7] ^ (ex_m1_b4 & (ex1[6:4] == 3'd0));

	wire v2_w          = rst_n && v1;
	wire sp2_w         = sp1;
	wire sp_nan2_w     = sp_nan1;
	wire sp_inf2_w     = sp_inf1;
	wire sx2_w         = sx1;
	wire close_cand2_w = close_cand1;
	wire [7:0] ex2_w   = ex1;
	wire [26:0] px2_w  = {mx1, 3'b000};
	(* keep = "true", dont_touch = "true" *) wire [26:0] py2_w = {
		py2_raw[26:18] ^ {9{sub1_c}},
		py2_raw[17:9]  ^ {9{sub1_b}},
		py2_raw[8:0]   ^ {9{sub1_a}}
	};

	reg r_v2, r_sp2, r_sp_nan2, r_sp_inf2, r_sx2, r_close_cand2;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r_sub2_a, r_sub2_b, r_sub2_c, r_sub2_ci;
	reg [7:0] r_ex2, r_ex2_p1, r_ex2_sub1;
	reg [26:0] r_px2, r_py2;
	reg [24:0] r_close_diff2;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_v2 <= 1'b0;
		end else if (en_s2[0]) begin
			r_v2 <= v2_w;
		end
	end

	always @(posedge clk) begin
		if (en_s2[0]) begin
			r_sp2         <= sp2_w;
			r_sp_nan2     <= sp_nan2_w;
			r_sp_inf2     <= sp_inf2_w;
			r_sx2         <= sx2_w;
			r_sub2_a      <= sub1_a;
			r_sub2_b      <= sub1_a;
			r_sub2_c      <= sub1_a;
			r_sub2_ci     <= sub1_a;
			r_close_cand2 <= close_cand2_w;
		end
		if (en_s2[1]) begin
			r_ex2      <= ex2_w;
			r_ex2_p1   <= ex2_p1_w;
		end
		if (en_s2[2]) begin
			r_ex2_sub1  <= ex2_sub1_w;
			r_px2[6:0]  <= px2_w[6:0];
		end
		if (en_s2[3]) r_px2[18:7]  <= px2_w[18:7];
		if (en_s2[4]) begin
			r_px2[26:19] <= px2_w[26:19];
			r_py2[4:0]   <= py2_w[4:0];
		end
		if (en_s2[5]) r_py2[16:5]  <= py2_w[16:5];
		if (en_s2[6]) r_py2[26:17] <= py2_w[26:17];
		if (en_s2[7]) r_close_diff2[12:0]  <= close_diff2_w[12:0];
		if (en_s2[8]) r_close_diff2[24:13] <= close_diff2_w[24:13];
	end

	wire v2          = r_v2;
	wire sp2         = r_sp2;
	wire sp_nan2     = r_sp_nan2;
	wire sp_inf2     = r_sp_inf2;
	wire sx2         = r_sx2;
	wire close_cand2 = r_close_cand2;
	wire [7:0] ex2      = r_ex2;
	wire [7:0] ex2_p1   = r_ex2_p1;
	wire [7:0] ex2_sub1 = r_ex2_sub1;
	wire [26:0] px2         = r_px2;
	wire [26:0] py2         = r_py2;
	wire [24:0] close_diff2 = r_close_diff2;

	/* =========================================================================
	 * Stage 3:
	 * - Far path: 28-bit addition u_sum (Pre-LUTs = 1, Post-LUTs = 1 via direct
	 *   <= 5-input functions of sum[5:0] and 6-bit slice prefix-ANDs).
	 * - Close path: 2-level nibble LZC and zero-detect from registered close_diff2
	 *   (0 CARRY4s, <= 3 LUT levels).
	 * ========================================================================= */
	wire [27:0] sum;
	wire sum_co_unused;
	am_add #(.W(28)) u_sum (
		.a({1'b0, px2}),
		.b({r_sub2_a, py2}),
		.ci(r_sub2_ci),
		.s(sum),
		.co(sum_co_unused)
	);

	/* Direct <= 5-input LUT expressions of sum[5:0] (Post-LUTs = 1 guaranteed!) */
	(* keep = "true" *) wire [1:0] fmu_c_w;
	assign fmu_c_w[0] = sum[4] ^ (sum[3] & (sum[2] | sum[1] | sum[0] | sum[4]));
	assign fmu_c_w[1] = sum[5] ^ (sum[4] & sum[3]);
	(* keep = "true" *) wire cin6_c_w = sum[5] & sum[4] & sum[3];

	(* keep = "true" *) wire [2:0] fmu_n_w;
	assign fmu_n_w[0] = sum[3] ^ (sum[2] & (sum[1] | sum[0] | sum[3]));
	assign fmu_n_w[1] = sum[4] ^ (sum[3] & sum[2]);
	assign fmu_n_w[2] = sum[5] ^ (sum[4] & sum[3] & sum[2]);
	(* keep = "true" *) wire cin6_n_w = sum[5] & sum[4] & sum[3] & sum[2];

	(* keep = "true" *) wire [3:0] fmu_u_w;
	assign fmu_u_w[0] = sum[2] ^ (sum[1] & (sum[0] | sum[2]));
	assign fmu_u_w[1] = sum[3] ^ (sum[2] & sum[1]);
	assign fmu_u_w[2] = sum[4] ^ (sum[3] & sum[2] & sum[1]);
	assign fmu_u_w[3] = sum[5] ^ (sum[4] & sum[3] & sum[2] & sum[1]);
	(* keep = "true" *) wire cin6_u_w = sum[5] & sum[4] & sum[3] & sum[2] & sum[1];

	(* keep = "true" *) wire [11:6] p6_w;
	assign p6_w[6]  = sum[6];
	assign p6_w[7]  = &sum[7:6];
	assign p6_w[8]  = &sum[8:6];
	assign p6_w[9]  = &sum[9:6];
	assign p6_w[10] = &sum[10:6];
	assign p6_w[11] = &sum[11:6];

	(* keep = "true" *) wire [17:12] p12_w;
	assign p12_w[12] = sum[12];
	assign p12_w[13] = &sum[13:12];
	assign p12_w[14] = &sum[14:12];
	assign p12_w[15] = &sum[15:12];
	assign p12_w[16] = &sum[16:12];
	assign p12_w[17] = &sum[17:12];

	(* keep = "true" *) wire [23:18] p18_w;
	assign p18_w[18] = sum[18];
	assign p18_w[19] = &sum[19:18];
	assign p18_w[20] = &sum[20:18];
	assign p18_w[21] = &sum[21:18];
	assign p18_w[22] = &sum[22:18];
	assign p18_w[23] = &sum[23:18];

	(* keep = "true" *) wire [26:24] p24_w;
	assign p24_w[24] = sum[24];
	assign p24_w[25] = &sum[25:24];
	assign p24_w[26] = &sum[26:24];

	/* 3-level nibble LZC on registered close_diff2[24:0] (3 LUT levels max, 0 CARRY4s) */
	(* keep = "true", dont_touch = "true" *) wire [5:0] nib_nz;
	generate
	for (gs = 0; gs < 6; gs = gs + 1) begin : g_lzc_nib
		wire [3:0] nb = close_diff2[4 * gs +: 4];
		assign nib_nz[gs] = |nb;
	end
	endgenerate

	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n5 = close_diff2[23] ? 5'd1  : close_diff2[22] ? 5'd2  : close_diff2[21] ? 5'd3  : 5'd4;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n4 = close_diff2[19] ? 5'd5  : close_diff2[18] ? 5'd6  : close_diff2[17] ? 5'd7  : 5'd8;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n3 = close_diff2[15] ? 5'd9  : close_diff2[14] ? 5'd10 : close_diff2[13] ? 5'd11 : 5'd12;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n2 = close_diff2[11] ? 5'd13 : close_diff2[10] ? 5'd14 : close_diff2[9]  ? 5'd15 : 5'd16;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n1 = close_diff2[7]  ? 5'd17 : close_diff2[6]  ? 5'd18 : close_diff2[5]  ? 5'd19 : 5'd20;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_n0 = close_diff2[3]  ? 5'd21 : close_diff2[2]  ? 5'd22 : close_diff2[1]  ? 5'd23 : 5'd24;

	(* keep = "true", dont_touch = "true" *) wire hi_nz  = close_diff2[24] | nib_nz[5] | nib_nz[4];
	(* keep = "true", dont_touch = "true" *) wire mid_nz = nib_nz[3] | nib_nz[2];
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_hi  = close_diff2[24] ? 5'd0 : (nib_nz[5] ? lz_n5 : lz_n4);
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_mid = nib_nz[3] ? lz_n3 : lz_n2;
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz_lo  = nib_nz[1] ? lz_n1 : (nib_nz[0] ? lz_n0 : 5'd27);
	(* keep = "true", dont_touch = "true" *) wire [4:0] lz = hi_nz ? lz_hi : (mid_nz ? lz_mid : lz_lo);

	wire is_close3_w = close_cand2 && (close_diff2[24:23] == 2'b00);
	wire sz3_w       = close_cand2 && !hi_nz && !mid_nz && !(nib_nz[1] | nib_nz[0]);
	wire ex2_le31_w  = (ex2[7:5] == 3'd0);
	wire ex2_0_w     = (ex2[7:4] == 4'd0) && (ex2[3:0] == 4'd0);
	wire ex2_1_w     = (ex2[7:4] == 4'd0) && (ex2[3:0] == 4'd1);
	wire ex2_254_w   = (&ex2[7:4]) && (ex2[3:0] == 4'hE);

	wire v3_w              = rst_n && v2;
	wire sp3_w             = sp2;
	wire sp_nan3_w         = sp_nan2;
	wire sp_inf3_w         = sp_inf2;
	wire sx3_w             = sx2;
	wire [7:0] ex2_3_w     = ex2;
	wire [7:0] ex2_p1_3_w  = ex2_p1;
	wire [7:0] ex2_sub1_3_w = ex2_sub1;
	wire [22:0] close_diff3_w = close_diff2[22:0];

	reg r_v3, r_sp3, r_sp_nan3, r_sp_inf3, r_sx3, r_sz3;
	(* equivalent_register_removal = "no", max_fanout = 14 *) reg r_is_close_a, r_is_close_b;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r_far_c_a, r_far_c_b, r_far_c_c, r_far_c_d, r_far_c_e;
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg r_far_norm_a, r_far_norm_b, r_far_norm_c, r_far_norm_d, r_far_norm_e;
	reg [26:6] r_sum3;
	reg [1:0] r_fmu_c3;
	reg [2:0] r_fmu_n3;
	reg [3:0] r_fmu_u3;
	reg r_cin6_c3, r_cin6_n3, r_cin6_u3;
	reg [11:6] r_p6_3;
	reg [17:12] r_p12_3;
	reg [23:18] r_p18_3;
	reg [26:24] r_p24_3;
	reg [22:0] r_close_diff3;
	(* equivalent_register_removal = "no", max_fanout = 14 *) reg [4:0] r_lz3_a, r_lz3_b;
	reg [7:0] r_ex2_3, r_ex2_p1_3, r_ex2_sub1_3;
	reg r_ex2_le31_3, r_ex2_0_3, r_ex2_1_3, r_ex2_254_3;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_v3 <= 1'b0;
		end else if (en_s3[0]) begin
			r_v3 <= v3_w;
		end
	end

	always @(posedge clk) begin
		if (en_s3[0]) begin
			r_sp3        <= sp3_w;
			r_sp_nan3    <= sp_nan3_w;
			r_sp_inf3    <= sp_inf3_w;
			r_sx3        <= sx3_w;
			r_sz3        <= sz3_w;
			r_is_close_a <= is_close3_w;
			r_is_close_b <= is_close3_w;
			r_ex2_le31_3 <= ex2_le31_w;
			r_ex2_0_3    <= ex2_0_w;
			r_ex2_1_3    <= ex2_1_w;
			r_ex2_254_3  <= ex2_254_w;
		end
		if (en_s3[1]) begin
			r_far_c_a    <= sum[27];
			r_far_c_b    <= sum[27];
			r_far_c_c    <= sum[27];
			r_far_c_d    <= sum[27];
			r_far_c_e    <= sum[27];
			r_far_norm_a <= sum[26];
			r_far_norm_b <= sum[26];
			r_far_norm_c <= sum[26];
			r_far_norm_d <= sum[26];
			r_far_norm_e <= sum[26];
		end
		if (en_s3[2]) begin
			r_fmu_c3  <= fmu_c_w;
			r_fmu_n3  <= fmu_n_w;
			r_fmu_u3  <= fmu_u_w;
			r_cin6_c3 <= cin6_c_w;
			r_cin6_n3 <= cin6_n_w;
			r_cin6_u3 <= cin6_u_w;
		end
		if (en_s3[3]) begin
			r_p6_3  <= p6_w;
			r_p12_3 <= p12_w;
		end
		if (en_s3[4]) begin
			r_p18_3 <= p18_w;
			r_p24_3 <= p24_w;
		end
		if (en_s3[5]) r_sum3[16:6]  <= sum[16:6];
		if (en_s3[6]) begin
			r_sum3[26:17] <= sum[26:17];
			r_lz3_a       <= lz;
		end
		if (en_s3[7]) begin
			r_lz3_b            <= lz;
			r_close_diff3[6:0] <= close_diff3_w[6:0];
		end
		if (en_s3[8])
			r_close_diff3[22:7] <= close_diff3_w[22:7];
		if (en_s3[9]) begin
			r_ex2_3             <= ex2_3_w;
			r_ex2_p1_3          <= ex2_p1_3_w;
		end
		if (en_s3[10])
			r_ex2_sub1_3        <= ex2_sub1_3_w;
	end

	wire v3          = r_v3;
	wire sp3         = r_sp3;
	wire sp_nan3     = r_sp_nan3;
	wire sp_inf3     = r_sp_inf3;
	wire sx3         = r_sx3;
	wire sz3         = r_sz3;
	wire is_close_a  = r_is_close_a;
	wire is_close_b  = r_is_close_b;
	wire far_c_a     = r_far_c_a;
	wire far_c_b     = r_far_c_b;
	wire far_c_c     = r_far_c_c;
	wire far_c_d     = r_far_c_d;
	wire far_c_e     = r_far_c_e;
	wire far_norm_a  = r_far_norm_a;
	wire far_norm_b  = r_far_norm_b;
	wire far_norm_c  = r_far_norm_c;
	wire far_norm_d  = r_far_norm_d;
	wire far_norm_e  = r_far_norm_e;
	wire [26:6] sum3        = r_sum3;
	wire [1:0] fmu_c3       = r_fmu_c3;
	wire [2:0] fmu_n3       = r_fmu_n3;
	wire [3:0] fmu_u3       = r_fmu_u3;
	wire cin6_c3            = r_cin6_c3;
	wire cin6_n3            = r_cin6_n3;
	wire cin6_u3            = r_cin6_u3;
	wire [11:6] p6_3        = r_p6_3;
	wire [17:12] p12_3      = r_p12_3;
	wire [23:18] p18_3      = r_p18_3;
	wire [26:24] p24_3      = r_p24_3;
	wire [22:0] close_diff3 = r_close_diff3;
	wire [4:0] lz3_a        = r_lz3_a;
	wire [4:0] lz3_b        = r_lz3_b;
	wire [7:0] ex2_3        = r_ex2_3;
	wire [7:0] ex2_p1_3     = r_ex2_p1_3;
	wire [7:0] ex2_sub1_3   = r_ex2_sub1_3;
	wire ex2_le31_3         = r_ex2_le31_3;
	wire ex2_0_3            = r_ex2_0_3;
	wire ex2_1_3            = r_ex2_1_3;
	wire ex2_254_3          = r_ex2_254_3;

	/* =========================================================================
	 * Stage 4:
	 * - Close path: 2-stage left shift (2 LUT levels) and pure-LUT 8-bit exponent
	 *   subtract (2 LUT levels, 0 CARRY4s).
	 * - Far path: 2-level factored-carry mantissa selection & 3-level output pack.
	 * ========================================================================= */
	wire [27:0] c_in_pad = {2'b00, close_diff3, 3'b000};
	(* keep = "true", dont_touch = "true" *) wire [24:0] nl_s1;
	genvar gk;
	generate
	for (gk = 0; gk < 13; gk = gk + 1) begin : g_nls1_lo
		assign nl_s1[gk] = (lz3_a[1:0] == 2'd0) ? c_in_pad[gk + 3] :
		                   (lz3_a[1:0] == 2'd1) ? c_in_pad[gk + 2] :
		                   (lz3_a[1:0] == 2'd2) ? c_in_pad[gk + 1] : c_in_pad[gk];
	end
	for (gk = 13; gk < 25; gk = gk + 1) begin : g_nls1_hi
		assign nl_s1[gk] = (lz3_b[1:0] == 2'd0) ? c_in_pad[gk + 3] :
		                   (lz3_b[1:0] == 2'd1) ? c_in_pad[gk + 2] :
		                   (lz3_b[1:0] == 2'd2) ? c_in_pad[gk + 1] : c_in_pad[gk];
	end
	endgenerate

	wire [48:0] nl_s1_pad = {nl_s1, 24'd0};
	(* keep = "true", dont_touch = "true" *) wire [24:0] nl_hi0;
	(* keep = "true", dont_touch = "true" *) wire [24:13] nl_hi1;
	generate
	for (gk = 0; gk < 13; gk = gk + 1) begin : g_nl_lo
		assign nl_hi0[gk] = (lz3_a[3:2] == 2'd0) ? nl_s1_pad[gk + 24] :
		                    (lz3_a[3:2] == 2'd1) ? nl_s1_pad[gk + 20] :
		                    (lz3_a[3:2] == 2'd2) ? nl_s1_pad[gk + 16] : nl_s1_pad[gk + 12];
	end
	for (gk = 13; gk < 25; gk = gk + 1) begin : g_nl_hi
		assign nl_hi0[gk] = (lz3_b[3:2] == 2'd0) ? nl_s1_pad[gk + 24] :
		                    (lz3_b[3:2] == 2'd1) ? nl_s1_pad[gk + 20] :
		                    (lz3_b[3:2] == 2'd2) ? nl_s1_pad[gk + 16] : nl_s1_pad[gk + 12];
		assign nl_hi1[gk] = (lz3_b[3:2] == 2'd0) ? nl_s1_pad[gk + 8]  :
		                    (lz3_b[3:2] == 2'd1) ? nl_s1_pad[gk + 4]  :
		                    (lz3_b[3:2] == 2'd2) ? nl_s1_pad[gk]      : 1'b0;
	end
	endgenerate
	(* keep = "true", dont_touch = "true" *) wire close_m22 = lz3_b[4] ? nl_hi1[23] : nl_hi0[23];

	/* Pure-LUT 8-bit subtractor close_e = ex2_3 - {3'd0, lz3_b} (2 LUT levels, 0 CARRY4s) */
	(* keep = "true", dont_touch = "true" *) wire ce_b1 = ~ex2_3[0] & lz3_b[0];
	(* keep = "true", dont_touch = "true" *) wire ce_b2 = (~ex2_3[1] & lz3_b[1]) | ((ex2_3[1] ~^ lz3_b[1]) & ce_b1);
	(* keep = "true", dont_touch = "true" *) wire ce_b3 = (ex2_3[2:0] < lz3_b[2:0]);
	(* keep = "true", dont_touch = "true" *) wire ce_b4 = (~ex2_3[3] & lz3_b[3]) | ((ex2_3[3] ~^ lz3_b[3]) & ce_b3);
	(* keep = "true", dont_touch = "true" *) wire ce_b5 = (~ex2_3[4] & lz3_b[4]) |
	                                                      ((ex2_3[4] ~^ lz3_b[4]) & (~ex2_3[3] & lz3_b[3])) |
	                                                      ((ex2_3[4] ~^ lz3_b[4]) & (ex2_3[3] ~^ lz3_b[3]) & ce_b3);
	(* keep = "true", dont_touch = "true" *) wire [7:0] close_e;
	assign close_e[0] = ex2_3[0] ^ lz3_b[0];
	assign close_e[1] = ex2_3[1] ^ lz3_b[1] ^ ce_b1;
	assign close_e[2] = ex2_3[2] ^ lz3_b[2] ^ ce_b2;
	assign close_e[3] = ex2_3[3] ^ lz3_b[3] ^ ce_b3;
	assign close_e[4] = ex2_3[4] ^ lz3_b[4] ^ ce_b4;
	assign close_e[5] = ex2_3[5] ^ ce_b5;
	assign close_e[6] = ex2_3[6] ^ (ce_b5 & ~ex2_3[5]);
	assign close_e[7] = ex2_3[7] ^ (ce_b5 & (ex2_3[6:5] == 2'd0));

	(* keep = "true", dont_touch = "true" *) wire cudf_lo = (ex2_3[2:0] <= lz3_a[2:0]);
	(* keep = "true", dont_touch = "true" *) wire cudf_eq = is_close_a && ex2_le31_3 && (ex2_3[4:3] == lz3_a[4:3]);
	(* keep = "true", dont_touch = "true" *) wire cudf_lt = is_close_a && ex2_le31_3 && (ex2_3[4:3] < lz3_a[4:3]);

	/* Far path Stage 4 */
	(* keep = "true", dont_touch = "true" *) wire cin_6  = far_c_a ? cin6_c3 : (far_norm_a ? cin6_n3 : cin6_u3);
	(* keep = "true", dont_touch = "true" *) wire cin_12 = (far_c_c ? cin6_c3 : (far_norm_c ? cin6_n3 : cin6_u3)) & p6_3[11];
	(* keep = "true", dont_touch = "true" *) wire p24_sel = far_c_c ? 1'b0 : (far_norm_c ? p24_3[26] : p24_3[25]);
	(* keep = "true", dont_touch = "true" *) wire far_m0_cout = cin_12 & p12_3[17] & p18_3[23] & p24_sel;

	(* keep = "true", dont_touch = "true" *) wire [22:4] mu_bit;
	(* keep = "true", dont_touch = "true" *) wire [22:4] p_mux;
	wire [10:5] w_p6  = {p6_3[10:6], 1'b1};
	wire [16:11] w_p12 = {p12_3[16:12], 1'b1};
	wire [22:17] w_p18 = {p18_3[22:18], 1'b1};

	genvar gi;
	generate
	for (gi = 4; gi < 11; gi = gi + 1) begin : g_mu_lo
		assign mu_bit[gi] = far_c_a ? sum3[gi + 4] : (far_norm_a ? sum3[gi + 3] : sum3[gi + 2]);
	end
	for (gi = 11; gi < 18; gi = gi + 1) begin : g_mu_mid
		assign mu_bit[gi] = far_c_b ? sum3[gi + 4] : (far_norm_b ? sum3[gi + 3] : sum3[gi + 2]);
	end
	for (gi = 18; gi < 23; gi = gi + 1) begin : g_mu_hi
		assign mu_bit[gi] = far_c_c ? sum3[gi + 4] : (far_norm_c ? sum3[gi + 3] : sum3[gi + 2]);
	end
	for (gi = 4; gi <= 7; gi = gi + 1) begin : g_pmux_4_7
		assign p_mux[gi] = far_c_a ? w_p6[gi + 3] : (far_norm_a ? w_p6[gi + 2] : w_p6[gi + 1]);
	end
	for (gi = 10; gi <= 13; gi = gi + 1) begin : g_pmux_10_13
		assign p_mux[gi] = far_c_b ? w_p12[gi + 3] : (far_norm_b ? w_p12[gi + 2] : w_p12[gi + 1]);
	end
	for (gi = 16; gi <= 19; gi = gi + 1) begin : g_pmux_16_19
		wire fc = (gi < 18) ? far_c_b : far_c_c;
		wire fn = (gi < 18) ? far_norm_b : far_norm_c;
		assign p_mux[gi] = fc ? w_p18[gi + 3] : (fn ? w_p18[gi + 2] : w_p18[gi + 1]);
	end
	endgenerate

	assign p_mux[8]  = far_c_a ? p6_3[11] : (far_norm_a ? p6_3[10] : p6_3[9]);
	assign p_mux[9]  = far_c_a ? (p6_3[11] & p12_3[12]) : (far_norm_a ? p6_3[11] : p6_3[10]);
	assign p_mux[14] = far_c_b ? p12_3[17] : (far_norm_b ? p12_3[16] : p12_3[15]);
	assign p_mux[15] = far_c_b ? (p12_3[17] & p18_3[18]) : (far_norm_b ? p12_3[17] : p12_3[16]);
	assign p_mux[20] = far_c_c ? p18_3[23] : (far_norm_c ? p18_3[22] : p18_3[21]);
	assign p_mux[21] = far_c_c ? (p18_3[23] & p24_3[24]) : (far_norm_c ? p18_3[23] : p18_3[22]);
	assign p_mux[22] = far_c_c ? p24_3[25] : (far_norm_c ? p24_3[24] : 1'b1);

	(* keep = "true", dont_touch = "true" *) wire [22:0] far_m;
	assign far_m[0] = far_c_a ? fmu_c3[0] : (far_norm_a ? fmu_n3[0] : fmu_u3[0]);
	assign far_m[1] = far_c_a ? fmu_c3[1] : (far_norm_a ? fmu_n3[1] : fmu_u3[1]);
	assign far_m[2] = far_c_a ? (sum3[6] ^ cin6_c3) : (far_norm_a ? fmu_n3[2] : fmu_u3[2]);
	(* keep = "true", dont_touch = "true" *) wire mu3_c = sum3[7] ^ (cin6_c3 & p6_3[6]);
	assign far_m[3] = far_c_a ? mu3_c : (far_norm_a ? (sum3[6] ^ cin6_n3) : fmu_u3[3]);

	generate
	for (gi = 4; gi <= 9; gi = gi + 1) begin : g_fm_4_9
		assign far_m[gi] = mu_bit[gi] ^ (cin_6 & p_mux[gi]);
	end
	for (gi = 10; gi <= 15; gi = gi + 1) begin : g_fm_10_15
		assign far_m[gi] = mu_bit[gi] ^ (cin_12 & p_mux[gi]);
	end
	for (gi = 16; gi <= 21; gi = gi + 1) begin : g_fm_16_21
		assign far_m[gi] = mu_bit[gi] ^ (cin_12 & p12_3[17] & p_mux[gi]);
	end
	endgenerate
	assign far_m[22] = mu_bit[22] ^ (cin_12 & p12_3[17] & p18_3[23] & p_mux[22]);

	/* Final packing (<= 3-4 LUT levels total, 0 CARRY4s) */
	(* keep = "true", dont_touch = "true" *) wire far_mz = !is_close_a && (ex2_0_3 || (ex2_1_3 && !far_c_d && !far_norm_d) || (ex2_254_3 && far_c_d));
	(* keep = "true", dont_touch = "true" *) wire force_mz_a = sp3 || sz3 || far_mz || cudf_lt || (cudf_eq && cudf_lo);
	(* keep = "true", dont_touch = "true" *) wire force_mz_b = sp3 || sz3 || far_mz || cudf_lt || (cudf_eq && cudf_lo);

	(* keep = "true", dont_touch = "true" *) wire [22:0] m_out;
	generate
	for (gi = 0; gi < 12; gi = gi + 1) begin : g_mout_lo
		assign m_out[gi] = !force_mz_a && (is_close_a ? (!lz3_a[4] && nl_hi0[gi + 1]) : far_m[gi]);
	end
	for (gi = 12; gi < 22; gi = gi + 1) begin : g_mout_hi
		assign m_out[gi] = !force_mz_b && (is_close_b ? (lz3_b[4] ? nl_hi1[gi + 1] : nl_hi0[gi + 1]) : far_m[gi]);
	end
	endgenerate
	assign m_out[22] = sp_nan3 || (!force_mz_b && (is_close_b ? close_m22 : far_m[22]));

	(* keep = "true", dont_touch = "true" *) wire use_close_e = !sp3 && !sz3 && is_close_b && !cudf_lt && !(cudf_eq && cudf_lo);
	(* keep = "true", dont_touch = "true" *) wire sp_force_ff = sp_nan3 || sp_inf3;
	(* keep = "true", dont_touch = "true" *) wire sp_force_0  = (sp3 && !sp_nan3 && !sp_inf3) || sz3 || is_close_b;
	(* keep = "true", dont_touch = "true" *) wire far_zero_c0 = ex2_0_3 || (ex2_1_3 && !far_c_e && !far_norm_e);
	(* keep = "true", dont_touch = "true" *) wire far_ovf_c1  = ex2_254_3 && (far_c_e || far_norm_e);

	(* keep = "true", dont_touch = "true" *) wire [7:0] ebit_c0, ebit_c1;
	(* keep = "true", dont_touch = "true" *) wire [7:0] far_e_c0, far_e_c1;
	(* keep = "true", dont_touch = "true" *) wire [7:0] e_out;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_eout
		wire fc_e = (gi < 4) ? far_c_d : far_c_e;
		wire fn_e = (gi < 4) ? far_norm_d : far_norm_e;
		assign ebit_c0[gi] = fc_e ? ex2_p1_3[gi] : (fn_e ? ex2_3[gi] : ex2_sub1_3[gi]);
		assign ebit_c1[gi] = (fc_e || fn_e) ? ex2_p1_3[gi] : ex2_3[gi];
		assign far_e_c0[gi] = (sp_force_ff || (!sp_force_0 && ex2_254_3 && far_c_e)) ? 1'b1 :
		                      (sp_force_0 || far_zero_c0) ? 1'b0 : ebit_c0[gi];
		assign far_e_c1[gi] = (sp_force_ff || (!sp_force_0 && far_ovf_c1)) ? 1'b1 :
		                      (sp_force_0 || ex2_0_3) ? 1'b0 : ebit_c1[gi];
		assign e_out[gi] = use_close_e ? close_e[gi] : (far_m0_cout ? far_e_c1[gi] : far_e_c0[gi]);
	end
	endgenerate

	wire o_valid_comb = rst_n && v3;
	(* keep = "true", dont_touch = "true" *) wire s_out = !sp_nan3 && sx3 && !sz3;
	wire [31:0] o_r_comb = {s_out, e_out, m_out};

	reg r_ovalid;
	(* max_fanout = 16 *) reg [31:0] r_or;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_ovalid <= 1'b0;
		end else if (en_s4[0]) begin
			r_ovalid <= o_valid_comb;
		end
	end

	always @(posedge clk) begin
		if (en_s4[1]) r_or[15:0]  <= o_r_comb[15:0];
		if (en_s4[2]) r_or[31:16] <= o_r_comb[31:16];
	end

	assign o_valid = r_ovalid;
	assign o_r     = r_or;

	wire unused_bits = &{1'b0, shr_0[26:8], shr_0[0], shr_1[26:15], shr_1[7:0], shr_2[14:0],
		nl_hi0[24], nl_hi0[0], nl_hi1[24], dab[7:5], dba[7:5], r_sub2_b, r_sub2_c,
		c_in_pad[27:25], nl_s1_pad[11:0], en_s3[11],
		close_bo0_unused, close_bo1_unused, sum_co_unused, LAT[31:0]};
endmodule

`default_nettype wire
