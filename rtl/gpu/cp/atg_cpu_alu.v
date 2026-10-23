/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_alu: The RV32I integer ALU and branch comparator of
 * atg_cpu_core, combinational.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/cp/atg_cpu_alu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_alu (
	input wire [3:0] op,
	input wire [31:0] a,
	input wire [31:0] b,
	output wire [31:0] y,
	output wire eq,
	output wire lt,
	output wire ltu
);
	/* spec/gpu/cp/atg_cpu_alu.md */
	assign y = 32'd0;
	assign eq = 1'd0;
	assign lt = 1'd0;
	assign ltu = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		op, a, b};
endmodule

`default_nettype wire
