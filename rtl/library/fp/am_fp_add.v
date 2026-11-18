/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_add: fp32 adder / subtractor with configurable latency (LAT = 0 or 4).
 * IEEE single, round to nearest even, denormals flushed to zero on input
 * and output, NaN results the canonical 0x7FC00000.
 * i_sub negates b.
 * See spec/library/fp/am_fp_add.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_add #(
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
	am_shift #(.W(27), .SW(5), .DIR(1)) u_shr (.a(shi), .amt(d1[4:0]), .left(1'b0), .arith(1'b0),
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
	wire [26:0] px2, py2;

	/* Stage 3: add or subtract, parallel LZA + zero detect, normalise shift & exponent. */
	wire [27:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(28)) u_sum (.a({1'b0, px2}), .b({1'b0, py2}), .sub(sub2), .s(sum), .co(sum_co_unused));

	/* Parallel LZA for subtraction (px2 >= py2 guaranteed by Stage 1): error in {0, +1} bit left */
	wire [26:0] lza_g = px2 & ~py2;
	wire [26:0] lza_z = ~px2 & py2;
	wire [26:0] lza_p = ~(px2 ^ py2);
	wire [26:0] lza_f;
	assign lza_f[26] = lza_g[26] & ~lza_z[25];
	genvar gi_lza;
	generate
		for (gi_lza = 1; gi_lza < 26; gi_lza = gi_lza + 1) begin : g_lza
			assign lza_f[gi_lza] = lza_p[gi_lza + 1] ?
				(lza_g[gi_lza] & ~lza_z[gi_lza - 1]) :
				(lza_z[gi_lza] & ~lza_z[gi_lza - 1]);
		end
	endgenerate
	assign lza_f[0] = lza_p[1] ? lza_g[0] : lza_z[0];

	reg [4:0] lz_est, lz_est_p1;
	reg lz_v3, lz_v2, lz_v1;
	reg [4:0] lz_g3, lz_g2, lz_g1, lz_g0;
	reg [4:0] lz_g3_p1, lz_g2_p1, lz_g1_p1, lz_g0_p1;

	always @(*) begin
		lz_v3 = |lza_f[26:20];
		if      (lza_f[26]) begin lz_g3 = 5'd0; lz_g3_p1 = 5'd1; end
		else if (lza_f[25]) begin lz_g3 = 5'd1; lz_g3_p1 = 5'd2; end
		else if (lza_f[24]) begin lz_g3 = 5'd2; lz_g3_p1 = 5'd3; end
		else if (lza_f[23]) begin lz_g3 = 5'd3; lz_g3_p1 = 5'd4; end
		else if (lza_f[22]) begin lz_g3 = 5'd4; lz_g3_p1 = 5'd5; end
		else if (lza_f[21]) begin lz_g3 = 5'd5; lz_g3_p1 = 5'd6; end
		else                begin lz_g3 = 5'd6; lz_g3_p1 = 5'd7; end

		lz_v2 = |lza_f[19:13];
		if      (lza_f[19]) begin lz_g2 = 5'd7;  lz_g2_p1 = 5'd8;  end
		else if (lza_f[18]) begin lz_g2 = 5'd8;  lz_g2_p1 = 5'd9;  end
		else if (lza_f[17]) begin lz_g2 = 5'd9;  lz_g2_p1 = 5'd10; end
		else if (lza_f[16]) begin lz_g2 = 5'd10; lz_g2_p1 = 5'd11; end
		else if (lza_f[15]) begin lz_g2 = 5'd11; lz_g2_p1 = 5'd12; end
		else if (lza_f[14]) begin lz_g2 = 5'd12; lz_g2_p1 = 5'd13; end
		else                begin lz_g2 = 5'd13; lz_g2_p1 = 5'd14; end

		lz_v1 = |lza_f[12:6];
		if      (lza_f[12]) begin lz_g1 = 5'd14; lz_g1_p1 = 5'd15; end
		else if (lza_f[11]) begin lz_g1 = 5'd15; lz_g1_p1 = 5'd16; end
		else if (lza_f[10]) begin lz_g1 = 5'd16; lz_g1_p1 = 5'd17; end
		else if (lza_f[9])  begin lz_g1 = 5'd17; lz_g1_p1 = 5'd18; end
		else if (lza_f[8])  begin lz_g1 = 5'd18; lz_g1_p1 = 5'd19; end
		else if (lza_f[7])  begin lz_g1 = 5'd19; lz_g1_p1 = 5'd20; end
		else                begin lz_g1 = 5'd20; lz_g1_p1 = 5'd21; end

		if      (lza_f[5])  begin lz_g0 = 5'd21; lz_g0_p1 = 5'd22; end
		else if (lza_f[4])  begin lz_g0 = 5'd22; lz_g0_p1 = 5'd23; end
		else if (lza_f[3])  begin lz_g0 = 5'd23; lz_g0_p1 = 5'd24; end
		else if (lza_f[2])  begin lz_g0 = 5'd24; lz_g0_p1 = 5'd25; end
		else if (lza_f[1])  begin lz_g0 = 5'd25; lz_g0_p1 = 5'd26; end
		else if (lza_f[0])  begin lz_g0 = 5'd26; lz_g0_p1 = 5'd27; end
		else                begin lz_g0 = 5'd27; lz_g0_p1 = 5'd27; end

		if (lz_v3)      begin lz_est = lz_g3; lz_est_p1 = lz_g3_p1; end
		else if (lz_v2) begin lz_est = lz_g2; lz_est_p1 = lz_g2_p1; end
		else if (lz_v1) begin lz_est = lz_g1; lz_est_p1 = lz_g1_p1; end
		else            begin lz_est = lz_g0; lz_est_p1 = lz_g0_p1; end
	end

	wire [4:0] lz_in = sub2 ? lz_est : 5'd0;
	wire [26:0] nl_est;
	am_shift #(.W(27), .SW(5), .DIR(2)) u_nl (.a(sum[26:0]), .amt(lz_in), .left(1'b1), .arith(1'b0), .y(nl_est));
	wire [26:0] nl = (sub2 && !nl_est[26]) ? {nl_est[25:0], 1'b0} : nl_est;
	wire [4:0]  lz = (!sub2 || sum[27]) ? 5'd0 : (nl_est[26] ? lz_est : lz_est_p1);
	wire [26:0] n_comb = sum[27] ? {sum[27:2], sum[1] | sum[0]} : nl;
	wire sz_comb = sub2 && (px2 == py2);

	wire v3_w = rst_n && v2;
	wire sp3_w = sp2;
	wire [31:0] spv3_w = spv2;
	wire sx3_w = sx2;
	wire [26:0] n3_w = n_comb;
	wire [7:0] ex3_w = ex2;
	wire sum27_3_w = sum[27];
	wire [4:0] lz3_w = lz;
	wire sz3_w = sz_comb;

	wire v3;
	wire sp3, sx3, sz3, sum27_3;
	wire [31:0] spv3;
	wire [26:0] n3;
	wire [7:0] ex3;
	wire [4:0] lz3;

	/* Stage 4: round to nearest even, pack. */
	wire inc = n3[2] && (n3[1] || n3[0] || n3[3]);
	wire m0_ovf = (&n3[26:3]) && inc;
	wire [24:0] m0;
	wire m_co_unused;
	am_add #(.W(25)) u_m0 (.a({1'b0, n3[26:3]}), .b(25'd0), .ci(inc), .s(m0), .co(m_co_unused));
	wire [24:0] m = m0[24] ? {1'b0, m0[24:1]} : m0;
	wire [9:0] e0_4;
	wire e0_co_unused;
	am_addsub #(.W(10)) u_e0 (.a({2'b00, ex3}), .b(sum27_3 ? 10'd1 : {5'd0, lz3}), .sub(!sum27_3),
		.s(e0_4), .co(e0_co_unused));
	wire [9:0] e;
	wire e_co_unused;
	am_add #(.W(10)) u_e (.a(e0_4), .b(10'd0), .ci(m0_ovf), .s(e), .co(e_co_unused));
	wire unused_m = &{1'b0, m[24:23], e0_co_unused, e_co_unused, m_co_unused, dab_bo_unused, sum_co_unused};

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
			assign px2 = px2_w;
			assign py2 = py2_w;

			assign v3 = v2;
			assign sp3 = sp3_w;
			assign spv3 = spv3_w;
			assign sx3 = sx3_w;
			assign n3 = n3_w;
			assign ex3 = ex3_w;
			assign sum27_3 = sum27_3_w;
			assign lz3 = lz3_w;
			assign sz3 = sz3_w;

			assign o_valid = o_valid_comb;
			assign o_r = o_r_comb;

			wire unused_clk = &{1'b0, clk, v1_w, v2_w, v3_w};
		end else if (LAT == 4) begin : g_lat4
			reg r_v1;
			reg r_sp1, r_sx1, r_sub1;
			reg [31:0] r_spv1;
			reg [7:0] r_ex1, r_d1;
			reg [23:0] r_mx1, r_my1;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v1 <= 1'b0;
				else
					r_v1 <= i_valid;
			end

			always @(posedge clk) begin
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

			reg r_v2;
			reg r_sp2, r_sx2, r_sub2;
			reg [31:0] r_spv2;
			reg [7:0] r_ex2;
			reg [26:0] r_px2, r_py2;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v2 <= 1'b0;
				else
					r_v2 <= v1;
			end

			always @(posedge clk) begin
				r_sp2 <= sp2_w;
				r_spv2 <= spv2_w;
				r_sx2 <= sx2_w;
				r_sub2 <= sub2_w;
				r_ex2 <= ex2_w;
				r_px2 <= px2_w;
				r_py2 <= py2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign spv2 = r_spv2;
			assign sx2 = r_sx2;
			assign sub2 = r_sub2;
			assign ex2 = r_ex2;
			assign px2 = r_px2;
			assign py2 = r_py2;

			reg r_v3;
			reg r_sp3, r_sx3, r_sz3, r_sum27_3;
			reg [31:0] r_spv3;
			reg [26:0] r_n3;
			reg [7:0] r_ex3;
			reg [4:0] r_lz3;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v3 <= 1'b0;
				else
					r_v3 <= v2;
			end

			always @(posedge clk) begin
				r_sp3     <= sp3_w;
				r_spv3    <= spv3_w;
				r_sx3     <= sx3_w;
				r_n3      <= n3_w;
				r_ex3     <= ex3_w;
				r_sum27_3 <= sum27_3_w;
				r_lz3     <= lz3_w;
				r_sz3     <= sz3_w;
			end

			assign v3      = r_v3;
			assign sp3     = r_sp3;
			assign spv3    = r_spv3;
			assign sx3     = r_sx3;
			assign n3      = r_n3;
			assign ex3     = r_ex3;
			assign sum27_3 = r_sum27_3;
			assign lz3     = r_lz3;
			assign sz3     = r_sz3;

			reg r_ovalid;
			(* extract_reset = "no" *) reg [31:0] r_or;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_ovalid <= 1'b0;
				else
					r_ovalid <= v3;
			end

			always @(posedge clk) begin
				r_or     <= o_r_comb;
			end

			assign o_valid = r_ovalid;
			assign o_r     = r_or;

			wire unused_lat4 = &{1'b0, v1_w, v2_w, v3_w, o_valid_comb};
		end else begin : g_lat5
			reg r_v1;
			reg r_sp1, r_sx1, r_sub1;
			reg [31:0] r_spv1;
			reg [7:0] r_ex1, r_d1;
			reg [23:0] r_mx1, r_my1;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v1 <= 1'b0;
				else
					r_v1 <= i_valid;
			end

			always @(posedge clk) begin
				r_sp1  <= sp1_w;
				r_spv1 <= spv1_w;
				r_sx1  <= sx1_w;
				r_sub1 <= sub1_w;
				r_ex1  <= ex1_w;
				r_mx1  <= mx1_w;
				r_my1  <= my1_w;
				r_d1   <= d1_w;
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

			reg r_v2;
			reg r_sp2, r_sx2, r_sub2;
			reg [31:0] r_spv2;
			reg [7:0] r_ex2;
			reg [26:0] r_px2, r_py2;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v2 <= 1'b0;
				else
					r_v2 <= v1;
			end

			always @(posedge clk) begin
				r_sp2  <= sp2_w;
				r_spv2 <= spv2_w;
				r_sx2  <= sx2_w;
				r_sub2 <= sub2_w;
				r_ex2  <= ex2_w;
				r_px2  <= px2_w;
				r_py2  <= py2_w;
			end

			assign v2 = r_v2;
			assign sp2 = r_sp2;
			assign spv2 = r_spv2;
			assign sx2 = r_sx2;
			assign sub2 = r_sub2;
			assign ex2 = r_ex2;
			assign px2 = r_px2;
			assign py2 = r_py2;

			/* Stage 3: Add/Sub & Leading Zero Count */
			reg r_v3;
			reg r_sp3, r_sx3, r_sz3;
			reg [31:0] r_spv3;
			reg [7:0] r_ex3;
			reg [27:0] r_sum3;
			reg [4:0] r_lz3;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v3 <= 1'b0;
				else
					r_v3 <= r_v2;
			end

			always @(posedge clk) begin
				r_sp3  <= r_sp2;
				r_spv3 <= r_spv2;
				r_sx3  <= r_sx2;
				r_sz3  <= sz_comb;
				r_ex3  <= r_ex2;
				r_sum3 <= sum;
				r_lz3  <= lz;
			end

			/* Stage 4: Normalise shift & exponent adjustment */
			wire [26:0] nl5;
			am_shift #(.W(27), .SW(5), .DIR(2)) u_nl5 (.a(r_sum3[26:0]), .amt(r_lz3), .left(1'b1), .arith(1'b0), .y(nl5));
			wire [26:0] n_comb5 = r_sum3[27] ? {r_sum3[27:2], r_sum3[1] | r_sum3[0]} : nl5;
			wire [9:0] e0_comb5;
			wire e0_co_unused5;
			am_addsub #(.W(10)) u_e0_5 (.a({2'b00, r_ex3}), .b(r_sum3[27] ? 10'd1 : {5'd0, r_lz3}), .sub(!r_sum3[27]),
				.s(e0_comb5), .co(e0_co_unused5));

			reg r_v4;
			reg r_sp4, r_sx4, r_sz4;
			reg [31:0] r_spv4;
			reg [26:0] r_n4;
			reg [9:0] r_e0_4;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_v4 <= 1'b0;
				else
					r_v4 <= r_v3;
			end

			always @(posedge clk) begin
				r_sp4  <= r_sp3;
				r_spv4 <= r_spv3;
				r_sx4  <= r_sx3;
				r_sz4  <= r_sz3;
				r_n4   <= n_comb5;
				r_e0_4 <= e0_comb5;
			end

			/* Stage 5: Round & pack */
			wire inc5 = r_n4[2] && (r_n4[1] || r_n4[0] || r_n4[3]);
			wire [24:0] m0_5;
			wire m_co_unused5;
			am_add #(.W(25)) u_m0_5 (.a({1'b0, r_n4[26:3]}), .b(25'd0), .ci(inc5), .s(m0_5), .co(m_co_unused5));
			wire [24:0] m5 = m0_5[24] ? {1'b0, m0_5[24:1]} : m0_5;
			wire [9:0] e5;
			wire e_co_unused5;
			am_add #(.W(10)) u_e_5 (.a(r_e0_4), .b(10'd0), .ci(m0_5[24]), .s(e5), .co(e_co_unused5));

			wire [31:0] o_r_comb5 = r_sp4 ? r_spv4 :
				r_sz4 ? 32'd0 :
				(!e5[9] && e5 >= 10'd255) ? {r_sx4, 8'hFF, 23'd0} :
				(e5[9] || e5 == 10'd0) ? {r_sx4, 31'd0} :
				{r_sx4, e5[7:0], m5[22:0]};

			reg r_ovalid5;
			(* extract_reset = "no" *) reg [31:0] r_or5;

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					r_ovalid5 <= 1'b0;
				else
					r_ovalid5 <= r_v4;
			end

			always @(posedge clk) begin
				r_or5     <= o_r_comb5;
			end

			assign o_valid = r_ovalid5;
			assign o_r     = r_or5;

			assign n3      = 27'd0;
			assign ex3     = 8'd0;
			assign sum27_3 = 1'b0;
			assign lz3     = 5'd0;
			assign v3      = 1'b0;
			assign sp3     = 1'b0;
			assign spv3    = 32'd0;
			assign sx3     = 1'b0;
			assign sz3     = 1'b0;

			wire unused_lat5 = &{1'b0, m5[24:23], e0_co_unused5, e_co_unused5, m_co_unused5,
				n3_w, ex3_w, sum27_3_w, lz3_w, e0_4, m0_ovf, o_valid_comb, o_r_comb, v3_w, sp3_w, spv3_w, sx3_w, sz3_w};
		end
	endgenerate
endmodule

`default_nettype wire
