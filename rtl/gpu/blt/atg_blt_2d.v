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

	/* The byte offset of pixel x in a row (linear or in 4x4 tiles). */
	function [ADDR_W-1:0] x_bytes;
		input [16:0] x;
		input tiled;
		input [2:0] pl;
		x_bytes = (tiled ? {{(ADDR_W - 19){1'b0}}, x[16:2], 2'b00, x[1:0]} :
			{{(ADDR_W - 17){1'b0}}, x}) << pl;
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
	wire [2*LINE_BITS-1:0] shifted = both >> {src_off, 3'd0};
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
	wire [ADDR_W-1:0] tile_step = {{(ADDR_W - 3){1'b0}}, 3'd4} << psl;
	wire [ADDR_W-1:0] tile_back = {{(ADDR_W - 4){1'b0}}, 4'd12} << psl;
	wire [ADDR_W-1:0] dst_step = m_dtile ? (ydl == 2'd3 ? dstride_u - tile_back : tile_step) :
		dstride_u;
	wire [ADDR_W-1:0] src_step = m_stile ? (ysl == 2'd3 ? sstride_u - tile_back : tile_step) :
		sstride_u;

	/* S_START: the first row (the last one when reversed). */
	wire [16:0] yd_start = m_rev ? y1 - 1'b1 : y0;
	wire [16:0] ys_start = m_rev ? sy0 + rows : sy0;
	wire row_go = state == S_START;
	wire row_add = state == S_WR && wr_go && seg_last;
	wire [ADDR_W-1:0] dst_row, src_row;
	wire d_idle, s_idle;

	atg_blt_acc dacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_dtile ? {2'b00, yd_start[16:2]} : yd_start), .s(dstride_u),
		.b(dbase_u + (m_dtile ? {{(ADDR_W - 4){1'b0}}, yd_start[1:0], 2'b00} << psl :
			{ADDR_W{1'b0}})),
		.add(row_add), .d(m_rev ? 32'd0 - dstride_u : dst_step), .r(dst_row), .idle(d_idle)
	);
	atg_blt_acc sacc (
		.clk(clk), .rst_n(rst_n), .go(row_go),
		.y(m_stile ? {2'b00, ys_start[16:2]} : ys_start), .s(sstride_u),
		.b(sbase_u + (m_stile ? {{(ADDR_W - 4){1'b0}}, ys_start[1:0], 2'b00} << psl :
			{ADDR_W{1'b0}})),
		.add(row_add), .d(m_rev ? 32'd0 - sstride_u : src_step), .r(src_row), .idle(s_idle)
	);

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
					da <= dst_row + x_bytes(px, m_dtile, psl);
					sa <= src_row + x_bytes(spx, m_stile, psl);
				end
			S_SB: begin
				state <= S_SC;
				sn <= seg_n;
				snu <= seg_n << psl;
			end
			S_SC: begin
				state <= S_SD;
				dlo <= m_rev ? da - back : da;
				slo <= m_rev ? sa - back : sa;
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

	wire unused_ok = &{1'b0, shifted[2*LINE_BITS-1:LINE_BITS], c_op2, c_resolve};
endmodule

`default_nettype wire
