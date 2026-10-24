/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exp: the fragment export buffer: exp of COLOR0 (0x100-0x103) and
 * DEPTH (0x104) by fragment warps into the warp's buffer, drained to the
 * ROP quad by quad after the warp's end, in sequence-number order; the
 * slot release (xr_*) of every ended warp.  The PT and its allocator are
 * atg_su_pt.
 *
 * The warp's quads come from the RX's register writes (fl_*): r3 (z) of
 * every lane is the depth unless the shader exports 0x104, r4/r5 (the
 * pixel centre, x + 0.5 and y + 0.5) of lane 4q give quad q's position;
 * fl_go gives the coverage and the sequence number (fl_info).  A quad of
 * the warp is one with coverage (RX packs the quads from lane 0).
 * ex_mask = the covered lanes that some fragment exp wrote under the
 * side-effect mask (EXEC & coverage & ~KILLED).  Storage: NPHYS lane
 * banks × 6 words (R, G, B, A, depth, z) × NWARPS×32/NPHYS rows, written
 * one word per bank per cycle, read asynchronously (a quad's 4 lanes are
 * in 4 banks of one row).
 *
 * States: IDLE →(an ended fragment warp whose number is ex_next)→ DRAIN
 * (one quad per ex_ready) →(last quad)→ RET (xr_valid) → IDLE.  Vertex
 * and compute warps release at once (xr_valid the cycle after wc_end; a
 * drain's release waits a cycle when both fall together).
 *
 * Multisampling (docs/ghci.md section 12.11): the RX's r6 (the lane's
 * samples after the sample mask test) is snooped like r3 (a lane the RX
 * did not write takes 1111); exp 0x105 (SAMPLE_MASK) keeps the last value
 * written per lane; the quad's sample mask is r6 AND that value (1111 when
 * none), lane l at ex_ms bits 4 l + s.  A lane whose mask is 0 does not go
 * out (ex_mask).  ex_ms also carries the lanes that exported DEPTH and the
 * warp's d_s (the RX's table words 0xFF8-0xFFB, one per sample; 0 for a
 * warp without them: the slot's copy is cleared at its release).
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
	/* Multisampling to the ROP: {d_s[127:0], zexp[3:0], smask[15:0]} */
	output wire [147:0] ex_ms,
	/* Slot release (atg_su_sched) */
	output wire xr_valid,
	output wire [WARP_W-1:0] xr_warp,
	input wire wc_end,
	input wire [WARP_W-1:0] wc_warp
);
`include "atg_su_uop.vh"

	localparam G = 32 / NPHYS;
	localparam ROWS = NWARPS * G;
	localparam RW = ROWS > 1 ? $clog2(ROWS) : 1;
	localparam [1:0] S_IDLE = 2'd0, S_DRAIN = 2'd1, S_RET = 2'd2;

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
	reg [NWARPS-1:0] frag, ended;
	reg [NWARPS*16-1:0] seq;
	reg [NWARPS*32-1:0] cov, xp, dw;	/* coverage, exported lanes, depth written */
	reg [NWARPS*32-1:0] smw, r6w;	/* SAMPLE_MASK exported, r6 written by the RX */
	reg [NWARPS*128-1:0] dsv;	/* the warp's d_s */
	reg [NWARPS*8*16-1:0] qx, qy;

	/* ---- Exports of fragment warps. */
	wire [31:0] tgt = x_uop[ATG_UOP_IMM +: 32];
	wire ex_op = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXP && x_info[17:16] == 2'd1 &&
		tgt >= 32'h100 && tgt <= 32'h105;
	wire [2:0] comp = tgt[2:0];
	wire [31:0] xrow = {{(32-WARP_W){1'b0}}, x_warp} * G + {{(32-GRP_W){1'b0}}, x_grp};
	wire [NPHYS-1:0] side = x_mask[2*NPHYS-1:NPHYS];
	wire [31:0] lane0 = {{(32-GRP_W){1'b0}}, x_grp} * NPHYS;
	wire [31:0] side_w = {{(32-NPHYS){1'b0}}, side} << lane0[4:0];
	wire [31:0] zrow = {{(32-WARP_W){1'b0}}, fl_slot} * G + {27'd0, fl_lane} / NPHYS;
	wire [31:0] zbank = {27'd0, fl_lane} % NPHYS;
	wire [31:0] fq = ({{(32-WARP_W){1'b0}}, fl_slot} * 8 + {29'd0, fl_lane[4:2]}) * 16;
	wire [15:0] fx = ffloor(fl_data[31:8]);

	/* ---- The drain. */
	reg [1:0] st;
	reg [WARP_W-1:0] dwarp;
	reg [2:0] dq;
	reg vx_v;	/* a vertex/compute warp's release, this cycle */
	reg [WARP_W-1:0] vx_w;

	wire [4:0] dl0 = {dq, 2'b00};
	wire [31:0] drow = {{(32-WARP_W){1'b0}}, dwarp} * G + {27'd0, dl0} / NPHYS;
	wire [31:0] dcov = cov[dwarp*32 +: 32];
	wire [2:0] dq1 = dq + 3'd1;
	wire dlast = dq == 3'd7 || dcov[{dq1, 2'b00} +: 4] == 4'd0;
	wire [31:0] dqs = ({{(32-WARP_W){1'b0}}, dwarp} * 8 + {29'd0, dq}) * 16;
	wire [31:0] dxp = xp[dwarp*32 +: 32] & dcov;
	wire [31:0] ddw = dw[dwarp*32 +: 32];
	wire [31:0] dsm = smw[dwarp*32 +: 32];
	wire [31:0] dr6 = r6w[dwarp*32 +: 32];

	/* NPHYS lane banks × {R, G, B, A, depth, z} and {SAMPLE_MASK, r6}. */
	wire [NPHYS*192-1:0] rdat;
	wire [NPHYS*8-1:0] rsm;
	genvar b;
	generate
	for (b = 0; b < NPHYS; b = b + 1) begin : g_bank
		reg [31:0] m0 [0:ROWS-1];
		reg [31:0] m1 [0:ROWS-1];
		reg [31:0] m2 [0:ROWS-1];
		reg [31:0] m3 [0:ROWS-1];
		reg [31:0] m4 [0:ROWS-1];
		reg [31:0] mz [0:ROWS-1];
		reg [3:0] m5 [0:ROWS-1];
		reg [3:0] mr6 [0:ROWS-1];
		wire [31:0] d = x_b[32 * b +: 32];
		wire we = ex_op && side[b];
		always @(posedge clk) begin
			if (we && comp == 3'd0) m0[xrow[RW-1:0]] <= d;
			if (we && comp == 3'd1) m1[xrow[RW-1:0]] <= d;
			if (we && comp == 3'd2) m2[xrow[RW-1:0]] <= d;
			if (we && comp == 3'd3) m3[xrow[RW-1:0]] <= d;
			if (we && comp == 3'd4) m4[xrow[RW-1:0]] <= d;
			if (we && comp == 3'd5) m5[xrow[RW-1:0]] <= d[3:0];
			if (fl_we && fl_reg == 6'd3 && zbank == b)
				mz[zrow[RW-1:0]] <= fl_data;
			if (fl_we && fl_reg == 6'd6 && zbank == b)
				mr6[zrow[RW-1:0]] <= fl_data[3:0];
		end
		assign rsm[8 * b +: 8] = {m5[drow[RW-1:0]], mr6[drow[RW-1:0]]};
		assign rdat[192 * b +: 192] = {mz[drow[RW-1:0]], m4[drow[RW-1:0]],
			m3[drow[RW-1:0]], m2[drow[RW-1:0]], m1[drow[RW-1:0]], m0[drow[RW-1:0]]};
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

	/* An ended fragment warp whose sequence number is the ROP's next one. */
	reg [WARP_W-1:0] cand;
	reg cand_v;
	integer w;
	always @(*) begin
		cand_v = 1'b0;
		cand = {WARP_W{1'b0}};
		for (w = NWARPS - 1; w >= 0; w = w - 1)
			if (frag[w] && ended[w] && seq[w*16 +: 16] == ex_next) begin
				cand_v = 1'b1;
				cand = w[WARP_W-1:0];
			end
	end

	assign x_ready = 1'b1;
	assign ex_valid = st == S_DRAIN;
	assign ex_seq = seq[dwarp*16 +: 16];
	assign ex_xy = {qy[dqs +: 16], qx[dqs +: 16]};
	assign ex_mask = dxp[dl0 +: 4] & smok;
	assign ex_ms = {dsv[dwarp*128 +: 128], zexp & dxp[dl0 +: 4], smask};
	assign ex_color = col;
	assign ex_depth = dep;
	assign ex_last = dlast;
	assign xr_valid = vx_v || st == S_RET;
	assign xr_warp = vx_v ? vx_w : dwarp;

	always @(posedge clk) begin
		if (!rst_n) begin
			frag <= {NWARPS{1'b0}};
			ended <= {NWARPS{1'b0}};
			r6w <= {(NWARPS*32){1'b0}};
			dsv <= {(NWARPS*128){1'b0}};
			st <= S_IDLE;
			vx_v <= 1'b0;
			vx_w <= {WARP_W{1'b0}};
			dwarp <= {WARP_W{1'b0}};
			dq <= 3'd0;
		end else begin
			vx_v <= wc_end && !frag[wc_warp];
			vx_w <= wc_warp;
			/* The RX's r6 and d_s of the warp being built; cleared at a release. */
			if (fl_we && fl_reg == 6'd6)
				r6w[fl_slot*32 + {27'd0, fl_lane}] <= 1'b1;
			if (fl_pw_we && fl_pw_addr[11:2] == 10'h3FE)
				dsv[fl_slot*128 + {fl_pw_addr[1:0], 5'd0} +: 32] <= fl_pw_data;
			if (xr_valid) begin
				r6w[xr_warp*32 +: 32] <= 32'd0;
				dsv[xr_warp*128 +: 128] <= 128'd0;
			end
			if (wc_end && frag[wc_warp])
				ended[wc_warp] <= 1'b1;
			if (fl_go) begin
				frag[fl_slot] <= 1'b1;
				ended[fl_slot] <= 1'b0;
				seq[fl_slot*16 +: 16] <= fl_info[47:32];
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
				if (comp == 3'd4)
					dw[x_warp*32 +: 32] <= dw[x_warp*32 +: 32] | side_w;
				if (comp == 3'd5)
					smw[x_warp*32 +: 32] <= smw[x_warp*32 +: 32] | side_w;
			end
			case (st)
			S_IDLE:
				if (cand_v) begin
					dwarp <= cand;
					dq <= 3'd0;
					st <= S_DRAIN;
				end
			S_DRAIN:
				if (ex_ready) begin
					if (dlast)
						st <= S_RET;
					else
						dq <= dq1;
				end
			default:	/* S_RET: the release (after a vertex warp's of this cycle) */
				if (!vx_v) begin
					frag[dwarp] <= 1'b0;
					ended[dwarp] <= 1'b0;
					st <= S_IDLE;
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_a, x_c, x_mask[NPHYS-1:0], x_info,
		x_uop, fl_info[63:48], fl_data[7:0], tgt, xrow, lane0, zrow, drow, fq, dqs};
endmodule

`default_nettype wire
