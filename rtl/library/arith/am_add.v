/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_add: a W-bit adder with carry in and out, {co, s} = a + b + ci
 * (combinational; one CARRY4/CARRY8 chain on Xilinx FPGAs when USE_DSP = 0).
 * Every signal addition outside rtl/library/arith/ is an instance of this
 * module, am_sub or am_addsub (docs/style.md, "Arithmetic"); a unit whose
 * additions are not used in the same cycle shares one instance with its
 * operands selected in front of it.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   USE_DSP = 0 (default): explicitly mapped to FPGA fabric carry chain
 *                          with use_dsp = "no" and syn_resources = "carry".
 *   USE_DSP = 1:           explicitly allows mapping to DSP slice (DSP48E1/E2).
 * Under other platforms (ASIC/generic simulation):
 *   Clean behavioral addition without vendor attributes.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_add #(
	parameter W = 32,
	parameter USE_DSP = 0
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire ci,
	output wire [W-1:0] s,
	output wire co
);
`ifdef _AM_XILINX_SYNTH
	generate
	if (USE_DSP != 0) begin : g_dsp
		(* use_dsp = "yes" *)
		/* synthesis syn_resources = "dsp" */
		wire [W:0] sum = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
		assign {co, s} = sum;
	end else begin : g_carry
		(* use_dsp = "no" *)
		/* synthesis syn_resources = "carry" */
		wire [W:0] sum = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
		assign {co, s} = sum;
	end
	endgenerate
`else
	assign {co, s} = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
