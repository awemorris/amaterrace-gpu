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
	wire [7:0] e = x[30:23];
	wire e_nz = (e != 8'd0);
	wire [23:0] m = {e_nz, x[22:0]};

	/* Parallel suffix/prefix OR: sp[k] = |m[k-1:0] for k=1..24, sp[0]=0.
	 * Computed directly from x in 5 OR levels in parallel with shift amount decode. */
	wire [24:0] sp;
	assign sp[0] = 1'b0;
	genvar gi;
	generate
		for (gi = 1; gi <= 24; gi = gi + 1) begin : g_sp
			assign sp[gi] = |m[gi-1:0];
		end
	endgenerate

	wire e_ge150 = (e >= 8'd150);
	wire e_eq126 = (e == 8'd126);
	wire e_eq127 = (e == 8'd127);
	wire e_in_hi = (e[7:5] == 3'b100) && (e[4:0] <= 5'd21); /* 128..149 */
	wire e_lt126 = !e_ge150 && !e_eq126 && !e_eq127 && !e_in_hi;

	/* For 128..149: f = 22 - e[4:0] (1..22), fm1 = 21 - e[4:0] (0..21). */
	wire [4:0] f_hi, fm1_hi;
	wire [1:0] f5_bo_unused;
	am_sub #(.W(5)) u_f_hi   (.a(5'd22), .b(e[4:0]), .bi(1'b0), .d(f_hi),   .bo(f5_bo_unused[0]));
	am_sub #(.W(5)) u_fm1_hi (.a(5'd21), .b(e[4:0]), .bi(1'b0), .d(fm1_hi), .bo(f5_bo_unused[1]));

	wire [4:0] f_sh = e_eq127 ? 5'd23 : f_hi;
	wire [23:0] q0;
	am_shift #(.W(24), .SW(5), .DIR(1)) u_q (.a(m), .amt(f_sh), .left(1'b0), .arith(1'b0), .y(q0));

	wire [23:0] q = e_ge150 ? m : (e_eq127 || e_in_hi) ? q0 : 24'd0;
	wire g = e_eq126 ? m[23] : e_eq127 ? m[22] : e_in_hi ? m[fm1_hi] : 1'b0;
	wire st = e_ge150 ? 1'b0 : e_lt126 ? sp[24] : e_eq126 ? sp[23] : e_eq127 ? sp[22] : sp[fm1_hi];

	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q[0]);
		endcase
	wire [24:0] qp1;
	wire n_co_unused;
	am_add #(.W(25)) u_n (.a({1'b0, q}), .b(25'd0), .ci(1'b1), .s(qp1), .co(n_co_unused));
	assign n = up ? qp1 : {1'b0, q};

	wire unused_ok = &{1'b0, f5_bo_unused, n_co_unused};
endmodule

`default_nettype wire
