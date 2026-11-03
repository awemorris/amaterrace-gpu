/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_lane: Cross-lane operations: qd (quad differences and swaps for
 * derivatives, design §3.4.1) always; shfl/vote/ballot with SUBGROUP
 * (staging registers, design §3.4.2).  Short results, SHORT_LAT cycles
 * after the group's slot on the bus.
 *
 * qd works inside a lane group (NPHYS >= 4), one group per cycle.
 * shfl/vote/ballot need all 32 lanes: the groups before the last are
 * staged as they pass (x_ready 1); the last group is staged in its first
 * cycle on the bus and then held there (x_ready 0) for G = 32/NPHYS more
 * cycles, in which the results of groups 0..G-1 enter the result pipeline,
 * one per cycle; x_ready is 1 in the last of them.  So group g's result
 * leaves SHORT_LAT cycles after cycle x_end - (G-1) + g, the same as for
 * an instruction whose groups pass one per cycle: atg_su_sb's short
 * interlock and atg_su_wb's one-short-result-per-cycle rule hold, since
 * the bus carries nothing else in those cycles.  2 × G bus cycles.
 * The behaviour: spec/gpu/su/atg_su_lane.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_lane #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot present */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
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
	output wire sg_emit_done,
	/* Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid) */
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	wire [3:0] unit = x_uop[ATG_UOP_UNIT +: 4];
	wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire [4:0] sub = x_uop[ATG_UOP_SUB +: 5];
	wire wrd = x_uop[ATG_UOP_WRD];
	wire mine = x_valid && unit == ATG_UNIT_LANE && op == ATG_LANE_QD && wrd;
	/* A subgroup instruction on the bus (they are ISA faults without SUBGROUP). */
	wire sg = SUBGROUP != 0 && x_valid && unit == ATG_UNIT_LANE &&
		(op == ATG_LANE_SHFL || op == ATG_LANE_VOTE || op == ATG_LANE_BALLOT);

	/* Stage 0 registered input for QD instructions (cuts long path from OPD) */
	(* shreg_extract = "no" *) reg r0_valid;
	(* shreg_extract = "no" *) reg [WARP_W-1:0] r0_warp;
	(* shreg_extract = "no" *) reg [GRP_W-1:0]  r0_grp;
	(* shreg_extract = "no" *) reg [6:0]        r0_rd;
	(* shreg_extract = "no" *) reg [NPHYS-1:0]  r0_mask;
	(* shreg_extract = "no", max_fanout = 16 *) reg [2:0] r0_sub;
	(* shreg_extract = "no" *) reg [DW-1:0]     r0_xa;
	(* shreg_extract = "no" *) reg [(NPHYS/4)*32-1:0] r0_qa_a, r0_qa_b, r0_qb_a, r0_qb_b;

	wire [16*3-1:0] sub_ctl_p;
	wire [2:0] sub_pipe;
	wire [2:0] sub_ctl_vote;
`ifdef SYNTH_KINTEX7
	wire [2:0] sub_p0, sub_p1, sub_qa;
	genvar gsb_pre;
	generate
		for (gsb_pre = 0; gsb_pre < 3; gsb_pre = gsb_pre + 1) begin : g_sub_pre
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_p0 (.I0(sub[gsb_pre]), .O(sub_p0[gsb_pre]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_p1 (.I0(sub[gsb_pre]), .O(sub_p1[gsb_pre]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_qa (.I0(sub[gsb_pre]), .O(sub_qa[gsb_pre]));
		end
	endgenerate

	genvar gsb, gsp;
	generate
		for (gsp = 0; gsp < 16; gsp = gsp + 1) begin : g_sub_p
			wire [2:0] sub_src = (gsp < 8) ? sub_p0 : sub_p1;
			for (gsb = 0; gsb < 3; gsb = gsb + 1) begin : g_sub_b
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_ctl (.I0(sub_src[gsb]), .O(sub_ctl_p[gsp*3 + gsb]));
			end
		end
		for (gsb = 0; gsb < 3; gsb = gsb + 1) begin : g_sub_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_pip (.I0(sub_qa[gsb]), .O(sub_pipe[gsb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs_vot (.I0(sub_qa[gsb]), .O(sub_ctl_vote[gsb]));
		end
	endgenerate
`else
	assign sub_ctl_p = {16{sub[2:0]}};
	assign sub_pipe = sub[2:0];
	assign sub_ctl_vote = sub[2:0];
`endif

	genvar gqi;
	generate
		for (gqi = 0; gqi < NPHYS / 4; gqi = gqi + 1) begin : g_qa_mux
			wire sub0_qa_lo, sub0_qa_hi;
			wire sub0_qb_lo, sub0_qb_hi;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs0_qa_lo (.I0(sub_qa[0]), .O(sub0_qa_lo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs0_qa_hi (.I0(sub_qa[0]), .O(sub0_qa_hi));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs0_qb_lo (.I0(sub_qa[0]), .O(sub0_qb_lo));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bs0_qb_hi (.I0(sub_qa[0]), .O(sub0_qb_hi));
`else
			assign sub0_qa_lo = sub[0];
			assign sub0_qa_hi = sub[0];
			assign sub0_qb_lo = sub[0];
			assign sub0_qb_hi = sub[0];
`endif
			always @(posedge clk) begin
				if (rst_p) begin
					r0_qa_a[gqi*32 +: 32] <= 32'd0;
					r0_qa_b[gqi*32 +: 32] <= 32'd0;
					r0_qb_a[gqi*32 +: 32] <= 32'd0;
					r0_qb_b[gqi*32 +: 32] <= 32'd0;
				end else begin
					r0_qa_b[gqi*32 +: 32] <= x_a[(4*gqi)*32 +: 32];
					r0_qb_a[gqi*32 +: 32] <= x_a[(4*gqi + 3)*32 +: 32];
					r0_qa_a[gqi*32 +: 16] <= sub0_qa_lo ? x_a[(4*gqi + 2)*32 +: 16] : x_a[(4*gqi + 1)*32 +: 16];
					r0_qa_a[gqi*32+16 +: 16] <= sub0_qa_hi ? x_a[(4*gqi + 2)*32+16 +: 16] : x_a[(4*gqi + 1)*32+16 +: 16];
					r0_qb_b[gqi*32 +: 16] <= sub0_qb_lo ? x_a[(4*gqi + 1)*32 +: 16] : x_a[(4*gqi + 2)*32 +: 16];
					r0_qb_b[gqi*32+16 +: 16] <= sub0_qb_hi ? x_a[(4*gqi + 1)*32+16 +: 16] : x_a[(4*gqi + 2)*32+16 +: 16];
				end
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			r0_valid <= 1'b0;
			r0_warp  <= {WARP_W{1'b0}};
			r0_grp   <= {GRP_W{1'b0}};
			r0_rd    <= 7'd0;
			r0_mask  <= {NPHYS{1'b0}};
			r0_sub   <= 3'd0;
			r0_xa    <= {DW{1'b0}};
		end else begin
			r0_valid <= mine;
			r0_warp  <= x_warp;
			r0_grp   <= x_grp;
			r0_rd    <= x_uop[ATG_UOP_RD +: 7];
			r0_mask  <= x_mask[NPHYS-1:0];
			r0_sub   <= sub_pipe;
			r0_xa    <= x_a;
		end
	end

	/* Stage 1 to 5 pipeline match for QD control & operands (quad-swap pre-muxed at r0 -> r1) */
	(* shreg_extract = "no" *) reg r1_valid, r2_valid, r3_valid;
	(* shreg_extract = "no", max_fanout = 12 *) reg r4_valid, r5_valid;
	(* shreg_extract = "no" *) reg [WARP_W-1:0] r1_warp, r2_warp, r3_warp, r4_warp, r5_warp;
	(* shreg_extract = "no" *) reg [GRP_W-1:0]  r1_grp,  r2_grp,  r3_grp,  r4_grp,  r5_grp;
	(* shreg_extract = "no" *) reg [6:0]        r1_rd,   r2_rd,   r3_rd,   r4_rd,   r5_rd;
	(* shreg_extract = "no" *) reg [NPHYS-1:0]  r1_mask, r2_mask, r3_mask, r4_mask, r5_mask;
	(* shreg_extract = "no" *) reg [2:0]        r1_sub,  r2_sub,  r3_sub,  r4_sub;
	(* shreg_extract = "no" *) reg [DW-1:0]     r1_xa,   r2_xa,   r3_xa,   r4_xa,   r5_xa;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 16 *) reg [NPHYS*2-1:0] r4_use_qa, r4_use_qb, r4_use_xa;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 16 *) reg [NPHYS*2-1:0] r5_use_qa, r5_use_qb, r5_use_xa;

	integer qm;
	always @(posedge clk) begin
		if (rst_p) begin
			r1_valid <= 1'b0; r2_valid <= 1'b0; r3_valid <= 1'b0; r4_valid <= 1'b0; r5_valid <= 1'b0;
			r1_warp  <= {WARP_W{1'b0}}; r2_warp <= {WARP_W{1'b0}}; r3_warp <= {WARP_W{1'b0}}; r4_warp <= {WARP_W{1'b0}}; r5_warp <= {WARP_W{1'b0}};
			r1_grp   <= {GRP_W{1'b0}};  r2_grp  <= {GRP_W{1'b0}};  r3_grp  <= {GRP_W{1'b0}};  r4_grp  <= {GRP_W{1'b0}};  r5_grp  <= {GRP_W{1'b0}};
			r1_rd    <= 7'd0;           r2_rd   <= 7'd0;           r3_rd   <= 7'd0;           r4_rd   <= 7'd0;           r5_rd   <= 7'd0;
			r1_mask  <= {NPHYS{1'b0}};  r2_mask <= {NPHYS{1'b0}};  r3_mask <= {NPHYS{1'b0}};  r4_mask <= {NPHYS{1'b0}};  r5_mask <= {NPHYS{1'b0}};
			r1_sub   <= 3'd0;           r2_sub  <= 3'd0;           r3_sub  <= 3'd0;           r4_sub  <= 3'd0;
			r1_xa    <= {DW{1'b0}};     r2_xa   <= {DW{1'b0}};     r3_xa   <= {DW{1'b0}};     r4_xa   <= {DW{1'b0}};     r5_xa   <= {DW{1'b0}};
			r4_use_qa <= {(NPHYS*2){1'b0}};
			r4_use_qb <= {(NPHYS*2){1'b0}};
			r4_use_xa <= {(NPHYS*2){1'b0}};
			r5_use_qa <= {(NPHYS*2){1'b0}};
			r5_use_qb <= {(NPHYS*2){1'b0}};
			r5_use_xa <= {(NPHYS*2){1'b0}};
		end else begin
			r1_valid <= r0_valid; r2_valid <= r1_valid; r3_valid <= r2_valid; r4_valid <= r3_valid; r5_valid <= r4_valid;
			r1_warp  <= r0_warp;  r2_warp  <= r1_warp;  r3_warp  <= r2_warp;  r4_warp  <= r3_warp;  r5_warp  <= r4_warp;
			r1_grp   <= r0_grp;   r2_grp   <= r1_grp;   r3_grp   <= r2_grp;   r4_grp   <= r3_grp;   r5_grp   <= r4_grp;
			r1_rd    <= r0_rd;    r2_rd    <= r1_rd;    r3_rd    <= r2_rd;    r4_rd    <= r3_rd;    r5_rd    <= r4_rd;
			r1_mask  <= r0_mask;  r2_mask  <= r1_mask;  r3_mask  <= r2_mask;  r4_mask  <= r3_mask;  r5_mask  <= r4_mask;
			r1_sub   <= r0_sub;   r2_sub   <= r1_sub;   r3_sub   <= r2_sub;   r4_sub   <= r3_sub;
			for (qm = 0; qm < NPHYS; qm = qm + 1) begin
				r1_xa[qm*32 +: 32] <= (r0_sub == 3'd2) ? r0_xa[(qm ^ 1)*32 +: 32] :
				                      (r0_sub == 3'd3) ? r0_xa[(qm ^ 2)*32 +: 32] :
				                      (r0_sub == 3'd4) ? r0_xa[(qm ^ 3)*32 +: 32] :
				                      r0_xa[(qm & ~3)*32 +: 32];
				r4_use_qa[qm*2 +: 2] <= {2{r3_valid && ((r3_sub == 3'd0 && (qm & 2) == 0) || (r3_sub == 3'd1 && (qm & 1) == 0))}};
				r4_use_qb[qm*2 +: 2] <= {2{r3_valid && ((r3_sub == 3'd0 && (qm & 2) != 0) || (r3_sub == 3'd1 && (qm & 1) != 0))}};
				r4_use_xa[qm*2 +: 2] <= {2{r3_valid && (r3_sub >= 3'd2)}};
			end
			r2_xa <= r1_xa; r3_xa <= r2_xa; r4_xa <= r3_xa; r5_xa <= r4_xa;
			r5_use_qa <= r4_use_qa;
			r5_use_qb <= r4_use_qb;
			r5_use_xa <= r4_use_xa;
		end
	end

	/* qd: quads inside the group: lane l's partners l^1, l^2, l^3 and l&~3.
	 * The differences x[l|1] - x[l&~1] (sub 0) and x[l|2] - x[l&~2] (sub 1)
	 * take two values per quad, so a quad has two adders: A for lanes 0
	 * and 1 (sub 0) or 0 and 2 (sub 1), B for the other two. */
	wire [DW-1:0] qa_all, qb_all;
	genvar gq, gm;
	generate
		for (gq = 0; gq < NPHYS / 4; gq = gq + 1) begin : g_qd
			wire [31:0] qa, qb;
			wire unused_qa_v, unused_qb_v;
			am_fp_add #(.LAT(5)) u_qa (
				.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
				.i_a(r0_qa_a[gq*32 +: 32]),
				.i_b(r0_qa_b[gq*32 +: 32]), .i_sub(1'b1),
				.o_valid(unused_qa_v), .o_r(qa)
			);
			am_fp_add #(.LAT(5)) u_qb (
				.clk(clk), .rst_n(rst_n), .i_valid(1'b1),
				.i_a(r0_qb_a[gq*32 +: 32]),
				.i_b(r0_qb_b[gq*32 +: 32]), .i_sub(1'b1),
				.o_valid(unused_qb_v), .o_r(qb)
			);
			for (gm = 4*gq; gm < 4*gq + 4; gm = gm + 1) begin : g_l
				assign qa_all[gm*32 +: 32] = qa;
				assign qb_all[gm*32 +: 32] = qb;
			end
		end
	endgenerate

	/* The state machine of the subgroup instructions: IDLE (groups are
	 * staged as they pass; the last one moves to EMIT) and EMIT (group
	 * e_cnt's result enters the pipeline; x_ready in the last). */
	localparam S_IDLE = 1'b0;
	localparam S_EMIT = 1'b1;
	reg st;
	reg [GRP_W-1:0] e_cnt;
	wire e_last = {{(32-GRP_W){1'b0}}, e_cnt} == G - 1;
	wire emit = st == S_EMIT;
	wire stage = sg && st == S_IDLE;
	assign sg_emit_done = (SUBGROUP == 0) || (emit && e_last);
	assign x_ready = !(sg && x_last) || (emit && e_last);

	/* Staging, per warp lane: rs1, EXEC, and the shfl source lane (s_ok: it
	 * exists, 0..31). */
	reg [32*32-1:0] s_d;
	reg [31:0] s_ex;
	reg [31:0] s_ok;
	reg [32*5-1:0] s_src;

	/* The source lane of shfl for lane ln of the group on the bus. */
	/*
	 * Lane ln = x_grp NPHYS + l (disjoint bits); ln + rs2 or ln - rs2 (up,
	 * down) in one adder a lane.
	 */
	wire [NPHYS-1:0] c_ok;
	wire [NPHYS*5-1:0] c_src;
	wire [GRP_W-1:0] x_grp_src, x_grp_stg;
`ifdef SYNTH_KINTEX7
	genvar gxg;
	generate
		for (gxg = 0; gxg < GRP_W; gxg = gxg + 1) begin : g_xgrp_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bxgrp_src (.I0(x_grp[gxg]), .O(x_grp_src[gxg]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bxgrp_stg (.I0(x_grp[gxg]), .O(x_grp_stg[gxg]));
		end
	endgenerate
`else
	assign x_grp_src = x_grp;
	assign x_grp_stg = x_grp;
`endif
	genvar gl;
	generate
		for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_src
			/* verilator lint_off WIDTHTRUNC */
			wire [4:0] ln = ({{(32-GRP_W){1'b0}}, x_grp_src} << $clog2(NPHYS)) | gl;
			/* verilator lint_on WIDTHTRUNC */
			wire [31:0] bv = x_b[gl*32 +: 32];
			wire [2:0] sub_ctl_l = (gl / 2 < 16) ? sub_ctl_p[(gl/2)*3 +: 3] : 3'd0;
			wire [5:0] sum;
			wire co_unused;
			am_addsub #(.W(6)) u_sum (.a({1'b0, ln}), .b({1'b0, bv[4:0]}), .sub(sub_ctl_l == 3'd2),
				.s(sum), .co(co_unused));
			(* keep = "true" *) wire nz0 = |bv[9:5];
			(* keep = "true" *) wire nz1 = |bv[15:10];
			(* keep = "true" *) wire nz2 = |bv[21:16];
			(* keep = "true" *) wire nz3 = |bv[26:22];
			(* keep = "true" *) wire nz4 = |bv[31:27];
			(* keep = "true" *) wire ok_hi = ~(nz0 | nz1 | nz2 | nz3 | nz4);
			/* (local regs: one block's writes do not wake the other lanes' blocks) */
			reg ok;
			reg [4:0] src;
			always @(*) begin
				ok = ok_hi;
				case (sub_ctl_l)
				3'd0: src = bv[4:0];
				3'd2, 3'd3: begin
					src = sum[4:0];
					ok = ok_hi && !sum[5];
				end
				3'd4: begin	/* rot: (l + rs2) mod 32, always a lane */
					src = sum[4:0];
					ok = 1'b1;
				end
				default: src = ln ^ bv[4:0];	/* 1 xor */
				endcase
			end
			assign c_ok[gl] = ok;
			assign c_src[gl*5 +: 5] = src;
		end
	endgenerate

	/* Results of group e_cnt.  shfl: the source lane's rs1 when the source
	 * exists and is in EXEC, else the lane's own rs1.  ballot: the EXEC
	 * lanes whose rs1 is not 0; vote: any/all of them as a Boolean. */
	reg [31:0] bal;
	integer bl;
	always @(*) begin
		for (bl = 0; bl < 32; bl = bl + 1)
			bal[bl] = s_ex[bl] && (s_d[bl*32 +: 32] != 32'd0);
	end
	wire is_ballot = (op == ATG_LANE_BALLOT);
	wire is_vote   = (op == ATG_LANE_VOTE);
	wire vote_val  = sub_ctl_vote[0] ? (bal == s_ex) : (bal != 32'd0);
	/* shfl writes the EXEC lanes; vote and ballot every lane. */
	wire [31:0] e_base = {{(32-GRP_W){1'b0}}, e_cnt} * NPHYS;
	wire [31:0] ex_g;
	wire [GRP_W-1:0] e_cnt_next;
	wire ec_co_unused;
	am_shift #(.W(32), .SW(6)) u_ex_g (.a(s_ex), .amt(e_base[5:0]), .left(1'b0), .arith(1'b0),
		.y(ex_g));
	wire unused_eb = &{1'b0, e_base[31:6]};
	am_add #(.W(GRP_W)) u_e_cnt (.a(e_cnt), .b({GRP_W{1'b0}}), .ci(1'b1), .s(e_cnt_next),
		.co(ec_co_unused));
	wire [NPHYS-1:0] z_lanes = op == ATG_LANE_SHFL ? ex_g[NPHYS-1:0] : {NPHYS{1'b1}};

	wire [GRP_W-1:0] e_cnt_g0, e_cnt_g1;
`ifdef SYNTH_KINTEX7
	genvar gec;
	generate
		for (gec = 0; gec < GRP_W; gec = gec + 1) begin : g_ec_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ec0 (.I0(e_cnt[gec]), .O(e_cnt_g0[gec]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_ec1 (.I0(e_cnt[gec]), .O(e_cnt_g1[gec]));
		end
	endgenerate
`else
	assign e_cnt_g0 = e_cnt;
	assign e_cnt_g1 = e_cnt;
`endif

	/* Sliced shuffle data multiplexers per lane and per 2-bit pair */
	wire [15:0] z_h [0:NPHYS*2-1];
	genvar gzl, gzh, gzp;
	generate
		for (gzl = 0; gzl < NPHYS; gzl = gzl + 1) begin: g_shfl_lane
			wire [GRP_W-1:0] e_cnt_lane = (gzl < NPHYS/2) ? e_cnt_g0 : e_cnt_g1;
			wire [GRP_W-1:0] ec_es, ec_h0, ec_h1;
`ifdef SYNTH_KINTEX7
			genvar gec;
			for (gec = 0; gec < GRP_W; gec = gec + 1) begin : g_ec_lane_buf
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bec_es (.I0(e_cnt_lane[gec]), .O(ec_es[gec]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bec_h0 (.I0(e_cnt_lane[gec]), .O(ec_h0[gec]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bec_h1 (.I0(e_cnt_lane[gec]), .O(ec_h1[gec]));
			end
`else
			assign ec_es = e_cnt_lane;
			assign ec_h0 = e_cnt_lane;
			assign ec_h1 = e_cnt_lane;
`endif
			/* verilator lint_off WIDTHTRUNC */
			/* verilator lint_off WIDTHEXPAND */
			wire [4:0] el_l_es = ({{(32-GRP_W){1'b0}}, ec_es} << $clog2(NPHYS)) | {27'd0, gzl[4:0]};
			wire [4:0] el_l_h0 = ({{(32-GRP_W){1'b0}}, ec_h0} << $clog2(NPHYS)) | {27'd0, gzl[4:0]};
			wire [4:0] el_l_h1 = ({{(32-GRP_W){1'b0}}, ec_h1} << $clog2(NPHYS)) | {27'd0, gzl[4:0]};
			/* verilator lint_on WIDTHEXPAND */
			/* verilator lint_on WIDTHTRUNC */
			reg [4:0] es_l;
			integer sl_idx;
			always @(*) begin
				es_l = s_src[4:0];
				for (sl_idx = 1; sl_idx < 32; sl_idx = sl_idx + 1) begin
					if (el_l_es == sl_idx[4:0])
						es_l = s_src[sl_idx*5 +: 5];
				end
			end
			wire s_ok_l = s_ok[el_l_es];
			wire s_ex_l = s_ex[es_l];
			wire sel_shfl_l = s_ok_l && s_ex_l;

			for (gzh = 0; gzh < 2; gzh = gzh + 1) begin: g_half
				wire [4:0] el_l_h = gzh[0] ? el_l_h1 : el_l_h0;
				wire [15:0] s_d_el_half = s_d[{el_l_h, gzh[0], 4'd0} +: 16];
				wire [1:0] z_pair [0:7];
				for (gzp = 0; gzp < 8; gzp = gzp + 1) begin: g_pair
					wire [4:0] es_p;
					wire sel_p;
`ifdef SYNTH_KINTEX7
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bes0 (.I0(es_l[0]), .O(es_p[0]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bes1 (.I0(es_l[1]), .O(es_p[1]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bes2 (.I0(es_l[2]), .O(es_p[2]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bes3 (.I0(es_l[3]), .O(es_p[3]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bes4 (.I0(es_l[4]), .O(es_p[4]));
					(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_bsel (.I0(sel_shfl_l), .O(sel_p));
`else
					assign es_p  = es_l;
					assign sel_p = sel_shfl_l;
`endif
					genvar gbit;
					for (gbit = 0; gbit < 2; gbit = gbit + 1) begin: g_bit
						localparam [4:0] B_IDX = {gzh[0], gzp[2:0], gbit[0]};
						localparam [3:0] BH_IDX = {gzp[2:0], gbit[0]};
						assign z_pair[gzp][gbit] = sel_p ? s_d[{es_p, B_IDX}] : s_d_el_half[BH_IDX];
					end
				end
				localparam integer H_IDX = gzl*2 + gzh;
				assign z_h[H_IDX] = {
					z_pair[7], z_pair[6], z_pair[5], z_pair[4],
					z_pair[3], z_pair[2], z_pair[1], z_pair[0]
				};
			end
		end
	endgenerate

	/* Buffered bal per half-lane */
	wire [15:0] bal_h [0:NPHYS*2-1];
	genvar g_kp, g_b16;
	generate
		for (g_kp = 0; g_kp < NPHYS*2; g_kp = g_kp + 1) begin: g_bal_h
			wire [15:0] bal_src = g_kp[0] ? bal[31:16] : bal[15:0];
`ifdef SYNTH_KINTEX7
			for (g_b16 = 0; g_b16 < 16; g_b16 = g_b16 + 1) begin: g_bal_b
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bal (.I0(bal_src[g_b16]), .O(bal_h[g_kp][g_b16]));
			end
`else
			assign bal_h[g_kp] = bal_src;
`endif
		end
	endgenerate

	(* shreg_extract = "no" *) reg [EW-1:0] pipe [0:SHORT_LAT-1];
	(* keep = "true" *) wire [DW-1:0] pipe_fb;
	(* keep = "true" *) wire [31:0] stg_we_lo, stg_we_hi;
	wire [NPHYS*2-1:0] emit_h_lo, emit_h_hi;
	wire [NPHYS*2-1:0] is_ballot_h_lo, is_ballot_h_hi;
	wire [NPHYS*2-1:0] is_vote_h_lo, is_vote_h_hi;
	wire [NPHYS*2-1:0] vote_val_h_lo, vote_val_h_hi;
	(* shreg_extract = "no" *) reg [NPHYS*2-1:0] is_ballot_d, is_vote_d;
	(* shreg_extract = "no" *) reg [15:0] bal_h_d [0:NPHYS*2-1];
	(* shreg_extract = "no" *) reg [NPHYS*2-1:0] vote_val_d;
	wire emit_ctrl;
	wire emit_h_raw = (st == S_EMIT);
	wire emit_h_raw_lo, emit_h_raw_hi;
	wire is_ballot_g0, is_ballot_g1;
	wire is_vote_g0, is_vote_g1;
	wire vote_val_g0, vote_val_g1;
`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_emit_ctrl (.I0(emit), .O(emit_ctrl));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_eraw_lo   (.I0(emit_h_raw), .O(emit_h_raw_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_eraw_hi   (.I0(emit_h_raw), .O(emit_h_raw_hi));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bg0       (.I0(is_ballot),  .O(is_ballot_g0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bg1       (.I0(is_ballot),  .O(is_ballot_g1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vt0       (.I0(is_vote),    .O(is_vote_g0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vt1       (.I0(is_vote),    .O(is_vote_g1));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vg0       (.I0(vote_val),   .O(vote_val_g0));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vg1       (.I0(vote_val),   .O(vote_val_g1));
`else
	assign emit_ctrl     = emit;
	assign emit_h_raw_lo = emit_h_raw;
	assign emit_h_raw_hi = emit_h_raw;
	assign is_ballot_g0  = is_ballot;
	assign is_ballot_g1  = is_ballot;
	assign is_vote_g0    = is_vote;
	assign is_vote_g1    = is_vote;
	assign vote_val_g0   = vote_val;
	assign vote_val_g1   = vote_val;
`endif

	genvar gp;
	generate
		for (gp = 0; gp < NPHYS * 2; gp = gp + 1) begin : g_r4v
			assign pipe_fb[gp*16 +: 16] = r4_use_xa[gp] ? r4_xa[gp*16 +: 16] : pipe[SHORT_LAT-2][gp*16 +: 16];
			wire emit_h_raw_gp = (gp < NPHYS) ? emit_h_raw_lo : emit_h_raw_hi;
			wire is_ballot_gp  = (gp < NPHYS) ? is_ballot_g0  : is_ballot_g1;
			wire is_vote_gp    = (gp < NPHYS) ? is_vote_g0    : is_vote_g1;
			wire vote_val_gp   = (gp < NPHYS) ? vote_val_g0   : vote_val_g1;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_emit_lo (.I0(emit_h_raw_gp), .O(emit_h_lo[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_emit_hi (.I0(emit_h_raw_gp), .O(emit_h_hi[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bal_lo  (.I0(is_ballot_gp),  .O(is_ballot_h_lo[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bal_hi  (.I0(is_ballot_gp),  .O(is_ballot_h_hi[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vot_lo  (.I0(is_vote_gp),    .O(is_vote_h_lo[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vot_hi  (.I0(is_vote_gp),    .O(is_vote_h_hi[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_val_lo  (.I0(vote_val_gp),   .O(vote_val_h_lo[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_val_hi  (.I0(vote_val_gp),   .O(vote_val_h_hi[gp]));
`else
			assign emit_h_lo[gp]      = emit_h_raw_gp;
			assign emit_h_hi[gp]      = emit_h_raw_gp;
			assign is_ballot_h_lo[gp] = is_ballot_gp;
			assign is_ballot_h_hi[gp] = is_ballot_gp;
			assign is_vote_h_lo[gp]   = is_vote_gp;
			assign is_vote_h_hi[gp]   = is_vote_gp;
			assign vote_val_h_lo[gp]  = vote_val_gp;
			assign vote_val_h_hi[gp]  = vote_val_gp;
`endif
		end
		wire [G-1:0] stage_grp;
		genvar gg;
		for (gg = 0; gg < G; gg = gg + 1) begin : g_stg_grp
			assign stage_grp[gg] = stage && (gg[GRP_W-1:0] == x_grp_stg);
		end
		for (gp = 0; gp < 32; gp = gp + 1) begin : g_stgw
			wire stg_cond = (gp / NPHYS < G) ? stage_grp[gp / NPHYS] : 1'b0;
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_stgw_l (.I0(stg_cond), .O(stg_we_lo[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_stgw_h (.I0(stg_cond), .O(stg_we_hi[gp]));
`else
			assign stg_we_lo[gp] = stg_cond;
			assign stg_we_hi[gp] = stg_cond;
`endif
		end
	endgenerate

	integer k, kp;
	always @(posedge clk) begin
		if (rst_p) begin
			st <= S_IDLE;
			e_cnt <= {GRP_W{1'b0}};
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
			is_ballot_d <= {(NPHYS*2){1'b0}};
			is_vote_d   <= {(NPHYS*2){1'b0}};
			vote_val_d  <= {(NPHYS*2){1'b0}};
			for (kp = 0; kp < NPHYS * 2; kp = kp + 1)
				bal_h_d[kp] <= 16'd0;
		end else begin
			if (emit_ctrl)
				pipe[0][EW-1:DW] <= {wrd, x_warp, e_cnt, x_uop[ATG_UOP_RD +: 7], z_lanes};
			else
				pipe[0][EW-1:DW] <= {(EW-DW){1'b0}};

			for (kp = 0; kp < NPHYS * 2; kp = kp + 1) begin
				is_ballot_d[kp] <= is_ballot_h_lo[kp];
				is_vote_d[kp]   <= is_vote_h_lo[kp];
				bal_h_d[kp]     <= bal_h[kp];
				vote_val_d[kp]  <= vote_val_h_lo[kp];

				if (emit_h_lo[kp])
					pipe[0][kp*16 +: 8] <= z_h[kp][7:0];
				else
					pipe[0][kp*16 +: 8] <= 8'd0;

				if (emit_h_hi[kp])
					pipe[0][kp*16 + 8 +: 8] <= z_h[kp][15:8];
				else
					pipe[0][kp*16 + 8 +: 8] <= 8'd0;
			end

			pipe[1][EW-1:DW] <= pipe[0][EW-1:DW];
			for (kp = 0; kp < NPHYS * 2; kp = kp + 1) begin
				pipe[1][kp*16 +: 8] <= is_ballot_d[kp] ? bal_h_d[kp][7:0] :
				                       is_vote_d[kp]   ? {8{vote_val_d[kp]}} :
				                       pipe[0][kp*16 +: 8];

				pipe[1][kp*16 + 8 +: 8] <= is_ballot_d[kp] ? bal_h_d[kp][15:8] :
				                          is_vote_d[kp]   ? {8{vote_val_d[kp]}} :
				                          pipe[0][kp*16 + 8 +: 8];
			end

			for (k = 2; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];

			if (stage && x_last) begin
				st <= S_EMIT;
				e_cnt <= {GRP_W{1'b0}};
			end else if (emit) begin
				if (e_last)
					st <= S_IDLE;
				else
					e_cnt <= e_cnt_next;
			end
		end
	end

	/* The staging registers (no reset: written before they are read). */
	integer m;
	always @(posedge clk) begin
		for (m = 0; m < 32; m = m + 1) begin
			if (stg_we_lo[m]) begin
				s_d[m*32 +: 16] <= x_a[(m % NPHYS)*32 +: 16];
				s_ex[m] <= x_mask[m % NPHYS];
				s_ok[m] <= c_ok[m % NPHYS];
			end
			if (stg_we_hi[m]) begin
				s_d[m*32 + 16 +: 16] <= x_a[(m % NPHYS)*32 + 16 +: 16];
				s_src[m*5 +: 5] <= c_src[(m % NPHYS)*5 +: 5];
			end
		end
	end

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = r5_valid ? 1'b1 : o[EW-1];
	assign s_warp  = r5_valid ? r5_warp : o[EW-2 -: WARP_W];
	assign s_grp   = r5_valid ? r5_grp : o[EW-2-WARP_W -: GRP_W];
	assign s_rd    = r5_valid ? r5_rd : o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = r5_valid ? r5_mask : o[DW +: NPHYS];

	genvar g_sd;
	generate
		for (g_sd = 0; g_sd < NPHYS * 2; g_sd = g_sd + 1) begin : g_s_data
			assign s_data[g_sd*16 +: 16] = r5_use_qa[g_sd] ? qa_all[g_sd*16 +: 16] :
			                               r5_use_qb[g_sd] ? qb_all[g_sd*16 +: 16] :
			                               r5_use_xa[g_sd] ? r5_xa[g_sd*16 +: 16]  :
			                               o[g_sd*16 +: 16];
		end
	endgenerate

	wire unused_ok = &{1'b0, x_sbe, x_pc, x_c, x_mask[2*NPHYS-1:NPHYS], x_info,
		x_uop, sub[4:3], ex_g, pipe_fb, (NWARPS != 0)};
endmodule


`default_nettype wire
