/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cube_sc: one of atg_tu_cube's face coordinates before the
 * division (the former function scaled): floor(v 2^(150 - em)) with the
 * sign flipped by neg, clamped to [-3 mm, 3 mm], plus 3 mm: [0, 6 mm]
 * (m3 = 3 mm, computed by the caller once for both coordinates).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_sc (
	input wire [31:0] v,
	input wire neg,
	input wire [7:0] em,
	input wire [26:0] m3,
	output wire [26:0] o
);
	/* sh = e - em: a left shift by sh (0..2), a right shift by k = -sh (1..23) with
	 * the sticky of the bits shifted out, or the clamp */
	wire [8:0] sh, k;
	wire [26:0] qs, qst, r;
	wire [3:0] carry_unused;
	am_sub #(.W(9)) u_sh (.a({1'b0, v[30:23]}), .b({1'b0, em}), .bi(1'b0), .d(sh), .bo(carry_unused[0]));
	am_sub #(.W(9)) u_k (.a(9'd0), .b(sh), .bi(1'b0), .d(k), .bo(carry_unused[1]));
	am_shift #(.W(27), .SW(5)) u_qs (.a({3'd0, 1'b1, v[22:0]}), .amt(sh[8] ? k[4:0] : {3'd0, sh[1:0]}),
		.left(!sh[8]), .arith(1'b0), .y(qs));
	reg [26:0] q;
	reg sticky;
	integer b;
	always @(*) begin
		q = 27'd0;
		sticky = 1'b0;
		if (v[30:23] == 8'd0)
			q = 27'd0;
		else if (!sh[8] && sh > 9'd2)
			q = m3;
		else if (!sh[8])
			q = qs;
		else if (k < 9'd24) begin
			q = qs;
			for (b = 0; b < 24; b = b + 1)
				if (b < k)
					sticky = sticky | (b == 23 ? 1'b1 : v[b]);
		end else
			sticky = 1'b1;
		if (q > m3)
			q = m3;
	end
	/* ng: m3 - q - sticky (0 when q + sticky >= m3); else m3 + q */
	wire ng = v[31] ^ neg;
	am_add #(.W(27)) u_qst (.a(q), .b(27'd0), .ci(sticky), .s(qst), .co(carry_unused[2]));
	am_add #(.W(27)) u_r (.a(m3), .b(ng ? ~q : q), .ci(ng && !sticky), .s(r), .co(carry_unused[3]));
	assign o = v[30:23] == 8'd0 ? m3 : ng && qst >= m3 ? 27'd0 : r;
endmodule

`default_nettype wire
