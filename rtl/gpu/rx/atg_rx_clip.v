/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_clip: RX primitive input and near-plane clipping: reads the three
 * vertices' clip-space positions from the PT (or DRAW_RAW's screen-space
 * vertices from STATE 0x1E0-0x1E8), clips against the near plane (one
 * triangle → 0, 1 or 2), and passes triangles with weights relative to the
 * original vertices.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rx/atg_rx_clip.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_clip (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire raw_kick,
	/* Primitives to the RX */
	input wire prim_valid,
	output wire prim_ready,
	input wire [23:0] prim_vtx,
	input wire [2:0] prim_free,
	input wire prim_last,
	/* PT read (shared with atg_rx_scan in atg_rx: scan has priority) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [5:0] pt_word,
	input wire [31:0] pt_rdata,
	input wire pt_busy,
	/* Triangles to atg_rx_setup */
	output wire cl_valid,
	input wire cl_ready,
	output wire [699:0] cl_tri,
	output wire cl_last,
	output wire busy
);
	/* spec/gpu/rx/atg_rx_clip.md */
	assign prim_ready = 1'd0;
	assign pt_rd = 1'd0;
	assign pt_idx = 8'd0;
	assign pt_word = 6'd0;
	assign cl_valid = 1'd0;
	assign cl_tri = 700'd0;
	assign cl_last = 1'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, raw_kick, prim_valid, prim_vtx, prim_free,
		prim_last, pt_rdata, pt_busy, cl_ready};
endmodule

`default_nettype wire
