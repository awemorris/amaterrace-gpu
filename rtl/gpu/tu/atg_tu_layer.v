/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_layer: Vulkan's layer clamp(RNE(f), 0, cnt − 1); NaN, zeros,
 * denormals and negative values give 0 (the former function tu_layer of
 * include/atg_tu_fn.vh; tools/tumodel.py rne_layer).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_layer #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	input wire [15:0] cnt,
	output wire [15:0] l
);
	wire rst_inv = !rst_n;

	/* k = 150 - e: for 1 <= k <= 24, 1.f >> k, the remainder and half the step */
	wire [8:0] k_s0;
	wire [23:0] qs;
	wire [24:0] tv;
	wire [15:0] c1;
	wire [2:0] carry_unused;
	am_sub #(.W(9)) u_k (.a(9'd150), .b({1'b0, f[30:23]}), .bi(1'b0), .d(k_s0), .bo(carry_unused[0]));
	wire kin_s0 = !k_s0[8] && k_s0 >= 9'd1 && k_s0 <= 9'd24;

	/* Stage 0A -> Stage 0B Pipeline Registers (when LAT >= 3) */
	(* equivalent_register_removal = "no", max_fanout = 12 *) reg [8:0]  r0_k, r0_k_rb, r0_k_sb;
	(* keep = "true", equivalent_register_removal = "no" *) reg        r0_kin_q_lo, r0_kin_q_hi, r0_kin_rb, r0_kin_sb;
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r0_f;
	always @(posedge clk) begin
		if (rst_inv) begin
			r0_k        <= 9'd0;
			r0_k_rb     <= 9'd0;
			r0_k_sb     <= 9'd0;
			r0_kin_q_lo <= 1'b0;
			r0_kin_q_hi <= 1'b0;
			r0_kin_rb   <= 1'b0;
			r0_kin_sb   <= 1'b0;
			r0_f        <= 32'd0;
		end else if (en) begin
			r0_k        <= k_s0;
			r0_k_rb     <= k_s0;
			r0_k_sb     <= k_s0;
			r0_kin_q_lo <= kin_s0;
			r0_kin_q_hi <= kin_s0;
			r0_kin_rb   <= kin_s0;
			r0_kin_sb   <= kin_s0;
			r0_f        <= f;
		end
	end

	wire [8:0]  k        = (LAT >= 3) ? r0_k        : k_s0;
	wire [8:0]  k_rb     = (LAT >= 3) ? r0_k_rb     : k_s0;
	wire [8:0]  k_sb     = (LAT >= 3) ? r0_k_sb     : k_s0;
	wire        kin_q_lo = (LAT >= 3) ? r0_kin_q_lo : kin_s0;
	wire        kin_q_hi = (LAT >= 3) ? r0_kin_q_hi : kin_s0;
	wire        kin_rb   = (LAT >= 3) ? r0_kin_rb   : kin_s0;
	wire        kin_sb   = (LAT >= 3) ? r0_kin_sb   : kin_s0;
	wire [31:0] f_s      = (LAT >= 3) ? r0_f        : f;

	am_shift #(.W(24), .SW(5)) u_qs (.a({1'b1, f_s[22:0]}), .amt(k[4:0]), .left(1'b0), .arith(1'b0),
		.y(qs));
	wire [11:0] q_lo = kin_q_lo ? qs[11:0]  : 12'd0;
	wire [11:0] q_hi = kin_q_hi ? qs[23:12] : 12'd0;
	wire [23:0] q = {q_hi, q_lo};
	reg round_bit, sticky_bit;
	integer b;
	always @(*) begin
		round_bit = 1'b0;
		sticky_bit = 1'b0;
		for (b = 0; b < 24; b = b + 1) begin
			if (kin_rb && b + 1 == {23'd0, k_rb})
				round_bit = (b == 23 || f_s[b]);
			if (kin_sb && b + 1 < {23'd0, k_sb} && (b == 23 || f_s[b]))
				sticky_bit = 1'b1;
		end
	end

	/* Pipeline register when LAT >= 1 */
	(* keep = "true", equivalent_register_removal = "no" *) reg [23:0] r_q;
	(* keep = "true", equivalent_register_removal = "no" *) reg        r_round_bit, r_sticky_bit;
	(* keep = "true", equivalent_register_removal = "no" *) reg [8:0]  r_k;
	(* keep = "true", equivalent_register_removal = "no" *) reg [15:0] r_cnt;
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r_f;

	always @(posedge clk) begin
		if (rst_inv) begin
			r_q          <= 24'd0;
			r_round_bit  <= 1'b0;
			r_sticky_bit <= 1'b0;
			r_k          <= 9'd0;
			r_cnt        <= 16'd0;
			r_f          <= 32'd0;
		end else if (en) begin
			r_q          <= q;
			r_round_bit  <= round_bit;
			r_sticky_bit <= sticky_bit;
			r_k          <= k;
			r_cnt        <= cnt;
			r_f          <= f_s;
		end
	end

	wire [23:0] s1_q          = (LAT >= 1) ? r_q          : q;
	wire        s1_round_bit  = (LAT >= 1) ? r_round_bit  : round_bit;
	wire        s1_sticky_bit = (LAT >= 1) ? r_sticky_bit : sticky_bit;
	wire [8:0]  s1_k          = (LAT >= 1) ? r_k          : k;
	wire [15:0] s1_cnt        = (LAT >= 1) ? r_cnt        : cnt;
	wire [31:0] s1_f          = (LAT >= 1) ? r_f          : f_s;

	wire rnd = s1_round_bit && (s1_sticky_bit || s1_q[0]);
	am_add #(.W(25)) u_tv (.a({1'b0, s1_q}), .b(25'd0), .ci(rnd), .s(tv),
		.co(carry_unused[1]));
	am_sub #(.W(16)) u_c1 (.a(s1_cnt), .b(16'd0), .bi(1'b1), .d(c1), .bo(carry_unused[2]));

	/* Stage 1 -> Stage 2 Pipeline Registers (when LAT >= 2) */
	reg [24:0] r2_tv;
	reg [15:0] r2_c1;
	reg [15:0] r2_cnt;
	reg        r2_zero_neg;
	reg        r2_k_ovf;
	always @(posedge clk) begin
		if (rst_inv) begin
			r2_tv       <= 25'd0;
			r2_c1       <= 16'd0;
			r2_cnt      <= 16'd0;
			r2_zero_neg <= 1'b0;
			r2_k_ovf    <= 1'b0;
		end else if (en) begin
			r2_tv       <= tv;
			r2_c1       <= c1;
			r2_cnt      <= s1_cnt;
			r2_zero_neg <= (s1_f[30:23] == 8'd0 || (s1_f[30:23] == 8'hFF && s1_f[22:0] != 23'd0) || s1_f[31]);
			r2_k_ovf    <= (s1_k[8] || s1_k == 9'd0);
		end
	end

	wire [24:0] s2_tv       = (LAT >= 2) ? r2_tv       : tv;
	wire [15:0] s2_c1       = (LAT >= 2) ? r2_c1       : c1;
	wire [15:0] s2_cnt      = (LAT >= 2) ? r2_cnt      : s1_cnt;
	wire        s2_zero_neg = (LAT >= 2) ? r2_zero_neg : (s1_f[30:23] == 8'd0 || (s1_f[30:23] == 8'hFF && s1_f[22:0] != 23'd0) || s1_f[31]);
	wire        s2_k_ovf    = (LAT >= 2) ? r2_k_ovf    : (s1_k[8] || s1_k == 9'd0);

	wire [15:0] cmp_d_unused;
	wire        cmp_bo;
	am_sub #(.W(16)) u_cmp (.a(s2_tv[15:0]), .b(s2_cnt), .bi(1'b0), .d(cmp_d_unused), .bo(cmp_bo));
	wire tv_ge_cnt = (s2_tv[24:16] != 9'd0) || !cmp_bo;

	/* Stage 2 -> Stage 3 Pipeline Registers (when LAT >= 3) */
	(* max_fanout = 16 *) reg [15:0] r3_tv;
	(* max_fanout = 16 *) reg [15:0] r3_c1;
	(* max_fanout = 16 *) reg        r3_zero_neg;
	(* max_fanout = 16 *) reg        r3_ovf;
	always @(posedge clk) begin
		if (rst_inv) begin
			r3_tv       <= 16'd0;
			r3_c1       <= 16'd0;
			r3_zero_neg <= 1'b0;
			r3_ovf      <= 1'b0;
		end else if (en) begin
			r3_tv       <= s2_tv[15:0];
			r3_c1       <= s2_c1;
			r3_zero_neg <= s2_zero_neg;
			r3_ovf      <= s2_k_ovf || tv_ge_cnt;
		end
	end

	wire [15:0] s3_tv       = (LAT >= 3) ? r3_tv       : s2_tv[15:0];
	wire [15:0] s3_c1       = (LAT >= 3) ? r3_c1       : s2_c1;
	wire        s3_zero_neg = (LAT >= 3) ? r3_zero_neg : s2_zero_neg;
	wire        s3_ovf      = (LAT >= 3) ? r3_ovf      : (s2_k_ovf || tv_ge_cnt);

	assign l = s3_zero_neg ? 16'd0 : s3_ovf ? s3_c1 : s3_tv;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, unused_lat0, cmp_d_unused};
endmodule

`default_nettype wire
