/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx: The rasterizer (design §3.8): clip, setup, quad scan into
 * fragment warps (or direct quads), sequence numbers for the ROP order.
 *
 * Wiring of its children; see spec/gpu/rx/atg_rx.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx #(
	parameter HAS_SU = 1	/* Fragment warps to an SU (0: DEBUG_COLOR quads to the ROP) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire raw_kick,
	output wire busy,
	output wire [3:0] fsm,
	/* Primitives to the RX */
	input wire prim_valid,
	output wire prim_ready,
	input wire [25:0] prim_vtx,
	input wire [2:0] prim_free,
	input wire prim_last,
	/* PT of SU 0 (atg_su pt_*) */
	output wire pt_rd,
	output wire [7:0] pt_idx,
	output wire [6:0] pt_word,
	input wire [31:0] pt_rdata,
	output wire pt_free,
	output wire [7:0] pt_free_idx,
	/* Fragment warps to the SU (atg_su fl_*) */
	output wire fl_req,
	input wire fl_gnt,
	output wire fl_we,
	output wire [5:0] fl_reg,
	output wire [4:0] fl_lane,
	output wire [31:0] fl_data,
	output wire fl_pw_we,
	output wire [11:0] fl_pw_addr,
	output wire [31:0] fl_pw_data,
	output wire fl_go,
	output wire [31:0] fl_mask,
	output wire [63:0] fl_info,
	/* Direct fragments to the ROP (no SU: DEBUG_COLOR) */
	output wire dx_valid,
	input wire dx_ready,
	output wire [15:0] dx_seq,
	output wire [31:0] dx_xy,
	output wire [3:0] dx_mask,
	output wire [127:0] dx_depth,
	output wire dx_last,
	/* Sequence numbers to the ROP */
	output wire ord_valid,
	output wire [15:0] ord_seq
);
	wire cl_valid, cl_ready, cl_last;
	wire [701:0] cl_tri;
	wire sp_valid, sp_ready, sp_last;
	wire [767:0] sp_tri;
	wire c_pt_rd, f_pt_rd, f_pt_busy;
	wire [7:0] c_pt_idx, f_pt_idx;
	wire [6:0] c_pt_word, f_pt_word;
	wire s_sq_req, f_sq_req, sq_req;
	wire [15:0] sq_seq;
	wire clip_busy, setup_busy, scan_busy, frag_busy;
	wire fq_valid, fq_ready, fq_end;
	wire [31:0] fq_xy;
	wire [15:0] fq_scov;
	wire [3:0] fq_ccov;

	/* One PT read port: atg_rx_frag's copy has priority, the clip waits while pt_busy. */
	assign pt_rd = c_pt_rd || f_pt_rd;
	assign pt_idx = f_pt_rd ? f_pt_idx : c_pt_idx;
	assign pt_word = f_pt_rd ? f_pt_word : c_pt_word;
	/* Sequence numbers: the scan's (direct quads) and the warps' never overlap. */
	assign sq_req = s_sq_req || f_sq_req;

	atg_rx_clip clip (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.raw_kick(raw_kick),
		.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
		.prim_free(prim_free), .prim_last(prim_last),
		.pt_rd(c_pt_rd), .pt_idx(c_pt_idx), .pt_word(c_pt_word), .pt_rdata(pt_rdata),
		.pt_busy(f_pt_busy),
		.cl_valid(cl_valid), .cl_ready(cl_ready), .cl_tri(cl_tri), .cl_last(cl_last),
		.busy(clip_busy)
	);

	atg_rx_setup setup (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cl_valid(cl_valid), .cl_ready(cl_ready), .cl_tri(cl_tri), .cl_last(cl_last),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri), .sp_last(sp_last),
		.busy(setup_busy)
	);

	atg_rx_scan #(.HAS_SU(HAS_SU)) scan (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri), .sp_last(sp_last),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx),
		.fq_valid(fq_valid), .fq_ready(fq_ready), .fq_xy(fq_xy), .fq_scov(fq_scov), .fq_ccov(fq_ccov),
		.fq_end(fq_end), .f_busy(frag_busy),
		.dx_valid(dx_valid), .dx_ready(dx_ready), .dx_seq(dx_seq), .dx_xy(dx_xy),
		.dx_mask(dx_mask), .dx_depth(dx_depth), .dx_last(dx_last),
		.sq_req(s_sq_req), .sq_seq(sq_seq), .busy(scan_busy)
	);

	atg_rx_frag frag (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.t_load(sp_valid && sp_ready), .t_tri(sp_tri),
		.fq_valid(fq_valid), .fq_ready(fq_ready), .fq_xy(fq_xy), .fq_scov(fq_scov), .fq_ccov(fq_ccov),
		.fq_end(fq_end), .busy(frag_busy),
		.pt_rd(f_pt_rd), .pt_idx(f_pt_idx), .pt_word(f_pt_word), .pt_rdata(pt_rdata),
		.pt_busy(f_pt_busy),
		.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_we(fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane),
		.fl_data(fl_data), .fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data),
		.fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.sq_req(f_sq_req), .sq_seq(sq_seq)
	);

	atg_rx_order order (
		.clk(clk), .rst_n(rst_n), .sq_req(sq_req), .sq_seq(sq_seq),
		.ord_valid(ord_valid), .ord_seq(ord_seq)
	);

	assign busy = clip_busy || setup_busy || scan_busy || frag_busy;
	assign fsm = {frag_busy, scan_busy, setup_busy, clip_busy};
endmodule

`default_nettype wire
