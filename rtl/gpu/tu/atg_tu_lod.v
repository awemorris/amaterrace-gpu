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
 * fraction bits, >> 8) against the width.  One axis at a time: lam is λA
 * of axis ax (0 u, 1 v, 2 w; w is -32768 but for a 3D image), and
 * atg_tu_addr takes the largest over three cycles.  See
 * spec/gpu/tu/atg_tu_lod.md.
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
	input wire [1:0] ax,	/* the axis: 0 u, 1 v, 2 w */
	output wire signed [16:0] lam
);
	`include "atg_tu_fn.vh"
	localparam signed [16:0] LAM_MIN = -17'sd32768;

	/* The axis' fixed-point lane values: floor(x × 2^16), or the cube's
	 * >> 8, and its size. */
	reg [95:0] fa;
	integer i;
	always @(*)
		for (i = 0; i < 3; i = i + 1)
			fa[i*32 +: 32] = cube && !ax[1] ?
				(ax[0] ? {{13{ct[i*27 + 26]}}, ct[i*27 + 8 +: 19]} :
				{{13{cs[i*27 + 26]}}, cs[i*27 + 8 +: 19]}) :
				tu_fx32(ax[1] ? w[i*32 +: 32] : ax[0] ? v[i*32 +: 32] : u[i*32 +: 32], 5'd16);
	wire [15:0] n = ax[1] ? d0 : ax[0] && !cube ? h0 : w0;
	/* The axis: the lanes' differences to lane 0, the larger magnitude mx, then
	 * log2(mx) + log2(n) - 1.0 (Q8 in a signed 17-bit value). */
	wire [32:0] d1, d2, m1, m2;
	wire [16:0] l2s, lsum;
	wire [5:0] lod_carry_unused;
	am_sub #(.W(33)) u_d1 (.a({fa[63], fa[63:32]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d1),
		.bo(lod_carry_unused[0]));
	am_sub #(.W(33)) u_d2 (.a({fa[95], fa[95:64]}), .b({fa[31], fa[31:0]}), .bi(1'b0), .d(d2),
		.bo(lod_carry_unused[1]));
	am_addsub #(.W(33)) u_m1 (.a(33'd0), .b(d1), .sub(d1[32]), .s(m1), .co(lod_carry_unused[2]));
	am_addsub #(.W(33)) u_m2 (.a(33'd0), .b(d2), .sub(d2[32]), .s(m2), .co(lod_carry_unused[3]));
	wire [32:0] mx = m1 > m2 ? m1 : m2;
	am_add #(.W(17)) u_l2s (.a({3'd0, tu_l2(mx)}), .b({3'd0, tu_l2({17'd0, n})}), .ci(1'b0), .s(l2s),
		.co(lod_carry_unused[4]));
	am_sub #(.W(17)) u_lsum (.a(l2s), .b(17'd4096), .bi(1'b0), .d(lsum), .bo(lod_carry_unused[5]));
	assign lam = ax[1] && !is3d ? LAM_MIN : mx == 33'd0 ? LAM_MIN : lsum;

	wire unused_ok = &{1'b0, cs[7:0], cs[34:27], cs[61:54], ct[7:0], ct[34:27], ct[61:54]};
endmodule

`default_nettype wire
