/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ring: The command ring: RING_BASE/SIZE/WPTR/RPTR, line reads of
 * the ring through the CP's AMB port, the packet envelope (design §2.4.2),
 * class N packets to the sequencer, class V packets to the CPU, class 3
 * padding skipped.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_ring.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ring #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Control (from atg_cp_ctl) */
	input wire run,
	input wire halt,
	input wire step,
	input wire open,
	/* Class N packets (to atg_cp_seq) */
	output wire n_valid,
	input wire n_ready,
	output wire [31:0] n_data,
	output wire n_last,
	/* Class V packets (to atg_cpu) */
	output wire v_valid,
	output wire [31:0] v_addr,
	output wire [15:0] v_dwords,
	output wire [7:0] v_tag,
	input wire v_done,
	/* Status */
	output wire empty,
	output wire retire,
	output wire busy,
	/* Fault report to atg_cp_ctl (one source of its `src_*` vectors) */
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag,
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
	/* spec/gpu/cp/atg_cp_ring.md */
	assign hcr_rdata = 32'd0;
	assign n_valid = 1'd0;
	assign n_data = 32'd0;
	assign n_last = 1'd0;
	assign v_valid = 1'd0;
	assign v_addr = 32'd0;
	assign v_dwords = 16'd0;
	assign v_tag = 8'd0;
	assign empty = 1'd0;
	assign retire = 1'd0;
	assign busy = 1'd0;
	assign fault = 1'd0;
	assign fault_kind = 4'd0;
	assign fault_addr = 32'd0;
	assign fault_tag = 8'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, run, halt, step, open,
		n_ready, v_done, req_ready, rsp_valid, rsp_write, rsp_tag, rsp_rdata, rsp_error};
endmodule

`default_nettype wire
