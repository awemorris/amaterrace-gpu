/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tgen: The DC's timing generator in the pixel clock: h/v counters,
 * DE/HSYNC/VSYNC, pixel pop from the FIFO, format conversion to RGB888,
 * the test pattern, frame start and vsync events.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_tgen.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tgen (
	input wire clk,
	input wire rst_n,
	input wire enable,
	input wire test_pattern,
	input wire [1:0] format,
	input wire [287:0] timing,
	input wire px_valid,
	output wire px_ready,
	input wire [31:0] px_data,
	output wire [23:0] rgb,
	output wire de,
	output wire hs,
	output wire vs,
	output wire frame_toggle,
	output wire vsync_toggle,
	output wire underflow_toggle,
	output wire [11:0] line
);
	/* spec/dc/atg_dc_tgen.md */
	assign px_ready = 1'd0;
	assign rgb = 24'd0;
	assign de = 1'd0;
	assign hs = 1'd0;
	assign vs = 1'd0;
	assign frame_toggle = 1'd0;
	assign vsync_toggle = 1'd0;
	assign underflow_toggle = 1'd0;
	assign line = 12'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, enable, test_pattern, format, timing, px_valid, px_data};
endmodule

`default_nettype wire
