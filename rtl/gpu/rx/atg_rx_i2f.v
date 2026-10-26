/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_i2f: backward compatibility wrapper around am_fp_fix2f.
 * See rtl/library/fp/am_fp_fix2f.v.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_i2f #(
	parameter W = 17,       /* input bits, sign included */
	parameter F = 0         /* fraction bits of the input */
) (
	input wire [W-1:0] v,
	output wire [31:0] f
);
	am_fp_fix2f #(
		.W(W),
		.F(F),
		.SIGNED(1)
	) u_impl (
		.v(v),
		.f(f)
	);
endmodule

`default_nettype wire
