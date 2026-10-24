/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_seg: the segment geometry of the blitter's 2D engine
 * (atg_blt_2d), combinational, in bytes: the length of the segment that
 * starts at pixel px (byte address da) and stays inside one destination
 * line (reversed: from px back to the line's start) and inside one row of
 * a 4x4 tile (a tiled destination or source), at most rem pixels; the
 * bytes back from the rightmost pixel of a reversed segment; the source
 * window (the source byte that maps to byte 0 of the destination line,
 * and the line of the segment's last source byte); the write's byte
 * enables: bytes p0 .. p0 + snu - 1 of the line without the KEEP bytes of
 * each 32-bit pixel.
 * See spec/gpu/blt/atg_blt_seg.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_seg #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire [2:0] psl,	/* log2 of the pixel's bytes */
	input wire rev,
	input wire dtile,
	input wire stile,
	input wire [3:0] keep,
	/* S_SB: the segment's length */
	input wire [LINE_SHIFT-1:0] da,	/* the byte of px in its line */
	input wire [1:0] px,
	input wire [1:0] spx,
	input wire [16:0] rem,
	output wire [LINE_SHIFT:0] seg_n,
	/* S_SC: back from the rightmost pixel (reversed) */
	input wire [LINE_SHIFT:0] sn,
	output wire [ADDR_W-1:0] back,
	/* S_SD: the source window */
	input wire [LINE_SHIFT:0] snu,
	input wire [LINE_SHIFT-1:0] dlo,	/* the byte of the first destination byte */
	input wire [ADDR_W-1:0] slo,
	output wire [ADDR_W-1:0] src_base,
	output wire [ADDR_W-LINE_SHIFT-1:0] last_line,	/* the line of the last source byte */
	/* S_WR: the byte enables */
	input wire [LINE_SHIFT-1:0] p0,
	output reg [LINE_BYTES-1:0] be
);
	localparam US = LINE_SHIFT;

	/* verilator lint_off WIDTHTRUNC */
	localparam [US:0] LB_V = LINE_BYTES;
	/* verilator lint_on WIDTHTRUNC */

	wire [US-1:0] p_da = da;
	wire [US:0] room_fb = LB_V - {1'b0, p_da};
	wire [US:0] room_f = room_fb >> psl;
	wire [US:0] room_r = ({1'b0, p_da} >> psl) + 1'b1;
	wire [2:0] tile_room_d = 3'd4 - {1'b0, px};
	wire [2:0] tile_room_s = 3'd4 - {1'b0, spx};
	wire [US:0] room_t = {{(US - 2){1'b0}}, tile_room_d};
	wire [US:0] room_d = rev ? room_r : (dtile && room_t < room_f) ? room_t : room_f;
	wire [US:0] room_s = {{(US - 2){1'b0}}, tile_room_s};
	wire [US:0] room = (stile && room_s < room_d) ? room_s : room_d;
	assign seg_n = rem < {{(16 - US){1'b0}}, room} ? rem[US:0] : room;

	assign back = {{(ADDR_W - US - 1){1'b0}}, sn - 1'b1} << psl;
	assign src_base = slo - {{(ADDR_W - US){1'b0}}, dlo};
	wire [ADDR_W-1:0] src_last = slo + {{(ADDR_W - US - 1){1'b0}}, snu} - 1'b1;
	assign last_line = src_last[ADDR_W-1:US];

	wire [US:0] p_end = {1'b0, p0} + snu;
	integer u;

	always @(*)
		for (u = 0; u < LINE_BYTES; u = u + 1)
`ifdef MUT_BLT_KEEP
			be[u] = u[US:0] >= {1'b0, p0} && u[US:0] < p_end;	/* KEEP ignored */
`else
			be[u] = u[US:0] >= {1'b0, p0} && u[US:0] < p_end && !keep[u % 4];
`endif

	wire unused_ok = &{1'b0, src_last[US-1:0], keep};
endmodule

`default_nettype wire
