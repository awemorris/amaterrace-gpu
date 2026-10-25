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
 * (the offsets are folded into one non-negative 16-bit sum).  The chroma
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

	/* Each sum stays in 0..65535 (the minimum of Cb and Cr is 4336). */
	wire [15:0] y_sum = 16'd66 * r + 16'd129 * g + 16'd25 * b + 16'd4224;
	wire [15:0] cb_sum = 16'd112 * b - 16'd38 * r - 16'd74 * g + 16'd32896;
	wire [15:0] cr_sum = 16'd112 * r - 16'd94 * g - 16'd18 * b + 16'd32896;

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

	wire unused_ok = &{1'b0, y_sum[7:0], cb_sum[7:0], cr_sum[7:0]};
endmodule

`default_nettype wire
