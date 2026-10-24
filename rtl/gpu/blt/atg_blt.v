/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt: the blitter.  It takes its parameters from the BLT
 * range of the state register file (STATE[0x000..0x00A], docs/ghci.md),
 * seen as the CP writes them (st_we), and runs one blit per kick through
 * its AMB port (atg_mc):
 *
 *   FILL    writes COLOR to every pixel of the destination rectangle
 *   COPY    copies the source rectangle to the destination
 *   TILE    copies a linear source into a destination in 4x4 tiles
 *   UNTILE  copies a source in 4x4 tiles into a linear destination
 *
 * with BLT_OP's options: 16- or 32-bit pixels (bases and strides are taken
 * as multiples of the pixel size: their low bits are ignored), blend-over
 * (FILL and COPY of 32-bit pixels: source-over with premultiplied alpha in
 * bits 31:24, out = src + dst * (255 - src.a) / 255 per byte, rounded and
 * saturated) and the reverse direction (FILL and COPY: the bottom row
 * first, right to left, for an overlapping copy whose destination lies
 * after its source).  Other combinations are refused with an error of kind
 * OPCODE.  The rectangle is clipped to [CLIP_MIN, CLIP_MAX) when CLIP_MAX
 * is not 0; the source moves with it.
 *
 * The 4x4 tile layout (Amaterrace's, CAPS[11]): 16 pixels per tile, stored
 * row by row inside the tile, tiles left to right; the stride is the bytes
 * of one row of tiles.  Pixel (x, y) of a tiled image is at
 *   base + (y / 4) * stride + (x / 4) * 16 * ps + ((y % 4) * 4 + x % 4) * ps
 * with ps the pixel size in bytes.  A tiled base and stride are multiples
 * of a tile (16 * ps bytes).
 *
 * The walk works in 16-bit units.  A row is cut into segments that stay
 * inside one destination line (and, in a tiled image, inside one row of a
 * tile).  For each segment the blitter computes its addresses (four
 * cycles), then: FILL queues the write and goes on with the next segment
 * (writes stream, up to the MC's outstanding limit); COPY, TILE and UNTILE
 * wait for every earlier write (so that an overlapping copy reads what it
 * must), read the one or two source lines that cover the segment, shift
 * them by whole units and write; blend-over reads the destination line as
 * well and combines one 32-bit pixel per cycle (a three-stage pipeline)
 * before the write.  The write's byte enables cover the segment only.
 * (The MC does not order a read after an earlier write; waiting for every
 * write gives each read the memory the earlier segments left.  Waiting
 * only for writes to the lines read, with a table of eight lines, made a
 * copy on the ZYBO 19% faster for 0.75k more LUTs, and was not kept: a
 * copy is bound by the read latency, one segment at a time.)
 *
 * busy is 1 from kick to done or error (one-cycle pulses).  An error
 * response stops new requests; the error pulse comes when every request
 * is answered.  A kick while busy is ignored (the CP does not make one).
 * Under the MC's quiesce the port's request waits, and the blit goes on
 * where it stopped when the quiesce ends.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,

	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	input wire kick,
	output wire busy,
	output reg done,
	output reg error,
	output reg [3:0] error_kind,

	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,

	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam LINE_BITS = LINE_BYTES * 8;
	localparam WPL = LINE_BYTES / 4;	/* 32-bit words per line */
	localparam LU = LINE_BYTES / 2;		/* 16-bit units per line */
	localparam US = LINE_SHIFT - 1;		/* log2(LU) */
	localparam WS = LINE_SHIFT - 2;		/* log2(WPL) */
	localparam UA = ADDR_W - 1;		/* unit address width */
	localparam LA_W = ADDR_W - LINE_SHIFT;

	/* verilator lint_off WIDTHTRUNC */
	localparam [US:0] LU_V = LU;
	localparam [WS:0] WPL_V = WPL;
	/* verilator lint_on WIDTHTRUNC */

	/* The BLT state, as written. */
	reg [31:0] s_op;
	reg [31:0] s_dst_base;
	reg [31:0] s_dst_stride;
	reg [31:0] s_src_base;
	reg [31:0] s_src_stride;
	reg [31:0] s_dst_xy;
	reg [31:0] s_src_xy;
	reg [31:0] s_size;
	reg [31:0] s_color;
	reg [31:0] s_clip_min;
	reg [31:0] s_clip_max;

	always @(posedge clk) begin
		if (!rst_n) begin
			s_op <= 32'd0;
			s_dst_base <= 32'd0;
			s_dst_stride <= 32'd0;
			s_src_base <= 32'd0;
			s_src_stride <= 32'd0;
			s_dst_xy <= 32'd0;
			s_src_xy <= 32'd0;
			s_size <= 32'd0;
			s_color <= 32'd0;
			s_clip_min <= 32'd0;
			s_clip_max <= 32'd0;
		end else if (st_we) begin
			case (st_idx)
			GHCI_S_BLT_OP: s_op <= st_wdata;
			GHCI_S_BLT_DST_BASE: s_dst_base <= st_wdata;
			GHCI_S_BLT_DST_STRIDE: s_dst_stride <= st_wdata;
			GHCI_S_BLT_SRC_BASE: s_src_base <= st_wdata;
			GHCI_S_BLT_SRC_STRIDE: s_src_stride <= st_wdata;
			GHCI_S_BLT_DST_XY: s_dst_xy <= st_wdata;
			GHCI_S_BLT_SRC_XY: s_src_xy <= st_wdata;
			GHCI_S_BLT_SIZE: s_size <= st_wdata;
			GHCI_S_BLT_COLOR: s_color <= st_wdata;
			GHCI_S_BLT_CLIP_MIN: s_clip_min <= st_wdata;
			GHCI_S_BLT_CLIP_MAX: s_clip_max <= st_wdata;
			default: ;
			endcase
		end
	end

	/* The operation and whether it is one the blitter does. */
	wire [1:0] o_op = s_op[1:0];
	wire o_blend = s_op[GHCI_BLT_OP_BLEND];
	wire [1:0] o_bpp = s_op[9:8];
	wire o_rev = s_op[GHCI_BLT_OP_REVERSE];
	wire o_tiled = o_op == GHCI_BLT_TILE || o_op == GHCI_BLT_UNTILE;
	wire op_ok = !o_bpp[1] && !(o_blend && (o_bpp[0] || o_tiled)) && !(o_rev && o_tiled);

	/* The clipped rectangle, from the state (stable while busy: the CP
	 * writes no BLT state then). */
	wire clip_en = s_clip_max != 32'd0;
	wire [16:0] dx = {1'b0, s_dst_xy[15:0]};
	wire [16:0] dy = {1'b0, s_dst_xy[31:16]};
	wire [16:0] dx_end = dx + {1'b0, s_size[15:0]};
	wire [16:0] dy_end = dy + {1'b0, s_size[31:16]};
	wire [16:0] cx0 = {1'b0, s_clip_min[15:0]};
	wire [16:0] cy0 = {1'b0, s_clip_min[31:16]};
	wire [16:0] cx1 = {1'b0, s_clip_max[15:0]};
	wire [16:0] cy1 = {1'b0, s_clip_max[31:16]};
	wire [16:0] clip_x0 = clip_en && cx0 > dx ? cx0 : dx;
	wire [16:0] clip_y0 = clip_en && cy0 > dy ? cy0 : dy;
	wire [16:0] clip_x1 = clip_en && cx1 < dx_end ? cx1 : dx_end;
	wire [16:0] clip_y1 = clip_en && cy1 < dy_end ? cy1 : dy_end;

	/* The mode of the blit in progress, taken at the kick. */
	reg m_copy;		/* reads a source: COPY, TILE, UNTILE */
	reg m_blend;
	reg m_rev;
	reg m_dtile;		/* the destination is tiled (TILE) */
	reg m_stile;		/* the source is tiled (UNTILE) */
	reg m16;		/* 16-bit pixels */

	/* Pixels to units: x << ps. */
	function [UA-1:0] pix_units;
		input [UA-1:0] x;
		input is16;
		pix_units = is16 ? x : {x[UA-2:0], 1'b0};
	endfunction

	/* The unit offset of pixel x in a row: linear, or in 4x4 tiles. */
	function [UA-1:0] x_units;
		input [16:0] x;
		input tiled;
		input is16;
		x_units = pix_units(tiled ? {{(UA - 19){1'b0}}, x[16:2], 2'b00, x[1:0]} :
			{{(UA - 17){1'b0}}, x}, is16);
	endfunction

	/* Bases and strides in units, their low bits ignored. */
	wire [UA-1:0] unit_mask = {{(UA - 1){1'b1}}, m16};
	wire [UA-1:0] dbase_u = s_dst_base[ADDR_W-1:1] & unit_mask;
	wire [UA-1:0] sbase_u = s_src_base[ADDR_W-1:1] & unit_mask;
	wire [UA-1:0] dstride_u = s_dst_stride[ADDR_W-1:1] & unit_mask;
	wire [UA-1:0] sstride_u = s_src_stride[ADDR_W-1:1] & unit_mask;

	localparam [3:0] S_IDLE = 4'd0;
	localparam [3:0] S_CLIP = 4'd1;		/* size and source origin */
	localparam [3:0] S_START = 4'd2;	/* the first row and pixel */
	localparam [3:0] S_MUL = 4'd3;		/* row addresses: y * stride */
	localparam [3:0] S_SA = 4'd4;		/* segment: the pixel's addresses */
	localparam [3:0] S_SB = 4'd5;		/* segment: its length */
	localparam [3:0] S_SC = 4'd6;		/* segment: its first unit */
	localparam [3:0] S_SD = 4'd7;		/* segment: lines and shift */
	localparam [3:0] S_CRD = 4'd8;		/* read the source lines */
	localparam [3:0] S_CWAIT = 4'd9;	/* wait for them */
	localparam [3:0] S_DRD = 4'd10;		/* blend: read the destination line */
	localparam [3:0] S_DWAIT = 4'd11;	/* wait for it */
	localparam [3:0] S_BLEND = 4'd12;	/* blend the words */
	localparam [3:0] S_WR = 4'd13;		/* queue the segment's write */
	localparam [3:0] S_DRAIN = 4'd14;	/* wait for every response */

	reg [3:0] state;
	reg fail;		/* an error response was seen */

	/* The rectangle. */
	reg [16:0] x0;
	reg [16:0] y0;
	reg [16:0] x1;
	reg [16:0] y1;
	wire empty = x1 <= x0 || y1 <= y0;
	reg [16:0] width;
	reg [16:0] rows;	/* rows left after this one */
	reg [16:0] sx0;		/* the source pixel of x0, y0 */
	reg [16:0] sy0;
	reg [16:0] px_row;	/* the first pixel of every row */
	reg [16:0] spx_row;

	/* Row walking: the row's unit address, its y modulo 4 (tiles). */
	reg [UA-1:0] dst_row;
	reg [UA-1:0] src_row;
	reg [1:0] ydl;
	reg [1:0] ysl;
	reg [16:0] px;		/* the next pixel (leftmost; rightmost reversed) */
	reg [16:0] spx;		/* its source pixel */
	reg [16:0] rem;		/* pixels left in the row */

	/* The shift-and-add multiplier of S_MUL. */
	reg [16:0] mul_dy;
	reg [16:0] mul_sy;
	reg [UA-1:0] mul_ds;
	reg [UA-1:0] mul_ss;

	/* The segment. */
	reg [UA-1:0] da;	/* unit address of px */
	reg [UA-1:0] sa;	/* unit address of spx */
	reg [US:0] sn;		/* pixels */
	reg [US:0] snu;		/* units */
	reg [UA-1:0] dlo;	/* first destination unit */
	reg [UA-1:0] slo;	/* first source unit */
	reg [LA_W-1:0] seg_line;
	reg [US-1:0] seg_p0;
	reg [US-1:0] src_off;
	reg [LA_W-1:0] src_n0;
	reg [LA_W-1:0] src_n1;
	reg n0_slot;
	reg rd_first;		/* the first source read is still to go */
	reg rd_second;		/* a second one is needed and still to go */

	/* Outstanding requests. */
	reg [3:0] wr_out;
	reg [1:0] rd_out;

	/* The line buffers: two source lines, the destination line (blend). */
	reg [LINE_BITS-1:0] buf0;
	reg [LINE_BITS-1:0] buf1;
	reg [LINE_BITS-1:0] bufd;

	/* S_SB: the segment's length from px. */
	wire [US-1:0] p_da = da[US-1:0];
	wire [US:0] room_f_u = LU_V - {1'b0, p_da};
	wire [US:0] room_f = m16 ? room_f_u : {1'b0, room_f_u[US:1]};
	wire [US:0] room_r = (m16 ? {1'b0, p_da} : {2'b00, p_da[US-1:1]}) + 1'b1;
	wire [2:0] tile_room_d = 3'd4 - {1'b0, px[1:0]};
	wire [2:0] tile_room_s = 3'd4 - {1'b0, spx[1:0]};
	wire [US:0] room_t = {{(US - 2){1'b0}}, tile_room_d};
	wire [US:0] room_d = m_rev ? room_r :
		(m_dtile && room_t < room_f) ? room_t : room_f;
	wire [US:0] room_s = {{(US - 2){1'b0}}, tile_room_s};
	wire [US:0] room = (m_stile && room_s < room_d) ? room_s : room_d;
	wire [US:0] seg_n = rem < {{(16 - US){1'b0}}, room} ? rem[US:0] : room;

	/* S_SC: the first unit of the segment (reversed: back by n - 1). */
	wire [UA-1:0] back = pix_units({{(UA - US - 1){1'b0}}, sn - 1'b1}, m16);

	/* S_SD: the source window: the unit that maps to destination unit 0
	 * of the line, its line and the following one. */
	wire [UA-1:0] src_base_u = slo - {{(UA - US){1'b0}}, dlo[US-1:0]};
	wire [UA-1:0] src_last = slo + {{(UA - US - 1){1'b0}}, snu} - 1'b1;
	wire [LA_W-1:0] src_lo = src_base_u[UA-1:US];

	/* The copied line: the source window shifted by whole units. */
	wire [2*LINE_BITS-1:0] both = {buf1, buf0};
	wire [2*LINE_BITS-1:0] shifted = both >> {src_off, 4'd0};
	wire [LINE_BITS-1:0] copy_line = shifted[LINE_BITS-1:0];
	wire [LINE_BITS-1:0] fill_line = m16 ? {LU{s_color[15:0]}} : {WPL{s_color}};

	/* The write's byte enables: units p0 .. p0 + nu - 1. */
	wire [US:0] seg_end = {1'b0, seg_p0} + snu;
	reg [LINE_BYTES-1:0] seg_be;
	integer u;

	always @(*) begin
		for (u = 0; u < LU; u = u + 1)
			seg_be[u*2 +: 2] = {2{u[US:0] >= {1'b0, seg_p0} && u[US:0] < seg_end}};
	end

	/* Blend-over, three stages: the words, the products, the sums. */
	reg [WS:0] bi;		/* the next word to take */
	reg a_v;
	reg [WS-1:0] a_i;
	reg [31:0] a_s;
	reg [31:0] a_d;
	reg b_v;
	reg [WS-1:0] b_i;
	reg [31:0] b_s;
	reg [63:0] b_t;		/* four 16-bit products */
	wire [31:0] bs_word = m_copy ? copy_line[{bi[WS-1:0], 5'd0} +: 32] : s_color;
	wire [31:0] bd_word = bufd[{bi[WS-1:0], 5'd0} +: 32];
	wire [7:0] inv_a = 8'd255 - a_s[31:24];
	reg [31:0] b_out;
	integer c;

	function [15:0] mul8;
		input [7:0] x;
		input [7:0] y;
		mul8 = {8'd0, x} * {8'd0, y};
	endfunction
	reg [16:0] t1;
	reg [16:0] t2;
	reg [8:0] sum;

	always @(*) begin
		b_out = 32'd0;
		t1 = 17'd0;
		t2 = 17'd0;
		sum = 9'd0;
		for (c = 0; c < 4; c = c + 1) begin
			/* (t + 128 + ((t + 128) >> 8)) >> 8 = t / 255, rounded */
			t1 = {1'b0, b_t[c*16 +: 16]} + 17'd128;
			t2 = t1 + {8'd0, t1[16:8]};
			sum = {1'b0, b_s[c*8 +: 8]} + t2[16:8];
			b_out[c*8 +: 8] = sum[8] ? 8'hFF : sum[7:0];
		end
	end

	/* The request. */
	reg q_valid;
	reg q_write;
	reg [LA_W-1:0] q_line;
	reg [1:0] q_slot;	/* reads: 0 buf0, 1 buf1, 2 bufd */
	reg [LINE_BYTES-1:0] q_be;
	reg [LINE_BITS-1:0] q_wdata;

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = q_line;
	assign req_be = q_be;
	assign req_wdata = q_wdata;
	assign req_tag = {5'd0, q_write, q_slot};

	wire q_fire = q_valid && req_ready;
	wire rsp_rd = rsp_valid && !rsp_write;
	wire rsp_wr = rsp_valid && rsp_write;

	assign busy = state != S_IDLE;

	/* The segment's end: the next pixel, or the next row. */
	wire [16:0] sn17 = {{(16 - US){1'b0}}, sn};
	wire seg_last = rem == sn17;
	wire [UA-1:0] tile_step = pix_units({{(UA - 3){1'b0}}, 3'd4}, m16);
	wire [UA-1:0] tile_back = pix_units({{(UA - 4){1'b0}}, 4'd12}, m16);
	wire [UA-1:0] dst_step = m_dtile ? (ydl == 2'd3 ? dstride_u - tile_back : tile_step) :
		dstride_u;
	wire [UA-1:0] src_step = m_stile ? (ysl == 2'd3 ? sstride_u - tile_back : tile_step) :
		sstride_u;

	/* S_START: the first row (the last one when reversed). */
	wire [16:0] yd_start = m_rev ? y1 - 1'b1 : y0;
	wire [16:0] ys_start = m_rev ? sy0 + rows : sy0;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			fail <= 1'b0;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			m_copy <= 1'b0;
			m_blend <= 1'b0;
			m_rev <= 1'b0;
			m_dtile <= 1'b0;
			m_stile <= 1'b0;
			m16 <= 1'b0;
			x0 <= 17'd0;
			y0 <= 17'd0;
			x1 <= 17'd0;
			y1 <= 17'd0;
			width <= 17'd0;
			rows <= 17'd0;
			sx0 <= 17'd0;
			sy0 <= 17'd0;
			px_row <= 17'd0;
			spx_row <= 17'd0;
			dst_row <= {UA{1'b0}};
			src_row <= {UA{1'b0}};
			ydl <= 2'd0;
			ysl <= 2'd0;
			px <= 17'd0;
			spx <= 17'd0;
			rem <= 17'd0;
			mul_dy <= 17'd0;
			mul_sy <= 17'd0;
			mul_ds <= {UA{1'b0}};
			mul_ss <= {UA{1'b0}};
			da <= {UA{1'b0}};
			sa <= {UA{1'b0}};
			sn <= {(US + 1){1'b0}};
			snu <= {(US + 1){1'b0}};
			dlo <= {UA{1'b0}};
			slo <= {UA{1'b0}};
			seg_line <= {LA_W{1'b0}};
			seg_p0 <= {US{1'b0}};
			src_off <= {US{1'b0}};
			src_n0 <= {LA_W{1'b0}};
			src_n1 <= {LA_W{1'b0}};
			n0_slot <= 1'b0;
			rd_first <= 1'b0;
			rd_second <= 1'b0;
			wr_out <= 4'd0;
			rd_out <= 2'd0;
			buf0 <= {LINE_BITS{1'b0}};
			buf1 <= {LINE_BITS{1'b0}};
			bufd <= {LINE_BITS{1'b0}};
			bi <= {(WS + 1){1'b0}};
			a_v <= 1'b0;
			a_i <= {WS{1'b0}};
			a_s <= 32'd0;
			a_d <= 32'd0;
			b_v <= 1'b0;
			b_i <= {WS{1'b0}};
			b_s <= 32'd0;
			b_t <= 64'd0;
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_line <= {LA_W{1'b0}};
			q_slot <= 2'd0;
			q_be <= {LINE_BYTES{1'b0}};
			q_wdata <= {LINE_BITS{1'b0}};
		end else begin
			done <= 1'b0;
			error <= 1'b0;

			/* Outstanding requests and the read lines. */
			wr_out <= wr_out + {3'd0, q_fire && q_write} - {3'd0, rsp_wr};
			rd_out <= rd_out + {1'b0, q_fire && !q_write} - {1'b0, rsp_rd};
			if (rsp_rd) begin
				case (rsp_tag[1:0])
				2'd0: buf0 <= rsp_rdata;
				2'd1: buf1 <= rsp_rdata;
				default: bufd <= rsp_rdata;
				endcase
			end
			if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire)
				q_valid <= 1'b0;

			case (state)
			S_IDLE:
				if (kick) begin
					fail <= 1'b0;
					m_copy <= o_op != GHCI_BLT_FILL;
					m_blend <= o_blend;
					m_rev <= o_rev;
					m_dtile <= o_op == GHCI_BLT_TILE;
					m_stile <= o_op == GHCI_BLT_UNTILE;
					m16 <= o_bpp[0];
					if (!op_ok) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_OPCODE;
					end else begin
						state <= S_CLIP;
						x0 <= clip_x0;
						y0 <= clip_y0;
						x1 <= clip_x1;
						y1 <= clip_y1;
					end
				end
			S_CLIP:
				if (empty) begin
					state <= S_IDLE;
					done <= 1'b1;
				end else begin
					state <= S_START;
					width <= x1 - x0;
					rows <= y1 - y0 - 1'b1;
					sx0 <= {1'b0, s_src_xy[15:0]} + (x0 - dx);
					sy0 <= {1'b0, s_src_xy[31:16]} + (y0 - dy);
				end
			S_START: begin
				state <= S_MUL;
				px_row <= m_rev ? x1 - 1'b1 : x0;
				spx_row <= m_rev ? sx0 + width - 1'b1 : sx0;
				ydl <= yd_start[1:0];
				ysl <= ys_start[1:0];
				mul_dy <= m_dtile ? {2'b00, yd_start[16:2]} : yd_start;
				mul_sy <= m_stile ? {2'b00, ys_start[16:2]} : ys_start;
				mul_ds <= dstride_u;
				mul_ss <= sstride_u;
				dst_row <= dbase_u + (m_dtile ?
					pix_units({{(UA - 4){1'b0}}, yd_start[1:0], 2'b00}, m16) : {UA{1'b0}});
				src_row <= sbase_u + (m_stile ?
					pix_units({{(UA - 4){1'b0}}, ys_start[1:0], 2'b00}, m16) : {UA{1'b0}});
			end
			S_MUL:
				if (mul_dy == 17'd0 && mul_sy == 17'd0) begin
					state <= S_SA;
					px <= px_row;
					spx <= spx_row;
					rem <= width;
				end else begin
					if (mul_dy[0])
						dst_row <= dst_row + mul_ds;
					if (mul_sy[0])
						src_row <= src_row + mul_ss;
					mul_dy <= mul_dy >> 1;
					mul_sy <= mul_sy >> 1;
					mul_ds <= mul_ds << 1;
					mul_ss <= mul_ss << 1;
				end
			S_SA:
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					state <= S_SB;
					da <= dst_row + x_units(px, m_dtile, m16);
					sa <= src_row + x_units(spx, m_stile, m16);
				end
			S_SB: begin
				state <= S_SC;
				sn <= seg_n;
				snu <= m16 ? seg_n : {seg_n[US-1:0], 1'b0};
			end
			S_SC: begin
				state <= S_SD;
				dlo <= m_rev ? da - back : da;
				slo <= m_rev ? sa - back : sa;
			end
			S_SD: begin
				seg_line <= dlo[UA-1:US];
				seg_p0 <= dlo[US-1:0];
				src_off <= src_base_u[US-1:0];
				src_n0 <= slo[UA-1:US];
				src_n1 <= src_last[UA-1:US];
				n0_slot <= slo[UA-1:US] != src_lo;
				rd_first <= 1'b1;
				state <= m_copy ? S_CRD : m_blend ? S_DRD : S_WR;
			end
			S_CRD:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid && wr_out == 4'd0) begin
					if (rd_first) begin
						q_valid <= 1'b1;
						q_write <= 1'b0;
						q_line <= src_n0;
						q_slot <= {1'b0, n0_slot};
						q_be <= {LINE_BYTES{1'b1}};
						rd_first <= 1'b0;
						rd_second <= src_n1 != src_n0;
					end else if (rd_second) begin
						q_valid <= 1'b1;
						q_write <= 1'b0;
						q_line <= src_n1;
						q_slot <= 2'd1;
						q_be <= {LINE_BYTES{1'b1}};
						rd_second <= 1'b0;
					end else begin
						state <= S_CWAIT;
					end
				end
			S_CWAIT:
				if (fail)
					state <= S_DRAIN;
				else if (!q_valid && rd_out == 2'd0)
					state <= m_blend ? S_DRD : S_WR;
			S_DRD:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid && wr_out == 4'd0) begin
					q_valid <= 1'b1;
					q_write <= 1'b0;
					q_line <= seg_line;
					q_slot <= 2'd2;
					q_be <= {LINE_BYTES{1'b1}};
					state <= S_DWAIT;
				end
			S_DWAIT:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid && rd_out == 2'd0) begin
					state <= S_BLEND;
					bi <= {(WS + 1){1'b0}};
					a_v <= 1'b0;
					b_v <= 1'b0;
				end
			S_BLEND: begin
				/* Stage 1: take word bi. */
				a_v <= bi != WPL_V;
				if (bi != WPL_V) begin
					a_s <= bs_word;
					a_d <= bd_word;
					a_i <= bi[WS-1:0];
					bi <= bi + 1'b1;
				end
				/* Stage 2: its products. */
				b_v <= a_v;
				b_s <= a_s;
				b_i <= a_i;
				b_t <= {mul8(a_d[31:24], inv_a), mul8(a_d[23:16], inv_a),
					mul8(a_d[15:8], inv_a), mul8(a_d[7:0], inv_a)};
				/* Stage 3: its sums, back into the line. */
				if (b_v)
					bufd[{b_i, 5'd0} +: 32] <= b_out;
				if (bi == WPL_V && !a_v && !b_v)
					state <= S_WR;
			end
			S_WR:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid) begin
					q_valid <= 1'b1;
					q_write <= 1'b1;
					q_line <= seg_line;
					q_slot <= 2'd0;
					q_be <= seg_be;
					q_wdata <= m_blend ? bufd : m_copy ? copy_line : fill_line;
					if (seg_last) begin
						dst_row <= m_rev ? dst_row - dstride_u : dst_row + dst_step;
						src_row <= m_rev ? src_row - sstride_u : src_row + src_step;
						ydl <= ydl + 1'b1;
						ysl <= ysl + 1'b1;
						px <= px_row;
						spx <= spx_row;
						rem <= width;
						rows <= rows - 1'b1;
						state <= rows == 17'd0 ? S_DRAIN : S_SA;
					end else begin
						px <= m_rev ? px - sn17 : px + sn17;
						spx <= m_rev ? spx - sn17 : spx + sn17;
						rem <= rem - sn17;
						state <= S_SA;
					end
				end
			S_DRAIN:
				if (!q_valid && wr_out == 4'd0 && rd_out == 2'd0 &&
				    !rsp_valid) begin
					state <= S_IDLE;
					if (fail) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_AXI;
					end else begin
						done <= 1'b1;
					end
				end
			default:
				state <= S_IDLE;
			endcase
		end
	end

`ifdef BLT_TRACE
	always @(posedge clk)
		if (q_fire)
			$display("%m t=%0t %s line %h slot %0d be %h px %0d spx %0d rem %0d rows %0d sn %0d",
				$time, q_write ? "W" : "R", q_line, q_slot, q_be, px, spx, rem, rows, sn);
`endif

	wire unused_ok = &{1'b0, s_op[31:13], s_op[11:10], s_op[7:5], s_op[3:2],
		s_dst_base[0], s_src_base[0], s_dst_stride[0], s_src_stride[0],
		rsp_tag[7:2], src_last[US-1:0], shifted[2*LINE_BITS-1:LINE_BITS], t2[7:0]};
endmodule

`default_nettype wire
