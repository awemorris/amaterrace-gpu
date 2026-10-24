/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lane: Cross-lane operations: qd (quad differences and swaps for
 * derivatives, design §3.4.1) always; shfl/vote/ballot with SUBGROUP
 * (staging RAM). Short results.
 *
 * qd is implemented (WS288 p008); shfl/vote/ballot (SUBGROUP) are not
 * yet: they give no result.  The behaviour: spec/gpu/su/atg_su_lane.md
 * (§10 Status).
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
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_LANE &&
		x_uop[ATG_UOP_OP +: 8] == ATG_LANE_QD && x_uop[ATG_UOP_WRD];
	wire [2:0] qs = x_uop[ATG_UOP_SUB +: 3];

	/* Quads inside the group: lane l's partners l^1, l^2, l^3 and l&~3. */
	reg [DW-1:0] y;
	integer l;
	always @(*) begin
		for (l = 0; l < NPHYS; l = l + 1) begin
			case (qs)
			3'd0: y[l*32 +: 32] = atg_su_fadd(x_a[(l | 1)*32 +: 32],
				x_a[(l & ~1)*32 +: 32] ^ 32'h80000000);
			3'd1: y[l*32 +: 32] = atg_su_fadd(x_a[(l | 2)*32 +: 32],
				x_a[(l & ~2)*32 +: 32] ^ 32'h80000000);
			3'd2: y[l*32 +: 32] = x_a[(l ^ 1)*32 +: 32];
			3'd3: y[l*32 +: 32] = x_a[(l ^ 2)*32 +: 32];
			3'd4: y[l*32 +: 32] = x_a[(l ^ 3)*32 +: 32];
			default: y[l*32 +: 32] = x_a[(l & ~3)*32 +: 32];
			endcase
		end
	end

	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {mine, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], x_mask[NPHYS-1:0], y};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
		end
	end

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];
	/* shfl/vote/ballot (SUBGROUP) are not implemented yet (p009): no result. */
	assign x_ready = 1'b1;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_b, x_c, x_mask[2*NPHYS-1:NPHYS], x_info,
		x_uop, (NWARPS != 0), (SUBGROUP != 0)};
endmodule

`default_nettype wire
