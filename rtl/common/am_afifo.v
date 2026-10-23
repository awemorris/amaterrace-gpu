/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_afifo: an asynchronous first-word-fall-through FIFO of 2^DEPTH_LOG2
 * entries of W bits between two clock domains (gclk and mclk when they
 * differ, the PCIe and JTAG clocks).  The pointers cross in Gray code
 * through two flops each; the storage is distributed RAM written in the
 * write domain and read asynchronously in the read domain (the entry being
 * read is stable: the write pointer that made it visible passed the
 * synchroniser after the write).
 *
 * Each side has its own synchronous active-low reset.  Both resets must be
 * asserted together for at least three cycles of the slower clock and the
 * FIFO must be idle on both sides meanwhile; resetting one side alone
 * loses the FIFO's contents.  w_ready is "not full" and r_valid "not
 * empty", both seen with the other side's pointer up to three cycles late,
 * so they are conservative.  DEPTH_LOG2 is at least 2.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_afifo #(
	parameter W = 8,
	parameter DEPTH_LOG2 = 3
) (
	input wire w_clk,
	input wire w_rst_n,
	input wire w_valid,
	output wire w_ready,
	input wire [W-1:0] w_data,

	input wire r_clk,
	input wire r_rst_n,
	output wire r_valid,
	input wire r_ready,
	output wire [W-1:0] r_data
);
	localparam P = DEPTH_LOG2 + 1;

	reg [W-1:0] mem [0:(1 << DEPTH_LOG2) - 1];

	/* Write side: binary and Gray pointers, the read pointer synchronised. */
	reg [P-1:0] w_bin;
	reg [P-1:0] w_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray2;

	/* Read side. */
	reg [P-1:0] r_bin;
	reg [P-1:0] r_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray2;

	wire w_push = w_valid && w_ready;
	wire [P-1:0] w_bin_next = w_bin + {{(P - 1){1'b0}}, w_push};
	wire [P-1:0] w_gray_next = w_bin_next ^ (w_bin_next >> 1);

	/* Full: the Gray write pointer equals the read pointer with the two
	 * top bits inverted. */
	wire [P-1:0] full_gray = {~w_rgray2[P-1:P-2], w_rgray2[P-3:0]};

	assign w_ready = w_gray != full_gray;

	always @(posedge w_clk) begin
		if (w_push)
			mem[w_bin[DEPTH_LOG2-1:0]] <= w_data;
	end

	always @(posedge w_clk) begin
		if (!w_rst_n) begin
			w_bin <= {P{1'b0}};
			w_gray <= {P{1'b0}};
			w_rgray1 <= {P{1'b0}};
			w_rgray2 <= {P{1'b0}};
		end else begin
			w_bin <= w_bin_next;
			w_gray <= w_gray_next;
			w_rgray1 <= r_gray;
			w_rgray2 <= w_rgray1;
		end
	end

	wire r_pop = r_valid && r_ready;
	wire [P-1:0] r_bin_next = r_bin + {{(P - 1){1'b0}}, r_pop};
	wire [P-1:0] r_gray_next = r_bin_next ^ (r_bin_next >> 1);

	assign r_valid = r_gray != r_wgray2;
	assign r_data = mem[r_bin[DEPTH_LOG2-1:0]];

	always @(posedge r_clk) begin
		if (!r_rst_n) begin
			r_bin <= {P{1'b0}};
			r_gray <= {P{1'b0}};
			r_wgray1 <= {P{1'b0}};
			r_wgray2 <= {P{1'b0}};
		end else begin
			r_bin <= r_bin_next;
			r_gray <= r_gray_next;
			r_wgray1 <= w_gray;
			r_wgray2 <= r_wgray1;
		end
	end
endmodule

`default_nettype wire
