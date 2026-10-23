/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_asm: VF warp and primitive assembly: packs vertices into 32-lane
 * vertex warps (one SU slot and 32 PT entries each), starts the warps, and
 * builds the primitive list (points, lines, strips, fans, triangles,
 * restart) as PT entries for the RX, with last-use flags.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/vf/atg_vf_asm.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_asm (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Index stream (atg_vf_index → atg_vf_asm) */
	input wire iv_valid,
	output wire iv_ready,
	input wire [31:0] iv_index,
	input wire [31:0] iv_inst,
	input wire iv_restart,
	input wire iv_last,
	/* Vertices of a warp (atg_vf_asm → atg_vf_fetch) */
	output wire vb_valid,
	input wire vb_ready,
	output wire [31:0] vb_index,
	output wire [31:0] vb_inst,
	output wire [4:0] vb_lane,
	output wire vb_last,
	input wire conv_done,
	/* Vertex warps to the SU (atg_su vl_*) */
	output wire vl_req,
	input wire vl_gnt,
	input wire [7:0] vl_ptbase,
	output wire vl_go,
	output wire [31:0] vl_mask,
	/* Primitives to the RX */
	output wire prim_valid,
	input wire prim_ready,
	output wire [23:0] prim_vtx,
	output wire [2:0] prim_free,
	output wire prim_last,
	output wire busy
);
	/* spec/gpu/vf/atg_vf_asm.md */
	assign iv_ready = 1'd0;
	assign vb_valid = 1'd0;
	assign vb_index = 32'd0;
	assign vb_inst = 32'd0;
	assign vb_lane = 5'd0;
	assign vb_last = 1'd0;
	assign vl_req = 1'd0;
	assign vl_go = 1'd0;
	assign vl_mask = 32'd0;
	assign prim_valid = 1'd0;
	assign prim_vtx = 24'd0;
	assign prim_free = 3'd0;
	assign prim_last = 1'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, iv_valid, iv_index, iv_inst, iv_restart, iv_last,
		vb_ready, conv_done, vl_gnt, vl_ptbase, prim_ready};
endmodule

`default_nettype wire
