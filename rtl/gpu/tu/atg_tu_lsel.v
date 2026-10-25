/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_lsel: a lane's λ and level for atg_tu_addr's stage A: λ' (texl
 * rs2; texb the quad's plus the bias rs2, none for the query) plus
 * mipLodBias, λ = max(min(λ', maxLod), minLod) (0 with unnormalized
 * coordinates); the level read (texsz rs1, texf rs2 or 0 for a
 * multisampled image, gather and magnification 0, mip linear λ >> 8 and
 * the next with the weight λ & 255, else (λ + 127) >> 8, clamped to the
 * last level); the query's level clamp(λ, 0, LEVELS − 1); linear or
 * nearest filtering.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_lsel (
	input wire [1:0] op,	/* 0 texl, 1 texb, 2 texf, 3 texsz */
	input wire qlod,
	input wire unn,
	input wire gather,
	input wire ms,
	input wire filt,
	input wire miplin,
	input wire mag_lin,	/* the sampler's MAG_LINEAR, MIN_LINEAR */
	input wire min_lin,
	input wire pas1,	/* the pass's second level */
	input wire [31:0] cw0,	/* the lane's rs1 (texsz: the level) */
	input wire [31:0] cw2,	/* rs2: the LOD, the bias, texf's level or sample */
	input wire signed [16:0] lam_q,	/* texb: the quad's λ */
	input wire signed [16:0] sbias,
	input wire signed [16:0] minlod,
	input wire signed [16:0] maxlod,
	input wire [3:0] maxl,	/* the last level */
	output wire [3:0] lvl,
	output wire lin,
	output wire [7:0] fl,
	output wire signed [16:0] lamp,
	output wire [15:0] dq
);
	`include "atg_tu_fn.vh"
	localparam [1:0] OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;

	wire [31:0] lfx;
	atg_tu_fx32 u_lfx (.f(cw2), .sh(5'd8), .q(lfx));
	wire signed [16:0] lam1 = tu_sat16({lfx[31], lfx});
	wire [32:0] lsum, bsum;
	wire [16:0] lrnd;
	wire [3:0] lnx;
	wire [3:0] carry_unused;
	am_add #(.W(33)) u_lsum (.a({{16{lam_q[16]}}, lam_q}), .b({{16{lam1[16]}}, lam1}), .ci(1'b0), .s(lsum),
		.co(carry_unused[0]));
	wire signed [16:0] lraw = op != OP_TEXB ? lam1 : qlod ? lam_q : tu_sat16(lsum);
	am_add #(.W(33)) u_bsum (.a({{16{lraw[16]}}, lraw}), .b({{16{sbias[16]}}, sbias}), .ci(1'b0),
		.s(bsum), .co(carry_unused[1]));
	assign lamp = unn ? 17'sd0 : tu_sat16(bsum);
	wire signed [16:0] lamc = lamp > maxlod ? maxlod : lamp;
	wire signed [16:0] lam = unn ? 17'sd0 : lamc < minlod ? minlod : lamc;
	wire mag = !(lam > 17'sd0);
	/* The query: the level accessed, clamp(λ, 0, LEVELS − 1). */
	wire signed [16:0] lmaxf = $signed({5'd0, maxl, 8'd0});
	assign dq = lam < 0 ? 16'd0 : lam > lmaxf ? lmaxf[15:0] : lam[15:0];
	am_add #(.W(17)) u_lrnd (.a(lam), .b(17'd127), .ci(1'b0), .s(lrnd), .co(carry_unused[2]));
	am_add #(.W(4)) u_lnx (.a(lam[11:8]), .b(4'd0), .ci(pas1), .s(lnx), .co(carry_unused[3]));
	wire [3:0] lmin = lrnd[15:8] > {4'd0, maxl} ? maxl : lrnd[11:8];
	wire lend = lam[15:8] >= {4'd0, maxl};
	wire [3:0] llin = lend ? maxl : lnx;
	assign fl = !mag && miplin && !lend ? lam[7:0] : 8'd0;
	wire [3:0] lfetch = cw2[31] ? 4'd0 : cw2[30:0] > {27'd0, maxl} ? maxl : cw2[3:0];
	wire [3:0] lsize = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
	assign lvl = op == OP_TEXSZ ? lsize : op == OP_TEXF ? (ms ? 4'd0 : lfetch) : gather || mag ? 4'd0 :
		miplin ? llin : lmin;
	assign lin = op[1] || qlod ? 1'b0 : gather ? 1'b1 : filt && (mag ? mag_lin : min_lin);

	wire unused_ok = &{1'b0, lrnd[16], lrnd[7:0], lmaxf[16]};
endmodule

`default_nettype wire
