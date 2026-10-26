/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_edge: Cube map boundary (Face Edge) texel coordinate remapping
 * for seamless filtering (Phase 005 / ws002-p005).
 *
 * Remaps out-of-bound texel coordinates across the 12 edges of a cube map
 * to the corresponding adjacent face and rotated coordinates.
 *
 * Faces:
 * 0: +X, 1: -X, 2: +Y, 3: -Y, 4: +Z, 5: -Z
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_edge (
	input  wire [2:0]         face_in,      /* 0:+X, 1:-X, 2:+Y, 3:-Y, 4:+Z, 5:-Z */
	input  wire signed [15:0] u_in,
	input  wire signed [15:0] v_in,         /* Texel coordinates (signed) */
	input  wire [15:0]        size,         /* Face size (n) */

	output reg  [2:0]         face_out,     /* Transformed face index */
	output reg  [15:0]        u_out,
	output reg  [15:0]        v_out         /* Transformed texel coordinates */
);

	/* Out-of-bounds detection */
	wire oi_lo = u_in[15];
	wire oi_hi = !u_in[15] && (u_in >= size);
	wire oi = oi_lo || oi_hi;

	wire oj_lo = v_in[15];
	wire oj_hi = !v_in[15] && (v_in >= size);
	wire oj = oj_lo || oj_hi;

	/* Edge index: 0: u < 0, 1: u >= size, 2: v < 0, 3: v >= size */
	wire [1:0] e = oi ? {1'b0, oi_hi} : {1'b1, oj_hi};
	wire [15:0] a = oi ? v_in : u_in;

	/* Boundary coordinate calculations: n1 = size - 1, n1a = size - 1 - a */
	wire [15:0] n1, n1a;
	wire [1:0] sub_bo_unused;

	am_sub #(.W(16)) u_sub_n1 (
		.a(size), .b(16'd0), .bi(1'b1), .d(n1), .bo(sub_bo_unused[0])
	);
	am_sub #(.W(16)) u_sub_n1a (
		.a(n1), .b(a), .bi(1'b0), .d(n1a), .bo(sub_bo_unused[1])
	);

	/* 12-edge adjacent face and coordinate mapping table */
	reg [2:0] g;
	reg [1:0] xi, xj;

	always @(*) begin
		case ({face_in, e})
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
		default:   {g, xi, xj} = {3'd3, 2'd3, 2'd1};
		endcase
	end

	wire [15:0] ri = (xi == 2'd0) ? 16'd0 :
	                 (xi == 2'd1) ? n1 :
	                 (xi == 2'd2) ? a : n1a;
	wire [15:0] rj = (xj == 2'd0) ? 16'd0 :
	                 (xj == 2'd1) ? n1 :
	                 (xj == 2'd2) ? a : n1a;

	/* Corner clamping fallback */
	wire [15:0] ci = oi_lo ? 16'd0 : n1;
	wire [15:0] cj = oj_lo ? 16'd0 : n1;

	always @(*) begin
		if (oi && oj) begin
			face_out = face_in;
			u_out = ci;
			v_out = cj;
		end else if (!oi && !oj) begin
			face_out = face_in;
			u_out = u_in;
			v_out = v_in;
		end else begin
			face_out = g;
			u_out = ri;
			v_out = rj;
		end
	end

	wire unused_ok = &{1'b0, sub_bo_unused};

endmodule

`default_nettype wire
