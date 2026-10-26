/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_hazard: Pixel Lock CAM and RAW Hazard Tracker for ROP pipeline.
 *
 * Tracks in-flight quad coordinates {RT[1:0], Y[15:1], X[15:1]} across the
 * ROP pipeline.
 * - Compares incoming quad tag against 16 parallel CAM entries.
 * - Stalls allocation (alloc_ready = 0) when an in-flight quad matches the same
 *   pixel coordinates (preventing RAW hazard).
 * - Issues non-conflicting quads with 0-wait (1 beat/cycle throughput).
 * - Releases CAM entry when quad commits at the end of the pipeline.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_hazard #(
	parameter NUM_ENTRIES = 16,
	parameter TAG_W = 32	/* {RT[1:0], Y[15:1], X[15:1]} */
) (
	input wire clk,
	input wire rst_n,

	/* Allocation interface (pipeline issue stage) */
	input wire alloc_valid,
	output wire alloc_ready,	/* not full and no RAW hazard */
	input wire [TAG_W-1:0] alloc_tag,
	output reg [3:0] alloc_id,	/* allocated entry ID */

	/* Release interface (pipeline commit stage) */
	input wire release_valid,
	input wire [3:0] release_id
);
	reg [NUM_ENTRIES-1:0] valid;
	reg [TAG_W-1:0] tag [0:NUM_ENTRIES-1];

	wire [NUM_ENTRIES-1:0] match;
	wire [NUM_ENTRIES-1:0] empty;

	genvar i;
	generate
	for (i = 0; i < NUM_ENTRIES; i = i + 1) begin : g_cam
		wire i_rel = release_valid && (release_id == i[3:0]);
		wire i_val = valid[i] && !i_rel;
		assign match[i] = i_val && (tag[i] == alloc_tag);
		assign empty[i] = !i_val;
	end
	endgenerate

	wire hazard_hit = |match;
	wire has_empty = |empty;
	assign alloc_ready = (!hazard_hit) && has_empty;

	/* Priority encoder for empty slot selection */
	always @(*) begin
		if (empty[0])       alloc_id = 4'd0;
		else if (empty[1])  alloc_id = 4'd1;
		else if (empty[2])  alloc_id = 4'd2;
		else if (empty[3])  alloc_id = 4'd3;
		else if (empty[4])  alloc_id = 4'd4;
		else if (empty[5])  alloc_id = 4'd5;
		else if (empty[6])  alloc_id = 4'd6;
		else if (empty[7])  alloc_id = 4'd7;
		else if (empty[8])  alloc_id = 4'd8;
		else if (empty[9])  alloc_id = 4'd9;
		else if (empty[10]) alloc_id = 4'd10;
		else if (empty[11]) alloc_id = 4'd11;
		else if (empty[12]) alloc_id = 4'd12;
		else if (empty[13]) alloc_id = 4'd13;
		else if (empty[14]) alloc_id = 4'd14;
		else                alloc_id = 4'd15;
	end

	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			valid <= {NUM_ENTRIES{1'b0}};
			for (k = 0; k < NUM_ENTRIES; k = k + 1)
				tag[k] <= {TAG_W{1'b0}};
		end else begin
			if (release_valid)
				valid[release_id] <= 1'b0;
			if (alloc_valid && alloc_ready) begin
				valid[alloc_id] <= 1'b1;
				tag[alloc_id] <= alloc_tag;
			end
		end
	end
endmodule

`default_nettype wire
