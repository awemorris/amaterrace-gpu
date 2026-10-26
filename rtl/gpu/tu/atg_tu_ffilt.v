/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_ffilt: the TU's fp32 filter path (docs/ghci.md section 8.5):
 * the formats of TEX_FORMAT that atg_tu_filter does not take (tc_ctl[20]
 * = 1).  tools/tumodel.py (FFilter) is the reference, bit for bit; the
 * texel layout, borders, blocks, weights, bypass, gather and swizzle are
 * in spec/gpu/tu/atg_tu_ffilt.md section 4.
 *
 * Takes one pass of a quad (tc_*) in IDLE; holds tr_* until taken (order
 * is kept); a pass with tc_ctl[4] (more to follow) returns nothing and
 * keeps the sums.  idle: no quad in the unit (0 between the passes of a
 * quad; atg_tu hands a pass of the other path only when idle).
 *
 * A pass's steps (one component of a lane's texel: a term A = fma(w, x,
 * A), a bypassed component or a gathered texel) are issued one a cycle in
 * the order texel, lane, component (LOAD makes the pass's work, a mask of
 * {texel, lane}) into atg_tu_ffront, which gives the value and the weight
 * 13 cycles later (PV): a bypassed or gathered value is written to its
 * accumulator there, a term goes into am_fp_fma, which reads the
 * accumulator 3 cycles later and writes it 10 cycles later.  The terms of
 * one accumulator keep the reference's order (texels, then passes); a
 * term is issued only 8 or more cycles after the last term of its
 * accumulator (the issue waits otherwise).  The next pass is taken while
 * the last one's steps are in the pipeline; after a quad's last pass the
 * unit waits until it is empty (DRAIN), then FIN takes the lanes one a
 * cycle (the components the format has, (0, 0, 0, 1) for the others, the
 * swizzle; lanes outside tc_mask 0).
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
	wire u_ifmt_nc, u_inc_nc;	/* the carries not used */
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

	/* ---- P1-PV: the step's value and weight (atg_tu_ffront) ---- */
	wire vldv, f_busy0;
	wire [11:0] metav;
	wire [31:0] upv, wfv;

	atg_tu_ffront front (
		.clk(clk), .rst_n(rst_n), .i_vld(issue), .i_op(iop), .i_cs(gathq ? gsrc : c),
		.i_aid(aid), .i_t(it), .i_sl(tx[ik*128 +: 128]), .i_bd(bd[ik*4 +: 4]),
		.i_lo(lo[ik*8 +: 8]), .i_ft(ift), .i_wl(wts[ik*32 +: 32]), .i_bil(bil),
		.i_p17(ctl[17]), .i_p18(ctl[18]), .i_wg(wg), .i_gwi(gwi), .i_b8(b8), .i_b16(b16),
		.i_ifmt(ifmt), .i_blk(blk), .i_inf(inf_q), .i_sten(stq),
		.o_vld(vldv), .o_meta(metav), .o_up(upv), .o_wf(wfv), .o_busy(f_busy0)
	);

	wire [1:0] opv = metav[11:10], csv = metav[9:8];
	wire [3:0] aidv = metav[7:4];
	wire tbv = metav[3], esv = metav[2], ersv = metav[1], egsv = metav[0];

	/* ---- PV: the value; a bypass or gather writes it, a term goes on ---- */
	wire [31:0] ev = {csv == 2'd0 ? esv && ersv : csv == 2'd1 ? esv && egsv : upv[31],
		upv[30:0]};
	wire [31:0] bval = {1'b0, csv} < ncomp ?
		(bcls == 2'd2 || (bcls == 2'd1 && csv == 2'd3) ? one : 32'd0) :
		csv == 2'd3 ? one : 32'd0;
	wire [31:0] val = tbv ? bval : blk ? ev : upv;
	wire [31:0] gval = gsw == 3'd1 ? 32'd0 : gsw == 3'd2 ? one : val;
	wire wrv = vldv && opv != OP_FMA;

	wire f_cvld, f_rvld, f_busy;
	wire [3:0] f_ctag, f_rtag;
	wire [31:0] f_r;

	am_fp_fma #(.TW(4), .LAT(10)) fma (
		.clk(clk), .rst_n(rst_n), .i_vld(vldv && opv == OP_FMA), .i_tag(aidv),
		.i_a(wfv), .i_b(val), .c_vld(f_cvld), .c_tag(f_ctag), .c_val(acc[f_ctag*32 +: 32]),
		.rm(3'd0), .noc(1'b0),
		.r_vld(f_rvld), .r_tag(f_rtag), .r_val(f_r), .o_busy(f_busy)
	);

	/* busy: a step in the pipeline. */
	wire busy = f_busy0 || f_busy;

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

	/* ld: st is IDLE (its own register, replicated: it enables the pass's
	 * fields, about 800 registers) */
	(* max_fanout = 64 *) reg ld;

	assign tc_ready = ld;
	assign tr_valid = st == OUT;
	assign idle = ld && !mid;

	/* The pass's fields, taken in every cycle of IDLE (the enables do not
	 * wait for tc_valid). */
	always @(posedge clk)
		if (ld) begin
			tx <= tc_texels;
			bd <= tc_bord;
			lo <= tc_lo;
			wts <= tc_wts;
			mask <= tc_mask;
			ctl <= tc_ctl;
			tr_tag <= tc_tag;
			tr_last <= tc_last;
		end

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			ld <= 1'b1;
			mid <= 1'b0;
			hist <= 35'd0;
		end else begin
			hist <= {hist[29:0], issue && iop == OP_FMA, aid};
			case (st)
			IDLE: if (tc_valid) begin
				mid <= tc_ctl[4];
				st <= LOAD;
				ld <= 1'b0;
			end
			LOAD: begin
				if (!ctl[5])	/* the quad's first pass: the pipeline is empty */
					acc <= {16{32'h80000000}};
				rem <= wk;
				c <= 2'd0;
				st <= RUN;
			end
			RUN: if (rem == 16'd0 || (issue && rem_n == 16'd0)) begin
				st <= more ? IDLE : DRAIN;
				ld <= more;
			end else if (issue) begin
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
			default: if (tr_ready) begin
				st <= IDLE;
				ld <= 1'b1;
			end
			endcase
			/* the accumulators: a bypass or gather (PV), a term (am_fp_fma) */
			if (wrv)
				acc[aidv*32 +: 32] <= opv == OP_GATH ? gval : val;
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

	wire unused_ok = &{1'b0, u_ifmt_nc, u_inc_nc, gpos_l[4:0], ctl[33:23], ctl[16],
		ctl[20:19], ctl[12:8], ctl[3:1], vkf[7:4], f_cvld};
endmodule

`default_nettype wire
