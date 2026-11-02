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
	localparam [3:0] IDLE = 4'd0, LREQ = 4'd1, LWAIT = 4'd2, LWR = 4'd3, ACCESS = 4'd4,
		DRAIN = 4'd5, DRAIN2 = 4'd6, BEAT = 4'd7, DRAIN3 = 4'd8;

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	reg [31:0] bank [0:CONST_WORDS-1];
	(* max_fanout = 12 *) reg [3:0] st;
	(* max_fanout = 12 *) reg valid, lc_pend;
	reg [31:0] s_region, s_addr, s_words;
	/* Load. */
	(* max_fanout = 12 *) reg [31:0] ladr;	/* byte address of the next word */
	(* max_fanout = 12 *) reg [CW:0] wi, nw;	/* next word, words */
	wire [LB-1:0] lbuf;
	/* lwc. */
	wire [NPHYS*CW-1:0] ridx;
	wire [DW-1:0] res;
	(* max_fanout = 12 *) reg [NPHYS-1:0] lanes;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LW-1:0] li, pli, pli_d, pli_d2;
	(* shreg_extract = "no", max_fanout = 12 *) reg pval, pval_d, pval_d2;
	(* dont_touch = "true" *) reg [CW-1:0] ra_r;
	reg [31:0] q;
	(* dont_touch = "true" *) reg [31:0] q_pipe;
	wire [95:0] crq;
	(* max_fanout = 12 *) reg b_we_r, cw_we_r;
	(* dont_touch = "true" *) reg [CW-1:0] b_wa_r;
	(* max_fanout = 12 *) reg [4:0] cw_wa_r;
	(* max_fanout = 12 *) reg [31:0] b_wd_r;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_CBANK;
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	wire [WW-1:0] lwo = ladr[2 +: WW];
	wire [31:0] lword = lbuf[lwo*32 +: 32];
	assign x_ready = st == IDLE && !lc_pend && !lc_kick && !b_we_r;

	wire sc_on;
	wire [CW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(CONST_WORDS), .AW(CW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	wire [CW-1:0] sc_a_next;
	wire sc_a_co_unused;
	am_add #(.W(CW)) u_sc_a_next (.a(sc_a), .b({CW{1'b0}}), .ci(1'b1), .s(sc_a_next), .co(sc_a_co_unused));

	assign scrub_busy = sc_on;
	wire sc_done = ({{(32-CW){1'b0}}, sc_a} == CONST_WORDS - 1);
	wire cw_we_next = rst_p ? 1'b0 : scrub ? 1'b1 : sc_on ? (!sc_done && ({{(32-CW){1'b0}}, sc_a_next} < 32)) :
		(st == LWR) ? (wi < 32) : 1'b0;
	wire [4:0] cw_wa_next = (rst_p || scrub) ? 5'd0 : sc_on ? sc_a_next[4:0] : wi[4:0];
	wire valid_next = rst_p ? 1'b0 : inv ? 1'b0 :
		(st == IDLE && lc_pend && s_region == 32'd0 && s_words != 32'd0) ? 1'b1 : valid;

	/* Sliced distributed RAM cw (8 x 4-bit slices) so each address/WE net drives <= 12 RAM primitives */
	wire [31:0] cw_r0, cw_r1, cw_r2;
	genvar gcs, gcl, gch;
	generate
	for (gcs = 0; gcs < 8; gcs = gcs + 1) begin : g_cw_sl
		(* ram_style = "distributed" *) reg [3:0] cw_mem [0:31];
		(* dont_touch = "true" *) reg cw_we_sl_r;
		(* dont_touch = "true" *) reg [4:0] cw_wa_sl_r;
		(* dont_touch = "true" *) wire [4:0] cr_a0_s = cr_idx[4:0];
		(* dont_touch = "true" *) wire [4:0] cr_a1_s = cr_idx[9:5];
		(* dont_touch = "true" *) wire [4:0] cr_a2_s = cr_idx[14:10];
		always @(posedge clk) begin
			cw_we_sl_r <= cw_we_next;
			if (rst_p || scrub || sc_on || st == LWR)
				cw_wa_sl_r <= cw_wa_next;
			if (cw_we_sl_r)
				cw_mem[cw_wa_sl_r] <= b_wd_r[gcs*4 +: 4];
		end
		assign cw_r0[gcs*4 +: 4] = cw_mem[cr_a0_s];
		assign cw_r1[gcs*4 +: 4] = cw_mem[cr_a1_s];
		assign cw_r2[gcs*4 +: 4] = cw_mem[cr_a2_s];
	end
	endgenerate
	wire [95:0] cw_rdata = {cw_r2, cw_r1, cw_r0};

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

	/* Sliced wide registers res, lbuf, ridx, crq to bound CE fanout <= 16 */
	generate
	for (gcl = 0; gcl < NPHYS; gcl = gcl + 1) begin : g_cb_res
		(* shreg_extract = "no" *) reg [CW-1:0] ridx_l;
		(* dont_touch = "true" *) wire ridx_we_l = (st == IDLE) && !lc_pend && mine && !rst_p;
		always @(posedge clk)
			if (ridx_we_l)
				ridx_l <= xidx[gcl*CW +: CW];
		assign ridx[gcl*CW +: CW] = ridx_l;
		for (gch = 0; gch < 2; gch = gch + 1) begin : g_cb_res_h
			(* shreg_extract = "no" *) reg [15:0] res_h;
			(* dont_touch = "true" *) reg valid_res_h;
			(* dont_touch = "true" *) wire res_clr_h = (st == IDLE) && !lc_pend && mine && !rst_p;
			(* dont_touch = "true" *) wire res_we_h = pval_d2 && (pli_d2 == gcl[LW-1:0]) && !rst_p;
			always @(posedge clk) begin
				valid_res_h <= valid_next;
				if (res_clr_h)
					res_h <= 16'd0;
				else if (res_we_h)
					res_h <= valid_res_h ? q_pipe[gch*16 +: 16] : 16'd0;
			end
			assign res[gcl*32 + gch*16 +: 16] = res_h;
		end
	end
	for (gcl = 0; gcl < LB / 16; gcl = gcl + 1) begin : g_cb_lbuf
		(* shreg_extract = "no" *) reg [15:0] lbuf_s;
		(* dont_touch = "true" *) wire lbuf_we_s = (st == LWAIT) && rsp_valid && !rst_p;
		always @(posedge clk)
			if (lbuf_we_s)
				lbuf_s <= rsp_rdata[gcl*16 +: 16];
		assign lbuf[gcl*16 +: 16] = lbuf_s;
	end
	for (gcl = 0; gcl < 6; gcl = gcl + 1) begin : g_cb_crq
		(* shreg_extract = "no" *) reg [15:0] crq_s;
		(* dont_touch = "true" *) reg valid_crq_s;
		(* dont_touch = "true" *) reg crq_rdy_s;
		(* dont_touch = "true" *) wire crq_we_s = cr_en && crq_rdy_s;
		always @(posedge clk) begin
			valid_crq_s <= valid_next;
			crq_rdy_s <= !rst_p;
			if (crq_we_s)
				crq_s <= valid_crq_s ? cw_rdata[gcl*16 +: 16] : 16'd0;
		end
		assign crq[gcl*16 +: 16] = crq_s;
	end
	endgenerate

	(* dont_touch = "true" *) wire s_reg_we_lo = st_we && (st_idx == GHCI_S_LC_REGION) && !rst_p;
	(* dont_touch = "true" *) wire s_reg_we_hi = st_we && (st_idx == GHCI_S_LC_REGION) && !rst_p;
	(* dont_touch = "true" *) wire s_adr_we_lo = st_we && (st_idx == GHCI_S_LC_ADDR) && !rst_p;
	(* dont_touch = "true" *) wire s_adr_we_hi = st_we && (st_idx == GHCI_S_LC_ADDR) && !rst_p;
	(* dont_touch = "true" *) wire s_wrd_we_lo = st_we && (st_idx == GHCI_S_LC_WORDS) && !rst_p;
	(* dont_touch = "true" *) wire s_wrd_we_hi = st_we && (st_idx == GHCI_S_LC_WORDS) && !rst_p;
	(* dont_touch = "true" *) wire ladr_we_lo  = ((st == IDLE && lc_pend) || (st == LWR)) && !rst_p;
	(* dont_touch = "true" *) wire ladr_we_hi  = ((st == IDLE && lc_pend) || (st == LWR)) && !rst_p;
	wire [31:0] ladr_mux = (st == IDLE) ? {s_addr[31:2], 2'b00} : ladr_next;

	always @(posedge clk) begin
		if (ladr_we_lo) ladr[15:0]  <= ladr_mux[15:0];
		if (ladr_we_hi) ladr[31:16] <= ladr_mux[31:16];
		if (rst_p) begin
			st <= IDLE;
			valid <= 1'b0;
			lc_pend <= 1'b0;
			s_region <= 32'd0;
			s_addr <= 32'd0;
			s_words <= 32'd0;
			pval <= 1'b0;
			pval_d <= 1'b0;
			pval_d2 <= 1'b0;
			li <= {LW{1'b0}};
			pli <= {LW{1'b0}};
			pli_d <= {LW{1'b0}};
			pli_d2 <= {LW{1'b0}};
			ra_r <= {CW{1'b0}};
		end else begin
			if (s_reg_we_lo) s_region[15:0]  <= st_wdata[15:0];
			if (s_reg_we_hi) s_region[31:16] <= st_wdata[31:16];
			if (s_adr_we_lo) s_addr[15:0]    <= st_wdata[15:0];
			if (s_adr_we_hi) s_addr[31:16]   <= st_wdata[31:16];
			if (s_wrd_we_lo) s_words[15:0]   <= st_wdata[15:0];
			if (s_wrd_we_hi) s_words[31:16]  <= st_wdata[31:16];
			if (lc_kick)
				lc_pend <= 1'b1;
			pval <= 1'b0;
			pval_d <= pval;
			pval_d2 <= pval_d;
			pli_d <= pli;
			pli_d2 <= pli_d;
			case (st)
			IDLE:
				if (lc_pend) begin
					lc_pend <= lc_kick;
					wi <= {(CW+1){1'b0}};
					nw <= s_words > CONST_WORDS ? CONST_WORDS[CW:0] : s_words[CW:0];
					if (s_region == 32'd0 && s_words != 32'd0) begin
						valid <= 1'b1;
						st <= LREQ;
					end
				end else if (mine) begin
					lanes <= x_mask[NPHYS-1:0];
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
				st <= rsp_error ? IDLE : LWR;
			end
			LWR: begin
				wi <= wi_next;
				if (wi_next == nw)
					st <= IDLE;
				else if (&lwo)
					st <= LREQ;
			end
			ACCESS: begin
				pval <= lanes[li];
				pli <= li;
				li <= li_next;
				ra_r <= ridx[li*CW +: CW];
				if ({{(32-LW){1'b0}}, li} == NPHYS - 1)
					st <= DRAIN;
			end
			DRAIN: st <= DRAIN2;
			DRAIN2: st <= DRAIN3;
			DRAIN3: st <= BEAT;
			BEAT: if (l_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
			if (inv)
				valid <= 1'b0;
		end
	end

	(* dont_touch = "true" *) wire b_wd_zero_lo = rst_p || scrub || sc_on;
	(* dont_touch = "true" *) wire b_wd_zero_hi = rst_p || scrub || sc_on;
	(* dont_touch = "true" *) wire b_wd_we_lo   = (st == LWR) && !rst_p;
	(* dont_touch = "true" *) wire b_wd_we_hi   = (st == LWR) && !rst_p;

	always @(posedge clk) begin
		if (b_wd_zero_lo)
			b_wd_r[15:0] <= 16'd0;
		else if (b_wd_we_lo)
			b_wd_r[15:0] <= lword[15:0];

		if (b_wd_zero_hi)
			b_wd_r[31:16] <= 16'd0;
		else if (b_wd_we_hi)
			b_wd_r[31:16] <= lword[31:16];

		if (rst_p) begin
			b_we_r  <= 1'b0;
			cw_we_r <= 1'b0;
			b_wa_r  <= {CW{1'b0}};
			cw_wa_r <= 5'd0;
		end else if (scrub) begin
			b_we_r  <= 1'b1;
			cw_we_r <= 1'b1;
			b_wa_r  <= {CW{1'b0}};
			cw_wa_r <= 5'd0;
		end else if (sc_on) begin
			b_we_r  <= !sc_done;
			cw_we_r <= !sc_done && ({{(32-CW){1'b0}}, sc_a_next} < 32);
			b_wa_r  <= sc_a_next;
			cw_wa_r <= sc_a_next[4:0];
		end else if (st == LWR) begin
			b_we_r  <= 1'b1;
			cw_we_r <= wi < 32;
			b_wa_r  <= wi[CW-1:0];
			cw_wa_r <= wi[4:0];
		end else begin
			b_we_r  <= 1'b0;
			cw_we_r <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (b_we_r)
			bank[b_wa_r] <= b_wd_r;
	end

	/* The bank's registered read + dedicated fabric output register (Rule 4). */
	always @(posedge clk) begin
		q <= bank[ra_r];
		q_pipe <= q;
	end

	assign cr_data = crq;
	assign busy = st == LREQ || st == LWAIT || st == LWR || lc_pend || (b_we_r && !sc_on);
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
		rsp_write, rsp_tag, sc_a_co_unused, (NWARPS != 0), ladr[1:0], s_addr[1:0], cw_we_r, cw_wa_r};
endmodule

`default_nettype wire
