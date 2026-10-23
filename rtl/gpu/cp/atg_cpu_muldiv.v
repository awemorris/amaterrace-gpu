/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_muldiv: The RV32M unit: MUL/MULH/MULHSU/MULHU on a DSP (3
 * cycles) and DIV/DIVU/REM/REMU by a 32-step restoring divider.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_muldiv.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_muldiv (
	input wire clk,
	input wire rst_n,
	input wire start,
	input wire [2:0] op,
	input wire [31:0] a,
	input wire [31:0] b,
	output wire busy,
	output wire done,
	output wire [31:0] y
);
	/* spec/gpu/cp/atg_cpu_muldiv.md */
	assign busy = 1'd0;
	assign done = 1'd0;
	assign y = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, start, op, a, b};
endmodule

`default_nettype wire
