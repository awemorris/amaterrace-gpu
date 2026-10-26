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
	parameter SAT_BITS = 0      /* saturation bit count (0 = full magnitude W-SIGNED) */
) (
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

	/* Shift distance calculation: s = E_BASE - exp */
	wire [7:0] shift_amt;
	wire s_bo_unused;
	am_sub #(.W(8)) u_s (.a(E_BASE), .b(exp), .bi(1'b0), .d(shift_amt), .bo(s_bo_unused));

	/* Place 1.mantissa at top of 48-bit word, shift right by shift_amt */
	wire [47:0] shifted;
	am_shift #(.W(48), .SW(8)) u_sh (
		.a({1'b1, mant, 24'd0}),
		.amt(shift_amt),
		.left(1'b0),
		.arith(1'b0),
		.y(shifted)
	);

	/* Rounding */
	wire [W-1:0] unrounded = shifted[47:48-W];
	wire guard = (ROUND != 0) ? shifted[47-W] : 1'b0;
	wire sticky = (ROUND != 0) ? (shifted[46-W:0] != 0 || mant != 23'd0) : 1'b0;
	wire lsb = unrounded[0];
	wire round_up = (ROUND != 0) ? (guard && (sticky || lsb)) : 1'b0;

	wire [W-1:0] rounded;
	wire r_co_unused;
	am_add #(.W(W)) u_rnd (
		.a(unrounded),
		.b({W{1'b0}}),
		.ci(round_up),
		.s(rounded),
		.co(r_co_unused)
	);

	/* Sign conversion */
	wire [W-1:0] signed_res;
	wire rs_co_unused;
	generate
		if (SIGNED) begin : g_sign
			am_addsub #(.W(W)) u_rs (
				.a({W{1'b0}}),
				.b(rounded),
				.sub(sign),
				.s(signed_res),
				.co(rs_co_unused)
			);
		end else begin : g_nosign
			assign signed_res = rounded;
			assign rs_co_unused = 1'b0;
		end
	endgenerate

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
	wire is_overflow = (exp >= E_BASE) || (rounded > sat_pos);
	wire is_underflow = (exp < E_MIN) || is_zero;

	wire [W-1:0] sat_res = (!SIGNED && sign) ? {W{1'b0}} :
		(sign ? sat_neg : sat_pos);

	assign q = is_nan || is_underflow ? {W{1'b0}} :
		(SATURATE && is_overflow) ? sat_res : signed_res;

	wire unused_ok = &{1'b0, s_bo_unused, r_co_unused, rs_co_unused, sn_co_unused};
endmodule

`default_nettype wire
