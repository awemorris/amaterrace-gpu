/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_unnorm: an unnormalized coordinate, floor(u × 256) clamped to
 * [−2^28, 2^28] (the former function tu_unnorm of include/atg_tu_fn.vh;
 * tools/tumodel.py unnorm_c).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_unnorm (
	input wire [31:0] f,
	output wire signed [29:0] c
);
	wire [31:0] tx;
	atg_tu_fx32 u_tx (.f(f), .sh(5'd8), .q(tx));
	wire signed [31:0] txs = tx;
	assign c = txs < -32'sd268435456 ? -30'sd268435456 : txs > 32'sd268435456 ? 30'sd268435456 : tx[29:0];
endmodule

`default_nettype wire
