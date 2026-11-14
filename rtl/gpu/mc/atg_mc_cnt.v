/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_cnt: the MC's request counters (spec/gpu/mc/atg_mc.md), from the
 * clients' handshakes (take: valid and ready of a client's AMB port) and
 * responses:
 *
 *   pend    requests taken by the leaves and not yet granted or refused
 *           (done) at the root: pend_zero
 *   chk     those of them with chk (done_chk): chk_idle
 *   unit    requests of UNIT_MASK's clients without their response yet:
 *           unit_idle
 *   ax      requests the root granted to the AXI master (ax_inc: walks
 *           included) without their response from it yet (ax_dec): ax_zero
 *
 * KEEP_MASK's clients (the DC, atg_mc's ROOT_KEEP) are not counted by pend
 * (take is masked and done_keep marks their done) and the caller leaves
 * them out of ax.  rst_n and flush clear pend, chk and unit; ax only rst_n
 * (it counts the AXI master, which flush does not empty).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_cnt #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] UNIT_MASK = {NCLIENT{1'b0}},
	parameter [NCLIENT-1:0] KEEP_MASK = {NCLIENT{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire [NCLIENT-1:0] take,
	input wire [NCLIENT-1:0] take_chk,
	input wire [NCLIENT-1:0] rsp,
	input wire done,
	input wire done_chk,
	input wire done_keep,	/* done was a KEEP_MASK client's */
	input wire ax_inc,
	input wire ax_dec,
	output wire pend_zero,
	output wire chk_idle,
	output wire unit_idle,
	output wire ax_zero
);
	reg [7:0] pend, chk_n;
	reg [9:0] unit_n;

	/*
	 * The net deltas of this cycle's takes and ends/responses: a chain of
	 * one adder per client for each, folding the decrement into the chain
	 * so each counter updates through a single final adder.
	 */
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire cnt_flush_rst_sync;
	(* keep = "true", dont_touch = "true" *) wire cnt_rst_sync;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hD)) u_cnt_frst (
		.I0(rst_n), .I1(flush), .O(cnt_flush_rst_sync)
	);
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_cnt_rst (
		.I0(rst_n), .O(cnt_rst_sync)
	);

	reg [NCLIENT-1:0] take_s, take_chk_s, rsp_s;
	reg done_s, done_chk_s, done_keep_s, ax_inc_s, ax_dec_s;
	always @(posedge clk or posedge cnt_flush_rst_sync) begin
		if (cnt_flush_rst_sync) begin
			take_s      <= {NCLIENT{1'b0}};
			take_chk_s  <= {NCLIENT{1'b0}};
			rsp_s       <= {NCLIENT{1'b0}};
			done_s      <= 1'b0;
			done_chk_s  <= 1'b0;
			done_keep_s <= 1'b0;
		end else begin
			take_s      <= take;
			take_chk_s  <= take_chk;
			rsp_s       <= rsp;
			done_s      <= done;
			done_chk_s  <= done_chk;
			done_keep_s <= done_keep;
		end
	end

	always @(posedge clk or posedge cnt_rst_sync) begin
		if (cnt_rst_sync) begin
			ax_inc_s <= 1'b0;
			ax_dec_s <= 1'b0;
		end else begin
			ax_inc_s <= ax_inc;
			ax_dec_s <= ax_dec;
		end
	end
`else
/* verilator lint_off SYNCASYNCNET */
	wire cnt_flush_rst_sync = !rst_n || flush;
	wire cnt_rst_sync = !rst_n;
/* verilator lint_on SYNCASYNCNET */
	wire [NCLIENT-1:0] take_s     = take;
	wire [NCLIENT-1:0] take_chk_s = take_chk;
	wire [NCLIENT-1:0] rsp_s      = rsp;
	wire done_s      = done;
	wire done_chk_s  = done_chk;
	wire done_keep_s = done_keep;
	wire ax_inc_s    = ax_inc;
	wire ax_dec_s    = ax_dec;
`endif

	/*
	 * Population count trees for active increment/decrement events across clients.
	 * Evaluated in O(log2 NCLIENT) depth (<= 2 LUT levels) rather than an O(N) daisy-chain.
	 */
	wire [4:0] n_take;
	wire [4:0] n_take_chk;
	wire [4:0] n_unit_take;
	wire [4:0] n_unit_rsp;

	am_popcount #(.W(NCLIENT), .OW(5)) u_pop_take (
		.i_vec(take_s & ~KEEP_MASK),
		.o_cnt(n_take)
	);
	am_popcount #(.W(NCLIENT), .OW(5)) u_pop_take_chk (
		.i_vec(take_s & take_chk_s),
		.o_cnt(n_take_chk)
	);
	am_popcount #(.W(NCLIENT), .OW(5)) u_pop_u_take (
		.i_vec(take_s & UNIT_MASK),
		.o_cnt(n_unit_take)
	);
	am_popcount #(.W(NCLIENT), .OW(5)) u_pop_u_rsp (
		.i_vec(rsp_s & UNIT_MASK),
		.o_cnt(n_unit_rsp)
	);

	/* Net deltas computed by single-level subtractors */
	wire [7:0] t_n;
	wire [7:0] tc_n;
	wire [9:0] u_delta;
	wire sub_t_bo_unused, sub_tc_bo_unused, sub_u_bo_unused;

	am_sub #(.W(8)) u_sub_t (
		.a({{3{1'b0}}, n_take}),
		.b({7'd0, done_s && !done_keep_s}),
		.bi(1'b0),
		.d(t_n),
		.bo(sub_t_bo_unused)
	);
	am_sub #(.W(8)) u_sub_tc (
		.a({{3{1'b0}}, n_take_chk}),
		.b({7'd0, done_chk_s}),
		.bi(1'b0),
		.d(tc_n),
		.bo(sub_tc_bo_unused)
	);
	am_sub #(.W(10)) u_sub_u (
		.a({{5{1'b0}}, n_unit_take}),
		.b({{5{1'b0}}, n_unit_rsp}),
		.bi(1'b0),
		.d(u_delta),
		.bo(sub_u_bo_unused)
	);

	/* Each counter: n + this cycle's net delta in a single adder. */
	wire [7:0] pend_n, chk_nx;
	wire [9:0] unit_nx;
	wire [2:0] cnt_co;

	am_add #(.W(8)) pend_add (.a(pend), .b(t_n), .ci(1'b0), .s(pend_n), .co(cnt_co[0]));
	am_add #(.W(8)) chk_add (.a(chk_n), .b(tc_n), .ci(1'b0), .s(chk_nx), .co(cnt_co[1]));
	am_add #(.W(10)) unit_add (.a(unit_n), .b(u_delta), .ci(1'b0), .s(unit_nx), .co(cnt_co[2]));

	always @(posedge clk or posedge cnt_flush_rst_sync) begin
		if (cnt_flush_rst_sync) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else begin
			pend <= pend_n;
			chk_n <= chk_nx;
			unit_n <= unit_nx;
		end
	end

	assign pend_zero = pend == 8'd0;
	assign chk_idle = chk_n == 8'd0;
	assign unit_idle = unit_n == 10'd0;

	/* ax: one increment and one decrement a cycle, n + inc - dec in one adder. */
	reg [7:0] ax_n;
	wire [7:0] ax_next;
	wire ax_co_unused;

	am_add #(.W(8)) ax_add (
		.a(ax_n), .b({8{ax_dec_s}}), .ci(ax_inc_s), .s(ax_next), .co(ax_co_unused)
	);

	always @(posedge clk or posedge cnt_rst_sync)
		if (cnt_rst_sync)
			ax_n <= 8'd0;
		else
			ax_n <= ax_next;

	assign ax_zero = ax_n == 8'd0;

	wire unused_ok = &{1'b0, ax_co_unused, cnt_co, sub_t_bo_unused, sub_tc_bo_unused, sub_u_bo_unused};
endmodule

`default_nettype wire
