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
	wire [8*(NCLIENT+1)-1:0] t_c, tc_c;
	wire [10*(NCLIENT+1)-1:0] ui_c;
	wire [3*NCLIENT-1:0] chain_co;

	assign t_c[7:0] = {8{done && !done_keep}};
	assign tc_c[7:0] = {8{done_chk}};
	assign ui_c[9:0] = 10'd0;

	genvar g;
	generate
		for (g = 0; g < NCLIENT; g = g + 1) begin : pc
			am_add #(.W(8)) t_add (
				.a(t_c[8*g +: 8]), .b(8'd0), .ci(take[g] && !KEEP_MASK[g]),
				.s(t_c[8*(g+1) +: 8]), .co(chain_co[3*g])
			);
			am_add #(.W(8)) tc_add (
				.a(tc_c[8*g +: 8]), .b(8'd0), .ci(take[g] && take_chk[g]),
				.s(tc_c[8*(g+1) +: 8]), .co(chain_co[3*g+1])
			);
			am_add #(.W(10)) ui_add (
				.a(ui_c[10*g +: 10]), .b({10{rsp[g] && UNIT_MASK[g]}}),
				.ci(take[g] && UNIT_MASK[g]),
				.s(ui_c[10*(g+1) +: 10]), .co(chain_co[3*g+2])
			);
		end
	endgenerate

	wire [7:0] t_n = t_c[8*NCLIENT +: 8];
	wire [7:0] tc_n = tc_c[8*NCLIENT +: 8];
	wire [9:0] u_delta = ui_c[10*NCLIENT +: 10];

	/* Each counter: n + this cycle's net delta in a single adder. */
	wire [7:0] pend_n, chk_nx;
	wire [9:0] unit_nx;
	wire [2:0] cnt_co;

	am_add #(.W(8)) pend_add (.a(pend), .b(t_n), .ci(1'b0), .s(pend_n), .co(cnt_co[0]));
	am_add #(.W(8)) chk_add (.a(chk_n), .b(tc_n), .ci(1'b0), .s(chk_nx), .co(cnt_co[1]));
	am_add #(.W(10)) unit_add (.a(unit_n), .b(u_delta), .ci(1'b0), .s(unit_nx), .co(cnt_co[2]));

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire cnt_flush_rst_sync;
	(* keep = "true", dont_touch = "true" *) wire cnt_rst_sync;
	(* DONT_TOUCH = "TRUE" *) LUT2 #(.INIT(4'hD)) u_cnt_frst (
		.I0(rst_n), .I1(flush), .O(cnt_flush_rst_sync)
	);
	(* DONT_TOUCH = "TRUE" *) LUT1 #(.INIT(2'h1)) u_cnt_rst (
		.I0(rst_n), .O(cnt_rst_sync)
	);
`else
	wire cnt_flush_rst_sync = !rst_n || flush;
	wire cnt_rst_sync = !rst_n;
`endif

	always @(posedge clk) begin
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
		.a(ax_n), .b({8{ax_dec}}), .ci(ax_inc), .s(ax_next), .co(ax_co_unused)
	);

	always @(posedge clk)
		if (cnt_rst_sync)
			ax_n <= 8'd0;
		else
			ax_n <= ax_next;

	assign ax_zero = ax_n == 8'd0;

	wire unused_ok = &{1'b0, ax_co_unused, chain_co, cnt_co};
endmodule

`default_nettype wire
