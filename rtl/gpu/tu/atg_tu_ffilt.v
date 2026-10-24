/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_ffilt: the TU's fp32 filter path (docs/ghci.md section 8.5):
 * the formats of TEX_FORMAT that atg_tu_filter does not take (tc_ctl[20]
 * = 1): every sampled format but RGBA8, BGRA8, R8, R8G8 UNORM and the
 * compares.  tools/tumodel.py (FFilter) is the reference, bit for bit.
 *
 * Takes one pass of a quad (tc_*) in IDLE; per lane of tc_mask, in the
 * order lane, texel, component, one step a cycle; holds tr_* until taken
 * (order is kept).  The texels of a lane come from its four slots: 1- to
 * 4-byte texels are slots 0-3 (right-justified by atg_tu_cache), 8-byte
 * texels slots {1, 0} and {3, 2} (the texels i0 and i1 of the pass's row,
 * tc_ctl[22]), 16-byte texels slots {3, 2, 1, 0}; gather: slot t is the
 * word of texel t that holds the component (include/atg_tu_fmt.vh
 * tu_gwi).  Each texel is converted by atg_fmt_unpack (tc_ctl[34:27] the
 * VkFormat, [35] the stencil aspect), or is a border texel (tc_bord):
 * the border colour (tc_ctl[7:6]: 0 transparent black, 1 opaque black, 2
 * opaque white; integer 0 and 1 for the integer formats) in the format's
 * components, the others (0, 0, 0, 1).  sRGB texels are linear after
 * atg_fmt_unpack, before filtering.
 * Weights: texel t's integer weight wu x wv (bilinear: (256 - fu or fu) x
 * (256 - fv or fv) by its column and row; 8-byte row passes: the row's
 * 256 - fv or fv; nearest: 65536 for texel 0) times the pass's (256 - fw
 * or fw) x (256 - fl or fl) (tc_ctl[17], [18]), as fp32 n x 2^-32 rounded
 * to nearest even; a weight of 0 is skipped.  Each component c below the
 * format's count is accumulated by a fused multiply-add, A = fma(w, x, A)
 * (include/atg_su_fp.vh: one rounding to nearest even, denormals flushed),
 * from A = -0.0 at the quad's first pass (tc_ctl[5] = 0) over the passes;
 * the components the format does not have are (0, 0, 0, 1).  A lane with
 * a single texel of weight 1 (a quad of one pass without bilinear, or a
 * bilinear lane with fu = fv = 0) returns the converted texel as it is
 * (integer formats, texf and nearest sampling are exact).  Gather
 * returns the component of texels 2, 3, 1, 0.  The component swizzle
 * (tc_ctl[47:36]) is applied last (gather selects through it); lanes
 * outside tc_mask give 0.  A pass with tc_ctl[4] (more to follow) returns
 * nothing and keeps the sums.
 * See spec/gpu/tu/atg_tu_ffilt.md.
 *
 * States: IDLE →(tc)→ RUN (lanes 0-3) → FIN → OUT →(tr_ready)→ IDLE; a
 * pass with more to follow goes from RUN back to IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_ffilt (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [15:0] tc_bord,
	input wire [127:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [47:0] tc_ctl,
	input wire tc_last,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output reg [15:0] tr_tag,
	output reg [511:0] tr_data,
	output reg tr_last
);
	`include "ghci_regs.vh"
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_tu_fmt.vh"
	`include "atg_su_fp.vh"
	localparam [1:0] IDLE = 2'd0, RUN = 2'd1, FIN = 2'd2, OUT = 2'd3;

	/* n x 2^-32 as fp32, n > 0, rounded to nearest even; 0 for 0. */
	function [31:0] w2f;
		input [32:0] n;
		integer i;
		reg [5:0] m;
		reg [56:0] y;
		reg [24:0] q;
		begin
			m = 6'd0;
			for (i = 0; i < 33; i = i + 1)
				if (n[i])
					m = i[5:0];
			y = {n, 24'd0} << (6'd32 - m);
			q = {1'b0, y[56:33]} + {24'd0, y[32] && (y[31:0] != 32'd0 || y[33])};
			w2f = n == 33'd0 ? 32'd0 :
				{1'b0, 8'd95 + {2'b00, m} + {7'd0, q[24]}, q[24] ? q[23:1] : q[22:0]};
		end
	endfunction

	/* The component swizzle; one is 1.0 or the integer 1. */
	function [127:0] swz4;
		input [127:0] v;
		input [11:0] z;
		input [31:0] one;
		integer c;
		reg [2:0] sc;
		begin
			for (c = 0; c < 4; c = c + 1) begin
				sc = z[3*c +: 3];
				swz4[c*32 +: 32] = sc == 3'd1 ? 32'd0 : sc == 3'd2 ? one :
					sc >= 3'd3 && sc <= 3'd6 ? v[{sc[1:0] + 2'd1, 5'd0} +: 32] : v[c*32 +: 32];
			end
		end
	endfunction

	reg [1:0] st;
	reg [1:0] k, t, c;
	reg [511:0] tx;
	reg [15:0] bd;
	reg [127:0] wts;
	reg [3:0] mask;
	reg [47:0] ctl;
	reg [511:0] acc;	/* lane-major, 4 components a lane */

	/* The quad. */
	wire bil = ctl[0], more = ctl[4], gath = ctl[13], split = ctl[21], row = ctl[22];
	wire [1:0] comp = ctl[15:14], bcls = ctl[7:6];
	wire [7:0] vkf = ctl[34:27];
	wire sten = ctl[35];
	wire [11:0] swz = ctl[47:36];
	wire [67:0] inf = atg_fmt_info(vkf);
	wire [2:0] ncomp = sten ? 3'd1 : inf[0] && !inf[14] ? inf[8:6] : 3'd0;
	wire isint = sten || inf[11:9] == ATG_FMT_UINT || inf[11:9] == ATG_FMT_SINT;
	wire [31:0] one = isint ? 32'd1 : 32'h3F800000;
	wire b8 = inf[5:1] == 5'd8, b16 = inf[5:1] == 5'd16;
	wire [1:0] gwi = tu_gwi({swz, sten, vkf}, comp);
	/* Gather: the component the swizzle puts in place comp. */
	wire [2:0] gsw = swz[3*comp +: 3];
	wire [1:0] gsrc = gsw >= 3'd3 && gsw <= 3'd6 ? gsw[1:0] + 2'd1 : comp;

	/* Lane k, texel t: its raw bits, border bit and converted value. */
	wire [127:0] sl = tx[k*128 +: 128];
	wire [127:0] raw = gath ? {96'd0, sl[t*32 +: 32]} << {gwi, 5'd0} :
		b8 ? (t[0] ? {64'd0, sl[127:64]} : {64'd0, sl[63:0]}) : b16 ? sl : {96'd0, sl[t*32 +: 32]};
	wire tb = gath || !(b8 || b16) ? bd[{k, t}] : b8 && t[0] ? bd[{k, 2'd2}] : bd[{k, 2'd0}];
	wire [128:0] up = atg_fmt_unpack(raw, vkf, sten);
	reg [127:0] bval;
	integer q;
	always @(*)
		for (q = 0; q < 4; q = q + 1)
			bval[q*32 +: 32] = q < ncomp ? (bcls == 2'd2 || (bcls == 2'd1 && q == 3) ? one : 32'd0) :
				q == 3 ? one : 32'd0;
	wire [127:0] val = tb ? bval : up[127:0];
	/* Its weight. */
	wire [7:0] fu = wts[k*32 +: 8], fv = wts[k*32 + 8 +: 8];
	wire [7:0] fl = wts[k*32 + 16 +: 8], fw = wts[k*32 + 24 +: 8];
	wire [8:0] ru = 9'd256 - {1'b0, fu}, rv = 9'd256 - {1'b0, fv};
	wire [8:0] wu = split ? (t == 2'd0 ? ru : t == 2'd1 ? {1'b0, fu} : 9'd0) :
		!bil ? (t == 2'd0 ? 9'd256 : 9'd0) : t[0] ? {1'b0, fu} : ru;
`ifdef MUT_FFILT_ROW
	wire [8:0] wv = split ? (t[1] ? 9'd0 : rv) :	/* the second row weighted as the first */
`else
	wire [8:0] wv = split ? (t[1] ? 9'd0 : row ? {1'b0, fv} : rv) :
`endif
		!bil ? (t == 2'd0 ? 9'd256 : 9'd0) : t[1] ? {1'b0, fv} : rv;
	wire [8:0] wa = ctl[17] ? {1'b0, fw} : 9'd256 - {1'b0, fw};
	wire [8:0] wb = ctl[18] ? {1'b0, fl} : 9'd256 - {1'b0, fl};
	wire [17:0] wuv = {9'd0, wu} * {9'd0, wv}, wab = {9'd0, wa} * {9'd0, wb};
	wire [35:0] n = {18'd0, wuv} * {18'd0, wab};
	wire [31:0] wf = w2f(n[32:0]);
	/* The lane is a single texel of weight 1. */
	wire byp = !more && !ctl[5] && !gath && (!bil || (fu == 8'd0 && fv == 8'd0));
	wire [31:0] sum = atg_su_ffma(wf, val[c*32 +: 32], acc[{k, c}*32 +: 32], 3'd0, 1'b0);
	/* The next lane; the next texel; is c the last component. */
	wire lastc = {1'b0, c} == ncomp - 3'd1;
	wire skip = n[32:0] == 33'd0 || ncomp == 3'd0;

	/* The result of lane l. */
	reg [511:0] fin_q;
	reg [127:0] fin;
	reg [2:0] g3;
	integer l, m;
	always @(*) begin
		for (l = 0; l < 4; l = l + 1) begin
			for (m = 0; m < 4; m = m + 1) begin
				g3 = m[2:0];
				fin[m*32 +: 32] = g3 < ncomp ? acc[(l*4 + m)*32 +: 32] : m == 3 ? one : 32'd0;
			end
			fin_q[l*128 +: 128] = !mask[l] ? 128'd0 : gath ? acc[l*128 +: 128] : swz4(fin, swz, one);
		end
	end

	assign tc_ready = st == IDLE;
	assign tr_valid = st == OUT;

	/* Gather word g of the lane: texel 2, 3, 1, 0 (texel t's place). */
	wire [1:0] gpos = t == 2'd2 ? 2'd0 : t == 2'd3 ? 2'd1 : t == 2'd1 ? 2'd2 : 2'd3;
	wire [31:0] gval = gsw == 3'd1 ? 32'd0 : gsw == 3'd2 ? one : val[gsrc*32 +: 32];

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (tc_valid) begin
				tx <= tc_texels;
				bd <= tc_bord;
				wts <= tc_wts;
				mask <= tc_mask;
				ctl <= tc_ctl;
				tr_tag <= tc_tag;
				tr_last <= tc_last;
				if (!tc_ctl[5])
					acc <= {16{32'h80000000}};
				k <= 2'd0;
				t <= 2'd0;
				c <= 2'd0;
				st <= RUN;
			end
			RUN: begin
				if (!mask[k] || byp || (!gath && t == 2'd3 && (skip || lastc)) ||
				    (gath && t == 2'd3)) begin
					/* the lane is done */
					if (mask[k] && byp)
						acc[k*128 +: 128] <= val;
					k <= k + 2'd1;
					t <= 2'd0;
					c <= 2'd0;
					if (k == 2'd3)
						st <= more ? IDLE : FIN;
				end else if (gath || skip || lastc) begin
					t <= t + 2'd1;
					c <= 2'd0;
				end else
					c <= c + 2'd1;
				if (mask[k] && gath)
					acc[{k, gpos}*32 +: 32] <= gval;
				else if (mask[k] && !byp && !skip)
					acc[{k, c}*32 +: 32] <= sum;
			end
			FIN: begin
				tr_data <= fin_q;
				st <= OUT;
			end
			default: if (tr_ready)
				st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, n[35:33], up[128], inf[67:15], inf[13:12], ctl[33:23], ctl[16],
		ctl[20:19], ctl[12:8], ctl[3:1]};
endmodule

`default_nettype wire
