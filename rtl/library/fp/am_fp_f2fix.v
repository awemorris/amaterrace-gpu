/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_f2fix: converts IEEE 754 fp32 to W-bit fixed-point (F fractional bits).
 * Supports configurable rounding (RNE or truncate), signed/unsigned output,
 * and optional saturation.
 * See spec/library/fp/am_fp_f2fix.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_f2fix #(
	parameter W = 24,           /* output bit width */
	parameter F = 8,            /* fraction bits */
	parameter SIGNED = 1,       /* 1 = signed two's complement, 0 = unsigned */
	parameter ROUND = 1,        /* 1 = round to nearest even (RNE), 0 = truncate */
	parameter SATURATE = 1,     /* 1 = saturate to max/min, 0 = wrap */
	parameter SAT_BITS = 0,     /* saturation bit count (0 = full magnitude W-SIGNED) */
	parameter USE_DSP = 0,      /* 1 = map shifter/internal arithmetic to DSP */
	parameter LAT = 0           /* 0 = combinational, 1 = 1 pipeline stage after shift */
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	output wire [W-1:0] q
);
	localparam [7:0] E_BASE = 127 + W - SIGNED - F;
	localparam [7:0] E_MIN = (127 - F >= 1) ? (127 - F - 1) : 8'd0;
	localparam ACT_SAT_BITS = (SAT_BITS > 0 && SAT_BITS < (W - SIGNED)) ? SAT_BITS : (W - SIGNED);

	wire sign = f[31];
	wire [7:0] exp = f[30:23];
	wire [22:0] mant = f[22:0];

	wire is_nan = (exp == 8'hFF) && (mant != 23'd0);
	wire is_zero = (exp == 8'd0);

	/* Shift distance calculation: direct 1-hot equality decode against constant E_BASE (~3 cmos3). */
	wire sh_lo_bo = (exp[2:0] > E_BASE[2:0]);
	wire sh_hi0_bo_unused = 1'b0;
	wire sh_hi1_bo_unused = 1'b0;

	wire [7:0] oh_lo;
	wire [5:0] oh_hi0, oh_hi1;
	genvar gk;
	generate
		for (gk = 0; gk < 8; gk = gk + 1) begin : g_oh_lo
			localparam [2:0] TGT_LO = E_BASE[2:0] - gk[2:0];
			assign oh_lo[gk] = (exp[2:0] == TGT_LO);
		end
		for (gk = 0; gk < 6; gk = gk + 1) begin : g_oh_hi
			localparam [4:0] TGT_HI0 = E_BASE[7:3] - gk[4:0];
			localparam [4:0] TGT_HI1 = E_BASE[7:3] - 5'd1 - gk[4:0];
			assign oh_hi0[gk] = (exp[7:3] == TGT_HI0);
			assign oh_hi1[gk] = (exp[7:3] == TGT_HI1);
		end
	endgenerate
	wire [5:0] oh_hi = sh_lo_bo ? oh_hi1 : oh_hi0;

	/* Stage 0a: fine right shift 0..7 across [47:17] (bits [16:0] are always 0) */
	wire [37:0] sh_pad = {7'd0, 1'b1, mant, 7'd0};
	wire [30:0] sh1;
	genvar gb;
	generate
		for (gb = 0; gb < 31; gb = gb + 1) begin : g_sh_lo
			wire lo4 = |(oh_lo[3:0] & sh_pad[gb +: 4]);
			wire hi4 = |(oh_lo[7:4] & sh_pad[gb + 4 +: 4]);
			assign sh1[gb] = lo4 || hi4;
		end
	endgenerate

	/* Stage 0b: coarse right shift 0, 8, 16, 24, 32, 40 (>= 48 yields 0) */
	wire [47:0] shifted_comb;
	genvar gm;
	generate
		for (gb = 0; gb < 48; gb = gb + 1) begin : g_sh_hi
			wire [5:0] term;
			for (gm = 0; gm < 6; gm = gm + 1) begin : g_m
				localparam integer SRC = gb + 8 * gm;
				if (SRC >= 17 && SRC <= 47) begin : g_in
					assign term[gm] = oh_hi[gm] && sh1[SRC - 17];
				end else begin : g_z
					assign term[gm] = 1'b0;
				end
			end
			assign shifted_comb[gb] = |term;
		end
	endgenerate

	/* Pipeline register stage (LAT = 1) */
	reg [47:0] r_shifted;
	reg [7:0]  r_exp;
	reg        r_sign;
	reg        r_is_nan;
	reg        r_is_zero;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			r_shifted <= 48'd0;
			r_exp     <= 8'd0;
			r_sign    <= 1'b0;
			r_is_nan  <= 1'b0;
			r_is_zero <= 1'b0;
		end else if (en) begin
			r_shifted <= shifted_comb;
			r_exp     <= exp;
			r_sign    <= sign;
			r_is_nan  <= is_nan;
			r_is_zero <= is_zero;
		end
	end

	wire [47:0] shifted   = (LAT != 0) ? r_shifted : shifted_comb;
	wire [7:0]  act_exp   = (LAT != 0) ? r_exp     : exp;
	wire        act_sign  = (LAT != 0) ? r_sign    : sign;
	wire        act_nan   = (LAT != 0) ? r_is_nan  : is_nan;
	wire        act_zero  = (LAT != 0) ? r_is_zero : is_zero;

	/* Rounding */
	wire [W-1:0] unrounded = shifted[47:48-W];
	wire guard = (ROUND != 0) ? shifted[47-W] : 1'b0;
	wire sticky = (ROUND != 0) ? (shifted[46-W:0] != 0) : 1'b0;
	wire lsb = unrounded[0];
	wire round_up = (ROUND != 0) ? (guard && (sticky || lsb)) : 1'b0;

	/* Speculative rounding/sign adders run in parallel with sticky/round_up */
	wire [W-1:0] pos_1;
	wire pos_co_unused;
	am_add #(.W(W)) u_pos1 (
		.a(unrounded),
		.b({W{1'b0}}),
		.ci(1'b1),
		.s(pos_1),
		.co(pos_co_unused)
	);

	wire [W-1:0] neg_1;
	wire neg_co_unused;
	generate
		if (SIGNED != 0) begin : g_neg1
			am_add #(.W(W)) u_neg1 (
				.a(~unrounded),
				.b({W{1'b0}}),
				.ci(1'b1),
				.s(neg_1),
				.co(neg_co_unused)
			);
		end else begin : g_no_neg1
			assign neg_1 = {W{1'b0}};
			assign neg_co_unused = 1'b0;
		end
	endgenerate

	wire [W-1:0] pos_res = round_up ? pos_1 : unrounded;
	wire [W-1:0] neg_res = round_up ? ~unrounded : neg_1;
	wire [W-1:0] signed_res = (SIGNED && act_sign) ? neg_res : pos_res;

	/* Saturation limits */
	wire [W-1:0] sat_pos;
	generate
		if (ACT_SAT_BITS >= W) begin : g_sat_pos_full
			assign sat_pos = {W{1'b1}};
		end else begin : g_sat_pos_partial
			assign sat_pos = { {(W - ACT_SAT_BITS){1'b0}}, {ACT_SAT_BITS{1'b1}} };
		end
	endgenerate

	wire [W-1:0] sat_neg;
	wire sn_co_unused;
	generate
		if (SIGNED) begin : g_sat_neg
			am_addsub #(.W(W)) u_sn (
				.a({W{1'b0}}),
				.b(sat_pos),
				.sub(1'b1),
				.s(sat_neg),
				.co(sn_co_unused)
			);
		end else begin : g_nosat_neg
			assign sat_neg = {W{1'b0}};
			assign sn_co_unused = 1'b0;
		end
	endgenerate

	/* Overflow & Underflow detection */
	wire rnd_gt_sat;
	generate
		if (ACT_SAT_BITS >= W) begin : g_no_sat_cmp
			assign rnd_gt_sat = 1'b0;
		end else begin : g_sat_cmp
			assign rnd_gt_sat = (|unrounded[W-1:ACT_SAT_BITS]) ||
				(round_up && (&unrounded[ACT_SAT_BITS-1:0]));
		end
	endgenerate
	wire is_overflow = (act_exp >= E_BASE) || rnd_gt_sat;
	wire is_underflow = (act_exp < E_MIN) || act_zero;

	wire [W-1:0] sat_res = (!SIGNED && act_sign) ? {W{1'b0}} :
		(act_sign ? sat_neg : sat_pos);

	assign q = act_nan || is_underflow ? {W{1'b0}} :
		(SATURATE && is_overflow) ? sat_res : signed_res;

	wire unused_ok = &{1'b0, sh_hi0_bo_unused, sh_hi1_bo_unused, pos_co_unused, neg_co_unused,
		sn_co_unused, clk, rst_n, en, USE_DSP[0]};
endmodule

`default_nettype wire
