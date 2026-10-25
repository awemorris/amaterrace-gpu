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

	reg [31:0] gw;
	reg [2:0] gsw18;
	reg [1:0] gsrc18;
	always @(*) begin
		case (i_ctl[15:14])
		2'd0: gsw18 = i_ctl[38:36];
		2'd1: gsw18 = i_ctl[41:39];
		2'd2: gsw18 = i_ctl[44:42];
		default: gsw18 = i_ctl[47:45];
		endcase
		gsrc18 = gsw18 >= 3'd3 && gsw18 <= 3'd6 ? zsrc(gsw18[1:0]) : i_ctl[15:14];
		o_res = i_rn;
		if (i_ctl[19] && i_ctl[3])	/* texf of RGB565: exact */
			o_res[127:96] = 32'h3F800000;
		if (i_ctl[8] && !i_ctl[9])
			o_res = {32'h3F800000, 64'd0, i_ctl[1] ? i_lt[31:0] : i_rn[31:0]};
		if (i_ctl[13]) begin
			/* gather: word g is texel 2, 3, 1, 0 */
			for (c = 0; c < 4; c = c + 1) begin
				gw = i_lt[gtx(c[1:0])*32 +: 32];
				if (i_ctl[9])
					o_res[c*32 +: 32] = i_ok[gtx(c[1:0])] ? 32'h3F800000 : 32'd0;
				else if (gsw18 == 3'd1 || gsw18 == 3'd2)
					o_res[c*32 +: 32] = gsw18 == 3'd2 ? 32'h3F800000 : 32'd0;
				else if (i_ctl[8])
					o_res[c*32 +: 32] = gsrc18 == 2'd0 ? (i_ctl[1] ? gw : i_rn[c*32 +: 32]) :
						gsrc18 == 2'd3 ? 32'h3F800000 : 32'd0;
				else
					o_res[c*32 +: 32] = i_rn[c*32 +: 32];
			end
		end else
			o_res = swz4(o_res, i_ctl[47:36]);
		if (i_ctl[2])
			o_res = i_ctl[16] ? {64'd0, i_vw[31], i_rn[62:32], i_vw[15], i_rn[30:0]} :
				{96'd0, i_vw};
		if (!i_mk)
			o_res = 128'd0;
	end


	wire unused_ok = &{1'b0, i_ctl[49:48], i_ctl[35:20], i_ctl[18:17], i_ctl[12:10],
		i_ctl[7:4], i_ctl[0]};
endmodule

`default_nettype wire
