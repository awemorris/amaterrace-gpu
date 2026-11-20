/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_quadrant16: Explicit 4x4 Quadrant of 4 SU Quads (q0..q3, 16 SUs)
 * merged via atg_rt4 and K=4 Spine distribution/aggregation routers.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_quadrant16 #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter NREGS = 32,
	parameter SB_ENTRIES = 4,
	parameter SBE_W = 2,
	parameter NSU = 64,
	parameter BASE_INDEX = 0,
	parameter FRAG_RESERVE = 1,
	parameter PACKED = 0,
	parameter PK_SHARED = 0,
	parameter SUBGROUP = 0,
	parameter HAS_SA = 0,
	parameter MS4 = 0,
	parameter HAS_MESH = 0,
	parameter LDS_BYTES = 4096,
	parameter PT_ENTRIES = 256,
	parameter VARY_WORDS = 16,
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter MRT_COUNT = 1,
	parameter DUAL_SOURCE = 0,
	parameter HAS_GFX = 1,
	parameter HAS_TU = 1,
	parameter HAS_ROP = 1,
	parameter SU_RW = 5,
	parameter RBIT_Q16 = 10,
	parameter RBIT_QUAD = 12,
	parameter RBIT_SU = 14,
	parameter [SU_RW-1:0] Q16_ROUTE_PFX = {SU_RW{1'b0}},
	parameter TX_TBIT_Q16 = 12,
	parameter TX_TBIT_Q = 10,
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
	input wire p_vl_req,
	output wire p_vl_gnt,
	output wire [7:0] p_vl_ptbase,
	output wire p_vl_avail,
	input wire p_vl_we,
	input wire [5:0] p_vl_reg,
	input wire [4:0] p_vl_lane,
	input wire [31:0] p_vl_data,
	input wire p_vl_go,
	input wire [31:0] p_vl_mask,
	input wire [7:0] p_vl_go_ptbase,

	/* Fragment warp dist */
	input wire p_fl_req,
	output wire p_fl_gnt,
	output wire p_fl_avail,
	input wire p_fl_we,
	input wire [5:0] p_fl_reg,
	input wire [4:0] p_fl_lane,
	input wire [31:0] p_fl_data,
	input wire p_fl_pw_we,
	input wire [11:0] p_fl_pw_addr,
	input wire [31:0] p_fl_pw_data,
	input wire p_fl_go,
	input wire [31:0] p_fl_mask,
	input wire [63:0] p_fl_info,

	/* Shared Spine PT export */
	output wire p_pt_exp_valid,
	input wire p_pt_exp_ready,
	output wire [PT_W-1:0] p_pt_exp_data,

	/* TU */
	output wire p_tx_valid,
	input wire p_tx_ready,
	output wire [7:0] p_tx_op,
	output wire [3:0] p_tx_slot,
	output wire [3:0] p_tx_samp_slot,
	output wire p_tx_vs,
	output wire [3:0] p_tx_mask,
	output wire [639:0] p_tx_coord,
	output wire [11:0] p_tx_off,
	output wire [15:0] p_tx_tag,
	output wire p_tx_last,
	input wire p_tr_valid,
	output wire p_tr_ready,
	input wire [15:0] p_tr_tag,
	input wire [511:0] p_tr_data,
	input wire p_tr_last,

	/* ROP */
	output wire p_ex_valid,
	input wire p_ex_ready,
	output wire [15:0] p_ex_seq,
	output wire [31:0] p_ex_xy,
	output wire [3:0] p_ex_mask,
	output wire [511:0] p_ex_color,
	output wire [511:0] p_ex_color1,
	output wire p_ex_has_src1,
	output wire [127:0] p_ex_depth,
	output wire p_ex_last,
	output wire [154:0] p_ex_aux,
	input wire [15:0] p_ex_next,

	/* Merged Trunk */
	output wire t_req_valid,
	input wire t_req_ready,
	output wire [FW-1:0] t_req_data,
	output wire t_req_last,
	input wire t_rsp_valid,
	output wire t_rsp_ready,
	input wire [RFW-1:0] t_rsp_data,

	/* Atomics */
	output wire p_at_valid,
	input wire p_at_ready,
	output wire [3:0] p_at_op,
	output wire [29:0] p_at_addr,
	output wire [31:0] p_at_a,
	output wire [31:0] p_at_b,
	output wire [1:0] p_at_stage,
	input wire p_at_rsp_valid,
	input wire [31:0] p_at_old,
	input wire p_at_error,

	/* Mesh / SA (SU 0 within this quadrant) */
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
	function [SU_RW-1:0] mk_q_pfx;
		input [1:0] q_child;
		reg [SU_RW-1:0] r;
		begin
			r = Q16_ROUTE_PFX;
			r[RBIT_Q16 - 10 +: 2] = q_child;
			mk_q_pfx = r;
		end
	endfunction

	wire [3:0] c_req_v, c_req_r, c_req_l, c_rsp_v, c_rsp_r;
	wire [FW-1:0] c_req_d0, c_req_d1, c_req_d2, c_req_d3;
	wire [RFW-1:0] c_rsp_d0, c_rsp_d1, c_rsp_d2, c_rsp_d3;

	wire [3:0] c_vl_req, c_vl_gnt, c_vl_avail, c_vl_we, c_vl_go;
	wire [31:0] c_vl_ptbase;
	wire [5:0] w_vl_reg;
	wire [4:0] w_vl_lane;
	wire [31:0] w_vl_data, w_vl_mask;
	wire [7:0] w_vl_go_ptbase;

	wire [3:0] c_fl_req, c_fl_gnt, c_fl_avail, c_fl_we, c_fl_pw_we, c_fl_go;
	wire [5:0] w_fl_reg;
	wire [4:0] w_fl_lane;
	wire [31:0] w_fl_data, w_fl_pw_data, w_fl_mask;
	wire [11:0] w_fl_pw_addr;
	wire [63:0] w_fl_info;

	wire [3:0] c_pt_exp_v, c_pt_exp_r;
	wire [4*PT_W-1:0] c_pt_exp_d;

	wire [3:0] c_tx_v, c_tx_r, c_tx_vs, c_tx_l, c_tr_v, c_tr_r, c_tr_l;
	wire [31:0] c_tx_op;
	wire [15:0] c_tx_slot, c_tx_samp, c_tx_mask;
	wire [2559:0] c_tx_coord;
	wire [47:0] c_tx_off;
	wire [63:0] c_tx_tag, c_tr_tag;
	wire [2047:0] c_tr_data;

	wire [3:0] c_ex_v, c_ex_r, c_ex_hs1, c_ex_l;
	wire [63:0] c_ex_seq;
	wire [127:0] c_ex_xy;
	wire [15:0] c_ex_mask;
	wire [2047:0] c_ex_col, c_ex_col1;
	wire [511:0] c_ex_dep;
	wire [619:0] c_ex_aux;
	wire [15:0] w_ex_next;

	wire [3:0] c_at_v, c_at_r, c_at_rsp_v;
	wire [15:0] c_at_op;
	wire [119:0] c_at_addr;
	wire [127:0] c_at_a, c_at_b;
	wire [7:0] c_at_stage;
	wire [31:0] w_at_old;
	wire w_at_err;

	wire [3:0] c_busy, c_scrub_busy, c_fault;
	wire [31:0] c_faddr0, c_faddr1, c_faddr2, c_faddr3;
	wire [3:0] c_fstage0, c_fstage1, c_fstage2, c_fstage3;
	wire [15:0] q_fsm0, q_fsm1, q_fsm2, q_fsm3;
	assign fsm0 = q_fsm0[3:0];

	wire u_q1_mv, u_q1_ml, u_q2_mv, u_q2_ml, u_q3_mv, u_q3_ml;
	wire [701:0] u_q1_mt, u_q2_mt, u_q3_mt;
	wire [15:0] u_q1_mi, u_q2_mi, u_q3_mi;
	wire u_q1_spv, u_q1_spr, u_q1_scv, u_q2_spv, u_q2_spr, u_q2_scv, u_q3_spv, u_q3_spr, u_q3_scv;
	wire [NPHYS*32-1:0] u_q1_spd, u_q2_spd, u_q3_spd;
	wire [31:0] u_q1_scd, u_q2_scd, u_q3_scd;

	/* Quad 0 (NW) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(NSU),
		.BASE_INDEX(BASE_INDEX + 0), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(RBIT_QUAD), .RBIT_SU(RBIT_SU),
		.QUAD_ROUTE_PFX(mk_q_pfx(2'd0)), .TX_TBIT(TX_TBIT_Q), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q0 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.scrub(scrub), .session_id(session_id),
		.p_vl_req(c_vl_req[0]), .p_vl_gnt(c_vl_gnt[0]), .p_vl_ptbase(c_vl_ptbase[0*8 +: 8]), .p_vl_avail(c_vl_avail[0]),
		.p_vl_we(c_vl_we[0]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
		.p_vl_go(c_vl_go[0]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
		.p_fl_req(c_fl_req[0]), .p_fl_gnt(c_fl_gnt[0]), .p_fl_avail(c_fl_avail[0]),
		.p_fl_we(c_fl_we[0]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
		.p_fl_pw_we(c_fl_pw_we[0]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
		.p_fl_go(c_fl_go[0]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
		.p_pt_exp_valid(c_pt_exp_v[0]), .p_pt_exp_ready(c_pt_exp_r[0]), .p_pt_exp_data(c_pt_exp_d[0*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[0]), .p_tx_ready(c_tx_r[0]), .p_tx_op(c_tx_op[0*8 +: 8]),
		.p_tx_slot(c_tx_slot[0*4 +: 4]), .p_tx_samp_slot(c_tx_samp[0*4 +: 4]), .p_tx_vs(c_tx_vs[0]),
		.p_tx_mask(c_tx_mask[0*4 +: 4]), .p_tx_coord(c_tx_coord[0*640 +: 640]), .p_tx_off(c_tx_off[0*12 +: 12]),
		.p_tx_tag(c_tx_tag[0*16 +: 16]), .p_tx_last(c_tx_l[0]),
		.p_tr_valid(c_tr_v[0]), .p_tr_ready(c_tr_r[0]), .p_tr_tag(c_tr_tag[0*16 +: 16]),
		.p_tr_data(c_tr_data[0*512 +: 512]), .p_tr_last(c_tr_l[0]),
		.p_ex_valid(c_ex_v[0]), .p_ex_ready(c_ex_r[0]), .p_ex_seq(c_ex_seq[0*16 +: 16]),
		.p_ex_xy(c_ex_xy[0*32 +: 32]), .p_ex_mask(c_ex_mask[0*4 +: 4]),
		.p_ex_color(c_ex_col[0*512 +: 512]), .p_ex_color1(c_ex_col1[0*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[0]), .p_ex_depth(c_ex_dep[0*128 +: 128]), .p_ex_last(c_ex_l[0]),
		.p_ex_aux(c_ex_aux[0*155 +: 155]), .p_ex_next(w_ex_next),
		.t_req_valid(c_req_v[0]), .t_req_ready(c_req_r[0]), .t_req_data(c_req_d0), .t_req_last(c_req_l[0]),
		.t_rsp_valid(c_rsp_v[0]), .t_rsp_ready(c_rsp_r[0]), .t_rsp_data(c_rsp_d0),
		.p_at_valid(c_at_v[0]), .p_at_ready(c_at_r[0]), .p_at_op(c_at_op[0*4 +: 4]),
		.p_at_addr(c_at_addr[0*30 +: 30]), .p_at_a(c_at_a[0*32 +: 32]), .p_at_b(c_at_b[0*32 +: 32]),
		.p_at_stage(c_at_stage[0*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[0]), .p_at_old(w_at_old), .p_at_error(w_at_err),
		.su0_mesh_valid(su0_mesh_valid), .su0_mesh_ready(su0_mesh_ready), .su0_mesh_tri(su0_mesh_tri),
		.su0_mesh_last(su0_mesh_last), .su0_mesh_id(su0_mesh_id),
		.su0_sa_push_valid(su0_sa_push_valid), .su0_sa_push_ready(su0_sa_push_ready), .su0_sa_push_data(su0_sa_push_data),
		.su0_sa_pop_valid(su0_sa_pop_valid), .su0_sa_pop_ready(su0_sa_pop_ready), .su0_sa_pop_data(su0_sa_pop_data),
		.su0_sa_ctl_valid(su0_sa_ctl_valid), .su0_sa_ctl_data(su0_sa_ctl_data),
		.su0_sa_qstat(su0_sa_qstat), .su0_sa_stat(su0_sa_stat), .su0_sa_qtag(su0_sa_qtag),
		.busy(c_busy[0]), .scrub_busy(c_scrub_busy[0]), .fault(c_fault[0]),
		.fault_addr(c_faddr0), .fault_stage(c_fstage0), .fsm_packed(q_fsm0)
	);

	/* Quad 1 (NE) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(NSU),
		.BASE_INDEX(BASE_INDEX + 4), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(RBIT_QUAD), .RBIT_SU(RBIT_SU),
		.QUAD_ROUTE_PFX(mk_q_pfx(2'd1)), .TX_TBIT(TX_TBIT_Q), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q1 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.scrub(scrub), .session_id(session_id),
		.p_vl_req(c_vl_req[1]), .p_vl_gnt(c_vl_gnt[1]), .p_vl_ptbase(c_vl_ptbase[1*8 +: 8]), .p_vl_avail(c_vl_avail[1]),
		.p_vl_we(c_vl_we[1]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
		.p_vl_go(c_vl_go[1]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
		.p_fl_req(c_fl_req[1]), .p_fl_gnt(c_fl_gnt[1]), .p_fl_avail(c_fl_avail[1]),
		.p_fl_we(c_fl_we[1]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
		.p_fl_pw_we(c_fl_pw_we[1]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
		.p_fl_go(c_fl_go[1]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
		.p_pt_exp_valid(c_pt_exp_v[1]), .p_pt_exp_ready(c_pt_exp_r[1]), .p_pt_exp_data(c_pt_exp_d[1*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[1]), .p_tx_ready(c_tx_r[1]), .p_tx_op(c_tx_op[1*8 +: 8]),
		.p_tx_slot(c_tx_slot[1*4 +: 4]), .p_tx_samp_slot(c_tx_samp[1*4 +: 4]), .p_tx_vs(c_tx_vs[1]),
		.p_tx_mask(c_tx_mask[1*4 +: 4]), .p_tx_coord(c_tx_coord[1*640 +: 640]), .p_tx_off(c_tx_off[1*12 +: 12]),
		.p_tx_tag(c_tx_tag[1*16 +: 16]), .p_tx_last(c_tx_l[1]),
		.p_tr_valid(c_tr_v[1]), .p_tr_ready(c_tr_r[1]), .p_tr_tag(c_tr_tag[1*16 +: 16]),
		.p_tr_data(c_tr_data[1*512 +: 512]), .p_tr_last(c_tr_l[1]),
		.p_ex_valid(c_ex_v[1]), .p_ex_ready(c_ex_r[1]), .p_ex_seq(c_ex_seq[1*16 +: 16]),
		.p_ex_xy(c_ex_xy[1*32 +: 32]), .p_ex_mask(c_ex_mask[1*4 +: 4]),
		.p_ex_color(c_ex_col[1*512 +: 512]), .p_ex_color1(c_ex_col1[1*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[1]), .p_ex_depth(c_ex_dep[1*128 +: 128]), .p_ex_last(c_ex_l[1]),
		.p_ex_aux(c_ex_aux[1*155 +: 155]), .p_ex_next(w_ex_next),
		.t_req_valid(c_req_v[1]), .t_req_ready(c_req_r[1]), .t_req_data(c_req_d1), .t_req_last(c_req_l[1]),
		.t_rsp_valid(c_rsp_v[1]), .t_rsp_ready(c_rsp_r[1]), .t_rsp_data(c_rsp_d1),
		.p_at_valid(c_at_v[1]), .p_at_ready(c_at_r[1]), .p_at_op(c_at_op[1*4 +: 4]),
		.p_at_addr(c_at_addr[1*30 +: 30]), .p_at_a(c_at_a[1*32 +: 32]), .p_at_b(c_at_b[1*32 +: 32]),
		.p_at_stage(c_at_stage[1*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[1]), .p_at_old(w_at_old), .p_at_error(w_at_err),
		.su0_mesh_valid(u_q1_mv), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q1_mt),
		.su0_mesh_last(u_q1_ml), .su0_mesh_id(u_q1_mi),
		.su0_sa_push_valid(u_q1_spv), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q1_spd),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q1_spr), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q1_scv), .su0_sa_ctl_data(u_q1_scd),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(c_busy[1]), .scrub_busy(c_scrub_busy[1]), .fault(c_fault[1]),
		.fault_addr(c_faddr1), .fault_stage(c_fstage1), .fsm_packed(q_fsm1)
	);

	/* Quad 2 (SW) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(NSU),
		.BASE_INDEX(BASE_INDEX + 8), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(RBIT_QUAD), .RBIT_SU(RBIT_SU),
		.QUAD_ROUTE_PFX(mk_q_pfx(2'd2)), .TX_TBIT(TX_TBIT_Q), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q2 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.scrub(scrub), .session_id(session_id),
		.p_vl_req(c_vl_req[2]), .p_vl_gnt(c_vl_gnt[2]), .p_vl_ptbase(c_vl_ptbase[2*8 +: 8]), .p_vl_avail(c_vl_avail[2]),
		.p_vl_we(c_vl_we[2]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
		.p_vl_go(c_vl_go[2]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
		.p_fl_req(c_fl_req[2]), .p_fl_gnt(c_fl_gnt[2]), .p_fl_avail(c_fl_avail[2]),
		.p_fl_we(c_fl_we[2]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
		.p_fl_pw_we(c_fl_pw_we[2]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
		.p_fl_go(c_fl_go[2]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
		.p_pt_exp_valid(c_pt_exp_v[2]), .p_pt_exp_ready(c_pt_exp_r[2]), .p_pt_exp_data(c_pt_exp_d[2*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[2]), .p_tx_ready(c_tx_r[2]), .p_tx_op(c_tx_op[2*8 +: 8]),
		.p_tx_slot(c_tx_slot[2*4 +: 4]), .p_tx_samp_slot(c_tx_samp[2*4 +: 4]), .p_tx_vs(c_tx_vs[2]),
		.p_tx_mask(c_tx_mask[2*4 +: 4]), .p_tx_coord(c_tx_coord[2*640 +: 640]), .p_tx_off(c_tx_off[2*12 +: 12]),
		.p_tx_tag(c_tx_tag[2*16 +: 16]), .p_tx_last(c_tx_l[2]),
		.p_tr_valid(c_tr_v[2]), .p_tr_ready(c_tr_r[2]), .p_tr_tag(c_tr_tag[2*16 +: 16]),
		.p_tr_data(c_tr_data[2*512 +: 512]), .p_tr_last(c_tr_l[2]),
		.p_ex_valid(c_ex_v[2]), .p_ex_ready(c_ex_r[2]), .p_ex_seq(c_ex_seq[2*16 +: 16]),
		.p_ex_xy(c_ex_xy[2*32 +: 32]), .p_ex_mask(c_ex_mask[2*4 +: 4]),
		.p_ex_color(c_ex_col[2*512 +: 512]), .p_ex_color1(c_ex_col1[2*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[2]), .p_ex_depth(c_ex_dep[2*128 +: 128]), .p_ex_last(c_ex_l[2]),
		.p_ex_aux(c_ex_aux[2*155 +: 155]), .p_ex_next(w_ex_next),
		.t_req_valid(c_req_v[2]), .t_req_ready(c_req_r[2]), .t_req_data(c_req_d2), .t_req_last(c_req_l[2]),
		.t_rsp_valid(c_rsp_v[2]), .t_rsp_ready(c_rsp_r[2]), .t_rsp_data(c_rsp_d2),
		.p_at_valid(c_at_v[2]), .p_at_ready(c_at_r[2]), .p_at_op(c_at_op[2*4 +: 4]),
		.p_at_addr(c_at_addr[2*30 +: 30]), .p_at_a(c_at_a[2*32 +: 32]), .p_at_b(c_at_b[2*32 +: 32]),
		.p_at_stage(c_at_stage[2*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[2]), .p_at_old(w_at_old), .p_at_error(w_at_err),
		.su0_mesh_valid(u_q2_mv), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q2_mt),
		.su0_mesh_last(u_q2_ml), .su0_mesh_id(u_q2_mi),
		.su0_sa_push_valid(u_q2_spv), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q2_spd),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q2_spr), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q2_scv), .su0_sa_ctl_data(u_q2_scd),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(c_busy[2]), .scrub_busy(c_scrub_busy[2]), .fault(c_fault[2]),
		.fault_addr(c_faddr2), .fault_stage(c_fstage2), .fsm_packed(q_fsm2)
	);

	/* Quad 3 (SE) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(NSU),
		.BASE_INDEX(BASE_INDEX + 12), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(RBIT_QUAD), .RBIT_SU(RBIT_SU),
		.QUAD_ROUTE_PFX(mk_q_pfx(2'd3)), .TX_TBIT(TX_TBIT_Q), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q3 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.scrub(scrub), .session_id(session_id),
		.p_vl_req(c_vl_req[3]), .p_vl_gnt(c_vl_gnt[3]), .p_vl_ptbase(c_vl_ptbase[3*8 +: 8]), .p_vl_avail(c_vl_avail[3]),
		.p_vl_we(c_vl_we[3]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
		.p_vl_go(c_vl_go[3]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
		.p_fl_req(c_fl_req[3]), .p_fl_gnt(c_fl_gnt[3]), .p_fl_avail(c_fl_avail[3]),
		.p_fl_we(c_fl_we[3]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
		.p_fl_pw_we(c_fl_pw_we[3]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
		.p_fl_go(c_fl_go[3]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
		.p_pt_exp_valid(c_pt_exp_v[3]), .p_pt_exp_ready(c_pt_exp_r[3]), .p_pt_exp_data(c_pt_exp_d[3*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[3]), .p_tx_ready(c_tx_r[3]), .p_tx_op(c_tx_op[3*8 +: 8]),
		.p_tx_slot(c_tx_slot[3*4 +: 4]), .p_tx_samp_slot(c_tx_samp[3*4 +: 4]), .p_tx_vs(c_tx_vs[3]),
		.p_tx_mask(c_tx_mask[3*4 +: 4]), .p_tx_coord(c_tx_coord[3*640 +: 640]), .p_tx_off(c_tx_off[3*12 +: 12]),
		.p_tx_tag(c_tx_tag[3*16 +: 16]), .p_tx_last(c_tx_l[3]),
		.p_tr_valid(c_tr_v[3]), .p_tr_ready(c_tr_r[3]), .p_tr_tag(c_tr_tag[3*16 +: 16]),
		.p_tr_data(c_tr_data[3*512 +: 512]), .p_tr_last(c_tr_l[3]),
		.p_ex_valid(c_ex_v[3]), .p_ex_ready(c_ex_r[3]), .p_ex_seq(c_ex_seq[3*16 +: 16]),
		.p_ex_xy(c_ex_xy[3*32 +: 32]), .p_ex_mask(c_ex_mask[3*4 +: 4]),
		.p_ex_color(c_ex_col[3*512 +: 512]), .p_ex_color1(c_ex_col1[3*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[3]), .p_ex_depth(c_ex_dep[3*128 +: 128]), .p_ex_last(c_ex_l[3]),
		.p_ex_aux(c_ex_aux[3*155 +: 155]), .p_ex_next(w_ex_next),
		.t_req_valid(c_req_v[3]), .t_req_ready(c_req_r[3]), .t_req_data(c_req_d3), .t_req_last(c_req_l[3]),
		.t_rsp_valid(c_rsp_v[3]), .t_rsp_ready(c_rsp_r[3]), .t_rsp_data(c_rsp_d3),
		.p_at_valid(c_at_v[3]), .p_at_ready(c_at_r[3]), .p_at_op(c_at_op[3*4 +: 4]),
		.p_at_addr(c_at_addr[3*30 +: 30]), .p_at_a(c_at_a[3*32 +: 32]), .p_at_b(c_at_b[3*32 +: 32]),
		.p_at_stage(c_at_stage[3*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[3]), .p_at_old(w_at_old), .p_at_error(w_at_err),
		.su0_mesh_valid(u_q3_mv), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q3_mt),
		.su0_mesh_last(u_q3_ml), .su0_mesh_id(u_q3_mi),
		.su0_sa_push_valid(u_q3_spv), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q3_spd),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q3_spr), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q3_scv), .su0_sa_ctl_data(u_q3_scd),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(c_busy[3]), .scrub_busy(c_scrub_busy[3]), .fault(c_fault[3]),
		.fault_addr(c_faddr3), .fault_stage(c_fstage3), .fsm_packed(q_fsm3)
	);

	/* 4x1 Memory NoC Router (rt4_q16) */
	wire unused_rt4_idle;
	atg_rt4 #(.RBIT(RBIT_Q16), .FW(FW), .RFW(RFW)) u_rt4_q16 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(c_req_v[0]), .c0_req_ready(c_req_r[0]), .c0_req_data(c_req_d0), .c0_req_last(c_req_l[0]),
		.c1_req_valid(c_req_v[1]), .c1_req_ready(c_req_r[1]), .c1_req_data(c_req_d1), .c1_req_last(c_req_l[1]),
		.c2_req_valid(c_req_v[2]), .c2_req_ready(c_req_r[2]), .c2_req_data(c_req_d2), .c2_req_last(c_req_l[2]),
		.c3_req_valid(c_req_v[3]), .c3_req_ready(c_req_r[3]), .c3_req_data(c_req_d3), .c3_req_last(c_req_l[3]),
		.p_req_valid(t_req_valid), .p_req_ready(t_req_ready),
		.p_req_data(t_req_data), .p_req_last(t_req_last),
		.p_rsp_valid(t_rsp_valid), .p_rsp_ready(t_rsp_ready), .p_rsp_data(t_rsp_data),
		.c0_rsp_valid(c_rsp_v[0]), .c0_rsp_ready(c_rsp_r[0]), .c0_rsp_data(c_rsp_d0),
		.c1_rsp_valid(c_rsp_v[1]), .c1_rsp_ready(c_rsp_r[1]), .c1_rsp_data(c_rsp_d1),
		.c2_rsp_valid(c_rsp_v[2]), .c2_rsp_ready(c_rsp_r[2]), .c2_rsp_data(c_rsp_d2),
		.c3_rsp_valid(c_rsp_v[3]), .c3_rsp_ready(c_rsp_r[3]), .c3_rsp_data(c_rsp_d3),
		.rsp_idle(unused_rt4_idle)
	);

	/* Spine routers (K=4) */
	generate
	if (HAS_GFX != 0) begin : g_q16_gfx
		atg_warp_dist #(.K(4)) u_q16_wdist (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(p_vl_req), .p_vl_gnt(p_vl_gnt), .p_vl_ptbase(p_vl_ptbase), .p_vl_avail(p_vl_avail),
			.p_vl_we(p_vl_we), .p_vl_reg(p_vl_reg), .p_vl_lane(p_vl_lane), .p_vl_data(p_vl_data),
			.p_vl_go(p_vl_go), .p_vl_mask(p_vl_mask), .p_vl_go_ptbase(p_vl_go_ptbase),
			.c_vl_req(c_vl_req), .c_vl_gnt(c_vl_gnt), .c_vl_ptbase(c_vl_ptbase), .c_vl_avail(c_vl_avail),
			.c_vl_we(c_vl_we), .c_vl_reg(w_vl_reg), .c_vl_lane(w_vl_lane), .c_vl_data(w_vl_data),
			.c_vl_go(c_vl_go), .c_vl_mask(w_vl_mask), .c_vl_go_ptbase(w_vl_go_ptbase),
			.p_fl_req(p_fl_req), .p_fl_gnt(p_fl_gnt), .p_fl_avail(p_fl_avail),
			.p_fl_we(p_fl_we), .p_fl_reg(p_fl_reg), .p_fl_lane(p_fl_lane), .p_fl_data(p_fl_data),
			.p_fl_pw_we(p_fl_pw_we), .p_fl_pw_addr(p_fl_pw_addr), .p_fl_pw_data(p_fl_pw_data),
			.p_fl_go(p_fl_go), .p_fl_mask(p_fl_mask), .p_fl_info(p_fl_info),
			.c_fl_req(c_fl_req), .c_fl_gnt(c_fl_gnt), .c_fl_avail(c_fl_avail),
			.c_fl_we(c_fl_we), .c_fl_reg(w_fl_reg), .c_fl_lane(w_fl_lane), .c_fl_data(w_fl_data),
			.c_fl_pw_we(c_fl_pw_we), .c_fl_pw_addr(w_fl_pw_addr), .c_fl_pw_data(w_fl_pw_data),
			.c_fl_go(c_fl_go), .c_fl_mask(w_fl_mask), .c_fl_info(w_fl_info)
		);
		atg_pt_exp_rt #(.K(4), .W(PT_W)) u_q16_ptrt (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v), .c_ready(c_pt_exp_r), .c_data(c_pt_exp_d),
			.p_valid(p_pt_exp_valid), .p_ready(p_pt_exp_ready), .p_data(p_pt_exp_data)
		);
	end else begin : g_q16_nogfx
		assign p_vl_gnt = 1'b0;
		assign p_vl_ptbase = 8'd0;
		assign p_vl_avail = 1'b0;
		assign p_fl_gnt = 1'b0;
		assign p_fl_avail = 1'b0;
		assign p_pt_exp_valid = 1'b0;
		assign p_pt_exp_data = {PT_W{1'b0}};
		assign c_vl_req = 4'd0;
		assign c_vl_we = 4'd0;
		assign c_vl_go = 4'd0;
		assign w_vl_reg = 6'd0;
		assign w_vl_lane = 5'd0;
		assign w_vl_data = 32'd0;
		assign w_vl_mask = 32'd0;
		assign w_vl_go_ptbase = 8'd0;
		assign c_fl_req = 4'd0;
		assign c_fl_we = 4'd0;
		assign c_fl_pw_we = 4'd0;
		assign c_fl_go = 4'd0;
		assign w_fl_reg = 6'd0;
		assign w_fl_lane = 5'd0;
		assign w_fl_data = 32'd0;
		assign w_fl_pw_addr = 12'd0;
		assign w_fl_pw_data = 32'd0;
		assign w_fl_mask = 32'd0;
		assign w_fl_info = 64'd0;
		assign c_pt_exp_r = 4'hF;
	end

	if (HAS_TU != 0) begin : g_q16_tu
		atg_tx_rt #(.K(4), .TBIT(TX_TBIT_Q16)) u_q16_txrt (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v), .c_tx_ready(c_tx_r), .c_tx_op(c_tx_op),
			.c_tx_slot(c_tx_slot), .c_tx_samp_slot(c_tx_samp), .c_tx_vs(c_tx_vs),
			.c_tx_mask(c_tx_mask), .c_tx_coord(c_tx_coord), .c_tx_off(c_tx_off),
			.c_tx_tag(c_tx_tag), .c_tx_last(c_tx_l),
			.c_tr_valid(c_tr_v), .c_tr_ready(c_tr_r), .c_tr_tag(c_tr_tag),
			.c_tr_data(c_tr_data), .c_tr_last(c_tr_l),
			.p_tx_valid(p_tx_valid), .p_tx_ready(p_tx_ready), .p_tx_op(p_tx_op),
			.p_tx_slot(p_tx_slot), .p_tx_samp_slot(p_tx_samp_slot), .p_tx_vs(p_tx_vs),
			.p_tx_mask(p_tx_mask), .p_tx_coord(p_tx_coord), .p_tx_off(p_tx_off),
			.p_tx_tag(p_tx_tag), .p_tx_last(p_tx_last),
			.p_tr_valid(p_tr_valid), .p_tr_ready(p_tr_ready), .p_tr_tag(p_tr_tag),
			.p_tr_data(p_tr_data), .p_tr_last(p_tr_last)
		);
	end else begin : g_q16_notu
		assign p_tx_valid = 1'b0;
		assign p_tx_op = 8'd0;
		assign p_tx_slot = 4'd0;
		assign p_tx_samp_slot = 4'd0;
		assign p_tx_vs = 1'b0;
		assign p_tx_mask = 4'd0;
		assign p_tx_coord = 640'd0;
		assign p_tx_off = 12'd0;
		assign p_tx_tag = 16'd0;
		assign p_tx_last = 1'b0;
		assign p_tr_ready = 1'b1;
		assign c_tx_r = 4'd0;
		assign c_tr_v = 4'd0;
		assign c_tr_tag = 64'd0;
		assign c_tr_data = 2048'd0;
		assign c_tr_l = 4'd0;
	end

	if (HAS_ROP != 0) begin : g_q16_rop
		atg_ex_rt #(.K(4)) u_q16_exrt (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v), .c_ex_ready(c_ex_r), .c_ex_seq(c_ex_seq),
			.c_ex_xy(c_ex_xy), .c_ex_mask(c_ex_mask), .c_ex_color(c_ex_col),
			.c_ex_color1(c_ex_col1), .c_ex_has_src1(c_ex_hs1), .c_ex_depth(c_ex_dep),
			.c_ex_last(c_ex_l), .c_ex_aux(c_ex_aux), .c_ex_next(w_ex_next),
			.p_ex_valid(p_ex_valid), .p_ex_ready(p_ex_ready), .p_ex_seq(p_ex_seq),
			.p_ex_xy(p_ex_xy), .p_ex_mask(p_ex_mask), .p_ex_color(p_ex_color),
			.p_ex_color1(p_ex_color1), .p_ex_has_src1(p_ex_has_src1), .p_ex_depth(p_ex_depth),
			.p_ex_last(p_ex_last), .p_ex_aux(p_ex_aux), .p_ex_next(p_ex_next)
		);
	end else begin : g_q16_norop
		assign p_ex_valid = 1'b0;
		assign p_ex_seq = 16'd0;
		assign p_ex_xy = 32'd0;
		assign p_ex_mask = 4'd0;
		assign p_ex_color = 512'd0;
		assign p_ex_color1 = 512'd0;
		assign p_ex_has_src1 = 1'b0;
		assign p_ex_depth = 128'd0;
		assign p_ex_last = 1'b0;
		assign p_ex_aux = 155'd0;
		assign c_ex_r = 4'd0;
		assign w_ex_next = 16'd0;
	end
	endgenerate

	atg_atom_rt #(.K(4), .ATOM_AW(30)) u_q16_atomrt (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v), .c_at_ready(c_at_r), .c_at_op(c_at_op),
		.c_at_addr(c_at_addr), .c_at_a(c_at_a), .c_at_b(c_at_b), .c_at_stage(c_at_stage),
		.c_at_rsp_valid(c_at_rsp_v), .c_at_old(w_at_old), .c_at_error(w_at_err),
		.p_at_valid(p_at_valid), .p_at_ready(p_at_ready), .p_at_op(p_at_op),
		.p_at_addr(p_at_addr), .p_at_a(p_at_a), .p_at_b(p_at_b), .p_at_stage(p_at_stage),
		.p_at_rsp_valid(p_at_rsp_valid), .p_at_old(p_at_old), .p_at_error(p_at_error)
	);

	assign busy = |c_busy;
	assign scrub_busy = |c_scrub_busy;
	assign fault = |c_fault;
	assign fault_addr = c_fault[0] ? c_faddr0 :
	                    c_fault[1] ? c_faddr1 :
	                    c_fault[2] ? c_faddr2 :
	                    c_fault[3] ? c_faddr3 : 32'd0;
	assign fault_stage = c_fault[0] ? c_fstage0 :
	                     c_fault[1] ? c_fstage1 :
	                     c_fault[2] ? c_fstage2 :
	                     c_fault[3] ? c_fstage3 : 4'd0;

	wire unused_ok = &{1'b0, unused_rt4_idle, q_fsm0[15:4], q_fsm1, q_fsm2, q_fsm3,
		u_q1_mv, u_q1_ml, u_q1_mt, u_q1_mi, u_q2_mv, u_q2_ml, u_q2_mt, u_q2_mi,
		u_q3_mv, u_q3_ml, u_q3_mt, u_q3_mi,
		u_q1_spv, u_q1_spr, u_q1_spd, u_q1_scv, u_q1_scd,
		u_q2_spv, u_q2_spr, u_q2_spd, u_q2_scv, u_q2_scd,
		u_q3_spv, u_q3_spr, u_q3_spd, u_q3_scv, u_q3_scd};
endmodule

`default_nettype wire
