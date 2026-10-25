/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_acc: a row address of the blitter's engines (atg_blt_2d,
 * atg_blt_rsv): go loads r = b and starts r += y x s by shift and add, one
 * bit of y a cycle (idle when the bits are used up: at most 17 cycles);
 * add (when idle) adds d to r (the next row).  32-bit wrap.
 * See spec/gpu/blt/atg_blt_acc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_acc #(
	parameter W = 32
) (
	input wire clk,
	input wire rst_n,
	input wire go,
	input wire [16:0] y,
	input wire [W-1:0] s,
	input wire [W-1:0] b,
	input wire add,
	input wire [W-1:0] d,
	output reg [W-1:0] r,
	output wire idle
);
	reg [16:0] my;
	reg [W-1:0] ms;

	assign idle = my == 17'd0;

	/* One adder for both sums (a step of the multiply, or the final add: never in one cycle). */
	wire [W-1:0] sum;
	wire sum_co_unused;

	am_add #(.W(W)) a_sum (.a(r), .b(idle ? d : ms), .ci(1'b0), .s(sum), .co(sum_co_unused));

	always @(posedge clk)
		if (!rst_n) begin
			my <= 17'd0;
		end else if (go) begin
			my <= y;
			ms <= s;
			r <= b;
		end else if (!idle) begin
			if (my[0])
				r <= sum;
			my <= my >> 1;
			ms <= ms << 1;
		end else if (add)
			r <= sum;

	wire unused_ok = &{1'b0, sum_co_unused};
endmodule

`default_nettype wire
