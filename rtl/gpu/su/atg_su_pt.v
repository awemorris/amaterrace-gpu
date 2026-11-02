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
	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire scrub_i = scrub;
	(* dont_touch = "true" *) wire vl_go_pt = vl_go;
	(* dont_touch = "true" *) wire [31:0] vl_mask_pt = vl_mask;
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
	 * The word addresses row WPV + word, modulo 2^AW (the bank's):
	 * ROWS = PT_ENTRIES / NPHYS is small (e.g. 8 or 16), so row * WPV is a pure
	 * constant-table lookup of row[$clog2(ROWS)-1:0] (1 LUT level, 0 CARRY4s),
	 * followed by a single am_add with wword / pt_word.
	 */
	localparam RW = ROWS > 1 ? $clog2(ROWS) : 1;
	reg [31:0] wrow_w32, rrow_w32;
	integer ri;
	always @(*) begin
		wrow_w32 = 32'd0;
		rrow_w32 = 32'd0;
		for (ri = 0; ri < ROWS; ri = ri + 1) begin
			if (wrow[RW-1:0] == ri[RW-1:0])
				wrow_w32 = ri * WPV;
			if (rrow[RW-1:0] == ri[RW-1:0])
				rrow_w32 = ri * WPV;
		end
	end
	wire [AW-1:0] wrow_w_aw = wrow_w32[AW-1:0];
	wire [AW-1:0] rrow_w_aw = rrow_w32[AW-1:0];

	wire [AW-1:0] waddr_a;
	wire [AW-1:0] raddr_a;
	wire [31:0] pt_word32 = {25'd0, pt_word};
	wire wa_co_unused, ra_co_unused;
	am_add #(.W(AW)) u_waddr (.a(wrow_w_aw), .b(wword[AW-1:0]), .ci(1'b0), .s(waddr_a),
		.co(wa_co_unused));
	am_add #(.W(AW)) u_raddr (.a(rrow_w_aw), .b(pt_word32[AW-1:0]), .ci(1'b0), .s(raddr_a),
		.co(ra_co_unused));
	wire [31:0] waddr = {{(32-AW){1'b0}}, waddr_a};
	wire [31:0] raddr = {{(32-AW){1'b0}}, raddr_a};
	wire unused_addr = &{1'b0, wword[31:AW], wrow[31:RW], rrow[31:RW], wrow_w32[31:AW], rrow_w32[31:AW], pt_word32[31:AW], WPV_V};
	wire [31:0] rbank = {24'd0, pt_idx} % NPHYS;
	(* shreg_extract = "no", max_fanout = 12 *) reg pt_rd_r1;
	(* dont_touch = "true" *) reg [AW-1:0] raddr_r;
	(* shreg_extract = "no", max_fanout = 12 *) reg [$clog2(NPHYS)-1:0] rb_r1, rb_r2, rb_r3;
	wire [NPHYS*32-1:0] rd_q;
	wire [NPHYS*32-1:0] rd_q_pipe;

	/* The banks' write port: the vertex warps' exp, or the scrub's zeros (registered for 0-LUT BRAM ADDR, Rule 4). */
	wire sc_on;
	wire [AW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(DEPTH), .AW(AW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub_i), .on(sc_on), .a(sc_a)
	);

	wire [AW-1:0] sc_a_next;
	wire sc_a_co_unused;
	am_add #(.W(AW)) u_sc_a_next (.a(sc_a), .b({AW{1'b0}}), .ci(1'b1), .s(sc_a_next), .co(sc_a_co_unused));

	assign scrub_busy = sc_on;
	(* max_fanout = 12 *) reg [NPHYS-1:0] m_we_r;
	(* dont_touch = "true" *) reg [AW-1:0] m_wa_r;
	wire [NPHYS*32-1:0] m_wd_r;
	always @(posedge clk) begin
		if (rst_p) begin
			m_we_r <= {NPHYS{1'b0}};
			m_wa_r <= {AW{1'b0}};
		end else if (scrub_i) begin
			m_we_r <= {NPHYS{1'b1}};
			m_wa_r <= {AW{1'b0}};
		end else if (sc_on) begin
			if ({{(32-AW){1'b0}}, sc_a} == DEPTH - 1)
				m_we_r <= {NPHYS{1'b0}};
			else begin
				m_we_r <= {NPHYS{1'b1}};
				m_wa_r <= sc_a_next;
			end
		end else begin
			m_we_r <= wr ? x_mask[2*NPHYS-1:NPHYS] : {NPHYS{1'b0}};
			m_wa_r <= waddr[AW-1:0];
		end
	end

	genvar b, gbh;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		for (gbh = 0; gbh < 2; gbh = gbh + 1) begin : g_wd_half
			(* shreg_extract = "no" *) reg [15:0] m_wd_h;
			(* dont_touch = "true" *) wire wd_zero_h = rst_p || scrub_i || sc_on;
			always @(posedge clk) begin
				if (wd_zero_h)
					m_wd_h <= 16'd0;
				else
					m_wd_h <= x_b[b*32 + gbh*16 +: 16];
			end
			assign m_wd_r[b*32 + gbh*16 +: 16] = m_wd_h;
		end
		(* ram_style = "block" *) reg [31:0] m [0:DEPTH-1];
		reg [31:0] rd_q_b;
		(* dont_touch = "true" *) reg [31:0] rd_q_pipe_b;
		(* dont_touch = "true" *) wire pt_rd_b = pt_rd_r1;
		always @(posedge clk) begin
			if (m_we_r[b])
				m[m_wa_r] <= m_wd_r[32 * b +: 32];
			if (pt_rd_b)
				rd_q_b <= m[raddr_r];
			rd_q_pipe_b <= rd_q_b;
		end
		assign rd_q[32 * b +: 32] = rd_q_b;
		assign rd_q_pipe[32 * b +: 32] = rd_q_pipe_b;
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			pt_rd_r1 <= 1'b0;
			raddr_r  <= {AW{1'b0}};
			rb_r1    <= {$clog2(NPHYS){1'b0}};
			rb_r2    <= {$clog2(NPHYS){1'b0}};
			rb_r3    <= {$clog2(NPHYS){1'b0}};
		end else begin
			pt_rd_r1 <= pt_rd;
			if (pt_rd) begin
				raddr_r <= raddr[AW-1:0];
				rb_r1   <= rbank[$clog2(NPHYS)-1:0];
			end
			if (pt_rd_r1)
				rb_r2 <= rb_r1;
			rb_r3 <= rb_r2;
		end
	end
	generate
	for (gbh = 0; gbh < 4; gbh = gbh + 1) begin : g_rdata_sl
		(* dont_touch = "true" *) wire [$clog2(NPHYS)-1:0] rb_r3_sl = rb_r3;
		reg [7:0] rdata_sl_w;
		integer rbi;
		always @(*) begin
			rdata_sl_w = rd_q_pipe[gbh*8 +: 8];
			for (rbi = 1; rbi < NPHYS; rbi = rbi + 1)
				if (rb_r3_sl == rbi[$clog2(NPHYS)-1:0])
					rdata_sl_w = rd_q_pipe[rbi*32 + gbh*8 +: 8];
		end
		assign pt_rdata[gbh*8 +: 8] = rdata_sl_w;
	end
	endgenerate

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

	/*
	 * Pipelined popcount of vl_mask (eliminates 8-deep serial CARRY4 cascade):
	 * - On vl_go with vl_mask == 0, cnt[last_blk] becomes 0 immediately.
	 * - On vl_go with vl_mask != 0, two 16-bit popcounts (computed in 3 LUT
	 *   levels with 0 CARRY4s) are latched into p16_lo_r and p16_hi_r, and on
	 *   the next cycle u_pop32 (1 am_add with 0 Pre-CARRY LUTs) sets cnt[last_blk_d1].
	 */
	function [2:0] pop4;
		input [3:0] x;
		case (x)
		4'b0000: pop4 = 3'd0;
		4'b0001, 4'b0010, 4'b0100, 4'b1000: pop4 = 3'd1;
		4'b0011, 4'b0101, 4'b0110, 4'b1001, 4'b1010, 4'b1100: pop4 = 3'd2;
		4'b0111, 4'b1011, 4'b1101, 4'b1110: pop4 = 3'd3;
		default: pop4 = 3'd4;
		endcase
	endfunction

	function [3:0] add_0to4;
		input [2:0] a;
		input [2:0] b;
		reg c0, c1;
		begin
			c0 = a[0] & b[0];
			c1 = (a[1] & b[1]) | ((a[1] ^ b[1]) & c0);
			add_0to4 = {
				(a[2] & b[2]) | ((a[2] ^ b[2]) & c1),
				a[2] ^ b[2] ^ c1,
				a[1] ^ b[1] ^ c0,
				a[0] ^ b[0]
			};
		end
	endfunction

	function [4:0] add_0to8;
		input [3:0] a;
		input [3:0] b;
		reg c0, c1, c2;
		begin
			c0 = a[0] & b[0];
			c1 = (a[1] & b[1]) | ((a[1] ^ b[1]) & c0);
			c2 = (a[2] & b[2]) | ((a[2] ^ b[2]) & c1);
			add_0to8 = {
				(a[3] & b[3]) | ((a[3] ^ b[3]) & c2),
				a[3] ^ b[3] ^ c2,
				a[2] ^ b[2] ^ c1,
				a[1] ^ b[1] ^ c0,
				a[0] ^ b[0]
			};
		end
	endfunction

	function [4:0] pop16;
		input [15:0] x;
		reg [3:0] s0, s1;
		begin
			s0 = add_0to4(pop4(x[3:0]),  pop4(x[7:4]));
			s1 = add_0to4(pop4(x[11:8]), pop4(x[15:12]));
			pop16 = add_0to8(s0, s1);
		end
	endfunction

	function [5:0] dec6;
		input [5:0] a;
		begin
			dec6[0] = ~a[0];
			dec6[1] = ~(a[1] ^ a[0]);
			dec6[2] = a[2] ^ (~(|a[1:0]));
			dec6[3] = a[3] ^ (~(|a[2:0]));
			dec6[4] = a[4] ^ (~(|a[3:0]));
			dec6[5] = a[5] ^ (~(|a[4:0]));
		end
	endfunction

	reg vl_go_d1;
	reg [BW-1:0] last_blk_d1;
	reg [4:0] p16_lo_r, p16_hi_r;
	wire [5:0] pop32_s;
	wire pop32_co_unused;
	am_add #(.W(6)) u_pop32 (
		.a({1'b0, p16_lo_r}),
		.b({1'b0, p16_hi_r}),
		.ci(1'b0),
		.s(pop32_s),
		.co(pop32_co_unused)
	);

	wire [BW-1:0] free_blk = pt_free_idx[5 +: BW];
	wire vl_mask_zero = (vl_mask_pt == 32'd0);

	wire [BW-1:0] end_blk = wblk[wc_warp*BW +: BW];
	wire end_own = wc_end && wv[wc_warp] && own[end_blk*WARP_W +: WARP_W] == wc_warp;

	integer cb_i;
	always @(posedge clk) begin
		if (rst_p) begin
			cnt <= {(NB*6){1'b0}};
			own <= {(NB*WARP_W){1'b0}};
			done <= {NB{1'b0}};
			last_blk <= {BW{1'b0}};
			last_blk_d1 <= {BW{1'b0}};
			vl_go_d1 <= 1'b0;
			p16_lo_r <= 5'd0;
			p16_hi_r <= 5'd0;
			wblk <= {(NWARPS*BW){1'b0}};
			wv <= {NWARPS{1'b0}};
		end else begin
			vl_go_d1 <= vl_go_pt && !vl_mask_zero;
			if (vl_go_pt) begin
				last_blk_d1 <= last_blk;
				p16_lo_r <= pop16(vl_mask_pt[15:0]);
				p16_hi_r <= pop16(vl_mask_pt[31:16]);
			end
			for (cb_i = 0; cb_i < NB; cb_i = cb_i + 1) begin
				if (pt_take && fb == cb_i[BW-1:0])
					cnt[cb_i*6 +: 6] <= 6'd32;
				else if (vl_go_pt && vl_mask_zero && last_blk == cb_i[BW-1:0])
					cnt[cb_i*6 +: 6] <= 6'd0;
				else if (vl_go_d1 && last_blk_d1 == cb_i[BW-1:0])
					cnt[cb_i*6 +: 6] <= (pt_free && free_blk == cb_i[BW-1:0]) ? dec6(pop32_s) : pop32_s;
				else if (pt_free && free_blk == cb_i[BW-1:0])
					cnt[cb_i*6 +: 6] <= dec6(cnt[cb_i*6 +: 6]);
			end
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

	wire unused_ok = &{1'b0, waddr, raddr, rbank, pt_free_idx, x_info, x_uop,
		sc_a_co_unused, pop32_co_unused};
endmodule

`default_nettype wire
