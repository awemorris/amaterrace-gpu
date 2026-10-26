/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_msb: the index n of the highest set bit of a W-bit a (a priority
 * encoder; combinational, LUTs: SW levels of a half select), 0 when a is
 * 0; nz: a is not 0.  W <= 2^SW.  Written without a loop: a loop in an
 * always @(*) runs again on every change of its input while the logic in
 * front of it settles, which made the simulation of the fp datapaths six
 * times slower than the former functions.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_msb #(
	parameter W = 32,
	parameter SW = 5	/* index bits */
) (
	input wire [W-1:0] a,
	output wire [SW-1:0] n,
	output wire nz
);
	localparam P = 1 << SW;
	wire [P-1:0] v0;	/* a zero-extended */
	generate
		if (P > W) begin : g_ext
			assign v0 = {{(P - W){1'b0}}, a};
		end else begin : g_eq
			assign v0 = a;
		end
	endgenerate

	/* Level k halves the vector of level k + 1: bit k of n is whether its
	 * upper half has a set bit, and that half (or the lower) goes on. */
	genvar k;
	generate
		for (k = SW - 1; k >= 0; k = k - 1) begin : g_l
			wire [(2 << k)-1:0] src;
			wire [(1 << k)-1:0] v;
			if (k == SW - 1) begin : g_top
				assign src = v0;
			end else begin : g_mid
				assign src = g_l[k + 1].v;
			end
			assign n[k] = |src[(2 << k)-1:(1 << k)];
			assign v = n[k] ? src[(2 << k)-1:(1 << k)] : src[(1 << k)-1:0];
			if (k == 0) begin : g_last
				wire unused_ok = &{1'b0, v};	/* the last half: the set bit itself */
			end
		end
	endgenerate
	assign nz = |a;
endmodule

`default_nettype wire
