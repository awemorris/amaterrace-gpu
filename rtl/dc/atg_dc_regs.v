/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_regs: The DC's registers (design §5.1): DC_ID/VERSION/CAPS, CTRL,
 * STATUS, IRQ, FB_*, timing, FRAME_COUNT, PCLK_SEL, the I2C window, and in
 * the standalone bitstream the GHCI header that makes the DC a
 * display-only GHCI device.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_regs.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_regs #(
	parameter STANDALONE = 0,	/* 1: a DC-only GHCI device (ZYBO bitstream 2): GHCI header at 0x000, DISP registers at 0x200; 0: DISP registers at BASE (KC705 0x10000) */
	parameter BASE = 17'h10000,	/* Window of the DISP registers when STANDALONE = 0 */
	parameter HAS_I2C = 0	/* ADV7511 I2C master present (KC705, DC_CAPS[2]) */
) (
	input wire clk,
	input wire rst_n,
	/* Register bus (am_axi_regs; the DC decodes its own window) */
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,
	/* Configuration to atg_dc_dma and atg_dc_tgen */
	output wire enable,
	output wire test_pattern,
	output wire [1:0] format,
	output wire [31:0] fb_next,
	output wire [31:0] fb_stride,
	output wire [31:0] fb_size,
	output wire [287:0] timing,
	output wire pclk_sel,
	output wire dc_reset,
	/* Status (gclk, already synchronised by atg_dc) */
	input wire ev_vsync,
	input wire ev_flip,
	input wire ev_underflow,
	input wire dma_idle,
	input wire [11:0] line,
	output wire [31:0] fb_base,
	output wire irq,
	/* I2C window (to atg_dc_i2c) */
	output wire i2c_we,
	output wire [1:0] i2c_idx,
	output wire [31:0] i2c_wdata,
	input wire [31:0] i2c_rdata
);
	/* spec/dc/atg_dc_regs.md */
	assign reg_rdata = 32'd0;
	assign enable = 1'd0;
	assign test_pattern = 1'd0;
	assign format = 2'd0;
	assign fb_next = 32'd0;
	assign fb_stride = 32'd0;
	assign fb_size = 32'd0;
	assign timing = 288'd0;
	assign pclk_sel = 1'd0;
	assign dc_reset = 1'd0;
	assign fb_base = 32'd0;
	assign irq = 1'd0;
	assign i2c_we = 1'd0;
	assign i2c_idx = 2'd0;
	assign i2c_wdata = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, reg_wr, reg_waddr, reg_wdata, reg_wstrb, reg_rd, reg_raddr, ev_vsync,
		ev_flip, ev_underflow, dma_idle, line, i2c_rdata, (STANDALONE != 0), (BASE != 0),
		(HAS_I2C != 0)};
endmodule

`default_nettype wire
