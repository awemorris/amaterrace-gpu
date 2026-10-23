/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan: RX quad traversal: walks the bounding box in 2×2 quads,
 * evaluates the edges for coverage, packs up to 8 quads of one triangle
 * into a 32-lane fragment warp (or sends quads directly to the ROP without
 * an SU), copies the vertices' varyings into the SU's primitive table,
 * frees PT entries.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rx/atg_rx_scan.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_scan #(
	parameter HAS_SU = 1	/* 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR (bitstream 3) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_setup */
	input wire sp_valid,
	output wire sp_ready,
	input wire [767:0] sp_tri,
	input wire sp_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	output wire pt_busy,
	output wire pt_free,
	output wire [7:0] pt_free_idx,
	/* Fragment warps to the SU (atg_su fl_*) */
	output wire fl_req,
	input wire fl_gnt,
	output wire fl_we,
	output wire [5:0] fl_reg,
	output wire [4:0] fl_lane,
	output wire [31:0] fl_data,
	output wire fl_pw_we,
	output wire [11:0] fl_pw_addr,
	output wire [31:0] fl_pw_data,
	output wire fl_go,
	output wire [31:0] fl_mask,
	output wire [63:0] fl_info,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	output wire dx_valid,
	input wire dx_ready,
	output wire [15:0] dx_seq,
	output wire [31:0] dx_xy,
	output wire [3:0] dx_mask,
	output wire [127:0] dx_depth,
	output wire dx_last,
	/* Sequence numbers (atg_rx_order) */
	output wire sq_req,
	input wire [15:0] sq_seq,
	output wire busy
);
	/* spec/gpu/rx/atg_rx_scan.md */
	assign sp_ready = 1'd0;
	assign pt_rd = 1'd0;
	assign pt_idx = 8'd0;
	assign pt_word = 6'd0;
	assign pt_busy = 1'd0;
	assign pt_free = 1'd0;
	assign pt_free_idx = 8'd0;
	assign fl_req = 1'd0;
	assign fl_we = 1'd0;
	assign fl_reg = 6'd0;
	assign fl_lane = 5'd0;
	assign fl_data = 32'd0;
	assign fl_pw_we = 1'd0;
	assign fl_pw_addr = 12'd0;
	assign fl_pw_data = 32'd0;
	assign fl_go = 1'd0;
	assign fl_mask = 32'd0;
	assign fl_info = 64'd0;
	assign dx_valid = 1'd0;
	assign dx_seq = 16'd0;
	assign dx_xy = 32'd0;
	assign dx_mask = 4'd0;
	assign dx_depth = 128'd0;
	assign dx_last = 1'd0;
	assign sq_req = 1'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, sp_valid, sp_tri, sp_last, pt_rdata, fl_gnt,
		dx_ready, sq_seq, (HAS_SU != 0)};
endmodule

`default_nettype wire
