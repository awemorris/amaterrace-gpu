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
 *   s = y + (y >> 8) + y[16]
 *   q = s[16:8]
 *
 * Implemented using a single 18-bit adder with a 3:2 compressor:
 *   s = x + (x >> 8) + (128 + x[7] + y[16])
 *   y[16] = x[16] ^ (&x[15:7])
 * The three terms have at most 3 active bits at any column, compressed in
 * one LUT level into (u, v) and added via a single 18-bit carry chain.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_div255 (
	input wire [17:0] x,
	output wire [8:0] q
);
	wire y16 = x[16] | (&x[15:7]);

	wire [16:0] u;
	wire [16:0] v;

	/* Bit 0: a=x[0], b=x[8], c=x[7]; y16 is added via adder carry-in */
	assign u[0] = x[0] ^ x[8] ^ x[7];
	wire car0 = (x[0] & x[8]) | (x[8] & x[7]) | (x[0] & x[7]);
	assign v[0] = 1'b0;

	/* Bit 1: a=x[1], b=x[9], c=0 */
	assign u[1] = x[1] ^ x[9];
	wire car1 = x[1] & x[9];
	assign v[1] = car0;

	/* Bits 2..6: a=x[i], b=x[i+8], c=0 */
	assign u[2] = x[2] ^ x[10];
	assign v[2] = car1;
	wire car2 = x[2] & x[10];

	assign u[3] = x[3] ^ x[11];
	assign v[3] = car2;
	wire car3 = x[3] & x[11];

	assign u[4] = x[4] ^ x[12];
	assign v[4] = car3;
	wire car4 = x[4] & x[12];

	assign u[5] = x[5] ^ x[13];
	assign v[5] = car4;
	wire car5 = x[5] & x[13];

	assign u[6] = x[6] ^ x[14];
	assign v[6] = car5;
	wire car6 = x[6] & x[14];

	/* Bit 7: a=x[7], b=x[15], c=1 (128) */
	assign u[7] = ~(x[7] ^ x[15]);
	assign v[7] = car6;
	wire car7 = x[7] | x[15];

	/* Bits 8..9: a=x[i], b=x[i+8], c=0 */
	assign u[8] = x[8] ^ x[16];
	assign v[8] = car7;
	wire car8 = x[8] & x[16];

	assign u[9] = x[9] ^ x[17];
	assign v[9] = car8;
	wire car9 = x[9] & x[17];

	/* Bits 10..16: a=x[i], b=0, c=0 */
	assign u[10] = x[10];
	assign v[10] = car9;

	assign u[16:11] = x[16:11];
	assign v[16:11] = 6'd0;

	wire [16:0] s;
	wire s_co_unused;
	am_add #(.W(17)) u_add (
		.a(u),
		.b(v),
		.ci(y16),
		.s(s),
		.co(s_co_unused)
	);

	assign q = s[16:8];

	wire unused_ok = &{1'b0, s_co_unused, s[7:0], x[17]};
endmodule

`default_nettype wire
