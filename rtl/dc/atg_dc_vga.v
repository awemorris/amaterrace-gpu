/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_vga: ZYBO VGA output: RGB888 to the board's 5-6-5 resistor DAC
 * pins, blanking outside DE, registered.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_vga.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_vga (
	input wire clk,
	input wire [23:0] rgb,
	input wire de,
	input wire hs,
	input wire vs,
	output wire [4:0] vga_r,
	output wire [5:0] vga_g,
	output wire [4:0] vga_b,
	output wire vga_hs,
	output wire vga_vs
);
	/* spec/dc/atg_dc_vga.md */
	assign vga_r = 5'd0;
	assign vga_g = 6'd0;
	assign vga_b = 5'd0;
	assign vga_hs = 1'd0;
	assign vga_vs = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rgb, de, hs, vs};
endmodule

`default_nettype wire
