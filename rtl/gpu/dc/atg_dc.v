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
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter FIFO_LOG2 = 9,	/* Pixel FIFO depth (2 lines of 640 need ≥ 1280 → 11 for 720p; 9 is the stub default) */
	parameter PX_FMT = 0	/* The parallel output: 0 RGB888 (px_rgb = {r, g, b}), 1 YCbCr 4:2:2 16-bit (px_rgb = {8'd0, C, Y}, the KC705's ADV7511, atg_dc_ycc) */
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
	wire [23:0] rgb;
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

	/* The cursor plane comes later (DC_CAPS[8] is 0): plane 1 is absent. */
	assign taken[1] = 1'b0;
	assign taken_cancel[1] = 1'b0;
	assign pending[1] = 1'b0;
	assign cursor_base = 32'd0;
	assign idle = dma_idle;
	assign d_rdata = regs_rdata | mode_rdata;

	atg_dc_regs #(.HAS_I2C(HAS_I2C), .HAS_CURSOR(0)) regs (
		.clk(clk), .rst_n(rst_n),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(regs_rdata),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_base(fb_base),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.flip_valid(flip_valid && !flip_plane), .flip_base(flip_base),
		.taken(taken[0]), .taken_cancel(taken_cancel[0]), .pending(pending[0]),
		.ev_vsync(g_ev[1]), .ev_underflow(g_ev[2]), .idle_in(dma_idle), .line(g_line),
		.scan_sum(scan_sum), .scan_words(scan_words), .rd_err(dma_err), .dc_err(dc_err),
		.connected(connected), .pending1(pending[1]),
		.ev_vblank(ev_vblank), .ev_error(ev_error), .frame_count(frame_count),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(i2c_rdata)
	);

	atg_dc_mode mode (
		.clk(clk), .rst_n(rst_n), .dc_reset(dc_reset),
		.d_we(d_we), .d_idx(d_idx), .d_wdata(d_wdata), .d_wmask(d_wmask), .d_ridx(d_ridx),
		.d_rdata(mode_rdata), .connected(connected), .ev_hotplug(ev_hotplug),
		.cur_pos(cur_pos), .cur_show(cur_show), .cursor_base(cursor_base)
	);

	atg_dc_dma #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dma (
		.clk(clk), .rst_n(rst_n), .clear(dc_reset),
		.enable(enable), .frame_start(g_ev[0]), .fb_base(fb_base), .fb_stride(fb_stride),
		.fb_size(fb_size), .format(format),
		.px_valid(px_w_valid), .px_ready(px_w_ready), .px_data(px_w_data), .idle(dma_idle),
		.done(dma_done), .err(dma_err),
		.scan_sum(scan_sum), .scan_words(scan_words),
		.req_valid(req_valid), .req_ready(req_ready), .req_write(req_write), .req_line(req_line),
		.req_be(req_be), .req_wdata(req_wdata), .req_tag(req_tag),
		.rsp_valid(rsp_valid), .rsp_write(rsp_write), .rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	am_afifo #(.W(32), .DEPTH_LOG2(FIFO_LOG2)) pixels (
		.w_clk(clk), .w_rst_n(g_rst_n), .w_valid(px_w_valid), .w_ready(px_w_ready),
		.w_data(px_w_data),
		.r_clk(pclk), .r_rst_n(p_rst_n), .r_valid(px_r_valid), .r_ready(px_r_ready),
		.r_data(px_r_data)
	);

	atg_dc_tgen tgen (
		.clk(pclk), .rst_n(p_rst_n), .enable(p_enable), .test_pattern(test_pattern),
		.format(format), .timing(timing),
		.px_valid(px_r_valid), .px_ready(px_r_ready), .px_data(px_r_data),
		.rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.frame_toggle(frame_toggle), .vsync_toggle(vsync_toggle),
		.underflow_toggle(underflow_toggle), .line(p_line)
	);

	atg_dc_tmds tmds_enc (
		.clk(pclk), .rst_n(p_rst_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs), .tmds(tmds)
	);

	/* The parallel output (KC705 ADV7511). */
	generate
	if (PX_FMT == 1) begin : g_ycc
		wire [15:0] ycc;

		atg_dc_ycc ycc_enc (
			.clk(pclk), .rst_n(p_rst_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
			.ycc(ycc), .ycc_de(px_de), .ycc_hs(px_hs), .ycc_vs(px_vs)
		);
		assign px_rgb = {8'd0, ycc};
	end else begin : g_rgb
		assign px_rgb = rgb;
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

	wire unused_ok = &{1'b0, dma_done, cur_pos, cur_show};
endmodule

`default_nettype wire
