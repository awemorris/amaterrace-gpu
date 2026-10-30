/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf: The vertex fetcher (design §2.3, §3.8): index walk, warp and
 * primitive assembly, attribute fetch and conversion into the SU's
 * registers; one MC client (index and attribute reads behind 2-input AMB mux).
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
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB   = LINE_BYTES * 8;

	/* Named synchronous reset net so asic-lint excludes it from data fanout checks */
	(* keep = "true" *) wire rst_sync = !rst_n;

	/*
	 * Per-submodule LUT1 fanout buffers for STATE broadcast (st_we, st_idx, st_wdata)
	 * so top-level ports have fanout 4 and submodule internal fanouts do not sum.
	 */
	wire        st_we_ix, st_we_as, st_we_fx, st_we_cv;
	wire [8:0]  st_idx_ix, st_idx_as, st_idx_fx, st_idx_cv;
	wire [31:0] st_wdata_ix, st_wdata_as, st_wdata_fx, st_wdata_cv;

	genvar gb;
	generate
`ifdef SYNTH_KINTEX7
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_we_ix (.O(st_we_ix), .I0(st_we));
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_we_as (.O(st_we_as), .I0(st_we));
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_we_fx (.O(st_we_fx), .I0(st_we));
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_we_cv (.O(st_we_cv), .I0(st_we));
`else
		assign st_we_ix = st_we;
		assign st_we_as = st_we;
		assign st_we_fx = st_we;
		assign st_we_cv = st_we;
`endif
		for (gb = 0; gb < 9; gb = gb + 1) begin : g_st_idx_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ix (.O(st_idx_ix[gb]), .I0(st_idx[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_as (.O(st_idx_as[gb]), .I0(st_idx[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_fx (.O(st_idx_fx[gb]), .I0(st_idx[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cv (.O(st_idx_cv[gb]), .I0(st_idx[gb]));
`else
			assign st_idx_ix[gb] = st_idx[gb];
			assign st_idx_as[gb] = st_idx[gb];
			assign st_idx_fx[gb] = st_idx[gb];
			assign st_idx_cv[gb] = st_idx[gb];
`endif
		end
		for (gb = 0; gb < 32; gb = gb + 1) begin : g_st_wd_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ix (.O(st_wdata_ix[gb]), .I0(st_wdata[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_as (.O(st_wdata_as[gb]), .I0(st_wdata[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_fx (.O(st_wdata_fx[gb]), .I0(st_wdata[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cv (.O(st_wdata_cv[gb]), .I0(st_wdata[gb]));
`else
			assign st_wdata_ix[gb] = st_wdata[gb];
			assign st_wdata_as[gb] = st_wdata[gb];
			assign st_wdata_fx[gb] = st_wdata[gb];
			assign st_wdata_cv[gb] = st_wdata[gb];
`endif
		end
	endgenerate

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
	wire [LA_W-1:0] ix_req_line;
	wire [LINE_BYTES-1:0] ix_req_be;
	wire [LB-1:0] ix_req_wdata, ix_rsp_rdata;
	wire [7:0] ix_req_tag, ix_rsp_tag;

	wire fx_req_valid, fx_req_ready, fx_req_write, fx_rsp_valid, fx_rsp_write, fx_rsp_error;
	wire [LA_W-1:0] fx_req_line;
	wire [LINE_BYTES-1:0] fx_req_be;
	wire [LB-1:0] fx_req_wdata, fx_rsp_rdata;
	wire [7:0] fx_req_tag, fx_rsp_tag;

	/*
	 * 2-requester AMB mux (requester 0 = index, requester 1 = fetch) with
	 * LUT1-buffered mux select (vmux_k_b[0..1], fanout <= 15) and buffered
	 * response error/tag nets so Rule 2 (fanout <= 16) is strictly met.
	 */
	reg vmux_lock;
	reg vmux_lock_k;
	wire vmux_pick = !ix_req_valid && fx_req_valid;
	wire vmux_any  = ix_req_valid || fx_req_valid;
	wire vmux_k    = vmux_lock ? vmux_lock_k : vmux_pick;
	wire [1:0] vmux_k_b;

`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_vk0 (.O(vmux_k_b[0]), .I0(vmux_k));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_vk1 (.O(vmux_k_b[1]), .I0(vmux_k));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_re_ix (.O(ix_rsp_error), .I0(rsp_error));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_re_fx (.O(fx_rsp_error), .I0(rsp_error));
`else
	assign vmux_k_b     = {2{vmux_k}};
	assign ix_rsp_error = rsp_error;
	assign fx_rsp_error = rsp_error;
`endif

	always @(posedge clk) begin
		if (rst_sync) begin
			vmux_lock   <= 1'b0;
			vmux_lock_k <= 1'b0;
		end else begin
			vmux_lock   <= req_valid && !req_ready;
			vmux_lock_k <= vmux_k;
		end
	end

	assign req_valid    = vmux_lock ? 1'b1 : vmux_any;
	assign req_write    = vmux_k_b[1] ? fx_req_write : ix_req_write;
	assign req_line     = {
		vmux_k_b[1] ? fx_req_line[LA_W-1:14] : ix_req_line[LA_W-1:14],
		vmux_k_b[0] ? fx_req_line[13:0]      : ix_req_line[13:0]
	};
	assign req_be       = {LINE_BYTES{1'b0}};
	assign req_wdata    = {LB{1'b0}};
	assign req_tag      = {vmux_k_b[1], vmux_k_b[1] ? fx_req_tag[6:0] : ix_req_tag[6:0]};
	assign ix_req_ready = req_valid && req_ready && !vmux_k;
	assign fx_req_ready = req_valid && req_ready &&  vmux_k;
	assign ix_rsp_valid = rsp_valid && !rsp_tag[7];
	assign fx_rsp_valid = rsp_valid &&  rsp_tag[7];
	assign ix_rsp_write = rsp_write;
	assign fx_rsp_write = rsp_write;
	assign ix_rsp_tag   = {1'b0, rsp_tag[6:0]};
	assign fx_rsp_tag   = {1'b0, rsp_tag[6:0]};
	assign ix_rsp_rdata = rsp_rdata;
	assign fx_rsp_rdata = rsp_rdata;

	wire unused_amb = &{1'b0, ix_req_be, fx_req_be, ix_req_wdata, fx_req_wdata,
		ix_req_tag[7], fx_req_tag[7]};

	atg_vf_index #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) index (
		.clk(clk), .rst_n(rst_n), .st_we(st_we_ix), .st_idx(st_idx_ix), .st_wdata(st_wdata_ix),
		.kick(draw_kick), .busy(index_busy),
		.iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
		.iv_restart(iv_restart), .iv_last(iv_last),
		.req_valid(ix_req_valid), .req_ready(ix_req_ready), .req_write(ix_req_write), .req_line(ix_req_line), .req_be(ix_req_be), .req_wdata(ix_req_wdata), .req_tag(ix_req_tag), .rsp_valid(ix_rsp_valid), .rsp_write(ix_rsp_write), .rsp_tag(ix_rsp_tag), .rsp_rdata(ix_rsp_rdata), .rsp_error(ix_rsp_error)
	);

	atg_vf_asm vasm (
		.clk(clk), .rst_n(rst_n), .st_we(st_we_as), .st_idx(st_idx_as), .st_wdata(st_wdata_as),
		.iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index), .iv_inst(iv_inst),
		.iv_restart(iv_restart), .iv_last(iv_last),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go), .vl_mask(vl_mask),
		.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
		.prim_free(prim_free), .prim_last(prim_last), .busy(asm_busy)
	);

	atg_vf_fetch #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) fetch (
		.clk(clk), .rst_n(rst_n), .st_we(st_we_fx), .st_idx(st_idx_fx), .st_wdata(st_wdata_fx),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane), .vb_last(vb_last),
		.af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
		.af_raw(af_raw), .af_oob(af_oob), .af_last(af_last), .busy(fetch_busy),
		.req_valid(fx_req_valid), .req_ready(fx_req_ready), .req_write(fx_req_write), .req_line(fx_req_line), .req_be(fx_req_be), .req_wdata(fx_req_wdata), .req_tag(fx_req_tag), .rsp_valid(fx_rsp_valid), .rsp_write(fx_rsp_write), .rsp_tag(fx_rsp_tag), .rsp_rdata(fx_rsp_rdata), .rsp_error(fx_rsp_error)
	);

	atg_vf_conv conv (
		.clk(clk), .rst_n(rst_n), .st_we(st_we_cv), .st_idx(st_idx_cv), .st_wdata(st_wdata_cv),
		.af_valid(af_valid), .af_ready(af_ready), .af_attr(af_attr), .af_lane(af_lane),
		.af_raw(af_raw), .af_oob(af_oob), .af_last(af_last),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane),
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
