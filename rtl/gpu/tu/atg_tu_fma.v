/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_fma: TU fp32 fused multiply-add (LAT = 10), bit-for-bit identical
 * to am_fp_fma #(.LAT(10)) with high-frequency pipeline stage balancing
 * (<= 4 LUTs random logic, <= 1 Pre/Post LUT around carry chains).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_fma #(
	parameter TW = 4
) (
	input wire clk,
	input wire rst_n,
	input wire i_vld,
	input wire [TW-1:0] i_tag,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	/* The addend, read in cycle 3 */
	output wire c_vld,
	output wire [TW-1:0] c_tag,
	input wire [31:0] c_val,
	input wire [2:0] rm,
	input wire noc,
	/* The result in cycle 10 */
	output wire r_vld,
	output wire [TW-1:0] r_tag,
	output wire [31:0] r_val,
	output wire o_busy
);
	wire u_eab_nc, u_q100_nc, u_q175_nc, u_eb99_nc, u_k50_nc, u_u_nc, u_ec2_nc, u_cp_nc,
		u_er_nc, u_rnd_nc, u_er1_nc;
	(* dont_touch = "true" *) wire rst_inv = !rst_n;
	integer i;

	/* ---- M0: a and b ---- */
	wire [7:0] ea = i_a[30:23], eb = i_b[30:23];
	(* keep = "true" *) wire ea_z_lo0 = (ea[3:0] == 4'd0);
	(* keep = "true" *) wire ea_z_lo1 = (ea[3:0] == 4'd0);
	(* keep = "true" *) wire ea_z_hi0 = (ea[7:4] == 4'd0);
	(* keep = "true" *) wire ea_z_hi1 = (ea[7:4] == 4'd0);
	(* keep = "true" *) wire eb_z_lo0 = (eb[3:0] == 4'd0);
	(* keep = "true" *) wire eb_z_lo1 = (eb[3:0] == 4'd0);
	(* keep = "true" *) wire eb_z_hi0 = (eb[7:4] == 4'd0);
	(* keep = "true" *) wire eb_z_hi1 = (eb[7:4] == 4'd0);
	(* keep = "true" *) wire ma_nz_lo = (i_a[11:0]  != 12'd0);
	(* keep = "true" *) wire ma_nz_hi = (i_a[22:12] != 11'd0);
	(* keep = "true" *) wire mb_nz_lo = (i_b[11:0]  != 12'd0);
	(* keep = "true" *) wire mb_nz_hi = (i_b[22:12] != 11'd0);
	wire [8:0] eab0;

	am_add #(.W(9)) u_eab (.a({1'b0, ea}), .b({1'b0, eb}), .ci(1'b0), .s(eab0), .co(u_eab_nc));

	reg v1;
	(* extract_reset = "no" *) reg [TW-1:0] t1;
	(* extract_reset = "no" *) reg [23:0] sa1, sb1;
	(* extract_reset = "no" *) reg sp1, za1, zb1, ea_ff1, eb_ff1, ma_nz1, mb_nz1;
	(* extract_reset = "no" *) reg [8:0] eab1;
	always @(posedge clk) begin
		sa1[11:0]  <= (ea_z_lo0 && ea_z_hi0) ? 12'd0 : i_a[11:0];
		sa1[22:12] <= (ea_z_lo1 && ea_z_hi1) ? 11'd0 : i_a[22:12];
		sa1[23]    <= !(ea_z_lo1 && ea_z_hi1);
		sb1[11:0]  <= (eb_z_lo0 && eb_z_hi0) ? 12'd0 : i_b[11:0];
		sb1[22:12] <= (eb_z_lo1 && eb_z_hi1) ? 11'd0 : i_b[22:12];
		sb1[23]    <= !(eb_z_lo1 && eb_z_hi1);
		sp1 <= i_a[31] ^ i_b[31];
		za1 <= ea_z_lo0 && ea_z_hi0;
		zb1 <= eb_z_lo0 && eb_z_hi0;
		ea_ff1 <= (ea == 8'hFF);
		eb_ff1 <= (eb == 8'hFF);
		ma_nz1 <= ma_nz_lo || ma_nz_hi;
		mb_nz1 <= mb_nz_lo || mb_nz_hi;
		eab1 <= eab0;
		t1 <= i_tag;
	end

	/* ---- The product (R2-R4) and the constants of the exponents ---- */
	wire [47:0] p4;

	am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(3)) u_mul (
		.clk(clk), .en(1'b1), .a(sa1), .b(sb1), .p(p4)
	);

	/* q100 = 100 - eab1 (so ec + q100 = ks - 50; ks > 49 <=> !(ec + q100)[11]) */
	wire [11:0] q100, q175, eb99;

	am_sub #(.W(12)) u_q100 (.a(12'd100), .b({3'd0, eab1}), .bi(1'b0), .d(q100), .bo(u_q100_nc));
	am_sub #(.W(12)) u_q175 (.a(12'd175), .b({3'd0, eab1}), .bi(1'b0), .d(q175), .bo(u_q175_nc));
	am_sub #(.W(12)) u_eb99 (.a({3'd0, eab1}), .b(12'd99), .bi(1'b0), .d(eb99), .bo(u_eb99_nc));

	wire nan_a1 = ea_ff1 && ma_nz1;
	wire nan_b1 = eb_ff1 && mb_nz1;
	wire inf_a1 = ea_ff1 && !ma_nz1;
	wire inf_b1 = eb_ff1 && !mb_nz1;
	wire nanp1 = nan_a1 || nan_b1 || (inf_a1 && zb1) || (inf_b1 && za1);
	wire infp1 = inf_a1 || inf_b1;
	wire zp1 = za1 || zb1;

	reg v2, v3, v4;
	(* extract_reset = "no", shreg_extract = "no" *) reg [TW-1:0] t2, t3, t4;
	(* extract_reset = "no", shreg_extract = "no" *) reg sp2, sp3, sp4, nanp2, nanp3, nanp4, infp2, infp3, infp4, zp2, zp3, zp4;
	(* extract_reset = "no", shreg_extract = "no" *) reg [11:0] q100_2, q100_3, q100_4, q175_2, q175_3, q175_4, eb99_2, eb99_3, eb99_4;
	always @(posedge clk) begin
		{sp2, nanp2, infp2, zp2, t2} <= {sp1, nanp1, infp1, zp1, t1};
		{sp3, nanp3, infp3, zp3, t3} <= {sp2, nanp2, infp2, zp2, t2};
		{sp4, nanp4, infp4, zp4, t4} <= {sp3, nanp3, infp3, zp3, t3};
		{q100_2, q175_2, eb99_2} <= {q100, q175, eb99};
		{q100_3, q175_3, eb99_3} <= {q100_2, q175_2, eb99_2};
		{q100_4, q175_4, eb99_4} <= {q100_3, q175_3, eb99_3};
	end

	/* The addend is read in cycle 3 and registered. */
	assign c_vld = v3;
	assign c_tag = t3;
	(* extract_reset = "no", max_fanout = 16 *) reg [31:0] c4;
	always @(posedge clk)
		c4 <= c_val;

	/* ---- A1: the addend ---- */
	wire [7:0] ec = c4[30:23];
	wire zc_raw = ec == 8'd0;
	(* keep = "true" *) wire zc = zc_raw;
	(* keep = "true" *) wire zc_cf_lo = zc_raw;
	(* keep = "true" *) wire zc_cf_hi = zc_raw;
	(* keep = "true" *) wire zc_mc_lo = zc_raw;
	(* keep = "true" *) wire zc_mc_hi = zc_raw;
	wire nan_c = ec == 8'hFF && c4[22:0] != 23'd0;
	wire inf_c = ec == 8'hFF && c4[22:0] == 23'd0;
	wire sc = c4[31];
	wire [31:0] cf = {sc, zc_cf_hi ? 15'd0 : c4[30:16], zc_cf_lo ? 16'd0 : c4[15:0]};
	wire [11:0] k_m50, u_a1, ec2;

	am_add #(.W(12)) u_k50 (.a({4'd0, ec}), .b(q100_4), .ci(1'b0), .s(k_m50), .co(u_k50_nc));
	am_add #(.W(12)) u_u   (.a({4'd0, ec}), .b(q175_4), .ci(1'b0), .s(u_a1),  .co(u_u_nc));
	am_add #(.W(12)) u_ec2 (.a({4'd0, ec}), .b(12'd2),  .ci(1'b0), .s(ec2),   .co(u_ec2_nc));

	reg spec_a1;
	reg [31:0] sres_a1;
	always @(*) begin
		spec_a1 = 1'b1;
		if (nanp4 || nan_c)
			sres_a1 = 32'h7FC00000;
		else if (infp4)
			sres_a1 = inf_c && sc != sp4 ? 32'h7FC00000 : {sp4, 8'hFF, 23'd0};
		else if (inf_c)
			sres_a1 = cf;
		else if (zp4)
			sres_a1 = !zc ? cf : {sp4 & sc, 31'd0};
		else begin
			sres_a1 = 32'd0;
			spec_a1 = 1'b0;
		end
	end

	/* ks > 49 <=> !k_m50[11]; ks < -25 <=> u_a1[11] (1 LUT Post-CARRY!) */
	(* keep = "true" *) wire big_a1 = !zc && !k_m50[11];
	(* keep = "true" *) wire [6:0] amt5_w = big_a1 ? 7'd74 : u_a1[6:0];

	reg v5;
	(* extract_reset = "no" *) reg [TW-1:0] t5;
	(* extract_reset = "no", max_fanout = 16 *) reg [47:0] p5;
	(* extract_reset = "no", max_fanout = 16 *) reg big5, tiny5;
	(* extract_reset = "no", keep = "true", max_fanout = 16 *) reg [6:0] amt5, amt5_st;
	(* extract_reset = "no" *) reg [11:0] eb99_5, ec2_5;
	(* extract_reset = "no", max_fanout = 16 *) reg [23:0] mc5;
	(* extract_reset = "no", max_fanout = 16 *) reg zc5, sc5, sp5, spec5;
	(* extract_reset = "no" *) reg [31:0] sres5;
	always @(posedge clk) begin
		p5 <= p4;
		big5 <= big_a1;
		tiny5 <= u_a1[11];
		amt5 <= amt5_w;
		amt5_st <= amt5_w;
		eb99_5 <= eb99_4;
		ec2_5 <= ec2;
		mc5[11:0]  <= zc_mc_lo ? 12'd0 : c4[11:0];
		mc5[23:12] <= zc_mc_hi ? 12'd0 : {1'b1, c4[22:12]};
		zc5 <= zc;
		sc5 <= sc;
		sp5 <= sp4;
		spec5 <= spec_a1;
		sres5 <= sres_a1;
		t5 <= t4;
	end

	/* ---- A2: the window (P's LSB at bit 2) ---- */
	wire big = big5, tiny = tiny5;
	(* keep = "true" *) wire [5:0] big_s  = {6{big5}};
	(* keep = "true" *) wire [5:0] tiny_s = {6{tiny5}};
	(* keep = "true" *) wire [5:0] zc5_s  = {6{zc5}};
	wire [6:0] amt = amt5;
	wire [97:0] csh;

	am_shift #(.W(98), .SW(7)) u_csh (
		.a({74'd0, mc5}), .amt(amt), .left(1'b1), .arith(1'b0), .y(csh)
	);

	/* Fast sticky bit of csh[23:0] directly from mc5 and amt (<= 3 LUTs) */
	wire [23:0] st_bit;
	genvar gb;
	generate
	for (gb = 0; gb < 24; gb = gb + 1) begin : g_st_a2
		localparam [4:0] MAX_AMT = 5'd23 - gb[4:0];
		(* keep = "true" *) wire b_hit = mc5[gb] && (amt5_st[4:0] <= MAX_AMT);
		assign st_bit[gb] = b_hit;
	end
	endgenerate
	(* keep = "true" *) wire [3:0] st_grp = {
		|st_bit[23:18], |st_bit[17:12], |st_bit[11:6], |st_bit[5:0]
	};
	wire csh_st = (amt5_st[6:5] == 2'b00) && (|st_grp);

	wire [76:0] cw_raw = {2'b00, csh[97:24], csh_st};
	wire [76:0] pw_raw = {27'd0, p5, 2'b00};
	wire [76:0] cw_a2;
	wire [76:0] pw_a2;
	genvar gw;
	generate
	for (gw = 0; gw < 6; gw = gw + 1) begin : g_w_a2
		if (gw == 0) begin : g_w0
			assign cw_a2[12:0] = zc5_s[0] ? 13'd0 : tiny_s[0] ? 13'd1 : cw_raw[12:0];
			assign pw_a2[12:0] = big_s[0] ? 13'd1 : pw_raw[12:0];
		end else if (gw < 5) begin : g_w1_4
			assign cw_a2[gw*13 +: 13] = (zc5_s[gw] || tiny_s[gw]) ? 13'd0 : cw_raw[gw*13 +: 13];
			assign pw_a2[gw*13 +: 13] = big_s[gw] ? 13'd0 : pw_raw[gw*13 +: 13];
		end else begin : g_w5
			assign cw_a2[76:65] = (zc5_s[5] || tiny_s[5]) ? 12'd0 : cw_raw[76:65];
			assign pw_a2[76:65] = big_s[5] ? 12'd0 : pw_raw[76:65];
		end
	end
	endgenerate

	reg v6;
	(* extract_reset = "no" *) reg [TW-1:0] t6;
	(* extract_reset = "no" *) reg [76:0] pw6, cw6;
	(* extract_reset = "no", max_fanout = 16 *) reg sub6, sp6, sc6, spec6;
	(* extract_reset = "no" *) reg [11:0] eb6;
	(* extract_reset = "no" *) reg [31:0] sres6;
	always @(posedge clk) begin
		pw6 <= pw_a2;
		cw6 <= cw_a2;
		sub6 <= !zc5 && sp5 != sc5;
		sp6 <= sp5;
		sc6 <= sc5;
		eb6 <= big ? ec2_5 : eb99_5;
		spec6 <= spec5;
		sres6 <= sres5;
		t6 <= t5;
	end

	/* ---- B: P + C, or |P - C| ---- */
	wire [76:0] s1, s2;
	wire co1;

	am_addsub #(.W(77)) u_pc (.a(pw6), .b(cw6), .sub(sub6), .s(s1), .co(co1));
	am_sub #(.W(77)) u_cp (.a(cw6), .b(pw6), .bi(1'b0), .d(s2), .bo(u_cp_nc));

	wire neg_b = sub6 && !co1;

	reg v7;
	(* extract_reset = "no" *) reg [TW-1:0] t7;
	(* extract_reset = "no", max_fanout = 16 *) reg [76:0] s1_7, s2_7;
	(* extract_reset = "no", max_fanout = 16 *) reg neg7;
	(* extract_reset = "no" *) reg sr7, spec7;
	(* extract_reset = "no" *) reg [11:0] eb7;
	(* extract_reset = "no" *) reg [31:0] sres7;
	always @(posedge clk) begin
		s1_7 <= s1;
		s2_7 <= s2;
		neg7 <= neg_b;
		sr7 <= neg_b ? sc6 : sp6;
		eb7 <= eb6;
		spec7 <= spec6;
		sres7 <= sres6;
		t7 <= t6;
	end

	/* ---- C1: the magnitude, its leading zeros (4-level 6-input-bounded LZC <= 4 LUTs) ---- */
	(* keep = "true" *) wire [5:0] neg7_s = {6{neg7}};
	wire [76:0] sum7 = {
		neg7_s[5] ? s2_7[76:65] : s1_7[76:65],
		neg7_s[4] ? s2_7[64:52] : s1_7[64:52],
		neg7_s[3] ? s2_7[51:39] : s1_7[51:39],
		neg7_s[2] ? s2_7[38:26] : s1_7[38:26],
		neg7_s[1] ? s2_7[25:13] : s1_7[25:13],
		neg7_s[0] ? s2_7[12:0]  : s1_7[12:0]
	};

	/* Level 1: 6-input LUTs on 6-bit slices of s1_7 and s2_7 */
	(* keep = "true" *) wire [5:0] sz1_hi, sz2_hi;
	(* keep = "true" *) wire [6:0] sp1_hi [0:5];
	(* keep = "true" *) wire [6:0] sp2_hi [0:5];
	(* keep = "true" *) wire [6:0] sp1_lo [0:5];
	(* keep = "true" *) wire [6:0] sp2_lo [0:5];
	(* keep = "true" *) wire [5:1] u1_lo, u2_lo, wm_lo;

	genvar gp;
	generate
	for (gp = 0; gp < 6; gp = gp + 1) begin : g_lzc_l1
		localparam [6:0] HI_BASE = 7'd65 - 7'd13 * gp[6:0];
		localparam [6:0] LO_BASE = 7'd71 - 7'd13 * gp[6:0];
		wire [5:0] w1_hi = s1_7[13*gp + 6 +: 6];
		wire [5:0] w2_hi = s2_7[13*gp + 6 +: 6];
		wire [5:0] w1_lo = s1_7[13*gp +: 6];
		wire [5:0] w2_lo = s2_7[13*gp +: 6];

		assign sz1_hi[gp] = |w1_hi;
		assign sz2_hi[gp] = |w2_hi;
		assign sp1_hi[gp] = w1_hi[5] ? (HI_BASE + 7'd0) :
		                    w1_hi[4] ? (HI_BASE + 7'd1) :
		                    w1_hi[3] ? (HI_BASE + 7'd2) :
		                    w1_hi[2] ? (HI_BASE + 7'd3) :
		                    w1_hi[1] ? (HI_BASE + 7'd4) :
		                               (HI_BASE + 7'd5);
		assign sp2_hi[gp] = w2_hi[5] ? (HI_BASE + 7'd0) :
		                    w2_hi[4] ? (HI_BASE + 7'd1) :
		                    w2_hi[3] ? (HI_BASE + 7'd2) :
		                    w2_hi[2] ? (HI_BASE + 7'd3) :
		                    w2_hi[1] ? (HI_BASE + 7'd4) :
		                               (HI_BASE + 7'd5);
		if (gp == 0) begin : g_p0
			assign sp1_lo[gp] = w1_lo[5] ? 7'd71 :
			                    w1_lo[4] ? 7'd72 :
			                    w1_lo[3] ? 7'd73 :
			                    w1_lo[2] ? 7'd74 :
			                    w1_lo[1] ? 7'd75 : 7'd76;
			assign sp2_lo[gp] = w2_lo[5] ? 7'd71 :
			                    w2_lo[4] ? 7'd72 :
			                    w2_lo[3] ? 7'd73 :
			                    w2_lo[2] ? 7'd74 :
			                    w2_lo[1] ? 7'd75 : 7'd76;
		end else begin : g_p1_5
			assign sp1_lo[gp] = w1_lo[5] ? (LO_BASE + 7'd0) :
			                    w1_lo[4] ? (LO_BASE + 7'd1) :
			                    w1_lo[3] ? (LO_BASE + 7'd2) :
			                    w1_lo[2] ? (LO_BASE + 7'd3) :
			                    w1_lo[1] ? (LO_BASE + 7'd4) :
			                    w1_lo[0] ? (LO_BASE + 7'd5) :
			                               (LO_BASE + 7'd6);
			assign sp2_lo[gp] = w2_lo[5] ? (LO_BASE + 7'd0) :
			                    w2_lo[4] ? (LO_BASE + 7'd1) :
			                    w2_lo[3] ? (LO_BASE + 7'd2) :
			                    w2_lo[2] ? (LO_BASE + 7'd3) :
			                    w2_lo[1] ? (LO_BASE + 7'd4) :
			                    w2_lo[0] ? (LO_BASE + 7'd5) :
			                               (LO_BASE + 7'd6);
			assign u1_lo[gp] = |s1_7[13*gp - 1 +: 6];
			assign u2_lo[gp] = |s2_7[13*gp - 1 +: 6];
			assign wm_lo[gp] = neg7 ? s2_7[13*gp + 5] : s1_7[13*gp + 5];
		end
	end
	endgenerate

	/* Level 2: 3-input pair position and 6-input pair non-zero */
	(* keep = "true" *) wire [6:0] pp1 [0:5];
	(* keep = "true" *) wire [6:0] pp2 [0:5];
	(* keep = "true" *) wire [5:1] pz_m;
	generate
	for (gp = 0; gp < 6; gp = gp + 1) begin : g_lzc_l2
		assign pp1[gp] = sz1_hi[gp] ? sp1_hi[gp] : sp1_lo[gp];
		assign pp2[gp] = sz2_hi[gp] ? sp2_hi[gp] : sp2_lo[gp];
		if (gp >= 1) begin : g_pz
			assign pz_m[gp] = wm_lo[gp] | (neg7 ? (sz2_hi[gp] | u2_lo[gp]) : (sz1_hi[gp] | u1_lo[gp]));
		end
	end
	endgenerate

	/* Level 3: 6-input group position and 2-input group non-zero */
	(* keep = "true" *) wire [6:0] grp_p [0:2];
	(* keep = "true" *) wire [2:1] grp_z;
	genvar gg;
	generate
	for (gg = 0; gg < 3; gg = gg + 1) begin : g_lzc_l3
		assign grp_p[gg] = pz_m[2*gg + 1] ? (neg7 ? pp2[2*gg + 1] : pp1[2*gg + 1]) :
		                                    (neg7 ? pp2[2*gg]     : pp1[2*gg]);
		if (gg >= 1) begin : g_gz
			assign grp_z[gg] = pz_m[2*gg + 1] | pz_m[2*gg];
		end
	end
	endgenerate

	/* Level 4: 5-input final mux */
	(* keep = "true" *) wire [6:0] lz_c1 = grp_z[2] ? grp_p[2] : grp_z[1] ? grp_p[1] : grp_p[0];
	(* keep = "true" *) wire s1_z = (s1_7 == 77'd0);
	(* keep = "true" *) wire s2_z = (s2_7 == 77'd0);

	reg v8;
	(* extract_reset = "no" *) reg [TW-1:0] t8;
	(* extract_reset = "no", max_fanout = 16 *) reg [76:0] sum8;
	(* extract_reset = "no", keep = "true", max_fanout = 16 *) reg [6:0] lz8;
	(* extract_reset = "no", keep = "true", max_fanout = 16 *) reg [6:0] lz8_st0, lz8_st1, lz8_st2;
	(* extract_reset = "no", max_fanout = 16 *) reg sr8, zero8, spec8;
	(* extract_reset = "no" *) reg [11:0] eb8;
	(* extract_reset = "no" *) reg [31:0] sres8;
	always @(posedge clk) begin
		sum8 <= sum7;
		lz8 <= lz_c1;
		lz8_st0 <= lz_c1;
		lz8_st1 <= lz_c1;
		lz8_st2 <= lz_c1;
		zero8 <= neg7 ? s2_z : s1_z;
		sr8 <= sr7;
		eb8 <= eb7;
		spec8 <= spec7;
		sres8 <= sres7;
		t8 <= t7;
	end

	/* ---- C2: normalised (the leading one at bit 76), exponent ---- */
	wire [76:0] nrm;
	wire [11:0] er_c2;

	am_shift #(.W(77), .SW(7)) u_nrm (.a(sum8), .amt(lz8), .left(1'b1), .arith(1'b0), .y(nrm));
	am_sub #(.W(12)) u_er (.a(eb8), .b({5'd0, lz8}), .bi(1'b0), .d(er_c2), .bo(u_er_nc));

	/* Fast sticky bit of nrm[51:0] directly from sum8[51:0] and lz8 (<= 3 LUTs) */
	wire [51:0] nrm_st_bit;
	genvar gs;
	generate
	for (gs = 0; gs < 52; gs = gs + 1) begin : g_st_c2
		localparam [5:0] MAX_LZ = 6'd51 - gs[5:0];
		if (gs < 18) begin : g_st0
			(* keep = "true" *) wire s_hit = sum8[gs] && (lz8_st0[5:0] <= MAX_LZ);
			assign nrm_st_bit[gs] = s_hit;
		end else if (gs < 36) begin : g_st1
			(* keep = "true" *) wire s_hit = sum8[gs] && (lz8_st1[5:0] <= MAX_LZ);
			assign nrm_st_bit[gs] = s_hit;
		end else begin : g_st2
			(* keep = "true" *) wire s_hit = sum8[gs] && (lz8_st2[5:0] <= MAX_LZ);
			assign nrm_st_bit[gs] = s_hit;
		end
	end
	endgenerate
	(* keep = "true" *) wire [8:0] nrm_st_grp = {
		|nrm_st_bit[51:48], |nrm_st_bit[47:42], |nrm_st_bit[41:36],
		|nrm_st_bit[35:30], |nrm_st_bit[29:24], |nrm_st_bit[23:18],
		|nrm_st_bit[17:12], |nrm_st_bit[11:6],  |nrm_st_bit[5:0]
	};
	wire st9_w = !lz8_st0[6] && (|nrm_st_grp);

	reg v9;
	(* extract_reset = "no" *) reg [TW-1:0] t9;
	(* extract_reset = "no", max_fanout = 16 *) reg [24:0] m9;
	(* extract_reset = "no", max_fanout = 16 *) reg st9, sr9, zero9, spec9;
	(* extract_reset = "no", max_fanout = 16 *) reg [11:0] er9;
	(* extract_reset = "no" *) reg [31:0] sres9;
	always @(posedge clk) begin
		m9 <= nrm[76:52];
		st9 <= st9_w;
		er9 <= er_c2;
		sr9 <= sr8;
		zero9 <= zero8;
		spec9 <= spec8;
		sres9 <= sres8;
		t9 <= t8;
	end

	/* ---- D1: round to nearest even & pre-decode exponent range ---- */
	wire up = m9[0] && (st9 || m9[1]);
	wire [24:0] mr_d1;
	wire [11:0] er1_d1;

	am_add #(.W(25)) u_rnd (.a({1'b0, m9[24:1]}), .b(25'd0), .ci(up), .s(mr_d1), .co(u_rnd_nc));
	am_add #(.W(12)) u_er1 (.a(er9), .b(12'd0), .ci(1'b1), .s(er1_d1), .co(u_er1_nc));

	wire ovf0_d1 = !er9[11] && (|er9[10:8] || (&er9[7:0]));
	wire udf0_d1 = er9[11] || (er9[10:0] == 11'd0);
	wire ovf1_d1 = !er9[11] && (|er9[10:8] || (&er9[7:1]));
	wire udf1_d1 = er9[11];

	reg v10;
	(* extract_reset = "no" *) reg [TW-1:0] t10;
	(* extract_reset = "no", max_fanout = 16 *) reg [24:0] mr10;
	(* extract_reset = "no" *) reg [7:0] e0_10, e1_10;
	(* extract_reset = "no", max_fanout = 16 *) reg m0_en_10, m1_en_10;
	(* extract_reset = "no", max_fanout = 16 *) reg sr10, spec10;
	(* extract_reset = "no" *) reg [31:0] sres10;
	always @(posedge clk) begin
		mr10 <= mr_d1;
		e0_10 <= (zero9 || udf0_d1) ? 8'd0 : ovf0_d1 ? 8'hFF : er9[7:0];
		e1_10 <= (zero9 || udf1_d1) ? 8'd0 : ovf1_d1 ? 8'hFF : er1_d1[7:0];
		m0_en_10 <= !zero9 && !ovf0_d1 && !udf0_d1;
		m1_en_10 <= !zero9 && !ovf1_d1 && !udf1_d1;
		sr10 <= zero9 ? 1'b0 : sr9;
		spec10 <= spec9;
		sres10 <= sres9;
		t10 <= t9;
	end

	/* ---- D2: 1-LUT output mux ---- */
	(* keep = "true" *) wire mr24_e  = mr10[24];
	(* keep = "true" *) wire mr24_lo = mr10[24];
	(* keep = "true" *) wire mr24_hi = mr10[24];
	(* keep = "true" *) wire m0_en_lo = m0_en_10, m0_en_hi = m0_en_10;
	(* keep = "true" *) wire m1_en_lo = m1_en_10, m1_en_hi = m1_en_10;
	(* keep = "true" *) wire spec10_lo = spec10, spec10_hi = spec10;
	wire [7:0] ef = mr24_e ? e1_10 : e0_10;
	wire [11:0] mf_lo = mr24_lo ? (m1_en_lo ? mr10[12:1]  : 12'd0) : (m0_en_lo ? mr10[11:0]  : 12'd0);
	wire [10:0] mf_hi = mr24_hi ? (m1_en_hi ? mr10[23:13] : 11'd0) : (m0_en_hi ? mr10[22:12] : 11'd0);
	wire [31:0] norm_val = {sr10, ef, mf_hi, mf_lo};
	assign r_val = {spec10_hi ? sres10[31:16] : norm_val[31:16], spec10_lo ? sres10[15:0] : norm_val[15:0]};
	/* The valid bits. */
	(* keep = "true" *) reg busy_q;
	assign r_vld = v10;
	assign r_tag = t10;
	assign o_busy = busy_q;

	always @(posedge clk) begin
		if (rst_inv) begin
			{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10} <= 10'd0;
			busy_q <= 1'b0;
		end else begin
			{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10} <=
				{i_vld, v1, v2, v3, v4, v5, v6, v7, v8, v9};
			busy_q <= i_vld || (|{v1, v2, v3, v4, v5, v6, v7, v8, v9});
		end
	end

	wire unused_ok = &{1'b0, u_eab_nc, u_q100_nc, u_q175_nc, u_eb99_nc, u_k50_nc, u_u_nc,
		u_ec2_nc, u_cp_nc, u_er_nc, u_rnd_nc, u_er1_nc, k_m50[10:0], u_a1[10:7],
		csh[23:0], nrm[51:0], er1_d1[11:8], lz8_st1[6], lz8_st2[6], rm, noc};
endmodule

`default_nettype wire
