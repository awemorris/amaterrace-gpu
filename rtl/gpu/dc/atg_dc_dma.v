/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_dma: The DC's scan-out DMA: reads the framebuffer FB_BASE line by
 * line (FB_STRIDE, FB_SIZE) through the AMB and pushes pixel words into
 * the pixel FIFO towards pclk.  See spec/gpu/dc/atg_dc_dma.md.
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
 *
 * clear (the DC's CTRL.RESET) aborts like enable = 0 and starts no frame;
 * the count of outstanding requests is kept (rst_n is the board reset), so
 * the responses of reads issued before it are still counted and dropped.
 * err pulses for an error response of the current frame (its line is
 * black).  done is 1 when the frame has no line left to request and no
 * pixel left to push (or there is no frame): the cursor may read then.
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
	input wire clear,
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
	output wire done,
	output reg err,
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
	wire abort = frame_start || (enable_q && !enable) || clear;
	wire start = frame_start && enable && !clear;
	reg [3:0] epoch;
	reg [3:0] tag_q;
	assign req_tag = {4'd0, tag_q};

	/* The frame's parameters. */
	reg [AW-1:0] f_stride;
	reg [15:0] f_w, f_h;
	reg f_16;
	wire [17:0] row_bytes = format == 2'd2 ? {1'b0, fb_size[15:0], 1'b0} :
		{fb_size[15:0], 2'b00};
	wire [17:0] row_end_bytes;
	wire [17:0] row_lines = row_end_bytes >> LINE_SHIFT;
	wire row_co_unused;

	am_add #(.W(18)) a_rowl (.a(row_bytes), .b(LINE_MASK), .ci(1'b0), .s(row_end_bytes), .co(row_co_unused));

	/* Requests. */
	reg rq_active;
	reg [15:0] rq_row, rq_k, f_nl;
	reg [AW-1:0] rq_row_line, rq_cur;
	reg [LFIFO_LOG2:0] inflight;
	wire [LFIFO_LOG2:0] lcount;
	wire take = req_valid && req_ready;
	wire rsp_read = rsp_valid && !rsp_write;
	wire [LFIFO_LOG2:0] used;
	wire room = used < LFIFO;

	assign idle = !req_valid && inflight == {(LFIFO_LOG2 + 1){1'b0}};

	/*
	 * The requests' sums: the lines in flight or waiting, the next counts
	 * (in flight, epoch, row, line of the row, the next row's first line,
	 * the line), and the last line of a row and the last row.
	 */
	wire [LFIFO_LOG2:0] infl_up, infl_next;
	wire [3:0] epoch_inc;
	wire [15:0] f_nl_last, rq_row_inc, f_h_last, rq_k_inc;
	wire [AW-1:0] rq_next_row, rq_cur_inc;
	wire [9:0] rq_co_unused;

	am_add #(.W(LFIFO_LOG2 + 1)) a_used (.a(inflight), .b(lcount), .ci(1'b0), .s(used), .co(rq_co_unused[0]));
	am_add #(.W(LFIFO_LOG2 + 1)) a_infl (.a(inflight), .b({(LFIFO_LOG2 + 1){1'b0}}), .ci(take), .s(infl_up),
		.co(rq_co_unused[1]));
	am_sub #(.W(LFIFO_LOG2 + 1)) s_infl (.a(infl_up), .b({(LFIFO_LOG2 + 1){1'b0}}), .bi(rsp_read), .d(infl_next),
		.bo(rq_co_unused[2]));
	am_add #(.W(4)) a_epoch (.a(epoch), .b(4'd0), .ci(1'b1), .s(epoch_inc), .co(rq_co_unused[3]));
	am_sub #(.W(16)) s_nl (.a(f_nl), .b(16'd1), .bi(1'b0), .d(f_nl_last), .bo(rq_co_unused[4]));
	am_add #(.W(16)) a_row (.a(rq_row), .b(16'd0), .ci(1'b1), .s(rq_row_inc), .co(rq_co_unused[5]));
	am_add #(.W(AW)) a_nrow (.a(rq_row_line), .b(f_stride), .ci(1'b0), .s(rq_next_row), .co(rq_co_unused[6]));
	am_sub #(.W(16)) s_h (.a(f_h), .b(16'd1), .bi(1'b0), .d(f_h_last), .bo(rq_co_unused[7]));
	am_add #(.W(16)) a_k (.a(rq_k), .b(16'd0), .ci(1'b1), .s(rq_k_inc), .co(rq_co_unused[8]));
	am_add #(.W(AW)) a_cur (.a(rq_cur), .b({AW{1'b0}}), .ci(1'b1), .s(rq_cur_inc), .co(rq_co_unused[9]));

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
			inflight <= infl_next;
			if (take)
				req_valid <= 1'b0;
			if (abort) begin
				epoch <= epoch_inc;
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
				if (rq_k == f_nl_last) begin
					rq_k <= 16'd0;
					rq_row <= rq_row_inc;
					rq_row_line <= rq_next_row;
					rq_cur <= rq_next_row;
					if (rq_row == f_h_last)
						rq_active <= 1'b0;
				end else begin
					rq_k <= rq_k_inc;
					rq_cur <= rq_cur_inc;
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

	always @(posedge clk)
		if (!rst_n)
			err <= 1'b0;
		else
			err <= keep && rsp_error;

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
	wire [15:0] f_w_last;
	wire [5:0] ppl_last;
	wire [1:0] up_co_unused;

	am_sub #(.W(16)) s_w (.a(f_w), .b(16'd1), .bi(1'b0), .d(f_w_last), .bo(up_co_unused[0]));
	am_sub #(.W(6)) s_ppl (.a(ppl), .b(6'd1), .bi(1'b0), .d(ppl_last), .bo(up_co_unused[1]));
	wire row_end = up_x == f_w_last;
	assign l_pop = push && (row_end || up_idx == ppl_last);
	assign px_valid = up_active && l_valid && !abort;
	assign px_data = f_16 ? {16'd0, l_data[16*up_idx[LINE_SHIFT-2:0] +: 16]} :
		l_data[32*up_idx[LINE_SHIFT-3:0] +: 32];

	reg [31:0] sum_acc, words_acc;

	/* The unpacker's sums: the frame's sum and words, and the next row, column and pixel of the line. */
	wire [31:0] sum_next, words_inc;
	wire [15:0] up_row_inc, up_x_inc;
	wire [5:0] up_idx_inc;
	wire [4:0] acc_co_unused;

	am_add #(.W(32)) a_sum (.a(sum_acc), .b(px_data), .ci(1'b0), .s(sum_next), .co(acc_co_unused[0]));
	am_add #(.W(32)) a_words (.a(words_acc), .b(32'd0), .ci(1'b1), .s(words_inc), .co(acc_co_unused[1]));
	am_add #(.W(16)) a_urow (.a(up_row), .b(16'd0), .ci(1'b1), .s(up_row_inc), .co(acc_co_unused[2]));
	am_add #(.W(16)) a_ux (.a(up_x), .b(16'd0), .ci(1'b1), .s(up_x_inc), .co(acc_co_unused[3]));
	am_add #(.W(6)) a_uidx (.a(up_idx), .b(6'd0), .ci(1'b1), .s(up_idx_inc), .co(acc_co_unused[4]));

	assign done = !rq_active && !up_active;

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
			sum_acc <= sum_next;
			words_acc <= words_inc;
			if (row_end) begin
				up_x <= 16'd0;
				up_idx <= 6'd0;
				up_row <= up_row_inc;
				if (up_row == f_h_last)
					up_active <= 1'b0;
			end else begin
				up_x <= up_x_inc;
				up_idx <= up_idx == ppl_last ? 6'd0 : up_idx_inc;
			end
		end
	end

	wire unused_ok = &{1'b0, fb_base[LINE_SHIFT-1:0], fb_stride[LINE_SHIFT-1:0],
		rsp_tag[7:4], l_in_ready, row_lines[17:16], up_idx[5:LINE_SHIFT-1], row_co_unused, rq_co_unused,
		up_co_unused, acc_co_unused};
endmodule

`default_nettype wire
