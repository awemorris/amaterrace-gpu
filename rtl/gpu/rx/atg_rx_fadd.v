/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fadd: optimized fp32 adder / subtractor for RX pipeline (LAT = 0 or 4).
 * Dual-path normalisation & rounding architecture compliant with ASIC 5nm 1.5 GHz
 * timing and primitive limits (LAT = 4).
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rx_fadd #(
	parameter LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	input wire i_sub,
	output wire o_valid,
	output wire [31:0] o_r
);
	/* Stage 1: unpack, specials, order by magnitude. */
	wire [31:0] b_in = {i_b[31] ^ i_sub, i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && b_in[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && b_in[22:0] == 23'd0;

	/* the exponent difference, larger minus smaller (<= 1 Post-CARRY4 LUT in Stage 1) */
	wire [7:0] dab, dba;
	wire ea_lt_eb, dba_bo_unused;
	am_sub #(.W(8)) u_dab (.a(ea), .b(eb), .bi(1'b0), .d(dab), .bo(ea_lt_eb));
	am_sub #(.W(8)) u_dba (.a(eb), .b(ea), .bi(1'b0), .d(dba), .bo(dba_bo_unused));

	/* 4 replicated 31-bit magnitude comparators to keep CARRY4 borrow fanout <= 15
	 * and Post-LUTs <= 1. */
	(* keep = "true" *) wire [3:0] a_lt_b;
	wire [30:0] cmp_diff_unused [0:3];
	genvar gc;
	generate
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_cmp
		am_sub #(.W(31)) u_cmp (
			.a(i_a[30:0]),
			.b(i_b[30:0]),
			.bi(1'b0),
			.d(cmp_diff_unused[gc]),
			.bo(a_lt_b[gc])
		);
	end
	endgenerate

	wire v1_w = rst_n && i_valid;
	wire sp_nan1_w = nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31]);
	wire sp_inf1_w = !sp_nan1_w && (inf_a || inf_b);
	wire sp_zero1_w = !sp_nan1_w && !sp_inf1_w && (za && zb);
	wire sp1_w = sp_nan1_w || sp_inf1_w || sp_zero1_w;
	wire sx_norm1_w = a_lt_b[3] ? b_in[31] : i_a[31];
	wire sp_sx1_w = !sp_nan1_w && (inf_a ? i_a[31] : inf_b ? b_in[31] : (i_a[31] && b_in[31]));
	wire sx1_w = sp1_w ? sp_sx1_w : sx_norm1_w;
	wire sub1_w = i_a[31] != b_in[31];
	wire y_zero1_w = za || zb;
	wire [7:0] ex1_w = a_lt_b[3] ? eb : ea;
	wire [23:0] mx1_w = {1'b1,
		a_lt_b[1] ? b_in[22:15] : i_a[22:15],
		a_lt_b[0] ? b_in[14:0]  : i_a[14:0]};
	wire [23:0] my1_w = {1'b1,
		a_lt_b[3] ? i_a[22:21] : b_in[22:21],
		a_lt_b[2] ? i_a[20:6]  : b_in[20:6],
		a_lt_b[1] ? i_a[5:0]   : b_in[5:0]};
	wire [4:0] d1_w = ea_lt_eb ? dba[4:0] : dab[4:0];
	wire ealtb1_w = ea_lt_eb;
	wire dab_hi1_w = (dab[7:5] != 3'd0);
	wire dba_hi1_w = (dba[7:5] != 3'd0);
	wire dab_cc1_w = (dab[4:1] == 4'd0);
	wire dba_cc1_w = (dba[4:1] == 4'd0);
	wire cc_en1_w = (i_a[31] != b_in[31]) && !za && !zb;

	wire v1, sp1, sp_nan1, sp_inf1, sx1, sub1_a, sub1_b, y_zero1_a, y_zero1_b, close_cand1;
	wire ealtb1, dab_hi1, dba_hi1;
	wire [7:0] ex1;
	wire [4:0] d1_a, d1_b, d1_c, d1_d;
	wire d1_e0, d1_f0;
	wire [23:0] mx1, my1;

	/* Stage 2:
	 * - Far path: align smaller operand, compute 3-level chunked sticky bit, and XOR with sub1.
	 * - Close path: 25-bit exact subtraction for d1 <= 1.
	 */
	wire [26:0] shi = {my1, 3'b000};
	wire [26:0] shr_0, shr_1, shr_2;
	am_shift #(.W(27), .SW(5)) u_shr_0 (.a(shi), .amt(d1_a), .left(1'b0), .arith(1'b0), .y(shr_0));
	am_shift #(.W(27), .SW(5)) u_shr_1 (.a(shi), .amt(d1_d), .left(1'b0), .arith(1'b0), .y(shr_1));
	am_shift #(.W(27), .SW(5)) u_shr_2 (.a(shi), .amt(d1_b), .left(1'b0), .arith(1'b0), .y(shr_2));

	wire [5:0] st_full, st_part;
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

	reg stk_raw;
	always @(*) begin
		if (d1_c < 5'd3)
			stk_raw = 1'b0;
		else if (d1_c < 5'd7)
			stk_raw = st_part[0];
		else if (d1_c < 5'd11)
			stk_raw = st_full[0] | st_part[1];
		else if (d1_c < 5'd15)
			stk_raw = (|st_full[1:0]) | st_part[2];
		else if (d1_c < 5'd19)
			stk_raw = (|st_full[2:0]) | st_part[3];
		else if (d1_c < 5'd23)
			stk_raw = (|st_full[3:0]) | st_part[4];
		else if (d1_c < 5'd27)
			stk_raw = (|st_full[4:0]) | st_part[5];
		else
			stk_raw = |st_full[5:0];
	end
	(* keep = "true" *) wire y_clr_lo = y_zero1_a || (ealtb1 ? dba_hi1 : dab_hi1);
	(* keep = "true" *) wire y_clr_hi = y_zero1_b || (ealtb1 ? dba_hi1 : dab_hi1);
	wire py2_bit0 = !y_zero1_a && ((ealtb1 ? dba_hi1 : dab_hi1) || stk_raw);
	wire [13:0] py2_raw_lo = {y_clr_lo ? 13'd0 : {shr_1[13:8], shr_0[7:1]}, py2_bit0};
	wire [26:14] py2_raw_hi = y_clr_hi ? 13'd0 : {shr_2[26:15], shr_1[14]};
	wire [26:0] py2_raw = {py2_raw_hi, py2_raw_lo};

	wire [24:0] close_a = {mx1, 1'b0};
	wire [12:0] close_b_lo = d1_e0 ? my1[12:0] : {my1[11:0], 1'b0};
	wire [24:13] close_b_hi = d1_f0 ? {1'b0, my1[23:13]} : my1[23:12];
	wire [24:0] close_b = {close_b_hi, close_b_lo};
	wire [24:0] close_diff2_w;
	wire close_sub_bo_unused;
	am_sub #(.W(25)) u_close_sub (.a(close_a), .b(close_b), .bi(1'b0), .d(close_diff2_w), .bo(close_sub_bo_unused));

	wire [7:0] ex2_p1_w, ex2_sub1_w;
	wire ex2_p1_co_unused, ex2_sub1_bo_unused;
	am_add #(.W(8)) u_ex2_p1 (.a(ex1), .b(8'd1), .ci(1'b0), .s(ex2_p1_w), .co(ex2_p1_co_unused));
	am_sub #(.W(8)) u_ex2_sub1 (.a(ex1), .b(8'd1), .bi(1'b0), .d(ex2_sub1_w), .bo(ex2_sub1_bo_unused));

	wire v2_w = rst_n && v1;
	wire sp2_w = sp1;
	wire sp_nan2_w = sp_nan1;
	wire sp_inf2_w = sp_inf1;
	wire sx2_w = sx1;
	wire sub2_w = sub1_a;
	wire close_cand2_w = close_cand1;
	wire [7:0] ex2_w = ex1;
	wire [26:0] px2_w = {mx1, 3'b000};
	wire [26:0] py2_w = {py2_raw[26:14] ^ {13{sub1_b}}, py2_raw[13:0] ^ {14{sub1_a}}};

	wire v2, sp2, sp_nan2, sp_inf2, sx2, sub2, close_cand2;
	wire [7:0] ex2, ex2_p1, ex2_sub1;
	wire [26:0] px2, py2;
	wire [24:0] close_diff2;

	/* Stage 3:
	 * - Far path: 28-bit addition u_sum, plus 1-LUT slice prefix-ANDs and low-bit rounding.
	 * - Close path: LZC and zero-detect from registered close_diff2 (0 CARRY4s).
	 */
	wire [27:0] sum;
	wire sum_co_unused;
	am_add #(.W(28)) u_sum (.a({1'b0, px2}), .b({sub2, py2}), .ci(sub2), .s(sum), .co(sum_co_unused));

	wire inc_c = sum[3] && (sum[2] || sum[1] || sum[0] || sum[4]);
	wire inc_n = sum[2] && (sum[1] || sum[0] || sum[3]);
	wire inc_u = sum[1] && (sum[0] || sum[2]);

	wire [1:0] fmu_c_w;
	assign fmu_c_w[0] = sum[4] ^ inc_c;
	assign fmu_c_w[1] = sum[5] ^ (inc_c & sum[4]);
	wire cin6_c_w = inc_c & sum[4] & sum[5];

	wire [2:0] fmu_n_w;
	assign fmu_n_w[0] = sum[3] ^ inc_n;
	assign fmu_n_w[1] = sum[4] ^ (inc_n & sum[3]);
	assign fmu_n_w[2] = sum[5] ^ (inc_n & sum[3] & sum[4]);
	wire cin6_n_w = inc_n & (&sum[5:3]);

	wire [3:0] fmu_u_w;
	assign fmu_u_w[0] = sum[2] ^ inc_u;
	assign fmu_u_w[1] = sum[3] ^ (inc_u & sum[2]);
	assign fmu_u_w[2] = sum[4] ^ (inc_u & sum[2] & sum[3]);
	assign fmu_u_w[3] = sum[5] ^ (inc_u & (&sum[4:2]));
	wire cin6_u_w = inc_u & (&sum[5:2]);

	wire [11:6] p6_w;
	assign p6_w[6]  = sum[6];
	assign p6_w[7]  = &sum[7:6];
	assign p6_w[8]  = &sum[8:6];
	assign p6_w[9]  = &sum[9:6];
	assign p6_w[10] = &sum[10:6];
	assign p6_w[11] = &sum[11:6];

	wire [17:12] p12_w;
	assign p12_w[12] = sum[12];
	assign p12_w[13] = &sum[13:12];
	assign p12_w[14] = &sum[14:12];
	assign p12_w[15] = &sum[15:12];
	assign p12_w[16] = &sum[16:12];
	assign p12_w[17] = &sum[17:12];

	wire [23:18] p18_w;
	assign p18_w[18] = sum[18];
	assign p18_w[19] = &sum[19:18];
	assign p18_w[20] = &sum[20:18];
	assign p18_w[21] = &sum[21:18];
	assign p18_w[22] = &sum[22:18];
	assign p18_w[23] = &sum[23:18];

	wire [26:24] p24_w;
	assign p24_w[24] = sum[24];
	assign p24_w[25] = &sum[25:24];
	assign p24_w[26] = &sum[26:24];

	/* Close path LZC on registered close_diff2 (no CARRY4 in Stage 3) */
	integer k;
	reg [4:0] lz;
	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 25; k = k + 1)
			if (close_diff2[k])
				lz = 5'd24 - k[4:0];
	end

	wire is_close3_w = close_cand2 && (close_diff2[24:23] == 2'b00);
	wire sz3_w = close_cand2 && (close_diff2 == 25'd0);
	wire ex2_le31_w = (ex2[7:5] == 3'd0);
	wire ex2_0_w = (ex2 == 8'd0);
	wire ex2_1_w = (ex2 == 8'd1);
	wire ex2_254_w = (ex2 == 8'd254);

	wire v3_w = rst_n && v2;
	wire sp3_w = sp2;
	wire sp_nan3_w = sp_nan2;
	wire sp_inf3_w = sp_inf2;
	wire sx3_w = sx2;
	wire [7:0] ex2_3_w = ex2;
	wire [7:0] ex2_p1_3_w = ex2_p1;
	wire [7:0] ex2_sub1_3_w = ex2_sub1;
	wire [22:0] close_diff3_w = close_diff2[22:0];

	wire v3, sp3, sp_nan3, sp_inf3, sx3, sz3;
	wire is_close_a, is_close_b;
	wire far_c_a, far_c_b, far_c_c, far_c_d, far_c_e;
	wire far_norm_a, far_norm_b, far_norm_c, far_norm_d, far_norm_e;
	wire [26:6] sum3;
	wire [1:0] fmu_c3;
	wire [2:0] fmu_n3;
	wire [3:0] fmu_u3;
	wire cin6_c3, cin6_n3, cin6_u3;
	wire [11:6] p6_3;
	wire [17:12] p12_3;
	wire [23:18] p18_3;
	wire [26:24] p24_3;
	wire [22:0] close_diff3;
	wire [4:0] lz3_a, lz3_b;
	wire [7:0] ex2_3, ex2_p1_3, ex2_sub1_3;
	wire ex2_le31_3, ex2_0_3, ex2_1_3, ex2_254_3;

	/* Stage 4:
	 * - Close path: 2-stage left shift (2 LUT levels) and 8-bit exponent subtract (1 Post-LUT).
	 * - Far path: 2-level factored-carry mantissa selection & 3-level output pack.
	 */
	wire [24:0] c_in_pad = {2'b00, close_diff3};
	reg [24:0] nl_s1;
	always @(*) begin
		for (k = 0; k < 13; k = k + 1) begin
			case (lz3_a[1:0])
			2'd0: nl_s1[k] = c_in_pad[k];
			2'd1: nl_s1[k] = (k >= 1) ? c_in_pad[k - 1] : 1'b0;
			2'd2: nl_s1[k] = (k >= 2) ? c_in_pad[k - 2] : 1'b0;
			default: nl_s1[k] = (k >= 3) ? c_in_pad[k - 3] : 1'b0;
			endcase
		end
		for (k = 13; k < 25; k = k + 1) begin
			case (lz3_b[1:0])
			2'd0: nl_s1[k] = c_in_pad[k];
			2'd1: nl_s1[k] = c_in_pad[k - 1];
			2'd2: nl_s1[k] = c_in_pad[k - 2];
			default: nl_s1[k] = c_in_pad[k - 3];
			endcase
		end
	end

	reg [24:0] nl;
	always @(*) begin
		for (k = 0; k < 13; k = k + 1) begin
			case (lz3_a[4:2])
			3'd0: nl[k] = nl_s1[k];
			3'd1: nl[k] = (k >= 4)  ? nl_s1[k - 4]  : 1'b0;
			3'd2: nl[k] = (k >= 8)  ? nl_s1[k - 8]  : 1'b0;
			3'd3: nl[k] = (k >= 12) ? nl_s1[k - 12] : 1'b0;
			default: nl[k] = 1'b0;
			endcase
		end
		for (k = 13; k < 25; k = k + 1) begin
			case (lz3_b[4:2])
			3'd0: nl[k] = nl_s1[k];
			3'd1: nl[k] = nl_s1[k - 4];
			3'd2: nl[k] = nl_s1[k - 8];
			3'd3: nl[k] = nl_s1[k - 12];
			3'd4: nl[k] = (k >= 16) ? nl_s1[k - 16] : 1'b0;
			3'd5: nl[k] = (k >= 20) ? nl_s1[k - 20] : 1'b0;
			3'd6: nl[k] = (k >= 24) ? nl_s1[k - 24] : 1'b0;
			default: nl[k] = 1'b0;
			endcase
		end
	end
	wire [22:0] close_m = nl[23:1];
	wire [7:0] close_e;
	wire close_e_bo_unused;
	am_sub #(.W(8)) u_close_e (.a(ex2_3), .b({3'd0, lz3_b}), .bi(1'b0), .d(close_e), .bo(close_e_bo_unused));
	(* keep = "true" *) wire cudf_lo = (ex2_3[2:0] <= lz3_a[2:0]);
	(* keep = "true" *) wire cudf_eq = is_close_a && ex2_le31_3 && (ex2_3[4:3] == lz3_a[4:3]);
	(* keep = "true" *) wire cudf_lt = is_close_a && ex2_le31_3 && (ex2_3[4:3] < lz3_a[4:3]);

	/* Far path Stage 4 */
	wire cin_6  = far_c_a ? cin6_c3 : (far_norm_a ? cin6_n3 : cin6_u3);
	wire cin_12 = (far_c_c ? cin6_c3 : (far_norm_c ? cin6_n3 : cin6_u3)) & p6_3[11];
	wire p24_sel = far_c_c ? 1'b0 : (far_norm_c ? p24_3[26] : p24_3[25]);
	wire far_m0_cout = cin_12 & p12_3[17] & p18_3[23] & p24_sel;

	wire [22:4] mu_bit;
	wire [22:4] p_mux;
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

	wire [22:0] far_m;
	assign far_m[0] = far_c_a ? fmu_c3[0] : (far_norm_a ? fmu_n3[0] : fmu_u3[0]);
	assign far_m[1] = far_c_a ? fmu_c3[1] : (far_norm_a ? fmu_n3[1] : fmu_u3[1]);
	assign far_m[2] = far_c_a ? (sum3[6] ^ cin6_c3) : (far_norm_a ? fmu_n3[2] : fmu_u3[2]);
	wire mu3_c = sum3[7] ^ (cin6_c3 & p6_3[6]);
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

	/* Final packing (<= 3 LUT levels total, <= 1 Post-LUT after u_close_e) */
	(* keep = "true" *) wire far_mz = !is_close_a && (ex2_0_3 || (ex2_1_3 && !far_c_d && !far_norm_d) || (ex2_254_3 && far_c_d));
	(* keep = "true" *) wire force_mz_a = sp3 || sz3 || far_mz || cudf_lt || (cudf_eq && cudf_lo);
	(* keep = "true" *) wire force_mz_b = sp3 || sz3 || far_mz || cudf_lt || (cudf_eq && cudf_lo);

	wire [22:0] m_out;
	generate
	for (gi = 0; gi < 12; gi = gi + 1) begin : g_mout_lo
		assign m_out[gi] = !force_mz_a && (is_close_a ? close_m[gi] : far_m[gi]);
	end
	for (gi = 12; gi < 22; gi = gi + 1) begin : g_mout_hi
		assign m_out[gi] = !force_mz_b && (is_close_b ? close_m[gi] : far_m[gi]);
	end
	endgenerate
	assign m_out[22] = sp_nan3 || (!force_mz_b && (is_close_b ? close_m[22] : far_m[22]));

	(* keep = "true" *) wire use_close_e = !sp3 && !sz3 && is_close_b && !cudf_lt && !(cudf_eq && cudf_lo);
	wire far_ovf_c0 = ex2_254_3 && far_c_e;
	wire far_udf_c0 = ex2_0_3 || (ex2_1_3 && !far_c_e && !far_norm_e);
	wire far_ovf_c1 = ex2_254_3 && (far_c_e || far_norm_e);
	wire far_udf_c1 = ex2_0_3;

	(* keep = "true" *) wire [7:0] far_e_c0, far_e_c1;
	wire [7:0] e_out;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_eout
		wire fc_e = (gi < 4) ? far_c_d : far_c_e;
		wire fn_e = (gi < 4) ? far_norm_d : far_norm_e;
		wire ebit_c0 = fc_e ? ex2_p1_3[gi] : (fn_e ? ex2_3[gi] : ex2_sub1_3[gi]);
		wire ebit_c1 = (fc_e || fn_e) ? ex2_p1_3[gi] : ex2_3[gi];
		assign far_e_c0[gi] = (sp_nan3 || sp_inf3 || (!sp3 && !sz3 && !is_close_b && far_ovf_c0)) ? 1'b1 :
		                      (sp3 || sz3 || is_close_b || far_udf_c0) ? 1'b0 : ebit_c0;
		assign far_e_c1[gi] = (sp_nan3 || sp_inf3 || (!sp3 && !sz3 && !is_close_b && far_ovf_c1)) ? 1'b1 :
		                      (sp3 || sz3 || is_close_b || far_udf_c1) ? 1'b0 : ebit_c1;
		assign e_out[gi] = use_close_e ? close_e[gi] : (far_m0_cout ? far_e_c1[gi] : far_e_c0[gi]);
	end
	endgenerate

	wire o_valid_comb = rst_n && v3;
	wire [31:0] o_r_comb = {sx3 && !sz3, e_out, m_out};

	wire unused_bits = &{1'b0, shr_0[26:8], shr_0[0], shr_1[26:15], shr_1[7:0], shr_2[14:0],
		nl[24], nl[0], close_e_bo_unused, dba_bo_unused,
		close_sub_bo_unused, sum_co_unused, ex2_p1_co_unused, ex2_sub1_bo_unused,
		cmp_diff_unused[0], cmp_diff_unused[1], cmp_diff_unused[2], cmp_diff_unused[3]};

	generate
		if (LAT == 0) begin : g_lat0
			assign v1 = i_valid;
			assign sp1 = sp1_w;
			assign sp_nan1 = sp_nan1_w;
			assign sp_inf1 = sp_inf1_w;
			assign sx1 = sx1_w;
			assign sub1_a = sub1_w;
			assign sub1_b = sub1_w;
			assign y_zero1_a = y_zero1_w;
			assign y_zero1_b = y_zero1_w;
			assign ealtb1 = ealtb1_w;
			assign dab_hi1 = dab_hi1_w;
			assign dba_hi1 = dba_hi1_w;
			assign close_cand1 = cc_en1_w && (ealtb1_w ? (!dba_hi1_w && dba_cc1_w) : (!dab_hi1_w && dab_cc1_w));
			assign ex1 = ex1_w;
			assign mx1 = mx1_w;
			assign my1 = my1_w;
			assign d1_a = d1_w;
			assign d1_b = d1_w;
			assign d1_c = d1_w;
			assign d1_d = d1_w;
			assign d1_e0 = d1_w[0];
			assign d1_f0 = d1_w[0];

			assign v2 = v1;
			assign sp2 = sp2_w;
			assign sp_nan2 = sp_nan2_w;
			assign sp_inf2 = sp_inf2_w;
			assign sx2 = sx2_w;
			assign sub2 = sub2_w;
			assign close_cand2 = close_cand2_w;
			assign ex2 = ex2_w;
			assign ex2_p1 = ex2_p1_w;
			assign ex2_sub1 = ex2_sub1_w;
			assign px2 = px2_w;
			assign py2 = py2_w;
			assign close_diff2 = close_diff2_w;

			assign v3 = v2;
			assign sp3 = sp3_w;
			assign sp_nan3 = sp_nan3_w;
			assign sp_inf3 = sp_inf3_w;
			assign sx3 = sx3_w;
			assign sz3 = sz3_w;
			assign is_close_a = is_close3_w;
			assign is_close_b = is_close3_w;
			assign far_c_a = sum[27];
			assign far_c_b = sum[27];
			assign far_c_c = sum[27];
			assign far_c_d = sum[27];
			assign far_c_e = sum[27];
			assign far_norm_a = sum[26];
			assign far_norm_b = sum[26];
			assign far_norm_c = sum[26];
			assign far_norm_d = sum[26];
			assign far_norm_e = sum[26];
			assign sum3 = sum[26:6];
			assign fmu_c3 = fmu_c_w;
			assign fmu_n3 = fmu_n_w;
			assign fmu_u3 = fmu_u_w;
			assign cin6_c3 = cin6_c_w;
			assign cin6_n3 = cin6_n_w;
			assign cin6_u3 = cin6_u_w;
			assign p6_3 = p6_w;
			assign p12_3 = p12_w;
			assign p18_3 = p18_w;
			assign p24_3 = p24_w;
			assign close_diff3 = close_diff3_w;
			assign lz3_a = lz;
			assign lz3_b = lz;
			assign ex2_3 = ex2_3_w;
			assign ex2_p1_3 = ex2_p1_3_w;
			assign ex2_sub1_3 = ex2_sub1_3_w;
			assign ex2_le31_3 = ex2_le31_w;
			assign ex2_0_3 = ex2_0_w;
			assign ex2_1_3 = ex2_1_w;
			assign ex2_254_3 = ex2_254_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w, v2_w, v3_w, unused_bits};
		end else begin : g_lat4
			(* keep = "true" *) reg r_v1, r_sp1, r_sp_nan1, r_sp_inf1, r_sx_norm1, r_sp_sx1;
			(* keep = "true" *) reg r_ealtb1, r_dab_hi1, r_dba_hi1, r_dab_cc1, r_dba_cc1, r_cc_en1;
			(* keep = "true" *) reg r_y_zero1_a, r_y_zero1_b;
			(* keep = "true" *) reg r_sub1_a, r_sub1_b;
			(* extract_enable = "no", extract_reset = "no" *) reg [7:0] r_ex1;
			(* keep = "true", extract_reset = "no" *) reg [4:0] r_d1_a, r_d1_b, r_d1_c, r_d1_d;
			(* keep = "true" *) reg r_d1_e0, r_d1_f0;
			(* extract_enable = "no", extract_reset = "no" *) reg [23:0] r_mx1, r_my1;

			always @(posedge clk) begin
				r_v1 <= v1_w;
				r_sp1 <= sp1_w;
				r_sp_nan1 <= sp_nan1_w;
				r_sp_inf1 <= sp_inf1_w;
				r_sx_norm1 <= sx_norm1_w;
				r_sp_sx1 <= sp_sx1_w;
				r_sub1_a <= sub1_w;
				r_sub1_b <= sub1_w;
				r_y_zero1_a <= y_zero1_w;
				r_y_zero1_b <= y_zero1_w;
				r_ealtb1 <= ealtb1_w;
				r_dab_hi1 <= dab_hi1_w;
				r_dba_hi1 <= dba_hi1_w;
				r_dab_cc1 <= dab_cc1_w;
				r_dba_cc1 <= dba_cc1_w;
				r_cc_en1 <= cc_en1_w;
				r_ex1 <= ex1_w;
				r_mx1 <= mx1_w;
				r_my1 <= my1_w;
				r_d1_a <= d1_w;
				r_d1_b <= d1_w;
				r_d1_c <= d1_w;
				r_d1_d <= d1_w;
				r_d1_e0 <= d1_w[0];
				r_d1_f0 <= d1_w[0];
			end

			assign v1 = r_v1;
			assign sp1 = r_sp1;
			assign sp_nan1 = r_sp_nan1;
			assign sp_inf1 = r_sp_inf1;
			assign sx1 = r_sp1 ? r_sp_sx1 : r_sx_norm1;
			assign sub1_a = r_sub1_a;
			assign sub1_b = r_sub1_b;
			assign y_zero1_a = r_y_zero1_a;
			assign y_zero1_b = r_y_zero1_b;
			assign ealtb1 = r_ealtb1;
			assign dab_hi1 = r_dab_hi1;
			assign dba_hi1 = r_dba_hi1;
			assign close_cand1 = r_cc_en1 && (r_ealtb1 ? (!r_dba_hi1 && r_dba_cc1) : (!r_dab_hi1 && r_dab_cc1));
			assign ex1 = r_ex1;
			assign mx1 = r_mx1;
			assign my1 = r_my1;
			assign d1_a = r_d1_a;
			assign d1_b = r_d1_b;
			assign d1_c = r_d1_c;
			assign d1_d = r_d1_d;
			assign d1_e0 = r_d1_e0;
			assign d1_f0 = r_d1_f0;

			reg r_v2, r_sp2, r_sp_nan2, r_sp_inf2, r_sx2, r_sub2, r_close_cand2;
			reg [7:0] r_ex2, r_ex2_p1, r_ex2_sub1;
			reg [26:0] r_px2, r_py2;
			reg [24:0] r_close_diff2;

			always @(posedge clk) begin
				r_v2 <= v2_w;
				r_sp2 <= sp2_w;
				r_sp_nan2 <= sp_nan2_w;
				r_sp_inf2 <= sp_inf2_w;
				r_sx2 <= sx2_w;
				r_sub2 <= sub2_w;
				r_close_cand2 <= close_cand2_w;
				r_ex2 <= ex2_w;
				r_ex2_p1 <= ex2_p1_w;
				r_ex2_sub1 <= ex2_sub1_w;
				r_px2 <= px2_w;
				r_py2 <= py2_w;
				r_close_diff2 <= close_diff2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign sp_nan2 = r_sp_nan2;
			assign sp_inf2 = r_sp_inf2;
			assign sx2 = r_sx2;
			assign sub2 = r_sub2;
			assign close_cand2 = r_close_cand2;
			assign ex2 = r_ex2;
			assign ex2_p1 = r_ex2_p1;
			assign ex2_sub1 = r_ex2_sub1;
			assign px2 = r_px2;
			assign py2 = r_py2;
			assign close_diff2 = r_close_diff2;

			reg r_v3, r_sp3, r_sp_nan3, r_sp_inf3, r_sx3, r_sz3;
			(* keep = "true" *) reg r_is_close_a, r_is_close_b;
			(* keep = "true" *) reg r_far_c_a, r_far_c_b, r_far_c_c, r_far_c_d, r_far_c_e;
			(* keep = "true" *) reg r_far_norm_a, r_far_norm_b, r_far_norm_c, r_far_norm_d, r_far_norm_e;
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
			(* keep = "true" *) reg [4:0] r_lz3_a, r_lz3_b;
			reg [7:0] r_ex2_3, r_ex2_p1_3, r_ex2_sub1_3;
			reg r_ex2_le31_3, r_ex2_0_3, r_ex2_1_3, r_ex2_254_3;

			always @(posedge clk) begin
				r_v3          <= v3_w;
				r_sp3         <= sp3_w;
				r_sp_nan3     <= sp_nan3_w;
				r_sp_inf3     <= sp_inf3_w;
				r_sx3         <= sx3_w;
				r_sz3         <= sz3_w;
				r_is_close_a  <= is_close3_w;
				r_is_close_b  <= is_close3_w;
				r_far_c_a     <= sum[27];
				r_far_c_b     <= sum[27];
				r_far_c_c     <= sum[27];
				r_far_c_d     <= sum[27];
				r_far_c_e     <= sum[27];
				r_far_norm_a  <= sum[26];
				r_far_norm_b  <= sum[26];
				r_far_norm_c  <= sum[26];
				r_far_norm_d  <= sum[26];
				r_far_norm_e  <= sum[26];
				r_sum3        <= sum[26:6];
				r_fmu_c3      <= fmu_c_w;
				r_fmu_n3      <= fmu_n_w;
				r_fmu_u3      <= fmu_u_w;
				r_cin6_c3     <= cin6_c_w;
				r_cin6_n3     <= cin6_n_w;
				r_cin6_u3     <= cin6_u_w;
				r_p6_3        <= p6_w;
				r_p12_3       <= p12_w;
				r_p18_3       <= p18_w;
				r_p24_3       <= p24_w;
				r_close_diff3 <= close_diff3_w;
				r_lz3_a       <= lz;
				r_lz3_b       <= lz;
				r_ex2_3       <= ex2_3_w;
				r_ex2_p1_3    <= ex2_p1_3_w;
				r_ex2_sub1_3  <= ex2_sub1_3_w;
				r_ex2_le31_3  <= ex2_le31_w;
				r_ex2_0_3     <= ex2_0_w;
				r_ex2_1_3     <= ex2_1_w;
				r_ex2_254_3   <= ex2_254_w;
			end

			assign v3          = r_v3;
			assign sp3         = r_sp3;
			assign sp_nan3     = r_sp_nan3;
			assign sp_inf3     = r_sp_inf3;
			assign sx3         = r_sx3;
			assign sz3         = r_sz3;
			assign is_close_a  = r_is_close_a;
			assign is_close_b  = r_is_close_b;
			assign far_c_a     = r_far_c_a;
			assign far_c_b     = r_far_c_b;
			assign far_c_c     = r_far_c_c;
			assign far_c_d     = r_far_c_d;
			assign far_c_e     = r_far_c_e;
			assign far_norm_a  = r_far_norm_a;
			assign far_norm_b  = r_far_norm_b;
			assign far_norm_c  = r_far_norm_c;
			assign far_norm_d  = r_far_norm_d;
			assign far_norm_e  = r_far_norm_e;
			assign sum3        = r_sum3;
			assign fmu_c3      = r_fmu_c3;
			assign fmu_n3      = r_fmu_n3;
			assign fmu_u3      = r_fmu_u3;
			assign cin6_c3     = r_cin6_c3;
			assign cin6_n3     = r_cin6_n3;
			assign cin6_u3     = r_cin6_u3;
			assign p6_3        = r_p6_3;
			assign p12_3       = r_p12_3;
			assign p18_3       = r_p18_3;
			assign p24_3       = r_p24_3;
			assign close_diff3 = r_close_diff3;
			assign lz3_a       = r_lz3_a;
			assign lz3_b       = r_lz3_b;
			assign ex2_3       = r_ex2_3;
			assign ex2_p1_3    = r_ex2_p1_3;
			assign ex2_sub1_3  = r_ex2_sub1_3;
			assign ex2_le31_3  = r_ex2_le31_3;
			assign ex2_0_3     = r_ex2_0_3;
			assign ex2_1_3     = r_ex2_1_3;
			assign ex2_254_3   = r_ex2_254_3;

			reg r_ovalid;
			(* extract_reset = "no" *) reg [31:0] r_or;

			always @(posedge clk) begin
				r_ovalid <= o_valid_comb;
				r_or     <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r     = r_or;

			wire unused_lat4 = &{1'b0, unused_bits};
		end
	endgenerate
endmodule

`default_nettype wire
