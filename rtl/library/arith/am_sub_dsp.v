/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_sub_dsp: W-bit subtractor using DSP resources.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   Mapped directly to DSP slice (DSP48E1 / DSP48E2) using use_dsp = "yes".
 * Under other platforms (ASIC / generic simulation):
 *   Identical behavior to am_sub (standard behavioral subtraction).
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_sub_dsp #(
	parameter W = 32
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire bi,
	output wire [W-1:0] d,
	output wire bo
);
`ifdef _AM_XILINX_SYNTH
	(* use_dsp = "yes" *)
	/* synthesis syn_resources = "dsp" */
	wire [W:0] diff = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
	assign {bo, d} = diff;
`else
	assign {bo, d} = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
