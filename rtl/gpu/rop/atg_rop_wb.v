/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wb: ROP write-back: a small write-combining buffer of
 * render-target lines; reads the destination line when blending, sends
 * pixels through atg_rop_blend, writes lines back; drains when idle.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rop/atg_rop_wb.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_wb #(
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
	/* From atg_rop_ds */
	input wire d_valid,
	output wire d_ready,
	input wire [31:0] d_xy,
	input wire [3:0] d_mask,
	input wire [511:0] d_color,
	/* atg_rop_blend */
	output wire b_valid,
	output wire [511:0] b_src,
	output wire [127:0] b_dst,
	output wire [3:0] b_mask,
	input wire b_rvalid,
	input wire [127:0] b_pix,
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
	/* spec/gpu/rop/atg_rop_wb.md */
	assign d_ready = 1'd0;
	assign b_valid = 1'd0;
	assign b_src = 512'd0;
	assign b_dst = 128'd0;
	assign b_mask = 4'd0;
	assign busy = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, d_valid, d_xy, d_mask, d_color, b_rvalid, b_pix,
		req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
