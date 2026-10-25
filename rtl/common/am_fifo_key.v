/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fifo_key: am_fifo (first-word-fall-through, 2^DEPTH_LOG2 entries of
 * W bits) whose entries also keep a KEY_W-bit key, and that tells whether
 * an entry with a given key is in it: has = some entry now in the FIFO was
 * pushed with in_key == key (combinational, from the entries and key; an
 * entry popped in this cycle still counts, one pushed in this cycle does
 * not yet).  am_axi_master keeps the order keys of its outstanding bursts
 * in it.  A push and a pop in the same cycle are allowed when both are
 * possible.  count is the number of entries.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fifo_key #(
	parameter W = 8,
	parameter KEY_W = 8,
	parameter DEPTH_LOG2 = 2
) (
	input wire clk,
	input wire rst_n,
	input wire in_valid,
	output wire in_ready,
	input wire [W-1:0] in_data,
	input wire [KEY_W-1:0] in_key,
	output wire out_valid,
	input wire out_ready,
	output wire [W-1:0] out_data,
	output wire [DEPTH_LOG2:0] count,
	input wire [KEY_W-1:0] key,
	output wire has
);
	localparam D = 1 << DEPTH_LOG2;
	localparam [DEPTH_LOG2:0] DEPTH = D;

	reg [W-1:0] mem [0:D-1];
	reg [D*KEY_W-1:0] keys;	/* slot i's key at i * KEY_W */
	reg [D-1:0] full;	/* slot i holds an entry */
	reg [DEPTH_LOG2:0] wp;
	reg [DEPTH_LOG2:0] rp;

	wire [DEPTH_LOG2:0] used = wp - rp;
	wire push = in_valid && in_ready;
	wire pop = out_valid && out_ready;

	assign count = used;
	assign in_ready = used != DEPTH;
	assign out_valid = used != {(DEPTH_LOG2 + 1){1'b0}};
	assign out_data = mem[rp[DEPTH_LOG2-1:0]];

	reg match;
	integer i;

	always @(*) begin
		match = 1'b0;
		for (i = 0; i < D; i = i + 1)
			if (full[i] && keys[i*KEY_W +: KEY_W] == key)
				match = 1'b1;
	end

	assign has = match;

	always @(posedge clk) begin
		if (push)
			mem[wp[DEPTH_LOG2-1:0]] <= in_data;
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			wp <= {(DEPTH_LOG2 + 1){1'b0}};
			rp <= {(DEPTH_LOG2 + 1){1'b0}};
			full <= {D{1'b0}};
			keys <= {(D * KEY_W){1'b0}};
		end else begin
			if (push)
				wp <= wp + 1'b1;
			if (pop)
				rp <= rp + 1'b1;
			for (i = 0; i < D; i = i + 1) begin
				if (pop && rp[DEPTH_LOG2-1:0] == i[DEPTH_LOG2-1:0])
					full[i] <= 1'b0;
				if (push && wp[DEPTH_LOG2-1:0] == i[DEPTH_LOG2-1:0]) begin
					full[i] <= 1'b1;
					keys[i*KEY_W +: KEY_W] <= in_key;
				end
			end
		end
	end
endmodule

`default_nettype wire
