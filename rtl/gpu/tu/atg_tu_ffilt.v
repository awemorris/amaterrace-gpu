/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_ffilt: the TU's fp32 filter path (docs/ghci.md section 8.5):
 * the formats of TEX_FORMAT that atg_tu_filter does not take (tc_ctl[20]
 * = 1): every sampled format but RGBA8, BGRA8, R8, R8G8 UNORM and the
 * compares.  tools/tumodel.py (FFilter) is the reference, bit for bit.
 *
 * Takes one pass of a quad (tc_*) in IDLE; holds tr_* until taken (order
 * is kept).  The texels of a lane come from its four slots: 1- to 4-byte
 * texels are slots 0-3 (right-justified by atg_tu_cache), 8-byte texels
 * slots {1, 0} and {3, 2} (the texels i0 and i1 of the pass's row,
 * tc_ctl[22]), 16-byte texels slots {3, 2, 1, 0}; gather: slot t is the
 * word of texel t that holds the component (include/atg_tu_fmt.vh
 * tu_gwi).  ETC2 and EAC blocks (8 or 16 bytes) come as the 8- and 16-byte
 * texels, a block per texel, the texel's column and row in the block in
 * tc_lo (address bits 1:0 of the block's first and second slot), and are
 * decoded by atg_tu_etc; 16-byte blocks come one texel a pass (tc_ctl[49],
 * the pass's footprint texel {row, column [48]}), gather of 8-byte blocks
 * in the row passes.  Each texel's component is converted by atg_fmt_cvt
 * (atg_fmt_unpack's conversion; tc_ctl[34:27] the VkFormat, [35] the
 * stencil aspect), or is a border texel's (tc_bord): the border colour
 * (tc_ctl[7:6]: 0 transparent black, 1 opaque black, 2 opaque white;
 * integer 0 and 1 for the integer formats) in the format's components,
 * the others (0, 0, 0, 1).  sRGB texels are linear after the conversion,
 * before filtering.
 * Weights: texel t's integer weight wu x wv (bilinear: (256 - fu or fu) x
 * (256 - fv or fv) by its column and row; 8-byte row passes: the row's
 * 256 - fv or fv; nearest: 65536 for texel 0) times the pass's (256 - fw
 * or fw) x (256 - fl or fl) (tc_ctl[17], [18]), as fp32 n x 2^-32 rounded
 * to nearest even; a weight of 0 is skipped.  Each component c below the
 * format's count is accumulated by a fused multiply-add, A = fma(w, x, A)
 * (atg_tu_fma: one rounding to nearest even, denormals flushed), from A =
 * -0.0 at the quad's first pass (tc_ctl[5] = 0) over the passes; the
 * components the format does not have are (0, 0, 0, 1).  A lane with a
 * single texel of weight 1 (a quad of one pass without bilinear, or a
 * bilinear lane with fu = fv = 0) returns the converted texel as it is
 * (integer formats, texf and nearest sampling are exact).  Gather
 * returns the component of texels 2, 3, 1, 0.  The component swizzle
 * (tc_ctl[47:36]) is applied last (gather selects through it); lanes
 * outside tc_mask give 0.  A pass with tc_ctl[4] (more to follow) returns
 * nothing and keeps the sums.  idle: no quad in the unit (between the
 * passes of a quad it is 0; atg_tu hands a pass of the other path only
 * when idle).
 *
 * Pipeline: a pass's steps (one component of a lane's texel) are issued
 * one a cycle in the order texel, lane, component (LOAD makes the pass's
 * work, a mask of {texel, lane}), through P1 (the texel's bits, the
 * lane's weights), P2-P3 (atg_tu_etc's block decode, 2 cycles; the
 * weight's factors, wu wv and wa wb), P4 (the converter's inputs),
 * P4-P10 (atg_fmt_cvt; the weight n and its fp32), to P10: a bypassed or
 * gathered value is written to its accumulator there, a term goes into
 * atg_tu_fma, which reads the accumulator 3 cycles later and writes it 10
 * cycles later.  The steps of
 * one accumulator keep the reference's order (texels, then passes); a
 * term is issued only 8 cycles or more after the previous term of its
 * accumulator (the issue waits otherwise: a pass with few lanes and
 * components).  The next pass of the quad is taken while the last one's
 * steps are in the pipeline; after the last pass the unit waits until it
 * is empty (DRAIN), then FIN takes the lanes one a cycle.
 * See spec/gpu/tu/atg_tu_ffilt.md.
 *
 * States: IDLE →(tc)→ LOAD → RUN → DRAIN → FIN (lanes 0-3) → OUT
 * →(tr_ready)→ IDLE; a pass with more to follow goes from RUN back to
 * IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_ffilt (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [15:0] tc_bord,
	input wire [31:0] tc_lo,
	input wire [127:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [49:0] tc_ctl,
	input wire tc_last,
	output wire idle,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output reg [15:0] tr_tag,
	output reg [511:0] tr_data,
	output reg tr_last
);
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	localparam [2:0] IDLE = 3'd0, LOAD = 3'd1, RUN = 3'd2, DRAIN = 3'd3, FIN = 3'd4,
		OUT = 3'd5;
	/* A step's kind */
	localparam [1:0] OP_FMA = 2'd0, OP_BYP = 2'd1, OP_GATH = 2'd2;
	wire u_ifmt_nc, u_inc_nc, u_ru_nc, u_rv_nc, u_rl_nc, u_rw_nc, u_ner_nc, u_neg_nc,
		u_e0_nc, u_e1_nc, u_wq_nc;	/* the carries not used */
	integer i, m;

	/* The component that swizzle code 3-6 (R, G, B, A) takes, by its bits
	 * 1:0. */
	function [1:0] zsrc;
		input [1:0] s;
		case (s)
		2'd3: zsrc = 2'd0;
		2'd0: zsrc = 2'd1;
		2'd1: zsrc = 2'd2;
		default: zsrc = 2'd3;
		endcase
	endfunction

	/* The component swizzle; one is 1.0 or the integer 1. */
	function [127:0] swz4;
		input [127:0] v;
		input [11:0] z;
		input [31:0] one;
		integer c;
		reg [2:0] sc;
		begin
			for (c = 0; c < 4; c = c + 1) begin
				sc = z[3*c +: 3];
				swz4[c*32 +: 32] = sc == 3'd1 ? 32'd0 : sc == 3'd2 ? one :
					sc >= 3'd3 && sc <= 3'd6 ? v[{zsrc(sc[1:0]), 5'd0} +: 32] : v[c*32 +: 32];
			end
		end
	endfunction

	reg [2:0] st;
	reg [511:0] tx;
	reg [15:0] bd;
	reg [31:0] lo;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [49:0] ctl;
	reg [511:0] acc;	/* lane-major, 4 components a lane */

	/* ---- The pass (from ctl) ---- */
	wire bil = ctl[0], more = ctl[4], gath = ctl[13], split = ctl[21], row = ctl[22];
	wire quad = ctl[49], col = ctl[48];
	wire [1:0] comp = ctl[15:14];
	wire [7:0] vkf = ctl[34:27];
	wire sten = ctl[35];
	wire [11:0] swz = ctl[47:36];
	wire [67:0] inf = atg_fmt_info(vkf);
	wire [2:0] ncomp_l = sten ? 3'd1 : inf[0] ? inf[8:6] : 3'd0;
	wire isint_l = sten || inf[11:9] == ATG_FMT_UINT || inf[11:9] == ATG_FMT_SINT;
	/* Gather: the swizzle of component comp, the component it takes and
	 * the texel's word that holds it (tu_gwi of include/atg_tu_fmt.vh). */
	reg [2:0] gsw_l;
	reg [6:0] gpos_l;
	wire [1:0] gsrc_l = gsw_l >= 3'd3 && gsw_l <= 3'd6 ? zsrc(gsw_l[1:0]) : comp;
	always @(*) begin
		case (comp)
		2'd0: gsw_l = swz[2:0];
		2'd1: gsw_l = swz[5:3];
		2'd2: gsw_l = swz[8:6];
		default: gsw_l = swz[11:9];
		endcase
		case (gsrc_l)
		2'd0: gpos_l = inf[22:16];
		2'd1: gpos_l = inf[35:29];
		2'd2: gpos_l = inf[48:42];
		default: gpos_l = inf[61:55];
		endcase
	end
	wire [1:0] gwi_l = gsw_l == 3'd1 || gsw_l == 3'd2 || {1'b0, gsrc_l} >= inf[8:6] ? 2'd0 :
		gpos_l[6:5];
	wire [3:0] ifmt_l;	/* atg_tu_etc's format: VkFormat - 147 */

	am_sub #(.W(4)) u_ifmt (.a(vkf[3:0]), .b(4'd3), .bi(1'b0), .d(ifmt_l), .bo(u_ifmt_nc));

	/* The quad's constants, registered in LOAD (the same in every pass). */
	reg [67:0] inf_q;
	reg [2:0] ncomp, gsw;
	reg [1:0] ncm1, gwi, gsrc, bcls;
	reg [31:0] one;
	reg blk, b8, b16, wg, stq, gathq;
	reg [11:0] swzq;
	reg [3:0] ifmt;

	/* The footprint texel of the pass's texel t. */
	function [1:0] ft_f;
		input [1:0] t;
		input q, sp, r, cl;
`ifdef MUT_FFILT_ROW
		ft_f = q ? {1'b0, cl} : sp ? {1'b0, t[0]} : t;	/* row read as the first */
`else
		ft_f = q ? {r, cl} : sp ? {r, t[0]} : t;
`endif
	endfunction

	/* ---- LOAD: the pass's work, wk[{t, k}]: a gathered texel, a
	 * bypassed lane's texel 0, or a term with a weight above 0 ---- */
	reg [3:0] byp_l;
	reg [15:0] wk;
	reg [1:0] tt, kk, ftt;
	reg [7:0] fu, fv, fl, fw;
	reg pr, nz;
	always @(*) begin
		for (i = 0; i < 4; i = i + 1)
			byp_l[i] = !more && !ctl[5] && !gath &&
				(!bil || (wts[i*32 +: 8] == 8'd0 && wts[i*32 + 8 +: 8] == 8'd0));
		for (i = 0; i < 16; i = i + 1) begin
			tt = i[3:2];
			kk = i[1:0];
			fu = wts[i[1:0]*32 +: 8];
			fv = wts[i[1:0]*32 + 8 +: 8];
			fl = wts[i[1:0]*32 + 16 +: 8];
			fw = wts[i[1:0]*32 + 24 +: 8];
			pr = quad ? tt == 2'd0 : split ? !tt[1] : bil || gath || tt == 2'd0;
			ftt = ft_f(tt, quad, split, row, col);
			nz = pr && (!bil || !ftt[0] || fu != 8'd0) && (!bil || !ftt[1] || fv != 8'd0) &&
				!(ctl[17] && fw == 8'd0) && !(ctl[18] && fl == 8'd0);
			wk[i] = mask[kk] && (gath ? pr : byp_l[kk] ? tt == 2'd0 && ncomp_l != 3'd0 :
				nz && ncomp_l != 3'd0);
		end
	end

	/* ---- RUN: the issue ---- */
	reg [15:0] rem;	/* the {texel, lane} still to issue */
	reg [1:0] c;	/* the component of the current {texel, lane} */
	reg [3:0] cur;
	reg [15:0] cur1;
	always @(*) begin
		cur = 4'd0;
		for (i = 15; i >= 0; i = i - 1)
			if (rem[i])
				cur = i[3:0];
		cur1 = 16'd0;
		cur1[cur] = 1'b1;
	end
	wire [1:0] it = cur[3:2], ik = cur[1:0];
	wire [1:0] iop = gathq ? OP_GATH : byp_l[ik] ? OP_BYP : OP_FMA;
	wire [1:0] ift = ft_f(it, quad, split, row, col);
	/* gather: word texel 2, 3, 1, 0 of the lane (texel t's place) */
	wire [1:0] gpos = ift == 2'd2 ? 2'd0 : ift == 2'd3 ? 2'd1 : ift == 2'd1 ? 2'd2 : 2'd3;
	wire [3:0] aid = iop == OP_GATH ? {ik, gpos} : {ik, c};
	wire lastc = iop == OP_GATH || c == ncm1;
	/* The terms of the last 7 cycles: one on the same accumulator waits. */
	reg [34:0] hist;	/* 7 x {term, aid}, the latest in [4:0] */
	reg haz;
	always @(*) begin
		haz = 1'b0;
		for (i = 0; i < 7; i = i + 1)
			if (hist[i*5 + 4] && hist[i*5 +: 4] == aid)
				haz = 1'b1;
	end
	wire issue = st == RUN && rem != 16'd0 && !(iop == OP_FMA && haz);
	wire [15:0] rem_n = lastc ? rem & ~cur1 : rem;
	wire [1:0] c_inc;
	reg [1:0] kf;	/* FIN's lane */

	/* c + 1 (RUN) and FIN's next lane share an adder. */
	am_add #(.W(2)) u_inc (.a(st == FIN ? kf : c), .b(2'd0), .ci(1'b1), .s(c_inc),
		.co(u_inc_nc));

	/* The texel's bits and border bit; its position in a block. */
	wire [127:0] sl = tx[ik*128 +: 128];
	wire [31:0] slw = sl[it*32 +: 32];
	reg [127:0] raw_i;
	always @(*) begin
		if (wg)
			case (gwi)
			2'd0: raw_i = {96'd0, slw};
			2'd1: raw_i = {64'd0, slw, 32'd0};
			2'd2: raw_i = {32'd0, slw, 64'd0};
			default: raw_i = {slw, 96'd0};
			endcase
		else if (b8)
			raw_i = it[0] ? {64'd0, sl[127:64]} : {64'd0, sl[63:0]};
		else if (b16)
			raw_i = sl;
		else
			raw_i = {96'd0, slw};
	end
	wire tb_i = wg || !(b8 || b16) ? bd[{ik, it}] : b8 && it[0] ? bd[{ik, 2'd2}] : bd[{ik, 2'd0}];
	wire [7:0] llo = lo[ik*8 +: 8];
	wire [1:0] es_i = b16 || !it[0] ? llo[1:0] : llo[5:4];
	wire [1:0] et_i = b16 || !it[0] ? llo[3:2] : llo[7:6];

	/* ---- P1 ---- */
	reg v1;
	reg [1:0] op1, cs1;
	reg [3:0] aid1;
	reg tb1;
	reg [127:0] raw1;
	reg [1:0] es1, et1, ft1;
	reg [31:0] wl1;	/* the lane's {fw, fl, fv, fu} */
	reg bil1, p17_1, p18_1;
	always @(posedge clk) begin
		op1 <= iop;
		aid1 <= aid;
		cs1 <= gathq ? gsrc : c;
		tb1 <= tb_i;
		raw1 <= raw_i;
		es1 <= es_i;
		et1 <= et_i;
		ft1 <= ift;
		wl1 <= wts[ik*32 +: 32];
		bil1 <= bil;
		p17_1 <= ctl[17];
		p18_1 <= ctl[18];
	end

	/* ---- P1 → P2: the block decode; the weight's factors ---- */
	wire [1:0] e_kind;
	wire [31:0] e_tx;

	atg_tu_etc etc (
		.clk(clk), .i_fmt(ifmt), .i_block(raw1), .i_s(es1), .i_t(et1), .o_kind(e_kind), .o_texel(e_tx)
	);

	wire [8:0] ru, rv, rw, rl;

	am_sub #(.W(9)) u_ru (.a(9'd256), .b({1'b0, wl1[7:0]}), .bi(1'b0), .d(ru), .bo(u_ru_nc));
	am_sub #(.W(9)) u_rv (.a(9'd256), .b({1'b0, wl1[15:8]}), .bi(1'b0), .d(rv), .bo(u_rv_nc));
	am_sub #(.W(9)) u_rl (.a(9'd256), .b({1'b0, wl1[23:16]}), .bi(1'b0), .d(rl), .bo(u_rl_nc));
	am_sub #(.W(9)) u_rw (.a(9'd256), .b({1'b0, wl1[31:24]}), .bi(1'b0), .d(rw), .bo(u_rw_nc));

	reg v2;
	reg [1:0] op2, cs2;
	reg [3:0] aid2;
	reg tb2;
	reg [127:0] raw2;
	reg [8:0] wu2, wv2, wa2, wb2;
	always @(posedge clk) begin
		{op2, cs2, aid2, tb2, raw2} <= {op1, cs1, aid1, tb1, raw1};
		/* (the texel of an issued term is present) */
		wu2 <= !bil1 ? 9'd256 : ft1[0] ? {1'b0, wl1[7:0]} : ru;
		wv2 <= !bil1 ? 9'd256 : ft1[1] ? {1'b0, wl1[15:8]} : rv;
		wa2 <= p17_1 ? {1'b0, wl1[31:24]} : rw;
		wb2 <= p18_1 ? {1'b0, wl1[23:16]} : rl;
	end

	/* ---- P3: the decoded block (atg_tu_etc: 2 cycles) ---- */
	reg v3;
	reg [1:0] op3, cs3;
	reg [3:0] aid3;
	reg tb3;
	reg [127:0] raw3;
	always @(posedge clk)
		{op3, cs3, aid3, tb3, raw3} <= {op2, cs2, aid2, tb2, raw2};
	wire [1:0] ek3 = e_kind;
	wire [31:0] etx3 = e_tx;

	/* ---- P3 → P4: the converter's inputs.  A block's texel: RGBA8 as
	 * R8G8B8A8_UNORM or _SRGB; EAC R11 and RG11 as two 11-bit UNORM
	 * components (the second 0 for R11), the signed ones as the
	 * magnitudes' 10-bit UNORM with the sign set (-0.0 for -1024); the
	 * components the block does not have (0, 0, 1.0). ---- */
	wire [10:0] er = etx3[10:0], eg = etx3[26:16];
	wire [10:0] ner, neg_g;

	am_sub #(.W(11)) u_ner (.a(11'd0), .b(er), .bi(1'b0), .d(ner), .bo(u_ner_nc));
	am_sub #(.W(11)) u_neg (.a(11'd0), .b(eg), .bi(1'b0), .d(neg_g), .bo(u_neg_nc));

	wire [10:0] ear = er[10] ? ner : er, eag = eg[10] ? neg_g : eg;
	wire esgn = ek3 == 2'd3;	/* signed EAC */
	wire [67:0] e_inf = ek3[1] ? (esgn ? atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd16, 6'd10), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0)) : atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
		atg_fmt_c(7'd0, 6'd11), atg_fmt_c(7'd16, 6'd11), atg_fmt_c(7'd0, 6'd0),
		atg_fmt_c(7'd0, 6'd0))) : ek3[0] ? atg_fmt_info(8'd43) : atg_fmt_info(8'd37);
	wire [127:0] e_raw = esgn ? {96'd0, 5'd0, eag, 5'd0, ear} : {96'd0, etx3};

	wire [17:0] wuv3, wab3;

	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wuv (
		.clk(clk), .en(1'b1), .a(wu2), .b(wv2), .p(wuv3)
	);
	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wab (
		.clk(clk), .en(1'b1), .a(wa2), .b(wb2), .p(wab3)
	);

	reg [127:0] craw4;
	reg [67:0] cinf4;
	reg [1:0] ck4;
	reg csten4;
	reg v4;
	reg [1:0] op4, cs4;
	reg [3:0] aid4;
	reg tb4, es4, ers4, egs4;
	always @(posedge clk) begin
		craw4 <= blk ? e_raw : raw3;
		cinf4 <= blk ? e_inf : inf_q;
		ck4 <= cs3;
		csten4 <= stq && !blk;
		{op4, cs4, aid4, tb4} <= {op3, cs3, aid3, tb3};
		es4 <= esgn;
		ers4 <= er[10];
		egs4 <= eg[10];
	end

	/* ---- P4-P10: the component (atg_fmt_cvt, 6 cycles) ---- */
	wire [31:0] up10;

	atg_fmt_cvt cvt (.clk(clk), .i_raw(craw4), .i_inf(cinf4), .i_k(ck4), .i_sten(csten4),
		.o_val(up10));

	/* The weight: n = wu wv wa wb (P4), as fp32 n x 2^-32 rounded to
	 * nearest even (n > 0 for a term): P5 its leading zeros, P6 shifted,
	 * P7 rounded, P8. */
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

	reg [31:0] wf7, wf8, wf9, wf10;
	always @(posedge clk) begin
		wf7 <= {1'b0, q6[24] ? e1_6 : e0_6, q6[24] ? q6[23:1] : q6[22:0]};
		wf8 <= wf7;
		wf9 <= wf8;
		wf10 <= wf9;
	end

	/* The step's fields from P4 to P10: {op, cs, aid, tb, es, ers, egs}. */
	reg [11:0] meta5, meta6, meta7, meta8, meta9, meta10;
	reg [10:5] vm;
	always @(posedge clk) begin
		meta5 <= {op4, cs4, aid4, tb4, es4, ers4, egs4};
		meta6 <= meta5;
		meta7 <= meta6;
		meta8 <= meta7;
		meta9 <= meta8;
		meta10 <= meta9;
	end
	wire [1:0] op10 = meta10[11:10], cs10 = meta10[9:8];
	wire [3:0] aid10 = meta10[7:4];
	wire tb10 = meta10[3], es10 = meta10[2], ers10 = meta10[1], egs10 = meta10[0];

	/* ---- P10: the value; a bypass or gather writes it, a term goes on ---- */
	wire [31:0] ev = {cs10 == 2'd0 ? es10 && ers10 : cs10 == 2'd1 ? es10 && egs10 : up10[31],
		up10[30:0]};
	wire [31:0] bval = {1'b0, cs10} < ncomp ?
		(bcls == 2'd2 || (bcls == 2'd1 && cs10 == 2'd3) ? one : 32'd0) :
		cs10 == 2'd3 ? one : 32'd0;
	wire [31:0] val = tb10 ? bval : blk ? ev : up10;
	wire [31:0] gval = gsw == 3'd1 ? 32'd0 : gsw == 3'd2 ? one : val;
	wire wr10 = vm[10] && op10 != OP_FMA;

	wire f_cvld, f_rvld, f_busy;
	wire [3:0] f_ctag, f_rtag;
	wire [31:0] f_r;

	atg_tu_fma #(.TW(4)) fma (
		.clk(clk), .rst_n(rst_n), .i_vld(vm[10] && op10 == OP_FMA), .i_tag(aid10),
		.i_a(wf10), .i_b(val), .c_vld(f_cvld), .c_tag(f_ctag), .c_val(acc[f_ctag*32 +: 32]),
		.r_vld(f_rvld), .r_tag(f_rtag), .r_val(f_r), .o_busy(f_busy)
	);

	/* The valid bits; busy: a step in the pipeline. */
	always @(posedge clk) begin
		if (!rst_n) begin
			{v1, v2, v3, v4} <= 4'd0;
			vm <= 6'd0;
		end else begin
			v1 <= issue;
			v2 <= v1;
			v3 <= v2;
			v4 <= v3;
			vm <= {vm[9:5], v4};
		end
	end
	wire busy = v1 || v2 || v3 || v4 || |vm || f_busy;

	/* The result of lane kf (FIN takes the lanes one a cycle). */
	reg [127:0] fin_q;
	reg [127:0] fin;
	reg [2:0] g3;
	always @(*) begin
		for (m = 0; m < 4; m = m + 1) begin
			g3 = m[2:0];
			fin[m*32 +: 32] = g3 < ncomp ? acc[{kf, m[1:0]}*32 +: 32] : m == 3 ? one : 32'd0;
		end
		fin_q = !mask[kf] ? 128'd0 : gathq ? acc[kf*128 +: 128] : swz4(fin, swzq, one);
	end

	reg mid;	/* a pass with more to follow taken, its last not yet */

	assign tc_ready = st == IDLE;
	assign tr_valid = st == OUT;
	assign idle = st == IDLE && !mid;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			mid <= 1'b0;
			hist <= 35'd0;
		end else begin
			hist <= {hist[29:0], issue && iop == OP_FMA, aid};
			case (st)
			IDLE: if (tc_valid) begin
				tx <= tc_texels;
				bd <= tc_bord;
				lo <= tc_lo;
				wts <= tc_wts;
				mask <= tc_mask;
				ctl <= tc_ctl;
				tr_tag <= tc_tag;
				tr_last <= tc_last;
				if (!tc_ctl[5])
					acc <= {16{32'h80000000}};
				mid <= tc_ctl[4];
				st <= LOAD;
			end
			LOAD: begin
				rem <= wk;
				c <= 2'd0;
				st <= RUN;
			end
			RUN: if (rem == 16'd0 || (issue && rem_n == 16'd0))
				st <= more ? IDLE : DRAIN;
			else if (issue) begin
				rem <= rem_n;
				c <= lastc ? 2'd0 : c_inc;
			end
			DRAIN: if (!busy) begin
				kf <= 2'd0;
				st <= FIN;
			end
			FIN: begin
				tr_data[kf*128 +: 128] <= fin_q;
				kf <= c_inc;
				if (kf == 2'd3)
					st <= OUT;
			end
			default: if (tr_ready)
				st <= IDLE;
			endcase
			/* the accumulators: a bypass or gather (P10), a term (atg_tu_fma) */
			if (wr10)
				acc[aid10*32 +: 32] <= op10 == OP_GATH ? gval : val;
			if (f_rvld)
				acc[f_rtag*32 +: 32] <= f_r;
		end
	end

	/* The quad's constants (LOAD). */
	always @(posedge clk)
		if (st == LOAD) begin
			inf_q <= inf;
			ncomp <= ncomp_l;
			case (ncomp_l)
			3'd2: ncm1 <= 2'd1;
			3'd3: ncm1 <= 2'd2;
			3'd4: ncm1 <= 2'd3;
			default: ncm1 <= 2'd0;
			endcase
			one <= isint_l ? 32'd1 : 32'h3F800000;
			blk <= inf[14];
			b8 <= inf[5:1] == 5'd8;
			b16 <= inf[5:1] == 5'd16;
			wg <= gath && !inf[14];
			gwi <= gwi_l;
			gsw <= gsw_l;
			gsrc <= gsrc_l;
			bcls <= ctl[7:6];
			stq <= sten;
			gathq <= gath;
			swzq <= swz;
			ifmt <= ifmt_l;
		end

	wire unused_ok = &{1'b0, u_ifmt_nc, u_inc_nc, u_ru_nc, u_rv_nc, u_rl_nc, u_rw_nc,
		u_ner_nc, u_neg_nc, u_e0_nc, u_e1_nc, u_wq_nc, n4[35:33], gpos_l[4:0],
		ctl[33:23], ctl[16], ctl[20:19],
		ctl[12:8], ctl[3:1], vkf[7:4], ear[10], eag[10], f_cvld};
endmodule

`default_nettype wire
