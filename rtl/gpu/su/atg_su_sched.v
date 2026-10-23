/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_sched: The SU's warp scheduler: warp slots and their PCs, slot
 * allocation for vertex warps (VF), fragment warps (RX) and compute
 * workgroups (DISPATCH), round-robin selection of a ready warp for fetch,
 * and the warp-info word for special operands.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_sched.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_sched #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter NSU = 1,	/* Number of SUs (compute workgroups are shared out: this SU takes wg_id % NSU == SU_INDEX) */
	parameter SU_INDEX = 0,	/* This SU's number */
	parameter FRAG_RESERVE = 1	/* Slots kept for fragment warps (design §3.8; KC705 2) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire cs_kick,
	/* Vertex warp allocation (VF, via atg_su ports vl_*) */
	input wire vl_req,
	output wire vl_gnt,
	output wire [WARP_W-1:0] vl_slot,
	input wire vl_go,
	input wire [31:0] vl_mask,
	/* Fragment warp allocation (RX, via atg_su ports fl_*) */
	input wire fl_req,
	output wire fl_gnt,
	output wire [WARP_W-1:0] fl_slot,
	input wire fl_go,
	input wire [31:0] fl_mask,
	input wire [63:0] fl_info,
	/* Fetch (to atg_su_fetch) */
	output wire f_valid,
	input wire f_ready,
	output wire [WARP_W-1:0] f_warp,
	output wire [15:0] f_pc,
	output wire [31:0] f_addr,
	/* Feedback (from atg_su_sb and atg_su_exec) */
	input wire fb_valid,
	input wire [WARP_W-1:0] fb_warp,
	input wire [1:0] fb_kind,
	input wire [NWARPS-1:0] wake,
	input wire wc_valid,
	input wire [WARP_W-1:0] wc_warp,
	input wire [1:0] wc_op,
	input wire [15:0] wc_pc,
	/* Warp information */
	input wire [WARP_W-1:0] q_warp,
	output wire [159:0] q_info,
	output wire init_valid,
	output wire [WARP_W-1:0] init_warp,
	output wire [31:0] init_mask,
	input wire pt_ok,
	input wire xr_valid,
	input wire [WARP_W-1:0] xr_warp,
	output wire busy
);
	/* spec/gpu/su/atg_su_sched.md */
	assign vl_gnt = 1'd0;
	assign vl_slot = {WARP_W{1'b0}};
	assign fl_gnt = 1'd0;
	assign fl_slot = {WARP_W{1'b0}};
	assign f_valid = 1'd0;
	assign f_warp = {WARP_W{1'b0}};
	assign f_pc = 16'd0;
	assign f_addr = 32'd0;
	assign q_info = 160'd0;
	assign init_valid = 1'd0;
	assign init_warp = {WARP_W{1'b0}};
	assign init_mask = 32'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, cs_kick, vl_req, vl_go, vl_mask, fl_req, fl_go,
		fl_mask, fl_info, f_ready, fb_valid, fb_warp, fb_kind, wake, wc_valid, wc_warp, wc_op,
		wc_pc, q_warp, pt_ok, xr_valid, xr_warp, (NPHYS != 0), (NSU != 0), (SU_INDEX != 0),
		(FRAG_RESERVE != 0)};
endmodule

`default_nettype wire
