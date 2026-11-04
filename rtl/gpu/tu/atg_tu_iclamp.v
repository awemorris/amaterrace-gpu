/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_iclamp: a signed integer clamped into [0, n − 1] (the former
 * function iclamp of atg_tu_foot).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_iclamp #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire signed [32:0] v,
	input wire [15:0] n,
	output wire [15:0] c
);
	wire [15:0] n1;
	wire [15:0] cmp_d_unused;
	wire n1_bo_unused, cmp_bo;
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(n1_bo_unused));
	am_sub #(.W(16)) u_cmp (.a(v[15:0]), .b(n), .bi(1'b0), .d(cmp_d_unused), .bo(cmp_bo));
	wire v_lt0_s0 = v[32];
	wire v_ge_n_s0 = !v[32] && ((v[31:16] != 16'd0) || !cmp_bo);

	(* extract_reset = "no" *) reg        r_lt0, r_ge_n;
	(* extract_reset = "no" *) reg [15:0] r_n1, r_v;
	always @(posedge clk) begin
		if (en) begin
			r_lt0  <= v_lt0_s0;
			r_ge_n <= v_ge_n_s0;
			r_n1   <= n1;
			r_v    <= v[15:0];
		end
	end

	wire        s_lt0  = (LAT >= 1) ? r_lt0  : v_lt0_s0;
	wire        s_ge_n = (LAT >= 1) ? r_ge_n : v_ge_n_s0;
	wire [15:0] s_n1   = (LAT >= 1) ? r_n1   : n1;
	wire [15:0] s_v    = (LAT >= 1) ? r_v    : v[15:0];

	assign c = s_lt0 ? 16'd0 : s_ge_n ? s_n1 : s_v;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, en} : 1'b0;
	wire unused_ok = &{1'b0, rst_n, unused_lat0, cmp_d_unused};
endmodule

`default_nettype wire
