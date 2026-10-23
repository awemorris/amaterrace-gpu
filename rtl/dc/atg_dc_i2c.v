/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_i2c: A small I2C master for the KC705's ADV7511 HDMI transmitter
 * configuration (I2C_CTRL/DATA/STATUS of design §5.1).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_i2c.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_i2c #(
	parameter CLK_DIV = 250	/* gclk cycles per quarter SCL period (100 MHz → 100 kHz) */
) (
	input wire clk,
	input wire rst_n,
	input wire i_we,
	input wire [1:0] i_idx,
	input wire [31:0] i_wdata,
	output wire [31:0] i_rdata,
	output wire scl_t,
	input wire scl_i,
	output wire sda_t,
	input wire sda_i
);
	/* spec/dc/atg_dc_i2c.md */
	assign i_rdata = 32'd0;
	assign scl_t = 1'd0;
	assign sda_t = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, i_we, i_idx, i_wdata, scl_i, sda_i, (CLK_DIV != 0)};
endmodule

`default_nettype wire
