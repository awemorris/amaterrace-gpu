/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_f2unorm: fp32 to a w-bit UNORM (w <= 16), RNE(clamp01(f) x
 * (2^w - 1)); NaN and negative values (-0 included) give 0 (the former
 * function atg_fmt_f2unorm of include/atg_fmt_pack.vh; tools/fmtmodel.py
 * is the reference).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_f2unorm (
	input wire [31:0] f,
	input wire [5:0] w,
	output wire [15:0] u
);
	/* m (2^w - 1) = (m << w) - m, shifted right by sa = 150 - e; RNE */
	wire [47:0] pw, p, ps;
	wire [5:0] sa, sa1;
	wire [15:0] r;
	wire [3:0] carry_unused;
	am_shift #(.W(48), .SW(6)) u_pw (.a({24'd0, 1'b1, f[22:0]}), .amt(w), .left(1'b1), .arith(1'b0),
		.y(pw));
	am_sub #(.W(48)) u_p (.a(pw), .b({24'd0, 1'b1, f[22:0]}), .bi(1'b0), .d(p),
		.bo(carry_unused[0]));
	am_sub #(.W(6)) u_sa (.a(6'd22), .b(f[28:23]), .bi(1'b0), .d(sa),
		.bo(carry_unused[1]));	/* 150 - e mod 64 */
	am_sub #(.W(6)) u_sa1 (.a(sa), .b(6'd0), .bi(1'b1), .d(sa1), .bo(carry_unused[2]));
	am_shift #(.W(48), .SW(6)) u_ps (.a(p), .amt(sa), .left(1'b0), .arith(1'b0), .y(ps));
	wire g = p[sa1];
	/* the sticky bits below the guard: p & (2^sa1 - 1); 2^w - 1 */
	wire [47:0] hi;	/* the bits from sa1 up */
	wire [15:0] wh;	/* the bits from w up */
	am_shift #(.W(48), .SW(6)) u_hi (.a({48{1'b1}}), .amt(sa1), .left(1'b1), .arith(1'b0), .y(hi));
	am_shift #(.W(16), .SW(6)) u_wh (.a({16{1'b1}}), .amt(w), .left(1'b1), .arith(1'b0), .y(wh));
	wire st = (p & ~hi) != 48'd0;
	wire [15:0] ones = ~wh;	/* 2^w - 1 */
	am_add #(.W(16)) u_r (.a(ps[15:0]), .b(16'd0), .ci(g && (st || ps[0])), .s(r),
		.co(carry_unused[3]));
	assign u = f[31] || (f[30:23] == 8'hFF && f[22:0] != 23'd0) || f[30:23] < 8'd103 ? 16'd0 :
		f[30:23] >= 8'd127 ? ones : r;

	wire unused_ok = &{1'b0, ps[47:16]};
endmodule

`default_nettype wire
