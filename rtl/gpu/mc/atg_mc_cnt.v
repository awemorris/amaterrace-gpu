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

	/* Carry-select adders: 4+4 for 8-bit pend/chk_n, 5+5 for 10-bit unit_n. */
	wire [7:0] pend_n, chk_nx;
	wire [9:0] unit_nx;
	wire [8:0] cnt_co;

	wire pend_lo_c, chk_lo_c, unit_lo_c;
	wire [3:0] pend_hi0, pend_hi1, chk_hi0, chk_hi1;
	wire [4:0] unit_hi0, unit_hi1;

	am_add #(.W(4)) pend_add_lo  (.a(t_csa_s[3:0]), .b({t_csa_c[2:0], 1'b0}), .ci(1'b0), .s(pend_n[3:0]), .co(pend_lo_c));
	am_add #(.W(4)) pend_add_hi0 (.a(t_csa_s[7:4]), .b(t_csa_c[6:3]),         .ci(1'b0), .s(pend_hi0),    .co(cnt_co[0]));
	am_add #(.W(4)) pend_add_hi1 (.a(t_csa_s[7:4]), .b(t_csa_c[6:3]),         .ci(1'b1), .s(pend_hi1),    .co(cnt_co[1]));
	assign pend_n[7:4] = pend_lo_c ? pend_hi1 : pend_hi0;

	am_add #(.W(4)) chk_add_lo   (.a(tc_csa_s[3:0]), .b({tc_csa_c[2:0], 1'b0}), .ci(1'b0), .s(chk_nx[3:0]), .co(chk_lo_c));
	am_add #(.W(4)) chk_add_hi0  (.a(tc_csa_s[7:4]), .b(tc_csa_c[6:3]),         .ci(1'b0), .s(chk_hi0),     .co(cnt_co[2]));
	am_add #(.W(4)) chk_add_hi1  (.a(tc_csa_s[7:4]), .b(tc_csa_c[6:3]),         .ci(1'b1), .s(chk_hi1),     .co(cnt_co[3]));
	assign chk_nx[7:4] = chk_lo_c ? chk_hi1 : chk_hi0;

	am_add #(.W(5)) unit_add_lo  (.a(u_csa_s[4:0]), .b({u_csa_c[3:0], 1'b1}), .ci(1'b0), .s(unit_nx[4:0]), .co(unit_lo_c));
	am_add #(.W(5)) unit_add_hi0 (.a(u_csa_s[9:5]), .b(u_csa_c[8:4]),         .ci(1'b0), .s(unit_hi0),     .co(cnt_co[4]));
	am_add #(.W(5)) unit_add_hi1 (.a(u_csa_s[9:5]), .b(u_csa_c[8:4]),         .ci(1'b1), .s(unit_hi1),     .co(cnt_co[5]));
	assign unit_nx[9:5] = unit_lo_c ? unit_hi1 : unit_hi0;
	assign cnt_co[8:6] = 3'b000;

	reg pend_is0_r, pend_is1_r;
	reg chk_is0_r, chk_is1_r;
	reg unit_is0_r, unit_is1_r;
	reg ax_is0_r, ax_is1_r;

`ifdef SYNTH_KINTEX7
	always @(posedge clk or posedge cnt_rst_sync) begin
		if (cnt_rst_sync) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
			pend_is0_r <= 1'b1;
			pend_is1_r <= 1'b0;
			chk_is0_r  <= 1'b1;
			chk_is1_r  <= 1'b0;
			unit_is0_r <= 1'b1;
			unit_is1_r <= 1'b0;
		end else if (flush) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
			pend_is0_r <= 1'b1;
			pend_is1_r <= 1'b0;
			chk_is0_r  <= 1'b1;
			chk_is1_r  <= 1'b0;
			unit_is0_r <= 1'b1;
			unit_is1_r <= 1'b0;
		end else begin
			pend <= pend_n;
			chk_n <= chk_nx;
			unit_n <= unit_nx;
			pend_is0_r <= pend_n == 8'd0;
			pend_is1_r <= pend_n == 8'd1;
			chk_is0_r  <= chk_nx == 8'd0;
			chk_is1_r  <= chk_nx == 8'd1;
			unit_is0_r <= unit_nx == 10'd0;
			unit_is1_r <= unit_nx == 10'd1;
		end
	end
`else
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
			pend_is0_r <= 1'b1;
			pend_is1_r <= 1'b0;
			chk_is0_r  <= 1'b1;
			chk_is1_r  <= 1'b0;
			unit_is0_r <= 1'b1;
			unit_is1_r <= 1'b0;
		end else if (flush) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
			pend_is0_r <= 1'b1;
			pend_is1_r <= 1'b0;
			chk_is0_r  <= 1'b1;
			chk_is1_r  <= 1'b0;
			unit_is0_r <= 1'b1;
			unit_is1_r <= 1'b0;
		end else begin
			pend <= pend_n;
			chk_n <= chk_nx;
			unit_n <= unit_nx;
			pend_is0_r <= pend_n == 8'd0;
			pend_is1_r <= pend_n == 8'd1;
			chk_is0_r  <= chk_nx == 8'd0;
			chk_is1_r  <= chk_nx == 8'd1;
			unit_is0_r <= unit_nx == 10'd0;
			unit_is1_r <= unit_nx == 10'd1;
		end
	end
`endif

	function [1:0] nib_ag;
		input [3:0] n;
		begin
			nib_ag[1] = |n;
			nib_ag[0] = (n[0] & n[1]) | (n[2] & n[3]) | ((n[0] | n[1]) & (n[2] | n[3]));
		end
	endfunction

	/* Returns {is_zero, is_one} for up to 16 bits in <= 6 cmos3 gates. */
	function [1:0] fn_z1;
		input [15:0] v;
		reg [1:0] g0, g1, g2, g3;
		reg [3:0] na, ng;
		reg any_b, gt1_b;
		begin
			g0 = nib_ag(v[3:0]);
			g1 = nib_ag(v[7:4]);
			g2 = nib_ag(v[11:8]);
			g3 = nib_ag(v[15:12]);
			na = {g3[1], g2[1], g1[1], g0[1]};
			ng = {g3[0], g2[0], g1[0], g0[0]};
			any_b = |na;
			gt1_b = (|ng) | (na[0] & na[1]) | (na[2] & na[3]) | ((na[0] | na[1]) & (na[2] | na[3]));
			fn_z1 = {~any_b, any_b & ~gt1_b};
		end
	endfunction

	reg [15:0] tm_p, tcm_p, tu_p;
	always @(*) begin
		tm_p  = 16'd0;
		tcm_p = 16'd0;
		tu_p  = 16'd0;
		tm_p[NCLIENT-1:0]  = take_s & ~KEEP_MASK;
		tcm_p[NCLIENT-1:0] = take_s & take_chk_s;
		tu_p[NCLIENT-1:0]  = take_s & UNIT_MASK;
	end

	wire [1:0] tm_z1  = fn_z1(tm_p);
	wire [1:0] tcm_z1 = fn_z1(tcm_p);
	wire [1:0] tu_z1  = fn_z1(tu_p);
	wire ru_any = |(rsp_s & UNIT_MASK);

	assign pend_zero = dec_t ? ((pend_is1_r && tm_z1[1]) || (pend_is0_r && tm_z1[0]))
	                         : (pend_is0_r && tm_z1[1]);
	assign chk_idle  = done_chk_s ? ((chk_is1_r && tcm_z1[1]) || (chk_is0_r && tcm_z1[0]))
	                              : (chk_is0_r && tcm_z1[1]);
	assign unit_idle = ru_any ? ((unit_is1_r && tu_z1[1]) || (unit_is0_r && tu_z1[0]))
	                          : (unit_is0_r && tu_z1[1]);

	/* ax: precompute +1 and -1 in parallel with ax_inc/ax_dec control logic. */
	reg [7:0] ax_n;
	wire [7:0] ax_p1, ax_m1;
	wire [1:0] ax_co_unused;

	am_add #(.W(8)) ax_add_p1 (.a(ax_n), .b(8'd0), .ci(1'b1), .s(ax_p1), .co(ax_co_unused[0]));
	am_add #(.W(8)) ax_add_m1 (.a(ax_n), .b(8'hFF), .ci(1'b0), .s(ax_m1), .co(ax_co_unused[1]));
	wire [7:0] ax_next = (ax_inc_s == ax_dec_s) ? ax_n : (ax_inc_s ? ax_p1 : ax_m1);

`ifdef SYNTH_KINTEX7
	always @(posedge clk or posedge cnt_rst_sync)
		if (cnt_rst_sync) begin
			ax_n     <= 8'd0;
			ax_is0_r <= 1'b1;
			ax_is1_r <= 1'b0;
		end else begin
			ax_n     <= ax_next;
			ax_is0_r <= ax_next == 8'd0;
			ax_is1_r <= ax_next == 8'd1;
		end
`else
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			ax_n     <= 8'd0;
			ax_is0_r <= 1'b1;
			ax_is1_r <= 1'b0;
		end else begin
			ax_n     <= ax_next;
			ax_is0_r <= ax_next == 8'd0;
			ax_is1_r <= ax_next == 8'd1;
		end
`endif

	assign ax_zero = (ax_inc_s == ax_dec_s) ? ax_is0_r : (ax_inc_s ? 1'b0 : ax_is1_r);

	wire unused_ok = &{1'b0, ax_co_unused, cnt_co, t_csa_c[7], tc_csa_c[7], u_csa_c[9]};
endmodule

`default_nettype wire
