/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf: The vertex fetcher (design §2.3, §3.8): index walk, warp and
 * primitive assembly, attribute fetch and conversion into the SU's
 * registers; one MC client (index and attribute reads behind am_amb_mux).
 *
 * Wiring of its children; see spec/gpu/vf/atg_vf.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire draw_kick,
	output wire busy,
	output wire [3:0] fsm,
	/* Vertex warps to the SU (atg_su vl_*) */
	output wire vl_req,
	input wire vl_gnt,
	input wire [7:0] vl_ptbase,
	output wire vl_go,
	output wire [31:0] vl_mask,
	output wire vl_we,
	output wire [5:0] vl_reg,
	output wire [4:0] vl_lane,
	output wire [31:0] vl_data,
	/* Primitives to the RX */
	output wire prim_valid,
	input wire prim_ready,
	output wire [25:0] prim_vtx,
	output wire [2:0] prim_free,
	output wire prim_last,
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
	wire iv_valid, iv_ready, iv_restart, iv_last;
	wire [31:0] iv_index, iv_inst;
	wire vb_valid, vb_ready, vb_last;
	wire [31:0] vb_index, vb_inst;
	wire [4:0] vb_lane;
	wire af_valid, af_ready, af_last, af_oob;
	wire [3:0] af_attr;
	wire [4:0] af_lane;
	wire [127:0] af_raw;
	wire conv_done;
	wire index_busy, asm_busy, fetch_busy;
	wire ix_req_valid, ix_req_ready, ix_req_write, ix_rsp_valid, ix_rsp_write, ix_rsp_error;
	wire [ADDR_W-LINE_SHIFT-1:0] ix_req_line;
	wire [LINE_BYTES-1:0] ix_req_be;
	wire [LINE_BYTES*8-1:0] ix_req_wdata, ix_rsp_rdata;
	wire [7:0] ix_req_tag, ix_rsp_tag;
	wire fx_req_valid, fx_req_ready, fx_req_write, fx_rsp_valid, fx_rsp_write, fx_rsp_error;
	wire [ADDR_W-LINE_SHIFT-1:0] fx_req_line;
	wire [LINE_BYTES-1:0] fx_req_be;
	wire [LINE_BYTES*8-1:0] fx_req_wdata, fx_rsp_rdata;
	wire [7:0] fx_req_tag, fx_rsp_tag;
	wire [1:0] vmux_rsp_valid_v;
	am_amb_mux #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(2), .ID_W(1)) vmux (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid({fx_req_valid, ix_req_valid}), .i_req_ready({fx_req_ready, ix_req_ready}),
		.i_req_write({fx_req_write, ix_req_write}), .i_req_line({fx_req_line, ix_req_line}),
		.i_req_be({fx_req_be, ix_req_be}), .i_req_wdata({fx_req_wdata, ix_req_wdata}),
		.i_req_tag({fx_req_tag, ix_req_tag}),
		.i_rsp_valid(vmux_rsp_valid_v), .i_rsp_write(ix_rsp_write), .i_rsp_tag(ix_rsp_tag),
		.i_rsp_rdata(ix_rsp_rdata), .i_rsp_error(ix_rsp_error),
		.o_req_valid(req_valid), .o_req_ready(req_ready), .o_req_write(req_write), .o_req_line(req_line), .o_req_be(req_be), .o_req_wdata(req_wdata), .o_req_tag(req_tag), .o_rsp_valid(rsp_valid), .o_rsp_write(rsp_write), .o_rsp_tag(rsp_tag), .o_rsp_rdata(rsp_rdata), .o_rsp_error(rsp_error)
	);
	assign ix_rsp_valid = vmux_rsp_valid_v[0];
	assign fx_rsp_valid = vmux_rsp_valid_v[1];
	assign fx_rsp_write = ix_rsp_write;
	assign fx_rsp_tag = ix_rsp_tag;
	assign fx_rsp_rdata = ix_rsp_rdata;
	assign fx_rsp_error = ix_rsp_error;

	atg_vf_index #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) index (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.kick(draw_kick), .busy(index_busy),
		.iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
		.iv_restart(iv_restart), .iv_last(iv_last),
		.req_valid(ix_req_valid), .req_ready(ix_req_ready), .req_write(ix_req_write), .req_line(ix_req_line), .req_be(ix_req_be), .req_wdata(ix_req_wdata), .req_tag(ix_req_tag), .rsp_valid(ix_rsp_valid), .rsp_write(ix_rsp_write), .rsp_tag(ix_rsp_tag), .rsp_rdata(ix_rsp_rdata), .rsp_error(ix_rsp_error)
	);

	atg_vf_asm vasm (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
		.iv_restart(iv_restart), .iv_last(iv_last),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask),
		.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
		.prim_free(prim_free), .prim_last(prim_last), .busy(asm_busy)
	);

	atg_vf_fetch #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) fetch (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane), .vb_last(vb_last),
		.af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
		.af_raw(af_raw), .af_oob(af_oob), .af_last(af_last), .busy(fetch_busy),
		.req_valid(fx_req_valid), .req_ready(fx_req_ready), .req_write(fx_req_write), .req_line(fx_req_line), .req_be(fx_req_be), .req_wdata(fx_req_wdata), .req_tag(fx_req_tag), .rsp_valid(fx_rsp_valid), .rsp_write(fx_rsp_write), .rsp_tag(fx_rsp_tag), .rsp_rdata(fx_rsp_rdata), .rsp_error(fx_rsp_error)
	);

	atg_vf_conv conv (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
		.af_raw(af_raw), .af_oob(af_oob), .af_last(af_last),
		.vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data),
		.conv_done(conv_done)
	);

	/* Post-Transform Vertex Cache (Phase 033) */
	wire vc_hit;
	wire [511:0] vc_hit_vdata;
	wire [4:0] vc_hit_slot;
	atg_vf_vc #(.NENTRIES(32), .VDATA_W(512), .SLOT_W(5)) vc (
		.clk(clk), .rst_n(rst_n), .flush(draw_kick),
		.lookup_valid(iv_valid), .lookup_index(iv_index),
		.hit(vc_hit), .hit_vdata(vc_hit_vdata), .hit_slot(vc_hit_slot),
		.commit_valid(1'b0), .commit_index(32'd0), .commit_vdata(512'd0)
	);

	wire unused_vc = &{1'b0, vc_hit, vc_hit_slot, vc_hit_vdata};

	assign busy = index_busy || asm_busy || fetch_busy;
	assign fsm = {prim_valid, fetch_busy, asm_busy, index_busy};
endmodule

`default_nettype wire
