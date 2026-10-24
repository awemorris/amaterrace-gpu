/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_rsv: the blitter's RESOLVE (BLT_OP[2:0] = 4, docs/ghci.md
 * section 8.2): converts a 4x multisampled source rectangle to one sample
 * per pixel, streaming, through the blitter's AMB port.  It keeps its own
 * copy of the BLT range of STATE (0x000-0x00B, as the CP writes it) and
 * runs one resolve per kick (atg_blt routes the kick here when BLT_OP[2]
 * is 1).
 *
 * The source: sample s of pixel (x, y) at SRC_BASE + y SRC_STRIDE + (4 x +
 * s) ps (the multisampled layout of section 12.11; the base and the stride
 * lose their bits below 4 ps).  The destination: linear, or 4x4 tiles with
 * BLT_RESOLVE[8] (the bits below ps lost).  The averages are those of
 * atg_blt_avg (BLT_RESOLVE[7:4] 0 UNORM8, 1 UNORM565 with 16-bit pixels,
 * 2 SAMPLE0).  The destination rectangle is clipped to [CLIP_MIN,
 * CLIP_MAX) when CLIP_MAX is not 0; the source moves with it.  Anything
 * else (another op, blend, reverse, a sample count other than 4, another
 * average, UNORM565 with 32-bit pixels) is refused at the kick: error of
 * kind OPCODE the next cycle, busy stays 0, no access.
 *
 * The walk: per row, a descriptor to atg_blt_rsv_px (the row's first
 * source byte, its number of source lines, its pixels, the destination
 * row's address), then the reads of the row's source lines, in order.  The
 * one request register holds a request until the MC takes it and takes the
 * next one in the same cycle; atg_blt_rsv_px's writes go before reads.  A
 * read is taken only while the reads in flight, in the register and the
 * lines waiting in atg_blt_rsv_px's FIFO are fewer than its 2^DEPTH_LOG2
 * lines (the responses have no ready; the MC answers a client in order).
 * Source and destination must not overlap (the reads do not wait for the
 * writes).
 *
 * busy is 1 from the kick to done or error.  An error response stops new
 * requests and empties atg_blt_rsv_px (no response is pushed after it);
 * when every request is answered, error of kind AXI.  Under the MC's
 * quiesce the request waits and the walk goes on after it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_rsv #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter DEPTH_LOG2 = 2
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

	localparam LBITS = LINE_BYTES * 8;
	localparam LS = LINE_SHIFT;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam RD_W = ADDR_W + 51 + LINE_SHIFT;
	localparam DEPTH = 1 << DEPTH_LOG2;

	/* The BLT state, as written. */
	reg [31:0] s_op;
	reg [31:0] s_dst_base;
	reg [31:0] s_dst_stride;
	reg [31:0] s_src_base;
	reg [31:0] s_src_stride;
	reg [31:0] s_dst_xy;
	reg [31:0] s_src_xy;
	reg [31:0] s_size;
	reg [31:0] s_clip_min;
	reg [31:0] s_clip_max;
	reg [31:0] s_resolve;

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
			s_clip_min <= 32'd0;
			s_clip_max <= 32'd0;
			s_resolve <= 32'd0;
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
			GHCI_S_BLT_CLIP_MIN: s_clip_min <= st_wdata;
			GHCI_S_BLT_CLIP_MAX: s_clip_max <= st_wdata;
			GHCI_S_BLT_RESOLVE: s_resolve <= st_wdata;
			default: ;
			endcase
		end
	end

	/* The combinations taken. */
	wire o_16 = s_op[9:8] == 2'd1;
	wire [3:0] o_fmt = s_resolve[7:4];
	wire op_ok = s_op[2:0] == GHCI_BLT_RESOLVE && !s_op[GHCI_BLT_OP_BLEND] &&
		!s_op[GHCI_BLT_OP_REVERSE] && !s_op[9] && s_resolve[3:0] == 4'd2 &&
		(o_fmt == GHCI_RSV_UNORM8 || o_fmt == GHCI_RSV_SAMPLE0 ||
		 (o_fmt == GHCI_RSV_UNORM565 && o_16));

	/* The clipped rectangle (as atg_blt_2d). */
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

	/* The mode, taken at the kick. */
	reg m16;
	reg [1:0] m_fmt;
	reg m_tiled;

	/* Bases and strides, their low bits ignored. */
	wire [ADDR_W-1:0] dmask = m16 ? ~32'd1 : ~32'd3;
	wire [ADDR_W-1:0] smask = m16 ? ~32'd7 : ~32'd15;
	wire [ADDR_W-1:0] dbase = s_dst_base & dmask;
	wire [ADDR_W-1:0] dstride = s_dst_stride & dmask;
	wire [ADDR_W-1:0] sbase = s_src_base & smask;
	wire [ADDR_W-1:0] sstride = s_src_stride & smask;

	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_CLIP = 3'd1;		/* size, source origin, multiplier */
	localparam [2:0] S_MUL = 3'd2;		/* row addresses: y * stride */
	localparam [2:0] S_RCALC = 3'd3;	/* the row's source lines */
	localparam [2:0] S_RISSUE = 3'd4;	/* the descriptor and the reads */
	localparam [2:0] S_DRAIN = 3'd5;	/* wait for every response */

	reg [2:0] state;
	reg fail;

	reg [16:0] x0;
	reg [16:0] y0;
	reg [16:0] x1;
	reg [16:0] y1;
	wire empty = x1 <= x0 || y1 <= y0;
	reg [16:0] width;
	reg [16:0] rows;	/* rows left after this one */
	reg [16:0] sx0;
	reg [1:0] ydl;		/* destination y modulo 4 (tiles) */
	reg [ADDR_W-1:0] dst_row;
	reg [ADDR_W-1:0] src_row;
	reg [16:0] mul_dy;
	reg [16:0] mul_sy;
	reg [ADDR_W-1:0] mul_ds;
	reg [ADDR_W-1:0] mul_ss;

	/* S_RCALC: the row's source byte range and lines. */
	wire [ADDR_W-1:0] sx_b = m16 ? {{(ADDR_W - 20){1'b0}}, sx0, 3'b000} :
		{{(ADDR_W - 21){1'b0}}, sx0, 4'b0000};
	wire [ADDR_W-1:0] w_b = m16 ? {{(ADDR_W - 20){1'b0}}, width, 3'b000} :
		{{(ADDR_W - 21){1'b0}}, width, 4'b0000};
	wire [ADDR_W-1:0] r_first = src_row + sx_b;
	wire [ADDR_W-1:0] r_last = r_first + w_b - 1'b1;
	wire [LA_W-1:0] r_nl = r_last[ADDR_W-1:LS] - r_first[ADDR_W-1:LS] + 1'b1;

	reg desc_pend;
	reg [RD_W-1:0] desc;
	reg [LA_W-1:0] rd_line;
	reg [16:0] rd_left;

	/* The tiled destination's next row. */
	wire [ADDR_W-1:0] tile_step = m16 ? 32'd8 : 32'd16;
	wire [ADDR_W-1:0] tile_back = m16 ? 32'd24 : 32'd48;
	wire [ADDR_W-1:0] dst_step = m_tiled ? (ydl == 2'd3 ? dstride - tile_back : tile_step) :
		dstride;

	/* The pixel path. */
	wire px_rd_ready;
	wire [DEPTH_LOG2:0] ln_count;
	wire px_wr_valid;
	wire px_wr_ready;
	wire [LA_W-1:0] px_wr_line;
	wire [LINE_BYTES-1:0] px_wr_be;
	wire [LBITS-1:0] px_wr_data;
	wire px_idle;
	wire rsp_rd = rsp_valid && !rsp_write;
	wire rsp_wr = rsp_valid && rsp_write;

	atg_blt_rsv_px #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.DEPTH_LOG2(DEPTH_LOG2),
		.RD_W(RD_W)
	) px (
		.clk(clk),
		.rst_n(rst_n),
		.stop(fail),
		.m16(m16),
		.fmt(m_fmt),
		.tiled(m_tiled),
		.rd_valid(desc_pend),
		.rd_ready(px_rd_ready),
		.rd_data(desc),
		.ln_push(rsp_rd && !rsp_error && !fail),
		.ln_data(rsp_rdata),
		.ln_count(ln_count),
		.wr_valid(px_wr_valid),
		.wr_ready(px_wr_ready),
		.wr_line(px_wr_line),
		.wr_be(px_wr_be),
		.wr_data(px_wr_data),
		.idle(px_idle)
	);

	/* The request register. */
	reg q_valid;
	reg q_write;
	reg [LA_W-1:0] q_line;
	reg [LINE_BYTES-1:0] q_be;
	reg [LBITS-1:0] q_wdata;
	reg [DEPTH_LOG2:0] rd_out;
	reg [7:0] wr_out;

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = q_line;
	assign req_be = q_be;
	assign req_wdata = q_wdata;
	assign req_tag = {7'd0, q_write};

	wire q_fire = q_valid && req_ready;
	wire q_open = (!q_valid || q_fire) && !fail;
	assign px_wr_ready = q_open && px_wr_valid;
	wire [DEPTH_LOG2+1:0] held = {1'b0, rd_out} + {1'b0, ln_count} +
		{{(DEPTH_LOG2 + 1){1'b0}}, q_valid && !q_write};
`ifdef MUT_RSV_CREDIT
	wire credit = 1'b1;	/* no credit */
`else
	wire credit = held < DEPTH;
`endif
	wire rd_take = q_open && !px_wr_valid && state == S_RISSUE && rd_left != 17'd0 && credit;

	assign busy = state != S_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			fail <= 1'b0;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			m16 <= 1'b0;
			m_fmt <= 2'd0;
			m_tiled <= 1'b0;
			x0 <= 17'd0;
			y0 <= 17'd0;
			x1 <= 17'd0;
			y1 <= 17'd0;
			width <= 17'd0;
			rows <= 17'd0;
			sx0 <= 17'd0;
			ydl <= 2'd0;
			dst_row <= {ADDR_W{1'b0}};
			src_row <= {ADDR_W{1'b0}};
			mul_dy <= 17'd0;
			mul_sy <= 17'd0;
			mul_ds <= {ADDR_W{1'b0}};
			mul_ss <= {ADDR_W{1'b0}};
			desc_pend <= 1'b0;
			desc <= {RD_W{1'b0}};
			rd_line <= {LA_W{1'b0}};
			rd_left <= 17'd0;
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_line <= {LA_W{1'b0}};
			q_be <= {LINE_BYTES{1'b0}};
			q_wdata <= {LBITS{1'b0}};
			rd_out <= {(DEPTH_LOG2 + 1){1'b0}};
			wr_out <= 8'd0;
		end else begin
			done <= 1'b0;
			error <= 1'b0;

			/* The port and the outstanding requests. */
			rd_out <= rd_out + {{DEPTH_LOG2{1'b0}}, q_fire && !q_write} -
				{{DEPTH_LOG2{1'b0}}, rsp_rd};
			wr_out <= wr_out + {7'd0, q_fire && q_write} - {7'd0, rsp_wr};
			if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire)
				q_valid <= 1'b0;
			if (px_wr_ready) begin
				q_valid <= 1'b1;
				q_write <= 1'b1;
				q_line <= px_wr_line;
				q_be <= px_wr_be;
				q_wdata <= px_wr_data;
			end else if (rd_take) begin
				q_valid <= 1'b1;
				q_write <= 1'b0;
				q_line <= rd_line;
				q_be <= {LINE_BYTES{1'b1}};
				rd_line <= rd_line + 1'b1;
				rd_left <= rd_left - 1'b1;
			end
			if (desc_pend && px_rd_ready)
				desc_pend <= 1'b0;

			case (state)
			S_IDLE:
				if (kick) begin
					fail <= 1'b0;
					m16 <= o_16;
					m_fmt <= o_fmt[1:0];
					m_tiled <= s_resolve[8];
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
					state <= S_MUL;
					width <= x1 - x0;
					rows <= y1 - y0 - 1'b1;
					sx0 <= {1'b0, s_src_xy[15:0]} + (x0 - dx);
					ydl <= y0[1:0];
					mul_dy <= m_tiled ? {2'b00, y0[16:2]} : y0;
					mul_sy <= {1'b0, s_src_xy[31:16]} + (y0 - dy);
					mul_ds <= dstride;
					mul_ss <= sstride;
					dst_row <= dbase + (m_tiled ? (m16 ? {27'd0, y0[1:0], 3'b000} :
						{26'd0, y0[1:0], 4'b0000}) : 32'd0);
					src_row <= sbase;
				end
			S_MUL:
				if (fail) begin
					state <= S_DRAIN;
				end else if (mul_dy == 17'd0 && mul_sy == 17'd0) begin
					state <= S_RCALC;
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
			S_RCALC:
				if (fail) begin
					state <= S_DRAIN;
				end else begin
					state <= S_RISSUE;
					desc_pend <= 1'b1;
					desc <= {r_first[LS-1:0], r_nl[16:0], width, x0, dst_row};
					rd_line <= r_first[ADDR_W-1:LS];
					rd_left <= r_nl[16:0];
				end
			S_RISSUE:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!desc_pend && rd_left == 17'd0) begin
					if (rows == 17'd0) begin
						state <= S_DRAIN;
					end else begin
						state <= S_RCALC;
						rows <= rows - 1'b1;
						ydl <= ydl + 1'b1;
						dst_row <= dst_row + dst_step;
						src_row <= src_row + sstride;
					end
				end
			S_DRAIN:
				if ((px_idle || fail) && !q_valid && rd_out == {(DEPTH_LOG2 + 1){1'b0}} &&
				    wr_out == 8'd0 && !rsp_valid) begin
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

`ifdef RSV_TRACE
	always @(posedge clk) begin
		if (q_fire)
			$display("%m t=%0t %s line %h be %h", $time, q_write ? "W" : "R", q_line, q_be);
		if (desc_pend && px_rd_ready)
			$display("%m t=%0t desc off %0d nl %0d w %0d x %0d drow %h", $time,
				desc[RD_W-1 -: LS], desc[ADDR_W + 34 +: 17], desc[ADDR_W + 17 +: 17],
				desc[ADDR_W +: 17], desc[ADDR_W-1:0]);
	end
`endif

	wire unused_ok = &{1'b0, s_op[31:13], s_op[11:10], s_op[7:5], s_op[3],
		s_resolve[31:9], o_fmt[3:2], rsp_tag, r_nl[LA_W-1:17], r_last[LS-1:0]};
endmodule

`default_nettype wire
