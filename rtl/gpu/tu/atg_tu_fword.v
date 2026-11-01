/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fword: a lane's four words in atg_tu_filter (P18, combinational):
 * the conversions i_rn, then RGB565's texf alpha 1.0, a depth texel
 * without compare (D, 0, 0, 1.0; D32F the word itself), gather (texels 2,
 * 3, 1, 0: the compare's 1.0 or 0.0, the swizzle's constant, a depth
 * component, the byte's conversion), else the component swizzle; the
 * queries (texsz: the tc_value word; texqlod: the two signed values); 0
 * outside the mask.
 * See spec/gpu/tu/atg_tu_filter.md section 4.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fword (
	input wire [127:0] i_rn,	/* the four conversions */
	input wire [127:0] i_lt,	/* the lane's texels */
	input wire [31:0] i_vw,	/* the lane's tc_value word */
	input wire [3:0] i_ok,	/* the compares */
	input wire [49:0] i_ctl,
	input wire [7:0] i_ctl_c13,
	input wire i_mk,
	output reg [127:0] o_res
);
	integer c;

	/* The component that swizzle code 3-6 (R, G, B, A) takes, by its bits
	 * 1:0. */
	function [1:0] zsrc;
		input [1:0] s;
		case (s)
		2'd3: zsrc = 2'd0;
		2'd0: zsrc = 2'd1;
		2'd1: zsrc = 2'd2;
		default: zsrc = 2'd3;
		endcase
	endfunction

	/* The component swizzle of four fp32 components. */
	function [127:0] swz4;
		input [127:0] v;
		input [11:0] z;
		integer j;
		reg [2:0] sc;
		begin
			for (j = 0; j < 4; j = j + 1) begin
				sc = z[3*j +: 3];
				swz4[j*32 +: 32] = sc == 3'd1 ? 32'd0 : sc == 3'd2 ? 32'h3F800000 :
					sc >= 3'd3 && sc <= 3'd6 ? v[{zsrc(sc[1:0]), 5'd0} +: 32] : v[j*32 +: 32];
			end
		end
	endfunction

	/* The texel of word g of a gather: 2, 3, 1, 0. */
	function [1:0] gtx;
		input [1:0] g;
		gtx = g == 2'd0 ? 2'd2 : g == 2'd1 ? 2'd3 : g == 2'd2 ? 2'd1 : 2'd0;
	endfunction

	(* dont_touch = "true" *) wire [15:0] mk_h = {16{i_mk}};
	(* dont_touch = "true" *) wire [15:0] ctl2_h = {16{i_ctl[2]}};
	(* dont_touch = "true" *) wire [15:0] ctl16_h = {16{i_ctl[16]}};
	(* dont_touch = "true" *) wire [11:0] swz_z0 = i_ctl[47:36];
	(* dont_touch = "true" *) wire [11:0] swz_z1 = i_ctl[47:36];
	(* dont_touch = "true" *) wire [11:0] swz_z2 = i_ctl[47:36];
	(* dont_touch = "true" *) wire [11:0] swz_z3 = i_ctl[47:36];

	(* keep = "true" *) wire [127:0] o_base;
	genvar gb;
	generate
	for (gb = 0; gb < 8; gb = gb + 1) begin : g_base
		(* dont_touch = "true" *) wire d_nocomp = i_ctl[8] && !i_ctl[9];
		(* dont_touch = "true" *) wire d32_sel = i_ctl[1];
		(* dont_touch = "true" *) wire rgb565_texf = i_ctl[19] && i_ctl[3];
		if (gb == 0) begin : g_b0
			assign o_base[15:0] = d_nocomp ? (d32_sel ? i_lt[15:0] : i_rn[15:0]) : i_rn[15:0];
		end else if (gb == 1) begin : g_b1
			assign o_base[31:16] = d_nocomp ? (d32_sel ? i_lt[31:16] : i_rn[31:16]) : i_rn[31:16];
		end else if (gb < 6) begin : g_b2_5
			assign o_base[gb*16 +: 16] = d_nocomp ? 16'd0 : i_rn[gb*16 +: 16];
		end else if (gb == 6) begin : g_b6
			assign o_base[111:96] = (d_nocomp || rgb565_texf) ? 16'h0000 : i_rn[111:96];
		end else begin : g_b7
			assign o_base[127:112] = (d_nocomp || rgb565_texf) ? 16'h3F80 : i_rn[127:112];
		end
	end
	endgenerate

	reg [127:0] o_swz_r;
	reg [2:0] sc0, sc1, sc2, sc3;
	always @(*) begin
		for (c = 0; c < 4; c = c + 1) begin
			sc0 = swz_z0[3*c +: 3];
			sc1 = swz_z1[3*c +: 3];
			sc2 = swz_z2[3*c +: 3];
			sc3 = swz_z3[3*c +: 3];
			o_swz_r[c*32 +: 8] = sc0 == 3'd1 ? 8'd0 : sc0 == 3'd2 ? 8'h00 :
				sc0 >= 3'd3 && sc0 <= 3'd6 ? o_base[{zsrc(sc0[1:0]), 5'd0} +: 8] : o_base[c*32 +: 8];
			o_swz_r[c*32 + 8 +: 8] = sc1 == 3'd1 ? 8'd0 : sc1 == 3'd2 ? 8'h00 :
				sc1 >= 3'd3 && sc1 <= 3'd6 ? o_base[{zsrc(sc1[1:0]), 5'd8} +: 8] : o_base[c*32 + 8 +: 8];
			o_swz_r[c*32 + 16 +: 8] = sc2 == 3'd1 ? 8'd0 : sc2 == 3'd2 ? 8'h80 :
				sc2 >= 3'd3 && sc2 <= 3'd6 ? o_base[{zsrc(sc2[1:0]), 5'd16} +: 8] : o_base[c*32 + 16 +: 8];
			o_swz_r[c*32 + 24 +: 8] = sc3 == 3'd1 ? 8'd0 : sc3 == 3'd2 ? 8'h3F :
				sc3 >= 3'd3 && sc3 <= 3'd6 ? o_base[{zsrc(sc3[1:0]), 5'd24} +: 8] : o_base[c*32 + 24 +: 8];
		end
	end
	(* keep = "true" *) wire [127:0] o_swz = o_swz_r;

	(* keep = "true" *) wire [127:0] o_mid;
	generate
	for (gb = 0; gb < 8; gb = gb + 1) begin : g_mid
		localparam [1:0] MC = gb[2:1];
		localparam       HI = gb[0];
		(* dont_touch = "true" *) wire c13 = i_ctl_c13[gb];
		(* dont_touch = "true" *) wire c9  = i_ctl[9];
		(* dont_touch = "true" *) wire c8  = i_ctl[8];
		(* dont_touch = "true" *) wire c1  = i_ctl[1];
		(* keep = "true" *) wire [2:0] gsw_m = (i_ctl[15:14] == 2'd0) ? i_ctl[38:36] :
		                                       (i_ctl[15:14] == 2'd1) ? i_ctl[41:39] :
		                                       (i_ctl[15:14] == 2'd2) ? i_ctl[44:42] : i_ctl[47:45];
		(* keep = "true" *) wire [1:0] gsrc_m = (gsw_m >= 3'd3 && gsw_m <= 3'd6) ? zsrc(gsw_m[1:0]) : i_ctl[15:14];
		wire [31:0] gw_m = i_lt[gtx(MC)*32 +: 32];
		if (!HI) begin : g_m_lo
			assign o_mid[gb*16 +: 16] = !c13 ? o_swz[gb*16 +: 16] :
				(c9 || gsw_m == 3'd1 || gsw_m == 3'd2) ? 16'd0 :
				c8 ? (gsrc_m == 2'd0 ? (c1 ? gw_m[15:0] : i_rn[gb*16 +: 16]) : 16'd0) :
				i_rn[gb*16 +: 16];
		end else begin : g_m_hi
			assign o_mid[gb*16 +: 16] = !c13 ? o_swz[gb*16 +: 16] :
				c9 ? (i_ok[gtx(MC)] ? 16'h3F80 : 16'd0) :
				(gsw_m == 3'd1 || gsw_m == 3'd2) ? (gsw_m == 3'd2 ? 16'h3F80 : 16'd0) :
				c8 ? (gsrc_m == 2'd0 ? (c1 ? gw_m[31:16] : i_rn[gb*16 +: 16]) :
				      gsrc_m == 2'd3 ? 16'h3F80 : 16'd0) :
				i_rn[gb*16 +: 16];
		end
	end
	endgenerate
	wire [127:0] q_val = {64'd0, i_vw[31], i_rn[62:32], i_vw[15], i_rn[30:0]};
	wire [127:0] s_val = {96'd0, i_vw};
	integer h;
	always @(*) begin
		for (h = 0; h < 16; h = h + 1) begin
			o_res[h*8 +: 8] = !mk_h[h] ? 8'd0 :
				ctl2_h[h] ? (ctl16_h[h] ? q_val[h*8 +: 8] : s_val[h*8 +: 8]) :
				o_mid[h*8 +: 8];
		end
	end


	wire unused_ok = &{1'b0, i_ctl[49:48], i_ctl[35:20], i_ctl[18:17], i_ctl[12:10],
		i_ctl[7:4], i_ctl[0]};
endmodule

`default_nettype wire
