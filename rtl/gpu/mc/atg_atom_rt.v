/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_atom_rt: K-way pipelined atomic request router & response distributor.
 *
 * Aggregates K child atomic interfaces (from SUs or lower atg_atom_rt stages)
 * up to one parent port (ultimately spine atg_mc_atom) with strict
 * flop-to-flop boundaries (am_skid on all inputs and request output).
 * A small FIFO tracks child ownership of in-flight atomic requests in order,
 * broadcasting the parent's single-cycle at_rsp_valid pulse back only to the
 * originating child.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_atom_rt #(
	parameter K = 4,
	parameter ATOM_AW = 30
) (
	input wire clk,
	input wire rst_n,

	/* Child atomic ports (packed, child 0 in low bits) */
	input wire [K-1:0] c_at_valid,
	output wire [K-1:0] c_at_ready,
	input wire [K*4-1:0] c_at_op,
	input wire [K*ATOM_AW-1:0] c_at_addr,
	input wire [K*32-1:0] c_at_a,
	input wire [K*32-1:0] c_at_b,
	input wire [K*2-1:0] c_at_stage,
	output reg [K-1:0] c_at_rsp_valid,
	output reg [31:0] c_at_old,
	output reg c_at_error,

	/* Parent atomic port (toward spine atg_mc_atom) */
	output wire p_at_valid,
	input wire p_at_ready,
	output wire [3:0] p_at_op,
	output wire [ATOM_AW-1:0] p_at_addr,
	output wire [31:0] p_at_a,
	output wire [31:0] p_at_b,
	output wire [1:0] p_at_stage,
	input wire p_at_rsp_valid,
	input wire [31:0] p_at_old,
	input wire p_at_error
);
	localparam KW = (K > 2) ? 2 : 1;
	localparam REQ_W = 4 + ATOM_AW + 32 + 32 + 2;

	wire [K-1:0] sk_v, sk_r;
	wire [K*REQ_W-1:0] sk_d_flat;

	genvar gk;
	generate
		for (gk = 0; gk < K; gk = gk + 1) begin : g_csk
			wire [REQ_W-1:0] c_in = {
				c_at_op[gk*4 +: 4],
				c_at_addr[gk*ATOM_AW +: ATOM_AW],
				c_at_a[gk*32 +: 32],
				c_at_b[gk*32 +: 32],
				c_at_stage[gk*2 +: 2]
			};
			am_skid #(.WIDTH(REQ_W), .RST_DATA(0)) u_skid (
				.clk(clk), .rst_n(rst_n),
				.in_valid(c_at_valid[gk]), .in_ready(c_at_ready[gk]),
				.in_data(c_in),
				.out_valid(sk_v[gk]), .out_ready(sk_r[gk]),
				.out_data(sk_d_flat[gk*REQ_W +: REQ_W])
			);
		end
	endgenerate

	reg [KW-1:0] last_won;
	reg [KW-1:0] pick;
	wire         pick_valid = |sk_v;
	integer      step, idx;

	/* Zero-arithmetic round-robin scan starting at (last_won + 1) mod K */
	always @(*) begin
		pick = {KW{1'b0}};
		for (step = K - 1; step >= 0; step = step - 1) begin
			for (idx = 0; idx < K; idx = idx + 1) begin
				/* Constant modulo index mapping per last_won value */
				if (last_won == idx[KW-1:0] && sk_v[(idx + 1 + step) % K])
					pick = ((idx + 1 + step) % K);
			end
		end
	end

	wire out_in_ready;
	wire fifo_in_ready;
	wire fifo_out_valid;
	wire [KW-1:0] fifo_out_owner;

	wire fire = pick_valid && out_in_ready && fifo_in_ready;

	generate
		for (gk = 0; gk < K; gk = gk + 1) begin : g_skr
			assign sk_r[gk] = fire && (pick == gk[KW-1:0]);
		end
	endgenerate

	reg [REQ_W-1:0] mux_req;
	integer mi;
	always @(*) begin
		mux_req = {REQ_W{1'b0}};
		for (mi = 0; mi < K; mi = mi + 1) begin
			if (pick == mi[KW-1:0])
				mux_req = sk_d_flat[mi*REQ_W +: REQ_W];
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			last_won <= {KW{1'b0}};
		end else if (fire) begin
			last_won <= pick;
		end
	end

	am_skid #(.WIDTH(REQ_W), .RST_DATA(0)) u_out_skid (
		.clk(clk), .rst_n(rst_n),
		.in_valid(fire), .in_ready(out_in_ready),
		.in_data(mux_req),
		.out_valid(p_at_valid), .out_ready(p_at_ready),
		.out_data({p_at_op, p_at_addr, p_at_a, p_at_b, p_at_stage})
	);

	wire [3:0] fifo_cnt;
	am_fifo #(.W(KW), .DEPTH_LOG2(3)) u_own_fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(fire), .in_ready(fifo_in_ready), .in_data(pick),
		.out_valid(fifo_out_valid), .out_ready(p_at_rsp_valid), .out_data(fifo_out_owner),
		.count(fifo_cnt)
	);
	wire unused_ok = &{1'b0, fifo_cnt};

	/* Registered 1-cycle response fanout back to originating child */
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			c_at_rsp_valid <= {K{1'b0}};
			c_at_old       <= 32'd0;
			c_at_error     <= 1'b0;
		end else begin
			c_at_rsp_valid <= {K{1'b0}};
			if (p_at_rsp_valid && fifo_out_valid) begin
				c_at_rsp_valid[fifo_out_owner] <= 1'b1;
				c_at_old                       <= p_at_old;
				c_at_error                     <= p_at_error;
			end
		end
	end
endmodule

`default_nettype wire
