/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_atom: The MC's atomic unit: one read-modify-write at a time for
 * the SUs' atomics (design §4.1): reads the line, applies the operation to
 * one word, writes the line back, returns the old value. An MC client of
 * its own (placed next to atg_mc in atg_top).
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/mc/atg_mc_atom.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_atom #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter NATOM = 1,	/* Requesters (one per SU) */
	parameter AW = 1	/* clog2(NATOM), at least 1 */
) (
	input wire clk,
	input wire rst_n,
	/* Atomic requests (packed, SU 0 in the low bits) */
	input wire [NATOM-1:0] at_valid,
	output wire [NATOM-1:0] at_ready,
	input wire [NATOM*4-1:0] at_op,
	input wire [NATOM*30-1:0] at_addr,
	input wire [NATOM*32-1:0] at_a,
	input wire [NATOM*32-1:0] at_b,
	output wire [NATOM-1:0] at_rsp_valid,
	output wire [31:0] at_old,
	output wire at_error,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	/* spec/gpu/mc/atg_mc_atom.md */
	assign at_ready = {NATOM{1'b0}};
	assign at_rsp_valid = {NATOM{1'b0}};
	assign at_old = 32'd0;
	assign at_error = 1'd0;
	assign busy = 1'd0;
	assign req_valid = 1'd0;
	assign req_write = 1'd0;
	assign req_line = {(ADDR_W-LINE_SHIFT){1'b0}};
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {(LINE_BYTES*8){1'b0}};
	assign req_tag = 8'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, at_valid, at_op, at_addr, at_a, at_b, req_ready, rsp_valid, rsp_write,
		rsp_tag, rsp_rdata, rsp_error, (AW != 0)};
endmodule

`default_nettype wire
