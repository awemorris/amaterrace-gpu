/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_unorm: c / (2^w - 1) to the nearest fp32, w in 1, 2, 4-8, 10,
 * 11, 15, 16, 24 (the former function atg_fmt_unorm of
 * include/atg_fmt_unpack.vh; tools/fmtmodel.py): c / (2^w - 1) is 0.ccc...
 * in binary, so the leading 72 bits of c repeated give the fp32 and its
 * rounding (never a tie).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_unorm (
	input wire [23:0] c,
	input wire [5:0] w,
	output wire [31:0] f
);
	reg [79:0] r;
	always @(*)
		case (w)
		6'd1: r = {80{c[0]}};
		6'd2: r = {40{c[1:0]}};
		6'd4: r = {20{c[3:0]}};
		6'd5: r = {16{c[4:0]}};
		6'd6: r = {c[5:0], {12{c[5:0]}}, c[5:4]};
		6'd7: r = {c[6:0], {10{c[6:0]}}, c[6:4]};
		6'd8: r = {10{c[7:0]}};
		6'd10: r = {8{c[9:0]}};
		6'd11: r = {c[10:0], {6{c[10:0]}}, c[10:8]};
		6'd15: r = {c[14:0], {4{c[14:0]}}, c[14:10]};
		6'd16: r = {5{c[15:0]}};
		default: r = {c, c, c, c[23:16]};
		endcase
	/* the leading zeros (of the first 24 bits) */
	reg [4:0] lz;
	reg found;
	integer i;
	always @(*) begin
		lz = 5'd0;
		found = 1'b0;
		for (i = 0; i < 24; i = i + 1)
			if (!found && r[79 - i]) begin
				lz = i[4:0];
				found = 1'b1;
			end
	end
	/* the leading one goes to bit 71 (dropped); the mantissa [70:48], RNE */
	wire [71:0] mn;
	wire [23:0] q;
	wire [7:0] e;
	wire [1:0] carry_unused;
	am_shift #(.W(72), .SW(5)) u_mn (.a(r[79:8]), .amt(lz), .left(1'b1), .arith(1'b0), .y(mn));
	am_add #(.W(24)) u_q (.a({1'b0, mn[70:48]}), .b(24'd0), .ci(mn[47] && (mn[46:0] != 47'd0 || mn[48])),
		.s(q), .co(carry_unused[0]));
	am_sub #(.W(8)) u_e (.a(q[23] ? 8'd127 : 8'd126), .b({3'd0, lz}), .bi(1'b0), .d(e),
		.bo(carry_unused[1]));
	assign f = !found ? 32'd0 : {1'b0, e, q[23] ? 23'd0 : q[22:0]};

	wire unused_ok = &{1'b0, r[7:0], mn[71]};
endmodule

`default_nettype wire
