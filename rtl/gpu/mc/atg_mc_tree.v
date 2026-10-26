/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_tree: Memory Controller Flat Crossbar & QoS Arbiter (ws001-p028).
 *
 * Replaces the multi-hop binary tree of atg_rt routers with a 2-stage flat
 * matrix crossbar and QoS priority arbiter, reducing roundtrip latency from
 * 8 cycles to 2 cycles.
 *
 * QoS Priorities:
 *   - Priority Level 1 (Strict Priority): Clients with HIGH_MASK (e.g. DC).
 *   - Priority Level 0 (Fair Round Robin): 3D/compute clients (SU, TU, ROP, VF, BLT).
 *
 * Multi-flit packet atomicity:
 *   - Arbiter locks to the winning client until its last flit (grant_last) completes.
 *
 * Channel Splitting:
 *   - When HAS_ROOT != 0 && ROOT_SPLIT != 0, ROOT_CLIENT has a dedicated channel
 *     to the root (s_req_*, s_rsp_*), while the remaining NCLIENT-1 clients are
 *     arbitrated through the flat crossbar to r_req_*, r_rsp_*.
 *   - When ROOT_SPLIT == 0, all NCLIENT clients are arbitrated through the flat
 *     crossbar to r_req_*, r_rsp_*, and s_req_* is held idle.
 *
 * Latency:
 *   - Request path: 1 cycle (via am_skid register slice).
 *   - Response path: 1 cycle (via registered demux slice).
 *   - Total roundtrip latency: 2 cycles.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_tree #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter HAS_ROOT = 0,	/* 1: ROOT_CLIENT sits next to the root */
	parameter ROOT_SPLIT = 0,	/* 1: ROOT_CLIENT has its own channel to the root (s_*) */
	parameter ROOT_KEEP = 0,	/* 1 (with ROOT_SPLIT): flush leaves ROOT_CLIENT's leaf alone */
	parameter ROOT_CLIENT = 0,
	parameter TREE_L = 1,	/* clog2(NCLIENT - HAS_ROOT) */
	parameter RW = 1,	/* route bits: max(1, TREE_L + HAS_ROOT) */
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter VRAM_AW = 32,
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire [NCLIENT-1:0] hold,	/* per client: start no new packet (quiesce) */

	/* The clients (packed, client 0 in the low bits). */
	input wire [NCLIENT-1:0] c_req_valid,
	output wire [NCLIENT-1:0] c_req_ready,
	input wire [NCLIENT-1:0] c_req_write,
	input wire [NCLIENT*(ADDR_W-LINE_SHIFT)-1:0] c_req_line,
	input wire [NCLIENT*LINE_BYTES-1:0] c_req_be,
	input wire [NCLIENT*LINE_BYTES*8-1:0] c_req_wdata,
	input wire [NCLIENT*8-1:0] c_req_tag,
	input wire [NCLIENT-1:0] c_req_chk,
	input wire [NCLIENT-1:0] c_req_tbl,
	input wire [NCLIENT*6-1:0] c_req_slot,
	output wire [NCLIENT-1:0] c_rsp_valid,
	output wire [NCLIENT-1:0] c_rsp_write,
	output wire [NCLIENT*8-1:0] c_rsp_tag,
	output wire [NCLIENT*LINE_BYTES*8-1:0] c_rsp_rdata,
	output wire [NCLIENT-1:0] c_rsp_error,

	/* The root. */
	output wire r_req_valid,
	input wire r_req_ready,
	output wire [LINE_BYTES*8-1:0] r_req_data,
	output wire r_req_last,
	input wire r_rsp_valid,
	output wire r_rsp_ready,
	input wire [LINE_BYTES*8+10+RW-1:0] r_rsp_data,

	/* ROOT_CLIENT's own channel (ROOT_SPLIT; its responses always taken). */
	output wire s_req_valid,
	input wire s_req_ready,
	output wire [LINE_BYTES*8-1:0] s_req_data,
	output wire s_req_last,
	input wire s_rsp_valid,
	input wire [LINE_BYTES*8+10+RW-1:0] s_rsp_data,

	output wire rsp_idle	/* no response flit in crossbar */
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam FW = LB;
	localparam RFW = LB + 10 + RW;
	localparam SPLIT_ROOT = (HAS_ROOT != 0 && ROOT_SPLIT != 0) ? 1 : 0;
	localparam NX = SPLIT_ROOT ? (NCLIENT - 1) : NCLIENT;
	localparam CW = (NX > 1) ? $clog2(NX) : 1;

	/* The route of client c_idx */
	function [RW-1:0] client_route;
		input integer c_idx;
		integer jj, l;
		begin
			client_route = {RW{1'b0}};
			if (HAS_ROOT != 0 && c_idx == ROOT_CLIENT) begin
				client_route = {RW{1'b0}};
			end else begin
				if (HAS_ROOT != 0) begin
					client_route[0] = 1'b1;
					jj = (c_idx > ROOT_CLIENT) ? (c_idx - 1) : c_idx;
				end else begin
					jj = c_idx;
				end
				for (l = 0; l < TREE_L; l = l + 1)
					client_route[l + HAS_ROOT] = ((jj >> (TREE_L - 1 - l)) & 1) != 0;
			end
		end
	endfunction

	/* Crossbar leaf signals */
	wire [NX-1:0] leaf_req_valid;
	wire [NX-1:0] leaf_req_ready;
	wire [NX*FW-1:0] leaf_req_data;
	wire [NX-1:0] leaf_req_last;
	wire [NX-1:0] leaf_rsp_valid;
	wire [NX-1:0] leaf_rsp_ready;
	wire [NX*RFW-1:0] leaf_rsp_data;

	genvar c;
	generate
	for (c = 0; c < NCLIENT; c = c + 1) begin : g_client
		localparam [7:0] C8 = c[7:0];
		if (SPLIT_ROOT && c == ROOT_CLIENT) begin : g_split_leaf
			wire rc_rsp_ready_unused;
			am_amb_to_rt #(
				.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE(client_route(c)),
				.CLIENT(C8), .PRIO(HIGH_MASK[c] ? 1 : 0)
			) leaf_split (
`ifdef MUT_MC_NOKEEP
				.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[c]),
`else
				.clk(clk), .rst_n(rst_n), .flush(flush && !(ROOT_KEEP != 0)),
				.hold(hold[c]),
`endif
				.req_valid(c_req_valid[c]), .req_ready(c_req_ready[c]),
				.req_write(c_req_write[c]), .req_line(c_req_line[c*LA_W +: LA_W]),
				.req_be(c_req_be[c*LINE_BYTES +: LINE_BYTES]),
				.req_wdata(c_req_wdata[c*LB +: LB]), .req_tag(c_req_tag[c*8 +: 8]),
				.req_chk(c_req_chk[c]), .req_tbl(c_req_tbl[c]),
				.req_slot(c_req_slot[c*6 +: 6]),
				.rsp_valid(c_rsp_valid[c]), .rsp_write(c_rsp_write[c]),
				.rsp_tag(c_rsp_tag[c*8 +: 8]), .rsp_rdata(c_rsp_rdata[c*LB +: LB]),
				.rsp_error(c_rsp_error[c]),
				.t_req_valid(s_req_valid), .t_req_ready(s_req_ready),
				.t_req_data(s_req_data), .t_req_last(s_req_last),
				.t_rsp_valid(s_rsp_valid), .t_rsp_ready(rc_rsp_ready_unused),
				.t_rsp_data(s_rsp_data)
			);
			wire unused_rc_rdy = rc_rsp_ready_unused;
		end else begin : g_cross_leaf
			localparam J = (SPLIT_ROOT && c > ROOT_CLIENT) ? (c - 1) : c;
			am_amb_to_rt #(
				.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE(client_route(c)),
				.CLIENT(C8), .PRIO(HIGH_MASK[c] ? 1 : 0)
			) leaf_cross (
				.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[c]),
				.req_valid(c_req_valid[c]), .req_ready(c_req_ready[c]),
				.req_write(c_req_write[c]), .req_line(c_req_line[c*LA_W +: LA_W]),
				.req_be(c_req_be[c*LINE_BYTES +: LINE_BYTES]),
				.req_wdata(c_req_wdata[c*LB +: LB]), .req_tag(c_req_tag[c*8 +: 8]),
				.req_chk(c_req_chk[c]), .req_tbl(c_req_tbl[c]),
				.req_slot(c_req_slot[c*6 +: 6]),
				.rsp_valid(c_rsp_valid[c]), .rsp_write(c_rsp_write[c]),
				.rsp_tag(c_rsp_tag[c*8 +: 8]), .rsp_rdata(c_rsp_rdata[c*LB +: LB]),
				.rsp_error(c_rsp_error[c]),
				.t_req_valid(leaf_req_valid[J]), .t_req_ready(leaf_req_ready[J]),
				.t_req_data(leaf_req_data[J*FW +: FW]), .t_req_last(leaf_req_last[J]),
				.t_rsp_valid(leaf_rsp_valid[J]), .t_rsp_ready(leaf_rsp_ready[J]),
				.t_rsp_data(leaf_rsp_data[J*RFW +: RFW])
			);
		end
	end
	endgenerate

	generate
	if (!SPLIT_ROOT) begin : g_no_split
		assign s_req_valid = 1'b0;
		assign s_req_data = {FW{1'b0}};
		assign s_req_last = 1'b0;
		wire unused_split_inputs = &{1'b0, s_req_ready, s_rsp_valid, s_rsp_data};
	end
	endgenerate

	/*
	 * QoS Priority Arbitration across the NX crossbar clients
	 * Level 1: Strict Priority (HIGH_MASK)
	 * Level 0: Fair Round Robin (normal 3D/compute clients)
	 */
	wire [NX-1:0] prio_req;
	wire [NX-1:0] norm_req;

	genvar j;
	generate
	for (j = 0; j < NX; j = j + 1) begin : g_prio_split
		localparam C = (SPLIT_ROOT && j >= ROOT_CLIENT) ? (j + 1) : j;
		assign prio_req[j] = leaf_req_valid[j] && (HIGH_MASK[C] != 0);
		assign norm_req[j] = leaf_req_valid[j] && (HIGH_MASK[C] == 0);
	end
	endgenerate

	reg locked;
	reg [CW-1:0] locked_client;
	reg [CW-1:0] rr_ptr;

	reg grant_v;
	reg [CW-1:0] grant_idx;
	integer k;

	always @(*) begin
		grant_v = 1'b0;
		grant_idx = {CW{1'b0}};
		if (locked) begin
			grant_v = leaf_req_valid[locked_client];
			grant_idx = locked_client;
		end else if (|prio_req) begin
			/* Priority Level 1: Strict priority */
			grant_v = 1'b1;
			for (k = NX - 1; k >= 0; k = k - 1) begin
				if (prio_req[k])
					grant_idx = k[CW-1:0];
			end
		end else if (|norm_req) begin
			/* Priority Level 0: Round Robin */
			grant_v = 1'b1;
			for (k = NX - 1; k >= 0; k = k - 1) begin
				if (k < rr_ptr && norm_req[k])
					grant_idx = k[CW-1:0];
			end
			for (k = NX - 1; k >= 0; k = k - 1) begin
				if (k >= rr_ptr && norm_req[k])
					grant_idx = k[CW-1:0];
			end
		end
	end

	wire [CW:0] grant_plus1;
	wire rr_co;
	am_add #(.W(CW+1)) u_rr_add (
		.a({1'b0, grant_idx}), .b({(CW+1){1'b0}}), .ci(1'b1),
		.s(grant_plus1), .co(rr_co)
	);
	wire [CW-1:0] next_rr = (grant_plus1 >= NX[CW:0]) ? {CW{1'b0}} : grant_plus1[CW-1:0];

	wire skid_in_ready;
	wire skid_fire = grant_v && skid_in_ready;

	reg [FW-1:0] grant_data_mux;
	reg grant_last_mux;
	integer mxi;
	always @(*) begin
		grant_data_mux = {FW{1'b0}};
		grant_last_mux = 1'b0;
		for (mxi = 0; mxi < NX; mxi = mxi + 1) begin
			if (grant_idx == mxi[CW-1:0]) begin
				grant_data_mux = leaf_req_data[mxi*FW +: FW];
				grant_last_mux = leaf_req_last[mxi];
			end
		end
	end
	wire [FW-1:0] grant_data = grant_data_mux;
	wire grant_last = grant_last_mux;

	generate
	for (j = 0; j < NX; j = j + 1) begin : g_rdy
		assign leaf_req_ready[j] = grant_v && (grant_idx == j[CW-1:0]) && skid_in_ready;
	end
	endgenerate

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			locked <= 1'b0;
			locked_client <= {CW{1'b0}};
			rr_ptr <= {CW{1'b0}};
		end else if (skid_fire) begin
			if (!grant_last) begin
				locked <= 1'b1;
				locked_client <= grant_idx;
			end else begin
				locked <= 1'b0;
				rr_ptr <= next_rr;
			end
		end
	end

	/* Flat crossbar request path with skid buffer */
	am_skid #(.WIDTH(FW + 1)) u_req_skid (
		.clk(clk), .rst_n(rst_n && !flush),
		.in_valid(grant_v), .in_ready(skid_in_ready),
		.in_data({grant_last, grant_data}),
		.out_valid(r_req_valid), .out_ready(r_req_ready),
		.out_data({r_req_last, r_req_data})
	);

	/* Flat crossbar response path with 1-cycle registered demux */
	reg rsp_reg_v;
	reg [RFW-1:0] rsp_reg_data;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			rsp_reg_v <= 1'b0;
			rsp_reg_data <= {RFW{1'b0}};
		end else begin
			rsp_reg_v <= r_rsp_valid;
			rsp_reg_data <= r_rsp_data;
		end
	end

	assign r_rsp_ready = 1'b1;
	assign rsp_idle = !rsp_reg_v;

	generate
	for (j = 0; j < NX; j = j + 1) begin : g_rsp_demux
		localparam C = (SPLIT_ROOT && j >= ROOT_CLIENT) ? (j + 1) : j;
		wire match = (rsp_reg_data[10 +: RW] == client_route(C));
		assign leaf_rsp_valid[j] = rsp_reg_v && match;
		assign leaf_rsp_data[j*RFW +: RFW] = rsp_reg_data;
	end
	endgenerate

	wire unused_co = &{1'b0, rr_co, leaf_rsp_ready};
endmodule

`default_nettype wire
