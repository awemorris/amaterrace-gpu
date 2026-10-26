/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_sub: a W-bit subtractor with borrow in and out, d = a - b - bi and
 * bo = 1 when the difference borrowed (a < b + bi as unsigned numbers);
 * combinational, one CARRY4 chain on the 7 series.  A negation is 0 - b.
 * See am_add for the rule that puts every signal subtraction here.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_sub #(
	parameter W = 32
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire bi,
	output wire [W-1:0] d,
	output wire bo
);
	assign {bo, d} = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
endmodule

`default_nettype wire
