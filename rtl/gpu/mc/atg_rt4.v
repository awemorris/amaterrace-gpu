/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rt4: 4-way pipelined NoC router with strict flop-to-flop boundaries.
 *
 * Aggregates a 2x2 quad or 4-port cluster in 1 router stage.
 * Uses 2 route bits at p_rsp_data[RBIT +: 2] (children 0..3).
 * Strict priority (header bit 0) beats non-priority requests; fair round-robin
 * rotates from (last_won + 1) mod 4. Multi-flit packets lock until last flit.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rt4 #(
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

	input wire c2_req_valid,
	output wire c2_req_ready,
	input wire [FW-1:0] c2_req_data,
	input wire c2_req_last,

	input wire c3_req_valid,
	output wire c3_req_ready,
	input wire [FW-1:0] c3_req_data,
	input wire c3_req_last,

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

	output wire c2_rsp_valid,
	input wire c2_rsp_ready,
	output wire [RFW-1:0] c2_rsp_data,

	output wire c3_rsp_valid,
	input wire c3_rsp_ready,
	output wire [RFW-1:0] c3_rsp_data,

	output wire rsp_idle
);
	wire rst_int_n = rst_n && !flush;

	wire [3:0] sk_v, sk_r, sk_last;
	wire [FW-1:0] sk_d0, sk_d1, sk_d2, sk_d3;

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

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_c2_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(c2_req_valid), .in_ready(c2_req_ready),
		.in_data({c2_req_last, c2_req_data}),
		.out_valid(sk_v[2]), .out_ready(sk_r[2]),
		.out_data({sk_last[2], sk_d2})
	);

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_c3_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(c3_req_valid), .in_ready(c3_req_ready),
		.in_data({c3_req_last, c3_req_data}),
		.out_valid(sk_v[3]), .out_ready(sk_r[3]),
		.out_data({sk_last[3], sk_d3})
	);

	reg       lock;
	reg [1:0] owner;
	reg [1:0] last_won;

	wire [3:0] hi_v = {sk_v[3] && sk_d3[0], sk_v[2] && sk_d2[0], sk_v[1] && sk_d1[0], sk_v[0] && sk_d0[0]};
	wire [3:0] cand = (|hi_v) ? hi_v : sk_v;

	reg [1:0] rr_pick;
	always @(*) begin
		rr_pick = 2'd0;
		case (last_won)
		2'd0: begin
			if (cand[1])      rr_pick = 2'd1;
			else if (cand[2]) rr_pick = 2'd2;
			else if (cand[3]) rr_pick = 2'd3;
			else              rr_pick = 2'd0;
		end
		2'd1: begin
			if (cand[2])      rr_pick = 2'd2;
			else if (cand[3]) rr_pick = 2'd3;
			else if (cand[0]) rr_pick = 2'd0;
			else              rr_pick = 2'd1;
		end
		2'd2: begin
			if (cand[3])      rr_pick = 2'd3;
			else if (cand[0]) rr_pick = 2'd0;
			else if (cand[1]) rr_pick = 2'd1;
			else              rr_pick = 2'd2;
		end
		default: begin
			if (cand[0])      rr_pick = 2'd0;
			else if (cand[1]) rr_pick = 2'd1;
			else if (cand[2]) rr_pick = 2'd2;
			else              rr_pick = 2'd3;
		end
		endcase
	end

	wire [1:0] pick = lock ? owner : rr_pick;
	wire pick_valid = (pick == 2'd0) ? sk_v[0] :
	                 ((pick == 2'd1) ? sk_v[1] : ((pick == 2'd2) ? sk_v[2] : sk_v[3]));
	wire pick_last  = (pick == 2'd0) ? sk_last[0] :
	                 ((pick == 2'd1) ? sk_last[1] : ((pick == 2'd2) ? sk_last[2] : sk_last[3]));

	wire out_in_ready;
	wire fire = pick_valid && out_in_ready;
	assign sk_r[0] = out_in_ready && (pick == 2'd0);
	assign sk_r[1] = out_in_ready && (pick == 2'd1);
	assign sk_r[2] = out_in_ready && (pick == 2'd2);
	assign sk_r[3] = out_in_ready && (pick == 2'd3);

	/* Replicated mux select to respect max fanout <= 16 */
	localparam integer SL_W = 32;
	localparam integer N_SL = (FW + SL_W - 1) / SL_W;
	wire [FW-1:0] mux_data;
	genvar gs;
	generate
		for (gs = 0; gs < N_SL; gs = gs + 1) begin : g_dmux
			localparam integer B0 = gs * SL_W;
			localparam integer BW = (B0 + SL_W <= FW) ? SL_W : (FW - B0);
			(* max_fanout = 16 *) wire [1:0] sel_sl = pick;
			assign mux_data[B0 +: BW] =
				(sel_sl == 2'd0) ? sk_d0[B0 +: BW] :
				(sel_sl == 2'd1) ? sk_d1[B0 +: BW] :
				(sel_sl == 2'd2) ? sk_d2[B0 +: BW] : sk_d3[B0 +: BW];
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			lock     <= 1'b0;
			owner    <= 2'd0;
			last_won <= 2'd3;
		end else if (flush) begin
			lock     <= 1'b0;
			owner    <= 2'd0;
			last_won <= 2'd3;
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

	am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_out_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pick_valid), .in_ready(out_in_ready),
		.in_data({pick_last, mux_data}),
		.out_valid(p_req_valid), .out_ready(p_req_ready),
		.out_data({p_req_last, p_req_data})
	);

	wire pr_v, pr_r;
	wire [RFW-1:0] pr_d;

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_prsp_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(p_rsp_valid), .in_ready(p_rsp_ready),
		.in_data(p_rsp_data),
		.out_valid(pr_v), .out_ready(pr_r),
		.out_data(pr_d)
	);

	wire [1:0] dst = pr_d[RBIT +: 2];
	wire cr_in_r0, cr_in_r1, cr_in_r2, cr_in_r3;
	assign pr_r = (dst == 2'd0) ? cr_in_r0 :
	             ((dst == 2'd1) ? cr_in_r1 : ((dst == 2'd2) ? cr_in_r2 : cr_in_r3));

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp0_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && (dst == 2'd0)), .in_ready(cr_in_r0),
		.in_data(pr_d),
		.out_valid(c0_rsp_valid), .out_ready(c0_rsp_ready),
		.out_data(c0_rsp_data)
	);

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp1_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && (dst == 2'd1)), .in_ready(cr_in_r1),
		.in_data(pr_d),
		.out_valid(c1_rsp_valid), .out_ready(c1_rsp_ready),
		.out_data(c1_rsp_data)
	);

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp2_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && (dst == 2'd2)), .in_ready(cr_in_r2),
		.in_data(pr_d),
		.out_valid(c2_rsp_valid), .out_ready(c2_rsp_ready),
		.out_data(c2_rsp_data)
	);

	am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_crsp3_skid (
		.clk(clk), .rst_n(rst_int_n),
		.in_valid(pr_v && (dst == 2'd3)), .in_ready(cr_in_r3),
		.in_data(pr_d),
		.out_valid(c3_rsp_valid), .out_ready(c3_rsp_ready),
		.out_data(c3_rsp_data)
	);

	assign rsp_idle = !pr_v && !c0_rsp_valid && !c1_rsp_valid && !c2_rsp_valid && !c3_rsp_valid;
endmodule

`default_nettype wire
