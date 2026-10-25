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
	wire [15:0] y1s, y2s, y3s, y4s, y5s, y6s, y_sum;
	wire [15:0] cb1s, cb2s, cb3s, cb4s, cb5s, cb6s, cb7s, cb_sum;
	wire [15:0] cr1s, cr2s, cr3s, cr4s, cr5s, cr6s, cr_sum;
	wire [21:0] sum_co_unused;

	/* Y = 64 R + 2 R + 128 G + G + 16 B + 8 B + B + 4224. */
	am_add #(.W(16)) y_1 (.a(r << 6), .b(r << 1), .ci(1'b0), .s(y1s), .co(sum_co_unused[0]));
	am_add #(.W(16)) y_2 (.a(y1s), .b(g << 7), .ci(1'b0), .s(y2s), .co(sum_co_unused[1]));
	am_add #(.W(16)) y_3 (.a(y2s), .b(g), .ci(1'b0), .s(y3s), .co(sum_co_unused[2]));
	am_add #(.W(16)) y_4 (.a(y3s), .b(b << 4), .ci(1'b0), .s(y4s), .co(sum_co_unused[3]));
	am_add #(.W(16)) y_5 (.a(y4s), .b(b << 3), .ci(1'b0), .s(y5s), .co(sum_co_unused[4]));
	am_add #(.W(16)) y_6 (.a(y5s), .b(b), .ci(1'b0), .s(y6s), .co(sum_co_unused[5]));
	am_add #(.W(16)) y_7 (.a(y6s), .b(16'd4224), .ci(1'b0), .s(y_sum), .co(sum_co_unused[6]));

	/* Cb = 128 B - 16 B - 32 R - 4 R - 2 R - 64 G - 8 G - 2 G + 32896. */
	am_sub #(.W(16)) cb_1 (.a(b << 7), .b(b << 4), .bi(1'b0), .d(cb1s), .bo(sum_co_unused[7]));
	am_sub #(.W(16)) cb_2 (.a(cb1s), .b(r << 5), .bi(1'b0), .d(cb2s), .bo(sum_co_unused[8]));
	am_sub #(.W(16)) cb_3 (.a(cb2s), .b(r << 2), .bi(1'b0), .d(cb3s), .bo(sum_co_unused[9]));
	am_sub #(.W(16)) cb_4 (.a(cb3s), .b(r << 1), .bi(1'b0), .d(cb4s), .bo(sum_co_unused[10]));
	am_sub #(.W(16)) cb_5 (.a(cb4s), .b(g << 6), .bi(1'b0), .d(cb5s), .bo(sum_co_unused[11]));
	am_sub #(.W(16)) cb_6 (.a(cb5s), .b(g << 3), .bi(1'b0), .d(cb6s), .bo(sum_co_unused[12]));
	am_sub #(.W(16)) cb_7 (.a(cb6s), .b(g << 1), .bi(1'b0), .d(cb7s), .bo(sum_co_unused[13]));
	am_add #(.W(16)) cb_8 (.a(cb7s), .b(16'd32896), .ci(1'b0), .s(cb_sum), .co(sum_co_unused[14]));

	/* Cr = 128 R - 16 R - 128 G + 32 G + 2 G - 16 B - 2 B + 32896. */
	am_sub #(.W(16)) cr_1 (.a(r << 7), .b(r << 4), .bi(1'b0), .d(cr1s), .bo(sum_co_unused[15]));
	am_sub #(.W(16)) cr_2 (.a(cr1s), .b(g << 7), .bi(1'b0), .d(cr2s), .bo(sum_co_unused[16]));
	am_add #(.W(16)) cr_3 (.a(cr2s), .b(g << 5), .ci(1'b0), .s(cr3s), .co(sum_co_unused[17]));
	am_add #(.W(16)) cr_4 (.a(cr3s), .b(g << 1), .ci(1'b0), .s(cr4s), .co(sum_co_unused[18]));
	am_sub #(.W(16)) cr_5 (.a(cr4s), .b(b << 4), .bi(1'b0), .d(cr5s), .bo(sum_co_unused[19]));
	am_sub #(.W(16)) cr_6 (.a(cr5s), .b(b << 1), .bi(1'b0), .d(cr6s), .bo(sum_co_unused[20]));
	am_add #(.W(16)) cr_7 (.a(cr6s), .b(16'd32896), .ci(1'b0), .s(cr_sum), .co(sum_co_unused[21]));

	/* Stage 1: the three components. */
	reg [7:0] y1, cb1, cr1;
	reg de1, hs1, vs1;
	/* Stage 2: the pair. */
	reg odd;
	reg [7:0] cr_held;

	always @(posedge clk) begin
		if (!rst_n) begin
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
