/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_foot: one lane's footprint (stage B of atg_tu_addr,
 * tools/tumodel.py lane_addr is the reference, bit for bit).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register
 * - LAT = 3: 3 cycle pipeline registers (Stage 0A, Stage 0B, Stage 1A)
 * - LAT = 4: 4 cycle pipeline registers:
 *            Stage 0A: texel coordinates & offsets (i0, j0, i1, j1, ki, zd, xd, yd)
 *            Stage 0B: wrap, cube face mapping & footprint slots
 *            Stage 1A: multipliers (u_kp, u_fs, u_m)
 *            Stage 1B: tile offsets (u_s1, u_sh, to) and base adders (u_a1)
 *            Stage 2:  final address adders (u_a2, u_a)
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_foot #(
	parameter LAT = 2
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [1:0] op,	/* 0 texl, 1 texb, 2 texf, 3 texsz */
	input wire gather,
	input wire cube,
	input wire is3d,
	input wire tiled,
	input wire lin,
	input wire ms,
	input wire [1:0] smp,	/* multisample: the sample (texf) */
	input wire [2:0] psl,	/* log2 of the texel's bytes */
	input wire [1:0] ra,	/* log2 of a row's texel multiple (TEX_ROW) */
	input wire blk,		/* compressed 4 x 4 blocks */
	input wire row,		/* 8-byte texels, 16-byte blocks: pass's row */
	input wire col,		/* 16-byte blocks: pass's column */
	input wire [1:0] gwi,	/* gather: the word of the texel */
	input wire p0,		/* 3D linear: pass's second slice */
	input wire [31:0] x,	/* coordinates for texf (signed 32-bit integer) */
	input wire [31:0] y,
	input wire [31:0] z,
	input wire [11:0] off,	/* texel offsets (signed 4-bit integer): {dw, dv, du} */
	input wire signed [30:0] cu,	/* normalized (8 fraction bits, floor) or unnorm */
	input wire signed [30:0] cv,
	input wire signed [30:0] cw,
	input wire [15:0] wl,	/* the level's size (at least 1) */
	input wire [15:0] hl,
	input wire [15:0] dl,
	input wire [1:0] mu,	/* address modes (ghci_regs.vh) */
	input wire [1:0] mv,
	input wire [1:0] mw,
	input wire [2:0] face,	/* cube: the lane's face (0-5) */
	input wire [31:0] stride,	/* layer stride (cube: face stride) */
	input wire [31:0] lbase,	/* the level's base address in bytes */
	input wire [31:0] plane,	/* a 3D level's plane in bytes */
	output wire [127:0] addr,	/* four slots of 32 bits */
	output wire [3:0] bord,	/* border texels */
	output wire [15:0] fuv,	/* {fv, fu} */
	output wire [7:0] fw
);

	wire rst_inv = !rst_n;

	wire off_u_s_lo = off[3];
	wire off_u_s_hi = off[3];
	wire off_v_s_lo = off[7];
	wire off_v_s_hi = off[7];
	wire off_w_s_lo = off[11];
	wire off_w_s_hi = off[11];
	wire signed [23:0] du_w = {{12{off_u_s_hi}}, {8{off_u_s_lo}}, off[3:0]};
	wire signed [23:0] dv_w = {{12{off_v_s_hi}}, {8{off_v_s_lo}}, off[7:4]};
	wire signed [23:0] dw_w = {{12{off_w_s_hi}}, {8{off_w_s_lo}}, off[11:8]};
	wire texf = op == 2'd2;
	/* The slice. */
	wire dlin = is3d && lin && !gather;
	wire [13:0] carry_unused;	/* the adders' carries */
	wire signed [23:0] ki;
	wire signed [32:0] zd, xd, yd;

	wire [4:0] dw_m1_5, du_m1_5, dv_m1_5;
	am_sub #(.W(5)) u_dw_m1 (.a({off[11], off[11:8]}), .b(5'd1), .bi(1'b0), .d(dw_m1_5), .bo(carry_unused[0]));
	am_sub #(.W(5)) u_du_m1 (.a({off[3],  off[3:0]}),  .b(5'd1), .bi(1'b0), .d(du_m1_5), .bo(carry_unused[3]));
	am_sub #(.W(5)) u_dv_m1 (.a({off[7],  off[7:4]}),  .b(5'd1), .bi(1'b0), .d(dv_m1_5), .bo(carry_unused[4]));
	wire du_m1_s_lo = du_m1_5[4];
	wire du_m1_s_hi = du_m1_5[4];
	wire dv_m1_s_lo = dv_m1_5[4];
	wire dv_m1_s_hi = dv_m1_5[4];
	wire dw_m1_s_lo = dw_m1_5[4];
	wire dw_m1_s_hi = dw_m1_5[4];
	wire signed [23:0] du_m1_w = {{12{du_m1_s_hi}}, {7{du_m1_s_lo}}, du_m1_5};
	wire signed [23:0] dv_m1_w = {{12{dv_m1_s_hi}}, {7{dv_m1_s_lo}}, dv_m1_5};
	wire signed [23:0] dw_m1_w = {{12{dw_m1_s_hi}}, {7{dw_m1_s_lo}}, dw_m1_5};

	/* Pre-register steady texel offsets when LAT >= 2 so Stage 0A adders see <= 1 Pre-LUT */
	reg signed [23:0] r_du, r_dv, r_dw;
	reg signed [23:0] r_du_m1, r_dv_m1, r_dw_m1;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_du    <= 24'sd0;
			r_dv    <= 24'sd0;
			r_dw    <= 24'sd0;
			r_du_m1 <= 24'sd0;
			r_dv_m1 <= 24'sd0;
			r_dw_m1 <= 24'sd0;
		end else if (en) begin
			r_du    <= du_w;
			r_dv    <= dv_w;
			r_dw    <= dw_w;
			r_du_m1 <= du_m1_w;
			r_dv_m1 <= dv_m1_w;
			r_dw_m1 <= dw_m1_w;
		end
	end

	wire signed [23:0] du    = (LAT >= 2) ? r_du    : du_w;
	wire signed [23:0] dv    = (LAT >= 2) ? r_dv    : dv_w;
	wire signed [23:0] dw    = (LAT >= 2) ? r_dw    : dw_w;
	wire signed [23:0] du_m1 = (LAT >= 2) ? r_du_m1 : du_m1_w;
	wire signed [23:0] dv_m1 = (LAT >= 2) ? r_dv_m1 : dv_m1_w;
	wire signed [23:0] dw_m1 = (LAT >= 2) ? r_dw_m1 : dw_m1_w;

	wire dw_sel_lo = (dlin && !cw[7]);
	wire dw_sel_hi = (dlin && !cw[7]);
	wire signed [23:0] dw_adj = {dw_sel_hi ? dw_m1[23:12] : dw[23:12], dw_sel_lo ? dw_m1[11:0] : dw[11:0]};

	wire signed [23:0] cw_int = {cw[30], cw[30:8]};
	wire [7:0] s0_fw = dlin ? {cw[7] ^ 1'b1, cw[6:0]} : 8'd0;

	/* The footprint coordinates. */
	wire signed [23:0] cu_int = {cu[30], cu[30:8]};
	wire signed [23:0] cv_int = {cv[30], cv[30:8]};

	wire du_sel_lo = (lin && !cu[7]);
	wire du_sel_hi = (lin && !cu[7]);
	wire dv_sel_lo = (lin && !cv[7]);
	wire dv_sel_hi = (lin && !cv[7]);
	wire signed [23:0] du_adj = {du_sel_hi ? du_m1[23:12] : du[23:12], du_sel_lo ? du_m1[11:0] : du[11:0]};
	wire signed [23:0] dv_adj = {dv_sel_hi ? dv_m1[23:12] : dv[23:12], dv_sel_lo ? dv_m1[11:0] : dv[11:0]};

	wire [7:0] cu2_lo = {cu[7] ^ lin, cu[6:0]};
	wire [7:0] cv2_lo = {cv[7] ^ lin, cv[6:0]};
	wire [15:0] s0_fuv = {cv2_lo, cu2_lo};

	/* Pre-adder pipeline registers (when LAT >= 5, capturing in LA2D so Stage 0A adders see 0 Pre-LUTs) */
	reg signed [23:0] r_pre_cw_int, r_pre_cu_int_i0, r_pre_cu_int_i1, r_pre_cv_int_j0, r_pre_cv_int_j1;
	reg signed [23:0] r_pre_dw_adj, r_pre_du_adj, r_pre_dv_adj;
	reg               r_pre_ki_ci, r_pre_i1_ci, r_pre_j1_ci;
	reg [15:0]        r_pre_fuv;
	reg [7:0]         r_pre_fw;
	always @(posedge clk) begin
		if (rst_inv) begin
			r_pre_cw_int    <= 24'sd0;
			r_pre_cu_int_i0 <= 24'sd0;
			r_pre_cu_int_i1 <= 24'sd0;
			r_pre_cv_int_j0 <= 24'sd0;
			r_pre_cv_int_j1 <= 24'sd0;
			r_pre_dw_adj    <= 24'sd0;
			r_pre_du_adj    <= 24'sd0;
			r_pre_dv_adj    <= 24'sd0;
			r_pre_ki_ci     <= 1'b0;
			r_pre_i1_ci     <= 1'b0;
			r_pre_j1_ci     <= 1'b0;
			r_pre_fuv       <= 16'd0;
			r_pre_fw        <= 8'd0;
		end else if (en) begin
			r_pre_cw_int    <= cw_int;
			r_pre_cu_int_i0 <= cu_int;
			r_pre_cu_int_i1 <= cu_int;
			r_pre_cv_int_j0 <= cv_int;
			r_pre_cv_int_j1 <= cv_int;
			r_pre_dw_adj    <= dw_adj;
			r_pre_du_adj    <= du_adj;
			r_pre_dv_adj    <= dv_adj;
			r_pre_ki_ci     <= dlin && p0;
			r_pre_i1_ci     <= lin && cu[7];
			r_pre_j1_ci     <= lin && cv[7];
			r_pre_fuv       <= s0_fuv;
			r_pre_fw        <= s0_fw;
		end
	end

	wire signed [23:0] a_cw_int    = (LAT >= 5) ? r_pre_cw_int    : cw_int;
	wire signed [23:0] a_cu_int_i0 = (LAT >= 5) ? r_pre_cu_int_i0 : cu_int;
	wire signed [23:0] a_cu_int_i1 = (LAT >= 5) ? r_pre_cu_int_i1 : cu_int;
	wire signed [23:0] a_cv_int_j0 = (LAT >= 5) ? r_pre_cv_int_j0 : cv_int;
	wire signed [23:0] a_cv_int_j1 = (LAT >= 5) ? r_pre_cv_int_j1 : cv_int;
	wire signed [23:0] a_dw_adj    = (LAT >= 5) ? r_pre_dw_adj    : dw_adj;
	wire signed [23:0] a_du_adj    = (LAT >= 5) ? r_pre_du_adj    : du_adj;
	wire signed [23:0] a_dv_adj    = (LAT >= 5) ? r_pre_dv_adj    : dv_adj;
	wire               a_ki_ci     = (LAT >= 5) ? r_pre_ki_ci     : (dlin && p0);
	wire               a_i1_ci     = (LAT >= 5) ? r_pre_i1_ci     : (lin && cu[7]);
	wire               a_j1_ci     = (LAT >= 5) ? r_pre_j1_ci     : (lin && cv[7]);
	wire [15:0]        a_fuv       = (LAT >= 5) ? r_pre_fuv       : s0_fuv;
	wire [7:0]         a_fw        = (LAT >= 5) ? r_pre_fw        : s0_fw;

	am_add #(.W(24)) u_ki (.a(a_cw_int), .b(a_dw_adj), .ci(a_ki_ci), .s(ki),
		.co(carry_unused[1]));
	wire dw_s_ext = dw[23];
	am_add #(.W(33)) u_zd (.a({z[31], z}), .b({{9{dw_s_ext}}, dw}), .ci(1'b0), .s(zd),
		.co(carry_unused[2]));

	wire signed [23:0] i0, j0, i1, j1;
	am_add #(.W(24)) u_i0 (.a(a_cu_int_i0), .b(a_du_adj), .ci(1'b0), .s(i0),
		.co(carry_unused[5]));
	am_add #(.W(24)) u_j0 (.a(a_cv_int_j0), .b(a_dv_adj), .ci(1'b0), .s(j0),
		.co(carry_unused[6]));
	am_add #(.W(24)) u_i1 (.a(a_cu_int_i1), .b(du), .ci(a_i1_ci), .s(i1),
		.co(carry_unused[7]));
	am_add #(.W(24)) u_j1 (.a(a_cv_int_j1), .b(dv), .ci(a_j1_ci), .s(j1),
		.co(carry_unused[8]));

	wire du_s_ext = du[23];
	wire dv_s_ext = dv[23];
	am_add #(.W(33)) u_xd (.a({x[31], x}), .b({{9{du_s_ext}}, du}), .ci(1'b0), .s(xd),
		.co(carry_unused[9]));
	am_add #(.W(33)) u_yd (.a({y[31], y}), .b({{9{dv_s_ext}}, dv}), .ci(1'b0), .s(yd),
		.co(carry_unused[10]));

	/* ========================================================================= */
	/* Stage 0A -> Stage 0B Pipeline Registers (when LAT >= 2)                   */
	/* ========================================================================= */
	reg signed [23:0] rA_i0_wi, rA_i0_c00, rA_i0_c01, rA_i0_ci;
	reg signed [23:0] rA_i1_wi, rA_i1_c10, rA_i1_c11;
	reg signed [23:0] rA_j0_wj, rA_j0_c00, rA_j0_c10, rA_j0_cj;
	reg signed [23:0] rA_j1_wj, rA_j1_c01, rA_j1_c11;
	reg signed [23:0] rA_ki;
	reg signed [32:0] rA_zd, rA_xd, rA_yd;
	reg [15:0] rA_fuv;
	reg [7:0]  rA_fw;
	reg [15:0] rA_wl_wi0, rA_wl_wi1, rA_wl_fi, rA_wl_c00, rA_wl_c10, rA_wl_c01, rA_wl_c11, rA_wl_ci, rA_wl_cj, rA_wl_misc;
	reg [15:0] rA_hl_wj0, rA_hl_wj1, rA_hl_fj;
	reg [15:0] rA_dl_kw, rA_dl_kf;
	reg [1:0]  rA_mu_0, rA_mu_1, rA_mv_0, rA_mv_1, rA_mw;
	reg [2:0]  rA_face_0, rA_face_1, rA_face_2, rA_face_3, rA_face;
	reg [31:0] rA_stride, rA_lbase, rA_plane;
	reg [1:0]  rA_op;
	reg        rA_gather, rA_cube, rA_is3d, rA_tiled, rA_lin, rA_ms;
	reg [1:0]  rA_smp;
	reg [2:0]  rA_psl;
	reg [1:0]  rA_ra;
	reg        rA_blk, rA_row, rA_col;
	reg [1:0]  rA_gwi;

	always @(posedge clk) begin
		if (rst_inv) begin
			rA_i0_wi <= 24'sd0; rA_i0_c00 <= 24'sd0; rA_i0_c01 <= 24'sd0; rA_i0_ci <= 24'sd0;
			rA_i1_wi <= 24'sd0; rA_i1_c10 <= 24'sd0; rA_i1_c11 <= 24'sd0;
			rA_j0_wj <= 24'sd0; rA_j0_c00 <= 24'sd0; rA_j0_c10 <= 24'sd0; rA_j0_cj <= 24'sd0;
			rA_j1_wj <= 24'sd0; rA_j1_c01 <= 24'sd0; rA_j1_c11 <= 24'sd0;
			rA_ki <= 24'sd0;
			rA_zd <= 33'sd0; rA_xd <= 33'sd0; rA_yd <= 33'sd0;
			rA_fuv <= 16'd0; rA_fw <= 8'd0;
			rA_wl_wi0 <= 16'd0; rA_wl_wi1 <= 16'd0; rA_wl_fi <= 16'd0;
			rA_wl_c00 <= 16'd0; rA_wl_c10 <= 16'd0; rA_wl_c01 <= 16'd0; rA_wl_c11 <= 16'd0;
			rA_wl_ci <= 16'd0; rA_wl_cj <= 16'd0; rA_wl_misc <= 16'd0;
			rA_hl_wj0 <= 16'd0; rA_hl_wj1 <= 16'd0; rA_hl_fj <= 16'd0;
			rA_dl_kw <= 16'd0; rA_dl_kf <= 16'd0;
			rA_mu_0 <= 2'd0; rA_mu_1 <= 2'd0; rA_mv_0 <= 2'd0; rA_mv_1 <= 2'd0; rA_mw <= 2'd0;
			rA_face_0 <= 3'd0; rA_face_1 <= 3'd0; rA_face_2 <= 3'd0; rA_face_3 <= 3'd0; rA_face <= 3'd0;
			rA_stride <= 32'd0; rA_lbase <= 32'd0; rA_plane <= 32'd0;
			rA_op <= 2'd0; rA_gather <= 1'b0; rA_cube <= 1'b0; rA_is3d <= 1'b0;
			rA_tiled <= 1'b0; rA_lin <= 1'b0; rA_ms <= 1'b0;
			rA_smp <= 2'd0; rA_psl <= 3'd0; rA_ra <= 2'd0;
			rA_blk <= 1'b0; rA_row <= 1'b0; rA_col <= 1'b0; rA_gwi <= 2'd0;
		end else if (en) begin
			rA_i0_wi <= i0; rA_i0_c00 <= i0; rA_i0_c01 <= i0; rA_i0_ci <= i0;
			rA_i1_wi <= i1; rA_i1_c10 <= i1; rA_i1_c11 <= i1;
			rA_j0_wj <= j0; rA_j0_c00 <= j0; rA_j0_c10 <= j0; rA_j0_cj <= j0;
			rA_j1_wj <= j1; rA_j1_c01 <= j1; rA_j1_c11 <= j1;
			rA_ki <= ki;
			rA_zd <= zd; rA_xd <= xd; rA_yd <= yd;
			rA_fuv <= a_fuv; rA_fw <= a_fw;
			rA_wl_wi0 <= wl; rA_wl_wi1 <= wl; rA_wl_fi <= wl;
			rA_wl_c00 <= wl; rA_wl_c10 <= wl; rA_wl_c01 <= wl; rA_wl_c11 <= wl;
			rA_wl_ci <= wl; rA_wl_cj <= wl; rA_wl_misc <= wl;
			rA_hl_wj0 <= hl; rA_hl_wj1 <= hl; rA_hl_fj <= hl;
			rA_dl_kw <= dl; rA_dl_kf <= dl;
			rA_mu_0 <= mu; rA_mu_1 <= mu; rA_mv_0 <= mv; rA_mv_1 <= mv; rA_mw <= mw;
			rA_face_0 <= face; rA_face_1 <= face; rA_face_2 <= face; rA_face_3 <= face; rA_face <= face;
			rA_stride <= stride; rA_lbase <= lbase; rA_plane <= plane;
			rA_op <= op; rA_gather <= gather; rA_cube <= cube; rA_is3d <= is3d;
			rA_tiled <= tiled; rA_lin <= lin; rA_ms <= ms;
			rA_smp <= smp; rA_psl <= psl; rA_ra <= ra;
			rA_blk <= blk; rA_row <= row; rA_col <= col; rA_gwi <= gwi;
		end
	end

	wire signed [23:0] inB_i0_wi  = (LAT >= 2) ? rA_i0_wi  : i0;
	wire signed [23:0] inB_i0_c00 = (LAT >= 2) ? rA_i0_c00 : i0;
	wire signed [23:0] inB_i0_c01 = (LAT >= 2) ? rA_i0_c01 : i0;
	wire signed [23:0] inB_i0_ci  = (LAT >= 2) ? rA_i0_ci  : i0;
	wire signed [23:0] inB_i1_wi  = (LAT >= 2) ? rA_i1_wi  : i1;
	wire signed [23:0] inB_i1_c10 = (LAT >= 2) ? rA_i1_c10 : i1;
	wire signed [23:0] inB_i1_c11 = (LAT >= 2) ? rA_i1_c11 : i1;
	wire signed [23:0] inB_j0_wj  = (LAT >= 2) ? rA_j0_wj  : j0;
	wire signed [23:0] inB_j0_c00 = (LAT >= 2) ? rA_j0_c00 : j0;
	wire signed [23:0] inB_j0_c10 = (LAT >= 2) ? rA_j0_c10 : j0;
	wire signed [23:0] inB_j0_cj  = (LAT >= 2) ? rA_j0_cj  : j0;
	wire signed [23:0] inB_j1_wj  = (LAT >= 2) ? rA_j1_wj  : j1;
	wire signed [23:0] inB_j1_c01 = (LAT >= 2) ? rA_j1_c01 : j1;
	wire signed [23:0] inB_j1_c11 = (LAT >= 2) ? rA_j1_c11 : j1;
	wire signed [23:0] inB_ki     = (LAT >= 2) ? rA_ki     : ki;
	wire signed [32:0] inB_zd     = (LAT >= 2) ? rA_zd     : zd;
	wire signed [32:0] inB_xd     = (LAT >= 2) ? rA_xd     : xd;
	wire signed [32:0] inB_yd     = (LAT >= 2) ? rA_yd     : yd;
	wire [15:0] inB_fuv           = (LAT >= 2) ? rA_fuv    : s0_fuv;
	wire [7:0]  inB_fw            = (LAT >= 2) ? rA_fw     : s0_fw;
	wire [15:0] inB_wl_wi0        = (LAT >= 2) ? rA_wl_wi0 : wl;
	wire [15:0] inB_wl_wi1        = (LAT >= 2) ? rA_wl_wi1 : wl;
	wire [15:0] inB_wl_fi         = (LAT >= 2) ? rA_wl_fi  : wl;
	wire [15:0] inB_wl_c00        = (LAT >= 2) ? rA_wl_c00 : wl;
	wire [15:0] inB_wl_c10        = (LAT >= 2) ? rA_wl_c10 : wl;
	wire [15:0] inB_wl_c01        = (LAT >= 2) ? rA_wl_c01 : wl;
	wire [15:0] inB_wl_c11        = (LAT >= 2) ? rA_wl_c11 : wl;
	wire [15:0] inB_wl_ci         = (LAT >= 2) ? rA_wl_ci  : wl;
	wire [15:0] inB_wl_cj         = (LAT >= 2) ? rA_wl_cj  : wl;
	wire [15:0] inB_wl            = (LAT >= 2) ? rA_wl_misc : wl;
	wire [15:0] inB_hl_wj0        = (LAT >= 2) ? rA_hl_wj0 : hl;
	wire [15:0] inB_hl_wj1        = (LAT >= 2) ? rA_hl_wj1 : hl;
	wire [15:0] inB_hl_fj         = (LAT >= 2) ? rA_hl_fj  : hl;
	wire [15:0] inB_dl_kw         = (LAT >= 2) ? rA_dl_kw  : dl;
	wire [15:0] inB_dl_kf         = (LAT >= 2) ? rA_dl_kf  : dl;
	wire [1:0]  inB_mu_0          = (LAT >= 2) ? rA_mu_0   : mu;
	wire [1:0]  inB_mu_1          = (LAT >= 2) ? rA_mu_1   : mu;
	wire [1:0]  inB_mv_0          = (LAT >= 2) ? rA_mv_0   : mv;
	wire [1:0]  inB_mv_1          = (LAT >= 2) ? rA_mv_1   : mv;
	wire [1:0]  inB_mw            = (LAT >= 2) ? rA_mw     : mw;
	wire [2:0]  inB_face_0        = (LAT >= 2) ? rA_face_0 : face;
	wire [2:0]  inB_face_1        = (LAT >= 2) ? rA_face_1 : face;
	wire [2:0]  inB_face_2        = (LAT >= 2) ? rA_face_2 : face;
	wire [2:0]  inB_face_3        = (LAT >= 2) ? rA_face_3 : face;
	wire [2:0]  inB_face          = (LAT >= 2) ? rA_face   : face;
	wire [31:0] inB_stride        = (LAT >= 2) ? rA_stride : stride;
	wire [31:0] inB_lbase         = (LAT >= 2) ? rA_lbase  : lbase;
	wire [31:0] inB_plane         = (LAT >= 2) ? rA_plane  : plane;
	wire [1:0]  inB_op            = (LAT >= 2) ? rA_op     : op;
	wire        inB_gather        = (LAT >= 2) ? rA_gather : gather;
	wire        inB_cube          = (LAT >= 2) ? rA_cube   : cube;
	wire        inB_is3d          = (LAT >= 2) ? rA_is3d   : is3d;
	wire        inB_tiled         = (LAT >= 2) ? rA_tiled  : tiled;
	wire        inB_lin           = (LAT >= 2) ? rA_lin    : lin;
	wire        inB_ms            = (LAT >= 2) ? rA_ms     : ms;
	wire [1:0]  inB_smp           = (LAT >= 2) ? rA_smp    : smp;
	wire [2:0]  inB_psl           = (LAT >= 2) ? rA_psl    : psl;
	wire [1:0]  inB_ra            = (LAT >= 2) ? rA_ra     : ra;
	wire        inB_blk           = (LAT >= 2) ? rA_blk    : blk;
	wire        inB_row           = (LAT >= 2) ? rA_row    : row;
	wire        inB_col           = (LAT >= 2) ? rA_col    : col;
	wire [1:0]  inB_gwi           = (LAT >= 2) ? rA_gwi    : gwi;

	/* ========================================================================= */
	/* Stage 0B: Wrap, cube face mapping & footprint evaluation                  */
	/* ========================================================================= */
	localparam W_LAT = (LAT >= 5) ? 1 : 0;

	wire [16:0] kw;
	wire [15:0] kf;
	atg_tu_wrap   #(.LAT(W_LAT)) u_kw (.clk(clk), .rst_n(rst_n), .en(en), .i(inB_ki), .n(inB_dl_kw), .mode(inB_mw), .w(kw));
	atg_tu_iclamp #(.LAT(W_LAT)) u_kf (.clk(clk), .rst_n(rst_n), .en(en), .v(inB_zd), .n(inB_dl_kf), .c(kf));

	wire [16:0] wi0, wi1, wj0, wj1;
	atg_tu_wrap #(.LAT(W_LAT)) u_wi0 (.clk(clk), .rst_n(rst_n), .en(en), .i(inB_i0_wi), .n(inB_wl_wi0), .mode(inB_mu_0), .w(wi0));
	atg_tu_wrap #(.LAT(W_LAT)) u_wi1 (.clk(clk), .rst_n(rst_n), .en(en), .i(inB_i1_wi), .n(inB_wl_wi1), .mode(inB_mu_1), .w(wi1));
	atg_tu_wrap #(.LAT(W_LAT)) u_wj0 (.clk(clk), .rst_n(rst_n), .en(en), .i(inB_j0_wj), .n(inB_hl_wj0), .mode(inB_mv_0), .w(wj0));
	atg_tu_wrap #(.LAT(W_LAT)) u_wj1 (.clk(clk), .rst_n(rst_n), .en(en), .i(inB_j1_wj), .n(inB_hl_wj1), .mode(inB_mv_1), .w(wj1));

	wire [15:0] fi, fj;
	atg_tu_iclamp #(.LAT(W_LAT)) u_fi (.clk(clk), .rst_n(rst_n), .en(en), .v(inB_xd), .n(inB_wl_fi), .c(fi));
	atg_tu_iclamp #(.LAT(W_LAT)) u_fj (.clk(clk), .rst_n(rst_n), .en(en), .v(inB_yd), .n(inB_hl_fj), .c(fj));

`ifdef MUT_TU_MSROW
	wire [15:0] wms_s0 = {inB_wl[13:0], 2'b00};
`else
	wire [12:0] wl2;
	am_add #(.W(13)) u_wl2 (.a(inB_wl[13:1]), .b(13'd0), .ci(inB_wl[0]), .s(wl2), .co(carry_unused[11]));
	wire [15:0] wms_s0 = {wl2, 3'b000};
`endif

	wire [16:0] rm = inB_ra == 2'd0 ? 17'd0 : inB_ra == 2'd1 ? 17'd1 : inB_ra == 2'd2 ? 17'd3 : 17'd7;
	wire [16:0] wrm;
	am_add #(.W(17)) u_wrm (.a({1'b0, inB_wl}), .b(rm), .ci(1'b0), .s(wrm), .co(carry_unused[12]));
`ifdef MUT_TU_PITCH
	wire [16:0] wr_s0 = {1'b0, inB_wl} | (rm & 17'd0);
	wire unused_wrm = &{1'b0, wrm};
`else
	wire [16:0] wr_s0 = wrm & ~rm;
`endif

	wire [34:0] c00l, c10, c01, c11;
	wire [15:0] ci0, cj0;
	atg_tu_cube_texel #(.LAT(W_LAT)) u_c00 (.clk(clk), .rst_n(rst_n), .en(en), .tface(inB_face_0), .i(inB_i0_c00), .j(inB_j0_c00), .n(inB_wl_c00), .t(c00l));
	atg_tu_cube_texel #(.LAT(W_LAT)) u_c10 (.clk(clk), .rst_n(rst_n), .en(en), .tface(inB_face_1), .i(inB_i1_c10), .j(inB_j0_c10), .n(inB_wl_c10), .t(c10));
	atg_tu_cube_texel #(.LAT(W_LAT)) u_c01 (.clk(clk), .rst_n(rst_n), .en(en), .tface(inB_face_2), .i(inB_i0_c01), .j(inB_j1_c01), .n(inB_wl_c01), .t(c01));
	atg_tu_cube_texel #(.LAT(W_LAT)) u_c11 (.clk(clk), .rst_n(rst_n), .en(en), .tface(inB_face_3), .i(inB_i1_c11), .j(inB_j1_c11), .n(inB_wl_c11), .t(c11));
	atg_tu_iclamp #(.LAT(W_LAT)) u_ci0 (.clk(clk), .rst_n(rst_n), .en(en), .v({{9{inB_i0_ci[23]}}, inB_i0_ci}), .n(inB_wl_ci), .c(ci0));
	atg_tu_iclamp #(.LAT(W_LAT)) u_cj0 (.clk(clk), .rst_n(rst_n), .en(en), .v({{9{inB_j0_cj[23]}}, inB_j0_cj}), .n(inB_wl_cj), .c(cj0));

	/* Stage 0B1 -> Stage 0B2 Pipeline Registers (when LAT >= 5, matching W_LAT = 1) */
	reg [15:0] rB1_wms;
	reg [16:0] rB1_wr;
	reg [15:0] rB1_fuv;
	reg [7:0]  rB1_fw;
	reg [2:0]  rB1_face;
	reg [31:0] rB1_stride, rB1_lbase, rB1_plane;
	reg [1:0]  rB1_op;
	reg        rB1_gather, rB1_cube, rB1_is3d, rB1_tiled, rB1_lin, rB1_ms;
	reg [1:0]  rB1_smp;
	reg [2:0]  rB1_psl;
	reg        rB1_blk, rB1_row, rB1_col;
	reg [1:0]  rB1_gwi;
	always @(posedge clk) begin
		if (rst_inv) begin
			rB1_wms    <= 16'd0;
			rB1_wr     <= 17'd0;
			rB1_fuv    <= 16'd0;
			rB1_fw     <= 8'd0;
			rB1_face   <= 3'd0;
			rB1_stride <= 32'd0;
			rB1_lbase  <= 32'd0;
			rB1_plane  <= 32'd0;
			rB1_op     <= 2'd0;
			rB1_gather <= 1'b0;
			rB1_cube   <= 1'b0;
			rB1_is3d   <= 1'b0;
			rB1_tiled  <= 1'b0;
			rB1_lin    <= 1'b0;
			rB1_ms     <= 1'b0;
			rB1_smp    <= 2'd0;
			rB1_psl    <= 3'd0;
			rB1_blk    <= 1'b0;
			rB1_row    <= 1'b0;
			rB1_col    <= 1'b0;
			rB1_gwi    <= 2'd0;
		end else if (en) begin
			rB1_wms    <= wms_s0;
			rB1_wr     <= wr_s0;
			rB1_fuv    <= inB_fuv;
			rB1_fw     <= inB_fw;
			rB1_face   <= inB_face;
			rB1_stride <= inB_stride;
			rB1_lbase  <= inB_lbase;
			rB1_plane  <= inB_plane;
			rB1_op     <= inB_op;
			rB1_gather <= inB_gather;
			rB1_cube   <= inB_cube;
			rB1_is3d   <= inB_is3d;
			rB1_tiled  <= inB_tiled;
			rB1_lin    <= inB_lin;
			rB1_ms     <= inB_ms;
			rB1_smp    <= inB_smp;
			rB1_psl    <= inB_psl;
			rB1_blk    <= inB_blk;
			rB1_row    <= inB_row;
			rB1_col    <= inB_col;
			rB1_gwi    <= inB_gwi;
		end
	end

	wire [15:0] b1_wms    = (LAT >= 5) ? rB1_wms    : wms_s0;
	wire [16:0] b1_wr     = (LAT >= 5) ? rB1_wr     : wr_s0;
	wire [15:0] b1_fuv    = (LAT >= 5) ? rB1_fuv    : inB_fuv;
	wire [7:0]  b1_fw     = (LAT >= 5) ? rB1_fw     : inB_fw;
	wire [2:0]  b1_face   = (LAT >= 5) ? rB1_face   : inB_face;
	wire [31:0] b1_stride = (LAT >= 5) ? rB1_stride : inB_stride;
	wire [31:0] b1_lbase  = (LAT >= 5) ? rB1_lbase  : inB_lbase;
	wire [31:0] b1_plane  = (LAT >= 5) ? rB1_plane  : inB_plane;
	wire [1:0]  b1_op     = (LAT >= 5) ? rB1_op     : inB_op;
	wire        b1_gather = (LAT >= 5) ? rB1_gather : inB_gather;
	wire        b1_cube   = (LAT >= 5) ? rB1_cube   : inB_cube;
	wire        b1_is3d   = (LAT >= 5) ? rB1_is3d   : inB_is3d;
	wire        b1_tiled  = (LAT >= 5) ? rB1_tiled  : inB_tiled;
	wire        b1_lin    = (LAT >= 5) ? rB1_lin    : inB_lin;
	wire        b1_ms     = (LAT >= 5) ? rB1_ms     : inB_ms;
	wire [1:0]  b1_smp    = (LAT >= 5) ? rB1_smp    : inB_smp;
	wire [2:0]  b1_psl    = (LAT >= 5) ? rB1_psl    : inB_psl;
	wire        b1_blk    = (LAT >= 5) ? rB1_blk    : inB_blk;
	wire        b1_row    = (LAT >= 5) ? rB1_row    : inB_row;
	wire        b1_col    = (LAT >= 5) ? rB1_col    : inB_col;
	wire [1:0]  b1_gwi    = (LAT >= 5) ? rB1_gwi    : inB_gwi;

	wire b1_texf_w = (b1_op == 2'd2);
	wire b1_msf_w  = b1_ms && (b1_op == 2'd2);
	wire [1:0] b1_ft0 [0:3];
	wire [1:0] b1_pt0 [0:3];
	genvar gfb1;
	generate
	for (gfb1 = 0; gfb1 < 4; gfb1 = gfb1 + 1) begin : g_b1_ft
		localparam [1:0] TB1 = gfb1;
`ifdef MUT_TU_ROW
		assign b1_ft0[gfb1] = (b1_gather && !b1_blk) || b1_psl <= 3'd2 ? TB1 : b1_psl == 3'd3 ? {1'b0, TB1[1]} : {1'b0, b1_col};
`else
		assign b1_ft0[gfb1] = (b1_gather && !b1_blk) || b1_psl <= 3'd2 ? TB1 : b1_psl == 3'd3 ? {b1_row, TB1[1]} : {b1_row, b1_col};
`endif
		assign b1_pt0[gfb1] = b1_gather && !b1_blk ? b1_gwi : b1_psl == 3'd3 ? {1'b0, TB1[0]} : b1_psl == 3'd4 ? TB1 : 2'd0;
	end
	endgenerate

	/* Stage 0B2 -> Stage 0B3 Pipeline Registers (when LAT >= 5, registering pure-LUT outputs of wrap/iclamp/cube_edge) */
	reg [16:0] rB2_kw, rB2_wi0, rB2_wi1, rB2_wj0, rB2_wj1;
	reg [15:0] rB2_kf, rB2_fi, rB2_fj, rB2_ci0, rB2_cj0;
	reg [34:0] rB2_c00l, rB2_c10, rB2_c01, rB2_c11;
	reg [15:0] rB2_wms;
	reg [16:0] rB2_wr;
	reg [15:0] rB2_fuv;
	reg [7:0]  rB2_fw;
	reg [2:0]  rB2_face;
	reg [31:0] rB2_stride, rB2_lbase, rB2_plane;
	reg [1:0]  rB2_op;
	reg        rB2_gather, rB2_cube, rB2_is3d, rB2_tiled, rB2_lin, rB2_ms, rB2_msf_wr_lo, rB2_msf_wr_hi, rB2_msf_tw;
	reg [1:0]  rB2_smp;
	reg [2:0]  rB2_psl;
	reg        rB2_blk, rB2_row, rB2_col;
	reg [1:0]  rB2_gwi;
	reg        rB2_texf_i [0:3], rB2_texf_j [0:3], rB2_texf_f [0:3];
	reg        rB2_msf_i [0:3];
	reg        rB2_cube_i [0:3], rB2_cube_j [0:3], rB2_cube_f [0:3];
	reg        rB2_lin_c00_i [0:3], rB2_lin_c00_j [0:3], rB2_lin_f [0:3];
	reg [1:0]  rB2_ft0_ct_i_lo [0:3], rB2_ft0_ct_i_hi [0:3], rB2_ft0_ct_j_lo [0:3], rB2_ft0_ct_j_hi [0:3], rB2_ft0_ti [0:3], rB2_ft0_f [0:3], rB2_pt0 [0:3];
	integer kb2;
	always @(posedge clk) begin
		if (rst_inv) begin
			rB2_kw     <= 17'd0;
			rB2_wi0    <= 17'd0;
			rB2_wi1    <= 17'd0;
			rB2_wj0    <= 17'd0;
			rB2_wj1    <= 17'd0;
			rB2_kf     <= 16'd0;
			rB2_fi     <= 16'd0;
			rB2_fj     <= 16'd0;
			rB2_ci0    <= 16'd0;
			rB2_cj0    <= 16'd0;
			rB2_c00l   <= 35'd0;
			rB2_c10    <= 35'd0;
			rB2_c01    <= 35'd0;
			rB2_c11    <= 35'd0;
			rB2_wms    <= 16'd0;
			rB2_wr     <= 17'd0;
			rB2_fuv    <= 16'd0;
			rB2_fw     <= 8'd0;
			rB2_face   <= 3'd0;
			rB2_stride <= 32'd0;
			rB2_lbase  <= 32'd0;
			rB2_plane  <= 32'd0;
			rB2_op     <= 2'd0;
			rB2_gather <= 1'b0;
			rB2_cube   <= 1'b0;
			rB2_is3d   <= 1'b0;
			rB2_tiled  <= 1'b0;
			rB2_lin    <= 1'b0;
			rB2_ms     <= 1'b0;
			rB2_msf_wr_lo <= 1'b0;
			rB2_msf_wr_hi <= 1'b0;
			rB2_msf_tw    <= 1'b0;
			rB2_smp    <= 2'd0;
			rB2_psl    <= 3'd0;
			rB2_blk    <= 1'b0;
			rB2_row    <= 1'b0;
			rB2_col    <= 1'b0;
			rB2_gwi    <= 2'd0;
			for (kb2 = 0; kb2 < 4; kb2 = kb2 + 1) begin
				rB2_texf_i[kb2]      <= 1'b0;
				rB2_texf_j[kb2]      <= 1'b0;
				rB2_texf_f[kb2]      <= 1'b0;
				rB2_msf_i[kb2]       <= 1'b0;
				rB2_cube_i[kb2]      <= 1'b0;
				rB2_cube_j[kb2]      <= 1'b0;
				rB2_cube_f[kb2]      <= 1'b0;
				rB2_lin_c00_i[kb2]   <= 1'b0;
				rB2_lin_c00_j[kb2]   <= 1'b0;
				rB2_lin_f[kb2]       <= 1'b0;
				rB2_ft0_ct_i_lo[kb2] <= 2'd0;
				rB2_ft0_ct_i_hi[kb2] <= 2'd0;
				rB2_ft0_ct_j_lo[kb2] <= 2'd0;
				rB2_ft0_ct_j_hi[kb2] <= 2'd0;
				rB2_ft0_ti[kb2]      <= 2'd0;
				rB2_ft0_f[kb2]       <= 2'd0;
				rB2_pt0[kb2]         <= 2'd0;
			end
		end else if (en) begin
			rB2_kw     <= kw;
			rB2_wi0    <= wi0;
			rB2_wi1    <= wi1;
			rB2_wj0    <= wj0;
			rB2_wj1    <= wj1;
			rB2_kf     <= kf;
			rB2_fi     <= fi;
			rB2_fj     <= fj;
			rB2_ci0    <= ci0;
			rB2_cj0    <= cj0;
			rB2_c00l   <= c00l;
			rB2_c10    <= c10;
			rB2_c01    <= c01;
			rB2_c11    <= c11;
			rB2_wms    <= b1_wms;
			rB2_wr     <= b1_wr;
			rB2_fuv    <= b1_fuv;
			rB2_fw     <= b1_fw;
			rB2_face   <= b1_face;
			rB2_stride <= b1_stride;
			rB2_lbase  <= b1_lbase;
			rB2_plane  <= b1_plane;
			rB2_op     <= b1_op;
			rB2_gather <= b1_gather;
			rB2_cube   <= b1_cube;
			rB2_is3d   <= b1_is3d;
			rB2_tiled  <= b1_tiled;
			rB2_lin    <= b1_lin;
			rB2_ms     <= b1_ms;
			rB2_msf_wr_lo <= b1_msf_w;
			rB2_msf_wr_hi <= b1_msf_w;
			rB2_msf_tw    <= b1_msf_w;
			rB2_smp    <= b1_smp;
			rB2_psl    <= b1_psl;
			rB2_blk    <= b1_blk;
			rB2_row    <= b1_row;
			rB2_col    <= b1_col;
			rB2_gwi    <= b1_gwi;
			for (kb2 = 0; kb2 < 4; kb2 = kb2 + 1) begin
				rB2_texf_i[kb2]      <= b1_texf_w;
				rB2_texf_j[kb2]      <= b1_texf_w;
				rB2_texf_f[kb2]      <= b1_texf_w;
				rB2_msf_i[kb2]       <= b1_msf_w;
				rB2_cube_i[kb2]      <= b1_cube;
				rB2_cube_j[kb2]      <= b1_cube;
				rB2_cube_f[kb2]      <= b1_cube;
				rB2_lin_c00_i[kb2]   <= b1_lin;
				rB2_lin_c00_j[kb2]   <= b1_lin;
				rB2_lin_f[kb2]       <= b1_lin;
				rB2_ft0_ct_i_lo[kb2] <= b1_lin ? b1_ft0[kb2] : 2'd0;
				rB2_ft0_ct_i_hi[kb2] <= b1_lin ? b1_ft0[kb2] : 2'd0;
				rB2_ft0_ct_j_lo[kb2] <= b1_lin ? b1_ft0[kb2] : 2'd0;
				rB2_ft0_ct_j_hi[kb2] <= b1_lin ? b1_ft0[kb2] : 2'd0;
				rB2_ft0_ti[kb2]      <= b1_ft0[kb2];
				rB2_ft0_f[kb2]       <= b1_ft0[kb2];
				rB2_pt0[kb2]         <= b1_pt0[kb2];
			end
		end
	end

	wire [16:0] sB_kw     = (LAT >= 5) ? rB2_kw     : kw;
	wire [16:0] sB_wi0    = (LAT >= 5) ? rB2_wi0    : wi0;
	wire [16:0] sB_wi1    = (LAT >= 5) ? rB2_wi1    : wi1;
	wire [16:0] sB_wj0    = (LAT >= 5) ? rB2_wj0    : wj0;
	wire [16:0] sB_wj1    = (LAT >= 5) ? rB2_wj1    : wj1;
	wire [15:0] sB_kf     = (LAT >= 5) ? rB2_kf     : kf;
	wire [15:0] sB_fi     = (LAT >= 5) ? rB2_fi     : fi;
	wire [15:0] sB_fj     = (LAT >= 5) ? rB2_fj     : fj;
	wire [15:0] sB_ci0    = (LAT >= 5) ? rB2_ci0    : ci0;
	wire [15:0] sB_cj0    = (LAT >= 5) ? rB2_cj0    : cj0;
	wire [34:0] sB_c00l   = (LAT >= 5) ? rB2_c00l   : c00l;
	wire [34:0] sB_c10    = (LAT >= 5) ? rB2_c10    : c10;
	wire [34:0] sB_c01    = (LAT >= 5) ? rB2_c01    : c01;
	wire [34:0] sB_c11    = (LAT >= 5) ? rB2_c11    : c11;
	wire [15:0] sB_wms    = (LAT >= 5) ? rB2_wms    : b1_wms;
	wire [16:0] sB_wr     = (LAT >= 5) ? rB2_wr     : b1_wr;
	wire [15:0] sB_fuv    = (LAT >= 5) ? rB2_fuv    : b1_fuv;
	wire [7:0]  sB_fw     = (LAT >= 5) ? rB2_fw     : b1_fw;
	wire [2:0]  sB_face   = (LAT >= 5) ? rB2_face   : b1_face;
	wire [31:0] sB_stride = (LAT >= 5) ? rB2_stride : b1_stride;
	wire [31:0] sB_lbase  = (LAT >= 5) ? rB2_lbase  : b1_lbase;
	wire [31:0] sB_plane  = (LAT >= 5) ? rB2_plane  : b1_plane;
	wire [1:0]  sB_op     = (LAT >= 5) ? rB2_op     : b1_op;
	wire        sB_gather = (LAT >= 5) ? rB2_gather : b1_gather;
	wire        sB_cube   = (LAT >= 5) ? rB2_cube   : b1_cube;
	wire        sB_is3d   = (LAT >= 5) ? rB2_is3d   : b1_is3d;
	wire        sB_tiled  = (LAT >= 5) ? rB2_tiled  : b1_tiled;
	wire        sB_lin    = (LAT >= 5) ? rB2_lin    : b1_lin;
	wire        sB_ms     = (LAT >= 5) ? rB2_ms     : b1_ms;
	wire [1:0]  sB_smp    = (LAT >= 5) ? rB2_smp    : b1_smp;
	wire [2:0]  sB_psl    = (LAT >= 5) ? rB2_psl    : b1_psl;
	wire        sB_blk    = (LAT >= 5) ? rB2_blk    : b1_blk;
	wire        sB_row    = (LAT >= 5) ? rB2_row    : b1_row;
	wire        sB_col    = (LAT >= 5) ? rB2_col    : b1_col;
	wire [1:0]  sB_gwi    = (LAT >= 5) ? rB2_gwi    : b1_gwi;

	wire sB_texf = sB_op == 2'd2;
	wire sB_msf_wr_lo = (LAT >= 5) ? rB2_msf_wr_lo : (sB_ms && sB_texf);
	wire sB_msf_wr_hi = (LAT >= 5) ? rB2_msf_wr_hi : (sB_ms && sB_texf);
	wire sB_msf_tw    = (LAT >= 5) ? rB2_msf_tw    : (sB_ms && sB_texf);
	wire [15:0] s0_k = !sB_is3d ? 16'd0 : sB_texf ? sB_kf : sB_kw[15:0];
	wire s0_bk = sB_is3d && !sB_texf && sB_kw[16];
	wire [15:0] fim = {sB_fi[13:0], sB_smp};

	wire [15:0] ti_s0 [0:3];
	wire [15:0] tj_s0 [0:3];
	wire [2:0]  tf_s0 [0:3];
	wire [1:0]  part_s0 [0:3];
	wire        tb_s0 [0:3];

	genvar gt0;
	generate
	for (gt0 = 0; gt0 < 4; gt0 = gt0 + 1) begin : g_slot0
		localparam [1:0] T0 = gt0;
`ifdef MUT_TU_ROW
		wire [1:0] ft0_raw = (sB_gather && !sB_blk) || sB_psl <= 3'd2 ? T0 : sB_psl == 3'd3 ? {1'b0, T0[1]} : {1'b0, sB_col};
`else
		wire [1:0] ft0_raw = (sB_gather && !sB_blk) || sB_psl <= 3'd2 ? T0 : sB_psl == 3'd3 ? {sB_row, T0[1]} : {sB_row, sB_col};
`endif
		wire [1:0] pt0_raw = sB_gather && !sB_blk ? sB_gwi : sB_psl == 3'd3 ? {1'b0, T0[0]} : sB_psl == 3'd4 ? T0 : 2'd0;
		wire texf_i    = (LAT >= 5) ? rB2_texf_i[gt0]    : (sB_op == 2'd2);
		wire texf_j    = (LAT >= 5) ? rB2_texf_j[gt0]    : (sB_op == 2'd2);
		wire texf_f    = (LAT >= 5) ? rB2_texf_f[gt0]    : (sB_op == 2'd2);
		wire msf_i     = (LAT >= 5) ? rB2_msf_i[gt0]     : (sB_ms && (sB_op == 2'd2));
		wire cube_i    = (LAT >= 5) ? rB2_cube_i[gt0]    : sB_cube;
		wire cube_j    = (LAT >= 5) ? rB2_cube_j[gt0]    : sB_cube;
		wire cube_f    = (LAT >= 5) ? rB2_cube_f[gt0]    : sB_cube;
		wire lin_c00_i = (LAT >= 5) ? rB2_lin_c00_i[gt0] : sB_lin;
		wire lin_c00_j = (LAT >= 5) ? rB2_lin_c00_j[gt0] : sB_lin;
		wire lin_f     = (LAT >= 5) ? rB2_lin_f[gt0]     : sB_lin;
		wire [1:0] ft0_ct_i_lo = (LAT >= 5) ? rB2_ft0_ct_i_lo[gt0] : (sB_lin ? ft0_raw : 2'd0);
		wire [1:0] ft0_ct_i_hi = (LAT >= 5) ? rB2_ft0_ct_i_hi[gt0] : (sB_lin ? ft0_raw : 2'd0);
		wire [1:0] ft0_ct_j_lo = (LAT >= 5) ? rB2_ft0_ct_j_lo[gt0] : (sB_lin ? ft0_raw : 2'd0);
		wire [1:0] ft0_ct_j_hi = (LAT >= 5) ? rB2_ft0_ct_j_hi[gt0] : (sB_lin ? ft0_raw : 2'd0);
		wire [1:0] ft0_ti   = (LAT >= 5) ? rB2_ft0_ti[gt0]   : ft0_raw;
		wire [1:0] ft0_f    = (LAT >= 5) ? rB2_ft0_f[gt0]    : ft0_raw;
		wire [1:0] pt0      = (LAT >= 5) ? rB2_pt0[gt0]      : pt0_raw;

		wire [15:0] c00_i = lin_c00_i ? sB_c00l[31:16] : sB_ci0;
		wire [15:0] c00_j = lin_c00_j ? sB_c00l[15:0]  : sB_cj0;
		wire [2:0]  c00_f = lin_f ? sB_c00l[34:32] : sB_face;
		wire [7:0] ct0_i_lo = ft0_ct_i_lo == 2'd0 ? c00_i[7:0]  : ft0_ct_i_lo == 2'd1 ? sB_c10[23:16] : ft0_ct_i_lo == 2'd2 ? sB_c01[23:16] : sB_c11[23:16];
		wire [7:0] ct0_i_hi = ft0_ct_i_hi == 2'd0 ? c00_i[15:8] : ft0_ct_i_hi == 2'd1 ? sB_c10[31:24] : ft0_ct_i_hi == 2'd2 ? sB_c01[31:24] : sB_c11[31:24];
		wire [7:0] ct0_j_lo = ft0_ct_j_lo == 2'd0 ? c00_j[7:0]  : ft0_ct_j_lo == 2'd1 ? sB_c10[7:0]   : ft0_ct_j_lo == 2'd2 ? sB_c01[7:0]   : sB_c11[7:0];
		wire [7:0] ct0_j_hi = ft0_ct_j_hi == 2'd0 ? c00_j[15:8] : ft0_ct_j_hi == 2'd1 ? sB_c10[15:8]  : ft0_ct_j_hi == 2'd2 ? sB_c01[15:8]  : sB_c11[15:8];
		wire [15:0] ct0_i = {ct0_i_hi, ct0_i_lo};
		wire [15:0] ct0_j = {ct0_j_hi, ct0_j_lo};
		wire [2:0]  ct0_f = (!lin_f || ft0_f == 2'd0) ? c00_f : ft0_f == 2'd1 ? sB_c10[34:32] : ft0_f == 2'd2 ? sB_c01[34:32] : sB_c11[34:32];
		assign ti_s0[gt0]   = texf_i ? (msf_i ? fim : sB_fi) : cube_i ? ct0_i : (ft0_ti[0] ? sB_wi1[15:0] : sB_wi0[15:0]);
		assign tj_s0[gt0]   = texf_j ? sB_fj                 : cube_j ? ct0_j : (ft0_ti[1] ? sB_wj1[15:0] : sB_wj0[15:0]);
		assign tf_s0[gt0]   = (texf_f || !cube_f) ? 3'd0 : ct0_f;
		assign part_s0[gt0] = pt0;
		assign tb_s0[gt0]   = (texf_f || cube_f) ? 1'b0 : ((ft0_f[0] ? sB_wi1[16] : sB_wi0[16]) | (ft0_f[1] ? sB_wj1[16] : sB_wj0[16]) | s0_bk);
	end
	endgenerate

	wire [16:0] s0_wr = {sB_msf_wr_hi ? {1'b0, sB_wms[15:8]} : sB_wr[16:8], sB_msf_wr_lo ? sB_wms[7:0] : sB_wr[7:0]};
	wire [15:0] s0_wr_tw = sB_msf_tw ? sB_wms : sB_wr[15:0];
	wire [15:0] s0_tw;
	wire carry_tw_unused;
	am_add #(.W(16)) u_tw (.a({2'b00, s0_wr_tw[15:2]}), .b(16'd0), .ci(s0_wr_tw[1:0] != 2'd0), .s(s0_tw),
		.co(carry_tw_unused));

	/* ========================================================================= */
	/* Stage 0B -> Stage 1 Pipeline Registers (LAT >= 1)                         */
	/* ========================================================================= */
	reg [15:0] r0_k;
	reg [31:0] r0_lbase;
	reg [31:0] r0_plane;
	reg [31:0] r0_stride;
	reg [16:0] r0_wr;
	reg [15:0] r0_tw;
	reg [15:0] r0_fuv;
	reg [7:0]  r0_fw;
	reg        r0_tiled;
	reg [2:0]  r0_psl;
	reg        r0_blk;
	reg        r0_cube;
	reg        r0_texf;

	reg [15:0] r0_ti [0:3];
	reg [15:0] r0_tj [0:3];
	reg [2:0]  r0_tf [0:3];
	reg [1:0]  r0_part [0:3];
	reg        r0_tb [0:3];

	integer ki0;
	always @(posedge clk) begin
		if (rst_inv) begin
			r0_k      <= 16'd0;
			r0_lbase  <= 32'd0;
			r0_plane  <= 32'd0;
			r0_stride <= 32'd0;
			r0_wr     <= 17'd0;
			r0_tw     <= 16'd0;
			r0_fuv    <= 16'd0;
			r0_fw     <= 8'd0;
			r0_tiled  <= 1'b0;
			r0_psl    <= 3'd0;
			r0_blk    <= 1'b0;
			r0_cube   <= 1'b0;
			r0_texf   <= 1'b0;
			for (ki0 = 0; ki0 < 4; ki0 = ki0 + 1) begin
				r0_ti[ki0]   <= 16'd0;
				r0_tj[ki0]   <= 16'd0;
				r0_tf[ki0]   <= 3'd0;
				r0_part[ki0] <= 2'd0;
				r0_tb[ki0]   <= 1'b0;
			end
		end else if (en) begin
			r0_k      <= s0_k;
			r0_lbase  <= sB_lbase;
			r0_plane  <= sB_plane;
			r0_stride <= sB_stride;
			r0_wr     <= s0_wr;
			r0_tw     <= s0_tw;
			r0_fuv    <= sB_fuv;
			r0_fw     <= sB_fw;
			r0_tiled  <= sB_tiled;
			r0_psl    <= sB_psl;
			r0_blk    <= sB_blk;
			r0_cube   <= sB_cube;
			r0_texf   <= sB_texf;
			for (ki0 = 0; ki0 < 4; ki0 = ki0 + 1) begin
				r0_ti[ki0]   <= ti_s0[ki0];
				r0_tj[ki0]   <= tj_s0[ki0];
				r0_tf[ki0]   <= tf_s0[ki0];
				r0_part[ki0] <= part_s0[ki0];
				r0_tb[ki0]   <= tb_s0[ki0];
			end
		end
	end

	/* ========================================================================= */
	/* Stage 1: Address calculation & multipliers                                */
	/* ========================================================================= */
	wire [15:0] s1_k      = (LAT >= 1) ? r0_k      : s0_k;
	wire [31:0] s1_lbase  = (LAT >= 1) ? r0_lbase  : sB_lbase;
	wire [31:0] s1_plane  = (LAT >= 1) ? r0_plane  : sB_plane;
	wire [31:0] s1_stride = (LAT >= 1) ? r0_stride : sB_stride;
	wire [16:0] s1_wr     = (LAT >= 1) ? r0_wr     : s0_wr;
	wire [15:0] s1_tw     = (LAT >= 1) ? r0_tw     : s0_tw;
	wire [15:0] s1_fuv    = (LAT >= 1) ? r0_fuv    : sB_fuv;
	wire [7:0]  s1_fw     = (LAT >= 1) ? r0_fw     : sB_fw;
	wire        s1_tiled  = (LAT >= 1) ? r0_tiled  : sB_tiled;
	wire [2:0]  s1_psl    = (LAT >= 1) ? r0_psl    : sB_psl;
	wire        s1_blk    = (LAT >= 1) ? r0_blk    : sB_blk;
	wire        s1_cube   = (LAT >= 1) ? r0_cube   : sB_cube;
	wire        s1_texf   = (LAT >= 1) ? r0_texf   : sB_texf;

	/* Stage 1A: Multipliers */
	wire [47:0] kp;
	localparam KP_LAT = (LAT >= 3) ? 2 : 0;
	wire kp_clk = (LAT >= 3) ? clk : 1'b0;
	am_mul #(.AW(32), .BW(16), .LAT(KP_LAT)) u_kp (.clk(kp_clk), .en(en), .a(s1_plane), .b(s1_k), .p(kp));

	wire [34:0] fs_comb [0:3];
	wire [32:0] m_comb [0:3];
	localparam M_LAT = (LAT >= 3) ? 2 : 0;
	wire m_clk = (LAT >= 3) ? clk : 1'b0;
	genvar gt1;
	generate
	for (gt1 = 0; gt1 < 4; gt1 = gt1 + 1) begin : g_s1a
		wire [15:0] s1_ti_w   = (LAT >= 1) ? r0_ti[gt1]   : ti_s0[gt1];
		wire [15:0] s1_tj_w   = (LAT >= 1) ? r0_tj[gt1]   : tj_s0[gt1];
		wire [2:0]  s1_tf_w   = (LAT >= 1) ? r0_tf[gt1]   : tf_s0[gt1];
		wire tb_w_a    = s1_tiled || s1_blk;
		wire tb_w_b_lo = s1_tiled || s1_blk;
		wire tb_w_b_hi = s1_tiled || s1_blk;
		wire [16:0] b_m = {tb_w_b_hi ? {1'b0, s1_tw[15:8]} : s1_wr[16:8], tb_w_b_lo ? s1_tw[7:0] : s1_wr[7:0]};

		am_mul #(.AW(32), .BW(3), .LAT(M_LAT)) u_fs (.clk(m_clk), .en(en), .a(s1_stride), .b(s1_tf_w), .p(fs_comb[gt1]));
		am_mul #(.AW(16), .BW(17), .LAT(M_LAT)) u_m (.clk(m_clk), .en(en), .a(tb_w_a ? {2'b00, s1_tj_w[15:2]} : s1_tj_w),
			.b(b_m), .p(m_comb[gt1]));
	end
	endgenerate

	/* Stage 1A -> Stage 1B Pipeline Registers (when LAT >= 3) */
	reg [31:0] r1_lbase, r1b_lbase, r1c_lbase;
	reg [15:0] r1_ti [0:3], r1b_ti [0:3], r1c_ti [0:3];
	reg [15:0] r1_tj [0:3], r1b_tj [0:3], r1c_tj [0:3];
	reg [1:0]  r1_part [0:3], r1b_part [0:3], r1c_part [0:3];
	reg        r1_tb [0:3], r1b_tb [0:3], r1c_tb [0:3];
	reg        r1_tiled, r1b_tiled, r1c_tiled;
	reg        r1_blk, r1b_blk, r1c_blk;
	reg        r1_cube, r1b_cube, r1c_cube;
	reg        r1_texf, r1b_texf, r1c_texf;
	reg [2:0]  r1_psl, r1b_psl, r1c_psl;
	reg [15:0] r1_fuv, r1b_fuv, r1c_fuv;
	reg [7:0]  r1_fw, r1b_fw, r1c_fw;

	/* Post-DSP output registers (when LAT >= 5) */
	reg [31:0] r1c_kp;
	reg [31:0] r1c_fs [0:3];
	reg [31:0] r1c_m [0:3];

	integer ki1;
	always @(posedge clk) begin
		if (rst_inv) begin
			r1_lbase  <= 32'd0; r1b_lbase <= 32'd0; r1c_lbase <= 32'd0;
			r1_tiled  <= 1'b0;  r1b_tiled <= 1'b0;  r1c_tiled <= 1'b0;
			r1_blk    <= 1'b0;  r1b_blk   <= 1'b0;  r1c_blk   <= 1'b0;
			r1_cube   <= 1'b0;  r1b_cube  <= 1'b0;  r1c_cube  <= 1'b0;
			r1_texf   <= 1'b0;  r1b_texf  <= 1'b0;  r1c_texf  <= 1'b0;
			r1_psl    <= 3'd0;  r1b_psl   <= 3'd0;  r1c_psl   <= 3'd0;
			r1_fuv    <= 16'd0; r1b_fuv   <= 16'd0; r1c_fuv   <= 16'd0;
			r1_fw     <= 8'd0;  r1b_fw    <= 8'd0;  r1c_fw    <= 8'd0;
			r1c_kp    <= 32'd0;
			for (ki1 = 0; ki1 < 4; ki1 = ki1 + 1) begin
				r1_ti[ki1]    <= 16'd0; r1b_ti[ki1]   <= 16'd0; r1c_ti[ki1]   <= 16'd0;
				r1_tj[ki1]    <= 16'd0; r1b_tj[ki1]   <= 16'd0; r1c_tj[ki1]   <= 16'd0;
				r1_part[ki1]  <= 2'd0;  r1b_part[ki1] <= 2'd0;  r1c_part[ki1] <= 2'd0;
				r1_tb[ki1]    <= 1'b0;  r1b_tb[ki1]   <= 1'b0;  r1c_tb[ki1]   <= 1'b0;
				r1c_fs[ki1]   <= 32'd0;
				r1c_m[ki1]    <= 32'd0;
			end
		end else if (en) begin
			r1_lbase  <= s1_lbase;  r1b_lbase <= r1_lbase;  r1c_lbase <= r1b_lbase;
			r1_tiled  <= s1_tiled;  r1b_tiled <= r1_tiled;  r1c_tiled <= r1b_tiled;
			r1_blk    <= s1_blk;    r1b_blk   <= r1_blk;    r1c_blk   <= r1b_blk;
			r1_cube   <= s1_cube;   r1b_cube  <= r1_cube;   r1c_cube  <= r1b_cube;
			r1_texf   <= s1_texf;   r1b_texf  <= r1_texf;   r1c_texf  <= r1b_texf;
			r1_psl    <= s1_psl;    r1b_psl   <= r1_psl;    r1c_psl   <= r1b_psl;
			r1_fuv    <= s1_fuv;    r1b_fuv   <= r1_fuv;    r1c_fuv   <= r1b_fuv;
			r1_fw     <= s1_fw;     r1b_fw    <= r1_fw;     r1c_fw    <= r1b_fw;
			r1c_kp    <= kp[31:0];
			for (ki1 = 0; ki1 < 4; ki1 = ki1 + 1) begin
				r1_ti[ki1]    <= (LAT >= 1) ? r0_ti[ki1]   : ti_s0[ki1];
				r1b_ti[ki1]   <= r1_ti[ki1];
				r1c_ti[ki1]   <= r1b_ti[ki1];
				r1_tj[ki1]    <= (LAT >= 1) ? r0_tj[ki1]   : tj_s0[ki1];
				r1b_tj[ki1]   <= r1_tj[ki1];
				r1c_tj[ki1]   <= r1b_tj[ki1];
				r1_part[ki1]  <= (LAT >= 1) ? r0_part[ki1] : part_s0[ki1];
				r1b_part[ki1] <= r1_part[ki1];
				r1c_part[ki1] <= r1b_part[ki1];
				r1_tb[ki1]    <= (LAT >= 1) ? r0_tb[ki1]   : tb_s0[ki1];
				r1b_tb[ki1]   <= r1_tb[ki1];
				r1c_tb[ki1]   <= r1b_tb[ki1];
				r1c_fs[ki1]   <= fs_comb[ki1][31:0];
				r1c_m[ki1]    <= m_comb[ki1][31:0];
			end
		end
	end

	wire [31:0] s1b_kp    = (LAT >= 5) ? r1c_kp    : kp[31:0];
	wire [31:0] s1b_lbase = (LAT >= 5) ? r1c_lbase : (LAT >= 3) ? r1b_lbase : s1_lbase;
	wire [31:0] s1b_lbk_comb;
	am_add #(.W(32)) u_lbk (.a(s1b_lbase), .b(s1b_kp), .ci(1'b0), .s(s1b_lbk_comb), .co(carry_unused[13]));
	wire        s1b_tiled = (LAT >= 5) ? r1c_tiled : (LAT >= 3) ? r1b_tiled : s1_tiled;
	wire        s1b_blk   = (LAT >= 5) ? r1c_blk   : (LAT >= 3) ? r1b_blk   : s1_blk;
	wire        s1b_cube  = (LAT >= 5) ? r1c_cube  : (LAT >= 3) ? r1b_cube  : s1_cube;
	wire        s1b_texf  = (LAT >= 5) ? r1c_texf  : (LAT >= 3) ? r1b_texf  : s1_texf;
	wire [2:0]  s1b_psl   = (LAT >= 5) ? r1c_psl   : (LAT >= 3) ? r1b_psl   : s1_psl;
	wire [15:0] s1b_fuv   = (LAT >= 5) ? r1c_fuv   : (LAT >= 3) ? r1b_fuv   : s1_fuv;
	wire [7:0]  s1b_fw    = (LAT >= 5) ? r1c_fw    : (LAT >= 3) ? r1b_fw    : s1_fw;

	/* Stage 1B: Offset & Base Adders */
	wire [31:0] s1_comb [0:3];
	wire [3:0]  cu_t1;
	genvar gt_s1;
	generate
	for (gt_s1 = 0; gt_s1 < 4; gt_s1 = gt_s1 + 1) begin : g_slot_1b_s1
		wire [31:0] m_in  = (LAT >= 5) ? r1c_m[gt_s1]  : m_comb[gt_s1][31:0];
		wire [15:0] ti_in = (LAT >= 5) ? r1c_ti[gt_s1] : (LAT >= 3) ? r1b_ti[gt_s1] : (LAT >= 1) ? r0_ti[gt_s1] : ti_s0[gt_s1];
		wire tb_in = s1b_tiled || s1b_blk;
		am_add #(.W(32)) u_s1 (.a(m_in), .b(tb_in ? {18'd0, ti_in[15:2]} : {16'd0, ti_in}), .ci(1'b0), .s(s1_comb[gt_s1]),
			.co(cu_t1[gt_s1]));
	end
	endgenerate

	/* Stage 1C -> Stage 1D Pipeline Registers (when LAT >= 5, separating u_lbk/u_s1 from u_a1/u_sh) */
	reg [31:0] r1d_lbk;
	reg [31:0] r1d_s1 [0:3];
	reg [31:0] r1d_fs [0:3];
	reg [15:0] r1d_ti [0:3], r1d_tj [0:3];
	reg [1:0]  r1d_part [0:3];
	reg        r1d_tb [0:3];
	reg        r1d_tiled, r1d_blk, r1d_cube, r1d_texf;
	reg [2:0]  r1d_psl [0:3];
	reg [15:0] r1d_fuv;
	reg [7:0]  r1d_fw;
	integer ki1d;
	always @(posedge clk) begin
		if (rst_inv) begin
			r1d_lbk   <= 32'd0;
			r1d_tiled <= 1'b0;
			r1d_blk   <= 1'b0;
			r1d_cube  <= 1'b0;
			r1d_texf  <= 1'b0;
			r1d_fuv   <= 16'd0;
			r1d_fw    <= 8'd0;
			for (ki1d = 0; ki1d < 4; ki1d = ki1d + 1) begin
				r1d_psl[ki1d]  <= 3'd0;
				r1d_s1[ki1d]   <= 32'd0;
				r1d_fs[ki1d]   <= 32'd0;
				r1d_ti[ki1d]   <= 16'd0;
				r1d_tj[ki1d]   <= 16'd0;
				r1d_part[ki1d] <= 2'd0;
				r1d_tb[ki1d]   <= 1'b0;
			end
		end else if (en) begin
			r1d_lbk   <= s1b_lbk_comb;
			r1d_tiled <= s1b_tiled;
			r1d_blk   <= s1b_blk;
			r1d_cube  <= s1b_cube;
			r1d_texf  <= s1b_texf;
			r1d_fuv   <= s1b_fuv;
			r1d_fw    <= s1b_fw;
			for (ki1d = 0; ki1d < 4; ki1d = ki1d + 1) begin
				r1d_psl[ki1d]  <= s1b_psl;
				r1d_s1[ki1d]   <= s1_comb[ki1d];
				r1d_fs[ki1d]   <= (LAT >= 5) ? r1c_fs[ki1d]   : fs_comb[ki1d][31:0];
				r1d_ti[ki1d]   <= (LAT >= 5) ? r1c_ti[ki1d]   : (LAT >= 3) ? r1b_ti[ki1d]   : (LAT >= 1) ? r0_ti[ki1d]   : ti_s0[ki1d];
				r1d_tj[ki1d]   <= (LAT >= 5) ? r1c_tj[ki1d]   : (LAT >= 3) ? r1b_tj[ki1d]   : (LAT >= 1) ? r0_tj[ki1d]   : tj_s0[ki1d];
				r1d_part[ki1d] <= (LAT >= 5) ? r1c_part[ki1d] : (LAT >= 3) ? r1b_part[ki1d] : (LAT >= 1) ? r0_part[ki1d] : part_s0[ki1d];
				r1d_tb[ki1d]   <= (LAT >= 5) ? r1c_tb[ki1d]   : (LAT >= 3) ? r1b_tb[ki1d]   : (LAT >= 1) ? r0_tb[ki1d]   : tb_s0[ki1d];
			end
		end
	end

	wire [31:0] s1d_lbk   = (LAT >= 5) ? r1d_lbk   : s1b_lbk_comb;
	wire        s1d_tiled = (LAT >= 5) ? r1d_tiled : s1b_tiled;
	wire        s1d_blk   = (LAT >= 5) ? r1d_blk   : s1b_blk;
	wire        s1d_cube  = (LAT >= 5) ? r1d_cube  : s1b_cube;
	wire        s1d_texf  = (LAT >= 5) ? r1d_texf  : s1b_texf;
	wire [15:0] s1d_fuv   = (LAT >= 5) ? r1d_fuv   : s1b_fuv;
	wire [7:0]  s1d_fw    = (LAT >= 5) ? r1d_fw    : s1b_fw;

	wire [31:0] to_comb [0:3];
	wire [31:0] a1_comb [0:3];
	wire [3:0]  unused_sh;
	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_slot_1b
		wire [31:0] s1 = (LAT >= 5) ? r1d_s1[gt] : s1_comb[gt];
		wire [31:0] fs = (LAT >= 5) ? r1d_fs[gt] : fs_comb[gt][31:0];
		wire [15:0] ti = (LAT >= 5) ? r1d_ti[gt] : (LAT >= 3) ? r1b_ti[gt] : (LAT >= 1) ? r0_ti[gt] : ti_s0[gt];
		wire [15:0] tj = (LAT >= 5) ? r1d_tj[gt] : (LAT >= 3) ? r1b_tj[gt] : (LAT >= 1) ? r0_tj[gt] : tj_s0[gt];
		wire [2:0]  psl_slot = (LAT >= 5) ? r1d_psl[gt] : s1b_psl;
		wire [2:0] psl_sh_lo = psl_slot;
		wire [2:0] psl_sh_hi = psl_slot;
		wire psl_is1_lo = (psl_slot == 3'd1);
		wire psl_is1_hi = (psl_slot == 3'd1);
		wire blk_lo   = s1d_blk;
		wire blk_hi   = s1d_blk;
		wire tiled_lo = s1d_tiled;
		wire tiled_hi = s1d_tiled;
		wire cf_lo    = s1d_cube && !s1d_texf;
		wire cf_hi    = s1d_cube && !s1d_texf;

		wire [31:0] sh_lo_w, sh_hi_w;
		am_shift #(.W(32), .SW(3)) u_sh_lo (.a(s1), .amt(psl_sh_lo), .left(1'b1), .arith(1'b0), .y(sh_lo_w));
		am_shift #(.W(32), .SW(3)) u_sh_hi (.a(s1), .amt(psl_sh_hi), .left(1'b1), .arith(1'b0), .y(sh_hi_w));
		assign unused_sh[gt] = &{1'b0, sh_lo_w[31:16], sh_hi_w[15:0]};
		wire [31:0] t_p1 = {s1[26:0], tj[1:0], ti[1:0], 1'b0};
		wire [31:0] t_p2 = {s1[25:0], tj[1:0], ti[1:0], 2'b00};
		assign to_comb[gt][15:0]  = blk_lo ? sh_lo_w[15:0]  : tiled_lo ? (psl_is1_lo ? t_p1[15:0]  : t_p2[15:0])  : sh_lo_w[15:0];
		assign to_comb[gt][31:16] = blk_hi ? sh_hi_w[31:16] : tiled_hi ? (psl_is1_hi ? t_p1[31:16] : t_p2[31:16]) : sh_hi_w[31:16];

		am_add #(.W(32)) u_a1 (.a(s1d_lbk), .b({cf_hi ? fs[31:16] : 16'd0, cf_lo ? fs[15:0] : 16'd0}), .ci(1'b0),
			.s(a1_comb[gt]), .co());
	end
	endgenerate

	/* Stage 1B -> Stage 2 Pipeline Registers (when LAT >= 4) */
	reg [31:0] r2_to [0:3];
	reg [31:0] r2_a1 [0:3];
	reg [1:0]  r2_part [0:3];
	reg [1:0]  r2_ti [0:3];
	reg [1:0]  r2_tj [0:3];
	reg        r2_tb [0:3];
	reg        r2_blk;
	reg [15:0] r2_fuv;
	reg [7:0]  r2_fw;

	integer ki2;
	always @(posedge clk) begin
		if (rst_inv) begin
			r2_blk <= 1'b0;
			r2_fuv <= 16'd0;
			r2_fw  <= 8'd0;
			for (ki2 = 0; ki2 < 4; ki2 = ki2 + 1) begin
				r2_to[ki2]   <= 32'd0;
				r2_a1[ki2]   <= 32'd0;
				r2_part[ki2] <= 2'd0;
				r2_ti[ki2]   <= 2'd0;
				r2_tj[ki2]   <= 2'd0;
				r2_tb[ki2]   <= 1'b0;
			end
		end else if (en) begin
			r2_blk <= s1d_blk;
			r2_fuv <= s1d_fuv;
			r2_fw  <= s1d_fw;
			for (ki2 = 0; ki2 < 4; ki2 = ki2 + 1) begin
				r2_to[ki2]   <= to_comb[ki2];
				r2_a1[ki2]   <= a1_comb[ki2];
				r2_part[ki2] <= (LAT >= 5) ? r1d_part[ki2] : (LAT >= 3) ? r1b_part[ki2] : (LAT >= 1) ? r0_part[ki2] : part_s0[ki2];
				r2_ti[ki2]   <= (LAT >= 5) ? r1d_ti[ki2][1:0] : (LAT >= 3) ? r1b_ti[ki2][1:0] : (LAT >= 1) ? r0_ti[ki2][1:0] : ti_s0[ki2][1:0];
				r2_tj[ki2]   <= (LAT >= 5) ? r1d_tj[ki2][1:0] : (LAT >= 3) ? r1b_tj[ki2][1:0] : (LAT >= 1) ? r0_tj[ki2][1:0] : tj_s0[ki2][1:0];
				r2_tb[ki2]   <= (LAT >= 5) ? r1d_tb[ki2] : (LAT >= 3) ? r1b_tb[ki2] : (LAT >= 1) ? r0_tb[ki2] : tb_s0[ki2];
			end
		end
	end

	wire        s2_blk = (LAT >= 4) ? r2_blk : s1d_blk;
	wire [15:0] s2_fuv = (LAT >= 4) ? r2_fuv : s1d_fuv;
	wire [7:0]  s2_fw  = (LAT >= 4) ? r2_fw  : s1d_fw;

	/* Stage 2: Final Address Adders */
	wire [31:0] a2_comb [0:3];
	wire [3:0]  part_off_comb [0:3];
	wire [3:0]  cu_t2_0;
	genvar gt2a;
	generate
	for (gt2a = 0; gt2a < 4; gt2a = gt2a + 1) begin : g_slot_2a
		wire [31:0] to   = (LAT >= 4) ? r2_to[gt2a]   : to_comb[gt2a];
		wire [31:0] a1   = (LAT >= 4) ? r2_a1[gt2a]   : a1_comb[gt2a];
		wire [1:0]  part = (LAT >= 4) ? r2_part[gt2a] : (LAT >= 3) ? r1_part[gt2a] : (LAT >= 1) ? r0_part[gt2a] : part_s0[gt2a];
		wire [1:0]  ti2  = (LAT >= 4) ? r2_ti[gt2a]   : (LAT >= 3) ? r1_ti[gt2a][1:0] : (LAT >= 1) ? r0_ti[gt2a][1:0] : ti_s0[gt2a][1:0];
		wire [1:0]  tj2  = (LAT >= 4) ? r2_tj[gt2a]   : (LAT >= 3) ? r1_tj[gt2a][1:0] : (LAT >= 1) ? r0_tj[gt2a][1:0] : tj_s0[gt2a][1:0];
		am_add #(.W(32)) u_a2 (.a(a1), .b(to), .ci(1'b0), .s(a2_comb[gt2a]), .co(cu_t2_0[gt2a]));
		assign part_off_comb[gt2a] = {part, s2_blk && part == 2'd0 ? ti2 : s2_blk && part == 2'd1 ? tj2 : 2'd0};
	end
	endgenerate

	/* Stage 2A -> Stage 2B Pipeline Registers (when LAT >= 5, separating u_a2 and u_a) */
	reg [31:0] r2b_a2 [0:3];
	reg [3:0]  r2b_part_off [0:3];
	reg        r2b_tb [0:3];
	reg [15:0] r2b_fuv;
	reg [7:0]  r2b_fw;
	integer ki2b;
	always @(posedge clk) begin
		if (rst_inv) begin
			r2b_fuv <= 16'd0;
			r2b_fw  <= 8'd0;
			for (ki2b = 0; ki2b < 4; ki2b = ki2b + 1) begin
				r2b_a2[ki2b]       <= 32'd0;
				r2b_part_off[ki2b] <= 4'd0;
				r2b_tb[ki2b]       <= 1'b0;
			end
		end else if (en) begin
			r2b_fuv <= s2_fuv;
			r2b_fw  <= s2_fw;
			for (ki2b = 0; ki2b < 4; ki2b = ki2b + 1) begin
				r2b_a2[ki2b]       <= a2_comb[ki2b];
				r2b_part_off[ki2b] <= part_off_comb[ki2b];
				r2b_tb[ki2b]       <= (LAT >= 4) ? r2_tb[ki2b] : (LAT >= 3) ? r1_tb[ki2b] : (LAT >= 1) ? r0_tb[ki2b] : tb_s0[ki2b];
			end
		end
	end

	wire [127:0] a;
	wire [3:0] bd;
	wire [3:0] cu_t2_1;
	genvar gt2;
	generate
	for (gt2 = 0; gt2 < 4; gt2 = gt2 + 1) begin : g_slot_2
		wire [31:0] a2_in  = (LAT >= 5) ? r2b_a2[gt2]       : a2_comb[gt2];
		wire [3:0]  po_in  = (LAT >= 5) ? r2b_part_off[gt2] : part_off_comb[gt2];
		wire        tb_in2 = (LAT >= 5) ? r2b_tb[gt2]       : (LAT >= 4) ? r2_tb[gt2] : (LAT >= 3) ? r1_tb[gt2] : (LAT >= 1) ? r0_tb[gt2] : tb_s0[gt2];
		am_add #(.W(32)) u_a (.a(a2_in), .b({28'd0, po_in}), .ci(1'b0), .s(a[gt2*32 +: 32]), .co(cu_t2_1[gt2]));
		assign bd[gt2] = tb_in2;
	end
	endgenerate
	assign addr = a;
	assign bord = bd;
	assign fuv = (LAT >= 5) ? r2b_fuv : s2_fuv;
	assign fw  = (LAT >= 5) ? r2b_fw  : s2_fw;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, kp[47:32], inB_wl[15:14], sB_fi[15:14], cu_t1, cu_t2_0, cu_t2_1, carry_tw_unused, unused_lat0, unused_sh, texf,
		fs_comb[0][34:32], fs_comb[1][34:32], fs_comb[2][34:32], fs_comb[3][34:32],
		m_comb[0][32], m_comb[1][32], m_comb[2][32], m_comb[3][32]};
endmodule

`default_nettype wire
