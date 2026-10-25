/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_desc: the TU's descriptors (STATE 0x090-0x18F, 16 slots of 16
 * words, docs/ghci.md section 8.4, the slots 0-15 of fragment and compute
 * programs; with CAPS[30] also 0x200-0x2FF, the vertex stage's 16 slots,
 * here slots 16-31, section 8.5) and the byte offsets of their mip
 * levels.
 *
 * Keeps words 0-7 of each slot (BASE, SIZE, IMAGE, LAYER_STRIDE, SAMPLER,
 * LOD, FORMAT's 21 bits, ROW's 2 bits; words 8-15 are reserved and not
 * kept).  A write of SIZE, IMAGE, FORMAT or ROW marks the slot; one at a
 * time, lowest slot first, the offsets of levels 1-12 are computed again,
 * a level a cycle: off[l + 1] = off[l] + P_l x D_l with P_l the level's
 * plane in bytes rounded up to 64 (linear: r_l x h_l x ps, ps the texel's
 * bytes, 1-16, of the format (include/atg_tu_fmt.vh), r_l the row's
 * texels, w_l rounded up to a multiple of 2^TEX_ROW[1:0] (the rule is 0,
 * packed rows, for tiled, compressed and multisampled images); tiled, only
 * 4-byte texels and the
 * earlier RGB565 code: ceil(w_l / 4) x ceil(h_l / 4) x 16 ps) and D_l =
 * max(1, depth >> l) for the view type 3D, 1 otherwise (32-bit wrap;
 * offsets are multiples of 64 and kept as bits 31:6).  busy is high while
 * a slot is marked or being computed; atg_tu_addr takes no quad then, and
 * the CP holds a SET_REG of the TU range while the TU is busy.
 * The read port is combinational: the eight words of rd_slot (ROW as the
 * rule that applies), the offset of level rd_level (0 for level 0) and the
 * plane P of that level.
 * See spec/gpu/tu/atg_tu_desc.md.
 *
 * States: IDLE →(a marked slot)→ RUN (levels 0-11) → IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_desc (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [9:0] st_idx,
	input wire [31:0] st_wdata,
	output wire busy,
	/* Read port (combinational) */
	input wire [4:0] rd_slot,	/* [4]: the vertex stage's */
	input wire [3:0] rd_level,
	output wire [31:0] rd_base,
	output wire [31:0] rd_size,
	output wire [31:0] rd_image,
	output wire [31:0] rd_stride,
	output wire [31:0] rd_samp,
	output wire [31:0] rd_lod,
	output wire [20:0] rd_fmt,
	output wire [1:0] rd_row,	/* log2 of a row's texel multiple (0: packed) */
	output wire [31:0] rd_loff,
	output wire [31:0] rd_plane
);
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	`include "atg_tu_fmt.vh"
	localparam IDLE = 1'b0, RUN = 1'b1;

	/* P_l: the plane of level l of a w x h image in bytes, a multiple of 64
	 * (texels of 2^psl bytes in rows of w rounded up to a multiple of 2^ra;
	 * tiled: 4-byte texels, or psl 1 for RGB565). */
	function [31:0] plane;
		input [31:0] sz;
		input tiled;
		input blk;	/* compressed 4 x 4 blocks of 2^psl bytes */
		input [2:0] psl;
		input [1:0] ra;
		input [3:0] l;
		reg [15:0] w0, h0, w, h;
		reg [16:0] wr, m;
		/* verilator lint_off UNUSEDSIGNAL */
		reg [33:0] p;	/* bits 33:32 wrap, 5:0 rounded off */
		reg [31:0] t;	/* tiles; below 2^28 */
		/* verilator lint_on UNUSEDSIGNAL */
		begin
			w0 = sz[15:0] == 16'd0 ? 16'd1 : sz[15:0];
			h0 = sz[31:16] == 16'd0 ? 16'd1 : sz[31:16];
			w = w0 >> l;
			h = h0 >> l;
			w = w == 16'd0 ? 16'd1 : w;
			h = h == 16'd0 ? 16'd1 : h;
			m = (17'd1 << ra) - 17'd1;
`ifdef MUT_TU_PITCHOFF
			wr = {1'b0, w} | (m & 17'd0);	/* the planes of packed rows */
`else
			wr = ({1'b0, w} + m) & ~m;
`endif
			t = ({16'd0, 2'b00, w[15:2]} + {31'd0, w[1:0] != 2'd0}) *
				({16'd0, 2'b00, h[15:2]} + {31'd0, h[1:0] != 2'd0});
			if (tiled)
				p = psl == 3'd1 ? {t[28:0], 5'd0} + 34'd63 : {t[27:0], 6'd0};
			else if (blk)
				p = ({2'b00, t} << psl) + 34'd63;
			else
				p = (({17'd0, wr} * {18'd0, h}) << psl) + 34'd63;
			plane = {p[31:6], 6'd0};
		end
	endfunction

	/* The slot's texel size and whether it is tiled (only 4-byte texels and
	 * the earlier RGB565); [6:5] the row rule that applies (0 for tiled,
	 * compressed and multisampled images). */
	function [6:0] layout;
		input [31:0] img;
		input [20:0] tf;
		input [1:0] ra;
		/* verilator lint_off UNUSEDSIGNAL */
		reg [12:0] c;	/* the size, legacy and block bits */
		/* verilator lint_on UNUSEDSIGNAL */
		reg tl;
		begin
			c = tu_fcls(tf, img[GHCI_IMG_FMT +: 4]);
			tl = img[GHCI_IMG_TILED] && (c[3] || c[2:0] == 3'd2);
			layout = {tl || c[12] || (img[GHCI_IMG_SAMPLES +: 4] == 4'd2 &&
				!img[GHCI_IMG_TILED]) ? 2'd0 : ra, c[12], tl, c[2:0]};
		end
	endfunction

	reg [31:0] d_base [0:31];
	reg [31:0] d_size [0:31];
	reg [31:0] d_img [0:31];
	reg [31:0] d_stride [0:31];
	reg [31:0] d_samp [0:31];
	reg [31:0] d_lod [0:31];
	reg [20:0] d_fmt [0:31];
	reg [1:0] d_row [0:31];
	reg [25:0] d_off [0:511];	/* {slot, level}: levels 1-12 */
	wire [8:0] s_fs = st_idx[8:0] - GHCI_S_TU;
	wire in_fs = !st_idx[9] && st_idx[8:0] >= GHCI_S_TU && st_idx[8:0] < GHCI_S_TU + 9'd256;
	wire in_vs = st_idx[9:8] == GHCI_S_TU_VS[9:8];
	wire in_tu = st_we && (in_fs || in_vs);
	/* The slot (vertex: 16-31) and the word. */
	wire [8:0] s_off = in_vs ? {1'b1, st_idx[7:0]} : {1'b0, s_fs[7:0]};
	always @(posedge clk)
		if (in_tu) begin
			if (s_off[3:0] == GHCI_TEX_BASE)
				d_base[s_off[8:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_SIZE)
				d_size[s_off[8:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_IMAGE)
				d_img[s_off[8:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_LAYER_STRIDE)
				d_stride[s_off[8:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_SAMPLER)
				d_samp[s_off[8:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_LOD)
				d_lod[s_off[8:4]] <= st_wdata;
		end
	/* TEX_FORMAT is 0 (the earlier formats) and TEX_ROW 0 (packed rows)
	 * until written. */
	integer r;
	always @(posedge clk)
		if (!rst_n) begin
			for (r = 0; r < 32; r = r + 1) begin
				d_fmt[r] <= 21'd0;
				d_row[r] <= 2'd0;
			end
		end else begin
			if (in_tu && s_off[3:0] == GHCI_TEX_FORMAT)
				d_fmt[s_off[8:4]] <= st_wdata[20:0];
			if (in_tu && s_off[3:0] == GHCI_TEX_ROW)
				d_row[s_off[8:4]] <= st_wdata[GHCI_TROW_ALIGN +: 2];
		end
	wire mark = in_tu && (s_off[3:0] == GHCI_TEX_SIZE || s_off[3:0] == GHCI_TEX_IMAGE ||
		s_off[3:0] == GHCI_TEX_FORMAT || s_off[3:0] == GHCI_TEX_ROW);

	reg st;
	reg [31:0] dirty;
	reg [4:0] cs;
	reg [3:0] cl;
	reg [31:0] acc;

	/* The lowest marked slot. */
	reg [4:0] lo;
	integer i;
	always @(*) begin
		lo = 5'd0;
		for (i = 31; i >= 0; i = i - 1)
			if (dirty[i])
				lo = i[4:0];
	end
	/* Level cl of slot cs: P x D. */
	wire [31:0] cimg = d_img[cs];
	wire [15:0] cnt = cimg[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : cimg[GHCI_IMG_COUNT +: 16];
	wire [15:0] dsh = cnt >> cl;
	wire [15:0] dl = cimg[GHCI_IMG_TYPE +: 3] != 3'd2 || dsh == 16'd0 ? 16'd1 : dsh;
	wire [6:0] clay = layout(cimg, d_fmt[cs], d_row[cs]);
	wire [31:0] cp = plane(d_size[cs], clay[3], clay[4], clay[2:0], clay[6:5], cl);
	wire [47:0] pd = cp * {16'd0, dl};
	wire [31:0] nacc = acc + pd[31:0];
	wire [31:0] clr = st == IDLE && dirty != 32'd0 ? 32'd1 << lo : 32'd0;
	wire [31:0] set = mark ? 32'd1 << s_off[8:4] : 32'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			dirty <= 32'd0;
		end else begin
			dirty <= (dirty & ~clr) | set;
			case (st)
			IDLE: if (dirty != 32'd0) begin
				cs <= lo;
				cl <= 4'd0;
				acc <= 32'd0;
				st <= RUN;
			end
			default: begin
				acc <= nacc;
				d_off[{cs, cl + 4'd1}] <= nacc[31:6];
				cl <= cl + 4'd1;
				if (cl == 4'd11)
					st <= IDLE;
			end
			endcase
		end
	end

	assign busy = st == RUN || dirty != 32'd0;
	assign rd_base = d_base[rd_slot];
	assign rd_size = d_size[rd_slot];
	assign rd_image = d_img[rd_slot];
	assign rd_stride = d_stride[rd_slot];
	assign rd_samp = d_samp[rd_slot];
	assign rd_lod = d_lod[rd_slot];
	assign rd_loff = rd_level == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level}], 6'd0};
	assign rd_fmt = d_fmt[rd_slot];
	wire [6:0] rlay = layout(d_img[rd_slot], d_fmt[rd_slot], d_row[rd_slot]);
	assign rd_plane = plane(d_size[rd_slot], rlay[3], rlay[4], rlay[2:0], rlay[6:5], rd_level);
	assign rd_row = rlay[6:5];

	wire unused_ok = &{1'b0, s_fs[8], pd[47:32], nacc[5:0], acc[5:0]};
endmodule

`default_nettype wire
