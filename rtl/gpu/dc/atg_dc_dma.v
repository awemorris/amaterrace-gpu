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
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter LFIFO_LOG2 = 5	/* 32 entries (ws001-p038) */
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
	localparam LW = LINE_BYTES * 8;
	localparam AW = ADDR_W - LINE_SHIFT;
	localparam [LFIFO_LOG2:0] LFIFO = 1 << LFIFO_LOG2;
	localparam [LFIFO_LOG2:0] LFIFO_M1 = LFIFO - 1;
	localparam integer PPL32_I = LINE_BYTES / 4;	/* pixels in a line */
	localparam integer PPL16_I = LINE_BYTES / 2;
	localparam [5:0] PPL32 = PPL32_I[5:0];
	localparam [5:0] PPL16 = PPL16_I[5:0];
	localparam [5:0] PPL32_LAST = PPL32 - 6'd1;
	localparam [5:0] PPL16_LAST = PPL16 - 6'd1;
	localparam integer LB_I = LINE_BYTES - 1;
	localparam [17:0] LINE_MASK = LB_I[17:0];

	assign req_write = 1'b0;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LW{1'b0}};

	reg enable_q;

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire dma_top_rst_high;
	LUT2 #(.INIT(4'b1101)) u_dma_top_rst (.I0(rst_n), .I1(clear), .O(dma_top_rst_high));
	wire rst_high = dma_top_rst_high;
	(* max_fanout = 16 *) wire abort = frame_start || (enable_q && !enable) || clear;
	(* max_fanout = 16 *) wire start = frame_start && enable && !clear;
`else
	wire rst_high = !rst_n || clear;
	(* max_fanout = 16 *) wire abort = frame_start || (enable_q && !enable) || clear;
	(* max_fanout = 16 *) wire start = frame_start && enable && !clear;
`endif
	reg [3:0] epoch;
	reg [3:0] tag_q;
	assign req_tag = {4'd0, tag_q};

	/* The frame's parameters. */
	reg [13:0] f_stride_lo;
	reg [AW-1:14] f_stride_hi;
	wire [AW-1:0] f_stride = {f_stride_hi, f_stride_lo};
	reg [15:0] f_w, f_h;
	(* keep = "true" *) reg f_16, f_16_lo0, f_16_lo1, f_16_hi0, f_16_hi1;
	wire [17:0] row_bytes = format == 2'd2 ? {1'b0, fb_size[15:0], 1'b0} :
		{fb_size[15:0], 2'b00};
	wire [17:0] row_end_bytes;
	wire [17:0] row_lines = row_end_bytes >> LINE_SHIFT;
	wire row_co_unused;

	am_add #(.W(18)) a_rowl (.a(row_bytes), .b(LINE_MASK), .ci(1'b0), .s(row_end_bytes), .co(row_co_unused));

	/* Requests. */
	reg rq_active;
	(* extract_reset = "no" *) reg [15:0] rq_k;
	(* extract_reset = "no" *) reg [15:0] rq_row;
	reg [15:0] f_nl;
	reg [13:0] rq_row_line_lo;
	reg [AW-1:14] rq_row_line_hi;
	wire [AW-1:0] rq_row_line = {rq_row_line_hi, rq_row_line_lo};

	reg [13:0] rq_cur_lo;
	reg [AW-1:14] rq_cur_hi;
	wire [AW-1:0] rq_cur = {rq_cur_hi, rq_cur_lo};

	reg [13:0] req_line_lo;
	reg [AW-1:14] req_line_hi;
	assign req_line = {req_line_hi, req_line_lo};
	reg [LFIFO_LOG2:0] inflight;
	wire take = req_valid && req_ready;
	wire rsp_read = rsp_valid && !rsp_write;
	(* max_fanout = 16 *) reg [LFIFO_LOG2:0] used;
	wire [LFIFO_LOG2:0] used_inc, used_dec;
	wire [1:0] u_co_unused;
	am_add #(.W(LFIFO_LOG2 + 1)) a_uinc (.a(used), .b({(LFIFO_LOG2 + 1){1'b0}}), .ci(1'b1), .s(used_inc), .co(u_co_unused[0]));
	am_sub #(.W(LFIFO_LOG2 + 1)) s_udec (.a(used), .b({(LFIFO_LOG2 + 1){1'b0}}), .bi(1'b1), .d(used_dec), .bo(u_co_unused[1]));

	wire room = req_valid ? (!used[LFIFO_LOG2] && (used[LFIFO_LOG2-1:0] != {LFIFO_LOG2{1'b1}})) : !used[LFIFO_LOG2];
`ifdef SYNTH_KINTEX7
	wire rq_active_iss, rq_active_done;
	LUT1 #(.INIT(2'b10)) u_buf_rqa (.I0(rq_active), .O(rq_active_iss));
	LUT1 #(.INIT(2'b10)) u_buf_rqd (.I0(rq_active), .O(rq_active_done));
`else
	wire rq_active_iss = rq_active;
	wire rq_active_done = rq_active;
`endif
	wire can_issue = !abort && enable && rq_active_iss && room;

	assign idle = !req_valid && inflight == {(LFIFO_LOG2 + 1){1'b0}};

	/*
	 * The requests' sums: the lines in flight or waiting, the next counts
	 * (in flight, epoch, row, line of the row, the next row's first line,
	 * the line), and the last line of a row and the last row.
	 */
	wire [LFIFO_LOG2:0] infl_up, infl_next;
	wire [3:0] epoch_inc;
	wire [15:0] calc_nl_last, rq_row_inc, calc_h_last, rq_k_inc;
	(* max_fanout = 16 *) reg [15:0] f_nl_last, f_h_last;
	wire [AW-1:0] rq_next_row, rq_cur_inc;
	wire [9:0] rq_co_unused;

	assign rq_co_unused[0] = 1'b0;
	am_add #(.W(LFIFO_LOG2 + 1)) a_infl (.a(inflight), .b({(LFIFO_LOG2 + 1){1'b0}}), .ci(take), .s(infl_up),
		.co(rq_co_unused[1]));
	am_sub #(.W(LFIFO_LOG2 + 1)) s_infl (.a(infl_up), .b({(LFIFO_LOG2 + 1){1'b0}}), .bi(rsp_read), .d(infl_next),
		.bo(rq_co_unused[2]));
	am_add #(.W(4)) a_epoch (.a(epoch), .b(4'd0), .ci(1'b1), .s(epoch_inc), .co(rq_co_unused[3]));
	am_sub #(.W(16)) s_nl (.a(row_lines[15:0]), .b(16'd1), .bi(1'b0), .d(calc_nl_last), .bo(rq_co_unused[4]));
	am_add #(.W(16)) a_row (.a(rq_row), .b(16'd0), .ci(1'b1), .s(rq_row_inc), .co(rq_co_unused[5]));
	am_add #(.W(AW)) a_nrow (.a(rq_row_line), .b(f_stride), .ci(1'b0), .s(rq_next_row), .co(rq_co_unused[6]));
	am_sub #(.W(16)) s_h (.a(fb_size[31:16]), .b(16'd1), .bi(1'b0), .d(calc_h_last), .bo(rq_co_unused[7]));
	am_add #(.W(16)) a_k (.a(rq_k), .b(16'd0), .ci(1'b1), .s(rq_k_inc), .co(rq_co_unused[8]));
	am_add #(.W(AW)) a_cur (.a(rq_cur), .b({AW{1'b0}}), .ci(1'b1), .s(rq_cur_inc), .co(rq_co_unused[9]));

	wire k_is_nl = (rq_k == f_nl_last);
`ifdef SYNTH_KINTEX7
	wire k_is_nl_a0, k_is_nl_a1, k_is_nl_b0, k_is_nl_b1;
	LUT1 #(.INIT(2'b10)) u_buf_knl_a0 (.I0(k_is_nl), .O(k_is_nl_a0));
	LUT1 #(.INIT(2'b10)) u_buf_knl_a1 (.I0(k_is_nl), .O(k_is_nl_a1));
	LUT1 #(.INIT(2'b10)) u_buf_knl_b0 (.I0(k_is_nl), .O(k_is_nl_b0));
	LUT1 #(.INIT(2'b10)) u_buf_knl_b1 (.I0(k_is_nl), .O(k_is_nl_b1));
`else
	wire k_is_nl_a0 = k_is_nl;
	wire k_is_nl_a1 = k_is_nl;
	wire k_is_nl_b0 = k_is_nl;
	wire k_is_nl_b1 = k_is_nl;
`endif

	wire issue_step = can_issue && (take || !req_valid);
`ifdef SYNTH_KINTEX7
	wire issue_step_rql, issue_step_rqh, issue_step_curl, issue_step_curh, issue_step_rowl, issue_step_rowh;
	wire issue_step_ctla, issue_step_ctlk, issue_step_ctlr;
	LUT1 #(.INIT(2'b10)) u_buf_is_rql  (.I0(issue_step), .O(issue_step_rql));
	LUT1 #(.INIT(2'b10)) u_buf_is_rqh  (.I0(issue_step), .O(issue_step_rqh));
	LUT1 #(.INIT(2'b10)) u_buf_is_curl (.I0(issue_step), .O(issue_step_curl));
	LUT1 #(.INIT(2'b10)) u_buf_is_curh (.I0(issue_step), .O(issue_step_curh));
	LUT1 #(.INIT(2'b10)) u_buf_is_rowl (.I0(issue_step), .O(issue_step_rowl));
	LUT1 #(.INIT(2'b10)) u_buf_is_rowh (.I0(issue_step), .O(issue_step_rowh));
	LUT1 #(.INIT(2'b10)) u_buf_is_ctla (.I0(issue_step), .O(issue_step_ctla));
	LUT1 #(.INIT(2'b10)) u_buf_is_ctlk (.I0(issue_step), .O(issue_step_ctlk));
	LUT1 #(.INIT(2'b10)) u_buf_is_ctlr (.I0(issue_step), .O(issue_step_ctlr));
`else
	wire issue_step_rql = issue_step, issue_step_rqh = issue_step;
	wire issue_step_curl = issue_step, issue_step_curh = issue_step;
	wire issue_step_rowl = issue_step, issue_step_rowh = issue_step;
	wire issue_step_ctla = issue_step;
	wire issue_step_ctlk = issue_step;
	wire issue_step_ctlr = issue_step;
`endif

	always @(posedge clk) begin
		if (rst_high) begin
			rq_k <= 16'd0;
		end else if (start) begin
			rq_k <= 16'd0;
		end else if (issue_step_ctlk) begin
			if (k_is_nl_a0)
				rq_k <= 16'd0;
			else
				rq_k <= rq_k_inc;
		end
	end

	always @(posedge clk) begin
		if (rst_high) begin
			rq_row <= 16'd0;
		end else if (start) begin
			rq_row <= 16'd0;
		end else if (issue_step_ctlr && k_is_nl_b0) begin
			rq_row <= rq_row_inc;
		end
	end

	always @(posedge clk) begin
		if (rst_high) begin
			enable_q <= 1'b0;
			epoch <= 4'd0;
			tag_q <= 4'd0;
			rq_active <= 1'b0;
			req_valid <= 1'b0;
			inflight <= {(LFIFO_LOG2 + 1){1'b0}};
			used <= {(LFIFO_LOG2 + 1){1'b0}};
			f_w <= 16'd0;
			f_h <= 16'd0;
			f_nl <= 16'd0;
			f_nl_last <= 16'd0;
			f_h_last <= 16'd0;
			f_16 <= 1'b0;
			f_16_lo0 <= 1'b0;
			f_16_lo1 <= 1'b0;
			f_16_hi0 <= 1'b0;
			f_16_hi1 <= 1'b0;
		end else begin
			enable_q <= enable;
			inflight <= infl_next;
			if (abort) begin
				epoch <= epoch_inc;
				rq_active <= 1'b0;
				used <= {(LFIFO_LOG2 + 1){1'b0}};
			end else begin
				case ({take, l_pop})
				2'b10: used <= used_inc;
				2'b01: used <= used_dec;
				default: ;
				endcase
			end
			if (start) begin
				if (take)
					req_valid <= 1'b0;
				rq_active <= fb_size[15:0] != 16'd0 && fb_size[31:16] != 16'd0;
				f_w <= fb_size[15:0];
				f_h <= fb_size[31:16];
				f_nl <= row_lines[15:0];
				f_nl_last <= calc_nl_last;
				f_h_last <= calc_h_last;
				f_16 <= format == 2'd2;
				f_16_lo0 <= format == 2'd2;
				f_16_lo1 <= format == 2'd2;
				f_16_hi0 <= format == 2'd2;
				f_16_hi1 <= format == 2'd2;
			end else if (issue_step_ctla) begin
				/* One line of the frame. */
				req_valid <= 1'b1;
				tag_q <= epoch;
				if (k_is_nl_b0) begin
					if (rq_row == f_h_last)
						rq_active <= 1'b0;
				end
			end else if (take) begin
				req_valid <= 1'b0;
			end
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			req_line_lo <= 14'd0;
		else if (issue_step_rql)
			req_line_lo <= rq_cur_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			req_line_hi <= {(AW-14){1'b0}};
		else if (issue_step_rqh)
			req_line_hi <= rq_cur_hi;
	end

	always @(posedge clk) begin
		if (rst_high)
			rq_cur_lo <= 14'd0;
		else if (start)
			rq_cur_lo <= fb_base[LINE_SHIFT +: 14];
		else if (issue_step_curl)
			rq_cur_lo <= k_is_nl_a1 ? rq_next_row[13:0] : rq_cur_inc[13:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			rq_cur_hi <= {(AW-14){1'b0}};
		else if (start)
			rq_cur_hi <= fb_base[LINE_SHIFT + 14 +: AW - 14];
		else if (issue_step_curh)
			rq_cur_hi <= k_is_nl_b1 ? rq_next_row[AW-1:14] : rq_cur_inc[AW-1:14];
	end

	always @(posedge clk) begin
		if (rst_high)
			rq_row_line_lo <= 14'd0;
		else if (start)
			rq_row_line_lo <= fb_base[LINE_SHIFT +: 14];
		else if (issue_step_rowl && k_is_nl_a1)
			rq_row_line_lo <= rq_next_row[13:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			rq_row_line_hi <= {(AW-14){1'b0}};
		else if (start)
			rq_row_line_hi <= fb_base[LINE_SHIFT + 14 +: AW - 14];
		else if (issue_step_rowh && k_is_nl_b1)
			rq_row_line_hi <= rq_next_row[AW-1:14];
	end

	always @(posedge clk) begin
		if (rst_high)
			f_stride_lo <= 14'd0;
		else if (start)
			f_stride_lo <= fb_stride[LINE_SHIFT +: 14];
	end

	always @(posedge clk) begin
		if (rst_high)
			f_stride_hi <= {(AW-14){1'b0}};
		else if (start)
			f_stride_hi <= fb_stride[LINE_SHIFT + 14 +: AW - 14];
	end

	/* Sliced line FIFO (Rule 2 fanout isolation for 512-bit width) */
	wire l_valid;
	wire [LW-1:0] l_data;
	wire l_pop;
	wire l_in_ready = 1'b1;	/* always 1 when a response comes: the requests wait for room */
	wire keep = rsp_read && rsp_tag[3:0] == epoch && !abort;

	always @(posedge clk)
		if (rst_high)
			err <= 1'b0;
		else
			err <= keep && rsp_error;

	localparam NUM_L_SLICES = LW / 16;
	localparam NUM_L_GROUPS = 4;
	localparam SLICES_PER_GROUP = NUM_L_SLICES / NUM_L_GROUPS;

	reg [LFIFO_LOG2:0] l_wp, l_rp;
	wire [LFIFO_LOG2:0] l_wp_next, l_rp_next;
	wire [1:0] l_fifo_co_unused;
	am_add #(.W(LFIFO_LOG2 + 1)) a_lwp (.a(l_wp), .b({(LFIFO_LOG2 + 1){1'b0}}), .ci(1'b1), .s(l_wp_next), .co(l_fifo_co_unused[0]));
	am_add #(.W(LFIFO_LOG2 + 1)) a_lrp (.a(l_rp), .b({(LFIFO_LOG2 + 1){1'b0}}), .ci(1'b1), .s(l_rp_next), .co(l_fifo_co_unused[1]));

	reg l_valid_r;
	wire l_will_empty = (l_rp_next == l_wp);
	assign l_valid = l_valid_r;

	wire dma_rst = rst_high || abort;

	always @(posedge clk) begin
		if (dma_rst) begin
			l_wp <= {(LFIFO_LOG2 + 1){1'b0}};
			l_rp <= {(LFIFO_LOG2 + 1){1'b0}};
			l_valid_r <= 1'b0;
		end else begin
			if (keep)
				l_wp <= l_wp_next;
			if (l_pop)
				l_rp <= l_rp_next;
			case ({keep, l_pop})
			2'b10: l_valid_r <= 1'b1;
			2'b01: l_valid_r <= !l_will_empty;
			default: ;
			endcase
		end
	end

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire rst_abort = dma_rst;
	localparam NUM_BUFS = NUM_L_SLICES * 4;
	wire [NUM_BUFS-1:0] keep_b;
	wire [NUM_BUFS-1:0] l_pop_b;
	wire [NUM_BUFS-1:0] rsp_error_b;

	wire [3:0] keep_tree;
	wire [3:0] l_pop_tree;
	wire [3:0] rsp_error_tree;
	genvar gti;
	generate
		for (gti = 0; gti < 4; gti = gti + 1) begin : g_slice_tree
			LUT1 #(.INIT(2'b10)) u_t_k (.I0(keep), .O(keep_tree[gti]));
			LUT1 #(.INIT(2'b10)) u_t_p (.I0(l_pop), .O(l_pop_tree[gti]));
			LUT1 #(.INIT(2'b10)) u_t_e (.I0(rsp_error), .O(rsp_error_tree[gti]));
		end
	endgenerate

	genvar gki;
	generate
		for (gki = 0; gki < NUM_BUFS; gki = gki + 1) begin : g_slice_bufs
			LUT1 #(.INIT(2'b10)) u_buf_k (.I0(keep_tree[gki / 16]), .O(keep_b[gki]));
			LUT1 #(.INIT(2'b10)) u_buf_p (.I0(l_pop_tree[gki / 16]), .O(l_pop_b[gki]));
			LUT1 #(.INIT(2'b10)) u_buf_e (.I0(rsp_error_tree[gki / 16]), .O(rsp_error_b[gki]));
		end
	endgenerate

	wire [LFIFO_LOG2-1:0] l_wp_tree [0:3];
	wire [LFIFO_LOG2-1:0] l_rp_tree [0:3];
	genvar gptr;
	generate
		for (gptr = 0; gptr < 4; gptr = gptr + 1) begin : g_ptr_tree
			LUT1 #(.INIT(2'b10)) u_buf_wp0 (.I0(l_wp_next[0]), .O(l_wp_tree[gptr][0]));
			LUT1 #(.INIT(2'b10)) u_buf_wp1 (.I0(l_wp_next[1]), .O(l_wp_tree[gptr][1]));
			LUT1 #(.INIT(2'b10)) u_buf_wp2 (.I0(l_wp_next[2]), .O(l_wp_tree[gptr][2]));
			LUT1 #(.INIT(2'b10)) u_buf_wp3 (.I0(l_wp_next[3]), .O(l_wp_tree[gptr][3]));
			LUT1 #(.INIT(2'b10)) u_buf_wp4 (.I0(l_wp_next[4]), .O(l_wp_tree[gptr][4]));
			LUT1 #(.INIT(2'b10)) u_buf_rp0 (.I0(l_rp_next[0]), .O(l_rp_tree[gptr][0]));
			LUT1 #(.INIT(2'b10)) u_buf_rp1 (.I0(l_rp_next[1]), .O(l_rp_tree[gptr][1]));
			LUT1 #(.INIT(2'b10)) u_buf_rp2 (.I0(l_rp_next[2]), .O(l_rp_tree[gptr][2]));
			LUT1 #(.INIT(2'b10)) u_buf_rp3 (.I0(l_rp_next[3]), .O(l_rp_tree[gptr][3]));
			LUT1 #(.INIT(2'b10)) u_buf_rp4 (.I0(l_rp_next[4]), .O(l_rp_tree[gptr][4]));
		end
	endgenerate
`else
	(* max_fanout = 16 *) reg [LFIFO_LOG2-1:0] s_wp;
	(* max_fanout = 16 *) reg [LFIFO_LOG2-1:0] s_rp;

	always @(posedge clk) begin
		if (dma_rst) begin
			s_wp <= {LFIFO_LOG2{1'b0}};
			s_rp <= {LFIFO_LOG2{1'b0}};
		end else begin
			if (keep)
				s_wp <= l_wp_next[LFIFO_LOG2-1:0];
			if (l_pop)
				s_rp <= l_rp_next[LFIFO_LOG2-1:0];
		end
	end
`endif

	genvar igrp;
	generate
	for (igrp = 0; igrp < NUM_L_SLICES * 4; igrp = igrp + 1) begin : g_l_grp
`ifdef SYNTH_KINTEX7
		(* max_fanout = 16 *) reg [LFIFO_LOG2-1:0] s_wp_r;
		(* max_fanout = 16 *) reg [LFIFO_LOG2-1:0] s_rp_r;
		always @(posedge clk) begin
			if (dma_rst) begin
				s_wp_r <= {LFIFO_LOG2{1'b0}};
				s_rp_r <= {LFIFO_LOG2{1'b0}};
			end else begin
				if (keep_b[igrp])
					s_wp_r <= l_wp_tree[igrp / 16];
				if (l_pop_b[igrp])
					s_rp_r <= l_rp_tree[igrp / 16];
			end
		end

		RAM32X1D u_ram0 (
			.WCLK(clk), .WE(keep_b[igrp]),
			.D(rsp_error_b[igrp] ? 1'b0 : rsp_rdata[igrp*4 + 0]),
			.A0(s_wp_r[0]), .A1(s_wp_r[1]), .A2(s_wp_r[2]), .A3(s_wp_r[3]), .A4(s_wp_r[4]),
			.DPRA0(s_rp_r[0]), .DPRA1(s_rp_r[1]), .DPRA2(s_rp_r[2]), .DPRA3(s_rp_r[3]), .DPRA4(s_rp_r[4]),
			.SPO(), .DPO(l_data[igrp*4 + 0])
		);
		RAM32X1D u_ram1 (
			.WCLK(clk), .WE(keep_b[igrp]),
			.D(rsp_error_b[igrp] ? 1'b0 : rsp_rdata[igrp*4 + 1]),
			.A0(s_wp_r[0]), .A1(s_wp_r[1]), .A2(s_wp_r[2]), .A3(s_wp_r[3]), .A4(s_wp_r[4]),
			.DPRA0(s_rp_r[0]), .DPRA1(s_rp_r[1]), .DPRA2(s_rp_r[2]), .DPRA3(s_rp_r[3]), .DPRA4(s_rp_r[4]),
			.SPO(), .DPO(l_data[igrp*4 + 1])
		);
		RAM32X1D u_ram2 (
			.WCLK(clk), .WE(keep_b[igrp]),
			.D(rsp_error_b[igrp] ? 1'b0 : rsp_rdata[igrp*4 + 2]),
			.A0(s_wp_r[0]), .A1(s_wp_r[1]), .A2(s_wp_r[2]), .A3(s_wp_r[3]), .A4(s_wp_r[4]),
			.DPRA0(s_rp_r[0]), .DPRA1(s_rp_r[1]), .DPRA2(s_rp_r[2]), .DPRA3(s_rp_r[3]), .DPRA4(s_rp_r[4]),
			.SPO(), .DPO(l_data[igrp*4 + 2])
		);
		RAM32X1D u_ram3 (
			.WCLK(clk), .WE(keep_b[igrp]),
			.D(rsp_error_b[igrp] ? 1'b0 : rsp_rdata[igrp*4 + 3]),
			.A0(s_wp_r[0]), .A1(s_wp_r[1]), .A2(s_wp_r[2]), .A3(s_wp_r[3]), .A4(s_wp_r[4]),
			.DPRA0(s_rp_r[0]), .DPRA1(s_rp_r[1]), .DPRA2(s_rp_r[2]), .DPRA3(s_rp_r[3]), .DPRA4(s_rp_r[4]),
			.SPO(), .DPO(l_data[igrp*4 + 3])
		);
`else
		reg [3:0] grp_mem [0:LFIFO-1];
		always @(posedge clk) begin
			if (keep)
				grp_mem[s_wp] <= rsp_error ? 4'd0 : rsp_rdata[igrp*4 +: 4];
		end
		assign l_data[igrp*4 +: 4] = grp_mem[s_rp];
`endif
	end
	endgenerate

	wire [LFIFO_LOG2:0] lcount = {(LFIFO_LOG2 + 1){1'b0}};

	/* The unpacker. */
	reg up_active;
	reg [15:0] up_row, up_x;
	(* max_fanout = 16 *) reg [5:0] up_idx;
	wire [5:0] ppl = f_16 ? PPL16 : PPL32;
	wire push = px_valid && px_ready;
	wire [15:0] calc_w_last;
	reg [15:0] f_w_last;
	wire [5:0] ppl_last = f_16 ? PPL16_LAST : PPL32_LAST;
	wire [1:0] up_co_unused;

	am_sub #(.W(16)) s_w (.a(fb_size[15:0]), .b(16'd1), .bi(1'b0), .d(calc_w_last), .bo(up_co_unused[0]));
	assign up_co_unused[1] = 1'b0;
`ifdef SYNTH_KINTEX7
	reg row_end_r;
	wire [15:0] diff_next_w = up_x_inc ^ f_w_last;
	wire next_is_row_end = ~(|diff_next_w);
	wire zero_w_last = ~(|f_w_last);
	always @(posedge clk) begin
		if (rst_high) begin
			row_end_r <= 1'b0;
		end else if (abort) begin
			row_end_r <= ~(|calc_w_last);
		end else if (push) begin
			if (row_end_r)
				row_end_r <= zero_w_last;
			else
				row_end_r <= next_is_row_end;
		end
	end
	wire row_end = row_end_r;
	wire [15:0] diff_h_last = up_row ^ f_h_last;
	wire row_h_end = ~(|diff_h_last);
	wire [5:0] diff_ppl = up_idx ^ ppl_last;
	wire ppl_match = ~(|diff_ppl);
`else
	wire row_end = up_x == f_w_last;
	wire row_h_end = up_row == f_h_last;
	wire ppl_match = up_idx == ppl_last;
`endif
	assign l_pop = push && (row_end || ppl_match);
	assign px_valid = up_active && l_valid && !abort;
	assign px_data[7:0] = f_16_lo0 ? l_data[{up_idx[LINE_SHIFT-2:0], 4'b0000} +: 8] :
		l_data[{up_idx[LINE_SHIFT-3:0], 5'b00000} +: 8];
	assign px_data[15:8] = f_16_lo1 ? l_data[{up_idx[LINE_SHIFT-2:0], 4'b1000} +: 8] :
		l_data[{up_idx[LINE_SHIFT-3:0], 5'b01000} +: 8];
	assign px_data[23:16] = f_16_hi0 ? 8'd0 :
		l_data[{up_idx[LINE_SHIFT-3:0], 5'b10000} +: 8];
	assign px_data[31:24] = f_16_hi1 ? 8'd0 :
		l_data[{up_idx[LINE_SHIFT-3:0], 5'b11000} +: 8];

	/* Pipelined pixel accumulator (Rule 1 & Rule 4) */
	reg [31:0] sum_px;
	(* keep = "true" *) reg sum_push, sum_push_lo, sum_push_hi;
	always @(posedge clk) begin
		if (dma_rst) begin
			sum_px <= 32'd0;
			sum_push <= 1'b0;
			sum_push_lo <= 1'b0;
			sum_push_hi <= 1'b0;
		end else begin
			sum_px <= px_data;
			sum_push <= push;
			sum_push_lo <= push;
			sum_push_hi <= push;
		end
	end

	(* max_fanout = 16 *) reg [31:0] sum_acc, words_acc;

	/* The unpacker's sums: the frame's sum and words, and the next row, column and pixel of the line. */
	wire [31:0] sum_next, words_inc;
	wire [15:0] up_row_inc, up_x_inc;
	wire [5:0] up_idx_inc;
	wire [4:0] acc_co_unused;

	am_add #(.W(32)) a_sum (.a(sum_acc), .b(sum_px), .ci(1'b0), .s(sum_next), .co(acc_co_unused[0]));
	am_add #(.W(32)) a_words (.a(words_acc), .b(32'd0), .ci(1'b1), .s(words_inc), .co(acc_co_unused[1]));
	am_add #(.W(16)) a_urow (.a(up_row), .b(16'd0), .ci(1'b1), .s(up_row_inc), .co(acc_co_unused[2]));
	am_add #(.W(16)) a_ux (.a(up_x), .b(16'd0), .ci(1'b1), .s(up_x_inc), .co(acc_co_unused[3]));
	am_add #(.W(6)) a_uidx (.a(up_idx), .b(6'd0), .ci(1'b1), .s(up_idx_inc), .co(acc_co_unused[4]));

	assign done = !rq_active_done && !up_active && !sum_push;

`ifdef SYNTH_KINTEX7
	wire push_w_lo, push_w_hi, push_up0, push_up1, push_idx_lo, push_idx_hi;
	LUT1 #(.INIT(2'b10)) u_buf_pwl (.I0(push), .O(push_w_lo));
	LUT1 #(.INIT(2'b10)) u_buf_pwh (.I0(push), .O(push_w_hi));
	LUT1 #(.INIT(2'b10)) u_buf_pup0 (.I0(push), .O(push_up0));
	LUT1 #(.INIT(2'b10)) u_buf_pup1 (.I0(push), .O(push_up1));
	LUT1 #(.INIT(2'b10)) u_buf_pidxl (.I0(push), .O(push_idx_lo));
	LUT1 #(.INIT(2'b10)) u_buf_pidxh (.I0(push), .O(push_idx_hi));
`else
	wire push_w_lo = push;
	wire push_w_hi = push;
	wire push_up0 = push;
	wire push_up1 = push;
	wire push_idx_lo = push;
	wire push_idx_hi = push;
`endif

	always @(posedge clk) begin
		if (rst_high)
			up_active <= 1'b0;
		else if (abort)
			up_active <= start && fb_size[15:0] != 16'd0 && fb_size[31:16] != 16'd0;
		else if (push_up1 && row_end && row_h_end)
			up_active <= 1'b0;
	end

	always @(posedge clk) begin
		if (rst_high)
			f_w_last <= 16'd0;
		else if (abort)
			f_w_last <= calc_w_last;
	end

	always @(posedge clk) begin
		if (rst_high)
			scan_sum[15:0] <= 16'd0;
		else if (abort)
			scan_sum[15:0] <= sum_acc[15:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			scan_sum[31:16] <= 16'd0;
		else if (abort)
			scan_sum[31:16] <= sum_acc[31:16];
	end

	always @(posedge clk) begin
		if (rst_high)
			scan_words[15:0] <= 16'd0;
		else if (abort)
			scan_words[15:0] <= words_acc[15:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			scan_words[31:16] <= 16'd0;
		else if (abort)
			scan_words[31:16] <= words_acc[31:16];
	end

	always @(posedge clk) begin
		if (dma_rst)
			sum_acc[15:0] <= 16'd0;
		else if (sum_push_lo)
			sum_acc[15:0] <= sum_next[15:0];
	end

	always @(posedge clk) begin
		if (dma_rst)
			sum_acc[31:16] <= 16'd0;
		else if (sum_push_hi)
			sum_acc[31:16] <= sum_next[31:16];
	end

	always @(posedge clk) begin
		if (dma_rst)
			words_acc[15:0] <= 16'd0;
		else if (push_w_lo)
			words_acc[15:0] <= words_inc[15:0];
	end

	always @(posedge clk) begin
		if (dma_rst)
			words_acc[31:16] <= 16'd0;
		else if (push_w_hi)
			words_acc[31:16] <= words_inc[31:16];
	end

	always @(posedge clk) begin
		if (dma_rst)
			up_x <= 16'd0;
		else if (push_up0)
			up_x <= row_end ? 16'd0 : up_x_inc;
	end

	always @(posedge clk) begin
		if (dma_rst)
			up_idx[2:0] <= 3'd0;
		else if (push_idx_lo)
			up_idx[2:0] <= row_end ? 3'd0 : (ppl_match ? 3'd0 : up_idx_inc[2:0]);
	end

	always @(posedge clk) begin
		if (dma_rst)
			up_idx[5:3] <= 3'd0;
		else if (push_idx_hi)
			up_idx[5:3] <= row_end ? 3'd0 : (ppl_match ? 3'd0 : up_idx_inc[5:3]);
	end

	always @(posedge clk) begin
		if (dma_rst)
			up_row <= 16'd0;
		else if (push_up1 && row_end)
			up_row <= up_row_inc;
	end

	wire unused_ok = &{1'b0, fb_base[LINE_SHIFT-1:0], fb_stride[LINE_SHIFT-1:0],
		rsp_tag[7:4], l_in_ready, row_lines[17:16], up_idx[5:LINE_SHIFT-1], row_co_unused, rq_co_unused,
		up_co_unused, acc_co_unused, u_co_unused};
endmodule

`default_nettype wire
