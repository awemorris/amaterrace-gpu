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
	/* sum / 4, rounded to the nearest integer, ties to even. */
	function [9:0] rne4;
		input [11:0] sum;
		begin
`ifdef MUT_RSV_RNE
			rne4 = sum[11:2] + {9'd0, sum[1]};
`else
			rne4 = sum[11:2] + {9'd0, sum[1] && (sum[0] || sum[2])};
`endif
		end
	endfunction

	/* The fields of a format: {lowest bit, width} of up to four fields. */
	function [43:0] fields;
		input [2:0] f;
		case (f)
		3'd1: fields = {5'd0, 6'd0, 5'd11, 6'd5, 5'd5, 6'd6, 5'd0, 6'd5};
		3'd6: fields = {5'd30, 6'd2, 5'd20, 6'd10, 5'd10, 6'd10, 5'd0, 6'd10};
		3'd7: fields = {5'd15, 6'd1, 5'd10, 6'd5, 5'd5, 6'd5, 5'd0, 6'd5};
		default: fields = 44'd0;
		endcase
	endfunction

	integer p, k, s, f, ps;
	reg [11:0] sum;
	reg [9:0] q;
	reg [31:0] wd, px, wf;
	reg [43:0] fl;
	reg [4:0] fpos;
	reg [5:0] fw;
	reg [31:0] msk;

	always @(*) begin
		out_p = 128'd0;
		ps = 1 << psl;
		fl = fields(fmt);
		sum = 12'd0;
		q = 10'd0;
		px = 32'd0;
		wd = 32'd0;
		wf = 32'd0;
		fpos = 5'd0;
		fw = 6'd0;
		msk = 32'd0;
		for (p = 0; p < 4; p = p + 1) begin
			if (fmt == 3'd0) begin
				/* UNORM8: every byte of the pixel. */
				for (k = 0; k < 4; k = k + 1)
					if (k < ps && ps <= 4) begin
						sum = 12'd0;
						for (s = 0; s < 4; s = s + 1)
							sum = sum + {4'd0, in_s[8 * (ps * (4 * p + s) + k) +: 8]};
						q = rne4(sum);
						out_p[8 * (ps * p + k) +: 8] = q[7:0];
					end
			end else if (fmt == 3'd1 || fmt == 3'd6 || fmt == 3'd7) begin
				/* The fields of a 16- or 32-bit pixel. */
				px = 32'd0;
				for (f = 0; f < 4; f = f + 1) begin
					fpos = fl[11 * f + 6 +: 5];
					fw = fl[11 * f +: 6];
					msk = (32'd1 << fw) - 32'd1;
					sum = 12'd0;
					for (s = 0; s < 4; s = s + 1) begin
						wd = fmt == 3'd6 ? in_s[32 * (4 * p + s) +: 32] :
							{16'd0, in_s[16 * (4 * p + s) +: 16]};
						wf = (wd >> fpos) & msk;
						sum = sum + {2'd0, wf[9:0]};
					end
					q = rne4(sum);
					if (fw != 6'd0)
						px = px | (({22'd0, q} & msk) << fpos);
				end
				if (fmt == 3'd6)
					out_p[32 * p +: 32] = px;
				else
					out_p[16 * p +: 16] = px[15:0];
			end else begin
				/* SAMPLE0: the bytes of sample 0. */
				for (k = 0; k < 16; k = k + 1)
					if (k < ps && ps * p + k < 16)
						out_p[8 * (ps * p + k) +: 8] = in_s[8 * (ps * 4 * p + k) +: 8];
			end
		end
	end

	wire unused_ok = &{1'b0, q[9:8], sum, wf[31:10]};
endmodule

`default_nettype wire
