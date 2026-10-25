/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_pack: four 32-bit components to a pixel of the colour
 * attachment format FMT (a constant: the module is the format's own bit
 * placement): o = {keep[127:0], raw[127:0]}.  The former function
 * atg_fmt_pack of include/atg_fmt_pack.vh; tools/fmtmodel.py pack is the
 * reference; spec/gpu/fmt/atg_fmt.md.  c = {c3, c2, c1, c0}, wm the write
 * mask of R, G, B, A.  raw is the pixel as a little-endian integer, keep
 * has a 1 for every bit not written (the masked components and the bits
 * outside the pixel).  The conversions come from the caller, so that a
 * unit that packs one of several formats at a time has one converter a
 * component (docs/style.md, "Arithmetic"): un[16 k +: 16] =
 * atg_fmt_f2unorm(c_k, the component's width; 8 for an sRGB alpha), hf[16
 * k +: 16] = atg_fmt_f2h(c_k); only the formats that need them read them.
 * UNORM RNE(clamp01(f) x (2^b - 1)), 16-bit floats to nearest even, 32-bit
 * floats and integer formats the low bits; sRGB formats take R, G and B as
 * 8-bit codes in [7:0] (atg_fmt_srgbenc) and A as UNORM 8.  A format
 * without the colour-attachment feature writes nothing (keep all ones).
 * Combinational, no arithmetic.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_pack #(
	parameter [7:0] FMT = 8'd37	/* the VkFormat */
) (
	input wire [127:0] c,
	input wire [63:0] un,	/* the components as UNORM (atg_fmt_f2unorm) */
	input wire [63:0] hf,	/* as fp16 (atg_fmt_f2h) */
	input wire [3:0] wm,
	output wire [255:0] o
);
	`include "atg_fmt_info.vh"

	localparam [67:0] INF = atg_fmt_info(FMT);
	localparam [25:0] FEAT = atg_fmt_feat(FMT, 1'b0);
	localparam COL = FEAT[7];	/* COLOR_ATTACHMENT */
	localparam [2:0] TY = INF[11:9];
	wire [511:0] raws, wrs;	/* component k's field and mask in place, at 128 k */
	genvar gk;
	generate
	for (gk = 0; gk < 4; gk = gk + 1) begin : g_c
		localparam [6:0] POS = INF[16 + 13 * gk +: 7];
		localparam [5:0] W = INF[23 + 13 * gk +: 6];
		localparam [31:0] MSK = W >= 6'd32 ? 32'hFFFFFFFF : (32'd1 << W) - 32'd1;
		localparam ON = COL && gk < INF[8:6];
		wire [31:0] v = c[32 * gk +: 32];
		wire unused_v = &{1'b0, v};	/* (a part of v for some formats) */
		wire [31:0] fld;
		if (TY == ATG_FMT_UNORM || (TY == ATG_FMT_SRGB && gk == 3)) begin : g_un
			assign fld = {16'd0, un[16 * gk +: 16]};
		end else if (TY == ATG_FMT_SRGB) begin : g_srgb
			assign fld = {24'd0, v[7:0]};
		end else if (TY == ATG_FMT_SFLOAT && W != 6'd32) begin : g_hf
			assign fld = {16'd0, hf[16 * gk +: 16]};
		end else begin : g_v
			assign fld = v;
		end
		wire on = ON && wm[gk];
		assign raws[128 * gk +: 128] = on ? {96'd0, fld & MSK} << POS : 128'd0;
		assign wrs[128 * gk +: 128] = on ? {96'd0, MSK} << POS : 128'd0;
	end
	endgenerate
	wire [127:0] raw = raws[0 +: 128] | raws[128 +: 128] | raws[256 +: 128] | raws[384 +: 128];
	wire [127:0] wr = wrs[0 +: 128] | wrs[128 +: 128] | wrs[256 +: 128] | wrs[384 +: 128];
	assign o = {~wr, raw};

	wire unused_ok = &{1'b0, un, hf};	/* (only some formats read them) */
endmodule

`default_nettype wire
