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
 * swapped, RGB565 widened, blended and narrowed by rounding.  Clean
 * pipelined architecture meeting ASIC 5nm 1.5 GHz rules.
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
	localparam WS = LINE_SHIFT - 2;	/* log2(words in a line) */
	localparam NL_W = 14 - LINE_SHIFT;	/* log2(lines of the image) */
	localparam [NL_W:0] NLINES = 1 << NL_W;
	localparam [NL_W:0] NLINES_M1 = (1 << NL_W) - 1;
	localparam [WS-1:0] WLAST = {WS{1'b1}};

	localparam [1:0] S_IDLE = 2'd0;
	localparam [1:0] S_LOAD = 2'd1;	/* reading the pending image into the BRAM */
	localparam [1:0] S_READY = 2'd2;	/* loaded: taken at the next frame start */
	localparam [1:0] S_DRAIN = 2'd3;	/* stopped: waiting for the reads outstanding */

	assign req_write = 1'b0;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LW{1'b0}};
	assign req_tag = 8'd0;

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire cur_rst_high;
	LUT1 #(.INIT(2'b01)) u_cur_rst (.I0(rst_n), .O(cur_rst_high));
	wire rst_high = cur_rst_high;

	(* keep = "true" *) wire pipe_clr_rst_lo, pipe_clr_rst_hi;
	LUT3 #(.INIT(8'hFE)) u_buf_pclr_l (.I0(cur_rst_high), .I1(frame_start), .I2(!enable), .O(pipe_clr_rst_lo));
	LUT3 #(.INIT(8'hFE)) u_buf_pclr_h (.I0(cur_rst_high), .I1(frame_start), .I2(!enable), .O(pipe_clr_rst_hi));
	(* keep = "true" *) wire pipe_clr_rst = pipe_clr_rst_lo;
`else
	wire rst_high = !rst_n;
	(* keep = "true" *) wire pipe_clr_rst = rst_high || frame_start || !enable;
	wire pipe_clr_rst_lo = pipe_clr_rst, pipe_clr_rst_hi = pipe_clr_rst;
`endif
	reg [13:0] req_line_lo;
	reg [AW-1:14] req_line_hi;
	assign req_line = {req_line_hi, req_line_lo};

	(* max_fanout = 16 *) reg [1:0] st;
	reg pend;
	reg [15:0] pend_base_lo, pend_base_hi;
	wire [31:0] pend_base = {pend_base_hi, pend_base_lo};
	reg [15:0] cur_base_lo, cur_base_hi;
	wire [31:0] cur_base = {cur_base_hi, cur_base_lo};
	reg img_ok, load_err;
	reg [NL_W:0] rq_n, wr_n;
	reg [2:0] inflight;
	(* max_fanout = 16 *) reg [WS-1:0] up_w;
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

	/* Clean 4-entry flip-flop line FIFO (replaces distributed RAM am_fifo) */
	reg [LW-1:0] ff_mem [0:3];
	(* max_fanout = 16 *) reg [1:0] ff_wp;
	(* max_fanout = 16 *) reg [1:0] ff_rp;
	reg [2:0] ff_count;
	reg ff_valid;

	wire [1:0] ff_wp_next, ff_rp_next;
	wire [2:0] ff_cnt_inc, ff_cnt_dec;
	wire [3:0] ff_co_unused;

	am_add #(.W(2)) u_ff_wp (.a(ff_wp), .b(2'd0), .ci(1'b1), .s(ff_wp_next), .co(ff_co_unused[0]));
	am_add #(.W(2)) u_ff_rp (.a(ff_rp), .b(2'd0), .ci(1'b1), .s(ff_rp_next), .co(ff_co_unused[1]));
	am_add #(.W(3)) u_ff_inc (.a(ff_count), .b(3'd0), .ci(1'b1), .s(ff_cnt_inc), .co(ff_co_unused[2]));
	am_sub #(.W(3)) u_ff_dec (.a(ff_count), .b(3'd0), .bi(1'b1), .d(ff_cnt_dec), .bo(ff_co_unused[3]));

	wire ff_push = keep;
	wire ff_pop = l_pop;

	localparam NUM_FF_SLICES = LW / 16;
`ifdef SYNTH_KINTEX7
	localparam NUM_FF_GROUPS = NUM_FF_SLICES;
	wire [NUM_FF_GROUPS-1:0] ff_push_grp;
	wire [1:0] ff_wp_grp [0:NUM_FF_GROUPS-1];
	wire [1:0] ff_rp_grp [0:NUM_FF_GROUPS-1];
	wire [NUM_FF_GROUPS-1:0] ff_err_grp;
	genvar gfg;
	generate
		for (gfg = 0; gfg < NUM_FF_GROUPS; gfg = gfg + 1) begin : g_ff_buf
			LUT1 #(.INIT(2'b10)) u_buf_push (.I0(ff_push), .O(ff_push_grp[gfg]));
			LUT1 #(.INIT(2'b10)) u_buf_wp0 (.I0(ff_wp[0]), .O(ff_wp_grp[gfg][0]));
			LUT1 #(.INIT(2'b10)) u_buf_wp1 (.I0(ff_wp[1]), .O(ff_wp_grp[gfg][1]));
			LUT1 #(.INIT(2'b10)) u_buf_rp0 (.I0(ff_rp[0]), .O(ff_rp_grp[gfg][0]));
			LUT1 #(.INIT(2'b10)) u_buf_rp1 (.I0(ff_rp[1]), .O(ff_rp_grp[gfg][1]));
			LUT1 #(.INIT(2'b10)) u_buf_err (.I0(rsp_error), .O(ff_err_grp[gfg]));
		end
	endgenerate
`endif

	genvar gff;
	generate
	for (gff = 0; gff < NUM_FF_SLICES; gff = gff + 1) begin : g_ff_slice
`ifdef SYNTH_KINTEX7
		reg [15:0] ff_mem0, ff_mem1, ff_mem2, ff_mem3;
		always @(posedge clk) begin
			if (ff_push_grp[gff] && ff_wp_grp[gff] == 2'd0)
				ff_mem0 <= ff_err_grp[gff] ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (ff_push_grp[gff] && ff_wp_grp[gff] == 2'd1)
				ff_mem1 <= ff_err_grp[gff] ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (ff_push_grp[gff] && ff_wp_grp[gff] == 2'd2)
				ff_mem2 <= ff_err_grp[gff] ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (ff_push_grp[gff] && ff_wp_grp[gff] == 2'd3)
				ff_mem3 <= ff_err_grp[gff] ? 16'd0 : rsp_rdata[gff*16 +: 16];
		end
		assign l_data[gff*16 +: 16] =
			(ff_rp_grp[gff] == 2'd0) ? ff_mem0 :
			(ff_rp_grp[gff] == 2'd1) ? ff_mem1 :
			(ff_rp_grp[gff] == 2'd2) ? ff_mem2 : ff_mem3;
`else
		(* max_fanout = 16 *) wire slice_push = ff_push;
		(* max_fanout = 16 *) wire [1:0] slice_wp = ff_wp;
		(* max_fanout = 16 *) wire slice_err = rsp_error;
		always @(posedge clk) begin
			if (slice_push && slice_wp == 2'd0) ff_mem[0][gff*16 +: 16] <= slice_err ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (slice_push && slice_wp == 2'd1) ff_mem[1][gff*16 +: 16] <= slice_err ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (slice_push && slice_wp == 2'd2) ff_mem[2][gff*16 +: 16] <= slice_err ? 16'd0 : rsp_rdata[gff*16 +: 16];
			if (slice_push && slice_wp == 2'd3) ff_mem[3][gff*16 +: 16] <= slice_err ? 16'd0 : rsp_rdata[gff*16 +: 16];
		end
`endif
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_high || st != S_LOAD || stop) begin
			ff_wp <= 2'd0;
			ff_rp <= 2'd0;
			ff_count <= 3'd0;
			ff_valid <= 1'b0;
		end else begin
			if (ff_push)
				ff_wp <= ff_wp_next;
			if (ff_pop)
				ff_rp <= ff_rp_next;

			case ({ff_push, ff_pop})
			2'b10: begin
				ff_count <= ff_cnt_inc;
				ff_valid <= 1'b1;
			end
			2'b01: begin
				ff_count <= ff_cnt_dec;
				ff_valid <= (ff_count != 3'd1);
			end
			default: ;
			endcase
		end
	end

	assign l_valid = ff_valid;
	assign l_in_ready = (ff_count < 3'd4);
`ifndef SYNTH_KINTEX7
	assign l_data = ff_mem[ff_rp];
`endif
	assign lcount = ff_count;

	/* The image: 64 rows of 64 words (RAMB36E1 inferable) */
	(* ram_style = "block" *) reg [31:0] mem [0:4095];
	wire mem_we = st == S_LOAD && l_valid && !stop;

	always @(posedge clk)
		if (mem_we)
			mem[{wr_n[NL_W-1:0], up_w}] <= l_data[32*up_w +: 32];

	/* Base address and request line registers */
	wire pend_base_en = flip_valid && !stop;
	wire pend_base_en_lo, pend_base_en_hi;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_buf_pbe_l (.I0(pend_base_en), .O(pend_base_en_lo));
	LUT1 #(.INIT(2'b10)) u_buf_pbe_h (.I0(pend_base_en), .O(pend_base_en_hi));
`else
	assign pend_base_en_lo = pend_base_en;
	assign pend_base_en_hi = pend_base_en;
`endif

	always @(posedge clk) begin
		if (rst_high)
			pend_base_lo <= 16'd0;
		else if (pend_base_en_lo)
			pend_base_lo <= flip_base[15:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			pend_base_hi <= 16'd0;
		else if (pend_base_en_hi)
			pend_base_hi <= flip_base[31:16];
	end

	wire cur_base_en = (st == S_READY) && !stop && frame_start;
	wire cur_base_en_lo, cur_base_en_hi;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_buf_cbe_l (.I0(cur_base_en), .O(cur_base_en_lo));
	LUT1 #(.INIT(2'b10)) u_buf_cbe_h (.I0(cur_base_en), .O(cur_base_en_hi));
`else
	assign cur_base_en_lo = cur_base_en;
	assign cur_base_en_hi = cur_base_en;
`endif

	always @(posedge clk) begin
		if (rst_high)
			cur_base_lo <= 16'd0;
		else if (cur_base_en_lo)
			cur_base_lo <= pend_base_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			cur_base_hi <= 16'd0;
		else if (cur_base_en_hi)
			cur_base_hi <= pend_base_hi;
	end

	wire req_line_en = (st == S_LOAD) && !stop && (!req_valid && rq_n != NLINES && used < 3'd4);
	wire req_line_en_lo, req_line_en_hi;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_buf_rle_l (.I0(req_line_en), .O(req_line_en_lo));
	LUT1 #(.INIT(2'b10)) u_buf_rle_h (.I0(req_line_en), .O(req_line_en_hi));
`else
	assign req_line_en_lo = req_line_en;
	assign req_line_en_hi = req_line_en;
`endif

	always @(posedge clk) begin
		if (rst_high)
			req_line_lo <= 14'd0;
		else if (req_line_en_lo)
			req_line_lo <= rq_line[13:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			req_line_hi <= {(AW-14){1'b0}};
		else if (req_line_en_hi)
			req_line_hi <= rq_line[AW-1:14];
	end

	always @(posedge clk) begin
		taken <= 1'b0;
		taken_cancel <= 1'b0;
		err <= 1'b0;
		if (rst_high) begin
			st <= S_IDLE;
			pend <= 1'b0;
			img_ok <= 1'b0;
			load_err <= 1'b0;
			rq_n <= {(NL_W + 1){1'b0}};
			wr_n <= {(NL_W + 1){1'b0}};
			inflight <= 3'd0;
			up_w <= {WS{1'b0}};
			req_valid <= 1'b0;
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
						rq_n <= rq_inc;
					end
					if (mem_we) begin
						up_w <= up_inc;
						if (up_w == WLAST) begin
							wr_n <= wr_inc;
							if (wr_n == NLINES_M1)
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
					img_ok <= !load_err;
					taken <= 1'b1;
				end
			default:	/* S_DRAIN */
				if (idle)
					st <= S_IDLE;
			endcase
		end
	end

	/*
	 * Pipelined Blend Pipeline:
	 * Stage 0a: Coordinate calculation and RAM address register (Rule 4 address)
	 * Stage 0b: BRAM synchronous read (0 logic levels to RAM address)
	 * Stage 0c: Clean BRAM output register (0 logic levels from RAM DO)
	 * Stage 1:  Multiplier (am_mul LAT=1)
	 * Stage 1b: DSP output register (Rule 1: 0 LUTs after DSP)
	 * Stage 2a: Add a_t (Rule 1 Adder <= 1 LUT)
	 * Stage 2b: Add a_u and a_s (Rule 1 Adder <= 1 LUT)
	 * Stage 3a: Narrow s_vm (Rule 1 Sub <= 1 LUT)
	 * Stage 3b: Narrow a_nt (Rule 1 Add <= 1 LUT)
	 * Stage 3c: Narrow a_nu (Rule 1 Add <= 1 LUT)
	 * Output:   Mux & register to o_data
	 */
	(* max_fanout = 16 *) wire pipe_en;
	wire skid_in_ready;
	assign pipe_en = skid_in_ready;
	assign i_ready = pipe_en;

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire skid_rst_n_0, skid_rst_n_1, skid_rst_n_2, skid_rst_n_3;
	LUT1 #(.INIT(2'b10)) u_skrst_0 (.I0(rst_n), .O(skid_rst_n_0));
	LUT1 #(.INIT(2'b10)) u_skrst_1 (.I0(rst_n), .O(skid_rst_n_1));
	LUT1 #(.INIT(2'b10)) u_skrst_2 (.I0(rst_n), .O(skid_rst_n_2));
	LUT1 #(.INIT(2'b10)) u_skrst_3 (.I0(rst_n), .O(skid_rst_n_3));
`else
	wire skid_rst_n_0 = rst_n, skid_rst_n_1 = rst_n, skid_rst_n_2 = rst_n, skid_rst_n_3 = rst_n;
`endif

	wire skid_lo_ready;
	assign skid_in_ready = skid_lo_ready;
	wire unused_sk1_rdy, unused_sk2_rdy, unused_sk3_rdy;
	wire unused_sk1_vld, unused_sk2_vld, unused_sk3_vld;

	reg st_out_valid_lo, st_out_valid_hi;
	reg [15:0] st_out_data_lo, st_out_data_hi;

	am_skid #(.WIDTH(8)) u_out_skid_0 (
		.clk(clk),
		.rst_n(skid_rst_n_0),
		.in_valid(st_out_valid_lo),
		.in_ready(skid_lo_ready),
		.in_data(st_out_data_lo[7:0]),
		.out_valid(o_valid),
		.out_ready(o_ready),
		.out_data(o_data[7:0])
	);

	am_skid #(.WIDTH(8)) u_out_skid_1 (
		.clk(clk),
		.rst_n(skid_rst_n_1),
		.in_valid(st_out_valid_lo),
		.in_ready(unused_sk1_rdy),
		.in_data(st_out_data_lo[15:8]),
		.out_valid(unused_sk1_vld),
		.out_ready(o_ready),
		.out_data(o_data[15:8])
	);

	am_skid #(.WIDTH(8)) u_out_skid_2 (
		.clk(clk),
		.rst_n(skid_rst_n_2),
		.in_valid(st_out_valid_hi),
		.in_ready(unused_sk2_rdy),
		.in_data(st_out_data_hi[7:0]),
		.out_valid(unused_sk2_vld),
		.out_ready(o_ready),
		.out_data(o_data[23:16])
	);

	am_skid #(.WIDTH(8)) u_out_skid_3 (
		.clk(clk),
		.rst_n(skid_rst_n_3),
		.in_valid(st_out_valid_hi),
		.in_ready(unused_sk3_rdy),
		.in_data(st_out_data_hi[15:8]),
		.out_valid(unused_sk3_vld),
		.out_ready(o_ready),
		.out_data(o_data[31:24])
	);

	/* Pipeline enable buffer tree */
`ifdef SYNTH_KINTEX7
	wire pe_b0, pe_b1, pe_b2, pe_b3, pe_b4, pe_b5;
	LUT1 #(.INIT(2'b10)) u_pe_b0 (.I0(pipe_en), .O(pe_b0));
	LUT1 #(.INIT(2'b10)) u_pe_b1 (.I0(pipe_en), .O(pe_b1));
	LUT1 #(.INIT(2'b10)) u_pe_b2 (.I0(pipe_en), .O(pe_b2));
	LUT1 #(.INIT(2'b10)) u_pe_b3 (.I0(pipe_en), .O(pe_b3));
	LUT1 #(.INIT(2'b10)) u_pe_b4 (.I0(pipe_en), .O(pe_b4));
	LUT1 #(.INIT(2'b10)) u_pe_b5 (.I0(pipe_en), .O(pe_b5));

	wire pe_s0a_pxl, pe_s0a_pxh, pe_s0a_ctl;
	wire pe_s0b_pxl, pe_s0b_pxh, pe_s0b_ctl;
	wire pe_s0c_pxl, pe_s0c_pxh, pe_s0c_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s0a_l (.I0(pe_b0), .O(pe_s0a_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s0a_h (.I0(pe_b0), .O(pe_s0a_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s0a_c (.I0(pe_b0), .O(pe_s0a_ctl));
	LUT1 #(.INIT(2'b10)) u_pe_s0b_l (.I0(pe_b0), .O(pe_s0b_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s0b_h (.I0(pe_b0), .O(pe_s0b_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s0b_c (.I0(pe_b0), .O(pe_s0b_ctl));
	LUT1 #(.INIT(2'b10)) u_pe_s0c_l (.I0(pe_b0), .O(pe_s0c_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s0c_h (.I0(pe_b0), .O(pe_s0c_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s0c_c (.I0(pe_b0), .O(pe_s0c_ctl));

	wire pe_s1_pxl, pe_s1_pxh, pe_s1_c, pe_s1_ctl;
	wire pe_s1b_pxl, pe_s1b_pxh, pe_s1b_pa0, pe_s1b_pa1, pe_s1b_pa2, pe_s1b_c, pe_s1b_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s1_l (.I0(pe_b1), .O(pe_s1_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s1_h (.I0(pe_b1), .O(pe_s1_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s1_c (.I0(pe_b1), .O(pe_s1_c));
	LUT1 #(.INIT(2'b10)) u_pe_s1_ct (.I0(pe_b1), .O(pe_s1_ctl));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_l (.I0(pe_b1), .O(pe_s1b_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_h (.I0(pe_b1), .O(pe_s1b_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_p0 (.I0(pe_b1), .O(pe_s1b_pa0));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_p1 (.I0(pe_b1), .O(pe_s1b_pa1));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_p2 (.I0(pe_b1), .O(pe_s1b_pa2));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_c (.I0(pe_b1), .O(pe_s1b_c));
	LUT1 #(.INIT(2'b10)) u_pe_s1b_ct (.I0(pe_b1), .O(pe_s1b_ctl));

	wire pe_s2a_pxl, pe_s2a_pxh, pe_s2a_t0, pe_s2a_t1, pe_s2a_t2, pe_s2a_c, pe_s2a_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s2a_l (.I0(pe_b2), .O(pe_s2a_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_h (.I0(pe_b2), .O(pe_s2a_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_t0 (.I0(pe_b2), .O(pe_s2a_t0));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_t1 (.I0(pe_b2), .O(pe_s2a_t1));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_t2 (.I0(pe_b2), .O(pe_s2a_t2));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_c (.I0(pe_b2), .O(pe_s2a_c));
	LUT1 #(.INIT(2'b10)) u_pe_s2a_ct (.I0(pe_b2), .O(pe_s2a_ctl));

	wire pe_s2b_pxl, pe_s2b_pxh, pe_s2b_u0, pe_s2b_u1, pe_s2b_u2, pe_s2b_c, pe_s2b_ctl;
	wire pe_s2c_pxl, pe_s2c_pxh, pe_s2c_v, pe_s2c_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s2b_l (.I0(pe_b3), .O(pe_s2b_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_h (.I0(pe_b3), .O(pe_s2b_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_u0 (.I0(pe_b3), .O(pe_s2b_u0));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_u1 (.I0(pe_b3), .O(pe_s2b_u1));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_u2 (.I0(pe_b3), .O(pe_s2b_u2));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_c (.I0(pe_b3), .O(pe_s2b_c));
	LUT1 #(.INIT(2'b10)) u_pe_s2b_ct (.I0(pe_b3), .O(pe_s2b_ctl));
	LUT1 #(.INIT(2'b10)) u_pe_s2c_l (.I0(pe_b3), .O(pe_s2c_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s2c_h (.I0(pe_b3), .O(pe_s2c_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s2c_v (.I0(pe_b3), .O(pe_s2c_v));
	LUT1 #(.INIT(2'b10)) u_pe_s2c_ct (.I0(pe_b3), .O(pe_s2c_ctl));

	wire pe_s3a_pxl, pe_s3a_pxh, pe_s3a_vm0, pe_s3a_vm1, pe_s3a_vm2, pe_s3a_v, pe_s3a_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s3a_l (.I0(pe_b4), .O(pe_s3a_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_h (.I0(pe_b4), .O(pe_s3a_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_v0 (.I0(pe_b4), .O(pe_s3a_vm0));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_v1 (.I0(pe_b4), .O(pe_s3a_vm1));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_v2 (.I0(pe_b4), .O(pe_s3a_vm2));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_v (.I0(pe_b4), .O(pe_s3a_v));
	LUT1 #(.INIT(2'b10)) u_pe_s3a_ct (.I0(pe_b4), .O(pe_s3a_ctl));

	wire pe_s3b_pxl, pe_s3b_pxh, pe_s3b_nt0, pe_s3b_nt1, pe_s3b_nt2, pe_s3b_v, pe_s3b_ctl;
	wire pe_out_l, pe_out_h, pe_out_ctl;
	LUT1 #(.INIT(2'b10)) u_pe_s3b_l (.I0(pe_b5), .O(pe_s3b_pxl));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_h (.I0(pe_b5), .O(pe_s3b_pxh));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_n0 (.I0(pe_b5), .O(pe_s3b_nt0));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_n1 (.I0(pe_b5), .O(pe_s3b_nt1));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_n2 (.I0(pe_b5), .O(pe_s3b_nt2));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_v (.I0(pe_b5), .O(pe_s3b_v));
	LUT1 #(.INIT(2'b10)) u_pe_s3b_ct (.I0(pe_b5), .O(pe_s3b_ctl));
	LUT1 #(.INIT(2'b10)) u_pe_out_l (.I0(pe_b5), .O(pe_out_l));
	LUT1 #(.INIT(2'b10)) u_pe_out_h (.I0(pe_b5), .O(pe_out_h));
	LUT1 #(.INIT(2'b10)) u_pe_out_ct (.I0(pe_b5), .O(pe_out_ctl));
`else
	wire pe_s0a_pxl = pipe_en;
	wire pe_s0a_pxh = pipe_en;
	wire pe_s0a_ctl = pipe_en;
	wire pe_s0b_pxl = pipe_en;
	wire pe_s0b_pxh = pipe_en;
	wire pe_s0b_ctl = pipe_en;
	wire pe_s0c_pxl = pipe_en;
	wire pe_s0c_pxh = pipe_en;
	wire pe_s0c_ctl = pipe_en;
	wire pe_s1_pxl = pipe_en;
	wire pe_s1_pxh = pipe_en;
	wire pe_s1_c = pipe_en;
	wire pe_s1_ctl = pipe_en;
	wire pe_s1b_pxl = pipe_en;
	wire pe_s1b_pxh = pipe_en;
	wire pe_s1b_pa0 = pipe_en;
	wire pe_s1b_pa1 = pipe_en;
	wire pe_s1b_pa2 = pipe_en;
	wire pe_s1b_c = pipe_en;
	wire pe_s1b_ctl = pipe_en;
	wire pe_s2a_pxl = pipe_en;
	wire pe_s2a_pxh = pipe_en;
	wire pe_s2a_t0 = pipe_en;
	wire pe_s2a_t1 = pipe_en;
	wire pe_s2a_t2 = pipe_en;
	wire pe_s2a_c = pipe_en;
	wire pe_s2a_ctl = pipe_en;
	wire pe_s2b_pxl = pipe_en;
	wire pe_s2b_pxh = pipe_en;
	wire pe_s2b_u0 = pipe_en;
	wire pe_s2b_u1 = pipe_en;
	wire pe_s2b_u2 = pipe_en;
	wire pe_s2b_c = pipe_en;
	wire pe_s2b_ctl = pipe_en;
	wire pe_s2c_pxl = pipe_en;
	wire pe_s2c_pxh = pipe_en;
	wire pe_s2c_v = pipe_en;
	wire pe_s2c_ctl = pipe_en;
	wire pe_s3a_pxl = pipe_en;
	wire pe_s3a_pxh = pipe_en;
	wire pe_s3a_vm0 = pipe_en;
	wire pe_s3a_vm1 = pipe_en;
	wire pe_s3a_vm2 = pipe_en;
	wire pe_s3a_v = pipe_en;
	wire pe_s3a_ctl = pipe_en;
	wire pe_s3b_pxl = pipe_en;
	wire pe_s3b_pxh = pipe_en;
	wire pe_s3b_nt0 = pipe_en;
	wire pe_s3b_nt1 = pipe_en;
	wire pe_s3b_nt2 = pipe_en;
	wire pe_s3b_v = pipe_en;
	wire pe_s3b_ctl = pipe_en;
	wire pe_out_l = pipe_en;
	wire pe_out_h = pipe_en;
	wire pe_out_ctl = pipe_en;
`endif

	/* Screen coordinate tracking */
	(* extract_reset = "no" *) reg [15:0] x, y;
	reg [15:0] pos_x, pos_y;
	reg vis;

	wire [16:0] dx, dy;
	wire [15:0] x_inc, y_inc, x_last_w;
	reg [15:0] x_last;
	wire [4:0] bl_co_unused;

	am_sub #(.W(17)) s_dx (.a({1'b0, x}), .b({pos_x[15], pos_x}), .bi(1'b0), .d(dx), .bo(bl_co_unused[0]));
	am_sub #(.W(17)) s_dy (.a({1'b0, y}), .b({pos_y[15], pos_y}), .bi(1'b0), .d(dy), .bo(bl_co_unused[1]));
	am_add #(.W(16)) a_x (.a(x), .b(16'd0), .ci(1'b1), .s(x_inc), .co(bl_co_unused[2]));
	am_add #(.W(16)) a_y (.a(y), .b(16'd0), .ci(1'b1), .s(y_inc), .co(bl_co_unused[3]));
	am_sub #(.W(16)) s_w (.a(fb_width), .b(16'd1), .bi(1'b0), .d(x_last_w), .bo(bl_co_unused[4]));
	always @(posedge clk)
		x_last <= x_last_w;
	reg cur_gate;
	always @(posedge clk)
		cur_gate <= vis && img_ok && (st == S_IDLE);
	wire dx_in = (dx[16:6] == 11'd0);
	wire dy_in = (dy[16:6] == 11'd0);

	wire eq0 = (x[2:0]   == x_last[2:0]);
	wire eq1 = (x[5:3]   == x_last[5:3]);
	wire eq2 = (x[8:6]   == x_last[8:6]);
	wire eq3 = (x[11:9]  == x_last[11:9]);
	wire eq4 = (x[14:12] == x_last[14:12]);
	wire eq5 = (x[15]    == x_last[15]);
	wire x_is_eol = eq0 && eq1 && eq2 && eq3 && eq4 && eq5;

	/* Stage 0a: Register RAM read address (Rule 4: clean address) */
	reg st0a_valid;
	reg s0a_dx_in, s0a_dy_in, s0a_cur_gate;
	(* max_fanout = 16 *) reg [1:0] s0a_fmt;
	reg [15:0] s0a_px_lo, s0a_px_hi;
	reg [11:0] s0a_addr;

	always @(posedge clk) begin
		if (rst_high)
			vis <= 1'b0;
		else if (frame_start || !enable)
			vis <= show;
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo)
			pos_x <= pos[15:0];
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo)
			pos_y <= pos[31:16];
	end

	wire pe_s0a_valid = pe_s0a_ctl && i_valid;
`ifdef SYNTH_KINTEX7
	wire pe_s0a_v_addr, pe_s0a_v_x, pe_s0a_v_y, pe_s0a_v_ctl;
	LUT1 #(.INIT(2'b10)) u_buf_s0a_a (.I0(pe_s0a_valid), .O(pe_s0a_v_addr));
	LUT1 #(.INIT(2'b10)) u_buf_s0a_x (.I0(pe_s0a_valid), .O(pe_s0a_v_x));
	LUT1 #(.INIT(2'b10)) u_buf_s0a_y (.I0(pe_s0a_valid), .O(pe_s0a_v_y));
	LUT1 #(.INIT(2'b10)) u_buf_s0a_c (.I0(pe_s0a_valid), .O(pe_s0a_v_ctl));

	wire x_is_eol_x, x_is_eol_y;
	LUT1 #(.INIT(2'b10)) u_buf_eol_x (.I0(x_is_eol), .O(x_is_eol_x));
	LUT1 #(.INIT(2'b10)) u_buf_eol_y (.I0(x_is_eol), .O(x_is_eol_y));
`else
	wire pe_s0a_v_addr = pe_s0a_valid;
	wire pe_s0a_v_x = pe_s0a_valid;
	wire pe_s0a_v_y = pe_s0a_valid;
	wire pe_s0a_v_ctl = pe_s0a_valid;
	wire x_is_eol_x = x_is_eol;
	wire x_is_eol_y = x_is_eol;
`endif

	always @(posedge clk) begin
		if (pipe_clr_rst_lo)
			x <= 16'd0;
		else if (pe_s0a_v_x)
			x <= x_is_eol_x ? 16'd0 : x_inc;
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo)
			y <= 16'd0;
		else if (pe_s0a_v_y && x_is_eol_y)
			y <= y_inc;
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo)
			st0a_valid <= 1'b0;
		else if (pe_s0a_ctl)
			st0a_valid <= i_valid;
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			s0a_dx_in <= 1'b0;
			s0a_dy_in <= 1'b0;
			s0a_cur_gate <= 1'b0;
			s0a_fmt <= 2'd0;
		end else if (pe_s0a_v_ctl) begin
			s0a_dx_in <= dx_in;
			s0a_dy_in <= dy_in;
			s0a_cur_gate <= cur_gate;
			s0a_fmt <= format;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			s0a_addr <= 12'd0;
		else if (pe_s0a_v_addr)
			s0a_addr <= {dy[5:0], dx[5:0]};
	end

	always @(posedge clk) begin
		if (rst_high)
			s0a_px_lo <= 16'd0;
		else if (pe_s0a_pxl && i_valid)
			s0a_px_lo <= i_data[15:0];
	end

	always @(posedge clk) begin
		if (rst_high)
			s0a_px_hi <= 16'd0;
		else if (pe_s0a_pxh && i_valid)
			s0a_px_hi <= i_data[31:16];
	end

	/* Stage 0b: BRAM Synchronous Read (address is pure register s0a_addr) */
	reg [31:0] mem_q;
	reg st0b_valid, s0b_in;
	(* max_fanout = 16 *) reg [1:0] s0b_fmt;
	reg [15:0] s0b_px_lo, s0b_px_hi;

	always @(posedge clk) begin
		if (pipe_en)
			mem_q <= mem[s0a_addr];
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st0b_valid <= 1'b0;
			s0b_in <= 1'b0;
			s0b_fmt <= 2'd0;
		end else if (pe_s0b_ctl) begin
			st0b_valid <= st0a_valid;
			s0b_in <= s0a_dx_in && s0a_dy_in && s0a_cur_gate;
			s0b_fmt <= s0a_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			s0b_px_lo <= 16'd0;
		else if (pe_s0b_pxl)
			s0b_px_lo <= s0a_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			s0b_px_hi <= 16'd0;
		else if (pe_s0b_pxh)
			s0b_px_hi <= s0a_px_hi;
	end

	/* Stage 0c: Clean BRAM output register (0 logic levels from mem_q) */
	(* keep = "true" *) reg [31:0] q_direct;
	reg st0c_valid, s0c_in;
	(* keep = "true" *) reg [1:0] s0c_fmt_p, s0c_fmt_c, s0c_fmt_st1;
	reg [15:0] s0c_px_lo, s0c_px_hi;

	always @(posedge clk) begin
		if (pipe_en)
			q_direct <= mem_q;
	end

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st0c_valid <= 1'b0;
			s0c_in <= 1'b0;
			s0c_fmt_p <= 2'd0;
			s0c_fmt_c <= 2'd0;
			s0c_fmt_st1 <= 2'd0;
		end else if (pe_s0c_ctl) begin
			st0c_valid <= st0b_valid;
			s0c_in <= s0b_in;
			s0c_fmt_p <= s0b_fmt;
			s0c_fmt_c <= s0b_fmt;
			s0c_fmt_st1 <= s0b_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			s0c_px_lo <= 16'd0;
		else if (pe_s0c_pxl)
			s0c_px_lo <= s0b_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			s0c_px_hi <= 16'd0;
		else if (pe_s0c_pxh)
			s0c_px_hi <= s0b_px_hi;
	end

	/* Stage 1: Mul (am_mul LAT=1) */
	wire [7:0] cb = q_direct[7:0], cg = q_direct[15:8], cr = q_direct[23:16], ca = q_direct[31:24];
	wire [7:0] r8 = {s0c_px_lo[15:11], s0c_px_lo[15:13]};
	wire [7:0] g8 = {s0c_px_lo[10:5], s0c_px_lo[10:9]};
	wire [7:0] b8 = {s0c_px_lo[4:0], s0c_px_lo[4:2]};

	wire [23:0] mix_c = (s0c_fmt_c == 2'd1) ? {cb, cg, cr} : {cr, cg, cb};
	wire [23:0] mix_p = (s0c_fmt_p == 2'd2) ? {r8, g8, b8} : {s0c_px_hi[7:0], s0c_px_lo};

	reg st1_valid, st1_in;
	reg [7:0] st1_c0, st1_c1, st1_c2;
	reg [15:0] st1_px_lo, st1_px_hi;
	(* max_fanout = 16 *) reg [1:0] st1_fmt;

`ifdef SYNTH_KINTEX7
	localparam CURSOR_MUL_LAT = 2;
	wire [7:0] not_ca_0, not_ca_1, not_ca_2;
	genvar gca;
	generate
		for (gca = 0; gca < 8; gca = gca + 1) begin : g_ca_buf
			LUT1 #(.INIT(2'b01)) u_buf0 (.I0(ca[gca]), .O(not_ca_0[gca]));
			LUT1 #(.INIT(2'b01)) u_buf1 (.I0(ca[gca]), .O(not_ca_1[gca]));
			LUT1 #(.INIT(2'b01)) u_buf2 (.I0(ca[gca]), .O(not_ca_2[gca]));
		end
	endgenerate
	wire [7:0] not_ca_arr [0:2];
	assign not_ca_arr[0] = not_ca_0;
	assign not_ca_arr[1] = not_ca_1;
	assign not_ca_arr[2] = not_ca_2;
`else
	localparam CURSOR_MUL_LAT = 1;
	wire [7:0] not_ca_arr [0:2];
	assign not_ca_arr[0] = ~ca;
	assign not_ca_arr[1] = ~ca;
	assign not_ca_arr[2] = ~ca;
`endif

	wire [15:0] st1_pa [0:2];
	genvar k;
	generate
	for (k = 0; k < 3; k = k + 1) begin : g_mul
		wire [7:0] p = mix_p[8*(2-k) +: 8];
		am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(CURSOR_MUL_LAT)) m_pa (
			.clk(clk), .en(pipe_en), .a(p), .b(not_ca_arr[k]), .p(st1_pa[k])
		);
	end
	endgenerate

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st1_valid <= 1'b0;
			st1_in <= 1'b0;
			st1_fmt <= 2'd0;
		end else if (pe_s1_ctl) begin
			st1_valid <= st0c_valid;
			st1_in <= s0c_in;
			st1_fmt <= s0c_fmt_st1;
		end
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st1_c0 <= 8'd0;
			st1_c1 <= 8'd0;
			st1_c2 <= 8'd0;
		end else if (pe_s1_c) begin
			st1_c0 <= mix_c[7:0];
			st1_c1 <= mix_c[15:8];
			st1_c2 <= mix_c[23:16];
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st1_px_lo <= 16'd0;
		else if (pe_s1_pxl)
			st1_px_lo <= s0c_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st1_px_hi <= 16'd0;
		else if (pe_s1_pxh)
			st1_px_hi <= s0c_px_hi;
	end

	/* Stage 1b: Register DSP outputs (Rule 1: Post-DSP LUTs <= 1) */
	reg [15:0] st1b_pa0, st1b_pa1, st1b_pa2;
	reg [7:0] st1b_c0, st1b_c1, st1b_c2;
	reg [15:0] st1b_px_lo, st1b_px_hi;
	reg st1b_valid, st1b_in;
	reg [1:0] st1b_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st1b_valid <= 1'b0;
			st1b_in <= 1'b0;
			st1b_fmt <= 2'd0;
		end else if (pe_s1b_ctl) begin
			st1b_valid <= st1_valid;
			st1b_in <= st1_in;
			st1b_fmt <= st1_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st1b_pa0 <= 16'd0;
		else if (pe_s1b_pa0)
			st1b_pa0 <= st1_pa[0];
	end

	always @(posedge clk) begin
		if (rst_high)
			st1b_pa1 <= 16'd0;
		else if (pe_s1b_pa1)
			st1b_pa1 <= st1_pa[1];
	end

	always @(posedge clk) begin
		if (rst_high)
			st1b_pa2 <= 16'd0;
		else if (pe_s1b_pa2)
			st1b_pa2 <= st1_pa[2];
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st1b_c0 <= 8'd0;
			st1b_c1 <= 8'd0;
			st1b_c2 <= 8'd0;
		end else if (pe_s1b_c) begin
			st1b_c0 <= st1_c0;
			st1b_c1 <= st1_c1;
			st1b_c2 <= st1_c2;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st1b_px_lo <= 16'd0;
		else if (pe_s1b_pxl)
			st1b_px_lo <= st1_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st1b_px_hi <= 16'd0;
		else if (pe_s1b_pxh)
			st1b_px_hi <= st1_px_hi;
	end

	/* Stage 2a: Add a_t (t = pa + 128) */
	wire [15:0] st2a_t_wire [0:2];
	wire [2:0] t_co_unused;
	am_add #(.W(16)) a_t0 (.a(st1b_pa0), .b(16'd128), .ci(1'b0), .s(st2a_t_wire[0]), .co(t_co_unused[0]));
	am_add #(.W(16)) a_t1 (.a(st1b_pa1), .b(16'd128), .ci(1'b0), .s(st2a_t_wire[1]), .co(t_co_unused[1]));
	am_add #(.W(16)) a_t2 (.a(st1b_pa2), .b(16'd128), .ci(1'b0), .s(st2a_t_wire[2]), .co(t_co_unused[2]));

	reg [15:0] st2a_t0, st2a_t1, st2a_t2;
	reg [7:0] st2a_c0, st2a_c1, st2a_c2;
	reg [15:0] st2a_px_lo, st2a_px_hi;
	reg st2a_valid, st2a_in;
	reg [1:0] st2a_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st2a_valid <= 1'b0;
			st2a_in <= 1'b0;
			st2a_fmt <= 2'd0;
		end else if (pe_s2a_ctl) begin
			st2a_valid <= st1b_valid;
			st2a_in <= st1b_in;
			st2a_fmt <= st1b_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st2a_t0 <= 16'd0;
		else if (pe_s2a_t0)
			st2a_t0 <= st2a_t_wire[0];
	end

	always @(posedge clk) begin
		if (rst_high)
			st2a_t1 <= 16'd0;
		else if (pe_s2a_t1)
			st2a_t1 <= st2a_t_wire[1];
	end

	always @(posedge clk) begin
		if (rst_high)
			st2a_t2 <= 16'd0;
		else if (pe_s2a_t2)
			st2a_t2 <= st2a_t_wire[2];
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st2a_c0 <= 8'd0;
			st2a_c1 <= 8'd0;
			st2a_c2 <= 8'd0;
		end else if (pe_s2a_c) begin
			st2a_c0 <= st1b_c0;
			st2a_c1 <= st1b_c1;
			st2a_c2 <= st1b_c2;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st2a_px_lo <= 16'd0;
		else if (pe_s2a_pxl)
			st2a_px_lo <= st1b_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st2a_px_hi <= 16'd0;
		else if (pe_s2a_pxh)
			st2a_px_hi <= st1b_px_hi;
	end

	/* Stage 2b: Add a_u (u = t + (t >> 8)) */
	wire [15:0] st2b_u_wire [0:2];
	wire [2:0] u_co_unused;
	am_add #(.W(16)) a_u0 (.a(st2a_t0), .b({8'd0, st2a_t0[15:8]}), .ci(1'b0), .s(st2b_u_wire[0]), .co(u_co_unused[0]));
	am_add #(.W(16)) a_u1 (.a(st2a_t1), .b({8'd0, st2a_t1[15:8]}), .ci(1'b0), .s(st2b_u_wire[1]), .co(u_co_unused[1]));
	am_add #(.W(16)) a_u2 (.a(st2a_t2), .b({8'd0, st2a_t2[15:8]}), .ci(1'b0), .s(st2b_u_wire[2]), .co(u_co_unused[2]));

	reg [15:0] st2b_u0, st2b_u1, st2b_u2;
	reg [7:0] st2b_c0, st2b_c1, st2b_c2;
	reg [15:0] st2b_px_lo, st2b_px_hi;
	reg st2b_valid, st2b_in;
	reg [1:0] st2b_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_lo) begin
			st2b_valid <= 1'b0;
			st2b_in <= 1'b0;
			st2b_fmt <= 2'd0;
		end else if (pe_s2b_ctl) begin
			st2b_valid <= st2a_valid;
			st2b_in <= st2a_in;
			st2b_fmt <= st2a_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st2b_u0 <= 16'd0;
		else if (pe_s2b_u0)
			st2b_u0 <= st2b_u_wire[0];
	end

	always @(posedge clk) begin
		if (rst_high)
			st2b_u1 <= 16'd0;
		else if (pe_s2b_u1)
			st2b_u1 <= st2b_u_wire[1];
	end

	always @(posedge clk) begin
		if (rst_high)
			st2b_u2 <= 16'd0;
		else if (pe_s2b_u2)
			st2b_u2 <= st2b_u_wire[2];
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st2b_c0 <= 8'd0;
			st2b_c1 <= 8'd0;
			st2b_c2 <= 8'd0;
		end else if (pe_s2b_c) begin
			st2b_c0 <= st2a_c0;
			st2b_c1 <= st2a_c1;
			st2b_c2 <= st2a_c2;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st2b_px_lo <= 16'd0;
		else if (pe_s2b_pxl)
			st2b_px_lo <= st2a_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st2b_px_hi <= 16'd0;
		else if (pe_s2b_pxh)
			st2b_px_hi <= st2a_px_hi;
	end

	/* Stage 2c: Add a_s (sum = c + u[15:8]) */
	wire [8:0] st2c_sum_wire [0:2];
	am_add #(.W(8)) a_s0 (.a(st2b_c2), .b(st2b_u0[15:8]), .ci(1'b0), .s(st2c_sum_wire[0][7:0]), .co(st2c_sum_wire[0][8]));
	am_add #(.W(8)) a_s1 (.a(st2b_c1), .b(st2b_u1[15:8]), .ci(1'b0), .s(st2c_sum_wire[1][7:0]), .co(st2c_sum_wire[1][8]));
	am_add #(.W(8)) a_s2 (.a(st2b_c0), .b(st2b_u2[15:8]), .ci(1'b0), .s(st2c_sum_wire[2][7:0]), .co(st2c_sum_wire[2][8]));

	reg [7:0] st2c_v0, st2c_v1, st2c_v2;
	reg [15:0] st2c_px_lo, st2c_px_hi;
	reg st2c_valid, st2c_in;
	reg [1:0] st2c_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_hi) begin
			st2c_valid <= 1'b0;
			st2c_in <= 1'b0;
			st2c_fmt <= 2'd0;
		end else if (pe_s2c_ctl) begin
			st2c_valid <= st2b_valid;
			st2c_in <= st2b_in;
			st2c_fmt <= st2b_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st2c_v0 <= 8'd0;
			st2c_v1 <= 8'd0;
			st2c_v2 <= 8'd0;
		end else if (pe_s2c_v) begin
			st2c_v0 <= st2c_sum_wire[0][8] ? 8'hFF : st2c_sum_wire[0][7:0];
			st2c_v1 <= st2c_sum_wire[1][8] ? 8'hFF : st2c_sum_wire[1][7:0];
			st2c_v2 <= st2c_sum_wire[2][8] ? 8'hFF : st2c_sum_wire[2][7:0];
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st2c_px_lo <= 16'd0;
		else if (pe_s2c_pxl)
			st2c_px_lo <= st2b_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st2c_px_hi <= 16'd0;
		else if (pe_s2c_pxh)
			st2c_px_hi <= st2b_px_hi;
	end

	/* Stage 3a: Narrow s_vm (vm = v*31 or v*63) */
	wire [15:0] st3a_vm_wire [0:2];
	wire [2:0] vm_bo_unused;
	am_sub #(.W(16)) s_vm0 (.a({3'd0, st2c_v0, 5'd0}), .b({8'd0, st2c_v0}), .bi(1'b0), .d(st3a_vm_wire[0]), .bo(vm_bo_unused[0]));
	am_sub #(.W(16)) s_vm1 (.a({2'd0, st2c_v1, 6'd0}), .b({8'd0, st2c_v1}), .bi(1'b0), .d(st3a_vm_wire[1]), .bo(vm_bo_unused[1]));
	am_sub #(.W(16)) s_vm2 (.a({3'd0, st2c_v2, 5'd0}), .b({8'd0, st2c_v2}), .bi(1'b0), .d(st3a_vm_wire[2]), .bo(vm_bo_unused[2]));

	reg [15:0] st3a_vm0, st3a_vm1, st3a_vm2;
	reg [7:0] st3a_v0, st3a_v1, st3a_v2;
	reg [15:0] st3a_px_lo, st3a_px_hi;
	reg st3a_valid, st3a_in;
	reg [1:0] st3a_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_hi) begin
			st3a_valid <= 1'b0;
			st3a_in <= 1'b0;
			st3a_fmt <= 2'd0;
		end else if (pe_s3a_ctl) begin
			st3a_valid <= st2c_valid;
			st3a_in <= st2c_in;
			st3a_fmt <= st2c_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st3a_vm0 <= 16'd0;
		else if (pe_s3a_vm0)
			st3a_vm0 <= st3a_vm_wire[0];
	end

	always @(posedge clk) begin
		if (rst_high)
			st3a_vm1 <= 16'd0;
		else if (pe_s3a_vm1)
			st3a_vm1 <= st3a_vm_wire[1];
	end

	always @(posedge clk) begin
		if (rst_high)
			st3a_vm2 <= 16'd0;
		else if (pe_s3a_vm2)
			st3a_vm2 <= st3a_vm_wire[2];
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st3a_v0 <= 8'd0;
			st3a_v1 <= 8'd0;
			st3a_v2 <= 8'd0;
		end else if (pe_s3a_v) begin
			st3a_v0 <= st2c_v0;
			st3a_v1 <= st2c_v1;
			st3a_v2 <= st2c_v2;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st3a_px_lo <= 16'd0;
		else if (pe_s3a_pxl)
			st3a_px_lo <= st2c_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st3a_px_hi <= 16'd0;
		else if (pe_s3a_pxh)
			st3a_px_hi <= st2c_px_hi;
	end

	/* Stage 3b: Narrow a_nt (nt = vm + 128) */
	wire [15:0] st3b_nt_wire [0:2];
	wire [2:0] nt_co_unused;
	am_add #(.W(16)) a_nt0 (.a(st3a_vm0), .b(16'd128), .ci(1'b0), .s(st3b_nt_wire[0]), .co(nt_co_unused[0]));
	am_add #(.W(16)) a_nt1 (.a(st3a_vm1), .b(16'd128), .ci(1'b0), .s(st3b_nt_wire[1]), .co(nt_co_unused[1]));
	am_add #(.W(16)) a_nt2 (.a(st3a_vm2), .b(16'd128), .ci(1'b0), .s(st3b_nt_wire[2]), .co(nt_co_unused[2]));

	reg [15:0] st3b_nt0, st3b_nt1, st3b_nt2;
	reg [7:0] st3b_v0, st3b_v1, st3b_v2;
	reg [15:0] st3b_px_lo, st3b_px_hi;
	reg st3b_valid, st3b_in;
	reg [1:0] st3b_fmt;

	always @(posedge clk) begin
		if (pipe_clr_rst_hi) begin
			st3b_valid <= 1'b0;
			st3b_in <= 1'b0;
			st3b_fmt <= 2'd0;
		end else if (pe_s3b_ctl) begin
			st3b_valid <= st3a_valid;
			st3b_in <= st3a_in;
			st3b_fmt <= st3a_fmt;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st3b_nt0 <= 16'd0;
		else if (pe_s3b_nt0)
			st3b_nt0 <= st3b_nt_wire[0];
	end

	always @(posedge clk) begin
		if (rst_high)
			st3b_nt1 <= 16'd0;
		else if (pe_s3b_nt1)
			st3b_nt1 <= st3b_nt_wire[1];
	end

	always @(posedge clk) begin
		if (rst_high)
			st3b_nt2 <= 16'd0;
		else if (pe_s3b_nt2)
			st3b_nt2 <= st3b_nt_wire[2];
	end

	always @(posedge clk) begin
		if (rst_high) begin
			st3b_v0 <= 8'd0;
			st3b_v1 <= 8'd0;
			st3b_v2 <= 8'd0;
		end else if (pe_s3b_v) begin
			st3b_v0 <= st3a_v0;
			st3b_v1 <= st3a_v1;
			st3b_v2 <= st3a_v2;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st3b_px_lo <= 16'd0;
		else if (pe_s3b_pxl)
			st3b_px_lo <= st3a_px_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st3b_px_hi <= 16'd0;
		else if (pe_s3b_pxh)
			st3b_px_hi <= st3a_px_hi;
	end

	/* Stage 3c: Narrow a_nu (nu = nt + (nt >> 8)) */
	wire [15:0] st3c_nu_wire [0:2];
	wire [2:0] nu_co_unused;
	am_add #(.W(16)) a_nu0 (.a(st3b_nt0), .b({8'd0, st3b_nt0[15:8]}), .ci(1'b0), .s(st3c_nu_wire[0]), .co(nu_co_unused[0]));
	am_add #(.W(16)) a_nu1 (.a(st3b_nt1), .b({8'd0, st3b_nt1[15:8]}), .ci(1'b0), .s(st3c_nu_wire[1]), .co(nu_co_unused[1]));
	am_add #(.W(16)) a_nu2 (.a(st3b_nt2), .b({8'd0, st3b_nt2[15:8]}), .ci(1'b0), .s(st3c_nu_wire[2]), .co(nu_co_unused[2]));

	wire [5:0] st3c_r5 = st3c_nu_wire[0][13:8];
	wire [5:0] st3c_g6 = st3c_nu_wire[1][13:8];
	wire [5:0] st3c_b5 = st3c_nu_wire[2][13:8];
	wire [23:0] mixed = {st3b_v0, st3b_v1, st3b_v2};
	reg [15:0] blended_lo, blended_hi;

	wire [1:0] st3b_fmt_lo, st3b_fmt_hi;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_buf_fmt_l0 (.I0(st3b_fmt[0]), .O(st3b_fmt_lo[0]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_l1 (.I0(st3b_fmt[1]), .O(st3b_fmt_lo[1]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_h0 (.I0(st3b_fmt[0]), .O(st3b_fmt_hi[0]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_h1 (.I0(st3b_fmt[1]), .O(st3b_fmt_hi[1]));
`else
	assign st3b_fmt_lo = st3b_fmt;
	assign st3b_fmt_hi = st3b_fmt;
`endif

	always @(*) begin
		case (st3b_fmt_lo)
		2'd2:    blended_lo = {st3c_r5[4:0], st3c_g6, st3c_b5[4:0]};
		default: blended_lo = mixed[15:0];
		endcase
	end

	always @(*) begin
		case (st3b_fmt_hi)
		2'd2:    blended_hi = st3b_px_hi;
		default: blended_hi = {st3b_px_hi[15:8], mixed[23:16]};
		endcase
	end

	wire st3b_in_lo, st3b_in_hi;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_buf_in_l (.I0(st3b_in), .O(st3b_in_lo));
	LUT1 #(.INIT(2'b10)) u_buf_in_h (.I0(st3b_in), .O(st3b_in_hi));
`else
	assign st3b_in_lo = st3b_in;
	assign st3b_in_hi = st3b_in;
`endif

	wire [15:0] nxt_out_data_lo = st3b_in_lo ? blended_lo : st3b_px_lo;
	wire [15:0] nxt_out_data_hi = st3b_in_hi ? blended_hi : st3b_px_hi;

	always @(posedge clk) begin
		if (pipe_clr_rst_hi) begin
			st_out_valid_lo <= 1'b0;
			st_out_valid_hi <= 1'b0;
		end else if (pe_out_ctl) begin
			st_out_valid_lo <= st3b_valid;
			st_out_valid_hi <= st3b_valid;
		end
	end

	always @(posedge clk) begin
		if (rst_high)
			st_out_data_lo <= 16'd0;
		else if (pe_out_l)
			st_out_data_lo <= nxt_out_data_lo;
	end

	always @(posedge clk) begin
		if (rst_high)
			st_out_data_hi <= 16'd0;
		else if (pe_out_h)
			st_out_data_hi <= nxt_out_data_hi;
	end

`ifndef SYNTH_KINTEX7
	/* Testbench identity check wires (probed hierarchically by atg_dc_cursor_tb) */
	reg [31:0] q;
	reg [31:0] s_px;
	wire [7:0] tb_cb = q[7:0], tb_cg = q[15:8], tb_cr = q[23:16], tb_ca = q[31:24];
	wire [7:0] tb_r8 = {s_px[15:11], s_px[15:13]};
	wire [7:0] tb_g8 = {s_px[10:5], s_px[10:9]};
	wire [7:0] tb_b8 = {s_px[4:0], s_px[4:2]};

	wire [23:0] tb_mix_c = (format == 2'd1) ? {tb_cb, tb_cg, tb_cr} : {tb_cr, tb_cg, tb_cb};
	wire [23:0] tb_mix_p = (format == 2'd2) ? {tb_r8, tb_g8, tb_b8} : s_px[23:0];
	wire [5:0] tb_narrowed [0:2];
	wire [2:0] tb_t_unused, tb_u_unused, tb_vm_unused, tb_nt_unused, tb_nu_unused;

	genvar m;
	generate
	for (m = 0; m < 3; m = m + 1) begin : g_tb
		wire [7:0] c = tb_mix_c[8*(2-m) +: 8];
		wire [7:0] p = tb_mix_p[8*(2-m) +: 8];
		wire [15:0] pa, t, u;
		wire [8:0] sum;
		am_mul #(.AW(8), .BW(8), .SIGNED(0), .LAT(0)) m_pa (.clk(clk), .en(1'b1), .a(p), .b(~tb_ca), .p(pa));
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
`endif

	wire unused_ok = &{1'b0, rsp_tag, l_in_ready, st3c_r5[5], st3c_b5[5], flip_base[5:0],
		ld_co_unused, bl_co_unused, t_co_unused, u_co_unused, vm_bo_unused, nt_co_unused,
		nu_co_unused, ff_co_unused
`ifndef SYNTH_KINTEX7
		, r5[5], b5[5], tb_t_unused, tb_u_unused, tb_vm_unused, tb_nt_unused, tb_nu_unused
`endif
	};
endmodule

`default_nettype wire
