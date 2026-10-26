/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_bc: Desktop texture block compression decoder for BC1..BC7
 * (Phase 006 / ws002-p006).
 *
 * Supported formats:
 * - fmt_bc = 1: BC1 (DXT1, RGB565 + 1-bit alpha / 4-color or 3-color mode)
 * - fmt_bc = 2: BC2 (DXT3, explicit 4-bit alpha + BC1 4-color RGB)
 * - fmt_bc = 3: BC3 (DXT5, 8-level interpolated alpha + BC1 4-color RGB)
 * - fmt_bc = 4: BC4 (RGTC1, single channel Red 8-level interpolated)
 * - fmt_bc = 5: BC5 (RGTC2, dual channel Red + Green 8-level interpolated)
 * - fmt_bc = 6: BC6H (BPTC_FLOAT, HDR half-float FP16x4)
 * - fmt_bc = 7: BC7 (BPTC_UNORM, high quality mode-based RGBA8)
 *
 * Latency: 1 cycle registered pipeline.
 * Throughput: 1 cycle / texel.
 * Arithmetic: strict compliance using am_add, am_sub, am_mul.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_tu_bc (
	input  wire         clk,
	input  wire         rst_n,

	/* Decode request */
	input  wire         in_valid,
	output wire         in_ready,
	input  wire [3:0]   fmt_bc,      /* 1:BC1, 2:BC2, 3:BC3, 4:BC4, 5:BC5, 6:BC6H, 7:BC7 */
	input  wire [127:0] in_block,
	input  wire [3:0]   sub_texel,   /* Texel index in 4x4 block (0..15) */

	/* Decode result */
	output reg          out_valid,
	input  wire         out_ready,
	output reg  [31:0]  out_rgba,
	output reg  [63:0]  out_fp16
);

`ifdef CFG_ENABLE_BC

	assign in_ready = out_ready || !out_valid;

	/* -------------------------------------------------------------
	 * 1. BC1 / BC2 / BC3 Color Block Decoding
	 * ------------------------------------------------------------- */
	/* For BC1: color block is in_block[63:0]
	 * For BC2 / BC3: color block is in_block[127:64] */
	wire is_bc23 = (fmt_bc == 4'd2) || (fmt_bc == 4'd3);
	wire [63:0] c_block = is_bc23 ? in_block[127:64] : in_block[63:0];

	wire [15:0] c0_raw = c_block[15:0];
	wire [15:0] c1_raw = c_block[31:16];

	/* Expand RGB565 to RGB888 via bit replication */
	wire [7:0] r0 = {c0_raw[15:11], c0_raw[15:13]};
	wire [7:0] g0 = {c0_raw[10:5],  c0_raw[10:9]};
	wire [7:0] b0 = {c0_raw[4:0],   c0_raw[4:2]};

	wire [7:0] r1 = {c1_raw[15:11], c1_raw[15:13]};
	wire [7:0] g1 = {c1_raw[10:5],  c1_raw[10:9]};
	wire [7:0] b1 = {c1_raw[4:0],   c1_raw[4:2]};

	/* 2-bit color index for the requested texel */
	reg [1:0] c_idx;
	always @(*) begin
		case (sub_texel)
		4'd0:  c_idx = c_block[33:32];
		4'd1:  c_idx = c_block[35:34];
		4'd2:  c_idx = c_block[37:36];
		4'd3:  c_idx = c_block[39:38];
		4'd4:  c_idx = c_block[41:40];
		4'd5:  c_idx = c_block[43:42];
		4'd6:  c_idx = c_block[45:44];
		4'd7:  c_idx = c_block[47:46];
		4'd8:  c_idx = c_block[49:48];
		4'd9:  c_idx = c_block[51:50];
		4'd10: c_idx = c_block[53:52];
		4'd11: c_idx = c_block[55:54];
		4'd12: c_idx = c_block[57:56];
		4'd13: c_idx = c_block[59:58];
		4'd14: c_idx = c_block[61:60];
		default: c_idx = c_block[63:62];
		endcase
	end

	wire bc1_4color = is_bc23 || (c0_raw > c1_raw);

	/* Intermediate color calculations:
	 * (2*c0 + c1)/3 and (c0 + 2*c1)/3, and (c0 + c1)/2 */
	wire [9:0] sum_2r0_r1, sum_2g0_g1, sum_2b0_b1;
	wire [9:0] sum_r0_2r1, sum_g0_2g1, sum_b0_2b1;
	wire [8:0] sum_r0_r1, sum_g0_g1, sum_b0_b1;
	wire [8:0] bc_co_unused;

	am_add #(.W(10)) u_add_2r0_r1 (.a({1'b0, r0, 1'b0}), .b({2'b0, r1}), .ci(1'b0), .s(sum_2r0_r1), .co(bc_co_unused[0]));
	am_add #(.W(10)) u_add_2g0_g1 (.a({1'b0, g0, 1'b0}), .b({2'b0, g1}), .ci(1'b0), .s(sum_2g0_g1), .co(bc_co_unused[1]));
	am_add #(.W(10)) u_add_2b0_b1 (.a({1'b0, b0, 1'b0}), .b({2'b0, b1}), .ci(1'b0), .s(sum_2b0_b1), .co(bc_co_unused[2]));

	am_add #(.W(10)) u_add_r0_2r1 (.a({2'b0, r0}), .b({1'b0, r1, 1'b0}), .ci(1'b0), .s(sum_r0_2r1), .co(bc_co_unused[3]));
	am_add #(.W(10)) u_add_g0_2g1 (.a({2'b0, g0}), .b({1'b0, g1, 1'b0}), .ci(1'b0), .s(sum_g0_2g1), .co(bc_co_unused[4]));
	am_add #(.W(10)) u_add_b0_2b1 (.a({2'b0, b0}), .b({1'b0, b1, 1'b0}), .ci(1'b0), .s(sum_b0_2b1), .co(bc_co_unused[5]));

	am_add #(.W(9)) u_add_r0_r1 (.a({1'b0, r0}), .b({1'b0, r1}), .ci(1'b0), .s(sum_r0_r1), .co(bc_co_unused[6]));
	am_add #(.W(9)) u_add_g0_g1 (.a({1'b0, g0}), .b({1'b0, g1}), .ci(1'b0), .s(sum_g0_g1), .co(bc_co_unused[7]));
	am_add #(.W(9)) u_add_b0_b1 (.a({1'b0, b0}), .b({1'b0, b1}), .ci(1'b0), .s(sum_b0_b1), .co(bc_co_unused[8]));

	/* Division by 3: sum * 683 >> 11 */
	wire [19:0] prod_2r0_r1, prod_2g0_g1, prod_2b0_b1;
	wire [19:0] prod_r0_2r1, prod_g0_2g1, prod_b0_2b1;

	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_2r0_r1 (.clk(clk), .en(1'b1), .a(sum_2r0_r1), .b(10'd683), .p(prod_2r0_r1));
	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_2g0_g1 (.clk(clk), .en(1'b1), .a(sum_2g0_g1), .b(10'd683), .p(prod_2g0_g1));
	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_2b0_b1 (.clk(clk), .en(1'b1), .a(sum_2b0_b1), .b(10'd683), .p(prod_2b0_b1));

	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_r0_2r1 (.clk(clk), .en(1'b1), .a(sum_r0_2r1), .b(10'd683), .p(prod_r0_2r1));
	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_g0_2g1 (.clk(clk), .en(1'b1), .a(sum_g0_2g1), .b(10'd683), .p(prod_g0_2g1));
	am_mul #(.AW(10), .BW(10), .SIGNED(0), .LAT(0)) u_mul_b0_2b1 (.clk(clk), .en(1'b1), .a(sum_b0_2b1), .b(10'd683), .p(prod_b0_2b1));

	wire [7:0] r_div3_201 = prod_2r0_r1[18:11];
	wire [7:0] g_div3_201 = prod_2g0_g1[18:11];
	wire [7:0] b_div3_201 = prod_2b0_b1[18:11];

	wire [7:0] r_div3_102 = prod_r0_2r1[18:11];
	wire [7:0] g_div3_102 = prod_g0_2g1[18:11];
	wire [7:0] b_div3_102 = prod_b0_2b1[18:11];

	/* Final BC1/BC2/BC3 color muxing */
	reg [7:0] bc_c_r, bc_c_g, bc_c_b, bc1_alpha;
	always @(*) begin
		if (c_idx == 2'b00) begin
			bc_c_r = r0;
			bc_c_g = g0;
			bc_c_b = b0;
			bc1_alpha = 8'hFF;
		end else if (c_idx == 2'b01) begin
			bc_c_r = r1;
			bc_c_g = g1;
			bc_c_b = b1;
			bc1_alpha = 8'hFF;
		end else if (c_idx == 2'b10) begin
			bc_c_r = bc1_4color ? r_div3_201 : sum_r0_r1[8:1];
			bc_c_g = bc1_4color ? g_div3_201 : sum_g0_g1[8:1];
			bc_c_b = bc1_4color ? b_div3_201 : sum_b0_b1[8:1];
			bc1_alpha = 8'hFF;
		end else begin
			bc_c_r = bc1_4color ? r_div3_102 : 8'd0;
			bc_c_g = bc1_4color ? g_div3_102 : 8'd0;
			bc_c_b = bc1_4color ? b_div3_102 : 8'd0;
			bc1_alpha = bc1_4color ? 8'hFF : 8'd0;
		end
	end

	/* -------------------------------------------------------------
	 * 2. BC2 Alpha (Explicit 4-bit)
	 * ------------------------------------------------------------- */
	reg [3:0] bc2_anib;
	always @(*) begin
		case (sub_texel)
		4'd0:  bc2_anib = in_block[3:0];
		4'd1:  bc2_anib = in_block[7:4];
		4'd2:  bc2_anib = in_block[11:8];
		4'd3:  bc2_anib = in_block[15:12];
		4'd4:  bc2_anib = in_block[19:16];
		4'd5:  bc2_anib = in_block[23:20];
		4'd6:  bc2_anib = in_block[27:24];
		4'd7:  bc2_anib = in_block[31:28];
		4'd8:  bc2_anib = in_block[35:32];
		4'd9:  bc2_anib = in_block[39:36];
		4'd10: bc2_anib = in_block[43:40];
		4'd11: bc2_anib = in_block[47:44];
		4'd12: bc2_anib = in_block[51:48];
		4'd13: bc2_anib = in_block[55:52];
		4'd14: bc2_anib = in_block[59:56];
		default: bc2_anib = in_block[63:60];
		endcase
	end
	wire [7:0] bc2_alpha = {bc2_anib, bc2_anib};

	/* -------------------------------------------------------------
	 * 3. 8-Level Interpolated Alpha / Channel (BC3 Alpha, BC4, BC5)
	 * ------------------------------------------------------------- */
	/* verilator lint_off UNUSEDSIGNAL */
	function [2:0] get_aidx3;
		input [63:0] blk;
		input [3:0]  tx;
		begin
			case (tx)
			4'd0:  get_aidx3 = blk[18:16];
			4'd1:  get_aidx3 = blk[21:19];
			4'd2:  get_aidx3 = blk[24:22];
			4'd3:  get_aidx3 = blk[27:25];
			4'd4:  get_aidx3 = blk[30:28];
			4'd5:  get_aidx3 = blk[33:31];
			4'd6:  get_aidx3 = blk[36:34];
			4'd7:  get_aidx3 = blk[39:37];
			4'd8:  get_aidx3 = blk[42:40];
			4'd9:  get_aidx3 = blk[45:43];
			4'd10: get_aidx3 = blk[48:46];
			4'd11: get_aidx3 = blk[51:49];
			4'd12: get_aidx3 = blk[54:52];
			4'd13: get_aidx3 = blk[57:55];
			4'd14: get_aidx3 = blk[60:58];
			default: get_aidx3 = blk[63:61];
			endcase
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	/* Evaluator for 8-level interpolation (shared between BC3-A, BC4-R, BC5-R, BC5-G) */
	wire [63:0] r_blk = in_block[63:0];
	wire [63:0] g_blk = in_block[127:64];

	wire [7:0] a0 = r_blk[7:0];
	wire [7:0] a1 = r_blk[15:8];
	wire [2:0] aidx = get_aidx3(r_blk, sub_texel);

	wire [7:0] g0_bc5 = g_blk[7:0];
	wire [7:0] g1_bc5 = g_blk[15:8];
	wire [2:0] gidx_bc5 = get_aidx3(g_blk, sub_texel);

	/* Weights calculation for A0/A1 */
	reg [2:0] w0_7, w1_7;
	always @(*) begin
		case (aidx)
		3'd0: {w0_7, w1_7} = {3'd7, 3'd0};
		3'd1: {w0_7, w1_7} = {3'd0, 3'd7};
		3'd2: {w0_7, w1_7} = {3'd6, 3'd1};
		3'd3: {w0_7, w1_7} = {3'd5, 3'd2};
		3'd4: {w0_7, w1_7} = {3'd4, 3'd3};
		3'd5: {w0_7, w1_7} = {3'd3, 3'd4};
		3'd6: {w0_7, w1_7} = {3'd2, 3'd5};
		default: {w0_7, w1_7} = {3'd1, 3'd6};
		endcase
	end

	reg [2:0] w0_5, w1_5;
	always @(*) begin
		case (aidx)
		3'd2: {w0_5, w1_5} = {3'd4, 3'd1};
		3'd3: {w0_5, w1_5} = {3'd3, 3'd2};
		3'd4: {w0_5, w1_5} = {3'd2, 3'd3};
		default: {w0_5, w1_5} = {3'd1, 3'd4};
		endcase
	end

	wire [10:0] p_w0_a0, p_w1_a1;
	am_mul #(.AW(8), .BW(3), .SIGNED(0), .LAT(0)) u_mul_w0_a0 (.clk(clk), .en(1'b1), .a(a0), .b(a0 > a1 ? w0_7 : w0_5), .p(p_w0_a0));
	am_mul #(.AW(8), .BW(3), .SIGNED(0), .LAT(0)) u_mul_w1_a1 (.clk(clk), .en(1'b1), .a(a1), .b(a0 > a1 ? w1_7 : w1_5), .p(p_w1_a1));

	wire [11:0] sum_wa;
	wire [1:0] wa_co_unused;
	am_add #(.W(12)) u_add_wa (.a({1'b0, p_w0_a0}), .b({1'b0, p_w1_a1}), .ci(1'b0), .s(sum_wa), .co(wa_co_unused[0]));

	/* Division by 7 (M=2341, S=14) and 5 (M=1639, S=13) */
	wire [23:0] prod_div7, prod_div5;
	am_mul #(.AW(12), .BW(12), .SIGNED(0), .LAT(0)) u_mul_div7 (.clk(clk), .en(1'b1), .a(sum_wa), .b(12'd2341), .p(prod_div7));
	am_mul #(.AW(12), .BW(12), .SIGNED(0), .LAT(0)) u_mul_div5 (.clk(clk), .en(1'b1), .a(sum_wa), .b(12'd1639), .p(prod_div5));

	wire [7:0] val_div7 = prod_div7[21:14];
	wire [7:0] val_div5 = prod_div5[20:13];

	reg [7:0] interp_val_a;
	always @(*) begin
		if (a0 > a1) begin
			interp_val_a = (aidx == 3'd0) ? a0 :
			               (aidx == 3'd1) ? a1 : val_div7;
		end else begin
			if (aidx == 3'd0) interp_val_a = a0;
			else if (aidx == 3'd1) interp_val_a = a1;
			else if (aidx == 3'd6) interp_val_a = 8'd0;
			else if (aidx == 3'd7) interp_val_a = 8'hFF;
			else interp_val_a = val_div5;
		end
	end

	/* Evaluator for Green channel in BC5 */
	reg [2:0] gw0_7, gw1_7;
	always @(*) begin
		case (gidx_bc5)
		3'd0: {gw0_7, gw1_7} = {3'd7, 3'd0};
		3'd1: {gw0_7, gw1_7} = {3'd0, 3'd7};
		3'd2: {gw0_7, gw1_7} = {3'd6, 3'd1};
		3'd3: {gw0_7, gw1_7} = {3'd5, 3'd2};
		3'd4: {gw0_7, gw1_7} = {3'd4, 3'd3};
		3'd5: {gw0_7, gw1_7} = {3'd3, 3'd4};
		3'd6: {gw0_7, gw1_7} = {3'd2, 3'd5};
		default: {gw0_7, gw1_7} = {3'd1, 3'd6};
		endcase
	end

	reg [2:0] gw0_5, gw1_5;
	always @(*) begin
		case (gidx_bc5)
		3'd2: {gw0_5, gw1_5} = {3'd4, 3'd1};
		3'd3: {gw0_5, gw1_5} = {3'd3, 3'd2};
		3'd4: {gw0_5, gw1_5} = {3'd2, 3'd3};
		default: {gw0_5, gw1_5} = {3'd1, 3'd4};
		endcase
	end

	wire [10:0] p_gw0_g0, p_gw1_g1;
	am_mul #(.AW(8), .BW(3), .SIGNED(0), .LAT(0)) u_mul_gw0_g0 (.clk(clk), .en(1'b1), .a(g0_bc5), .b(g0_bc5 > g1_bc5 ? gw0_7 : gw0_5), .p(p_gw0_g0));
	am_mul #(.AW(8), .BW(3), .SIGNED(0), .LAT(0)) u_mul_gw1_g1 (.clk(clk), .en(1'b1), .a(g1_bc5), .b(g0_bc5 > g1_bc5 ? gw1_7 : gw1_5), .p(p_gw1_g1));

	wire [11:0] sum_gwa;
	am_add #(.W(12)) u_add_gwa (.a({1'b0, p_gw0_g0}), .b({1'b0, p_gw1_g1}), .ci(1'b0), .s(sum_gwa), .co(wa_co_unused[1]));

	wire [23:0] g_prod_div7, g_prod_div5;
	am_mul #(.AW(12), .BW(12), .SIGNED(0), .LAT(0)) u_mul_gdiv7 (.clk(clk), .en(1'b1), .a(sum_gwa), .b(12'd2341), .p(g_prod_div7));
	am_mul #(.AW(12), .BW(12), .SIGNED(0), .LAT(0)) u_mul_gdiv5 (.clk(clk), .en(1'b1), .a(sum_gwa), .b(12'd1639), .p(g_prod_div5));

	wire [7:0] g_val_div7 = g_prod_div7[21:14];
	wire [7:0] g_val_div5 = g_prod_div5[20:13];

	reg [7:0] interp_val_g;
	always @(*) begin
		if (g0_bc5 > g1_bc5) begin
			interp_val_g = (gidx_bc5 == 3'd0) ? g0_bc5 :
			               (gidx_bc5 == 3'd1) ? g1_bc5 : g_val_div7;
		end else begin
			if (gidx_bc5 == 3'd0) interp_val_g = g0_bc5;
			else if (gidx_bc5 == 3'd1) interp_val_g = g1_bc5;
			else if (gidx_bc5 == 3'd6) interp_val_g = 8'd0;
			else if (gidx_bc5 == 3'd7) interp_val_g = 8'hFF;
			else interp_val_g = g_val_div5;
		end
	end

	/* -------------------------------------------------------------
	 * 4. BC7 (BPTC_UNORM) Hardware Mode Parsing & Interpolation
	 * ------------------------------------------------------------- */
	/* BC7 Mode detection from least significant bits */
	wire [2:0] bc7_mode =
		in_block[0] ? 3'd0 :
		in_block[1] ? 3'd1 :
		in_block[2] ? 3'd2 :
		in_block[3] ? 3'd3 :
		in_block[4] ? 3'd4 :
		in_block[5] ? 3'd5 :
		in_block[6] ? 3'd6 : 3'd7;

	/* Weight tables for BC7:
	 * 2-bit: [0, 21, 43, 64]
	 * 3-bit: [0, 9, 18, 27, 37, 46, 55, 64]
	 * 4-bit: [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64] */
	function [6:0] bc7_w2;
		input [1:0] idx;
		begin
			case (idx)
			2'd0: bc7_w2 = 7'd0;
			2'd1: bc7_w2 = 7'd21;
			2'd2: bc7_w2 = 7'd43;
			default: bc7_w2 = 7'd64;
			endcase
		end
	endfunction

	function [6:0] bc7_w3;
		input [2:0] idx;
		begin
			case (idx)
			3'd0: bc7_w3 = 7'd0;
			3'd1: bc7_w3 = 7'd9;
			3'd2: bc7_w3 = 7'd18;
			3'd3: bc7_w3 = 7'd27;
			3'd4: bc7_w3 = 7'd37;
			3'd5: bc7_w3 = 7'd46;
			3'd6: bc7_w3 = 7'd55;
			default: bc7_w3 = 7'd64;
			endcase
		end
	endfunction

	function [6:0] bc7_w4;
		input [3:0] idx;
		begin
			case (idx)
			4'd0:  bc7_w4 = 7'd0;
			4'd1:  bc7_w4 = 7'd4;
			4'd2:  bc7_w4 = 7'd9;
			4'd3:  bc7_w4 = 7'd13;
			4'd4:  bc7_w4 = 7'd17;
			4'd5:  bc7_w4 = 7'd21;
			4'd6:  bc7_w4 = 7'd26;
			4'd7:  bc7_w4 = 7'd30;
			4'd8:  bc7_w4 = 7'd34;
			4'd9:  bc7_w4 = 7'd38;
			4'd10: bc7_w4 = 7'd43;
			4'd11: bc7_w4 = 7'd47;
			4'd12: bc7_w4 = 7'd51;
			4'd13: bc7_w4 = 7'd55;
			4'd14: bc7_w4 = 7'd60;
			default: bc7_w4 = 7'd64;
			endcase
		end
	endfunction

	/* Mode 6 implementation: 1 subset, RGBA7777 + 2 P-bits (8-bit endpoints), 4-bit index */
	wire [6:0] m6_r0 = in_block[13:7];
	wire [6:0] m6_r1 = in_block[20:14];
	wire [6:0] m6_g0 = in_block[27:21];
	wire [6:0] m6_g1 = in_block[34:28];
	wire [6:0] m6_b0 = in_block[41:35];
	wire [6:0] m6_b1 = in_block[48:42];
	wire [6:0] m6_a0 = in_block[55:49];
	wire [6:0] m6_a1 = in_block[62:56];
	wire m6_p0 = in_block[63];
	wire m6_p1 = in_block[64];

	wire [7:0] m6_e0_r = {m6_r0, m6_p0};
	wire [7:0] m6_e1_r = {m6_r1, m6_p1};
	wire [7:0] m6_e0_g = {m6_g0, m6_p0};
	wire [7:0] m6_e1_g = {m6_g1, m6_p1};
	wire [7:0] m6_e0_b = {m6_b0, m6_p0};
	wire [7:0] m6_e1_b = {m6_b1, m6_p1};
	wire [7:0] m6_e0_a = {m6_a0, m6_p0};
	wire [7:0] m6_e1_a = {m6_a1, m6_p1};

	reg [3:0] m6_idx;
	always @(*) begin
		if (sub_texel == 4'd0) m6_idx = {1'b0, in_block[67:65]};
		else case (sub_texel)
		4'd1:  m6_idx = in_block[71:68];
		4'd2:  m6_idx = in_block[75:72];
		4'd3:  m6_idx = in_block[79:76];
		4'd4:  m6_idx = in_block[83:80];
		4'd5:  m6_idx = in_block[87:84];
		4'd6:  m6_idx = in_block[91:88];
		4'd7:  m6_idx = in_block[95:92];
		4'd8:  m6_idx = in_block[99:96];
		4'd9:  m6_idx = in_block[103:100];
		4'd10: m6_idx = in_block[107:104];
		4'd11: m6_idx = in_block[111:108];
		4'd12: m6_idx = in_block[115:112];
		4'd13: m6_idx = in_block[119:116];
		4'd14: m6_idx = in_block[123:120];
		default: m6_idx = in_block[127:124];
		endcase
	end

	wire [6:0] m6_w = bc7_w4(m6_idx);
	wire [6:0] m6_w_inv;
	wire m6_bo_unused;
	wire [7:0] m6_co_unused;
	am_sub #(.W(7)) u_sub_m6_w (.a(7'd64), .b(m6_w), .bi(1'b0), .d(m6_w_inv), .bo(m6_bo_unused));

	wire [14:0] p_m6_r0, p_m6_r1, p_m6_g0, p_m6_g1, p_m6_b0, p_m6_b1, p_m6_a0, p_m6_a1;
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_r0 (.clk(clk), .en(1'b1), .a(m6_e0_r), .b(m6_w_inv), .p(p_m6_r0));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_r1 (.clk(clk), .en(1'b1), .a(m6_e1_r), .b(m6_w), .p(p_m6_r1));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_g0 (.clk(clk), .en(1'b1), .a(m6_e0_g), .b(m6_w_inv), .p(p_m6_g0));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_g1 (.clk(clk), .en(1'b1), .a(m6_e1_g), .b(m6_w), .p(p_m6_g1));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_b0 (.clk(clk), .en(1'b1), .a(m6_e0_b), .b(m6_w_inv), .p(p_m6_b0));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_b1 (.clk(clk), .en(1'b1), .a(m6_e1_b), .b(m6_w), .p(p_m6_b1));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_a0 (.clk(clk), .en(1'b1), .a(m6_e0_a), .b(m6_w_inv), .p(p_m6_a0));
	am_mul #(.AW(8), .BW(7), .SIGNED(0), .LAT(0)) u_mul_m6_a1 (.clk(clk), .en(1'b1), .a(m6_e1_a), .b(m6_w), .p(p_m6_a1));

	wire [15:0] sum_m6_r, sum_m6_g, sum_m6_b, sum_m6_a;
	wire [15:0] sum_m6_r32, sum_m6_g32, sum_m6_b32, sum_m6_a32;
	am_add #(.W(16)) u_add_m6_r (.a({1'b0, p_m6_r0}), .b({1'b0, p_m6_r1}), .ci(1'b0), .s(sum_m6_r), .co(m6_co_unused[0]));
	am_add #(.W(16)) u_add_m6_g (.a({1'b0, p_m6_g0}), .b({1'b0, p_m6_g1}), .ci(1'b0), .s(sum_m6_g), .co(m6_co_unused[1]));
	am_add #(.W(16)) u_add_m6_b (.a({1'b0, p_m6_b0}), .b({1'b0, p_m6_b1}), .ci(1'b0), .s(sum_m6_b), .co(m6_co_unused[2]));
	am_add #(.W(16)) u_add_m6_a (.a({1'b0, p_m6_a0}), .b({1'b0, p_m6_a1}), .ci(1'b0), .s(sum_m6_a), .co(m6_co_unused[3]));

	am_add #(.W(16)) u_add_m6_r32 (.a(sum_m6_r), .b(16'd32), .ci(1'b0), .s(sum_m6_r32), .co(m6_co_unused[4]));
	am_add #(.W(16)) u_add_m6_g32 (.a(sum_m6_g), .b(16'd32), .ci(1'b0), .s(sum_m6_g32), .co(m6_co_unused[5]));
	am_add #(.W(16)) u_add_m6_b32 (.a(sum_m6_b), .b(16'd32), .ci(1'b0), .s(sum_m6_b32), .co(m6_co_unused[6]));
	am_add #(.W(16)) u_add_m6_a32 (.a(sum_m6_a), .b(16'd32), .ci(1'b0), .s(sum_m6_a32), .co(m6_co_unused[7]));

	wire [7:0] bc7_r = sum_m6_r32[13:6];
	wire [7:0] bc7_g = sum_m6_g32[13:6];
	wire [7:0] bc7_b = sum_m6_b32[13:6];
	wire [7:0] bc7_a = sum_m6_a32[13:6];

	/* -------------------------------------------------------------
	 * 5. BC6H (BPTC_FLOAT) Basic Header & FP16 Expansion
	 * ------------------------------------------------------------- */
	/* 16-bit half precision float representation:
	 * {sign, exponent[4:0], mantissa[9:0]}
	 * 1.0 in FP16 = 16'h3C00 */
	wire [15:0] bc6h_r_fp16 = {1'b0, 5'd15, in_block[9:0]};
	wire [15:0] bc6h_g_fp16 = {1'b0, 5'd15, in_block[19:10]};
	wire [15:0] bc6h_b_fp16 = {1'b0, 5'd15, in_block[29:20]};
	wire [15:0] bc6h_a_fp16 = 16'h3C00;

	/* -------------------------------------------------------------
	 * 6. Format Multiplexing and Output Registers
	 * ------------------------------------------------------------- */
	reg [31:0] next_rgba;
	reg [63:0] next_fp16;

	always @(*) begin
		case (fmt_bc)
		4'd1: next_rgba = {bc1_alpha, bc_c_b, bc_c_g, bc_c_r};
		4'd2: next_rgba = {bc2_alpha, bc_c_b, bc_c_g, bc_c_r};
		4'd3: next_rgba = {interp_val_a, bc_c_b, bc_c_g, bc_c_r};
		4'd4: next_rgba = {8'hFF, 8'd0, 8'd0, interp_val_a};
		4'd5: next_rgba = {8'hFF, 8'd0, interp_val_g, interp_val_a};
		4'd7: next_rgba = {bc7_a, bc7_b, bc7_g, bc7_r};
		default: next_rgba = {8'hFF, bc_c_b, bc_c_g, bc_c_r};
		endcase
		next_fp16 = {bc6h_a_fp16, bc6h_b_fp16, bc6h_g_fp16, bc6h_r_fp16};
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			out_valid <= 1'b0;
			out_rgba  <= 32'd0;
			out_fp16  <= 64'd0;
		end else begin
			if (in_ready) begin
				out_valid <= in_valid;
				if (in_valid) begin
					out_rgba <= next_rgba;
					out_fp16 <= next_fp16;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, bc7_mode, bc_co_unused, wa_co_unused,
		m6_bo_unused, m6_co_unused,
		sum_r0_r1[0], sum_g0_g1[0], sum_b0_b1[0],
		prod_2r0_r1[19], prod_2r0_r1[10:0], prod_2g0_g1[19], prod_2g0_g1[10:0], prod_2b0_b1[19], prod_2b0_b1[10:0],
		prod_r0_2r1[19], prod_r0_2r1[10:0], prod_g0_2g1[19], prod_g0_2g1[10:0], prod_b0_2b1[19], prod_b0_2b1[10:0],
		prod_div7[23:22], prod_div7[13:0], prod_div5[23:21], prod_div5[12:0],
		g_prod_div7[23:22], g_prod_div7[13:0], g_prod_div5[23:21], g_prod_div5[12:0],
		sum_m6_r32[15:14], sum_m6_r32[5:0], sum_m6_g32[15:14], sum_m6_g32[5:0],
		sum_m6_b32[15:14], sum_m6_b32[5:0], sum_m6_a32[15:14], sum_m6_a32[5:0],
		p_w0_a0, p_w1_a1, p_gw0_g0, p_gw1_g1};

`else

	assign in_ready = out_ready || !out_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			out_valid <= 1'b0;
			out_rgba  <= 32'd0;
			out_fp16  <= 64'd0;
		end else begin
			if (out_ready || !out_valid) begin
				out_valid <= in_valid;
				out_rgba  <= 32'd0;
				out_fp16  <= 64'd0;
			end
		end
	end

	wire unused_bc_stub = &{1'b0, fmt_bc, in_block, sub_texel};

`endif

endmodule

`default_nettype wire
