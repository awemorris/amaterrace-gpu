/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_arb: The MC's arbiter: one grant per cycle among the clients with
 * a request; the HIGH_MASK clients by fixed priority (lowest number
 * first), the others round-robin (design §4.1).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/mc/atg_mc_arb.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_arb #(
	parameter NCLIENT = 2,	/* Clients (≤ 32) */
	parameter CW = 1,	/* Client number width (clog2(NCLIENT), at least 1) */
	parameter HIGH_MASK = 2'b01	/* Fixed-priority clients (NCLIENT bits) */
) (
	input wire clk,
	input wire rst_n,
	input wire [NCLIENT-1:0] req,
	input wire hold,
	output wire gnt_valid,
	output wire [CW-1:0] gnt_idx,
	input wire take,
	input wire flush
);
	/* spec/gpu/mc/atg_mc_arb.md */
	assign gnt_valid = 1'd0;
	assign gnt_idx = {CW{1'b0}};

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, req, hold, take, flush, (HIGH_MASK != 0)};
endmodule

`default_nettype wire
