/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_setup: Stream Setup Engine (Phase 022):
 * Fully-pipelined hardware setup engine replacing the microcoded FSM.
 * Direct feedforward sequencing for perspective divide, viewport mapping,
 * integer edge calculation (atg_rx_edge), plane equations, and depth bias.
 * Instant 1-cycle triangle loading and zero-latency early culling bypass.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_clip */
	input wire cl_valid,
	output wire cl_ready,
	input wire [701:0] cl_tri,
	input wire cl_last,
	/* From Mesh Shader (atg_su_exp_mesh) */
	input wire mesh_valid,
	output wire mesh_ready,
	input wire [701:0] mesh_tri,
	input wire mesh_last,
	input wire [15:0] mesh_id,
	/* To atg_rx_scan */
	output reg sp_valid,
	input wire sp_ready,
	output wire [767:0] sp_tri,
	output wire sp_last,
	output wire busy,
	/* Extended primitive interfaces */
	output wire [2:0] prim_type,
	output wire [15:0] cur_line_width,
	output wire [15:0] cur_point_size,
	output wire [3:0] cur_viewport_idx
);
	`include "ghci_regs.vh"

	localparam [31:0] ONE  = 32'h3F800000;
	localparam [31:0] HALF = 32'h3F000000;

	/* STATE: VIEWPORT 0x050-0x055 (16-entry array), SCISSOR 0x056-0x057 (16 entries),
	 * CULL 0x058, RAST_MODE 0x05A, DEPTH_BIAS_* 0x060-0x062, LINE_WIDTH 0x063,
	 * POINT_SIZE 0x064, VIEWPORT_IDX 0x065, RT_SIZE 0x073.
	 * VIEWPORT words: 0 x_scale, 1 y_scale, 2 x_offset, 3 y_offset, 4 z_scale, 5 z_offset. */
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] vp_array_lo [0:15][0:5];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] vp_array_hi [0:15][0:5];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] smin_array_lo [0:15];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] smin_array_hi [0:15];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] smax_array_lo [0:15];
	(* ram_style = "registers", extract_reset = "no" *) reg [15:0] smax_array_hi [0:15];
	(* max_fanout = 16 *) reg [3:0] vp_idx;
	reg [15:0] line_width;
	reg [15:0] point_size;
	reg [15:0] rts_lo, rts_hi;
	reg [15:0] b_const_lo, b_const_hi;
	reg [15:0] b_slope_lo, b_slope_hi;
	reg [15:0] b_clamp_lo, b_clamp_hi;
	wire [31:0] rts     = {rts_hi, rts_lo};
	wire [31:0] b_const = {b_const_hi, b_const_lo};
	wire [31:0] b_slope = {b_slope_hi, b_slope_lo};
	wire [31:0] b_clamp = {b_clamp_hi, b_clamp_lo};
	reg [2:0] cull;
	reg [5:0] rm;	/* RAST_MODE[5:0] */

	wire [31:0] cur_smin = {smin_array_hi[vp_idx_rs_smin_b7][15:12], smin_array_hi[vp_idx_rs_smin_b6][11:8],
	                        smin_array_hi[vp_idx_rs_smin_b5][7:4],   smin_array_hi[vp_idx_rs_smin_b4][3:0],
	                        smin_array_lo[vp_idx_rs_smin_b3][15:12], smin_array_lo[vp_idx_rs_smin_b2][11:8],
	                        smin_array_lo[vp_idx_rs_smin_b1][7:4],   smin_array_lo[vp_idx_rs_smin_b0][3:0]};
	wire [31:0] cur_smax = {smax_array_hi[vp_idx_rs_smx_b7][15:12],  smax_array_hi[vp_idx_rs_smx_b6][11:8],
	                        smax_array_hi[vp_idx_rs_smx_b5][7:4],   smax_array_hi[vp_idx_rs_smx_b4][3:0],
	                        smax_array_lo[vp_idx_rs_smx_b3][15:12],  smax_array_lo[vp_idx_rs_smx_b2][11:8],
	                        smax_array_lo[vp_idx_rs_smx_b1][7:4],   smax_array_lo[vp_idx_rs_smx_b0][3:0]};

`ifdef SYNTH_KINTEX7
	wire rst_setup_high;
	LUT1 #(.INIT(2'b01)) u_rst_setup (.I0(rst_n), .O(rst_setup_high));

	wire [15:0] vp_w_lo [0:5];
	wire [15:0] vp_w_hi [0:5];
	wire [15:0] smin_lo_buf, smin_hi_buf;
	wire [15:0] smax_lo_buf, smax_hi_buf;
	wire [15:0] misc_lo_buf, misc_hi_buf;

	wire [2:0] st_idx_vp_lo, st_idx_vp_hi;
	genvar gi;
	generate
		for (gi = 0; gi < 3; gi = gi + 1) begin : g_idx_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id_vpl (.I0(st_idx[gi]), .O(st_idx_vp_lo[gi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id_vph (.I0(st_idx[gi]), .O(st_idx_vp_hi[gi]));
		end
	endgenerate

	wire we_vp = st_we && (st_idx >= GHCI_S_VIEWPORT && st_idx <= GHCI_S_VIEWPORT + 9'd5);
	wire we_vp_lo, we_vp_hi;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_vplo (.I0(we_vp), .O(we_vp_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_vphi (.I0(we_vp), .O(we_vp_hi));

	wire [5:0] we_vp_w_lo, we_vp_w_hi;
	genvar gvw;
	generate
		for (gvw = 0; gvw < 6; gvw = gvw + 1) begin : g_vp_dec
			assign we_vp_w_lo[gvw] = we_vp_lo && (st_idx_vp_lo == gvw[2:0]);
			assign we_vp_w_hi[gvw] = we_vp_hi && (st_idx_vp_hi == gvw[2:0]);
		end
	endgenerate

	wire we_smin = st_we && (st_idx == GHCI_S_SCISSOR_MIN);
	wire we_smin_lo, we_smin_hi;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_sminlo (.I0(we_smin), .O(we_smin_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_sminhi (.I0(we_smin), .O(we_smin_hi));

	wire we_smax = st_we && (st_idx == GHCI_S_SCISSOR_MAX);
	wire we_smax_lo, we_smax_hi;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_smaxlo (.I0(we_smax), .O(we_smax_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_smaxhi (.I0(we_smax), .O(we_smax_hi));

	wire we_bias = st_we && (st_idx == GHCI_S_DEPTH_BIAS_CONST || st_idx == GHCI_S_DEPTH_BIAS_SLOPE || st_idx == GHCI_S_DEPTH_BIAS_CLAMP || st_idx == GHCI_S_RT_SIZE);
	wire we_bias_lo, we_bias_hi;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_biaslo (.I0(we_bias), .O(we_bias_lo));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_we_biashi (.I0(we_bias), .O(we_bias_hi));

	wire [31:0] st_wdata_vp_b, st_wdata_sc_b, st_wdata_fpu_lw, st_wdata_fpu_ps, st_wdata_cfg_reg;
	genvar gwb;
	generate
		for (gwb = 0; gwb < 32; gwb = gwb + 1) begin : g_st_wdata_split
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wdata_vp  (.I0(st_wdata[gwb]), .O(st_wdata_vp_b[gwb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wdata_sc  (.I0(st_wdata[gwb]), .O(st_wdata_sc_b[gwb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wdata_lw  (.I0(st_wdata[gwb]), .O(st_wdata_fpu_lw[gwb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wdata_ps  (.I0(st_wdata[gwb]), .O(st_wdata_fpu_ps[gwb]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wdata_reg (.I0(st_wdata[gwb]), .O(st_wdata_cfg_reg[gwb]));
		end
	endgenerate

	genvar gwd;
	generate
		for (gwd = 0; gwd < 16; gwd = gwd + 1) begin : g_wd_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_smn_l (.I0(st_wdata_sc_b[gwd]),      .O(smin_lo_buf[gwd]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_smn_h (.I0(st_wdata_sc_b[16 + gwd]), .O(smin_hi_buf[gwd]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_smx_l (.I0(st_wdata_sc_b[gwd]),      .O(smax_lo_buf[gwd]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_smx_h (.I0(st_wdata_sc_b[16 + gwd]), .O(smax_hi_buf[gwd]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_msc_l (.I0(st_wdata_sc_b[gwd]),      .O(misc_lo_buf[gwd]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_msc_h (.I0(st_wdata_sc_b[16 + gwd]), .O(misc_hi_buf[gwd]));
			for (gvw = 0; gvw < 6; gvw = gvw + 1) begin : g_vp_wd
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_vp_l (.I0(st_wdata_vp_b[gwd]),      .O(vp_w_lo[gvw][gwd]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wd_vp_h (.I0(st_wdata_vp_b[16 + gwd]), .O(vp_w_hi[gvw][gwd]));
			end
		end
	endgenerate

	wire [3:0] vp_idx_w_lo [0:5];
	wire [3:0] vp_idx_w_hi [0:5];
	wire [3:0] vp_idx_ws_smin_l, vp_idx_ws_smin_h;
	wire [3:0] vp_idx_ws_smx_l, vp_idx_ws_smx_h;
	wire [3:0] vp_idx_r_lo_b0 [0:5], vp_idx_r_lo_b1 [0:5], vp_idx_r_lo_b2 [0:5], vp_idx_r_lo_b3 [0:5];
	wire [3:0] vp_idx_r_hi_b0 [0:5], vp_idx_r_hi_b1 [0:5], vp_idx_r_hi_b2 [0:5], vp_idx_r_hi_b3 [0:5];
	wire [3:0] vp_idx_rs_smin_b0, vp_idx_rs_smin_b1, vp_idx_rs_smin_b2, vp_idx_rs_smin_b3;
	wire [3:0] vp_idx_rs_smin_b4, vp_idx_rs_smin_b5, vp_idx_rs_smin_b6, vp_idx_rs_smin_b7;
	wire [3:0] vp_idx_rs_smx_b0,  vp_idx_rs_smx_b1,  vp_idx_rs_smx_b2,  vp_idx_rs_smx_b3;
	wire [3:0] vp_idx_rs_smx_b4,  vp_idx_rs_smx_b5,  vp_idx_rs_smx_b6,  vp_idx_rs_smx_b7;

	genvar gvi;
	generate
		for (gvi = 0; gvi < 4; gvi = gvi + 1) begin : g_vpi_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_ws_smnl (.I0(vp_idx[gvi]), .O(vp_idx_ws_smin_l[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_ws_smnh (.I0(vp_idx[gvi]), .O(vp_idx_ws_smin_h[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_ws_smxl (.I0(vp_idx[gvi]), .O(vp_idx_ws_smx_l[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_ws_smxh (.I0(vp_idx[gvi]), .O(vp_idx_ws_smx_h[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn0 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b0[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn1 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b1[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn2 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b2[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn3 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b3[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn4 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b4[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn5 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b5[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn6 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b6[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smn7 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smin_b7[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx0 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b0[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx1 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b1[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx2 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b2[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx3 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b3[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx4 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b4[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx5 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b5[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx6 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b6[gvi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rs_smx7 (.I0(vp_idx[gvi]), .O(vp_idx_rs_smx_b7[gvi]));
			for (gvw = 0; gvw < 6; gvw = gvw + 1) begin : g_vpi_wr
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_wl (.I0(vp_idx[gvi]), .O(vp_idx_w_lo[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_wh (.I0(vp_idx[gvi]), .O(vp_idx_w_hi[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rl0 (.I0(vp_idx[gvi]), .O(vp_idx_r_lo_b0[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rl1 (.I0(vp_idx[gvi]), .O(vp_idx_r_lo_b1[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rl2 (.I0(vp_idx[gvi]), .O(vp_idx_r_lo_b2[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rl3 (.I0(vp_idx[gvi]), .O(vp_idx_r_lo_b3[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rh0 (.I0(vp_idx[gvi]), .O(vp_idx_r_hi_b0[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rh1 (.I0(vp_idx[gvi]), .O(vp_idx_r_hi_b1[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rh2 (.I0(vp_idx[gvi]), .O(vp_idx_r_hi_b2[gvw][gvi]));
				(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_vpi_rh3 (.I0(vp_idx[gvi]), .O(vp_idx_r_hi_b3[gvw][gvi]));
			end
		end
	endgenerate
`else
	wire rst_setup_high = !rst_n;
	wire [31:0] st_wdata_vp_b = st_wdata;
	wire [31:0] st_wdata_sc_b = st_wdata;
	wire [31:0] st_wdata_fpu_lw = st_wdata;
	wire [31:0] st_wdata_fpu_ps = st_wdata;
	wire [31:0] st_wdata_cfg_reg = st_wdata;
	wire [15:0] vp_w_lo [0:5];
	wire [15:0] vp_w_hi [0:5];
	wire [15:0] smin_lo_buf = st_wdata[15:0];
	wire [15:0] smin_hi_buf = st_wdata[31:16];
	wire [15:0] smax_lo_buf = st_wdata[15:0];
	wire [15:0] smax_hi_buf = st_wdata[31:16];
	wire [15:0] misc_lo_buf = st_wdata[15:0];
	wire [15:0] misc_hi_buf = st_wdata[31:16];
	wire [2:0] st_idx_vp_lo = st_idx[2:0];
	wire [2:0] st_idx_vp_hi = st_idx[2:0];
	wire we_vp = st_we && (st_idx >= GHCI_S_VIEWPORT && st_idx <= GHCI_S_VIEWPORT + 9'd5);
	wire we_vp_lo = we_vp;
	wire we_vp_hi = we_vp;
	wire [5:0] we_vp_w_lo, we_vp_w_hi;
	genvar gvw;
	generate
		for (gvw = 0; gvw < 6; gvw = gvw + 1) begin : g_vp_dec_sim
			assign we_vp_w_lo[gvw] = we_vp_lo && (st_idx_vp_lo == gvw[2:0]);
			assign we_vp_w_hi[gvw] = we_vp_hi && (st_idx_vp_hi == gvw[2:0]);
			assign vp_w_lo[gvw] = st_wdata[15:0];
			assign vp_w_hi[gvw] = st_wdata[31:16];
		end
	endgenerate
	wire we_smin_lo = st_we && (st_idx == GHCI_S_SCISSOR_MIN);
	wire we_smin_hi = we_smin_lo;
	wire we_smax_lo = st_we && (st_idx == GHCI_S_SCISSOR_MAX);
	wire we_smax_hi = we_smax_lo;
	wire we_bias_lo = st_we && (st_idx == GHCI_S_DEPTH_BIAS_CONST || st_idx == GHCI_S_DEPTH_BIAS_SLOPE || st_idx == GHCI_S_DEPTH_BIAS_CLAMP || st_idx == GHCI_S_RT_SIZE);
	wire we_bias_hi = we_bias_lo;
	wire [3:0] vp_idx_w_lo [0:5];
	wire [3:0] vp_idx_w_hi [0:5];
	wire [3:0] vp_idx_ws_smin_l = vp_idx;
	wire [3:0] vp_idx_ws_smin_h = vp_idx;
	wire [3:0] vp_idx_ws_smx_l  = vp_idx;
	wire [3:0] vp_idx_ws_smx_h  = vp_idx;
	wire [3:0] vp_idx_rs_smin_b0 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b1 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b2 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b3 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b4 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b5 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b6 = vp_idx;
	wire [3:0] vp_idx_rs_smin_b7 = vp_idx;
	wire [3:0] vp_idx_rs_smx_b0  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b1  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b2  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b3  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b4  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b5  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b6  = vp_idx;
	wire [3:0] vp_idx_rs_smx_b7  = vp_idx;
	wire [3:0] vp_idx_r_lo_b0 [0:5];
	wire [3:0] vp_idx_r_lo_b1 [0:5];
	wire [3:0] vp_idx_r_lo_b2 [0:5];
	wire [3:0] vp_idx_r_lo_b3 [0:5];
	wire [3:0] vp_idx_r_hi_b0 [0:5];
	wire [3:0] vp_idx_r_hi_b1 [0:5];
	wire [3:0] vp_idx_r_hi_b2 [0:5];
	wire [3:0] vp_idx_r_hi_b3 [0:5];
	generate
		for (gvw = 0; gvw < 6; gvw = gvw + 1) begin : g_vpi_sim
			assign vp_idx_w_lo[gvw] = vp_idx;
			assign vp_idx_w_hi[gvw] = vp_idx;
			assign vp_idx_r_lo_b0[gvw] = vp_idx;
			assign vp_idx_r_lo_b1[gvw] = vp_idx;
			assign vp_idx_r_lo_b2[gvw] = vp_idx;
			assign vp_idx_r_lo_b3[gvw] = vp_idx;
			assign vp_idx_r_hi_b0[gvw] = vp_idx;
			assign vp_idx_r_hi_b1[gvw] = vp_idx;
			assign vp_idx_r_hi_b2[gvw] = vp_idx;
			assign vp_idx_r_hi_b3[gvw] = vp_idx;
		end
	endgenerate
`endif

	wire [23:0] lw_fix, ps_fix;
	atg_rx_f2fix u_lw_fix (.f(st_wdata_fpu_lw), .q(lw_fix));
	atg_rx_f2fix u_ps_fix (.f(st_wdata_fpu_ps), .q(ps_fix));

	wire [31:0] ps_in_fp32;
	am_fp_fix2f #(.W(16), .F(8), .SIGNED(0)) u_ps2f (.v(st_wdata_fpu_ps[15:0]), .f(ps_in_fp32));
	wire [31:0] div_b = (st_wdata_fpu_ps[31:23] != 9'd0) ? st_wdata_fpu_ps : ps_in_fp32;
	reg [15:0] inv_ps_lo, inv_ps_hi;
	wire [31:0] inv_ps = {inv_ps_hi, inv_ps_lo};
	wire [31:0] div_inv_ps;
	wire div_inv_done, div_busy;
`ifdef SYNTH_KINTEX7
	wire div_inv_done_lo, div_inv_done_hi;
	LUT1 #(.INIT(2'b10)) u_did_l (.I0(div_inv_done), .O(div_inv_done_lo));
	LUT1 #(.INIT(2'b10)) u_did_h (.I0(div_inv_done), .O(div_inv_done_hi));
	wire is_flw = (st_wdata_fpu_lw[31:23] != 9'd0);
	wire is_fps = (st_wdata_fpu_ps[31:23] != 9'd0);
	(* keep = "true", dont_touch = "true" *) wire [1:0] is_flw_leaf, is_fps_leaf;
	LUT1 #(.INIT(2'b10)) u_flw0 (.I0(is_flw), .O(is_flw_leaf[0]));
	LUT1 #(.INIT(2'b10)) u_flw1 (.I0(is_flw), .O(is_flw_leaf[1]));
	LUT1 #(.INIT(2'b10)) u_fps0 (.I0(is_fps), .O(is_fps_leaf[0]));
	LUT1 #(.INIT(2'b10)) u_fps1 (.I0(is_fps), .O(is_fps_leaf[1]));
	wire [15:0] lw_next = {is_flw_leaf[1] ? lw_fix[15:8] : st_wdata_cfg_reg[15:8],
	                       is_flw_leaf[0] ? lw_fix[7:0]  : st_wdata_cfg_reg[7:0]};
	wire [15:0] ps_next = {is_fps_leaf[1] ? ps_fix[15:8] : st_wdata_cfg_reg[15:8],
	                       is_fps_leaf[0] ? ps_fix[7:0]  : st_wdata_cfg_reg[7:0]};
`else
	wire div_inv_done_lo = div_inv_done;
	wire div_inv_done_hi = div_inv_done;
`endif
	reg div_inv_start;
	atg_rx_fdiv u_ps_div (
		.clk(clk), .rst_n(rst_n),
		.i_start(div_inv_start),
		.i_a(32'h3F800000), .i_b(div_b),
		.busy(div_busy), .o_done(div_inv_done), .o_r(div_inv_ps)
	);

	assign prim_type = {1'b0, kind};
	assign cur_line_width = line_width;
	assign cur_point_size = point_size;
	assign cur_viewport_idx = vp_idx;

	integer e;
	always @(posedge clk)
		if (rst_setup_high) begin
			vp_idx <= 4'd0;
			line_width <= 16'h0100;
			point_size <= 16'h0100;
			inv_ps_lo <= 16'h0000;
			inv_ps_hi <= 16'h3F80;
			div_inv_start <= 1'b0;
			rts_lo <= 16'd0;
			rts_hi <= 16'd0;
			cull <= 3'd0;
			rm <= 6'd0;
			b_const_lo <= 16'd0;
			b_const_hi <= 16'd0;
			b_slope_lo <= 16'd0;
			b_slope_hi <= 16'd0;
			b_clamp_lo <= 16'd0;
			b_clamp_hi <= 16'd0;
		end else begin
			div_inv_start <= 1'b0;
			for (e = 0; e < 16; e = e + 1) begin
				if (we_vp_w_lo[0] && (vp_idx_w_lo[0] == e[3:0])) vp_array_lo[e][0] <= vp_w_lo[0];
				if (we_vp_w_hi[0] && (vp_idx_w_hi[0] == e[3:0])) vp_array_hi[e][0] <= vp_w_hi[0];
				if (we_vp_w_lo[1] && (vp_idx_w_lo[1] == e[3:0])) vp_array_lo[e][1] <= vp_w_lo[1];
				if (we_vp_w_hi[1] && (vp_idx_w_hi[1] == e[3:0])) vp_array_hi[e][1] <= vp_w_hi[1];
				if (we_vp_w_lo[2] && (vp_idx_w_lo[2] == e[3:0])) vp_array_lo[e][2] <= vp_w_lo[2];
				if (we_vp_w_hi[2] && (vp_idx_w_hi[2] == e[3:0])) vp_array_hi[e][2] <= vp_w_hi[2];
				if (we_vp_w_lo[3] && (vp_idx_w_lo[3] == e[3:0])) vp_array_lo[e][3] <= vp_w_lo[3];
				if (we_vp_w_hi[3] && (vp_idx_w_hi[3] == e[3:0])) vp_array_hi[e][3] <= vp_w_hi[3];
				if (we_vp_w_lo[4] && (vp_idx_w_lo[4] == e[3:0])) vp_array_lo[e][4] <= vp_w_lo[4];
				if (we_vp_w_hi[4] && (vp_idx_w_hi[4] == e[3:0])) vp_array_hi[e][4] <= vp_w_hi[4];
				if (we_vp_w_lo[5] && (vp_idx_w_lo[5] == e[3:0])) vp_array_lo[e][5] <= vp_w_lo[5];
				if (we_vp_w_hi[5] && (vp_idx_w_hi[5] == e[3:0])) vp_array_hi[e][5] <= vp_w_hi[5];

				if (we_smin_lo && (vp_idx_ws_smin_l == e[3:0])) smin_array_lo[e] <= smin_lo_buf;
				if (we_smin_hi && (vp_idx_ws_smin_h == e[3:0])) smin_array_hi[e] <= smin_hi_buf;
				if (we_smax_lo && (vp_idx_ws_smx_l == e[3:0])) smax_array_lo[e] <= smax_lo_buf;
				if (we_smax_hi && (vp_idx_ws_smx_h == e[3:0])) smax_array_hi[e] <= smax_hi_buf;
			end
			if (st_we) begin
				if (st_idx == GHCI_S_VIEWPORT_IDX)
					vp_idx <= st_wdata_cfg_reg[3:0];
				if (st_idx == GHCI_S_LINE_WIDTH)
`ifdef SYNTH_KINTEX7
					line_width <= lw_next;
`else
					line_width <= (st_wdata_cfg_reg[31:23] != 9'd0) ? lw_fix[15:0] : st_wdata_cfg_reg[15:0];
`endif
				if (st_idx == GHCI_S_POINT_SIZE) begin
`ifdef SYNTH_KINTEX7
					point_size <= ps_next;
`else
					point_size <= (st_wdata_cfg_reg[31:23] != 9'd0) ? ps_fix[15:0] : st_wdata_cfg_reg[15:0];
`endif
					if (st_wdata_cfg_reg == 32'h0100 || st_wdata_cfg_reg == 32'h3F800000) begin
						inv_ps_lo <= 16'h0000;
						inv_ps_hi <= 16'h3F80;
					end else
						div_inv_start <= 1'b1;
				end
				if (st_idx == GHCI_S_CULL)
					cull <= st_wdata_cfg_reg[2:0];
				if (st_idx == GHCI_S_RAST_MODE)
					rm <= st_wdata_cfg_reg[5:0];
			end
			if (we_bias_lo && (st_idx == GHCI_S_DEPTH_BIAS_CONST))
				b_const_lo <= misc_lo_buf;
			if (we_bias_hi && (st_idx == GHCI_S_DEPTH_BIAS_CONST))
				b_const_hi <= misc_hi_buf;
			if (we_bias_lo && (st_idx == GHCI_S_DEPTH_BIAS_SLOPE))
				b_slope_lo <= misc_lo_buf;
			if (we_bias_hi && (st_idx == GHCI_S_DEPTH_BIAS_SLOPE))
				b_slope_hi <= misc_hi_buf;
			if (we_bias_lo && (st_idx == GHCI_S_DEPTH_BIAS_CLAMP))
				b_clamp_lo <= misc_lo_buf;
			if (we_bias_hi && (st_idx == GHCI_S_DEPTH_BIAS_CLAMP))
				b_clamp_hi <= misc_hi_buf;
			if (we_bias_lo && (st_idx == GHCI_S_RT_SIZE))
				rts_lo <= misc_lo_buf;
			if (we_bias_hi && (st_idx == GHCI_S_RT_SIZE))
				rts_hi <= misc_hi_buf;
			if (div_inv_done_lo)
				inv_ps_lo <= div_inv_ps[15:0];
			if (div_inv_done_hi)
				inv_ps_hi <= div_inv_ps[31:16];
		end

	/*
	 * Hardware Sequencer FSM
	 */
	localparam [3:0]
		S_IDLE      = 4'd0,
		S_PERSP_W   = 4'd1,
		S_PERSP_XYZ = 4'd2,
		S_RECT      = 4'd3,
		S_EDGE      = 4'd4,
		S_PLANE_DIV = 4'd5,
		S_PLANE     = 4'd6,
		S_BIAS      = 4'd7,
		S_OUT       = 4'd8;

	(* fsm_encoding = "none" *) reg [3:0] st;
	reg [4:0] seq_step;
	reg [1:0] p_plane;	/* 0: Z, 1: RW, 2: B0, 3: B1 */
	reg [3:0] p_step;
	reg [1:0] kind;
	reg [26:0] keep;
	reg lastq;
	reg raw;
	reg sub;
	reg more;

	(* extract_reset = "no" *) reg [15:0] R_lo [0:79];
	(* extract_reset = "no" *) reg [15:0] R_hi [0:79];
	wire [31:0] R [0:79];
	genvar gr;
	generate
		for (gr = 0; gr < 80; gr = gr + 1) begin : g_R_wire
			assign R[gr] = {R_hi[gr], R_lo[gr]};
		end
	endgenerate

	(* extract_reset = "no" *) reg [15:0] pl_lo [0:11];
	(* extract_reset = "no" *) reg [15:0] pl_hi [0:11];
	wire [31:0] pl [0:11];
	genvar gpl;
	generate
		for (gpl = 0; gpl < 12; gpl = gpl + 1) begin : g_pl_wire
			assign pl[gpl] = {pl_hi[gpl], pl_lo[gpl]};
		end
	endgenerate

	(* extract_reset = "no" *) reg [15:0] T0_lo, T0_hi;
	(* extract_reset = "no" *) reg [15:0] T1_lo, T1_hi;
	(* extract_reset = "no" *) reg [15:0] T2_lo, T2_hi;
	wire [31:0] T0 = {T0_hi, T0_lo};
	wire [31:0] T1 = {T1_hi, T1_lo};
	wire [31:0] T2 = {T2_hi, T2_lo};

	(* extract_reset = "no" *) reg [15:0] b_m_lo, b_m_hi;
	(* extract_reset = "no" *) reg [15:0] b_o_lo, b_o_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg [15:0] r_bias_fa_lo, r_bias_fa_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_bcl_is_zero_lo, r_bcl_is_zero_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_bcl_sign_lo, r_bcl_sign_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_bcl_le_lo, r_bcl_le_hi;
	(* dont_touch = "true", extract_reset = "no" *) reg r_bcl_ge_lo, r_bcl_ge_hi;
	wire [31:0] b_m = {b_m_hi, b_m_lo};
	wire [31:0] b_o = {b_o_hi, b_o_lo};
	wire [31:0] bm_val = max_mag({1'b0, pl[0][30:0]}, {1'b0, pl[1][30:0]});

`ifdef SYNTH_KINTEX7
	wire fa_o_xyz_v0, fa_o_xyz_v1, fa_o_xyz_v2;
	wire fa_o_rect, fa_o_rect_lo, fa_o_rect_hi, fa_o_plane_p01, fa_o_plane_p23, fa_o_bias;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_x0 (.I0(fa_o), .O(fa_o_xyz_v0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_x1 (.I0(fa_o), .O(fa_o_xyz_v1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_x2 (.I0(fa_o), .O(fa_o_xyz_v2));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_rc (.I0(fa_o), .O(fa_o_rect));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_rcl (.I0(fa_o), .O(fa_o_rect_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_rch (.I0(fa_o), .O(fa_o_rect_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_p0 (.I0(fa_o), .O(fa_o_plane_p01));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_p1 (.I0(fa_o), .O(fa_o_plane_p23));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fao_bs (.I0(fa_o), .O(fa_o_bias));

	wire fm_o_xyz_v0, fm_o_xyz_v1, fm_o_xyz_v2;
	wire fm_o_rect, fm_o_rect_lo, fm_o_rect_hi, fm_o_plane_p01, fm_o_plane_p23, fm_o_bias;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_x0 (.I0(fm_o), .O(fm_o_xyz_v0));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_x1 (.I0(fm_o), .O(fm_o_xyz_v1));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_x2 (.I0(fm_o), .O(fm_o_xyz_v2));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_rc (.I0(fm_o), .O(fm_o_rect));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_rcl (.I0(fm_o), .O(fm_o_rect_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_rch (.I0(fm_o), .O(fm_o_rect_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_p0 (.I0(fm_o), .O(fm_o_plane_p01));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_p1 (.I0(fm_o), .O(fm_o_plane_p23));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fmo_bs (.I0(fm_o), .O(fm_o_bias));

	wire fd_o_w, fd_o_plane;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fdo_w (.I0(fd_o), .O(fd_o_w));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_fdo_p (.I0(fd_o), .O(fd_o_plane));

	wire [31:0] fa_r_R, fa_r_pl;
	wire [31:0] fm_r_R, fm_r_pl;
	wire [6:0] e_ra_lo_b0, e_ra_lo_b1, e_ra_hi_b0, e_ra_hi_b1;
	genvar gbf;
	generate
		for (gbf = 0; gbf < 32; gbf = gbf + 1) begin : g_fpu_res_buf
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_far_r (.I0(fa_r[gbf]), .O(fa_r_R[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_far_p (.I0(fa_r[gbf]), .O(fa_r_pl[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_fmr_r (.I0(fm_r[gbf]), .O(fm_r_R[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_fmr_p (.I0(fm_r[gbf]), .O(fm_r_pl[gbf]));
		end
		for (gbf = 0; gbf < 7; gbf = gbf + 1) begin : g_era_buf
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_era_l0 (.I0(e_ra[gbf]), .O(e_ra_lo_b0[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_era_l1 (.I0(e_ra[gbf]), .O(e_ra_lo_b1[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_era_h0 (.I0(e_ra[gbf]), .O(e_ra_hi_b0[gbf]));
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_era_h1 (.I0(e_ra[gbf]), .O(e_ra_hi_b1[gbf]));
		end
	endgenerate

	wire e_empty_buf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_empty (.I0(e_empty), .O(e_empty_buf));
`else
	wire fa_o_xyz_v0 = fa_o;
	wire fa_o_xyz_v1 = fa_o;
	wire fa_o_xyz_v2 = fa_o;
	wire fa_o_rect = fa_o;
	wire fa_o_rect_lo = fa_o;
	wire fa_o_rect_hi = fa_o;
	wire fa_o_plane_p01 = fa_o;
	wire fa_o_plane_p23 = fa_o;
	wire fa_o_bias = fa_o;
	wire fm_o_xyz_v0 = fm_o;
	wire fm_o_xyz_v1 = fm_o;
	wire fm_o_xyz_v2 = fm_o;
	wire fm_o_rect = fm_o;
	wire fm_o_rect_lo = fm_o;
	wire fm_o_rect_hi = fm_o;
	wire fm_o_plane_p01 = fm_o;
	wire fm_o_plane_p23 = fm_o;
	wire fm_o_bias = fm_o;
	wire fd_o_w = fd_o;
	wire fd_o_plane = fd_o;
	wire [31:0] fa_r_R = fa_r;
	wire [31:0] fa_r_pl = fa_r;
	wire [31:0] fm_r_R = fm_r;
	wire [31:0] fm_r_pl = fm_r;
	wire [6:0] e_ra_lo_b0 = e_ra;
	wire [6:0] e_ra_lo_b1 = e_ra;
	wire [6:0] e_ra_hi_b0 = e_ra;
	wire [6:0] e_ra_hi_b1 = e_ra;
	wire e_empty_buf = e_empty;
`endif

	wire fa_o_plane = p_plane[1] ? fa_o_plane_p23 : fa_o_plane_p01;
	wire fm_o_plane = p_plane[1] ? fm_o_plane_p23 : fm_o_plane_p01;

	function [4:0] inc5;
		input [4:0] v;
		case (v)
		5'd0: inc5 = 5'd1;
		5'd1: inc5 = 5'd2;
		5'd2: inc5 = 5'd3;
		5'd3: inc5 = 5'd4;
		5'd4: inc5 = 5'd5;
		5'd5: inc5 = 5'd6;
		5'd6: inc5 = 5'd7;
		5'd7: inc5 = 5'd8;
		5'd8: inc5 = 5'd9;
		5'd9: inc5 = 5'd10;
		5'd10: inc5 = 5'd11;
		5'd11: inc5 = 5'd12;
		5'd12: inc5 = 5'd13;
		5'd13: inc5 = 5'd14;
		5'd14: inc5 = 5'd15;
		5'd15: inc5 = 5'd16;
		5'd16: inc5 = 5'd17;
		5'd17: inc5 = 5'd18;
		5'd18: inc5 = 5'd19;
		5'd19: inc5 = 5'd20;
		5'd20: inc5 = 5'd21;
		5'd21: inc5 = 5'd22;
		5'd22: inc5 = 5'd23;
		5'd23: inc5 = 5'd24;
		5'd24: inc5 = 5'd25;
		5'd25: inc5 = 5'd26;
		5'd26: inc5 = 5'd27;
		5'd27: inc5 = 5'd28;
		5'd28: inc5 = 5'd29;
		5'd29: inc5 = 5'd30;
		5'd30: inc5 = 5'd31;
		default: inc5 = 5'd0;
		endcase
	endfunction

	function [3:0] inc4;
		input [3:0] v;
		case (v)
		4'd0: inc4 = 4'd1;
		4'd1: inc4 = 4'd2;
		4'd2: inc4 = 4'd3;
		4'd3: inc4 = 4'd4;
		4'd4: inc4 = 4'd5;
		4'd5: inc4 = 4'd6;
		4'd6: inc4 = 4'd7;
		4'd7: inc4 = 4'd8;
		4'd8: inc4 = 4'd9;
		4'd9: inc4 = 4'd10;
		4'd10: inc4 = 4'd11;
		4'd11: inc4 = 4'd12;
		4'd12: inc4 = 4'd13;
		4'd13: inc4 = 4'd14;
		4'd14: inc4 = 4'd15;
		default: inc4 = 4'd0;
		endcase
	endfunction

	function [1:0] inc2;
		input [1:0] v;
		case (v)
		2'd0: inc2 = 2'd1;
		2'd1: inc2 = 2'd2;
		2'd2: inc2 = 2'd3;
		default: inc2 = 2'd0;
		endcase
	endfunction

	/* the bias's r for D16 (2^-16) and D24 (2^-24) */
`ifdef MUT_BIAS_R
	localparam [31:0] R24 = 32'h34000000;
`else
	localparam [31:0] R24 = 32'h33800000;
`endif
	wire [31:0] rfmt = rm[5:4] == 2'd1 ? 32'h37800000 : rm[5:4] == 2'd2 ? R24 : 32'd0;

	/* atg_rx_edge (the integer steps), sharing the register file. */
	reg e_start;
	wire [6:0] e_ra, e_wa;
	reg [31:0] e_rd;
	wire e_we, e_done, e_front, e_empty;
	wire [31:0] e_wd;
	wire [287:0] e_edges;
	wire [63:0] e_bbox;

	atg_rx_edge edge_u (
		.clk(clk), .rst_n(rst_n), .start(e_start),
		.mode({raw, sub, kind}), .smin(cur_smin), .smax(cur_smax), .rts(rts), .cull(cull),
		.vprect(rm[3]), .line_width(line_width), .point_size(point_size),
		.r_ra(e_ra), .r_rd(e_rd), .r_we(e_we), .r_wa(e_wa), .r_wd(e_wd),
		.done(e_done), .edges(e_edges), .bbox(e_bbox), .front(e_front), .empty(e_empty)
	);

	wire [6:0] we_r40_l, we_r40_h;
`ifdef SYNTH_KINTEX7
	genvar gr40;
	generate
		for (gr40 = 0; gr40 < 7; gr40 = gr40 + 1) begin : g_we_r40
			wire we_raw = e_we && (e_wa == (7'd40 + gr40));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wer40_l (.I0(we_raw), .O(we_r40_l[gr40]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_wer40_h (.I0(we_raw), .O(we_r40_h[gr40]));
		end
	endgenerate
`else
	genvar gr40;
	generate
		for (gr40 = 0; gr40 < 7; gr40 = gr40 + 1) begin : g_we_r40
			wire we_raw = e_we && (e_wa == (7'd40 + gr40));
			assign we_r40_l[gr40] = we_raw;
			assign we_r40_h[gr40] = we_raw;
		end
	endgenerate
`endif

	always @(posedge clk) begin
		if (we_r40_l[0]) R_lo[40] <= e_wd[15:0];
		if (we_r40_h[0]) R_hi[40] <= e_wd[31:16];
		if (we_r40_l[1]) R_lo[41] <= e_wd[15:0];
		if (we_r40_h[1]) R_hi[41] <= e_wd[31:16];
		if (we_r40_l[2]) R_lo[42] <= e_wd[15:0];
		if (we_r40_h[2]) R_hi[42] <= e_wd[31:16];
		if (we_r40_l[3]) R_lo[43] <= e_wd[15:0];
		if (we_r40_h[3]) R_hi[43] <= e_wd[31:16];
		if (we_r40_l[4]) R_lo[44] <= e_wd[15:0];
		if (we_r40_h[4]) R_hi[44] <= e_wd[31:16];
		if (we_r40_l[5]) R_lo[45] <= e_wd[15:0];
		if (we_r40_h[5]) R_hi[45] <= e_wd[31:16];
		if (we_r40_l[6]) R_lo[46] <= e_wd[15:0];
		if (we_r40_h[6]) R_hi[46] <= e_wd[31:16];
	end

	/* Floating-point arithmetic units */
	reg fa_v, fm_v, fd_v;
	(* extract_reset = "no" *) reg [31:0] fa_a, fa_b;
	(* extract_reset = "no" *) reg fa_sub;
	(* extract_reset = "no" *) reg [31:0] fm_a, fm_b;
	(* extract_reset = "no" *) reg [31:0] fd_a, fd_b;
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;

	atg_rx_fadd #(.LAT(4)) fadd (
		.clk(clk), .rst_n(rst_n), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(fa_sub), .o_valid(fa_o), .o_r(fa_r)
	);
	atg_rx_fmul #(.LAT(4)) fmul (
		.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r)
	);
	atg_rx_fdiv fdiv (
		.clk(clk), .rst_n(rst_n), .i_start(fd_v), .i_a(fd_a), .i_b(fd_b),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r)
	);

	/* fp32 compare: a <= b */
	function fle;
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction

	function [31:0] bcl;
		input [31:0] a, b;
		bcl = b[30:0] == 31'd0 ? a : !b[31] ? (fle(a, b) ? a : b) : (fle(b, a) ? a : b);
	endfunction

	function [31:0] max_mag;
		input [31:0] a, b;
		max_mag = b[30:0] > a[30:0] ? b : a;
	endfunction

	wire [7:0] ea23;
	wire su_bo_unused;
	reg [7:0] ea_in;
	am_sub #(.W(8)) u_ea23 (.a(ea_in), .b(8'd23), .bi(1'b0), .d(ea23), .bo(su_bo_unused));

	wire [31:0] max_z01 = max_mag({1'b0, R[33][30:0]}, {1'b0, R[36][30:0]});
	wire [31:0] max_z   = max_mag(max_z01, {1'b0, R[39][30:0]});

	/* Stream Selection: cl_* vs mesh_* (Option 4 Static MUX with cl_* priority) */
	wire in_mesh = mesh_valid && !cl_valid;
	wire in_valid = cl_valid || mesh_valid;
	wire [701:0] in_tri;
	wire in_last = in_mesh ? mesh_last : cl_last;

	wire in_raw = cl_valid ? cl_tri[699] : mesh_tri[699];
	wire [1:0] in_kind_hdr = cl_valid ? cl_tri[701:700] : mesh_tri[701:700];
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire cl_valid_kp0, cl_valid_kp1;
	LUT1 #(.INIT(2'b10)) u_clv_kp0 (.I0(cl_valid), .O(cl_valid_kp0));
	LUT1 #(.INIT(2'b10)) u_clv_kp1 (.I0(cl_valid), .O(cl_valid_kp1));
	wire [26:0] in_keep_hdr = {
		cl_valid_kp1 ? cl_tri[698:688] : mesh_tri[698:688],
		cl_valid_kp0 ? cl_tri[687:672] : mesh_tri[687:672]
	};
`else
	wire [26:0] in_keep_hdr = cl_valid ? cl_tri[698:672] : mesh_tri[698:672];
`endif

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [3:0] in_mesh_t1;
	(* keep = "true", dont_touch = "true" *) wire [43:0] in_mesh_leaf;
	(* keep = "true", dont_touch = "true" *) wire [19:0] in_mesh_leaf_r31;
	wire [319:0] in_tri_r31;
	genvar gmt, gml;
	generate
		for (gmt = 0; gmt < 4; gmt = gmt + 1) begin : g_im_t1
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_imt (.I0(in_mesh), .O(in_mesh_t1[gmt]));
			for (gml = 0; gml < 11; gml = gml + 1) begin : g_im_leaf
				(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_iml (.I0(in_mesh_t1[gmt]), .O(in_mesh_leaf[gmt * 11 + gml]));
			end
		end
		for (gml = 0; gml < 44; gml = gml + 1) begin : g_im_mux
			localparam integer HI = (gml == 43) ? 701 : (gml * 16 + 15);
			localparam integer LO = gml * 16;
			assign in_tri[HI:LO] = in_mesh_leaf[gml] ? mesh_tri[HI:LO] : cl_tri[HI:LO];
		end
		for (gml = 0; gml < 20; gml = gml + 1) begin : g_im_r31
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_im_r31 (.I0(in_mesh_t1[gml / 5]), .O(in_mesh_leaf_r31[gml]));
			assign in_tri_r31[gml * 16 +: 16] = in_mesh_leaf_r31[gml] ? mesh_tri[gml * 16 +: 16] : cl_tri[gml * 16 +: 16];
		end
	endgenerate

	wire in_valid_ctrl, in_valid_pl, in_valid_fd, in_valid_raw_r;
	wire [3:0] iv_branch;
	(* keep = "true", dont_touch = "true" *) wire [20:0] we_in_lo, we_in_hi;
	(* keep = "true", dont_touch = "true" *) wire [6:0] we_vpr_lo, we_vpr_hi;

	LUT1 #(.INIT(2'b10)) u_iv_ctrl (.I0(in_valid), .O(in_valid_ctrl));
	LUT1 #(.INIT(2'b10)) u_iv_pl   (.I0(in_valid), .O(in_valid_pl));
	LUT1 #(.INIT(2'b10)) u_iv_fd   (.I0(in_valid), .O(in_valid_fd));
	LUT1 #(.INIT(2'b10)) u_iv_raw  (.I0(in_valid), .O(in_valid_raw_r));

	LUT1 #(.INIT(2'b10)) u_iv_b0 (.I0(in_valid), .O(iv_branch[0]));
	LUT1 #(.INIT(2'b10)) u_iv_b1 (.I0(in_valid), .O(iv_branch[1]));
	LUT1 #(.INIT(2'b10)) u_iv_b2 (.I0(in_valid), .O(iv_branch[2]));
	LUT1 #(.INIT(2'b10)) u_iv_b3 (.I0(in_valid), .O(iv_branch[3]));

	genvar giv;
	generate
		for (giv = 0; giv < 21; giv = giv + 1) begin : g_we_in
			localparam integer BR = (giv < 6) ? 0 : (giv < 12) ? 1 : (giv < 18) ? 2 : 3;
			LUT1 #(.INIT(2'b10)) u_wel (.I0(iv_branch[BR]), .O(we_in_lo[giv]));
			LUT1 #(.INIT(2'b10)) u_weh (.I0(iv_branch[BR]), .O(we_in_hi[giv]));
		end
		for (giv = 0; giv < 7; giv = giv + 1) begin : g_we_vp
			LUT1 #(.INIT(2'b10)) u_wvpl (.I0(iv_branch[3]), .O(we_vpr_lo[giv]));
			LUT1 #(.INIT(2'b10)) u_wvph (.I0(iv_branch[3]), .O(we_vpr_hi[giv]));
		end
	endgenerate
`else
	assign in_tri = in_mesh ? mesh_tri : cl_tri;
	wire in_valid_ctrl = in_valid;
	wire in_valid_pl = in_valid;
	wire in_valid_fd = in_valid;
	wire in_valid_raw_r = in_valid;
	wire [20:0] we_in_lo = {21{in_valid}};
	wire [20:0] we_in_hi = {21{in_valid}};
	wire [6:0] we_vpr_lo = {7{in_valid}};
	wire [6:0] we_vpr_hi = {7{in_valid}};
`endif

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire cl_ready_out, mesh_ready_out, busy_out;
	LUT1 #(.INIT(2'b10)) u_cr_out (.I0(st == S_IDLE), .O(cl_ready_out));
	LUT1 #(.INIT(2'b10)) u_mr_out (.I0(st == S_IDLE), .O(mesh_ready_out));
	LUT1 #(.INIT(2'b10)) u_bs_out (.I0(st != S_IDLE), .O(busy_out));
	assign cl_ready = cl_ready_out;
	assign mesh_ready = mesh_ready_out;
	assign busy = busy_out;
`else
	assign cl_ready = (st == S_IDLE);
	assign mesh_ready = (st == S_IDLE);
	assign busy = (st != S_IDLE);
`endif
	assign sp_last = lastq && !more;

	/* Plane source registers */
	reg [6:0] pf0, pf1, pf2;
	always @(*)
		case (p_plane)
		2'd0: begin pf0 = 7'd33; pf1 = 7'd36; pf2 = 7'd39; end	/* Z */
		2'd1: begin pf0 = 7'd28; pf1 = 7'd29; pf2 = 7'd30; end	/* RW */
		2'd2: begin pf0 = 7'd52; pf1 = 7'd53; pf2 = 7'd54; end	/* B0W */
		default: begin pf0 = 7'd55; pf1 = 7'd56; pf2 = 7'd57; end	/* B1W */
		endcase

	wire [31:0] cur_A = (p_plane == 2'd0) ? pl[0] : (p_plane == 2'd1) ? pl[3] : (p_plane == 2'd2) ? pl[6] : pl[9];
	wire [31:0] cur_B = (p_plane == 2'd0) ? pl[1] : (p_plane == 2'd1) ? pl[4] : (p_plane == 2'd2) ? pl[7] : pl[10];

	integer i;
	always @(posedge clk) begin
		case (e_ra_lo_b0)
		7'd31: e_rd[7:0] <= R_lo[31][7:0];
		7'd32: e_rd[7:0] <= R_lo[32][7:0];
		7'd33: e_rd[7:0] <= R_lo[33][7:0];
		7'd34: e_rd[7:0] <= R_lo[34][7:0];
		7'd35: e_rd[7:0] <= R_lo[35][7:0];
		7'd36: e_rd[7:0] <= R_lo[36][7:0];
		7'd37: e_rd[7:0] <= R_lo[37][7:0];
		7'd38: e_rd[7:0] <= R_lo[38][7:0];
		7'd39: e_rd[7:0] <= R_lo[39][7:0];
		7'd76: e_rd[7:0] <= R_lo[76][7:0];
		7'd77: e_rd[7:0] <= R_lo[77][7:0];
		7'd78: e_rd[7:0] <= R_lo[78][7:0];
		7'd79: e_rd[7:0] <= R_lo[79][7:0];
		default: e_rd[7:0] <= 8'd0;
		endcase
		case (e_ra_lo_b1)
		7'd31: e_rd[15:8] <= R_lo[31][15:8];
		7'd32: e_rd[15:8] <= R_lo[32][15:8];
		7'd33: e_rd[15:8] <= R_lo[33][15:8];
		7'd34: e_rd[15:8] <= R_lo[34][15:8];
		7'd35: e_rd[15:8] <= R_lo[35][15:8];
		7'd36: e_rd[15:8] <= R_lo[36][15:8];
		7'd37: e_rd[15:8] <= R_lo[37][15:8];
		7'd38: e_rd[15:8] <= R_lo[38][15:8];
		7'd39: e_rd[15:8] <= R_lo[39][15:8];
		7'd76: e_rd[15:8] <= R_lo[76][15:8];
		7'd77: e_rd[15:8] <= R_lo[77][15:8];
		7'd78: e_rd[15:8] <= R_lo[78][15:8];
		7'd79: e_rd[15:8] <= R_lo[79][15:8];
		default: e_rd[15:8] <= 8'd0;
		endcase
		case (e_ra_hi_b0)
		7'd31: e_rd[23:16] <= R_hi[31][7:0];
		7'd32: e_rd[23:16] <= R_hi[32][7:0];
		7'd33: e_rd[23:16] <= R_hi[33][7:0];
		7'd34: e_rd[23:16] <= R_hi[34][7:0];
		7'd35: e_rd[23:16] <= R_hi[35][7:0];
		7'd36: e_rd[23:16] <= R_hi[36][7:0];
		7'd37: e_rd[23:16] <= R_hi[37][7:0];
		7'd38: e_rd[23:16] <= R_hi[38][7:0];
		7'd39: e_rd[23:16] <= R_hi[39][7:0];
		7'd76: e_rd[23:16] <= R_hi[76][7:0];
		7'd77: e_rd[23:16] <= R_hi[77][7:0];
		7'd78: e_rd[23:16] <= R_hi[78][7:0];
		7'd79: e_rd[23:16] <= R_hi[79][7:0];
		default: e_rd[23:16] <= 8'd0;
		endcase
		case (e_ra_hi_b1)
		7'd31: e_rd[31:24] <= R_hi[31][15:8];
		7'd32: e_rd[31:24] <= R_hi[32][15:8];
		7'd33: e_rd[31:24] <= R_hi[33][15:8];
		7'd34: e_rd[31:24] <= R_hi[34][15:8];
		7'd35: e_rd[31:24] <= R_hi[35][15:8];
		7'd36: e_rd[31:24] <= R_hi[36][15:8];
		7'd37: e_rd[31:24] <= R_hi[37][15:8];
		7'd38: e_rd[31:24] <= R_hi[38][15:8];
		7'd39: e_rd[31:24] <= R_hi[39][15:8];
		7'd76: e_rd[31:24] <= R_hi[76][15:8];
		7'd77: e_rd[31:24] <= R_hi[77][15:8];
		7'd78: e_rd[31:24] <= R_hi[78][15:8];
		7'd79: e_rd[31:24] <= R_hi[79][15:8];
		default: e_rd[31:24] <= 8'd0;
		endcase
		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		e_start <= 1'b0;

		if (rst_setup_high) begin
			st <= S_IDLE;
			sp_valid <= 1'b0;
			more <= 1'b0;
			sub <= 1'b0;
			seq_step <= 5'd0;
			p_plane <= 2'd0;
			p_step <= 4'd0;
			ea_in <= 8'd0;
			for (i = 0; i < 12; i = i + 1) begin
				pl_lo[i] <= 16'd0;
				pl_hi[i] <= 16'd0;
			end
		end else case (st)
		S_IDLE:
			if (in_valid_ctrl) begin
				raw <= in_raw;
				kind <= in_raw || in_kind_hdr == 2'd3 ? 2'd2 : in_kind_hdr;
				keep <= in_keep_hdr;
				lastq <= in_last;
				sub <= 1'b0;
				more <= 1'b0;
				if (in_valid_pl) begin
					for (i = 0; i < 12; i = i + 1) begin
						pl_lo[i] <= 16'd0;
						pl_hi[i] <= 16'd0;
					end
				end

				/* 1-cycle parallel load */
				for (i = 0; i < 21; i = i + 1) begin
					if (we_in_lo[i]) R_lo[i] <= in_tri[i * 32 +: 16];
					if (we_in_hi[i]) R_hi[i] <= in_tri[i * 32 + 16 +: 16];
				end
				if (we_vpr_lo[0]) R_lo[21] <= {vp_array_lo[vp_idx_r_lo_b3[0]][0][15:12], vp_array_lo[vp_idx_r_lo_b2[0]][0][11:8], vp_array_lo[vp_idx_r_lo_b1[0]][0][7:4], vp_array_lo[vp_idx_r_lo_b0[0]][0][3:0]};
				if (we_vpr_hi[0]) R_hi[21] <= {vp_array_hi[vp_idx_r_hi_b3[0]][0][15:12], vp_array_hi[vp_idx_r_hi_b2[0]][0][11:8], vp_array_hi[vp_idx_r_hi_b1[0]][0][7:4], vp_array_hi[vp_idx_r_hi_b0[0]][0][3:0]};
				if (we_vpr_lo[1]) R_lo[22] <= {vp_array_lo[vp_idx_r_lo_b3[1]][1][15:12], vp_array_lo[vp_idx_r_lo_b2[1]][1][11:8], vp_array_lo[vp_idx_r_lo_b1[1]][1][7:4], vp_array_lo[vp_idx_r_lo_b0[1]][1][3:0]};
				if (we_vpr_hi[1]) R_hi[22] <= {vp_array_hi[vp_idx_r_hi_b3[1]][1][15:12], vp_array_hi[vp_idx_r_hi_b2[1]][1][11:8], vp_array_hi[vp_idx_r_hi_b1[1]][1][7:4], vp_array_hi[vp_idx_r_hi_b0[1]][1][3:0]};
				if (we_vpr_lo[2]) R_lo[23] <= {vp_array_lo[vp_idx_r_lo_b3[2]][2][15:12], vp_array_lo[vp_idx_r_lo_b2[2]][2][11:8], vp_array_lo[vp_idx_r_lo_b1[2]][2][7:4], vp_array_lo[vp_idx_r_lo_b0[2]][2][3:0]};
				if (we_vpr_hi[2]) R_hi[23] <= {vp_array_hi[vp_idx_r_hi_b3[2]][2][15:12], vp_array_hi[vp_idx_r_hi_b2[2]][2][11:8], vp_array_hi[vp_idx_r_hi_b1[2]][2][7:4], vp_array_hi[vp_idx_r_hi_b0[2]][2][3:0]};
				if (we_vpr_lo[3]) R_lo[24] <= {vp_array_lo[vp_idx_r_lo_b3[3]][3][15:12], vp_array_lo[vp_idx_r_lo_b2[3]][3][11:8], vp_array_lo[vp_idx_r_lo_b1[3]][3][7:4], vp_array_lo[vp_idx_r_lo_b0[3]][3][3:0]};
				if (we_vpr_hi[3]) R_hi[24] <= {vp_array_hi[vp_idx_r_hi_b3[3]][3][15:12], vp_array_hi[vp_idx_r_hi_b2[3]][3][11:8], vp_array_hi[vp_idx_r_hi_b1[3]][3][7:4], vp_array_hi[vp_idx_r_hi_b0[3]][3][3:0]};
				if (we_vpr_lo[4]) R_lo[25] <= {vp_array_lo[vp_idx_r_lo_b3[4]][4][15:12], vp_array_lo[vp_idx_r_lo_b2[4]][4][11:8], vp_array_lo[vp_idx_r_lo_b1[4]][4][7:4], vp_array_lo[vp_idx_r_lo_b0[4]][4][3:0]};
				if (we_vpr_hi[4]) R_hi[25] <= {vp_array_hi[vp_idx_r_hi_b3[4]][4][15:12], vp_array_hi[vp_idx_r_hi_b2[4]][4][11:8], vp_array_hi[vp_idx_r_hi_b1[4]][4][7:4], vp_array_hi[vp_idx_r_hi_b0[4]][4][3:0]};
				if (we_vpr_lo[5]) R_lo[26] <= {vp_array_lo[vp_idx_r_lo_b3[5]][5][15:12], vp_array_lo[vp_idx_r_lo_b2[5]][5][11:8], vp_array_lo[vp_idx_r_lo_b1[5]][5][7:4], vp_array_lo[vp_idx_r_lo_b0[5]][5][3:0]};
				if (we_vpr_hi[5]) R_hi[26] <= {vp_array_hi[vp_idx_r_hi_b3[5]][5][15:12], vp_array_hi[vp_idx_r_hi_b2[5]][5][11:8], vp_array_hi[vp_idx_r_hi_b1[5]][5][7:4], vp_array_hi[vp_idx_r_hi_b0[5]][5][3:0]};
				if (we_vpr_lo[6]) R_lo[27] <= ONE[15:0];
				if (we_vpr_hi[6]) R_hi[27] <= ONE[31:16];

				if (in_raw) begin
					/* RAW screen space: load X, Y, Z directly */
					if (in_valid_raw_r) begin
`ifdef SYNTH_KINTEX7
						R_lo[31] <= in_tri_r31[15:0];   R_hi[31] <= in_tri_r31[31:16];
						R_lo[32] <= in_tri_r31[47:32];  R_hi[32] <= in_tri_r31[63:48];
						R_lo[33] <= in_tri_r31[79:64];  R_hi[33] <= in_tri_r31[95:80];
						R_lo[34] <= in_tri_r31[143:128]; R_hi[34] <= in_tri_r31[159:144];
						R_lo[35] <= in_tri_r31[175:160]; R_hi[35] <= in_tri_r31[191:176];
						R_lo[36] <= in_tri_r31[207:192]; R_hi[36] <= in_tri_r31[223:208];
						R_lo[37] <= in_tri_r31[271:256]; R_hi[37] <= in_tri_r31[287:272];
						R_lo[38] <= in_tri_r31[303:288]; R_hi[38] <= in_tri_r31[319:304];
						R_lo[39] <= in_tri[335:320];     R_hi[39] <= in_tri[351:336];
`else
						R_lo[31] <= in_tri[15:0];   R_hi[31] <= in_tri[31:16];
						R_lo[32] <= in_tri[47:32];  R_hi[32] <= in_tri[63:48];
						R_lo[33] <= in_tri[79:64];  R_hi[33] <= in_tri[95:80];
						R_lo[34] <= in_tri[143:128]; R_hi[34] <= in_tri[159:144];
						R_lo[35] <= in_tri[175:160]; R_hi[35] <= in_tri[191:176];
						R_lo[36] <= in_tri[207:192]; R_hi[36] <= in_tri[223:208];
						R_lo[37] <= in_tri[271:256]; R_hi[37] <= in_tri[287:272];
						R_lo[38] <= in_tri[303:288]; R_hi[38] <= in_tri[319:304];
						R_lo[39] <= in_tri[335:320]; R_hi[39] <= in_tri[351:336];
`endif
					end
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					/* Clip space: start 1/w0 divide */
					if (in_valid_fd) begin
						fd_v <= 1'b1;
						fd_a <= ONE;
						fd_b <= in_tri[127:96];
						seq_step <= 5'd0;
						st <= S_PERSP_W;
					end
				end
			end

		S_PERSP_W:
			if (fd_o_w) begin
				case (seq_step)
				5'd0: begin
					R_lo[28] <= fd_r[15:0]; R_hi[28] <= fd_r[31:16];	/* RW0 */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[7];	/* V1.w */
					seq_step <= 5'd1;
				end
				5'd1: begin
					R_lo[29] <= fd_r[15:0]; R_hi[29] <= fd_r[31:16];	/* RW1 */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[11];	/* V2.w */
					seq_step <= 5'd2;
				end
				default: begin
					R_lo[30] <= fd_r[15:0]; R_hi[30] <= fd_r[31:16];	/* RW2 */
					seq_step <= 5'd0;
					st <= S_PERSP_XYZ;
				end
				endcase
			end

		S_PERSP_XYZ:
			case (seq_step)
			/* Vertex 0: X0, Y0, Z0, B0W0, B1W0 */
			5'd0: begin
				fm_v <= 1'b1; fm_a <= R[0]; fm_b <= R[28];	/* V0.x * RW0 */
				seq_step <= inc5(seq_step);
			end
			5'd1: begin
				fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				if (fm_o_xyz_v0) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd2: if (fm_o_xyz_v0) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd3: begin
				fm_a <= R[1]; fm_b <= R[28];	/* V0.y * RW0 */
				if (fa_o_xyz_v0) begin
					R_lo[31] <= fa_r_R[15:0]; R_hi[31] <= fa_r_R[31:16];	/* X0 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd4: begin
				fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				if (fm_o_xyz_v0) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd5: if (fm_o_xyz_v0) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd6: begin
				fm_a <= R[2]; fm_b <= R[28];	/* V0.z * RW0 */
				if (fa_o_xyz_v0) begin
					R_lo[32] <= fa_r_R[15:0]; R_hi[32] <= fa_r_R[31:16];	/* Y0 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd7: begin
				fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				if (fm_o_xyz_v0) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd8: if (fm_o_xyz_v0) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			5'd9: begin
				fm_a <= R[12]; fm_b <= R[28];	/* W0.0 * RW0 */
				if (fa_o_xyz_v0) begin
					R_lo[33] <= fa_r_R[15:0]; R_hi[33] <= fa_r_R[31:16];	/* Z0 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd10: begin
				fm_a <= R[13]; fm_b <= R[28];	/* W0.1 * RW0 */
				if (fm_o_xyz_v0) begin
					R_lo[52] <= fm_r_R[15:0]; R_hi[52] <= fm_r_R[31:16];	/* B0W0 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd11: begin
				fm_a <= R[4]; fm_b <= R[29];	/* V1.x * RW1 */
				if (fm_o_xyz_v1) begin
					R_lo[55] <= fm_r_R[15:0]; R_hi[55] <= fm_r_R[31:16];	/* B1W0 */
					/* Vertex 1: X1, Y1, Z1, B0W1, B1W1 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd12: begin
				fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				if (fm_o_xyz_v1) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd13: if (fm_o_xyz_v1) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd14: begin
				fm_a <= R[5]; fm_b <= R[29];	/* V1.y * RW1 */
				if (fa_o_xyz_v1) begin
					R_lo[34] <= fa_r_R[15:0]; R_hi[34] <= fa_r_R[31:16];	/* X1 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd15: begin
				fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				if (fm_o_xyz_v1) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd16: if (fm_o_xyz_v1) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd17: begin
				fm_a <= R[6]; fm_b <= R[29];	/* V1.z * RW1 */
				if (fa_o_xyz_v1) begin
					R_lo[35] <= fa_r_R[15:0]; R_hi[35] <= fa_r_R[31:16];	/* Y1 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd18: begin
				fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				if (fm_o_xyz_v1) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd19: if (fm_o_xyz_v1) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			5'd20: begin
				fm_a <= R[15]; fm_b <= R[29];	/* W1.0 * RW1 */
				if (fa_o_xyz_v1) begin
					R_lo[36] <= fa_r_R[15:0]; R_hi[36] <= fa_r_R[31:16];	/* Z1 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd21: begin
				fm_a <= R[16]; fm_b <= R[29];	/* W1.1 * RW1 */
				if (fm_o_xyz_v2) begin
					R_lo[53] <= fm_r_R[15:0]; R_hi[53] <= fm_r_R[31:16];	/* B0W1 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd22: begin
				fm_a <= R[8]; fm_b <= R[30];	/* V2.x * RW2 */
				if (fm_o_xyz_v2) begin
					R_lo[56] <= fm_r_R[15:0]; R_hi[56] <= fm_r_R[31:16];	/* B1W1 */
					/* Vertex 2: X2, Y2, Z2, B0W2, B1W2 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd23: begin
				fm_a <= fm_r; fm_b <= R[21];	/* * XS */
				if (fm_o_xyz_v2) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd24: if (fm_o_xyz_v2) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[23]; fa_sub <= 1'b0;	/* + XO */
				seq_step <= inc5(seq_step);
			end
			5'd25: begin
				fm_a <= R[9]; fm_b <= R[30];	/* V2.y * RW2 */
				if (fa_o_xyz_v2) begin
					R_lo[37] <= fa_r_R[15:0]; R_hi[37] <= fa_r_R[31:16];	/* X2 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd26: begin
				fm_a <= fm_r; fm_b <= R[22];	/* * YS */
				if (fm_o_xyz_v2) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd27: if (fm_o_xyz_v2) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[24]; fa_sub <= 1'b0;	/* + YO */
				seq_step <= inc5(seq_step);
			end
			5'd28: begin
				fm_a <= R[10]; fm_b <= R[30];	/* V2.z * RW2 */
				if (fa_o_xyz_v2) begin
					R_lo[38] <= fa_r_R[15:0]; R_hi[38] <= fa_r_R[31:16];	/* Y2 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd29: begin
				fm_a <= fm_r; fm_b <= R[25];	/* * ZS */
				if (fm_o_xyz_v2) begin
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd30: if (fm_o_xyz_v2) begin
				fa_v <= 1'b1; fa_a <= fm_r; fa_b <= R[26]; fa_sub <= 1'b0;	/* + ZO */
				seq_step <= inc5(seq_step);
			end
			default: begin
				fm_a <= R[18]; fm_b <= R[30];	/* W2.0 * RW2 */
				if (fa_o_xyz_v2) begin
					fm_v <= 1'b1;
					R_lo[39] <= fa_r_R[15:0]; R_hi[39] <= fa_r_R[31:16];	/* Z2 */
					st <= S_RECT;
					seq_step <= 5'd0;
				end
			end
			endcase

		S_RECT:
			case (seq_step)
			5'd0: begin
				fm_a <= R[19]; fm_b <= R[30];	/* W2.1 * RW2 */
				if (fm_o_rect) begin
					if (fm_o_rect_lo) R_lo[54] <= fm_r_R[15:0];
					if (fm_o_rect_hi) R_hi[54] <= fm_r_R[31:16];	/* B0W2 */
					fm_v <= 1'b1;
					seq_step <= inc5(seq_step);
				end
			end
			5'd1: if (fm_o_rect) begin
				if (fm_o_rect_lo) R_lo[57] <= fm_r_R[15:0];
				if (fm_o_rect_hi) R_hi[57] <= fm_r_R[31:16];	/* B1W2 */
				if (!rm[3]) begin
					/* No viewport rectangle: dispatch edge directly */
					if (kind == 2'd1) begin
						if (fm_o_rect_lo) begin
							R_lo[30] <= R_lo[28];
							R_lo[39] <= R_lo[33];
							R_lo[54] <= R_lo[52];
							R_lo[57] <= R_lo[55];
						end
						if (fm_o_rect_hi) begin
							R_hi[30] <= R_hi[28];
							R_hi[39] <= R_hi[33];
							R_hi[54] <= R_hi[52];
							R_hi[57] <= R_hi[55];
						end
					end
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					/* Viewport rectangle: RX0, RX1, RY0, RY1 */
					fa_v <= 1'b1; fa_a <= R[23]; fa_b <= {1'b0, R[21][30:0]}; fa_sub <= 1'b1;	/* XO - |XS| */
					seq_step <= inc5(seq_step);
			end
			end
			5'd2: if (fa_o_rect) begin
				if (fa_o_rect_lo) R_lo[76] <= fa_r_R[15:0];
				if (fa_o_rect_hi) R_hi[76] <= fa_r_R[31:16];	/* RX0 */
				fa_v <= 1'b1; fa_a <= R[23]; fa_b <= {1'b0, R[21][30:0]}; fa_sub <= 1'b0;	/* XO + |XS| */
				seq_step <= inc5(seq_step);
			end
			5'd3: if (fa_o_rect) begin
				if (fa_o_rect_lo) R_lo[77] <= fa_r_R[15:0];
				if (fa_o_rect_hi) R_hi[77] <= fa_r_R[31:16];	/* RX1 */
				fa_v <= 1'b1; fa_a <= R[24]; fa_b <= {1'b0, R[22][30:0]}; fa_sub <= 1'b1;	/* YO - |YS| */
				seq_step <= inc5(seq_step);
			end
			5'd4: if (fa_o_rect) begin
				if (fa_o_rect_lo) R_lo[78] <= fa_r_R[15:0];
				if (fa_o_rect_hi) R_hi[78] <= fa_r_R[31:16];	/* RY0 */
				fa_v <= 1'b1; fa_a <= R[24]; fa_b <= {1'b0, R[22][30:0]}; fa_sub <= 1'b0;	/* YO + |YS| */
				seq_step <= inc5(seq_step);
			end
			default: if (fa_o_rect) begin
				if (fa_o_rect_lo) R_lo[79] <= fa_r_R[15:0];
				if (fa_o_rect_hi) R_hi[79] <= fa_r_R[31:16];	/* RY1 */
				if (kind == 2'd1) begin
					if (fa_o_rect_lo) begin
						R_lo[30] <= R_lo[28];
						R_lo[39] <= R_lo[33];
						R_lo[54] <= R_lo[52];
						R_lo[57] <= R_lo[55];
					end
					if (fa_o_rect_hi) begin
						R_hi[30] <= R_hi[28];
						R_hi[39] <= R_hi[33];
						R_hi[54] <= R_hi[52];
						R_hi[57] <= R_hi[55];
					end
				end
				st <= S_EDGE;
				e_start <= 1'b1;
			end
			endcase

		S_EDGE:
			if (e_done) begin
				if (e_empty_buf) begin
					/* Early culling / zero-area / out-of-screen: zero-latency drop! */
					st <= S_OUT;
				end else if (kind == 2'd0) begin
					/* Point: direct plane assignment */
					pl_lo[0] <= 16'd0; pl_hi[0] <= 16'd0;
					pl_lo[1] <= 16'd0; pl_hi[1] <= 16'd0;
					pl_lo[2] <= R_lo[33]; pl_hi[2] <= R_hi[33];
					pl_lo[3] <= 16'd0; pl_hi[3] <= 16'd0;
					pl_lo[4] <= 16'd0; pl_hi[4] <= 16'd0;
					pl_lo[5] <= ONE[15:0]; pl_hi[5] <= ONE[31:16];
					pl_lo[6] <= inv_ps[15:0]; pl_hi[6] <= inv_ps[31:16];
					pl_lo[7] <= 16'd0; pl_hi[7] <= 16'd0;
					pl_lo[9] <= 16'd0; pl_hi[9] <= 16'd0;
					pl_lo[10] <= inv_ps[15:0]; pl_hi[10] <= inv_ps[31:16];
					if (point_size != 16'h0100) begin
						fm_v <= 1'b1; fm_a <= R[45]; fm_b <= inv_ps;
						seq_step <= 5'd0;
						st <= S_PLANE_DIV;
					end else begin
						fa_v <= 1'b1; fa_a <= HALF; fa_b <= R[45]; fa_sub <= 1'b0;	/* 0.5 + OX */
						seq_step <= 5'd2;
						st <= S_PLANE_DIV;
					end
				end else begin
					/* Triangle or line: start 1/DF */
					fd_v <= 1'b1;
					fd_a <= ONE;
					fd_b <= R[44];	/* DF */
					st <= S_PLANE_DIV;
					seq_step <= 5'd0;
				end
			end

		S_PLANE_DIV:
			if (kind == 2'd0) begin
				/* Point path: cleanly serialized arithmetic (no missed pulse races) */
				case (seq_step)
				5'd0: if (fm_o_plane) begin
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= fm_r; fa_sub <= 1'b0;	/* 0.5 + OX_scaled */
					seq_step <= 5'd1;
				end
				5'd1: begin
					fm_a <= R[46]; fm_b <= inv_ps;	/* launch OY * inv_ps */
					if (fa_o_plane) begin
						pl_lo[8] <= fa_r_pl[15:0]; pl_hi[8] <= fa_r_pl[31:16];	/* b0/w C */
						fm_v <= 1'b1;
						seq_step <= 5'd3;
					end
				end
				5'd3: if (fm_o_plane) begin
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= fm_r; fa_sub <= 1'b0;	/* 0.5 + OY_scaled */
					seq_step <= 5'd4;
				end
				5'd2: if (fa_o_plane) begin
					pl_lo[8] <= fa_r_pl[15:0]; pl_hi[8] <= fa_r_pl[31:16];	/* b0/w C */
					fa_v <= 1'b1; fa_a <= HALF; fa_b <= R[46]; fa_sub <= 1'b0;	/* 0.5 + OY */
					seq_step <= 5'd4;
				end
				5'd4: if (fa_o_plane) begin
					pl_lo[11] <= fa_r_pl[15:0]; pl_hi[11] <= fa_r_pl[31:16];	/* b1/w C */
					more <= !sub;	/* 1st sub-triangle: more=1; 2nd: more=0 */
					st <= S_OUT;
				end
				default: ;
				endcase
			end else if (fd_o_plane) begin
				R_lo[47] <= fd_r[15:0]; R_hi[47] <= fd_r[31:16];	/* RD = 1/DF */
				p_plane <= 2'd0;
				p_step <= 4'd0;
				st <= S_PLANE;
			end

		S_PLANE:
			case (p_step)
			4'd0: begin
				fa_v <= 1'b1; fa_a <= R[pf1]; fa_b <= R[pf0]; fa_sub <= 1'b1;	/* T0 = f1 - f0 */
				p_step <= inc4(p_step);
			end
			4'd1: if (fa_o_plane) begin
				T0_lo <= fa_r[15:0]; T0_hi <= fa_r[31:16];
				fa_v <= 1'b1; fa_a <= R[pf2]; fa_b <= R[pf0]; fa_sub <= 1'b1;	/* T1 = f2 - f0 */
				p_step <= inc4(p_step);
			end
			4'd2: begin
				fm_a <= T0; fm_b <= R[43];	/* T2 = T0 * DY2 */
				if (fa_o_plane) begin
					T1_lo <= fa_r[15:0]; T1_hi <= fa_r[31:16];
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd3: begin
				fm_a <= T1; fm_b <= R[41];	/* T3 = T1 * DY1 */
				if (fm_o_plane) begin
					T2_lo <= fm_r[15:0]; T2_hi <= fm_r[31:16];
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd4: if (fm_o_plane) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b1;	/* T2 = T2 - T3 */
				p_step <= inc4(p_step);
			end
			4'd5: begin
				fm_a <= fa_r; fm_b <= R[47];	/* a[0] = T2 * RD (A) */
				if (fa_o_plane) begin
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd6: begin
				fm_a <= T1; fm_b <= R[40];	/* T2 = T1 * DX1 */
				if (fm_o_plane) begin
					case (p_plane)
					2'd0: begin pl_lo[0] <= fm_r_pl[15:0]; pl_hi[0] <= fm_r_pl[31:16]; end
					2'd1: begin pl_lo[3] <= fm_r_pl[15:0]; pl_hi[3] <= fm_r_pl[31:16]; end
					2'd2: begin pl_lo[6] <= fm_r_pl[15:0]; pl_hi[6] <= fm_r_pl[31:16]; end
					default: begin pl_lo[9] <= fm_r_pl[15:0]; pl_hi[9] <= fm_r_pl[31:16]; end
					endcase
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd7: begin
				fm_a <= T0; fm_b <= R[42];	/* T3 = T0 * DX2 */
				if (fm_o_plane) begin
					T2_lo <= fm_r[15:0]; T2_hi <= fm_r[31:16];
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd8: if (fm_o_plane) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b1;	/* T2 = T2 - T3 */
				p_step <= inc4(p_step);
			end
			4'd9: begin
				fm_a <= fa_r; fm_b <= R[47];	/* a[1] = T2 * RD (B) */
				if (fa_o_plane) begin
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd10: begin
				fm_a <= cur_A; fm_b <= R[45];	/* T2 = A * OX */
				if (fm_o_plane) begin
					case (p_plane)
					2'd0: begin pl_lo[1] <= fm_r_pl[15:0]; pl_hi[1] <= fm_r_pl[31:16]; end
					2'd1: begin pl_lo[4] <= fm_r_pl[15:0]; pl_hi[4] <= fm_r_pl[31:16]; end
					2'd2: begin pl_lo[7] <= fm_r_pl[15:0]; pl_hi[7] <= fm_r_pl[31:16]; end
					default: begin pl_lo[10] <= fm_r_pl[15:0]; pl_hi[10] <= fm_r_pl[31:16]; end
					endcase
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd11: begin
				fm_a <= cur_B; fm_b <= R[46];	/* T3 = B * OY */
				if (fm_o_plane) begin
					T2_lo <= fm_r[15:0]; T2_hi <= fm_r[31:16];
					fm_v <= 1'b1;
					p_step <= inc4(p_step);
				end
			end
			4'd12: if (fm_o_plane) begin
				fa_v <= 1'b1; fa_a <= T2; fa_b <= fm_r; fa_sub <= 1'b0;	/* T2 = T2 + T3 */
				p_step <= inc4(p_step);
			end
			4'd13: if (fa_o_plane) begin
				fa_v <= 1'b1; fa_a <= R[pf0]; fa_b <= fa_r; fa_sub <= 1'b0;	/* C = f0 + T2 */
				p_step <= inc4(p_step);
			end
			default: if (fa_o_plane) begin
				case (p_plane)
				2'd0: begin pl_lo[2] <= fa_r_pl[15:0]; pl_hi[2] <= fa_r_pl[31:16]; end
				2'd1: begin pl_lo[5] <= fa_r_pl[15:0]; pl_hi[5] <= fa_r_pl[31:16]; end
				2'd2: begin pl_lo[8] <= fa_r_pl[15:0]; pl_hi[8] <= fa_r_pl[31:16]; end
				default: begin pl_lo[11] <= fa_r_pl[15:0]; pl_hi[11] <= fa_r_pl[31:16]; end
				endcase
				p_step <= 4'd0;
				if (raw) begin
					/* RAW triangle: Z plane only, done */
					st <= S_OUT;
				end else if (p_plane != 2'd3) begin
					p_plane <= inc2(p_plane);
				end else if (kind == 2'd1) begin
					/* Line: sub-triangle 0 done */
					more <= !sub;
					st <= S_OUT;
				end else if (rm[0] && rm[5:4] != 2'd0) begin
					/* Triangle with depth bias */
					seq_step <= 5'd0;
					st <= S_BIAS;
				end else begin
					st <= S_OUT;
				end
			end
			endcase

		/* S_BIAS */
		S_BIAS:
			case (seq_step)
			5'd0: begin
				b_m_lo <= bm_val[15:0];
				b_m_hi <= bm_val[31:16];
				seq_step <= inc5(seq_step);
			end
			5'd1: begin
				fm_v <= 1'b1; fm_a <= b_m; fm_b <= b_slope;	/* T0 = m * SLOPE */
				seq_step <= inc5(seq_step);
			end
			5'd2: begin
				fm_a <= rfmt; fm_b <= b_const;	/* T1 = r * CONST */
				if (fm_o_bias) begin
					T0_lo <= fm_r[15:0]; T0_hi <= fm_r[31:16];
					if (rm[5:4] == 2'd3) begin
						/* D32_SFLOAT: ULP(max(|z0|, |z1|, |z2|)) */
						ea_in <= max_z[30:23];
						seq_step <= 5'd3;
					end else begin
						/* D16 / D24 */
						fm_v <= 1'b1;
						seq_step <= 5'd4;
					end
				end
			end
			5'd3: begin
				fm_v <= 1'b1;
				fm_a <= (ea_in > 8'd23) ? {1'b0, ea23, 23'd0} : 32'd0;
				fm_b <= b_const;
				seq_step <= 5'd4;
			end
			5'd4: if (fm_o_bias) begin
				fa_v <= 1'b1; fa_a <= T0; fa_b <= fm_r; fa_sub <= 1'b0;	/* T0 = T0 + T1 */
				seq_step <= inc5(seq_step);
			end
			5'd5: if (fa_o_bias) begin
				r_bias_fa_lo <= fa_r[15:0];
				r_bias_fa_hi <= fa_r[31:16];
				r_bcl_is_zero_lo <= (b_clamp[30:0] == 31'd0);
				r_bcl_is_zero_hi <= (b_clamp[30:0] == 31'd0);
				r_bcl_sign_lo <= b_clamp[31];
				r_bcl_sign_hi <= b_clamp[31];
				r_bcl_le_lo <= fle(fa_r, b_clamp);
				r_bcl_le_hi <= fle(fa_r, b_clamp);
				r_bcl_ge_lo <= fle(b_clamp, fa_r);
				r_bcl_ge_hi <= fle(b_clamp, fa_r);
				seq_step <= inc5(seq_step);
			end
			5'd6: begin
				b_o_lo <= r_bcl_is_zero_lo ? r_bias_fa_lo :
				          (!r_bcl_sign_lo ? (r_bcl_le_lo ? r_bias_fa_lo : b_clamp_lo)
				                          : (r_bcl_ge_lo ? r_bias_fa_lo : b_clamp_lo));
				b_o_hi <= r_bcl_is_zero_hi ? r_bias_fa_hi :
				          (!r_bcl_sign_hi ? (r_bcl_le_hi ? r_bias_fa_hi : b_clamp_hi)
				                          : (r_bcl_ge_hi ? r_bias_fa_hi : b_clamp_hi));
				seq_step <= inc5(seq_step);
			end
			5'd7: begin
				fa_v <= 1'b1; fa_a <= pl[2]; fa_b <= b_o; fa_sub <= 1'b0;	/* Cz + o */
				seq_step <= inc5(seq_step);
			end
			default: if (fa_o_bias) begin
				pl_lo[2] <= fa_r_pl[15:0]; pl_hi[2] <= fa_r_pl[31:16];	/* Cz biased */
				st <= S_OUT;
			end
			endcase

		/* S_OUT */
		S_OUT: begin
			sp_valid <= 1'b1;
			if (sp_valid && sp_ready) begin
				sp_valid <= 1'b0;
				if (more) begin
					more <= 1'b0;
					sub <= 1'b1;
					st <= S_EDGE;
					e_start <= 1'b1;
				end else begin
					st <= S_IDLE;
				end
			end
		end
		default: ;
		endcase
	end


	genvar g;
	generate
	for (g = 0; g < 12; g = g + 1) begin : g_plane
		assign sp_tri[352 + 32 * g +: 32] = pl[g];
	end
	endgenerate
	assign sp_tri[351:0] = {e_bbox, e_edges};
	assign sp_tri[767:736] = {1'b0, kind, raw, e_front, more ? 3'd0 : keep[26:24], keep[23:0]};

	wire unused_ok = &{1'b0, fd_busy, rm[2:1], su_bo_unused, max_z[31], max_z[22:0],
		lw_fix[23:16], ps_fix[23:16], div_busy, mesh_id};
endmodule

`default_nettype wire
