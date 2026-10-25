/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_avg: the integer averages of the blitter's RESOLVE (docs/ghci.md
 * sections 8.2 and 8.5), combinational.  The input holds up to four
 * pixels of four samples each, sample s of pixel p at sample slot 4 p + s,
 * one slot per pixel (ps = 2^psl bytes: slot k at bits 8 ps k); the output
 * holds the pixels' averages, pixel p at bits 8 ps p (as many pixels as
 * fit 128 bits; the rest 0):
 *
 *   fmt 0 UNORM8           every byte an unsigned normalized channel
 *                          (pixels of 1, 2 or 4 bytes)
 *   fmt 1 UNORM565         the fields [15:11], [10:5], [4:0]
 *   fmt 6 UNORM2_10_10_10  the fields [31:30], [29:20], [19:10], [9:0]
 *   fmt 7 UNORM1555        the fields [15], [14:10], [9:5], [4:0]
 *   fmt 2 SAMPLE0 (and 3-5, which atg_blt_favg averages)  sample 0
 *
 * A field's average is the sum of the four samples' codes divided by 4,
 * rounded to the nearest code, ties to even.  See spec/gpu/blt/atg_blt_avg.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_avg (
	input wire [2:0] fmt,
	input wire [2:0] psl,	/* log2 of the pixel's bytes */
	input wire [511:0] in_s,
	output reg [127:0] out_p
);
	/*
	 * The code of channel c of sample word wd: byte c (fmt 0), or field c
	 * of the format (fmt 1, 6, 7; the fields from the low bits), 0 when
	 * the format has no such field.  Called with c constant, so each case
	 * is a fixed part-select.
	 */
	function [9:0] chan;
		input [2:0] f;
		input [1:0] c;
		input [31:0] wd;
		begin
			chan = 10'd0;
			case ({f, c})
			{3'd0, 2'd0}: chan = {2'd0, wd[7:0]};
			{3'd0, 2'd1}: chan = {2'd0, wd[15:8]};
			{3'd0, 2'd2}: chan = {2'd0, wd[23:16]};
			{3'd0, 2'd3}: chan = {2'd0, wd[31:24]};
			{3'd1, 2'd0}: chan = {5'd0, wd[4:0]};
			{3'd1, 2'd1}: chan = {4'd0, wd[10:5]};
			{3'd1, 2'd2}: chan = {5'd0, wd[15:11]};
			{3'd6, 2'd0}: chan = wd[9:0];
			{3'd6, 2'd1}: chan = wd[19:10];
			{3'd6, 2'd2}: chan = wd[29:20];
			{3'd6, 2'd3}: chan = {8'd0, wd[31:30]};
			{3'd7, 2'd0}: chan = {5'd0, wd[4:0]};
			{3'd7, 2'd1}: chan = {5'd0, wd[9:5]};
			{3'd7, 2'd2}: chan = {5'd0, wd[14:10]};
			{3'd7, 2'd3}: chan = {9'd0, wd[15]};
			default: chan = 10'd0;
			endcase
		end
	endfunction

	/* Average avg of channel c placed in its field of a 32-bit pixel word (fmt 1, 6, 7; c constant). */
	function [31:0] place;
		input [2:0] f;
		input [1:0] c;
		input [9:0] avg;
		begin
			place = 32'd0;
			case ({f, c})
			{3'd1, 2'd0}: place = {27'd0, avg[4:0]};
			{3'd1, 2'd1}: place = {21'd0, avg[5:0], 5'd0};
			{3'd1, 2'd2}: place = {16'd0, avg[4:0], 11'd0};
			{3'd6, 2'd0}: place = {22'd0, avg};
			{3'd6, 2'd1}: place = {12'd0, avg, 10'd0};
			{3'd6, 2'd2}: place = {2'd0, avg, 20'd0};
			{3'd6, 2'd3}: place = {avg[1:0], 30'd0};
			{3'd7, 2'd0}: place = {27'd0, avg[4:0]};
			{3'd7, 2'd1}: place = {22'd0, avg[4:0], 5'd0};
			{3'd7, 2'd2}: place = {17'd0, avg[4:0], 10'd0};
			{3'd7, 2'd3}: place = {16'd0, avg[0], 15'd0};
			default: place = 32'd0;
			endcase
		end
	endfunction

	/* SAMPLE0: the bytes of sample 0 of each pixel, for a pixel of 2^pl bytes (pl constant). */
	function [127:0] sample0;
		input [2:0] pl;
		input [511:0] x;
		integer p, k, ps;
		reg [127:0] o;
		begin
			o = 128'd0;
			ps = 1 << pl;
			for (p = 0; p < 4; p = p + 1)
				for (k = 0; k < 16; k = k + 1)
					if (k < ps && ps * p + k < 16)
						o[8 * (ps * p + k) +: 8] = x[8 * (ps * 4 * p + k) +: 8];
			sample0 = o;
		end
	endfunction

	/*
	 * Sixteen averagers, one for channel c of pixel p (j = 4 p + c): the
	 * sum of the four samples' codes (at most 4 x 1023) and its quarter,
	 * rounded to the nearest code, ties to even.  The samples' words and
	 * the codes are chosen by the format and the pixel size: UNORM8 byte c
	 * of a pixel of 1, 2 or 4 bytes, or field c of a 16- or 32-bit pixel.
	 */
	wire [159:0] q;	/* average j at bits 10 j */

	genvar j, sm;
	generate
	for (j = 0; j < 16; j = j + 1) begin : g_avg
		localparam integer CH_I = j % 4;	/* the channel */
		localparam [1:0] CH = CH_I[1:0];
		wire [9:0] v [0:3];

		for (sm = 0; sm < 4; sm = sm + 1) begin : g_s
			reg [31:0] wd;
			reg [2:0] cf;

			/* Sample sm of pixel j / 4: the word of its slot, and the channel's format. */
			always @(*) begin
				wd = 32'd0;
				cf = fmt;
				if (fmt == 3'd0) begin
					case (psl)
					3'd0: wd = (j % 4) < 1 ? {24'd0, in_s[8 * (4 * (j / 4) + sm) +: 8]} : 32'd0;
					3'd1: wd = (j % 4) < 2 ? {16'd0, in_s[16 * (4 * (j / 4) + sm) +: 16]} : 32'd0;
					3'd2: wd = in_s[32 * (4 * (j / 4) + sm) +: 32];
					default: wd = 32'd0;
					endcase
				end else if (fmt == 3'd6) begin
					wd = in_s[32 * (4 * (j / 4) + sm) +: 32];
				end else if (fmt == 3'd1 || fmt == 3'd7) begin
					wd = {16'd0, in_s[16 * (4 * (j / 4) + sm) +: 16]};
				end else begin
					cf = 3'd2;
				end
			end
			assign v[sm] = chan(cf, CH, wd);
		end

		wire [11:0] s01, s23, sum;
		wire [2:0] sum_co_unused;
		wire q_co_unused;

		am_add #(.W(12)) a_01 (.a({2'd0, v[0]}), .b({2'd0, v[1]}), .ci(1'b0), .s(s01), .co(sum_co_unused[0]));
		am_add #(.W(12)) a_23 (.a({2'd0, v[2]}), .b({2'd0, v[3]}), .ci(1'b0), .s(s23), .co(sum_co_unused[1]));
		am_add #(.W(12)) a_s (.a(s01), .b(s23), .ci(1'b0), .s(sum), .co(sum_co_unused[2]));
`ifdef MUT_RSV_RNE
		wire round_up = sum[1];
`else
		wire round_up = sum[1] && (sum[0] || sum[2]);
`endif
		am_add #(.W(10)) a_q (.a(sum[11:2]), .b(10'd0), .ci(round_up), .s(q[10 * j +: 10]), .co(q_co_unused));

		wire unused_ok = &{1'b0, sum_co_unused, q_co_unused};
	end
	endgenerate

	/* The output pixels of each format and pixel size. */
	reg [31:0] px;
	integer pp, cc;

	always @(*) begin
		out_p = 128'd0;
		px = 32'd0;
		case (fmt)
		3'd0:
			case (psl)
			3'd0:
				for (pp = 0; pp < 4; pp = pp + 1)
					out_p[8 * pp +: 8] = q[10 * (4 * pp) +: 8];
			3'd1:
				for (pp = 0; pp < 4; pp = pp + 1)
					for (cc = 0; cc < 2; cc = cc + 1)
						out_p[8 * (2 * pp + cc) +: 8] = q[10 * (4 * pp + cc) +: 8];
			3'd2:
				for (pp = 0; pp < 4; pp = pp + 1)
					for (cc = 0; cc < 4; cc = cc + 1)
						out_p[8 * (4 * pp + cc) +: 8] = q[10 * (4 * pp + cc) +: 8];
			default:	/* above 4 bytes: nothing */
				out_p = 128'd0;
			endcase
		3'd1, 3'd6, 3'd7:	/* the fields: any size */
			for (pp = 0; pp < 4; pp = pp + 1) begin
				px = place(fmt, 2'd0, q[10 * (4 * pp) +: 10]) | place(fmt, 2'd1, q[10 * (4 * pp + 1) +: 10]) |
					place(fmt, 2'd2, q[10 * (4 * pp + 2) +: 10]) | place(fmt, 2'd3, q[10 * (4 * pp + 3) +: 10]);
				if (fmt == 3'd6)
					out_p[32 * pp +: 32] = px;
				else
					out_p[16 * pp +: 16] = px[15:0];
			end
		default:	/* SAMPLE0 */
			case (psl)
			3'd0: out_p = sample0(3'd0, in_s);
			3'd1: out_p = sample0(3'd1, in_s);
			3'd2: out_p = sample0(3'd2, in_s);
			3'd3: out_p = sample0(3'd3, in_s);
			3'd4: out_p = sample0(3'd4, in_s);
			default: out_p = sample0(3'd5, in_s);	/* 32 bytes and more: as 16 */
			endcase
		endcase
	end

endmodule

`default_nettype wire
