/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_cvt: one component of a texel to 32 bits, pipelined: bit for
 * bit atg_fmt_comp(i_raw, i_inf, i_k, i_sten) of include/atg_fmt_unpack.vh
 * (tools/fmtmodel.py unpack; spec/gpu/fmt/atg_fmt.md): UNORM and SNORM to
 * the nearest fp32, the 16-bit, packed unsigned and E5B9G9R9 floats
 * exactly, integers zero or sign extended, sRGB R, G, B through
 * atg_srgb_dec and A as UNORM, the stencil aspect, and the constants of
 * the components a format does not have.
 *
 * One conversion a cycle, no stall: the inputs in cycle 0, o_val in cycle
 * 5 (a register).  Stages: U1 (the component's field and mask, the
 * constant results) R1; U2 (SNORM's magnitude, the inputs of the
 * normalisations, the integer and sRGB results) R2; U3 (UNORM's repeated
 * bits and their leading zeros; the 10-bit leading zeros of the floats)
 * R3; U4 (UNORM normalised; the 16-bit, packed and E5 floats) R4; U5
 * (UNORM's rounding, SNORM's sign, the selection) R5.
 * See spec/gpu/fmt/atg_fmt_cvt.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_cvt (
	input wire clk,
	input wire [127:0] i_raw,
	input wire [67:0] i_inf,	/* the format's atg_fmt_info word */
	input wire [1:0] i_k,	/* the component */
	input wire i_sten,	/* the stencil aspect */
	output reg [31:0] o_val
);
	`include "atg_fmt_info.vh"
	`include "atg_srgb.vh"
	wire u_neg_nc, u_wm1_nc, u_e5b_nc, u_hexp_nc, u_hden_nc, u_e5x_nc, u_q_nc, u_e127_nc, u_e126_nc;	/* the carries not used */
	integer i;

	/* The result's kinds (the selection of U5). */
	localparam [2:0] K_CST = 3'd0, K_DIR = 3'd1, K_UN = 3'd2, K_SN = 3'd3, K_HF = 3'd4,
		K_E5 = 3'd5;

	/* ---- U1 ---- */
	wire [2:0] ty = i_inf[11:9];
	wire isint = ty == ATG_FMT_UINT || ty == ATG_FMT_SINT;
	reg cst_u1;
	reg [31:0] cval_u1;
	reg [6:0] pos;
	reg [5:0] w_u1;
	always @(*) begin
		cst_u1 = 1'b1;
		if (!i_inf[0] || i_inf[14])
			cval_u1 = i_k == 2'd3 ? 32'h3F800000 : 32'd0;
		else if (i_sten)
			cval_u1 = i_k == 2'd3 ? (i_inf[13] ? 32'd1 : 32'h3F800000) :
				i_k == 2'd0 && i_inf[13] ? {24'd0, i_raw[31:24]} : 32'd0;
		else if ({1'b0, i_k} >= i_inf[8:6])
			cval_u1 = i_k == 2'd3 ? (isint ? 32'd1 : 32'h3F800000) : 32'd0;
		else begin
			cval_u1 = 32'd0;
			cst_u1 = 1'b0;
		end
		case (i_k)
		2'd0: {w_u1, pos} = i_inf[28:16];
		2'd1: {w_u1, pos} = i_inf[41:29];
		2'd2: {w_u1, pos} = i_inf[54:42];
		default: {w_u1, pos} = i_inf[67:55];
		endcase
	end
	wire [159:0] rawx = {32'd0, i_raw};
	wire [31:0] fsel = rawx[{1'b0, pos} +: 32];
	reg [31:0] msk_u1;
	always @(*)
		for (i = 0; i < 32; i = i + 1)
			msk_u1[i] = i[5:0] < w_u1;

	reg cst1;
	reg [31:0] cval1, fld1;
	reg [5:0] w1;
	reg [2:0] ty1;
	reg [1:0] k1;
	reg [4:0] e5e1;
	always @(posedge clk) begin
		cst1 <= cst_u1;
		cval1 <= cval_u1;
		fld1 <= fsel & msk_u1;
		w1 <= w_u1;
		ty1 <= ty;
		k1 <= i_k;
		e5e1 <= i_raw[31:27];
	end

	/* ---- U2 ---- */
	wire w8 = w1 == 6'd8;
	wire neg = w8 ? fld1[7] : fld1[15];
	wire [15:0] n16;

	am_sub #(.W(16)) u_neg (.a(16'd0), .b(fld1[15:0]), .bi(1'b0), .d(n16), .bo(u_neg_nc));

	wire [15:0] mag = neg ? (w8 ? {8'd0, n16[7:0]} : n16) : fld1[15:0];
	wire sn = ty1 == ATG_FMT_SNORM;
	wire [5:0] wm1;

	am_sub #(.W(6)) u_wm1 (.a(w1), .b(6'd1), .bi(1'b0), .d(wm1), .bo(u_wm1_nc));

	wire [23:0] uc = sn ? {8'd0, mag} : fld1[23:0];
	wire [5:0] uw = sn ? wm1 : ty1 == ATG_FMT_SRGB ? 6'd8 : w1;
	wire snmin = neg && mag == (w8 ? 16'h0080 : 16'h8000);
	/* the inputs of the one normalisation of the floats */
	wire [4:0] he = ty1 == ATG_FMT_SFLOAT ? fld1[14:10] : w1 == 6'd11 ? fld1[10:6] : fld1[9:5];
	wire [9:0] x = ty1 == ATG_FMT_SFLOAT ? fld1[9:0] : ty1 == ATG_FMT_UFLOAT ?
		(w1 == 6'd11 ? {fld1[5:0], 4'd0} : {fld1[4:0], 5'd0}) : {1'b0, fld1[8:0]};
	wire hs = ty1 == ATG_FMT_SFLOAT && fld1[15];
	/* SINT: the field's top bit (w - 1) above it */
	wire [32:0] fx = {fld1, 1'b0};
	reg [31:0] msk2;
	always @(*)
		for (i = 0; i < 32; i = i + 1)
			msk2[i] = i[5:0] < w1;
	wire [31:0] sint = fld1 | (fx[w1] ? ~msk2 : 32'd0);
	reg [2:0] kind_u2;
	reg [31:0] dir_u2;
	always @(*) begin
		dir_u2 = fld1;
		kind_u2 = K_DIR;
		if (cst1) begin
			kind_u2 = K_CST;
			dir_u2 = cval1;
		end else
			case (ty1)
			ATG_FMT_UNORM: kind_u2 = K_UN;
			ATG_FMT_SNORM: kind_u2 = K_SN;
			ATG_FMT_UINT: dir_u2 = fld1;
			ATG_FMT_SINT: dir_u2 = sint;
			ATG_FMT_SFLOAT: kind_u2 = w1 == 6'd32 ? K_DIR : K_HF;
			ATG_FMT_SRGB:
				if (k1 != 2'd3)
					dir_u2 = atg_srgb_dec(fld1[7:0]);
				else
					kind_u2 = K_UN;
			ATG_FMT_UFLOAT: kind_u2 = K_HF;
			default: kind_u2 = K_E5;
			endcase
	end
	wire [7:0] e5b;

	am_add #(.W(8)) u_e5b (.a(8'd112), .b({3'd0, e5e1}), .ci(1'b0), .s(e5b), .co(u_e5b_nc));

	reg [2:0] kind2;
	reg [31:0] dir2;
	reg [23:0] uc2;
	reg [5:0] uw2;
	reg neg2, snmin2, hs2;
	reg [4:0] he2;
	reg [9:0] x2;
	reg [7:0] e5b2;
	always @(posedge clk) begin
		kind2 <= kind_u2;
		dir2 <= dir_u2;
		uc2 <= uc;
		uw2 <= uw;
		neg2 <= neg;
		snmin2 <= snmin;
		he2 <= he;
		x2 <= x;
		hs2 <= hs;
		e5b2 <= e5b;
	end

	/* ---- U3: c / (2^w - 1) is 0.ccc... (atg_fmt_unorm) ---- */
	reg [79:0] r_u3;
	reg [4:0] lz_u3;
	reg found_u3;
	always @(*) begin
		case (uw2)
		6'd1: r_u3 = {80{uc2[0]}};
		6'd2: r_u3 = {40{uc2[1:0]}};
		6'd4: r_u3 = {20{uc2[3:0]}};
		6'd5: r_u3 = {16{uc2[4:0]}};
		6'd6: r_u3 = {uc2[5:0], {12{uc2[5:0]}}, uc2[5:4]};
		6'd7: r_u3 = {uc2[6:0], {10{uc2[6:0]}}, uc2[6:4]};
		6'd8: r_u3 = {10{uc2[7:0]}};
		6'd10: r_u3 = {8{uc2[9:0]}};
		6'd11: r_u3 = {uc2[10:0], {6{uc2[10:0]}}, uc2[10:8]};
		6'd15: r_u3 = {uc2[14:0], {4{uc2[14:0]}}, uc2[14:10]};
		6'd16: r_u3 = {5{uc2[15:0]}};
		default: r_u3 = {uc2, uc2, uc2, uc2[23:16]};
		endcase
		lz_u3 = 5'd0;
		found_u3 = 1'b0;
		for (i = 0; i < 24; i = i + 1)
			if (!found_u3 && r_u3[79 - i]) begin
				lz_u3 = i[4:0];
				found_u3 = 1'b1;
			end
	end
	/* the 10-bit leading zeros of the floats' mantissa */
	reg [3:0] hlz_u3;
	reg hfound;
	always @(*) begin
		hlz_u3 = 4'd0;
		hfound = 1'b0;
		for (i = 0; i < 10; i = i + 1)
			if (!hfound && x2[9 - i]) begin
				hlz_u3 = i[3:0];
				hfound = 1'b1;
			end
	end

	reg [2:0] kind3;
	reg [31:0] dir3;
	reg [71:0] r3;
	reg [4:0] lz3;
	reg found3, neg3, snmin3, hs3;
	reg [4:0] he3;
	reg [9:0] x3;
	reg [3:0] hlz3;
	reg [7:0] e5b3;
	always @(posedge clk) begin
		kind3 <= kind2;
		dir3 <= dir2;
		r3 <= r_u3[79:8];
		lz3 <= lz_u3;
		found3 <= found_u3;
		neg3 <= neg2;
		snmin3 <= snmin2;
		hs3 <= hs2;
		he3 <= he2;
		x3 <= x2;
		hlz3 <= hlz_u3;
		e5b3 <= e5b2;
	end

	/* ---- U4 ---- */
	wire [71:0] um;	/* the leading one at bit 71 (dropped) */

	am_shift #(.W(72), .SW(5)) u_un (.a(r3), .amt(lz3), .left(1'b1), .arith(1'b0), .y(um));

	wire [9:0] fsh;
	wire [7:0] hexp, hden, e5x;

	am_shift #(.W(10), .SW(4)) u_hf (.a(x3), .amt(hlz3), .left(1'b1), .arith(1'b0), .y(fsh));
	am_add #(.W(8)) u_hexp (.a({3'd0, he3}), .b(8'd112), .ci(1'b0), .s(hexp), .co(u_hexp_nc));
	am_sub #(.W(8)) u_hden (.a(8'd112), .b({4'd0, hlz3}), .bi(1'b0), .d(hden), .bo(u_hden_nc));
	am_sub #(.W(8)) u_e5x (.a(e5b3), .b({4'd0, hlz3}), .bi(1'b0), .d(e5x), .bo(u_e5x_nc));

	/* f: the bits below the leading one (x << (lz + 1)) */
	wire [9:0] f = {fsh[8:0], 1'b0};
	reg [31:0] hval;
	always @(*) begin
		if (kind3 == K_E5)
			hval = x3[8:0] == 9'd0 ? 32'd0 : {1'b0, e5x, f[9:1], 14'd0};
		else if (he3 == 5'd31)
			hval = x3 != 10'd0 ? 32'h7FC00000 : {hs3, 31'h7F800000};
		else if (he3 == 5'd0)
			hval = x3 == 10'd0 ? {hs3, 31'd0} : {hs3, hden, f, 13'd0};
		else
			hval = {hs3, hexp, x3, 13'd0};
	end

	reg [2:0] kind4;
	reg [31:0] dir4;
	reg [23:0] um4;	/* bits 70:47 */
	reg st4;
	reg [4:0] lz4;
	reg found4, neg4, snmin4;
	always @(posedge clk) begin
		kind4 <= kind3;
		dir4 <= kind3 == K_HF || kind3 == K_E5 ? hval : dir3;
		um4 <= um[70:47];
		st4 <= |um[46:0];
		lz4 <= lz3;
		found4 <= found3;
		neg4 <= neg3;
		snmin4 <= snmin3;
	end

	/* ---- U5: UNORM's rounding (never a tie), SNORM ---- */
	wire [23:0] q;
	wire [7:0] e127, e126;

	am_add #(.W(24)) u_q (.a({1'b0, um4[23:1]}), .b(24'd0),
		.ci(um4[0] && (st4 || um4[1])), .s(q), .co(u_q_nc));
	am_sub #(.W(8)) u_e127 (.a(8'd127), .b({3'd0, lz4}), .bi(1'b0), .d(e127), .bo(u_e127_nc));
	am_sub #(.W(8)) u_e126 (.a(8'd126), .b({3'd0, lz4}), .bi(1'b0), .d(e126), .bo(u_e126_nc));

	wire [31:0] u = !found4 ? 32'd0 : q[23] ? {1'b0, e127, 23'd0} : {1'b0, e126, q[22:0]};
	always @(posedge clk)
		o_val <= kind4 == K_UN ? u :
			kind4 == K_SN ? (snmin4 ? 32'hBF800000 : {neg4 | u[31], u[30:0]}) : dir4;
	wire unused_ok = &{1'b0, i_inf[15], i_inf[12], i_inf[5:1], um[71], fsh[9], u_neg_nc, u_wm1_nc, u_e5b_nc, u_hexp_nc, u_hden_nc, u_e5x_nc, u_q_nc, u_e127_nc, u_e126_nc};
endmodule

`default_nettype wire
