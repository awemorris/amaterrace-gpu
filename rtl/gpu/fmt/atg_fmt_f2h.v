/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_f2h: fp32 to fp16, to nearest even (overflow to infinity, NaN
 * 0x7E00, half denormals exact, fp32 denormals 0); the former function
 * atg_fmt_f2h of include/atg_fmt_pack.vh (tools/fmtmodel.py).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_f2h (
	input wire [31:0] f,
	output wire [15:0] h
);
	/* normal: the mantissa rounded at bit 13, the exponent e - 112 (+ 1 for a carry) */
	wire [23:0] m = {1'b1, f[22:0]};
	wire [11:0] q;
	wire [7:0] ex;
	wire [4:0] sh, sh1;
	wire [23:0] ds;
	wire [14:0] dr;
	wire [4:0] carry_unused;
	am_add #(.W(12)) u_q (.a({1'b0, m[23:13]}), .b(12'd0), .ci(f[12] && (f[11:0] != 12'd0 || f[13])),
		.s(q), .co(carry_unused[0]));
	am_sub #(.W(8)) u_ex (.a(f[30:23]), .b(q[11] ? 8'd111 : 8'd112), .bi(1'b0), .d(ex),
		.bo(carry_unused[1]));
	/* half denormals: m >> (126 - e), RNE */
	am_sub #(.W(5)) u_sh (.a(5'd30), .b(f[27:23]), .bi(1'b0), .d(sh),
		.bo(carry_unused[2]));	/* 126 - e mod 32 */
	am_sub #(.W(5)) u_sh1 (.a(sh), .b(5'd0), .bi(1'b1), .d(sh1), .bo(carry_unused[3]));
	am_shift #(.W(24), .SW(5)) u_ds (.a(m), .amt(sh), .left(1'b0), .arith(1'b0), .y(ds));
	wire g = m[sh1];
	/* the sticky bits below the guard: m & (2^sh1 - 1) */
	wire [23:0] hi;	/* the bits from sh1 up */
	am_shift #(.W(24), .SW(5)) u_hi (.a({24{1'b1}}), .amt(sh1), .left(1'b1), .arith(1'b0), .y(hi));
	wire st = (m & ~hi) != 24'd0;
	am_add #(.W(15)) u_dr (.a(ds[14:0]), .b(15'd0), .ci(g && (st || ds[0])), .s(dr),
		.co(carry_unused[4]));
	assign h = f[30:23] == 8'hFF ? (f[22:0] != 23'd0 ? 16'h7E00 : {f[31], 15'h7C00}) :
		f[30:23] >= 8'd113 ? (ex >= 8'd31 || f[30:23] > 8'd142 ? {f[31], 15'h7C00} :
			{f[31], ex[4:0], q[11:10] != 2'b01 ? 10'd0 : q[9:0]}) :
		f[30:23] <= 8'd101 ? {f[31], 15'd0} : {f[31], dr};

	wire unused_ok = &{1'b0, ds[23:15]};
endmodule

`default_nettype wire
