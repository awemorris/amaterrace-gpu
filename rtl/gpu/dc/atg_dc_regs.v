/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_dc_regs: the DC's scan-out registers of the DISP2 window
 * (docs/ghci.md section 13.2): DC_ID/VERSION/CAPS, CTRL, STATUS, FB_*,
 * the timing, FRAME_COUNT, PCLK_SEL, the I2C window and the vendor
 * SCAN_SUM/SCAN_WORDS; plane 0's pending flip; the events.  See
 * spec/gpu/dc/atg_dc_regs.md.
 *
 * The register bus is the DC's internal one (d_*): atg_cp_disp has
 * already decided who may write (the kinds of section 13.2), so every
 * write that reaches it is taken; a write takes effect in its cycle, the
 * read data is combinational from d_ridx and 0 for the words this module
 * does not hold (atg_dc ORs its children's).  CTRL.RESET (W1S) raises
 * dc_reset for RESET_CYCLES cycles and clears ENABLE, the sticky status,
 * FRAME_COUNT and plane 0's pending flip (taken as cancelled); the
 * configuration keeps its values.  A write of the timing, FB_STRIDE,
 * FB_SIZE or PCLK_SEL while ENABLE is 1, or of CTRL with another FORMAT
 * that keeps ENABLE 1, is refused (CTRL's other bits are taken) and sets
 * BAD_WRITE.
 *
 * Plane 0: a flip of the CP (flip_valid) or a host write of FB_NEXT makes
 * FB_NEXT pending while ENABLE is 1, taken at the next vsync; while ENABLE
 * is 0 (or falls in that cycle) it sets FB_BASE at once.  ENABLE falling
 * and CTRL.RESET take a pending flip as cancelled, and so does a host
 * write of FB_NEXT over a flip of the CP.  taken/taken_cancel pulse (the
 * cycle after) only for the CP's flips.
 *
 * DISP_ERROR (ev_error) pulses when one of the sticky errors is set: at
 * most once a frame while ENABLE is 1, at every error while it is 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_dc_regs #(
	parameter HAS_I2C = 0,	/* ADV7511 I2C master present (KC705, DC_CAPS[2]) */
	parameter HAS_CURSOR = 0,	/* the cursor plane (DC_CAPS[8]) */
	parameter MODES = 2	/* the modes of atg_dc_mode's table (DC_CAPS[11:9]) */
) (
	input wire clk,
	input wire rst_n,
	/* The DC's register bus (from atg_cp_disp) */
	input wire d_we,
	input wire [5:0] d_idx,
	input wire [31:0] d_wdata,
	input wire [31:0] d_wmask,
	input wire [5:0] d_ridx,
	output reg [31:0] d_rdata,
	/* Configuration to atg_dc_dma and atg_dc_tgen */
	output wire enable,
	output wire test_pattern,
	output wire [1:0] format,
	output wire [31:0] fb_base,
	output wire [31:0] fb_stride,
	output wire [31:0] fb_size,
	output wire [287:0] timing,
	output wire pclk_sel,
	output wire dc_reset,
	/* Plane 0's flips (from atg_cp_disp) */
	input wire flip_valid,
	input wire [31:0] flip_base,
	output reg taken,
	output reg taken_cancel,
	output wire pending,
	/* Status (gclk, already synchronised by atg_dc) */
	input wire ev_vsync,
	input wire ev_underflow,
	input wire idle_in,
	input wire [11:0] line,
	input wire [31:0] scan_sum,
	input wire [31:0] scan_words,
	input wire rd_err,
	input wire [1:0] dc_err,
	input wire connected,
	input wire pending1,
	/* Events (one-cycle pulses) and FRAME_COUNT */
	output wire ev_vblank,
	output reg ev_error,
	output wire [31:0] frame_count,
	/* I2C window (to atg_dc_i2c) */
	output wire i2c_we,
	output wire [1:0] i2c_idx,
	output wire [31:0] i2c_wdata,
	input wire [31:0] i2c_rdata
);
	`include "ghci_regs.vh"

	localparam [31:0] DC_VERSION_VALUE = 32'h00000002;	/* 0.2: DISP2 */
	/* DC_CAPS: [1] TMDS without the transmitter, [2] the transmitter with
	 * it; [7:4] formats 0..2; [8] the cursor plane; [11:9] the modes. */
	localparam [2:0] MODES_VALUE = MODES;
	localparam [31:0] DC_CAPS_VALUE = {20'd0, MODES_VALUE, HAS_CURSOR != 0, 4'b0111, 1'b0,
		HAS_I2C != 0 ? 3'b100 : 3'b010};
	localparam [5:0] RESET_CYCLES = 6'd32;
	localparam [5:0] I_CTRL = GHCI_DC_CTRL[7:2];
	localparam [5:0] I_STATUS = GHCI_DC_STATUS[7:2];
	localparam [5:0] I_FB_BASE = GHCI_DC_FB_BASE[7:2];
	localparam [5:0] I_FB_NEXT = GHCI_DC_FB_NEXT[7:2];
	localparam [5:0] I_FB_STRIDE = GHCI_DC_FB_STRIDE[7:2];
	localparam [5:0] I_FB_SIZE = GHCI_DC_FB_SIZE[7:2];
	localparam [5:0] I_TIMING = GHCI_DC_TIMING[7:2];
	localparam [5:0] I_SYNC_POL = GHCI_DC_SYNC_POL[7:2];
	localparam [5:0] I_FRAME_COUNT = GHCI_DC_FRAME_COUNT[7:2];
	localparam [5:0] I_PCLK_SEL = GHCI_DC_PCLK_SEL[7:2];
	localparam [5:0] I_I2C = GHCI_DC_I2C[7:2];
	localparam [5:0] I_SCAN_SUM = GHCI_DC_SCAN_SUM[7:2];
	localparam [5:0] I_SCAN_WORDS = GHCI_DC_SCAN_WORDS[7:2];

	reg r_enable, r_test, r_output;
	reg [1:0] r_format;
	reg [31:0] r_fb_base, r_fb_next, r_stride, r_size;
	reg [31:0] r_timing [0:8];
	reg [3:0] r_pclk_sel;
	reg st_underflow, st_rd_err, st_rec_err, st_bad;
	reg pend, pend_cp;
	reg err_frame;	/* DISP_ERROR was raised in this frame */
	reg [31:0] r_frame_count;
	reg [5:0] reset_left;

	assign enable = r_enable;
	assign test_pattern = r_test;
	assign format = r_format;
	assign fb_base = r_fb_base;
	assign fb_stride = r_stride;
	assign fb_size = r_size;
	assign pclk_sel = r_pclk_sel[0];
	assign dc_reset = reset_left != 6'd0;
	assign pending = pend;
	assign frame_count = r_frame_count;
	assign ev_vblank = ev_vsync && r_enable;

	genvar t;
	generate
	for (t = 0; t < 9; t = t + 1) begin : g_timing
		assign timing[32*t +: 32] = r_timing[t];
	end
	endgenerate

	/* Writes. */
	wire [31:0] wbits = d_wdata & d_wmask;
	wire w_timing = d_we && d_idx >= I_TIMING && d_idx <= I_SYNC_POL;
	wire [3:0] w_tidx;
	wire [3:0] idx_bo_unused;

	am_sub #(.W(4)) s_wtidx (.a(d_idx[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(w_tidx), .bo(idx_bo_unused[0]));
	wire w_quasi = w_timing || (d_we && (d_idx == I_FB_STRIDE || d_idx == I_FB_SIZE ||
		d_idx == I_PCLK_SEL));
	wire [31:0] ctrl_old = {25'd0, r_output, r_format, 1'b0, r_test, 1'b0, r_enable};
	wire [31:0] ctrl_new = (ctrl_old & ~d_wmask) | wbits;
	wire w_ctrl = d_we && d_idx == I_CTRL;
	wire do_reset = w_ctrl && ctrl_new[GHCI_DC_CTRL_RESET];
	/* A FORMAT change that keeps ENABLE 1 is refused (the rest of CTRL is taken). */
	wire fmt_bad = w_ctrl && r_enable && ctrl_new[GHCI_DC_CTRL_ENABLE] &&
		ctrl_new[GHCI_DC_CTRL_FORMAT +: 2] != r_format;
	wire quasi_bad = w_quasi && r_enable;
	wire en_fall = w_ctrl && r_enable && !ctrl_new[GHCI_DC_CTRL_ENABLE];
	wire en_eff = r_enable && !en_fall;	/* ENABLE after this cycle */
	wire w_next = d_we && d_idx == I_FB_NEXT;
	wire [31:0] next_new = (r_fb_next & ~d_wmask) | wbits;

	/* The reset's countdown and the vsync count. */
	wire [5:0] reset_dec;
	wire [31:0] frame_inc;

	am_sub #(.W(6)) s_reset (.a(reset_left), .b(6'd0), .bi(1'b1), .d(reset_dec), .bo(idx_bo_unused[1]));
	am_add #(.W(32)) a_frame (.a(r_frame_count), .b(32'd0), .ci(1'b1), .s(frame_inc), .co(idx_bo_unused[2]));
	wire w_status = d_we && d_idx == I_STATUS;
	wire [3:0] st_clear = w_status ? {wbits[GHCI_DC_ST_BAD_WRITE], wbits[GHCI_DC_ST_RECORD_ERROR],
		wbits[GHCI_DC_ST_READ_ERROR], wbits[GHCI_DC_ST_UNDERFLOW]} : 4'd0;
	wire bad_now = dc_err[1] || fmt_bad || quasi_bad;
	wire err_now = ev_underflow || rd_err || dc_err[0] || bad_now;

	integer k;

	always @(posedge clk) begin
		taken <= 1'b0;
		taken_cancel <= 1'b0;
		ev_error <= 1'b0;
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
			r_pclk_sel <= 4'd0;
			st_underflow <= 1'b0;
			st_rd_err <= 1'b0;
			st_rec_err <= 1'b0;
			st_bad <= 1'b0;
			pend <= 1'b0;
			pend_cp <= 1'b0;
			err_frame <= 1'b0;
			r_frame_count <= 32'd0;
			reset_left <= 6'd0;
		end else if (do_reset) begin
			r_enable <= 1'b0;
			st_underflow <= 1'b0;
			st_rd_err <= 1'b0;
			st_rec_err <= 1'b0;
			st_bad <= 1'b0;
			err_frame <= 1'b0;
			r_frame_count <= 32'd0;
			reset_left <= RESET_CYCLES;
			pend <= 1'b0;
			if (pend && pend_cp) begin
				taken <= 1'b1;
				taken_cancel <= 1'b1;
			end
		end else begin
			if (reset_left != 6'd0)
				reset_left <= reset_dec;
			/* The sticky status and DISP_ERROR. */
			st_underflow <= (st_underflow && !st_clear[0]) || ev_underflow;
			st_rd_err <= (st_rd_err && !st_clear[1]) || rd_err;
			st_rec_err <= (st_rec_err && !st_clear[2]) || dc_err[0];
			st_bad <= (st_bad && !st_clear[3]) || bad_now;
			if (err_now && !err_frame) begin
				ev_error <= 1'b1;
				err_frame <= r_enable;
			end else if (ev_vsync || !r_enable) begin
				err_frame <= 1'b0;
			end
			if (ev_vsync)
				r_frame_count <= frame_inc;
			/* Plane 0. */
			if (en_fall && pend) begin
				pend <= 1'b0;
				if (pend_cp) begin
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end
			end else if (flip_valid) begin
				if (!en_eff) begin
					r_fb_base <= flip_base;
					taken <= 1'b1;
				end else begin
					r_fb_next <= flip_base;
					pend <= 1'b1;
					pend_cp <= 1'b1;
				end
			end else if (w_next) begin
				r_fb_next <= next_new;
				if (pend && pend_cp) begin
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end
				if (!en_eff) begin
					r_fb_base <= next_new;
					pend <= 1'b0;
				end else begin
					pend <= 1'b1;
					pend_cp <= 1'b0;
				end
			end else if (ev_vsync && pend) begin
				r_fb_base <= r_fb_next;
				pend <= 1'b0;
				if (pend_cp)
					taken <= 1'b1;
			end
			if (w_ctrl) begin
				/* ENABLE rising clears the sticky underflow. */
				if (ctrl_new[GHCI_DC_CTRL_ENABLE] && !r_enable)
					st_underflow <= 1'b0;
				r_enable <= ctrl_new[GHCI_DC_CTRL_ENABLE];
				r_test <= ctrl_new[GHCI_DC_CTRL_TEST_PATTERN];
				if (!fmt_bad)
					r_format <= ctrl_new[GHCI_DC_CTRL_FORMAT +: 2];
				r_output <= ctrl_new[GHCI_DC_CTRL_OUTPUT];
			end
			if (!quasi_bad) begin
				if (d_we && d_idx == I_FB_STRIDE)
					r_stride <= (r_stride & ~d_wmask) | wbits;
				if (d_we && d_idx == I_FB_SIZE)
					r_size <= (r_size & ~d_wmask) | wbits;
				if (d_we && d_idx == I_PCLK_SEL)
					r_pclk_sel <= (r_pclk_sel & ~d_wmask[3:0]) | wbits[3:0];
				if (w_timing)
					r_timing[w_tidx] <= (r_timing[w_tidx] & ~d_wmask) | wbits;
			end
		end
	end

	/* The I2C window 0x60..0x68 (a write wins the index in its cycle). */
	assign i2c_we = d_we && d_idx[5:2] == I_I2C[5:2] && d_idx[1:0] != 2'd3;
	assign i2c_idx = i2c_we ? d_idx[1:0] : d_ridx[1:0];
	assign i2c_wdata = d_wdata;

	/* Reads. */
	wire r_timing_hit = d_ridx >= I_TIMING && d_ridx <= I_SYNC_POL;
	wire [3:0] r_tidx;

	am_sub #(.W(4)) s_rtidx (.a(d_ridx[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx), .bo(idx_bo_unused[3]));
	wire r_i2c = d_ridx[5:2] == I_I2C[5:2] && d_ridx[1:0] != 2'd3;

	always @(*) begin
		case (d_ridx)
		GHCI_DC_ID[7:2]: d_rdata = GHCI_DC_ID_VALUE;
		GHCI_DC_VERSION[7:2]: d_rdata = DC_VERSION_VALUE;
		GHCI_DC_CAPS[7:2]: d_rdata = DC_CAPS_VALUE;
		I_CTRL: d_rdata = ctrl_old;
		I_STATUS: d_rdata = {1'b0, pending1, pend, connected, line, 10'd0, st_bad,
			st_rec_err, st_rd_err, !r_enable && idle_in, st_underflow, r_enable};
		I_FB_BASE: d_rdata = r_fb_base;
		I_FB_NEXT: d_rdata = r_fb_next;
		I_FB_STRIDE: d_rdata = r_stride;
		I_FB_SIZE: d_rdata = r_size;
		I_FRAME_COUNT: d_rdata = r_frame_count;
		I_PCLK_SEL: d_rdata = {28'd0, r_pclk_sel};
		I_SCAN_SUM: d_rdata = scan_sum;
		I_SCAN_WORDS: d_rdata = scan_words;
		default:
			if (r_timing_hit)
				d_rdata = timing[32*r_tidx +: 32];
			else if (r_i2c && HAS_I2C != 0)
				d_rdata = i2c_rdata;
			else
				d_rdata = 32'd0;
		endcase
	end
endmodule

`default_nettype wire
