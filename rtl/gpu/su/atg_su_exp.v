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
	parameter LDS_AW = $clog2(LDS_BYTES / 4)
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

	localparam G = 32 / NPHYS;
	localparam ROWS = NWARPS * G;
	localparam RW = ROWS > 1 ? $clog2(ROWS) : 1;
	localparam G_W = $clog2(G);	/* G is a power of two: warp G + group are disjoint bits */

	/* ---- Per warp. */
	reg [NWARPS-1:0] fr;	/* the warp's facing (fl_info[48]) */
	reg [NWARPS*8-1:0] rtw;	/* the attachments exported (8 attachments) */
	reg [NWARPS-1:0] has_src1;	/* whether the warp exported src1 (COLOR1) */
	wire [NWARPS*32-1:0] cov, xp, dw;	/* coverage, exported lanes, depth written */
	wire [NWARPS*32-1:0] smw, r6w;	/* SAMPLE_MASK exported, r6 written by the RX */
	wire [NWARPS*128-1:0] dsv;	/* the warp's d_s */
	wire [NWARPS*8*16-1:0] qx, qy;

	/* ---- Exports of fragment warps: colour k component c at 0x100 + 16 k + c;
	 * 0x108 + c is the second colour (src1) of attachment 0 for dual-source blending. */
	wire [31:0] tgt = x_uop[ATG_UOP_IMM +: 32];
	wire ex_frag = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && x_info[17:16] == 2'd1;
	(* keep = "true", max_fanout = 12 *) wire ex_col  = ex_frag && tgt[31:7] == 25'd2 && tgt[3:2] == 2'd0;
	(* keep = "true", max_fanout = 12 *) wire ex_col1 = ex_frag && tgt[31:4] == 28'h010 && tgt[3:2] == 2'b10;
	(* keep = "true", max_fanout = 12 *) wire ex_dep  = ex_frag && tgt == 32'h104;
	(* keep = "true", max_fanout = 12 *) wire ex_sm   = ex_frag && tgt == 32'h105;
	(* keep = "true", max_fanout = 12 *) wire ex_op   = ex_col || ex_dep || ex_sm;
	wire [2:0] tk = tgt[6:4];
	wire [1:0] comp = tgt[1:0];
	wire [31:0] xrow = ({{(32-WARP_W){1'b0}}, x_warp} << G_W) | ({{(32-GRP_W){1'b0}}, x_grp} % G);
	wire [NPHYS-1:0] side = x_mask[2*NPHYS-1:NPHYS];
	wire [31:0] lane0 = {{(32-GRP_W){1'b0}}, x_grp} * NPHYS;
	wire [31:0] side_w;
	am_shift #(.W(32), .SW(5)) u_side_w (.a({{(32-NPHYS){1'b0}}, side}), .amt(lane0[4:0]), .left(1'b1),
		.arith(1'b0), .y(side_w));
	(* dont_touch = "true" *) wire [4:0] fl_lane_z = fl_lane;
	wire [31:0] zrow = ({{(32-WARP_W){1'b0}}, fl_slot} << G_W) | ({27'd0, fl_lane_z} / NPHYS);
	wire [31:0] zbank = {27'd0, fl_lane_z} % NPHYS;
	wire [31:0] fq = {{(25-WARP_W){1'b0}}, fl_slot, fl_lane_z[4:2], 4'd0};

	/* ---- The drain (atg_su_exp_drain): the beat of warp dwarp, quad dq, attachment drt. */
	wire [WARP_W-1:0] dwarp;
	wire [2:0] dq;
	wire [2:0] drt;
	wire dfirst, dlastb, dnocol;
	wire [31:0] dcov, dxp_raw, ddw, dsm, dr6;
	genvar gwm;
	generate
		for (gwm = 0; gwm < 2; gwm = gwm + 1) begin : g_wmux_sl
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_cov_s = dwarp;
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_xp_s  = dwarp;
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_dw_s  = dwarp;
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_sm_s  = dwarp;
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_r6_s  = dwarp;
			assign dcov[gwm*16 +: 16]    = cov[dw_cov_s*32 + gwm*16 +: 16];
			assign dxp_raw[gwm*16 +: 16] = xp[dw_xp_s*32 + gwm*16 +: 16];
			assign ddw[gwm*16 +: 16]     = dw[dw_dw_s*32 + gwm*16 +: 16];
			assign dsm[gwm*16 +: 16]     = smw[dw_sm_s*32 + gwm*16 +: 16];
			assign dr6[gwm*16 +: 16]     = r6w[dw_r6_s*32 + gwm*16 +: 16];
		end
	endgenerate
	(* dont_touch = "true" *) wire [WARP_W-1:0] dw_rtw = dwarp;
	atg_su_exp_drain #(.NWARPS(NWARPS), .WARP_W(WARP_W)) drain (
		.clk(clk), .rst_n(rst_n), .fl_go(fl_go), .fl_slot(fl_slot), .fl_seq(fl_info[47:32]),
		.wc_end(wc_end), .wc_warp(wc_warp), .d_cov(dcov), .d_rtw(rtw[dw_rtw*8 +: 8]),
		.d_warp(dwarp), .d_q(dq), .d_rt(drt), .d_first(dfirst), .d_lastb(dlastb),
		.d_nocol(dnocol), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq),
		.ex_last(ex_last), .ex_next(ex_next), .xr_valid(xr_valid), .xr_warp(xr_warp)
	);

	wire [4:0] dl0 = {dq, 2'b00};
	wire [31:0] drow = {{(32-WARP_W){1'b0}}, dwarp} * G + {27'd0, dl0} / NPHYS;
	wire [RW+2:0] dcrow = {drow[RW-1:0], drt};
	wire [RW+2:0] xcrow = {xrow[RW-1:0], tk};
	wire [31:0] dqs = ({{(32-WARP_W){1'b0}}, dwarp} * 8 + {29'd0, dq}) * 16;
	wire [31:0] dxp = dxp_raw & dcov;

	/* The scrub: rows of the attachments' arrays; the others take its row / 4. */
	wire sc_on;
	wire [RW+2:0] sc_a;

	atg_su_scrub #(.DEPTH(ROWS * 8), .AW(RW + 3)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	assign scrub_busy = sc_on;

	/* NPHYS lane banks × {R, G, B, A of 8 attachments, depth, z} and {SAMPLE_MASK, r6}. */
	wire [NPHYS*192-1:0] rdat;
	wire [NPHYS*128-1:0] rdat1;
	wire [NPHYS*8-1:0] rsm;
	genvar b, bs, bh;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		(* dont_touch = "true" *) wire b_sc_on_c0   = sc_on;
		(* dont_touch = "true" *) wire b_sc_on_c1   = sc_on;
		(* dont_touch = "true" *) wire b_sc_on_r0   = sc_on;
		(* dont_touch = "true" *) wire b_sc_on_r1   = sc_on;
		(* dont_touch = "true" *) wire [RW+2:0] b_sc_a_c0  = sc_a;
		(* dont_touch = "true" *) wire [RW+2:0] b_sc_a_c1  = sc_a;
		(* dont_touch = "true" *) wire [RW-1:0] b_sc_ar_0  = sc_a[RW+2:3];
		(* dont_touch = "true" *) wire [RW-1:0] b_sc_ar_1  = sc_a[RW+2:3];
		(* dont_touch = "true" *) wire [RW+2:0] b_xcrow_0  = xcrow;
		(* dont_touch = "true" *) wire [RW+2:0] b_xcrow_1  = xcrow;
		(* dont_touch = "true" *) wire [RW-1:0] b_xrow_0   = xrow[RW-1:0];
		(* dont_touch = "true" *) wire [RW-1:0] b_xrow_1   = xrow[RW-1:0];
		(* dont_touch = "true" *) wire [RW-1:0] b_zrow     = zrow[RW-1:0];
		(* dont_touch = "true" *) wire [RW+2:0] b_dcrow_0  = dcrow;
		(* dont_touch = "true" *) wire [RW+2:0] b_dcrow_1  = dcrow;
		(* dont_touch = "true" *) wire [RW-1:0] b_drow_0   = drow[RW-1:0];
		(* dont_touch = "true" *) wire [RW-1:0] b_drow_1   = drow[RW-1:0];
		(* dont_touch = "true" *) wire b_we_0 = b_sc_on_c0 || (side[b] && ex_col && comp == 2'd0);
		(* dont_touch = "true" *) wire b_we_1 = b_sc_on_c0 || (side[b] && ex_col && comp == 2'd1);
		(* dont_touch = "true" *) wire b_we_2 = b_sc_on_c1 || (side[b] && ex_col && comp == 2'd2);
		(* dont_touch = "true" *) wire b_we_3 = b_sc_on_c1 || (side[b] && ex_col && comp == 2'd3);
		(* dont_touch = "true" *) wire b_we_s0 = b_sc_on_r0 || (side[b] && ex_col1 && comp == 2'd0);
		(* dont_touch = "true" *) wire b_we_s1 = b_sc_on_r0 || (side[b] && ex_col1 && comp == 2'd1);
		(* dont_touch = "true" *) wire b_we_s2 = b_sc_on_r1 || (side[b] && ex_col1 && comp == 2'd2);
		(* dont_touch = "true" *) wire b_we_s3 = b_sc_on_r1 || (side[b] && ex_col1 && comp == 2'd3);
		(* dont_touch = "true" *) wire b_we_m4 = b_sc_on_r0 || (side[b] && ex_dep);
		(* dont_touch = "true" *) wire b_we_mz = b_sc_on_r1 || (fl_we && fl_reg == 6'd3 && zbank == b);

		(* dont_touch = "true" *) wire [RW-1:0] r_wa_m5  = b_sc_on_r1 ? b_sc_ar_1 : b_xrow_1;
		(* dont_touch = "true" *) wire [RW-1:0] z_wa_mr6 = b_sc_on_r1 ? b_sc_ar_1 : b_zrow;
		(* dont_touch = "true" *) wire [RW-1:0] drow_rsm = b_drow_1;
		(* dont_touch = "true" *) wire we_m5 = b_sc_on_r1 || (side[b] && ex_sm);
		(* dont_touch = "true" *) wire we_mr6 = b_sc_on_r1 || (fl_we && fl_reg == 6'd6 && zbank == b);
		(* dont_touch = "true" *) wire [3:0] d_m5 = b_sc_on_r1 ? 4'd0 : x_b[32 * b +: 4];
		(* dont_touch = "true" *) wire [3:0] fd_mr6 = b_sc_on_r1 ? 4'd0 : fl_data[3:0];

		reg [3:0] m5 [0:ROWS-1];
		reg [3:0] mr6 [0:ROWS-1];
		always @(posedge clk) begin
			if (we_m5) m5[r_wa_m5] <= d_m5;
			if (we_mr6) mr6[z_wa_mr6] <= fd_mr6;
		end
		assign rsm[8 * b +: 8] = {m5[drow_rsm], mr6[drow_rsm]};

		for (bs = 0; bs < 8; bs = bs + 1) begin : g_col_sl
			wire b_scon = (bs < 4) ? b_sc_on_c0 : b_sc_on_c1;
			wire [RW+2:0] b_sca = (bs < 4) ? b_sc_a_c0 : b_sc_a_c1;
			wire [RW+2:0] b_xcr = (bs < 4) ? b_xcrow_0 : b_xcrow_1;
			wire [RW+2:0] b_dcr = (bs < 4) ? b_dcrow_0 : b_dcrow_1;
			(* dont_touch = "true" *) wire [RW+2:0] c_wa_0 = b_scon ? b_sca : b_xcr;
			(* dont_touch = "true" *) wire [RW+2:0] c_wa_1 = b_scon ? b_sca : b_xcr;
			(* dont_touch = "true" *) wire [RW+2:0] c_wa_2 = b_scon ? b_sca : b_xcr;
			(* dont_touch = "true" *) wire [RW+2:0] c_wa_3 = b_scon ? b_sca : b_xcr;
			(* dont_touch = "true" *) wire [RW+2:0] dcrow_01 = b_dcr;
			(* dont_touch = "true" *) wire [RW+2:0] dcrow_23 = b_dcr;
			(* dont_touch = "true" *) wire we_0 = b_we_0;
			(* dont_touch = "true" *) wire we_1 = b_we_1;
			(* dont_touch = "true" *) wire we_2 = b_we_2;
			(* dont_touch = "true" *) wire we_3 = b_we_3;
			(* dont_touch = "true" *) wire [3:0] d_sl = b_scon ? 4'd0 : x_b[32 * b + bs * 4 +: 4];

			reg [3:0] m0 [0:ROWS*8-1];
			reg [3:0] m1 [0:ROWS*8-1];
			reg [3:0] m2 [0:ROWS*8-1];
			reg [3:0] m3 [0:ROWS*8-1];
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
			wire b_scon = (bh < 2) ? b_sc_on_r0 : b_sc_on_r1;
			wire [RW-1:0] b_scar = (bh < 2) ? b_sc_ar_0 : b_sc_ar_1;
			wire [RW-1:0] b_xr   = (bh < 2) ? b_xrow_0  : b_xrow_1;
			wire [RW-1:0] b_dr   = (bh < 2) ? b_drow_0  : b_drow_1;
			(* dont_touch = "true" *) wire [RW-1:0] r_wa_s0 = b_scon ? b_scar : b_xr;
			(* dont_touch = "true" *) wire [RW-1:0] r_wa_s1 = b_scon ? b_scar : b_xr;
			(* dont_touch = "true" *) wire [RW-1:0] r_wa_s2 = b_scon ? b_scar : b_xr;
			(* dont_touch = "true" *) wire [RW-1:0] r_wa_s3 = b_scon ? b_scar : b_xr;
			(* dont_touch = "true" *) wire [RW-1:0] r_wa_m4 = b_scon ? b_scar : b_xr;
			(* dont_touch = "true" *) wire [RW-1:0] z_wa_mz = b_scon ? b_scar : b_zrow;
			(* dont_touch = "true" *) wire [RW-1:0] drow_s01 = b_dr;
			(* dont_touch = "true" *) wire [RW-1:0] drow_s23 = b_dr;
			(* dont_touch = "true" *) wire [RW-1:0] drow_m4z = b_dr;
			(* dont_touch = "true" *) wire we_s0 = b_we_s0;
			(* dont_touch = "true" *) wire we_s1 = b_we_s1;
			(* dont_touch = "true" *) wire we_s2 = b_we_s2;
			(* dont_touch = "true" *) wire we_s3 = b_we_s3;
			(* dont_touch = "true" *) wire we_m4 = b_we_m4;
			(* dont_touch = "true" *) wire we_mz = b_we_mz;
			(* dont_touch = "true" *) wire [7:0] d_h = b_scon ? 8'd0 : x_b[32 * b + bh * 8 +: 8];
			(* dont_touch = "true" *) wire [7:0] fd_h = b_scon ? 8'd0 : fl_data[bh * 8 +: 8];

			reg [7:0] ms1_0 [0:ROWS-1];
			reg [7:0] ms1_1 [0:ROWS-1];
			reg [7:0] ms1_2 [0:ROWS-1];
			reg [7:0] ms1_3 [0:ROWS-1];
			reg [7:0] m4 [0:ROWS-1];
			reg [7:0] mz [0:ROWS-1];
			always @(posedge clk) begin
				if (we_s0) ms1_0[r_wa_s0] <= d_h;
				if (we_s1) ms1_1[r_wa_s1] <= d_h;
				if (we_s2) ms1_2[r_wa_s2] <= d_h;
				if (we_s3) ms1_3[r_wa_s3] <= d_h;
				if (we_m4) m4[r_wa_m4] <= d_h;
				if (we_mz) mz[z_wa_mz] <= fd_h;
			end
			assign rdat1[128 * b + 0  + bh * 8 +: 8] = ms1_0[drow_s01];
			assign rdat1[128 * b + 32 + bh * 8 +: 8] = ms1_1[drow_s01];
			assign rdat1[128 * b + 64 + bh * 8 +: 8] = ms1_2[drow_s23];
			assign rdat1[128 * b + 96 + bh * 8 +: 8] = ms1_3[drow_s23];
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
			for (gch = 0; gch < 8; gch = gch + 1) begin : g_c_sl
				(* dont_touch = "true" *) wire [2:0] dq_c  = dq;
				(* dont_touch = "true" *) wire [2:0] dq_c1 = dq;
				assign col[128 * gi + gch * 16 +: 16]  = rdat[192 * (({27'd0, dq_c,  gi[1:0]}) % NPHYS) + gch * 16 +: 16];
				assign col1[128 * gi + gch * 16 +: 16] = rdat1[128 * (({27'd0, dq_c1, gi[1:0]}) % NPHYS) + gch * 16 +: 16];
			end
			for (gch = 0; gch < 2; gch = gch + 1) begin : g_d_sl
				(* dont_touch = "true" *) wire [2:0] dq_d = dq;
				(* dont_touch = "true" *) wire q_ddw = ddw[{dq_d, gi[1:0]}];
				wire [15:0] w_m4 = rdat[192 * (({27'd0, dq_d, gi[1:0]}) % NPHYS) + 128 + gch * 16 +: 16];
				wire [15:0] w_mz = rdat[192 * (({27'd0, dq_d, gi[1:0]}) % NPHYS) + 160 + gch * 16 +: 16];
				assign dep[32 * gi + gch * 16 +: 16] = q_ddw ? w_m4 : w_mz;
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
			(* dont_touch = "true" *) wire [WARP_W-1:0] dw_sl = dwarp;
			assign dsv_mux[gds * 16 +: 16] = dsv[{dw_sl, gds[2:0], 4'd0} +: 16];
		end
	endgenerate

	(* dont_touch = "true" *) wire [WARP_W+2:0] dqs_x = {dwarp, dq};
	(* dont_touch = "true" *) wire [WARP_W+2:0] dqs_y = {dwarp, dq};
	assign x_ready = 1'b1;
	assign ex_xy = {qy[{dqs_y, 4'd0} +: 16], qx[{dqs_x, 4'd0} +: 16]};
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
	assign ex_has_src1 = has_src1[dwarp];
	assign ex_depth = dep;

	genvar gw, gq;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_w_ctrl
			(* dont_touch = "true" *) wire rst_w = !rst_n;
			(* dont_touch = "true" *) wire [23:0] w_ff_f = fl_data[31:8];
			wire [3:0] w_ff_sh;
			wire [15:0] w_ff_m;
			wire w_fs_bo_unused;
			wire w_unused_ok = &{1'b0, w_fs_bo_unused};
			am_sub #(.W(4)) u_w_ff_sh (.a(4'd14), .b(w_ff_f[18:15]), .bi(1'b0), .d(w_ff_sh), .bo(w_fs_bo_unused));
			am_shift #(.W(16), .SW(4)) u_w_ff_m (.a({1'b1, w_ff_f[14:0]}), .amt(w_ff_sh), .left(1'b0), .arith(1'b0),
				.y(w_ff_m));
			(* dont_touch = "true" *) wire [15:0] w_fx_floor =
				(w_ff_f[23] || w_ff_f[22:15] < 8'd127) ? 16'd0 :
				(w_ff_f[22:15] > 8'd142) ? 16'hFFFF : w_ff_m;

			(* dont_touch = "true" *) wire [4:0] w_fl_lane_h0 = fl_lane;
			(* dont_touch = "true" *) wire [4:0] w_fl_lane_h1 = fl_lane;
			(* dont_touch = "true" *) wire [4:0] w_fl_lane_q  = fl_lane;
			(* dont_touch = "true" *) wire w_qx_en  = fl_we && (w_fl_lane_q[1:0] == 2'd0) && (fl_reg == 6'd4) && (fl_slot == gw[WARP_W-1:0]);
			(* dont_touch = "true" *) wire w_qy_en  = fl_we && (w_fl_lane_q[1:0] == 2'd0) && (fl_reg == 6'd5) && (fl_slot == gw[WARP_W-1:0]);
			(* dont_touch = "true" *) wire w_dsv_en = fl_pw_we && (fl_pw_addr[11:2] == 10'h3FE) && (fl_slot == gw[WARP_W-1:0]);

			for (gq = 0; gq < 2; gq = gq + 1) begin : g_wh
				wire [4:0] wh_lane = (gq == 0) ? w_fl_lane_h0 : w_fl_lane_h1;
				(* dont_touch = "true" *) wire rst_wh     = rst_w || (xr_valid && (xr_warp == gw[WARP_W-1:0]));
				(* dont_touch = "true" *) wire cov_we_s   = fl_go && (fl_slot == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire xp_clr_s   = fl_go && (fl_slot == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire dw_clr_s   = fl_go && (fl_slot == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire smw_clr_s  = fl_go && (fl_slot == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire w_ex_op_s  = ex_op && (x_warp == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire w_ex_dep_s = ex_op && ex_dep && (x_warp == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire w_ex_sm_s  = ex_op && ex_sm && (x_warp == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire w_r6_we_s  = fl_we && (fl_reg == 6'd6) && (fl_slot == gw[WARP_W-1:0]) && (wh_lane[4] == gq[0]);
				reg [15:0] r6w_sl, cov_sl, xp_sl, dw_sl, smw_sl;
				integer ib;
				always @(posedge clk) begin
					if (rst_wh) begin
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
						xp_sl <= xp_sl | side_w[gq*16 +: 16];
					if (dw_clr_s)
						dw_sl <= 16'd0;
					else if (w_ex_dep_s)
						dw_sl <= dw_sl | side_w[gq*16 +: 16];
					if (smw_clr_s)
						smw_sl <= 16'd0;
					else if (w_ex_sm_s)
						smw_sl <= smw_sl | side_w[gq*16 +: 16];
				end
				assign r6w[gw*32 + gq*16 +: 16] = r6w_sl;
				assign cov[gw*32 + gq*16 +: 16] = cov_sl;
				assign xp[gw*32 + gq*16 +: 16]  = xp_sl;
				assign dw[gw*32 + gq*16 +: 16]  = dw_sl;
				assign smw[gw*32 + gq*16 +: 16] = smw_sl;
			end
			for (gq = 0; gq < 8; gq = gq + 1) begin : g_wq
				(* dont_touch = "true" *) wire rst_wq   = rst_w || (xr_valid && (xr_warp == gw[WARP_W-1:0]));
				(* dont_touch = "true" *) wire dsv_we_s = w_dsv_en && (fl_pw_addr[1:0] == gq[2:1]);
				(* dont_touch = "true" *) wire qx_we_s  = w_qx_en && (w_fl_lane_q[4:2] == gq[2:0]);
				(* dont_touch = "true" *) wire qy_we_s  = w_qy_en && (w_fl_lane_q[4:2] == gq[2:0]);
				reg [15:0] dsv_sl, qx_sl, qy_sl;
				always @(posedge clk) begin
					if (rst_wq)
						dsv_sl <= 16'd0;
					else if (dsv_we_s)
						dsv_sl <= fl_pw_data[(gq[0] * 16) +: 16];
					if (qx_we_s)
						qx_sl <= w_fx_floor;
					if (qy_we_s)
						qy_sl <= w_fx_floor;
				end
				assign dsv[gw*128 + gq*16 +: 16] = dsv_sl;
				assign qx[(gw*8 + gq)*16 +: 16]  = qx_sl;
				assign qy[(gw*8 + gq)*16 +: 16]  = qy_sl;
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (fl_go) begin
			fr[fl_slot] <= fl_info[48];
			rtw[fl_slot*8 +: 8] <= 8'd0;
			has_src1[fl_slot] <= 1'b0;
		end
		if (ex_op && ex_col && side != {NPHYS{1'b0}})
			rtw[{x_warp, tk}] <= 1'b1;
		if (ex_col1 && side != {NPHYS{1'b0}})
			has_src1[x_warp] <= 1'b1;
	end

	/* ---- Unified Meshlet Primitive Export Sequencer */
	wire ex_mesh = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && tgt == 32'h200;
	wire [7:0] mesh_k_prim = x_b[7:0];
	wire [7:0] mesh_k_vert = x_b[15:8];
	wire [9:0] mesh_pb_10 = 10'd512;
	wire [LDS_AW-1:0] mesh_k_pbase = {{(LDS_AW > 10 ? LDS_AW - 10 : 0){1'b0}}, mesh_pb_10[LDS_AW > 10 ? 9 : LDS_AW-1 : 0]};

	wire mesh_done_unused;

	wire [9:0] mesh_vb_10 = 10'd256;
	wire [LDS_AW-1:0] mesh_k_vbase = {{(LDS_AW > 10 ? LDS_AW - 10 : 0){1'b0}}, mesh_vb_10[LDS_AW > 10 ? 9 : LDS_AW-1 : 0]};

	atg_su_exp_mesh #(.AW(LDS_AW), .DATA_W(32)) u_mesh (
		.clk(clk), .rst_n(rst_n),
		.kick_valid(ex_mesh),
		.kick_mesh_id(x_info[15:0]),
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

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_c, x_mask[NPHYS-1:0], x_info,
		x_uop, fl_info[63:49], fl_data[7:0], tgt, xrow, lane0, zrow, drow, fq, dqs, mesh_done_unused,
		mesh_pb_10, mesh_vb_10};
endmodule

`default_nettype wire
