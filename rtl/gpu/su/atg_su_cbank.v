/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_cbank: The constant bank: 256 words loaded by LOAD_CONST (DMA
 * from memory), read as c0-c31 operands (atg_su_opd's port) and by lwc
 * (long beats).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_cbank.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_cbank #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter CONST_WORDS = 256	/* Size in words */
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
	/* c-operand read port (atg_su_opd) */
	input wire cr_en,
	input wire [14:0] cr_idx,
	output wire [95:0] cr_data,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire lc_kick,
	input wire inv,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	/* spec/gpu/su/atg_su_cbank.md */
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
	assign cr_data = 96'd0;
	assign busy = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, x_valid, x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask,
		x_info, l_ready, cr_en, cr_idx, st_we, st_idx, st_wdata, lc_kick, inv, req_ready,
		rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error, (NWARPS != 0), (CONST_WORDS != 0)};
endmodule

`default_nettype wire
