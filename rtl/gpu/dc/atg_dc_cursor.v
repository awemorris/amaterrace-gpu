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

	/* The loader's sums: the reads in flight or waiting, the next counts and the next line's address. */
	wire [2:0] infl_up, infl_next, used;
	wire [NL_W:0] rq_inc, wr_inc;
	wire [WS-1:0] up_inc;
	wire [AW-1:0] rq_line;
	wire [6:0] ld_co_unused;

	am_add #(.W(3)) a_infl (.a(inflight), .b(3'd0), .ci(take), .s(infl_up), .co(ld_co_unused[0]));
	am_sub #(.W(3)) s_infl (.a(infl_up), .b(3'd0), .bi(rsp_read), .d(infl_next), .bo(ld_co_unused[1]));
	am_add #(.W(3)) a_used (.a(inflight), .b(lcount), .ci(1'b0), .s(used), .co(ld_co_unused[2]));
	am_add #(.W(NL_W + 1)) a_rq (.a(rq_n), .b({(NL_W + 1){1'b0}}), .ci(1'b1), .s(rq_inc), .co(ld_co_unused[3]));
	am_add #(.W(NL_W + 1)) a_wr (.a(wr_n), .b({(NL_W + 1){1'b0}}), .ci(1'b1), .s(wr_inc), .co(ld_co_unused[4]));
	am_add #(.W(WS)) a_up (.a(up_w), .b({WS{1'b0}}), .ci(1'b1), .s(up_inc), .co(ld_co_unused[5]));
	am_add #(.W(AW)) a_line (.a(pend_base[ADDR_W-1:LINE_SHIFT]), .b({{(AW - NL_W - 1){1'b0}}, rq_n}), .ci(1'b0),
		.s(rq_line), .co(ld_co_unused[6]));

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
			inflight <= infl_next;
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
					if (!req_valid && rq_n != NLINES && used < 3'd4) begin
						req_valid <= 1'b1;
						req_line <= rq_line;
						rq_n <= rq_inc;
					end
					if (mem_we) begin
						up_w <= up_inc;
						if (up_w == WLAST) begin
							wr_n <= wr_inc;
							if (wr_inc == NLINES)
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

	/* The blend pipeline (3 stages: Fetch/BRAM -> Mix -> Narrow/Output). */
	reg st0_valid, s_in;
	reg [1:0] s_fmt;
	reg [31:0] s_px, q;
	reg [15:0] x, y;
	reg [15:0] pos_x, pos_y;
	reg vis;

	wire st1_ready;
	wire st0_ready = !st0_valid || st1_ready;
	wire accept = i_valid && st0_ready;
	assign i_ready = st0_ready;

	wire [16:0] dx, dy;
	wire [15:0] x_inc, y_inc, x_last;
	wire [4:0] bl_co_unused;

	/* The pixel's place in the cursor, and the next column and row of the screen. */
	am_sub #(.W(17)) s_dx (.a({1'b0, x}), .b({pos_x[15], pos_x}), .bi(1'b0), .d(dx), .bo(bl_co_unused[0]));
	am_sub #(.W(17)) s_dy (.a({1'b0, y}), .b({pos_y[15], pos_y}), .bi(1'b0), .d(dy), .bo(bl_co_unused[1]));
	am_add #(.W(16)) a_x (.a(x), .b(16'd0), .ci(1'b1), .s(x_inc), .co(bl_co_unused[2]));
	am_add #(.W(16)) a_y (.a(y), .b(16'd0), .ci(1'b1), .s(y_inc), .co(bl_co_unused[3]));
	am_sub #(.W(16)) s_w (.a(fb_width), .b(16'd1), .bi(1'b0), .d(x_last), .bo(bl_co_unused[4]));
	wire in_cur = dx[16:6] == 11'd0 && dy[16:6] == 11'd0;

	always @(posedge clk)
		if (accept)
			q <= mem[{dy[5:0], dx[5:0]}];

	always @(posedge clk) begin
		if (!rst_n) begin
			st0_valid <= 1'b0;
			s_in <= 1'b0;
			s_fmt <= 2'd0;
			s_px <= 32'd0;
			x <= 16'd0;
			y <= 16'd0;
			pos_x <= 16'd0;
			pos_y <= 16'd0;
			vis <= 1'b0;
		end else if (frame_start || !enable) begin
			st0_valid <= 1'b0;
			x <= 16'd0;
			y <= 16'd0;
			pos_x <= pos[15:0];
			pos_y <= pos[31:16];
			vis <= show;
		end else if (st0_ready) begin
			st0_valid <= i_valid;
			if (i_valid) begin
				s_px <= i_data;
				s_fmt <= format;
				s_in <= in_cur && vis && img_ok && st == S_IDLE;
				if (x == x_last) begin
					x <= 16'd0;
					y <= y_inc;
				end else begin
					x <= x_inc;
				end
			end
		end
	end

	/* Stage 1: Mix computation */
	wire [7:0] cb = q[7:0], cg = q[15:8], cr = q[23:16], ca = q[31:24];
	wire [7:0] r8 = {s_px[15:11], s_px[15:13]};
	wire [7:0] g8 = {s_px[10:5], s_px[10:9]};
	wire [7:0] b8 = {s_px[4:0], s_px[4:2]};

	wire [23:0] mix_c = (s_fmt == 2'd1) ? {cb, cg, cr} : {cr, cg, cb};
	wire [23:0] mix_p = (s_fmt == 2'd2) ? {r8, g8, b8} : s_px[23:0];
	wire [7:0] st0_v [0:2];
	wire [2:0] t_co_unused, u_co_unused;

	genvar k;
	generate
	for (k = 0; k < 3; k = k + 1) begin : g_mix
		wire [7:0] c = mix_c[8*(2-k) +: 8];
		wire [7:0] p = mix_p[8*(2-k) +: 8];
		wire [15:0] pa, t, u;
		wire [8:0] sum;

		am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(0)) m_pa (.clk(clk), .en(1'b1), .a(p), .b(~ca), .p(pa));
		am_add #(.W(16)) a_t (.a(pa), .b(16'd128), .ci(1'b0), .s(t), .co(t_co_unused[k]));
		am_add #(.W(16)) a_u (.a(t), .b({8'd0, t[15:8]}), .ci(1'b0), .s(u), .co(u_co_unused[k]));
		am_add #(.W(8)) a_s (.a(c), .b(u[15:8]), .ci(1'b0), .s(sum[7:0]), .co(sum[8]));
		assign st0_v[k] = sum[8] ? 8'hFF : sum[7:0];
	end
	endgenerate

	wire st2_ready;
	assign st1_ready = !st1_valid || st2_ready;
	reg st1_valid;
	reg [7:0] st1_v0, st1_v1, st1_v2;
	reg [31:0] st1_px;
	reg st1_in;
	reg [1:0] st1_fmt;

	always @(posedge clk) begin
		if (!rst_n) begin
			st1_valid <= 1'b0;
			st1_v0 <= 8'd0;
			st1_v1 <= 8'd0;
			st1_v2 <= 8'd0;
			st1_px <= 32'd0;
			st1_in <= 1'b0;
			st1_fmt <= 2'd0;
		end else if (frame_start || !enable) begin
			st1_valid <= 1'b0;
		end else if (st1_ready) begin
			st1_valid <= st0_valid;
			if (st0_valid) begin
				st1_v0 <= st0_v[0];
				st1_v1 <= st0_v[1];
				st1_v2 <= st0_v[2];
				st1_px <= s_px;
				st1_in <= s_in;
				st1_fmt <= s_fmt;
			end
		end
	end

	/* Testbench identity check wires (combinational from q and s_px) */
	wire [23:0] tb_mix_c = (format == 2'd1) ? {cb, cg, cr} : {cr, cg, cb};
	wire [23:0] tb_mix_p = (format == 2'd2) ? {r8, g8, b8} : s_px[23:0];
	wire [5:0] tb_narrowed [0:2];
	wire [2:0] tb_t_unused, tb_u_unused, tb_vm_unused, tb_nt_unused, tb_nu_unused;

	genvar m;
	generate
	for (m = 0; m < 3; m = m + 1) begin : g_tb
		wire [7:0] c = tb_mix_c[8*(2-m) +: 8];
		wire [7:0] p = tb_mix_p[8*(2-m) +: 8];
		wire [15:0] pa, t, u;
		wire [8:0] sum;
		am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(0)) m_pa (.clk(clk), .en(1'b1), .a(p), .b(~ca), .p(pa));
		am_add #(.W(16)) a_t (.a(pa), .b(16'd128), .ci(1'b0), .s(t), .co(tb_t_unused[m]));
		am_add #(.W(16)) a_u (.a(t), .b({8'd0, t[15:8]}), .ci(1'b0), .s(u), .co(tb_u_unused[m]));
		am_add #(.W(8)) a_s (.a(c), .b(u[15:8]), .ci(1'b0), .s(sum[7:0]), .co(sum[8]));
		wire [7:0] v = sum[8] ? 8'hFF : sum[7:0];
		wire [15:0] vm, nt, nu;
		if (m == 1) begin : g_63
			am_sub #(.W(16)) s_vm (.a({2'd0, v, 6'd0}), .b({8'd0, v}), .bi(1'b0), .d(vm), .bo(tb_vm_unused[m]));
		end else begin : g_31
			am_sub #(.W(16)) s_vm (.a({3'd0, v, 5'd0}), .b({8'd0, v}), .bi(1'b0), .d(vm), .bo(tb_vm_unused[m]));
		end
		am_add #(.W(16)) a_nt (.a(vm), .b(16'd128), .ci(1'b0), .s(nt), .co(tb_nt_unused[m]));
		am_add #(.W(16)) a_nu (.a(nt), .b({8'd0, nt[15:8]}), .ci(1'b0), .s(nu), .co(tb_nu_unused[m]));
		assign tb_narrowed[m] = nu[13:8];
	end
	endgenerate
	wire [5:0] r5 = tb_narrowed[0];
	wire [5:0] g6 = tb_narrowed[1];
	wire [5:0] b5 = tb_narrowed[2];

	/* Stage 2: Narrow computation & output */
	wire [5:0] narrowed [0:2];
	wire [2:0] vm_bo_unused, nt_co_unused, nu_co_unused;
	generate
	for (k = 0; k < 3; k = k + 1) begin : g_narrow
		wire [7:0] v = (k == 0) ? st1_v0 : (k == 1) ? st1_v1 : st1_v2;
		wire [15:0] vm, nt, nu;

		if (k == 1) begin : g_63
			am_sub #(.W(16)) s_vm (.a({2'd0, v, 6'd0}), .b({8'd0, v}), .bi(1'b0), .d(vm), .bo(vm_bo_unused[k]));
		end else begin : g_31
			am_sub #(.W(16)) s_vm (.a({3'd0, v, 5'd0}), .b({8'd0, v}), .bi(1'b0), .d(vm), .bo(vm_bo_unused[k]));
		end
		am_add #(.W(16)) a_nt (.a(vm), .b(16'd128), .ci(1'b0), .s(nt), .co(nt_co_unused[k]));
		am_add #(.W(16)) a_nu (.a(nt), .b({8'd0, nt[15:8]}), .ci(1'b0), .s(nu), .co(nu_co_unused[k]));
		assign narrowed[k] = nu[13:8];
	end
	endgenerate

	wire [5:0] st2_r5 = narrowed[0];
	wire [5:0] st2_g6 = narrowed[1];
	wire [5:0] st2_b5 = narrowed[2];
	wire [23:0] mixed = {st1_v0, st1_v1, st1_v2};
	reg [31:0] blended;

	always @(*) begin
		case (st1_fmt)
		2'd2:
			blended = {st1_px[31:16], st2_r5[4:0], st2_g6, st2_b5[4:0]};
		default:	/* BGRA8, RGBA8 */
			blended = {st1_px[31:24], mixed};
		endcase
	end

	wire [31:0] nxt_out_data = st1_in ? blended : st1_px;

	assign st2_ready = !st2_valid || o_ready;
	reg st2_valid;
	reg [31:0] st2_data;

	always @(posedge clk) begin
		if (!rst_n) begin
			st2_valid <= 1'b0;
			st2_data <= 32'd0;
		end else if (frame_start || !enable) begin
			st2_valid <= 1'b0;
		end else if (st2_ready) begin
			st2_valid <= st1_valid;
			if (st1_valid)
				st2_data <= nxt_out_data;
		end
	end

	assign o_valid = st2_valid;
	assign o_data = st2_data;

	wire unused_ok = &{1'b0, rsp_tag, l_in_ready, r5[5], b5[5], st2_r5[5], st2_b5[5], flip_base[5:0], ld_co_unused, bl_co_unused,
		t_co_unused, u_co_unused, vm_bo_unused, nt_co_unused, nu_co_unused,
		tb_t_unused, tb_u_unused, tb_vm_unused, tb_nt_unused, tb_nu_unused};
endmodule

`default_nettype wire
