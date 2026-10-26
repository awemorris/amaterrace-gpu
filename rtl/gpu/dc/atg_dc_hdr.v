/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_hdr: Display Controller HDR10 & Color Management Engine.
 *
 * Implements:
 * 1. 10-bit Color Space Conversion (BT.709 -> BT.2020 color gamut matrix).
 *    All fixed-point multiplications are performed using am_mul (DSP48E1),
 *    and matrix additions using am_add.
 * 2. SMPTE ST 2084 (PQ: Perceptual Quantizer) EOTF non-linear LUT:
 *    1024-entry 10-bit lookup table.
 *
 * When hdr_en is 0, inputs are passed through directly without modification.
 * When hdr_en is 1, pixels are transformed through BT.2020 matrix and PQ LUT.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_hdr #(
	parameter CSC_ENABLE = 1
) (
	input  wire        pclk,
	input  wire        prst_n,
	input  wire        hdr_en,
	input  wire [9:0]  in_r, in_g, in_b, /* 10-bit RGB input */
	output reg  [9:0]  out_r, out_g, out_b /* 10-bit RGB output */
);
	/*
	 * BT.709 -> BT.2020 Matrix Coefficients (12-bit fixed point, /4096):
	 * R2020 = (2570 * R + 1349 * G +  177 * B) / 4096
	 * G2020 = ( 283 * R + 3766 * G +   47 * B) / 4096
	 * B2020 = (   7 * R +  360 * G + 3729 * B) / 4096
	 */
	localparam [11:0] C00 = 12'd2570;
	localparam [11:0] C01 = 12'd1349;
	localparam [11:0] C02 = 12'd177;

	localparam [11:0] C10 = 12'd283;
	localparam [11:0] C11 = 12'd3766;
	localparam [11:0] C12 = 12'd47;

	localparam [11:0] C20 = 12'd7;
	localparam [11:0] C21 = 12'd360;
	localparam [11:0] C22 = 12'd3729;

	/* Multipliers for Row 0 (R) */
	wire [21:0] p_r0, p_r1, p_r2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_r0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C00), .p(p_r0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_r1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C01), .p(p_r1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_r2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C02), .p(p_r2));

	/* verilator lint_off UNUSEDSIGNAL */
	wire [21:0] sum_r01, sum_r;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_r_unused;
	am_add #(.W(22)) u_add_r01 (.a(p_r0), .b(p_r1), .ci(1'b0), .s(sum_r01), .co(co_r_unused[0]));
	am_add #(.W(22)) u_add_r   (.a(sum_r01), .b(p_r2), .ci(1'b0), .s(sum_r), .co(co_r_unused[1]));

	wire [9:0] r_csc;
	wire r_co;
	am_add #(.W(10)) u_add_rnd_r (.a(sum_r[21:12]), .b(10'd0), .ci(sum_r[11]), .s(r_csc), .co(r_co));
	wire [9:0] r_idx = (CSC_ENABLE != 0) ? (r_co ? 10'h3FF : r_csc) : in_r;

	/* Multipliers for Row 1 (G) */
	wire [21:0] p_g0, p_g1, p_g2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_g0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C10), .p(p_g0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_g1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C11), .p(p_g1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_g2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C12), .p(p_g2));

	/* verilator lint_off UNUSEDSIGNAL */
	wire [21:0] sum_g01, sum_g;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_g_unused;
	am_add #(.W(22)) u_add_g01 (.a(p_g0), .b(p_g1), .ci(1'b0), .s(sum_g01), .co(co_g_unused[0]));
	am_add #(.W(22)) u_add_g   (.a(sum_g01), .b(p_g2), .ci(1'b0), .s(sum_g), .co(co_g_unused[1]));

	wire [9:0] g_csc;
	wire g_co;
	am_add #(.W(10)) u_add_rnd_g (.a(sum_g[21:12]), .b(10'd0), .ci(sum_g[11]), .s(g_csc), .co(g_co));
	wire [9:0] g_idx = (CSC_ENABLE != 0) ? (g_co ? 10'h3FF : g_csc) : in_g;

	/* Multipliers for Row 2 (B) */
	wire [21:0] p_b0, p_b1, p_b2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_b0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C20), .p(p_b0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_b1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C21), .p(p_b1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(0)) u_mul_b2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C22), .p(p_b2));

	/* verilator lint_off UNUSEDSIGNAL */
	wire [21:0] sum_b01, sum_b;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [1:0] co_b_unused;
	am_add #(.W(22)) u_add_b01 (.a(p_b0), .b(p_b1), .ci(1'b0), .s(sum_b01), .co(co_b_unused[0]));
	am_add #(.W(22)) u_add_b   (.a(sum_b01), .b(p_b2), .ci(1'b0), .s(sum_b), .co(co_b_unused[1]));

	wire [9:0] b_csc;
	wire b_co;
	am_add #(.W(10)) u_add_rnd_b (.a(sum_b[21:12]), .b(10'd0), .ci(sum_b[11]), .s(b_csc), .co(b_co));
	wire [9:0] b_idx = (CSC_ENABLE != 0) ? (b_co ? 10'h3FF : b_csc) : in_b;

	/* SMPTE ST 2084 (PQ) 1024-entry LUT */
	reg [9:0] lut [0:1023];
	initial begin
		`include "atg_dc_pq_lut.vh"
	end

	always @(posedge pclk) begin
		if (!prst_n) begin
			out_r <= 10'd0;
			out_g <= 10'd0;
			out_b <= 10'd0;
		end else if (!hdr_en) begin
			out_r <= in_r;
			out_g <= in_g;
			out_b <= in_b;
		end else begin
			out_r <= lut[r_idx];
			out_g <= lut[g_idx];
			out_b <= lut[b_idx];
		end
	end

	wire unused_ok = &{1'b0, co_r_unused, co_g_unused, co_b_unused};
endmodule

`default_nettype wire
