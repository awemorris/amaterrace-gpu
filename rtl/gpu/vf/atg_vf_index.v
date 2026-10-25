/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_index: VF index stage: walks FIRST..FIRST+COUNT (non-indexed) or
 * reads the index buffer (u16/u32), detects primitive restart, and repeats
 * for INSTANCE_COUNT instances.
 *
 * On kick the walk starts from the STATE words of the VF range (the CP does
 * not change them under a draw; a kick while busy is ignored).
 * Non-indexed: iv_index = FIRST + n, no memory access.  Indexed: the lines
 * of INDEX_BASE + (FIRST + n) * size are read in order (one line request
 * ahead, two line buffers, the tag names the buffer) and each line's
 * indices go out one per cycle; INDEX_BASE is aligned to the index size,
 * so an index never crosses a line.  With PRIM_RESTART[0], 0xFFFF (u16) or
 * 0xFFFFFFFF (u32) goes out as iv_restart.  The whole walk repeats for each
 * instance (iv_inst = FIRST_INSTANCE + i; the lines are read again).
 * iv_last marks the last item of the last instance.  COUNT 0 or
 * INSTANCE_COUNT 0 sends nothing.  rsp_error stops the walk without iv_last
 * (the MC faulted; the CP resets the VF); busy stays up until the requests
 * in flight are answered.  See spec/gpu/vf/atg_vf_index.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_index #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire kick,
	output wire busy,
	/* Index stream (atg_vf_index → atg_vf_asm) */
	output wire iv_valid,
	input wire iv_ready,
	output wire [31:0] iv_index,
	output wire [31:0] iv_inst,
	output wire iv_restart,
	output wire iv_last,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;

	/* STATE indices of the VF range (design §2.3). */

	reg [31:0] s_ibase, s_first, s_count, s_icount, s_finst;
	reg [1:0] s_ifmt;
	reg s_restart;
	always @(posedge clk)
		if (!rst_n) begin
			s_ibase <= 32'd0;
			s_ifmt <= 2'd0;
			s_first <= 32'd0;
			s_count <= 32'd0;
			s_restart <= 1'b0;
			s_icount <= 32'd0;
			s_finst <= 32'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_INDEX_BASE)
				s_ibase <= st_wdata;
			if (st_idx == GHCI_S_INDEX_FORMAT)
				s_ifmt <= st_wdata[1:0];
			if (st_idx == GHCI_S_FIRST)
				s_first <= st_wdata;
			if (st_idx == GHCI_S_COUNT)
				s_count <= st_wdata;
			if (st_idx == GHCI_S_PRIM_RESTART)
				s_restart <= st_wdata[0];
			if (st_idx == GHCI_S_INSTANCE_COUNT)
				s_icount <= st_wdata;
			if (st_idx == GHCI_S_FIRST_INSTANCE)
				s_finst <= st_wdata;
		end

	/* INDEX_FORMAT: 0 none, 1 u16, 2 (and the reserved 3) u32. */
	wire k_ind = s_ifmt != 2'd0;
	wire k_u32 = s_ifmt[1];
	wire [31:0] k_a0;
	wire [31:0] k_alast;
	wire [31:0] k_cm1;	/* COUNT - 1 */

	localparam [1:0] ST_IDLE = 2'd0, ST_WALK = 2'd1, ST_DRAIN = 2'd2;
	reg [1:0] st;
	reg ind, u32;
	reg [31:0] a0;	/* byte address of the first index */
	reg [LA_W-1:0] l0, lend;	/* first and last line of an instance */

	/* Request side: the line sequence l0..lend, once per instance. */
	reg rq_pend, rq_more, rq_slot;
	reg [LA_W-1:0] rq_l;
	reg [31:0] rq_ileft;
	reg [1:0] nalloc;	/* buffers requested and not yet consumed */
	reg [1:0] inflight;	/* requests not yet answered */

	/* Line buffers, filled by tag. */
	reg [LB-1:0] buf0, buf1;
	reg [1:0] bv;

	/* Emit side. */
	reg e_slot;
	reg [31:0] e_a;	/* byte address of the next index (indexed) */
	reg [31:0] e_v;	/* FIRST + n (non-indexed) */
	reg [31:0] e_n;	/* indices left in this instance */
	reg [31:0] e_inst, e_ileft;

	wire [LB-1:0] head = e_slot ? buf1 : buf0;
	wire [LINE_SHIFT-1:0] e_off = e_a[LINE_SHIFT-1:0];
	wire [LB-1:0] head_sh;

	/* The head line from the next index's byte. */
	am_shift #(.W(LB), .SW(LINE_SHIFT + 3)) hs (.a(head), .amt({e_off, 3'b000}), .left(1'b0),
		.arith(1'b0), .y(head_sh));
	wire [31:0] e_raw = u32 ? head_sh[31:0] : {16'd0, head_sh[15:0]};
	wire e_have = !ind || bv[e_slot];

	assign iv_valid = st == ST_WALK && e_have;
	assign iv_index = ind ? e_raw : e_v;
	assign iv_inst = e_inst;
	assign iv_restart = ind && s_restart && (u32 ? &e_raw : &e_raw[15:0]);
	assign iv_last = e_n == 32'd1 && e_ileft == 32'd1;
	assign busy = st != ST_IDLE;

	wire take = iv_valid && iv_ready;
	wire inst_end = e_n == 32'd1;
	wire [31:0] e_anext;

	/*
	 * The address adder, shared: at the kick (IDLE) INDEX_BASE + FIRST x the
	 * index size, while walking (WALK) the next index's address.
	 */
	wire [31:0] ad_a = st == ST_IDLE ? s_ibase : e_a;
	wire [31:0] ad_b = st == ST_IDLE ? (k_u32 ? s_first << 2 : s_first << 1) :
		(u32 ? 32'd4 : 32'd2);
	wire [31:0] ad_s;
	wire ad_co_unused, cm1_bo_unused, al_co_unused;	/* the carries are not used */

	am_add #(.W(32)) ad (.a(ad_a), .b(ad_b), .ci(1'b0), .s(ad_s), .co(ad_co_unused));
	assign k_a0 = ad_s;
	assign e_anext = ad_s;

	/* The last index's address: k_a0 + (COUNT - 1) x the index size. */
	am_sub #(.W(32)) cm1 (.a(s_count), .b(32'd1), .bi(1'b0), .d(k_cm1), .bo(cm1_bo_unused));
	am_add #(.W(32)) al (.a(k_a0), .b(k_u32 ? k_cm1 << 2 : k_cm1 << 1), .ci(1'b0), .s(k_alast),
		.co(al_co_unused));
	/* The head line is used up: the next index is in another line, or the
	 * instance ends (its last line). */
	wire pop = take && ind &&
		(inst_end || e_anext[ADDR_W-1:LINE_SHIFT] != e_a[ADDR_W-1:LINE_SHIFT]);
	/* Reserve a buffer and offer the next line. */
	wire rq_new = !rq_pend && st == ST_WALK && ind && rq_more && (nalloc != 2'd2 || pop);

	assign req_valid = rq_pend;
	assign req_write = 1'b0;
	assign req_line = rq_l;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = {7'd0, rq_slot};
	wire rq_take = rq_pend && req_ready;
	wire rd_rsp = rsp_valid && !rsp_write;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= ST_IDLE;
			rq_pend <= 1'b0;
			rq_more <= 1'b0;
			rq_slot <= 1'b0;
			nalloc <= 2'd0;
			inflight <= 2'd0;
			bv <= 2'b00;
			e_slot <= 1'b0;
		end else begin
			/* Responses: fill the buffer named by the tag (data 0 on error). */
			if (rd_rsp) begin
				if (rsp_tag[0])
					buf1 <= rsp_error ? {LB{1'b0}} : rsp_rdata;
				else
					buf0 <= rsp_error ? {LB{1'b0}} : rsp_rdata;
				bv[rsp_tag[0]] <= 1'b1;
			end
			inflight <= inflight + {1'b0, rq_take} - {1'b0, rd_rsp};

			/* Requests: at most two buffers ahead of the emitter. */
			if (rq_take) begin
				rq_pend <= 1'b0;
				if (rq_l == lend) begin
					rq_l <= l0;
					rq_ileft <= rq_ileft - 32'd1;
					if (rq_ileft == 32'd1)
						rq_more <= 1'b0;
				end else
					rq_l <= rq_l + {{(LA_W-1){1'b0}}, 1'b1};
			end else if (rq_new) begin
				rq_pend <= 1'b1;
				rq_slot <= !rq_slot;
			end
			nalloc <= nalloc + {1'b0, rq_new} - {1'b0, pop};
			if (pop)
				bv[e_slot] <= 1'b0;

			case (st)
			ST_IDLE:
				if (kick && s_count != 32'd0 && s_icount != 32'd0) begin
					st <= ST_WALK;
					ind <= k_ind;
					u32 <= k_u32;
					a0 <= k_a0;
					l0 <= k_a0[ADDR_W-1:LINE_SHIFT];
					lend <= k_alast[ADDR_W-1:LINE_SHIFT];
					rq_l <= k_a0[ADDR_W-1:LINE_SHIFT];
					rq_ileft <= s_icount;
					rq_more <= k_ind;
					rq_slot <= 1'b1;	/* the first request toggles it to buffer 0 */
					e_slot <= 1'b0;
					e_a <= k_a0;
					e_v <= s_first;
					e_n <= s_count;
					e_inst <= s_finst;
					e_ileft <= s_icount;
				end
			ST_WALK:
				if (rd_rsp && rsp_error)
					st <= ST_DRAIN;
				else if (take) begin
					if (pop)
						e_slot <= !e_slot;
					if (inst_end) begin
						e_n <= s_count;
						e_a <= a0;
						e_v <= s_first;
						e_inst <= e_inst + 32'd1;
						e_ileft <= e_ileft - 32'd1;
						if (e_ileft == 32'd1)
							st <= ST_IDLE;
					end else begin
						e_n <= e_n - 32'd1;
						e_a <= e_anext;
						e_v <= e_v + 32'd1;
					end
				end
			default:
				/* After an error: wait for the requests in flight, then drop them. */
				if (!rq_pend && inflight == {1'b0, rd_rsp}) begin
					st <= ST_IDLE;
					rq_more <= 1'b0;
					nalloc <= 2'd0;
					bv <= 2'b00;
				end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:1], k_alast[LINE_SHIFT-1:0], head_sh[LB-1:32],
		ad_co_unused, cm1_bo_unused, al_co_unused};
endmodule

`default_nettype wire
