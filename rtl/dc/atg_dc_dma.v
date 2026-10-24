/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_dma: The DC's scan-out DMA: reads the framebuffer FB_BASE line by
 * line (FB_STRIDE, FB_SIZE) through the AMB and pushes pixel words into
 * the pixel FIFO towards pclk.  See spec/dc/atg_dc_dma.md.
 *
 * A frame starts at frame_start (with enable 1): the base, stride, size
 * and format are taken then.  Each row of FB_SIZE.w pixels (4 bytes, or 2
 * for RGB565) is read as ceil(row bytes / LINE_BYTES) lines from
 * base + y * stride; base and stride are LINE_BYTES aligned (the low bits
 * are ignored).  Read responses go to a line FIFO of LFIFO entries; a
 * request is made only when the outstanding requests and the lines
 * waiting fit in it, so the responses (which cannot be held back) always
 * have room.  At most one request every two cycles.  The unpacker sends
 * the pixels of each line in order, one per cycle, as px_data (a 32-bit
 * pixel, or RGB565 in the low 16 bits) with px_valid/px_ready.  An error
 * response gives pixels 0 (the MC raised the fault).
 *
 * frame_start during a frame and enable = 0 abort it: no new request (a
 * request already offered stays until req_ready), the line FIFO and the
 * unpacker are cleared, and the responses still to come are dropped: each
 * request carries the frame's epoch in its tag, and responses of an older
 * epoch are not kept.  px_valid may fall without px_ready at an abort.
 * idle is 1 when no request is offered or outstanding.
 *
 * scan_sum and scan_words are the sum and the number of the pixel words
 * pushed in the last frame (taken at the next frame_start or abort): a
 * check that the scan-out read the framebuffer, without a display.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_dma #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire enable,
	input wire frame_start,
	input wire [31:0] fb_base,
	input wire [31:0] fb_stride,
	input wire [31:0] fb_size,
	input wire [1:0] format,
	output wire px_valid,
	input wire px_ready,
	output wire [31:0] px_data,
	output wire idle,
	output reg [31:0] scan_sum,
	output reg [31:0] scan_words,
	/* AMB client port (design §4.1) */
	output reg req_valid,
	input wire req_ready,
	output wire req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam LW = LINE_BYTES * 8;
	localparam AW = ADDR_W - LINE_SHIFT;
	localparam LFIFO_LOG2 = 3;
	localparam [LFIFO_LOG2:0] LFIFO = 1 << LFIFO_LOG2;
	localparam integer PPL32_I = LINE_BYTES / 4;	/* pixels in a line */
	localparam integer PPL16_I = LINE_BYTES / 2;
	localparam [5:0] PPL32 = PPL32_I[5:0];
	localparam [5:0] PPL16 = PPL16_I[5:0];
	localparam integer LB_I = LINE_BYTES - 1;
	localparam [17:0] LINE_MASK = LB_I[17:0];

	assign req_write = 1'b0;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LW{1'b0}};

	/* An abort ends the current frame; frame_start then starts the next. */
	reg enable_q;
	wire abort = frame_start || (enable_q && !enable);
	wire start = frame_start && enable;
	reg [3:0] epoch;
	reg [3:0] tag_q;
	assign req_tag = {4'd0, tag_q};

	/* The frame's parameters. */
	reg [AW-1:0] f_stride;
	reg [15:0] f_w, f_h;
	reg f_16;
	wire [17:0] row_bytes = format == 2'd2 ? {1'b0, fb_size[15:0], 1'b0} :
		{fb_size[15:0], 2'b00};
	wire [17:0] row_lines = (row_bytes + LINE_MASK) >> LINE_SHIFT;

	/* Requests. */
	reg rq_active;
	reg [15:0] rq_row, rq_k, f_nl;
	reg [AW-1:0] rq_row_line, rq_cur;
	reg [LFIFO_LOG2:0] inflight;
	wire [LFIFO_LOG2:0] lcount;
	wire take = req_valid && req_ready;
	wire rsp_read = rsp_valid && !rsp_write;
	wire room = inflight + lcount < LFIFO;

	assign idle = !req_valid && inflight == {(LFIFO_LOG2 + 1){1'b0}};

	always @(posedge clk) begin
		if (!rst_n) begin
			enable_q <= 1'b0;
			epoch <= 4'd0;
			tag_q <= 4'd0;
			rq_active <= 1'b0;
			rq_row <= 16'd0;
			rq_k <= 16'd0;
			rq_row_line <= {AW{1'b0}};
			rq_cur <= {AW{1'b0}};
			req_valid <= 1'b0;
			req_line <= {AW{1'b0}};
			inflight <= {(LFIFO_LOG2 + 1){1'b0}};
			f_stride <= {AW{1'b0}};
			f_w <= 16'd0;
			f_h <= 16'd0;
			f_nl <= 16'd0;
			f_16 <= 1'b0;
		end else begin
			enable_q <= enable;
			inflight <= inflight + {{LFIFO_LOG2{1'b0}}, take} -
				{{LFIFO_LOG2{1'b0}}, rsp_read};
			if (take)
				req_valid <= 1'b0;
			if (abort) begin
				epoch <= epoch + 4'd1;
				rq_active <= 1'b0;
			end
			if (start) begin
				rq_active <= fb_size[15:0] != 16'd0 && fb_size[31:16] != 16'd0;
				rq_row <= 16'd0;
				rq_k <= 16'd0;
				rq_row_line <= fb_base[ADDR_W-1:LINE_SHIFT];
				rq_cur <= fb_base[ADDR_W-1:LINE_SHIFT];
				f_stride <= fb_stride[ADDR_W-1:LINE_SHIFT];
				f_w <= fb_size[15:0];
				f_h <= fb_size[31:16];
				f_nl <= row_lines[15:0];
				f_16 <= format == 2'd2;
			end else if (!abort && enable && rq_active && !req_valid && room) begin
				/* One line of the frame. */
				req_valid <= 1'b1;
				req_line <= rq_cur;
				tag_q <= epoch;
				if (rq_k == f_nl - 16'd1) begin
					rq_k <= 16'd0;
					rq_row <= rq_row + 16'd1;
					rq_row_line <= rq_row_line + f_stride;
					rq_cur <= rq_row_line + f_stride;
					if (rq_row == f_h - 16'd1)
						rq_active <= 1'b0;
				end else begin
					rq_k <= rq_k + 16'd1;
					rq_cur <= rq_cur + {{(AW - 1){1'b0}}, 1'b1};
				end
			end
		end
	end

	/* The line FIFO, cleared by an abort. */
	wire l_valid;
	wire [LW-1:0] l_data;
	wire l_pop;
	wire l_in_ready;	/* always 1 when a response comes: the requests wait for room */
	wire keep = rsp_read && rsp_tag[3:0] == epoch && !abort;

	am_fifo #(.W(LW), .DEPTH_LOG2(LFIFO_LOG2)) lines (
		.clk(clk), .rst_n(rst_n && !abort),
		.in_valid(keep), .in_ready(l_in_ready), .in_data(rsp_error ? {LW{1'b0}} : rsp_rdata),
		.out_valid(l_valid), .out_ready(l_pop), .out_data(l_data), .count(lcount)
	);

	/* The unpacker. */
	reg up_active;
	reg [15:0] up_row, up_x;
	reg [5:0] up_idx;
	wire [5:0] ppl = f_16 ? PPL16 : PPL32;
	wire push = px_valid && px_ready;
	wire row_end = up_x == f_w - 16'd1;
	assign l_pop = push && (row_end || up_idx == ppl - 6'd1);
	assign px_valid = up_active && l_valid && !abort;
	assign px_data = f_16 ? {16'd0, l_data[16*up_idx[LINE_SHIFT-2:0] +: 16]} :
		l_data[32*up_idx[LINE_SHIFT-3:0] +: 32];

	reg [31:0] sum_acc, words_acc;

	always @(posedge clk) begin
		if (!rst_n) begin
			up_active <= 1'b0;
			up_row <= 16'd0;
			up_x <= 16'd0;
			up_idx <= 6'd0;
			sum_acc <= 32'd0;
			words_acc <= 32'd0;
			scan_sum <= 32'd0;
			scan_words <= 32'd0;
		end else if (abort) begin
			up_active <= start && fb_size[15:0] != 16'd0 && fb_size[31:16] != 16'd0;
			up_row <= 16'd0;
			up_x <= 16'd0;
			up_idx <= 6'd0;
			scan_sum <= sum_acc;
			scan_words <= words_acc;
			sum_acc <= 32'd0;
			words_acc <= 32'd0;
		end else if (push) begin
			sum_acc <= sum_acc + px_data;
			words_acc <= words_acc + 32'd1;
			if (row_end) begin
				up_x <= 16'd0;
				up_idx <= 6'd0;
				up_row <= up_row + 16'd1;
				if (up_row == f_h - 16'd1)
					up_active <= 1'b0;
			end else begin
				up_x <= up_x + 16'd1;
				up_idx <= up_idx == ppl - 6'd1 ? 6'd0 : up_idx + 6'd1;
			end
		end
	end

	wire unused_ok = &{1'b0, fb_base[LINE_SHIFT-1:0], fb_stride[LINE_SHIFT-1:0],
		rsp_tag[7:4], l_in_ready, row_lines[17:16], up_idx[5:LINE_SHIFT-1]};
endmodule

`default_nettype wire
