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

module atg_tu_layer #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
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
	reg round_bit, sticky_bit;
	integer b;
	always @(*) begin
		round_bit = 1'b0;
		sticky_bit = 1'b0;
		for (b = 0; b < 24; b = b + 1) begin
			if (kin && b + 1 == {23'd0, k})
				round_bit = (b == 23 || f[b]);
			if (kin && b + 1 < {23'd0, k} && (b == 23 || f[b]))
				sticky_bit = 1'b1;
		end
	end

	/* Pipeline register when LAT >= 1 */
	reg [23:0] r_q;
	reg        r_round_bit, r_sticky_bit;
	reg [8:0]  r_k;
	reg [15:0] r_cnt;
	reg [31:0] r_f;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_q          <= 24'd0;
			r_round_bit  <= 1'b0;
			r_sticky_bit <= 1'b0;
			r_k          <= 9'd0;
			r_cnt        <= 16'd0;
			r_f          <= 32'd0;
		end else if (en) begin
			r_q          <= q;
			r_round_bit  <= round_bit;
			r_sticky_bit <= sticky_bit;
			r_k          <= k;
			r_cnt        <= cnt;
			r_f          <= f;
		end
	end

	wire [23:0] s1_q          = (LAT >= 1) ? r_q          : q;
	wire        s1_round_bit  = (LAT >= 1) ? r_round_bit  : round_bit;
	wire        s1_sticky_bit = (LAT >= 1) ? r_sticky_bit : sticky_bit;
	wire [8:0]  s1_k          = (LAT >= 1) ? r_k          : k;
	wire [15:0] s1_cnt        = (LAT >= 1) ? r_cnt        : cnt;
	wire [31:0] s1_f          = (LAT >= 1) ? r_f          : f;

	wire rnd = s1_round_bit && (s1_sticky_bit || s1_q[0]);
	am_add #(.W(25)) u_tv (.a({1'b0, s1_q}), .b(25'd0), .ci(rnd), .s(tv),
		.co(carry_unused[1]));
	am_sub #(.W(16)) u_c1 (.a(s1_cnt), .b(16'd0), .bi(1'b1), .d(c1), .bo(carry_unused[2]));
	assign l = s1_f[30:23] == 8'd0 || (s1_f[30:23] == 8'hFF && s1_f[22:0] != 23'd0) || s1_f[31] ? 16'd0 :
		s1_k[8] || s1_k == 9'd0 || tv >= {9'd0, s1_cnt} ? c1 : tv[15:0];

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, unused_lat0};
endmodule

`default_nettype wire
