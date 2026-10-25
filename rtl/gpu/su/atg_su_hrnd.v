/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_hrnd: round a normalised magnitude m (bit 10 set), guard g,
 * sticky st, sign s and biased exponent e (10-bit signed) to fp16 under
 * rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, others RNE); an overflow gives
 * infinity or the largest finite by rm, an underflow zero (the former
 * function atg_su_hrnd of include/atg_su_fp16.vh; tools/gsi1fp.py).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_hrnd (
	input wire s,
	input wire signed [9:0] e,
	input wire [10:0] m,
	input wire g,
	input wire st,
	input wire [2:0] rm,
	output wire [15:0] h
);
	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = s && (g || st);
		3'd3: up = !s && (g || st);
		3'd4: up = g;
		default: up = g && (st || m[0]);
		endcase
	/* the rounded magnitude, the exponent + 1 when it carries */
	wire [11:0] mr0;
	wire signed [9:0] er;
	wire [1:0] carry_unused;
	am_add #(.W(12)) u_mr (.a({1'b0, m}), .b(12'd0), .ci(up), .s(mr0), .co(carry_unused[0]));
	am_add #(.W(10)) u_er (.a(e), .b(10'd0), .ci(mr0[11]), .s(er), .co(carry_unused[1]));
	wire [11:0] mr = mr0[11] ? {1'b0, mr0[11:1]} : mr0;
	assign h = er >= 10'sd31 ? (rm == 3'd1 || (rm == 3'd2 && !s) || (rm == 3'd3 && s) ? {s, 5'h1E, 10'h3FF} :
		{s, 5'h1F, 10'd0}) : er <= 10'sd0 ? {s, 15'd0} : {s, er[4:0], mr[9:0]};

	wire unused_ok = &{1'b0, mr[11:10]};
endmodule

`default_nettype wire
