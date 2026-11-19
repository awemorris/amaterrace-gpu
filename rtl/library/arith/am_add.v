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
	/* verilator lint_off UNUSEDPARAM */
	parameter USE_DSP = 0
	/* verilator lint_on UNUSEDPARAM */
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
`ifdef SYNTH_ASIC
	generate
	if (W > 2 && W <= 128) begin : g_ks
		localparam LG = (W <= 4) ? 2 : ((W <= 8) ? 3 : ((W <= 16) ? 4 : ((W <= 32) ? 5 : ((W <= 64) ? 6 : 7))));
		wire [W-1:0] p_raw = a ^ b;
		wire [W-1:0] g_lvl [0:LG];
		wire [W-1:0] p_lvl [0:LG];
		assign g_lvl[0][0] = (a[0] & b[0]) | (p_raw[0] & ci);
		assign p_lvl[0][0] = 1'b0;
		genvar gi, gst;
		for (gi = 1; gi < W; gi = gi + 1) begin : g_init
			assign g_lvl[0][gi] = a[gi] & b[gi];
			assign p_lvl[0][gi] = p_raw[gi];
		end
		for (gst = 0; gst < LG; gst = gst + 1) begin : g_st
			localparam integer D = 1 << gst;
			for (gi = 0; gi < W; gi = gi + 1) begin : g_bit
				if (gi >= D) begin : g_comb
					assign g_lvl[gst+1][gi] = g_lvl[gst][gi] | (p_lvl[gst][gi] & g_lvl[gst][gi-D]);
					assign p_lvl[gst+1][gi] = p_lvl[gst][gi] & p_lvl[gst][gi-D];
				end else begin : g_pass
					assign g_lvl[gst+1][gi] = g_lvl[gst][gi];
					assign p_lvl[gst+1][gi] = p_lvl[gst][gi];
				end
			end
		end
		assign s[0] = p_raw[0] ^ ci;
		for (gi = 1; gi < W; gi = gi + 1) begin : g_sum
			assign s[gi] = p_raw[gi] ^ g_lvl[LG][gi-1];
		end
		assign co = g_lvl[LG][W-1];
		wire unused_p = &{1'b0, p_lvl[LG]};
	end else begin : g_beh
		assign {co, s} = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
	end
	endgenerate
`else
	assign {co, s} = {1'b0, a} + {1'b0, b} + {{W{1'b0}}, ci};
`endif
`endif
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
