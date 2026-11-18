/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_plane: P_l, the plane of level l of a w x h image in bytes, a
 * multiple of 64 (texels of 2^psl bytes in rows of w rounded up to a
 * multiple of 2^ra; tiled: 4-byte texels, or psl 1 for RGB565; blk:
 * compressed 4 x 4 blocks of 2^psl bytes).  The former function plane of
 * atg_tu_desc.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_plane (
	input wire [31:0] sz,	/* TEX_SIZE: height, width */
	input wire tiled,
	input wire blk,
	input wire [2:0] psl,
	input wire [1:0] ra,
	input wire [3:0] l,
	output wire [31:0] plane
);
	/* the level's width and height (at least 1) */
	wire [15:0] w0 = sz[15:0] == 16'd0 ? 16'd1 : sz[15:0];
	wire [15:0] h0 = sz[31:16] == 16'd0 ? 16'd1 : sz[31:16];
	wire [15:0] ws, hs;
	wire [3:0] carry_unused;
	am_shift #(.W(16), .SW(4)) u_ws (.a(w0), .amt(l), .left(1'b0), .arith(1'b0), .y(ws));
	am_shift #(.W(16), .SW(4)) u_hs (.a(h0), .amt(l), .left(1'b0), .arith(1'b0), .y(hs));
	wire [15:0] w = ws == 16'd0 ? 16'd1 : ws;
	wire [15:0] h = hs == 16'd0 ? 16'd1 : hs;
	/* the row: w rounded up to a multiple of 2^ra (m = 2^ra - 1) */
	wire [16:0] m = ra == 2'd0 ? 17'd0 : ra == 2'd1 ? 17'd1 : ra == 2'd2 ? 17'd3 : 17'd7;
	wire [16:0] wm;
	am_add #(.W(17)) u_wm (.a({1'b0, w}), .b(m), .ci(1'b0), .s(wm), .co(carry_unused[0]));
`ifdef MUT_TU_PITCHOFF
	wire [16:0] wr = {1'b0, w} | (m & 17'd0);	/* the planes of packed rows */
	wire unused_wm = &{1'b0, wm};
`else
	wire [16:0] wr = wm & ~m;
`endif
	/* the 4 x 4 tiles (below 2^28), the rows' bytes */
	wire [15:0] tw, th;
	wire [31:0] t;
	wire [32:0] wrh;
	am_add #(.W(16)) u_tw (.a({2'b00, w[15:2]}), .b(16'd0), .ci(w[1:0] != 2'd0), .s(tw),
		.co(carry_unused[1]));
	am_add #(.W(16)) u_th (.a({2'b00, h[15:2]}), .b(16'd0), .ci(h[1:0] != 2'd0), .s(th),
		.co(carry_unused[2]));
	am_mul #(.AW(16), .BW(16)) u_t (.clk(1'b0), .en(1'b1), .a(tw), .b(th), .p(t));
	am_mul #(.AW(17), .BW(16)) u_wrh (.clk(1'b0), .en(1'b1), .a(wr), .b(h), .p(wrh));
	/* tiled: t 32 (psl 1) or t 64; compressed: t 2^psl; else w h 2^psl; + 63, then
	 * to a multiple of 64 (bits 33:32 wrap) */
	wire [33:0] ps, p;
	am_shift #(.W(34), .SW(3)) u_ps (.a(blk ? {2'b00, t} : {1'b0, wrh}), .amt(psl), .left(1'b1),
		.arith(1'b0), .y(ps));
	am_add #(.W(34)) u_p (.a(tiled ? (psl == 3'd1 ? {t[28:0], 5'd0} : {t[27:0], 6'd0}) : ps),
		.b(tiled && psl != 3'd1 ? 34'd0 : 34'd63), .ci(1'b0), .s(p), .co(carry_unused[3]));
	assign plane = {p[31:6], 6'd0};

	wire unused_ok = &{1'b0, p[33:32], p[5:0], t[31:29]};
endmodule

`default_nettype wire
