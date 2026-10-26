/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_mshr: Miss Status Holding Register (MSHR) for TU L1 texture cache.
 *
 * Tracks up to NENTRIES (4) concurrent in-flight cache line misses.
 * Supports:
 *   - Primary Miss: allocates a new MSHR entry and issues memory request.
 *   - Secondary Miss (Merge): detects line address match across in-flight
 *     entries and merges waiting quads without duplicate memory fetches.
 *   - Hit-Under-Miss: permits cache hits to proceed concurrently while
 *     unrelated misses are in-flight.
 *   - Refill: signals data arrival, releases the MSHR entry, and notifies
 *     waiting quads.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_tu_mshr #(
	parameter NENTRIES   = 4,
	parameter ADDR_W     = 32,
	parameter LINE_BYTES = 64,
	parameter LINE_SHIFT = 6,
	parameter QUAD_ID_W  = 6
) (
	input wire clk,
	input wire rst_n,

	/* Query interface (check if line is already in-flight) */
	input wire check_valid,
	input wire [ADDR_W-LINE_SHIFT-1:0] check_line_addr,
	output wire check_hit,
	output wire [1:0] check_mshr_idx,

	/* Miss registration / allocation interface */
	input wire alloc_valid,
	output wire alloc_ready,
	input wire [ADDR_W-LINE_SHIFT-1:0] alloc_line_addr,
	input wire [QUAD_ID_W-1:0] alloc_quad_id,
	output wire [1:0] alloc_mshr_idx,
	output wire alloc_merged,

	/* Memory refill response interface */
	input wire refill_valid,
	input wire [1:0] refill_mshr_idx,
	input wire [LINE_BYTES*8-1:0] refill_data,
	input wire refill_error,

	/* Cache update & completion notification */
	output reg mshr_ready_valid,
	output reg [QUAD_ID_W-1:0] mshr_ready_quad_id,
	output reg [(1<<QUAD_ID_W)-1:0] mshr_ready_mask,
	output reg [LINE_BYTES*8-1:0] mshr_ready_data,
	output reg [ADDR_W-LINE_SHIFT-1:0] mshr_ready_line,
	output reg mshr_ready_error,
	output reg [1:0] mshr_ready_idx,

	/* Status */
	output wire [2:0] active_count,
	output wire empty,
	output wire full,
	output wire [NENTRIES-1:0] mshr_vld_vec,
	output wire [NENTRIES*LA_W-1:0] mshr_line_vec
);

`ifdef CFG_ENABLE_MSHR
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB   = LINE_BYTES * 8;
	localparam QMASK_W = 1 << QUAD_ID_W;

	reg entry_vld [0:NENTRIES-1];
	reg [LA_W-1:0] entry_line [0:NENTRIES-1];
	reg [QUAD_ID_W-1:0] entry_qid [0:NENTRIES-1];
	reg [QMASK_W-1:0] entry_qmask [0:NENTRIES-1];

	assign mshr_vld_vec = {entry_vld[3], entry_vld[2], entry_vld[1], entry_vld[0]};
	assign mshr_line_vec = {entry_line[3], entry_line[2], entry_line[1], entry_line[0]};

	/* Query check logic */
	wire c_match0 = entry_vld[0] && (entry_line[0] == check_line_addr);
	wire c_match1 = entry_vld[1] && (entry_line[1] == check_line_addr);
	wire c_match2 = entry_vld[2] && (entry_line[2] == check_line_addr);
	wire c_match3 = entry_vld[3] && (entry_line[3] == check_line_addr);

	assign check_hit = check_valid && (c_match0 || c_match1 || c_match2 || c_match3);
	assign check_mshr_idx = c_match0 ? 2'd0 :
	                        c_match1 ? 2'd1 :
	                        c_match2 ? 2'd2 : 2'd3;

	/* Allocation match check (Merge / Secondary Miss) */
	wire a_match0 = entry_vld[0] && (entry_line[0] == alloc_line_addr);
	wire a_match1 = entry_vld[1] && (entry_line[1] == alloc_line_addr);
	wire a_match2 = entry_vld[2] && (entry_line[2] == alloc_line_addr);
	wire a_match3 = entry_vld[3] && (entry_line[3] == alloc_line_addr);

	wire [1:0] match_idx = a_match0 ? 2'd0 :
	                       a_match1 ? 2'd1 :
	                       a_match2 ? 2'd2 : 2'd3;

	assign alloc_merged = a_match0 || a_match1 || a_match2 || a_match3;

	/* Free entry finding (taking into account refill clearing in current cycle) */
	wire free0 = !entry_vld[0] || (refill_valid && refill_mshr_idx == 2'd0);
	wire free1 = !entry_vld[1] || (refill_valid && refill_mshr_idx == 2'd1);
	wire free2 = !entry_vld[2] || (refill_valid && refill_mshr_idx == 2'd2);
	wire free3 = !entry_vld[3] || (refill_valid && refill_mshr_idx == 2'd3);

	wire has_free = free0 || free1 || free2 || free3;
	wire [1:0] free_idx = free0 ? 2'd0 :
	                      free1 ? 2'd1 :
	                      free2 ? 2'd2 : 2'd3;

	assign alloc_ready = alloc_merged || has_free;
	assign alloc_mshr_idx = alloc_merged ? match_idx : free_idx;

	/* Active count and status */
	wire [3:0] vld_bits = {entry_vld[3], entry_vld[2], entry_vld[1], entry_vld[0]};

	reg [2:0] cnt;
	always @(*) begin
		case (vld_bits)
		4'b0000: cnt = 3'd0;
		4'b0001, 4'b0010, 4'b0100, 4'b1000: cnt = 3'd1;
		4'b0011, 4'b0101, 4'b0110, 4'b1001, 4'b1010, 4'b1100: cnt = 3'd2;
		4'b0111, 4'b1011, 4'b1101, 4'b1110: cnt = 3'd3;
		4'b1111: cnt = 3'd4;
		default: cnt = 3'd0;
		endcase
	end

	assign active_count = cnt;
	assign empty = (vld_bits == 4'b0000);
	assign full  = (vld_bits == 4'b1111);

	/* 1-hot mask of alloc_quad_id via am_shift (zero raw operator in this module) */
	wire [QMASK_W-1:0] alloc_qmask;
	am_shift #(.W(QMASK_W), .SW(QUAD_ID_W)) u_qmask (
		.a({{(QMASK_W-1){1'b0}}, 1'b1}),
		.amt(alloc_quad_id),
		.left(1'b1),
		.arith(1'b0),
		.y(alloc_qmask)
	);

	/* Sequential update */
	integer i;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (i = 0; i < NENTRIES; i = i + 1) begin
				entry_vld[i]   <= 1'b0;
				entry_line[i]  <= {LA_W{1'b0}};
				entry_qid[i]   <= {QUAD_ID_W{1'b0}};
				entry_qmask[i] <= {QMASK_W{1'b0}};
			end
			mshr_ready_valid   <= 1'b0;
			mshr_ready_quad_id <= {QUAD_ID_W{1'b0}};
			mshr_ready_mask    <= {QMASK_W{1'b0}};
			mshr_ready_data    <= {LB{1'b0}};
			mshr_ready_line    <= {LA_W{1'b0}};
			mshr_ready_error   <= 1'b0;
			mshr_ready_idx     <= 2'd0;
		end else begin
			/* Refill notification */
			if (refill_valid && entry_vld[refill_mshr_idx]) begin
				mshr_ready_valid   <= 1'b1;
				mshr_ready_quad_id <= entry_qid[refill_mshr_idx];
				mshr_ready_mask    <= entry_qmask[refill_mshr_idx] |
					((alloc_valid && alloc_merged && match_idx == refill_mshr_idx) ?
					alloc_qmask : {QMASK_W{1'b0}});
				mshr_ready_data    <= refill_data;
				mshr_ready_line    <= entry_line[refill_mshr_idx];
				mshr_ready_error   <= refill_error;
				mshr_ready_idx     <= refill_mshr_idx;
				entry_vld[refill_mshr_idx]   <= 1'b0;
				entry_qmask[refill_mshr_idx] <= {QMASK_W{1'b0}};
			end else begin
				mshr_ready_valid <= 1'b0;
			end

			/* Allocation */
			if (alloc_valid && alloc_ready) begin
				if (alloc_merged) begin
					/* Secondary miss: merge quad onto existing entry if not refilling this cycle */
					if (!(refill_valid && refill_mshr_idx == match_idx)) begin
						entry_qmask[match_idx] <= entry_qmask[match_idx] | alloc_qmask;
					end
				end else begin
					/* Primary miss: allocate new entry */
					entry_vld[free_idx]   <= 1'b1;
					entry_line[free_idx]  <= alloc_line_addr;
					entry_qid[free_idx]   <= alloc_quad_id;
					entry_qmask[free_idx] <= alloc_qmask;
				end
			end
		end
	end

`else

	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB   = LINE_BYTES * 8;
	localparam QMASK_W = 1 << QUAD_ID_W;

	assign check_hit = 1'b0;
	assign check_mshr_idx = 2'd0;
	assign alloc_ready = 1'b0;
	assign alloc_mshr_idx = 2'd0;
	assign alloc_merged = 1'b0;
	assign active_count = 3'd0;
	assign empty = 1'b1;
	assign full = 1'b0;
	assign mshr_vld_vec = {NENTRIES{1'b0}};
	assign mshr_line_vec = {(NENTRIES*LA_W){1'b0}};

	always @(posedge clk) begin
		if (!rst_n) begin
			mshr_ready_valid   <= 1'b0;
			mshr_ready_quad_id <= {QUAD_ID_W{1'b0}};
			mshr_ready_mask    <= {QMASK_W{1'b0}};
			mshr_ready_data    <= {LB{1'b0}};
			mshr_ready_line    <= {LA_W{1'b0}};
			mshr_ready_error   <= 1'b0;
			mshr_ready_idx     <= 2'd0;
		end else begin
			mshr_ready_valid   <= 1'b0;
			mshr_ready_quad_id <= {QUAD_ID_W{1'b0}};
			mshr_ready_mask    <= {QMASK_W{1'b0}};
			mshr_ready_data    <= {LB{1'b0}};
			mshr_ready_line    <= {LA_W{1'b0}};
			mshr_ready_error   <= 1'b0;
			mshr_ready_idx     <= 2'd0;
		end
	end

	wire unused_mshr_stub = &{1'b0, check_valid, check_line_addr, alloc_valid,
		alloc_line_addr, alloc_quad_id, refill_valid, refill_mshr_idx,
		refill_data, refill_error};

`endif

endmodule

`default_nettype wire
