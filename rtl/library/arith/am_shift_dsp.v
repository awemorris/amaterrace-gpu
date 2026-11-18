/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_shift_dsp: W-bit barrel shifter using DSP resources.
 *
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE:
 *   Mapped directly to DSP resources using use_dsp = "yes".
 * Under other platforms (ASIC / generic simulation):
 *   Identical behavior to am_shift.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_shift_dsp #(
	parameter W = 32,
	parameter SW = 5,
	parameter DIR = 0
) (
	input wire [W-1:0] a,
	input wire [SW-1:0] amt,
	input wire left,
	input wire arith,
	output wire [W-1:0] y
);
	am_shift #(
		.W(W),
		.SW(SW),
		.DIR(DIR),
		.USE_DSP(1)
	) u_shift (
		.a(a),
		.amt(amt),
		.left(left),
		.arith(arith),
		.y(y)
	);
endmodule

`default_nettype wire
