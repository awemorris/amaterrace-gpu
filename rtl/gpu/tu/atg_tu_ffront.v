/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_ffront: the front of atg_tu_ffilt's pipeline: a step (one
 * component of a lane's texel, issued by atg_tu_ffilt in cycle 0) to its
 * value and weight in cycle PV = 13.  P0 the texel's bits from the lane's
 * slots (as atg_tu_ffilt.md section 4); P1 the step's fields; P2-P5
 * atg_tu_etc (a block's texel, 4 cycles); P2-P7 the weight wu wv wa wb
 * (am_mul) and its fp32 n x 2^-32 rounded to nearest even (n > 0 for a
 * term); P6 the converter's inputs (a block's texel: RGBA8 as R8G8B8A8
 * UNORM or SRGB, EAC R11 and RG11 as two 11-bit UNORM components, the
 * signed ones as the magnitudes' 10-bit UNORM with the sign set, -0.0
 * for -1024); P6-P13 atg_fmt_cvt.  No stall; o_busy while a step is in
 * it.  The quad's constants (i_ifmt, i_blk, i_inf, i_sten) are those of
 * every pass of a quad.
 * See spec/gpu/tu/atg_tu_ffilt.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* rom_style = "distributed" *)
module atg_tu_ffront (
	input wire clk,
	input wire rst_n,
	/* The step (cycle 0) */
	input wire i_vld,
	input wire [1:0] i_op,
	input wire [1:0] i_cs,
	input wire [3:0] i_aid,
	input wire [1:0] i_t_slw,	/* the texel (for slw mux) */
	input wire [1:0] i_t_aux,	/* the texel (for t0_s/tb/es/et) */
	input wire [127:0] i_sl,	/* the lane's slots */
	input wire [3:0] i_bd,	/* their border bits */
	input wire [7:0] i_lo,	/* their address bits 1:0 */
	input wire [1:0] i_ft,
	input wire [31:0] i_wl,
	input wire i_bil,
	input wire i_p17,
	input wire i_p18,
	/* The quad's constants */
	input wire i_wg,	/* gather of a word of the texel */
	input wire [1:0] i_gwi,	/* that word */
	input wire i_b8,	/* 8-byte texels */
	input wire i_b16,	/* 16-byte texels */
	input wire [3:0] i_ifmt,
	input wire i_blk,
	input wire [67:0] i_inf,
	input wire i_sten,
	/* The step in cycle PV */
	output wire o_vld,
	output wire [11:0] o_meta_pre,	/* {op, cs, aid, tb, es, ers, egs} in cycle PV-1 */
	output wire [11:0] o_meta,	/* {op, cs, aid, tb, es, ers, egs} */
	output wire [31:0] o_up,
	output wire [31:0] o_wf,
	output wire o_busy
);
	`include "atg_fmt_info.vh"
	`include "atg_srgb.vh"
	integer i, m;
	wire u_e0_nc, u_e1_nc, u_neg_nc, u_ner_nc, u_rl_nc, u_ru_nc, u_rv_nc, u_rw_nc, u_wq_nc;
	(* dont_touch = "true" *) wire rst_inv = !rst_n;

	/* ---- P0: the texel's bits and border bit, its position in a block ---- */
	(* keep = "true" *) wire [1:0] t_slw_lo = i_t_slw;
	(* keep = "true" *) wire [1:0] t_slw_hi = i_t_slw;
	(* keep = "true" *) wire [31:0] slw = {
		i_sl[{t_slw_hi, 5'd16} +: 16],
		i_sl[{t_slw_lo, 5'd0} +: 16]
	};
	(* keep = "true" *) wire [7:0] wg_s  = {8{i_wg}};
	(* keep = "true" *) wire [7:0] b8_s  = {8{i_b8}};
	(* keep = "true" *) wire [7:0] b16_s = {8{i_b16}};
	(* keep = "true" *) wire [7:0] t0_s  = {8{i_t_aux[0]}};
	(* keep = "true" *) wire [15:0] gwi_s = {8{i_gwi}};
	reg [127:0] raw_i;
	always @(*) begin
		for (i = 0; i < 8; i = i + 1) begin
			if (wg_s[i]) begin
				if (i[2:1] == gwi_s[i*2 +: 2])
					raw_i[i*16 +: 16] = slw[i[0]*16 +: 16];
				else
					raw_i[i*16 +: 16] = 16'd0;
			end else if (b8_s[i]) begin
				if (i < 4)
					raw_i[i*16 +: 16] = t0_s[i] ? i_sl[64 + i*16 +: 16] : i_sl[i*16 +: 16];
				else
					raw_i[i*16 +: 16] = 16'd0;
			end else if (b16_s[i]) begin
				raw_i[i*16 +: 16] = i_sl[i*16 +: 16];
			end else begin
				if (i < 2)
					raw_i[i*16 +: 16] = slw[i*16 +: 16];
				else
					raw_i[i*16 +: 16] = 16'd0;
			end
		end
	end
	wire tb_i = i_wg || !(i_b8 || i_b16) ? i_bd[i_t_aux] : i_b8 && i_t_aux[0] ? i_bd[2] : i_bd[0];
	wire [1:0] es_i = i_b16 || !i_t_aux[0] ? i_lo[1:0] : i_lo[5:4];
	wire [1:0] et_i = i_b16 || !i_t_aux[0] ? i_lo[3:2] : i_lo[7:6];

	/* ---- P1 ---- */
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] op1, cs1;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] aid1;
	(* extract_reset = "no", max_fanout = 16 *) reg tb1;
	(* extract_reset = "no", max_fanout = 16 *) reg [127:0] raw1;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] es1, et1, ft1;
	(* extract_reset = "no", max_fanout = 16 *) reg [31:0] wl1;	/* the lane's {fw, fl, fv, fu} */
	(* extract_reset = "no", max_fanout = 16 *) reg bil1, p17_1, p18_1;
	always @(posedge clk) begin
		op1 <= i_op;
		aid1 <= i_aid;
		cs1 <= i_cs;
		tb1 <= tb_i;
		raw1 <= raw_i;
		es1 <= es_i;
		et1 <= et_i;
		ft1 <= i_ft;
		wl1 <= i_wl;
		bil1 <= i_bil;
		p17_1 <= i_p17;
		p18_1 <= i_p18;
	end

	/* ---- P1 → PE: the block decode (atg_tu_etc); the weight's factors ---- */
	wire [1:0] e_kind;
	wire [31:0] e_tx;

	atg_tu_etc etc (
		.clk(clk), .i_fmt(i_ifmt), .i_block(raw1), .i_s(es1), .i_t(et1), .o_kind(e_kind),
		.o_texel(e_tx)
	);

	wire [8:0] ru, rv, rw, rl;

	am_sub #(.W(9)) u_ru (.a(9'd256), .b({1'b0, wl1[7:0]}), .bi(1'b0), .d(ru), .bo(u_ru_nc));
	am_sub #(.W(9)) u_rv (.a(9'd256), .b({1'b0, wl1[15:8]}), .bi(1'b0), .d(rv), .bo(u_rv_nc));
	am_sub #(.W(9)) u_rl (.a(9'd256), .b({1'b0, wl1[23:16]}), .bi(1'b0), .d(rl), .bo(u_rl_nc));
	am_sub #(.W(9)) u_rw (.a(9'd256), .b({1'b0, wl1[31:24]}), .bi(1'b0), .d(rw), .bo(u_rw_nc));

	(* extract_reset = "no" *) reg [8:0] wu2, wv2, wa2, wb2;
	always @(posedge clk) begin
		/* (the texel of an issued term is present) */
		wu2 <= !bil1 ? 9'd256 : ft1[0] ? {1'b0, wl1[7:0]} : ru;
		wv2 <= !bil1 ? 9'd256 : ft1[1] ? {1'b0, wl1[15:8]} : rv;
		wa2 <= p17_1 ? {1'b0, wl1[31:24]} : rw;
		wb2 <= p18_1 ? {1'b0, wl1[23:16]} : rl;
	end

	/* ---- The step's fields along the pipeline: {op, cs, aid, tb, raw}
	 * from P1 to PE (atg_tu_etc's output), {op, cs, aid, tb, es, ers, egs}
	 * from PC (atg_fmt_cvt's input) to PV (its output) ---- */
	localparam ETC_LAT = 4, CVT_LAT = 7;
	localparam PE = 1 + ETC_LAT, PC = PE + 1, PV = PC + CVT_LAT;
	wire [136:0] fe1 = {op1, cs1, aid1, tb1, raw1};
	(* extract_reset = "no", shreg_extract = "no", max_fanout = 16 *) reg [136:0] fe [2:PE];
	always @(posedge clk) begin
		fe[2] <= fe1;
		for (m = 3; m <= PE; m = m + 1)
			fe[m] <= fe[m - 1];
	end
	wire [1:0] ope = fe[PE][136:135], cse = fe[PE][134:133];
	wire [3:0] aide = fe[PE][132:129];
	wire tbe = fe[PE][128];
	wire [127:0] rawe = fe[PE][127:0];

	/* ---- PE → PC: the converter's inputs.  A block's texel: RGBA8 as
	 * R8G8B8A8_UNORM or _SRGB; EAC R11 and RG11 as two 11-bit UNORM
	 * components (the second 0 for R11), the signed ones as the
	 * magnitudes' 10-bit UNORM with the sign set (-0.0 for -1024); the
	 * components the block does not have (0, 0, 1.0). ---- */
	wire [10:0] er = e_tx[10:0], eg = e_tx[26:16];
	wire [10:0] ner, neg_g;

	am_sub #(.W(11)) u_ner (.a(11'd0), .b(er), .bi(1'b0), .d(ner), .bo(u_ner_nc));
	am_sub #(.W(11)) u_neg (.a(11'd0), .b(eg), .bi(1'b0), .d(neg_g), .bo(u_neg_nc));

	wire [10:0] ear = er[10] ? ner : er, eag = eg[10] ? neg_g : eg;
	(* keep = "true" *) wire [1:0] ek_s0 = e_kind;
	(* keep = "true" *) wire [1:0] ek_s1 = e_kind;
	(* keep = "true" *) wire [1:0] ek_s2 = e_kind;
	(* keep = "true" *) wire [1:0] ek_s3 = e_kind;
	wire esgn = ek_s0 == 2'd3;	/* signed EAC */
	(* keep = "true" *) wire esgn_raw_lo = (ek_s0 == 2'd3);
	(* keep = "true" *) wire esgn_raw_hi = (ek_s1 == 2'd3);
	(* keep = "true" *) wire esgn_inf_lo = (ek_s2 == 2'd3);
	(* keep = "true" *) wire esgn_inf_hi = (ek_s3 == 2'd3);
	wire [67:0] e_inf_s2 = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd16, 6'd10), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0));
	wire [67:0] e_inf_u2 = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd11), atg_fmt_c(7'd16, 6'd11), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0));
	wire [67:0] e_inf_43 = atg_fmt_info(8'd43);
	wire [67:0] e_inf_37 = atg_fmt_info(8'd37);
	wire [67:0] e_inf = {
		ek_s3[1] ? (esgn_inf_hi ? e_inf_s2[67:34] : e_inf_u2[67:34]) : ek_s3[0] ? e_inf_43[67:34] : e_inf_37[67:34],
		ek_s2[1] ? (esgn_inf_lo ? e_inf_s2[33:0]  : e_inf_u2[33:0])  : ek_s2[0] ? e_inf_43[33:0]  : e_inf_37[33:0]
	};
	wire [127:0] e_raw = {
		96'd0,
		esgn_raw_hi ? {5'd0, eag} : e_tx[31:16],
		esgn_raw_lo ? {5'd0, ear} : e_tx[15:0]
	};

	(* keep = "true" *) wire [1:0] blk_g = {2{i_blk}};
	(* keep = "true" *) wire [7:0] blk_raw_s = {4{blk_g[1], blk_g[0]}};
	(* keep = "true" *) wire [4:0] blk_inf_s = {5{blk_g[0]}};

	(* extract_reset = "no", max_fanout = 16 *) reg [127:0] crawc;
	(* extract_reset = "no", max_fanout = 16 *) reg [67:0] cinfc;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] ckc;
	(* extract_reset = "no", max_fanout = 16 *) reg cstenc;
	(* extract_reset = "no", max_fanout = 16 *) reg [11:0] mc;	/* {op, cs, aid, tb, es, ers, egs} */
	always @(posedge clk) begin
		for (i = 0; i < 8; i = i + 1)
			crawc[i*16 +: 16] <= blk_raw_s[i] ? e_raw[i*16 +: 16] : rawe[i*16 +: 16];
		for (i = 0; i < 4; i = i + 1)
			cinfc[i*16 +: 16] <= blk_inf_s[i] ? e_inf[i*16 +: 16] : i_inf[i*16 +: 16];
		cinfc[67:64] <= blk_inf_s[4] ? e_inf[67:64] : i_inf[67:64];
		ckc <= cse;
		cstenc <= i_sten && !blk_g[1];
		mc <= {ope, cse, aide, tbe, esgn, er[10], eg[10]};
	end

	/* ---- PC → PV: the component (inlined atg_fmt_cvt with 3-LUT st4 sticky bit) ---- */
	wire [31:0] upv;

	generate
	if (1) begin : cvt
		wire [127:0] i_raw = crawc;
		wire [67:0]  i_inf = cinfc;
		wire [1:0]   i_k   = ckc;
		wire         i_sten_c = cstenc;
		(* extract_reset = "no" *) reg  [31:0]  o_val;
		assign upv = o_val;

		wire u_neg_c_nc, u_wm1_nc, u_e5b_nc, u_hexp_nc, u_hden_nc, u_e5x_nc, u_q_nc, u_e127_nc,
			u_e126_nc;
		integer ci_idx;

		localparam [2:0] K_CST = 3'd0, K_DIR = 3'd1, K_UN = 3'd2, K_SN = 3'd3, K_HF = 3'd4,
			K_E5 = 3'd5;

		/* ---- U1 ---- */
		(* keep = "true" *) wire [1:0] k_cval = i_k;
		(* keep = "true" *) wire [1:0] k_wp = i_k;

		wire [2:0] ty = i_inf[11:9];
		wire isint = ty == ATG_FMT_UINT || ty == ATG_FMT_SINT;
		reg cst_u1;
		reg [31:0] cval_u1;
		reg [6:0] pos;
		reg [5:0] w_u1;
		always @(*) begin
			cst_u1 = 1'b1;
			if (!i_inf[0] || i_inf[14])
				cval_u1 = k_cval == 2'd3 ? 32'h3F800000 : 32'd0;
			else if (i_sten_c)
				cval_u1 = k_cval == 2'd3 ? (i_inf[13] ? 32'd1 : 32'h3F800000) :
					k_cval == 2'd0 && i_inf[13] ? {24'd0, i_raw[31:24]} : 32'd0;
			else if ({1'b0, k_cval} >= i_inf[8:6])
				cval_u1 = k_cval == 2'd3 ? (isint ? 32'd1 : 32'h3F800000) : 32'd0;
			else begin
				cval_u1 = 32'd0;
				cst_u1 = 1'b0;
			end
			case (k_wp)
			2'd0: {w_u1, pos} = i_inf[28:16];
			2'd1: {w_u1, pos} = i_inf[41:29];
			2'd2: {w_u1, pos} = i_inf[54:42];
			default: {w_u1, pos} = i_inf[67:55];
			endcase
		end

		(* keep = "true" *) wire [2:0] cpos_0a = pos[6:4];
		(* keep = "true" *) wire [2:0] cpos_0b = pos[6:4];
		(* keep = "true" *) wire [2:0] cpos_1a = pos[6:4];
		(* keep = "true" *) wire [2:0] cpos_1b = pos[6:4];
		(* keep = "true" *) wire [2:0] cpos_2a = pos[6:4];
		(* keep = "true" *) wire [2:0] cpos_2b = pos[6:4];

		reg [7:0] raw_w0_lo, raw_w0_hi;
		reg [7:0] raw_w1_lo, raw_w1_hi;
		reg [7:0] raw_w2_lo, raw_w2_hi;

		always @(*) begin
			case (cpos_0a)
			3'd0: raw_w0_lo = i_raw[7:0];
			3'd1: raw_w0_lo = i_raw[23:16];
			3'd2: raw_w0_lo = i_raw[39:32];
			3'd3: raw_w0_lo = i_raw[55:48];
			3'd4: raw_w0_lo = i_raw[71:64];
			3'd5: raw_w0_lo = i_raw[87:80];
			3'd6: raw_w0_lo = i_raw[103:96];
			default: raw_w0_lo = i_raw[119:112];
			endcase

			case (cpos_0b)
			3'd0: raw_w0_hi = i_raw[15:8];
			3'd1: raw_w0_hi = i_raw[31:24];
			3'd2: raw_w0_hi = i_raw[47:40];
			3'd3: raw_w0_hi = i_raw[63:56];
			3'd4: raw_w0_hi = i_raw[79:72];
			3'd5: raw_w0_hi = i_raw[95:88];
			3'd6: raw_w0_hi = i_raw[111:104];
			default: raw_w0_hi = i_raw[127:120];
			endcase

			case (cpos_1a)
			3'd0: raw_w1_lo = i_raw[23:16];
			3'd1: raw_w1_lo = i_raw[39:32];
			3'd2: raw_w1_lo = i_raw[55:48];
			3'd3: raw_w1_lo = i_raw[71:64];
			3'd4: raw_w1_lo = i_raw[87:80];
			3'd5: raw_w1_lo = i_raw[103:96];
			3'd6: raw_w1_lo = i_raw[119:112];
			default: raw_w1_lo = 8'd0;
			endcase

			case (cpos_1b)
			3'd0: raw_w1_hi = i_raw[31:24];
			3'd1: raw_w1_hi = i_raw[47:40];
			3'd2: raw_w1_hi = i_raw[63:56];
			3'd3: raw_w1_hi = i_raw[79:72];
			3'd4: raw_w1_hi = i_raw[95:88];
			3'd5: raw_w1_hi = i_raw[111:104];
			3'd6: raw_w1_hi = i_raw[127:120];
			default: raw_w1_hi = 8'd0;
			endcase

			case (cpos_2a)
			3'd0: raw_w2_lo = i_raw[39:32];
			3'd1: raw_w2_lo = i_raw[55:48];
			3'd2: raw_w2_lo = i_raw[71:64];
			3'd3: raw_w2_lo = i_raw[87:80];
			3'd4: raw_w2_lo = i_raw[103:96];
			3'd5: raw_w2_lo = i_raw[119:112];
			default: raw_w2_lo = 8'd0;
			endcase

			case (cpos_2b)
			3'd0: raw_w2_hi = i_raw[47:40];
			3'd1: raw_w2_hi = i_raw[63:56];
			3'd2: raw_w2_hi = i_raw[79:72];
			3'd3: raw_w2_hi = i_raw[95:88];
			3'd4: raw_w2_hi = i_raw[111:104];
			3'd5: raw_w2_hi = i_raw[127:120];
			default: raw_w2_hi = 8'd0;
			endcase
		end

		wire [15:0] raw_w0 = {raw_w0_hi, raw_w0_lo};
		wire [15:0] raw_w1 = {raw_w1_hi, raw_w1_lo};
		wire [15:0] raw_w2 = {raw_w2_hi, raw_w2_lo};
		wire [47:0] raw_win = {raw_w2, raw_w1, raw_w0};

		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg cst0_0, cst0_1, cst0_2, cst0_3, cst0_k;
		(* extract_reset = "no" *) reg [31:0] cval0;
		(* extract_reset = "no", ram_style = "registers" *) reg [31:0] raw0_s0, raw0_s1, raw0_s2, raw0_s3;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [3:0] pos0_0, pos0_1, pos0_2, pos0_3;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [5:0] w0_0, w0_1, w0_2, w0_3;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [2:0] ty0_0, ty0_1, ty0_2, ty0_3, ty0_k;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [2:0] ty0_sn0, ty0_sn1, ty0_sn2, ty0_uw, ty0_snmin;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [1:0] k0_0, k0_1, k0_2, k0_3;
		(* extract_reset = "no" *) reg [4:0] e5e0;
		always @(posedge clk) begin
			cst0_0 <= cst_u1;
			cst0_1 <= cst_u1;
			cst0_2 <= cst_u1;
			cst0_3 <= cst_u1;
			cst0_k <= cst_u1;
			cval0 <= cval_u1;
			raw0_s0 <= raw_win[31:0];
			raw0_s1 <= raw_win[39:8];
			raw0_s2 <= raw_win[47:16];
			raw0_s3 <= {8'd0, raw_win[47:24]};
			pos0_0 <= pos[3:0];
			pos0_1 <= pos[3:0];
			pos0_2 <= pos[3:0];
			pos0_3 <= pos[3:0];
			w0_0 <= w_u1;
			w0_1 <= w_u1;
			w0_2 <= w_u1;
			w0_3 <= w_u1;
			ty0_0 <= ty;
			ty0_1 <= ty;
			ty0_2 <= ty;
			ty0_3 <= ty;
			ty0_k <= ty;
			ty0_sn0 <= ty;
			ty0_sn1 <= ty;
			ty0_sn2 <= ty;
			ty0_uw <= ty;
			ty0_snmin <= ty;
			k0_0 <= i_k;
			k0_1 <= i_k;
			k0_2 <= i_k;
			k0_3 <= i_k;
			e5e0 <= i_raw[31:27];
		end

		/* ---- U1b: the field ---- */
		wire [7:0] fsel_0 = raw0_s0[{1'b0, pos0_0} +: 8];
		wire [7:0] fsel_1 = raw0_s1[{1'b0, pos0_1} +: 8];
		wire [7:0] fsel_2 = raw0_s2[{1'b0, pos0_2} +: 8];
		wire [7:0] fsel_3 = raw0_s3[{1'b0, pos0_3} +: 8];

		reg [7:0] msk_u1_0, msk_u1_1, msk_u1_2, msk_u1_3;
		always @(*) begin
			for (ci_idx = 0; ci_idx < 8; ci_idx = ci_idx + 1)
				msk_u1_0[ci_idx] = ci_idx[5:0] < w0_0;
			for (ci_idx = 8; ci_idx < 16; ci_idx = ci_idx + 1)
				msk_u1_1[ci_idx - 8] = ci_idx[5:0] < w0_1;
			for (ci_idx = 16; ci_idx < 24; ci_idx = ci_idx + 1)
				msk_u1_2[ci_idx - 16] = ci_idx[5:0] < w0_2;
			for (ci_idx = 24; ci_idx < 32; ci_idx = ci_idx + 1)
				msk_u1_3[ci_idx - 24] = ci_idx[5:0] < w0_3;
		end

		wire [15:0] fsel_lo = {fsel_1, fsel_0};
		wire [15:0] fsel_hi = {fsel_3, fsel_2};
		wire [15:0] msk_u1_lo = {msk_u1_1, msk_u1_0};
		wire [15:0] msk_u1_hi = {msk_u1_3, msk_u1_2};

		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg cst1_0, cst1_1, cst1_2, cst1_3, cst1_k;
		(* extract_reset = "no" *) reg [31:0] cval1;
		(* extract_reset = "no", ram_style = "registers" *) reg [15:0] fld1_lo;
		(* extract_reset = "no", ram_style = "registers" *) reg [15:0] fld1_hi;
		(* extract_reset = "no", ram_style = "registers", keep = "true", equivalent_register_removal = "no" *) reg [7:0] fld1_srgb_0, fld1_srgb_1, fld1_srgb_2, fld1_srgb_3, fld1_srgb_4, fld1_srgb_5, fld1_srgb_6, fld1_srgb_7;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [5:0] w1_msk_lo, w1_msk_hi;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [5:0] w1_ctrl_a;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [5:0] w1_ctrl_b_lo, w1_ctrl_b_hi;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [2:0] ty1_0, ty1_1, ty1_2, ty1_3, ty1_k;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [2:0] ty1_sn0, ty1_sn1, ty1_sn2, ty1_uw, ty1_snmin;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [1:0] k1_0, k1_1, k1_2, k1_3;
		(* extract_reset = "no" *) reg [4:0] e5e1;
		always @(posedge clk) begin
			cst1_0 <= cst0_0;
			cst1_1 <= cst0_1;
			cst1_2 <= cst0_2;
			cst1_3 <= cst0_3;
			cst1_k <= cst0_k;
			cval1 <= cval0;
			fld1_lo <= fsel_lo & msk_u1_lo;
			fld1_hi <= fsel_hi & msk_u1_hi;
			fld1_srgb_0 <= fsel_0 & msk_u1_0;
			fld1_srgb_1 <= fsel_0 & msk_u1_0;
			fld1_srgb_2 <= fsel_0 & msk_u1_0;
			fld1_srgb_3 <= fsel_0 & msk_u1_0;
			fld1_srgb_4 <= fsel_0 & msk_u1_0;
			fld1_srgb_5 <= fsel_0 & msk_u1_0;
			fld1_srgb_6 <= fsel_0 & msk_u1_0;
			fld1_srgb_7 <= fsel_0 & msk_u1_0;
			w1_msk_lo <= w0_0;
			w1_msk_hi <= w0_2;
			w1_ctrl_a <= w0_1;
			w1_ctrl_b_lo <= w0_3;
			w1_ctrl_b_hi <= w0_3;
			ty1_0 <= ty0_0;
			ty1_1 <= ty0_1;
			ty1_2 <= ty0_2;
			ty1_3 <= ty0_3;
			ty1_k <= ty0_k;
			ty1_sn0 <= ty0_sn0;
			ty1_sn1 <= ty0_sn1;
			ty1_sn2 <= ty0_sn2;
			ty1_uw <= ty0_uw;
			ty1_snmin <= ty0_snmin;
			k1_0 <= k0_0;
			k1_1 <= k0_1;
			k1_2 <= k0_2;
			k1_3 <= k0_3;
			e5e1 <= e5e0;
		end

		/* ---- U2 ---- */
		wire [31:0] fld1 = {fld1_hi, fld1_lo};
		wire w8_a = w1_ctrl_a == 6'd8;
		wire w8_b = w1_ctrl_a == 6'd8;
		wire neg_0 = w8_a ? fld1_lo[7] : fld1_lo[15];
		wire neg_1 = w8_b ? fld1_lo[7] : fld1_lo[15];
		wire neg_reg = w8_a ? fld1_lo[7] : fld1_lo[15];
		wire [15:0] n16;

		am_sub #(.W(16)) u_neg (.a(16'd0), .b(fld1_lo), .bi(1'b0), .d(n16), .bo(u_neg_c_nc));

		(* keep = "true" *) wire sn_neg_lo = (ty1_sn0 == ATG_FMT_SNORM) && neg_0;
		(* keep = "true" *) wire sn_neg_hi = (ty1_sn0 == ATG_FMT_SNORM) && neg_0;
		(* keep = "true" *) wire sn_neg_1  = (ty1_sn1 == ATG_FMT_SNORM) && neg_1;

		wire [3:0] uc_0_lo = sn_neg_lo ? n16[3:0] : fld1_lo[3:0];
		wire [3:0] uc_0_hi = sn_neg_hi ? n16[7:4] : fld1_lo[7:4];
		wire [7:0] uc_0 = {uc_0_hi, uc_0_lo};

		wire sn_2 = ty1_sn2 == ATG_FMT_SNORM;
		wire sn_uw = ty1_uw == ATG_FMT_SNORM;
		wire sn_min = ty1_snmin == ATG_FMT_SNORM;
		wire [5:0] wm1;

		am_sub #(.W(6)) u_wm1 (.a(w1_ctrl_a), .b(6'd1), .bi(1'b0), .d(wm1), .bo(u_wm1_nc));

		wire [7:0] uc_1 = sn_neg_1 ? (w8_b ? 8'd0 : n16[15:8]) : fld1_lo[15:8];
		wire [7:0] uc_2 = sn_2 ? 8'd0 : fld1_hi[7:0];
		(* keep = "true" *) wire [23:0] uc = {uc_2, uc_1, uc_0};

		wire [5:0] uw = sn_uw ? wm1 : ty1_uw == ATG_FMT_SRGB ? 6'd8 : w1_ctrl_a;
		wire snmin = sn_min && (w8_a ? (fld1_lo[7:0] == 8'h80) : (fld1_lo == 16'h8000));
		wire [4:0] he = ty1_k == ATG_FMT_SFLOAT ? fld1[14:10] : w1_ctrl_a == 6'd11 ? fld1[10:6] : fld1[9:5];
		wire [9:0] x = ty1_k == ATG_FMT_SFLOAT ? fld1[9:0] : ty1_k == ATG_FMT_UFLOAT ?
			(w1_ctrl_a == 6'd11 ? {fld1[5:0], 4'd0} : {fld1[4:0], 5'd0}) : {1'b0, fld1[8:0]};
		wire hs = ty1_k == ATG_FMT_SFLOAT && fld1[15];
		wire [32:0] fx = {fld1, 1'b0};
		reg [15:0] msk2_lo;
		reg [15:0] msk2_hi;
		always @(*) begin
			for (ci_idx = 0; ci_idx < 16; ci_idx = ci_idx + 1)
				msk2_lo[ci_idx] = ci_idx[5:0] < w1_msk_lo;
			for (ci_idx = 16; ci_idx < 32; ci_idx = ci_idx + 1)
				msk2_hi[ci_idx - 16] = ci_idx[5:0] < w1_msk_hi;
		end
		wire [15:0] sint_lo = fld1_lo | (fx[w1_ctrl_b_lo] ? ~msk2_lo : 16'd0);
		wire [15:0] sint_hi = fld1_hi | (fx[w1_ctrl_b_hi] ? ~msk2_hi : 16'd0);

		(* rom_style = "distributed" *) wire [31:0] srgb_0 = atg_srgb_dec(fld1_srgb_0);
		(* rom_style = "distributed" *) wire [31:0] srgb_1 = atg_srgb_dec(fld1_srgb_1);
		(* rom_style = "distributed" *) wire [31:0] srgb_2 = atg_srgb_dec(fld1_srgb_2);
		(* rom_style = "distributed" *) wire [31:0] srgb_3 = atg_srgb_dec(fld1_srgb_3);
		(* rom_style = "distributed" *) wire [31:0] srgb_4 = atg_srgb_dec(fld1_srgb_4);
		(* rom_style = "distributed" *) wire [31:0] srgb_5 = atg_srgb_dec(fld1_srgb_5);
		(* rom_style = "distributed" *) wire [31:0] srgb_6 = atg_srgb_dec(fld1_srgb_6);
		(* rom_style = "distributed" *) wire [31:0] srgb_7 = atg_srgb_dec(fld1_srgb_7);

		wire [31:0] srgb_val = {srgb_7[31:28], srgb_6[27:24], srgb_5[23:20], srgb_4[19:16],
			srgb_3[15:12], srgb_2[11:8], srgb_1[7:4], srgb_0[3:0]};

		reg [2:0] kind_u2;
		reg [7:0] dir_u2_0, dir_u2_1, dir_u2_2, dir_u2_3;
		always @(*) begin
			kind_u2 = K_DIR;
			if (cst1_k) begin
				kind_u2 = K_CST;
			end else
				case (ty1_k)
				ATG_FMT_UNORM: kind_u2 = K_UN;
				ATG_FMT_SNORM: kind_u2 = K_SN;
				ATG_FMT_UINT: ;
				ATG_FMT_SINT: ;
				ATG_FMT_SFLOAT: kind_u2 = w1_ctrl_a == 6'd32 ? K_DIR : K_HF;
				ATG_FMT_SRGB:
					if (k1_3 == 2'd3)
						kind_u2 = K_UN;
				ATG_FMT_UFLOAT: kind_u2 = K_HF;
				default: kind_u2 = K_E5;
				endcase

			if (cst1_0)
				dir_u2_0 = cval1[7:0];
			else
				case (ty1_0)
				ATG_FMT_UINT: dir_u2_0 = fld1_lo[7:0];
				ATG_FMT_SINT: dir_u2_0 = sint_lo[7:0];
				ATG_FMT_SRGB:
					if (k1_0 != 2'd3)
						dir_u2_0 = srgb_val[7:0];
					else
						dir_u2_0 = fld1_lo[7:0];
				default: dir_u2_0 = fld1_lo[7:0];
				endcase

			if (cst1_1)
				dir_u2_1 = cval1[15:8];
			else
				case (ty1_1)
				ATG_FMT_UINT: dir_u2_1 = fld1_lo[15:8];
				ATG_FMT_SINT: dir_u2_1 = sint_lo[15:8];
				ATG_FMT_SRGB:
					if (k1_1 != 2'd3)
						dir_u2_1 = srgb_val[15:8];
					else
						dir_u2_1 = fld1_lo[15:8];
				default: dir_u2_1 = fld1_lo[15:8];
				endcase

			if (cst1_2)
				dir_u2_2 = cval1[23:16];
			else
				case (ty1_2)
				ATG_FMT_UINT: dir_u2_2 = fld1_hi[7:0];
				ATG_FMT_SINT: dir_u2_2 = sint_hi[7:0];
				ATG_FMT_SRGB:
					if (k1_2 != 2'd3)
						dir_u2_2 = srgb_val[23:16];
					else
						dir_u2_2 = fld1_hi[7:0];
				default: dir_u2_2 = fld1_hi[7:0];
				endcase

			if (cst1_3)
				dir_u2_3 = cval1[31:24];
			else
				case (ty1_3)
				ATG_FMT_UINT: dir_u2_3 = fld1_hi[15:8];
				ATG_FMT_SINT: dir_u2_3 = sint_hi[15:8];
				ATG_FMT_SRGB:
					if (k1_3 != 2'd3)
						dir_u2_3 = srgb_val[31:24];
					else
						dir_u2_3 = fld1_hi[15:8];
				default: dir_u2_3 = fld1_hi[15:8];
				endcase
		end
		wire [7:0] e5b;

		am_add #(.W(8)) u_e5b (.a(8'd112), .b({3'd0, e5e1}), .ci(1'b0), .s(e5b), .co(u_e5b_nc));

		reg [3:0] uw_code_u2;
		always @(*)
			case (uw)
			6'd1: uw_code_u2 = 4'd1;
			6'd2: uw_code_u2 = 4'd2;
			6'd4: uw_code_u2 = 4'd3;
			6'd5: uw_code_u2 = 4'd4;
			6'd6: uw_code_u2 = 4'd5;
			6'd7: uw_code_u2 = 4'd6;
			6'd8: uw_code_u2 = 4'd7;
			6'd10: uw_code_u2 = 4'd8;
			6'd11: uw_code_u2 = 4'd9;
			6'd15: uw_code_u2 = 4'd10;
			6'd16: uw_code_u2 = 4'd11;
			default: uw_code_u2 = 4'd0;
			endcase

		(* extract_reset = "no", max_fanout = 16 *) reg [2:0] kind2;
		(* extract_reset = "no", keep = "true" *) reg [7:0] dir2_0, dir2_1, dir2_2, dir2_3;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [23:0] uc2_0, uc2_1, uc2_2, uc2_3, uc2_4, uc2_5, uc2_6, uc2_7;
		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [3:0] uw_code2_0, uw_code2_1, uw_code2_2, uw_code2_3, uw_code2_4, uw_code2_5, uw_code2_6, uw_code2_7, uw_code2_8, uw_code2_9, uw_code2_10, uw_code2_11, uw_code2_12, uw_code2_13, uw_code2_14, uw_code2_15;
		(* extract_reset = "no" *) reg neg2, snmin2, hs2;
		(* extract_reset = "no" *) reg [4:0] he2;
		(* extract_reset = "no" *) reg [9:0] x2;
		(* extract_reset = "no" *) reg [7:0] e5b2;
		always @(posedge clk) begin
			kind2 <= kind_u2;
			dir2_0 <= dir_u2_0;
			dir2_1 <= dir_u2_1;
			dir2_2 <= dir_u2_2;
			dir2_3 <= dir_u2_3;
			uc2_0 <= uc;
			uc2_1 <= uc;
			uc2_2 <= uc;
			uc2_3 <= uc;
			uc2_4 <= uc;
			uc2_5 <= uc;
			uc2_6 <= uc;
			uc2_7 <= uc;
			uw_code2_0 <= uw_code_u2;
			uw_code2_1 <= uw_code_u2;
			uw_code2_2 <= uw_code_u2;
			uw_code2_3 <= uw_code_u2;
			uw_code2_4 <= uw_code_u2;
			uw_code2_5 <= uw_code_u2;
			uw_code2_6 <= uw_code_u2;
			uw_code2_7 <= uw_code_u2;
			uw_code2_8 <= uw_code_u2;
			uw_code2_9 <= uw_code_u2;
			uw_code2_10 <= uw_code_u2;
			uw_code2_11 <= uw_code_u2;
			uw_code2_12 <= uw_code_u2;
			uw_code2_13 <= uw_code_u2;
			uw_code2_14 <= uw_code_u2;
			uw_code2_15 <= uw_code_u2;
			neg2 <= neg_reg;
			snmin2 <= snmin;
			he2 <= he;
			x2 <= x;
			hs2 <= hs;
			e5b2 <= e5b;
		end

		/* ---- U3 ---- */
		function [79:0] calc_r;
			input [3:0] code;
			input [23:0] u;
			case (code)
			4'd1: calc_r = {80{u[0]}};
			4'd2: calc_r = {40{u[1:0]}};
			4'd3: calc_r = {20{u[3:0]}};
			4'd4: calc_r = {16{u[4:0]}};
			4'd5: calc_r = {u[5:0], {12{u[5:0]}}, u[5:4]};
			4'd6: calc_r = {u[6:0], {10{u[6:0]}}, u[6:4]};
			4'd7: calc_r = {10{u[7:0]}};
			4'd8: calc_r = {8{u[9:0]}};
			4'd9: calc_r = {u[10:0], {6{u[10:0]}}, u[10:8]};
			4'd10: calc_r = {u[14:0], {4{u[14:0]}}, u[14:10]};
			4'd11: calc_r = {5{u[15:0]}};
			default: calc_r = {u, u, u, u[23:16]};
			endcase
		endfunction

		wire [79:0] r_full_0  = calc_r(uw_code2_0,  uc2_0);
		wire [79:0] r_full_1  = calc_r(uw_code2_1,  uc2_0);
		wire [79:0] r_full_2  = calc_r(uw_code2_2,  uc2_1);
		wire [79:0] r_full_3  = calc_r(uw_code2_3,  uc2_1);
		wire [79:0] r_full_4  = calc_r(uw_code2_4,  uc2_2);
		wire [79:0] r_full_5  = calc_r(uw_code2_5,  uc2_2);
		wire [79:0] r_full_6  = calc_r(uw_code2_6,  uc2_3);
		wire [79:0] r_full_7  = calc_r(uw_code2_7,  uc2_3);
		wire [79:0] r_full_8  = calc_r(uw_code2_8,  uc2_4);
		wire [79:0] r_full_9  = calc_r(uw_code2_9,  uc2_4);
		wire [79:0] r_full_10 = calc_r(uw_code2_10, uc2_5);
		wire [79:0] r_full_11 = calc_r(uw_code2_11, uc2_5);
		wire [79:0] r_full_12 = calc_r(uw_code2_12, uc2_6);
		wire [79:0] r_full_13 = calc_r(uw_code2_13, uc2_6);
		wire [79:0] r_full_14 = calc_r(uw_code2_14, uc2_7);
		wire [79:0] r_full_15 = calc_r(uw_code2_15, uc2_7);

		wire [79:0] r_u3 = {
			r_full_15[79:75], r_full_14[74:70], r_full_13[69:65], r_full_12[64:60],
			r_full_11[59:55], r_full_10[54:50], r_full_9[49:45], r_full_8[44:40],
			r_full_7[39:35], r_full_6[34:30], r_full_5[29:25], r_full_4[24:20],
			r_full_3[19:15], r_full_2[14:10], r_full_1[9:5], r_full_0[4:0]
		};

		reg [3:0] hlz_u3;
		reg hfound;
		always @(*) begin
			hlz_u3 = 4'd0;
			hfound = 1'b0;
			for (ci_idx = 0; ci_idx < 10; ci_idx = ci_idx + 1)
				if (!hfound && x2[9 - ci_idx]) begin
					hlz_u3 = ci_idx[3:0];
					hfound = 1'b1;
				end
		end

		(* extract_reset = "no", max_fanout = 16 *) reg [2:0] kind3;
		(* extract_reset = "no", keep = "true" *) reg [7:0] dir3_0, dir3_1, dir3_2, dir3_3;
		(* extract_reset = "no", max_fanout = 16 *) reg [79:0] rr3;
		(* extract_reset = "no" *) reg neg3, snmin3, hs3;
		(* extract_reset = "no" *) reg [4:0] he3;
		(* extract_reset = "no" *) reg [9:0] x3;
		(* extract_reset = "no" *) reg [3:0] hlz3;
		(* extract_reset = "no" *) reg [7:0] e5b3;
		always @(posedge clk) begin
			kind3 <= kind2;
			dir3_0 <= dir2_0;
			dir3_1 <= dir2_1;
			dir3_2 <= dir2_2;
			dir3_3 <= dir2_3;
			rr3 <= r_u3;
			neg3 <= neg2;
			snmin3 <= snmin2;
			hs3 <= hs2;
			he3 <= he2;
			x3 <= x2;
			hlz3 <= hlz_u3;
			e5b3 <= e5b2;
		end

		/* ---- U3b: UNORM's leading zeros (of the top 24 bits) ---- */
		reg [4:0] lz_u3;
		reg found_u3;
		always @(*) begin
			lz_u3 = 5'd0;
			found_u3 = 1'b0;
			for (ci_idx = 0; ci_idx < 24; ci_idx = ci_idx + 1)
				if (!found_u3 && rr3[79 - ci_idx]) begin
					lz_u3 = ci_idx[4:0];
					found_u3 = 1'b1;
				end
		end

		(* extract_reset = "no", max_fanout = 16 *) reg [2:0] kind3b;
		(* extract_reset = "no", keep = "true" *) reg [7:0] dir3b_0, dir3b_1, dir3b_2, dir3b_3;
		(* extract_reset = "no", max_fanout = 16 *) reg [47:0] r3_hi;
		(* extract_reset = "no" *) reg r_low_or;
		(* extract_reset = "no", max_fanout = 16 *) reg [4:0] lz3;
		(* extract_reset = "no", keep = "true", max_fanout = 16 *) reg [4:0] lz3_un;
		(* extract_reset = "no", max_fanout = 16 *) reg found3, neg3b, snmin3b, hs3b;
		(* extract_reset = "no", max_fanout = 16 *) reg [4:0] he3b;
		(* extract_reset = "no", max_fanout = 16 *) reg [9:0] x3b;
		(* extract_reset = "no", max_fanout = 16 *) reg [3:0] hlz3b_hf;
		(* extract_reset = "no", max_fanout = 16 *) reg [3:0] hlz3b_exp;
		(* extract_reset = "no", max_fanout = 16 *) reg [7:0] e5b3b;
		always @(posedge clk) begin
			kind3b <= kind3;
			dir3b_0 <= dir3_0;
			dir3b_1 <= dir3_1;
			dir3b_2 <= dir3_2;
			dir3b_3 <= dir3_3;
			r3_hi <= rr3[79:32];
			r_low_or <= |rr3[31:8];
			lz3 <= lz_u3;
			lz3_un <= lz_u3;
			found3 <= found_u3;
			neg3b <= neg3;
			snmin3b <= snmin3;
			hs3b <= hs3;
			he3b <= he3;
			x3b <= x3;
			hlz3b_hf <= hlz3;
			hlz3b_exp <= hlz3;
			e5b3b <= e5b3;
		end

		/* ---- U4 ---- */
		wire [47:0] um_hi;

		am_shift #(.W(48), .SW(5)) u_un (.a(r3_hi), .amt(lz3_un), .left(1'b1), .arith(1'b0), .y(um_hi));

		/* Direct 3-LUT sticky bit calculation for |um_hi[22:0] | r_low_or */
		(* keep = "true" *) wire [22:0] u_st_b;
		genvar gsb;
		for (gsb = 0; gsb < 23; gsb = gsb + 1) begin : g_st_u4
			localparam [4:0] MAX_LZ_U4 = 5'd22 - gsb[4:0];
			assign u_st_b[gsb] = r3_hi[gsb] && (lz3_un <= MAX_LZ_U4);
		end
		(* keep = "true" *) wire [3:0] u_st_grp = {
			|u_st_b[22:18], |u_st_b[17:12], |u_st_b[11:6], |{u_st_b[5:0], r_low_or}
		};
		wire st4_w = |u_st_grp;

		wire [9:0] fsh;
		wire [7:0] hexp, hden, e5x;

		am_shift #(.W(10), .SW(4)) u_hf (.a(x3b), .amt(hlz3b_hf), .left(1'b1), .arith(1'b0), .y(fsh));
		am_add #(.W(8)) u_hexp (.a({3'd0, he3b}), .b(8'd112), .ci(1'b0), .s(hexp), .co(u_hexp_nc));
		am_sub #(.W(8)) u_hden (.a(8'd112), .b({4'd0, hlz3b_exp}), .bi(1'b0), .d(hden), .bo(u_hden_nc));
		am_sub #(.W(8)) u_e5x (.a(e5b3b), .b({4'd0, hlz3b_exp}), .bi(1'b0), .d(e5x), .bo(u_e5x_nc));

		wire [9:0] f = {fsh[8:0], 1'b0};
		reg [31:0] hval;
		always @(*) begin
			if (kind3b == K_E5)
				hval = x3b[8:0] == 9'd0 ? 32'd0 : {1'b0, e5x, f[9:1], 14'd0};
			else if (he3b == 5'd31)
				hval = x3b != 10'd0 ? 32'h7FC00000 : {hs3b, 31'h7F800000};
			else if (he3b == 5'd0)
				hval = x3b == 10'd0 ? {hs3b, 31'd0} : {hs3b, hden, f, 13'd0};
			else
				hval = {hs3b, hexp, x3b, 13'd0};
		end

		(* keep = "true" *) wire is_hfe5_lo = (kind3b == K_HF || kind3b == K_E5);
		(* keep = "true" *) wire is_hfe5_hi = (kind3b == K_HF || kind3b == K_E5);

		(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [2:0] kind4_lo, kind4_hi;
		(* extract_reset = "no", keep = "true" *) reg [7:0] dir4_0, dir4_1, dir4_2, dir4_3;
		(* extract_reset = "no" *) reg [23:0] um4;
		(* extract_reset = "no" *) reg st4;
		(* extract_reset = "no", max_fanout = 16 *) reg [4:0] lz4;
		(* extract_reset = "no", max_fanout = 16 *) reg found4;
		(* extract_reset = "no", max_fanout = 16 *) reg neg4;
		(* extract_reset = "no", max_fanout = 16 *) reg snmin4;
		always @(posedge clk) begin
			kind4_lo <= kind3b;
			kind4_hi <= kind3b;
			dir4_0 <= is_hfe5_lo ? hval[7:0] : dir3b_0;
			dir4_1 <= is_hfe5_lo ? hval[15:8] : dir3b_1;
			dir4_2 <= is_hfe5_hi ? hval[23:16] : dir3b_2;
			dir4_3 <= is_hfe5_hi ? hval[31:24] : dir3b_3;
			um4 <= um_hi[46:23];
			st4 <= st4_w;
			lz4 <= lz3;
			found4 <= found3;
			neg4 <= neg3b;
			snmin4 <= snmin3b;
		end

		/* ---- U5: UNORM's rounding (never a tie), SNORM ---- */
		wire [22:0] q22;
		wire [7:0] e127, e126;
		wire ci = um4[0] && (st4 || um4[1]);
		wire q23 = (&um4[23:1]) && ci;

		am_add #(.W(23)) u_q (.a(um4[23:1]), .b(23'd0), .ci(ci), .s(q22), .co(u_q_nc));
		am_sub #(.W(8)) u_e127 (.a(8'd127), .b({3'd0, lz4}), .bi(1'b0), .d(e127), .bo(u_e127_nc));
		am_sub #(.W(8)) u_e126 (.a(8'd126), .b({3'd0, lz4}), .bi(1'b0), .d(e126), .bo(u_e126_nc));

		wire [7:0] exp = q23 ? e127 : e126;
		wire is_norm_lo = (kind4_lo == K_UN) || (kind4_lo == K_SN);
		wire is_norm_hi = (kind4_hi == K_UN) || (kind4_hi == K_SN);
		wire is_snmin_lo = (kind4_lo == K_SN) && snmin4;
		wire is_snmin_hi = (kind4_hi == K_SN) && snmin4;

		always @(posedge clk) begin
			o_val[7:0] <= is_norm_lo ? ((found4 && !is_snmin_lo) ? q22[7:0] : 8'd0) : dir4_0;
			o_val[15:8] <= is_norm_lo ? ((found4 && !is_snmin_lo) ? q22[15:8] : 8'd0) : dir4_1;
			o_val[22:16] <= is_norm_hi ? ((found4 && !is_snmin_hi) ? q22[22:16] : 7'd0) : dir4_2[6:0];
			o_val[23] <= is_norm_hi ? (is_snmin_hi ? 1'b1 : (found4 ? exp[0] : 1'b0)) : dir4_2[7];
			o_val[30:24] <= is_norm_hi ? (is_snmin_hi ? 7'h3F : (found4 ? exp[7:1] : 7'd0)) : dir4_3[6:0];
			o_val[31] <= is_norm_hi ? ((kind4_hi == K_SN) ? (is_snmin_hi || (found4 && neg4)) : 1'b0) : dir4_3[7];
		end
		wire unused_cvt_ok = &{1'b0, i_inf[15], i_inf[12], i_inf[5:1], um_hi[47], um_hi[22:0], fsh[9],
			u_neg_c_nc, u_wm1_nc, u_e5b_nc, u_hexp_nc, u_hden_nc, u_e5x_nc, u_q_nc, u_e127_nc,
			u_e126_nc};
	end
	endgenerate

	(* extract_reset = "no", shreg_extract = "no" *) reg [11:0] mv [PC+1:PV];
	always @(posedge clk) begin
		mv[PC+1] <= mc;
		for (m = PC + 2; m <= PV; m = m + 1)
			mv[m] <= mv[m - 1];
	end

	/* The weight: wu wv and wa wb (P4), n = wu wv wa wb (P6), as fp32 n x
	 * 2^-32 rounded to nearest even (n > 0 for a term): P7 its leading
	 * zeros, P8 shifted, P9 rounded, then delayed to PV. */
	wire [17:0] wuv4, wab4;

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(2)) u_wuv (
		.clk(clk), .en(1'b1), .a(wu2), .b(wv2), .p(wuv4)
	);
	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(2)) u_wab (
		.clk(clk), .en(1'b1), .a(wa2), .b(wb2), .p(wab4)
	);

	wire [35:0] n6;

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(2)) u_n (
		.clk(clk), .en(1'b1), .a(wuv4), .b(wab4), .p(n6)
	);

	(* extract_reset = "no", max_fanout = 16 *) reg [32:0] n6_q;
	always @(posedge clk) begin
		n6_q <= n6[32:0];
	end

	reg [5:0] lz_w6;
	always @(*) begin
		lz_w6 = 6'd0;
		for (i = 0; i < 33; i = i + 1)
			if (n6_q[i])
				lz_w6 = 6'd32 - i[5:0];
	end

	(* extract_reset = "no", max_fanout = 16 *) reg [32:0] n7;
	(* extract_reset = "no", max_fanout = 16 *) reg [5:0] lz7;
	always @(posedge clk) begin
		n7 <= n6_q;
		lz7 <= lz_w6;
	end

	wire [56:0] y7;
	wire [7:0] e0_7, e1_7;

	am_shift #(.W(57), .SW(6)) u_w2f (.a({n7, 24'd0}), .amt(lz7), .left(1'b1), .arith(1'b0),
		.y(y7));
	am_sub #(.W(8)) u_e0 (.a(8'd127), .b({2'd0, lz7}), .bi(1'b0), .d(e0_7), .bo(u_e0_nc));
	am_sub #(.W(8)) u_e1 (.a(8'd128), .b({2'd0, lz7}), .bi(1'b0), .d(e1_7), .bo(u_e1_nc));

	(* extract_reset = "no", max_fanout = 16 *) reg [24:0] y8;	/* bits 56:32 */
	(* extract_reset = "no" *) reg yst8;
	(* extract_reset = "no", max_fanout = 16 *) reg [7:0] e0_8, e1_8;
	always @(posedge clk) begin
		y8 <= y7[56:32];
		yst8 <= y7[31:0] != 32'd0;
		e0_8 <= e0_7;
		e1_8 <= e1_7;
	end

	wire [24:0] q8;

	am_add #(.W(25)) u_wq (.a({1'b0, y8[24:1]}), .b(25'd0), .ci(y8[0] && (yst8 || y8[1])),
		.s(q8), .co(u_wq_nc));

	(* extract_reset = "no" *) reg [23:0] q9;
	(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg q9_24_lo, q9_24_hi;
	(* extract_reset = "no" *) reg [7:0] e0_9, e1_9;
	(* extract_reset = "no", shreg_extract = "no" *) reg [31:0] wf [11:PV];
	always @(posedge clk) begin
		q9 <= q8[23:0];
		q9_24_lo <= q8[24];
		q9_24_hi <= q8[24];
		e0_9 <= e0_8;
		e1_9 <= e1_8;
		wf[11] <= {1'b0, q9_24_hi ? e1_9 : e0_9, q9_24_hi ? q9[23:16] : q9[22:15], q9_24_lo ? q9[15:1] : q9[14:0]};
		for (m = 12; m <= PV; m = m + 1)
			wf[m] <= wf[m - 1];
	end


	/* The valid bits. */
	reg [PV:1] vp;
	(* keep = "true" *) reg busy_q;
	assign o_vld = vp[PV];
	assign o_meta_pre = mv[PV-1];
	assign o_meta = mv[PV];
	assign o_up = upv;
	assign o_wf = wf[PV];
	assign o_busy = busy_q;

	always @(posedge clk) begin
		if (rst_inv) begin
			vp <= {PV{1'b0}};
			busy_q <= 1'b0;
		end else begin
			vp <= {vp[PV-1:1], i_vld};
			busy_q <= i_vld || (|vp[PV-1:1]);
		end
	end

	wire unused_ok = &{1'b0, u_e0_nc, u_e1_nc, u_neg_nc, u_ner_nc, u_rl_nc, u_ru_nc, u_rv_nc, u_rw_nc, u_wq_nc, ear[10], eag[10]};
endmodule

`default_nettype wire
