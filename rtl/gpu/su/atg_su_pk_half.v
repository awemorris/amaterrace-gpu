/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk_half: one 16-bit half of a lane of atg_su_pk.
 * Supports LAT == 0 (combinational, for unit testbench) and LAT == 6
 * (6-stage physical pipeline with 0 Pre/Post-DSP LUTs and <= 1 Pre/Post-CARRY
 * LUTs for 1.5 GHz ASIC synthesis).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk_half #(
	parameter ARITH = 1,	/* the packed arithmetic (atg_su_pk's PACKED) */
	parameter FP = 1,	/* with ARITH: the float operations here (not PK_SHARED) */
	parameter LAT = 0	/* 0 = combinational, 6 = 6-stage pipeline */
) (
	input wire clk,
	input wire rst_n,
	input wire valid_in,
	input wire ovr_en,
	input wire [15:0] ovr_val,
	input wire [3:0] o,
	input wire [15:0] ha,
	input wire [15:0] hb,
	input wire [15:0] hc,
	input wire [2:0] r,
	input wire sat,
	input wire [31:0] xw,
	output wire [15:0] y
);
`include "atg_su_uop.vh"
`include "atg_su_fp16.vh"

	localparam AR = ARITH != 0;
	localparam FL = ARITH != 0 && FP != 0;

	/* Pure logic 10-bit incrementer (2 LUT6 levels, 0 CARRY4 primitives) */
	function [9:0] inc10;
		input [9:0] a;
		input lo_all1;
		reg [4:0] lo;
		reg [4:0] hi;
		begin
			lo[0] = ~a[0];
			lo[1] = a[1] ^ a[0];
			lo[2] = a[2] ^ (&a[1:0]);
			lo[3] = a[3] ^ (&a[2:0]);
			lo[4] = a[4] ^ (&a[3:0]);
			hi[0] = a[5] ^ lo_all1;
			hi[1] = a[6] ^ (a[5] & lo_all1);
			hi[2] = a[7] ^ ((&a[6:5]) & lo_all1);
			hi[3] = a[8] ^ ((&a[7:5]) & lo_all1);
			hi[4] = a[9] ^ ((&a[8:5]) & lo_all1);
			inc10 = {hi, lo};
		end
	endfunction

	/* Pure logic 5-bit incrementer (1 LUT5 level, 0 CARRY4 primitives) */
	function [4:0] inc5;
		input [4:0] a;
		begin
			inc5[0] = ~a[0];
			inc5[1] = a[1] ^ a[0];
			inc5[2] = a[2] ^ (&a[1:0]);
			inc5[3] = a[3] ^ (&a[2:0]);
			inc5[4] = a[4] ^ (&a[3:0]);
		end
	endfunction

	/* Pure logic 3-bit incrementer (1 LUT3 level, 0 CARRY4 primitives) */
	function [2:0] inc3;
		input [2:0] a;
		begin
			inc3[0] = ~a[0];
			inc3[1] = a[1] ^ a[0];
			inc3[2] = a[2] ^ (&a[1:0]);
		end
	endfunction

	/* Pure logic 4-bit adder with carry-in and carry-out (1 LUT6 level, 0 CARRY4) */
	function [4:0] add4_co;
		input [3:0] x;
		input [3:0] y_in;
		input ci;
		reg c1, c2, c3, c4;
		begin
			c1 = (x[0] & y_in[0]) | ((x[0] ^ y_in[0]) & ci);
			c2 = (x[1] & y_in[1]) | ((x[1] ^ y_in[1]) & c1);
			c3 = (x[2] & y_in[2]) | ((x[2] ^ y_in[2]) & c2);
			c4 = (x[3] & y_in[3]) | ((x[3] ^ y_in[3]) & c3);
			add4_co = {c4, x[3] ^ y_in[3] ^ c3, x[2] ^ y_in[2] ^ c2, x[1] ^ y_in[1] ^ c1, x[0] ^ y_in[0] ^ ci};
		end
	endfunction

	/* 6-input sticky helper: (h3 & |l[2:0]) | (h2 & |l[1:0]) | (h1 & l[0]) (1 LUT6) */
	function st_part6;
		input [2:0] h31;
		input [2:0] l20;
		begin
			st_part6 = (h31[2] && (|l20[2:0])) || (h31[1] && (|l20[1:0])) || (h31[0] && l20[0]);
		end
	endfunction

	/* Pure logic 4-bit two's complement negate (1 LUT4 level, 0 CARRY4) */
	function [3:0] neg4;
		input [3:0] a;
		begin
			neg4[0] = a[0];
			neg4[1] = a[1] ^ a[0];
			neg4[2] = a[2] ^ (|a[1:0]);
			neg4[3] = a[3] ^ (|a[2:0]);
		end
	endfunction

	/* Carry out of bit 1 of (eb_lo[1:0] + msb_nibble(x[3:1])[1:0] + ci) (5 inputs -> 1 LUT5) */
	function nib_c2;
		input [2:0] x31;
		input [1:0] eb10;
		input ci;
		reg m1, m0, c1;
		begin
			m1 = |x31[2:1];
			m0 = x31[2] || (!x31[1] && x31[0]);
			c1 = ci ? (eb10[0] || m0) : (eb10[0] && m0);
			nib_c2 = (eb10[1] && m1) || ((eb10[1] ^ m1) && c1);
		end
	endfunction

	generate
	if (LAT == 0) begin : g_lat0
		wire packh = o == ATG_PK_PACKH[3:0];
		wire is_int = o == ATG_PK_IADD2[3:0] || o == ATG_PK_ISUB2[3:0] || o == ATG_PK_IMUL2[3:0];

		reg [15:0] fy, fz;
		reg fnoc;
		always @(*) begin
			fy = 16'h3C00;
			fz = hb;
			fnoc = 1'b0;
			case (o)
			ATG_PK_FSUB2[3:0]: fz = {!hb[15], hb[14:0]};
			ATG_PK_FMUL2[3:0]: begin
				fy = hb;
				fz = 16'd0;
				fnoc = 1'b1;
			end
			ATG_PK_FFMA2[3:0]: begin
				fy = hb;
				fz = hc;
			end
			default: ;
			endcase
		end

		wire [15:0] fa = atg_su_hflush(ha);
		wire [15:0] fb = atg_su_hflush(fy);
		wire [15:0] fc = atg_su_hflush(fz);
		wire [4:0] ea = fa[14:10];
		wire [4:0] eb = fb[14:10];
		wire [4:0] ec = fc[14:10];
		wire sp = fa[15] ^ fb[15];
		wire sc = fc[15];
		wire rdn = r == 3'd2;
		wire nan_a = ea == 5'h1F && fa[9:0] != 10'd0;
		wire nan_b = eb == 5'h1F && fb[9:0] != 10'd0;
		wire nan_c = !fnoc && ec == 5'h1F && fc[9:0] != 10'd0;
		wire inf_a = ea == 5'h1F && fa[9:0] == 10'd0;
		wire inf_b = eb == 5'h1F && fb[9:0] == 10'd0;
		wire inf_c = !fnoc && ec == 5'h1F && fc[9:0] == 10'd0;
		wire za = ea == 5'd0;
		wire zb = eb == 5'd0;
		wire zc = fnoc || ec == 5'd0;
		wire [10:0] ma = {!za, fa[9:0]};
		wire [10:0] mb = {!zb, fb[9:0]};
		wire [10:0] mc = zc ? 11'd0 : {1'b1, fc[9:0]};

		wire [31:0] prod;
		am_mul #(.AW(16), .BW(16)) u_mul (
			.clk(1'b0), .en(1'b0), .a(is_int ? ha : {5'd0, ma}), .b(is_int ? hb : {5'd0, mb}),
			.p(prod)
		);
		wire [21:0] p = prod[21:0];

		wire [9:0] t;
		wire [9:0] d;
		wire [9:0] kx;
		wire [2:0] co_unused;
		am_add #(.W(10)) u_t (.a({5'd0, ea}), .b({5'd0, eb}), .ci(1'b0), .s(t), .co(co_unused[0]));
		am_sub #(.W(10)) u_d (.a({5'd0, ec}), .b(t), .bi(1'b0), .d(d), .bo(co_unused[1]));
		wire big = $signed(d) >= -10'sd1;
		wire near = $signed(d) >= -10'sd37;
		am_add #(.W(10)) u_k (
			.a(big ? {5'd0, ec} : d), .b(big ? 10'd2 : 10'd37), .ci(1'b0), .s(kx),
			.co(co_unused[2])
		);
		wire [46:0] zal;
		am_shift #(.W(47), .SW(6), .DIR(2)) u_al (
			.a({36'd0, mc}), .amt(kx[5:0]), .left(1'b1), .arith(1'b0), .y(zal)
		);
		wire [36:0] pw = !zc && big ? 37'd1 : {13'd0, p, 2'b00};
		wire [36:0] cw = zc ? 37'd0 : big ? {1'b0, mc, 25'd0} :
			near ? {zal[46:11], zal[10] | (|zal[9:0])} : 37'd1;

		wire eff_sub = !(zc || sp == sc);
		wire swap = eff_sub && pw < cw;
		wire sr = swap ? sc : sp;
		wire [36:0] sum;
		wire sum_co_unused;
		am_addsub #(.W(37)) u_sum (
			.a(is_int ? {21'd0, ha} : swap ? cw : pw), .b(is_int ? {21'd0, hb} : swap ? pw : cw),
			.sub(is_int ? o == ATG_PK_ISUB2[3:0] : eff_sub), .s(sum), .co(sum_co_unused)
		);

		wire [36:0] rev;
		genvar j;
		for (j = 0; j < 37; j = j + 1) begin : g_rev
			assign rev[j] = sum[36 - j];
		end
		reg [5:0] lz;
		integer i;
		always @(*) begin
			lz = 6'd0;
			for (i = 36; i >= 0; i = i - 1)
				if (rev[i])
					lz = i[5:0];
		end
		wire [36:0] nrm;
		am_shift #(.W(37), .SW(6), .DIR(2)) u_nrm (
			.a(sum), .amt(lz), .left(1'b1), .arith(1'b0), .y(nrm)
		);

		wire [31:0] xf = xw[30:23] == 8'd0 ? {xw[31], 31'd0} : xw;

		wire f2h = packh || !FL;
		wire [9:0] er;
		wire er_bo_unused;
		am_sub #(.W(10)) u_er (
			.a(f2h ? {2'd0, xf[30:23]} : !zc && big ? kx : t), .b(f2h ? 10'd112 : {4'd0, lz}),
			.bi(!f2h), .d(er), .bo(er_bo_unused)
		);
		wire [15:0] hr;
		am_fp_hrnd #(.LAT(0)) u_rnd (
			.s(f2h ? xf[31] : sr), .e(er), .m(f2h ? {1'b1, xf[22:13]} : nrm[36:26]),
			.g(f2h ? xf[12] : nrm[25]), .st(f2h ? |xf[11:0] : |nrm[24:0]),
			.rm(f2h ? 3'd0 : r), .h(hr)
		);

		wire [15:0] xh = xf[30:23] == 8'hFF ? (xf[22:0] != 23'd0 ? 16'h7E00 : {xf[31], 5'h1F, 10'd0}) :
			xf[30:23] == 8'd0 ? {xf[31], 15'd0} : hr;

		reg [15:0] fma;
		always @(*) begin
			if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
				fma = 16'h7E00;
			else if (inf_a || inf_b)
				fma = inf_c && sc != sp ? 16'h7E00 : {sp, 5'h1F, 10'd0};
			else if (inf_c)
				fma = fc;
			else if (za || zb)
				fma = !zc ? fc : fnoc ? {sp, 15'd0} : {rdn ? (sp | sc) : (sp & sc), 15'd0};
			else if (sum == 37'd0)
				fma = {rdn, 15'd0};
			else
				fma = hr;
		end

		reg [15:0] ca, cb;
		reg [1:0] cop;
		always @(*) begin
			ca = ha;
			cb = hb;
			case (o)
			ATG_PK_FCMPLT2[3:0]: cop = 2'd1;
			ATG_PK_FCMPGE2[3:0]: begin
				ca = hb;
				cb = ha;
				cop = 2'd2;
			end
			ATG_PK_FCMPEQ2[3:0]: cop = 2'd0;
			default: cop = 2'd3;
			endcase
		end

		reg [15:0] v;
		always @(*)
			case (o)
			ATG_PK_FADD2[3:0], ATG_PK_FSUB2[3:0], ATG_PK_FMUL2[3:0], ATG_PK_FFMA2[3:0]:
				v = FL ? fma : 16'd0;
			ATG_PK_FMIN2[3:0]: v = FL ? atg_su_hminmax(ha, hb, 1'b0) : 16'd0;
			ATG_PK_FMAX2[3:0]: v = FL ? atg_su_hminmax(ha, hb, 1'b1) : 16'd0;
			ATG_PK_IADD2[3:0], ATG_PK_ISUB2[3:0]: v = sum[15:0];
			ATG_PK_IMUL2[3:0]: v = prod[15:0];
			ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
				v = FL ? {16{atg_su_hcmp(ca, cb, cop)}} : 16'd0;
			default: v = 16'd0;
			endcase

		assign y = !valid_in ? 16'd0 : ovr_en ? ovr_val :
			packh ? xh : !AR ? 16'd0 : sat && o <= ATG_PK_FMAX2[3:0] ? atg_su_hsat(v) : v;

		wire unused_ok = &{1'b0, clk, rst_n, prod[31:22], sum[36:16], kx[9:6], er_bo_unused, sum_co_unused,
			co_unused};
	end else if (!AR) begin : g_lat6_noarith
		(* dont_touch = "true" *) wire rst_p = !rst_n;
		(* shreg_extract = "no" *) reg        s1_valid, s2_valid, s3_valid, s4_valid, s5_valid, s6_valid;
		(* shreg_extract = "no" *) reg        s1_ovr_en, s2_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s1_ovr_val, s2_ovr_val;
		(* shreg_extract = "no" *) reg        s1_packh, s2_packh;
		(* shreg_extract = "no" *) reg [31:0] s1_xw, s2_xw;
		(* shreg_extract = "no" *) reg [9:0]  s2_er_p;
		(* shreg_extract = "no" *) reg [15:0] s3_res, s4_res, s5_res, s6_res;

		wire [9:0] s1_er_p;
		wire       s1_erp_bo_unused;
		am_sub #(.W(10)) u_s1_erp (.a({2'd0, s1_xw[30:23]}), .b(10'd112), .bi(1'b0), .d(s1_er_p), .bo(s1_erp_bo_unused));

		wire        s2_p_st    = |s2_xw[11:0];
		wire        s2_p_up    = s2_xw[12] && (s2_p_st || s2_xw[13]);
		wire        s2_p_lo1   = &s2_xw[17:13];
		wire        s2_p_hi1   = &s2_xw[22:18];
		wire        s2_p_carry = s2_p_lo1 && s2_p_hi1 && s2_p_up;
		wire [9:0]  s2_p_mp1   = inc10(s2_xw[22:13], s2_p_lo1);
		wire [4:0]  s2_p_ep1   = inc5(s2_er_p[4:0]);
		wire [9:0]  s2_p_mr    = s2_p_carry ? 10'd0 : (s2_p_up ? s2_p_mp1 : s2_xw[22:13]);
		wire [4:0]  s2_p_exp   = s2_p_carry ? s2_p_ep1 : s2_er_p[4:0];
		wire        s2_p_ovf0  = !s2_er_p[9] && ((|s2_er_p[8:5]) || (&s2_er_p[4:0]));
		wire        s2_p_ovf1  = !s2_er_p[9] && ((|s2_er_p[8:5]) || (&s2_er_p[4:1]));
		wire        s2_p_udf0  = s2_er_p[9] || (s2_er_p[8:0] == 9'd0);
		wire        s2_p_udf1  = s2_er_p[9];
		wire        s2_p_ovf   = s2_p_carry ? s2_p_ovf1 : s2_p_ovf0;
		wire        s2_p_udf   = s2_p_carry ? s2_p_udf1 : s2_p_udf0;
		wire [15:0] s2_hr_p    = s2_p_ovf ? {s2_xw[31], 5'h1F, 10'd0} :
		                         s2_p_udf ? {s2_xw[31], 15'd0} : {s2_xw[31], s2_p_exp, s2_p_mr};
		wire [15:0] s2_xh      = (s2_xw[30:23] == 8'hFF) ? ((s2_xw[22:0] != 23'd0) ? 16'h7E00 : {s2_xw[31], 5'h1F, 10'd0}) :
		                         (s2_xw[30:23] == 8'd0)  ? {s2_xw[31], 15'd0} : s2_hr_p;
		wire [15:0] s2_res     = s2_ovr_en ? s2_ovr_val : s2_packh ? s2_xh : 16'd0;

		always @(posedge clk) begin
			if (rst_p) begin
				s1_valid <= 1'b0;
				s2_valid <= 1'b0;
				s3_valid <= 1'b0;
				s4_valid <= 1'b0;
				s5_valid <= 1'b0;
				s6_valid <= 1'b0;
				s6_res   <= 16'd0;
			end else begin
				s1_valid <= valid_in;
				s2_valid <= s1_valid;
				s3_valid <= s2_valid;
				s4_valid <= s3_valid;
				s5_valid <= s4_valid;
				s6_valid <= s5_valid;
				s6_res   <= s5_valid ? s5_res : 16'd0;
			end
			if (valid_in) begin
				s1_ovr_en  <= ovr_en;
				s1_ovr_val <= ovr_val;
				s1_packh   <= (o == ATG_PK_PACKH[3:0]);
				s1_xw      <= xw;
			end
			if (s1_valid) begin
				s2_ovr_en  <= s1_ovr_en;
				s2_ovr_val <= s1_ovr_val;
				s2_packh   <= s1_packh;
				s2_xw      <= s1_xw;
				s2_er_p    <= s1_er_p;
			end
			if (s2_valid)
				s3_res <= s2_res;
			if (s3_valid)
				s4_res <= s3_res;
			if (s4_valid)
				s5_res <= s4_res;
		end

		assign y = s6_res;
		wire unused_noarith = &{1'b0, ha, hb, hc, r, sat, o, s6_valid, s1_erp_bo_unused};
	end else begin : g_lat6
		(* dont_touch = "true" *) wire rst_p = !rst_n;
		/* =====================================================================
		 * Stage 1 (EX1): Latch inputs and dedicated multiplier operands (0 Pre-DSP LUTs)
		 * ===================================================================== */
		wire [3:0] o_mux_y, o_mux_z, o_is_int_a, o_is_int_b, o_pipe;
		genvar go;
		for (go = 0; go < 4; go = go + 1) begin : g_o_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bo_y  (.I0(o[go]), .O(o_mux_y[go]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bo_z  (.I0(o[go]), .O(o_mux_z[go]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bo_ia (.I0(o[go]), .O(o_is_int_a[go]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bo_ib (.I0(o[go]), .O(o_is_int_b[go]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bo_p  (.I0(o[go]), .O(o_pipe[go]));
`else
			assign o_mux_y[go]    = o[go];
			assign o_mux_z[go]    = o[go];
			assign o_is_int_a[go] = o[go];
			assign o_is_int_b[go] = o[go];
			assign o_pipe[go]     = o[go];
`endif
		end

		wire s0_is_int_a = o_is_int_a == ATG_PK_IADD2[3:0] || o_is_int_a == ATG_PK_ISUB2[3:0] || o_is_int_a == ATG_PK_IMUL2[3:0];
		wire s0_is_int_b = o_is_int_b == ATG_PK_IADD2[3:0] || o_is_int_b == ATG_PK_ISUB2[3:0] || o_is_int_b == ATG_PK_IMUL2[3:0];
		reg [15:0] s0_fy;
		reg        s0_fnoc;
		always @(*) begin
			s0_fy = 16'h3C00;
			s0_fnoc = 1'b0;
			case (o_mux_y)
			ATG_PK_FMUL2[3:0]: begin
				s0_fy = hb;
				s0_fnoc = 1'b1;
			end
			ATG_PK_FFMA2[3:0]: begin
				s0_fy = hb;
			end
			default: ;
			endcase
		end
		reg [15:0] s0_fz;
		always @(*) begin
			s0_fz = hb;
			case (o_mux_z)
			ATG_PK_FSUB2[3:0]: s0_fz = {!hb[15], hb[14:0]};
			ATG_PK_FMUL2[3:0]: s0_fz = 16'd0;
			ATG_PK_FFMA2[3:0]: s0_fz = hc;
			default: ;
			endcase
		end
		wire [15:0] s0_fa = atg_su_hflush(ha);
		wire [15:0] s0_fb = atg_su_hflush(s0_fy);
		wire [15:0] s0_fc = atg_su_hflush(s0_fz);
		wire s0_za = ha[14:10] == 5'd0;
		wire s0_zb = s0_fy[14:10] == 5'd0;
		wire [10:0] s0_ma = {!s0_za, s0_za ? 10'd0 : ha[9:0]};
		wire [10:0] s0_mb = {!s0_zb, s0_zb ? 10'd0 : s0_fy[9:0]};

		(* shreg_extract = "no" *) reg        s1_valid;
		(* shreg_extract = "no" *) reg        s1_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s1_ovr_val;
		(* shreg_extract = "no" *) reg [3:0]  s1_o;
		(* shreg_extract = "no" *) reg [15:0] s1_ha, s1_hb, s1_hc;
		(* shreg_extract = "no" *) reg [15:0] s1_fa, s1_fb, s1_fc;
		(* shreg_extract = "no" *) reg        s1_fnoc;
		(* shreg_extract = "no" *) reg [2:0]  s1_r;
		(* shreg_extract = "no" *) reg        s1_sat;
		(* shreg_extract = "no" *) reg [31:0] s1_xw;
		(* shreg_extract = "no", keep = "true" *) reg [15:0] s1_mul_a;
		(* shreg_extract = "no", keep = "true" *) reg [15:0] s1_mul_b;

		always @(posedge clk) begin
			if (rst_p) begin
				s1_valid   <= 1'b0;
				s1_ovr_en  <= 1'b0;
				s1_ovr_val <= 16'd0;
				s1_o       <= 4'd0;
				s1_ha      <= 16'd0;
				s1_hb      <= 16'd0;
				s1_hc      <= 16'd0;
				s1_fa      <= 16'd0;
				s1_fb      <= 16'd0;
				s1_fc      <= 16'd0;
				s1_fnoc    <= 1'b0;
				s1_r       <= 3'd0;
				s1_sat     <= 1'b0;
				s1_xw      <= 32'd0;
				s1_mul_a   <= 16'd0;
				s1_mul_b   <= 16'd0;
			end else begin
				s1_valid   <= valid_in;
				s1_ovr_en  <= ovr_en;
				s1_ovr_val <= ovr_val;
				s1_o       <= o_pipe;
				s1_ha      <= ha;
				s1_hb      <= hb;
				s1_hc      <= hc;
				s1_fa      <= s0_fa;
				s1_fb      <= s0_fb;
				s1_fc      <= s0_fc;
				s1_fnoc    <= s0_fnoc;
				s1_r       <= r;
				s1_sat     <= sat;
				s1_xw      <= xw;
				s1_mul_a   <= s0_is_int_a ? ha : {5'd0, s0_ma};
				s1_mul_b   <= s0_is_int_b ? hb : {5'd0, s0_mb};
			end
		end

		/* 16x16 Multiplier with LAT=2 (Stages 2 and 3 inside DSP) */
		wire [31:0] prod_mul;
		am_mul #(.AW(16), .BW(16), .LAT(2)) u_mul (
			.clk(clk), .en(1'b1), .a(s1_mul_a), .b(s1_mul_b), .p(prod_mul)
		);

		/* Stage 4 fabric register directly after DSP PREG (0 Post-DSP LUTs) */
		(* dont_touch = "true" *) reg [31:0] s4_prod;
		always @(posedge clk) begin
			if (rst_p)
				s4_prod <= 32'd0;
			else
				s4_prod <= prod_mul;
		end

		/* =====================================================================
		 * Stage 1 -> Stage 2: Parallel small adders & operand decode
		 * ===================================================================== */
		wire [4:0]  s1_ea = s1_fa[14:10];
		wire [4:0]  s1_eb = s1_fb[14:10];
		wire [4:0]  s1_ec = s1_fc[14:10];
		wire        s1_sp = s1_fa[15] ^ s1_fb[15];
		wire        s1_sc = s1_fc[15];
		wire        s1_rdn = s1_r == 3'd2;
		wire        s1_nan_a = s1_ea == 5'h1F && s1_fa[9:0] != 10'd0;
		wire        s1_nan_b = s1_eb == 5'h1F && s1_fb[9:0] != 10'd0;
		wire        s1_nan_c = !s1_fnoc && s1_ec == 5'h1F && s1_fc[9:0] != 10'd0;
		wire        s1_inf_a = s1_ea == 5'h1F && s1_fa[9:0] == 10'd0;
		wire        s1_inf_b = s1_eb == 5'h1F && s1_fb[9:0] == 10'd0;
		wire        s1_inf_c = !s1_fnoc && s1_ec == 5'h1F && s1_fc[9:0] == 10'd0;
		wire        s1_za = s1_ea == 5'd0;
		wire        s1_zb = s1_eb == 5'd0;
		wire        s1_zc = s1_fnoc || s1_ec == 5'd0;
		wire [10:0] s1_mc = s1_zc ? 11'd0 : {1'b1, s1_fc[9:0]};

		wire        s1_spec_nan = s1_nan_a || s1_nan_b || s1_nan_c || (s1_inf_a && s1_zb) || (s1_inf_b && s1_za);
		wire        s1_spec_inf_ab = (s1_inf_a || s1_inf_b) && !s1_spec_nan;
		wire        s1_spec_inf_c = s1_inf_c && !s1_spec_nan && !s1_spec_inf_ab;
		wire        s1_spec_zero = (s1_za || s1_zb) && !s1_spec_nan && !s1_spec_inf_ab && !s1_spec_inf_c;
		wire        s1_spec_hit = s1_spec_nan || s1_spec_inf_ab || s1_spec_inf_c || s1_spec_zero;

		wire s1_spec_nan_lo, s1_spec_nan_hi;
		wire s1_spec_inf_ab_lo, s1_spec_inf_ab_hi;
		wire s1_spec_inf_c_lo, s1_spec_inf_c_hi;
		wire s1_zc_lo, s1_zc_hi;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_snan_l (.I0(s1_spec_nan),    .O(s1_spec_nan_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_snan_h (.I0(s1_spec_nan),    .O(s1_spec_nan_hi));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_sinf_l (.I0(s1_spec_inf_ab), .O(s1_spec_inf_ab_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_sinf_h (.I0(s1_spec_inf_ab), .O(s1_spec_inf_ab_hi));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_sc_l   (.I0(s1_spec_inf_c),  .O(s1_spec_inf_c_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_sc_h   (.I0(s1_spec_inf_c),  .O(s1_spec_inf_c_hi));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_zc_l   (.I0(s1_zc),          .O(s1_zc_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_zc_h   (.I0(s1_zc),          .O(s1_zc_hi));
`else
		assign s1_spec_nan_lo    = s1_spec_nan;
		assign s1_spec_nan_hi    = s1_spec_nan;
		assign s1_spec_inf_ab_lo = s1_spec_inf_ab;
		assign s1_spec_inf_ab_hi = s1_spec_inf_ab;
		assign s1_spec_inf_c_lo  = s1_spec_inf_c;
		assign s1_spec_inf_c_hi  = s1_spec_inf_c;
		assign s1_zc_lo          = s1_zc;
		assign s1_zc_hi          = s1_zc;
`endif
		wire [7:0] s1_spec_res_lo =
			s1_spec_nan_lo ? 8'h00 :
			s1_spec_inf_ab_lo ? 8'h00 :
			s1_spec_inf_c_lo ? s1_fc[7:0] :
			(!s1_zc_lo ? s1_fc[7:0] : 8'd0);

		wire [7:0] s1_spec_res_hi =
			s1_spec_nan_hi ? 8'h7E :
			s1_spec_inf_ab_hi ? (s1_inf_c && s1_sc != s1_sp ? 8'h7E : {s1_sp, 5'h1F, 2'd0}) :
			s1_spec_inf_c_hi ? s1_fc[15:8] :
			(!s1_zc_hi ? s1_fc[15:8] : s1_fnoc ? {s1_sp, 7'd0} : {s1_rdn ? (s1_sp | s1_sc) : (s1_sp & s1_sc), 7'd0});

		wire [15:0] s1_spec_res = {s1_spec_res_hi, s1_spec_res_lo};

		wire [9:0] s1_t, s1_ec_p25, s1_ec_p37, s1_ec_p2, s1_er_p;
		wire [15:0] s1_isum;
		wire [5:0] s1_co_unused;
		am_add #(.W(10)) u_s1_t   (.a({5'd0, s1_ea}), .b({5'd0, s1_eb}), .ci(1'b0), .s(s1_t),      .co(s1_co_unused[0]));
		am_add #(.W(10)) u_s1_c25 (.a({5'd0, s1_ec}), .b(10'd25),        .ci(1'b0), .s(s1_ec_p25), .co(s1_co_unused[1]));
		am_add #(.W(10)) u_s1_c37 (.a({5'd0, s1_ec}), .b(10'd37),        .ci(1'b0), .s(s1_ec_p37), .co(s1_co_unused[2]));
		am_add #(.W(10)) u_s1_c2  (.a({5'd0, s1_ec}), .b(10'd2),         .ci(1'b0), .s(s1_ec_p2),  .co(s1_co_unused[3]));
		am_addsub #(.W(16)) u_s1_iadd (.a(s1_ha), .b(s1_hb), .sub(s1_o == ATG_PK_ISUB2[3:0]), .s(s1_isum), .co(s1_co_unused[4]));
		am_sub #(.W(10)) u_s1_erp (.a({2'd0, s1_xw[30:23]}), .b(10'd112), .bi(1'b0), .d(s1_er_p), .bo(s1_co_unused[5]));

		wire [15:0] s1_haf = s1_fa;
		wire [15:0] s1_hbf = atg_su_hflush(s1_hb);
		wire        s1_hb_z = s1_hb[14:10] == 5'd0;
		wire        s1_hb_nan = s1_hb[14:10] == 5'h1F && s1_hb[9:0] != 10'd0;
		wire [14:0] s1_ab_diff_unused, s1_ba_diff_unused;
		wire        s1_ab_lt_raw, s1_ba_lt_raw;
		am_sub #(.W(15)) u_s1_ab_lt (.a(s1_ha[14:0]), .b(s1_hb[14:0]), .bi(1'b0), .d(s1_ab_diff_unused), .bo(s1_ab_lt_raw));
		am_sub #(.W(15)) u_s1_ba_lt (.a(s1_hb[14:0]), .b(s1_ha[14:0]), .bi(1'b0), .d(s1_ba_diff_unused), .bo(s1_ba_lt_raw));

		/* --- Stage 2 registers --- */
		(* shreg_extract = "no" *) reg        s2_valid;
		(* shreg_extract = "no" *) reg        s2_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s2_ovr_val;
		(* shreg_extract = "no" *) reg [3:0]  s2_o;
		(* shreg_extract = "no" *) reg [2:0]  s2_r;
		(* shreg_extract = "no" *) reg        s2_sat;
		(* shreg_extract = "no" *) reg [31:0] s2_xw;
		(* shreg_extract = "no" *) reg [10:0] s2_mc;
		(* shreg_extract = "no" *) reg        s2_sp, s2_sc, s2_rdn, s2_zc;
		(* shreg_extract = "no" *) reg        s2_spec_hit;
		(* shreg_extract = "no" *) reg [15:0] s2_spec_res;
		(* shreg_extract = "no" *) reg [9:0]  s2_t, s2_ec_p25, s2_ec_p37, s2_ec_p2, s2_er_p;
		(* shreg_extract = "no" *) reg [15:0] s2_isum;
		(* shreg_extract = "no" *) reg [15:0] s2_haf, s2_hbf;
		(* shreg_extract = "no" *) reg        s2_za, s2_hb_z, s2_nan_a, s2_hb_nan;
		(* shreg_extract = "no" *) reg        s2_ab_lt_raw, s2_ba_lt_raw;

		always @(posedge clk) begin
			if (rst_p) begin
				s2_valid     <= 1'b0;
				s2_ovr_en    <= 1'b0;
				s2_ovr_val   <= 16'd0;
				s2_o         <= 4'd0;
				s2_r         <= 3'd0;
				s2_sat       <= 1'b0;
				s2_xw        <= 32'd0;
				s2_mc        <= 11'd0;
				s2_sp        <= 1'b0;
				s2_sc        <= 1'b0;
				s2_rdn       <= 1'b0;
				s2_zc        <= 1'b0;
				s2_spec_hit  <= 1'b0;
				s2_spec_res  <= 16'd0;
				s2_t         <= 10'd0;
				s2_ec_p25    <= 10'd0;
				s2_ec_p37    <= 10'd0;
				s2_ec_p2     <= 10'd0;
				s2_er_p      <= 10'd0;
				s2_isum      <= 16'd0;
				s2_haf       <= 16'd0;
				s2_hbf       <= 16'd0;
				s2_za        <= 1'b0;
				s2_hb_z      <= 1'b0;
				s2_nan_a     <= 1'b0;
				s2_hb_nan    <= 1'b0;
				s2_ab_lt_raw <= 1'b0;
				s2_ba_lt_raw <= 1'b0;
			end else begin
				s2_valid     <= s1_valid;
				s2_ovr_en    <= s1_ovr_en;
				s2_ovr_val   <= s1_ovr_val;
				s2_o         <= s1_o;
				s2_r         <= s1_r;
				s2_sat       <= s1_sat;
				s2_xw        <= s1_xw;
				s2_mc        <= s1_mc;
				s2_sp        <= s1_sp;
				s2_sc        <= s1_sc;
				s2_rdn       <= s1_rdn;
				s2_zc        <= s1_zc;
				s2_spec_hit  <= s1_spec_hit;
				s2_spec_res  <= s1_spec_res;
				s2_t         <= s1_t;
				s2_ec_p25    <= s1_ec_p25;
				s2_ec_p37    <= s1_ec_p37;
				s2_ec_p2     <= s1_ec_p2;
				s2_er_p      <= s1_er_p;
				s2_isum      <= s1_isum;
				s2_haf       <= s1_haf;
				s2_hbf       <= s1_hbf;
				s2_za        <= s1_za;
				s2_hb_z      <= s1_hb_z;
				s2_nan_a     <= s1_nan_a;
				s2_hb_nan    <= s1_hb_nan;
				s2_ab_lt_raw <= s1_ab_lt_raw;
				s2_ba_lt_raw <= s1_ba_lt_raw;
			end
		end

		/* =====================================================================
		 * Stage 2 -> Stage 3: Exponent differences, packh rounding, & minmax/cmp
		 * ===================================================================== */
		wire s2_both_z = s2_za && s2_hb_z;
		wire s2_mag_lt = s2_ab_lt_raw && !s2_both_z;
		wire s2_mag_gt = s2_ba_lt_raw && !s2_both_z;
		wire s2_mag_eq = !s2_mag_lt && !s2_mag_gt;
		wire s2_lt_ab  = (s2_haf[15] && !s2_hbf[15]) ||
		                 (!s2_haf[15] && !s2_hbf[15] && s2_mag_lt) ||
		                 (s2_haf[15] && s2_hbf[15] && s2_mag_gt);
		wire s2_lt_ba  = (s2_hbf[15] && !s2_haf[15]) ||
		                 (!s2_hbf[15] && !s2_haf[15] && s2_mag_gt) ||
		                 (s2_hbf[15] && s2_haf[15] && s2_mag_lt);
		wire s2_is_max = (s2_o == ATG_PK_FMAX2[3:0]);
		wire [15:0] s2_fminmax = (s2_nan_a && s2_hb_nan) ? 16'h7E00 :
		                         s2_nan_a ? s2_hbf :
		                         s2_hb_nan ? s2_haf :
		                         s2_is_max ? (s2_lt_ab ? s2_hbf : s2_haf) :
		                                     (s2_lt_ba ? s2_hbf : s2_haf);
		wire s2_un = s2_nan_a || s2_hb_nan;
		wire s2_eq = s2_both_z || ((s2_haf[15] == s2_hbf[15]) && s2_mag_eq);
		wire s2_lt = !s2_eq && s2_lt_ab;
		wire s2_gt = !s2_eq && s2_lt_ba;
		reg  s2_cmp_bit;
		always @(*) begin
			case (s2_o)
			ATG_PK_FCMPLT2[3:0]: s2_cmp_bit = !s2_un && s2_lt;
			ATG_PK_FCMPGE2[3:0]: s2_cmp_bit = !s2_un && (s2_gt || s2_eq);
			ATG_PK_FCMPEQ2[3:0]: s2_cmp_bit = !s2_un && s2_eq;
			default:             s2_cmp_bit = s2_un || !s2_eq;
			endcase
		end
		wire [15:0] s2_fcmp = {16{s2_cmp_bit}};
		wire [9:0] s2_k, s2_dp37, s2_eb_c, s2_eb_t;
		wire [3:0] s2_bo_unused;
		am_sub #(.W(10)) u_s2_k    (.a(s2_ec_p25), .b(s2_t),     .bi(1'b0), .d(s2_k),    .bo(s2_bo_unused[0]));
		am_sub #(.W(10)) u_s2_dp37 (.a(s2_ec_p37), .b(s2_t),     .bi(1'b0), .d(s2_dp37), .bo(s2_bo_unused[1]));
		am_sub #(.W(10)) u_s2_ebc  (.a(s2_ec_p2),  .b(10'd37),   .bi(1'b0), .d(s2_eb_c), .bo(s2_bo_unused[2]));
		am_sub #(.W(10)) u_s2_ebt  (.a(s2_t),      .b(10'd37),   .bi(1'b0), .d(s2_eb_t), .bo(s2_bo_unused[3]));

		/* Pure-LUT FP32 -> FP16 RNE rounder (0 CARRY4s, <= 3 LUTs) */
		wire        s2_p_st    = |s2_xw[11:0];
		wire        s2_p_up    = s2_xw[12] && (s2_p_st || s2_xw[13]);
		wire        s2_p_lo1   = &s2_xw[17:13];
		wire        s2_p_hi1   = &s2_xw[22:18];
		wire        s2_p_carry = s2_p_lo1 && s2_p_hi1 && s2_p_up;
		wire [9:0]  s2_p_mp1   = inc10(s2_xw[22:13], s2_p_lo1);
		wire [4:0]  s2_p_ep1   = inc5(s2_er_p[4:0]);
		wire [9:0]  s2_p_mr    = s2_p_carry ? 10'd0 : (s2_p_up ? s2_p_mp1 : s2_xw[22:13]);
		wire [4:0]  s2_p_exp   = s2_p_carry ? s2_p_ep1 : s2_er_p[4:0];
		wire        s2_p_ovf0  = !s2_er_p[9] && ((|s2_er_p[8:5]) || (&s2_er_p[4:0]));
		wire        s2_p_ovf1  = !s2_er_p[9] && ((|s2_er_p[8:5]) || (&s2_er_p[4:1]));
		wire        s2_p_udf0  = s2_er_p[9] || (s2_er_p[8:0] == 9'd0);
		wire        s2_p_udf1  = s2_er_p[9];
		wire        s2_p_ovf   = s2_p_carry ? s2_p_ovf1 : s2_p_ovf0;
		wire        s2_p_udf   = s2_p_carry ? s2_p_udf1 : s2_p_udf0;
		wire [15:0] s2_hr_p    = s2_p_ovf ? {s2_xw[31], 5'h1F, 10'd0} :
		                         s2_p_udf ? {s2_xw[31], 15'd0} : {s2_xw[31], s2_p_exp, s2_p_mr};
		wire [15:0] s2_xh      = (s2_xw[30:23] == 8'hFF) ? ((s2_xw[22:0] != 23'd0) ? 16'h7E00 : {s2_xw[31], 5'h1F, 10'd0}) :
		                         (s2_xw[30:23] == 8'd0)  ? {s2_xw[31], 15'd0} : s2_hr_p;

		/* --- Stage 3 registers --- */
		(* shreg_extract = "no" *) reg        s3_valid;
		(* shreg_extract = "no" *) reg        s3_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s3_ovr_val;
		(* dont_touch = "true" *) reg [3:0]  s3_o_pipe, s3_o_mux_lo, s3_o_mux_hi;
		(* shreg_extract = "no" *) reg [2:0]  s3_r;
		(* shreg_extract = "no" *) reg        s3_sat;
		(* dont_touch = "true" *) reg [10:0] s3_mc_sh, s3_mc_cw;
		(* shreg_extract = "no" *) reg        s3_sp, s3_sc, s3_rdn, s3_zc;
		(* shreg_extract = "no" *) reg        s3_spec_hit;
		(* shreg_extract = "no" *) reg [15:0] s3_spec_res;
		(* shreg_extract = "no" *) reg [9:0]  s3_k, s3_dp37;
		(* shreg_extract = "no" *) reg [6:0]  s3_eb_c, s3_eb_t;
		(* shreg_extract = "no" *) reg [15:0] s3_xh, s3_isum, s3_fminmax, s3_fcmp;

		always @(posedge clk) begin
			if (rst_p) begin
				s3_valid    <= 1'b0;
				s3_ovr_en   <= 1'b0;
				s3_ovr_val  <= 16'd0;
				s3_o_pipe   <= 4'd0;
				s3_o_mux_lo <= 4'd0;
				s3_o_mux_hi <= 4'd0;
				s3_r        <= 3'd0;
				s3_sat      <= 1'b0;
				s3_mc_sh    <= 11'd0;
				s3_mc_cw    <= 11'd0;
				s3_sp       <= 1'b0;
				s3_sc       <= 1'b0;
				s3_rdn      <= 1'b0;
				s3_zc       <= 1'b0;
				s3_spec_hit <= 1'b0;
				s3_spec_res <= 16'd0;
				s3_k        <= 10'd0;
				s3_dp37     <= 10'd0;
				s3_eb_c     <= 7'd0;
				s3_eb_t     <= 7'd0;
				s3_xh       <= 16'd0;
				s3_isum     <= 16'd0;
				s3_fminmax  <= 16'd0;
				s3_fcmp     <= 16'd0;
			end else begin
				s3_valid    <= s2_valid;
				s3_ovr_en   <= s2_ovr_en;
				s3_ovr_val  <= s2_ovr_val;
				s3_o_pipe   <= s2_o;
				s3_o_mux_lo <= s2_o;
				s3_o_mux_hi <= s2_o;
				s3_r        <= s2_r;
				s3_sat      <= s2_sat;
				s3_mc_sh    <= s2_mc;
				s3_mc_cw    <= s2_mc;
				s3_sp       <= s2_sp;
				s3_sc       <= s2_sc;
				s3_rdn      <= s2_rdn;
				s3_zc       <= s2_zc;
				s3_spec_hit <= s2_spec_hit;
				s3_spec_res <= s2_spec_res;
				s3_k        <= s2_k;
				s3_dp37     <= s2_dp37;
				s3_eb_c     <= s2_eb_c[6:0];
				s3_eb_t     <= s2_eb_t[6:0];
				s3_xh       <= s2_xh;
				s3_isum     <= s2_isum;
				s3_fminmax  <= s2_fminmax;
				s3_fcmp     <= s2_fcmp;
			end
		end

		/* =====================================================================
		 * Stage 3 -> Stage 4: Addend shift (u_al) & non-mul result pre-mux
		 * ===================================================================== */
		wire s3_big  = $signed(s3_k) > 10'sd23;
		wire s3_near = $signed(s3_k) >= -10'sd12;
		wire [46:0] s3_zal;
		am_shift #(.W(47), .SW(6), .DIR(2)) u_s3_al (
			.a({36'd0, s3_mc_sh}), .amt(s3_dp37[5:0]), .left(1'b1), .arith(1'b0), .y(s3_zal)
		);
		wire [36:0] s3_zal_cw = {s3_zal[46:11], s3_zal[10] | (|s3_zal[9:0])};
		wire [36:0] s3_big_cw = {1'b0, s3_mc_cw, 25'd0};
		wire [6:0]  s3_eb = (!s3_zc && s3_big) ? s3_eb_c : s3_eb_t;

		reg [7:0] s3_other_lo, s3_other_hi;
		wire [15:0] s3_fminmax_sat = s3_sat ? atg_su_hsat(s3_fminmax) : s3_fminmax;
		always @(*) begin
			case (s3_o_mux_lo)
			ATG_PK_PACKH[3:0]: s3_other_lo = s3_xh[7:0];
			ATG_PK_FMIN2[3:0], ATG_PK_FMAX2[3:0]: s3_other_lo = FL ? s3_fminmax_sat[7:0] : 8'd0;
			ATG_PK_IADD2[3:0], ATG_PK_ISUB2[3:0]: s3_other_lo = AR ? s3_isum[7:0] : 8'd0;
			ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
				s3_other_lo = FL ? s3_fcmp[7:0] : 8'd0;
			default: s3_other_lo = 8'd0;
			endcase
		end
		always @(*) begin
			case (s3_o_mux_hi)
			ATG_PK_PACKH[3:0]: s3_other_hi = s3_xh[15:8];
			ATG_PK_FMIN2[3:0], ATG_PK_FMAX2[3:0]: s3_other_hi = FL ? s3_fminmax_sat[15:8] : 8'd0;
			ATG_PK_IADD2[3:0], ATG_PK_ISUB2[3:0]: s3_other_hi = AR ? s3_isum[15:8] : 8'd0;
			ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
				s3_other_hi = FL ? s3_fcmp[15:8] : 8'd0;
			default: s3_other_hi = 8'd0;
			endcase
		end
		wire [15:0] s3_other_pre = {s3_other_hi, s3_other_lo};

		/* --- Stage 4 registers (in sync with s4_prod) --- */
		(* shreg_extract = "no" *) reg        s4_valid;
		(* shreg_extract = "no" *) reg        s4_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s4_ovr_val;
		(* shreg_extract = "no" *) reg [3:0]  s4_o;
		(* shreg_extract = "no" *) reg [2:0]  s4_r;
		(* shreg_extract = "no" *) reg        s4_sat;
		(* shreg_extract = "no" *) reg [36:0] s4_cw;
		(* shreg_extract = "no" *) reg [6:0]  s4_eb;
		(* shreg_extract = "no" *) reg        s4_big, s4_sp, s4_sc, s4_rdn, s4_zc;
		(* shreg_extract = "no" *) reg        s4_spec_hit;
		(* shreg_extract = "no" *) reg [15:0] s4_spec_res;
		(* shreg_extract = "no" *) reg [15:0] s4_other_pre;

		always @(posedge clk) begin
			if (rst_p) begin
				s4_valid     <= 1'b0;
				s4_ovr_en    <= 1'b0;
				s4_ovr_val   <= 16'd0;
				s4_o         <= 4'd0;
				s4_r         <= 3'd0;
				s4_sat       <= 1'b0;
				s4_eb        <= 7'd0;
				s4_big       <= 1'b0;
				s4_sp        <= 1'b0;
				s4_sc        <= 1'b0;
				s4_rdn       <= 1'b0;
				s4_zc        <= 1'b0;
				s4_spec_hit  <= 1'b0;
				s4_spec_res  <= 16'd0;
				s4_other_pre <= 16'd0;
			end else begin
				s4_valid     <= s3_valid;
				s4_ovr_en    <= s3_ovr_en;
				s4_ovr_val   <= s3_ovr_val;
				s4_o         <= s3_o_pipe;
				s4_r         <= s3_r;
				s4_sat       <= s3_sat;
				s4_eb        <= s3_eb;
				s4_big       <= s3_big;
				s4_sp        <= s3_sp;
				s4_sc        <= s3_sc;
				s4_rdn       <= s3_rdn;
				s4_zc        <= s3_zc;
				s4_spec_hit  <= s3_spec_hit;
				s4_spec_res  <= s3_sat ? atg_su_hsat(s3_spec_res) : s3_spec_res;
				s4_other_pre <= s3_other_pre;
			end
		end
		genvar gcw4;
		for (gcw4 = 0; gcw4 < 3; gcw4 = gcw4 + 1) begin : g_s4_cw
			localparam CW4_W = (gcw4 == 2) ? 5 : 16;
			wire clr_s_raw = rst_p || s3_zc;
			wire clr_s;
			wire s3_big_s, s3_near_s;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_clr (.I0(clr_s_raw), .O(clr_s));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bg  (.I0(s3_big),    .O(s3_big_s));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_nr  (.I0(s3_near),   .O(s3_near_s));
`else
			assign clr_s = clr_s_raw;
			assign s3_big_s = s3_big;
			assign s3_near_s = s3_near;
`endif
			wire [CW4_W-1:0] cw_in = s3_big_s ? s3_big_cw[gcw4*16 +: CW4_W] :
				s3_near_s ? s3_zal_cw[gcw4*16 +: CW4_W] :
				(gcw4 == 0 ? {{(CW4_W-1){1'b0}}, 1'b1} : {CW4_W{1'b0}});
			always @(posedge clk) begin
				if (clr_s)
					s4_cw[gcw4*16 +: CW4_W] <= {CW4_W{1'b0}};
				else
					s4_cw[gcw4*16 +: CW4_W] <= cw_in;
			end
		end

		/* =====================================================================
		 * Stage 4 -> Stage 5: Speculative parallel 37-bit FMA add/sub
		 * ===================================================================== */
		wire s4_zc_sub, s4_zc_pw;
		wire s4_big_pw;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_zc_sub (.I0(s4_zc), .O(s4_zc_sub));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_zc_pw  (.I0(s4_zc), .O(s4_zc_pw));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_big_pw (.I0(s4_big), .O(s4_big_pw));
`else
		assign s4_zc_sub = s4_zc;
		assign s4_zc_pw  = s4_zc;
		assign s4_big_pw = s4_big;
`endif

		wire s4_eff_sub_raw = !(s4_zc_sub || s4_sp == s4_sc);
		wire s4_eff_sub;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_esub (.I0(s4_eff_sub_raw), .O(s4_eff_sub));
`else
		assign s4_eff_sub = s4_eff_sub_raw;
`endif

		wire s4_pw_sel = !s4_zc_pw && s4_big_pw;
		wire s4_pw_sel_pc_0, s4_pw_sel_pc_1;
		wire s4_pw_sel_cp_0, s4_pw_sel_cp_1;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pw_pc0 (.I0(s4_pw_sel), .O(s4_pw_sel_pc_0));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pw_pc1 (.I0(s4_pw_sel), .O(s4_pw_sel_pc_1));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pw_cp0 (.I0(s4_pw_sel), .O(s4_pw_sel_cp_0));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pw_cp1 (.I0(s4_pw_sel), .O(s4_pw_sel_cp_1));
`else
		assign s4_pw_sel_pc_0 = s4_pw_sel;
		assign s4_pw_sel_pc_1 = s4_pw_sel;
		assign s4_pw_sel_cp_0 = s4_pw_sel;
		assign s4_pw_sel_cp_1 = s4_pw_sel;
`endif

		wire [21:0] s4_prod_m_pc = {s4_pw_sel_pc_1 ? 11'd0 : s4_prod[21:11], s4_pw_sel_pc_0 ? 11'd0 : s4_prod[10:0]};
		wire [36:0] s4_pw_pc = {13'd0, s4_prod_m_pc, 1'b0, s4_pw_sel_pc_0};

		wire [21:0] s4_prod_m_cp = {s4_pw_sel_cp_1 ? 11'd0 : s4_prod[21:11], s4_pw_sel_cp_0 ? 11'd0 : s4_prod[10:0]};
		wire [36:0] s4_pw_cp = {13'd0, s4_prod_m_cp, 1'b0, s4_pw_sel_cp_0};

		wire [36:0] s4_sum_pc, s4_sum_cp;
		wire s4_co_pc;
		wire s4_bo_cp_unused;

		am_addsub #(.W(37)) u_s4_sum_pc (
			.a(s4_pw_pc), .b(s4_cw), .sub(s4_eff_sub), .s(s4_sum_pc), .co(s4_co_pc)
		);
		am_sub #(.W(37)) u_s4_sum_cp (
			.a(s4_cw), .b(s4_pw_cp), .bi(1'b0), .d(s4_sum_cp), .bo(s4_bo_cp_unused)
		);

		wire s4_swap = s4_eff_sub && !s4_co_pc;
		wire s4_swap_lo, s4_swap_hi;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sw0 (.I0(s4_swap), .O(s4_swap_lo));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sw1 (.I0(s4_swap), .O(s4_swap_hi));
`else
		assign s4_swap_lo = s4_swap;
		assign s4_swap_hi = s4_swap;
`endif
		wire [36:0] s4_sum  = {
			s4_swap_hi ? s4_sum_cp[36:19] : s4_sum_pc[36:19],
			s4_swap_lo ? s4_sum_cp[18:0]  : s4_sum_pc[18:0]
		};
		wire        s4_sr   = s4_swap ? s4_sc : s4_sp;

		/* Precompute block exponent bases (+0, +16, +32) and their +1 upper bits (LUT3, 0 CARRY4) */
		wire [2:0] s4_eb_hi0 = s4_eb[6:4];
		wire [2:0] s4_eb_hi1 = inc3(s4_eb[6:4]);
		wire [2:0] s4_eb_hi2 = {s4_eb[6] ^ s4_eb[5], ~s4_eb[5], s4_eb[4]};
		wire [2:0] s4_eb_hi3 = inc3(s4_eb_hi2);
		wire [3:0] s4_eb_neg = neg4(s4_eb[3:0]);

		wire s4_is_fma = FL && (s4_o == ATG_PK_FADD2[3:0] || s4_o == ATG_PK_FSUB2[3:0] ||
		                        s4_o == ATG_PK_FMUL2[3:0] || s4_o == ATG_PK_FFMA2[3:0]);
		wire [15:0] s4_other = (s4_o == ATG_PK_IMUL2[3:0]) ? (AR ? s4_prod[15:0] : 16'd0) : s4_other_pre;

		/* --- Stage 5 registers --- */
		(* shreg_extract = "no" *) reg        s5_valid;
		(* shreg_extract = "no" *) reg        s5_ovr_en;
		(* shreg_extract = "no" *) reg [15:0] s5_ovr_val;
		(* shreg_extract = "no" *) reg        s5_is_fma;
		(* shreg_extract = "no" *) reg [2:0]  s5_r;
		(* shreg_extract = "no" *) reg        s5_sat;
		(* shreg_extract = "no" *) reg [36:0] s5_sum;
		(* shreg_extract = "no" *) reg        s5_sr, s5_rdn;
		(* shreg_extract = "no" *) reg [3:0]  s5_eb_lo, s5_eb_neg;
		(* shreg_extract = "no" *) reg [2:0]  s5_eb_hi0, s5_eb_hi1, s5_eb_hi2, s5_eb_hi3;
		(* shreg_extract = "no" *) reg        s5_spec_hit;
		(* shreg_extract = "no" *) reg [15:0] s5_spec_res;
		(* shreg_extract = "no" *) reg [15:0] s5_other;

		always @(posedge clk) begin
			if (rst_p) begin
				s5_valid    <= 1'b0;
				s5_ovr_en   <= 1'b0;
				s5_ovr_val  <= 16'd0;
				s5_is_fma   <= 1'b0;
				s5_r        <= 3'd0;
				s5_sat      <= 1'b0;
				s5_sum      <= 37'd0;
				s5_sr       <= 1'b0;
				s5_rdn      <= 1'b0;
				s5_eb_lo    <= 4'd0;
				s5_eb_neg   <= 4'd0;
				s5_eb_hi0   <= 3'd0;
				s5_eb_hi1   <= 3'd0;
				s5_eb_hi2   <= 3'd0;
				s5_eb_hi3   <= 3'd0;
				s5_spec_hit <= 1'b0;
				s5_spec_res <= 16'd0;
				s5_other    <= 16'd0;
			end else begin
				s5_valid    <= s4_valid;
				s5_ovr_en   <= s4_ovr_en;
				s5_ovr_val  <= s4_ovr_val;
				s5_is_fma   <= s4_is_fma;
				s5_r        <= s4_r;
				s5_sat      <= s4_sat;
				s5_sum      <= s4_sum;
				s5_sr       <= s4_sr;
				s5_rdn      <= s4_rdn;
				s5_eb_lo    <= s4_eb[3:0];
				s5_eb_neg   <= s4_eb_neg;
				s5_eb_hi0   <= s4_eb_hi0;
				s5_eb_hi1   <= s4_eb_hi1;
				s5_eb_hi2   <= s4_eb_hi2;
				s5_eb_hi3   <= s4_eb_hi3;
				s5_spec_hit <= s4_spec_hit;
				s5_spec_res <= s4_spec_res;
				s5_other    <= s4_other;
			end
		end

		/* =====================================================================
		 * Stage 5 -> Stage 6: Level-pinned <= 4 LUT LOD, parallel shift, 1-bit
		 *                     sticky, and Carry-Select exponent add (0 CARRY4s)
		 * ===================================================================== */
		/* --- Level 1 (1 LUT6 per wire from Stage 5 FFs) --- */
		(* keep = "true" *) wire       nz_b2   = |s5_sum[36:32];
		(* keep = "true" *) wire       nz_b2_s = |s5_sum[36:32];
		(* keep = "true" *) wire [3:0] msb_b2  = {
			1'b0,
			s5_sum[36],
			!s5_sum[36] && (|s5_sum[35:34]),
			!s5_sum[36] && (s5_sum[35] || (!s5_sum[34] && s5_sum[33]))
		};
		(* keep = "true" *) wire b2_g32  = s5_eb_lo[3] && s5_eb_lo[2] && s5_sum[36];
		(* keep = "true" *) wire b2_p32  = s5_eb_lo[3] ? (s5_eb_lo[2] || s5_sum[36]) : (s5_eb_lo[2] && s5_sum[36]);
		(* keep = "true" *) wire b2_c2_0 = nib_c2(
			{!s5_sum[36] && s5_sum[35], !s5_sum[36] && s5_sum[34], !s5_sum[36] && s5_sum[33]},
			s5_eb_lo[1:0], 1'b0
		);
		(* keep = "true" *) wire b2_c2_1 = nib_c2(
			{!s5_sum[36] && s5_sum[35], !s5_sum[36] && s5_sum[34], !s5_sum[36] && s5_sum[33]},
			s5_eb_lo[1:0], 1'b1
		);

		(* keep = "true" *) wire b1_h3   = |s5_sum[31:28], b1_h2   = |s5_sum[27:24], b1_h1 = |s5_sum[23:20], b1_h0 = |s5_sum[19:16];
		(* keep = "true" *) wire b1_h3_s = |s5_sum[31:28], b1_h2_s = |s5_sum[27:24];
		(* keep = "true" *) wire b1_m1_3 = |s5_sum[31:30], b1_m0_3 = s5_sum[31] || (!s5_sum[30] && s5_sum[29]);
		(* keep = "true" *) wire b1_m1_2 = |s5_sum[27:26], b1_m0_2 = s5_sum[27] || (!s5_sum[26] && s5_sum[25]);
		(* keep = "true" *) wire b1_m1_1 = |s5_sum[23:22], b1_m0_1 = s5_sum[23] || (!s5_sum[22] && s5_sum[21]);
		(* keep = "true" *) wire b1_m1_0 = |s5_sum[19:18], b1_m0_0 = s5_sum[19] || (!s5_sum[18] && s5_sum[17]);
		(* keep = "true" *) wire b1_c2_0_3 = nib_c2(s5_sum[31:29], s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b1_c2_0_2 = nib_c2(s5_sum[27:25], s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b1_c2_0_1 = nib_c2(s5_sum[23:21], s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b1_c2_0_0 = nib_c2(s5_sum[19:17], s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b1_c2_1_3 = nib_c2(s5_sum[31:29], s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b1_c2_1_2 = nib_c2(s5_sum[27:25], s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b1_c2_1_1 = nib_c2(s5_sum[23:21], s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b1_c2_1_0 = nib_c2(s5_sum[19:17], s5_eb_lo[1:0], 1'b1);

		(* keep = "true" *) wire b0_h3 = |s5_sum[15:12], b0_h2 = |s5_sum[11:8], b0_h1 = |s5_sum[7:4], b0_h0 = |s5_sum[3:0];
		(* keep = "true" *) wire b0_m1_3 = |s5_sum[15:14], b0_m0_3 = s5_sum[15] || (!s5_sum[14] && s5_sum[13]);
		(* keep = "true" *) wire b0_m1_2 = |s5_sum[11:10], b0_m0_2 = s5_sum[11] || (!s5_sum[10] && s5_sum[9]);
		(* keep = "true" *) wire b0_m1_1 = |s5_sum[7:6],   b0_m0_1 = s5_sum[7]  || (!s5_sum[6]  && s5_sum[5]);
		(* keep = "true" *) wire b0_m1_0 = |s5_sum[3:2],   b0_m0_0 = s5_sum[3]  || (!s5_sum[2]  && s5_sum[1]);
		(* keep = "true" *) wire b0_c2_0_3 = nib_c2(s5_sum[15:13], s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b0_c2_0_2 = nib_c2(s5_sum[11:9],  s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b0_c2_0_1 = nib_c2(s5_sum[7:5],   s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b0_c2_0_0 = nib_c2(s5_sum[3:1],   s5_eb_lo[1:0], 1'b0);
		(* keep = "true" *) wire b0_c2_1_3 = nib_c2(s5_sum[15:13], s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b0_c2_1_2 = nib_c2(s5_sum[11:9],  s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b0_c2_1_1 = nib_c2(s5_sum[7:5],   s5_eb_lo[1:0], 1'b1);
		(* keep = "true" *) wire b0_c2_1_0 = nib_c2(s5_sum[3:1],   s5_eb_lo[1:0], 1'b1);

		(* keep = "true" *) wire st2_p0 = st_part6(s5_sum[35:33], s5_sum[23:21]);
		(* keep = "true" *) wire st2_p1 = s5_sum[36] && (|s5_sum[24:21]);
		(* keep = "true" *) wire st1_p3 = st_part6(s5_sum[31:29], s5_sum[19:17]);
		(* keep = "true" *) wire st1_p2 = st_part6(s5_sum[27:25], s5_sum[15:13]);
		(* keep = "true" *) wire st1_p1 = st_part6(s5_sum[23:21], s5_sum[11:9]);
		(* keep = "true" *) wire st1_p0 = st_part6(s5_sum[19:17], s5_sum[7:5]);
		(* keep = "true" *) wire st0_p0 = st_part6(s5_sum[14:12], s5_sum[2:0]);
		(* keep = "true" *) wire st0_p1 = s5_sum[15] && (|s5_sum[3:0]);
		(* keep = "true" *) wire or_4_0   = |s5_sum[4:0];
		(* keep = "true" *) wire or_8_5   = |s5_sum[8:5];
		(* keep = "true" *) wire or_12_9  = |s5_sum[12:9];
		(* keep = "true" *) wire or_16_13 = |s5_sum[16:13];
		(* keep = "true" *) wire or_20_17 = |s5_sum[20:17];
		(* keep = "true" *) wire s5_norm_base_ok = s5_valid && !s5_ovr_en && s5_is_fma && !s5_spec_hit && !(s5_sat && s5_sr);

		/* --- Level 2 (1 LUT6 per wire from Level 1) --- */
		wire       nz_b1_raw = b1_h3 || b1_h2 || b1_h1 || b1_h0;
		wire       nz_b1_a, nz_b1_b, nz_b1_c;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_nzb1_a (.I0(nz_b1_raw), .O(nz_b1_a));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_nzb1_b (.I0(nz_b1_raw), .O(nz_b1_b));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_nzb1_c (.I0(nz_b1_raw), .O(nz_b1_c));
`else
		assign nz_b1_a = nz_b1_raw;
		assign nz_b1_b = nz_b1_raw;
		assign nz_b1_c = nz_b1_raw;
`endif
		(* keep = "true" *) wire       nz_b0  = b0_h3 || b0_h2 || b0_h1 || b0_h0;
		(* keep = "true" *) wire [3:0] msb_b1 = {
			b1_h3 || b1_h2,
			b1_h3 || (!b1_h2 && b1_h1),
			b1_h3 ? b1_m1_3 : b1_h2 ? b1_m1_2 : b1_h1 ? b1_m1_1 : b1_m1_0,
			b1_h3 ? b1_m0_3 : b1_h2 ? b1_m0_2 : b1_h1 ? b1_m0_1 : b1_m0_0
		};
		(* keep = "true" *) wire [3:0] msb_b0 = {
			b0_h3 || b0_h2,
			b0_h3 || (!b0_h2 && b0_h1),
			b0_h3 ? b0_m1_3 : b0_h2 ? b0_m1_2 : b0_h1 ? b0_m1_1 : b0_m1_0,
			b0_h3 ? b0_m0_3 : b0_h2 ? b0_m0_2 : b0_h1 ? b0_m0_1 : b0_m0_0
		};
		(* keep = "true" *) wire b1_c2_0 = b1_h3 ? b1_c2_0_3 : b1_h2 ? b1_c2_0_2 : b1_h1 ? b1_c2_0_1 : b1_c2_0_0;
		(* keep = "true" *) wire b1_c2_1 = b1_h3 ? b1_c2_1_3 : b1_h2 ? b1_c2_1_2 : b1_h1 ? b1_c2_1_1 : b1_c2_1_0;
		(* keep = "true" *) wire b0_c2_0 = b0_h3 ? b0_c2_0_3 : b0_h2 ? b0_c2_0_2 : b0_h1 ? b0_c2_0_1 : b0_c2_0_0;
		(* keep = "true" *) wire b0_c2_1 = b0_h3 ? b0_c2_1_3 : b0_h2 ? b0_c2_1_2 : b0_h1 ? b0_c2_1_1 : b0_c2_1_0;

		wire b1_m3 = b1_h3 || b1_h2, b1_m2 = b1_h3 || (!b1_h2 && b1_h1);
		wire b0_m3 = b0_h3 || b0_h2, b0_m2 = b0_h3 || (!b0_h2 && b0_h1);
		(* keep = "true" *) wire b1_g32 = (s5_eb_lo[3] && b1_m3) || ((s5_eb_lo[3] || b1_m3) && s5_eb_lo[2] && b1_m2);
		(* keep = "true" *) wire b1_p32 = (s5_eb_lo[3] || b1_m3) && (s5_eb_lo[2] || b1_m2);
		(* keep = "true" *) wire b0_g32 = (s5_eb_lo[3] && b0_m3) || ((s5_eb_lo[3] || b0_m3) && s5_eb_lo[2] && b0_m2);
		(* keep = "true" *) wire b0_p32 = (s5_eb_lo[3] || b0_m3) && (s5_eb_lo[2] || b0_m2);

		(* keep = "true" *) wire st_b2    = st2_p1 || st2_p0 || or_20_17 || or_16_13 || or_12_9 || or_8_5;
		(* keep = "true" *) wire st_b1_32 = b1_h3 ? (st1_p3 || or_16_13 || or_12_9 || or_8_5) : (st1_p2 || or_12_9 || or_8_5);
		(* keep = "true" *) wire st_b1_10 = b1_h1 ? (st1_p1 || or_8_5) : st1_p0;
		(* keep = "true" *) wire st_b0    = st0_p1 || st0_p0;

		wire [25:0] win0_pad = {s5_sum[14:0], 11'd0};
		(* keep = "true" *) wire [10:0] w2_s2;
		(* keep = "true" *) wire [13:0] w1_s2, w0_s2;
		genvar gs;
		for (gs = 0; gs < 11; gs = gs + 1) begin : g_w2_s2
			assign w2_s2[gs] = msb_b2[1] ? (msb_b2[0] ? s5_sum[24 + gs] : s5_sum[23 + gs]) :
			                               (msb_b2[0] ? s5_sum[22 + gs] : s5_sum[21 + gs]);
		end
		for (gs = 0; gs < 14; gs = gs + 1) begin : g_w10_s2
			assign w1_s2[gs] = b1_h3_s ? s5_sum[17 + gs]   : b1_h2_s ? s5_sum[13 + gs]  : b1_h1 ? s5_sum[9 + gs]  : s5_sum[5 + gs];
			assign w0_s2[gs] = b0_h3   ? win0_pad[12 + gs] : b0_h2   ? win0_pad[8 + gs] : b0_h1 ? win0_pad[4 + gs] : win0_pad[gs];
		end

		/* --- Level 3 (1 LUT6 per wire from Level 2) --- */
		(* keep = "true" *) wire [10:0] w2_sh, w1_sh, w0_sh;
		for (gs = 0; gs < 11; gs = gs + 1) begin : g_w_sh
			assign w2_sh[gs] = s5_sum[36] ? s5_sum[25 + gs] : w2_s2[gs];
			assign w1_sh[gs] = msb_b1[1] ? (msb_b1[0] ? w1_s2[gs + 3] : w1_s2[gs + 2]) :
			                               (msb_b1[0] ? w1_s2[gs + 1] : w1_s2[gs]);
			assign w0_sh[gs] = msb_b0[1] ? (msb_b0[0] ? w0_s2[gs + 3] : w0_s2[gs + 2]) :
			                               (msb_b0[0] ? w0_s2[gs + 1] : w0_s2[gs]);
		end

		(* keep = "true" *) wire [3:0] s5_sub_msb   = nz_b2 ? msb_b2 : nz_b1_a ? msb_b1 : msb_b0;
		(* keep = "true" *) wire [3:0] s5_msb_x_eb  = (nz_b2 ? msb_b2 : nz_b1_a ? msb_b1 : msb_b0) ^ s5_eb_lo;
		(* keep = "true" *) wire [3:0] s5_msb_x_neg = (nz_b2 ? msb_b2 : nz_b1_a ? msb_b1 : msb_b0) ^ s5_eb_neg;
		(* keep = "true" *) wire       s5_c2_0      = nz_b2 ? b2_c2_0 : nz_b1_b ? b1_c2_0 : b0_c2_0;
		(* keep = "true" *) wire       s5_c2_1      = nz_b2 ? b2_c2_1 : nz_b1_b ? b1_c2_1 : b0_c2_1;
		(* keep = "true" *) wire       s5_g32       = nz_b2 ? b2_g32  : nz_b1_b ? b1_g32  : b0_g32;
		(* keep = "true" *) wire       s5_p32       = nz_b2 ? b2_p32  : nz_b1_b ? b1_p32  : b0_p32;
		(* keep = "true" *) wire [2:0] s5_eb_hi     = nz_b2_s ? s5_eb_hi2 : nz_b1_b ? s5_eb_hi1 : s5_eb_hi0;
		(* keep = "true" *) wire [2:0] s5_eb_hi_p1  = nz_b2_s ? s5_eb_hi3 : nz_b1_b ? s5_eb_hi2 : s5_eb_hi1;
		(* keep = "true" *) wire       s5_norm_ok   = s5_norm_base_ok && (nz_b2_s || nz_b1_b || nz_b0);
		(* keep = "true" *) wire       s5_use_norm  = s5_valid && !s5_ovr_en && s5_is_fma && !s5_spec_hit && (nz_b2_s || nz_b1_b || nz_b0);

		/* --- Level 4 (1 LUT6 per wire from Level 3, directly into Stage 6 FFs) --- */
		wire [10:0] s5_mg = nz_b2_s ? w2_sh : nz_b1_c ? w1_sh : w0_sh;
		wire [9:0]  s5_m  = s5_mg[10:1];
		wire        s5_g  = s5_mg[0];
		wire        s5_st = nz_b2_s ? (st_b2 || or_4_0) :
		                    (b1_h3_s || b1_h2_s) ? (st_b1_32 || or_4_0) :
		                    (b1_h1 || b1_h0) ? (st_b1_10 || or_4_0) : st_b0;

		wire s5_c1_0 = s5_eb_lo[0] && s5_sub_msb[0];
		wire s5_c1_1 = s5_eb_lo[0] || s5_sub_msb[0];
		wire s5_c3_0 = (s5_eb_lo[2] && s5_sub_msb[2]) || ((s5_eb_lo[2] ^ s5_sub_msb[2]) && s5_c2_0);
		wire s5_c3_1 = (s5_eb_lo[2] && s5_sub_msb[2]) || ((s5_eb_lo[2] ^ s5_sub_msb[2]) && s5_c2_1);
		wire s5_c4_0 = s5_g32 || (s5_p32 && s5_c2_0);
		wire s5_c4_1 = s5_g32 || (s5_p32 && s5_c2_1);

		wire [5:0] s5_er = {
			s5_c4_0 ? s5_eb_hi_p1[1:0] : s5_eb_hi[1:0],
			s5_eb_lo[3] ^ s5_sub_msb[3] ^ s5_c3_0,
			s5_eb_lo[2] ^ s5_sub_msb[2] ^ s5_c2_0,
			s5_eb_lo[1] ^ s5_sub_msb[1] ^ s5_c1_0,
			s5_eb_lo[0] ^ s5_sub_msb[0]
		};
		wire [5:0] s5_er_p1 = {
			s5_c4_1 ? s5_eb_hi_p1[1:0] : s5_eb_hi[1:0],
			s5_eb_lo[3] ^ s5_sub_msb[3] ^ s5_c3_1,
			s5_eb_lo[2] ^ s5_sub_msb[2] ^ s5_c2_1,
			s5_eb_lo[1] ^ s5_sub_msb[1] ^ s5_c1_1,
			~(s5_eb_lo[0] ^ s5_sub_msb[0])
		};
		wire s5_er0_en = s5_norm_ok && !(s5_c4_0 ? s5_eb_hi_p1[2] : s5_eb_hi[2]);
		wire s5_er1_en = s5_norm_ok && !(s5_c4_1 ? s5_eb_hi_p1[2] : s5_eb_hi[2]);
		wire s5_er_lo_all1 = &s5_msb_x_eb;
		wire s5_er_lo_zero = ~|s5_msb_x_neg;

		wire [1:0] s5_rm_mode =
			(s5_r == 3'd1 || (s5_r == 3'd2 && !s5_sr) || (s5_r == 3'd3 && s5_sr)) ? 2'd0 :
			((s5_r == 3'd2 && s5_sr) || (s5_r == 3'd3 && !s5_sr)) ? 2'd1 :
			(s5_r == 3'd4) ? 2'd2 : 2'd3;

		wire [15:0] s5_non_norm_raw = !s5_valid ? 16'd0 :
			s5_ovr_en ? s5_ovr_val :
			!s5_is_fma ? s5_other :
			s5_spec_hit ? s5_spec_res :
			(s5_sat ? 16'd0 : {s5_rdn, 15'd0});

		/* --- Stage 6 registers --- */
		(* shreg_extract = "no" *) reg [1:0]  s6_rm_mode;
		(* shreg_extract = "no" *) reg        s6_sat;
		(* shreg_extract = "no" *) reg [9:0]  s6_m;
		(* shreg_extract = "no" *) reg [5:0]  s6_er, s6_er_p1;
		(* shreg_extract = "no" *) reg        s6_er0_en, s6_er1_en;
		(* shreg_extract = "no" *) reg        s6_er_lo_all1, s6_er_lo_zero;
		(* shreg_extract = "no" *) reg        s6_trunc_ovf_en;
		(* shreg_extract = "no" *) reg        s6_g, s6_st;
		(* shreg_extract = "no" *) reg        s6_y15;
		(* shreg_extract = "no" *) reg [14:0] s6_non_norm;

		always @(posedge clk) begin
			if (rst_p) begin
				s6_rm_mode      <= 2'd0;
				s6_sat          <= 1'b0;
				s6_m            <= 10'd0;
				s6_er           <= 6'd0;
				s6_er_p1        <= 6'd0;
				s6_er0_en       <= 1'b0;
				s6_er1_en       <= 1'b0;
				s6_er_lo_all1   <= 1'b0;
				s6_er_lo_zero   <= 1'b0;
				s6_trunc_ovf_en <= 1'b0;
				s6_g            <= 1'b0;
				s6_st           <= 1'b0;
				s6_y15          <= 1'b0;
				s6_non_norm     <= 15'd0;
			end else begin
				s6_rm_mode      <= s5_rm_mode;
				s6_sat          <= s5_sat;
				s6_m            <= s5_m;
				s6_er           <= s5_er;
				s6_er_p1        <= s5_er_p1;
				s6_er0_en       <= s5_er0_en;
				s6_er1_en       <= s5_er1_en;
				s6_er_lo_all1   <= s5_er_lo_all1;
				s6_er_lo_zero   <= s5_er_lo_zero;
				s6_trunc_ovf_en <= s5_er0_en && !s5_sat && (s5_rm_mode == 2'd0);
				s6_g            <= s5_g;
				s6_st           <= s5_st;
				s6_y15          <= s5_use_norm ? (s5_sat ? 1'b0 : s5_sr) : s5_non_norm_raw[15];
				s6_non_norm     <= s5_use_norm ? 15'd0 : s5_non_norm_raw[14:0];
			end
		end

		/* =====================================================================
		 * Stage 6: Level-pinned 2-LUT rounding and output mux (0 CARRY4s)
		 * ===================================================================== */
		/* --- Level 1 (each wire <= 6 Stage-6 FF inputs -> 1 LUT6) --- */
		(* keep = "true" *) wire s6_up_l1 =
			(s6_rm_mode == 2'd0) ? 1'b0 :
			(s6_rm_mode == 2'd1) ? (s6_g || s6_st) :
			(s6_rm_mode == 2'd2) ? s6_g :
			                       (s6_g && (s6_st || s6_m[0]));
		(* keep = "true" *) wire s6_c1_l1 = s6_m[0] && (
			(s6_rm_mode == 2'd0) ? 1'b0 :
			(s6_rm_mode == 2'd1) ? (s6_g || s6_st) :
			(s6_rm_mode == 2'd2) ? s6_g :
			                       s6_g
		);
		(* keep = "true" *) wire s6_m31_all1_l1 = &s6_m[3:1];
		(* keep = "true" *) wire s6_m41_all1_l1 = &s6_m[4:1];
		(* keep = "true" *) wire s6_m51_all1_l1 = &s6_m[5:1];
		(* keep = "true" *) wire s6_m61_all1_l1 = &s6_m[6:1];
		(* keep = "true" *) wire s6_m87_all1_l1 = &s6_m[8:7];
		(* keep = "true" *) wire s6_m97_all1_l1 = &s6_m[9:7];

		(* keep = "true" *) wire s6_m_pass_l1 = s6_er0_en && !s6_er[5] &&
			(s6_sat ? (!s6_er[4] && !s6_er_lo_zero && !s6_er_lo_all1) :
			          (s6_er[4] ? !s6_er_lo_all1 : !s6_er_lo_zero));
		(* keep = "true" *) wire s6_ovf_trunc_l1 = s6_trunc_ovf_en && (s6_er[5] || (s6_er[4] && s6_er_lo_all1));

		(* keep = "true" *) wire [9:0] s6_m_fb_l1;
		for (gs = 0; gs < 10; gs = gs + 1) begin : g_m_fb_l1
			assign s6_m_fb_l1[gs] = s6_non_norm[gs] || (s6_trunc_ovf_en && (s6_er[5] || (s6_er[4] && s6_er_lo_all1)));
		end

		(* keep = "true" *) wire [14:10] s6_h0_l1, s6_h1_l1;
		assign s6_h0_l1[14] = s6_non_norm[14] || (s6_er0_en && !s6_sat && (s6_er[5] || s6_er[4]));
		assign s6_h1_l1[14] = s6_non_norm[14] || (s6_er1_en && !s6_sat && (s6_er_p1[5] || s6_er_p1[4]));
		for (gs = 0; gs < 4; gs = gs + 1) begin : g_h_l1
			assign s6_h0_l1[10 + gs] = s6_non_norm[10 + gs] || (s6_er0_en && (s6_er[5] || (s6_sat && s6_er[4]) || s6_er[gs]));
			assign s6_h1_l1[10 + gs] = s6_non_norm[10 + gs] || (s6_er1_en && (s6_er_p1[5] || (s6_sat && s6_er_p1[4]) || s6_er_p1[gs]));
		end

		/* --- Level 2 (each output bit y[14:0] <= 6 Level-1 inputs -> 1 LUT6) --- */
		assign y[0]  = s6_m_pass_l1 ? (s6_m[0] ^ s6_up_l1) : s6_m_fb_l1[0];
		assign y[1]  = s6_m_pass_l1 ? (s6_m[1] ^ s6_c1_l1) : s6_m_fb_l1[1];
		assign y[2]  = s6_m_pass_l1 ? (s6_m[2] ^ (s6_c1_l1 && s6_m[1])) : s6_m_fb_l1[2];
		assign y[3]  = s6_m_pass_l1 ? (s6_m[3] ^ (s6_c1_l1 && (&s6_m[2:1]))) : s6_m_fb_l1[3];
		assign y[4]  = s6_m_pass_l1 ? (s6_m[4] ^ (s6_c1_l1 && s6_m31_all1_l1)) : s6_m_fb_l1[4];
		assign y[5]  = s6_m_pass_l1 ? (s6_m[5] ^ (s6_c1_l1 && s6_m41_all1_l1)) : s6_m_fb_l1[5];
		assign y[6]  = s6_m_pass_l1 ? (s6_m[6] ^ (s6_c1_l1 && s6_m51_all1_l1)) : s6_m_fb_l1[6];
		assign y[7]  = s6_m_pass_l1 ? (s6_m[7] ^ (s6_c1_l1 && s6_m61_all1_l1)) : s6_m_fb_l1[7];
		assign y[8]  = s6_m_pass_l1 ? (s6_m[8] ^ (s6_c1_l1 && s6_m61_all1_l1 && s6_m[7])) : s6_m_fb_l1[8];
		assign y[9]  = s6_m_pass_l1 ? (s6_m[9] ^ (s6_c1_l1 && s6_m61_all1_l1 && s6_m87_all1_l1)) : s6_m_fb_l1[9];
		assign y[10] = (s6_c1_l1 && s6_m61_all1_l1 && s6_m97_all1_l1) ? s6_h1_l1[10] : (!s6_ovf_trunc_l1 && s6_h0_l1[10]);
		assign y[11] = (s6_c1_l1 && s6_m61_all1_l1 && s6_m97_all1_l1) ? s6_h1_l1[11] : s6_h0_l1[11];
		assign y[12] = (s6_c1_l1 && s6_m61_all1_l1 && s6_m97_all1_l1) ? s6_h1_l1[12] : s6_h0_l1[12];
		assign y[13] = (s6_c1_l1 && s6_m61_all1_l1 && s6_m97_all1_l1) ? s6_h1_l1[13] : s6_h0_l1[13];
		assign y[14] = (s6_c1_l1 && s6_m61_all1_l1 && s6_m97_all1_l1) ? s6_h1_l1[14] : s6_h0_l1[14];
		assign y[15] = s6_y15;

		wire unused_lat6 = &{1'b0, s4_prod[31:22], s1_co_unused, s1_ab_diff_unused, s1_ba_diff_unused,
			s2_bo_unused, s2_eb_c[9:7], s2_eb_t[9:7], s3_dp37[9:6], s4_bo_cp_unused};
	end
	endgenerate
endmodule

`default_nettype wire
