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
	 * The counts of this cycle's takes and responses: a chain of one
	 * adder per client for each (bit k added to the sum of the bits
	 * before it).
	 */
	wire [8*(NCLIENT+1)-1:0] t_c, tc_c;
	wire [10*(NCLIENT+1)-1:0] ui_c, uo_c;
	wire [4*NCLIENT-1:0] chain_co;

	assign t_c[7:0] = 8'd0;
	assign tc_c[7:0] = 8'd0;
	assign ui_c[9:0] = 10'd0;
	assign uo_c[9:0] = 10'd0;

	genvar g;
	generate
		for (g = 0; g < NCLIENT; g = g + 1) begin : pc
			am_add #(.W(8)) t_add (
				.a(t_c[8*g +: 8]), .b(8'd0), .ci(take[g] && !KEEP_MASK[g]),
				.s(t_c[8*(g+1) +: 8]), .co(chain_co[4*g])
			);
			am_add #(.W(8)) tc_add (
				.a(tc_c[8*g +: 8]), .b(8'd0), .ci(take[g] && take_chk[g]),
				.s(tc_c[8*(g+1) +: 8]), .co(chain_co[4*g+1])
			);
			am_add #(.W(10)) ui_add (
				.a(ui_c[10*g +: 10]), .b(10'd0), .ci(take[g] && UNIT_MASK[g]),
				.s(ui_c[10*(g+1) +: 10]), .co(chain_co[4*g+2])
			);
			am_add #(.W(10)) uo_add (
				.a(uo_c[10*g +: 10]), .b(10'd0), .ci(rsp[g] && UNIT_MASK[g]),
				.s(uo_c[10*(g+1) +: 10]), .co(chain_co[4*g+3])
			);
		end
	endgenerate

	wire [7:0] t_n = t_c[8*NCLIENT +: 8];
	wire [7:0] tc_n = tc_c[8*NCLIENT +: 8];
	wire [9:0] u_in = ui_c[10*NCLIENT +: 10];
	wire [9:0] u_out = uo_c[10*NCLIENT +: 10];

	/* Each counter: n + this cycle's takes, less this cycle's ends (an adder and a subtractor). */
	wire [7:0] pend_s, pend_n, chk_s, chk_nx;
	wire [9:0] unit_s, unit_nx;
	wire [5:0] cnt_co;

	am_add #(.W(8)) pend_add (.a(pend), .b(t_n), .ci(1'b0), .s(pend_s), .co(cnt_co[0]));
	am_sub #(.W(8)) pend_sub (
		.a(pend_s), .b(8'd0), .bi(done && !done_keep), .d(pend_n), .bo(cnt_co[1])
	);
	am_add #(.W(8)) chk_add (.a(chk_n), .b(tc_n), .ci(1'b0), .s(chk_s), .co(cnt_co[2]));
	am_sub #(.W(8)) chk_sub (.a(chk_s), .b(8'd0), .bi(done_chk), .d(chk_nx), .bo(cnt_co[3]));
	am_add #(.W(10)) unit_add (.a(unit_n), .b(u_in), .ci(1'b0), .s(unit_s), .co(cnt_co[4]));
	am_sub #(.W(10)) unit_sub (.a(unit_s), .b(u_out), .bi(1'b0), .d(unit_nx), .bo(cnt_co[5]));

	always @(posedge clk) begin
		if (!rst_n || flush) begin
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
		if (!rst_n)
			ax_n <= 8'd0;
		else
			ax_n <= ax_next;

	assign ax_zero = ax_n == 8'd0;

	wire unused_ok = &{1'b0, ax_co_unused, chain_co, cnt_co};
endmodule

`default_nettype wire
