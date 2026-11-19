/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_popcount: counts the number of 1-bits in a W-bit vector (W <= 32).
 * Implemented as an explicit balanced binary reduction tree to guarantee
 * O(log2 W) logic depth (typically <= 2-3 LUT levels on Kintex-7).
 */

`timescale 1ns / 1ps
`default_nettype none

module am_popcount #(
	parameter W = 16,
	parameter OW = 5
) (
	input wire [W-1:0] i_vec,
	output wire [OW-1:0] o_cnt
);
	genvar gi, gk;
	generate
	if (W <= 12) begin : g_fast12
		reg [11:0] v12;
		always @(*) begin
			v12 = 12'd0;
			v12[W-1:0] = i_vec;
		end
		wire [3:0] s0, c1;
		for (gk = 0; gk < 4; gk = gk + 1) begin : g_g3
			wire a = v12[3*gk], b = v12[3*gk + 1], c = v12[3*gk + 2];
			assign s0[gk] = a ^ b ^ c;
			assign c1[gk] = (a & b) | (a & c) | (b & c);
		end
		wire sa0 = s0[0] ^ s0[1] ^ s0[2];
		wire ca0 = (s0[0] & s0[1]) | (s0[0] & s0[2]) | (s0[1] & s0[2]);
		wire w1_r = sa0 ^ s0[3];
		wire w2_a = sa0 & s0[3];

		wire sa1 = c1[0] ^ c1[1] ^ c1[2];
		wire ca1 = (c1[0] & c1[1]) | (c1[0] & c1[2]) | (c1[1] & c1[2]);
		wire w2_b = sa1 ^ c1[3];
		wire w4_a = sa1 & c1[3];

		wire w2_s = ca0 ^ w2_a ^ w2_b;
		wire w4_b = (ca0 & w2_a) | (ca0 & w2_b) | (w2_a & w2_b);

		wire w4_s = ca1 ^ w4_a ^ w4_b;
		wire w8_c = (ca1 & w4_a) | (ca1 & w4_b) | (w4_a & w4_b);

		wire [4:0] cnt5 = {1'b0, w8_c, w4_s, w2_s, w1_r};
		if (OW <= 5) begin : g_ow_le5
			assign o_cnt = cnt5[OW-1:0];
			if (OW < 5) begin : g_un5
				wire unused_c5 = &{1'b0, cnt5[4:OW]};
			end
		end else begin : g_ow_gt5
			assign o_cnt = {{(OW - 5){1'b0}}, cnt5};
		end
	end else begin : g_full32
	/* Bit-slice 3:2 CSA popcount tree (O(log W) FA stages + single 6-bit final add) */
	localparam integer PAD_W = 32;
	wire [PAD_W-1:0] v = {{(PAD_W - W){1'b0}}, i_vec};

	/* Compress weight-0 bits via full/half adders into weights 0..5.
	 * Stage 1: ten 3-bit groups (0..29) + bits 30..31 -> 11 weight-0, 10 weight-1 bits (with 30,31->HA: 12 w0, 11 w1). */
	wire [11:0] w0_s1;
	wire [10:0] w1_s1;
		for (gi = 0; gi < 10; gi = gi + 1) begin : g_w0_s1
			wire a = v[3*gi], b = v[3*gi+1], c = v[3*gi+2];
			assign w0_s1[gi] = a ^ b ^ c;
			assign w1_s1[gi] = (a & b) | (a & c) | (b & c);
		end
	assign w0_s1[10] = v[30] ^ v[31];
	assign w1_s1[10] = v[30] & v[31];
	assign w0_s1[11] = 1'b0;

	/* Reduce w0_s1 (11 bits) -> 4 bits w0_s2, 4 bits to w1 */
	wire [3:0] w0_s2;
	wire [3:0] w1_from_0;
		for (gi = 0; gi < 4; gi = gi + 1) begin : g_w0_s2
			wire a = w0_s1[3*gi], b = w0_s1[3*gi+1], c = w0_s1[3*gi+2];
			assign w0_s2[gi]     = a ^ b ^ c;
			assign w1_from_0[gi] = (a & b) | (a & c) | (b & c);
		end

	/* Reduce w0_s2 (4 bits) -> 2 bits w0_fin, 2 bits to w1 */
	wire [1:0] w0_fin;
	wire [1:0] w1_from_0b;
	assign w0_fin[0]     = w0_s2[0] ^ w0_s2[1] ^ w0_s2[2];
	assign w1_from_0b[0] = (w0_s2[0] & w0_s2[1]) | (w0_s2[0] & w0_s2[2]) | (w0_s2[1] & w0_s2[2]);
	assign w0_fin[1]     = w0_s2[3];
	assign w1_from_0b[1] = 1'b0;

	/* Weight-1 pool: 11 (s1) + 4 (s2) + 2 (s3) = 17 bits (15 + 2) */
	wire [16:0] w1_pool = {w1_from_0b, w1_from_0, w1_s1};
	wire [6:0] w1_s2;
	wire [5:0] w2_from_1;
		for (gi = 0; gi < 5; gi = gi + 1) begin : g_w1_s2
			wire a = w1_pool[3*gi], b = w1_pool[3*gi+1], c = w1_pool[3*gi+2];
			assign w1_s2[gi]     = a ^ b ^ c;
			assign w2_from_1[gi] = (a & b) | (a & c) | (b & c);
		end
	assign w1_s2[5]     = w1_pool[15] ^ w1_pool[16];
	assign w2_from_1[5] = w1_pool[15] & w1_pool[16];
	assign w1_s2[6]     = 1'b0;

	/* Weight-1: 6 bits (0..5) -> 2 bits w1_fin + 2 bits to w2 */
	wire [1:0] w1_fin;
	wire [1:0] w2_from_1b;
		for (gi = 0; gi < 2; gi = gi + 1) begin : g_w1_fin
			wire a = w1_s2[3*gi], b = w1_s2[3*gi+1], c = w1_s2[3*gi+2];
			assign w1_fin[gi]     = a ^ b ^ c;
			assign w2_from_1b[gi] = (a & b) | (a & c) | (b & c);
		end

	/* Weight-2 pool: 8 bits -> 3 bits + 3 to w3 */
	wire [8:0] w2_pool = {1'b0, w2_from_1b, w2_from_1};
	wire [2:0] w2_s2;
	wire [2:0] w3_from_2;
		for (gi = 0; gi < 3; gi = gi + 1) begin : g_w2_s2
			wire a = w2_pool[3*gi], b = w2_pool[3*gi+1], c = w2_pool[3*gi+2];
			assign w2_s2[gi]     = a ^ b ^ c;
			assign w3_from_2[gi] = (a & b) | (a & c) | (b & c);
		end
	wire w2_fin0 = w2_s2[0] ^ w2_s2[1] ^ w2_s2[2];
	wire w3_fin_c = (w2_s2[0] & w2_s2[1]) | (w2_s2[0] & w2_s2[2]) | (w2_s2[1] & w2_s2[2]);

	/* Weight-3 pool: 4 bits -> 2 bits w3_fin + 1 to w4 */
	wire w3_fin0 = w3_from_2[0] ^ w3_from_2[1] ^ w3_from_2[2];
	wire w4_from_3 = (w3_from_2[0] & w3_from_2[1]) | (w3_from_2[0] & w3_from_2[2]) | (w3_from_2[1] & w3_from_2[2]);

	wire [5:0] op_a = {1'b0, w4_from_3, w3_fin0,  w2_fin0, w1_fin[0], w0_fin[0]};
	wire [5:0] op_b = {1'b0, 1'b0,      w3_fin_c, 1'b0,    w1_fin[1], w0_fin[1]};
	wire [5:0] s4 = op_a + op_b;

	assign o_cnt = s4[OW-1:0];

	wire unused_s4 = &{1'b0, s4[5:OW], w0_s1[11], w1_from_0b[1], w1_s2[6]};
	end
	endgenerate
endmodule

`default_nettype wire
