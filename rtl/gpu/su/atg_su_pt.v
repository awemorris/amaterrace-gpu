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
 * Allocator: each block counts its entries in use.
 * pt_take (with the warp's slot pt_warp) takes the lowest block whose
 * count is 0 and sets 32; vl_go returns the entries of the lanes outside
 * vl_mask (also for vl_mask 0); pt_free returns one entry.  pt_done[b]:
 * the vertex warp that took block b has ended (its exports are in), so RX
 * may read the block's primitives.  See spec/gpu/su/atg_su_pt.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pt #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS) (1 for NPHYS 32) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W) */
	parameter PT_ENTRIES = 64,	/* PT vertices: a multiple of 32, at most 256 */
	parameter VARY_WORDS = 16	/* Varying words per vertex, at most 64 (KC705 64) */
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
	input wire [6:0] pt_word,
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
	input wire [WARP_W-1:0] wc_warp,
	/* Session protection: clear the table (the unit idle), one word per cycle */
	input wire scrub,
	output wire scrub_busy
);
`include "atg_su_uop.vh"

	localparam NB = PT_ENTRIES / 32;	/* blocks */
	localparam BW = NB > 1 ? $clog2(NB) : 1;
	localparam WPV = 4 + VARY_WORDS;	/* words per entry */
	localparam ROWS = PT_ENTRIES / NPHYS;	/* entries per bank */
	localparam G = 32 / NPHYS;	/* lane groups per warp (= rows per block per bank) */
	localparam DEPTH = ROWS * WPV;
	localparam AW = $clog2(DEPTH);
	localparam G_W = $clog2(G);	/* G is a power of two: block G + group are disjoint bits */
	/* verilator lint_off WIDTHTRUNC */
	localparam [7:0] WPV_V = WPV;
	/* verilator lint_on WIDTHTRUNC */

	/* ---- The exp writes of vertex warps. */
	wire [31:0] tgt = x_uop[ATG_UOP_IMM +: 32];
	wire is_pos = tgt < 32'd4;
	wire is_var = tgt >= 32'h10 && tgt < 32'h10 + VARY_WORDS;
	wire [31:0] tgt_v;
	wire tv_bo_unused;
	am_sub #(.W(32)) u_tgt_v (.a(tgt), .b(32'd12), .bi(1'b0), .d(tgt_v), .bo(tv_bo_unused));
	wire [31:0] wword = is_pos ? tgt : tgt_v;	/* varying v at word 4 + v */
	wire wr = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && x_info[17:16] == 2'd0 &&
		(is_pos || is_var);

	/* The block of each vertex warp (set at pt_take). */
	reg [NWARPS*BW-1:0] wblk;
	reg [NWARPS-1:0] wv;	/* a vertex warp that owns a block */
	wire [BW-1:0] xblk = wblk[x_warp*BW +: BW];
	/* the row (entry / NPHYS) of lane l of this group */
	wire [31:0] wrow = ({{(32-BW){1'b0}}, xblk} << G_W) | ({{(32-GRP_W){1'b0}}, x_grp} % G);
	wire [31:0] rrow = {24'd0, pt_idx} / NPHYS;

	/*
	 * The word addresses row WPV + word, modulo 2^AW (the bank's): a
	 * multiplier by the constant WPV each.
	 */
	wire [AW+7:0] wrow_w;
	wire [AW+7:0] rrow_w;
	wire [AW-1:0] waddr_a;
	wire [AW-1:0] raddr_a;
	wire [31:0] pt_word32 = {25'd0, pt_word};
	wire wa_co_unused, ra_co_unused;
	am_mul #(.AW(AW), .BW(8)) u_wrow (.clk(clk), .en(1'b1), .a(wrow[AW-1:0]), .b(WPV_V), .p(wrow_w));
	am_mul #(.AW(AW), .BW(8)) u_rrow (.clk(clk), .en(1'b1), .a(rrow[AW-1:0]), .b(WPV_V), .p(rrow_w));
	am_add #(.W(AW)) u_waddr (.a(wrow_w[AW-1:0]), .b(wword[AW-1:0]), .ci(1'b0), .s(waddr_a),
		.co(wa_co_unused));
	am_add #(.W(AW)) u_raddr (.a(rrow_w[AW-1:0]), .b(pt_word32[AW-1:0]), .ci(1'b0), .s(raddr_a),
		.co(ra_co_unused));
	wire [31:0] waddr = {{(32-AW){1'b0}}, waddr_a};
	wire [31:0] raddr = {{(32-AW){1'b0}}, raddr_a};
	wire unused_addr = &{1'b0, wword[31:AW], wrow[31:AW], rrow[31:AW], wrow_w[AW+7:AW],
		rrow_w[AW+7:AW], pt_word32[31:AW]};
	wire [31:0] rbank = {24'd0, pt_idx} % NPHYS;
	reg [31:0] rb_q;
	reg [NPHYS*32-1:0] rd_q;

	/* The banks' write port: the vertex warps' exp, or the scrub's zeros. */
	wire sc_on;
	wire [AW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(DEPTH), .AW(AW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	assign scrub_busy = sc_on;
	wire [AW-1:0] m_wa = sc_on ? sc_a : waddr[AW-1:0];

	genvar b;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		reg [31:0] m [0:DEPTH-1];
		always @(posedge clk) begin
			if (sc_on || wr && x_mask[NPHYS + b])
				m[m_wa] <= sc_on ? 32'd0 : x_b[32 * b +: 32];
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

	/* entries returned at vl_go: the lanes outside vl_mask (a tree of adders) */
	wire [5:0] unused_n;
	wire [31:0] nm = ~vl_mask;
	wire [31:0] pc2;	/* 16 sums of 2 bits */
	wire [23:0] pc4;	/* 8 sums of 3 bits */
	wire [15:0] pc8;	/* 4 sums of 4 bits */
	wire [9:0] pc16;	/* 2 sums of 5 bits */
	genvar pi;
	generate
		for (pi = 0; pi < 16; pi = pi + 1) begin : g_pc2
			wire co_unused;
			am_add #(.W(2)) u (.a({1'b0, nm[2*pi]}), .b({1'b0, nm[2*pi+1]}), .ci(1'b0),
				.s(pc2[2*pi +: 2]), .co(co_unused));
		end
		for (pi = 0; pi < 8; pi = pi + 1) begin : g_pc4
			wire co_unused;
			am_add #(.W(3)) u (.a({1'b0, pc2[4*pi +: 2]}), .b({1'b0, pc2[4*pi+2 +: 2]}), .ci(1'b0),
				.s(pc4[3*pi +: 3]), .co(co_unused));
		end
		for (pi = 0; pi < 4; pi = pi + 1) begin : g_pc8
			wire co_unused;
			am_add #(.W(4)) u (.a({1'b0, pc4[6*pi +: 3]}), .b({1'b0, pc4[6*pi+3 +: 3]}), .ci(1'b0),
				.s(pc8[4*pi +: 4]), .co(co_unused));
		end
		for (pi = 0; pi < 2; pi = pi + 1) begin : g_pc16
			wire co_unused;
			am_add #(.W(5)) u (.a({1'b0, pc8[8*pi +: 4]}), .b({1'b0, pc8[8*pi+4 +: 4]}), .ci(1'b0),
				.s(pc16[5*pi +: 5]), .co(co_unused));
		end
	endgenerate
	wire pc_co_unused;
	am_add #(.W(6)) u_pc32 (.a({1'b0, pc16[4:0]}), .b({1'b0, pc16[9:5]}), .ci(1'b0), .s(unused_n),
		.co(pc_co_unused));
	wire [BW-1:0] free_blk = pt_free_idx[5 +: BW];

	/* Each block's count: + 32 at its grant, - the unused lanes at vl_go, - 1 at a free. */
	wire [NB*6-1:0] cnt_next;
	genvar cb;
	generate
		for (cb = 0; cb < NB; cb = cb + 1) begin : g_cnt
			wire [5:0] c1;
			wire [5:0] c2;
			wire c1_co_unused, c2_bo_unused, c3_bo_unused;
			am_add #(.W(6)) u_take (.a(cnt[cb*6 +: 6]), .b(pt_take && fb == cb ? 6'd32 : 6'd0), .ci(1'b0),
				.s(c1), .co(c1_co_unused));
			am_sub #(.W(6)) u_go (.a(c1), .b(vl_go && last_blk == cb ? unused_n : 6'd0), .bi(1'b0),
				.d(c2), .bo(c2_bo_unused));
			am_sub #(.W(6)) u_free (.a(c2), .b(6'd0), .bi(pt_free && free_blk == cb), .d(cnt_next[cb*6 +: 6]),
				.bo(c3_bo_unused));
		end
	endgenerate
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
			cnt <= cnt_next;
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
