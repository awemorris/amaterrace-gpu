/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_depth_u24: fp32 in [0, 1] to unorm24, RNE(f × (2^24 − 1)); NaN,
 * ≤ 0 and denormals give 0, ≥ 1 all ones (the former atg_depth_u24 of
 * include/atg_depth.vh; tools/rxmodel.py f2u24 is the reference).  Shared
 * by the ROP's depth test and the TU's compare samplers.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_depth_u24 (
	input wire [31:0] f,
	output wire [23:0] u
);
	/* m × (2^24 − 1) = (m << 24) − m, m = 1.f (24 bits). */
	wire [47:0] p;
	wire [4:0] t;	/* 126 − e for e in 102..126 */
	wire [71:0] z;
	wire [23:0] r;
	wire p_bo_unused, t_bo_unused, r_co_unused;
	am_sub #(.W(48)) u_p (.a({1'b1, f[22:0], 24'd0}), .b({24'd0, 1'b1, f[22:0]}), .bi(1'b0), .d(p),
		.bo(p_bo_unused));
	am_sub #(.W(5)) u_t (.a(5'd30), .b(f[27:23]), .bi(1'b0), .d(t), .bo(t_bo_unused));
	am_shift #(.W(72), .SW(5)) u_z (.a({p, 24'd0}), .amt(t), .left(1'b0), .arith(1'b0), .y(z));
	/* RNE at bit 48. */
	am_add #(.W(24)) u_r (.a(z[71:48]), .b(24'd0), .ci(z[47] && (z[46:0] != 47'd0 || z[48])), .s(r),
		.co(r_co_unused));

	wire e0 = f[30:23] == 8'd0;
	wire nan = f[30:23] == 8'hFF && f[22:0] != 23'd0;
	assign u = e0 || f[31] || nan || f[30:23] < 8'd102 ? 24'd0 :
		f[30:23] >= 8'd127 ? 24'hFFFFFF : r;
endmodule

`default_nettype wire
