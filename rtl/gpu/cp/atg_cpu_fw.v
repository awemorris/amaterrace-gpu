/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_fw: The CPFW extended capability (design §2.4.10):
 * CPFW_CTRL/STATUS/IBASE/IWORDS/DBASE/DWORDS/VERSION/MBOX0-3 on the HCR
 * (0x120-0x13F), the image reload sequence, the core's run/reset, and the
 * firmware fault report.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_fw.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_fw (
	input wire clk,
	input wire rst_n,
	/* HCR register snoop (from atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output wire [31:0] hcr_rdata,
	/* Window sub-bus (from atg_cpu_win) */
	input wire sb_we,
	input wire sb_re,
	input wire [5:0] sb_idx,
	input wire [31:0] sb_wdata,
	output wire [31:0] sb_rdata,
	/* To atg_cpu_dma */
	output wire ld_start,
	output wire ld_imem,
	output wire [31:0] ld_addr,
	output wire [31:0] ld_words,
	input wire ld_done,
	input wire ld_error,
	/* Core control */
	output wire core_rst_n,
	output wire core_run,
	input wire core_stopped,
	input wire core_fault,
	input wire [31:0] core_fault_pc,
	input wire halt_req,
	input wire open,
	/* Fault (to atg_cp_ctl, source 5) */
	output wire fault,
	output wire [31:0] fault_addr
);
	/* spec/gpu/cp/atg_cpu_fw.md */
	assign hcr_rdata = 32'd0;
	assign sb_rdata = 32'd0;
	assign ld_start = 1'd0;
	assign ld_imem = 1'd0;
	assign ld_addr = 32'd0;
	assign ld_words = 32'd0;
	assign core_rst_n = 1'd0;
	assign core_run = 1'd0;
	assign fault = 1'd0;
	assign fault_addr = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, hcr_we, hcr_widx, hcr_wdata, hcr_wmask, hcr_ridx, sb_we, sb_re, sb_idx,
		sb_wdata, ld_done, ld_error, core_stopped, core_fault, core_fault_pc, halt_req, open};
endmodule

`default_nettype wire
