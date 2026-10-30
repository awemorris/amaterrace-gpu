/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc: the display controller (DISP2, docs/ghci.md section 13.2), a
 * unit of the GPU in atg_top: registers and DMA in gclk, a pixel FIFO
 * (am_afifo) to the pixel clock, the timing generator, a TMDS encoder and
 * a parallel output, optional I2C; one AMB client port (MC client C_DC).
 * The CP reaches it through atg_cp_disp: the internal register bus (d_*),
 * the flips (flip_*, taken) and the status for the records.
 *
 * Wiring of its children; see spec/gpu/dc/atg_dc.md.  The only clock
 * crossings: the pixel FIFO (am_afifo), ENABLE and CTRL.RESET to pclk, the
 * event toggles and the line to gclk (am_sync).  The timing, format and
 * test pattern are quasi-static and go to pclk directly (atg_dc_regs).
 * rst_n is the board reset; the DC's own CTRL.RESET (dc_reset) resets the
 * gclk side of the FIFO, the I2C master and the event synchronisers, and
 * clears the DMA (whose count of outstanding reads survives it).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc #(
`ifdef SYNTH_KINTEX7
	parameter REG_RDATA = 1,
`else
	parameter REG_RDATA = 0,
`endif
	parameter HAS_I2C = 0,	/* ADV7511 I2C master present (KC705, DC_CAPS[2]) */
	parameter HAS_CURSOR = 1,	/* the cursor plane, plane 1 (DC_CAPS[8], atg_dc_cursor) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter FIFO_LOG2 = 11,	/* Pixel FIFO depth (2048 words, ws001-p038: 13.8 us margin at 1080p@60Hz) */
	parameter PX_FMT = 0,	/* The parallel output: 0 RGB888 (px_rgb = {r, g, b}), 1 YCbCr 4:2:2 16-bit (px_rgb = {8'd0, C, Y}, the KC705's ADV7511, atg_dc_ycc) */
	parameter TEST_MODE = 0	/* 1: a simulation's one small mode instead of the board's two (atg_dc_mode) */
) (
	input wire clk,
	input wire rst_n,
	input wire pclk,
	input wire prst_n,
	/* The internal register bus (from atg_cp_disp) */
	(* max_fanout = 16 *) input wire d_we,
	(* max_fanout = 16 *) input wire [5:0] d_idx,
	(* max_fanout = 16 *) input wire [31:0] d_wdata,
	(* max_fanout = 16 *) input wire [31:0] d_wmask,
	(* max_fanout = 16 *) input wire [5:0] d_ridx,
	output wire [31:0] d_rdata,
	/* Flips and the status for the records (atg_cp_disp) */
	(* max_fanout = 16 *) input wire flip_valid,
	(* max_fanout = 16 *) input wire flip_plane,
	input wire [31:0] flip_base,
	output wire [1:0] taken,
	output wire [1:0] taken_cancel,
	output wire [1:0] pending,
	input wire [1:0] dc_err,
	output wire idle,
	output wire [31:0] frame_count,
	/* Events (one-cycle pulses): IRQ_STATUS VBLANK, DISP_ERROR, HOTPLUG */
	output wire ev_vblank,
	output wire ev_error,
	output wire ev_hotplug,
	output wire irq_display,
	output wire pclk_sel,
	/* Watermark preemption signals to MC (ws001-p039) */
	output wire dc_urgent,
	output wire dc_panic,
	/* AMB client port (design §4.1) */
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
	input wire rsp_error,
	/* Video outputs (pclk) */
	output wire [29:0] tmds,
	output wire [23:0] px_rgb,
	output wire px_de,
	output wire px_hs,
	output wire px_vs,
	/* I2C (gclk; open drain through the board's IOBUF) */
	output wire scl_t,
	input wire scl_i,
	output wire sda_t,
	input wire sda_i
);
	wire enable, test_pattern, dc_reset, dma_idle, dma_done, dma_err;
	wire [1:0] format;
	wire [31:0] fb_stride, fb_size, fb_base, scan_sum, scan_words;
	wire [287:0] timing;
	wire i2c_we;
	wire [1:0] i2c_idx;
	wire [31:0] i2c_wdata, i2c_rdata;
	wire px_w_valid, px_w_ready, px_r_valid, px_r_ready;
	wire [31:0] px_w_data, px_r_data;

`ifdef SYNTH_KINTEX7
	wire [31:0] d_wdata_b0, d_wdata_b1;
	wire [31:0] d_wmask_b0, d_wmask_b1;
	genvar gwb;
	generate
		for (gwb = 0; gwb < 32; gwb = gwb + 1) begin : g_wdata_buf
			LUT1 #(.INIT(2'b10)) u_buf_d0 (.I0(d_wdata[gwb]), .O(d_wdata_b0[gwb]));
			LUT1 #(.INIT(2'b10)) u_buf_d1 (.I0(d_wdata[gwb]), .O(d_wdata_b1[gwb]));
			LUT1 #(.INIT(2'b10)) u_buf_m0 (.I0(d_wmask[gwb]), .O(d_wmask_b0[gwb]));
			LUT1 #(.INIT(2'b10)) u_buf_m1 (.I0(d_wmask[gwb]), .O(d_wmask_b1[gwb]));
		end
	endgenerate
	wire flip_valid_b0, flip_valid_b1;
	LUT1 #(.INIT(2'b10)) u_buf_fv0 (.I0(flip_valid), .O(flip_valid_b0));
	LUT1 #(.INIT(2'b10)) u_buf_fv1 (.I0(flip_valid), .O(flip_valid_b1));
	wire flip_plane_b0, flip_plane_b1;
	LUT1 #(.INIT(2'b10)) u_buf_fp0 (.I0(flip_plane), .O(flip_plane_b0));
	LUT1 #(.INIT(2'b10)) u_buf_fp1 (.I0(flip_plane), .O(flip_plane_b1));
	wire rsp_error_b0, rsp_error_b1;
	LUT1 #(.INIT(2'b10)) u_buf_re0 (.I0(rsp_error), .O(rsp_error_b0));
	LUT1 #(.INIT(2'b10)) u_buf_re1 (.I0(rsp_error), .O(rsp_error_b1));
	wire d_we_b0, d_we_b1;
	LUT1 #(.INIT(2'b10)) u_buf_we0 (.I0(d_we), .O(d_we_b0));
	LUT1 #(.INIT(2'b10)) u_buf_we1 (.I0(d_we), .O(d_we_b1));
	wire [5:0] d_idx_b0, d_idx_b1;
	wire [5:0] d_ridx_b0, d_ridx_b1;
	genvar gib;
	generate
		for (gib = 0; gib < 6; gib = gib + 1) begin : g_idx_buf
			LUT1 #(.INIT(2'b10)) u_buf_i0 (.I0(d_idx[gib]), .O(d_idx_b0[gib]));
			LUT1 #(.INIT(2'b10)) u_buf_i1 (.I0(d_idx[gib]), .O(d_idx_b1[gib]));
			LUT1 #(.INIT(2'b10)) u_buf_ri0 (.I0(d_ridx[gib]), .O(d_ridx_b0[gib]));
			LUT1 #(.INIT(2'b10)) u_buf_ri1 (.I0(d_ridx[gib]), .O(d_ridx_b1[gib]));
		end
	endgenerate
`else
	wire [31:0] d_wdata_b0 = d_wdata, d_wdata_b1 = d_wdata;
	wire [31:0] d_wmask_b0 = d_wmask, d_wmask_b1 = d_wmask;
	wire flip_valid_b0 = flip_valid, flip_valid_b1 = flip_valid;
	wire flip_plane_b0 = flip_plane, flip_plane_b1 = flip_plane;
	wire rsp_error_b0 = rsp_error, rsp_error_b1 = rsp_error;
	wire d_we_b0 = d_we, d_we_b1 = d_we;
	wire [5:0] d_idx_b0 = d_idx, d_idx_b1 = d_idx;
	wire [5:0] d_ridx_b0 = d_ridx, d_ridx_b1 = d_ridx;
`endif

	wire de, hs, vs;
	wire frame_toggle, vsync_toggle, underflow_toggle;
	wire [11:0] p_line;
	wire [2:0] g_toggles;
	reg [2:0] g_toggles_q;
`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire dc_top_rst_high;
	LUT1 #(.INIT(2'b01)) u_top_rst_inv (.I0(rst_n), .O(dc_top_rst_high));
	wire rst_high = dc_top_rst_high;

	(* keep = "true" *) wire dc_top_prst_high;
	LUT1 #(.INIT(2'b01)) u_top_prst_inv (.I0(prst_n), .O(dc_top_prst_high));
	wire prst_high = dc_top_prst_high;

	(* keep = "true" *) wire dc_rst_high;
	LUT2 #(.INIT(4'b1101)) u_top_dc_rst (.I0(rst_n), .I1(dc_reset), .O(dc_rst_high));
`else
	(* keep = "true" *) wire rst_high = !rst_n;
	(* keep = "true" *) wire prst_high = !prst_n;
	(* keep = "true" *) wire dc_rst_high = !rst_n || dc_reset;
`endif
	wire dc_rst_n = !dc_rst_high;
	wire g_rst_n = dc_rst_n;
	wire [31:0] regs_rdata, mode_rdata;
	wire connected;
	wire [31:0] cur_pos, cursor_base;
	wire cur_show;

	/* Extended WSI / HDR / VRR / Plane2 signals */
	wire hdr_en, vrr_en, flip_ready, plane2_en;
	wire [11:0] vrr_vmax;
	wire [11:0] plane2_pos_x, plane2_pos_y, plane2_width, plane2_height;
	wire [7:0]  plane2_alpha;
	wire        plane2_colorkey_en, plane2_yuv_mode;
	wire [23:0] plane2_colorkey;

`ifdef SYNTH_KINTEX7
	wire clk_g;
	BUFG u_bufg_clk (.I(clk), .O(clk_g));
	wire p_clk = clk_g;
`else
	wire clk_g = clk;
	wire p_clk = pclk;
`endif

	(* keep = "true" *) wire rst_n_net = rst_n;
	(* max_fanout = 16 *) wire rsp_error_b = rsp_error;
	(* max_fanout = 16 *) wire enable_b = enable;
	(* max_fanout = 16 *) wire flip_valid_b = flip_valid;
	(* max_fanout = 16 *) wire flip_plane_b = flip_plane;

`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire [1:0] format_dma, format_cursor, format_tgen;
	LUT1 #(.INIT(2'b10)) u_buf_fmt_d0 (.I0(format[0]), .O(format_dma[0]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_d1 (.I0(format[1]), .O(format_dma[1]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_c0 (.I0(format[0]), .O(format_cursor[0]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_c1 (.I0(format[1]), .O(format_cursor[1]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_t0 (.I0(format[0]), .O(format_tgen[0]));
	LUT1 #(.INIT(2'b10)) u_buf_fmt_t1 (.I0(format[1]), .O(format_tgen[1]));

	(* keep = "true" *) wire connected_regs;
	LUT1 #(.INIT(2'b10)) u_buf_conn (.I0(connected), .O(connected_regs));
`else
	wire [1:0] format_dma = format, format_cursor = format, format_tgen = format;
	wire connected_regs = connected;
`endif

	(* max_fanout = 16 *) wire p_hdr_en, p_vrr_en, p_flip_ready, p_plane2_en;
	am_sync sync_hdr (.clk(p_clk), .rst_n(prst_n), .d(hdr_en), .q(p_hdr_en));
	am_sync sync_vrr (.clk(p_clk), .rst_n(prst_n), .d(vrr_en), .q(p_vrr_en));
	am_sync sync_fr  (.clk(p_clk), .rst_n(prst_n), .d(flip_ready), .q(p_flip_ready));
	am_sync sync_p2  (.clk(p_clk), .rst_n(prst_n), .d(plane2_en), .q(p_plane2_en));

	/* pclk → gclk events as toggles (am_sync), edges here. */
	am_sync #(.W(3)) sync_ev (
		.clk(clk_g), .rst_n(1'b1), .d({underflow_toggle, vsync_toggle, frame_toggle}),
		.q(g_toggles)
	);
	always @(posedge clk_g) begin
		if (rst_high)
			g_toggles_q <= 3'd0;
		else
			g_toggles_q <= g_toggles;
	end
	(* keep = "true", equivalent_register_removal = "no" *) reg [2:0] g_ev;
	(* keep = "true", equivalent_register_removal = "no" *) reg [2:1] g_ev_regs;
	(* keep = "true", equivalent_register_removal = "no" *) reg [2:0] g_ev_dma;
	(* keep = "true", equivalent_register_removal = "no" *) reg [2:0] g_ev_cursor;
	always @(posedge clk_g) begin
		if (rst_high) begin
			g_ev <= 3'd0;
			g_ev_regs <= 2'd0;
			g_ev_dma <= 3'd0;
			g_ev_cursor <= 3'd0;
		end else begin
			g_ev <= g_toggles ^ g_toggles_q;
			g_ev_regs <= g_toggles[2:1] ^ g_toggles_q[2:1];
			g_ev_dma <= g_toggles ^ g_toggles_q;
			g_ev_cursor <= g_toggles ^ g_toggles_q;
		end
	end

	/* gclk → pclk: ENABLE, and CTRL.RESET (a 32-cycle pulse) so that both
	 * sides of the pixel FIFO are reset together (am_afifo's rule). */
	wire p_dc_reset;
	(* max_fanout = 16 *) wire p_enable;
	am_sync sync_en (.clk(p_clk), .rst_n(prst_n), .d(enable_b), .q(p_enable));
	am_sync sync_rst (.clk(p_clk), .rst_n(prst_n), .d(dc_reset), .q(p_dc_reset));
	(* max_fanout = 16 *) reg p_enable_q;
	always @(posedge p_clk)
		p_enable_q <= p_enable;
	(* keep = "true" *) wire p_rst_high = !prst_n || p_dc_reset;
	wire p_rst_n = !p_rst_high;

	/* The current line, approximate (status only). */
	wire [11:0] g_line;
	am_sync #(.W(12)) sync_line (.clk(clk_g), .rst_n(1'b1), .d(p_line), .q(g_line));

	/* Register read data (Rule 3 feedthrough elimination under synthesis) */
	reg [31:0] d_rdata_q;
	always @(posedge clk_g)
		d_rdata_q <= regs_rdata | mode_rdata;
	assign d_rdata = REG_RDATA ? d_rdata_q : (regs_rdata | mode_rdata);
	wire cur_idle, cur_err;
	wire [31:0] dma_px_data;
	wire dma_px_valid, dma_px_ready;
	/* The DMA's AMB port (requester 0 of the DC's mux with the cursor). */
	wire m_req_valid, m_req_ready, m_req_write, m_rsp_valid;
	wire [ADDR_W-LINE_SHIFT-1:0] m_req_line;
	wire [LINE_BYTES-1:0] m_req_be;
	wire [LINE_BYTES*8-1:0] m_req_wdata;
	wire [7:0] m_req_tag;

	atg_dc_regs #(.HAS_I2C(HAS_I2C), .HAS_CURSOR(HAS_CURSOR), .MODES(TEST_MODE != 0 ? 1 : 2)) regs (
		.clk(clk_g), .rst_n(rst_n_net),
		.d_we(d_we_b0), .d_idx(d_idx_b0), .d_wdata(d_wdata_b0), .d_wmask(d_wmask_b0), .d_ridx(d_ridx_b0),
		.d_rdata(regs_rdata),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_base(fb_base),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.flip_valid(flip_valid_b0 && !flip_plane_b0), .flip_base(flip_base),
		.taken(taken[0]), .taken_cancel(taken_cancel[0]), .pending(pending[0]),
		.ev_vsync(g_ev_regs[1]), .ev_underflow(g_ev_regs[2]), .idle_in(idle), .line(g_line),
		.scan_sum(scan_sum), .scan_words(scan_words), .rd_err(dma_err || cur_err),
		.dc_err(dc_err),
		.connected(connected_regs), .pending1(pending[1]),
		.ev_vblank(ev_vblank), .ev_error(ev_error), .frame_count(frame_count),
		.irq_display(irq_display),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(i2c_rdata),
		.hdr_en(hdr_en), .vrr_en(vrr_en), .vrr_vmax(vrr_vmax), .flip_ready(flip_ready),
		.plane2_en(plane2_en), .plane2_pos_x(plane2_pos_x), .plane2_pos_y(plane2_pos_y),
		.plane2_width(plane2_width), .plane2_height(plane2_height),
		.plane2_alpha(plane2_alpha), .plane2_colorkey_en(plane2_colorkey_en),
		.plane2_colorkey(plane2_colorkey), .plane2_yuv_mode(plane2_yuv_mode)
	);

	atg_dc_mode #(.TEST_MODE(TEST_MODE)) mode (
		.clk(clk_g), .rst_n(rst_n_net), .dc_reset(dc_reset),
		.d_we(d_we_b1), .d_idx(d_idx_b1), .d_wdata(d_wdata_b1), .d_wmask(d_wmask_b1), .d_ridx(d_ridx_b1),
		.d_rdata(mode_rdata), .connected(connected), .ev_hotplug(ev_hotplug),
		.cur_pos(cur_pos), .cur_show(cur_show), .cursor_base(cursor_base)
	);

	atg_dc_dma #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dma (
		.clk(clk_g), .rst_n(rst_n_net), .clear(dc_reset),
		.enable(enable_b), .frame_start(g_ev_dma[0]), .fb_base(fb_base), .fb_stride(fb_stride),
		.fb_size(fb_size), .format(format_dma),
		.px_valid(dma_px_valid), .px_ready(dma_px_ready), .px_data(dma_px_data),
		.idle(dma_idle), .done(dma_done), .err(dma_err),
		.scan_sum(scan_sum), .scan_words(scan_words),
		.req_valid(m_req_valid), .req_ready(m_req_ready), .req_write(m_req_write),
		.req_line(m_req_line), .req_be(m_req_be), .req_wdata(m_req_wdata), .req_tag(m_req_tag),
		.rsp_valid(m_rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error_b0)
	);

	/* The cursor between the DMA and the pixel FIFO, its reads behind the DMA's. */
	generate
	if (HAS_CURSOR != 0) begin : g_cursor
		wire c_req_valid, c_req_ready, c_req_write, c_rsp_valid;
		wire [ADDR_W-LINE_SHIFT-1:0] c_req_line;
		wire [LINE_BYTES-1:0] c_req_be;
		wire [LINE_BYTES*8-1:0] c_req_wdata;
		wire [7:0] c_req_tag, mux_rsp_tag;
		wire mux_rsp_write, mux_rsp_error;
		wire [LINE_BYTES*8-1:0] mux_rsp_rdata;

		atg_dc_cursor #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) cursor (
			.clk(clk_g), .rst_n(rst_n_net), .dc_reset(dc_reset), .enable(enable_b), .format(format_cursor),
			.frame_start(g_ev_cursor[0]), .dma_done(dma_done), .fb_width(fb_size[15:0]),
			.i_valid(dma_px_valid), .i_ready(dma_px_ready), .i_data(dma_px_data),
			.o_valid(px_w_valid), .o_ready(px_w_ready), .o_data(px_w_data),
			.pos(cur_pos), .show(cur_show),
			.flip_valid(flip_valid_b1 && flip_plane_b1), .flip_base(flip_base),
			.taken(taken[1]), .taken_cancel(taken_cancel[1]), .pending(pending[1]),
			.cursor_base(cursor_base), .idle(cur_idle), .err(cur_err),
			.req_valid(c_req_valid), .req_ready(c_req_ready), .req_write(c_req_write),
			.req_line(c_req_line), .req_be(c_req_be), .req_wdata(c_req_wdata),
			.req_tag(c_req_tag),
			.rsp_valid(c_rsp_valid), .rsp_write(mux_rsp_write), .rsp_tag(mux_rsp_tag),
			.rsp_rdata(mux_rsp_rdata), .rsp_error(mux_rsp_error)
		);

		/* Low-fanout 2-way AMB read multiplexer between DMA (0) and Cursor (1) */
		reg lock;
		reg lock_k;
		wire pick = !m_req_valid && c_req_valid;
		wire any = m_req_valid || c_req_valid;
		wire k = lock ? lock_k : pick;

		always @(posedge clk_g) begin
			if (!rst_n_net) begin
				lock <= 1'b0;
				lock_k <= 1'b0;
			end else begin
				lock <= req_valid && !req_ready;
				lock_k <= k;
			end
		end

`ifdef SYNTH_KINTEX7
		wire k_line, k_tag;
		LUT1 #(.INIT(2'b10)) u_buf_kl (.I0(k), .O(k_line));
		LUT1 #(.INIT(2'b10)) u_buf_kt (.I0(k), .O(k_tag));
`else
		wire k_line = k;
		wire k_tag = k;
`endif

		assign req_valid = lock ? 1'b1 : any;
		assign req_write = 1'b0;
`ifdef SYNTH_KINTEX7
		wire k_line_lo, k_line_hi;
		LUT1 #(.INIT(2'b10)) u_buf_kl_lo (.I0(k_line), .O(k_line_lo));
		LUT1 #(.INIT(2'b10)) u_buf_kl_hi (.I0(k_line), .O(k_line_hi));
		assign req_line[13:0] = k_line_lo ? c_req_line[13:0] : m_req_line[13:0];
		assign req_line[ADDR_W-LINE_SHIFT-1:14] = k_line_hi ? c_req_line[ADDR_W-LINE_SHIFT-1:14] : m_req_line[ADDR_W-LINE_SHIFT-1:14];
`else
		assign req_line = k_line ? c_req_line : m_req_line;
`endif
		assign req_be = {LINE_BYTES{1'b0}};
		assign req_wdata = {(LINE_BYTES*8){1'b0}};
		assign req_tag = {k_tag, k_tag ? c_req_tag[6:0] : m_req_tag[6:0]};

		assign m_req_ready = req_valid && req_ready && (k == 1'b0);
		assign c_req_ready = req_valid && req_ready && (k == 1'b1);

		assign m_rsp_valid = rsp_valid && (rsp_tag[7] == 1'b0);
		assign c_rsp_valid = rsp_valid && (rsp_tag[7] == 1'b1);
		assign mux_rsp_write = rsp_write;
		assign mux_rsp_tag = {1'b0, rsp_tag[6:0]};
		assign mux_rsp_rdata = rsp_rdata;
		assign mux_rsp_error = rsp_error_b1;
		assign idle = dma_idle && cur_idle;
	end else begin : g_no_cursor
		assign px_w_valid = dma_px_valid;
		assign dma_px_ready = px_w_ready;
		assign px_w_data = dma_px_data;
		assign req_valid = m_req_valid;
		assign m_req_ready = req_ready;
		assign req_write = m_req_write;
		assign req_line = m_req_line;
		assign req_be = m_req_be;
		assign req_wdata = m_req_wdata;
		assign req_tag = m_req_tag;
		assign m_rsp_valid = rsp_valid;
		assign taken[1] = 1'b0;
		assign taken_cancel[1] = 1'b0;
		assign pending[1] = 1'b0;
		assign cursor_base = 32'd0;
		assign cur_idle = 1'b1;
		assign cur_err = 1'b0;
		assign idle = dma_idle;
		wire unused_cur = &{1'b0, cur_pos, cur_show, dma_done};
	end
	endgenerate

	wire [FIFO_LOG2:0] px_fifo_count;
	atg_dc_fifo #(.W(32), .DEPTH_LOG2(FIFO_LOG2)) pixels (
		.w_clk(clk_g), .w_rst_n(g_rst_n), .w_valid(px_w_valid), .w_ready(px_w_ready),
		.w_data(px_w_data),
		.r_clk(p_clk), .r_rst_n(p_rst_n), .r_valid(px_r_valid), .r_ready(px_r_ready),
		.r_data(px_r_data),
		.r_count(px_fifo_count)
	);

	/* Watermark detection in pclk domain, synchronized to clk */
	localparam [FIFO_LOG2:0] WM_URGENT = (40 * (1 << FIFO_LOG2)) / 100;
	localparam [FIFO_LOG2:0] WM_PANIC  = (20 * (1 << FIFO_LOG2)) / 100;

	reg p_urgent, p_panic;
	always @(posedge p_clk) begin
		if (prst_high) begin
			p_urgent <= 1'b0;
			p_panic  <= 1'b0;
		end else begin
			p_urgent <= p_enable && (px_fifo_count < WM_URGENT);
			p_panic  <= p_enable && (px_fifo_count < WM_PANIC);
		end
	end

	am_sync sync_urgent (
		.clk(clk_g), .rst_n(1'b1), .d(p_urgent), .q(dc_urgent)
	);
	am_sync sync_panic (
		.clk(clk_g), .rst_n(1'b1), .d(p_panic), .q(dc_panic)
	);

	wire [11:0] p_col;
	wire [23:0] tgen_rgb, p2_rgb, final_rgb;
	wire [29:0] tgen_rgb10;
	/* verilator lint_off UNUSEDSIGNAL */
	wire p2_de;
	/* verilator lint_on UNUSEDSIGNAL */
	wire [9:0] hdr_in_r, hdr_in_g, hdr_in_b;
	/* verilator lint_off UNUSEDSIGNAL */
	wire [9:0] hdr_out_r, hdr_out_g, hdr_out_b;
	/* verilator lint_on UNUSEDSIGNAL */

	atg_dc_tgen tgen (
		.clk(p_clk), .rst_n(p_rst_n), .enable(p_enable_q), .test_pattern(test_pattern),
		.format(format_tgen), .timing(timing),
		.px_valid(px_r_valid), .px_ready(px_r_ready), .px_data(px_r_data),
		.rgb(tgen_rgb), .de(de), .hs(hs), .vs(vs),
		.frame_toggle(frame_toggle), .vsync_toggle(vsync_toggle),
		.underflow_toggle(underflow_toggle), .line(p_line),
		.vrr_en(p_vrr_en), .flip_ready(p_flip_ready), .vrr_vmax(vrr_vmax),
		.col(p_col), .rgb10(tgen_rgb10)
	);

	/* verilator lint_off PINCONNECTEMPTY */
	atg_dc_plane2 #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)
	) u_plane2 (
		.clk(p_clk), .rst_n(p_rst_n), .enable(p_enable_q),
		.plane_en(p_plane2_en),
		.pos_x(plane2_pos_x), .pos_y(plane2_pos_y),
		.width(plane2_width), .height(plane2_height),
		.alpha(plane2_alpha), .colorkey_en(plane2_colorkey_en),
		.colorkey(plane2_colorkey), .yuv_mode(plane2_yuv_mode),
		.cur_x(p_col), .cur_y(p_line),
		.prim_rgb(tgen_rgb), .prim_valid(de),
		.out_rgb(p2_rgb), .out_valid(p2_de),
		.ov_valid(1'b0), .ov_ready(), .ov_y(8'd0), .ov_u(8'd0), .ov_v(8'd0), .ov_rgb(24'd0),
		.req_valid(), .req_ready(1'b0), .req_write(), .req_line(), .req_be(), .req_wdata(), .req_tag(),
		.rsp_valid(1'b0), .rsp_write(1'b0), .rsp_tag(8'd0), .rsp_rdata({(LINE_BYTES*8){1'b0}}), .rsp_error(1'b0)
	);
	/* verilator lint_on PINCONNECTEMPTY */

	assign hdr_in_r = p_plane2_en ? {p2_rgb[23:16], p2_rgb[23:22]} : tgen_rgb10[29:20];
	assign hdr_in_g = p_plane2_en ? {p2_rgb[15:8],  p2_rgb[15:14]}  : tgen_rgb10[19:10];
	assign hdr_in_b = p_plane2_en ? {p2_rgb[7:0],   p2_rgb[7:6]}   : tgen_rgb10[9:0];

	atg_dc_hdr #(
		.CSC_ENABLE(1)
	) u_hdr (
		.pclk(p_clk), .prst_n(p_rst_n),
		.hdr_en(p_hdr_en),
		.in_r(hdr_in_r), .in_g(hdr_in_g), .in_b(hdr_in_b),
		.out_r(hdr_out_r), .out_g(hdr_out_g), .out_b(hdr_out_b)
	);

	(* equivalent_register_removal = "no" *) reg p_plane2_en_r, p_plane2_en_g, p_plane2_en_b;
	(* equivalent_register_removal = "no" *) reg p_hdr_en_r, p_hdr_en_g, p_hdr_en_b;
	always @(posedge p_clk) begin
		p_plane2_en_r <= p_plane2_en;
		p_plane2_en_g <= p_plane2_en;
		p_plane2_en_b <= p_plane2_en;
		p_hdr_en_r    <= p_hdr_en;
		p_hdr_en_g    <= p_hdr_en;
		p_hdr_en_b    <= p_hdr_en;
	end

	assign final_rgb[23:16] = p_hdr_en_r ? hdr_out_r[9:2] : (p_plane2_en_r ? p2_rgb[23:16] : tgen_rgb[23:16]);
	assign final_rgb[15:8]  = p_hdr_en_g ? hdr_out_g[9:2] : (p_plane2_en_g ? p2_rgb[15:8]  : tgen_rgb[15:8]);
	assign final_rgb[7:0]   = p_hdr_en_b ? hdr_out_b[9:2] : (p_plane2_en_b ? p2_rgb[7:0]   : tgen_rgb[7:0]);

	wire [23:0] final_rgb_tmds = final_rgb;
	wire [23:0] final_rgb_px = final_rgb;

	atg_dc_tmds tmds_enc (
		.clk(p_clk), .rst_n(p_rst_n), .rgb(final_rgb_tmds), .de(de), .hs(hs), .vs(vs), .tmds(tmds)
	);

	/* The parallel output (KC705 ADV7511). */
	generate
	if (PX_FMT == 1) begin : g_ycc
		wire [15:0] ycc;

		atg_dc_ycc ycc_enc (
			.clk(p_clk), .rst_n(p_rst_n), .rgb(final_rgb_px), .de(de), .hs(hs), .vs(vs),
			.ycc(ycc), .ycc_de(px_de), .ycc_hs(px_hs), .ycc_vs(px_vs)
		);
		assign px_rgb = {8'd0, ycc};
	end else begin : g_rgb
		assign px_rgb = final_rgb_px;
		assign px_de = de;
		assign px_hs = hs;
		assign px_vs = vs;
	end
	endgenerate

	generate
	if (HAS_I2C != 0) begin : g_i2c
		atg_dc_i2c i2c (
			.clk(clk_g), .rst_n(g_rst_n), .i_we(i2c_we), .i_idx(i2c_idx), .i_wdata(i2c_wdata),
			.i_rdata(i2c_rdata), .scl_t(scl_t), .scl_i(scl_i), .sda_t(sda_t), .sda_i(sda_i)
		);
	end else begin : g_no_i2c
		assign i2c_rdata = 32'd0;
		assign scl_t = 1'b1;
		assign sda_t = 1'b1;
		wire unused_i2c = &{1'b0, i2c_we, i2c_idx, i2c_wdata, scl_i, sda_i};
	end
	endgenerate

	wire unused_ok = &{1'b0, cur_idle};
endmodule

`default_nettype wire
