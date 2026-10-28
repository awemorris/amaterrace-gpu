/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_addsub: a W-bit adder-subtractor, s = sub ? a - b : a + b, with co the
 * carry out of a + (sub ? ~b : b) + sub (for a subtraction 1 means no
 * borrow); combinational, one CARRY4/CARRY8 chain and the XOR of b on Xilinx
 * FPGAs when USE_DSP = 0.  For a unit that adds and subtracts in different
 * cycles (or a subtraction chosen at run time) one instance instead of an
 * am_add and an am_sub.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   USE_DSP = 0 (default): explicitly mapped to FPGA fabric carry chain
 *                          with use_dsp = "no" and syn_resources = "carry".
 *   USE_DSP = 1:           explicitly allows mapping to DSP slice (DSP48E1/E2).
 * Under other platforms (ASIC/generic simulation):
 *   Clean behavioral adder-subtractor without vendor attributes.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_addsub #(
	parameter W = 32,
	parameter USE_DSP = 0
) (
	input wire [W-1:0] a,
	input wire [W-1:0] b,
	input wire sub,
	output wire [W-1:0] s,
	output wire co
);
	wire [W-1:0] bx = b ^ {W{sub}};

`ifdef _AM_XILINX_SYNTH
	generate
	if (USE_DSP != 0) begin : g_dsp
		(* use_dsp = "yes" *)
		/* synthesis syn_resources = "dsp" */
		wire [W:0] sum = {1'b0, a} + {1'b0, bx} + {{W{1'b0}}, sub};
		assign {co, s} = sum;
	end else begin : g_carry
		(* use_dsp = "no" *)
		/* synthesis syn_resources = "carry" */
		wire [W:0] sum = {1'b0, a} + {1'b0, bx} + {{W{1'b0}}, sub};
		assign {co, s} = sum;
	end
	endgenerate
`else
	assign {co, s} = {1'b0, a} + {1'b0, bx} + {{W{1'b0}}, sub};
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
