/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_div255: round(x / 255) for 0 <= x <= 255 * 255 (65025).
 * Mathematical identity:
 *   t = x + 128 => q = (t + (t >> 8)) >> 8
 * Since (x + 128) >> 8 = (x >> 8) + x[7],
 *   t + (t >> 8) = x + ((x >> 8) + 128) + x[7].
 * For x <= 65025, (x >> 8) + 128 = {x[15], ~x[15], x[14:8]} by pure bit wiring.
 * Hence q = (x + {x[15], ~x[15], x[14:8]} + x[7]) >> 8, implemented in a
 * single 17-bit am_add with ci = x[7] and no intermediate carry chains.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_div255 (
	input wire [17:0] x,
	output wire [8:0] q
);
	wire [16:0] a = {1'b0, x[15:0]};
	wire [16:0] b = {8'd0, x[15], ~x[15], x[14:8]};
	wire [16:0] s;
	wire s_co_unused;

	am_add #(.W(17)) u_add (
		.a(a),
		.b(b),
		.ci(x[7]),
		.s(s),
		.co(s_co_unused)
	);

	assign q = s[16:8];

	wire unused_ok = &{1'b0, x[17:16], s[7:0], s_co_unused};
endmodule

`default_nettype wire
