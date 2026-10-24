/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter: TU filtering: converts texels (RGBA8/BGRA8 UNORM, D24,
 * D32F) to fp32 RGBA, compares depth texels with the reference of a
 * compare sampler, and blends nearest, bilinear or (over two passes)
 * trilinear per lane.
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
 * Mip linear: a quad with tc_ctl[4] is the first level; its sums R0 are
 * kept and nothing is returned.  The next quad (tc_ctl[5]) is the second
 * level: R' = R0 (256 − fl) + R1 fl with fl the lane's tc_wts[23:16];
 * otherwise R' = R × 256.  The word is R' / (255 × 2^24) as R' ×
 * 0x0101010101 / 2^64 rounded to fp32 to nearest even (R' = a × 2^24
 * gives exactly the correctly rounded a / 255).
 * A depth format without compare (tc_ctl[8]) returns texel 0 as (D, 0, 0,
 * 1): D32F the word itself, D24 c / (2^24 − 1) as c × (2^48 + 2^24 + 1) /
 * 2^72 rounded to nearest even (the correctly rounded quotient).
 * Lanes outside tc_mask give 0; texsz (tc_ctl[2]) gives word 0 = the
 * lane's tc_value word, the others 0.  texf texels convert like the
 * others.  See spec/gpu/tu/atg_tu_filter.md.
 *
 * States: IDLE →(tc)→ RUN (lanes 0-3) → OUT →(tr_ready)→ IDLE; a first
 * level (tc_ctl[4]) goes from RUN back to IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_filter (
	input wire clk,
	input wire rst_n,
	/* From atg_tu_cache */
	input wire tc_valid,
	output wire tc_ready,
	input wire [511:0] tc_texels,
	input wire [95:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [15:0] tc_ctl,
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
	localparam [1:0] IDLE = 2'd0, RUN = 2'd1, OUT = 2'd2;

	/* p × 2^(eb − 127) as fp32 (p > 0, the result normal), RNE; 0 for 0. */
	function [31:0] rnd73;
		input [72:0] p;
		input [7:0] eb;
		integer i;
		reg [72:0] y;
		reg [6:0] n;
		reg [24:0] m;
		reg [7:0] e;
		begin
			n = 7'd0;
			for (i = 0; i < 73; i = i + 1)
				if (p[i])
					n = i[6:0];
			y = p << (7'd72 - n);
			m = {1'b0, y[72:49]} + {24'd0, y[48] && (y[47:0] != 48'd0 || y[49])};
			e = eb + {1'b0, n} + {7'd0, m[24]};
			rnd73 = p == 73'd0 ? 32'd0 : {1'b0, e, m[24] ? m[23:1] : m[22:0]};
		end
	endfunction

	/* R' / (255 × 2^24): R' × 0x0101010101 × 2^-64. */
	function [31:0] conv;
		input [31:0] r;
		reg [72:0] p;
		begin
			p = {41'd0, r} + ({41'd0, r} << 8) + ({41'd0, r} << 16) + ({41'd0, r} << 24) +
				({41'd0, r} << 32);
			conv = rnd73(p, 8'd63);
		end
	endfunction

	/* unorm24 to fp32: c × (2^48 + 2^24 + 1) × 2^-72. */
	function [31:0] conv24;
		input [23:0] c;
		reg [72:0] p;
		begin
			p = {49'd0, c} + ({49'd0, c} << 24) + ({49'd0, c} << 48);
			conv24 = rnd73(p, 8'd55);
		end
	endfunction

	reg [1:0] st;
	reg [1:0] k;
	reg [511:0] tx;
	reg [95:0] wts;
	reg [3:0] mask;
	reg [15:0] ctl;
	reg [127:0] val;
	reg [383:0] hold;	/* the first level's sums: lane-major, 4 × 24 bits a lane */

	/* Lane k: its texels, weights, reference and kept sums. */
	wire [127:0] lt = tx[k*128 +: 128];
	wire [7:0] fu = wts[k*24 +: 8], fv = wts[k*24 + 8 +: 8], fl = wts[k*24 + 16 +: 8];
	wire [31:0] dref = val[k*32 +: 32];
	wire [95:0] hl = hold[k*96 +: 96];
	wire [23:0] dref24 = atg_depth_u24(dref);
	wire [32:0] dkey = atg_depth_key(dref);
	wire dnan = dref[30:23] == 8'hFF && dref[22:0] != 23'd0;
	reg [127:0] res;
	reg [95:0] sums;
	reg [31:0] tex, tx0;
	reg [3:0] ok;
	reg [7:0] ca, cb, cc, cd;
	reg [16:0] top, bot;
	reg [25:0] r;
	reg [31:0] rr;
	integer c, t;
	always @(*) begin
		/* Depth compare of the four texels. */
		for (t = 0; t < 4; t = t + 1) begin
			tex = lt[t*32 +: 32];
			ok[t] = ctl[1] ? atg_depth_pass(ctl[12:10], dkey, atg_depth_key(tex),
				dnan || (tex[30:23] == 8'hFF && tex[22:0] != 23'd0)) :
				atg_depth_pass(ctl[12:10], {9'd0, dref24}, {9'd0, tex[23:0]}, 1'b0);
		end
		res = 128'd0;
		sums = 96'd0;
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
			sums[c*24 +: 24] = r[23:0];
			rr = ctl[5] ? {8'd0, hl[c*24 +: 24]} * (32'd256 - {24'd0, fl}) +
				{8'd0, r[23:0]} * {24'd0, fl} : {r[23:0], 8'd0};
			res[c*32 +: 32] = conv(rr);
		end
		tx0 = lt[31:0];
		if (ctl[8] && !ctl[9])
			res = {32'h3F800000, 64'd0, ctl[1] ? tx0 : conv24(tx0[23:0])};
		if (ctl[2])
			res = {96'd0, val[k*32 +: 32]};
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
				if (ctl[4])
					hold[k*96 +: 96] <= sums;
				else
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

	wire unused_ok = &{1'b0, ctl[15:13], ctl[7:6], ctl[3], r[25:24]};
endmodule

`default_nettype wire
