/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_f2u8: fp32 to unorm8 for the ROP's blend: NaN, ≤ 0 (−0
 * included) and denormals give 0, ≥ 1 gives 255, else RNE(f × 255).
 * Combinational (the former function f2u8 of atg_rop_blend).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_f2u8 (
	input wire [31:0] f,
	output wire [7:0] u
);
	/* m × 255 = (m << 8) − m, m = 1.f; shifted right by 126 − e; RNE at bit 34. */
	wire [31:0] p;
	wire [3:0] t;	/* s - 24 = 126 - e for e in 117..126 */
	wire [41:0] z;
	wire [7:0] r;
	wire p_bo_unused, t_bo_unused, r_co_unused;
	am_sub #(.W(32)) u_p (.a({1'b1, f[22:0], 8'd0}), .b({8'd0, 1'b1, f[22:0]}), .bi(1'b0), .d(p),
		.bo(p_bo_unused));
	am_sub #(.W(4)) u_t (.a(4'd14), .b(f[26:23]), .bi(1'b0), .d(t), .bo(t_bo_unused));
	am_shift #(.W(42), .SW(4)) u_z (.a({p, 10'd0}), .amt(t), .left(1'b0), .arith(1'b0), .y(z));
	am_add #(.W(8)) u_r (.a(z[41:34]), .b(8'd0), .ci(z[33] && (z[32:0] != 33'd0 || z[34])), .s(r),
		.co(r_co_unused));

	assign u = f[30:23] == 8'd0 || f[31] || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ||
		f[30:23] < 8'd117 ? 8'd0 : f[30:23] >= 8'd127 ? 8'd255 : r;
endmodule

`default_nettype wire
