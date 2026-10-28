/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_texel: a texel of a cube face's bilinear footprint (i, j in
 * [−1, n]): {face, i, j} on the face; beyond one edge the adjacent face's
 * texel. Delegates to atg_tu_cube_edge (Phase 005 / ws002-p005).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_texel (
	input  wire [2:0]         tface,
	input  wire signed [23:0] i,
	input  wire signed [23:0] j,
	input  wire [15:0]        n,
	output wire [34:0]        t
);

	wire [2:0] face_out;
	wire [15:0] u_out, v_out;

	atg_tu_cube_edge u_cube_edge (
		.face_in(tface),
		.u_in(i[16:0]),
		.v_in(j[16:0]),
		.size(n),
		.face_out(face_out),
		.u_out(u_out),
		.v_out(v_out)
	);

	assign t = {face_out, u_out, v_out};

	wire unused_ok = &{1'b0, i[23:17], j[23:17]};

endmodule

`default_nettype wire
