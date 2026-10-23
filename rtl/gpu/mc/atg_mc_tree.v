/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_tree: the MC's client tree (spec/gpu/mc/atg_mc_tree.md): one
 * am_amb_to_rt leaf per client and a binary tree of atg_rt routers whose
 * top is the MC's root (atg_mc).  Wiring only.
 *
 * Shape: the clients other than ROOT_CLIENT are the leaves of a complete
 * binary tree of 2^TREE_L leaves (tree client j is the leaf j, unused
 * leaves are idle); routers are numbered as a heap (1 is the top, node i
 * has the children 2i and 2i+1, the leaves are the nodes 2^TREE_L + j).
 * With ROOT_CLIENT (HAS_ROOT = 1, the KC705's DC) one more router sits on
 * top: child 0 is ROOT_CLIENT, child 1 the tree, so that client is one hop
 * from the root.  The routes: bit 0 is the top router's choice, then one
 * bit per level; tree client j takes at level l the bit TREE_L-1-l of j.
 * Clients of HIGH_MASK send their packets with the priority bit.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_tree #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter HAS_ROOT = 0,	/* 1: ROOT_CLIENT sits next to the root */
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

	output wire rsp_idle	/* no response flit in any router */
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam FW = LB;
	localparam RFW = LB + 10 + RW;
	localparam NT = NCLIENT - HAS_ROOT;	/* tree clients */
	localparam NL = 1 << TREE_L;	/* tree leaves */
	localparam [7:0] RC8 = ROOT_CLIENT[7:0];

	/* The nodes' channels towards their parent (index 0 is not used). */
	wire [2*NL-1:0] n_req_valid, n_req_ready, n_req_last, n_rsp_valid, n_rsp_ready;
	wire [2*NL*FW-1:0] n_req_data;
	wire [2*NL*RFW-1:0] n_rsp_data;
	wire [NL-1:0] rt_idle;

	assign n_req_valid[0] = 1'b0;
	assign n_req_ready[0] = 1'b0;
	assign n_req_last[0] = 1'b0;
	assign n_req_data[0 +: FW] = {FW{1'b0}};
	assign n_rsp_valid[0] = 1'b0;
	assign n_rsp_ready[0] = 1'b0;
	assign n_rsp_data[0 +: RFW] = {RFW{1'b0}};
	assign rt_idle[0] = 1'b1;
	wire unused_ok = &{1'b0, n_req_valid[0], n_req_last[0], n_rsp_ready[0], n_req_data[0 +: FW],
		n_rsp_data[0 +: RFW]};

	/* The route of tree client jj: 1 at bit 0 with HAS_ROOT, then its bits from the top. */
	function [RW-1:0] route_of;
		input integer jj;
		integer l;
		begin
			route_of = {RW{1'b0}};
			if (HAS_ROOT != 0)
				route_of[0] = 1'b1;
			for (l = 0; l < TREE_L; l = l + 1)
				route_of[l + HAS_ROOT] = ((jj >> (TREE_L - 1 - l)) & 1) != 0;
		end
	endfunction

	genvar j, i;
	generate
	/* The leaves. */
	for (j = 0; j < NL; j = j + 1) begin : g_leaf
		localparam N = NL + j;
		if (j < NT) begin : g_used
			localparam C = (HAS_ROOT != 0 && j >= ROOT_CLIENT) ? j + 1 : j;
			localparam [7:0] C8 = C[7:0];
			am_amb_to_rt #(
				.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE(route_of(j)),
				.CLIENT(C8), .PRIO(HIGH_MASK[C] ? 1 : 0)
			) leaf (
				.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[C]),
				.req_valid(c_req_valid[C]), .req_ready(c_req_ready[C]),
				.req_write(c_req_write[C]), .req_line(c_req_line[C*LA_W +: LA_W]),
				.req_be(c_req_be[C*LINE_BYTES +: LINE_BYTES]),
				.req_wdata(c_req_wdata[C*LB +: LB]), .req_tag(c_req_tag[C*8 +: 8]),
				.rsp_valid(c_rsp_valid[C]), .rsp_write(c_rsp_write[C]),
				.rsp_tag(c_rsp_tag[C*8 +: 8]), .rsp_rdata(c_rsp_rdata[C*LB +: LB]),
				.rsp_error(c_rsp_error[C]),
				.t_req_valid(n_req_valid[N]), .t_req_ready(n_req_ready[N]),
				.t_req_data(n_req_data[N*FW +: FW]), .t_req_last(n_req_last[N]),
				.t_rsp_valid(n_rsp_valid[N]), .t_rsp_ready(n_rsp_ready[N]),
				.t_rsp_data(n_rsp_data[N*RFW +: RFW])
			);
		end else begin : g_idle
			assign n_req_valid[N] = 1'b0;
			assign n_req_last[N] = 1'b0;
			assign n_req_data[N*FW +: FW] = {FW{1'b0}};
			assign n_rsp_ready[N] = 1'b1;
			wire unused_leaf = &{1'b0, n_req_ready[N], n_rsp_valid[N], n_rsp_data[N*RFW +: RFW]};
		end
	end

	/* The routers. */
	for (i = 1; i < NL; i = i + 1) begin : g_rt
		atg_rt #(.FW(FW), .RFW(RFW), .RBIT(10 + HAS_ROOT + $clog2(i + 1) - 1)) rt (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(n_req_valid[2*i]), .c0_req_ready(n_req_ready[2*i]),
			.c0_req_data(n_req_data[2*i*FW +: FW]), .c0_req_last(n_req_last[2*i]),
			.c1_req_valid(n_req_valid[2*i+1]), .c1_req_ready(n_req_ready[2*i+1]),
			.c1_req_data(n_req_data[(2*i+1)*FW +: FW]), .c1_req_last(n_req_last[2*i+1]),
			.p_req_valid(n_req_valid[i]), .p_req_ready(n_req_ready[i]),
			.p_req_data(n_req_data[i*FW +: FW]), .p_req_last(n_req_last[i]),
			.p_rsp_valid(n_rsp_valid[i]), .p_rsp_ready(n_rsp_ready[i]),
			.p_rsp_data(n_rsp_data[i*RFW +: RFW]),
			.c0_rsp_valid(n_rsp_valid[2*i]), .c0_rsp_ready(n_rsp_ready[2*i]),
			.c0_rsp_data(n_rsp_data[2*i*RFW +: RFW]),
			.c1_rsp_valid(n_rsp_valid[2*i+1]), .c1_rsp_ready(n_rsp_ready[2*i+1]),
			.c1_rsp_data(n_rsp_data[(2*i+1)*RFW +: RFW]),
			.rsp_idle(rt_idle[i])
		);
	end

	/* The top: node 1, or the root router with ROOT_CLIENT beside it. */
	if (HAS_ROOT != 0) begin : g_root
		wire rc_req_valid, rc_req_ready, rc_req_last, rc_rsp_valid, rc_rsp_ready;
		wire [FW-1:0] rc_req_data;
		wire [RFW-1:0] rc_rsp_data;
		wire root_idle;

		am_amb_to_rt #(
			.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
			.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE({RW{1'b0}}),
			.CLIENT(RC8), .PRIO(HIGH_MASK[ROOT_CLIENT] ? 1 : 0)
		) leaf (
			.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[ROOT_CLIENT]),
			.req_valid(c_req_valid[ROOT_CLIENT]), .req_ready(c_req_ready[ROOT_CLIENT]),
			.req_write(c_req_write[ROOT_CLIENT]),
			.req_line(c_req_line[ROOT_CLIENT*LA_W +: LA_W]),
			.req_be(c_req_be[ROOT_CLIENT*LINE_BYTES +: LINE_BYTES]),
			.req_wdata(c_req_wdata[ROOT_CLIENT*LB +: LB]),
			.req_tag(c_req_tag[ROOT_CLIENT*8 +: 8]),
			.rsp_valid(c_rsp_valid[ROOT_CLIENT]), .rsp_write(c_rsp_write[ROOT_CLIENT]),
			.rsp_tag(c_rsp_tag[ROOT_CLIENT*8 +: 8]),
			.rsp_rdata(c_rsp_rdata[ROOT_CLIENT*LB +: LB]),
			.rsp_error(c_rsp_error[ROOT_CLIENT]),
			.t_req_valid(rc_req_valid), .t_req_ready(rc_req_ready), .t_req_data(rc_req_data),
			.t_req_last(rc_req_last), .t_rsp_valid(rc_rsp_valid), .t_rsp_ready(rc_rsp_ready),
			.t_rsp_data(rc_rsp_data)
		);

		atg_rt #(.FW(FW), .RFW(RFW), .RBIT(10)) rt (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(rc_req_valid), .c0_req_ready(rc_req_ready), .c0_req_data(rc_req_data),
			.c0_req_last(rc_req_last),
			.c1_req_valid(n_req_valid[1]), .c1_req_ready(n_req_ready[1]),
			.c1_req_data(n_req_data[FW +: FW]), .c1_req_last(n_req_last[1]),
			.p_req_valid(r_req_valid), .p_req_ready(r_req_ready), .p_req_data(r_req_data),
			.p_req_last(r_req_last),
			.p_rsp_valid(r_rsp_valid), .p_rsp_ready(r_rsp_ready), .p_rsp_data(r_rsp_data),
			.c0_rsp_valid(rc_rsp_valid), .c0_rsp_ready(rc_rsp_ready), .c0_rsp_data(rc_rsp_data),
			.c1_rsp_valid(n_rsp_valid[1]), .c1_rsp_ready(n_rsp_ready[1]),
			.c1_rsp_data(n_rsp_data[RFW +: RFW]),
			.rsp_idle(root_idle)
		);
		assign rsp_idle = root_idle && (&rt_idle);
	end else begin : g_top
		assign r_req_valid = n_req_valid[1];
		assign n_req_ready[1] = r_req_ready;
		assign r_req_data = n_req_data[FW +: FW];
		assign r_req_last = n_req_last[1];
		assign n_rsp_valid[1] = r_rsp_valid;
		assign r_rsp_ready = n_rsp_ready[1];
		assign n_rsp_data[RFW +: RFW] = r_rsp_data;
		assign rsp_idle = &rt_idle;
	end
	endgenerate
endmodule

`default_nettype wire
