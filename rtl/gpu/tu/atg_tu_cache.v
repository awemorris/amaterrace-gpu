/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache: The texture cache: 4 KiB (KC705; ZYBO has no TU), lines
 * from the AMB, 16 texels per quad looked up (several per cycle by
 * banking), invalidated by INVALIDATE[1] / DRAW.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/tu/atg_tu_cache.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter TC_BYTES = 4096	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* From atg_tu_addr */
	input wire ta_valid,
	output wire ta_ready,
	input wire [511:0] ta_addr,
	input wire [63:0] ta_wts,
	input wire [15:0] ta_tag,
	input wire [3:0] ta_mask,
	input wire [7:0] ta_ctl,
	input wire [127:0] ta_value,
	input wire ta_last,
	/* To atg_tu_filter */
	output wire tc_valid,
	input wire tc_ready,
	output wire [511:0] tc_texels,
	output wire [63:0] tc_wts,
	output wire [15:0] tc_tag,
	output wire [3:0] tc_mask,
	output wire [7:0] tc_ctl,
	output wire [127:0] tc_value,
	output wire tc_last,
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
	/* spec/gpu/tu/atg_tu_cache.md */
	assign ta_ready = 1'd0;
	assign tc_valid = 1'd0;
	assign tc_texels = 512'd0;
	assign tc_wts = 64'd0;
	assign tc_tag = 16'd0;
	assign tc_mask = 4'd0;
	assign tc_ctl = 8'd0;
	assign tc_value = 128'd0;
	assign tc_last = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, inv, ta_valid, ta_addr, ta_wts, ta_tag, ta_mask, ta_ctl, ta_value, ta_last,
		tc_ready, req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error,
		(TC_BYTES != 0)};
endmodule

`default_nettype wire
