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
	wire x_s = e_nz && x[31];
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

	wire e_ge150 = e[7] && (|e[6:5] || (e[4] && (e[3] || (e[2] && e[1]))));
	wire e_lt126 = !e[7] && !(&e[6:1]);
	wire e_hi011 = (e[7:5] == 3'b011) && (&e[4:1]);
	wire e_hi100 = (e[7:5] == 3'b100);

	/* 1-hot exponent decoder for sticky only: e_oh[k] = (e == 150 - k) for k = 2..24. */
	wire [24:0] e_oh;
	assign e_oh[0] = e_ge150;
	assign e_oh[1] = e_hi100 && (e[4:0] == 5'd21);
	generate
		for (gi = 2; gi <= 22; gi = gi + 1) begin : g_eoh
			localparam [4:0] TGT5 = 22 - gi;
			assign e_oh[gi] = e_hi100 && (e[4:0] == TGT5);
		end
	endgenerate
	assign e_oh[23] = e_hi011 &&  e[0];
	assign e_oh[24] = e_hi011 && !e[0];

	wire st_lo = e_lt126 && e_nz && sp[24];
	wire st_hi = |(e_oh[24:2] & sp[23:1]);
	wire st = st_lo || st_hi;

	/* Direct 2-stage right shift on {m, 1'b0}: lo_oh from e[1:0], hi_oh from e[4:0], mask e_lt126 after shift. */
	wire [3:0] lo_oh = {
		!e_ge150 && (e[1:0] == 2'd3),
		!e_ge150 && (e[1:0] == 2'd0),
		!e_ge150 && (e[1:0] == 2'd1),
		 e_ge150 || (e[1:0] == 2'd2)
	};
	wire [6:0] hi_oh = {
		e_hi011 && !e[0],
		(e_hi100 && (e[4:0] <= 5'd2)) || (e_hi011 && e[0]),
		e_hi100 && (e[4:0] >= 5'd3  && e[4:0] <= 5'd6),
		e_hi100 && (e[4:0] >= 5'd7  && e[4:0] <= 5'd10),
		e_hi100 && (e[4:0] >= 5'd11 && e[4:0] <= 5'd14),
		e_hi100 && (e[4:0] >= 5'd15 && e[4:0] <= 5'd18),
		e_ge150 || (e_hi100 && (e[4:0] >= 5'd19 && e[4:0] <= 5'd21))
	};

	wire [28:0] pre_sh_g = {4'd0, m, 1'b0};
	wire [25:0] s1_sh;
	wire [49:0] s1_sh_p = {24'd0, s1_sh};
	wire [25:0] sh_out;
	generate
		for (gi = 0; gi < 26; gi = gi + 1) begin : g_s1_sh
			assign s1_sh[gi] =
				(lo_oh[0] & pre_sh_g[gi])     | (lo_oh[1] & pre_sh_g[gi + 1]) |
				(lo_oh[2] & pre_sh_g[gi + 2]) | (lo_oh[3] & pre_sh_g[gi + 3]);
		end
		for (gi = 0; gi < 26; gi = gi + 1) begin : g_s2_sh
			assign sh_out[gi] =
				(hi_oh[0] & s1_sh_p[gi])      | (hi_oh[1] & s1_sh_p[gi + 4])  |
				(hi_oh[2] & s1_sh_p[gi + 8])  | (hi_oh[3] & s1_sh_p[gi + 12]) |
				(hi_oh[4] & s1_sh_p[gi + 16]) | (hi_oh[5] & s1_sh_p[gi + 20]) |
				(hi_oh[6] & s1_sh_p[gi + 24]);
		end
	endgenerate

	wire [24:0] sh_m = e_lt126 ? 25'd0 : sh_out[25:1];
	wire g = !e_lt126 && sh_out[0];
	wire q_lsb = sh_m[0];

	reg up;
	always @(*)
		case (rm)
		3'd1: up = 1'b0;
		3'd2: up = x_s && (g || st);
		3'd3: up = !x_s && (g || st);
		3'd4: up = g;
		default: up = g && (st || q_lsb);
		endcase

	/* Carry-propagate vector depends only on sh_m; up gates only at the final XOR. */
	wire [5:0] inc_g4;
	wire [6:0] inc_p4;
	wire [24:0] inc_raw;
	assign inc_p4[0] = 1'b1;
	generate
		for (gi = 0; gi < 6; gi = gi + 1) begin : g_inc_grp
			assign inc_g4[gi] = &sh_m[gi*4 +: 4];
			assign inc_p4[gi + 1] = &inc_g4[gi:0];
			assign inc_raw[gi*4 + 0] = inc_p4[gi];
			assign inc_raw[gi*4 + 1] = inc_p4[gi] & sh_m[gi*4 + 0];
			assign inc_raw[gi*4 + 2] = inc_p4[gi] & (&sh_m[gi*4 + 1 : gi*4 + 0]);
			assign inc_raw[gi*4 + 3] = inc_p4[gi] & (&sh_m[gi*4 + 2 : gi*4 + 0]);
		end
	endgenerate
	assign inc_raw[24] = inc_p4[6];
	assign n = sh_m ^ ({25{up}} & inc_raw);

	wire unused_ok = &{1'b0, pre_sh_g[28:26], s1_sh_p[49:26], sp[0], e_oh[1:0]};
endmodule

`default_nettype wire
