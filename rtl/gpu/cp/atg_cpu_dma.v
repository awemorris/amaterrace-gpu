/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_dma: The CPU's line DMA between GPU memory (AMB) and IMEM/DMEM:
 * the firmware's heap ↔ DMEM copies (window DMA_*) and the CPFW image load
 * (from atg_cpu_fw).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_dma.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_dma #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* Window sub-bus (from atg_cpu_win) */
	input wire sb_we,
	input wire sb_re,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output wire [31:0] sb_rdata,
	/* Image load (from atg_cpu_fw) */
	input wire ld_start,
	input wire ld_imem,
	input wire [31:0] ld_addr,
	input wire [31:0] ld_words,
	output wire ld_done,
	output wire ld_error,
	/* Memory port (atg_cpu_mem x_*) */
	output wire x_en,
	output wire x_we,
	output wire x_imem,
	output wire [31:0] x_addr,
	output wire [31:0] x_wdata,
	input wire [31:0] x_rdata,
	output wire wait_amb,
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
	/* spec/gpu/cp/atg_cpu_dma.md */
	assign sb_rdata = 32'd0;
	assign ld_done = 1'd0;
	assign ld_error = 1'd0;
	assign x_en = 1'd0;
	assign x_we = 1'd0;
	assign x_imem = 1'd0;
	assign x_addr = 32'd0;
	assign x_wdata = 32'd0;
	assign wait_amb = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, sb_we, sb_re, sb_idx, sb_wdata, ld_start, ld_imem, ld_addr, ld_words,
		x_rdata, req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
