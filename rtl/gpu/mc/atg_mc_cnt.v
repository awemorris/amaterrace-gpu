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
 *
 * rst_n and flush clear them.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_cnt #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] UNIT_MASK = {NCLIENT{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire [NCLIENT-1:0] take,
	input wire [NCLIENT-1:0] take_chk,
	input wire [NCLIENT-1:0] rsp,
	input wire done,
	input wire done_chk,
	output wire pend_zero,
	output wire chk_idle,
	output wire unit_idle
);
	reg [7:0] pend, chk_n;
	reg [9:0] unit_n;
	reg [7:0] t_n, tc_n;
	reg [9:0] u_in, u_out;
	integer k;

	always @(*) begin
		t_n = 8'd0;
		tc_n = 8'd0;
		u_in = 10'd0;
		u_out = 10'd0;
		for (k = 0; k < NCLIENT; k = k + 1) begin
			t_n = t_n + {7'd0, take[k]};
			tc_n = tc_n + {7'd0, take[k] && take_chk[k]};
			u_in = u_in + {9'd0, take[k] && UNIT_MASK[k]};
			u_out = u_out + {9'd0, rsp[k] && UNIT_MASK[k]};
		end
	end

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			pend <= 8'd0;
			chk_n <= 8'd0;
			unit_n <= 10'd0;
		end else begin
			pend <= pend + t_n - {7'd0, done};
			chk_n <= chk_n + tc_n - {7'd0, done_chk};
			unit_n <= unit_n + u_in - u_out;
		end
	end

	assign pend_zero = pend == 8'd0;
	assign chk_idle = chk_n == 8'd0;
	assign unit_idle = unit_n == 10'd0;
endmodule

`default_nettype wire
