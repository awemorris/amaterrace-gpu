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

module atg_tu_iclamp (
	input wire signed [32:0] v,
	input wire [15:0] n,
	output wire [15:0] c
);
	wire [15:0] n1;
	wire n1_bo_unused;
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(n1_bo_unused));
	assign c = v < 0 ? 16'd0 : v >= $signed({17'd0, n}) ? n1 : v[15:0];
endmodule

`default_nettype wire
