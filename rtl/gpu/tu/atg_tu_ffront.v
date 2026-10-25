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

module atg_tu_ffront (
	input wire clk,
	input wire rst_n,
	/* The step (cycle 0) */
	input wire i_vld,
	input wire [1:0] i_op,
	input wire [1:0] i_cs,
	input wire [3:0] i_aid,
	input wire [1:0] i_t,	/* the texel */
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
	output wire [11:0] o_meta,	/* {op, cs, aid, tb, es, ers, egs} */
	output wire [31:0] o_up,
	output wire [31:0] o_wf,
	output wire o_busy
);
	`include "atg_fmt_info.vh"
	integer i, m;
	wire u_e0_nc, u_e1_nc, u_neg_nc, u_ner_nc, u_rl_nc, u_ru_nc, u_rv_nc, u_rw_nc, u_wq_nc;

	/* ---- P0: the texel's bits and border bit, its position in a block ---- */
	wire [31:0] slw = i_sl[i_t*32 +: 32];
	reg [127:0] raw_i;
	always @(*) begin
		if (i_wg)
			case (i_gwi)
			2'd0: raw_i = {96'd0, slw};
			2'd1: raw_i = {64'd0, slw, 32'd0};
			2'd2: raw_i = {32'd0, slw, 64'd0};
			default: raw_i = {slw, 96'd0};
			endcase
		else if (i_b8)
			raw_i = i_t[0] ? {64'd0, i_sl[127:64]} : {64'd0, i_sl[63:0]};
		else if (i_b16)
			raw_i = i_sl;
		else
			raw_i = {96'd0, slw};
	end
	wire tb_i = i_wg || !(i_b8 || i_b16) ? i_bd[i_t] : i_b8 && i_t[0] ? i_bd[2] : i_bd[0];
	wire [1:0] es_i = i_b16 || !i_t[0] ? i_lo[1:0] : i_lo[5:4];
	wire [1:0] et_i = i_b16 || !i_t[0] ? i_lo[3:2] : i_lo[7:6];

	/* ---- P1 ---- */
	reg [1:0] op1, cs1;
	reg [3:0] aid1;
	reg tb1;
	reg [127:0] raw1;
	reg [1:0] es1, et1, ft1;
	reg [31:0] wl1;	/* the lane's {fw, fl, fv, fu} */
	reg bil1, p17_1, p18_1;
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

	reg [8:0] wu2, wv2, wa2, wb2;
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
	reg [136:0] fe [2:PE];
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
	wire esgn = e_kind == 2'd3;	/* signed EAC */
	wire [67:0] e_inf = e_kind[1] ? (esgn ? atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd16, 6'd10), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0)) : atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd11), atg_fmt_c(7'd16, 6'd11), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0))) : e_kind[0] ? atg_fmt_info(8'd43) : atg_fmt_info(8'd37);
	wire [127:0] e_raw = esgn ? {96'd0, 5'd0, eag, 5'd0, ear} : {96'd0, e_tx};

	reg [127:0] crawc;
	reg [67:0] cinfc;
	reg [1:0] ckc;
	reg cstenc;
	reg [11:0] mc;	/* {op, cs, aid, tb, es, ers, egs} */
	always @(posedge clk) begin
		crawc <= i_blk ? e_raw : rawe;
		cinfc <= i_blk ? e_inf : i_inf;
		ckc <= cse;
		cstenc <= i_sten && !i_blk;
		mc <= {ope, cse, aide, tbe, esgn, er[10], eg[10]};
	end

	/* ---- PC → PV: the component (atg_fmt_cvt) ---- */
	wire [31:0] upv;

	atg_fmt_cvt cvt (.clk(clk), .i_raw(crawc), .i_inf(cinfc), .i_k(ckc), .i_sten(cstenc),
		.o_val(upv));

	reg [11:0] mv [PC+1:PV];
	always @(posedge clk) begin
		mv[PC+1] <= mc;
		for (m = PC + 2; m <= PV; m = m + 1)
			mv[m] <= mv[m - 1];
	end

	/* The weight: wu wv and wa wb (P3), n = wu wv wa wb (P4), as fp32 n x
	 * 2^-32 rounded to nearest even (n > 0 for a term): P5 its leading
	 * zeros, P6 shifted, P7 rounded, then delayed to PV. */
	wire [17:0] wuv3, wab3;

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wuv (
		.clk(clk), .en(1'b1), .a(wu2), .b(wv2), .p(wuv3)
	);
	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wab (
		.clk(clk), .en(1'b1), .a(wa2), .b(wb2), .p(wab3)
	);

	wire [35:0] n4;

	am_mul #(.AW(18), .BW(18), .SIGNED(0), .LAT(1)) u_n (
		.clk(clk), .en(1'b1), .a(wuv3), .b(wab3), .p(n4)
	);

	reg [5:0] lz_w4;
	always @(*) begin
		lz_w4 = 6'd0;
		for (i = 0; i < 33; i = i + 1)
			if (n4[i])
				lz_w4 = 6'd32 - i[5:0];
	end

	reg [32:0] n5;
	reg [5:0] lz5;
	always @(posedge clk) begin
		n5 <= n4[32:0];
		lz5 <= lz_w4;
	end

	wire [56:0] y5;
	wire [7:0] e0_5, e1_5;

	am_shift #(.W(57), .SW(6)) u_w2f (.a({n5, 24'd0}), .amt(lz5), .left(1'b1), .arith(1'b0),
		.y(y5));
	am_sub #(.W(8)) u_e0 (.a(8'd127), .b({2'd0, lz5}), .bi(1'b0), .d(e0_5), .bo(u_e0_nc));
	am_sub #(.W(8)) u_e1 (.a(8'd128), .b({2'd0, lz5}), .bi(1'b0), .d(e1_5), .bo(u_e1_nc));

	reg [24:0] y6;	/* bits 56:32 */
	reg yst6;
	reg [7:0] e0_6, e1_6;
	always @(posedge clk) begin
		y6 <= y5[56:32];
		yst6 <= y5[31:0] != 32'd0;
		e0_6 <= e0_5;
		e1_6 <= e1_5;
	end

	wire [24:0] q6;

	am_add #(.W(25)) u_wq (.a({1'b0, y6[24:1]}), .b(25'd0), .ci(y6[0] && (yst6 || y6[1])),
		.s(q6), .co(u_wq_nc));

	reg [31:0] wf [7:PV];
	always @(posedge clk) begin
		wf[7] <= {1'b0, q6[24] ? e1_6 : e0_6, q6[24] ? q6[23:1] : q6[22:0]};
		for (m = 8; m <= PV; m = m + 1)
			wf[m] <= wf[m - 1];
	end


	assign o_vld = vp[PV];
	assign o_meta = mv[PV];
	assign o_up = upv;
	assign o_wf = wf[PV];
	assign o_busy = |vp;

	/* The valid bits. */
	reg [PV:1] vp;
	always @(posedge clk) begin
		if (!rst_n)
			vp <= {PV{1'b0}};
		else
			vp <= {vp[PV-1:1], i_vld};
	end

	wire unused_ok = &{1'b0, u_e0_nc, u_e1_nc, u_neg_nc, u_ner_nc, u_rl_nc, u_ru_nc, u_rv_nc, u_rw_nc, u_wq_nc, ear[10], eag[10]};
endmodule

`default_nettype wire
