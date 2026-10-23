/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_mem: IMEM and DMEM of the CP's CPU (block RAMs with initial
 * images from $readmemh), with a fetch port, a data port and a DMA port
 * for the firmware load and the CPU's line DMA.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_mem.md.
 */

`timescale 1ns / 1ps
`default_nettype none

/* The stub does not use its file-name parameters. */
/* verilator lint_off UNUSEDPARAM */
module atg_cpu_mem #(
	parameter IMEM_WORDS = 8192,	/* IMEM size in 32-bit words (32 KiB) */
	parameter DMEM_WORDS = 4096,	/* DMEM size in words (16 KiB) */
	parameter IMEM_INIT = "",	/* $readmemh file of the IMEM image ("" = none) */
	parameter DMEM_INIT = ""	/* $readmemh file of the DMEM image */
) (
	input wire clk,
	/* Fetch (atg_cpu_core) */
	input wire i_en,
	input wire [31:0] i_addr,
	output wire [31:0] i_rdata,
	/* Data (from atg_cpu_win) */
	input wire d_en,
	input wire [3:0] d_we,
	input wire [31:0] d_addr,
	input wire [31:0] d_wdata,
	output wire [31:0] d_rdata,
	/* DMA (from atg_cpu_dma) */
	input wire x_en,
	input wire x_we,
	input wire x_imem,
	input wire [31:0] x_addr,
	input wire [31:0] x_wdata,
	output wire [31:0] x_rdata
);
/* verilator lint_on UNUSEDPARAM */
	/* spec/gpu/cp/atg_cpu_mem.md */
	assign i_rdata = 32'd0;
	assign d_rdata = 32'd0;
	assign x_rdata = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, i_en, i_addr, d_en, d_we, d_addr, d_wdata, x_en, x_we, x_imem, x_addr, x_wdata,
		(IMEM_WORDS != 0), (DMEM_WORDS != 0)};
endmodule

`default_nettype wire
