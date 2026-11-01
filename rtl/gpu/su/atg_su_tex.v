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
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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
	output reg [3:0] tx_samp_slot,
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
	localparam QS = $clog2(NQ);	/* the quad number's bits in a group (0 for NPHYS 4) */
	localparam [1:0] IDLE = 2'd0, SEND = 2'd1, DREF = 2'd2;

	(* keep = "true" *) wire rst_p = !rst_n;

	(* fsm_encoding = "none", max_fanout = 12 *) reg [1:0] st;
	(* max_fanout = 12 *) reg [QW-1:0] q, lastq;
	(* max_fanout = 12 *) reg [NPHYS-1:0] lanes;
	(* max_fanout = 12 *) reg [WARP_W-1:0] warp;
	(* max_fanout = 12 *) reg [GRP_W-1:0] grp;
	(* max_fanout = 12 *) reg [6:0] rd;
	(* max_fanout = 12 *) reg last;

	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_TEX;
	(* max_fanout = 12 *) wire cform = x_uop[ATG_UOP_OP + ATG_TEX_CFORM];
	(* max_fanout = 12 *) wire three = x_uop[ATG_UOP_SUB + 4];	/* a .3 form (atg_su_dec) */
	wire wide = cform || three;	/* two operand passes */
	wire [NPHYS-1:0] exec = x_mask[NPHYS-1:0];
	wire rq_ready;

	/* Which quads of the group have EXEC lanes, and the last of them. */
	reg [NQ-1:0] qm;
	reg [QW-1:0] ql;
	integer i;
	always @(*) begin
		ql = {QW{1'b0}};
		for (i = 0; i < NQ; i = i + 1) begin
			qm[i] = exec[4*i +: 4] != 4'd0;
			if (qm[i])
				ql = i[QW-1:0];
		end
	end
	wire take = mine && x_ready;
	(* max_fanout = 12 *) wire take_idle = (st == IDLE) && rq_ready && mine;
	(* max_fanout = 12 *) wire take_dref = (st == DREF) && rq_ready && mine;
	/* The record goes to the return half with the group's last pass. */
	(* max_fanout = 12 *) wire push = take && (st == DREF || !wide);

	assign x_ready = (st == IDLE || st == DREF) && rq_ready;
	wire [3:0] qmask = lanes[q*4 +: 4];
	assign tx_valid = st == SEND && qmask != 4'd0;
	assign tx_mask = qmask;

	/* Quad q's coordinates (640 bits = 4 lanes in quad × 10 16-bit half-words per lane),
	 * stored in per-slice registers so each CE/mux net drives at most 16 bits. */
	wire [639:0] q_crd;
	genvar gq_l, ghw, gqi;
	generate
	for (gq_l = 0; gq_l < 4; gq_l = gq_l + 1) begin : g_qlane
		for (ghw = 0; ghw < 10; ghw = ghw + 1) begin : g_qhw
			localparam SL_IDX = gq_l * 10 + ghw;
			localparam H_BIT = (ghw % 2) * 16;
			localparam W_IDX = ghw / 2;
			(* keep = "true" *) wire ti_s = take_idle;
			(* keep = "true" *) wire td_s = take_dref;
			(* keep = "true" *) wire th_s = three;
			(* keep = "true" *) wire cf_s = cform;
			(* keep = "true" *) wire [QW-1:0] q_sl = q;
			(* shreg_extract = "no" *) reg [NQ*16-1:0] crd_sl;

			for (gqi = 0; gqi < NQ; gqi = gqi + 1) begin : g_qinst
				localparam L_IDX = gqi * 4 + gq_l;
				wire [15:0] xa_h = x_a[L_IDX*32 + H_BIT +: 16];
				wire [15:0] xb_h = x_b[L_IDX*32 + H_BIT +: 16];
				wire [15:0] xc_h = x_c[L_IDX*32 + H_BIT +: 16];
				wire [15:0] idle_d = (W_IDX == 0) ? xa_h :
				                     (W_IDX == 1) ? xc_h :
				                     (W_IDX == 2) ? xb_h : 16'd0;
				wire [15:0] dref_d = (W_IDX == 3) ? (th_s ? (cf_s ? xc_h : 16'd0) : xa_h) :
				                     (W_IDX == 4) ? (th_s ? xa_h : 16'd0) :
				                     crd_sl[gqi*16 +: 16];
				always @(posedge clk) begin
					if (ti_s)
						crd_sl[gqi*16 +: 16] <= idle_d;
					else if (td_s && (W_IDX >= 3))
						crd_sl[gqi*16 +: 16] <= dref_d;
				end
			end

			reg [15:0] q_crd_s;
			integer qsi;
			always @(*) begin
				q_crd_s = crd_sl[0 +: 16];
				for (qsi = 1; qsi < NQ; qsi = qsi + 1)
					if (q_sl == qsi[QW-1:0])
						q_crd_s = crd_sl[qsi*16 +: 16];
			end
			assign q_crd[SL_IDX*16 +: 16] = q_crd_s;
		end
	end
	endgenerate
	assign tx_coord = q_crd;
	wire [31:0] qn = ({{(32 - GRP_W){1'b0}}, grp} << QS) |
		(NQ > 1 ? {{(32 - QW){1'b0}}, q} : 32'd0);
	wire [QW-1:0] q_next;
	wire qn_co_unused;
	am_add #(.W(QW)) u_q (.a(q), .b({QW{1'b0}}), .ci(1'b1), .s(q_next), .co(qn_co_unused));
	wire [2:0] qnum = qn[2:0];
	wire [5:0] wpad = {{(6 - WARP_W){1'b0}}, warp};
	assign tx_tag = {3'd0, wpad[2:0], qnum, rd};
	assign tx_last = last && q == lastq;

	always @(posedge clk) begin
		if (rst_p) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (take_idle) begin
				lanes <= exec;
				warp <= x_warp;
				grp <= x_grp;
				rd <= x_uop[ATG_UOP_RD +: 7];
				last <= x_last;
				tx_op <= {1'b0, x_uop[ATG_UOP_OP +: 7]};
				tx_slot <= x_uop[ATG_UOP_SUB +: 4];
				tx_samp_slot <= x_uop[ATG_UOP_SAMP_SLOT +: 4];
				tx_vs <= x_info[17:16] == 2'd0;
				tx_off <= x_uop[ATG_UOP_IMM +: 12];
				q <= {QW{1'b0}};
				lastq <= ql;
				if (wide)
					st <= DREF;
				else if (qm != {NQ{1'b0}})
					st <= SEND;
			end
			DREF: if (take_dref) begin
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
