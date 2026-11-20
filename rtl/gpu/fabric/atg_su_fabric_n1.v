/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fabric_n1: Explicit 2D physical fabric for N = 1 SU (1x1 Tile).
 * Matches docs/svg/floorplan/floorplan_n1.svg:
 *
 *   [ SU 0 (rt2: D$+I$) ]
 *           |  (0 atg_rep hops)
 *           v
 *       Trunk 0  ---> Spine MMU / Root Fat-Tree
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fabric_n1 #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter NREGS = 32,
	parameter SB_ENTRIES = 4,
	parameter SBE_W = 2,
	parameter FRAG_RESERVE = 1,
	parameter PACKED = 0,
	parameter PK_SHARED = 0,
	parameter SUBGROUP = 0,
	parameter HAS_SA = 0,
	parameter MS4 = 0,
	parameter HAS_MESH = 0,
	parameter LDS_BYTES = 4096,
	parameter PT_ENTRIES = 64,
	parameter VARY_WORDS = 16,
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter MRT_COUNT = 1,
	parameter DUAL_SOURCE = 0,
	parameter SHARED_PT = 0,
	parameter HAS_GFX = 1,
	parameter HAS_TU = 1,
	parameter HAS_ROP = 1,
	parameter SU_RW = 1,
	parameter FW = LINE_BYTES * 8,
	parameter RFW = LINE_BYTES * 8 + 10 + SU_RW,
	parameter PT_W = 1 + 3 + GRP_W + 7 + NPHYS + NPHYS * 32
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	/* Control broadcast */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire cs_kick,
	input wire cs_mesh,
	input wire lc_kick,
	input wire [3:0] inv,
	input wire scrub,
	input wire [3:0] session_id,

	/* Vertex warp dist */
	input wire vl_req,
	output wire vl_gnt,
	output wire [7:0] vl_ptbase,
	output wire vl_avail,
	input wire vl_we,
	input wire [5:0] vl_reg,
	input wire [4:0] vl_lane,
	input wire [31:0] vl_data,
	input wire vl_go,
	input wire [31:0] vl_mask,
	input wire [7:0] vl_go_ptbase,

	/* Fragment warp dist */
	input wire fl_req,
	output wire fl_gnt,
	output wire fl_avail,
	input wire fl_we,
	input wire [5:0] fl_reg,
	input wire [4:0] fl_lane,
	input wire [31:0] fl_data,
	input wire fl_pw_we,
	input wire [11:0] fl_pw_addr,
	input wire [31:0] fl_pw_data,
	input wire fl_go,
	input wire [31:0] fl_mask,
	input wire [63:0] fl_info,

	/* Local PT (SHARED_PT == 0) */
	input wire pt_rd,
	input wire [7:0] pt_idx,
	input wire [6:0] pt_word,
	output wire [31:0] pt_rdata,
	input wire pt_free,
	input wire [7:0] pt_free_idx,
	output wire [7:0] pt_done,

	/* Shared Spine PT export (SHARED_PT != 0) */
	output wire pt_exp_valid,
	input wire pt_exp_ready,
	output wire [PT_W-1:0] pt_exp_packed,

	/* TU */
	output wire tx_valid,
	input wire tx_ready,
	output wire [7:0] tx_op,
	output wire [3:0] tx_slot,
	output wire [3:0] tx_samp_slot,
	output wire tx_vs,
	output wire [3:0] tx_mask,
	output wire [639:0] tx_coord,
	output wire [11:0] tx_off,
	output wire [15:0] tx_tag,
	output wire tx_last,
	input wire tr_valid,
	output wire tr_ready,
	input wire [15:0] tr_tag,
	input wire [511:0] tr_data,
	input wire tr_last,

	/* ROP */
	output wire ex_valid,
	input wire ex_ready,
	output wire [15:0] ex_seq,
	output wire [31:0] ex_xy,
	output wire [3:0] ex_mask,
	output wire [511:0] ex_color,
	output wire [511:0] ex_color1,
	output wire ex_has_src1,
	output wire [127:0] ex_depth,
	output wire ex_last,
	output wire [154:0] ex_aux,
	input wire [15:0] ex_next,

	/* 1 Unified NoC Trunk */
	output wire [0:0] trunk_req_valid,
	input wire [0:0] trunk_req_ready,
	output wire [FW-1:0] trunk_req_data,
	output wire [0:0] trunk_req_last,
	input wire [0:0] trunk_rsp_valid,
	output wire [0:0] trunk_rsp_ready,
	input wire [RFW-1:0] trunk_rsp_data,

	/* Atomics */
	output wire at_valid,
	input wire at_ready,
	output wire [3:0] at_op,
	output wire [29:0] at_addr,
	output wire [31:0] at_a,
	output wire [31:0] at_b,
	output wire [1:0] at_stage,
	input wire at_rsp_valid,
	input wire [31:0] at_old,
	input wire at_error,

	/* Mesh / SA (SU 0) */
	output wire su0_mesh_valid,
	input wire su0_mesh_ready,
	output wire [701:0] su0_mesh_tri,
	output wire su0_mesh_last,
	output wire [15:0] su0_mesh_id,
	output wire su0_sa_push_valid,
	input wire su0_sa_push_ready,
	output wire [NPHYS*32-1:0] su0_sa_push_data,
	input wire su0_sa_pop_valid,
	output wire su0_sa_pop_ready,
	input wire [NPHYS*32-1:0] su0_sa_pop_data,
	output wire su0_sa_ctl_valid,
	output wire [31:0] su0_sa_ctl_data,
	input wire [31:0] su0_sa_qstat,
	input wire [31:0] su0_sa_stat,
	input wire [31:0] su0_sa_qtag,

	/* Status */
	output wire busy,
	output wire scrub_busy,
	output wire fault,
	output wire [31:0] fault_addr,
	output wire [3:0] fault_stage,
	output wire [3:0] fsm0
);
	localparam [SU_RW-1:0] ROUTE_D0 = {SU_RW{1'b0}};
	localparam [SU_RW-1:0] ROUTE_I0 = {{(SU_RW > 1 ? SU_RW - 1 : 1){1'b0}}, 1'b1};
	wire unused_rop = 1'b0 && (HAS_ROP != 0);

	atg_su_tile #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(1),
		.SU_INDEX(0), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.SHARED_PT(SHARED_PT), .HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU),
		.SU_RW(SU_RW), .ROUTE_D(ROUTE_D0[SU_RW-1:0]), .ROUTE_I(ROUTE_I0[SU_RW-1:0]),
		.RBIT_SU(10), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) su0 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.scrub(scrub), .session_id(session_id),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_avail(vl_avail),
		.vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data),
		.vl_go(vl_go), .vl_mask(vl_mask), .vl_go_ptbase(vl_go_ptbase),
		.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_avail(fl_avail),
		.fl_we(fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane), .fl_data(fl_data),
		.fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data),
		.fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx), .pt_done(pt_done),
		.pt_exp_valid(pt_exp_valid), .pt_exp_ready(pt_exp_ready), .pt_exp_packed(pt_exp_packed),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op),
		.tx_slot(tx_slot), .tx_samp_slot(tx_samp_slot), .tx_vs(tx_vs),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off),
		.tx_tag(tx_tag), .tx_last(tx_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag),
		.tr_data(tr_data), .tr_last(tr_last),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq),
		.ex_xy(ex_xy), .ex_mask(ex_mask), .ex_color(ex_color), .ex_color1(ex_color1),
		.ex_has_src1(ex_has_src1), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_aux(ex_aux),
		.mesh_valid(su0_mesh_valid), .mesh_ready(su0_mesh_ready), .mesh_tri(su0_mesh_tri),
		.mesh_last(su0_mesh_last), .mesh_id(su0_mesh_id),
		.t_req_valid(trunk_req_valid[0]), .t_req_ready(trunk_req_ready[0]),
		.t_req_data(trunk_req_data), .t_req_last(trunk_req_last[0]),
		.t_rsp_valid(trunk_rsp_valid[0]), .t_rsp_ready(trunk_rsp_ready[0]),
		.t_rsp_data(trunk_rsp_data),
		.at_valid(at_valid), .at_stage(at_stage), .at_ready(at_ready),
		.at_op(at_op), .at_addr(at_addr), .at_a(at_a), .at_b(at_b),
		.at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(at_error),
		.sa_push_valid(su0_sa_push_valid), .sa_push_ready(su0_sa_push_ready),
		.sa_push_data(su0_sa_push_data),
		.sa_pop_valid(su0_sa_pop_valid), .sa_pop_ready(su0_sa_pop_ready),
		.sa_pop_data(su0_sa_pop_data),
		.sa_ctl_valid(su0_sa_ctl_valid), .sa_ctl_data(su0_sa_ctl_data),
		.sa_qstat(su0_sa_qstat), .sa_stat(su0_sa_stat), .sa_qtag(su0_sa_qtag),
		.busy(busy), .scrub_busy(scrub_busy), .fault(fault),
		.fault_addr(fault_addr), .fault_stage(fault_stage), .fsm(fsm0)
	);
endmodule

`default_nettype wire
