/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop: The ROP / buffer writer (design §2.3, §3.8): primitive-order
 * retirement, depth/stencil, blend, write-back; one MC client (depth and
 * colour behind am_amb_mux).
 *
 * Wiring of its children; see spec/gpu/rop/atg_rop.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter STENCIL = 0	/* ROP_STENCIL */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	output wire busy,
	/* Fragment output of SU 0 (atg_su ex_*) */
	input wire ex_valid,
	output wire ex_ready,
	input wire [15:0] ex_seq,
	input wire [31:0] ex_xy,
	input wire [3:0] ex_mask,
	input wire [511:0] ex_color,
	input wire [127:0] ex_depth,
	input wire ex_last,
	output wire [15:0] ex_next,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	input wire dx_valid,
	output wire dx_ready,
	input wire [15:0] dx_seq,
	input wire [31:0] dx_xy,
	input wire [3:0] dx_mask,
	input wire [127:0] dx_depth,
	input wire dx_last,
	/* Issued sequence numbers (atg_rx ord_*) */
	input wire ord_valid,
	input wire [15:0] ord_seq,
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
	wire q_valid, q_ready, q_dbg;
	wire [31:0] q_xy;
	wire [3:0] q_mask;
	wire [511:0] q_color;
	wire [127:0] q_depth;
	wire d_valid, d_ready;
	wire [31:0] d_xy;
	wire [3:0] d_mask;
	wire [511:0] d_color;
	wire b_valid, b_rvalid;
	wire [511:0] b_src;
	wire [127:0] b_dst, b_pix;
	wire [3:0] b_mask;
	wire order_busy, ds_busy, wb_busy;
	wire ds_req_valid, ds_req_ready, ds_req_write, ds_rsp_valid, ds_rsp_write, ds_rsp_error;
	wire [ADDR_W-LINE_SHIFT-1:0] ds_req_line;
	wire [LINE_BYTES-1:0] ds_req_be;
	wire [LINE_BYTES*8-1:0] ds_req_wdata, ds_rsp_rdata;
	wire [7:0] ds_req_tag, ds_rsp_tag;
	wire wb_req_valid, wb_req_ready, wb_req_write, wb_rsp_valid, wb_rsp_write, wb_rsp_error;
	wire [ADDR_W-LINE_SHIFT-1:0] wb_req_line;
	wire [LINE_BYTES-1:0] wb_req_be;
	wire [LINE_BYTES*8-1:0] wb_req_wdata, wb_rsp_rdata;
	wire [7:0] wb_req_tag, wb_rsp_tag;
	wire [1:0] rmux_rsp_valid_v;
	am_amb_mux #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(2), .ID_W(1)) rmux (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid({wb_req_valid, ds_req_valid}), .i_req_ready({wb_req_ready, ds_req_ready}),
		.i_req_write({wb_req_write, ds_req_write}), .i_req_line({wb_req_line, ds_req_line}),
		.i_req_be({wb_req_be, ds_req_be}), .i_req_wdata({wb_req_wdata, ds_req_wdata}),
		.i_req_tag({wb_req_tag, ds_req_tag}),
		.i_rsp_valid(rmux_rsp_valid_v), .i_rsp_write(ds_rsp_write), .i_rsp_tag(ds_rsp_tag),
		.i_rsp_rdata(ds_rsp_rdata), .i_rsp_error(ds_rsp_error),
		.o_req_valid(req_valid), .o_req_ready(req_ready), .o_req_write(req_write), .o_req_line(req_line), .o_req_be(req_be), .o_req_wdata(req_wdata), .o_req_tag(req_tag), .o_rsp_valid(rsp_valid), .o_rsp_write(rsp_write), .o_rsp_tag(rsp_tag), .o_rsp_rdata(rsp_rdata), .o_rsp_error(rsp_error)
	);
	assign ds_rsp_valid = rmux_rsp_valid_v[0];
	assign wb_rsp_valid = rmux_rsp_valid_v[1];
	assign wb_rsp_write = ds_rsp_write;
	assign wb_rsp_tag = ds_rsp_tag;
	assign wb_rsp_rdata = ds_rsp_rdata;
	assign wb_rsp_error = ds_rsp_error;

	atg_rop_order order (
		.clk(clk), .rst_n(rst_n),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.ord_valid(ord_valid), .ord_seq(ord_seq),
		.q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy), .q_mask(q_mask), .q_color(q_color),
		.q_depth(q_depth), .q_dbg(q_dbg), .busy(order_busy)
	);

	atg_rop_ds #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .STENCIL(STENCIL)) ds (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.q_valid(q_valid), .q_ready(q_ready), .q_xy(q_xy), .q_mask(q_mask), .q_color(q_color),
		.q_depth(q_depth), .q_dbg(q_dbg),
		.d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_mask(d_mask), .d_color(d_color),
		.busy(ds_busy),
		.req_valid(ds_req_valid), .req_ready(ds_req_ready), .req_write(ds_req_write), .req_line(ds_req_line), .req_be(ds_req_be), .req_wdata(ds_req_wdata), .req_tag(ds_req_tag), .rsp_valid(ds_rsp_valid), .rsp_write(ds_rsp_write), .rsp_tag(ds_rsp_tag), .rsp_rdata(ds_rsp_rdata), .rsp_error(ds_rsp_error)
	);

	atg_rop_blend blend (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask),
		.b_rvalid(b_rvalid), .b_pix(b_pix)
	);

	atg_rop_wb #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) wb (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.d_valid(d_valid), .d_ready(d_ready), .d_xy(d_xy), .d_mask(d_mask), .d_color(d_color),
		.b_valid(b_valid), .b_src(b_src), .b_dst(b_dst), .b_mask(b_mask),
		.b_rvalid(b_rvalid), .b_pix(b_pix), .busy(wb_busy),
		.req_valid(wb_req_valid), .req_ready(wb_req_ready), .req_write(wb_req_write), .req_line(wb_req_line), .req_be(wb_req_be), .req_wdata(wb_req_wdata), .req_tag(wb_req_tag), .rsp_valid(wb_rsp_valid), .rsp_write(wb_rsp_write), .rsp_tag(wb_rsp_tag), .rsp_rdata(wb_rsp_rdata), .rsp_error(wb_rsp_error)
	);

	assign busy = order_busy || ds_busy || wb_busy;
endmodule

`default_nettype wire
