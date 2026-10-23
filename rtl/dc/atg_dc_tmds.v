/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_tmds: DVI/HDMI TMDS encoding (8b/10b with DC balance, control
 * symbols in blanking) of the three channels; the 10-bit symbols are
 * serialised by OSERDESE2 in the board top (vendor primitive).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/dc/atg_dc_tmds.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_tmds (
	input wire clk,
	input wire rst_n,
	input wire [23:0] rgb,
	input wire de,
	input wire hs,
	input wire vs,
	output wire [29:0] tmds
);
	/* spec/dc/atg_dc_tmds.md */
	assign tmds = 30'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, rgb, de, hs, vs};
endmodule

`default_nettype wire
