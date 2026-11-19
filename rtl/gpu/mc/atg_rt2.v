/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rt2: 2-way pipelined NoC router with strict flop-to-flop boundaries.
 *
 * Architecture (docs/style.md Rules 1-5):
 *   - Request path (upward toward root/MC):
 *       c{0,1}_req -> per-child am_skid -> QoS+RR arbiter (locks on !last,
 *       strict prio on header flit bit 0) -> output am_skid -> p_req.
 *       Zero combinational p_req_ready -> c*_req_ready propagation.
 *   - Response path (downward toward children/SUs):
 *       p_rsp -> input am_skid -> registered route bit decode p_rsp_data[RBIT]
 *       -> per-child output am_skid -> c{0,1}_rsp.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rt2 #(
	parameter FW = 512,
	parameter RFW = 534,
	parameter RBIT = 10
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	/* Child request ports */
	input wire c0_req_valid,
	output wire c0_req_ready,
	input wire [FW-1:0] c0_req_data,
	input wire c0_req_last,

	input wire c1_req_valid,
	output wire c1_req_ready,
	input wire [FW-1:0] c1_req_data,
	input wire c1_req_last,

	/* Parent request port */
	output wire p_req_valid,
	input wire p_req_ready,
	output wire [FW-1:0] p_req_data,
	output wire p_req_last,

	/* Parent response port */
	input wire p_rsp_valid,
	output wire p_rsp_ready,
	input wire [RFW-1:0] p_rsp_data,

	/* Child response ports */
	output wire c0_rsp_valid,
	input wire c0_rsp_ready,
	output wire [RFW-1:0] c0_rsp_data,

	output wire c1_rsp_valid,
	input wire c1_rsp_ready,
	output wire [RFW-1:0] c1_rsp_data,

	output wire rsp_idle
);
	wire rst_int_n = rst_n && !flush;

	/* Input request skid buffers (isolate child ready & valid/data) */
	wire [1:0] sk_v, sk_r, sk_last;
	wire [FW-1:0] sk_d0, sk_d1;

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_c0_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(c0_req_valid), .in_ready(c0_req_ready),
		.in_data({c0_req_last, c0_req_data}),
		.out_valid(sk_v[0]), .out_ready(sk_r[0]),
		.out_data({sk_last[0], sk_d0})
	);

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_c1_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(c1_req_valid), .in_ready(c1_req_ready),
		.in_data({c1_req_last, c1_req_data}),
		.out_valid(sk_v[1]), .out_ready(sk_r[1]),
		.out_data({sk_last[1], sk_d1})
	);

	/* QoS + Round-Robin packet-locked arbiter */
	reg lock;
	reg owner;
	reg last_won;

	wire both = sk_v[0] && sk_v[1];
	wire p0 = sk_d0[0];
	wire p1 = sk_d1[0];
	wire pick_free = both ? ((p0 != p1) ? p1 : !last_won) : sk_v[1];
	wire pick = lock ? owner : pick_free;
	wire pick_valid = pick ? sk_v[1] : sk_v[0];
	wire pick_last  = pick ? sk_last[1] : sk_last[0];

	wire out_in_ready;
	wire fire = pick_valid && out_in_ready;
	assign sk_r[0] = out_in_ready && !pick;
	assign sk_r[1] = out_in_ready && pick;

	(* max_fanout = 16 *) wire pick_d = pick;
	wire [FW-1:0] mux_data = pick_d ? sk_d1 : sk_d0;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lock     <= 1'b0;
			owner    <= 1'b0;
			last_won <= 1'b1;
		end else if (flush) begin
			lock     <= 1'b0;
			owner    <= 1'b0;
			last_won <= 1'b1;
		end else if (fire) begin
			if (!lock)
				last_won <= pick;
			if (pick_last) begin
				lock <= 1'b0;
			end else begin
				lock  <= 1'b1;
				owner <= pick;
			end
		end
	end

	/* Output request skid buffer (isolate parent backpressure) */
	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_out_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pick_valid), .in_ready(out_in_ready),
		.in_data({pick_last, mux_data}),
		.out_valid(p_req_valid), .out_ready(p_req_ready),
		.out_data({p_req_last, p_req_data})
	);

	/* Response path: parent skid -> RBIT decode -> per-child skid */
	wire pr_v, pr_r;
	wire [RFW-1:0] pr_d;

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_prsp_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(p_rsp_valid), .in_ready(p_rsp_ready),
		.in_data(p_rsp_data),
		.out_valid(pr_v), .out_ready(pr_r),
		.out_data(pr_d)
	);

	wire dst = pr_d[RBIT];
	wire cr_in_r0, cr_in_r1;
	assign pr_r = dst ? cr_in_r1 : cr_in_r0;

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp0_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && !dst), .in_ready(cr_in_r0),
		.in_data(pr_d),
		.out_valid(c0_rsp_valid), .out_ready(c0_rsp_ready),
		.out_data(c0_rsp_data)
	);

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp1_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && dst), .in_ready(cr_in_r1),
		.in_data(pr_d),
		.out_valid(c1_rsp_valid), .out_ready(c1_rsp_ready),
		.out_data(c1_rsp_data)
	);

	assign rsp_idle = !pr_v && !c0_rsp_valid && !c1_rsp_valid;
endmodule

`default_nettype wire
