/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_addr: TU addressing: per quad, the slot's descriptor, level of
 * detail (texl explicit, texb from the quad derivatives + bias, texf
 * level), mip selection, the layer (2D array), the slice (3D), the face
 * (cube), wrap on integer texel coordinates after the texel offsets,
 * clamp to border, cube edges, bilinear footprint, texel byte addresses
 * (linear or 4×4 tiled), the reference of a compare sampler, and texsz.
 *
 * Children: atg_tu_desc (the descriptors and their level offsets),
 * atg_tu_cube (cube faces), atg_tu_lod (texb's quad LOD), atg_tu_foot (a
 * lane's footprint and addresses).
 * Takes one quad (tx_*) in IDLE while atg_tu_desc is not busy.  A cube
 * quad that samples first has each lane's face and face coordinates
 * computed by atg_tu_cube, one lane at a time; texb (and texqlod) on a
 * cube also lanes 1 and 2 projected on lane 0's face for the LOD.  Then
 * lane by lane (two cycles a lane: A the LOD, level, sizes, texel
 * coordinates, layer and level base; B the footprint) into ta_*, held
 * until taken.  Passes: 0; 1, the second slice of 3D linear filtering,
 * when a lane of tx_mask has a weight fw; 2, the second level of mip
 * linear filtering, when one has a weight fl; 3, both, when a lane's fw at
 * the second level is not 0.  ta_ctl[4] says a later pass follows, [5]
 * that this is not the first, [18:17] which pass it is.
 * Numbers (tools/tumodel.py is the reference, bit for bit; the functions
 * are in include/atg_tu_fn.vh):
 *   λ: signed, 8 fraction bits, saturated to 16 bits; texl floor(lod ×
 *   256), texb the quad's (atg_tu_lod) plus floor(bias × 256), then the
 *   sampler's mipLodBias, then clamped to [minLod, maxLod]; 0 with
 *   unnormalized coordinates.  λ > 0 minifies (SAMPLER min filter), mip
 *   nearest level (λ + 127) >> 8, mip linear levels λ >> 8 and one more
 *   with the weight λ & 255; otherwise level 0 and the mag filter.  A depth
 *   format without compare is nearest only.
 *   Texel coordinates with 8 fraction bits: (the normalized coordinate's
 *   tu_coord) × size >> 16, a cube's face coordinate × size >> 16, or an
 *   unnormalized coordinate's floor(x × 256).
 *   Layer: a 2D array's RNE(rs1+2) clamped (texf: the integer, also of a
 *   cube); level base = BASE + layer × LAYER_STRIDE + the level's offset.
 *   texsz: word 0 = level (unsigned, clamped to 15): {h, w}; texsz.l the
 *   level count; texsz.d the layer count (array), the level's depth (3D),
 *   else 1.
 * Lanes outside tx_mask are computed too (the cache does not fetch them).
 * See spec/gpu/tu/atg_tu_addr.md.
 *
 * States: IDLE →(tx)→ [CUBE ⇄ CWAIT (cube lanes)] → [LOD (texb)] → LA →
 * LB → LA … (lanes 0-3) → OUT →(ta_ready)→ IDLE, or LA (the next pass).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_addr (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	output wire desc_busy,
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [7:0] tx_op,
	input wire [3:0] tx_slot,
	input wire [3:0] tx_mask,
	input wire [639:0] tx_coord,
	input wire [11:0] tx_off,
	input wire [15:0] tx_tag,
	input wire tx_last,
	/* To atg_tu_cache */
	output wire ta_valid,
	input wire ta_ready,
	output reg [511:0] ta_addr,
	output reg [127:0] ta_wts,
	output reg [15:0] ta_tag,
	output reg [3:0] ta_mask,
	output wire [23:0] ta_ctl,
	output reg [127:0] ta_value,
	output reg ta_last
);
	`include "ghci_regs.vh"
	`include "atg_tu_fn.vh"
	localparam [1:0] OP_TEXL = 2'd0, OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;
	localparam [2:0] IDLE = 3'd0, CUBE = 3'd1, CWAIT = 3'd2, LOD = 3'd3, LA = 3'd4, LB = 3'd5,
		OUT = 3'd6;

	reg [2:0] st;
	reg [1:0] k, pas;
	reg [7:0] opr;
	reg [3:0] slot;
	reg [639:0] crd;
	reg [11:0] offs;
	reg signed [16:0] lam_q;
	reg linq, depf, mipf;
	reg cb_lod, cb_lane;	/* a cube quad: the LOD projections, the lanes' own */
	reg [2:0] job;	/* the cube projection being computed (below) */
	reg [2:0] cf [0:3];	/* cube: each lane's face, s, t */
	reg signed [26:0] cs [0:3];
	reg signed [26:0] ct [0:3];
	reg signed [26:0] ls1, lt1, ls2, lt2;	/* lanes 1, 2 on lane 0's face (LOD) */
	/* Lane stage A → B. */
	reg r_lin;
	reg [7:0] r_fl;
	reg [15:0] r_wl, r_hl, r_dl;
	reg signed [30:0] r_cu, r_cv, r_cw;
	reg [31:0] r_lbase, r_plane, r_val;

	/* The descriptor of the quad's slot (of tx_slot in IDLE). */
	wire [3:0] lvl;
	wire [31:0] base, dsize, image, stride, samp, dlod, loff, plane;
	atg_tu_desc desc (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.busy(desc_busy), .rd_slot(st == IDLE ? tx_slot : slot), .rd_level(lvl),
		.rd_base(base), .rd_size(dsize), .rd_image(image), .rd_stride(stride),
		.rd_samp(samp), .rd_lod(dlod), .rd_loff(loff), .rd_plane(plane)
	);
	wire [15:0] w0 = dsize[15:0] == 16'd0 ? 16'd1 : dsize[15:0];
	wire [15:0] h0 = dsize[31:16] == 16'd0 ? 16'd1 : dsize[31:16];
	wire [3:0] nlev = image[3:0] == 4'd0 ? 4'd1 : image[3:0] > 4'd13 ? 4'd13 : image[3:0];
	wire [3:0] maxl = nlev - 4'd1;
	/* Format (4-15 read as RGBA8), view type (4-7 and unnormalized: 2D). */
	wire [1:0] fmt = image[GHCI_IMG_FMT + 2 +: 2] != 2'd0 ? 2'd0 : image[GHCI_IMG_FMT +: 2];
	wire depth = fmt[1];
	wire tiled = image[GHCI_IMG_TILED];
	wire unn = samp[GHCI_SAMP_UNNORM];
	wire [2:0] traw = image[GHCI_IMG_TYPE +: 3];
	wire is3dr = traw == 3'd2;	/* as written: the levels' depths */
	wire arr = !unn && traw == 3'd1, is3d = !unn && is3dr, cube = !unn && traw == 3'd3;
	wire [15:0] cnt = image[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : image[GHCI_IMG_COUNT +: 16];
	wire signed [16:0] minlod = $signed({5'd0, dlod[GHCI_TEX_MIN_LOD +: 12]});
	wire signed [16:0] maxlod = $signed({5'd0, 12'hFFF - dlod[GHCI_TEX_MAX_LOD +: 12]});
	wire signed [16:0] sbias = $signed({{4{samp[31]}}, samp[GHCI_SAMP_LOD_BIAS +: 13]});
	/* Unnormalized coordinates read repeat and mirrored repeat as clamp to edge. */
	wire [1:0] mu0 = samp[GHCI_SAMP_WRAP_U +: 2], mv0 = samp[GHCI_SAMP_WRAP_V +: 2];
	wire [1:0] mw0 = samp[GHCI_SAMP_WRAP_W +: 2];
	wire [1:0] mu = unn && !mu0[1] ? 2'd2 : mu0, mv = unn && !mv0[1] ? 2'd2 : mv0;
	wire [1:0] mw = unn && !mw0[1] ? 2'd2 : mw0;
	/* The operation and its modifiers (tx_op). */
	wire [1:0] op = opr[1:0];
	wire gather = op == OP_TEXL && opr[3];
	wire qlod = op == OP_TEXB && opr[6];
	wire nlevq = op == OP_TEXSZ && opr[6];
	wire dszq = op == OP_TEXSZ && opr[3];
	wire nofetch = op == OP_TEXSZ || qlod;
	/* Compare (texl, texb); filtering allowed; mip linear. */
	wire cmp = depth && samp[GHCI_SAMP_COMPARE] && !op[1] && !qlod;
	wire filt = !depth || cmp;
	wire miplin = filt && !gather && !unn && samp[GHCI_SAMP_MIP_LINEAR];
	wire [2:0] cmp_op = samp[GHCI_SAMP_COMPARE_OP +: 3];
	/* VkBorderColor >> 1: 0 transparent black, 1 opaque black, 2 opaque white. */
	wire [2:0] bcol = samp[GHCI_SAMP_BORDER +: 3];
	wire [1:0] bcls = bcol[2:1] == 2'd3 ? 2'd0 : bcol[2:1];

	/* A new quad (IDLE): the cube projections it needs.  Jobs: 0 lane 0;
	 * with the LOD 1 and 2, lanes 1 and 2 on lane 0's face; for the lanes'
	 * own 3-5, lanes 1-3; 6 done. */
	wire n_lod = cube && tx_op[1:0] == OP_TEXB;
	wire n_lane = cube && !tx_op[1] && !tx_op[6];
	wire [1:0] jlane = job[2] || job == 3'd3 ? job[1:0] - 2'd2 : job[1:0];
	wire jfix = job == 3'd1 || job == 3'd2;
	wire [2:0] jnext = job == 3'd0 && !cb_lod ? 3'd3 : job == 3'd2 && !cb_lane ? 3'd6 :
		job + 3'd1;
	wire c_bsy;
	wire [2:0] c_face;
	wire signed [26:0] c_s, c_t;
	atg_tu_cube cubeu (
		.clk(clk), .rst_n(rst_n), .go(st == CUBE),
		.x(crd[jlane*160 +: 32]), .y(crd[jlane*160 + 32 +: 32]),
		.z(crd[jlane*160 + 128 +: 32]), .fix(jfix), .fface(cf[0]),
		.bsy(c_bsy), .face(c_face), .s(c_s), .t(c_t)
	);
	wire signed [16:0] lam_quad;
	atg_tu_lod lodu (
		.u({crd[320 +: 32], crd[160 +: 32], crd[0 +: 32]}),
		.v({crd[352 +: 32], crd[192 +: 32], crd[32 +: 32]}),
		.w({crd[448 +: 32], crd[288 +: 32], crd[128 +: 32]}),
		.cs({ls2, ls1, cs[0]}), .ct({lt2, lt1, ct[0]}), .is3d(is3d), .cube(cube),
		.w0(w0), .h0(h0), .d0(cnt), .lam(lam_quad)
	);

	/* Stage A of lane k. */
	wire [31:0] cw0 = crd[k*160 +: 32], cw1 = crd[k*160 + 32 +: 32];
	wire [31:0] cw2 = crd[k*160 + 64 +: 32], cw3 = crd[k*160 + 96 +: 32];
	wire [31:0] cw4 = crd[k*160 + 128 +: 32];
	wire [31:0] lfx = tu_fx32(cw2, 5'd8);
	wire signed [16:0] lam1 = tu_sat16({lfx[31], lfx});
	/* λ': the LOD (texl rs2; texb the quad's plus the bias rs2, none for the
	 * query) plus mipLodBias; λ = max(min(λ', maxLod), minLod). */
	wire signed [16:0] lraw = op != OP_TEXB ? lam1 : qlod ? lam_q :
		tu_sat16({{16{lam_q[16]}}, lam_q} + {{16{lam1[16]}}, lam1});
	wire signed [16:0] lamp = unn ? 17'sd0 :
		tu_sat16({{16{lraw[16]}}, lraw} + {{16{sbias[16]}}, sbias});
	wire signed [16:0] lamc = lamp > maxlod ? maxlod : lamp;
	wire signed [16:0] lam = unn ? 17'sd0 : lamc < minlod ? minlod : lamc;
	wire mag = !(lam > 17'sd0);
	/* The query: the level accessed, clamp(λ, 0, LEVELS − 1). */
	wire signed [16:0] lmaxf = $signed({5'd0, maxl, 8'd0});
	wire [15:0] dq = lam < 0 ? 16'd0 : lam > lmaxf ? lmaxf[15:0] : lam[15:0];
	wire [16:0] lrnd = lam + 17'd127;
	wire [3:0] lmin = lrnd[15:8] > {4'd0, maxl} ? maxl : lrnd[11:8];
	wire lend = lam[15:8] >= {4'd0, maxl};
	wire [3:0] llin = lend ? maxl : lam[11:8] + {3'd0, pas[1]};
	wire [7:0] fl = !mag && miplin && !lend ? lam[7:0] : 8'd0;
	wire [3:0] lfetch = cw2[31] ? 4'd0 : cw2[30:0] > {27'd0, maxl} ? maxl : cw2[3:0];
	wire [3:0] lsize = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
	assign lvl = op == OP_TEXSZ ? lsize : op == OP_TEXF ? lfetch : gather || mag ? 4'd0 :
		miplin ? llin : lmin;
	wire lin = op[1] || qlod ? 1'b0 : gather ? 1'b1 :
		filt && (mag ? samp[GHCI_SAMP_MAG_LINEAR] : samp[GHCI_SAMP_MIN_LINEAR]);
	wire [15:0] wl_s = w0 >> lvl, hl_s = h0 >> lvl, dl_s = cnt >> lvl;
	wire [15:0] wl = wl_s == 16'd0 ? 16'd1 : wl_s;
	wire [15:0] hl1 = hl_s == 16'd0 ? 16'd1 : hl_s;
	wire [15:0] hl = cube ? wl : hl1;	/* a cube's faces are squares of the width */
	wire [15:0] dl = !is3dr || dl_s == 16'd0 ? 16'd1 : dl_s;
	/* The texel coordinates with 8 fraction bits. */
	wire signed [46:0] pu = tu_coord(cw0, mu) * $signed({1'b0, wl});
	wire signed [46:0] pv = tu_coord(cw1, mv) * $signed({1'b0, hl});
	wire signed [46:0] pw = tu_coord(cw4, mw) * $signed({1'b0, dl});
	wire signed [43:0] qu = cs[k] * $signed({1'b0, wl}), qv = ct[k] * $signed({1'b0, wl});
	wire signed [29:0] un0 = tu_unnorm(cw0), un1 = tu_unnorm(cw1);
	wire signed [30:0] cu = cube ? {{3{qu[43]}}, qu[43:16]} : unn ? {un0[29], un0} : pu[46:16];
	wire signed [30:0] cv = cube ? {{3{qv[43]}}, qv[43:16]} : unn ? {un1[29], un1} : pv[46:16];
	/* The lane's layer: a 2D array's; texf's integer layer of an array or a
	 * cube (a cube's face is chosen per texel in atg_tu_foot). */
	wire [31:0] sfl = cw4[31] ? 32'd0 : cw4;
	wire [15:0] lay = op == OP_TEXF ? (arr ? (sfl >= {16'd0, cnt} ? cnt - 16'd1 : sfl[15:0]) :
		cube ? (sfl > 32'd5 ? 16'd5 : sfl[15:0]) : 16'd0) : arr ? tu_layer(cw4, cnt) : 16'd0;
	wire [47:0] lstr = {16'd0, stride} * {32'd0, lay};
	/* texsz.d: an array's layer count, a 3D level's depth, otherwise 1. */
	wire [15:0] dsz = arr ? cnt : is3d ? dl : 16'd1;

	/* The next pass: 1 if a lane needs a second slice, 2 a second level, 3
	 * (after 2) a second slice there; 4 none. */
	wire [2:0] nxt = pas == 2'd0 ? (depf ? 3'd1 : mipf ? 3'd2 : 3'd4) :
		pas == 2'd1 ? (mipf ? 3'd2 : 3'd4) : pas == 2'd2 ? (depf ? 3'd3 : 3'd4) : 3'd4;

	/* Stage B of lane k. */
	wire [127:0] f_addr;
	wire [15:0] f_fuv;
	wire [7:0] f_fw;
	atg_tu_foot foot (
		.op(op), .gather(gather), .cube(cube), .is3d(is3d), .tiled(tiled), .lin(r_lin),
		.p0(pas[0]), .mu(mu), .mv(mv), .mw(mw), .off(cube ? 12'd0 : offs),
		.x(cw0), .y(cw1), .z(cw4), .cu(r_cu), .cv(r_cv), .cw(r_cw),
		.wl(r_wl), .hl(r_hl), .dl(r_dl), .face(cf[k]), .lbase(r_lbase), .plane(r_plane),
		.stride(stride), .addr(f_addr), .fuv(f_fuv), .fw(f_fw)
	);

	assign tx_ready = st == IDLE && !desc_busy;
	assign ta_valid = st == OUT;
	assign ta_ctl = {5'd0, pas, qlod, gather ? opr[5:4] : 2'd0, gather, cmp_op, cmp, depth, bcls,
		pas != 2'd0, nxt != 3'd4, op == OP_TEXF, nofetch, fmt[0], linq};

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (tx_valid && !desc_busy) begin
				opr <= tx_op;
				slot <= tx_slot;
				crd <= tx_coord;
				offs <= tx_off;
				ta_mask <= tx_mask;
				ta_tag <= tx_tag;
				ta_last <= tx_last;
				k <= 2'd0;
				pas <= 2'd0;
				linq <= 1'b0;
				depf <= 1'b0;
				mipf <= 1'b0;
				cb_lod <= n_lod;
				cb_lane <= n_lane;
				job <= 3'd0;
				st <= n_lod || n_lane ? CUBE : tx_op[1:0] == OP_TEXB ? LOD : LA;
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
				st <= jnext != 3'd6 ? CUBE : op == OP_TEXB ? LOD : LA;
			end
			LOD: begin
				lam_q <= lam_quad;
				st <= LA;
			end
			LA: begin
				r_lin <= lin;
				r_fl <= op[1] || qlod ? 8'd0 : fl;
				r_wl <= wl;
				r_hl <= hl;
				r_dl <= dl;
				r_cu <= cu;
				r_cv <= cv;
				r_cw <= pw[46:16];
				r_lbase <= base + lstr[31:0] + loff;
				r_plane <= plane;
				r_val <= nlevq ? {28'd0, nlev} : dszq ? {16'd0, dsz} :
					op == OP_TEXSZ ? {hl1, wl} : qlod ? {lamp[15:0], dq} :
					cmp ? cw3 : 32'd0;
				st <= LB;
			end
			LB: begin
				ta_addr[k*128 +: 128] <= nofetch ? 128'd0 : f_addr;
				ta_wts[k*32 +: 32] <= {f_fw, r_fl, r_lin ? f_fuv : 16'd0};
				ta_value[k*32 +: 32] <= r_val;
				if (r_lin && ta_mask[k])
					linq <= 1'b1;
				if (f_fw != 8'd0 && ta_mask[k])
					depf <= 1'b1;
				if (r_fl != 8'd0 && ta_mask[k])
					mipf <= 1'b1;
				k <= k + 2'd1;
				st <= k == 2'd3 ? OUT : LA;
			end
			OUT: if (ta_ready) begin
				linq <= 1'b0;
				depf <= 1'b0;
				mipf <= 1'b0;
				if (nxt != 3'd4) begin
					pas <= nxt[1:0];
					st <= LA;
				end else
					st <= IDLE;
			end
			default: st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, lrnd[16], lrnd[7:0], lamp[16], lmaxf[16], pu[15:0], pv[15:0],
		pw[15:0], qu[15:0], qv[15:0], lstr[47:32], samp[18:17], bcol[0], opr[7], opr[2],
		image[15:12], dlod[31:24], OP_TEXL};
endmodule

`default_nettype wire
