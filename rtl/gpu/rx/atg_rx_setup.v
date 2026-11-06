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

	wire rst_setup_high = !rst_n;
	wire rst_n_setup = rst_n;
	wire rst_n_edge = rst_n;
	wire rst_n_fpu = rst_n;
	wire [31:0] st_wdata_vp_b = st_wdata;
	wire [31:0] st_wdata_sc_b = st_wdata;
	(* keep = "true" *) reg r_st_lw_we;
	(* keep = "true" *) reg [31:0] r_st_lw_data;
	(* keep = "true" *) reg r_st_ps_we;
	(* keep = "true" *) reg [31:0] r_st_ps_data;
	(* keep = "true" *) reg r_st_lw_valid;
	(* keep = "true" *) reg [15:0] r_st_lw_val;
	(* keep = "true" *) reg r_st_ps_valid;
	(* keep = "true" *) reg [15:0] r_st_ps_val;
	(* keep = "true" *) reg [31:0] r_st_ps_raw;
	wire [31:0] st_wdata_fpu_lw = r_st_lw_data;
	wire [31:0] st_wdata_fpu_ps = r_st_ps_data;
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

	wire [23:0] lw_fix, ps_fix;
	atg_rx_f2fix #(.USE_DSP(1)) u_lw_fix (.f(st_wdata_fpu_lw), .q(lw_fix));
	atg_rx_f2fix #(.USE_DSP(1)) u_ps_fix (.f(st_wdata_fpu_ps), .q(ps_fix));

	wire [31:0] ps_in_fp32;
	am_fp_fix2f #(.W(16), .F(8), .SIGNED(0)) u_ps2f (.v(st_wdata_fpu_ps[15:0]), .f(ps_in_fp32));
	reg [15:0] inv_ps_lo, inv_ps_hi;
	wire [31:0] inv_ps = {inv_ps_hi, inv_ps_lo};
	wire [31:0] div_inv_ps;
	wire div_inv_done, div_busy;
	wire is_flw = (st_wdata_fpu_lw[31:23] != 9'd0);
	wire is_fps = (st_wdata_fpu_ps[31:23] != 9'd0);
	wire [31:0] div_b = (st_wdata_fpu_ps[31:23] != 9'd0) ? st_wdata_fpu_ps : ps_in_fp32;
	wire div_inv_done_lo = div_inv_done;
	wire div_inv_done_hi = div_inv_done;
	reg div_inv_start;
	am_fp_div u_ps_div (
		.clk(clk), .rst_n(rst_n_fpu),
		.i_start(div_inv_start),
		.i_a(32'h3F800000), .i_b(div_b),
		.busy(div_busy), .o_done(div_inv_done), .o_r(div_inv_ps)
	);

`ifdef SYNTH_KINTEX7
	assign prim_type = {1'b0, kind_prim};
`else
	assign prim_type = {1'b0, kind};
`endif
	assign cur_line_width = line_width;
	assign cur_point_size = point_size;
	assign cur_viewport_idx = vp_idx;

	integer e;
	always @(posedge clk)
		if (rst_setup_high) begin
			r_st_lw_we <= 1'b0;
			r_st_lw_data <= 32'd0;
			r_st_ps_we <= 1'b0;
			r_st_ps_data <= 32'd0;
			r_st_lw_valid <= 1'b0;
			r_st_lw_val <= 16'd0;
			r_st_ps_valid <= 1'b0;
			r_st_ps_val <= 16'd0;
			r_st_ps_raw <= 32'd0;
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
			r_st_lw_we <= st_we && (st_idx == GHCI_S_LINE_WIDTH);
			if (st_we && (st_idx == GHCI_S_LINE_WIDTH))
				r_st_lw_data <= st_wdata;

			r_st_ps_we <= st_we && (st_idx == GHCI_S_POINT_SIZE);
			if (st_we && (st_idx == GHCI_S_POINT_SIZE))
				r_st_ps_data <= st_wdata;

			r_st_lw_valid <= r_st_lw_we;
			if (r_st_lw_we)
				r_st_lw_val <= (r_st_lw_data[31:23] != 9'd0) ? lw_fix[15:0] : r_st_lw_data[15:0];

			r_st_ps_valid <= r_st_ps_we;
			if (r_st_ps_we) begin
				r_st_ps_val <= (r_st_ps_data[31:23] != 9'd0) ? ps_fix[15:0] : r_st_ps_data[15:0];
				r_st_ps_raw <= r_st_ps_data;
			end

			div_inv_start <= 1'b0;
			if (r_st_lw_valid) begin
				line_width <= r_st_lw_val;
			end
			if (r_st_ps_valid) begin
				point_size <= r_st_ps_val;
				if (r_st_ps_raw == 32'h0100 || r_st_ps_raw == 32'h3F800000) begin
					inv_ps_lo <= 16'h0000;
					inv_ps_hi <= 16'h3F80;
				end else
					div_inv_start <= 1'b1;
			end
			if (st_we) begin
				if (st_idx == GHCI_S_VIEWPORT_IDX)
					vp_idx <= st_wdata_cfg_reg[3:0];
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

`define RX_BUF1(inst_name, in_sig, out_sig) \
	assign out_sig = (in_sig)

	(* fsm_encoding = "none", extract_enable = "no", extract_reset = "no" *) reg [3:0] st, st_rep_a, st_rep_b, st_rep_c, st_rep_d, st_rep_e, st_rep_f;
	(* fsm_encoding = "none", extract_enable = "no", extract_reset = "no" *) reg [4:0] seq_step, seq_step_hi, seq_step_v, seq_step_rep_a, seq_step_rep_b, seq_step_rep_c, seq_step_rep_d;
	(* fsm_encoding = "none", extract_reset = "no", max_fanout = 16 *) reg [1:0] p_plane;	/* 0: Z, 1: RW, 2: B0, 3: B1 */
	(* fsm_encoding = "none", extract_enable = "no", extract_reset = "no" *) reg [3:0] p_step, p_step_rep_a;
	(* extract_enable = "no", extract_reset = "no" *) reg [1:0] kind, kind_prim, kind_out, kind_edge, kind_fpu;
	reg [26:0] keep;
	reg lastq;
	reg raw;
	reg sub;
	reg more;

	 wire [1:0] p_plane_pf0_l, p_plane_pf0_h;
	 wire [1:0] p_plane_pf1_l, p_plane_pf1_h;
	 wire [1:0] p_plane_pf2_l, p_plane_pf2_h;
	 wire [1:0] p_plane_2_l, p_plane_2_h;
	 wire [1:0] p_plane_3_l, p_plane_3_h;
	 wire [1:0] p_plane_pl_l, p_plane_pl_h;
	`RX_BUF1(u_pp_f0l0, p_plane[0], p_plane_pf0_l[0]);
	`RX_BUF1(u_pp_f0l1, p_plane[1], p_plane_pf0_l[1]);
	`RX_BUF1(u_pp_f0h0, p_plane[0], p_plane_pf0_h[0]);
	`RX_BUF1(u_pp_f0h1, p_plane[1], p_plane_pf0_h[1]);
	`RX_BUF1(u_pp_f1l0, p_plane[0], p_plane_pf1_l[0]);
	`RX_BUF1(u_pp_f1l1, p_plane[1], p_plane_pf1_l[1]);
	`RX_BUF1(u_pp_f1h0, p_plane[0], p_plane_pf1_h[0]);
	`RX_BUF1(u_pp_f1h1, p_plane[1], p_plane_pf1_h[1]);
	`RX_BUF1(u_pp_f2l0, p_plane[0], p_plane_pf2_l[0]);
	`RX_BUF1(u_pp_f2l1, p_plane[1], p_plane_pf2_l[1]);
	`RX_BUF1(u_pp_f2h0, p_plane[0], p_plane_pf2_h[0]);
	`RX_BUF1(u_pp_f2h1, p_plane[1], p_plane_pf2_h[1]);
	`RX_BUF1(u_pp_2l0,  p_plane[0], p_plane_2_l[0]);
	`RX_BUF1(u_pp_2l1,  p_plane[1], p_plane_2_l[1]);
	`RX_BUF1(u_pp_2h0,  p_plane[0], p_plane_2_h[0]);
	`RX_BUF1(u_pp_2h1,  p_plane[1], p_plane_2_h[1]);
	`RX_BUF1(u_pp_3l0,  p_plane[0], p_plane_3_l[0]);
	`RX_BUF1(u_pp_3l1,  p_plane[1], p_plane_3_l[1]);
	`RX_BUF1(u_pp_3h0,  p_plane[0], p_plane_3_h[0]);
	`RX_BUF1(u_pp_3h1,  p_plane[1], p_plane_3_h[1]);
	`RX_BUF1(u_pp_pll0, p_plane[0], p_plane_pl_l[0]);
	`RX_BUF1(u_pp_pll1, p_plane[1], p_plane_pl_l[1]);
	`RX_BUF1(u_pp_plh0, p_plane[0], p_plane_pl_h[0]);
	`RX_BUF1(u_pp_plh1, p_plane[1], p_plane_pl_h[1]);

	 wire [3:0] st_fma_s [0:7];
	 wire [3:0] st_fmb_s [0:7];
	 wire [3:0] st_faa_s [0:7];
	 wire [3:0] st_fab_s [0:7];
	 wire [3:0] st_R_lo0, st_R_lo1, st_R_hi0, st_R_hi1;
	 wire [3:0] st_pl_lo, st_pl_hi, st_T_lo, st_T_hi;
	 wire [3:0] st_fdb_lo0, st_fdb_lo1, st_fdb_hi0, st_fdb_hi1;

	 wire [4:0] seq_fma_s [0:7];
	 wire [4:0] seq_fmb_s [0:7];
	 wire [4:0] seq_faa_s [0:7];
	 wire [4:0] seq_fab_s [0:7];
	 wire [4:0] seq_R_lo0, seq_R_lo1, seq_R_hi0, seq_R_hi1;
	 wire [4:0] seq_pl_lo, seq_pl_hi, seq_fdb_lo, seq_fdb_hi, seq_T_lo, seq_T_hi;

	 wire [3:0] p_step_a_s [0:7];
	 wire [3:0] p_step_b_s [0:7];
	 wire [3:0] p_step_ctrl, p_step_pl_lo, p_step_pl_hi, p_step_T_lo, p_step_T_hi;

	genvar gps, gsq, gsb;
	generate
		for (gsb = 0; gsb < 4; gsb = gsb + 1) begin : g_st_sl_buf
			for (gps = 0; gps < 4; gps = gps + 1) begin : g_st_b
				`RX_BUF1(u_st_fma_lo, st_rep_a[gps], st_fma_s[gsb][gps]);
				`RX_BUF1(u_st_fmb_lo, st_rep_a[gps], st_fmb_s[gsb][gps]);
				`RX_BUF1(u_st_faa_lo, st_rep_a[gps], st_faa_s[gsb][gps]);
				`RX_BUF1(u_st_fab_lo, st_rep_a[gps], st_fab_s[gsb][gps]);
				`RX_BUF1(u_st_fma_hi, st_rep_b[gps], st_fma_s[gsb + 4][gps]);
				`RX_BUF1(u_st_fmb_hi, st_rep_b[gps], st_fmb_s[gsb + 4][gps]);
				`RX_BUF1(u_st_faa_hi, st_rep_b[gps], st_faa_s[gsb + 4][gps]);
				`RX_BUF1(u_st_fab_hi, st_rep_b[gps], st_fab_s[gsb + 4][gps]);
				`RX_BUF1(u_psa_lo,    p_step[gps],       p_step_a_s[gsb][gps]);
				`RX_BUF1(u_psb_lo,    p_step[gps],       p_step_b_s[gsb][gps]);
				`RX_BUF1(u_psa_hi,    p_step_rep_a[gps], p_step_a_s[gsb + 4][gps]);
				`RX_BUF1(u_psb_hi,    p_step_rep_a[gps], p_step_b_s[gsb + 4][gps]);
			end
			for (gsq = 0; gsq < 5; gsq = gsq + 1) begin : g_sq_b
				`RX_BUF1(u_sq_fma_lo, seq_step_rep_a[gsq], seq_fma_s[gsb][gsq]);
				`RX_BUF1(u_sq_fmb_lo, seq_step_rep_a[gsq], seq_fmb_s[gsb][gsq]);
				`RX_BUF1(u_sq_faa_lo, seq_step_rep_b[gsq], seq_faa_s[gsb][gsq]);
				`RX_BUF1(u_sq_fab_lo, seq_step_rep_b[gsq], seq_fab_s[gsb][gsq]);
				`RX_BUF1(u_sq_fma_hi, seq_step_rep_c[gsq], seq_fma_s[gsb + 4][gsq]);
				`RX_BUF1(u_sq_fmb_hi, seq_step_rep_c[gsq], seq_fmb_s[gsb + 4][gsq]);
				`RX_BUF1(u_sq_faa_hi, seq_step_rep_d[gsq], seq_faa_s[gsb + 4][gsq]);
				`RX_BUF1(u_sq_fab_hi, seq_step_rep_d[gsq], seq_fab_s[gsb + 4][gsq]);
			end
		end
		for (gps = 0; gps < 4; gps = gps + 1) begin : g_st_ps_misc
			`RX_BUF1(u_st_rlo0,  st_rep_c[gps], st_R_lo0[gps]);
			`RX_BUF1(u_st_rlo1,  st_rep_c[gps], st_R_lo1[gps]);
			`RX_BUF1(u_st_rhi0,  st_rep_c[gps], st_R_hi0[gps]);
			`RX_BUF1(u_st_rhi1,  st_rep_c[gps], st_R_hi1[gps]);
			`RX_BUF1(u_st_pllo,  st_rep_c[gps], st_pl_lo[gps]);
			`RX_BUF1(u_st_plhi,  st_rep_c[gps], st_pl_hi[gps]);
			`RX_BUF1(u_st_fdbl0, st_rep_c[gps], st_fdb_lo0[gps]);
			`RX_BUF1(u_st_fdbl1, st_rep_c[gps], st_fdb_lo1[gps]);
			`RX_BUF1(u_st_fdbh0, st_rep_c[gps], st_fdb_hi0[gps]);
			`RX_BUF1(u_st_fdbh1, st_rep_c[gps], st_fdb_hi1[gps]);
			`RX_BUF1(u_st_tlo,   st_rep_c[gps], st_T_lo[gps]);
			`RX_BUF1(u_st_thi,   st_rep_c[gps], st_T_hi[gps]);

			`RX_BUF1(u_psc,    p_step[gps],       p_step_ctrl[gps]);
			`RX_BUF1(u_ps_pll, p_step_rep_a[gps], p_step_pl_lo[gps]);
			`RX_BUF1(u_ps_plh, p_step_rep_a[gps], p_step_pl_hi[gps]);
			`RX_BUF1(u_ps_tl,  p_step_rep_a[gps], p_step_T_lo[gps]);
			`RX_BUF1(u_ps_th,  p_step_rep_a[gps], p_step_T_hi[gps]);
		end
		for (gsq = 0; gsq < 5; gsq = gsq + 1) begin : g_seq_misc
			`RX_BUF1(u_sq_rlo0, seq_step_rep_a[gsq], seq_R_lo0[gsq]);
			`RX_BUF1(u_sq_rlo1, seq_step_rep_b[gsq], seq_R_lo1[gsq]);
			`RX_BUF1(u_sq_rhi0, seq_step_rep_c[gsq], seq_R_hi0[gsq]);
			`RX_BUF1(u_sq_rhi1, seq_step_rep_d[gsq], seq_R_hi1[gsq]);
			`RX_BUF1(u_sq_pllo, seq_step_rep_a[gsq], seq_pl_lo[gsq]);
			`RX_BUF1(u_sq_plhi, seq_step_rep_b[gsq], seq_pl_hi[gsq]);
			`RX_BUF1(u_sq_fdbl, seq_step_rep_c[gsq], seq_fdb_lo[gsq]);
			`RX_BUF1(u_sq_fdbh, seq_step_rep_d[gsq], seq_fdb_hi[gsq]);
			`RX_BUF1(u_sq_tlo,  seq_step_rep_c[gsq], seq_T_lo[gsq]);
			`RX_BUF1(u_sq_thi,  seq_step_rep_d[gsq], seq_T_hi[gsq]);
		end
	endgenerate

	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] R_lo [0:79];
	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] R_hi [0:79];
	wire [31:0] R [0:79];
	genvar gr;
	generate
		for (gr = 0; gr < 80; gr = gr + 1) begin : g_R_wire
			assign R[gr] = {R_hi[gr], R_lo[gr]};
		end
	endgenerate

	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] pl_lo [0:11];
	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] pl_hi [0:11];
	wire [31:0] pl [0:11];
	genvar gpl;
	generate
		for (gpl = 0; gpl < 12; gpl = gpl + 1) begin : g_pl_wire
			assign pl[gpl] = {pl_hi[gpl], pl_lo[gpl]};
		end
	endgenerate

	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] T0_lo, T0_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] T1_lo, T1_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] T2_lo, T2_hi;
	wire [31:0] T0 = {T0_hi, T0_lo};
	wire [31:0] T1 = {T1_hi, T1_lo};
	wire [31:0] T2 = {T2_hi, T2_lo};

	(* extract_reset = "no", extract_enable = "no" *) reg [15:0] r_bias_fa_lo, r_bias_fa_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_bcl_is_zero_lo, r_bcl_is_zero_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_bcl_sign_lo, r_bcl_sign_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_bcl_mag_lt_lo, r_bcl_mag_lt_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_bcl_mag_eq_lo, r_bcl_mag_eq_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_fa_nan_lo, r_fa_nan_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_fa_sign_lo, r_fa_sign_hi;
	(* extract_reset = "no", extract_enable = "no" *) reg r_fa_is_zero_lo, r_fa_is_zero_hi;
	wire [31:0] bm_val = max_mag({1'b0, pl[0][30:0]}, {1'b0, pl[1][30:0]});

	 wire [7:0] fa_o_s, fm_o_s;
	 wire fa_o_R_lo, fa_o_R_hi, fa_o_pl_lo, fa_o_pl_hi, fa_o_c_st, fa_o_c_seq, fa_o_c_ps, fa_o_c_v;
	 wire fm_o_R_lo, fm_o_R_hi, fm_o_pl_lo, fm_o_pl_hi, fm_o_c_st, fm_o_c_seq, fm_o_c_ps, fm_o_c_v;
	 wire fd_o_w, fd_o_fdb_lo, fd_o_fdb_hi, fd_o_plane_lo, fd_o_plane_hi, fd_o_plane_ctrl;

	genvar gfo;
	generate
		for (gfo = 0; gfo < 8; gfo = gfo + 1) begin : g_fo_sl
			`RX_BUF1(u_fao_s, fa_o, fa_o_s[gfo]);
			`RX_BUF1(u_fmo_s, fm_o, fm_o_s[gfo]);
		end
	endgenerate
	`RX_BUF1(u_fao_rlo,  fa_o, fa_o_R_lo);
	`RX_BUF1(u_fao_rhi,  fa_o, fa_o_R_hi);
	`RX_BUF1(u_fao_pllo, fa_o, fa_o_pl_lo);
	`RX_BUF1(u_fao_plhi, fa_o, fa_o_pl_hi);
	`RX_BUF1(u_fao_cst,  fa_o, fa_o_c_st);
	`RX_BUF1(u_fao_csq,  fa_o, fa_o_c_seq);
	`RX_BUF1(u_fao_cps,  fa_o, fa_o_c_ps);
	`RX_BUF1(u_fao_cv,   fa_o, fa_o_c_v);

	`RX_BUF1(u_fmo_rlo,  fm_o, fm_o_R_lo);
	`RX_BUF1(u_fmo_rhi,  fm_o, fm_o_R_hi);
	`RX_BUF1(u_fmo_pllo, fm_o, fm_o_pl_lo);
	`RX_BUF1(u_fmo_plhi, fm_o, fm_o_pl_hi);
	`RX_BUF1(u_fmo_cst,  fm_o, fm_o_c_st);
	`RX_BUF1(u_fmo_csq,  fm_o, fm_o_c_seq);
	`RX_BUF1(u_fmo_cps,  fm_o, fm_o_c_ps);
	`RX_BUF1(u_fmo_cv,   fm_o, fm_o_c_v);

	`RX_BUF1(u_fdo_w,    fd_o, fd_o_w);
	`RX_BUF1(u_fdo_fdbl, fd_o, fd_o_fdb_lo);
	`RX_BUF1(u_fdo_fdbh, fd_o, fd_o_fdb_hi);
	`RX_BUF1(u_fdo_pllo, fd_o, fd_o_plane_lo);
	`RX_BUF1(u_fdo_plhi, fd_o, fd_o_plane_hi);
	`RX_BUF1(u_fdo_pctl, fd_o, fd_o_plane_ctrl);

	wire [31:0] fa_r_R, fa_r_pl;
	wire [31:0] fm_r_R, fm_r_pl;
	wire [6:0] e_ra_b [0:7];
	genvar gbf, gnb;
	generate
		for (gbf = 0; gbf < 32; gbf = gbf + 1) begin : g_fpu_res_buf
			`RX_BUF1(u_far_r, fa_r[gbf], fa_r_R[gbf]);
			`RX_BUF1(u_far_p, fa_r[gbf], fa_r_pl[gbf]);
			`RX_BUF1(u_fmr_r, fm_r[gbf], fm_r_R[gbf]);
			`RX_BUF1(u_fmr_p, fm_r[gbf], fm_r_pl[gbf]);
		end
		for (gnb = 0; gnb < 8; gnb = gnb + 1) begin : g_era_nib
			for (gbf = 0; gbf < 7; gbf = gbf + 1) begin : g_era_bit
				`RX_BUF1(u_era, e_ra[gbf], e_ra_b[gnb][gbf]);
			end
		end
	endgenerate

	wire e_empty_buf;
	`RX_BUF1(u_buf_empty, e_empty, e_empty_buf);

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
		.clk(clk), .rst_n(rst_n_edge), .start(e_start),
		.mode({raw, sub, kind_edge}), .smin(cur_smin), .smax(cur_smax), .rts(rts), .cull(cull),
		.vprect(rm[3]), .line_width(line_width), .point_size(point_size),
		.r_ra(e_ra), .r_rd(e_rd), .r_we(e_we), .r_wa(e_wa), .r_wd(e_wd),
		.done(e_done), .edges(e_edges), .bbox(e_bbox), .front(e_front), .empty(e_empty)
	);

	wire [6:0] we_r40_l, we_r40_h;
	genvar gr40;
	generate
		for (gr40 = 0; gr40 < 7; gr40 = gr40 + 1) begin : g_we_r40
			wire we_raw = e_we && (e_wa == (7'd40 + gr40));
			`RX_BUF1(u_wer40_l, we_raw, we_r40_l[gr40]);
			`RX_BUF1(u_wer40_h, we_raw, we_r40_h[gr40]);
		end
	endgenerate

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
	(* max_fanout = 16 *) reg fa_v, fm_v, fd_v;
	(* max_fanout = 16, extract_enable = "no", extract_reset = "no" *) reg fa_sub;
	(* extract_enable = "no", extract_reset = "no" *) reg [15:0] fd_b_lo, fd_b_hi;
	wire [31:0] fa_a, fa_b, fm_a, fm_b;
	wire [31:0] fd_a = ONE;
	wire [31:0] fd_b = {fd_b_hi, fd_b_lo};
	wire fa_o, fm_o, fd_o, fd_busy;
	wire [31:0] fa_r, fm_r, fd_r;

	atg_rx_fadd #(.LAT(4)) fadd (
		.clk(clk), .rst_n(rst_n_fpu), .i_valid(fa_v), .i_a(fa_a), .i_b(fa_b),
		.i_sub(fa_sub), .o_valid(fa_o), .o_r(fa_r)
	);
	atg_rx_fmul #(.LAT(4)) fmul (
		.clk(clk), .rst_n(rst_n_fpu), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r)
	);
	am_fp_div fdiv (
		.clk(clk), .rst_n(rst_n_fpu), .i_start(fd_v), .i_a(fd_a), .i_b(fd_b),
		.busy(fd_busy), .o_done(fd_o), .o_r(fd_r)
	);

	/* Hardware carry-chain float magnitude comparator for depth bias clamp */
	wire bcl_mag_lt;
	am_sub #(.W(31)) u_bcl_sub (
		.a(fa_r[30:0]),
		.b(b_clamp[30:0]),
		.bi(1'b0),
		.d(),
		.bo(bcl_mag_lt)
	);
	wire bcl_lo_zero = (b_clamp_lo == 16'd0);
	wire bcl_hi_zero = (b_clamp_hi[14:0] == 15'd0);
	wire bcl_is_zero = bcl_lo_zero && bcl_hi_zero;
	wire bcl_nan = (b_clamp[30:23] == 8'hFF) && (b_clamp[22:0] != 23'd0);
	wire bcl_nan_free_lo = !r_fa_nan_lo;
	wire bcl_nan_free_hi = !r_fa_nan_hi;
	wire bcl_fa_le_lo = bcl_nan_free_lo && (
		r_fa_sign_lo ? (r_bcl_sign_lo ? !r_bcl_mag_lt_lo : 1'b1) :
		               (r_bcl_sign_lo ? (r_fa_is_zero_lo && r_bcl_is_zero_lo) : (r_bcl_mag_lt_lo || r_bcl_mag_eq_lo))
	);
	wire bcl_fa_le_hi = bcl_nan_free_hi && (
		r_fa_sign_hi ? (r_bcl_sign_hi ? !r_bcl_mag_lt_hi : 1'b1) :
		               (r_bcl_sign_hi ? (r_fa_is_zero_hi && r_bcl_is_zero_hi) : (r_bcl_mag_lt_hi || r_bcl_mag_eq_hi))
	);
	wire bcl_ge_lo = bcl_nan_free_lo && (
		r_bcl_sign_lo ? (r_fa_sign_lo ? (r_bcl_mag_lt_lo || r_bcl_mag_eq_lo) : 1'b1) :
		                (r_fa_sign_lo ? (r_fa_is_zero_lo && r_bcl_is_zero_lo) : !r_bcl_mag_lt_lo)
	);
	wire bcl_ge_hi = bcl_nan_free_hi && (
		r_bcl_sign_hi ? (r_fa_sign_hi ? (r_bcl_mag_lt_hi || r_bcl_mag_eq_hi) : 1'b1) :
		                (r_fa_sign_hi ? (r_fa_is_zero_hi && r_bcl_is_zero_hi) : !r_bcl_mag_lt_hi)
	);
	(* keep = "true" *) wire bcl_use_fa_lo = r_bcl_is_zero_lo || (!r_bcl_sign_lo ? bcl_fa_le_lo : bcl_ge_lo);
	(* keep = "true" *) wire bcl_use_fa_hi = r_bcl_is_zero_hi || (!r_bcl_sign_hi ? bcl_fa_le_hi : bcl_ge_hi);

	function [31:0] max_mag;
		input [31:0] a, b;
		max_mag = b[30:0] > a[30:0] ? b : a;
	endfunction

	/* Pre-register bm_sel (pl[0] and pl[1] are written >100 cycles before S_BIAS) to eliminate CARRY4 in fm_a_sl path */
	wire bm_sel = {1'b0, pl[1][30:0]} > {1'b0, pl[0][30:0]};
	(* extract_enable = "no", extract_reset = "no" *) reg r_bm_sel_lo, r_bm_sel_hi;
	always @(posedge clk) begin
		r_bm_sel_lo <= bm_sel;
		r_bm_sel_hi <= bm_sel;
	end
	wire [15:0] bm_val_lo = r_bm_sel_lo ? pl_lo[1] : pl_lo[0];
	wire [15:0] bm_val_hi = r_bm_sel_hi ? {1'b0, pl_hi[1][14:0]} : {1'b0, pl_hi[0][14:0]};

	wire [7:0] ea23;
	wire su_bo_unused;
	(* extract_enable = "no", extract_reset = "no" *) reg [7:0] ea_in;
	am_sub #(.W(8)) u_ea23 (.a(ea_in), .b(8'd23), .bi(1'b0), .d(ea23), .bo(su_bo_unused));

	wire [31:0] max_z01 = max_mag({1'b0, R[33][30:0]}, {1'b0, R[36][30:0]});
	wire [31:0] max_z   = max_mag(max_z01, {1'b0, R[39][30:0]});

	/* Stream Selection: cl_* vs mesh_* (Option 4 Static MUX with cl_* priority) */
	 wire cl_valid_b0, cl_valid_b1;
	`RX_BUF1(u_clv_b0, cl_valid, cl_valid_b0);
	`RX_BUF1(u_clv_b1, cl_valid, cl_valid_b1);
	wire in_mesh = mesh_valid && !cl_valid_b0;
	wire in_valid = cl_valid_b0 || mesh_valid;
	wire [701:0] in_tri;
	wire in_last = in_mesh ? mesh_last : cl_last;

	wire in_raw = cl_valid_b1 ? cl_tri[699] : mesh_tri[699];
	wire [1:0] in_kind_hdr = cl_valid_b1 ? cl_tri[701:700] : mesh_tri[701:700];
	 wire cl_valid_kp0, cl_valid_kp1;
	`RX_BUF1(u_clv_kp0, cl_valid_b0, cl_valid_kp0);
	`RX_BUF1(u_clv_kp1, cl_valid_b1, cl_valid_kp1);
	wire [26:0] in_keep_hdr = {
		cl_valid_kp1 ? cl_tri[698:688] : mesh_tri[698:688],
		cl_valid_kp0 ? cl_tri[687:672] : mesh_tri[687:672]
	};

	 wire [3:0] in_mesh_t1;
	 wire [43:0] in_mesh_leaf;
	 wire [21:0] in_mesh_leaf_r31;
	(* keep = "true" *) wire [351:0] in_tri_r31;
	genvar gmt, gml;
	generate
		for (gmt = 0; gmt < 4; gmt = gmt + 1) begin : g_im_t1
			`RX_BUF1(u_imt, in_mesh, in_mesh_t1[gmt]);
			for (gml = 0; gml < 11; gml = gml + 1) begin : g_im_leaf
				`RX_BUF1(u_iml, in_mesh_t1[gmt], in_mesh_leaf[gmt * 11 + gml]);
			end
		end
		for (gml = 0; gml < 44; gml = gml + 1) begin : g_im_mux
			localparam integer HI = (gml == 43) ? 701 : (gml * 16 + 15);
			localparam integer LO = gml * 16;
			assign in_tri[HI:LO] = in_mesh_leaf[gml] ? mesh_tri[HI:LO] : cl_tri[HI:LO];
		end
		for (gml = 0; gml < 22; gml = gml + 1) begin : g_im_r31
			`RX_BUF1(u_im_r31, in_mesh_t1[gml / 6], in_mesh_leaf_r31[gml]);
			assign in_tri_r31[gml * 16 +: 16] = in_mesh_leaf_r31[gml] ? mesh_tri[gml * 16 +: 16] : cl_tri[gml * 16 +: 16];
		end
	endgenerate

	 wire in_valid_ctrl, in_valid_pl, in_valid_fd, in_valid_fdb_lo, in_valid_fdb_hi;
	(* keep = "true" *) wire we_idle_in = rst_n_setup && (st_rep_c == S_IDLE) && in_valid_ctrl;
	 wire we_idle_ctrl, we_idle_fsm, we_idle_keep_lo, we_idle_keep_hi;
	 wire [4:0] iv_branch;
	 wire [20:0] we_in_lo, we_in_hi;
	 wire [6:0] we_vpr_lo, we_vpr_hi;

	`RX_BUF1(u_iv_ctrl,  in_valid, in_valid_ctrl);
	`RX_BUF1(u_iv_pl,    in_valid, in_valid_pl);
	`RX_BUF1(u_iv_fd,    in_valid, in_valid_fd);
	`RX_BUF1(u_iv_fdbl,  in_valid, in_valid_fdb_lo);
	`RX_BUF1(u_iv_fdbh,  in_valid, in_valid_fdb_hi);

	`RX_BUF1(u_wid_c,   we_idle_in, we_idle_ctrl);
	`RX_BUF1(u_wid_fsm, we_idle_in, we_idle_fsm);
	`RX_BUF1(u_wid_kl,  we_idle_in, we_idle_keep_lo);
	`RX_BUF1(u_wid_kh,  we_idle_in, we_idle_keep_hi);

	`RX_BUF1(u_iv_b0, we_idle_in, iv_branch[0]);
	`RX_BUF1(u_iv_b1, we_idle_in, iv_branch[1]);
	`RX_BUF1(u_iv_b2, we_idle_in, iv_branch[2]);
	`RX_BUF1(u_iv_b3, we_idle_in, iv_branch[3]);
	`RX_BUF1(u_iv_b4, we_idle_in, iv_branch[4]);

	genvar giv;
	generate
		for (giv = 0; giv < 21; giv = giv + 1) begin : g_we_in
			localparam integer BR = (giv < 6) ? 0 : (giv < 12) ? 1 : (giv < 18) ? 2 : 3;
			`RX_BUF1(u_wel, iv_branch[BR], we_in_lo[giv]);
			`RX_BUF1(u_weh, iv_branch[BR], we_in_hi[giv]);
		end
		for (giv = 0; giv < 7; giv = giv + 1) begin : g_we_vp
			localparam integer BRV = (giv < 3) ? 3 : 4;
			`RX_BUF1(u_wvpl, iv_branch[BRV], we_vpr_lo[giv]);
			`RX_BUF1(u_wvph, iv_branch[BRV], we_vpr_hi[giv]);
		end
	endgenerate

	 wire cl_ready_out, mesh_ready_out, busy_out;
	`RX_BUF1(u_cr_out, (st == S_IDLE), cl_ready_out);
	`RX_BUF1(u_mr_out, (st == S_IDLE), mesh_ready_out);
	`RX_BUF1(u_bs_out, (st != S_IDLE), busy_out);
	assign cl_ready = cl_ready_out;
	assign mesh_ready = mesh_ready_out;
	assign busy = busy_out;
	assign sp_last = lastq && !more;

	wire [15:0] cur_A_lo = (p_plane_2_l == 2'd0) ? pl_lo[0] : (p_plane_2_l == 2'd1) ? pl_lo[3] : (p_plane_2_l == 2'd2) ? pl_lo[6] : pl_lo[9];
	wire [15:0] cur_A_hi = (p_plane_2_h == 2'd0) ? pl_hi[0] : (p_plane_2_h == 2'd1) ? pl_hi[3] : (p_plane_2_h == 2'd2) ? pl_hi[6] : pl_hi[9];
	wire [31:0] cur_A = {cur_A_hi, cur_A_lo};

	wire [15:0] cur_B_lo = (p_plane_3_l == 2'd0) ? pl_lo[1] : (p_plane_3_l == 2'd1) ? pl_lo[4] : (p_plane_3_l == 2'd2) ? pl_lo[7] : pl_lo[10];
	wire [15:0] cur_B_hi = (p_plane_3_h == 2'd0) ? pl_hi[1] : (p_plane_3_h == 2'd1) ? pl_hi[4] : (p_plane_3_h == 2'd2) ? pl_hi[7] : pl_hi[10];
	wire [31:0] cur_B = {cur_B_hi, cur_B_lo};

	wire [15:0] R_pf0_lo = (p_plane_pf0_l == 2'd0) ? R_lo[33] : (p_plane_pf0_l == 2'd1) ? R_lo[28] : (p_plane_pf0_l == 2'd2) ? R_lo[52] : R_lo[55];
	wire [15:0] R_pf0_hi = (p_plane_pf0_h == 2'd0) ? R_hi[33] : (p_plane_pf0_h == 2'd1) ? R_hi[28] : (p_plane_pf0_h == 2'd2) ? R_hi[52] : R_hi[55];
	wire [31:0] R_pf0 = {R_pf0_hi, R_pf0_lo};

	wire [15:0] R_pf1_lo = (p_plane_pf1_l == 2'd0) ? R_lo[36] : (p_plane_pf1_l == 2'd1) ? R_lo[29] : (p_plane_pf1_l == 2'd2) ? R_lo[53] : R_lo[56];
	wire [15:0] R_pf1_hi = (p_plane_pf1_h == 2'd0) ? R_hi[36] : (p_plane_pf1_h == 2'd1) ? R_hi[29] : (p_plane_pf1_h == 2'd2) ? R_hi[53] : R_hi[56];
	wire [31:0] R_pf1 = {R_pf1_hi, R_pf1_lo};

	wire [15:0] R_pf2_lo = (p_plane_pf2_l == 2'd0) ? R_lo[39] : (p_plane_pf2_l == 2'd1) ? R_lo[30] : (p_plane_pf2_l == 2'd2) ? R_lo[54] : R_lo[57];
	wire [15:0] R_pf2_hi = (p_plane_pf2_h == 2'd0) ? R_hi[39] : (p_plane_pf2_h == 2'd1) ? R_hi[30] : (p_plane_pf2_h == 2'd2) ? R_hi[54] : R_hi[57];
	wire [31:0] R_pf2 = {R_pf2_hi, R_pf2_lo};

	always @(posedge clk) begin
		case (e_ra_b[0])
		7'd31: e_rd[3:0] <= R_lo[31][3:0];
		7'd32: e_rd[3:0] <= R_lo[32][3:0];
		7'd33: e_rd[3:0] <= R_lo[33][3:0];
		7'd34: e_rd[3:0] <= R_lo[34][3:0];
		7'd35: e_rd[3:0] <= R_lo[35][3:0];
		7'd36: e_rd[3:0] <= R_lo[36][3:0];
		7'd37: e_rd[3:0] <= R_lo[37][3:0];
		7'd38: e_rd[3:0] <= R_lo[38][3:0];
		7'd39: e_rd[3:0] <= R_lo[39][3:0];
		7'd76: e_rd[3:0] <= R_lo[76][3:0];
		7'd77: e_rd[3:0] <= R_lo[77][3:0];
		7'd78: e_rd[3:0] <= R_lo[78][3:0];
		7'd79: e_rd[3:0] <= R_lo[79][3:0];
		default: e_rd[3:0] <= 4'd0;
		endcase
		case (e_ra_b[1])
		7'd31: e_rd[7:4] <= R_lo[31][7:4];
		7'd32: e_rd[7:4] <= R_lo[32][7:4];
		7'd33: e_rd[7:4] <= R_lo[33][7:4];
		7'd34: e_rd[7:4] <= R_lo[34][7:4];
		7'd35: e_rd[7:4] <= R_lo[35][7:4];
		7'd36: e_rd[7:4] <= R_lo[36][7:4];
		7'd37: e_rd[7:4] <= R_lo[37][7:4];
		7'd38: e_rd[7:4] <= R_lo[38][7:4];
		7'd39: e_rd[7:4] <= R_lo[39][7:4];
		7'd76: e_rd[7:4] <= R_lo[76][7:4];
		7'd77: e_rd[7:4] <= R_lo[77][7:4];
		7'd78: e_rd[7:4] <= R_lo[78][7:4];
		7'd79: e_rd[7:4] <= R_lo[79][7:4];
		default: e_rd[7:4] <= 4'd0;
		endcase
		case (e_ra_b[2])
		7'd31: e_rd[11:8] <= R_lo[31][11:8];
		7'd32: e_rd[11:8] <= R_lo[32][11:8];
		7'd33: e_rd[11:8] <= R_lo[33][11:8];
		7'd34: e_rd[11:8] <= R_lo[34][11:8];
		7'd35: e_rd[11:8] <= R_lo[35][11:8];
		7'd36: e_rd[11:8] <= R_lo[36][11:8];
		7'd37: e_rd[11:8] <= R_lo[37][11:8];
		7'd38: e_rd[11:8] <= R_lo[38][11:8];
		7'd39: e_rd[11:8] <= R_lo[39][11:8];
		7'd76: e_rd[11:8] <= R_lo[76][11:8];
		7'd77: e_rd[11:8] <= R_lo[77][11:8];
		7'd78: e_rd[11:8] <= R_lo[78][11:8];
		7'd79: e_rd[11:8] <= R_lo[79][11:8];
		default: e_rd[11:8] <= 4'd0;
		endcase
		case (e_ra_b[3])
		7'd31: e_rd[15:12] <= R_lo[31][15:12];
		7'd32: e_rd[15:12] <= R_lo[32][15:12];
		7'd33: e_rd[15:12] <= R_lo[33][15:12];
		7'd34: e_rd[15:12] <= R_lo[34][15:12];
		7'd35: e_rd[15:12] <= R_lo[35][15:12];
		7'd36: e_rd[15:12] <= R_lo[36][15:12];
		7'd37: e_rd[15:12] <= R_lo[37][15:12];
		7'd38: e_rd[15:12] <= R_lo[38][15:12];
		7'd39: e_rd[15:12] <= R_lo[39][15:12];
		7'd76: e_rd[15:12] <= R_lo[76][15:12];
		7'd77: e_rd[15:12] <= R_lo[77][15:12];
		7'd78: e_rd[15:12] <= R_lo[78][15:12];
		7'd79: e_rd[15:12] <= R_lo[79][15:12];
		default: e_rd[15:12] <= 4'd0;
		endcase
		case (e_ra_b[4])
		7'd31: e_rd[19:16] <= R_hi[31][3:0];
		7'd32: e_rd[19:16] <= R_hi[32][3:0];
		7'd33: e_rd[19:16] <= R_hi[33][3:0];
		7'd34: e_rd[19:16] <= R_hi[34][3:0];
		7'd35: e_rd[19:16] <= R_hi[35][3:0];
		7'd36: e_rd[19:16] <= R_hi[36][3:0];
		7'd37: e_rd[19:16] <= R_hi[37][3:0];
		7'd38: e_rd[19:16] <= R_hi[38][3:0];
		7'd39: e_rd[19:16] <= R_hi[39][3:0];
		7'd76: e_rd[19:16] <= R_hi[76][3:0];
		7'd77: e_rd[19:16] <= R_hi[77][3:0];
		7'd78: e_rd[19:16] <= R_hi[78][3:0];
		7'd79: e_rd[19:16] <= R_hi[79][3:0];
		default: e_rd[19:16] <= 4'd0;
		endcase
		case (e_ra_b[5])
		7'd31: e_rd[23:20] <= R_hi[31][7:4];
		7'd32: e_rd[23:20] <= R_hi[32][7:4];
		7'd33: e_rd[23:20] <= R_hi[33][7:4];
		7'd34: e_rd[23:20] <= R_hi[34][7:4];
		7'd35: e_rd[23:20] <= R_hi[35][7:4];
		7'd36: e_rd[23:20] <= R_hi[36][7:4];
		7'd37: e_rd[23:20] <= R_hi[37][7:4];
		7'd38: e_rd[23:20] <= R_hi[38][7:4];
		7'd39: e_rd[23:20] <= R_hi[39][7:4];
		7'd76: e_rd[23:20] <= R_hi[76][7:4];
		7'd77: e_rd[23:20] <= R_hi[77][7:4];
		7'd78: e_rd[23:20] <= R_hi[78][7:4];
		7'd79: e_rd[23:20] <= R_hi[79][7:4];
		default: e_rd[23:20] <= 4'd0;
		endcase
		case (e_ra_b[6])
		7'd31: e_rd[27:24] <= R_hi[31][11:8];
		7'd32: e_rd[27:24] <= R_hi[32][11:8];
		7'd33: e_rd[27:24] <= R_hi[33][11:8];
		7'd34: e_rd[27:24] <= R_hi[34][11:8];
		7'd35: e_rd[27:24] <= R_hi[35][11:8];
		7'd36: e_rd[27:24] <= R_hi[36][11:8];
		7'd37: e_rd[27:24] <= R_hi[37][11:8];
		7'd38: e_rd[27:24] <= R_hi[38][11:8];
		7'd39: e_rd[27:24] <= R_hi[39][11:8];
		7'd76: e_rd[27:24] <= R_hi[76][11:8];
		7'd77: e_rd[27:24] <= R_hi[77][11:8];
		7'd78: e_rd[27:24] <= R_hi[78][11:8];
		7'd79: e_rd[27:24] <= R_hi[79][11:8];
		default: e_rd[27:24] <= 4'd0;
		endcase
		case (e_ra_b[7])
		7'd31: e_rd[31:28] <= R_hi[31][15:12];
		7'd32: e_rd[31:28] <= R_hi[32][15:12];
		7'd33: e_rd[31:28] <= R_hi[33][15:12];
		7'd34: e_rd[31:28] <= R_hi[34][15:12];
		7'd35: e_rd[31:28] <= R_hi[35][15:12];
		7'd36: e_rd[31:28] <= R_hi[36][15:12];
		7'd37: e_rd[31:28] <= R_hi[37][15:12];
		7'd38: e_rd[31:28] <= R_hi[38][15:12];
		7'd39: e_rd[31:28] <= R_hi[39][15:12];
		7'd76: e_rd[31:28] <= R_hi[76][15:12];
		7'd77: e_rd[31:28] <= R_hi[77][15:12];
		7'd78: e_rd[31:28] <= R_hi[78][15:12];
		7'd79: e_rd[31:28] <= R_hi[79][15:12];
		default: e_rd[31:28] <= 4'd0;
		endcase
	end

	/* ====================================================================
	 * Split Always Blocks for Fanout <= 24 (ASIC 5nm 1.5 GHz Rule 2)
	 * ==================================================================== */

	/* 1. FPU Input Registers (fm_a, fm_b, fa_a, fa_b) split into 8 x 4-bit slices */
	 wire [1:0] kind_s [0:7];
	 wire [7:0] rm3_s, ea_gt23_s;
	wire ea_gt_23 = (ea_in > 8'd23);
	wire [31:0] bm_val_32 = {bm_val_hi, bm_val_lo};
	wire [31:0] b_clamp_32 = {b_clamp_hi, b_clamp_lo};
	wire [31:0] r_bias_fa_32 = {r_bias_fa_hi, r_bias_fa_lo};
	wire [31:0] ea23_f32 = {1'b0, ea23, 23'd0};

	genvar gs;
	generate
	for (gs = 0; gs < 8; gs = gs + 1) begin : g_fpu_slice
		localparam integer B0 = gs * 4;
		localparam integer B1 = gs * 4 + 3;
		`RX_BUF1(u_kd0_s, kind_fpu[0], kind_s[gs][0]);
		`RX_BUF1(u_kd1_s, kind_fpu[1], kind_s[gs][1]);
		`RX_BUF1(u_rm3_s, rm[3],       rm3_s[gs]);
		`RX_BUF1(u_eag_s, ea_gt_23,    ea_gt23_s[gs]);

		(* extract_enable = "no", extract_reset = "no" *) reg [3:0] fm_a_sl, fm_b_sl, fa_a_sl, fa_b_sl;
		assign fm_a[B1:B0] = fm_a_sl;
		assign fm_b[B1:B0] = fm_b_sl;
		assign fa_a[B1:B0] = fa_a_sl;
		assign fa_b[B1:B0] = fa_b_sl;

		wire [3:0] r21_abs_sl = (gs == 7) ? {1'b0, R[21][30:28]} : R[21][B1:B0];
		wire [3:0] r22_abs_sl = (gs == 7) ? {1'b0, R[22][30:28]} : R[22][B1:B0];
		wire bcl_use_fa_sl = (gs < 4) ? bcl_use_fa_lo : bcl_use_fa_hi;

		always @(posedge clk) begin
			if (rst_n_setup) begin
				case (st_fma_s[gs])
				S_PERSP_XYZ:
					case (seq_fma_s[gs])
					5'd0:  fm_a_sl <= R[0][B1:B0];
					5'd1, 5'd4, 5'd7, 5'd12, 5'd15, 5'd18, 5'd23, 5'd26, 5'd29: fm_a_sl <= fm_r[B1:B0];
					5'd3:  fm_a_sl <= R[1][B1:B0];
					5'd6:  fm_a_sl <= R[2][B1:B0];
					5'd9:  fm_a_sl <= R[12][B1:B0];
					5'd10: fm_a_sl <= R[13][B1:B0];
					5'd11: fm_a_sl <= R[4][B1:B0];
					5'd14: fm_a_sl <= R[5][B1:B0];
					5'd17: fm_a_sl <= R[6][B1:B0];
					5'd20: fm_a_sl <= R[15][B1:B0];
					5'd21: fm_a_sl <= R[16][B1:B0];
					5'd22: fm_a_sl <= R[8][B1:B0];
					5'd25: fm_a_sl <= R[9][B1:B0];
					5'd28: fm_a_sl <= R[10][B1:B0];
					5'd2, 5'd5, 5'd8, 5'd13, 5'd16, 5'd19, 5'd24, 5'd27, 5'd30: ;
					default: fm_a_sl <= R[18][B1:B0];
					endcase
				S_RECT:
					if (seq_fma_s[gs] == 5'd0) fm_a_sl <= R[19][B1:B0];
				S_EDGE:
					fm_a_sl <= R[45][B1:B0];
				S_PLANE_DIV:
					if ((kind_s[gs] == 2'd0) && (seq_fma_s[gs] == 5'd1)) fm_a_sl <= R[46][B1:B0];
				S_PLANE:
					case (p_step_a_s[gs])
					4'd2:  fm_a_sl <= T0[B1:B0];
					4'd3:  fm_a_sl <= T1[B1:B0];
					4'd5:  fm_a_sl <= fa_r[B1:B0];
					4'd6:  fm_a_sl <= T1[B1:B0];
					4'd7:  fm_a_sl <= T0[B1:B0];
					4'd9:  fm_a_sl <= fa_r[B1:B0];
					4'd10: fm_a_sl <= cur_A[B1:B0];
					4'd11: fm_a_sl <= cur_B[B1:B0];
					default: ;
					endcase
				S_BIAS:
					case (seq_fma_s[gs])
					5'd0: fm_a_sl <= bm_val_32[B1:B0];
					5'd2: fm_a_sl <= rfmt[B1:B0];
					5'd3: fm_a_sl <= ea_gt23_s[gs] ? ea23_f32[B1:B0] : 4'd0;
					default: ;
					endcase
				default: ;
				endcase

				case (st_fmb_s[gs])
				S_PERSP_XYZ:
					case (seq_fmb_s[gs])
					5'd0, 5'd3, 5'd6, 5'd9, 5'd10: fm_b_sl <= R[28][B1:B0];
					5'd1, 5'd12, 5'd23: fm_b_sl <= R[21][B1:B0];
					5'd4, 5'd15, 5'd26: fm_b_sl <= R[22][B1:B0];
					5'd7, 5'd18, 5'd29: fm_b_sl <= R[25][B1:B0];
					5'd11, 5'd14, 5'd17, 5'd20, 5'd21: fm_b_sl <= R[29][B1:B0];
					5'd22, 5'd25, 5'd28: fm_b_sl <= R[30][B1:B0];
					5'd2, 5'd5, 5'd8, 5'd13, 5'd16, 5'd19, 5'd24, 5'd27, 5'd30: ;
					default: fm_b_sl <= R[30][B1:B0];
					endcase
				S_RECT:
					if (seq_fmb_s[gs] == 5'd0) fm_b_sl <= R[30][B1:B0];
				S_EDGE:
					fm_b_sl <= inv_ps[B1:B0];
				S_PLANE_DIV:
					if ((kind_s[gs] == 2'd0) && (seq_fmb_s[gs] == 5'd1)) fm_b_sl <= inv_ps[B1:B0];
				S_PLANE:
					case (p_step_b_s[gs])
					4'd2:  fm_b_sl <= R[43][B1:B0];
					4'd3:  fm_b_sl <= R[41][B1:B0];
					4'd5:  fm_b_sl <= R[47][B1:B0];
					4'd6:  fm_b_sl <= R[40][B1:B0];
					4'd7:  fm_b_sl <= R[42][B1:B0];
					4'd9:  fm_b_sl <= R[47][B1:B0];
					4'd10: fm_b_sl <= R[45][B1:B0];
					4'd11: fm_b_sl <= R[46][B1:B0];
					default: ;
					endcase
				S_BIAS:
					case (seq_fmb_s[gs])
					5'd1: fm_b_sl <= b_slope[B1:B0];
					5'd2, 5'd3: fm_b_sl <= b_const[B1:B0];
					default: ;
					endcase
				default: ;
				endcase

				case (st_faa_s[gs])
				S_PERSP_XYZ:
					if (fm_o_s[gs]) begin
						case (seq_faa_s[gs])
						5'd2, 5'd5, 5'd8, 5'd13, 5'd16, 5'd19, 5'd24, 5'd27, 5'd30: fa_a_sl <= fm_r[B1:B0];
						default: ;
						endcase
					end
				S_RECT:
					case (seq_faa_s[gs])
					5'd1: if (fm_o_s[gs] && rm3_s[gs]) fa_a_sl <= R[23][B1:B0];
					5'd2: if (fa_o_s[gs]) fa_a_sl <= R[23][B1:B0];
					5'd3, 5'd4: if (fa_o_s[gs]) fa_a_sl <= R[24][B1:B0];
					default: ;
					endcase
				S_EDGE:
					fa_a_sl <= HALF[B1:B0];
				S_PLANE_DIV:
					if (kind_s[gs] == 2'd0) begin
						case (seq_faa_s[gs])
						5'd0, 5'd3: if (fm_o_s[gs]) fa_a_sl <= HALF[B1:B0];
						5'd2: if (fa_o_s[gs]) fa_a_sl <= HALF[B1:B0];
						default: ;
						endcase
					end
				S_PLANE:
					case (p_step_a_s[gs])
					4'd0: fa_a_sl <= R_pf1[B1:B0];
					4'd1: if (fa_o_s[gs]) fa_a_sl <= R_pf2[B1:B0];
					4'd4, 4'd8, 4'd12: if (fm_o_s[gs]) fa_a_sl <= T2[B1:B0];
					4'd13: if (fa_o_s[gs]) fa_a_sl <= R_pf0[B1:B0];
					default: ;
					endcase
				S_BIAS:
					case (seq_faa_s[gs])
					5'd4: if (fm_o_s[gs]) fa_a_sl <= T0[B1:B0];
					5'd7: fa_a_sl <= pl[2][B1:B0];
					default: ;
					endcase
				default: ;
				endcase

				case (st_fab_s[gs])
				S_PERSP_XYZ:
					if (fm_o_s[gs]) begin
						case (seq_fab_s[gs])
						5'd2, 5'd13, 5'd24: fa_b_sl <= R[23][B1:B0];
						5'd5, 5'd16, 5'd27: fa_b_sl <= R[24][B1:B0];
						5'd8, 5'd19, 5'd30: fa_b_sl <= R[26][B1:B0];
						default: ;
						endcase
					end
				S_RECT:
					case (seq_fab_s[gs])
					5'd1: if (fm_o_s[gs] && rm3_s[gs]) fa_b_sl <= r21_abs_sl;
					5'd2: if (fa_o_s[gs]) fa_b_sl <= r21_abs_sl;
					5'd3, 5'd4: if (fa_o_s[gs]) fa_b_sl <= r22_abs_sl;
					default: ;
					endcase
				S_EDGE:
					fa_b_sl <= R[45][B1:B0];
				S_PLANE_DIV:
					if (kind_s[gs] == 2'd0) begin
						case (seq_fab_s[gs])
						5'd0, 5'd3: if (fm_o_s[gs]) fa_b_sl <= fm_r[B1:B0];
						5'd2: if (fa_o_s[gs]) fa_b_sl <= R[46][B1:B0];
						default: ;
						endcase
					end
				S_PLANE:
					case (p_step_b_s[gs])
					4'd0: fa_b_sl <= R_pf0[B1:B0];
					4'd1: if (fa_o_s[gs]) fa_b_sl <= R_pf0[B1:B0];
					4'd4, 4'd8, 4'd12: if (fm_o_s[gs]) fa_b_sl <= fm_r[B1:B0];
					4'd13: if (fa_o_s[gs]) fa_b_sl <= fa_r[B1:B0];
					default: ;
					endcase
				S_BIAS:
					case (seq_fab_s[gs])
					5'd4: if (fm_o_s[gs]) fa_b_sl <= fm_r[B1:B0];
					5'd6: fa_b_sl <= bcl_use_fa_sl ? r_bias_fa_32[B1:B0] : b_clamp_32[B1:B0];
					default: ;
					endcase
				default: ;
				endcase
			end
		end
	end
	endgenerate

	/* 2. S_IDLE Preload Registers: R_lo[0:27], R_hi[0:27], keep, raw, kind*, lastq */
	wire [1:0] next_kind_idle = (in_raw || in_kind_hdr == 2'd3) ? 2'd2 : in_kind_hdr;
	genvar gri;
	generate
	for (gri = 0; gri < 21; gri = gri + 1) begin : g_r_idle_load
		always @(posedge clk) begin
			if (we_in_lo[gri]) R_lo[gri] <= in_tri[gri * 32 +: 16];
			if (we_in_hi[gri]) R_hi[gri] <= in_tri[gri * 32 + 16 +: 16];
		end
	end
	endgenerate

	always @(posedge clk) begin
		if (we_idle_ctrl) begin
			raw <= in_raw;
			kind <= next_kind_idle;
			kind_prim <= next_kind_idle;
			kind_out <= next_kind_idle;
			kind_edge <= next_kind_idle;
			kind_fpu <= next_kind_idle;
			lastq <= in_last;
		end
		if (we_idle_keep_lo) keep[13:0] <= in_keep_hdr[13:0];
		if (we_idle_keep_hi) keep[26:14] <= in_keep_hdr[26:14];

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
	end

	/* 3. R_lo[28:39, 47, 52:57, 76:79] and R_hi[28:39, 47, 52:57, 76:79]
	 * Split write enables into 8-bit halves (lo0/lo1/hi0/hi1) so max fanout <= 16 */
	 wire in_raw_b0;
	`RX_BUF1(u_in_raw_b0, in_raw, in_raw_b0);
	(* keep = "true" *) wire raw_load_b0 = (st_rep_c == S_IDLE) && in_valid_ctrl && in_raw_b0;
	(* keep = "true" *) wire raw_load_b1 = (st_rep_d == S_IDLE) && in_valid_fd   && in_raw_b0;
	 wire [8:0] we_raw_r_lo0, we_raw_r_lo1, we_raw_r_hi0, we_raw_r_hi1;
	genvar grw;
	generate
		for (grw = 0; grw < 9; grw = grw + 1) begin : g_we_raw_r
			`RX_BUF1(u_wrl0, raw_load_b0, we_raw_r_lo0[grw]);
			`RX_BUF1(u_wrl1, raw_load_b0, we_raw_r_lo1[grw]);
			`RX_BUF1(u_wrh0, raw_load_b1, we_raw_r_hi0[grw]);
			`RX_BUF1(u_wrh1, raw_load_b1, we_raw_r_hi1[grw]);
		end
	endgenerate

	wire line_dup_cond = rst_n_setup && (st_R_lo1 == S_RECT) && (kind == 2'd1) &&
		(((seq_R_lo1 == 5'd1) && fm_o_R_lo && !rm[3]) || ((seq_R_lo1 >= 5'd5) && fa_o_R_lo));
	 wire we_ldup_r30_lo0, we_ldup_r30_lo1, we_ldup_r30_hi0, we_ldup_r30_hi1;
	 wire we_ldup_r39_lo0, we_ldup_r39_lo1, we_ldup_r39_hi0, we_ldup_r39_hi1;
	 wire we_ldup_r54_lo0, we_ldup_r54_lo1, we_ldup_r54_hi0, we_ldup_r54_hi1;
	 wire we_ldup_r57_lo0, we_ldup_r57_lo1, we_ldup_r57_hi0, we_ldup_r57_hi1;
	`RX_BUF1(u_ld30l0, line_dup_cond, we_ldup_r30_lo0);
	`RX_BUF1(u_ld30l1, line_dup_cond, we_ldup_r30_lo1);
	`RX_BUF1(u_ld30h0, line_dup_cond, we_ldup_r30_hi0);
	`RX_BUF1(u_ld30h1, line_dup_cond, we_ldup_r30_hi1);
	`RX_BUF1(u_ld39l0, line_dup_cond, we_ldup_r39_lo0);
	`RX_BUF1(u_ld39l1, line_dup_cond, we_ldup_r39_lo1);
	`RX_BUF1(u_ld39h0, line_dup_cond, we_ldup_r39_hi0);
	`RX_BUF1(u_ld39h1, line_dup_cond, we_ldup_r39_hi1);
	`RX_BUF1(u_ld54l0, line_dup_cond, we_ldup_r54_lo0);
	`RX_BUF1(u_ld54l1, line_dup_cond, we_ldup_r54_lo1);
	`RX_BUF1(u_ld54h0, line_dup_cond, we_ldup_r54_hi0);
	`RX_BUF1(u_ld54h1, line_dup_cond, we_ldup_r54_hi1);
	`RX_BUF1(u_ld57l0, line_dup_cond, we_ldup_r57_lo0);
	`RX_BUF1(u_ld57l1, line_dup_cond, we_ldup_r57_lo1);
	`RX_BUF1(u_ld57h0, line_dup_cond, we_ldup_r57_hi0);
	`RX_BUF1(u_ld57h1, line_dup_cond, we_ldup_r57_hi1);

	wire pw_base_cond = rst_n_setup && (st_R_lo0 == S_PERSP_W) && fd_o_w;
	 wire we_r28_lo, we_r28_hi, we_r29_lo, we_r29_hi;
	 wire we_r30_pw_lo0, we_r30_pw_lo1, we_r30_pw_hi0, we_r30_pw_hi1;
	`RX_BUF1(u_wr28l,  pw_base_cond && (seq_R_lo0 == 5'd0), we_r28_lo);
	`RX_BUF1(u_wr28h,  pw_base_cond && (seq_R_hi0 == 5'd0), we_r28_hi);
	`RX_BUF1(u_wr29l,  pw_base_cond && (seq_R_lo0 == 5'd1), we_r29_lo);
	`RX_BUF1(u_wr29h,  pw_base_cond && (seq_R_hi0 == 5'd1), we_r29_hi);
	`RX_BUF1(u_wr30l0, pw_base_cond && (seq_R_lo0 >= 5'd2), we_r30_pw_lo0);
	`RX_BUF1(u_wr30l1, pw_base_cond && (seq_R_lo0 >= 5'd2), we_r30_pw_lo1);
	`RX_BUF1(u_wr30h0, pw_base_cond && (seq_R_hi0 >= 5'd2), we_r30_pw_hi0);
	`RX_BUF1(u_wr30h1, pw_base_cond && (seq_R_hi0 >= 5'd2), we_r30_pw_hi1);

	wire pxyz_fa_lo0 = rst_n_setup && (st_R_lo0 == S_PERSP_XYZ) && fa_o_R_lo;
	wire pxyz_fa_hi0 = rst_n_setup && (st_R_hi0 == S_PERSP_XYZ) && fa_o_R_hi;
	wire pxyz_fa_lo1 = rst_n_setup && (st_R_lo1 == S_PERSP_XYZ) && fa_o_R_lo;
	wire pxyz_fa_hi1 = rst_n_setup && (st_R_hi1 == S_PERSP_XYZ) && fa_o_R_hi;
	 wire [8:0] we_pxyz_lo0, we_pxyz_lo1, we_pxyz_hi0, we_pxyz_hi1;
	`RX_BUF1(u_wpx0l0, pxyz_fa_lo0 && (seq_R_lo0 == 5'd3),  we_pxyz_lo0[0]);
	`RX_BUF1(u_wpx0l1, pxyz_fa_lo0 && (seq_R_lo0 == 5'd3),  we_pxyz_lo1[0]);
	`RX_BUF1(u_wpx0h0, pxyz_fa_hi0 && (seq_R_hi0 == 5'd3),  we_pxyz_hi0[0]);
	`RX_BUF1(u_wpx0h1, pxyz_fa_hi0 && (seq_R_hi0 == 5'd3),  we_pxyz_hi1[0]);
	`RX_BUF1(u_wpx1l0, pxyz_fa_lo0 && (seq_R_lo0 == 5'd6),  we_pxyz_lo0[1]);
	`RX_BUF1(u_wpx1l1, pxyz_fa_lo0 && (seq_R_lo0 == 5'd6),  we_pxyz_lo1[1]);
	`RX_BUF1(u_wpx1h0, pxyz_fa_hi0 && (seq_R_hi0 == 5'd6),  we_pxyz_hi0[1]);
	`RX_BUF1(u_wpx1h1, pxyz_fa_hi0 && (seq_R_hi0 == 5'd6),  we_pxyz_hi1[1]);
	`RX_BUF1(u_wpx2l0, pxyz_fa_lo0 && (seq_R_lo0 == 5'd9),  we_pxyz_lo0[2]);
	`RX_BUF1(u_wpx2l1, pxyz_fa_lo0 && (seq_R_lo0 == 5'd9),  we_pxyz_lo1[2]);
	`RX_BUF1(u_wpx2h0, pxyz_fa_hi0 && (seq_R_hi0 == 5'd9),  we_pxyz_hi0[2]);
	`RX_BUF1(u_wpx2h1, pxyz_fa_hi0 && (seq_R_hi0 == 5'd9),  we_pxyz_hi1[2]);
	`RX_BUF1(u_wpx3l0, pxyz_fa_lo0 && (seq_R_lo0 == 5'd14), we_pxyz_lo0[3]);
	`RX_BUF1(u_wpx3l1, pxyz_fa_lo0 && (seq_R_lo0 == 5'd14), we_pxyz_lo1[3]);
	`RX_BUF1(u_wpx3h0, pxyz_fa_hi0 && (seq_R_hi0 == 5'd14), we_pxyz_hi0[3]);
	`RX_BUF1(u_wpx3h1, pxyz_fa_hi0 && (seq_R_hi0 == 5'd14), we_pxyz_hi1[3]);
	`RX_BUF1(u_wpx4l0, pxyz_fa_lo0 && (seq_R_lo0 == 5'd17), we_pxyz_lo0[4]);
	`RX_BUF1(u_wpx4l1, pxyz_fa_lo0 && (seq_R_lo0 == 5'd17), we_pxyz_lo1[4]);
	`RX_BUF1(u_wpx4h0, pxyz_fa_hi0 && (seq_R_hi0 == 5'd17), we_pxyz_hi0[4]);
	`RX_BUF1(u_wpx4h1, pxyz_fa_hi0 && (seq_R_hi0 == 5'd17), we_pxyz_hi1[4]);
	`RX_BUF1(u_wpx5l0, pxyz_fa_lo1 && (seq_R_lo1 == 5'd20), we_pxyz_lo0[5]);
	`RX_BUF1(u_wpx5l1, pxyz_fa_lo1 && (seq_R_lo1 == 5'd20), we_pxyz_lo1[5]);
	`RX_BUF1(u_wpx5h0, pxyz_fa_hi1 && (seq_R_hi1 == 5'd20), we_pxyz_hi0[5]);
	`RX_BUF1(u_wpx5h1, pxyz_fa_hi1 && (seq_R_hi1 == 5'd20), we_pxyz_hi1[5]);
	`RX_BUF1(u_wpx6l0, pxyz_fa_lo1 && (seq_R_lo1 == 5'd25), we_pxyz_lo0[6]);
	`RX_BUF1(u_wpx6l1, pxyz_fa_lo1 && (seq_R_lo1 == 5'd25), we_pxyz_lo1[6]);
	`RX_BUF1(u_wpx6h0, pxyz_fa_hi1 && (seq_R_hi1 == 5'd25), we_pxyz_hi0[6]);
	`RX_BUF1(u_wpx6h1, pxyz_fa_hi1 && (seq_R_hi1 == 5'd25), we_pxyz_hi1[6]);
	`RX_BUF1(u_wpx7l0, pxyz_fa_lo1 && (seq_R_lo1 == 5'd28), we_pxyz_lo0[7]);
	`RX_BUF1(u_wpx7l1, pxyz_fa_lo1 && (seq_R_lo1 == 5'd28), we_pxyz_lo1[7]);
	`RX_BUF1(u_wpx7h0, pxyz_fa_hi1 && (seq_R_hi1 == 5'd28), we_pxyz_hi0[7]);
	`RX_BUF1(u_wpx7h1, pxyz_fa_hi1 && (seq_R_hi1 == 5'd28), we_pxyz_hi1[7]);
	`RX_BUF1(u_wpx8l0, pxyz_fa_lo1 && (seq_R_lo1 == 5'd31), we_pxyz_lo0[8]);
	`RX_BUF1(u_wpx8l1, pxyz_fa_lo1 && (seq_R_lo1 == 5'd31), we_pxyz_lo1[8]);
	`RX_BUF1(u_wpx8h0, pxyz_fa_hi1 && (seq_R_hi1 == 5'd31), we_pxyz_hi0[8]);
	`RX_BUF1(u_wpx8h1, pxyz_fa_hi1 && (seq_R_hi1 == 5'd31), we_pxyz_hi1[8]);

	wire pxyz_fm_lo1 = rst_n_setup && (st_R_lo1 == S_PERSP_XYZ) && fm_o_R_lo;
	wire pxyz_fm_hi1 = rst_n_setup && (st_R_hi1 == S_PERSP_XYZ) && fm_o_R_hi;
	wire rect_fm_lo1 = rst_n_setup && (st_R_lo1 == S_RECT) && fm_o_R_lo;
	wire rect_fm_hi1 = rst_n_setup && (st_R_hi1 == S_RECT) && fm_o_R_hi;
	wire rect_fa_lo1 = rst_n_setup && (st_R_lo1 == S_RECT) && fa_o_R_lo;
	wire rect_fa_hi1 = rst_n_setup && (st_R_hi1 == S_RECT) && fa_o_R_hi;

	 wire we_r52_lo, we_r52_hi, we_r53_lo, we_r53_hi, we_r55_lo, we_r55_hi, we_r56_lo, we_r56_hi;
	 wire we_r54_fm_lo0, we_r54_fm_lo1, we_r54_fm_hi0, we_r54_fm_hi1;
	 wire we_r57_fm_lo0, we_r57_fm_lo1, we_r57_fm_hi0, we_r57_fm_hi1;
	 wire we_r76_lo, we_r76_hi, we_r77_lo, we_r77_hi, we_r78_lo, we_r78_hi, we_r79_lo, we_r79_hi;
	 wire we_r47_lo, we_r47_hi;

	`RX_BUF1(u_wr52l, pxyz_fm_lo1 && (seq_R_lo1 == 5'd10), we_r52_lo);
	`RX_BUF1(u_wr52h, pxyz_fm_hi1 && (seq_R_hi1 == 5'd10), we_r52_hi);
	`RX_BUF1(u_wr55l, pxyz_fm_lo1 && (seq_R_lo1 == 5'd11), we_r55_lo);
	`RX_BUF1(u_wr55h, pxyz_fm_hi1 && (seq_R_hi1 == 5'd11), we_r55_hi);
	`RX_BUF1(u_wr53l, pxyz_fm_lo1 && (seq_R_lo1 == 5'd21), we_r53_lo);
	`RX_BUF1(u_wr53h, pxyz_fm_hi1 && (seq_R_hi1 == 5'd21), we_r53_hi);
	`RX_BUF1(u_wr56l, pxyz_fm_lo1 && (seq_R_lo1 == 5'd22), we_r56_lo);
	`RX_BUF1(u_wr56h, pxyz_fm_hi1 && (seq_R_hi1 == 5'd22), we_r56_hi);

	`RX_BUF1(u_wr54l0, rect_fm_lo1 && (seq_R_lo1 == 5'd0), we_r54_fm_lo0);
	`RX_BUF1(u_wr54l1, rect_fm_lo1 && (seq_R_lo1 == 5'd0), we_r54_fm_lo1);
	`RX_BUF1(u_wr54h0, rect_fm_hi1 && (seq_R_hi1 == 5'd0), we_r54_fm_hi0);
	`RX_BUF1(u_wr54h1, rect_fm_hi1 && (seq_R_hi1 == 5'd0), we_r54_fm_hi1);
	`RX_BUF1(u_wr57l0, rect_fm_lo1 && (seq_R_lo1 == 5'd1), we_r57_fm_lo0);
	`RX_BUF1(u_wr57l1, rect_fm_lo1 && (seq_R_lo1 == 5'd1), we_r57_fm_lo1);
	`RX_BUF1(u_wr57h0, rect_fm_hi1 && (seq_R_hi1 == 5'd1), we_r57_fm_hi0);
	`RX_BUF1(u_wr57h1, rect_fm_hi1 && (seq_R_hi1 == 5'd1), we_r57_fm_hi1);

	`RX_BUF1(u_wr76l, rect_fa_lo1 && (seq_R_lo1 == 5'd2), we_r76_lo);
	`RX_BUF1(u_wr76h, rect_fa_hi1 && (seq_R_hi1 == 5'd2), we_r76_hi);
	`RX_BUF1(u_wr77l, rect_fa_lo1 && (seq_R_lo1 == 5'd3), we_r77_lo);
	`RX_BUF1(u_wr77h, rect_fa_hi1 && (seq_R_hi1 == 5'd3), we_r77_hi);
	`RX_BUF1(u_wr78l, rect_fa_lo1 && (seq_R_lo1 == 5'd4), we_r78_lo);
	`RX_BUF1(u_wr78h, rect_fa_hi1 && (seq_R_hi1 == 5'd4), we_r78_hi);
	`RX_BUF1(u_wr79l, rect_fa_lo1 && (seq_R_lo1 >= 5'd5), we_r79_lo);
	`RX_BUF1(u_wr79h, rect_fa_hi1 && (seq_R_hi1 >= 5'd5), we_r79_hi);

	`RX_BUF1(u_wr47l, rst_n_setup && (st_R_lo1 == S_PLANE_DIV) && (kind != 2'd0) && fd_o_plane_lo, we_r47_lo);
	`RX_BUF1(u_wr47h, rst_n_setup && (st_R_hi1 == S_PLANE_DIV) && (kind != 2'd0) && fd_o_plane_hi, we_r47_hi);

	always @(posedge clk) begin
		if (we_r28_lo) R_lo[28] <= fd_r[15:0];
		if (we_r29_lo) R_lo[29] <= fd_r[15:0];
		if (we_r30_pw_lo0) R_lo[30][7:0] <= fd_r[7:0];
		else if (we_ldup_r30_lo0) R_lo[30][7:0] <= R_lo[28][7:0];
		if (we_r30_pw_lo1) R_lo[30][15:8] <= fd_r[15:8];
		else if (we_ldup_r30_lo1) R_lo[30][15:8] <= R_lo[28][15:8];

		if (we_raw_r_lo0[0]) R_lo[31][7:0] <= in_tri_r31[7:0];
		else if (we_pxyz_lo0[0]) R_lo[31][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[0]) R_lo[31][15:8] <= in_tri_r31[15:8];
		else if (we_pxyz_lo1[0]) R_lo[31][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[1]) R_lo[32][7:0] <= in_tri_r31[39:32];
		else if (we_pxyz_lo0[1]) R_lo[32][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[1]) R_lo[32][15:8] <= in_tri_r31[47:40];
		else if (we_pxyz_lo1[1]) R_lo[32][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[2]) R_lo[33][7:0] <= in_tri_r31[71:64];
		else if (we_pxyz_lo0[2]) R_lo[33][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[2]) R_lo[33][15:8] <= in_tri_r31[79:72];
		else if (we_pxyz_lo1[2]) R_lo[33][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[3]) R_lo[34][7:0] <= in_tri_r31[135:128];
		else if (we_pxyz_lo0[3]) R_lo[34][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[3]) R_lo[34][15:8] <= in_tri_r31[143:136];
		else if (we_pxyz_lo1[3]) R_lo[34][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[4]) R_lo[35][7:0] <= in_tri_r31[167:160];
		else if (we_pxyz_lo0[4]) R_lo[35][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[4]) R_lo[35][15:8] <= in_tri_r31[175:168];
		else if (we_pxyz_lo1[4]) R_lo[35][15:8] <= fa_r_R[15:8];
	end

	always @(posedge clk) begin
		if (we_r28_hi) R_hi[28] <= fd_r[31:16];
		if (we_r29_hi) R_hi[29] <= fd_r[31:16];
		if (we_r30_pw_hi0) R_hi[30][7:0] <= fd_r[23:16];
		else if (we_ldup_r30_hi0) R_hi[30][7:0] <= R_hi[28][7:0];
		if (we_r30_pw_hi1) R_hi[30][15:8] <= fd_r[31:24];
		else if (we_ldup_r30_hi1) R_hi[30][15:8] <= R_hi[28][15:8];

		if (we_raw_r_hi0[0]) R_hi[31][7:0] <= in_tri_r31[23:16];
		else if (we_pxyz_hi0[0]) R_hi[31][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[0]) R_hi[31][15:8] <= in_tri_r31[31:24];
		else if (we_pxyz_hi1[0]) R_hi[31][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[1]) R_hi[32][7:0] <= in_tri_r31[55:48];
		else if (we_pxyz_hi0[1]) R_hi[32][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[1]) R_hi[32][15:8] <= in_tri_r31[63:56];
		else if (we_pxyz_hi1[1]) R_hi[32][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[2]) R_hi[33][7:0] <= in_tri_r31[87:80];
		else if (we_pxyz_hi0[2]) R_hi[33][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[2]) R_hi[33][15:8] <= in_tri_r31[95:88];
		else if (we_pxyz_hi1[2]) R_hi[33][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[3]) R_hi[34][7:0] <= in_tri_r31[151:144];
		else if (we_pxyz_hi0[3]) R_hi[34][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[3]) R_hi[34][15:8] <= in_tri_r31[159:152];
		else if (we_pxyz_hi1[3]) R_hi[34][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[4]) R_hi[35][7:0] <= in_tri_r31[183:176];
		else if (we_pxyz_hi0[4]) R_hi[35][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[4]) R_hi[35][15:8] <= in_tri_r31[191:184];
		else if (we_pxyz_hi1[4]) R_hi[35][15:8] <= fa_r_R[31:24];
	end

	/* 4. R_lo[36:39, 47, 52:57, 76:79] and R_hi[36:39, 47, 52:57, 76:79] */
	always @(posedge clk) begin
		if (we_raw_r_lo0[5]) R_lo[36][7:0] <= in_tri_r31[199:192];
		else if (we_pxyz_lo0[5]) R_lo[36][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[5]) R_lo[36][15:8] <= in_tri_r31[207:200];
		else if (we_pxyz_lo1[5]) R_lo[36][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[6]) R_lo[37][7:0] <= in_tri_r31[263:256];
		else if (we_pxyz_lo0[6]) R_lo[37][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[6]) R_lo[37][15:8] <= in_tri_r31[271:264];
		else if (we_pxyz_lo1[6]) R_lo[37][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[7]) R_lo[38][7:0] <= in_tri_r31[295:288];
		else if (we_pxyz_lo0[7]) R_lo[38][7:0] <= fa_r_R[7:0];
		if (we_raw_r_lo1[7]) R_lo[38][15:8] <= in_tri_r31[303:296];
		else if (we_pxyz_lo1[7]) R_lo[38][15:8] <= fa_r_R[15:8];

		if (we_raw_r_lo0[8]) R_lo[39][7:0] <= in_tri_r31[327:320];
		else if (we_pxyz_lo0[8]) R_lo[39][7:0] <= fa_r_R[7:0];
		else if (we_ldup_r39_lo0) R_lo[39][7:0] <= R_lo[33][7:0];
		if (we_raw_r_lo1[8]) R_lo[39][15:8] <= in_tri_r31[335:328];
		else if (we_pxyz_lo1[8]) R_lo[39][15:8] <= fa_r_R[15:8];
		else if (we_ldup_r39_lo1) R_lo[39][15:8] <= R_lo[33][15:8];

		if (we_r52_lo) R_lo[52] <= fm_r_R[15:0];
		if (we_r55_lo) R_lo[55] <= fm_r_R[15:0];
		if (we_r53_lo) R_lo[53] <= fm_r_R[15:0];
		if (we_r56_lo) R_lo[56] <= fm_r_R[15:0];

		if (we_ldup_r54_lo0) R_lo[54][7:0] <= R_lo[52][7:0];
		else if (we_r54_fm_lo0) R_lo[54][7:0] <= fm_r_R[7:0];
		if (we_ldup_r54_lo1) R_lo[54][15:8] <= R_lo[52][15:8];
		else if (we_r54_fm_lo1) R_lo[54][15:8] <= fm_r_R[15:8];

		if (we_ldup_r57_lo0) R_lo[57][7:0] <= R_lo[55][7:0];
		else if (we_r57_fm_lo0) R_lo[57][7:0] <= fm_r_R[7:0];
		if (we_ldup_r57_lo1) R_lo[57][15:8] <= R_lo[55][15:8];
		else if (we_r57_fm_lo1) R_lo[57][15:8] <= fm_r_R[15:8];

		if (we_r76_lo) R_lo[76] <= fa_r_R[15:0];
		if (we_r77_lo) R_lo[77] <= fa_r_R[15:0];
		if (we_r78_lo) R_lo[78] <= fa_r_R[15:0];
		if (we_r79_lo) R_lo[79] <= fa_r_R[15:0];
		if (we_r47_lo) R_lo[47] <= fd_r[15:0];
	end

	always @(posedge clk) begin
		if (we_raw_r_hi0[5]) R_hi[36][7:0] <= in_tri_r31[215:208];
		else if (we_pxyz_hi0[5]) R_hi[36][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[5]) R_hi[36][15:8] <= in_tri_r31[223:216];
		else if (we_pxyz_hi1[5]) R_hi[36][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[6]) R_hi[37][7:0] <= in_tri_r31[279:272];
		else if (we_pxyz_hi0[6]) R_hi[37][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[6]) R_hi[37][15:8] <= in_tri_r31[287:280];
		else if (we_pxyz_hi1[6]) R_hi[37][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[7]) R_hi[38][7:0] <= in_tri_r31[311:304];
		else if (we_pxyz_hi0[7]) R_hi[38][7:0] <= fa_r_R[23:16];
		if (we_raw_r_hi1[7]) R_hi[38][15:8] <= in_tri_r31[319:312];
		else if (we_pxyz_hi1[7]) R_hi[38][15:8] <= fa_r_R[31:24];

		if (we_raw_r_hi0[8]) R_hi[39][7:0] <= in_tri_r31[343:336];
		else if (we_pxyz_hi0[8]) R_hi[39][7:0] <= fa_r_R[23:16];
		else if (we_ldup_r39_hi0) R_hi[39][7:0] <= R_hi[33][7:0];
		if (we_raw_r_hi1[8]) R_hi[39][15:8] <= in_tri_r31[351:344];
		else if (we_pxyz_hi1[8]) R_hi[39][15:8] <= fa_r_R[31:24];
		else if (we_ldup_r39_hi1) R_hi[39][15:8] <= R_hi[33][15:8];

		if (we_r52_hi) R_hi[52] <= fm_r_R[31:16];
		if (we_r55_hi) R_hi[55] <= fm_r_R[31:16];
		if (we_r53_hi) R_hi[53] <= fm_r_R[31:16];
		if (we_r56_hi) R_hi[56] <= fm_r_R[31:16];

		if (we_ldup_r54_hi0) R_hi[54][7:0] <= R_hi[52][7:0];
		else if (we_r54_fm_hi0) R_hi[54][7:0] <= fm_r_R[23:16];
		if (we_ldup_r54_hi1) R_hi[54][15:8] <= R_hi[52][15:8];
		else if (we_r54_fm_hi1) R_hi[54][15:8] <= fm_r_R[31:24];

		if (we_ldup_r57_hi0) R_hi[57][7:0] <= R_hi[55][7:0];
		else if (we_r57_fm_hi0) R_hi[57][7:0] <= fm_r_R[23:16];
		if (we_ldup_r57_hi1) R_hi[57][15:8] <= R_hi[55][15:8];
		else if (we_r57_fm_hi1) R_hi[57][15:8] <= fm_r_R[31:24];

		if (we_r76_hi) R_hi[76] <= fa_r_R[31:16];
		if (we_r77_hi) R_hi[77] <= fa_r_R[31:16];
		if (we_r78_hi) R_hi[78] <= fa_r_R[31:16];
		if (we_r79_hi) R_hi[79] <= fa_r_R[31:16];
		if (we_r47_hi) R_hi[47] <= fd_r[31:16];
	end

	/* 5. Plane Registers pl_lo[0:11] and pl_hi[0:11] */
	wire pl_clr_cond = rst_setup_high || ((st_pl_lo == S_IDLE) && in_valid_pl);
	wire pl_point_cond = rst_n_setup && (st_pl_lo == S_EDGE) && e_done && !e_empty_buf && (kind == 2'd0);
	 wire [11:0] clr_pl_lo, clr_pl_hi, pt_pl_lo, pt_pl_hi;
	 wire we_pl8_div_lo, we_pl8_div_hi, we_pl11_div_lo, we_pl11_div_hi;
	`RX_BUF1(u_wpl8dl,  (st_pl_lo == S_PLANE_DIV) && (kind == 2'd0) && ((seq_pl_lo == 5'd1) || (seq_pl_lo == 5'd2)) && fa_o_pl_lo, we_pl8_div_lo);
	`RX_BUF1(u_wpl8dh,  (st_pl_hi == S_PLANE_DIV) && (kind == 2'd0) && ((seq_pl_hi == 5'd1) || (seq_pl_hi == 5'd2)) && fa_o_pl_hi, we_pl8_div_hi);
	`RX_BUF1(u_wpl11dl, (st_pl_lo == S_PLANE_DIV) && (kind == 2'd0) && (seq_pl_lo == 5'd4) && fa_o_pl_lo, we_pl11_div_lo);
	`RX_BUF1(u_wpl11dh, (st_pl_hi == S_PLANE_DIV) && (kind == 2'd0) && (seq_pl_hi == 5'd4) && fa_o_pl_hi, we_pl11_div_hi);
	genvar gpc;
	generate
		for (gpc = 0; gpc < 12; gpc = gpc + 1) begin : g_pl_ctrl_buf
			`RX_BUF1(u_cpl_l, pl_clr_cond,   clr_pl_lo[gpc]);
			`RX_BUF1(u_cpl_h, pl_clr_cond,   clr_pl_hi[gpc]);
			`RX_BUF1(u_ppl_l, pl_point_cond, pt_pl_lo[gpc]);
			`RX_BUF1(u_ppl_h, pl_point_cond, pt_pl_hi[gpc]);
		end
	endgenerate

	always @(posedge clk) begin
		if (clr_pl_lo[0] || pt_pl_lo[0]) pl_lo[0] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd6) && fm_o_pl_lo && (p_plane_pl_l == 2'd0)) pl_lo[0] <= fm_r_pl[15:0];

		if (clr_pl_lo[1] || pt_pl_lo[1]) pl_lo[1] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd10) && fm_o_pl_lo && (p_plane_pl_l == 2'd0)) pl_lo[1] <= fm_r_pl[15:0];

		if (clr_pl_lo[2]) pl_lo[2] <= 16'd0;
		else if (pt_pl_lo[2]) pl_lo[2] <= R_lo[33];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo >= 4'd14) && fa_o_pl_lo && (p_plane_pl_l == 2'd0)) pl_lo[2] <= fa_r_pl[15:0];
		else if ((st_pl_lo == S_BIAS) && (seq_pl_lo >= 5'd8) && fa_o_pl_lo) pl_lo[2] <= fa_r_pl[15:0];

		if (clr_pl_lo[3] || pt_pl_lo[3]) pl_lo[3] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd6) && fm_o_pl_lo && (p_plane_pl_l == 2'd1)) pl_lo[3] <= fm_r_pl[15:0];

		if (clr_pl_lo[4] || pt_pl_lo[4]) pl_lo[4] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd10) && fm_o_pl_lo && (p_plane_pl_l == 2'd1)) pl_lo[4] <= fm_r_pl[15:0];

		if (clr_pl_lo[5]) pl_lo[5] <= 16'd0;
		else if (pt_pl_lo[5]) pl_lo[5] <= ONE[15:0];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo >= 4'd14) && fa_o_pl_lo && (p_plane_pl_l == 2'd1)) pl_lo[5] <= fa_r_pl[15:0];

		if (clr_pl_lo[6]) pl_lo[6] <= 16'd0;
		else if (pt_pl_lo[6]) pl_lo[6] <= inv_ps[15:0];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd6) && fm_o_pl_lo && (p_plane_pl_l == 2'd2)) pl_lo[6] <= fm_r_pl[15:0];

		if (clr_pl_lo[7] || pt_pl_lo[7]) pl_lo[7] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd10) && fm_o_pl_lo && (p_plane_pl_l == 2'd2)) pl_lo[7] <= fm_r_pl[15:0];

		if (clr_pl_lo[8]) pl_lo[8] <= 16'd0;
		else if (we_pl8_div_lo) pl_lo[8] <= fa_r_pl[15:0];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo >= 4'd14) && fa_o_pl_lo && (p_plane_pl_l == 2'd2)) pl_lo[8] <= fa_r_pl[15:0];

		if (clr_pl_lo[9] || pt_pl_lo[9]) pl_lo[9] <= 16'd0;
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd6) && fm_o_pl_lo && (p_plane_pl_l == 2'd3)) pl_lo[9] <= fm_r_pl[15:0];

		if (clr_pl_lo[10]) pl_lo[10] <= 16'd0;
		else if (pt_pl_lo[10]) pl_lo[10] <= inv_ps[15:0];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo == 4'd10) && fm_o_pl_lo && (p_plane_pl_l == 2'd3)) pl_lo[10] <= fm_r_pl[15:0];

		if (clr_pl_lo[11]) pl_lo[11] <= 16'd0;
		else if (we_pl11_div_lo) pl_lo[11] <= fa_r_pl[15:0];
		else if ((st_pl_lo == S_PLANE) && (p_step_pl_lo >= 4'd14) && fa_o_pl_lo && (p_plane_pl_l == 2'd3)) pl_lo[11] <= fa_r_pl[15:0];
	end

	always @(posedge clk) begin
		if (clr_pl_hi[0] || pt_pl_hi[0]) pl_hi[0] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd6) && fm_o_pl_hi && (p_plane_pl_h == 2'd0)) pl_hi[0] <= fm_r_pl[31:16];

		if (clr_pl_hi[1] || pt_pl_hi[1]) pl_hi[1] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd10) && fm_o_pl_hi && (p_plane_pl_h == 2'd0)) pl_hi[1] <= fm_r_pl[31:16];

		if (clr_pl_hi[2]) pl_hi[2] <= 16'd0;
		else if (pt_pl_hi[2]) pl_hi[2] <= R_hi[33];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi >= 4'd14) && fa_o_pl_hi && (p_plane_pl_h == 2'd0)) pl_hi[2] <= fa_r_pl[31:16];
		else if ((st_pl_hi == S_BIAS) && (seq_pl_hi >= 5'd8) && fa_o_pl_hi) pl_hi[2] <= fa_r_pl[31:16];

		if (clr_pl_hi[3] || pt_pl_hi[3]) pl_hi[3] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd6) && fm_o_pl_hi && (p_plane_pl_h == 2'd1)) pl_hi[3] <= fm_r_pl[31:16];

		if (clr_pl_hi[4] || pt_pl_hi[4]) pl_hi[4] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd10) && fm_o_pl_hi && (p_plane_pl_h == 2'd1)) pl_hi[4] <= fm_r_pl[31:16];

		if (clr_pl_hi[5]) pl_hi[5] <= 16'd0;
		else if (pt_pl_hi[5]) pl_hi[5] <= ONE[31:16];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi >= 4'd14) && fa_o_pl_hi && (p_plane_pl_h == 2'd1)) pl_hi[5] <= fa_r_pl[31:16];

		if (clr_pl_hi[6]) pl_hi[6] <= 16'd0;
		else if (pt_pl_hi[6]) pl_hi[6] <= inv_ps[31:16];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd6) && fm_o_pl_hi && (p_plane_pl_h == 2'd2)) pl_hi[6] <= fm_r_pl[31:16];

		if (clr_pl_hi[7] || pt_pl_hi[7]) pl_hi[7] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd10) && fm_o_pl_hi && (p_plane_pl_h == 2'd2)) pl_hi[7] <= fm_r_pl[31:16];

		if (clr_pl_hi[8]) pl_hi[8] <= 16'd0;
		else if (we_pl8_div_hi) pl_hi[8] <= fa_r_pl[31:16];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi >= 4'd14) && fa_o_pl_hi && (p_plane_pl_h == 2'd2)) pl_hi[8] <= fa_r_pl[31:16];

		if (clr_pl_hi[9] || pt_pl_hi[9]) pl_hi[9] <= 16'd0;
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd6) && fm_o_pl_hi && (p_plane_pl_h == 2'd3)) pl_hi[9] <= fm_r_pl[31:16];

		if (clr_pl_hi[10]) pl_hi[10] <= 16'd0;
		else if (pt_pl_hi[10]) pl_hi[10] <= inv_ps[31:16];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi == 4'd10) && fm_o_pl_hi && (p_plane_pl_h == 2'd3)) pl_hi[10] <= fm_r_pl[31:16];

		if (clr_pl_hi[11]) pl_hi[11] <= 16'd0;
		else if (we_pl11_div_hi) pl_hi[11] <= fa_r_pl[31:16];
		else if ((st_pl_hi == S_PLANE) && (p_step_pl_hi >= 4'd14) && fa_o_pl_hi && (p_plane_pl_h == 2'd3)) pl_hi[11] <= fa_r_pl[31:16];
	end

	/* 6. Temporary Registers T0, T1, T2 */
	always @(posedge clk) begin
		if (rst_n_setup) begin
			if ((st_T_lo == S_PLANE) && (p_step_T_lo == 4'd1) && fa_o_pl_lo) T0_lo <= fa_r[15:0];
			else if ((st_T_lo == S_BIAS) && (seq_T_lo == 5'd2) && fm_o_pl_lo) T0_lo <= fm_r[15:0];

			if ((st_T_lo == S_PLANE) && (p_step_T_lo == 4'd2) && fa_o_pl_lo) T1_lo <= fa_r[15:0];

			if ((st_T_lo == S_PLANE) && ((p_step_T_lo == 4'd3) || (p_step_T_lo == 4'd7) || (p_step_T_lo == 4'd11)) && fm_o_pl_lo)
				T2_lo <= fm_r[15:0];
		end
	end

	always @(posedge clk) begin
		if (rst_n_setup) begin
			if ((st_T_hi == S_PLANE) && (p_step_T_hi == 4'd1) && fa_o_pl_hi) T0_hi <= fa_r[31:16];
			else if ((st_T_hi == S_BIAS) && (seq_T_hi == 5'd2) && fm_o_pl_hi) T0_hi <= fm_r[31:16];

			if ((st_T_hi == S_PLANE) && (p_step_T_hi == 4'd2) && fa_o_pl_hi) T1_hi <= fa_r[31:16];

			if ((st_T_hi == S_PLANE) && ((p_step_T_hi == 4'd3) || (p_step_T_hi == 4'd7) || (p_step_T_hi == 4'd11)) && fm_o_pl_hi)
				T2_hi <= fm_r[31:16];
		end
	end

	/* 7. Divider Operands fd_b_lo/hi (split into 8-bit halves so st_fdb_* fanout <= 16) */
	always @(posedge clk) begin
		if (rst_n_setup) begin
			case (st_fdb_lo0)
			S_IDLE:
				if (!in_raw && in_valid_fdb_lo) fd_b_lo[7:0] <= in_tri[103:96];
			S_PERSP_W:
				if (fd_o_fdb_lo) begin
					if (seq_fdb_lo == 5'd0) fd_b_lo[7:0] <= R_lo[7][7:0];
					else if (seq_fdb_lo == 5'd1) fd_b_lo[7:0] <= R_lo[11][7:0];
				end
			S_EDGE:
				fd_b_lo[7:0] <= R_lo[44][7:0];
			default: ;
			endcase

			case (st_fdb_lo1)
			S_IDLE:
				if (!in_raw && in_valid_fdb_lo) fd_b_lo[15:8] <= in_tri[111:104];
			S_PERSP_W:
				if (fd_o_fdb_lo) begin
					if (seq_fdb_lo == 5'd0) fd_b_lo[15:8] <= R_lo[7][15:8];
					else if (seq_fdb_lo == 5'd1) fd_b_lo[15:8] <= R_lo[11][15:8];
				end
			S_EDGE:
				fd_b_lo[15:8] <= R_lo[44][15:8];
			default: ;
			endcase
		end
	end

	always @(posedge clk) begin
		if (rst_n_setup) begin
			case (st_fdb_hi0)
			S_IDLE:
				if (!in_raw && in_valid_fdb_hi) fd_b_hi[7:0] <= in_tri[119:112];
			S_PERSP_W:
				if (fd_o_fdb_hi) begin
					if (seq_fdb_hi == 5'd0) fd_b_hi[7:0] <= R_hi[7][7:0];
					else if (seq_fdb_hi == 5'd1) fd_b_hi[7:0] <= R_hi[11][7:0];
				end
			S_EDGE:
				fd_b_hi[7:0] <= R_hi[44][7:0];
			default: ;
			endcase

			case (st_fdb_hi1)
			S_IDLE:
				if (!in_raw && in_valid_fdb_hi) fd_b_hi[15:8] <= in_tri[127:120];
			S_PERSP_W:
				if (fd_o_fdb_hi) begin
					if (seq_fdb_hi == 5'd0) fd_b_hi[15:8] <= R_hi[7][15:8];
					else if (seq_fdb_hi == 5'd1) fd_b_hi[15:8] <= R_hi[11][15:8];
				end
			S_EDGE:
				fd_b_hi[15:8] <= R_hi[44][15:8];
			default: ;
			endcase
		end
	end

	/* 8. Depth Bias Clamp Pipeline Registers (fanout <= 16 per enable buffer) */
	wire bias_s5_raw = rst_n_setup && (st_T_lo == S_BIAS) && (seq_T_lo == 5'd5) && fa_o_c_v;
	 wire we_bias_s5_lo, we_bias_s5_hi, we_bias_s5_flg;
	`RX_BUF1(u_wbs5_l, bias_s5_raw, we_bias_s5_lo);
	`RX_BUF1(u_wbs5_h, bias_s5_raw, we_bias_s5_hi);
	`RX_BUF1(u_wbs5_f, bias_s5_raw, we_bias_s5_flg);

	always @(posedge clk) begin
		if (we_bias_s5_lo)  r_bias_fa_lo <= fa_r[15:0];
		if (we_bias_s5_hi)  r_bias_fa_hi <= fa_r[31:16];
		if (we_bias_s5_flg) begin
			r_bcl_is_zero_lo <= bcl_is_zero;
			r_bcl_sign_lo <= b_clamp[31];
			r_bcl_mag_lt_lo <= bcl_mag_lt;
			r_bcl_mag_eq_lo <= (fa_r[30:0] == b_clamp[30:0]);
			r_fa_nan_lo <= ((fa_r[30:23] == 8'hFF) && (fa_r[22:0] != 23'd0)) || bcl_nan;
			r_fa_sign_lo <= fa_r[31];
			r_fa_is_zero_lo <= (fa_r[30:0] == 31'd0);

			r_bcl_is_zero_hi <= bcl_is_zero;
			r_bcl_sign_hi <= b_clamp[31];
			r_bcl_mag_lt_hi <= bcl_mag_lt;
			r_bcl_mag_eq_hi <= (fa_r[30:0] == b_clamp[30:0]);
			r_fa_nan_hi <= ((fa_r[30:23] == 8'hFF) && (fa_r[22:0] != 23'd0)) || bcl_nan;
			r_fa_sign_hi <= fa_r[31];
			r_fa_is_zero_hi <= (fa_r[30:0] == 31'd0);
		end
	end

	/* 9. Main Control FSM: Compute st_next, seq_next, p_step_next ONCE combinationally
	 * so replicating st_rep_*, seq_step_rep_*, p_step_rep_* does NOT duplicate next-state logic cones! */
	wire ps_ne_0100 = (point_size != 16'h0100);
	wire [4:0] seq_inc, seq_inc_hi;
	wire seq_inc_co_unused, seq_inc_hi_co_unused;
	am_add #(.W(5)) u_inc_seq (
		.a(seq_step_rep_b),
		.b(5'd1),
		.ci(1'b0),
		.s(seq_inc),
		.co(seq_inc_co_unused)
	);
	am_add #(.W(5)) u_inc_seq_hi (
		.a(seq_step_hi),
		.b(5'd1),
		.ci(1'b0),
		.s(seq_inc_hi),
		.co(seq_inc_hi_co_unused)
	);
	(* keep = "true" *) wire xyz_use_fa = (seq_step_rep_b == 5'd3 || seq_step_rep_b == 5'd6 || seq_step_rep_b == 5'd9 ||
		seq_step_rep_b == 5'd14 || seq_step_rep_b == 5'd17 || seq_step_rep_b == 5'd20 ||
		seq_step_rep_b == 5'd25 || seq_step_rep_b == 5'd28 || seq_step_rep_b == 5'd31);
	(* keep = "true" *) wire xyz_use_fa_hi = (seq_step_hi == 5'd3 || seq_step_hi == 5'd6 || seq_step_hi == 5'd9 ||
		seq_step_hi == 5'd14 || seq_step_hi == 5'd17 || seq_step_hi == 5'd20 ||
		seq_step_hi == 5'd25 || seq_step_hi == 5'd28 || seq_step_hi == 5'd31);

	(* keep = "true" *) reg [3:0] st_next;
	always @(*) begin
		st_next = st;
		if (rst_setup_high) begin
			st_next = S_IDLE;
		end else begin
			case (st)
			S_IDLE:
				if (we_idle_fsm) st_next = in_raw ? S_EDGE : S_PERSP_W;
			S_PERSP_W:
				if (fd_o_w && (seq_step_rep_a >= 5'd2)) st_next = S_PERSP_XYZ;
			S_PERSP_XYZ:
				if ((seq_step_rep_a == 5'd31) && fa_o_c_st) st_next = S_RECT;
			S_RECT:
				if ((seq_step_rep_a == 5'd1) && fm_o_c_st && !rm[3]) st_next = S_EDGE;
				else if ((seq_step_rep_a >= 5'd5) && fa_o_c_st) st_next = S_EDGE;
			S_EDGE:
				if (e_done) st_next = e_empty_buf ? S_OUT : S_PLANE_DIV;
			S_PLANE_DIV:
				if (kind == 2'd0) begin
					if ((seq_step_rep_a == 5'd4) && fa_o_c_st) st_next = S_OUT;
				end else if (fd_o_plane_ctrl) begin
					st_next = S_PLANE;
				end
			S_PLANE:
				if ((p_step_ctrl >= 4'd14) && fa_o_c_st) begin
					if (raw) st_next = S_OUT;
					else if (p_plane != 2'd3) st_next = S_PLANE;
					else if (kind == 2'd1) st_next = S_OUT;
					else if (rm[0] && (rm[5:4] != 2'd0)) st_next = S_BIAS;
					else st_next = S_OUT;
				end
			S_BIAS:
				if ((seq_step_rep_a >= 5'd8) && fa_o_c_st) st_next = S_OUT;
			S_OUT:
				if (sp_valid && sp_ready) st_next = more ? S_EDGE : S_IDLE;
			default: ;
			endcase
		end
	end

	(* keep = "true" *) reg [2:0] seq_next_lo;
	always @(*) begin
		seq_next_lo = seq_step[2:0];
		if (rst_setup_high) begin
			seq_next_lo = 3'd0;
		end else begin
			case (st_rep_d)
			S_IDLE:
				seq_next_lo = 3'd0;
			S_PERSP_W:
				if (fd_o_w) begin
					if (seq_step == 5'd0) seq_next_lo = 3'd1;
					else if (seq_step == 5'd1) seq_next_lo = 3'd2;
					else seq_next_lo = 3'd0;
				end
			S_PERSP_XYZ:
				if ((seq_step == 5'd0) || (xyz_use_fa ? fa_o_c_seq : fm_o_c_seq))
					seq_next_lo = seq_inc[2:0];
			S_RECT:
				case (seq_step)
				5'd0: if (fm_o_c_seq) seq_next_lo = 3'd1;
				5'd1: if (fm_o_c_seq && rm[3]) seq_next_lo = 3'd2;
				5'd2, 5'd3, 5'd4: if (fa_o_c_seq) seq_next_lo = seq_inc[2:0];
				default: ;
				endcase
			S_EDGE:
				if (e_done && !e_empty_buf) begin
					if ((kind == 2'd0) && !ps_ne_0100) seq_next_lo = 3'd2;
					else seq_next_lo = 3'd0;
				end
			S_PLANE_DIV:
				if (kind == 2'd0) begin
					case (seq_step)
					5'd0: if (fm_o_c_seq) seq_next_lo = 3'd1;
					5'd1: if (fa_o_c_seq) seq_next_lo = 3'd3;
					5'd2: if (fa_o_c_seq) seq_next_lo = 3'd4;
					5'd3: if (fm_o_c_seq) seq_next_lo = 3'd4;
					default: ;
					endcase
				end else if (fd_o_plane_ctrl) begin
					seq_next_lo = 3'd0;
				end
			S_BIAS:
				case (seq_step)
				5'd0, 5'd1, 5'd6, 5'd7: seq_next_lo = seq_inc[2:0];
				5'd2: if (fm_o_c_seq) seq_next_lo = (rm[5:4] == 2'd3) ? 3'd3 : 3'd4;
				5'd3: seq_next_lo = 3'd4;
				5'd4: if (fm_o_c_seq) seq_next_lo = 3'd5;
				5'd5: if (fa_o_c_seq) seq_next_lo = 3'd6;
				default: ;
				endcase
			default: ;
			endcase
		end
	end

	(* keep = "true" *) reg [4:3] seq_next_hi;
	always @(*) begin
		seq_next_hi = seq_step_hi[4:3];
		if (rst_setup_high) begin
			seq_next_hi = 2'd0;
		end else begin
			case (st_rep_f)
			S_IDLE:
				seq_next_hi = 2'd0;
			S_PERSP_W:
				if (fd_o_w) seq_next_hi = 2'd0;
			S_PERSP_XYZ:
				if ((seq_step_hi == 5'd0) || (xyz_use_fa_hi ? fa_o_c_ps : fm_o_c_ps))
					seq_next_hi = seq_inc_hi[4:3];
			S_RECT:
				case (seq_step_hi)
				5'd0: if (fm_o_c_ps) seq_next_hi = 2'd0;
				5'd1: if (fm_o_c_ps && rm[3]) seq_next_hi = 2'd0;
				5'd2, 5'd3, 5'd4: if (fa_o_c_ps) seq_next_hi = seq_inc_hi[4:3];
				default: ;
				endcase
			S_EDGE:
				if (e_done && !e_empty_buf) seq_next_hi = 2'd0;
			S_PLANE_DIV:
				if (kind == 2'd0) begin
					case (seq_step_hi)
					5'd0: if (fm_o_c_ps) seq_next_hi = 2'd0;
					5'd1: if (fa_o_c_ps) seq_next_hi = 2'd0;
					5'd2: if (fa_o_c_ps) seq_next_hi = 2'd0;
					5'd3: if (fm_o_c_ps) seq_next_hi = 2'd0;
					default: ;
					endcase
				end else if (fd_o_plane_ctrl) begin
					seq_next_hi = 2'd0;
				end
			S_BIAS:
				case (seq_step_hi)
				5'd0, 5'd1, 5'd6, 5'd7: seq_next_hi = seq_inc_hi[4:3];
				5'd2: if (fm_o_c_ps) seq_next_hi = 2'd0;
				5'd3: seq_next_hi = 2'd0;
				5'd4: if (fm_o_c_ps) seq_next_hi = 2'd0;
				5'd5: if (fa_o_c_ps) seq_next_hi = 2'd0;
				default: ;
				endcase
			default: ;
			endcase
		end
	end
	(* keep = "true" *) wire [4:0] seq_next = {seq_next_hi, seq_next_lo};

	wire [3:0] p_step_ctrl_inc;
	wire p_step_ctrl_inc_co_unused;
	am_add #(.W(4)) u_inc_p_step (
		.a(p_step_ctrl),
		.b(4'd1),
		.ci(1'b0),
		.s(p_step_ctrl_inc),
		.co(p_step_ctrl_inc_co_unused)
	);

	wire [1:0] p_plane_inc;
	wire p_plane_inc_co_unused;
	am_add #(.W(2)) u_inc_p_plane (
		.a(p_plane),
		.b(2'd1),
		.ci(1'b0),
		.s(p_plane_inc),
		.co(p_plane_inc_co_unused)
	);

	(* keep = "true" *) reg [3:0] p_step_next;
	always @(*) begin
		p_step_next = p_step_ctrl;
		if (rst_setup_high) begin
			p_step_next = 4'd0;
		end else begin
			case (st_rep_f)
			S_PLANE_DIV:
				if ((kind != 2'd0) && fd_o_plane_ctrl)
					p_step_next = 4'd0;
			S_PLANE:
				case (p_step_ctrl)
				4'd0: p_step_next = 4'd1;
				4'd1, 4'd2, 4'd5, 4'd9, 4'd13:
					if (fa_o_c_ps) p_step_next = p_step_ctrl_inc;
				4'd3, 4'd4, 4'd6, 4'd7, 4'd8, 4'd10, 4'd11, 4'd12:
					if (fm_o_c_ps) p_step_next = p_step_ctrl_inc;
				default:
					if (fa_o_c_ps) p_step_next = 4'd0;
				endcase
			default: ;
			endcase
		end
	end

	always @(posedge clk) begin
		st <= st_next;
		st_rep_a <= st_next;
		st_rep_b <= st_next;
		st_rep_c <= st_next;
		st_rep_d <= st_next;
		st_rep_e <= st_next;
		st_rep_f <= st_next;

		seq_step <= seq_next;
		seq_step_hi <= seq_next;
		seq_step_v <= seq_next;
		seq_step_rep_a <= seq_next;
		seq_step_rep_b <= seq_next;
		seq_step_rep_c <= seq_next;
		seq_step_rep_d <= seq_next;

		p_step <= p_step_next;
		p_step_rep_a <= p_step_next;

		fa_v <= 1'b0;
		fm_v <= 1'b0;
		fd_v <= 1'b0;
		e_start <= 1'b0;

		if (rst_setup_high) begin
			sp_valid <= 1'b0;
			more <= 1'b0;
			sub <= 1'b0;
			fa_sub <= 1'b0;
			p_plane <= 2'd0;
			ea_in <= 8'd0;
		end else case (st_rep_e)
		S_IDLE:
			if (we_idle_fsm) begin
				sub <= 1'b0;
				more <= 1'b0;
				if (in_raw) e_start <= 1'b1;
				else fd_v <= 1'b1;
			end

		S_PERSP_W:
			if (fd_o_w && ((seq_step_v == 5'd0) || (seq_step_v == 5'd1)))
				fd_v <= 1'b1;

		S_PERSP_XYZ:
			case (seq_step_v)
			5'd0: fm_v <= 1'b1;
			5'd1, 5'd4, 5'd7, 5'd10, 5'd11, 5'd12, 5'd15, 5'd18, 5'd21, 5'd22, 5'd23, 5'd26, 5'd29:
				if (fm_o_c_v) fm_v <= 1'b1;
			5'd2, 5'd5, 5'd8, 5'd13, 5'd16, 5'd19, 5'd24, 5'd27, 5'd30:
				if (fm_o_c_v) begin
					fa_v <= 1'b1;
					fa_sub <= 1'b0;
				end
			default:
				if (fa_o_c_v) fm_v <= 1'b1;
			endcase

		S_RECT:
			case (seq_step_v)
			5'd0: if (fm_o_c_v) fm_v <= 1'b1;
			5'd1: if (fm_o_c_v) begin
				if (!rm[3]) e_start <= 1'b1;
				else begin
					fa_v <= 1'b1;
					fa_sub <= 1'b1;
				end
			end
			5'd2, 5'd4: if (fa_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b0;
			end
			5'd3: if (fa_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
			end
			default: if (fa_o_c_v) e_start <= 1'b1;
			endcase

		S_EDGE:
			if (e_done && !e_empty_buf) begin
				if (kind == 2'd0) begin
					if (ps_ne_0100) fm_v <= 1'b1;
					else begin
						fa_v <= 1'b1;
						fa_sub <= 1'b0;
					end
				end else begin
					fd_v <= 1'b1;
				end
			end

		S_PLANE_DIV:
			if (kind == 2'd0) begin
				case (seq_step_v)
				5'd0, 5'd3: if (fm_o_c_v) begin
					fa_v <= 1'b1;
					fa_sub <= 1'b0;
				end
				5'd1: if (fa_o_c_v) fm_v <= 1'b1;
				5'd2: if (fa_o_c_v) begin
					fa_v <= 1'b1;
					fa_sub <= 1'b0;
				end
				5'd4: if (fa_o_c_v) more <= !sub;
				default: ;
				endcase
			end else if (fd_o_plane_ctrl) begin
				p_plane <= 2'd0;
			end

		S_PLANE:
			case (p_step_ctrl)
			4'd0: begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
			end
			4'd1: if (fa_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
			end
			4'd2, 4'd5, 4'd9: if (fa_o_c_v) fm_v <= 1'b1;
			4'd3, 4'd6, 4'd7, 4'd10, 4'd11: if (fm_o_c_v) fm_v <= 1'b1;
			4'd4, 4'd8: if (fm_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b1;
			end
			4'd12: if (fm_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b0;
			end
			4'd13: if (fa_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b0;
			end
			default: if (fa_o_c_v) begin
				if (!raw && (p_plane != 2'd3)) p_plane <= p_plane_inc;
				else if (!raw && (kind == 2'd1)) more <= !sub;
			end
			endcase

		S_BIAS:
			case (seq_step_v)
			5'd1, 5'd3: fm_v <= 1'b1;
			5'd2: if (fm_o_c_v) begin
				if (rm[5:4] == 2'd3) ea_in <= max_z[30:23];
				else fm_v <= 1'b1;
			end
			5'd4: if (fm_o_c_v) begin
				fa_v <= 1'b1;
				fa_sub <= 1'b0;
			end
			5'd7: begin
				fa_v <= 1'b1;
				fa_sub <= 1'b0;
			end
			default: ;
			endcase

		S_OUT: begin
			sp_valid <= 1'b1;
			if (sp_valid && sp_ready) begin
				sp_valid <= 1'b0;
				if (more) begin
					more <= 1'b0;
					sub <= 1'b1;
					e_start <= 1'b1;
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
	assign sp_tri[767:736] = {1'b0, kind_out, raw, e_front, more ? 3'd0 : keep[26:24], keep[23:0]};

	wire unused_ok = &{1'b0, fd_busy, rm[2:1], su_bo_unused, max_z[31], max_z[22:0],
		lw_fix[23:16], ps_fix[23:16], div_busy, mesh_id, in_valid_ctrl, in_valid_fd,
		seq_inc_co_unused, seq_inc_hi_co_unused, p_step_ctrl_inc_co_unused, p_plane_inc_co_unused,
		is_flw, is_fps};

`undef RX_BUF1
endmodule

`default_nettype wire
