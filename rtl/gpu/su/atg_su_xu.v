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

	(* dont_touch = "true" *) wire rst_p = !rst_n;

	reg [2:0] st;
	wire [DW-1:0] rx, rq;
	reg [NPHYS-1:0] rmask;
	(* dont_touch = "true" *) reg [2:0] rop;
	(* dont_touch = "true" *) reg [2:0] rop_fin_lo0, rop_fin_lo1, rop_fin_hi0, rop_fin_hi1, rop_fin_ctl;
	(* dont_touch = "true" *) reg [2:0] rop_pipe, rop_we, rop_step;
	(* dont_touch = "true" *) reg [2:0] rop_dt, rop_dt_dtr_lo, rop_dt_dtr_hi, rop_dt_exab, rop_dt_tt;
	(* dont_touch = "true" *) reg [2:0] rop_load, rop_load_ctl_lo, rop_load_ctl_hi, rop_load_mb, rop_load_y, rop_load_fr;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	reg [LW-1:0] li;
	(* dont_touch = "true" *) reg [5:0] step;
	(* dont_touch = "true" *) reg [5:0] step_cnt, step_cordic, step_tab, step_fbit_lo, step_fbit_hi;
	(* dont_touch = "true" *) reg [5:0] step_tab_atan, step_tab_expk;
	reg ph;			/* rsq: 0 square root, 1 division */
	/* The engine (registers sliced to bound fanout <= 16). */
	wire [59:0] n;		/* sqrt: the radicand, two bits per step from the top */
	wire [33:0] rem;		/* division and sqrt remainder */
	wire [29:0] root;	/* quotient / root */
	reg stk;		/* rsq: the square root was inexact */
	wire [41:0] y;		/* exp2 / log2 */
	wire [29:0] fr;		/* exp2: the fraction bits; log2: the result bits */
	reg signed [11:0] ex;	/* the exponent of the result's LSB */
	wire signed [35:0] cx, cy;
	wire signed [40:0] z;
	reg qneg;		/* sin/cos: the quadrant's sign */
	reg sres;		/* a special result is in res */
	reg [31:0] res;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_XU;
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
	wire [31:0] lx_cur_r;
	wire [31:0] lx_raw = atg_su_flush(lx_cur_r);
	reg [31:0] lx;
	reg [23:0] lm_r;
	reg [3:0] sub_st;
	(* dont_touch = "true" *) reg [3:0] sub_st_load, sub_st_step, sub_st_fin;
	wire ls = lx[31];
	wire ls_ev, ls_t1, ls_res;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ls_ev  (.I0(lx[31]), .O(ls_ev));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ls_t1  (.I0(lx[31]), .O(ls_t1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ls_res (.I0(lx[31]), .O(ls_res));
`else
	assign ls_ev  = lx[31];
	assign ls_t1  = lx[31];
	assign ls_res = lx[31];
`endif
	wire [7:0] le_sub, le_cmp;
`ifdef SYNTH_KINTEX7
	genvar gle;
	generate
		for (gle = 0; gle < 8; gle = gle + 1) begin : g_le_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lesub (.I0(lx[23+gle]), .O(le_sub[gle]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lecmp (.I0(lx[23+gle]), .O(le_cmp[gle]));
		end
	endgenerate
`else
	assign le_sub = lx[30:23];
	assign le_cmp = lx[30:23];
`endif
	wire [7:0] le = le_sub;
	wire [23:0] lm = lm_r;
	wire [23:0] lm_lmm, lm_ev0, lm_dtr, lm_y;
	genvar glm;
	generate
		for (glm = 0; glm < 24; glm = glm + 1) begin : g_lm_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lmm (.I0(lm_r[glm]), .O(lm_lmm[glm]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lev (.I0(lm_r[glm]), .O(lm_ev0[glm]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ldt (.I0(lm_r[glm]), .O(lm_dtr[glm]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ly  (.I0(lm_r[glm]), .O(lm_y[glm]));
`else
			assign lm_lmm[glm] = lm_r[glm];
			assign lm_ev0[glm] = lm_r[glm];
			assign lm_dtr[glm] = lm_r[glm];
			assign lm_y[glm]   = lm_r[glm];
`endif
		end
	endgenerate
	wire lnan = le_cmp == 8'hFF && lx[22:0] != 0;
	wire linf = le_cmp == 8'hFF && lx[22:0] == 0;
	wire lzero = le_cmp == 8'd0;
	reg lnan_r, linf_r, lzero_r, le_ge135_r, le_lt115_r;
	reg load_go_step_r;
	wire [31:0] load_res_r;
	wire lodd = le[0];	/* e - 150 odd */
	wire lodd_lmm0, lodd_lmm1, lodd_hee;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_blodd_0 (.I0(le[0]), .O(lodd_lmm0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_blodd_1 (.I0(le[0]), .O(lodd_lmm1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_blodd_h (.I0(le[0]), .O(lodd_hee));
`else
	assign lodd_lmm0 = le[0];
	assign lodd_lmm1 = le[0];
	assign lodd_hee  = le[0];
`endif
	wire [24:0] lmm = {
		lodd_lmm1 ? lm_lmm[23:11]          : {1'b0, lm_lmm[23:12]},
		lodd_lmm0 ? {lm_lmm[10:0], 1'b0}  : lm_lmm[11:0]
	};
	/* ee/2 with ee = e - 150 (- 1 when odd). */
	wire [11:0] hee_d, esh, tsh;
	wire [6:0] ersh;
	wire [7:0] trsh;
	reg signed [11:0] hee_r;
	reg [11:0] esh_r, tsh_r;
	reg [6:0] ersh_r;
	reg [7:0] trsh_r;
	reg [6:0] esh_amt_r;
	reg esh_left_r;
	reg [7:0] tsh_amt_r;
	reg tsh_left_r;
	am_sub #(.W(12)) u_hee (.a({4'd0, le}), .b(12'd150), .bi(lodd_hee), .d(hee_d), .bo(carry_unused[1]));
	wire signed [11:0] hee = $signed(hee_d) >>> 1;
	/* exp2: x in Q8.30 (sh = e - 120 <= 14 here). */
	am_sub #(.W(12)) u_esh (.a({4'd0, le}), .b(12'd120), .bi(1'b0), .d(esh), .bo(carry_unused[2]));
	am_sub #(.W(7)) u_ersh (.a(7'd120), .b(le[6:0]), .bi(1'b0), .d(ersh), .bo(carry_unused[3]));
	wire [38:0] ev0, ev;
	wire [38:0] ev0_r, ev_r;
	am_shift #(.W(39), .SW(7)) u_ev0 (.a({15'd0, lm_ev0}), .amt(esh_amt_r),
		.left(esh_left_r), .arith(1'b0), .y(ev0));
	am_addsub #(.W(39)) u_ev (.a(39'd0), .b(ev0_r), .sub(ls_ev), .s(ev), .co(carry_unused[6]));
	/* sin/cos: the turns (split into 4 single-DSP 24x<=17 multiplies). */
	wire [40:0] tp0, tp1, tp2;
	wire [31:0] tp3;
	(* dont_touch = "true" *) reg [40:0] tp0_r, tp1_r, tp2_r;
	(* dont_touch = "true" *) reg [31:0] tp3_r;
	reg [40:0] tp2_rr;
	wire [82:0] tp_s0, tp, tps;
	reg [82:0] tp_s0_r;
	(* dont_touch = "true" *) reg [82:0] tp_r;
	wire [39:0] tps_r;
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
	am_shift #(.W(83), .SW(8)) u_tps (.a(tp_r), .amt(tsh_amt_r), .left(tsh_left_r),
		.arith(1'b0), .y(tps));
	wire t0_zero_a, t0_zero_b, t0_zero_c;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_t0z_a (.I0($signed(tsh_r) >= 12'sd40), .O(t0_zero_a));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_t0z_b (.I0($signed(tsh_r) >= 12'sd40), .O(t0_zero_b));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_t0z_c (.I0($signed(tsh_r) >= 12'sd40), .O(t0_zero_c));
`else
	assign t0_zero_a = $signed(tsh_r) >= 12'sd40;
	assign t0_zero_b = $signed(tsh_r) >= 12'sd40;
	assign t0_zero_c = $signed(tsh_r) >= 12'sd40;
`endif
	wire [39:0] t0 = {
		t0_zero_c ? 8'd0 : tps_r[39:32],
		t0_zero_b ? 16'd0 : tps_r[31:16],
		t0_zero_a ? 16'd0 : tps_r[15:0]
	};
	wire [39:0] t1, tt;
	wire [39:0] t1_r, tt_r;
	am_addsub #(.W(40)) u_t1 (.a(40'd0), .b(t0), .sub(ls_t1), .s(t1), .co(carry_unused[7]));
	am_add #(.W(40)) u_tt (.a(t1_r), .b(rop_dt_tt == ATG_XU_COS[2:0] ? 40'h4000000000 : 40'd0), .ci(1'b0),
		.s(tt), .co(carry_unused[8]));
	/* The shared multiplier (exp2: y * K, log2: y * y), split into 6 single-DSP <=24x<=17 multiplies. */
	wire [41:0] mb_r;
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
	wire is_rcp_lo, is_rcp_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rcp_lo (.I0(rop_dt_dtr_lo == ATG_XU_RCP[2:0]), .O(is_rcp_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rcp_hi (.I0(rop_dt_dtr_hi == ATG_XU_RCP[2:0]), .O(is_rcp_hi));
`else
	assign is_rcp_lo = rop_dt_dtr_lo == ATG_XU_RCP[2:0];
	assign is_rcp_hi = rop_dt_dtr_hi == ATG_XU_RCP[2:0];
`endif
	wire [34:0] dtr_b = {
		is_rcp_hi ? {11'd0, lm_dtr[23:17]} : {5'd0, root[29:17]},
		is_rcp_lo ? lm_dtr[16:0]            : root[16:0]
	};
	am_sub #(.W(35)) u_dtr (.a({rem, 1'b0}), .b(dtr_b), .bi(1'b0), .d(dtr), .bo(carry_unused[9]));
	am_sub #(.W(35)) u_strl (.a({1'b0, srem}), .b({3'd0, root, 2'b01}), .bi(1'b0), .d(strl),
		.bo(carry_unused[10]));
	wire [33:0] snext = strl[34] ? srem : strl[33:0];
	/* The step counts, less one. */
	wire [5:0] nsteps_m1 = rop_pipe == ATG_XU_RCP[2:0] ? 6'd27 : rop_pipe == ATG_XU_FSQRT[2:0] ? 6'd25 :
		rop_pipe == ATG_XU_RSQ[2:0] ? (ph_step ? 6'd28 : 6'd29) :
		(rop_pipe == ATG_XU_SIN[2:0] || rop_pipe == ATG_XU_COS[2:0]) ? 6'd25 : 6'd29;
	wire [4:0] step_tab_atn_lo, step_tab_atn_hi;
	wire [4:0] step_tab_exp_lo, step_tab_exp_hi;
	genvar gsta;
	generate
		for (gsta = 0; gsta < 5; gsta = gsta + 1) begin : g_step_tab_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_atn_lo (.I0(step_tab_atan[gsta]), .O(step_tab_atn_lo[gsta]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_atn_hi (.I0(step_tab_atan[gsta]), .O(step_tab_atn_hi[gsta]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_lo (.I0(step_tab_expk[gsta]), .O(step_tab_exp_lo[gsta]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_hi (.I0(step_tab_expk[gsta]), .O(step_tab_exp_hi[gsta]));
`else
			assign step_tab_atn_lo[gsta] = step_tab_atan[gsta];
			assign step_tab_atn_hi[gsta] = step_tab_atan[gsta];
			assign step_tab_exp_lo[gsta] = step_tab_expk[gsta];
			assign step_tab_exp_hi[gsta] = step_tab_expk[gsta];
`endif
		end
	endgenerate
	wire [39:0] atn_full_lo = xu_atan(step_tab_atn_lo);
	wire [39:0] atn_full_hi = xu_atan(step_tab_atn_hi);
	wire [39:0] atn = {atn_full_hi[39:20], atn_full_lo[19:0]};
	(* rom_style = "distributed", ram_style = "distributed" *) wire [39:0] atn_r;
	wire [10:0] lue;
	reg [10:0] lue_r;
	am_sub #(.W(11)) u_lue (.a({3'd0, le}), .b(11'd127), .bi(1'b0), .d(lue), .bo(carry_unused[11]));
	wire [40:0] lv = {lue_r, fr};	/* log2: (e - 127) << 30 | fraction, signed */
	wire [40:0] lva;
	wire [40:0] lva_r;
	am_addsub #(.W(41)) u_lva (.a(41'd0), .b(lv), .sub(lv[40]), .s(lva), .co(carry_unused[12]));
	/* The result of a finished lane (state FIN): an integer v (< 2^41) times 2^e, sign s, to
	 * fp32 (RNE, flushed). */
	reg ns, nst, nz, fbit;	/* nz: the result is 0; fbit: fr[29 - step] (exp2) */
	reg [40:0] nv;
	reg [11:0] ne;
	reg [5:0] np;
	reg ns_r, nst_r, nz_r;
	wire [40:0] nv_r;
	reg [11:0] ne_r;
	reg [5:0] np_r;
	integer pi;
	reg [9:0] nv_lo0, nv_lo1;
	reg [10:0] nv_hi0;
	reg [9:0] nv_hi1;
	always @(*) begin
		case (rop_fin_lo0)
		ATG_XU_RCP[2:0]:   nv_lo0 = root[9:0];
		ATG_XU_FSQRT[2:0]: nv_lo0 = root[9:0];
		ATG_XU_RSQ[2:0]:   nv_lo0 = n[9:0];
		ATG_XU_EXP2[2:0]:  nv_lo0 = y[9:0];
		ATG_XU_LOG2[2:0]:  nv_lo0 = lva_r[9:0];
		default:           nv_lo0 = cy[9:0];
		endcase
	end
	always @(*) begin
		case (rop_fin_lo1)
		ATG_XU_RCP[2:0]:   nv_lo1 = root[19:10];
		ATG_XU_FSQRT[2:0]: nv_lo1 = root[19:10];
		ATG_XU_RSQ[2:0]:   nv_lo1 = n[19:10];
		ATG_XU_EXP2[2:0]:  nv_lo1 = y[19:10];
		ATG_XU_LOG2[2:0]:  nv_lo1 = lva_r[19:10];
		default:           nv_lo1 = cy[19:10];
		endcase
	end
	always @(*) begin
		case (rop_fin_hi0)
		ATG_XU_RCP[2:0]:   nv_hi0 = {3'd0, root[27:20]};
		ATG_XU_FSQRT[2:0]: nv_hi0 = {5'd0, root[25:20]};
		ATG_XU_RSQ[2:0]:   nv_hi0 = {2'd0, n[28:20]};
		ATG_XU_EXP2[2:0]:  nv_hi0 = y[30:20];
		ATG_XU_LOG2[2:0]:  nv_hi0 = lva_r[30:20];
		default:           nv_hi0 = cy[30:20];
		endcase
	end
	always @(*) begin
		case (rop_fin_hi1)
		ATG_XU_RCP[2:0]:   nv_hi1 = 10'd0;
		ATG_XU_FSQRT[2:0]: nv_hi1 = 10'd0;
		ATG_XU_RSQ[2:0]:   nv_hi1 = 10'd0;
		ATG_XU_EXP2[2:0]:  nv_hi1 = y[40:31];
		ATG_XU_LOG2[2:0]:  nv_hi1 = lva_r[40:31];
		default:           nv_hi1 = {5'd0, cy[35:31]};
		endcase
	end
	always @(*) begin
		nv = {nv_hi1, nv_hi0, nv_lo1, nv_lo0};
		{ns, nst, nz, ne} = {3'b000, ex};
		case (rop_fin_ctl)
		ATG_XU_RCP[2:0]:   {ns, nst} = {ls_res, rem != 34'd0};
		ATG_XU_FSQRT[2:0]: nst = (rem != 34'd0);
		ATG_XU_RSQ[2:0]:   nst = (rem != 34'd0 || stk);
		ATG_XU_EXP2[2:0]:  ;
		ATG_XU_LOG2[2:0]:  {ns, ne, nz} = {lv[40], -12'sd30, lv == 41'd0};
		default:           {ns, ne, nz} = {qneg, -12'sd34, cy <= 36'sd0};
		endcase
		np = 6'd0;
		for (pi = 0; pi < 41; pi = pi + 1)
			if (nv[pi])
				np = pi[5:0];
		fbit = 1'b0;
		for (pi = 0; pi < 15; pi = pi + 1)
			if (step_fbit_lo[4:0] == pi[4:0])
				fbit = fr[29 - pi];
		for (pi = 15; pi < 30; pi = pi + 1)
			if (step_fbit_hi[4:0] == pi[4:0])
				fbit = fr[29 - pi];
	end
	wire [5:0] nsh;
	reg [5:0] nsh_r;
	wire [40:0] nw;
	wire [40:0] nw_r;
	reg nst_all_r, nw_all1_r;
	wire [11:0] ne127, nexp;
	reg [11:0] ne127_r;
	reg [11:0] nexp_r;
	am_sub #(.W(6)) u_nsh (.a(6'd40), .b(np_r), .bi(1'b0), .d(nsh), .bo(carry_unused[13]));
	am_shift #(.W(41), .SW(6), .DIR(2)) u_nw (.a(nv_r), .amt(nsh_r), .left(1'b1), .arith(1'b0), .y(nw));
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

	wire [23:0] nr_mp1_r;
	reg [11:0] nr_ep1_r;
	reg nr_up_r, nr_carry_r;
	wire [31:0] nr_r;

	wire nr_carry_e, nr_carry_m;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nrc_e (.I0(nr_carry_r), .O(nr_carry_e));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nrc_m (.I0(nr_carry_r), .O(nr_carry_m));
`else
	assign nr_carry_e = nr_carry_r;
	assign nr_carry_m = nr_carry_r;
`endif
	wire [11:0] nr_e_final = nr_carry_e ? nr_ep1_r : nexp_r;
	(* keep = "true" *) wire nr_udf_lo = nr_e_final[11] || !(|nr_e_final[10:0]);
	(* keep = "true" *) wire nr_udf_hi = nr_e_final[11] || !(|nr_e_final[10:0]);
	(* keep = "true" *) wire nr_ovf_lo = !nr_e_final[11] && ((|nr_e_final[10:8]) || (&nr_e_final[7:0]));
	(* keep = "true" *) wire nr_ovf_hi = !nr_e_final[11] && ((|nr_e_final[10:8]) || (&nr_e_final[7:0]));
	wire [22:0] nr_m_final = nr_carry_m ? 23'd0 : (nr_up_r ? nr_mp1_r[22:0] : nw_r[39:17]);
	wire [31:0] nr = {
		nr_ovf_hi ? {ns_r, 8'hFF, 7'd0} : nr_udf_hi ? {ns_r, 15'd0} : {ns_r, nr_e_final[7:0], nr_m_final[22:16]},
		(nr_ovf_lo || nr_udf_lo) ? 16'd0 : nr_m_final[15:0]
	};
	wire nz_r_lo, nz_r_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nz_lo (.I0(nz_r), .O(nz_r_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nz_hi (.I0(nz_r), .O(nz_r_hi));
`else
	assign nz_r_lo = nz_r;
	assign nz_r_hi = nz_r;
`endif
	wire [31:0] fin = {
		nz_r_hi ? 16'd0 : nr_r[31:16],
		nz_r_lo ? 16'd0 : nr_r[15:0]
	};

	/* LOAD: the result's exponent (rcp, rsq, fsqrt, exp2); z of sin/cos. */
	wire [23:0] exab = rop_dt_exab == ATG_XU_RCP[2:0] ? {12'd100, 4'd0, le} :	/* -50 - (e - 150) */
		rop_dt_exab == ATG_XU_RSQ[2:0] ? {-12'sd40, hee_r} : rop_dt_exab == ATG_XU_FSQRT[2:0] ? {hee_r, 12'd13} :
		{{3{ev_r[38]}}, ev_r[38:30], 12'd38};
	wire [11:0] ex_l;
	reg [11:0] ex_l_r;
	wire [38:0] zq;
	wire [38:0] zq_r;
	am_sub #(.W(12)) u_ex (.a(exab[23:12]), .b(exab[11:0]), .bi(1'b0), .d(ex_l), .bo(carry_unused[16]));
	am_sub #(.W(39)) u_zq (.a(39'h4000000000), .b({1'b0, t1_r[37:0]}), .bi(1'b0), .d(zq),
		.bo(carry_unused[17]));

	/* Precomputed LOAD special condition and result (registered in LOAD sub_st 8) */
	reg load_go_step_w;
	reg [15:0] load_res_w_lo, load_res_w_hi;
	always @(*) begin
		load_go_step_w = 1'b0;
		load_res_w_hi = 16'h7FC0;
		case (rop_load_ctl_hi)
		ATG_XU_RCP[2:0]:
			if (lzero_r || linf_r)
				load_res_w_hi = {ls_res, linf_r ? 15'd0 : 15'h7F80};
			else if (!lnan_r)
				load_go_step_w = 1'b1;
		ATG_XU_RSQ[2:0], ATG_XU_FSQRT[2:0]:
			if (lzero_r)
				load_res_w_hi = rop_load_ctl_hi == ATG_XU_RSQ[2:0] ? {ls_res, 15'h7F80} : lx[31:16];
			else if (lnan_r || ls_res)
				load_res_w_hi = 16'h7FC0;
			else if (linf_r)
				load_res_w_hi = rop_load_ctl_hi == ATG_XU_RSQ[2:0] ? 16'd0 : lx[31:16];
			else
				load_go_step_w = 1'b1;
		ATG_XU_EXP2[2:0]:
			if (lzero_r)
				load_res_w_hi = 16'h3F80;
			else if (linf_r || (!lnan_r && le_ge135_r))
				load_res_w_hi = ls_res ? 16'd0 : 16'h7F80;
			else if (!lnan_r)
				load_go_step_w = 1'b1;
		ATG_XU_LOG2[2:0]:
			if (lzero_r)
				load_res_w_hi = 16'hFF80;
			else if (lnan_r || ls_res)
				load_res_w_hi = 16'h7FC0;
			else if (linf_r)
				load_res_w_hi = lx[31:16];
			else
				load_go_step_w = 1'b1;
		default:
			if (lnan_r || linf_r)
				load_res_w_hi = 16'h7FC0;
			else if (le_lt115_r)
				load_res_w_hi = rop_load_ctl_hi == ATG_XU_SIN[2:0] ? lx[31:16] : 16'h3F80;
			else
				load_go_step_w = 1'b1;
		endcase
	end
	always @(*) begin
		load_res_w_lo = 16'd0;
		case (rop_load_ctl_lo)
		ATG_XU_RCP[2:0]:
			if (lzero_r || linf_r)
				load_res_w_lo = 16'd0;
		ATG_XU_RSQ[2:0], ATG_XU_FSQRT[2:0]:
			if (lzero_r)
				load_res_w_lo = rop_load_ctl_lo == ATG_XU_RSQ[2:0] ? 16'd0 : lx[15:0];
			else if (lnan_r || ls_res)
				load_res_w_lo = 16'd0;
			else if (linf_r)
				load_res_w_lo = rop_load_ctl_lo == ATG_XU_RSQ[2:0] ? 16'd0 : lx[15:0];
		ATG_XU_EXP2[2:0]:
			load_res_w_lo = 16'd0;
		ATG_XU_LOG2[2:0]:
			load_res_lo = 16'd0;
		default:
			if (lnan_r || linf_r)
				load_res_w_lo = 16'd0;
			else if (le_lt115_r)
				load_res_w_lo = rop_load_ctl_lo == ATG_XU_SIN[2:0] ? lx[15:0] : 16'd0;
		endcase
	end
	wire [31:0] load_res_w = {load_res_w_hi, load_res_w_lo};

	/* STEP: the step count and the CORDIC rotation. */
	wire [5:0] step1;
	am_add #(.W(6)) u_step (.a(step_cnt), .b(6'd0), .ci(1'b1), .s(step1), .co(carry_unused[18]));
	wire [35:0] cysh, cxsh, cx_n, cy_n;
	wire [35:0] cysh_r, cxsh_r, cx_n_r, cy_n_r;
	wire [40:0] z_n;
	wire [40:0] z_n_r;
	wire [34:0] dtr_r, strl_r;
	wire strl34_snext_0, strl34_snext_1, strl34_snext_2, strl34_snext_stk, strl34_root;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl_0   (.I0(strl_r[34]), .O(strl34_snext_0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl_1   (.I0(strl_r[34]), .O(strl34_snext_1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl_2   (.I0(strl_r[34]), .O(strl34_snext_2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl_stk (.I0(strl_r[34]), .O(strl34_snext_stk));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl_rt  (.I0(strl_r[34]), .O(strl34_root));
`else
	assign strl34_snext_0   = strl_r[34];
	assign strl34_snext_1   = strl_r[34];
	assign strl34_snext_2   = strl_r[34];
	assign strl34_snext_stk = strl_r[34];
	assign strl34_root      = strl_r[34];
`endif
	wire [33:0] snext_r = {
		strl34_snext_2 ? srem[33:22] : strl_r[33:22],
		strl34_snext_1 ? srem[21:11] : strl_r[21:11],
		strl34_snext_0 ? srem[10:0]  : strl_r[10:0]
	};
	wire cx35_sh, cy35_sh;
	wire z40_cx, z40_cy, z40_z;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cx35 (.I0(cx[35]), .O(cx35_sh));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cy35 (.I0(cy[35]), .O(cy35_sh));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b01)) u_b_z40_cx (.I0(z[40]), .O(z40_cx)); // !z[40]
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_z40_cy (.I0(z[40]), .O(z40_cy)); //  z[40]
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b01)) u_b_z40_z  (.I0(z[40]), .O(z40_z));  // !z[40]
`else
	assign cx35_sh = cx[35];
	assign cy35_sh = cy[35];
	assign z40_cx = !z[40];
	assign z40_cy = z[40];
	assign z40_z  = !z[40];
`endif
	am_shift #(.W(36), .SW(6), .DIR(1)) u_cysh (.a({cy35_sh, cy[34:0]}), .amt(step_cordic), .left(1'b0), .arith(1'b1), .y(cysh));
	am_shift #(.W(36), .SW(6), .DIR(1)) u_cxsh (.a({cx35_sh, cx[34:0]}), .amt(step_cordic), .left(1'b0), .arith(1'b1), .y(cxsh));
	am_addsub #(.W(36)) u_cx (.a(cx), .b(cysh_r), .sub(z40_cx), .s(cx_n), .co(carry_unused[19]));
	am_addsub #(.W(36)) u_cy (.a(cy), .b(cxsh_r), .sub(z40_cy), .s(cy_n), .co(carry_unused[20]));
	am_addsub #(.W(41)) u_z  (.a(z),  .b({1'b0, atn_r}), .sub(z40_z),  .s(z_n),  .co(carry_unused[21]));

	wire [3:0] sub_st1;
	wire sub_st_co_unused;
	am_add #(.W(4)) u_sub_st (.a(sub_st), .b(4'd0), .ci(1'b1), .s(sub_st1), .co(sub_st_co_unused));

	/* Sliced wide registers to bound CE fanout <= 16 */
	wire idle_mine = (st == IDLE) && mine;
	wire idle_mine_lane_lo, idle_mine_lane_hi, idle_mine_ctl;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_lo  (.I0(idle_mine), .O(idle_mine_lane_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_hi  (.I0(idle_mine), .O(idle_mine_lane_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_ctl (.I0(idle_mine), .O(idle_mine_ctl));
`else
	assign idle_mine_lane_lo = idle_mine;
	assign idle_mine_lane_hi = idle_mine;
	assign idle_mine_ctl     = idle_mine;
`endif

	genvar gxl, gxh;
	generate
	for (gxl = 0; gxl < NPHYS; gxl = gxl + 1) begin : g_xu_lane_reg
		wire im_lane = (gxl < 4) ? idle_mine_lane_lo : idle_mine_lane_hi;
		for (gxh = 0; gxh < 2; gxh = gxh + 1) begin : g_xu_half
			wire rx_we_h, rq_clr_h, rq_we_h;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rx_we  (.I0(im_lane), .O(rx_we_h));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rq_clr (.I0(im_lane), .O(rq_clr_h));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_rq_we  (.I0((st == STORE) && (li == gxl[LW-1:0])), .O(rq_we_h));
`else
			assign rx_we_h = im_lane;
			assign rq_clr_h = im_lane;
			assign rq_we_h = (st == STORE) && (li == gxl[LW-1:0]);
`endif
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
	for (gxl = 0; gxl < 3; gxl = gxl + 1) begin : g_tps_sl
		localparam TPS_W = (gxl == 2) ? 8 : 16;
		wire tps_we_sl;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_tps (.I0((st == LOAD) && (sub_st_load == 4'd6)), .O(tps_we_sl));
`else
		assign tps_we_sl = (st == LOAD) && (sub_st_load == 4'd6);
`endif
		reg [TPS_W-1:0] tps_sl;
		always @(posedge clk)
			if (tps_we_sl)
				tps_sl <= tps[gxl*16 +: TPS_W];
		assign tps_r[gxl*16 +: TPS_W] = tps_sl;
	end
	for (gxl = 0; gxl < 3; gxl = gxl + 1) begin : g_dtr_sl
		localparam DTR_W = (gxl == 2) ? 3 : 16;
		wire dtr_we_sl, strl_we_sl;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr  (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(dtr_we_sl));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_strl (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(strl_we_sl));
`else
		assign dtr_we_sl = (st == STEP) && (sub_st_step == 4'd0);
		assign strl_we_sl = (st == STEP) && (sub_st_step == 4'd0);
`endif
		reg [DTR_W-1:0] dtr_sl, strl_sl;
		always @(posedge clk) begin
			if (dtr_we_sl)
				dtr_sl <= dtr[gxl*16 +: DTR_W];
			if (strl_we_sl)
				strl_sl <= strl[gxl*16 +: DTR_W];
		end
		assign dtr_r[gxl*16 +: DTR_W] = dtr_sl;
		assign strl_r[gxl*16 +: DTR_W] = strl_sl;
	end
	for (gxl = 0; gxl < 3; gxl = gxl + 1) begin : g_xu_wide_sl
		localparam W39 = (gxl == 2) ? 7 : 16;
		localparam W40 = (gxl == 2) ? 8 : 16;
		localparam W41 = (gxl == 2) ? 9 : 16;
		localparam W36 = (gxl == 2) ? 4 : 16;
		wire ev0_we_s, ev_we_s, t1_we_s, tt_we_s, zq_we_s;
		wire cysh_we_s, cxsh_we_s, atn_we_s, cxn_we_s, cyn_we_s, zn_we_s;
		wire lva_we_s, nv_we_s, nw_we_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ev0  (.I0((st == LOAD) && (sub_st_load == 4'd2)), .O(ev0_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ev   (.I0((st == LOAD) && (sub_st_load == 4'd3)), .O(ev_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_t1   (.I0((st == LOAD) && (sub_st_load == 4'd7)), .O(t1_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_tt   (.I0((st == LOAD) && (sub_st_load == 4'd8)), .O(tt_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_zq   (.I0((st == LOAD) && (sub_st_load == 4'd8)), .O(zq_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cysh (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(cysh_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cxsh (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(cxsh_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_atn  (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(atn_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cxn  (.I0((st == STEP) && (sub_st_step == 4'd1)), .O(cxn_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cyn  (.I0((st == STEP) && (sub_st_step == 4'd1)), .O(cyn_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_zn   (.I0((st == STEP) && (sub_st_step == 4'd1)), .O(zn_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lva  (.I0((st == FIN)  && (sub_st_fin == 4'd1)),  .O(lva_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nv   (.I0((st == FIN)  && (sub_st_fin == 4'd2)),  .O(nv_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw   (.I0((st == FIN)  && (sub_st_fin == 4'd4)),  .O(nw_we_s));
`else
		assign ev0_we_s  = (st == LOAD) && (sub_st_load == 4'd2);
		assign ev_we_s   = (st == LOAD) && (sub_st_load == 4'd3);
		assign t1_we_s   = (st == LOAD) && (sub_st_load == 4'd7);
		assign tt_we_s   = (st == LOAD) && (sub_st_load == 4'd8);
		assign zq_we_s   = (st == LOAD) && (sub_st_load == 4'd8);
		assign cysh_we_s = (st == STEP) && (sub_st_step == 4'd0);
		assign cxsh_we_s = (st == STEP) && (sub_st_step == 4'd0);
		assign atn_we_s  = (st == STEP) && (sub_st_step == 4'd0);
		assign cxn_we_s  = (st == STEP) && (sub_st_step == 4'd1);
		assign cyn_we_s  = (st == STEP) && (sub_st_step == 4'd1);
		assign zn_we_s   = (st == STEP) && (sub_st_step == 4'd1);
		assign lva_we_s  = (st == FIN)  && (sub_st_fin == 4'd1);
		assign nv_we_s   = (st == FIN)  && (sub_st_fin == 4'd2);
		assign nw_we_s   = (st == FIN)  && (sub_st_fin == 4'd4);
`endif
		reg [W39-1:0] ev0_sl, ev_sl, zq_sl;
		reg [W40-1:0] t1_sl, tt_sl, atn_sl;
		reg [W36-1:0] cysh_sl, cxsh_sl, cxn_sl, cyn_sl;
		reg [W41-1:0] zn_sl, lva_sl, nv_sl, nw_sl;
		always @(posedge clk) begin
			if (ev0_we_s)  ev0_sl  <= ev0[gxl*16 +: W39];
			if (ev_we_s)   ev_sl   <= ev[gxl*16 +: W39];
			if (t1_we_s)   t1_sl   <= t1[gxl*16 +: W40];
			if (tt_we_s)   tt_sl   <= tt[gxl*16 +: W40];
			if (zq_we_s)   zq_sl   <= zq[gxl*16 +: W39];
			if (cysh_we_s) cysh_sl <= cysh[gxl*16 +: W36];
			if (cxsh_we_s) cxsh_sl <= cxsh[gxl*16 +: W36];
			if (atn_we_s)  atn_sl  <= atn[gxl*16 +: W40];
			if (cxn_we_s)  cxn_sl  <= cx_n[gxl*16 +: W36];
			if (cyn_we_s)  cyn_sl  <= cy_n[gxl*16 +: W36];
			if (zn_we_s)   zn_sl   <= z_n[gxl*16 +: W41];
			if (lva_we_s)  lva_sl  <= lva[gxl*16 +: W41];
			if (nv_we_s)   nv_sl   <= nv[gxl*16 +: W41];
			if (nw_we_s)   nw_sl   <= nw[gxl*16 +: W41];
		end
		assign ev0_r[gxl*16 +: W39]  = ev0_sl;
		assign ev_r[gxl*16 +: W39]   = ev_sl;
		assign t1_r[gxl*16 +: W40]   = t1_sl;
		assign tt_r[gxl*16 +: W40]   = tt_sl;
		assign zq_r[gxl*16 +: W39]   = zq_sl;
		assign cysh_r[gxl*16 +: W36] = cysh_sl;
		assign cxsh_r[gxl*16 +: W36] = cxsh_sl;
		assign atn_r[gxl*16 +: W40]  = atn_sl;
		assign cx_n_r[gxl*16 +: W36] = cxn_sl;
		assign cy_n_r[gxl*16 +: W36] = cyn_sl;
		assign z_n_r[gxl*16 +: W41]  = zn_sl;
		assign lva_r[gxl*16 +: W41]  = lva_sl;
		assign nv_r[gxl*16 +: W41]   = nv_sl;
		assign nw_r[gxl*16 +: W41]   = nw_sl;
	end
	for (gxl = 0; gxl < 2; gxl = gxl + 1) begin : g_xu_nr_sl
		localparam W24 = (gxl == 1) ? 8 : 16;
		wire nrmp1_we_s, nrr_we_s;
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nrmp1 (.I0((st == FIN) && (sub_st_fin == 4'd5)), .O(nrmp1_we_s));
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nrr   (.I0((st == FIN) && (sub_st_fin == 4'd6)), .O(nrr_we_s));
`else
		assign nrmp1_we_s = (st == FIN) && (sub_st_fin == 4'd5);
		assign nrr_we_s   = (st == FIN) && (sub_st_fin == 4'd6);
`endif
		reg [W24-1:0] nrmp1_sl;
		reg [15:0] nrr_sl;
		always @(posedge clk) begin
			if (nrmp1_we_s) nrmp1_sl <= nr_mp1_d[gxl*16 +: W24];
			if (nrr_we_s)   nrr_sl   <= nr[gxl*16 +: 16];
		end
		assign nr_mp1_r[gxl*16 +: W24] = nrmp1_sl;
		assign nr_r[gxl*16 +: 16]      = nrr_sl;
	end
	endgenerate

	wire lx_we_lo, lx_we_hi, lm_we_lo, lm_we_hi;
	wire sh1_we_a, sh1_we_b, sh1_we_eamt, sh1_we_ersh, sh1_we_trsh1, sh1_we_trsh2, sh1_we_tsh_lo, sh1_we_tsh_hi;
	wire load_commit_raw = (st == LOAD) && (sub_st_load >= 4'd9);
	wire load_commit_res;
	wire cordic_load_commit, y_we_load, fr_we_load_lo, fr_we_load_hi;
	wire root_we_load_we, root_we_load_lo, root_we_load_hi, rem_we_load, n_we_load_lo, n_we_load_hi;
	wire load_end_lo, load_end_hi, res_we_lo, res_we_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lx_lo  (.I0((st == LOAD) && (sub_st_load == 4'd0)), .O(lx_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lx_hi  (.I0((st == LOAD) && (sub_st_load == 4'd0)), .O(lx_we_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lm_lo  (.I0((st == LOAD) && (sub_st_load == 4'd0)), .O(lm_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lm_hi  (.I0((st == LOAD) && (sub_st_load == 4'd0)), .O(lm_we_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_a  (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_a));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_b  (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_b));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_ea (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_eamt));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_e  (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_ersh));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_t1 (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_trsh1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_t2 (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_trsh2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_s1 (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_tsh_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_sh1_s2 (.I0((st == LOAD) && (sub_st_load == 4'd1)), .O(sh1_we_tsh_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_res (.I0(load_commit_raw), .O(load_commit_res));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_crd (.I0(load_commit_raw), .O(cordic_load_commit));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_y   (.I0(load_commit_raw), .O(y_we_load));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_frl (.I0(load_commit_raw), .O(fr_we_load_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_frh (.I0(load_commit_raw), .O(fr_we_load_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_rtw (.I0(load_commit_raw), .O(root_we_load_we));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_rtl (.I0(load_commit_raw), .O(root_we_load_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_rth (.I0(load_commit_raw), .O(root_we_load_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_rem (.I0(load_commit_raw), .O(rem_we_load));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_nlo (.I0(load_commit_raw), .O(n_we_load_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lcom_nhi (.I0(load_commit_raw), .O(n_we_load_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lend_lo (.I0(load_commit_res), .O(load_end_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lend_hi (.I0(load_commit_res), .O(load_end_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_res_lo (.I0((load_commit_res && !load_go_step_r) || ((st == FIN) && (sub_st_fin >= 4'd7) && !sres)), .O(res_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_res_hi (.I0((load_commit_res && !load_go_step_r) || ((st == FIN) && (sub_st_fin >= 4'd7) && !sres)), .O(res_we_hi));
`else
	assign lx_we_lo    = (st == LOAD) && (sub_st_load == 4'd0);
	assign lx_we_hi    = (st == LOAD) && (sub_st_load == 4'd0);
	assign lm_we_lo    = (st == LOAD) && (sub_st_load == 4'd0);
	assign lm_we_hi    = (st == LOAD) && (sub_st_load == 4'd0);
	assign sh1_we_a    = (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_b    = (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_eamt = (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_ersh = (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_trsh1= (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_trsh2= (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_tsh_lo = (st == LOAD) && (sub_st_load == 4'd1);
	assign sh1_we_tsh_hi = (st == LOAD) && (sub_st_load == 4'd1);
	assign load_commit_res     = load_commit_raw;
	assign cordic_load_commit  = load_commit_raw;
	assign y_we_load           = load_commit_raw;
	assign fr_we_load_lo       = load_commit_raw;
	assign fr_we_load_hi       = load_commit_raw;
	assign root_we_load_we     = load_commit_raw;
	assign root_we_load_lo     = load_commit_raw;
	assign root_we_load_hi     = load_commit_raw;
	assign rem_we_load         = load_commit_raw;
	assign n_we_load_lo        = load_commit_raw;
	assign n_we_load_hi        = load_commit_raw;
	assign load_end_lo = load_commit_res;
	assign load_end_hi = load_commit_res;
	assign res_we_lo   = (load_end_lo && !load_go_step_r) || (((st == FIN) && (sub_st_fin >= 4'd7)) && !sres);
	assign res_we_hi   = (load_end_hi && !load_go_step_r) || (((st == FIN) && (sub_st_fin >= 4'd7)) && !sres);
`endif
	wire step_end_b0, step_end_b1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_stpe0 (.I0((st == STEP) && (sub_st_step >= 4'd6)), .O(step_end_b0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_stpe1 (.I0((st == STEP) && (sub_st_step >= 4'd6)), .O(step_end_b1));
`else
	assign step_end_b0 = (st == STEP) && (sub_st_step >= 4'd6);
	assign step_end_b1 = (st == STEP) && (sub_st_step >= 4'd6);
`endif
	wire step_end   = step_end_b0;
	wire step_last  = step_end_b0 && (step_cnt == nsteps_m1);
	wire fin_end    = (st == FIN)  && (sub_st_fin >= 4'd7);
	wire load_end   = load_end_lo;

	always @(posedge clk) begin
		if (lx_we_lo) lx[15:0]   <= lx_raw[15:0];
		if (lx_we_hi) lx[31:16]  <= lx_raw[31:16];
		if (lm_we_lo) lm_r[15:0] <= lx_raw[15:0];
		if (lm_we_hi) lm_r[23:16] <= {1'b1, lx_raw[22:16]};
		if (sh1_we_a) begin
			hee_r  <= hee;
			lnan_r <= lnan;
			linf_r <= linf;
			lzero_r <= lzero;
			le_ge135_r <= (le_cmp >= 8'd135);
			le_lt115_r <= (le_cmp < 8'd115);
		end
		if (sh1_we_b) esh_r  <= esh;
		if (sh1_we_eamt) begin
			esh_amt_r  <= esh[11] ? ersh : {3'd0, esh[3:0]};
			esh_left_r <= !esh[11];
		end
		if (sh1_we_ersh) ersh_r <= ersh;
		if (sh1_we_trsh1) trsh_r[3:0] <= trsh[3:0];
		if (sh1_we_trsh2) trsh_r[7:4] <= trsh[7:4];
		if (sh1_we_tsh_lo) tsh_r[5:0]  <= tsh[5:0];
		if (sh1_we_tsh_hi) begin
			tsh_r[11:6] <= tsh[11:6];
			tsh_amt_r   <= tsh[11] ? trsh : {2'd0, tsh[5:0]};
			tsh_left_r  <= !tsh[11];
		end
		if (res_we_lo) res[15:0]  <= load_end_lo ? load_res_r[15:0]  : fin[15:0];
		if (res_we_hi) res[31:16] <= load_end_hi ? load_res_r[31:16] : fin[31:16];
	end

	/* Sliced/buffered datapath registers */
	wire [LW-1:0] first_x_b0, first_x_b1, first_x_b2, first_x_b3;
	wire [LW-1:0] after_x_b0, after_x_b1, after_x_b2, after_x_b3;
	genvar gxb;
	generate
		for (gxb = 0; gxb < LW; gxb = gxb + 1) begin : g_buf_x_sel
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fx_b0 (.I0(first[gxb]), .O(first_x_b0[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fx_b1 (.I0(first[gxb]), .O(first_x_b1[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fx_b2 (.I0(first[gxb]), .O(first_x_b2[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fx_b3 (.I0(first[gxb]), .O(first_x_b3[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ax_b0 (.I0(after[gxb]), .O(after_x_b0[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ax_b1 (.I0(after[gxb]), .O(after_x_b1[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ax_b2 (.I0(after[gxb]), .O(after_x_b2[gxb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ax_b3 (.I0(after[gxb]), .O(after_x_b3[gxb]));
`else
			assign first_x_b0[gxb] = first[gxb];
			assign first_x_b1[gxb] = first[gxb];
			assign first_x_b2[gxb] = first[gxb];
			assign first_x_b3[gxb] = first[gxb];
			assign after_x_b0[gxb] = after[gxb];
			assign after_x_b1[gxb] = after[gxb];
			assign after_x_b2[gxb] = after[gxb];
			assign after_x_b3[gxb] = after[gxb];
`endif
		end
	endgenerate

	wire cur_lx_load_raw = ((st == IDLE) && mine && (first != NPHYS[LW:0])) ||
	                       ((st == STORE) && (after != NPHYS[LW:0]));
	wire idle_lx_raw = (st == IDLE);

	wire cur_lx_lo, cur_lx_hi;
	wire idle_lx_lo, idle_lx_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_clx_lo (.I0(cur_lx_load_raw), .O(cur_lx_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_clx_hi (.I0(cur_lx_load_raw), .O(cur_lx_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ilx_lo (.I0(idle_lx_raw),     .O(idle_lx_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ilx_hi (.I0(idle_lx_raw),     .O(idle_lx_hi));
`else
	assign cur_lx_lo = cur_lx_load_raw;
	assign cur_lx_hi = cur_lx_load_raw;
	assign idle_lx_lo = idle_lx_raw;
	assign idle_lx_hi = idle_lx_raw;
`endif

	reg [7:0] lx_cur_b0, lx_cur_b1, lx_cur_b2, lx_cur_b3;
	always @(posedge clk) begin
		if (rst_p) begin
			lx_cur_b0 <= 8'd0;
			lx_cur_b1 <= 8'd0;
			lx_cur_b2 <= 8'd0;
			lx_cur_b3 <= 8'd0;
		end else begin
			if (cur_lx_lo) begin
				lx_cur_b0 <= idle_lx_lo ? x_a[{first_x_b0, 5'd0} +: 8] : rx[{after_x_b0, 5'd0} +: 8];
				lx_cur_b1 <= idle_lx_lo ? x_a[{first_x_b1, 5'd8} +: 8] : rx[{after_x_b1, 5'd8} +: 8];
			end
			if (cur_lx_hi) begin
				lx_cur_b2 <= idle_lx_hi ? x_a[{first_x_b2, 5'd16} +: 8] : rx[{after_x_b2, 5'd16} +: 8];
				lx_cur_b3 <= idle_lx_hi ? x_a[{first_x_b3, 5'd24} +: 8] : rx[{after_x_b3, 5'd24} +: 8];
			end
		end
	end
	assign lx_cur_r = {lx_cur_b3, lx_cur_b2, lx_cur_b1, lx_cur_b0};

	wire load_res_we_lo, load_res_we_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lres_lo (.I0((st == LOAD) && (sub_st_load == 4'd8)), .O(load_res_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lres_hi (.I0((st == LOAD) && (sub_st_load == 4'd8)), .O(load_res_we_hi));
`else
	assign load_res_we_lo = (st == LOAD) && (sub_st_load == 4'd8);
	assign load_res_we_hi = (st == LOAD) && (sub_st_load == 4'd8);
`endif

	reg [15:0] load_res_lo, load_res_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			load_res_lo <= 16'd0;
			load_res_hi <= 16'd0;
		end else begin
			if (load_res_we_lo) load_res_lo <= load_res_w[15:0];
			if (load_res_we_hi) load_res_hi <= load_res_w[31:16];
		end
	end
	assign load_res_r = {load_res_hi, load_res_lo};

	wire prod_r_81_a0, prod_r_81_a1, prod_r_81_a2;
	wire prod_r_81_b, prod_r_81_c;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pr81_a0 (.I0(prod_r[81]), .O(prod_r_81_a0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pr81_a1 (.I0(prod_r[81]), .O(prod_r_81_a1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pr81_a2 (.I0(prod_r[81]), .O(prod_r_81_a2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pr81_b  (.I0(prod_r[81]), .O(prod_r_81_b));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_pr81_c  (.I0(prod_r[81]), .O(prod_r_81_c));
`else
	assign prod_r_81_a0 = prod_r[81];
	assign prod_r_81_a1 = prod_r[81];
	assign prod_r_81_a2 = prod_r[81];
	assign prod_r_81_b  = prod_r[81];
	assign prod_r_81_c  = prod_r[81];
`endif

	wire ph_rem, ph_root, ph_step;
	wire ph_n_s0, ph_n_s1, ph_n_s2, ph_n_s3;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_rem  (.I0(ph), .O(ph_rem));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_root (.I0(ph), .O(ph_root));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_step (.I0(ph), .O(ph_step));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_n0   (.I0(ph), .O(ph_n_s0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_n1   (.I0(ph), .O(ph_n_s1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_n2   (.I0(ph), .O(ph_n_s2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ph_n3   (.I0(ph), .O(ph_n_s3));
`else
	assign ph_rem   = ph;
	assign ph_root  = ph;
	assign ph_step  = ph;
	assign ph_n_s0  = ph;
	assign ph_n_s1  = ph;
	assign ph_n_s2  = ph;
	assign ph_n_s3  = ph;
`endif

	/* CORDIC cx, cy, z */
	wire cordic_we_cx_lo, cordic_we_cx_hi;
	wire cordic_we_cy_lo, cordic_we_cy_hi;
	wire cordic_we_z_lo, cordic_we_z_mid, cordic_we_z_hi;
	wire is_load_cx_lo, is_load_cx_hi;
	wire is_load_cy_lo, is_load_cy_hi;
	wire is_load_z_lo, is_load_z_mid, is_load_z_hi;
	wire cordic_step_commit = step_end_b0 && ((rop_we == ATG_XU_SIN[2:0]) || (rop_we == ATG_XU_COS[2:0]));
	wire cordic_we_raw = cordic_load_commit || cordic_step_commit;

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_cxlo (.I0(cordic_we_raw), .O(cordic_we_cx_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_cxhi (.I0(cordic_we_raw), .O(cordic_we_cx_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_cylo (.I0(cordic_we_raw), .O(cordic_we_cy_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_cyhi (.I0(cordic_we_raw), .O(cordic_we_cy_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_zlo  (.I0(cordic_we_raw), .O(cordic_we_z_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_zmid (.I0(cordic_we_raw), .O(cordic_we_z_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_cwe_zhi  (.I0(cordic_we_raw), .O(cordic_we_z_hi));

	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_cxlo (.I0(cordic_load_commit), .O(is_load_cx_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_cxhi (.I0(cordic_load_commit), .O(is_load_cx_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_cylo (.I0(cordic_load_commit), .O(is_load_cy_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_cyhi (.I0(cordic_load_commit), .O(is_load_cy_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_zlo  (.I0(cordic_load_commit), .O(is_load_z_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_zmid (.I0(cordic_load_commit), .O(is_load_z_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ild_zhi  (.I0(cordic_load_commit), .O(is_load_z_hi));
`else
	assign cordic_we_cx_lo = cordic_we_raw;
	assign cordic_we_cx_hi = cordic_we_raw;
	assign cordic_we_cy_lo = cordic_we_raw;
	assign cordic_we_cy_hi = cordic_we_raw;
	assign cordic_we_z_lo  = cordic_we_raw;
	assign cordic_we_z_mid = cordic_we_raw;
	assign cordic_we_z_hi  = cordic_we_raw;

	assign is_load_cx_lo = cordic_load_commit;
	assign is_load_cx_hi = cordic_load_commit;
	assign is_load_cy_lo = cordic_load_commit;
	assign is_load_cy_hi = cordic_load_commit;
	assign is_load_z_lo  = cordic_load_commit;
	assign is_load_z_mid = cordic_load_commit;
	assign is_load_z_hi  = cordic_load_commit;
`endif

	wire tt38_lo, tt38_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_tt38_lo (.I0(tt_r[38]), .O(tt38_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_tt38_hi (.I0(tt_r[38]), .O(tt38_hi));
`else
	assign tt38_lo = tt_r[38];
	assign tt38_hi = tt_r[38];
`endif
	wire [40:0] z_init = {
		tt38_hi ? {2'b0, zq_r[38:20]} : {3'b0, tt_r[37:20]},
		tt38_lo ? zq_r[19:0]          : tt_r[19:0]
	};
	reg [17:0] cx_lo, cx_hi, cy_lo, cy_hi;
	reg [13:0] z_lo, z_mid;
	reg [12:0] z_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			cx_lo <= 18'd0;
			cx_hi <= 18'd0;
			cy_lo <= 18'd0;
			cy_hi <= 18'd0;
			z_lo  <= 14'd0;
			z_mid <= 14'd0;
			z_hi  <= 13'd0;
		end else begin
			if (cordic_we_cx_lo)
				cx_lo <= is_load_cx_lo ? XU_CG[17:0] : cx_n_r[17:0];
			if (cordic_we_cx_hi)
				cx_hi <= is_load_cx_hi ? {1'b0, XU_CG[34:18]} : cx_n_r[35:18];
			if (cordic_we_cy_lo)
				cy_lo <= is_load_cy_lo ? 18'd0 : cy_n_r[17:0];
			if (cordic_we_cy_hi)
				cy_hi <= is_load_cy_hi ? 18'd0 : cy_n_r[35:18];
			if (cordic_we_z_lo)
				z_lo  <= is_load_z_lo ? z_init[13:0] : z_n_r[13:0];
			if (cordic_we_z_mid)
				z_mid <= is_load_z_mid ? z_init[27:14] : z_n_r[27:14];
			if (cordic_we_z_hi)
				z_hi  <= is_load_z_hi ? z_init[40:28] : z_n_r[40:28];
		end
	end
	assign cx = {cx_hi, cx_lo};
	assign cy = {cy_hi, cy_lo};
	assign z  = {z_hi, z_mid, z_lo};

	/* Multiplier buffer mb_r */
	wire mb_we_lo, mb_we_mid, mb_we_hi;
	wire is_exp2_lo0, is_exp2_lo1;
	wire is_exp2_mid0, is_exp2_mid1;
	wire is_exp2_hi0, is_exp2_hi1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_mb_lo   (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(mb_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_mb_mid  (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(mb_we_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_mb_hi   (.I0((st == STEP) && (sub_st_step == 4'd0)), .O(mb_we_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_lo0 (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_lo1 (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_m0  (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_mid0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_m1  (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_mid1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_hi0 (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_hi0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_exp_hi1 (.I0(rop_load_mb == ATG_XU_EXP2[2:0]), .O(is_exp2_hi1));
`else
	assign mb_we_lo = (st == STEP) && (sub_st_step == 4'd0);
	assign mb_we_mid = (st == STEP) && (sub_st_step == 4'd0);
	assign mb_we_hi = (st == STEP) && (sub_st_step == 4'd0);
	assign is_exp2_lo0  = rop_load_mb == ATG_XU_EXP2[2:0];
	assign is_exp2_lo1  = rop_load_mb == ATG_XU_EXP2[2:0];
	assign is_exp2_mid0 = rop_load_mb == ATG_XU_EXP2[2:0];
	assign is_exp2_mid1 = rop_load_mb == ATG_XU_EXP2[2:0];
	assign is_exp2_hi0  = rop_load_mb == ATG_XU_EXP2[2:0];
	assign is_exp2_hi1  = rop_load_mb == ATG_XU_EXP2[2:0];
`endif

	wire [39:0] expk_full_lo = xu_expk(step_tab_exp_lo);
	wire [39:0] expk_full_hi = xu_expk(step_tab_exp_hi);
	wire [41:0] expk_val = {2'd0, expk_full_hi[39:20], expk_full_lo[19:0]};
	reg [13:0] mb_r_lo, mb_r_mid, mb_r_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			mb_r_lo  <= 14'd0;
			mb_r_mid <= 14'd0;
			mb_r_hi  <= 14'd0;
		end else begin
			if (mb_we_lo)  mb_r_lo  <= {is_exp2_lo1  ? expk_val[13:7]  : y[13:7],  is_exp2_lo0  ? expk_val[6:0]  : y[6:0]};
			if (mb_we_mid) mb_r_mid <= {is_exp2_mid1 ? expk_val[27:21] : y[27:21], is_exp2_mid0 ? expk_val[20:14] : y[20:14]};
			if (mb_we_hi)  mb_r_hi  <= {is_exp2_hi1  ? expk_val[41:35] : y[41:35], is_exp2_hi0  ? expk_val[34:28] : y[34:28]};
		end
	end
	assign mb_r = {mb_r_hi, mb_r_mid, mb_r_lo};

	/* Accumulator y */
	wire y_we_exp  = step_end_b0 && (rop_we == ATG_XU_EXP2[2:0]) && fbit;
	wire y_we_log  = step_end_b0 && (rop_we == ATG_XU_LOG2[2:0]);
	wire y_we_raw  = y_we_load || y_we_exp || y_we_log;

	wire y_we_lo, y_we_mid, y_we_hi;
	wire y_we_load_lo, y_we_load_mid, y_we_load_hi;
	wire y_we_exp_lo, y_we_exp_mid, y_we_exp_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_y_lo   (.I0(y_we_raw), .O(y_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_y_mid  (.I0(y_we_raw), .O(y_we_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_y_hi   (.I0(y_we_raw), .O(y_we_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yld_lo (.I0(y_we_load), .O(y_we_load_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yld_mid(.I0(y_we_load), .O(y_we_load_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yld_hi (.I0(y_we_load), .O(y_we_load_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yex_lo (.I0(y_we_exp), .O(y_we_exp_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yex_mid(.I0(y_we_exp), .O(y_we_exp_mid));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_yex_hi (.I0(y_we_exp), .O(y_we_exp_hi));
`else
	assign y_we_lo   = y_we_raw;
	assign y_we_mid  = y_we_raw;
	assign y_we_hi   = y_we_raw;
	assign y_we_load_lo  = y_we_load;
	assign y_we_load_mid = y_we_load;
	assign y_we_load_hi  = y_we_load;
	assign y_we_exp_lo   = y_we_exp;
	assign y_we_exp_mid  = y_we_exp;
	assign y_we_exp_hi   = y_we_exp;
`endif

	wire is_exp2_y_lo, is_exp2_y_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_expy_lo (.I0(rop_load_y == ATG_XU_EXP2[2:0]), .O(is_exp2_y_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_expy_hi (.I0(rop_load_y == ATG_XU_EXP2[2:0]), .O(is_exp2_y_hi));
`else
	assign is_exp2_y_lo = rop_load_y == ATG_XU_EXP2[2:0];
	assign is_exp2_y_hi = rop_load_y == ATG_XU_EXP2[2:0];
`endif
	wire [41:0] y_load_val = {
		is_exp2_y_hi ? 21'h20000 : {1'b0, lm_y[23:4]},
		is_exp2_y_lo ? 21'd0     : {lm_y[3:0], 17'd0}
	};
	wire [13:0] y_next_lo = y_we_load_lo ? y_load_val[13:0] :
	                        y_we_exp_lo  ? prod_r[51:38] :
	                        (prod_r_81_a0 ? prod_r[54:41] : prod_r[53:40]);
	wire [13:0] y_next_mid = y_we_load_mid ? y_load_val[27:14] :
	                         y_we_exp_mid  ? prod_r[65:52] :
	                         (prod_r_81_a1 ? prod_r[68:55] : prod_r[67:54]);
	wire [13:0] y_next_hi = y_we_load_hi ? y_load_val[41:28] :
	                        y_we_exp_hi  ? {2'd0, prod_r[77:66]} :
	                        (prod_r_81_a2 ? {1'b0, prod_r[81:69]} : prod_r[81:68]);

	reg [13:0] y_lo, y_mid, y_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			y_lo  <= 14'd0;
			y_mid <= 14'd0;
			y_hi  <= 14'd0;
		end else begin
			if (y_we_lo)  y_lo  <= y_next_lo;
			if (y_we_mid) y_mid <= y_next_mid;
			if (y_we_hi)  y_hi  <= y_next_hi;
		end
	end
	assign y = {y_hi, y_mid, y_lo};

	/* Fraction register fr */
	wire fr_we_step = step_end_b1 && (rop_we == ATG_XU_LOG2[2:0]);
	wire fr_we_raw = fr_we_load_lo || fr_we_step;

	wire fr_we_lo, fr_we_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fr_lo (.I0(fr_we_raw), .O(fr_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_fr_hi (.I0(fr_we_raw), .O(fr_we_hi));
`else
	assign fr_we_lo = fr_we_raw;
	assign fr_we_hi = fr_we_raw;
`endif

	wire is_exp2_fr_lo, is_exp2_fr_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_expfr_lo (.I0(rop_load_fr == ATG_XU_EXP2[2:0]), .O(is_exp2_fr_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_expfr_hi (.I0(rop_load_fr == ATG_XU_EXP2[2:0]), .O(is_exp2_fr_hi));
`else
	assign is_exp2_fr_lo = rop_load_fr == ATG_XU_EXP2[2:0];
	assign is_exp2_fr_hi = rop_load_fr == ATG_XU_EXP2[2:0];
`endif
	wire [29:0] fr_load_val = {
		is_exp2_fr_hi ? ev_r[29:15] : 15'd0,
		is_exp2_fr_lo ? ev_r[14:0]  : 15'd0
	};
	wire [14:0] fr_next_lo = fr_we_load_lo ? fr_load_val[14:0]  : {fr_lo[13:0], prod_r_81_b};
	wire [14:0] fr_next_hi = fr_we_load_hi ? fr_load_val[29:15] : {fr_hi[13:0], fr_lo[14]};
	reg [14:0] fr_lo, fr_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			fr_lo <= 15'd0;
			fr_hi <= 15'd0;
		end else begin
			if (fr_we_lo) fr_lo <= fr_next_lo;
			if (fr_we_hi) fr_hi <= fr_next_hi;
		end
	end
	assign fr = {fr_hi, fr_lo};

	/* Sqrt/div root */
	wire root_we_step = step_end_b1 && ((rop_we == ATG_XU_RCP[2:0]) || (((rop_we == ATG_XU_RSQ[2:0]) || (rop_we == ATG_XU_FSQRT[2:0])) && !ph_root));
	wire root_we_raw = root_we_load_we || root_we_step;

	wire root_we_lo, root_we_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_root_lo (.I0(root_we_raw), .O(root_we_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_root_hi (.I0(root_we_raw), .O(root_we_hi));
`else
	assign root_we_lo = root_we_raw;
	assign root_we_hi = root_we_raw;
`endif

	wire dtr34_rem_s0, dtr34_rem_s1, dtr34_rem_s2, dtr34_root;
	wire dtr34_n;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr34_r0 (.I0(dtr_r[34]), .O(dtr34_rem_s0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr34_r1 (.I0(dtr_r[34]), .O(dtr34_rem_s1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr34_r2 (.I0(dtr_r[34]), .O(dtr34_rem_s2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr34_rt (.I0(dtr_r[34]), .O(dtr34_root));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr34_n  (.I0(dtr_r[34]), .O(dtr34_n));
`else
	assign dtr34_rem_s0 = dtr_r[34];
	assign dtr34_rem_s1 = dtr_r[34];
	assign dtr34_rem_s2 = dtr_r[34];
	assign dtr34_root   = dtr_r[34];
	assign dtr34_n      = dtr_r[34];
`endif

	wire [14:0] root_next_lo = root_we_load_lo ? 15'd0 : {root[13:0], (rop_step == ATG_XU_RCP[2:0]) ? !dtr34_root : !strl34_root};
	wire [14:0] root_next_hi = root_we_load_hi ? 15'd0 : root[28:14];
	wire [29:0] root_next = {root_next_hi, root_next_lo};
	reg [14:0] root_lo, root_hi;
	always @(posedge clk) begin
		if (rst_p) begin
			root_lo <= 15'd0;
			root_hi <= 15'd0;
		end else begin
			if (root_we_lo) root_lo <= root_next[14:0];
			if (root_we_hi) root_hi <= root_next[29:15];
		end
	end
	assign root = {root_hi, root_lo};

	/* Remainder rem */
	wire rem_we_step = step_end_b1 && ((rop_we == ATG_XU_RCP[2:0]) || (rop_we == ATG_XU_RSQ[2:0]) || (rop_we == ATG_XU_FSQRT[2:0]));
	wire rem_we_last = step_last && (rop_we == ATG_XU_RSQ[2:0]) && !ph_rem;
	wire rem_we_last_lo, rem_we_last_hi, rem_we_last_raw;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rwl_lo  (.I0(rem_we_last), .O(rem_we_last_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rwl_hi  (.I0(rem_we_last), .O(rem_we_last_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rwl_raw (.I0(rem_we_last), .O(rem_we_last_raw));
`else
	assign rem_we_last_lo  = rem_we_last;
	assign rem_we_last_hi  = rem_we_last;
	assign rem_we_last_raw = rem_we_last;
`endif
	wire rem_we_raw = rem_we_load || rem_we_step || rem_we_last_raw;

	wire rem_we_s0, rem_we_s1, rem_we_s2;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rem_s0 (.I0(rem_we_raw), .O(rem_we_s0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rem_s1 (.I0(rem_we_raw), .O(rem_we_s1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rem_s2 (.I0(rem_we_raw), .O(rem_we_s2));
`else
	assign rem_we_s0 = rem_we_raw;
	assign rem_we_s1 = rem_we_raw;
	assign rem_we_s2 = rem_we_raw;
`endif

	wire rem_step_cond = (rop_step == ATG_XU_RCP[2:0]) || ph_rem;
	wire dtr34_rem_lo, dtr34_rem_hi;
	wire rem_cond_lo, rem_cond_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr_rlo (.I0(dtr_r[34]), .O(dtr34_rem_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_dtr_rhi (.I0(dtr_r[34]), .O(dtr34_rem_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rcnd_lo (.I0(rem_step_cond), .O(rem_cond_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rcnd_hi (.I0(rem_step_cond), .O(rem_cond_hi));
`else
	assign dtr34_rem_lo = dtr_r[34];
	assign dtr34_rem_hi = dtr_r[34];
	assign rem_cond_lo  = rem_step_cond;
	assign rem_cond_hi  = rem_step_cond;
`endif
	wire [16:0] rem_step_lo = rem_cond_lo ? (!dtr34_rem_lo ? dtr_r[16:0] : {rem[15:0], 1'b0}) : snext_r[16:0];
	wire [16:0] rem_step_hi = rem_cond_hi ? (!dtr34_rem_hi ? dtr_r[33:17] : rem[32:16]) : snext_r[33:17];
	wire [33:0] rem_step_val = {rem_step_hi, rem_step_lo};
	wire rem_we_load_lo, rem_we_load_hi;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rem_ld_lo (.I0(rem_we_load), .O(rem_we_load_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_rem_ld_hi (.I0(rem_we_load), .O(rem_we_load_hi));
`else
	assign rem_we_load_lo = rem_we_load;
	assign rem_we_load_hi = rem_we_load;
`endif
	wire [16:0] rem_next_lo = rem_we_load_lo ? ((rop_step == ATG_XU_RCP[2:0]) ? 17'h00000 : 17'd0) :
	                          rem_we_last_lo ? 17'h00000 : rem_step_lo;
	wire [16:0] rem_next_hi = rem_we_load_hi ? ((rop_step == ATG_XU_RCP[2:0]) ? 17'h00020 : 17'd0) :
	                          rem_we_last_hi ? 17'h00800 : rem_step_hi;
	wire [33:0] rem_next = {rem_next_hi, rem_next_lo};

	reg [11:0] rem_s0, rem_s1;
	reg [9:0]  rem_s2;
	always @(posedge clk) begin
		if (rst_p) begin
			rem_s0 <= 12'd0;
			rem_s1 <= 12'd0;
			rem_s2 <= 10'd0;
		end else begin
			if (rem_we_s0) rem_s0 <= rem_next[11:0];
			if (rem_we_s1) rem_s1 <= rem_next[23:12];
			if (rem_we_s2) rem_s2 <= rem_next[33:24];
		end
	end
	assign rem = {rem_s2, rem_s1, rem_s0};

	/* Radicand n */
	wire n_we_step = step_end_b1 && ((rop_we == ATG_XU_RSQ[2:0]) || (rop_we == ATG_XU_FSQRT[2:0]));
	wire n_we_last = step_last && (rop_we == ATG_XU_RSQ[2:0]) && !ph_n_s0;
	wire n_we_last_we, n_we_last_lo0, n_we_last_lo1, n_we_last_hi0, n_we_last_hi1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw_we  (.I0(n_we_last), .O(n_we_last_we));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw_lo0 (.I0(n_we_last), .O(n_we_last_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw_lo1 (.I0(n_we_last), .O(n_we_last_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw_hi0 (.I0(n_we_last), .O(n_we_last_hi0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nw_hi1 (.I0(n_we_last), .O(n_we_last_hi1));
`else
	assign n_we_last_we  = n_we_last;
	assign n_we_last_lo0 = n_we_last;
	assign n_we_last_lo1 = n_we_last;
	assign n_we_last_hi0 = n_we_last;
	assign n_we_last_hi1 = n_we_last;
`endif
	wire n_we_raw_lo = n_we_load_lo || n_we_step || n_we_last_we;
	wire n_we_raw_hi = n_we_load_hi || n_we_step || n_we_last_we;

	wire n_we_s0, n_we_s1, n_we_s2, n_we_s3;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_n_s0 (.I0(n_we_raw_lo), .O(n_we_s0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_n_s1 (.I0(n_we_raw_lo), .O(n_we_s1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_n_s2 (.I0(n_we_raw_hi), .O(n_we_s2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_n_s3 (.I0(n_we_raw_hi), .O(n_we_s3));
`else
	assign n_we_s0 = n_we_raw_lo;
	assign n_we_s1 = n_we_raw_lo;
	assign n_we_s2 = n_we_raw_hi;
	assign n_we_s3 = n_we_raw_hi;
`endif

	wire [59:0] n_step_val = {
		ph_n_s3 ? n[59:45] : n[57:43],
		ph_n_s2 ? n[44:30] : n[42:28],
		ph_n_s1 ? {n[29], n[27:14]} : n[27:13],
		ph_n_s0 ? {n[13:0], !dtr34_n} : {n[12:0], 2'b00}
	};
	wire [59:0] n_load_val = {1'b0, lmm, 34'd0};
	wire n_we_load_lo0, n_we_load_lo1;
	wire n_we_load_hi0, n_we_load_hi1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nld_lo0 (.I0(n_we_load_lo), .O(n_we_load_lo0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nld_lo1 (.I0(n_we_load_lo), .O(n_we_load_lo1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nld_hi0 (.I0(n_we_load_hi), .O(n_we_load_hi0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_nld_hi1 (.I0(n_we_load_hi), .O(n_we_load_hi1));
`else
	assign n_we_load_lo0 = n_we_load_lo;
	assign n_we_load_lo1 = n_we_load_lo;
	assign n_we_load_hi0 = n_we_load_hi;
	assign n_we_load_hi1 = n_we_load_hi;
`endif
	wire [29:0] n_next_lo = {
		n_we_load_lo1 ? n_load_val[29:15] : n_we_last_lo1 ? 15'd0 : n_step_val[29:15],
		n_we_load_lo0 ? n_load_val[14:0]  : n_we_last_lo0 ? 15'd0 : n_step_val[14:0]
	};
	wire [29:0] n_next_hi = {
		n_we_load_hi1 ? n_load_val[59:45] : n_we_last_hi1 ? n[59:45] : n_step_val[59:45],
		n_we_load_hi0 ? n_load_val[44:30] : n_we_last_hi0 ? n[44:30] : n_step_val[44:30]
	};
	wire [59:0] n_next = {n_next_hi, n_next_lo};

	reg [14:0] n_s0, n_s1, n_s2, n_s3;
	always @(posedge clk) begin
		if (rst_p) begin
			n_s0 <= 15'd0;
			n_s1 <= 15'd0;
			n_s2 <= 15'd0;
			n_s3 <= 15'd0;
		end else begin
			if (n_we_s0) n_s0 <= n_next[14:0];
			if (n_we_s1) n_s1 <= n_next[29:15];
			if (n_we_s2) n_s2 <= n_next[44:30];
			if (n_we_s3) n_s3 <= n_next[59:45];
		end
	end
	assign n = {n_s3, n_s2, n_s1, n_s0};

	wire idle_mine_rmask;
	wire idle_mine_rop_0, idle_mine_rop_1, idle_mine_rop_2;
	wire idle_mine_rrd;
	wire idle_mine_warp_grp;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rmk (.I0(idle_mine_ctl), .O(idle_mine_rmask));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rp0 (.I0(idle_mine_ctl), .O(idle_mine_rop_0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rp1 (.I0(idle_mine_ctl), .O(idle_mine_rop_1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rp2 (.I0(idle_mine_ctl), .O(idle_mine_rop_2));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_rrd (.I0(idle_mine_ctl), .O(idle_mine_rrd));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_im_wgp (.I0(idle_mine_ctl), .O(idle_mine_warp_grp));
`else
	assign idle_mine_rmask    = idle_mine_ctl;
	assign idle_mine_rop_0    = idle_mine_ctl;
	assign idle_mine_rop_1    = idle_mine_ctl;
	assign idle_mine_rop_2    = idle_mine_ctl;
	assign idle_mine_rrd      = idle_mine_ctl;
	assign idle_mine_warp_grp = idle_mine_ctl;
`endif

	always @(posedge clk) begin
		if (rst_p) begin
			rmask <= {NPHYS{1'b0}};
			rop <= 3'd0;
			rop_fin_lo0 <= 3'd0;
			rop_fin_lo1 <= 3'd0;
			rop_fin_hi0 <= 3'd0;
			rop_fin_hi1 <= 3'd0;
			rop_fin_ctl <= 3'd0;
			rop_pipe <= 3'd0;
			rop_dt <= 3'd0;
			rop_dt_dtr_lo <= 3'd0;
			rop_dt_dtr_hi <= 3'd0;
			rop_dt_exab <= 3'd0;
			rop_dt_tt <= 3'd0;
			rop_load <= 3'd0;
			rop_load_ctl_lo <= 3'd0;
			rop_load_ctl_hi <= 3'd0;
			rop_load_mb <= 3'd0;
			rop_load_y <= 3'd0;
			rop_load_fr <= 3'd0;
			rop_we <= 3'd0;
			rop_step <= 3'd0;
			rrd <= 7'd0;
			rwarp <= {WARP_W{1'b0}};
			rgrp <= {GRP_W{1'b0}};
			rlast <= 1'b0;
			rsbe <= {(SBE_W+1){1'b0}};
		end else begin
			if (idle_mine_rmask)
				rmask <= x_mask[NPHYS-1:0];
			if (idle_mine_rop_0) begin
				rop <= x_uop[ATG_UOP_OP +: 3];
				rop_fin_lo0 <= x_uop[ATG_UOP_OP +: 3];
				rop_fin_lo1 <= x_uop[ATG_UOP_OP +: 3];
				rop_fin_hi0 <= x_uop[ATG_UOP_OP +: 3];
				rop_fin_hi1 <= x_uop[ATG_UOP_OP +: 3];
				rop_fin_ctl <= x_uop[ATG_UOP_OP +: 3];
			end
			if (idle_mine_rop_1) begin
				rop_pipe <= x_uop[ATG_UOP_OP +: 3];
				rop_dt <= x_uop[ATG_UOP_OP +: 3];
				rop_dt_dtr_lo <= x_uop[ATG_UOP_OP +: 3];
				rop_dt_dtr_hi <= x_uop[ATG_UOP_OP +: 3];
				rop_dt_exab <= x_uop[ATG_UOP_OP +: 3];
				rop_dt_tt <= x_uop[ATG_UOP_OP +: 3];
			end
			if (idle_mine_rop_2) begin
				rop_load <= x_uop[ATG_UOP_OP +: 3];
				rop_load_ctl_lo <= x_uop[ATG_UOP_OP +: 3];
				rop_load_ctl_hi <= x_uop[ATG_UOP_OP +: 3];
				rop_load_mb <= x_uop[ATG_UOP_OP +: 3];
				rop_load_y <= x_uop[ATG_UOP_OP +: 3];
				rop_load_fr <= x_uop[ATG_UOP_OP +: 3];
				rop_we <= x_uop[ATG_UOP_OP +: 3];
				rop_step <= x_uop[ATG_UOP_OP +: 3];
			end
			if (idle_mine_rrd) begin
				rrd <= x_uop[ATG_UOP_RD +: 7];
			end
			if (idle_mine_warp_grp) begin
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
			end
		end
	end

	wire lue_we;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_lue (.I0((st == FIN) && (sub_st_fin == 4'd0)), .O(lue_we));
`else
	assign lue_we = (st == FIN) && (sub_st_fin == 4'd0);
`endif

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
			sub_st <= 4'd0;
			sub_st_load <= 4'd0;
			sub_st_step <= 4'd0;
			sub_st_fin <= 4'd0;
			li <= {LW{1'b0}};
			step <= 6'd0;
			step_cnt <= 6'd0;
			step_cordic <= 6'd0;
			step_tab <= 6'd0;
			step_tab_atan <= 6'd0;
			step_tab_expk <= 6'd0;
			step_fbit_lo  <= 6'd0;
			step_fbit_hi  <= 6'd0;
			ph <= 1'b0;
			load_go_step_r <= 1'b0;
			stk <= 1'b0;
			sres <= 1'b0;
			ex <= 12'sd0;
			ex_l_r <= 12'sd0;
			qneg <= 1'b0;
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
			lue_r <= 11'd0;
			ns_r <= 1'b0;
			nst_r <= 1'b0;
			nz_r <= 1'b0;
			ne_r <= 12'd0;
			np_r <= 6'd0;
			nsh_r <= 6'd0;
			ne127_r <= 12'd0;
			nexp_r <= 12'd0;
			nst_all_r <= 1'b0;
			nw_all1_r <= 1'b0;
			nr_ep1_r <= 12'd0;
			nr_up_r <= 1'b0;
			nr_carry_r <= 1'b0;
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
				sub_st <= 4'd0;
				sub_st_load <= 4'd0;
				sub_st_step <= 4'd0;
				sub_st_fin <= 4'd0;
				if (first == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= first[LW-1:0];
					st <= LOAD;
				end
			end
			LOAD: begin
				sub_st <= sub_st1;
				sub_st_load <= sub_st1;
				sub_st_step <= sub_st1;
				sub_st_fin <= sub_st1;
				case (sub_st_load)
				4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd7: ;
				4'd6: begin
					ex_l_r <= ex_l;
				end
				4'd8: begin
					load_go_step_r <= load_go_step_w;
				end
				default: begin
					sub_st <= 4'd0;
					sub_st_load <= 4'd0;
					sub_st_step <= 4'd0;
					sub_st_fin <= 4'd0;
					step <= 6'd0;
					step_cnt <= 6'd0;
					step_cordic <= 6'd0;
					step_tab <= 6'd0;
					step_tab_atan <= 6'd0;
					step_tab_expk <= 6'd0;
					step_fbit_lo <= 6'd0;
					step_fbit_hi <= 6'd0;
					ph <= 1'b0;
					stk <= 1'b0;
					sres <= !load_go_step_r;
					st <= load_go_step_r ? STEP : FIN;
					ex <= ex_l_r;
					qneg <= tt_r[39];
				end
				endcase
			end
			STEP: begin
				sub_st <= sub_st1;
				sub_st_load <= sub_st1;
				sub_st_step <= sub_st1;
				sub_st_fin <= sub_st1;
				case (sub_st_step)
				4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5: ;
				default: begin
					sub_st <= 4'd0;
					sub_st_load <= 4'd0;
					sub_st_step <= 4'd0;
					sub_st_fin <= 4'd0;
					step          <= step_last ? 6'd0 : step1;
					step_cnt      <= step_last ? 6'd0 : step1;
					step_cordic   <= step_last ? 6'd0 : step1;
					step_tab      <= step_last ? 6'd0 : step1;
					step_tab_atan <= step_last ? 6'd0 : step1;
					step_tab_expk <= step_last ? 6'd0 : step1;
					step_fbit_lo  <= step_last ? 6'd0 : step1;
					step_fbit_hi  <= step_last ? 6'd0 : step1;
					if (step_last) begin
						if (rop == ATG_XU_RSQ[2:0] && !ph_step) begin
							/* 2^57 / t: t = the root (30 bits). */
							ph <= 1'b1;
							stk <= strl34_snext_stk ? (srem != 34'd0) : (strl_r[33:0] != 34'd0);
						end else
							st <= FIN;
					end
				end
				endcase
			end
			FIN: begin
				sub_st <= sub_st1;
				sub_st_load <= sub_st1;
				sub_st_step <= sub_st1;
				sub_st_fin <= sub_st1;
				case (sub_st_fin)
				4'd0: if (lue_we) lue_r <= lue;
				4'd1: ;
				4'd2: begin
					ns_r <= ns;
					nst_r <= nst;
					nz_r <= nz;
					ne_r <= ne;
					np_r <= np;
				end
				4'd3: begin
					nsh_r <= nsh;
					ne127_r <= ne127;
				end
				4'd4: begin
					nexp_r <= nexp;
					nst_all_r <= (|nw[15:0]) || nst_r;
					nw_all1_r <= &nw[40:17];
				end
				4'd5: begin
					nr_ep1_r <= nr_ep1_d;
					nr_up_r <= nr_up_d;
					nr_carry_r <= nr_carry_d;
				end
				4'd6: ;
				default: begin
					sub_st <= 4'd0;
					sub_st_load <= 4'd0;
					sub_st_step <= 4'd0;
					sub_st_fin <= 4'd0;
					st <= STORE;
				end
				endcase
			end
			STORE: begin
				/* The result of FIN is in res: store it, next lane. */
				sub_st <= 4'd0;
				sub_st_load <= 4'd0;
				sub_st_step <= 4'd0;
				sub_st_fin <= 4'd0;
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

	wire l_valid_buf;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_l_val (.I0(st == RET), .O(l_valid_buf));
`else
	assign l_valid_buf = st == RET;
`endif
	assign l_valid = l_valid_buf;
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
		snext, prod_r, tp_r[82:40], tps[82:40], y[41], esh_r[10:4], carry_unused[27],
		sub_st_co_unused, step_end, nr_ep1_co_unused, nr_mp1_r[23], nw_r[40], nw_r[15:0], (NWARPS != 0)};
endmodule

`default_nettype wire
