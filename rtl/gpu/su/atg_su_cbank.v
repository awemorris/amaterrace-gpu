/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_cbank: The constant bank: 256 words loaded by LOAD_CONST (DMA
 * from memory), read as c0-c31 operands (atg_su_opd's port) and by lwc
 * (long beats).
 *
 * LOAD_CONST (lc_kick, kept pending while a lwc group is in progress):
 * reads STATE 0x1EC (region; v1 loads region 0 only, other regions are
 * ignored), 0x1ED (byte address, word aligned) and 0x1EE (words, at most
 * CONST_WORDS) from the STATE broadcast, then reads the lines from the MC
 * one at a time and writes the words one per cycle into the bank (and the
 * first 32 into the c-operand copy); busy meanwhile.  An error response
 * ends the load (the words before it stay).  inv drops the contents: c
 * operands and lwc read 0 until the next load.  scrub (session
 * protection, the unit idle) writes 0 to every word of the bank and the
 * copy through their write port, one per cycle, while scrub_busy (a later
 * load does not show another session's words beyond its own).
 * c operands: cr_en registers the three words cr_idx[4:0], [9:5], [14:10]
 * of the copy; cr_data holds while cr_en is 0 (like the RF).
 * lwc: one lane group at a time (x_ready 1 only in IDLE): the EXEC lanes'
 * word index (rs1 + imm) mod CONST_WORDS is read one lane per cycle, then
 * one beat (l_wr 1, EXEC lanes, l_last = x_last, class m).
 *
 * States: IDLE →(load)→ LREQ →(req_ready)→ LWAIT →(rsp)→ LWR (words of
 * the line) → LREQ | IDLE; IDLE →(lwc)→ ACCESS → DRAIN → BEAT
 * →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_cbank #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter CONST_WORDS = 256	/* Size in words */
) (
	input wire clk,
	input wire rst_n,
	/* Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,
	/* Long result to atg_su_wb (any time; wb may refuse with l_ready = 0) */
	output wire l_valid,
	input wire l_ready,
	output wire [WARP_W-1:0] l_warp,
	output wire [GRP_W-1:0] l_grp,
	output wire [6:0] l_rd,
	output wire [NPHYS*32-1:0] l_data,
	output wire [NPHYS-1:0] l_lanes,
	output wire l_wr,
	output wire l_last,
	output wire [SBE_W:0] l_sbe,
	output wire [2:0] l_cls,
	/* c-operand read port (atg_su_opd) */
	input wire cr_en,
	input wire [14:0] cr_idx,
	output wire [95:0] cr_data,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire lc_kick,
	input wire inv,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error,
	/* Session protection: clear the contents */
	input wire scrub,
	output wire scrub_busy
);
`include "atg_su_uop.vh"
`include "ghci_regs.vh"

	localparam DW = NPHYS * 32;
	localparam LB = LINE_BYTES * 8;
	localparam CW = $clog2(CONST_WORDS);
	localparam WPL = LINE_BYTES / 4;
	localparam WW = WPL > 1 ? $clog2(WPL) : 1;
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [2:0] IDLE = 3'd0, LREQ = 3'd1, LWAIT = 3'd2, LWR = 3'd3, ACCESS = 3'd4,
		DRAIN = 3'd5, BEAT = 3'd6;

	reg [31:0] bank [0:CONST_WORDS-1];
	(* ram_style = "distributed" *) reg [31:0] cw [0:31];
	reg [2:0] st;
	reg valid, lc_pend;
	reg [31:0] s_region, s_addr, s_words;
	/* Load. */
	reg [31:0] ladr;	/* byte address of the next word */
	reg [CW:0] wi, nw;	/* next word, words */
	reg [LB-1:0] lbuf;
	/* lwc. */
	reg [NPHYS*CW-1:0] ridx;
	reg [DW-1:0] res;
	reg [NPHYS-1:0] lanes;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	reg [LW-1:0] li, pli;
	reg pval;
	reg [31:0] q;
	reg [95:0] crq;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_CBANK;
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	wire [CW-1:0] ra = st == LWR ? wi[CW-1:0] : ridx[li*CW +: CW];
	wire [WW-1:0] lwo = ladr[2 +: WW];
	wire [31:0] lword = lbuf[lwo*32 +: 32];
	assign x_ready = st == IDLE && !lc_pend && !lc_kick;

	/* Each lane's word index rs1 + imm (its low CW bits). */
	wire [NPHYS*CW-1:0] xidx;
	genvar l;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_ix
			wire co_unused;
			am_add #(.W(CW)) u_ix (.a(x_a[l*32 +: CW]), .b(imm[CW-1:0]), .ci(1'b0),
				.s(xidx[l*CW +: CW]), .co(co_unused));
		end
	endgenerate

	/* The next word of a load, its address, and the next lane. */
	wire [CW:0] wi_next;
	wire [31:0] ladr_next;
	wire [LW-1:0] li_next;
	wire wi_co_unused, la_co_unused, li_co_unused;
	am_add #(.W(CW + 1)) u_wi (.a(wi), .b({(CW + 1){1'b0}}), .ci(1'b1), .s(wi_next), .co(wi_co_unused));
	am_add #(.W(32)) u_ladr (.a(ladr), .b(32'd4), .ci(1'b0), .s(ladr_next), .co(la_co_unused));
	am_add #(.W(LW)) u_li (.a(li), .b({LW{1'b0}}), .ci(1'b1), .s(li_next), .co(li_co_unused));

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			valid <= 1'b0;
			lc_pend <= 1'b0;
			s_region <= 32'd0;
			s_addr <= 32'd0;
			s_words <= 32'd0;
			pval <= 1'b0;
			li <= {LW{1'b0}};
		end else begin
			if (st_we && st_idx == GHCI_S_LC_REGION)
				s_region <= st_wdata;
			if (st_we && st_idx == GHCI_S_LC_ADDR)
				s_addr <= st_wdata;
			if (st_we && st_idx == GHCI_S_LC_WORDS)
				s_words <= st_wdata;
			if (lc_kick)
				lc_pend <= 1'b1;
			pval <= 1'b0;
			case (st)
			IDLE:
				if (lc_pend) begin
					lc_pend <= lc_kick;
					ladr <= {s_addr[31:2], 2'b00};
					wi <= {(CW+1){1'b0}};
					nw <= s_words > CONST_WORDS ? CONST_WORDS[CW:0] : s_words[CW:0];
					if (s_region == 32'd0 && s_words != 32'd0) begin
						valid <= 1'b1;
						st <= LREQ;
					end
				end else if (mine) begin
					ridx <= xidx;
					lanes <= x_mask[NPHYS-1:0];
					res <= {DW{1'b0}};
					rrd <= x_uop[ATG_UOP_RD +: 7];
					rwarp <= x_warp;
					rgrp <= x_grp;
					rlast <= x_last;
					rsbe <= x_sbe;
					li <= {LW{1'b0}};
					st <= x_mask[NPHYS-1:0] == {NPHYS{1'b0}} ? BEAT : ACCESS;
				end
			LREQ: if (req_ready)
				st <= LWAIT;
			LWAIT: if (rsp_valid) begin
				lbuf <= rsp_rdata;
				st <= rsp_error ? IDLE : LWR;
			end
			LWR: begin
				wi <= wi_next;
				ladr <= ladr_next;
				if (wi_next == nw)
					st <= IDLE;
				else if (&lwo)
					st <= LREQ;
			end
			ACCESS: begin
				pval <= lanes[li];
				pli <= li;
				li <= li_next;
				if ({{(32-LW){1'b0}}, li} == NPHYS - 1)
					st <= DRAIN;
			end
			DRAIN: st <= BEAT;
			BEAT: if (l_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
			if (pval)
				res[pli*32 +: 32] <= valid ? q : 32'd0;
			if (inv)
				valid <= 1'b0;
			if (cr_en)
				crq <= valid ? {cw[cr_idx[14:10]], cw[cr_idx[9:5]], cw[cr_idx[4:0]]} : 96'd0;
		end
	end

	/* The write port: a load's words, or the scrub's zeros. */
	wire sc_on;
	wire [CW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(CONST_WORDS), .AW(CW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	assign scrub_busy = sc_on;
	wire [CW-1:0] b_wa = sc_on ? sc_a : wi[CW-1:0];
	wire [31:0] b_wd = sc_on ? 32'd0 : lword;

	always @(posedge clk)
		if (sc_on || st == LWR) begin
			bank[b_wa] <= b_wd;
			if (sc_on ? {{(32-CW){1'b0}}, sc_a} < 32 : wi < 32)
				cw[b_wa[4:0]] <= b_wd;
		end

	/* The bank's registered read. */
	always @(posedge clk)
		q <= bank[ra];

	assign cr_data = crq;
	assign busy = st == LREQ || st == LWAIT || st == LWR || lc_pend;
	assign req_valid = st == LREQ;
	assign req_write = 1'b0;
	assign req_line = ladr[ADDR_W-1:LINE_SHIFT];
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	assign l_valid = st == BEAT;
	assign l_warp = rwarp;
	assign l_grp = rgrp;
	assign l_rd = rrd;
	assign l_data = res;
	assign l_lanes = lanes;
	assign l_wr = 1'b1;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_M;

	wire unused_ok = &{1'b0, x_pc, x_b, x_c, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop, imm, x_a,
		rsp_write, rsp_tag, (NWARPS != 0), ladr[1:0], s_addr[1:0]};
endmodule

`default_nettype wire
