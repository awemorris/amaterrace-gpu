/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_popcount: counts the number of 1-bits in a W-bit vector (W <= 32).
 * Implemented as an explicit balanced binary reduction tree to guarantee
 * O(log2 W) logic depth (typically <= 2-3 LUT levels on Kintex-7).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_popcount #(
	parameter W = 16,
	parameter OW = 5
) (
	input wire [W-1:0] i_vec,
	output wire [OW-1:0] o_cnt
);
	localparam PAD_W = 32;
	wire [PAD_W-1:0] v = {{(PAD_W - W){1'b0}}, i_vec};

	/* Level 0: 16 pairs of 1-bit inputs -> 16 2-bit sums */
	wire [1:0] s0 [0:15];
	genvar g0;
	generate
	for (g0 = 0; g0 < 16; g0 = g0 + 1) begin : g_lvl0
		assign s0[g0] = {v[2*g0] & v[2*g0+1], v[2*g0] ^ v[2*g0+1]};
	end
	endgenerate

	/* Level 1: 8 pairs of 2-bit inputs -> 8 3-bit sums */
	wire [2:0] s1 [0:7];
	genvar g1;
	generate
	for (g1 = 0; g1 < 8; g1 = g1 + 1) begin : g_lvl1
		assign s1[g1] = s0[2*g1] + s0[2*g1+1];
	end
	endgenerate

	/* Level 2: 4 pairs of 3-bit inputs -> 4 4-bit sums */
	wire [3:0] s2 [0:3];
	genvar g2;
	generate
	for (g2 = 0; g2 < 4; g2 = g2 + 1) begin : g_lvl2
		assign s2[g2] = s1[2*g2] + s1[2*g2+1];
	end
	endgenerate

	/* Level 3: 2 pairs of 4-bit inputs -> 2 5-bit sums */
	wire [4:0] s3 [0:1];
	genvar g3;
	generate
	for (g3 = 0; g3 < 2; g3 = g3 + 1) begin : g_lvl3
		assign s3[g3] = s2[2*g3] + s2[2*g3+1];
	end
	endgenerate

	/* Level 4: 1 pair of 5-bit inputs -> 1 6-bit sum */
	wire [5:0] s4 = s3[0] + s3[1];

	assign o_cnt = s4[OW-1:0];

	wire unused_s4 = &{1'b0, s4[5:OW]};
endmodule

`default_nettype wire
