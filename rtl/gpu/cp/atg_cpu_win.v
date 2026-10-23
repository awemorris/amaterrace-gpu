/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_win: The CPU's data-bus decoder and control window: routes
 * loads/stores to DMEM or to the window registers (class V packet,
 * UOP_FIFO, STATE read, FENCE_LAST, cycle counter, RESULT, interrupt), and
 * the sub-bus to atg_cpu_dma and atg_cpu_fw.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_win.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_win #(
	parameter UOP_DEPTH_LOG2 = 4	/* UOP_FIFO depth log2 (16 dwords) */
) (
	input wire clk,
	input wire rst_n,
	/* Core data port */
	input wire d_valid,
	input wire d_write,
	input wire [31:0] d_addr,
	input wire [31:0] d_wdata,
	input wire [3:0] d_be,
	output wire d_ready,
	output wire [31:0] d_rdata,
	/* DMEM data port (atg_cpu_mem) */
	output wire m_en,
	output wire [3:0] m_we,
	output wire [31:0] m_addr,
	output wire [31:0] m_wdata,
	input wire [31:0] m_rdata,
	/* Sub-bus to atg_cpu_dma and atg_cpu_fw */
	output wire sb_we,
	output wire sb_re,
	output wire [5:0] sb_idx,
	output wire [31:0] sb_wdata,
	input wire [31:0] dma_rdata,
	input wire [31:0] fw_rdata,
	/* Class V packet (from atg_cp_ring) */
	input wire v_valid,
	input wire [31:0] v_addr,
	input wire [15:0] v_dwords,
	input wire [7:0] v_tag,
	output wire v_done,
	/* µops to atg_cp_seq */
	output wire fw_valid,
	input wire fw_ready,
	output wire [31:0] fw_data,
	output wire fw_last,
	output wire fw_active,
	/* Other */
	output wire [8:0] st_ridx,
	input wire [31:0] st_rdata,
	input wire [31:0] fence_last,
	input wire fence_ev,
	input wire halt_req,
	output wire irq,
	output wire ev_result,
	output wire stall
);
	/* spec/gpu/cp/atg_cpu_win.md */
	assign d_ready = 1'd0;
	assign d_rdata = 32'd0;
	assign m_en = 1'd0;
	assign m_we = 4'd0;
	assign m_addr = 32'd0;
	assign m_wdata = 32'd0;
	assign sb_we = 1'd0;
	assign sb_re = 1'd0;
	assign sb_idx = 6'd0;
	assign sb_wdata = 32'd0;
	assign v_done = 1'd0;
	assign fw_valid = 1'd0;
	assign fw_data = 32'd0;
	assign fw_last = 1'd0;
	assign fw_active = 1'd0;
	assign st_ridx = 9'd0;
	assign irq = 1'd0;
	assign ev_result = 1'd0;
	assign stall = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, d_valid, d_write, d_addr, d_wdata, d_be, m_rdata, dma_rdata, fw_rdata,
		v_valid, v_addr, v_dwords, v_tag, fw_ready, st_rdata, fence_last, fence_ev, halt_req,
		(UOP_DEPTH_LOG2 != 0)};
endmodule

`default_nettype wire
