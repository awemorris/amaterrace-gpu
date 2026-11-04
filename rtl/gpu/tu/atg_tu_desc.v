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

	wire rst_inv = !rst_n;

	/* Clean single-cycle BRAMs for slot words 0-7 (rd_slot/rd_samp_slot port and cs port) */
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_q0, wslot_q1, wslot_q2, wslot_q3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_base_lo, wslot_base_hi, wslot_size_lo, wslot_size_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_img_lo, wslot_img_hi, wslot_str_lo, wslot_str_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_samp_lo, wslot_samp_hi, wslot_lod_lo, wslot_lod_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_fmt_lo, wslot_fmt_hi, wslot_row_lo, wslot_row_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] wslot_v4_lo, wslot_v4_hi;
	(* keep = "true", extract_reset = "no", max_fanout = 16 *) reg [31:0] wdata_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg we_base_q, we_size_q, we_img_q, we_str_q, we_samp_q, we_lod_q, we_fmt_q, we_row_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg we_size_cs_q, we_img_cs_q, we_fmt_cs_q, we_row_cs_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg we_base_vlo, we_base_vhi, we_size_vlo, we_size_vhi, we_img_vlo, we_img_vhi, we_str_vlo, we_str_vhi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg we_samp_vlo, we_samp_vhi, we_lod_vlo, we_lod_vhi, we_fmt_vlo, we_fmt_vhi, we_row_vlo, we_row_vhi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg mark_q_lo, mark_q_hi;
	reg [31:0] base_vld, size_vld, img_vld, str_vld, samp_vld, lod_vld, fmt_vld, row_vld, off_vld;

	wire [31:0] bram_base_rdata, bram_size_rdata, bram_img_rdata, bram_str_rdata, bram_samp_rdata, bram_lod_rdata;
	wire [20:0] bram_fmt_rdata;
	wire [1:0]  bram_row_rdata;
	wire [31:0] cs_size_rdata, cs_img_rdata;
	wire [20:0] cs_fmt_rdata;
	wire [1:0]  cs_row_rdata;

	(* keep = "true", extract_reset = "no" *) reg [31:0] rd_base_q, rd_size_q, rd_img_q, rd_str_q, rd_samp_q, rd_lod_q;
	(* keep = "true", extract_reset = "no" *) reg [20:0] rd_fmt_q;
	(* keep = "true", extract_reset = "no" *) reg [1:0]  rd_row_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] rd_slot_d1_base, rd_slot_d1_size, rd_slot_d1_img, rd_slot_d1_str;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] rd_slot_d1_samp, rd_slot_d1_lod, rd_slot_d1_fmt, rd_slot_d1_row;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [4:0] rd_slot_d1_off, rd_slot_d1_pl;
	reg rd_row_vld_d2;
	reg rd_off_vld_d1,  rd_off_vld_d2;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_base_vld_d2_lo, rd_base_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_size_vld_d2_lo, rd_size_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_img_vld_d2_lo,  rd_img_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_str_vld_d2_lo,  rd_str_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_samp_vld_d2_lo, rd_samp_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_lod_vld_d2_lo,  rd_lod_vld_d2_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg rd_fmt_vld_d2_0, rd_fmt_vld_d2_1, rd_fmt_vld_d2_2;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] rd_loff_en_lo, rd_loff_en_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0] rd_pl_en_lo,   rd_pl_en_hi;

	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_base (
		.clk(clk), .we(we_base_q), .waddr(wslot_q0), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_base_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_size (
		.clk(clk), .we(we_size_q), .waddr(wslot_q0), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_size_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_img (
		.clk(clk), .we(we_img_q), .waddr(wslot_q0), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_img_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_str (
		.clk(clk), .we(we_str_q), .waddr(wslot_q1), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_str_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_samp (
		.clk(clk), .we(we_samp_q), .waddr(wslot_q1), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_samp_slot), .rdata(bram_samp_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_lod (
		.clk(clk), .we(we_lod_q), .waddr(wslot_q1), .wdata(wdata_q),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_lod_rdata)
	);
	am_bram_sdp #(.W(21), .ADDR_W(5)) u_bram_fmt (
		.clk(clk), .we(we_fmt_q), .waddr(wslot_q2), .wdata(wdata_q[20:0]),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_fmt_rdata)
	);
	am_bram_sdp #(.W(2), .ADDR_W(5)) u_bram_row (
		.clk(clk), .we(we_row_q), .waddr(wslot_q2), .wdata(wdata_q[GHCI_TROW_ALIGN +: 2]),
		.re(1'b1), .raddr(rd_slot), .rdata(bram_row_rdata)
	);

	/* Second read port for cs (used by level offset calculation in S_LOAD) */
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_cs_size (
		.clk(clk), .we(we_size_cs_q), .waddr(wslot_q2), .wdata(wdata_q),
		.re(1'b1), .raddr(cs_bram), .rdata(cs_size_rdata)
	);
	am_bram_sdp #(.W(32), .ADDR_W(5)) u_bram_cs_img (
		.clk(clk), .we(we_img_cs_q), .waddr(wslot_q3), .wdata(wdata_q),
		.re(1'b1), .raddr(cs_bram), .rdata(cs_img_rdata)
	);
	am_bram_sdp #(.W(21), .ADDR_W(5)) u_bram_cs_fmt (
		.clk(clk), .we(we_fmt_cs_q), .waddr(wslot_q3), .wdata(wdata_q[20:0]),
		.re(1'b1), .raddr(cs_bram), .rdata(cs_fmt_rdata)
	);
	am_bram_sdp #(.W(2), .ADDR_W(5)) u_bram_cs_row (
		.clk(clk), .we(we_row_cs_q), .waddr(wslot_q3), .wdata(wdata_q[GHCI_TROW_ALIGN +: 2]),
		.re(1'b1), .raddr(cs_bram), .rdata(cs_row_rdata)
	);

	/* Clean single-cycle BRAMs for d_off and d_plane (4 parallel read ports) */
	(* keep = "true", equivalent_register_removal = "no" *) reg b_we_off_q, b_we_pl_q;
	(* keep = "true", extract_reset = "no" *) reg [8:0] b_waddr_off_q;
	(* keep = "true", extract_reset = "no" *) reg [8:0] b_waddr_pl_q;
	(* keep = "true", extract_reset = "no" *) reg [25:0] b_wdata_off_q;
	(* keep = "true", extract_reset = "no" *) reg [25:0] b_wdata_pl_q;

	(* keep = "true", extract_reset = "no" *) reg [8:0] raddr_off0_q, raddr_off1_q, raddr_off2_q, raddr_off3_q;
	(* keep = "true", extract_reset = "no" *) reg [8:0] raddr_pl0_q,  raddr_pl1_q,  raddr_pl2_q,  raddr_pl3_q;
	(* extract_reset = "no" *) reg [3:0] rlvl0_d1, rlvl1_d1, rlvl2_d1, rlvl3_d1;

	wire [25:0] bram_off0_rdata, bram_off1_rdata, bram_off2_rdata, bram_off3_rdata;
	wire [25:0] bram_pl0_rdata,  bram_pl1_rdata,  bram_pl2_rdata,  bram_pl3_rdata;
	(* keep = "true", extract_reset = "no" *) reg [25:0] rd_off0_q, rd_off1_q, rd_off2_q, rd_off3_q;
	(* keep = "true", extract_reset = "no" *) reg [25:0] rd_pl0_q,  rd_pl1_q,  rd_pl2_q,  rd_pl3_q;

	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_off0 (
		.clk(clk), .we(b_we_off_q), .waddr(b_waddr_off_q), .wdata(b_wdata_off_q),
		.re(1'b1), .raddr(raddr_off0_q), .rdata(bram_off0_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_off1 (
		.clk(clk), .we(b_we_off_q), .waddr(b_waddr_off_q), .wdata(b_wdata_off_q),
		.re(1'b1), .raddr(raddr_off1_q), .rdata(bram_off1_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_off2 (
		.clk(clk), .we(b_we_off_q), .waddr(b_waddr_off_q), .wdata(b_wdata_off_q),
		.re(1'b1), .raddr(raddr_off2_q), .rdata(bram_off2_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_off3 (
		.clk(clk), .we(b_we_off_q), .waddr(b_waddr_off_q), .wdata(b_wdata_off_q),
		.re(1'b1), .raddr(raddr_off3_q), .rdata(bram_off3_rdata)
	);

	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_pl0 (
		.clk(clk), .we(b_we_pl_q), .waddr(b_waddr_pl_q), .wdata(b_wdata_pl_q),
		.re(1'b1), .raddr(raddr_pl0_q), .rdata(bram_pl0_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_pl1 (
		.clk(clk), .we(b_we_pl_q), .waddr(b_waddr_pl_q), .wdata(b_wdata_pl_q),
		.re(1'b1), .raddr(raddr_pl1_q), .rdata(bram_pl1_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_pl2 (
		.clk(clk), .we(b_we_pl_q), .waddr(b_waddr_pl_q), .wdata(b_wdata_pl_q),
		.re(1'b1), .raddr(raddr_pl2_q), .rdata(bram_pl2_rdata)
	);
	am_bram_sdp #(.W(26), .ADDR_W(9)) u_bram_pl3 (
		.clk(clk), .we(b_we_pl_q), .waddr(b_waddr_pl_q), .wdata(b_wdata_pl_q),
		.re(1'b1), .raddr(raddr_pl3_q), .rdata(bram_pl3_rdata)
	);
	wire [8:0] s_fs;
	wire [6:0] carry_unused;
	am_sub #(.W(9)) u_s_fs (.a(st_idx[8:0]), .b(GHCI_S_TU), .bi(1'b0), .d(s_fs), .bo(carry_unused[0]));
	wire in_fs = !st_idx[9] && st_idx[8:0] >= GHCI_S_TU && st_idx[8:0] < GHCI_S_TU + 9'd256;
	wire in_vs = st_idx[9:8] == GHCI_S_TU_VS[9:8];
	(* keep = "true" *) wire in_tu = st_we && (in_fs || in_vs);
	(* keep = "true" *) wire in_tu_a = in_tu;
	(* keep = "true" *) wire in_tu_b = in_tu;
	/* The slot (vertex: 16-31) and the word. */
	(* keep = "true" *) wire [8:0] s_off = in_vs ? {1'b1, st_idx[7:0]} : {1'b0, s_fs[7:0]};
	(* keep = "true" *) wire [4:0] wslot_d_a = s_off[8:4];
	(* keep = "true" *) wire [4:0] wslot_d_b = s_off[8:4];
	wire mark = in_tu_b && (s_off[3:0] == GHCI_TEX_SIZE || s_off[3:0] == GHCI_TEX_IMAGE ||
		s_off[3:0] == GHCI_TEX_FORMAT || s_off[3:0] == GHCI_TEX_ROW);

	localparam [3:0] S_IDLE      = 4'd0,
	                 S_LOAD      = 4'd1,
	                 S_LOAD_B    = 4'd2,
	                 S_RUN       = 4'd3,
	                 S_DRAIN     = 4'd4,
	                 S_DONE      = 4'd5,
	                 S_LOAD_WAIT = 4'd6,
	                 S_LOAD_FMT  = 4'd7;

	(* max_fanout = 16 *) reg [3:0] st;
	reg [31:0] dirty;
	(* keep = "true", max_fanout = 16 *) reg r_busy;
	(* keep = "true", equivalent_register_removal = "no" *) reg [4:0] cs_0, cs_1, cs_2, cs_3, cs_bram;
	(* keep = "true", equivalent_register_removal = "no" *) reg [4:0] cs_vld_clr_lo, cs_vld_clr_hi, cs_vld_off_lo, cs_vld_off_hi, cs_waddr;
	(* keep = "true", max_fanout = 16, equivalent_register_removal = "no" *) reg [3:0] cl;
	(* extract_reset = "no" *) reg [31:0] acc;

	/* Registers for pipelined calculation (1 level per cycle in S_RUN) */
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_sz_raw;
	(* keep = "true", extract_reset = "no" *) reg [31:0] r_img_raw;
	(* keep = "true", extract_reset = "no" *) reg [20:0] r_fmt_raw;
	(* keep = "true", extract_reset = "no" *) reg [1:0]  r_row_raw;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg cs_size_vld_lo, cs_size_vld_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg cs_img_vld_lo,  cs_img_vld_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg cs_fmt_vld_lo,  cs_fmt_vld_hi;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg cs_row_vld_q;
	(* keep = "true", extract_reset = "no", max_fanout = 16 *) reg [31:0] r_sz;
	(* keep = "true", extract_reset = "no", max_fanout = 16 *) reg [31:0] r_img;
	(* keep = "true", extract_reset = "no", max_fanout = 16, rom_style = "distributed" *) reg [20:0] r_fmt;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0]  r_row;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no", rom_style = "distributed" *) reg [6:0] r_clay_a, r_clay_b0, r_clay_c;
	(* equivalent_register_removal = "no", extract_reset = "no", max_fanout = 10, rom_style = "distributed" *) reg [6:0] r_clay_b1;

	reg [8:0]  v_p;
	(* keep = "true", equivalent_register_removal = "no" *) reg [6:0] v_p9_s;
	(* extract_reset = "no", srl_style = "register" *) reg [3:0]  cl_p  [0:9];
	(* extract_reset = "no", srl_style = "register" *) reg [3:0]  cl1_p [0:9];

	(* extract_reset = "no" *) reg [15:0] r_w0, r_h0, r_cnt;
	(* extract_reset = "no" *) reg r_is3d;
	(* extract_reset = "no" *) reg [15:0] r_w;
	(* extract_reset = "no" *) reg [15:0] r_h, r_h1;
	(* extract_reset = "no", srl_style = "register" *) reg [15:0] r_dl, r_dl1, r_dl2, r_dl3, r_dl4, r_dl5, r_dl6;
	(* extract_reset = "no" *) reg [15:0] r_tw;
	(* extract_reset = "no" *) reg [15:0] r_th;
	(* extract_reset = "no" *) reg [16:0] r_wr;

	(* extract_reset = "no" *) reg [31:0] r_t;
	(* extract_reset = "no" *) reg [28:0] r_t5;
	(* extract_reset = "no" *) reg [32:0] r_wrh;
	(* extract_reset = "no" *) reg [33:0] r_ps;
	(* extract_reset = "no" *) reg [31:0] r_cp;
	(* extract_reset = "no", srl_style = "register" *) reg [25:0] r_cp7, r_cp8, r_cp9;
	(* extract_reset = "no" *) reg [31:0] r_pd;

	/* Fast 3-level 6-input-bounded priority encoder for lowest marked slot (<= 4 LUTs) */
	(* keep = "true" *) wire [7:0] nib_nz;
	(* keep = "true" *) wire [1:0] nib_lo [0:7];
	genvar gn;
	generate
	for (gn = 0; gn < 8; gn = gn + 1) begin : g_nib
		assign nib_nz[gn] = |dirty[gn*4 +: 4];
		assign nib_lo[gn] = dirty[gn*4 + 0] ? 2'd0 :
		                    dirty[gn*4 + 1] ? 2'd1 :
		                    dirty[gn*4 + 2] ? 2'd2 : 2'd3;
	end
	endgenerate

	(* keep = "true" *) wire [3:0] pair_nz;
	(* keep = "true" *) wire [2:0] pair_lo [0:3];
	genvar gp;
	generate
	for (gp = 0; gp < 4; gp = gp + 1) begin : g_pair
		assign pair_nz[gp] = nib_nz[gp*2] | nib_nz[gp*2 + 1];
		assign pair_lo[gp] = nib_nz[gp*2] ? {1'b0, nib_lo[gp*2]} : {1'b1, nib_lo[gp*2 + 1]};
	end
	endgenerate

	(* keep = "true" *) wire lo_half_nz = pair_nz[0] | pair_nz[1];
	(* keep = "true" *) wire dirty_nz   = lo_half_nz | pair_nz[2] | pair_nz[3];
	(* keep = "true" *) wire [3:0] half_lo0 = pair_nz[0] ? {1'b0, pair_lo[0]} : {1'b1, pair_lo[1]};
	(* keep = "true" *) wire [3:0] half_lo1 = pair_nz[2] ? {1'b0, pair_lo[2]} : {1'b1, pair_lo[3]};
	wire [4:0] lo = lo_half_nz ? {1'b0, half_lo0} : {1'b1, half_lo1};

	/* Stage S_DIM combinational logic (from r_w0, r_h0, r_cnt, r_is3d, cl) */
	wire [15:0] ws, hs, dsh;
	am_shift #(.W(16), .SW(4)) u_ws (.a(r_w0), .amt(cl), .left(1'b0), .arith(1'b0), .y(ws));
	am_shift #(.W(16), .SW(4)) u_hs (.a(r_h0), .amt(cl), .left(1'b0), .arith(1'b0), .y(hs));
	am_shift #(.W(16), .SW(4)) u_dsh (.a(r_cnt), .amt(cl), .left(1'b0), .arith(1'b0), .y(dsh));
	wire [15:0] w = ws == 16'd0 ? 16'd1 : ws;
	wire [15:0] h = hs == 16'd0 ? 16'd1 : hs;
	(* keep = "true" *) wire [6:0] clay = layout(r_img, r_fmt, r_row);
	wire [16:0] m = r_clay_a[6:5] == 2'd0 ? 17'd0 : r_clay_a[6:5] == 2'd1 ? 17'd1 : r_clay_a[6:5] == 2'd2 ? 17'd3 : 17'd7;
	wire [16:0] wm;
	am_add #(.W(17)) u_wm (.a({1'b0, r_w}), .b(m), .ci(1'b0), .s(wm), .co(carry_unused[1]));
`ifdef MUT_TU_PITCHOFF
	wire [16:0] wr = {1'b0, r_w} | (m & 17'd0);
	wire unused_wm = &{1'b0, wm};
`else
	wire [16:0] wr = wm & ~m;
`endif
	wire [15:0] tw, th;
	am_add #(.W(16)) u_tw (.a({2'b00, r_w[15:2]}), .b(16'd0), .ci(r_w[1:0] != 2'd0), .s(tw), .co(carry_unused[2]));
	am_add #(.W(16)) u_th (.a({2'b00, r_h[15:2]}), .b(16'd0), .ci(r_h[1:0] != 2'd0), .s(th), .co(carry_unused[3]));
	wire [15:0] dl = !r_is3d || dsh == 16'd0 ? 16'd1 : dsh;

	/* Stage 2..3: am_mul instances */
	wire [31:0] t_w;
	wire [32:0] wrh_w;
	am_mul #(.AW(16), .BW(16), .LAT(2)) u_t (.clk(clk), .en(1'b1), .a(r_tw), .b(r_th), .p(t_w));
	am_mul #(.AW(17), .BW(16), .LAT(2)) u_wrh (.clk(clk), .en(1'b1), .a(r_wr), .b(r_h1), .p(wrh_w));

	/* Stage 5..6: plane size calculation */
	wire [3:0] clay4_s    = {4{r_clay_b0[4]}};
	wire [3:0] clay3_s    = {4{r_clay_c[3]}};
	wire [3:0] clay_is1_s = {4{r_clay_c[2:0] == 3'd1}};
	(* keep = "true" *) wire [33:0] ps_in = {
		clay4_s[3] ? {2'b00, r_t[31:25]} : {1'b0, r_wrh[32:25]},
		clay4_s[2] ? r_t[24:17]          : r_wrh[24:17],
		clay4_s[1] ? r_t[16:9]           : r_wrh[16:9],
		clay4_s[0] ? r_t[8:0]            : r_wrh[8:0]
	};
	wire [33:0] ps, p;
	am_shift #(.W(34), .SW(3)) u_ps (.a(ps_in),
		.amt(r_clay_b1[2:0]), .left(1'b1), .arith(1'b0), .y(ps));
	wire [33:0] t5_1 = {r_t5[28:0], 5'd0};
	wire [33:0] t5_2 = {r_t5[27:0], 6'd0};
	(* keep = "true" *) wire [33:0] p_in = {
		clay3_s[3] ? (clay_is1_s[3] ? t5_1[33:25] : t5_2[33:25]) : r_ps[33:25],
		clay3_s[2] ? (clay_is1_s[2] ? t5_1[24:17] : t5_2[24:17]) : r_ps[24:17],
		clay3_s[1] ? (clay_is1_s[1] ? t5_1[16:9]  : t5_2[16:9])  : r_ps[16:9],
		clay3_s[0] ? (clay_is1_s[0] ? t5_1[8:0]   : t5_2[8:0])   : r_ps[8:0]
	};
	am_add #(.W(34)) u_p (.a(p_in),
		.b(clay3_s[0] && !clay_is1_s[0] ? 34'd0 : 34'd63), .ci(1'b0), .s(p), .co(carry_unused[4]));
	wire [31:0] cp_w = {p[31:6], 6'd0};

	/* Stage 7..8: plane x depth */
	wire [47:0] pd_w;
	am_mul #(.AW(32), .BW(16), .LAT(2)) u_pd (.clk(clk), .en(1'b1), .a(r_cp), .b(r_dl6), .p(pd_w));

	/* Stage S_ACC: accumulation and level step */
	wire [31:0] nacc;
	wire [3:0] cl1;
	am_add #(.W(32)) u_nacc (.a(acc), .b(r_pd), .ci(1'b0), .s(nacc), .co(carry_unused[5]));
	am_add #(.W(4)) u_cl1 (.a(cl), .b(4'd0), .ci(1'b1), .s(cl1), .co(carry_unused[6]));

	/* the slot taken (cs in S_LOAD) and the slot marked (wslot_v4), one-hot */
	(* keep = "true", equivalent_register_removal = "no" *) reg [4:0] load_clr_s;
	(* keep = "true", equivalent_register_removal = "no" *) reg acc_clr_lo_q, acc_clr_hi_q;
	wire done_lo     = (st == S_DONE);
	wire done_hi     = (st == S_DONE);
	(* keep = "true", equivalent_register_removal = "no" *) reg [6:0] ce_lw;
	wire [5:0] ce_lf = {6{st == S_LOAD_FMT}};
	wire we_base_d = in_tu_a && (s_off[3:0] == GHCI_TEX_BASE);
	wire we_size_d = in_tu_a && (s_off[3:0] == GHCI_TEX_SIZE);
	wire we_img_d  = in_tu_a && (s_off[3:0] == GHCI_TEX_IMAGE);
	wire we_str_d  = in_tu_a && (s_off[3:0] == GHCI_TEX_LAYER_STRIDE);
	wire we_samp_d = in_tu_a && (s_off[3:0] == GHCI_TEX_SAMPLER);
	wire we_lod_d  = in_tu_a && (s_off[3:0] == GHCI_TEX_LOD);
	wire we_fmt_d  = in_tu_a && (s_off[3:0] == GHCI_TEX_FORMAT);
	wire we_row_d  = in_tu_a && (s_off[3:0] == GHCI_TEX_ROW);

	reg [31:0] clr, set;
	integer o;
	always @(*) begin
		for (o = 0; o < 16; o = o + 1) begin
			clr[o] = load_clr_s[0] && (cs_vld_clr_lo == o[4:0]);
			set[o] = mark_q_lo && (wslot_v4_lo == o[4:0]);
		end
		for (o = 16; o < 32; o = o + 1) begin
			clr[o] = load_clr_s[1] && (cs_vld_clr_hi == o[4:0]);
			set[o] = mark_q_hi && (wslot_v4_hi == o[4:0]);
		end
	end

	integer pi;
	always @(posedge clk) begin
		if (rst_inv) begin
			st <= S_IDLE;
			dirty <= 32'd0;
			r_busy <= 1'b0;
			cs_0 <= 5'd0; cs_1 <= 5'd0; cs_2 <= 5'd0; cs_3 <= 5'd0; cs_bram <= 5'd0;
			cs_vld_clr_lo <= 5'd0; cs_vld_clr_hi <= 5'd0;
			cs_vld_off_lo <= 5'd0; cs_vld_off_hi <= 5'd0; cs_waddr <= 5'd0;
			cl <= 4'd0;
			we_base_q <= 1'b0; we_size_q <= 1'b0; we_img_q <= 1'b0; we_str_q <= 1'b0;
			we_samp_q <= 1'b0; we_lod_q  <= 1'b0; we_fmt_q <= 1'b0; we_row_q <= 1'b0;
			we_size_cs_q <= 1'b0; we_img_cs_q <= 1'b0; we_fmt_cs_q <= 1'b0; we_row_cs_q <= 1'b0;
			we_base_vlo <= 1'b0; we_base_vhi <= 1'b0;
			we_size_vlo <= 1'b0; we_size_vhi <= 1'b0;
			we_img_vlo  <= 1'b0; we_img_vhi  <= 1'b0;
			we_str_vlo  <= 1'b0; we_str_vhi  <= 1'b0;
			we_samp_vlo <= 1'b0; we_samp_vhi <= 1'b0;
			we_lod_vlo  <= 1'b0; we_lod_vhi  <= 1'b0;
			we_fmt_vlo  <= 1'b0; we_fmt_vhi  <= 1'b0;
			we_row_vlo  <= 1'b0; we_row_vhi  <= 1'b0;
			mark_q_lo   <= 1'b0; mark_q_hi   <= 1'b0;
			base_vld  <= 32'd0;
			size_vld  <= 32'd0;
			img_vld   <= 32'd0;
			str_vld   <= 32'd0;
			samp_vld  <= 32'd0;
			lod_vld   <= 32'd0;
			fmt_vld   <= 32'd0;
			row_vld   <= 32'd0;
			off_vld   <= 32'd0;
			rd_base_vld_d2_lo <= 1'b0; rd_base_vld_d2_hi <= 1'b0;
			rd_size_vld_d2_lo <= 1'b0; rd_size_vld_d2_hi <= 1'b0;
			rd_img_vld_d2_lo  <= 1'b0; rd_img_vld_d2_hi  <= 1'b0;
			rd_str_vld_d2_lo  <= 1'b0; rd_str_vld_d2_hi  <= 1'b0;
			rd_samp_vld_d2_lo <= 1'b0; rd_samp_vld_d2_hi <= 1'b0;
			rd_lod_vld_d2_lo  <= 1'b0; rd_lod_vld_d2_hi  <= 1'b0;
			rd_fmt_vld_d2_0   <= 1'b0; rd_fmt_vld_d2_1   <= 1'b0; rd_fmt_vld_d2_2 <= 1'b0;
			rd_row_vld_d2     <= 1'b0;
			rd_off_vld_d1     <= 1'b0; rd_off_vld_d2     <= 1'b0;
			rd_loff_en_lo  <= 4'd0; rd_loff_en_hi     <= 4'd0;
			rd_pl_en_lo    <= 4'd0; rd_pl_en_hi       <= 4'd0;
			v_p        <= 9'd0;
			v_p9_s     <= 7'd0;
			acc_clr_lo_q <= 1'b0;
			acc_clr_hi_q <= 1'b0;
			load_clr_s <= 5'd0;
			ce_lw      <= 7'd0;
			b_we_off_q <= 1'b0;
			b_we_pl_q  <= 1'b0;
		end else begin
			acc_clr_lo_q <= (st == S_LOAD_WAIT);
			acc_clr_hi_q <= (st == S_LOAD_WAIT);
			load_clr_s   <= {5{(st == S_IDLE) && dirty_nz && !mark && !mark_q_lo}};
			ce_lw        <= {7{load_clr_s[2]}};
			we_base_q <= we_base_d; we_base_vlo <= we_base_d; we_base_vhi <= we_base_d;
			we_size_q <= we_size_d; we_size_cs_q <= we_size_d; we_size_vlo <= we_size_d; we_size_vhi <= we_size_d;
			we_img_q  <= we_img_d;  we_img_cs_q  <= we_img_d;  we_img_vlo  <= we_img_d;  we_img_vhi  <= we_img_d;
			we_str_q  <= we_str_d;  we_str_vlo  <= we_str_d;  we_str_vhi  <= we_str_d;
			we_samp_q <= we_samp_d; we_samp_vlo <= we_samp_d; we_samp_vhi <= we_samp_d;
			we_lod_q  <= we_lod_d;  we_lod_vlo  <= we_lod_d;  we_lod_vhi  <= we_lod_d;
			we_fmt_q  <= we_fmt_d;  we_fmt_cs_q  <= we_fmt_d;  we_fmt_vlo  <= we_fmt_d;  we_fmt_vhi  <= we_fmt_d;
			we_row_q  <= we_row_d;  we_row_cs_q  <= we_row_d;  we_row_vlo  <= we_row_d;  we_row_vhi  <= we_row_d;
			mark_q_lo <= mark;
			mark_q_hi <= mark;

			for (o = 0; o < 16; o = o + 1) begin
				if (we_base_vlo && (wslot_base_lo == o[4:0])) base_vld[o] <= 1'b1;
				if (we_size_vlo && (wslot_size_lo == o[4:0])) size_vld[o] <= 1'b1;
				if (we_img_vlo  && (wslot_img_lo  == o[4:0])) img_vld[o]  <= 1'b1;
				if (we_str_vlo  && (wslot_str_lo  == o[4:0])) str_vld[o]  <= 1'b1;
				if (we_samp_vlo && (wslot_samp_lo == o[4:0])) samp_vld[o] <= 1'b1;
				if (we_lod_vlo  && (wslot_lod_lo  == o[4:0])) lod_vld[o]  <= 1'b1;
				if (we_fmt_vlo  && (wslot_fmt_lo  == o[4:0])) fmt_vld[o]  <= 1'b1;
				if (we_row_vlo  && (wslot_row_lo  == o[4:0])) row_vld[o]  <= 1'b1;
				if (done_lo     && (cs_vld_off_lo == o[4:0])) off_vld[o] <= 1'b1;
			end
			for (o = 16; o < 32; o = o + 1) begin
				if (we_base_vhi && (wslot_base_hi == o[4:0])) base_vld[o] <= 1'b1;
				if (we_size_vhi && (wslot_size_hi == o[4:0])) size_vld[o] <= 1'b1;
				if (we_img_vhi  && (wslot_img_hi  == o[4:0])) img_vld[o]  <= 1'b1;
				if (we_str_vhi  && (wslot_str_hi  == o[4:0])) str_vld[o]  <= 1'b1;
				if (we_samp_vhi && (wslot_samp_hi == o[4:0])) samp_vld[o] <= 1'b1;
				if (we_lod_vhi  && (wslot_lod_hi  == o[4:0])) lod_vld[o]  <= 1'b1;
				if (we_fmt_vhi  && (wslot_fmt_hi  == o[4:0])) fmt_vld[o]  <= 1'b1;
				if (we_row_vhi  && (wslot_row_hi  == o[4:0])) row_vld[o]  <= 1'b1;
				if (done_hi     && (cs_vld_off_hi == o[4:0])) off_vld[o] <= 1'b1;
			end

			rd_base_vld_d2_lo <= base_vld[rd_slot_d1_base]; rd_base_vld_d2_hi <= base_vld[rd_slot_d1_base];
			rd_size_vld_d2_lo <= size_vld[rd_slot_d1_size]; rd_size_vld_d2_hi <= size_vld[rd_slot_d1_size];
			rd_img_vld_d2_lo  <= img_vld[rd_slot_d1_img];   rd_img_vld_d2_hi  <= img_vld[rd_slot_d1_img];
			rd_str_vld_d2_lo  <= str_vld[rd_slot_d1_str];   rd_str_vld_d2_hi  <= str_vld[rd_slot_d1_str];
			rd_samp_vld_d2_lo <= samp_vld[rd_slot_d1_samp]; rd_samp_vld_d2_hi <= samp_vld[rd_slot_d1_samp];
			rd_lod_vld_d2_lo  <= lod_vld[rd_slot_d1_lod];   rd_lod_vld_d2_hi  <= lod_vld[rd_slot_d1_lod];
			rd_fmt_vld_d2_0   <= fmt_vld[rd_slot_d1_fmt];   rd_fmt_vld_d2_1   <= fmt_vld[rd_slot_d1_fmt]; rd_fmt_vld_d2_2 <= fmt_vld[rd_slot_d1_fmt];
			rd_row_vld_d2     <= row_vld[rd_slot_d1_row];
			rd_off_vld_d1     <= off_vld[rd_slot_d1_off];   rd_off_vld_d2     <= rd_off_vld_d1;

			rd_loff_en_lo[0] <= (rlvl0_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_hi[0] <= (rlvl0_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_lo[1] <= (rlvl1_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_hi[1] <= (rlvl1_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_lo[2] <= (rlvl2_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_hi[2] <= (rlvl2_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_lo[3] <= (rlvl3_d1 != 4'd0) && rd_off_vld_d2;
			rd_loff_en_hi[3] <= (rlvl3_d1 != 4'd0) && rd_off_vld_d2;
			for (o = 0; o < 4; o = o + 1) begin
				rd_pl_en_lo[o] <= rd_off_vld_d2;
				rd_pl_en_hi[o] <= rd_off_vld_d2;
			end

			dirty <= (dirty & ~clr) | set;
			r_busy <= in_tu_b || mark_q_lo || dirty_nz || (st != S_IDLE && st != S_DONE);
			b_we_off_q <= v_p9_s[6];
			b_we_pl_q  <= v_p9_s[6];

			v_p    <= {v_p[7:0], st == S_RUN};
			v_p9_s <= {7{v_p[8]}};

			case (st)
			S_IDLE: if (dirty_nz && !mark && !mark_q_lo) begin
				cs_0          <= lo;
				cs_bram       <= lo;
				cs_vld_clr_lo <= lo;
				cs_vld_clr_hi <= lo;
				st <= S_LOAD;
			end
			S_LOAD: begin
				cs_1 <= cs_0;
				cs_2 <= cs_0;
				cs_3 <= cs_0;
				cl <= 4'd0;
				st <= S_LOAD_WAIT;
			end
			S_LOAD_WAIT: begin
				cs_vld_off_lo <= cs_1;
				cs_vld_off_hi <= cs_1;
				cs_waddr      <= cs_2;
				st <= S_LOAD_FMT;
			end
			S_LOAD_FMT:  st <= S_LOAD_B;
			S_LOAD_B:    st <= S_RUN;
			S_RUN: begin
				cl <= cl1;
				if (cl == 4'd12)
					st <= S_DRAIN;
			end
			S_DRAIN: begin
				if (v_p9_s[6] && cl_p[9] == 4'd12)
					st <= S_DONE;
			end
			S_DONE: st <= S_IDLE;
			default: st <= S_IDLE;
			endcase
		end
	end

	always @(posedge clk) begin
		wslot_q0 <= wslot_d_a;
		wslot_q1 <= wslot_d_a;
		wslot_q2 <= wslot_d_a;
		wslot_q3 <= wslot_d_a;
		wslot_base_lo <= wslot_d_b; wslot_base_hi <= wslot_d_b;
		wslot_size_lo <= wslot_d_b; wslot_size_hi <= wslot_d_b;
		wslot_img_lo  <= wslot_d_b; wslot_img_hi  <= wslot_d_b;
		wslot_str_lo  <= wslot_d_b; wslot_str_hi  <= wslot_d_b;
		wslot_samp_lo <= wslot_d_b; wslot_samp_hi <= wslot_d_b;
		wslot_lod_lo  <= wslot_d_b; wslot_lod_hi  <= wslot_d_b;
		wslot_fmt_lo  <= wslot_d_b; wslot_fmt_hi  <= wslot_d_b;
		wslot_row_lo  <= wslot_d_b; wslot_row_hi  <= wslot_d_b;
		wslot_v4_lo   <= wslot_d_b; wslot_v4_hi   <= wslot_d_b;
		wdata_q  <= st_wdata;

		rd_base_q <= bram_base_rdata;
		rd_size_q <= bram_size_rdata;
		rd_img_q  <= bram_img_rdata;
		rd_str_q  <= bram_str_rdata;
		rd_samp_q <= bram_samp_rdata;
		rd_lod_q  <= bram_lod_rdata;
		rd_fmt_q  <= bram_fmt_rdata;
		rd_row_q  <= bram_row_rdata;

		rd_slot_d1_base <= rd_slot;
		rd_slot_d1_size <= rd_slot;
		rd_slot_d1_img  <= rd_slot;
		rd_slot_d1_str  <= rd_slot;
		rd_slot_d1_samp <= rd_samp_slot;
		rd_slot_d1_lod  <= rd_slot;
		rd_slot_d1_fmt  <= rd_slot;
		rd_slot_d1_row  <= rd_slot;
		rd_slot_d1_off  <= rd_slot;
		rd_slot_d1_pl   <= rd_slot;

		raddr_off0_q <= {rd_slot_d1_off, rd_level};
		raddr_off1_q <= {rd_slot_d1_off, rd_level1};
		raddr_off2_q <= {rd_slot_d1_off, rd_level2};
		raddr_off3_q <= {rd_slot_d1_off, rd_level3};
		raddr_pl0_q  <= {rd_slot_d1_pl,  rd_level};
		raddr_pl1_q  <= {rd_slot_d1_pl,  rd_level1};
		raddr_pl2_q  <= {rd_slot_d1_pl,  rd_level2};
		raddr_pl3_q  <= {rd_slot_d1_pl,  rd_level3};
		rlvl0_d1 <= raddr_off0_q[3:0];
		rlvl1_d1 <= raddr_off1_q[3:0];
		rlvl2_d1 <= raddr_off2_q[3:0];
		rlvl3_d1 <= raddr_off3_q[3:0];
		rd_off0_q <= bram_off0_rdata;
		rd_off1_q <= bram_off1_rdata;
		rd_off2_q <= bram_off2_rdata;
		rd_off3_q <= bram_off3_rdata;
		rd_pl0_q  <= bram_pl0_rdata;
		rd_pl1_q  <= bram_pl1_rdata;
		rd_pl2_q  <= bram_pl2_rdata;
		rd_pl3_q  <= bram_pl3_rdata;

		cl_p[0]  <= cl;
		cl1_p[0] <= cl1;
		for (pi = 1; pi < 10; pi = pi + 1) begin
			cl_p[pi]  <= cl_p[pi - 1];
			cl1_p[pi] <= cl1_p[pi - 1];
		end
		r_w   <= w;
		r_h   <= h;
		r_dl  <= dl;
		r_tw  <= tw;
		r_th  <= th;
		r_wr  <= wr;
		r_h1  <= r_h;
		r_dl1 <= r_dl;
		r_dl2 <= r_dl1;
		r_dl3 <= r_dl2;
		r_dl4 <= r_dl3;
		r_t   <= t_w;
		r_wrh <= wrh_w;
		r_dl5 <= r_dl4;
		r_ps  <= ps;
		r_t5  <= r_t[28:0];
		r_dl6 <= r_dl5;
		r_cp  <= cp_w;
		r_cp7 <= r_cp[31:6];
		r_cp8 <= r_cp7;
		r_cp9 <= r_cp8;
		r_pd  <= pd_w[31:0];

		if (ce_lw[6]) begin
			cs_size_vld_lo <= size_vld[cs_0];
			cs_size_vld_hi <= size_vld[cs_0];
			cs_img_vld_lo  <= img_vld[cs_1];
			cs_img_vld_hi  <= img_vld[cs_1];
			cs_fmt_vld_lo  <= fmt_vld[cs_2];
			cs_fmt_vld_hi  <= fmt_vld[cs_2];
			cs_row_vld_q   <= row_vld[cs_3];
		end
		if (acc_clr_lo_q) acc[15:0]  <= 16'd0;
		else if (v_p9_s[0]) acc[15:0] <= nacc[15:0];
		if (acc_clr_hi_q) acc[31:16] <= 16'd0;
		else if (v_p9_s[1]) acc[31:16] <= nacc[31:16];

		if (v_p9_s[2]) begin
			b_waddr_off_q <= {cs_waddr, cl1_p[9]};
			b_waddr_pl_q  <= {cs_waddr, cl_p[9]};
		end
		if (v_p9_s[3]) b_wdata_off_q[12:0]  <= nacc[18:6];
		if (v_p9_s[4]) b_wdata_off_q[25:13] <= nacc[31:19];
		if (v_p9_s[5]) b_wdata_pl_q[12:0]   <= r_cp9[12:0];
		if (v_p9_s[6]) b_wdata_pl_q[25:13]  <= r_cp9[25:13];

		if (ce_lw[0]) r_sz_raw[15:0]   <= cs_size_rdata[15:0];
		if (ce_lw[1]) r_sz_raw[31:16]  <= cs_size_rdata[31:16];
		if (ce_lw[2]) r_img_raw[15:0]  <= cs_img_rdata[15:0];
		if (ce_lw[3]) r_img_raw[31:16] <= cs_img_rdata[31:16];
		if (ce_lw[4]) r_fmt_raw[15:0]  <= cs_fmt_rdata[15:0];
		if (ce_lw[5]) begin
			r_fmt_raw[20:16] <= cs_fmt_rdata[20:16];
			r_row_raw        <= cs_row_rdata;
		end

		if (ce_lf[0]) r_sz[15:0]   <= cs_size_vld_lo ? r_sz_raw[15:0]   : 16'd0;
		if (ce_lf[1]) r_sz[31:16]  <= cs_size_vld_hi ? r_sz_raw[31:16]  : 16'd0;
		if (ce_lf[2]) r_img[15:0]  <= cs_img_vld_lo  ? r_img_raw[15:0]  : 16'd0;
		if (ce_lf[3]) r_img[31:16] <= cs_img_vld_hi  ? r_img_raw[31:16] : 16'd0;
		if (ce_lf[4]) r_fmt[15:0]  <= cs_fmt_vld_lo  ? r_fmt_raw[15:0]  : 16'd0;
		if (ce_lf[5]) begin
			r_fmt[20:16] <= cs_fmt_vld_hi ? r_fmt_raw[20:16] : 5'd0;
			r_row        <= cs_row_vld_q  ? r_row_raw        : 2'd0;
		end

		r_w0  <= r_sz[15:0] == 16'd0 ? 16'd1 : r_sz[15:0];
		r_h0  <= r_sz[31:16] == 16'd0 ? 16'd1 : r_sz[31:16];
		r_cnt <= r_img[GHCI_IMG_COUNT +: 16] == 16'd0 ? 16'd1 : r_img[GHCI_IMG_COUNT +: 16];
		r_clay_a     <= clay;
		r_clay_b0    <= clay;
		r_clay_b1    <= clay;
		r_clay_c     <= clay;
		r_is3d       <= r_img[GHCI_IMG_TYPE +: 3] == 3'd2;
	end

	assign busy = r_busy;
	assign rd_base   = {rd_base_vld_d2_hi ? rd_base_q[31:16] : 16'd0, rd_base_vld_d2_lo ? rd_base_q[15:0] : 16'd0};
	assign rd_size   = {rd_size_vld_d2_hi ? rd_size_q[31:16] : 16'd0, rd_size_vld_d2_lo ? rd_size_q[15:0] : 16'd0};
	assign rd_image  = {rd_img_vld_d2_hi  ? rd_img_q[31:16]  : 16'd0, rd_img_vld_d2_lo  ? rd_img_q[15:0]  : 16'd0};
	assign rd_stride = {rd_str_vld_d2_hi  ? rd_str_q[31:16]  : 16'd0, rd_str_vld_d2_lo  ? rd_str_q[15:0]  : 16'd0};
	assign rd_samp   = {rd_samp_vld_d2_hi ? rd_samp_q[31:16] : 16'd0, rd_samp_vld_d2_lo ? rd_samp_q[15:0] : 16'd0};
	assign rd_lod    = {rd_lod_vld_d2_hi  ? rd_lod_q[31:16]  : 16'd0, rd_lod_vld_d2_lo  ? rd_lod_q[15:0]  : 16'd0};
	assign rd_loff   = {rd_loff_en_hi[0] ? rd_off0_q[25:13] : 13'd0, rd_loff_en_lo[0] ? rd_off0_q[12:0] : 13'd0, 6'd0};
	assign rd_loff1  = {rd_loff_en_hi[1] ? rd_off1_q[25:13] : 13'd0, rd_loff_en_lo[1] ? rd_off1_q[12:0] : 13'd0, 6'd0};
	assign rd_loff2  = {rd_loff_en_hi[2] ? rd_off2_q[25:13] : 13'd0, rd_loff_en_lo[2] ? rd_off2_q[12:0] : 13'd0, 6'd0};
	assign rd_loff3  = {rd_loff_en_hi[3] ? rd_off3_q[25:13] : 13'd0, rd_loff_en_lo[3] ? rd_off3_q[12:0] : 13'd0, 6'd0};
	assign rd_plane  = {rd_pl_en_hi[0]   ? rd_pl0_q[25:13]  : 13'd0, rd_pl_en_lo[0]   ? rd_pl0_q[12:0]  : 13'd0, 6'd0};
	assign rd_plane1 = {rd_pl_en_hi[1]   ? rd_pl1_q[25:13]  : 13'd0, rd_pl_en_lo[1]   ? rd_pl1_q[12:0]  : 13'd0, 6'd0};
	assign rd_plane2 = {rd_pl_en_hi[2]   ? rd_pl2_q[25:13]  : 13'd0, rd_pl_en_lo[2]   ? rd_pl2_q[12:0]  : 13'd0, 6'd0};
	assign rd_plane3 = {rd_pl_en_hi[3]   ? rd_pl3_q[25:13]  : 13'd0, rd_pl_en_lo[3]   ? rd_pl3_q[12:0]  : 13'd0, 6'd0};
	assign rd_fmt    = {rd_fmt_vld_d2_2 ? rd_fmt_q[20:14] : 7'd0, rd_fmt_vld_d2_1 ? rd_fmt_q[13:7] : 7'd0, rd_fmt_vld_d2_0 ? rd_fmt_q[6:0] : 7'd0};
	assign rd_row    = rd_row_vld_d2 ? rd_row_q : 2'd0;

	wire unused_ok = &{1'b0, s_fs[8], pd_w[47:32], nacc[5:0], acc[5:0],
		p[33:32], p[5:0], r_t[31:29], r_cp[5:0], r_clay_a[4:0], r_clay_b0[6:5], r_clay_b0[3:0],
		r_clay_b1[6:3], r_clay_c[6:4], load_clr_s[4:2]};
endmodule

`default_nettype wire
