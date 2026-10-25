/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_wrap: an integer texel coordinate into the level: {border texel,
 * index} by the address mode (0 repeat, 1 mirrored repeat, 2 clamp to
 * edge, 3 clamp to border).  The former functions tu_wrap and tu_mod of
 * include/atg_tu_fn.vh (tools/tumodel.py wrap_idx); i mod p for i in
 * [−9, p + 7]: one correction for p >= 16, a 5-bit remainder (a table of
 * constants) for p < 16.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_wrap (
	input wire signed [23:0] i,
	input wire [15:0] n,
	input wire [1:0] mode,
	output wire [16:0] w
);
	wire lt = i < 0;
	wire ge = i >= $signed({8'd0, n});
	wire [16:0] p = mode[0] ? {n, 1'b0} : {1'b0, n};
	/* p >= 16: i + p, i - p or i */
	wire [16:0] mb;
	wire [4:0] tv;
	wire [16:0] d, dp;
	wire [15:0] mir, n1;
	wire [5:0] carry_unused;
	am_addsub #(.W(17)) u_mb (.a(i[16:0]), .b(p), .sub(!lt), .s(mb), .co(carry_unused[0]));
	wire [16:0] mbig = lt || i >= $signed({7'd0, p}) ? mb : i[16:0];
	/* p < 16: r = (i + 9) mod p, r9 = 9 mod p; r - r9, + p when r < r9 */
	am_add #(.W(5)) u_tv (.a(i[4:0]), .b(5'd9), .ci(1'b0), .s(tv), .co(carry_unused[1]));
	reg [4:0] r, r9;
	integer a, b, t;
	always @(*) begin
		r = 5'd0;
		r9 = 5'd0;
		t = 0;
		for (b = 1; b < 32; b = b + 1)
			if ({27'd0, p[4:0]} == b) begin
				t = 9 % b;
				r9 = t[4:0];
				for (a = 0; a < 32; a = a + 1)
					if ({27'd0, tv} == a)
						begin
							t = a % b;
							r = t[4:0];
						end
			end
	end
	wire unused_t = &{1'b0, t[31:5]};
	am_sub #(.W(17)) u_d (.a({12'd0, r}), .b({12'd0, r9}), .bi(1'b0), .d(d), .bo(carry_unused[2]));
	am_add #(.W(17)) u_dp (.a(d), .b(p), .ci(1'b0), .s(dp), .co(carry_unused[3]));
	wire [16:0] m = p >= 17'd16 ? mbig : r >= r9 ? d : dp;
	/* mirrored: 2 n - 1 - m beyond n; clamps: n - 1 */
	am_sub #(.W(16)) u_mir (.a({n[14:0], 1'b0}), .b(m[15:0]), .bi(1'b1), .d(mir),
		.bo(carry_unused[4]));
	am_sub #(.W(16)) u_n1 (.a(n), .b(16'd0), .bi(1'b1), .d(n1), .bo(carry_unused[5]));
	assign w = mode == 2'd0 ? {1'b0, m[15:0]} : mode == 2'd1 ? {1'b0, m < {1'b0, n} ? m[15:0] : mir} :
		{mode[0] && (lt || ge), lt ? 16'd0 : ge ? n1 : i[15:0]};
endmodule

`default_nettype wire
