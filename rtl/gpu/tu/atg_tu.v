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
 * Wiring of its children: atg_tu_addr
 * (descriptors and their level offsets, cube faces, LOD, wrap, addresses),
 * atg_tu_cache (the T$ on the MC port), atg_tu_filter (the 8-bit path:
 * texel conversion, compare, the filters over the passes) and atg_tu_ffilt
 * (the fp32 path of the formats of TEX_FORMAT, ta_ctl[20]).  Quads go
 * through in request order: the cache hands a pass to the filter of its
 * path when the filter of the other path is idle (has no quad), so the
 * returns of the two do not overtake each other (atg_tu_filter keeps
 * several quads of its path in its pipeline).  busy approximates STATUS.TU_BUSY: a quad on one of the links or
 * the level offsets being computed (a quad inside a child between them is
 * not seen; atg_cp_seq's SET_REG of the TU range also waits for the RX and
 * the SUs, which hold every fragment still to be textured).
 * See spec/gpu/tu/atg_tu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [9:0] st_idx,
	input wire [31:0] st_wdata,
	input wire inv,
	output wire busy,
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [7:0] tx_op,
	input wire [3:0] tx_slot,
	input wire tx_vs,
	input wire [3:0] tx_mask,
	input wire [639:0] tx_coord,
	input wire [11:0] tx_off,
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
	wire [15:0] ta_bord, tc_bord;
	wire [31:0] tc_lo;
	wire [127:0] ta_wts;
	wire [15:0] ta_tag;
	wire [3:0] ta_mask;
	wire [49:0] ta_ctl;
	wire [127:0] ta_value;
	wire tc_valid, tc_ready, tc_last;
	wire desc_busy;
	wire [511:0] tc_texels;
	wire [127:0] tc_wts;
	wire [15:0] tc_tag;
	wire [3:0] tc_mask;
	wire [49:0] tc_ctl;
	wire [127:0] tc_value;

	atg_tu_addr addr (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.desc_busy(desc_busy),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
		.tx_vs(tx_vs), .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_bord(ta_bord),
		.ta_wts(ta_wts), .ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value),
		.ta_last(ta_last)
	);

	atg_tu_cache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) cache (
		.clk(clk), .rst_n(rst_n), .inv(inv),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_bord(ta_bord),
		.ta_wts(ta_wts), .ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value),
		.ta_last(ta_last),
		.tc_valid(tc_valid), .tc_ready(tc_ready), .tc_texels(tc_texels), .tc_bord(tc_bord),
		.tc_lo(tc_lo), .tc_wts(tc_wts),
		.tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl), .tc_value(tc_value), .tc_last(tc_last),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	/* The two paths: passes are dispatched to the appropriate filter path
	 * (filter for 8-bit/UNORM8, ffilt for fp32) without mutual idle waiting.
	 * An in-order commit FIFO records the issue sequence of quads so that
	 * results from both paths return to the SU in strictly in-order fashion. */
	wire u_ready, f_ready, u_idle, f_idle;
	wire u_tr_valid, u_tr_ready, u_tr_last;
	wire [15:0] u_tr_tag;
	wire [511:0] u_tr_data;

	wire f_tr_valid_raw, f_tr_ready_raw, f_tr_last_raw;
	wire [15:0] f_tr_tag_raw;
	wire [511:0] f_tr_data_raw;

	wire [528:0] f_fifo_out;
	wire f_tr_valid, f_tr_ready, f_tr_last;
	wire [15:0] f_tr_tag;
	wire [511:0] f_tr_data;
	wire [2:0] f_fifo_count;
	wire f_fifo_in_ready;

	am_fifo #(.W(529), .DEPTH_LOG2(2)) u_ffilt_outq (
		.clk(clk), .rst_n(rst_n),
		.in_valid(f_tr_valid_raw),
		.in_ready(f_fifo_in_ready),
		.in_data({f_tr_last_raw, f_tr_tag_raw, f_tr_data_raw}),
		.out_valid(f_tr_valid),
		.out_ready(f_tr_ready),
		.out_data(f_fifo_out),
		.count(f_fifo_count)
	);
	assign f_tr_ready_raw = f_fifo_in_ready;
	assign f_tr_data = f_fifo_out[511:0];
	assign f_tr_tag = f_fifo_out[527:512];
	assign f_tr_last = f_fifo_out[528];

	/* Order FIFO: records the path (0: filter, 1: ffilt) of each committed quad */
	wire f32 = tc_ctl[20];
	wire order_in_valid = tc_valid && tc_ready && !tc_ctl[4];
	wire order_in_ready;
	wire order_out_valid, order_out_ready;
	wire order_path;
	wire [4:0] order_count;

	am_fifo #(.W(1), .DEPTH_LOG2(4)) u_order_fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(order_in_valid),
		.in_ready(order_in_ready),
		.in_data(f32),
		.out_valid(order_out_valid),
		.out_ready(order_out_ready),
		.out_data(order_path),
		.count(order_count)
	);

	wire order_can_take = tc_ctl[4] || order_in_ready;
	assign tc_ready = (f32 ? f_ready : u_ready) && order_can_take;

	atg_tu_filter filter (
		.clk(clk), .rst_n(rst_n),
		.tc_valid(tc_valid && !f32 && order_can_take), .tc_ready(u_ready), .tc_texels(tc_texels),
		.tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl),
		.tc_value(tc_value), .tc_last(tc_last), .idle(u_idle),
		.tr_valid(u_tr_valid), .tr_ready(u_tr_ready), .tr_tag(u_tr_tag), .tr_data(u_tr_data),
		.tr_last(u_tr_last)
	);

	atg_tu_ffilt ffilt (
		.clk(clk), .rst_n(rst_n),
		.tc_valid(tc_valid && f32 && order_can_take), .tc_ready(f_ready), .tc_texels(tc_texels),
		.tc_bord(tc_bord), .tc_lo(tc_lo), .tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask),
		.tc_ctl(tc_ctl), .tc_last(tc_last), .idle(f_idle),
		.tr_valid(f_tr_valid_raw), .tr_ready(f_tr_ready_raw), .tr_tag(f_tr_tag_raw), .tr_data(f_tr_data_raw),
		.tr_last(f_tr_last_raw)
	);

	/* In-order return based on order_fifo */
	wire cur_is_f32 = order_path;
	assign tr_valid = order_out_valid && (cur_is_f32 ? f_tr_valid : u_tr_valid);
	assign tr_tag   = cur_is_f32 ? f_tr_tag : u_tr_tag;
	assign tr_data  = cur_is_f32 ? f_tr_data : u_tr_data;
	assign tr_last  = cur_is_f32 ? f_tr_last : u_tr_last;

	wire tr_fire = tr_valid && tr_ready;
	assign u_tr_ready = tr_fire && !cur_is_f32;
	assign f_tr_ready = tr_fire && cur_is_f32;
	assign order_out_ready = tr_fire;

	assign busy = tx_valid || ta_valid || tc_valid || tr_valid || desc_busy ||
		!u_idle || !f_idle || order_out_valid || f_tr_valid;

	/* Anisotropic filtering engine (Phase 004 / ws002-p004) */
	wire aniso_req_ready;
	wire aniso_samp_valid;
	wire [31:0] aniso_samp_u, aniso_samp_v;
	wire [16:0] aniso_samp_weight;
	wire aniso_res_valid;
	wire [31:0] aniso_res_texel;

	atg_tu_aniso #(.MAX_SAMPLES(16)) u_aniso (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(1'b0),
		.req_ready(aniso_req_ready),
		.dudx(32'd0),
		.dudy(32'd0),
		.dvdx(32'd0),
		.dvdy(32'd0),
		.max_aniso(4'd0),	/* 4'd0 encodes 16x */
		.samp_valid(aniso_samp_valid),
		.samp_ready(1'b1),
		.samp_u(aniso_samp_u),
		.samp_v(aniso_samp_v),
		.samp_weight(aniso_samp_weight),
		.filt_valid(1'b0),
		.filt_texel(32'd0),
		.res_valid(aniso_res_valid),
		.res_texel(aniso_res_texel)
	);

	wire unused_tu_ok = &{1'b0, f_fifo_count, order_count, aniso_req_ready, aniso_samp_valid,
		aniso_samp_u, aniso_samp_v, aniso_samp_weight, aniso_res_valid, aniso_res_texel};
endmodule

`default_nettype wire
