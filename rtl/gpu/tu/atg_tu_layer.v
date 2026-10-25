/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_layer: Vulkan's layer clamp(RNE(f), 0, cnt − 1); NaN, zeros,
 * denormals and negative values give 0 (the former function tu_layer of
 * include/atg_tu_fn.vh; tools/tumodel.py rne_layer).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_layer (
	input wire [31:0] f,
	input wire [15:0] cnt,
	output wire [15:0] l
);
	/* k = 150 - e: for 1 <= k <= 24, 1.f >> k, the remainder and half the step */
	wire [8:0] k;
	wire [23:0] qs;
	wire [24:0] tv;
	wire [15:0] c1;
	wire [2:0] carry_unused;
	am_sub #(.W(9)) u_k (.a(9'd150), .b({1'b0, f[30:23]}), .bi(1'b0), .d(k), .bo(carry_unused[0]));
	wire kin = !k[8] && k >= 9'd1 && k <= 9'd24;
	am_shift #(.W(24), .SW(5)) u_qs (.a({1'b1, f[22:0]}), .amt(k[4:0]), .left(1'b0), .arith(1'b0),
		.y(qs));
	wire [23:0] q = kin ? qs : 24'd0;
	reg [23:0] rem, half;
	integer b;
	always @(*)
		for (b = 0; b < 24; b = b + 1) begin
			rem[b] = kin && b < k && (b == 23 || f[b]);
			half[b] = kin && b + 1 == {23'd0, k};
		end
	am_add #(.W(25)) u_tv (.a({1'b0, q}), .b(25'd0), .ci(rem > half || (rem == half && q[0])), .s(tv),
		.co(carry_unused[1]));
	am_sub #(.W(16)) u_c1 (.a(cnt), .b(16'd0), .bi(1'b1), .d(c1), .bo(carry_unused[2]));
	assign l = f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0) || f[31] ? 16'd0 :
		k[8] || k == 9'd0 || tv >= {9'd0, cnt} ? c1 : tv[15:0];
endmodule

`default_nettype wire
