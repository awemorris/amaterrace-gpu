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
	output reg [511:0] ta_addr,
	output reg [15:0] ta_bord,
	output reg [127:0] ta_wts,
	output reg [15:0] ta_tag,
	output reg [3:0] ta_mask,
	output wire [49:0] ta_ctl,
	output reg [127:0] ta_value,
	output reg ta_last
);
	`include "atg_config.vh"
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	`include "atg_tu_fmt.vh"
	`include "atg_tu_fn.vh"
	localparam [1:0] OP_TEXL = 2'd0, OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;
	localparam [4:0] IDLE  = 5'd0,
	                 CUBE  = 5'd1,
	                 CWAIT = 5'd2,
	                 LA0   = 5'd3,
	                 LA0B  = 5'd4,
	                 LA0BB = 5'd5,
	                 LA0BC = 5'd6,
	                 LA0C  = 5'd7,
	                 LA0D  = 5'd8,
	                 LA0E  = 5'd9,
	                 LA1   = 5'd10,
	                 LA1B  = 5'd11,
	                 LA2   = 5'd12,
	                 LB0   = 5'd13,
	                 LB1   = 5'd14,
	                 LB2   = 5'd15,
	                 LB2B  = 5'd16,
	                 LB3   = 5'd17,
	                 OUT   = 5'd18;

	reg [4:0] st;
	reg [3:0] pas;	/* {column, row, level, slice} */
	reg [7:0] opr;
	reg [4:0] slot;
	reg [4:0] samp_slot;
	reg [639:0] crd;
	reg [11:0] offs;
	reg linq, depf, mipf;
	reg cb_lod, cb_lane;	/* a cube quad: the LOD projections, the lanes' own */
	reg [2:0] job;	/* the cube projection being computed */
	reg [2:0] cf [0:3];	/* cube: each lane's face, s, t */
	reg signed [26:0] cs [0:3];
	reg signed [26:0] ct [0:3];
	reg signed [26:0] ls1, lt1, ls2, lt2;	/* lanes 1, 2 on lane 0's face (LOD) */

	/* Intermediate registers for pipelined Stage A */
	reg signed [16:0] r_lam_quad;
	reg signed [16:0] r_lam1 [0:3];
	reg signed [16:0] r_lraw [0:3];
	reg signed [16:0] r_lam [0:3];
	reg [15:0] r_lay [0:3];
	reg [31:0] r_lstr [0:3];
	reg [31:0] r_lb1 [0:3];
	reg [3:0] r_lvl [0:3];
	reg r_lin_a [0:3];
	reg [7:0] r_fl_a [0:3];
	reg signed [16:0] r_lamp [0:3];
	reg [15:0] r_dq [0:3];

	/* Lane stages A -> B registers (4 lanes parallel) */
	reg r_lin [0:3];
	reg [7:0] r_fl [0:3];
	reg [15:0] r_wl [0:3], r_hl [0:3], r_dl [0:3], r_hl1 [0:3];
	reg [31:0] r_lbase [0:3], r_plane [0:3], r_val [0:3];

	/* Quad slot descriptor snapshot registers (latched on quad start) */
	reg [31:0] r_base, r_stride;
	reg [15:0] r_w0, r_h0, r_cnt;
	reg [3:0]  r_nlev, r_maxl;
	reg [12:0] r_fc;
	reg        r_legacy, r_depth, r_blk, r_f565, r_ms, r_tiled, r_unn, r_is3dr, r_arr, r_is3d, r_cube;
	reg [2:0]  r_psl;
	reg signed [16:0] r_minlod, r_maxlod, r_sbias;
	reg [1:0]  r_mu, r_mv, r_mw;
	reg        r_samp_cmp, r_samp_mag_lin, r_samp_min_lin, r_samp_miplin;
	reg [2:0]  r_cmp_op;
	reg [1:0]  r_bcls;
	reg [1:0]  r_rowa;
	reg [20:0] r_tfmt;

	/* The descriptor of the quad's slot (4 parallel level read ports). */
	wire [3:0] lvl_l [0:3];
	wire [31:0] loff_l [0:3];
	wire [31:0] plane_l [0:3];
	wire [31:0] base, dsize, image, stride, samp, dlod;
	wire [20:0] tfmt;
	wire [1:0] rowa;	/* the slot's row rule (TEX_ROW) */

	atg_tu_desc desc (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.busy(desc_busy), .rd_slot(st == IDLE ? {tx_vs, tx_slot} : slot),
		.rd_samp_slot(st == IDLE ? {tx_vs, tx_samp_slot} : samp_slot),
		.rd_level(r_lvl[0]), .rd_level1(r_lvl[1]), .rd_level2(r_lvl[2]), .rd_level3(r_lvl[3]),
		.rd_base(base), .rd_size(dsize), .rd_image(image), .rd_stride(stride), .rd_samp(samp),
		.rd_lod(dlod), .rd_fmt(tfmt), .rd_row(rowa),
		.rd_loff(loff_l[0]), .rd_plane(plane_l[0]),
		.rd_loff1(loff_l[1]), .rd_plane1(plane_l[1]),
		.rd_loff2(loff_l[2]), .rd_plane2(plane_l[2]),
		.rd_loff3(loff_l[3]), .rd_plane3(plane_l[3])
	);

	/* Combinational decode of descriptor outputs (used at quad entry in IDLE) */
	wire [15:0] w0 = dsize[15:0] == 16'd0 ? 16'd1 : dsize[15:0];
	wire [15:0] h0 = dsize[31:16] == 16'd0 ? 16'd1 : dsize[31:16];
	wire [3:0] nlev = image[3:0] == 4'd0 ? 4'd1 : image[3:0] > 4'd13 ? 4'd13 : image[3:0];
	wire [3:0] maxl = nlev - 4'd1;

	wire [12:0] fc = tu_fcls(tfmt, image[GHCI_IMG_FMT +: 4]);
	wire legacy = fc[3], depth = fc[7], blk = fc[12];
	wire [2:0] psl = fc[2:0];
	wire f565 = legacy && image[GHCI_IMG_FMT +: 4] == 4'd4;	/* RGB565: 2-byte texels */
	wire tiled0 = image[GHCI_IMG_TILED];
	wire ms = image[GHCI_IMG_SAMPLES +: 4] == 4'd2 && !tiled0;	/* 4 samples */
	wire tiled = tiled0 && (legacy || psl == 3'd2);
	wire unn = samp[GHCI_SAMP_UNNORM];
	wire [2:0] traw = image[GHCI_IMG_TYPE +: 3];
	wire is3dr = traw == 3'd2;
`ifdef CFG_ENABLE_3D_CUBE
	wire arr = !unn && traw == 3'd1, is3d = !unn && is3dr, cube = !unn && traw == 3'd3;
`else
	wire arr = !unn && traw == 3'd1, is3d = 1'b0, cube = 1'b0;
`endif
	wire [15:0] cnt = image[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : image[GHCI_IMG_COUNT +: 16];
	wire signed [16:0] minlod = $signed({5'd0, dlod[GHCI_TEX_MIN_LOD +: 12]});
	wire signed [16:0] maxlod = $signed({5'd0, 12'hFFF - dlod[GHCI_TEX_MAX_LOD +: 12]});
	wire signed [16:0] sbias = $signed({{4{samp[31]}}, samp[GHCI_SAMP_LOD_BIAS +: 13]});

	wire [1:0] mu0 = samp[GHCI_SAMP_WRAP_U +: 2], mv0 = samp[GHCI_SAMP_WRAP_V +: 2];
	wire [1:0] mw0 = samp[GHCI_SAMP_WRAP_W +: 2];
	wire [1:0] mu = unn && !mu0[1] ? 2'd2 : mu0, mv = unn && !mv0[1] ? 2'd2 : mv0;
	wire [1:0] mw = unn && !mw0[1] ? 2'd2 : mw0;

	wire [2:0] cmp_op = samp[GHCI_SAMP_COMPARE_OP +: 3];
	wire [2:0] bcol = samp[GHCI_SAMP_BORDER +: 3];
	wire [1:0] bcls = bcol[2:1] == 2'd3 ? 2'd0 : bcol[2:1];
	wire mag_lin = samp[GHCI_SAMP_MAG_LINEAR];
	wire min_lin = samp[GHCI_SAMP_MIN_LINEAR];
	wire samp_cmp = samp[GHCI_SAMP_COMPARE];
	wire samp_miplin = samp[GHCI_SAMP_MIP_LINEAR];

	/* Active quad operations (derived from registered opr and registered descriptor) */
	wire [1:0] op = opr[1:0];
	wire gather = op == OP_TEXL && opr[3];
	wire qlod = op == OP_TEXB && opr[6];
	wire nlevq = op == OP_TEXSZ && opr[6] && !opr[3];
	wire dszq = op == OP_TEXSZ && opr[3] && !opr[6];
	wire smpq = op == OP_TEXSZ && opr[6] && opr[3];	/* texsz.s */
	wire nofetch = op == OP_TEXSZ || qlod;

	wire cmp = r_depth && r_samp_cmp && !op[1] && !qlod;
	wire filt = r_legacy ? !r_depth || cmp : r_fc[6] || cmp;
	wire f32 = !r_legacy && !nofetch && !(r_fc[5] || cmp);	/* the fp32 path */
	wire [1:0] gwi = f32 && gather ? tu_gwi(r_tfmt, opr[5:4]) : 2'd0;
`ifdef CFG_ENABLE_TRILINEAR
	wire miplin = filt && !gather && !r_unn && r_samp_miplin;
`else
	wire miplin = 1'b0;
`endif

	/* Cube Projections */
	wire n_lod = cube && tx_op[1:0] == OP_TEXB;
	wire n_lane = cube && !tx_op[1] && !tx_op[6];
	wire [1:0] jm2;
	wire [2:0] job1;
	wire [1:0] carry_unused;
	am_sub #(.W(2)) u_jm2 (.a(job[1:0]), .b(2'd2), .bi(1'b0), .d(jm2), .bo(carry_unused[0]));
	am_add #(.W(3)) u_job1 (.a(job), .b(3'd0), .ci(1'b1), .s(job1), .co(carry_unused[1]));
	wire [1:0] jlane = job[2] || job == 3'd3 ? jm2 : job[1:0];
	wire jfix = job == 3'd1 || job == 3'd2;
	wire [2:0] jnext = job == 3'd0 && !cb_lod ? 3'd3 : job == 3'd2 && !cb_lane ? 3'd6 : job1;

	wire [159:0] jcrd = jlane[1] ? (jlane[0] ? crd[480 +: 160] : crd[320 +: 160]) :
		(jlane[0] ? crd[160 +: 160] : crd[0 +: 160]);
`ifdef CFG_ENABLE_3D_CUBE
	wire c_bsy;
	wire [2:0] c_face;
	wire signed [26:0] c_s, c_t;
	atg_tu_cube cubeu (
		.clk(clk), .rst_n(rst_n), .go(st == CUBE),
		.x(jcrd[0 +: 32]), .y(jcrd[32 +: 32]), .z(jcrd[128 +: 32]), .fix(jfix), .fface(cf[0]),
		.bsy(c_bsy), .face(c_face), .s(c_s), .t(c_t)
	);
`else
	wire c_bsy = 1'b0;
	wire [2:0] c_face = 3'd0;
	wire signed [26:0] c_s = 27'sd0;
	wire signed [26:0] c_t = 27'sd0;
`endif

	/* Parallel Quad LOD Evaluation across u, v, w axes (LAT=4) */
	wire signed [16:0] lam_u, lam_v, lam_w;
	atg_tu_lod #(.LAT(4)) lodu_u (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d), .cube(r_cube),
		.w0(r_w0), .h0(r_h0), .d0(r_cnt), .ax(2'd0), .lam(lam_u)
	);
	atg_tu_lod #(.LAT(4)) lodu_v (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d), .cube(r_cube),
		.w0(r_w0), .h0(r_h0), .d0(r_cnt), .ax(2'd1), .lam(lam_v)
	);
	atg_tu_lod #(.LAT(4)) lodu_w (
		.clk(clk), .rst_n(rst_n), .en(1'b1),
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(r_is3d), .cube(r_cube),
		.w0(r_w0), .h0(r_h0), .d0(r_cnt), .ax(2'd2), .lam(lam_w)
	);
	wire signed [16:0] lam_uv = lam_u > lam_v ? lam_u : lam_v;
	wire signed [16:0] lam_quad = lam_uv > lam_w ? lam_uv : lam_w;

	/* 4 Lanes Parallel Stage A and Stage B */
	wire signed [16:0] lam1_l [0:3];
	wire signed [16:0] lraw_w [0:3];
	wire signed [16:0] lam_l [0:3];
	wire lin_l [0:3];
	wire [7:0] fl_l [0:3];
	wire signed [16:0] lamp_l [0:3];
	wire [15:0] dq_l [0:3];
	wire [15:0] wl_l [0:3], hl_l [0:3], dl_l [0:3], hl1_l [0:3];
	wire signed [30:0] cu_l [0:3], cv_l [0:3], cwz_l [0:3];
	wire [31:0] lbase_n_l [0:3], val_l [0:3];
	wire [31:0] lb1_w_l [0:3];
	wire [15:0] lay_w [0:3];

	wire [127:0] f_addr_l [0:3];
	wire [3:0]   f_bord_l [0:3];
	wire [15:0]  f_fuv_l [0:3];
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
		wire [31:0] cw0 = crd[160*gl + 0 +: 32];
		wire [31:0] cw1 = crd[160*gl + 32 +: 32];
		wire [31:0] cw2 = crd[160*gl + 64 +: 32];
		wire [31:0] cw3 = crd[160*gl + 96 +: 32];
		wire [31:0] cw4 = crd[160*gl + 128 +: 32];

		/* Stage A0: FP32 to Fix32 for cw2 (LAT=1) */
		wire [31:0] lfx_w;
		atg_tu_fx32 #(.LAT(1)) u_lfx (.clk(clk), .rst_n(rst_n), .en(1'b1), .f(cw2), .sh(5'd8), .q(lfx_w));
		assign lam1_l[gl] = tu_sat16({lfx_w[31], lfx_w});

		/* Stage A0B: LOD Raw Selection (using r_lam_quad and r_lam1) */
		wire [32:0] lsum;
		am_add #(.W(33)) u_lsum (
			.a({{16{r_lam_quad[16]}}, r_lam_quad}),
			.b({{16{r_lam1[gl][16]}}, r_lam1[gl]}),
			.ci(1'b0), .s(lsum), .co(lsum_carry_unused[gl*2 + 0])
		);
		assign lraw_w[gl] = op != OP_TEXB ? r_lam1[gl] : qlod ? r_lam_quad : tu_sat16(lsum);

		/* Stage A0C: LOD Bias Accumulation & Clamp (using r_lraw) */
		wire [32:0] bsum;
		am_add #(.W(33)) u_bsum (
			.a({{16{r_lraw[gl][16]}}, r_lraw[gl]}),
			.b({{16{r_sbias[16]}}, r_sbias}),
			.ci(1'b0), .s(bsum), .co(lsum_carry_unused[gl*2 + 1])
		);
		assign lamp_l[gl] = r_unn ? 17'sd0 : tu_sat16(bsum);
		wire signed [16:0] lamc = lamp_l[gl] > r_maxlod ? r_maxlod : lamp_l[gl];
		assign lam_l[gl] = r_unn ? 17'sd0 : lamc < r_minlod ? r_minlod : lamc;

		/* Stage A1: Level Selection & Rounding (using r_lam) */
		wire mag = !(r_lam[gl] > 17'sd0);
		wire signed [16:0] lmaxf = $signed({5'd0, r_maxl, 8'd0});
		assign dq_l[gl] = r_lam[gl] < 0 ? 16'd0 : r_lam[gl] > lmaxf ? lmaxf[15:0] : r_lam[gl][15:0];
		wire [16:0] lrnd;
		wire [3:0] lnx;
		am_add #(.W(17)) u_lrnd (.a(r_lam[gl]), .b(17'd127), .ci(1'b0), .s(lrnd), .co(lvl_carry_unused[gl*2 + 0]));
		am_add #(.W(4)) u_lnx (.a(r_lam[gl][11:8]), .b(4'd0), .ci(pas[1]), .s(lnx), .co(lvl_carry_unused[gl*2 + 1]));
		wire [3:0] lmin = lrnd[15:8] > {4'd0, r_maxl} ? r_maxl : lrnd[11:8];
		wire lend = r_lam[gl][15:8] >= {4'd0, r_maxl};
		wire [3:0] llin = lend ? r_maxl : lnx;
		assign fl_l[gl] = !mag && miplin && !lend ? r_lam[gl][7:0] : 8'd0;
		wire [3:0] lfetch = cw2[31] ? 4'd0 : cw2[30:0] > {27'd0, r_maxl} ? r_maxl : cw2[3:0];
		wire [3:0] lsize = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
		assign lvl_l[gl] = op == OP_TEXSZ ? lsize : op == OP_TEXF ? (r_ms ? 4'd0 : lfetch) : gather || mag ? 4'd0 :
			miplin ? llin : lmin;
		assign lin_l[gl] = op[1] || qlod ? 1'b0 : gather ? 1'b1 : filt && (mag ? r_samp_mag_lin : r_samp_min_lin);
		assign lrnd_unused[gl] = {lrnd[16], lrnd[7:0]};
		assign lmaxf_unused[gl] = lmaxf[16];

		wire [15:0] wl_s_nxt, hl_s_nxt, dl_s_nxt;
		am_shift #(.W(16), .SW(4)) u_wl_s (.a(r_w0), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(wl_s_nxt));
		am_shift #(.W(16), .SW(4)) u_hl_s (.a(r_h0), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(hl_s_nxt));
		am_shift #(.W(16), .SW(4)) u_dl_s (.a(r_cnt), .amt(r_lvl[gl]), .left(1'b0), .arith(1'b0), .y(dl_s_nxt));

		wire [15:0] wl_nxt = wl_s_nxt == 16'd0 ? 16'd1 : wl_s_nxt;
		wire [15:0] hl1_nxt = hl_s_nxt == 16'd0 ? 16'd1 : hl_s_nxt;
		wire [15:0] hl_nxt = r_cube ? wl_nxt : hl1_nxt;
		wire [15:0] dl_nxt = !r_is3dr || dl_s_nxt == 16'd0 ? 16'd1 : dl_s_nxt;
		assign wl_l[gl] = wl_nxt;
		assign hl_l[gl] = hl_nxt;
		assign dl_l[gl] = dl_nxt;
		assign hl1_l[gl] = hl1_nxt;

		atg_tu_tcrd #(.LAT(1)) u_tcrd (
			.clk(clk), .rst_n(rst_n), .en(1'b1),
			.cw0(cw0), .cw1(cw1), .cw4(cw4), .mu(r_mu), .mv(r_mv), .mw(r_mw),
			.wl(r_wl[gl]), .hl(r_hl[gl]), .dl(r_dl[gl]),
			.fcs(cs[gl]), .fct(ct[gl]), .cube(r_cube), .unn(r_unn),
			.cu(cu_l[gl]), .cv(cv_l[gl]), .cw(cwz_l[gl])
		);

		wire [31:0] sfl = cw4[31] ? 32'd0 : cw4;
		wire [15:0] cnt1, lyr;
		atg_tu_layer #(.LAT(1)) u_lyr (.clk(clk), .rst_n(rst_n), .en(1'b1), .f(cw4), .cnt(r_cnt), .l(lyr));
		am_sub #(.W(16)) u_cnt1 (.a(r_cnt), .b(16'd0), .bi(1'b1), .d(cnt1), .bo(cnt1_bo_unused[gl]));

		wire [15:0] lay = op == OP_TEXF ? (r_arr ? (sfl >= {16'd0, r_cnt} ? cnt1 : sfl[15:0]) :
			r_cube ? (sfl > 32'd5 ? 16'd5 : sfl[15:0]) : 16'd0) : r_arr ? lyr : 16'd0;
		assign lay_w[gl] = lay;
		am_mul #(.AW(32), .BW(16), .LAT(1)) u_lstr (.clk(clk), .en(1'b1), .a(r_stride), .b(r_lay[gl]), .p(lstr_l[gl]));

		wire [31:0] lb1_w;
		am_add #(.W(32)) u_lb1 (.a(r_base), .b(r_lstr[gl]), .ci(1'b0), .s(lb1_w), .co(lb1_co_unused[gl]));
		assign lb1_w_l[gl] = lb1_w;
		am_add #(.W(32)) u_lbase (.a(r_lb1[gl]), .b(loff_l[gl]), .ci(1'b0), .s(lbase_n_l[gl]),
			.co(lbase_co_unused[gl]));

		wire [15:0] dsz = r_arr ? r_cnt : r_is3d ? r_dl[gl] : 16'd1;
		assign val_l[gl] = smpq ? (r_ms ? 32'd4 : 32'd1) : nlevq ? {28'd0, r_nlev} : dszq ? {16'd0, dsz} :
			op == OP_TEXSZ ? {r_hl1[gl], r_wl[gl]} : qlod ? {r_lamp[gl][15:0], r_dq[gl]} :
			cmp ? cw3 : 32'd0;

		/* Stage B: Footprint and address expansion (LAT=4) */
		atg_tu_foot #(.LAT(4)) u_foot (
			.clk(clk), .rst_n(rst_n), .en(1'b1),
			.op(op), .gather(gather), .cube(r_cube), .is3d(r_is3d), .tiled(r_tiled), .lin(r_lin[gl]),
			.ms(r_ms), .smp(crd[160*gl + 64 +: 2]), .psl(r_psl), .ra(r_rowa), .blk(r_blk),
			.row(pas[2]), .col(pas[3]), .gwi(gwi), .p0(pas[0]),
			.mu(r_mu), .mv(r_mv), .mw(r_mw), .off(r_cube ? 12'd0 : offs),
			.x(crd[160*gl + 0 +: 32]), .y(crd[160*gl + 32 +: 32]), .z(crd[160*gl + 128 +: 32]),
			.cu(cu_l[gl]), .cv(cv_l[gl]), .cw(cwz_l[gl]),
			.wl(r_wl[gl]), .hl(r_hl[gl]), .dl(r_dl[gl]), .face(cf[gl]),
			.lbase(r_lbase[gl]), .plane(r_plane[gl]),
			.stride(r_stride), .addr(f_addr_l[gl]), .bord(f_bord_l[gl]),
			.fuv(f_fuv_l[gl]), .fw(f_fw_l[gl])
		);
	end
	endgenerate

	/* Multi-pass calculation */
	wire split = f32 && r_psl == 3'd3 && linq && (r_blk || !gather);
	wire quad = f32 && r_psl == 3'd4 && r_blk && linq;	/* 16-byte blocks: 4 passes */
	wire [2:0] nxb = pas[1:0] == 2'd0 ? (depf ? 3'd1 : mipf ? 3'd2 : 3'd4) :
		pas[1:0] == 2'd1 ? (mipf ? 3'd2 : 3'd4) : pas[1:0] == 2'd2 ? (depf ? 3'd3 : 3'd4) : 3'd4;
	wire [4:0] nxt = quad && !pas[3] ? {2'b01, pas[2:0]} : quad && !pas[2] ? {3'b001, pas[1:0]} :
		split && !pas[2] ? {3'b001, pas[1:0]} : {nxb[2], 2'b00, nxb[1:0]};

	assign tx_ready = st == IDLE && !desc_busy;
	assign ta_valid = st == OUT;

	wire [1:0] tsz = r_legacy ? 2'd0 : r_psl == 3'd0 ? 2'd2 : r_psl == 3'd1 ? 2'd1 : 2'd0;
	wire [1:0] nsl = r_psl == 3'd3 ? 2'd1 : r_psl == 3'd4 ? 2'd2 : 2'd0;
	wire [7:0] vkf = r_legacy || r_fc[4] ? 8'd0 : r_tfmt[7:0];
	assign ta_ctl = {quad, pas[3], r_tfmt[20:9], r_fc[8], vkf, nsl, tsz, pas[2], split, f32, r_f565,
		pas[1:0], qlod, gather ? opr[5:4] : 2'd0, gather, r_cmp_op, cmp, r_depth, r_bcls, pas != 4'd0,
		!nxt[4],
		op == OP_TEXF, nofetch, r_fc[9], linq};

	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			opr <= 8'd0;
			slot <= 5'd0;
			samp_slot <= 5'd0;
			crd <= 640'd0;
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
			ta_addr <= 512'd0;
			ta_bord <= 16'd0;
			ta_wts <= 128'd0;
			ta_value <= 128'd0;
			r_lam_quad <= 17'sd0;
			r_base <= 32'd0;
			r_stride <= 32'd0;
			r_w0 <= 16'd0;
			r_h0 <= 16'd0;
			r_cnt <= 16'd0;
			r_nlev <= 4'd0;
			r_maxl <= 4'd0;
			r_fc <= 13'd0;
			r_legacy <= 1'b0;
			r_depth <= 1'b0;
			r_blk <= 1'b0;
			r_psl <= 3'd0;
			r_f565 <= 1'b0;
			r_ms <= 1'b0;
			r_tiled <= 1'b0;
			r_unn <= 1'b0;
			r_is3dr <= 1'b0;
			r_arr <= 1'b0;
			r_is3d <= 1'b0;
			r_cube <= 1'b0;
			r_minlod <= 17'sd0;
			r_maxlod <= 17'sd0;
			r_sbias <= 17'sd0;
			r_mu <= 2'd0;
			r_mv <= 2'd0;
			r_mw <= 2'd0;
			r_samp_cmp <= 1'b0;
			r_samp_mag_lin <= 1'b0;
			r_samp_min_lin <= 1'b0;
			r_samp_miplin <= 1'b0;
			r_cmp_op <= 3'd0;
			r_bcls <= 2'd0;
			r_rowa <= 2'd0;
			r_tfmt <= 21'd0;
			for (k = 0; k < 4; k = k + 1) begin
				cf[k] <= 3'd0;
				cs[k] <= 27'sd0;
				ct[k] <= 27'sd0;
				r_lam1[k] <= 17'sd0;
				r_lraw[k] <= 17'sd0;
				r_lam[k] <= 17'sd0;
				r_lay[k] <= 16'd0;
				r_lstr[k] <= 32'd0;
				r_lb1[k] <= 32'd0;
				r_lvl[k] <= 4'd0;
				r_lin_a[k] <= 1'b0;
				r_fl_a[k] <= 8'd0;
				r_lamp[k] <= 17'sd0;
				r_dq[k] <= 16'd0;
				r_lin[k] <= 1'b0;
				r_fl[k] <= 8'd0;
				r_wl[k] <= 16'd0;
				r_hl[k] <= 16'd0;
				r_dl[k] <= 16'd0;
				r_hl1[k] <= 16'd0;
				r_lbase[k] <= 32'd0;
				r_plane[k] <= 32'd0;
				r_val[k] <= 32'd0;
			end
			ls1 <= 27'sd0;
			lt1 <= 27'sd0;
			ls2 <= 27'sd0;
			lt2 <= 27'sd0;
		end else begin
			case (st)
			IDLE: if (tx_valid && !desc_busy) begin
				opr <= tx_op;
				slot <= {tx_vs, tx_slot};
				samp_slot <= {tx_vs, tx_samp_slot};
				crd <= tx_coord;
				offs <= tx_off;
				ta_mask <= tx_mask;
				ta_tag <= tx_tag;
				ta_last <= tx_last;
				pas <= 4'd0;
				linq <= 1'b0;
				depf <= 1'b0;
				mipf <= 1'b0;
				cb_lod <= n_lod;
				cb_lane <= n_lane;
				job <= 3'd0;
				r_base <= base;
				r_stride <= stride;
				r_w0 <= w0;
				r_h0 <= h0;
				r_cnt <= cnt;
				r_nlev <= nlev;
				r_maxl <= maxl;
				r_fc <= fc;
				r_legacy <= legacy;
				r_depth <= depth;
				r_blk <= blk;
				r_psl <= psl;
				r_f565 <= f565;
				r_ms <= ms;
				r_tiled <= tiled;
				r_unn <= unn;
				r_is3dr <= is3dr;
				r_arr <= arr;
				r_is3d <= is3d;
				r_cube <= cube;
				r_minlod <= minlod;
				r_maxlod <= maxlod;
				r_sbias <= sbias;
				r_mu <= mu;
				r_mv <= mv;
				r_mw <= mw;
				r_samp_cmp <= samp_cmp;
				r_samp_mag_lin <= mag_lin;
				r_samp_min_lin <= min_lin;
				r_samp_miplin <= samp_miplin;
				r_cmp_op <= cmp_op;
				r_bcls <= bcls;
				r_rowa <= rowa;
				r_tfmt <= tfmt;
				st <= n_lod || n_lane ? CUBE : LA0;
			end
			CUBE: st <= CWAIT;
			CWAIT: if (!c_bsy) begin
				if (job == 3'd1) begin
					ls1 <= c_s;
					lt1 <= c_t;
				end else if (job == 3'd2) begin
					ls2 <= c_s;
					lt2 <= c_t;
				end else begin
					cf[jlane] <= c_face;
					cs[jlane] <= c_s;
					ct[jlane] <= c_t;
				end
				job <= jnext;
				st <= jnext != 3'd6 ? CUBE : LA0;
			end
			LA0: begin
				/* u_lfx Stage 0 registers at posedge clk */
				st <= LA0B;
			end
			LA0B: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lam1[k] <= lam1_l[k];
					r_lay[k]  <= lay_w[k];
				end
				st <= LA0BB;
			end
			LA0BB: begin
				st <= LA0BC;
			end
			LA0BC: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lstr[k] <= lstr_l[k][31:0];
				end
				st <= LA0C;
			end
			LA0C: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lb1[k] <= lb1_w_l[k];
				end
				r_lam_quad <= lam_quad;
				st <= LA0D;
			end
			LA0D: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lraw[k] <= lraw_w[k];
				end
				st <= LA0E;
			end
			LA0E: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lam[k]  <= lam_l[k];
					r_lamp[k] <= lamp_l[k];
				end
				st <= LA1;
			end
			LA1: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lvl[k]   <= lvl_l[k];
					r_lin_a[k] <= lin_l[k];
					r_fl_a[k]  <= op[1] || qlod ? 8'd0 : fl_l[k];
					r_lamp[k]  <= lamp_l[k];
					r_dq[k]    <= dq_l[k];
				end
				st <= LA1B;
			end
			LA1B: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_wl[k]    <= wl_l[k];
					r_hl[k]    <= hl_l[k];
					r_dl[k]    <= dl_l[k];
					r_hl1[k]   <= hl1_l[k];
				end
				st <= LA2;
			end
			LA2: begin
				for (k = 0; k < 4; k = k + 1) begin
					r_lin[k]   <= r_lin_a[k];
					r_fl[k]    <= r_fl_a[k];
					r_lbase[k] <= lbase_n_l[k];
					r_plane[k] <= plane_l[k];
					r_val[k]   <= val_l[k];
				end
				st <= LB0;
			end
			LB0: begin
				/* u_foot Stage 0A registers at posedge clk */
				st <= LB1;
			end
			LB1: begin
				/* u_foot Stage 0B registers at posedge clk */
				st <= LB2;
			end
			LB2: begin
				/* u_foot Stage 1A registers at posedge clk */
				st <= LB2B;
			end
			LB2B: begin
				/* u_foot Stage 1B registers at posedge clk */
				st <= LB3;
			end
			LB3: begin
				for (k = 0; k < 4; k = k + 1) begin
					ta_addr[k*128 +: 128]  <= nofetch ? 128'd0 : f_addr_l[k];
					ta_bord[k*4 +: 4]      <= nofetch ? 4'd0 : f_bord_l[k];
					ta_wts[k*32 +: 32]     <= {f_fw_l[k], r_fl[k], r_lin[k] ? f_fuv_l[k] : 16'd0};
					ta_value[k*32 +: 32]   <= r_val[k];
				end
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
					st <= LA1;
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
	wire unused_cube_signals = &{1'b0, jcrd[159:128], jcrd[63:0], jfix};
`endif

	wire unused_ok = &{1'b0, fc[11:10], jcrd[127:64],
		samp[18:17], bcol[0], opr[7], opr[2],
		dlod[31:24], OP_TEXL,
		cnt1_bo_unused, lb1_co_unused, lbase_co_unused,
		lsum_carry_unused, lvl_carry_unused,
		lrnd_unused[0], lrnd_unused[1], lrnd_unused[2], lrnd_unused[3], lmaxf_unused,
		r_lam_quad,
		lamp_l[0][16], lamp_l[1][16], lamp_l[2][16], lamp_l[3][16],
		r_lamp[0][16], r_lamp[1][16], r_lamp[2][16], r_lamp[3][16],
		lstr_l[0][47:32], lstr_l[1][47:32], lstr_l[2][47:32], lstr_l[3][47:32],
		cube_edge_fout, cube_edge_uout, cube_edge_vout, unused_cube_signals};
endmodule

`default_nettype wire
