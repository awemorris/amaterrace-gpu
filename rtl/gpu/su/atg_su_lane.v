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

	integer qi;
	always @(posedge clk) begin
		if (rst_p) begin
			r0_valid <= 1'b0;
			r0_warp  <= {WARP_W{1'b0}};
			r0_grp   <= {GRP_W{1'b0}};
			r0_rd    <= 7'd0;
			r0_mask  <= {NPHYS{1'b0}};
			r0_sub   <= 3'd0;
			r0_xa    <= {DW{1'b0}};
			r0_qa_a  <= {((NPHYS/4)*32){1'b0}};
			r0_qa_b  <= {((NPHYS/4)*32){1'b0}};
			r0_qb_a  <= {((NPHYS/4)*32){1'b0}};
			r0_qb_b  <= {((NPHYS/4)*32){1'b0}};
		end else begin
			r0_valid <= mine;
			r0_warp  <= x_warp;
			r0_grp   <= x_grp;
			r0_rd    <= x_uop[ATG_UOP_RD +: 7];
			r0_mask  <= x_mask[NPHYS-1:0];
			r0_sub   <= sub[2:0];
			r0_xa    <= x_a;
			for (qi = 0; qi < NPHYS / 4; qi = qi + 1) begin
				r0_qa_a[qi*32 +: 32] <= sub[0] ? x_a[(4*qi + 2)*32 +: 32] : x_a[(4*qi + 1)*32 +: 32];
				r0_qa_b[qi*32 +: 32] <= x_a[(4*qi)*32 +: 32];
				r0_qb_a[qi*32 +: 32] <= x_a[(4*qi + 3)*32 +: 32];
				r0_qb_b[qi*32 +: 32] <= sub[0] ? x_a[(4*qi + 1)*32 +: 32] : x_a[(4*qi + 2)*32 +: 32];
			end
		end
	end

	/* Stage 1 to 4 pipeline match for QD control & operands (quad-swap pre-muxed at r0 -> r1) */
	(* shreg_extract = "no" *) reg r1_valid, r2_valid, r3_valid;
	(* shreg_extract = "no", max_fanout = 12 *) reg r4_valid;
	(* shreg_extract = "no" *) reg [WARP_W-1:0] r1_warp, r2_warp, r3_warp, r4_warp;
	(* shreg_extract = "no" *) reg [GRP_W-1:0]  r1_grp,  r2_grp,  r3_grp,  r4_grp;
	(* shreg_extract = "no" *) reg [6:0]        r1_rd,   r2_rd,   r3_rd,   r4_rd;
	(* shreg_extract = "no" *) reg [NPHYS-1:0]  r1_mask, r2_mask, r3_mask, r4_mask;
	(* shreg_extract = "no" *) reg [2:0]        r1_sub,  r2_sub,  r3_sub;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0] r4_sub;
	(* shreg_extract = "no" *) reg [DW-1:0]     r1_xa,   r2_xa,   r3_xa,   r4_xa;
	(* shreg_extract = "no", keep = "true", equivalent_register_removal = "no", max_fanout = 16 *) reg [NPHYS*2-1:0] r4_use_qa, r4_use_qb, r4_use_xa;

	integer qm;
	always @(posedge clk) begin
		if (rst_p) begin
			r1_valid <= 1'b0; r2_valid <= 1'b0; r3_valid <= 1'b0; r4_valid <= 1'b0;
			r1_warp  <= {WARP_W{1'b0}}; r2_warp <= {WARP_W{1'b0}}; r3_warp <= {WARP_W{1'b0}}; r4_warp <= {WARP_W{1'b0}};
			r1_grp   <= {GRP_W{1'b0}};  r2_grp  <= {GRP_W{1'b0}};  r3_grp  <= {GRP_W{1'b0}};  r4_grp  <= {GRP_W{1'b0}};
			r1_rd    <= 7'd0;           r2_rd   <= 7'd0;           r3_rd   <= 7'd0;           r4_rd   <= 7'd0;
			r1_mask  <= {NPHYS{1'b0}};  r2_mask <= {NPHYS{1'b0}};  r3_mask <= {NPHYS{1'b0}};  r4_mask <= {NPHYS{1'b0}};
			r1_sub   <= 3'd0;           r2_sub  <= 3'd0;           r3_sub  <= 3'd0;           r4_sub  <= 3'd0;
			r1_xa    <= {DW{1'b0}};     r2_xa   <= {DW{1'b0}};     r3_xa   <= {DW{1'b0}};     r4_xa   <= {DW{1'b0}};
			r4_use_qa <= {(NPHYS*2){1'b0}};
			r4_use_qb <= {(NPHYS*2){1'b0}};
			r4_use_xa <= {(NPHYS*2){1'b0}};
		end else begin
			r1_valid <= r0_valid; r2_valid <= r1_valid; r3_valid <= r2_valid; r4_valid <= r3_valid;
			r1_warp  <= r0_warp;  r2_warp  <= r1_warp;  r3_warp  <= r2_warp;  r4_warp  <= r3_warp;
			r1_grp   <= r0_grp;   r2_grp   <= r1_grp;   r3_grp   <= r2_grp;   r4_grp   <= r3_grp;
			r1_rd    <= r0_rd;    r2_rd    <= r1_rd;    r3_rd    <= r2_rd;    r4_rd    <= r3_rd;
			r1_mask  <= r0_mask;  r2_mask  <= r1_mask;  r3_mask  <= r2_mask;  r4_mask  <= r3_mask;
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
			r2_xa <= r1_xa; r3_xa <= r2_xa; r4_xa <= r3_xa;
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
			atg_su_lane_fsub u_qa (
				.clk(clk), .rst_n(rst_n),
				.i_a(r0_qa_a[gq*32 +: 32]),
				.i_b(r0_qa_b[gq*32 +: 32]),
				.o_r(qa)
			);
			atg_su_lane_fsub u_qb (
				.clk(clk), .rst_n(rst_n),
				.i_a(r0_qb_a[gq*32 +: 32]),
				.i_b(r0_qb_b[gq*32 +: 32]),
				.o_r(qb)
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
	(* max_fanout = 12 *) reg st;
	(* max_fanout = 12 *) reg [GRP_W-1:0] e_cnt;
	wire e_last = {{(32-GRP_W){1'b0}}, e_cnt} == G - 1;
	(* max_fanout = 12 *) wire emit = st == S_EMIT;
	(* max_fanout = 12 *) wire stage = sg && st == S_IDLE;
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
	genvar gl;
	generate
		for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_src
			/* verilator lint_off WIDTHTRUNC */
			wire [4:0] ln = ({{(32-GRP_W){1'b0}}, x_grp} << $clog2(NPHYS)) | gl;
			/* verilator lint_on WIDTHTRUNC */
			wire [31:0] bv = x_b[gl*32 +: 32];
			wire [5:0] sum;
			wire co_unused;
			am_addsub #(.W(6)) u_sum (.a({1'b0, ln}), .b({1'b0, bv[4:0]}), .sub(sub[2:0] == 3'd2),
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
				case (sub[2:0])
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
	reg [DW-1:0] z;
	reg [4:0] el, es;
	integer sl, l;
	always @(*) begin
		for (l = 0; l < 32; l = l + 1)
			bal[l] = s_ex[l] && s_d[l*32 +: 32] != 32'd0;
		for (l = 0; l < NPHYS; l = l + 1) begin
			/* verilator lint_off WIDTHTRUNC */
			el = ({{(32-GRP_W){1'b0}}, e_cnt} << $clog2(NPHYS)) | l;
			/* verilator lint_on WIDTHTRUNC */
			es = s_src[4:0];
			for (sl = 1; sl < 32; sl = sl + 1)
				if (el == sl[4:0])
					es = s_src[sl*5 +: 5];
			z[l*32 +: 32] = s_ok[el] && s_ex[es] ? s_d[es*32 +: 32] : s_d[el*32 +: 32];
		end
	end
	wire is_ballot = (op == ATG_LANE_BALLOT);
	wire is_vote   = (op == ATG_LANE_VOTE);
	wire vote_val  = sub[0] ? (bal == s_ex) : (bal != 32'd0);
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

	(* shreg_extract = "no" *) reg [EW-1:0] pipe [0:SHORT_LAT-1];
	(* keep = "true" *) wire [DW-1:0] pipe_fb;
	(* keep = "true" *) wire [31:0] stg_we_lo, stg_we_hi;
	(* keep = "true" *) wire [NPHYS*2-1:0] emit_h;
	wire [NPHYS*2-1:0] is_ballot_h, is_vote_h, vote_val_h;
	(* keep = "true" *) wire emit_ctrl = emit;
	wire emit_h_raw = (st == S_EMIT);
	genvar gp;
	generate
		for (gp = 0; gp < NPHYS * 2; gp = gp + 1) begin : g_r4v
			assign pipe_fb[gp*16 +: 16] = r4_use_xa[gp] ? r4_xa[gp*16 +: 16] : pipe[SHORT_LAT-2][gp*16 +: 16];
`ifdef SYNTH_KINTEX7
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_emit (.I0(emit_h_raw), .O(emit_h[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_bal  (.I0(is_ballot),  .O(is_ballot_h[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_vot  (.I0(is_vote),    .O(is_vote_h[gp]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_val  (.I0(vote_val),   .O(vote_val_h[gp]));
`else
			assign emit_h[gp]      = emit_h_raw;
			assign is_ballot_h[gp] = is_ballot;
			assign is_vote_h[gp]   = is_vote;
			assign vote_val_h[gp]  = vote_val;
`endif
		end
		for (gp = 0; gp < 32; gp = gp + 1) begin : g_stgw
			assign stg_we_lo[gp] = stage && (gp / NPHYS == {{(32-GRP_W){1'b0}}, x_grp});
			assign stg_we_hi[gp] = stage && (gp / NPHYS == {{(32-GRP_W){1'b0}}, x_grp});
		end
	endgenerate
	integer k, kp;
	always @(posedge clk) begin
		if (rst_p) begin
			st <= S_IDLE;
			e_cnt <= {GRP_W{1'b0}};
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			if (emit_ctrl)
				pipe[0][EW-1:DW] <= {wrd, x_warp, e_cnt, x_uop[ATG_UOP_RD +: 7], z_lanes};
			else
				pipe[0][EW-1:DW] <= {(EW-DW){1'b0}};
			for (kp = 0; kp < NPHYS * 2; kp = kp + 1) begin
				if (emit_h[kp])
					pipe[0][kp*16 +: 16] <= is_ballot_h[kp] ? bal[kp[0]*16 +: 16] :
					                        is_vote_h[kp]   ? {16{vote_val_h[kp]}} :
					                        z[kp*16 +: 16];
				else
					pipe[0][kp*16 +: 16] <= 16'd0;
			end

			for (k = 1; k < SHORT_LAT - 1; k = k + 1)
				pipe[k] <= pipe[k-1];

			pipe[SHORT_LAT-1][EW-1:DW] <= r4_valid ?
				{1'b1, r4_warp, r4_grp, r4_rd, r4_mask} :
				pipe[SHORT_LAT-2][EW-1:DW];
			for (kp = 0; kp < NPHYS * 2; kp = kp + 1) begin
				pipe[SHORT_LAT-1][kp*16 +: 16] <= r4_use_qa[kp] ? qa_all[kp*16 +: 16] :
					(r4_use_qb[kp] ? qb_all[kp*16 +: 16] : pipe_fb[kp*16 +: 16]);
			end
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
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];

	wire unused_ok = &{1'b0, x_sbe, x_pc, x_c, x_mask[2*NPHYS-1:NPHYS], x_info,
		x_uop, sub[4:3], ex_g, (NWARPS != 0)};
endmodule

/*
 * atg_su_lane_fsub: 4-stage registered fp32 subtractor (i_a - i_b) for atg_su_lane's
 * quad derivatives (qd). Takes registered Stage 0 inputs (r0_*) and outputs o_r at Stage 4
 * (r4_*) with <= 1 Pre/Post-CARRY LUTs and <= 4 logic levels per stage.
 */
module atg_su_lane_fsub (
	input wire clk,
	input wire rst_n,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire [31:0] o_r
);
	(* dont_touch = "true" *) wire rst_p = !rst_n;

	/* Pure-LUT 5-bit decrementer (0 CARRY4) */
	function [4:0] dec5;
		input [4:0] a;
		begin
			dec5[0] = ~a[0];
			dec5[1] = a[1] ^ ~a[0];
			dec5[2] = a[2] ^ (~a[1] & ~a[0]);
			dec5[3] = a[3] ^ (~a[2] & ~a[1] & ~a[0]);
			dec5[4] = a[4] ^ (~a[3] & ~a[2] & ~a[1] & ~a[0]);
		end
	endfunction

	/* Pure-LUT 5-bit constant + 3-bit offset (0 CARRY4, 1 LUT3 per bit) */
	function [4:0] add5_c3;
		input [4:0] c;
		input [2:0] sh;
		reg c0, c1, c2, c3;
		begin
			c0 = c[0] & sh[0];
			c1 = (c[1] & sh[1]) | ((c[1] ^ sh[1]) & c0);
			c2 = (c[2] & sh[2]) | ((c[2] ^ sh[2]) & c1);
			c3 = c[3] & c2;
			add5_c3 = {
				c[4] ^ c3,
				c[3] ^ c2,
				c[2] ^ sh[2] ^ c1,
				c[1] ^ sh[1] ^ c0,
				c[0] ^ sh[0]
			};
		end
	endfunction

	/* Pure-LUT 6-bit leading-one shift amount 0..5 (0 CARRY4, 1 LUT6 per bit) */
	function [2:0] f_sh3;
		input [5:0] b;
		begin
			if (b[5])      f_sh3 = 3'd0;
			else if (b[4]) f_sh3 = 3'd1;
			else if (b[3]) f_sh3 = 3'd2;
			else if (b[2]) f_sh3 = 3'd3;
			else if (b[1]) f_sh3 = 3'd4;
			else           f_sh3 = 3'd5;
		end
	endfunction

	/* Pure-LUT 10-bit incrementer (0 CARRY4) */
	function [9:0] inc10;
		input [9:0] a;
		reg [4:0] lo, hi;
		reg c5;
		begin
			lo[0] = ~a[0];
			lo[1] = a[1] ^ a[0];
			lo[2] = a[2] ^ (&a[1:0]);
			lo[3] = a[3] ^ (&a[2:0]);
			lo[4] = a[4] ^ (&a[3:0]);
			c5 = &a[4:0];
			hi[0] = a[5] ^ c5;
			hi[1] = a[6] ^ (a[5] & c5);
			hi[2] = a[7] ^ ((&a[6:5]) & c5);
			hi[3] = a[8] ^ ((&a[7:5]) & c5);
			hi[4] = a[9] ^ ((&a[8:5]) & c5);
			inc10 = {hi, lo};
		end
	endfunction

	/* Pure-LUT 3-bit subtractor with carry-in: {c3, s[2:0]} = a[2:0] + ~b[2:0] + ci (1 LUT6) */
	function [3:0] sub3_ci;
		input [2:0] a;
		input [2:0] b;
		input ci;
		reg [2:0] bn;
		reg c0, c1, c2, c3;
		reg [2:0] s;
		begin
			bn = ~b;
			c0 = ci;
			s[0] = a[0] ^ bn[0] ^ c0;
			c1 = (a[0] & bn[0]) | ((a[0] ^ bn[0]) & c0);
			s[1] = a[1] ^ bn[1] ^ c1;
			c2 = (a[1] & bn[1]) | ((a[1] ^ bn[1]) & c1);
			s[2] = a[2] ^ bn[2] ^ c2;
			c3 = (a[2] & bn[2]) | ((a[2] ^ bn[2]) & c2);
			sub3_ci = {c3, s};
		end
	endfunction

	/* Pure-LUT upper 7-bit subtractor from c3: {ehi[4:0], s[4:3]} (6 inputs per bit = 1 LUT6) */
	function [6:0] sub2_hi;
		input [4:0] a_hi;      /* s3_ex[7:3] */
		input [4:0] a_hi_m1;   /* s3_ex_hi_m1[4:0] */
		input [1:0] b_hi;      /* s3_lz[4:3] */
		input c3;
		reg [1:0] bn;
		reg c4, c5;
		reg [1:0] s;
		reg [4:0] ehi;
		begin
			bn = ~b_hi;
			s[0] = a_hi[0] ^ bn[0] ^ c3;
			c4 = (a_hi[0] & bn[0]) | ((a_hi[0] ^ bn[0]) & c3);
			s[1] = a_hi[1] ^ bn[1] ^ c4;
			c5 = (a_hi[1] & bn[1]) | ((a_hi[1] ^ bn[1]) & c4);
			ehi = c5 ? {2'b00, a_hi[4:2]} : a_hi_m1;
			sub2_hi = {ehi, s};
		end
	endfunction

	/* Pure-LUT 5-bit slice incrementer (0 CARRY4, 1 LUT6 per bit) */
	function [4:0] inc5_ci;
		input [4:0] a;
		input ci;
		begin
			inc5_ci[0] = a[0] ^ ci;
			inc5_ci[1] = a[1] ^ (a[0] & ci);
			inc5_ci[2] = a[2] ^ ((&a[1:0]) & ci);
			inc5_ci[3] = a[3] ^ ((&a[2:0]) & ci);
			inc5_ci[4] = a[4] ^ ((&a[3:0]) & ci);
		end
	endfunction

	/* =====================================================================
	 * Stage 1 (r0 -> s1): Parallel exponent & mantissa subtractors (pre=1, post=0)
	 * ===================================================================== */
	wire [31:0] b_in = {~i_b[31], i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];
	wire za = (ea == 8'd0);
	wire zb = (eb == 8'd0);
	wire nan_a = (ea == 8'hFF) && (i_a[22:0] != 23'd0);
	wire nan_b = (eb == 8'hFF) && (b_in[22:0] != 23'd0);
	wire inf_a = (ea == 8'hFF) && (i_a[22:0] == 23'd0);
	wire inf_b = (eb == 8'hFF) && (b_in[22:0] == 23'd0);

	wire [7:0] eab, eba;
	wire [22:0] mab_unused;
	wire eab_bo, eba_bo, mab_bo;
	am_sub #(.W(8))  u_eab (.a(ea),        .b(eb),        .bi(1'b0), .d(eab),        .bo(eab_bo));
	am_sub #(.W(8))  u_eba (.a(eb),        .b(ea),        .bi(1'b0), .d(eba),        .bo(eba_bo));
	am_sub #(.W(23)) u_mab (.a(i_a[22:0]), .b(b_in[22:0]), .bi(1'b0), .d(mab_unused), .bo(mab_bo));

	wire sp1_w = nan_a || nan_b || inf_a || inf_b || (za && zb);
	wire [31:0] spv1_w = (nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31])) ? 32'h7FC00000 :
		inf_a ? {i_a[31], 8'hFF, 23'd0} :
		inf_b ? {b_in[31], 8'hFF, 23'd0} :
		{i_a[31] && b_in[31], 31'd0};

	(* max_fanout = 12 *) reg        s1_sp, s1_za, s1_zb, s1_eab_bo, s1_eba_bo, s1_mab_bo;
	(* shreg_extract = "no" *) reg [31:0] s1_spv, s1_a, s1_b;
	(* max_fanout = 12 *) reg [7:0]  s1_eab, s1_eba;

	always @(posedge clk) begin
		if (rst_p) begin
			s1_sp     <= 1'b0;
			s1_za     <= 1'b0;
			s1_zb     <= 1'b0;
			s1_eab_bo <= 1'b0;
			s1_eba_bo <= 1'b0;
			s1_mab_bo <= 1'b0;
			s1_spv    <= 32'd0;
			s1_a      <= 32'd0;
			s1_b      <= 32'd0;
			s1_eab    <= 8'd0;
			s1_eba    <= 8'd0;
		end else begin
			s1_sp     <= sp1_w;
			s1_za     <= za;
			s1_zb     <= zb;
			s1_eab_bo <= eab_bo;
			s1_eba_bo <= eba_bo;
			s1_mab_bo <= mab_bo;
			s1_spv    <= spv1_w;
			s1_a      <= i_a;
			s1_b      <= b_in;
			s1_eab    <= eab;
			s1_eba    <= eba;
		end
	end

	/* =====================================================================
	 * Stage 2 (s1 -> s2): Parallel alignment shifts & operand swap (0 CARRY4)
	 * ===================================================================== */
	(* max_fanout = 12 *) wire s1_a_big = (s1_za && s1_zb) ? 1'b1 :
	                s1_za ? 1'b0 :
	                s1_zb ? 1'b1 :
	                (!s1_eab_bo && (s1_eba_bo || !s1_mab_bo));

	wire [26:0] s1_shi_a = {s1_za ? 24'd0 : {1'b1, s1_a[22:0]}, 3'b000};
	wire [26:0] s1_shi_b = {s1_zb ? 24'd0 : {1'b1, s1_b[22:0]}, 3'b000};

	wire [26:0] s1_shr_b, s1_shr_a, s1_smk_b, s1_smk_a;
	am_shift #(.W(27), .SW(5)) u_shr_b (.a(s1_shi_b),     .amt(s1_eab[4:0]), .left(1'b0), .arith(1'b0), .y(s1_shr_b));
	am_shift #(.W(27), .SW(5)) u_shr_a (.a(s1_shi_a),     .amt(s1_eba[4:0]), .left(1'b0), .arith(1'b0), .y(s1_shr_a));
	am_shift #(.W(27), .SW(5)) u_smk_b (.a(27'h7FFFFFF),  .amt(s1_eab[4:0]), .left(1'b1), .arith(1'b0), .y(s1_smk_b));
	am_shift #(.W(27), .SW(5)) u_smk_a (.a(27'h7FFFFFF),  .amt(s1_eba[4:0]), .left(1'b1), .arith(1'b0), .y(s1_smk_a));

	(* max_fanout = 12 *) wire s1_big_b = s1_zb || (s1_eab >= 8'd27);
	(* max_fanout = 12 *) wire s1_big_a = s1_za || (s1_eba >= 8'd27);
	wire [26:0] s1_sh_b = s1_big_b ? 27'd0 : s1_shr_b;
	wire [26:0] s1_sh_a = s1_big_a ? 27'd0 : s1_shr_a;
	wire s1_stk_b = s1_zb ? 1'b0 : (s1_eab >= 8'd27) ? 1'b1 : |(s1_shi_b & ~s1_smk_b);
	wire s1_stk_a = s1_za ? 1'b0 : (s1_eba >= 8'd27) ? 1'b1 : |(s1_shi_a & ~s1_smk_a);

	wire [26:0] s1_py_b = {s1_sh_b[26:1], s1_sh_b[0] | s1_stk_b};
	wire [26:0] s1_py_a = {s1_sh_a[26:1], s1_sh_a[0] | s1_stk_a};

	(* shreg_extract = "no", max_fanout = 12 *) reg        s2_sp, s2_sx, s2_sub;
	(* shreg_extract = "no" *) reg [31:0] s2_spv;
	(* shreg_extract = "no", max_fanout = 12 *) reg [7:0]  s2_ex;
	(* shreg_extract = "no" *) reg [26:0] s2_px, s2_py;

	always @(posedge clk) begin
		if (rst_p) begin
			s2_sp  <= 1'b0;
			s2_sx  <= 1'b0;
			s2_sub <= 1'b0;
			s2_spv <= 32'd0;
			s2_ex  <= 8'd0;
			s2_px  <= 27'd0;
			s2_py  <= 27'd0;
		end else begin
			s2_sp  <= s1_sp;
			s2_sx  <= s1_a_big ? s1_a[31] : s1_b[31];
			s2_sub <= s1_a[31] != s1_b[31];
			s2_spv <= s1_spv;
			s2_ex  <= s1_a_big ? s1_a[30:23] : s1_b[30:23];
			s2_px  <= s1_a_big ? s1_shi_a : s1_shi_b;
			s2_py  <= s1_a_big ? s1_py_b  : s1_py_a;
		end
	end

	/* =====================================================================
	 * Stage 3 (s2 -> s3): Mantissa add/sub (pre=1, post=1 around CARRY4)
	 * ===================================================================== */
	(* keep = "true" *) wire [27:0] s2_sum;
	wire s2_sum_co_unused;
	am_addsub #(.W(28)) u_sum (
		.a({1'b0, s2_px}), .b({1'b0, s2_py}), .sub(s2_sub), .s(s2_sum), .co(s2_sum_co_unused)
	);

	(* shreg_extract = "no" *) reg        s3_sp, s3_sx;
	(* shreg_extract = "no" *) reg [31:0] s3_spv;
	(* shreg_extract = "no", max_fanout = 12 *) reg [7:0]  s3_ex;
	(* shreg_extract = "no", max_fanout = 12 *) reg [4:0]  s3_ex_hi_m1;
	(* shreg_extract = "no" *) reg [9:0]  s3_ex_p1, s3_ex_p2;
	(* shreg_extract = "no" *) reg        s3_exp1_ovf, s3_exp2_ovf;
	(* shreg_extract = "no", max_fanout = 12 *) reg [27:0] s3_sum;
	(* shreg_extract = "no", max_fanout = 12 *) reg        s3_nz4, s3_nz3, s3_nz2, s3_nz1, s3_nz0;
	(* shreg_extract = "no", max_fanout = 12 *) reg [1:0]  s3_sh4;
	(* shreg_extract = "no", max_fanout = 12 *) reg [2:0]  s3_sh3, s3_sh2, s3_sh1, s3_sh0;

	wire [9:0] s2_ex_p1_w = inc10({2'b00, s2_ex});
	wire [9:0] s2_ex_p2_w = inc10(s2_ex_p1_w);

	always @(posedge clk) begin
		if (rst_p) begin
			s3_sp       <= 1'b0;
			s3_sx       <= 1'b0;
			s3_spv      <= 32'd0;
			s3_ex       <= 8'd0;
			s3_ex_hi_m1 <= 5'd0;
			s3_ex_p1    <= 10'd0;
			s3_ex_p2    <= 10'd0;
			s3_exp1_ovf <= 1'b0;
			s3_exp2_ovf <= 1'b0;
			s3_sum      <= 28'd0;
			s3_nz4      <= 1'b0;
			s3_nz3      <= 1'b0;
			s3_nz2      <= 1'b0;
			s3_nz1      <= 1'b0;
			s3_nz0      <= 1'b0;
			s3_sh4      <= 2'd0;
			s3_sh3      <= 3'd0;
			s3_sh2      <= 3'd0;
			s3_sh1      <= 3'd0;
			s3_sh0      <= 3'd0;
		end else begin
			s3_sp       <= s2_sp;
			s3_sx       <= s2_sx;
			s3_spv      <= s2_spv;
			s3_ex       <= s2_ex;
			s3_ex_hi_m1 <= dec5({2'b00, s2_ex[7:5]});
			s3_ex_p1    <= s2_ex_p1_w;
			s3_ex_p2    <= s2_ex_p2_w;
			s3_exp1_ovf <= (s2_ex >= 8'd254);
			s3_exp2_ovf <= (s2_ex >= 8'd253);
			s3_sum      <= s2_sum;
			s3_nz4      <= |s2_sum[26:24];
			s3_nz3      <= |s2_sum[23:18];
			s3_nz2      <= |s2_sum[17:12];
			s3_nz1      <= |s2_sum[11:6];
			s3_nz0      <= |s2_sum[5:0];
			s3_sh4      <= s2_sum[26] ? 2'd0 : (s2_sum[25] ? 2'd1 : 2'd2);
			s3_sh3      <= f_sh3(s2_sum[23:18]);
			s3_sh2      <= f_sh3(s2_sum[17:12]);
			s3_sh1      <= f_sh3(s2_sum[11:6]);
			s3_sh0      <= f_sh3(s2_sum[5:0]);
		end
	end

	/* =====================================================================
	 * Stage 4 (s3 -> s4): 4-LUT block normalizer & exponent subtract (0 CARRY4)
	 * ===================================================================== */
	/* Level 1 from s3_*_reg */
	(* keep = "true" *) wire s3_use_47_lo = s3_sum[27] || s3_nz4;
	(* keep = "true" *) wire s3_use_47_hi = s3_sum[27] || s3_nz4;
	(* keep = "true" *) wire [1:0] s3_bsel_lo = (s3_sum[27] || s3_nz4 || s3_nz3) ? 2'd3 :
		(s3_nz2 ? 2'd2 : (s3_nz1 ? 2'd1 : 2'd0));
	(* keep = "true" *) wire [1:0] s3_bsel_hi = (s3_sum[27] || s3_nz4 || s3_nz3) ? 2'd3 :
		(s3_nz2 ? 2'd2 : (s3_nz1 ? 2'd1 : 2'd0));
	(* keep = "true" *) wire [1:0] s3_bsel_lz = (s3_sum[27] || s3_nz4 || s3_nz3) ? 2'd3 :
		(s3_nz2 ? 2'd2 : (s3_nz1 ? 2'd1 : 2'd0));
	(* keep = "true" *) wire [26:0] s3_n_47 = s3_sum[27] ? {s3_sum[27:2], s3_sum[1] | s3_sum[0]} :
		(s3_sh4 == 2'd0 ? s3_sum[26:0] : (s3_sh4 == 2'd1 ? {s3_sum[25:0], 1'b0} : {s3_sum[24:0], 2'b00}));

	wire [26:0] w3_in = {s3_sum[23:0], 3'd0};
	wire [26:0] w2_in = {s3_sum[17:0], 9'd0};
	wire [26:0] w1_in = {s3_sum[11:0], 15'd0};
	wire [26:0] w0_in = {s3_sum[5:0], 21'd0};

	(* keep = "true" *) wire [26:0] w3_03 = s3_sh3[1] ? (s3_sh3[0] ? {w3_in[23:0], 3'd0} : {w3_in[24:0], 2'd0}) : (s3_sh3[0] ? {w3_in[25:0], 1'd0} : w3_in);
	(* keep = "true" *) wire [26:0] w3_45 = s3_sh3[0] ? {w3_in[21:0], 5'd0} : {w3_in[22:0], 4'd0};
	(* keep = "true" *) wire [26:0] w2_03 = s3_sh2[1] ? (s3_sh2[0] ? {w2_in[23:0], 3'd0} : {w2_in[24:0], 2'd0}) : (s3_sh2[0] ? {w2_in[25:0], 1'd0} : w2_in);
	(* keep = "true" *) wire [26:0] w2_45 = s3_sh2[0] ? {w2_in[21:0], 5'd0} : {w2_in[22:0], 4'd0};
	(* keep = "true" *) wire [26:0] w1_03 = s3_sh1[1] ? (s3_sh1[0] ? {w1_in[23:0], 3'd0} : {w1_in[24:0], 2'd0}) : (s3_sh1[0] ? {w1_in[25:0], 1'd0} : w1_in);
	(* keep = "true" *) wire [26:0] w1_45 = s3_sh1[0] ? {w1_in[21:0], 5'd0} : {w1_in[22:0], 4'd0};
	(* keep = "true" *) wire [26:0] w0_03 = s3_sh0[1] ? (s3_sh0[0] ? {w0_in[23:0], 3'd0} : {w0_in[24:0], 2'd0}) : (s3_sh0[0] ? {w0_in[25:0], 1'd0} : w0_in);
	(* keep = "true" *) wire [26:0] w0_45 = s3_sh0[0] ? {w0_in[21:0], 5'd0} : {w0_in[22:0], 4'd0};

	(* keep = "true" *) wire [4:0] lz_43   = s3_nz4 ? {3'b000, s3_sh4}       : add5_c3(5'd3,  s3_sh3);
	(* keep = "true" *) wire [4:0] lz_2    = add5_c3(5'd9,  s3_sh2);
	(* keep = "true" *) wire [4:0] lz_1    = add5_c3(5'd15, s3_sh1);
	(* keep = "true" *) wire [4:0] lz_0    = add5_c3(5'd21, s3_sh0);
	(* keep = "true" *) wire [4:0] lzm1_43 = s3_nz4 ? dec5({3'b000, s3_sh4}) : add5_c3(5'd2,  s3_sh3);
	(* keep = "true" *) wire [4:0] lzm1_2  = add5_c3(5'd8,  s3_sh2);
	(* keep = "true" *) wire [4:0] lzm1_1  = add5_c3(5'd14, s3_sh1);
	(* keep = "true" *) wire [4:0] lzm1_0  = add5_c3(5'd20, s3_sh0);

	/* Level 2 */
	(* keep = "true" *) wire [26:0] s3_n3_47 = {
		s3_use_47_hi ? s3_n_47[26:14] : (s3_sh3[2] ? w3_45[26:14] : w3_03[26:14]),
		s3_use_47_lo ? s3_n_47[13:0]  : (s3_sh3[2] ? w3_45[13:0]  : w3_03[13:0])
	};
	(* keep = "true" *) wire [26:0] s3_n2    = s3_sh2[2] ? w2_45 : w2_03;
	(* keep = "true" *) wire [26:0] s3_n1    = s3_sh1[2] ? w1_45 : w1_03;
	(* keep = "true" *) wire [26:0] s3_n0    = s3_sh0[2] ? w0_45 : w0_03;
	(* keep = "true" *) wire [4:0]  s3_lz    = (s3_bsel_lz == 2'd3) ? lz_43   : ((s3_bsel_lz == 2'd2) ? lz_2   : ((s3_bsel_lz == 2'd1) ? lz_1   : lz_0));
	(* keep = "true" *) wire [4:0]  s3_lz_m1 = (s3_bsel_lz == 2'd3) ? lzm1_43 : ((s3_bsel_lz == 2'd2) ? lzm1_2 : ((s3_bsel_lz == 2'd1) ? lzm1_1 : lzm1_0));

	/* Level 3 */
	(* keep = "true" *) wire [26:0] s3_n_comb = {
		(s3_bsel_hi == 2'd3) ? s3_n3_47[26:14] : ((s3_bsel_hi == 2'd2) ? s3_n2[26:14] : ((s3_bsel_hi == 2'd1) ? s3_n1[26:14] : s3_n0[26:14])),
		(s3_bsel_lo == 2'd3) ? s3_n3_47[13:0]  : ((s3_bsel_lo == 2'd2) ? s3_n2[13:0]  : ((s3_bsel_lo == 2'd1) ? s3_n1[13:0]  : s3_n0[13:0]))
	};
	(* keep = "true" *) wire [3:0] s3_sub0_lo = sub3_ci(s3_ex[2:0], s3_lz[2:0],    1'b1);
	(* keep = "true" *) wire [3:0] s3_sub1_lo = sub3_ci(s3_ex[2:0], s3_lz_m1[2:0], 1'b1);

	/* Level 4 -> s4_*_reg */
	wire [6:0] s3_sub0_hi = sub2_hi(s3_ex[7:3], s3_ex_hi_m1, s3_lz[4:3],    s3_sub0_lo[3]);
	wire [6:0] s3_sub1_hi = sub2_hi(s3_ex[7:3], s3_ex_hi_m1, s3_lz_m1[4:3], s3_sub1_lo[3]);

	(* shreg_extract = "no", max_fanout = 16 *) reg        s4_sp, s4_sx, s4_sz, s4_sum27, s4_lz_z;
	(* shreg_extract = "no" *) reg [31:0] s4_spv;
	(* shreg_extract = "no" *) reg [9:0]  s4_ex_p1, s4_ex_p2, s4_esub0, s4_esub1;
	(* shreg_extract = "no" *) reg        s4_exp1_ovf, s4_exp2_ovf;
	(* shreg_extract = "no", max_fanout = 16 *) reg [26:0] s4_n;
	(* shreg_extract = "no", max_fanout = 16 *) reg        s4_inc_r;
	(* shreg_extract = "no", max_fanout = 16 *) reg        s4_a0, s4_a1, s4_a2, s4_a3;
	(* shreg_extract = "no", max_fanout = 16 *) reg        s4_g01, s4_g12, s4_g23, s4_g34;

	always @(posedge clk) begin
		if (rst_p) begin
			s4_sp       <= 1'b0;
			s4_sx       <= 1'b0;
			s4_sz       <= 1'b0;
			s4_sum27    <= 1'b0;
			s4_lz_z     <= 1'b0;
			s4_spv      <= 32'd0;
			s4_ex_p1    <= 10'd0;
			s4_ex_p2    <= 10'd0;
			s4_esub0    <= 10'd0;
			s4_esub1    <= 10'd0;
			s4_exp1_ovf <= 1'b0;
			s4_exp2_ovf <= 1'b0;
			s4_n        <= 27'd0;
			s4_inc_r    <= 1'b0;
			s4_a0       <= 1'b0;
			s4_a1       <= 1'b0;
			s4_a2       <= 1'b0;
			s4_a3       <= 1'b0;
			s4_g01      <= 1'b0;
			s4_g12      <= 1'b0;
			s4_g23      <= 1'b0;
			s4_g34      <= 1'b0;
		end else begin
			s4_sp       <= s3_sp;
			s4_sx       <= s3_sx;
			s4_sz       <= !s3_sum[27] && !s3_nz4 && !s3_nz3 && !s3_nz2 && !s3_nz1 && !s3_nz0;
			s4_sum27    <= s3_sum[27];
			s4_lz_z     <= s3_nz4 && (s3_sh4 == 2'd0);
			s4_spv      <= s3_spv;
			s4_ex_p1    <= s3_ex_p1;
			s4_ex_p2    <= s3_ex_p2;
			s4_esub0    <= {s3_sub0_hi, s3_sub0_lo[2:0]};
			s4_esub1    <= {s3_sub1_hi, s3_sub1_lo[2:0]};
			s4_exp1_ovf <= s3_exp1_ovf;
			s4_exp2_ovf <= s3_exp2_ovf;
			s4_n        <= s3_n_comb;
			s4_inc_r    <= s3_n_comb[2] && (s3_n_comb[1] || s3_n_comb[0] || s3_n_comb[3]);
			s4_a0       <= &s3_n_comb[7:3];
			s4_a1       <= &s3_n_comb[12:8];
			s4_a2       <= &s3_n_comb[17:13];
			s4_a3       <= &s3_n_comb[22:18];
			s4_g01      <= &s3_n_comb[8:3];
			s4_g12      <= &s3_n_comb[14:9];
			s4_g23      <= &s3_n_comb[20:15];
			s4_g34      <= &s3_n_comb[26:21];
		end
	end

	/* =====================================================================
	 * Stage 5 (s4 -> o_r -> pipe[5]): 3-LUT rounding & pack + 1-LUT pipe mux
	 * ===================================================================== */
	/* Level 1 from s4_*_reg */
	(* keep = "true" *) wire s4_ci1   = s4_inc_r && s4_a0;
	(* keep = "true" *) wire s4_ci2   = s4_inc_r && s4_a0 && s4_a1;
	(* keep = "true" *) wire s4_ci3   = s4_inc_r && s4_a0 && s4_a1 && s4_a2;
	(* keep = "true" *) wire s4_ci4   = s4_inc_r && s4_a0 && s4_a1 && s4_a2 && s4_a3;
	(* keep = "true" *) wire s4_m_ovf = s4_inc_r && s4_g01 && s4_g12 && s4_g23 && s4_g34;

	(* keep = "true" *) wire [7:0] s4_e0_b = s4_sum27 ? s4_ex_p1[7:0] : s4_esub0[7:0];
	(* keep = "true" *) wire [7:0] s4_e1_b = s4_sum27 ? s4_ex_p2[7:0] : (s4_lz_z ? s4_ex_p1[7:0] : s4_esub1[7:0]);
	(* keep = "true" *) wire esub0_hi_all1 = &s4_esub0[7:4];
	(* keep = "true" *) wire esub0_lo_all1 = &s4_esub0[3:0];
	(* keep = "true" *) wire esub0_hi_nz   = !s4_sz && (|s4_esub0[7:4]);
	(* keep = "true" *) wire esub0_lo_nz   = !s4_sz && (|s4_esub0[3:0]);
	(* keep = "true" *) wire esub1_hi_all1 = &s4_esub1[7:4];
	(* keep = "true" *) wire esub1_lo_all1 = &s4_esub1[3:0];
	(* keep = "true" *) wire esub1_hi_nz   = !s4_sz && (|s4_esub1[7:4]);
	(* keep = "true" *) wire esub1_lo_nz   = !s4_sz && (|s4_esub1[3:0]);
	(* keep = "true" *) wire s4_use_p_ovf  = s4_sum27 || s4_lz_z;
	(* keep = "true" *) wire s4_p_ovf      = s4_sum27 ? s4_exp2_ovf : s4_exp1_ovf;

	/* Level 2 */
	(* keep = "true" *) wire [24:0] s4_m_inc = {
		inc5_ci({1'b0, s4_n[26:23]}, s4_ci4),
		inc5_ci(s4_n[22:18],         s4_ci3),
		inc5_ci(s4_n[17:13],         s4_ci2),
		inc5_ci(s4_n[12:8],          s4_ci1),
		inc5_ci(s4_n[7:3],           s4_inc_r)
	};
	(* keep = "true" *) wire s4_ovf0 = !s4_sz && (s4_sum27 ? s4_exp1_ovf : (!s4_esub0[9] && (s4_esub0[8] || (esub0_hi_all1 && esub0_lo_all1))));
	(* keep = "true" *) wire s4_udf0 = s4_sz || (!s4_sum27 && (s4_esub0[9] || (!s4_esub0[8] && !esub0_hi_nz && !esub0_lo_nz)));
	(* keep = "true" *) wire s4_ovf1 = !s4_sz && (s4_use_p_ovf ? s4_p_ovf : (!s4_esub1[9] && (s4_esub1[8] || (esub1_hi_all1 && esub1_lo_all1))));
	(* keep = "true" *) wire s4_udf1 = s4_sz || (!s4_use_p_ovf && (s4_esub1[9] || (!s4_esub1[8] && !esub1_hi_nz && !esub1_lo_nz)));
	(* keep = "true" *) wire s4_clr_m0 = s4_sum27 ? s4_exp1_ovf : (s4_esub0[9] || s4_esub0[8] || (esub0_hi_all1 && esub0_lo_all1) || (!esub0_hi_nz && !esub0_lo_nz));

	/* Level 3 */
	(* keep = "true" *) wire [31:0] o_r_w;
	assign o_r_w[31]    = s4_sp ? s4_spv[31]    : (s4_sz ? 1'b0 : s4_sx);
	assign o_r_w[30:23] = s4_sp ? s4_spv[30:23] : (s4_m_ovf ? (s4_ovf1 ? 8'hFF : (s4_udf1 ? 8'd0 : s4_e1_b)) :
	                                                          (s4_ovf0 ? 8'hFF : (s4_udf0 ? 8'd0 : s4_e0_b)));
	assign o_r_w[22:0]  = s4_sp ? s4_spv[22:0]  : (s4_clr_m0 ? 23'd0 : s4_m_inc[22:0]);
	assign o_r = o_r_w;

	wire unused_fsub = &{1'b0, mab_unused, s2_sum_co_unused, s4_m_inc[24:23], s4_ex_p1[9:8], s4_ex_p2[9:8]};
endmodule

`default_nettype wire
