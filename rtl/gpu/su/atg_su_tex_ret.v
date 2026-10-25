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

module atg_su_tex_ret #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 */
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

	wire f_valid;
	wire [2:0] f_count;
	wire [RW-1:0] f_data;
	reg [1:0] st;
	reg [QW-1:0] q;
	reg [1:0] c;
	reg [NQ*512-1:0] buf_q;
	reg [WARP_W-1:0] warp;
	reg [GRP_W-1:0] grp;
	reg [6:0] rd;
	reg [SBE_W:0] sbe;
	reg last, sz;
	reg [NQ-1:0] qm;
	reg [NPHYS-1:0] lanes;

	am_fifo #(.W(RW), .DEPTH_LOG2(2)) fifo (
		.clk(clk), .rst_n(rst_n),
		.in_valid(rq_valid), .in_ready(rq_ready),
		.in_data({rq_warp, rq_grp, rq_rd, rq_sbe, rq_last, rq_sz, rq_qmask, rq_lanes}),
		.out_valid(f_valid), .out_ready(st == HEAD), .out_data(f_data), .count(f_count)
	);

	wire q_end = {{(32 - QW){1'b0}}, q} == NQ - 1;
	assign tr_ready = st == GATHER && qm[q];

	/* Beat c: channel c of each lane (lane 4j + l: quad j, lane l). */
	integer j;
	reg [127:0] l_texel;
	always @(*)
		for (j = 0; j < NPHYS; j = j + 1) begin
			l_texel = buf_q[(j / 4) * 512 + (j % 4) * 128 +: 128];
			l_data[j*32 +: 32] = l_texel[c * 32 +: 32];
		end

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

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= HEAD;
		end else begin
			case (st)
			HEAD: if (f_valid) begin
				{warp, grp, rd, sbe, last, sz, qm, lanes} <= f_data;
				q <= {QW{1'b0}};
				c <= 2'd0;
				st <= f_data[NPHYS +: NQ] == {NQ{1'b0}} ? BEAT : GATHER;
			end
			GATHER: if (!qm[q] || tr_valid) begin
				if (qm[q])
					buf_q[q*512 +: 512] <= tr_data;
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
