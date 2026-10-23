/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_fetch: VF attribute fetch: for each vertex of a warp and each
 * enabled attribute k (ATTR[k]_BASE/DESC), computes the address
 * (per-vertex or per-instance with divisor) and reads the attribute's
 * bytes through the AMB.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/vf/atg_vf_fetch.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_fetch #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Vertices of a warp (atg_vf_asm → atg_vf_fetch) */
	input wire vb_valid,
	output wire vb_ready,
	input wire [31:0] vb_index,
	input wire [31:0] vb_inst,
	input wire [4:0] vb_lane,
	input wire vb_last,
	/* Attribute data (atg_vf_fetch → atg_vf_conv) */
	output wire af_valid,
	input wire af_ready,
	output wire [3:0] af_attr,
	output wire [4:0] af_lane,
	output wire [127:0] af_raw,
	output wire af_last,
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
	/* spec/gpu/vf/atg_vf_fetch.md */
	assign vb_ready = 1'd0;
	assign af_valid = 1'd0;
	assign af_attr = 4'd0;
	assign af_lane = 5'd0;
	assign af_raw = 128'd0;
	assign af_last = 1'd0;
	assign busy = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, vb_valid, vb_index, vb_inst, vb_lane, vb_last,
		af_ready, req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
