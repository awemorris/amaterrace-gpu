/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_div255: round(x / 255) for 0 <= x <= 2 * 255 * 255 (130,050).
 * Mathematical identity:
 *   y = x + 128
 *   q = (y + (y >> 8) + (y >> 16)) >> 8
 * For x <= 130,050, y[17] == 0, so (y >> 16) is exactly y[16] (1 bit).
 * Implemented using two 18-bit adders:
 *   Adder 1: y = x + 128
 *   Adder 2: s = y + (y >> 8) + y[16] (via carry-in)
 *   q = s[16:8]
 * Replaces the legacy 5-stage carry-chain cascade with a 2-stage adder.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_div255 (
	input wire [17:0] x,
	output wire [8:0] q
);
	wire [17:0] y;
	wire y_co_unused;
	am_add #(.W(18)) u_y (
		.a(x),
		.b(18'd128),
		.ci(1'b0),
		.s(y),
		.co(y_co_unused)
	);

	wire [17:0] s;
	wire s_co_unused;
	am_add #(.W(18)) u_s (
		.a(y),
		.b({8'd0, y[17:8]}),
		.ci(y[16]),
		.s(s),
		.co(s_co_unused)
	);

	assign q = s[16:8];

	wire unused_ok = &{1'b0, y_co_unused, s_co_unused, s[7:0], s[17]};
endmodule

`default_nettype wire
