/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tlb_l1: 16-entry fully-associative L1 TLB per client (1-cycle hit).
 * Translated virtual page number (VPN) to physical frame number (PFN).
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tlb_l1 #(
	parameter ENTRIES = 16,
	parameter TAG_W = 24		/* {session_id[3:0], vpn[19:0]} */
) (
	input wire clk,
	input wire rst_n,

	/* Translation Lookup Request (Combinatorial 1-cycle hit) */
	input  wire [3:0]  req_session,
	input  wire [19:0] req_vpn,
	output reg         hit,
	output reg  [19:0] hit_pfn,
	output reg  [5:0]  hit_flags,	/* [0]=V, [1]=R, [2]=W, [3]=X, [4]=C, [5]=WC */

	/* Refill Interface (from L2 or Walker) */
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
	wire [TAG_W-1:0] req_tag    = {req_session, req_vpn};
	wire [TAG_W-1:0] refill_tag = {refill_session, refill_vpn};

	/* Packed entries: 32 bits per tag, 32 bits per pfn, 8 bits per flag to avoid multipliers */
	reg [ENTRIES-1:0]   entry_valid;
	reg [ENTRIES*32-1:0] entry_tag;
	reg [ENTRIES*32-1:0] entry_pfn;
	reg [ENTRIES*8-1:0]  entry_flags;

	/* Replacement pointer */
	reg [3:0] alloc_ptr;
	wire [3:0] next_ptr;
	wire ptr_co_unused;
	am_add #(.W(4)) u_ptr_inc (
		.a(alloc_ptr),
		.b(4'd1),
		.ci(1'b0),
		.s(next_ptr),
		.co(ptr_co_unused)
	);

	/* Read / Lookup (1 cycle combinatorial) */
	integer i;
	always @(*) begin
		hit       = 1'b0;
		hit_pfn   = 20'd0;
		hit_flags = 6'd0;
		for (i = 0; i < ENTRIES; i = i + 1) begin
			if (entry_valid[i] && (entry_tag[i*32 +: TAG_W] == req_tag)) begin
				hit       = 1'b1;
				hit_pfn   = entry_pfn[i*32 +: 20];
				hit_flags = entry_flags[i*8 +: 6];
			end
		end
	end

	/* Refill and Invalidation */
	integer f;
	always @(posedge clk) begin
		if (!rst_n) begin
			alloc_ptr   <= 4'd0;
			entry_valid <= {ENTRIES{1'b0}};
			entry_tag   <= {(ENTRIES*32){1'b0}};
			entry_pfn   <= {(ENTRIES*32){1'b0}};
			entry_flags <= {(ENTRIES*8){1'b0}};
		end else begin
			if (flush_all) begin
				entry_valid <= {ENTRIES{1'b0}};
			end else if (flush_trigger) begin
				for (f = 0; f < ENTRIES; f = f + 1) begin
					if (entry_tag[f*32 + 20 +: 4] == flush_session)
						entry_valid[f] <= 1'b0;
				end
			end

			if (refill_we) begin
				alloc_ptr <= next_ptr;
				case (alloc_ptr)
				4'd0:  begin entry_valid[0]  <= 1'b1; entry_tag[0*32 +: TAG_W]  <= refill_tag; entry_pfn[0*32 +: 20]  <= refill_pfn; entry_flags[0*8 +: 6]  <= refill_flags; end
				4'd1:  begin entry_valid[1]  <= 1'b1; entry_tag[1*32 +: TAG_W]  <= refill_tag; entry_pfn[1*32 +: 20]  <= refill_pfn; entry_flags[1*8 +: 6]  <= refill_flags; end
				4'd2:  begin entry_valid[2]  <= 1'b1; entry_tag[2*32 +: TAG_W]  <= refill_tag; entry_pfn[2*32 +: 20]  <= refill_pfn; entry_flags[2*8 +: 6]  <= refill_flags; end
				4'd3:  begin entry_valid[3]  <= 1'b1; entry_tag[3*32 +: TAG_W]  <= refill_tag; entry_pfn[3*32 +: 20]  <= refill_pfn; entry_flags[3*8 +: 6]  <= refill_flags; end
				4'd4:  begin entry_valid[4]  <= 1'b1; entry_tag[4*32 +: TAG_W]  <= refill_tag; entry_pfn[4*32 +: 20]  <= refill_pfn; entry_flags[4*8 +: 6]  <= refill_flags; end
				4'd5:  begin entry_valid[5]  <= 1'b1; entry_tag[5*32 +: TAG_W]  <= refill_tag; entry_pfn[5*32 +: 20]  <= refill_pfn; entry_flags[5*8 +: 6]  <= refill_flags; end
				4'd6:  begin entry_valid[6]  <= 1'b1; entry_tag[6*32 +: TAG_W]  <= refill_tag; entry_pfn[6*32 +: 20]  <= refill_pfn; entry_flags[6*8 +: 6]  <= refill_flags; end
				4'd7:  begin entry_valid[7]  <= 1'b1; entry_tag[7*32 +: TAG_W]  <= refill_tag; entry_pfn[7*32 +: 20]  <= refill_pfn; entry_flags[7*8 +: 6]  <= refill_flags; end
				4'd8:  begin entry_valid[8]  <= 1'b1; entry_tag[8*32 +: TAG_W]  <= refill_tag; entry_pfn[8*32 +: 20]  <= refill_pfn; entry_flags[8*8 +: 6]  <= refill_flags; end
				4'd9:  begin entry_valid[9]  <= 1'b1; entry_tag[9*32 +: TAG_W]  <= refill_tag; entry_pfn[9*32 +: 20]  <= refill_pfn; entry_flags[9*8 +: 6]  <= refill_flags; end
				4'd10: begin entry_valid[10] <= 1'b1; entry_tag[10*32 +: TAG_W] <= refill_tag; entry_pfn[10*32 +: 20] <= refill_pfn; entry_flags[10*8 +: 6] <= refill_flags; end
				4'd11: begin entry_valid[11] <= 1'b1; entry_tag[11*32 +: TAG_W] <= refill_tag; entry_pfn[11*32 +: 20] <= refill_pfn; entry_flags[11*8 +: 6] <= refill_flags; end
				4'd12: begin entry_valid[12] <= 1'b1; entry_tag[12*32 +: TAG_W] <= refill_tag; entry_pfn[12*32 +: 20] <= refill_pfn; entry_flags[12*8 +: 6] <= refill_flags; end
				4'd13: begin entry_valid[13] <= 1'b1; entry_tag[13*32 +: TAG_W] <= refill_tag; entry_pfn[13*32 +: 20] <= refill_pfn; entry_flags[13*8 +: 6] <= refill_flags; end
				4'd14: begin entry_valid[14] <= 1'b1; entry_tag[14*32 +: TAG_W] <= refill_tag; entry_pfn[14*32 +: 20] <= refill_pfn; entry_flags[14*8 +: 6] <= refill_flags; end
				4'd15: begin entry_valid[15] <= 1'b1; entry_tag[15*32 +: TAG_W] <= refill_tag; entry_pfn[15*32 +: 20] <= refill_pfn; entry_flags[15*8 +: 6] <= refill_flags; end
				default: ;
				endcase
			end
		end
	end

	wire unused_ok = &{1'b0, ptr_co_unused};
endmodule

`default_nettype wire
