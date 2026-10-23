/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_amb_mux: Merges N AMB requesters into one AMB client port: fixed
 * priority (requester 0 first), the requester number in the top bits of
 * the tag, responses routed back by those bits.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/common/am_amb_mux.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_amb_mux #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter N = 2,	/* Number of requesters, 2..4 */
	parameter ID_W = 1	/* log2(N) rounded up: the tag bits [7:8-ID_W] carry the requester */
) (
	input wire clk,
	input wire rst_n,
	/* Requesters (packed, requester 0 in the low bits) */
	input wire [N-1:0] i_req_valid,
	output wire [N-1:0] i_req_ready,
	input wire [N-1:0] i_req_write,
	input wire [N*(ADDR_W-LINE_SHIFT)-1:0] i_req_line,
	input wire [N*LINE_BYTES-1:0] i_req_be,
	input wire [N*LINE_BYTES*8-1:0] i_req_wdata,
	input wire [N*8-1:0] i_req_tag,
	output wire [N-1:0] i_rsp_valid,
	output wire i_rsp_write,
	output wire [7:0] i_rsp_tag,
	output wire [LINE_BYTES*8-1:0] i_rsp_rdata,
	output wire i_rsp_error,
	/* AMB client port (design §4.1) */
	output wire o_req_valid,
	input wire o_req_ready,
	output wire o_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] o_req_line,
	output wire [LINE_BYTES-1:0] o_req_be,
	output wire [LINE_BYTES*8-1:0] o_req_wdata,
	output wire [7:0] o_req_tag,
	input wire o_rsp_valid,
	input wire o_rsp_write,
	input wire [7:0] o_rsp_tag,
	input wire [LINE_BYTES*8-1:0] o_rsp_rdata,
	input wire o_rsp_error
);
	/* spec/common/am_amb_mux.md */
	assign i_req_ready = {N{1'b0}};
	assign i_rsp_valid = {N{1'b0}};
	assign i_rsp_write = 1'd0;
	assign i_rsp_tag = 8'd0;
	assign i_rsp_rdata = {(LINE_BYTES*8){1'b0}};
	assign i_rsp_error = 1'd0;
	assign o_req_valid = 1'd0;
	assign o_req_write = 1'd0;
	assign o_req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign o_req_be = {LINE_BYTES{1'b0}};
	assign o_req_wdata = {(LINE_BYTES*8){1'b0}};
	assign o_req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, i_req_valid, i_req_write, i_req_line, i_req_be, i_req_wdata, i_req_tag,
		o_req_ready, o_rsp_valid, o_rsp_write, o_rsp_tag, o_rsp_rdata, o_rsp_error, (ID_W != 0)};
endmodule

`default_nettype wire
