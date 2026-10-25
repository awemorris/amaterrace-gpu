/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_2d: the blitter's 2D engine (atg_blt routes to it the kicks with
 * BLT_OP[2] = 0): FILL, COPY, TILE (linear to 4x4 tiles) and UNTILE of a
 * rectangle through the blitter's AMB port (atg_mc), one blit per kick,
 * with the state of atg_blt_cfg (STATE 0x000-0x00A, 0x00C-0x00E as the CP
 * writes them, docs/ghci.md sections 8.2 and 8.5): pixels of 8, 16, 32,
 * 64 or 128 bits, blend-over of 32-bit FILL and COPY (atg_blt_blend), the
 * reverse direction of FILL and COPY (the bottom row first, right to
 * left), KEEP (32-bit FILL and COPY: the bytes of each pixel not written),
 * and the clip rectangle.  Other combinations are refused with an error
 * of kind OPCODE.
 *
 * The walk works in bytes: segments inside one destination line (and one
 * row of a tile), their addresses in four cycles (atg_blt_seg); FILL
 * streams its writes; COPY, TILE and UNTILE wait for every earlier write
 * (the MC does not order a read after a write), read the one or two
 * source lines (atg_blt_port) and shift them into place; blend-over reads
 * the destination line too.  busy, done and error (kind AXI after an error
 * response, when every request is answered) as spec/gpu/blt/atg_blt_2d.md.
 *
 * States: S_IDLE →(kick)→ S_CLIP → S_START → S_MUL → S_SA → S_SB → S_SC →
 * S_SD → [S_CRD → S_CWAIT] → [S_DRD → S_DWAIT → S_BLEND] → S_WR → S_SA
 * (next segment or row) or S_DRAIN → S_IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_2d #(
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
	localparam US = LINE_SHIFT;		/* log2 of the bytes of a line */
	localparam LA_W = ADDR_W - LINE_SHIFT;

	/* The state and the operation (atg_blt_cfg). */
	wire [1:0] o_op;
	wire o_blend, o_rev, op_ok;
	wire [2:0] o_psl;
	wire [3:0] o_keep;
	wire [16:0] clip_x0, clip_y0, clip_x1, clip_y1, dx, dy;
	wire [31:0] s_src_xy, dbase_u, sbase_u, dstride_u, sstride_u;
	wire [LINE_BITS-1:0] fill_line;
	wire c_op2;
	wire [8:0] c_resolve;

	atg_blt_cfg #(.LINE_BYTES(LINE_BYTES)) cfg (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.op(o_op), .op2(c_op2), .resolve(c_resolve), .blend(o_blend), .rev(o_rev), .psl(o_psl), .keep(o_keep), .op_ok(op_ok),
		.x0(clip_x0), .y0(clip_y0), .x1(clip_x1), .y1(clip_y1), .dx(dx), .dy(dy),
		.src_xy(s_src_xy), .dbase(dbase_u), .sbase(sbase_u), .dstride(dstride_u),
		.sstride(sstride_u), .fill_line(fill_line)
	);

	/* The mode of the blit in progress, taken at the kick. */
	reg m_copy;		/* reads a source: COPY, TILE, UNTILE */
	reg m_blend;
	reg m_rev;
	reg m_dtile, m_stile;	/* the destination (TILE), the source (UNTILE) is tiled */
	reg [2:0] psl;		/* log2 of the pixel's bytes */
	reg [3:0] m_keep;

	/* The pixel offset of pixel x in a row (linear or in 4x4 tiles); its bytes are this << psl. */
	function [ADDR_W-1:0] x_pixels;
		input [16:0] x;
		input tiled;
		x_pixels = tiled ? {{(ADDR_W - 19){1'b0}}, x[16:2], 2'b00, x[1:0]} :
			{{(ADDR_W - 17){1'b0}}, x};
	endfunction

	/* A tile row's bytes, 4 << psl, and three of them, 12 << psl, by table. */
	function [ADDR_W-1:0] tile_bytes;
		input [2:0] pl;
		input three;
		reg [ADDR_W-1:0] t;
		begin
			case (pl)
			3'd0: t = 4;
			3'd1: t = 8;
			3'd2: t = 16;
			3'd3: t = 32;
			3'd4: t = 64;
			3'd5: t = 128;
			3'd6: t = 256;
			default: t = 512;
			endcase
			tile_bytes = three ? {t[ADDR_W-2:0], 1'b0} | t : t;
		end
	endfunction

	localparam [3:0] S_IDLE = 4'd0;
	localparam [3:0] S_CLIP = 4'd1;		/* size and source origin */
	localparam [3:0] S_START = 4'd2;	/* the first row and pixel */
	localparam [3:0] S_MUL = 4'd3;		/* row addresses: y * stride */
	localparam [3:0] S_SA = 4'd4;		/* segment: the pixel's addresses */
	localparam [3:0] S_SB = 4'd5;		/* segment: its length */
	localparam [3:0] S_SC = 4'd6;		/* segment: its first byte */
	localparam [3:0] S_SD = 4'd7;		/* segment: lines and shift */
	localparam [3:0] S_CRD = 4'd8;		/* read the source lines */
	localparam [3:0] S_CWAIT = 4'd9;	/* wait for them */
	localparam [3:0] S_DRD = 4'd10;		/* blend: read the destination line */
	localparam [3:0] S_DWAIT = 4'd11;	/* wait for it */
	localparam [3:0] S_BLEND = 4'd12;	/* blend the line */
	localparam [3:0] S_WR = 4'd13;		/* queue the segment's write */
	localparam [3:0] S_DRAIN = 4'd14;	/* wait for every response */

	reg [3:0] state;

	/* The rectangle. */
	reg [16:0] x0, y0, x1, y1;
	wire empty = x1 <= x0 || y1 <= y0;
	reg [16:0] width, rows;	/* rows: left after this one */
	reg [16:0] sx0, sy0;	/* the source pixel of x0, y0 */
	reg [16:0] px_row, spx_row;	/* the first pixel of every row */

	/* Row walking: the row's y modulo 4 (tiles); the rows' byte addresses
	 * (base + y stride, then + the step a row) in atg_blt_acc. */
	reg [1:0] ydl, ysl;
	reg [16:0] px, spx;	/* the next pixel (rightmost reversed), its source pixel */
	reg [16:0] rem;		/* pixels left in the row */

	/* The segment. */
	reg [ADDR_W-1:0] da, sa;	/* byte addresses of px, spx */
	reg [US:0] sn, snu;	/* pixels, bytes */
	reg [ADDR_W-1:0] dlo, slo;	/* first destination and source bytes */
	reg [LA_W-1:0] seg_line;
	reg [US-1:0] seg_p0;
	reg [US-1:0] src_off;
	reg [LA_W-1:0] src_n0, src_n1;
	reg n0_slot;
	reg rd_first, rd_second;	/* the first, a needed second source read is to go */

	/* The segment's geometry (atg_blt_seg, combinational). */
	wire [US:0] seg_n;
	wire [ADDR_W-1:0] back, src_base_u;
	wire [LA_W-1:0] last_line;
	wire [LINE_BYTES-1:0] seg_be;

	atg_blt_seg #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) seg (
		.psl(psl), .rev(m_rev), .dtile(m_dtile), .stile(m_stile), .keep(m_keep),
		.da(da[US-1:0]), .px(px[1:0]), .spx(spx[1:0]), .rem(rem), .sn(sn), .snu(snu), .dlo(dlo[US-1:0]),
		.slo(slo), .p0(seg_p0), .seg_n(seg_n), .back(back), .src_base(src_base_u),
		.last_line(last_line), .be(seg_be)
	);
	wire [LA_W-1:0] src_lo = src_base_u[ADDR_W-1:US];

	/* The port: the request, the outstanding requests, the line buffers. */
	wire q_free, rd_idle, wr_idle, fail;
	wire [LINE_BITS-1:0] buf0, buf1, bufd;
	wire rd_go = state == S_CRD && q_free && wr_idle && !fail && (rd_first || rd_second);
	wire drd_go = state == S_DRD && q_free && wr_idle && !fail;
	wire wr_go = state == S_WR && q_free && !fail;

	/* The copied line: the source window shifted by whole bytes. */
	wire [2*LINE_BITS-1:0] both = {buf1, buf0};
	wire [2*LINE_BITS-1:0] shifted;

	am_shift #(.W(2 * LINE_BITS), .SW(US + 3)) h_copy (.a(both), .amt({src_off, 3'd0}), .left(1'b0), .arith(1'b0),
		.y(shifted));
	wire [LINE_BITS-1:0] copy_line = shifted[LINE_BITS-1:0];

	/* Blend-over. */
	wire bl_done;
	wire [LINE_BITS-1:0] bl_out;
	reg bl_go;

	atg_blt_blend #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) bl (
		.clk(clk), .rst_n(rst_n), .go(bl_go), .src(m_copy ? copy_line : fill_line),
		.dst(bufd), .done(bl_done), .out(bl_out)
	);

	atg_blt_port #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) port (
		.clk(clk), .rst_n(rst_n), .clr(state == S_IDLE && kick),
		.issue(rd_go || drd_go || wr_go), .i_write(wr_go),
		.i_line(rd_go ? (rd_first ? src_n0 : src_n1) : seg_line),
		.i_slot(rd_go ? (rd_first ? {1'b0, n0_slot} : 2'd1) : drd_go ? 2'd2 : 2'd0),
		.i_be(wr_go ? seg_be : {LINE_BYTES{1'b1}}),
		.i_wdata(m_blend ? bl_out : m_copy ? copy_line : fill_line),
		.free(q_free), .rd_idle(rd_idle), .wr_idle(wr_idle), .fail(fail),
		.buf0(buf0), .buf1(buf1), .bufd(bufd),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
		.req_line(req_line), .req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
	);

	assign busy = state != S_IDLE;

	/* The segment's end: the next pixel, or the next row. */
	wire [16:0] sn17 = {{(16 - US){1'b0}}, sn};
	wire seg_last = rem == sn17;
	wire [ADDR_W-1:0] tile_step = tile_bytes(psl, 1'b0);
	wire [ADDR_W-1:0] tile_back = tile_bytes(psl, 1'b1);
	wire [ADDR_W-1:0] dst_back, src_back;
	wire [31:0] dst_neg, src_neg;
	wire [16:0] y1_last, ys_rev;
	wire [5:0] step_co_unused;

	am_sub #(.W(ADDR_W)) s_dback (.a(dstride_u), .b(tile_back), .bi(1'b0), .d(dst_back), .bo(step_co_unused[0]));
	am_sub #(.W(ADDR_W)) s_sback (.a(sstride_u), .b(tile_back), .bi(1'b0), .d(src_back), .bo(step_co_unused[1]));
	am_sub #(.W(32)) s_dneg (.a(32'd0), .b(dstride_u), .bi(1'b0), .d(dst_neg), .bo(step_co_unused[2]));
	am_sub #(.W(32)) s_sneg (.a(32'd0), .b(sstride_u), .bi(1'b0), .d(src_neg), .bo(step_co_unused[3]));
	wire [ADDR_W-1:0] dst_step = m_dtile ? (ydl == 2'd3 ? dst_back : tile_step) :
		dstride_u;
	wire [ADDR_W-1:0] src_step = m_stile ? (ysl == 2'd3 ? src_back : tile_step) :
		sstride_u;

	/* S_START: the first row (the last one when reversed). */
	am_sub #(.W(17)) s_y1 (.a(y1), .b(17'd0), .bi(1'b1), .d(y1_last), .bo(step_co_unused[4]));
	am_add #(.W(17)) a_ys (.a(sy0), .b(rows), .ci(1'b0), .s(ys_rev), .co(step_co_unused[5]));
	wire [16:0] yd_start = m_rev ? y1_last : y0;
	wire [16:0] ys_start = m_rev ? ys_rev : sy0;
	wire row_go = state == S_START;
	wire row_add = state == S_WR && wr_go && seg_last;
	wire [ADDR_W-1:0] dst_row, src_row;
	wire d_idle, s_idle;

	/* The first row's address within its tile row: (y mod 4) x 4 pixels, in bytes. */
	wire [ADDR_W-1:0] d_in_tile, s_in_tile;
	wire [31:0] d_first, s_first;
	wire [1:0] first_co_unused;

	am_shift #(.W(ADDR_W), .SW(3)) h_dt (.a(m_dtile ? {{(ADDR_W - 4){1'b0}}, yd_start[1:0], 2'b00} : {ADDR_W{1'b0}}),
		.amt(psl), .left(1'b1), .arith(1'b0), .y(d_in_tile));
	am_shift #(.W(ADDR_W), .SW(3)) h_st (.a(m_stile ? {{(ADDR_W - 4){1'b0}}, ys_start[1:0], 2'b00} : {ADDR_W{1'b0}}),
		.amt(psl), .left(1'b1), .arith(1'b0), .y(s_in_tile));
	am_add #(.W(32)) a_df (.a(dbase_u), .b(d_in_tile), .ci(1'b0), .s(d_first), .co(first_co_unused[0]));
	am_add #(.W(32)) a_sf (.a(sbase_u), .b(s_in_tile), .ci(1'b0), .s(s_first), .co(first_co_unused[1]));

	atg_blt_acc dacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_dtile ? {2'b00, yd_start[16:2]} : yd_start), .s(dstride_u),
		.b(d_first),
		.add(row_add), .d(m_rev ? dst_neg : dst_step), .r(dst_row), .idle(d_idle)
	);
	atg_blt_acc sacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_stile ? {2'b00, ys_start[16:2]} : ys_start), .s(sstride_u),
		.b(s_first),
		.add(row_add), .d(m_rev ? src_neg : src_step), .r(src_row), .idle(s_idle)
	);

	/*
	 * The FSM's sums, each for the state that takes it: the rectangle's
	 * size and source origin (S_CLIP), the rows' first pixels (S_START),
	 * the pixel's addresses (S_SA), the segment's bytes (S_SB), its first
	 * bytes (S_SC), and the next pixel, row and the pixels left (S_WR).
	 */
	wire [16:0] c_width, c_rows, c_dx, c_dy, c_sx0, c_sy0, x1_last, s_end, s_last;
	wire [ADDR_W-1:0] d_px, s_px, d_xb, s_xb, d_addr, s_addr, d_lo, s_lo;
	wire [US:0] seg_bytes;
	wire [1:0] ydl_inc, ysl_inc;
	wire [16:0] rows_dec, px_next, spx_next, rem_next;
	wire [18:0] fsm_co_unused;

	am_sub #(.W(17)) s_w (.a(x1), .b(x0), .bi(1'b0), .d(c_width), .bo(fsm_co_unused[0]));
	am_sub #(.W(17)) s_rows (.a(y1), .b(y0), .bi(1'b1), .d(c_rows), .bo(fsm_co_unused[1]));
	am_sub #(.W(17)) s_cdx (.a(x0), .b(dx), .bi(1'b0), .d(c_dx), .bo(fsm_co_unused[2]));
	am_sub #(.W(17)) s_cdy (.a(y0), .b(dy), .bi(1'b0), .d(c_dy), .bo(fsm_co_unused[3]));
	am_add #(.W(17)) a_sx0 (.a({1'b0, s_src_xy[15:0]}), .b(c_dx), .ci(1'b0), .s(c_sx0), .co(fsm_co_unused[4]));
	am_add #(.W(17)) a_sy0 (.a({1'b0, s_src_xy[31:16]}), .b(c_dy), .ci(1'b0), .s(c_sy0), .co(fsm_co_unused[5]));
	am_sub #(.W(17)) s_x1 (.a(x1), .b(17'd0), .bi(1'b1), .d(x1_last), .bo(fsm_co_unused[6]));
	am_add #(.W(17)) a_send (.a(sx0), .b(width), .ci(1'b0), .s(s_end), .co(fsm_co_unused[7]));
	am_sub #(.W(17)) s_slast (.a(s_end), .b(17'd0), .bi(1'b1), .d(s_last), .bo(fsm_co_unused[8]));
	assign d_px = x_pixels(px, m_dtile);
	assign s_px = x_pixels(spx, m_stile);
	am_shift #(.W(ADDR_W), .SW(3)) h_dx (.a(d_px), .amt(psl), .left(1'b1), .arith(1'b0), .y(d_xb));
	am_shift #(.W(ADDR_W), .SW(3)) h_sx (.a(s_px), .amt(psl), .left(1'b1), .arith(1'b0), .y(s_xb));
	am_add #(.W(ADDR_W)) a_da (.a(dst_row), .b(d_xb), .ci(1'b0), .s(d_addr), .co(fsm_co_unused[9]));
	am_add #(.W(ADDR_W)) a_sa (.a(src_row), .b(s_xb), .ci(1'b0), .s(s_addr), .co(fsm_co_unused[10]));
	am_shift #(.W(US + 1), .SW(3)) h_sn (.a(seg_n), .amt(psl), .left(1'b1), .arith(1'b0), .y(seg_bytes));
	am_sub #(.W(ADDR_W)) s_dlo (.a(da), .b(back), .bi(1'b0), .d(d_lo), .bo(fsm_co_unused[11]));
	am_sub #(.W(ADDR_W)) s_slo (.a(sa), .b(back), .bi(1'b0), .d(s_lo), .bo(fsm_co_unused[12]));
	am_add #(.W(2)) a_ydl (.a(ydl), .b(2'd0), .ci(1'b1), .s(ydl_inc), .co(fsm_co_unused[13]));
	am_add #(.W(2)) a_ysl (.a(ysl), .b(2'd0), .ci(1'b1), .s(ysl_inc), .co(fsm_co_unused[14]));
	am_sub #(.W(17)) s_rdec (.a(rows), .b(17'd0), .bi(1'b1), .d(rows_dec), .bo(fsm_co_unused[15]));
	am_addsub #(.W(17)) as_px (.a(px), .b(sn17), .sub(m_rev), .s(px_next), .co(fsm_co_unused[16]));
	am_addsub #(.W(17)) as_spx (.a(spx), .b(sn17), .sub(m_rev), .s(spx_next), .co(fsm_co_unused[17]));
	am_sub #(.W(17)) s_rem (.a(rem), .b(sn17), .bi(1'b0), .d(rem_next), .bo(fsm_co_unused[18]));

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			m_copy <= 1'b0;
			m_blend <= 1'b0;
			m_rev <= 1'b0;
			m_dtile <= 1'b0;
			m_stile <= 1'b0;
			psl <= 3'd2;
			m_keep <= 4'd0;
			rd_first <= 1'b0;
			rd_second <= 1'b0;
			bl_go <= 1'b0;
		end else begin
			done <= 1'b0;
			error <= 1'b0;
			bl_go <= 1'b0;

			case (state)
			S_IDLE:
				if (kick) begin
					m_copy <= o_op != GHCI_BLT_FILL;
					m_blend <= o_blend;
					m_rev <= o_rev;
					m_dtile <= o_op == GHCI_BLT_TILE;
					m_stile <= o_op == GHCI_BLT_UNTILE;
					psl <= o_psl;
					m_keep <= o_keep;
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
					width <= c_width;
					rows <= c_rows;
					sx0 <= c_sx0;
					sy0 <= c_sy0;
				end
			S_START: begin
				state <= S_MUL;
				px_row <= m_rev ? x1_last : x0;
				spx_row <= m_rev ? s_last : sx0;
				ydl <= yd_start[1:0];
				ysl <= ys_start[1:0];
			end
			S_MUL:
				if (d_idle && s_idle) begin
					state <= S_SA;
					px <= px_row;
					spx <= spx_row;
					rem <= width;
				end
			S_SA:
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					state <= S_SB;
					da <= d_addr;
					sa <= s_addr;
				end
			S_SB: begin
				state <= S_SC;
				sn <= seg_n;
				snu <= seg_bytes;
			end
			S_SC: begin
				state <= S_SD;
				dlo <= m_rev ? d_lo : da;
				slo <= m_rev ? s_lo : sa;
			end
			S_SD: begin
				seg_line <= dlo[ADDR_W-1:US];
				seg_p0 <= dlo[US-1:0];
				src_off <= src_base_u[US-1:0];
				src_n0 <= slo[ADDR_W-1:US];
				src_n1 <= last_line;
				n0_slot <= slo[ADDR_W-1:US] != src_lo;
				rd_first <= 1'b1;
				state <= m_copy ? S_CRD : m_blend ? S_DRD : S_WR;
			end
			S_CRD:
				if (fail) begin
					state <= S_DRAIN;
				end else if (q_free && wr_idle) begin
					if (rd_first) begin
						rd_first <= 1'b0;
						rd_second <= src_n1 != src_n0;
					end else if (rd_second) begin
						rd_second <= 1'b0;
					end else begin
						state <= S_CWAIT;
					end
				end
			S_CWAIT:
				if (fail)
					state <= S_DRAIN;
				else if (q_free && rd_idle)
					state <= m_blend ? S_DRD : S_WR;
			S_DRD:
				if (fail)
					state <= S_DRAIN;
				else if (drd_go)
					state <= S_DWAIT;
			S_DWAIT:
				if (fail) begin
					state <= S_DRAIN;
				end else if (q_free && rd_idle) begin
					state <= S_BLEND;
					bl_go <= 1'b1;
				end
			S_BLEND:
				if (bl_done)
					state <= S_WR;
			S_WR:
				if (fail) begin
					state <= S_DRAIN;
				end else if (wr_go) begin
					if (seg_last) begin
						ydl <= ydl_inc;
						ysl <= ysl_inc;
						px <= px_row;
						spx <= spx_row;
						rem <= width;
						rows <= rows_dec;
						state <= rows == 17'd0 ? S_DRAIN : S_SA;
					end else begin
						px <= px_next;
						spx <= spx_next;
						rem <= rem_next;
						state <= S_SA;
					end
				end
			S_DRAIN:
				if (q_free && wr_idle && rd_idle && !rsp_valid) begin
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

	wire unused_ok = &{1'b0, shifted[2*LINE_BITS-1:LINE_BITS], c_op2, c_resolve, step_co_unused, first_co_unused,
		fsm_co_unused};
endmodule

`default_nettype wire
