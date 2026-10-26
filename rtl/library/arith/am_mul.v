/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_mul: an AW x BW multiplier for the DSP48E1 slices: p = a * b, both
 * signed (SIGNED = 1, two's complement) or both unsigned, the full
 * AW + BW bits.  LAT = 0 is combinational; LAT = n registers the product
 * n times (en enables every stage), so that the DSP's MREG and PREG (and
 * further registers, retimed into the cascade) can be used.  The
 * multiply is marked use_dsp, so that Vivado maps it to DSPs and not to
 * LUTs at any width; one DSP48E1 takes 25 x 18 signed bits.
 * A unit whose multiplies are not used in the same cycle shares one
 * am_mul with its operands selected in front of it.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_mul #(
	parameter AW = 18,
	parameter BW = 18,
	parameter SIGNED = 0,
	parameter LAT = 0
) (
	input wire clk,
	input wire en,
	input wire [AW-1:0] a,
	input wire [BW-1:0] b,
	output wire [AW+BW-1:0] p
);
	(* use_dsp = "yes" *) wire [AW+BW-1:0] m;
	generate
	if (SIGNED != 0) begin : g_s
		assign m = $signed(a) * $signed(b);
	end else begin : g_u
		assign m = a * b;
	end
	if (LAT == 0) begin : g_c
		assign p = m;
	end else begin : g_r
		reg [AW+BW-1:0] r [0:LAT-1];
		integer i;
		always @(posedge clk)
			if (en) begin
				r[0] <= m;
				for (i = 1; i < LAT; i = i + 1)
					r[i] <= r[i-1];
			end
		assign p = r[LAT-1];
	end
	endgenerate

	wire unused_ok = &{1'b0, clk, en};
endmodule

`default_nettype wire
