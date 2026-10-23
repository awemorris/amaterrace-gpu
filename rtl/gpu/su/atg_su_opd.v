/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_opd: Operand collection: for each lane group of an issued
 * instruction, reads the GPRs, the constant operands c0-c31, the special
 * operands (design §3.2) and rq, applies the float modifiers, computes the
 * lane masks, and drives the execution bus x_* to the units.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_opd.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_opd #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_sb */
	input wire i_valid,
	output wire i_ready,
	input wire [WARP_W-1:0] i_warp,
	input wire [15:0] i_pc,
	input wire [UOP_W-1:0] i_uop,
	input wire [SBE_W:0] i_sbe,
	/* Register file (atg_su_rf read port) */
	output wire r_en,
	output wire [WARP_W-1:0] r_warp,
	output wire [GRP_W-1:0] r_grp,
	output wire [17:0] r_regs,
	input wire [3*NPHYS*32-1:0] r_data,
	/* Constant bank (atg_su_cbank) */
	output wire cr_en,
	output wire [14:0] cr_idx,
	input wire [95:0] cr_data,
	/* Warp state */
	output wire [WARP_W-1:0] q_warp,
	input wire [159:0] q_info,
	input wire [31:0] q_exec,
	input wire [31:0] q_killed,
	/* rq (atg_su_rq) */
	output wire rq_pop,
	input wire [NPHYS*32-1:0] rq_data,
	/* Execution bus (to every unit) */
	output wire x_valid,
	output wire [WARP_W-1:0] x_warp,
	output wire [GRP_W-1:0] x_grp,
	output wire x_last,
	output wire [SBE_W:0] x_sbe,
	output wire [15:0] x_pc,
	output wire [UOP_W-1:0] x_uop,
	output wire [NPHYS*32-1:0] x_a,
	output wire [NPHYS*32-1:0] x_b,
	output wire [NPHYS*32-1:0] x_c,
	output wire [2*NPHYS-1:0] x_mask,
	output wire [31:0] x_info,
	input wire [15:0] unit_ready
);
	/* spec/gpu/su/atg_su_opd.md */
	assign i_ready = 1'd0;
	assign r_en = 1'd0;
	assign r_warp = {WARP_W{1'b0}};
	assign r_grp = {GRP_W{1'b0}};
	assign r_regs = 18'd0;
	assign cr_en = 1'd0;
	assign cr_idx = 15'd0;
	assign q_warp = {WARP_W{1'b0}};
	assign rq_pop = 1'd0;
	assign x_valid = 1'd0;
	assign x_warp = {WARP_W{1'b0}};
	assign x_grp = {GRP_W{1'b0}};
	assign x_last = 1'd0;
	assign x_sbe = {((SBE_W)+1){1'b0}};
	assign x_pc = 16'd0;
	assign x_uop = {UOP_W{1'b0}};
	assign x_a = {(NPHYS*32){1'b0}};
	assign x_b = {(NPHYS*32){1'b0}};
	assign x_c = {(NPHYS*32){1'b0}};
	assign x_mask = {(2*NPHYS){1'b0}};
	assign x_info = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, i_valid, i_warp, i_pc, i_uop, i_sbe, r_data, cr_data, q_info, q_exec,
		q_killed, rq_data, unit_ready};
endmodule

`default_nettype wire
