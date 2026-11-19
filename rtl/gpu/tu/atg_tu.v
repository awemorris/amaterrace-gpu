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

`include "atg_config.vh"

`ifdef CFG_TU_L1_BANKS
`define ATG_TU_DEF_L1_BANKS `CFG_TU_L1_BANKS
`else
`define ATG_TU_DEF_L1_BANKS 4
`endif

`ifdef CFG_TU_L1_CACHE_KB
`define ATG_TU_DEF_L1_CACHE_KB `CFG_TU_L1_CACHE_KB
`else
`define ATG_TU_DEF_L1_CACHE_KB 8
`endif

`ifdef CFG_TU_ENABLE_FFILT
`define ATG_TU_DEF_ENABLE_FFILT (`CFG_TU_ENABLE_FFILT != 0)
`else
`define ATG_TU_DEF_ENABLE_FFILT 1
`endif

`ifdef ATG_CONFIG_VH
`ifdef CFG_TU_ENABLE_BILINEAR
`define ATG_TU_DEF_ENABLE_BILINEAR (`CFG_TU_ENABLE_BILINEAR != 0)
`else
`define ATG_TU_DEF_ENABLE_BILINEAR 1
`endif

`ifdef CFG_ENABLE_TRILINEAR
`define ATG_TU_DEF_ENABLE_TRILINEAR (`CFG_ENABLE_TRILINEAR != 0)
`else
`define ATG_TU_DEF_ENABLE_TRILINEAR 1
`endif

`ifdef CFG_ENABLE_3D_CUBE
`define ATG_TU_DEF_ENABLE_3D_CUBE (`CFG_ENABLE_3D_CUBE != 0)
`else
`define ATG_TU_DEF_ENABLE_3D_CUBE 1
`endif

`ifdef CFG_ENABLE_BC
`define ATG_TU_DEF_ENABLE_BC (`CFG_ENABLE_BC != 0)
`else
`define ATG_TU_DEF_ENABLE_BC 1
`endif

`ifdef CFG_ENABLE_ETC2
`define ATG_TU_DEF_ENABLE_ETC2 (`CFG_ENABLE_ETC2 != 0)
`else
`define ATG_TU_DEF_ENABLE_ETC2 1
`endif

`ifdef CFG_ENABLE_ANISO
`define ATG_TU_DEF_ENABLE_ANISO (`CFG_ENABLE_ANISO != 0)
`else
`define ATG_TU_DEF_ENABLE_ANISO 1
`endif

`ifdef CFG_ENABLE_SEAMLESS_CUBE
`define ATG_TU_DEF_ENABLE_SEAMLESS_CUBE (`CFG_ENABLE_SEAMLESS_CUBE != 0)
`else
`define ATG_TU_DEF_ENABLE_SEAMLESS_CUBE 1
`endif

`ifdef CFG_ENABLE_ARRAY
`define ATG_TU_DEF_ENABLE_ARRAY (`CFG_ENABLE_ARRAY != 0)
`else
`define ATG_TU_DEF_ENABLE_ARRAY 1
`endif

`ifdef CFG_ENABLE_MSAA
`define ATG_TU_DEF_ENABLE_MSAA (`CFG_ENABLE_MSAA != 0)
`else
`define ATG_TU_DEF_ENABLE_MSAA 1
`endif

`else
`define ATG_TU_DEF_ENABLE_BILINEAR 1
`define ATG_TU_DEF_ENABLE_TRILINEAR 1
`define ATG_TU_DEF_ENABLE_3D_CUBE 1
`define ATG_TU_DEF_ENABLE_BC 1
`define ATG_TU_DEF_ENABLE_ETC2 1
`define ATG_TU_DEF_ENABLE_ANISO 1
`define ATG_TU_DEF_ENABLE_SEAMLESS_CUBE 1
`define ATG_TU_DEF_ENABLE_ARRAY 1
`define ATG_TU_DEF_ENABLE_MSAA 1
`endif

module atg_tu #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter L1_CACHE_KB = `ATG_TU_DEF_L1_CACHE_KB,
	parameter L1_BANKS = `ATG_TU_DEF_L1_BANKS,
	parameter ENABLE_BILINEAR = `ATG_TU_DEF_ENABLE_BILINEAR,
	parameter ENABLE_TRILINEAR = `ATG_TU_DEF_ENABLE_TRILINEAR,
	parameter ENABLE_3D_CUBE = `ATG_TU_DEF_ENABLE_3D_CUBE,
	parameter ENABLE_BC = `ATG_TU_DEF_ENABLE_BC,
	parameter ENABLE_ETC2 = `ATG_TU_DEF_ENABLE_ETC2,
	parameter ENABLE_ANISO = `ATG_TU_DEF_ENABLE_ANISO,
	parameter ENABLE_SEAMLESS_CUBE = `ATG_TU_DEF_ENABLE_SEAMLESS_CUBE,
	parameter ENABLE_ARRAY = `ATG_TU_DEF_ENABLE_ARRAY,
	parameter ENABLE_MSAA = `ATG_TU_DEF_ENABLE_MSAA,
	parameter ENABLE_FFILT = `ATG_TU_DEF_ENABLE_FFILT
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
	input wire [3:0] tx_samp_slot,
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

	(* keep_hierarchy = "yes" *)
	atg_tu_addr #(
		.ENABLE_BILINEAR(ENABLE_BILINEAR),
		.ENABLE_TRILINEAR(ENABLE_TRILINEAR),
		.ENABLE_3D_CUBE(ENABLE_3D_CUBE),
		.ENABLE_BC(ENABLE_BC),
		.ENABLE_ETC2(ENABLE_ETC2),
		.ENABLE_ANISO(ENABLE_ANISO),
		.ENABLE_SEAMLESS_CUBE(ENABLE_SEAMLESS_CUBE),
		.ENABLE_ARRAY(ENABLE_ARRAY),
		.ENABLE_MSAA(ENABLE_MSAA)
	) addr (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.desc_busy(desc_busy),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot),
		.tx_samp_slot(tx_samp_slot),
		.tx_vs(tx_vs), .tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last),
		.ta_valid(ta_valid), .ta_ready(ta_ready), .ta_addr(ta_addr), .ta_bord(ta_bord),
		.ta_wts(ta_wts), .ta_tag(ta_tag), .ta_mask(ta_mask), .ta_ctl(ta_ctl), .ta_value(ta_value),
		.ta_last(ta_last)
	);

	(* keep_hierarchy = "yes" *)
	atg_tu_cache #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.TC_BYTES(L1_CACHE_KB * 1024),
		.NBANKS(L1_BANKS)
	) cache (
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

	(* keep_hierarchy = "yes" *)
	atg_tu_outq #(.W(529)) u_ffilt_outq (
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
	wire f32 = (ENABLE_FFILT != 0) && tc_ctl[20];
	wire order_in_valid = tc_valid && tc_ready && !tc_ctl[4];
	wire order_in_ready;
	wire order_out_valid, order_out_ready;
	wire order_path;
	wire [4:0] order_count;

	(* keep_hierarchy = "yes" *)
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

	/* Replicated scalar order storage to cap per-FF fanout on cur_f32_* <= 32 */
	reg [3:0] ord_wp, ord_rp;
	wire [3:0] ord_wp_next, ord_rp_next;
	wire ord_wp_co_unused, ord_rp_co_unused;
	wire order_push = order_in_valid && order_in_ready;
	wire order_pop  = order_out_valid && order_out_ready;
	am_add #(.W(4)) u_ord_wp (.a(ord_wp), .b(4'd0), .ci(1'b1), .s(ord_wp_next), .co(ord_wp_co_unused));
	am_add #(.W(4)) u_ord_rp (.a(ord_rp), .b(4'd0), .ci(1'b1), .s(ord_rp_next), .co(ord_rp_co_unused));
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			ord_wp <= 4'd0;
			ord_rp <= 4'd0;
		end else begin
			if (order_push) ord_wp <= ord_wp_next;
			if (order_pop)  ord_rp <= ord_rp_next;
		end
	end
	wire [17:0] ord_path_rep;
	genvar gof;
	generate
		for (gof = 0; gof < 18; gof = gof + 1) begin : g_ord_rep
			(* keep = "true" *) reg [15:0] ord_mem;
			always @(posedge clk) begin
				if (order_push)
					ord_mem[ord_wp] <= f32;
			end
			assign ord_path_rep[gof] = ord_mem[ord_rp];
		end
	endgenerate

	wire order_can_take = tc_ctl[4] || order_in_ready;
	assign tc_ready = (f32 ? f_ready : u_ready) && order_can_take;

	(* keep_hierarchy = "yes" *)
	atg_tu_filter #(
		.ENABLE_BILINEAR(ENABLE_BILINEAR)
	) filter (
		.clk(clk), .rst_n(rst_n),
		.tc_valid(tc_valid && !f32 && order_can_take), .tc_ready(u_ready), .tc_texels(tc_texels),
		.tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask), .tc_ctl(tc_ctl),
		.tc_value(tc_value), .tc_last(tc_last), .idle(u_idle),
		.tr_valid(u_tr_valid), .tr_ready(u_tr_ready), .tr_tag(u_tr_tag), .tr_data(u_tr_data),
		.tr_last(u_tr_last)
	);

	generate
	if (ENABLE_FFILT != 0) begin : g_ffilt
		(* keep_hierarchy = "yes" *)
		atg_tu_ffilt ffilt (
			.clk(clk), .rst_n(rst_n),
			.tc_valid(tc_valid && f32 && order_can_take), .tc_ready(f_ready), .tc_texels(tc_texels),
			.tc_bord(tc_bord), .tc_lo(tc_lo), .tc_wts(tc_wts), .tc_tag(tc_tag), .tc_mask(tc_mask),
			.tc_ctl(tc_ctl), .tc_last(tc_last), .idle(f_idle),
			.tr_valid(f_tr_valid_raw), .tr_ready(f_tr_ready_raw), .tr_tag(f_tr_tag_raw), .tr_data(f_tr_data_raw),
			.tr_last(f_tr_last_raw)
		);
	end else begin : g_no_ffilt
		assign f_ready = 1'b1;
		assign f_idle = 1'b1;
		assign f_tr_valid_raw = 1'b0;
		assign f_tr_tag_raw = 16'd0;
		assign f_tr_data_raw = 512'd0;
		assign f_tr_last_raw = 1'b0;
	end
	endgenerate

	/* In-order return based on order_fifo (using replicated scalar FFs per slice group) */
	wire cur_is_f32 = ord_path_rep[17];
	genvar gs;
	generate
	for (gs = 0; gs < 32; gs = gs + 1) begin : g_tr_mux
		assign tr_data[gs*16 +: 16] = ord_path_rep[gs / 2] ? f_tr_data[gs*16 +: 16] : u_tr_data[gs*16 +: 16];
	end
	endgenerate
	assign tr_valid = order_out_valid && (ord_path_rep[17] ? f_tr_valid : u_tr_valid);
	assign tr_tag   = ord_path_rep[16] ? f_tr_tag : u_tr_tag;
	assign tr_last  = ord_path_rep[17] ? f_tr_last : u_tr_last;

	wire tr_fire = tr_valid && tr_ready;
	assign u_tr_ready = tr_fire && !cur_is_f32;
	assign f_tr_ready = tr_fire && cur_is_f32;
	assign order_out_ready = tr_fire;

	assign busy = ta_valid || tc_valid || tr_valid || desc_busy ||
		!u_idle || !f_idle || order_out_valid || f_tr_valid;

	/* Anisotropic filtering engine (Phase 004 / ws002-p004) */
	wire aniso_req_ready;
	wire aniso_samp_valid;
	wire [31:0] aniso_samp_u, aniso_samp_v;
	wire [16:0] aniso_samp_weight;
	wire aniso_res_valid;
	wire [31:0] aniso_res_texel;

	generate
	if (ENABLE_ANISO) begin : g_aniso
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
	end else begin : g_no_aniso
		assign aniso_req_ready = 1'b0;
		assign aniso_samp_valid = 1'b0;
		assign aniso_samp_u = 32'd0;
		assign aniso_samp_v = 32'd0;
		assign aniso_samp_weight = 17'd0;
		assign aniso_res_valid = 1'b0;
		assign aniso_res_texel = 32'd0;
	end
	endgenerate

	wire unused_tu_ok = &{1'b0, f_fifo_count, order_count, order_path, ord_wp_co_unused, ord_rp_co_unused,
		aniso_req_ready, aniso_samp_valid,
		aniso_samp_u, aniso_samp_v, aniso_samp_weight, aniso_res_valid, aniso_res_texel,
		tc_bord, tc_lo, f_tr_ready_raw};
endmodule

`default_nettype wire
