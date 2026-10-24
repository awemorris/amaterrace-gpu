/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pt: the post-transform buffer (PT) of the SU: vertex warps' exp
 * of the position (0x000-0x003) and the varyings (0x010 + k) land in the
 * vertex entry base + lane, RX reads it back word by word; the allocator
 * hands out 32-entry blocks to vertex warps.
 *
 * Storage: NPHYS banks (bank = entry mod NPHYS, so one lane group writes
 * one word into each bank), WPV = 4 + VARY_WORDS words per entry, read
 * data registered (pt_rdata the cycle after pt_rd).
 *
 * Allocator (WS288 p009, Q1): each block counts its entries in use.
 * pt_take (with the warp's slot pt_warp) takes the lowest block whose
 * count is 0 and sets 32; vl_go returns the entries of the lanes outside
 * vl_mask (also for vl_mask 0); pt_free returns one entry.  pt_done[b]:
 * the vertex warp that took block b has ended (its exports are in), so RX
 * may read the block's primitives.  See spec/gpu/su/atg_su_pt.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pt #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS) (1 for NPHYS 32) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W) */
	parameter PT_ENTRIES = 64,	/* PT vertices: a multiple of 32, at most 256 */
	parameter VARY_WORDS = 16	/* Varying words per vertex (ZYBO 16, KC705 32) */
) (
	input wire clk,
	input wire rst_n,
	/* Issued instruction (from atg_su_opd; only exp of vertex warps is taken) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_b,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	/* PT read port (atg_rx) */
	input wire pt_rd,
	input wire [7:0] pt_idx,
	input wire [5:0] pt_word,
	output wire [31:0] pt_rdata,
	input wire pt_free,
	input wire [7:0] pt_free_idx,
	/* Allocation (atg_su_sched, the VF) */
	output wire pt_ok,
	input wire pt_take,
	input wire [WARP_W-1:0] pt_warp,
	output wire [7:0] pt_base,
	input wire vl_go,
	input wire [31:0] vl_mask,
	output wire [7:0] pt_done,
	/* Warp ends (atg_su_exec) */
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp
);
`include "atg_su_uop.vh"

	localparam NB = PT_ENTRIES / 32;	/* blocks */
	localparam BW = NB > 1 ? $clog2(NB) : 1;
	localparam WPV = 4 + VARY_WORDS;	/* words per entry */
	localparam ROWS = PT_ENTRIES / NPHYS;	/* entries per bank */
	localparam G = 32 / NPHYS;	/* lane groups per warp (= rows per block per bank) */
	localparam DEPTH = ROWS * WPV;
	localparam AW = $clog2(DEPTH);

	/* ---- The exp writes of vertex warps. */
	wire [31:0] tgt = x_uop[ATG_UOP_IMM +: 32];
	wire is_pos = tgt < 32'd4;
	wire is_var = tgt >= 32'h10 && tgt < 32'h10 + VARY_WORDS;
	wire [31:0] wword = is_pos ? tgt : tgt - 32'h10 + 32'd4;
	wire wr = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && x_info[17:16] == 2'd0 &&
		(is_pos || is_var);

	/* The block of each vertex warp (set at pt_take). */
	reg [NWARPS*BW-1:0] wblk;
	reg [NWARPS-1:0] wv;	/* a vertex warp that owns a block */
	wire [BW-1:0] xblk = wblk[x_warp*BW +: BW];
	/* the row (entry / NPHYS) of lane l of this group */
	wire [31:0] wrow = {{(32-BW){1'b0}}, xblk} * G + {{(32-GRP_W){1'b0}}, x_grp};
	wire [31:0] waddr = wrow * WPV + wword;

	wire [31:0] rrow = {24'd0, pt_idx} / NPHYS;
	wire [31:0] raddr = rrow * WPV + {26'd0, pt_word};
	wire [31:0] rbank = {24'd0, pt_idx} % NPHYS;
	reg [31:0] rb_q;
	reg [NPHYS*32-1:0] rd_q;

	genvar b;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		reg [31:0] m [0:DEPTH-1];
		always @(posedge clk) begin
			if (wr && x_mask[NPHYS + b])
				m[waddr[AW-1:0]] <= x_b[32 * b +: 32];
			if (pt_rd)
				rd_q[32 * b +: 32] <= m[raddr[AW-1:0]];
		end
	end
	endgenerate

	always @(posedge clk)
		if (pt_rd)
			rb_q <= rbank;
	assign pt_rdata = rd_q[32 * rb_q[$clog2(NPHYS)-1:0] +: 32];

	/* ---- The allocator. */
	reg [NB*6-1:0] cnt;	/* entries in use, 0..32 */
	reg [NB*WARP_W-1:0] own;	/* the vertex warp that took the block */
	reg [NB-1:0] done;
	reg [BW-1:0] last_blk;	/* the block of the latest grant (for vl_go) */

	reg [BW-1:0] fb;
	reg any;
	integer i;
	always @(*) begin
		any = 1'b0;
		fb = {BW{1'b0}};
		for (i = NB - 1; i >= 0; i = i - 1)
			if (cnt[i*6 +: 6] == 6'd0) begin
				any = 1'b1;
				fb = i[BW-1:0];
			end
	end
	assign pt_ok = any;
	assign pt_base = {{(3-BW){1'b0}}, fb, 5'd0};
	assign pt_done = {{(8-NB){1'b0}}, done};

	/* entries returned at vl_go: the lanes outside vl_mask */
	reg [5:0] unused_n;
	always @(*) begin
		unused_n = 6'd0;
		for (i = 0; i < 32; i = i + 1)
			unused_n = unused_n + {5'd0, !vl_mask[i]};
	end
	wire [BW-1:0] free_blk = pt_free_idx[5 +: BW];
	wire [BW-1:0] end_blk = wblk[wc_warp*BW +: BW];
	wire end_own = wc_end && wv[wc_warp] && own[end_blk*WARP_W +: WARP_W] == wc_warp;

	always @(posedge clk) begin
		if (!rst_n) begin
			cnt <= {(NB*6){1'b0}};
			own <= {(NB*WARP_W){1'b0}};
			done <= {NB{1'b0}};
			last_blk <= {BW{1'b0}};
			wblk <= {(NWARPS*BW){1'b0}};
			wv <= {NWARPS{1'b0}};
		end else begin
			for (i = 0; i < NB; i = i + 1)
				cnt[i*6 +: 6] <= cnt[i*6 +: 6] +
					(pt_take && fb == i[BW-1:0] ? 6'd32 : 6'd0) -
					(vl_go && last_blk == i[BW-1:0] ? unused_n : 6'd0) -
					(pt_free && free_blk == i[BW-1:0] ? 6'd1 : 6'd0);
			if (end_own)
				done[end_blk] <= 1'b1;
			if (wc_end)
				wv[wc_warp] <= 1'b0;
			if (pt_take) begin
				own[fb*WARP_W +: WARP_W] <= pt_warp;
				done[fb] <= 1'b0;
				last_blk <= fb;
				wblk[pt_warp*BW +: BW] <= fb;
				wv[pt_warp] <= 1'b1;
			end
		end
	end

	wire unused_ok = &{1'b0, waddr, raddr, rb_q, pt_free_idx, x_info, x_uop};
endmodule

`default_nettype wire
