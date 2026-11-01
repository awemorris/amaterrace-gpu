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

`include "atg_config.vh"

module atg_tu_cube_edge #(
	parameter LAT = 0
) (
	input  wire               clk,
	input  wire               rst_n,
	input  wire               en,
	input  wire [2:0]         face_in,      /* 0:+X, 1:-X, 2:+Y, 3:-Y, 4:+Z, 5:-Z */
	input  wire signed [16:0] u_in,
	input  wire signed [16:0] v_in,         /* Texel coordinates (signed, bit 16 is sign) */
	input  wire [15:0]        size,         /* Face size (n) */

	output reg  [2:0]         face_out,     /* Transformed face index */
	output reg  [15:0]        u_out,
	output reg  [15:0]        v_out         /* Transformed texel coordinates */
);

`ifdef CFG_ENABLE_3D_CUBE

	/* Out-of-bounds detection */
	wire [15:0] u_cmp_d, v_cmp_d, n1, n1u, n1v;
	wire u_cmp_bo, v_cmp_bo;
	wire [2:0] sub_bo_unused;

	am_sub #(.W(16)) u_cmp_u (.a(u_in[15:0]), .b(size), .bi(1'b0), .d(u_cmp_d), .bo(u_cmp_bo));
	am_sub #(.W(16)) u_cmp_v (.a(v_in[15:0]), .b(size), .bi(1'b0), .d(v_cmp_d), .bo(v_cmp_bo));
	am_sub #(.W(16)) u_sub_n1 (.a(size), .b(16'd0), .bi(1'b1), .d(n1), .bo(sub_bo_unused[0]));
	am_sub #(.W(16)) u_sub_n1u (.a(size), .b(u_in[15:0]), .bi(1'b1), .d(n1u), .bo(sub_bo_unused[1]));
	am_sub #(.W(16)) u_sub_n1v (.a(size), .b(v_in[15:0]), .bi(1'b1), .d(n1v), .bo(sub_bo_unused[2]));

	wire oi_lo_s0 = u_in[16];
	wire oi_hi_s0 = !u_in[16] && !u_cmp_bo;
	wire oj_lo_s0 = v_in[16];
	wire oj_hi_s0 = !v_in[16] && !v_cmp_bo;

	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg        r_oi_lo, r_oi_hi, r_oj_lo, r_oj_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [15:0] r_n1, r_n1u, r_n1v, r_u, r_v;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  r_face;
	always @(posedge clk) begin
		if (en) begin
			r_oi_lo <= oi_lo_s0;
			r_oi_hi <= oi_hi_s0;
			r_oj_lo <= oj_lo_s0;
			r_oj_hi <= oj_hi_s0;
			r_n1    <= n1;
			r_n1u   <= n1u;
			r_n1v   <= n1v;
			r_u     <= u_in[15:0];
			r_v     <= v_in[15:0];
			r_face  <= face_in;
		end
	end

	wire        oi_lo = (LAT >= 1) ? r_oi_lo : oi_lo_s0;
	wire        oi_hi = (LAT >= 1) ? r_oi_hi : oi_hi_s0;
	wire        oj_lo = (LAT >= 1) ? r_oj_lo : oj_lo_s0;
	wire        oj_hi = (LAT >= 1) ? r_oj_hi : oj_hi_s0;
	wire [15:0] s_n1  = (LAT >= 1) ? r_n1    : n1;
	wire [15:0] s_n1u = (LAT >= 1) ? r_n1u   : n1u;
	wire [15:0] s_n1v = (LAT >= 1) ? r_n1v   : n1v;
	wire [15:0] s_u   = (LAT >= 1) ? r_u     : u_in[15:0];
	wire [15:0] s_v   = (LAT >= 1) ? r_v     : v_in[15:0];
	wire [2:0]  s_f   = (LAT >= 1) ? r_face  : face_in;

	wire oi = oi_lo || oi_hi;
	wire oj = oj_lo || oj_hi;

	/* Edge index: 0: u < 0, 1: u >= size, 2: v < 0, 3: v >= size */
	wire [1:0] e = oi ? {1'b0, oi_hi} : {1'b1, oj_hi};
	wire [15:0] a = oi ? s_v : s_u;
	wire [15:0] n1a = oi ? s_n1v : s_n1u;

	/* 12-edge adjacent face and coordinate mapping table */
	reg [2:0] g;
	reg [1:0] xi, xj;

	always @(*) begin
		case ({s_f, e})
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
	                 (xi == 2'd1) ? s_n1 :
	                 (xi == 2'd2) ? a : n1a;
	wire [15:0] rj = (xj == 2'd0) ? 16'd0 :
	                 (xj == 2'd1) ? s_n1 :
	                 (xj == 2'd2) ? a : n1a;

	/* Corner clamping fallback */
	wire [15:0] ci = oi_lo ? 16'd0 : s_n1;
	wire [15:0] cj = oj_lo ? 16'd0 : s_n1;

	always @(*) begin
		if (oi && oj) begin
			face_out = s_f;
			u_out = ci;
			v_out = cj;
		end else if (!oi && !oj) begin
			face_out = s_f;
			u_out = s_u;
			v_out = s_v;
		end else begin
			face_out = g;
			u_out = ri;
			v_out = rj;
		end
	end

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, en} : 1'b0;
	wire unused_ok = &{1'b0, rst_n, sub_bo_unused, u_cmp_d, v_cmp_d, unused_lat0};

`else

	always @(*) begin
		face_out = face_in;
		u_out    = u_in[15:0];
		v_out    = v_in[15:0];
	end

	wire unused_cube_edge_stub = &{1'b0, size};

`endif

endmodule

`default_nettype wire
