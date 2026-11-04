/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_addr: TU addressing: 4-lane parallel stream address generation.
 *
 * Computes:
 * - LOD lambda from quad derivatives across u, v, w in parallel (0 cycles).
 * - 4-lane parallel mip level, unnormalized coordinates, layer, and level base.
 * - 4-lane parallel wrap, border check, and bilinear footprint addresses (atg_tu_foot).
 *
 * Latency: 2 cycles (LA -> LB -> OUT).
 * Throughput: 1 cycle / quad.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_addr (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [9:0] st_idx,
	input wire [31:0] st_wdata,
	output wire desc_busy,
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [7:0] tx_op,
	input wire [3:0] tx_slot,
	input wire [3:0] tx_samp_slot,
	input wire tx_vs,	/* a vertex warp's: the vertex stage's slots */
	input wire [3:0] tx_mask,
	input wire [639:0] tx_coord,
	input wire [11:0] tx_off,
	input wire [15:0] tx_tag,
	input wire tx_last,
	/* To atg_tu_cache */
	output wire ta_valid,
	input wire ta_ready,
	(* keep = "true", extract_reset = "no" *) output reg [511:0] ta_addr,
	(* keep = "true" *) output reg [15:0] ta_bord,
	(* keep = "true", extract_reset = "no" *) output reg [127:0] ta_wts,
	(* keep = "true" *) output reg [15:0] ta_tag,
	(* keep = "true" *) output reg [3:0] ta_mask,
	output wire [49:0] ta_ctl,
	(* keep = "true", extract_reset = "no" *) output reg [127:0] ta_value,
	(* keep = "true" *) output reg ta_last
);
	`include "atg_config.vh"
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	`include "atg_tu_fmt.vh"
	`include "atg_tu_fn.vh"
	localparam [1:0] OP_TEXL = 2'd0, OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;
	localparam [5:0] IDLE         = 6'd0,
	                 CUBE         = 6'd1,
	                 CWAIT        = 6'd2,
	                 LA0          = 6'd3,
	                 LA0B         = 6'd4,
	                 LA0BB        = 6'd5,
	                 LA0BC        = 6'd6,
	                 LA0BD        = 6'd21,
	                 LA0BE        = 6'd26,
	                 LA0BF        = 6'd27,
	                 LA0BG        = 6'd28,
	                 LA0BH0       = 6'd44,
	                 LA0BH1       = 6'd45,
	                 LA0BH2       = 6'd46,
	                 LA0BH        = 6'd29,
	                 LA0BI        = 6'd30,
	                 LA0BJ        = 6'd31,
	                 LA0BK        = 6'd32,
	                 LA0C         = 6'd7,
	                 LA0C2        = 6'd33,
	                 LA0D         = 6'd8,
	                 LA0E         = 6'd9,
	                 LA0E2        = 6'd34,
	                 LA0F         = 6'd35,
	                 LA0G         = 6'd36,
	                 LA1A         = 6'd37,
	                 LA1          = 6'd10,
	                 LA1BA        = 6'd47,
	                 LA1B         = 6'd11,
	                 LA2          = 6'd12,
	                 LA2B         = 6'd19,
	                 LA2C         = 6'd22,
	                 LB0          = 6'd13,
	                 LB0B         = 6'd38,
	                 LB0C         = 6'd39,
	                 LB1          = 6'd14,
	                 LB2          = 6'd15,
	                 LB2B         = 6'd16,
	                 LB2C         = 6'd20,
	                 LB2D         = 6'd40,
	                 LB2E         = 6'd41,
	                 LB2F         = 6'd42,
	                 LA2D         = 6'd43,
	                 LB3          = 6'd17,
	                 OUT          = 6'd18,
	                 LOAD_DESC    = 6'd23,
	                 DECODE_DESC  = 6'd24,
	                 DECODE_DESC2 = 6'd25,
	                 WAIT_DESC1   = 6'd48,
	                 WAIT_DESC2   = 6'd49;

	wire rst_inv = !rst_n;

	(* keep = "true", max_fanout = 12 *) reg [5:0] st;
	(* keep = "true", max_fanout = 12 *) reg [3:0] pas;	/* {column, row, level, slice} */
	(* keep = "true", max_fanout = 12 *) reg [7:0] opr;
	(* keep = "true", max_fanout = 12 *) reg [4:0] slot;
	(* keep = "true", max_fanout = 12 *) reg [4:0] samp_slot;
	(* keep = "true", extract_reset = "no" *) reg [639:0] crd;
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_tcrd_w0 [0:3];
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_tcrd_w1 [0:3];
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_tcrd_w4 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0] r_tcrd_un0 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0] r_tcrd_un1 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0] r_lyr_w4 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  r_cw4_neg_lo, r_cw4_neg_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0] r_sfl [0:3];
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_foot_x [0:3];
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_foot_y [0:3];
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_foot_z [0:3];
	(* keep = "true", extract_reset = "no" *) reg [1:0]  r_foot_smp [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [11:0] r_foot_off [0:3];
	(* keep = "true", max_fanout = 12 *) reg [11:0] offs;
	(* keep = "true", max_fanout = 12 *) reg linq, depf, mipf;
	(* keep = "true" *) reg cb_lod, cb_lane;	/* a cube quad: the LOD projections, the lanes' own */
	(* keep = "true", max_fanout = 12 *) reg [2:0] job;	/* the cube projection being computed */
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [2:0] cf [0:3];	/* cube: each lane's face, s, t */
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [26:0] cs [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [26:0] ct [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [26:0] ls1, lt1, ls2, lt2;	/* lanes 1, 2 on lane 0's face (LOD) */

	/* Intermediate registers for pipelined Stage A */
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lam_u, r_lam_v, r_lam_w;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lam_uv, r_lam_w_d;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg r_uv_ge_v, r_uv_ge_w_lo, r_uv_ge_w_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg signed [16:0] r_lam_quad [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_lfx [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lam1 [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [32:0] r_lsum [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lraw [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [32:0] r_bsum [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lamp [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg r_gt_maxlod [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg r_lt_minlod [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_lam [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [16:0] r_lrnd [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [3:0]  r_lnx [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [3:0]  r_lfetch [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_mag [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_lend [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [3:0]  r_lsize [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_wl_s [0:3], r_hl_s [0:3], r_dl_s [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_sfl_ge_cnt [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_sfl_gt5 [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_cnt1 [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_lay [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_lstr [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_lb1 [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [3:0] r_lvl [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg r_lin_a [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [7:0] r_fl_a [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_dq [0:3];

	/* Lane stages A -> B registers (4 lanes parallel) */
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg r_lin [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] r_lin_wts;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [7:0] r_fl [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_wl [0:3], r_hl [0:3], r_dl [0:3], r_hl1 [0:3];
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_lbase [0:3], r_plane [0:3], r_val [0:3];

	/* Quad slot descriptor snapshot registers (latched on quad start) */
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_base, r_stride;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [15:0] r_w0_a, r_w0_b, r_h0_a, r_h0_b;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [15:0] r_cnt;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [3:0]  r_nlev, r_maxl;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [12:0] r_fc;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_legacy, r_depth, r_blk, r_f565, r_ms, r_tiled, r_unn, r_is3dr, r_arr, r_cube;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0] r_is3d_lod, r_cube_lod;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] r_is3d_foot, r_is3d_dsz;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] r_cube_hl, r_cube_tcrd, r_cube_lay, r_cube_foot;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] r_qlod_lraw, r_not_texb_lraw;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] r_val_dsz_b0, r_val_dsz_b1, r_val_texsz_lo_b0, r_val_texsz_lo_b1, r_val_texsz_hi, r_val_qlod_lo, r_val_qlod_hi, r_val_cmp_lo, r_val_cmp_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0] r_nofetch_a;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  r_nofetch_bord;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [2:0]  r_psl;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg signed [16:0] r_minlod, r_maxlod, r_sbias;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_max_lt_min;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [1:0]  r_mu, r_mv, r_mw;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg        r_samp_cmp, r_samp_mag_lin, r_samp_min_lin, r_samp_miplin;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [2:0]  r_cmp_op;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [1:0]  r_bcls;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [1:0]  r_rowa;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [20:0] r_tfmt;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [1:0]  r_gwi;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [31:0] r_dsize_raw, r_image_raw, r_samp_raw, r_dlod_raw;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [1:0]  r_row_raw;

	/* The descriptor of the quad's slot (4 parallel level read ports). */
	wire [3:0] lvl_l [0:3];
	wire [31:0] loff_l [0:3];
	wire [31:0] plane_l [0:3];
	wire [31:0] base, dsize, image, stride, samp, dlod;
	wire [20:0] tfmt;
	wire [1:0] rowa;	/* the slot's raw TEX_ROW */

	(* keep_hierarchy = "yes" *)
	atg_tu_desc desc (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.busy(desc_busy), .rd_slot(slot),
		.rd_samp_slot(samp_slot),
		.rd_level(r_lvl[0]), .rd_level1(r_lvl[1]), .rd_level2(r_lvl[2]), .rd_level3(r_lvl[3]),
		.rd_base(base), .rd_size(dsize), .rd_image(image), .rd_stride(stride), .rd_samp(samp),
		.rd_lod(dlod), .rd_fmt(tfmt), .rd_row(rowa),
		.rd_loff(loff_l[0]), .rd_plane(plane_l[0]),
		.rd_loff1(loff_l[1]), .rd_plane1(plane_l[1]),
		.rd_loff2(loff_l[2]), .rd_plane2(plane_l[2]),
		.rd_loff3(loff_l[3]), .rd_plane3(plane_l[3])
	);

	/* Pipelined decode of registered descriptor outputs (used in DECODE_DESC & DECODE_DESC2) */
	wire w0_zero_a = (r_dsize_raw[15:0]  == 16'd0);
	wire w0_zero_b = (r_dsize_raw[15:0]  == 16'd0);
	wire h0_zero_a = (r_dsize_raw[31:16] == 16'd0);
	wire h0_zero_b = (r_dsize_raw[31:16] == 16'd0);
	(* keep = "true" *) wire [15:0] w0_a = w0_zero_a ? 16'd1 : r_dsize_raw[15:0];
	(* keep = "true" *) wire [15:0] w0_b = w0_zero_b ? 16'd1 : r_dsize_raw[15:0];
	(* keep = "true" *) wire [15:0] h0_a = h0_zero_a ? 16'd1 : r_dsize_raw[31:16];
	(* keep = "true" *) wire [15:0] h0_b = h0_zero_b ? 16'd1 : r_dsize_raw[31:16];
	wire [3:0] nlev = r_image_raw[3:0] == 4'd0 ? 4'd1 : r_image_raw[3:0] > 4'd13 ? 4'd13 : r_image_raw[3:0];
	wire [3:0] maxl;
	wire maxl_bo_unused;
	am_sub #(.W(4)) u_maxl (.a(nlev), .b(4'd1), .bi(1'b0), .d(maxl), .bo(maxl_bo_unused));

	wire [12:0] fc = tu_fcls(r_tfmt, r_image_raw[GHCI_IMG_FMT +: 4]);
	wire tiled0 = r_image_raw[GHCI_IMG_TILED];
	wire ms = r_image_raw[GHCI_IMG_SAMPLES +: 4] == 4'd2 && !tiled0;	/* 4 samples */
	wire unn = r_samp_raw[GHCI_SAMP_UNNORM];
	wire [2:0] traw = r_image_raw[GHCI_IMG_TYPE +: 3];
	wire is3dr = traw == 3'd2;
`ifdef CFG_ENABLE_3D_CUBE
	wire arr = !unn && traw == 3'd1, is3d = !unn && is3dr, cube = !unn && traw == 3'd3;
`else
	wire arr = !unn && traw == 3'd1, is3d = 1'b0, cube = 1'b0;
`endif
	wire [15:0] cnt = r_image_raw[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : r_image_raw[GHCI_IMG_COUNT +: 16];
	wire signed [16:0] minlod = $signed({5'd0, r_dlod_raw[GHCI_TEX_MIN_LOD +: 12]});
	wire signed [16:0] maxlod = $signed({5'd0, ~r_dlod_raw[GHCI_TEX_MAX_LOD +: 12]});
	wire signed [16:0] sbias = $signed({{4{r_samp_raw[31]}}, r_samp_raw[GHCI_SAMP_LOD_BIAS +: 13]});

	wire [1:0] mu0 = r_samp_raw[GHCI_SAMP_WRAP_U +: 2], mv0 = r_samp_raw[GHCI_SAMP_WRAP_V +: 2];
	wire [1:0] mw0 = r_samp_raw[GHCI_SAMP_WRAP_W +: 2];
	wire [1:0] mu = unn && !mu0[1] ? 2'd2 : mu0, mv = unn && !mv0[1] ? 2'd2 : mv0;
	wire [1:0] mw = unn && !mw0[1] ? 2'd2 : mw0;

	wire [2:0] cmp_op = r_samp_raw[GHCI_SAMP_COMPARE_OP +: 3];
	wire [2:0] bcol = r_samp_raw[GHCI_SAMP_BORDER +: 3];
	wire [1:0] bcls = bcol[2:1] == 2'd3 ? 2'd0 : bcol[2:1];
	wire mag_lin = r_samp_raw[GHCI_SAMP_MAG_LINEAR];
	wire min_lin = r_samp_raw[GHCI_SAMP_MIN_LINEAR];
	wire samp_cmp = r_samp_raw[GHCI_SAMP_COMPARE];
	wire samp_miplin = r_samp_raw[GHCI_SAMP_MIP_LINEAR];

	/* Stage DECODE_DESC2 wires (from registered r_fc, r_image_raw, r_row_raw, r_ms) */
	wire legacy_d2 = r_fc[3], depth_d2 = r_fc[7], blk_d2 = r_fc[12];
	wire [2:0] psl_d2 = r_fc[2:0];
	wire f565_d2 = legacy_d2 && (r_image_raw[GHCI_IMG_FMT +: 4] == 4'd4);
	wire tiled_d2 = r_image_raw[GHCI_IMG_TILED] && (legacy_d2 || psl_d2 == 3'd2);
	wire [1:0] rowa_d2 = (tiled_d2 || blk_d2 || r_ms) ? 2'd0 : r_row_raw;
	wire [1:0] gwi_d2 = tu_gwi(r_tfmt, opr[5:4]);
	wire [11:0] max_lt_min_d;
	wire        max_lt_min_bo;
	am_sub #(.W(12)) u_max_lt_min (.a(r_maxlod[11:0]), .b(r_minlod[11:0]), .bi(1'b0), .d(max_lt_min_d), .bo(max_lt_min_bo));

	/* Active quad operations (derived from registered opr and registered descriptor) */
	wire [1:0] op = opr[1:0];
	wire [3:0] gather_foot = {4{op == OP_TEXL && opr[3]}};
	wire [3:0] gather_lane = {4{op == OP_TEXL && opr[3]}};
	wire       gather_ctl  = (op == OP_TEXL && opr[3]);
	wire qlod = op == OP_TEXB && opr[6];
	wire nlevq = op == OP_TEXSZ && opr[6] && !opr[3];
	wire dszq = op == OP_TEXSZ && opr[3] && !opr[6];
	wire smpq = op == OP_TEXSZ && opr[6] && opr[3];	/* texsz.s */
	wire nofetch      = op == OP_TEXSZ || qlod;
	wire nofetch_ctl  = op == OP_TEXSZ || qlod;
	wire nofetch_bord = op == OP_TEXSZ || qlod;
	wire nofetch_a_lo = op == OP_TEXSZ || qlod;
	wire nofetch_a_hi = op == OP_TEXSZ || qlod;

	wire cmp = r_depth && r_samp_cmp && !op[1] && !qlod;
	wire filt = r_legacy ? !r_depth || cmp : r_fc[6] || cmp;
	wire f32 = !r_legacy && !nofetch && !(r_fc[5] || cmp);	/* the fp32 path */
	wire [1:0] gwi = f32 && gather_ctl ? r_gwi : 2'd0;
`ifdef CFG_ENABLE_TRILINEAR
	wire miplin = filt && !gather_ctl && !r_unn && r_samp_miplin;
`else
	wire miplin = 1'b0;
`endif

	/* Cube Projections */
	wire n_lod = r_cube && op == OP_TEXB;
	wire n_lane = r_cube && !opr[1] && !opr[6];
	wire [1:0] jm2;
	wire [2:0] job1;
	wire [1:0] carry_unused;
	am_sub #(.W(2)) u_jm2 (.a(job[1:0]), .b(2'd2), .bi(1'b0), .d(jm2), .bo(carry_unused[0]));
	am_add #(.W(3)) u_job1 (.a(job), .b(3'd0), .ci(1'b1), .s(job1), .co(carry_unused[1]));
	wire [1:0] jlane = job[2] || job == 3'd3 ? jm2 : job[1:0];
	wire jfix = job == 3'd1 || job == 3'd2;
	wire [2:0] jnext = job == 3'd0 && !cb_lod ? 3'd3 : job == 3'd2 && !cb_lane ? 3'd6 : job1;

	wire [1:0] jlane_xl = jlane;
	wire [1:0] jlane_xh = jlane;
	wire [1:0] jlane_yl = jlane;
	wire [1:0] jlane_yh = jlane;
	wire [1:0] jlane_zl = jlane;
	wire [1:0] jlane_zh = jlane;
	wire [31:0] jcrd_x = {
		jlane_xh[1] ? (jlane_xh[0] ? r_foot_x[3][31:16] : r_foot_x[2][31:16]) : (jlane_xh[0] ? r_foot_x[1][31:16] : r_foot_x[0][31:16]),
		jlane_xl[1] ? (jlane_xl[0] ? r_foot_x[3][15:0]  : r_foot_x[2][15:0])  : (jlane_xl[0] ? r_foot_x[1][15:0]  : r_foot_x[0][15:0])
	};
	wire [31:0] jcrd_y = {
		jlane_yh[1] ? (jlane_yh[0] ? r_foot_y[3][31:16] : r_foot_y[2][31:16]) : (jlane_yh[0] ? r_foot_y[1][31:16] : r_foot_y[0][31:16]),
		jlane_yl[1] ? (jlane_yl[0] ? r_foot_y[3][15:0]  : r_foot_y[2][15:0])  : (jlane_yl[0] ? r_foot_y[1][15:0]  : r_foot_y[0][15:0])
	};
	wire [31:0] jcrd_z = {
		jlane_zh[1] ? (jlane_zh[0] ? r_foot_z[3][31:16] : r_foot_z[2][31:16]) : (jlane_zh[0] ? r_foot_z[1][31:16] : r_foot_z[0][31:16]),
		jlane_zl[1] ? (jlane_zl[0] ? r_foot_z[3][15:0]  : r_foot_z[2][15:0])  : (jlane_zl[0] ? r_foot_z[1][15:0]  : r_foot_z[0][15:0])
	};
`ifdef CFG_ENABLE_3D_CUBE
	wire c_bsy;
	wire [2:0] c_face;
	wire signed [26:0] c_s, c_t;
	(* keep_hierarchy = "yes" *)
	atg_tu_cube cubeu (
		.clk(clk), .rst_n(rst_n), .go(st == CUBE),
		.x(jcrd_x), .y(jcrd_y), .z(jcrd_z), .fix(jfix), .fface(cf[0]),
		.bsy(c_bsy), .face(c_face), .s(c_s), .t(c_t)
	);
`else
	wire c_bsy = 1'b0;
	wire [2:0] c_face = 3'd0;
	wire signed [26:0] c_s = 27'sd0;
	wire signed [26:0] c_t = 27'sd0;
`endif

	/* Parallel Quad LOD Evaluation across u, v, w axes (LAT=5 -> 11 cycles) */
	wire signed [16:0] lam_u, lam_v, lam_w;
	(* keep_hierarchy = "yes" *)
	atg_tu_lod #(.LAT(5)) lodu_u (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d_lod[0]), .cube(r_cube_lod[0]),
		.w0(r_w0_a), .h0(r_h0_a), .d0(r_cnt), .ax(2'd0), .lam(lam_u)
	);
	(* keep_hierarchy = "yes" *)
	atg_tu_lod #(.LAT(5)) lodu_v (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d_lod[1]), .cube(r_cube_lod[1]),
		.w0(r_w0_a), .h0(r_h0_a), .d0(r_cnt), .ax(2'd1), .lam(lam_v)
	);
	(* keep_hierarchy = "yes" *)
	atg_tu_lod #(.LAT(5)) lodu_w (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d_lod[2]), .cube(r_cube_lod[2]),
		.w0(r_w0_a), .h0(r_h0_a), .d0(r_cnt), .ax(2'd2), .lam(lam_w)
	);
	wire [16:0] uv_cmp_d, uvw_cmp_d;
	wire        uv_cmp_bo, uvw_cmp_bo;
	am_sub #(.W(17)) u_uv_cmp (.a({~r_lam_u[16], r_lam_u[15:0]}), .b({~r_lam_v[16], r_lam_v[15:0]}), .bi(1'b0), .d(uv_cmp_d), .bo(uv_cmp_bo));
	wire uv_ge_v_lo = r_uv_ge_v;
	wire uv_ge_v_hi = r_uv_ge_v;
	wire signed [16:0] lam_uv_sel = $signed({uv_ge_v_hi ? r_lam_u[16:9] : r_lam_v[16:9], uv_ge_v_lo ? r_lam_u[8:0] : r_lam_v[8:0]});
	am_sub #(.W(17)) u_uvw_cmp (.a({~r_lam_uv[16], r_lam_uv[15:0]}), .b({~r_lam_w_d[16], r_lam_w_d[15:0]}), .bi(1'b0), .d(uvw_cmp_d), .bo(uvw_cmp_bo));
	(* keep = "true" *) wire signed [16:0] lam_quad = $signed({r_uv_ge_w_hi ? r_lam_uv[16:9] : r_lam_w_d[16:9], r_uv_ge_w_lo ? r_lam_uv[8:0] : r_lam_w_d[8:0]});

	/* 4 Lanes Parallel Stage A and Stage B */
	wire [31:0] lfx_w_l [0:3];
	wire signed [16:0] lam1_l [0:3];
	wire [32:0] lsum_l [0:3];
	wire signed [16:0] lraw_w [0:3];
	wire [32:0] bsum_l [0:3];
	wire signed [16:0] lamp_l [0:3];
	wire gt_maxlod_l [0:3];
	wire lt_minlod_l [0:3];
	wire signed [16:0] lam_l [0:3];
	wire [16:0] lrnd_l [0:3];
	wire [3:0]  lnx_l [0:3];
	wire [3:0]  lfetch_l [0:3];
	wire        mag_l [0:3];
	wire        lend_l [0:3];
	wire [3:0]  lsize_l [0:3];
	wire [15:0] wl_s_nxt_l [0:3], hl_s_nxt_l [0:3], dl_s_nxt_l [0:3];
	wire        sfl_ge_cnt_l [0:3];
	wire        sfl_gt5_l [0:3];
	wire [15:0] cnt1_l [0:3];
	wire lin_l [0:3];
	wire [7:0] fl_l [0:3];
	wire [15:0] dq_l [0:3];
	wire [15:0] wl_l [0:3], hl_l [0:3], dl_l [0:3], hl1_l [0:3];
	wire signed [30:0] cu_l [0:3], cv_l [0:3], cwz_l [0:3];
	wire [31:0] lbase_n_l [0:3], val_l [0:3];
	wire [31:0] lb1_w_l [0:3];
	wire [15:0] lay_w [0:3];

	wire [127:0] f_addr_l [0:3];
	wire [3:0]   f_bord_l [0:3];
	wire [15:0]  f_fuv_l [0:3];
	wire [15:0]  wts_lo_l [0:3];
	wire [7:0]   f_fw_l [0:3];

	wire [3:0] cnt1_bo_unused;
	wire [3:0] lb1_co_unused;
	wire [3:0] lbase_co_unused;
	wire [7:0] lsum_carry_unused;
	wire [7:0] lvl_carry_unused;
	wire [8:0] lrnd_unused [0:3];
	wire [3:0] lmaxf_unused;
	wire [47:0] lstr_l [0:3];

	genvar gl;
	generate
	for (gl = 0; gl < 4; gl = gl + 1) begin : g_lanes
		wire [31:0] cw0 = r_tcrd_w0[gl];
		wire [31:0] cw1 = r_tcrd_w1[gl];
		wire [31:0] cw2 = crd[160*gl + 64 +: 32];
		wire [31:0] cw3 = crd[160*gl + 96 +: 32];
		wire [31:0] cw4 = r_tcrd_w4[gl];

		/* Stage A0: FP32 to Fix32 for cw2 (LAT=2) */
		wire [31:0] lfx_w;
		(* keep_hierarchy = "yes" *)
		atg_tu_fx32 #(.LAT(2)) u_lfx (.clk(clk), .rst_n(rst_n), .en(1'b1), .f(cw2), .sh(5'd8), .q(lfx_w));
		assign lfx_w_l[gl] = lfx_w;
		wire signed [16:0] lam1_sat = tu_sat16({r_lfx[gl][31], r_lfx[gl]});
		assign lam1_l[gl] = lam1_sat;

		/* Stage A0B: LOD Raw Selection (using r_lam_quad[gl] and r_lam1[gl]) */
		wire lq_s_lo   = r_lam_quad[gl][16];
		wire lq_s_hi   = r_lam_quad[gl][16];
		wire lam1_s_lo = r_lam1[gl][16];
		wire lam1_s_hi = r_lam1[gl][16];
		wire [32:0] lsum;
		am_add #(.W(33)) u_lsum (
			.a({{8{lq_s_hi}}, {8{lq_s_lo}}, r_lam_quad[gl]}),
			.b({{8{lam1_s_hi}}, {8{lam1_s_lo}}, r_lam1[gl]}),
			.ci(1'b0), .s(lsum), .co(lsum_carry_unused[gl*2 + 0])
		);
		assign lsum_l[gl] = lsum;
		wire signed [16:0] lsum_sat = tu_sat16(r_lsum[gl]);
		assign lraw_w[gl] = $signed({
			r_not_texb_lraw[gl] ? r_lam1[gl][16:9] : r_qlod_lraw[gl] ? r_lam_quad[gl][16:9] : lsum_sat[16:9],
			r_not_texb_lraw[gl] ? r_lam1[gl][8:0]  : r_qlod_lraw[gl] ? r_lam_quad[gl][8:0]  : lsum_sat[8:0]
		});

		/* Stage A0C: LOD Bias Accumulation & Clamp (using r_lraw) */
		wire lraw_s_lo  = r_lraw[gl][16];
		wire lraw_s_hi  = r_lraw[gl][16];
		wire sbias_s_lo = r_sbias[16];
		wire sbias_s_hi = r_sbias[16];
		wire [32:0] bsum;
		am_add #(.W(33)) u_bsum (
			.a({{8{lraw_s_hi}}, {8{lraw_s_lo}}, r_lraw[gl]}),
			.b({{8{sbias_s_hi}}, {8{sbias_s_lo}}, r_sbias}),
			.ci(1'b0), .s(bsum), .co(lsum_carry_unused[gl*2 + 1])
		);
		assign bsum_l[gl] = bsum;
		wire lamp_unn_lo = r_unn;
		wire lamp_unn_hi = r_unn;
		wire signed [16:0] bsum_sat = tu_sat16(r_bsum[gl]);
		assign lamp_l[gl] = $signed({
			lamp_unn_hi ? 8'd0 : bsum_sat[16:9],
			lamp_unn_lo ? 9'd0 : bsum_sat[8:0]
		});

		wire [16:0] maxlod_cmp_d, minlod_cmp_d;
		wire        maxlod_cmp_bo, minlod_cmp_bo;
		am_sub #(.W(17)) u_maxlod_cmp (.a({~r_maxlod[16], r_maxlod[15:0]}), .b({~r_lamp[gl][16], r_lamp[gl][15:0]}), .bi(1'b0), .d(maxlod_cmp_d), .bo(maxlod_cmp_bo));
		am_sub #(.W(17)) u_minlod_cmp (.a({~r_lamp[gl][16], r_lamp[gl][15:0]}), .b({~r_minlod[16], r_minlod[15:0]}), .bi(1'b0), .d(minlod_cmp_d), .bo(minlod_cmp_bo));
		assign gt_maxlod_l[gl] = maxlod_cmp_bo;
		assign lt_minlod_l[gl] = minlod_cmp_bo;
		wire gt_max_lo = r_gt_maxlod[gl];
		wire gt_max_hi = r_gt_maxlod[gl];
		wire lam_unn_lo = r_unn;
		wire lam_unn_hi = r_unn;
		wire use_min_lo = r_lt_minlod[gl] || r_max_lt_min;
		wire use_min_hi = r_lt_minlod[gl] || r_max_lt_min;
		wire [8:0] lamc_lo = gt_max_lo ? r_maxlod[8:0]  : r_lamp[gl][8:0];
		wire [7:0] lamc_hi = gt_max_hi ? r_maxlod[16:9] : r_lamp[gl][16:9];
		assign lam_l[gl] = $signed({
			lam_unn_hi ? 8'd0 : use_min_hi ? r_minlod[16:9] : lamc_hi,
			lam_unn_lo ? 9'd0 : use_min_lo ? r_minlod[8:0]  : lamc_lo
		});

		/* Stage A1A: Rounding & Level Fetch Pre-computation */
		wire [16:0] lrnd;
		wire [3:0] lnx;
		am_add #(.W(17)) u_lrnd (.a(r_lam[gl]), .b(17'd127), .ci(1'b0), .s(lrnd), .co(lvl_carry_unused[gl*2 + 0]));
		am_add #(.W(4)) u_lnx (.a(r_lam[gl][11:8]), .b(4'd0), .ci(pas[1]), .s(lnx), .co(lvl_carry_unused[gl*2 + 1]));
		assign lrnd_l[gl]   = lrnd;
		assign lnx_l[gl]    = lnx;
		(* keep = "true" *) wire [3:0] lfetch_w = cw2[31] ? 4'd0 : (cw2[30:4] != 27'd0 || cw2[3:0] > r_maxl) ? r_maxl : cw2[3:0];
		(* keep = "true" *) wire [3:0] lsize_w  = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
		assign lfetch_l[gl] = lfetch_w;
		assign mag_l[gl]    = r_lam[gl][16] || (r_lam[gl][15:0] == 16'd0);
		assign lend_l[gl]   = (r_lam[gl][15:12] != 4'd0 || r_lam[gl][11:8] >= r_maxl);
		assign lsize_l[gl]  = lsize_w;

		/* Stage A1: Level Selection (using r_lam, r_lrnd, r_lnx, r_lfetch, r_mag, r_lend, r_lsize) */
		wire mag = r_mag[gl];
		wire signed [16:0] lmaxf = $signed({5'd0, r_maxl, 8'd0});
		wire lam_gt_lmaxf = !r_lam[gl][16] && (r_lam[gl][15:12] != 4'd0 || r_lam[gl][11:8] > r_maxl || (r_lam[gl][11:8] == r_maxl && r_lam[gl][7:0] != 8'd0));
		wire lam_neg_dq   = r_lam[gl][16];
		assign dq_l[gl] = lam_neg_dq ? 16'd0 : lam_gt_lmaxf ? lmaxf[15:0] : r_lam[gl][15:0];
		wire [3:0] lmin = (r_lrnd[gl][15:12] != 4'd0 || r_lrnd[gl][11:8] > r_maxl) ? r_maxl : r_lrnd[gl][11:8];
		wire lend = r_lend[gl];
		wire [3:0] llin = lend ? r_maxl : r_lnx[gl];
		wire miplin_fl  = !mag && miplin && !lend && !op[1] && !qlod;
		wire miplin_lvl = miplin;
		assign fl_l[gl] = miplin_fl ? r_lam[gl][7:0] : 8'd0;
		wire [3:0] lsize = r_lsize[gl];
		(* keep = "true" *) wire [3:0] lvl_w = op == OP_TEXSZ ? lsize : op == OP_TEXF ? (r_ms ? 4'd0 : r_lfetch[gl]) : gather_lane[gl] || mag ? 4'd0 :
			miplin_lvl ? llin : lmin;
		(* keep = "true" *) wire lin_w = op[1] || qlod ? 1'b0 : gather_lane[gl] ? 1'b1 : filt && (mag ? r_samp_mag_lin : r_samp_min_lin);
		assign lvl_l[gl] = lvl_w;
		assign lin_l[gl] = lin_w;
		assign lrnd_unused[gl] = {r_lrnd[gl][16], r_lrnd[gl][7:0]};
		assign lmaxf_unused[gl] = lmaxf[16];
		wire unused_lod_cmp = &{1'b0, maxlod_cmp_d, minlod_cmp_d};

		wire [15:0] wl_s_nxt, hl_s_nxt, dl_s_nxt;
		am_shift #(.W(16), .SW(4)) u_wl_s (.a((gl < 2) ? r_w0_a : r_w0_b), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(wl_s_nxt));
		am_shift #(.W(16), .SW(4)) u_hl_s (.a((gl < 2) ? r_h0_a : r_h0_b), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(hl_s_nxt));
		am_shift #(.W(16), .SW(4)) u_dl_s (.a(r_cnt), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(dl_s_nxt));
		assign wl_s_nxt_l[gl] = wl_s_nxt;
		assign hl_s_nxt_l[gl] = hl_s_nxt;
		assign dl_s_nxt_l[gl] = dl_s_nxt;

		wire [15:0] wl_nxt = r_wl_s[gl] == 16'd0 ? 16'd1 : r_wl_s[gl];
		wire [15:0] hl1_nxt = r_hl_s[gl] == 16'd0 ? 16'd1 : r_hl_s[gl];
		wire is3dr_dl_l = r_is3dr;
		wire [15:0] hl_nxt = r_cube_hl[gl] ? wl_nxt : hl1_nxt;
		wire [15:0] dl_nxt = !is3dr_dl_l || r_dl_s[gl] == 16'd0 ? 16'd1 : r_dl_s[gl];
		assign wl_l[gl] = wl_nxt;
		assign hl_l[gl] = hl_nxt;
		assign dl_l[gl] = dl_nxt;
		assign hl1_l[gl] = hl1_nxt;

		(* keep_hierarchy = "yes" *)
		atg_tu_tcrd #(.LAT(2)) u_tcrd (
			.clk(clk), .rst_n(rst_n), .en(1'b1),
			.cw0(cw0), .cw1(cw1), .cw4(cw4),
			.cw0_un(r_tcrd_un0[gl]), .cw1_un(r_tcrd_un1[gl]),
			.mu(r_mu), .mv(r_mv), .mw(r_mw),
			.wl(r_wl[gl]), .hl(r_hl[gl]), .dl(r_dl[gl]),
			.fcs(cs[gl]), .fct(ct[gl]), .cube(r_cube_tcrd[gl]), .unn(r_unn),
			.cu(cu_l[gl]), .cv(cv_l[gl]), .cw(cwz_l[gl])
		);

		wire [31:0] sfl = r_sfl[gl];
		wire [15:0] cnt1, lyr, sfl_cmp_d;
		wire        sfl_cmp_bo;
		(* keep_hierarchy = "yes" *)
		atg_tu_layer #(.LAT(3)) u_lyr (.clk(clk), .rst_n(rst_n), .en(1'b1), .f(r_lyr_w4[gl]), .cnt(r_cnt), .l(lyr));
		am_sub #(.W(16)) u_cnt1 (.a(r_cnt), .b(16'd0), .bi(1'b1), .d(cnt1), .bo(cnt1_bo_unused[gl]));
		am_sub #(.W(16)) u_sfl_cmp (.a(sfl[15:0]), .b(r_cnt), .bi(1'b0), .d(sfl_cmp_d), .bo(sfl_cmp_bo));
		assign cnt1_l[gl]       = cnt1;
		assign sfl_ge_cnt_l[gl] = (sfl[31:16] != 16'd0) || !sfl_cmp_bo;
		assign sfl_gt5_l[gl]    = (sfl[31:3] != 29'd0) || (sfl[2:1] == 2'b11);
		wire unused_sfl_cmp = &{1'b0, sfl_cmp_d, unused_lod_cmp};

		wire lay_texf_arr  = (op == OP_TEXF) && r_arr;
		wire lay_texf_cube = (op == OP_TEXF) && !r_arr && r_cube_lay[gl];
		wire lay_norm_arr  = (op != OP_TEXF) && r_arr;
		wire [15:0] lay = lay_texf_arr  ? (r_sfl_ge_cnt[gl] ? r_cnt1[gl] : sfl[15:0]) :
		                  lay_texf_cube ? (r_sfl_gt5[gl]    ? 16'd5      : sfl[15:0]) :
		                  lay_norm_arr  ? lyr : 16'd0;
		assign lay_w[gl] = lay;
		am_mul #(.AW(32), .BW(16), .LAT(2)) u_lstr (.clk(clk), .en(1'b1), .a(r_stride), .b(r_lay[gl]), .p(lstr_l[gl]));

		wire [31:0] lb1_w;
		am_add #(.W(32)) u_lb1 (.a(r_base), .b(r_lstr[gl]), .ci(1'b0), .s(lb1_w), .co(lb1_co_unused[gl]));
		assign lb1_w_l[gl] = lb1_w;
		am_add #(.W(32)) u_lbase (.a(r_lb1[gl]), .b(loff_l[gl]), .ci(1'b0), .s(lbase_n_l[gl]),
			.co(lbase_co_unused[gl]));

		wire dsz_arr  = r_arr;
		wire dsz_is3d = !r_arr && r_is3d_dsz[gl];
		wire [15:0] dsz = dsz_arr ? r_cnt : dsz_is3d ? r_dl[gl] : 16'd1;
		wire [15:0] val_lo_s0 = smpq ? (r_ms ? 16'd4 : 16'd1) : nlevq ? {12'd0, r_nlev} : 16'd0;
		wire [15:0] val_lo = {
			r_val_dsz_b1[gl]      ? dsz[15:8]       :
			r_val_texsz_lo_b1[gl] ? r_wl[gl][15:8]  :
			r_val_qlod_lo[gl]     ? r_dq[gl][15:8]  :
			r_val_cmp_lo[gl]      ? cw3[15:8]       : val_lo_s0[15:8],
			r_val_dsz_b0[gl]      ? dsz[7:0]        :
			r_val_texsz_lo_b0[gl] ? r_wl[gl][7:0]   :
			r_val_qlod_lo[gl]     ? r_dq[gl][7:0]   :
			r_val_cmp_lo[gl]      ? cw3[7:0]        : val_lo_s0[7:0]
		};
		wire [15:0] val_hi = r_val_texsz_hi[gl] ? r_hl1[gl] :
		                     r_val_qlod_hi[gl]  ? r_lamp[gl][15:0] :
		                     r_val_cmp_hi[gl]   ? cw3[31:16] : 16'd0;
		assign val_l[gl] = {val_hi, val_lo};

		/* Stage B: Footprint and address expansion (LAT=5) */
		(* keep_hierarchy = "yes" *)
		atg_tu_foot #(.LAT(5)) u_foot (
			.clk(clk), .rst_n(rst_n), .en(1'b1),
			.op(op), .gather(gather_foot[gl]), .cube(r_cube_foot[gl]), .is3d(r_is3d_foot[gl]), .tiled(r_tiled), .lin(r_lin[gl]),
			.ms(r_ms), .smp(r_foot_smp[gl]), .psl(r_psl), .ra(r_rowa), .blk(r_blk),
			.row(pas[2]), .col(pas[3]), .gwi(gwi), .p0(pas[0]),
			.mu(r_mu), .mv(r_mv), .mw(r_mw), .off(r_foot_off[gl]),
			.x(r_foot_x[gl]), .y(r_foot_y[gl]), .z(r_foot_z[gl]),
			.cu(cu_l[gl]), .cv(cv_l[gl]), .cw(cwz_l[gl]),
			.wl(r_wl[gl]), .hl(r_hl[gl]), .dl(r_dl[gl]), .face(cf[gl]),
			.lbase(r_lbase[gl]), .plane(r_plane[gl]),
			.stride(r_stride), .addr(f_addr_l[gl]), .bord(f_bord_l[gl]),
			.fuv(f_fuv_l[gl]), .fw(f_fw_l[gl])
		);
		(* keep = "true" *) wire [15:0] wts_lo_w = r_lin_wts[gl] ? f_fuv_l[gl] : 16'd0;
		assign wts_lo_l[gl] = wts_lo_w;
	end
	endgenerate

	/* Multi-pass calculation */
	wire split = f32 && r_psl == 3'd3 && linq && (r_blk || !gather_ctl);
	wire quad = f32 && r_psl == 3'd4 && r_blk && linq;	/* 16-byte blocks: 4 passes */
	wire [2:0] nxb = pas[1:0] == 2'd0 ? (depf ? 3'd1 : mipf ? 3'd2 : 3'd4) :
		pas[1:0] == 2'd1 ? (mipf ? 3'd2 : 3'd4) : pas[1:0] == 2'd2 ? (depf ? 3'd3 : 3'd4) : 3'd4;
	wire [4:0] nxt = quad && !pas[3] ? {2'b01, pas[2:0]} : quad && !pas[2] ? {3'b001, pas[1:0]} :
		split && !pas[2] ? {3'b001, pas[1:0]} : {nxb[2], 2'b00, nxb[1:0]};

	wire [4:0] desc_busy_b = {5{desc_busy}};
	assign tx_ready = (st == IDLE) && !desc_busy_b[0];
	assign ta_valid = st == OUT;

	wire [1:0] tsz = r_legacy ? 2'd0 : r_psl == 3'd0 ? 2'd2 : r_psl == 3'd1 ? 2'd1 : 2'd0;
	wire [1:0] nsl = r_psl == 3'd3 ? 2'd1 : r_psl == 3'd4 ? 2'd2 : 2'd0;
	wire [7:0] vkf = r_legacy || r_fc[4] ? 8'd0 : r_tfmt[7:0];
	(* keep = "true" *) wire [49:0] ta_ctl_w = {quad, pas[3], r_tfmt[20:9], r_fc[8], vkf, nsl, tsz, pas[2], split, f32, r_f565,
		pas[1:0], qlod, gather_ctl ? opr[5:4] : 2'd0, gather_ctl, r_cmp_op, cmp, r_depth, r_bcls, pas != 4'd0,
		!nxt[4],
		op == OP_TEXF, nofetch_ctl, r_fc[9], linq};
	assign ta_ctl = ta_ctl_w;

	/* Fanout-decoupled slice enables for wide registers crd (640b) and ta_addr/ta_wts/ta_value */
	wire [7:0]  idle_ce_g;
	wire [79:0] idle_ce_s;
	wire [7:0]  idle_meta_ce = {8{(st == IDLE) && tx_valid && !desc_busy_b[0]}};
	wire [2:0]  wdesc1_en = {3{(st == IDLE) && tx_valid && !desc_busy_b[0]}};
	wire [4:0]  wdesc2_en = {5{st == WAIT_DESC1}};
	wire [1:0]  ld_desc_en = {2{st == WAIT_DESC2}};
	wire [1:0]  dec_desc_en = {2{st == LOAD_DESC}};
	wire [1:0]  la1_en = {2{st == LA1A}};
	wire [1:0]  la1b_en = {2{st == LA1BA}};
	wire [1:0]  la2d_en = {2{st == LA2C}};
	wire [3:0]  lb3_en = {4{st == LB2F}};
	(* keep = "true", equivalent_register_removal = "no" *) reg [32:0] wdesc1_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [52:0] wdesc2_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] lb3_ce_a;
	(* keep = "true", equivalent_register_removal = "no" *) reg [7:0]  lb3_ce_wts;
	(* keep = "true", equivalent_register_removal = "no" *) reg [7:0]  lb3_ce_val;
	(* keep = "true", equivalent_register_removal = "no" *) reg        lb3_ce_bord;
	genvar gs;
	generate
	for (gs = 0; gs < 8; gs = gs + 1) begin : g_ce_grp
		assign idle_ce_g[gs] = (st == IDLE) && tx_valid && !desc_busy_b[1 + (gs >> 1)];
	end
	for (gs = 0; gs < 80; gs = gs + 1) begin : g_idle_ce
		assign idle_ce_s[gs] = idle_ce_g[gs / 10];
	end
	endgenerate

	/* Fanout-decoupled state enables (<= 16 FFs per enable flip-flop) */
	(* keep = "true", equivalent_register_removal = "no" *) reg [15:0] ld_desc_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [22:0] dec_desc_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [9:0]  dec_desc2_ce;

	wire [3:0]  cwait_rdy = {4{(st == CWAIT) && !c_bsy}};
	wire [3:0]  cwait_j1_ce = {4{cwait_rdy[0] && (job == 3'd1)}};
	wire [3:0]  cwait_j2_ce = {4{cwait_rdy[0] && (job == 3'd2)}};
	wire [3:0]  cwait_l0_ce = {4{cwait_rdy[0] && (job != 3'd1) && (job != 3'd2) && (jlane == 2'd0)}};
	wire [3:0]  cwait_l1_ce = {4{cwait_rdy[1] && (job != 3'd1) && (job != 3'd2) && (jlane == 2'd1)}};
	wire [3:0]  cwait_l2_ce = {4{cwait_rdy[2] && (job != 3'd1) && (job != 3'd2) && (jlane == 2'd2)}};
	wire [3:0]  cwait_l3_ce = {4{cwait_rdy[3] && (job != 3'd1) && (job != 3'd2) && (jlane == 2'd3)}};

	wire [4:0]  la0_ce    = {5{st == LA0}};
	wire [7:0]  la0bb_ce  = {8{st == LA0BB}};
	wire [1:0]  la0bc_g   = {2{st == LA0BC}};
	wire [11:0] la0bc_ce  = {{6{la0bc_g[1]}}, {6{la0bc_g[0]}}};
	wire [7:0]  la0bf_ce  = {8{st == LA0BF}};
	wire [7:0]  la0bg_ce  = {8{st == LA0BG}};
	wire [5:0]  la0bh_ce  = {6{st == LA0BH}};
	wire [1:0]  la0bi_ce  = {2{st == LA0BI}};
	wire [1:0]  la0bj_ce  = {2{st == LA0BJ}};
	wire        la0bk_ce  = (st == LA0BK);
	wire [7:0]  la0c_ce   = {8{st == LA0C}};
	wire [1:0]  la0c2_g   = {2{st == LA0C2}};
	wire [11:0] la0c2_ce  = {{6{la0c2_g[1]}}, {6{la0c2_g[0]}}};
	wire [7:0]  la0d_ce   = {8{st == LA0D}};
	wire [1:0]  la0e_g    = {2{st == LA0E}};
	wire [11:0] la0e_ce   = {{6{la0e_g[1]}}, {6{la0e_g[0]}}};
	wire [7:0]  la0e2_ce  = {8{st == LA0E2}};
	wire        la0f_ce   = (st == LA0F);
	wire [7:0]  la0g_ce   = {8{st == LA0G}};
	wire [1:0]  la1a_g    = {2{st == LA1A}};
	wire [11:0] la1a_ce   = {{6{la1a_g[1]}}, {6{la1a_g[0]}}};
	(* keep = "true", equivalent_register_removal = "no" *) reg [15:0] la1_ce;
	wire [1:0]  la1ba_g   = {2{st == LA1BA}};
	wire [11:0] la1ba_ce  = {{6{la1ba_g[1]}}, {6{la1ba_g[0]}}};
	(* keep = "true", equivalent_register_removal = "no" *) reg [17:0] la1b_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [23:0] la2d_ce;

	integer k, si;
	always @(posedge clk) begin
		for (si = 0; si < 80; si = si + 1) begin
			if (idle_ce_s[si])
				crd[si*8 +: 8] <= tx_coord[si*8 +: 8];
		end
		for (k = 0; k < 4; k = k + 1) begin
			if (wdesc1_ce[k*8 + 0]) r_tcrd_w0[k][15:0]  <= crd[160*k + 0   +: 16];
			if (wdesc1_ce[k*8 + 1]) r_tcrd_w0[k][31:16] <= crd[160*k + 16  +: 16];
			if (wdesc1_ce[k*8 + 2]) r_tcrd_w1[k][15:0]  <= crd[160*k + 32  +: 16];
			if (wdesc1_ce[k*8 + 3]) r_tcrd_w1[k][31:16] <= crd[160*k + 48  +: 16];
			if (wdesc1_ce[k*8 + 4]) r_tcrd_w4[k][15:0]  <= crd[160*k + 128 +: 16];
			if (wdesc1_ce[k*8 + 5]) r_tcrd_w4[k][31:16] <= crd[160*k + 144 +: 16];
			if (wdesc1_ce[k*8 + 6]) r_lyr_w4[k][15:0]   <= crd[160*k + 128 +: 16];
			if (wdesc1_ce[k*8 + 7]) r_lyr_w4[k][31:16]  <= crd[160*k + 144 +: 16];
			if (wdesc1_ce[32]) begin
				r_cw4_neg_lo[k] <= crd[160*k + 159];
				r_cw4_neg_hi[k] <= crd[160*k + 159];
			end

			if (wdesc2_ce[k*8 + 0]) r_foot_x[k][15:0]   <= crd[160*k + 0   +: 16];
			if (wdesc2_ce[k*8 + 1]) r_foot_x[k][31:16]  <= crd[160*k + 16  +: 16];
			if (wdesc2_ce[k*8 + 2]) r_foot_y[k][15:0]   <= crd[160*k + 32  +: 16];
			if (wdesc2_ce[k*8 + 3]) r_foot_y[k][31:16]  <= crd[160*k + 48  +: 16];
			if (wdesc2_ce[k*8 + 4]) r_foot_z[k][15:0]   <= crd[160*k + 128 +: 16];
			if (wdesc2_ce[k*8 + 5]) r_foot_z[k][31:16]  <= crd[160*k + 144 +: 16];
			if (wdesc2_ce[k*8 + 6]) r_sfl[k][7:0]       <= r_cw4_neg_lo[k] ? 8'd0  : r_tcrd_w4[k][7:0];
			if (wdesc2_ce[33 + k])  r_sfl[k][15:8]      <= r_cw4_neg_lo[k] ? 8'd0  : r_tcrd_w4[k][15:8];
			if (wdesc2_ce[k*8 + 7]) r_sfl[k][31:16]     <= r_cw4_neg_hi[k] ? 16'd0 : r_tcrd_w4[k][31:16];
			if (wdesc2_ce[32])      r_foot_smp[k]       <= crd[160*k + 64  +: 2];
			if (wdesc2_ce[37 + k*4 + 0]) r_tcrd_un0[k][15:0]  <= crd[160*k + 0  +: 16];
			if (wdesc2_ce[37 + k*4 + 1]) r_tcrd_un0[k][31:16] <= crd[160*k + 16 +: 16];
			if (wdesc2_ce[37 + k*4 + 2]) r_tcrd_un1[k][15:0]  <= crd[160*k + 32 +: 16];
			if (wdesc2_ce[37 + k*4 + 3]) r_tcrd_un1[k][31:16] <= crd[160*k + 48 +: 16];

			for (si = 0; si < 8; si = si + 1) begin
				if (lb3_ce_a[k*8 + si])
					ta_addr[k*128 + si*16 +: 16] <= r_nofetch_a[k*8 + si] ? 16'd0 : f_addr_l[k][si*16 +: 16];
			end
			if (lb3_ce_wts[k*2 + 0])
				ta_wts[k*32 + 0 +: 16]    <= wts_lo_l[k];
			if (lb3_ce_wts[k*2 + 1])
				ta_wts[k*32 + 16 +: 16]   <= {f_fw_l[k], r_fl[k]};
			if (lb3_ce_val[k*2 + 0])
				ta_value[k*32 + 0 +: 16]  <= r_val[k][15:0];
			if (lb3_ce_val[k*2 + 1])
				ta_value[k*32 + 16 +: 16] <= r_val[k][31:16];
		end

		if (idle_meta_ce[0]) opr[2:0]  <= tx_op[2:0];
		if (idle_meta_ce[1]) opr[5:3]  <= tx_op[5:3];
		if (idle_meta_ce[2]) opr[7:6]  <= tx_op[7:6];
		if (idle_meta_ce[3]) slot      <= {tx_vs, tx_slot};
		if (idle_meta_ce[4]) begin
			samp_slot <= {tx_vs, tx_samp_slot};
			ta_mask   <= tx_mask;
			ta_last   <= tx_last;
		end
		if (idle_meta_ce[5]) begin
			offs <= tx_off;
		end
		if (idle_meta_ce[6]) begin
			ta_tag <= tx_tag;
		end

		if (ld_desc_ce[0])  r_base[15:0]       <= base[15:0];
		if (ld_desc_ce[1])  r_base[31:16]      <= base[31:16];
		if (ld_desc_ce[2])  r_stride[15:0]     <= stride[15:0];
		if (ld_desc_ce[3])  r_stride[31:16]    <= stride[31:16];
		if (ld_desc_ce[4])  r_dsize_raw[15:0]  <= dsize[15:0];
		if (ld_desc_ce[5])  r_dsize_raw[31:16] <= dsize[31:16];
		if (ld_desc_ce[6])  r_image_raw[15:0]  <= image[15:0];
		if (ld_desc_ce[7])  r_image_raw[31:16] <= image[31:16];
		if (ld_desc_ce[8])  r_samp_raw[15:0]   <= samp[15:0];
		if (ld_desc_ce[9])  r_samp_raw[31:16]  <= samp[31:16];
		if (ld_desc_ce[10]) r_dlod_raw[15:0]   <= dlod[15:0];
		if (ld_desc_ce[11]) r_dlod_raw[31:16]  <= dlod[31:16];
		if (ld_desc_ce[12]) r_tfmt[3:0]        <= tfmt[3:0];
		if (ld_desc_ce[15]) r_tfmt[7:4]        <= tfmt[7:4];
		if (ld_desc_ce[13]) r_tfmt[15:8]       <= tfmt[15:8];
		if (ld_desc_ce[14]) begin
			r_tfmt[20:16] <= tfmt[20:16];
			r_row_raw     <= rowa;
		end

		if (dec_desc_ce[0])  r_w0_a <= w0_a;
		if (dec_desc_ce[22]) r_w0_b <= w0_b;
		if (dec_desc_ce[1])  r_h0_a <= h0_a;
		if (dec_desc_ce[21]) r_h0_b <= h0_b;
		if (dec_desc_ce[2])  r_cnt  <= cnt;
		if (dec_desc_ce[3]) begin
			r_nlev <= nlev;
			r_maxl <= maxl;
		end
		if (dec_desc_ce[4]) begin
			r_ms    <= ms;
			r_unn   <= unn;
			r_is3dr <= is3dr;
		end
		if (dec_desc_ce[5]) begin
			r_arr       <= arr;
			r_cube      <= cube;
			r_is3d_lod  <= {3{is3d}};
			r_is3d_foot <= {4{is3d}};
			r_is3d_dsz  <= {4{is3d}};
		end
		if (dec_desc_ce[6])  r_fc <= fc;
		if (dec_desc_ce[7])  r_minlod[4:0] <= minlod[4:0];
		if (dec_desc_ce[18]) r_minlod[8:5] <= minlod[8:5];
		if (dec_desc_ce[8]) begin
			r_mu <= mu;
			r_mv <= mv;
			r_mw <= mw;
		end
		if (dec_desc_ce[9])  r_minlod[16:9] <= minlod[16:9];
		if (dec_desc_ce[10]) begin
			r_samp_cmp     <= samp_cmp;
			r_samp_mag_lin <= mag_lin;
			r_samp_min_lin <= min_lin;
			r_samp_miplin  <= samp_miplin;
		end
		if (dec_desc_ce[11]) r_maxlod[4:0] <= maxlod[4:0];
		if (dec_desc_ce[19]) r_maxlod[8:5] <= maxlod[8:5];
		if (dec_desc_ce[12]) begin
			r_cmp_op <= cmp_op;
			r_bcls   <= bcls;
		end
		if (dec_desc_ce[13]) r_maxlod[16:9] <= maxlod[16:9];
		if (dec_desc_ce[14]) r_sbias[4:0]   <= sbias[4:0];
		if (dec_desc_ce[20]) r_sbias[8:5]   <= sbias[8:5];
		if (dec_desc_ce[15]) r_sbias[16:9]  <= sbias[16:9];
		if (dec_desc_ce[16]) begin
			r_cube_lod  <= {3{cube}};
			r_cube_hl   <= {4{cube}};
			r_cube_tcrd <= {4{cube}};
		end
		if (dec_desc_ce[17]) begin
			r_cube_lay  <= {4{cube}};
			r_cube_foot <= {4{cube}};
		end

		if (dec_desc2_ce[0]) begin
			cb_lod          <= n_lod;
			cb_lane         <= n_lane;
			r_legacy        <= legacy_d2;
			r_depth         <= depth_d2;
			r_blk           <= blk_d2;
			r_psl           <= psl_d2;
		end
		if (dec_desc2_ce[6]) begin
			r_f565          <= f565_d2;
			r_tiled         <= tiled_d2;
			r_rowa          <= rowa_d2;
			r_gwi           <= gwi_d2;
			r_max_lt_min    <= max_lt_min_bo;
		end
		if (dec_desc2_ce[1]) begin
			r_qlod_lraw     <= {4{qlod}};
			r_not_texb_lraw <= {4{op != OP_TEXB}};
			r_nofetch_bord  <= {4{nofetch_bord}};
		end
		if (dec_desc2_ce[7]) begin
			r_val_dsz_b0      <= {4{!smpq && !nlevq && dszq}};
			r_val_dsz_b1      <= {4{!smpq && !nlevq && dszq}};
		end
		if (dec_desc2_ce[9]) begin
			r_val_texsz_lo_b0 <= {4{!smpq && !nlevq && !dszq && (op == OP_TEXSZ)}};
			r_val_texsz_lo_b1 <= {4{!smpq && !nlevq && !dszq && (op == OP_TEXSZ)}};
			r_val_texsz_hi    <= {4{!smpq && !nlevq && !dszq && (op == OP_TEXSZ)}};
		end
		if (dec_desc2_ce[8]) begin
			r_val_qlod_lo  <= {4{!smpq && !nlevq && !dszq && (op != OP_TEXSZ) && qlod}};
			r_val_qlod_hi  <= {4{!smpq && !nlevq && !dszq && (op != OP_TEXSZ) && qlod}};
			r_val_cmp_lo   <= {4{!smpq && !nlevq && !dszq && (op != OP_TEXSZ) && !qlod && (depth_d2 && r_samp_cmp && !op[1] && !qlod)}};
			r_val_cmp_hi   <= {4{!smpq && !nlevq && !dszq && (op != OP_TEXSZ) && !qlod && (depth_d2 && r_samp_cmp && !op[1] && !qlod)}};
		end
		if (dec_desc2_ce[2]) r_nofetch_a[15:0]  <= {16{nofetch_a_lo}};
		if (dec_desc2_ce[3]) r_nofetch_a[31:16] <= {16{nofetch_a_hi}};
		if (dec_desc2_ce[4]) begin
			r_foot_off[0] <= r_cube ? 12'd0 : offs;
			r_foot_off[1] <= r_cube ? 12'd0 : offs;
		end
		if (dec_desc2_ce[5]) begin
			r_foot_off[2] <= r_cube ? 12'd0 : offs;
			r_foot_off[3] <= r_cube ? 12'd0 : offs;
		end

		if (cwait_j1_ce[0]) ls1[13:0]  <= c_s[13:0];
		if (cwait_j1_ce[1]) ls1[26:14] <= c_s[26:14];
		if (cwait_j1_ce[2]) lt1[13:0]  <= c_t[13:0];
		if (cwait_j1_ce[3]) lt1[26:14] <= c_t[26:14];

		if (cwait_j2_ce[0]) ls2[13:0]  <= c_s[13:0];
		if (cwait_j2_ce[1]) ls2[26:14] <= c_s[26:14];
		if (cwait_j2_ce[2]) lt2[13:0]  <= c_t[13:0];
		if (cwait_j2_ce[3]) lt2[26:14] <= c_t[26:14];

		if (cwait_l0_ce[0]) cs[0][13:0]  <= c_s[13:0];
		if (cwait_l0_ce[1]) begin cs[0][26:14] <= c_s[26:14]; cf[0] <= c_face; end
		if (cwait_l0_ce[2]) ct[0][13:0]  <= c_t[13:0];
		if (cwait_l0_ce[3]) ct[0][26:14] <= c_t[26:14];

		if (cwait_l1_ce[0]) cs[1][13:0]  <= c_s[13:0];
		if (cwait_l1_ce[1]) begin cs[1][26:14] <= c_s[26:14]; cf[1] <= c_face; end
		if (cwait_l1_ce[2]) ct[1][13:0]  <= c_t[13:0];
		if (cwait_l1_ce[3]) ct[1][26:14] <= c_t[26:14];

		if (cwait_l2_ce[0]) cs[2][13:0]  <= c_s[13:0];
		if (cwait_l2_ce[1]) begin cs[2][26:14] <= c_s[26:14]; cf[2] <= c_face; end
		if (cwait_l2_ce[2]) ct[2][13:0]  <= c_t[13:0];
		if (cwait_l2_ce[3]) ct[2][26:14] <= c_t[26:14];

		if (cwait_l3_ce[0]) cs[3][13:0]  <= c_s[13:0];
		if (cwait_l3_ce[1]) begin cs[3][26:14] <= c_s[26:14]; cf[3] <= c_face; end
		if (cwait_l3_ce[2]) ct[3][13:0]  <= c_t[13:0];
		if (cwait_l3_ce[3]) ct[3][26:14] <= c_t[26:14];

		for (k = 0; k < 4; k = k + 1) begin
			if (la0_ce[k]) r_cnt1[k] <= cnt1_l[k];
			if (la0_ce[4]) begin
				r_sfl_ge_cnt[k] <= sfl_ge_cnt_l[k];
				r_sfl_gt5[k]    <= sfl_gt5_l[k];
			end
			if (la0bb_ce[k*2 + 0]) r_lfx[k][15:0]  <= lfx_w_l[k][15:0];
			if (la0bb_ce[k*2 + 1]) r_lfx[k][31:16] <= lfx_w_l[k][31:16];
			if (la0bc_ce[k*2 + 0]) r_lam1[k][8:0]  <= lam1_l[k][8:0];
			if (la0bc_ce[k*2 + 1]) r_lam1[k][16:9] <= lam1_l[k][16:9];
			if (la0bc_ce[8 + k])   r_lay[k]        <= lay_w[k];
			if (la0bf_ce[k*2 + 0]) r_lstr[k][15:0]  <= lstr_l[k][15:0];
			if (la0bf_ce[k*2 + 1]) r_lstr[k][31:16] <= lstr_l[k][31:16];
			if (la0bg_ce[k*2 + 0]) r_lb1[k][15:0]   <= lb1_w_l[k][15:0];
			if (la0bg_ce[k*2 + 1]) r_lb1[k][31:16]  <= lb1_w_l[k][31:16];
			if (la0c_ce[k*2 + 0])  r_lam_quad[k][8:0]  <= lam_quad[8:0];
			if (la0c_ce[k*2 + 1])  r_lam_quad[k][16:9] <= lam_quad[16:9];
			if (la0c2_ce[k*3 + 0]) r_lsum[k][10:0]  <= lsum_l[k][10:0];
			if (la0c2_ce[k*3 + 1]) r_lsum[k][21:11] <= lsum_l[k][21:11];
			if (la0c2_ce[k*3 + 2]) r_lsum[k][32:22] <= lsum_l[k][32:22];
			if (la0d_ce[k*2 + 0])  r_lraw[k][8:0]  <= lraw_w[k][8:0];
			if (la0d_ce[k*2 + 1])  r_lraw[k][16:9] <= lraw_w[k][16:9];
			if (la0e_ce[k*3 + 0])  r_bsum[k][10:0]  <= bsum_l[k][10:0];
			if (la0e_ce[k*3 + 1])  r_bsum[k][21:11] <= bsum_l[k][21:11];
			if (la0e_ce[k*3 + 2])  r_bsum[k][32:22] <= bsum_l[k][32:22];
			if (la0e2_ce[k*2 + 0]) r_lamp[k][8:0]  <= lamp_l[k][8:0];
			if (la0e2_ce[k*2 + 1]) r_lamp[k][16:9] <= lamp_l[k][16:9];
			if (la0f_ce) begin
				r_gt_maxlod[k] <= gt_maxlod_l[k];
				r_lt_minlod[k] <= lt_minlod_l[k];
			end
			if (la0g_ce[k*2 + 0])  r_lam[k][8:0]  <= lam_l[k][8:0];
			if (la0g_ce[k*2 + 1])  r_lam[k][16:9] <= lam_l[k][16:9];
			if (la1a_ce[k*2 + 0])  r_lrnd[k][8:0]  <= lrnd_l[k][8:0];
			if (la1a_ce[k*2 + 1])  r_lrnd[k][16:9] <= lrnd_l[k][16:9];
			if (la1a_ce[8 + k]) begin
				r_lnx[k]    <= lnx_l[k];
				r_lfetch[k] <= lfetch_l[k];
				r_mag[k]    <= mag_l[k];
				r_lend[k]   <= lend_l[k];
				r_lsize[k]  <= lsize_l[k];
			end
			if (la1_ce[k])      r_lvl[k][1:0] <= lvl_l[k][1:0];
			if (la1_ce[12 + k]) begin
				r_lvl[k][3:2] <= lvl_l[k][3:2];
				r_lin_a[k]    <= lin_l[k];
			end
			if (la1_ce[4 + k]) r_fl_a[k] <= fl_l[k];
			if (la1_ce[8 + k]) r_dq[k]   <= dq_l[k];
			if (la1ba_ce[k*3 + 0]) r_wl_s[k] <= wl_s_nxt_l[k];
			if (la1ba_ce[k*3 + 1]) r_hl_s[k] <= hl_s_nxt_l[k];
			if (la1ba_ce[k*3 + 2]) r_dl_s[k] <= dl_s_nxt_l[k];
			if (la1b_ce[k*4 + 0])  r_wl[k]   <= wl_l[k];
			if (la1b_ce[k*4 + 1])  r_hl[k]   <= hl_l[k];
			if (la1b_ce[k*4 + 2])  r_dl[k]   <= dl_l[k];
			if (la1b_ce[k*4 + 3])  r_hl1[k]  <= hl1_l[k];
			if (la1b_ce[16 + (k >> 1)]) begin
				r_lin[k]     <= r_lin_a[k];
				r_lin_wts[k] <= r_lin_a[k];
				r_fl[k]      <= r_fl_a[k];
			end
			if (la2d_ce[k*6 + 0])  r_lbase[k][15:0]  <= lbase_n_l[k][15:0];
			if (la2d_ce[k*6 + 1])  r_lbase[k][31:16] <= lbase_n_l[k][31:16];
			if (la2d_ce[k*6 + 2])  r_plane[k][15:0]  <= plane_l[k][15:0];
			if (la2d_ce[k*6 + 3])  r_plane[k][31:16] <= plane_l[k][31:16];
			if (la2d_ce[k*6 + 4])  r_val[k][15:0]    <= val_l[k][15:0];
			if (la2d_ce[k*6 + 5])  r_val[k][31:16]   <= val_l[k][31:16];
			if (lb3_ce_bord)
				ta_bord[k*4 +: 4] <= r_nofetch_bord[k] ? 4'd0 : f_bord_l[k];
		end

		if (la0bh_ce[0]) r_lam_u[8:0]  <= lam_u[8:0];
		if (la0bh_ce[1]) r_lam_u[16:9] <= lam_u[16:9];
		if (la0bh_ce[2]) r_lam_v[8:0]  <= lam_v[8:0];
		if (la0bh_ce[3]) r_lam_v[16:9] <= lam_v[16:9];
		if (la0bh_ce[4]) r_lam_w[8:0]  <= lam_w[8:0];
		if (la0bh_ce[5]) r_lam_w[16:9] <= lam_w[16:9];

		if (la0bi_ce[0]) begin
			r_uv_ge_v      <= !uv_cmp_bo;
			r_lam_w_d[8:0] <= r_lam_w[8:0];
		end
		if (la0bi_ce[1]) r_lam_w_d[16:9] <= r_lam_w[16:9];

		if (la0bj_ce[0]) r_lam_uv[8:0]  <= lam_uv_sel[8:0];
		if (la0bj_ce[1]) r_lam_uv[16:9] <= lam_uv_sel[16:9];

		if (la0bk_ce) begin
			r_uv_ge_w_lo <= !uvw_cmp_bo;
			r_uv_ge_w_hi <= !uvw_cmp_bo;
		end

		if (rst_inv) begin
			st <= IDLE;
			opr <= 8'd0;
			slot <= 5'd0;
			samp_slot <= 5'd0;
			offs <= 12'd0;
			ta_mask <= 4'd0;
			ta_tag <= 16'd0;
			ta_last <= 1'b0;
			pas <= 4'd0;
			linq <= 1'b0;
			depf <= 1'b0;
			mipf <= 1'b0;
			cb_lod <= 1'b0;
			cb_lane <= 1'b0;
			job <= 3'd0;
			ta_bord <= 16'd0;
			wdesc1_ce    <= 33'd0;
			wdesc2_ce    <= 53'd0;
			ld_desc_ce   <= 16'd0;
			dec_desc_ce  <= 23'd0;
			dec_desc2_ce <= 10'd0;
			la1_ce       <= 16'd0;
			la1b_ce      <= 18'd0;
			la2d_ce      <= 24'd0;
			lb3_ce_a     <= 32'd0;
			lb3_ce_wts   <= 8'd0;
			lb3_ce_val   <= 8'd0;
			lb3_ce_bord  <= 1'b0;
		end else begin
			wdesc1_ce    <= {{11{wdesc1_en[2]}}, {11{wdesc1_en[1]}}, {11{wdesc1_en[0]}}};
			wdesc2_ce    <= {{11{wdesc2_en[4]}}, {11{wdesc2_en[3]}}, {10{wdesc2_en[2]}}, {10{wdesc2_en[1]}}, {11{wdesc2_en[0]}}};
			ld_desc_ce   <= {{8{ld_desc_en[1]}}, {8{ld_desc_en[0]}}};
			dec_desc_ce  <= {{12{dec_desc_en[1]}}, {11{dec_desc_en[0]}}};
			dec_desc2_ce <= {10{st == DECODE_DESC}};
			la1_ce       <= {{8{la1_en[1]}}, {8{la1_en[0]}}};
			la1b_ce      <= {{9{la1b_en[1]}}, {9{la1b_en[0]}}};
			la2d_ce      <= {{12{la2d_en[1]}}, {12{la2d_en[0]}}};
			lb3_ce_a     <= {{11{lb3_en[2]}}, {11{lb3_en[1]}}, {10{lb3_en[0]}}};
			lb3_ce_wts   <= {8{lb3_en[3]}};
			lb3_ce_val   <= {8{lb3_en[3]}};
			lb3_ce_bord  <= lb3_en[2];
			case (st)
			IDLE: if (idle_meta_ce[7]) begin
				pas <= 4'd0;
				linq <= 1'b0;
				depf <= 1'b0;
				mipf <= 1'b0;
				job <= 3'd0;
				st <= WAIT_DESC1;
			end
			WAIT_DESC1: begin
				st <= WAIT_DESC2;
			end
			WAIT_DESC2: begin
				st <= LOAD_DESC;
			end
			LOAD_DESC: begin
				st <= DECODE_DESC;
			end
			DECODE_DESC: begin
				st <= DECODE_DESC2;
			end
			DECODE_DESC2: begin
				st <= n_lod || n_lane ? CUBE : LA0;
			end
			CUBE: st <= CWAIT;
			CWAIT: if (cwait_rdy[3]) begin
				job <= jnext;
				st <= jnext != 3'd6 ? CUBE : LA0;
			end
			LA0: begin
				st <= LA0B;
			end
			LA0B: begin
				st <= LA0BB;
			end
			LA0BB: begin
				st <= LA0BC;
			end
			LA0BC: begin
				st <= LA0BD;
			end
			LA0BD: begin
				st <= LA0BE;
			end
			LA0BE: begin
				st <= LA0BF;
			end
			LA0BF: begin
				st <= LA0BG;
			end
			LA0BG: begin
				st <= (op == OP_TEXB) ? LA0BH0 : LA0D;
			end
			LA0BH0: begin
				st <= LA0BH1;
			end
			LA0BH1: begin
				st <= LA0BH2;
			end
			LA0BH2: begin
				st <= LA0BH;
			end
			LA0BH: begin
				st <= LA0BI;
			end
			LA0BI: begin
				st <= LA0BJ;
			end
			LA0BJ: begin
				st <= LA0BK;
			end
			LA0BK: begin
				st <= LA0C;
			end
			LA0C: begin
				st <= LA0C2;
			end
			LA0C2: begin
				st <= LA0D;
			end
			LA0D: begin
				st <= LA0E;
			end
			LA0E: begin
				st <= LA0E2;
			end
			LA0E2: begin
				st <= LA0F;
			end
			LA0F: begin
				st <= LA0G;
			end
			LA0G: begin
				st <= LA1A;
			end
			LA1A: begin
				st <= LA1;
			end
			LA1: begin
				st <= LA1BA;
			end
			LA1BA: begin
				st <= LA1B;
			end
			LA1B: begin
				st <= LA2;
			end
			LA2: begin
				st <= LA2B;
			end
			LA2B: begin
				st <= LA2C;
			end
			LA2C: begin
				st <= LA2D;
			end
			LA2D: begin
				st <= LB0;
			end
			LB0: begin
				/* u_foot Stage 0A registers at posedge clk */
				st <= LB0B;
			end
			LB0B: begin
				/* u_foot Stage 0B1 registers at posedge clk */
				st <= LB0C;
			end
			LB0C: begin
				/* u_foot Stage 0B2 registers at posedge clk */
				st <= LB1;
			end
			LB1: begin
				/* u_foot Stage 0B3 -> Stage 1 registers at posedge clk */
				st <= LB2;
			end
			LB2: begin
				/* u_foot Stage 1A DSP stage 1 registers at posedge clk */
				st <= LB2B;
			end
			LB2B: begin
				/* u_foot Stage 1A DSP stage 2 registers at posedge clk */
				st <= LB2C;
			end
			LB2C: begin
				/* u_foot Stage 1C post-DSP registers at posedge clk */
				st <= LB2D;
			end
			LB2D: begin
				/* u_foot Stage 1D registers at posedge clk */
				st <= LB2E;
			end
			LB2E: begin
				/* u_foot Stage 2A registers at posedge clk */
				st <= LB2F;
			end
			LB2F: begin
				/* u_foot Stage 2B registers at posedge clk */
				st <= LB3;
			end
			LB3: begin
				linq <= (r_lin[0] && ta_mask[0]) || (r_lin[1] && ta_mask[1]) ||
				        (r_lin[2] && ta_mask[2]) || (r_lin[3] && ta_mask[3]);
				depf <= (f_fw_l[0] != 8'd0 && ta_mask[0]) || (f_fw_l[1] != 8'd0 && ta_mask[1]) ||
				        (f_fw_l[2] != 8'd0 && ta_mask[2]) || (f_fw_l[3] != 8'd0 && ta_mask[3]);
				mipf <= (r_fl[0] != 8'd0 && ta_mask[0]) || (r_fl[1] != 8'd0 && ta_mask[1]) ||
				        (r_fl[2] != 8'd0 && ta_mask[2]) || (r_fl[3] != 8'd0 && ta_mask[3]);
				st <= OUT;
			end
			OUT: if (ta_ready) begin
				linq <= 1'b0;
				depf <= 1'b0;
				mipf <= 1'b0;
				if (!nxt[4]) begin
					pas <= nxt[3:0];
					st <= LA1A;
				end else
					st <= IDLE;
			end
			default: st <= IDLE;
			endcase
		end
	end

`ifdef CFG_ENABLE_3D_CUBE
	/* Cube seamless edge mapping reference (Phase 005 / ws002-p005) */
	wire [2:0] cube_edge_fout;
	wire [15:0] cube_edge_uout, cube_edge_vout;
	atg_tu_cube_edge u_cube_edge_ref (
		.clk(clk),
		.rst_n(rst_n),
		.en(1'b1),
		.face_in(cf[0]),
		.u_in(17'sd0),
		.v_in(17'sd0),
		.size(16'd1),
		.face_out(cube_edge_fout),
		.u_out(cube_edge_uout),
		.v_out(cube_edge_vout)
	);
`else
	wire [2:0] cube_edge_fout = 3'd0;
	wire [15:0] cube_edge_uout = 16'd0;
	wire [15:0] cube_edge_vout = 16'd0;
`endif

`ifdef CFG_ENABLE_3D_CUBE
	wire unused_cube_signals = 1'b0;
`else
	wire unused_cube_signals = &{1'b0, jcrd_x, jcrd_y, jcrd_z, jfix};
`endif

	wire unused_ok = &{1'b0, fc[11:10],
		r_samp_raw[18:17], bcol[0], opr[7], opr[2],
		r_dlod_raw[31:24], r_image_raw[15:12], OP_TEXL, maxl_bo_unused, max_lt_min_d,
		cnt1_bo_unused, lb1_co_unused, lbase_co_unused,
		lsum_carry_unused, lvl_carry_unused,
		lrnd_unused[0], lrnd_unused[1], lrnd_unused[2], lrnd_unused[3], lmaxf_unused,
		uv_cmp_d, uvw_cmp_d, r_lam_quad[0], r_lam_quad[1], r_lam_quad[2], r_lam_quad[3],
		lamp_l[0][16], lamp_l[1][16], lamp_l[2][16], lamp_l[3][16],
		r_lamp[0][16], r_lamp[1][16], r_lamp[2][16], r_lamp[3][16],
		lstr_l[0][47:32], lstr_l[1][47:32], lstr_l[2][47:32], lstr_l[3][47:32],
		cube_edge_fout, cube_edge_uout, cube_edge_vout, unused_cube_signals};
endmodule

`default_nettype wire
