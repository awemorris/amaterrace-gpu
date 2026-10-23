/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_index: VF index stage: walks FIRST..FIRST+COUNT (non-indexed) or
 * reads the index buffer (u16/u32), detects primitive restart, and repeats
 * for INSTANCE_COUNT instances.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/vf/atg_vf_index.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_index #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire kick,
	output wire busy,
	/* Index stream (atg_vf_index → atg_vf_asm) */
	output wire iv_valid,
	input wire iv_ready,
	output wire [31:0] iv_index,
	output wire [31:0] iv_inst,
	output wire iv_restart,
	output wire iv_last,
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
	/* spec/gpu/vf/atg_vf_index.md */
	assign busy = 1'd0;
	assign iv_valid = 1'd0;
	assign iv_index = 32'd0;
	assign iv_inst = 32'd0;
	assign iv_restart = 1'd0;
	assign iv_last = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, st_we, st_idx, st_wdata, kick, iv_ready, req_ready, rsp_valid, rsp_write,
		rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
