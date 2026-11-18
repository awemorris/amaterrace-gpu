/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * LUT1..LUT6: simulation models for Xilinx 7-series lookup tables.
 */

`timescale 1ns / 1ps
`default_nettype none

module LUT1 #(
	parameter [1:0] INIT = 2'h0
) (
	input wire I0,
	output wire O
);
	assign O = INIT[I0];
endmodule

module LUT2 #(
	parameter [3:0] INIT = 4'h0
) (
	input wire I0, I1,
	output wire O
);
	assign O = INIT[{I1, I0}];
endmodule

module LUT3 #(
	parameter [7:0] INIT = 8'h0
) (
	input wire I0, I1, I2,
	output wire O
);
	assign O = INIT[{I2, I1, I0}];
endmodule

module LUT4 #(
	parameter [15:0] INIT = 16'h0
) (
	input wire I0, I1, I2, I3,
	output wire O
);
	assign O = INIT[{I3, I2, I1, I0}];
endmodule

module LUT5 #(
	parameter [31:0] INIT = 32'h0
) (
	input wire I0, I1, I2, I3, I4,
	output wire O
);
	assign O = INIT[{I4, I3, I2, I1, I0}];
endmodule

module LUT6 #(
	parameter [63:0] INIT = 64'h0
) (
	input wire I0, I1, I2, I3, I4, I5,
	output wire O
);
	assign O = INIT[{I5, I4, I3, I2, I1, I0}];
endmodule

`default_nettype wire
