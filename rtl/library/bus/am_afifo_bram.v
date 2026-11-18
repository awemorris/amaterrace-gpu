/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_afifo_bram: An asynchronous BRAM-inferable FIFO with FWFT (First-Word
 * Fall-Through) output using an integrated skid buffer (am_skid).
 *
 * Infers dual-port block RAM (RAMB18E1 / RAMB36E1) with synchronous reads.
 * The 1-cycle BRAM read latency is completely hidden by the read-side
 * skid buffer, providing zero-bubble 100% sustained throughput and
 * 0-cycle fall-through presentation on the read interface.
 *
 * Watermark output r_count is available in the r_clk domain.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_afifo_bram #(
	parameter W = 32,
	parameter DEPTH_LOG2 = 11
) (
	// Write domain (w_clk)
	input wire w_clk,
	input wire w_rst_n,
	input wire w_valid,
	output wire w_ready,
	input wire [W-1:0] w_data,

	// Read domain (r_clk)
	input wire r_clk,
	input wire r_rst_n,
	output wire r_valid,
	input wire r_ready,
	output wire [W-1:0] r_data,

	// Watermark count (r_clk domain)
	output wire [DEPTH_LOG2:0] r_count
);
	localparam P = DEPTH_LOG2 + 1;

	// Dual-port Block RAM inferable memory array
	(* ram_style = "block" *) reg [W-1:0] mem [0:(1 << DEPTH_LOG2) - 1];

	// -------------------------------------------------------------
	// Write side (w_clk domain)
	// -------------------------------------------------------------
	reg [P-1:0] w_bin;
	reg [P-1:0] w_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] w_rgray2;

	wire w_push = w_valid && w_ready;
	wire [P-1:0] w_bin_next;
	wire unused_w_co;
	am_add #(.W(P)) u_w_bin (
		.a(w_bin), .b({P{1'b0}}), .ci(w_push), .s(w_bin_next), .co(unused_w_co)
	);
	wire [P-1:0] w_gray_next = w_bin_next ^ (w_bin_next >> 1);

	// Full condition: write Gray equals read Gray with top 2 bits inverted
	wire [P-1:0] full_gray = {~w_rgray2[P-1:P-2], w_rgray2[P-3:0]};
	assign w_ready = (w_gray != full_gray);

	always @(posedge w_clk) begin
		if (w_push)
			mem[w_bin[DEPTH_LOG2-1:0]] <= w_data;
	end

	always @(posedge w_clk) begin
		if (!w_rst_n) begin
			w_bin    <= {P{1'b0}};
			w_gray   <= {P{1'b0}};
			w_rgray1 <= {P{1'b0}};
			w_rgray2 <= {P{1'b0}};
		end else begin
			w_bin    <= w_bin_next;
			w_gray   <= w_gray_next;
			w_rgray1 <= r_gray;
			w_rgray2 <= w_rgray1;
		end
	end

	// -------------------------------------------------------------
	// Read side (r_clk domain) - BRAM Synchronous Read
	// -------------------------------------------------------------
	reg [P-1:0] r_bin;
	reg [P-1:0] r_gray;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray1;
	(* ASYNC_REG = "TRUE" *) reg [P-1:0] r_wgray2;

	// BRAM synchronous read registers
	reg [W-1:0] ram_rdata;
	reg         ram_rvalid;

	// Skid buffer interface signals
	wire skid_in_ready;

	// Skid buffer space tracking:
	// A new BRAM read can be launched if:
	// 1) Skid buffer is empty (!r_valid), OR
	// 2) Downstream is consuming an entry this cycle (r_ready), OR
	// 3) Skid buffer has room (skid_in_ready) AND no data is currently in-flight (!ram_rvalid).
	wire fetch_space = !r_valid || r_ready || (skid_in_ready && !ram_rvalid);
	wire bram_has_data = (r_gray != r_wgray2);
	wire ram_ren = bram_has_data && fetch_space;

	wire [P-1:0] r_bin_next;
	wire unused_r_co;
	am_add #(.W(P)) u_r_bin (
		.a(r_bin), .b({P{1'b0}}), .ci(ram_ren), .s(r_bin_next), .co(unused_r_co)
	);
	wire [P-1:0] r_gray_next = r_bin_next ^ (r_bin_next >> 1);

	// Synchronous BRAM read data register
	always @(posedge r_clk) begin
		if (ram_ren)
			ram_rdata <= mem[r_bin[DEPTH_LOG2-1:0]];
	end

	// Valid tracker for synchronous BRAM read
	always @(posedge r_clk) begin
		if (!r_rst_n)
			ram_rvalid <= 1'b0;
		else
			ram_rvalid <= ram_ren;
	end

	always @(posedge r_clk) begin
		if (!r_rst_n) begin
			r_bin    <= {P{1'b0}};
			r_gray   <= {P{1'b0}};
			r_wgray1 <= {P{1'b0}};
			r_wgray2 <= {P{1'b0}};
		end else begin
			r_bin    <= r_bin_next;
			r_gray   <= r_gray_next;
			r_wgray1 <= w_gray;
			r_wgray2 <= r_wgray1;
		end
	end

	// -------------------------------------------------------------
	// FWFT Skid Buffer Instance
	// -------------------------------------------------------------
	am_skid #(
		.WIDTH(W)
	) u_skid (
		.clk(r_clk),
		.rst_n(r_rst_n),
		.in_valid(ram_rvalid),
		.in_ready(skid_in_ready),
		.in_data(ram_rdata),
		.out_valid(r_valid),
		.out_ready(r_ready),
		.out_data(r_data)
	);

	// -------------------------------------------------------------
	// Watermark calculation (r_clk domain)
	// -------------------------------------------------------------
	// Convert synchronized write Gray pointer to binary
	wire [P-1:0] w_bin_in_rclk;
	assign w_bin_in_rclk[P-1] = r_wgray2[P-1];
	genvar gi;
	generate
		for (gi = 0; gi < P - 1; gi = gi + 1) begin : g2b
			assign w_bin_in_rclk[gi] = ^r_wgray2[P-1:gi];
		end
	endgenerate

	// Entries in BRAM: (w_bin_in_rclk - r_bin)
	wire [P-1:0] bram_count;
	wire unused_bram_bo;
	am_sub #(.W(P)) u_bram_count (
		.a(w_bin_in_rclk), .b(r_bin), .bi(1'b0), .d(bram_count), .bo(unused_bram_bo)
	);

	// Entries in skid buffer: 0, 1, or 2
	wire [1:0] skid_entries = {!skid_in_ready, (r_valid ^ !skid_in_ready)};

	// Total entries in buffer and read pipeline (skid_entries + ram_rvalid)
	wire [1:0] buf_count;
	wire unused_buf_co;
	am_add #(.W(2)) u_buf_count (
		.a(skid_entries), .b(2'b00), .ci(ram_rvalid), .s(buf_count), .co(unused_buf_co)
	);

	// Total FIFO watermark: bram_count + buf_count
	wire [P-1:0] total_count;
	wire unused_tot_co;
	am_add #(.W(P)) u_tot_count (
		.a(bram_count), .b({{(P-2){1'b0}}, buf_count}), .ci(1'b0), .s(total_count), .co(unused_tot_co)
	);

	assign r_count = total_count;

endmodule

`default_nettype wire
