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
 * WS288 p023 stub: ports and parameters only, every output is 0.
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
	assign sq_seq = 16'd0;
	assign ord_valid = 1'd0;
	assign ord_seq = 16'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, sq_req};
endmodule

`default_nettype wire
