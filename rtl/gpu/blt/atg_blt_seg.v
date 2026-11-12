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
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter BURST = 0
) (
	input wire [2:0] psl,	/* log2 of the pixel's bytes */
	input wire [LINE_SHIFT:0] line_pix,	/* LINE_BYTES >> psl */
	input wire rev,
	input wire dtile,
	input wire stile,
	input wire [3:0] keep,
	/* S_SB: the segment's length */
	input wire [LINE_SHIFT-1:0] da,	/* the byte of px in its line */
	input wire [1:0] px,
	input wire [1:0] spx,
	input wire [16:0] rem,
	input wire [LINE_SHIFT:0] in_room,
	input wire use_in_room,
	input wire [LINE_SHIFT:0] in_da_px,
	input wire use_in_da_px,
	output wire [LINE_SHIFT:0] seg_n,
	output wire seg_last,
	output wire [LINE_SHIFT:0] room,
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
	wire [US:0] da_px, room_r, back_n, p_end, leg_back_n;
	wire [ADDR_W-1:0] src_next, src_last;
	wire [7:0] seg_co_unused;
	assign seg_co_unused[7] = 1'b0;
	assign seg_co_unused[1:0] = 2'b00;

	/* Pre-shift da by pixel size (da_px = p_da >> psl) */
	assign da_px  = use_in_da_px ? in_da_px :
	                (psl == 3'd4) ? {5'b00000, p_da[US-1:4]} :
	                (psl == 3'd3) ? {4'b0000, p_da[US-1:3]}  :
	                (psl == 3'd2) ? {3'b000, p_da[US-1:2]}   :
	                (psl == 3'd1) ? {2'b00, p_da[US-1:1]}    : {1'b0, p_da};

	/* Line pixels: LINE_BYTES >> psl */
	wire [US:0] line_pixels = line_pix;

	/* Forward: line_pixels - da_px; Reverse: da_px + 1 */
	wire [US:0] room_f;

	assign room_f[0] = da_px[0];
	assign room_r[0] = ~da_px[0];

	genvar g_rf;
	generate
		for (g_rf = 1; g_rf < US; g_rf = g_rf + 1) begin : g_rf_bits
			assign room_f[g_rf] = (|line_pixels[US:g_rf+1]) ?
				(da_px[g_rf] ^ (|da_px[g_rf-1:0])) :
				((da_px[g_rf-1:0] == {g_rf{1'b0}}) & line_pixels[g_rf]);
			assign room_r[g_rf] = da_px[g_rf] ^ (&da_px[g_rf-1:0]);
		end
	endgenerate

	assign room_f[US] = (da_px[US-1:0] == {US{1'b0}}) & line_pixels[US];
	assign room_r[US] = da_px[US] ^ (&da_px[US-1:0]);
	wire [2:0] tile_room_d = {px == 2'b00, px[1] ^ px[0], px[0]};
	wire [2:0] tile_room_s = {spx == 2'b00, spx[1] ^ spx[0], spx[0]};

	wire rem_large = |rem[16:US];
	wire tiled = dtile || stile;

	wire [US:0] fwd_rem = {1'b0, rem[US-1:0]};
	wire [US:0] room_line = rev ? room_r : room_f;
	wire [2:0] room_t3 = tile_room_d;
	wire [2:0] room_s3 = tile_room_s;
	wire [2:0] room_tile3 = (dtile && stile) ? (room_t3 < room_s3 ? room_t3 : room_s3) :
	                        dtile ? room_t3 : room_s3;
	wire tile_lt_line = (|room_line[US:3]) || (room_tile3 < room_line[2:0]);
	wire take_tile = tiled && tile_lt_line;
	wire [US:0] room_calc = {take_tile ? {(US-2){1'b0}} : room_line[US:3],
	                         take_tile ? room_tile3     : room_line[2:0]};
	assign room = room_calc;
	wire [US:0] eff_room = BURST ? in_room : (use_in_room ? in_room : room_calc);

	wire rem_done = !rem_large && (fwd_rem <= eff_room);
	assign seg_n = rem_done ? fwd_rem : eff_room;
	assign seg_last = rem_done;

	/* The bytes back from the rightmost pixel, and the source window. */
	am_sub #(.W(US + 1)) s_bn (.a(sn), .b({(US + 1){1'b0}}), .bi(1'b1), .d(back_n), .bo(seg_co_unused[2]));
	assign back = (psl == 3'd4) ? {{(ADDR_W - US - 5){1'b0}}, back_n, 4'b0000} :
	              (psl == 3'd3) ? {{(ADDR_W - US - 4){1'b0}}, back_n, 3'b000}  :
	              (psl == 3'd2) ? {{(ADDR_W - US - 3){1'b0}}, back_n, 2'b00}   :
	              (psl == 3'd1) ? {{(ADDR_W - US - 2){1'b0}}, back_n, 1'b0}    :
	                              {{(ADDR_W - US - 1){1'b0}}, back_n};
	am_sub #(.W(ADDR_W)) s_sb (.a(slo), .b({{(ADDR_W - US){1'b0}}, dlo}), .bi(1'b0), .d(src_base),
		.bo(seg_co_unused[3]));
	am_add #(.W(ADDR_W)) a_sn (.a(slo), .b({{(ADDR_W - US - 1){1'b0}}, snu}), .ci(1'b0), .s(src_next),
		.co(seg_co_unused[4]));
	am_sub #(.W(ADDR_W)) s_sl (.a(src_next), .b({ADDR_W{1'b0}}), .bi(1'b1), .d(src_last), .bo(seg_co_unused[5]));
	assign last_line = src_last[ADDR_W-1:US];

	/* The end of the write's bytes. */
	am_add #(.W(US + 1)) a_pe (.a({1'b0, p0}), .b(snu), .ci(1'b0), .s(p_end), .co(seg_co_unused[6]));
	integer u;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [US-1:0] p0_l, p0_h;
	genvar g_p0;
	generate
		for (g_p0 = 0; g_p0 < US; g_p0 = g_p0 + 1) begin : g_p0_bufs
			LUT1 #(.INIT(2'b10)) u_p0_l (.I0(p0[g_p0]), .O(p0_l[g_p0]));
			LUT1 #(.INIT(2'b10)) u_p0_h (.I0(p0[g_p0]), .O(p0_h[g_p0]));
		end
	endgenerate
`else
	wire [US-1:0] p0_l = p0, p0_h = p0;
`endif
	wire [US:0] pend_l = p_end, pend_h = p_end;

	always @(*) begin
		for (u = 0; u < 16; u = u + 1)
			be[u] = u[US:0] >= {1'b0, p0_l} && u[US:0] < pend_l && !keep[u % 4];
		for (u = 16; u < LINE_BYTES; u = u + 1)
			be[u] = u[US:0] >= {1'b0, p0_h} && u[US:0] < pend_h && !keep[u % 4];
	end

	wire unused_ok = &{1'b0, src_last[US-1:0], keep, seg_co_unused};
endmodule

`default_nettype wire
