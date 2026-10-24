/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_addr: TU addressing: per quad, the slot's descriptor (STATE
 * 16s+0..15), level of detail (texl explicit, texb from the quad
 * derivatives + bias, texf level), mip selection, wrap modes, bilinear
 * footprint, texel byte addresses (linear or 4×4 tiled), and texsz.
 *
 * Takes one quad (tx_*) in IDLE, works lane by lane (two cycles per lane,
 * one more for texb's quad LOD) and holds the result on ta_* until taken.
 * With mip linear filtering (SAMPLER[6]) the quad goes out twice: pass 0
 * at level ⌊λ⌋ with ta_ctl[4] when a lane of tx_mask needs a second level,
 * then pass 1 at ⌊λ⌋ + 1 with ta_ctl[5]; each lane's weight of the second
 * level is in ta_wts (0 for a lane that needs one level only).
 * Numbers (tools/tumodel.py is the reference, bit for bit):
 *   LOD λ: signed, 8 fraction bits, saturated to 16 bits.  texl: floor(lod
 *   × 256); texb: the quad's λ (lanes 0, 1 = x + 1, 2 = y + 1: the largest
 *   |Δu| times the width and |Δv| times the height, log2 as msb + 8 bits
 *   below it, from u and v as floor(x × 2^16)) plus floor(bias × 256).
 *   A compare sampler (SAMPLER[7] on a depth format, texl and texb): rs2
 *   is the reference (passed on ta_value), λ = 0 for texl and the quad's
 *   λ without bias for texb.
 *   λ > 0: minification (SAMPLER[5] linear); mip nearest: level (λ + 127)
 *   >> 8 clamped to LEVELS − 1; mip linear: levels λ >> 8 and one more
 *   with the weight λ & 255 (one level, LEVELS − 1, at the end).  λ ≤ 0:
 *   magnification (SAMPLER[4]), level 0.  A depth format without compare
 *   is nearest only (no filter, mip nearest).
 *   Wrap (2 bits: 0 repeat, 1 mirrored repeat, 2 clamp to edge, 3 clamp to
 *   border) on the normalised coordinate: f with 24 fraction bits in [0, 1]
 *   (border: [−1, 2]), then c = f × size >> 16 (8 fraction bits, floor).
 *   Nearest: texel c >> 8; bilinear: c − 128, the integer part and its
 *   neighbour, the low 8 bits the weight.  Indices outside the level go
 *   back into it (repeat: −1 → size − 1, size → 0; the others clamp); with
 *   clamp to border such a texel is a border texel: bit 0 of its address
 *   is set (the address's bits 1:0 are otherwise 0).
 *   texf: integer x, y, level (rs2), all clamped into range, nearest.
 *   texsz: word 0 = level (unsigned, clamped to 15), value {h, w} of it.
 *   Address: level base = BASE (+ MIP_OFFSET[level] above level 0), level
 *   size max(1, size >> level), 4 bytes a texel; linear rows of width × 4
 *   bytes, or SAMPLER[13] the 4×4 tiles of atg_blt (a row of tiles is
 *   ceil(width / 4) × 64 bytes).
 * Lanes outside tx_mask are computed too (the cache does not fetch them).
 * See spec/gpu/tu/atg_tu_addr.md.
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
	/* Requests from the SU (atg_su tx_* /tr_*) */
	input wire tx_valid,
	output wire tx_ready,
	input wire [1:0] tx_op,
	input wire [3:0] tx_slot,
	input wire [3:0] tx_mask,
	input wire [383:0] tx_coord,
	input wire [15:0] tx_tag,
	input wire tx_last,
	/* To atg_tu_cache */
	output wire ta_valid,
	input wire ta_ready,
	output reg [511:0] ta_addr,
	output reg [95:0] ta_wts,
	output reg [15:0] ta_tag,
	output reg [3:0] ta_mask,
	output wire [15:0] ta_ctl,
	output reg [127:0] ta_value,
	output reg ta_last
);
	`include "ghci_regs.vh"
	localparam [1:0] OP_TEXL = 2'd0, OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;
	localparam [2:0] IDLE = 3'd0, LOD = 3'd1, LA = 3'd2, LB = 3'd3, OUT = 3'd4;
	localparam signed [16:0] LAM_MIN = -17'sd32768;

	/* floor(f × 2^sh), saturated to 32 bits; zero, denormal, NaN → 0. */
	function [31:0] fx32;
		input [31:0] f;
		input [4:0] sh;
		integer k;
		reg [31:0] q;
		reg st;
		begin
			k = {24'd0, f[30:23]} - 150 + {27'd0, sh};
			q = 32'd0;
			st = 1'b0;
			if (k >= 0 && k < 8)
				q = {8'd0, 1'b1, f[22:0]} << k;
			else if (k < 0 && k > -24) begin
				q = {8'd0, 1'b1, f[22:0]} >> (-k);
				st = |({1'b1, f[22:0]} & ((24'd1 << (-k)) - 24'd1));
			end else if (k < 0)
				st = 1'b1;
			if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
				fx32 = 32'd0;
			else if (f[30:23] == 8'hFF || k >= 8)
				fx32 = f[31] ? 32'h80000000 : 32'h7FFFFFFF;
			else
				fx32 = f[31] ? -(q + {31'd0, st}) : q;
		end
	endfunction

	function signed [16:0] sat16;
		input signed [32:0] v;
		sat16 = v > 33'sd32767 ? 17'sd32767 : v < -33'sd32768 ? -17'sd32768 : v[16:0];
	endfunction

	/* The wrapped coordinate (tools/tumodel.py fwrap): [0, 2^24], or for
	 * clamp to border floor(u × 2^24) clamped to [−2^24, 2^25]. */
	function signed [26:0] fwrap;
		input [31:0] f;
		input [1:0] mode;
		integer k;
		reg [24:0] q, t;
		reg st;
		begin
			k = {24'd0, f[30:23]} - 126;
			q = 25'd0;
			st = 1'b0;
			if (k >= 0 && k < 25)
				q = {1'b0, 1'b1, f[22:0]} << k;
			else if (k < 0 && k > -24) begin
				q = {1'b0, 1'b1, f[22:0]} >> (-k);
				st = |({1'b1, f[22:0]} & ((24'd1 << (-k)) - 24'd1));
			end else if (k < 0)
				st = 1'b1;
			t = f[31] ? -(q + {24'd0, st}) : q;
			if (f[30:23] == 8'hFF)
				t = 25'd0;
			if (f[30:23] == 8'd0 || (f[30:23] == 8'hFF && f[22:0] != 23'd0))
				fwrap = 27'sd0;
			else if (mode == 2'd3 && f[30:23] >= 8'd128)
				fwrap = f[31] ? -27'sd16777216 : 27'sd33554432;
			else if (mode == 2'd3)
				fwrap = !f[31] ? $signed({2'b00, q}) :
					{1'b0, q} + {25'd0, st} >= 26'h1000000 ? -27'sd16777216 :
					-$signed({1'b0, {1'b0, q} + {25'd0, st}});
			else if (mode[1])
				fwrap = f[31] ? 27'sd0 : f[30:23] >= 8'd127 ? 27'sd16777216 :
					$signed({3'b000, {1'b1, f[22:0]} >> (8'd126 - f[30:23])});
			else if (mode[0] && t[24])
				fwrap = $signed({2'b00, 25'h1000000 - {1'b0, t[23:0]}});
			else if (mode[0])
				fwrap = $signed({2'b00, t});
			else
				fwrap = $signed({3'b000, t[23:0]});
		end
	endfunction

	/* log2 with 8 fraction bits (x != 0). */
	function [13:0] l2;
		input [32:0] x;
		integer i;
		reg [5:0] p;
		reg [7:0] m;
		begin
			p = 6'd0;
			for (i = 0; i < 33; i = i + 1)
				if (x[i])
					p = i[5:0];
			for (i = 0; i < 8; i = i + 1)
				m[7 - i] = {26'd0, p} > i ? x[{26'd0, p} - 1 - i] : 1'b0;
			l2 = {p, m};
		end
	endfunction

	/* A texel index back into the level: {border texel, index}. */
	function [16:0] wrapi;
		input signed [18:0] i;
		input [15:0] n;
		input [1:0] mode;
		reg lt, ge;
		begin
			lt = i < 0;
			ge = i >= $signed({3'b000, n});
			if (mode == 2'd0)
				wrapi = {1'b0, lt ? n - 16'd1 : ge ? 16'd0 : i[15:0]};
			else
				wrapi = {mode == 2'd3 && (lt || ge), lt ? 16'd0 : ge ? n - 16'd1 : i[15:0]};
		end
	endfunction

	/* STATE 0x090-0x18F: the header words of each slot, and all words for
	 * MIP_OFFSET (read at {slot, 3 + level}). */
	reg [31:0] d_base [0:15];
	reg [31:0] d_size [0:15];
	reg [3:0] d_lev [0:15];
	reg [18:0] d_samp [0:15];
	reg [31:0] d_word [0:255];
	wire [8:0] s_off = st_idx - GHCI_S_TU;
	always @(posedge clk)
		if (st_we && st_idx >= GHCI_S_TU && st_idx < GHCI_S_TU + 9'd256) begin
			d_word[s_off[7:0]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_BASE)
				d_base[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_SIZE)
				d_size[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_LEVELS)
				d_lev[s_off[7:4]] <= st_wdata[3:0];
			if (s_off[3:0] == GHCI_TEX_SAMPLER)
				d_samp[s_off[7:4]] <= st_wdata[18:0];
		end

	reg [2:0] st;
	reg [1:0] k, op;
	reg [3:0] slot;
	reg [383:0] crd;
	reg signed [16:0] lam_q;
	reg linq;
	reg pass;	/* 1: the second level of mip linear filtering */
	reg trineed;	/* a lane of the mask needs the second level */
	/* Lane stage A → B. */
	reg r_lin;
	reg [7:0] r_fl;
	reg [15:0] r_wl, r_hl;
	reg signed [26:0] r_cu, r_cv;
	reg [31:0] r_lbase;

	wire [31:0] base = d_base[slot];
	wire [15:0] w0 = d_size[slot][15:0] == 16'd0 ? 16'd1 : d_size[slot][15:0];
	wire [15:0] h0 = d_size[slot][31:16] == 16'd0 ? 16'd1 : d_size[slot][31:16];
	wire [3:0] nlev = d_lev[slot] == 4'd0 ? 4'd1 : d_lev[slot] > 4'd13 ? 4'd13 : d_lev[slot];
	wire [3:0] maxl = nlev - 4'd1;
	wire [18:0] samp = d_samp[slot];
	wire [1:0] mu = samp[GHCI_SAMP_WRAP_U +: 2], mv = samp[GHCI_SAMP_WRAP_V +: 2];
	/* Depth format; compare (texl, texb); filtering allowed; mip linear. */
	wire depth = samp[GHCI_SAMP_FMT_HI];
	wire cmp = depth && samp[GHCI_SAMP_COMPARE] && !op[1];
	wire filt = !depth || cmp;
	wire miplin = filt && samp[GHCI_SAMP_MIP_LINEAR];
	wire [2:0] cmp_op = samp[GHCI_SAMP_COMPARE_OP +: 3];
	wire fmt = samp[GHCI_SAMP_FMT_LO];
	/* VkBorderColor >> 1: 0 transparent black, 1 opaque black, 2 opaque white. */
	wire [2:0] bcol = samp[GHCI_SAMP_BORDER +: 3];
	wire [1:0] bcls = bcol[2:1] == 2'd3 ? 2'd0 : bcol[2:1];

	/* The quad LOD (texb), from lanes 0-2. */
	wire [31:0] uq0 = fx32(crd[0 +: 32], 5'd16), uq1 = fx32(crd[96 +: 32], 5'd16);
	wire [31:0] uq2 = fx32(crd[192 +: 32], 5'd16);
	wire [31:0] vq0 = fx32(crd[32 +: 32], 5'd16), vq1 = fx32(crd[128 +: 32], 5'd16);
	wire [31:0] vq2 = fx32(crd[224 +: 32], 5'd16);
	wire signed [32:0] dux = $signed({uq1[31], uq1}) - $signed({uq0[31], uq0});
	wire signed [32:0] duy = $signed({uq2[31], uq2}) - $signed({uq0[31], uq0});
	wire signed [32:0] dvx = $signed({vq1[31], vq1}) - $signed({vq0[31], vq0});
	wire signed [32:0] dvy = $signed({vq2[31], vq2}) - $signed({vq0[31], vq0});
	wire [32:0] adux = dux[32] ? -dux : dux, aduy = duy[32] ? -duy : duy;
	wire [32:0] advx = dvx[32] ? -dvx : dvx, advy = dvy[32] ? -dvy : dvy;
	wire [32:0] mxu = adux > aduy ? adux : aduy, mxv = advx > advy ? advx : advy;
	wire signed [16:0] lu = mxu == 33'd0 ? LAM_MIN :
		$signed({3'd0, l2(mxu)}) + $signed({3'd0, l2({17'd0, w0})}) - 17'sd4096;
	wire signed [16:0] lv = mxv == 33'd0 ? LAM_MIN :
		$signed({3'd0, l2(mxv)}) + $signed({3'd0, l2({17'd0, h0})}) - 17'sd4096;

	/* Stage A of lane k: LOD, level, filter, level size, wrapped coordinates. */
	wire [31:0] cw0 = crd[k*96 +: 32], cw1 = crd[k*96 + 32 +: 32], cw2 = crd[k*96 + 64 +: 32];
	wire [31:0] lfx = fx32(cw2, 5'd8);
	wire signed [16:0] lam1 = sat16({lfx[31], lfx});
	wire signed [16:0] lam = cmp ? (op == OP_TEXB ? lam_q : 17'sd0) : op == OP_TEXB ?
		sat16({{16{lam_q[16]}}, lam_q} + {{16{lam1[16]}}, lam1}) : lam1;
	wire mag = !(lam > 17'sd0);
	wire [16:0] lrnd = lam + 17'd127;
	wire [3:0] lmin = lrnd[15:8] > {4'd0, maxl} ? maxl : lrnd[11:8];
	/* Mip linear: λ > 0 here, so λ >> 8 is 0 .. 127. */
	wire lend = lam[15:8] >= {4'd0, maxl};
	wire [3:0] llin = lend ? maxl : lam[11:8] + {3'd0, pass};
	wire [7:0] fl = !mag && miplin && !lend ? lam[7:0] : 8'd0;
	wire [3:0] lfetch = cw2[31] ? 4'd0 : cw2[30:0] > {27'd0, maxl} ? maxl : cw2[3:0];
	wire [3:0] lsize = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
	wire [3:0] lvl = op == OP_TEXSZ ? lsize : op == OP_TEXF ? lfetch : mag ? 4'd0 :
		miplin ? llin : lmin;
	wire lin = op[1] ? 1'b0 : filt && (mag ? samp[GHCI_SAMP_MAG_LINEAR] :
		samp[GHCI_SAMP_MIN_LINEAR]);
	wire [15:0] wl_s = w0 >> lvl, hl_s = h0 >> lvl;
	wire [15:0] wl = wl_s == 16'd0 ? 16'd1 : wl_s, hl = hl_s == 16'd0 ? 16'd1 : hl_s;
	wire signed [26:0] fwu = fwrap(cw0, mu), fwv = fwrap(cw1, mv);
	wire signed [43:0] pu = fwu * $signed({1'b0, wl});
	wire signed [43:0] pv = fwv * $signed({1'b0, hl});

	/* Stage B of lane k: the footprint and the addresses. */
	wire signed [26:0] cu2 = r_cu - 27'sd128;
	wire signed [26:0] cv2 = r_cv - 27'sd128;
	wire signed [18:0] bi0 = cu2[26:8], bj0 = cv2[26:8];
	/* Nearest: c >> 8 (0 .. size for the modes other than border). */
	wire [16:0] ni = wrapi(r_cu[26:8], r_wl, mu), nj = wrapi(r_cv[26:8], r_hl, mv);
	wire [16:0] wi0 = wrapi(bi0, r_wl, mu), wj0 = wrapi(bj0, r_hl, mv);
	wire [16:0] wi1 = wrapi(bi0 + 19'sd1, r_wl, mu), wj1 = wrapi(bj0 + 19'sd1, r_hl, mv);
	wire signed [31:0] fxi = $signed(cw0), fxj = $signed(cw1);
	wire [15:0] ti = fxi < 0 ? 16'd0 : fxi >= $signed({16'd0, r_wl}) ? r_wl - 16'd1 : cw0[15:0];
	wire [15:0] tj = fxj < 0 ? 16'd0 : fxj >= $signed({16'd0, r_hl}) ? r_hl - 16'd1 : cw1[15:0];
	wire [16:0] xi0 = op == OP_TEXF ? {1'b0, ti} : r_lin ? wi0 : ni;
	wire [16:0] xj0 = op == OP_TEXF ? {1'b0, tj} : r_lin ? wj0 : nj;
	wire [16:0] xi1 = r_lin ? wi1 : xi0, xj1 = r_lin ? wj1 : xj0;
	wire [15:0] i0 = xi0[15:0], j0 = xj0[15:0], i1 = xi1[15:0], j1 = xj1[15:0];
	/* Border texels 0-3. */
	wire [3:0] bt = {xi1[16] | xj1[16], xi0[16] | xj1[16], xi1[16] | xj0[16], xi0[16] | xj0[16]};
	wire [31:0] a00 = r_lbase + row0 + col0, a10 = r_lbase + row0 + col1;
	wire [31:0] a01 = r_lbase + row1 + col0, a11 = r_lbase + row1 + col1;
	wire tiled = samp[GHCI_SAMP_TILED];
	wire [15:0] tw = {2'b00, r_wl[15:2]} + {15'd0, r_wl[1:0] != 2'd0};	/* tiles per row */
	wire [31:0] m0 = tiled ? {18'd0, j0[15:2]} * {16'd0, tw} : {16'd0, j0} * {16'd0, r_wl};
	wire [31:0] m1 = tiled ? {18'd0, j1[15:2]} * {16'd0, tw} : {16'd0, j1} * {16'd0, r_wl};
	wire [31:0] row0 = tiled ? {m0[25:0], 6'd0} + {26'd0, j0[1:0], 4'd0} : {m0[29:0], 2'd0};
	wire [31:0] row1 = tiled ? {m1[25:0], 6'd0} + {26'd0, j1[1:0], 4'd0} : {m1[29:0], 2'd0};
	wire [31:0] col0 = tiled ? {12'd0, i0[15:2], 6'd0} + {28'd0, i0[1:0], 2'd0} :
		{14'd0, i0, 2'd0};
	wire [31:0] col1 = tiled ? {12'd0, i1[15:2], 6'd0} + {28'd0, i1[1:0], 2'd0} :
		{14'd0, i1, 2'd0};

	assign tx_ready = st == IDLE;
	assign ta_valid = st == OUT;
	assign ta_ctl = {3'd0, cmp_op, cmp, depth, bcls, pass, !pass && trineed, op == OP_TEXF,
		op == OP_TEXSZ, fmt, linq};

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
		end else begin
			case (st)
			IDLE: if (tx_valid) begin
				op <= tx_op;
				slot <= tx_slot;
				crd <= tx_coord;
				ta_mask <= tx_mask;
				ta_tag <= tx_tag;
				ta_last <= tx_last;
				k <= 2'd0;
				linq <= 1'b0;
				pass <= 1'b0;
				trineed <= 1'b0;
				st <= tx_op == OP_TEXB ? LOD : LA;
			end
			LOD: begin
				lam_q <= lu > lv ? lu : lv;
				st <= LA;
			end
			LA: begin
				r_lin <= lin;
				r_fl <= op[1] ? 8'd0 : fl;
				r_wl <= wl;
				r_hl <= hl;
				r_cu <= pu[42:16];
				r_cv <= pv[42:16];
				r_lbase <= base + (lvl == 4'd0 ? 32'd0 :
					d_word[{slot, lvl + GHCI_TEX_MIP_OFFSET - 4'd1}]);
				st <= LB;
			end
			LB: begin
				ta_addr[k*128 +: 128] <= op == OP_TEXSZ ? 128'd0 : {
					a11[31:2], 1'b0, bt[3], a01[31:2], 1'b0, bt[2],
					a10[31:2], 1'b0, bt[1], a00[31:2], 1'b0, bt[0]};
				ta_wts[k*24 +: 24] <= {r_fl, r_lin ? {cv2[7:0], cu2[7:0]} : 16'd0};
				ta_value[k*32 +: 32] <= op == OP_TEXSZ ? {r_hl, r_wl} : cmp ? cw2 : 32'd0;
				if (r_lin && ta_mask[k])
					linq <= 1'b1;
				if (r_fl != 8'd0 && ta_mask[k] && !pass)
					trineed <= 1'b1;
				k <= k + 2'd1;
				st <= k == 2'd3 ? OUT : LA;
			end
			OUT: if (ta_ready) begin
				/* The second level of mip linear filtering: the lanes again. */
				if (!pass && trineed) begin
					pass <= 1'b1;
					linq <= 1'b0;
					st <= LA;
				end else
					st <= IDLE;
			end
			default: st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, lrnd[16], lrnd[7:0], m0[31:30], m1[31:30], s_off[8], samp[15],
		samp[11], bcol[0], pu[43], pu[15:0], pv[43], pv[15:0], a00[1:0], a10[1:0],
		a01[1:0], a11[1:0], OP_TEXL};
endmodule

`default_nettype wire
