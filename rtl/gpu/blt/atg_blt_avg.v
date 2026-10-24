/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_avg: the averages of the blitter's RESOLVE (docs/ghci.md section
 * 8.2), combinational.  The input holds four pixels of four samples each,
 * sample s of pixel p at sample slot 4 p + s, one slot per pixel size
 * (32-bit pixels: slot k at bits 32 k; 16-bit pixels: at bits 16 k, the
 * low 256 bits).  The output holds the four pixels' averages, pixel p at
 * bits 32 p (16 p for 16-bit pixels, the low 64 bits; the rest 0):
 *
 *   fmt 0 UNORM8    every byte an unsigned normalized channel: the sum of
 *                   the four codes divided by 4, rounded to the nearest
 *                   code, ties to even
 *   fmt 1 UNORM565  the fields [15:11], [10:5], [4:0] of 16-bit pixels,
 *                   each the same way
 *   fmt 2 SAMPLE0   sample 0
 *
 * Other fmt values give SAMPLE0 (atg_blt_rsv refuses them at the kick).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_avg (
	input wire [1:0] fmt,
	input wire is16,
	input wire [511:0] in_s,
	output reg [127:0] out_p
);
	/* sum / 4, rounded to the nearest integer, ties to even (sum < 1024). */
	function [7:0] rne4;
		input [9:0] sum;
		begin
`ifdef MUT_RSV_RNE
			rne4 = sum[9:2] + {7'd0, sum[1]};
`else
			rne4 = sum[9:2] + {7'd0, sum[1] && (sum[0] || sum[2])};
`endif
		end
	endfunction

	integer p, k, s, f, w;
	reg [9:0] sum;
	reg [7:0] q;
	reg [15:0] h;
	reg [15:0] px565;

	always @(*) begin
		out_p = 128'd0;
		sum = 10'd0;
		q = 8'd0;
		h = 16'd0;
		px565 = 16'd0;
		w = is16 ? 2 : 4;
		for (p = 0; p < 4; p = p + 1) begin
			if (fmt == 2'd1 && is16) begin
				/* UNORM565: the three fields, at bits 0, 5 and 11. */
				px565 = 16'd0;
				for (f = 0; f < 3; f = f + 1) begin
					sum = 10'd0;
					for (s = 0; s < 4; s = s + 1) begin
						h = in_s[16 * (4 * p + s) +: 16];
						if (f == 0)
							sum = sum + {5'd0, h[4:0]};
						else if (f == 1)
							sum = sum + {4'd0, h[10:5]};
						else
							sum = sum + {5'd0, h[15:11]};
					end
					q = rne4(sum);
					if (f == 0)
						px565[4:0] = q[4:0];
					else if (f == 1)
						px565[10:5] = q[5:0];
					else
						px565[15:11] = q[4:0];
				end
				out_p[16 * p +: 16] = px565;
			end else if (fmt == 2'd0) begin
				/* UNORM8: every byte of the pixel. */
				for (k = 0; k < 4; k = k + 1) begin
					if (k < w) begin
						sum = 10'd0;
						for (s = 0; s < 4; s = s + 1)
							sum = sum + {2'd0, in_s[8 * (w * (4 * p + s) + k) +: 8]};
						out_p[8 * (w * p + k) +: 8] = rne4(sum);
					end
				end
			end else if (is16) begin
				out_p[16 * p +: 16] = in_s[64 * p +: 16];	/* SAMPLE0 */
			end else begin
				out_p[32 * p +: 32] = in_s[128 * p +: 32];
			end
		end
	end

	wire unused_ok = &{1'b0, q[7:6]};
endmodule

`default_nettype wire
