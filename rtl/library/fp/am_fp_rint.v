/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_rint: the integer nearest to |x| (x flushed, exponent below 150)
 * under rm (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM, others RNE) and x's sign;
 * n is the magnitude, 25 bits.
 * See spec/library/fp/am_fp_rint.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_rint #(
	/* verilator lint_off UNUSEDPARAM */
	parameter LAT = 0
	/* verilator lint_on UNUSEDPARAM */
) (
	input wire [31:0] x,
	input wire [2:0] rm,
	output wire [24:0] n
);
	wire [23:0] m = {x[30:23] != 8'd0, x[22:0]};
	/* f: the fraction bits, 150 - e (1..150) */
	wire [7:0] f;
	wire [4:0] fm1;
	wire [23:0] q0;
	wire [2:0] carry_unused;
	am_sub #(.W(8)) u_f (.a(8'd150), .b(x[30:23]), .bi(1'b0), .d(f), .bo(carry_unused[0]));
	am_sub #(.W(5)) u_fm1 (.a(f[4:0]), .b(5'd1), .bi(1'b0), .d(fm1), .bo(carry_unused[1]));
	am_shift #(.W(24), .SW(5)) u_q (.a(m), .amt(f[4:0]), .left(1'b0), .arith(1'b0), .y(q0));
	wire [23:0] q = f >= 8'd24 ? 24'd0 : q0;
	wire g = f > 8'd24 ? 1'b0 : m[fm1];
	/* the sticky bit: the bits of m below f - 1 (all of them for f > 24) */
	wire [23:0] smk;
	am_shift #(.W(24), .SW(5)) u_smk (.a(24'hFFFFFF), .amt(fm1), .left(1'b1), .arith(1'b0), .y(smk));
	wire st = f > 8'd24 ? |m : f != 8'd0 && |(m & ~smk);
	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q[0]);
		endcase
	am_add #(.W(25)) u_n (.a({1'b0, q}), .b(25'd0), .ci(up), .s(n), .co(carry_unused[2]));

	wire unused_ok = &{1'b0, carry_unused};
endmodule

`default_nettype wire
