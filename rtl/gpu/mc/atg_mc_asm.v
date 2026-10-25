/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_asm: an assembly buffer of the MC's root (spec/gpu/mc/atg_mc.md):
 * it takes a request's header flit and, for a write, its data flit from
 * the tree (t_*), and offers the complete request (full, head, data) until
 * take.  A flit is taken when the buffer is empty or its request is taken
 * in the same cycle (t_ready).  rst_n and flush empty it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_asm #(
	parameter LINE_BYTES = 32
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire t_valid,
	output wire t_ready,
	input wire [LINE_BYTES*8-1:0] t_data,
	input wire t_last,
	output reg full,
	output reg [LINE_BYTES*8-1:0] head,
	output reg [LINE_BYTES*8-1:0] data,
	input wire take
);
	/* A write's header is in, its data flit is not. */
	reg hdr;

	assign t_ready = !full || take;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			hdr <= 1'b0;
			full <= 1'b0;
			head <= {LINE_BYTES*8{1'b0}};
			data <= {LINE_BYTES*8{1'b0}};
		end else begin
			if (take)
				full <= 1'b0;
			if (t_valid && t_ready) begin
				if (!hdr) begin
					head <= t_data;
					hdr <= !t_last;
					full <= t_last;
				end else begin
					data <= t_data;
					hdr <= 1'b0;
					full <= 1'b1;
				end
			end
		end
	end
endmodule

`default_nettype wire
