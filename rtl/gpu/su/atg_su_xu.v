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
 * Inputs are flushed (denormals as zeros); results through atg_su_rnd
 * (RNE, flushed).  Constants: include/atg_su_xu_tab.vh.
 *
 * States: IDLE →(group)→ LOAD → STEP (per op) → FIN → (next lane | RET)
 * →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_xu #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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

	reg [2:0] st;
	reg [DW-1:0] rx, rq;
	reg [NPHYS-1:0] rmask;
	reg [2:0] rop;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	reg [LW-1:0] li;
	reg [5:0] step;
	reg ph;			/* rsq: 0 square root, 1 division */
	/* The engine. */
	reg [59:0] n;		/* sqrt: the radicand, two bits per step from the top */
	reg [33:0] rem;		/* division and sqrt remainder */
	reg [29:0] root;	/* quotient / root */
	reg stk;		/* rsq: the square root was inexact */
	reg [41:0] y;		/* exp2 / log2 */
	reg [29:0] fr;		/* exp2: the fraction bits; log2: the result bits */
	reg signed [11:0] ex;	/* the exponent of the result's LSB */
	reg signed [35:0] cx, cy;
	reg signed [40:0] z;
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

	wire [21:0] carry_unused;	/* the adders' carries and borrows */
	wire [LW:0] first = next_lane(x_mask[NPHYS-1:0], {(LW+1){1'b0}});
	wire [LW:0] li1;
	am_add #(.W(LW+1)) u_li1 (.a({1'b0, li}), .b({(LW+1){1'b0}}), .ci(1'b1), .s(li1),
		.co(carry_unused[0]));
	wire [LW:0] after = next_lane(rmask, li1);
	/* The lane's input, flushed, and its fields. */
	wire [31:0] lx = atg_su_flush(rx[li*32 +: 32]);
	wire ls = lx[31];
	wire [7:0] le = lx[30:23];
	wire [23:0] lm = {1'b1, lx[22:0]};
	wire lnan = le == 8'hFF && lx[22:0] != 0;
	wire linf = le == 8'hFF && lx[22:0] == 0;
	wire lzero = le == 8'd0;
	wire lodd = le[0];	/* e - 150 odd */
	wire [24:0] lmm = lodd ? {lm, 1'b0} : {1'b0, lm};
	/* ee/2 with ee = e - 150 (- 1 when odd). */
	wire [11:0] hee_d, esh, tsh;
	wire [6:0] ersh;
	wire [7:0] trsh;
	am_sub #(.W(12)) u_hee (.a({4'd0, le}), .b(12'd150), .bi(lodd), .d(hee_d), .bo(carry_unused[1]));
	wire signed [11:0] hee = $signed(hee_d) >>> 1;
	/* exp2: x in Q8.30 (sh = e - 120 <= 14 here). */
	am_sub #(.W(12)) u_esh (.a({4'd0, le}), .b(12'd120), .bi(1'b0), .d(esh), .bo(carry_unused[2]));
	am_sub #(.W(7)) u_ersh (.a(7'd120), .b(le[6:0]), .bi(1'b0), .d(ersh), .bo(carry_unused[3]));
	wire [38:0] ev0, ev;
	am_shift #(.W(39), .SW(7)) u_ev0 (.a({15'd0, lm}), .amt(esh[11] ? ersh : {3'd0, esh[3:0]}),
		.left(!esh[11]), .arith(1'b0), .y(ev0));
	am_addsub #(.W(39)) u_ev (.a(39'd0), .b(ev0), .sub(ls), .s(ev), .co(carry_unused[6]));
	/* sin/cos: the turns. */
	wire [82:0] tp, tps;
	am_mul #(.AW(24), .BW(59)) u_tp (.clk(clk), .en(1'b1), .a(lm), .b(XU_INV2PI), .p(tp));
	am_sub #(.W(12)) u_tsh (.a({4'd0, le}), .b(12'd171), .bi(1'b0), .d(tsh), .bo(carry_unused[4]));
	am_sub #(.W(8)) u_trsh (.a(8'd171), .b(le), .bi(1'b0), .d(trsh), .bo(carry_unused[5]));
	/* The low 40 bits of tp[39:0] << tsh or tp >> -tsh: one shifter. */
	am_shift #(.W(83), .SW(8)) u_tps (.a(tp), .amt(tsh[11] ? trsh : {2'd0, tsh[5:0]}), .left(!tsh[11]),
		.arith(1'b0), .y(tps));
	wire [39:0] t0 = $signed(tsh) >= 12'sd40 ? 40'd0 : tps[39:0];
	wire [39:0] t1, tt;
	am_addsub #(.W(40)) u_t1 (.a(40'd0), .b(t0), .sub(ls), .s(t1), .co(carry_unused[7]));
	am_add #(.W(40)) u_tt (.a(t1), .b(rop == ATG_XU_COS[2:0] ? 40'h4000000000 : 40'd0), .ci(1'b0),
		.s(tt), .co(carry_unused[8]));
	/* The shared multiplier (exp2: y * K, log2: y * y). */
	wire [41:0] mb = rop == ATG_XU_EXP2[2:0] ? {2'd0, xu_expk(step[4:0])} : y;
	wire [83:0] prod;
	am_mul #(.AW(42), .BW(42)) u_prod (.clk(clk), .en(1'b1), .a(y), .b(mb), .p(prod));
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
	wire [10:0] lue;
	am_sub #(.W(11)) u_lue (.a({3'd0, le}), .b(11'd127), .bi(1'b0), .d(lue), .bo(carry_unused[11]));
	wire [40:0] lv = {lue, fr};	/* log2: (e - 127) << 30 | fraction, signed */
	wire [40:0] lva;
	am_addsub #(.W(41)) u_lva (.a(41'd0), .b(lv), .sub(lv[40]), .s(lva), .co(carry_unused[12]));
	/* The result of a finished lane (state FIN): an integer v (< 2^41) times 2^e, sign s, to
	 * fp32 (RNE, flushed). */
	reg ns, nst, nz, fbit;	/* nz: the result is 0; fbit: fr[29 - step] (exp2) */
	reg [40:0] nv;
	reg [11:0] ne;
	reg [5:0] np;
	integer pi;
	always @(*) begin
		{ns, nst, nz, ne} = {3'b000, ex};
		case (rop)
		ATG_XU_RCP[2:0]: {ns, nv, nst} = {ls, 13'd0, root[27:0], rem != 34'd0};
		ATG_XU_FSQRT[2:0]: {nv, nst} = {15'd0, root[25:0], rem != 34'd0};
		ATG_XU_RSQ[2:0]: {nv, nst} = {12'd0, n[28:0], rem != 34'd0 || stk};
		ATG_XU_EXP2[2:0]: nv = y[40:0];
		ATG_XU_LOG2[2:0]: {ns, nv, ne, nz} = {lv[40], lva, -12'sd30, lv == 41'd0};
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
	wire [40:0] nw;
	wire [11:0] ne127, nexp;
	am_sub #(.W(6)) u_nsh (.a(6'd40), .b(np), .bi(1'b0), .d(nsh), .bo(carry_unused[13]));
	am_shift #(.W(41), .SW(6)) u_nw (.a(nv), .amt(nsh), .left(1'b1), .arith(1'b0), .y(nw));
	am_add #(.W(12)) u_ne (.a(ne), .b(12'd127), .ci(1'b0), .s(ne127), .co(carry_unused[14]));
	am_add #(.W(12)) u_nx (.a(ne127), .b({6'd0, np}), .ci(1'b0), .s(nexp), .co(carry_unused[15]));
	wire [31:0] nr;
	atg_su_rnd u_nr (.s(ns), .e(nexp), .m(nw[40:17]), .g(nw[16]), .st(|nw[15:0] || nst), .rm(3'd0), .r(nr));
	wire [31:0] fin = nz ? 32'd0 : nr;

	/* LOAD: the result's exponent (rcp, rsq, fsqrt, exp2); z of sin/cos. */
	wire [23:0] exab = rop == ATG_XU_RCP[2:0] ? {12'd100, 4'd0, le} :	/* -50 - (e - 150) */
		rop == ATG_XU_RSQ[2:0] ? {-12'sd40, hee} : rop == ATG_XU_FSQRT[2:0] ? {hee, 12'd13} :
		{{3{ev[38]}}, ev[38:30], 12'd38};
	wire [11:0] ex_l;
	wire [38:0] zq;
	am_sub #(.W(12)) u_ex (.a(exab[23:12]), .b(exab[11:0]), .bi(1'b0), .d(ex_l), .bo(carry_unused[16]));
	am_sub #(.W(39)) u_zq (.a(39'h4000000000), .b({1'b0, tt[37:0]}), .bi(1'b0), .d(zq),
		.bo(carry_unused[17]));
	/* STEP: the step count and the CORDIC rotation. */
	wire [5:0] step1;
	am_add #(.W(6)) u_step (.a(step), .b(6'd0), .ci(1'b1), .s(step1), .co(carry_unused[18]));
	wire [35:0] cysh, cxsh, cx_n, cy_n;
	wire [40:0] z_n;
	am_shift #(.W(36), .SW(6)) u_cysh (.a(cy), .amt(step), .left(1'b0), .arith(1'b1), .y(cysh));
	am_shift #(.W(36), .SW(6)) u_cxsh (.a(cx), .amt(step), .left(1'b0), .arith(1'b1), .y(cxsh));
	am_addsub #(.W(36)) u_cx (.a(cx), .b(cysh), .sub(!z[40]), .s(cx_n), .co(carry_unused[19]));
	am_addsub #(.W(36)) u_cy (.a(cy), .b(cxsh), .sub(z[40]), .s(cy_n), .co(carry_unused[20]));
	am_addsub #(.W(41)) u_z (.a(z), .b({1'b0, atn}), .sub(!z[40]), .s(z_n), .co(carry_unused[21]));

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			li <= {LW{1'b0}};
			step <= 6'd0;
			ph <= 1'b0;
		end else begin
			case (st)
			IDLE: if (mine) begin
				rx <= x_a;
				rmask <= x_mask[NPHYS-1:0];
				rop <= x_uop[ATG_UOP_OP +: 3];
				rrd <= x_uop[ATG_UOP_RD +: 7];
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
				rq <= {DW{1'b0}};
				if (first == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= first[LW-1:0];
					st <= LOAD;
				end
			end
			LOAD: begin
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
						ex <= ex_l;
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
						ex <= ex_l;
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
						fr <= ev[29:0];
						ex <= ex_l;
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
						qneg <= tt[39];
						z <= tt[38] ? $signed({2'b0, zq}) : $signed({3'b0, tt[37:0]});
						cx <= $signed({1'b0, XU_CG[34:0]});
						cy <= 36'sd0;
						st <= STEP;
					end
				endcase
			end
			STEP: begin
				step <= step1;
				case (rop)
				ATG_XU_RCP[2:0]: begin
					if (!dtr[34]) begin
						rem <= dtr[33:0];
						root <= {root[28:0], 1'b1};
					end else begin
						rem <= {rem[32:0], 1'b0};
						root <= {root[28:0], 1'b0};
					end
				end
				ATG_XU_RSQ[2:0], ATG_XU_FSQRT[2:0]:
					if (ph) begin
						if (!dtr[34]) begin
							rem <= dtr[33:0];
							n[28:0] <= {n[27:0], 1'b1};
						end else begin
							rem <= {rem[32:0], 1'b0};
							n[28:0] <= {n[27:0], 1'b0};
						end
					end else begin
						n <= {n[57:0], 2'b00};
						rem <= snext;
						root <= {root[28:0], !strl[34]};
					end
				ATG_XU_EXP2[2:0]:
					if (fbit)
						y <= {2'd0, prod[77:38]};
				ATG_XU_LOG2[2:0]: begin
					if (prod[81]) begin
						y <= {1'b0, prod[81:41]};
						fr <= {fr[28:0], 1'b1};
					end else begin
						y <= prod[81:40];
						fr <= {fr[28:0], 1'b0};
					end
				end
				default:
					{cx, cy, z} <= {cx_n, cy_n, z_n};
				endcase
				if (step == nsteps_m1) begin
					step <= 6'd0;
					if (rop == ATG_XU_RSQ[2:0] && !ph) begin
						/* 2^57 / t: t = the root (30 bits). */
						ph <= 1'b1;
						stk <= snext != 34'd0;
						rem <= 34'h010000000;
						n[28:0] <= 29'd0;
					end else
						st <= FIN;
				end
			end
			FIN: begin
				if (!sres)
					res <= fin;
				st <= STORE;
			end
			STORE: begin
				/* The result of FIN is in res: store it, next lane. */
				rq[li*32 +: 32] <= res;
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
		prod, tp[82:40], tps[82:40], y[41], esh[10:4], (NWARPS != 0)};
endmodule

`default_nettype wire
