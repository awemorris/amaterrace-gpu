/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_fadd: optimized fp32 adder / subtractor for RX pipeline (LAT = 0 or 4).
 * Drop-in replacement for am_fp_add with precomputed exponent increment
 * to break the critical path through CLZ and addsub in Stage 3.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_fadd #(
	parameter LAT = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_valid,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	input wire i_sub,
	output wire o_valid,
	output wire [31:0] o_r
);
	/* Stage 1: unpack, specials, order by magnitude. */
	wire [31:0] b_in = {i_b[31] ^ i_sub, i_b[30:0]};
	wire [7:0] ea = i_a[30:23];
	wire [7:0] eb = b_in[30:23];
	wire [23:0] ma = ea == 8'd0 ? 24'd0 : {1'b1, i_a[22:0]};
	wire [23:0] mb = eb == 8'd0 ? 24'd0 : {1'b1, b_in[22:0]};
	wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0;
	wire nan_b = eb == 8'hFF && b_in[22:0] != 23'd0;
	wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0;
	wire inf_b = eb == 8'hFF && b_in[22:0] == 23'd0;
	wire a_big = {ea, ma} >= {eb, mb};
	/* the exponent difference, larger minus smaller */
	wire [7:0] dab;
	wire dab_bo_unused;
	am_sub #(.W(8)) u_dab (.a(a_big ? ea : eb), .b(a_big ? eb : ea), .bi(1'b0), .d(dab),
		.bo(dab_bo_unused));

	wire v1_w = rst_n && i_valid;
	wire sp1_w = nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31]) || inf_a || inf_b || (ma == 24'd0 && mb == 24'd0);
	wire [31:0] spv1_w = (nan_a || nan_b || (inf_a && inf_b && i_a[31] != b_in[31])) ? 32'h7FC00000 :
		inf_a ? {i_a[31], 8'hFF, 23'd0} :
		inf_b ? {b_in[31], 8'hFF, 23'd0} :
		(ma == 24'd0 && mb == 24'd0) ? {i_a[31] && b_in[31], 31'd0} : 32'd0;
	wire sx1_w = a_big ? i_a[31] : b_in[31];
	wire sub1_w = i_a[31] != b_in[31];
	wire [7:0] ex1_w = a_big ? ea : eb;
	wire [23:0] mx1_w = a_big ? ma : mb;
	wire [23:0] my1_w = a_big ? mb : ma;
	wire [7:0] d1_w = a_big ? (mb == 24'd0 ? 8'd255 : dab) : (ma == 24'd0 ? 8'd255 : dab);

	wire v1;
	wire sp1, sx1, sub1;
	wire [31:0] spv1;
	wire [7:0] ex1, d1;
	wire [23:0] mx1, my1;

	/* Stage 2: align the smaller operand (3 extra bits, the last sticky). */
	reg [26:0] sh;
	reg stk;
	integer k;

	wire [26:0] shi = {my1, 3'b000};
	wire [26:0] shr;	/* (d1 < 27 where it is used) */
	am_shift #(.W(27), .SW(5)) u_shr (.a(shi), .amt(d1[4:0]), .left(1'b0), .arith(1'b0),
		.y(shr));
	always @(*) begin
		stk = 1'b0;
		if (d1 >= 8'd27) begin
			stk = my1 != 24'd0;
			sh = 27'd0;
		end else begin
			for (k = 0; k < 27; k = k + 1)
				if (k < d1)
					stk = stk | shi[k];
			sh = shr;
		end
	end

	wire [9:0] ex2_p1_w;
	wire ex2_p1_co_unused;
	am_add #(.W(10)) u_ex2_p1 (.a({2'b00, ex1}), .b(10'd1), .ci(1'b0), .s(ex2_p1_w), .co(ex2_p1_co_unused));

	wire v2_w = rst_n && v1;
	wire sp2_w = sp1;
	wire [31:0] spv2_w = spv1;
	wire sx2_w = sx1;
	wire sub2_w = sub1;
	wire [7:0] ex2_w = ex1;
	wire [26:0] px2_w = {mx1, 3'b000};
	wire [26:0] py2_w = {sh[26:1], sh[0] | stk};

	wire v2;
	wire sp2, sx2, sub2;
	wire [31:0] spv2;
	wire [7:0] ex2;
	wire [9:0] ex2_p1;
	wire [26:0] px2, py2;

	/* Stage 3: add or subtract, count leading zeros, normalise shift & exponent. */
	wire [27:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(28)) u_sum (.a({1'b0, px2}), .b({1'b0, py2}), .sub(sub2), .s(sum), .co(sum_co_unused));
	reg [4:0] lz;

	always @(*) begin
		lz = 5'd27;
		for (k = 0; k < 27; k = k + 1)
			if (sum[k])
				lz = 5'd26 - k[4:0];
	end

	wire [26:0] nl;
	am_shift #(.W(27), .SW(5)) u_nl (.a(sum[26:0]), .amt(lz), .left(1'b1), .arith(1'b0), .y(nl));
	wire [26:0] n_comb = sum[27] ? {sum[27:2], sum[1] | sum[0]} : nl;
	wire [9:0] e0_sub;
	wire e0_sub_bo_unused;
	am_sub #(.W(10)) u_e0_sub (.a({2'b00, ex2}), .b({5'd0, lz}), .bi(1'b0), .d(e0_sub), .bo(e0_sub_bo_unused));
	wire [9:0] e0_comb = sum[27] ? ex2_p1 : e0_sub;
	wire sz_comb = (sum == 28'd0);

	wire v3_w = rst_n && v2;
	wire sp3_w = sp2;
	wire [31:0] spv3_w = spv2;
	wire sx3_w = sx2;
	wire [26:0] n3_w = n_comb;
	wire [9:0] e0_3_w = e0_comb;
	wire sz3_w = sz_comb;

	wire v3;
	wire sp3, sx3, sz3;
	wire [31:0] spv3;
	wire [26:0] n3;
	wire [9:0] e0_3;

	/* Stage 4: round to nearest even, pack. */
	wire inc = n3[2] && (n3[1] || n3[0] || n3[3]);
	wire [24:0] m0;
	wire m_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, n3[26:3]}), .b(25'd0), .ci(inc), .s(m0), .co(m_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	wire [9:0] e;
	wire e_co_unused;
	am_add #(.W(10)) u_e (.a(e0_3), .b(10'd0), .ci(m0[24]), .s(e), .co(e_co_unused));
	wire unused_m = &{1'b0, m[24:23], e0_sub_bo_unused, ex2_p1_co_unused, e_co_unused, m_co_unused, dab_bo_unused, sum_co_unused};

	wire o_valid_comb = rst_n && v3;
	wire [31:0] o_r_comb = sp3 ? spv3 :
		sz3 ? 32'd0 :
		(!e[9] && e >= 10'd255) ? {sx3, 8'hFF, 23'd0} :
		(e[9] || e == 10'd0) ? {sx3, 31'd0} :
		{sx3, e[7:0], m[22:0]};

	generate
		if (LAT == 0) begin : g_lat0
			assign v1 = i_valid;
			assign sp1 = sp1_w;
			assign spv1 = spv1_w;
			assign sx1 = sx1_w;
			assign sub1 = sub1_w;
			assign ex1 = ex1_w;
			assign mx1 = mx1_w;
			assign my1 = my1_w;
			assign d1 = d1_w;

			assign v2 = v1;
			assign sp2 = sp2_w;
			assign spv2 = spv2_w;
			assign sx2 = sx2_w;
			assign sub2 = sub2_w;
			assign ex2 = ex2_w;
			assign ex2_p1 = ex2_p1_w;
			assign px2 = px2_w;
			assign py2 = py2_w;

			assign v3 = v2;
			assign sp3 = sp3_w;
			assign spv3 = spv3_w;
			assign sx3 = sx3_w;
			assign n3 = n3_w;
			assign e0_3 = e0_3_w;
			assign sz3 = sz3_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w, v2_w, v3_w};
		end else begin : g_lat4
			reg r_v1, r_sp1, r_sx1, r_sub1;
			reg [31:0] r_spv1;
			reg [7:0] r_ex1, r_d1;
			reg [23:0] r_mx1, r_my1;

			always @(posedge clk) begin
				r_v1 <= v1_w;
				r_sp1 <= sp1_w;
				r_spv1 <= spv1_w;
				r_sx1 <= sx1_w;
				r_sub1 <= sub1_w;
				r_ex1 <= ex1_w;
				r_mx1 <= mx1_w;
				r_my1 <= my1_w;
				r_d1 <= d1_w;
			end

			assign v1 = r_v1;
			assign sp1 = r_sp1;
			assign spv1 = r_spv1;
			assign sx1 = r_sx1;
			assign sub1 = r_sub1;
			assign ex1 = r_ex1;
			assign mx1 = r_mx1;
			assign my1 = r_my1;
			assign d1 = r_d1;

			reg r_v2, r_sp2, r_sx2, r_sub2;
			reg [31:0] r_spv2;
			reg [7:0] r_ex2;
			reg [9:0] r_ex2_p1;
			reg [26:0] r_px2, r_py2;

			always @(posedge clk) begin
				r_v2 <= v2_w;
				r_sp2 <= sp2_w;
				r_spv2 <= spv2_w;
				r_sx2 <= sx2_w;
				r_sub2 <= sub2_w;
				r_ex2 <= ex2_w;
				r_ex2_p1 <= ex2_p1_w;
				r_px2 <= px2_w;
				r_py2 <= py2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign spv2 = r_spv2;
			assign sx2 = r_sx2;
			assign sub2 = r_sub2;
			assign ex2 = r_ex2;
			assign ex2_p1 = r_ex2_p1;
			assign px2 = r_px2;
			assign py2 = r_py2;

			reg r_v3, r_sp3, r_sx3, r_sz3;
			reg [31:0] r_spv3;
			reg [26:0] r_n3;
			reg [9:0] r_e0_3;

			always @(posedge clk) begin
				r_v3   <= v3_w;
				r_sp3  <= sp3_w;
				r_spv3 <= spv3_w;
				r_sx3  <= sx3_w;
				r_n3   <= n3_w;
				r_e0_3 <= e0_3_w;
				r_sz3  <= sz3_w;
			end

			assign v3   = r_v3;
			assign sp3  = r_sp3;
			assign spv3 = r_spv3;
			assign sx3  = r_sx3;
			assign n3   = r_n3;
			assign e0_3 = r_e0_3;
			assign sz3  = r_sz3;

			reg r_ovalid;
			(* extract_reset = "no" *) reg [31:0] r_or;

			always @(posedge clk) begin
				r_ovalid <= o_valid_comb;
				r_or     <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r     = r_or;
		end
	endgenerate
endmodule

`default_nettype wire
