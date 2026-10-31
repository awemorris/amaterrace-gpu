/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_scan: RX quad traversal & Fine Rasterizer.
 *
 * Traverses bounding boxes via Coarse Tile Rasterizer (atg_rx_coarse,
 * 8x8 pixel tiles) and evaluates coverage of 2x2 quads. Empty tiles outside
 * the triangle are skipped in 1 cycle. Trivially accepted tiles bypass edge
 * testing.
 *
 * In boundary tiles, MSAA 4x coverage (16 sample locations across 4 lanes)
 * is evaluated in parallel using 48 addsub units, resolving fq_scov and
 * fq_ccov in a single clock cycle without serialization.
 *
 * Strict Guardrails: Verilog-2005 only, zero raw arithmetic operators.
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"
`ifdef CFG_ENABLE_MSAA
`define ATG_DEFAULT_ENABLE_MSAA (`CFG_ENABLE_MSAA != 0)
`else
`define ATG_DEFAULT_ENABLE_MSAA 0
`endif

`ifdef CFG_MSAA_SAMPLES
`define ATG_DEFAULT_MSAA_SAMPLES `CFG_MSAA_SAMPLES
`else
`define ATG_DEFAULT_MSAA_SAMPLES 1
`endif

`ifdef CFG_ENABLE_EARLY_Z
`define ATG_DEFAULT_ENABLE_EARLY_Z (`CFG_ENABLE_EARLY_Z != 0)
`else
`define ATG_DEFAULT_ENABLE_EARLY_Z 0
`endif

`ifdef CFG_COARSE_SCAN
`define ATG_DEFAULT_COARSE_SCAN (`CFG_COARSE_SCAN != 0)
`else
`define ATG_DEFAULT_COARSE_SCAN 0
`endif

module atg_rx_scan #(
	parameter HAS_SU = 1,	/* 1: fragment warps to the SU; 0: quads straight to the ROP with DEBUG_COLOR */
	parameter ENABLE_MSAA = `ATG_DEFAULT_ENABLE_MSAA,
	parameter MSAA_SAMPLES = `ATG_DEFAULT_MSAA_SAMPLES,
	parameter ENABLE_EARLY_Z = `ATG_DEFAULT_ENABLE_EARLY_Z,
	parameter COARSE_SCAN = `ATG_DEFAULT_COARSE_SCAN
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rx_setup */
	input wire sp_valid,
	output wire sp_ready,
	input wire [767:0] sp_tri,
	input wire sp_last,
	output reg pt_free,
	output reg [7:0] pt_free_idx,
	/* Covered quads of a non-raw triangle to atg_rx_frag (HAS_SU) */
	output wire fq_valid,
	input wire fq_ready,
	output wire [31:0] fq_xy,
	output wire [15:0] fq_scov,
	output wire [3:0] fq_ccov,
	output wire fq_end,
	input wire f_busy,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	output reg dx_valid,
	input wire dx_ready,
	output reg [15:0] dx_seq,
	output reg [31:0] dx_xy,
	output reg [3:0] dx_mask,
	(* extract_reset = "no" *) output reg [127:0] dx_depth,
	output reg dx_last,
	/* Sequence numbers (atg_rx_order) */
	output wire sq_req,
	input wire [15:0] sq_seq,
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [3:0] S_IDLE = 4'd0, S_SEQ = 4'd1, S_TILE_WAIT = 4'd2, S_WALK = 4'd3,
		S_Z = 4'd4, S_EMIT = 4'd5, S_LAST = 4'd6, S_FREE = 4'd7, S_FQ = 4'd8, S_STEP = 4'd9,
		S_SAMP = 4'd10, S_EVAL = 4'd11;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_inv_net;
	LUT1 #(.INIT(2'b01)) u_rst_inv (.I0(rst_n), .O(rst_inv_net));
	wire rst_n_inv = rst_inv_net;

	(* keep = "true", dont_touch = "true" *) wire ctv_fsm, ctv_edge;
	LUT1 #(.INIT(2'h2)) u_ctv_f (.I0(coarse_tile_valid), .O(ctv_fsm));
	LUT1 #(.INIT(2'h2)) u_ctv_e (.I0(coarse_tile_valid), .O(ctv_edge));

	(* keep = "true", dont_touch = "true" *) wire sp_val_fsm, sp_val_edge;
	(* keep = "true", dont_touch = "true" *) wire sp_val_qx, sp_val_qy;
	(* keep = "true", dont_touch = "true" *) wire we_ent_lo, we_ent_hi, sp_val_ctrl;
	LUT1 #(.INIT(2'h2)) u_spv_f  (.I0(sp_valid), .O(sp_val_fsm));
	LUT1 #(.INIT(2'h2)) u_spv_e  (.I0(sp_valid), .O(sp_val_edge));
	LUT1 #(.INIT(2'h2)) u_spv_qx (.I0(sp_valid), .O(sp_val_qx));
	LUT1 #(.INIT(2'h2)) u_spv_qy (.I0(sp_valid), .O(sp_val_qy));
	LUT1 #(.INIT(2'h2)) u_went_l (.I0(sp_valid), .O(we_ent_lo));
	LUT1 #(.INIT(2'h2)) u_went_h (.I0(sp_valid), .O(we_ent_hi));
	LUT1 #(.INIT(2'h2)) u_spv_c  (.I0(sp_valid), .O(sp_val_ctrl));
`else
	wire rst_n_inv = !rst_n;
	wire ctv_fsm = coarse_tile_valid;
	wire ctv_edge = coarse_tile_valid;
	wire sp_val_fsm = sp_valid;
	wire sp_val_edge = sp_valid;
	wire sp_val_qx = sp_valid;
	wire sp_val_qy = sp_valid;
	wire we_ent_lo = sp_valid;
	wire we_ent_hi = sp_valid;
	wire sp_val_ctrl = sp_valid;
`endif
	(* fsm_encoding = "none", extract_enable = "no", max_fanout = 16 *) reg [3:0] st;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [3:0] st_fsm_0, st_fsm_1, st_fsm_2, st_fsm_3;
	(* keep = "true", dont_touch = "true" *) wire [3:0] st_fsm_4, st_fsm_5, st_fsm_6, st_fsm_7, st_fsm_8;
	(* keep = "true", max_fanout = 16 *) wire [3:0] st_fsm_main;
	genvar gst;
	generate
		for (gst = 0; gst < 4; gst = gst + 1) begin : g_st_bufs
			LUT1 #(.INIT(2'h2)) u_st0 (.I0(st[gst]), .O(st_fsm_0[gst]));
			LUT1 #(.INIT(2'h2)) u_st1 (.I0(st[gst]), .O(st_fsm_1[gst]));
			LUT1 #(.INIT(2'h2)) u_st2 (.I0(st[gst]), .O(st_fsm_2[gst]));
			LUT1 #(.INIT(2'h2)) u_st3 (.I0(st[gst]), .O(st_fsm_3[gst]));
			LUT1 #(.INIT(2'h2)) u_st4 (.I0(st[gst]), .O(st_fsm_4[gst]));
			LUT1 #(.INIT(2'h2)) u_st5 (.I0(st[gst]), .O(st_fsm_5[gst]));
			LUT1 #(.INIT(2'h2)) u_st6 (.I0(st[gst]), .O(st_fsm_6[gst]));
			LUT1 #(.INIT(2'h2)) u_st7 (.I0(st[gst]), .O(st_fsm_7[gst]));
			LUT1 #(.INIT(2'h2)) u_st8 (.I0(st[gst]), .O(st_fsm_8[gst]));
			LUT1 #(.INIT(2'h2)) u_stm (.I0(st[gst]), .O(st_fsm_main[gst]));
		end
	endgenerate

	(* keep = "true", dont_touch = "true" *) wire [4:0] zc_0, zc_1, zc_2, zc_3;
	genvar gzc;
	generate
		for (gzc = 0; gzc < 5; gzc = gzc + 1) begin : g_zc_bufs
			LUT1 #(.INIT(2'h2)) u_zc0 (.I0(zc[gzc]), .O(zc_0[gzc]));
			LUT1 #(.INIT(2'h2)) u_zc1 (.I0(zc[gzc]), .O(zc_1[gzc]));
			LUT1 #(.INIT(2'h2)) u_zc2 (.I0(zc[gzc]), .O(zc_2[gzc]));
			LUT1 #(.INIT(2'h2)) u_zc3 (.I0(zc[gzc]), .O(zc_3[gzc]));
		end
	endgenerate

	(* keep = "true", dont_touch = "true" *) wire cur_trivial_cov, cur_trivial_scov;
	LUT1 #(.INIT(2'h2)) u_triv_c (.I0(cur_trivial), .O(cur_trivial_cov));
	LUT1 #(.INIT(2'h2)) u_triv_s (.I0(cur_trivial), .O(cur_trivial_scov));

`define SET_ST(val) begin st <= (val); end
`define SET_ZC(val) begin zc <= (val); end
`define SET_TRIV(val) begin cur_trivial <= (val); end
`else
	wire [3:0] st_fsm_0 = st;
	wire [3:0] st_fsm_1 = st;
	wire [3:0] st_fsm_2 = st;
	wire [3:0] st_fsm_3 = st;
	wire [3:0] st_fsm_4 = st;
	wire [3:0] st_fsm_5 = st;
	wire [3:0] st_fsm_6 = st;
	wire [3:0] st_fsm_7 = st;
	wire [3:0] st_fsm_8 = st;
	wire [3:0] st_fsm_main = st;
	wire [4:0] zc_0 = zc;
	wire [4:0] zc_1 = zc;
	wire [4:0] zc_2 = zc;
	wire [4:0] zc_3 = zc;
	wire cur_trivial_cov = cur_trivial;
	wire cur_trivial_scov = cur_trivial;
`define SET_ST(val) begin st <= (val); end
`define SET_ZC(val) begin zc <= (val); end
`define SET_TRIV(val) begin cur_trivial <= (val); end
`endif
	(* max_fanout = 16 *) reg r_tile_row_end;
	(* max_fanout = 16 *) reg r_tile_col_end;
	(* max_fanout = 16 *) reg wm;		/* warp mode: a non-raw triangle with an SU */
	(* max_fanout = 16 *) reg fend;	/* S_FQ: the end marker (no quad) */

	/* The triangle. */
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] a8 [0:2];	/* A << 8: one pixel in x */
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] b8 [0:2];
	(* extract_reset = "no" *) reg signed [47:0] er [0:2];	/* the edges at the tile's current quad row */
	(* extract_reset = "no" *) reg signed [47:0] ec [0:2];	/* at the current quad */
	reg [15:0] bx0, by0, bx1, by1;
	(* extract_enable = "no", extract_reset = "no" *) reg [15:0] qx, qy;
	reg [31:0] az, bz, cz;
	(* extract_enable = "no", extract_reset = "no" *) reg [23:0] ent;
	reg [2:0] fl;
	reg raw;
	reg [1:0] fi;	/* S_FREE: vertex */
	integer k;

	/* Multisampling: MS_CTRL[3:0] = 2 and SAMPLE_KILL[3:0]. */
	reg ms4;
	reg [3:0] kill;

	always @(posedge clk)
		if (rst_n_inv) begin
			ms4 <= 1'b0;
			kill <= 4'd0;
		end else if (st_we && st_idx == GHCI_S_MS_CTRL)
			ms4 <= (ENABLE_MSAA != 0) && (st_wdata[3:0] == 4'd2);
		else if (st_we && st_idx == GHCI_S_SAMPLE_KILL)
			kill <= (ENABLE_MSAA != 0) ? st_wdata[3:0] : 4'd0;

	/* Coarse Tile Rasterizer Interface */
	reg coarse_tri_valid;
	wire coarse_tri_ready;
	wire coarse_tile_valid;
	reg coarse_tile_ready;
	wire [15:0] coarse_tile_x, coarse_tile_y;
	wire [47:0] coarse_tile_e0, coarse_tile_e1, coarse_tile_e2;
	wire coarse_tile_trivial, coarse_tile_last, coarse_busy;

	reg [15:0] cur_tx, cur_ty;
	reg cur_trivial;
	reg cur_last_tile;

	/* The edges back to the quad origin (S_IDLE), one quad right (ec + 2 A) and
	 * one row down (er + 2 B); */
	wire [47:0] er0 [0:2];
	wire [47:0] ec_n [0:2];
	wire [47:0] er_n [0:2];
	wire [11:0] ed_carry_unused;
	genvar ge;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_er
		assign er0[ge] = sp_tri[96 * ge + 48 +: 48];
		assign ed_carry_unused[4 * ge +: 2] = 2'b00;
		am_add #(.W(48)) u_ec_n (.a(ec[ge]), .b(a8[ge] <<< 1), .ci(1'b0), .s(ec_n[ge]),
			.co(ed_carry_unused[4 * ge + 2]));
		am_add #(.W(48)) u_er_n (.a(er[ge]), .b(b8[ge] <<< 1), .ci(1'b0), .s(er_n[ge]),
			.co(ed_carry_unused[4 * ge + 3]));
	end
	endgenerate

	/* Sample offsets generator */
	wire [143:0] eb_cov_unused;
	wire [143:0] lowmv;
	wire [143:0] cov_op, cov_oq;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire we_sp_cv;
	LUT1 #(.INIT(2'h2)) u_wsp_cv (.I0((st_fsm_5 == S_IDLE) && sp_val_fsm), .O(we_sp_cv));
`else
	wire we_sp_cv = (st == S_IDLE) && sp_valid;
`endif
	generate
	if (ENABLE_MSAA != 0) begin : g_cov
		atg_rx_cov cv (
			.clk(clk),
			.i_load(we_sp_cv),
			.i_ab({sp_tri[192 +: 48], sp_tri[96 +: 48], sp_tri[0 +: 48]}),
			.i_ec({ec[2], ec[1], ec[0]}),
			.i_start(1'b0),
			.i_step(1'b0),
			.i_sc(2'd0),
			.i_samp(1'b0),
			.o_eb(eb_cov_unused),
			.o_lowm(lowmv),
			.o_op(cov_op),
			.o_oq(cov_oq)
		);
	end else begin : g_no_cov
		assign eb_cov_unused = 144'd0;
		assign lowmv = 144'd0;
		assign cov_op = 144'd0;
		assign cov_oq = 144'd0;
	end
	endgenerate

	wire s_e0_a_scan = s_e0_a_scan_ext;
	wire s_e0_b_scan = s_e0_b_scan_ext;
	wire s_e1_a_scan = s_e1_a_scan_ext;
	wire s_e1_b_scan = s_e1_b_scan_ext;
	wire s_e2_a_scan = s_e2_a_scan_ext;
	wire s_e2_b_scan = s_e2_b_scan_ext;

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire s_e0_a_coarse_eval, s_e0_b_coarse_eval;
	(* keep = "true", dont_touch = "true" *) wire s_e1_a_coarse_eval, s_e1_b_coarse_eval;
	(* keep = "true", dont_touch = "true" *) wire s_e2_a_coarse_eval, s_e2_b_coarse_eval;
	(* keep = "true", dont_touch = "true" *) wire s_e0_a_coarse_reg, s_e0_b_coarse_reg;
	(* keep = "true", dont_touch = "true" *) wire s_e1_a_coarse_reg, s_e1_b_coarse_reg;
	(* keep = "true", dont_touch = "true" *) wire s_e2_a_coarse_reg, s_e2_b_coarse_reg;
	(* keep = "true", dont_touch = "true" *) wire s_e0_a_scan_ext, s_e0_b_scan_ext;
	(* keep = "true", dont_touch = "true" *) wire s_e1_a_scan_ext, s_e1_b_scan_ext;
	(* keep = "true", dont_touch = "true" *) wire s_e2_a_scan_ext, s_e2_b_scan_ext;

	(* keep = "true", dont_touch = "true" *) wire [2:0] se0a_ce_l, se0b_ce_l;
	(* keep = "true", dont_touch = "true" *) wire [2:0] se1a_ce_l, se1b_ce_l;
	(* keep = "true", dont_touch = "true" *) wire [2:0] se2a_ce_l, se2b_ce_l;
	LUT1 #(.INIT(2'b10)) u_buf_se0ace_0 (.I0(sp_tri[23]),  .O(se0a_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se0ace_1 (.I0(sp_tri[23]),  .O(se0a_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se0ace_2 (.I0(sp_tri[23]),  .O(se0a_ce_l[2]));
	LUT1 #(.INIT(2'b10)) u_buf_se0bce_0 (.I0(sp_tri[47]),  .O(se0b_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se0bce_1 (.I0(sp_tri[47]),  .O(se0b_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se0bce_2 (.I0(sp_tri[47]),  .O(se0b_ce_l[2]));
	LUT1 #(.INIT(2'b10)) u_buf_se1ace_0 (.I0(sp_tri[119]), .O(se1a_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se1ace_1 (.I0(sp_tri[119]), .O(se1a_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se1ace_2 (.I0(sp_tri[119]), .O(se1a_ce_l[2]));
	LUT1 #(.INIT(2'b10)) u_buf_se1bce_0 (.I0(sp_tri[143]), .O(se1b_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se1bce_1 (.I0(sp_tri[143]), .O(se1b_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se1bce_2 (.I0(sp_tri[143]), .O(se1b_ce_l[2]));
	LUT1 #(.INIT(2'b10)) u_buf_se2ace_0 (.I0(sp_tri[215]), .O(se2a_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se2ace_1 (.I0(sp_tri[215]), .O(se2a_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se2ace_2 (.I0(sp_tri[215]), .O(se2a_ce_l[2]));
	LUT1 #(.INIT(2'b10)) u_buf_se2bce_0 (.I0(sp_tri[239]), .O(se2b_ce_l[0]));
	LUT1 #(.INIT(2'b10)) u_buf_se2bce_1 (.I0(sp_tri[239]), .O(se2b_ce_l[1]));
	LUT1 #(.INIT(2'b10)) u_buf_se2bce_2 (.I0(sp_tri[239]), .O(se2b_ce_l[2]));

	LUT1 #(.INIT(2'b10)) u_buf_se0acr (.I0(sp_tri[23]), .O(s_e0_a_coarse_reg));
	LUT1 #(.INIT(2'b10)) u_buf_se0bcr (.I0(sp_tri[47]), .O(s_e0_b_coarse_reg));
	LUT1 #(.INIT(2'b10)) u_buf_se1acr (.I0(sp_tri[119]), .O(s_e1_a_coarse_reg));
	LUT1 #(.INIT(2'b10)) u_buf_se1bcr (.I0(sp_tri[143]), .O(s_e1_b_coarse_reg));
	LUT1 #(.INIT(2'b10)) u_buf_se2acr (.I0(sp_tri[215]), .O(s_e2_a_coarse_reg));
	LUT1 #(.INIT(2'b10)) u_buf_se2bcr (.I0(sp_tri[239]), .O(s_e2_b_coarse_reg));

	LUT1 #(.INIT(2'b10)) u_buf_se0as (.I0(sp_tri[23]), .O(s_e0_a_scan_ext));
	LUT1 #(.INIT(2'b10)) u_buf_se0bs (.I0(sp_tri[47]), .O(s_e0_b_scan_ext));
	LUT1 #(.INIT(2'b10)) u_buf_se1as (.I0(sp_tri[119]), .O(s_e1_a_scan_ext));
	LUT1 #(.INIT(2'b10)) u_buf_se1bs (.I0(sp_tri[143]), .O(s_e1_b_scan_ext));
	LUT1 #(.INIT(2'b10)) u_buf_se2as (.I0(sp_tri[215]), .O(s_e2_a_scan_ext));
	LUT1 #(.INIT(2'b10)) u_buf_se2bs (.I0(sp_tri[239]), .O(s_e2_b_scan_ext));

	wire [2:0] ms4_m0, ms4_m1, ms4_m2;
	wire ms4_misc, ms4_act;
	wire [47:0] lowm0_muxed, lowm1_muxed, lowm2_muxed;
	genvar gms;
	generate
		for (gms = 0; gms < 3; gms = gms + 1) begin : g_ms4_buf
			LUT1 #(.INIT(2'h2)) u_m0 (.I0(ms4), .O(ms4_m0[gms]));
			LUT1 #(.INIT(2'h2)) u_m1 (.I0(ms4), .O(ms4_m1[gms]));
			LUT1 #(.INIT(2'h2)) u_m2 (.I0(ms4), .O(ms4_m2[gms]));
			assign lowm0_muxed[gms*16 +: 16] = ms4_m0[gms] ? lowmv[gms*16 +: 16] : 16'd0;
			assign lowm1_muxed[gms*16 +: 16] = ms4_m1[gms] ? lowmv[48 + gms*16 +: 16] : 16'd0;
			assign lowm2_muxed[gms*16 +: 16] = ms4_m2[gms] ? lowmv[96 + gms*16 +: 16] : 16'd0;
		end
	endgenerate
	LUT1 #(.INIT(2'h2)) u_ms4_misc (.I0(ms4), .O(ms4_misc));
	LUT1 #(.INIT(2'h2)) u_ms4_act  (.I0(ms4), .O(ms4_act));

`ifdef SYNTH_KINTEX7
	wire we_tile_x_raw = (st_fsm_4 == S_TILE_WAIT && ctv_edge) ||
	                     (st_fsm_4 == S_STEP && r_tile_row_end && r_tile_col_end && !cur_last_tile && ctv_edge) ||
	                     (st_fsm_4 == S_SEQ && COARSE_SCAN == 0);
`else
	wire we_tile_x_raw = (st == S_TILE_WAIT && coarse_tile_valid) ||
	                     (st == S_STEP && r_tile_row_end && r_tile_col_end && !cur_last_tile && coarse_tile_valid) ||
	                     (st == S_SEQ && COARSE_SCAN == 0);
`endif
	(* keep = "true", dont_touch = "true" *) wire we_tile_x, we_tile_y;
	LUT1 #(.INIT(2'h2)) u_wtx (.I0(we_tile_x_raw), .O(we_tile_x));
	LUT1 #(.INIT(2'h2)) u_wty (.I0(we_tile_x_raw), .O(we_tile_y));

`ifdef SYNTH_KINTEX7
	wire [15:0] next_tile_tx = (st_fsm_4 == S_SEQ) ? {bx0[15:1], 1'b0} : coarse_tile_x;
	wire [15:0] next_tile_ty = (st_fsm_8 == S_SEQ) ? {by0[15:1], 1'b0} : coarse_tile_y;
	wire next_tile_triv = (st_fsm_4 == S_SEQ) ? 1'b0 : coarse_tile_trivial;
	wire next_tile_last = (st_fsm_4 == S_SEQ) ? 1'b1 : coarse_tile_last;
`else
	wire [15:0] next_tile_tx = (st == S_SEQ) ? {bx0[15:1], 1'b0} : coarse_tile_x;
	wire [15:0] next_tile_ty = (st == S_SEQ) ? {by0[15:1], 1'b0} : coarse_tile_y;
	wire next_tile_triv = (st == S_SEQ) ? 1'b0 : coarse_tile_trivial;
	wire next_tile_last = (st == S_SEQ) ? 1'b1 : coarse_tile_last;
`endif

	always @(posedge clk) begin
		if (rst_n_inv) begin
			cur_tx <= 16'd0;
			`SET_TRIV(1'b0);
		end else if (we_tile_x) begin
			cur_tx <= next_tile_tx;
			`SET_TRIV(next_tile_triv);
		end
	end

	always @(posedge clk) begin
		if (rst_n_inv) begin
			cur_ty <= 16'd0;
			cur_last_tile <= 1'b0;
		end else if (we_tile_y) begin
			cur_ty <= next_tile_ty;
			cur_last_tile <= next_tile_last;
		end
	end

	wire we_fa_raw = (st_fsm_1 == S_Z) && ((zc_0 >= 5'd10 && zc_0 <= 5'd13) || (zc_0 >= 5'd15 && zc_0 <= 5'd18));
	(* keep = "true", dont_touch = "true" *) wire [3:0] we_fa_leaf;
	LUT1 #(.INIT(2'h2)) u_wfa0 (.I0(we_fa_raw), .O(we_fa_leaf[0]));
	LUT1 #(.INIT(2'h2)) u_wfa1 (.I0(we_fa_raw), .O(we_fa_leaf[1]));
	LUT1 #(.INIT(2'h2)) u_wfa2 (.I0(we_fa_raw), .O(we_fa_leaf[2]));
	LUT1 #(.INIT(2'h2)) u_wfa3 (.I0(we_fa_raw), .O(we_fa_leaf[3]));

	(* keep = "true", dont_touch = "true" *) wire [3:0] sel_zc_lo, sel_zc_hi;
	LUT1 #(.INIT(2'h2)) u_szc0_l (.I0(zc_2 == 5'd10), .O(sel_zc_lo[0]));
	LUT1 #(.INIT(2'h2)) u_szc1_l (.I0(zc_2 == 5'd11), .O(sel_zc_lo[1]));
	LUT1 #(.INIT(2'h2)) u_szc2_l (.I0(zc_2 == 5'd12), .O(sel_zc_lo[2]));
	LUT1 #(.INIT(2'h2)) u_szc3_l (.I0(zc_2 == 5'd13), .O(sel_zc_lo[3]));
	LUT1 #(.INIT(2'h2)) u_szc0_h (.I0(zc_2 == 5'd10), .O(sel_zc_hi[0]));
	LUT1 #(.INIT(2'h2)) u_szc1_h (.I0(zc_2 == 5'd11), .O(sel_zc_hi[1]));
	LUT1 #(.INIT(2'h2)) u_szc2_h (.I0(zc_2 == 5'd12), .O(sel_zc_hi[2]));
	LUT1 #(.INIT(2'h2)) u_szc3_h (.I0(zc_2 == 5'd13), .O(sel_zc_hi[3]));

	wire [15:0] next_fa_a_lo = sel_zc_lo[0] ? t1_0[15:0] :
	                           sel_zc_lo[1] ? t1_1[15:0] :
	                           sel_zc_lo[2] ? t1_2[15:0] :
	                           sel_zc_lo[3] ? t1_3[15:0] : fa_r[15:0];
	wire [15:0] next_fa_a_hi = sel_zc_hi[0] ? t1_0[31:16] :
	                           sel_zc_hi[1] ? t1_1[31:16] :
	                           sel_zc_hi[2] ? t1_2[31:16] :
	                           sel_zc_hi[3] ? t1_3[31:16] : fa_r[31:16];

	(* keep = "true", dont_touch = "true" *) wire sel_zc_b_lo, sel_zc_b_hi;
	LUT1 #(.INIT(2'h2)) u_szcb_l (.I0(zc_0 >= 5'd10 && zc_0 <= 5'd13), .O(sel_zc_b_lo));
	LUT1 #(.INIT(2'h2)) u_szcb_h (.I0(zc_0 >= 5'd10 && zc_0 <= 5'd13), .O(sel_zc_b_hi));
	wire [15:0] next_fa_b_lo = sel_zc_b_lo ? fm_r[15:0] : cz[15:0];
	wire [15:0] next_fa_b_hi = sel_zc_b_hi ? fm_r[31:16] : cz[31:16];

	always @(posedge clk) begin
		if (we_fa_leaf[0]) r_fa_a_lo <= next_fa_a_lo;
		if (we_fa_leaf[1]) r_fa_a_hi <= next_fa_a_hi;
		if (we_fa_leaf[2]) r_fa_b_lo <= next_fa_b_lo;
		if (we_fa_leaf[3]) r_fa_b_hi <= next_fa_b_hi;
	end
`else
	wire [2:0] se0a_ce_l = {3{sp_tri[23]}}, se0b_ce_l = {3{sp_tri[47]}};
	wire [2:0] se1a_ce_l = {3{sp_tri[119]}}, se1b_ce_l = {3{sp_tri[143]}};
	wire [2:0] se2a_ce_l = {3{sp_tri[215]}}, se2b_ce_l = {3{sp_tri[239]}};
	wire s_e0_a_coarse_reg = sp_tri[23], s_e0_b_coarse_reg = sp_tri[47];
	wire s_e1_a_coarse_reg = sp_tri[119], s_e1_b_coarse_reg = sp_tri[143];
	wire s_e2_a_coarse_reg = sp_tri[215], s_e2_b_coarse_reg = sp_tri[239];
	wire s_e0_a_scan_ext = sp_tri[23], s_e0_b_scan_ext = sp_tri[47];
	wire s_e1_a_scan_ext = sp_tri[119], s_e1_b_scan_ext = sp_tri[143];
	wire s_e2_a_scan_ext = sp_tri[215], s_e2_b_scan_ext = sp_tri[239];
	wire [47:0] lowm0_muxed = ms4 ? lowmv[0 +: 48] : 48'd0;
	wire [47:0] lowm1_muxed = ms4 ? lowmv[48 +: 48] : 48'd0;
	wire [47:0] lowm2_muxed = ms4 ? lowmv[96 +: 48] : 48'd0;
	wire ms4_misc = ms4;
	wire ms4_act = ms4;
`endif

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire rst_n_coarse;
	LUT1 #(.INIT(2'h2)) u_rst_coarse (.I0(rst_n), .O(rst_n_coarse));
`else
	wire rst_n_coarse = rst_n;
`endif

	generate
	if (COARSE_SCAN != 0) begin : g_coarse
		atg_rx_coarse u_coarse (
			.clk(clk),
			.rst_n(rst_n_coarse),
			.tri_valid(coarse_tri_valid),
			.tri_ready(coarse_tri_ready),
			.bbox_min_x(sp_tri[303:288]),
			.bbox_min_y(sp_tri[319:304]),
			.bbox_max_x(sp_tri[335:320]),
			.bbox_max_y(sp_tri[351:336]),
			.e0_a8({{5{se0a_ce_l[2]}}, {5{se0a_ce_l[1]}}, {6{se0a_ce_l[0]}}, sp_tri[0 +: 24], 8'd0}),
			.e0_b8({{5{se0b_ce_l[2]}}, {5{se0b_ce_l[1]}}, {6{se0b_ce_l[0]}}, sp_tri[24 +: 24], 8'd0}),
			.e0_er(er0[0]),
			.e1_a8({{5{se1a_ce_l[2]}}, {5{se1a_ce_l[1]}}, {6{se1a_ce_l[0]}}, sp_tri[96 +: 24], 8'd0}),
			.e1_b8({{5{se1b_ce_l[2]}}, {5{se1b_ce_l[1]}}, {6{se1b_ce_l[0]}}, sp_tri[96 + 24 +: 24], 8'd0}),
			.e1_er(er0[1]),
			.e2_a8({{5{se2a_ce_l[2]}}, {5{se2a_ce_l[1]}}, {6{se2a_ce_l[0]}}, sp_tri[192 +: 24], 8'd0}),
			.e2_b8({{5{se2b_ce_l[2]}}, {5{se2b_ce_l[1]}}, {6{se2b_ce_l[0]}}, sp_tri[192 + 24 +: 24], 8'd0}),
			.e2_er(er0[2]),
			.lowm0(lowm0_muxed),
			.lowm1(lowm1_muxed),
			.lowm2(lowm2_muxed),
			.tile_valid(coarse_tile_valid),
			.tile_ready(coarse_tile_ready),
			.tile_x(coarse_tile_x),
			.tile_y(coarse_tile_y),
			.tile_e0(coarse_tile_e0),
			.tile_e1(coarse_tile_e1),
			.tile_e2(coarse_tile_e2),
			.tile_trivial(coarse_tile_trivial),
			.tile_last(coarse_tile_last),
			.busy(coarse_busy)
		);
	end else begin : g_no_coarse
		assign coarse_tri_ready = 1'b1;
		assign coarse_tile_valid = 1'b0;
		assign coarse_tile_x = 16'd0;
		assign coarse_tile_y = 16'd0;
		assign coarse_tile_e0 = 48'd0;
		assign coarse_tile_e1 = 48'd0;
		assign coarse_tile_e2 = 48'd0;
		assign coarse_tile_trivial = 1'b0;
		assign coarse_tile_last = 1'b0;
		assign coarse_busy = 1'b0;
	end
	endgenerate

	/* Hierarchical Early-Z (Hi-Z) RAM */
	wire hiz_cull;
	wire [15:0] hiz_rd_zmax;
	generate
	if (ENABLE_EARLY_Z != 0) begin : g_hiz
		wire [10:0] hiz_rd_addr = {cur_ty[8:3], cur_tx[8:4]};
`ifdef SYNTH_KINTEX7
		wire hiz_wr_en = (st_fsm_5 == S_Z) && (zc_0 == 5'd19);
`else
		wire hiz_wr_en = (st == S_Z) && (zc == 5'd19);
`endif
		wire [10:0] hiz_wr_addr = {qy[8:3], qx[8:4]};
		wire [15:0] hiz_wr_z = zv[31:16];
		atg_rx_hiz #(
			.DEPTH_W(16),
			.TILE_ADDR_W(11)
		) u_hiz (
			.clk(clk),
			.rst_n(rst_n),
			.clear(st_we && st_idx == GHCI_S_DEPTH),
			.rd_addr(hiz_rd_addr),
			.rd_zmax(hiz_rd_zmax),
			.wr_en(hiz_wr_en),
			.wr_addr(hiz_wr_addr),
			.wr_zmax(hiz_wr_z)
		);
		assign hiz_cull = 1'b0;
	end else begin : g_no_hiz
		assign hiz_cull = 1'b0;
		assign hiz_rd_zmax = 16'd0;
	end
	endgenerate

	/* Quad lane coordinate stepping: qx and qy are always even, so +1 is bit 0 set */
	wire [16:0] qx1 = {1'b0, qx[15:1], 1'b1};
	wire [16:0] qy1 = {1'b0, qy[15:1], 1'b1};
	wire [16:0] qx2, qy2;
	wire [3:0] qstep_carry_unused;
	assign qstep_carry_unused[1:0] = 2'b00;
	am_add #(.W(17)) u_qx2 (.a({1'b0, qx}), .b(17'd2), .ci(1'b0), .s(qx2), .co(qstep_carry_unused[2]));
	am_add #(.W(17)) u_qy2 (.a({1'b0, qy}), .b(17'd2), .ci(1'b0), .s(qy2), .co(qstep_carry_unused[3]));

	/* Precompute ab8 = a8 + b8 */
	(* extract_reset = "no", equivalent_register_removal = "no" *) reg signed [47:0] ab8 [0:2];
	wire signed [47:0] ab8_comb [0:2];
	wire [2:0] ab8_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_ab8
		am_add #(.W(48)) u_ab8 (.a(a8[ge]), .b(b8[ge]), .ci(1'b0), .s(ab8_comb[ge]), .co(ab8_carry_unused[ge]));
	end
	endgenerate

	/* Lane edge values at pixel centre: ec, + A, + B, + (A + B) */
	wire [12*48-1:0] lve_comb;
	wire [8:0] lve_carry_unused;
	generate
	for (ge = 0; ge < 3; ge = ge + 1) begin : g_lv
		assign lve_comb[48 * (4 * ge) +: 48] = ec[ge];
		am_add #(.W(48)) u_la (.a(ec[ge]), .b(a8[ge]), .ci(1'b0), .s(lve_comb[48 * (4 * ge + 1) +: 48]),
			.co(lve_carry_unused[3 * ge + 0]));
		am_add #(.W(48)) u_lb (.a(ec[ge]), .b(b8[ge]), .ci(1'b0), .s(lve_comb[48 * (4 * ge + 2) +: 48]),
			.co(lve_carry_unused[3 * ge + 1]));
		am_add #(.W(48)) u_lab (.a(ec[ge]), .b(ab8[ge]), .ci(1'b0), .s(lve_comb[48 * (4 * ge + 3) +: 48]),
			.co(lve_carry_unused[3 * ge + 2]));
	end
	endgenerate

	/* Pipelined lve register to break carry chains between lve and sample adders */
	(* extract_reset = "no" *) reg [12*48-1:0] r_lve;
`ifdef SYNTH_KINTEX7
	wire [2:0] we_lve_mid;
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wlm0 (.I0(st_fsm_6 == S_WALK), .O(we_lve_mid[0]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wlm1 (.I0(st_fsm_6 == S_WALK), .O(we_lve_mid[1]));
	(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wlm2 (.I0(st_fsm_6 == S_WALK), .O(we_lve_mid[2]));
	wire [35:0] we_lve_leaf;
	genvar glv;
	generate
		for (glv = 0; glv < 36; glv = glv + 1) begin : g_we_lve_tree
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wlvl (.I0(we_lve_mid[glv / 12]), .O(we_lve_leaf[glv]));
			always @(posedge clk) begin
				if (we_lve_leaf[glv]) begin
					r_lve[glv * 16 +: 16] <= lve_comb[glv * 16 +: 16];
				end
			end
		end
	endgenerate
`else
	always @(posedge clk) begin
		if (st == S_WALK)
			r_lve <= lve_comb;
	end
`endif

	/* Parallel sample evaluation: 3 edges x 4 lanes x MSAA_SAMPLES */
	wire [47:0] esamp_sign;
	wire [47:0] esamp_carry_unused;
	wire [48*47-1:0] esamp_unused;
	genvar gk, gs;
	generate
	if (ENABLE_MSAA != 0) begin : g_msaa_eval
		for (ge = 0; ge < 3; ge = ge + 1) begin : g_samp_e
			wire signed [47:0] ope = cov_op[48 * ge +: 48];
			wire signed [47:0] oqe = cov_oq[48 * ge +: 48];
			for (gk = 0; gk < 4; gk = gk + 1) begin : g_samp_k
				wire signed [47:0] lve_val = r_lve[48 * (4 * ge + gk) +: 48];
				for (gs = 0; gs < 4; gs = gs + 1) begin : g_samp_s
					localparam integer idx = 16 * ge + 4 * gk + gs;
					if (gs < MSAA_SAMPLES) begin : g_active_sample
						wire signed [47:0] s_off = (gs == 0 || gs == 3) ? ope : oqe;
`ifdef MUT_SAMPLE_SWAP
						wire s_sub = (gs == 0 || gs == 1);
`else
						wire s_sub = (gs == 0 || gs == 2);
`endif
						wire [47:0] s_val;
						am_addsub #(.W(48)) u_esamp (
							.a(lve_val),
							.b(s_off),
							.sub(s_sub),
							.s(s_val),
							.co(esamp_carry_unused[idx])
						);
						assign esamp_sign[idx] = s_val[47];
						assign esamp_unused[47 * idx +: 47] = s_val[46:0];
					end else begin : g_inactive_sample
						assign esamp_sign[idx] = 1'b0;
						assign esamp_carry_unused[idx] = 1'b0;
						assign esamp_unused[47 * idx +: 47] = 47'd0;
					end
				end
			end
		end
	end else begin : g_no_msaa_eval
		assign esamp_sign = 48'd0;
		assign esamp_carry_unused = 48'd0;
		assign esamp_unused = { (48*47){1'b0} };
	end
	endgenerate

	/* Registered sample signs and edge signs to break carry chain before coverage logic */
	(* dont_touch = "true", extract_reset = "no" *) reg [47:0] r_esamp_sign;
	(* dont_touch = "true", extract_reset = "no" *) reg [11:0] r_lve_sign;
	(* dont_touch = "true", extract_reset = "no" *) reg [3:0] r_inb;

	/* Quad lane in-bounds logic: evaluated at S_WALK, registered to r_inb */
	wire [3:0] inb_comb;
	assign inb_comb[0] = !(qx < bx0 || qx >= bx1 || qy < by0 || qy >= by1);
	assign inb_comb[1] = !(qx1 < {1'b0, bx0} || qx1 >= {1'b0, bx1} || qy < by0 || qy >= by1);
	assign inb_comb[2] = !(qx < bx0 || qx >= bx1 || qy1 < {1'b0, by0} || qy1 >= {1'b0, by1});
	assign inb_comb[3] = !(qx1 < {1'b0, bx0} || qx1 >= {1'b0, bx1} || qy1 < {1'b0, by0} || qy1 >= {1'b0, by1});

	/* Coverage logic: purely random logic evaluated from flops in S_EVAL */
	reg [3:0] cov_edge;
	reg [3:0] ccov_comb;
	reg [15:0] scov_comb;
	integer e, ln, sm;

	always @(*) begin
		for (ln = 0; ln < 4; ln = ln + 1) begin
			cov_edge[ln] = r_inb[ln];
			ccov_comb[ln] = r_inb[ln];
			for (e = 0; e < 3; e = e + 1) begin
				if (r_lve_sign[4 * e + ln]) begin
					cov_edge[ln] = 1'b0;
					ccov_comb[ln] = 1'b0;
				end
			end
			for (sm = 0; sm < 4; sm = sm + 1) begin
				if (ENABLE_MSAA != 0) begin
					scov_comb[4 * ln + sm] = r_inb[ln] && !kill[sm] && (sm < MSAA_SAMPLES) &&
						!r_esamp_sign[16 * 0 + 4 * ln + sm] &&
						!r_esamp_sign[16 * 1 + 4 * ln + sm] &&
						!r_esamp_sign[16 * 2 + 4 * ln + sm];
				end else begin
					scov_comb[4 * ln + sm] = (sm == 0) ? (r_inb[ln] && !kill[0] && ccov_comb[ln]) : 1'b0;
				end
			end
		end
	end

	/* Trivial accept quad coverage */
	reg [3:0] cov_triv;
	reg [15:0] scov_triv;
	always @(*) begin
		for (ln = 0; ln < 4; ln = ln + 1) begin
			cov_triv[ln] = r_inb[ln];
			for (sm = 0; sm < 4; sm = sm + 1) begin
				if (ENABLE_MSAA != 0)
					scov_triv[4 * ln + sm] = r_inb[ln] && !kill[sm] && (sm < MSAA_SAMPLES);
				else
					scov_triv[4 * ln + sm] = (sm == 0) ? (r_inb[ln] && !kill[0]) : 1'b0;
			end
		end
	end

	/* Combined quad evaluation results */
`ifdef SYNTH_KINTEX7
	wire [3:0] cur_cov = cur_trivial_cov ? cov_triv : cov_edge;
	wire [3:0] cur_ccov = cur_trivial_cov ? cov_triv : ccov_comb;
	wire [15:0] cur_scov = cur_trivial_scov ? scov_triv : scov_comb;
`else
	wire [3:0] cur_cov = cur_trivial ? cov_triv : cov_edge;
	wire [3:0] cur_ccov = cur_trivial ? cov_triv : ccov_comb;
	wire [15:0] cur_scov = cur_trivial ? scov_triv : scov_comb;
`endif
	wire [3:0] cov1 = cur_cov & ~{4{kill[0]}};

	(* extract_enable = "no", extract_reset = "no" *) reg [15:0] scov_reg;
	(* extract_enable = "no", extract_reset = "no" *) reg [3:0] ccov_reg;
	(* extract_enable = "no", extract_reset = "no" *) reg [3:0] cov_reg;
`ifdef SYNTH_KINTEX7
	(* extract_enable = "no", extract_reset = "no", keep = "true", dont_touch = "true" *) reg [3:0] cov_reg_scov;
`endif

	wire [3:0] cov1_edge = cov_edge & ~{4{kill[0]}};
	wire [3:0] cov1_triv = cov_triv & ~{4{kill[0]}};
	wire w_empty_triv = wm ? (ms4_misc ? (scov_triv == 16'd0) : (cov1_triv == 4'd0)) : (cov_triv == 4'd0);
`ifdef SYNTH_KINTEX7
	wire [15:0] s_active;
	genvar gsi;
	generate
		for (gsi = 0; gsi < 16; gsi = gsi + 1) begin : g_s_act
			localparam integer qln = gsi / 4;
			localparam integer qsm = gsi % 4;
			if (ENABLE_MSAA != 0) begin : g_msaa_s
				assign s_active[gsi] = r_inb[qln] && (ms4_act ? (!kill[qsm] && (qsm < MSAA_SAMPLES) && !r_esamp_sign[gsi] && !r_esamp_sign[16 + gsi] && !r_esamp_sign[32 + gsi]) :
				                                                 (qsm == 0 && !kill[0] && !r_lve_sign[qln] && !r_lve_sign[4 + qln] && !r_lve_sign[8 + qln]));
			end else begin : g_noms_s
				assign s_active[gsi] = (qsm == 0) && r_inb[qln] && !kill[0] &&
				                       !r_lve_sign[qln] && !r_lve_sign[4 + qln] && !r_lve_sign[8 + qln];
			end
		end
	endgenerate

	wire [3:0] quad_cov_act;
	genvar gqa;
	generate
		for (gqa = 0; gqa < 4; gqa = gqa + 1) begin : g_q_act
			assign quad_cov_act[gqa] = |s_active[4 * gqa +: 4];
		end
	endgenerate

	wire any_cov = cur_trivial_cov ? (wm ? (ms4_misc ? (|scov_triv) : (|cov1_triv)) : (|cov_triv))
	                               : (|quad_cov_act);
	wire w_empty = !any_cov;
`else
	wire w_empty_edge = wm ? (ms4_misc ? (scov_comb == 16'd0) : (cov1_edge == 4'd0)) : (cov_edge == 4'd0);
	wire w_empty = cur_trivial ? w_empty_triv : w_empty_edge;
`endif

	/* Stepping within 8x8 coarse tile or bounding box */
	wire [15:0] cur_tx_end, cur_ty_end;
	wire [1:0] tend_carry_unused;
	generate
	if (COARSE_SCAN != 0) begin : g_coarse_end
		am_add #(.W(16)) u_tx_end (.a(cur_tx), .b(16'd8), .ci(1'b0), .s(cur_tx_end), .co(tend_carry_unused[0]));
		am_add #(.W(16)) u_ty_end (.a(cur_ty), .b(16'd8), .ci(1'b0), .s(cur_ty_end), .co(tend_carry_unused[1]));
	end else begin : g_direct_end
		assign cur_tx_end = bx1;
		assign cur_ty_end = by1;
		assign tend_carry_unused = 2'd0;
	end
	endgenerate

	wire tile_row_end = (qx2 >= {1'b0, cur_tx_end}) || (qx2 >= {1'b0, bx1});
	wire tile_col_end = (qy2 >= {1'b0, cur_ty_end}) || (qy2 >= {1'b0, by1});

	/* Depth: z = (Az i + Bz j) + Cz, i = x - bx0, j = y - by0, clamped to [0, 1].
	 * Stage 0 (zc == 0): latch dx0, dx1, dy0, dy1 (17-bit sub).
	 * Stage 1 (zc == 1): convert to fp32 (fix2f).
	 * Stage 2..9: fmul.
	 * Stage 10..17: fadd (two phases: Az*i + Bz*j, then + Cz).
	 * Stage 18..21: write zv, transition to S_EMIT at zc == 21.
	 */
	(* extract_enable = "no", extract_reset = "no" *) reg [4:0] zc;
	reg [1:0] r_zl;
	(* extract_enable = "no", extract_reset = "no" *) reg [3:0] zmask;
	reg [31:0] t1_0, t1_1, t1_2, t1_3;
	reg [127:0] zv;

	wire [16:0] dx0_comb, dy0_comb, dx1_comb, dy1_comb;
	wire [3:0] dxy_carry_unused;
	am_sub #(.W(17)) u_dx0 (.a({1'b0, qx}), .b({1'b0, bx0}), .bi(1'b0), .d(dx0_comb), .bo(dxy_carry_unused[0]));
	am_sub #(.W(17)) u_dy0 (.a({1'b0, qy}), .b({1'b0, by0}), .bi(1'b0), .d(dy0_comb), .bo(dxy_carry_unused[1]));
	am_sub #(.W(17)) u_dx1 (.a(qx1), .b({1'b0, bx0}), .bi(1'b0), .d(dx1_comb), .bo(dxy_carry_unused[2]));
	am_sub #(.W(17)) u_dy1 (.a(qy1), .b({1'b0, by0}), .bi(1'b0), .d(dy1_comb), .bo(dxy_carry_unused[3]));

	reg [16:0] r_dx0, r_dy0, r_dx1, r_dy1;

	wire [31:0] f_dx0_comb, f_dy0_comb, f_dx1_comb, f_dy1_comb;
	am_fp_fix2f #(.W(17), .F(0), .SIGNED(0)) u_fdx0 (.v(r_dx0), .f(f_dx0_comb));
	am_fp_fix2f #(.W(17), .F(0), .SIGNED(0)) u_fdy0 (.v(r_dy0), .f(f_dy0_comb));
	am_fp_fix2f #(.W(17), .F(0), .SIGNED(0)) u_fdx1 (.v(r_dx1), .f(f_dx1_comb));
	am_fp_fix2f #(.W(17), .F(0), .SIGNED(0)) u_fdy1 (.v(r_dy1), .f(f_dy1_comb));

	reg [31:0] r_fdx0, r_fdy0, r_fdx1, r_fdy1;

	wire [1:0] r_zl_next;
	wire r_zl_co_unused;
	am_add #(.W(2)) u_zl_inc (.a(r_zl), .b(2'd0), .ci(1'b1), .s(r_zl_next), .co(r_zl_co_unused));

	(* dont_touch = "true" *) reg r_is_bz_a, r_is_bz_b;
	reg r_fm_v;
	wire fm_v = r_fm_v;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) reg r_is_bz_a_l, r_is_bz_a_h;
	(* keep = "true", dont_touch = "true" *) reg r_is_bz_b_l, r_is_bz_b_h0, r_is_bz_b_h1;
	(* keep = "true", dont_touch = "true" *) reg [1:0] r_zl_l, r_zl_h;

`define SET_BZA(val) begin r_is_bz_a <= (val); r_is_bz_a_l <= (val); r_is_bz_a_h <= (val); end
`define SET_BZB(val) begin r_is_bz_b <= (val); r_is_bz_b_l <= (val); r_is_bz_b_h0 <= (val); r_is_bz_b_h1 <= (val); end
`define SET_ZL(val)  begin r_zl <= (val); r_zl_l <= (val); r_zl_h <= (val); end

	wire [15:0] fm_a_lo = r_is_bz_a_l ? bz[15:0] : az[15:0];
	wire [15:0] fm_a_hi = r_is_bz_a_h ? bz[31:16] : az[31:16];
	wire [15:0] fm_b_lo = r_is_bz_b_l ? (r_zl_l[1] ? r_fdy1[15:0] : r_fdy0[15:0]) : (r_zl_l[0] ? r_fdx1[15:0] : r_fdx0[15:0]);
	wire [7:0] fm_b_hi_0 = r_is_bz_b_h0 ? (r_zl_h[1] ? r_fdy1[23:16] : r_fdy0[23:16]) : (r_zl_h[0] ? r_fdx1[23:16] : r_fdx0[23:16]);
	wire [7:0] fm_b_hi_1 = r_is_bz_b_h1 ? (r_zl_h[1] ? r_fdy1[31:24] : r_fdy0[31:24]) : (r_zl_h[0] ? r_fdx1[31:24] : r_fdx0[31:24]);
	wire [15:0] fm_b_hi = {fm_b_hi_1, fm_b_hi_0};
	wire [31:0] fm_a = {fm_a_hi, fm_a_lo};
	wire [31:0] fm_b = {fm_b_hi, fm_b_lo};
`else
`define SET_BZA(val) begin r_is_bz_a <= (val); end
`define SET_BZB(val) begin r_is_bz_b <= (val); end
`define SET_ZL(val)  begin r_zl <= (val); end

	wire [31:0] fm_a = r_is_bz_a ? bz : az;
	wire [31:0] fm_b = r_is_bz_b ? (r_zl[1] ? r_fdy1 : r_fdy0) : (r_zl[0] ? r_fdx1 : r_fdx0);
`endif

	reg r_fa_v;
	reg [15:0] r_fa_a_lo, r_fa_a_hi;
	reg [15:0] r_fa_b_lo, r_fa_b_hi;
	wire [31:0] r_fa_a = {r_fa_a_hi, r_fa_a_lo};
	wire [31:0] r_fa_b = {r_fa_b_hi, r_fa_b_lo};
	wire fm_o, fa_o;
	wire [31:0] fm_r, fa_r;

	atg_rx_fmul #(.LAT(4)) fmul (.clk(clk), .rst_n(rst_n), .i_valid(fm_v), .i_a(fm_a), .i_b(fm_b),
		.o_valid(fm_o), .o_r(fm_r));
	atg_rx_fadd #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid(r_fa_v), .i_a(r_fa_a), .i_b(r_fa_b),
		.i_sub(1'b0), .o_valid(fa_o), .o_r(fa_r));
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire zcl_zero_lo, zcl_zero_hi;
	(* keep = "true", dont_touch = "true" *) wire zcl_sat_lo, zcl_sat_hi;
	wire is_nan_or_neg = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0);
	wire is_sat = fa_r > 32'h3F800000;
	LUT1 #(.INIT(2'h2)) u_zcl_zlo (.I0(is_nan_or_neg), .O(zcl_zero_lo));
	LUT1 #(.INIT(2'h2)) u_zcl_zhi (.I0(is_nan_or_neg), .O(zcl_zero_hi));
	LUT1 #(.INIT(2'h2)) u_zcl_slo (.I0(is_sat), .O(zcl_sat_lo));
	LUT1 #(.INIT(2'h2)) u_zcl_shi (.I0(is_sat), .O(zcl_sat_hi));
	wire [15:0] zcl_lo = zcl_zero_lo ? 16'd0 : (zcl_sat_lo ? 16'h0000 : fa_r[15:0]);
	wire [15:0] zcl_hi = zcl_zero_hi ? 16'd0 : (zcl_sat_hi ? 16'h3F80 : fa_r[31:16]);
	wire [31:0] zcl = {zcl_hi, zcl_lo};
`else
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > 32'h3F800000 ? 32'h3F800000 : fa_r;
`endif

	wire [1:0] fi1;
	wire [4:0] zc1;
	wire [1:0] ct_carry_unused;
	am_add #(.W(2)) u_fi1 (.a(fi), .b(2'd0), .ci(1'b1), .s(fi1), .co(ct_carry_unused[0]));
	am_add #(.W(5)) u_zc1 (.a(zc), .b(5'd0), .ci(1'b1), .s(zc1), .co(ct_carry_unused[1]));

	/* The quad that waits for its successor */
	reg pend;
	reg [31:0] p_xy;
	reg [3:0] p_mask;
	reg [127:0] p_z;
	reg [15:0] seq;

`ifdef SYNTH_KINTEX7
	wire [7:0] clr_zv_leaf;
	wire [7:0] we_zv_leaf;
	wire [7:0] we_pz_leaf;
	wire [7:0] we_dxd_leaf;
	wire [1:0] we_dxy_leaf;
	wire [1:0] we_pxy_leaf;

	wire dx_stall = !(dx_valid && dx_ready);
	(* keep = "true", dont_touch = "true" *) wire [2:0] dx_stall_b;
	LUT1 #(.INIT(2'h2)) u_dxst0 (.I0(dx_stall), .O(dx_stall_b[0]));
	LUT1 #(.INIT(2'h2)) u_dxst1 (.I0(dx_stall), .O(dx_stall_b[1]));
	LUT1 #(.INIT(2'h2)) u_dxst2 (.I0(dx_stall), .O(dx_stall_b[2]));

	wire we_pz_raw = (st_fsm_3 == S_EMIT) && (!pend || !dx_stall_b[0]);
	wire we_dxd_raw = dx_stall_b[1] && (((st_fsm_3 == S_EMIT) && pend) || (st_fsm_3 == S_LAST));
	wire we_dxy_raw = dx_stall_b[2] && (((st_fsm_3 == S_EMIT) && pend) || (st_fsm_3 == S_LAST));
	wire we_pxy_raw = we_pz_raw;

	wire sel_last_raw = (st_fsm_3 == S_LAST) && !pend;
	(* keep = "true", dont_touch = "true" *) wire [7:0] sel_last_d_leaf;
	(* keep = "true", dont_touch = "true" *) wire [1:0] sel_last_xy_leaf;

	genvar gzs;
	generate
		for (gzs = 0; gzs < 8; gzs = gzs + 1) begin : g_zv_slices
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_czv (.I0(st_fsm_1 == S_Z && zc_3 == 5'd0), .O(clr_zv_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wzv (.I0(st_fsm_1 == S_Z && zc_3 == (5'd20 + (gzs / 2)) && zmask[gzs / 2]), .O(we_zv_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wpz (.I0(we_pz_raw), .O(we_pz_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdz (.I0(we_dxd_raw), .O(we_dxd_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sld (.I0(sel_last_raw), .O(sel_last_d_leaf[gzs]));

			always @(posedge clk) begin
				if (clr_zv_leaf[gzs])
					zv[gzs * 16 +: 16] <= 16'd0;
				else if (we_zv_leaf[gzs])
					zv[gzs * 16 +: 16] <= (gzs % 2 == 0) ? zcl_lo : zcl_hi;
			end

			always @(posedge clk) begin
				if (we_pz_leaf[gzs])
					p_z[gzs * 16 +: 16] <= zv[gzs * 16 +: 16];
			end

			always @(posedge clk) begin
				if (we_dxd_leaf[gzs])
					dx_depth[gzs * 16 +: 16] <= sel_last_d_leaf[gzs] ? 16'd0 : p_z[gzs * 16 +: 16];
			end
		end
		for (gzs = 0; gzs < 2; gzs = gzs + 1) begin : g_xy_slices
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wdx (.I0(we_dxy_raw), .O(we_dxy_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_wpx (.I0(we_pxy_raw), .O(we_pxy_leaf[gzs]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_slx (.I0(sel_last_raw), .O(sel_last_xy_leaf[gzs]));

			always @(posedge clk) begin
				if (we_pxy_leaf[gzs])
					p_xy[gzs * 16 +: 16] <= (gzs == 0) ? qx : qy;
			end

			always @(posedge clk) begin
				if (we_dxy_leaf[gzs])
					dx_xy[gzs * 16 +: 16] <= sel_last_xy_leaf[gzs] ?
						((gzs == 0) ? {bx0[15:1], 1'b0} : {by0[15:1], 1'b0}) :
						p_xy[gzs * 16 +: 16];
			end
		end
	endgenerate

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire we_seq;
	LUT1 #(.INIT(2'h2)) u_wseq (.I0(st_fsm_3 == S_SEQ), .O(we_seq));
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) seq <= 16'd0;
		else if (we_seq) seq <= sq_seq;
	end
`endif

	wire we_sp_idle = (st_fsm_5 == S_IDLE) && sp_val_fsm;
	(* keep = "true", dont_touch = "true" *) wire [3:0] we_sp_branch;
	LUT1 #(.INIT(2'h2)) u_sp_b0 (.I0(we_sp_idle), .O(we_sp_branch[0]));
	LUT1 #(.INIT(2'h2)) u_sp_b1 (.I0(we_sp_idle), .O(we_sp_branch[1]));
	LUT1 #(.INIT(2'h2)) u_sp_b2 (.I0(we_sp_idle), .O(we_sp_branch[2]));
	LUT1 #(.INIT(2'h2)) u_sp_b3 (.I0(we_sp_idle), .O(we_sp_branch[3]));

	(* keep = "true", dont_touch = "true" *) wire [8:0] we_a8_l, we_b8_l;
	(* keep = "true", dont_touch = "true" *) wire [3:0] we_bbox_l;
	(* keep = "true", dont_touch = "true" *) wire [5:0] we_z_l;
	genvar gsp;
	generate
		for (gsp = 0; gsp < 9; gsp = gsp + 1) begin : g_sp_leaves
			localparam integer BR = (gsp < 3) ? 0 : (gsp < 6) ? 1 : 2;
			LUT1 #(.INIT(2'h2)) u_wea (.I0(we_sp_branch[BR]), .O(we_a8_l[gsp]));
			LUT1 #(.INIT(2'h2)) u_web (.I0(we_sp_branch[BR]), .O(we_b8_l[gsp]));
		end
		for (gsp = 0; gsp < 4; gsp = gsp + 1) begin : g_bbox_leaves
			LUT1 #(.INIT(2'h2)) u_webb (.I0(we_sp_branch[0]), .O(we_bbox_l[gsp]));
		end
		for (gsp = 0; gsp < 6; gsp = gsp + 1) begin : g_z_leaves
			LUT1 #(.INIT(2'h2)) u_wez (.I0(we_sp_branch[1]), .O(we_z_l[gsp]));
		end
	endgenerate

	wire [47:0] in_a8_comb [0:2];
	wire [47:0] in_b8_comb [0:2];
	assign in_a8_comb[0] = {{16{s_e0_a_scan_ext}}, sp_tri[0 +: 24], 8'd0};
	assign in_b8_comb[0] = {{16{s_e0_b_scan_ext}}, sp_tri[24 +: 24], 8'd0};
	assign in_a8_comb[1] = {{16{s_e1_a_scan_ext}}, sp_tri[96 +: 24], 8'd0};
	assign in_b8_comb[1] = {{16{s_e1_b_scan_ext}}, sp_tri[120 +: 24], 8'd0};
	assign in_a8_comb[2] = {{16{s_e2_a_scan_ext}}, sp_tri[192 +: 24], 8'd0};
	assign in_b8_comb[2] = {{16{s_e2_b_scan_ext}}, sp_tri[216 +: 24], 8'd0};

	generate
		for (gsp = 0; gsp < 9; gsp = gsp + 1) begin : g_a8_b8_reg
			localparam integer EK = gsp / 3;
			localparam integer SK = gsp % 3;
			always @(posedge clk) begin
				if (we_a8_l[gsp]) a8[EK][SK*16 +: 16] <= in_a8_comb[EK][SK*16 +: 16];
				if (we_b8_l[gsp]) b8[EK][SK*16 +: 16] <= in_b8_comb[EK][SK*16 +: 16];
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (we_bbox_l[0]) bx0 <= sp_tri[303:288];
		if (we_bbox_l[1]) by0 <= sp_tri[319:304];
		if (we_bbox_l[2]) bx1 <= sp_tri[335:320];
		if (we_bbox_l[3]) by1 <= sp_tri[351:336];
	end

	always @(posedge clk) begin
		if (we_z_l[0]) az[15:0]  <= sp_tri[367:352];
		if (we_z_l[1]) az[31:16] <= sp_tri[383:368];
		if (we_z_l[2]) bz[15:0]  <= sp_tri[399:384];
		if (we_z_l[3]) bz[31:16] <= sp_tri[415:400];
		if (we_z_l[4]) cz[15:0]  <= sp_tri[431:416];
		if (we_z_l[5]) cz[31:16] <= sp_tri[447:432];
	end

	wire we_dx_raw = (st_fsm_1 == S_Z) && (zc_1 == 5'd0);
	(* keep = "true", dont_touch = "true" *) wire [7:0] we_dx_leaf;
	genvar gdx;
	generate
		for (gdx = 0; gdx < 8; gdx = gdx + 1) begin : g_we_dx
			LUT1 #(.INIT(2'h2)) u_wdx (.I0(we_dx_raw), .O(we_dx_leaf[gdx]));
		end
	endgenerate
	always @(posedge clk) begin
		if (we_dx_leaf[0]) r_dx0[15:0]  <= dx0_comb[15:0];
		if (we_dx_leaf[1]) r_dx0[16]    <= dx0_comb[16];
		if (we_dx_leaf[2]) r_dy0[15:0]  <= dy0_comb[15:0];
		if (we_dx_leaf[3]) r_dy0[16]    <= dy0_comb[16];
		if (we_dx_leaf[4]) r_dx1[15:0]  <= dx1_comb[15:0];
		if (we_dx_leaf[5]) r_dx1[16]    <= dx1_comb[16];
		if (we_dx_leaf[6]) r_dy1[15:0]  <= dy1_comb[15:0];
		if (we_dx_leaf[7]) r_dy1[16]    <= dy1_comb[16];
	end

	wire we_fdx_raw = (st_fsm_1 == S_Z) && (zc_1 == 5'd1);
	(* keep = "true", dont_touch = "true" *) wire [7:0] we_fdx_leaf;
	generate
		for (gdx = 0; gdx < 8; gdx = gdx + 1) begin : g_we_fdx
			LUT1 #(.INIT(2'h2)) u_wfdx (.I0(we_fdx_raw), .O(we_fdx_leaf[gdx]));
		end
	endgenerate
	always @(posedge clk) begin
		if (we_fdx_leaf[0]) r_fdx0[15:0]  <= f_dx0_comb[15:0];
		if (we_fdx_leaf[1]) r_fdx0[31:16] <= f_dx0_comb[31:16];
		if (we_fdx_leaf[2]) r_fdy0[15:0]  <= f_dy0_comb[15:0];
		if (we_fdx_leaf[3]) r_fdy0[31:16] <= f_dy0_comb[31:16];
		if (we_fdx_leaf[4]) r_fdx1[15:0]  <= f_dx1_comb[15:0];
		if (we_fdx_leaf[5]) r_fdx1[31:16] <= f_dx1_comb[31:16];
		if (we_fdx_leaf[6]) r_fdy1[15:0]  <= f_dy1_comb[15:0];
		if (we_fdx_leaf[7]) r_fdy1[31:16] <= f_dy1_comb[31:16];
	end

	(* keep = "true", dont_touch = "true" *) wire [7:0] we_t1_leaf;
	LUT1 #(.INIT(2'h2)) u_wt0_l (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd6)), .O(we_t1_leaf[0]));
	LUT1 #(.INIT(2'h2)) u_wt0_h (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd6)), .O(we_t1_leaf[1]));
	LUT1 #(.INIT(2'h2)) u_wt1_l (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd7)), .O(we_t1_leaf[2]));
	LUT1 #(.INIT(2'h2)) u_wt1_h (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd7)), .O(we_t1_leaf[3]));
	LUT1 #(.INIT(2'h2)) u_wt2_l (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd8)), .O(we_t1_leaf[4]));
	LUT1 #(.INIT(2'h2)) u_wt2_h (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd8)), .O(we_t1_leaf[5]));
	LUT1 #(.INIT(2'h2)) u_wt3_l (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd9)), .O(we_t1_leaf[6]));
	LUT1 #(.INIT(2'h2)) u_wt3_h (.I0((st_fsm_1 == S_Z) && (zc_2 == 5'd9)), .O(we_t1_leaf[7]));

	always @(posedge clk) begin
		if (we_t1_leaf[0]) t1_0[15:0]  <= fm_r[15:0];
		if (we_t1_leaf[1]) t1_0[31:16] <= fm_r[31:16];
		if (we_t1_leaf[2]) t1_1[15:0]  <= fm_r[15:0];
		if (we_t1_leaf[3]) t1_1[31:16] <= fm_r[31:16];
		if (we_t1_leaf[4]) t1_2[15:0]  <= fm_r[15:0];
		if (we_t1_leaf[5]) t1_2[31:16] <= fm_r[31:16];
		if (we_t1_leaf[6]) t1_3[15:0]  <= fm_r[15:0];
		if (we_t1_leaf[7]) t1_3[31:16] <= fm_r[31:16];
	end

`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) wire [2:0] cond_step_r_b, cond_step_c_b, cond_coarse_e_b, cond_we_er_b, cond_we_ec_b;
	genvar gqb;
	generate
		for (gqb = 0; gqb < 3; gqb = gqb + 1) begin : g_qte_branches
			(* dont_touch = "true" *) wire qte;
			LUT2 #(.INIT(4'h8)) u_qte (.I0(r_tile_row_end), .I1(r_tile_col_end), .O(qte));
			wire cce = (st_fsm_2 == S_TILE_WAIT && ctv_edge) ||
			           (st_fsm_2 == S_STEP && qte && !cur_last_tile && ctv_edge);
			wire er0_b = (st_fsm_0 == S_SEQ && COARSE_SCAN == 0);
			wire cstep = (st_fsm_0 == S_STEP && !qte);
			wire cstep_r = cstep && r_tile_row_end;
			wire cstep_c = cstep && !r_tile_row_end;

			assign cond_coarse_e_b[gqb] = cce;
			assign cond_step_r_b[gqb] = cstep_r;
			assign cond_step_c_b[gqb] = cstep_c;
			assign cond_we_er_b[gqb] = er0_b || cce || cstep_r;
			assign cond_we_ec_b[gqb] = er0_b || cce || cstep;
		end
	endgenerate
`else
	wire q_tile_end = (r_tile_row_end && r_tile_col_end);
	wire cond_coarse_e = (st_fsm_2 == S_TILE_WAIT && coarse_tile_valid) ||
	                     (st_fsm_2 == S_STEP && q_tile_end && !cur_last_tile && coarse_tile_valid);
	wire cond_er0 = (st_fsm_0 == S_IDLE && sp_val_fsm) || (st_fsm_0 == S_SEQ && COARSE_SCAN == 0);
	wire cond_step = (st_fsm_0 == S_STEP && !q_tile_end);
	wire cond_step_r = cond_step && r_tile_row_end;
	wire cond_step_c = cond_step && !r_tile_row_end;

	wire cond_we_er = cond_er0 || cond_coarse_e || cond_step_r;
	wire cond_we_ec = cond_er0 || cond_coarse_e || cond_step;
`endif

	(* keep = "true", dont_touch = "true" *) wire [8:0] sel_step_r_er_l, sel_coarse_er_l;
	(* keep = "true", dont_touch = "true" *) wire [8:0] sel_step_c_ec_l, sel_step_r_ec_l, sel_coarse_ec_l;
	(* keep = "true", dont_touch = "true" *) wire [8:0] we_er_leaf;
	(* keep = "true", dont_touch = "true" *) wire [8:0] we_ec_leaf;
	(* keep = "true", dont_touch = "true" *) wire [8:0] we_ab8_leaf;
	genvar gsk;
	generate
		for (gsk = 0; gsk < 9; gsk = gsk + 1) begin : g_slice_er_ec
			localparam integer EK = gsk / 3;
			localparam integer SK = gsk % 3;

`ifdef SYNTH_KINTEX7
			LUT1 #(.INIT(2'h2)) u_srer  (.I0(cond_step_r_b[EK]), .O(sel_step_r_er_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scer  (.I0(cond_coarse_e_b[EK]), .O(sel_coarse_er_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scec  (.I0(cond_step_c_b[EK]), .O(sel_step_c_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_srec  (.I0(cond_step_r_b[EK]), .O(sel_step_r_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scoe  (.I0(cond_coarse_e_b[EK]), .O(sel_coarse_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_wer   (.I0(cond_we_er_b[EK]), .O(we_er_leaf[gsk]));
			LUT1 #(.INIT(2'h2)) u_wec   (.I0(cond_we_ec_b[EK]), .O(we_ec_leaf[gsk]));
`else
			LUT1 #(.INIT(2'h2)) u_srer  (.I0(cond_step_r), .O(sel_step_r_er_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scer  (.I0(cond_coarse_e), .O(sel_coarse_er_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scec  (.I0(cond_step_c), .O(sel_step_c_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_srec  (.I0(cond_step_r), .O(sel_step_r_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_scoe  (.I0(cond_coarse_e), .O(sel_coarse_ec_l[gsk]));
			LUT1 #(.INIT(2'h2)) u_wer   (.I0(cond_we_er), .O(we_er_leaf[gsk]));
			LUT1 #(.INIT(2'h2)) u_wec   (.I0(cond_we_ec), .O(we_ec_leaf[gsk]));
`endif
			LUT1 #(.INIT(2'h2)) u_wab8  (.I0(st_fsm_0 == S_SEQ), .O(we_ab8_leaf[gsk]));

			wire [15:0] in_coarse_e = (EK == 0) ? coarse_tile_e0[SK*16 +: 16] :
			                          (EK == 1) ? coarse_tile_e1[SK*16 +: 16] :
			                                      coarse_tile_e2[SK*16 +: 16];
			wire [15:0] in_er0 = er0[EK][SK*16 +: 16];
			wire [15:0] in_er_n = er_n[EK][SK*16 +: 16];
			wire [15:0] in_ec_n = ec_n[EK][SK*16 +: 16];

			wire [15:0] next_er = sel_step_r_er_l[gsk] ? in_er_n : sel_coarse_er_l[gsk] ? in_coarse_e : in_er0;
			wire [15:0] next_ec = sel_step_c_ec_l[gsk] ? in_ec_n : sel_step_r_ec_l[gsk] ? in_er_n : sel_coarse_ec_l[gsk] ? in_coarse_e : in_er0;

			always @(posedge clk) begin
				if (we_er_leaf[gsk])
					er[EK][SK*16 +: 16] <= next_er;
				if (we_ec_leaf[gsk])
					ec[EK][SK*16 +: 16] <= next_ec;
				if (we_ab8_leaf[gsk])
					ab8[EK][SK*16 +: 16] <= ab8_comb[EK][SK*16 +: 16];
			end
		end
	endgenerate

	wire we_resamp_raw = (st_fsm_7 == S_IDLE && sp_val_fsm) || (st_fsm_7 == S_SAMP);
	(* keep = "true", dont_touch = "true" *) wire [2:0] we_resamp_leaf;
	genvar gres;
	generate
		for (gres = 0; gres < 3; gres = gres + 1) begin : g_we_resamp
			LUT1 #(.INIT(2'h2)) u_wres (.I0(we_resamp_raw), .O(we_resamp_leaf[gres]));
			always @(posedge clk) begin
				if (we_resamp_leaf[gres])
					r_esamp_sign[gres*16 +: 16] <= (st_fsm_7 == S_IDLE) ? 16'd0 : esamp_sign[gres*16 +: 16];
			end
		end
	endgenerate
`endif

`ifdef SYNTH_KINTEX7
	assign sp_ready = (st_fsm_7 == S_IDLE);
	assign sq_req = (st_fsm_7 == S_SEQ && !wm);
	assign fq_valid = (st_fsm_7 == S_FQ);
	assign fq_xy = {qy, qx};
	assign fq_scov = fend ? 16'd0 : ms4_misc ? scov_reg :
		{3'd0, cov_reg_scov[3] & ~kill[0], 3'd0, cov_reg_scov[2] & ~kill[0], 3'd0, cov_reg_scov[1] & ~kill[0], 3'd0, cov_reg_scov[0] & ~kill[0]};
	assign fq_ccov = fend ? 4'd0 : ms4_misc ? ccov_reg : cov_reg;
	assign fq_end = fend;
	assign busy = (st_fsm_7 != S_IDLE);
`else
	assign sp_ready = (st == S_IDLE);
	assign sq_req = (st == S_SEQ && !wm);
	assign fq_valid = (st == S_FQ);
	assign fq_xy = {qy, qx};
	assign fq_scov = fend ? 16'd0 : ms4_misc ? scov_reg :
		{3'd0, cov_reg[3] & ~kill[0], 3'd0, cov_reg[2] & ~kill[0], 3'd0, cov_reg[1] & ~kill[0], 3'd0, cov_reg[0] & ~kill[0]};
	assign fq_ccov = fend ? 4'd0 : ms4_misc ? ccov_reg : cov_reg;
	assign fq_end = fend;
	assign busy = (st != S_IDLE);
`endif

	/* Dedicated scov_reg process to isolate 16-bit register fanout */
	always @(posedge clk) begin
		if (rst_n_inv) begin
			scov_reg <= 16'd0;
		end else if (st_fsm_6 == S_EVAL) begin
			scov_reg <= cur_scov;
		end
	end

	always @(posedge clk) begin
		pt_free <= 1'b0;
		if (rst_n_inv) begin
			`SET_ST(S_IDLE);
			dx_valid <= 1'b0;
			coarse_tri_valid <= 1'b0;
			coarse_tile_ready <= 1'b0;
`ifndef SYNTH_KINTEX7
			cur_tx <= 16'd0;
			cur_ty <= 16'd0;
			cur_trivial <= 1'b0;
			cur_last_tile <= 1'b0;
`endif
			ccov_reg <= 4'd0;
			cov_reg <= 4'd0;
`ifdef SYNTH_KINTEX7
			cov_reg_scov <= 4'd0;
`endif
			fend <= 1'b0;
			pend <= 1'b0;
			fi <= 2'd0;
			`SET_ZC(5'd0);
			`SET_ZL(2'd0);
			`SET_BZA(1'b0);
			`SET_BZB(1'b0);
			r_fm_v <= 1'b0;
			r_fa_v <= 1'b0;
			zmask <= 4'd0;
			p_mask <= 4'd0;
`ifndef SYNTH_KINTEX7
			seq <= 16'd0;
`endif
			dx_seq <= 16'd0;
			dx_mask <= 4'd0;
			dx_last <= 1'b0;
`ifndef SYNTH_KINTEX7
			r_esamp_sign <= 48'd0;
`endif
			r_lve_sign <= 12'd0;
			r_inb <= 4'd0;
			r_tile_row_end <= 1'b0;
			r_tile_col_end <= 1'b0;
`ifdef SYNTH_KINTEX7
		end else case (st_fsm_main)
`else
		end else case (st)
`endif
		S_IDLE: begin
			coarse_tile_ready <= 1'b0;
			r_fm_v <= 1'b0;
			`SET_BZA(1'b0);
			`SET_BZB(1'b0);
			if (sp_val_qx) begin
				qx <= {sp_tri[303:289], 1'b0};
			end
			if (sp_val_qy) begin
				qy <= {sp_tri[319:305], 1'b0};
			end
`ifdef SYNTH_KINTEX7
			if (we_ent_lo) ent[11:0] <= sp_tri[747:736];
			if (we_ent_hi) ent[23:12] <= sp_tri[759:748];
`endif
			if (sp_val_ctrl) begin
`ifndef SYNTH_KINTEX7
				a8[0] <= {{16{s_e0_a_scan}}, sp_tri[0 +: 24], 8'd0};
				b8[0] <= {{16{s_e0_b_scan}}, sp_tri[24 +: 24], 8'd0};
				er[0] <= er0[0];
				ec[0] <= er0[0];
				a8[1] <= {{16{s_e1_a_scan}}, sp_tri[96 +: 24], 8'd0};
				b8[1] <= {{16{s_e1_b_scan}}, sp_tri[120 +: 24], 8'd0};
				er[1] <= er0[1];
				ec[1] <= er0[1];
				a8[2] <= {{16{s_e2_a_scan}}, sp_tri[192 +: 24], 8'd0};
				b8[2] <= {{16{s_e2_b_scan}}, sp_tri[216 +: 24], 8'd0};
				er[2] <= er0[2];
				ec[2] <= er0[2];
				bx0 <= sp_tri[303:288];
				by0 <= sp_tri[319:304];
				bx1 <= sp_tri[335:320];
				by1 <= sp_tri[351:336];
				qx <= {sp_tri[303:289], 1'b0};
				qy <= {sp_tri[319:305], 1'b0};
				{cz, bz, az} <= sp_tri[447:352];
				ent <= sp_tri[759:736];
`endif
				fl <= sp_tri[762:760];
				raw <= sp_tri[764];
				wm <= (HAS_SU != 0) && !sp_tri[764];
				fend <= 1'b0;
				pend <= 1'b0;
				fi <= 2'd0;
				coarse_tri_valid <= (COARSE_SCAN != 0);
				if (sp_tri[335:320] > sp_tri[303:288] && sp_tri[351:336] > sp_tri[319:304]) begin
					`SET_ST(S_SEQ);
				end else begin
					coarse_tri_valid <= 1'b0;
					`SET_ST(S_FREE);
				end
			end
		end

		S_SEQ: begin
			coarse_tri_valid <= 1'b0;
			coarse_tile_ready <= 1'b0;
`ifndef SYNTH_KINTEX7
			seq <= sq_seq;
			ab8[0] <= ab8_comb[0];
			ab8[1] <= ab8_comb[1];
			ab8[2] <= ab8_comb[2];
`endif
			if (COARSE_SCAN != 0) begin
				`SET_ST(S_TILE_WAIT);
			end else begin
				/* Direct bounding box traversal bypassing coarse scan */
`ifndef SYNTH_KINTEX7
				cur_tx <= {bx0[15:1], 1'b0};
				cur_ty <= {by0[15:1], 1'b0};
				cur_trivial <= 1'b0;
				cur_last_tile <= 1'b1;
`endif
				qx <= {bx0[15:1], 1'b0};
				qy <= {by0[15:1], 1'b0};
`ifndef SYNTH_KINTEX7
				er[0] <= er0[0]; ec[0] <= er0[0];
				er[1] <= er0[1]; ec[1] <= er0[1];
				er[2] <= er0[2]; ec[2] <= er0[2];
`endif
				`SET_ST(S_WALK);
			end
		end

		S_TILE_WAIT: begin
			coarse_tile_ready <= 1'b0;
			if (ctv_fsm) begin
				coarse_tile_ready <= 1'b1;
`ifndef SYNTH_KINTEX7
				cur_tx <= coarse_tile_x;
				cur_ty <= coarse_tile_y;
				cur_trivial <= coarse_tile_trivial;
				cur_last_tile <= coarse_tile_last;
`endif
				qx <= coarse_tile_x;
				qy <= coarse_tile_y;
`ifndef SYNTH_KINTEX7
				er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
				er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
				er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
`endif
				`SET_ST(S_WALK);
			end else if (!coarse_busy) begin
				/* Traversal of all tiles complete */
				fend <= wm;
				`SET_ST(wm ? S_FQ : S_LAST);
			end
		end

		S_WALK: begin
			coarse_tile_ready <= 1'b0;
			r_inb <= inb_comb;
			r_tile_row_end <= tile_row_end;
			r_tile_col_end <= tile_col_end;
			`SET_ST(S_SAMP);
		end

		S_SAMP: begin
`ifndef SYNTH_KINTEX7
			r_esamp_sign <= esamp_sign;
`endif
			for (k = 0; k < 12; k = k + 1)
				r_lve_sign[k] <= r_lve[48 * k + 47];
			`SET_ST(S_EVAL);
		end

		S_EVAL: begin
			`SET_ZC(5'd0);
			ccov_reg <= cur_ccov;
			cov_reg  <= cur_cov;
`ifdef SYNTH_KINTEX7
			cov_reg_scov <= cur_cov;
`endif
			if (!w_empty && wm) begin
				`SET_ST(S_FQ);
			end else if (!w_empty) begin
				zmask <= cur_cov;
				`SET_ST(S_Z);
			end else begin
				`SET_ST(S_STEP);
			end
		end

		S_STEP: begin
			if (r_tile_row_end && r_tile_col_end) begin
				/* End of quads in this coarse tile */
				if (cur_last_tile) begin
					fend <= wm;
					`SET_ST(wm ? S_FQ : S_LAST);
				end else if (ctv_fsm) begin
					/* Immediate switch to next pre-fetched tile */
					coarse_tile_ready <= 1'b1;
`ifndef SYNTH_KINTEX7
					cur_tx <= coarse_tile_x;
					cur_ty <= coarse_tile_y;
					cur_trivial <= coarse_tile_trivial;
					cur_last_tile <= coarse_tile_last;
`endif
					qx <= coarse_tile_x;
					qy <= coarse_tile_y;
`ifndef SYNTH_KINTEX7
					er[0] <= coarse_tile_e0; ec[0] <= coarse_tile_e0;
					er[1] <= coarse_tile_e1; ec[1] <= coarse_tile_e1;
					er[2] <= coarse_tile_e2; ec[2] <= coarse_tile_e2;
`endif
					`SET_ST(S_WALK);
				end else begin
					`SET_ST(S_TILE_WAIT);
				end
			end else begin
				/* Step to next quad within tile */
				if (r_tile_row_end) begin
					qx <= cur_tx;
					qy <= qy2[15:0];
`ifndef SYNTH_KINTEX7
					for (k = 0; k < 3; k = k + 1) begin
						er[k] <= er_n[k];
						ec[k] <= er_n[k];
					end
`endif
				end else begin
					qx <= qx2[15:0];
`ifndef SYNTH_KINTEX7
					for (k = 0; k < 3; k = k + 1)
						ec[k] <= ec_n[k];
`endif
				end
				`SET_ST(S_WALK);
			end
		end

		S_FQ: begin
			coarse_tile_ready <= 1'b0;
			if (fq_ready) begin
				if (fend) begin
					`SET_ST(S_FREE);
				end else begin
					`SET_ST(S_STEP);
				end
			end
		end

		S_Z: begin
			`SET_ZC(zc1);
			if (zc == 5'd0) begin
`ifndef SYNTH_KINTEX7
				zv <= 128'd0;
				r_dx0 <= dx0_comb;
				r_dy0 <= dy0_comb;
				r_dx1 <= dx1_comb;
				r_dy1 <= dy1_comb;
`endif
			end
			if (zc == 5'd1) begin
`ifndef SYNTH_KINTEX7
				r_fdx0 <= f_dx0_comb;
				r_fdy0 <= f_dy0_comb;
				r_fdx1 <= f_dx1_comb;
				r_fdy1 <= f_dy1_comb;
`endif
				`SET_ZL(2'd0);
				`SET_BZA(1'b0);
				`SET_BZB(1'b0);
				r_fm_v <= 1'b1;
			end else if (zc >= 5'd2) begin
				`SET_ZL(r_zl_next);
			end
`ifdef SYNTH_KINTEX7
			if (zc_1 == 5'd5) begin
				`SET_BZA(1'b1);
				`SET_BZB(1'b1);
			end
			if (zc_1 == 5'd9) r_fm_v <= 1'b0;
`else
			if (zc == 5'd5) begin
				`SET_BZA(1'b1);
				`SET_BZB(1'b1);
			end
			if (zc == 5'd9) r_fm_v <= 1'b0;
`endif
`ifndef SYNTH_KINTEX7
			if (zc == 5'd6) t1_0 <= fm_r;
			if (zc == 5'd7) t1_1 <= fm_r;
			if (zc == 5'd8) t1_2 <= fm_r;
			if (zc == 5'd9) t1_3 <= fm_r;
`endif

`ifdef SYNTH_KINTEX7
			if (zc_0 == 5'd10 || zc_0 == 5'd11 || zc_0 == 5'd12 || zc_0 == 5'd13 || (zc_0 >= 5'd15 && zc_0 <= 5'd18))
				r_fa_v <= 1'b1;
			if (zc_0 == 5'd14 || zc_0 == 5'd19)
				r_fa_v <= 1'b0;
`else
			if (zc == 5'd10) begin r_fa_v <= 1'b1; r_fa_a_lo <= t1_0[15:0]; r_fa_a_hi <= t1_0[31:16]; r_fa_b_lo <= fm_r[15:0]; r_fa_b_hi <= fm_r[31:16]; end
			if (zc == 5'd11) begin r_fa_v <= 1'b1; r_fa_a_lo <= t1_1[15:0]; r_fa_a_hi <= t1_1[31:16]; r_fa_b_lo <= fm_r[15:0]; r_fa_b_hi <= fm_r[31:16]; end
			if (zc == 5'd12) begin r_fa_v <= 1'b1; r_fa_a_lo <= t1_2[15:0]; r_fa_a_hi <= t1_2[31:16]; r_fa_b_lo <= fm_r[15:0]; r_fa_b_hi <= fm_r[31:16]; end
			if (zc == 5'd13) begin r_fa_v <= 1'b1; r_fa_a_lo <= t1_3[15:0]; r_fa_a_hi <= t1_3[31:16]; r_fa_b_lo <= fm_r[15:0]; r_fa_b_hi <= fm_r[31:16]; end
			if (zc == 5'd14) begin r_fa_v <= 1'b0; end

			if (zc == 5'd15 || zc == 5'd16 || zc == 5'd17 || zc == 5'd18) begin
				r_fa_v <= 1'b1;
				r_fa_a_lo <= fa_r[15:0];
				r_fa_a_hi <= fa_r[31:16];
				r_fa_b_lo <= cz[15:0];
				r_fa_b_hi <= cz[31:16];
			end
			if (zc == 5'd19) begin r_fa_v <= 1'b0; end
`endif

`ifndef SYNTH_KINTEX7
			if (zc == 5'd20 && zmask[0]) zv[31:0] <= zcl;
			if (zc == 5'd21 && zmask[1]) zv[63:32] <= zcl;
			if (zc == 5'd22 && zmask[2]) zv[95:64] <= zcl;
			if (zc == 5'd23 && zmask[3]) zv[127:96] <= zcl;
`endif
`ifdef SYNTH_KINTEX7
			if (zc_0 == 5'd23)
`else
			if (zc == 5'd23)
`endif
				`SET_ST(S_EMIT);
		end

		S_EMIT: begin
			if (pend && !(dx_valid && dx_ready)) begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_mask <= p_mask;
				dx_last <= 1'b0;
`ifndef SYNTH_KINTEX7
				dx_xy <= p_xy;
				dx_depth <= p_z;
`endif
			end else begin
				dx_valid <= 1'b0;
				pend <= 1'b1;
				p_mask <= zmask;
				`SET_ST(S_STEP);
`ifndef SYNTH_KINTEX7
				p_xy <= {qy, qx};
				p_z <= zv;
`endif
			end
		end

		S_LAST: begin
			if (dx_valid && dx_ready) begin
				dx_valid <= 1'b0;
				`SET_ST(S_FREE);
			end else begin
				dx_valid <= 1'b1;
				dx_seq <= seq;
				dx_mask <= pend ? p_mask : 4'd0;
				dx_last <= 1'b1;
`ifndef SYNTH_KINTEX7
				dx_xy <= pend ? p_xy : {by0[15:1], 1'b0, bx0[15:1], 1'b0};
				dx_depth <= pend ? p_z : 128'd0;
`endif
			end
		end

		default: if (!f_busy) begin	/* S_FREE */
			fi <= fi1;
			if (fi < 2'd3 && fl[fi] && !raw) begin
				pt_free <= 1'b1;
				pt_free_idx <= ent[8 * fi +: 8];
			end
			if (fi == 2'd3)
				`SET_ST(S_IDLE);
		end
		endcase
	end

	wire unused_ok = &{1'b0, st_wdata[31:4], sp_last, fm_o, fa_o,
		sp_tri[767:765], sp_tri[735:448], qx1[16], qy1[16], qx2[16], qy2[16],
		HAS_SU != 0, coarse_tri_ready, cur_last_tile, eb_cov_unused,
		esamp_carry_unused, esamp_unused, lve_carry_unused, qstep_carry_unused, tend_carry_unused,
		dxy_carry_unused, r_zl_co_unused, ab8_carry_unused,
		hiz_cull, hiz_rd_zmax, coarse_tri_valid, coarse_tile_ready, cur_ty, cov_op, cov_oq};
endmodule

`default_nettype wire
