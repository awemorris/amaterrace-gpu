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
	input wire [4:0] rd_samp_slot,	/* [4]: the vertex stage's, independent sampler slot (N62, N77) */
	input wire [3:0] rd_level,
	input wire [3:0] rd_level1,
	input wire [3:0] rd_level2,
	input wire [3:0] rd_level3,
	output wire [31:0] rd_base,
	output wire [31:0] rd_size,
	output wire [31:0] rd_image,
	output wire [31:0] rd_stride,
	output wire [31:0] rd_samp,
	output wire [31:0] rd_lod,
	output wire [20:0] rd_fmt,
	output wire [1:0] rd_row,	/* log2 of a row's texel multiple (0: packed) */
	output wire [31:0] rd_loff,
	output wire [31:0] rd_plane,
	output wire [31:0] rd_loff1,
	output wire [31:0] rd_plane1,
	output wire [31:0] rd_loff2,
	output wire [31:0] rd_plane2,
	output wire [31:0] rd_loff3,
	output wire [31:0] rd_plane3
);
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	`include "atg_tu_fmt.vh"
	localparam IDLE = 1'b0, RUN = 1'b1;

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
	reg [25:0] d_plane [0:511];	/* {slot, level}: levels 0-12 plane size (multiple of 64) */
	wire [8:0] s_fs;
	wire [6:0] carry_unused;
	am_sub #(.W(9)) u_s_fs (.a(st_idx[8:0]), .b(GHCI_S_TU), .bi(1'b0), .d(s_fs), .bo(carry_unused[0]));
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

	localparam [2:0] S_IDLE  = 3'd0,
	                 S_LOAD  = 3'd1,
	                 S_DIM   = 3'd2,
	                 S_MULP  = 3'd3,
	                 S_PLANE = 3'd4,
	                 S_MULD  = 3'd5,
	                 S_MULD1 = 3'd7,
	                 S_ACC   = 3'd6;

	reg [2:0] st;
	reg [31:0] dirty;
	reg [4:0] cs;
	reg [3:0] cl;
	reg [31:0] acc;

	/* Registers for pipelined calculation */
	reg [31:0] r_sz;
	reg [31:0] r_img;
	reg [20:0] r_fmt;
	reg [1:0]  r_row;
	reg [6:0]  r_clay;

	reg [15:0] r_tw;
	reg [15:0] r_th;
	reg [16:0] r_wr;
	reg [15:0] r_h;
	reg [15:0] r_dl;

	reg [31:0] r_t;
	reg [32:0] r_wrh;

	reg [31:0] r_cp;
	reg [31:0] r_pd;

	/* The lowest marked slot. */
	reg [4:0] lo;
	integer i;
	always @(*) begin
		lo = 5'd0;
		for (i = 31; i >= 0; i = i - 1)
			if (dirty[i])
				lo = i[4:0];
	end

	/* Stage S_DIM combinational logic (from r_sz, r_img, r_fmt, r_row, cl) */
	wire [15:0] w0 = r_sz[15:0] == 16'd0 ? 16'd1 : r_sz[15:0];
	wire [15:0] h0 = r_sz[31:16] == 16'd0 ? 16'd1 : r_sz[31:16];
	wire [15:0] cnt = r_img[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : r_img[GHCI_IMG_COUNT +: 16];
	wire [15:0] ws, hs, dsh;
	am_shift #(.W(16), .SW(4)) u_ws (.a(w0), .amt(cl), .left(1'b0), .arith(1'b0), .y(ws));
	am_shift #(.W(16), .SW(4)) u_hs (.a(h0), .amt(cl), .left(1'b0), .arith(1'b0), .y(hs));
	am_shift #(.W(16), .SW(4)) u_dsh (.a(cnt), .amt(cl), .left(1'b0), .arith(1'b0), .y(dsh));
	wire [15:0] w = ws == 16'd0 ? 16'd1 : ws;
	wire [15:0] h = hs == 16'd0 ? 16'd1 : hs;
	wire [6:0] clay = layout(r_img, r_fmt, r_row);
	wire [16:0] m = clay[6:5] == 2'd0 ? 17'd0 : clay[6:5] == 2'd1 ? 17'd1 : clay[6:5] == 2'd2 ? 17'd3 : 17'd7;
	wire [16:0] wm;
	am_add #(.W(17)) u_wm (.a({1'b0, w}), .b(m), .ci(1'b0), .s(wm), .co(carry_unused[1]));
`ifdef MUT_TU_PITCHOFF
	wire [16:0] wr = {1'b0, w} | (m & 17'd0);
	wire unused_wm = &{1'b0, wm};
`else
	wire [16:0] wr = wm & ~m;
`endif
	wire [15:0] tw, th;
	am_add #(.W(16)) u_tw (.a({2'b00, w[15:2]}), .b(16'd0), .ci(w[1:0] != 2'd0), .s(tw), .co(carry_unused[2]));
	am_add #(.W(16)) u_th (.a({2'b00, h[15:2]}), .b(16'd0), .ci(h[1:0] != 2'd0), .s(th), .co(carry_unused[3]));
	wire [15:0] dl = r_img[GHCI_IMG_TYPE +: 3] != 3'd2 || dsh == 16'd0 ? 16'd1 : dsh;

	/* Stage S_MULP: am_mul instances */
	wire [31:0] t_w;
	wire [32:0] wrh_w;
	am_mul #(.AW(16), .BW(16)) u_t (.clk(1'b0), .en(1'b1), .a(r_tw), .b(r_th), .p(t_w));
	am_mul #(.AW(17), .BW(16)) u_wrh (.clk(1'b0), .en(1'b1), .a(r_wr), .b(r_h), .p(wrh_w));

	/* Stage S_PLANE: plane size calculation */
	wire [33:0] ps, p;
	am_shift #(.W(34), .SW(3)) u_ps (.a(r_clay[4] ? {2'b00, r_t} : {1'b0, r_wrh}),
		.amt(r_clay[2:0]), .left(1'b1), .arith(1'b0), .y(ps));
	am_add #(.W(34)) u_p (.a(r_clay[3] ? (r_clay[2:0] == 3'd1 ? {r_t[28:0], 5'd0} : {r_t[27:0], 6'd0}) : ps),
		.b(r_clay[3] && r_clay[2:0] != 3'd1 ? 34'd0 : 34'd63), .ci(1'b0), .s(p), .co(carry_unused[4]));
	wire [31:0] cp_w = {p[31:6], 6'd0};

	/* Stage S_MULD: plane x depth */
	wire [47:0] pd_w;
	am_mul #(.AW(32), .BW(16), .LAT(1)) u_pd (.clk(clk), .en(1'b1), .a(r_cp), .b(r_dl), .p(pd_w));

	/* Stage S_ACC: accumulation and level step */
	wire [31:0] nacc;
	wire [3:0] cl1;
	am_add #(.W(32)) u_nacc (.a(acc), .b(r_pd), .ci(1'b0), .s(nacc), .co(carry_unused[5]));
	am_add #(.W(4)) u_cl1 (.a(cl), .b(4'd0), .ci(1'b1), .s(cl1), .co(carry_unused[6]));

	/* the slot taken (lo) and the slot marked (s_off[8:4]), one-hot */
	reg [31:0] clr, set;
	integer o;
	always @(*)
		for (o = 0; o < 32; o = o + 1) begin
			clr[o] = st == S_IDLE && dirty != 32'd0 && lo == o[4:0];
			set[o] = mark && s_off[8:4] == o[4:0];
		end

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			dirty <= 32'd0;
			cs <= 5'd0;
			cl <= 4'd0;
			acc <= 32'd0;
			r_sz <= 32'd0;
			r_img <= 32'd0;
			r_fmt <= 21'd0;
			r_row <= 2'd0;
			r_clay <= 7'd0;
			r_tw <= 16'd0;
			r_th <= 16'd0;
			r_wr <= 17'd0;
			r_h <= 16'd0;
			r_dl <= 16'd0;
			r_t <= 32'd0;
			r_wrh <= 33'd0;
			r_cp <= 32'd0;
			r_pd <= 32'd0;
		end else begin
			dirty <= (dirty & ~clr) | set;
			case (st)
			S_IDLE: if (dirty != 32'd0) begin
				cs <= lo;
				st <= S_LOAD;
			end
			S_LOAD: begin
				r_sz  <= d_size[cs];
				r_img <= d_img[cs];
				r_fmt <= d_fmt[cs];
				r_row <= d_row[cs];
				cl <= 4'd0;
				acc <= 32'd0;
				st <= S_DIM;
			end
			S_DIM: begin
				r_clay <= clay;
				r_tw   <= tw;
				r_th   <= th;
				r_wr   <= wr;
				r_h    <= h;
				r_dl   <= dl;
				st <= S_MULP;
			end
			S_MULP: begin
				r_t   <= t_w;
				r_wrh <= wrh_w;
				st <= S_PLANE;
			end
			S_PLANE: begin
				r_cp <= cp_w;
				st <= S_MULD;
			end
			S_MULD: begin
				st <= S_MULD1;
			end
			S_MULD1: begin
				r_pd <= pd_w[31:0];
				st <= S_ACC;
			end
			S_ACC: begin
				acc <= nacc;
				d_off[{cs, cl1}]  <= nacc[31:6];
				d_plane[{cs, cl}] <= r_cp[31:6];
				cl <= cl1;
				if (cl == 4'd12) begin
					st <= S_IDLE;
				end else begin
					st <= S_DIM;
				end
			end
			default: st <= S_IDLE;
			endcase
		end
	end

	assign busy = st != S_IDLE || dirty != 32'd0;
	assign rd_base = d_base[rd_slot];
	assign rd_size = d_size[rd_slot];
	assign rd_image = d_img[rd_slot];
	assign rd_stride = d_stride[rd_slot];
	assign rd_samp = d_samp[rd_samp_slot];
	assign rd_lod = d_lod[rd_slot];
	assign rd_loff = rd_level == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level}], 6'd0};
	assign rd_loff1 = rd_level1 == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level1}], 6'd0};
	assign rd_loff2 = rd_level2 == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level2}], 6'd0};
	assign rd_loff3 = rd_level3 == 4'd0 ? 32'd0 : {d_off[{rd_slot, rd_level3}], 6'd0};
	assign rd_plane = {d_plane[{rd_slot, rd_level}], 6'd0};
	assign rd_plane1 = {d_plane[{rd_slot, rd_level1}], 6'd0};
	assign rd_plane2 = {d_plane[{rd_slot, rd_level2}], 6'd0};
	assign rd_plane3 = {d_plane[{rd_slot, rd_level3}], 6'd0};
	assign rd_fmt = d_fmt[rd_slot];
	wire [6:0] rlay = layout(d_img[rd_slot], d_fmt[rd_slot], d_row[rd_slot]);
	assign rd_row = rlay[6:5];

	wire unused_ok = &{1'b0, s_fs[8], pd_w[47:32], nacc[5:0], acc[5:0], rlay[4:0],
		p[33:32], p[5:0], r_t[31:29]};
endmodule

`default_nettype wire
