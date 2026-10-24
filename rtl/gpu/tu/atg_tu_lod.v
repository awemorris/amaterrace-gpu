/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_lod: the quad's level of detail of texb (combinational; part of
 * atg_tu_addr, tools/tumodel.py lod_quad is the reference, bit for bit).
 *
 * From lanes 0, 1 (x + 1) and 2 (y + 1): per axis A the largest |A1 − A0|,
 * |A2 − A0|, λA = L2(that) + L2(size) − 4096 (L2(x) = 256 × msb position +
 * the 8 bits below the msb; −32768 for 0), λ = the largest λA saturated to
 * 16 bits.  The axes: u and v as floor(x × 2^16) against the width and
 * the height; a 3D image also w against the depth; a cube the face
 * coordinates s and t of the three lanes on lane 0's face (cs, ct: 24
 * fraction bits, >> 8) against the width.  See spec/gpu/tu/atg_tu_lod.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_lod (
	input wire [95:0] u,	/* lanes 0-2, lane 0 in the low bits */
	input wire [95:0] v,
	input wire [95:0] w,	/* the third coordinates (3D) */
	input wire [80:0] cs,	/* cube: s of lanes 0-2 on lane 0's face (27 bits each) */
	input wire [80:0] ct,
	input wire is3d,
	input wire cube,
	input wire [15:0] w0,	/* level 0: width, height, depth (3D) */
	input wire [15:0] h0,
	input wire [15:0] d0,
	output wire signed [16:0] lam
);
	`include "atg_tu_fn.vh"
	localparam signed [16:0] LAM_MIN = -17'sd32768;

	/* One axis: the lanes' fixed-point values a0..a2 against size n. */
	function signed [16:0] axis;
		input [95:0] a;
		input [15:0] n;
		reg signed [32:0] d1, d2;
		reg [32:0] m1, m2, mx;
		begin
			d1 = $signed({a[63], a[63:32]}) - $signed({a[31], a[31:0]});
			d2 = $signed({a[95], a[95:64]}) - $signed({a[31], a[31:0]});
			m1 = d1[32] ? -d1 : d1;
			m2 = d2[32] ? -d2 : d2;
			mx = m1 > m2 ? m1 : m2;
			axis = mx == 33'd0 ? LAM_MIN :
				$signed({3'd0, tu_l2(mx)}) + $signed({3'd0, tu_l2({17'd0, n})}) - 17'sd4096;
		end
	endfunction

	/* The fixed-point lane values: floor(x × 2^16), or the cube's >> 8. */
	reg [95:0] fu, fv, fw;
	integer i;
	always @(*)
		for (i = 0; i < 3; i = i + 1) begin
			fu[i*32 +: 32] = cube ? {{13{cs[i*27 + 26]}}, cs[i*27 + 8 +: 19]} :
				tu_fx32(u[i*32 +: 32], 5'd16);
			fv[i*32 +: 32] = cube ? {{13{ct[i*27 + 26]}}, ct[i*27 + 8 +: 19]} :
				tu_fx32(v[i*32 +: 32], 5'd16);
			fw[i*32 +: 32] = tu_fx32(w[i*32 +: 32], 5'd16);
		end
	wire signed [16:0] lu = axis(fu, w0);
	wire signed [16:0] lv = axis(fv, cube ? w0 : h0);
	wire signed [16:0] lw = is3d ? axis(fw, d0) : LAM_MIN;
	wire signed [16:0] luv = lu > lv ? lu : lv;
	assign lam = luv > lw ? luv : lw;

	wire unused_ok = &{1'b0, cs[7:0], cs[34:27], cs[61:54], ct[7:0], ct[34:27], ct[61:54]};
endmodule

`default_nettype wire
