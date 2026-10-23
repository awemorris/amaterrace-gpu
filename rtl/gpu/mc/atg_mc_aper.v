/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_aper: The aperture check of an AMB request: the line is inside
 * [APERTURE_BASE, APERTURE_LIMIT) (line granularity).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/mc/atg_mc_aper.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_aper #(
	parameter ADDR_W = 32,	/* Address width */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire [ADDR_W-LINE_SHIFT-1:0] line,
	input wire [ADDR_W-1:0] base,
	input wire [ADDR_W-1:0] limit,
	output wire ok
);
	/* spec/gpu/mc/atg_mc_aper.md */
	assign ok = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		line, base, limit};
endmodule

`default_nettype wire
