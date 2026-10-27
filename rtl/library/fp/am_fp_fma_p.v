/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_fp_fma_p: fused a * b + c with one rounding under rm (am_fp_rnd's
 * modes; 6: RDN's sign of an exact zero sum), denormals flushed, NaN
 * 0x7FC00000; noc: no addend (fmul).  p is the product of the
 * significands (am_fp_fma has its own multiplier; atg_su_fpu shares one).
 * Supports:
 *   LAT = 0: combinational (0 cycles)
 *   LAT = 1: 2-stage pipelined (Stage 0+1 combinational, Stage 2 registered)
 *   LAT = 2: 3-stage pipelined (Stage 0: align, Stage 1: add, Stage 2: LOD+norm+round)
 * See spec/library/fp/am_fp_fma_p.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_fp_fma_p #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] a0,
	input wire [31:0] b0,
	input wire [31:0] c0,
	input wire [2:0] rm,
	input wire noc,
	input wire [47:0] p,
	output wire [31:0] r
);
	wire [31:0] a = a0[30:23] == 8'd0 ? {a0[31], 31'd0} : a0;
	wire [31:0] b = b0[30:23] == 8'd0 ? {b0[31], 31'd0} : b0;
	wire [31:0] c = c0[30:23] == 8'd0 ? {c0[31], 31'd0} : c0;
	wire sp = a[31] ^ b[31];
	wire sc = c[31];
	wire rdn = rm == 3'd2 || rm == 3'd6;
	wire nan_a = a[30:23] == 8'hFF && a[22:0] != 0;
	wire nan_b = b[30:23] == 8'hFF && b[22:0] != 0;
	wire nan_c = !noc && c[30:23] == 8'hFF && c[22:0] != 0;
	wire inf_a = a[30:23] == 8'hFF && a[22:0] == 0;
	wire inf_b = b[30:23] == 8'hFF && b[22:0] == 0;
	wire inf_c = !noc && c[30:23] == 8'hFF && c[22:0] == 0;
	wire za = a[30:23] == 8'd0;
	wire zb = b[30:23] == 8'd0;
	wire zc = noc || c[30:23] == 8'd0;
	wire [23:0] mc = zc ? 24'd0 : {1'b1, c[22:0]};
	wire [10:0] carry_unused;

	/* k: C's LSB relative to P's (units of P's LSB), the window has two bits
	 * below P's LSB: k = ec - ea - eb + 150 */
	wire [11:0] ab, c150, k, kadj, kp2;
	wire [4:0] rs;
	am_add #(.W(12)) u_ab (.a({4'd0, a[30:23]}), .b({4'd0, b[30:23]}), .ci(1'b0), .s(ab),
		.co(carry_unused[0]));
	am_add #(.W(12)) u_c150 (.a({4'd0, c[30:23]}), .b(12'd150), .ci(1'b0), .s(c150),
		.co(carry_unused[1]));
	am_sub #(.W(12)) u_k (.a(c150), .b(ab), .bi(1'b0), .d(k), .bo(carry_unused[2]));
	am_sub #(.W(12)) u_kadj (.a(k), .b(12'd49), .bi(1'b0), .d(kadj), .bo(carry_unused[3]));
	am_add #(.W(12)) u_kp2 (.a(k), .b(12'd2), .ci(1'b0), .s(kp2), .co(carry_unused[4]));
	am_sub #(.W(5)) u_rs (.a(5'd0), .b(kp2[4:0]), .bi(1'b0), .d(rs),
		.bo(carry_unused[5]));	/* 1..23 */
	wire signed [11:0] ks = k;
	wire kbig = ks > 12'sd49;
	wire kleft = ks >= -12'sd2;
	wire kright = ks > -12'sd26;
	wire [76:0] cs;
	am_shift #(.W(77), .SW(7)) u_cs (.a({53'd0, mc}), .amt(kleft ? kp2[6:0] : {2'd0, rs}), .left(kleft),
		.arith(1'b0), .y(cs));
	/* the sticky bit: the bits of mc below rs */
	wire [23:0] cmk;
	am_shift #(.W(24), .SW(5)) u_cmk (.a(24'hFFFFFF), .amt(rs), .left(1'b1), .arith(1'b0), .y(cmk));
	wire cst = |(mc & ~cmk);
	wire [11:0] adj = !zc && kbig ? kadj : 12'd0;
	wire [76:0] pw = !zc && kbig ? {76'd0, 1'b1} : {27'd0, p, 2'b00};
	wire [76:0] cw = zc ? 77'd0 : kbig ? {2'b00, mc, 51'd0} : kleft ? cs : kright ? {cs[76:1], cs[0] | cst} : 77'd1;
	/* the sum: pw + cw, pw - cw or cw - pw (the larger first) */
	wire same = zc || sp == sc;
	wire pge = pw >= cw;
	wire sr = same || pge ? sp : sc;

	/* Special cases determined in Stage 0 */
	wire spec_nan = nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za);
	wire spec_inf_ab = (inf_a || inf_b) && !spec_nan;
	wire spec_inf_c = inf_c && !spec_nan && !spec_inf_ab;
	wire spec_zero = (za || zb) && !spec_nan && !spec_inf_ab && !spec_inf_c;
	wire spec_hit = spec_nan || spec_inf_ab || spec_inf_c || spec_zero;
	wire [31:0] spec_res =
		spec_nan ? 32'h7FC00000 :
		spec_inf_ab ? (inf_c && sc != sp ? 32'h7FC00000 : {sp, 8'hFF, 23'd0}) :
		spec_inf_c ? c :
		(!zc ? c : noc ? {sp, 31'd0} : {rdn ? (sp | sc) : (sp & sc), 31'd0});

	/* --- Stage 0 -> Stage 1 Pipeline Register (LAT >= 2) --- */
	reg [76:0] r0_op_a;
	reg [76:0] r0_op_b;
	reg        r0_op_sub;
	reg        r0_sr;
	reg [11:0] r0_ab;
	reg [11:0] r0_adj;
	reg [2:0]  r0_rm;
	reg        r0_rdn;
	reg        r0_spec_hit;
	reg [31:0] r0_spec_res;

	always @(posedge clk) begin
		if (!rst_n) begin
			r0_op_a     <= 77'd0;
			r0_op_b     <= 77'd0;
			r0_op_sub   <= 1'b0;
			r0_sr       <= 1'b0;
			r0_ab       <= 12'd0;
			r0_adj      <= 12'd0;
			r0_rm       <= 3'd0;
			r0_rdn      <= 1'b0;
			r0_spec_hit <= 1'b0;
			r0_spec_res <= 32'd0;
		end else if (en) begin
			r0_op_a     <= same || pge ? pw : cw;
			r0_op_b     <= same || pge ? cw : pw;
			r0_op_sub   <= !same;
			r0_sr       <= sr;
			r0_ab       <= ab;
			r0_adj      <= adj;
			r0_rm       <= rm;
			r0_rdn      <= rdn;
			r0_spec_hit <= spec_hit;
			r0_spec_res <= spec_res;
		end
	end

	/* --- Stage 1: 77-bit add/sub --- */
	wire [76:0] s0_op_a     = (LAT >= 2) ? r0_op_a     : (same || pge ? pw : cw);
	wire [76:0] s0_op_b     = (LAT >= 2) ? r0_op_b     : (same || pge ? cw : pw);
	wire        s0_op_sub   = (LAT >= 2) ? r0_op_sub   : !same;
	wire        s0_sr       = (LAT >= 2) ? r0_sr       : sr;
	wire [11:0] s0_ab       = (LAT >= 2) ? r0_ab       : ab;
	wire [11:0] s0_adj      = (LAT >= 2) ? r0_adj      : adj;
	wire [2:0]  s0_rm       = (LAT >= 2) ? r0_rm       : rm;
	wire        s0_rdn      = (LAT >= 2) ? r0_rdn      : rdn;
	wire        s0_spec_hit = (LAT >= 2) ? r0_spec_hit : spec_hit;
	wire [31:0] s0_spec_res = (LAT >= 2) ? r0_spec_res : spec_res;

	wire [76:0] sum;
	am_addsub #(.W(77)) u_sum (.a(s0_op_a), .b(s0_op_b), .sub(s0_op_sub), .s(sum),
		.co(carry_unused[6]));

	/* --- Stage 1 -> Stage 2 Pipeline Register (LAT >= 1) --- */
	reg [76:0] r1_sum;
	reg        r1_sr;
	reg [11:0] r1_ab;
	reg [11:0] r1_adj;
	reg [2:0]  r1_rm;
	reg        r1_rdn;
	reg        r1_spec_hit;
	reg [31:0] r1_spec_res;

	always @(posedge clk) begin
		if (!rst_n) begin
			r1_sum      <= 77'd0;
			r1_sr       <= 1'b0;
			r1_ab       <= 12'd0;
			r1_adj      <= 12'd0;
			r1_rm       <= 3'd0;
			r1_rdn      <= 1'b0;
			r1_spec_hit <= 1'b0;
			r1_spec_res <= 32'd0;
		end else if (en) begin
			r1_sum      <= sum;
			r1_sr       <= s0_sr;
			r1_ab       <= s0_ab;
			r1_adj      <= s0_adj;
			r1_rm       <= s0_rm;
			r1_rdn      <= s0_rdn;
			r1_spec_hit <= s0_spec_hit;
			r1_spec_res <= s0_spec_res;
		end
	end

	/* --- Stage 2: LOD, Normalization, Rounding --- */
	wire [76:0] s1_sum      = (LAT >= 1) ? r1_sum      : sum;
	wire        s1_sr       = (LAT >= 1) ? r1_sr       : s0_sr;
	wire [11:0] s1_ab       = (LAT >= 1) ? r1_ab       : s0_ab;
	wire [11:0] s1_adj      = (LAT >= 1) ? r1_adj      : s0_adj;
	wire [2:0]  s1_rm       = (LAT >= 1) ? r1_rm       : s0_rm;
	wire        s1_rdn      = (LAT >= 1) ? r1_rdn      : s0_rdn;
	wire        s1_spec_hit = (LAT >= 1) ? r1_spec_hit : s0_spec_hit;
	wire [31:0] s1_spec_res = (LAT >= 1) ? r1_spec_res : s0_spec_res;

	/* normalised to bit 76; the exponent msb + ea + eb + adj - 175 */
	wire [6:0] msb;
	wire sum_nz;
	am_msb #(.W(77), .SW(7)) u_msb (.a(s1_sum), .n(msb), .nz(sum_nz));
	wire [6:0] nsh;
	wire [76:0] nrm;
	wire [11:0] t1, t2, er;
	am_sub #(.W(7)) u_nsh (.a(7'd76), .b(msb), .bi(1'b0), .d(nsh), .bo(carry_unused[7]));
	am_shift #(.W(77), .SW(7)) u_nrm (.a(s1_sum), .amt(nsh), .left(1'b1), .arith(1'b0), .y(nrm));
	am_add #(.W(12)) u_t1 (.a(s1_ab), .b(s1_adj), .ci(1'b0), .s(t1), .co(carry_unused[8]));
	am_add #(.W(12)) u_t2 (.a(t1), .b({5'd0, msb}), .ci(1'b0), .s(t2), .co(carry_unused[9]));
	am_sub #(.W(12)) u_er (.a(t2), .b(12'd175), .bi(1'b0), .d(er), .bo(carry_unused[10]));
	wire [31:0] rnd;
	am_fp_rnd #(.LAT(0)) u_rnd (.s(s1_sr), .e(er), .m(nrm[76:53]), .g(nrm[52]), .st(|nrm[51:0]), .rm(s1_rm), .r(rnd));

	assign r = s1_spec_hit ? s1_spec_res :
		!sum_nz ? {s1_rdn, 31'd0} : rnd;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, kp2[11:7], carry_unused, unused_lat0};
endmodule

`default_nettype wire
