/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_texel: a texel of a cube face's bilinear footprint (i, j in
 * [−1, n]): {face, i, j} on the face; beyond one edge the adjacent face's
 * texel (tools/tumodel.py CUBE_ADJ: edge 0 i < 0, 1 i >= n, 2 j < 0, 3 j
 * >= n; i' and j' 0, n − 1, a or n − 1 − a with a the coordinate along
 * the edge); beyond two (a corner) the face's own corner texel (the
 * former function tu_cube_texel of include/atg_tu_fn.vh).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_texel (
	input wire [2:0] tface,
	input wire signed [23:0] i,
	input wire signed [23:0] j,
	input wire [15:0] n,
	output wire [34:0] t
);
	wire oi = i < 0 || i >= $signed({8'd0, n});
	wire oj = j < 0 || j >= $signed({8'd0, n});
	wire [1:0] e = oi ? {1'b0, !(i < 0)} : {1'b1, !(j < 0)};
	wire [15:0] a = oi ? j[15:0] : i[15:0];
	reg [1:0] xi, xj;
	reg [2:0] g;
	always @(*)
		case ({tface, e})
		5'b000_00: {g, xi, xj} = {3'd4, 2'd1, 2'd2};
		5'b000_01: {g, xi, xj} = {3'd5, 2'd0, 2'd2};
		5'b000_10: {g, xi, xj} = {3'd2, 2'd1, 2'd3};
		5'b000_11: {g, xi, xj} = {3'd3, 2'd1, 2'd2};
		5'b001_00: {g, xi, xj} = {3'd5, 2'd1, 2'd2};
		5'b001_01: {g, xi, xj} = {3'd4, 2'd0, 2'd2};
		5'b001_10: {g, xi, xj} = {3'd2, 2'd0, 2'd2};
		5'b001_11: {g, xi, xj} = {3'd3, 2'd0, 2'd3};
		5'b010_00: {g, xi, xj} = {3'd1, 2'd2, 2'd0};
		5'b010_01: {g, xi, xj} = {3'd0, 2'd3, 2'd0};
		5'b010_10: {g, xi, xj} = {3'd5, 2'd3, 2'd0};
		5'b010_11: {g, xi, xj} = {3'd4, 2'd2, 2'd0};
		5'b011_00: {g, xi, xj} = {3'd1, 2'd3, 2'd1};
		5'b011_01: {g, xi, xj} = {3'd0, 2'd2, 2'd1};
		5'b011_10: {g, xi, xj} = {3'd4, 2'd2, 2'd1};
		5'b011_11: {g, xi, xj} = {3'd5, 2'd3, 2'd1};
		5'b100_00: {g, xi, xj} = {3'd1, 2'd1, 2'd2};
		5'b100_01: {g, xi, xj} = {3'd0, 2'd0, 2'd2};
		5'b100_10: {g, xi, xj} = {3'd2, 2'd2, 2'd1};
		5'b100_11: {g, xi, xj} = {3'd3, 2'd2, 2'd0};
		5'b101_00: {g, xi, xj} = {3'd0, 2'd1, 2'd2};
		5'b101_01: {g, xi, xj} = {3'd1, 2'd0, 2'd2};
		5'b101_10: {g, xi, xj} = {3'd2, 2'd3, 2'd0};
		default: {g, xi, xj} = {3'd3, 2'd3, 2'd1};
		endcase
	/* n − 1 and n − 1 − a */
	wire [15:0] n1, n1a;
	wire [1:0] carry_unused;
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(carry_unused[0]));
	am_sub #(.W(16)) u_n1a (.a(n1), .b(a), .bi(1'b0), .d(n1a), .bo(carry_unused[1]));
	wire [15:0] ri = xi == 2'd0 ? 16'd0 : xi == 2'd1 ? n1 : xi == 2'd2 ? a : n1a;
	wire [15:0] rj = xj == 2'd0 ? 16'd0 : xj == 2'd1 ? n1 : xj == 2'd2 ? a : n1a;
	/* a corner: i and j clamped into [0, n − 1] */
	wire [15:0] ci = i < 0 ? 16'd0 : i >= $signed({8'd0, n}) ? n1 : i[15:0];
	wire [15:0] cj = j < 0 ? 16'd0 : j >= $signed({8'd0, n}) ? n1 : j[15:0];
	assign t = oi && oj ? {tface, ci, cj} : !oi && !oj ? {tface, i[15:0], j[15:0]} : {g, ri, rj};
endmodule

`default_nettype wire
