/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_frnd: one channel of atg_tu_filter's conversion to fp32 (P12 →
 * P18): the integer p of the source i_sel (0 the sum A: A × 0x0101010101
 * = (A × 257) × 65537 + A × 2^32; 1 the LOD query's magnitude; 2 gather of
 * a D24 texel and 4 a D24 texel: c × (2^48 + 2^24 + 1); 3 gather of a
 * byte b: b × 0x0101010101 × 2^32; 5 RGB565's G: c × sum(2^6i, i < 13);
 * 6 its R or B: c × sum(2^5i, i < 16)), as p × 2^(n + eb − 127) rounded to
 * nearest even, n the msb position, eb 55 (the query 119, 5: 49, 6: 47);
 * 0 for p = 0.
 *
 * Pipelined, no stall: i_rr in cycle 12, i_sel in 13, the other sources
 * in 14; P13-P14 the adders, P15 the leading zeros, P16 p << lz, P17 the
 * rounding; o_rn in cycle 18 (a register).
 * See spec/gpu/tu/atg_tu_filter.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_frnd (
	input wire clk,
	input wire [39:0] i_rr,
	input wire [2:0] i_sel,
	input wire [15:0] i_fx,
	input wire [23:0] i_g24,
	input wire [7:0] i_gb,
	input wire [23:0] i_d24,
	input wire [5:0] i_c6,
	input wire [4:0] i_c5,
	output reg [31:0] o_rn
);
	integer i;
	wire [5:0] p_nc;

	wire [48:0] x;
	wire [64:0] y;
	wire [80:0] p;
	reg [48:0] x13;
	reg [39:0] rr13, rr14;
	reg [64:0] y14;
	reg [2:0] sel;

	am_add #(.W(49)) u_x (.a({9'd0, i_rr}), .b({1'b0, i_rr, 8'd0}), .ci(1'b0), .s(x),
		.co(p_nc[0]));
	am_add #(.W(65)) u_y (.a({16'd0, x13}), .b({x13, 16'd0}), .ci(1'b0), .s(y), .co(p_nc[1]));
	am_add #(.W(81)) u_p (.a({16'd0, y14}), .b({9'd0, rr14, 32'd0}), .ci(1'b0), .s(p),
		.co(p_nc[2]));

	always @(posedge clk) begin
		x13 <= x;
		rr13 <= i_rr;
		y14 <= y;
		rr14 <= rr13;
		sel <= i_sel;	/* (registered: it drives every bit of np) */
	end

	/* P14: the integer */
	reg [80:0] np;
	reg [1:0] ncode;
	always @(*) begin
		ncode = sel == 3'd1 ? 2'd1 : sel == 3'd5 ? 2'd2 : sel == 3'd6 ? 2'd3 : 2'd0;
		case (sel)
		3'd1: np = {65'd0, i_fx};
		3'd2: np = {9'd0, i_g24, i_g24, i_g24};
		3'd3: np = {9'd0, {5{i_gb}}, 32'd0};
		3'd4: np = {9'd0, i_d24, i_d24, i_d24};
		3'd5: np = {3'd0, {13{i_c6}}};
		3'd6: np = {1'd0, {16{i_c5}}};
		default: np = p;
		endcase
	end

	reg [80:0] np15, np16;
	reg [1:0] nc15, nc16;
	reg [6:0] lz16;
	reg z16, z17;
	reg [6:0] lz;
	always @(*) begin
		lz = 7'd0;
		for (i = 0; i < 81; i = i + 1)
			if (np15[i])
				lz = 7'd80 - i[6:0];
	end
	always @(posedge clk) begin
		np15 <= np;
		nc15 <= ncode;
		np16 <= np15;
		nc16 <= nc15;
		lz16 <= lz;
		z16 <= np15 == 81'd0;
	end

	/* eb + 80 and eb + 81 of the code */
	wire [7:0] eb80 = nc16 == 2'd1 ? 8'd199 : nc16 == 2'd2 ? 8'd129 : nc16 == 2'd3 ? 8'd127 :
		8'd135;
	wire [7:0] eb81 = nc16 == 2'd1 ? 8'd200 : nc16 == 2'd2 ? 8'd130 : nc16 == 2'd3 ? 8'd128 :
		8'd136;
	wire [80:0] ny;
	wire [7:0] ne0, ne1;

	am_shift #(.W(81), .SW(7)) u_ny (.a(np16), .amt(lz16), .left(1'b1), .arith(1'b0), .y(ny));
	am_sub #(.W(8)) u_ne0 (.a(eb80), .b({1'b0, lz16}), .bi(1'b0), .d(ne0), .bo(p_nc[3]));
	am_sub #(.W(8)) u_ne1 (.a(eb81), .b({1'b0, lz16}), .bi(1'b0), .d(ne1), .bo(p_nc[4]));

	reg [24:0] ny17;	/* bits 80:56 */
	reg nst17;
	reg [7:0] ne0_17, ne1_17;
	always @(posedge clk) begin
		ny17 <= ny[80:56];
		nst17 <= ny[55:0] != 56'd0;
		z17 <= z16;
		ne0_17 <= ne0;
		ne1_17 <= ne1;
	end

	wire [24:0] m;

	am_add #(.W(25)) u_m (.a({1'b0, ny17[24:1]}), .b(25'd0),
		.ci(ny17[0] && (nst17 || ny17[1])), .s(m), .co(p_nc[5]));

	always @(posedge clk)
		o_rn <= z17 ? 32'd0 : {1'b0, m[24] ? ne1_17 : ne0_17, m[24] ? m[23:1] : m[22:0]};

	wire unused_ok = &{1'b0, p_nc};
endmodule

`default_nettype wire
