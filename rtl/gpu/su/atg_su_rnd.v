/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rnd: round a normalised magnitude m (bit 23 set), guard g,
 * sticky st, sign s and biased exponent e (12-bit signed) to fp32 under
 * rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, 7 RNE; 5 and 6 round to odd (the
 * last bit set when inexact, an overflow gives the largest finite);
 * underflow flushes to zero (the former function atg_su_rnd of
 * include/atg_su_fp.vh; tools/gsi1fp.py).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rnd (
	input wire s,
	input wire signed [11:0] e,
	input wire [23:0] m,
	input wire g,
	input wire st,
	input wire [2:0] rm,
	output wire [31:0] r
);
	reg up;
	always @(*)
		case (rm)
		3'd1, 3'd5, 3'd6: up = 1'b0;
		3'd2: up = s && (g || st);
		3'd3: up = !s && (g || st);
		3'd4: up = g;
		default: up = g && (st || m[0]);
		endcase
	/* the rounded magnitude, the exponent + 1 when it carries */
	wire [24:0] mr0;
	wire signed [11:0] er;
	wire [1:0] carry_unused;
	am_add #(.W(25)) u_mr (.a({1'b0, m[23:1], m[0] | ((rm == 3'd5 || rm == 3'd6) && (g || st))}), .b(25'd0),
		.ci(up), .s(mr0), .co(carry_unused[0]));
	am_add #(.W(12)) u_er (.a(e), .b(12'd0), .ci(mr0[24]), .s(er), .co(carry_unused[1]));
	wire [24:0] mr = mr0[24] ? {1'b0, mr0[24:1]} : mr0;
	assign r = er >= 12'sd255 ? (rm == 3'd1 || rm == 3'd5 || rm == 3'd6 || (rm == 3'd2 && !s) || (rm == 3'd3 && s) ?
		{s, 8'hFE, 23'h7FFFFF} : {s, 8'hFF, 23'd0}) : er <= 12'sd0 ? {s, 31'd0} : {s, er[7:0], mr[22:0]};

	wire unused_ok = &{1'b0, mr[24:23]};
endmodule

`default_nettype wire
