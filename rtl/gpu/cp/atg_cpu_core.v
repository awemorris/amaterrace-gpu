/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_core: The RV32IM pipeline of the CP's control processor: fetch,
 * decode/execute, writeback (3 stages), Machine mode only, one interrupt
 * line, no CSRs but none needed (the control window replaces them).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_core.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_core (
	input wire clk,
	input wire rst_n,
	input wire run,
	output wire stopped,
	input wire irq,
	/* Instruction port (IMEM, synchronous BRAM read) */
	output wire i_en,
	output wire [31:0] i_addr,
	input wire [31:0] i_rdata,
	/* Data port (to atg_cpu_win) */
	output wire d_valid,
	output wire d_write,
	output wire [31:0] d_addr,
	output wire [31:0] d_wdata,
	output wire [3:0] d_be,
	input wire d_ready,
	input wire [31:0] d_rdata,
	/* Faults (to atg_cpu_fw) */
	output wire fault,
	output wire [31:0] fault_pc
);
	/* spec/gpu/cp/atg_cpu_core.md */
	assign stopped = 1'd0;
	assign i_en = 1'd0;
	assign i_addr = 32'd0;
	assign d_valid = 1'd0;
	assign d_write = 1'd0;
	assign d_addr = 32'd0;
	assign d_wdata = 32'd0;
	assign d_be = 4'd0;
	assign fault = 1'd0;
	assign fault_pc = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, run, irq, i_rdata, d_ready, d_rdata};

	/* The children, wired to constants until the pipeline exists. */
	wire [31:0] alu_y;
	wire alu_eq, alu_lt, alu_ltu;
	wire md_busy, md_done;
	wire [31:0] md_y;

	atg_cpu_alu alu (
		.op(4'd0), .a(32'd0), .b(32'd0),
		.y(alu_y), .eq(alu_eq), .lt(alu_lt), .ltu(alu_ltu)
	);

	atg_cpu_muldiv muldiv (
		.clk(clk), .rst_n(rst_n), .start(1'b0), .op(3'd0), .a(32'd0), .b(32'd0),
		.busy(md_busy), .done(md_done), .y(md_y)
	);

	wire unused_kids = &{1'b0, alu_y, alu_eq, alu_lt, alu_ltu, md_busy, md_done, md_y};
endmodule

`default_nettype wire
