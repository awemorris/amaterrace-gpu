/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_comp: component k of a texel to 32 bits, combinational (the
 * former function atg_fmt_comp of include/atg_fmt_unpack.vh; atg_fmt_cvt
 * is its pipelined form; tools/fmtmodel.py unpack; spec/gpu/fmt/atg_fmt.md):
 * UNORM c / (2^b - 1) and SNORM max(c / (2^(b-1) - 1), -1) to the nearest
 * fp32 (even), 16-bit floats, the packed unsigned floats and E5B9G9R9
 * exactly (infinities kept, NaN 0x7FC00000), UINT and SINT zero and sign
 * extended, sRGB R, G, B through atg_srgb_dec and A as UNORM; missing
 * components 0, 0, 0 and 1.0 (integer 1 for integer formats); stencil:
 * the stencil aspect of D24_UNORM_S8_UINT, (s, 0, 0, 1) as integers; a
 * format without an entry, and a compressed block, (0, 0, 0, 1.0).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_comp (
	input wire [127:0] raw,	/* the texel's bytes as a little-endian integer */
	input wire [67:0] inf,	/* the format's atg_fmt_info word */
	input wire [1:0] k,
	input wire sten,
	output wire [31:0] v
);
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"

	wire is_int = inf[11:9] == ATG_FMT_UINT || inf[11:9] == ATG_FMT_SINT;
	wire [2:0] ty = inf[11:9];
	/* the component's place, width, field */
	wire [6:0] pos = k == 2'd0 ? inf[16 +: 7] : k == 2'd1 ? inf[29 +: 7] : k == 2'd2 ? inf[42 +: 7] :
		inf[55 +: 7];
	wire [5:0] w = k == 2'd0 ? inf[23 +: 6] : k == 2'd1 ? inf[36 +: 6] : k == 2'd2 ? inf[49 +: 6] :
		inf[62 +: 6];
	reg [31:0] msk;
	integer b;
	always @(*)
		for (b = 0; b < 32; b = b + 1)
			msk[b] = b < w;
	wire [31:0] fld = raw[pos +: 32] & msk;
	/* one atg_fmt_unorm for UNORM, SNORM's magnitude and sRGB's alpha */
	wire neg = w == 6'd8 ? fld[7] : fld[15];
	wire [15:0] nf;
	wire [5:0] wm1;
	wire [31:0] u;
	wire [5:0] carry_unused;
	am_sub #(.W(16)) u_nf (.a(16'd0), .b(w == 6'd8 ? {8'd0, fld[7:0]} : fld[15:0]), .bi(1'b0), .d(nf),
		.bo(carry_unused[0]));
	wire [15:0] mag = neg ? (w == 6'd8 ? {8'd0, nf[7:0]} : nf) : fld[15:0];
	wire sn = ty == ATG_FMT_SNORM;
	am_sub #(.W(6)) u_wm1 (.a(w), .b(6'd0), .bi(1'b1), .d(wm1), .bo(carry_unused[1]));
	atg_fmt_unorm u_u (.c(sn ? {8'd0, mag} : fld[23:0]), .w(sn ? wm1 : ty == ATG_FMT_SRGB ? 6'd8 : w),
		.f(u));
	/* one normalisation for the 16-bit and packed unsigned floats and
	 * E5B9G9R9's components: x the mantissa left aligned in 10 bits (E5: 0
	 * and the 9 bits), lz its leading zeros, f the bits below its leading one */
	wire [4:0] he = ty == ATG_FMT_SFLOAT ? fld[14:10] : w == 6'd11 ? fld[10:6] : fld[9:5];
	wire [9:0] x = ty == ATG_FMT_SFLOAT ? fld[9:0] : ty == ATG_FMT_UFLOAT ?
		(w == 6'd11 ? {fld[5:0], 4'd0} : {fld[4:0], 5'd0}) : {1'b0, fld[8:0]};
	wire hs = ty == ATG_FMT_SFLOAT && fld[15];
	reg [3:0] lz;
	reg found;
	integer i;
	always @(*) begin
		lz = 4'd0;
		found = 1'b0;
		for (i = 0; i < 10; i = i + 1)
			if (!found && x[9 - i]) begin
				lz = i[3:0];
				found = 1'b1;
			end
	end
	wire [3:0] lz1;
	wire [9:0] f;
	wire [7:0] eb, el;
	wire [4:0] sw1;
	am_add #(.W(4)) u_lz1 (.a(lz), .b(4'd0), .ci(1'b1), .s(lz1), .co(carry_unused[2]));
	am_shift #(.W(10), .SW(4)) u_f (.a(x), .amt(lz1), .left(1'b1), .arith(1'b0), .y(f));
	/* the exponents: 112 + e (normal), 112 - lz (denormal), 112 + e5 - lz (E5) */
	am_add #(.W(8)) u_eb (.a(8'd112), .b({3'd0, ty == ATG_FMT_E5 ? raw[31:27] : he}), .ci(1'b0), .s(eb),
		.co(carry_unused[3]));
	am_sub #(.W(8)) u_el (.a(eb), .b({4'd0, lz}), .bi(1'b0), .d(el), .bo(carry_unused[4]));
	wire [31:0] hf = he == 5'd31 ? (x != 10'd0 ? 32'h7FC00000 : {hs, 31'h7F800000}) :
		he == 5'd0 ? (x == 10'd0 ? {hs, 31'd0} : {hs, el, f, 13'd0}) : {hs, eb, x, 13'd0};
	/* SINT: the sign bit w - 1 */
	am_sub #(.W(5)) u_sw1 (.a(w[4:0]), .b(5'd0), .bi(1'b1), .d(sw1), .bo(carry_unused[5]));
	reg [31:0] cv;
	always @(*)
		case (ty)
		ATG_FMT_UNORM: cv = u;
		ATG_FMT_SNORM: cv = neg && mag == (w == 6'd8 ? 16'h0080 : 16'h8000) ? 32'hBF800000 :
			{neg | u[31], u[30:0]};
		ATG_FMT_UINT: cv = fld;
		ATG_FMT_SINT: cv = fld | (fld[sw1] ? ~msk : 32'd0);
		ATG_FMT_SFLOAT: cv = w == 6'd32 ? fld : hf;
		ATG_FMT_SRGB: cv = k != 2'd3 ? atg_srgb_dec(fld[7:0]) : u;
		ATG_FMT_UFLOAT: cv = hf;
		default: cv = x[8:0] == 9'd0 ? 32'd0 : {1'b0, el, f[9:1], 14'd0};
		endcase
	assign v = !inf[0] || inf[14] ? (k == 2'd3 ? 32'h3F800000 : 32'd0) :
		sten ? (k == 2'd3 ? (inf[13] ? 32'd1 : 32'h3F800000) : k == 2'd0 && inf[13] ? {24'd0, raw[31:24]} :
		32'd0) : {1'b0, k} >= inf[8:6] ? (k == 2'd3 ? (is_int ? 32'd1 : 32'h3F800000) : 32'd0) : cv;

	wire unused_ok = &{1'b0, carry_unused, inf[15], inf[12], inf[5:1], f[0]};
endmodule

`default_nettype wire
