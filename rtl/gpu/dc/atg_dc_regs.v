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
	output wire [31:0] d_rdata,
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
	output wire irq_display,
	/* I2C window (to atg_dc_i2c) */
	output wire i2c_we,
	output wire [1:0] i2c_idx,
	output wire [31:0] i2c_wdata,
	input wire [31:0] i2c_rdata,
	/* Extended WSI / HDR / VRR / Plane2 outputs */
	output wire hdr_en,
	output wire vrr_en,
	output wire [11:0] vrr_vmax,
	output wire flip_ready,
	output wire plane2_en,
	output wire [11:0] plane2_pos_x,
	output wire [11:0] plane2_pos_y,
	output wire [11:0] plane2_width,
	output wire [11:0] plane2_height,
	output wire [7:0]  plane2_alpha,
	output wire        plane2_colorkey_en,
	output wire [23:0] plane2_colorkey,
	output wire        plane2_yuv_mode
);
	`include "ghci_regs.vh"

	localparam [31:0] DC_VERSION_VALUE = 32'h00000002;	/* 0.2: DISP2 */
	/* DC_CAPS: [1] TMDS without the transmitter, [2] the transmitter with
	 * it; [7:4] formats 0..2; [8] the cursor plane; [11:9] the modes. */
	localparam [2:0] MODES_VALUE = MODES;
	localparam [31:0] DC_CAPS_VALUE = {16'd0, 1'b1, 1'b1, 1'b1, 1'b0, MODES_VALUE, HAS_CURSOR != 0, 4'b1111, 1'b0,
		HAS_I2C != 0 ? 3'b100 : 3'b010};
	localparam [5:0] RESET_CYCLES = 6'd32;
	localparam [5:0] I_CTRL = GHCI_DC_CTRL[7:2];
	localparam [5:0] I_STATUS = GHCI_DC_STATUS[7:2];
	localparam [5:0] I_DC_IRQ_STATUS = GHCI_DC_IRQ_STATUS[7:2];
	localparam [5:0] I_DC_IRQ_ENABLE = GHCI_DC_IRQ_ENABLE[7:2];
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

`ifdef SYNTH_KINTEX7
	(* keep = "true", DONT_TOUCH = "TRUE" *) wire regs_rst_high;
	LUT1 #(.INIT(2'b01)) u_regs_rst (.I0(rst_n), .O(regs_rst_high));
	wire rst_high = regs_rst_high;

	(* keep = "true", DONT_TOUCH = "TRUE" *) wire regs_dc_rst;
	LUT2 #(.INIT(4'b1110)) u_buf_dcrst (.I0(regs_rst_high), .I1(do_reset), .O(regs_dc_rst));
	wire dc_regs_rst = regs_dc_rst;

	wire [31:0] d_wdata_b0, d_wdata_b1, d_wdata_b2;
	wire [31:0] d_wmask_b0, d_wmask_b1, d_wmask_b2;
	genvar gwd;
	generate
		for (gwd = 0; gwd < 32; gwd = gwd + 1) begin : g_wdata_tree
			LUT1 #(.INIT(2'b10)) u_wd0 (.I0(d_wdata[gwd]), .O(d_wdata_b0[gwd]));
			LUT1 #(.INIT(2'b10)) u_wd1 (.I0(d_wdata[gwd]), .O(d_wdata_b1[gwd]));
			LUT1 #(.INIT(2'b10)) u_wd2 (.I0(d_wdata[gwd]), .O(d_wdata_b2[gwd]));
			LUT1 #(.INIT(2'b10)) u_wm0 (.I0(d_wmask[gwd]), .O(d_wmask_b0[gwd]));
			LUT1 #(.INIT(2'b10)) u_wm1 (.I0(d_wmask[gwd]), .O(d_wmask_b1[gwd]));
			LUT1 #(.INIT(2'b10)) u_wm2 (.I0(d_wmask[gwd]), .O(d_wmask_b2[gwd]));
		end
	endgenerate

	wire [5:0] idx_ctl, idx_cfg;
	wire [5:0] idx_ext_l, idx_ext_h;
	genvar gidx;
	generate
		for (gidx = 0; gidx < 6; gidx = gidx + 1) begin : g_idx_buf
			LUT1 #(.INIT(2'b10)) u_buf_ict (.I0(d_idx[gidx]), .O(idx_ctl[gidx]));
			LUT1 #(.INIT(2'b10)) u_buf_icf (.I0(d_idx[gidx]), .O(idx_cfg[gidx]));
			LUT1 #(.INIT(2'b10)) u_buf_iel (.I0(d_idx[gidx]), .O(idx_ext_l[gidx]));
			LUT1 #(.INIT(2'b10)) u_buf_ieh (.I0(d_idx[gidx]), .O(idx_ext_h[gidx]));
		end
	endgenerate
	wire d_we_ctl, d_we_cfg, d_we_cfg_l, d_we_cfg_h, d_we_ext_l, d_we_ext_h;
	LUT1 #(.INIT(2'b10)) u_buf_wect (.I0(d_we), .O(d_we_ctl));
	LUT1 #(.INIT(2'b10)) u_buf_wecf (.I0(d_we), .O(d_we_cfg));
	LUT1 #(.INIT(2'b10)) u_buf_wecl (.I0(d_we), .O(d_we_cfg_l));
	LUT1 #(.INIT(2'b10)) u_buf_wech (.I0(d_we), .O(d_we_cfg_h));
	LUT1 #(.INIT(2'b10)) u_buf_weel (.I0(d_we), .O(d_we_ext_l));
	LUT1 #(.INIT(2'b10)) u_buf_weeh (.I0(d_we), .O(d_we_ext_h));
	wire flip_valid_b0, flip_valid_b1, flip_valid_n0, flip_valid_n1, flip_valid_ctl;
	LUT1 #(.INIT(2'b10)) u_buf_fvb0 (.I0(flip_valid), .O(flip_valid_b0));
	LUT1 #(.INIT(2'b10)) u_buf_fvb1 (.I0(flip_valid), .O(flip_valid_b1));
	LUT1 #(.INIT(2'b10)) u_buf_fvn0 (.I0(flip_valid), .O(flip_valid_n0));
	LUT1 #(.INIT(2'b10)) u_buf_fvn1 (.I0(flip_valid), .O(flip_valid_n1));
	LUT1 #(.INIT(2'b10)) u_buf_fvct (.I0(flip_valid), .O(flip_valid_ctl));
	wire w_next_l, w_next_h, w_next_ctl;
	LUT1 #(.INIT(2'b10)) u_buf_wnl (.I0(w_next), .O(w_next_l));
	LUT1 #(.INIT(2'b10)) u_buf_wnh (.I0(w_next), .O(w_next_h));
	LUT1 #(.INIT(2'b10)) u_buf_wnc (.I0(w_next), .O(w_next_ctl));
`else
	(* keep = "true" *) wire rst_high = !rst_n;
	(* keep = "true" *) wire dc_regs_rst = rst_high || do_reset;
	wire [31:0] d_wdata_b0 = d_wdata, d_wdata_b1 = d_wdata, d_wdata_b2 = d_wdata;
	wire [31:0] d_wmask_b0 = d_wmask, d_wmask_b1 = d_wmask, d_wmask_b2 = d_wmask;
	wire [5:0] idx_ctl = d_idx, idx_cfg = d_idx;
	wire [5:0] idx_ext_l = d_idx, idx_ext_h = d_idx;
	wire d_we_ctl = d_we, d_we_cfg = d_we, d_we_cfg_l = d_we, d_we_cfg_h = d_we;
	wire d_we_ext_l = d_we, d_we_ext_h = d_we;
	wire flip_valid_b0 = flip_valid, flip_valid_b1 = flip_valid;
	wire flip_valid_n0 = flip_valid, flip_valid_n1 = flip_valid;
	wire flip_valid_ctl = flip_valid;
	wire w_next_l = w_next, w_next_h = w_next, w_next_ctl = w_next;
`endif
	wire [5:0] idx = idx_ctl;
	localparam [5:0] I_PLANE2_BASE = GHCI_DC_PLANE2_BASE[7:2];
	localparam [5:0] I_PLANE2_POS = GHCI_DC_PLANE2_POS[7:2];
	localparam [5:0] I_PLANE2_SIZE = GHCI_DC_PLANE2_SIZE[7:2];
	localparam [5:0] I_PLANE2_CTRL = GHCI_DC_PLANE2_CTRL[7:2];
	localparam [5:0] I_PLANE2_COLORKEY = GHCI_DC_PLANE2_COLORKEY[7:2];
	localparam [5:0] I_VRR_CTRL = GHCI_DC_VRR_CTRL[7:2];
	localparam [5:0] I_HDR_CTRL = GHCI_DC_HDR_CTRL[7:2];
	localparam [5:0] I_FLIP_READY = GHCI_DC_FLIP_READY[7:2];

	reg r_enable, r_test, r_output;
	reg [1:0] r_format;
	reg [15:0] r_fb_base_lo, r_fb_base_hi;
	wire [31:0] r_fb_base = {r_fb_base_hi, r_fb_base_lo};
	reg [15:0] r_fb_next_lo, r_fb_next_hi;
	wire [31:0] r_fb_next = {r_fb_next_hi, r_fb_next_lo};
	reg [15:0] r_stride_lo, r_stride_hi;
	wire [31:0] r_stride = {r_stride_hi, r_stride_lo};
	reg [15:0] r_size_lo, r_size_hi;
	wire [31:0] r_size = {r_size_hi, r_size_lo};
	reg [15:0] r_timing_lo [0:8], r_timing_hi [0:8];
	wire [31:0] r_timing [0:8];
	wire [143:0] timing_lo;
	wire [143:0] timing_hi;
	genvar gti;
	generate
		for (gti = 0; gti < 9; gti = gti + 1) begin : g_tim
			assign r_timing[gti] = {r_timing_hi[gti], r_timing_lo[gti]};
			assign timing_lo[16*gti +: 16] = r_timing_lo[gti];
			assign timing_hi[16*gti +: 16] = r_timing_hi[gti];
		end
	endgenerate
	reg [3:0] r_pclk_sel;
	reg st_underflow, st_rd_err, st_rec_err, st_bad;
	reg pend, pend_cp;
	reg err_frame;	/* DISP_ERROR was raised in this frame */
	reg [15:0] r_frame_count_lo, r_frame_count_hi;
	wire [31:0] r_frame_count = {r_frame_count_hi, r_frame_count_lo};
	reg [5:0] reset_left;

	reg r_hdr_en, r_vrr_en, r_plane2_en;
	reg [15:0] r_plane2_base_lo, r_plane2_base_hi;
	wire [31:0] r_plane2_base = {r_plane2_base_hi, r_plane2_base_lo};
	reg [15:0] r_plane2_pos_lo, r_plane2_pos_hi;
	wire [31:0] r_plane2_pos = {r_plane2_pos_hi, r_plane2_pos_lo};
	reg [15:0] r_plane2_size_lo, r_plane2_size_hi;
	wire [31:0] r_plane2_size = {r_plane2_size_hi, r_plane2_size_lo};
	reg [15:0] r_plane2_ctrl_lo, r_plane2_ctrl_hi;
	wire [31:0] r_plane2_ctrl = {r_plane2_ctrl_hi, r_plane2_ctrl_lo};
	reg [15:0] r_plane2_colorkey_lo, r_plane2_colorkey_hi;
	wire [31:0] r_plane2_colorkey = {r_plane2_colorkey_hi, r_plane2_colorkey_lo};
	reg [15:0] r_vrr_ctrl_lo, r_vrr_ctrl_hi;
	wire [31:0] r_vrr_ctrl = {r_vrr_ctrl_hi, r_vrr_ctrl_lo};
	reg [15:0] r_hdr_ctrl_lo, r_hdr_ctrl_hi;
	wire [31:0] r_hdr_ctrl = {r_hdr_ctrl_hi, r_hdr_ctrl_lo};
	reg r_flip_ready;

	reg [5:0] disp_irq_status;
	reg [5:0] disp_irq_enable;
	(* keep = "true" *) reg connected_q;
	(* keep = "true" *) reg ev_hotplug_q;
	assign irq_display = |(disp_irq_status & disp_irq_enable);

	assign enable = r_enable;
	assign test_pattern = r_test;
	assign format = r_format;
	assign fb_base = r_fb_base;
	assign fb_stride = r_stride;
	assign fb_size = r_size;
	assign pclk_sel = r_pclk_sel[0];
	wire [31:0] wbits_ctl = d_wdata_b0 & d_wmask_b0;
	wire [31:0] wbits_cfg = d_wdata_b1 & d_wmask_b1;
	wire [31:0] wbits_ext = d_wdata_b2 & d_wmask_b2;
	wire [31:0] d_wmask_cfg = d_wmask_b1;
	wire [31:0] d_wmask_ext = d_wmask_b2;
	wire [31:0] wbits = wbits_ctl;
	wire [31:0] ctrl_old = {22'd0, r_plane2_en, r_vrr_en, r_hdr_en, r_output, r_format, 1'b0, r_test, 1'b0, r_enable};
	wire [31:0] ctrl_new = (ctrl_old & ~d_wmask_b0) | wbits_ctl;
	wire w_ctrl = d_we && idx == I_CTRL;
	wire do_reset = w_ctrl && d_wmask[GHCI_DC_CTRL_RESET] && d_wdata[GHCI_DC_CTRL_RESET];

	(* keep = "true" *) reg dc_reset_q;
	always @(posedge clk) begin
		if (rst_high)
			dc_reset_q <= 1'b0;
		else
			dc_reset_q <= (reset_left != 6'd0) || do_reset;
	end
	assign dc_reset = dc_reset_q;
	assign pending = pend;
	assign frame_count = r_frame_count;
	assign ev_vblank = ev_vsync && r_enable;

	assign hdr_en = r_hdr_en || r_hdr_ctrl[0] || (r_format == GHCI_DC_FMT_A2B10G10R10);
	assign vrr_en = r_vrr_en || r_vrr_ctrl[0];
	assign vrr_vmax = r_vrr_ctrl[27:16];
	assign flip_ready = r_flip_ready;
	assign plane2_en = r_plane2_en || r_plane2_ctrl[0];
	assign plane2_pos_x = r_plane2_pos[11:0];
	assign plane2_pos_y = r_plane2_pos[27:16];
	assign plane2_width = r_plane2_size[11:0];
	assign plane2_height = r_plane2_size[27:16];
	assign plane2_alpha = r_plane2_ctrl[15:8];
	assign plane2_colorkey_en = r_plane2_ctrl[16];
	assign plane2_yuv_mode = r_plane2_ctrl[17];
	assign plane2_colorkey = r_plane2_colorkey[23:0];

	genvar t;
	generate
	for (t = 0; t < 9; t = t + 1) begin : g_timing
		assign timing[32*t +: 32] = r_timing[t];
	end
	endgenerate

	wire w_timing = d_we_cfg && idx_cfg >= I_TIMING && idx_cfg <= I_SYNC_POL;
	genvar gtw;
	generate
		for (gtw = 0; gtw < 9; gtw = gtw + 1) begin : g_twrite
			wire we_t_l = d_we_cfg_l && (idx_cfg == (I_TIMING + gtw));
			wire we_t_h = d_we_cfg_h && (idx_cfg == (I_TIMING + gtw));
			always @(posedge clk) begin
				if (rst_high) begin
					r_timing_lo[gtw] <= 16'd0;
					r_timing_hi[gtw] <= 16'd0;
				end else begin
					if (we_t_l)
						r_timing_lo[gtw] <= (r_timing_lo[gtw] & ~d_wmask_cfg[15:0])  | wbits_cfg[15:0];
					if (we_t_h)
						r_timing_hi[gtw] <= (r_timing_hi[gtw] & ~d_wmask_cfg[31:16]) | wbits_cfg[31:16];
				end
			end
		end
	endgenerate
	wire [11:0] idx_bo_unused;
	wire w_quasi = w_timing || (d_we_cfg && (idx_cfg == I_FB_STRIDE || idx_cfg == I_FB_SIZE ||
		idx_cfg == I_PCLK_SEL));
	/* A FORMAT change that keeps ENABLE 1 is refused (the rest of CTRL is taken). */
	wire fmt_bad = w_ctrl && r_enable && ctrl_new[GHCI_DC_CTRL_ENABLE] &&
		ctrl_new[GHCI_DC_CTRL_FORMAT +: 2] != r_format;
	wire quasi_bad = w_quasi && r_enable;
	wire en_fall = w_ctrl && r_enable && !ctrl_new[GHCI_DC_CTRL_ENABLE];
	wire en_eff = r_enable && !en_fall;	/* ENABLE after this cycle */

`ifdef SYNTH_KINTEX7
	wire en_eff_blo, en_eff_bhi, en_eff_nlo, en_eff_nhi, en_eff_ctl;
	LUT1 #(.INIT(2'b10)) u_buf_ebl (.I0(en_eff), .O(en_eff_blo));
	LUT1 #(.INIT(2'b10)) u_buf_ebh (.I0(en_eff), .O(en_eff_bhi));
	LUT1 #(.INIT(2'b10)) u_buf_enl (.I0(en_eff), .O(en_eff_nlo));
	LUT1 #(.INIT(2'b10)) u_buf_enh (.I0(en_eff), .O(en_eff_nhi));
	LUT1 #(.INIT(2'b10)) u_buf_ect (.I0(en_eff), .O(en_eff_ctl));
`else
	wire en_eff_blo = en_eff, en_eff_bhi = en_eff, en_eff_nlo = en_eff, en_eff_nhi = en_eff, en_eff_ctl = en_eff;
`endif

	wire w_next = d_we_cfg && idx_cfg == I_FB_NEXT;
	wire [31:0] next_new = (r_fb_next & ~d_wmask_cfg) | wbits_cfg;

	/* The reset's countdown and the vsync count. */
	wire [5:0] reset_dec;
	wire [15:0] frame_inc_lo, frame_inc_hi;
	wire frame_co_lo;

	am_sub #(.W(6)) s_reset (.a(reset_left), .b(6'd0), .bi(1'b1), .d(reset_dec), .bo(idx_bo_unused[2]));
	am_add #(.W(16)) a_frame_l (.a(r_frame_count_lo), .b(16'd0), .ci(1'b1), .s(frame_inc_lo), .co(frame_co_lo));
	am_add #(.W(16)) a_frame_h (.a(r_frame_count_hi), .b(16'd0), .ci(frame_co_lo), .s(frame_inc_hi), .co(idx_bo_unused[3]));

`ifdef SYNTH_KINTEX7
	wire ev_vsync_lo, ev_vsync_hi;
	LUT1 #(.INIT(2'b10)) u_buf_vsl (.I0(ev_vsync), .O(ev_vsync_lo));
	LUT1 #(.INIT(2'b10)) u_buf_vsh (.I0(ev_vsync), .O(ev_vsync_hi));
`else
	wire ev_vsync_lo = ev_vsync;
	wire ev_vsync_hi = ev_vsync;
`endif

	always @(posedge clk) begin
		if (dc_regs_rst)
			r_frame_count_lo <= 16'd0;
		else if (ev_vsync_lo)
			r_frame_count_lo <= frame_inc_lo;
	end

	always @(posedge clk) begin
		if (dc_regs_rst)
			r_frame_count_hi <= 16'd0;
		else if (ev_vsync_hi)
			r_frame_count_hi <= frame_inc_hi;
	end
	wire w_status = d_we && idx == I_STATUS;
	wire [3:0] st_clear = w_status ? {wbits[GHCI_DC_ST_BAD_WRITE], wbits[GHCI_DC_ST_RECORD_ERROR],
		wbits[GHCI_DC_ST_READ_ERROR], wbits[GHCI_DC_ST_UNDERFLOW]} : 4'd0;
	wire bad_now = dc_err[1] || fmt_bad || quasi_bad;
	wire err_now = ev_underflow || rd_err || dc_err[0] || bad_now;
	wire ev_hotplug_pulse = connected ^ connected_q;
	wire [5:0] disp_ev = {
		err_now,
		ev_underflow,
		ev_hotplug_q,
		1'b0,
		taken && !taken_cancel,
		ev_vsync && r_enable
	};

	integer k;

	always @(posedge clk) begin
		taken <= 1'b0;
		taken_cancel <= 1'b0;
		ev_error <= 1'b0;
		if (rst_high) begin
			r_enable <= 1'b0;
			r_test <= 1'b0;
			r_output <= 1'b0;
			r_format <= 2'd0;
			r_fb_base_lo <= 16'd0; r_fb_base_hi <= 16'd0;
			r_fb_next_lo <= 16'd0; r_fb_next_hi <= 16'd0;
			r_stride_lo <= 16'd0; r_stride_hi <= 16'd0;
			r_size_lo <= 16'd0; r_size_hi <= 16'd0;

			r_pclk_sel <= 4'd0;
			st_underflow <= 1'b0;
			st_rd_err <= 1'b0;
			st_rec_err <= 1'b0;
			st_bad <= 1'b0;
			pend <= 1'b0;
			pend_cp <= 1'b0;
			err_frame <= 1'b0;
			reset_left <= 6'd0;
			r_hdr_en <= 1'b0;
			r_vrr_en <= 1'b0;
			r_plane2_en <= 1'b0;
			r_plane2_base_lo <= 16'd0; r_plane2_base_hi <= 16'd0;
			r_plane2_pos_lo <= 16'd0; r_plane2_pos_hi <= 16'd0;
			r_plane2_size_lo <= 16'd0; r_plane2_size_hi <= 16'd0;
			r_plane2_ctrl_lo <= 16'd0; r_plane2_ctrl_hi <= 16'd0;
			r_plane2_colorkey_lo <= 16'd0; r_plane2_colorkey_hi <= 16'd0;
			r_vrr_ctrl_lo <= 16'd0; r_vrr_ctrl_hi <= 16'd0;
			r_hdr_ctrl_lo <= 16'd0; r_hdr_ctrl_hi <= 16'd0;
			r_flip_ready <= 1'b0;
			disp_irq_status <= 6'd0;
			disp_irq_enable <= 6'd0;
			connected_q <= 1'b0;
			ev_hotplug_q <= 1'b0;
		end else if (do_reset) begin
			r_enable <= 1'b0;
			st_underflow <= 1'b0;
			st_rd_err <= 1'b0;
			st_rec_err <= 1'b0;
			st_bad <= 1'b0;
			err_frame <= 1'b0;
			reset_left <= RESET_CYCLES;
			pend <= 1'b0;
			disp_irq_status <= 6'd0;
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
			connected_q <= connected;
			ev_hotplug_q <= ev_hotplug_pulse;
			disp_irq_status <= (disp_irq_status & ~(d_we && idx == I_DC_IRQ_STATUS ? wbits[5:0] : 6'd0)) | disp_ev;
			if (d_we && idx == I_DC_IRQ_ENABLE)
				disp_irq_enable <= (disp_irq_enable & ~d_wmask[5:0]) | wbits[5:0];
			/* Plane 0. */
			if (en_fall && pend) begin
				pend <= 1'b0;
				if (pend_cp) begin
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end
			end else if (flip_valid_ctl) begin
				if (!en_eff_ctl) begin
					taken <= 1'b1;
				end else begin
					pend <= 1'b1;
					pend_cp <= 1'b1;
				end
			end else if (w_next_ctl) begin
				if (pend && pend_cp) begin
					taken <= 1'b1;
					taken_cancel <= 1'b1;
				end
				if (!en_eff_ctl) begin
					pend <= 1'b0;
				end else begin
					pend <= 1'b1;
					pend_cp <= 1'b0;
				end
			end else if (ev_vsync && pend) begin
				r_fb_base_lo <= r_fb_next_lo;
				r_fb_base_hi <= r_fb_next_hi;
				pend <= 1'b0;
				if (pend_cp)
					taken <= 1'b1;
			end

			if (flip_valid_b0 && !en_eff_blo)
				r_fb_base_lo <= flip_base[15:0];
			else if (w_next_l && !en_eff_blo)
				r_fb_base_lo <= next_new[15:0];

			if (flip_valid_b1 && !en_eff_bhi)
				r_fb_base_hi <= flip_base[31:16];
			else if (w_next_h && !en_eff_bhi)
				r_fb_base_hi <= next_new[31:16];

			if (flip_valid_n0 && en_eff_nlo)
				r_fb_next_lo <= flip_base[15:0];
			else if (w_next_l)
				r_fb_next_lo <= next_new[15:0];

			if (flip_valid_n1 && en_eff_nhi)
				r_fb_next_hi <= flip_base[31:16];
			else if (w_next_h)
				r_fb_next_hi <= next_new[31:16];

			r_flip_ready <= (d_we && idx == I_FLIP_READY && wbits[0]) || flip_valid_ctl || w_next_ctl;
			if (w_ctrl) begin
				/* ENABLE rising clears the sticky underflow. */
				if (ctrl_new[GHCI_DC_CTRL_ENABLE] && !r_enable)
					st_underflow <= 1'b0;
				r_enable <= ctrl_new[GHCI_DC_CTRL_ENABLE];
				r_test <= ctrl_new[GHCI_DC_CTRL_TEST_PATTERN];
				if (!fmt_bad)
					r_format <= ctrl_new[GHCI_DC_CTRL_FORMAT +: 2];
				r_output <= ctrl_new[GHCI_DC_CTRL_OUTPUT];
				r_hdr_en <= ctrl_new[GHCI_DC_CTRL_HDR];
				r_vrr_en <= ctrl_new[GHCI_DC_CTRL_VRR];
				r_plane2_en <= ctrl_new[GHCI_DC_CTRL_PLANE2];
			end
			if (d_we_ext_l && idx_ext_l == I_PLANE2_BASE)
				r_plane2_base_lo <= (r_plane2_base_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_PLANE2_BASE)
				r_plane2_base_hi <= (r_plane2_base_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_PLANE2_POS)
				r_plane2_pos_lo <= (r_plane2_pos_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_PLANE2_POS)
				r_plane2_pos_hi <= (r_plane2_pos_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_PLANE2_SIZE)
				r_plane2_size_lo <= (r_plane2_size_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_PLANE2_SIZE)
				r_plane2_size_hi <= (r_plane2_size_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_PLANE2_CTRL)
				r_plane2_ctrl_lo <= (r_plane2_ctrl_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_PLANE2_CTRL)
				r_plane2_ctrl_hi <= (r_plane2_ctrl_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_PLANE2_COLORKEY)
				r_plane2_colorkey_lo <= (r_plane2_colorkey_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_PLANE2_COLORKEY)
				r_plane2_colorkey_hi <= (r_plane2_colorkey_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_VRR_CTRL)
				r_vrr_ctrl_lo <= (r_vrr_ctrl_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_VRR_CTRL)
				r_vrr_ctrl_hi <= (r_vrr_ctrl_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (d_we_ext_l && idx_ext_l == I_HDR_CTRL)
				r_hdr_ctrl_lo <= (r_hdr_ctrl_lo & ~d_wmask_ext[15:0])  | wbits_ext[15:0];
			if (d_we_ext_h && idx_ext_h == I_HDR_CTRL)
				r_hdr_ctrl_hi <= (r_hdr_ctrl_hi & ~d_wmask_ext[31:16]) | wbits_ext[31:16];

			if (!quasi_bad) begin
				if (d_we_cfg_l && idx_cfg == I_FB_STRIDE)
					r_stride_lo <= (r_stride_lo & ~d_wmask_cfg[15:0])  | wbits_cfg[15:0];
				if (d_we_cfg_h && idx_cfg == I_FB_STRIDE)
					r_stride_hi <= (r_stride_hi & ~d_wmask_cfg[31:16]) | wbits_cfg[31:16];

				if (d_we_cfg_l && idx_cfg == I_FB_SIZE)
					r_size_lo <= (r_size_lo & ~d_wmask_cfg[15:0])  | wbits_cfg[15:0];
				if (d_we_cfg_h && idx_cfg == I_FB_SIZE)
					r_size_hi <= (r_size_hi & ~d_wmask_cfg[31:16]) | wbits_cfg[31:16];

				if (d_we_cfg && idx_cfg == I_PCLK_SEL)
					r_pclk_sel <= (r_pclk_sel & ~d_wmask_cfg[3:0]) | wbits_cfg[3:0];


			end
		end
	end

	/* The I2C window 0x60..0x68 (a write wins the index in its cycle). */
	assign i2c_we = d_we && idx[5:2] == I_I2C[5:2] && idx[1:0] != 2'd3;
	assign i2c_idx = i2c_we ? idx[1:0] : d_ridx[1:0];
	assign i2c_wdata = d_wdata;

	/* Reads: Split into 16-bit low and high halves with buffered indices to limit fanout. */
`ifdef SYNTH_KINTEX7
	wire [5:0] ridx_b0_lo, ridx_b0_mid, ridx_b0_tl, ridx_b0_th, ridx_b0_hi;
	wire [5:0] ridx_b1_lo, ridx_b1_mid, ridx_b1_tl, ridx_b1_th, ridx_b1_hi;
	wire [5:0] ridx_b2_lo, ridx_b2_mid, ridx_b2_tl, ridx_b2_th, ridx_b2_hi;
	wire [5:0] ridx_b3_lo, ridx_b3_mid, ridx_b3_tl, ridx_b3_th, ridx_b3_hi;
	genvar gri;
	generate
		for (gri = 0; gri < 6; gri = gri + 1) begin : g_ridx_buf
			LUT1 #(.INIT(2'b10)) u_buf_0l  (.I0(d_ridx[gri]), .O(ridx_b0_lo[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_0m  (.I0(d_ridx[gri]), .O(ridx_b0_mid[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_0tl (.I0(d_ridx[gri]), .O(ridx_b0_tl[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_0th (.I0(d_ridx[gri]), .O(ridx_b0_th[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_0h  (.I0(d_ridx[gri]), .O(ridx_b0_hi[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_1l  (.I0(d_ridx[gri]), .O(ridx_b1_lo[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_1m  (.I0(d_ridx[gri]), .O(ridx_b1_mid[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_1tl (.I0(d_ridx[gri]), .O(ridx_b1_tl[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_1th (.I0(d_ridx[gri]), .O(ridx_b1_th[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_1h  (.I0(d_ridx[gri]), .O(ridx_b1_hi[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_2l  (.I0(d_ridx[gri]), .O(ridx_b2_lo[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_2m  (.I0(d_ridx[gri]), .O(ridx_b2_mid[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_2tl (.I0(d_ridx[gri]), .O(ridx_b2_tl[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_2th (.I0(d_ridx[gri]), .O(ridx_b2_th[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_2h  (.I0(d_ridx[gri]), .O(ridx_b2_hi[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_3l  (.I0(d_ridx[gri]), .O(ridx_b3_lo[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_3m  (.I0(d_ridx[gri]), .O(ridx_b3_mid[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_3tl (.I0(d_ridx[gri]), .O(ridx_b3_tl[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_3th (.I0(d_ridx[gri]), .O(ridx_b3_th[gri]));
			LUT1 #(.INIT(2'b10)) u_buf_3h  (.I0(d_ridx[gri]), .O(ridx_b3_hi[gri]));
		end
	endgenerate
`else
	wire [5:0] ridx_b0_lo = d_ridx, ridx_b0_mid = d_ridx, ridx_b0_tl = d_ridx, ridx_b0_th = d_ridx, ridx_b0_hi = d_ridx;
	wire [5:0] ridx_b1_lo = d_ridx, ridx_b1_mid = d_ridx, ridx_b1_tl = d_ridx, ridx_b1_th = d_ridx, ridx_b1_hi = d_ridx;
	wire [5:0] ridx_b2_lo = d_ridx, ridx_b2_mid = d_ridx, ridx_b2_tl = d_ridx, ridx_b2_th = d_ridx, ridx_b2_hi = d_ridx;
	wire [5:0] ridx_b3_lo = d_ridx, ridx_b3_mid = d_ridx, ridx_b3_tl = d_ridx, ridx_b3_th = d_ridx, ridx_b3_hi = d_ridx;
`endif

	wire r_timing_hit_0 = ridx_b0_tl >= I_TIMING && ridx_b0_tl <= I_SYNC_POL;
	wire [3:0] r_tidx_0_l, r_tidx_0_h;
	am_sub #(.W(4)) s_rtidx_0l (.a(ridx_b0_tl[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_0_l), .bo(idx_bo_unused[4]));
	am_sub #(.W(4)) s_rtidx_0h (.a(ridx_b0_th[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_0_h), .bo(idx_bo_unused[5]));
	wire [3:0] r_timing_b0_lo = timing_lo[16*r_tidx_0_l +: 4];
	wire [3:0] r_timing_b0_hi = timing_lo[16*r_tidx_0_h + 4 +: 4];
	wire [7:0] timing_mux_b0 = {r_timing_b0_hi, r_timing_b0_lo};
	wire r_i2c_0 = ridx_b0_mid[5:2] == I_I2C[5:2] && ridx_b0_mid[1:0] != 2'd3;

	wire r_timing_hit_1 = ridx_b1_tl >= I_TIMING && ridx_b1_tl <= I_SYNC_POL;
	wire [3:0] r_tidx_1_l, r_tidx_1_h;
	am_sub #(.W(4)) s_rtidx_1l (.a(ridx_b1_tl[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_1_l), .bo(idx_bo_unused[6]));
	am_sub #(.W(4)) s_rtidx_1h (.a(ridx_b1_th[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_1_h), .bo(idx_bo_unused[7]));
	wire [3:0] r_timing_b1_lo = timing_lo[16*r_tidx_1_l + 8 +: 4];
	wire [3:0] r_timing_b1_hi = timing_lo[16*r_tidx_1_h + 12 +: 4];
	wire [7:0] timing_mux_b1 = {r_timing_b1_hi, r_timing_b1_lo};
	wire r_i2c_1 = ridx_b1_mid[5:2] == I_I2C[5:2] && ridx_b1_mid[1:0] != 2'd3;

	wire r_timing_hit_2 = ridx_b2_tl >= I_TIMING && ridx_b2_tl <= I_SYNC_POL;
	wire [3:0] r_tidx_2_l, r_tidx_2_h;
	am_sub #(.W(4)) s_rtidx_2l (.a(ridx_b2_tl[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_2_l), .bo(idx_bo_unused[8]));
	am_sub #(.W(4)) s_rtidx_2h (.a(ridx_b2_th[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_2_h), .bo(idx_bo_unused[9]));
	wire [3:0] r_timing_b2_lo = timing_hi[16*r_tidx_2_l +: 4];
	wire [3:0] r_timing_b2_hi = timing_hi[16*r_tidx_2_h + 4 +: 4];
	wire [7:0] timing_mux_b2 = {r_timing_b2_hi, r_timing_b2_lo};
	wire r_i2c_2 = ridx_b2_mid[5:2] == I_I2C[5:2] && ridx_b2_mid[1:0] != 2'd3;

	wire r_timing_hit_3 = ridx_b3_tl >= I_TIMING && ridx_b3_tl <= I_SYNC_POL;
	wire [3:0] r_tidx_3_l, r_tidx_3_h;
	am_sub #(.W(4)) s_rtidx_3l (.a(ridx_b3_tl[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_3_l), .bo(idx_bo_unused[10]));
	am_sub #(.W(4)) s_rtidx_3h (.a(ridx_b3_th[3:0]), .b(I_TIMING[3:0]), .bi(1'b0), .d(r_tidx_3_h), .bo(idx_bo_unused[11]));
	wire [3:0] r_timing_b3_lo = timing_hi[16*r_tidx_3_l + 8 +: 4];
	wire [3:0] r_timing_b3_hi = timing_hi[16*r_tidx_3_h + 12 +: 4];
	wire [7:0] timing_mux_b3 = {r_timing_b3_hi, r_timing_b3_lo};
	wire r_i2c_3 = ridx_b3_mid[5:2] == I_I2C[5:2] && ridx_b3_mid[1:0] != 2'd3;

	reg [7:0] rdata_b0_lo, rdata_b0_mid, rdata_b0_hi;
	always @(*) begin
		case (ridx_b0_lo)
		GHCI_DC_ID[7:2]:      rdata_b0_lo = GHCI_DC_ID_VALUE[7:0];
		GHCI_DC_VERSION[7:2]: rdata_b0_lo = DC_VERSION_VALUE[7:0];
		GHCI_DC_CAPS[7:2]:    rdata_b0_lo = DC_CAPS_VALUE[7:0];
		I_CTRL:               rdata_b0_lo = ctrl_old[7:0];
		I_STATUS:             rdata_b0_lo = {2'd0, st_bad, st_rec_err, st_rd_err, !r_enable && idle_in, st_underflow, r_enable};
		I_DC_IRQ_STATUS:      rdata_b0_lo = {2'd0, disp_irq_status};
		I_DC_IRQ_ENABLE:      rdata_b0_lo = {2'd0, disp_irq_enable};
		I_FB_BASE:            rdata_b0_lo = r_fb_base_lo[7:0];
		I_FB_NEXT:            rdata_b0_lo = r_fb_next_lo[7:0];
		I_FB_STRIDE:          rdata_b0_lo = r_stride_lo[7:0];
		I_FB_SIZE:            rdata_b0_lo = r_size_lo[7:0];
		default:              rdata_b0_lo = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b0_mid)
		I_FRAME_COUNT:     rdata_b0_mid = r_frame_count_lo[7:0];
		I_PCLK_SEL:        rdata_b0_mid = {4'd0, r_pclk_sel};
		I_SCAN_SUM:        rdata_b0_mid = scan_sum[7:0];
		I_SCAN_WORDS:      rdata_b0_mid = scan_words[7:0];
		default:
			if (r_timing_hit_0)
				rdata_b0_mid = timing_mux_b0;
			else if (r_i2c_0 && HAS_I2C != 0)
				rdata_b0_mid = i2c_rdata[7:0];
			else
				rdata_b0_mid = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b0_hi)
		I_PLANE2_BASE:     rdata_b0_hi = r_plane2_base_lo[7:0];
		I_PLANE2_POS:      rdata_b0_hi = r_plane2_pos_lo[7:0];
		I_PLANE2_SIZE:     rdata_b0_hi = r_plane2_size_lo[7:0];
		I_PLANE2_CTRL:     rdata_b0_hi = r_plane2_ctrl_lo[7:0];
		I_PLANE2_COLORKEY: rdata_b0_hi = r_plane2_colorkey_lo[7:0];
		I_VRR_CTRL:        rdata_b0_hi = r_vrr_ctrl_lo[7:0];
		I_HDR_CTRL:        rdata_b0_hi = r_hdr_ctrl_lo[7:0];
		I_FLIP_READY:      rdata_b0_hi = {7'd0, r_flip_ready};
		default:           rdata_b0_hi = 8'd0;
		endcase
	end
	wire [7:0] d_rdata_b0 = (ridx_b0_hi >= I_PLANE2_BASE) ? rdata_b0_hi :
		((ridx_b0_hi >= I_TIMING) ? rdata_b0_mid : rdata_b0_lo);

	reg [7:0] rdata_b1_lo, rdata_b1_mid, rdata_b1_hi;
	always @(*) begin
		case (ridx_b1_lo)
		GHCI_DC_ID[7:2]:      rdata_b1_lo = GHCI_DC_ID_VALUE[15:8];
		GHCI_DC_VERSION[7:2]: rdata_b1_lo = DC_VERSION_VALUE[15:8];
		GHCI_DC_CAPS[7:2]:    rdata_b1_lo = DC_CAPS_VALUE[15:8];
		I_CTRL:               rdata_b1_lo = ctrl_old[15:8];
		I_STATUS:             rdata_b1_lo = 8'd0;
		I_DC_IRQ_STATUS:      rdata_b1_lo = 8'd0;
		I_DC_IRQ_ENABLE:      rdata_b1_lo = 8'd0;
		I_FB_BASE:            rdata_b1_lo = r_fb_base_lo[15:8];
		I_FB_NEXT:            rdata_b1_lo = r_fb_next_lo[15:8];
		I_FB_STRIDE:          rdata_b1_lo = r_stride_lo[15:8];
		I_FB_SIZE:            rdata_b1_lo = r_size_lo[15:8];
		default:              rdata_b1_lo = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b1_mid)
		I_FRAME_COUNT:     rdata_b1_mid = r_frame_count_lo[15:8];
		I_PCLK_SEL:        rdata_b1_mid = 8'd0;
		I_SCAN_SUM:        rdata_b1_mid = scan_sum[15:8];
		I_SCAN_WORDS:      rdata_b1_mid = scan_words[15:8];
		default:
			if (r_timing_hit_1)
				rdata_b1_mid = timing_mux_b1;
			else if (r_i2c_1 && HAS_I2C != 0)
				rdata_b1_mid = i2c_rdata[15:8];
			else
				rdata_b1_mid = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b1_hi)
		I_PLANE2_BASE:     rdata_b1_hi = r_plane2_base_lo[15:8];
		I_PLANE2_POS:      rdata_b1_hi = r_plane2_pos_lo[15:8];
		I_PLANE2_SIZE:     rdata_b1_hi = r_plane2_size_lo[15:8];
		I_PLANE2_CTRL:     rdata_b1_hi = r_plane2_ctrl_lo[15:8];
		I_PLANE2_COLORKEY: rdata_b1_hi = r_plane2_colorkey_lo[15:8];
		I_VRR_CTRL:        rdata_b1_hi = r_vrr_ctrl_lo[15:8];
		I_HDR_CTRL:        rdata_b1_hi = r_hdr_ctrl_lo[15:8];
		I_FLIP_READY:      rdata_b1_hi = 8'd0;
		default:           rdata_b1_hi = 8'd0;
		endcase
	end
	wire [7:0] d_rdata_b1 = (ridx_b1_hi >= I_PLANE2_BASE) ? rdata_b1_hi :
		((ridx_b1_hi >= I_TIMING) ? rdata_b1_mid : rdata_b1_lo);

	reg [7:0] rdata_b2_lo, rdata_b2_mid, rdata_b2_hi;
	always @(*) begin
		case (ridx_b2_lo)
		GHCI_DC_ID[7:2]:      rdata_b2_lo = GHCI_DC_ID_VALUE[23:16];
		GHCI_DC_VERSION[7:2]: rdata_b2_lo = DC_VERSION_VALUE[23:16];
		GHCI_DC_CAPS[7:2]:    rdata_b2_lo = DC_CAPS_VALUE[23:16];
		I_CTRL:               rdata_b2_lo = ctrl_old[23:16];
		I_STATUS:             rdata_b2_lo = line[7:0];
		I_DC_IRQ_STATUS:      rdata_b2_lo = 8'd0;
		I_DC_IRQ_ENABLE:      rdata_b2_lo = 8'd0;
		I_FB_BASE:            rdata_b2_lo = r_fb_base_hi[7:0];
		I_FB_NEXT:            rdata_b2_lo = r_fb_next_hi[7:0];
		I_FB_STRIDE:          rdata_b2_lo = r_stride_hi[7:0];
		I_FB_SIZE:            rdata_b2_lo = r_size_hi[7:0];
		default:              rdata_b2_lo = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b2_mid)
		I_FRAME_COUNT:     rdata_b2_mid = r_frame_count_hi[7:0];
		I_PCLK_SEL:        rdata_b2_mid = 8'd0;
		I_SCAN_SUM:        rdata_b2_mid = scan_sum[23:16];
		I_SCAN_WORDS:      rdata_b2_mid = scan_words[23:16];
		default:
			if (r_timing_hit_2)
				rdata_b2_mid = timing_mux_b2;
			else if (r_i2c_2 && HAS_I2C != 0)
				rdata_b2_mid = i2c_rdata[23:16];
			else
				rdata_b2_mid = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b2_hi)
		I_PLANE2_BASE:     rdata_b2_hi = r_plane2_base_hi[7:0];
		I_PLANE2_POS:      rdata_b2_hi = r_plane2_pos_hi[7:0];
		I_PLANE2_SIZE:     rdata_b2_hi = r_plane2_size_hi[7:0];
		I_PLANE2_CTRL:     rdata_b2_hi = r_plane2_ctrl_hi[7:0];
		I_PLANE2_COLORKEY: rdata_b2_hi = r_plane2_colorkey_hi[7:0];
		I_VRR_CTRL:        rdata_b2_hi = r_vrr_ctrl_hi[7:0];
		I_HDR_CTRL:        rdata_b2_hi = r_hdr_ctrl_hi[7:0];
		I_FLIP_READY:      rdata_b2_hi = 8'd0;
		default:           rdata_b2_hi = 8'd0;
		endcase
	end
	wire [7:0] d_rdata_b2 = (ridx_b2_hi >= I_PLANE2_BASE) ? rdata_b2_hi :
		((ridx_b2_hi >= I_TIMING) ? rdata_b2_mid : rdata_b2_lo);

	reg [7:0] rdata_b3_lo, rdata_b3_mid, rdata_b3_hi;
	always @(*) begin
		case (ridx_b3_lo)
		GHCI_DC_ID[7:2]:      rdata_b3_lo = GHCI_DC_ID_VALUE[31:24];
		GHCI_DC_VERSION[7:2]: rdata_b3_lo = DC_VERSION_VALUE[31:24];
		GHCI_DC_CAPS[7:2]:    rdata_b3_lo = DC_CAPS_VALUE[31:24];
		I_CTRL:               rdata_b3_lo = ctrl_old[31:24];
		I_STATUS:             rdata_b3_lo = {1'b0, pending1, pend, connected, line[11:8]};
		I_DC_IRQ_STATUS:      rdata_b3_lo = 8'd0;
		I_DC_IRQ_ENABLE:      rdata_b3_lo = 8'd0;
		I_FB_BASE:            rdata_b3_lo = r_fb_base_hi[15:8];
		I_FB_NEXT:            rdata_b3_lo = r_fb_next_hi[15:8];
		I_FB_STRIDE:          rdata_b3_lo = r_stride_hi[15:8];
		I_FB_SIZE:            rdata_b3_lo = r_size_hi[15:8];
		default:              rdata_b3_lo = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b3_mid)
		I_FRAME_COUNT:     rdata_b3_mid = r_frame_count_hi[15:8];
		I_PCLK_SEL:        rdata_b3_mid = 8'd0;
		I_SCAN_SUM:        rdata_b3_mid = scan_sum[31:24];
		I_SCAN_WORDS:      rdata_b3_mid = scan_words[31:24];
		default:
			if (r_timing_hit_3)
				rdata_b3_mid = timing_mux_b3;
			else if (r_i2c_3 && HAS_I2C != 0)
				rdata_b3_mid = i2c_rdata[31:24];
			else
				rdata_b3_mid = 8'd0;
		endcase
	end

	always @(*) begin
		case (ridx_b3_hi)
		I_PLANE2_BASE:     rdata_b3_hi = r_plane2_base_hi[15:8];
		I_PLANE2_POS:      rdata_b3_hi = r_plane2_pos_hi[15:8];
		I_PLANE2_SIZE:     rdata_b3_hi = r_plane2_size_hi[15:8];
		I_PLANE2_CTRL:     rdata_b3_hi = r_plane2_ctrl_hi[15:8];
		I_PLANE2_COLORKEY: rdata_b3_hi = r_plane2_colorkey_hi[15:8];
		I_VRR_CTRL:        rdata_b3_hi = r_vrr_ctrl_hi[15:8];
		I_HDR_CTRL:        rdata_b3_hi = r_hdr_ctrl_hi[15:8];
		I_FLIP_READY:      rdata_b3_hi = 8'd0;
		default:           rdata_b3_hi = 8'd0;
		endcase
	end
	wire [7:0] d_rdata_b3 = (ridx_b3_hi >= I_PLANE2_BASE) ? rdata_b3_hi :
		((ridx_b3_hi >= I_TIMING) ? rdata_b3_mid : rdata_b3_lo);

	assign d_rdata = {d_rdata_b3, d_rdata_b2, d_rdata_b1, d_rdata_b0};
endmodule

`default_nettype wire
