/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_f2fix: fp32 to 15.8 fixed point (24 bits, two's complement), RNE,
 * saturated to +-(2^22 - 1), NaN and values below 2^-33 give 0 (the
 * former function f2fix of atg_rx_edge).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_f2fix (
	input wire [31:0] f,
	output wire [23:0] q
);
	/* 1.f >> (142 - e), RNE at bit 24, the sign */
	wire [7:0] s;
	wire [47:0] v;
	wire [23:0] r, rs;
	wire s_bo_unused, r_co_unused, rs_co_unused;
	am_sub #(.W(8)) u_s (.a(8'd142), .b(f[30:23]), .bi(1'b0), .d(s), .bo(s_bo_unused));
	am_shift #(.W(48), .SW(8)) u_v (.a({1'b1, f[22:0], 24'd0}), .amt(s), .left(1'b0), .arith(1'b0),
		.y(v));
	am_add #(.W(24)) u_r (.a(v[47:24]), .b(24'd0), .ci(v[23] && (v[22:0] != 23'd0 || v[24])), .s(r),
		.co(r_co_unused));
	am_addsub #(.W(24)) u_rs (.a(24'd0), .b(r), .sub(f[31]), .s(rs), .co(rs_co_unused));

	assign q = f[30:23] < 8'd94 || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ? 24'd0 :
		f[30:23] >= 8'd142 || r > 24'h3FFFFF ? (f[31] ? 24'hC00001 : 24'h3FFFFF) : rs;
endmodule

`default_nettype wire
