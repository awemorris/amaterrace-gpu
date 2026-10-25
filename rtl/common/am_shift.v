/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift: a W-bit barrel shifter by a variable amount (combinational,
 * LUTs: log2(W) levels of multiplexers): left (y = a << amt), or right,
 * logical (a >> amt) or arithmetic (the sign of a shifted in, a >>> amt).
 * An amount of W or more gives 0 (or all sign bits).  left and arith may
 * be constants; synthesis keeps only the direction used.  Every shift by a
 * signal amount outside rtl/common/ is an instance of this module (a shift
 * by a constant amount is wiring and stays where it is).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_shift #(
	parameter W = 32,
	parameter SW = 5	/* amount bits */
) (
	input wire [W-1:0] a,
	input wire [SW-1:0] amt,
	input wire left,
	input wire arith,
	output wire [W-1:0] y
);
	wire signed [W-1:0] sa = a;
	wire [W-1:0] l = a << amt;
	wire [W-1:0] ra = sa >>> amt;	/* its own wire: a signed shift stays signed */
	wire [W-1:0] rl = a >> amt;
	wire [W-1:0] r = arith ? ra : rl;

	assign y = left ? l : r;
endmodule

`default_nettype wire
