/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tlb_l2: 256-entry 4-way set-associative L2 TLB (64 sets x 4 ways).
 * Shared across execution units; handles misses from L1 TLBs.
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tlb_l2 #(
	parameter SETS = 64,
	parameter TAG_W = 18		/* {session_id[3:0], vpn[19:6]} */
) (
	input wire clk,
	input wire rst_n,

	/* Lookup Request (from L1 miss) */
	input  wire        lookup_valid,
	input  wire [3:0]  lookup_session,
	input  wire [19:0] lookup_vpn,
	output reg         hit,
	output reg  [19:0] hit_pfn,
	output reg  [5:0]  hit_flags,

	/* Refill Interface (from Hardware Page Table Walker) */
	input wire        refill_we,
	input wire [3:0]  refill_session,
	input wire [19:0] refill_vpn,
	input wire [19:0] refill_pfn,
	input wire [5:0]  refill_flags,

	/* Invalidation Interface */
	input wire        flush_trigger,
	input wire        flush_all,
	input wire [3:0]  flush_session
);
	wire [5:0]       lookup_set = lookup_vpn[5:0];
	wire [TAG_W-1:0] lookup_tag = {lookup_session, lookup_vpn[19:6]};

	wire [5:0]       refill_set = refill_vpn[5:0];
	wire [TAG_W-1:0] refill_tag = {refill_session, refill_vpn[19:6]};

	/* 4 ways packed registers: 32 bits per tag, 32 bits per pfn, 8 bits per flag */
	reg [SETS-1:0]    way0_valid, way1_valid, way2_valid, way3_valid;
	reg [SETS*32-1:0] way0_tag,   way1_tag,   way2_tag,   way3_tag;
	reg [SETS*32-1:0] way0_pfn,   way1_pfn,   way2_pfn,   way3_pfn;
	reg [SETS*8-1:0]  way0_flags, way1_flags, way2_flags, way3_flags;

	/* 2-bit cyclic replacement pointer per set */
	reg [SETS*2-1:0] set_alloc_ptr;
	wire [6:0] refill_ptr_idx = {refill_set, 1'b0};
	wire [1:0] cur_ptr = set_alloc_ptr[refill_ptr_idx +: 2];
	wire [1:0] next_ptr;
	wire ptr_co_unused;
	am_add #(.W(2)) u_ptr_inc (
		.a(cur_ptr),
		.b(2'd1),
		.ci(1'b0),
		.s(next_ptr),
		.co(ptr_co_unused)
	);

	/* Combinatorial Lookup across 4 ways */
	wire [10:0] set_tag_idx   = {lookup_set, 5'b00000};
	wire [10:0] set_pfn_idx   = {lookup_set, 5'b00000};
	wire [8:0]  set_flags_idx = {lookup_set, 3'b000};

	wire match0 = way0_valid[lookup_set] && (way0_tag[set_tag_idx +: TAG_W] == lookup_tag);
	wire match1 = way1_valid[lookup_set] && (way1_tag[set_tag_idx +: TAG_W] == lookup_tag);
	wire match2 = way2_valid[lookup_set] && (way2_tag[set_tag_idx +: TAG_W] == lookup_tag);
	wire match3 = way3_valid[lookup_set] && (way3_tag[set_tag_idx +: TAG_W] == lookup_tag);

	always @(*) begin
		hit       = 1'b0;
		hit_pfn   = 20'd0;
		hit_flags = 6'd0;
		if (lookup_valid) begin
			if (match0) begin
				hit       = 1'b1;
				hit_pfn   = way0_pfn[set_pfn_idx +: 20];
				hit_flags = way0_flags[set_flags_idx +: 6];
			end else if (match1) begin
				hit       = 1'b1;
				hit_pfn   = way1_pfn[set_pfn_idx +: 20];
				hit_flags = way1_flags[set_flags_idx +: 6];
			end else if (match2) begin
				hit       = 1'b1;
				hit_pfn   = way2_pfn[set_pfn_idx +: 20];
				hit_flags = way2_flags[set_flags_idx +: 6];
			end else if (match3) begin
				hit       = 1'b1;
				hit_pfn   = way3_pfn[set_pfn_idx +: 20];
				hit_flags = way3_flags[set_flags_idx +: 6];
			end
		end
	end

	/* Refill and Invalidation */
	wire [10:0] ref_tag_idx   = {refill_set, 5'b00000};
	wire [10:0] ref_pfn_idx   = {refill_set, 5'b00000};
	wire [8:0]  ref_flags_idx = {refill_set, 3'b000};

	integer s_flush;
	always @(posedge clk) begin
		if (!rst_n) begin
			set_alloc_ptr <= {(SETS*2){1'b0}};
			way0_valid    <= {SETS{1'b0}};
			way1_valid    <= {SETS{1'b0}};
			way2_valid    <= {SETS{1'b0}};
			way3_valid    <= {SETS{1'b0}};
			way0_tag      <= {(SETS*32){1'b0}};
			way1_tag      <= {(SETS*32){1'b0}};
			way2_tag      <= {(SETS*32){1'b0}};
			way3_tag      <= {(SETS*32){1'b0}};
			way0_pfn      <= {(SETS*32){1'b0}};
			way1_pfn      <= {(SETS*32){1'b0}};
			way2_pfn      <= {(SETS*32){1'b0}};
			way3_pfn      <= {(SETS*32){1'b0}};
			way0_flags    <= {(SETS*8){1'b0}};
			way1_flags    <= {(SETS*8){1'b0}};
			way2_flags    <= {(SETS*8){1'b0}};
			way3_flags    <= {(SETS*8){1'b0}};
		end else begin
			if (flush_all) begin
				way0_valid <= {SETS{1'b0}};
				way1_valid <= {SETS{1'b0}};
				way2_valid <= {SETS{1'b0}};
				way3_valid <= {SETS{1'b0}};
			end else if (flush_trigger) begin
				for (s_flush = 0; s_flush < SETS; s_flush = s_flush + 1) begin
					if (way0_tag[s_flush*32 + 14 +: 4] == flush_session) way0_valid[s_flush] <= 1'b0;
					if (way1_tag[s_flush*32 + 14 +: 4] == flush_session) way1_valid[s_flush] <= 1'b0;
					if (way2_tag[s_flush*32 + 14 +: 4] == flush_session) way2_valid[s_flush] <= 1'b0;
					if (way3_tag[s_flush*32 + 14 +: 4] == flush_session) way3_valid[s_flush] <= 1'b0;
				end
			end

			if (refill_we) begin
				set_alloc_ptr[refill_ptr_idx +: 2] <= next_ptr;
				case (cur_ptr)
				2'd0: begin
					way0_valid[refill_set]             <= 1'b1;
					way0_tag[ref_tag_idx +: TAG_W]     <= refill_tag;
					way0_pfn[ref_pfn_idx +: 20]        <= refill_pfn;
					way0_flags[ref_flags_idx +: 6]     <= refill_flags;
				end
				2'd1: begin
					way1_valid[refill_set]             <= 1'b1;
					way1_tag[ref_tag_idx +: TAG_W]     <= refill_tag;
					way1_pfn[ref_pfn_idx +: 20]        <= refill_pfn;
					way1_flags[ref_flags_idx +: 6]     <= refill_flags;
				end
				2'd2: begin
					way2_valid[refill_set]             <= 1'b1;
					way2_tag[ref_tag_idx +: TAG_W]     <= refill_tag;
					way2_pfn[ref_pfn_idx +: 20]        <= refill_pfn;
					way2_flags[ref_flags_idx +: 6]     <= refill_flags;
				end
				2'd3: begin
					way3_valid[refill_set]             <= 1'b1;
					way3_tag[ref_tag_idx +: TAG_W]     <= refill_tag;
					way3_pfn[ref_pfn_idx +: 20]        <= refill_pfn;
					way3_flags[ref_flags_idx +: 6]     <= refill_flags;
				end
				endcase
			end
		end
	end

	wire unused_ok = &{1'b0, ptr_co_unused};
endmodule

`default_nettype wire
