/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_fma: fp32 fused multiply-add with configurable latency (LAT = 0 or 10).
 * Rounded once to nearest even with denormals flushed.
 * See spec/library/fp/am_fp_fma.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_fma #(
	parameter TW = 16,
	parameter LAT = 10
) (
	input wire clk,
	input wire rst_n,
	input wire i_vld,
	input wire [TW-1:0] i_tag,
	input wire [31:0] i_a,
	input wire [31:0] i_b,
	/* The addend, read in cycle 3 (or cycle 0 if LAT=0) */
	output wire c_vld,
	output wire [TW-1:0] c_tag,
	input wire [31:0] c_val,
	input wire [2:0] rm,
	input wire noc,
	/* The result */
	output wire r_vld,
	output wire [TW-1:0] r_tag,
	output wire [31:0] r_val,
	output wire o_busy
);
	generate
		if (LAT == 0) begin : g_lat0
			wire [23:0] ma0 = i_a[30:23] != 8'd0 ? {1'b1, i_a[22:0]} : 24'd0;
			wire [23:0] mb0 = i_b[30:23] != 8'd0 ? {1'b1, i_b[22:0]} : 24'd0;
			wire [47:0] pp0;
			am_mul #(.AW(24), .BW(24), .LAT(0)) u_pp0 (.clk(clk), .en(1'b1), .a(ma0), .b(mb0), .p(pp0));
			wire [31:0] r0;
			am_fp_fma_p #(.LAT(0)) u_f0 (.a0(i_a), .b0(i_b), .c0(c_val), .rm(rm), .noc(noc), .p(pp0), .r(r0));

			assign c_vld = i_vld;
			assign c_tag = i_tag;
			assign r_vld = i_vld;
			assign r_tag = i_tag;
			assign r_val = r0;
			assign o_busy = 1'b0;

			wire unused_lat0 = &{1'b0, clk, rst_n};
		end else begin : g_lat10
			wire u_eab_nc, u_q150_nc, u_q175_nc, u_eb99_nc, u_k_nc, u_u_nc, u_ec2_nc, u_cp_nc,
				u_er_nc, u_rnd_nc, u_er1_nc;
			integer i;

			/* ---- M0: a and b ---- */
			wire [7:0] ea = i_a[30:23], eb = i_b[30:23];
			wire za = ea == 8'd0, zb = eb == 8'd0;
			wire nan_a = ea == 8'hFF && i_a[22:0] != 23'd0, nan_b = eb == 8'hFF && i_b[22:0] != 23'd0;
			wire inf_a = ea == 8'hFF && i_a[22:0] == 23'd0, inf_b = eb == 8'hFF && i_b[22:0] == 23'd0;
			wire [8:0] eab0;

			am_add #(.W(9)) u_eab (.a({1'b0, ea}), .b({1'b0, eb}), .ci(1'b0), .s(eab0), .co(u_eab_nc));

			reg v1;
			reg [TW-1:0] t1;
			reg [23:0] sa1, sb1;
			reg sp1, nanp1, infp1, zp1;
			reg [8:0] eab1;
			always @(posedge clk) begin
				sa1 <= za ? 24'd0 : {1'b1, i_a[22:0]};
				sb1 <= zb ? 24'd0 : {1'b1, i_b[22:0]};
				sp1 <= i_a[31] ^ i_b[31];
				nanp1 <= nan_a || nan_b || (inf_a && zb) || (inf_b && za);
				infp1 <= inf_a || inf_b;
				zp1 <= za || zb;
				eab1 <= eab0;
				t1 <= i_tag;
			end

			/* ---- The product (R2-R4) and the constants of the exponents ---- */
			wire [47:0] p4;

			am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(3)) u_mul (
				.clk(clk), .en(1'b1), .a(sa1), .b(sb1), .p(p4)
			);

			wire [11:0] q150, q175, eb99;

			am_sub #(.W(12)) u_q150 (.a(12'd150), .b({3'd0, eab1}), .bi(1'b0), .d(q150), .bo(u_q150_nc));
			am_sub #(.W(12)) u_q175 (.a(12'd175), .b({3'd0, eab1}), .bi(1'b0), .d(q175), .bo(u_q175_nc));
			am_sub #(.W(12)) u_eb99 (.a({3'd0, eab1}), .b(12'd99), .bi(1'b0), .d(eb99), .bo(u_eb99_nc));

			reg v2, v3, v4;
			reg [TW-1:0] t2, t3, t4;
			reg sp2, sp3, sp4, nanp2, nanp3, nanp4, infp2, infp3, infp4, zp2, zp3, zp4;
			reg [11:0] q150_2, q150_3, q150_4, q175_2, q175_3, q175_4, eb99_2, eb99_3, eb99_4;
			always @(posedge clk) begin
				{sp2, nanp2, infp2, zp2, t2} <= {sp1, nanp1, infp1, zp1, t1};
				{sp3, nanp3, infp3, zp3, t3} <= {sp2, nanp2, infp2, zp2, t2};
				{sp4, nanp4, infp4, zp4, t4} <= {sp3, nanp3, infp3, zp3, t3};
				{q150_2, q175_2, eb99_2} <= {q150, q175, eb99};
				{q150_3, q175_3, eb99_3} <= {q150_2, q175_2, eb99_2};
				{q150_4, q175_4, eb99_4} <= {q150_3, q175_3, eb99_3};
			end

			/* The addend is read in cycle 3 and registered. */
			assign c_vld = v3;
			assign c_tag = t3;
			reg [31:0] c4;
			always @(posedge clk)
				c4 <= c_val;

			/* ---- A1: the addend ---- */
			wire [7:0] ec = c4[30:23];
			wire zc = ec == 8'd0;
			wire nan_c = ec == 8'hFF && c4[22:0] != 23'd0;
			wire inf_c = ec == 8'hFF && c4[22:0] == 23'd0;
			wire sc = c4[31];
			wire [31:0] cf = zc ? {sc, 31'd0} : c4;
			wire [11:0] k_a1, u_a1, ec2;

			am_add #(.W(12)) u_k (.a({4'd0, ec}), .b(q150_4), .ci(1'b0), .s(k_a1), .co(u_k_nc));
			am_add #(.W(12)) u_u (.a({4'd0, ec}), .b(q175_4), .ci(1'b0), .s(u_a1), .co(u_u_nc));
			am_add #(.W(12)) u_ec2 (.a({4'd0, ec}), .b(12'd2), .ci(1'b0), .s(ec2), .co(u_ec2_nc));

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

			reg v5;
			reg [TW-1:0] t5;
			reg [47:0] p5;
			reg big5, tiny5;
			reg [6:0] amt5;
			reg [11:0] eb99_5, ec2_5;
			wire signed [11:0] ks = k_a1;
			reg [23:0] mc5;
			reg zc5, sc5, sp5, spec5;
			reg [31:0] sres5;
			always @(posedge clk) begin
				p5 <= p4;
				big5 <= !zc && ks > 12'sd49;
				tiny5 <= ks < -12'sd25;
				amt5 <= !zc && ks > 12'sd49 ? 7'd74 : u_a1[6:0];
				eb99_5 <= eb99_4;
				ec2_5 <= ec2;
				mc5 <= zc ? 24'd0 : {1'b1, c4[22:0]};
				zc5 <= zc;
				sc5 <= sc;
				sp5 <= sp4;
				spec5 <= spec_a1;
				sres5 <= sres_a1;
				t5 <= t4;
			end

			/* ---- A2: the window (P's LSB at bit 2) ---- */
			wire big = big5, tiny = tiny5;
			wire [6:0] amt = amt5;
			wire [97:0] csh;

			am_shift #(.W(98), .SW(7)) u_csh (
				.a({74'd0, mc5}), .amt(amt), .left(1'b1), .arith(1'b0), .y(csh)
			);

			wire [76:0] cw_a2 = zc5 ? 77'd0 : tiny ? 77'd1 :
				{2'b00, csh[97:24], csh[23] | (|csh[22:0])};
			wire [76:0] pw_a2 = big ? 77'd1 : {27'd0, p5, 2'b00};

			reg v6;
			reg [TW-1:0] t6;
			reg [76:0] pw6, cw6;
			reg sub6, sp6, sc6, spec6;
			reg [11:0] eb6;
			reg [31:0] sres6;
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
			reg [TW-1:0] t7;
			reg [76:0] s1_7, s2_7;
			reg neg7, sr7, spec7;
			reg [11:0] eb7;
			reg [31:0] sres7;
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

			/* ---- C1: the magnitude, its leading zeros ---- */
			wire [76:0] sum7 = neg7 ? s2_7 : s1_7;
			reg [6:0] lz_c1;
			always @(*) begin
				lz_c1 = 7'd0;
				for (i = 0; i < 77; i = i + 1)
					if (sum7[i])
						lz_c1 = 7'd76 - i[6:0];
			end

			reg v8;
			reg [TW-1:0] t8;
			reg [76:0] sum8;
			reg [6:0] lz8;
			reg sr8, zero8, spec8;
			reg [11:0] eb8;
			reg [31:0] sres8;
			always @(posedge clk) begin
				sum8 <= sum7;
				lz8 <= lz_c1;
				zero8 <= sum7 == 77'd0;
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

			reg v9;
			reg [TW-1:0] t9;
			reg [24:0] m9;
			reg st9, sr9, zero9, spec9;
			reg [11:0] er9;
			reg [31:0] sres9;
			always @(posedge clk) begin
				m9 <= nrm[76:52];
				st9 <= |nrm[51:0];
				er9 <= er_c2;
				sr9 <= sr8;
				zero9 <= zero8;
				spec9 <= spec8;
				sres9 <= sres8;
				t9 <= t8;
			end

			/* ---- D1: round to nearest even ---- */
			wire up = m9[0] && (st9 || m9[1]);
			wire [24:0] mr_d1;
			wire [11:0] er1_d1;

			am_add #(.W(25)) u_rnd (.a({1'b0, m9[24:1]}), .b(25'd0), .ci(up), .s(mr_d1), .co(u_rnd_nc));
			am_add #(.W(12)) u_er1 (.a(er9), .b(12'd0), .ci(1'b1), .s(er1_d1), .co(u_er1_nc));

			reg v10;
			reg [TW-1:0] t10;
			reg [24:0] mr10;
			reg signed [11:0] er10, er1_10;
			reg sr10, zero10, spec10;
			reg [31:0] sres10;
			always @(posedge clk) begin
				mr10 <= mr_d1;
				er10 <= er9;
				er1_10 <= er1_d1;
				sr10 <= sr9;
				zero10 <= zero9;
				spec10 <= spec9;
				sres10 <= sres9;
				t10 <= t9;
			end

			/* ---- D2: the carry of the rounding, the range ---- */
			wire signed [11:0] ef = mr10[24] ? er1_10 : er10;
			wire [22:0] mf = mr10[24] ? mr10[23:1] : mr10[22:0];
			assign r_val = spec10 ? sres10 : zero10 ? 32'd0 :
				ef >= 12'sd255 ? {sr10, 8'hFF, 23'd0} : ef <= 12'sd0 ? {sr10, 31'd0} :
				{sr10, ef[7:0], mf};
			assign r_vld = v10;
			assign r_tag = t10;
			assign o_busy = |{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10};

			/* The valid bits. */
			always @(posedge clk) begin
				if (!rst_n)
					{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10} <= 10'd0;
				else
					{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10} <=
						{i_vld, v1, v2, v3, v4, v5, v6, v7, v8, v9};
			end

			wire unused_ok = &{1'b0, u_eab_nc, u_q150_nc, u_q175_nc, u_eb99_nc, u_k_nc, u_u_nc,
				u_ec2_nc, u_cp_nc, u_er_nc, u_rnd_nc, u_er1_nc, u_a1[11:7], rm, noc};
		end
	endgenerate
endmodule

`default_nettype wire
