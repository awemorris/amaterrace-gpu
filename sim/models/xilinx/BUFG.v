/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * BUFG: simulation only.  The global clock buffer: O follows I.
 */

`timescale 1ns / 1ps
`default_nettype none

module BUFG (
	input wire I,
	output wire O
);
	assign O = I;
endmodule

`default_nettype wire
