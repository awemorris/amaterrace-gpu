/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_dma: The DC's scan-out DMA: reads the framebuffer FB_BASE line by
 * line (FB_STRIDE, FB_SIZE) through the AMB and pushes pixel words into
 * the pixel FIFO towards pclk.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_dma.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_dma #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire enable,
	input wire frame_start,
	input wire [31:0] fb_base,
	input wire [31:0] fb_stride,
	input wire [31:0] fb_size,
	input wire [1:0] format,
	output wire px_valid,
	input wire px_ready,
	output wire [31:0] px_data,
	output wire idle,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	/* spec/dc/atg_dc_dma.md */
	assign px_valid = 1'd0;
	assign px_data = 32'd0;
	assign idle = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, enable, frame_start, fb_base, fb_stride, fb_size, format, px_ready,
		req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
