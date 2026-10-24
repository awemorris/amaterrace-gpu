/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * BSCANE2: simulation only.  A behavioural stand-in for the 7 Series
 * BSCANE2 primitive (the ports of Vivado's unisims; Values referenced:
 * UG470, BSCANE2) whose outputs come from the testbench through tasks
 * that walk the TAP as a cable would after selecting this USER register
 * (the IR scan is not modelled: SEL is 1 from the first scan on):
 *
 *   idle(n)          n TCK cycles in Run-Test/Idle;
 *   scan(n, din, dout)  Select-DR, Capture-DR, n bits of Shift-DR (bit 0
 *                    first, TDO sampled before each rising edge, the last
 *                    bit leaves Shift-DR), Exit1-DR, Update-DR, back to
 *                    Run-Test/Idle.
 *
 * CAPTURE, SHIFT and UPDATE are high for the TCK cycle of their state, so
 * logic that samples them on the rising edge of TCK acts once per state,
 * as with the real primitive.  TCK_HALF is half the TCK period in ns.
 */

`timescale 1ns / 1ps
`default_nettype none

module BSCANE2 #(
	parameter integer JTAG_CHAIN = 1,
	parameter DISABLE_JTAG = "FALSE",
	parameter integer TCK_HALF = 20
) (
	output wire CAPTURE,
	output wire DRCK,
	output wire RESET,
	output wire RUNTEST,
	output wire SEL,
	output wire SHIFT,
	output wire TCK,
	output wire TDI,
	output wire TMS,
	output wire UPDATE,
	input wire TDO
);
	reg r_tck = 1'b0;
	reg r_tdi = 1'b0;
	reg r_sel = 1'b0;
	reg r_capture = 1'b0;
	reg r_shift = 1'b0;
	reg r_update = 1'b0;
	reg r_runtest = 1'b0;

	assign CAPTURE = r_capture;
	assign SHIFT = r_shift;
	assign UPDATE = r_update;
	assign SEL = r_sel;
	assign TCK = r_tck;
	assign TDI = r_tdi;
	assign RUNTEST = r_runtest;
	assign RESET = 1'b0;
	assign TMS = 1'b0;
	assign DRCK = r_sel && (r_capture || r_shift) ? r_tck : 1'b1;

	/* One TCK cycle: the outputs change on the falling edge (as the TAP's
	 * state outputs do), then the rising edge. */
	task cycle;
		begin
			#(TCK_HALF) r_tck = 1'b1;
			#(TCK_HALF) r_tck = 1'b0;
		end
	endtask

	task idle;
		input integer n;
		integer k;
		begin
			r_runtest = 1'b1;
			for (k = 0; k < n; k = k + 1)
				cycle;
		end
	endtask

	task scan;
		input integer n;
		input [127:0] din;
		output [127:0] dout;
		integer k;
		begin
			dout = 128'd0;
			r_sel = 1'b1;
			r_runtest = 1'b0;
			cycle;	/* Select-DR-Scan */
			r_capture = 1'b1;
			cycle;	/* Capture-DR */
			r_capture = 1'b0;
			r_shift = 1'b1;
			for (k = 0; k < n; k = k + 1) begin
				r_tdi = din[k];
				#(TCK_HALF) dout[k] = TDO;
				r_tck = 1'b1;
				#(TCK_HALF) r_tck = 1'b0;
			end
			r_shift = 1'b0;
			cycle;	/* Exit1-DR */
			r_update = 1'b1;
			cycle;	/* Update-DR */
			r_update = 1'b0;
			idle(1);
		end
	endtask
endmodule

`default_nettype wire
