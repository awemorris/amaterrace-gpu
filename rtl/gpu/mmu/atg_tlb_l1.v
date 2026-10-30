/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tlb_l1: 16-entry 2-way set-associative L1 TLB per client (8 sets x 2 ways).
 * Hit latency: 1 clock cycle (clean <= 4 LUT levels).
 * Translates virtual page number (VPN) to physical frame number (PFN).
 * See spec/gpu/mmu/atg_mmu.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tlb_l1 #(
	parameter ENTRIES = 16,
	parameter VA_BITS = 32,
	parameter PA_BITS = 32,
	parameter VPN_BITS = VA_BITS - 12,
	parameter PPN_BITS = PA_BITS - 12,
	parameter SET_W = 3,
	parameter SETS = 8,
	parameter REM_VPN = VPN_BITS - SET_W,	/* 20 - 3 = 17 bits */
	parameter TAG_W = 4 + REM_VPN		/* 4 + 17 = 21 bits */
) (
	input wire clk,
	input wire rst_active,

	/* Translation Lookup Request (Combinatorial 1-cycle hit) */
	input  wire                req_valid,
	input  wire [3:0]          req_session,
	input  wire [VPN_BITS-1:0] req_vpn,
	input  wire [SET_W-1:0]    req_set_pfn_lo,
	input  wire [SET_W-1:0]    req_set_pfn_hi,
	input  wire [SET_W-1:0]    req_set_flg,
	input  wire [SET_W-1:0]    req_set_hit,

	(* max_fanout = 16 *) output wire                 hit,
	(* max_fanout = 16 *) output wire                 miss,
	output wire [PPN_BITS-1:0] hit_pfn,
	output wire [5:0]          hit_flags,	/* [0]=V, [1]=LOCAL, [2]=W, [3]=X, [4]=D, [5]=A */
	output wire                hit_w1,
	output wire [PPN_BITS-1:0] pfn_w0,
	output wire [PPN_BITS-1:0] pfn_w1,
	output wire [5:0]          flags_w0,
	output wire [5:0]          flags_w1,

	/* Refill Interface (from L2 or Walker) */
	input wire                refill_we,
	input wire [3:0]          refill_session,
	input wire [VPN_BITS-1:0] refill_vpn,
	input wire [PPN_BITS-1:0] refill_pfn,
	input wire [5:0]          refill_flags,

	/* Invalidation Interface */
	input wire        flush_trigger,
	input wire        flush_all,
	input wire [3:0]  flush_session
);
	/* Clock and reset net naming to prevent anonymous net violations */
	(* keep = "true" *) wire clk_l1 = clk;
	(* keep = "true" *) wire rst_l1_int = rst_active;

	wire [TAG_W-1:0] req_tag = {req_session, req_vpn[VPN_BITS-1:SET_W]};

	wire [SET_W-1:0] refill_set = refill_vpn[SET_W-1:0];
	wire [TAG_W-1:0] refill_tag = {refill_session, refill_vpn[VPN_BITS-1:SET_W]};

	/* 3:8 Set Active Decoder (limits refill_set fanout to <= 8) */
	(* dont_touch = "true" *) wire [SETS-1:0] set_active;
	assign set_active[0] = (refill_set == 3'd0);
	assign set_active[1] = (refill_set == 3'd1);
	assign set_active[2] = (refill_set == 3'd2);
	assign set_active[3] = (refill_set == 3'd3);
	assign set_active[4] = (refill_set == 3'd4);
	assign set_active[5] = (refill_set == 3'd5);
	assign set_active[6] = (refill_set == 3'd6);
	assign set_active[7] = (refill_set == 3'd7);

	/* Per-set match and read signals */
	wire [SETS-1:0]      set_hit;
	wire [SETS-1:0]      set_hit_w1;
	wire [9:0]           set_w0_pfn_lo [0:SETS-1];
	wire [PPN_BITS-11:0] set_w0_pfn_hi [0:SETS-1];
	wire [5:0]           set_w0_flags  [0:SETS-1];
	wire [9:0]           set_w1_pfn_lo [0:SETS-1];
	wire [PPN_BITS-11:0] set_w1_pfn_hi [0:SETS-1];
	wire [5:0]           set_w1_flags  [0:SETS-1];

	genvar gs;
	generate
	for (gs = 0; gs < SETS; gs = gs + 1) begin : g_set
		wire cur_set_active = set_active[gs];

		(* keep = "true", equivalent_register_removal = "no" *) reg w0_valid;
		(* keep = "true", equivalent_register_removal = "no" *) reg w1_valid;
		(* keep = "true", equivalent_register_removal = "no" *) reg set_alloc_ptr;

		(* keep = "true", equivalent_register_removal = "no" *) reg [TAG_W-1:0]     w0_tag;
		(* keep = "true", equivalent_register_removal = "no" *) reg [TAG_W-1:0]     w1_tag;
		(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]           w0_pfn_lo;
		(* keep = "true", equivalent_register_removal = "no" *) reg [PPN_BITS-11:0] w0_pfn_hi;
		(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]           w1_pfn_lo;
		(* keep = "true", equivalent_register_removal = "no" *) reg [PPN_BITS-11:0] w1_pfn_hi;
		(* keep = "true", equivalent_register_removal = "no" *) reg [5:0]           w0_flags;
		(* keep = "true", equivalent_register_removal = "no" *) reg [5:0]           w1_flags;

		/* Replicated write enables per field to strictly maintain <= 11 fanout */
		(* keep = "true", equivalent_register_removal = "no" *) wire we0_tag_lo = refill_we & cur_set_active & (set_alloc_ptr == 1'b0);
		(* keep = "true", equivalent_register_removal = "no" *) wire we0_tag_hi = refill_we & cur_set_active & (set_alloc_ptr == 1'b0);
		(* keep = "true", equivalent_register_removal = "no" *) wire we0_pfn_lo = refill_we & cur_set_active & (set_alloc_ptr == 1'b0);
		(* keep = "true", equivalent_register_removal = "no" *) wire we0_pfn_hi = refill_we & cur_set_active & (set_alloc_ptr == 1'b0);
		(* keep = "true", equivalent_register_removal = "no" *) wire we0_flg    = refill_we & cur_set_active & (set_alloc_ptr == 1'b0);

		(* keep = "true", equivalent_register_removal = "no" *) wire we1_tag_lo = refill_we & cur_set_active & (set_alloc_ptr == 1'b1);
		(* keep = "true", equivalent_register_removal = "no" *) wire we1_tag_hi = refill_we & cur_set_active & (set_alloc_ptr == 1'b1);
		(* keep = "true", equivalent_register_removal = "no" *) wire we1_pfn_lo = refill_we & cur_set_active & (set_alloc_ptr == 1'b1);
		(* keep = "true", equivalent_register_removal = "no" *) wire we1_pfn_hi = refill_we & cur_set_active & (set_alloc_ptr == 1'b1);
		(* keep = "true", equivalent_register_removal = "no" *) wire we1_flg    = refill_we & cur_set_active & (set_alloc_ptr == 1'b1);

		always @(posedge clk_l1) begin
			if (rst_l1_int) begin
				w0_valid      <= 1'b0;
				w1_valid      <= 1'b0;
				set_alloc_ptr <= 1'b0;
			end else begin
				if (flush_all) begin
					w0_valid <= 1'b0;
					w1_valid <= 1'b0;
				end else if (flush_trigger) begin
					if (w0_tag[TAG_W-1:TAG_W-4] == flush_session) w0_valid <= 1'b0;
					if (w1_tag[TAG_W-1:TAG_W-4] == flush_session) w1_valid <= 1'b0;
				end

				if (refill_we && cur_set_active) begin
					set_alloc_ptr <= ~set_alloc_ptr;
					if (set_alloc_ptr == 1'b0) begin
						w0_valid <= 1'b1;
					end else begin
						w1_valid <= 1'b1;
					end
				end
			end
		end

		always @(posedge clk_l1) begin
			if (we0_tag_lo) w0_tag[10:0]          <= refill_tag[10:0];
			if (we0_tag_hi) w0_tag[TAG_W-1:11]    <= refill_tag[TAG_W-1:11];
			if (we0_pfn_lo) w0_pfn_lo             <= refill_pfn[9:0];
			if (we0_pfn_hi) w0_pfn_hi             <= refill_pfn[PPN_BITS-1:10];
			if (we0_flg)    w0_flags              <= refill_flags;

			if (we1_tag_lo) w1_tag[10:0]          <= refill_tag[10:0];
			if (we1_tag_hi) w1_tag[TAG_W-1:11]    <= refill_tag[TAG_W-1:11];
			if (we1_pfn_lo) w1_pfn_lo             <= refill_pfn[9:0];
			if (we1_pfn_hi) w1_pfn_hi             <= refill_pfn[PPN_BITS-1:10];
			if (we1_flg)    w1_flags              <= refill_flags;
		end

		/* Level 1: 7 groups of 3-bit equality checks per way (1 LUT each) */
		wire eq0_0 = (w0_tag[2:0]   == req_tag[2:0]);
		wire eq0_1 = (w0_tag[5:3]   == req_tag[5:3]);
		wire eq0_2 = (w0_tag[8:6]   == req_tag[8:6]);
		wire eq0_3 = (w0_tag[11:9]  == req_tag[11:9]);
		wire eq0_4 = (w0_tag[14:12] == req_tag[14:12]);
		wire eq0_5 = (w0_tag[17:15] == req_tag[17:15]);
		wire eq0_6 = (w0_tag[20:18] == req_tag[20:18]);

		wire eq1_0 = (w1_tag[2:0]   == req_tag[2:0]);
		wire eq1_1 = (w1_tag[5:3]   == req_tag[5:3]);
		wire eq1_2 = (w1_tag[8:6]   == req_tag[8:6]);
		wire eq1_3 = (w1_tag[11:9]  == req_tag[11:9]);
		wire eq1_4 = (w1_tag[14:12] == req_tag[14:12]);
		wire eq1_5 = (w1_tag[17:15] == req_tag[17:15]);
		wire eq1_6 = (w1_tag[20:18] == req_tag[20:18]);

		/* Level 2: combine into hi/lo intermediate terms */
		wire m0_lo = eq0_0 & eq0_1 & eq0_2 & eq0_3;
		wire m0_hi = eq0_4 & eq0_5 & eq0_6 & w0_valid;

		wire m1_lo = eq1_0 & eq1_1 & eq1_2 & eq1_3;
		wire m1_hi = eq1_4 & eq1_5 & eq1_6 & w1_valid;

		/* Level 3: per-set hit indicators (clean logic depth <= 2) */
		assign set_hit[gs]       = (m0_lo & m0_hi) | (m1_lo & m1_hi);
		assign set_hit_w1[gs]    = (m1_lo & m1_hi);
		assign set_w0_pfn_lo[gs] = w0_pfn_lo;
		assign set_w0_pfn_hi[gs] = w0_pfn_hi;
		assign set_w0_flags[gs]  = w0_flags;
		assign set_w1_pfn_lo[gs] = w1_pfn_lo;
		assign set_w1_pfn_hi[gs] = w1_pfn_hi;
		assign set_w1_flags[gs]  = w1_flags;
	end
	endgenerate

	/* Decoupled 8:1 Multiplexers (<= 20 fanout per select bit) */
	wire [SET_W-1:0] sel_pfn_lo_a, sel_pfn_lo_b;
	wire [SET_W-1:0] sel_pfn_hi_a, sel_pfn_hi_b;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'h2)) u_b_plo_a0 (.I0(req_set_pfn_lo[0]), .O(sel_pfn_lo_a[0]));
	LUT1 #(.INIT(2'h2)) u_b_plo_a1 (.I0(req_set_pfn_lo[1]), .O(sel_pfn_lo_a[1]));
	LUT1 #(.INIT(2'h2)) u_b_plo_a2 (.I0(req_set_pfn_lo[2]), .O(sel_pfn_lo_a[2]));
	LUT1 #(.INIT(2'h2)) u_b_plo_b0 (.I0(req_set_pfn_lo[0]), .O(sel_pfn_lo_b[0]));
	LUT1 #(.INIT(2'h2)) u_b_plo_b1 (.I0(req_set_pfn_lo[1]), .O(sel_pfn_lo_b[1]));
	LUT1 #(.INIT(2'h2)) u_b_plo_b2 (.I0(req_set_pfn_lo[2]), .O(sel_pfn_lo_b[2]));

	LUT1 #(.INIT(2'h2)) u_b_phi_a0 (.I0(req_set_pfn_hi[0]), .O(sel_pfn_hi_a[0]));
	LUT1 #(.INIT(2'h2)) u_b_phi_a1 (.I0(req_set_pfn_hi[1]), .O(sel_pfn_hi_a[1]));
	LUT1 #(.INIT(2'h2)) u_b_phi_a2 (.I0(req_set_pfn_hi[2]), .O(sel_pfn_hi_a[2]));
	LUT1 #(.INIT(2'h2)) u_b_phi_b0 (.I0(req_set_pfn_hi[0]), .O(sel_pfn_hi_b[0]));
	LUT1 #(.INIT(2'h2)) u_b_phi_b1 (.I0(req_set_pfn_hi[1]), .O(sel_pfn_hi_b[1]));
	LUT1 #(.INIT(2'h2)) u_b_phi_b2 (.I0(req_set_pfn_hi[2]), .O(sel_pfn_hi_b[2]));
`else
	assign sel_pfn_lo_a = req_set_pfn_lo;
	assign sel_pfn_lo_b = req_set_pfn_lo;
	assign sel_pfn_hi_a = req_set_pfn_hi;
	assign sel_pfn_hi_b = req_set_pfn_hi;
`endif

	wire [9:0]           w0_pfn_lo_sel = set_w0_pfn_lo[sel_pfn_lo_a];
	wire [PPN_BITS-11:0] w0_pfn_hi_sel = set_w0_pfn_hi[sel_pfn_hi_a];
	wire [9:0]           w1_pfn_lo_sel = set_w1_pfn_lo[sel_pfn_lo_b];
	wire [PPN_BITS-11:0] w1_pfn_hi_sel = set_w1_pfn_hi[sel_pfn_hi_b];
	wire [5:0]           w0_flags_sel  = set_w0_flags[req_set_flg];
	wire [5:0]           w1_flags_sel  = set_w1_flags[req_set_flg];

	assign pfn_w0   = {w0_pfn_hi_sel, w0_pfn_lo_sel};
	assign pfn_w1   = {w1_pfn_hi_sel, w1_pfn_lo_sel};
	assign flags_w0 = w0_flags_sel;
	assign flags_w1 = w1_flags_sel;

	assign hit_w1    = set_hit_w1[req_set_hit];
	assign hit       = req_valid & set_hit[req_set_hit];
	assign miss      = req_valid & ~set_hit[req_set_hit];
	assign hit_pfn   = hit_w1 ? pfn_w1 : pfn_w0;
	assign hit_flags = hit_w1 ? flags_w1 : flags_w0;
endmodule

`default_nettype wire
