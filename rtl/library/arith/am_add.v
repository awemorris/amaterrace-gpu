/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_add: a W-bit adder with carry in and out, {co, s} = a + b + ci
 * (combinational; one CARRY4 chain on the 7 series).  Every signal addition
 * outside rtl/library/arith/ is an instance of this module, am_sub or am_addsub
 * (docs/style.md, "Arithmetic"); a unit whose additions are not used in the
 * same cycle shares one instance with its operands selected in front of it.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_add #(
	parameter W = 32
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire ci,
	output wire [W-1:0] s,
	output wire co
);
	assign {co, s} = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
endmodule

`default_nettype wire
