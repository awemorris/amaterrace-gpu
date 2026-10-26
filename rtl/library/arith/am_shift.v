/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift: a W-bit barrel shifter by a variable amount (combinational).
 * Optimized with Bit Reversal: uses a single sign-extended right shifter
 * for left, logical right, and arithmetic right shifts.
 *
 * Left shift reverses input bit order at zero cost (wiring only), passes
 * through the right shifter with 0-fill, and reverses the output bits.
 * Arithmetic right shifts sign bit; logical right shifts 0.
 * Eliminates duplicate barrel shifters and post-shift multiplexer levels.
 *
 * An amount of W or more gives 0 (or all sign bits).
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
	/* Bit reversal of input for left shift (wiring only, 0 LUTs) */
	wire [W-1:0] rev_a;
	genvar gi;
	generate
	for (gi = 0; gi < W; gi = gi + 1) begin : g_rev_in
		assign rev_a[gi] = a[W - 1 - gi];
	end
	endgenerate

	wire [W-1:0] in_data = left ? rev_a : a;
	wire fill = (!left && arith) ? a[W - 1] : 1'b0;

	/*
	 * Extended by 1 bit with fill to leverage Verilog signed shift (>>>).
	 * If amt >= W, all W bits are filled with fill.
	 */
	wire signed [W:0] ext_data = {fill, in_data};
	wire signed [W:0] shifted_ext = ext_data >>> amt;
	wire [W-1:0] shifted = shifted_ext[W-1:0];

	/* Bit reversal of output for left shift (wiring only, 0 LUTs) */
	wire [W-1:0] rev_shifted;
	generate
	for (gi = 0; gi < W; gi = gi + 1) begin : g_rev_out
		assign rev_shifted[gi] = shifted[W - 1 - gi];
	end
	endgenerate

	assign y = left ? rev_shifted : shifted;

	wire unused_ok = &{1'b0, shifted_ext[W]};
endmodule

`default_nettype wire
