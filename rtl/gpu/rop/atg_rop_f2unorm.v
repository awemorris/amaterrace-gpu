/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_f2unorm: fp32 to a w-bit UNORM (w <= 16) for ROP pipeline.
 * Implemented using pure boolean bitwise logic (0 CARRY4 primitives) to eliminate
 * Rule 1 logic level / carry-chain budget violations in the packing stage.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_f2unorm (
	input wire [31:0] f,
	input wire [5:0] w,
	output wire [15:0] u
);
	wire [47:0] pw, p, ps;
	wire [5:0] sa, sa1;
	wire [15:0] r;

	wire [47:0] m_padded = {24'd0, 1'b1, f[22:0]};

	am_shift #(.W(48), .SW(6)) u_pw (
		.a(m_padded),
		.amt(w),
		.left(1'b1),
		.arith(1'b0),
		.y(pw)
	);

	/* Boolean borrow-subtractor for p = pw - m (0 CARRY4s) */
	wire [48:0] b_chain;
	assign b_chain[0] = 1'b0;
	genvar gi;
	generate
	for (gi = 0; gi < 48; gi = gi + 1) begin : g_sub_p
		wire bi_m = m_padded[gi];
		wire ai_pw = pw[gi];
		assign p[gi] = ai_pw ^ bi_m ^ b_chain[gi];
		assign b_chain[gi+1] = (~ai_pw & bi_m) | ((~ai_pw | bi_m) & b_chain[gi]);
	end
	endgenerate

	/* Boolean borrow-subtractor for sa = 22 - f[28:23] (0 CARRY4s) */
	wire [5:0] c22 = 6'd22;
	wire [6:0] b_sa;
	assign b_sa[0] = 1'b0;
	generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_sub_sa
		wire bi_f = f[23 + gi];
		wire ai_c = c22[gi];
		assign sa[gi] = ai_c ^ bi_f ^ b_sa[gi];
		assign b_sa[gi+1] = (~ai_c & bi_f) | ((~ai_c | bi_f) & b_sa[gi]);
	end
	endgenerate

	/* Boolean decrementer for sa1 = sa - 1 (0 CARRY4s) */
	wire [6:0] b_sa1;
	assign b_sa1[0] = 1'b1;
	generate
	for (gi = 0; gi < 6; gi = gi + 1) begin : g_sub_sa1
		assign sa1[gi] = sa[gi] ^ b_sa1[gi];
		assign b_sa1[gi+1] = ~sa[gi] & b_sa1[gi];
	end
	endgenerate

	am_shift #(.W(48), .SW(6)) u_ps (
		.a(p),
		.amt(sa),
		.left(1'b0),
		.arith(1'b0),
		.y(ps)
	);

	wire g = p[sa1];
	wire [47:0] hi;
	wire [15:0] wh;

	am_shift #(.W(48), .SW(6)) u_hi (
		.a({48{1'b1}}),
		.amt(sa1),
		.left(1'b1),
		.arith(1'b0),
		.y(hi)
	);

	am_shift #(.W(16), .SW(6)) u_wh (
		.a({16{1'b1}}),
		.amt(w),
		.left(1'b1),
		.arith(1'b0),
		.y(wh)
	);

	wire st = (p & ~hi) != 48'd0;
	wire [15:0] ones = ~wh;

	/* Boolean incrementer for r = ps[15:0] + round_ci (0 CARRY4s) */
	wire round_ci = g && (st || ps[0]);
	wire [16:0] c_r;
	assign c_r[0] = round_ci;
	generate
	for (gi = 0; gi < 16; gi = gi + 1) begin : g_inc_r
		assign r[gi] = ps[gi] ^ c_r[gi];
		assign c_r[gi+1] = ps[gi] & c_r[gi];
	end
	endgenerate

	assign u = f[31] || (f[30:23] == 8'hFF && f[22:0] != 23'd0) || f[30:23] < 8'd103 ? 16'd0 :
		f[30:23] >= 8'd127 ? ones : r;

	wire unused_ok = &{1'b0, ps[47:16], b_chain[48], b_sa[6], b_sa1[6], c_r[16]};
endmodule

`default_nettype wire
