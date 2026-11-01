/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lsu: Global memory: lw/sw/atom of NPHYS lanes per group through
 * the coalescer (lanes merged into line requests), the SU's D$
 * (atg_su_dcache) and the MC's atomic unit; fence's acquire invalidate.
 *
 * One lane group at a time (x_ready is 1 only in IDLE):
 *   lw   the EXEC lanes' byte addresses rs1 + imm (word aligned: bits 1:0
 *        are ignored) are coalesced: the line of the first pending lane is
 *        read from the D$, every pending lane in that line takes its word,
 *        until no lane is pending; then one beat (l_wr 1, EXEC lanes);
 *   sw   the side-effect lanes are coalesced the same way into line writes
 *        with byte enables (when two lanes write one word the higher lane
 *        wins); each write's response is waited for; then a beat without
 *        data (l_wr 0), so cm falls after the stores are done (design
 *        §3.1.1); sw.x (the uop's sub[0], a store to the warp's scratch
 *        memory) takes the EXEC lanes instead, helper and killed lanes
 *        included;
 *   atom one at_* operation per side-effect lane, in lane order (at_op =
 *        the uop's sub: and or xor xchg add sub smax smin umax umin
 *        cmpxchg), the D$ invalidated first (dc_inv); the old values are
 *        the beat's data when rd is written (l_wr = WRD);
 *   fence (class a, no beat) pulses dc_inv when imm[2] (acquire) is set;
 *        atg_su_sb has waited for cm = 0 before issuing it.
 * A group without lanes returns its beat at once.  dc_rsp_error and
 * at_error give 0 to the lanes concerned (the MC raised the fault).  Every
 * beat carries the group's x_last as l_last, class m and x_sbe.  Requests
 * are in order, so a warp's sw is complete before its next lw is read.
 *
 * States: IDLE →(group)→ LINE (request the next line) →(dc_req_ready)→
 * WAIT →(dc_rsp)→ LINE | BEAT; IDLE →(atom)→ AREQ →(at_ready)→ AWAIT
 * →(at_rsp)→ AREQ | BEAT; BEAT →(l_ready)→ IDLE.
*/

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lsu #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
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
	/* AMB client port (design §4.1) */
	output wire dc_req_valid,
	input wire dc_req_ready,
	output wire dc_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] dc_req_line,
	output wire [LINE_BYTES-1:0] dc_req_be,
	output wire [LINE_BYTES*8-1:0] dc_req_wdata,
	output wire [7:0] dc_req_tag,
	input wire dc_rsp_valid,
	input wire dc_rsp_write,
	input wire [7:0] dc_rsp_tag,
	input wire [LINE_BYTES*8-1:0] dc_rsp_rdata,
	input wire dc_rsp_error,
	/* Atomic port (to atg_mc_atom) */
	output wire at_valid,
	input wire at_ready,
	output wire [3:0] at_op,
	output wire [29:0] at_addr,
	output wire [31:0] at_a,
	output wire [31:0] at_b,
	input wire at_rsp_valid,
	input wire [31:0] at_old,
	input wire at_error,
	output wire dc_inv
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam LB = LINE_BYTES * 8;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam WPL = LINE_BYTES / 4;
	localparam WW = WPL > 1 ? $clog2(WPL) : 1;
	localparam LW = NPHYS > 1 ? $clog2(NPHYS) : 1;
	localparam [2:0] IDLE = 3'd0, LINE = 3'd1, WAIT = 3'd2, AREQ = 3'd3, AWAIT = 3'd4,
		BEAT = 3'd5, LINE_HIT = 3'd6, LINE_DAT = 3'd7;

	(* keep = "true" *) wire rst_p = !rst_n;
	(* max_fanout = 12 *) reg [2:0] st;
	wire [DW-1:0] radr, rdat, rcmp, res;
	(* max_fanout = 12 *) reg [NPHYS-1:0] pend, lanes, cur, lhit;
	(* max_fanout = 12 *) reg rwr, rst_w, ratom;
	(* max_fanout = 12 *) reg [3:0] rsub;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	(* max_fanout = 12 *) reg [LA_W-1:0] cline;
	(* dont_touch = "true" *) reg [LA_W-1:0] dc_line_r;
	wire [LINE_BYTES-1:0] cbe;
	wire [LB-1:0] cwd;
	(* max_fanout = 12 *) reg [LW-1:0] ali;
	reg inv_q;

	wire [3:0] unit = x_uop[ATG_UOP_UNIT +: 4];
	(* max_fanout = 12 *) wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire mine = x_valid && unit == ATG_UNIT_LSU;
	wire take = mine && st == IDLE && op != ATG_LSU_FENCE;
	(* keep = "true", max_fanout = 16 *) wire take_base = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE);
	(* max_fanout = 12 *) wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	/* The lanes of the access: EXEC for lw and sw.x, the side-effect lanes otherwise. */
	wire use_exec = op == ATG_LSU_LW || (op == ATG_LSU_SW && x_uop[ATG_UOP_SUB]);
	wire [NPHYS-1:0] amask = use_exec ? x_mask[NPHYS-1:0] : x_mask[2*NPHYS-1:NPHYS];
	assign x_ready = st == IDLE;

	/* The first pending lane and the lanes in its line, with the write's
	 * byte enables and data. */
	(* max_fanout = 12 *) reg [LW:0] lead;
	reg [NPHYS-1:0] inl;
	wire [NPHYS-1:0] line_eq;
	reg [LA_W-1:0] lline;
	reg [LINE_BYTES-1:0] lbe;
	reg [LB-1:0] lwd;
	reg [WW-1:0] wo;
	integer l;
	always @(*) begin
		lead = NPHYS[LW:0];
		for (l = NPHYS - 1; l >= 0; l = l - 1)
			if (pend[l])
				lead = l[LW:0];
		lline = radr[lead[LW-1:0]*32 + LINE_SHIFT +: LA_W];
		inl = {NPHYS{1'b0}};
		lbe = {LINE_BYTES{1'b0}};
		lwd = {LB{1'b0}};
		for (l = 0; l < NPHYS; l = l + 1) begin
			wo = radr[l*32 + 2 +: WW];
			if (pend[l] && lhit[l]) begin
				inl[l] = 1'b1;
				lbe[wo*4 +: 4] = 4'hF;
				lwd[wo*32 +: 32] = rdat[l*32 +: 32];
			end
		end
	end

	/* The next atomic lane. */
	(* max_fanout = 12 *) reg [LW:0] anext;
	integer l2;
	always @(*) begin
		anext = NPHYS[LW:0];
		for (l2 = NPHYS - 1; l2 >= 0; l2 = l2 - 1)
			if (pend[l2])
				anext = l2[LW:0];
	end

	/* Each lane's word of the D$ response. */
	reg [DW-1:0] rsel;
	reg [WW-1:0] ro;
	integer l3;

	/* The lanes' addresses: rs1 + imm (rs1 alone for an atomic). */
	localparam N_LEQ = (LA_W + 2) / 3;
	wire [DW-1:0] x_adr;
	genvar la, gh, gleq;
	generate
		for (la = 0; la < NPHYS; la = la + 1) begin : g_adr
			wire co_unused;
			am_add #(.W(32)) u_adr (.a(x_a[la*32 +: 32]), .b(op == ATG_LSU_ATOM ? 32'd0 : imm),
				.ci(1'b0), .s(x_adr[la*32 +: 32]), .co(co_unused));
			(* keep = "true" *) wire [N_LEQ-1:0] leq_g;
			for (gleq = 0; gleq < N_LEQ; gleq = gleq + 1) begin : g_leq
				localparam LB_B = gleq * 3;
				localparam LW_C = (LB_B + 3 <= LA_W) ? 3 : (LA_W - LB_B);
				assign leq_g[gleq] = (radr[la*32 + LINE_SHIFT + LB_B +: LW_C] == cline[LB_B +: LW_C]);
			end
			(* keep = "true" *) wire leq_lo = &leq_g[N_LEQ/2-1:0];
			(* keep = "true" *) wire leq_hi = &leq_g[N_LEQ-1:N_LEQ/2];
			assign line_eq[la] = leq_lo && leq_hi;
			for (gh = 0; gh < 2; gh = gh + 1) begin : g_lsu_half
				(* shreg_extract = "no" *) reg [15:0] radr_h, rdat_h, rcmp_h, res_h;
				(* keep = "true" *) wire take_h = take_base && (op != ATG_LSU_FENCE);
				(* keep = "true" *) wire dc_we_h = (st == WAIT) && dc_rsp_valid && cur[la];
				(* keep = "true" *) wire dc_err_h = dc_rsp_error;
				(* keep = "true" *) wire at_we_h = (st == AWAIT) && at_rsp_valid && (ali == la[LW-1:0]);
				(* keep = "true" *) wire at_err_h = at_error;
				always @(posedge clk) begin
					if (take_h) begin
						radr_h <= x_adr[la*32 + gh*16 +: 16];
						rdat_h <= x_b[la*32 + gh*16 +: 16];
						rcmp_h <= x_c[la*32 + gh*16 +: 16];
						res_h  <= 16'd0;
					end else if (dc_we_h) begin
						res_h <= dc_err_h ? 16'd0 : rsel[la*32 + gh*16 +: 16];
					end else if (at_we_h) begin
						res_h <= at_err_h ? 16'd0 : at_old[gh*16 +: 16];
					end
				end
				assign radr[la*32 + gh*16 +: 16] = radr_h;
				assign rdat[la*32 + gh*16 +: 16] = rdat_h;
				assign rcmp[la*32 + gh*16 +: 16] = rcmp_h;
				assign res[la*32 + gh*16 +: 16]  = res_h;
			end
		end
		for (la = 0; la < LB / 16; la = la + 1) begin : g_cwd_sl
			(* shreg_extract = "no" *) reg [15:0] cwd_sl;
			(* keep = "true" *) wire cwd_we_sl = (st == LINE_DAT);
			always @(posedge clk)
				if (cwd_we_sl)
					cwd_sl <= lwd[la*16 +: 16];
			assign cwd[la*16 +: 16] = cwd_sl;
		end
		for (la = 0; la < LINE_BYTES / 16; la = la + 1) begin : g_cbe_sl
			(* shreg_extract = "no" *) reg [15:0] cbe_sl;
			(* keep = "true" *) wire cbe_we_sl = (st == LINE_DAT);
			(* keep = "true" *) wire rwr_sl = rwr;
			always @(posedge clk)
				if (cbe_we_sl)
					cbe_sl <= lbe[la*16 +: 16];
			assign cbe[la*16 +: 16] = cbe_sl;
			assign dc_req_be[la*16 +: 16] = rwr_sl ? cbe_sl : 16'd0;
		end
	endgenerate
	always @(*)
		for (l3 = 0; l3 < NPHYS; l3 = l3 + 1) begin
			ro = radr[l3*32 + 2 +: WW];
			rsel[l3*32 +: 32] = dc_rsp_rdata[ro*32 +: 32];
		end

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
			inv_q <= 1'b0;
			pend <= {NPHYS{1'b0}};
			ali <= {LW{1'b0}};
			cline <= {LA_W{1'b0}};
			dc_line_r <= {LA_W{1'b0}};
		end else begin
			inv_q <= mine && st == IDLE && op == ATG_LSU_FENCE && imm[2];
			case (st)
			IDLE: if (take) begin
				rwr <= op == ATG_LSU_SW;
				ratom <= op == ATG_LSU_ATOM;
				rst_w <= op == ATG_LSU_LW || (op == ATG_LSU_ATOM && x_uop[ATG_UOP_WRD]);
				rsub <= x_uop[ATG_UOP_SUB +: 4];
				rrd <= x_uop[ATG_UOP_RD +: 7];
				rwarp <= x_warp;
				rgrp <= x_grp;
				rlast <= x_last;
				rsbe <= x_sbe;
				lanes <= amask;
				pend <= amask;
				if (amask == {NPHYS{1'b0}})
					st <= BEAT;
				else if (op == ATG_LSU_ATOM) begin
					inv_q <= 1'b1;
					st <= AREQ;
				end else
					st <= LINE;
			end
			LINE: begin
				if (lead == NPHYS[LW:0])
					st <= BEAT;
				else begin
					cline <= lline;
					dc_line_r <= lline;
					st <= LINE_HIT;
				end
			end
			LINE_HIT: begin
				lhit <= line_eq;
				st <= LINE_DAT;
			end
			LINE_DAT: begin
				cur <= inl;
				st <= WAIT;
			end
			WAIT: if (dc_rsp_valid) begin
				pend <= pend & ~cur;
				st <= LINE;
			end
			AREQ: if (anext == NPHYS[LW:0])
				st <= BEAT;
			else begin
				ali <= anext[LW-1:0];
				if (at_ready)
					st <= AWAIT;
			end
			AWAIT: if (at_rsp_valid) begin
				pend[ali] <= 1'b0;
				st <= AREQ;
			end
			default: if (l_ready)
				st <= IDLE;
			endcase
		end
	end

	/* The D$ request is valid in WAIT until taken (cline holds). */
	reg req_taken;
	always @(posedge clk)
		if (rst_p || st != WAIT)
			req_taken <= 1'b0;
		else if (dc_req_valid && dc_req_ready)
			req_taken <= 1'b1;
	assign dc_req_valid = st == WAIT && !req_taken;
	assign dc_req_write = rwr;
	assign dc_req_line = dc_line_r;
	assign dc_req_wdata = cwd;
	assign dc_req_tag = 8'd0;
	assign dc_inv = inv_q;

	wire [LW-1:0] an = anext[LW-1:0];
	assign at_valid = st == AREQ && anext != NPHYS[LW:0];
	assign at_op = rsub;
	assign at_addr = radr[an*32 + 2 +: 30];
	assign at_a = rdat[an*32 +: 32];
	assign at_b = rcmp[an*32 +: 32];

	assign l_valid = st == BEAT;
	assign l_warp = rwarp;
	assign l_grp = rgrp;
	assign l_rd = rrd;
	assign l_data = res;
	assign l_lanes = lanes;
	assign l_wr = rst_w;
	assign l_last = rlast;
	assign l_sbe = rsbe;
	assign l_cls = ATG_CLS_M;

	wire unused_ok = &{1'b0, x_pc, x_info, x_uop, imm, dc_rsp_write, dc_rsp_tag, ratom,
		(NWARPS != 0)};
endmodule

`default_nettype wire
