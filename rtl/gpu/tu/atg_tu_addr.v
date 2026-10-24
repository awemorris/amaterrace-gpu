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
 * Numbers (tools/tumodel.py is the reference, bit for bit):
 *   LOD λ: signed, 8 fraction bits, saturated to 16 bits.  texl: floor(lod
 *   × 256); texb: the quad's λ (lanes 0, 1 = x + 1, 2 = y + 1: the largest
 *   |Δu| times the width and |Δv| times the height, log2 as msb + 8 bits
 *   below it, from u and v as floor(x × 2^16)) plus floor(bias × 256).
 *   λ > 0: minification (SAMPLER[5] linear), level (λ + 127) >> 8 clamped
 *   to LEVELS − 1 (nearest mip; SAMPLER[6] mip linear is not done); λ ≤ 0:
 *   magnification (SAMPLER[4]), level 0.
 *   Wrap (2 bits: 0 repeat, 1 mirrored repeat, 2 clamp to edge, 3 read as
 *   2) on the normalised coordinate: f in [0, 1] with 24 fraction bits,
 *   then c = f × size >> 16 (8 fraction bits).  Nearest: texel min(c >> 8,
 *   size − 1).  Bilinear: c − 128, the integer part and its neighbour
 *   wrapped back into the level (repeat: −1 → size − 1, size → 0; the
 *   others clamp), the low 8 bits the weight.
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
	output reg [63:0] ta_wts,
	output reg [15:0] ta_tag,
	output reg [3:0] ta_mask,
	output wire [7:0] ta_ctl,
	output reg [127:0] ta_value,
	output reg ta_last
);
	`include "ghci_regs.vh"
	localparam [1:0] OP_TEXB = 2'd1, OP_TEXF = 2'd2, OP_TEXSZ = 2'd3;
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

	/* The wrapped coordinate in [0, 2^24] (tools/tumodel.py fwrap). */
	function [24:0] fwrap;
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
				fwrap = 25'd0;
			else if (mode[1])
				fwrap = f[31] ? 25'd0 : f[30:23] >= 8'd127 ? 25'h1000000 :
					{1'b0, 1'b1, f[22:0]} >> (8'd126 - f[30:23]);
			else if (mode[0] && t[24])
				fwrap = 25'h1000000 - {1'b0, t[23:0]};
			else if (mode[0])
				fwrap = t;
			else
				fwrap = {1'b0, t[23:0]};
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

	/* A bilinear neighbour (−1 .. n) back into the level. */
	function [15:0] wrapi;
		input signed [17:0] i;
		input [15:0] n;
		input rep;
		wrapi = i < 0 ? (rep ? n - 16'd1 : 16'd0) :
			i >= $signed({2'b00, n}) ? (rep ? 16'd0 : n - 16'd1) : i[15:0];
	endfunction

	/* STATE 0x090-0x18F: the header words of each slot, and all words for
	 * MIP_OFFSET (read at {slot, 3 + level}). */
	reg [31:0] d_base [0:15];
	reg [31:0] d_size [0:15];
	reg [3:0] d_lev [0:15];
	reg [13:0] d_samp [0:15];
	reg [31:0] d_word [0:255];
	wire [8:0] s_off = st_idx - GHCI_S_TU;
	always @(posedge clk)
		if (st_we && st_idx >= GHCI_S_TU && st_idx < GHCI_S_TU + 9'd256) begin
			d_word[s_off[7:0]] <= st_wdata;
			if (s_off[3:0] == 4'd0)
				d_base[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == 4'd1)
				d_size[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == 4'd2)
				d_lev[s_off[7:4]] <= st_wdata[3:0];
			if (s_off[3:0] == 4'd3)
				d_samp[s_off[7:4]] <= st_wdata[13:0];
		end

	reg [2:0] st;
	reg [1:0] k, op;
	reg [3:0] slot;
	reg [383:0] crd;
	reg signed [16:0] lam_q;
	reg linq;
	/* Lane stage A → B. */
	reg r_lin;
	reg [15:0] r_wl, r_hl;
	reg [24:0] r_cu, r_cv;
	reg [31:0] r_lbase;

	wire [31:0] base = d_base[slot];
	wire [15:0] w0 = d_size[slot][15:0] == 16'd0 ? 16'd1 : d_size[slot][15:0];
	wire [15:0] h0 = d_size[slot][31:16] == 16'd0 ? 16'd1 : d_size[slot][31:16];
	wire [3:0] nlev = d_lev[slot] == 4'd0 ? 4'd1 : d_lev[slot] > 4'd13 ? 4'd13 : d_lev[slot];
	wire [3:0] maxl = nlev - 4'd1;
	wire [13:0] samp = d_samp[slot];
	wire [1:0] mu = samp[1:0], mv = samp[3:2];

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
	wire signed [16:0] lam = op == OP_TEXB ?
		sat16({{16{lam_q[16]}}, lam_q} + {{16{lam1[16]}}, lam1}) : lam1;
	wire mag = !(lam > 17'sd0);
	wire [16:0] lrnd = lam + 17'd127;
	wire [3:0] lmin = lrnd[15:8] > {4'd0, maxl} ? maxl : lrnd[11:8];
	wire [3:0] lfetch = cw2[31] ? 4'd0 : cw2[30:0] > {27'd0, maxl} ? maxl : cw2[3:0];
	wire [3:0] lsize = cw0[31:4] != 28'd0 ? 4'd15 : cw0[3:0];
	wire [3:0] lvl = op == OP_TEXSZ ? lsize : op == OP_TEXF ? lfetch : mag ? 4'd0 : lmin;
	wire lin = op[1] ? 1'b0 : mag ? samp[4] : samp[5];
	wire [15:0] wl_s = w0 >> lvl, hl_s = h0 >> lvl;
	wire [15:0] wl = wl_s == 16'd0 ? 16'd1 : wl_s, hl = hl_s == 16'd0 ? 16'd1 : hl_s;
	wire [40:0] pu = {16'd0, fwrap(cw0, mu)} * {25'd0, wl};
	wire [40:0] pv = {16'd0, fwrap(cw1, mv)} * {25'd0, hl};

	/* Stage B of lane k: the footprint and the addresses. */
	wire signed [25:0] cu2 = $signed({1'b0, r_cu}) - 26'sd128;
	wire signed [25:0] cv2 = $signed({1'b0, r_cv}) - 26'sd128;
	wire signed [17:0] bi0 = cu2[25:8], bj0 = cv2[25:8];
	wire [15:0] ni = r_cu[24:8] >= {1'b0, r_wl} ? r_wl - 16'd1 : r_cu[23:8];
	wire [15:0] nj = r_cv[24:8] >= {1'b0, r_hl} ? r_hl - 16'd1 : r_cv[23:8];
	wire signed [31:0] fxi = $signed(cw0), fxj = $signed(cw1);
	wire [15:0] ti = fxi < 0 ? 16'd0 : fxi >= $signed({16'd0, r_wl}) ? r_wl - 16'd1 : cw0[15:0];
	wire [15:0] tj = fxj < 0 ? 16'd0 : fxj >= $signed({16'd0, r_hl}) ? r_hl - 16'd1 : cw1[15:0];
	wire [15:0] i0 = op == OP_TEXF ? ti : r_lin ? wrapi(bi0, r_wl, mu == 2'd0) : ni;
	wire [15:0] j0 = op == OP_TEXF ? tj : r_lin ? wrapi(bj0, r_hl, mv == 2'd0) : nj;
	wire [15:0] i1 = r_lin ? wrapi(bi0 + 18'sd1, r_wl, mu == 2'd0) : i0;
	wire [15:0] j1 = r_lin ? wrapi(bj0 + 18'sd1, r_hl, mv == 2'd0) : j0;
	wire tiled = samp[13];
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
	assign ta_ctl = {4'd0, op == OP_TEXF, op == OP_TEXSZ, samp[12], linq};

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
				st <= tx_op == OP_TEXB ? LOD : LA;
			end
			LOD: begin
				lam_q <= lu > lv ? lu : lv;
				st <= LA;
			end
			LA: begin
				r_lin <= lin;
				r_wl <= wl;
				r_hl <= hl;
				r_cu <= pu[40:16];
				r_cv <= pv[40:16];
				r_lbase <= base + (lvl == 4'd0 ? 32'd0 : d_word[{slot, lvl + 4'd3}]);
				st <= LB;
			end
			LB: begin
				ta_addr[k*128 +: 128] <= op == OP_TEXSZ ? 128'd0 : {
					r_lbase + row1 + col1, r_lbase + row1 + col0,
					r_lbase + row0 + col1, r_lbase + row0 + col0};
				ta_wts[k*16 +: 16] <= r_lin ? {cv2[7:0], cu2[7:0]} : 16'd0;
				ta_value[k*32 +: 32] <= op == OP_TEXSZ ? {r_hl, r_wl} : 32'd0;
				if (r_lin && ta_mask[k])
					linq <= 1'b1;
				k <= k + 2'd1;
				st <= k == 2'd3 ? OUT : LA;
			end
			OUT: if (ta_ready)
				st <= IDLE;
			default: st <= IDLE;
			endcase
		end
	end

	wire unused_ok = &{1'b0, lrnd[16], lrnd[7:0], m0[31:30], m1[31:30], s_off[8], samp[11:6],
		pu[15:0], pv[15:0]};
endmodule

`default_nettype wire
