/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup: RX triangle setup: perspective divide and viewport
 * (VIEWPORT 0-5), cull (CULL), edge-function coefficients in 16.8 fixed
 * point, bounding box ∩ scissor, depth and perspective-barycentric planes.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rx/atg_rx_setup.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Triangles from atg_rx_clip */
	input wire cl_valid,
	output wire cl_ready,
	input wire [699:0] cl_tri,
	input wire cl_last,
	/* To atg_rx_scan */
	output wire sp_valid,
	input wire sp_ready,
	output wire [767:0] sp_tri,
	output wire sp_last,
	output wire busy
);
	/* spec/gpu/rx/atg_rx_setup.md */
	assign cl_ready = 1'd0;
	assign sp_valid = 1'd0;
	assign sp_tri = 768'd0;
	assign sp_last = 1'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, cl_valid, cl_tri, cl_last, sp_ready};
endmodule

`default_nettype wire
