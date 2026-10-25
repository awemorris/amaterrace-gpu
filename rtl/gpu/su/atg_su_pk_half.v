/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pk_half: one 16-bit half of a lane of atg_su_pk, combinational:
 * packh's fp32 -> fp16 of xw (RNE, flushed, NaN 0x7E00) and, with ARITH,
 * the packed operation o on the halves ha, hb (rs2's half, after hsel's
 * swap) and hc: fadd2/fsub2/fmul2/ffma2 as one fused ha * hb + hc with one
 * rounding under r, fmin2/fmax2, the compares (0xFFFF/0; ge is the swapped
 * le), iadd2/isub2/imul2; sat clamps the float results to [0, 1].  (The
 * port names are not those of the functions of include/atg_su_fp16.vh.)  FP = 0
 * (PK_SHARED: the float operations are atg_su_fpu's) gives 0 for them.
 * The rules of include/atg_su_fp16.vh (denormals flushed on input and
 * output, canonical NaN 0x7E00); this module replaces its functions
 * atg_su_hfma and atg_su_f2h.  Reference: tools/gsi1fp.py.
 *
 * The arithmetic (docs/style.md, "Arithmetic") is shared between the
 * operations, none of which is needed with another: one am_mul 16 x 16
 * (the fma's 11 x 11 mantissas, imul2), one am_addsub of 37 bits (the
 * fma's aligned sum, iadd2/isub2), one am_sub of the exponent (the fma's
 * normalised exponent, packh's rebias) and one atg_su_hrnd (the fma's
 * rounding, packh's).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pk_half #(
	parameter ARITH = 1,	/* the packed arithmetic (atg_su_pk's PACKED) */
	parameter FP = 1	/* with ARITH: the float operations here (not PK_SHARED) */
) (
	input wire [3:0] o,
	input wire [15:0] ha,
	input wire [15:0] hb,
	input wire [15:0] hc,
	input wire [2:0] r,
	input wire sat,
	input wire [31:0] xw,
	output wire [15:0] y
);
`include "atg_su_uop.vh"
`include "atg_su_fp16.vh"

	localparam AR = ARITH != 0;
	localparam FL = ARITH != 0 && FP != 0;

	wire packh = o == ATG_PK_PACKH[3:0];
	wire is_int = o == ATG_PK_IADD2[3:0] || o == ATG_PK_ISUB2[3:0] || o == ATG_PK_IMUL2[3:0];

	/* ------------------------------------------- the fma's operands */

	/* fadd2 a * 1 + b, fsub2 a * 1 - b, fmul2 a * b (no addend), ffma2. */
	reg [15:0] fy, fz;
	reg fnoc;
	always @(*) begin
		fy = 16'h3C00;
		fz = hb;
		fnoc = 1'b0;
		case (o)
		ATG_PK_FSUB2[3:0]: fz = {!hb[15], hb[14:0]};
		ATG_PK_FMUL2[3:0]: begin
			fy = hb;
			fz = 16'd0;
			fnoc = 1'b1;
		end
		ATG_PK_FFMA2[3:0]: begin
			fy = hb;
			fz = hc;
		end
		default: ;
		endcase
	end

	wire [15:0] fa = atg_su_hflush(ha);
	wire [15:0] fb = atg_su_hflush(fy);
	wire [15:0] fc = atg_su_hflush(fz);
	wire [4:0] ea = fa[14:10];
	wire [4:0] eb = fb[14:10];
	wire [4:0] ec = fc[14:10];
	wire sp = fa[15] ^ fb[15];
	wire sc = fc[15];
	wire rdn = r == 3'd2;
	wire nan_a = ea == 5'h1F && fa[9:0] != 10'd0;
	wire nan_b = eb == 5'h1F && fb[9:0] != 10'd0;
	wire nan_c = !fnoc && ec == 5'h1F && fc[9:0] != 10'd0;
	wire inf_a = ea == 5'h1F && fa[9:0] == 10'd0;
	wire inf_b = eb == 5'h1F && fb[9:0] == 10'd0;
	wire inf_c = !fnoc && ec == 5'h1F && fc[9:0] == 10'd0;
	wire za = ea == 5'd0;
	wire zb = eb == 5'd0;
	wire zc = fnoc || ec == 5'd0;
	wire [10:0] ma = {!za, fa[9:0]};
	wire [10:0] mb = {!zb, fb[9:0]};
	wire [10:0] mc = zc ? 11'd0 : {1'b1, fc[9:0]};

	/* ------------------------------------------- the product (imul2's too) */

	wire [31:0] prod;
	am_mul #(.AW(16), .BW(16)) u_mul (
		.clk(1'b0), .en(1'b0), .a(is_int ? ha : {5'd0, ma}), .b(is_int ? hb : {5'd0, mb}),
		.p(prod)
	);
	wire [21:0] p = prod[21:0];

	/*
	 * The addend's place: d = ec - ea - eb, the distance of k = d + 25
	 * (the addend's exponent less the product's, in the product's bits
	 * {p, 00}).  k > 23 (d >= -1): the addend alone with the product a
	 * sticky bit, the exponent ec + 2; -12 <= k <= 23: the addend shifted
	 * left by k + 12 = d + 37 in a 47-bit value of 10 more fraction bits,
	 * whose bits below the sum's are its sticky bit; below, a sticky bit.
	 */
	wire [9:0] t;
	wire [9:0] d;
	wire [9:0] kx;
	wire [2:0] co_unused;
	am_add #(.W(10)) u_t (.a({5'd0, ea}), .b({5'd0, eb}), .ci(1'b0), .s(t), .co(co_unused[0]));
	am_sub #(.W(10)) u_d (.a({5'd0, ec}), .b(t), .bi(1'b0), .d(d), .bo(co_unused[1]));
	wire big = $signed(d) >= -10'sd1;
	wire near = $signed(d) >= -10'sd37;
	am_add #(.W(10)) u_k (
		.a(big ? {5'd0, ec} : d), .b(big ? 10'd2 : 10'd37), .ci(1'b0), .s(kx),
		.co(co_unused[2])
	);
	wire [46:0] zal;
	am_shift #(.W(47), .SW(6)) u_al (
		.a({36'd0, mc}), .amt(kx[5:0]), .left(1'b1), .arith(1'b0), .y(zal)
	);
	wire [36:0] pw = !zc && big ? 37'd1 : {13'd0, p, 2'b00};
	wire [36:0] cw = zc ? 37'd0 : big ? {1'b0, mc, 25'd0} :
		near ? {zal[46:11], zal[10] | (|zal[9:0])} : 37'd1;

	/* ------------------------------------------- the sum (iadd2/isub2's too) */

	wire eff_sub = !(zc || sp == sc);
	wire swap = eff_sub && pw < cw;
	wire sr = swap ? sc : sp;
	wire [36:0] sum;
	wire sum_co_unused;
	am_addsub #(.W(37)) u_sum (
		.a(is_int ? {21'd0, ha} : swap ? cw : pw), .b(is_int ? {21'd0, hb} : swap ? pw : cw),
		.sub(is_int ? o == ATG_PK_ISUB2[3:0] : eff_sub), .s(sum), .co(sum_co_unused)
	);

	/* The leading zeros of the sum (the lowest one of it reversed). */
	wire [36:0] rev;
	genvar j;
	generate
	for (j = 0; j < 37; j = j + 1) begin : g_rev
		assign rev[j] = sum[36 - j];
	end
	endgenerate
	reg [5:0] lz;
	integer i;
	always @(*) begin
		lz = 6'd0;
		for (i = 36; i >= 0; i = i - 1)
			if (rev[i])
				lz = i[5:0];
	end
	wire [36:0] nrm;
	am_shift #(.W(37), .SW(6)) u_nrm (
		.a(sum), .amt(lz), .left(1'b1), .arith(1'b0), .y(nrm)
	);

	/* ------------------------------------------- packh's fp32 operand */

	wire [31:0] xf = xw[30:23] == 8'd0 ? {xw[31], 31'd0} : xw;	/* flushed */

	/*
	 * The exponent: the fma's ea + eb + adj - lz - 1 (adj = k - 23 when
	 * k > 23: then ea + eb + adj = ec + 2, kx), packh's e - 112.
	 */
	wire f2h = packh || !FL;
	wire [9:0] er;
	wire er_bo_unused;
	am_sub #(.W(10)) u_er (
		.a(f2h ? {2'd0, xf[30:23]} : !zc && big ? kx : t), .b(f2h ? 10'd112 : {4'd0, lz}),
		.bi(!f2h), .d(er), .bo(er_bo_unused)
	);
	wire [15:0] hr;
	atg_su_hrnd u_rnd (
		.s(f2h ? xf[31] : sr), .e(er), .m(f2h ? {1'b1, xf[22:13]} : nrm[36:26]),
		.g(f2h ? xf[12] : nrm[25]), .st(f2h ? |xf[11:0] : |nrm[24:0]),
		.rm(f2h ? 3'd0 : r), .h(hr)
	);

	/* ------------------------------------------- the results */

	wire [15:0] xh = xf[30:23] == 8'hFF ? (xf[22:0] != 23'd0 ? 16'h7E00 : {xf[31], 5'h1F, 10'd0}) :
		xf[30:23] == 8'd0 ? {xf[31], 15'd0} : hr;

	reg [15:0] fma;
	always @(*) begin
		if (nan_a || nan_b || nan_c || (inf_a && zb) || (inf_b && za))
			fma = 16'h7E00;
		else if (inf_a || inf_b)
			fma = inf_c && sc != sp ? 16'h7E00 : {sp, 5'h1F, 10'd0};
		else if (inf_c)
			fma = fc;
		else if (za || zb)
			fma = !zc ? fc : fnoc ? {sp, 15'd0} : {rdn ? (sp | sc) : (sp & sc), 15'd0};
		else if (sum == 37'd0)
			fma = {rdn, 15'd0};
		else
			fma = hr;
	end

	/* The compares: lt, ge (the swapped le), eq, ne. */
	reg [15:0] ca, cb;
	reg [1:0] cop;
	always @(*) begin
		ca = ha;
		cb = hb;
		case (o)
		ATG_PK_FCMPLT2[3:0]: cop = 2'd1;
		ATG_PK_FCMPGE2[3:0]: begin
			ca = hb;
			cb = ha;
			cop = 2'd2;
		end
		ATG_PK_FCMPEQ2[3:0]: cop = 2'd0;
		default: cop = 2'd3;
		endcase
	end

	reg [15:0] v;
	always @(*)
		case (o)
		ATG_PK_FADD2[3:0], ATG_PK_FSUB2[3:0], ATG_PK_FMUL2[3:0], ATG_PK_FFMA2[3:0]:
			v = FL ? fma : 16'd0;
		ATG_PK_FMIN2[3:0]: v = FL ? atg_su_hminmax(ha, hb, 1'b0) : 16'd0;
		ATG_PK_FMAX2[3:0]: v = FL ? atg_su_hminmax(ha, hb, 1'b1) : 16'd0;
		ATG_PK_IADD2[3:0], ATG_PK_ISUB2[3:0]: v = sum[15:0];
		ATG_PK_IMUL2[3:0]: v = prod[15:0];
		ATG_PK_FCMPLT2[3:0], ATG_PK_FCMPGE2[3:0], ATG_PK_FCMPEQ2[3:0], ATG_PK_FCMPNE2[3:0]:
			v = FL ? {16{atg_su_hcmp(ca, cb, cop)}} : 16'd0;
		default: v = 16'd0;
		endcase

	assign y = packh ? xh : !AR ? 16'd0 : sat && o <= ATG_PK_FMAX2[3:0] ? atg_su_hsat(v) : v;

	wire unused_ok = &{1'b0, prod[31:22], sum[36:16], kx[9:6], er_bo_unused, sum_co_unused,
		co_unused};
endmodule

`default_nettype wire
