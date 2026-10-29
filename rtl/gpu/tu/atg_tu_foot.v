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

	wire signed [23:0] du = {{20{off[3]}}, off[3:0]};
	wire signed [23:0] dv = {{20{off[7]}}, off[7:4]};
	wire signed [23:0] dw = {{20{off[11]}}, off[11:8]};
	wire texf = op == 2'd2;
	/* The slice. */
	wire dlin = is3d && lin && !gather;
	wire [13:0] carry_unused;	/* the adders' carries */
	wire signed [23:0] ki;
	wire signed [32:0] zd, xd, yd;

	wire signed [23:0] dw_m1;
	am_sub #(.W(24)) u_dw_m1 (.a(dw), .b(24'd1), .bi(1'b0), .d(dw_m1), .bo(carry_unused[0]));
	wire signed [23:0] dw_adj = (dlin && !cw[7]) ? dw_m1 : dw;

	wire signed [23:0] cw_int = {cw[30], cw[30:8]};
	am_add #(.W(24)) u_ki (.a(cw_int), .b(dw_adj), .ci(dlin && p0), .s(ki),
		.co(carry_unused[1]));
	am_add #(.W(33)) u_zd (.a({z[31], z}), .b({{9{dw[23]}}, dw}), .ci(1'b0), .s(zd),
		.co(carry_unused[2]));
	wire [7:0] s0_fw = dlin ? {cw[7] ^ 1'b1, cw[6:0]} : 8'd0;

	/* The footprint coordinates. */
	wire signed [23:0] cu_int = {cu[30], cu[30:8]};
	wire signed [23:0] cv_int = {cv[30], cv[30:8]};
	wire signed [23:0] du_m1, dv_m1;
	am_sub #(.W(24)) u_du_m1 (.a(du), .b(24'd1), .bi(1'b0), .d(du_m1), .bo(carry_unused[3]));
	am_sub #(.W(24)) u_dv_m1 (.a(dv), .b(24'd1), .bi(1'b0), .d(dv_m1), .bo(carry_unused[4]));

	wire signed [23:0] du_adj = (lin && !cu[7]) ? du_m1 : du;
	wire signed [23:0] dv_adj = (lin && !cv[7]) ? dv_m1 : dv;

	wire signed [23:0] i0, j0, i1, j1;
	am_add #(.W(24)) u_i0 (.a(cu_int), .b(du_adj), .ci(1'b0), .s(i0),
		.co(carry_unused[5]));
	am_add #(.W(24)) u_j0 (.a(cv_int), .b(dv_adj), .ci(1'b0), .s(j0),
		.co(carry_unused[6]));
	am_add #(.W(24)) u_i1 (.a(cu_int), .b(du), .ci(lin && cu[7]), .s(i1),
		.co(carry_unused[7]));
	am_add #(.W(24)) u_j1 (.a(cv_int), .b(dv), .ci(lin && cv[7]), .s(j1),
		.co(carry_unused[8]));

	wire [7:0] cu2_lo = {cu[7] ^ lin, cu[6:0]};
	wire [7:0] cv2_lo = {cv[7] ^ lin, cv[6:0]};
	wire [15:0] s0_fuv = {cv2_lo, cu2_lo};

	am_add #(.W(33)) u_xd (.a({x[31], x}), .b({{9{du[23]}}, du}), .ci(1'b0), .s(xd),
		.co(carry_unused[9]));
	am_add #(.W(33)) u_yd (.a({y[31], y}), .b({{9{dv[23]}}, dv}), .ci(1'b0), .s(yd),
		.co(carry_unused[10]));

	/* ========================================================================= */
	/* Stage 0A -> Stage 0B Pipeline Registers (when LAT >= 2)                   */
	/* ========================================================================= */
	reg signed [23:0] rA_i0, rA_j0, rA_i1, rA_j1, rA_ki;
	reg signed [32:0] rA_zd, rA_xd, rA_yd;
	reg [15:0] rA_fuv;
	reg [7:0]  rA_fw;
	reg [15:0] rA_wl, rA_hl, rA_dl;
	reg [1:0]  rA_mu, rA_mv, rA_mw;
	reg [2:0]  rA_face;
	reg [31:0] rA_stride, rA_lbase, rA_plane;
	reg [1:0]  rA_op;
	reg        rA_gather, rA_cube, rA_is3d, rA_tiled, rA_lin, rA_ms;
	reg [1:0]  rA_smp;
	reg [2:0]  rA_psl;
	reg [1:0]  rA_ra;
	reg        rA_blk, rA_row, rA_col;
	reg [1:0]  rA_gwi;

	always @(posedge clk) begin
		if (!rst_n) begin
			rA_i0 <= 24'sd0; rA_j0 <= 24'sd0; rA_i1 <= 24'sd0; rA_j1 <= 24'sd0; rA_ki <= 24'sd0;
			rA_zd <= 33'sd0; rA_xd <= 33'sd0; rA_yd <= 33'sd0;
			rA_fuv <= 16'd0; rA_fw <= 8'd0;
			rA_wl <= 16'd0; rA_hl <= 16'd0; rA_dl <= 16'd0;
			rA_mu <= 2'd0; rA_mv <= 2'd0; rA_mw <= 2'd0;
			rA_face <= 3'd0; rA_stride <= 32'd0; rA_lbase <= 32'd0; rA_plane <= 32'd0;
			rA_op <= 2'd0; rA_gather <= 1'b0; rA_cube <= 1'b0; rA_is3d <= 1'b0;
			rA_tiled <= 1'b0; rA_lin <= 1'b0; rA_ms <= 1'b0;
			rA_smp <= 2'd0; rA_psl <= 3'd0; rA_ra <= 2'd0;
			rA_blk <= 1'b0; rA_row <= 1'b0; rA_col <= 1'b0; rA_gwi <= 2'd0;
		end else if (en) begin
			rA_i0 <= i0; rA_j0 <= j0; rA_i1 <= i1; rA_j1 <= j1; rA_ki <= ki;
			rA_zd <= zd; rA_xd <= xd; rA_yd <= yd;
			rA_fuv <= s0_fuv; rA_fw <= s0_fw;
			rA_wl <= wl; rA_hl <= hl; rA_dl <= dl;
			rA_mu <= mu; rA_mv <= mv; rA_mw <= mw;
			rA_face <= face; rA_stride <= stride; rA_lbase <= lbase; rA_plane <= plane;
			rA_op <= op; rA_gather <= gather; rA_cube <= cube; rA_is3d <= is3d;
			rA_tiled <= tiled; rA_lin <= lin; rA_ms <= ms;
			rA_smp <= smp; rA_psl <= psl; rA_ra <= ra;
			rA_blk <= blk; rA_row <= row; rA_col <= col; rA_gwi <= gwi;
		end
	end

	wire signed [23:0] inB_i0  = (LAT >= 2) ? rA_i0  : i0;
	wire signed [23:0] inB_j0  = (LAT >= 2) ? rA_j0  : j0;
	wire signed [23:0] inB_i1  = (LAT >= 2) ? rA_i1  : i1;
	wire signed [23:0] inB_j1  = (LAT >= 2) ? rA_j1  : j1;
	wire signed [23:0] inB_ki  = (LAT >= 2) ? rA_ki  : ki;
	wire signed [32:0] inB_zd  = (LAT >= 2) ? rA_zd  : zd;
	wire signed [32:0] inB_xd  = (LAT >= 2) ? rA_xd  : xd;
	wire signed [32:0] inB_yd  = (LAT >= 2) ? rA_yd  : yd;
	wire [15:0] inB_fuv        = (LAT >= 2) ? rA_fuv : s0_fuv;
	wire [7:0]  inB_fw         = (LAT >= 2) ? rA_fw  : s0_fw;
	wire [15:0] inB_wl         = (LAT >= 2) ? rA_wl  : wl;
	wire [15:0] inB_hl         = (LAT >= 2) ? rA_hl  : hl;
	wire [15:0] inB_dl         = (LAT >= 2) ? rA_dl  : dl;
	wire [1:0]  inB_mu         = (LAT >= 2) ? rA_mu  : mu;
	wire [1:0]  inB_mv         = (LAT >= 2) ? rA_mv  : mv;
	wire [1:0]  inB_mw         = (LAT >= 2) ? rA_mw  : mw;
	wire [2:0]  inB_face       = (LAT >= 2) ? rA_face : face;
	wire [31:0] inB_stride     = (LAT >= 2) ? rA_stride : stride;
	wire [31:0] inB_lbase      = (LAT >= 2) ? rA_lbase  : lbase;
	wire [31:0] inB_plane      = (LAT >= 2) ? rA_plane  : plane;
	wire [1:0]  inB_op         = (LAT >= 2) ? rA_op     : op;
	wire        inB_gather     = (LAT >= 2) ? rA_gather : gather;
	wire        inB_cube       = (LAT >= 2) ? rA_cube   : cube;
	wire        inB_is3d       = (LAT >= 2) ? rA_is3d   : is3d;
	wire        inB_tiled      = (LAT >= 2) ? rA_tiled  : tiled;
	wire        inB_lin        = (LAT >= 2) ? rA_lin    : lin;
	wire        inB_ms         = (LAT >= 2) ? rA_ms     : ms;
	wire [1:0]  inB_smp        = (LAT >= 2) ? rA_smp    : smp;
	wire [2:0]  inB_psl        = (LAT >= 2) ? rA_psl    : psl;
	wire [1:0]  inB_ra         = (LAT >= 2) ? rA_ra     : ra;
	wire        inB_blk        = (LAT >= 2) ? rA_blk    : blk;
	wire        inB_row        = (LAT >= 2) ? rA_row    : row;
	wire        inB_col        = (LAT >= 2) ? rA_col    : col;
	wire [1:0]  inB_gwi        = (LAT >= 2) ? rA_gwi    : gwi;

	wire inB_texf = inB_op == 2'd2;

	/* ========================================================================= */
	/* Stage 0B: Wrap, cube face mapping & footprint evaluation                  */
	/* ========================================================================= */
	wire [16:0] kw;
	wire [15:0] kf;
	atg_tu_wrap u_kw (.i(inB_ki), .n(inB_dl), .mode(inB_mw), .w(kw));
	atg_tu_iclamp u_kf (.v(inB_zd), .n(inB_dl), .c(kf));
	wire [15:0] s0_k = !inB_is3d ? 16'd0 : inB_texf ? kf : kw[15:0];
	wire s0_bk = inB_is3d && !inB_texf && kw[16];

	wire [16:0] wi0, wi1, wj0, wj1;
	atg_tu_wrap u_wi0 (.i(inB_i0), .n(inB_wl), .mode(inB_mu), .w(wi0));
	atg_tu_wrap u_wi1 (.i(inB_i1), .n(inB_wl), .mode(inB_mu), .w(wi1));
	atg_tu_wrap u_wj0 (.i(inB_j0), .n(inB_hl), .mode(inB_mv), .w(wj0));
	atg_tu_wrap u_wj1 (.i(inB_j1), .n(inB_hl), .mode(inB_mv), .w(wj1));

	wire [15:0] fi, fj;
	atg_tu_iclamp u_fi (.v(inB_xd), .n(inB_wl), .c(fi));
	atg_tu_iclamp u_fj (.v(inB_yd), .n(inB_hl), .c(fj));
	wire inB_msf = inB_ms && inB_texf;
`ifdef MUT_TU_MSROW
	wire [15:0] wms = {inB_wl[13:0], 2'b00};
`else
	wire [12:0] wl2;
	am_add #(.W(13)) u_wl2 (.a(inB_wl[13:1]), .b(13'd0), .ci(inB_wl[0]), .s(wl2), .co(carry_unused[11]));
	wire [15:0] wms = {wl2, 3'b000};
`endif
	wire [15:0] fim = {fi[13:0], inB_smp};

	wire [16:0] rm = inB_ra == 2'd0 ? 17'd0 : inB_ra == 2'd1 ? 17'd1 : inB_ra == 2'd2 ? 17'd3 : 17'd7;
	wire [16:0] wrm;
	am_add #(.W(17)) u_wrm (.a({1'b0, inB_wl}), .b(rm), .ci(1'b0), .s(wrm), .co(carry_unused[12]));
`ifdef MUT_TU_PITCH
	wire [16:0] wr = {1'b0, inB_wl} | (rm & 17'd0);
	wire unused_wrm = &{1'b0, wrm};
`else
	wire [16:0] wr = wrm & ~rm;
`endif

	wire [34:0] c00l, c10, c01, c11;
	wire [15:0] ci0, cj0;
	atg_tu_cube_texel u_c00 (.tface(inB_face), .i(inB_i0), .j(inB_j0), .n(inB_wl), .t(c00l));
	atg_tu_cube_texel u_c10 (.tface(inB_face), .i(inB_i1), .j(inB_j0), .n(inB_wl), .t(c10));
	atg_tu_cube_texel u_c01 (.tface(inB_face), .i(inB_i0), .j(inB_j1), .n(inB_wl), .t(c01));
	atg_tu_cube_texel u_c11 (.tface(inB_face), .i(inB_i1), .j(inB_j1), .n(inB_wl), .t(c11));
	atg_tu_iclamp u_ci0 (.v({{9{inB_i0[23]}}, inB_i0}), .n(inB_wl), .c(ci0));
	atg_tu_iclamp u_cj0 (.v({{9{inB_j0[23]}}, inB_j0}), .n(inB_wl), .c(cj0));
	wire [34:0] c00 = inB_lin ? c00l : {inB_face, ci0, cj0};

	wire [15:0] ti_s0 [0:3];
	wire [15:0] tj_s0 [0:3];
	wire [2:0]  tf_s0 [0:3];
	wire [1:0]  part_s0 [0:3];
	wire        tb_s0 [0:3];

	genvar gt0;
	generate
	for (gt0 = 0; gt0 < 4; gt0 = gt0 + 1) begin : g_slot0
		localparam [1:0] T0 = gt0;
		reg [34:0] ct0;
		reg [15:0] ti0, tj0;
		reg [2:0]  tf0;
		reg [1:0]  ft0, pt0;
		reg        tb0;
		always @(*) begin
`ifdef MUT_TU_ROW
			ft0 = (inB_gather && !inB_blk) || inB_psl <= 3'd2 ? T0 : inB_psl == 3'd3 ? {1'b0, T0[1]} : {1'b0, inB_col};
`else
			ft0 = (inB_gather && !inB_blk) || inB_psl <= 3'd2 ? T0 : inB_psl == 3'd3 ? {inB_row, T0[1]} : {inB_row, inB_col};
`endif
			pt0 = inB_gather && !inB_blk ? inB_gwi : inB_psl == 3'd3 ? {1'b0, T0[0]} : inB_psl == 3'd4 ? T0 : 2'd0;
			ct0 = !inB_lin || ft0 == 2'd0 ? c00 : ft0 == 2'd1 ? c10 : ft0 == 2'd2 ? c01 : c11;
			if (inB_texf) begin
				tf0 = 3'd0;
				ti0 = inB_msf ? fim : fi;
				tj0 = fj;
				tb0 = 1'b0;
			end else if (inB_cube) begin
				tf0 = ct0[34:32];
				ti0 = ct0[31:16];
				tj0 = ct0[15:0];
				tb0 = 1'b0;
			end else begin
				tf0 = 3'd0;
				ti0 = ft0[0] ? wi1[15:0] : wi0[15:0];
				tj0 = ft0[1] ? wj1[15:0] : wj0[15:0];
				tb0 = (ft0[0] ? wi1[16] : wi0[16]) | (ft0[1] ? wj1[16] : wj0[16]) | s0_bk;
			end
		end
		assign ti_s0[gt0]   = ti0;
		assign tj_s0[gt0]   = tj0;
		assign tf_s0[gt0]   = tf0;
		assign part_s0[gt0] = pt0;
		assign tb_s0[gt0]   = tb0;
	end
	endgenerate

	wire [16:0] s0_wr = inB_msf ? {1'b0, wms} : wr;
	wire [15:0] s0_tw;
	wire carry_tw_unused;
	am_add #(.W(16)) u_tw (.a({2'b00, s0_wr[15:2]}), .b(16'd0), .ci(s0_wr[1:0] != 2'd0), .s(s0_tw),
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
		if (!rst_n) begin
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
			r0_lbase  <= inB_lbase;
			r0_plane  <= inB_plane;
			r0_stride <= inB_stride;
			r0_wr     <= s0_wr;
			r0_tw     <= s0_tw;
			r0_fuv    <= inB_fuv;
			r0_fw     <= inB_fw;
			r0_tiled  <= inB_tiled;
			r0_psl    <= inB_psl;
			r0_blk    <= inB_blk;
			r0_cube   <= inB_cube;
			r0_texf   <= inB_texf;
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
	wire [31:0] s1_lbase  = (LAT >= 1) ? r0_lbase  : inB_lbase;
	wire [31:0] s1_plane  = (LAT >= 1) ? r0_plane  : inB_plane;
	wire [31:0] s1_stride = (LAT >= 1) ? r0_stride : inB_stride;
	wire [16:0] s1_wr     = (LAT >= 1) ? r0_wr     : s0_wr;
	wire [15:0] s1_tw     = (LAT >= 1) ? r0_tw     : s0_tw;
	wire [15:0] s1_fuv    = (LAT >= 1) ? r0_fuv    : inB_fuv;
	wire [7:0]  s1_fw     = (LAT >= 1) ? r0_fw     : inB_fw;
	wire        s1_tiled  = (LAT >= 1) ? r0_tiled  : inB_tiled;
	wire [2:0]  s1_psl    = (LAT >= 1) ? r0_psl    : inB_psl;
	wire        s1_blk    = (LAT >= 1) ? r0_blk    : inB_blk;
	wire        s1_cube   = (LAT >= 1) ? r0_cube   : inB_cube;
	wire        s1_texf   = (LAT >= 1) ? r0_texf   : inB_texf;

	/* Stage 1A: Multipliers */
	wire [47:0] kp;
	localparam KP_LAT = (LAT >= 3) ? 1 : 0;
	wire kp_clk = (LAT >= 3) ? clk : 1'b0;
	am_mul #(.AW(32), .BW(16), .LAT(KP_LAT)) u_kp (.clk(kp_clk), .en(en), .a(s1_plane), .b(s1_k), .p(kp));

	wire [34:0] fs_comb [0:3];
	wire [32:0] m_comb [0:3];
	genvar gt1;
	generate
	for (gt1 = 0; gt1 < 4; gt1 = gt1 + 1) begin : g_s1a
		wire [15:0] s1_ti_w   = (LAT >= 1) ? r0_ti[gt1]   : ti_s0[gt1];
		wire [15:0] s1_tj_w   = (LAT >= 1) ? r0_tj[gt1]   : tj_s0[gt1];
		wire [2:0]  s1_tf_w   = (LAT >= 1) ? r0_tf[gt1]   : tf_s0[gt1];
		wire tb_w = s1_tiled || s1_blk;

		am_mul #(.AW(32), .BW(3)) u_fs (.clk(1'b0), .en(1'b1), .a(s1_stride), .b(s1_tf_w), .p(fs_comb[gt1]));
		am_mul #(.AW(16), .BW(17)) u_m (.clk(1'b0), .en(1'b1), .a(tb_w ? {2'b00, s1_tj_w[15:2]} : s1_tj_w),
			.b(tb_w ? {1'b0, s1_tw} : s1_wr), .p(m_comb[gt1]));
	end
	endgenerate

	/* Stage 1A -> Stage 1B Pipeline Registers (when LAT >= 3) */
	reg [31:0] r1_lbase;
	reg [34:0] r1_fs [0:3];
	reg [32:0] r1_m [0:3];
	reg [15:0] r1_ti [0:3];
	reg [15:0] r1_tj [0:3];
	reg [1:0]  r1_part [0:3];
	reg        r1_tb [0:3];
	reg        r1_tiled, r1_blk, r1_cube, r1_texf;
	reg [2:0]  r1_psl;
	reg [15:0] r1_fuv;
	reg [7:0]  r1_fw;

	integer ki1;
	always @(posedge clk) begin
		if (!rst_n) begin
			r1_lbase <= 32'd0;
			r1_tiled <= 1'b0;
			r1_blk   <= 1'b0;
			r1_cube  <= 1'b0;
			r1_texf  <= 1'b0;
			r1_psl   <= 3'd0;
			r1_fuv   <= 16'd0;
			r1_fw    <= 8'd0;
			for (ki1 = 0; ki1 < 4; ki1 = ki1 + 1) begin
				r1_fs[ki1]   <= 35'd0;
				r1_m[ki1]    <= 33'd0;
				r1_ti[ki1]   <= 16'd0;
				r1_tj[ki1]   <= 16'd0;
				r1_part[ki1] <= 2'd0;
				r1_tb[ki1]   <= 1'b0;
			end
		end else if (en) begin
			r1_lbase <= s1_lbase;
			r1_tiled <= s1_tiled;
			r1_blk   <= s1_blk;
			r1_cube  <= s1_cube;
			r1_texf  <= s1_texf;
			r1_psl   <= s1_psl;
			r1_fuv   <= s1_fuv;
			r1_fw    <= s1_fw;
			for (ki1 = 0; ki1 < 4; ki1 = ki1 + 1) begin
				r1_fs[ki1]   <= fs_comb[ki1];
				r1_m[ki1]    <= m_comb[ki1];
				r1_ti[ki1]   <= (LAT >= 1) ? r0_ti[ki1]   : ti_s0[ki1];
				r1_tj[ki1]   <= (LAT >= 1) ? r0_tj[ki1]   : tj_s0[ki1];
				r1_part[ki1] <= (LAT >= 1) ? r0_part[ki1] : part_s0[ki1];
				r1_tb[ki1]   <= (LAT >= 1) ? r0_tb[ki1]   : tb_s0[ki1];
			end
		end
	end

	wire [31:0] s1b_kp    = kp[31:0];
	wire [31:0] s1b_lbase = (LAT >= 3) ? r1_lbase : s1_lbase;
	wire [31:0] s1b_lbk;
	am_add #(.W(32)) u_lbk (.a(s1b_lbase), .b(s1b_kp), .ci(1'b0), .s(s1b_lbk), .co(carry_unused[13]));
	wire        s1b_tiled = (LAT >= 3) ? r1_tiled : s1_tiled;
	wire        s1b_blk   = (LAT >= 3) ? r1_blk   : s1_blk;
	wire        s1b_cube  = (LAT >= 3) ? r1_cube  : s1_cube;
	wire        s1b_texf  = (LAT >= 3) ? r1_texf  : s1_texf;
	wire [2:0]  s1b_psl   = (LAT >= 3) ? r1_psl   : s1_psl;
	wire [15:0] s1b_fuv   = (LAT >= 3) ? r1_fuv   : s1_fuv;
	wire [7:0]  s1b_fw    = (LAT >= 3) ? r1_fw    : s1_fw;

	/* Stage 1B: Offset & Base Adders */
	wire [31:0] to_comb [0:3];
	wire [31:0] a1_comb [0:3];
	wire [3:0]  cu_t1;

	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_slot_1b
		wire [34:0] fs   = (LAT >= 3) ? r1_fs[gt]   : fs_comb[gt];
		wire [32:0] m    = (LAT >= 3) ? r1_m[gt]    : m_comb[gt];
		wire [15:0] ti   = (LAT >= 3) ? r1_ti[gt]   : (LAT >= 1) ? r0_ti[gt]   : ti_s0[gt];
		wire [15:0] tj   = (LAT >= 3) ? r1_tj[gt]   : (LAT >= 1) ? r0_tj[gt]   : tj_s0[gt];

		wire [31:0] s1, sh;
		wire tb_in = s1b_tiled || s1b_blk;
		am_add #(.W(32)) u_s1 (.a(m[31:0]), .b(tb_in ? {18'd0, ti[15:2]} : {16'd0, ti}), .ci(1'b0), .s(s1),
			.co(cu_t1[gt]));
		am_shift #(.W(32), .SW(3)) u_sh (.a(s1), .amt(s1b_psl), .left(1'b1), .arith(1'b0), .y(sh));
		assign to_comb[gt] = s1b_blk ? sh : s1b_tiled && s1b_psl == 3'd1 ? {s1[26:0], tj[1:0], ti[1:0], 1'b0} :
			s1b_tiled ? {s1[25:0], tj[1:0], ti[1:0], 2'b00} : sh;

		am_add #(.W(32)) u_a1 (.a(s1b_lbk), .b(s1b_cube && !s1b_texf ? fs[31:0] : 32'd0), .ci(1'b0),
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
		if (!rst_n) begin
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
			r2_blk <= s1b_blk;
			r2_fuv <= s1b_fuv;
			r2_fw  <= s1b_fw;
			for (ki2 = 0; ki2 < 4; ki2 = ki2 + 1) begin
				r2_to[ki2]   <= to_comb[ki2];
				r2_a1[ki2]   <= a1_comb[ki2];
				r2_part[ki2] <= (LAT >= 3) ? r1_part[ki2] : (LAT >= 1) ? r0_part[ki2] : part_s0[ki2];
				r2_ti[ki2]   <= (LAT >= 3) ? r1_ti[ki2][1:0] : (LAT >= 1) ? r0_ti[ki2][1:0] : ti_s0[ki2][1:0];
				r2_tj[ki2]   <= (LAT >= 3) ? r1_tj[ki2][1:0] : (LAT >= 1) ? r0_tj[ki2][1:0] : tj_s0[ki2][1:0];
				r2_tb[ki2]   <= (LAT >= 3) ? r1_tb[ki2] : (LAT >= 1) ? r0_tb[ki2] : tb_s0[ki2];
			end
		end
	end

	wire        s2_blk = (LAT >= 4) ? r2_blk : s1b_blk;
	wire [15:0] s2_fuv = (LAT >= 4) ? r2_fuv : s1b_fuv;
	wire [7:0]  s2_fw  = (LAT >= 4) ? r2_fw  : s1b_fw;

	/* Stage 2: Final Address Adders */
	wire [127:0] a;
	wire [3:0] bd;
	genvar gt2;
	generate
	for (gt2 = 0; gt2 < 4; gt2 = gt2 + 1) begin : g_slot_2
		wire [31:0] to   = (LAT >= 4) ? r2_to[gt2]   : to_comb[gt2];
		wire [31:0] a1   = (LAT >= 4) ? r2_a1[gt2]   : a1_comb[gt2];
		wire [1:0]  part = (LAT >= 4) ? r2_part[gt2] : (LAT >= 3) ? r1_part[gt2] : (LAT >= 1) ? r0_part[gt2] : part_s0[gt2];
		wire [1:0]  ti2  = (LAT >= 4) ? r2_ti[gt2]   : (LAT >= 3) ? r1_ti[gt2][1:0] : (LAT >= 1) ? r0_ti[gt2][1:0] : ti_s0[gt2][1:0];
		wire [1:0]  tj2  = (LAT >= 4) ? r2_tj[gt2]   : (LAT >= 3) ? r1_tj[gt2][1:0] : (LAT >= 1) ? r0_tj[gt2][1:0] : tj_s0[gt2][1:0];
		wire        tb   = (LAT >= 4) ? r2_tb[gt2]   : (LAT >= 3) ? r1_tb[gt2] : (LAT >= 1) ? r0_tb[gt2] : tb_s0[gt2];

		wire [31:0] a2;
		wire [1:0] cu_t2;
		am_add #(.W(32)) u_a2 (.a(a1), .b(to), .ci(1'b0), .s(a2), .co(cu_t2[0]));
		am_add #(.W(32)) u_a (.a(a2), .b({28'd0, part, s2_blk && part == 2'd0 ? ti2 :
			s2_blk && part == 2'd1 ? tj2 : 2'd0}), .ci(1'b0), .s(a[gt2*32 +: 32]), .co(cu_t2[1]));
		assign bd[gt2] = tb;
	end
	endgenerate
	assign addr = a;
	assign bord = bd;
	assign fuv = s2_fuv;
	assign fw = s2_fw;

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, kp[47:32], inB_wl[15:14], fi[15:14], cu_t1, carry_tw_unused, unused_lat0};
endmodule

`default_nettype wire
