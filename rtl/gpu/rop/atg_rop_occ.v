/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_occ: the occlusion counter: counts the samples that pass every
 * per-sample test while ROP_CTRL[0] is 1; the command processor's QUERY
 * micro-op reads and clears it.
 *
 * count <= (clear ? 0 : count) + (inc_valid && ROP_CTRL[0] ? inc_n : 0):
 * a clear and an increment in the same cycle leave the increment.  40
 * bits, wrapping.  ROP_CTRL[0] takes effect on its STATE write.  See
 * spec/gpu/rop/atg_rop_occ.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_occ (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire inc_valid,
	input wire [4:0] inc_n,
	input wire clear,
	output reg [39:0] count
);
	`include "ghci_regs.vh"

	reg on;	/* ROP_CTRL[0] */
	always @(posedge clk)
		if (!rst_n) begin
			on <= 1'b0;
			count <= 40'd0;
		end else begin
			if (st_we && st_idx == GHCI_S_ROP_CTRL)
				on <= st_wdata[0];
			count <= (clear ? 40'd0 : count) + {35'd0, inc_valid && on ? inc_n : 5'd0};
		end

	wire unused_ok = &{1'b0, st_wdata[31:1]};
endmodule

`default_nettype wire
