/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_xu: The SU's shared transcendental unit: rcp, rsq (table + one
 * Newton step), exp2, log2, sin, cos (range reduction + polynomial) and
 * fsqrt; one lane at a time, results as long beats.
 *
 * Takes one lane group at a time (x_ready is 1 only in IDLE) and
 * computes its EXEC lanes one after the other in a sequential engine,
 * then returns the group as one long beat (l_wr 1, l_last = the group's
 * x_last, class x); a group without EXEC lanes returns at once.  The
 * algorithms are integer and exact step for step with tools/gsi1fp.py
 * xu() (the model the SU testbench compares with):
 *   rcp    2^50 / m by a 28-step restoring division, RNE with the
 *          remainder as sticky (correctly rounded);
 *   fsqrt  isqrt(m << 26) bit by bit (26 steps), correctly rounded;
 *   rsq    t = isqrt(m << 34) (30 steps), then 2^57 / t (29 steps);
 *   exp2   x in Q8.30, 2^frac as the product of 2^(2^-i) (30 steps, one
 *          multiply each), the integer part in the exponent;
 *   log2   the mantissa squared 30 times (one bit of the fraction each),
 *          the exponent as the integer part (absolute error about 2^-22);
 *   sin, cos  x / (2 pi) in turns (Q0.40, mod 1), the quadrant, then 26
 *          CORDIC rotations; |x| < 2^-12 gives x and 1.0 (absolute error
 *          about 2^-24 on [-pi, pi]).
 * Inputs are flushed (denormals as zeros); results through am_fp_rnd
 * (RNE, flushed).  Constants: include/atg_su_xu_tab.vh.
 *
 * States: IDLE →(group)→ LOAD → STEP (per op) → FIN → (next lane | RET)
 * →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_xu #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
) (
	input wire clk,
	input wire rst_n,
	/* Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,
	/* Long result to atg_su_wb (any time; wb may refuse with l_ready = 0) */
	output wire l_valid,
	input wire l_ready,
	output wire [WARP_W-1:0] l_warp,
	output wire [GRP_W-1:0] l_grp,
	output wire [6:0] l_rd,
	output wire [NPHYS*32-1:0] l_data,
	output wire [NPHYS-1:0] l_lanes,
	output wire l_wr,
	output wire l_last,
	output wire [SBE_W:0] l_sbe,
	output wire [2:0] l_cls
);
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"
`include "atg_su_xu_tab.vh"

	localparam DW = NPHYS * 32;
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [2:0] IDLE = 3'd0, LOAD = 3'd1, STEP = 3'd2, FIN = 3'd3, STORE = 3'd4, RET = 3'd5;

	(* keep = "true" *) wire rst_p = !rst_n;

	(* max_fanout = 12 *) reg [2:0] st;
	wire [DW-1:0] rx, rq;
	(* max_fanout = 12 *) reg [NPHYS-1:0] rmask;
	(* max_fanout = 12 *) reg [2:0] rop;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	(* max_fanout = 12 *) reg [LW-1:0] li;
	(* max_fanout = 12 *) reg [5:0] step;
	(* max_fanout = 12 *) reg ph;			/* rsq: 0 square root, 1 division */
	/* The engine. */
	(* max_fanout = 12 *) reg [59:0] n;		/* sqrt: the radicand, two bits per step from the top */
	(* max_fanout = 12 *) reg [33:0] rem;		/* division and sqrt remainder */
	(* max_fanout = 12 *) reg [29:0] root;	/* quotient / root */
	reg stk;		/* rsq: the square root was inexact */
	(* max_fanout = 12 *) reg [41:0] y;		/* exp2 / log2 */
	(* max_fanout = 12 *) reg [29:0] fr;		/* exp2: the fraction bits; log2: the result bits */
	(* max_fanout = 12 *) reg signed [11:0] ex;	/* the exponent of the result's LSB */
	(* max_fanout = 12 *) reg signed [35:0] cx, cy;
	(* max_fanout = 12 *) reg signed [40:0] z;
	reg qneg;		/* sin/cos: the quadrant's sign */
	reg sres;		/* a special result is in res */
	(* max_fanout = 12 *) reg [31:0] res;

	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_XU;
	assign x_ready = st == IDLE;

	function [LW:0] next_lane;
		input [NPHYS-1:0] m;
		input [LW:0] k;
		integer i;
		begin
			next_lane = NPHYS[LW:0];
			for (i = NPHYS - 1; i >= 0; i = i - 1)
				if (m[i] && i >= k)
					next_lane = i[LW:0];
		end
	endfunction

	wire [27:0] carry_unused;	/* the adders' carries and borrows */
	wire [LW:0] first = next_lane(x_mask[NPHYS-1:0], {(LW+1){1'b0}});
	wire [LW:0] li1;
	am_add #(.W(LW+1)) u_li1 (.a({1'b0, li}), .b({(LW+1){1'b0}}), .ci(1'b1), .s(li1),
		.co(carry_unused[0]));
	wire [LW:0] after = next_lane(rmask, li1);
	/* The lane's input, flushed, and its fields (registered in sub_st 0). */
	wire [31:0] lx_raw = atg_su_flush(rx[li*32 +: 32]);
	(* max_fanout = 12 *) reg [31:0] lx;
	(* max_fanout = 12 *) reg [23:0] lm_r;
	(* max_fanout = 12 *) reg [3:0] sub_st;
	wire ls = lx[31];
	(* max_fanout = 12 *) wire [7:0] le = lx[30:23];
	wire [23:0] lm = lm_r;
	(* max_fanout = 12 *) wire lnan = le == 8'hFF && lx[22:0] != 0;
	(* max_fanout = 12 *) wire linf = le == 8'hFF && lx[22:0] == 0;
	(* max_fanout = 12 *) wire lzero = le == 8'd0;
	wire lodd = le[0];	/* e - 150 odd */
	wire [24:0] lmm = lodd ? {lm, 1'b0} : {1'b0, lm};
	/* ee/2 with ee = e - 150 (- 1 when odd). */
	wire [11:0] hee_d, esh, tsh;
	wire [6:0] ersh;
	wire [7:0] trsh;
	(* max_fanout = 12 *) reg signed [11:0] hee_r;
	(* max_fanout = 12 *) reg [11:0] esh_r, tsh_r;
	(* max_fanout = 12 *) reg [6:0] ersh_r;
	(* max_fanout = 12 *) reg [7:0] trsh_r;
	am_sub #(.W(12)) u_hee (.a({4'd0, le}), .b(12'd150), .bi(lodd), .d(hee_d), .bo(carry_unused[1]));
	wire signed [11:0] hee = $signed(hee_d) >>> 1;
	/* exp2: x in Q8.30 (sh = e - 120 <= 14 here). */
	am_sub #(.W(12)) u_esh (.a({4'd0, le}), .b(12'd120), .bi(1'b0), .d(esh), .bo(carry_unused[2]));
	am_sub #(.W(7)) u_ersh (.a(7'd120), .b(le[6:0]), .bi(1'b0), .d(ersh), .bo(carry_unused[3]));
	wire [38:0] ev0, ev;
	reg [38:0] ev0_r, ev_r;
	am_shift #(.W(39), .SW(7)) u_ev0 (.a({15'd0, lm}), .amt(esh_r[11] ? ersh_r : {3'd0, esh_r[3:0]}),
		.left(!esh_r[11]), .arith(1'b0), .y(ev0));
	am_addsub #(.W(39)) u_ev (.a(39'd0), .b(ev0_r), .sub(ls), .s(ev), .co(carry_unused[6]));
	/* sin/cos: the turns (split into 4 single-DSP 24x<=17 multiplies). */
	wire [40:0] tp0, tp1, tp2;
	wire [31:0] tp3;
	(* dont_touch = "true" *) reg [40:0] tp0_r, tp1_r, tp2_r;
	(* dont_touch = "true" *) reg [31:0] tp3_r;
	reg [40:0] tp2_rr;
	wire [82:0] tp_s0, tp, tps;
	reg [82:0] tp_s0_r;
	(* dont_touch = "true" *) reg [82:0] tp_r;
	wire [82:0] tps_r;
	am_mul #(.AW(24), .BW(17), .LAT(2)) u_tp0 (.clk(clk), .en(1'b1), .a(lm_r), .b(XU_INV2PI[16:0]), .p(tp0));
	am_mul #(.AW(24), .BW(17), .LAT(2)) u_tp1 (.clk(clk), .en(1'b1), .a(lm_r), .b(XU_INV2PI[33:17]), .p(tp1));
	am_mul #(.AW(24), .BW(17), .LAT(2)) u_tp2 (.clk(clk), .en(1'b1), .a(lm_r), .b(XU_INV2PI[50:34]), .p(tp2));
	am_mul #(.AW(24), .BW(8),  .LAT(2)) u_tp3 (.clk(clk), .en(1'b1), .a(lm_r), .b(XU_INV2PI[58:51]), .p(tp3));
	am_add #(.W(83)) u_tp_s0 (.a({tp3_r, 10'd0, tp0_r}), .b({25'd0, tp1_r, 17'd0}), .ci(1'b0),
		.s(tp_s0), .co(carry_unused[22]));
	am_add #(.W(83)) u_tp_s1 (.a(tp_s0_r), .b({8'd0, tp2_rr, 34'd0}), .ci(1'b0),
		.s(tp), .co(carry_unused[23]));
	am_sub #(.W(12)) u_tsh (.a({4'd0, le}), .b(12'd171), .bi(1'b0), .d(tsh), .bo(carry_unused[4]));
	am_sub #(.W(8)) u_trsh (.a(8'd171), .b(le), .bi(1'b0), .d(trsh), .bo(carry_unused[5]));
	/* The low 40 bits of tp[39:0] << tsh or tp >> -tsh: one shifter. */
	am_shift #(.W(83), .SW(8)) u_tps (.a(tp_r), .amt(tsh_r[11] ? trsh_r : {2'd0, tsh_r[5:0]}), .left(!tsh_r[11]),
		.arith(1'b0), .y(tps));
	wire [39:0] t0 = $signed(tsh_r) >= 12'sd40 ? 40'd0 : tps_r[39:0];
	wire [39:0] t1, tt;
	reg [39:0] t1_r, tt_r;
	am_addsub #(.W(40)) u_t1 (.a(40'd0), .b(t0), .sub(ls), .s(t1), .co(carry_unused[7]));
	am_add #(.W(40)) u_tt (.a(t1_r), .b(rop == ATG_XU_COS[2:0] ? 40'h4000000000 : 40'd0), .ci(1'b0),
		.s(tt), .co(carry_unused[8]));
	/* The shared multiplier (exp2: y * K, log2: y * y), split into 6 single-DSP <=24x<=17 multiplies. */
	(* rom_style = "distributed", ram_style = "distributed" *) reg [41:0] mb_r;
	wire [40:0] p00, p01;
	wire [31:0] p02;
	wire [34:0] p10, p11;
	wire [25:0] p12;
	(* dont_touch = "true" *) reg [40:0] p00_r, p01_r;
	(* dont_touch = "true" *) reg [31:0] p02_r;
	(* dont_touch = "true" *) reg [34:0] p10_r, p11_r;
	(* dont_touch = "true" *) reg [25:0] p12_r;
	wire [83:0] psum0, psum1, prod;
	reg [83:0] psum0_r, psum1_r;
	(* dont_touch = "true" *) reg [83:0] prod_r;
	am_mul #(.AW(24), .BW(17), .LAT(2)) u_p00 (.clk(clk), .en(1'b1), .a(y[23:0]),  .b(mb_r[16:0]),  .p(p00));
	am_mul #(.AW(24), .BW(17), .LAT(2)) u_p01 (.clk(clk), .en(1'b1), .a(y[23:0]),  .b(mb_r[33:17]), .p(p01));
	am_mul #(.AW(24), .BW(8),  .LAT(2)) u_p02 (.clk(clk), .en(1'b1), .a(y[23:0]),  .b(mb_r[41:34]), .p(p02));
	am_mul #(.AW(18), .BW(17), .LAT(2)) u_p10 (.clk(clk), .en(1'b1), .a(y[41:24]), .b(mb_r[16:0]),  .p(p10));
	am_mul #(.AW(18), .BW(17), .LAT(2)) u_p11 (.clk(clk), .en(1'b1), .a(y[41:24]), .b(mb_r[33:17]), .p(p11));
	am_mul #(.AW(18), .BW(8),  .LAT(2)) u_p12 (.clk(clk), .en(1'b1), .a(y[41:24]), .b(mb_r[41:34]), .p(p12));
	am_add #(.W(84)) u_ps0 (.a({8'd0, p11_r, p00_r}), .b({p12_r, p01_r, 17'd0}), .ci(1'b0),
		.s(psum0), .co(carry_unused[24]));
	am_add #(.W(84)) u_ps1 (.a({25'd0, p10_r, 24'd0}), .b({18'd0, p02_r, 34'd0}), .ci(1'b0),
		.s(psum1), .co(carry_unused[25]));
	am_add #(.W(84)) u_prod (.a(psum0_r), .b(psum1_r), .ci(1'b0),
		.s(prod), .co(carry_unused[26]));
	/* The division step (rcp, rsq phase 1) and the sqrt step. */
	wire [34:0] dtr, strl;
	wire [33:0] srem = {rem[31:0], n[59:58]};
	am_sub #(.W(35)) u_dtr (.a({rem, 1'b0}), .b(rop == ATG_XU_RCP[2:0] ? {11'd0, lm} : {5'd0, root}),
		.bi(1'b0), .d(dtr), .bo(carry_unused[9]));
	am_sub #(.W(35)) u_strl (.a({1'b0, srem}), .b({3'd0, root, 2'b01}), .bi(1'b0), .d(strl),
		.bo(carry_unused[10]));
	wire [33:0] snext = strl[34] ? srem : strl[33:0];
	/* The step counts, less one. */
	wire [5:0] nsteps_m1 = rop == ATG_XU_RCP[2:0] ? 6'd27 : rop == ATG_XU_FSQRT[2:0] ? 6'd25 :
		rop == ATG_XU_RSQ[2:0] ? (ph ? 6'd28 : 6'd29) :
		(rop == ATG_XU_SIN[2:0] || rop == ATG_XU_COS[2:0]) ? 6'd25 : 6'd29;
	wire [39:0] atn = xu_atan(step[4:0]);
	(* rom_style = "distributed", ram_style = "distributed" *) reg [39:0] atn_r;
	wire [10:0] lue;
	reg [10:0] lue_r;
	am_sub #(.W(11)) u_lue (.a({3'd0, le}), .b(11'd127), .bi(1'b0), .d(lue), .bo(carry_unused[11]));
	wire [40:0] lv = {lue_r, fr};	/* log2: (e - 127) << 30 | fraction, signed */
	wire [40:0] lva;
	reg [40:0] lva_r;
	am_addsub #(.W(41)) u_lva (.a(41'd0), .b(lv), .sub(lv[40]), .s(lva), .co(carry_unused[12]));
	/* The result of a finished lane (state FIN): an integer v (< 2^41) times 2^e, sign s, to
	 * fp32 (RNE, flushed). */
	reg ns, nst, nz, fbit;	/* nz: the result is 0; fbit: fr[29 - step] (exp2) */
	reg [40:0] nv;
	reg [11:0] ne;
	reg [5:0] np;
	reg ns_r, nst_r, nz_r;
	reg [40:0] nv_r;
	reg [11:0] ne_r;
	reg [5:0] np_r;
	integer pi;
	always @(*) begin
		{ns, nst, nz, ne} = {3'b000, ex};
		case (rop)
		ATG_XU_RCP[2:0]: {ns, nv, nst} = {ls, 13'd0, root[27:0], rem != 34'd0};
		ATG_XU_FSQRT[2:0]: {nv, nst} = {15'd0, root[25:0], rem != 34'd0};
		ATG_XU_RSQ[2:0]: {nv, nst} = {12'd0, n[28:0], rem != 34'd0 || stk};
		ATG_XU_EXP2[2:0]: nv = y[40:0];
		ATG_XU_LOG2[2:0]: {ns, nv, ne, nz} = {lv[40], lva_r, -12'sd30, lv == 41'd0};
		default: {ns, nv, ne, nz} = {qneg, 5'd0, cy, -12'sd34, cy <= 36'sd0};
		endcase
		np = 6'd0;
		for (pi = 0; pi < 41; pi = pi + 1)
			if (nv[pi])
				np = pi[5:0];
		fbit = 1'b0;
		for (pi = 0; pi < 30; pi = pi + 1)
			if (step[4:0] == pi[4:0])
				fbit = fr[29 - pi];
	end
	wire [5:0] nsh;
	(* max_fanout = 12 *) reg [5:0] nsh_r;
	wire [40:0] nw;
	(* max_fanout = 12 *) reg [40:0] nw_r;
	reg nst_all_r, nw_all1_r;
	wire [11:0] ne127, nexp;
	reg [11:0] ne127_r;
	(* max_fanout = 12 *) reg [11:0] nexp_r;
	am_sub #(.W(6)) u_nsh (.a(6'd40), .b(np_r), .bi(1'b0), .d(nsh), .bo(carry_unused[13]));
	am_shift #(.W(41), .SW(6)) u_nw (.a(nv_r), .amt(nsh_r), .left(1'b1), .arith(1'b0), .y(nw));
	am_add #(.W(12)) u_ne (.a(ne_r), .b(12'd127), .ci(1'b0), .s(ne127), .co(carry_unused[14]));
	am_add #(.W(12)) u_nx (.a(ne127_r), .b({6'd0, np_r}), .ci(1'b0), .s(nexp), .co(carry_unused[15]));

	/* 2-cycle pipelined RNE rounding (Pre=0, Post=0 around CARRY4 in sub_st 5, pure LUTs in sub_st 6) */
	wire [23:0] nr_mp1_d;
	wire [11:0] nr_ep1_d;
	wire nr_ep1_co_unused;
	am_add #(.W(24)) u_nr_mp1 (.a(nw_r[40:17]), .b(24'd0), .ci(1'b1), .s(nr_mp1_d), .co(carry_unused[27]));
	am_add #(.W(12)) u_nr_ep1 (.a(nexp_r),      .b(12'd0), .ci(1'b1), .s(nr_ep1_d), .co(nr_ep1_co_unused));
	wire nr_up_d    = nw_r[16] && (nst_all_r || nw_r[17]);
	wire nr_carry_d = nw_all1_r && nw_r[16] && (nst_all_r || nw_r[17]);

	reg [23:0] nr_mp1_r;
	reg [11:0] nr_ep1_r;
	reg nr_up_r, nr_carry_r;
	reg [31:0] nr_r;

	wire [11:0] nr_e_final = nr_carry_r ? nr_ep1_r : nexp_r;
	wire nr_udf = nr_e_final[11] || !(|nr_e_final[10:0]);
	wire nr_ovf = !nr_e_final[11] && ((|nr_e_final[10:8]) || (&nr_e_final[7:0]));
	wire [22:0] nr_m_final = nr_carry_r ? 23'd0 : (nr_up_r ? nr_mp1_r[22:0] : nw_r[39:17]);
	wire [31:0] nr = nr_ovf ? {ns_r, 8'hFF, 23'd0} : nr_udf ? {ns_r, 31'd0} : {ns_r, nr_e_final[7:0], nr_m_final};
	wire [31:0] fin = nz_r ? 32'd0 : nr_r;

	/* LOAD: the result's exponent (rcp, rsq, fsqrt, exp2); z of sin/cos. */
	wire [23:0] exab = rop == ATG_XU_RCP[2:0] ? {12'd100, 4'd0, le} :	/* -50 - (e - 150) */
		rop == ATG_XU_RSQ[2:0] ? {-12'sd40, hee_r} : rop == ATG_XU_FSQRT[2:0] ? {hee_r, 12'd13} :
		{{3{ev_r[38]}}, ev_r[38:30], 12'd38};
	wire [11:0] ex_l;
	reg [11:0] ex_l_r;
	wire [38:0] zq;
	reg [38:0] zq_r;
	am_sub #(.W(12)) u_ex (.a(exab[23:12]), .b(exab[11:0]), .bi(1'b0), .d(ex_l), .bo(carry_unused[16]));
	am_sub #(.W(39)) u_zq (.a(39'h4000000000), .b({1'b0, t1_r[37:0]}), .bi(1'b0), .d(zq),
		.bo(carry_unused[17]));
	/* STEP: the step count and the CORDIC rotation. */
	wire [5:0] step1;
	am_add #(.W(6)) u_step (.a(step), .b(6'd0), .ci(1'b1), .s(step1), .co(carry_unused[18]));
	wire [35:0] cysh, cxsh, cx_n, cy_n;
	reg [35:0] cysh_r, cxsh_r, cx_n_r, cy_n_r;
	wire [40:0] z_n;
	reg [40:0] z_n_r;
	wire [34:0] dtr_r, strl_r;
	wire [33:0] snext_r = strl_r[34] ? srem : strl_r[33:0];
	am_shift #(.W(36), .SW(6)) u_cysh (.a(cy), .amt(step), .left(1'b0), .arith(1'b1), .y(cysh));
	am_shift #(.W(36), .SW(6)) u_cxsh (.a(cx), .amt(step), .left(1'b0), .arith(1'b1), .y(cxsh));
	am_addsub #(.W(36)) u_cx (.a(cx), .b(cysh_r), .sub(!z[40]), .s(cx_n), .co(carry_unused[19]));
	am_addsub #(.W(36)) u_cy (.a(cy), .b(cxsh_r), .sub(z[40]), .s(cy_n), .co(carry_unused[20]));
	am_addsub #(.W(41)) u_z (.a(z), .b({1'b0, atn_r}), .sub(!z[40]), .s(z_n), .co(carry_unused[21]));

	wire [3:0] sub_st1;
	wire sub_st_co_unused;
	am_add #(.W(4)) u_sub_st (.a(sub_st), .b(4'd0), .ci(1'b1), .s(sub_st1), .co(sub_st_co_unused));

	/* Sliced wide registers rx, rq, tps_r, dtr_r, strl_r to bound CE fanout <= 16 */
	genvar gxl, gxh;
	generate
	for (gxl = 0; gxl < NPHYS; gxl = gxl + 1) begin : g_xu_lane_reg
		for (gxh = 0; gxh < 2; gxh = gxh + 1) begin : g_xu_half
			(* keep = "true" *) wire rx_we_h = (st == IDLE) && mine;
			(* keep = "true" *) wire rq_clr_h = (st == IDLE) && mine;
			(* keep = "true" *) wire rq_we_h = (st == STORE) && (li == gxl[LW-1:0]);
			(* shreg_extract = "no" *) reg [15:0] rx_sl, rq_sl;
			always @(posedge clk) begin
				if (rx_we_h)
					rx_sl <= x_a[gxl*32 + gxh*16 +: 16];
				if (rq_clr_h)
					rq_sl <= 16'd0;
				else if (rq_we_h)
					rq_sl <= res[gxh*16 +: 16];
			end
			assign rx[gxl*32 + gxh*16 +: 16] = rx_sl;
			assign rq[gxl*32 + gxh*16 +: 16] = rq_sl;
		end
	end
	for (gxl = 0; gxl < 6; gxl = gxl + 1) begin : g_tps_sl
		localparam TPS_W = (gxl == 5) ? 3 : 16;
		(* keep = "true" *) wire tps_we_sl = (st == LOAD) && (sub_st == 4'd6);
		reg [TPS_W-1:0] tps_sl;
		always @(posedge clk)
			if (tps_we_sl)
				tps_sl <= tps[gxl*16 +: TPS_W];
		assign tps_r[gxl*16 +: TPS_W] = tps_sl;
	end
	for (gxl = 0; gxl < 3; gxl = gxl + 1) begin : g_dtr_sl
		localparam DTR_W = (gxl == 2) ? 3 : 16;
		(* keep = "true" *) wire dtr_we_sl = (st == STEP) && (sub_st == 4'd0);
		(* max_fanout = 12 *) reg [DTR_W-1:0] dtr_sl, strl_sl;
		always @(posedge clk)
			if (dtr_we_sl) begin
				dtr_sl <= dtr[gxl*16 +: DTR_W];
				strl_sl <= strl[gxl*16 +: DTR_W];
			end
		assign dtr_r[gxl*16 +: DTR_W] = dtr_sl;
		assign strl_r[gxl*16 +: DTR_W] = strl_sl;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
			sub_st <= 4'd0;
			li <= {LW{1'b0}};
			step <= 6'd0;
			ph <= 1'b0;
			lx <= 32'd0;
			lm_r <= 24'd0;
			mb_r <= 42'd0;
			tp0_r <= 41'd0;
			tp1_r <= 41'd0;
			tp2_r <= 41'd0;
			tp3_r <= 32'd0;
			tp2_rr <= 41'd0;
			tp_s0_r <= 83'd0;
			tp_r <= 83'd0;
			p00_r <= 41'd0;
			p01_r <= 41'd0;
			p02_r <= 32'd0;
			p10_r <= 35'd0;
			p11_r <= 35'd0;
			p12_r <= 26'd0;
			psum0_r <= 84'd0;
			psum1_r <= 84'd0;
			prod_r <= 84'd0;
		end else begin
			tp0_r <= tp0;
			tp1_r <= tp1;
			tp2_r <= tp2;
			tp3_r <= tp3;
			tp2_rr <= tp2_r;
			tp_s0_r <= tp_s0;
			tp_r <= tp;
			p00_r <= p00;
			p01_r <= p01;
			p02_r <= p02;
			p10_r <= p10;
			p11_r <= p11;
			p12_r <= p12;
			psum0_r <= psum0;
			psum1_r <= psum1;
			prod_r <= prod;
			case (st)
			IDLE: if (mine) begin
				rmask <= x_mask[NPHYS-1:0];
				rop <= x_uop[ATG_UOP_OP +: 3];
				rrd <= x_uop[ATG_UOP_RD +: 7];
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
				sub_st <= 4'd0;
				if (first == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= first[LW-1:0];
					st <= LOAD;
				end
			end
			LOAD: begin
				sub_st <= sub_st1;
				case (sub_st)
				4'd0: begin
					lx <= lx_raw;
					lm_r <= {1'b1, lx_raw[22:0]};
				end
				4'd1: begin
					hee_r <= hee;
					esh_r <= esh;
					ersh_r <= ersh;
					tsh_r <= tsh;
					trsh_r <= trsh;
				end
				4'd2: begin
					ev0_r <= ev0;
				end
				4'd3: begin
					ev_r <= ev;
				end
				4'd4, 4'd5: ;
				4'd6: begin
					ex_l_r <= ex_l;
				end
				4'd7: begin
					t1_r <= t1;
				end
				4'd8: begin
					tt_r <= tt;
					zq_r <= zq;
				end
				default: begin
					sub_st <= 4'd0;
					step <= 6'd0;
					ph <= 1'b0;
					stk <= 1'b0;
					sres <= 1'b1;
					res <= 32'h7FC00000;
					st <= FIN;
					case (rop)
					ATG_XU_RCP[2:0]:
						if (lzero || linf)
							res <= {ls, linf ? 31'd0 : {8'hFF, 23'd0}};
						else if (!lnan) begin
							sres <= 1'b0;
							rem <= 34'h000400000;
							root <= 30'd0;
							ex <= ex_l_r;
							st <= STEP;
						end
					ATG_XU_RSQ[2:0], ATG_XU_FSQRT[2:0]:
						if (lzero)
							res <= rop == ATG_XU_RSQ[2:0] ? {ls, 8'hFF, 23'd0} : lx;
						else if (lnan || ls)
							res <= 32'h7FC00000;
						else if (linf)
							res <= rop == ATG_XU_RSQ[2:0] ? 32'd0 : lx;
						else begin
							sres <= 1'b0;
							n <= rop == ATG_XU_RSQ[2:0] ? {1'b0, lmm, 34'd0} :
								{1'b0, lmm, 26'd0, 8'd0};
							rem <= 34'd0;
							root <= 30'd0;
							ex <= ex_l_r;
							st <= STEP;
						end
					ATG_XU_EXP2[2:0]:
						if (lzero)
							res <= 32'h3F800000;
						else if (linf || (!lnan && le >= 8'd135))
							res <= ls ? 32'd0 : 32'h7F800000;
						else if (!lnan) begin
							sres <= 1'b0;
							y <= 42'd1 << 38;
							fr <= ev_r[29:0];
							ex <= ex_l_r;
							st <= STEP;
						end
					ATG_XU_LOG2[2:0]:
						if (lzero)
							res <= 32'hFF800000;
						else if (lnan || ls)
							res <= 32'h7FC00000;
						else if (linf)
							res <= lx;
						else begin
							sres <= 1'b0;
							y <= {1'b0, lm, 17'd0};
							fr <= 30'd0;
							st <= STEP;
						end
					default:	/* sin, cos */
						if (lnan || linf)
							res <= 32'h7FC00000;
						else if (le < 8'd115)
							res <= rop == ATG_XU_SIN[2:0] ? lx : 32'h3F800000;
						else begin
							sres <= 1'b0;
							qneg <= tt_r[39];
							z <= tt_r[38] ? $signed({2'b0, zq_r}) : $signed({3'b0, tt_r[37:0]});
							cx <= $signed({1'b0, XU_CG[34:0]});
							cy <= 36'sd0;
							st <= STEP;
						end
					endcase
				end
				endcase
			end
			STEP: begin
				sub_st <= sub_st1;
				case (sub_st)
				4'd0: begin
					mb_r <= rop == ATG_XU_EXP2[2:0] ? {2'd0, xu_expk(step[4:0])} : y;
					cysh_r <= cysh;
					cxsh_r <= cxsh;
					atn_r <= atn;
				end
				4'd1: begin
					cx_n_r <= cx_n;
					cy_n_r <= cy_n;
					z_n_r <= z_n;
				end
				4'd2, 4'd3, 4'd4, 4'd5: ;
				default: begin
					sub_st <= 4'd0;
					step <= step1;
					case (rop)
					ATG_XU_RCP[2:0]: begin
						if (!dtr_r[34]) begin
							rem <= dtr_r[33:0];
							root <= {root[28:0], 1'b1};
						end else begin
							rem <= {rem[32:0], 1'b0};
							root <= {root[28:0], 1'b0};
						end
					end
					ATG_XU_RSQ[2:0], ATG_XU_FSQRT[2:0]:
						if (ph) begin
							if (!dtr_r[34]) begin
								rem <= dtr_r[33:0];
								n[28:0] <= {n[27:0], 1'b1};
							end else begin
								rem <= {rem[32:0], 1'b0};
								n[28:0] <= {n[27:0], 1'b0};
							end
						end else begin
							n <= {n[57:0], 2'b00};
							rem <= snext_r;
							root <= {root[28:0], !strl_r[34]};
						end
					ATG_XU_EXP2[2:0]:
						if (fbit)
							y <= {2'd0, prod_r[77:38]};
					ATG_XU_LOG2[2:0]: begin
						if (prod_r[81]) begin
							y <= {1'b0, prod_r[81:41]};
							fr <= {fr[28:0], 1'b1};
						end else begin
							y <= prod_r[81:40];
							fr <= {fr[28:0], 1'b0};
						end
					end
					default:
						{cx, cy, z} <= {cx_n_r, cy_n_r, z_n_r};
					endcase
					if (step == nsteps_m1) begin
						step <= 6'd0;
						if (rop == ATG_XU_RSQ[2:0] && !ph) begin
							/* 2^57 / t: t = the root (30 bits). */
							ph <= 1'b1;
							stk <= snext_r != 34'd0;
							rem <= 34'h010000000;
							n[28:0] <= 29'd0;
						end else
							st <= FIN;
					end
				end
				endcase
			end
			FIN: begin
				sub_st <= sub_st1;
				case (sub_st)
				4'd0: lue_r <= lue;
				4'd1: lva_r <= lva;
				4'd2: begin
					ns_r <= ns;
					nst_r <= nst;
					nz_r <= nz;
					nv_r <= nv;
					ne_r <= ne;
					np_r <= np;
				end
				4'd3: begin
					nsh_r <= nsh;
					ne127_r <= ne127;
				end
				4'd4: begin
					nw_r <= nw;
					nexp_r <= nexp;
					nst_all_r <= (|nw[15:0]) || nst_r;
					nw_all1_r <= &nw[40:17];
				end
				4'd5: begin
					nr_mp1_r <= nr_mp1_d;
					nr_ep1_r <= nr_ep1_d;
					nr_up_r <= nr_up_d;
					nr_carry_r <= nr_carry_d;
				end
				4'd6: begin
					nr_r <= nr;
				end
				default: begin
					sub_st <= 4'd0;
					if (!sres)
						res <= fin;
					st <= STORE;
				end
				endcase
			end
			STORE: begin
				/* The result of FIN is in res: store it, next lane. */
				sub_st <= 4'd0;
				if (after == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= after[LW-1:0];
					st <= LOAD;
				end
			end
			default: if (l_ready)
				st <= IDLE;
			endcase
		end
	end

	assign l_valid = st == RET;
	assign l_warp = rwarp;
	assign l_grp = rgrp;
	assign l_rd = rrd;
	assign l_data = rq;
	assign l_lanes = rmask;
	assign l_wr = 1'b1;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_X;

	wire unused_ok = &{1'b0, x_pc, x_b, x_c, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		snext, prod_r, tp_r[82:40], tps_r[82:40], y[41], esh_r[10:4], carry_unused[27],
		sub_st_co_unused, nr_ep1_co_unused, nr_mp1_r[23], nw_r[40], nw_r[15:0], (NWARPS != 0)};
endmodule

`default_nettype wire
