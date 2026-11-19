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
	(* keep = "true", dont_touch = "true" *) wire cnt_rst_sync;
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_cnt_rst (
		.I0(rst_n), .O(cnt_rst_sync)
	);

	reg [NCLIENT-1:0] take_s, take_chk_s, rsp_s;
	reg done_s, done_chk_s, done_keep_s, ax_inc_s, ax_dec_s;
	always @(posedge clk or posedge cnt_rst_sync) begin
		if (cnt_rst_sync) begin
			take_s      <= {NCLIENT{1'b0}};
			take_chk_s  <= {NCLIENT{1'b0}};
			rsp_s       <= {NCLIENT{1'b0}};
			done_s      <= 1'b0;
			done_chk_s  <= 1'b0;
			done_keep_s <= 1'b0;
		end else if (flush) begin
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
	reg [NCLIENT-1:0] take_s, take_chk_s, rsp_s;
	reg done_s, done_chk_s, done_keep_s, ax_inc_s, ax_dec_s;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			take_s      <= {NCLIENT{1'b0}};
			take_chk_s  <= {NCLIENT{1'b0}};
			rsp_s       <= {NCLIENT{1'b0}};
			done_s      <= 1'b0;
			done_chk_s  <= 1'b0;
			done_keep_s <= 1'b0;
		end else if (flush) begin
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

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			ax_inc_s <= 1'b0;
			ax_dec_s <= 1'b0;
		end else begin
			ax_inc_s <= ax_inc;
			ax_dec_s <= ax_dec;
		end
	end
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

	/* Fold + popcount - decrement via 1-level 3:2 CSA into a single adder per counter. */
	wire dec_t = done_s && !done_keep_s;
	wire [7:0] n_take_w = {3'd0, n_take};
	wire [7:0] dec_t_w = {8{dec_t}};
	wire [7:0] t_csa_s = pend ^ n_take_w ^ dec_t_w;
	wire [7:0] t_csa_c = (pend & n_take_w) | (pend & dec_t_w) | (n_take_w & dec_t_w);

	wire [7:0] n_take_chk_w = {3'd0, n_take_chk};
	wire [7:0] dec_tc_w = {8{done_chk_s}};
	wire [7:0] tc_csa_s = chk_n ^ n_take_chk_w ^ dec_tc_w;
	wire [7:0] tc_csa_c = (chk_n & n_take_chk_w) | (chk_n & dec_tc_w) | (n_take_chk_w & dec_tc_w);

	wire [9:0] n_unit_take_w = {5'd0, n_unit_take};
	wire [9:0] n_unit_rsp_inv = {5'h1F, ~n_unit_rsp};
	wire [9:0] u_csa_s = unit_n ^ n_unit_take_w ^ n_unit_rsp_inv;
	wire [9:0] u_csa_c = (unit_n & n_unit_take_w) | (unit_n & n_unit_rsp_inv) | (n_unit_take_w & n_unit_rsp_inv);

	/* Each counter: single final carry-propagate adder. */
	wire [7:0] pend_n, chk_nx;
	wire [9:0] unit_nx;
	wire [2:0] cnt_co;

	am_add #(.W(8)) pend_add (.a(t_csa_s), .b({t_csa_c[6:0], 1'b0}), .ci(1'b0), .s(pend_n), .co(cnt_co[0]));
	am_add #(.W(8)) chk_add (.a(tc_csa_s), .b({tc_csa_c[6:0], 1'b0}), .ci(1'b0), .s(chk_nx), .co(cnt_co[1]));
	am_add #(.W(10)) unit_add (.a(u_csa_s), .b({u_csa_c[8:0], 1'b1}), .ci(1'b0), .s(unit_nx), .co(cnt_co[2]));

`ifdef SYNTH_KINTEX7
	always @(posedge clk or posedge cnt_rst_sync) begin
		if (cnt_rst_sync) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else if (flush) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else begin
			pend <= pend_n;
			chk_n <= chk_nx;
			unit_n <= unit_nx;
		end
	end
`else
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else if (flush) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else begin
			pend <= pend_n;
			chk_n <= chk_nx;
			unit_n <= unit_nx;
		end
	end
`endif

	assign pend_zero = pend_n == 8'd0;
	assign chk_idle  = chk_nx == 8'd0;
	assign unit_idle = unit_nx == 10'd0;

	/* ax: precompute +1 and -1 in parallel with ax_inc/ax_dec control logic. */
	reg [7:0] ax_n;
	wire [7:0] ax_p1, ax_m1;
	wire [1:0] ax_co_unused;

	am_add #(.W(8)) ax_add_p1 (.a(ax_n), .b(8'd0), .ci(1'b1), .s(ax_p1), .co(ax_co_unused[0]));
	am_add #(.W(8)) ax_add_m1 (.a(ax_n), .b(8'hFF), .ci(1'b0), .s(ax_m1), .co(ax_co_unused[1]));
	wire [7:0] ax_next = (ax_inc_s == ax_dec_s) ? ax_n : (ax_inc_s ? ax_p1 : ax_m1);

`ifdef SYNTH_KINTEX7
	always @(posedge clk or posedge cnt_rst_sync)
		if (cnt_rst_sync)
			ax_n <= 8'd0;
		else
			ax_n <= ax_next;
`else
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			ax_n <= 8'd0;
		else
			ax_n <= ax_next;
`endif

	assign ax_zero = ax_next == 8'd0;

	wire unused_ok = &{1'b0, ax_co_unused, cnt_co, t_csa_c[7], tc_csa_c[7], u_csa_c[9]};
endmodule

`default_nettype wire
