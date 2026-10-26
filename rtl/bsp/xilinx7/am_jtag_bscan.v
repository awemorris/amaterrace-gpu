/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_jtag_bscan: Xilinx 7-series JTAG boundary scan wrapper (BSCANE2 + BUFG).
 * Enabled when SYNTH_KINTEX7 is defined.
 * See spec/bsp/xilinx7/am_jtag_bscan.md.
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
module am_jtag_bscan #(
	parameter JTAG_CHAIN = 2
) (
	output wire tck,
	output wire sel,
	output wire capture,
	output wire shift,
	output wire update,
	output wire tdi,
	input wire tdo
);
	wire tck_raw;

	/* verilator lint_off PINCONNECTEMPTY */
	BSCANE2 #(.JTAG_CHAIN(JTAG_CHAIN)) bscan (
		.CAPTURE(capture), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel), .SHIFT(shift),
		.TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(update), .TDO(tdo)
	);
	/* verilator lint_on PINCONNECTEMPTY */

	BUFG tck_bufg (.I(tck_raw), .O(tck));
endmodule
`endif

`default_nettype wire
