/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_f2fix: backward compatibility wrapper around am_fp_f2fix
 * with W=24, F=8, SIGNED=1, ROUND=1, SATURATE=1, SAT_BITS=22, plus
 * 5nm 1.5 GHz pipelined float<->fixed conversion engines:
 *   - atg_rx_f2fix_pipe (LAT = 6)
 *   - atg_rx_fix2f_pipe (LAT = 5)
 * See rtl/library/fp/am_fp_f2fix.v and rtl/library/fp/am_fp_fix2f.v.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_f2fix (
	input wire [31:0] f,
	output wire [23:0] q
);
	localparam [7:0] E_BASE = 8'd142;
	localparam [7:0] E_MIN  = 8'd118;

	(* keep = "true" *) wire [31:0] f_0 = f;
	(* keep = "true" *) wire [31:0] f_1 = f;
	(* keep = "true" *) wire [31:0] f_2 = f;

	wire sign_l = f_0[31];
	wire sign_h = f_1[31];

	wire [7:0] exp0 = f_0[30:23];
	wire [7:0] exp1 = f_1[30:23];
	wire [7:0] exp2 = f_2[30:23];

	wire is_nan = (&exp2) && (|f_2[22:0]);
	wire is_zero = ~|exp2;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire is_nan_l, is_nan_h;
	LUT1 #(.INIT(2'h2)) u_nan_l (.I0(is_nan), .O(is_nan_l));
	LUT1 #(.INIT(2'h2)) u_nan_h (.I0(is_nan), .O(is_nan_h));
`else
	wire is_nan_l = is_nan;
	wire is_nan_h = is_nan;
`endif

	(* keep = "true" *) wire [7:0] sh_w0;
	(* keep = "true" *) wire [7:0] sh_w1;
	(* keep = "true" *) wire [7:0] sh_w2;
	wire bo_s0, bo_s1, bo_s2, bo_udf_w, bo_lt_ebase_w;

	am_sub #(.W(8)) u_s0 (.a(E_BASE), .b(exp0), .bi(1'b0), .d(sh_w0), .bo(bo_s0));
	am_sub #(.W(8)) u_s1 (.a(E_BASE), .b(exp1), .bi(1'b0), .d(sh_w1), .bo(bo_s1));
	am_sub #(.W(8)) u_s2 (.a(E_BASE), .b(exp2), .bi(1'b0), .d(sh_w2), .bo(bo_s2));
	am_sub #(.W(8)) u_uf (.a(exp2),   .b(E_MIN),  .bi(1'b0), .d(),      .bo(bo_udf_w));
	am_sub #(.W(8)) u_ov (.a(exp2),   .b(E_BASE), .bi(1'b0), .d(),      .bo(bo_lt_ebase_w));

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [2:0] sh0_lo_amt, sh0_hi_amt;
	(* keep = "true", dont_touch = "true" *) wire [1:0] sh0_c_amt;
	LUT1 #(.INIT(2'h2)) u_s0_l0 (.I0(sh_w0[0]), .O(sh0_lo_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s0_l1 (.I0(sh_w0[1]), .O(sh0_lo_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s0_l2 (.I0(sh_w0[2]), .O(sh0_lo_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s0_h0 (.I0(sh_w0[0]), .O(sh0_hi_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s0_h1 (.I0(sh_w0[1]), .O(sh0_hi_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s0_h2 (.I0(sh_w0[2]), .O(sh0_hi_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s0_c0 (.I0(sh_w0[3]), .O(sh0_c_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s0_c1 (.I0(sh_w0[4]), .O(sh0_c_amt[1]));

	(* keep = "true", dont_touch = "true" *) wire [2:0] sh1_lo_amt, sh1_hi_amt;
	(* keep = "true", dont_touch = "true" *) wire [1:0] sh1_c_amt;
	LUT1 #(.INIT(2'h2)) u_s1_l0 (.I0(sh_w1[0]), .O(sh1_lo_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s1_l1 (.I0(sh_w1[1]), .O(sh1_lo_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s1_l2 (.I0(sh_w1[2]), .O(sh1_lo_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s1_h0 (.I0(sh_w1[0]), .O(sh1_hi_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s1_h1 (.I0(sh_w1[1]), .O(sh1_hi_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s1_h2 (.I0(sh_w1[2]), .O(sh1_hi_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s1_c0 (.I0(sh_w1[3]), .O(sh1_c_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s1_c1 (.I0(sh_w1[4]), .O(sh1_c_amt[1]));

	(* keep = "true", dont_touch = "true" *) wire [2:0] sh2_lo_amt, sh2_hi_amt;
	(* keep = "true", dont_touch = "true" *) wire [1:0] sh2_c_lo_amt, sh2_c_hi_amt;
	LUT1 #(.INIT(2'h2)) u_s2_l0 (.I0(sh_w2[0]), .O(sh2_lo_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s2_l1 (.I0(sh_w2[1]), .O(sh2_lo_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s2_l2 (.I0(sh_w2[2]), .O(sh2_lo_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s2_h0 (.I0(sh_w2[0]), .O(sh2_hi_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s2_h1 (.I0(sh_w2[1]), .O(sh2_hi_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s2_h2 (.I0(sh_w2[2]), .O(sh2_hi_amt[2]));
	LUT1 #(.INIT(2'h2)) u_s2_cl0 (.I0(sh_w2[3]), .O(sh2_c_lo_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s2_cl1 (.I0(sh_w2[4]), .O(sh2_c_lo_amt[1]));
	LUT1 #(.INIT(2'h2)) u_s2_ch0 (.I0(sh_w2[3]), .O(sh2_c_hi_amt[0]));
	LUT1 #(.INIT(2'h2)) u_s2_ch1 (.I0(sh_w2[4]), .O(sh2_c_hi_amt[1]));
`else
	wire [2:0] sh0_lo_amt = sh_w0[2:0];
	wire [2:0] sh0_hi_amt = sh_w0[2:0];
	wire [1:0] sh0_c_amt  = sh_w0[4:3];

	wire [2:0] sh1_lo_amt = sh_w1[2:0];
	wire [2:0] sh1_hi_amt = sh_w1[2:0];
	wire [1:0] sh1_c_amt  = sh_w1[4:3];

	wire [2:0] sh2_lo_amt = sh_w2[2:0];
	wire [2:0] sh2_hi_amt = sh_w2[2:0];
	wire [1:0] sh2_c_lo_amt = sh_w2[4:3];
	wire [1:0] sh2_c_hi_amt = sh_w2[4:3];
`endif

	wire [47:0] in_data0 = {1'b1, f_0[22:0], 24'd0};
	wire [47:0] in_data1 = {1'b1, f_1[22:0], 24'd0};
	wire [47:0] in_data2 = {1'b1, f_2[22:0], 24'd0};

	wire [31:0] s_coarse;
	assign s_coarse[15:0]  = (sh_w0[7:5] != 3'd0) ? 16'd0 :
	                         (sh0_c_amt == 2'd0)  ? in_data0[15:0] :
	                         (sh0_c_amt == 2'd1)  ? in_data0[23:8] :
	                         (sh0_c_amt == 2'd2)  ? in_data0[31:16] : in_data0[39:24];

	assign s_coarse[31:16] = (sh_w1[7:5] != 3'd0) ? 16'd0 :
	                         (sh1_c_amt == 2'd0)  ? in_data1[31:16] :
	                         (sh1_c_amt == 2'd1)  ? in_data1[39:24] :
	                         (sh1_c_amt == 2'd2)  ? in_data1[47:32] : {8'd0, in_data1[47:40]};

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire sh_w2_nz_lo, sh_w2_nz_hi0, sh_w2_nz_hi1;
	LUT3 #(.INIT(8'hFE)) u_w2nz_l  (.I0(sh_w2[5]), .I1(sh_w2[6]), .I2(sh_w2[7]), .O(sh_w2_nz_lo));
	LUT3 #(.INIT(8'hFE)) u_w2nz_h0 (.I0(sh_w2[5]), .I1(sh_w2[6]), .I2(sh_w2[7]), .O(sh_w2_nz_hi0));
	LUT3 #(.INIT(8'hFE)) u_w2nz_h1 (.I0(sh_w2[5]), .I1(sh_w2[6]), .I2(sh_w2[7]), .O(sh_w2_nz_hi1));
`else
	wire sh_w2_nz_lo  = (sh_w2[7:5] != 3'd0);
	wire sh_w2_nz_hi0 = (sh_w2[7:5] != 3'd0);
	wire sh_w2_nz_hi1 = (sh_w2[7:5] != 3'd0);
`endif

	wire [15:0] s_coarse2_lo = sh_w2_nz_lo ? 16'd0 :
	                           (sh2_c_lo_amt == 2'd0)  ? in_data2[47:32] :
	                           (sh2_c_lo_amt == 2'd1)  ? {8'd0, in_data2[47:40]} : 16'd0;
	wire [15:0] s_coarse2_hi;
	assign s_coarse2_hi[7:0]  = sh_w2_nz_hi0 ? 8'd0 :
	                            (sh2_c_hi_amt == 2'd0)  ? in_data2[39:32] :
	                            (sh2_c_hi_amt == 2'd1)  ? in_data2[47:40] : 8'd0;
	assign s_coarse2_hi[15:8] = sh_w2_nz_hi1 ? 8'd0 :
	                            (sh2_c_hi_amt == 2'd0)  ? in_data2[47:40] : 8'd0;

	wire [38:0] c_pad = {7'd0, s_coarse};
	wire [22:0] c_pad2_lo = {7'd0, s_coarse2_lo};
	wire [22:0] c_pad2_hi = {7'd0, s_coarse2_hi};
	wire [47:0] shifted;

	wire [15:0] f0_lo = sh0_lo_amt[1] ?
		(sh0_lo_amt[0] ? c_pad[3 +: 16] : c_pad[2 +: 16]) :
		(sh0_lo_amt[0] ? c_pad[1 +: 16] : c_pad[0 +: 16]);
	wire [15:0] f0_hi = sh0_hi_amt[1] ?
		(sh0_hi_amt[0] ? c_pad[7 +: 16] : c_pad[6 +: 16]) :
		(sh0_hi_amt[0] ? c_pad[5 +: 16] : c_pad[4 +: 16]);
	assign shifted[15:0] = sh0_hi_amt[2] ? f0_hi : f0_lo;

	wire [15:0] f1_lo = sh1_lo_amt[1] ?
		(sh1_lo_amt[0] ? c_pad[16 + 3 +: 16] : c_pad[16 + 2 +: 16]) :
		(sh1_lo_amt[0] ? c_pad[16 + 1 +: 16] : c_pad[16 + 0 +: 16]);
	wire [15:0] f1_hi = sh1_hi_amt[1] ?
		(sh1_hi_amt[0] ? c_pad[16 + 7 +: 16] : c_pad[16 + 6 +: 16]) :
		(sh1_hi_amt[0] ? c_pad[16 + 5 +: 16] : c_pad[16 + 4 +: 16]);
	assign shifted[31:16] = sh1_hi_amt[2] ? f1_hi : f1_lo;

	wire [15:0] f2_lo = sh2_lo_amt[1] ?
		(sh2_lo_amt[0] ? c_pad2_lo[3 +: 16] : c_pad2_lo[2 +: 16]) :
		(sh2_lo_amt[0] ? c_pad2_lo[1 +: 16] : c_pad2_lo[0 +: 16]);
	wire [15:0] f2_hi = sh2_hi_amt[1] ?
		(sh2_hi_amt[0] ? c_pad2_hi[7 +: 16] : c_pad2_hi[6 +: 16]) :
		(sh2_hi_amt[0] ? c_pad2_hi[5 +: 16] : c_pad2_hi[4 +: 16]);
	assign shifted[47:32] = sh2_hi_amt[2] ? f2_hi : f2_lo;

	wire [23:0] unrounded = shifted[47:24];
	wire guard = shifted[23];
	(* keep = "true" *) wire st_0 = |shifted[5:0];
	(* keep = "true" *) wire st_1 = |shifted[11:6];
	(* keep = "true" *) wire st_2 = |shifted[17:12];
	(* keep = "true" *) wire st_3 = |shifted[22:18];
	wire sticky = st_0 || st_1 || st_2 || st_3;
	wire round_up = guard && (sticky || unrounded[0]);

	wire [23:0] rounded_mag;
	wire rnd_carry;
	am_add #(.W(24)) u_rnd (.a(unrounded), .b(24'd0), .ci(round_up), .s(rounded_mag), .co(rnd_carry));

	wire overflow_l_val = is_nan || (!bo_lt_ebase_w) || rnd_carry || (rounded_mag[23:22] != 2'd0);
	wire overflow_h_val = is_nan || (!bo_lt_ebase_w) || rnd_carry || (rounded_mag[23:22] != 2'd0);
	wire underflow_l_val = bo_udf_w || is_zero;
	wire underflow_h_val = bo_udf_w || is_zero;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire ovf_l, ovf_h;
	LUT1 #(.INIT(2'h2)) u_ovf_l (.I0(overflow_l_val), .O(ovf_l));
	LUT1 #(.INIT(2'h2)) u_ovf_h (.I0(overflow_h_val), .O(ovf_h));
	(* keep = "true", dont_touch = "true" *) wire udf_l, udf_h;
	LUT1 #(.INIT(2'h2)) u_udf_l (.I0(underflow_l_val), .O(udf_l));
	LUT1 #(.INIT(2'h2)) u_udf_h (.I0(underflow_h_val), .O(udf_h));
`else
	wire ovf_l = overflow_l_val;
	wire ovf_h = overflow_h_val;
	wire udf_l = underflow_l_val;
	wire udf_h = underflow_h_val;
`endif

	wire [23:0] pos_val = {
		ovf_h  ? 12'h3FF : (udf_h ? 12'd0 : rounded_mag[23:12]),
		ovf_l  ? 12'hFFF : (udf_l ? 12'd0 : rounded_mag[11:0])
	};
	wire [23:0] neg_val;
	am_sub #(.W(24)) u_neg (.a(24'd0), .b(pos_val), .bi(1'b0), .d(neg_val), .bo());

	assign q = {
		is_nan_h ? 12'd0 : (sign_h ? neg_val[23:12] : pos_val[23:12]),
		is_nan_l ? 12'd0 : (sign_l ? neg_val[11:0]  : pos_val[11:0])
	};
endmodule

/*
 * atg_rx_f2fix_pipe: 6-stage pipelined IEEE-754 fp32 -> signed 24-bit Q15.8
 * fixed-point converter with RNE rounding and 22-bit magnitude saturation.
 * Strictly <= 2 LUT6 levels per stage, 0 Pre-CARRY4 LUTs, <= 1 Post-CARRY4 LUT,
 * and fanout <= 16 on all internal nets.
 */
(* keep_hierarchy = "yes" *) module atg_rx_f2fix_pipe (
	input wire clk,
	input wire [31:0] i_f,
	output reg [23:0] o_q
);
	localparam [7:0] E_BASE = 8'd142;	/* 127 + 24 - 1 - 8 */
	localparam [7:0] E_MIN  = 8'd118;	/* 127 - 8 - 1 */

	/* Stage 1: Exponent subtractors & NaN/Zero/Underflow/Overflow flags */
	wire [7:0] sh_w, uf_unused, ov_unused;
	wire bo_s_unused, bo_udf_w, bo_lt_ebase_w;
	am_sub #(.W(8)) u_s  (.a(E_BASE),      .b(i_f[30:23]), .bi(1'b0), .d(sh_w),      .bo(bo_s_unused));
	am_sub #(.W(8)) u_uf (.a(i_f[30:23]),  .b(E_MIN),      .bi(1'b0), .d(uf_unused), .bo(bo_udf_w));
	am_sub #(.W(8)) u_ov (.a(i_f[30:23]),  .b(E_BASE),     .bi(1'b0), .d(ov_unused), .bo(bo_lt_ebase_w));

	(* keep = "true" *) wire m_nz0 = |i_f[5:0];
	(* keep = "true" *) wire m_nz1 = |i_f[11:6];
	(* keep = "true" *) wire m_nz2 = |i_f[17:12];
	(* keep = "true" *) wire m_nz3 = |i_f[22:18];
	(* keep = "true" *) wire e_ff0 = &i_f[30:27];
	(* keep = "true" *) wire e_ff1 = &i_f[26:23];
	(* keep = "true" *) wire e_z0  = ~|i_f[30:27];
	(* keep = "true" *) wire e_z1  = ~|i_f[26:23];

	(* dont_touch = "true", extract_reset = "no" *) reg [1:0] r_sh1_hi [0:2];
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_sh1_lo [0:2];
	(* extract_reset = "no" *) reg [22:0] r_mant1;
	(* extract_reset = "no" *) reg r_sign1, r_bo_udf1, r_bo_lt_eb1, r_eff1, r_ez1, r_mnz1;

	always @(posedge clk) begin
		r_sh1_hi[0] <= sh_w[4:3];
		r_sh1_hi[1] <= sh_w[4:3];
		r_sh1_hi[2] <= sh_w[4:3];
		r_sh1_lo[0] <= sh_w[2:0];
		r_sh1_lo[1] <= sh_w[2:0];
		r_sh1_lo[2] <= sh_w[2:0];
		r_mant1     <= i_f[22:0];
		r_sign1     <= i_f[31];
		r_bo_udf1   <= bo_udf_w;
		r_bo_lt_eb1 <= bo_lt_ebase_w;
		r_eff1      <= e_ff0 && e_ff1;
		r_ez1       <= e_z0 && e_z1;
		r_mnz1      <= m_nz0 || m_nz1 || m_nz2 || m_nz3;
	end

	/* Stage 2: Coarse right shift by {r_sh1_hi, 3'b000} (0, 8, 16, 24) - 1 LUT6 level */
	wire [47:0] in_s2 = {1'b1, r_mant1, 24'd0};
	wire [47:0] c2_w;
	genvar gi;
	generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : g_c2
		wire [1:0] sel = r_sh1_hi[gi];
		wire [15:0] s0 = in_s2[16 * gi +: 16];
		wire [15:0] s1 = (16 * gi + 8  < 48) ? ((16 * gi + 23 < 48) ? in_s2[16 * gi + 8  +: 16] : {8'd0,  in_s2[47 : 16 * gi + 8]})  : 16'd0;
		wire [15:0] s2 = (16 * gi + 16 < 48) ? ((16 * gi + 31 < 48) ? in_s2[16 * gi + 16 +: 16] : {16'd0, in_s2[47 : 16 * gi + 16]}) : 16'd0;
		wire [15:0] s3 = (16 * gi + 24 < 48) ? {8'd0, in_s2[47 : 16 * gi + 24]} : 16'd0;
		assign c2_w[16 * gi +: 16] = (sel == 2'd0) ? s0 : ((sel == 2'd1) ? s1 : ((sel == 2'd2) ? s2 : s3));
	end
	endgenerate

	(* extract_reset = "no" *) reg [47:0] r_c2;
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_sh2_lo [0:2];
	(* extract_reset = "no" *) reg r_sign2, r_zero2, r_ovf2;
	always @(posedge clk) begin
		r_c2        <= c2_w;
		r_sh2_lo[0] <= r_sh1_lo[0];
		r_sh2_lo[1] <= r_sh1_lo[1];
		r_sh2_lo[2] <= r_sh1_lo[2];
		r_sign2     <= r_sign1;
		r_zero2     <= (r_eff1 && r_mnz1) || r_ez1 || r_bo_udf1;
		r_ovf2      <= !r_bo_lt_eb1;
	end

	/* Stage 3: Fine right shift by r_sh2_lo[2:0] (0..7) - 2 LUT6 levels */
	wire [54:0] c2_pad = {7'd0, r_c2};
	wire [47:0] sh3_w;
	generate
	for (gi = 0; gi < 3; gi = gi + 1) begin : g_f3
		wire [2:0] sel = r_sh2_lo[gi];
		(* keep = "true" *) wire [15:0] m_lo = sel[1] ?
			(sel[0] ? c2_pad[16 * gi + 3 +: 16] : c2_pad[16 * gi + 2 +: 16]) :
			(sel[0] ? c2_pad[16 * gi + 1 +: 16] : c2_pad[16 * gi + 0 +: 16]);
		(* keep = "true" *) wire [15:0] m_hi = sel[1] ?
			(sel[0] ? c2_pad[16 * gi + 7 +: 16] : c2_pad[16 * gi + 6 +: 16]) :
			(sel[0] ? c2_pad[16 * gi + 5 +: 16] : c2_pad[16 * gi + 4 +: 16]);
		assign sh3_w[16 * gi +: 16] = sel[2] ? m_hi : m_lo;
	end
	endgenerate

	(* extract_reset = "no" *) reg [47:0] r_sh3;
	(* extract_reset = "no" *) reg r_sign3, r_zero3, r_ovf3;
	always @(posedge clk) begin
		r_sh3   <= sh3_w;
		r_sign3 <= r_sign2;
		r_zero3 <= r_zero2;
		r_ovf3  <= r_ovf2;
	end

	/* Stage 4: Guard / Sticky / Round-up evaluation (2 LUT6 levels, 0 CARRY4s) */
	(* keep = "true" *) wire st_0 = |r_sh3[5:0];
	(* keep = "true" *) wire st_1 = |r_sh3[11:6];
	(* keep = "true" *) wire st_2 = |r_sh3[17:12];
	(* keep = "true" *) wire st_3 = |r_sh3[22:18];
	wire round_up_w = r_sh3[23] && (r_sh3[24] || st_0 || st_1 || st_2 || st_3);

	(* extract_reset = "no" *) reg [23:0] r_unrnd4;
	(* extract_reset = "no" *) reg r_rup4, r_sign4, r_zero4, r_ovf4;
	always @(posedge clk) begin
		r_unrnd4 <= r_sh3[47:24];
		r_rup4   <= round_up_w;
		r_sign4  <= r_sign3;
		r_zero4  <= r_zero3;
		r_ovf4   <= r_ovf3;
	end

	/* Stage 5: Rounding increment (am_add W=24, 0 Pre-CARRY4 LUTs, <= 1 Post-CARRY4 LUT) */
	wire [23:0] rnd_w;
	wire rnd_co_unused;
	am_add #(.W(24)) u_rnd (.a(r_unrnd4), .b(24'd0), .ci(r_rup4), .s(rnd_w), .co(rnd_co_unused));

	(* extract_reset = "no" *) reg [23:0] r_rnd5;
	(* dont_touch = "true", extract_reset = "no" *) reg r_sign5_add, r_sign5_lo, r_sign5_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_zero5_lo, r_zero5_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_ovf5_lo, r_ovf5_hi;
	wire ovf5_w = r_ovf4 || rnd_w[23] || rnd_w[22];

	always @(posedge clk) begin
		r_rnd5      <= rnd_w;
		r_sign5_add <= r_sign4;
		r_sign5_lo  <= r_sign4;
		r_sign5_hi  <= r_sign4;
		r_zero5_lo  <= r_zero4;
		r_zero5_hi  <= r_zero4;
		r_ovf5_lo   <= ovf5_w;
		r_ovf5_hi   <= ovf5_w;
	end

	/* Stage 6: Sign conversion (am_addsub W=24) & Saturation (1 Post-CARRY4 LUT) */
	wire [23:0] sres_w;
	wire sres_co_unused;
	am_addsub #(.W(24)) u_rs (.a(24'd0), .b(r_rnd5), .sub(r_sign5_add), .s(sres_w), .co(sres_co_unused));

	wire [15:0] sat_lo = r_sign5_lo ? 16'h0001 : 16'hFFFF;
	wire [7:0]  sat_hi = r_sign5_hi ? 8'hC0    : 8'h3F;

	always @(posedge clk) begin
		o_q[15:0]  <= r_zero5_lo ? 16'd0 : (r_ovf5_lo ? sat_lo : sres_w[15:0]);
		o_q[23:16] <= r_zero5_hi ? 8'd0  : (r_ovf5_hi ? sat_hi : sres_w[23:16]);
	end

	wire unused_ok = &{1'b0, bo_s_unused, uf_unused, ov_unused, rnd_co_unused, sres_co_unused};
endmodule

/*
 * atg_rx_fix2f_pipe: 5-stage pipelined W-bit fixed-point -> IEEE-754 fp32 converter.
 * Strictly <= 3 LUT6 levels per stage, 0 Pre-CARRY4 LUTs, 0 Post-CARRY4 LUTs,
 * and fanout <= 16 on all internal nets.
 */
(* keep_hierarchy = "yes" *) module atg_rx_fix2f_pipe #(
	parameter W = 17,
	parameter F = 0,
	parameter SIGNED = 1
) (
	input wire clk,
	input wire [W-1:0] i_v,
	output reg [31:0] o_f
);
	localparam [7:0] E0 = 127 + W - 1 - F;
	localparam integer PAD = 24 - W;

	/* Stage 1: Absolute value (am_addsub W=W, 0 Pre-CARRY4 LUTs, 0 Post-CARRY4 LUTs) */
	wire sign_w = (SIGNED != 0) ? i_v[W-1] : 1'b0;
	wire [W-1:0] m_w;
	wire m_co_unused;
	generate
	if (SIGNED != 0) begin : g_signed
		am_addsub #(.W(W)) u_m (.a({W{1'b0}}), .b(i_v), .sub(sign_w), .s(m_w), .co(m_co_unused));
	end else begin : g_unsigned
		assign m_w = i_v;
		assign m_co_unused = 1'b0;
	end
	endgenerate

	wire [23:0] m24_w;
	generate
	if (PAD > 0) begin : g_pad
		assign m24_w = {m_w, {PAD{1'b0}}};
	end else begin : g_nopad
		assign m24_w = m_w[23:0];
	end
	endgenerate

	(* extract_reset = "no" *) reg [23:0] r_m1;
	(* extract_reset = "no" *) reg r_sign1;
	always @(posedge clk) begin
		r_m1    <= m24_w;
		r_sign1 <= sign_w;
	end

	/* Stage 2: 24-bit Leading-Zero Count in four 6-bit chunks (3 LUT6 levels, 0 CARRY4s) */
	function [2:0] lzc6;
		input [5:0] x;
		begin
			lzc6 = x[5] ? 3'd0 : x[4] ? 3'd1 : x[3] ? 3'd2 :
				x[2] ? 3'd3 : x[1] ? 3'd4 : 3'd5;
		end
	endfunction

	(* keep = "true" *) wire v3 = |r_m1[23:18];
	(* keep = "true" *) wire v2 = |r_m1[17:12];
	(* keep = "true" *) wire v1 = |r_m1[11:6];
	(* keep = "true" *) wire v0 = |r_m1[5:0];
	(* keep = "true" *) wire [2:0] p3 = lzc6(r_m1[23:18]);
	(* keep = "true" *) wire [2:0] p2 = lzc6(r_m1[17:12]);
	(* keep = "true" *) wire [2:0] p1 = lzc6(r_m1[11:6]);
	(* keep = "true" *) wire [2:0] p0 = lzc6(r_m1[5:0]);

	wire [4:0] lz_c3 = {2'b00, p3};
	wire [4:0] lz_c2 = (p2 == 3'd0) ? 5'd6  : (p2 == 3'd1) ? 5'd7  : (p2 == 3'd2) ? 5'd8  : (p2 == 3'd3) ? 5'd9  : (p2 == 3'd4) ? 5'd10 : 5'd11;
	wire [4:0] lz_c1 = (p1 == 3'd0) ? 5'd12 : (p1 == 3'd1) ? 5'd13 : (p1 == 3'd2) ? 5'd14 : (p1 == 3'd3) ? 5'd15 : (p1 == 3'd4) ? 5'd16 : 5'd17;
	wire [4:0] lz_c0 = (p0 == 3'd0) ? 5'd18 : (p0 == 3'd1) ? 5'd19 : (p0 == 3'd2) ? 5'd20 : (p0 == 3'd3) ? 5'd21 : (p0 == 3'd4) ? 5'd22 : 5'd23;
	wire [4:0] lz_w  = v3 ? lz_c3 : (v2 ? lz_c2 : (v1 ? lz_c1 : (v0 ? lz_c0 : 5'd0)));

	(* extract_reset = "no" *) reg [23:0] r_m2;
	(* dont_touch = "true", extract_reset = "no" *) reg [4:0] r_lz2_e;
	(* dont_touch = "true", extract_reset = "no" *) reg [1:0] r_lz2_hi_a, r_lz2_hi_b;
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_lz2_lo;
	(* extract_reset = "no" *) reg r_sign2, r_zero2;

	always @(posedge clk) begin
		r_m2       <= r_m1;
		r_lz2_e    <= lz_w;
		r_lz2_hi_a <= lz_w[4:3];
		r_lz2_hi_b <= lz_w[4:3];
		r_lz2_lo   <= lz_w[2:0];
		r_sign2    <= r_sign1;
		r_zero2    <= !(v3 || v2 || v1 || v0);
	end

	/* Stage 3: Exponent E0 - r_lz2_e (am_sub W=8) & Coarse left shift by {r_lz2_hi, 3'b000} (1 LUT6) */
	wire [7:0] e_w;
	wire e_bo_unused;
	am_sub #(.W(8)) u_e (.a(E0), .b({3'd0, r_lz2_e}), .bi(1'b0), .d(e_w), .bo(e_bo_unused));

	wire [23:0] c3_lo = (r_lz2_hi_a == 2'd0) ? r_m2 :
		((r_lz2_hi_a == 2'd1) ? {r_m2[15:0], 8'd0} :
		((r_lz2_hi_a == 2'd2) ? {r_m2[7:0], 16'd0} : 24'd0));
	wire [23:0] c3_hi = (r_lz2_hi_b == 2'd0) ? r_m2 :
		((r_lz2_hi_b == 2'd1) ? {r_m2[15:0], 8'd0} :
		((r_lz2_hi_b == 2'd2) ? {r_m2[7:0], 16'd0} : 24'd0));

	(* extract_reset = "no" *) reg [23:0] r_c3;
	(* extract_reset = "no" *) reg [7:0] r_e3;
	(* dont_touch = "true", extract_reset = "no" *) reg [2:0] r_lz3_lo_a, r_lz3_lo_b, r_lz3_lo_c, r_lz3_lo_d;
	(* extract_reset = "no" *) reg r_sign3, r_zero3;

	always @(posedge clk) begin
		r_c3[11:0]  <= c3_lo[11:0];
		r_c3[23:12] <= c3_hi[23:12];
		r_e3        <= e_w;
		r_lz3_lo_a  <= r_lz2_lo;
		r_lz3_lo_b  <= r_lz2_lo;
		r_lz3_lo_c  <= r_lz2_lo;
		r_lz3_lo_d  <= r_lz2_lo;
		r_sign3     <= r_sign2;
		r_zero3     <= r_zero2;
	end

	/* Stage 4: Fine left shift by r_lz3_lo (0..7) - 2 LUT6 levels, fanout <= 12 */
	wire [30:0] c3_pad = {r_c3, 7'd0};
	wire [22:0] mn4_w;
	genvar gb;
	generate
	for (gb = 0; gb < 6; gb = gb + 1) begin : g_mn_0
		(* keep = "true" *) wire m0 = r_lz3_lo_a[1] ?
			(r_lz3_lo_a[0] ? c3_pad[gb + 7 - 3] : c3_pad[gb + 7 - 2]) :
			(r_lz3_lo_a[0] ? c3_pad[gb + 7 - 1] : c3_pad[gb + 7 - 0]);
		(* keep = "true" *) wire m1 = r_lz3_lo_a[1] ?
			(r_lz3_lo_a[0] ? c3_pad[gb + 7 - 7] : c3_pad[gb + 7 - 6]) :
			(r_lz3_lo_a[0] ? c3_pad[gb + 7 - 5] : c3_pad[gb + 7 - 4]);
		assign mn4_w[gb] = r_lz3_lo_a[2] ? m1 : m0;
	end
	for (gb = 6; gb < 12; gb = gb + 1) begin : g_mn_1
		(* keep = "true" *) wire m0 = r_lz3_lo_b[1] ?
			(r_lz3_lo_b[0] ? c3_pad[gb + 7 - 3] : c3_pad[gb + 7 - 2]) :
			(r_lz3_lo_b[0] ? c3_pad[gb + 7 - 1] : c3_pad[gb + 7 - 0]);
		(* keep = "true" *) wire m1 = r_lz3_lo_b[1] ?
			(r_lz3_lo_b[0] ? c3_pad[gb + 7 - 7] : c3_pad[gb + 7 - 6]) :
			(r_lz3_lo_b[0] ? c3_pad[gb + 7 - 5] : c3_pad[gb + 7 - 4]);
		assign mn4_w[gb] = r_lz3_lo_b[2] ? m1 : m0;
	end
	for (gb = 12; gb < 18; gb = gb + 1) begin : g_mn_2
		(* keep = "true" *) wire m0 = r_lz3_lo_c[1] ?
			(r_lz3_lo_c[0] ? c3_pad[gb + 7 - 3] : c3_pad[gb + 7 - 2]) :
			(r_lz3_lo_c[0] ? c3_pad[gb + 7 - 1] : c3_pad[gb + 7 - 0]);
		(* keep = "true" *) wire m1 = r_lz3_lo_c[1] ?
			(r_lz3_lo_c[0] ? c3_pad[gb + 7 - 7] : c3_pad[gb + 7 - 6]) :
			(r_lz3_lo_c[0] ? c3_pad[gb + 7 - 5] : c3_pad[gb + 7 - 4]);
		assign mn4_w[gb] = r_lz3_lo_c[2] ? m1 : m0;
	end
	for (gb = 18; gb < 23; gb = gb + 1) begin : g_mn_3
		(* keep = "true" *) wire m0 = r_lz3_lo_d[1] ?
			(r_lz3_lo_d[0] ? c3_pad[gb + 7 - 3] : c3_pad[gb + 7 - 2]) :
			(r_lz3_lo_d[0] ? c3_pad[gb + 7 - 1] : c3_pad[gb + 7 - 0]);
		(* keep = "true" *) wire m1 = r_lz3_lo_d[1] ?
			(r_lz3_lo_d[0] ? c3_pad[gb + 7 - 7] : c3_pad[gb + 7 - 6]) :
			(r_lz3_lo_d[0] ? c3_pad[gb + 7 - 5] : c3_pad[gb + 7 - 4]);
		assign mn4_w[gb] = r_lz3_lo_d[2] ? m1 : m0;
	end
	endgenerate

	(* extract_reset = "no" *) reg [22:0] r_mn4;
	(* extract_reset = "no" *) reg [7:0] r_e4;
	(* extract_reset = "no" *) reg r_sign4;
	(* dont_touch = "true", extract_reset = "no" *) reg r_zero4_lo, r_zero4_hi;

	always @(posedge clk) begin
		r_mn4      <= mn4_w;
		r_e4       <= r_e3;
		r_sign4    <= r_sign3;
		r_zero4_lo <= r_zero3;
		r_zero4_hi <= r_zero3;
	end

	/* Stage 5: Output register pack (1 LUT2 level) */
	always @(posedge clk) begin
		o_f[15:0]  <= r_zero4_lo ? 16'd0 : r_mn4[15:0];
		o_f[31:16] <= r_zero4_hi ? 16'd0 : {r_sign4, r_e4, r_mn4[22:16]};
	end

	wire unused_ok = &{1'b0, m_co_unused, e_bo_unused, c3_lo[23:12], c3_hi[11:0], c3_pad[30]};
endmodule

`default_nettype wire
