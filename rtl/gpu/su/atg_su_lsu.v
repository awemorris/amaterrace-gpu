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
	input wire [NWARPS*2-1:0] warp_stage,
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
	output wire [1:0] at_stage,
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
	localparam [3:0] IDLE = 4'd0, LINE = 4'd1, WAIT = 4'd2, AREQ = 4'd3, AWAIT = 4'd4,
		BEAT = 4'd5, LINE_HIT = 4'd6, LINE_DAT = 4'd7, PREP = 4'd8;

	wire rst_p = !rst_n;
	wire take_lsu_raw = x_valid && (unit == ATG_UNIT_LSU) && (st == IDLE) && (op != ATG_LSU_FENCE);
	wire take_lsu_h0, take_lsu_h1;
	wire prep_lsu_raw = (st == PREP);
	wire prep_lsu_h0, prep_lsu_h1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_tk_lh0 (.I0(take_lsu_raw), .O(take_lsu_h0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_tk_lh1 (.I0(take_lsu_raw), .O(take_lsu_h1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pr_lh0 (.I0(prep_lsu_raw), .O(prep_lsu_h0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pr_lh1 (.I0(prep_lsu_raw), .O(prep_lsu_h1));
`else
	assign take_lsu_h0 = take_lsu_raw;
	assign take_lsu_h1 = take_lsu_raw;
	assign prep_lsu_h0 = prep_lsu_raw;
	assign prep_lsu_h1 = prep_lsu_raw;
`endif
	(* max_fanout = 12 *) reg [3:0] st;
	(* keep = "true", dont_touch = "true" *) reg [NPHYS-1:0] idle_r, prep_r;
	reg at_valid_r;
	reg [29:0] at_addr_r;
	reg [31:0] at_a_r, at_b_r;
	wire [29:0] at_ad_w;
	wire [31:0] at_a_w, at_b_w;
	(* max_fanout = 12 *) reg [31:0] rimm;
	wire [DW-1:0] radr, rdat, rcmp, res;
	(* dont_touch = "true" *) reg [NPHYS-1:0] pend, pend_a, pend_b, pend_be;
	(* keep = "true" *) reg [NPHYS-1:0] pend_clr, pend_at_ad, pend_at_a, pend_at_b;
	(* keep = "true", dont_touch = "true" *) reg [NPHYS-1:0] pend_ll0, pend_ll1, pend_ll2, pend_ll3;
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
	wire [NPHYS-1:0] pend_rev, pend_clr_rev;
	genvar gpr;
	generate
		for (gpr = 0; gpr < NPHYS; gpr = gpr + 1) begin : g_pend_rev
			assign pend_rev[gpr]     = pend[NPHYS - 1 - gpr];
			assign pend_clr_rev[gpr] = pend_clr[NPHYS - 1 - gpr];
		end
	endgenerate
	wire [LW-1:0] pend_rev_n, pend_clr_rev_n;
	wire pend_nz, pend_clr_nz;
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_lead     (.a(pend_rev),     .n(pend_rev_n),     .nz(pend_nz));
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_lead_clr (.a(pend_clr_rev), .n(pend_clr_rev_n), .nz(pend_clr_nz));
	(* max_fanout = 12 *) wire [LW:0] lead     = pend_nz     ? {1'b0, ~pend_rev_n}     : NPHYS[LW:0];
	(* max_fanout = 12 *) wire [LW:0] lead_clr = pend_clr_nz ? {1'b0, ~pend_clr_rev_n} : NPHYS[LW:0];
	wire [NPHYS-1:0] inl = pend & lhit;
	wire [NPHYS-1:0] line_eq;
	wire [NPHYS-1:0] pend_ll0_rev, pend_ll1_rev, pend_ll2_rev, pend_ll3_rev;
	genvar gpl;
	generate
		for (gpl = 0; gpl < NPHYS; gpl = gpl + 1) begin : g_pend_ll_rev
			assign pend_ll0_rev[gpl] = pend_ll0[NPHYS - 1 - gpl];
			assign pend_ll1_rev[gpl] = pend_ll1[NPHYS - 1 - gpl];
			assign pend_ll2_rev[gpl] = pend_ll2[NPHYS - 1 - gpl];
			assign pend_ll3_rev[gpl] = pend_ll3[NPHYS - 1 - gpl];
		end
	endgenerate
	wire [LW-1:0] pend_ll0_n, pend_ll1_n, pend_ll2_n, pend_ll3_n;
	wire pend_ll0_nz, pend_ll1_nz, pend_ll2_nz, pend_ll3_nz;
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_ll0 (.a(pend_ll0_rev), .n(pend_ll0_n), .nz(pend_ll0_nz));
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_ll1 (.a(pend_ll1_rev), .n(pend_ll1_n), .nz(pend_ll1_nz));
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_ll2 (.a(pend_ll2_rev), .n(pend_ll2_n), .nz(pend_ll2_nz));
	am_msb #(.W(NPHYS), .SW(LW)) u_lsu_ll3 (.a(pend_ll3_rev), .n(pend_ll3_n), .nz(pend_ll3_nz));
	wire [LW-1:0] lead_ll0 = ~pend_ll0_n;
	wire [LW-1:0] lead_ll1 = ~pend_ll1_n;
	wire [LW-1:0] lead_ll2 = ~pend_ll2_n;
	wire [LW-1:0] lead_ll3 = ~pend_ll3_n;
	wire [NPHYS*64-1:0] radr64;
	genvar ge;
	generate
		for (ge = 0; ge < NPHYS; ge = ge + 1) begin : g_radr64
			assign radr64[ge*64 +: 64] = {32'd0, radr[ge*32 +: 32]};
		end
	endgenerate
	localparam integer LL_Q0 = LA_W / 4;
	localparam integer LL_Q1 = LA_W / 4;
	localparam integer LL_Q2 = LA_W / 4;
	localparam integer LL_Q3 = LA_W - (LL_Q0 + LL_Q1 + LL_Q2);
	wire [LA_W-1:0] lline = {
		radr64[lead_ll3*64 + LINE_SHIFT + LL_Q0 + LL_Q1 + LL_Q2 +: LL_Q3],
		radr64[lead_ll2*64 + LINE_SHIFT + LL_Q0 + LL_Q1         +: LL_Q2],
		radr64[lead_ll1*64 + LINE_SHIFT + LL_Q0                 +: LL_Q1],
		radr64[lead_ll0*64 + LINE_SHIFT                         +: LL_Q0]
	};
	wire unused_ll_nz = &{1'b0, pend_ll0_nz, pend_ll1_nz, pend_ll2_nz, pend_ll3_nz};

	/* The next atomic lane. */
	wire [LW:0] anext = lead;

	/* The lanes' addresses: registered radr + rimm in PREP (avoids opd+adder in IDLE). */
	localparam N_LEQ = (LA_W + 2) / 3;
	wire [DW-1:0] x_adr;
	wire [NPHYS*WW-1:0] rwo_wr_a_bus, rwo_wr_b_bus, rwo_wr_be_bus;

	wire at_err_l [0:NPHYS-1];
	genvar gop_l;
	generate
	for (gop_l = 0; gop_l < NPHYS; gop_l = gop_l + 1) begin : g_buf_opl
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ae (.I0(at_error), .O(at_err_l[gop_l]));
`else
		assign at_err_l[gop_l] = at_error;
`endif
	end
	endgenerate

	genvar la, gh, gleq, gl;
	generate
		for (la = 0; la < NPHYS; la = la + 1) begin : g_adr
			wire co_unused;
			am_add #(.W(32)) u_adr (.a(radr[la*32 +: 32]), .b(rimm),
				.ci(1'b0), .s(x_adr[la*32 +: 32]), .co(co_unused));
			(* keep = "true" *) wire [N_LEQ-1:0] leq_g;
			for (gleq = 0; gleq < N_LEQ; gleq = gleq + 1) begin : g_leq
				localparam LB_B = gleq * 3;
				localparam LW_C = (LB_B + 3 <= LA_W) ? 3 : (LA_W - LB_B);
				assign leq_g[gleq] = (radr64[la*64 + LINE_SHIFT + LB_B +: LW_C] == cline[LB_B +: LW_C]);
			end
			(* keep = "true" *) wire leq_lo = &leq_g[N_LEQ/2-1:0];
			(* keep = "true" *) wire leq_hi = &leq_g[N_LEQ-1:N_LEQ/2];
			assign line_eq[la] = leq_lo && leq_hi;

			wire take_lsu_h = (la < NPHYS/2) ? take_lsu_h0 : take_lsu_h1;
			wire prep_lsu_h = (la < NPHYS/2) ? prep_lsu_h0 : prep_lsu_h1;
			wire prep_wo, prep_adr_h, take_byte_l;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_tk_b  (.I0(take_lsu_h), .O(take_byte_l));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pr_wo (.I0(prep_lsu_h), .O(prep_wo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_pr_ad (.I0(prep_lsu_h), .O(prep_adr_h));
`else
			assign take_byte_l = idle_r[la];
			assign prep_wo     = prep_r[la];
			assign prep_adr_h  = prep_r[la];
`endif
			(* dont_touch = "true" *) reg [WW-1:0] rwo_rd_0, rwo_rd_1, rwo_rd_2, rwo_rd_3, rwo_wr_a, rwo_wr_b, rwo_wr_be;
			always @(posedge clk) begin
				if (prep_wo) begin
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

			wire at_err_la0, at_err_la1;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ae0 (.I0(at_err_l[la]), .O(at_err_la0));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_ae1 (.I0(at_err_l[la]), .O(at_err_la1));
`else
			assign at_err_la0 = at_err_l[la];
			assign at_err_la1 = at_err_l[la];
`endif

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
				wire dc_we_h = (st == WAIT) && dc_rsp_valid && cur[la];
				wire dc_err_h = dc_rsp_error;
				wire at_we_h = (st == AWAIT) && at_rsp_valid && (ali == la[LW-1:0]);
				wire at_err_h = (gh < 2) ? at_err_la0 : at_err_la1;
				wire take_rd_h, take_cr_h;
`ifdef SYNTH_KINTEX7
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_trd (.I0(take_byte_l), .O(take_rd_h));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_b_tcr (.I0(take_byte_l), .O(take_cr_h));
`else
				assign take_rd_h = take_byte_l;
				assign take_cr_h = take_byte_l;
`endif
				always @(posedge clk) begin
					if (take_rd_h)
						radr_h <= x_a[la*32 + gh*8 +: 8];
					else if (prep_adr_h)
						radr_h <= x_adr[la*32 + gh*8 +: 8];
					if (take_rd_h)
						rdat_h <= x_b[la*32 + gh*8 +: 8];
					if (take_cr_h)
						rcmp_h <= x_c[la*32 + gh*8 +: 8];
					if (take_cr_h) begin
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
			localparam integer NG_CWD = (NPHYS >= 4) ? (NPHYS / 4) : 1;
			wire [NG_CWD-1:0] grp_any_0, grp_any_1;
			wire [NG_CWD-1:0] grp_win_0, grp_win_1;
			wire [NG_CWD*8-1:0] grp_dat_0, grp_dat_1;
			genvar ggc;
			for (ggc = 0; ggc < NG_CWD; ggc = ggc + 1) begin : g_cwd_grp
				if (NPHYS >= 4) begin : g_4
					localparam integer B = ggc * 4;
					assign grp_any_0[ggc] = |sl_hit_0[B +: 4];
					assign grp_any_1[ggc] = |sl_hit_1[B +: 4];
					assign grp_dat_0[ggc*8 +: 8] =
						sl_hit_0[B+3] ? rdat[(B+3)*32 + H_IDX*16 +: 8] :
						sl_hit_0[B+2] ? rdat[(B+2)*32 + H_IDX*16 +: 8] :
						sl_hit_0[B+1] ? rdat[(B+1)*32 + H_IDX*16 +: 8] :
						                rdat[(B+0)*32 + H_IDX*16 +: 8];
					assign grp_dat_1[ggc*8 +: 8] =
						sl_hit_1[B+3] ? rdat[(B+3)*32 + H_IDX*16 + 8 +: 8] :
						sl_hit_1[B+2] ? rdat[(B+2)*32 + H_IDX*16 + 8 +: 8] :
						sl_hit_1[B+1] ? rdat[(B+1)*32 + H_IDX*16 + 8 +: 8] :
						                rdat[(B+0)*32 + H_IDX*16 + 8 +: 8];
				end else begin : g_lt4
					reg [7:0] d0, d1;
					integer il;
					always @(*) begin
						d0 = 8'd0;
						d1 = 8'd0;
						for (il = 0; il < NPHYS; il = il + 1) begin
							if (sl_hit_0[il]) d0 = rdat[il*32 + H_IDX*16 +: 8];
							if (sl_hit_1[il]) d1 = rdat[il*32 + H_IDX*16 + 8 +: 8];
						end
					end
					assign grp_any_0[0] = |sl_hit_0;
					assign grp_any_1[0] = |sl_hit_1;
					assign grp_dat_0[7:0] = d0;
					assign grp_dat_1[7:0] = d1;
				end
				if (ggc == NG_CWD - 1) begin : g_top
					assign grp_win_0[ggc] = grp_any_0[ggc];
					assign grp_win_1[ggc] = grp_any_1[ggc];
				end else begin : g_lo
					assign grp_win_0[ggc] = grp_any_0[ggc] && !(|grp_any_0[NG_CWD-1:ggc+1]);
					assign grp_win_1[ggc] = grp_any_1[ggc] && !(|grp_any_1[NG_CWD-1:ggc+1]);
				end
			end
			reg [7:0] lwd_sl_0, lwd_sl_1;
			integer sl_l;
			always @(*) begin
				lwd_sl_0 = 8'd0;
				lwd_sl_1 = 8'd0;
				for (sl_l = 0; sl_l < NG_CWD; sl_l = sl_l + 1) begin
					if (grp_win_0[sl_l])
						lwd_sl_0 = lwd_sl_0 | grp_dat_0[sl_l*8 +: 8];
					if (grp_win_1[sl_l])
						lwd_sl_1 = lwd_sl_1 | grp_dat_1[sl_l*8 +: 8];
				end
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

	wire lsu_idle_ce_a = !rst_p && (st == IDLE) && take;
	wire lsu_idle_ce_b = !rst_p && (st == IDLE) && take;
	wire lsu_idle_ce_imm0 = !rst_p && (st == IDLE) && take;
	wire lsu_idle_ce_imm1 = !rst_p && (st == IDLE) && take;
	wire line_ce_raw = !rst_p && (st == LINE) && (lead != NPHYS[LW:0]);
	wire line_ce_0, line_ce_1, line_ce_2, line_ce_3;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lce0 (.O(line_ce_0), .I0(line_ce_raw));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lce1 (.O(line_ce_1), .I0(line_ce_raw));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lce2 (.O(line_ce_2), .I0(line_ce_raw));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lce3 (.O(line_ce_3), .I0(line_ce_raw));
`else
	assign line_ce_0 = line_ce_raw;
	assign line_ce_1 = line_ce_raw;
	assign line_ce_2 = line_ce_raw;
	assign line_ce_3 = line_ce_raw;
`endif
	wire line_hit_ce = !rst_p && (st == LINE_HIT);
	wire line_hit_ce_0, line_hit_ce_1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lhit0 (.O(line_hit_ce_0), .I0(line_hit_ce));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_buf_lhit1 (.O(line_hit_ce_1), .I0(line_hit_ce));
`else
	assign line_hit_ce_0 = line_hit_ce;
	assign line_hit_ce_1 = line_hit_ce;
`endif

	always @(posedge clk or posedge rst_p) begin
		if (rst_p) begin
			pend    <= {NPHYS{1'b0}};
			pend_a  <= {NPHYS{1'b0}};
			pend_b  <= {NPHYS{1'b0}};
			pend_be <= {NPHYS{1'b0}};
			pend_clr   <= {NPHYS{1'b0}};
			pend_at_ad <= {NPHYS{1'b0}};
			pend_at_a  <= {NPHYS{1'b0}};
			pend_at_b  <= {NPHYS{1'b0}};
			pend_ll0 <= {NPHYS{1'b0}};
			pend_ll1 <= {NPHYS{1'b0}};
			pend_ll2 <= {NPHYS{1'b0}};
			pend_ll3 <= {NPHYS{1'b0}};
			st <= IDLE;
			idle_r <= {NPHYS{1'b1}};
			prep_r <= {NPHYS{1'b0}};
			at_valid_r <= 1'b0;
			at_addr_r <= 30'd0;
			at_a_r <= 32'd0;
			at_b_r <= 32'd0;
			rimm <= 32'd0;
			inv_q <= 1'b0;
			ali <= {LW{1'b0}};
			rwr <= 1'b0;
			ratom <= 1'b0;
			rst_w <= 1'b0;
			rsub <= 4'd0;
			lanes <= {NPHYS{1'b0}};
			rrd <= 7'd0;
			rwarp <= {WARP_W{1'b0}};
			rgrp <= {GRP_W{1'b0}};
			rlast <= 1'b0;
			rsbe <= {(SBE_W+1){1'b0}};
			cline_lo <= {LA_LO{1'b0}};
			cline_hi <= {LA_HI{1'b0}};
			dc_line_lo_r <= {LA_LO{1'b0}};
			dc_line_hi_r <= {LA_HI{1'b0}};
			lhit <= {NPHYS{1'b0}};
			lhit_a <= {NPHYS{1'b0}};
			lhit_b <= {NPHYS{1'b0}};
			lhit_be <= {NPHYS{1'b0}};
			cur <= {NPHYS{1'b0}};
		end else begin
			if (st == IDLE && take) begin
				pend    <= amask;
				pend_a  <= amask;
				pend_b  <= amask;
				pend_be <= amask;
				pend_clr   <= amask;
				pend_at_ad <= amask;
				pend_at_a  <= amask;
				pend_at_b  <= amask;
				pend_ll0 <= amask;
				pend_ll1 <= amask;
				pend_ll2 <= amask;
				pend_ll3 <= amask;
			end else if (st == WAIT && dc_rsp_valid) begin
				pend    <= pend & ~cur;
				pend_a  <= pend_a & ~cur;
				pend_b  <= pend_b & ~cur;
				pend_be <= pend_be & ~cur;
				pend_clr   <= pend_clr & ~cur;
				pend_at_ad <= pend_at_ad & ~cur;
				pend_at_a  <= pend_at_a & ~cur;
				pend_at_b  <= pend_at_b & ~cur;
				pend_ll0 <= pend_ll0 & ~cur;
				pend_ll1 <= pend_ll1 & ~cur;
				pend_ll2 <= pend_ll2 & ~cur;
				pend_ll3 <= pend_ll3 & ~cur;
			end else if (st == AREQ && at_valid_r && at_ready) begin
				pend[lead[LW-1:0]]       <= 1'b0;
				pend_a[lead[LW-1:0]]     <= 1'b0;
				pend_b[lead[LW-1:0]]     <= 1'b0;
				pend_be[lead[LW-1:0]]    <= 1'b0;
				pend_clr[lead_clr[LW-1:0]]   <= 1'b0;
				pend_at_ad[lead_clr[LW-1:0]] <= 1'b0;
				pend_at_a[lead_clr[LW-1:0]]  <= 1'b0;
				pend_at_b[lead_clr[LW-1:0]]  <= 1'b0;
				pend_ll0[lead_clr[LW-1:0]] <= 1'b0;
				pend_ll1[lead_clr[LW-1:0]] <= 1'b0;
				pend_ll2[lead_clr[LW-1:0]] <= 1'b0;
				pend_ll3[lead_clr[LW-1:0]] <= 1'b0;
			end
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
			if (lsu_idle_ce_imm0)
				rimm[15:0] <= (op == ATG_LSU_ATOM) ? 16'd0 : imm[15:0];
			if (lsu_idle_ce_imm1)
				rimm[31:16] <= (op == ATG_LSU_ATOM) ? 16'd0 : imm[31:16];
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

			inv_q <= (mine && st == IDLE && op == ATG_LSU_FENCE && imm[2]) ||
			         (take && (amask != {NPHYS{1'b0}}) && (op == ATG_LSU_ATOM));
			case (st)
			IDLE: if (take) begin
				idle_r <= {NPHYS{1'b0}};
				prep_r <= {NPHYS{1'b1}};
				st <= PREP;
			end
			PREP: begin
				prep_r <= {NPHYS{1'b0}};
				if (lanes == {NPHYS{1'b0}})
					st <= BEAT;
				else if (ratom) begin
					st         <= AREQ;
					at_valid_r <= pend_nz;
					at_addr_r  <= at_ad_w;
					at_a_r     <= at_a_w;
					at_b_r     <= at_b_w;
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
			AREQ: if (!at_valid_r) begin
				st <= BEAT;
			end else begin
				ali <= lead[LW-1:0];
				if (at_ready) begin
					st         <= AWAIT;
					at_valid_r <= 1'b0;
				end
			end
			AWAIT: begin
				at_addr_r <= at_ad_w;
				at_a_r    <= at_a_w;
				at_b_r    <= at_b_w;
				if (at_rsp_valid) begin
					st         <= AREQ;
					at_valid_r <= pend_nz;
				end
			end
			default: if (l_ready) begin
				st     <= IDLE;
				idle_r <= {NPHYS{1'b1}};
			end
			endcase
		end
	end

	/* The D$ request is valid in WAIT until taken (cline holds). */
	reg req_taken;
	always @(posedge clk or posedge rst_p)
		if (rst_p)
			req_taken <= 1'b0;
		else if (st != WAIT)
			req_taken <= 1'b0;
		else if (dc_req_valid && dc_req_ready)
			req_taken <= 1'b1;
	wire [1:0] cur_stage = warp_stage[rwarp * 2 +: 2];
	assign dc_req_valid = st == WAIT && !req_taken;
	assign dc_req_write = rwr;
	assign dc_req_line = dc_line_r;
	assign dc_req_wdata = cwd;
	assign dc_req_tag = {6'd0, cur_stage};
	assign at_stage = cur_stage;
	assign dc_inv = inv_q;

	/* 4-lane group tree for atomic request address and operands (FO <= 32, depth ~11 cmos3) */
	localparam integer NG_AT = (NPHYS >= 4) ? (NPHYS / 4) : 1;
	wire [NG_AT-1:0] at_any_ad, at_any_a, at_any_b;
	wire [NG_AT-1:0] at_win_ad, at_win_a, at_win_b;
	wire [NG_AT*30-1:0] at_gdat_ad;
	wire [NG_AT*32-1:0] at_gdat_a, at_gdat_b;
	genvar gat;
	generate
		for (gat = 0; gat < NG_AT; gat = gat + 1) begin : g_at_grp
			localparam integer B = gat * 4;
			wire [3:0] pad = pend_at_ad[B +: 4];
			wire [3:0] pa  = pend_at_a[B +: 4];
			wire [3:0] pb  = pend_at_b[B +: 4];
			assign at_any_ad[gat] = |pad;
			assign at_any_a[gat]  = |pa;
			assign at_any_b[gat]  = |pb;
			assign at_gdat_ad[gat*30 +: 30] =
				pad[0] ? radr[(B+0)*32 + 2 +: 30] :
				pad[1] ? radr[(B+1)*32 + 2 +: 30] :
				pad[2] ? radr[(B+2)*32 + 2 +: 30] :
				pad[3] ? radr[(B+3)*32 + 2 +: 30] : 30'd0;
			assign at_gdat_a[gat*32 +: 32] =
				pa[0] ? rdat[(B+0)*32 +: 32] :
				pa[1] ? rdat[(B+1)*32 +: 32] :
				pa[2] ? rdat[(B+2)*32 +: 32] :
				pa[3] ? rdat[(B+3)*32 +: 32] : 32'd0;
			assign at_gdat_b[gat*32 +: 32] =
				pb[0] ? rcmp[(B+0)*32 +: 32] :
				pb[1] ? rcmp[(B+1)*32 +: 32] :
				pb[2] ? rcmp[(B+2)*32 +: 32] :
				pb[3] ? rcmp[(B+3)*32 +: 32] : 32'd0;
			if (gat == 0) begin : g_at_first
				assign at_win_ad[gat] = at_any_ad[0];
				assign at_win_a[gat]  = at_any_a[0];
				assign at_win_b[gat]  = at_any_b[0];
			end else begin : g_at_rest
				assign at_win_ad[gat] = at_any_ad[gat] && !(|at_any_ad[gat-1:0]);
				assign at_win_a[gat]  = at_any_a[gat]  && !(|at_any_a[gat-1:0]);
				assign at_win_b[gat]  = at_any_b[gat]  && !(|at_any_b[gat-1:0]);
			end
		end
	endgenerate
	reg [29:0] at_ad_comb;
	reg [31:0] at_a_comb, at_b_comb;
	integer iat;
	always @(*) begin
		at_ad_comb = 30'd0;
		at_a_comb  = 32'd0;
		at_b_comb  = 32'd0;
		for (iat = 0; iat < NG_AT; iat = iat + 1) begin
			if (at_win_ad[iat]) at_ad_comb = at_ad_comb | at_gdat_ad[iat*30 +: 30];
			if (at_win_a[iat])  at_a_comb  = at_a_comb  | at_gdat_a[iat*32 +: 32];
			if (at_win_b[iat])  at_b_comb  = at_b_comb  | at_gdat_b[iat*32 +: 32];
		end
	end
	assign at_ad_w = at_ad_comb;
	assign at_a_w  = at_a_comb;
	assign at_b_w  = at_b_comb;
	assign at_valid = at_valid_r;
	assign at_op = rsub;
	assign at_addr = at_addr_r;
	assign at_a = at_a_r;
	assign at_b = at_b_r;

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
		unused_ll_nz, lead_clr[LW], (NWARPS != 0)};
endmodule

`default_nettype wire
