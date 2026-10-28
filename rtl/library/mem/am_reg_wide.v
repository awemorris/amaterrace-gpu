/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_reg_wide: Dedicated Wide Register (>128 bits: 256, 512, 640, 702, 1024 bits).
 *
 * Used for wide pipeline stages, cache lines, and multi-quad vector coordinates.
 * Strictly prevents synthesis tools from inferring Shift Register LUTs (SRLs) or RAMs,
 * guaranteeing clean standard flip-flop arrays with synchronous clock enable.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_reg_wide #(
	parameter W = 512,
	parameter [W-1:0] RESET_VAL = {W{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [W-1:0] d,
	output reg [W-1:0] q
);
`ifdef _AM_XILINX_SYNTH
	(* shreg_extract = "no" *)
	/* synthesis syn_srl_style = "registers", syn_preserve = 1 */
`endif
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			q <= RESET_VAL;
		else if (en)
			q <= d;
	end
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
