/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tex_ret: the return half of atg_su_tex: a FIFO of the records of
 * the lane groups sent to the TU (rq_*, pushed by the send half when it
 * takes a group) and, for the oldest record, the gathering of its returned
 * quads and the long beats to atg_su_wb.
 *
 * The TU answers in request order, so the returned quads (tr_*) belong to
 * the oldest record, one per set bit of its quad mask, in increasing quad
 * order.  When all are in, the group's results go out: rd, rd+1, rd+2,
 * rd+3 (R, G, B, A of each lane; texsz: rd only, word 0 of each lane), each
 * beat with the record's EXEC lanes, l_wr 1, class t, l_last on the last
 * beat of a record with rq_last.  A record without quads (no EXEC lane)
 * writes its beats at once (no lanes).
 *
 * States: HEAD →(a record)→ GATHER (quad q) →(all in)→ BEAT (c) →(last
 * beat taken)→ HEAD.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_tex_fifo #(
	parameter W = 8,
	parameter DEPTH_LOG2 = 2
) (
	input wire clk,
	input wire rst_n,
	input wire in_valid,
	output wire in_ready,
	input wire [W-1:0] in_data,
	output wire out_valid,
	input wire out_ready,
	output wire [W-1:0] out_data,
	output wire [DEPTH_LOG2:0] count
);
	(* max_fanout = 12 *) reg [DEPTH_LOG2:0] wp;
	(* max_fanout = 12 *) reg [DEPTH_LOG2:0] rp;

	wire [DEPTH_LOG2:0] used;
	wire unused_used_bo;
	am_sub #(.W(DEPTH_LOG2 + 1)) u_used (
		.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(unused_used_bo)
	);
	(* dont_touch = "true" *) reg r_in_ready;
	(* dont_touch = "true" *) reg r_valid;
	(* max_fanout = 12 *) wire push = in_valid && r_in_ready;
	(* max_fanout = 12 *) wire pop = r_valid && out_ready;

	wire [DEPTH_LOG2:0] wp_next;
	wire unused_wp_co;
	am_add #(.W(DEPTH_LOG2 + 1)) u_wp (
		.a(wp), .b({(DEPTH_LOG2 + 1){1'b0}}), .ci(1'b1), .s(wp_next), .co(unused_wp_co)
	);

	wire [DEPTH_LOG2:0] rp_next;
	wire unused_rp_co;
	am_add #(.W(DEPTH_LOG2 + 1)) u_rp (
		.a(rp), .b({(DEPTH_LOG2 + 1){1'b0}}), .ci(1'b1), .s(rp_next), .co(unused_rp_co)
	);

	wire will_empty = (rp_next == wp);
	wire will_full  = (wp_next[DEPTH_LOG2-1:0] == rp[DEPTH_LOG2-1:0]) && (wp_next[DEPTH_LOG2] != rp[DEPTH_LOG2]);
	assign count = used;
	assign in_ready = r_in_ready;
	assign out_valid = r_valid;

	localparam N_TF_SL = (W + 15) / 16;
	genvar gtf;
	generate
	for (gtf = 0; gtf < N_TF_SL; gtf = gtf + 1) begin : g_tf_sl
		localparam TF_W = (gtf * 16 + 16 <= W) ? 16 : (W - gtf * 16);
		(* ram_style = "distributed" *) reg [TF_W-1:0] mem_sl [0:(1 << DEPTH_LOG2) - 1];
		(* dont_touch = "true" *) wire push_s = push;
		(* dont_touch = "true" *) wire [DEPTH_LOG2-1:0] wp_s = wp[DEPTH_LOG2-1:0];
		(* dont_touch = "true" *) wire [DEPTH_LOG2-1:0] rp_s = rp[DEPTH_LOG2-1:0];
		(* dont_touch = "true" *) wire [TF_W-1:0] wd_s = in_data[gtf*16 +: TF_W];
		always @(posedge clk)
			if (push_s)
				mem_sl[wp_s] <= wd_s;
		assign out_data[gtf*16 +: TF_W] = mem_sl[rp_s];
	end
	endgenerate

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	always @(posedge clk) begin
		if (rst_p) begin
			wp <= {(DEPTH_LOG2 + 1){1'b0}};
			rp <= {(DEPTH_LOG2 + 1){1'b0}};
			r_valid <= 1'b0;
			r_in_ready <= 1'b1;
		end else begin
			if (push)
				wp <= wp_next;
			if (pop)
				rp <= rp_next;
			case ({push, pop})
			2'b10: begin
				r_valid <= 1'b1;
				r_in_ready <= !will_full;
			end
			2'b01: begin
				r_valid <= !will_empty;
				r_in_ready <= 1'b1;
			end
			default: ;
			endcase
		end
	end
endmodule

module atg_su_tex_ret #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS) */
	parameter SBE_W = 2	/* log2(SB_ENTRIES) */
) (
	input wire clk,
	input wire rst_n,
	/* Records from the send half (one per lane group) */
	input wire rq_valid,
	output wire rq_ready,
	input wire [WARP_W-1:0] rq_warp,
	input wire [GRP_W-1:0] rq_grp,
	input wire [6:0] rq_rd,
	input wire [SBE_W:0] rq_sbe,
	input wire rq_last,
	input wire rq_sz,
	input wire [NPHYS/4-1:0] rq_qmask,
	input wire [NPHYS-1:0] rq_lanes,
	/* Returned quads from the TU */
	input wire tr_valid,
	output wire tr_ready,
	input wire [511:0] tr_data,
	/* Long result to atg_su_wb */
	output wire l_valid,
	input wire l_ready,
	output wire [WARP_W-1:0] l_warp,
	output wire [GRP_W-1:0] l_grp,
	output wire [6:0] l_rd,
	output reg [NPHYS*32-1:0] l_data,
	output wire [NPHYS-1:0] l_lanes,
	output wire l_wr,
	output wire l_last,
	output wire [SBE_W:0] l_sbe,
	output wire [2:0] l_cls
);
`include "atg_su_uop.vh"

	localparam NQ = NPHYS / 4;
	localparam QW = NQ > 1 ? $clog2(NQ) : 1;
	localparam RW = WARP_W + GRP_W + 7 + SBE_W + 1 + 2 + NQ + NPHYS;
	localparam [1:0] HEAD = 2'd0, GATHER = 2'd1, BEAT = 2'd2;

	(* max_fanout = 12 *) wire f_valid;
	wire [2:0] f_count;
	(* max_fanout = 12 *) wire [RW-1:0] f_data;
	(* fsm_encoding = "none", max_fanout = 12 *) reg [1:0] st;
	(* max_fanout = 12 *) reg [QW-1:0] q;
	(* max_fanout = 12 *) reg [1:0] c;
	(* max_fanout = 12 *) reg [WARP_W-1:0] warp;
	(* max_fanout = 12 *) reg [GRP_W-1:0] grp;
	(* max_fanout = 12 *) reg [6:0] rd;
	(* max_fanout = 12 *) reg [SBE_W:0] sbe;
	(* max_fanout = 12 *) reg last, sz;
	(* max_fanout = 12 *) reg [NQ-1:0] qm;
	(* max_fanout = 12 *) reg [NPHYS-1:0] lanes;

	atg_su_tex_fifo #(.W(RW), .DEPTH_LOG2(2)) fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(rq_valid), .in_ready(rq_ready),
		.in_data({rq_warp, rq_grp, rq_rd, rq_sbe, rq_last, rq_sz, rq_qmask, rq_lanes}),
		.out_valid(f_valid), .out_ready(st == HEAD), .out_data(f_data), .count(f_count)
	);

	wire q_end = {{(32 - QW){1'b0}}, q} == NQ - 1;
	assign tr_ready = st == GATHER && qm[q];
	(* keep = "true", max_fanout = 12 *) wire gather_we = (st == GATHER) && qm[q] && tr_valid;

	/* Beat c: channel c of each lane (lane 4*gq + glq: quad gq, lane glq),
	 * stored in per-lane/half registers so each CE/mux net drives <= 16 bits. */
	wire [NPHYS*32-1:0] l_data_w;
	genvar gq, glq, gh;
	generate
	for (gq = 0; gq < NQ; gq = gq + 1) begin : g_bufq_quad
		for (glq = 0; glq < 4; glq = glq + 1) begin : g_bufq_lane
			for (gh = 0; gh < 2; gh = gh + 1) begin : g_bufq_half
				localparam L_IDX = gq * 4 + glq;
				localparam TR_BASE = glq * 128 + gh * 16;
				(* dont_touch = "true" *) wire bufq_we_0 = gather_we && (q == gq[QW-1:0]);
				(* dont_touch = "true" *) wire bufq_we_1 = gather_we && (q == gq[QW-1:0]);
				(* dont_touch = "true" *) wire bufq_we_2 = gather_we && (q == gq[QW-1:0]);
				(* dont_touch = "true" *) wire bufq_we_3 = gather_we && (q == gq[QW-1:0]);
				(* dont_touch = "true" *) wire [1:0] c_sl = c;
				(* shreg_extract = "no" *) reg [15:0] b_c0, b_c1, b_c2, b_c3;
				always @(posedge clk) begin
					if (bufq_we_0) b_c0 <= tr_data[TR_BASE + 0*32 +: 16];
					if (bufq_we_1) b_c1 <= tr_data[TR_BASE + 1*32 +: 16];
					if (bufq_we_2) b_c2 <= tr_data[TR_BASE + 2*32 +: 16];
					if (bufq_we_3) b_c3 <= tr_data[TR_BASE + 3*32 +: 16];
				end
				assign l_data_w[L_IDX*32 + gh*16 +: 16] =
					(c_sl == 2'd0) ? b_c0 :
					(c_sl == 2'd1) ? b_c1 :
					(c_sl == 2'd2) ? b_c2 : b_c3;
			end
		end
	end
	endgenerate
	always @(*) l_data = l_data_w;

	/* The beat's register rd + c, the next beat and the next quad. */
	wire [6:0] rd_c;
	wire [1:0] c_next;
	wire [QW-1:0] q_next;
	wire rc_co_unused, cn_co_unused, qn_co_unused;
	am_add #(.W(7)) u_rd (.a(rd), .b({5'd0, c}), .ci(1'b0), .s(rd_c), .co(rc_co_unused));
	am_add #(.W(2)) u_c (.a(c), .b(2'd0), .ci(1'b1), .s(c_next), .co(cn_co_unused));
	am_add #(.W(QW)) u_q (.a(q), .b({QW{1'b0}}), .ci(1'b1), .s(q_next), .co(qn_co_unused));

	assign l_valid = st == BEAT;
	assign l_warp = warp;
	assign l_grp = grp;
	assign l_rd = rd_c;
	assign l_lanes = lanes;
	assign l_wr = 1'b1;
	assign l_last = last && (sz || c == 2'd3);
	assign l_sbe = sbe;
	assign l_cls = ATG_CLS_T;

	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire head_take_a = !rst_p && (st == HEAD) && f_valid;
	(* dont_touch = "true" *) wire head_take_b = !rst_p && (st == HEAD) && f_valid;
	always @(posedge clk) begin
		if (head_take_a) begin
			{warp, grp, rd, sbe} <= f_data[RW-1 : 2 + NQ + NPHYS];
		end
		if (head_take_b) begin
			{last, sz, qm, lanes} <= f_data[2 + NQ + NPHYS - 1 : 0];
		end
		if (rst_p) begin
			st <= HEAD;
		end else begin
			case (st)
			HEAD: if (f_valid) begin
				q <= {QW{1'b0}};
				c <= 2'd0;
				st <= f_data[NPHYS +: NQ] == {NQ{1'b0}} ? BEAT : GATHER;
			end
			GATHER: if (!qm[q] || tr_valid) begin
				q <= q_next;
				if (q_end)
					st <= BEAT;
			end
			BEAT: if (l_ready) begin
				c <= c_next;
				if (sz || c == 2'd3)
					st <= HEAD;
			end
			default: st <= HEAD;
			endcase
		end
	end

	wire unused_ok = &{1'b0, f_count};
endmodule

`default_nettype wire
