/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter: TU filtering: converts texels (RGBA8/BGRA8 UNORM, D24,
 * D32F) to fp32 RGBA, compares depth texels with the reference of a
 * compare sampler, and blends nearest, bilinear, and over the passes of
 * 3D linear and mip linear filtering, per lane.
 *
 * Takes one quad (tc_*) in IDLE, does one lane per cycle (its four
 * channels) and holds tr_* until taken; order is kept.  Per channel, with
 * a, b, c, d the 8-bit values of texels 0-3 and fu, fv the lane's weights:
 * bilinear (tc_ctl[0]) R = (a (256 − fu) + b fu) (256 − fv) + (c (256 −
 * fu) + d fu) fv, otherwise R = a × 65536.  The 8-bit values are the
 * texel's bytes (BGRA8, tc_ctl[1]: bytes 0 and 2 swapped) or, for a
 * compare (tc_ctl[9]), (255 when Dref passes VkCompareOp tc_ctl[12:10]
 * against the texel's depth, else 0; 0; 0; 255), Dref the lane's tc_value
 * word (D24: Dref to unorm24 and an integer compare; D32F, tc_ctl[1]: an
 * fp32 compare, NaN passing only NOT_EQUAL and ALWAYS; include/
 * atg_depth.vh, as the ROP's depth test).
 * Passes: each adds R × W to the lane's sums A (the first, tc_ctl[5] = 0,
 * starts them), W = (fw or 256 − fw) × (fl or 256 − fl) by the pass's
 * slice and level bits tc_ctl[17], [18] (fl, fw the lane's tc_wts[23:16],
 * [31:24]); a pass with tc_ctl[4] (more follow) returns nothing.  The last
 * returns A / (255 × 2^32) as A × 0x0101010101 / 2^72 rounded to fp32 to
 * nearest even (A = a × 2^32 gives exactly the correctly rounded a / 255).
 * A depth format without compare (tc_ctl[8]) returns texel 0 as (D, 0, 0,
 * 1): D32F the word itself, D24 c / (2^24 − 1) as c × (2^48 + 2^24 + 1) /
 * 2^72 rounded to nearest even (the correctly rounded quotient).
 * Gather (tc_ctl[13]): the lane's words are component tc_ctl[15:14] of
 * texels 2, 3, 1, 0 ((i0, j1), (i1, j1), (i1, j0), (i0, j0)), converted
 * alone: UNORM a / 255, a depth component 0 D (others 0, 3 1.0), a
 * compare 1.0 or 0.0.
 * Lanes outside tc_mask give 0; texsz (tc_ctl[2]) gives word 0 = the
 * lane's tc_value word, the others 0; the LOD query (tc_ctl[2], [16])
 * gives tc_value [15:0] / 256 (the level accessed) and [31:16] / 256
 * (λ'), both signed, as fp32.  texf texels convert like the others.
 * RGB565 (tc_ctl[19], the texel's bits 15:0): texf converts exactly, (R /
 * 31, G / 63, B / 31, 1) rounded to nearest even; the other operations
 * take the texel as RGBA8 ((c << 3) | (c >> 2), (c << 2) | (c >> 4), alpha
 * 255) and filter it like RGBA8.
 * The VkFormat of TEX_FORMAT (tc_ctl[34:27]; 0 for the earlier codes):
 * R8_UNORM (9) and R8G8_UNORM (16) texels are taken as RGBA8 with the
 * missing bytes 0 and alpha 255 (border texels too: Vulkan replaces the
 * format's components only); D16_UNORM (124) compares the texel's bits
 * 15:0 with Dref converted to 16-bit UNORM (atg_fmt_f2unorm).  The
 * component swizzle (tc_ctl[47:36], VkComponentSwizzle of R, G, B, A:
 * IDENTITY, ZERO, ONE, R, G, B, A) is applied last, after a compare, and
 * gather takes the component that the swizzle puts in its place (ZERO and
 * ONE: 0.0 and 1.0); the queries are not swizzled.
 * See spec/gpu/tu/atg_tu_filter.md.
 *
 * States: IDLE →(tc)→ RUN (lanes 0-3) → OUT →(tr_ready)→ IDLE; a pass
 * with more to follow (tc_ctl[4]) goes from RUN back to IDLE. */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_filter (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [127:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [47:0] tc_ctl,
	input wire [127:0] tc_value,
	input wire tc_last,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output reg [15:0] tr_tag,
	output reg [511:0] tr_data,
	output reg tr_last
);
	`include "atg_depth.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_pack.vh"
	localparam [1:0] IDLE = 2'd0, RUN = 2'd1, OUT = 2'd2;

	/* p × 2^(n + eb − 127) as fp32 with n the msb position (p > 0, the
	 * result normal), RNE; 0 for 0. */
	function [31:0] rnd81;
		input [80:0] p;
		input [7:0] eb;
		integer i;
		reg [80:0] y;
		reg [6:0] n;
		reg [24:0] m;
		reg [7:0] e;
		begin
			n = 7'd0;
			for (i = 0; i < 81; i = i + 1)
				if (p[i])
					n = i[6:0];
			y = p << (7'd80 - n);
			m = {1'b0, y[80:57]} + {24'd0, y[56] && (y[55:0] != 56'd0 || y[57])};
			e = eb + {1'b0, n} + {7'd0, m[24]};
			rnd81 = p == 81'd0 ? 32'd0 : {1'b0, e, m[24] ? m[23:1] : m[22:0]};
		end
	endfunction

	/* A / (255 × 2^32): A × 0x0101010101 × 2^-72 (A < 2^40). */
	function [31:0] conv40;
		input [39:0] a;
		reg [80:0] p;
		begin
			p = {41'd0, a} + ({41'd0, a} << 8) + ({41'd0, a} << 16) + ({41'd0, a} << 24) +
				({41'd0, a} << 32);
			conv40 = rnd81(p, 8'd55);
		end
	endfunction

	/* c / 31 (5 bits): c × sum(2^5i, i < 16) × 2^-80; c / 63 (6 bits):
	 * c × sum(2^6i, i < 13) × 2^-78 (never a tie: rounding is exact). */
	function [31:0] conv5;
		input [4:0] c;
		reg [80:0] p;
		integer i;
		begin
			p = 81'd0;
			for (i = 0; i < 16; i = i + 1)
				p = p + ({76'd0, c} << (5 * i));
			conv5 = rnd81(p, 8'd47);
		end
	endfunction
	function [31:0] conv6;
		input [5:0] c;
		reg [80:0] p;
		integer i;
		begin
			p = 81'd0;
			for (i = 0; i < 13; i = i + 1)
				p = p + ({75'd0, c} << (6 * i));
			conv6 = rnd81(p, 8'd49);
		end
	endfunction

	/* RGB565 as RGBA8 (for the filtered operations). */
	function [31:0] x565;
		input [15:0] t;
		x565 = {8'hFF, t[4:0], t[4:2], t[10:5], t[10:9], t[15:11], t[15:13]};
	endfunction

	/* R8 and R8G8 as RGBA8 (the missing bytes 0, alpha 255). */
	function [31:0] xrg;
		input [31:0] t;
		input [7:0] f;
		xrg = f == 8'd9 ? {8'hFF, 16'd0, t[7:0]} : f == 8'd16 ? {8'hFF, 8'd0, t[15:0]} : t;
	endfunction

	/* The component swizzle of four fp32 components. */
	function [127:0] swz4;
		input [127:0] v;
		input [11:0] z;
		integer c;
		reg [2:0] sc;
		begin
			for (c = 0; c < 4; c = c + 1) begin
				sc = z[3*c +: 3];
				swz4[c*32 +: 32] = sc == 3'd1 ? 32'd0 : sc == 3'd2 ? 32'h3F800000 :
					sc >= 3'd3 && sc <= 3'd6 ? v[{sc[1:0] + 2'd1, 5'd0} +: 32] : v[c*32 +: 32];
			end
		end
	endfunction

	/* An 8-bit value a / 255. */
	function [31:0] conv8;
		input [7:0] a;
		conv8 = conv40({a, 32'd0});
	endfunction

	/* A signed 16-bit value with 8 fraction bits as fp32 (exact). */
	function [31:0] fix8;
		input [15:0] v;
		reg [15:0] a;
		begin
			a = v[15] ? -v : v;
			fix8 = {v[15], 31'd0} | rnd81({65'd0, a}, 8'd119);
		end
	endfunction

	/* unorm24 to fp32: c × (2^48 + 2^24 + 1) × 2^-72. */
	function [31:0] conv24;
		input [23:0] c;
		reg [80:0] p;
		begin
			p = {57'd0, c} + ({57'd0, c} << 24) + ({57'd0, c} << 48);
			conv24 = rnd81(p, 8'd55);
		end
	endfunction

	reg [1:0] st;
	reg [1:0] k;
	reg [511:0] tx;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [47:0] ctl;
	reg [127:0] val;
	reg [639:0] acc;	/* the passes' sums: lane-major, 4 × 40 bits a lane */

	/* Lane k: its texels (RGB565 as RGBA8), weights, reference and kept sums. */
	wire [127:0] lraw = tx[k*128 +: 128];
	wire [7:0] vkf = ctl[34:27];
	wire [127:0] lt = ctl[19] ? {x565(lraw[111:96]), x565(lraw[79:64]), x565(lraw[47:32]),
		x565(lraw[15:0])} : {xrg(lraw[127:96], vkf), xrg(lraw[95:64], vkf), xrg(lraw[63:32], vkf),
		xrg(lraw[31:0], vkf)};
	wire [7:0] fu = wts[k*32 +: 8], fv = wts[k*32 + 8 +: 8];
	wire [7:0] fl = wts[k*32 + 16 +: 8], fw = wts[k*32 + 24 +: 8];
	wire [31:0] dref = val[k*32 +: 32];
	wire [159:0] al = acc[k*160 +: 160];
	/* The pass's weight: (fw or 256 − fw) × (fl or 256 − fl). */
	wire [8:0] wa = ctl[17] ? {1'b0, fw} : 9'd256 - {1'b0, fw};
	wire [8:0] wb = ctl[18] ? {1'b0, fl} : 9'd256 - {1'b0, fl};
	wire [17:0] wp = {9'd0, wa} * {9'd0, wb};
	wire [23:0] dref24 = atg_depth_u24(dref);
	wire [15:0] dref16 = atg_fmt_f2unorm(dref, 6'd16);
	wire d16 = vkf == 8'd124;
	wire [32:0] dkey = atg_depth_key(dref);
	wire dnan = dref[30:23] == 8'hFF && dref[22:0] != 23'd0;
	reg [127:0] res;
	reg [159:0] sums;
	reg [31:0] tex, tx0;
	reg [3:0] ok;
	reg [7:0] ca, cb, cc, cd;
	reg [16:0] top, bot;
	reg [25:0] r;
	reg [39:0] rr;
	reg [31:0] gt;
	reg [7:0] gb;
	integer c, t, g;
	/* Gather: the component the swizzle puts in place ctl[15:14] (gsw 1, 2:
	 * the constants), and its byte (BGRA8 swaps R and B). */
	wire [2:0] gsw = ctl[36 + 3 * ctl[15:14] +: 3];
	wire [1:0] gsrc = gsw >= 3'd3 && gsw <= 3'd6 ? gsw[1:0] + 2'd1 : ctl[15:14];
	wire [1:0] gsel = ctl[1] && !gsrc[0] ? gsrc ^ 2'd2 : gsrc;
	always @(*) begin
		gt = 32'd0;
		gb = 8'd0;
		/* Depth compare of the four texels. */
		for (t = 0; t < 4; t = t + 1) begin
			tex = lt[t*32 +: 32];
			ok[t] = ctl[1] ? atg_depth_pass(ctl[12:10], dkey, atg_depth_key(tex),
				dnan || (tex[30:23] == 8'hFF && tex[22:0] != 23'd0)) :
				d16 ? atg_depth_pass(ctl[12:10], {17'd0, dref16}, {17'd0, tex[15:0]}, 1'b0) :
				atg_depth_pass(ctl[12:10], {9'd0, dref24}, {9'd0, tex[23:0]}, 1'b0);
		end
		res = 128'd0;
		sums = 160'd0;
		for (c = 0; c < 4; c = c + 1) begin
			if (ctl[9]) begin
				/* (pass, 0, 0, 1) as bytes */
				ca = c == 0 ? {8{ok[0]}} : c == 3 ? 8'hFF : 8'd0;
				cb = c == 0 ? {8{ok[1]}} : c == 3 ? 8'hFF : 8'd0;
				cc = c == 0 ? {8{ok[2]}} : c == 3 ? 8'hFF : 8'd0;
				cd = c == 0 ? {8{ok[3]}} : c == 3 ? 8'hFF : 8'd0;
			end else begin
				/* byte of channel c: RGBA8 c, BGRA8 swaps R and B */
				tex = lt[0 +: 32];
				ca = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
				tex = lt[32 +: 32];
				cb = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
				tex = lt[64 +: 32];
				cc = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
				tex = lt[96 +: 32];
				cd = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			end
			top = {9'd0, ca} * (17'd256 - {9'd0, fu}) + {9'd0, cb} * {9'd0, fu};
			bot = {9'd0, cc} * (17'd256 - {9'd0, fu}) + {9'd0, cd} * {9'd0, fu};
			r = ctl[0] ? {9'd0, top} * (26'd256 - {18'd0, fv}) + {9'd0, bot} * {18'd0, fv} :
				{2'd0, ca, 16'd0};
			rr = (ctl[5] ? al[c*40 +: 40] : 40'd0) + {16'd0, r[23:0]} * {22'd0, wp};
			sums[c*40 +: 40] = rr;
			res[c*32 +: 32] = conv40(rr);
		end
		tx0 = lt[31:0];
		if (ctl[19] && ctl[3])	/* texf of RGB565: exact */
			res = {32'h3F800000, conv5(lraw[4:0]), conv6(lraw[10:5]), conv5(lraw[15:11])};
		if (ctl[8] && !ctl[9])
			res = {32'h3F800000, 64'd0, ctl[1] ? tx0 : conv24(tx0[23:0])};
		if (ctl[13]) begin
			/* gather: word g is texel 2, 3, 1, 0 */
			for (g = 0; g < 4; g = g + 1) begin
				t = g == 0 ? 2 : g == 1 ? 3 : g == 2 ? 1 : 0;
				gt = lt[t*32 +: 32];
				gb = gt[gsel*8 +: 8];
				if (ctl[9])
					res[g*32 +: 32] = ok[t] ? 32'h3F800000 : 32'd0;
				else if (gsw == 3'd1 || gsw == 3'd2)
					res[g*32 +: 32] = gsw == 3'd2 ? 32'h3F800000 : 32'd0;
				else if (ctl[8])
					res[g*32 +: 32] = gsrc == 2'd0 ? (ctl[1] ? gt : conv24(gt[23:0])) :
						gsrc == 2'd3 ? 32'h3F800000 : 32'd0;
				else
					res[g*32 +: 32] = conv8(gb);
			end
		end else
			res = swz4(res, ctl[47:36]);
		if (ctl[2])
			res = ctl[16] ? {64'd0, fix8(val[k*32 + 16 +: 16]), fix8(val[k*32 +: 16])} :
				{96'd0, val[k*32 +: 32]};
		if (!mask[k])
			res = 128'd0;
	end

	assign tc_ready = st == IDLE;
	assign tr_valid = st == OUT;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (tc_valid) begin
				tx <= tc_texels;
				wts <= tc_wts;
				mask <= tc_mask;
				ctl <= tc_ctl;
				val <= tc_value;
				tr_tag <= tc_tag;
				tr_last <= tc_last;
				k <= 2'd0;
				st <= RUN;
			end
			RUN: begin
				acc[k*160 +: 160] <= sums;
				if (!ctl[4])
					tr_data[k*128 +: 128] <= res;
				k <= k + 2'd1;
				if (k == 2'd3)
					st <= ctl[4] ? IDLE : OUT;
			end
			OUT: if (tr_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, ctl[35], ctl[26:20], ctl[7:6], r[25:24], wp[17], lraw};
endmodule

`default_nettype wire
