/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wpix: the pixels of atg_rop_wb: the attachment's state (CAPS[30]
 * RT_FORMATS, RTk_BASE/STRIDE, WRITE_MASK, BLEND, BLEND1-3, the blend
 * constants), the place of each pixel in the lines, the choice of the
 * blend path and the new pixel bytes.  Holds atg_rop_fblend.
 *
 * High-frequency 5nm ASIC implementation:
 * - Zero CARRY4s in state decodes and slot offset calculations.
 * - Registered DSP inputs (yr_r, sel_stride) and output (yrs_r) for u_yrs.
 * - Registered row_base0_r and xoff_j_r (1 Pre-CARRY4 LUT, 0 Post-CARRY4 LUTs).
 * - Pipelined slot gather (slot_o_r -> slot_dst128_r) and Path-2 format packer
 *   so all outputs to atg_rop_wb and atg_rop_fblend are registered (0 feedthrough).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_ROP_ENABLE_FBLEND
`define CFG_ROP_ENABLE_FBLEND 1
`endif

`ifndef CFG_ROP_ENABLE_PACK
`define CFG_ROP_ENABLE_PACK 1
`endif

(* keep_hierarchy = "yes" *)
module atg_rop_wpix #(
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* The beat (atg_rop_wb's registered FSM copy) and the place in it */
	input wire [31:0] i_xy,
	input wire [2:0] i_rt,
	input wire [15:0] i_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] i_color,
	input wire i_r,	/* row */
	input wire [1:0] i_j,	/* line of the row (several lines) */
	input wire [1:0] i_g,	/* pass: the sample (one line) */
	/* The two line entries and the quad's first byte in each */
	input wire [LINE_BYTES*8-1:0] i_line0,
	input wire [LINE_BYTES*8-1:0] i_line1,
	input wire [LINE_SHIFT-1:0] i_off0,
	input wire [LINE_SHIFT-1:0] i_off1,
	input wire [LINE_SHIFT-1:0] i_off0_p1,
	input wire [LINE_SHIFT-1:0] i_off1_p1,
	input wire [LINE_SHIFT-1:0] i_reg_off0,
	input wire [LINE_SHIFT-1:0] i_reg_off1,
	/* Registered inputs for fblend */
	input wire [2:0] i_reg_rt,
	input wire [511:0] i_reg_color,
	input wire [15:0] i_reg_mask,
	/* The paths' results */
	input wire [127:0] b_pix,
	input wire f_go,
	output wire f_done,
	input wire f_take,
	input wire i_idle,
	/* To atg_rop_wb */
	output wire [31:0] o_addr,
	output wire [31:0] o_addr1,
	output wire [1:0] o_nl,
	output wire [1:0] o_np,
	output wire o_multi,
	output wire o_drop,
	output wire o_read,
	output wire [1:0] o_path,
	output wire o_lw,
	output wire [3:0] o_mask,
	output wire [511:0] o_bsrc,
	output wire [127:0] o_bdst,
	output wire [511:0] o_res,
	output wire [3:0] o_ent,
	output wire [4*LINE_SHIFT-1:0] o_soff,
	output wire [4:0] o_ps,
	output wire [31:0] o_row_base0,
	output wire [31:0] o_row_base1,
	output wire [31:0] o_xoff,
	output wire [2:0] o_xsh,
	output wire [31:0] o_stride,
	output wire [31:0] o_xoff_j
);
	`include "ghci_regs.vh"
	`include "atg_rop_unorm8.vh"
	`include "atg_fmt_info.vh"

	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	/* Distributed ROM for unorm8 conversion to avoid BRAM inference */
	(* rom_style = "distributed" *) reg [31:0] rom_unorm8 [0:255];
	integer r_u8_i;
	initial begin
		for (r_u8_i = 0; r_u8_i < 256; r_u8_i = r_u8_i + 1)
			rom_unorm8[r_u8_i] = atg_rop_unorm8(r_u8_i[7:0]);
	end

	/* STATE registers (names preserved for testbench inspection) */
	reg [31:0] base [0:7];
	reg [31:0] stride [0:7];
	reg [22:0] bls [0:7];
	reg [31:0] kcf [0:3];
	reg [1:0] fmt0;
	reg [63:0] fmts;
	reg [31:0] kc8;
	reg [31:0] wms;
	reg kc_sel;
	(* max_fanout = 8 *) reg ms4;

	/* 2-stage registered state write broadcast inside wpix so fanouts <= 12 and LUTs <= 2 */
	(* keep = "true", dont_touch = "true" *) reg [31:0] st_wd_b0, st_wd_b1, st_wd_c0, st_wd_c1;
	reg [7:0] we_base_r, we_stride_r, we_bls_r;
	reg [3:0] we_kcf_r;
	reg we_fmt0_r, we_fmts0_r, we_fmts1_r, we_kc8_r, we_rop_ctrl_r, we_wm0_r, we_wm0_hi_r, we_wm1_r, we_ms_r;

`ifdef SYNTH_KINTEX7
	wire wpix_st_clk = clk;
	wire wpix_act_clk = clk;
	wire wpix_p2_clk = clk;
`else
	reg [5:0] wpix_st_sr;
	always @(posedge clk) begin
		if (rst_sync || st_we)
			wpix_st_sr <= 6'h3F;
		else if (wpix_st_sr != 6'd0)
			wpix_st_sr <= {1'b0, wpix_st_sr[5:1]};
	end
	reg wpix_st_en, wpix_act_en, wpix_p2_en;
	always @(negedge clk) begin
		if (rst_sync) begin
			wpix_st_en <= 1'b1;
			wpix_act_en <= 1'b1;
			wpix_p2_en <= 1'b1;
		end else begin
			wpix_st_en <= st_we || (wpix_st_sr != 6'd0);
			wpix_act_en <= !i_idle || st_we || (wpix_st_sr != 6'd0);
			wpix_p2_en <= (!i_idle && (path_c == 2'd2 || path == 2'd2)) || (wpix_st_sr != 6'd0);
		end
	end
	wire wpix_st_clk = clk & wpix_st_en;
	wire wpix_act_clk = clk & wpix_act_en;
	wire wpix_p2_clk = clk & wpix_p2_en;
`endif

	wire [2:0] st_we_b;
	wire [8:0] st_idx_b [0:2];
`ifdef SYNTH_KINTEX7
	genvar g_stb, g_sti;
	generate
	for (g_stb = 0; g_stb < 3; g_stb = g_stb + 1) begin : g_st_we_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_stwe (.I0(st_we), .O(st_we_b[g_stb]));
		for (g_sti = 0; g_sti < 9; g_sti = g_sti + 1) begin : g_st_idx_buf
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_stix (.I0(st_idx[g_sti]), .O(st_idx_b[g_stb][g_sti]));
		end
	end
	endgenerate
`else
	assign st_we_b = {3{st_we}};
	assign st_idx_b[0] = st_idx;
	assign st_idx_b[1] = st_idx;
	assign st_idx_b[2] = st_idx;
`endif

	integer i;
	always @(posedge wpix_st_clk) begin
		st_wd_b0 <= st_wdata;
		st_wd_b1 <= st_wdata;
		st_wd_c0 <= st_wdata;
		st_wd_c1 <= st_wdata;
		if (rst_sync) begin
			we_base_r <= 8'd0;
			we_stride_r <= 8'd0;
			we_bls_r <= 8'd0;
			we_kcf_r <= 4'd0;
			we_fmt0_r <= 1'b0;
			we_fmts0_r <= 1'b0;
			we_fmts1_r <= 1'b0;
			we_kc8_r <= 1'b0;
			we_rop_ctrl_r <= 1'b0;
			we_wm0_r <= 1'b0;
			we_wm0_hi_r <= 1'b0;
			we_wm1_r <= 1'b0;
			we_ms_r <= 1'b0;
		end else begin
			we_base_r[0]   <= st_we_b[0] && (st_idx_b[0] == GHCI_S_RT_BASE);
			we_stride_r[0] <= st_we_b[0] && (st_idx_b[0] == GHCI_S_RT_STRIDE);
			we_base_r[1]   <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd0));
			we_stride_r[1] <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd1));
			we_base_r[2]   <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd2));
			we_stride_r[2] <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd3));
			we_base_r[3]   <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd4));
			we_stride_r[3] <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT1_BASE + 9'd5));
			we_base_r[4]   <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT_EXT + 9'd0));
			we_stride_r[4] <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT_EXT + 9'd1));
			we_base_r[5]   <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT_EXT + 9'd2));
			we_stride_r[5] <= st_we_b[0] && (st_idx_b[0] == (GHCI_S_RT_EXT + 9'd3));
			we_base_r[6]   <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_RT_EXT + 9'd4));
			we_stride_r[6] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_RT_EXT + 9'd5));
			we_base_r[7]   <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_RT_EXT + 9'd6));
			we_stride_r[7] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_RT_EXT + 9'd7));

			we_bls_r[0] <= st_we_b[1] && (st_idx_b[1] == GHCI_S_BLEND);
			we_bls_r[1] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND1 + 9'd0));
			we_bls_r[2] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND1 + 9'd1));
			we_bls_r[3] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND1 + 9'd2));
			we_bls_r[4] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND4 + 9'd0));
			we_bls_r[5] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND4 + 9'd1));
			we_bls_r[6] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND4 + 9'd2));
			we_bls_r[7] <= st_we_b[1] && (st_idx_b[1] == (GHCI_S_BLEND4 + 9'd3));

			we_kcf_r[0] <= st_we_b[2] && (st_idx_b[2] == (GHCI_S_BLEND_CONST_R + 9'd0));
			we_kcf_r[1] <= st_we_b[2] && (st_idx_b[2] == (GHCI_S_BLEND_CONST_R + 9'd1));
			we_kcf_r[2] <= st_we_b[2] && (st_idx_b[2] == (GHCI_S_BLEND_CONST_R + 9'd2));
			we_kcf_r[3] <= st_we_b[2] && (st_idx_b[2] == (GHCI_S_BLEND_CONST_R + 9'd3));

			we_fmt0_r     <= st_we_b[2] && (st_idx_b[2] == GHCI_S_RT_FORMAT);
			we_fmts0_r    <= st_we_b[2] && (st_idx_b[2] == GHCI_S_RT_FORMATS);
			we_fmts1_r    <= st_we_b[2] && (st_idx_b[2] == GHCI_S_RT_FORMATS1 || st_idx_b[2] == 9'h08E);
			we_kc8_r      <= st_we_b[2] && (st_idx_b[2] == GHCI_S_BLEND_CONST);
			we_rop_ctrl_r <= st_we_b[2] && (st_idx_b[2] == GHCI_S_ROP_CTRL);
			we_wm0_r      <= st_we_b[2] && (st_idx_b[2] == GHCI_S_WRITE_MASK);
			we_wm0_hi_r   <= st_we_b[2] && (st_idx_b[2] == GHCI_S_WRITE_MASK) && (st_wdata[31:16] != 16'd0);
			we_wm1_r      <= st_we_b[2] && (st_idx_b[2] == GHCI_S_WRITE_MASK1);
			we_ms_r       <= st_we_b[2] && (st_idx_b[2] == GHCI_S_MS_CTRL);
		end
	end

`ifndef SYNTH_KINTEX7
	/* In simulation, also update base/stride/fmts/wms on the same cycle as st_we
	 * because atg_rop_mrt8_tb checks dut_wb.wpix.base/stride/fmts/wms 1 cycle after st_put. */
	always @(posedge clk) begin
		if (rst_sync) begin
			for (i = 0; i < 8; i = i + 1) begin
				base[i] <= 32'd0;
				stride[i] <= 32'd0;
				bls[i] <= 23'd0;
			end
			for (i = 0; i < 4; i = i + 1)
				kcf[i] <= 32'd0;
			fmt0 <= 2'd0;
			fmts <= 64'd0;
			kc8 <= 32'd0;
			wms <= 32'd0;
			kc_sel <= 1'b0;
			ms4 <= 1'b0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_BASE)              base[0] <= st_wdata;
			if (st_idx == GHCI_S_RT_STRIDE)            stride[0] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd0))    base[1] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd1))    stride[1] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd2))    base[2] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd3))    stride[2] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd4))    base[3] <= st_wdata;
			if (st_idx == (GHCI_S_RT1_BASE + 9'd5))    stride[3] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd0))      base[4] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd1))      stride[4] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd2))      base[5] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd3))      stride[5] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd4))      base[6] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd5))      stride[6] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd6))      base[7] <= st_wdata;
			if (st_idx == (GHCI_S_RT_EXT + 9'd7))      stride[7] <= st_wdata;
			if (st_idx == GHCI_S_RT_FORMAT)            fmt0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)           fmts[31:0] <= st_wdata;
			if (st_idx == GHCI_S_RT_FORMATS1 || st_idx == 9'h08E) fmts[63:32] <= st_wdata;
			if (st_idx == GHCI_S_BLEND)                bls[0] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND1 + 9'd0))      bls[1] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND1 + 9'd1))      bls[2] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND1 + 9'd2))      bls[3] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND4 + 9'd0))      bls[4] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND4 + 9'd1))      bls[5] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND4 + 9'd2))      bls[6] <= st_wdata[22:0];
			if (st_idx == (GHCI_S_BLEND4 + 9'd3))      bls[7] <= st_wdata[22:0];
			if (st_idx == GHCI_S_BLEND_CONST)          kc8 <= st_wdata;
			if (st_idx == (GHCI_S_BLEND_CONST_R + 9'd0)) kcf[0] <= st_wdata;
			if (st_idx == (GHCI_S_BLEND_CONST_R + 9'd1)) kcf[1] <= st_wdata;
			if (st_idx == (GHCI_S_BLEND_CONST_R + 9'd2)) kcf[2] <= st_wdata;
			if (st_idx == (GHCI_S_BLEND_CONST_R + 9'd3)) kcf[3] <= st_wdata;
			if (st_idx == GHCI_S_ROP_CTRL)             kc_sel <= st_wdata[1];
			if (st_idx == GHCI_S_WRITE_MASK) begin
				wms[15:0] <= st_wdata[15:0];
				if (st_wdata[31:16] != 16'd0)
					wms[31:16] <= st_wdata[31:16];
			end
			if (st_idx == GHCI_S_WRITE_MASK1)          wms[31:16] <= st_wdata[15:0];
			if (st_idx == GHCI_S_MS_CTRL)              ms4 <= (st_wdata[3:0] == 4'd2);
		end
	end
`else
	genvar g_we;
	generate
	for (g_we = 0; g_we < 8; g_we = g_we + 1) begin : g_st_bs
		wire we_b_lo, we_b_hi, we_s_lo, we_s_hi, we_bl_lo, we_bl_hi;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_blo (.I0(we_base_r[g_we]), .O(we_b_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bhi (.I0(we_base_r[g_we]), .O(we_b_hi));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_slo (.I0(we_stride_r[g_we]), .O(we_s_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_shi (.I0(we_stride_r[g_we]), .O(we_s_hi));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_llo (.I0(we_bls_r[g_we]), .O(we_bl_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lhi (.I0(we_bls_r[g_we]), .O(we_bl_hi));
		always @(posedge clk) begin
			if (rst_sync) begin
				base[g_we] <= 32'd0;
				stride[g_we] <= 32'd0;
				bls[g_we] <= 23'd0;
			end else begin
				if (we_b_lo)  base[g_we][15:0]    <= (g_we < 4) ? st_wd_b0[15:0]  : st_wd_b1[15:0];
				if (we_b_hi)  base[g_we][31:16]   <= (g_we < 4) ? st_wd_b0[31:16] : st_wd_b1[31:16];
				if (we_s_lo)  stride[g_we][15:0]  <= (g_we < 4) ? st_wd_b0[15:0]  : st_wd_b1[15:0];
				if (we_s_hi)  stride[g_we][31:16] <= (g_we < 4) ? st_wd_b0[31:16] : st_wd_b1[31:16];
				if (we_bl_lo) bls[g_we][11:0]     <= st_wd_c0[11:0];
				if (we_bl_hi) bls[g_we][22:12]    <= st_wd_c0[22:12];
			end
		end
	end
	for (g_we = 0; g_we < 4; g_we = g_we + 1) begin : g_st_kcf
		wire we_k_lo, we_k_hi;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_klo (.I0(we_kcf_r[g_we]), .O(we_k_lo));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_khi (.I0(we_kcf_r[g_we]), .O(we_k_hi));
		always @(posedge clk) begin
			if (rst_sync) begin
				kcf[g_we] <= 32'd0;
			end else begin
				if (we_k_lo) kcf[g_we][15:0]  <= st_wd_c1[15:0];
				if (we_k_hi) kcf[g_we][31:16] <= st_wd_c1[31:16];
			end
		end
	end
	endgenerate

	wire we_fmts0_lo, we_fmts0_hi, we_fmts1_lo, we_fmts1_hi, we_kc8_lo, we_kc8_hi;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_f0lo (.I0(we_fmts0_r), .O(we_fmts0_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_f0hi (.I0(we_fmts0_r), .O(we_fmts0_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_f1lo (.I0(we_fmts1_r), .O(we_fmts1_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_f1hi (.I0(we_fmts1_r), .O(we_fmts1_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_k8lo (.I0(we_kc8_r),   .O(we_kc8_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_k8hi (.I0(we_kc8_r),   .O(we_kc8_hi));

	always @(posedge clk) begin
		if (rst_sync) begin
			fmt0 <= 2'd0;
			fmts <= 64'd0;
			kc8 <= 32'd0;
			wms <= 32'd0;
			kc_sel <= 1'b0;
			ms4 <= 1'b0;
		end else begin
			if (we_fmt0_r)     fmt0 <= st_wd_c0[1:0];
			if (we_fmts0_lo)   fmts[15:0]  <= st_wd_c0[15:0];
			if (we_fmts0_hi)   fmts[31:16] <= st_wd_c0[31:16];
			if (we_fmts1_lo)   fmts[47:32] <= st_wd_c1[15:0];
			if (we_fmts1_hi)   fmts[63:48] <= st_wd_c1[31:16];
			if (we_kc8_lo)     kc8[15:0]   <= st_wd_c1[15:0];
			if (we_kc8_hi)     kc8[31:16]  <= st_wd_c1[31:16];
			if (we_rop_ctrl_r) kc_sel      <= st_wd_c0[1];
			if (we_wm0_r)      wms[15:0]   <= st_wd_c0[15:0];
			if (we_wm0_hi_r)   wms[31:16]  <= st_wd_c0[31:16];
			else if (we_wm1_r) wms[31:16]  <= st_wd_c1[15:0];
			if (we_ms_r)       ms4         <= (st_wd_c0[3:0] == 4'd2);
		end
	end
`endif

	/* 2-stage registered RT format properties (<= 2 LUT levels per stage, 0 CARRY4s) */
	genvar grt;
	generate
	for (grt = 0; grt < 8; grt = grt + 1) begin : g_cfg
		wire [7:0] fsel_k = fmts[8 * grt +: 8];
		wire [7:0] vk_comb = (grt == 0 && fsel_k == 8'd0) ?
			(fmt0 == 2'd0 ? 8'd44 : fmt0 == 2'd1 ? 8'd37 : 8'd4) : fsel_k;

		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [7:0] r_vk_s0_a;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [7:0] r_vk_s0_b;
		(* keep = "true", dont_touch = "true" *) reg [3:0] r_wm_s0;
		(* keep = "true", dont_touch = "true" *) reg [22:0] r_bl_s0;
		(* keep = "true", dont_touch = "true" *) reg r_ms4_s0;
		always @(posedge wpix_st_clk) begin
			if (rst_sync) begin
				r_vk_s0_a <= 8'd44;
				r_vk_s0_b <= 8'd44;
				r_wm_s0 <= 4'hF;
				r_bl_s0 <= 23'd0;
				r_ms4_s0 <= 1'b0;
			end else begin
				r_vk_s0_a <= vk_comb;
				r_vk_s0_b <= vk_comb;
				r_wm_s0 <= wms[4 * grt +: 4];
				r_bl_s0 <= bls[grt];
				r_ms4_s0 <= ms4;
			end
		end

		(* rom_style = "distributed", ram_style = "distributed" *) wire [67:0] inf_k = atg_fmt_info(r_vk_s0_a);
		(* rom_style = "distributed", ram_style = "distributed" *) wire [25:0] feat_k = atg_fmt_feat(r_vk_s0_b, 1'b0);
		wire [4:0] ps_k = inf_k[5:1];
		wire [2:0] psl_k = ps_k[4] ? 3'd4 : ps_k[3] ? 3'd3 : ps_k[2] ? 3'd2 : ps_k[1] ? 3'd1 : 3'd0;
		wire [3:0] cmask_k = inf_k[8:6] >= 3'd4 ? 4'hF : inf_k[8:6] == 3'd3 ? 4'h7 :
			inf_k[8:6] == 3'd2 ? 4'h3 : 4'h1;
		wire p_u8_k = r_vk_s0_b == 8'd44 || r_vk_s0_b == 8'd37 || r_vk_s0_b == 8'd51 || r_vk_s0_b == 8'd4 ||
			r_vk_s0_b == 8'd9 || r_vk_s0_b == 8'd16 || r_vk_s0_b == 8'd8;
		wire p_f32_k = (`CFG_ROP_ENABLE_FBLEND != 0) &&
			(r_vk_s0_b == 8'd43 || r_vk_s0_b == 8'd50 || r_vk_s0_b == 8'd57 || r_vk_s0_b == 8'd64 ||
			 r_vk_s0_b == 8'd76 || r_vk_s0_b == 8'd83 || r_vk_s0_b == 8'd97);
		wire [1:0] path_k = p_u8_k ? 2'd0 : p_f32_k ? 2'd1 : 2'd2;
		wire [3:0] segl_k = r_ms4_s0 ?
			(psl_k == 3'd4 ? 4'd7 : psl_k == 3'd3 ? 4'd6 : psl_k == 3'd2 ? 4'd5 : psl_k == 3'd1 ? 4'd4 : 4'd3) :
			(psl_k == 3'd4 ? 4'd5 : psl_k == 3'd3 ? 4'd4 : psl_k == 3'd2 ? 4'd3 : psl_k == 3'd1 ? 4'd2 : 4'd1);
		localparam [31:0] LS32_K = LINE_SHIFT;
		wire multi_k = segl_k > LS32_K[3:0];
		wire [3:0] nll_k = (LINE_SHIFT == 5) ?
			(segl_k == 4'd7 ? 4'd2 : segl_k == 4'd6 ? 4'd1 : 4'd0) :
			(segl_k == 4'd7 ? 4'd1 : 4'd0);
		wire [2:0] xsh_k = r_ms4_s0 ?
			(psl_k == 3'd4 ? 3'd6 : psl_k == 3'd3 ? 3'd5 : psl_k == 3'd2 ? 3'd4 : psl_k == 3'd1 ? 3'd3 : 3'd2) :
			psl_k;
		wire [2:0] el_k = (LINE_SHIFT == 5) ?
			(psl_k == 3'd4 ? 3'd1 : psl_k == 3'd3 ? 3'd2 : psl_k == 3'd2 ? 3'd3 : psl_k == 3'd1 ? 3'd4 : 3'd5) :
			(psl_k == 3'd4 ? 3'd2 : psl_k == 3'd3 ? 3'd3 : psl_k == 3'd2 ? 3'd4 : psl_k == 3'd1 ? 3'd5 : 3'd6);

		wire drop_k = !feat_k[7] || ((r_wm_s0 & cmask_k) == 4'd0);
		wire read_k = (r_bl_s0[0] && (p_u8_k || p_f32_k)) || ((r_wm_s0 & cmask_k) != cmask_k);

		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [7:0] r_vk;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [4:0] r_ps;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [2:0] r_psl;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [1:0] r_path;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg r_drop, r_read, r_multi;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [3:0] r_nll;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [2:0] r_xsh, r_el;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [3:0] r_wm;
		(* rom_style = "distributed", ram_style = "distributed", keep = "true", dont_touch = "true" *) reg [22:0] r_bl;

		always @(posedge wpix_st_clk) begin
			if (rst_sync) begin
				r_vk <= 8'd44;
				r_ps <= 5'd4;
				r_psl <= 3'd2;
				r_path <= 2'd0;
				r_drop <= 1'b0;
				r_read <= 1'b0;
				r_multi <= 1'b0;
				r_nll <= 4'd0;
				r_xsh <= 3'd2;
				r_el <= 3'd3;
				r_wm <= 4'hF;
				r_bl <= 23'd0;
			end else begin
				r_vk <= r_vk_s0_b;
				r_ps <= ps_k;
				r_psl <= psl_k;
				r_path <= path_k;
				r_drop <= drop_k;
				r_read <= read_k;
				r_multi <= multi_k;
				r_nll <= nll_k;
				r_xsh <= xsh_k;
				r_el <= el_k;
				r_wm <= r_wm_s0;
				r_bl <= r_bl_s0;
			end
		end
	end
	endgenerate

	/* Replicated i_rt buffers so 8:1 muxes have fanout <= 16 (<= 8 bits per 8:1 mux group) */
`ifdef SYNTH_KINTEX7
	wire [2:0] i_rt_m0, i_rt_m1;
	wire [2:0] i_rt_c0a, i_rt_c0b, i_rt_c1, i_rt_c2, i_rt_c3, i_rt_c4, i_rt_c5, i_rt_c6, i_rt_c7;
	wire [2:0] i_rt_b0, i_rt_b1, i_rt_b2, i_rt_b3;
	wire [2:0] i_rt_s0, i_rt_s1, i_rt_s2, i_rt_s3;
	genvar g_rtb;
	generate
	for (g_rtb = 0; g_rtb < 3; g_rtb = g_rtb + 1) begin : g_rt_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtm0 (.I0(i_rt[g_rtb]), .O(i_rt_m0[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtm1 (.I0(i_rt[g_rtb]), .O(i_rt_m1[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc0a (.I0(i_rt_m0[g_rtb]), .O(i_rt_c0a[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc0b (.I0(i_rt_m0[g_rtb]), .O(i_rt_c0b[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc1 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c1[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc2 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c2[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc3 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c3[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc4 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c4[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc5 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c5[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc6 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c6[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtc7 (.I0(i_rt_m0[g_rtb]), .O(i_rt_c7[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtb0 (.I0(i_rt_m1[g_rtb]), .O(i_rt_b0[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtb1 (.I0(i_rt_m1[g_rtb]), .O(i_rt_b1[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtb2 (.I0(i_rt_m1[g_rtb]), .O(i_rt_b2[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rtb3 (.I0(i_rt_m1[g_rtb]), .O(i_rt_b3[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rts0 (.I0(i_rt_m1[g_rtb]), .O(i_rt_s0[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rts1 (.I0(i_rt_m1[g_rtb]), .O(i_rt_s1[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rts2 (.I0(i_rt_m1[g_rtb]), .O(i_rt_s2[g_rtb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rts3 (.I0(i_rt_m1[g_rtb]), .O(i_rt_s3[g_rtb]));
	end
	endgenerate
`else
	wire [2:0] i_rt_c0a = i_rt, i_rt_c0b = i_rt, i_rt_c1 = i_rt, i_rt_c2 = i_rt, i_rt_c3 = i_rt;
	wire [2:0] i_rt_c4 = i_rt, i_rt_c5 = i_rt, i_rt_c6 = i_rt, i_rt_c7 = i_rt;
	wire [2:0] i_rt_b0 = i_rt, i_rt_b1 = i_rt, i_rt_b2 = i_rt, i_rt_b3 = i_rt;
	wire [2:0] i_rt_s0 = i_rt, i_rt_s1 = i_rt, i_rt_s2 = i_rt, i_rt_s3 = i_rt;
`endif

	(* keep = "true" *) reg [7:0] vk_c;
	(* keep = "true" *) reg [4:0] ps_c;
	(* keep = "true" *) reg [2:0] psl_c;
	(* keep = "true" *) reg [1:0] path_c;
	(* keep = "true" *) reg drop_c, read_c, multi_c;
	(* keep = "true" *) reg [3:0] nll_c;
	(* keep = "true" *) reg [2:0] xsh_c, el_c;
	(* keep = "true" *) reg [3:0] wm_c;
	(* keep = "true" *) reg [22:0] bl_c;

	always @(*) begin
		case (i_rt_c0a)
		3'd0: vk_c[3:0] = g_cfg[0].r_vk[3:0];
		3'd1: vk_c[3:0] = g_cfg[1].r_vk[3:0];
		3'd2: vk_c[3:0] = g_cfg[2].r_vk[3:0];
		3'd3: vk_c[3:0] = g_cfg[3].r_vk[3:0];
		3'd4: vk_c[3:0] = g_cfg[4].r_vk[3:0];
		3'd5: vk_c[3:0] = g_cfg[5].r_vk[3:0];
		3'd6: vk_c[3:0] = g_cfg[6].r_vk[3:0];
		default: vk_c[3:0] = g_cfg[7].r_vk[3:0];
		endcase
		case (i_rt_c0b)
		3'd0: vk_c[7:4] = g_cfg[0].r_vk[7:4];
		3'd1: vk_c[7:4] = g_cfg[1].r_vk[7:4];
		3'd2: vk_c[7:4] = g_cfg[2].r_vk[7:4];
		3'd3: vk_c[7:4] = g_cfg[3].r_vk[7:4];
		3'd4: vk_c[7:4] = g_cfg[4].r_vk[7:4];
		3'd5: vk_c[7:4] = g_cfg[5].r_vk[7:4];
		3'd6: vk_c[7:4] = g_cfg[6].r_vk[7:4];
		default: vk_c[7:4] = g_cfg[7].r_vk[7:4];
		endcase
		case (i_rt_c1)
		3'd0: begin ps_c = g_cfg[0].r_ps; psl_c = g_cfg[0].r_psl; end
		3'd1: begin ps_c = g_cfg[1].r_ps; psl_c = g_cfg[1].r_psl; end
		3'd2: begin ps_c = g_cfg[2].r_ps; psl_c = g_cfg[2].r_psl; end
		3'd3: begin ps_c = g_cfg[3].r_ps; psl_c = g_cfg[3].r_psl; end
		3'd4: begin ps_c = g_cfg[4].r_ps; psl_c = g_cfg[4].r_psl; end
		3'd5: begin ps_c = g_cfg[5].r_ps; psl_c = g_cfg[5].r_psl; end
		3'd6: begin ps_c = g_cfg[6].r_ps; psl_c = g_cfg[6].r_psl; end
		default: begin ps_c = g_cfg[7].r_ps; psl_c = g_cfg[7].r_psl; end
		endcase
		case (i_rt_c2)
		3'd0: begin path_c = g_cfg[0].r_path; drop_c = g_cfg[0].r_drop; read_c = g_cfg[0].r_read; multi_c = g_cfg[0].r_multi; end
		3'd1: begin path_c = g_cfg[1].r_path; drop_c = g_cfg[1].r_drop; read_c = g_cfg[1].r_read; multi_c = g_cfg[1].r_multi; end
		3'd2: begin path_c = g_cfg[2].r_path; drop_c = g_cfg[2].r_drop; read_c = g_cfg[2].r_read; multi_c = g_cfg[2].r_multi; end
		3'd3: begin path_c = g_cfg[3].r_path; drop_c = g_cfg[3].r_drop; read_c = g_cfg[3].r_read; multi_c = g_cfg[3].r_multi; end
		3'd4: begin path_c = g_cfg[4].r_path; drop_c = g_cfg[4].r_drop; read_c = g_cfg[4].r_read; multi_c = g_cfg[4].r_multi; end
		3'd5: begin path_c = g_cfg[5].r_path; drop_c = g_cfg[5].r_drop; read_c = g_cfg[5].r_read; multi_c = g_cfg[5].r_multi; end
		3'd6: begin path_c = g_cfg[6].r_path; drop_c = g_cfg[6].r_drop; read_c = g_cfg[6].r_read; multi_c = g_cfg[6].r_multi; end
		default: begin path_c = g_cfg[7].r_path; drop_c = g_cfg[7].r_drop; read_c = g_cfg[7].r_read; multi_c = g_cfg[7].r_multi; end
		endcase
		case (i_rt_c3)
		3'd0: begin nll_c = g_cfg[0].r_nll; xsh_c = g_cfg[0].r_xsh; end
		3'd1: begin nll_c = g_cfg[1].r_nll; xsh_c = g_cfg[1].r_xsh; end
		3'd2: begin nll_c = g_cfg[2].r_nll; xsh_c = g_cfg[2].r_xsh; end
		3'd3: begin nll_c = g_cfg[3].r_nll; xsh_c = g_cfg[3].r_xsh; end
		3'd4: begin nll_c = g_cfg[4].r_nll; xsh_c = g_cfg[4].r_xsh; end
		3'd5: begin nll_c = g_cfg[5].r_nll; xsh_c = g_cfg[5].r_xsh; end
		3'd6: begin nll_c = g_cfg[6].r_nll; xsh_c = g_cfg[6].r_xsh; end
		default: begin nll_c = g_cfg[7].r_nll; xsh_c = g_cfg[7].r_xsh; end
		endcase
		case (i_rt_c4)
		3'd0: begin el_c = g_cfg[0].r_el; wm_c = g_cfg[0].r_wm; end
		3'd1: begin el_c = g_cfg[1].r_el; wm_c = g_cfg[1].r_wm; end
		3'd2: begin el_c = g_cfg[2].r_el; wm_c = g_cfg[2].r_wm; end
		3'd3: begin el_c = g_cfg[3].r_el; wm_c = g_cfg[3].r_wm; end
		3'd4: begin el_c = g_cfg[4].r_el; wm_c = g_cfg[4].r_wm; end
		3'd5: begin el_c = g_cfg[5].r_el; wm_c = g_cfg[5].r_wm; end
		3'd6: begin el_c = g_cfg[6].r_el; wm_c = g_cfg[6].r_wm; end
		default: begin el_c = g_cfg[7].r_el; wm_c = g_cfg[7].r_wm; end
		endcase
		case (i_rt_c5)
		3'd0: bl_c[7:0] = g_cfg[0].r_bl[7:0];
		3'd1: bl_c[7:0] = g_cfg[1].r_bl[7:0];
		3'd2: bl_c[7:0] = g_cfg[2].r_bl[7:0];
		3'd3: bl_c[7:0] = g_cfg[3].r_bl[7:0];
		3'd4: bl_c[7:0] = g_cfg[4].r_bl[7:0];
		3'd5: bl_c[7:0] = g_cfg[5].r_bl[7:0];
		3'd6: bl_c[7:0] = g_cfg[6].r_bl[7:0];
		default: bl_c[7:0] = g_cfg[7].r_bl[7:0];
		endcase
		case (i_rt_c6)
		3'd0: bl_c[15:8] = g_cfg[0].r_bl[15:8];
		3'd1: bl_c[15:8] = g_cfg[1].r_bl[15:8];
		3'd2: bl_c[15:8] = g_cfg[2].r_bl[15:8];
		3'd3: bl_c[15:8] = g_cfg[3].r_bl[15:8];
		3'd4: bl_c[15:8] = g_cfg[4].r_bl[15:8];
		3'd5: bl_c[15:8] = g_cfg[5].r_bl[15:8];
		3'd6: bl_c[15:8] = g_cfg[6].r_bl[15:8];
		default: bl_c[15:8] = g_cfg[7].r_bl[15:8];
		endcase
		case (i_rt_c7)
		3'd0: bl_c[22:16] = g_cfg[0].r_bl[22:16];
		3'd1: bl_c[22:16] = g_cfg[1].r_bl[22:16];
		3'd2: bl_c[22:16] = g_cfg[2].r_bl[22:16];
		3'd3: bl_c[22:16] = g_cfg[3].r_bl[22:16];
		3'd4: bl_c[22:16] = g_cfg[4].r_bl[22:16];
		3'd5: bl_c[22:16] = g_cfg[5].r_bl[22:16];
		3'd6: bl_c[22:16] = g_cfg[6].r_bl[22:16];
		default: bl_c[22:16] = g_cfg[7].r_bl[22:16];
		endcase
	end

	/* Registered selected attachment properties (latched every cycle from i_rt) */
	reg [7:0] vk;
	(* keep = "true", dont_touch = "true" *) reg [7:0] vk_pack_a, vk_pack_b;
	reg [4:0] ps;
	(* keep = "true", dont_touch = "true" *) reg [2:0] psl_slot [0:3];
	(* keep = "true", dont_touch = "true" *) reg [2:0] psl_dst [0:3][0:9];
	reg [1:0] path;
	reg drop, read;
	(* keep = "true", dont_touch = "true" *) reg multi_out;
	(* keep = "true", dont_touch = "true" *) reg [3:0] multi_slot;
	reg [1:0] nl_r, np_r;
	reg [2:0] xsh, el;
	(* keep = "true", dont_touch = "true" *) reg [2:0] xsh_int_lo, xsh_int_hi;
	(* keep = "true", dont_touch = "true" *) reg [3:0] wm_a, wm_b;
	reg [22:0] bl;
	reg [31:0] sel_base, sel_stride;
	reg [16:0] yr_r;
	reg [15:0] x_r;

	wire [2:0] psl_c_buf [0:3];
`ifdef SYNTH_KINTEX7
	genvar g_pslb, g_pslk;
	generate
	for (g_pslk = 0; g_pslk < 4; g_pslk = g_pslk + 1) begin : g_psl_slot_buf
		for (g_pslb = 0; g_pslb < 3; g_pslb = g_pslb + 1) begin : g_psl_bit_buf
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_psl (
				.I0(psl_c[g_pslb]), .O(psl_c_buf[g_pslk][g_pslb])
			);
		end
	end
	endgenerate
`else
	assign psl_c_buf[0] = psl_c;
	assign psl_c_buf[1] = psl_c;
	assign psl_c_buf[2] = psl_c;
	assign psl_c_buf[3] = psl_c;
`endif

	(* keep = "true", dont_touch = "true" *) reg [1:0] path_rep [0:3];
	(* keep = "true", dont_touch = "true" *) reg [1:0] psl_pk_lo [0:3][0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] psl_pk_is16 [0:3];
	(* keep = "true", dont_touch = "true" *) reg [1:0] f32_ps_sel_r [0:3][0:7];

	integer is, is2;
	always @(posedge wpix_act_clk) begin
		if (rst_sync) begin
			vk <= 8'd44;
			vk_pack_a <= 8'd44;
			vk_pack_b <= 8'd44;
			ps <= 5'd4;
			for (is = 0; is < 4; is = is + 1) begin
				psl_slot[is] <= 3'd2;
				path_rep[is] <= 2'd0;
				psl_pk_is16[is] <= 4'd0;
				for (is2 = 0; is2 < 4; is2 = is2 + 1)
					psl_pk_lo[is][is2] <= 2'd2;
				for (is2 = 0; is2 < 8; is2 = is2 + 1)
					f32_ps_sel_r[is][is2] <= 2'd0;
				for (is2 = 0; is2 < 10; is2 = is2 + 1)
					psl_dst[is][is2] <= 3'd2;
			end
			path <= 2'd0;
			drop <= 1'b0;
			read <= 1'b0;
			multi_out <= 1'b0;
			multi_slot <= 4'd0;
			nl_r <= 2'd0;
			np_r <= 2'd0;
			xsh <= 3'd2;
			xsh_int_lo <= 3'd2;
			xsh_int_hi <= 3'd2;
			el <= 3'd3;
			wm_a <= 4'hF;
			wm_b <= 4'hF;
			bl <= 23'd0;
			sel_base <= 32'd0;
			sel_stride <= 32'd0;
			yr_r <= 17'd0;
			x_r <= 16'd0;
		end else begin
			vk <= vk_c;
			vk_pack_a <= vk_c;
			vk_pack_b <= vk_c;
			ps <= ps_c;
			for (is = 0; is < 4; is = is + 1) begin
				psl_slot[is] <= psl_c_buf[is];
				path_rep[is] <= path_c;
				psl_pk_is16[is] <= {4{psl_slot[is][2]}};
`ifdef SYNTH_KINTEX7
				for (is2 = 0; is2 < 4; is2 = is2 + 1)
					psl_pk_lo[is][is2] <= (psl_slot[is] >= 3'd3) ? 2'd3 : psl_slot[is][1:0];
				for (is2 = 0; is2 < 8; is2 = is2 + 1)
					f32_ps_sel_r[is][is2] <= (path_rep[is] != 2'd1) ? 2'd0 :
						((psl_slot[is] >= 3'd3) ? 2'd3 : psl_slot[is][1:0]);
`else
				psl_pk_lo[is][0] <= (psl_slot[is] >= 3'd3) ? 2'd3 : psl_slot[is][1:0];
				f32_ps_sel_r[is][0] <= (path_rep[is] != 2'd1) ? 2'd0 :
					((psl_slot[is] >= 3'd3) ? 2'd3 : psl_slot[is][1:0]);
`endif
				for (is2 = 0; is2 < 10; is2 = is2 + 1)
					psl_dst[is][is2] <= psl_c_buf[is];
			end
			path <= path_c;
			drop <= drop_c;
			read <= read_c;
			multi_out <= multi_c;
			multi_slot <= {4{multi_c}};
			nl_r <= multi_c ? (nll_c == 4'd1 ? 2'd1 : 2'd3) : 2'd0;
			np_r <= (!multi_c && ms4) ? 2'd3 : 2'd0;
			xsh <= xsh_c;
			xsh_int_lo <= xsh_c;
			xsh_int_hi <= xsh_c;
			el <= el_c;
			wm_a <= wm_c;
			wm_b <= wm_c;
			bl <= bl_c;
			sel_base[7:0]   <= base[i_rt_b0][7:0];
			sel_base[15:8]  <= base[i_rt_b1][15:8];
			sel_base[23:16] <= base[i_rt_b2][23:16];
			sel_base[31:24] <= base[i_rt_b3][31:24];
			sel_stride[7:0]   <= stride[i_rt_s0][7:0];
			sel_stride[15:8]  <= stride[i_rt_s1][15:8];
			sel_stride[23:16] <= stride[i_rt_s2][23:16];
			sel_stride[31:24] <= stride[i_rt_s3][31:24];
			yr_r <= {1'b0, i_xy[31:16]};
			x_r <= i_xy[15:0];
		end
	end

	assign o_path = path;
	assign o_drop = drop;
	assign o_read = read;
	assign o_ps = ps;
	assign o_multi = multi_out;
	assign o_nl = nl_r;
	assign o_np = np_r;
	assign o_xsh = xsh;
	assign o_stride = sel_stride;

	/* Row base & xoff pipeline:
	 * - u_xoff_lo / u_xoff_hi shift registered x_r by registered xsh_int_lo / xsh_int_hi -> registered xoff_r -> registered xoff_j_r (0 CARRY4s)
	 * - u_yrs multiplies registered yr_r by registered sel_stride -> registered yrs_r (0 Pre/Post-DSP LUTs)
	 * - u_a1 adds registered sel_base + registered yrs_r -> o_row_base0 (1 Pre-CARRY4 LUT, 0 Post-CARRY4 LUTs)
	 */
	wire [11:0] xoff_lo;
	wire [19:0] xoff_hi_full;
	am_shift #(.W(12), .SW(3)) u_xoff_lo (.a(x_r[11:0]), .amt(xsh_int_lo), .left(1'b1), .arith(1'b0), .y(xoff_lo));
	am_shift #(.W(20), .SW(3)) u_xoff_hi (.a({8'd0, x_r[15:4]}), .amt(xsh_int_hi), .left(1'b1), .arith(1'b0), .y(xoff_hi_full));
	wire [31:0] xoff = {8'd0, xoff_hi_full[19:8], xoff_lo};
	wire unused_xoff_hi = &{1'b0, xoff_hi_full[7:0]};

	reg [31:0] xoff_r, xoff_j_r;
	wire [48:0] yrs;
	am_mul #(.AW(17), .BW(32), .LAT(2)) u_yrs (.clk(wpix_act_clk), .en(1'b1), .a(yr_r), .b(sel_stride), .p(yrs));

	reg [31:0] yrs_r;
	always @(posedge wpix_act_clk) begin
		if (rst_sync) begin
			xoff_r <= 32'd0;
			xoff_j_r <= 32'd0;
			yrs_r <= 32'd0;
		end else begin
			xoff_r <= xoff;
`ifdef MUT_WPIX_LINE
			xoff_j_r <= xoff_r;
`else
			xoff_j_r <= xoff_r | (multi_slot[0] ? {{(30-LINE_SHIFT){1'b0}}, i_j, {LINE_SHIFT{1'b0}}} : 32'd0);
`endif
			yrs_r <= yrs[31:0];
		end
	end

	wire [31:0] a1;
	wire a1_co_unused;
	am_add #(.W(32)) u_a1 (.a(sel_base), .b(yrs_r), .ci(1'b0), .s(a1), .co(a1_co_unused));
	assign o_row_base0 = a1;
	assign o_row_base1 = 32'd0;
	assign o_xoff = xoff_r;
	assign o_xoff_j = xoff_j_r;
	assign o_addr = 32'd0;
	assign o_addr1 = 32'd0;

	/* 2-stage registered blend constant kcv (1 LUT level per stage) */
	reg [127:0] kc8_unorm_r, kcv_r;
`ifdef SYNTH_KINTEX7
	wire [7:0] kc_sel_buf;
	genvar g_kcb;
	generate
	for (g_kcb = 0; g_kcb < 8; g_kcb = g_kcb + 1) begin : g_kcsel_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_kcb (.I0(kc_sel), .O(kc_sel_buf[g_kcb]));
	end
	endgenerate
`else
	wire [7:0] kc_sel_buf = {8{kc_sel}};
`endif
	wire [127:0] kcf_vec = {kcf[3], kcf[2], kcf[1], kcf[0]};
	integer ikc;
	always @(posedge wpix_st_clk) begin
		if (rst_sync) begin
			kc8_unorm_r <= 128'd0;
			kcv_r <= 128'd0;
		end else begin
			kc8_unorm_r <= {
				rom_unorm8[kc8[31:24]],
				rom_unorm8[kc8[23:16]],
				rom_unorm8[kc8[15:8]],
				rom_unorm8[kc8[7:0]]
			};
			for (ikc = 0; ikc < 8; ikc = ikc + 1)
				kcv_r[16 * ikc +: 16] <= kc_sel_buf[ikc] ? kcf_vec[16 * ikc +: 16] : kc8_unorm_r[16 * ikc +: 16];
		end
	end

	/* Pure-LUT helper functions (0 CARRY4s) */
	function [LINE_SHIFT-1:0] shift_left_psl;
		input [2:0] val;
		input [2:0] sh;
		case (sh)
		3'd0: shift_left_psl = {{(LINE_SHIFT-3){1'b0}}, val};
		3'd1: shift_left_psl = {{(LINE_SHIFT-4){1'b0}}, val, 1'b0};
		3'd2: shift_left_psl = {{(LINE_SHIFT-5){1'b0}}, val, 2'b00};
		3'd3: shift_left_psl = {val[LINE_SHIFT-4:0], 3'b000};
		default: shift_left_psl = {val[LINE_SHIFT-5:0], 4'b0000};
		endcase
	endfunction

	function [3:0] shift_left_el;
		input [1:0] val;
		input [2:0] sh;
		case (sh)
		3'd0: shift_left_el = {2'b00, val};
		3'd1: shift_left_el = {1'b0, val, 1'b0};
		default: shift_left_el = {val, 2'b00};
		endcase
	endfunction

	/* Pure-LUT 4-bit + 2-bit constant addition (0 CARRY4s, 1 LUT4 per bit) */
	function [3:0] add4_const_lut;
		input [3:0] a;
		input [1:0] k_val;
		reg c0, c1, c2;
		begin
			c0 = a[0] & k_val[0];
			c1 = (a[1] & k_val[1]) | ((a[1] ^ k_val[1]) & c0);
			c2 = a[2] & c1;
			add4_const_lut = {
				a[3] ^ c2,
				a[2] ^ c1,
				a[1] ^ k_val[1] ^ c0,
				a[0] ^ k_val[0]
			};
		end
	endfunction

	/* Pure-LUT LINE_SHIFT-bit addition for slot byte offset (0 CARRY4s) */
	function [LINE_SHIFT-1:0] add_ls_lut;
		input [LINE_SHIFT-1:0] a;
		input [LINE_SHIFT-1:0] b;
		reg [LINE_SHIFT:0] c;
		integer bi;
		begin
			c[0] = 1'b0;
			for (bi = 0; bi < LINE_SHIFT; bi = bi + 1) begin
				add_ls_lut[bi] = a[bi] ^ b[bi] ^ c[bi];
				c[bi + 1] = (a[bi] & b[bi]) | ((a[bi] ^ b[bi]) & c[bi]);
			end
		end
	endfunction

	/* 2-stage pipelined slot gather (S_BLEND_PREP1 -> S_BLEND_PREP2 -> S_BLEND):
	 * Stage 1 latches slot_o_r, slot_o_rep, slot_en_r, slot_en_rep, slot_mk_r, slot_src_r.
	 * Stage 2 latches slot_dst128_r from i_line0/i_line1.
	 */
	reg [LINE_SHIFT-1:0] slot_o_r [0:3];
	(* keep = "true", dont_touch = "true" *) reg [LINE_SHIFT-1:0] slot_o_rep [0:3][0:7];
	(* keep = "true", dont_touch = "true" *) reg [3:0] slot_o_dst [0:3][0:9];
	reg [3:0] slot_en_r;
	(* keep = "true", dont_touch = "true" *) reg [7:0] slot_en_rep [0:3];
	reg [3:0] slot_mk_r;
	reg [127:0] slot_src_r [0:3];
	reg [127:0] slot_dst128_r [0:3];

	wire [3:0] mk_comb;
	genvar k, g_rep;
	generate
	for (k = 0; k < 4; k = k + 1) begin : g_slot
		localparam [1:0] K2 = k[1:0];
		wire [1:0] i_g_k;
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ig0 (.I0(i_g[0]), .O(i_g_k[0]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ig1 (.I0(i_g[1]), .O(i_g_k[1]));
`else
		assign i_g_k = i_g;
`endif
		wire [3:0] nj = shift_left_el(i_j, el);
		(* keep = "true" *) wire [3:0] n = add4_const_lut(nj, K2);
		wire [1:0] ln = multi_slot[k] ? {i_r, n[2]} : K2;
		wire [LINE_SHIFT-1:0] o1s = shift_left_psl(ms4 ? {k[0], i_g_k} : {2'b00, k[0]}, psl_slot[k]);
		wire [LINE_SHIFT-1:0] off_base = (k >= 2) ? i_off1 : i_off0;
		wire [LINE_SHIFT-1:0] off_p1_base = (k >= 2) ? i_off1_p1 : i_off0_p1;
		(* keep = "true" *) wire [LINE_SHIFT-1:0] o1_ms = add_ls_lut(off_base, o1s);
		wire [LINE_SHIFT-1:0] o1 = ms4 ? o1_ms : (k[0] ? off_p1_base : off_base);
		wire [LINE_SHIFT-1:0] om = shift_left_psl({1'b0, K2}, psl_slot[k]);
		(* keep = "true" *) wire [LINE_SHIFT-1:0] o = multi_slot[k] ? om : o1;
		wire en_k = multi_slot[k] ? i_r : (k >= 2);
		wire mk_k = multi_slot[k] ? ((el == 3'd2 || k < 2) && i_smask[{ln, n[1:0]}]) : i_smask[{ln, i_g_k}];
		assign mk_comb[k] = mk_k;

		/* Replicate ln into 8 copies (16 bits of i_color each) via LUT1 buffers so fanout <= 16 */
		wire [127:0] src_k_comb;
		for (g_rep = 0; g_rep < 8; g_rep = g_rep + 1) begin : g_src_mux
			wire [1:0] ln_b;
`ifdef SYNTH_KINTEX7
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ln0 (.I0(ln[0]), .O(ln_b[0]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ln1 (.I0(ln[1]), .O(ln_b[1]));
`else
			assign ln_b = ln;
`endif
			assign src_k_comb[16 * g_rep +: 16] = i_color[{ln_b, g_rep[2:0], 4'b0000} +: 16];
		end

		integer ir;
		always @(posedge wpix_act_clk) begin
			if (rst_sync) begin
				slot_o_r[k] <= {LINE_SHIFT{1'b0}};
				for (ir = 0; ir < 8; ir = ir + 1)
					slot_o_rep[k][ir] <= {LINE_SHIFT{1'b0}};
				for (ir = 0; ir < 10; ir = ir + 1)
					slot_o_dst[k][ir] <= 4'd0;
				slot_en_r[k] <= 1'b0;
				slot_en_rep[k] <= 8'd0;
				slot_mk_r[k] <= 1'b0;
				slot_src_r[k] <= 128'd0;
			end else begin
				slot_o_r[k] <= o;
				for (ir = 0; ir < 8; ir = ir + 1)
					slot_o_rep[k][ir] <= o;
				for (ir = 0; ir < 10; ir = ir + 1)
					slot_o_dst[k][ir] <= o[3:0];
				slot_en_r[k] <= en_k;
				slot_en_rep[k] <= {8{en_k}};
				slot_mk_r[k] <= mk_k;
				slot_src_r[k] <= src_k_comb;
			end
		end

		/* Stage 2: extract 128-bit old pixel from i_line0 / i_line1 using replicated slot_o_rep and slot_en_rep */
		(* keep = "true" *) wire [127:0] blk;
		for (g_rep = 0; g_rep < 8; g_rep = g_rep + 1) begin : g_blk_mux
			wire [LINE_SHIFT-1:4] o_hi = slot_o_rep[k][g_rep][LINE_SHIFT-1:4];
			assign blk[16 * g_rep +: 16] = slot_en_rep[k][g_rep] ?
				i_line1[{o_hi, g_rep[2:0], 4'b0000} +: 16] :
				i_line0[{o_hi, g_rep[2:0], 4'b0000} +: 16];
		end

		wire [2:0] psl_d0a = psl_dst[k][0];
		wire [2:0] psl_d0b = psl_dst[k][1];
		wire [2:0] psl_d0c = psl_dst[k][2];
		wire [2:0] psl_d0d = psl_dst[k][3];
		wire [2:0] psl_d1a = psl_dst[k][4];
		wire [2:0] psl_d1b = psl_dst[k][5];
		wire [2:0] psl_d2  = psl_dst[k][6];
		wire [2:0] psl_d3  = psl_dst[k][7];
		wire [2:0] psl_d4  = psl_dst[k][8];
		wire [2:0] psl_d5  = psl_dst[k][9];
		wire [127:0] dst_k_comb;
		assign dst_k_comb[1:0] = psl_d0a[2] ? blk[1:0] :
			(psl_d0a == 3'd3) ? blk[{slot_o_dst[k][0][3], 6'b00_0000} +: 2] :
			(psl_d0a == 3'd2) ? blk[{slot_o_dst[k][0][3:2], 5'b0_0000} +: 2] :
			(psl_d0a == 3'd1) ? blk[{slot_o_dst[k][0][3:1], 4'b0000} +: 2] :
			blk[{slot_o_dst[k][0][3:0], 3'b000} +: 2];
		assign dst_k_comb[3:2] = psl_d0a[2] ? blk[3:2] :
			(psl_d0a == 3'd3) ? blk[{slot_o_dst[k][1][3], 6'b00_0010} +: 2] :
			(psl_d0a == 3'd2) ? blk[{slot_o_dst[k][1][3:2], 5'b0_0010} +: 2] :
			(psl_d0a == 3'd1) ? blk[{slot_o_dst[k][1][3:1], 4'b0010} +: 2] :
			blk[{slot_o_dst[k][1][3:0], 3'b010} +: 2];
		assign dst_k_comb[5:4] = psl_d0b[2] ? blk[5:4] :
			(psl_d0b == 3'd3) ? blk[{slot_o_dst[k][2][3], 6'b00_0100} +: 2] :
			(psl_d0b == 3'd2) ? blk[{slot_o_dst[k][2][3:2], 5'b0_0100} +: 2] :
			(psl_d0b == 3'd1) ? blk[{slot_o_dst[k][2][3:1], 4'b0100} +: 2] :
			blk[{slot_o_dst[k][2][3:0], 3'b100} +: 2];
		assign dst_k_comb[7:6] = psl_d0b[2] ? blk[7:6] :
			(psl_d0b == 3'd3) ? blk[{slot_o_dst[k][3][3], 6'b00_0110} +: 2] :
			(psl_d0b == 3'd2) ? blk[{slot_o_dst[k][3][3:2], 5'b0_0110} +: 2] :
			(psl_d0b == 3'd1) ? blk[{slot_o_dst[k][3][3:1], 4'b0110} +: 2] :
			blk[{slot_o_dst[k][3][3:0], 3'b110} +: 2];
		assign dst_k_comb[11:8] = psl_d0c[2] ? blk[11:8] :
			(psl_d0c == 3'd3) ? blk[{slot_o_dst[k][4][3], 6'b00_1000} +: 4] :
			(psl_d0c == 3'd2) ? blk[{slot_o_dst[k][4][3:2], 5'b0_1000} +: 4] :
			(psl_d0c == 3'd1) ? blk[{slot_o_dst[k][4][3:1], 4'b1000} +: 4] :
			4'd0;
		assign dst_k_comb[15:12] = psl_d0d[2] ? blk[15:12] :
			(psl_d0d == 3'd3) ? blk[{slot_o_dst[k][5][3], 6'b00_1100} +: 4] :
			(psl_d0d == 3'd2) ? blk[{slot_o_dst[k][5][3:2], 5'b0_1100} +: 4] :
			(psl_d0d == 3'd1) ? blk[{slot_o_dst[k][5][3:1], 4'b1100} +: 4] :
			4'd0;
		assign dst_k_comb[23:16] = psl_d1a[2] ? blk[23:16] :
			(psl_d1a == 3'd3) ? blk[{slot_o_dst[k][6][3], 6'b01_0000} +: 8] :
			(psl_d1a == 3'd2) ? blk[{slot_o_dst[k][6][3:2], 5'b1_0000} +: 8] : 8'd0;
		assign dst_k_comb[31:24] = psl_d1b[2] ? blk[31:24] :
			(psl_d1b == 3'd3) ? blk[{slot_o_dst[k][7][3], 6'b01_1000} +: 8] :
			(psl_d1b == 3'd2) ? blk[{slot_o_dst[k][7][3:2], 5'b1_1000} +: 8] : 8'd0;
		assign dst_k_comb[47:32] = psl_d2[2] ? blk[47:32] :
			(psl_d2 == 3'd3) ? blk[{slot_o_dst[k][8][3], 6'b10_0000} +: 16] : 16'd0;
		assign dst_k_comb[63:48] = psl_d3[2] ? blk[63:48] :
			(psl_d3 == 3'd3) ? blk[{slot_o_dst[k][9][3], 6'b11_0000} +: 16] : 16'd0;
		wire dst_rst_64, dst_rst_80, dst_rst_96, dst_rst_112;
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) LUT2 #(.INIT(4'hB)) u_dr64  (.I0(rst_sync), .I1(psl_d4[2]), .O(dst_rst_64));
		(* keep = "true", dont_touch = "true" *) LUT2 #(.INIT(4'hB)) u_dr80  (.I0(rst_sync), .I1(psl_d4[2]), .O(dst_rst_80));
		(* keep = "true", dont_touch = "true" *) LUT2 #(.INIT(4'hB)) u_dr96  (.I0(rst_sync), .I1(psl_d5[2]), .O(dst_rst_96));
		(* keep = "true", dont_touch = "true" *) LUT2 #(.INIT(4'hB)) u_dr112 (.I0(rst_sync), .I1(psl_d5[2]), .O(dst_rst_112));
`else
		assign dst_rst_64  = rst_sync || !psl_d4[2];
		assign dst_rst_80  = rst_sync || !psl_d4[2];
		assign dst_rst_96  = rst_sync || !psl_d5[2];
		assign dst_rst_112 = rst_sync || !psl_d5[2];
`endif
		assign dst_k_comb[127:64] = blk[127:64];

		always @(posedge wpix_act_clk) begin
			if (rst_sync)
				slot_dst128_r[k][63:0] <= 64'd0;
			else
				slot_dst128_r[k][63:0] <= dst_k_comb[63:0];

			if (dst_rst_64)
				slot_dst128_r[k][79:64] <= 16'd0;
			else
				slot_dst128_r[k][79:64] <= dst_k_comb[79:64];

			if (dst_rst_80)
				slot_dst128_r[k][95:80] <= 16'd0;
			else
				slot_dst128_r[k][95:80] <= dst_k_comb[95:80];

			if (dst_rst_96)
				slot_dst128_r[k][111:96] <= 16'd0;
			else
				slot_dst128_r[k][111:96] <= dst_k_comb[111:96];

			if (dst_rst_112)
				slot_dst128_r[k][127:112] <= 16'd0;
			else
				slot_dst128_r[k][127:112] <= dst_k_comb[127:112];
		end

		wire unused_n = &{1'b0, n[3], psl_d4[1:0], psl_d5[1:0],
			slot_o_dst[k][4][0], slot_o_dst[k][5][0], slot_o_dst[k][6][1:0], slot_o_dst[k][7][1:0],
			slot_o_dst[k][8][2:0], slot_o_dst[k][9][2:0],
			slot_o_rep[k][0][3:0], slot_o_rep[k][1][3:0], slot_o_rep[k][2][3:0], slot_o_rep[k][3][3:0],
			slot_o_rep[k][4][3:0], slot_o_rep[k][5][3:0], slot_o_rep[k][6][3:0], slot_o_rep[k][7][3:0]};
	end
	endgenerate

	assign o_mask = slot_mk_r;
	assign o_lw = multi_slot[0] ? (slot_mk_r != 4'd0) : (i_smask[8 * i_r +: 8] != 8'd0);
	assign o_ent = slot_en_r;
	assign o_soff = {slot_o_r[3], slot_o_r[2], slot_o_r[1], slot_o_r[0]};
	assign o_bsrc = {slot_src_r[3], slot_src_r[2], slot_src_r[1], slot_src_r[0]};
	assign o_bdst = {slot_dst128_r[3][31:0], slot_dst128_r[2][31:0], slot_dst128_r[1][31:0], slot_dst128_r[0][31:0]};

	wire [255:0] f_dst = {slot_dst128_r[3][63:0], slot_dst128_r[2][63:0], slot_dst128_r[1][63:0], slot_dst128_r[0][63:0]};
`ifdef SYNTH_KINTEX7
	wire [511:0] f_src = o_bsrc;
	wire [255:0] f_dst_in = f_dst;
`else
	wire [511:0] f_src = (path == 2'd1) ? o_bsrc : 512'd0;
	wire [255:0] f_dst_in = (path == 2'd1) ? f_dst : 256'd0;
`endif
	wire [3:0] f_mk = slot_mk_r;
	wire [255:0] f_raw, f_keep;
	wire f_idle;

	generate
	if (`CFG_ROP_ENABLE_FBLEND != 0) begin : g_fblend
`ifdef SYNTH_KINTEX7
		wire fblend_clk = clk;
`else
		reg [4:0] f_sim_cnt;
		wire [4:0] f_sim_cnt_next = {
			f_sim_cnt[4] ^ (f_sim_cnt[3:0] == 4'd0),
			f_sim_cnt[3] ^ (f_sim_cnt[2:0] == 3'd0),
			f_sim_cnt[2] ^ (f_sim_cnt[1:0] == 2'd0),
			f_sim_cnt[1] ^ ~f_sim_cnt[0],
			~f_sim_cnt[0]
		};
		always @(posedge clk) begin
			if (!rst_n) begin
				f_sim_cnt <= 5'd3;
			end else if (f_go) begin
				f_sim_cnt <= 5'd29;
			end else if (f_sim_cnt != 5'd0) begin
				f_sim_cnt <= f_sim_cnt_next;
			end
		end
		reg f_icg_en;
		always @(negedge clk) begin
			if (!rst_n)
				f_icg_en <= 1'b1;
			else
				f_icg_en <= f_go || (f_sim_cnt != 5'd0);
		end
		wire fblend_clk = clk & f_icg_en;
`endif
		atg_rop_fblend fblend (
			.clk(fblend_clk), .rst_n(rst_n),
			.i_valid(f_go), .i_ready(f_idle),
			.i_lanes(f_mk), .i_src(f_src), .i_dst(f_dst_in),
			.i_fmt(vk), .i_blend(bl), .i_const(kcv_r), .i_wm(wm_a),
			.o_valid(f_done), .o_ready(f_take),
			.o_raw(f_raw), .o_keep(f_keep)
		);
	end else begin : g_no_fblend
		assign f_idle = 1'b1;
		assign f_done = f_go;
		assign f_raw = 256'd0;
		assign f_keep = 256'd0;
	end
	endgenerate

	/* Pipelined Path 2 format packer (24 integer and 32-bit float formats, <= 2 LUT levels per stage) */
	localparam integer N_P2 = 24;
	localparam [191:0] P2F = {8'd109, 8'd108, 8'd107, 8'd103, 8'd102, 8'd101, 8'd100, 8'd99, 8'd98,
		8'd96, 8'd95, 8'd82, 8'd81, 8'd75, 8'd74, 8'd68, 8'd56, 8'd55, 8'd42, 8'd41, 8'd21, 8'd20,
		8'd14, 8'd13};

	function [192*N_P2-1:0] ptab_p2;
		input integer unused_n;
		integer pi, pk, pb;
		reg [67:0] inf;
		reg [25:0] ft;
		reg [5:0] w;
		reg [31:0] m;
		begin
			ptab_p2 = {192*N_P2{1'b0}};
			for (pi = 0; pi < N_P2; pi = pi + 1) begin
				inf = atg_fmt_info(P2F[8 * pi +: 8]);
				ft = atg_fmt_feat(P2F[8 * pi +: 8], 1'b0);
				for (pk = 0; pk < 4; pk = pk + 1) begin
					w = inf[23 + 13 * pk +: 6];
					for (pb = 0; pb < 32; pb = pb + 1)
						m[pb] = pb < w;
					ptab_p2[48 * (4 * pi + pk) +: 48] = {6'd0, ft[7] && pk < inf[8:6], 2'd0, m,
						inf[16 + 13 * pk +: 7]};
				end
			end
		end
	endfunction
	localparam [192*N_P2-1:0] PTAB_P2 = ptab_p2(N_P2);

	/* Stage 1 of Path-2 packer: decode format hit & write-mask per format (replicated per lane & even/odd 16-bit slice) */
	(* keep = "true", dont_touch = "true" *) reg [3:0] p2_hit_wm_wr_b0 [0:N_P2-1];
	(* keep = "true", dont_touch = "true" *) reg [3:0] p2_hit_wm_wr_b1 [0:N_P2-1];
	(* keep = "true", dont_touch = "true" *) reg [3:0] p2_hit_wm_l_b0 [0:3][0:N_P2-1];
	(* keep = "true", dont_touch = "true" *) reg [3:0] p2_hit_wm_l_b1 [0:3][0:N_P2-1];
	(* keep = "true", dont_touch = "true" *) reg [N_P2-1:0] p2_hit_v;
	genvar gi, gg, gc_p2;
	generate
	for (gi = 0; gi < N_P2; gi = gi + 1) begin : g_p2_dec
		localparam [7:0] F = P2F[8 * gi +: 8];
		wire [7:0] vk_cur = (gi < 12) ? vk_pack_a : vk_pack_b;
		wire [3:0] wm_cur = (gi < 12) ? wm_a : wm_b;
		wire hit_i = (vk_cur == F);
		wire [3:0] hit_wm_i;
`ifdef SYNTH_KINTEX7
		for (gc_p2 = 0; gc_p2 < 4; gc_p2 = gc_p2 + 1) begin : g_hwm
			(* keep = "true", dont_touch = "true" *) LUT2 #(.INIT(4'h8)) u_hwm (
				.I0(hit_i), .I1(wm_cur[gc_p2]), .O(hit_wm_i[gc_p2])
			);
		end
`else
		assign hit_wm_i = hit_i ? wm_cur : 4'd0;
`endif
		integer il_p2;
		always @(posedge wpix_p2_clk) begin
			p2_hit_wm_wr_b0[gi] <= hit_wm_i;
			p2_hit_wm_wr_b1[gi] <= hit_wm_i;
			for (il_p2 = 0; il_p2 < 4; il_p2 = il_p2 + 1) begin
				p2_hit_wm_l_b0[il_p2][gi] <= hit_wm_i;
				p2_hit_wm_l_b1[il_p2][gi] <= hit_wm_i;
			end
			p2_hit_v[gi] <= hit_i;
		end
	end
	endgenerate

	/* Shared write-mask expansion across the 24 formats (2 stages: 4 groups of 6 -> final 128-bit wr) */
	wire [127:0] p2_wr_leaf [0:N_P2-1];
	generate
	for (gi = 0; gi < N_P2; gi = gi + 1) begin : g_p2_wr_leaf
		localparam [47:0] E0 = PTAB_P2[48 * (4 * gi) +: 48];
		localparam [47:0] E1 = PTAB_P2[48 * (4 * gi + 1) +: 48];
		localparam [47:0] E2 = PTAB_P2[48 * (4 * gi + 2) +: 48];
		localparam [47:0] E3 = PTAB_P2[48 * (4 * gi + 3) +: 48];
		localparam [6:0] P0 = E0[6:0], P1 = E1[6:0], P2 = E2[6:0], P3 = E3[6:0];
		localparam [127:0] M0 = E0[41] ? ({96'd0, E0[38:7]} << P0) : 128'd0;
		localparam [127:0] M1 = E1[41] ? ({96'd0, E1[38:7]} << P1) : 128'd0;
		localparam [127:0] M2 = E2[41] ? ({96'd0, E2[38:7]} << P2) : 128'd0;
		localparam [127:0] M3 = E3[41] ? ({96'd0, E3[38:7]} << P3) : 128'd0;
		for (gg = 0; gg < 4; gg = gg + 1) begin : g_wr_q
			assign p2_wr_leaf[gi][32 * gg +: 16] =
				(p2_hit_wm_wr_b0[gi][0] ? M0[32 * gg +: 16] : 16'd0) |
				(p2_hit_wm_wr_b0[gi][1] ? M1[32 * gg +: 16] : 16'd0) |
				(p2_hit_wm_wr_b0[gi][2] ? M2[32 * gg +: 16] : 16'd0) |
				(p2_hit_wm_wr_b0[gi][3] ? M3[32 * gg +: 16] : 16'd0);
			assign p2_wr_leaf[gi][32 * gg + 16 +: 16] =
				(p2_hit_wm_wr_b1[gi][0] ? M0[32 * gg + 16 +: 16] : 16'd0) |
				(p2_hit_wm_wr_b1[gi][1] ? M1[32 * gg + 16 +: 16] : 16'd0) |
				(p2_hit_wm_wr_b1[gi][2] ? M2[32 * gg + 16 +: 16] : 16'd0) |
				(p2_hit_wm_wr_b1[gi][3] ? M3[32 * gg + 16 +: 16] : 16'd0);
		end
	end
	endgenerate

	(* keep = "true", dont_touch = "true" *) reg [127:0] p2_wr_grp [0:3];
	(* keep = "true", dont_touch = "true" *) reg [3:0] p2_hit_grp;
	(* keep = "true", dont_touch = "true" *) reg [127:0] p2_wr_r [0:3];
	(* keep = "true", dont_touch = "true" *) reg [7:0] p2_hit_rep [0:3];
	integer ig;
	always @(posedge wpix_p2_clk) begin
		for (ig = 0; ig < 4; ig = ig + 1) begin
			p2_wr_grp[ig] <= p2_wr_leaf[6*ig + 0] | p2_wr_leaf[6*ig + 1] | p2_wr_leaf[6*ig + 2] |
				p2_wr_leaf[6*ig + 3] | p2_wr_leaf[6*ig + 4] | p2_wr_leaf[6*ig + 5];
			p2_hit_grp[ig] <= |p2_hit_v[6*ig +: 6];
		end
	end

	generate
	for (k = 0; k < 4; k = k + 1) begin : g_res
		wire hit_any_k;
		wire [127:0] wr_or_k;
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) LUT4 #(.INIT(16'hFFFE)) u_hany (
			.I0(p2_hit_grp[0]), .I1(p2_hit_grp[1]), .I2(p2_hit_grp[2]), .I3(p2_hit_grp[3]),
			.O(hit_any_k)
		);
		for (gg = 0; gg < 128; gg = gg + 1) begin : g_wror
			(* keep = "true", dont_touch = "true" *) LUT4 #(.INIT(16'hFFFE)) u_wo (
				.I0(p2_wr_grp[0][gg]), .I1(p2_wr_grp[1][gg]), .I2(p2_wr_grp[2][gg]), .I3(p2_wr_grp[3][gg]),
				.O(wr_or_k[gg])
			);
		end
`else
		assign hit_any_k = |p2_hit_grp;
		assign wr_or_k = p2_wr_grp[0] | p2_wr_grp[1] | p2_wr_grp[2] | p2_wr_grp[3];
`endif
		always @(posedge wpix_p2_clk) begin
			p2_hit_rep[k] <= {8{hit_any_k}};
			p2_wr_r[k] <= wr_or_k;
		end

		(* keep = "true", dont_touch = "true" *) reg [127:0] pk_raw_r;
		(* keep = "true", dont_touch = "true" *) reg [127:0] pk_merged_r;
		if (`CFG_ROP_ENABLE_PACK != 0) begin : g_pk
`ifdef SYNTH_KINTEX7
			wire [127:0] c_k = slot_src_r[k];
`else
			wire [127:0] c_k = (path == 2'd2) ? slot_src_r[k] : 128'd0;
`endif
			wire [127:0] raw_leaf [0:N_P2-1];
			for (gi = 0; gi < N_P2; gi = gi + 1) begin : g_raw_leaf
				localparam [47:0] E0 = PTAB_P2[48 * (4 * gi) +: 48];
				localparam [47:0] E1 = PTAB_P2[48 * (4 * gi + 1) +: 48];
				localparam [47:0] E2 = PTAB_P2[48 * (4 * gi + 2) +: 48];
				localparam [47:0] E3 = PTAB_P2[48 * (4 * gi + 3) +: 48];
				localparam [6:0] P0 = E0[6:0], P1 = E1[6:0], P2 = E2[6:0], P3 = E3[6:0];
				localparam [127:0] S0_MASK = {96'd0, E0[38:7]} << P0;
				localparam [127:0] S1_MASK = {96'd0, E1[38:7]} << P1;
				localparam [127:0] S2_MASK = {96'd0, E2[38:7]} << P2;
				localparam [127:0] S3_MASK = {96'd0, E3[38:7]} << P3;
				wire [127:0] s0_sh = ({96'd0, c_k[31:0]}   << P0) & S0_MASK;
				wire [127:0] s1_sh = ({96'd0, c_k[63:32]}  << P1) & S1_MASK;
				wire [127:0] s2_sh = ({96'd0, c_k[95:64]}  << P2) & S2_MASK;
				wire [127:0] s3_sh = ({96'd0, c_k[127:96]} << P3) & S3_MASK;
				for (gg = 0; gg < 4; gg = gg + 1) begin : g_raw_q
					wire [15:0] r0_b0 = (E0[41] && p2_hit_wm_l_b0[k][gi][0]) ? s0_sh[32 * gg +: 16] : 16'd0;
					wire [15:0] r1_b0 = (E1[41] && p2_hit_wm_l_b0[k][gi][1]) ? s1_sh[32 * gg +: 16] : 16'd0;
					wire [15:0] r2_b0 = (E2[41] && p2_hit_wm_l_b0[k][gi][2]) ? s2_sh[32 * gg +: 16] : 16'd0;
					wire [15:0] r3_b0 = (E3[41] && p2_hit_wm_l_b0[k][gi][3]) ? s3_sh[32 * gg +: 16] : 16'd0;
					wire [15:0] r0_b1 = (E0[41] && p2_hit_wm_l_b1[k][gi][0]) ? s0_sh[32 * gg + 16 +: 16] : 16'd0;
					wire [15:0] r1_b1 = (E1[41] && p2_hit_wm_l_b1[k][gi][1]) ? s1_sh[32 * gg + 16 +: 16] : 16'd0;
					wire [15:0] r2_b1 = (E2[41] && p2_hit_wm_l_b1[k][gi][2]) ? s2_sh[32 * gg + 16 +: 16] : 16'd0;
					wire [15:0] r3_b1 = (E3[41] && p2_hit_wm_l_b1[k][gi][3]) ? s3_sh[32 * gg + 16 +: 16] : 16'd0;
					assign raw_leaf[gi][32 * gg +: 16]      = r0_b0 | r1_b0 | r2_b0 | r3_b0;
					assign raw_leaf[gi][32 * gg + 16 +: 16] = r0_b1 | r1_b1 | r2_b1 | r3_b1;
				end
			end

			(* keep = "true", dont_touch = "true" *) reg [127:0] raw_grp [0:3];
			(* keep = "true" *) wire [127:0] pk_m_comb;
			for (gg = 0; gg < 8; gg = gg + 1) begin : g_pkm_comb
`ifdef MUT_WPIX_KEEP
				assign pk_m_comb[16 * gg +: 16] = pk_raw_r[16 * gg +: 16];
`else
				assign pk_m_comb[16 * gg +: 16] = p2_hit_rep[k][gg] ?
					((pk_raw_r[16 * gg +: 16] & p2_wr_r[k][16 * gg +: 16]) |
					 (slot_dst128_r[k][16 * gg +: 16] & ~p2_wr_r[k][16 * gg +: 16])) :
					16'd0;
`endif
			end
			(* keep = "true" *) wire [63:0] pk_w_lo;
`ifdef SYNTH_KINTEX7
			for (gg = 0; gg < 8; gg = gg + 1) begin : g_pkm_wlo
				wire [1:0] psl_lo_k = psl_pk_lo[k][gg / 2];
				assign pk_w_lo[8 * gg +: 8] =
					(psl_lo_k == 2'd3) ? pk_m_comb[8 * gg +: 8] :
					(psl_lo_k == 2'd2) ? pk_m_comb[8 * (gg % 4) +: 8] :
					(psl_lo_k == 2'd1) ? pk_m_comb[8 * (gg % 2) +: 8] :
					                     pk_m_comb[7:0];
			end
`else
			wire [1:0] psl_lo_k = psl_pk_lo[k][0];
			assign pk_w_lo =
				(psl_lo_k == 2'd3) ? pk_m_comb[63:0] :
				(psl_lo_k == 2'd2) ? {2{pk_m_comb[31:0]}} :
				(psl_lo_k == 2'd1) ? {4{pk_m_comb[15:0]}} :
				                     {8{pk_m_comb[7:0]}};
`endif
			integer rg;
			always @(posedge wpix_p2_clk) begin
				for (rg = 0; rg < 4; rg = rg + 1)
					raw_grp[rg] <= raw_leaf[6*rg + 0] | raw_leaf[6*rg + 1] | raw_leaf[6*rg + 2] |
						raw_leaf[6*rg + 3] | raw_leaf[6*rg + 4] | raw_leaf[6*rg + 5];
				pk_raw_r <= raw_grp[0] | raw_grp[1] | raw_grp[2] | raw_grp[3];
				pk_merged_r[63:0] <= pk_w_lo;
`ifdef SYNTH_KINTEX7
				for (rg = 0; rg < 4; rg = rg + 1) begin
					pk_merged_r[64 + 16 * rg +: 16] <= psl_pk_is16[k][rg] ?
						pk_m_comb[64 + 16 * rg +: 16] : pk_w_lo[16 * rg +: 16];
				end
`else
				pk_merged_r[127:64] <= psl_pk_is16[k][0] ? pk_m_comb[127:64] : pk_w_lo;
`endif
			end
		end else begin : g_no_pk
			always @(posedge clk) begin
				pk_raw_r <= 128'd0;
				pk_merged_r <= 128'd0;
			end
		end

		(* keep = "true" *) wire [63:0] fr = (f_raw[64 * k +: 64] & ~f_keep[64 * k +: 64]) |
			(f_dst[64 * k +: 64] & f_keep[64 * k +: 64]);
		wire [127:0] pk_out = (`CFG_ROP_ENABLE_PACK != 0) ? pk_merged_r : 128'd0;
`ifdef SYNTH_KINTEX7
		for (g_rep = 0; g_rep < 16; g_rep = g_rep + 1) begin : g_res_mux
			wire [1:0] f32_sel = f32_ps_sel_r[k][g_rep / 2];
			assign o_res[128 * k + 8 * g_rep +: 8] =
				(f32_sel == 2'd3) ? fr[8 * (g_rep % 8) +: 8] :
				(f32_sel == 2'd2) ? fr[8 * (g_rep % 4) +: 8] :
				(f32_sel == 2'd1) ? fr[8 * (g_rep % 2) +: 8] :
				                    pk_out[8 * g_rep +: 8];
		end
`else
		wire [1:0] f32_sel = f32_ps_sel_r[k][0];
		assign o_res[128 * k +: 128] =
			(f32_sel == 2'd3) ? {2{fr}} :
			(f32_sel == 2'd2) ? {4{fr[31:0]}} :
			(f32_sel == 2'd1) ? {8{fr[15:0]}} :
			                    pk_out;
`endif
	end
	endgenerate

	localparam [31:0] LS32 = LINE_SHIFT;
	wire unused_ok = &{1'b0, f_idle, yrs[48:32], LS32[31:4], a1_co_unused, bl[22:1], f_take, i_idle,
		b_pix, i_reg_off0, i_reg_off1, i_reg_rt, i_reg_color, i_reg_mask, mk_comb};
endmodule

`default_nettype wire
