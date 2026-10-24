/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_unpack.vh: a texel of any format to four 32-bit components,
 * included inside a module after atg_srgb.vh and atg_fmt_info.vh.
 * tools/fmtmodel.py (unpack) is the reference; spec/gpu/fmt/atg_fmt.md.
 *   atg_fmt_unpack(raw, fmt, stencil)  {is_int, c3, c2, c1, c0}: raw is
 *       the texel's bytes as a little-endian integer.  UNORM c / (2^b - 1)
 *       and SNORM max(c / (2^(b-1) - 1), -1) to the nearest fp32 (even),
 *       16-bit floats and the packed unsigned floats exactly (infinities
 *       kept, NaN 0x7FC00000), UINT and SINT zero and sign extended, sRGB
 *       R, G, B through atg_srgb_dec and A as UNORM.  Missing components
 *       read 0, 0, 0 and 1.0 (integer 1 for integer formats).  stencil:
 *       the stencil aspect of D24_UNORM_S8_UINT, (s, 0, 0, 1) as integers.
 *       A format without an entry, and a compressed block, read (0, 0, 0,
 *       1.0).
 *   atg_fmt_unorm(c, w)   c / (2^w - 1), w in 1, 2, 4-8, 10, 11, 15, 16,
 *       24: c / (2^w - 1) is 0.ccc... in binary, so the leading 72 bits
 *       of c repeated give the fp32 and its rounding (never a tie).
 *   atg_fmt_h2f(h), atg_fmt_uf2f(v, mb), atg_fmt_e5(m, e)  exact.
 */

function [31:0] atg_fmt_unorm;
	input [23:0] fu_c;
	input [5:0] fu_w;
	reg [79:0] fu_r;
	reg [70:0] fu_m;
	reg fu_unused_lead;
	reg [4:0] fu_lz;
	reg [23:0] fu_q;
	reg fu_g, fu_st, fu_found;
	integer fu_i;
	begin
		case (fu_w)
		6'd1: fu_r = {80{fu_c[0]}};
		6'd2: fu_r = {40{fu_c[1:0]}};
		6'd4: fu_r = {20{fu_c[3:0]}};
		6'd5: fu_r = {16{fu_c[4:0]}};
		6'd6: fu_r = {fu_c[5:0], {12{fu_c[5:0]}}, fu_c[5:4]};
		6'd7: fu_r = {fu_c[6:0], {10{fu_c[6:0]}}, fu_c[6:4]};
		6'd8: fu_r = {10{fu_c[7:0]}};
		6'd10: fu_r = {8{fu_c[9:0]}};
		6'd11: fu_r = {fu_c[10:0], {6{fu_c[10:0]}}, fu_c[10:8]};
		6'd15: fu_r = {fu_c[14:0], {4{fu_c[14:0]}}, fu_c[14:10]};
		6'd16: fu_r = {5{fu_c[15:0]}};
		default: fu_r = {fu_c, fu_c, fu_c, fu_c[23:16]};
		endcase
		fu_lz = 5'd0;
		fu_found = 1'b0;
		for (fu_i = 0; fu_i < 24; fu_i = fu_i + 1)
			if (!fu_found && fu_r[79 - fu_i]) begin
				fu_lz = fu_i[4:0];
				fu_found = 1'b1;
			end
		/* the leading one goes to bit 71 (dropped); mantissa [70:48] */
		{fu_unused_lead, fu_m} = fu_r[79:8] << fu_lz;
		fu_g = fu_m[47];
		fu_st = fu_m[46:0] != 47'd0;
		fu_q = {1'b0, fu_m[70:48]} + {23'd0, fu_g && (fu_st || fu_m[48])};
		if (!fu_found)
			atg_fmt_unorm = 32'd0;
		else if (fu_q[23])
			atg_fmt_unorm = {1'b0, 8'd127 - {3'd0, fu_lz}, 23'd0};
		else
			atg_fmt_unorm = {1'b0, 8'd126 - {3'd0, fu_lz}, fu_q[22:0]};
	end
endfunction

function [31:0] atg_fmt_snorm;
	input [15:0] fu_c;
	input [5:0] fu_w;
	reg [15:0] fu_mag;
	reg [31:0] fu_u;	/* [31] is 0 */
	reg fu_neg;
	begin
		fu_neg = fu_w == 6'd8 ? fu_c[7] : fu_c[15];
		fu_mag = fu_neg ? (fu_w == 6'd8 ? {8'd0, 8'd0 - fu_c[7:0]} : 16'd0 - fu_c) : fu_c;
		fu_u = atg_fmt_unorm({8'd0, fu_mag}, fu_w - 6'd1);
		if (fu_neg && fu_mag == (fu_w == 6'd8 ? 16'h0080 : 16'h8000))
			atg_fmt_snorm = 32'hBF800000;
		else
			atg_fmt_snorm = {fu_neg | fu_u[31], fu_u[30:0]};
	end
endfunction

/* The leading zeros of a 10-bit field (0 for 0). */
function [3:0] atg_fmt_lz10;
	input [9:0] fu_m;
	integer fu_i;
	reg fu_found;
	begin
		atg_fmt_lz10 = 4'd0;
		fu_found = 1'b0;
		for (fu_i = 0; fu_i < 10; fu_i = fu_i + 1)
			if (!fu_found && fu_m[9 - fu_i]) begin
				atg_fmt_lz10 = fu_i[3:0];
				fu_found = 1'b1;
			end
	end
endfunction

function [31:0] atg_fmt_h2f;
	input [15:0] fu_h;
	reg [3:0] fu_lz;
	reg [9:0] fu_f;
	begin
		fu_lz = atg_fmt_lz10(fu_h[9:0]);
		fu_f = fu_h[9:0] << (fu_lz + 4'd1);
		if (fu_h[14:10] == 5'd31)
			atg_fmt_h2f = fu_h[9:0] != 10'd0 ? 32'h7FC00000 : {fu_h[15], 31'h7F800000};
		else if (fu_h[14:10] == 5'd0)
			atg_fmt_h2f = fu_h[9:0] == 10'd0 ? {fu_h[15], 31'd0} :
				{fu_h[15], 8'd112 - {4'd0, fu_lz}, fu_f, 13'd0};
		else
			atg_fmt_h2f = {fu_h[15], {3'd0, fu_h[14:10]} + 8'd112, fu_h[9:0], 13'd0};
	end
endfunction

/* An 11-bit (mb 6) or 10-bit (mb 5) unsigned float: 5 exponent bits above
 * mb mantissa bits, bias 15. */
function [31:0] atg_fmt_uf2f;
	input [10:0] fu_v;
	input [5:0] fu_mb;
	reg [4:0] fu_e;
	reg [9:0] fu_m, fu_f;
	reg [3:0] fu_lz;
	begin
		fu_e = fu_mb == 6'd6 ? fu_v[10:6] : fu_v[9:5];
		/* the mantissa left aligned in 10 bits */
		fu_m = fu_mb == 6'd6 ? {fu_v[5:0], 4'd0} : {fu_v[4:0], 5'd0};
		fu_lz = atg_fmt_lz10(fu_m);
		fu_f = fu_m << (fu_lz + 4'd1);
		if (fu_e == 5'd31)
			atg_fmt_uf2f = fu_m != 10'd0 ? 32'h7FC00000 : 32'h7F800000;
		else if (fu_e == 5'd0)
			atg_fmt_uf2f = fu_m == 10'd0 ? 32'd0 :
				{1'b0, 8'd112 - {4'd0, fu_lz}, fu_f, 13'd0};
		else
			atg_fmt_uf2f = {1'b0, {3'd0, fu_e} + 8'd112, fu_m, 13'd0};
	end
endfunction

/* m x 2^(e - 24): a component of E5B9G9R9. */
function [31:0] atg_fmt_e5;
	input [8:0] fu_m;
	input [4:0] fu_e;
	reg [3:0] fu_lz;	/* the leading zeros of m, plus 1 */
	reg [8:0] fu_f;
	begin
		fu_lz = atg_fmt_lz10({1'b0, fu_m});
		fu_f = fu_m << fu_lz;
		atg_fmt_e5 = fu_m == 9'd0 ? 32'd0 :
			{1'b0, 8'd112 + {3'd0, fu_e} - {4'd0, fu_lz}, fu_f, 14'd0};
	end
endfunction

function [128:0] atg_fmt_unpack;
	input [127:0] fu_raw;
	input [7:0] fu_fmt;
	input fu_stencil;
	reg [67:0] fu_inf;
	reg [127:0] fu_o;
	reg [31:0] fu_fld, fu_msk, fu_v;
	reg [6:0] fu_pos;
	reg [5:0] fu_w;
	reg fu_int;
	integer fu_k;
	begin
		fu_inf = atg_fmt_info(fu_fmt);
		fu_int = fu_inf[11:9] == ATG_FMT_UINT || fu_inf[11:9] == ATG_FMT_SINT;
		fu_o = {fu_int ? 32'd1 : 32'h3F800000, 96'd0};
		if (!fu_inf[0] || fu_inf[14]) begin
			fu_int = 1'b0;
			fu_o = {32'h3F800000, 96'd0};
		end else if (fu_stencil) begin
			fu_int = fu_inf[13];
			fu_o = fu_inf[13] ? {32'd1, 64'd0, 24'd0, fu_raw[31:24]} : {32'h3F800000, 96'd0};
		end else
			for (fu_k = 0; fu_k < 4; fu_k = fu_k + 1)
				if (fu_k < {29'd0, fu_inf[8:6]}) begin
					fu_pos = fu_inf[16 + 13 * fu_k +: 7];
					fu_w = fu_inf[23 + 13 * fu_k +: 6];
					fu_msk = fu_w == 6'd32 ? 32'hFFFFFFFF : (32'd1 << fu_w) - 32'd1;
					fu_fld = fu_raw[fu_pos +: 32] & fu_msk;
					case (fu_inf[11:9])
					ATG_FMT_UNORM: fu_v = atg_fmt_unorm(fu_fld[23:0], fu_w);
					ATG_FMT_SNORM: fu_v = atg_fmt_snorm(fu_fld[15:0], fu_w);
					ATG_FMT_UINT: fu_v = fu_fld;
					ATG_FMT_SINT:
						fu_v = fu_fld | (fu_fld[fu_w[4:0] - 5'd1] ? ~fu_msk : 32'd0);
					ATG_FMT_SFLOAT:
						fu_v = fu_w == 6'd32 ? fu_fld : atg_fmt_h2f(fu_fld[15:0]);
					ATG_FMT_SRGB: fu_v = fu_k < 3 ? atg_srgb_dec(fu_fld[7:0]) :
						atg_fmt_unorm(fu_fld[23:0], 6'd8);
					ATG_FMT_UFLOAT: fu_v = atg_fmt_uf2f(fu_fld[10:0], fu_w - 6'd5);
					default: fu_v = atg_fmt_e5(fu_fld[8:0], fu_raw[31:27]);
					endcase
					fu_o[32 * fu_k +: 32] = fu_v;
				end
		atg_fmt_unpack = {fu_int, fu_o};
	end
endfunction
