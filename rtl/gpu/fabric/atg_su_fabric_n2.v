/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fabric_n2: Explicit 2D physical fabric for N = 2 SUs (2x1 West/East).
 * Matches docs/svg/floorplan/floorplan_n2.svg:
 *
 *   [ SU 0 (West) ] --- rep_h(1) --- [ rt2_top ] --- rep_h(1) --- [ SU 1 (East) ]
 *                                         |
 *                                         v
 *                                     Trunk 0 ---> Spine MMU / Root Fat-Tree
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fabric_n2 #(
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
	parameter SHARED_PT = 1,
	parameter HAS_GFX = 1,
	parameter HAS_TU = 1,
	parameter HAS_ROP = 1,
	parameter SU_RW = 2,
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

	/* Local PT stub (SHARED_PT == 1) */
	input wire pt_rd,
	input wire [7:0] pt_idx,
	input wire [6:0] pt_word,
	output wire [31:0] pt_rdata,
	input wire pt_free,
	input wire [7:0] pt_free_idx,
	output wire [7:0] pt_done,

	/* Shared Spine PT export */
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
	assign pt_rdata = 32'd0;
	assign pt_done = 8'd0;

	/* Route bits: [0] = su0/su1 at rt2_top (RBIT=10), [1] = D$/I$ at local rt2 (RBIT=11) */
	localparam [SU_RW-1:0] ROUTE_D0 = 2'b00;
	localparam [SU_RW-1:0] ROUTE_I0 = 2'b10;
	localparam [SU_RW-1:0] ROUTE_D1 = 2'b01;
	localparam [SU_RW-1:0] ROUTE_I1 = 2'b11;

	/* Per-SU wires (su0 West, su1 East) */
	wire [1:0] s_req_v, s_req_r, s_req_l, s_rsp_v, s_rsp_r;
	wire [FW-1:0] s_req_d0, s_req_d1;
	wire [RFW-1:0] s_rsp_d0, s_rsp_d1;

	wire [1:0] r_req_v, r_req_r, r_req_l, r_rsp_v, r_rsp_r;
	wire [FW-1:0] r_req_d0, r_req_d1;
	wire [RFW-1:0] r_rsp_d0, r_rsp_d1;

	wire [1:0] b_st_we, b_cs_kick, b_cs_mesh, b_lc_kick, b_scrub;
	wire [8:0] b_st_idx0, b_st_idx1;
	wire [31:0] b_st_wdata0, b_st_wdata1;
	wire [3:0] b_inv0, b_inv1, b_sess0, b_sess1;
	wire [1:0] b_busy, b_scrub_busy, b_fault;
	wire [31:0] b_faddr0, b_faddr1;
	wire [3:0] b_fstage0, b_fstage1;

	wire [1:0] s_busy, s_scrub_busy, s_fault;
	wire [31:0] s_faddr0, s_faddr1;
	wire [3:0] s_fstage0, s_fstage1, fsm1_unused;

	wire [1:0] c_vl_req, c_vl_gnt, c_vl_avail, c_vl_we, c_vl_go;
	wire [15:0] c_vl_ptbase;
	wire [5:0] w_vl_reg;
	wire [4:0] w_vl_lane;
	wire [31:0] w_vl_data, w_vl_mask;
	wire [7:0] w_vl_go_ptbase;

	wire [1:0] c_fl_req, c_fl_gnt, c_fl_avail, c_fl_we, c_fl_pw_we, c_fl_go;
	wire [5:0] w_fl_reg;
	wire [4:0] w_fl_lane;
	wire [31:0] w_fl_data, w_fl_pw_data, w_fl_mask;
	wire [11:0] w_fl_pw_addr;
	wire [63:0] w_fl_info;

	wire [1:0] c_pt_exp_v, c_pt_exp_r;
	wire [2*PT_W-1:0] c_pt_exp_d;

	wire [1:0] c_tx_v, c_tx_r, c_tx_vs, c_tx_l, c_tr_v, c_tr_r, c_tr_l;
	wire [15:0] c_tx_op;
	wire [7:0] c_tx_slot, c_tx_samp, c_tx_mask;
	wire [1279:0] c_tx_coord;
	wire [23:0] c_tx_off;
	wire [31:0] c_tx_tag, c_tr_tag;
	wire [1023:0] c_tr_data;

	wire [1:0] c_ex_v, c_ex_r, c_ex_hs1, c_ex_l;
	wire [31:0] c_ex_seq;
	wire [63:0] c_ex_xy;
	wire [7:0] c_ex_mask;
	wire [1023:0] c_ex_col, c_ex_col1;
	wire [255:0] c_ex_dep;
	wire [309:0] c_ex_aux;
	wire [15:0] w_ex_next;

	wire [1:0] c_at_v, c_at_r, c_at_rsp_v;
	wire [7:0] c_at_op;
	wire [59:0] c_at_addr;
	wire [63:0] c_at_a, c_at_b;
	wire [3:0] c_at_stage;
	wire [31:0] w_at_old;
	wire w_at_err;

	wire u_m1_v, u_m1_l;
	wire [701:0] u_m1_t;
	wire [15:0] u_m1_i;
	wire u_sa1_pv, u_sa1_pr, u_sa1_cv;
	wire [NPHYS*32-1:0] u_sa1_pd;
	wire [31:0] u_sa1_cd;

	/* SU 0 (West) */
	atg_su_tile #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(2),
		.SU_INDEX(0), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.SHARED_PT(SHARED_PT), .HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU),
		.SU_RW(SU_RW), .ROUTE_D(ROUTE_D0), .ROUTE_I(ROUTE_I0),
		.RBIT_SU(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) su0 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(b_st_we[0]), .st_idx(b_st_idx0), .st_wdata(b_st_wdata0),
		.cs_kick(b_cs_kick[0]), .cs_mesh(b_cs_mesh[0]), .lc_kick(b_lc_kick[0]), .inv(b_inv0),
		.scrub(b_scrub[0]), .session_id(b_sess0),
		.vl_req(c_vl_req[0]), .vl_gnt(c_vl_gnt[0]), .vl_ptbase(c_vl_ptbase[0*8 +: 8]), .vl_avail(c_vl_avail[0]),
		.vl_we(c_vl_we[0]), .vl_reg(w_vl_reg), .vl_lane(w_vl_lane), .vl_data(w_vl_data),
		.vl_go(c_vl_go[0]), .vl_mask(w_vl_mask), .vl_go_ptbase(w_vl_go_ptbase),
		.fl_req(c_fl_req[0]), .fl_gnt(c_fl_gnt[0]), .fl_avail(c_fl_avail[0]),
		.fl_we(c_fl_we[0]), .fl_reg(w_fl_reg), .fl_lane(w_fl_lane), .fl_data(w_fl_data),
		.fl_pw_we(c_fl_pw_we[0]), .fl_pw_addr(w_fl_pw_addr), .fl_pw_data(w_fl_pw_data),
		.fl_go(c_fl_go[0]), .fl_mask(w_fl_mask), .fl_info(w_fl_info),
		.pt_rd(1'b0), .pt_idx(8'd0), .pt_word(7'd0), .pt_rdata(), .pt_free(1'b0), .pt_free_idx(8'd0), .pt_done(),
		.pt_exp_valid(c_pt_exp_v[0]), .pt_exp_ready(c_pt_exp_r[0]), .pt_exp_packed(c_pt_exp_d[0*PT_W +: PT_W]),
		.tx_valid(c_tx_v[0]), .tx_ready(c_tx_r[0]), .tx_op(c_tx_op[0*8 +: 8]),
		.tx_slot(c_tx_slot[0*4 +: 4]), .tx_samp_slot(c_tx_samp[0*4 +: 4]), .tx_vs(c_tx_vs[0]),
		.tx_mask(c_tx_mask[0*4 +: 4]), .tx_coord(c_tx_coord[0*640 +: 640]), .tx_off(c_tx_off[0*12 +: 12]),
		.tx_tag(c_tx_tag[0*16 +: 16]), .tx_last(c_tx_l[0]),
		.tr_valid(c_tr_v[0]), .tr_ready(c_tr_r[0]), .tr_tag(c_tr_tag[0*16 +: 16]),
		.tr_data(c_tr_data[0*512 +: 512]), .tr_last(c_tr_l[0]),
		.ex_valid(c_ex_v[0]), .ex_ready(c_ex_r[0]), .ex_seq(c_ex_seq[0*16 +: 16]),
		.ex_xy(c_ex_xy[0*32 +: 32]), .ex_mask(c_ex_mask[0*4 +: 4]),
		.ex_color(c_ex_col[0*512 +: 512]), .ex_color1(c_ex_col1[0*512 +: 512]),
		.ex_has_src1(c_ex_hs1[0]), .ex_depth(c_ex_dep[0*128 +: 128]), .ex_last(c_ex_l[0]),
		.ex_next(w_ex_next), .ex_aux(c_ex_aux[0*155 +: 155]),
		.mesh_valid(su0_mesh_valid), .mesh_ready(su0_mesh_ready), .mesh_tri(su0_mesh_tri),
		.mesh_last(su0_mesh_last), .mesh_id(su0_mesh_id),
		.t_req_valid(s_req_v[0]), .t_req_ready(s_req_r[0]), .t_req_data(s_req_d0), .t_req_last(s_req_l[0]),
		.t_rsp_valid(s_rsp_v[0]), .t_rsp_ready(s_rsp_r[0]), .t_rsp_data(s_rsp_d0),
		.at_valid(c_at_v[0]), .at_stage(c_at_stage[0*2 +: 2]), .at_ready(c_at_r[0]),
		.at_op(c_at_op[0*4 +: 4]), .at_addr(c_at_addr[0*30 +: 30]),
		.at_a(c_at_a[0*32 +: 32]), .at_b(c_at_b[0*32 +: 32]),
		.at_rsp_valid(c_at_rsp_v[0]), .at_old(w_at_old), .at_error(w_at_err),
		.sa_push_valid(su0_sa_push_valid), .sa_push_ready(su0_sa_push_ready), .sa_push_data(su0_sa_push_data),
		.sa_pop_valid(su0_sa_pop_valid), .sa_pop_ready(su0_sa_pop_ready), .sa_pop_data(su0_sa_pop_data),
		.sa_ctl_valid(su0_sa_ctl_valid), .sa_ctl_data(su0_sa_ctl_data),
		.sa_qstat(su0_sa_qstat), .sa_stat(su0_sa_stat), .sa_qtag(su0_sa_qtag),
		.busy(s_busy[0]), .scrub_busy(s_scrub_busy[0]), .fault(s_fault[0]),
		.fault_addr(s_faddr0), .fault_stage(s_fstage0), .fsm(fsm0)
	);

	/* SU 1 (East) */
	atg_su_tile #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(2),
		.SU_INDEX(1), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.SHARED_PT(SHARED_PT), .HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU),
		.SU_RW(SU_RW), .ROUTE_D(ROUTE_D1), .ROUTE_I(ROUTE_I1),
		.RBIT_SU(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) su1 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(b_st_we[1]), .st_idx(b_st_idx1), .st_wdata(b_st_wdata1),
		.cs_kick(b_cs_kick[1]), .cs_mesh(b_cs_mesh[1]), .lc_kick(b_lc_kick[1]), .inv(b_inv1),
		.scrub(b_scrub[1]), .session_id(b_sess1),
		.vl_req(c_vl_req[1]), .vl_gnt(c_vl_gnt[1]), .vl_ptbase(c_vl_ptbase[1*8 +: 8]), .vl_avail(c_vl_avail[1]),
		.vl_we(c_vl_we[1]), .vl_reg(w_vl_reg), .vl_lane(w_vl_lane), .vl_data(w_vl_data),
		.vl_go(c_vl_go[1]), .vl_mask(w_vl_mask), .vl_go_ptbase(w_vl_go_ptbase),
		.fl_req(c_fl_req[1]), .fl_gnt(c_fl_gnt[1]), .fl_avail(c_fl_avail[1]),
		.fl_we(c_fl_we[1]), .fl_reg(w_fl_reg), .fl_lane(w_fl_lane), .fl_data(w_fl_data),
		.fl_pw_we(c_fl_pw_we[1]), .fl_pw_addr(w_fl_pw_addr), .fl_pw_data(w_fl_pw_data),
		.fl_go(c_fl_go[1]), .fl_mask(w_fl_mask), .fl_info(w_fl_info),
		.pt_rd(1'b0), .pt_idx(8'd0), .pt_word(7'd0), .pt_rdata(), .pt_free(1'b0), .pt_free_idx(8'd0), .pt_done(),
		.pt_exp_valid(c_pt_exp_v[1]), .pt_exp_ready(c_pt_exp_r[1]), .pt_exp_packed(c_pt_exp_d[1*PT_W +: PT_W]),
		.tx_valid(c_tx_v[1]), .tx_ready(c_tx_r[1]), .tx_op(c_tx_op[1*8 +: 8]),
		.tx_slot(c_tx_slot[1*4 +: 4]), .tx_samp_slot(c_tx_samp[1*4 +: 4]), .tx_vs(c_tx_vs[1]),
		.tx_mask(c_tx_mask[1*4 +: 4]), .tx_coord(c_tx_coord[1*640 +: 640]), .tx_off(c_tx_off[1*12 +: 12]),
		.tx_tag(c_tx_tag[1*16 +: 16]), .tx_last(c_tx_l[1]),
		.tr_valid(c_tr_v[1]), .tr_ready(c_tr_r[1]), .tr_tag(c_tr_tag[1*16 +: 16]),
		.tr_data(c_tr_data[1*512 +: 512]), .tr_last(c_tr_l[1]),
		.ex_valid(c_ex_v[1]), .ex_ready(c_ex_r[1]), .ex_seq(c_ex_seq[1*16 +: 16]),
		.ex_xy(c_ex_xy[1*32 +: 32]), .ex_mask(c_ex_mask[1*4 +: 4]),
		.ex_color(c_ex_col[1*512 +: 512]), .ex_color1(c_ex_col1[1*512 +: 512]),
		.ex_has_src1(c_ex_hs1[1]), .ex_depth(c_ex_dep[1*128 +: 128]), .ex_last(c_ex_l[1]),
		.ex_next(w_ex_next), .ex_aux(c_ex_aux[1*155 +: 155]),
		.mesh_valid(u_m1_v), .mesh_ready(1'b1), .mesh_tri(u_m1_t), .mesh_last(u_m1_l), .mesh_id(u_m1_i),
		.t_req_valid(s_req_v[1]), .t_req_ready(s_req_r[1]), .t_req_data(s_req_d1), .t_req_last(s_req_l[1]),
		.t_rsp_valid(s_rsp_v[1]), .t_rsp_ready(s_rsp_r[1]), .t_rsp_data(s_rsp_d1),
		.at_valid(c_at_v[1]), .at_stage(c_at_stage[1*2 +: 2]), .at_ready(c_at_r[1]),
		.at_op(c_at_op[1*4 +: 4]), .at_addr(c_at_addr[1*30 +: 30]),
		.at_a(c_at_a[1*32 +: 32]), .at_b(c_at_b[1*32 +: 32]),
		.at_rsp_valid(c_at_rsp_v[1]), .at_old(w_at_old), .at_error(w_at_err),
		.sa_push_valid(u_sa1_pv), .sa_push_ready(1'b0), .sa_push_data(u_sa1_pd),
		.sa_pop_valid(1'b0), .sa_pop_ready(u_sa1_pr), .sa_pop_data({(NPHYS*32){1'b0}}),
		.sa_ctl_valid(u_sa1_cv), .sa_ctl_data(u_sa1_cd),
		.sa_qstat(32'd0), .sa_stat(32'd0), .sa_qtag(32'd0),
		.busy(s_busy[1]), .scrub_busy(s_scrub_busy[1]), .fault(s_fault[1]),
		.fault_addr(s_faddr1), .fault_stage(s_fstage1), .fsm(fsm1_unused)
	);

	/* Horizontal repeaters rep_h(1) on West (su0) and East (su1) links */
	wire u_rep0_idle, u_rep1_idle, u_rt2_idle;
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_w (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(s_req_v[0]), .dn_req_ready(s_req_r[0]), .dn_req_data(s_req_d0), .dn_req_last(s_req_l[0]),
		.up_req_valid(r_req_v[0]), .up_req_ready(r_req_r[0]), .up_req_data(r_req_d0), .up_req_last(r_req_l[0]),
		.up_rsp_valid(r_rsp_v[0]), .up_rsp_ready(r_rsp_r[0]), .up_rsp_data(r_rsp_d0),
		.dn_rsp_valid(s_rsp_v[0]), .dn_rsp_ready(s_rsp_r[0]), .dn_rsp_data(s_rsp_d0), .rsp_idle(u_rep0_idle),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(b_st_we[0]), .out_st_idx(b_st_idx0), .out_st_wdata(b_st_wdata0),
		.out_cs_kick(b_cs_kick[0]), .out_cs_mesh(b_cs_mesh[0]), .out_lc_kick(b_lc_kick[0]),
		.out_inv(b_inv0), .out_scrub(b_scrub[0]), .out_session_id(b_sess0),
		.in_busy(s_busy[0]), .in_scrub_busy(s_scrub_busy[0]), .in_fault(s_fault[0]),
		.in_fault_addr(s_faddr0), .in_fault_stage(s_fstage0),
		.out_busy(b_busy[0]), .out_scrub_busy(b_scrub_busy[0]), .out_fault(b_fault[0]),
		.out_fault_addr(b_faddr0), .out_fault_stage(b_fstage0)
	);

	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_e (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(s_req_v[1]), .dn_req_ready(s_req_r[1]), .dn_req_data(s_req_d1), .dn_req_last(s_req_l[1]),
		.up_req_valid(r_req_v[1]), .up_req_ready(r_req_r[1]), .up_req_data(r_req_d1), .up_req_last(r_req_l[1]),
		.up_rsp_valid(r_rsp_v[1]), .up_rsp_ready(r_rsp_r[1]), .up_rsp_data(r_rsp_d1),
		.dn_rsp_valid(s_rsp_v[1]), .dn_rsp_ready(s_rsp_r[1]), .dn_rsp_data(s_rsp_d1), .rsp_idle(u_rep1_idle),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(b_st_we[1]), .out_st_idx(b_st_idx1), .out_st_wdata(b_st_wdata1),
		.out_cs_kick(b_cs_kick[1]), .out_cs_mesh(b_cs_mesh[1]), .out_lc_kick(b_lc_kick[1]),
		.out_inv(b_inv1), .out_scrub(b_scrub[1]), .out_session_id(b_sess1),
		.in_busy(s_busy[1]), .in_scrub_busy(s_scrub_busy[1]), .in_fault(s_fault[1]),
		.in_fault_addr(s_faddr1), .in_fault_stage(s_fstage1),
		.out_busy(b_busy[1]), .out_scrub_busy(b_scrub_busy[1]), .out_fault(b_fault[1]),
		.out_fault_addr(b_faddr1), .out_fault_stage(b_fstage1)
	);

	atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(10)) u_rt2_top (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(r_req_v[0]), .c0_req_ready(r_req_r[0]), .c0_req_data(r_req_d0), .c0_req_last(r_req_l[0]),
		.c1_req_valid(r_req_v[1]), .c1_req_ready(r_req_r[1]), .c1_req_data(r_req_d1), .c1_req_last(r_req_l[1]),
		.p_req_valid(trunk_req_valid[0]), .p_req_ready(trunk_req_ready[0]),
		.p_req_data(trunk_req_data), .p_req_last(trunk_req_last[0]),
		.p_rsp_valid(trunk_rsp_valid[0]), .p_rsp_ready(trunk_rsp_ready[0]), .p_rsp_data(trunk_rsp_data),
		.c0_rsp_valid(r_rsp_v[0]), .c0_rsp_ready(r_rsp_r[0]), .c0_rsp_data(r_rsp_d0),
		.c1_rsp_valid(r_rsp_v[1]), .c1_rsp_ready(r_rsp_r[1]), .c1_rsp_data(r_rsp_d1),
		.rsp_idle(u_rt2_idle)
	);

	/* K=2 Spine Warp Dist, PT Export, TU, ROP, Atomics */
	generate
	if (HAS_GFX != 0) begin : g_n2_gfx
		atg_warp_dist #(.K(2)) u_wdist (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(vl_req), .p_vl_gnt(vl_gnt), .p_vl_ptbase(vl_ptbase), .p_vl_avail(vl_avail),
			.p_vl_we(vl_we), .p_vl_reg(vl_reg), .p_vl_lane(vl_lane), .p_vl_data(vl_data),
			.p_vl_go(vl_go), .p_vl_mask(vl_mask), .p_vl_go_ptbase(vl_go_ptbase),
			.c_vl_req(c_vl_req), .c_vl_gnt(c_vl_gnt), .c_vl_ptbase(c_vl_ptbase), .c_vl_avail(c_vl_avail),
			.c_vl_we(c_vl_we), .c_vl_reg(w_vl_reg), .c_vl_lane(w_vl_lane), .c_vl_data(w_vl_data),
			.c_vl_go(c_vl_go), .c_vl_mask(w_vl_mask), .c_vl_go_ptbase(w_vl_go_ptbase),
			.p_fl_req(fl_req), .p_fl_gnt(fl_gnt), .p_fl_avail(fl_avail),
			.p_fl_we(fl_we), .p_fl_reg(fl_reg), .p_fl_lane(fl_lane), .p_fl_data(fl_data),
			.p_fl_pw_we(fl_pw_we), .p_fl_pw_addr(fl_pw_addr), .p_fl_pw_data(fl_pw_data),
			.p_fl_go(fl_go), .p_fl_mask(fl_mask), .p_fl_info(fl_info),
			.c_fl_req(c_fl_req), .c_fl_gnt(c_fl_gnt), .c_fl_avail(c_fl_avail),
			.c_fl_we(c_fl_we), .c_fl_reg(w_fl_reg), .c_fl_lane(w_fl_lane), .c_fl_data(w_fl_data),
			.c_fl_pw_we(c_fl_pw_we), .c_fl_pw_addr(w_fl_pw_addr), .c_fl_pw_data(w_fl_pw_data),
			.c_fl_go(c_fl_go), .c_fl_mask(w_fl_mask), .c_fl_info(w_fl_info)
		);
		atg_pt_exp_rt #(.K(2), .W(PT_W)) u_ptrt (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v), .c_ready(c_pt_exp_r), .c_data(c_pt_exp_d),
			.p_valid(pt_exp_valid), .p_ready(pt_exp_ready), .p_data(pt_exp_packed)
		);
	end else begin : g_n2_nogfx
		assign vl_gnt = 1'b0;
		assign vl_ptbase = 8'd0;
		assign vl_avail = 1'b0;
		assign fl_gnt = 1'b0;
		assign fl_avail = 1'b0;
		assign pt_exp_valid = 1'b0;
		assign pt_exp_packed = {PT_W{1'b0}};
		assign c_vl_req = 2'd0;
		assign c_vl_we = 2'd0;
		assign c_vl_go = 2'd0;
		assign w_vl_reg = 6'd0;
		assign w_vl_lane = 5'd0;
		assign w_vl_data = 32'd0;
		assign w_vl_mask = 32'd0;
		assign w_vl_go_ptbase = 8'd0;
		assign c_fl_req = 2'd0;
		assign c_fl_we = 2'd0;
		assign c_fl_pw_we = 2'd0;
		assign c_fl_go = 2'd0;
		assign w_fl_reg = 6'd0;
		assign w_fl_lane = 5'd0;
		assign w_fl_data = 32'd0;
		assign w_fl_pw_addr = 12'd0;
		assign w_fl_pw_data = 32'd0;
		assign w_fl_mask = 32'd0;
		assign w_fl_info = 64'd0;
		assign c_pt_exp_r = 2'b11;
	end

	if (HAS_TU != 0) begin : g_n2_tu
		atg_tx_rt #(.K(2), .TBIT(15)) u_txrt (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v), .c_tx_ready(c_tx_r), .c_tx_op(c_tx_op),
			.c_tx_slot(c_tx_slot), .c_tx_samp_slot(c_tx_samp), .c_tx_vs(c_tx_vs),
			.c_tx_mask(c_tx_mask), .c_tx_coord(c_tx_coord), .c_tx_off(c_tx_off),
			.c_tx_tag(c_tx_tag), .c_tx_last(c_tx_l),
			.c_tr_valid(c_tr_v), .c_tr_ready(c_tr_r), .c_tr_tag(c_tr_tag),
			.c_tr_data(c_tr_data), .c_tr_last(c_tr_l),
			.p_tx_valid(tx_valid), .p_tx_ready(tx_ready), .p_tx_op(tx_op),
			.p_tx_slot(tx_slot), .p_tx_samp_slot(tx_samp_slot), .p_tx_vs(tx_vs),
			.p_tx_mask(tx_mask), .p_tx_coord(tx_coord), .p_tx_off(tx_off),
			.p_tx_tag(tx_tag), .p_tx_last(tx_last),
			.p_tr_valid(tr_valid), .p_tr_ready(tr_ready), .p_tr_tag(tr_tag),
			.p_tr_data(tr_data), .p_tr_last(tr_last)
		);
	end else begin : g_n2_notu
		assign tx_valid = 1'b0;
		assign tx_op = 8'd0;
		assign tx_slot = 4'd0;
		assign tx_samp_slot = 4'd0;
		assign tx_vs = 1'b0;
		assign tx_mask = 4'd0;
		assign tx_coord = 640'd0;
		assign tx_off = 12'd0;
		assign tx_tag = 16'd0;
		assign tx_last = 1'b0;
		assign tr_ready = 1'b1;
		assign c_tx_r = 2'd0;
		assign c_tr_v = 2'd0;
		assign c_tr_tag = 32'd0;
		assign c_tr_data = 1024'd0;
		assign c_tr_l = 2'd0;
	end

	if (HAS_ROP != 0) begin : g_n2_rop
		atg_ex_rt #(.K(2)) u_exrt (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v), .c_ex_ready(c_ex_r), .c_ex_seq(c_ex_seq),
			.c_ex_xy(c_ex_xy), .c_ex_mask(c_ex_mask), .c_ex_color(c_ex_col),
			.c_ex_color1(c_ex_col1), .c_ex_has_src1(c_ex_hs1), .c_ex_depth(c_ex_dep),
			.c_ex_last(c_ex_l), .c_ex_aux(c_ex_aux), .c_ex_next(w_ex_next),
			.p_ex_valid(ex_valid), .p_ex_ready(ex_ready), .p_ex_seq(ex_seq),
			.p_ex_xy(ex_xy), .p_ex_mask(ex_mask), .p_ex_color(ex_color),
			.p_ex_color1(ex_color1), .p_ex_has_src1(ex_has_src1), .p_ex_depth(ex_depth),
			.p_ex_last(ex_last), .p_ex_aux(ex_aux), .p_ex_next(ex_next)
		);
	end else begin : g_n2_norop
		assign ex_valid = 1'b0;
		assign ex_seq = 16'd0;
		assign ex_xy = 32'd0;
		assign ex_mask = 4'd0;
		assign ex_color = 512'd0;
		assign ex_color1 = 512'd0;
		assign ex_has_src1 = 1'b0;
		assign ex_depth = 128'd0;
		assign ex_last = 1'b0;
		assign ex_aux = 155'd0;
		assign c_ex_r = 2'd0;
		assign w_ex_next = 16'd0;
	end
	endgenerate

	atg_atom_rt #(.K(2), .ATOM_AW(30)) u_atomrt (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v), .c_at_ready(c_at_r), .c_at_op(c_at_op),
		.c_at_addr(c_at_addr), .c_at_a(c_at_a), .c_at_b(c_at_b), .c_at_stage(c_at_stage),
		.c_at_rsp_valid(c_at_rsp_v), .c_at_old(w_at_old), .c_at_error(w_at_err),
		.p_at_valid(at_valid), .p_at_ready(at_ready), .p_at_op(at_op),
		.p_at_addr(at_addr), .p_at_a(at_a), .p_at_b(at_b), .p_at_stage(at_stage),
		.p_at_rsp_valid(at_rsp_valid), .p_at_old(at_old), .p_at_error(at_error)
	);

	/* Keep busy high while kick traverses 1-stage rep_h(1) down and status back up */
	reg [2:0] kick_flight_sr;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			kick_flight_sr <= 3'd0;
		else
			kick_flight_sr <= {kick_flight_sr[1:0], cs_kick || lc_kick};
	end

	assign busy = (|b_busy) || (|kick_flight_sr);
	assign scrub_busy = |b_scrub_busy;
	assign fault = |b_fault;
	assign fault_addr = b_fault[0] ? b_faddr0 : (b_fault[1] ? b_faddr1 : 32'd0);
	assign fault_stage = b_fault[0] ? b_fstage0 : (b_fault[1] ? b_fstage1 : 4'd0);

	wire unused_ok = &{1'b0, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx,
		u_rep0_idle, u_rep1_idle, u_rt2_idle, fsm1_unused,
		u_m1_v, u_m1_l, u_m1_t, u_m1_i, u_sa1_pv, u_sa1_pr, u_sa1_pd, u_sa1_cv, u_sa1_cd};
endmodule

`default_nettype wire
