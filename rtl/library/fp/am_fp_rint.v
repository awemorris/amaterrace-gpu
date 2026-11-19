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

	/* 1-hot exponent decoder: e_oh[k] = (e == 150 - k) for k = 1..24, e_oh[0] = e_ge150. */
	localparam [191:0] E_TGT = {
		8'd126, 8'd127, 8'd128, 8'd129, 8'd130, 8'd131,
		8'd132, 8'd133, 8'd134, 8'd135, 8'd136, 8'd137,
		8'd138, 8'd139, 8'd140, 8'd141, 8'd142, 8'd143,
		8'd144, 8'd145, 8'd146, 8'd147, 8'd148, 8'd149
	};
	wire [24:0] e_oh;
	assign e_oh[0] = e_ge150;
	generate
		for (gi = 1; gi <= 24; gi = gi + 1) begin : g_eoh
			assign e_oh[gi] = (e == E_TGT[(gi - 1) * 8 +: 8]);
		end
	endgenerate

	wire g = |(e_oh[24:1] & m[23:0]);
	wire st = (e_lt126 && sp[24]) || |(e_oh[24:2] & sp[23:1]);
	wire q_lsb = (e_oh[0] && m[0]) || |(e_oh[23:1] & m[23:1]);

	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x[31] && (g || st);
		3'd3: up = !x[31] && (g || st);
		3'd4: up = g;
		default: up = g && (st || q_lsb);
		endcase

	wire [23:0] m_eff = e_lt126 ? 24'd0 : m;

	/* Factored 2-stage 1-hot right shift on m_eff, then parallel-prefix +up increment. */
	wire [24:0] sh_oh = {e_oh[24] || e_lt126, e_oh[23:0]};
	wire [3:0] lo_oh = {
		sh_oh[3]  | sh_oh[7]  | sh_oh[11] | sh_oh[15] | sh_oh[19] | sh_oh[23],
		sh_oh[2]  | sh_oh[6]  | sh_oh[10] | sh_oh[14] | sh_oh[18] | sh_oh[22],
		sh_oh[1]  | sh_oh[5]  | sh_oh[9]  | sh_oh[13] | sh_oh[17] | sh_oh[21],
		sh_oh[0]  | sh_oh[4]  | sh_oh[8]  | sh_oh[12] | sh_oh[16] | sh_oh[20] | sh_oh[24]
	};
	wire [6:0] hi_oh = {
		sh_oh[24],
		|sh_oh[23:20],
		|sh_oh[19:16],
		|sh_oh[15:12],
		|sh_oh[11:8],
		|sh_oh[7:4],
		|sh_oh[3:0]
	};

	wire [27:0] pre_sh_p = {4'd0, m_eff};
	wire [24:0] s1_sh;
	wire [48:0] s1_sh_p = {24'd0, s1_sh};
	wire [24:0] sh_m;
	generate
		for (gi = 0; gi < 25; gi = gi + 1) begin : g_s1_sh
			assign s1_sh[gi] =
				(lo_oh[0] & pre_sh_p[gi])     | (lo_oh[1] & pre_sh_p[gi + 1]) |
				(lo_oh[2] & pre_sh_p[gi + 2]) | (lo_oh[3] & pre_sh_p[gi + 3]);
		end
		for (gi = 0; gi < 25; gi = gi + 1) begin : g_s2_sh
			assign sh_m[gi] =
				(hi_oh[0] & s1_sh_p[gi])      | (hi_oh[1] & s1_sh_p[gi + 4])  |
				(hi_oh[2] & s1_sh_p[gi + 8])  | (hi_oh[3] & s1_sh_p[gi + 12]) |
				(hi_oh[4] & s1_sh_p[gi + 16]) | (hi_oh[5] & s1_sh_p[gi + 20]) |
				(hi_oh[6] & s1_sh_p[gi + 24]);
		end
	endgenerate

	wire [5:0] inc_g_all;
	wire [6:0] inc_g_c;
	wire [24:0] inc_c;
	assign inc_g_c[0] = up;
	generate
		for (gi = 0; gi < 6; gi = gi + 1) begin : g_inc_grp
			assign inc_g_all[gi] = &sh_m[gi*4 +: 4];
			assign inc_g_c[gi + 1] = up & (&inc_g_all[gi:0]);
			assign inc_c[gi*4 + 0] = inc_g_c[gi];
			assign inc_c[gi*4 + 1] = inc_g_c[gi] & sh_m[gi*4 + 0];
			assign inc_c[gi*4 + 2] = inc_g_c[gi] & (&sh_m[gi*4 + 1 : gi*4 + 0]);
			assign inc_c[gi*4 + 3] = inc_g_c[gi] & (&sh_m[gi*4 + 2 : gi*4 + 0]);
		end
	endgenerate
	assign inc_c[24] = inc_g_c[6];
	assign n = sh_m ^ inc_c;

	wire unused_ok = &{1'b0, pre_sh_p[27:25], s1_sh_p[48:25], sp[0], e_oh[0]};
endmodule

`default_nettype wire
