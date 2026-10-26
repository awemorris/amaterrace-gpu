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
	input wire d_we,
	input wire [5:0] d_idx,
	input wire [31:0] d_wdata,
	input wire [31:0] d_wmask,
	input wire [5:0] d_ridx,
	output wire [31:0] d_rdata,
	/* Flips and the status for the records (atg_cp_disp) */
	input wire flip_valid,
	input wire flip_plane,
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
	wire de, hs, vs;
	wire frame_toggle, vsync_toggle, underflow_toggle;
	wire [11:0] p_line;
	wire p_enable;
	wire [2:0] g_toggles;
	reg [2:0] g_toggles_q;
	wire g_rst_n = rst_n && !dc_reset;
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

	wire p_hdr_en, p_vrr_en, p_flip_ready, p_plane2_en;
	am_sync sync_hdr (.clk(pclk), .rst_n(prst_n), .d(hdr_en), .q(p_hdr_en));
	am_sync sync_vrr (.clk(pclk), .rst_n(prst_n), .d(vrr_en), .q(p_vrr_en));
	am_sync sync_fr  (.clk(pclk), .rst_n(prst_n), .d(flip_ready), .q(p_flip_ready));
	am_sync sync_p2  (.clk(pclk), .rst_n(prst_n), .d(plane2_en), .q(p_plane2_en));

	/* pclk → gclk events as toggles (am_sync), edges here. */
	am_sync #(.W(3)) sync_ev (
		.clk(clk), .rst_n(g_rst_n), .d({underflow_toggle, vsync_toggle, frame_toggle}),
		.q(g_toggles)
	);
	always @(posedge clk)
		if (!g_rst_n)
			g_toggles_q <= 3'd0;
		else
			g_toggles_q <= g_toggles;
	wire [2:0] g_ev = g_toggles ^ g_toggles_q;

	/* gclk → pclk: ENABLE, and CTRL.RESET (a 32-cycle pulse) so that both
	 * sides of the pixel FIFO are reset together (am_afifo's rule). */
	wire p_dc_reset;
	am_sync sync_en (.clk(pclk), .rst_n(prst_n), .d(enable), .q(p_enable));
	am_sync sync_rst (.clk(pclk), .rst_n(prst_n), .d(dc_reset), .q(p_dc_reset));
	wire p_rst_n = prst_n && !p_dc_reset;

	/* The current line, approximate (status only). */
	wire [11:0] g_line;
	am_sync #(.W(12)) sync_line (.clk(clk), .rst_n(g_rst_n), .d(p_line), .q(g_line));

	assign d_rdata = regs_rdata | mode_rdata;
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
		.clk(clk), .rst_n(rst_n),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(regs_rdata),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_base(fb_base),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.flip_valid(flip_valid && !flip_plane), .flip_base(flip_base),
		.taken(taken[0]), .taken_cancel(taken_cancel[0]), .pending(pending[0]),
		.ev_vsync(g_ev[1]), .ev_underflow(g_ev[2]), .idle_in(idle), .line(g_line),
		.scan_sum(scan_sum), .scan_words(scan_words), .rd_err(dma_err || cur_err),
		.dc_err(dc_err),
		.connected(connected), .pending1(pending[1]),
		.ev_vblank(ev_vblank), .ev_error(ev_error), .frame_count(frame_count),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(i2c_rdata),
		.hdr_en(hdr_en), .vrr_en(vrr_en), .vrr_vmax(vrr_vmax), .flip_ready(flip_ready),
		.plane2_en(plane2_en), .plane2_pos_x(plane2_pos_x), .plane2_pos_y(plane2_pos_y),
		.plane2_width(plane2_width), .plane2_height(plane2_height),
		.plane2_alpha(plane2_alpha), .plane2_colorkey_en(plane2_colorkey_en),
		.plane2_colorkey(plane2_colorkey), .plane2_yuv_mode(plane2_yuv_mode)
	);

	atg_dc_mode #(.TEST_MODE(TEST_MODE)) mode (
		.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(mode_rdata), .connected(connected), .ev_hotplug(ev_hotplug),
		.cur_pos(cur_pos), .cur_show(cur_show), .cursor_base(cursor_base)
	);

	atg_dc_dma #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dma (
		.clk(clk), .rst_n(rst_n), .clear(dc_reset),
		.enable(enable), .frame_start(g_ev[0]), .fb_base(fb_base), .fb_stride(fb_stride),
		.fb_size(fb_size), .format(format),
		.px_valid(dma_px_valid), .px_ready(dma_px_ready), .px_data(dma_px_data),
		.idle(dma_idle), .done(dma_done), .err(dma_err),
		.scan_sum(scan_sum), .scan_words(scan_words),
		.req_valid(m_req_valid), .req_ready(m_req_ready), .req_write(m_req_write),
		.req_line(m_req_line), .req_be(m_req_be), .req_wdata(m_req_wdata), .req_tag(m_req_tag),
		.rsp_valid(m_rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata), .rsp_error(rsp_error)
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
			.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset), .enable(enable), .format(format),
			.frame_start(g_ev[0]), .dma_done(dma_done), .fb_width(fb_size[15:0]),
			.i_valid(dma_px_valid), .i_ready(dma_px_ready), .i_data(dma_px_data),
			.o_valid(px_w_valid), .o_ready(px_w_ready), .o_data(px_w_data),
			.pos(cur_pos), .show(cur_show),
			.flip_valid(flip_valid && flip_plane), .flip_base(flip_base),
			.taken(taken[1]), .taken_cancel(taken_cancel[1]), .pending(pending[1]),
			.cursor_base(cursor_base), .idle(cur_idle), .err(cur_err),
			.req_valid(c_req_valid), .req_ready(c_req_ready), .req_write(c_req_write),
			.req_line(c_req_line), .req_be(c_req_be), .req_wdata(c_req_wdata),
			.req_tag(c_req_tag),
			.rsp_valid(c_rsp_valid), .rsp_write(mux_rsp_write), .rsp_tag(mux_rsp_tag),
			.rsp_rdata(mux_rsp_rdata), .rsp_error(mux_rsp_error)
		);

		am_amb_mux #(
			.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(2), .ID_W(1)
		) amb (
			.clk(clk), .rst_n(rst_n),
			.i_req_valid({c_req_valid, m_req_valid}), .i_req_ready({c_req_ready, m_req_ready}),
			.i_req_write({c_req_write, m_req_write}), .i_req_line({c_req_line, m_req_line}),
			.i_req_be({c_req_be, m_req_be}), .i_req_wdata({c_req_wdata, m_req_wdata}),
			.i_req_tag({c_req_tag, m_req_tag}),
			.i_rsp_valid({c_rsp_valid, m_rsp_valid}), .i_rsp_write(mux_rsp_write),
			.i_rsp_tag(mux_rsp_tag), .i_rsp_rdata(mux_rsp_rdata), .i_rsp_error(mux_rsp_error),
			.o_req_valid(req_valid), .o_req_ready(req_ready), .o_req_write(req_write),
			.o_req_line(req_line), .o_req_be(req_be), .o_req_wdata(req_wdata),
			.o_req_tag(req_tag),
			.o_rsp_valid(rsp_valid), .o_rsp_write(rsp_write), .o_rsp_tag(rsp_tag),
			.o_rsp_rdata(rsp_rdata), .o_rsp_error(rsp_error)
		);
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
	am_afifo_bram #(.W(32), .DEPTH_LOG2(FIFO_LOG2)) pixels (
		.w_clk(clk), .w_rst_n(g_rst_n), .w_valid(px_w_valid), .w_ready(px_w_ready),
		.w_data(px_w_data),
		.r_clk(pclk), .r_rst_n(p_rst_n), .r_valid(px_r_valid), .r_ready(px_r_ready),
		.r_data(px_r_data),
		.r_count(px_fifo_count)
	);

	/* Watermark detection in pclk domain, synchronized to clk */
	localparam [FIFO_LOG2:0] WM_URGENT = (40 * (1 << FIFO_LOG2)) / 100;
	localparam [FIFO_LOG2:0] WM_PANIC  = (20 * (1 << FIFO_LOG2)) / 100;

	reg p_urgent, p_panic;
	always @(posedge pclk) begin
		if (!p_rst_n) begin
			p_urgent <= 1'b0;
			p_panic  <= 1'b0;
		end else begin
			p_urgent <= p_enable && (px_fifo_count < WM_URGENT);
			p_panic  <= p_enable && (px_fifo_count < WM_PANIC);
		end
	end

	am_sync sync_urgent (
		.clk(clk), .rst_n(g_rst_n), .d(p_urgent), .q(dc_urgent)
	);
	am_sync sync_panic (
		.clk(clk), .rst_n(g_rst_n), .d(p_panic), .q(dc_panic)
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
		.clk(pclk), .rst_n(p_rst_n), .enable(p_enable), .test_pattern(test_pattern),
		.format(format), .timing(timing),
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
		.clk(pclk), .rst_n(p_rst_n), .enable(p_enable),
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
		.pclk(pclk), .prst_n(p_rst_n),
		.hdr_en(p_hdr_en),
		.in_r(hdr_in_r), .in_g(hdr_in_g), .in_b(hdr_in_b),
		.out_r(hdr_out_r), .out_g(hdr_out_g), .out_b(hdr_out_b)
	);

	assign final_rgb = p_hdr_en ? {hdr_out_r[9:2], hdr_out_g[9:2], hdr_out_b[9:2]} : (p_plane2_en ? p2_rgb : tgen_rgb);

	atg_dc_tmds tmds_enc (
		.clk(pclk), .rst_n(p_rst_n), .rgb(final_rgb), .de(de), .hs(hs), .vs(vs), .tmds(tmds)
	);

	/* The parallel output (KC705 ADV7511). */
	generate
	if (PX_FMT == 1) begin : g_ycc
		wire [15:0] ycc;

		atg_dc_ycc ycc_enc (
			.clk(pclk), .rst_n(p_rst_n), .rgb(final_rgb), .de(de), .hs(hs), .vs(vs),
			.ycc(ycc), .ycc_de(px_de), .ycc_hs(px_hs), .ycc_vs(px_vs)
		);
		assign px_rgb = {8'd0, ycc};
	end else begin : g_rgb
		assign px_rgb = final_rgb;
		assign px_de = de;
		assign px_hs = hs;
		assign px_vs = vs;
	end
	endgenerate

	generate
	if (HAS_I2C != 0) begin : g_i2c
		atg_dc_i2c i2c (
			.clk(clk), .rst_n(g_rst_n), .i_we(i2c_we), .i_idx(i2c_idx), .i_wdata(i2c_wdata),
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
