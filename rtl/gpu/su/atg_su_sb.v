/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sb: The issue stage with the per-warp scoreboard (design §3.1.1):
 * checks the operand ranges of an instruction against the warp's
 * outstanding long operations, the wait counters, rq and write-back
 * stalls; issues to atg_su_opd with an entry, or replays.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_sb.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sb #(
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter SB_ENTRIES = 4,	/* Scoreboard entries per warp (ZYBO 4, KC705 8) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_dec */
	input wire u_valid,
	output wire u_ready,
	input wire [WARP_W-1:0] u_warp,
	input wire [15:0] u_pc,
	input wire [UOP_W-1:0] u_uop,
	/* To atg_su_opd */
	output wire i_valid,
	input wire i_ready,
	output wire [WARP_W-1:0] i_warp,
	output wire [15:0] i_pc,
	output wire [UOP_W-1:0] i_uop,
	output wire [SBE_W:0] i_sbe,
	/* To atg_su_sched */
	output wire fb_valid,
	output wire [WARP_W-1:0] fb_warp,
	output wire [1:0] fb_kind,
	output wire [NWARPS-1:0] wake,
	/* Releases (from atg_su_wb) */
	input wire rel_valid,
	input wire [WARP_W-1:0] rel_warp,
	input wire [SBE_W:0] rel_sbe,
	input wire [2:0] rel_cls,
	input wire wb_stall,
	input wire rq_empty,
	input wire rq_full,
	output wire busy,
	output wire fault,
	output wire [15:0] fault_pc
);
	/* spec/gpu/su/atg_su_sb.md */
	assign u_ready = 1'd0;
	assign i_valid = 1'd0;
	assign i_warp = {WARP_W{1'b0}};
	assign i_pc = 16'd0;
	assign i_uop = {UOP_W{1'b0}};
	assign i_sbe = {((SBE_W)+1){1'b0}};
	assign fb_valid = 1'd0;
	assign fb_warp = {WARP_W{1'b0}};
	assign fb_kind = 2'd0;
	assign wake = {NWARPS{1'b0}};
	assign busy = 1'd0;
	assign fault = 1'd0;
	assign fault_pc = 16'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, u_valid, u_warp, u_pc, u_uop, i_ready, rel_valid, rel_warp, rel_sbe,
		rel_cls, wb_stall, rq_empty, rq_full, (SB_ENTRIES != 0)};
endmodule

`default_nettype wire
