/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_div255: round(x / 255) for x <= 2 × 255 × 255, without a wide
 * adder (the former function div255 of atg_rop_blend): y = x + 128; the
 * low bytes give only a carry, c = (y[7:0] + y[15:8] + y[18:16]) >> 8,
 * and the result is (y >> 8) + (y >> 16) + c.  Equal to
 * (y + (y >> 8) + (y >> 16)) >> 8, checked exact against round(x / 255)
 * over the whole range on 2026-10-24.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_div255 (
	input wire [17:0] x,
	output wire [8:0] q
);
	wire [18:0] y;
	wire [9:0] lo0, lo;
	wire [10:0] hi0, hi;
	wire y_co_unused, l0_co_unused, l_co_unused, h0_co_unused, h_co_unused;
	am_add #(.W(19)) u_y (.a({1'b0, x}), .b(19'd128), .ci(1'b0), .s(y), .co(y_co_unused));
	am_add #(.W(10)) u_lo0 (.a({2'd0, y[7:0]}), .b({2'd0, y[15:8]}), .ci(1'b0), .s(lo0),
		.co(l0_co_unused));
	am_add #(.W(10)) u_lo (.a(lo0), .b({7'd0, y[18:16]}), .ci(1'b0), .s(lo), .co(l_co_unused));
	am_add #(.W(11)) u_hi0 (.a(y[18:8]), .b({8'd0, y[18:16]}), .ci(1'b0), .s(hi0), .co(h0_co_unused));
	am_add #(.W(11)) u_hi (.a(hi0), .b({9'd0, lo[9:8]}), .ci(1'b0), .s(hi), .co(h_co_unused));

	assign q = hi[8:0];

	wire unused_ok = &{1'b0, lo[7:0], hi[10:9]};
endmodule

`default_nettype wire
