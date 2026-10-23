/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp: Exports: vertex positions/varyings into the post-transform
 * buffer (PT) that RX reads, fragment colour/depth into the export buffer
 * that the ROP drains; the PT allocator for vertex warps.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_exp.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter PT_ENTRIES = 64,	/* PT vertices (two warps of 32) */
	parameter VARY_WORDS = 16	/* Varying words per vertex (ZYBO 16, KC705 32) */
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
	/* Export to the ROP (atg_rop) */
	output wire ex_valid,
	input wire ex_ready,
	output wire [15:0] ex_seq,
	output wire [31:0] ex_xy,
	output wire [3:0] ex_mask,
	output wire [511:0] ex_color,
	output wire [127:0] ex_depth,
	output wire ex_last,
	input wire [15:0] ex_next,
	/* PT read port (atg_rx) */
	input wire pt_rd,
	input wire [7:0] pt_idx,
	input wire [5:0] pt_word,
	output wire [31:0] pt_rdata,
	input wire pt_free,
	input wire [7:0] pt_free_idx,
	/* PT allocation */
	output wire pt_ok,
	input wire pt_take,
	output wire [7:0] pt_base,
	output wire xr_valid,
	output wire [WARP_W-1:0] xr_warp,
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp
);
	/* spec/gpu/su/atg_su_exp.md */
	assign x_ready = 1'd0;
	assign ex_valid = 1'd0;
	assign ex_seq = 16'd0;
	assign ex_xy = 32'd0;
	assign ex_mask = 4'd0;
	assign ex_color = 512'd0;
	assign ex_depth = 128'd0;
	assign ex_last = 1'd0;
	assign pt_rdata = 32'd0;
	assign pt_ok = 1'd0;
	assign pt_base = 8'd0;
	assign xr_valid = 1'd0;
	assign xr_warp = {WARP_W{1'b0}};

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, x_valid, x_warp, x_grp, x_last, x_sbe, x_pc, x_uop, x_a, x_b, x_c, x_mask,
		x_info, ex_ready, ex_next, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx, pt_take,
		wc_end, wc_warp, (NWARPS != 0), (PT_ENTRIES != 0), (VARY_WORDS != 0)};
endmodule

`default_nettype wire
