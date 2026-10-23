/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu: The texture unit (design §2.3, §3.7): addressing, cache, filter;
 * one MC client.
 *
 * Wiring of its children (WS288 p023); see spec/gpu/tu/atg_tu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu #(
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
	input wire inv,
	output wire busy,
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [1:0] tx_op,
	input wire [3:0] tx_slot,
	input wire [3:0] tx_mask,
	input wire [383:0] tx_coord,
	input wire [15:0] tx_tag,
	input wire tx_last,
	/* Return */
	output wire tr_valid,
	input wire tr_ready,
	output wire [15:0] tr_tag,
	output wire [511:0] tr_data,
	output wire tr_last,
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
	wire ta_valid, ta_ready, ta_last;
	wire [511:0] ta_addr;
	wire [63:0] ta_wts;
	wire [15:0] ta_tag;
	wire [3:0] ta_mask;
	wire [7:0] ta_ctl;
	wire [127:0] ta_value;
	wire tc_valid, tc_ready, tc_last;
	wire [511:0] tc_texels;
	wire [63:0] tc_wts;
	wire [15:0] tc_tag;
	wire [3:0] tc_mask;
	wire [7:0] tc_ctl;
	wire [127:0] tc_value;

	atg_tu_addr addr (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_tag(tx_tag), .tx_last(tx_last),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_wts(ta_wts),
		.ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value), .ta_last(ta_last)
	);

	atg_tu_cache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) cache (
		.clk(clk), .rst_n(rst_n), .inv(inv),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_wts(ta_wts),
		.ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value), .ta_last(ta_last),
		.tc_valid(tc_valid), .tc_ready(tc_ready), .tc_texels(tc_texels), .tc_wts(tc_wts),
		.tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl), .tc_value(tc_value), .tc_last(tc_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	atg_tu_filter filter (
		.clk(clk), .rst_n(rst_n),
		.tc_valid(tc_valid), .tc_ready(tc_ready), .tc_texels(tc_texels), .tc_wts(tc_wts),
		.tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl), .tc_value(tc_value), .tc_last(tc_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
		.tr_last(tr_last)
	);

	assign busy = ta_valid || tc_valid || tx_valid;
endmodule

`default_nettype wire
