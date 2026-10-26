/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_f2fix: backward compatibility wrapper around am_fp_f2fix
 * with W=24, F=8, SIGNED=1, ROUND=1, SATURATE=1, SAT_BITS=22.
 * See rtl/library/fp/am_fp_f2fix.v.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_f2fix (
	input wire [31:0] f,
	output wire [23:0] q
);
	am_fp_f2fix #(
		.W(24),
		.F(8),
		.SIGNED(1),
		.ROUND(1),
		.SATURATE(1),
		.SAT_BITS(22)
	) u_impl (
		.f(f),
		.q(q)
	);
endmodule

`default_nettype wire
