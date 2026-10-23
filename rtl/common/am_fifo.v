/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fifo: a synchronous first-word-fall-through FIFO of 2^DEPTH_LOG2
 * entries of W bits, in distributed RAM.  in_ready is "not full",
 * out_valid "not empty"; out_data is the oldest entry while out_valid.
 * A push and a pop in the same cycle are allowed when both are possible.
 * count is the number of entries.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fifo #(
	parameter W = 8,
	parameter DEPTH_LOG2 = 2
) (
	input wire clk,
	input wire rst_n,
	input wire in_valid,
	output wire in_ready,
	input wire [W-1:0] in_data,
	output wire out_valid,
	input wire out_ready,
	output wire [W-1:0] out_data,
	output wire [DEPTH_LOG2:0] count
);
	localparam [DEPTH_LOG2:0] DEPTH = 1 << DEPTH_LOG2;

	reg [W-1:0] mem [0:(1 << DEPTH_LOG2) - 1];
	reg [DEPTH_LOG2:0] wp;
	reg [DEPTH_LOG2:0] rp;

	wire [DEPTH_LOG2:0] used = wp - rp;
	wire push = in_valid && in_ready;
	wire pop = out_valid && out_ready;

	assign count = used;
	assign in_ready = used != DEPTH;
	assign out_valid = used != {(DEPTH_LOG2 + 1){1'b0}};
	assign out_data = mem[rp[DEPTH_LOG2-1:0]];

	always @(posedge clk) begin
		if (push)
			mem[wp[DEPTH_LOG2-1:0]] <= in_data;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			wp <= {(DEPTH_LOG2 + 1){1'b0}};
			rp <= {(DEPTH_LOG2 + 1){1'b0}};
		end else begin
			if (push)
				wp <= wp + 1'b1;
			if (pop)
				rp <= rp + 1'b1;
		end
	end
endmodule

`default_nettype wire
