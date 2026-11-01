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
	(* extract_reset = "no" *) output reg [15:0] tr_tag,
	(* extract_reset = "no" *) output reg [511:0] tr_data,
	(* extract_reset = "no" *) output reg tr_last
);
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	localparam [2:0] IDLE = 3'd0, LOAD = 3'd1, RUN = 3'd2, DRAIN = 3'd3, FIN = 3'd4,
		OUT = 3'd5, LOAD1 = 3'd6, LOAD2 = 3'd7;
	/* A step's kind */
	localparam [1:0] OP_FMA = 2'd0, OP_BYP = 2'd1, OP_GATH = 2'd2;
	wire u_ifmt_nc, u_inc_nc;	/* the carries not used */
	(* dont_touch = "true" *) wire rst_inv = !rst_n;
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

	(* max_fanout = 16 *) reg [2:0] st;
	(* extract_reset = "no", max_fanout = 16 *) reg [511:0] tx;
	(* extract_reset = "no", max_fanout = 16 *) reg [15:0] bd;
	(* extract_reset = "no", max_fanout = 16 *) reg [31:0] lo;
	(* extract_reset = "no", max_fanout = 16 *) reg [127:0] wts;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] mask;
	(* extract_reset = "no", max_fanout = 16 *) reg [49:0] ctl;
	(* extract_reset = "no", max_fanout = 16 *) reg [511:0] acc;	/* lane-major, 4 components a lane */

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
	wire [1:0] gsrc_l = gsw_l >= 3'd3 && gsw_l <= 3'd6 ? zsrc(gsw_l[1:0]) : comp;
	always @(*) begin
		case (comp)
		2'd0: gsw_l = swz[2:0];
		2'd1: gsw_l = swz[5:3];
		2'd2: gsw_l = swz[8:6];
		default: gsw_l = swz[11:9];
		endcase
	end
	wire [3:0] ifmt_l;	/* atg_tu_etc's format: VkFormat - 147 */

	am_sub #(.W(4)) u_ifmt (.a(vkf[3:0]), .b(4'd3), .bi(1'b0), .d(ifmt_l), .bo(u_ifmt_nc));

	/* The quad's constants, registered in LOAD (the same in every pass). */
	(* extract_reset = "no", max_fanout = 16 *) reg [67:0] inf_q;
	(* extract_reset = "no", max_fanout = 16 *) reg [2:0] ncomp, gsw;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] ncm1, gwi, gsrc, bcls;
	(* extract_reset = "no", max_fanout = 16 *) reg [31:0] one;
	(* extract_reset = "no", max_fanout = 16 *) reg blk, b8, b16, wg, stq, gathq;
	(* extract_reset = "no", max_fanout = 16 *) reg [11:0] swzq;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] ifmt;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] byp_q;
	(* extract_reset = "no", max_fanout = 16 *) reg [15:0] pr_q, nz_q;

	/* Gather word index computed in LOAD1 from registered inf_q, gsw, gsrc */
	reg [6:0] gpos_q;
	always @(*) begin
		case (gsrc)
		2'd0: gpos_q = inf_q[22:16];
		2'd1: gpos_q = inf_q[35:29];
		2'd2: gpos_q = inf_q[48:42];
		default: gpos_q = inf_q[61:55];
		endcase
	end
	wire [1:0] gwi_q = gsw == 3'd1 || gsw == 3'd2 || {1'b0, gsrc} >= inf_q[8:6] ? 2'd0 :
		gpos_q[6:5];

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

	/* ---- LOAD & LOAD1: the pass's work, wk[{t, k}]: a gathered texel, a
	 * bypassed lane's texel 0, or a term with a weight above 0 ---- */
	reg [3:0] byp_l;
	reg [15:0] pr_l, nz_l, wk;
	reg [1:0] tt, kk, ftt;
	reg [7:0] fu, fv, fl, fw;
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
			pr_l[i] = quad ? tt == 2'd0 : split ? !tt[1] : bil || gath || tt == 2'd0;
			ftt = ft_f(tt, quad, split, row, col);
			nz_l[i] = pr_l[i] && (!bil || !ftt[0] || fu != 8'd0) && (!bil || !ftt[1] || fv != 8'd0) &&
				!(ctl[17] && fw == 8'd0) && !(ctl[18] && fl == 8'd0);
			wk[i] = mask[kk] && (gathq ? pr_q[i] : byp_q[kk] ? tt == 2'd0 && ncomp != 3'd0 :
				nz_q[i] && ncomp != 3'd0);
		end
	end

	/* ---- RUN: the issue ---- */
	function [3:0] prio16;
		input [15:0] r;
		reg [3:0] c0;
		reg [1:0] h, l0, l1, l2, l3, l01, l23;
		begin
			c0[0] = (r[3:0]   != 4'd0);
			c0[1] = (r[7:4]   != 4'd0);
			c0[2] = (r[11:8]  != 4'd0);
			c0[3] = (r[15:12] != 4'd0);
			h[1] = !c0[0] && !c0[1];
			h[0] = !c0[0] && (c0[1] || !c0[2]);
			l0 = r[0]  ? 2'd0 : r[1]  ? 2'd1 : r[2]  ? 2'd2 : 2'd3;
			l1 = r[4]  ? 2'd0 : r[5]  ? 2'd1 : r[6]  ? 2'd2 : 2'd3;
			l2 = r[8]  ? 2'd0 : r[9]  ? 2'd1 : r[10] ? 2'd2 : 2'd3;
			l3 = r[12] ? 2'd0 : r[13] ? 2'd1 : r[14] ? 2'd2 : 2'd3;
			l01 = c0[0] ? l0 : l1;
			l23 = c0[2] ? l2 : l3;
			prio16 = {h, (c0[0] || c0[1]) ? l01 : l23};
		end
	endfunction

	function [15:0] first_onehot16;
		input [15:0] r;
		reg [3:0] c0;
		reg [15:0] nf;
		integer g;
		reg [3:0] nb;
		begin
			for (g = 0; g < 4; g = g + 1) begin
				nb = r[g*4 +: 4];
				c0[g] = (nb != 4'd0);
				nf[g*4 + 0] = nb[0];
				nf[g*4 + 1] = !nb[0] && nb[1];
				nf[g*4 + 2] = !nb[0] && !nb[1] && nb[2];
				nf[g*4 + 3] = !nb[0] && !nb[1] && !nb[2] && nb[3];
			end
			first_onehot16[3:0]   = nf[3:0];
			first_onehot16[7:4]   = c0[0] ? 4'd0 : nf[7:4];
			first_onehot16[11:8]  = (c0[0] || c0[1]) ? 4'd0 : nf[11:8];
			first_onehot16[15:12] = (c0[0] || c0[1] || c0[2]) ? 4'd0 : nf[15:12];
		end
	endfunction

	function is_one_left16;
		input [15:0] r;
		reg [3:0] c0, c2;
		integer g;
		reg [3:0] nb;
		begin
			for (g = 0; g < 4; g = g + 1) begin
				nb = r[g*4 +: 4];
				c0[g] = (nb != 4'd0);
				c2[g] = (nb != 4'd0) && (nb != 4'b0001) && (nb != 4'b0010) &&
				        (nb != 4'b0100) && (nb != 4'b1000);
			end
			is_one_left16 = (c2 == 4'b0000) &&
				(c0 == 4'b0001 || c0 == 4'b0010 || c0 == 4'b0100 || c0 == 4'b1000);
		end
	endfunction

	(* extract_reset = "no", max_fanout = 16 *) reg [15:0] rem;	/* the {texel, lane} still to issue */
	(* max_fanout = 16 *) reg rem_empty;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] c;	/* the component of the current {texel, lane} */
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] cur;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0] cur_it_slw, cur_it_aux;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0] cur_ik_tx [0:7];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0] cur_ik_wt [0:1];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0] cur_ik_aux;
	(* extract_reset = "no", max_fanout = 16 *) reg [15:0] cur1;
	(* extract_reset = "no", max_fanout = 16 *) reg rem_one_left;
	wire [1:0] it = cur[3:2], ik = cur[1:0];
	wire [1:0] iop = gathq ? OP_GATH : byp_q[ik] ? OP_BYP : OP_FMA;
	wire [1:0] ift = ft_f(it, quad, split, row, col);
	/* gather: word texel 2, 3, 1, 0 of the lane (texel t's place) */
	wire [1:0] gpos = ift == 2'd2 ? 2'd0 : ift == 2'd3 ? 2'd1 : ift == 2'd1 ? 2'd2 : 2'd3;
	wire [3:0] aid = iop == OP_GATH ? {ik, gpos} : {ik, c};
	wire lastc = iop == OP_GATH || c == ncm1;
	/* The terms of the last 7 cycles: one on the same accumulator waits. */
	(* max_fanout = 16 *) reg [34:0] hist;	/* 7 x {term, aid}, the latest in [4:0] */
	(* keep = "true" *) reg [15:0] haz_1to6_q;
	(* keep = "true" *) wire [3:0] haz_1to6_c = {
		haz_1to6_q[{ik, 2'd3}],
		haz_1to6_q[{ik, 2'd2}],
		haz_1to6_q[{ik, 2'd1}],
		haz_1to6_q[{ik, 2'd0}]
	};
	(* keep = "true" *) wire haz_1to6_sel = haz_1to6_c[c];
	(* keep = "true" *) wire haz_0 = hist[4] && (hist[3:0] == {ik, c});
	wire haz = haz_0 || haz_1to6_sel;
	(* keep = "true", max_fanout = 16 *) wire issue = st == RUN && !rem_empty && !(iop == OP_FMA && haz);
	(* keep = "true" *) wire [15:0] rem_n = rem & ~cur1;
	wire [1:0] c_inc;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] kf;	/* FIN's lane */
	(* extract_reset = "no", max_fanout = 16 *) reg [127:0] acc_kf_q;

	/* c + 1 (RUN) and FIN's next lane share an adder. */
	am_add #(.W(2)) u_inc (.a(st == FIN ? kf : c), .b(2'd0), .ci(1'b1), .s(c_inc),
		.co(u_inc_nc));

	/* ---- P1-PV: the step's value and weight (atg_tu_ffront) ---- */
	wire vldv, f_busy0;
	wire [11:0] meta_pre, metav;
	wire [31:0] upv, wfv;

	(* keep = "true" *) wire [127:0] front_sl;
	(* keep = "true" *) wire [31:0] front_wl;
	genvar gi;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_ik_tx
		assign front_sl[gi*16 +: 16] = tx[{cur_ik_tx[gi], gi[2:0], 4'd0} +: 16];
	end
	for (gi = 0; gi < 2; gi = gi + 1) begin : g_ik_wt
		assign front_wl[gi*16 +: 16] = wts[{cur_ik_wt[gi], gi[0], 4'd0} +: 16];
	end
	endgenerate

	(* keep_hierarchy = "yes" *) atg_tu_ffront front (
		.clk(clk), .rst_n(rst_n), .i_vld(issue), .i_op(iop), .i_cs(gathq ? gsrc : c),
		.i_aid(aid), .i_t_slw(cur_it_slw), .i_t_aux(cur_it_aux), .i_sl(front_sl), .i_bd(bd[cur_ik_aux*4 +: 4]),
		.i_lo(lo[cur_ik_aux*8 +: 8]), .i_ft(ift), .i_wl(front_wl), .i_bil(bil),
		.i_p17(ctl[17]), .i_p18(ctl[18]), .i_wg(wg), .i_gwi(gwi), .i_b8(b8), .i_b16(b16),
		.i_ifmt(ifmt), .i_blk(blk), .i_inf(inf_q), .i_sten(stq),
		.o_vld(vldv), .o_meta_pre(meta_pre), .o_meta(metav), .o_up(upv), .o_wf(wfv), .o_busy(f_busy0)
	);

	wire [1:0] csv_pre = meta_pre[9:8];
	wire tbv_pre = meta_pre[3], esv_pre = meta_pre[2], ersv_pre = meta_pre[1], egsv_pre = meta_pre[0];
	(* dont_touch = "true" *) wire bval_pre_use_one_lo = ({1'b0, csv_pre} < ncomp) ?
		(bcls == 2'd2 || (bcls == 2'd1 && csv_pre == 2'd3)) : (csv_pre == 2'd3);
	(* dont_touch = "true" *) wire bval_pre_use_one_hi = ({1'b0, csv_pre} < ncomp) ?
		(bcls == 2'd2 || (bcls == 2'd1 && csv_pre == 2'd3)) : (csv_pre == 2'd3);
	(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg val_tb_0_q, val_tb_1_q, val_tb_2_q, val_tb_3_q;
	(* extract_reset = "no", keep = "true" *) reg [31:0] val_bval_q;
	(* extract_reset = "no", keep = "true" *) reg val_ev_sgn_en_q, val_ev_sgn_q;
	always @(posedge clk) begin
		val_tb_0_q <= tbv_pre;
		val_tb_1_q <= tbv_pre;
		val_tb_2_q <= tbv_pre;
		val_tb_3_q <= tbv_pre;
		val_bval_q[15:0]  <= bval_pre_use_one_lo ? one[15:0]  : 16'd0;
		val_bval_q[31:16] <= bval_pre_use_one_hi ? one[31:16] : 16'd0;
		val_ev_sgn_en_q <= blk && !tbv_pre && (csv_pre == 2'd0 || csv_pre == 2'd1);
		val_ev_sgn_q <= (csv_pre == 2'd0) ? (esv_pre && ersv_pre) : (esv_pre && egsv_pre);
	end

	wire [1:0] opv = metav[11:10];
	wire [3:0] aidv = metav[7:4];
	(* keep = "true" *) wire [2:0] gsw_lo = gsw, gsw_hi = gsw;
	(* keep = "true" *) wire op_gath_lo = (opv == OP_GATH), op_gath_hi = (opv == OP_GATH);

	/* ---- PV: the value; a bypass or gather writes it, a term goes on ---- */
	wire [31:0] val = {
		val_ev_sgn_en_q ? val_ev_sgn_q : (val_tb_3_q ? val_bval_q[31] : upv[31]),
		val_tb_3_q ? val_bval_q[30:24] : upv[30:24],
		val_tb_2_q ? val_bval_q[23:16] : upv[23:16],
		val_tb_1_q ? val_bval_q[15:8]  : upv[15:8],
		val_tb_0_q ? val_bval_q[7:0]   : upv[7:0]
	};
	wire [31:0] gval = {
		gsw_hi == 3'd1 ? 16'd0 : gsw_hi == 3'd2 ? one[31:16] : val[31:16],
		gsw_lo == 3'd1 ? 16'd0 : gsw_lo == 3'd2 ? one[15:0]  : val[15:0]
	};
	wire wrv = vldv && opv != OP_FMA;

	wire f_cvld, f_rvld, f_busy;
	wire [3:0] f_ctag, f_rtag;
	wire [31:0] f_r;
	(* keep = "true" *) wire [3:0] f_ctag_s [0:7];
	wire [31:0] fma_c_val;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_fma_cval
		assign f_ctag_s[gi] = f_ctag;
		assign fma_c_val[gi*4 +: 4] = acc[{f_ctag_s[gi], gi[2:0], 2'd0} +: 4];
	end
	endgenerate

	(* keep_hierarchy = "yes" *) atg_tu_fma #(.TW(4)) fma (
		.clk(clk), .rst_n(rst_n), .i_vld(vldv && opv == OP_FMA), .i_tag(aidv),
		.i_a(wfv), .i_b(val), .c_vld(f_cvld), .c_tag(f_ctag), .c_val(fma_c_val),
		.rm(3'd0), .noc(1'b0),
		.r_vld(f_rvld), .r_tag(f_rtag), .r_val(f_r), .o_busy(f_busy)
	);

	/* busy: a step in the pipeline. */
	wire busy = f_busy0 || f_busy;

	/* The result of lane kf (FIN takes the lanes one a cycle, using pre-fetched acc_kf_q). */
	(* dont_touch = "true" *) wire [23:0] ncomp_fin_s = {8{ncomp}};
	(* dont_touch = "true" *) wire [15:0] mask_kf_s = {16{mask[kf]}};
	(* dont_touch = "true" *) wire [15:0] gathq_fin_s = {16{gathq}};
	(* dont_touch = "true" *) wire [11:0] swz_fin_0 = swzq;
	(* dont_touch = "true" *) wire [11:0] swz_fin_1 = swzq;
	(* dont_touch = "true" *) wire [11:0] swz_fin_2 = swzq;
	(* dont_touch = "true" *) wire [11:0] swz_fin_3 = swzq;

	reg [127:0] fin_raw;
	always @(*) begin
		for (m = 0; m < 4; m = m + 1) begin
			fin_raw[m*32 +: 16]      = (m[2:0] < ncomp_fin_s[(2*m)*3 +: 3])     ? acc_kf_q[m*32 +: 16]      : (m == 3 ? one[15:0]  : 16'd0);
			fin_raw[m*32 + 16 +: 16] = (m[2:0] < ncomp_fin_s[(2*m + 1)*3 +: 3]) ? acc_kf_q[m*32 + 16 +: 16] : (m == 3 ? one[31:16] : 16'd0);
		end
	end
	(* keep = "true" *) wire [127:0] fin = fin_raw;

	reg [127:0] fin_swz_raw;
	reg [127:0] fin_q_raw;
	reg [2:0] sc_0, sc_1, sc_2, sc_3;
	always @(*) begin
		for (m = 0; m < 4; m = m + 1) begin
			sc_0 = swz_fin_0[m*3 +: 3];
			sc_1 = swz_fin_1[m*3 +: 3];
			sc_2 = swz_fin_2[m*3 +: 3];
			sc_3 = swz_fin_3[m*3 +: 3];
			fin_swz_raw[m*32 +: 8] = sc_0 == 3'd1 ? 8'd0 : sc_0 == 3'd2 ? one[7:0] :
				(sc_0 >= 3'd3 && sc_0 <= 3'd6) ? fin[{zsrc(sc_0[1:0]), 5'd0} +: 8] : fin[m*32 +: 8];
			fin_swz_raw[m*32 + 8 +: 8] = sc_1 == 3'd1 ? 8'd0 : sc_1 == 3'd2 ? one[15:8] :
				(sc_1 >= 3'd3 && sc_1 <= 3'd6) ? fin[{zsrc(sc_1[1:0]), 5'd8} +: 8] : fin[m*32 + 8 +: 8];
			fin_swz_raw[m*32 + 16 +: 8] = sc_2 == 3'd1 ? 8'd0 : sc_2 == 3'd2 ? one[23:16] :
				(sc_2 >= 3'd3 && sc_2 <= 3'd6) ? fin[{zsrc(sc_2[1:0]), 5'd16} +: 8] : fin[m*32 + 16 +: 8];
			fin_swz_raw[m*32 + 24 +: 8] = sc_3 == 3'd1 ? 8'd0 : sc_3 == 3'd2 ? one[31:24] :
				(sc_3 >= 3'd3 && sc_3 <= 3'd6) ? fin[{zsrc(sc_3[1:0]), 5'd24} +: 8] : fin[m*32 + 24 +: 8];
		end
	end
	(* keep = "true" *) wire [127:0] fin_swz = fin_swz_raw;
	always @(*) begin
		for (i = 0; i < 16; i = i + 1) begin
			fin_q_raw[i*8 +: 8] = !mask_kf_s[i] ? 8'd0 :
				gathq_fin_s[i] ? acc_kf_q[i*8 +: 8] : fin_swz[i*8 +: 8];
		end
	end
	(* keep = "true" *) wire [127:0] fin_q = fin_q_raw;

	reg mid;	/* a pass with more to follow taken, its last not yet */

	/* ld: st is IDLE (its own register, replicated: it enables the pass's
	 * fields, about 800 registers) */
	(* max_fanout = 16 *) reg ld;
	(* keep = "true", equivalent_register_removal = "no" *) reg [63:0] ld_s;
	wire ld_n = (st == IDLE) ? !tc_valid :
		(st == RUN && (rem_empty || (issue && rem_one_left && lastc))) ? more :
		(st == OUT) ? tr_ready : ld;
	(* dont_touch = "true" *) wire [7:0] ld_n_g = {8{ld_n}};

	assign tc_ready = ld;
	assign tr_valid = st == OUT;
	assign idle = ld && !mid;

	/* The pass's fields, taken in every cycle of IDLE (the enables do not
	 * wait for tc_valid). */
	always @(posedge clk) begin
		for (i = 0; i < 32; i = i + 1)
			if (ld_s[i])
				tx[i*16 +: 16] <= tc_texels[i*16 +: 16];
		for (i = 0; i < 8; i = i + 1)
			if (ld_s[32 + i])
				wts[i*16 +: 16] <= tc_wts[i*16 +: 16];
		if (ld_s[40])
			bd <= tc_bord;
		if (ld_s[41])
			lo[15:0] <= tc_lo[15:0];
		if (ld_s[42])
			lo[31:16] <= tc_lo[31:16];
		for (i = 0; i < 16; i = i + 1)
			if (ld_s[43 + i])
				ctl[i*3 +: 3] <= tc_ctl[i*3 +: 3];
		if (ld_s[59])
			ctl[49:48] <= tc_ctl[49:48];
		if (ld_s[60]) begin
			mask <= tc_mask;
			tr_last <= tc_last;
		end
		if (ld_s[61])
			tr_tag[7:0] <= tc_tag[7:0];
		if (ld_s[62])
			tr_tag[15:8] <= tc_tag[15:8];
	end

	(* keep = "true" *) wire [31:0] wrv_val = {
		op_gath_hi ? gval[31:16] : val[31:16],
		op_gath_lo ? gval[15:0]  : val[15:0]
	};
	(* keep = "true" *) wire acc_clr = (st == LOAD) && !ctl[5];
	(* dont_touch = "true" *) wire [3:0] acc_clr_g = {4{acc_clr}};
	(* keep = "true" *) wire [15:0] acc_clr_w;
	(* keep = "true" *) wire [15:0] acc_wrv_w;
	(* keep = "true" *) wire [15:0] acc_fma_w;
	(* keep = "true" *) wire [63:0] acc_clr_s;
	(* keep = "true" *) wire [63:0] acc_wrv_s;
	(* keep = "true" *) wire [63:0] acc_fma_s;
	(* keep = "true" *) wire [3:0] fin_lwe;
	(* keep = "true" *) wire [31:0] fin_we_s;
	wire drain_ce_raw = (st == DRAIN) && !busy;
	wire fin_ce_raw   = (st == FIN);
	wire load_ce_raw  = (st == LOAD);
	(* dont_touch = "true" *) wire [1:0] drain_ce_g = {2{drain_ce_raw}};
	(* dont_touch = "true" *) wire [1:0] fin_ce_g   = {2{fin_ce_raw}};
	(* dont_touch = "true" *) wire [2:0] load_ce_g  = {3{load_ce_raw}};
	(* dont_touch = "true" *) wire [15:0] drain_ce_s = {{8{drain_ce_g[1]}}, {8{drain_ce_g[0]}}};
	(* dont_touch = "true" *) wire [15:0] fin_ce_s   = {{8{fin_ce_g[1]}}, {8{fin_ce_g[0]}}};
	(* dont_touch = "true" *) wire [23:0] load_ce_s  = {{8{load_ce_g[2]}}, {8{load_ce_g[1]}}, {8{load_ce_g[0]}}};
	(* dont_touch = "true" *) wire [1:0] kf_idx_s [0:15];
	genvar ga;
	generate
	for (ga = 0; ga < 16; ga = ga + 1) begin : g_c_inc
		assign kf_idx_s[ga] = (st == FIN) ? c_inc : 2'd0;
	end
	for (ga = 0; ga < 16; ga = ga + 1) begin : g_acc_en
		assign acc_clr_w[ga] = acc_clr_g[ga / 4];
		assign acc_wrv_w[ga] = wrv && (aidv == ga[3:0]);
		assign acc_fma_w[ga] = f_rvld && (f_rtag == ga[3:0]);
		assign acc_clr_s[4*ga +: 4] = {4{acc_clr_w[ga]}};
		assign acc_wrv_s[4*ga +: 4] = {4{acc_wrv_w[ga]}};
		assign acc_fma_s[4*ga +: 4] = {4{acc_fma_w[ga]}};
	end
	for (ga = 0; ga < 4; ga = ga + 1) begin : g_fin_en
		assign fin_lwe[ga] = (st == FIN) && (kf == ga[1:0]);
		assign fin_we_s[ga*8 +: 8] = {8{fin_lwe[ga]}};
	end
	endgenerate

	wire rem_ld_en  = (st == LOAD1);
	wire rem_run_en = (st == RUN) && !rem_empty && issue && !rem_one_left && lastc;
	wire cur_ld_en  = (st == LOAD2);
	(* dont_touch = "true" *) wire [3:0] rem_ce_s = {4{rem_ld_en || rem_run_en}};
	(* dont_touch = "true" *) wire [3:0] cur_ce_s = {4{cur_ld_en || rem_run_en}};
	wire [15:0] rem_nxt = (st == LOAD1) ? wk : rem_n;
	wire [3:0]  cur_nxt  = (st == LOAD2) ? prio16(rem) : prio16(rem_n);
	wire [15:0] cur1_nxt = (st == LOAD2) ? first_onehot16(rem) : first_onehot16(rem_n);
	wire        rol_nxt  = (st == LOAD2) ? is_one_left16(rem) : is_one_left16(rem_n);

	always @(posedge clk) begin
		if (rst_inv) begin
			st <= IDLE;
			ld <= 1'b1;
			ld_s <= {64{1'b1}};
			mid <= 1'b0;
			hist <= 35'd0;
			haz_1to6_q <= 16'd0;
			rem_empty <= 1'b1;
		end else begin
			ld <= ld_n;
			for (i = 0; i < 64; i = i + 1)
				ld_s[i] <= ld_n_g[i / 8];
			hist <= {hist[29:0], issue && iop == OP_FMA, aid};
			for (i = 0; i < 16; i = i + 1) begin
				haz_1to6_q[i] <= (hist[4]  && hist[3:0]   == i[3:0]) ||
				                 (hist[9]  && hist[8:5]   == i[3:0]) ||
				                 (hist[14] && hist[13:10] == i[3:0]) ||
				                 (hist[19] && hist[18:15] == i[3:0]) ||
				                 (hist[24] && hist[23:20] == i[3:0]) ||
				                 (hist[29] && hist[28:25] == i[3:0]);
			end
			case (st)
			IDLE: if (tc_valid) begin
				mid <= tc_ctl[4];
				st <= LOAD;
			end
			LOAD: begin
				st <= LOAD1;
			end
			LOAD1: begin
				rem_empty <= wk == 16'd0;
				st <= LOAD2;
			end
			LOAD2: begin
				c <= 2'd0;
				st <= RUN;
			end
			RUN: if (rem_empty || (issue && rem_one_left && lastc)) begin
				st <= more ? IDLE : DRAIN;
			end else if (issue) begin
				if (lastc) begin
					rem_empty <= 1'b0;
				end
				c <= lastc ? 2'd0 : c_inc;
			end
			DRAIN: if (!busy) begin
				kf <= 2'd0;
				st <= FIN;
			end
			FIN: begin
				kf <= c_inc;
				if (kf == 2'd3)
					st <= OUT;
			end
			default: if (tr_ready) begin
				st <= IDLE;
			end
			endcase
		end
	end

	/* Non-reset datapath updates */
	always @(posedge clk) begin
		for (i = 0; i < 4; i = i + 1) begin
			if (rem_ce_s[i])
				rem[i*4 +: 4] <= rem_nxt[i*4 +: 4];
			if (cur_ce_s[i])
				cur1[i*4 +: 4] <= cur1_nxt[i*4 +: 4];
		end
		if (cur_ce_s[0]) begin
			cur <= cur_nxt;
			rem_one_left <= rol_nxt;
		end
		if (cur_ce_s[1]) begin
			cur_it_slw <= cur_nxt[3:2];
			cur_it_aux <= cur_nxt[3:2];
			cur_ik_tx[0] <= cur_nxt[1:0];
			cur_ik_tx[1] <= cur_nxt[1:0];
			cur_ik_tx[2] <= cur_nxt[1:0];
		end
		if (cur_ce_s[2]) begin
			cur_ik_tx[3] <= cur_nxt[1:0];
			cur_ik_tx[4] <= cur_nxt[1:0];
			cur_ik_tx[5] <= cur_nxt[1:0];
			cur_ik_tx[6] <= cur_nxt[1:0];
		end
		if (cur_ce_s[3]) begin
			cur_ik_tx[7] <= cur_nxt[1:0];
			cur_ik_wt[0] <= cur_nxt[1:0];
			cur_ik_wt[1] <= cur_nxt[1:0];
			cur_ik_aux   <= cur_nxt[1:0];
		end
		for (i = 0; i < 16; i = i + 1) begin
			if (drain_ce_s[i] || fin_ce_s[i])
				acc_kf_q[i*8 +: 8] <= acc[{kf_idx_s[i], i[3:0], 3'd0} +: 8];
		end
		for (i = 0; i < 4; i = i + 1)
			for (m = 0; m < 8; m = m + 1)
				if (fin_we_s[i*8 + m])
					tr_data[i*128 + m*16 +: 16] <= fin_q[m*16 +: 16];
		/* the accumulators: clear in LOAD, bypass or gather (PV), term (am_fp_fma) */
		for (i = 0; i < 16; i = i + 1) begin
			if (acc_clr_s[4*i + 0]) acc[i*32 +: 8]       <= 8'h00;
			if (acc_clr_s[4*i + 1]) acc[i*32 + 8 +: 8]   <= 8'h00;
			if (acc_clr_s[4*i + 2]) acc[i*32 + 16 +: 8]  <= 8'h00;
			if (acc_clr_s[4*i + 3]) acc[i*32 + 24 +: 8]  <= 8'h80;
			if (acc_wrv_s[4*i + 0]) acc[i*32 +: 8]       <= wrv_val[7:0];
			if (acc_wrv_s[4*i + 1]) acc[i*32 + 8 +: 8]   <= wrv_val[15:8];
			if (acc_wrv_s[4*i + 2]) acc[i*32 + 16 +: 8]  <= wrv_val[23:16];
			if (acc_wrv_s[4*i + 3]) acc[i*32 + 24 +: 8]  <= wrv_val[31:24];
			if (acc_fma_s[4*i + 0]) acc[i*32 +: 8]       <= f_r[7:0];
			if (acc_fma_s[4*i + 1]) acc[i*32 + 8 +: 8]   <= f_r[15:8];
			if (acc_fma_s[4*i + 2]) acc[i*32 + 16 +: 8]  <= f_r[23:16];
			if (acc_fma_s[4*i + 3]) acc[i*32 + 24 +: 8]  <= f_r[31:24];
		end
	end

	/* The quad's constants (LOAD and LOAD1). */
	always @(posedge clk) begin
		if (load_ce_s[0])  inf_q[7:0]   <= inf[7:0];
		if (load_ce_s[1])  inf_q[15:8]  <= inf[15:8];
		if (load_ce_s[2])  inf_q[23:16] <= inf[23:16];
		if (load_ce_s[3])  inf_q[31:24] <= inf[31:24];
		if (load_ce_s[4])  inf_q[39:32] <= inf[39:32];
		if (load_ce_s[5])  inf_q[47:40] <= inf[47:40];
		if (load_ce_s[6])  inf_q[55:48] <= inf[55:48];
		if (load_ce_s[7])  inf_q[63:56] <= inf[63:56];
		if (load_ce_s[8]) begin
			inf_q[67:64] <= inf[67:64];
			ncomp <= ncomp_l;
			case (ncomp_l)
			3'd2: ncm1 <= 2'd1;
			3'd3: ncm1 <= 2'd2;
			3'd4: ncm1 <= 2'd3;
			default: ncm1 <= 2'd0;
			endcase
			blk <= inf[14];
			b8 <= inf[5:1] == 5'd8;
			b16 <= inf[5:1] == 5'd16;
			wg <= gath && !inf[14];
		end
		if (load_ce_s[9])  one[15:0]  <= isint_l ? 16'd1 : 16'h0000;
		if (load_ce_s[10]) one[31:16] <= isint_l ? 16'd0 : 16'h3F80;
		if (load_ce_s[11]) begin
			gsw <= gsw_l;
			gsrc <= gsrc_l;
			bcls <= ctl[7:6];
			stq <= sten;
			gathq <= gath;
			ifmt <= ifmt_l;
			byp_q <= byp_l;
		end
		if (load_ce_s[12]) swzq[5:0]  <= swz[5:0];
		if (load_ce_s[13]) swzq[11:6] <= swz[11:6];
		if (load_ce_s[14]) pr_q[7:0]  <= pr_l[7:0];
		if (load_ce_s[15]) pr_q[15:8] <= pr_l[15:8];
		if (load_ce_s[16]) nz_q[7:0]  <= nz_l[7:0];
		if (load_ce_s[17]) nz_q[15:8] <= nz_l[15:8];
		if (st == LOAD1) begin
			gwi <= gwi_q;
		end
	end

	wire unused_ok = &{1'b0, u_ifmt_nc, u_inc_nc, gpos_q[4:0], ctl[33:23], ctl[16],
		ctl[20:19], ctl[12:8], ctl[3:1], vkf[7:4], f_cvld, load_ce_s[23:18],
		meta_pre[11:10], meta_pre[7:4], metav[9:8], metav[3:0], ld_s[63]};
endmodule

`default_nettype wire
