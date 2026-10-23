/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_order: ROP ordering (design §3.8): retires fragment quads in
 * sequence-number order from SU 0's exports and the RX's direct quads;
 * tells the SU which sequence it waits for.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/rop/atg_rop_order.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_order (
	input wire clk,
	input wire rst_n,
	/* Fragment output of SU 0 (atg_su ex_*) */
	input wire ex_valid,
	output wire ex_ready,
	input wire [15:0] ex_seq,
	input wire [31:0] ex_xy,
	input wire [3:0] ex_mask,
	input wire [511:0] ex_color,
	input wire [127:0] ex_depth,
	input wire ex_last,
	output wire [15:0] ex_next,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	input wire dx_valid,
	output wire dx_ready,
	input wire [15:0] dx_seq,
	input wire [31:0] dx_xy,
	input wire [3:0] dx_mask,
	input wire [127:0] dx_depth,
	input wire dx_last,
	/* Issued sequence numbers (atg_rx ord_*) */
	input wire ord_valid,
	input wire [15:0] ord_seq,
	/* To atg_rop_ds */
	output wire q_valid,
	input wire q_ready,
	output wire [31:0] q_xy,
	output wire [3:0] q_mask,
	output wire [511:0] q_color,
	output wire [127:0] q_depth,
	output wire q_dbg,
	output wire busy
);
	/* spec/gpu/rop/atg_rop_order.md */
	assign ex_ready = 1'd0;
	assign ex_next = 16'd0;
	assign dx_ready = 1'd0;
	assign q_valid = 1'd0;
	assign q_xy = 32'd0;
	assign q_mask = 4'd0;
	assign q_color = 512'd0;
	assign q_depth = 128'd0;
	assign q_dbg = 1'd0;
	assign busy = 1'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, ex_valid, ex_seq, ex_xy, ex_mask, ex_color, ex_depth, ex_last, dx_valid,
		dx_seq, dx_xy, dx_mask, dx_depth, dx_last, ord_valid, ord_seq, q_ready};
endmodule

`default_nettype wire
