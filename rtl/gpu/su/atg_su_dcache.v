/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dcache: The SU's data cache: 1 KiB direct-mapped (32 lines of 32
 * bytes), write-through, read-allocate, flash-invalidated; between the
 * LSU's line requests and the MC.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_dcache.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dcache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DC_BYTES = 1024	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* AMB client port (design §4.1) */
	input wire u_req_valid,
	output wire u_req_ready,
	input wire u_req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] u_req_line,
	input wire [LINE_BYTES-1:0] u_req_be,
	input wire [LINE_BYTES*8-1:0] u_req_wdata,
	input wire [7:0] u_req_tag,
	output wire u_rsp_valid,
	output wire u_rsp_write,
	output wire [7:0] u_rsp_tag,
	output wire [LINE_BYTES*8-1:0] u_rsp_rdata,
	output wire u_rsp_error,
	/* AMB client port (design §4.1) */
	output wire m_req_valid,
	input wire m_req_ready,
	output wire m_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] m_req_line,
	output wire [LINE_BYTES-1:0] m_req_be,
	output wire [LINE_BYTES*8-1:0] m_req_wdata,
	output wire [7:0] m_req_tag,
	input wire m_rsp_valid,
	input wire m_rsp_write,
	input wire [7:0] m_rsp_tag,
	input wire [LINE_BYTES*8-1:0] m_rsp_rdata,
	input wire m_rsp_error
);
	/* spec/gpu/su/atg_su_dcache.md */
	assign u_req_ready = 1'd0;
	assign u_rsp_valid = 1'd0;
	assign u_rsp_write = 1'd0;
	assign u_rsp_tag = 8'd0;
	assign u_rsp_rdata = {(LINE_BYTES*8){1'b0}};
	assign u_rsp_error = 1'd0;
	assign m_req_valid = 1'd0;
	assign m_req_write = 1'd0;
	assign m_req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign m_req_be = {LINE_BYTES{1'b0}};
	assign m_req_wdata = {(LINE_BYTES*8){1'b0}};
	assign m_req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, inv, u_req_valid, u_req_write, u_req_line, u_req_be, u_req_wdata,
		u_req_tag, m_req_ready, m_rsp_valid, m_rsp_write, m_rsp_tag, m_rsp_rdata, m_rsp_error,
		(DC_BYTES != 0)};
endmodule

`default_nettype wire
