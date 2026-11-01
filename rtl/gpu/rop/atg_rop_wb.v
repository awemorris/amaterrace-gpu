/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wb: ROP write-back: a small write-combining buffer of
 * render-target lines; reads the destination line when its old pixels are
 * needed, sends the pixels through a blend path, writes lines back; drains
 * when idle.
 *
 * High-frequency 5nm ASIC implementation:
 * - Zero CARRY4s in streaming hit detection, slot offsets, and counters.
 * - 1-LUT6 shift-and-compare per bit for streaming tag hit (t0_eq, t1_eq).
 * - 4-LUT-level streaming b_dst gather via 64-bit chunk pre-select (q64_0, q64_1).
 * - 3-stage pipelined byte-enable decode & pixel merge (pre_wr* -> commit_* -> edat).
 * - All fanouts <= 16 via replicated flip-flops and LUT1 buffer trees.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

`ifndef CFG_ROP_MRT_COUNT
`define CFG_ROP_MRT_COUNT 1
`endif

(* keep_hierarchy = "yes" *)
module atg_rop_wb #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter MRT_COUNT = `CFG_ROP_MRT_COUNT
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rop_ds */
	input wire d_valid,
	output wire d_ready,
	input wire [31:0] d_xy,
	input wire [15:0] d_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] d_color,
	input wire [2:0] d_rt,	/* the beat's attachment (Phase 003: MRT 8) */
	input wire d_nocol,	/* a beat without colour */
	/* atg_rop_blend */
	output wire b_valid,
	output wire [511:0] b_src,
	output wire [127:0] b_dst,
	output wire [3:0] b_mask,
	output wire [2:0] b_rt,
	input wire b_rvalid,
	input wire [127:0] b_pix,
	output wire busy,
	/* AMB client port (design §4.1) */
	(* equivalent_register_removal = "no", max_fanout = 16 *) output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output reg [LINE_BYTES-1:0] req_be,
	output reg [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	/* The two cache line entries */
	reg ev [0:1];
	reg erd [0:1];
	reg [LA_W-1:0] etag [0:1];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [LINE_BYTES*8-1:0] edat [0:1];
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [LINE_BYTES-1:0] edirty [0:1];
	wire [LINE_BYTES*8-1:0] edat0 = edat[0], edat1 = edat[1];
	wire [LINE_BYTES-1:0] edirty0 = edirty[0], edirty1 = edirty[1];

	localparam [4:0]
		S_IDLE        = 5'd0,
		S_ROW_WAIT1   = 5'd1,
		S_ROW_WAIT2   = 5'd2,
		S_ROW_WAIT3   = 5'd3,
		S_ROW_WAIT4   = 5'd4,
		S_ROW_WAIT5   = 5'd5,
		S_ROW_PREP    = 5'd6,
		S_ROW         = 5'd7,
		S_LOOK        = 5'd8,
		S_EVW         = 5'd9,
		S_FILL        = 5'd10,
		S_BLEND_PREP1 = 5'd11,
		S_BLEND_PREP2 = 5'd12,
		S_BLEND       = 5'd13,
		S_BWAIT       = 5'd14,
		S_BCOMMIT     = 5'd15,
		S_FLUSH       = 5'd16,
		S_FLW         = 5'd17,
		S_LOOK_PREP   = 5'd18,
		S_FLUSH_PREP  = 5'd19;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [4:0] st;
	(* max_fanout = 16 *) reg r;	/* row / entry */
	(* max_fanout = 16 *) reg [1:0] j;	/* line of the row (several lines) */
	(* max_fanout = 16 *) reg [1:0] g;	/* pass (one line per row: the sample) */
	reg wait_rsp;
	reg [4:0] idle;

	/* Pure-LUT +1 increments for j, g, idle (0 CARRY4s) */
	wire [1:0] j1 = {j[1] ^ j[0], ~j[0]};
	wire [1:0] g1 = {g[1] ^ g[0], ~g[0]};
	wire idle_c1 = idle[1] & idle[0];
	wire idle_c2 = idle[2] & idle_c1;
	wire idle_c3 = idle[3] & idle_c2;
	wire [4:0] idle1 = {
		idle[4] ^ idle_c3,
		idle[3] ^ idle_c2,
		idle[2] ^ idle_c1,
		idle[1] ^ idle[0],
		~idle[0]
	};

	reg [31:0] xy;
	reg [15:0] mask;
	reg [511:0] color;
	reg [2:0] rt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] addr;
	reg [LINE_SHIFT-1:0] off [0:1];
	reg [LINE_SHIFT-1:0] off_p1 [0:1];
	reg f_go;
	reg fsm_b_valid;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg bwait_d1;
	reg r_look_hit;
	reg r_edirty_nz;

	/* Pure-LUT LINE_SHIFT-bit adder for off_p1_comb = addr[LINE_SHIFT-1:0] + ext_ps (0 CARRY4s) */
	function [LINE_SHIFT-1:0] add_ls_lut;
		input [LINE_SHIFT-1:0] a;
		input [LINE_SHIFT-1:0] b_in;
		reg [LINE_SHIFT:0] c;
		integer bi;
		begin
			c[0] = 1'b0;
			for (bi = 0; bi < LINE_SHIFT; bi = bi + 1) begin
				add_ls_lut[bi] = a[bi] ^ b_in[bi] ^ c[bi];
				c[bi + 1] = (a[bi] & b_in[bi]) | ((a[bi] ^ b_in[bi]) & c[bi]);
			end
		end
	endfunction

	/* Interface wires to/from atg_rop_wpix */
	wire [31:0] p_addr, p_addr1;
	wire [31:0] p_row_base0, p_row_base1, p_stride, p_xoff_j;
	wire [1:0] p_nl, p_np, p_path;
	wire p_multi, p_drop, p_read, p_lw, f_done;
	wire [3:0] p_mask, p_ent;
	wire [511:0] p_res;
	wire [4*LINE_SHIFT-1:0] p_soff;
	wire [4:0] p_ps;
	wire [31:0] p_xoff;
	wire [2:0] p_xsh;
	wire f_take = (st == S_BWAIT) && (p_path == 2'd1) && f_done;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] wb_row_base0, wb_row_base1, cur_row_base_r;
	wire [31:0] wb_row_base1_comb;
	wire wb_rb1_co;
	/* Both inputs are registered FFs -> 1 Pre-CARRY4 LUT, 0 Post-CARRY4 LUTs */
	am_add #(.W(32)) u_wb_rb1 (.a(wb_row_base0), .b(p_stride), .ci(1'b0), .s(wb_row_base1_comb), .co(wb_rb1_co));
	wire [31:0] wb_addr_comb;
	wire wb_addr_co;
	/* Both inputs are registered FFs -> 1 Pre-CARRY4 LUT, 0 Post-CARRY4 LUTs */
	am_add #(.W(32)) u_wb_addr (.a(cur_row_base_r), .b(p_xoff_j), .ci(1'b0), .s(wb_addr_comb), .co(wb_addr_co));

	wire [31:0] p_ps_32 = {27'd0, p_ps};
	wire [LINE_SHIFT-1:0] ext_ps = p_ps_32[LINE_SHIFT-1:0];
	(* keep = "true" *) wire [LINE_SHIFT-1:0] off_p1_comb = add_ls_lut(addr[LINE_SHIFT-1:0], ext_ps);

	(* keep = "true", dont_touch = "true" *) reg is_idle_reg;
	(* keep = "true", dont_touch = "true" *) reg [7:0] is_idle_bdst;

	/* Line Tracking and Cached Row Base */
	reg line_match_valid;
	reg stream_cfg_ok;
	reg [2:0] line_rt;
	reg [15:0] line_y;
	reg [LA_W-1:0] cached_tag_x0;
	reg [LA_W-1:0] cached_tag_x1;
	reg [31:0] cached_row_base0;
	reg [31:0] cached_row_base1;
	reg [2:0] cached_xsh;
	(* keep = "true", dont_touch = "true" *) reg [1:0] cached_xsh_rep [0:15];
	reg cached_drop;
	reg cached_multi;
	reg [1:0] cached_np;
	reg [1:0] cached_path;
	reg cached_read;
	reg [4:0] cached_ps;

	wire [LA_W-1:0] tag_x0_comb, tag_x1_comb;
	wire tag_x0_co, tag_x1_co;
	/* Both inputs are registered FFs, and outputs go directly to unconditional FFs tag_x0_r/tag_x1_r
	 * -> 1 Pre-CARRY4 LUT, 0 Post-CARRY4 LUTs! */
	am_sub #(.W(LA_W)) u_tag_x0 (.a(etag[0]), .b(wb_row_base0[ADDR_W-1:LINE_SHIFT]), .bi(1'b0), .d(tag_x0_comb), .bo(tag_x0_co));
	am_sub #(.W(LA_W)) u_tag_x1 (.a(etag[1]), .b(wb_row_base1[ADDR_W-1:LINE_SHIFT]), .bi(1'b0), .d(tag_x1_comb), .bo(tag_x1_co));
	reg [LA_W-1:0] tag_x0_r, tag_x1_r;
	reg rb0_aligned_r, rb1_aligned_r;
	always @(posedge clk) begin
`ifndef SYNTH_KINTEX7
		if (!is_idle_reg) begin
`endif
			tag_x0_r <= tag_x0_comb;
			tag_x1_r <= tag_x1_comb;
			rb0_aligned_r <= (wb_row_base0[LINE_SHIFT-1:0] == {LINE_SHIFT{1'b0}});
			rb1_aligned_r <= (wb_row_base1[LINE_SHIFT-1:0] == {LINE_SHIFT{1'b0}});
`ifndef SYNTH_KINTEX7
		end
`endif
	end

	/* Fast line-offset calculation for streaming (1 LUT level, 0 CARRY4s) */
	wire [LINE_SHIFT-1:1] d_xy_loff;
`ifdef SYNTH_KINTEX7
	genvar g_xl;
	generate
	for (g_xl = 1; g_xl < LINE_SHIFT; g_xl = g_xl + 1) begin : g_dxy_loff
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_xl (.I0(d_xy[g_xl]), .O(d_xy_loff[g_xl]));
	end
	endgenerate
`else
	assign d_xy_loff = d_xy[LINE_SHIFT-1:1];
`endif
	wire [LINE_SHIFT-1:0] d_xy_lo_b = {d_xy_loff, d_xy[0]};
	wire [1:0] xsh_loff = cached_xsh_rep[0];
	(* keep = "true" *) wire [LINE_SHIFT-1:0] str_line_off =
		(xsh_loff == 2'd2) ? {d_xy_lo_b[LINE_SHIFT-3:0], 2'b00} :
		(xsh_loff == 2'd1) ? {d_xy_lo_b[LINE_SHIFT-2:0], 1'b0} :
		d_xy_lo_b[LINE_SHIFT-1:0];

	wire [LINE_SHIFT-1:0] str_x_p1 = {d_xy_loff[LINE_SHIFT-1:1], 1'b1};
	(* keep = "true" *) wire [LINE_SHIFT-1:0] str_line_off_p1 =
		(xsh_loff == 2'd2) ? {str_x_p1[LINE_SHIFT-3:0], 2'b00} :
		(xsh_loff == 2'd1) ? {str_x_p1[LINE_SHIFT-2:0], 1'b0} :
		str_x_p1;

	wire [511:0] p_bsrc;
	wire [127:0] p_bdst;
	reg [511:0] r_bsrc;
	reg [127:0] r_bdst;
	reg [3:0] r_bmask;
	reg [4*LINE_SHIFT-1:0] r_bsoff;
	reg [3:0] r_bent;
	reg [4:0] r_bps;

`ifdef SYNTH_KINTEX7
	wire [1:0] idle_grp;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ig0 (.I0(is_idle_reg), .O(idle_grp[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ig1 (.I0(is_idle_reg), .O(idle_grp[1]));

	wire [31:0] idle_bsrc;
	genvar g_ib;
	generate
	for (g_ib = 0; g_ib < 32; g_ib = g_ib + 1) begin : g_ib_buf
		localparam G_IDX = g_ib / 16;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ib (.I0(idle_grp[G_IDX]), .O(idle_bsrc[g_ib]));
	end
	endgenerate

	genvar g_bs;
	generate
	for (g_bs = 0; g_bs < 32; g_bs = g_bs + 1) begin : g_bs_mux
		assign b_src[16 * g_bs +: 16] = idle_bsrc[g_bs] ? d_color[16 * g_bs +: 16] : r_bsrc[16 * g_bs +: 16];
	end
	endgenerate
`else
	assign b_src = is_idle_reg ? d_color : r_bsrc;
`endif

	/* 4-LUT-level streaming destination pixel gather (0 CARRY4s, fanout <= 16):
	 * Level 1: str_c_rep[0..7] selects which 64-bit chunk of edat0 / edat1 contains the quad's 2 pixels.
	 * Level 2: q64_0[63:0] and q64_1[63:0] mux edat0 and edat1 down to 64 bits.
	 * Level 3: s_p0 (psl==0 byte select) and s_p12 (psl==1,2 word/halfword select).
	 * Level 4: b_dst combines is_idle_bdst, cached_xsh_rep, s_p0, s_p12, and r_bdst.
	 */
	localparam integer CHUNK_IDX_W = LINE_SHIFT - 3;
	(* keep = "true" *) wire [CHUNK_IDX_W-1:0] str_c_rep [0:7];
	(* keep = "true" *) wire [63:0] q64_0, q64_1;
	genvar gc, gbit;
	generate
	for (gc = 0; gc < 8; gc = gc + 1) begin : g_str_c
		wire [1:0] xsh_c = cached_xsh_rep[gc];
		assign str_c_rep[gc] =
			xsh_c[1] ? d_xy[1 +: CHUNK_IDX_W] :
			xsh_c[0] ? d_xy[2 +: CHUNK_IDX_W] :
			           d_xy[3 +: CHUNK_IDX_W];
	end
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_q64
		for (gbit = 0; gbit < 16; gbit = gbit + 1) begin : g_qb
			assign q64_0[16 * gc + gbit] = edat0[{str_c_rep[gc],     gc[1:0], gbit[3:0]}];
			assign q64_1[16 * gc + gbit] = edat1[{str_c_rep[4 + gc], gc[1:0], gbit[3:0]}];
		end
	end
	for (gc = 0; gc < 4; gc = gc + 1) begin : g_bdst_slot
		wire [63:0] q64 = (gc >= 2) ? q64_1 : q64_0;
		wire [1:0] xsh_slo = cached_xsh_rep[8 + gc];
		wire [1:0] xsh_shi = cached_xsh_rep[12 + gc];
		wire idle_lo = is_idle_bdst[2 * gc + 0];
		wire idle_hi = is_idle_bdst[2 * gc + 1];
		/* Buffered d_xy[2:1] per slot (fanout <= 8 per LUT1, Level 1 -> feeds Level 3) */
		wire [1:0] x21_lo;
		wire x1_hi;
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_x21_l0 (.I0(d_xy[1]), .O(x21_lo[0]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_x21_l1 (.I0(d_xy[2]), .O(x21_lo[1]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_x1_hi  (.I0(d_xy[1]), .O(x1_hi));
`else
		assign x21_lo = d_xy[2:1];
		assign x1_hi  = d_xy[1];
`endif

		for (gbit = 0; gbit < 8; gbit = gbit + 1) begin : g_b0_7
			(* keep = "true" *) wire s_p0 = q64[{x21_lo, gc[0], gbit[2:0]}];
			(* keep = "true" *) wire s_p12 = gc[0] ?
				(xsh_slo[1] ? q64[32 + gbit] : (x21_lo[0] ? q64[48 + gbit] : q64[16 + gbit])) :
				(xsh_slo[1] ? q64[gbit]      : (x21_lo[0] ? q64[32 + gbit] : q64[gbit]));
			assign b_dst[32 * gc + gbit] = idle_lo ?
				((xsh_slo == 2'd0) ? s_p0 : s_p12) :
				r_bdst[32 * gc + gbit];
		end
		for (gbit = 8; gbit < 16; gbit = gbit + 1) begin : g_b8_15
			(* keep = "true" *) wire s_p12 = gc[0] ?
				(xsh_slo[1] ? q64[32 + gbit] : (xsh_slo[0] ? (x1_hi ? q64[48 + gbit] : q64[16 + gbit]) : 1'b0)) :
				(xsh_slo[1] ? q64[gbit]      : (xsh_slo[0] ? (x1_hi ? q64[32 + gbit] : q64[gbit])      : 1'b0));
			assign b_dst[32 * gc + gbit] = idle_lo ? s_p12 : r_bdst[32 * gc + gbit];
		end
		for (gbit = 16; gbit < 32; gbit = gbit + 1) begin : g_b16_31
			assign b_dst[32 * gc + gbit] = idle_hi ?
				(xsh_shi[1] ? q64[(gc[0] ? 32 : 0) + gbit] : 1'b0) :
				r_bdst[32 * gc + gbit];
		end
	end
	endgenerate

	/* wpix is driven exclusively by registered FSM state (0 combinational paths from d_* inputs) */
	atg_rop_wpix #(.LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) wpix (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.i_xy(xy), .i_rt(rt), .i_smask(mask), .i_color(color),
		.i_r(r), .i_j(j), .i_g(g),
		.i_line0(edat0), .i_line1(edat1),
		.i_off0(off[0]), .i_off1(off[1]),
		.i_off0_p1(off_p1[0]), .i_off1_p1(off_p1[1]),
		.i_reg_off0(off[0]), .i_reg_off1(off[1]),
		.i_reg_rt(rt), .i_reg_color(color), .i_reg_mask(mask),
		.b_pix(b_pix), .f_go(f_go), .f_done(f_done), .f_take(f_take), .i_idle(is_idle_reg),
		.o_addr(p_addr), .o_addr1(p_addr1), .o_nl(p_nl), .o_np(p_np), .o_multi(p_multi), .o_drop(p_drop),
		.o_read(p_read), .o_path(p_path), .o_lw(p_lw), .o_mask(p_mask), .o_bsrc(p_bsrc),
		.o_bdst(p_bdst), .o_res(p_res), .o_ent(p_ent), .o_soff(p_soff), .o_ps(p_ps),
		.o_row_base0(p_row_base0), .o_row_base1(p_row_base1),
		.o_xoff(p_xoff), .o_xsh(p_xsh),
		.o_stride(p_stride), .o_xoff_j(p_xoff_j)
	);

	/* Pure-LUT Cache Hit Detection and Streaming Qualification (0 CARRY4s, <= 3 LUT6 levels to d_ready_w / do_stream) */
	localparam integer TAG_CMP_BITS = 18 - LINE_SHIFT; /* 13 bits for LINE_SHIFT=5, 12 bits for LINE_SHIFT=6 */
	localparam integer T_HI = TAG_CMP_BITS - 1;
	wire [1:0] xsh_t0 = cached_xsh_rep[1];
	wire [1:0] xsh_t1 = cached_xsh_rep[2];
	(* keep = "true" *) wire [7:0] t01_eq;
	assign t01_eq[0] = ((!xsh_t0[1]) || ((d_xy[LINE_SHIFT - 2] == cached_tag_x0[0]) && (d_xy[LINE_SHIFT - 2] == cached_tag_x1[0]))) &&
	                   (d_xy[31] == line_y[15]);
	assign t01_eq[1] = ((xsh_t1 == 2'd0) || ((d_xy[LINE_SHIFT - 1] == cached_tag_x0[1]) && (d_xy[LINE_SHIFT - 1] == cached_tag_x1[1]))) &&
	                   is_idle_reg;
	genvar gt;
	generate
	for (gt = 0; gt < 5; gt = gt + 1) begin : g_tag_eq
		localparam integer X_LO = LINE_SHIFT + 2 * gt;
		localparam integer T_LO = 2 + 2 * gt;
		assign t01_eq[2 + gt] =
			(d_xy[X_LO +: 2] == cached_tag_x0[T_LO +: 2]) &&
			(d_xy[X_LO +: 2] == cached_tag_x1[T_LO +: 2]);
	end
	if (LINE_SHIFT == 5) begin : g_teq7_ls5
		assign t01_eq[7] = (d_xy[15] == cached_tag_x0[12]) && (d_xy[15] == cached_tag_x1[12]) &&
		                   !d_xy[0] && stream_cfg_ok && line_match_valid;
	end else begin : g_teq7_ls6
		assign t01_eq[7] = (cached_tag_x0[12] == cached_tag_x1[12]) &&
		                   !d_xy[0] && stream_cfg_ok && line_match_valid;
	end
	endgenerate

	(* keep = "true" *) wire [4:0] y_eq3;
	assign y_eq3[0] = (d_xy[18:16] == line_y[2:0]);
	assign y_eq3[1] = (d_xy[21:19] == line_y[5:3]);
	assign y_eq3[2] = (d_xy[24:22] == line_y[8:6]);
	assign y_eq3[3] = (d_xy[27:25] == line_y[11:9]);
	assign y_eq3[4] = (d_xy[30:28] == line_y[14:12]);

	(* keep = "true" *) wire hit_rt = (d_rt == line_rt);
	(* keep = "true" *) wire dval_col = d_valid && !d_nocol;

	(* keep = "true" *) wire sm_z0 = (d_smask[5:0]   == 6'd0);
	(* keep = "true" *) wire sm_z1 = (d_smask[11:6]  == 6'd0);
	(* keep = "true" *) wire sm_z2 = (d_smask[15:12] == 4'd0);

	/* Pipeline shift register (11 stages for atg_rop_blend LAT=11 + 1 commit stage) */
	reg [10:0] pipe_v;
	reg pipe_nz_1_r;
	reg [3:0] pipe_id [0:10];
	reg [4*LINE_SHIFT-1:0] pipe_soff [0:9];
	reg [3:0] pipe_mask [0:9];
	reg [3:0] pipe_ent [0:9];
	reg [4:0] pipe_ps [0:9];
	localparam integer N_CREP = LINE_BYTES + 4;
	reg commit_v;
	(* keep = "true", dont_touch = "true" *) reg [N_CREP-1:0] commit_v_rep;
	reg commit_is_stream;
	reg [3:0] commit_id;

	(* keep = "true" *) wire pipe_nz_0 = (pipe_v[5:0] != 6'd0);
	(* keep = "true" *) wire pipe_nz_1 = pipe_nz_1_r;
	wire pipe_busy = pipe_nz_0 || pipe_nz_1;

	(* keep = "true" *) wire p_idle_0 = d_nocol || (pipe_v[4:0] == 5'd0);
	(* keep = "true" *) wire p_idle_1 = d_nocol || (!pipe_v[5] && !pipe_nz_1_r);

	/* Level 2: single 6-input LUT6 for idle_or_drop */
	(* keep = "true" *) wire idle_or_drop =
		is_idle_reg && ((p_idle_0 && p_idle_1) || (sm_z0 && sm_z1 && sm_z2));

	/* Hazard Tracker and Pixel Lock CAM */
	wire alloc_ready;
	wire [3:0] alloc_id;
	wire [2:0] haz_grp_hit;
	reg release_valid;
	reg [3:0] release_id;

	/* Level 2: 6-input LUT6 groups for stream_hit and stream_cand */
	(* keep = "true" *) wire [2:0] sh_grp;
	assign sh_grp[0] = &t01_eq[5:0];
	assign sh_grp[1] = &{t01_eq[7:6], y_eq3[3:0]};
	assign sh_grp[2] = y_eq3[4] && hit_rt && !haz_grp_hit[2];
	(* keep = "true" *) wire sh_grp2_cand = y_eq3[4] && hit_rt && dval_col && !(sm_z0 && sm_z1 && sm_z2);

	/* Level 3: single LUTs for stream_hit_free, stream_cand_haz, do_stream, d_ready_w, b_valid_w */
	(* keep = "true" *) wire stream_hit_free = sh_grp[0] && sh_grp[1] && sh_grp[2] && !haz_grp_hit[0] && !haz_grp_hit[1];
	(* keep = "true" *) wire stream_cand_haz = sh_grp[0] && sh_grp[1] && sh_grp2_cand;
	(* keep = "true" *) wire do_stream = sh_grp[0] && sh_grp[1] && sh_grp2_cand && !haz_grp_hit[0] && !haz_grp_hit[1] && !haz_grp_hit[2];
	wire stream_ok = stream_hit_free;
	wire stream_hit_w = stream_hit_free;

	atg_rop_hazard #(
		.NUM_ENTRIES(16),
		.TAG_W(33)
	) u_hazard (
		.clk(clk),
		.rst_n(rst_n),
		.alloc_valid(stream_cand_haz),
		.alloc_ready(alloc_ready),
		.alloc_tag({d_rt, d_xy[31:17], d_xy[15:1]}),
		.alloc_id(alloc_id),
		.o_grp_hit(haz_grp_hit),
		.release_valid(release_valid),
		.release_id(release_id)
	);

	wire [3:0] s0_mask = {d_smask[12], d_smask[8], d_smask[4], d_smask[0]};
`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire b_valid_w =
		(sh_grp[0] && sh_grp[1] && sh_grp2_cand && !haz_grp_hit[0] && !haz_grp_hit[1]) || fsm_b_valid;
`else
	(* keep = "true" *) wire b_valid_w = is_idle_reg ? do_stream : fsm_b_valid;
`endif
	assign b_valid = b_valid_w;
	assign b_mask = is_idle_reg ? s0_mask : r_bmask;

	wire [2:0] eff_rt = is_idle_reg ? d_rt : rt;
`ifdef SYNTH_KINTEX7
	wire [2:0] eff_rt_blend;
	genvar g_rtb;
	generate
	for (g_rtb = 0; g_rtb < 3; g_rtb = g_rtb + 1) begin : g_rt_blend
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rt_b (.I0(eff_rt[g_rtb]), .O(eff_rt_blend[g_rtb]));
	end
	endgenerate
	assign b_rt = eff_rt_blend;
`else
	assign b_rt = eff_rt;
`endif

	wire p_ready = (p_path == 2'd2 && bwait_d1) || (p_path == 2'd0 && b_rvalid) || f_done;

	/* Pure-LUT 27-bit tag equality and dirty check for FSM (0 CARRY4s, <= 3 LUT levels) */
	(* keep = "true" *) wire [8:0] hit_eq3;
	genvar gh;
	generate
	for (gh = 0; gh < 9; gh = gh + 1) begin : g_hit_eq3
		localparam integer H_LO = 3 * gh;
		localparam integer H_W  = (H_LO + 3 <= LA_W) ? 3 : (LA_W - H_LO);
		wire [H_W-1:0] et_s = etag[r][H_LO +: H_W];
		wire [H_W-1:0] ad_s = addr[LINE_SHIFT + H_LO +: H_W];
		assign hit_eq3[gh] = (et_s == ad_s);
	end
	endgenerate
	(* keep = "true" *) wire hit_g0 = &hit_eq3[4:0];
	(* keep = "true" *) wire hit_g1 = &hit_eq3[8:5];
	wire hit = ev[r] && hit_g0 && hit_g1 && (erd[r] || !p_read);

	localparam integer N_DGRP = (LINE_BYTES + 5) / 6;
	wire [LINE_BYTES-1:0] cur_edirty = edirty[r];
	(* keep = "true" *) wire [N_DGRP-1:0] dirty_or6;
	generate
	for (gh = 0; gh < N_DGRP; gh = gh + 1) begin : g_dirty_or
		localparam integer D_LO = 6 * gh;
		localparam integer D_W = (D_LO + 6 <= LINE_BYTES) ? 6 : (LINE_BYTES - D_LO);
		assign dirty_or6[gh] = |cur_edirty[D_LO +: D_W];
	end
	endgenerate
	wire edirty_nz = |dirty_or6;

	localparam integer N_PRED = LINE_BYTES / 2;
`ifdef SYNTH_KINTEX7
	wire [1:0] p_read_mid;
	wire [2*N_PRED-1:0] p_read_edat;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_prdm0 (.I0(p_read), .O(p_read_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_prdm1 (.I0(p_read), .O(p_read_mid[1]));
	genvar g_pred;
	generate
	for (g_pred = 0; g_pred < 2 * N_PRED; g_pred = g_pred + 1) begin : g_pred_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_prd (
			.I0(p_read_mid[g_pred / N_PRED]), .O(p_read_edat[g_pred])
		);
	end
	endgenerate
`endif

	/* Level 3: single 6-input LUT6 for d_ready */
	(* keep = "true" *) wire d_ready_w =
		idle_or_drop || (sh_grp[0] && sh_grp[1] && sh_grp[2] && !haz_grp_hit[0] && !haz_grp_hit[1]);
	assign d_ready = d_ready_w;
	assign busy = (st != S_IDLE) || ev[0] || ev[1] || pipe_busy;
	assign req_tag = 8'd0;

	/* ---------------------------------------------------------------------
	 * 3-Stage Commit Pipeline (Stage A: pre_wr* -> Stage B: commit_* -> Stage C: edat)
	 * Shared between streaming (pipe_v[9] -> pipe_v[10] -> commit_v)
	 * and FSM (S_BWAIT !bwait_d1 -> S_BWAIT p_ready -> S_BCOMMIT).
	 * --------------------------------------------------------------------- */
	wire [4:0] pre_in_ps = pipe_v[9] ? pipe_ps[9] : r_bps;
	wire pre_is_u8 = pipe_v[9] || (p_path == 2'd0);
	wire [1:0] pre_u8_sel_in = !pre_is_u8 ? 2'd0 : (pre_in_ps[0] ? 2'd1 : (pre_in_ps[1] ? 2'd2 : 2'd3));
	wire [1:0] pre_u8_sel_in_b [0:3];
`ifdef SYNTH_KINTEX7
	genvar g_u8b;
	generate
	for (g_u8b = 0; g_u8b < 4; g_u8b = g_u8b + 1) begin : g_u8_sel_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_u8s0 (.I0(pre_u8_sel_in[0]), .O(pre_u8_sel_in_b[g_u8b][0]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_u8s1 (.I0(pre_u8_sel_in[1]), .O(pre_u8_sel_in_b[g_u8b][1]));
	end
	endgenerate
`else
	assign pre_u8_sel_in_b[0] = pre_u8_sel_in;
	assign pre_u8_sel_in_b[1] = pre_u8_sel_in;
	assign pre_u8_sel_in_b[2] = pre_u8_sel_in;
	assign pre_u8_sel_in_b[3] = pre_u8_sel_in;
`endif

	/* Replicate pre_in_* into 8 groups of 4 bytes via explicit LUTs so fanouts <= 16 */
	localparam integer N_BGRP = (LINE_BYTES + 3) / 4;
	(* keep = "true", dont_touch = "true" *) wire [3:0] pre_mask_g [0:N_BGRP-1];
	(* keep = "true", dont_touch = "true" *) wire [4*LINE_SHIFT-1:0] pre_soff_g [0:N_BGRP-1];
	(* keep = "true", dont_touch = "true" *) wire [3:0] pre_ent_g [0:N_BGRP-1];
	(* keep = "true", dont_touch = "true" *) wire [LINE_SHIFT-1:0] pre_lmw_g [0:N_BGRP-1];

`ifdef SYNTH_KINTEX7
	wire [1:0] pv9_mid;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pv9m0 (.I0(pipe_v[9]), .O(pv9_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pv9m1 (.I0(pipe_v[9]), .O(pv9_mid[1]));
`endif

	genvar gbg, gb, gbi;
	generate
	for (gbg = 0; gbg < N_BGRP; gbg = gbg + 1) begin : g_pre_grp
		(* keep = "true", dont_touch = "true" *) wire [4:0] ps_g;
`ifdef SYNTH_KINTEX7
		wire pv9_a, pv9_b;
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pva (.I0(pv9_mid[gbg / 4]), .O(pv9_a));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pvb (.I0(pv9_mid[gbg / 4]), .O(pv9_b));
		for (gbi = 0; gbi < 4; gbi = gbi + 1) begin : g_pm_lut
			(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'hCA)) u_mk (
				.I0(r_bmask[gbi]), .I1(pipe_mask[9][gbi]), .I2(pv9_a), .O(pre_mask_g[gbg][gbi])
			);
			(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'hCA)) u_en (
				.I0(r_bent[gbi]), .I1(pipe_ent[9][gbi]), .I2(pv9_a), .O(pre_ent_g[gbg][gbi])
			);
		end
		for (gbi = 0; gbi < 4 * LINE_SHIFT; gbi = gbi + 1) begin : g_so_lut
			(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'hCA)) u_so (
				.I0(r_bsoff[gbi]), .I1(pipe_soff[9][gbi]), .I2((gbi < 8) ? pv9_a : pv9_b), .O(pre_soff_g[gbg][gbi])
			);
		end
		for (gbi = 0; gbi < 5; gbi = gbi + 1) begin : g_ps_lut
			(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'hCA)) u_ps (
				.I0(r_bps[gbi]), .I1(pipe_ps[9][gbi]), .I2(pv9_b), .O(ps_g[gbi])
			);
		end
		wire [3:0] lm_raw = {
			ps_g[4],
			ps_g[4] | ps_g[3],
			ps_g[4] | ps_g[3] | ps_g[2],
			ps_g[4] | ps_g[3] | ps_g[2] | ps_g[1]
		};
		wire [3:0] lm_g;
		for (gbi = 0; gbi < 4; gbi = gbi + 1) begin : g_lm_lut
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lm (.I0(lm_raw[gbi]), .O(lm_g[gbi]));
		end
`else
		assign pre_mask_g[gbg] = pipe_v[9] ? pipe_mask[9] : r_bmask;
		assign pre_soff_g[gbg] = pipe_v[9] ? pipe_soff[9] : r_bsoff;
		assign pre_ent_g[gbg]  = pipe_v[9] ? pipe_ent[9]  : r_bent;
		assign ps_g = pipe_v[9] ? pipe_ps[9] : r_bps;
		wire [3:0] lm_g = {
			ps_g[4],
			ps_g[4] | ps_g[3],
			ps_g[4] | ps_g[3] | ps_g[2],
			ps_g[4] | ps_g[3] | ps_g[2] | ps_g[1]
		};
`endif
		assign pre_lmw_g[gbg] = {{(LINE_SHIFT-4){1'b0}}, lm_g};
		wire unused_ps0 = ps_g[0];
	end
	endgenerate

	wire [LINE_BYTES-1:0] pre_wr0_en_w, pre_wr1_en_w;
	wire [2*LINE_BYTES-1:0] pre_wr0_sel_w, pre_wr1_sel_w;
	generate
	for (gb = 0; gb < LINE_BYTES; gb = gb + 1) begin : g_pre_dec
		localparam integer G_B = gb / 4;
		wire [LINE_SHIFT-1:0] b_off = gb[LINE_SHIFT-1:0];
		wire [3:0] mk_g = pre_mask_g[G_B];
		wire [4*LINE_SHIFT-1:0] so_g = pre_soff_g[G_B];
		wire [3:0] en_g = pre_ent_g[G_B];
		wire [LINE_SHIFT-1:0] lmw_g = pre_lmw_g[G_B];

		(* keep = "true" *) wire m0 = mk_g[0] && (((b_off ^ so_g[0 +: LINE_SHIFT])            & ~lmw_g) == {LINE_SHIFT{1'b0}});
		(* keep = "true" *) wire m1 = mk_g[1] && (((b_off ^ so_g[LINE_SHIFT +: LINE_SHIFT])   & ~lmw_g) == {LINE_SHIFT{1'b0}});
		(* keep = "true" *) wire m2 = mk_g[2] && (((b_off ^ so_g[2*LINE_SHIFT +: LINE_SHIFT]) & ~lmw_g) == {LINE_SHIFT{1'b0}});
		(* keep = "true" *) wire m3 = mk_g[3] && (((b_off ^ so_g[3*LINE_SHIFT +: LINE_SHIFT]) & ~lmw_g) == {LINE_SHIFT{1'b0}});

		wire w0_0 = m0 && !en_g[0];
		wire w0_1 = m1 && !en_g[1];
		wire w0_2 = m2 && !en_g[2];
		wire w0_3 = m3 && !en_g[3];

		wire w1_0 = m0 && en_g[0];
		wire w1_1 = m1 && en_g[1];
		wire w1_2 = m2 && en_g[2];
		wire w1_3 = m3 && en_g[3];

		assign pre_wr0_en_w[gb] = w0_0 | w0_1 | w0_2 | w0_3;
		assign pre_wr1_en_w[gb] = w1_0 | w1_1 | w1_2 | w1_3;

		assign pre_wr0_sel_w[2*gb +: 2] = w0_3 ? 2'd3 : (w0_2 ? 2'd2 : (w0_1 ? 2'd1 : 2'd0));
		assign pre_wr1_sel_w[2*gb +: 2] = w1_3 ? 2'd3 : (w1_2 ? 2'd2 : (w1_1 ? 2'd1 : 2'd0));
	end
	endgenerate

	reg [LINE_BYTES-1:0] pre_wr0_en, pre_wr1_en;
	reg [2*LINE_BYTES-1:0] pre_wr0_sel, pre_wr1_sel;
	(* keep = "true", dont_touch = "true" *) reg [1:0] pre_u8_sel_rep [0:31];

	/* Stage B: 2-LUT-level slot byte mux and per-byte cache line mux (fanout <= 16) */
	wire use_stream_res = pipe_v[10] && b_rvalid;
	(* keep = "true" *) wire [127:0] m_raw [0:3];
`ifdef SYNTH_KINTEX7
	generate
	for (gb = 0; gb < 4; gb = gb + 1) begin : g_rep_gen
		genvar gq;
		for (gq = 0; gq < 16; gq = gq + 1) begin : g_m_slice
			wire [1:0] u8_sel = pre_u8_sel_rep[8 * gb + (gq / 2)];
			assign m_raw[gb][8 * gq +: 8] =
				(u8_sel == 2'd3) ? b_pix[32 * gb + 8 * (gq % 4) +: 8] :
				(u8_sel == 2'd2) ? b_pix[32 * gb + 8 * (gq % 2) +: 8] :
				(u8_sel == 2'd1) ? b_pix[32 * gb +: 8] :
				                   p_res[128 * gb + 8 * gq +: 8];
		end
	end
	endgenerate
`else
	generate
	for (gb = 0; gb < 4; gb = gb + 1) begin : g_rep_gen
		wire [1:0] u8_sel = pre_u8_sel_rep[0];
		assign m_raw[gb] =
			(u8_sel == 2'd3) ? {4{b_pix[32 * gb +: 32]}} :
			(u8_sel == 2'd2) ? {8{b_pix[32 * gb +: 16]}} :
			(u8_sel == 2'd1) ? {16{b_pix[32 * gb +: 8]}} :
			                   p_res[128 * gb +: 128];
	end
	endgenerate
`endif

	wire [LINE_BYTES*8-1:0] wdata0_pre_comb, wdata1_pre_comb;
	generate
	for (gb = 0; gb < LINE_BYTES; gb = gb + 1) begin : g_wdata_pre
		wire [1:0] s0 = pre_wr0_sel[2 * gb +: 2];
		wire [1:0] s1 = pre_wr1_sel[2 * gb +: 2];
		assign wdata0_pre_comb[8 * gb +: 8] = m_raw[s0][8 * (gb % 16) +: 8];
		assign wdata1_pre_comb[8 * gb +: 8] = m_raw[s1][8 * (gb % 16) +: 8];
	end
	endgenerate

	reg [LINE_BYTES-1:0] commit_wr0_en, commit_wr1_en;
	reg [LINE_BYTES*8-1:0] commit_wdata0, commit_wdata1;
	(* max_fanout = 16 *) reg [1:0] g_fsm;
	wire [1:0] p_multi_b;
	wire [1:0] p_xsh_b [0:3];
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pmb0 (.I0(p_multi), .O(p_multi_b[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_pmb1 (.I0(p_multi), .O(p_multi_b[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px00 (.I0(p_xsh[0]), .O(p_xsh_b[0][0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px01 (.I0(p_xsh[1]), .O(p_xsh_b[0][1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px10 (.I0(p_xsh[0]), .O(p_xsh_b[1][0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px11 (.I0(p_xsh[1]), .O(p_xsh_b[1][1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px20 (.I0(p_xsh[0]), .O(p_xsh_b[2][0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px21 (.I0(p_xsh[1]), .O(p_xsh_b[2][1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px30 (.I0(p_xsh[0]), .O(p_xsh_b[3][0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_px31 (.I0(p_xsh[1]), .O(p_xsh_b[3][1]));
`else
	assign p_multi_b = {2{p_multi}};
	assign p_xsh_b[0] = p_xsh[1:0];
	assign p_xsh_b[1] = p_xsh[1:0];
	assign p_xsh_b[2] = p_xsh[1:0];
	assign p_xsh_b[3] = p_xsh[1:0];
`endif

	task next_row;
		begin
			if (p_multi_b[0] && j != p_nl) begin
				j <= j1;
			end else if (!r) begin
				r <= 1'b1;
				j <= 2'd0;
			end else if (p_multi_b[0]) begin
				r <= 1'b0;
				j <= 2'd0;
				g <= 2'd0;
				g_fsm <= 2'd0;
			end else begin
				g <= 2'd0;
				g_fsm <= 2'd0;
			end
		end
	endtask

	task line_in;
		begin
			if (p_multi_b[0]) begin
				g <= 2'd0;
				g_fsm <= 2'd0;
			end else begin
				r <= 1'b1;
				g <= 2'd0;
				g_fsm <= 2'd0;
			end
		end
	endtask

	task pass_done;
		begin
			if (!p_multi_b[1] && g_fsm != p_np) begin
				g <= g1;
				g_fsm <= g1;
			end else if (!p_multi_b[1]) begin
				r <= 1'b0;
				j <= 2'd0;
				g <= 2'd0;
				g_fsm <= 2'd0;
			end else begin
				next_row;
			end
		end
	endtask

	integer l, b_idx, ps_i;
	wire latch_pre_en = pipe_v[9] || (st == S_BWAIT && !bwait_d1);
	wire latch_commit_en = (pipe_v[10] && b_rvalid) || (st == S_BWAIT && p_ready);

	/* Buffered enables for high-fanout data registers */
	wire fill_done_w = (st == S_FILL) && (!p_read || (!req_valid && wait_rsp && rsp_valid));
	wire fill_we0_w = fill_done_w && !r;
	wire fill_we1_w = fill_done_w && r;
	wire req_wr_go_w = ((st == S_LOOK) && !r_look_hit && r_edirty_nz) || ((st == S_FLUSH) && r_edirty_nz);
	wire req_rd_go_w = ((st == S_LOOK) && !r_look_hit && !r_edirty_nz && p_read) ||
	                   ((st == S_EVW) && !req_valid && !wait_rsp && p_read);
	wire req_go_w = req_wr_go_w || req_rd_go_w;
	wire en_s_blend_go = (st == S_BLEND) && (p_mask != 4'd0);
	/* Rule 1 fix: color/xy/mask are only read when st != S_IDLE, so latch whenever is_idle_reg && d_valid (1 LUT) */
	wire en_s_idle_miss = is_idle_reg && d_valid;
	wire en_s_row_w = (st == S_ROW);
	wire en_cur_rb_w = (st == S_ROW_WAIT5) || (st == S_ROW_PREP);
	wire en_bprep2_w = (st == S_BLEND_PREP2) && !p_multi_b[1] && (g_fsm == 2'd0);
	wire ed_clr_evw_flw = ((st == S_EVW) || (st == S_FLW)) && !req_valid && !wait_rsp;
	wire ed0_clr_w = rst_sync || fill_we0_w || (ed_clr_evw_flw && !r);
	wire ed1_clr_w = rst_sync || fill_we1_w || (ed_clr_evw_flw && r);

	localparam integer N_BE16  = LINE_BYTES / 16;
	localparam integer N_SEL16 = LINE_BYTES / 8;
	localparam integer N_LCE   = 2 * N_PRED + 2 * N_BE16 + 1;
	localparam integer N_LPE   = 2 * N_BE16 + 2 * N_SEL16 + 4;
	localparam integer N_RGO   = N_PRED + N_BE16 + 2;
	localparam integer N_RWR   = N_BE16 + 2;

	wire [1:0] en_s_row_buf, en_crb_buf, etag0_we_buf, etag1_we_buf;
	wire [1:0] crb_w5_buf, crb_r_buf;
	wire [5:0] en_bp2_leaf;
	wire [N_BE16-1:0] ed0_clr_buf, ed1_clr_buf;

`ifdef SYNTH_KINTEX7
	wire [1:0] fill_we0_mid, fill_we1_mid;
	wire [N_PRED-1:0] fill_we0_leaf, fill_we1_leaf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw0m0 (.I0(fill_we0_w), .O(fill_we0_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw0m1 (.I0(fill_we0_w), .O(fill_we0_mid[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw1m0 (.I0(fill_we1_w), .O(fill_we1_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw1m1 (.I0(fill_we1_w), .O(fill_we1_mid[1]));

	wire [2:0] lce_mid;
	wire [N_LCE-1:0] lce_leaf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lcem0 (.I0(latch_commit_en), .O(lce_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lcem1 (.I0(latch_commit_en), .O(lce_mid[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lcem2 (.I0(latch_commit_en), .O(lce_mid[2]));

	wire [1:0] lpe_mid;
	wire [N_LPE-1:0] lpe_leaf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lpem0 (.I0(latch_pre_en), .O(lpe_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lpem1 (.I0(latch_pre_en), .O(lpe_mid[1]));

	wire [1:0] req_go_mid, r_wdata_mid;
	wire [N_RGO-1:0] req_go_leaf;
	wire [N_PRED-1:0] r_wdata_leaf;
	wire [N_RWR-1:0] req_wr_leaf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rgm0 (.I0(req_go_w), .O(req_go_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rgm1 (.I0(req_go_w), .O(req_go_mid[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rwm0 (.I0(r), .O(r_wdata_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rwm1 (.I0(r), .O(r_wdata_mid[1]));

	wire [2:0] ebl_mid, eid_mid;
	wire [41:0] ebl_leaf;
	wire [35:0] eid_leaf;
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eblm0 (.I0(en_s_blend_go), .O(ebl_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eblm1 (.I0(en_s_blend_go), .O(ebl_mid[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eblm2 (.I0(en_s_blend_go), .O(ebl_mid[2]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eidm0 (.I0(en_s_idle_miss), .O(eid_mid[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eidm1 (.I0(en_s_idle_miss), .O(eid_mid[1]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eidm2 (.I0(en_s_idle_miss), .O(eid_mid[2]));

	wire is_w5_raw = (st == S_ROW_WAIT5);
	generate
	for (gb = 0; gb < 2; gb = gb + 1) begin : g_row_ce_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_srow  (.I0(en_s_row_w),  .O(en_s_row_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_crb   (.I0(en_cur_rb_w), .O(en_crb_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_crbw5 (.I0(is_w5_raw),   .O(crb_w5_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_crbr  (.I0(r),           .O(crb_r_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_et0   (.I0(fill_we0_w),  .O(etag0_we_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_et1   (.I0(fill_we1_w),  .O(etag1_we_buf[gb]));
	end
	for (gb = 0; gb < 6; gb = gb + 1) begin : g_bp2_ce_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bp2 (.I0(en_bprep2_w), .O(en_bp2_leaf[gb]));
	end
	for (gb = 0; gb < N_BE16; gb = gb + 1) begin : g_edclr_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_edc0 (.I0(ed0_clr_w), .O(ed0_clr_buf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_edc1 (.I0(ed1_clr_w), .O(ed1_clr_buf[gb]));
	end
	for (gb = 0; gb < N_PRED; gb = gb + 1) begin : g_fill_we_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw0l (.I0(fill_we0_mid[gb / (N_PRED / 2)]), .O(fill_we0_leaf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_fw1l (.I0(fill_we1_mid[gb / (N_PRED / 2)]), .O(fill_we1_leaf[gb]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rwl  (.I0(r_wdata_mid[gb / (N_PRED / 2)]),  .O(r_wdata_leaf[gb]));
	end
	for (gb = 0; gb < N_LCE; gb = gb + 1) begin : g_lce_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lcel (.I0(lce_mid[(gb * 3) / N_LCE]), .O(lce_leaf[gb]));
	end
	for (gb = 0; gb < N_LPE; gb = gb + 1) begin : g_lpe_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lpel (.I0(lpe_mid[gb / (N_LPE / 2)]), .O(lpe_leaf[gb]));
	end
	for (gb = 0; gb < N_RGO; gb = gb + 1) begin : g_req_go_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rgl (.I0(req_go_mid[gb / (N_RGO / 2)]), .O(req_go_leaf[gb]));
	end
	for (gb = 0; gb < N_RWR; gb = gb + 1) begin : g_req_wr_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rwrl (.I0(req_wr_go_w), .O(req_wr_leaf[gb]));
	end
	for (gb = 0; gb < 42; gb = gb + 1) begin : g_ebl_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ebll (.I0(ebl_mid[gb / 14]), .O(ebl_leaf[gb]));
	end
	for (gb = 0; gb < 36; gb = gb + 1) begin : g_eid_leaf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_eidl (.I0(eid_mid[gb / 12]), .O(eid_leaf[gb]));
	end
	endgenerate
`else
	assign en_s_row_buf = {2{en_s_row_w}};
	assign en_crb_buf = {2{en_cur_rb_w}};
	assign crb_w5_buf = {2{st == S_ROW_WAIT5}};
	assign crb_r_buf  = {2{r}};
	assign etag0_we_buf = {2{fill_we0_w}};
	assign etag1_we_buf = {2{fill_we1_w}};
	assign en_bp2_leaf = {6{en_bprep2_w}};
	assign ed0_clr_buf = {N_BE16{ed0_clr_w}};
	assign ed1_clr_buf = {N_BE16{ed1_clr_w}};
	wire [N_PRED-1:0] fill_we0_leaf = {N_PRED{fill_we0_w}};
	wire [N_PRED-1:0] fill_we1_leaf = {N_PRED{fill_we1_w}};
	wire [N_PRED-1:0] r_wdata_leaf  = {N_PRED{r}};
	wire [2:0] lce_mid = {3{latch_commit_en}};
	wire [N_LCE-1:0] lce_leaf = {N_LCE{latch_commit_en}};
	wire [N_LPE-1:0] lpe_leaf = {N_LPE{latch_pre_en}};
	wire [N_RGO-1:0] req_go_leaf = {N_RGO{req_go_w}};
	wire [N_RWR-1:0] req_wr_leaf = {N_RWR{req_wr_go_w}};
	wire [41:0] ebl_leaf = {42{en_s_blend_go}};
	wire [35:0] eid_leaf = {36{en_s_idle_miss}};
`endif

	/* Pre-shifted tag_x0/x1 for S_BLEND_PREP2 latch (so compare time needs 0 xsh muxes on bits T_HI:2) */
	wire tag_hi_bad = (p_xsh_b[2] == 2'd0) ? (|tag_x0_r[T_HI:T_HI-1] | |tag_x1_r[T_HI:T_HI-1]) :
	                  (p_xsh_b[2] == 2'd1) ? (tag_x0_r[T_HI] | tag_x1_r[T_HI]) : 1'b0;
	wire [T_HI:0] tag_x0_sh =
		(p_xsh_b[2] == 2'd2) ? tag_x0_r[T_HI:0] :
		(p_xsh_b[2] == 2'd1) ? {tag_x0_r[T_HI-1:0], 1'b0} :
		                       {tag_x0_r[T_HI-2:0], 2'b00};
	wire [T_HI:0] tag_x1_sh =
		(p_xsh_b[3] == 2'd2) ? tag_x1_r[T_HI:0] :
		(p_xsh_b[3] == 2'd1) ? {tag_x1_r[T_HI-1:0], 1'b0} :
		                       {tag_x1_r[T_HI-2:0], 2'b00};
	wire [12:0] tag_x0_prep = (LINE_SHIFT == 5) ?
		{tag_hi_bad ? 1'b1 : tag_x0_sh[T_HI], tag_x0_sh[11:0]} :
		{tag_hi_bad ? 1'b1 : 1'b0,            tag_x0_sh[11:0]};
	wire [12:0] tag_x1_prep = (LINE_SHIFT == 5) ?
		{tag_hi_bad ? 1'b0 : tag_x1_sh[T_HI], tag_x1_sh[11:0]} :
		{1'b0,                                tag_x1_sh[11:0]};

	/* Free-running / unreset datapath registers (<= 16 FFs per CE leaf, 0 rst_sync fanout) */
	always @(posedge clk) begin
`ifdef SYNTH_KINTEX7
		wb_row_base0 <= p_row_base0;
		wb_row_base1 <= wb_row_base1_comb;
`else
		if (!is_idle_reg) begin
			wb_row_base0 <= p_row_base0;
			wb_row_base1 <= wb_row_base1_comb;
		end
`endif

		if (en_crb_buf[0]) cur_row_base_r[15:0]  <= crb_w5_buf[0] ? p_row_base0[15:0]  : (crb_r_buf[0] ? wb_row_base1[15:0]  : wb_row_base0[15:0]);
		if (en_crb_buf[1]) cur_row_base_r[31:16] <= crb_w5_buf[1] ? p_row_base0[31:16] : (crb_r_buf[1] ? wb_row_base1[31:16] : wb_row_base0[31:16]);

		if (en_s_row_buf[0]) addr[15:0]  <= wb_addr_comb[15:0];
		if (en_s_row_buf[1]) addr[31:16] <= wb_addr_comb[31:16];

		if (etag0_we_buf[0]) etag[0][15:0]      <= addr[LINE_SHIFT +: 16];
		if (etag0_we_buf[1]) etag[0][LA_W-1:16] <= addr[ADDR_W-1 : LINE_SHIFT+16];
		if (etag1_we_buf[0]) etag[1][15:0]      <= addr[LINE_SHIFT +: 16];
		if (etag1_we_buf[1]) etag[1][LA_W-1:16] <= addr[ADDR_W-1 : LINE_SHIFT+16];

`ifdef SYNTH_KINTEX7
		for (l = 0; l < N_BE16; l = l + 1) begin
			edirty[0][16 * l +: 16] <= ed0_clr_buf[l] ? 16'd0 :
				(edirty[0][16 * l +: 16] | commit_wr0_en[16 * l +: 16]);
			edirty[1][16 * l +: 16] <= ed1_clr_buf[l] ? 16'd0 :
				(edirty[1][16 * l +: 16] | commit_wr1_en[16 * l +: 16]);
		end

		/* Buffered S_IDLE miss latches for color, xy, mask (Rule 1 fix: 3 LUTs to CE) */
		for (l = 0; l < 32; l = l + 1) begin
			if (eid_leaf[l])
				color[16 * l +: 16] <= d_color[16 * l +: 16];
		end
		if (eid_leaf[32])
			xy[15:0] <= {d_xy[15:LINE_SHIFT], d_xy_loff, d_xy[0]};
		if (eid_leaf[33])
			xy[31:16] <= d_xy[31:16];
		if (eid_leaf[34])
			mask <= d_smask;
		if (eid_leaf[35])
			rt <= d_rt;

		/* Buffered S_BLEND latches for r_bsrc, r_bdst, r_bmask, r_bsoff, r_bent, r_bps */
		for (l = 0; l < 32; l = l + 1) begin
			if (ebl_leaf[l])
				r_bsrc[16 * l +: 16] <= p_bsrc[16 * l +: 16];
		end
		for (l = 0; l < 8; l = l + 1) begin
			if (ebl_leaf[32 + l])
				r_bdst[16 * l +: 16] <= p_bdst[16 * l +: 16];
		end
		if (ebl_leaf[40])
			r_bsoff <= p_soff;
		if (ebl_leaf[41]) begin
			r_bmask <= p_mask;
			r_bent <= p_ent;
			r_bps <= p_ps;
		end

		/* Stage A -> B: latch decoded byte write enables & slot selects */
		for (l = 0; l < N_BE16; l = l + 1) begin
			if (lpe_leaf[l])
				pre_wr0_en[16 * l +: 16] <= pre_wr0_en_w[16 * l +: 16];
			if (lpe_leaf[N_BE16 + l])
				pre_wr1_en[16 * l +: 16] <= pre_wr1_en_w[16 * l +: 16];
		end
		for (l = 0; l < N_SEL16; l = l + 1) begin
			if (lpe_leaf[2 * N_BE16 + l])
				pre_wr0_sel[16 * l +: 16] <= pre_wr0_sel_w[16 * l +: 16];
			if (lpe_leaf[2 * N_BE16 + N_SEL16 + l])
				pre_wr1_sel[16 * l +: 16] <= pre_wr1_sel_w[16 * l +: 16];
		end
		for (ps_i = 0; ps_i < 32; ps_i = ps_i + 1) begin
			if (lpe_leaf[2 * N_BE16 + 2 * N_SEL16 + (ps_i / 8)])
				pre_u8_sel_rep[ps_i] <= pre_u8_sel_in_b[ps_i / 8];
		end

		/* Stage B -> C: latch muxed new pixel bytes for commit */
		for (l = 0; l < N_PRED; l = l + 1) begin
			if (lce_leaf[l])
				commit_wdata0[16 * l +: 16] <= wdata0_pre_comb[16 * l +: 16];
			if (lce_leaf[N_PRED + l])
				commit_wdata1[16 * l +: 16] <= wdata1_pre_comb[16 * l +: 16];
		end
`else
		if (ed0_clr_w)
			edirty[0] <= {LINE_BYTES{1'b0}};
		else if (commit_v)
			edirty[0] <= edirty[0] | commit_wr0_en;

		if (ed1_clr_w)
			edirty[1] <= {LINE_BYTES{1'b0}};
		else if (commit_v)
			edirty[1] <= edirty[1] | commit_wr1_en;

		if (en_s_idle_miss) begin
			color <= d_color;
			xy <= {d_xy[31:LINE_SHIFT], d_xy_loff, d_xy[0]};
			mask <= d_smask;
			rt <= d_rt;
		end

		if (en_s_blend_go) begin
			r_bsrc <= p_bsrc;
			r_bdst <= p_bdst;
			r_bsoff <= p_soff;
			r_bmask <= p_mask;
			r_bent <= p_ent;
			r_bps <= p_ps;
		end

		if (latch_pre_en) begin
			pre_wr0_en <= pre_wr0_en_w;
			pre_wr1_en <= pre_wr1_en_w;
			pre_wr0_sel <= pre_wr0_sel_w;
			pre_wr1_sel <= pre_wr1_sel_w;
			pre_u8_sel_rep[0] <= pre_u8_sel_in;
		end

		if (latch_commit_en) begin
			commit_wdata0 <= wdata0_pre_comb;
			commit_wdata1 <= wdata1_pre_comb;
		end
`endif

		/* Buffered S_BLEND_PREP2 line metadata latches (<= 16 FFs per leaf) */
		if (en_bp2_leaf[0]) begin
			line_rt <= rt;
			cached_drop <= p_drop;
			cached_ps <= p_ps;
			cached_xsh <= p_xsh;
		end
		if (en_bp2_leaf[1]) begin
			line_y <= xy[31:16];
		end
		if (en_bp2_leaf[2]) begin
			cached_tag_x0 <= {tag_x0_r[LA_W-1:13], tag_x0_prep};
		end
		if (en_bp2_leaf[3]) begin
			cached_tag_x1 <= {tag_x1_r[LA_W-1:13], tag_x1_prep};
		end
		if (en_bp2_leaf[4]) begin
			for (ps_i = 0; ps_i < 8; ps_i = ps_i + 1)
				cached_xsh_rep[ps_i] <= p_xsh_b[0];
		end
		if (en_bp2_leaf[5]) begin
			for (ps_i = 8; ps_i < 16; ps_i = ps_i + 1)
				cached_xsh_rep[ps_i] <= p_xsh_b[1];
		end
	end

	/* Rule 1 fix: decouple st[4:1] from cached_tag_x0, and compute st[0] / is_idle_reg next-state at Level 4 */
	(* keep = "true" *) wire idle_flush_go = is_idle_reg && !d_valid && !pipe_nz_0 && !pipe_nz_1 && (idle == 5'd16) && (ev[0] || ev[1]);
	(* keep = "true" *) wire miss_pre = !rst_sync && is_idle_reg && d_valid && !pipe_v[5] && !pipe_nz_1_r && !d_nocol;
	(* keep = "true" *) wire pipe_z4_0 = (pipe_v[4:0] == 5'd0);
	(* keep = "true" *) wire st0_miss_cand = miss_pre && pipe_z4_0 && !(sm_z0 && sm_z1 && sm_z2);

	reg [4:0] fsm_st_next;
	reg fsm_idle_next;
	always @(*) begin
		fsm_st_next = st;
		fsm_idle_next = is_idle_reg;
		case (st)
		S_IDLE: begin
			fsm_st_next = idle_flush_go ? S_FLUSH_PREP : S_IDLE;
			fsm_idle_next = !idle_flush_go;
		end
		S_ROW_WAIT1: begin fsm_st_next = S_ROW_WAIT2; fsm_idle_next = 1'b0; end
		S_ROW_WAIT2: begin fsm_st_next = S_ROW_WAIT3; fsm_idle_next = 1'b0; end
		S_ROW_WAIT3: begin fsm_st_next = S_ROW_WAIT4; fsm_idle_next = 1'b0; end
		S_ROW_WAIT4: begin fsm_st_next = S_ROW_WAIT5; fsm_idle_next = 1'b0; end
		S_ROW_WAIT5: begin fsm_st_next = S_ROW;       fsm_idle_next = 1'b0; end
		S_ROW_PREP:  begin fsm_st_next = S_ROW;       fsm_idle_next = 1'b0; end
		S_ROW: begin
			if (p_drop) begin
				fsm_st_next = S_IDLE;
				fsm_idle_next = 1'b1;
			end else if (p_lw) begin
				fsm_st_next = S_LOOK_PREP;
				fsm_idle_next = 1'b0;
			end else if (p_multi_b[0] && j != p_nl) begin
				fsm_st_next = S_ROW_PREP;
				fsm_idle_next = 1'b0;
			end else if (!r) begin
				fsm_st_next = S_ROW_PREP;
				fsm_idle_next = 1'b0;
			end else if (p_multi_b[0]) begin
				fsm_st_next = S_IDLE;
				fsm_idle_next = 1'b1;
			end else begin
				fsm_st_next = S_BLEND_PREP1;
				fsm_idle_next = 1'b0;
			end
		end
		S_LOOK_PREP: begin fsm_st_next = S_LOOK; fsm_idle_next = 1'b0; end
		S_LOOK: begin
			if (r_look_hit) begin
				fsm_st_next = p_multi_b[0] ? S_BLEND_PREP1 : (r ? S_BLEND_PREP1 : S_ROW_PREP);
				fsm_idle_next = 1'b0;
			end else if (r_edirty_nz) begin
				fsm_st_next = S_EVW;
				fsm_idle_next = 1'b0;
			end else begin
				fsm_st_next = S_FILL;
				fsm_idle_next = 1'b0;
			end
		end
		S_EVW: begin
			fsm_st_next = (!req_valid && !wait_rsp) ? S_FILL : S_EVW;
			fsm_idle_next = 1'b0;
		end
		S_FILL: begin
			if (!p_read || (!req_valid && wait_rsp && rsp_valid))
				fsm_st_next = p_multi_b[0] ? S_BLEND_PREP1 : (r ? S_BLEND_PREP1 : S_ROW_PREP);
			else
				fsm_st_next = S_FILL;
			fsm_idle_next = 1'b0;
		end
		S_BLEND_PREP1: begin fsm_st_next = S_BLEND_PREP2; fsm_idle_next = 1'b0; end
		S_BLEND_PREP2: begin fsm_st_next = S_BLEND;       fsm_idle_next = 1'b0; end
		S_BLEND: begin
			if (p_mask == 4'd0) begin
				if (!p_multi_b[1] && g_fsm != p_np) begin
					fsm_st_next = S_BLEND_PREP1;
					fsm_idle_next = 1'b0;
				end else if (!p_multi_b[1]) begin
					fsm_st_next = S_IDLE;
					fsm_idle_next = 1'b1;
				end else if (p_multi_b[0] && j != p_nl) begin
					fsm_st_next = S_ROW_PREP;
					fsm_idle_next = 1'b0;
				end else if (!r) begin
					fsm_st_next = S_ROW_PREP;
					fsm_idle_next = 1'b0;
				end else if (p_multi_b[0]) begin
					fsm_st_next = S_IDLE;
					fsm_idle_next = 1'b1;
				end else begin
					fsm_st_next = S_BLEND_PREP1;
					fsm_idle_next = 1'b0;
				end
			end else begin
				fsm_st_next = S_BWAIT;
				fsm_idle_next = 1'b0;
			end
		end
		S_BWAIT: begin
			fsm_st_next = p_ready ? S_BCOMMIT : S_BWAIT;
			fsm_idle_next = 1'b0;
		end
		S_BCOMMIT: begin
			if (!p_multi_b[1] && g_fsm != p_np) begin
				fsm_st_next = S_BLEND_PREP1;
				fsm_idle_next = 1'b0;
			end else if (!p_multi_b[1]) begin
				fsm_st_next = S_IDLE;
				fsm_idle_next = 1'b1;
			end else if (p_multi_b[0] && j != p_nl) begin
				fsm_st_next = S_ROW_PREP;
				fsm_idle_next = 1'b0;
			end else if (!r) begin
				fsm_st_next = S_ROW_PREP;
				fsm_idle_next = 1'b0;
			end else if (p_multi_b[0]) begin
				fsm_st_next = S_IDLE;
				fsm_idle_next = 1'b1;
			end else begin
				fsm_st_next = S_BLEND_PREP1;
				fsm_idle_next = 1'b0;
			end
		end
		S_FLUSH_PREP: begin fsm_st_next = S_FLUSH; fsm_idle_next = 1'b0; end
		S_FLUSH: begin
			if (r_edirty_nz) begin
				fsm_st_next = S_FLW;
				fsm_idle_next = 1'b0;
			end else if (r) begin
				fsm_st_next = S_IDLE;
				fsm_idle_next = 1'b1;
			end else begin
				fsm_st_next = S_FLUSH_PREP;
				fsm_idle_next = 1'b0;
			end
		end
		default: begin /* S_FLW */
			fsm_st_next = (!req_valid && !wait_rsp) ? S_FLUSH_PREP : S_FLW;
			fsm_idle_next = 1'b0;
		end
		endcase
	end

	(* keep = "true" *) wire st0_base = !rst_sync && fsm_st_next[0];
	(* keep = "true" *) wire idle_base = rst_sync || fsm_idle_next;
	wire st0_next, is_idle_next;
	wire [7:0] is_idle_bdst_next;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'hBA)) u_st0_nxt (
		.I0(st0_base), .I1(stream_hit_free), .I2(st0_miss_cand), .O(st0_next)
	);
	(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'h8A)) u_idle_nxt (
		.I0(idle_base), .I1(stream_hit_free), .I2(st0_miss_cand), .O(is_idle_next)
	);
	generate
	for (gb = 0; gb < 8; gb = gb + 1) begin : g_ibdst_nxt
		(* keep = "true", dont_touch = "true" *) LUT3 #(.INIT(8'h8A)) u_ibd_nxt (
			.I0(idle_base), .I1(stream_hit_free), .I2(st0_miss_cand), .O(is_idle_bdst_next[gb])
		);
	end
	endgenerate
`else
	assign st0_next = st0_base || (st0_miss_cand && !stream_hit_free);
	assign is_idle_next = idle_base && !(st0_miss_cand && !stream_hit_free);
	assign is_idle_bdst_next = {8{is_idle_next}};
`endif
	always @(posedge clk) begin
		st[0] <= st0_next;
		if (rst_sync)
			st[4:1] <= 4'd0;
		else
			st[4:1] <= fsm_st_next[4:1];
		is_idle_reg <= is_idle_next;
		is_idle_bdst <= is_idle_bdst_next;
	end

	always @(posedge clk) begin
		fsm_b_valid <= 1'b0;
		f_go <= 1'b0;
		if (req_valid && req_ready) begin
			req_valid <= 1'b0;
			wait_rsp <= 1'b1;
		end else if (req_go_w) begin
			req_valid <= 1'b1;
		end
		if (req_go_w)
			req_write <= req_wr_go_w;
		if (req_go_leaf[N_PRED + N_BE16 + 0])
			req_line[15:0] <= req_wr_leaf[N_BE16 + 0] ? etag[r][15:0] : addr[LINE_SHIFT +: 16];
		if (req_go_leaf[N_PRED + N_BE16 + 1])
			req_line[LA_W-1:16] <= req_wr_leaf[N_BE16 + 1] ? etag[r][LA_W-1:16] : addr[ADDR_W-1 : LINE_SHIFT+16];
		for (l = 0; l < N_BE16; l = l + 1) begin
			if (req_go_leaf[N_PRED + l])
				req_be[16 * l +: 16] <= req_wr_leaf[l] ? (r ? edirty[1][16 * l +: 16] : edirty[0][16 * l +: 16]) : 16'd0;
		end
		for (l = 0; l < N_PRED; l = l + 1) begin
			if (req_go_leaf[l])
				req_wdata[16 * l +: 16] <= r_wdata_leaf[l] ? edat[1][16 * l +: 16] : edat[0][16 * l +: 16];
		end
		if (rsp_valid)
			wait_rsp <= 1'b0;

		if (rst_sync) begin
			r <= 1'b0;
			j <= 2'd0;
			g <= 2'd0;
			g_fsm <= 2'd0;
			req_valid <= 1'b0;
			wait_rsp <= 1'b0;
			ev[0] <= 1'b0;
			ev[1] <= 1'b0;
			erd[0] <= 1'b0;
			erd[1] <= 1'b0;
			line_match_valid <= 1'b0;
			stream_cfg_ok <= 1'b0;
			off[0] <= {LINE_SHIFT{1'b0}};
			off[1] <= {LINE_SHIFT{1'b0}};
			off_p1[0] <= {LINE_SHIFT{1'b0}};
			off_p1[1] <= {LINE_SHIFT{1'b0}};
			cached_row_base0 <= 32'd0;
			cached_row_base1 <= 32'd0;
			cached_multi <= 1'b0;
			cached_np <= 2'd0;
			cached_path <= 2'd0;
			cached_read <= 1'b0;
			idle <= 5'd0;
			pipe_v <= 11'd0;
			pipe_nz_1_r <= 1'b0;
			commit_v <= 1'b0;
			commit_v_rep <= {N_CREP{1'b0}};
			commit_is_stream <= 1'b0;
			commit_id <= 4'd0;
			commit_wr0_en <= {LINE_BYTES{1'b0}};
			commit_wr1_en <= {LINE_BYTES{1'b0}};
			bwait_d1 <= 1'b0;
			r_look_hit <= 1'b0;
			r_edirty_nz <= 1'b0;
			release_valid <= 1'b0;
			release_id <= 4'd0;
		end else begin
			release_valid <= 1'b0;
			if (st_we) begin
				line_match_valid <= 1'b0;
				stream_cfg_ok <= 1'b0;
			end

			/* Advance 11-stage streaming shift register */
			pipe_nz_1_r <= (pipe_v[9:5] != 5'd0) || lce_leaf[N_LCE - 1];
`ifdef SYNTH_KINTEX7
			pipe_v[0] <= do_stream;
			for (ps_i = 1; ps_i <= 10; ps_i = ps_i + 1)
				pipe_v[ps_i] <= pipe_v[ps_i - 1];
`else
			if (do_stream || pipe_v != 11'd0)
				pipe_v <= {pipe_v[9:0], do_stream};
`endif

			if (do_stream) begin
				pipe_id[0] <= alloc_id;
				pipe_soff[0] <= {str_line_off_p1, str_line_off, str_line_off_p1, str_line_off};
				pipe_mask[0] <= s0_mask;
				pipe_ent[0] <= 4'b1100;
				pipe_ps[0] <= cached_ps;
			end
			if (pipe_v[9:0] != 10'd0) begin
				for (ps_i = 1; ps_i <= 9; ps_i = ps_i + 1) begin
					if (pipe_v[ps_i - 1]) begin
						pipe_id[ps_i] <= pipe_id[ps_i - 1];
						pipe_soff[ps_i] <= pipe_soff[ps_i - 1];
						pipe_mask[ps_i] <= pipe_mask[ps_i - 1];
						pipe_ent[ps_i] <= pipe_ent[ps_i - 1];
						pipe_ps[ps_i] <= pipe_ps[ps_i - 1];
					end
				end
				if (pipe_v[9])
					pipe_id[10] <= pipe_id[9];
			end

			/* Stage B -> C: pre-gate commit_wr0_en and commit_wr1_en with lce_leaf every cycle */
			commit_v <= lce_leaf[N_LCE - 1];
			if (lce_leaf[N_LCE - 1]) begin
				commit_is_stream <= pipe_v[10] && b_rvalid;
				commit_id <= pipe_id[10];
			end
`ifdef SYNTH_KINTEX7
			for (l = 0; l < N_BE16; l = l + 1) begin
				commit_wr0_en[16 * l +: 16] <= lce_leaf[2 * N_PRED + l] ? pre_wr0_en[16 * l +: 16] : 16'd0;
				commit_wr1_en[16 * l +: 16] <= lce_leaf[2 * N_PRED + N_BE16 + l] ? pre_wr1_en[16 * l +: 16] : 16'd0;
			end

			/* Stage C & S_FILL: update edat[0..1] with buffered slice enables */
			for (b_idx = 0; b_idx < LINE_BYTES; b_idx = b_idx + 1) begin
				if (fill_we0_leaf[b_idx / 2])
					edat[0][8 * b_idx +: 8] <= p_read_edat[b_idx / 2] ? rsp_rdata[8 * b_idx +: 8] : 8'd0;
				else if (commit_wr0_en[b_idx])
					edat[0][8 * b_idx +: 8] <= commit_wdata0[8 * b_idx +: 8];

				if (fill_we1_leaf[b_idx / 2])
					edat[1][8 * b_idx +: 8] <= p_read_edat[N_PRED + (b_idx / 2)] ? rsp_rdata[8 * b_idx +: 8] : 8'd0;
				else if (commit_wr1_en[b_idx])
					edat[1][8 * b_idx +: 8] <= commit_wdata1[8 * b_idx +: 8];
			end
`else
			commit_wr0_en <= latch_commit_en ? pre_wr0_en : {LINE_BYTES{1'b0}};
			commit_wr1_en <= latch_commit_en ? pre_wr1_en : {LINE_BYTES{1'b0}};

			if (fill_we0_w) begin
				edat[0] <= p_read ? rsp_rdata : {LINE_BYTES*8{1'b0}};
			end else if (commit_v) begin
				for (b_idx = 0; b_idx < LINE_BYTES; b_idx = b_idx + 1)
					if (commit_wr0_en[b_idx])
						edat[0][8 * b_idx +: 8] <= commit_wdata0[8 * b_idx +: 8];
			end

			if (fill_we1_w) begin
				edat[1] <= p_read ? rsp_rdata : {LINE_BYTES*8{1'b0}};
			end else if (commit_v) begin
				for (b_idx = 0; b_idx < LINE_BYTES; b_idx = b_idx + 1)
					if (commit_wr1_en[b_idx])
						edat[1][8 * b_idx +: 8] <= commit_wdata1[8 * b_idx +: 8];
			end
`endif
			if (commit_v && commit_is_stream) begin
				release_valid <= 1'b1;
				release_id <= commit_id;
			end

			case (st)
			S_IDLE: begin
				if (d_valid) begin
					idle <= 5'd0;
				end else if (!pipe_busy) begin
					if (idle != 5'd16)
						idle <= idle1;
					else if (ev[0] || ev[1])
						r <= 1'b0;
				end
			end
			S_ROW_WAIT1: begin
				r <= 1'b0;
				j <= 2'd0;
				g <= 2'd0;
				g_fsm <= 2'd0;
				line_match_valid <= 1'b0;
				stream_cfg_ok <= 1'b0;
			end
			S_ROW_WAIT2, S_ROW_WAIT3, S_ROW_WAIT4, S_ROW_WAIT5, S_ROW_PREP, S_BLEND_PREP1: begin
			end
			S_ROW: begin
				if (p_drop) begin
					r <= 1'b0;
					j <= 2'd0;
					g <= 2'd0;
					g_fsm <= 2'd0;
				end else if (!p_lw) begin
					next_row;
				end
			end
			S_LOOK_PREP: begin
				off[r] <= addr[LINE_SHIFT-1:0];
				off_p1[r] <= off_p1_comb;
				r_look_hit <= hit;
				r_edirty_nz <= ev[r] && edirty_nz;
			end
			S_LOOK: begin
				if (r_look_hit)
					line_in;
			end
			S_EVW: begin
				line_match_valid <= 1'b0;
				stream_cfg_ok <= 1'b0;
			end
			S_FILL: begin
				if (!p_read || (!req_valid && wait_rsp && rsp_valid)) begin
					ev[r] <= 1'b1;
					erd[r] <= p_read;
					line_in;
				end
			end
			S_BLEND_PREP2: begin
				/* By S_BLEND_PREP2, etag[0..1], wb_row_base0..1, and tag_x0_r/tag_x1_r are all stable */
				if (!p_multi_b[1] && g_fsm == 2'd0) begin
					line_match_valid <= 1'b1;
					stream_cfg_ok <= ev[0] && ev[1] &&
						rb0_aligned_r && rb1_aligned_r &&
						(mask[7:0] != 8'd0) && (mask[15:8] != 8'd0) &&
						(erd[0] || !p_read) && (erd[1] || !p_read) &&
						!p_multi_b[1] && (p_np == 2'd0) && (p_path == 2'd0) &&
						(tag_x0_r[LA_W-1 : TAG_CMP_BITS] == {(LA_W-TAG_CMP_BITS){1'b0}}) &&
						(tag_x1_r[LA_W-1 : TAG_CMP_BITS] == {(LA_W-TAG_CMP_BITS){1'b0}});
				end
			end
			S_BLEND: begin
				if (p_mask == 4'd0)
					pass_done;
				else begin
					fsm_b_valid <= (p_path == 2'd0);
					f_go <= (p_path == 2'd1);
					bwait_d1 <= 1'b0;
				end
			end
			S_BWAIT: begin
				bwait_d1 <= 1'b1;
			end
			S_BCOMMIT: begin
				pass_done;
			end
			S_FLUSH_PREP: begin
				line_match_valid <= 1'b0;
				stream_cfg_ok <= 1'b0;
				r_edirty_nz <= ev[r] && edirty_nz;
			end
			S_FLUSH: begin
				if (!r_edirty_nz) begin
					ev[r] <= 1'b0;
					r <= 1'b1;
					if (r) begin
						idle <= 5'd0;
						r <= 1'b0;
						j <= 2'd0;
						g <= 2'd0;
						g_fsm <= 2'd0;
					end
				end
			end
			default: begin /* S_FLW */
			end
			endcase
		end
	end

`ifndef SYNTHESIS
	/* A quad's row on one line stays in it; several lines start a line. */
	always @(posedge clk)
		if (rst_n && st == S_ROW && !p_drop && p_lw &&
		    (p_multi ? wb_addr_comb[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}} :
		    {{(32-LINE_SHIFT){1'b0}}, wb_addr_comb[LINE_SHIFT-1:0]} + 32'd2 * ({30'd0, p_np} + 32'd1) * {27'd0, p_ps} >
		    LINE_BYTES))
			$display("FAIL atg_rop_wb: attachment %0d row at %h crosses a line", rt, wb_addr_comb);
`endif

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, pre_in_ps[4:2], (MRT_COUNT != 0),
		wb_rb1_co, wb_addr_co, tag_x0_co, tag_x1_co, p_addr, p_addr1, p_row_base1, p_xoff,
		alloc_ready, use_stream_res, commit_v_rep, stream_ok, stream_hit_w, lce_mid, xsh_t0[0],
		cached_drop, cached_row_base0, cached_row_base1, cached_xsh, cached_multi, cached_np, cached_path, cached_read,
		cached_tag_x0[LA_W-1:13], cached_tag_x1[LA_W-1:13]};
endmodule

`default_nettype wire
