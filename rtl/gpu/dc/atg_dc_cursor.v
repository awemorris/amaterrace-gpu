/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_cursor: the cursor plane (plane 1 of DISP2, docs/ghci.md section
 * 13.2): a 64 x 64 BGRA8 image with premultiplied alpha, read once per flip
 * into a BRAM and blended, in gclk, over the pixels that atg_dc_dma sends
 * to the pixel FIFO.  See spec/gpu/dc/atg_dc_cursor.md.
 *
 * Flips: flip_valid makes flip_base pending (taken at once as cancelled
 * while enable is 0).  A pending image is loaded when dma_done says the
 * frame's reads are over: 16384 / LINE_BYTES line reads through a line
 * FIFO of 4 entries (a read is issued only with room for its response),
 * unpacked one word a cycle into the BRAM.  At the first frame_start after
 * the load the flip is taken and the image shown.  While a flip is being
 * loaded or waits for its frame start the cursor is not shown (the BRAM
 * holds neither image whole).  enable falling or dc_reset during a load
 * takes the flip as cancelled and hides the cursor until the next flip;
 * the reads still outstanding are counted (rst_n is the board reset) and
 * their responses dropped.  An error response pulses err and hides the
 * image of that flip.
 *
 * Blend: the module counts the stream's pixels from frame_start (x up to
 * fb_width - 1, then the next row) and blends a pixel inside the cursor
 * (pos and show taken at frame_start) as c + round(p x (255 - a) / 255)
 * per channel, saturated; BGRA8 as it is, RGBA8 with the cursor's R and B
 * swapped, RGB565 widened, blended and narrowed by rounding.  One register
 * stage (the BRAM read); it is emptied at frame_start and while enable is
 * 0, so a pixel of an aborted frame does not reach the next one.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_cursor #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire dc_reset,
	input wire enable,
	input wire [1:0] format,
	input wire frame_start,
	input wire dma_done,
	input wire [15:0] fb_width,
	/* The DMA's pixels in, the pixel FIFO out (valid/ready) */
	input wire i_valid,
	output wire i_ready,
	input wire [31:0] i_data,
	output wire o_valid,
	input wire o_ready,
	output wire [31:0] o_data,
	/* CURSOR_POS, CURSOR_CTRL[0] */
	input wire [31:0] pos,
	input wire show,
	/* Flips of plane 1 */
	input wire flip_valid,
	input wire [31:0] flip_base,
	output reg taken,
	output reg taken_cancel,
	output wire pending,
	output wire [31:0] cursor_base,
	output wire idle,
	output reg err,
	/* AMB client port (reads only) */
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
	localparam WS = LINE_SHIFT - 2;	/* log2(words in a line) */
	localparam NL_W = 14 - LINE_SHIFT;	/* log2(lines of the image) */
	localparam [NL_W:0] NLINES = 1 << NL_W;
	localparam [WS-1:0] WLAST = {WS{1'b1}};

	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_LOAD = 2'd1;	/* reading the pending image into the BRAM */
	localparam [1:0] S_READY = 2'd2;	/* loaded: taken at the next frame start */
	localparam [1:0] S_DRAIN = 2'd3;	/* stopped: waiting for the reads outstanding */

	assign req_write = 1'b0;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LW{1'b0}};
	assign req_tag = 8'd0;

	reg [1:0] st;
	reg pend;
	reg [31:0] pend_base, cur_base;
	reg img_ok, load_err;
	reg [NL_W:0] rq_n, wr_n;
	reg [2:0] inflight;
	reg [WS-1:0] up_w;
	wire [2:0] lcount;
	wire take = req_valid && req_ready;
	wire rsp_read = rsp_valid && !rsp_write;
	wire stop = dc_reset || !enable;
	wire keep = rsp_read && st == S_LOAD && !stop;
	wire l_valid;
	wire [LW-1:0] l_data;
	wire l_in_ready;	/* always 1 when a response comes: the reads wait for room */
	wire l_pop = st == S_LOAD && l_valid && up_w == WLAST;

	assign pending = pend;
	assign cursor_base = cur_base;
	assign idle = !req_valid && inflight == 3'd0;

	am_fifo #(.W(LW), .DEPTH_LOG2(2)) lines (
		.clk(clk), .rst_n(rst_n && st == S_LOAD && !stop),
		.in_valid(keep), .in_ready(l_in_ready), .in_data(rsp_error ? {LW{1'b0}} : rsp_rdata),
		.out_valid(l_valid), .out_ready(l_pop), .out_data(l_data), .count(lcount)
	);

	/* The image: 64 rows of 64 words. */
	reg [31:0] mem [0:4095];
	wire mem_we = st == S_LOAD && l_valid && !stop;

	always @(posedge clk)
		if (mem_we)
			mem[{wr_n[NL_W-1:0], up_w}] <= l_data[32*up_w +: 32];

	always @(posedge clk) begin
		taken <= 1'b0;
		taken_cancel <= 1'b0;
		err <= 1'b0;
		if (!rst_n) begin
			st <= S_IDLE;
			pend <= 1'b0;
			pend_base <= 32'd0;
			cur_base <= 32'd0;
			img_ok <= 1'b0;
			load_err <= 1'b0;
			rq_n <= {(NL_W + 1){1'b0}};
			wr_n <= {(NL_W + 1){1'b0}};
			inflight <= 3'd0;
			up_w <= {WS{1'b0}};
			req_valid <= 1'b0;
			req_line <= {AW{1'b0}};
		end else begin
			inflight <= inflight + {2'd0, take} - {2'd0, rsp_read};
			if (take)
				req_valid <= 1'b0;
			if (keep && rsp_error) begin
				load_err <= 1'b1;
				err <= 1'b1;
			end
			if (flip_valid) begin
				if (stop) begin
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end else begin
					pend <= 1'b1;
					pend_base <= flip_base;
				end
			end
			if (dc_reset)
				img_ok <= 1'b0;
			case (st)
			S_IDLE:
				if (pend && stop) begin
					pend <= 1'b0;
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end else if (pend && dma_done) begin
					st <= S_LOAD;
					rq_n <= {(NL_W + 1){1'b0}};
					wr_n <= {(NL_W + 1){1'b0}};
					up_w <= {WS{1'b0}};
					load_err <= 1'b0;
				end
			S_LOAD:
				if (stop) begin
					st <= S_DRAIN;
					pend <= 1'b0;
					img_ok <= 1'b0;
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end else begin
					if (!req_valid && rq_n != NLINES && inflight + lcount < 3'd4) begin
						req_valid <= 1'b1;
						req_line <= pend_base[ADDR_W-1:LINE_SHIFT] +
							{{(AW - NL_W - 1){1'b0}}, rq_n};
						rq_n <= rq_n + 1'b1;
					end
					if (mem_we) begin
						up_w <= up_w + 1'b1;
						if (up_w == WLAST) begin
							wr_n <= wr_n + 1'b1;
							if (wr_n + 1'b1 == NLINES)
								st <= S_READY;
						end
					end
				end
			S_READY:
				if (stop) begin
					st <= S_IDLE;
					pend <= 1'b0;
					img_ok <= 1'b0;
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end else if (frame_start) begin
					st <= S_IDLE;
					pend <= 1'b0;
					cur_base <= pend_base;
					img_ok <= !load_err;
					taken <= 1'b1;
				end
			default:	/* S_DRAIN */
				if (idle)
					st <= S_IDLE;
			endcase
		end
	end

	/* The blend stage. */
	reg sv, s_in;
	reg [31:0] s_px, q;
	reg [15:0] x, y;
	reg [15:0] pos_x, pos_y;
	reg vis;
	wire accept = i_valid && i_ready;
	wire [16:0] dx = {1'b0, x} - {pos_x[15], pos_x};
	wire [16:0] dy = {1'b0, y} - {pos_y[15], pos_y};
	wire in_cur = dx[16:6] == 11'd0 && dy[16:6] == 11'd0;

	assign i_ready = !sv || o_ready;
	assign o_valid = sv;

	always @(posedge clk)
		if (accept)
			q <= mem[{dy[5:0], dx[5:0]}];

	always @(posedge clk) begin
		if (!rst_n) begin
			sv <= 1'b0;
			s_in <= 1'b0;
			s_px <= 32'd0;
			x <= 16'd0;
			y <= 16'd0;
			pos_x <= 16'd0;
			pos_y <= 16'd0;
			vis <= 1'b0;
		end else if (frame_start || !enable) begin
			sv <= 1'b0;
			x <= 16'd0;
			y <= 16'd0;
			pos_x <= pos[15:0];
			pos_y <= pos[31:16];
			vis <= show;
		end else begin
			if (o_ready)
				sv <= 1'b0;
			if (accept) begin
				sv <= 1'b1;
				s_px <= i_data;
				s_in <= in_cur && vis && img_ok && st == S_IDLE;
				if (x == fb_width - 16'd1) begin
					x <= 16'd0;
					y <= y + 16'd1;
				end else begin
					x <= x + 16'd1;
				end
			end
		end
	end

	/* c + round(p x (255 - a) / 255), saturated; round(t / 255) of t + 128
	 * is (t + 128 + ((t + 128) >> 8)) >> 8 for every t up to 255 x 255. */
	function [7:0] mix;
		input [7:0] c, p, a;
		reg [15:0] t;
		reg [7:0] q8;
		reg [8:0] s;
		begin
			t = {8'd0, p} * {8'd0, ~a} + 16'd128;
			/* verilator lint_off WIDTHTRUNC */
			q8 = (t + {8'd0, t[15:8]}) >> 8;	/* < 256 */
			/* verilator lint_on WIDTHTRUNC */
			s = {1'b0, c} + {1'b0, q8};
			mix = s[8] ? 8'hFF : s[7:0];
		end
	endfunction

	/* round(v x m / 255) for m = 31 or 63. */
	function [5:0] narrow;
		input [7:0] v;
		input [5:0] m;
		reg [15:0] t;
		begin
			t = {8'd0, v} * {10'd0, m} + 16'd128;
			/* verilator lint_off WIDTHTRUNC */
			narrow = (t + {8'd0, t[15:8]}) >> 8;	/* < 64 */
			/* verilator lint_on WIDTHTRUNC */
		end
	endfunction

	wire [7:0] cb = q[7:0], cg = q[15:8], cr = q[23:16], ca = q[31:24];
	wire [7:0] r8 = {s_px[15:11], s_px[15:13]};
	wire [7:0] g8 = {s_px[10:5], s_px[10:9]};
	wire [7:0] b8 = {s_px[4:0], s_px[4:2]};
	wire [5:0] r5 = narrow(mix(cr, r8, ca), 6'd31);
	wire [5:0] g6 = narrow(mix(cg, g8, ca), 6'd63);
	wire [5:0] b5 = narrow(mix(cb, b8, ca), 6'd31);
	reg [31:0] blended;

	always @(*) begin
		case (format)
		2'd1:	/* RGBA8: R in byte 0 */
			blended = {s_px[31:24], mix(cb, s_px[23:16], ca), mix(cg, s_px[15:8], ca),
				mix(cr, s_px[7:0], ca)};
		2'd2:
			blended = {s_px[31:16], r5[4:0], g6, b5[4:0]};
		default:	/* BGRA8 */
			blended = {s_px[31:24], mix(cr, s_px[23:16], ca), mix(cg, s_px[15:8], ca),
				mix(cb, s_px[7:0], ca)};
		endcase
	end

	assign o_data = s_in ? blended : s_px;

	wire unused_ok = &{1'b0, rsp_tag, l_in_ready, r5[5], b5[5], flip_base[5:0]};
endmodule

`default_nettype wire
