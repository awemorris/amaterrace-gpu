/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_order: Hands out the fragment sequence numbers in primitive order
 * (design §3.8) and tells the ROP which numbers exist.
 *
 * The behaviour is specified in spec/gpu/rx/atg_rx_order.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_order (
	input wire clk,
	input wire rst_n,
	input wire sq_req,
	output wire [15:0] sq_seq,
	output wire ord_valid,
	output wire [15:0] ord_seq
);
	/* spec/gpu/rx/atg_rx_order.md */
	reg [15:0] cnt;
	wire [15:0] cnt1;
	wire c1_co_unused;
	am_add #(.W(16)) u_cnt1 (.a(cnt), .b(16'd0), .ci(1'b1), .s(cnt1), .co(c1_co_unused));

	assign sq_seq = cnt;
	assign ord_valid = sq_req;
	assign ord_seq = cnt;

	always @(posedge clk)
		if (!rst_n)
			cnt <= 16'd0;
		else if (sq_req)
			cnt <= cnt1;
endmodule

`default_nettype wire
