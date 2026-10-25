/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_addsub: a W-bit adder-subtractor, s = sub ? a - b : a + b, with co the
 * carry out of a + (sub ? ~b : b) + sub (for a subtraction 1 means no
 * borrow); combinational, one CARRY4 chain and the XOR of b on the 7
 * series.  For a unit that adds and subtracts in different cycles (or a
 * subtraction chosen at run time) one instance instead of an am_add and an
 * am_sub.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_addsub #(
	parameter W = 32
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire sub,
	output wire [W-1:0] s,
	output wire co
);
	wire [W-1:0] bx = b ^ {W{sub}};

	assign {co, s} = {1'b0, a} + {1'b0, bx} + {{W{1'b0}}, sub};
endmodule

`default_nettype wire
