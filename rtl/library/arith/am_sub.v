/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_sub: a W-bit subtractor with borrow in and out, d = a - b - bi and
 * bo = 1 when the difference borrowed (a < b + bi as unsigned numbers);
 * combinational, one CARRY4/CARRY8 chain on Xilinx FPGAs when USE_DSP = 0.
 * A negation is 0 - b.
 * See am_add for the rule that puts every signal subtraction here.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   USE_DSP = 0 (default): explicitly mapped to FPGA fabric carry chain
 *                          with use_dsp = "no" and syn_resources = "carry".
 *   USE_DSP = 1:           explicitly allows mapping to DSP slice (DSP48E1/E2).
 * Under other platforms (ASIC/generic simulation):
 *   Clean behavioral subtraction without vendor attributes.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_sub #(
	parameter W = 32,
	parameter USE_DSP = 0
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire bi,
	output wire [W-1:0] d,
	output wire bo
);
`ifdef _AM_XILINX_SYNTH
	generate
	if (USE_DSP != 0) begin : g_dsp
		(* use_dsp = "yes" *)
		/* synthesis syn_resources = "dsp" */
		wire [W:0] diff = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
		assign {bo, d} = diff;
	end else begin : g_carry
		(* use_dsp = "no" *)
		/* synthesis syn_resources = "carry" */
		wire [W:0] diff = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
		assign {bo, d} = diff;
	end
	endgenerate
`else
	assign {bo, d} = {1'b0, a} - {1'b0, b} - {{W{1'b0}}, bi};
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
