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

`ifdef SYNTH_KINTEX7
	localparam HDR_LAT = 2;
`elsif SYNTH_ASIC
	localparam HDR_LAT = 2;
`else
	localparam HDR_LAT = 0;
`endif

	/* Multipliers for Row 0 (R) */
	wire [21:0] p_r0, p_r1, p_r2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_r0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C00), .p(p_r0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_r1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C01), .p(p_r1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_r2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C02), .p(p_r2));

	/* Multipliers for Row 1 (G) */
	wire [21:0] p_g0, p_g1, p_g2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_g0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C10), .p(p_g0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_g1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C11), .p(p_g1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_g2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C12), .p(p_g2));

	/* Multipliers for Row 2 (B) */
	wire [21:0] p_b0, p_b1, p_b2;
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_b0 (.clk(pclk), .en(1'b1), .a(in_r), .b(C20), .p(p_b0));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_b1 (.clk(pclk), .en(1'b1), .a(in_g), .b(C21), .p(p_b1));
	am_mul #(.AW(10), .BW(12), .SIGNED(0), .LAT(HDR_LAT)) u_mul_b2 (.clk(pclk), .en(1'b1), .a(in_b), .b(C22), .p(p_b2));

`ifdef SYNTH_KINTEX7
	reg [21:0] p_r0_q, p_r1_q, p_r2_q;
	reg [21:0] p_g0_q, p_g1_q, p_g2_q;
	reg [21:0] p_b0_q, p_b1_q, p_b2_q;
	reg [9:0] in_r_q, in_g_q, in_b_q;
	reg hdr_en_q;

	always @(posedge pclk) begin
		p_r0_q <= p_r0; p_r1_q <= p_r1; p_r2_q <= p_r2;
		p_g0_q <= p_g0; p_g1_q <= p_g1; p_g2_q <= p_g2;
		p_b0_q <= p_b0; p_b1_q <= p_b1; p_b2_q <= p_b2;
		in_r_q <= in_r; in_g_q <= in_g; in_b_q <= in_b;
		hdr_en_q <= hdr_en;
	end

	wire [21:0] d_r0 = p_r0_q, d_r1 = p_r1_q, d_r2 = p_r2_q;
	wire [21:0] d_g0 = p_g0_q, d_g1 = p_g1_q, d_g2 = p_g2_q;
	wire [21:0] d_b0 = p_b0_q, d_b1 = p_b1_q, d_b2 = p_b2_q;
	wire [9:0]  d_in_r = in_r_q, d_in_g = in_g_q, d_in_b = in_b_q;
`elsif SYNTH_ASIC
	reg [9:0] in_r_q0, in_g_q0, in_b_q0;
	reg hdr_en_q0;
	reg [21:0] p_r0_q, p_r1_q, p_r2_q;
	reg [21:0] p_g0_q, p_g1_q, p_g2_q;
	reg [21:0] p_b0_q, p_b1_q, p_b2_q;
	reg [9:0] in_r_q, in_g_q, in_b_q;
	reg hdr_en_q;

	always @(posedge pclk) begin
		in_r_q0 <= in_r; in_g_q0 <= in_g; in_b_q0 <= in_b;
		hdr_en_q0 <= hdr_en;
		p_r0_q <= p_r0; p_r1_q <= p_r1; p_r2_q <= p_r2;
		p_g0_q <= p_g0; p_g1_q <= p_g1; p_g2_q <= p_g2;
		p_b0_q <= p_b0; p_b1_q <= p_b1; p_b2_q <= p_b2;
		in_r_q <= in_r_q0; in_g_q <= in_g_q0; in_b_q <= in_b_q0;
		hdr_en_q <= hdr_en_q0;
	end

	wire [21:0] d_r0 = p_r0_q, d_r1 = p_r1_q, d_r2 = p_r2_q;
	wire [21:0] d_g0 = p_g0_q, d_g1 = p_g1_q, d_g2 = p_g2_q;
	wire [21:0] d_b0 = p_b0_q, d_b1 = p_b1_q, d_b2 = p_b2_q;
	wire [9:0]  d_in_r = in_r_q, d_in_g = in_g_q, d_in_b = in_b_q;
`else
	wire [21:0] d_r0 = p_r0, d_r1 = p_r1, d_r2 = p_r2;
	wire [21:0] d_g0 = p_g0, d_g1 = p_g1, d_g2 = p_g2;
	wire [21:0] d_b0 = p_b0, d_b1 = p_b1, d_b2 = p_b2;
	wire [9:0]  d_in_r = in_r, d_in_g = in_g, d_in_b = in_b;
`endif

	/* 3:2 CSA + single 22-bit adder per channel */
	/* verilator lint_off UNUSEDSIGNAL */
	wire [21:0] sum_r, sum_g, sum_b;
	wire [21:0] csa_r_c = (d_r0 & d_r1) | (d_r0 & d_r2) | (d_r1 & d_r2);
	wire [21:0] csa_g_c = (d_g0 & d_g1) | (d_g0 & d_g2) | (d_g1 & d_g2);
	wire [21:0] csa_b_c = (d_b0 & d_b1) | (d_b0 & d_b2) | (d_b1 & d_b2);
	/* verilator lint_on UNUSEDSIGNAL */
	wire [21:0] csa_r_s = d_r0 ^ d_r1 ^ d_r2;
	wire [21:0] csa_g_s = d_g0 ^ d_g1 ^ d_g2;
	wire [21:0] csa_b_s = d_b0 ^ d_b1 ^ d_b2;
	wire [1:0] co_r_unused, co_g_unused, co_b_unused;
	assign co_r_unused[0] = 1'b0;
	assign co_g_unused[0] = 1'b0;
	assign co_b_unused[0] = 1'b0;
	/* Fast 6+6+5+5 carry-select 22-bit add per channel */
	genvar gc;
	wire [21:0] csa_s_w [0:2];
	wire [21:0] csa_c_w [0:2];
	wire [21:0] sum_ch [0:2];
	wire [2:0] sum_ch_co;
	assign csa_s_w[0] = csa_r_s; assign csa_c_w[0] = {csa_r_c[20:0], 1'b0};
	assign csa_s_w[1] = csa_g_s; assign csa_c_w[1] = {csa_g_c[20:0], 1'b0};
	assign csa_s_w[2] = csa_b_s; assign csa_c_w[2] = {csa_b_c[20:0], 1'b0};
	generate
		for (gc = 0; gc < 3; gc = gc + 1) begin : g_hdr_csa_add
			wire [5:0] s0, s1_0, s1_1;
			wire [4:0] s2_0, s2_1, s3_0, s3_1;
			wire c0, c1_0, c1_1, c2_0, c2_1, c3_0, c3_1;
			am_add #(.W(6)) u_a0  (.a(csa_s_w[gc][5:0]),   .b(csa_c_w[gc][5:0]),   .ci(1'b0), .s(s0),   .co(c0));
			am_add #(.W(6)) u_a10 (.a(csa_s_w[gc][11:6]),  .b(csa_c_w[gc][11:6]),  .ci(1'b0), .s(s1_0), .co(c1_0));
			am_add #(.W(6)) u_a11 (.a(csa_s_w[gc][11:6]),  .b(csa_c_w[gc][11:6]),  .ci(1'b1), .s(s1_1), .co(c1_1));
			am_add #(.W(5)) u_a20 (.a(csa_s_w[gc][16:12]), .b(csa_c_w[gc][16:12]), .ci(1'b0), .s(s2_0), .co(c2_0));
			am_add #(.W(5)) u_a21 (.a(csa_s_w[gc][16:12]), .b(csa_c_w[gc][16:12]), .ci(1'b1), .s(s2_1), .co(c2_1));
			am_add #(.W(5)) u_a30 (.a(csa_s_w[gc][21:17]), .b(csa_c_w[gc][21:17]), .ci(1'b0), .s(s3_0), .co(c3_0));
			am_add #(.W(5)) u_a31 (.a(csa_s_w[gc][21:17]), .b(csa_c_w[gc][21:17]), .ci(1'b1), .s(s3_1), .co(c3_1));
			wire c1 = c0 ? c1_1 : c1_0;
			wire c2 = c1 ? c2_1 : c2_0;
			assign sum_ch[gc] = {c2 ? s3_1 : s3_0, c1 ? s2_1 : s2_0, c0 ? s1_1 : s1_0, s0};
			assign sum_ch_co[gc] = c2 ? c3_1 : c3_0;
		end
	endgenerate
	assign sum_r = sum_ch[0]; assign co_r_unused[1] = sum_ch_co[0];
	assign sum_g = sum_ch[1]; assign co_g_unused[1] = sum_ch_co[1];
	assign sum_b = sum_ch[2]; assign co_b_unused[1] = sum_ch_co[2];

`ifdef SYNTH_KINTEX7
	reg [21:0] sum_r_q, sum_g_q, sum_b_q;
	reg [9:0]  in_r_q2, in_g_q2, in_b_q2;
	reg hdr_en_q2;
	always @(posedge pclk) begin
		sum_r_q   <= sum_r;
		sum_g_q   <= sum_g;
		sum_b_q   <= sum_b;
		in_r_q2   <= in_r_q;
		in_g_q2   <= in_g_q;
		in_b_q2   <= in_b_q;
		hdr_en_q2 <= hdr_en_q;
	end
	wire [21:0] pipe_sum_r = sum_r_q, pipe_sum_g = sum_g_q, pipe_sum_b = sum_b_q;
	wire [9:0]  pipe_in_r  = in_r_q2, pipe_in_g  = in_g_q2, pipe_in_b  = in_b_q2;
`elsif SYNTH_ASIC
	reg [21:0] sum_r_q, sum_g_q, sum_b_q;
	reg [9:0]  in_r_q2, in_g_q2, in_b_q2;
	reg hdr_en_q2;
	always @(posedge pclk) begin
		sum_r_q   <= sum_r;
		sum_g_q   <= sum_g;
		sum_b_q   <= sum_b;
		in_r_q2   <= in_r_q;
		in_g_q2   <= in_g_q;
		in_b_q2   <= in_b_q;
		hdr_en_q2 <= hdr_en_q;
	end
	wire [21:0] pipe_sum_r = sum_r_q, pipe_sum_g = sum_g_q, pipe_sum_b = sum_b_q;
	wire [9:0]  pipe_in_r  = in_r_q2, pipe_in_g  = in_g_q2, pipe_in_b  = in_b_q2;
`else
	wire [21:0] pipe_sum_r = sum_r, pipe_sum_g = sum_g, pipe_sum_b = sum_b;
	wire [9:0]  pipe_in_r  = d_in_r, pipe_in_g  = d_in_g, pipe_in_b  = d_in_b;
`endif

	wire [9:0] r_csc;
	wire r_co;
	am_add #(.W(10)) u_add_rnd_r (.a(pipe_sum_r[21:12]), .b(10'd0), .ci(pipe_sum_r[11]), .s(r_csc), .co(r_co));
	(* max_fanout = 16 *) wire [9:0] r_idx = (CSC_ENABLE != 0) ? (r_co ? 10'h3FF : r_csc) : pipe_in_r;

	wire [9:0] g_csc;
	wire g_co;
	am_add #(.W(10)) u_add_rnd_g (.a(pipe_sum_g[21:12]), .b(10'd0), .ci(pipe_sum_g[11]), .s(g_csc), .co(g_co));
	(* max_fanout = 16 *) wire [9:0] g_idx = (CSC_ENABLE != 0) ? (g_co ? 10'h3FF : g_csc) : pipe_in_g;

	wire [9:0] b_csc;
	wire b_co;
	am_add #(.W(10)) u_add_rnd_b (.a(pipe_sum_b[21:12]), .b(10'd0), .ci(pipe_sum_b[11]), .s(b_csc), .co(b_co));
	(* max_fanout = 16 *) wire [9:0] b_idx = (CSC_ENABLE != 0) ? (b_co ? 10'h3FF : b_csc) : pipe_in_b;

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg [9:0] r_idx_q, g_idx_q, b_idx_q;
	reg [9:0] in_r_q3, in_g_q3, in_b_q3;
	reg hdr_en_q3;
	always @(posedge pclk) begin
		r_idx_q   <= r_idx;
		g_idx_q   <= g_idx;
		b_idx_q   <= b_idx;
		in_r_q3   <= in_r_q2;
		in_g_q3   <= in_g_q2;
		in_b_q3   <= in_b_q2;
		hdr_en_q3 <= hdr_en_q2;
	end
`elsif SYNTH_ASIC
	(* max_fanout = 16 *) reg [9:0] r_idx_q, g_idx_q, b_idx_q;
	reg [9:0] in_r_q3, in_g_q3, in_b_q3;
	reg hdr_en_q3;
	always @(posedge pclk) begin
		r_idx_q   <= r_idx;
		g_idx_q   <= g_idx;
		b_idx_q   <= b_idx;
		in_r_q3   <= in_r_q2;
		in_g_q3   <= in_g_q2;
		in_b_q3   <= in_b_q2;
		hdr_en_q3 <= hdr_en_q2;
	end
`endif

	/* SMPTE ST 2084 (PQ) 1024-entry LUT */
	(* rom_style = "distributed" *) reg [9:0] lut [0:1023];
	initial begin
		`include "atg_dc_pq_lut.vh"
	end

	always @(posedge pclk or negedge prst_n) begin
		if (!prst_n) begin
			out_r <= 10'd0;
			out_g <= 10'd0;
			out_b <= 10'd0;
`ifdef SYNTH_KINTEX7
		end else if (!hdr_en_q3) begin
			out_r <= in_r_q3;
			out_g <= in_g_q3;
			out_b <= in_b_q3;
		end else begin
			out_r <= lut[r_idx_q];
			out_g <= lut[g_idx_q];
			out_b <= lut[b_idx_q];
		end
`elsif SYNTH_ASIC
		end else if (!hdr_en_q3) begin
			out_r <= in_r_q3;
			out_g <= in_g_q3;
			out_b <= in_b_q3;
		end else begin
			out_r <= lut[r_idx_q];
			out_g <= lut[g_idx_q];
			out_b <= lut[b_idx_q];
		end
`else
		end else if (!hdr_en) begin
			out_r <= in_r;
			out_g <= in_g;
			out_b <= in_b;
		end else begin
			out_r <= lut[r_idx];
			out_g <= lut[g_idx];
			out_b <= lut[b_idx];
		end
`endif
	end

	wire unused_ok = &{1'b0, co_r_unused, co_g_unused, co_b_unused};
endmodule

`default_nettype wire
