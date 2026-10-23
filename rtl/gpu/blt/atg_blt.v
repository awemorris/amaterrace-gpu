/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt: the blitter, skeleton (WS288 p002).  It takes its parameters
 * from the BLT range of the state register file (STATE[0x000..0x00A],
 * docs/ghci.md), seen as the CP writes them (st_we), and runs one blit per
 * kick through its AMB port (atg_mc):
 *
 *   FILL  writes COLOR to every pixel of the destination rectangle
 *   COPY  copies the source rectangle to the destination, top row first,
 *         left to right (the skeleton has no reversed direction: an
 *         overlapping copy whose source starts before its destination is
 *         wrong)
 *
 * Only 32-bit pixels.  The skeleton refuses (error with kind OPCODE)
 * TILE, UNTILE, 16-bit pixels, blend-over and the reversed direction;
 * they come with the CP in p003.  The rectangle is clipped to
 * [CLIP_MIN, CLIP_MAX) when CLIP_MAX is not 0.  Strides and bases are
 * byte values whose low two bits are ignored.
 *
 * A row is cut into line segments: FILL writes each with its byte enables
 * (writes stream, up to the MC's outstanding limit); COPY waits for its
 * earlier writes, reads the one or two source lines that cover the
 * segment, shifts them by whole pixels and writes the segment.  busy is 1
 * from kick to done or error (one-cycle pulses).  An error response stops
 * new requests; the error pulse comes when every request is answered.
 * A kick while busy is ignored (the CP does not make one).
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
	localparam WPL = LINE_BYTES / 4;	/* words (pixels) per line */
	localparam WS = LINE_SHIFT - 2;		/* log2(WPL) */
	localparam AW = ADDR_W - 2;		/* word address */
	localparam LA_W = ADDR_W - LINE_SHIFT;

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

	/* The clipped rectangle, from the state (stable while busy: the CP
	 * writes no state then). */
	wire clip_en = s_clip_max != 32'd0;
	wire [16:0] dx = {1'b0, s_dst_xy[15:0]};
	wire [16:0] dy = {1'b0, s_dst_xy[31:16]};
	wire [16:0] dx_end = dx + {1'b0, s_size[15:0]};
	wire [16:0] dy_end = dy + {1'b0, s_size[31:16]};
	wire [16:0] cx0 = {1'b0, s_clip_min[15:0]};
	wire [16:0] cy0 = {1'b0, s_clip_min[31:16]};
	wire [16:0] cx1 = {1'b0, s_clip_max[15:0]};
	wire [16:0] cy1 = {1'b0, s_clip_max[31:16]};
	wire [16:0] x0 = clip_en && cx0 > dx ? cx0 : dx;
	wire [16:0] y0 = clip_en && cy0 > dy ? cy0 : dy;
	wire [16:0] x1 = clip_en && cx1 < dx_end ? cx1 : dx_end;
	wire [16:0] y1 = clip_en && cy1 < dy_end ? cy1 : dy_end;
	wire empty = x1 <= x0 || y1 <= y0;
	wire [16:0] sx0 = {1'b0, s_src_xy[15:0]} + (x0 - dx);
	wire [16:0] sy0 = {1'b0, s_src_xy[31:16]} + (y0 - dy);

	wire op_fill = s_op[1:0] == GHCI_BLT_FILL;
	wire op_copy = s_op[1:0] == GHCI_BLT_COPY;
	wire op_ok = (op_fill || op_copy) && !s_op[4] && s_op[9:8] == 2'd0 && !s_op[12];

	localparam [2:0] S_IDLE = 3'd0;
	localparam [2:0] S_MUL = 3'd1;	/* row addresses: y * stride */
	localparam [2:0] S_SEG = 3'd2;	/* FILL: write the segment */
	localparam [2:0] S_CRD = 3'd3;	/* COPY: read the source lines */
	localparam [2:0] S_CWAIT = 3'd4;	/* COPY: wait for them */
	localparam [2:0] S_CWR = 3'd5;	/* COPY: write the segment */
	localparam [2:0] S_DRAIN = 3'd6;	/* wait for every response */

	reg [2:0] state;
	reg fail;		/* an error response was seen */
	reg copy;

	/* Row walking, in word (pixel) addresses. */
	reg [AW-1:0] dst_row;
	reg [AW-1:0] src_row;
	reg [AW-1:0] cw;	/* current destination word */
	reg [AW-1:0] cs;	/* the source word for cw */
	reg [16:0] rem;		/* words left in the row */
	reg [16:0] width;
	reg [16:0] rows;	/* rows left after this one */

	/* The shift-and-add multiplier of S_MUL. */
	reg [16:0] mul_dy;
	reg [16:0] mul_sy;
	reg [AW-1:0] mul_ds;
	reg [AW-1:0] mul_ss;

	/* Outstanding requests. */
	reg [3:0] wr_out;
	reg [1:0] rd_out;

	/* COPY: the reads to issue and the two source lines. */
	reg rd_first;		/* the first read is still to go */
	reg rd_second;		/* a second read is needed and still to go */
	reg [LINE_BITS-1:0] buf0;
	reg [LINE_BITS-1:0] buf1;

	/* The segment at cw. */
	wire [WS-1:0] p0 = cw[WS-1:0];
	/* verilator lint_off WIDTHTRUNC */
	localparam [WS:0] WPL_V = WPL;
	/* verilator lint_on WIDTHTRUNC */
	wire [WS:0] room = WPL_V - {1'b0, p0};
	wire [16:0] seg_n = rem < {{(16 - WS){1'b0}}, room} ? rem : {{(16 - WS){1'b0}}, room};
	wire seg_last = rem == seg_n;

	/* Word w of the line is written when p0 <= w < p0 + seg_n. */
	reg [WPL-1:0] seg_words;
	integer w;

	wire [16:0] seg_p0 = {{(17 - WS){1'b0}}, p0};
	wire [16:0] seg_end = seg_p0 + seg_n;

	always @(*) begin
		for (w = 0; w < WPL; w = w + 1)
			seg_words[w] = w[16:0] >= seg_p0 && w[16:0] < seg_end;
	end

	wire [LINE_BYTES-1:0] seg_be;

	genvar g;
	generate
		for (g = 0; g < WPL; g = g + 1) begin : be_expand
			assign seg_be[g*4 +: 4] = {4{seg_words[g]}};
		end
	endgenerate

	/* COPY: the source words cs..cs+seg_n-1 in the lines lo and lo+1,
	 * where lo is the line of cs - p0. */
	wire [AW-1:0] src_base_w = cs - {{(AW - WS){1'b0}}, p0};
	wire [WS-1:0] src_off = src_base_w[WS-1:0];
	wire [AW-1:0] src_last = cs + {{(AW - 17){1'b0}}, seg_n} - 1'b1;
	wire [LA_W-1:0] src_lo = src_base_w[AW-1:WS];
	wire [LA_W-1:0] src_n0 = cs[AW-1:WS];
	wire [LA_W-1:0] src_n1 = src_last[AW-1:WS];
	wire n0_slot = src_n0 != src_lo;
	wire [2*LINE_BITS-1:0] both = {buf1, buf0};
	wire [2*LINE_BITS-1:0] shifted = both >> {src_off, 5'd0};
	wire [LINE_BITS-1:0] copy_line = shifted[LINE_BITS-1:0];

	/* The request. */
	reg q_valid;
	reg q_write;
	reg [LA_W-1:0] q_line;
	reg q_slot;

	assign req_valid = q_valid;
	assign req_write = q_write;
	assign req_line = q_line;
	assign req_be = seg_be;
	assign req_wdata = copy ? copy_line : {WPL{s_color}};
	assign req_tag = {6'd0, q_write, q_slot};

	wire q_fire = q_valid && req_ready;
	wire rsp_rd = rsp_valid && !rsp_write;
	wire rsp_wr = rsp_valid && rsp_write;

	assign busy = state != S_IDLE;

	wire [AW-1:0] dst_base_w = s_dst_base[ADDR_W-1:2];
	wire [AW-1:0] src_base_s = s_src_base[ADDR_W-1:2];
	wire [AW-1:0] dst_stride_w = s_dst_stride[ADDR_W-1:2];
	wire [AW-1:0] src_stride_w = s_src_stride[ADDR_W-1:2];

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			fail <= 1'b0;
			copy <= 1'b0;
			done <= 1'b0;
			error <= 1'b0;
			error_kind <= 4'd0;
			dst_row <= {AW{1'b0}};
			src_row <= {AW{1'b0}};
			cw <= {AW{1'b0}};
			cs <= {AW{1'b0}};
			rem <= 17'd0;
			width <= 17'd0;
			rows <= 17'd0;
			mul_dy <= 17'd0;
			mul_sy <= 17'd0;
			mul_ds <= {AW{1'b0}};
			mul_ss <= {AW{1'b0}};
			wr_out <= 4'd0;
			rd_out <= 2'd0;
			rd_first <= 1'b0;
			rd_second <= 1'b0;
			buf0 <= {LINE_BITS{1'b0}};
			buf1 <= {LINE_BITS{1'b0}};
			q_valid <= 1'b0;
			q_write <= 1'b0;
			q_line <= {LA_W{1'b0}};
			q_slot <= 1'b0;
		end else begin
			done <= 1'b0;
			error <= 1'b0;

			/* Outstanding requests and the source lines. */
			wr_out <= wr_out + {3'd0, q_fire && q_write} - {3'd0, rsp_wr};
			rd_out <= rd_out + {1'b0, q_fire && !q_write} - {1'b0, rsp_rd};
			if (rsp_rd) begin
				if (rsp_tag[0])
					buf1 <= rsp_rdata;
				else
					buf0 <= rsp_rdata;
			end
			if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire)
				q_valid <= 1'b0;

			case (state)
			S_IDLE:
				if (kick) begin
					fail <= 1'b0;
					copy <= op_copy;
					if (!op_ok) begin
						error <= 1'b1;
						error_kind <= GHCI_FAULT_OPCODE;
					end else if (empty) begin
						done <= 1'b1;
					end else begin
						state <= S_MUL;
						width <= x1 - x0;
						rows <= y1 - y0 - 1'b1;
						mul_dy <= y0;
						mul_sy <= sy0;
						mul_ds <= dst_stride_w;
						mul_ss <= src_stride_w;
						dst_row <= dst_base_w + {{(AW - 17){1'b0}}, x0};
						src_row <= src_base_s + {{(AW - 17){1'b0}}, sx0};
					end
				end
			S_MUL:
				if (mul_dy == 17'd0 && mul_sy == 17'd0) begin
					state <= copy ? S_CRD : S_SEG;
					cw <= dst_row;
					cs <= src_row;
					rem <= width;
					rd_first <= 1'b1;
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
			S_SEG:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid || q_fire) begin
					/* Queue the segment at cw unless the last one
					 * is still waiting. */
					if (!q_valid) begin
						q_valid <= 1'b1;
						q_write <= 1'b1;
						q_line <= cw[AW-1:WS];
						q_slot <= 1'b0;
					end else begin
						/* q_fire: the segment went; step to the next. */
						step_segment();
						if (seg_last && rows == 17'd0)
							state <= S_DRAIN;
					end
				end
			S_CRD:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid && wr_out == 4'd0 && !(q_write && q_fire)) begin
					if (rd_first) begin
						q_valid <= 1'b1;
						q_write <= 1'b0;
						q_line <= src_n0;
						q_slot <= n0_slot;
						rd_first <= 1'b0;
						rd_second <= src_n1 != src_n0;
					end else if (rd_second) begin
						q_valid <= 1'b1;
						q_write <= 1'b0;
						q_line <= src_n1;
						q_slot <= 1'b1;
						rd_second <= 1'b0;
					end else begin
						state <= S_CWAIT;
					end
				end
			S_CWAIT:
				if (fail)
					state <= S_DRAIN;
				else if (!q_valid && rd_out == 2'd0)
					state <= S_CWR;
			S_CWR:
				if (fail) begin
					state <= S_DRAIN;
				end else if (!q_valid) begin
					q_valid <= 1'b1;
					q_write <= 1'b1;
					q_line <= cw[AW-1:WS];
					q_slot <= 1'b0;
				end else if (q_fire) begin
					step_segment();
					rd_first <= 1'b1;
					state <= seg_last && rows == 17'd0 ? S_DRAIN : S_CRD;
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

	/* Advance cw/cs past the segment just written; at the row's end go to
	 * the next row. */
	task step_segment;
		begin
			if (seg_last) begin
				dst_row <= dst_row + dst_stride_w;
				src_row <= src_row + src_stride_w;
				cw <= dst_row + dst_stride_w;
				cs <= src_row + src_stride_w;
				rem <= width;
				rows <= rows - 1'b1;
			end else begin
				cw <= cw + {{(AW - 17){1'b0}}, seg_n};
				cs <= cs + {{(AW - 17){1'b0}}, seg_n};
				rem <= rem - seg_n;
			end
		end
	endtask

	wire unused_ok = &{1'b0, s_op[31:13], s_op[11:10], s_op[7:5], s_op[3:2],
		s_dst_base[1:0], s_src_base[1:0], s_dst_stride[1:0], s_src_stride[1:0],
		rsp_tag[7:1], src_last[WS-1:0], shifted[2*LINE_BITS-1:LINE_BITS]};
endmodule

`default_nettype wire
