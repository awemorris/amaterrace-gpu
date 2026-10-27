/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_div: The SU's shared integer divider: div, divu, rem, remu
 * (RISC-V semantics), lane by lane, results as long beats.
 *
 * Takes one lane group at a time (x_ready is 1 only in IDLE), divides
 * its EXEC lanes one after the other with a 32-step restoring divider (34
 * cycles per lane: load, 32 steps, sign fix), then returns the group as
 * one long beat (l_wr 1, l_last = the group's x_last, class x).  A group
 * without EXEC lanes returns at once.  Division by zero gives all ones
 * (div/divu) and the dividend (rem/remu); INT_MIN / -1 gives INT_MIN and
 * remainder 0 (RISC-V).  The reference is tools/gsi1fp.py div().
 *
 * States: IDLE →(group)→ DIV (lane loop) → RET →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_div #(
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

	localparam DW = NPHYS * 32;
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [1:0] IDLE = 2'd0, DIV = 2'd1, RET = 2'd2;

	reg [1:0] st;
	reg [DW-1:0] ra, rb, rq;
	reg [NPHYS-1:0] rm;
	reg [1:0] rop;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	reg [LW-1:0] li;
	reg [5:0] step;
	/* The divider of the current lane. */
	reg [31:0] dn, dd, q;
	reg [32:0] r;
	reg neg_q, neg_r;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_DIV;
	assign x_ready = st == IDLE;

	/* The next lane in the mask at or after lane n (NPHYS when none). */
	function [LW:0] next_lane;
		input [NPHYS-1:0] m;
		input [LW:0] n;
		integer i;
		begin
			next_lane = NPHYS[LW:0];
			for (i = NPHYS - 1; i >= 0; i = i - 1)
				if (m[i] && i >= n)
					next_lane = i[LW:0];
		end
	endfunction

	wire [LW:0] first = next_lane(x_mask[NPHYS-1:0], {(LW+1){1'b0}});
	wire [LW:0] li_1;
	wire l1_co_unused;
	am_add #(.W(LW + 1)) u_li_1 (.a({1'b0, li}), .b({(LW + 1){1'b0}}), .ci(1'b1), .s(li_1),
		.co(l1_co_unused));
	wire [LW:0] after = next_lane(rm, li_1);
	wire [31:0] la = ra[li*32 +: 32];
	wire [31:0] lb = rb[li*32 +: 32];
	wire sgn = !rop[0];	/* div, rem */

	/*
	 * One 33-bit subtractor, by step: 0 - a at the load (step 0), the
	 * trial r:dn[31] - d of the steps 1-32, 0 - the result at the end; and
	 * 0 - b at the load.
	 */
	wire s_load = step == 6'd0;
	wire s_end = step > 6'd32;
	wire [32:0] d0;
	wire [31:0] neg_b;
	wire [5:0] step_next;
	wire d0_bo_unused, nb_bo_unused, sn_co_unused;
	am_sub #(.W(33)) u_d0 (.a(s_load || s_end ? 33'd0 : {r[31:0], dn[31]}),
		.b(s_load ? {1'b0, la} : s_end ? {1'b0, rop[1] ? r[31:0] : q} : {1'b0, dd}), .bi(1'b0),
		.d(d0), .bo(d0_bo_unused));
	am_sub #(.W(32)) u_neg_b (.a(32'd0), .b(lb), .bi(1'b0), .d(neg_b), .bo(nb_bo_unused));
	am_add #(.W(6)) u_step (.a(step), .b(6'd0), .ci(1'b1), .s(step_next), .co(sn_co_unused));
	wire [32:0] trial = d0;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			li <= {LW{1'b0}};
			step <= 6'd0;
		end else begin
			case (st)
			IDLE: if (mine) begin
				ra <= x_a;
				rb <= x_b;
				rm <= x_mask[NPHYS-1:0];
				rop <= x_uop[ATG_UOP_OP +: 2];
				rrd <= x_uop[ATG_UOP_RD +: 7];
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
				rq <= {DW{1'b0}};
				step <= 6'd0;
				if (first == NPHYS[LW:0])
					st <= RET;
				else begin
					li <= first[LW-1:0];
					st <= DIV;
				end
			end
			DIV: begin
				if (step == 6'd0) begin
					/* Load the lane: magnitudes and the signs of the results. */
					dn <= sgn && la[31] ? d0[31:0] : la;
					dd <= sgn && lb[31] ? neg_b : lb;
					neg_q <= sgn && (la[31] ^ lb[31]);
					neg_r <= sgn && la[31];
					r <= 33'd0;
					q <= 32'd0;
					step <= 6'd1;
				end else if (step <= 6'd32) begin
					if (!trial[32]) begin
						r <= trial;
						q <= {q[30:0], 1'b1};
					end else begin
						r <= {r[31:0], dn[31]};
						q <= {q[30:0], 1'b0};
					end
					dn <= {dn[30:0], 1'b0};
					step <= step_next;
				end else begin
					if (lb == 32'd0)
						rq[li*32 +: 32] <= rop[1] ? la : 32'hFFFFFFFF;
					else if (rop[1])
						rq[li*32 +: 32] <= neg_r ? d0[31:0] : r[31:0];
					else
						rq[li*32 +: 32] <= neg_q ? d0[31:0] : q;
					step <= 6'd0;
					if (after == NPHYS[LW:0])
						st <= RET;
					else
						li <= after[LW-1:0];
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
	assign l_lanes = rm;
	assign l_wr = 1'b1;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_X;

	wire unused_ok = &{1'b0, x_pc, x_c, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop, r[32],
		(NWARPS != 0)};
endmodule

`default_nettype wire
