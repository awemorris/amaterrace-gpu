/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_info.vh: the format table of the VF, the TU and the ROP, by
 * VkFormat value (docs/ghci.md section 8.5), included inside a module
 * (the conversions are the modules of rtl/gpu/fmt).  tools/fmtmodel.py
 * (info_word, features) is the reference; spec/gpu/fmt/atg_fmt.md.
 *   atg_fmt_info(fmt)  [0] valid, [5:1] bytes of a texel (or of a
 *       compressed block), [8:6] components, [11:9] type (ATG_FMT_*),
 *       [12] depth, [13] stencil in [31:24] (D24_UNORM_S8_UINT), [14]
 *       compressed block, [15] 0; component c (R, G, B, A) at 16 + 13c:
 *       [6:0] its lowest bit in the texel (a little-endian integer),
 *       [12:7] its width.  0 for a format the GPU does not have.
 *   atg_fmt_feat(fmt, etc)  {buffer[12:0], optimal[12:0]}: the
 *       VkFormatFeatureFlags of the fixed-function units (sampled with
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
	8'd3:	/* B4G4R4A4_UNORM_PACK16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd4, 6'd4), atg_fmt_c(7'd8, 6'd4),
			atg_fmt_c(7'd12, 6'd4), atg_fmt_c(7'd0, 6'd4));
	8'd4:	/* R5G6B5_UNORM_PACK16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd3, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd11, 6'd5), atg_fmt_c(7'd5, 6'd6),
			atg_fmt_c(7'd0, 6'd5), atg_fmt_c(7'd0, 6'd0));
	8'd8:	/* A1R5G5B5_UNORM_PACK16 */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd10, 6'd5), atg_fmt_c(7'd5, 6'd5),
			atg_fmt_c(7'd0, 6'd5), atg_fmt_c(7'd15, 6'd1));
	8'd9:	/* R8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd10:	/* R8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd13:	/* R8_UINT */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd14:	/* R8_SINT */
		atg_fmt_info = atg_fmt_i(5'd1, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd16:	/* R8G8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd17:	/* R8G8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd20:	/* R8G8_UINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd21:	/* R8G8_SINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd37:	/* R8G8B8A8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd38:	/* R8G8B8A8_SNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd41:	/* R8G8B8A8_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd42:	/* R8G8B8A8_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd43:	/* R8G8B8A8_SRGB */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SRGB, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd44:	/* B8G8R8A8_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd50:	/* B8G8R8A8_SRGB */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SRGB, 3'b000,
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd51:	/* A8B8G8R8_UNORM_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd52:	/* A8B8G8R8_SNORM_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd55:	/* A8B8G8R8_UINT_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd56:	/* A8B8G8R8_SINT_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd57:	/* A8B8G8R8_SRGB_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_SRGB, 3'b000,
			atg_fmt_c(7'd0, 6'd8), atg_fmt_c(7'd8, 6'd8),
			atg_fmt_c(7'd16, 6'd8), atg_fmt_c(7'd24, 6'd8));
	8'd64:	/* A2B10G10R10_UNORM_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd10, 6'd10),
			atg_fmt_c(7'd20, 6'd10), atg_fmt_c(7'd30, 6'd2));
	8'd68:	/* A2B10G10R10_UINT_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd10), atg_fmt_c(7'd10, 6'd10),
			atg_fmt_c(7'd20, 6'd10), atg_fmt_c(7'd30, 6'd2));
	8'd70:	/* R16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd71:	/* R16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd74:	/* R16_UINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd75:	/* R16_SINT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd76:	/* R16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd77:	/* R16G16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd78:	/* R16G16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd81:	/* R16G16_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd82:	/* R16G16_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd83:	/* R16G16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd2, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd91:	/* R16G16B16A16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'd92:	/* R16G16B16A16_SNORM */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SNORM, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'd95:	/* R16G16B16A16_UINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'd96:	/* R16G16B16A16_SINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'd97:	/* R16G16B16A16_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd16, 6'd16),
			atg_fmt_c(7'd32, 6'd16), atg_fmt_c(7'd48, 6'd16));
	8'd98:	/* R32_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd99:	/* R32_SINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd100:	/* R32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd101:	/* R32G32_UINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd102:	/* R32G32_SINT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd103:	/* R32G32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd2, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd104:	/* R32G32B32_UINT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'd105:	/* R32G32B32_SINT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'd106:	/* R32G32B32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd12, 3'd3, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd0, 6'd0));
	8'd107:	/* R32G32B32A32_UINT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_UINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'd108:	/* R32G32B32A32_SINT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SINT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'd109:	/* R32G32B32A32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd32, 6'd32),
			atg_fmt_c(7'd64, 6'd32), atg_fmt_c(7'd96, 6'd32));
	8'd122:	/* B10G11R11_UFLOAT_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd3, ATG_FMT_UFLOAT, 3'b000,
			atg_fmt_c(7'd0, 6'd11), atg_fmt_c(7'd11, 6'd11),
			atg_fmt_c(7'd22, 6'd10), atg_fmt_c(7'd0, 6'd0));
	8'd123:	/* E5B9G9R9_UFLOAT_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd3, ATG_FMT_E5, 3'b000,
			atg_fmt_c(7'd0, 6'd9), atg_fmt_c(7'd9, 6'd9),
			atg_fmt_c(7'd18, 6'd9), atg_fmt_c(7'd0, 6'd0));
	8'd124:	/* D16_UNORM */
		atg_fmt_info = atg_fmt_i(5'd2, 3'd1, ATG_FMT_UNORM, 3'b001,
			atg_fmt_c(7'd0, 6'd16), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd125:	/* X8_D24_UNORM_PACK32 */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UNORM, 3'b001,
			atg_fmt_c(7'd0, 6'd24), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd126:	/* D32_SFLOAT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_SFLOAT, 3'b001,
			atg_fmt_c(7'd0, 6'd32), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd129:	/* D24_UNORM_S8_UINT */
		atg_fmt_info = atg_fmt_i(5'd4, 3'd1, ATG_FMT_UNORM, 3'b011,
			atg_fmt_c(7'd0, 6'd24), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd147:	/* ETC2_R8G8B8_UNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd3, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd148:	/* ETC2_R8G8B8_SRGB_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd3, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd149:	/* ETC2_R8G8B8A1_UNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd150:	/* ETC2_R8G8B8A1_SRGB_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd4, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd151:	/* ETC2_R8G8B8A8_UNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd152:	/* ETC2_R8G8B8A8_SRGB_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd4, ATG_FMT_SRGB, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd153:	/* EAC_R11_UNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd1, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd154:	/* EAC_R11_SNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd8, 3'd1, ATG_FMT_SNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd155:	/* EAC_R11G11_UNORM_BLOCK */
		atg_fmt_info = atg_fmt_i(5'd16, 3'd2, ATG_FMT_UNORM, 3'b100,
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0),
			atg_fmt_c(7'd0, 6'd0), atg_fmt_c(7'd0, 6'd0));
	8'd156:	/* EAC_R11G11_SNORM_BLOCK */
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
		8'd3: fi_l = 7'b0110000;	/* B4G4R4A4_UNORM_PACK16 */
		8'd4: fi_l = 7'b0111100;	/* R5G6B5_UNORM_PACK16 */
		8'd8: fi_l = 7'b0111100;	/* A1R5G5B5_UNORM_PACK16 */
		8'd9: fi_l = 7'b0111101;	/* R8_UNORM */
		8'd10: fi_l = 7'b0110001;	/* R8_SNORM */
		8'd13: fi_l = 7'b0101001;	/* R8_UINT */
		8'd14: fi_l = 7'b0101001;	/* R8_SINT */
		8'd16: fi_l = 7'b0111101;	/* R8G8_UNORM */
		8'd17: fi_l = 7'b0110001;	/* R8G8_SNORM */
		8'd20: fi_l = 7'b0101001;	/* R8G8_UINT */
		8'd21: fi_l = 7'b0101001;	/* R8G8_SINT */
		8'd37: fi_l = 7'b0111101;	/* R8G8B8A8_UNORM */
		8'd38: fi_l = 7'b0110001;	/* R8G8B8A8_SNORM */
		8'd41: fi_l = 7'b0101001;	/* R8G8B8A8_UINT */
		8'd42: fi_l = 7'b0101001;	/* R8G8B8A8_SINT */
		8'd43: fi_l = 7'b0111100;	/* R8G8B8A8_SRGB */
		8'd44: fi_l = 7'b0111101;	/* B8G8R8A8_UNORM */
		8'd50: fi_l = 7'b0111100;	/* B8G8R8A8_SRGB */
		8'd51: fi_l = 7'b0111101;	/* A8B8G8R8_UNORM_PACK32 */
		8'd52: fi_l = 7'b0110001;	/* A8B8G8R8_SNORM_PACK32 */
		8'd55: fi_l = 7'b0101001;	/* A8B8G8R8_UINT_PACK32 */
		8'd56: fi_l = 7'b0101001;	/* A8B8G8R8_SINT_PACK32 */
		8'd57: fi_l = 7'b0111100;	/* A8B8G8R8_SRGB_PACK32 */
		8'd64: fi_l = 7'b0111101;	/* A2B10G10R10_UNORM_PACK32 */
		8'd68: fi_l = 7'b0101000;	/* A2B10G10R10_UINT_PACK32 */
		8'd70: fi_l = 7'b0000001;	/* R16_UNORM */
		8'd71: fi_l = 7'b0000001;	/* R16_SNORM */
		8'd74: fi_l = 7'b0101001;	/* R16_UINT */
		8'd75: fi_l = 7'b0101001;	/* R16_SINT */
		8'd76: fi_l = 7'b0111101;	/* R16_SFLOAT */
		8'd77: fi_l = 7'b0000001;	/* R16G16_UNORM */
		8'd78: fi_l = 7'b0000001;	/* R16G16_SNORM */
		8'd81: fi_l = 7'b0101001;	/* R16G16_UINT */
		8'd82: fi_l = 7'b0101001;	/* R16G16_SINT */
		8'd83: fi_l = 7'b0111101;	/* R16G16_SFLOAT */
		8'd91: fi_l = 7'b0000001;	/* R16G16B16A16_UNORM */
		8'd92: fi_l = 7'b0000001;	/* R16G16B16A16_SNORM */
		8'd95: fi_l = 7'b0101001;	/* R16G16B16A16_UINT */
		8'd96: fi_l = 7'b0101001;	/* R16G16B16A16_SINT */
		8'd97: fi_l = 7'b0111101;	/* R16G16B16A16_SFLOAT */
		8'd98: fi_l = 7'b0101001;	/* R32_UINT */
		8'd99: fi_l = 7'b0101001;	/* R32_SINT */
		8'd100: fi_l = 7'b0101001;	/* R32_SFLOAT */
		8'd101: fi_l = 7'b0101001;	/* R32G32_UINT */
		8'd102: fi_l = 7'b0101001;	/* R32G32_SINT */
		8'd103: fi_l = 7'b0101001;	/* R32G32_SFLOAT */
		8'd104: fi_l = 7'b0000001;	/* R32G32B32_UINT */
		8'd105: fi_l = 7'b0000001;	/* R32G32B32_SINT */
		8'd106: fi_l = 7'b0000001;	/* R32G32B32_SFLOAT */
		8'd107: fi_l = 7'b0101001;	/* R32G32B32A32_UINT */
		8'd108: fi_l = 7'b0101001;	/* R32G32B32A32_SINT */
		8'd109: fi_l = 7'b0101001;	/* R32G32B32A32_SFLOAT */
		8'd122: fi_l = 7'b0110000;	/* B10G11R11_UFLOAT_PACK32 */
		8'd123: fi_l = 7'b0110000;	/* E5B9G9R9_UFLOAT_PACK32 */
		8'd124: fi_l = 7'b0110010;	/* D16_UNORM */
		8'd125: fi_l = 7'b0110010;	/* X8_D24_UNORM_PACK32 */
		8'd126: fi_l = 7'b0110010;	/* D32_SFLOAT */
		8'd129: fi_l = 7'b0110010;	/* D24_UNORM_S8_UINT */
		8'd147: fi_l = 7'b1110000;	/* ETC2_R8G8B8_UNORM_BLOCK */
		8'd148: fi_l = 7'b1110000;	/* ETC2_R8G8B8_SRGB_BLOCK */
		8'd149: fi_l = 7'b1110000;	/* ETC2_R8G8B8A1_UNORM_BLOCK */
		8'd150: fi_l = 7'b1110000;	/* ETC2_R8G8B8A1_SRGB_BLOCK */
		8'd151: fi_l = 7'b1110000;	/* ETC2_R8G8B8A8_UNORM_BLOCK */
		8'd152: fi_l = 7'b1110000;	/* ETC2_R8G8B8A8_SRGB_BLOCK */
		8'd153: fi_l = 7'b1110000;	/* EAC_R11_UNORM_BLOCK */
		8'd154: fi_l = 7'b1110000;	/* EAC_R11_SNORM_BLOCK */
		8'd155: fi_l = 7'b1110000;	/* EAC_R11G11_UNORM_BLOCK */
		8'd156: fi_l = 7'b1110000;	/* EAC_R11G11_SNORM_BLOCK */
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
