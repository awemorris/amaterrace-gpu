/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_filter: TU filtering: converts texels (RGBA8/BGRA8 UNORM, or raw
 * integers for texf) to fp32 RGBA and blends nearest or bilinear per lane.
 *
 * Takes one quad (tc_*) in IDLE, does one lane per cycle (its four
 * channels) and holds tr_* until taken; order is kept.  Per channel, with
 * a, b, c, d the 8-bit values of texels 0-3 (BGRA8, ta_ctl[1]: bytes 0 and
 * 2 swapped) and fu, fv the lane's weights: bilinear (ta_ctl[0]) R =
 * (a (256 − fu) + b fu) (256 − fv) + (c (256 − fu) + d fu) fv, otherwise
 * R = a × 65536; the result is R / (255 × 65536) as R × 0x0101010101 /
 * 2^56 rounded to fp32 to nearest even (R = a × 65536 gives exactly the
 * correctly rounded a / 255).  Lanes outside tc_mask give 0; texsz
 * (ta_ctl[2]) gives word 0 = the lane's tc_value word, the others 0.  texf
 * texels convert like the others (v1 formats are UNORM).
 * See spec/gpu/tu/atg_tu_filter.md.
 *
 * States: IDLE →(tc)→ RUN (lanes 0-3) → OUT →(tr_ready)→ IDLE.
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
	input wire [63:0] tc_wts,
	input wire [15:0] tc_tag,
	input wire [3:0] tc_mask,
	input wire [7:0] tc_ctl,
	input wire [127:0] tc_value,
	input wire tc_last,
	/* Return to the SU */
	output wire tr_valid,
	input wire tr_ready,
	output reg [15:0] tr_tag,
	output reg [511:0] tr_data,
	output reg tr_last
);
	localparam [1:0] IDLE = 2'd0, RUN = 2'd1, OUT = 2'd2;

	/* R / (255 × 65536) as fp32 (R < 2^24). */
	function [31:0] conv;
		input [23:0] r;
		integer i;
		reg [56:0] p, y;
		reg [5:0] n;
		reg [24:0] m;
		reg [7:0] e;
		begin
			p = {33'd0, r} + ({33'd0, r} << 8) + ({33'd0, r} << 16) + ({33'd0, r} << 24) +
				({33'd0, r} << 32);
			n = 6'd0;
			for (i = 0; i < 57; i = i + 1)
				if (p[i])
					n = i[5:0];
			y = p << (6'd56 - n);
			m = {1'b0, y[56:33]} + {24'd0, y[32] && (y[31:0] != 32'd0 || y[33])};
			e = 8'd71 + {2'd0, n} + {7'd0, m[24]};
			conv = r == 24'd0 ? 32'd0 : {1'b0, e, m[24] ? m[23:1] : m[22:0]};
		end
	endfunction

	reg [1:0] st;
	reg [1:0] k;
	reg [511:0] tx;
	reg [63:0] wts;
	reg [3:0] mask;
	reg [7:0] ctl;
	reg [127:0] val;

	/* Lane k: its texels' channels (RGBA order) and weights. */
	wire [127:0] lt = tx[k*128 +: 128];
	wire [7:0] fu = wts[k*16 +: 8], fv = wts[k*16 + 8 +: 8];
	reg [127:0] res;
	reg [31:0] tex;
	reg [7:0] ca, cb, cc, cd;
	reg [16:0] top, bot;
	reg [25:0] r;
	integer c;
	always @(*) begin
		res = 128'd0;
		for (c = 0; c < 4; c = c + 1) begin
			/* byte of channel c: RGBA8 c, BGRA8 swaps R and B */
			tex = lt[0 +: 32];
			ca = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			tex = lt[32 +: 32];
			cb = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			tex = lt[64 +: 32];
			cc = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			tex = lt[96 +: 32];
			cd = tex[(ctl[1] && c != 1 && c != 3 ? 2 - c : c)*8 +: 8];
			top = {9'd0, ca} * (17'd256 - {9'd0, fu}) + {9'd0, cb} * {9'd0, fu};
			bot = {9'd0, cc} * (17'd256 - {9'd0, fu}) + {9'd0, cd} * {9'd0, fu};
			r = ctl[0] ? {9'd0, top} * (26'd256 - {18'd0, fv}) + {9'd0, bot} * {18'd0, fv} :
				{2'd0, ca, 16'd0};
			res[c*32 +: 32] = conv(r[23:0]);
		end
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
				tr_data[k*128 +: 128] <= res;
				k <= k + 2'd1;
				if (k == 2'd3)
					st <= OUT;
			end
			OUT: if (tr_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, ctl[7:3], r[25:24]};
endmodule

`default_nettype wire
