/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lane: Cross-lane operations: qd (quad differences and swaps for
 * derivatives, design §3.4.1) always; shfl/vote/ballot with SUBGROUP
 * (staging registers, design §3.4.2).  Short results, SHORT_LAT cycles
 * after the group's slot on the bus.
 *
 * qd works inside a lane group (NPHYS >= 8), one group per cycle.
 * shfl/vote/ballot need all 32 lanes: the groups before the last are
 * staged as they pass (x_ready 1); the last group is staged in its first
 * cycle on the bus and then held there (x_ready 0) for G = 32/NPHYS more
 * cycles, in which the results of groups 0..G-1 enter the result pipeline,
 * one per cycle; x_ready is 1 in the last of them.  So group g's result
 * leaves SHORT_LAT cycles after cycle x_end - (G-1) + g, the same as for
 * an instruction whose groups pass one per cycle: atg_su_sb's short
 * interlock and atg_su_wb's one-short-result-per-cycle rule hold, since
 * the bus carries nothing else in those cycles.  2 × G bus cycles.
 * The behaviour: spec/gpu/su/atg_su_lane.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lane #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot present */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
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
	/* Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid) */
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes
);
`include "atg_su_uop.vh"
`include "atg_su_fp.vh"

	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	wire [3:0] unit = x_uop[ATG_UOP_UNIT +: 4];
	wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire [4:0] sub = x_uop[ATG_UOP_SUB +: 5];
	wire wrd = x_uop[ATG_UOP_WRD];
	wire mine = x_valid && unit == ATG_UNIT_LANE && op == ATG_LANE_QD && wrd;
	/* A subgroup instruction on the bus (they are ISA faults without SUBGROUP). */
	wire sg = SUBGROUP != 0 && x_valid && unit == ATG_UNIT_LANE &&
		(op == ATG_LANE_SHFL || op == ATG_LANE_VOTE || op == ATG_LANE_BALLOT);

	/* qd: quads inside the group: lane l's partners l^1, l^2, l^3 and l&~3.
	 * The differences x[l|1] - x[l&~1] (sub 0) and x[l|2] - x[l&~2] (sub 1)
	 * take two values per quad, so a quad has two adders: A for lanes 0
	 * and 1 (sub 0) or 0 and 2 (sub 1), B for the other two. */
	reg [DW-1:0] y;
	reg [31:0] qa, qb;
	integer l, q;
	always @(*) begin
		for (q = 0; q < NPHYS / 4; q = q + 1) begin
			qa = atg_su_fadd(sub[0] ? x_a[(4*q + 2)*32 +: 32] : x_a[(4*q + 1)*32 +: 32],
				x_a[(4*q)*32 +: 32] ^ 32'h80000000);
			qb = atg_su_fadd(x_a[(4*q + 3)*32 +: 32],
				(sub[0] ? x_a[(4*q + 1)*32 +: 32] : x_a[(4*q + 2)*32 +: 32]) ^ 32'h80000000);
			for (l = 4*q; l < 4*q + 4; l = l + 1) begin
				case (sub[2:0])
				3'd0: y[l*32 +: 32] = l[1] ? qb : qa;
				3'd1: y[l*32 +: 32] = l[0] ? qb : qa;
				3'd2: y[l*32 +: 32] = x_a[(l ^ 1)*32 +: 32];
				3'd3: y[l*32 +: 32] = x_a[(l ^ 2)*32 +: 32];
				3'd4: y[l*32 +: 32] = x_a[(l ^ 3)*32 +: 32];
				default: y[l*32 +: 32] = x_a[(l & ~3)*32 +: 32];
				endcase
			end
		end
	end

	/* The state machine of the subgroup instructions: IDLE (groups are
	 * staged as they pass; the last one moves to EMIT) and EMIT (group
	 * e_cnt's result enters the pipeline; x_ready in the last). */
	localparam S_IDLE = 1'b0;
	localparam S_EMIT = 1'b1;
	reg st;
	reg [GRP_W-1:0] e_cnt;
	wire e_last = {{(32-GRP_W){1'b0}}, e_cnt} == G - 1;
	wire emit = st == S_EMIT;
	wire stage = sg && st == S_IDLE;
	assign x_ready = !(sg && x_last) || (emit && e_last);

	/* Staging, per warp lane: rs1, EXEC, and the shfl source lane (s_ok: it
	 * exists, 0..31). */
	reg [32*32-1:0] s_d;
	reg [31:0] s_ex;
	reg [31:0] s_ok;
	reg [32*5-1:0] s_src;

	/* The source lane of shfl for lane ln of the group on the bus. */
	reg [NPHYS-1:0] c_ok;
	reg [NPHYS*5-1:0] c_src;
	reg [4:0] ln;
	reg [31:0] bv;
	reg [5:0] sum;
	always @(*) begin
		for (l = 0; l < NPHYS; l = l + 1) begin
			/* verilator lint_off WIDTHTRUNC */
			ln = x_grp * NPHYS + l;
			/* verilator lint_on WIDTHTRUNC */
			bv = x_b[l*32 +: 32];
			sum = {1'b0, ln} + {1'b0, bv[4:0]};
			c_ok[l] = bv[31:5] == 27'd0;
			case (sub[2:0])
			3'd0: c_src[l*5 +: 5] = bv[4:0];
			3'd2: begin
				c_src[l*5 +: 5] = ln - bv[4:0];
				c_ok[l] = c_ok[l] && bv[4:0] <= ln;
			end
			3'd3: begin
				c_src[l*5 +: 5] = sum[4:0];
				c_ok[l] = c_ok[l] && !sum[5];
			end
			3'd4: begin	/* rot: (l + rs2) mod 32, always a lane */
				c_src[l*5 +: 5] = sum[4:0];
				c_ok[l] = 1'b1;
			end
			default: c_src[l*5 +: 5] = ln ^ bv[4:0];	/* 1 xor */
			endcase
		end
	end

	/* Results of group e_cnt.  shfl: the source lane's rs1 when the source
	 * exists and is in EXEC, else the lane's own rs1.  ballot: the EXEC
	 * lanes whose rs1 is not 0; vote: any/all of them as a Boolean. */
	reg [31:0] bal;
	reg [DW-1:0] z;
	reg [4:0] el, es;
	always @(*) begin
		for (l = 0; l < 32; l = l + 1)
			bal[l] = s_ex[l] && s_d[l*32 +: 32] != 32'd0;
		for (l = 0; l < NPHYS; l = l + 1) begin
			/* verilator lint_off WIDTHTRUNC */
			el = e_cnt * NPHYS + l;
			/* verilator lint_on WIDTHTRUNC */
			es = s_src[el*5 +: 5];
			if (op == ATG_LANE_BALLOT)
				z[l*32 +: 32] = bal;
			else if (op == ATG_LANE_VOTE)
				z[l*32 +: 32] = {32{sub[0] ? (bal == s_ex) : (bal != 32'd0)}};
			else
				z[l*32 +: 32] = s_ok[el] && s_ex[es] ? s_d[es*32 +: 32] : s_d[el*32 +: 32];
		end
	end
	/* shfl writes the EXEC lanes; vote and ballot every lane. */
	wire [31:0] ex_g = s_ex >> ({{(32-GRP_W){1'b0}}, e_cnt} * NPHYS);
	wire [NPHYS-1:0] z_lanes = op == ATG_LANE_SHFL ? ex_g[NPHYS-1:0] : {NPHYS{1'b1}};

	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			e_cnt <= {GRP_W{1'b0}};
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			if (emit)
				pipe[0] <= {wrd, x_warp, e_cnt, x_uop[ATG_UOP_RD +: 7], z_lanes, z};
			else
				pipe[0] <= {mine, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7],
					x_mask[NPHYS-1:0], y};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
			if (stage && x_last) begin
				st <= S_EMIT;
				e_cnt <= {GRP_W{1'b0}};
			end else if (emit) begin
				if (e_last)
					st <= S_IDLE;
				else
					e_cnt <= e_cnt + 1'b1;
			end
		end
	end

	/* The staging registers (no reset: written before they are read). */
	always @(posedge clk) begin
		if (stage)
			for (k = 0; k < NPHYS; k = k + 1) begin
				/* verilator lint_off WIDTHTRUNC */
				s_d[(x_grp * NPHYS + k)*32 +: 32] <= x_a[k*32 +: 32];
				s_ex[x_grp * NPHYS + k] <= x_mask[k];
				s_ok[x_grp * NPHYS + k] <= c_ok[k];
				s_src[(x_grp * NPHYS + k)*5 +: 5] <= c_src[k*5 +: 5];
				/* verilator lint_on WIDTHTRUNC */
			end
	end

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];

	wire unused_ok = &{1'b0, x_sbe, x_pc, x_c, x_mask[2*NPHYS-1:NPHYS], x_info,
		x_uop, sub[4:3], ex_g, (NWARPS != 0)};
endmodule

`default_nettype wire
