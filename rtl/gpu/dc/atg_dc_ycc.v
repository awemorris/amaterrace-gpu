/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_ycc: The KC705 HDMI pixel format: RGB888 to 16-bit YCbCr 4:2:2
 * for the ADV7511's parallel input (separate syncs), two register
 * stages.  See spec/gpu/dc/atg_dc_ycc.md.
 *
 * BT.601 with the studio range (Y 16..235, Cb/Cr 16..240), 8-bit
 * coefficients:
 *
 *   Y  = (( 66 R + 129 G +  25 B + 128) >> 8) + 16
 *   Cb = ((-38 R -  74 G + 112 B + 128) >> 8) + 128
 *   Cr = ((112 R -  94 G -  18 B + 128) >> 8) + 128
 *
 * (the offsets are folded into one non-negative 16-bit sum; the constant
 * products are sums of shifted copies added by am_add and am_sub).  The chroma
 * is co-sited: the first pixel of each pair (from the rise of DE) carries
 * its Cb, the second the Cr of the first.  ycc = {C, Y}; outside DE it is
 * black (Y 16, C 128).  DE and the syncs are delayed by the same two
 * stages, so the output is a pixel stream of the same timing.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_ycc (
	input wire clk,
	input wire rst_n,
	input wire [23:0] rgb,
	input wire de,
	input wire hs,
	input wire vs,
	output reg [15:0] ycc,
	output reg ycc_de,
	output reg ycc_hs,
	output reg ycc_vs
);
	wire rst_high = !rst_n;

	wire [15:0] r = {8'd0, rgb[23:16]};
	wire [15:0] g = {8'd0, rgb[15:8]};
	wire [15:0] b = {8'd0, rgb[7:0]};

	/*
	 * Each sum stays in 0..65535 (the minimum of Cb and Cr is 4336).  The
	 * constant products are sums of shifted copies (wiring), added in a
	 * chain modulo 2^16 as the 16-bit expressions were:
	 *   66 = 64 + 2, 129 = 128 + 1, 25 = 16 + 8 + 1;
	 *   112 = 128 - 16, 38 = 32 + 4 + 2, 74 = 64 + 8 + 2;
	 *   94 = 128 - 32 - 2, 18 = 16 + 2.
	 */
	wire [15:0] y_r, y_g, y_b, y_k, y_rg, y_bk, y_sum;
	wire [15:0] cb_p, cb_br, cb_rr, cb_gg, cb_pg, cb_n0, cb_n, cb_sum;
	wire [15:0] cr_p0, cr_p1, cr_n0, cr_n1, cr_pos, cr_neg, cr_sum;
	wire [21:0] sum_co_unused;

	/* Y = (64 R + 2 R) + (128 G + G) + (16 B + 8 B) + (B + 4224), 3-level tree. */
	am_add #(.W(16)) y_1 (.a(r << 6), .b(r << 1), .ci(1'b0), .s(y_r), .co(sum_co_unused[0]));
	am_add #(.W(16)) y_2 (.a(g << 7), .b(g), .ci(1'b0), .s(y_g), .co(sum_co_unused[1]));
	am_add #(.W(16)) y_3 (.a(b << 4), .b(b << 3), .ci(1'b0), .s(y_b), .co(sum_co_unused[2]));
	am_add #(.W(16)) y_4 (.a(b), .b(16'd4224), .ci(1'b0), .s(y_k), .co(sum_co_unused[3]));
	am_add #(.W(16)) y_5 (.a(y_r), .b(y_g), .ci(1'b0), .s(y_rg), .co(sum_co_unused[4]));
	am_add #(.W(16)) y_6 (.a(y_b), .b(y_k), .ci(1'b0), .s(y_bk), .co(sum_co_unused[5]));
	am_add #(.W(16)) y_7 (.a(y_rg), .b(y_bk), .ci(1'b0), .s(y_sum), .co(sum_co_unused[6]));

	/* Cb = (128 B + 32896 - 2 G) - ((16 B + 32 R) + (4 R + 2 R) + (64 G + 8 G)), 4-level tree. */
	am_add #(.W(16)) cb_1 (.a(b << 7), .b(16'd32896), .ci(1'b0), .s(cb_p), .co(sum_co_unused[7]));
	am_add #(.W(16)) cb_2 (.a(b << 4), .b(r << 5), .ci(1'b0), .s(cb_br), .co(sum_co_unused[8]));
	am_add #(.W(16)) cb_3 (.a(r << 2), .b(r << 1), .ci(1'b0), .s(cb_rr), .co(sum_co_unused[9]));
	am_add #(.W(16)) cb_4 (.a(g << 6), .b(g << 3), .ci(1'b0), .s(cb_gg), .co(sum_co_unused[10]));
	am_sub #(.W(16)) cb_5 (.a(cb_p), .b(g << 1), .bi(1'b0), .d(cb_pg), .bo(sum_co_unused[11]));
	am_add #(.W(16)) cb_6 (.a(cb_br), .b(cb_rr), .ci(1'b0), .s(cb_n0), .co(sum_co_unused[12]));
	am_add #(.W(16)) cb_7 (.a(cb_n0), .b(cb_gg), .ci(1'b0), .s(cb_n), .co(sum_co_unused[13]));
	am_sub #(.W(16)) cb_8 (.a(cb_pg), .b(cb_n), .bi(1'b0), .d(cb_sum), .bo(sum_co_unused[14]));

	/* Cr = ((128 R + 32896) + (32 G + 2 G)) - ((16 R + 128 G) + (16 B + 2 B)), 3-level tree. */
	am_add #(.W(16)) cr_1 (.a(r << 7), .b(16'd32896), .ci(1'b0), .s(cr_p0), .co(sum_co_unused[15]));
	am_add #(.W(16)) cr_2 (.a(g << 5), .b(g << 1), .ci(1'b0), .s(cr_p1), .co(sum_co_unused[16]));
	am_add #(.W(16)) cr_3 (.a(r << 4), .b(g << 7), .ci(1'b0), .s(cr_n0), .co(sum_co_unused[17]));
	am_add #(.W(16)) cr_4 (.a(b << 4), .b(b << 1), .ci(1'b0), .s(cr_n1), .co(sum_co_unused[18]));
	am_add #(.W(16)) cr_5 (.a(cr_p0), .b(cr_p1), .ci(1'b0), .s(cr_pos), .co(sum_co_unused[19]));
	am_add #(.W(16)) cr_6 (.a(cr_n0), .b(cr_n1), .ci(1'b0), .s(cr_neg), .co(sum_co_unused[20]));
	am_sub #(.W(16)) cr_7 (.a(cr_pos), .b(cr_neg), .bi(1'b0), .d(cr_sum), .bo(sum_co_unused[21]));

	/* Stage 1: the three components. */
	reg [7:0] y1, cb1, cr1;
	reg de1, hs1, vs1;
	/* Stage 2: the pair. */
	reg odd;
	reg [7:0] cr_held;

	always @(posedge clk or posedge rst_high) begin
		if (rst_high) begin
			y1 <= 8'd16;
			cb1 <= 8'd128;
			cr1 <= 8'd128;
			de1 <= 1'b0;
			hs1 <= 1'b0;
			vs1 <= 1'b0;
			odd <= 1'b0;
			cr_held <= 8'd128;
			ycc <= {8'd128, 8'd16};
			ycc_de <= 1'b0;
			ycc_hs <= 1'b0;
			ycc_vs <= 1'b0;
		end else begin
			y1 <= y_sum[15:8];
			cb1 <= cb_sum[15:8];
			cr1 <= cr_sum[15:8];
			de1 <= de;
			hs1 <= hs;
			vs1 <= vs;

			ycc_de <= de1;
			ycc_hs <= hs1;
			ycc_vs <= vs1;
			if (!de1) begin
				odd <= 1'b0;
				ycc <= {8'd128, 8'd16};
			end else begin
				odd <= !odd;
				if (!odd) begin
					ycc <= {cb1, y1};
					cr_held <= cr1;
				end else begin
					ycc <= {cr_held, y1};
				end
			end
		end
	end

	wire unused_ok = &{1'b0, y_sum[7:0], cb_sum[7:0], cr_sum[7:0], sum_co_unused};
endmodule

`default_nettype wire
