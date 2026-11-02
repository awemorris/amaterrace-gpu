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

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* max_fanout = 12 *) reg [2:0] st;
	wire [DW-1:0] radr, rdat, rcmp, res;
	(* dont_touch = "true" *) reg [NPHYS-1:0] pend, pend_a, pend_b, pend_be;
	(* dont_touch = "true" *) reg [NPHYS-1:0] lhit, lhit_a, lhit_b, lhit_be;
	(* max_fanout = 12 *) reg [NPHYS-1:0] lanes, cur;
	(* max_fanout = 12 *) reg rwr, rst_w, ratom;
	(* max_fanout = 12 *) reg [3:0] rsub;
	reg [6:0] rrd;
	reg [WARP_W-1:0] rwarp;
	reg [GRP_W-1:0] rgrp;
	reg rlast;
	reg [SBE_W:0] rsbe;
	localparam LA_LO = LA_W / 2;
	localparam LA_HI = LA_W - LA_LO;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LA_LO-1:0] cline_lo;
	(* shreg_extract = "no", max_fanout = 12 *) reg [LA_HI-1:0] cline_hi;
	(* dont_touch = "true" *) reg [LA_LO-1:0] dc_line_lo_r;
	(* dont_touch = "true" *) reg [LA_HI-1:0] dc_line_hi_r;
	wire [LA_W-1:0] cline = {cline_hi, cline_lo};
	wire [LA_W-1:0] dc_line_r = {dc_line_hi_r, dc_line_lo_r};
	wire [LINE_BYTES-1:0] cbe;
	wire [LB-1:0] cwd;
	(* max_fanout = 12 *) reg [LW-1:0] ali;
	reg inv_q;

	wire [3:0] unit = x_uop[ATG_UOP_UNIT +: 4];
	(* max_fanout = 12 *) wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire mine = x_valid && unit == ATG_UNIT_LSU;
	wire take = mine && st == IDLE && op != ATG_LSU_FENCE;
	(* max_fanout = 12 *) wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	/* The lanes of the access: EXEC for lw and sw.x, the side-effect lanes otherwise. */
	wire use_exec = op == ATG_LSU_LW || (op == ATG_LSU_SW && x_uop[ATG_UOP_SUB]);
	wire [NPHYS-1:0] amask = use_exec ? x_mask[NPHYS-1:0] : x_mask[2*NPHYS-1:NPHYS];
	assign x_ready = st == IDLE;

	/* The first pending lane and the lanes in its line. */
	(* max_fanout = 12 *) reg [LW:0] lead;
	wire [NPHYS-1:0] inl = pend & lhit;
	wire [NPHYS-1:0] line_eq;
	reg [LA_W-1:0] lline;
	integer l;
	always @(*) begin
		lead = NPHYS[LW:0];
		for (l = NPHYS - 1; l >= 0; l = l - 1)
			if (pend[l])
				lead = l[LW:0];
		lline = radr[lead[LW-1:0]*32 + LINE_SHIFT +: LA_W];
	end

	/* The next atomic lane. */
	reg [LW:0] anext;
	integer l2;
	always @(*) begin
		anext = NPHYS[LW:0];
		for (l2 = NPHYS - 1; l2 >= 0; l2 = l2 - 1)
			if (pend[l2])
				anext = l2[LW:0];
	end

	/* The lanes' addresses: rs1 + imm (rs1 alone for an atomic). */
	localparam N_LEQ = (LA_W + 2) / 3;
	wire [DW-1:0] x_adr;
	wire [NPHYS*WW-1:0] rwo_wr_a_bus, rwo_wr_b_bus, rwo_wr_be_bus;
	genvar la, gh, gleq, gl;
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

			(* dont_touch = "true" *) wire take_wo = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
			(* dont_touch = "true" *) reg [WW-1:0] rwo_rd_0, rwo_rd_1, rwo_rd_2, rwo_rd_3, rwo_wr_a, rwo_wr_b, rwo_wr_be;
			always @(posedge clk) begin
				if (take_wo) begin
					rwo_rd_0  <= x_adr[la*32 + 2 +: WW];
					rwo_rd_1  <= x_adr[la*32 + 2 +: WW];
					rwo_rd_2  <= x_adr[la*32 + 2 +: WW];
					rwo_rd_3  <= x_adr[la*32 + 2 +: WW];
					rwo_wr_a  <= x_adr[la*32 + 2 +: WW];
					rwo_wr_b  <= x_adr[la*32 + 2 +: WW];
					rwo_wr_be <= x_adr[la*32 + 2 +: WW];
				end
			end
			assign rwo_wr_a_bus[la*WW +: WW]  = rwo_wr_a;
			assign rwo_wr_b_bus[la*WW +: WW]  = rwo_wr_b;
			assign rwo_wr_be_bus[la*WW +: WW] = rwo_wr_be;

			for (gh = 0; gh < 4; gh = gh + 1) begin : g_lsu_half
				wire [WW-1:0] rwo_rd_h = (gh == 0) ? rwo_rd_0 :
				                         (gh == 1) ? rwo_rd_1 :
				                         (gh == 2) ? rwo_rd_2 : rwo_rd_3;
				reg [7:0] rsel_h;
				integer rwi;
				always @(*) begin
					rsel_h = dc_rsp_rdata[gh*8 +: 8];
					for (rwi = 1; rwi < WPL; rwi = rwi + 1)
						if (rwo_rd_h == rwi[WW-1:0])
							rsel_h = dc_rsp_rdata[rwi*32 + gh*8 +: 8];
				end
				(* shreg_extract = "no" *) reg [7:0] radr_h, rdat_h, rcmp_h, res_h;
				(* dont_touch = "true" *) wire take_adr_h = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
				(* dont_touch = "true" *) wire take_dat_h = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
				(* dont_touch = "true" *) wire take_cmp_h = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
				(* dont_touch = "true" *) wire take_res_h = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
				(* dont_touch = "true" *) wire dc_we_h = (st == WAIT) && dc_rsp_valid && cur[la];
				(* dont_touch = "true" *) wire dc_err_h = dc_rsp_error;
				(* dont_touch = "true" *) wire at_we_h = (st == AWAIT) && at_rsp_valid && (ali == la[LW-1:0]);
				(* dont_touch = "true" *) wire at_err_h = at_error;
				always @(posedge clk) begin
					if (take_adr_h)
						radr_h <= x_adr[la*32 + gh*8 +: 8];
					if (take_dat_h)
						rdat_h <= x_b[la*32 + gh*8 +: 8];
					if (take_cmp_h)
						rcmp_h <= x_c[la*32 + gh*8 +: 8];
					if (take_res_h) begin
						res_h <= 8'd0;
					end else if (dc_we_h) begin
						res_h <= dc_err_h ? 8'd0 : rsel_h;
					end else if (at_we_h) begin
						res_h <= at_err_h ? 8'd0 : at_old[gh*8 +: 8];
					end
				end
				assign radr[la*32 + gh*8 +: 8] = radr_h;
				assign rdat[la*32 + gh*8 +: 8] = rdat_h;
				assign rcmp[la*32 + gh*8 +: 8] = rcmp_h;
				assign res[la*32 + gh*8 +: 8]  = res_h;
			end
		end
		for (la = 0; la < LB / 16; la = la + 1) begin : g_cwd_sl
			localparam W_IDX = la / 2;
			localparam H_IDX = la % 2;
			wire [NPHYS-1:0] sl_hit_0, sl_hit_1;
			for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_sl_hit
				wire [WW-1:0] wo_g = (H_IDX == 0) ? rwo_wr_a_bus[gl*WW +: WW] : rwo_wr_b_bus[gl*WW +: WW];
				wire lh_g = (H_IDX == 0) ? lhit_a[gl] : lhit_b[gl];
				wire pd_g = (H_IDX == 0) ? pend_a[gl] : pend_b[gl];
				wire hit = pd_g && lh_g && (wo_g == W_IDX[WW-1:0]);
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_h0 (.I0(hit), .O(sl_hit_0[gl]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_h1 (.I0(hit), .O(sl_hit_1[gl]));
`else
				assign sl_hit_0[gl] = hit;
				assign sl_hit_1[gl] = hit;
`endif
			end
			reg [7:0] lwd_sl_0, lwd_sl_1;
			integer sl_l;
			always @(*) begin
				lwd_sl_0 = 8'd0;
				for (sl_l = 0; sl_l < NPHYS; sl_l = sl_l + 1)
					if (sl_hit_0[sl_l])
						lwd_sl_0 = rdat[sl_l*32 + H_IDX*16 +: 8];
			end
			always @(*) begin
				lwd_sl_1 = 8'd0;
				for (sl_l = 0; sl_l < NPHYS; sl_l = sl_l + 1)
					if (sl_hit_1[sl_l])
						lwd_sl_1 = rdat[sl_l*32 + H_IDX*16 + 8 +: 8];
			end
			wire [15:0] lwd_sl = {lwd_sl_1, lwd_sl_0};
			(* shreg_extract = "no" *) reg [15:0] cwd_sl;
			wire cwd_we_sl;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_cwdwe (.I0(st == LINE_DAT), .O(cwd_we_sl));
`else
			assign cwd_we_sl = (st == LINE_DAT);
`endif
			always @(posedge clk)
				if (cwd_we_sl)
					cwd_sl <= lwd_sl;
			assign cwd[la*16 +: 16] = cwd_sl;
		end
		for (la = 0; la < LINE_BYTES / 16; la = la + 1) begin : g_cbe_sl
			wire [15:0] lbe_sl;
			for (gh = 0; gh < 4; gh = gh + 1) begin : g_cbe_w
				localparam W_IDX = la * 4 + gh;
				(* dont_touch = "true" *) wire [NPHYS-1:0] be_hit;
				for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_be_l
					assign be_hit[gl] = pend_be[gl] && lhit_be[gl] && (rwo_wr_be_bus[gl*WW +: WW] == W_IDX[WW-1:0]);
				end
				(* dont_touch = "true" *) wire w_any_hit = |be_hit;
				assign lbe_sl[gh*4 +: 4] = {4{w_any_hit}};
			end
			(* shreg_extract = "no" *) reg [15:0] cbe_sl;
			(* dont_touch = "true" *) wire cbe_we_sl = (st == LINE_DAT);
			(* dont_touch = "true" *) wire rwr_sl = rwr;
			always @(posedge clk)
				if (cbe_we_sl)
					cbe_sl <= lbe_sl;
			assign cbe[la*16 +: 16] = cbe_sl;
			assign dc_req_be[la*16 +: 16] = rwr_sl ? cbe_sl : 16'd0;
		end
	endgenerate

	(* dont_touch = "true" *) wire lsu_idle_ce_a = !rst_p && (st == IDLE) && take;
	(* dont_touch = "true" *) wire lsu_idle_ce_b = !rst_p && (st == IDLE) && take;
	(* dont_touch = "true" *) wire line_ce_0 = !rst_p && (st == LINE) && (lead != NPHYS[LW:0]);
	(* dont_touch = "true" *) wire line_ce_1 = !rst_p && (st == LINE) && (lead != NPHYS[LW:0]);
	(* dont_touch = "true" *) wire line_ce_2 = !rst_p && (st == LINE) && (lead != NPHYS[LW:0]);
	(* dont_touch = "true" *) wire line_ce_3 = !rst_p && (st == LINE) && (lead != NPHYS[LW:0]);
	wire line_hit_ce = !rst_p && (st == LINE_HIT);
	wire line_hit_ce_0, line_hit_ce_1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lhit0 (.O(line_hit_ce_0), .I0(line_hit_ce));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lhit1 (.O(line_hit_ce_1), .I0(line_hit_ce));
`else
	assign line_hit_ce_0 = line_hit_ce;
	assign line_hit_ce_1 = line_hit_ce;
`endif

	(* dont_touch = "true" *) reg [NPHYS-1:0] pend_nxt, pend_a_nxt, pend_b_nxt, pend_be_nxt;
	always @(*) begin
		pend_nxt    = pend;
		pend_a_nxt  = pend_a;
		pend_b_nxt  = pend_b;
		pend_be_nxt = pend_be;
		if (rst_p) begin
			pend_nxt    = {NPHYS{1'b0}};
			pend_a_nxt  = {NPHYS{1'b0}};
			pend_b_nxt  = {NPHYS{1'b0}};
			pend_be_nxt = {NPHYS{1'b0}};
		end else if (st == IDLE && take) begin
			pend_nxt    = amask;
			pend_a_nxt  = amask;
			pend_b_nxt  = amask;
			pend_be_nxt = amask;
		end else if (st == WAIT && dc_rsp_valid) begin
			pend_nxt    = pend & ~cur;
			pend_a_nxt  = pend_a & ~cur;
			pend_b_nxt  = pend_b & ~cur;
			pend_be_nxt = pend_be & ~cur;
		end else if (st == AWAIT && at_rsp_valid) begin
			pend_nxt[ali]    = 1'b0;
			pend_a_nxt[ali]  = 1'b0;
			pend_b_nxt[ali]  = 1'b0;
			pend_be_nxt[ali] = 1'b0;
		end
	end

	always @(posedge clk) begin
		pend    <= pend_nxt;
		pend_a  <= pend_a_nxt;
		pend_b  <= pend_b_nxt;
		pend_be <= pend_be_nxt;
		if (lsu_idle_ce_a) begin
			rwr <= op == ATG_LSU_SW;
			ratom <= op == ATG_LSU_ATOM;
			rst_w <= op == ATG_LSU_LW || (op == ATG_LSU_ATOM && x_uop[ATG_UOP_WRD]);
			rsub <= x_uop[ATG_UOP_SUB +: 4];
			lanes <= amask;
		end
		if (lsu_idle_ce_b) begin
			rrd <= x_uop[ATG_UOP_RD +: 7];
			rwarp <= x_warp;
			rgrp <= x_grp;
			rlast <= x_last;
			rsbe <= x_sbe;
		end
		if (line_ce_0) cline_lo     <= lline[LA_LO-1:0];
		if (line_ce_1) cline_hi     <= lline[LA_W-1:LA_LO];
		if (line_ce_2) dc_line_lo_r <= lline[LA_LO-1:0];
		if (line_ce_3) dc_line_hi_r <= lline[LA_W-1:LA_LO];
		if (line_hit_ce_0) begin
			lhit   <= line_eq;
			lhit_a <= line_eq;
		end
		if (line_hit_ce_1) begin
			lhit_b  <= line_eq;
			lhit_be <= line_eq;
		end

		if (rst_p) begin
			st <= IDLE;
			inv_q <= 1'b0;
			ali <= {LW{1'b0}};
		end else begin
			inv_q <= mine && st == IDLE && op == ATG_LSU_FENCE && imm[2];
			case (st)
			IDLE: if (take) begin
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
				else
					st <= LINE_HIT;
			end
			LINE_HIT: begin
				st <= LINE_DAT;
			end
			LINE_DAT: begin
				cur <= inl;
				st <= WAIT;
			end
			WAIT: if (dc_rsp_valid) begin
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
`ifdef SYNTH_KINTEX7
	genvar g_dcl;
	generate
		for (g_dcl = 0; g_dcl < ADDR_W-LINE_SHIFT; g_dcl = g_dcl + 1) begin : g_buf_dcline
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_dcl (.I0(dc_line_r[g_dcl]), .O(dc_req_line[g_dcl]));
		end
	endgenerate
`else
	assign dc_req_line = dc_line_r;
`endif
	assign dc_req_wdata = cwd;
	assign dc_req_tag = 8'd0;
	assign dc_inv = inv_q;

	wire [LW-1:0] an_ad_b0, an_ad_b1, an_ad_b2, an_ad_b3;
	wire [LW-1:0] an_a_b0, an_a_b1, an_a_b2, an_a_b3;
	wire [LW-1:0] an_b_b0, an_b_b1, an_b_b2, an_b_b3;
	genvar gan;
	generate
		for (gan = 0; gan < LW; gan = gan + 1) begin : g_an_buf
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ad0 (.I0(anext[gan]), .O(an_ad_b0[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ad1 (.I0(anext[gan]), .O(an_ad_b1[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ad2 (.I0(anext[gan]), .O(an_ad_b2[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_ad3 (.I0(anext[gan]), .O(an_ad_b3[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_a0  (.I0(anext[gan]), .O(an_a_b0[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_a1  (.I0(anext[gan]), .O(an_a_b1[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_a2  (.I0(anext[gan]), .O(an_a_b2[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_a3  (.I0(anext[gan]), .O(an_a_b3[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_b0  (.I0(anext[gan]), .O(an_b_b0[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_b1  (.I0(anext[gan]), .O(an_b_b1[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_b2  (.I0(anext[gan]), .O(an_b_b2[gan]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_b3  (.I0(anext[gan]), .O(an_b_b3[gan]));
`else
			assign an_ad_b0[gan] = anext[gan];
			assign an_ad_b1[gan] = anext[gan];
			assign an_ad_b2[gan] = anext[gan];
			assign an_ad_b3[gan] = anext[gan];
			assign an_a_b0[gan]  = anext[gan];
			assign an_a_b1[gan]  = anext[gan];
			assign an_a_b2[gan]  = anext[gan];
			assign an_a_b3[gan]  = anext[gan];
			assign an_b_b0[gan]  = anext[gan];
			assign an_b_b1[gan]  = anext[gan];
			assign an_b_b2[gan]  = anext[gan];
			assign an_b_b3[gan]  = anext[gan];
`endif
		end
	endgenerate
	reg [7:0] at_ad_0, at_ad_1;
	reg [6:0] at_ad_2, at_ad_3;
	reg [7:0] at_a_0, at_a_1, at_a_2, at_a_3;
	reg [7:0] at_b_0, at_b_1, at_b_2, at_b_3;
	integer ai;
	always @(*) begin
		at_ad_0 = radr[2 +: 8];
		at_ad_1 = radr[10 +: 8];
		at_ad_2 = radr[18 +: 7];
		at_ad_3 = radr[25 +: 7];
		at_a_0  = rdat[0 +: 8];
		at_a_1  = rdat[8 +: 8];
		at_a_2  = rdat[16 +: 8];
		at_a_3  = rdat[24 +: 8];
		at_b_0  = rcmp[0 +: 8];
		at_b_1  = rcmp[8 +: 8];
		at_b_2  = rcmp[16 +: 8];
		at_b_3  = rcmp[24 +: 8];
		for (ai = 1; ai < NPHYS; ai = ai + 1) begin
			if (an_ad_b0 == ai[LW-1:0]) at_ad_0 = radr[ai*32 + 2 +: 8];
			if (an_ad_b1 == ai[LW-1:0]) at_ad_1 = radr[ai*32 + 10 +: 8];
			if (an_ad_b2 == ai[LW-1:0]) at_ad_2 = radr[ai*32 + 18 +: 7];
			if (an_ad_b3 == ai[LW-1:0]) at_ad_3 = radr[ai*32 + 25 +: 7];
			if (an_a_b0  == ai[LW-1:0]) at_a_0  = rdat[ai*32 + 0 +: 8];
			if (an_a_b1  == ai[LW-1:0]) at_a_1  = rdat[ai*32 + 8 +: 8];
			if (an_a_b2  == ai[LW-1:0]) at_a_2  = rdat[ai*32 + 16 +: 8];
			if (an_a_b3  == ai[LW-1:0]) at_a_3  = rdat[ai*32 + 24 +: 8];
			if (an_b_b0  == ai[LW-1:0]) at_b_0  = rcmp[ai*32 + 0 +: 8];
			if (an_b_b1  == ai[LW-1:0]) at_b_1  = rcmp[ai*32 + 8 +: 8];
			if (an_b_b2  == ai[LW-1:0]) at_b_2  = rcmp[ai*32 + 16 +: 8];
			if (an_b_b3  == ai[LW-1:0]) at_b_3  = rcmp[ai*32 + 24 +: 8];
		end
	end
	assign at_valid = st == AREQ && anext != NPHYS[LW:0];
	assign at_op = rsub;
	assign at_addr = {at_ad_3, at_ad_2, at_ad_1, at_ad_0};
	assign at_a = {at_a_3, at_a_2, at_a_1, at_a_0};
	assign at_b = {at_b_3, at_b_2, at_b_1, at_b_0};

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
