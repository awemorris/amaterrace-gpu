/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tex: The SU side of texturing: forms TU requests from
 * texl/texb/texf/texsz (per quad, with the derivative lanes), and returns
 * the TU's texels as long beats (rd..rd+3).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_tex.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_tex #(
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
	output wire [2:0] l_cls,
	/* To the TU (atg_tu) */
	output wire tx_valid,
	input wire tx_ready,
	output wire [1:0] tx_op,
	output wire [3:0] tx_slot,
	output wire [3:0] tx_mask,
	output wire [383:0] tx_coord,
	output wire [15:0] tx_tag,
	output wire tx_last,
	input wire tr_valid,
	output wire tr_ready,
	input wire [15:0] tr_tag,
	input wire [511:0] tr_data,
	input wire tr_last
);
	/* spec/gpu/su/atg_su_tex.md */
	assign x_ready = 1'd0;
	assign l_valid = 1'd0;
	assign l_warp = {WARP_W{1'b0}};
	assign l_grp = {GRP_W{1'b0}};
	assign l_rd = 7'd0;
	assign l_data = {(NPHYS*32){1'b0}};
	assign l_lanes = {NPHYS{1'b0}};
	assign l_wr = 1'd0;
	assign l_last = 1'd0;
	assign l_sbe = {((SBE_W)+1){1'b0}};
	assign l_cls = 3'd0;
	assign tx_valid = 1'd0;
	assign tx_op = 2'd0;
	assign tx_slot = 4'd0;
	assign tx_mask = 4'd0;
	assign tx_coord = 384'd0;
	assign tx_tag = 16'd0;
	assign tx_last = 1'd0;
	assign tr_ready = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, x_valid, x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask,
		x_info, l_ready, tx_ready, tr_valid, tr_tag, tr_data, tr_last, (NWARPS != 0)};
endmodule

`default_nettype wire
