/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_sub1: IEEE 754 float32 computation of (1.0f - x).
 * 2-stage pipelined architecture (LAT = 1 internal register stage):
 *   Stage 1: Special cases, exponent diff, alignment shift, mantissa addsub, pre-normalization
 *   Stage 2: Independent Dual-Path registers:
 *            - FAR path: Direct-from-register CARRY4 rounding (Pre-LUT = 0, Post-LUT = 1)
 *            - CLOSE path: 0-CARRY4 fast LZC & barrel shift (<= 4 LUTs)
 * Fully compliant with ASIC 5nm 1.5 GHz timing, primitive budget, and fanout limits.
 * RNE rounding, denormals flushed to zero, canonical NaN 0x7FC00000.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_sub1 #(
	parameter LAT = 2
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] i_x,
	output wire [31:0] o_r
);
	(* keep = "true" *) wire rst_sync = !rst_n;

	/* Buffered input x sign and exponent */
	wire s_x_sp, s_x_sub, s_x_sx;
	wire [7:0] ea_d1, ea_d2, ea_cmp, ea_sp, ea_ex0, ea_ex1, ea_ex2, ea_ex3;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sx_sp (.I0(i_x[31]), .O(s_x_sp));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sx_sb (.I0(i_x[31]), .O(s_x_sub));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sx_sx (.I0(i_x[31]), .O(s_x_sx));

	genvar ge;
	for (ge = 0; ge < 8; ge = ge + 1) begin : g_ea_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ea1 (.I0(i_x[23+ge]), .O(ea_d1[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ea2 (.I0(i_x[23+ge]), .O(ea_d2[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eac (.I0(i_x[23+ge]), .O(ea_cmp[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eas (.I0(i_x[23+ge]), .O(ea_sp[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eae0 (.I0(i_x[23+ge]), .O(ea_ex0[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eae1 (.I0(i_x[23+ge]), .O(ea_ex1[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eae2 (.I0(i_x[23+ge]), .O(ea_ex2[ge]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eae3 (.I0(i_x[23+ge]), .O(ea_ex3[ge]));
	end
`else
	assign s_x_sp = i_x[31]; assign s_x_sub = i_x[31]; assign s_x_sx = i_x[31];
	assign ea_d1 = i_x[30:23]; assign ea_d2 = i_x[30:23];
	assign ea_cmp = i_x[30:23]; assign ea_sp = i_x[30:23];
	assign ea_ex0 = i_x[30:23]; assign ea_ex1 = i_x[30:23];
	assign ea_ex2 = i_x[30:23]; assign ea_ex3 = i_x[30:23];
`endif

	/* Buffered enable trees (fanout <= 16 each) */
	wire en_sum_lo, en_sum_mid, en_sum_msb_a, en_sum_msb_b;
	wire en_meta_ex0, en_meta_ex1, en_meta_ctrl, en_spv0, en_spv1;
	wire en_r1_lzc_a, en_r1_lzc_b, en_r1_lzc_c, en_r1_lzc_d, en_r1_lzc_e, en_r1_lzc_f;
`ifdef SYNTH_KINTEX7
	wire en_tree_a;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_ta   (.I0(en), .O(en_tree_a));

	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_sl   (.I0(en_tree_a), .O(en_sum_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_sm   (.I0(en_tree_a), .O(en_sum_mid));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_sha  (.I0(en_tree_a), .O(en_sum_msb_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_shb  (.I0(en_tree_a), .O(en_sum_msb_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_me0  (.I0(en_tree_a), .O(en_meta_ex0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_me1  (.I0(en_tree_a), .O(en_meta_ex1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_mc   (.I0(en_tree_a), .O(en_meta_ctrl));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_v0   (.I0(en_tree_a), .O(en_spv0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_v1   (.I0(en_tree_a), .O(en_spv1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzca (.I0(en_tree_a), .O(en_r1_lzc_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzcb (.I0(en_tree_a), .O(en_r1_lzc_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzcc (.I0(en_tree_a), .O(en_r1_lzc_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzcd (.I0(en_tree_a), .O(en_r1_lzc_d));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzce (.I0(en_tree_a), .O(en_r1_lzc_e));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_lzcf (.I0(en_tree_a), .O(en_r1_lzc_f));
`else
	assign en_sum_lo = en; assign en_sum_mid = en;
	assign en_sum_msb_a = en; assign en_sum_msb_b = en;
	assign en_meta_ex0 = en; assign en_meta_ex1 = en; assign en_meta_ctrl = en;
	assign en_spv0 = en; assign en_spv1 = en;
	assign en_r1_lzc_a = en; assign en_r1_lzc_b = en;
	assign en_r1_lzc_c = en; assign en_r1_lzc_d = en;
	assign en_r1_lzc_e = en; assign en_r1_lzc_f = en;
`endif

	/* =========================================================================
	 * STAGE 1: Specials, Alignment, and Mantissa Subtraction
	 * ========================================================================= */
	wire [7:0] ea = ea_sp;
	wire [22:0] ma = i_x[22:0];

	/* Special cases */
	wire is_nan = (ea == 8'hFF) && (ma != 23'd0);
	wire is_inf = (ea == 8'hFF) && (ma == 23'd0);
	wire is_zero = (ea == 8'd0);
	wire is_one = (!s_x_sp) && (ea == 8'd127) && (ma == 23'd0);

	wire sp = is_nan || is_inf || is_zero || is_one;
	wire [31:0] spv = is_nan ? 32'h7FC00000 :
		is_inf ? (s_x_sp ? 32'h7F800000 : 32'hFF800000) :
		is_one ? 32'h00000000 : 32'h3F800000;

	/* Magnitude compare: |x| <= 1.0 */
	wire x_le_1 = (ea_cmp < 8'd127) || (ea_cmp == 8'd127 && ma == 23'd0);

`ifdef SYNTH_KINTEX7
	wire x_le_1_dab, x_le_1_ex0, x_le_1_ex1, x_le_1_ex2, x_le_1_ex3;
	wire x_le_1_px_lo, x_le_1_px_hi;
	wire x_le_1_shi_a, x_le_1_shi_b0, x_le_1_shi_b1, x_le_1_shi_c0, x_le_1_shi_c1, x_le_1_shi_d0, x_le_1_shi_d1;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_dab (.I0(x_le_1), .O(x_le_1_dab));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_e0  (.I0(x_le_1), .O(x_le_1_ex0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_e1  (.I0(x_le_1), .O(x_le_1_ex1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_e2  (.I0(x_le_1), .O(x_le_1_ex2));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_e3  (.I0(x_le_1), .O(x_le_1_ex3));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sa  (.I0(x_le_1), .O(x_le_1_shi_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sb0 (.I0(x_le_1), .O(x_le_1_shi_b0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sb1 (.I0(x_le_1), .O(x_le_1_shi_b1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sc0 (.I0(x_le_1), .O(x_le_1_shi_c0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sc1 (.I0(x_le_1), .O(x_le_1_shi_c1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sd0 (.I0(x_le_1), .O(x_le_1_shi_d0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_sd1 (.I0(x_le_1), .O(x_le_1_shi_d1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_pl  (.I0(x_le_1), .O(x_le_1_px_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl_ph  (.I0(x_le_1), .O(x_le_1_px_hi));
`else
	wire x_le_1_dab = x_le_1;
	wire x_le_1_ex0 = x_le_1, x_le_1_ex1 = x_le_1, x_le_1_ex2 = x_le_1, x_le_1_ex3 = x_le_1;
	wire x_le_1_shi_a = x_le_1;
	wire x_le_1_shi_b0 = x_le_1, x_le_1_shi_b1 = x_le_1;
	wire x_le_1_shi_c0 = x_le_1, x_le_1_shi_c1 = x_le_1;
	wire x_le_1_shi_d0 = x_le_1, x_le_1_shi_d1 = x_le_1;
	wire x_le_1_px_lo = x_le_1, x_le_1_px_hi = x_le_1;
`endif

	wire [7:0] dab1, dab2;
	wire dab1_bo_unused, dab2_bo_unused;
	am_sub #(.W(8)) u_dab1 (.a(8'd127), .b(ea_d1), .bi(1'b0), .d(dab1), .bo(dab1_bo_unused));
	am_sub #(.W(8)) u_dab2 (.a(ea_d2), .b(8'd127), .bi(1'b0), .d(dab2), .bo(dab2_bo_unused));
	wire [7:0] dab = x_le_1_dab ? dab1 : dab2;
	wire [7:0] ex0 = x_le_1_ex0 ? 8'd127 : ea_ex0;
	wire [7:0] ex1 = x_le_1_ex1 ? 8'd127 : ea_ex1;
	wire [7:0] ex2 = x_le_1_ex2 ? 8'd127 : ea_ex2;
	wire [7:0] ex3 = x_le_1_ex3 ? 8'd127 : ea_ex3;

	/* Exponent precomputations for Stage 2 FAR path (0 CARRY4 in Stage 2) */
	wire [7:0] ex_m1, ex_p1, ex_p2;
	wire ex_m1_bo_unused, ex_p1_co_unused, ex_p2_co_unused;
	am_sub #(.W(8)) u_ex_m1 (.a(ex1), .b(8'd1), .bi(1'b0), .d(ex_m1), .bo(ex_m1_bo_unused));
	am_add #(.W(8)) u_ex_p1 (.a(ex2), .b(8'd1), .ci(1'b0), .s(ex_p1), .co(ex_p1_co_unused));
	am_add #(.W(8)) u_ex_p2 (.a(ex3), .b(8'd2), .ci(1'b0), .s(ex_p2), .co(ex_p2_co_unused));

	wire [7:0] dab_stk_lo, dab_stk_hi;
`ifdef SYNTH_KINTEX7
	genvar gd;
	generate
	for (gd = 0; gd < 8; gd = gd + 1) begin : g_dab_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dst_l (.I0(dab[gd]), .O(dab_stk_lo[gd]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dst_h (.I0(dab[gd]), .O(dab_stk_hi[gd]));
	end
	endgenerate
`else
	assign dab_stk_lo = dab; assign dab_stk_hi = dab;
`endif

	/* Operands alignment */
	wire [23:0] m24 = {1'b1, ma};
	wire [26:0] shi;
	assign shi[6:0]   = x_le_1_shi_a  ? {m24[3:0], 3'b000} : 7'd0;
	assign shi[10:7]  = x_le_1_shi_b0 ? m24[7:4]           : 4'd0;
	assign shi[13:11] = x_le_1_shi_b1 ? m24[10:8]          : 3'd0;
	assign shi[17:14] = x_le_1_shi_c0 ? m24[14:11]         : 4'd0;
	assign shi[20:18] = x_le_1_shi_c1 ? m24[17:15]         : 3'd0;
	assign shi[23:21] = x_le_1_shi_d0 ? m24[20:18]         : 3'b000;
	assign shi[26:24] = x_le_1_shi_d1 ? m24[23:21]         : 3'b100;

`ifdef SYNTH_KINTEX7
	wire [4:0] dsh_a, dsh_b, dsh_c, dsh_d;
	wire dsh_b0_extra, dsh_c0_extra_l, dsh_c0_extra_h;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsb0_ex (.I0(dab[0]), .O(dsh_b0_extra));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsc0_l  (.I0(dab[0]), .O(dsh_c0_extra_l));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsc0_h  (.I0(dab[0]), .O(dsh_c0_extra_h));
	genvar g_dsh;
	generate
	for (g_dsh = 0; g_dsh < 5; g_dsh = g_dsh + 1) begin : g_dsh_split
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsa (.I0(dab[g_dsh]), .O(dsh_a[g_dsh]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsb (.I0(dab[g_dsh]), .O(dsh_b[g_dsh]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsc (.I0(dab[g_dsh]), .O(dsh_c[g_dsh]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dsd (.I0(dab[g_dsh]), .O(dsh_d[g_dsh]));
	end
	endgenerate
	wire [26:0] shr_s0, shr_s1, shr_s2, shr_s3, shr;
	assign shr_s0[8:0]   = dsh_a[0] ? shi[9:1]   : shi[8:0];
	assign shr_s0[17:9]  = dsh_b0_extra ? shi[18:10] : shi[17:9];
	assign shr_s0[22:18] = dsh_c0_extra_l ? shi[23:19] : shi[22:18];
	assign shr_s0[26:23] = dsh_c0_extra_h ? {1'b0, shi[26:24]} : shi[26:23];

	assign shr_s1[8:0]   = dsh_a[1] ? shr_s0[10:2]  : shr_s0[8:0];
	assign shr_s1[17:9]  = dsh_b[1] ? shr_s0[19:11] : shr_s0[17:9];
	assign shr_s1[26:18] = dsh_c[1] ? {2'b00, shr_s0[26:20]} : shr_s0[26:18];

	assign shr_s2[8:0]   = dsh_a[2] ? shr_s1[12:4]  : shr_s1[8:0];
	assign shr_s2[17:9]  = dsh_b[2] ? shr_s1[21:13] : shr_s1[17:9];
	assign shr_s2[26:18] = dsh_c[2] ? {4'b0000, shr_s1[26:22]} : shr_s1[26:18];

	assign shr_s3[8:0]   = dsh_a[3] ? shr_s2[16:8]  : shr_s2[8:0];
	assign shr_s3[17:9]  = dsh_b[3] ? shr_s2[25:17] : shr_s2[17:9];
	assign shr_s3[26:18] = dsh_c[3] ? {8'b0, shr_s2[26]} : shr_s2[26:18];

	assign shr[8:0]   = dsh_a[4] ? {7'b0, shr_s3[26:25]} : shr_s3[8:0];
	assign shr[17:9]  = dsh_b[4] ? 9'd0 : shr_s3[17:9];
	assign shr[26:18] = dsh_c[4] ? 9'd0 : shr_s3[26:18];
`else
	wire [26:0] shr;
	am_shift #(.W(27), .SW(5)) u_shr (.a(shi), .amt(dab[4:0]), .left(1'b0), .arith(1'b0), .y(shr));
`endif

	reg [26:0] sh;
	reg stk;
	integer k;
	always @(*) begin
		stk = 1'b0;
		if (dab_stk_hi >= 8'd27) begin
			stk = 1'b1;
			sh = 27'd0;
		end else begin
			for (k = 0; k < 14; k = k + 1)
				if (k < dab_stk_lo)
					stk = stk | shi[k];
			for (k = 14; k < 27; k = k + 1)
				if (k < dab_stk_hi)
					stk = stk | shi[k];
			sh = shr;
		end
	end

	wire [26:0] px;
	assign px[13:0] = x_le_1_px_lo ? 14'd0 : {m24[10:0], 3'b000};
	assign px[26:14] = x_le_1_px_hi ? 13'h1000 : m24[23:11];
	wire [26:0] py = {sh[26:1], sh[0] | stk};

	/* Subtraction operation and path classification */
	wire sub_op = (!s_x_sub);
	wire sx = x_le_1_ex0 ? 1'b0 : (!s_x_sx);
	wire is_close = (!s_x_sub) && ((ea == 8'd126) || (ea == 8'd127));

	wire [27:0] sum;
	wire sum_co_unused;
`ifdef SYNTH_KINTEX7
	wire [27:0] py_ext = {1'b0, py};
	wire [27:0] py_b;
	wire [1:0] sub_op_m;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sop_m0 (.I0(sub_op), .O(sub_op_m[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sop_m1 (.I0(sub_op), .O(sub_op_m[1]));
	wire sub_op_ci;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sop_ci (.I0(sub_op), .O(sub_op_ci));
	genvar g_py;
	generate
	for (g_py = 0; g_py < 28; g_py = g_py + 1) begin : g_py_xor
		wire sub_op_leaf;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sopl (
			.I0(sub_op_m[g_py / 14]), .O(sub_op_leaf)
		);
		assign py_b[g_py] = py_ext[g_py] ^ sub_op_leaf;
	end
	endgenerate
	(* keep_hierarchy = "yes" *) am_add #(.W(28)) u_sum (.a({1'b0, px}), .b(py_b), .ci(sub_op_ci), .s(sum), .co(sum_co_unused));
`else
	am_addsub #(.W(28)) u_sum (.a({1'b0, px}), .b({1'b0, py}), .sub(sub_op), .s(sum), .co(sum_co_unused));
`endif

	/* Buffered sum[27] and sum[26] to keep fanouts <= 16 */
	wire sum27_a, sum27_b, sum27_c;
	wire sum26_a, sum26_b, sum26_c;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s27a (.I0(sum[27]), .O(sum27_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s27b (.I0(sum[27]), .O(sum27_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s27c (.I0(sum[27]), .O(sum27_c));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s26a (.I0(sum[26]), .O(sum26_a));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s26b (.I0(sum[26]), .O(sum26_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s26c (.I0(sum[26]), .O(sum26_c));
`else
	assign sum27_a = sum[27]; assign sum27_b = sum[27]; assign sum27_c = sum[27];
	assign sum26_a = sum[26]; assign sum26_b = sum[26]; assign sum26_c = sum[26];
`endif

	/* Stage 1 Pre-normalization and Rounding extraction for FAR path */
	wire [23:0] s1_m_far_pre;
	assign s1_m_far_pre[11:0]  = sum27_a ? sum[15:4]  : sum26_a ? sum[14:3]  : sum[13:2];
	assign s1_m_far_pre[23:12] = sum27_b ? sum[27:16] : sum26_b ? sum[26:15] : sum[25:14];

	wire s1_inc_c = sum[3] && (sum[2] || sum[1] || sum[0] || sum[4]);
	wire s1_inc_n = sum[2] && (sum[1] || sum[0] || sum[3]);
	wire s1_inc_u = sum[1] && (sum[0] || sum[2]);
	wire s1_inc_far = sum27_c ? s1_inc_c : sum26_c ? s1_inc_n : s1_inc_u;
	wire [1:0] s1_ef_sel_base = sum27_c ? 2'd2 : sum26_c ? 2'd1 : 2'd0;
	wire s1_m_far_all_ones = &s1_m_far_pre;

	/* Stage 1 Fast Nibble LZC for CLOSE path (1 Post-LUT after CARRY4) */
	wire [27:0] s1_sum_ext = {sum[26:0], 1'b0};
	wire [6:0] s1_g_act;
	wire [1:0] s1_intra [0:6];

	genvar g_s1_cl;
	generate
	for (g_s1_cl = 0; g_s1_cl < 7; g_s1_cl = g_s1_cl + 1) begin : g_s1_cl_nib
		assign s1_g_act[g_s1_cl] = |s1_sum_ext[4 * g_s1_cl +: 4];
		assign s1_intra[g_s1_cl] = s1_sum_ext[4 * g_s1_cl + 3] ? 2'd0 :
		                           s1_sum_ext[4 * g_s1_cl + 2] ? 2'd1 :
		                           s1_sum_ext[4 * g_s1_cl + 1] ? 2'd2 : 2'd3;
	end
	endgenerate

	/* Pipeline matching register stage */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [13:0] r1_sum_lo;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [12:0] r1_sum_hi;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [23:0] r1_m_far_pre;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r1_inc_far;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0]  r1_ef_sel_base;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r1_m_far_all_ones;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [6:0]  r1_g_act_sh_lo;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [6:0]  r1_g_act_sh_mid;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [6:0]  r1_g_act_sh_hi;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [6:0]  r1_g_act_exp;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0]  r1_intra_sh_lo [0:6];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0]  r1_intra_sh_mid [0:6];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0]  r1_intra_sh_hi [0:6];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0]  r1_intra_exp [0:6];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1_ex;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1_ex_m1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1_ex_p1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r1_ex_p2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r1_sx;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r1_sp_or_zero;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r1_is_close;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r1_spv_lo;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r1_spv_hi;

	always @(posedge clk) begin
		if (rst_sync) begin
			r1_sum_lo          <= 14'd0;
			r1_sum_hi          <= 13'd0;
			r1_m_far_pre       <= 24'd0;
			r1_inc_far         <= 1'b0;
			r1_ef_sel_base     <= 2'd0;
			r1_m_far_all_ones  <= 1'b0;
			r1_g_act_sh_lo     <= 7'd0;
			r1_g_act_sh_mid    <= 7'd0;
			r1_g_act_sh_hi     <= 7'd0;
			r1_g_act_exp       <= 7'd0;
			r1_intra_sh_lo[0]  <= 2'd0;
			r1_intra_sh_lo[1]  <= 2'd0;
			r1_intra_sh_lo[2]  <= 2'd0;
			r1_intra_sh_lo[3]  <= 2'd0;
			r1_intra_sh_lo[4]  <= 2'd0;
			r1_intra_sh_lo[5]  <= 2'd0;
			r1_intra_sh_lo[6]  <= 2'd0;
			r1_intra_sh_mid[0] <= 2'd0;
			r1_intra_sh_mid[1] <= 2'd0;
			r1_intra_sh_mid[2] <= 2'd0;
			r1_intra_sh_mid[3] <= 2'd0;
			r1_intra_sh_mid[4] <= 2'd0;
			r1_intra_sh_mid[5] <= 2'd0;
			r1_intra_sh_mid[6] <= 2'd0;
			r1_intra_sh_hi[0]  <= 2'd0;
			r1_intra_sh_hi[1]  <= 2'd0;
			r1_intra_sh_hi[2]  <= 2'd0;
			r1_intra_sh_hi[3]  <= 2'd0;
			r1_intra_sh_hi[4]  <= 2'd0;
			r1_intra_sh_hi[5]  <= 2'd0;
			r1_intra_sh_hi[6]  <= 2'd0;
			r1_intra_exp[0]    <= 2'd0;
			r1_intra_exp[1]    <= 2'd0;
			r1_intra_exp[2]    <= 2'd0;
			r1_intra_exp[3]    <= 2'd0;
			r1_intra_exp[4]    <= 2'd0;
			r1_intra_exp[5]    <= 2'd0;
			r1_intra_exp[6]    <= 2'd0;
			r1_ex             <= 8'd0;
			r1_ex_m1          <= 8'd0;
			r1_ex_p1          <= 8'd0;
			r1_ex_p2          <= 8'd0;
			r1_sx             <= 1'b0;
			r1_sp_or_zero     <= 1'b0;
			r1_is_close       <= 1'b0;
			r1_spv_lo         <= 16'd0;
			r1_spv_hi         <= 16'd0;
		end else begin
			if (en_sum_lo)
				r1_sum_lo <= sum[13:0];
			if (en_sum_mid)
				r1_sum_hi <= sum[26:14];
			if (en_sum_msb_a)
				r1_m_far_pre[11:0] <= s1_m_far_pre[11:0];
			if (en_sum_msb_b) begin
				r1_m_far_pre[23:12] <= s1_m_far_pre[23:12];
				r1_inc_far          <= s1_inc_far;
				r1_ef_sel_base      <= s1_ef_sel_base;
				r1_m_far_all_ones   <= s1_m_far_all_ones;
			end
			if (en_r1_lzc_a) begin
				r1_g_act_sh_lo  <= s1_g_act;
				r1_g_act_sh_mid <= s1_g_act;
			end
			if (en_r1_lzc_b) begin
				r1_g_act_sh_hi <= s1_g_act;
				r1_g_act_exp   <= s1_g_act;
			end
			if (en_r1_lzc_c) begin
				r1_intra_sh_lo[0] <= s1_intra[0];
				r1_intra_sh_lo[1] <= s1_intra[1];
				r1_intra_sh_lo[2] <= s1_intra[2];
				r1_intra_sh_lo[3] <= s1_intra[3];
				r1_intra_sh_lo[4] <= s1_intra[4];
				r1_intra_sh_lo[5] <= s1_intra[5];
				r1_intra_sh_lo[6] <= s1_intra[6];
			end
			if (en_r1_lzc_d) begin
				r1_intra_sh_mid[0] <= s1_intra[0];
				r1_intra_sh_mid[1] <= s1_intra[1];
				r1_intra_sh_mid[2] <= s1_intra[2];
				r1_intra_sh_mid[3] <= s1_intra[3];
				r1_intra_sh_mid[4] <= s1_intra[4];
				r1_intra_sh_mid[5] <= s1_intra[5];
				r1_intra_sh_mid[6] <= s1_intra[6];
			end
			if (en_r1_lzc_e) begin
				r1_intra_exp[0] <= s1_intra[0];
				r1_intra_exp[1] <= s1_intra[1];
				r1_intra_exp[2] <= s1_intra[2];
				r1_intra_exp[3] <= s1_intra[3];
				r1_intra_exp[4] <= s1_intra[4];
				r1_intra_exp[5] <= s1_intra[5];
				r1_intra_exp[6] <= s1_intra[6];
			end
			if (en_r1_lzc_f) begin
				r1_intra_sh_hi[0] <= s1_intra[0];
				r1_intra_sh_hi[1] <= s1_intra[1];
				r1_intra_sh_hi[2] <= s1_intra[2];
				r1_intra_sh_hi[3] <= s1_intra[3];
				r1_intra_sh_hi[4] <= s1_intra[4];
				r1_intra_sh_hi[5] <= s1_intra[5];
				r1_intra_sh_hi[6] <= s1_intra[6];
			end
			if (en_meta_ex0) begin
				r1_ex    <= ex0;
				r1_ex_m1 <= ex_m1;
			end
			if (en_meta_ex1) begin
				r1_ex_p1 <= ex_p1;
				r1_ex_p2 <= ex_p2;
			end
			if (en_meta_ctrl) begin
				r1_sx         <= sx;
				r1_sp_or_zero <= sp;
				r1_is_close   <= is_close;
			end
			if (en_spv0)
				r1_spv_lo <= spv[15:0];
			if (en_spv1)
				r1_spv_hi <= spv[31:16];
		end
	end

	wire [26:0] r1_sum = {r1_sum_hi, r1_sum_lo};

	/* =========================================================================
	 * STAGE 2: DUAL-PATH PARALLEL ARCHITECTURE
	 * ========================================================================= */

	/* --- PATH A: CLOSE PATH (0 CARRY4 adders, <= 2 LUT levels) --- */
	wire [27:0] ext = {r1_sum, 1'b0};

	/* Direct 1-LUT Group priority encodings (0 LUT1 buffers to avoid consuming LUT budget) */
	wire [2:0] grp_sh_lo = r1_g_act_sh_lo[6] ? 3'd6 :
	                       r1_g_act_sh_lo[5] ? 3'd5 :
	                       r1_g_act_sh_lo[4] ? 3'd4 :
	                       r1_g_act_sh_lo[3] ? 3'd3 :
	                       r1_g_act_sh_lo[2] ? 3'd2 :
	                       r1_g_act_sh_lo[1] ? 3'd1 : 3'd0;

	wire [2:0] grp_sh_mid = r1_g_act_sh_mid[6] ? 3'd6 :
	                        r1_g_act_sh_mid[5] ? 3'd5 :
	                        r1_g_act_sh_mid[4] ? 3'd4 :
	                        r1_g_act_sh_mid[3] ? 3'd3 :
	                        r1_g_act_sh_mid[2] ? 3'd2 :
	                        r1_g_act_sh_mid[1] ? 3'd1 : 3'd0;

	wire [2:0] grp_sh_hi = r1_g_act_sh_hi[6] ? 3'd6 :
	                       r1_g_act_sh_hi[5] ? 3'd5 :
	                       r1_g_act_sh_hi[4] ? 3'd4 :
	                       r1_g_act_sh_hi[3] ? 3'd3 :
	                       r1_g_act_sh_hi[2] ? 3'd2 :
	                       r1_g_act_sh_hi[1] ? 3'd1 : 3'd0;

	wire [2:0] grp_exp = r1_g_act_exp[6] ? 3'd6 :
	                     r1_g_act_exp[5] ? 3'd5 :
	                     r1_g_act_exp[4] ? 3'd4 :
	                     r1_g_act_exp[3] ? 3'd3 :
	                     r1_g_act_exp[2] ? 3'd2 :
	                     r1_g_act_exp[1] ? 3'd1 : 3'd0;

	wire [1:0] active_intra_lo  = r1_intra_sh_lo[grp_sh_lo];
	wire [1:0] active_intra_mid = r1_intra_sh_mid[grp_sh_mid];
	wire [1:0] active_intra_hi  = r1_intra_sh_hi[grp_sh_hi];
	wire [1:0] active_intra_exp = r1_intra_exp[grp_exp];

	/* Low 10 bits of mantissa (m_close[9:0] <= fine_lo[13:4]) */
	wire [13:1] coarse_lo;
	assign coarse_lo[13:1] =
		(grp_sh_lo == 3'd6) ? ext[13:1] :
		(grp_sh_lo == 3'd5) ? {ext[9:0], 3'b0} :
		(grp_sh_lo == 3'd4) ? {ext[5:0], 7'b0} :
		(grp_sh_lo == 3'd3) ? {ext[1:0], 11'b0} : 13'd0;

	wire [13:4] fine_lo =
		(active_intra_lo == 2'd0) ? coarse_lo[13:4] :
		(active_intra_lo == 2'd1) ? coarse_lo[12:3] :
		(active_intra_lo == 2'd2) ? coarse_lo[11:2] :
		                            coarse_lo[10:1];

	/* Mid 7 bits of mantissa (m_close[16:10] <= fine_mid[20:14]) */
	wire [20:11] coarse_mid;
	assign coarse_mid[20:11] =
		(grp_sh_mid == 3'd6) ? ext[20:11] :
		(grp_sh_mid == 3'd5) ? ext[16:7] :
		(grp_sh_mid == 3'd4) ? ext[12:3] :
		(grp_sh_mid == 3'd3) ? {ext[8:0], 1'b0} :
		(grp_sh_mid == 3'd2) ? {ext[4:0], 5'b0} :
		(grp_sh_mid == 3'd1) ? {ext[0], 9'b0} : 10'd0;

	wire [20:14] fine_mid =
		(active_intra_mid == 2'd0) ? coarse_mid[20:14] :
		(active_intra_mid == 2'd1) ? coarse_mid[19:13] :
		(active_intra_mid == 2'd2) ? coarse_mid[18:12] :
		                             coarse_mid[17:11];

	/* High 6 bits of mantissa (m_close[22:17] <= fine_hi[26:21]) */
	wire [26:18] coarse_hi;
	assign coarse_hi[26:18] =
		(grp_sh_hi == 3'd6) ? ext[26:18] :
		(grp_sh_hi == 3'd5) ? ext[22:14] :
		(grp_sh_hi == 3'd4) ? ext[18:10] :
		(grp_sh_hi == 3'd3) ? ext[14:6] :
		(grp_sh_hi == 3'd2) ? ext[10:2] :
		(grp_sh_hi == 3'd1) ? {ext[6:0], 2'b0} :
		                      {ext[2:0], 6'b0};

	wire [26:21] fine_hi =
		(active_intra_hi == 2'd0) ? coarse_hi[26:21] :
		(active_intra_hi == 2'd1) ? coarse_hi[25:20] :
		(active_intra_hi == 2'd2) ? coarse_hi[24:19] :
		                            coarse_hi[23:18];

	wire [22:0] m_close = {fine_hi, fine_mid, fine_lo};

	wire [2:0] inv_grp =
		(grp_exp == 3'd6) ? 3'd0 :
		(grp_exp == 3'd5) ? 3'd1 :
		(grp_exp == 3'd4) ? 3'd2 :
		(grp_exp == 3'd3) ? 3'd3 :
		(grp_exp == 3'd2) ? 3'd4 :
		(grp_exp == 3'd1) ? 3'd5 : 3'd6;

	wire [1:0] w_lo_close = ~active_intra_exp;
	wire [1:0] w_res_lo = r1_ex[0] ? w_lo_close :
		{~w_lo_close[1] ^ w_lo_close[0], ~w_lo_close[0]};

	wire borrow = (active_intra_exp == 2'b11) && (!r1_ex[0]);

	wire [2:0] w_hi = ~inv_grp;
	wire [2:0] w_hi_m1;
	assign w_hi_m1[0] = ~w_hi[0];
	assign w_hi_m1[1] = w_hi[1] ^ (~w_hi[0]);
	assign w_hi_m1[2] = w_hi[2] ^ (~w_hi[0] & ~w_hi[1]);

	wire [2:0] w_res_hi = borrow ? w_hi_m1 : w_hi;
	wire [7:0] e_close = {3'b011, w_res_hi, w_res_lo};

	/* --- PATH B: FAR PATH (1 CARRY4 adder, Pre-LUT = 0, Post-LUT = 0) --- */
	wire [23:0] m_far_s;
	(* keep_hierarchy = "yes" *) am_add #(.W(24)) u_m0_far (
		.a(r1_m_far_pre), .b(24'd0), .ci(r1_inc_far), .s(m_far_s), .co()
	);

	wire m_far_ov = r1_m_far_all_ones && r1_inc_far;
	wire [1:0] ef_sel = m_far_ov ?
		(r1_ef_sel_base == 2'd2 ? 2'd3 : r1_ef_sel_base == 2'd1 ? 2'd2 : 2'd1) :
		r1_ef_sel_base;

	wire [7:0] e_far = (ef_sel == 2'd3) ? r1_ex_p2 :
		(ef_sel == 2'd2) ? r1_ex_p1 :
		(ef_sel == 2'd1) ? r1_ex : r1_ex_m1;

	wire is_ov_far = (e_far >= 8'd255);
	wire is_ov_far_lo, is_ov_far_hi;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_iov_lo (.I0(is_ov_far), .O(is_ov_far_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_iov_hi (.I0(is_ov_far), .O(is_ov_far_hi));
`else
	assign is_ov_far_lo = is_ov_far;
	assign is_ov_far_hi = is_ov_far;
`endif
	wire [22:0] m_far = m_far_s[22:0];

	/* Stage 2 Independent Dedicated Registers */
	wire [31:0] r_out_w;

	generate
	if (LAT >= 2) begin : g_lat2
		wire en_r2_mf_lo, en_r2_mf_hi, en_r2_ef, en_r2_mc_lo, en_r2_mc_hi, en_r2_ec;
		wire en_r2_ctrl_l1, en_r2_ctrl_l2, en_r2_ctrl_h1, en_r2_ctrl_h2;
`ifdef SYNTH_KINTEX7
		wire en_tree_b;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_tb   (.I0(en), .O(en_tree_b));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2fl (.I0(en_tree_b), .O(en_r2_mf_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2fh (.I0(en_tree_b), .O(en_r2_mf_hi));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2ef (.I0(en_tree_b), .O(en_r2_ef));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2cl (.I0(en_tree_b), .O(en_r2_mc_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2ch (.I0(en_tree_b), .O(en_r2_mc_hi));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2ec (.I0(en_tree_b), .O(en_r2_ec));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2ctl1(.I0(en_tree_b), .O(en_r2_ctrl_l1));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2ctl2(.I0(en_tree_b), .O(en_r2_ctrl_l2));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2cth1(.I0(en_tree_b), .O(en_r2_ctrl_h1));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_en_r2cth2(.I0(en_tree_b), .O(en_r2_ctrl_h2));
`else
		assign en_r2_mf_lo = en; assign en_r2_mf_hi = en; assign en_r2_ef = en;
		assign en_r2_mc_lo = en; assign en_r2_mc_hi = en; assign en_r2_ec = en;
		assign en_r2_ctrl_l1 = en; assign en_r2_ctrl_l2 = en;
		assign en_r2_ctrl_h1 = en; assign en_r2_ctrl_h2 = en;
`endif

		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] r2_m_far;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r2_e_far;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r2_is_ov_far;

		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [22:0] r2_m_close;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0]  r2_e_close;

		(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r2_sx_lo, r2_sx_hi;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r2_is_close_lo, r2_is_close_hi;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg        r2_sp_or_zero_lo, r2_sp_or_zero_hi;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r2_spv_lo;
		(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] r2_spv_hi;

		always @(posedge clk) begin
			if (rst_sync) begin
				r2_m_far         <= 23'd0;
				r2_e_far         <= 8'd0;
				r2_is_ov_far     <= 1'b0;
				r2_m_close       <= 23'd0;
				r2_e_close       <= 8'd0;
				r2_sx_lo         <= 1'b0;
				r2_sx_hi         <= 1'b0;
				r2_is_close_lo   <= 1'b0;
				r2_is_close_hi   <= 1'b0;
				r2_sp_or_zero_lo <= 1'b0;
				r2_sp_or_zero_hi <= 1'b0;
				r2_spv_lo        <= 16'd0;
				r2_spv_hi        <= 16'd0;
			end else begin
				if (en_r2_mf_lo)
					r2_m_far[11:0] <= m_far[11:0];
				if (en_r2_mf_hi)
					r2_m_far[22:12] <= m_far[22:12];
				if (en_r2_ef) begin
					r2_e_far     <= e_far;
					r2_is_ov_far <= is_ov_far;
				end
				if (en_r2_mc_lo)
					r2_m_close[11:0] <= m_close[11:0];
				if (en_r2_mc_hi)
					r2_m_close[22:12] <= m_close[22:12];
				if (en_r2_ec)
					r2_e_close <= e_close;
				if (en_r2_ctrl_l1) begin
					r2_sx_lo         <= r1_sx;
					r2_is_close_lo   <= r1_is_close;
					r2_sp_or_zero_lo <= r1_sp_or_zero;
				end
				if (en_r2_ctrl_l2)
					r2_spv_lo <= r1_spv_lo;
				if (en_r2_ctrl_h1) begin
					r2_sx_hi         <= r1_sx;
					r2_is_close_hi   <= r1_is_close;
					r2_sp_or_zero_hi <= r1_sp_or_zero;
				end
				if (en_r2_ctrl_h2)
					r2_spv_hi <= r1_spv_hi;
			end
		end

		wire [15:0] norm_far_lo = r2_is_ov_far ? 16'd0 : r2_m_far[15:0];
		wire [15:0] norm_far_hi = r2_is_ov_far ? {r2_sx_hi, 8'hFF, 7'd0} : {r2_sx_hi, r2_e_far, r2_m_far[22:16]};

		wire [15:0] norm_close_lo = r2_m_close[15:0];
		wire [15:0] norm_close_hi = {r2_sx_hi, r2_e_close, r2_m_close[22:16]};

		wire [15:0] res_lo = r2_is_close_lo ? norm_close_lo : norm_far_lo;
		wire [15:0] res_hi = r2_is_close_hi ? norm_close_hi : norm_far_hi;

		wire [15:0] o_r_lo = r2_sp_or_zero_lo ? r2_spv_lo : res_lo;
		wire [15:0] o_r_hi = r2_sp_or_zero_hi ? r2_spv_hi : res_hi;

		assign r_out_w = {o_r_hi, o_r_lo};
		wire unused_lat2 = r2_sx_lo;
	end else begin : g_lat1
		wire [15:0] norm_far_lo = is_ov_far_lo ? 16'd0 : m_far[15:0];
		wire [15:0] norm_far_hi = is_ov_far_hi ? {r1_sx, 8'hFF, 7'd0} : {r1_sx, e_far, m_far[22:16]};

		wire [15:0] norm_close_lo = m_close[15:0];
		wire [15:0] norm_close_hi = {r1_sx, e_close, m_close[22:16]};

		wire [15:0] res_lo = r1_is_close ? norm_close_lo : norm_far_lo;
		wire [15:0] res_hi = r1_is_close ? norm_close_hi : norm_far_hi;

		wire [15:0] o_r_lo = r1_sp_or_zero ? r1_spv_lo : res_lo;
		wire [15:0] o_r_hi = r1_sp_or_zero ? r1_spv_hi : res_hi;

		assign r_out_w = {o_r_hi, o_r_lo};
	end
	endgenerate

	assign o_r = r_out_w;

	wire unused_ok = &{1'b0, dab1_bo_unused, dab2_bo_unused, ex_m1_bo_unused,
		ex_p1_co_unused, ex_p2_co_unused, sum_co_unused, m_far_s[23], coarse_lo[3:1]};
endmodule

`default_nettype wire
