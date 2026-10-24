/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_pack.vh: four 32-bit components to a pixel of a colour
 * attachment format, included inside a module after atg_fmt_info.vh.
 * tools/fmtmodel.py (pack) is the reference; spec/gpu/fmt/atg_fmt.md.
 *   atg_fmt_pack(c, fmt, wm)  {keep[127:0], raw[127:0]}: c = {c3, c2, c1,
 *       c0}, wm the write mask of R, G, B, A.  raw is the pixel as a
 *       little-endian integer, keep has a 1 for every bit not written (the
 *       masked components and the bits outside the pixel).  UNORM
 *       RNE(clamp01(f) x (2^b - 1)) with NaN and negative values (-0
 *       included) to 0, 16-bit floats to nearest even (overflow to
 *       infinity, NaN 0x7E00, denormals exact), 32-bit floats and integer
 *       formats the low bits.  sRGB formats take R, G and B as 8-bit codes
 *       in [7:0] (atg_fmt_srgbenc) and A as fp32.  A format without the
 *       colour-attachment feature writes nothing (keep all ones).
 *   atg_fmt_f2unorm(f, w)  w <= 16.   atg_fmt_f2h(f)  fp32 to fp16.
 */

function [15:0] atg_fmt_f2unorm;
	input [31:0] fp_f;
	input [5:0] fp_w;
	reg [47:0] fp_p;
	reg [15:0] fp_q;
	reg [31:0] fp_unused_q;
	reg [5:0] fp_sa;	/* 150 - e: 24..47 for e = 103..126 */
	reg fp_g, fp_st;
	begin
		fp_p = ({24'd0, 1'b1, fp_f[22:0]} << fp_w) - {24'd0, 1'b1, fp_f[22:0]};
		fp_sa = 6'd22 - fp_f[28:23];	/* 150 - e mod 64 */
		{fp_unused_q, fp_q} = fp_p >> fp_sa;
		fp_g = fp_p[fp_sa - 6'd1];
		fp_st = (fp_p & ((48'd1 << (fp_sa - 6'd1)) - 48'd1)) != 48'd0;
		if (fp_f[31] || (fp_f[30:23] == 8'hFF && fp_f[22:0] != 23'd0) || fp_f[30:23] < 8'd103)
			atg_fmt_f2unorm = 16'd0;
		else if (fp_f[30:23] >= 8'd127)
			atg_fmt_f2unorm = (16'd1 << fp_w) - 16'd1;
		else
			atg_fmt_f2unorm = fp_q + {15'd0, fp_g && (fp_st || fp_q[0])};
	end
endfunction

function [15:0] atg_fmt_f2h;
	input [31:0] fp_f;
	reg [23:0] fp_m;
	reg [14:0] fp_d;
	reg [8:0] fp_unused_d;
	reg [11:0] fp_q;
	reg [7:0] fp_ex;
	reg [4:0] fp_sh;	/* 126 - e: 14..24 for e = 102..112 */
	reg fp_g, fp_st;
	begin
		fp_m = {1'b1, fp_f[22:0]};
		fp_q = {1'b0, fp_m[23:13]} + {11'd0, fp_f[12] && (fp_f[11:0] != 12'd0 || fp_f[13])};
		fp_ex = fp_q[11] ? fp_f[30:23] - 8'd111 : fp_f[30:23] - 8'd112;
		fp_sh = 5'd30 - fp_f[27:23];	/* 126 - e mod 32 */
		{fp_unused_d, fp_d} = fp_m >> fp_sh;
		fp_g = fp_m[fp_sh - 5'd1];
		fp_st = (fp_m & ((24'd1 << (fp_sh - 5'd1)) - 24'd1)) != 24'd0;
		if (fp_f[30:23] == 8'hFF)
			atg_fmt_f2h = fp_f[22:0] != 23'd0 ? 16'h7E00 : {fp_f[31], 15'h7C00};
		else if (fp_f[30:23] >= 8'd113)
			atg_fmt_f2h = fp_ex >= 8'd31 || fp_f[30:23] > 8'd142 ? {fp_f[31], 15'h7C00} :
				{fp_f[31], fp_ex[4:0], fp_q[11:10] != 2'b01 ? 10'd0 : fp_q[9:0]};
		else if (fp_f[30:23] <= 8'd101)
			atg_fmt_f2h = {fp_f[31], 15'd0};
		else
			atg_fmt_f2h = {fp_f[31], fp_d + {14'd0, fp_g && (fp_st || fp_d[0])}};
	end
endfunction

function [255:0] atg_fmt_pack;
	input [127:0] fp_c;
	input [7:0] fp_fmt;
	input [3:0] fp_wm;
	reg [67:0] fp_inf;
	reg [127:0] fp_raw, fp_wr;
	reg [31:0] fp_v, fp_fld, fp_msk;
	reg [6:0] fp_pos;
	reg [5:0] fp_w;
	reg fp_col;
	integer fp_k;
	begin
		fp_inf = atg_fmt_info(fp_fmt);
		fp_col = (atg_fmt_feat(fp_fmt, 1'b0) & 26'h80) != 26'd0;	/* COLOR_ATTACHMENT */
		fp_raw = 128'd0;
		fp_wr = 128'd0;
		if (fp_col)
			for (fp_k = 0; fp_k < 4; fp_k = fp_k + 1)
				if (fp_k < {29'd0, fp_inf[8:6]} && fp_wm[fp_k]) begin
					fp_pos = fp_inf[16 + 13 * fp_k +: 7];
					fp_w = fp_inf[23 + 13 * fp_k +: 6];
					fp_msk = fp_w == 6'd32 ? 32'hFFFFFFFF : (32'd1 << fp_w) - 32'd1;
					fp_v = fp_c[32 * fp_k +: 32];
					case (fp_inf[11:9])
					ATG_FMT_UNORM: fp_fld = {16'd0, atg_fmt_f2unorm(fp_v, fp_w)};
					ATG_FMT_SRGB: fp_fld = fp_k < 3 ? {24'd0, fp_v[7:0]} :
						{16'd0, atg_fmt_f2unorm(fp_v, 6'd8)};
					ATG_FMT_SFLOAT:
						fp_fld = fp_w == 6'd32 ? fp_v : {16'd0, atg_fmt_f2h(fp_v)};
					default: fp_fld = fp_v;
					endcase
					fp_raw = fp_raw | ({96'd0, fp_fld & fp_msk} << fp_pos);
					fp_wr = fp_wr | ({96'd0, fp_msk} << fp_pos);
				end
		atg_fmt_pack = {~fp_wr, fp_raw};
	end
endfunction
