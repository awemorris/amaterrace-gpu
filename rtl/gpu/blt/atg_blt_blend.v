/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_blend: the blend-over of the blitter's 2D engine (atg_blt_2d):
 * a line of 32-bit pixels, source over destination with premultiplied
 * alpha in bits 31:24, per byte out = src + round(dst x (255 - src.a) /
 * 255), saturated at 255 (docs/ghci.md section 8.2).
 *
 * go (a pulse) starts a line: src and dst are held by the caller until
 * done; three stages, one word a cycle (take the words, the four 8 x 8
 * products, the sums); out holds the blended line from done (a pulse,
 * WPL + 2 cycles after go) until the next go.  round(t / 255) is (t + 128
 * + ((t + 128) >> 8)) >> 8.  See spec/gpu/blt/atg_blt_blend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_blend #(
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire go,
	input wire [LINE_BYTES*8-1:0] src,
	input wire [LINE_BYTES*8-1:0] dst,
	output reg done,
	output reg [LINE_BYTES*8-1:0] out
);
	localparam WPL = LINE_BYTES / 4;	/* 32-bit words per line */
	localparam WS = LINE_SHIFT - 2;		/* log2(WPL) */

	/* verilator lint_off WIDTHTRUNC */
	localparam [WS:0] WPL_V = WPL;
	/* verilator lint_on WIDTHTRUNC */

	reg run;
	reg [WS:0] bi;		/* the next word to take */
	reg a_v;
	reg [WS-1:0] a_i;
	reg [31:0] a_s;
	reg [31:0] a_d;
	reg b_v;
	reg [WS-1:0] b_i;
	reg [31:0] b_s;
	reg [63:0] b_t;		/* four 16-bit products */
	wire [7:0] inv_a = 8'd255 - a_s[31:24];

	function [15:0] mul8;
		input [7:0] x;
		input [7:0] y;
		mul8 = {8'd0, x} * {8'd0, y};
	endfunction

	reg [31:0] b_out;
	reg [16:0] t1;
	reg [16:0] t2;
	reg [8:0] sum;
	integer c;

	always @(*) begin
		b_out = 32'd0;
		t1 = 17'd0;
		t2 = 17'd0;
		sum = 9'd0;
		for (c = 0; c < 4; c = c + 1) begin
			t1 = {1'b0, b_t[c*16 +: 16]} + 17'd128;
			t2 = t1 + {8'd0, t1[16:8]};
			sum = {1'b0, b_s[c*8 +: 8]} + t2[16:8];
			b_out[c*8 +: 8] = sum[8] ? 8'hFF : sum[7:0];
		end
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			run <= 1'b0;
			done <= 1'b0;
			bi <= {(WS + 1){1'b0}};
			a_v <= 1'b0;
			b_v <= 1'b0;
		end else begin
			done <= 1'b0;
			if (go) begin
				run <= 1'b1;
				bi <= {(WS + 1){1'b0}};
				a_v <= 1'b0;
				b_v <= 1'b0;
			end else if (run) begin
				/* Stage 1: take word bi. */
				a_v <= bi != WPL_V;
				if (bi != WPL_V) begin
					a_s <= src[{bi[WS-1:0], 5'd0} +: 32];
					a_d <= dst[{bi[WS-1:0], 5'd0} +: 32];
					a_i <= bi[WS-1:0];
					bi <= bi + 1'b1;
				end
				/* Stage 2: its products. */
				b_v <= a_v;
				b_s <= a_s;
				b_i <= a_i;
				b_t <= {mul8(a_d[31:24], inv_a), mul8(a_d[23:16], inv_a),
					mul8(a_d[15:8], inv_a), mul8(a_d[7:0], inv_a)};
				/* Stage 3: its sums. */
				if (b_v)
					out[{b_i, 5'd0} +: 32] <= b_out;
				if (bi == WPL_V && !a_v && !b_v) begin
					run <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, t2[7:0]};
endmodule

`default_nettype wire
