/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_seq: The class N µop sequencer: takes µop packets from the ring
 * or from the firmware (UOP_FIFO), writes STATE, kicks the blocks, waits
 * for idle, and hands fences, results and WAIT_FENCE to atg_cp_fence.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_seq.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_seq (
	input wire clk,
	input wire rst_n,
	/* µop packets from the ring (atg_cp_ring) */
	input wire n_valid,
	output wire n_ready,
	input wire [31:0] n_data,
	input wire n_last,
	/* µop packets from the firmware (atg_cpu UOP_FIFO) */
	input wire fw_valid,
	output wire fw_ready,
	input wire [31:0] fw_data,
	input wire fw_last,
	input wire fw_active,
	input wire halt,
	/* STATE writes (to atg_cp_state) */
	output wire uop_we,
	output wire [8:0] uop_idx,
	output wire [31:0] uop_wdata,
	/* Kicks (one-cycle pulses) */
	output wire blt_kick,
	output wire draw_kick,
	output wire cs_kick,
	output wire lc_kick,
	output wire raw_kick,
	output wire [3:0] inv,
	output wire perf_reset,
	input wire [7:0] busy_in,
	input wire vsync,
	/* Fences (to atg_cp_fence) */
	output wire f_valid,
	input wire f_ready,
	output wire [1:0] f_op,
	output wire [31:0] f_addr,
	output wire [31:0] f_value,
	output wire [31:0] f_aux,
	output wire f_irq,
	input wire f_busy,
	/* Status */
	output wire busy,
	output wire cmd_active,
	/* Fault report to atg_cp_ctl (one source of its `src_*` vectors) */
	output wire fault,
	output wire [3:0] fault_kind,
	output wire [31:0] fault_addr,
	output wire [7:0] fault_tag
);
	/* spec/gpu/cp/atg_cp_seq.md */
	assign n_ready = 1'd0;
	assign fw_ready = 1'd0;
	assign uop_we = 1'd0;
	assign uop_idx = 9'd0;
	assign uop_wdata = 32'd0;
	assign blt_kick = 1'd0;
	assign draw_kick = 1'd0;
	assign cs_kick = 1'd0;
	assign lc_kick = 1'd0;
	assign raw_kick = 1'd0;
	assign inv = 4'd0;
	assign perf_reset = 1'd0;
	assign f_valid = 1'd0;
	assign f_op = 2'd0;
	assign f_addr = 32'd0;
	assign f_value = 32'd0;
	assign f_aux = 32'd0;
	assign f_irq = 1'd0;
	assign busy = 1'd0;
	assign cmd_active = 1'd0;
	assign fault = 1'd0;
	assign fault_kind = 4'd0;
	assign fault_addr = 32'd0;
	assign fault_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, n_valid, n_data, n_last, fw_valid, fw_data, fw_last, fw_active, halt,
		busy_in, vsync, f_ready, f_busy};
endmodule

`default_nettype wire
