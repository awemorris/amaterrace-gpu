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
	wire [US:0] room_fb, room_f, da_px, room_r, back_n, p_end;
	wire [2:0] tile_room_d, tile_room_s;
	wire [ADDR_W-1:0] src_next, src_last;
	wire [8:0] seg_co_unused;

	/* The pixels to the line's end (forward) or back to its start (reversed), and to the tile row's end. */
	am_sub #(.W(US + 1)) s_fb (.a(LB_V), .b({1'b0, p_da}), .bi(1'b0), .d(room_fb), .bo(seg_co_unused[0]));
	am_shift #(.W(US + 1), .SW(3)) h_f (.a(room_fb), .amt(psl), .left(1'b0), .arith(1'b0), .y(room_f));
	am_shift #(.W(US + 1), .SW(3)) h_r (.a({1'b0, p_da}), .amt(psl), .left(1'b0), .arith(1'b0), .y(da_px));
	am_add #(.W(US + 1)) a_r (.a(da_px), .b({(US + 1){1'b0}}), .ci(1'b1), .s(room_r), .co(seg_co_unused[1]));
	am_sub #(.W(3)) s_td (.a(3'd4), .b({1'b0, px}), .bi(1'b0), .d(tile_room_d), .bo(seg_co_unused[2]));
	am_sub #(.W(3)) s_ts (.a(3'd4), .b({1'b0, spx}), .bi(1'b0), .d(tile_room_s), .bo(seg_co_unused[3]));
	wire [US:0] room_t = {{(US - 2){1'b0}}, tile_room_d};
	wire [US:0] room_d = rev ? room_r : (dtile && room_t < room_f) ? room_t : room_f;
	wire [US:0] room_s = {{(US - 2){1'b0}}, tile_room_s};
	wire [US:0] room = (stile && room_s < room_d) ? room_s : room_d;
	wire rem_large = |rem[16:US];
	wire rem_less = !rem_large && ({1'b0, rem[US-1:0]} < room);
	assign seg_n = rem_less ? {1'b0, rem[US-1:0]} : room;

	/* The bytes back from the rightmost pixel, and the source window. */
	am_sub #(.W(US + 1)) s_bn (.a(sn), .b({(US + 1){1'b0}}), .bi(1'b1), .d(back_n), .bo(seg_co_unused[4]));
	am_shift #(.W(ADDR_W), .SW(3)) h_b (.a({{(ADDR_W - US - 1){1'b0}}, back_n}), .amt(psl), .left(1'b1),
		.arith(1'b0), .y(back));
	am_sub #(.W(ADDR_W)) s_sb (.a(slo), .b({{(ADDR_W - US){1'b0}}, dlo}), .bi(1'b0), .d(src_base),
		.bo(seg_co_unused[5]));
	am_add #(.W(ADDR_W)) a_sn (.a(slo), .b({{(ADDR_W - US - 1){1'b0}}, snu}), .ci(1'b0), .s(src_next),
		.co(seg_co_unused[6]));
	am_sub #(.W(ADDR_W)) s_sl (.a(src_next), .b({ADDR_W{1'b0}}), .bi(1'b1), .d(src_last), .bo(seg_co_unused[7]));
	assign last_line = src_last[ADDR_W-1:US];

	/* The end of the write's bytes. */
	am_add #(.W(US + 1)) a_pe (.a({1'b0, p0}), .b(snu), .ci(1'b0), .s(p_end), .co(seg_co_unused[8]));
	integer u;

	always @(*)
		for (u = 0; u < LINE_BYTES; u = u + 1)
`ifdef MUT_BLT_KEEP
			be[u] = u[US:0] >= {1'b0, p0} && u[US:0] < p_end;	/* KEEP ignored */
`else
			be[u] = u[US:0] >= {1'b0, p0} && u[US:0] < p_end && !keep[u % 4];
`endif

	wire unused_ok = &{1'b0, src_last[US-1:0], keep, seg_co_unused};
endmodule

`default_nettype wire
