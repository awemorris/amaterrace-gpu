/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fdiv: backward compatibility wrapper around am_fp_div.
 * See rtl/library/fp/am_fp_div.v.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fdiv (
	input wire clk,
	input wire rst_n,
	input wire i_start,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire busy,
	output wire o_done,
	output wire [31:0] o_r
);
	am_fp_div u_div (
		.clk(clk),
		.rst_n(rst_n),
		.i_start(i_start),
		.i_a(i_a),
		.i_b(i_b),
		.busy(busy),
		.o_done(o_done),
		.o_r(o_r)
	);
endmodule

`default_nettype wire
