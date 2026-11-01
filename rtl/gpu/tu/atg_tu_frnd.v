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
	wire [5:0] p_nc;

	wire [48:0] x;
	wire [64:0] y;
	wire [80:0] p;
	reg [48:0] x13;
	reg [39:0] rr13, rr14;
	reg [64:0] y14;
	(* keep = "true", equivalent_register_removal = "no" *) reg [2:0] sel_s0, sel_s1, sel_s2, sel_s3, sel_s4, sel_s5, sel_s6, sel_s7, sel_s8, sel_s9, sel_nc;

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
		sel_s0 <= i_sel;
		sel_s1 <= i_sel;
		sel_s2 <= i_sel;
		sel_s3 <= i_sel;
		sel_s4 <= i_sel;
		sel_s5 <= i_sel;
		sel_s6 <= i_sel;
		sel_s7 <= i_sel;
		sel_s8 <= i_sel;
		sel_s9 <= i_sel;
		sel_nc <= i_sel;
	end

	/* P14: the integer */
	wire [80:0] np_fx  = {65'd0, i_fx};
	wire [80:0] np_g24 = {9'd0, i_g24, i_g24, i_g24};
	wire [80:0] np_gb  = {9'd0, {5{i_gb}}, 32'd0};
	wire [80:0] np_d24 = {9'd0, i_d24, i_d24, i_d24};
	wire [80:0] np_c6  = {3'd0, {13{i_c6}}};
	wire [80:0] np_c5  = {1'd0, {16{i_c5}}};

	function [7:0] mux8;
		input [2:0] s;
		input [7:0] p_s, fx_s, g24_s, gb_s, d24_s, c6_s, c5_s;
		case (s)
		3'd1: mux8 = fx_s;
		3'd2: mux8 = g24_s;
		3'd3: mux8 = gb_s;
		3'd4: mux8 = d24_s;
		3'd5: mux8 = c6_s;
		3'd6: mux8 = c5_s;
		default: mux8 = p_s;
		endcase
	endfunction

	reg [80:0] np;
	reg [1:0] ncode;
	always @(*) begin
		ncode = sel_nc == 3'd1 ? 2'd1 : sel_nc == 3'd5 ? 2'd2 : sel_nc == 3'd6 ? 2'd3 : 2'd0;
		np[7:0]   = mux8(sel_s0, p[7:0],   np_fx[7:0],   np_g24[7:0],   np_gb[7:0],   np_d24[7:0],   np_c6[7:0],   np_c5[7:0]);
		np[15:8]  = mux8(sel_s1, p[15:8],  np_fx[15:8],  np_g24[15:8],  np_gb[15:8],  np_d24[15:8],  np_c6[15:8],  np_c5[15:8]);
		np[23:16] = mux8(sel_s2, p[23:16], np_fx[23:16], np_g24[23:16], np_gb[23:16], np_d24[23:16], np_c6[23:16], np_c5[23:16]);
		np[31:24] = mux8(sel_s3, p[31:24], np_fx[31:24], np_g24[31:24], np_gb[31:24], np_d24[31:24], np_c6[31:24], np_c5[31:24]);
		np[39:32] = mux8(sel_s4, p[39:32], np_fx[39:32], np_g24[39:32], np_gb[39:32], np_d24[39:32], np_c6[39:32], np_c5[39:32]);
		np[47:40] = mux8(sel_s5, p[47:40], np_fx[47:40], np_g24[47:40], np_gb[47:40], np_d24[47:40], np_c6[47:40], np_c5[47:40]);
		np[55:48] = mux8(sel_s6, p[55:48], np_fx[55:48], np_g24[55:48], np_gb[55:48], np_d24[55:48], np_c6[55:48], np_c5[55:48]);
		np[63:56] = mux8(sel_s7, p[63:56], np_fx[63:56], np_g24[63:56], np_gb[63:56], np_d24[63:56], np_c6[63:56], np_c5[63:56]);
		np[71:64] = mux8(sel_s8, p[71:64], np_fx[71:64], np_g24[71:64], np_gb[71:64], np_d24[71:64], np_c6[71:64], np_c5[71:64]);
		case (sel_s9)
		3'd1: np[80:72] = np_fx[80:72];
		3'd2: np[80:72] = np_g24[80:72];
		3'd3: np[80:72] = np_gb[80:72];
		3'd4: np[80:72] = np_d24[80:72];
		3'd5: np[80:72] = np_c6[80:72];
		3'd6: np[80:72] = np_c5[80:72];
		default: np[80:72] = p[80:72];
		endcase
	end

	(* extract_reset = "no", shreg_extract = "no", max_fanout = 16 *) reg [80:0] np15, np16;
	(* max_fanout = 16 *) reg [1:0] nc15, nc16;
	(* keep = "true", max_fanout = 16 *) reg [6:0] lz16;
	(* keep = "true", equivalent_register_removal = "no" *) reg [6:0] lz16_st;
	(* max_fanout = 16 *) reg z16, z17;

	wire [83:0] lzv = {np15, 3'b000};
	(* keep = "true" *) wire [19:0] lznv;
	wire [1:0] lznl [0:19];
	(* keep = "true" *) wire [4:0] lzbv;
	(* keep = "true" *) wire [3:0] lzblo [0:4];
	genvar gl;
	generate
	for (gl = 0; gl < 20; gl = gl + 1) begin : g_lzn
		wire [3:0] nb = lzv[83 - gl*4 -: 4];
		assign lznv[gl] = |nb;
		assign lznl[gl] = nb[3] ? 2'd0 : nb[2] ? 2'd1 : nb[1] ? 2'd2 : 2'd3;
	end
	for (gl = 0; gl < 5; gl = gl + 1) begin : g_lzb
		assign lzbv[gl] = |lznv[gl*4 +: 4];
		assign lzblo[gl] = lznv[gl*4] ? {2'd0, lznl[gl*4]} :
			lznv[gl*4 + 1] ? {2'd1, lznl[gl*4 + 1]} :
			lznv[gl*4 + 2] ? {2'd2, lznl[gl*4 + 2]} : {2'd3, lznl[gl*4 + 3]};
	end
	endgenerate
	(* keep = "true" *) wire [6:0] lz = lzbv[0] ? {3'd0, lzblo[0]} :
		lzbv[1] ? {3'd1, lzblo[1]} :
		lzbv[2] ? {3'd2, lzblo[2]} :
		lzbv[3] ? {3'd3, lzblo[3]} :
		lzbv[4] ? {3'd4, lzblo[4]} :
		np15[0] ? 7'd80 : 7'd0;

	always @(posedge clk) begin
		np15 <= np;
		nc15 <= ncode;
		np16 <= np15;
		nc16 <= nc15;
		lz16 <= lz;
		lz16_st <= lz;
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
	am_sub #(.W(8)) u_ne0 (.a(eb80), .b({1'b0, lz16_st}), .bi(1'b0), .d(ne0), .bo(p_nc[3]));
	am_sub #(.W(8)) u_ne1 (.a(eb81), .b({1'b0, lz16_st}), .bi(1'b0), .d(ne1), .bo(p_nc[4]));

	(* keep = "true" *) wire [13:0] nib_st;
	generate
	for (gl = 0; gl < 14; gl = gl + 1) begin : g_nst
		(* keep = "true" *) wire [3:0] ng = {
			|np16[gl*4 +: 4], |np16[gl*4 +: 3], |np16[gl*4 +: 2], np16[gl*4]
		};
		localparam [3:0] GINV = 4'd13 - gl[3:0];
		assign nib_st[gl] = (gl < 13 && lz16_st[5:2] < GINV) ? ng[3] :
			(lz16_st[5:2] == GINV) ? ng[~lz16_st[1:0]] : 1'b0;
	end
	endgenerate

	(* extract_reset = "no", max_fanout = 16 *) reg [24:0] ny17;	/* bits 80:56 */
	reg nst17;
	(* max_fanout = 16 *) reg [7:0] ne0_17, ne1_17;
	always @(posedge clk) begin
		ny17 <= ny[80:56];
		nst17 <= !lz16_st[6] && (|nib_st);
		z17 <= z16;
		ne0_17 <= ne0;
		ne1_17 <= ne1;
	end

	wire [24:0] m;

	am_add #(.W(25)) u_m (.a({1'b0, ny17[24:1]}), .b(25'd0),
		.ci(ny17[0] && (nst17 || ny17[1])), .s(m), .co(p_nc[5]));

	(* keep = "true" *) wire m24_lo = m[24];
	(* keep = "true" *) wire m24_hi = m[24];
	(* keep = "true" *) wire z17_lo = z17;
	(* keep = "true" *) wire z17_hi = z17;
	wire [31:0] rn_lo_hi = {
		1'b0,
		m24_hi ? ne1_17 : ne0_17,
		m24_hi ? m[23:17] : m[22:16],
		m24_lo ? m[16:1]  : m[15:0]
	};

	always @(posedge clk) begin
		o_rn[15:0]  <= z17_lo ? 16'd0 : rn_lo_hi[15:0];
		o_rn[31:16] <= z17_hi ? 16'd0 : rn_lo_hi[31:16];
	end

	wire unused_ok = &{1'b0, p_nc, ny[55:0]};
endmodule

`default_nettype wire
