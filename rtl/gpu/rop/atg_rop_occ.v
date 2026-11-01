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

(* keep_hierarchy = "yes" *)
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

`ifdef SYNTH_KINTEX7
	wire [2:0] clear_buf;
	wire [2:0] rst_n_buf;
	genvar gcb;
	generate
		for (gcb = 0; gcb < 3; gcb = gcb + 1) begin : g_occ_bufs
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_cbuf (.I0(clear), .O(clear_buf[gcb]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_rbuf (.I0(rst_n), .O(rst_n_buf[gcb]));
		end
	endgenerate
`else
	wire [2:0] clear_buf = {3{clear}};
	wire [2:0] rst_n_buf = {3{rst_n}};
`endif

	wire [15:0] count_lo = clear_buf[0] ? 16'd0 : count[15:0];
	wire [15:0] count_mid = clear_buf[1] ? 16'd0 : count[31:16];
	wire [7:0] count_hi = clear_buf[2] ? 8'd0 : count[39:32];
	wire [39:0] count_in = {count_hi, count_mid, count_lo};

	wire inc_en = inc_valid && on;
	wire [4:0] inc_val = inc_en ? inc_n : 5'd0;

	/* the count (from 0 after a clear) + this beat's samples */
	wire [39:0] count_next;
	wire cn_co_unused;
	am_add #(.W(40)) u_count (.a(count_in), .b({35'd0, inc_val}),
		.ci(1'b0), .s(count_next), .co(cn_co_unused));

	always @(posedge clk) begin
		if (!rst_n_buf[0]) begin
			on <= 1'b0;
			count[15:0] <= 16'd0;
		end else begin
			if (st_we && st_idx == GHCI_S_ROP_CTRL)
				on <= st_wdata[0];
			count[15:0] <= count_next[15:0];
		end
	end

	always @(posedge clk) begin
		if (!rst_n_buf[1]) begin
			count[31:16] <= 16'd0;
		end else begin
			count[31:16] <= count_next[31:16];
		end
	end

	always @(posedge clk) begin
		if (!rst_n_buf[2]) begin
			count[39:32] <= 8'd0;
		end else begin
			count[39:32] <= count_next[39:32];
		end
	end

	wire unused_ok = &{1'b0, st_wdata[31:1]};
endmodule

`default_nettype wire
