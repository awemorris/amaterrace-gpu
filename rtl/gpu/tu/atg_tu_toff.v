/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_toff: the byte offset of texel (i, j) in a plane of width w
 * (linear: w texels a row, up to 2^16; tiled: 4 x 4 tiles of 64 bytes, or
 * 32 for pl 1; bk: 4 x 4 blocks of 2^pl bytes), 32-bit wrap.  The former
 * function toff of atg_tu_foot.  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_toff (
	input wire [15:0] i,
	input wire [15:0] j,
	input wire [16:0] w,
	input wire tl,
	input wire [2:0] pl,	/* log2 of the texel's bytes */
	input wire bk,	/* blocks of 2^pl bytes */
	output wire [31:0] off
);
	/* tiles (blocks) a row; the row's first: (j / 4) tw or j w; + i / 4 or i */
	wire [15:0] tw;
	wire [32:0] m;
	wire [31:0] s1, sh;
	wire [1:0] carry_unused;
	wire tb = tl || bk;
	am_add #(.W(16)) u_tw (.a({2'b00, w[15:2]}), .b(16'd0), .ci(w[1:0] != 2'd0), .s(tw),
		.co(carry_unused[0]));
	am_mul #(.AW(16), .BW(17)) u_m (.clk(1'b0), .en(1'b1), .a(tb ? {2'b00, j[15:2]} : j),
		.b(tb ? {1'b0, tw} : w), .p(m));
	am_add #(.W(32)) u_s1 (.a(m[31:0]), .b(tb ? {18'd0, i[15:2]} : {16'd0, i}), .ci(1'b0), .s(s1),
		.co(carry_unused[1]));
	am_shift #(.W(32), .SW(3)) u_sh (.a(s1), .amt(pl), .left(1'b1), .arith(1'b0), .y(sh));
	/* tiled: the tile's bytes, then the texel's {row, column} in it */
	assign off = bk ? sh : tl && pl == 3'd1 ? {s1[26:0], j[1:0], i[1:0], 1'b0} :
		tl ? {s1[25:0], j[1:0], i[1:0], 2'b00} : sh;

	wire unused_ok = &{1'b0, m[32]};
endmodule

`default_nettype wire
