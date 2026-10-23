/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_icache: The SU's instruction cache: 2 KiB direct-mapped (256
 * instructions), lines of LINE_BYTES from the AMB, invalidated by
 * LOAD_PROGRAM / INVALIDATE[3].
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_icache.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_icache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter IC_BYTES = 2048	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire ic_req,
	output wire ic_ready,
	input wire [31:0] ic_addr,
	output wire ic_rvalid,
	output wire [63:0] ic_rdata,
	input wire inv,
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
	/* spec/gpu/su/atg_su_icache.md */
	assign ic_ready = 1'd0;
	assign ic_rvalid = 1'd0;
	assign ic_rdata = 64'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, ic_req, ic_addr, inv, req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata,
		rsp_error, (IC_BYTES != 0)};
endmodule

`default_nettype wire
