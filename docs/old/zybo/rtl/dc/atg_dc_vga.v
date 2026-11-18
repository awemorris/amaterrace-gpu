/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_vga: ZYBO VGA output: RGB888 to the board's 5-6-5 resistor DAC
 * pins, blanking outside DE, registered.  See spec/dc/atg_dc_vga.md.
 *
 * The top bits of each channel; 0 outside DE (the DAC must be black in
 * the blanking for the monitor's black level); one register stage for
 * all outputs, so the pins change together on the pixel clock (the board
 * puts these registers in the IOBs).  The syncs pass with their polarity.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_vga (
	input wire clk,
	input wire [23:0] rgb,
	input wire de,
	input wire hs,
	input wire vs,
	output reg [4:0] vga_r,
	output reg [5:0] vga_g,
	output reg [4:0] vga_b,
	output reg vga_hs,
	output reg vga_vs
);
	always @(posedge clk) begin
		vga_r <= de ? rgb[23:19] : 5'd0;
		vga_g <= de ? rgb[15:10] : 6'd0;
		vga_b <= de ? rgb[7:3] : 5'd0;
		vga_hs <= hs;
		vga_vs <= vs;
	end

	wire unused_ok = &{1'b0, rgb[18:16], rgb[9:8], rgb[2:0]};
endmodule

`default_nettype wire
