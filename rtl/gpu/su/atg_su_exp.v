/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp: the fragment export buffer: exp of the colour attachments
 * 0-3 (0x100 + 16 k + c, CAPS[30]) and DEPTH (0x104) by fragment warps
 * into the warp's buffer, drained to the ROP after the warp's end, in
 * sequence-number order, by atg_su_exp_drain (one beat per exported
 * attachment of each quad); the slot release (xr_*) of every ended warp.
 * The PT and its allocator are atg_su_pt.
 *
 * The warp's quads come from the RX's register writes (fl_*): r3 (z) of
 * every lane is the depth unless the shader exports 0x104, r4/r5 (the
 * pixel centre, x + 0.5 and y + 0.5) of lane 4q give quad q's position;
 * fl_go gives the coverage and the sequence number (fl_info).  A quad of
 * the warp is one with coverage (RX packs the quads from lane 0).
 * ex_mask = the covered lanes that some fragment exp wrote under the
 * side-effect mask (EXEC & coverage & ~KILLED).  Storage: NPHYS lane
 * banks × 18 words (R, G, B, A of 4 attachments, depth, z) × NWARPS×32/NPHYS
 * rows, written one word per bank per cycle, read asynchronously (a
 * quad's 4 lanes are in 4 banks of one row).  The warp's attachments
 * (rtw) are those some fragment exp of a colour wrote under a non-empty
 * side-effect mask; every beat of a quad carries the same ex_mask.
 *
 * Multisampling (docs/ghci.md section 12.11): the RX's r6 (the lane's
 * samples after the sample mask test) is snooped like r3 (a lane the RX
 * did not write takes 1111); exp 0x105 (SAMPLE_MASK) keeps the last value
 * written per lane; the quad's sample mask is r6 AND that value (1111 when
 * none), lane l at ex_aux bits 4 l + s.  A lane whose mask is 0 does not go
 * out (ex_mask).  ex_aux also carries the lanes that exported DEPTH and the
 * warp's d_s (the RX's table words 0xFF8-0xFFB, one per sample; 0 for a
 * warp without them: the slot's copy is cleared at its release).
 * ex_aux = {rt[1:0], qlast, qfirst, nocol, front, d_s, zexp, smask}: the
 * beat's attachment, its place in the quad, no colour, the warp's facing.
 * scrub (session protection, the unit idle) writes 0 to every row of every
 * bank through each array's write port, one row per cycle, while
 * scrub_busy (a component a fragment does not export is not another
 * session's).
 * See spec/gpu/su/atg_su_exp.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exp #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter LDS_BYTES = 4096,	/* Shared memory bytes */
	parameter LDS_AW = $clog2(LDS_BYTES / 4),
`ifdef CFG_ENABLE_MESH
	parameter HAS_MESH = (`CFG_ENABLE_MESH != 0),
`else
	parameter HAS_MESH = 0,
`endif
	parameter MRT_COUNT = 8,	/* Colour attachments supported (1..8) */
	parameter DUAL_SOURCE = 1	/* Dual-source color1 export support (0/1) */
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
	/* Export to the ROP (atg_rop) */
	output wire ex_valid,
	input wire ex_ready,
	output wire [15:0] ex_seq,
	output wire [31:0] ex_xy,
	output wire [3:0] ex_mask,
	output wire [511:0] ex_color,
	output wire [511:0] ex_color1,
	output wire ex_has_src1,
	output wire [127:0] ex_depth,
	output wire ex_last,
	input wire [15:0] ex_next,
	/* Fragment warps from the RX (snooped: atg_su fl_*) */
	input wire fl_we,
	input wire [WARP_W-1:0] fl_slot,
	input wire [5:0] fl_reg,
	input wire [4:0] fl_lane,
	input wire [31:0] fl_data,
	input wire fl_go,
	input wire [63:0] fl_info,
	input wire fl_pw_we,
	input wire [11:0] fl_pw_addr,
	input wire [31:0] fl_pw_data,
	/* The beat's attachment and multisampling to the ROP */
	output wire [154:0] ex_aux,	/* {rt, qlast, qfirst, nocol, front, d_s, zexp, smask} */
	/* Slot release (atg_su_sched) */
	output wire xr_valid,
	output wire [WARP_W-1:0] xr_warp,
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp,
	/* Session protection: clear the buffer */
	input wire scrub,
	output wire scrub_busy,
	/* Meshlet Primitive Export to RX (atg_rx_setup) */
	output wire mesh_valid,
	input wire mesh_ready,
	output wire [701:0] mesh_tri,
	output wire mesh_last,
	output wire [15:0] mesh_id,
	output wire mesh_busy,
	/* LDS Port B Read Interface */
	output wire mesh_lds_rd_en,
	output wire [LDS_AW-1:0] mesh_lds_rd_addr,
	input wire [31:0] mesh_lds_rd_data
);
`include "atg_su_uop.vh"

	wire [WARP_W-1:0] fl_slot_top, fl_slot_gw_in;

	assign fl_slot_top   = fl_slot;
	assign fl_slot_gw_in = fl_slot;


	localparam G = 32 / NPHYS;
	localparam ROWS = NWARPS * G;
	localparam RW = ROWS > 1 ? $clog2(ROWS) : 1;
	localparam G_W = $clog2(G);	/* G is a power of two: warp G + group are disjoint bits */
	localparam RT_SLOTS = (MRT_COUNT <= 1) ? 1 : ((MRT_COUNT <= 2) ? 2 : ((MRT_COUNT <= 4) ? 4 : 8));
	localparam RT_AW = (RT_SLOTS == 1) ? 0 : ((RT_SLOTS == 2) ? 1 : ((RT_SLOTS == 4) ? 2 : 3));
	localparam C_DEPTH = ROWS * RT_SLOTS;
	localparam CAW = RW + RT_AW;
	localparam [2:0] RT_MAX = (MRT_COUNT >= 8) ? 3'd7 : ((MRT_COUNT <= 1) ? 3'd0 : (MRT_COUNT - 1));

	/* ---- Per warp. */
	reg [NWARPS-1:0] fr;	/* the warp's facing (fl_info[48]) */
	reg [NWARPS*8-1:0] rtw;	/* the attachments exported (8 attachments) */
	wire [NWARPS-1:0] has_src1_w;	/* whether the warp exported src1 (COLOR1) */
	wire [NWARPS*32-1:0] cov, xp, dw;	/* coverage, exported lanes, depth written */
	wire [NWARPS*32-1:0] smw, r6w;	/* SAMPLE_MASK exported, r6 written by the RX */
	wire [NWARPS*128-1:0] dsv;	/* the warp's d_s */
	wire [NWARPS*8*16-1:0] qx, qy;

	/*
	 * 1-cycle input pipeline stage on x_* to isolate OPD -> EXP long route from LUTRAM write ports.
	 * Timing invariant (0-cycle margin):
	 *   - With r_x_*, LUTRAM/rtw/has_src1_r/mesh writes take effect 2 cycles after exp issues.
	 *   - wc_end arrives from atg_su_exec's registered wc_v 1 cycle after END issues.
	 *   - Single-issue from opd guarantees the last exp issues >= 1 cycle before END, so its
	 *     writes complete by wc_end before drain starts reading. Dual-issue or an earlier wc_end
	 *     would violate this ordering and require delaying wc_end (or bypassing r_x_*).
	 */
	wire rst_exp_p = !rst_n;
	reg r_x_valid;
	reg [WARP_W-1:0] r_x_warp;
	reg [GRP_W-1:0] r_x_grp;
	reg [3:0] r_x_unit;
	reg [31:0] r_x_tgt;
	reg [NPHYS-1:0] r_x_side;
	reg [17:0] r_x_info;
	(* keep = "true" *) reg [NPHYS*32-1:0] r_x_b;
	always @(posedge clk or posedge rst_exp_p) begin
		if (rst_exp_p) begin
			r_x_valid <= 1'b0;
			r_x_warp  <= {WARP_W{1'b0}};
			r_x_grp   <= {GRP_W{1'b0}};
			r_x_unit  <= 4'd0;
			r_x_tgt   <= 32'd0;
			r_x_side  <= {NPHYS{1'b0}};
			r_x_info  <= 18'd0;
		end else begin
			r_x_valid <= x_valid;
			r_x_warp  <= x_warp;
			r_x_grp   <= x_grp;
			r_x_unit  <= x_uop[ATG_UOP_UNIT +: 4];
			r_x_tgt   <= x_uop[ATG_UOP_IMM +: 32];
			r_x_side  <= x_mask[2*NPHYS-1:NPHYS];
			r_x_info  <= x_info[17:0];
		end
	end
	always @(posedge clk) begin
		r_x_b <= x_b;
	end

	/* ---- Exports of fragment warps: colour k component c at 0x100 + 16 k + c;
	 * 0x108 + c is the second colour (src1) of attachment 0 for dual-source blending. */
	wire [31:0] tgt = r_x_tgt;
	wire ex_frag = r_x_valid && r_x_unit == ATG_UNIT_EXP && r_x_info[17:16] == 2'd1;
	wire [2:0] tk = tgt[6:4];
	wire ex_col  = ex_frag && tgt[31:7] == 25'd2 && tgt[3:2] == 2'd0 &&
		((MRT_COUNT >= 8) || (tk <= RT_MAX));
	wire ex_col1 = (DUAL_SOURCE != 0) && ex_frag && tgt[31:4] == 28'h010 && tgt[3:2] == 2'b10;
	wire ex_dep  = ex_frag && tgt == 32'h104;
	wire ex_sm   = ex_frag && tgt == 32'h105;
	wire ex_op   = ex_col || ex_dep || ex_sm;
	wire [2:0] tk_xcrow, tk_rtw;
	genvar gtk;
	generate
		for (gtk = 0; gtk < 3; gtk = gtk + 1) begin : g_tk_buf

			assign tk_xcrow[gtk] = tk[gtk];
			assign tk_rtw[gtk]   = tk[gtk];

		end
	endgenerate
	wire [1:0] comp = tgt[1:0];

	wire [WARP_W-1:0] x_warp_row;
	wire [WARP_W-1:0] x_warp_ctrl;
	wire [WARP_W-1:0] x_warp_rtw;
	genvar gxwb;
	generate
		for (gxwb = 0; gxwb < WARP_W; gxwb = gxwb + 1) begin : g_xwarp_buf

			assign x_warp_row[gxwb]  = r_x_warp[gxwb];
			assign x_warp_ctrl[gxwb] = r_x_warp[gxwb];
			assign x_warp_rtw[gxwb]  = r_x_warp[gxwb];

		end
	endgenerate

	wire [GRP_W-1:0] x_grp_row;
	wire [GRP_W-1:0] x_grp_sw0;
	wire [GRP_W-1:0] x_grp_sw1;
	genvar gxgb;
	generate
		for (gxgb = 0; gxgb < GRP_W; gxgb = gxgb + 1) begin : g_xgrp_buf

			assign x_grp_row[gxgb] = r_x_grp[gxgb];
			assign x_grp_sw0[gxgb] = r_x_grp[gxgb];
			assign x_grp_sw1[gxgb] = r_x_grp[gxgb];

		end
	endgenerate

	wire [31:0] xrow = ({{(32-WARP_W){1'b0}}, x_warp_row} << G_W) | ({{(32-GRP_W){1'b0}}, x_grp_row} % G);
	wire [NPHYS-1:0] side = r_x_side;
	wire [NPHYS-1:0] side_shf;
	wire [NPHYS-1:0] side_cmp;
	wire [NPHYS-1:0] side_bnk;
	genvar gsb;
	generate
		for (gsb = 0; gsb < NPHYS; gsb = gsb + 1) begin : g_side_buf

			assign side_shf[gsb] = side[gsb];
			assign side_cmp[gsb] = side[gsb];
			assign side_bnk[gsb] = side[gsb];

		end
	endgenerate
	wire [31:0] lane0 = {{(32-GRP_W){1'b0}}, x_grp_row} * NPHYS;
	wire [31:0] side_w;
	genvar gg;
	generate
		if (G == 1) begin : g_sw_g1
			assign side_w = side_shf;
		end else begin : g_sw_gn
			for (gg = 0; gg < G; gg = gg + 1) begin : g_sw_loop
				assign side_w[gg * NPHYS +: NPHYS] = (x_grp_sw0 == gg[GRP_W-1:0]) ? side_shf : {NPHYS{1'b0}};
			end
		end
	endgenerate
	wire [4:0] fl_lane_z;
	genvar gzln;
	generate
		for (gzln = 0; gzln < 5; gzln = gzln + 1) begin : g_zlane_buf

			assign fl_lane_z[gzln] = fl_lane[gzln];

		end
	endgenerate
	wire [31:0] zrow = ({{(32-WARP_W){1'b0}}, fl_slot_top} << G_W) | ({27'd0, fl_lane_z} / NPHYS);
	wire [31:0] zbank = {27'd0, fl_lane_z} % NPHYS;
	wire [31:0] fq = {{(25-WARP_W){1'b0}}, fl_slot_top, fl_lane_z[4:2], 4'd0};

	/* ---- The drain (atg_su_exp_drain): the beat of warp dwarp, quad dq, attachment drt. */
	wire [WARP_W-1:0] dwarp;
	wire [2:0] dq;
	wire [2:0] drt;
	wire dfirst, dlastb, dnocol;
	wire [31:0] dcov, dxp_raw, ddw, dsm, dr6;
	genvar gwm;
	generate
		for (gwm = 0; gwm < 2; gwm = gwm + 1) begin : g_wmux_sl
			wire [WARP_W-1:0] dw_cov_s;
			wire [WARP_W-1:0] dw_xp_s;
			wire [WARP_W-1:0] dw_dw_s;
			wire [WARP_W-1:0] dw_sm_s;
			wire [WARP_W-1:0] dw_r6_s;
			genvar gb;
			for (gb = 0; gb < WARP_W; gb = gb + 1) begin : g_wm_buf

				assign dw_cov_s[gb] = dwarp[gb];
				assign dw_xp_s[gb]  = dwarp[gb];
				assign dw_dw_s[gb]  = dwarp[gb];
				assign dw_sm_s[gb]  = dwarp[gb];
				assign dw_r6_s[gb]  = dwarp[gb];

			end
			assign dcov[gwm*16 +: 16]    = cov[dw_cov_s*32 + gwm*16 +: 16];
			assign dxp_raw[gwm*16 +: 16] = xp[dw_xp_s*32 + gwm*16 +: 16];
			assign ddw[gwm*16 +: 16]     = dw[dw_dw_s*32 + gwm*16 +: 16];
			assign dsm[gwm*16 +: 16]     = smw[dw_sm_s*32 + gwm*16 +: 16];
			assign dr6[gwm*16 +: 16]     = r6w[dw_r6_s*32 + gwm*16 +: 16];
		end
	endgenerate
	wire [WARP_W-1:0] dw_rtw;
	genvar gbr;
	generate
		for (gbr = 0; gbr < WARP_W; gbr = gbr + 1) begin : g_dw_rtw_buf

			assign dw_rtw[gbr] = dwarp[gbr];

		end
	endgenerate
	wire [36*WARP_W-1:0] dwarp_rep;
	wire [20*3-1:0] dq_rep;
	atg_su_exp_drain #(.NWARPS(NWARPS), .WARP_W(WARP_W)) drain (
		.clk(clk), .rst_n(rst_n), .fl_go(fl_go), .fl_slot(fl_slot_top), .fl_seq(fl_info[47:32]),
		.wc_end(wc_end), .wc_warp(wc_warp), .d_cov(dcov), .d_rtw(rtw[dw_rtw*8 +: 8]),
		.d_warp(dwarp), .d_q(dq), .d_rt(drt), .d_warp_rep(dwarp_rep), .d_q_rep(dq_rep),
		.d_first(dfirst), .d_lastb(dlastb),
		.d_nocol(dnocol), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq),
		.ex_last(ex_last), .ex_next(ex_next), .xr_valid(xr_valid), .xr_warp(xr_warp)
	);

	wire [2:0] dq_dl;

	assign dq_dl = dq;

	wire [4:0] dl0 = {dq_dl, 2'b00};
	wire [31:0] drow = {{(32-WARP_W){1'b0}}, dwarp} * G + {27'd0, dl0} / NPHYS;
	wire [CAW-1:0] dcrow, xcrow;
	generate
		if (RT_AW == 0) begin : g_crow_single
			assign dcrow = drow[RW-1:0];
			assign xcrow = xrow[RW-1:0];
		end else begin : g_crow_mrt
			assign dcrow = {drow[RW-1:0], drt[RT_AW-1:0]};
			assign xcrow = {xrow[RW-1:0], tk_xcrow[RT_AW-1:0]};
		end
	endgenerate
	wire [31:0] dqs = ({{(32-WARP_W){1'b0}}, dwarp} * 8 + {29'd0, dq}) * 16;
	wire [31:0] dxp = dxp_raw & dcov;

	wire [3:0] col_comp_match;
	wire [3:0] col1_comp_match;
	genvar gcm;
	generate
		for (gcm = 0; gcm < 4; gcm = gcm + 1) begin : g_comp_match
			assign col_comp_match[gcm]  = ex_col  && (comp == gcm[1:0]);
			assign col1_comp_match[gcm] = ex_col1 && (comp == gcm[1:0]);
		end
	endgenerate

	wire [3:0] col_match_q [0:1];
	wire [3:0] col1_match_q [0:1];
	wire dep_q [0:1];
	wire sm_q [0:1];
	wire [CAW-1:0] xcrow_q [0:1];
	wire [RW-1:0] xrow_q [0:1];
	genvar gmq, gmc, gq_bit;
	generate
		for (gmq = 0; gmq < 2; gmq = gmq + 1) begin : g_match_q
			for (gmc = 0; gmc < 4; gmc = gmc + 1) begin : g_match_c

				assign col_match_q[gmq][gmc]  = col_comp_match[gmc];
				assign col1_match_q[gmq][gmc] = col1_comp_match[gmc];

			end
			assign dep_q[gmq] = ex_dep;
			assign sm_q[gmq]  = ex_sm;
			for (gq_bit = 0; gq_bit < CAW; gq_bit = gq_bit + 1) begin : g_quad_xcbit

				assign xcrow_q[gmq][gq_bit] = xcrow[gq_bit];

			end
			for (gq_bit = 0; gq_bit < RW; gq_bit = gq_bit + 1) begin : g_quad_xrbit

				assign xrow_q[gmq][gq_bit] = xrow[gq_bit];

			end
		end
	endgenerate

	/* The scrub: rows of the attachments' arrays; the others take its row / RT_SLOTS. */
	wire sc_on;
	wire [CAW-1:0] sc_a;

	atg_su_scrub #(.DEPTH(C_DEPTH), .AW(CAW)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	assign scrub_busy = sc_on;

	/* NPHYS lane banks × {R, G, B, A of RT_SLOTS attachments, depth, z} and {SAMPLE_MASK, r6}. */
	wire [NPHYS*192-1:0] rdat;
	wire [NPHYS*128-1:0] rdat1;
	wire [NPHYS*8-1:0] rsm;
	genvar b, bs, bh;
	generate
	wire [NPHYS-1:0] sc_on_bnk;
	genvar gscb;
	for (gscb = 0; gscb < NPHYS; gscb = gscb + 1) begin : g_sc_buf

		assign sc_on_bnk[gscb] = sc_on;

	end

	wire [CAW-1:0] sc_a_pair [0:3];
	genvar gsp, gsa_b;
	for (gsp = 0; gsp < 4; gsp = gsp + 1) begin : g_sca_pair
		for (gsa_b = 0; gsa_b < CAW; gsa_b = gsa_b + 1) begin : g_sca_pb

			assign sc_a_pair[gsp][gsa_b] = sc_a[gsa_b];

		end
	end

	wire [CAW-1:0] dcrow_pair [0:NPHYS-1];
	wire [RW-1:0] drow_pair [0:NPHYS-1];
	genvar gdp;
	for (gdp = 0; gdp < NPHYS; gdp = gdp + 1) begin : g_dr_pair
		wire [WARP_W-1:0] dw_b = dwarp_rep[gdp*WARP_W +: WARP_W];
		wire [2:0] dq_b = dq_rep[(gdp / 4)*3 +: 3];
		wire [31:0] drow_b = {{(32-WARP_W){1'b0}}, dw_b} * G + {27'd0, dq_b, 2'b00} / NPHYS;
		assign drow_pair[gdp] = drow_b[RW-1:0];
		if (RT_AW == 0) begin : g_dcr_s
			assign dcrow_pair[gdp] = drow_b[RW-1:0];
		end else begin : g_dcr_m
			assign dcrow_pair[gdp] = {drow_b[RW-1:0], drt[RT_AW-1:0]};
		end
	end

	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		wire b_sc_on_c0_we, b_sc_on_c0_sl;
		wire b_sc_on_c1_we, b_sc_on_c1_sl;
		wire b_sc_on_r0_we, b_sc_on_r0_sl;
		wire b_sc_on_r1_we, b_sc_on_r1_sl;

		assign b_sc_on_c0_we = sc_on_bnk[b];
		assign b_sc_on_c0_sl = sc_on_bnk[b];
		assign b_sc_on_c1_we = sc_on_bnk[b];
		assign b_sc_on_c1_sl = sc_on_bnk[b];
		assign b_sc_on_r0_we = sc_on_bnk[b];
		assign b_sc_on_r0_sl = sc_on_bnk[b];
		assign b_sc_on_r1_we = sc_on_bnk[b];
		assign b_sc_on_r1_sl = sc_on_bnk[b];

		localparam b_half = (b >= NPHYS/2) ? 1 : 0;
		localparam b_quad = (b * 4) / NPHYS;
		wire [CAW-1:0] b_sc_a_c0, b_sc_a_c1;
		wire [RW-1:0] b_sc_ar_0, b_sc_ar_1;
		genvar gsa;
		for (gsa = 0; gsa < CAW; gsa = gsa + 1) begin : g_b_sca

			assign b_sc_a_c0[gsa] = sc_a_pair[b_quad][gsa];
			assign b_sc_a_c1[gsa] = sc_a_pair[b_quad][gsa];

		end
		for (gsa = 0; gsa < RW; gsa = gsa + 1) begin : g_b_scar

			assign b_sc_ar_0[gsa] = sc_a_pair[b_quad][gsa + RT_AW];
			assign b_sc_ar_1[gsa] = sc_a_pair[b_quad][gsa + RT_AW];

		end
		wire [CAW-1:0] b_xcrow_0, b_xcrow_1;
		wire [RW-1:0] b_xrow_0, b_xrow_1;
		genvar gxc, gxr;
		for (gxc = 0; gxc < CAW; gxc = gxc + 1) begin : g_b_xc

			assign b_xcrow_0[gxc] = xcrow_q[b_half][gxc];
			assign b_xcrow_1[gxc] = xcrow_q[b_half][gxc];

		end
		for (gxr = 0; gxr < RW; gxr = gxr + 1) begin : g_b_xr

			assign b_xrow_0[gxr] = xrow_q[b_half][gxr];
			assign b_xrow_1[gxr] = xrow_q[b_half][gxr];

		end
		wire [RW-1:0] b_zrow     = zrow[RW-1:0];
		wire [CAW-1:0] b_dcrow_0, b_dcrow_1;
		wire [RW-1:0] b_drow_0, b_drow_1, b_drow_rsm;
		genvar gbd;
		for (gbd = 0; gbd < CAW; gbd = gbd + 1) begin : g_b_dcrow

			assign b_dcrow_0[gbd] = dcrow_pair[b][gbd];
			assign b_dcrow_1[gbd] = dcrow_pair[b][gbd];

		end
		for (gbd = 0; gbd < RW; gbd = gbd + 1) begin : g_b_drow

			assign b_drow_0[gbd] = drow_pair[b][gbd];
			assign b_drow_1[gbd] = drow_pair[b][gbd];
			assign b_drow_rsm[gbd] = drow_pair[b][gbd];

		end
		wire b_we_0 = b_sc_on_c0_we || (side_bnk[b] && col_match_q[b_half][0]);
		wire b_we_1 = b_sc_on_c0_we || (side_bnk[b] && col_match_q[b_half][1]);
		wire b_we_2 = b_sc_on_c1_we || (side_bnk[b] && col_match_q[b_half][2]);
		wire b_we_3 = b_sc_on_c1_we || (side_bnk[b] && col_match_q[b_half][3]);
		wire b_we_s0 = b_sc_on_r0_we || (side_bnk[b] && col1_match_q[b_half][0]);
		wire b_we_s1 = b_sc_on_r0_we || (side_bnk[b] && col1_match_q[b_half][1]);
		wire b_we_s2 = b_sc_on_r1_we || (side_bnk[b] && col1_match_q[b_half][2]);
		wire b_we_s3 = b_sc_on_r1_we || (side_bnk[b] && col1_match_q[b_half][3]);
		wire b_we_m4 = b_sc_on_r0_we || (side_bnk[b] && dep_q[b_half]);
		wire b_we_mz = b_sc_on_r1_we || (fl_we && fl_reg == 6'd3 && zbank == b);

		wire [RW-1:0] r_wa_m5  = b_sc_on_r1_we ? b_sc_ar_1 : b_xrow_1;
		wire [RW-1:0] z_wa_mr6 = b_sc_on_r1_we ? b_sc_ar_1 : b_zrow;
		wire [RW-1:0] drow_rsm = b_drow_rsm;
		wire we_m5 = b_sc_on_r1_we || (side_bnk[b] && sm_q[b_half]);
		wire we_mr6 = b_sc_on_r1_we || (fl_we && fl_reg == 6'd6 && zbank == b);
		wire [3:0] d_m5 = b_sc_on_r1_we ? 4'd0 : r_x_b[32 * b +: 4];
		wire [3:0] fd_mr6 = b_sc_on_r1_we ? 4'd0 : fl_data[3:0];

		reg [3:0] m5 [0:ROWS-1];
		reg [3:0] mr6 [0:ROWS-1];
		always @(posedge clk) begin
			if (we_m5) m5[r_wa_m5] <= d_m5;
			if (we_mr6) mr6[z_wa_mr6] <= fd_mr6;
		end
		assign rsm[8 * b +: 8] = {m5[drow_rsm], mr6[drow_rsm]};

		for (bs = 0; bs < 8; bs = bs + 1) begin : g_col_sl
			wire b_scon_raw = (bs < 4) ? b_sc_on_c0_sl : b_sc_on_c1_sl;
			wire b_scon_a, b_scon_d;

			assign b_scon_a = b_scon_raw;
			assign b_scon_d = b_scon_raw;

			wire [CAW-1:0] b_sca_raw = (bs < 4) ? b_sc_a_c0 : b_sc_a_c1;
			wire [CAW-1:0] b_sca;
			genvar gba;
			for (gba = 0; gba < CAW; gba = gba + 1) begin : g_sca_buf

				assign b_sca[gba] = b_sca_raw[gba];

			end
			wire [CAW-1:0] b_xcr = (bs < 4) ? b_xcrow_0 : b_xcrow_1;
			wire [CAW-1:0] b_dcr = (bs < 4) ? b_dcrow_0 : b_dcrow_1;
			wire [CAW-1:0] c_wa_raw = b_scon_a ? b_sca : b_xcr;
			wire [CAW-1:0] c_wa_0, c_wa_1, c_wa_2, c_wa_3;
			genvar gbw;
			for (gbw = 0; gbw < CAW; gbw = gbw + 1) begin : g_cwa_buf

				assign c_wa_0[gbw] = c_wa_raw[gbw];
				assign c_wa_1[gbw] = c_wa_raw[gbw];
				assign c_wa_2[gbw] = c_wa_raw[gbw];
				assign c_wa_3[gbw] = c_wa_raw[gbw];

			end
			wire [CAW-1:0] dcrow_01, dcrow_23;

			assign dcrow_01 = b_dcr;
			assign dcrow_23 = b_dcr;

			wire we_0, we_1, we_2, we_3;

			assign we_0 = b_we_0;
			assign we_1 = b_we_1;
			assign we_2 = b_we_2;
			assign we_3 = b_we_3;

			wire [3:0] d_sl = b_scon_d ? 4'd0 : r_x_b[32 * b + bs * 4 +: 4];

			reg [3:0] m0 [0:C_DEPTH-1];
			reg [3:0] m1 [0:C_DEPTH-1];
			reg [3:0] m2 [0:C_DEPTH-1];
			reg [3:0] m3 [0:C_DEPTH-1];
			always @(posedge clk) begin
				if (we_0) m0[c_wa_0] <= d_sl;
				if (we_1) m1[c_wa_1] <= d_sl;
				if (we_2) m2[c_wa_2] <= d_sl;
				if (we_3) m3[c_wa_3] <= d_sl;
			end
			assign rdat[192 * b + 0   + bs * 4 +: 4] = m0[dcrow_01];
			assign rdat[192 * b + 32  + bs * 4 +: 4] = m1[dcrow_01];
			assign rdat[192 * b + 64  + bs * 4 +: 4] = m2[dcrow_23];
			assign rdat[192 * b + 96  + bs * 4 +: 4] = m3[dcrow_23];
		end

		for (bh = 0; bh < 4; bh = bh + 1) begin : g_row_sl
			wire b_scon_raw = (bh < 2) ? b_sc_on_r0_sl : b_sc_on_r1_sl;
			wire b_scon_a, b_scon_d;

			assign b_scon_a = b_scon_raw;
			assign b_scon_d = b_scon_raw;

			wire [RW-1:0] b_scar = (bh < 2) ? b_sc_ar_0 : b_sc_ar_1;
			wire [RW-1:0] b_xr   = (bh < 2) ? b_xrow_0  : b_xrow_1;
			wire [RW-1:0] b_dr   = (bh < 2) ? b_drow_0  : b_drow_1;
			wire [RW-1:0] b_zrow_h;

			assign b_zrow_h = b_zrow;

			wire [RW-1:0] r_wa_raw = b_scon_a ? b_scar : b_xr;
			wire [RW-1:0] z_wa_raw = b_scon_a ? b_scar : b_zrow_h;
			wire [RW-1:0] r_wa_s0, r_wa_s1, r_wa_s2, r_wa_s3, r_wa_m4, z_wa_mz;
			genvar grw;
			for (grw = 0; grw < RW; grw = grw + 1) begin : g_rwa_buf

				assign r_wa_s0[grw] = r_wa_raw[grw];
				assign r_wa_s1[grw] = r_wa_raw[grw];
				assign r_wa_s2[grw] = r_wa_raw[grw];
				assign r_wa_s3[grw] = r_wa_raw[grw];
				assign r_wa_m4[grw] = r_wa_raw[grw];
				assign z_wa_mz[grw] = z_wa_raw[grw];

			end
			wire [RW-1:0] drow_s01, drow_s23, drow_m4z;

			assign drow_s01 = b_dr;
			assign drow_s23 = b_dr;
			assign drow_m4z = b_dr;

			wire we_s0, we_s1, we_s2, we_s3, we_m4, we_mz;

			assign we_s0 = b_we_s0;
			assign we_s1 = b_we_s1;
			assign we_s2 = b_we_s2;
			assign we_s3 = b_we_s3;
			assign we_m4 = b_we_m4;
			assign we_mz = b_we_mz;

			wire [7:0] d_h = b_scon_d ? 8'd0 : r_x_b[32 * b + bh * 8 +: 8];
			wire [7:0] fd_h = b_scon_d ? 8'd0 : fl_data[bh * 8 +: 8];

			if (DUAL_SOURCE != 0) begin : g_ms1
				reg [7:0] ms1_0 [0:ROWS-1];
				reg [7:0] ms1_1 [0:ROWS-1];
				reg [7:0] ms1_2 [0:ROWS-1];
				reg [7:0] ms1_3 [0:ROWS-1];
				always @(posedge clk) begin
					if (we_s0) ms1_0[r_wa_s0] <= d_h;
					if (we_s1) ms1_1[r_wa_s1] <= d_h;
					if (we_s2) ms1_2[r_wa_s2] <= d_h;
					if (we_s3) ms1_3[r_wa_s3] <= d_h;
				end
				assign rdat1[128 * b + 0  + bh * 8 +: 8] = ms1_0[drow_s01];
				assign rdat1[128 * b + 32 + bh * 8 +: 8] = ms1_1[drow_s01];
				assign rdat1[128 * b + 64 + bh * 8 +: 8] = ms1_2[drow_s23];
				assign rdat1[128 * b + 96 + bh * 8 +: 8] = ms1_3[drow_s23];
			end else begin : g_no_ms1
				assign rdat1[128 * b + 0  + bh * 8 +: 8] = 8'd0;
				assign rdat1[128 * b + 32 + bh * 8 +: 8] = 8'd0;
				assign rdat1[128 * b + 64 + bh * 8 +: 8] = 8'd0;
				assign rdat1[128 * b + 96 + bh * 8 +: 8] = 8'd0;
			end
			reg [7:0] m4 [0:ROWS-1];
			reg [7:0] mz [0:ROWS-1];
			always @(posedge clk) begin
				if (we_m4) m4[r_wa_m4] <= d_h;
				if (we_mz) mz[z_wa_mz] <= fd_h;
			end
			assign rdat[192 * b + 128 + bh * 8 +: 8] = m4[drow_m4z];
			assign rdat[192 * b + 160 + bh * 8 +: 8] = mz[drow_m4z];
		end
	end
	endgenerate

	/* The quad's lanes i = 0..3 are lanes 4 dq + i, banks (4 dq + i) mod NPHYS. */
	wire [511:0] col, col1;
	wire [127:0] dep;
	reg [7:0] ls;
	reg [15:0] smask;
	reg [3:0] zexp;
	reg [3:0] smok;
	integer i;

	genvar gi, gch;
	generate
		for (gi = 0; gi < 4; gi = gi + 1) begin : g_qmux
			wire [2:0] dq_col  = dq_rep[(8 + gi*3 + 0)*3 +: 3];
			wire [2:0] dq_col1 = dq_rep[(8 + gi*3 + 1)*3 +: 3];
			wire [2:0] dq_dep  = dq_rep[(8 + gi*3 + 2)*3 +: 3];
			wire [4:0] lane_col  = {dq_col,  gi[1:0]} & (NPHYS - 1);
			wire [4:0] lane_col1 = {dq_col1, gi[1:0]} & (NPHYS - 1);
			wire [4:0] lane_dep  = {dq_dep,  gi[1:0]} & (NPHYS - 1);
			wire q_ddw = ddw[{dq_dep, gi[1:0]}];
			wire q_ddw_ch0, q_ddw_ch1;

			assign q_ddw_ch0 = q_ddw;
			assign q_ddw_ch1 = q_ddw;


			for (gch = 0; gch < 8; gch = gch + 1) begin : g_c_sl
				wire [4:0] lane_col_ch_lo, lane_col_ch_hi;
				wire [4:0] lane_col1_ch_lo, lane_col1_ch_hi;
				genvar glb;
				for (glb = 0; glb < 5; glb = glb + 1) begin : g_lbuf

					assign lane_col_ch_lo[glb]  = lane_col[glb];
					assign lane_col_ch_hi[glb]  = lane_col[glb];
					assign lane_col1_ch_lo[glb] = lane_col1[glb];
					assign lane_col1_ch_hi[glb] = lane_col1[glb];

				end
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(0), .CH_IDX(gch)) u_col_lo (
					.all_rdat(rdat), .l_idx(lane_col_ch_lo),
					.byte_out(col[128 * gi + gch * 16 +: 8])
				);
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(1), .CH_IDX(gch)) u_col_hi (
					.all_rdat(rdat), .l_idx(lane_col_ch_hi),
					.byte_out(col[128 * gi + gch * 16 + 8 +: 8])
				);
				if (DUAL_SOURCE != 0) begin : g_col1_mux
					atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(128), .HI(0), .CH_IDX(gch)) u_col1_lo (
						.all_rdat(rdat1), .l_idx(lane_col1_ch_lo),
						.byte_out(col1[128 * gi + gch * 16 +: 8])
					);
					atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(128), .HI(1), .CH_IDX(gch)) u_col1_hi (
						.all_rdat(rdat1), .l_idx(lane_col1_ch_hi),
						.byte_out(col1[128 * gi + gch * 16 + 8 +: 8])
					);
				end else begin : g_no_col1_mux
					assign col1[128 * gi + gch * 16 +: 16] = 16'd0;
				end
			end
			for (gch = 0; gch < 2; gch = gch + 1) begin : g_d_sl
				wire [4:0] lane_dep_m4_lo, lane_dep_m4_hi;
				wire [4:0] lane_dep_mz_lo, lane_dep_mz_hi;
				genvar gdb;
				for (gdb = 0; gdb < 5; gdb = gdb + 1) begin : g_dbuf

					assign lane_dep_m4_lo[gdb] = lane_dep[gdb];
					assign lane_dep_m4_hi[gdb] = lane_dep[gdb];
					assign lane_dep_mz_lo[gdb] = lane_dep[gdb];
					assign lane_dep_mz_hi[gdb] = lane_dep[gdb];

				end
				wire [7:0] w_m4_lo, w_m4_hi, w_mz_lo, w_mz_hi;
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(0), .CH_IDX(8 + gch)) u_m4_lo (
					.all_rdat(rdat), .l_idx(lane_dep_m4_lo),
					.byte_out(w_m4_lo)
				);
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(1), .CH_IDX(8 + gch)) u_m4_hi (
					.all_rdat(rdat), .l_idx(lane_dep_m4_hi),
					.byte_out(w_m4_hi)
				);
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(0), .CH_IDX(10 + gch)) u_mz_lo (
					.all_rdat(rdat), .l_idx(lane_dep_mz_lo),
					.byte_out(w_mz_lo)
				);
				atg_su_exp_ch_mux #(.NPHYS(NPHYS), .CH_W(192), .HI(1), .CH_IDX(10 + gch)) u_mz_hi (
					.all_rdat(rdat), .l_idx(lane_dep_mz_hi),
					.byte_out(w_mz_hi)
				);
				wire q_ddw_cur = (gch == 0) ? q_ddw_ch0 : q_ddw_ch1;
				assign dep[32 * gi + gch * 16 +: 8]      = q_ddw_cur ? w_m4_lo : w_mz_lo;
				assign dep[32 * gi + gch * 16 + 8 +: 8]  = q_ddw_cur ? w_m4_hi : w_mz_hi;
			end
		end
	endgenerate

	always @(*) begin
		ls = 8'd0;
		for (i = 0; i < 4; i = i + 1) begin
			ls = rsm[8 * (({27'd0, dl0} + i) % NPHYS) +: 8];
			zexp[i] = ddw[dl0 + i[4:0]];
`ifdef MUT_SMASK_AND
			smask[4 * i +: 4] = (dr6[dl0 + i[4:0]] ? ls[3:0] : 4'hF) &
				(dsm[dl0 + i[4:0]] ? ls[7:4] & ls[3:0] : 4'hF);
`else
			smask[4 * i +: 4] = (dr6[dl0 + i[4:0]] ? ls[3:0] : 4'hF) &
				(dsm[dl0 + i[4:0]] ? ls[7:4] : 4'hF);
`endif
			smok[i] = smask[4 * i +: 4] != 4'd0;
		end
	end

	wire [127:0] dsv_mux;
	genvar gds;
	generate
		for (gds = 0; gds < 8; gds = gds + 1) begin : g_dsv_sl
			wire [WARP_W-1:0] dw_sl;
			genvar gwb;
			for (gwb = 0; gwb < WARP_W; gwb = gwb + 1) begin : g_dw_buf

				assign dw_sl[gwb] = dwarp[gwb];

			end
			assign dsv_mux[gds * 16 +: 16] = dsv[{dw_sl, gds[2:0], 4'd0} +: 16];
		end
	endgenerate

	wire [WARP_W-1:0] dwarp_qx, dwarp_qy;
	wire [2:0] dq_qx, dq_qy;
	genvar gq_b;
	for (gq_b = 0; gq_b < WARP_W; gq_b = gq_b + 1) begin : g_dw_buf_xy

		assign dwarp_qx[gq_b] = dwarp[gq_b];
		assign dwarp_qy[gq_b] = dwarp[gq_b];

	end
	for (gq_b = 0; gq_b < 3; gq_b = gq_b + 1) begin : g_dq_buf_xy

		assign dq_qx[gq_b] = dq[gq_b];
		assign dq_qy[gq_b] = dq[gq_b];

	end
	wire [WARP_W+2:0] dqs_x = {dwarp_qx, dq_qx};
	wire [WARP_W+2:0] dqs_y = {dwarp_qy, dq_qy};
	assign x_ready = 1'b1;

	wire [15:0] qx_out, qy_out;
	genvar gq_sl;
	generate
		for (gq_sl = 0; gq_sl < 8; gq_sl = gq_sl + 1) begin : g_qx_mux
			wire [WARP_W+2:0] dqs_x_sl;
			wire [WARP_W+2:0] dqs_y_sl;
			genvar gb;
			for (gb = 0; gb < WARP_W+3; gb = gb + 1) begin : g_sel_buf

				assign dqs_x_sl[gb] = dqs_x[gb];
				assign dqs_y_sl[gb] = dqs_y[gb];

			end
			assign qx_out[gq_sl*2 +: 2] = qx[{dqs_x_sl, gq_sl[2:0], 1'b0} +: 2];
			assign qy_out[gq_sl*2 +: 2] = qy[{dqs_y_sl, gq_sl[2:0], 1'b0} +: 2];
		end
	endgenerate
	assign ex_xy = {qy_out, qx_out};
	assign ex_mask = dxp[dl0 +: 4] & smok;
`ifdef MUT_EXP_FRONT
	assign ex_aux = {drt, dlastb, dfirst, dnocol, 1'b1, dsv_mux,
		zexp & dxp[dl0 +: 4], smask};
`else
	assign ex_aux = {drt, dlastb, dfirst, dnocol, fr[dwarp], dsv_mux,
		zexp & dxp[dl0 +: 4], smask};
`endif
	assign ex_color = col;
	assign ex_color1 = col1;
	assign ex_has_src1 = (DUAL_SOURCE != 0) ? has_src1_w[dwarp] : 1'b0;
	assign ex_depth = dep;

	genvar gw, gq;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_w_ctrl
			wire rst_w = !rst_n;
			wire [23:0] w_ff_f_sh, w_ff_f_cmp;
			genvar gwf;
			for (gwf = 0; gwf < 24; gwf = gwf + 1) begin : g_wff_buf

				assign w_ff_f_sh[gwf]  = fl_data[8+gwf];
				assign w_ff_f_cmp[gwf] = fl_data[8+gwf];

			end
			wire [3:0] w_ff_f_exp;
			genvar gwe;
			for (gwe = 0; gwe < 4; gwe = gwe + 1) begin : g_wexp_buf

				assign w_ff_f_exp[gwe] = fl_data[8+15+gwe];

			end
			wire [3:0] w_ff_sh_raw;
			wire [3:0] w_ff_sh;
			genvar gsh;
			for (gsh = 0; gsh < 4; gsh = gsh + 1) begin : g_sh_buf

				assign w_ff_sh[gsh] = w_ff_sh_raw[gsh];

			end
			wire [15:0] w_ff_m;
			wire w_fs_bo_unused;
			wire w_unused_ok = &{1'b0, w_fs_bo_unused};
			am_sub #(.W(4)) u_w_ff_sh (.a(4'd14), .b(w_ff_f_exp), .bi(1'b0), .d(w_ff_sh_raw), .bo(w_fs_bo_unused));
			am_shift #(.W(16), .SW(4), .DIR(1)) u_w_ff_m (.a({1'b1, w_ff_f_sh[14:0]}), .amt(w_ff_sh), .left(1'b0), .arith(1'b0),
				.y(w_ff_m));
			wire [15:0] w_fx_floor =
				(w_ff_f_cmp[23] || w_ff_f_cmp[22:15] < 8'd127) ? 16'd0 :
				(w_ff_f_cmp[22:15] > 8'd142) ? 16'hFFFF : w_ff_m;

			wire [4:0] w_fl_lane_h0;
			wire [4:0] w_fl_lane_h1;
			wire [4:0] w_fl_lane_q;
			genvar gln;
			for (gln = 0; gln < 5; gln = gln + 1) begin : g_lane_buf

				assign w_fl_lane_h0[gln] = fl_lane[gln];
				assign w_fl_lane_h1[gln] = fl_lane[gln];
				assign w_fl_lane_q[gln]  = fl_lane[gln];

			end
			wire fl_slot_gw;

			assign fl_slot_gw = (fl_slot_gw_in == gw[WARP_W-1:0]);

			wire w_qx_en  = fl_we && (w_fl_lane_q[1:0] == 2'd0) && (fl_reg == 6'd4) && fl_slot_gw;
			wire w_qy_en  = fl_we && (w_fl_lane_q[1:0] == 2'd0) && (fl_reg == 6'd5) && fl_slot_gw;
			wire w_dsv_en = fl_pw_we && (fl_pw_addr[11:2] == 10'h3FE) && fl_slot_gw;
			wire w_warp_hit = (x_warp_ctrl == gw[WARP_W-1:0]);
			wire w_ex_op_w  = ex_op && w_warp_hit;
			wire w_ex_dep_w = ex_dep && w_warp_hit;
			wire w_ex_sm_w  = ex_sm && w_warp_hit;

			for (gq = 0; gq < 2; gq = gq + 1) begin : g_wh
				wire [4:0] wh_lane = (gq == 0) ? w_fl_lane_h0 : w_fl_lane_h1;
				wire xr_clr_wh  = (xr_valid && (xr_warp == gw[WARP_W-1:0]));
				wire cov_we_s   = fl_go && fl_slot_gw;
				wire xp_clr_s   = fl_go && fl_slot_gw;
				wire dw_clr_s   = fl_go && fl_slot_gw;
				wire smw_clr_s  = fl_go && fl_slot_gw;
				wire w_ex_op_s  = w_ex_op_w;
				wire w_ex_dep_s = w_ex_dep_w;
				wire w_ex_sm_s  = w_ex_sm_w;
				wire w_r6_we_s  = fl_we && (fl_reg == 6'd6) && fl_slot_gw && (wh_lane[4] == gq[0]);
				reg [15:0] r6w_sl, cov_sl, xp_sl, dw_sl, smw_sl;
				wire [15:0] side_w_sl;
				genvar gsw;
				for (gsw = 0; gsw < 16; gsw = gsw + 1) begin : g_sw_buf

					assign side_w_sl[gsw] = side_w[gq*16 + gsw];

				end
				integer ib;
				always @(posedge clk or posedge rst_w) begin
					if (rst_w) begin
						r6w_sl <= 16'd0;
						cov_sl <= 16'd0;
						xp_sl  <= 16'd0;
						dw_sl  <= 16'd0;
						smw_sl <= 16'd0;
					end else begin
						if (xr_clr_wh) begin
							r6w_sl <= 16'd0;
						end else if (w_r6_we_s) begin
							for (ib = 0; ib < 16; ib = ib + 1)
								if (wh_lane[3:0] == ib[3:0])
									r6w_sl[ib] <= 1'b1;
						end
						if (cov_we_s)
							cov_sl <= fl_info[gq*16 +: 16];
						if (xp_clr_s)
							xp_sl <= 16'd0;
						else if (w_ex_op_s)
							xp_sl <= xp_sl | side_w_sl;
						if (dw_clr_s)
							dw_sl <= 16'd0;
						else if (w_ex_dep_s)
							dw_sl <= dw_sl | side_w_sl;
						if (smw_clr_s)
							smw_sl <= 16'd0;
						else if (w_ex_sm_s)
							smw_sl <= smw_sl | side_w_sl;
					end
				end
				assign r6w[gw*32 + gq*16 +: 16] = r6w_sl;
				assign cov[gw*32 + gq*16 +: 16] = cov_sl;
				assign xp[gw*32 + gq*16 +: 16]  = xp_sl;
				assign dw[gw*32 + gq*16 +: 16]  = dw_sl;
				assign smw[gw*32 + gq*16 +: 16] = smw_sl;
			end
			for (gq = 0; gq < 8; gq = gq + 1) begin : g_wq
				wire xr_clr_wq = (xr_valid && (xr_warp == gw[WARP_W-1:0]));
				wire dsv_we_s  = w_dsv_en && (fl_pw_addr[1:0] == gq[2:1]);
				wire qx_we_s   = w_qx_en && (w_fl_lane_q[4:2] == gq[2:0]);
				wire qy_we_s   = w_qy_en && (w_fl_lane_q[4:2] == gq[2:0]);
				reg [15:0] dsv_sl, qx_sl, qy_sl;
				always @(posedge clk or posedge rst_w) begin
					if (rst_w) begin
						dsv_sl <= 16'd0;
						qx_sl  <= 16'd0;
						qy_sl  <= 16'd0;
					end else begin
						if (xr_clr_wq)
							dsv_sl <= 16'd0;
						else if (dsv_we_s)
							dsv_sl <= fl_pw_data[(gq[0] * 16) +: 16];
						if (qx_we_s)
							qx_sl <= w_fx_floor;
						if (qy_we_s)
							qy_sl <= w_fx_floor;
					end
				end
				assign dsv[gw*128 + gq*16 +: 16] = dsv_sl;
				assign qx[(gw*8 + gq)*16 +: 16]  = qx_sl;
				assign qy[(gw*8 + gq)*16 +: 16]  = qy_sl;
			end
		end
	endgenerate

	wire side_any = (side_cmp != {NPHYS{1'b0}});
	wire side_any_rtw0, side_any_rtw1, side_any_has1;
	wire ex_col_w0, ex_col_w1;

	assign side_any_rtw0 = side_any;
	assign side_any_rtw1 = side_any;
	assign side_any_has1 = side_any;
	assign ex_col_w0     = ex_col;
	assign ex_col_w1     = ex_col;


	wire rst_p = !rst_n;
	always @(posedge clk or posedge rst_p) begin
		if (rst_p) begin
			fr <= {NWARPS{1'b0}};
			rtw <= {(NWARPS*8){1'b0}};
		end else begin
			if (fl_go) begin
				fr[fl_slot_top] <= fl_info[48];
				rtw[fl_slot_top*8 +: 8] <= 8'd0;
			end
			if ((x_warp_rtw[1] ? ex_col_w1 : ex_col_w0) && (x_warp_rtw[1] ? side_any_rtw1 : side_any_rtw0))
				rtw[{x_warp_rtw, tk_rtw}] <= 1'b1;
		end
	end

	generate
		if (DUAL_SOURCE != 0) begin : g_has_src1_reg
			reg [NWARPS-1:0] has_src1_r;
			always @(posedge clk or posedge rst_p) begin
				if (rst_p) begin
					has_src1_r <= {NWARPS{1'b0}};
				end else begin
					if (fl_go)
						has_src1_r[fl_slot_top] <= 1'b0;
					if (ex_col1 && side_any_has1)
						has_src1_r[x_warp_rtw] <= 1'b1;
				end
			end
			assign has_src1_w = has_src1_r;
		end else begin : g_no_has_src1_reg
			assign has_src1_w = {NWARPS{1'b0}};
		end
	endgenerate

	/* ---- Unified Meshlet Primitive Export Sequencer */
	wire ex_mesh = r_x_valid && r_x_unit == ATG_UNIT_EXP && tgt == 32'h200;
	wire [7:0] mesh_k_prim = r_x_b[7:0];
	wire [7:0] mesh_k_vert = r_x_b[15:8];
	wire [9:0] mesh_pb_10 = 10'd512;
	wire [LDS_AW-1:0] mesh_k_pbase = {{(LDS_AW > 10 ? LDS_AW - 10 : 0){1'b0}}, mesh_pb_10[LDS_AW > 10 ? 9 : LDS_AW-1 : 0]};

	wire mesh_done_unused;

	wire [9:0] mesh_vb_10 = 10'd256;
	wire [LDS_AW-1:0] mesh_k_vbase = {{(LDS_AW > 10 ? LDS_AW - 10 : 0){1'b0}}, mesh_vb_10[LDS_AW > 10 ? 9 : LDS_AW-1 : 0]};

	generate
	if (HAS_MESH != 0) begin : g_mesh
		atg_su_exp_mesh #(.AW(LDS_AW), .DATA_W(32)) u_mesh (
			.clk(clk), .rst_n(rst_n),
			.kick_valid(ex_mesh),
			.kick_mesh_id(r_x_info[15:0]),
			.kick_prim_count(mesh_k_prim),
			.kick_vert_count(mesh_k_vert),
			.kick_prim_base(mesh_k_pbase),
			.kick_pos_base({LDS_AW{1'b0}}),
			.kick_var_base(mesh_k_vbase),
			.busy(mesh_busy),
			.done(mesh_done_unused),
			.lds_rd_en(mesh_lds_rd_en),
			.lds_rd_addr(mesh_lds_rd_addr),
			.lds_rd_data(mesh_lds_rd_data),
			.mesh_valid(mesh_valid),
			.mesh_ready(mesh_ready),
			.mesh_tri(mesh_tri),
			.mesh_last(mesh_last),
			.mesh_id(mesh_id)
		);
	end else begin : g_no_mesh
		assign mesh_busy = 1'b0;
		assign mesh_done_unused = 1'b0;
		assign mesh_lds_rd_en = 1'b0;
		assign mesh_lds_rd_addr = {LDS_AW{1'b0}};
		assign mesh_valid = 1'b0;
		assign mesh_tri = 702'd0;
		assign mesh_last = 1'b0;
		assign mesh_id = 16'd0;
		wire unused_no_mesh = &{1'b0, ex_mesh, mesh_k_prim, mesh_k_vert, mesh_k_pbase,
			mesh_k_vbase, mesh_ready, mesh_lds_rd_data};
	end
	endgenerate

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_c, x_mask[NPHYS-1:0], x_info[31:18],
		x_uop, fl_info[63:49], fl_data[7:0], tgt, xrow, lane0, zrow, drow, fq, dqs, mesh_done_unused,
		mesh_pb_10, mesh_vb_10};
endmodule

module atg_su_exp_ch_mux #(
	parameter NPHYS = 8,
	parameter CH_W = 192,
	parameter HI = 0,
	parameter integer CH_IDX = 0
) (
	input wire [NPHYS*CH_W-1:0] all_rdat,
	input wire [4:0] l_idx,
	output reg [7:0] byte_out
);
	localparam OFF = CH_IDX * 16 + (HI ? 8 : 0);
	integer k;
	always @(*) begin
		byte_out = 8'd0;
		for (k = 0; k < NPHYS; k = k + 1) begin
			if (l_idx[4:0] == k[4:0])
				byte_out = all_rdat[k * CH_W + OFF +: 8];
		end
	end
endmodule

`default_nettype wire
