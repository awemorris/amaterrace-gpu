/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tex: The SU side of texturing: forms TU requests from
 * texl/texb/texf/texsz (per quad, with the derivative lanes), and returns
 * the TU's texels as long beats (rd..rd+3).
 *
 * The send half (here): a lane group of a texture instruction is taken in
 * IDLE (x_ready, while the return half has room for its record); its
 * record (warp, group, rd, scoreboard entry, last, texsz, which quads were
 * sent, the EXEC lanes) goes to atg_su_tex_ret at once, then its quads
 * (lanes 4q..4q+3 of the group) go to the TU one per cycle, those with no
 * EXEC lane skipped.  A quad's coordinates are lane by lane {third, Dref,
 * rs2, rs1+1, rs1} (u, v, lod/bias/level, the reference of a .c form, the
 * third coordinate of a .3 form (rs1+2), else 0; texsz: rs1 = the level in
 * word 0), its tx_op the uop's TEX op bits 6:0 (the operation and its
 * modifiers), tx_off the uop's imm[11:0] (the texel offsets), its mask the
 * EXEC lanes (helper lanes included), its tag {0, warp, quad number in the
 * warp, rd}, tx_last on the last sent quad of the instruction's last
 * group.  A .c or .3 form's group comes twice (atg_su_opd): the first pass
 * is kept and the second (TEX op bit 7) brings rs1+2 on x_a and rs1+3 on
 * x_c: .3 the third coordinate and Dref (.3.c), .c alone Dref (x_a); the
 * record is pushed then.  The return half
 * (atg_su_tex_ret) gathers the returned quads, in request order, into
 * lane groups and writes rd..rd+3 (texsz: rd).
 *
 * States: IDLE →(group with a quad)→ SEND (quad q, NPHYS/4 of them)
 * →(last quad taken)→ IDLE; IDLE →(the first pass of a .c or .3 group)→ DREF
 * →(its second pass)→ SEND or IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_tex #(
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
	/* To the TU (atg_tu) */
	output wire tx_valid,
	input wire tx_ready,
	output reg [7:0] tx_op,
	output reg [3:0] tx_slot,
	output reg tx_vs,	/* a vertex warp's request (the vertex stage's slots) */
	output wire [3:0] tx_mask,
	output wire [639:0] tx_coord,
	output reg [11:0] tx_off,
	output wire [15:0] tx_tag,
	output wire tx_last,
	input wire tr_valid,
	output wire tr_ready,
	input wire [15:0] tr_tag,
	input wire [511:0] tr_data,
	input wire tr_last
);
`include "atg_su_uop.vh"

	localparam NQ = NPHYS / 4;	/* quads in a lane group */
	localparam QW = NQ > 1 ? $clog2(NQ) : 1;
	localparam [1:0] IDLE = 2'd0, SEND = 2'd1, DREF = 2'd2;

	reg [1:0] st;
	reg [QW-1:0] q, lastq;
	reg [NPHYS*160-1:0] crd;
	reg [NPHYS-1:0] lanes;
	reg [WARP_W-1:0] warp;
	reg [GRP_W-1:0] grp;
	reg [6:0] rd;
	reg last;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_TEX;
	wire cform = x_uop[ATG_UOP_OP + ATG_TEX_CFORM];
	wire three = x_uop[ATG_UOP_SUB + 4];	/* a .3 form (atg_su_dec) */
	wire wide = cform || three;	/* two operand passes */
	wire [NPHYS-1:0] exec = x_mask[NPHYS-1:0];
	wire rq_ready;

	/* Which quads of the group have EXEC lanes, and the last of them. */
	reg [NQ-1:0] qm;
	reg [QW-1:0] ql;
	reg [NPHYS*160-1:0] xcrd, dcrd;
	integer i;
	always @(*) begin
		ql = {QW{1'b0}};
		for (i = 0; i < NQ; i = i + 1) begin
			qm[i] = exec[4*i +: 4] != 4'd0;
			if (qm[i])
				ql = i[QW-1:0];
		end
		for (i = 0; i < NPHYS; i = i + 1) begin
			xcrd[i*160 +: 160] = {64'd0, x_b[i*32 +: 32], x_c[i*32 +: 32], x_a[i*32 +: 32]};
			dcrd[i*160 +: 160] = {three ? x_a[i*32 +: 32] : 32'd0,
				three ? (cform ? x_c[i*32 +: 32] : 32'd0) : x_a[i*32 +: 32], crd[i*160 +: 96]};
		end
	end
	wire take = mine && x_ready;
	/* The record goes to the return half with the group's last pass. */
	wire push = take && (st == DREF || !wide);

	assign x_ready = (st == IDLE || st == DREF) && rq_ready;
	wire [3:0] qmask = lanes[q*4 +: 4];
	assign tx_valid = st == SEND && qmask != 4'd0;
	assign tx_mask = qmask;
	/* Quad q's coordinates (a selection: 640 bits a quad), and the quad's number grp NQ + q. */
	reg [639:0] q_crd;
	integer qi;
	always @(*) begin
		q_crd = crd[639:0];
		for (qi = 1; qi < NQ; qi = qi + 1)
			if (q == qi[QW-1:0])
				q_crd = crd[qi*640 +: 640];
	end
	assign tx_coord = q_crd;
	wire [31:0] qn = ({{(32 - GRP_W){1'b0}}, grp} << QW) | {{(32 - QW){1'b0}}, q};
	wire [QW-1:0] q_next;
	wire qn_co_unused;
	am_add #(.W(QW)) u_q (.a(q), .b({QW{1'b0}}), .ci(1'b1), .s(q_next), .co(qn_co_unused));
	wire [2:0] qnum = qn[2:0];
	wire [5:0] wpad = {{(6 - WARP_W){1'b0}}, warp};
	assign tx_tag = {3'd0, wpad[2:0], qnum, rd};
	assign tx_last = last && q == lastq;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (take) begin
				crd <= xcrd;
				lanes <= exec;
				warp <= x_warp;
				grp <= x_grp;
				rd <= x_uop[ATG_UOP_RD +: 7];
				last <= x_last;
				tx_op <= {1'b0, x_uop[ATG_UOP_OP +: 7]};
				tx_slot <= x_uop[ATG_UOP_SUB +: 4];
				tx_vs <= x_info[17:16] == 2'd0;
				tx_off <= x_uop[ATG_UOP_IMM +: 12];
				q <= {QW{1'b0}};
				lastq <= ql;
				if (wide)
					st <= DREF;
				else if (qm != {NQ{1'b0}})
					st <= SEND;
			end
			DREF: if (take) begin
				crd <= dcrd;
				lanes <= exec;
				last <= x_last;
				lastq <= ql;
				st <= qm != {NQ{1'b0}} ? SEND : IDLE;
			end
			SEND: if (!tx_valid || tx_ready) begin
				q <= q_next;
				if (q == lastq)
					st <= IDLE;
			end
			default: st <= IDLE;
			endcase
		end
	end

	atg_su_tex_ret #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W)) ret (
		.clk(clk), .rst_n(rst_n),
		.rq_valid(push), .rq_ready(rq_ready), .rq_warp(x_warp), .rq_grp(x_grp),
		.rq_rd(x_uop[ATG_UOP_RD +: 7]), .rq_sbe(x_sbe), .rq_last(x_last),
		.rq_sz(x_uop[ATG_UOP_OP +: 2] == 2'd3), .rq_qmask(qm), .rq_lanes(exec),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_data(tr_data),
		.l_valid(l_valid), .l_ready(l_ready), .l_warp(l_warp), .l_grp(l_grp), .l_rd(l_rd),
		.l_data(l_data), .l_lanes(l_lanes), .l_wr(l_wr), .l_last(l_last), .l_sbe(l_sbe),
		.l_cls(l_cls)
	);

	wire unused_ok = &{1'b0, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info[31:18], x_info[15:0], x_uop, tr_tag, tr_last, wpad[5:3], qn[31:3],
		(NWARPS != 0)};
endmodule

`default_nettype wire
