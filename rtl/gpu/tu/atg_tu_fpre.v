/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fpre: the per-lane front of atg_tu_filter (P1 → P5): the
 * compare reference Dref (the lane's tc_value word) as unorm24 (as
 * atg_fmt_depth_u24), unorm16 (as atg_fmt_f2unorm with 16 bits) or the fp32
 * order key (atg_fmt_depth_key), the texels' keys, VkCompareOp i_op of Dref
 * against each texel (as atg_depth_pass: D32F a NaN on either side passes
 * NOT_EQUAL and ALWAYS only); the bilinear weights of the four texels
 * ((256 - fu or fu)(256 - fv or fv); without bilinear 65536 for texel 0)
 * and the pass's (fw or 256 - fw)(fl or 256 - fl); the LOD query's
 * magnitudes |tc_value[15:0]|, |[31:16]|.
 *
 * Pipelined, no stall: the inputs in cycle 1 (atg_tu_filter's P1),
 * o_ok in cycle 4 (combinational from P4's registers), the weights and
 * the magnitudes in cycle 5 (registers).
 * See spec/gpu/tu/atg_tu_filter.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fpre (
	input wire clk,
	input wire [31:0] i_vw,	/* Dref, or the query's fixed-point values */
	input wire [127:0] i_lt,	/* the lane's texels */
	input wire [31:0] i_wl,	/* the lane's {fw, fl, fv, fu} */
	input wire i_bil,
	input wire i_p17,
	input wire i_p18,
	input wire i_d32,	/* D32F (else D24, or D16) */
	input wire i_d16,
	input wire [2:0] i_op,
	output reg [3:0] o_ok,
	output wire [67:0] o_w,	/* texel t's weight in [17t +: 17] */
	output wire [16:0] o_wp,
	output wire [31:0] o_fa
);
	`include "atg_depth.vh"
	integer i, t;

	/* ---- P1 → P2: Dref's conversions (as atg_fmt_depth_u24, atg_fmt_f2unorm
	 * with 16 bits and atg_fmt_depth_key), the texels' keys, the weights ---- */
	wire [7:0] de = i_vw[30:23];
	wire dnan = de == 8'hFF && i_vw[22:0] != 23'd0;
	wire [47:0] p24, p16;
	wire [4:0] t24;
	wire [5:0] sam1;
	wire [32:0] dkey;
	wire p24_nc, p16_nc, t24_nc, sam1_nc;

	/* m (2^24 − 1) and m (2^16 − 1), m the significand */
	am_sub #(.W(48)) u_p24 (.a({1'b1, i_vw[22:0], 24'd0}), .b({24'd0, 1'b1, i_vw[22:0]}),
		.bi(1'b0), .d(p24), .bo(p24_nc));
	am_sub #(.W(48)) u_p16 (.a({8'd0, 1'b1, i_vw[22:0], 16'd0}), .b({24'd0, 1'b1, i_vw[22:0]}),
		.bi(1'b0), .d(p16), .bo(p16_nc));
	am_sub #(.W(5)) u_t24 (.a(5'd30), .b(i_vw[27:23]), .bi(1'b0), .d(t24), .bo(t24_nc));
	am_sub #(.W(6)) u_sam1 (.a(6'd21), .b(i_vw[28:23]), .bi(1'b0), .d(sam1), .bo(sam1_nc));
	/* the fp32 order keys of Dref and of the four texels */
	atg_fmt_depth_key u_dkey (.f(i_vw), .k(dkey));

	wire [32:0] tkey [0:3];
	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_key
		atg_fmt_depth_key u_tkey (.f(i_lt[gt*32 +: 32]), .k(tkey[gt]));
	end
	endgenerate

	wire [8:0] ru, rv, rw, rl;
	wire [15:0] fan0, fan1;
	wire [5:0] w_nc;

	am_sub #(.W(9)) u_ru (.a(9'd256), .b({1'b0, i_wl[7:0]}), .bi(1'b0), .d(ru), .bo(w_nc[0]));
	am_sub #(.W(9)) u_rv (.a(9'd256), .b({1'b0, i_wl[15:8]}), .bi(1'b0), .d(rv), .bo(w_nc[1]));
	am_sub #(.W(9)) u_rl (.a(9'd256), .b({1'b0, i_wl[23:16]}), .bi(1'b0), .d(rl), .bo(w_nc[2]));
	am_sub #(.W(9)) u_rw (.a(9'd256), .b({1'b0, i_wl[31:24]}), .bi(1'b0), .d(rw), .bo(w_nc[3]));
	/* the LOD query's magnitudes */
	am_sub #(.W(16)) u_fa0 (.a(16'd0), .b(i_vw[15:0]), .bi(1'b0), .d(fan0), .bo(w_nc[4]));
	am_sub #(.W(16)) u_fa1 (.a(16'd0), .b(i_vw[31:16]), .bi(1'b0), .d(fan1), .bo(w_nc[5]));

	reg [47:0] p24_2, p16_2;
	reg [4:0] t24_2;
	reg [5:0] sam1_2;
	reg [32:0] ka32_2;
	reg u24z2, u24o2, u16z2, u16o2;
	reg [131:0] kb2;
	reg [3:0] kn2;
	reg [8:0] wu2 [0:3];
	reg [8:0] wv2 [0:3];
	reg [8:0] wa2, wb2;
	reg [31:0] fa2;
	/* texel t's key (D32F: the order key; D16, D24: the bits) and NaN */
	wire [131:0] kbw;
	wire [3:0] knw;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_kb
		wire [30:0] tw = i_lt[gt*32 +: 31];	/* (the sign: in tkey) */
		assign kbw[gt*33 +: 33] = i_d32 ? tkey[gt] : i_d16 ? {17'd0, tw[15:0]} :
			{9'd0, tw[23:0]};
		assign knw[gt] = i_d32 && (dnan || (tw[30:23] == 8'hFF && tw[22:0] != 23'd0));
	end
	endgenerate
	always @(posedge clk) begin
		p24_2 <= p24;
		p16_2 <= p16;
		t24_2 <= t24;
		sam1_2 <= sam1;
		ka32_2 <= dkey;
		u24z2 <= de == 8'd0 || i_vw[31] || dnan || de < 8'd102;
		u24o2 <= de >= 8'd127;
		u16z2 <= i_vw[31] || dnan || de < 8'd103;
		u16o2 <= de >= 8'd127;
		kb2 <= kbw;
		kn2 <= knw;
		for (t = 0; t < 4; t = t + 1) begin
			/* texel t's bilinear factors (without bilinear 256 × 256 for texel 0) */
			wu2[t] <= !i_bil ? (t == 0 ? 9'd256 : 9'd0) : t[0] ? {1'b0, i_wl[7:0]} : ru;
			wv2[t] <= !i_bil ? 9'd256 : t[1] ? {1'b0, i_wl[15:8]} : rv;
		end
		wa2 <= i_p17 ? {1'b0, i_wl[31:24]} : rw;
		wb2 <= i_p18 ? {1'b0, i_wl[23:16]} : rl;
		fa2 <= {i_vw[31] ? fan1 : i_vw[31:16], i_vw[15] ? fan0 : i_vw[15:0]};
	end

	/* ---- P2 → P3 ---- */
	wire [71:0] z24;
	wire [47:0] s16;

	am_shift #(.W(72), .SW(5)) u_z24 (.a({p24_2, 24'd0}), .amt(t24_2), .left(1'b0),
		.arith(1'b0), .y(z24));
	am_shift #(.W(48), .SW(6)) u_s16 (.a(p16_2), .amt(sam1_2), .left(1'b0), .arith(1'b0),
		.y(s16));

	reg [47:0] m16;
	always @(*)
		for (i = 0; i < 48; i = i + 1)
			m16[i] = i[5:0] < sam1_2;

	wire [17:0] w3 [0:3];
	wire [17:0] wp3;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_w
		am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_w (
			.clk(clk), .en(1'b1), .a(wu2[gt]), .b(wv2[gt]), .p(w3[gt])
		);
	end
	endgenerate
	am_mul #(.AW(9), .BW(9), .SIGNED(0), .LAT(1)) u_wp (
		.clk(clk), .en(1'b1), .a(wa2), .b(wb2), .p(wp3)
	);

	reg [24:0] z3;	/* bits 71:47 */
	reg st24_3, st16_3;
	reg [16:0] s16_3;	/* bits 16:0 */
	reg [32:0] ka32_3;
	reg u24z3, u24o3, u16z3, u16o3;
	reg [131:0] kb3;
	reg [3:0] kn3;
	reg [31:0] fa3;
	always @(posedge clk) begin
		z3 <= z24[71:47];
		st24_3 <= z24[46:0] != 47'd0;
		s16_3 <= s16[16:0];
		st16_3 <= (p16_2 & m16) != 48'd0;
		{ka32_3, u24z3, u24o3, u16z3, u16o3, kb3, kn3, fa3} <=
			{ka32_2, u24z2, u24o2, u16z2, u16o2, kb2, kn2, fa2};
	end

	/* ---- P3 → P4: the roundings, the reference's key ---- */
	wire [23:0] q24;
	wire [15:0] q16;
	wire q24_nc, q16_nc;

	am_add #(.W(24)) u_q24 (.a(z3[24:1]), .b(24'd0), .ci(z3[0] && (st24_3 || z3[1])), .s(q24),
		.co(q24_nc));
	am_add #(.W(16)) u_q16 (.a(s16_3[16:1]), .b(16'd0), .ci(s16_3[0] && (st16_3 || s16_3[1])),
		.s(q16), .co(q16_nc));

	wire [23:0] dref24 = u24z3 ? 24'd0 : u24o3 ? 24'hFFFFFF : q24;
	wire [15:0] dref16 = u16z3 ? 16'd0 : u16o3 ? 16'hFFFF : q16;

	reg [32:0] ka4;
	reg [131:0] kb4;
	reg [3:0] kn4;
	reg [31:0] fa4;
	reg [17:0] w4 [0:3];
	reg [17:0] wp4;
	always @(posedge clk) begin
		ka4 <= d32_3 ? ka32_3 : d16_3 ? {17'd0, dref16} : {9'd0, dref24};
		kb4 <= kb3;
		kn4 <= kn3;
		fa4 <= fa3;
		for (t = 0; t < 4; t = t + 1)
			w4[t] <= w3[t];
		wp4 <= wp3;
	end

	/* the compare's fields to P4 */
	reg d32_2, d32_3, d16_2, d16_3;
	reg [2:0] op2, op3, op4;
	always @(posedge clk) begin
		{d32_2, d16_2, op2} <= {i_d32, i_d16, i_op};
		{d32_3, d16_3, op3} <= {d32_2, d16_2, op2};
		op4 <= op3;
	end

	/* P4: the compares */
	always @(*)
		for (t = 0; t < 4; t = t + 1)
			o_ok[t] = atg_depth_pass(op4, ka4, kb4[t*33 +: 33], kn4[t]);

	reg [16:0] w5 [0:3];
	reg [16:0] wp5;
	reg [31:0] fa5;
	always @(posedge clk) begin
		for (t = 0; t < 4; t = t + 1)
			w5[t] <= w4[t][16:0];
		wp5 <= wp4[16:0];
		fa5 <= fa4;
	end
	assign o_w = {w5[3], w5[2], w5[1], w5[0]};
	assign o_wp = wp5;
	assign o_fa = fa5;

	wire unused_ok = &{1'b0, q16_nc, q24_nc, p16_nc, p24_nc, sam1_nc, t24_nc, w_nc, s16[47:17], z24[46:0], wp4[17], w4[0][17], w4[1][17],
		w4[2][17], w4[3][17]};
endmodule

`default_nettype wire
