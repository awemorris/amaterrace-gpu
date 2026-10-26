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
 * Integrated 6-stage stream pipeline with registered skid buffers (am_skid)
 * between each stage to break long timing paths and ensure high-throughput
 * flow control with zero bubbles.
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
	/* Pipeline Stage 0 -> Stage 1: Clip to Setup */
	wire cl_raw_valid, cl_raw_ready, cl_raw_last;
	wire [701:0] cl_raw_tri;
	wire cl_valid, cl_ready, cl_last;
	wire [701:0] cl_tri;

	am_skid #(.WIDTH(703)) u_skid_clip (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(cl_raw_valid),
		.in_ready(cl_raw_ready),
		.in_data({cl_raw_last, cl_raw_tri}),
		.out_valid(cl_valid),
		.out_ready(cl_ready),
		.out_data({cl_last, cl_tri})
	);

	/* Pipeline Stage 1 -> Stage 2: Setup to Scan & Frag (Direct for single-triangle synchronization) */
	wire sp_valid, sp_ready, sp_last;
	wire [767:0] sp_tri;

	/* Pipeline Stage 3 -> Stage 4/5: Scan to Frag */
	wire fq_raw_valid, fq_raw_ready, fq_raw_end;
	wire [31:0] fq_raw_xy;
	wire [15:0] fq_raw_scov;
	wire [3:0] fq_raw_ccov;
	wire fq_valid, fq_ready, fq_end;
	wire [31:0] fq_xy;
	wire [15:0] fq_scov;
	wire [3:0] fq_ccov;

	am_skid #(.WIDTH(53)) u_skid_scan (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(fq_raw_valid),
		.in_ready(fq_raw_ready),
		.in_data({fq_raw_end, fq_raw_ccov, fq_raw_scov, fq_raw_xy}),
		.out_valid(fq_valid),
		.out_ready(fq_ready),
		.out_data({fq_end, fq_ccov, fq_scov, fq_xy})
	);

	/* Direct quads pipeline to ROP (HAS_SU == 0) */
	wire dx_raw_valid, dx_raw_ready, dx_raw_last;
	wire [15:0] dx_raw_seq;
	wire [31:0] dx_raw_xy;
	wire [3:0] dx_raw_mask;
	wire [127:0] dx_raw_depth;

	am_skid #(.WIDTH(181)) u_skid_dx (
		.clk(clk),
		.rst_n(rst_n),
		.in_valid(dx_raw_valid),
		.in_ready(dx_raw_ready),
		.in_data({dx_raw_last, dx_raw_depth, dx_raw_mask, dx_raw_xy, dx_raw_seq}),
		.out_valid(dx_valid),
		.out_ready(dx_ready),
		.out_data({dx_last, dx_depth, dx_mask, dx_xy, dx_seq})
	);

	wire c_pt_rd, f_pt_rd, f_pt_busy;
	wire [7:0] c_pt_idx, f_pt_idx;
	wire [6:0] c_pt_word, f_pt_word;
	wire s_sq_req, f_sq_req, sq_req;
	wire [15:0] sq_seq;
	wire clip_busy, setup_busy, scan_busy, frag_busy;

	/* One PT read port: atg_rx_frag's copy has priority, the clip waits while pt_busy. */
	assign pt_rd = c_pt_rd || f_pt_rd;
	assign pt_idx = f_pt_rd ? f_pt_idx : c_pt_idx;
	assign pt_word = f_pt_rd ? f_pt_word : c_pt_word;
	/* Sequence numbers: the scan's (direct quads) and the warps' never overlap. */
	assign sq_req = s_sq_req || f_sq_req;

	/* Clip unit (Stage 0: Prune & Cull) */
	atg_rx_clip clip (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.raw_kick(raw_kick),
		.prim_valid(prim_valid), .prim_ready(prim_ready), .prim_vtx(prim_vtx),
		.prim_free(prim_free), .prim_last(prim_last),
		.pt_rd(c_pt_rd), .pt_idx(c_pt_idx), .pt_word(c_pt_word), .pt_rdata(pt_rdata),
		.pt_busy(f_pt_busy),
		.cl_valid(cl_raw_valid), .cl_ready(cl_raw_ready), .cl_tri(cl_raw_tri), .cl_last(cl_raw_last),
		.busy(clip_busy)
	);

	/* Setup unit (Stage 1: Stream Setup) */
	atg_rx_setup setup (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cl_valid(cl_valid), .cl_ready(cl_ready), .cl_tri(cl_tri), .cl_last(cl_last),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri), .sp_last(sp_last),
		.busy(setup_busy)
	);

	/* Scan unit (Stage 2: Coarse Raster & Stage 3: Fine Raster / MSAA 4x) */
	wire frag_f_busy = frag_busy || fq_valid;
	atg_rx_scan #(.HAS_SU(HAS_SU)) scan (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_tri(sp_tri), .sp_last(sp_last),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx),
		.fq_valid(fq_raw_valid), .fq_ready(fq_raw_ready), .fq_xy(fq_raw_xy),
		.fq_scov(fq_raw_scov), .fq_ccov(fq_raw_ccov), .fq_end(fq_raw_end),
		.f_busy(frag_f_busy),
		.dx_valid(dx_raw_valid), .dx_ready(dx_raw_ready), .dx_seq(dx_raw_seq), .dx_xy(dx_raw_xy),
		.dx_mask(dx_raw_mask), .dx_depth(dx_raw_depth), .dx_last(dx_raw_last),
		.sq_req(s_sq_req), .sq_seq(sq_seq), .busy(scan_busy)
	);

	/* Fragment packing & warp dispatch unit (Stage 4: DDA & Stage 5: Warp Pack & Fire) */
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

	/* Sequence ordering unit */
	atg_rx_order order (
		.clk(clk), .rst_n(rst_n), .sq_req(sq_req), .sq_seq(sq_seq),
		.ord_valid(ord_valid), .ord_seq(ord_seq)
	);

	wire skid_busy = cl_valid || fq_valid || (dx_valid && !HAS_SU);
	assign busy = clip_busy || setup_busy || scan_busy || frag_busy || skid_busy;
	assign fsm = {frag_busy, scan_busy, setup_busy, clip_busy};
endmodule

`default_nettype wire
