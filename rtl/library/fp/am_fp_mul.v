/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_mul: fp32 multiplier with configurable latency (LAT = 0 or 4).
 * RNE, denormals flushed, canonical NaN 0x7FC00000.
 * See spec/library/fp/am_fp_mul.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_mul #(
	parameter LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	output wire o_valid,
	output wire [31:0] o_r
);
	/* Stage 1: unpack and the special cases. */
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = i_b[30:23];
	wire za = ea == 8'd0;
	wire zb = eb == 8'd0;
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
	wire s = i_a[31] ^ i_b[31];
	/* the exponent ea + eb - 127 */
	wire [9:0] eab, e_n;
	wire eab_co_unused, en_bo_unused;
	am_add #(.W(10)) u_eab (.a({2'b00, ea}), .b({2'b00, eb}), .ci(1'b0), .s(eab), .co(eab_co_unused));
	am_sub #(.W(10)) u_e_n (.a(eab), .b(10'd127), .bi(1'b0), .d(e_n), .bo(en_bo_unused));

	wire v1_w = rst_n && i_valid;
	wire s1_w = s;
	wire sp1_w = nan_a || nan_b || ((inf_a || inf_b) && (za || zb)) || inf_a || inf_b || za || zb;
	wire [31:0] spv1_w = (nan_a || nan_b || ((inf_a || inf_b) && (za || zb))) ? 32'h7FC00000 :
		(inf_a || inf_b) ? {s, 8'hFF, 23'd0} : {s, 31'd0};
	wire [9:0] e1_w = e_n;
	wire [23:0] ma1_w = {1'b1, i_a[22:0]};
	wire [23:0] mb1_w = {1'b1, i_b[22:0]};

	wire v1, sp1, s1;
	wire [31:0] spv1;
	wire [9:0] e1;
	wire [23:0] ma1, mb1;

	/* Stage 2: the product (DSPs). */
	wire [47:0] p1;
	am_mul #(.AW(24), .BW(24)) u_p1 (.clk(clk), .en(1'b1), .a(ma1), .b(mb1), .p(p1));

	wire v2, sp2, s2;
	wire [31:0] spv2;
	wire [9:0] e2;
	wire [47:0] p2;

	/* stage 3 exponent: + 1 for a product in [2, 4) */
	wire [9:0] e2n;
	wire e2n_co_unused;
	am_add #(.W(10)) u_e2n (.a(e2), .b(10'd0), .ci(p2[47]), .s(e2n), .co(e2n_co_unused));

	/* Stage 3: normalise (the product is in [1, 4)). */
	wire [23:0] m3_w = p2[47] ? p2[47:24] : p2[46:23];
	wire g3_w = p2[47] ? p2[23] : p2[22];
	wire st3_w = p2[47] ? (p2[22:0] != 23'd0) : (p2[21:0] != 22'd0);
	wire [9:0] e3_w = e2n;

	wire v3, sp3, s3, g3, st3;
	wire [31:0] spv3;
	wire [9:0] e3;
	wire [23:0] m3;

	/* Stage 4: round to nearest even, pack. */
	wire [24:0] m0;
	wire [9:0] e;
	wire m0_co_unused, e_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, m3}), .b(25'd0), .ci(g3 && (st3 || m3[0])), .s(m0),
		.co(m0_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	am_add #(.W(10)) u_e (.a(e3), .b(10'd0), .ci(m0[24]), .s(e), .co(e_co_unused));
	wire unused_m = &{1'b0, m[24:23], eab_co_unused, en_bo_unused, e2n_co_unused, m0_co_unused, e_co_unused};

	wire o_valid_comb = rst_n && v3;
	wire [31:0] o_r_comb = sp3 ? spv3 :
		(!e[9] && e >= 10'd255) ? {s3, 8'hFF, 23'd0} :
		(e[9] || e == 10'd0) ? {s3, 31'd0} :
		{s3, e[7:0], m[22:0]};

	generate
		if (LAT == 0) begin : g_lat0
			assign v1 = i_valid;
			assign sp1 = sp1_w;
			assign spv1 = spv1_w;
			assign s1 = s1_w;
			assign e1 = e1_w;
			assign ma1 = ma1_w;
			assign mb1 = mb1_w;

			assign v2 = v1;
			assign sp2 = sp1;
			assign spv2 = spv1;
			assign s2 = s1;
			assign e2 = e1;
			assign p2 = p1;

			assign v3 = v2;
			assign sp3 = sp2;
			assign spv3 = spv2;
			assign s3 = s2;
			assign g3 = g3_w;
			assign st3 = st3_w;
			assign e3 = e3_w;
			assign m3 = m3_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w};
		end else begin : g_lat4
			reg r_v1, r_sp1, r_s1;
			reg [31:0] r_spv1;
			reg [9:0] r_e1;
			reg [23:0] r_ma1, r_mb1;

			always @(posedge clk) begin
				r_v1 <= v1_w;
				r_s1 <= s1_w;
				r_sp1 <= sp1_w;
				r_spv1 <= spv1_w;
				r_e1 <= e1_w;
				r_ma1 <= ma1_w;
				r_mb1 <= mb1_w;
			end

			assign v1 = r_v1;
			assign sp1 = r_sp1;
			assign spv1 = r_spv1;
			assign s1 = r_s1;
			assign e1 = r_e1;
			assign ma1 = r_ma1;
			assign mb1 = r_mb1;

			reg r_v2, r_sp2, r_s2;
			reg [31:0] r_spv2;
			reg [9:0] r_e2;
			reg [47:0] r_p2;

			always @(posedge clk) begin
				r_v2 <= rst_n && v1;
				r_sp2 <= sp1;
				r_spv2 <= spv1;
				r_s2 <= s1;
				r_e2 <= e1;
				r_p2 <= p1;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign spv2 = r_spv2;
			assign s2 = r_s2;
			assign e2 = r_e2;
			assign p2 = r_p2;

			reg r_v3, r_sp3, r_s3, r_g3, r_st3;
			reg [31:0] r_spv3;
			reg [9:0] r_e3;
			reg [23:0] r_m3;

			always @(posedge clk) begin
				r_v3 <= rst_n && v2;
				r_sp3 <= sp2;
				r_spv3 <= spv2;
				r_s3 <= s2;
				r_m3 <= m3_w;
				r_g3 <= g3_w;
				r_st3 <= st3_w;
				r_e3 <= e3_w;
			end

			assign v3 = r_v3;
			assign sp3 = r_sp3;
			assign spv3 = r_spv3;
			assign s3 = r_s3;
			assign g3 = r_g3;
			assign st3 = r_st3;
			assign e3 = r_e3;
			assign m3 = r_m3;

			reg r_ovalid;
			reg [31:0] r_or;

			always @(posedge clk) begin
				r_ovalid <= o_valid_comb;
				r_or <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r = r_or;
		end
	endgenerate
endmodule

`default_nettype wire
