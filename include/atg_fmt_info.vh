/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_info.vh: the format table of the VF, the TU and the ROP, by
 * GhciFormat ID (ghci.md section 8.5), included inside a module
 * (the conversions are the modules of rtl/gpu/fmt).
 *   atg_fmt_info(fmt)  [0] valid, [5:1] bytes of a texel (or of a
 *       compressed block), [8:6] components, [11:9] type (ATG_FMT_*),
 *       [12] depth, [13] stencil in [31:24] (D24_UNORM_S8_UINT), [14]
 *       compressed block, [15] 0; component c (R, G, B, A) at 16 + 13c:
 *       [6:0] its lowest bit in the texel (a little-endian integer),
 *       [12:7] its width.  0 for a format the GPU does not have.
 *   atg_fmt_feat(fmt, etc)  {buffer[12:0], optimal[12:0]}: the
 *       format feature flags of the fixed-function units (sampled with
 *       blit source, linear filter, colour attachment with blit
 *       destination, blend, depth/stencil attachment; vertex buffer);
 *       linear tiling has the optimal ones.  etc: the ETC2/EAC decoder
 *       is present (the compressed formats are reported).
 */

localparam [2:0] ATG_FMT_UNORM = 3'd0;
localparam [2:0] ATG_FMT_SNORM = 3'd1;
localparam [2:0] ATG_FMT_UINT = 3'd2;
localparam [2:0] ATG_FMT_SINT = 3'd3;
localparam [2:0] ATG_FMT_SFLOAT = 3'd4;
localparam [2:0] ATG_FMT_SRGB = 3'd5;
localparam [2:0] ATG_FMT_UFLOAT = 3'd6;	/* B10G11R11: 11- and 10-bit unsigned floats */
localparam [2:0] ATG_FMT_E5 = 3'd7;	/* E5B9G9R9: a shared exponent in [31:27] */

function [12:0] atg_fmt_c;
	input [6:0] fi_pos;
	input [5:0] fi_w;
	atg_fmt_c = {fi_w, fi_pos};
endfunction

function [67:0] atg_fmt_i;
	input [4:0] fi_bytes;
	input [2:0] fi_n;
	input [2:0] fi_ty;
	input [2:0] fi_fl;	/* {block, stencil, depth} */
	input [12:0] fi_c0, fi_c1, fi_c2, fi_c3;
	atg_fmt_i = {fi_c3, fi_c2, fi_c1, fi_c0, 1'b0, fi_fl, fi_ty, fi_n, fi_bytes, 1'b1};
endfunction

function [67:0] atg_fmt_info;
	input [7:0] fi_fmt;
	case (fi_fmt)
	8'h01:	/* GHCI_FMT_B4G4R4A4_UNORM_P16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd4, 6'd4), atg_fmt_c(7'd8, 6'd4),
			atg_fmt_c(7'd12, 6'd4), atg_fmt_c(7'd0, 6'd4));
	8'h02:	/* GHCI_FMT_R5G6B5_UNORM_P16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd3, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd11, 6'd5), atg_fmt_c(7'd5, 6'd6),
			atg_fmt_c(7'd0, 6'd5), atg_fmt_c(7'd0, 6'd0));
	8'h03:	/* GHCI_FMT_A1R5G5B5_UNORM_P16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd10, 6'd5), atg_fmt_c(7'd5, 6'd5),
			atg_fmt_c(7'd0, 6'd5), atg_fmt_c(7'd15, 6'd1));
	8'h04:	/* GHCI_FMT_A2B10G10R10_UNORM_P32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd10, 6'd10),
			atg_fmt_c(7'd20, 6'd10), atg_fmt_c(7'd30, 6'd2));
	8'h05:	/* GHCI_FMT_A2B10G10R10_UINT_P32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd10, 6'd10),
			atg_fmt_c(7'd20, 6'd10), atg_fmt_c(7'd30, 6'd2));
	8'h06:	/* GHCI_FMT_B10G11R11_UFLOAT_P32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd3, ATG_FMT_UFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd11), atg_fmt_c(7'd11, 6'd11),
			atg_fmt_c(7'd22, 6'd10), atg_fmt_c(7'd0, 6'd0));
	8'h07:	/* GHCI_FMT_E5B9G9R9_UFLOAT_P32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd3, ATG_FMT_E5, 3'b000,
			atg_fmt_c(7'd0, 6'd9), atg_fmt_c(7'd9, 6'd9),
			atg_fmt_c(7'd18, 6'd9), atg_fmt_c(7'd0, 6'd0));
	8'h10:	/* GHCI_FMT_R8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h11:	/* GHCI_FMT_R8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h12:	/* GHCI_FMT_R8_UINT */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h13:	/* GHCI_FMT_R8_SINT */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h18:	/* GHCI_FMT_R8G8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h19:	/* GHCI_FMT_R8G8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h1A:	/* GHCI_FMT_R8G8_UINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h1B:	/* GHCI_FMT_R8G8_SINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h20:	/* GHCI_FMT_R8G8B8A8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h21:	/* GHCI_FMT_R8G8B8A8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h22:	/* GHCI_FMT_R8G8B8A8_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h23:	/* GHCI_FMT_R8G8B8A8_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h24:	/* GHCI_FMT_R8G8B8A8_SRGB */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SRGB, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h28:	/* GHCI_FMT_B8G8R8A8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h2C:	/* GHCI_FMT_B8G8R8A8_SRGB */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SRGB, 3'b000,
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'h30:	/* GHCI_FMT_R16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h31:	/* GHCI_FMT_R16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h32:	/* GHCI_FMT_R16_UINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h33:	/* GHCI_FMT_R16_SINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h34:	/* GHCI_FMT_R16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h38:	/* GHCI_FMT_R16G16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h39:	/* GHCI_FMT_R16G16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h3A:	/* GHCI_FMT_R16G16_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h3B:	/* GHCI_FMT_R16G16_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h3C:	/* GHCI_FMT_R16G16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h40:	/* GHCI_FMT_R16G16B16A16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'h41:	/* GHCI_FMT_R16G16B16A16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'h42:	/* GHCI_FMT_R16G16B16A16_UINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'h43:	/* GHCI_FMT_R16G16B16A16_SINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'h44:	/* GHCI_FMT_R16G16B16A16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'h52:	/* GHCI_FMT_R32_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h53:	/* GHCI_FMT_R32_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h54:	/* GHCI_FMT_R32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h5A:	/* GHCI_FMT_R32G32_UINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h5B:	/* GHCI_FMT_R32G32_SINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h5C:	/* GHCI_FMT_R32G32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h62:	/* GHCI_FMT_R32G32B32_UINT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'h63:	/* GHCI_FMT_R32G32B32_SINT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'h64:	/* GHCI_FMT_R32G32B32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'h6A:	/* GHCI_FMT_R32G32B32A32_UINT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'h6B:	/* GHCI_FMT_R32G32B32A32_SINT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'h6C:	/* GHCI_FMT_R32G32B32A32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'h70:	/* GHCI_FMT_D16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UNORM, 3'b001,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h71:	/* GHCI_FMT_X8D24_UNORM_P32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UNORM, 3'b001,
			atg_fmt_c(7'd0, 6'd24), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h72:	/* GHCI_FMT_D32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SFLOAT, 3'b001,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h74:	/* GHCI_FMT_D24_UNORM_S8_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UNORM, 3'b011,
			atg_fmt_c(7'd0, 6'd24), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h90:	/* GHCI_FMT_ETC2_R8G8B8_UNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd3, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h91:	/* GHCI_FMT_ETC2_R8G8B8_SRGB_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd3, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h92:	/* GHCI_FMT_ETC2_R8G8B8A1_UNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h93:	/* GHCI_FMT_ETC2_R8G8B8A1_SRGB_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h94:	/* GHCI_FMT_ETC2_R8G8B8A8_UNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h95:	/* GHCI_FMT_ETC2_R8G8B8A8_SRGB_BLK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h96:	/* GHCI_FMT_EAC_R11_UNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd1, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h97:	/* GHCI_FMT_EAC_R11_SNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd1, ATG_FMT_SNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h98:	/* GHCI_FMT_EAC_R11G11_UNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd2, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'h99:	/* GHCI_FMT_EAC_R11G11_SNORM_BLK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd2, ATG_FMT_SNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	default:
		atg_fmt_info = 68'd0;
	endcase
endfunction

function [25:0] atg_fmt_feat;
	input [7:0] fi_fmt;
	input fi_etc;
	reg [6:0] fi_l;	/* {block, S, F, C, B, D, V} */
	begin
		case (fi_fmt)
		8'h01: fi_l = 7'b0110000;	/* GHCI_FMT_B4G4R4A4_UNORM_P16 */
		8'h02: fi_l = 7'b0111100;	/* GHCI_FMT_R5G6B5_UNORM_P16 */
		8'h03: fi_l = 7'b0111100;	/* GHCI_FMT_A1R5G5B5_UNORM_P16 */
		8'h04: fi_l = 7'b0111101;	/* GHCI_FMT_A2B10G10R10_UNORM_P32 */
		8'h05: fi_l = 7'b0101000;	/* GHCI_FMT_A2B10G10R10_UINT_P32 */
		8'h06: fi_l = 7'b0110000;	/* GHCI_FMT_B10G11R11_UFLOAT_P32 */
		8'h07: fi_l = 7'b0110000;	/* GHCI_FMT_E5B9G9R9_UFLOAT_P32 */
		8'h10: fi_l = 7'b0111101;	/* GHCI_FMT_R8_UNORM */
		8'h11: fi_l = 7'b0110001;	/* GHCI_FMT_R8_SNORM */
		8'h12: fi_l = 7'b0101001;	/* GHCI_FMT_R8_UINT */
		8'h13: fi_l = 7'b0101001;	/* GHCI_FMT_R8_SINT */
		8'h18: fi_l = 7'b0111101;	/* GHCI_FMT_R8G8_UNORM */
		8'h19: fi_l = 7'b0110001;	/* GHCI_FMT_R8G8_SNORM */
		8'h1A: fi_l = 7'b0101001;	/* GHCI_FMT_R8G8_UINT */
		8'h1B: fi_l = 7'b0101001;	/* GHCI_FMT_R8G8_SINT */
		8'h20: fi_l = 7'b0111101;	/* GHCI_FMT_R8G8B8A8_UNORM */
		8'h21: fi_l = 7'b0110001;	/* GHCI_FMT_R8G8B8A8_SNORM */
		8'h22: fi_l = 7'b0101001;	/* GHCI_FMT_R8G8B8A8_UINT */
		8'h23: fi_l = 7'b0101001;	/* GHCI_FMT_R8G8B8A8_SINT */
		8'h24: fi_l = 7'b0111100;	/* GHCI_FMT_R8G8B8A8_SRGB */
		8'h28: fi_l = 7'b0111101;	/* GHCI_FMT_B8G8R8A8_UNORM */
		8'h2C: fi_l = 7'b0111100;	/* GHCI_FMT_B8G8R8A8_SRGB */
		8'h30: fi_l = 7'b0000001;	/* GHCI_FMT_R16_UNORM */
		8'h31: fi_l = 7'b0000001;	/* GHCI_FMT_R16_SNORM */
		8'h32: fi_l = 7'b0101001;	/* GHCI_FMT_R16_UINT */
		8'h33: fi_l = 7'b0101001;	/* GHCI_FMT_R16_SINT */
		8'h34: fi_l = 7'b0111101;	/* GHCI_FMT_R16_SFLOAT */
		8'h38: fi_l = 7'b0000001;	/* GHCI_FMT_R16G16_UNORM */
		8'h39: fi_l = 7'b0000001;	/* GHCI_FMT_R16G16_SNORM */
		8'h3A: fi_l = 7'b0101001;	/* GHCI_FMT_R16G16_UINT */
		8'h3B: fi_l = 7'b0101001;	/* GHCI_FMT_R16G16_SINT */
		8'h3C: fi_l = 7'b0111101;	/* GHCI_FMT_R16G16_SFLOAT */
		8'h40: fi_l = 7'b0000001;	/* GHCI_FMT_R16G16B16A16_UNORM */
		8'h41: fi_l = 7'b0000001;	/* GHCI_FMT_R16G16B16A16_SNORM */
		8'h42: fi_l = 7'b0101001;	/* GHCI_FMT_R16G16B16A16_UINT */
		8'h43: fi_l = 7'b0101001;	/* GHCI_FMT_R16G16B16A16_SINT */
		8'h44: fi_l = 7'b0111101;	/* GHCI_FMT_R16G16B16A16_SFLOAT */
		8'h52: fi_l = 7'b0101001;	/* GHCI_FMT_R32_UINT */
		8'h53: fi_l = 7'b0101001;	/* GHCI_FMT_R32_SINT */
		8'h54: fi_l = 7'b0101001;	/* GHCI_FMT_R32_SFLOAT */
		8'h5A: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32_UINT */
		8'h5B: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32_SINT */
		8'h5C: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32_SFLOAT */
		8'h62: fi_l = 7'b0000001;	/* GHCI_FMT_R32G32B32_UINT */
		8'h63: fi_l = 7'b0000001;	/* GHCI_FMT_R32G32B32_SINT */
		8'h64: fi_l = 7'b0000001;	/* GHCI_FMT_R32G32B32_SFLOAT */
		8'h6A: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32B32A32_UINT */
		8'h6B: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32B32A32_SINT */
		8'h6C: fi_l = 7'b0101001;	/* GHCI_FMT_R32G32B32A32_SFLOAT */
		8'h70: fi_l = 7'b0110010;	/* GHCI_FMT_D16_UNORM */
		8'h71: fi_l = 7'b0110010;	/* GHCI_FMT_X8D24_UNORM_P32 */
		8'h72: fi_l = 7'b0110010;	/* GHCI_FMT_D32_SFLOAT */
		8'h74: fi_l = 7'b0110010;	/* GHCI_FMT_D24_UNORM_S8_UINT */
		8'h90: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8_UNORM_BLK */
		8'h91: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8_SRGB_BLK */
		8'h92: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8A1_UNORM_BLK */
		8'h93: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8A1_SRGB_BLK */
		8'h94: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8A8_UNORM_BLK */
		8'h95: fi_l = 7'b1110000;	/* GHCI_FMT_ETC2_R8G8B8A8_SRGB_BLK */
		8'h96: fi_l = 7'b1110000;	/* GHCI_FMT_EAC_R11_UNORM_BLK */
		8'h97: fi_l = 7'b1110000;	/* GHCI_FMT_EAC_R11_SNORM_BLK */
		8'h98: fi_l = 7'b1110000;	/* GHCI_FMT_EAC_R11G11_UNORM_BLK */
		8'h99: fi_l = 7'b1110000;	/* GHCI_FMT_EAC_R11G11_SNORM_BLK */
		default: fi_l = 7'd0;
		endcase
		if (fi_l[6] && !fi_etc)
			fi_l = 7'd0;
		/* SAMPLED 0x1, VERTEX_BUFFER 0x40, COLOR_ATTACHMENT 0x80, BLEND 0x100,
		 * DEPTH_STENCIL 0x200, BLIT_SRC 0x400, BLIT_DST 0x800, FILTER_LINEAR 0x1000 */
		atg_fmt_feat = {6'd0, fi_l[0], 6'd0, fi_l[4], fi_l[3], fi_l[5], fi_l[1], fi_l[2], fi_l[3],
			6'd0, fi_l[5]};
	end
endfunction
