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
	wire [15:0] y_sum, cb_sum, cr_sum;
	wire [2:0] sum_co_unused;

	/* 3:2 CSA reduction + single 16-bit am_add per channel (zero chained adders) */
	wire [15:0] yt0 = r << 6, yt1 = r << 1, yt2 = g << 7, yt3 = g;
	wire [15:0] yt4 = b << 4, yt5 = b << 3, yt6 = b,      yt7 = 16'd4224;
	wire [15:0] ys1a = yt0 ^ yt1 ^ yt2, yc1a = ((yt0 & yt1) | (yt0 & yt2) | (yt1 & yt2)) << 1;
	wire [15:0] ys1b = yt3 ^ yt4 ^ yt5, yc1b = ((yt3 & yt4) | (yt3 & yt5) | (yt4 & yt5)) << 1;
	wire [15:0] ys2a = ys1a ^ yc1a ^ ys1b, yc2a = ((ys1a & yc1a) | (ys1a & ys1b) | (yc1a & ys1b)) << 1;
	wire [15:0] ys2b = yc1b ^ yt6  ^ yt7,  yc2b = ((yc1b & yt6)  | (yc1b & yt7)  | (yt6  & yt7))  << 1;
	wire [15:0] ys3  = ys2a ^ yc2a ^ ys2b, yc3  = ((ys2a & yc2a) | (ys2a & ys2b) | (yc2a & ys2b)) << 1;
	wire [15:0] ys4  = ys3  ^ yc3  ^ yc2b, yc4  = ((ys3  & yc3)  | (ys3  & yc2b) | (yc3  & yc2b)) << 1;
	wire [15:0] ys_p0 = ys4;
	wire [15:0] yc_p0 = yc4;
	wire [3:0] y_s0;
	wire [3:0] y_s1_0, y_s1_1, y_s2_0, y_s2_1, y_s3_0, y_s3_1;
	wire y_c0, y_c1_0, y_c1_1, y_c2_0, y_c2_1, y_c3_0, y_c3_1;
	am_add #(.W(4)) y_7_0  (.a(ys_p0[3:0]),   .b(yc_p0[3:0]),   .ci(1'b0), .s(y_s0),   .co(y_c0));
	am_add #(.W(4)) y_7_10 (.a(ys_p0[7:4]),   .b(yc_p0[7:4]),   .ci(1'b0), .s(y_s1_0), .co(y_c1_0));
	am_add #(.W(4)) y_7_11 (.a(ys_p0[7:4]),   .b(yc_p0[7:4]),   .ci(1'b1), .s(y_s1_1), .co(y_c1_1));
	am_add #(.W(4)) y_7_20 (.a(ys_p0[11:8]),  .b(yc_p0[11:8]),  .ci(1'b0), .s(y_s2_0), .co(y_c2_0));
	am_add #(.W(4)) y_7_21 (.a(ys_p0[11:8]),  .b(yc_p0[11:8]),  .ci(1'b1), .s(y_s2_1), .co(y_c2_1));
	am_add #(.W(4)) y_7_30 (.a(ys_p0[15:12]), .b(yc_p0[15:12]), .ci(1'b0), .s(y_s3_0), .co(y_c3_0));
	am_add #(.W(4)) y_7_31 (.a(ys_p0[15:12]), .b(yc_p0[15:12]), .ci(1'b1), .s(y_s3_1), .co(y_c3_1));
	wire y_c1 = y_c0 ? y_c1_1 : y_c1_0;
	wire y_c2 = y_c1 ? y_c2_1 : y_c2_0;
	assign y_sum = {y_c2 ? y_s3_1 : y_s3_0, y_c1 ? y_s2_1 : y_s2_0, y_c0 ? y_s1_1 : y_s1_0, y_s0};
	assign sum_co_unused[0] = y_c2 ? y_c3_1 : y_c3_0;

	/* Cb: 128 B + 32896 - (16 B + 32 R + 4 R + 2 R + 64 G + 8 G + 2 G) = sum + 7 + 32896 */
	wire [15:0] ct0 = b << 7,    ct1 = ~(g << 1), ct2 = ~(b << 4);
	wire [15:0] ct3 = ~(r << 5), ct4 = ~(r << 2), ct5 = ~(r << 1);
	wire [15:0] ct6 = ~(g << 6), ct7 = ~(g << 3), ct8 = 16'd32903;
	wire [15:0] cs1a = ct0 ^ ct1 ^ ct2, cc1a = ((ct0 & ct1) | (ct0 & ct2) | (ct1 & ct2)) << 1;
	wire [15:0] cs1b = ct3 ^ ct4 ^ ct5, cc1b = ((ct3 & ct4) | (ct3 & ct5) | (ct4 & ct5)) << 1;
	wire [15:0] cs1c = ct6 ^ ct7 ^ ct8, cc1c = ((ct6 & ct7) | (ct6 & ct8) | (ct7 & ct8)) << 1;
	wire [15:0] cs2a = cs1a ^ cc1a ^ cs1b, cc2a = ((cs1a & cc1a) | (cs1a & cs1b) | (cc1a & cs1b)) << 1;
	wire [15:0] cs2b = cc1b ^ cs1c ^ cc1c, cc2b = ((cc1b & cs1c) | (cc1b & cc1c) | (cs1c & cc1c)) << 1;
	wire [15:0] cs3  = cs2a ^ cc2a ^ cs2b, cc3  = ((cs2a & cc2a) | (cs2a & cs2b) | (cc2a & cs2b)) << 1;
	wire [15:0] cs4  = cs3  ^ cc3  ^ cc2b, cc4  = ((cs3  & cc3)  | (cs3  & cc2b) | (cc3  & cc2b)) << 1;
	wire [3:0] cb_s0, cb_s1_0, cb_s1_1, cb_s2_0, cb_s2_1, cb_s3_0, cb_s3_1;
	wire cb_c0, cb_c1_0, cb_c1_1, cb_c2_0, cb_c2_1, cb_c3_0, cb_c3_1;
	am_add #(.W(4)) cb_8_0  (.a(cs4[3:0]),   .b(cc4[3:0]),   .ci(1'b0), .s(cb_s0),   .co(cb_c0));
	am_add #(.W(4)) cb_8_10 (.a(cs4[7:4]),   .b(cc4[7:4]),   .ci(1'b0), .s(cb_s1_0), .co(cb_c1_0));
	am_add #(.W(4)) cb_8_11 (.a(cs4[7:4]),   .b(cc4[7:4]),   .ci(1'b1), .s(cb_s1_1), .co(cb_c1_1));
	am_add #(.W(4)) cb_8_20 (.a(cs4[11:8]),  .b(cc4[11:8]),  .ci(1'b0), .s(cb_s2_0), .co(cb_c2_0));
	am_add #(.W(4)) cb_8_21 (.a(cs4[11:8]),  .b(cc4[11:8]),  .ci(1'b1), .s(cb_s2_1), .co(cb_c2_1));
	am_add #(.W(4)) cb_8_30 (.a(cs4[15:12]), .b(cc4[15:12]), .ci(1'b0), .s(cb_s3_0), .co(cb_c3_0));
	am_add #(.W(4)) cb_8_31 (.a(cs4[15:12]), .b(cc4[15:12]), .ci(1'b1), .s(cb_s3_1), .co(cb_c3_1));
	wire cb_c1 = cb_c0 ? cb_c1_1 : cb_c1_0;
	wire cb_c2 = cb_c1 ? cb_c2_1 : cb_c2_0;
	assign cb_sum = {cb_c2 ? cb_s3_1 : cb_s3_0, cb_c1 ? cb_s2_1 : cb_s2_0, cb_c0 ? cb_s1_1 : cb_s1_0, cb_s0};
	assign sum_co_unused[1] = cb_c2 ? cb_c3_1 : cb_c3_0;

	/* Cr: 128 R + 32896 + 32 G + 2 G - (16 R + 128 G + 16 B + 2 B) = sum + 4 + 32896 */
	wire [15:0] rt0 = r << 7,    rt1 = g << 5,    rt2 = g << 1,    rt3 = ~(r << 4);
	wire [15:0] rt4 = ~(g << 7), rt5 = ~(b << 4), rt6 = ~(b << 1), rt7 = 16'd32900;
	wire [15:0] rs1a = rt0 ^ rt1 ^ rt2, rc1a = ((rt0 & rt1) | (rt0 & rt2) | (rt1 & rt2)) << 1;
	wire [15:0] rs1b = rt3 ^ rt4 ^ rt5, rc1b = ((rt3 & rt4) | (rt3 & rt5) | (rt4 & rt5)) << 1;
	wire [15:0] rs2a = rs1a ^ rc1a ^ rs1b, rc2a = ((rs1a & rc1a) | (rs1a & rs1b) | (rc1a & rs1b)) << 1;
	wire [15:0] rs2b = rc1b ^ rt6  ^ rt7,  rc2b = ((rc1b & rt6)  | (rc1b & rt7)  | (rt6  & rt7))  << 1;
	wire [15:0] rs3  = rs2a ^ rc2a ^ rs2b, rc3  = ((rs2a & rc2a) | (rs2a & rs2b) | (rc2a & rs2b)) << 1;
	wire [15:0] rs4  = rs3  ^ rc3  ^ rc2b, rc4  = ((rs3  & rc3)  | (rs3  & rc2b) | (rc3  & rc2b)) << 1;
	wire [3:0] cr_s0, cr_s1_0, cr_s1_1, cr_s2_0, cr_s2_1, cr_s3_0, cr_s3_1;
	wire cr_c0, cr_c1_0, cr_c1_1, cr_c2_0, cr_c2_1, cr_c3_0, cr_c3_1;
	am_add #(.W(4)) cr_7_0  (.a(rs4[3:0]),   .b(rc4[3:0]),   .ci(1'b0), .s(cr_s0),   .co(cr_c0));
	am_add #(.W(4)) cr_7_10 (.a(rs4[7:4]),   .b(rc4[7:4]),   .ci(1'b0), .s(cr_s1_0), .co(cr_c1_0));
	am_add #(.W(4)) cr_7_11 (.a(rs4[7:4]),   .b(rc4[7:4]),   .ci(1'b1), .s(cr_s1_1), .co(cr_c1_1));
	am_add #(.W(4)) cr_7_20 (.a(rs4[11:8]),  .b(rc4[11:8]),  .ci(1'b0), .s(cr_s2_0), .co(cr_c2_0));
	am_add #(.W(4)) cr_7_21 (.a(rs4[11:8]),  .b(rc4[11:8]),  .ci(1'b1), .s(cr_s2_1), .co(cr_c2_1));
	am_add #(.W(4)) cr_7_30 (.a(rs4[15:12]), .b(rc4[15:12]), .ci(1'b0), .s(cr_s3_0), .co(cr_c3_0));
	am_add #(.W(4)) cr_7_31 (.a(rs4[15:12]), .b(rc4[15:12]), .ci(1'b1), .s(cr_s3_1), .co(cr_c3_1));
	wire cr_c1 = cr_c0 ? cr_c1_1 : cr_c1_0;
	wire cr_c2 = cr_c1 ? cr_c2_1 : cr_c2_0;
	assign cr_sum = {cr_c2 ? cr_s3_1 : cr_s3_0, cr_c1 ? cr_s2_1 : cr_s2_0, cr_c0 ? cr_s1_1 : cr_s1_0, cr_s0};
	assign sum_co_unused[2] = cr_c2 ? cr_c3_1 : cr_c3_0;

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
