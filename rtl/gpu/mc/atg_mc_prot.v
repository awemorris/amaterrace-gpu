/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_prot: the grant of the MC's root and the session protection
 * check (spec/gpu/mc/atg_mc_prot.md, docs/ghci.md section 11.6).
 *
 * Inputs: the complete request of the tree's assembly buffer (A) and, with
 * HAS_DC, that of the display controller's own entry (D); both as header
 * and data flits (spec/common/am_amb_to_rt.md; with HAS_PROT the header
 * carries chk at bit 3 and tbl and the slot after the byte enables).  It
 * grants one request per cycle to the AXI master (g_*) or refuses one
 * (bad, one cycle; the root then sends its error response).  Nothing is
 * granted or refused while err_busy (a refusal's response waits).
 *
 * Without HAS_PROT: A and D are checked against the aperture and the VRAM
 * window only, as before.
 *
 * With HAS_PROT:
 *   - A write into [tbase, + the table's bytes) without tbl is refused
 *     (protection), whatever chk says; tbase = 0: no table.
 *   - A request with chk goes from A to the judge stage J (one cycle), where
 *     the granule g = address >> 12 is looked up in the PLB (PLB lines of
 *     the protection table, fully associative, round-robin) and in the
 *     grant CAM (atg_mc_grant) at the same time.  Allowed: own (the byte's
 *     slot is the request's, not a write to a read-only byte), public (a
 *     read of a byte with [7]), or a grant.  Refused: g outside [G0, G1),
 *     tbase = 0, or a PLB hit that allows nothing.  A miss moves to the
 *     park P, which reads the table's line from memory (a walk: client
 *     0xFF, its response comes back on w_*), fills the PLB and is judged
 *     again; a walk's AXI error refuses it (bad_mem).  While P waits, the
 *     requests of other clients pass; a client with a request in J or P has
 *     its later requests wait (order per client).
 *   - Judgements are not used in a cycle where the PLB or the CAM changes
 *     (a fill, inv_valid, gw_valid): they are made again a cycle later.
 *   - inv_valid invalidates the PLB lines that overlap the granules
 *     [inv_g, inv_g + inv_n) (inv_n = 0: all).  An overlapping invalidation
 *     while a walk is out makes that walk's line stale: it is not filled
 *     and is read again; inv_pending is 1 from then until a walk's line is
 *     filled or P leaves (the firmware waits for 0 before its next
 *     invalidation).
 *   - The requests of RMW_MASK's clients (the atomic unit) are judged as
 *     writes.
 *
 * Priorities: D, then the walk, then J or P, then A.  rst_n and flush
 * empty J, P, the PLB and the CAM.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_prot #(
	parameter HAS_PROT = 0,
	parameter HAS_DC = 0,	/* D: the root client's own entry */
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] RMW_MASK = {NCLIENT{1'b0}},
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter VRAM_AW = 32,
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}},
	parameter RW = 1,	/* route bits */
	parameter PLB = 4,	/* PLB lines */
	parameter PLB_W = 2,	/* clog2(PLB) */
	parameter NGRANT = 8,
	parameter GIDX_W = 3	/* clog2(NGRANT) */
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	/* A: the tree's request (held until a_take). */
	input wire a_valid,
	input wire [LINE_BYTES*8-1:0] a_head,
	input wire [LINE_BYTES*8-1:0] a_data,
	output wire a_take,

	/* D: the display controller's request (HAS_DC). */
	input wire d_valid,
	input wire [LINE_BYTES*8-1:0] d_head,
	input wire [LINE_BYTES*8-1:0] d_data,
	output wire d_take,

	input wire [ADDR_W-1:0] aperture_base,
	input wire [ADDR_W-1:0] aperture_limit,

	/* To am_axi_master. */
	output wire g_valid,
	input wire g_ready,
	output wire g_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] g_line,
	output wire [LINE_BYTES-1:0] g_be,
	output wire [LINE_BYTES*8-1:0] g_wdata,
	output wire [16+RW-1:0] g_user,

	/* Refusals and the requests that left the root. */
	input wire err_busy,
	output wire bad,
	output wire [20+RW+(VRAM_AW-LINE_SHIFT)+LINE_BYTES+7-1:0] bad_head,
	output wire [ADDR_W-LINE_SHIFT-1:0] bad_line,
	output wire bad_prot,
	output wire bad_mem,
	output wire done,	/* a request was granted to AXI or refused (not a walk) */
	output wire done_chk,	/* ... and it had chk */

	/* The walk's response (the AXI master's response with client 0xFF). */
	input wire w_valid,
	input wire w_error,
	input wire [LINE_BYTES*8-1:0] w_rdata,

	/* From the CP. */
	input wire [ADDR_W-1:0] tbase,
	input wire inv_valid,
	input wire [ADDR_W-13:0] inv_g,
	input wire [31:0] inv_n,
	output wire inv_pending,
	input wire gw_valid,
	input wire [GIDX_W-1:0] gw_idx,
	input wire [49:0] gw_data
);
	localparam P = HAS_PROT != 0;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam LAW = VRAM_AW - LINE_SHIFT;
	localparam HW = 20 + RW + LAW + LINE_BYTES;
	localparam HPW = HW + 7;	/* the header bits kept: up to tbl and the slot */
	localparam GW = ADDR_W - 12;	/* granule number bits */
	localparam GS = 12 - LINE_SHIFT;	/* line bits inside a granule */
	localparam TAGW = GW - LINE_SHIFT;	/* PLB tag: the table's line index */

	/* ------------------------------------------------ header fields */

	function [LA_W-1:0] line_of;
		input [LAW-1:0] off;	/* the header's line inside the window */
		begin
			line_of = {LA_W{1'b0}};
			line_of[LAW-1:0] = off;
			if (VRAM_AW < ADDR_W)
				line_of = line_of | (VRAM_BASE[ADDR_W-1:LINE_SHIFT] &
					~{{(ADDR_W-VRAM_AW){1'b0}}, {LAW{1'b1}}});
		end
	endfunction

	function rmw_of;
		input [7:0] client;
		integer k;
		begin
			rmw_of = 1'b0;
			for (k = 0; k < NCLIENT; k = k + 1)
				if (client == k[7:0])
					rmw_of = RMW_MASK[k];
		end
	endfunction

	/* -------------------------------------- the table and its range */

	wire [GW-1:0] g0 = aperture_base[ADDR_W-1:12];
	wire [ADDR_W:0] lim_up = {1'b0, aperture_limit} + 4095;
	wire [GW:0] g1 = lim_up[ADDR_W:12];
	/* The table's bytes: one per granule of [G0, G1), rounded up to 4 KiB. */
	wire [ADDR_W:0] tgran = {{(ADDR_W-GW){1'b0}}, g1 - {1'b0, g0}} + 4095;
	wire [ADDR_W:0] tbytes = {tgran[ADDR_W:12], 12'd0};
	wire tb_on = P && tbase != {ADDR_W{1'b0}};
	wire [ADDR_W:0] tend = {1'b0, tbase} + tbytes;

	/* A write into the table without tbl (with HAS_PROT and a table). */
	function tw_bad_of;
		input [LB-1:0] h;
		input [LA_W-1:0] line;
		reg [ADDR_W:0] a;
		begin
			a = {1'b0, line, {LINE_SHIFT{1'b0}}};
`ifdef MUT_PROT_TBL
			tw_bad_of = 1'b0;
`else
			tw_bad_of = tb_on && h[1] && !h[HW] && a >= {1'b0, tbase} && a < tend;
`endif
		end
	endfunction

	/* --------------------------------------------------- A and D */

	wire [LA_W-1:0] a_line = line_of(a_head[20+RW +: LAW]);
	wire [LA_W-1:0] d_line = line_of(d_head[20+RW +: LAW]);
	wire a_ap, d_ap;

	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) aper_a (
		.line(a_line), .base(aperture_base), .limit(aperture_limit), .ok(a_ap)
	);
	atg_mc_aper #(.ADDR_W(ADDR_W), .LINE_SHIFT(LINE_SHIFT)) aper_d (
		.line(d_line), .base(aperture_base), .limit(aperture_limit), .ok(d_ap)
	);

	wire a_inside = a_ap && !a_head[2];
	wire a_tw = tw_bad_of(a_head, a_line);
`ifdef MUT_PROT_NOCHK
	wire a_chk = 1'b0;
`else
	wire a_chk = P && a_head[3];
`endif
	wire a_direct = !a_chk || !a_inside || a_tw;
	wire a_isbad = !a_inside || a_tw;
	wire d_on = HAS_DC != 0 && d_valid;
	wire d_inside = d_ap && !d_head[2];

	/* ------------------------------------------------ J and P */

	reg j_v;
	reg [HPW-1:0] j_head;
	reg [LB-1:0] j_data;
	reg [LA_W-1:0] j_line;
	reg p_v, p_walk, p_stale, p_err, inv_pend;
	reg [HPW-1:0] p_head;
	reg [LB-1:0] p_data;
	reg [LA_W-1:0] p_line;

	wire [7:0] a_client = a_head[19:12];
	wire [7:0] j_client = j_head[19:12];
	wire [7:0] p_client = p_head[19:12];

	/* The judge: P when it is not waiting for a walk, else J. */
	wire src_p = p_v && !p_walk;
	wire [HPW-1:0] s_head = src_p ? p_head : j_head;
	wire [LA_W-1:0] s_line = src_p ? p_line : j_line;
	wire s_write = s_head[1] || rmw_of(s_head[19:12]);
	wire [5:0] s_slot = s_head[HW+1 +: 6];
	wire [GW-1:0] s_g = s_line[LA_W-1:GS];
	wire s_rng = tb_on && s_g >= g0 && {1'b0, s_g} < g1;
	wire [GW-1:0] s_idx = s_g - g0;
	wire [TAGW-1:0] s_tag = s_idx[GW-1:LINE_SHIFT];
	wire [LINE_SHIFT-1:0] s_byte = s_idx[LINE_SHIFT-1:0];

	/* The PLB (the walk's line: p_tag, below). */
	wire pl_hit, p_inv;
	wire [LB-1:0] s_pline;
	wire [TAGW-1:0] p_tag;
	wire fill;

	atg_mc_plb #(
		.PLB(PLB), .PLB_W(PLB_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .GW(GW),
		.TAGW(TAGW)
	) plb (
		.clk(clk), .rst_n(rst_n), .flush(flush), .en(P), .g0(g0), .tag(s_tag), .hit(pl_hit),
		.data(s_pline), .fill(fill), .fill_tag(p_tag), .fill_data(w_rdata),
		.inv_valid(inv_valid), .inv_g(inv_g), .inv_n(inv_n), .w_tag(p_tag), .w_inv(p_inv)
	);

	wire [7:0] s_b = s_pline[{s_byte, 3'b000} +: 8];
`ifdef MUT_PROT_RO
	wire s_own = s_slot != 6'd0 && s_b[5:0] == s_slot;
`else
	wire s_own = s_slot != 6'd0 && s_b[5:0] == s_slot && !(s_write && s_b[6]);
`endif
	wire s_pub = s_b[7] && !s_write;
	wire s_cam;

	atg_mc_grant #(.NGRANT(NGRANT), .IDX_W(GIDX_W)) cam (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.w_valid(P && gw_valid), .w_idx(gw_idx), .w_data(gw_data),
		.slot(s_slot), .g(s_g), .write(s_write), .hit(s_cam)
	);

	wire s_ok = s_rng && (s_cam || pl_hit && (s_own || s_pub));
	wire s_refuse = !s_rng || pl_hit && !s_own && !s_pub && !s_cam;
	wire s_miss = !s_ok && !s_refuse;

`ifdef MUT_PROT_RECHECK
	wire chg = 1'b0;
`else
	wire chg = fill || inv_valid || gw_valid;
`endif
	wire j_blocked = p_v && p_client == j_client;
	wire x_valid = P && !chg && (src_p || j_v && !j_blocked);
	wire x_axi = x_valid && !(src_p && p_err) && s_ok;
	wire x_bad = x_valid && (src_p && p_err || s_refuse);
	wire x_walk = x_valid && src_p && !p_err && s_miss;
	wire j_to_p = x_valid && !src_p && s_miss && !p_v;

	wire a_blocked = j_v && j_client == a_client || p_v && p_client == a_client;
	wire a_axi = a_valid && a_direct && !a_isbad && !a_blocked;
	wire a_bad = a_valid && a_direct && a_isbad && !a_blocked;

	/* --------------------------------------------- the selection */

	wire [GW-1:0] p_idx = p_line[LA_W-1:GS] - g0;
	assign p_tag = p_idx[GW-1:LINE_SHIFT];
	wire [LA_W-1:0] w_line = tbase[ADDR_W-1:LINE_SHIFT] + {{(LA_W-TAGW){1'b0}}, p_tag};

	/* The AXI request: D, the walk, J or P, A. */
	wire sel_d = d_on && d_inside;
	wire sel_w = !sel_d && x_walk;
	wire sel_x = !sel_d && !sel_w && x_axi;
	wire sel_a = !sel_d && !sel_w && !sel_x && a_axi;
	assign g_valid = !err_busy && (sel_d || sel_w || sel_x || sel_a);
	wire g_fire = g_valid && g_ready;

	wire [LB-1:0] g_head = sel_d ? d_head : sel_x ? {{(LB-HPW){1'b0}}, s_head} : a_head;
	assign g_write = !sel_w && g_head[1];
	assign g_line = sel_w ? w_line : sel_d ? d_line : sel_x ? s_line : a_line;
	assign g_be = g_head[20+RW+LAW +: LINE_BYTES];
	assign g_wdata = sel_d ? d_data : sel_x ? (src_p ? p_data : j_data) : a_data;
	assign g_user = sel_w ? {{RW{1'b0}}, 8'hFF, 8'h00} : {g_head[20 +: RW], g_head[19:4]};

	/* The refusal: D, J or P, A; only when no AXI grant is made. */
	wire bd_d = d_on && !d_inside;
	wire bd_x = !bd_d && x_bad;
	wire bd_a = !bd_d && !bd_x && a_bad;
	assign bad = !err_busy && !g_fire && (bd_d || bd_x || bd_a);
	wire [LB-1:0] b_head = bd_d ? d_head : bd_x ? {{(LB-HPW){1'b0}}, s_head} : a_head;
	assign bad_head = b_head[HPW-1:0];
	assign bad_line = bd_d ? d_line : bd_x ? s_line : a_line;
	assign bad_prot = bd_x && !(src_p && p_err) || bd_a && a_inside;
	assign bad_mem = bd_x && src_p && p_err;

	wire fired_x = g_fire && sel_x || bad && bd_x;
	wire fired_a = g_fire && sel_a || bad && bd_a;
	assign d_take = g_fire && sel_d || bad && bd_d;
	assign done = g_fire && !sel_w || bad;
	assign done_chk = fired_x || fired_a && a_chk;

	wire j_leave = fired_x && !src_p || j_to_p;
	wire a_to_j = P && a_valid && !a_direct && (!j_v || j_leave);
	assign a_take = fired_a || a_to_j;

	/* ------------------------------------------- invalidation */

	wire w_stale = p_stale || p_inv;
	assign fill = P && w_valid && !w_error && !w_stale;
	assign inv_pending = inv_pend;

	/* ------------------------------------------- J and P registers */

	always @(posedge clk) begin
		if (!rst_n || flush || !P) begin
			j_v <= 1'b0;
			p_v <= 1'b0;
			p_walk <= 1'b0;
			p_stale <= 1'b0;
			p_err <= 1'b0;
			inv_pend <= 1'b0;
		end else begin
			if (j_leave)
				j_v <= 1'b0;
			if (a_to_j)
				j_v <= 1'b1;
			if (fired_x && src_p) begin
				p_v <= 1'b0;
				inv_pend <= 1'b0;
			end
			if (j_to_p) begin
				p_v <= 1'b1;
				p_err <= 1'b0;
			end
			if (g_fire && sel_w) begin
				p_walk <= 1'b1;
				p_stale <= 1'b0;
			end
			if (p_walk && p_inv) begin
				p_stale <= 1'b1;
				inv_pend <= 1'b1;
			end
			if (w_valid) begin
				p_walk <= 1'b0;
				p_err <= w_error;
				if (!w_stale)
					inv_pend <= 1'b0;
			end
		end
	end

	always @(posedge clk) begin
		if (a_to_j) begin
			j_head <= a_head[HPW-1:0];
			j_data <= a_data;
			j_line <= a_line;
		end
		if (j_to_p) begin
			p_head <= j_head;
			p_data <= j_data;
			p_line <= j_line;
		end
	end

	wire unused_ok = &{1'b0, a_head, d_head, g_head, b_head, j_head, s_head, lim_up, tgran,
		p_idx, tend};
endmodule

`default_nettype wire
