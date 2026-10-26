/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_aniso: Anisotropic filtering unit with Elliptical Weighted Average (EWA)
 * loop (Phase 004 / ws002-p004).
 *
 * Features:
 * - Up to 16x anisotropic filtering ratio.
 * - Computes footprint major/minor axis lengths from partial derivatives (dudx, dudy, dvdx, dvdy).
 * - Generates N = min(ceil(Ratio), max_aniso) bilinear sample coordinates along the major axis.
 * - Gaussian weighting: pre-normalized exact integer weights summing to 65536 (2^16).
 * - Multipliers use am_mul with DSP48E1 internal register latencies (LAT=3 for squaring,
 *   LAT=1 for coordinates and channel accumulation).
 * - Zero raw arithmetic operators outside rtl/library/arith/.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_aniso #(
	parameter MAX_SAMPLES = 16
) (
	input  wire        clk,
	input  wire        rst_n,

	/* Request interface */
	input  wire        req_valid,
	output wire        req_ready,
	input  wire [31:0] dudx,
	input  wire [31:0] dudy,
	input  wire [31:0] dvdx,
	input  wire [31:0] dvdy,
	input  wire [3:0]  max_aniso,	/* 4'd0 = 16x; 4'd1..4'd15 = 1x..15x */

	/* Sample generation interface */
	output wire        samp_valid,
	input  wire        samp_ready,
	output wire [31:0] samp_u,
	output wire [31:0] samp_v,
	output wire [16:0] samp_weight,	/* Q16 pre-normalized weight */

	/* Filtered texel return interface */
	input  wire        filt_valid,
	input  wire [31:0] filt_texel,

	/* Final filtered result */
	output wire        res_valid,
	output wire [31:0] res_texel
);

	`include "atg_tu_fn.vh"

	/* FSM States */
	localparam ST_IDLE = 2'd0;
	localparam ST_EVAL = 2'd1;
	localparam ST_SAMP = 2'd2;
	localparam ST_DONE = 2'd3;

	reg [1:0] st;
	assign req_ready = (st == ST_IDLE);

	/* Request registers */
	reg signed [31:0] dudx_q, dudy_q, dvdx_q, dvdy_q;
	reg [4:0] max_aniso_q;

	/* Major axis coordinates and sample count */
	reg signed [31:0] maj_u_q, maj_v_q;
	reg [4:0] num_samples_q;
	reg [4:0] samp_idx_q;
	reg [4:0] filt_idx_q;
	reg [4:0] acc_cnt_q;
	reg samp_out_valid;
	reg filt_valid_d1;

	/* Evaluation wait counter (LAT=3 multiplier delay + latching) */
	reg [2:0] eval_cnt;
	wire [2:0] eval_cnt_n;
	wire eval_co_unused;
	am_add #(.W(3)) u_add_eval_cnt (
		.a(eval_cnt), .b(3'd0), .ci(1'b1), .s(eval_cnt_n), .co(eval_co_unused)
	);

	/* -------------------------------------------------------------
	 * 1. Vector Length Squared Calculation (LAT=3)
	 * ------------------------------------------------------------- */
	wire [31:0] sq_ux, sq_vx, sq_uy, sq_vy;
	wire [31:0] len_sq_x, len_sq_y;
	wire [1:0] len_co_unused;

	am_mul #(.AW(16), .BW(16), .SIGNED(1), .LAT(3)) u_mul_ux (
		.clk(clk), .en(1'b1), .a(dudx_q[23:8]), .b(dudx_q[23:8]), .p(sq_ux)
	);
	am_mul #(.AW(16), .BW(16), .SIGNED(1), .LAT(3)) u_mul_vx (
		.clk(clk), .en(1'b1), .a(dvdx_q[23:8]), .b(dvdx_q[23:8]), .p(sq_vx)
	);
	am_mul #(.AW(16), .BW(16), .SIGNED(1), .LAT(3)) u_mul_uy (
		.clk(clk), .en(1'b1), .a(dudy_q[23:8]), .b(dudy_q[23:8]), .p(sq_uy)
	);
	am_mul #(.AW(16), .BW(16), .SIGNED(1), .LAT(3)) u_mul_vy (
		.clk(clk), .en(1'b1), .a(dvdy_q[23:8]), .b(dvdy_q[23:8]), .p(sq_vy)
	);

	am_add #(.W(32)) u_add_lx (
		.a(sq_ux), .b(sq_vx), .ci(1'b0), .s(len_sq_x), .co(len_co_unused[0])
	);
	am_add #(.W(32)) u_add_ly (
		.a(sq_uy), .b(sq_vy), .ci(1'b0), .s(len_sq_y), .co(len_co_unused[1])
	);

	/* -------------------------------------------------------------
	 * 2. Major Axis & Ratio Evaluation
	 * ------------------------------------------------------------- */
	wire x_is_maj = (len_sq_x >= len_sq_y);
	wire [31:0] len_sq_maj = x_is_maj ? len_sq_x : len_sq_y;
	wire [31:0] len_sq_min = x_is_maj ? len_sq_y : len_sq_x;

	wire [13:0] l2_maj = tu_l2({1'b0, len_sq_maj});
	wire [13:0] l2_min = tu_l2({1'b0, len_sq_min});
	wire [13:0] delta_l2;
	wire delta_l2_bo;

	am_sub #(.W(14)) u_sub_l2 (
		.a(l2_maj), .b(l2_min), .bi(1'b0), .d(delta_l2), .bo(delta_l2_bo)
	);

	wire [12:0] log_ratio = delta_l2[13:1];	/* 0.5 * delta_l2 */

	function [4:0] eval_n;
		input is_zero_min;
		input is_bo;
		input [12:0] lr;
		begin
			if (is_zero_min)
				eval_n = 5'd16;
			else if (is_bo || lr < 13'd150)
				eval_n = 5'd1;
			else if (lr < 13'd338)
				eval_n = 5'd2;
			else if (lr < 13'd463)
				eval_n = 5'd3;
			else if (lr < 13'd556)
				eval_n = 5'd4;
			else if (lr < 13'd630)
				eval_n = 5'd5;
			else if (lr < 13'd691)
				eval_n = 5'd6;
			else if (lr < 13'd744)
				eval_n = 5'd7;
			else if (lr < 13'd790)
				eval_n = 5'd8;
			else if (lr < 13'd831)
				eval_n = 5'd9;
			else if (lr < 13'd868)
				eval_n = 5'd10;
			else if (lr < 13'd902)
				eval_n = 5'd11;
			else if (lr < 13'd933)
				eval_n = 5'd12;
			else if (lr < 13'd961)
				eval_n = 5'd13;
			else if (lr < 13'd988)
				eval_n = 5'd14;
			else if (lr < 13'd1012)
				eval_n = 5'd15;
			else
				eval_n = 5'd16;
		end
	endfunction

	wire [4:0] raw_n = eval_n(len_sq_min == 32'd0, delta_l2_bo, log_ratio);
	wire [4:0] clamped_n = (raw_n > max_aniso_q) ? max_aniso_q : raw_n;

	/* -------------------------------------------------------------
	 * 3. Sample Offset (t_i) & Gaussian Weight (w_i) Tables
	 * ------------------------------------------------------------- */
	function signed [15:0] sample_t;
		input [4:0] n_samp;
		input [3:0] idx;
		begin
			case (n_samp)
			5'd1: sample_t = 16'sd0;
			5'd2: case (idx)
				4'd0: sample_t = -16'sd16384;
				default: sample_t = 16'sd16384;
				endcase
			5'd3: case (idx)
				4'd0: sample_t = -16'sd21845;
				4'd1: sample_t = 16'sd0;
				default: sample_t = 16'sd21845;
				endcase
			5'd4: case (idx)
				4'd0: sample_t = -16'sd24576;
				4'd1: sample_t = -16'sd8192;
				4'd2: sample_t = 16'sd8192;
				default: sample_t = 16'sd24576;
				endcase
			5'd5: case (idx)
				4'd0: sample_t = -16'sd26214;
				4'd1: sample_t = -16'sd13107;
				4'd2: sample_t = 16'sd0;
				4'd3: sample_t = 16'sd13107;
				default: sample_t = 16'sd26214;
				endcase
			5'd6: case (idx)
				4'd0: sample_t = -16'sd27307;
				4'd1: sample_t = -16'sd16384;
				4'd2: sample_t = -16'sd5461;
				4'd3: sample_t = 16'sd5461;
				4'd4: sample_t = 16'sd16384;
				default: sample_t = 16'sd27307;
				endcase
			5'd7: case (idx)
				4'd0: sample_t = -16'sd28087;
				4'd1: sample_t = -16'sd18725;
				4'd2: sample_t = -16'sd9362;
				4'd3: sample_t = 16'sd0;
				4'd4: sample_t = 16'sd9362;
				4'd5: sample_t = 16'sd18725;
				default: sample_t = 16'sd28087;
				endcase
			5'd8: case (idx)
				4'd0: sample_t = -16'sd28672;
				4'd1: sample_t = -16'sd20480;
				4'd2: sample_t = -16'sd12288;
				4'd3: sample_t = -16'sd4096;
				4'd4: sample_t = 16'sd4096;
				4'd5: sample_t = 16'sd12288;
				4'd6: sample_t = 16'sd20480;
				default: sample_t = 16'sd28672;
				endcase
			5'd9: case (idx)
				4'd0: sample_t = -16'sd29127;
				4'd1: sample_t = -16'sd21845;
				4'd2: sample_t = -16'sd14564;
				4'd3: sample_t = -16'sd7282;
				4'd4: sample_t = 16'sd0;
				4'd5: sample_t = 16'sd7282;
				4'd6: sample_t = 16'sd14564;
				4'd7: sample_t = 16'sd21845;
				default: sample_t = 16'sd29127;
				endcase
			5'd10: case (idx)
				4'd0: sample_t = -16'sd29491;
				4'd1: sample_t = -16'sd22938;
				4'd2: sample_t = -16'sd16384;
				4'd3: sample_t = -16'sd9830;
				4'd4: sample_t = -16'sd3277;
				4'd5: sample_t = 16'sd3277;
				4'd6: sample_t = 16'sd9830;
				4'd7: sample_t = 16'sd16384;
				4'd8: sample_t = 16'sd22938;
				default: sample_t = 16'sd29491;
				endcase
			5'd11: case (idx)
				4'd0: sample_t = -16'sd29789;
				4'd1: sample_t = -16'sd23831;
				4'd2: sample_t = -16'sd17873;
				4'd3: sample_t = -16'sd11916;
				4'd4: sample_t = -16'sd5958;
				4'd5: sample_t = 16'sd0;
				4'd6: sample_t = 16'sd5958;
				4'd7: sample_t = 16'sd11916;
				4'd8: sample_t = 16'sd17873;
				4'd9: sample_t = 16'sd23831;
				default: sample_t = 16'sd29789;
				endcase
			5'd12: case (idx)
				4'd0: sample_t = -16'sd30037;
				4'd1: sample_t = -16'sd24576;
				4'd2: sample_t = -16'sd19115;
				4'd3: sample_t = -16'sd13653;
				4'd4: sample_t = -16'sd8192;
				4'd5: sample_t = -16'sd2731;
				4'd6: sample_t = 16'sd2731;
				4'd7: sample_t = 16'sd8192;
				4'd8: sample_t = 16'sd13653;
				4'd9: sample_t = 16'sd19115;
				4'd10: sample_t = 16'sd24576;
				default: sample_t = 16'sd30037;
				endcase
			5'd13: case (idx)
				4'd0: sample_t = -16'sd30247;
				4'd1: sample_t = -16'sd25206;
				4'd2: sample_t = -16'sd20165;
				4'd3: sample_t = -16'sd15124;
				4'd4: sample_t = -16'sd10082;
				4'd5: sample_t = -16'sd5041;
				4'd6: sample_t = 16'sd0;
				4'd7: sample_t = 16'sd5041;
				4'd8: sample_t = 16'sd10082;
				4'd9: sample_t = 16'sd15124;
				4'd10: sample_t = 16'sd20165;
				4'd11: sample_t = 16'sd25206;
				default: sample_t = 16'sd30247;
				endcase
			5'd14: case (idx)
				4'd0: sample_t = -16'sd30427;
				4'd1: sample_t = -16'sd25746;
				4'd2: sample_t = -16'sd21065;
				4'd3: sample_t = -16'sd16384;
				4'd4: sample_t = -16'sd11703;
				4'd5: sample_t = -16'sd7022;
				4'd6: sample_t = -16'sd2341;
				4'd7: sample_t = 16'sd2341;
				4'd8: sample_t = 16'sd7022;
				4'd9: sample_t = 16'sd11703;
				4'd10: sample_t = 16'sd16384;
				4'd11: sample_t = 16'sd21065;
				4'd12: sample_t = 16'sd25746;
				default: sample_t = 16'sd30427;
				endcase
			5'd15: case (idx)
				4'd0: sample_t = -16'sd30583;
				4'd1: sample_t = -16'sd26214;
				4'd2: sample_t = -16'sd21845;
				4'd3: sample_t = -16'sd17476;
				4'd4: sample_t = -16'sd13107;
				4'd5: sample_t = -16'sd8738;
				4'd6: sample_t = -16'sd4369;
				4'd7: sample_t = 16'sd0;
				4'd8: sample_t = 16'sd4369;
				4'd9: sample_t = 16'sd8738;
				4'd10: sample_t = 16'sd13107;
				4'd11: sample_t = 16'sd17476;
				4'd12: sample_t = 16'sd21845;
				4'd13: sample_t = 16'sd26214;
				default: sample_t = 16'sd30583;
				endcase
			default: case (idx)
				4'd0: sample_t = -16'sd30720;
				4'd1: sample_t = -16'sd26624;
				4'd2: sample_t = -16'sd22528;
				4'd3: sample_t = -16'sd18432;
				4'd4: sample_t = -16'sd14336;
				4'd5: sample_t = -16'sd10240;
				4'd6: sample_t = -16'sd6144;
				4'd7: sample_t = -16'sd2048;
				4'd8: sample_t = 16'sd2048;
				4'd9: sample_t = 16'sd6144;
				4'd10: sample_t = 16'sd10240;
				4'd11: sample_t = 16'sd14336;
				4'd12: sample_t = 16'sd18432;
				4'd13: sample_t = 16'sd22528;
				4'd14: sample_t = 16'sd26624;
				default: sample_t = 16'sd30720;
				endcase
			endcase
		end
	endfunction
	/* verilator lint_on WIDTHEXPAND */

	/* verilator lint_off WIDTHEXPAND */
	function [16:0] sample_w;
		input [4:0] n_samp;
		input [3:0] idx;
		begin
			case (n_samp)
			5'd1: case (idx)
				default: sample_w = 17'd65536;
				endcase
			5'd2: case (idx)
				default: sample_w = 17'd32768;
				endcase
			5'd3: case (idx)
				4'd0, 4'd2: sample_w = 17'd20172;
				default: sample_w = 17'd25192;
				endcase
			5'd4: case (idx)
				4'd0, 4'd3: sample_w = 17'd14347;
				4'd1, 4'd2: sample_w = 17'd18421;
				default: sample_w = 17'd18421;
				endcase
			5'd5: case (idx)
				4'd0, 4'd4: sample_w = 17'd11071;
				4'd1, 4'd3: sample_w = 17'd14074;
				default: sample_w = 17'd15246;
				endcase
			5'd6: case (idx)
				4'd0, 4'd5: sample_w = 17'd8991;
				4'd1, 4'd4: sample_w = 17'd11229;
				4'd2, 4'd3: sample_w = 17'd12548;
				default: sample_w = 17'd12548;
				endcase
			5'd7: case (idx)
				4'd0, 4'd6: sample_w = 17'd7560;
				4'd1, 4'd5: sample_w = 17'd9271;
				4'd2, 4'd4: sample_w = 17'd10479;
				default: sample_w = 17'd10916;
				endcase
			5'd8: case (idx)
				4'd0, 4'd7: sample_w = 17'd6517;
				4'd1, 4'd6: sample_w = 17'd7861;
				4'd2, 4'd5: sample_w = 17'd8908;
				4'd3, 4'd4: sample_w = 17'd9482;
				default: sample_w = 17'd9482;
				endcase
			5'd9: case (idx)
				4'd0, 4'd8: sample_w = 17'd5725;
				4'd1, 4'd7: sample_w = 17'd6805;
				4'd2, 4'd6: sample_w = 17'd7699;
				4'd3, 4'd5: sample_w = 17'd8291;
				default: sample_w = 17'd8496;
				endcase
			5'd10: case (idx)
				4'd0, 4'd9: sample_w = 17'd5103;
				4'd1, 4'd8: sample_w = 17'd5988;
				4'd2, 4'd7: sample_w = 17'd6751;
				4'd3, 4'd6: sample_w = 17'd7314;
				4'd4, 4'd5: sample_w = 17'd7612;
				default: sample_w = 17'd7612;
				endcase
			5'd11: case (idx)
				4'd0, 4'd10: sample_w = 17'd4602;
				4'd1, 4'd9: sample_w = 17'd5340;
				4'd2, 4'd8: sample_w = 17'd5995;
				4'd3, 4'd7: sample_w = 17'd6511;
				4'd4, 4'd6: sample_w = 17'd6842;
				default: sample_w = 17'd6956;
				endcase
			5'd12: case (idx)
				4'd0, 4'd11: sample_w = 17'd4190;
				4'd1, 4'd10: sample_w = 17'd4814;
				4'd2, 4'd9: sample_w = 17'd5380;
				4'd3, 4'd8: sample_w = 17'd5847;
				4'd4, 4'd7: sample_w = 17'd6181;
				4'd5, 4'd6: sample_w = 17'd6356;
				default: sample_w = 17'd6356;
				endcase
			5'd13: case (idx)
				4'd0, 4'd12: sample_w = 17'd3845;
				4'd1, 4'd11: sample_w = 17'd4380;
				4'd2, 4'd10: sample_w = 17'd4872;
				4'd3, 4'd9: sample_w = 17'd5293;
				4'd4, 4'd8: sample_w = 17'd5616;
				4'd5, 4'd7: sample_w = 17'd5818;
				default: sample_w = 17'd5888;
				endcase
			5'd14: case (idx)
				4'd0, 4'd13: sample_w = 17'd3553;
				4'd1, 4'd12: sample_w = 17'd4016;
				4'd2, 4'd11: sample_w = 17'd4447;
				4'd3, 4'd10: sample_w = 17'd4825;
				4'd4, 4'd9: sample_w = 17'd5130;
				4'd5, 4'd8: sample_w = 17'd5344;
				4'd6, 4'd7: sample_w = 17'd5453;
				default: sample_w = 17'd5453;
				endcase
			5'd15: case (idx)
				4'd0, 4'd14: sample_w = 17'd3302;
				4'd1, 4'd13: sample_w = 17'd3706;
				4'd2, 4'd12: sample_w = 17'd4087;
				4'd3, 4'd11: sample_w = 17'd4427;
				4'd4, 4'd10: sample_w = 17'd4711;
				4'd5, 4'd9: sample_w = 17'd4925;
				4'd6, 4'd8: sample_w = 17'd5058;
				default: sample_w = 17'd5104;
				endcase
			default: case (idx)
				4'd0, 4'd15: sample_w = 17'd3083;
				4'd1, 4'd14: sample_w = 17'd3440;
				4'd2, 4'd13: sample_w = 17'd3778;
				4'd3, 4'd12: sample_w = 17'd4085;
				4'd4, 4'd11: sample_w = 17'd4348;
				4'd5, 4'd10: sample_w = 17'd4557;
				4'd6, 4'd9: sample_w = 17'd4702;
				4'd7, 4'd8: sample_w = 17'd4775;
				default: sample_w = 17'd4775;
				endcase
			endcase
		end
	endfunction
	/* verilator lint_on WIDTHEXPAND */

	/* -------------------------------------------------------------
	 * 4. Sample Coordinate Generation (LAT=1)
	 * ------------------------------------------------------------- */
	wire [4:0] samp_idx_n;
	wire [1:0] idx_co_unused;
	am_add #(.W(5)) u_add_samp_idx (
		.a(samp_idx_q), .b(5'd0), .ci(1'b1), .s(samp_idx_n), .co(idx_co_unused[0])
	);

	wire samp_fire = samp_valid && samp_ready;
	wire [3:0] mul_su_idx = (st == ST_EVAL) ? 4'd0 :
		(samp_fire ? samp_idx_n[3:0] : samp_idx_q[3:0]);
	wire signed [15:0] cur_samp_t = sample_t(num_samples_q, mul_su_idx);
	wire [47:0] prod_su, prod_sv;

	wire samp_mul_en = (st == ST_EVAL && eval_cnt == 3'd4) || (st == ST_SAMP && samp_ready);

	am_mul #(.AW(16), .BW(32), .SIGNED(1), .LAT(1)) u_mul_su (
		.clk(clk), .en(samp_mul_en), .a(cur_samp_t), .b(maj_u_q), .p(prod_su)
	);
	am_mul #(.AW(16), .BW(32), .SIGNED(1), .LAT(1)) u_mul_sv (
		.clk(clk), .en(samp_mul_en), .a(cur_samp_t), .b(maj_v_q), .p(prod_sv)
	);

	assign samp_u = prod_su[47:16];
	assign samp_v = prod_sv[47:16];
	assign samp_weight = sample_w(num_samples_q, samp_idx_q[3:0]);
	assign samp_valid = samp_out_valid;

	/* -------------------------------------------------------------
	 * 5. Texel Accumulation (LAT=1)
	 * ------------------------------------------------------------- */
	wire [4:0] filt_idx_n;
	am_add #(.W(5)) u_add_filt_idx (
		.a(filt_idx_q), .b(5'd0), .ci(1'b1), .s(filt_idx_n), .co(idx_co_unused[1])
	);

	wire [4:0] acc_cnt_n;
	wire acc_cnt_co_unused;
	am_add #(.W(5)) u_add_acc_cnt (
		.a(acc_cnt_q), .b(5'd0), .ci(1'b1), .s(acc_cnt_n), .co(acc_cnt_co_unused)
	);

	wire [16:0] cur_filt_w = sample_w(num_samples_q, filt_idx_q[3:0]);
	wire [24:0] prod_r, prod_g, prod_b, prod_a;

	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_mul_acc_r (
		.clk(clk), .en(1'b1), .a(filt_texel[7:0]), .b(cur_filt_w), .p(prod_r)
	);
	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_mul_acc_g (
		.clk(clk), .en(1'b1), .a(filt_texel[15:8]), .b(cur_filt_w), .p(prod_g)
	);
	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_mul_acc_b (
		.clk(clk), .en(1'b1), .a(filt_texel[23:16]), .b(cur_filt_w), .p(prod_b)
	);
	am_mul #(.AW(8), .BW(17), .SIGNED(0), .LAT(1)) u_mul_acc_a (
		.clk(clk), .en(1'b1), .a(filt_texel[31:24]), .b(cur_filt_w), .p(prod_a)
	);

	reg [24:0] acc_r, acc_g, acc_b, acc_a;
	wire [24:0] acc_r_n, acc_g_n, acc_b_n, acc_a_n;
	wire [3:0] acc_co_unused;

	am_add #(.W(25)) u_add_acc_r (
		.a(acc_r), .b(prod_r), .ci(1'b0), .s(acc_r_n), .co(acc_co_unused[0])
	);
	am_add #(.W(25)) u_add_acc_g (
		.a(acc_g), .b(prod_g), .ci(1'b0), .s(acc_g_n), .co(acc_co_unused[1])
	);
	am_add #(.W(25)) u_add_acc_b (
		.a(acc_b), .b(prod_b), .ci(1'b0), .s(acc_b_n), .co(acc_co_unused[2])
	);
	am_add #(.W(25)) u_add_acc_a (
		.a(acc_a), .b(prod_a), .ci(1'b0), .s(acc_a_n), .co(acc_co_unused[3])
	);

	assign res_valid = (st == ST_DONE);
	assign res_texel = {acc_a[23:16], acc_b[23:16], acc_g[23:16], acc_r[23:16]};

	/* -------------------------------------------------------------
	 * 6. Main State Machine
	 * ------------------------------------------------------------- */
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= ST_IDLE;
			eval_cnt <= 3'd0;
			dudx_q <= 32'd0;
			dudy_q <= 32'd0;
			dvdx_q <= 32'd0;
			dvdy_q <= 32'd0;
			max_aniso_q <= 5'd1;
			maj_u_q <= 32'd0;
			maj_v_q <= 32'd0;
			num_samples_q <= 5'd1;
			samp_idx_q <= 5'd0;
			filt_idx_q <= 5'd0;
			acc_cnt_q <= 5'd0;
			samp_out_valid <= 1'b0;
			filt_valid_d1 <= 1'b0;
			acc_r <= 25'd0;
			acc_g <= 25'd0;
			acc_b <= 25'd0;
			acc_a <= 25'd0;
		end else begin
			case (st)
			ST_IDLE: begin
				eval_cnt <= 3'd0;
				samp_out_valid <= 1'b0;
				filt_valid_d1 <= 1'b0;
				if (req_valid) begin
					dudx_q <= dudx;
					dudy_q <= dudy;
					dvdx_q <= dvdx;
					dvdy_q <= dvdy;
					max_aniso_q <= (max_aniso == 4'd0) ? 5'd16 : {1'b0, max_aniso};
					st <= ST_EVAL;
				end
			end

			ST_EVAL: begin
				eval_cnt <= eval_cnt_n;
				if (eval_cnt == 3'd3) begin
					/* sq_ux/vx/uy/vy valid: latch major axis and clamped sample count */
					maj_u_q <= x_is_maj ? dudx_q : dudy_q;
					maj_v_q <= x_is_maj ? dvdx_q : dvdy_q;
					num_samples_q <= clamped_n;
				end else if (eval_cnt == 3'd4) begin
					/* cur_samp_t for sample 0 clocked into u_mul_su/sv PREG */
					samp_idx_q <= 5'd0;
					filt_idx_q <= 5'd0;
					acc_cnt_q <= 5'd0;
					samp_out_valid <= 1'b1;
					filt_valid_d1 <= 1'b0;
					acc_r <= 25'd0;
					acc_g <= 25'd0;
					acc_b <= 25'd0;
					acc_a <= 25'd0;
					st <= ST_SAMP;
				end
			end

			ST_SAMP: begin
				/* Sample generation tracking */
				if (samp_fire) begin
					if (samp_idx_n == num_samples_q)
						samp_out_valid <= 1'b0;
					else
						samp_idx_q <= samp_idx_n;
				end

				/* Filtered texel accumulation pipeline */
				filt_valid_d1 <= filt_valid;
				if (filt_valid) begin
					filt_idx_q <= filt_idx_n;
				end

				if (filt_valid_d1) begin
					acc_r <= acc_r_n;
					acc_g <= acc_g_n;
					acc_b <= acc_b_n;
					acc_a <= acc_a_n;
					acc_cnt_q <= acc_cnt_n;
					if (acc_cnt_n == num_samples_q)
						st <= ST_DONE;
				end
			end

			ST_DONE: begin
				st <= ST_IDLE;
			end

			default: st <= ST_IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, len_co_unused, acc_co_unused, idx_co_unused,
		eval_co_unused, acc_cnt_co_unused,
		prod_su[15:0], prod_sv[15:0], dudx_q[31:24], dudx_q[7:0],
		dvdx_q[31:24], dvdx_q[7:0], dudy_q[31:24], dudy_q[7:0],
		dvdy_q[31:24], dvdy_q[7:0]};

endmodule

`default_nettype wire
