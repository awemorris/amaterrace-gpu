/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_add_dsp: W-bit adder using DSP resources.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   Mapped directly to DSP slice (DSP48E1 / DSP48E2) using use_dsp = "yes".
 * Under other platforms (ASIC / generic simulation):
 *   Identical behavior to am_add (standard behavioral addition).
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_add_dsp #(
	parameter W = 32
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire ci,
	output wire [W-1:0] s,
	output wire co
);
`ifdef _AM_XILINX_SYNTH
	(* use_dsp = "yes" *)
	/* synthesis syn_resources = "dsp" */
	wire [W:0] sum = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
	assign {co, s} = sum;
`else
	assign {co, s} = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
