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
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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
	output wire [153:0] ex_aux,	/* {rt, qlast, qfirst, nocol, front, d_s, zexp, smask} */
	/* Slot release (atg_su_sched) */
	output wire xr_valid,
	output wire [WARP_W-1:0] xr_warp,
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp,
	/* Session protection: clear the buffer */
	input wire scrub,
	output wire scrub_busy
);
`include "atg_su_uop.vh"

	localparam G = 32 / NPHYS;
	localparam ROWS = NWARPS * G;
	localparam RW = ROWS > 1 ? $clog2(ROWS) : 1;

	/* floor of a non-negative fp32 below 65536 (the pixel centre's x or y) */
	function [15:0] ffloor;
		input [23:0] f;	/* bits 31:8 of the fp32 */
		reg [15:0] m;
		begin
			m = {1'b1, f[14:0]};
			if (f[23] || f[22:15] < 8'd127)
				ffloor = 16'd0;
			else if (f[22:15] > 8'd142)
				ffloor = 16'hFFFF;
			else
				ffloor = m >> (8'd142 - f[22:15]);
		end
	endfunction

	/* ---- Per warp. */
	reg [NWARPS-1:0] fr;	/* the warp's facing (fl_info[48]) */
	reg [NWARPS*4-1:0] rtw;	/* the attachments exported */
	reg [NWARPS*32-1:0] cov, xp, dw;	/* coverage, exported lanes, depth written */
	reg [NWARPS*32-1:0] smw, r6w;	/* SAMPLE_MASK exported, r6 written by the RX */
	reg [NWARPS*128-1:0] dsv;	/* the warp's d_s */
	reg [NWARPS*8*16-1:0] qx, qy;

	/* ---- Exports of fragment warps: colour k component c at 0x100 + 16 k + c. */
	wire [31:0] tgt = x_uop[ATG_UOP_IMM +: 32];
	wire ex_frag = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && x_info[17:16] == 2'd1;
	wire ex_col = ex_frag && tgt[31:6] == 26'd4 && tgt[3:2] == 2'd0;
	wire ex_dep = ex_frag && tgt == 32'h104;
	wire ex_sm = ex_frag && tgt == 32'h105;
	wire ex_op = ex_col || ex_dep || ex_sm;
	wire [1:0] tk = tgt[5:4];
	wire [1:0] comp = tgt[1:0];
	wire [31:0] xrow = {{(32-WARP_W){1'b0}}, x_warp} * G + {{(32-GRP_W){1'b0}}, x_grp};
	wire [NPHYS-1:0] side = x_mask[2*NPHYS-1:NPHYS];
	wire [31:0] lane0 = {{(32-GRP_W){1'b0}}, x_grp} * NPHYS;
	wire [31:0] side_w = {{(32-NPHYS){1'b0}}, side} << lane0[4:0];
	wire [31:0] zrow = {{(32-WARP_W){1'b0}}, fl_slot} * G + {27'd0, fl_lane} / NPHYS;
	wire [31:0] zbank = {27'd0, fl_lane} % NPHYS;
	wire [31:0] fq = ({{(32-WARP_W){1'b0}}, fl_slot} * 8 + {29'd0, fl_lane[4:2]}) * 16;
	wire [15:0] fx = ffloor(fl_data[31:8]);

	/* ---- The drain (atg_su_exp_drain): the beat of warp dwarp, quad dq, attachment drt. */
	wire [WARP_W-1:0] dwarp;
	wire [2:0] dq;
	wire [1:0] drt;
	wire dfirst, dlastb, dnocol;
	wire [31:0] dcov = cov[dwarp*32 +: 32];
	atg_su_exp_drain #(.NWARPS(NWARPS), .WARP_W(WARP_W)) drain (
		.clk(clk), .rst_n(rst_n), .fl_go(fl_go), .fl_slot(fl_slot), .fl_seq(fl_info[47:32]),
		.wc_end(wc_end), .wc_warp(wc_warp), .d_cov(dcov), .d_rtw(rtw[dwarp*4 +: 4]),
		.d_warp(dwarp), .d_q(dq), .d_rt(drt), .d_first(dfirst), .d_lastb(dlastb),
		.d_nocol(dnocol), .ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq),
		.ex_last(ex_last), .ex_next(ex_next), .xr_valid(xr_valid), .xr_warp(xr_warp)
	);

	wire [4:0] dl0 = {dq, 2'b00};
	wire [31:0] drow = {{(32-WARP_W){1'b0}}, dwarp} * G + {27'd0, dl0} / NPHYS;
	wire [RW+1:0] dcrow = {drow[RW-1:0], drt};
	wire [RW+1:0] xcrow = {xrow[RW-1:0], tk};
	wire [31:0] dqs = ({{(32-WARP_W){1'b0}}, dwarp} * 8 + {29'd0, dq}) * 16;
	wire [31:0] dxp = xp[dwarp*32 +: 32] & dcov;
	wire [31:0] ddw = dw[dwarp*32 +: 32];
	wire [31:0] dsm = smw[dwarp*32 +: 32];
	wire [31:0] dr6 = r6w[dwarp*32 +: 32];

	/* The scrub: rows of the attachments' arrays; the others take its row / 4. */
	wire sc_on;
	wire [RW+1:0] sc_a;

	atg_su_scrub #(.DEPTH(ROWS * 4), .AW(RW + 2)) sc (
		.clk(clk), .rst_n(rst_n), .start(scrub), .on(sc_on), .a(sc_a)
	);

	assign scrub_busy = sc_on;
	wire [RW+1:0] c_wa = sc_on ? sc_a : xcrow;
	wire [RW-1:0] r_wa = sc_on ? sc_a[RW+1:2] : xrow[RW-1:0];
	wire [RW-1:0] z_wa = sc_on ? sc_a[RW+1:2] : zrow[RW-1:0];

	/* NPHYS lane banks × {R, G, B, A of 4 attachments, depth, z} and {SAMPLE_MASK, r6}. */
	wire [NPHYS*192-1:0] rdat;
	wire [NPHYS*8-1:0] rsm;
	genvar b;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		reg [31:0] m0 [0:ROWS*4-1];
		reg [31:0] m1 [0:ROWS*4-1];
		reg [31:0] m2 [0:ROWS*4-1];
		reg [31:0] m3 [0:ROWS*4-1];
		reg [31:0] m4 [0:ROWS-1];
		reg [31:0] mz [0:ROWS-1];
		reg [3:0] m5 [0:ROWS-1];
		reg [3:0] mr6 [0:ROWS-1];
		wire [31:0] d = sc_on ? 32'd0 : x_b[32 * b +: 32];
		wire [31:0] fd = sc_on ? 32'd0 : fl_data;
		wire we = side[b];
		always @(posedge clk) begin
			if (sc_on || we && ex_col && comp == 2'd0) m0[c_wa] <= d;
			if (sc_on || we && ex_col && comp == 2'd1) m1[c_wa] <= d;
			if (sc_on || we && ex_col && comp == 2'd2) m2[c_wa] <= d;
			if (sc_on || we && ex_col && comp == 2'd3) m3[c_wa] <= d;
			if (sc_on || we && ex_dep) m4[r_wa] <= d;
			if (sc_on || we && ex_sm) m5[r_wa] <= d[3:0];
			if (sc_on || fl_we && fl_reg == 6'd3 && zbank == b)
				mz[z_wa] <= fd;
			if (sc_on || fl_we && fl_reg == 6'd6 && zbank == b)
				mr6[z_wa] <= fd[3:0];
		end
		assign rsm[8 * b +: 8] = {m5[drow[RW-1:0]], mr6[drow[RW-1:0]]};
		assign rdat[192 * b +: 192] = {mz[drow[RW-1:0]], m4[drow[RW-1:0]],
			m3[dcrow], m2[dcrow], m1[dcrow], m0[dcrow]};
	end
	endgenerate

	/* The quad's lanes i = 0..3 are lanes 4 dq + i, banks (4 dq + i) mod NPHYS. */
	reg [511:0] col;
	reg [127:0] dep;
	reg [191:0] lw;
	reg [7:0] ls;
	reg [15:0] smask;
	reg [3:0] zexp;
	reg [3:0] smok;
	integer i;
	always @(*) begin
		lw = 192'd0;
		ls = 8'd0;
		for (i = 0; i < 4; i = i + 1) begin
			lw = rdat[192 * (({27'd0, dl0} + i) % NPHYS) +: 192];
			ls = rsm[8 * (({27'd0, dl0} + i) % NPHYS) +: 8];
			col[128 * i +: 128] = lw[127:0];
			dep[32 * i +: 32] = ddw[dl0 + i[4:0]] ? lw[159:128] : lw[191:160];
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

	assign x_ready = 1'b1;
	assign ex_xy = {qy[dqs +: 16], qx[dqs +: 16]};
	assign ex_mask = dxp[dl0 +: 4] & smok;
`ifdef MUT_EXP_FRONT
	assign ex_aux = {drt, dlastb, dfirst, dnocol, 1'b1, dsv[dwarp*128 +: 128],
		zexp & dxp[dl0 +: 4], smask};
`else
	assign ex_aux = {drt, dlastb, dfirst, dnocol, fr[dwarp], dsv[dwarp*128 +: 128],
		zexp & dxp[dl0 +: 4], smask};
`endif
	assign ex_color = col;
	assign ex_depth = dep;

	always @(posedge clk) begin
		if (!rst_n) begin
			r6w <= {(NWARPS*32){1'b0}};
			dsv <= {(NWARPS*128){1'b0}};
		end else begin
			/* The RX's r6 and d_s of the warp being built; cleared at a release. */
			if (fl_we && fl_reg == 6'd6)
				r6w[fl_slot*32 + {27'd0, fl_lane}] <= 1'b1;
			if (fl_pw_we && fl_pw_addr[11:2] == 10'h3FE)
				dsv[fl_slot*128 + {fl_pw_addr[1:0], 5'd0} +: 32] <= fl_pw_data;
			if (xr_valid) begin
				r6w[xr_warp*32 +: 32] <= 32'd0;
				dsv[xr_warp*128 +: 128] <= 128'd0;
			end
		end
		if (fl_go) begin
			fr[fl_slot] <= fl_info[48];
			rtw[fl_slot*4 +: 4] <= 4'd0;
			cov[fl_slot*32 +: 32] <= fl_info[31:0];
			xp[fl_slot*32 +: 32] <= 32'd0;
			dw[fl_slot*32 +: 32] <= 32'd0;
			smw[fl_slot*32 +: 32] <= 32'd0;
		end
		if (fl_we && fl_lane[1:0] == 2'd0 && fl_reg == 6'd4)
			qx[fq +: 16] <= fx;
		if (fl_we && fl_lane[1:0] == 2'd0 && fl_reg == 6'd5)
			qy[fq +: 16] <= fx;
		if (ex_op) begin
			xp[x_warp*32 +: 32] <= xp[x_warp*32 +: 32] | side_w;
			if (ex_col && side != {NPHYS{1'b0}})
				rtw[x_warp*4 + {30'd0, tk}] <= 1'b1;
			if (ex_dep)
				dw[x_warp*32 +: 32] <= dw[x_warp*32 +: 32] | side_w;
			if (ex_sm)
				smw[x_warp*32 +: 32] <= smw[x_warp*32 +: 32] | side_w;
		end
	end

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_c, x_mask[NPHYS-1:0], x_info,
		x_uop, fl_info[63:49], fl_data[7:0], tgt, xrow, lane0, zrow, drow, fq, dqs};
endmodule

`default_nettype wire
