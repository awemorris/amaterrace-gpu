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
 * Two counters (spec/gpu/rop/atg_rop_order.md).
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
	reg [15:0] next;	/* the oldest unretired number */
	reg [15:0] issued;	/* numbers issued so far */
	wire ex_ok = ex_valid && ex_seq == next;
	wire dx_ok = dx_valid && dx_seq == next;

	assign ex_next = next;
	assign q_valid = ex_ok || dx_ok;
	assign ex_ready = ex_ok && q_ready;
	assign dx_ready = !ex_ok && dx_ok && q_ready;
	assign q_xy = ex_ok ? ex_xy : dx_xy;
	assign q_mask = ex_ok ? ex_mask : dx_mask;
	assign q_color = ex_ok ? ex_color : 512'd0;
	assign q_depth = ex_ok ? ex_depth : dx_depth;
	assign q_dbg = !ex_ok;
	assign busy = issued != next;

	always @(posedge clk)
		if (!rst_n) begin
			next <= 16'd0;
			issued <= 16'd0;
		end else begin
			if (ord_valid)
				issued <= ord_seq + 16'd1;
			if ((ex_ready && ex_last) || (dx_ready && dx_last))
				next <= next + 16'd1;
		end
endmodule

`default_nettype wire
