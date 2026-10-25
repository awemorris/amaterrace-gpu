/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_ffma_p: fused a * b + c with one rounding under rm (atg_su_rnd's
 * modes; 6: RDN's sign of an exact zero sum), denormals flushed, NaN
 * 0x7FC00000; noc: no addend (fmul).  p is the product of the
 * significands (atg_su_fsig of include/atg_su_fp.vh: a multiplier shared
 * with other operations, atg_su_fpu; atg_su_ffma has its own).  The former
 * function atg_su_ffma_p of include/atg_su_fp.vh (tools/gsi1fp.py).
 * Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_ffma_p (
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
	wire [76:0] sum;
	am_addsub #(.W(77)) u_sum (.a(same || pge ? pw : cw), .b(same || pge ? cw : pw), .sub(!same), .s(sum),
		.co(carry_unused[6]));
	wire sr = same || pge ? sp : sc;
	/* normalised to bit 76; the exponent msb + ea + eb + adj - 175 */
	wire [6:0] msb;
	wire sum_nz;
	am_msb #(.W(77), .SW(7)) u_msb (.a(sum), .n(msb), .nz(sum_nz));
	wire [6:0] nsh;
	wire [76:0] nrm;
	wire [11:0] t1, t2, er;
	am_sub #(.W(7)) u_nsh (.a(7'd76), .b(msb), .bi(1'b0), .d(nsh), .bo(carry_unused[7]));
	am_shift #(.W(77), .SW(7)) u_nrm (.a(sum), .amt(nsh), .left(1'b1), .arith(1'b0), .y(nrm));
	am_add #(.W(12)) u_t1 (.a(ab), .b(adj), .ci(1'b0), .s(t1), .co(carry_unused[8]));
	am_add #(.W(12)) u_t2 (.a(t1), .b({5'd0, msb}), .ci(1'b0), .s(t2), .co(carry_unused[9]));
	am_sub #(.W(12)) u_er (.a(t2), .b(12'd175), .bi(1'b0), .d(er), .bo(carry_unused[10]));
	wire [31:0] rnd;
	atg_su_rnd u_rnd (.s(sr), .e(er), .m(nrm[76:53]), .g(nrm[52]), .st(|nrm[51:0]), .rm(rm), .r(rnd));

	assign r = nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za) ? 32'h7FC00000 :
		inf_a || inf_b ? (inf_c && sc != sp ? 32'h7FC00000 : {sp, 8'hFF, 23'd0}) :
		inf_c ? c :
		za || zb ? (!zc ? c : noc ? {sp, 31'd0} : {rdn ? (sp | sc) : (sp & sc), 31'd0}) :
		!sum_nz ? {rdn, 31'd0} : rnd;

	wire unused_ok = &{1'b0, kp2[11:7]};
endmodule

`default_nettype wire
