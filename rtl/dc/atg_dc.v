/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc: The display controller IP (design §5): registers and DMA in
 * gclk, a pixel FIFO (am_afifo) to the pixel clock, timing generator, VGA
 * and TMDS encoders and a parallel output, optional I2C; its own AMB
 * client port (ZYBO: to its own am_axi_master on HP1; KC705: an MC client
 * of atg_top).
 *
 * Wiring of its children; see spec/dc/atg_dc.md.  The only clock
 * crossings: the pixel FIFO (am_afifo), ENABLE and CTRL.RESET to pclk, the
 * event toggles and the line to gclk (am_sync).  The timing, format and
 * test pattern are quasi-static and go to pclk directly (atg_dc_regs §7).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc #(
	parameter STANDALONE = 0,	/* 1: a DC-only GHCI device (ZYBO bitstream 2): GHCI header at 0x000, DISP registers at 0x200; 0: DISP registers at BASE (KC705 0x10000) */
	parameter BASE = 17'h10000,	/* Window of the DISP registers when STANDALONE = 0 */
	parameter HAS_I2C = 0,	/* ADV7511 I2C master present (KC705, DC_CAPS[2]) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter FIFO_LOG2 = 9	/* Pixel FIFO depth (2 lines of 640 need ≥ 1280 → 11 for 720p; 9 is the stub default) */
) (
	input wire clk,
	input wire rst_n,
	input wire pclk,
	input wire prst_n,
	/* Register bus (am_axi_regs; the DC decodes its own window) */
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output wire [31:0] reg_rdata,
	output wire irq,
	output wire vsync,
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
	output wire [4:0] vga_r,
	output wire [5:0] vga_g,
	output wire [4:0] vga_b,
	output wire vga_hs,
	output wire vga_vs,
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
	wire enable, test_pattern, dc_reset, dma_idle;
	wire [1:0] format;
	wire [31:0] fb_next, fb_stride, fb_size, fb_base, scan_sum, scan_words;
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

	assign vsync = g_ev[1];

	atg_dc_regs #(.STANDALONE(STANDALONE), .BASE(BASE), .HAS_I2C(HAS_I2C)) regs (
		.clk(clk), .rst_n(rst_n),
		.reg_wr(reg_wr), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
		.reg_rd(reg_rd), .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
		.enable(enable), .test_pattern(test_pattern), .format(format), .fb_next(fb_next),
		.fb_stride(fb_stride), .fb_size(fb_size), .timing(timing), .pclk_sel(pclk_sel),
		.dc_reset(dc_reset),
		.ev_vsync(g_ev[1]), .ev_flip(g_ev[1]), .ev_underflow(g_ev[2]), .dma_idle(dma_idle),
		.line(g_line), .scan_sum(scan_sum), .scan_words(scan_words), .fb_base(fb_base),
		.irq(irq),
		.i2c_we(i2c_we), .i2c_idx(i2c_idx), .i2c_wdata(i2c_wdata), .i2c_rdata(i2c_rdata)
	);

	atg_dc_dma #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dma (
		.clk(clk), .rst_n(g_rst_n),
		.enable(enable), .frame_start(g_ev[0]), .fb_base(fb_base), .fb_stride(fb_stride),
		.fb_size(fb_size), .format(format),
		.px_valid(px_w_valid), .px_ready(px_w_ready), .px_data(px_w_data), .idle(dma_idle),
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

	atg_dc_vga vga (
		.clk(pclk), .rgb(rgb), .de(de), .hs(hs), .vs(vs),
		.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs)
	);

	atg_dc_tmds tmds_enc (
		.clk(pclk), .rst_n(p_rst_n), .rgb(rgb), .de(de), .hs(hs), .vs(vs), .tmds(tmds)
	);

	/* The parallel output (KC705 ADV7511). */
	assign px_rgb = rgb;
	assign px_de = de;
	assign px_hs = hs;
	assign px_vs = vs;

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

	wire unused_ok = &{1'b0, fb_next};
endmodule

`default_nettype wire
