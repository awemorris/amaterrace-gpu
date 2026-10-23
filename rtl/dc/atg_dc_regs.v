/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_regs: The DC's registers (design §5.1): DC_ID/VERSION/CAPS, CTRL,
 * STATUS, IRQ, FB_*, timing, FRAME_COUNT, PCLK_SEL, the I2C window, and in
 * the standalone bitstream the GHCI header that makes the DC a
 * display-only GHCI device.  See spec/dc/atg_dc_regs.md.
 *
 * The register bus is am_axi_regs': a write takes effect in its cycle, a
 * read answers in the next cycle and reads 0 outside the DC's window
 * (128 bytes at the DISP offset, which is 128-byte aligned).
 * CTRL.RESET (W1S) raises dc_reset for RESET_CYCLES cycles (long enough
 * for the pixel clock side to see it, atg_dc) and clears ENABLE, the
 * interrupt status, the sticky underflow, FRAME_COUNT and a pending flip;
 * the configuration registers keep their values.  A write of FB_NEXT
 * while ENABLE is 1 makes a flip pending: at the next ev_flip (a vsync)
 * FB_BASE takes FB_NEXT and FLIP_DONE is raised.  While ENABLE is 0 there
 * is no vsync, so the write sets FB_BASE at once.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_regs #(
	parameter STANDALONE = 0,	/* 1: a DC-only GHCI device (ZYBO bitstream 2): GHCI header at 0x000, DISP registers at 0x200; 0: DISP registers at BASE (KC705 0x10000) */
	parameter BASE = 17'h10000,	/* Window of the DISP registers when STANDALONE = 0 */
	parameter HAS_I2C = 0	/* ADV7511 I2C master present (KC705, DC_CAPS[2]) */
) (
	input wire clk,
	input wire rst_n,
	/* Register bus (am_axi_regs; the DC decodes its own window) */
	input wire reg_wr,
	input wire [16:0] reg_waddr,
	input wire [31:0] reg_wdata,
	input wire [3:0] reg_wstrb,
	input wire reg_rd,
	input wire [16:0] reg_raddr,
	output reg [31:0] reg_rdata,
	/* Configuration to atg_dc_dma and atg_dc_tgen */
	output wire enable,
	output wire test_pattern,
	output wire [1:0] format,
	output wire [31:0] fb_next,
	output wire [31:0] fb_stride,
	output wire [31:0] fb_size,
	output wire [287:0] timing,
	output wire pclk_sel,
	output wire dc_reset,
	/* Status (gclk, already synchronised by atg_dc) */
	input wire ev_vsync,
	input wire ev_flip,
	input wire ev_underflow,
	input wire dma_idle,
	input wire [11:0] line,
	input wire [31:0] scan_sum,
	input wire [31:0] scan_words,
	output wire [31:0] fb_base,
	output wire irq,
	/* I2C window (to atg_dc_i2c) */
	output wire i2c_we,
	output wire [1:0] i2c_idx,
	output wire [31:0] i2c_wdata,
	input wire [31:0] i2c_rdata
);
	`include "ghci_regs.vh"

	localparam [16:0] DISP = STANDALONE != 0 ? GHCI_DC_STANDALONE_DISP : BASE;
	localparam [31:0] DC_VERSION_VALUE = 32'h00000001;	/* 0.1 (WS288 p005) */
	/* DC_CAPS: [1:0] VGA and TMDS without the transmitter, [2] the
	 * transmitter with it; [7:4] formats 0..2; [11:9] two modes. */
	localparam [31:0] DC_CAPS_VALUE = {20'd0, 3'd2, 1'b0, 4'b0111, 1'b0,
		HAS_I2C != 0 ? 3'b100 : 3'b011};
	localparam [31:0] DEVICE_VERSION_VALUE = 32'h00000001;
	localparam [31:0] GCLK_HZ_VALUE = 32'd100000000;
	localparam [16:0] LIST = GHCI_EXTCAP_LIST;
	localparam [5:0] RESET_CYCLES = 6'd32;

	/* Configuration and status. */
	reg r_enable, r_test, r_output;
	reg [1:0] r_format;
	reg [31:0] r_fb_base, r_fb_next, r_stride, r_size;
	reg [31:0] r_timing [0:8];
	reg r_pclk_sel;
	reg [2:0] irq_status, irq_enable;
	reg underflow;
	reg flip_pending;
	reg [31:0] frame_count;
	reg [5:0] reset_left;

	assign enable = r_enable;
	assign test_pattern = r_test;
	assign format = r_format;
	assign fb_next = r_fb_next;
	assign fb_stride = r_stride;
	assign fb_size = r_size;
	assign fb_base = r_fb_base;
	assign pclk_sel = r_pclk_sel;
	assign dc_reset = reset_left != 6'd0;
	assign irq = |(irq_status & irq_enable);

	genvar t;
	generate
	for (t = 0; t < 9; t = t + 1) begin : g_timing
		assign timing[32*t +: 32] = r_timing[t];
	end
	endgenerate

	/* Writes: the offset in the window. */
	wire w_in = reg_wr && reg_waddr[16:7] == DISP[16:7];
	wire [6:0] w_off = reg_waddr[6:0];
	wire [31:0] wmask = {{8{reg_wstrb[3]}}, {8{reg_wstrb[2]}}, {8{reg_wstrb[1]}},
		{8{reg_wstrb[0]}}};
	wire w_timing = w_off >= GHCI_DC_TIMING[6:0] && w_off <= GHCI_DC_SYNC_POL[6:0];
	wire [6:0] w_toff = w_off - GHCI_DC_TIMING[6:0];
	wire [3:0] w_tidx = w_toff[5:2];

	/* The written bits under the strobes. */
	wire [31:0] wbits = reg_wdata & wmask;

	wire [31:0] ctrl_old = {25'd0, r_output, r_format, 1'b0, r_test, 1'b0, r_enable};
	wire [31:0] ctrl_new = ((ctrl_old) & ~wmask | wbits);
	wire do_reset = w_in && w_off == GHCI_DC_CTRL[6:0] && ctrl_new[GHCI_DC_CTRL_RESET];
	wire w_irq_status = w_in && w_off == GHCI_DC_IRQ_STATUS[6:0];
	wire [2:0] irq_clear = w_irq_status ? reg_wdata[2:0] & wmask[2:0] : 3'd0;
	wire flip_now = ev_flip && flip_pending;
	wire [2:0] irq_set = {flip_now, ev_underflow, ev_vsync};
	wire [31:0] fb_next_new = ((r_fb_next) & ~wmask | wbits);
	wire [31:0] irq_enable_new = (({29'd0, irq_enable}) & ~wmask | wbits);
	wire [31:0] pclk_sel_new = (({31'd0, r_pclk_sel}) & ~wmask | wbits);

	integer k;

	always @(posedge clk) begin
		if (!rst_n) begin
			r_enable <= 1'b0;
			r_test <= 1'b0;
			r_output <= 1'b0;
			r_format <= 2'd0;
			r_fb_base <= 32'd0;
			r_fb_next <= 32'd0;
			r_stride <= 32'd0;
			r_size <= 32'd0;
			for (k = 0; k < 9; k = k + 1)
				r_timing[k] <= 32'd0;
			r_pclk_sel <= 1'b0;
			irq_status <= 3'd0;
			irq_enable <= 3'd0;
			underflow <= 1'b0;
			flip_pending <= 1'b0;
			frame_count <= 32'd0;
			reset_left <= 6'd0;
		end else if (do_reset) begin
			r_enable <= 1'b0;
			irq_status <= 3'd0;
			underflow <= 1'b0;
			flip_pending <= 1'b0;
			frame_count <= 32'd0;
			reset_left <= RESET_CYCLES;
		end else begin
			if (reset_left != 6'd0)
				reset_left <= reset_left - 6'd1;
			irq_status <= (irq_status & ~irq_clear) | irq_set;
			if (ev_underflow)
				underflow <= 1'b1;
			if (ev_vsync)
				frame_count <= frame_count + 32'd1;
			if (flip_now) begin
				r_fb_base <= r_fb_next;
				flip_pending <= 1'b0;
			end
			if (w_in) begin
				case (w_off)
				GHCI_DC_CTRL[6:0]: begin
					/* ENABLE rising clears the sticky underflow. */
					if (ctrl_new[GHCI_DC_CTRL_ENABLE] && !r_enable)
						underflow <= 1'b0;
					r_enable <= ctrl_new[GHCI_DC_CTRL_ENABLE];
					r_test <= ctrl_new[GHCI_DC_CTRL_TEST_PATTERN];
					r_format <= ctrl_new[GHCI_DC_CTRL_FORMAT +: 2];
					r_output <= ctrl_new[GHCI_DC_CTRL_OUTPUT];
				end
				GHCI_DC_IRQ_ENABLE[6:0]: irq_enable <= irq_enable_new[2:0];
				GHCI_DC_FB_NEXT[6:0]: begin
					r_fb_next <= fb_next_new;
					if (r_enable)
						flip_pending <= 1'b1;
					else
						r_fb_base <= fb_next_new;
				end
				GHCI_DC_FB_STRIDE[6:0]: r_stride <= ((r_stride) & ~wmask | wbits);
				GHCI_DC_FB_SIZE[6:0]: r_size <= ((r_size) & ~wmask | wbits);
				GHCI_DC_PCLK_SEL[6:0]: r_pclk_sel <= pclk_sel_new[0];
				default: ;
				endcase
				if (w_timing && w_off[1:0] == 2'd0)
					r_timing[w_tidx] <= ((r_timing[w_tidx]) & ~wmask | wbits);
			end
		end
	end

	/* Reads. */
	wire r_in = reg_raddr[16:7] == DISP[16:7];
	wire [6:0] r_off = reg_raddr[6:0];
	wire r_timing_hit = r_off >= GHCI_DC_TIMING[6:0] && r_off <= GHCI_DC_SYNC_POL[6:0] &&
		r_off[1:0] == 2'd0;
	wire [6:0] r_toff = r_off - GHCI_DC_TIMING[6:0];
	wire [3:0] r_tidx = r_toff[5:2];
	wire r_i2c = r_off[6:4] == GHCI_DC_I2C[6:4];
	reg [31:0] disp_rdata;
	reg [31:0] head_rdata;

	/* The I2C window: 0x60..0x6C (a write wins the index in its cycle). */
	assign i2c_we = w_in && w_off[6:4] == GHCI_DC_I2C[6:4];
	assign i2c_idx = i2c_we ? w_off[3:2] : r_off[3:2];
	assign i2c_wdata = reg_wdata;

	always @(*) begin
		case (r_off)
		GHCI_DC_ID[6:0]: disp_rdata = GHCI_DC_ID_VALUE;
		GHCI_DC_VERSION[6:0]: disp_rdata = DC_VERSION_VALUE;
		GHCI_DC_CAPS[6:0]: disp_rdata = DC_CAPS_VALUE;
		GHCI_DC_CTRL[6:0]: disp_rdata = ctrl_old;
		GHCI_DC_STATUS[6:0]: disp_rdata = {16'd0, line, 1'b0, !r_enable && dma_idle,
			underflow, r_enable};
		GHCI_DC_IRQ_STATUS[6:0]: disp_rdata = {29'd0, irq_status};
		GHCI_DC_IRQ_ENABLE[6:0]: disp_rdata = {29'd0, irq_enable};
		GHCI_DC_FB_BASE[6:0]: disp_rdata = r_fb_base;
		GHCI_DC_FB_NEXT[6:0]: disp_rdata = r_fb_next;
		GHCI_DC_FB_STRIDE[6:0]: disp_rdata = r_stride;
		GHCI_DC_FB_SIZE[6:0]: disp_rdata = r_size;
		GHCI_DC_FRAME_COUNT[6:0]: disp_rdata = frame_count;
		GHCI_DC_PCLK_SEL[6:0]: disp_rdata = {31'd0, r_pclk_sel};
		GHCI_DC_SCAN_SUM[6:0]: disp_rdata = scan_sum;
		GHCI_DC_SCAN_WORDS[6:0]: disp_rdata = scan_words;
		default:
			if (r_timing_hit)
				disp_rdata = timing[32*r_tidx +: 32];
			else if (r_i2c && HAS_I2C != 0)
				disp_rdata = i2c_rdata;
			else
				disp_rdata = 32'd0;
		endcase
	end

	/* The standalone GHCI header (docs/ghci.md section 12) and the DISP
	 * entry of the extended capability list. */
	always @(*) begin
		case (reg_raddr)
		GHCI_MAGIC: head_rdata = GHCI_MAGIC_VALUE;
		GHCI_VERSION: head_rdata = {GHCI_VERSION_MAJOR, GHCI_VERSION_MINOR};
		GHCI_VENDOR_ID: head_rdata = 32'h414D4154;	/* "AMAT" */
		GHCI_DEVICE_ID: head_rdata = GHCI_DC_ID_VALUE;
		GHCI_DEVICE_VERSION: head_rdata = DEVICE_VERSION_VALUE;
		GHCI_EXTCAP: head_rdata = {15'd0, LIST};
		GHCI_GCLK_HZ: head_rdata = GCLK_HZ_VALUE;
		GHCI_CAPS: head_rdata = 32'h00000008;	/* [3] only: a display controller here */
		LIST: head_rdata = {16'd0, 8'd1, GHCI_XCAP_DISP};
		LIST + 17'd4: head_rdata = {15'd0, DISP};
		default: head_rdata = 32'd0;
		endcase
	end

	always @(posedge clk) begin
		if (!rst_n)
			reg_rdata <= 32'd0;
		else if (reg_rd)
			reg_rdata <= r_in ? disp_rdata : (STANDALONE != 0 ? head_rdata : 32'd0);
	end

	wire unused_ok = &{1'b0, w_toff[6], w_toff[1:0], r_toff[6], r_toff[1:0],
		irq_enable_new[31:3], pclk_sel_new[31:1]};
endmodule

`default_nettype wire
