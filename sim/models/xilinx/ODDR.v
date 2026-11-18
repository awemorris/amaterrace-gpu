/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * ODDR: simulation only.  The 7 Series output DDR register in
 * OPPOSITE_EDGE mode (the only one the board tops use; Values
 * referenced: UG471): Q takes D1 at the rising edge of C and D2 at the
 * falling edge, while CE; R and S are synchronous (SRTYPE "SYNC").
 */

`timescale 1ns / 1ps
`default_nettype none

module ODDR #(
	parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
	parameter INIT = 1'b0,
	parameter SRTYPE = "SYNC"
) (
	output wire Q,
	input wire C,
	input wire CE,
	input wire D1,
	input wire D2,
	input wire R,
	input wire S
);
	reg q = INIT;

	assign Q = q;

	always @(posedge C)
		if (R)
			q <= 1'b0;
		else if (S)
			q <= 1'b1;
		else if (CE)
			q <= D1;

	always @(negedge C)
		if (R)
			q <= 1'b0;
		else if (S)
			q <= 1'b1;
		else if (CE)
			q <= D2;
endmodule

`default_nettype wire
