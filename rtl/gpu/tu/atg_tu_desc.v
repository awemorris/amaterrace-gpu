/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_desc: the TU's descriptors (STATE 0x090-0x18F, 16 slots of 16
 * words, docs/ghci.md section 8.4) and the byte offsets of their mip
 * levels.
 *
 * Keeps words 0-5 of each slot (BASE, SIZE, IMAGE, LAYER_STRIDE, SAMPLER,
 * LOD; words 6-15 are reserved and not kept).  A write of SIZE or IMAGE
 * marks the slot; one at a time, lowest slot first, the offsets of levels
 * 1-12 are computed again, a level a cycle: off[l + 1] = off[l] + P_l x
 * D_l with P_l the level's plane in bytes rounded up to 64 (linear: w_l x
 * h_l x 4; tiled: ceil(w_l / 4) x ceil(h_l / 4) x 64; the 2-byte format 4,
 * RGB565: x 2 and x 32) and D_l = max(1,
 * depth >> l) for the view type 3D, 1 otherwise (32-bit wrap; offsets are
 * multiples of 64 and kept as bits 31:6).  busy is high while a slot is
 * marked or being computed; atg_tu_addr takes no quad then, and the CP
 * holds a SET_REG of the TU range while the TU is busy.
 * The read port is combinational: the six words of rd_slot, the offset of
 * level rd_level (0 for level 0) and the plane P of that level.
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
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	output wire busy,
	/* Read port (combinational) */
	input wire [3:0] rd_slot,
	input wire [3:0] rd_level,
	output wire [31:0] rd_base,
	output wire [31:0] rd_size,
	output wire [31:0] rd_image,
	output wire [31:0] rd_stride,
	output wire [31:0] rd_samp,
	output wire [31:0] rd_lod,
	output wire [31:0] rd_loff,
	output wire [31:0] rd_plane
);
	`include "ghci_regs.vh"
	localparam IDLE = 1'b0, RUN = 1'b1;

	/* P_l: the plane of level l of a w x h image in bytes, a multiple of 64. */
	function [31:0] plane;
		input [31:0] sz;
		input tiled;
		input b2;	/* 2-byte texels (format 4) */
		input [3:0] l;
		reg [15:0] w0, h0, w, h;
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
			t = ({16'd0, 2'b00, w[15:2]} + {31'd0, w[1:0] != 2'd0}) *
				({16'd0, 2'b00, h[15:2]} + {31'd0, h[1:0] != 2'd0});
			if (tiled)
				p = b2 ? {t[28:0], 5'd0} + 34'd63 : {t[27:0], 6'd0};
			else
				p = {16'd0, w} * {18'd0, h} * (b2 ? 34'd2 : 34'd4) + 34'd63;
			plane = {p[31:6], 6'd0};
		end
	endfunction

	reg [31:0] d_base [0:15];
	reg [31:0] d_size [0:15];
	reg [31:0] d_img [0:15];
	reg [31:0] d_stride [0:15];
	reg [31:0] d_samp [0:15];
	reg [31:0] d_lod [0:15];
	reg [25:0] d_off [0:255];	/* {slot, level}: levels 1-12 */
	wire [8:0] s_off = st_idx - GHCI_S_TU;
	wire in_tu = st_we && st_idx >= GHCI_S_TU && st_idx < GHCI_S_TU + 9'd256;
	always @(posedge clk)
		if (in_tu) begin
			if (s_off[3:0] == GHCI_TEX_BASE)
				d_base[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_SIZE)
				d_size[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_IMAGE)
				d_img[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_LAYER_STRIDE)
				d_stride[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_SAMPLER)
				d_samp[s_off[7:4]] <= st_wdata;
			if (s_off[3:0] == GHCI_TEX_LOD)
				d_lod[s_off[7:4]] <= st_wdata;
		end
	wire mark = in_tu && (s_off[3:0] == GHCI_TEX_SIZE || s_off[3:0] == GHCI_TEX_IMAGE);

	reg st;
	reg [15:0] dirty;
	reg [3:0] cs, cl;
	reg [31:0] acc;

	/* The lowest marked slot. */
	reg [3:0] lo;
	integer i;
	always @(*) begin
		lo = 4'd0;
		for (i = 15; i >= 0; i = i - 1)
			if (dirty[i])
				lo = i[3:0];
	end
	/* Level cl of slot cs: P x D. */
	wire [31:0] cimg = d_img[cs];
	wire [15:0] cnt = cimg[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : cimg[GHCI_IMG_COUNT +: 16];
	wire [15:0] dsh = cnt >> cl;
	wire [15:0] dl = cimg[GHCI_IMG_TYPE +: 3] != 3'd2 || dsh == 16'd0 ? 16'd1 : dsh;
	wire [31:0] cp = plane(d_size[cs], cimg[GHCI_IMG_TILED], cimg[GHCI_IMG_FMT +: 4] == 4'd4, cl);
	wire [47:0] pd = cp * {16'd0, dl};
	wire [31:0] nacc = acc + pd[31:0];
	wire [15:0] clr = st == IDLE && dirty != 16'd0 ? 16'd1 << lo : 16'd0;
	wire [15:0] set = mark ? 16'd1 << s_off[7:4] : 16'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= IDLE;
			dirty <= 16'd0;
		end else begin
			dirty <= (dirty & ~clr) | set;
			case (st)
			IDLE: if (dirty != 16'd0) begin
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

	assign busy = st == RUN || dirty != 16'd0;
	assign rd_base = d_base[rd_slot];
	assign rd_size = d_size[rd_slot];
	assign rd_image = d_img[rd_slot];
	assign rd_stride = d_stride[rd_slot];
	assign rd_samp = d_samp[rd_slot];
	assign rd_lod = d_lod[rd_slot];
	assign rd_loff = rd_level == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level}], 6'd0};
	assign rd_plane = plane(d_size[rd_slot], d_img[rd_slot][GHCI_IMG_TILED],
		d_img[rd_slot][GHCI_IMG_FMT +: 4] == 4'd4, rd_level);

	wire unused_ok = &{1'b0, s_off[8], pd[47:32], nacc[5:0], acc[5:0]};
endmodule

`default_nettype wire
