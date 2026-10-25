/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fsum: one channel of atg_tu_filter's sums (P5 → P11): R = the
 * four texels' bytes times their bilinear weights (below 2^24), then A =
 * (i_acc ? the lane's sum i_al : 0) + R × W, W the pass's weight.
 *
 * Pipelined, no stall: i_by, i_w and i_wp in cycle 5 (atg_tu_filter's
 * P5), the products in 7 (am_mul, 2 registers), R in 9, R × W in 11
 * (am_mul, 2 registers); i_al and i_acc in cycle 11, o_rr combinational
 * in that cycle (atg_tu_filter writes it back and registers it).
 * See spec/gpu/tu/atg_tu_filter.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fsum (
	input wire clk,
	input wire [31:0] i_by,	/* texel t's byte in [8t +: 8] */
	input wire [67:0] i_w,	/* texel t's weight in [17t +: 17] */
	input wire [16:0] i_wp,
	input wire [39:0] i_al,
	input wire i_acc,
	output wire [39:0] o_rr
);
	wire [24:0] pr [0:3];
	genvar g;
	generate
	for (g = 0; g < 4; g = g + 1) begin : g_pr
		am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(2)) u_pr (
			.clk(clk), .en(1'b1), .a(i_by[g*8 +: 8]), .b(i_w[g*17 +: 17]), .p(pr[g])
		);
	end
	endgenerate

	reg [16:0] wp6, wp7, wp8, wp9;
	always @(posedge clk) begin
		wp6 <= i_wp;
		wp7 <= wp6;
		wp8 <= wp7;
		wp9 <= wp8;
	end

	wire [25:0] s01, s23, rs;
	wire [3:0] s_nc;
	reg [25:0] s01_8, s23_8;
	reg [23:0] r9;

	am_add #(.W(26)) u_s01 (.a({1'b0, pr[0]}), .b({1'b0, pr[1]}), .ci(1'b0), .s(s01),
		.co(s_nc[0]));
	am_add #(.W(26)) u_s23 (.a({1'b0, pr[2]}), .b({1'b0, pr[3]}), .ci(1'b0), .s(s23),
		.co(s_nc[1]));
	am_add #(.W(26)) u_r (.a(s01_8), .b(s23_8), .ci(1'b0), .s(rs), .co(s_nc[2]));

	always @(posedge clk) begin
		s01_8 <= s01;
		s23_8 <= s23;
		r9 <= rs[23:0];
	end

	wire [40:0] rw11;

	am_mul #(.AW(24), .BW(17), .SIGNED(0), .LAT(2)) u_rw (
		.clk(clk), .en(1'b1), .a(r9), .b(wp9), .p(rw11)
	);
	am_add #(.W(40)) u_rr (.a(i_acc ? i_al : 40'd0), .b(rw11[39:0]), .ci(1'b0), .s(o_rr),
		.co(s_nc[3]));

	wire unused_ok = &{1'b0, s_nc, rs[25:24], rw11[40]};
endmodule

`default_nettype wire
