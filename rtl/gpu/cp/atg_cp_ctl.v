/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_ctl: The CP's state machine (design §2.6): CTRL
 * (RUN/RESET/HALT/STEP/WDT_EN), STATUS, KICK from the host, HALT and
 * quiesce, the RESET order of design §1.3, the watchdog, and
 * FAULT_ADDR/FAULT_INFO from all fault sources.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cp_ctl.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_ctl #(
	parameter NSRC = 8,	/* Number of fault sources (0 ring, 1 seq, 2 state, 3 fence, 4 SU, 5 CPU, 6 BLT, 7 other blocks) */
	parameter WDT_RESET = 32'h10000000	/* WDT_CYCLES after reset (2^28) */
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
	/* Inputs */
	input wire mc_idle,
	input wire mem_ready,
	input wire [7:0] busy_in,
	input wire ring_empty,
	input wire cmd_active,
	input wire mc_fault,
	input wire [7:0] mc_fault_client,
	input wire [31:0] mc_fault_addr,
	input wire mc_fault_write,
	input wire [NSRC-1:0] src_fault,
	input wire [NSRC*4-1:0] src_kind,
	input wire [NSRC*32-1:0] src_addr,
	input wire [NSRC*8-1:0] src_tag,
	/* Outputs */
	output wire run,
	output wire halt,
	output wire quiesce,
	output wire mc_flush,
	output wire core_rst_n,
	output wire open,
	output wire [3:0] cp_state,
	output wire [2:0] host_kick,
	output wire step,
	output wire ev_halted,
	output wire ev_fault,
	output wire ev_wdt
);
	/* spec/gpu/cp/atg_cp_ctl.md */
	assign hcr_rdata = 32'd0;
	assign run = 1'd0;
	assign halt = 1'd0;
	assign quiesce = 1'd0;
	assign mc_flush = 1'd0;
	assign core_rst_n = 1'd0;
	assign open = 1'd0;
	assign cp_state = 4'd0;
	assign host_kick = 3'd0;
	assign step = 1'd0;
	assign ev_halted = 1'd0;
	assign ev_fault = 1'd0;
	assign ev_wdt = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, mc_idle, mem_ready,
		busy_in, ring_empty, cmd_active, mc_fault, mc_fault_client, mc_fault_addr,
		mc_fault_write, src_fault, src_kind, src_addr, src_tag, (WDT_RESET != 0)};
endmodule

`default_nettype wire
