/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fabric_n32: Explicit 2D physical fabric for N = 32 SUs (8x4: 8 Quads).
 * Matches docs/svg/floorplan/floorplan_n32.svg:
 *
 *   W_NW (Q0, rep_h(2)) + W_NE (Q1, rep_h(1)) -> rt2_wn -> rep_v(2) -> Trunk 0
 *   E_NW (Q4, rep_h(1)) + E_NE (Q5, rep_h(2)) -> rt2_en -> rep_v(2) -> Trunk 1
 *   W_SW (Q2, rep_h(2)) + W_SE (Q3, rep_h(1)) -> rt2_ws -> rep_v(1) -> Trunk 2
 *   E_SW (Q6, rep_h(1)) + E_SE (Q7, rep_h(2)) -> rt2_es -> rep_v(1) -> Trunk 3
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fabric_n32 #(
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
	parameter PT_ENTRIES = 256,
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
	parameter SU_RW = 4,
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

	/* Local PT stub */
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

	/* 4 Parallel NoC Trunks (0: W_N, 1: E_N, 2: W_S, 3: E_S) */
	output wire [3:0] trunk_req_valid,
	input wire [3:0] trunk_req_ready,
	output wire [4*FW-1:0] trunk_req_data,
	output wire [3:0] trunk_req_last,
	input wire [3:0] trunk_rsp_valid,
	output wire [3:0] trunk_rsp_ready,
	input wire [4*RFW-1:0] trunk_rsp_data,

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

	/* Quad-level signals (q0..q7) */
	wire [7:0] q_req_v, q_req_r, q_req_l, q_rsp_v, q_rsp_r;
	wire [FW-1:0] q_req_d0, q_req_d1, q_req_d2, q_req_d3, q_req_d4, q_req_d5, q_req_d6, q_req_d7;
	wire [RFW-1:0] q_rsp_d0, q_rsp_d1, q_rsp_d2, q_rsp_d3, q_rsp_d4, q_rsp_d5, q_rsp_d6, q_rsp_d7;

	wire [7:0] rh_req_v, rh_req_r, rh_req_l, rh_rsp_v, rh_rsp_r;
	wire [FW-1:0] rh_req_d0, rh_req_d1, rh_req_d2, rh_req_d3, rh_req_d4, rh_req_d5, rh_req_d6, rh_req_d7;
	wire [RFW-1:0] rh_rsp_d0, rh_rsp_d1, rh_rsp_d2, rh_rsp_d3, rh_rsp_d4, rh_rsp_d5, rh_rsp_d6, rh_rsp_d7;

	wire [3:0] rt2_req_v, rt2_req_r, rt2_req_l, rt2_rsp_v, rt2_rsp_r;
	wire [FW-1:0] rt2_req_d0, rt2_req_d1, rt2_req_d2, rt2_req_d3;
	wire [RFW-1:0] rt2_rsp_d0, rt2_rsp_d1, rt2_rsp_d2, rt2_rsp_d3;

	/* Control & Status repeater chains: rep_v (0:wn, 1:en, 2:ws, 3:es) -> rep_h (0..7) */
	wire [3:0] rv_st_we, rv_cs_kick, rv_cs_mesh, rv_lc_kick, rv_scrub;
	wire [8:0] rv_st_idx0, rv_st_idx1, rv_st_idx2, rv_st_idx3;
	wire [31:0] rv_st_wdata0, rv_st_wdata1, rv_st_wdata2, rv_st_wdata3;
	wire [3:0] rv_inv0, rv_inv1, rv_inv2, rv_inv3, rv_sess0, rv_sess1, rv_sess2, rv_sess3;

	wire [7:0] q_st_we, q_cs_kick, q_cs_mesh, q_lc_kick, q_scrub;
	wire [8:0] q_st_idx0, q_st_idx1, q_st_idx2, q_st_idx3, q_st_idx4, q_st_idx5, q_st_idx6, q_st_idx7;
	wire [31:0] q_st_wdata0, q_st_wdata1, q_st_wdata2, q_st_wdata3, q_st_wdata4, q_st_wdata5, q_st_wdata6, q_st_wdata7;
	wire [3:0] q_inv0, q_inv1, q_inv2, q_inv3, q_inv4, q_inv5, q_inv6, q_inv7;
	wire [3:0] q_sess0, q_sess1, q_sess2, q_sess3, q_sess4, q_sess5, q_sess6, q_sess7;

	wire [7:0] q_busy_in, q_scrub_in, q_fault_in;
	wire [31:0] q_faddr_in0, q_faddr_in1, q_faddr_in2, q_faddr_in3, q_faddr_in4, q_faddr_in5, q_faddr_in6, q_faddr_in7;
	wire [3:0] q_fstage_in0, q_fstage_in1, q_fstage_in2, q_fstage_in3, q_fstage_in4, q_fstage_in5, q_fstage_in6, q_fstage_in7;

	wire [7:0] rh_busy_out, rh_scrub_out, rh_fault_out;
	wire [31:0] rh_faddr_out0, rh_faddr_out1, rh_faddr_out2, rh_faddr_out3, rh_faddr_out4, rh_faddr_out5, rh_faddr_out6, rh_faddr_out7;
	wire [3:0] rh_fstage_out0, rh_fstage_out1, rh_fstage_out2, rh_fstage_out3, rh_fstage_out4, rh_fstage_out5, rh_fstage_out6, rh_fstage_out7;

	wire [3:0] b_busy, b_scrub_busy, b_fault;
	wire [31:0] b_faddr0, b_faddr1, b_faddr2, b_faddr3;
	wire [3:0] b_fstage0, b_fstage1, b_fstage2, b_fstage3;
	wire [3:0] rv_rsp_idle;
	wire [7:0] rh_rsp_idle;

	wire [15:0] q_fsm0, q_fsm1, q_fsm2, q_fsm3, q_fsm4, q_fsm5, q_fsm6, q_fsm7;
	assign fsm0 = q_fsm0[3:0];

	/* Spine buses: root (K=4 pairs: 0=wn, 1=en, 2=ws, 3=es) -> pair K=2 -> q0..q7 */
	wire [7:0] c_vl_req, c_vl_gnt, c_vl_avail, c_vl_we, c_vl_go;
	wire [63:0] c_vl_ptbase;
	wire [5:0] w_vl_reg;
	wire [4:0] w_vl_lane;
	wire [31:0] w_vl_data, w_vl_mask;
	wire [7:0] w_vl_go_ptbase;

	wire [7:0] c_fl_req, c_fl_gnt, c_fl_avail, c_fl_we, c_fl_pw_we, c_fl_go;
	wire [5:0] w_fl_reg;
	wire [4:0] w_fl_lane;
	wire [31:0] w_fl_data, w_fl_pw_data, w_fl_mask;
	wire [11:0] w_fl_pw_addr;
	wire [63:0] w_fl_info;

	wire [7:0] c_pt_exp_v, c_pt_exp_r;
	wire [8*PT_W-1:0] c_pt_exp_d;

	wire [7:0] c_tx_v, c_tx_r, c_tx_vs, c_tx_l, c_tr_v, c_tr_r, c_tr_l;
	wire [63:0] c_tx_op;
	wire [31:0] c_tx_slot, c_tx_samp, c_tx_mask;
	wire [8*640-1:0] c_tx_coord;
	wire [95:0] c_tx_off;
	wire [127:0] c_tx_tag, c_tr_tag;
	wire [8*512-1:0] c_tr_data;

	wire [7:0] c_ex_v, c_ex_r, c_ex_hs1, c_ex_l;
	wire [127:0] c_ex_seq;
	wire [255:0] c_ex_xy;
	wire [31:0] c_ex_mask;
	wire [8*512-1:0] c_ex_col, c_ex_col1;
	wire [1023:0] c_ex_dep;
	wire [8*155-1:0] c_ex_aux;
	wire [15:0] w_ex_next;

	wire [7:0] c_at_v, c_at_r, c_at_rsp_v;
	wire [31:0] c_at_op;
	wire [239:0] c_at_addr;
	wire [255:0] c_at_a, c_at_b;
	wire [15:0] c_at_stage;
	wire [31:0] w_at_old;
	wire w_at_err;

	/* Pair-level K=4 Spine wires (0=wn, 1=en, 2=ws, 3=es) */
	wire [3:0] p_vl_req, p_vl_gnt, p_vl_avail, p_vl_we, p_vl_go;
	wire [31:0] p_vl_ptbase;
	wire [5:0] p_vl_reg0, p_vl_reg1, p_vl_reg2, p_vl_reg3;
	wire [4:0] p_vl_lane0, p_vl_lane1, p_vl_lane2, p_vl_lane3;
	wire [31:0] p_vl_data0, p_vl_data1, p_vl_data2, p_vl_data3;
	wire [31:0] p_vl_mask0, p_vl_mask1, p_vl_mask2, p_vl_mask3;
	wire [7:0] p_vl_go_ptbase0, p_vl_go_ptbase1, p_vl_go_ptbase2, p_vl_go_ptbase3;

	wire [3:0] p_fl_req, p_fl_gnt, p_fl_avail, p_fl_we, p_fl_pw_we, p_fl_go;
	wire [5:0] p_fl_reg0, p_fl_reg1, p_fl_reg2, p_fl_reg3;
	wire [4:0] p_fl_lane0, p_fl_lane1, p_fl_lane2, p_fl_lane3;
	wire [31:0] p_fl_data0, p_fl_data1, p_fl_data2, p_fl_data3;
	wire [11:0] p_fl_pw_addr0, p_fl_pw_addr1, p_fl_pw_addr2, p_fl_pw_addr3;
	wire [31:0] p_fl_pw_data0, p_fl_pw_data1, p_fl_pw_data2, p_fl_pw_data3;
	wire [31:0] p_fl_mask0, p_fl_mask1, p_fl_mask2, p_fl_mask3;
	wire [63:0] p_fl_info0, p_fl_info1, p_fl_info2, p_fl_info3;

	wire [3:0] p_pt_exp_v, p_pt_exp_r;
	wire [4*PT_W-1:0] p_pt_exp_d;

	wire [3:0] p_tx_v, p_tx_r, p_tx_vs, p_tx_l, p_tr_v, p_tr_r, p_tr_l;
	wire [31:0] p_tx_op;
	wire [15:0] p_tx_slot, p_tx_samp, p_tx_mask;
	wire [4*640-1:0] p_tx_coord;
	wire [47:0] p_tx_off;
	wire [63:0] p_tx_tag, p_tr_tag;
	wire [4*512-1:0] p_tr_data;

	wire [3:0] p_ex_v, p_ex_r, p_ex_hs1, p_ex_l;
	wire [63:0] p_ex_seq;
	wire [127:0] p_ex_xy;
	wire [15:0] p_ex_mask;
	wire [4*512-1:0] p_ex_col, p_ex_col1;
	wire [511:0] p_ex_dep;
	wire [4*155-1:0] p_ex_aux;
	wire [63:0] p_ex_next;

	wire [3:0] p_at_v, p_at_r, p_at_rsp_v;
	wire [15:0] p_at_op;
	wire [119:0] p_at_addr;
	wire [127:0] p_at_a, p_at_b;
	wire [7:0] p_at_stage;
	wire [127:0] p_at_old;
	wire [3:0] p_at_err;

	/* Unused SU0 mesh/sa stubs for quads q1..q7 */
	wire [7:1] u_q_mv, u_q_ml, u_q_spv, u_q_spr, u_q_scv;
	wire [701:0] u_q_mt1, u_q_mt2, u_q_mt3, u_q_mt4, u_q_mt5, u_q_mt6, u_q_mt7;
	wire [15:0] u_q_mi1, u_q_mi2, u_q_mi3, u_q_mi4, u_q_mi5, u_q_mi6, u_q_mi7;
	wire [NPHYS*32-1:0] u_q_spd1, u_q_spd2, u_q_spd3, u_q_spd4, u_q_spd5, u_q_spd6, u_q_spd7;
	wire [31:0] u_q_scd1, u_q_scd2, u_q_scd3, u_q_scd4, u_q_scd5, u_q_scd6, u_q_scd7;

	/* Q0: W_NW (SU 0..3) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(0), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd0),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q0 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[0]), .st_idx(q_st_idx0), .st_wdata(q_st_wdata0),
		.cs_kick(q_cs_kick[0]), .cs_mesh(q_cs_mesh[0]), .lc_kick(q_lc_kick[0]), .inv(q_inv0),
		.scrub(q_scrub[0]), .session_id(q_sess0),
		.p_vl_req(c_vl_req[0]), .p_vl_gnt(c_vl_gnt[0]), .p_vl_ptbase(c_vl_ptbase[0*8 +: 8]), .p_vl_avail(c_vl_avail[0]),
		.p_vl_we(c_vl_we[0]), .p_vl_reg(p_vl_reg0), .p_vl_lane(p_vl_lane0), .p_vl_data(p_vl_data0),
		.p_vl_go(c_vl_go[0]), .p_vl_mask(p_vl_mask0), .p_vl_go_ptbase(p_vl_go_ptbase0),
		.p_fl_req(c_fl_req[0]), .p_fl_gnt(c_fl_gnt[0]), .p_fl_avail(c_fl_avail[0]),
		.p_fl_we(c_fl_we[0]), .p_fl_reg(p_fl_reg0), .p_fl_lane(p_fl_lane0), .p_fl_data(p_fl_data0),
		.p_fl_pw_we(c_fl_pw_we[0]), .p_fl_pw_addr(p_fl_pw_addr0), .p_fl_pw_data(p_fl_pw_data0),
		.p_fl_go(c_fl_go[0]), .p_fl_mask(p_fl_mask0), .p_fl_info(p_fl_info0),
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
		.p_ex_aux(c_ex_aux[0*155 +: 155]), .p_ex_next(p_ex_next[0*16 +: 16]),
		.t_req_valid(q_req_v[0]), .t_req_ready(q_req_r[0]), .t_req_data(q_req_d0), .t_req_last(q_req_l[0]),
		.t_rsp_valid(q_rsp_v[0]), .t_rsp_ready(q_rsp_r[0]), .t_rsp_data(q_rsp_d0),
		.p_at_valid(c_at_v[0]), .p_at_ready(c_at_r[0]), .p_at_op(c_at_op[0*4 +: 4]),
		.p_at_addr(c_at_addr[0*30 +: 30]), .p_at_a(c_at_a[0*32 +: 32]), .p_at_b(c_at_b[0*32 +: 32]),
		.p_at_stage(c_at_stage[0*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[0]), .p_at_old(p_at_old[0*32 +: 32]), .p_at_error(p_at_err[0]),
		.su0_mesh_valid(su0_mesh_valid), .su0_mesh_ready(su0_mesh_ready), .su0_mesh_tri(su0_mesh_tri),
		.su0_mesh_last(su0_mesh_last), .su0_mesh_id(su0_mesh_id),
		.su0_sa_push_valid(su0_sa_push_valid), .su0_sa_push_ready(su0_sa_push_ready), .su0_sa_push_data(su0_sa_push_data),
		.su0_sa_pop_valid(su0_sa_pop_valid), .su0_sa_pop_ready(su0_sa_pop_ready), .su0_sa_pop_data(su0_sa_pop_data),
		.su0_sa_ctl_valid(su0_sa_ctl_valid), .su0_sa_ctl_data(su0_sa_ctl_data),
		.su0_sa_qstat(su0_sa_qstat), .su0_sa_stat(su0_sa_stat), .su0_sa_qtag(su0_sa_qtag),
		.busy(q_busy_in[0]), .scrub_busy(q_scrub_in[0]), .fault(q_fault_in[0]),
		.fault_addr(q_faddr_in0), .fault_stage(q_fstage_in0), .fsm_packed(q_fsm0)
	);

	/* Q1: W_NE (SU 4..7) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(4), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd1),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q1 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[1]), .st_idx(q_st_idx1), .st_wdata(q_st_wdata1),
		.cs_kick(q_cs_kick[1]), .cs_mesh(q_cs_mesh[1]), .lc_kick(q_lc_kick[1]), .inv(q_inv1),
		.scrub(q_scrub[1]), .session_id(q_sess1),
		.p_vl_req(c_vl_req[1]), .p_vl_gnt(c_vl_gnt[1]), .p_vl_ptbase(c_vl_ptbase[1*8 +: 8]), .p_vl_avail(c_vl_avail[1]),
		.p_vl_we(c_vl_we[1]), .p_vl_reg(p_vl_reg0), .p_vl_lane(p_vl_lane0), .p_vl_data(p_vl_data0),
		.p_vl_go(c_vl_go[1]), .p_vl_mask(p_vl_mask0), .p_vl_go_ptbase(p_vl_go_ptbase0),
		.p_fl_req(c_fl_req[1]), .p_fl_gnt(c_fl_gnt[1]), .p_fl_avail(c_fl_avail[1]),
		.p_fl_we(c_fl_we[1]), .p_fl_reg(p_fl_reg0), .p_fl_lane(p_fl_lane0), .p_fl_data(p_fl_data0),
		.p_fl_pw_we(c_fl_pw_we[1]), .p_fl_pw_addr(p_fl_pw_addr0), .p_fl_pw_data(p_fl_pw_data0),
		.p_fl_go(c_fl_go[1]), .p_fl_mask(p_fl_mask0), .p_fl_info(p_fl_info0),
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
		.p_ex_aux(c_ex_aux[1*155 +: 155]), .p_ex_next(p_ex_next[0*16 +: 16]),
		.t_req_valid(q_req_v[1]), .t_req_ready(q_req_r[1]), .t_req_data(q_req_d1), .t_req_last(q_req_l[1]),
		.t_rsp_valid(q_rsp_v[1]), .t_rsp_ready(q_rsp_r[1]), .t_rsp_data(q_rsp_d1),
		.p_at_valid(c_at_v[1]), .p_at_ready(c_at_r[1]), .p_at_op(c_at_op[1*4 +: 4]),
		.p_at_addr(c_at_addr[1*30 +: 30]), .p_at_a(c_at_a[1*32 +: 32]), .p_at_b(c_at_b[1*32 +: 32]),
		.p_at_stage(c_at_stage[1*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[1]), .p_at_old(p_at_old[0*32 +: 32]), .p_at_error(p_at_err[0]),
		.su0_mesh_valid(u_q_mv[1]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt1), .su0_mesh_last(u_q_ml[1]), .su0_mesh_id(u_q_mi1),
		.su0_sa_push_valid(u_q_spv[1]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd1),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[1]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[1]), .su0_sa_ctl_data(u_q_scd1),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[1]), .scrub_busy(q_scrub_in[1]), .fault(q_fault_in[1]),
		.fault_addr(q_faddr_in1), .fault_stage(q_fstage_in1), .fsm_packed(q_fsm1)
	);

	/* Q2: W_SW (SU 8..11) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(8), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd0),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q2 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[2]), .st_idx(q_st_idx2), .st_wdata(q_st_wdata2),
		.cs_kick(q_cs_kick[2]), .cs_mesh(q_cs_mesh[2]), .lc_kick(q_lc_kick[2]), .inv(q_inv2),
		.scrub(q_scrub[2]), .session_id(q_sess2),
		.p_vl_req(c_vl_req[2]), .p_vl_gnt(c_vl_gnt[2]), .p_vl_ptbase(c_vl_ptbase[2*8 +: 8]), .p_vl_avail(c_vl_avail[2]),
		.p_vl_we(c_vl_we[2]), .p_vl_reg(p_vl_reg2), .p_vl_lane(p_vl_lane2), .p_vl_data(p_vl_data2),
		.p_vl_go(c_vl_go[2]), .p_vl_mask(p_vl_mask2), .p_vl_go_ptbase(p_vl_go_ptbase2),
		.p_fl_req(c_fl_req[2]), .p_fl_gnt(c_fl_gnt[2]), .p_fl_avail(c_fl_avail[2]),
		.p_fl_we(c_fl_we[2]), .p_fl_reg(p_fl_reg2), .p_fl_lane(p_fl_lane2), .p_fl_data(p_fl_data2),
		.p_fl_pw_we(c_fl_pw_we[2]), .p_fl_pw_addr(p_fl_pw_addr2), .p_fl_pw_data(p_fl_pw_data2),
		.p_fl_go(c_fl_go[2]), .p_fl_mask(p_fl_mask2), .p_fl_info(p_fl_info2),
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
		.p_ex_aux(c_ex_aux[2*155 +: 155]), .p_ex_next(p_ex_next[2*16 +: 16]),
		.t_req_valid(q_req_v[2]), .t_req_ready(q_req_r[2]), .t_req_data(q_req_d2), .t_req_last(q_req_l[2]),
		.t_rsp_valid(q_rsp_v[2]), .t_rsp_ready(q_rsp_r[2]), .t_rsp_data(q_rsp_d2),
		.p_at_valid(c_at_v[2]), .p_at_ready(c_at_r[2]), .p_at_op(c_at_op[2*4 +: 4]),
		.p_at_addr(c_at_addr[2*30 +: 30]), .p_at_a(c_at_a[2*32 +: 32]), .p_at_b(c_at_b[2*32 +: 32]),
		.p_at_stage(c_at_stage[2*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[2]), .p_at_old(p_at_old[2*32 +: 32]), .p_at_error(p_at_err[2]),
		.su0_mesh_valid(u_q_mv[2]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt2), .su0_mesh_last(u_q_ml[2]), .su0_mesh_id(u_q_mi2),
		.su0_sa_push_valid(u_q_spv[2]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd2),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[2]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[2]), .su0_sa_ctl_data(u_q_scd2),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[2]), .scrub_busy(q_scrub_in[2]), .fault(q_fault_in[2]),
		.fault_addr(q_faddr_in2), .fault_stage(q_fstage_in2), .fsm_packed(q_fsm2)
	);

	/* Q3: W_SE (SU 12..15) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(12), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd1),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q3 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[3]), .st_idx(q_st_idx3), .st_wdata(q_st_wdata3),
		.cs_kick(q_cs_kick[3]), .cs_mesh(q_cs_mesh[3]), .lc_kick(q_lc_kick[3]), .inv(q_inv3),
		.scrub(q_scrub[3]), .session_id(q_sess3),
		.p_vl_req(c_vl_req[3]), .p_vl_gnt(c_vl_gnt[3]), .p_vl_ptbase(c_vl_ptbase[3*8 +: 8]), .p_vl_avail(c_vl_avail[3]),
		.p_vl_we(c_vl_we[3]), .p_vl_reg(p_vl_reg2), .p_vl_lane(p_vl_lane2), .p_vl_data(p_vl_data2),
		.p_vl_go(c_vl_go[3]), .p_vl_mask(p_vl_mask2), .p_vl_go_ptbase(p_vl_go_ptbase2),
		.p_fl_req(c_fl_req[3]), .p_fl_gnt(c_fl_gnt[3]), .p_fl_avail(c_fl_avail[3]),
		.p_fl_we(c_fl_we[3]), .p_fl_reg(p_fl_reg2), .p_fl_lane(p_fl_lane2), .p_fl_data(p_fl_data2),
		.p_fl_pw_we(c_fl_pw_we[3]), .p_fl_pw_addr(p_fl_pw_addr2), .p_fl_pw_data(p_fl_pw_data2),
		.p_fl_go(c_fl_go[3]), .p_fl_mask(p_fl_mask2), .p_fl_info(p_fl_info2),
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
		.p_ex_aux(c_ex_aux[3*155 +: 155]), .p_ex_next(p_ex_next[2*16 +: 16]),
		.t_req_valid(q_req_v[3]), .t_req_ready(q_req_r[3]), .t_req_data(q_req_d3), .t_req_last(q_req_l[3]),
		.t_rsp_valid(q_rsp_v[3]), .t_rsp_ready(q_rsp_r[3]), .t_rsp_data(q_rsp_d3),
		.p_at_valid(c_at_v[3]), .p_at_ready(c_at_r[3]), .p_at_op(c_at_op[3*4 +: 4]),
		.p_at_addr(c_at_addr[3*30 +: 30]), .p_at_a(c_at_a[3*32 +: 32]), .p_at_b(c_at_b[3*32 +: 32]),
		.p_at_stage(c_at_stage[3*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[3]), .p_at_old(p_at_old[2*32 +: 32]), .p_at_error(p_at_err[2]),
		.su0_mesh_valid(u_q_mv[3]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt3), .su0_mesh_last(u_q_ml[3]), .su0_mesh_id(u_q_mi3),
		.su0_sa_push_valid(u_q_spv[3]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd3),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[3]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[3]), .su0_sa_ctl_data(u_q_scd3),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[3]), .scrub_busy(q_scrub_in[3]), .fault(q_fault_in[3]),
		.fault_addr(q_faddr_in3), .fault_stage(q_fstage_in3), .fsm_packed(q_fsm3)
	);

	/* Q4: E_NW (SU 16..19) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(16), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd0),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q4 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[4]), .st_idx(q_st_idx4), .st_wdata(q_st_wdata4),
		.cs_kick(q_cs_kick[4]), .cs_mesh(q_cs_mesh[4]), .lc_kick(q_lc_kick[4]), .inv(q_inv4),
		.scrub(q_scrub[4]), .session_id(q_sess4),
		.p_vl_req(c_vl_req[4]), .p_vl_gnt(c_vl_gnt[4]), .p_vl_ptbase(c_vl_ptbase[4*8 +: 8]), .p_vl_avail(c_vl_avail[4]),
		.p_vl_we(c_vl_we[4]), .p_vl_reg(p_vl_reg1), .p_vl_lane(p_vl_lane1), .p_vl_data(p_vl_data1),
		.p_vl_go(c_vl_go[4]), .p_vl_mask(p_vl_mask1), .p_vl_go_ptbase(p_vl_go_ptbase1),
		.p_fl_req(c_fl_req[4]), .p_fl_gnt(c_fl_gnt[4]), .p_fl_avail(c_fl_avail[4]),
		.p_fl_we(c_fl_we[4]), .p_fl_reg(p_fl_reg1), .p_fl_lane(p_fl_lane1), .p_fl_data(p_fl_data1),
		.p_fl_pw_we(c_fl_pw_we[4]), .p_fl_pw_addr(p_fl_pw_addr1), .p_fl_pw_data(p_fl_pw_data1),
		.p_fl_go(c_fl_go[4]), .p_fl_mask(p_fl_mask1), .p_fl_info(p_fl_info1),
		.p_pt_exp_valid(c_pt_exp_v[4]), .p_pt_exp_ready(c_pt_exp_r[4]), .p_pt_exp_data(c_pt_exp_d[4*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[4]), .p_tx_ready(c_tx_r[4]), .p_tx_op(c_tx_op[4*8 +: 8]),
		.p_tx_slot(c_tx_slot[4*4 +: 4]), .p_tx_samp_slot(c_tx_samp[4*4 +: 4]), .p_tx_vs(c_tx_vs[4]),
		.p_tx_mask(c_tx_mask[4*4 +: 4]), .p_tx_coord(c_tx_coord[4*640 +: 640]), .p_tx_off(c_tx_off[4*12 +: 12]),
		.p_tx_tag(c_tx_tag[4*16 +: 16]), .p_tx_last(c_tx_l[4]),
		.p_tr_valid(c_tr_v[4]), .p_tr_ready(c_tr_r[4]), .p_tr_tag(c_tr_tag[4*16 +: 16]),
		.p_tr_data(c_tr_data[4*512 +: 512]), .p_tr_last(c_tr_l[4]),
		.p_ex_valid(c_ex_v[4]), .p_ex_ready(c_ex_r[4]), .p_ex_seq(c_ex_seq[4*16 +: 16]),
		.p_ex_xy(c_ex_xy[4*32 +: 32]), .p_ex_mask(c_ex_mask[4*4 +: 4]),
		.p_ex_color(c_ex_col[4*512 +: 512]), .p_ex_color1(c_ex_col1[4*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[4]), .p_ex_depth(c_ex_dep[4*128 +: 128]), .p_ex_last(c_ex_l[4]),
		.p_ex_aux(c_ex_aux[4*155 +: 155]), .p_ex_next(p_ex_next[1*16 +: 16]),
		.t_req_valid(q_req_v[4]), .t_req_ready(q_req_r[4]), .t_req_data(q_req_d4), .t_req_last(q_req_l[4]),
		.t_rsp_valid(q_rsp_v[4]), .t_rsp_ready(q_rsp_r[4]), .t_rsp_data(q_rsp_d4),
		.p_at_valid(c_at_v[4]), .p_at_ready(c_at_r[4]), .p_at_op(c_at_op[4*4 +: 4]),
		.p_at_addr(c_at_addr[4*30 +: 30]), .p_at_a(c_at_a[4*32 +: 32]), .p_at_b(c_at_b[4*32 +: 32]),
		.p_at_stage(c_at_stage[4*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[4]), .p_at_old(p_at_old[1*32 +: 32]), .p_at_error(p_at_err[1]),
		.su0_mesh_valid(u_q_mv[4]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt4), .su0_mesh_last(u_q_ml[4]), .su0_mesh_id(u_q_mi4),
		.su0_sa_push_valid(u_q_spv[4]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd4),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[4]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[4]), .su0_sa_ctl_data(u_q_scd4),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[4]), .scrub_busy(q_scrub_in[4]), .fault(q_fault_in[4]),
		.fault_addr(q_faddr_in4), .fault_stage(q_fstage_in4), .fsm_packed(q_fsm4)
	);

	/* Q5: E_NE (SU 20..23) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(20), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd1),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q5 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[5]), .st_idx(q_st_idx5), .st_wdata(q_st_wdata5),
		.cs_kick(q_cs_kick[5]), .cs_mesh(q_cs_mesh[5]), .lc_kick(q_lc_kick[5]), .inv(q_inv5),
		.scrub(q_scrub[5]), .session_id(q_sess5),
		.p_vl_req(c_vl_req[5]), .p_vl_gnt(c_vl_gnt[5]), .p_vl_ptbase(c_vl_ptbase[5*8 +: 8]), .p_vl_avail(c_vl_avail[5]),
		.p_vl_we(c_vl_we[5]), .p_vl_reg(p_vl_reg1), .p_vl_lane(p_vl_lane1), .p_vl_data(p_vl_data1),
		.p_vl_go(c_vl_go[5]), .p_vl_mask(p_vl_mask1), .p_vl_go_ptbase(p_vl_go_ptbase1),
		.p_fl_req(c_fl_req[5]), .p_fl_gnt(c_fl_gnt[5]), .p_fl_avail(c_fl_avail[5]),
		.p_fl_we(c_fl_we[5]), .p_fl_reg(p_fl_reg1), .p_fl_lane(p_fl_lane1), .p_fl_data(p_fl_data1),
		.p_fl_pw_we(c_fl_pw_we[5]), .p_fl_pw_addr(p_fl_pw_addr1), .p_fl_pw_data(p_fl_pw_data1),
		.p_fl_go(c_fl_go[5]), .p_fl_mask(p_fl_mask1), .p_fl_info(p_fl_info1),
		.p_pt_exp_valid(c_pt_exp_v[5]), .p_pt_exp_ready(c_pt_exp_r[5]), .p_pt_exp_data(c_pt_exp_d[5*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[5]), .p_tx_ready(c_tx_r[5]), .p_tx_op(c_tx_op[5*8 +: 8]),
		.p_tx_slot(c_tx_slot[5*4 +: 4]), .p_tx_samp_slot(c_tx_samp[5*4 +: 4]), .p_tx_vs(c_tx_vs[5]),
		.p_tx_mask(c_tx_mask[5*4 +: 4]), .p_tx_coord(c_tx_coord[5*640 +: 640]), .p_tx_off(c_tx_off[5*12 +: 12]),
		.p_tx_tag(c_tx_tag[5*16 +: 16]), .p_tx_last(c_tx_l[5]),
		.p_tr_valid(c_tr_v[5]), .p_tr_ready(c_tr_r[5]), .p_tr_tag(c_tr_tag[5*16 +: 16]),
		.p_tr_data(c_tr_data[5*512 +: 512]), .p_tr_last(c_tr_l[5]),
		.p_ex_valid(c_ex_v[5]), .p_ex_ready(c_ex_r[5]), .p_ex_seq(c_ex_seq[5*16 +: 16]),
		.p_ex_xy(c_ex_xy[5*32 +: 32]), .p_ex_mask(c_ex_mask[5*4 +: 4]),
		.p_ex_color(c_ex_col[5*512 +: 512]), .p_ex_color1(c_ex_col1[5*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[5]), .p_ex_depth(c_ex_dep[5*128 +: 128]), .p_ex_last(c_ex_l[5]),
		.p_ex_aux(c_ex_aux[5*155 +: 155]), .p_ex_next(p_ex_next[1*16 +: 16]),
		.t_req_valid(q_req_v[5]), .t_req_ready(q_req_r[5]), .t_req_data(q_req_d5), .t_req_last(q_req_l[5]),
		.t_rsp_valid(q_rsp_v[5]), .t_rsp_ready(q_rsp_r[5]), .t_rsp_data(q_rsp_d5),
		.p_at_valid(c_at_v[5]), .p_at_ready(c_at_r[5]), .p_at_op(c_at_op[5*4 +: 4]),
		.p_at_addr(c_at_addr[5*30 +: 30]), .p_at_a(c_at_a[5*32 +: 32]), .p_at_b(c_at_b[5*32 +: 32]),
		.p_at_stage(c_at_stage[5*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[5]), .p_at_old(p_at_old[1*32 +: 32]), .p_at_error(p_at_err[1]),
		.su0_mesh_valid(u_q_mv[5]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt5), .su0_mesh_last(u_q_ml[5]), .su0_mesh_id(u_q_mi5),
		.su0_sa_push_valid(u_q_spv[5]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd5),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[5]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[5]), .su0_sa_ctl_data(u_q_scd5),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[5]), .scrub_busy(q_scrub_in[5]), .fault(q_fault_in[5]),
		.fault_addr(q_faddr_in5), .fault_stage(q_fstage_in5), .fsm_packed(q_fsm5)
	);

	/* Q6: E_SW (SU 24..27) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(24), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd0),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q6 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[6]), .st_idx(q_st_idx6), .st_wdata(q_st_wdata6),
		.cs_kick(q_cs_kick[6]), .cs_mesh(q_cs_mesh[6]), .lc_kick(q_lc_kick[6]), .inv(q_inv6),
		.scrub(q_scrub[6]), .session_id(q_sess6),
		.p_vl_req(c_vl_req[6]), .p_vl_gnt(c_vl_gnt[6]), .p_vl_ptbase(c_vl_ptbase[6*8 +: 8]), .p_vl_avail(c_vl_avail[6]),
		.p_vl_we(c_vl_we[6]), .p_vl_reg(p_vl_reg3), .p_vl_lane(p_vl_lane3), .p_vl_data(p_vl_data3),
		.p_vl_go(c_vl_go[6]), .p_vl_mask(p_vl_mask3), .p_vl_go_ptbase(p_vl_go_ptbase3),
		.p_fl_req(c_fl_req[6]), .p_fl_gnt(c_fl_gnt[6]), .p_fl_avail(c_fl_avail[6]),
		.p_fl_we(c_fl_we[6]), .p_fl_reg(p_fl_reg3), .p_fl_lane(p_fl_lane3), .p_fl_data(p_fl_data3),
		.p_fl_pw_we(c_fl_pw_we[6]), .p_fl_pw_addr(p_fl_pw_addr3), .p_fl_pw_data(p_fl_pw_data3),
		.p_fl_go(c_fl_go[6]), .p_fl_mask(p_fl_mask3), .p_fl_info(p_fl_info3),
		.p_pt_exp_valid(c_pt_exp_v[6]), .p_pt_exp_ready(c_pt_exp_r[6]), .p_pt_exp_data(c_pt_exp_d[6*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[6]), .p_tx_ready(c_tx_r[6]), .p_tx_op(c_tx_op[6*8 +: 8]),
		.p_tx_slot(c_tx_slot[6*4 +: 4]), .p_tx_samp_slot(c_tx_samp[6*4 +: 4]), .p_tx_vs(c_tx_vs[6]),
		.p_tx_mask(c_tx_mask[6*4 +: 4]), .p_tx_coord(c_tx_coord[6*640 +: 640]), .p_tx_off(c_tx_off[6*12 +: 12]),
		.p_tx_tag(c_tx_tag[6*16 +: 16]), .p_tx_last(c_tx_l[6]),
		.p_tr_valid(c_tr_v[6]), .p_tr_ready(c_tr_r[6]), .p_tr_tag(c_tr_tag[6*16 +: 16]),
		.p_tr_data(c_tr_data[6*512 +: 512]), .p_tr_last(c_tr_l[6]),
		.p_ex_valid(c_ex_v[6]), .p_ex_ready(c_ex_r[6]), .p_ex_seq(c_ex_seq[6*16 +: 16]),
		.p_ex_xy(c_ex_xy[6*32 +: 32]), .p_ex_mask(c_ex_mask[6*4 +: 4]),
		.p_ex_color(c_ex_col[6*512 +: 512]), .p_ex_color1(c_ex_col1[6*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[6]), .p_ex_depth(c_ex_dep[6*128 +: 128]), .p_ex_last(c_ex_l[6]),
		.p_ex_aux(c_ex_aux[6*155 +: 155]), .p_ex_next(p_ex_next[3*16 +: 16]),
		.t_req_valid(q_req_v[6]), .t_req_ready(q_req_r[6]), .t_req_data(q_req_d6), .t_req_last(q_req_l[6]),
		.t_rsp_valid(q_rsp_v[6]), .t_rsp_ready(q_rsp_r[6]), .t_rsp_data(q_rsp_d6),
		.p_at_valid(c_at_v[6]), .p_at_ready(c_at_r[6]), .p_at_op(c_at_op[6*4 +: 4]),
		.p_at_addr(c_at_addr[6*30 +: 30]), .p_at_a(c_at_a[6*32 +: 32]), .p_at_b(c_at_b[6*32 +: 32]),
		.p_at_stage(c_at_stage[6*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[6]), .p_at_old(p_at_old[3*32 +: 32]), .p_at_error(p_at_err[3]),
		.su0_mesh_valid(u_q_mv[6]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt6), .su0_mesh_last(u_q_ml[6]), .su0_mesh_id(u_q_mi6),
		.su0_sa_push_valid(u_q_spv[6]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd6),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[6]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[6]), .su0_sa_ctl_data(u_q_scd6),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[6]), .scrub_busy(q_scrub_in[6]), .fault(q_fault_in[6]),
		.fault_addr(q_faddr_in6), .fault_stage(q_fstage_in6), .fsm_packed(q_fsm6)
	);

	/* Q7: E_SE (SU 28..31) */
	atg_su_quad #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(32),
		.BASE_INDEX(28), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU), .HAS_ROP(HAS_ROP),
		.SU_RW(SU_RW), .RBIT_QUAD(11), .RBIT_SU(13), .QUAD_ROUTE_PFX(4'd1),
		.TX_TBIT(11), .FW(FW), .RFW(RFW), .PT_W(PT_W)
	) q7 (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.st_we(q_st_we[7]), .st_idx(q_st_idx7), .st_wdata(q_st_wdata7),
		.cs_kick(q_cs_kick[7]), .cs_mesh(q_cs_mesh[7]), .lc_kick(q_lc_kick[7]), .inv(q_inv7),
		.scrub(q_scrub[7]), .session_id(q_sess7),
		.p_vl_req(c_vl_req[7]), .p_vl_gnt(c_vl_gnt[7]), .p_vl_ptbase(c_vl_ptbase[7*8 +: 8]), .p_vl_avail(c_vl_avail[7]),
		.p_vl_we(c_vl_we[7]), .p_vl_reg(p_vl_reg3), .p_vl_lane(p_vl_lane3), .p_vl_data(p_vl_data3),
		.p_vl_go(c_vl_go[7]), .p_vl_mask(p_vl_mask3), .p_vl_go_ptbase(p_vl_go_ptbase3),
		.p_fl_req(c_fl_req[7]), .p_fl_gnt(c_fl_gnt[7]), .p_fl_avail(c_fl_avail[7]),
		.p_fl_we(c_fl_we[7]), .p_fl_reg(p_fl_reg3), .p_fl_lane(p_fl_lane3), .p_fl_data(p_fl_data3),
		.p_fl_pw_we(c_fl_pw_we[7]), .p_fl_pw_addr(p_fl_pw_addr3), .p_fl_pw_data(p_fl_pw_data3),
		.p_fl_go(c_fl_go[7]), .p_fl_mask(p_fl_mask3), .p_fl_info(p_fl_info3),
		.p_pt_exp_valid(c_pt_exp_v[7]), .p_pt_exp_ready(c_pt_exp_r[7]), .p_pt_exp_data(c_pt_exp_d[7*PT_W +: PT_W]),
		.p_tx_valid(c_tx_v[7]), .p_tx_ready(c_tx_r[7]), .p_tx_op(c_tx_op[7*8 +: 8]),
		.p_tx_slot(c_tx_slot[7*4 +: 4]), .p_tx_samp_slot(c_tx_samp[7*4 +: 4]), .p_tx_vs(c_tx_vs[7]),
		.p_tx_mask(c_tx_mask[7*4 +: 4]), .p_tx_coord(c_tx_coord[7*640 +: 640]), .p_tx_off(c_tx_off[7*12 +: 12]),
		.p_tx_tag(c_tx_tag[7*16 +: 16]), .p_tx_last(c_tx_l[7]),
		.p_tr_valid(c_tr_v[7]), .p_tr_ready(c_tr_r[7]), .p_tr_tag(c_tr_tag[7*16 +: 16]),
		.p_tr_data(c_tr_data[7*512 +: 512]), .p_tr_last(c_tr_l[7]),
		.p_ex_valid(c_ex_v[7]), .p_ex_ready(c_ex_r[7]), .p_ex_seq(c_ex_seq[7*16 +: 16]),
		.p_ex_xy(c_ex_xy[7*32 +: 32]), .p_ex_mask(c_ex_mask[7*4 +: 4]),
		.p_ex_color(c_ex_col[7*512 +: 512]), .p_ex_color1(c_ex_col1[7*512 +: 512]),
		.p_ex_has_src1(c_ex_hs1[7]), .p_ex_depth(c_ex_dep[7*128 +: 128]), .p_ex_last(c_ex_l[7]),
		.p_ex_aux(c_ex_aux[7*155 +: 155]), .p_ex_next(p_ex_next[3*16 +: 16]),
		.t_req_valid(q_req_v[7]), .t_req_ready(q_req_r[7]), .t_req_data(q_req_d7), .t_req_last(q_req_l[7]),
		.t_rsp_valid(q_rsp_v[7]), .t_rsp_ready(q_rsp_r[7]), .t_rsp_data(q_rsp_d7),
		.p_at_valid(c_at_v[7]), .p_at_ready(c_at_r[7]), .p_at_op(c_at_op[7*4 +: 4]),
		.p_at_addr(c_at_addr[7*30 +: 30]), .p_at_a(c_at_a[7*32 +: 32]), .p_at_b(c_at_b[7*32 +: 32]),
		.p_at_stage(c_at_stage[7*2 +: 2]), .p_at_rsp_valid(c_at_rsp_v[7]), .p_at_old(p_at_old[3*32 +: 32]), .p_at_error(p_at_err[3]),
		.su0_mesh_valid(u_q_mv[7]), .su0_mesh_ready(1'b1), .su0_mesh_tri(u_q_mt7), .su0_mesh_last(u_q_ml[7]), .su0_mesh_id(u_q_mi7),
		.su0_sa_push_valid(u_q_spv[7]), .su0_sa_push_ready(1'b0), .su0_sa_push_data(u_q_spd7),
		.su0_sa_pop_valid(1'b0), .su0_sa_pop_ready(u_q_spr[7]), .su0_sa_pop_data({(NPHYS*32){1'b0}}),
		.su0_sa_ctl_valid(u_q_scv[7]), .su0_sa_ctl_data(u_q_scd7),
		.su0_sa_qstat(32'd0), .su0_sa_stat(32'd0), .su0_sa_qtag(32'd0),
		.busy(q_busy_in[7]), .scrub_busy(q_scrub_in[7]), .fault(q_fault_in[7]),
		.fault_addr(q_faddr_in7), .fault_stage(q_fstage_in7), .fsm_packed(q_fsm7)
	);

	/* Horizontal Repeaters: Outer Q0,Q2,Q5,Q7 = rep_h(2); Inner Q1,Q3,Q4,Q6 = rep_h(1) */
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_h0 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[0]), .dn_req_ready(q_req_r[0]), .dn_req_data(q_req_d0), .dn_req_last(q_req_l[0]),
		.up_req_valid(rh_req_v[0]), .up_req_ready(rh_req_r[0]), .up_req_data(rh_req_d0), .up_req_last(rh_req_l[0]),
		.up_rsp_valid(rh_rsp_v[0]), .up_rsp_ready(rh_rsp_r[0]), .up_rsp_data(rh_rsp_d0),
		.dn_rsp_valid(q_rsp_v[0]), .dn_rsp_ready(q_rsp_r[0]), .dn_rsp_data(q_rsp_d0), .rsp_idle(rh_rsp_idle[0]),
		.in_st_we(rv_st_we[0]), .in_st_idx(rv_st_idx0), .in_st_wdata(rv_st_wdata0),
		.in_cs_kick(rv_cs_kick[0]), .in_cs_mesh(rv_cs_mesh[0]), .in_lc_kick(rv_lc_kick[0]),
		.in_inv(rv_inv0), .in_scrub(rv_scrub[0]), .in_session_id(rv_sess0),
		.out_st_we(q_st_we[0]), .out_st_idx(q_st_idx0), .out_st_wdata(q_st_wdata0),
		.out_cs_kick(q_cs_kick[0]), .out_cs_mesh(q_cs_mesh[0]), .out_lc_kick(q_lc_kick[0]),
		.out_inv(q_inv0), .out_scrub(q_scrub[0]), .out_session_id(q_sess0),
		.in_busy(q_busy_in[0]), .in_scrub_busy(q_scrub_in[0]), .in_fault(q_fault_in[0]),
		.in_fault_addr(q_faddr_in0), .in_fault_stage(q_fstage_in0),
		.out_busy(rh_busy_out[0]), .out_scrub_busy(rh_scrub_out[0]), .out_fault(rh_fault_out[0]),
		.out_fault_addr(rh_faddr_out0), .out_fault_stage(rh_fstage_out0)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_h1 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[1]), .dn_req_ready(q_req_r[1]), .dn_req_data(q_req_d1), .dn_req_last(q_req_l[1]),
		.up_req_valid(rh_req_v[1]), .up_req_ready(rh_req_r[1]), .up_req_data(rh_req_d1), .up_req_last(rh_req_l[1]),
		.up_rsp_valid(rh_rsp_v[1]), .up_rsp_ready(rh_rsp_r[1]), .up_rsp_data(rh_rsp_d1),
		.dn_rsp_valid(q_rsp_v[1]), .dn_rsp_ready(q_rsp_r[1]), .dn_rsp_data(q_rsp_d1), .rsp_idle(rh_rsp_idle[1]),
		.in_st_we(rv_st_we[0]), .in_st_idx(rv_st_idx0), .in_st_wdata(rv_st_wdata0),
		.in_cs_kick(rv_cs_kick[0]), .in_cs_mesh(rv_cs_mesh[0]), .in_lc_kick(rv_lc_kick[0]),
		.in_inv(rv_inv0), .in_scrub(rv_scrub[0]), .in_session_id(rv_sess0),
		.out_st_we(q_st_we[1]), .out_st_idx(q_st_idx1), .out_st_wdata(q_st_wdata1),
		.out_cs_kick(q_cs_kick[1]), .out_cs_mesh(q_cs_mesh[1]), .out_lc_kick(q_lc_kick[1]),
		.out_inv(q_inv1), .out_scrub(q_scrub[1]), .out_session_id(q_sess1),
		.in_busy(q_busy_in[1]), .in_scrub_busy(q_scrub_in[1]), .in_fault(q_fault_in[1]),
		.in_fault_addr(q_faddr_in1), .in_fault_stage(q_fstage_in1),
		.out_busy(rh_busy_out[1]), .out_scrub_busy(rh_scrub_out[1]), .out_fault(rh_fault_out[1]),
		.out_fault_addr(rh_faddr_out1), .out_fault_stage(rh_fstage_out1)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_h2 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[2]), .dn_req_ready(q_req_r[2]), .dn_req_data(q_req_d2), .dn_req_last(q_req_l[2]),
		.up_req_valid(rh_req_v[2]), .up_req_ready(rh_req_r[2]), .up_req_data(rh_req_d2), .up_req_last(rh_req_l[2]),
		.up_rsp_valid(rh_rsp_v[2]), .up_rsp_ready(rh_rsp_r[2]), .up_rsp_data(rh_rsp_d2),
		.dn_rsp_valid(q_rsp_v[2]), .dn_rsp_ready(q_rsp_r[2]), .dn_rsp_data(q_rsp_d2), .rsp_idle(rh_rsp_idle[2]),
		.in_st_we(rv_st_we[2]), .in_st_idx(rv_st_idx2), .in_st_wdata(rv_st_wdata2),
		.in_cs_kick(rv_cs_kick[2]), .in_cs_mesh(rv_cs_mesh[2]), .in_lc_kick(rv_lc_kick[2]),
		.in_inv(rv_inv2), .in_scrub(rv_scrub[2]), .in_session_id(rv_sess2),
		.out_st_we(q_st_we[2]), .out_st_idx(q_st_idx2), .out_st_wdata(q_st_wdata2),
		.out_cs_kick(q_cs_kick[2]), .out_cs_mesh(q_cs_mesh[2]), .out_lc_kick(q_lc_kick[2]),
		.out_inv(q_inv2), .out_scrub(q_scrub[2]), .out_session_id(q_sess2),
		.in_busy(q_busy_in[2]), .in_scrub_busy(q_scrub_in[2]), .in_fault(q_fault_in[2]),
		.in_fault_addr(q_faddr_in2), .in_fault_stage(q_fstage_in2),
		.out_busy(rh_busy_out[2]), .out_scrub_busy(rh_scrub_out[2]), .out_fault(rh_fault_out[2]),
		.out_fault_addr(rh_faddr_out2), .out_fault_stage(rh_fstage_out2)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_h3 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[3]), .dn_req_ready(q_req_r[3]), .dn_req_data(q_req_d3), .dn_req_last(q_req_l[3]),
		.up_req_valid(rh_req_v[3]), .up_req_ready(rh_req_r[3]), .up_req_data(rh_req_d3), .up_req_last(rh_req_l[3]),
		.up_rsp_valid(rh_rsp_v[3]), .up_rsp_ready(rh_rsp_r[3]), .up_rsp_data(rh_rsp_d3),
		.dn_rsp_valid(q_rsp_v[3]), .dn_rsp_ready(q_rsp_r[3]), .dn_rsp_data(q_rsp_d3), .rsp_idle(rh_rsp_idle[3]),
		.in_st_we(rv_st_we[2]), .in_st_idx(rv_st_idx2), .in_st_wdata(rv_st_wdata2),
		.in_cs_kick(rv_cs_kick[2]), .in_cs_mesh(rv_cs_mesh[2]), .in_lc_kick(rv_lc_kick[2]),
		.in_inv(rv_inv2), .in_scrub(rv_scrub[2]), .in_session_id(rv_sess2),
		.out_st_we(q_st_we[3]), .out_st_idx(q_st_idx3), .out_st_wdata(q_st_wdata3),
		.out_cs_kick(q_cs_kick[3]), .out_cs_mesh(q_cs_mesh[3]), .out_lc_kick(q_lc_kick[3]),
		.out_inv(q_inv3), .out_scrub(q_scrub[3]), .out_session_id(q_sess3),
		.in_busy(q_busy_in[3]), .in_scrub_busy(q_scrub_in[3]), .in_fault(q_fault_in[3]),
		.in_fault_addr(q_faddr_in3), .in_fault_stage(q_fstage_in3),
		.out_busy(rh_busy_out[3]), .out_scrub_busy(rh_scrub_out[3]), .out_fault(rh_fault_out[3]),
		.out_fault_addr(rh_faddr_out3), .out_fault_stage(rh_fstage_out3)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_h4 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[4]), .dn_req_ready(q_req_r[4]), .dn_req_data(q_req_d4), .dn_req_last(q_req_l[4]),
		.up_req_valid(rh_req_v[4]), .up_req_ready(rh_req_r[4]), .up_req_data(rh_req_d4), .up_req_last(rh_req_l[4]),
		.up_rsp_valid(rh_rsp_v[4]), .up_rsp_ready(rh_rsp_r[4]), .up_rsp_data(rh_rsp_d4),
		.dn_rsp_valid(q_rsp_v[4]), .dn_rsp_ready(q_rsp_r[4]), .dn_rsp_data(q_rsp_d4), .rsp_idle(rh_rsp_idle[4]),
		.in_st_we(rv_st_we[1]), .in_st_idx(rv_st_idx1), .in_st_wdata(rv_st_wdata1),
		.in_cs_kick(rv_cs_kick[1]), .in_cs_mesh(rv_cs_mesh[1]), .in_lc_kick(rv_lc_kick[1]),
		.in_inv(rv_inv1), .in_scrub(rv_scrub[1]), .in_session_id(rv_sess1),
		.out_st_we(q_st_we[4]), .out_st_idx(q_st_idx4), .out_st_wdata(q_st_wdata4),
		.out_cs_kick(q_cs_kick[4]), .out_cs_mesh(q_cs_mesh[4]), .out_lc_kick(q_lc_kick[4]),
		.out_inv(q_inv4), .out_scrub(q_scrub[4]), .out_session_id(q_sess4),
		.in_busy(q_busy_in[4]), .in_scrub_busy(q_scrub_in[4]), .in_fault(q_fault_in[4]),
		.in_fault_addr(q_faddr_in4), .in_fault_stage(q_fstage_in4),
		.out_busy(rh_busy_out[4]), .out_scrub_busy(rh_scrub_out[4]), .out_fault(rh_fault_out[4]),
		.out_fault_addr(rh_faddr_out4), .out_fault_stage(rh_fstage_out4)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_h5 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[5]), .dn_req_ready(q_req_r[5]), .dn_req_data(q_req_d5), .dn_req_last(q_req_l[5]),
		.up_req_valid(rh_req_v[5]), .up_req_ready(rh_req_r[5]), .up_req_data(rh_req_d5), .up_req_last(rh_req_l[5]),
		.up_rsp_valid(rh_rsp_v[5]), .up_rsp_ready(rh_rsp_r[5]), .up_rsp_data(rh_rsp_d5),
		.dn_rsp_valid(q_rsp_v[5]), .dn_rsp_ready(q_rsp_r[5]), .dn_rsp_data(q_rsp_d5), .rsp_idle(rh_rsp_idle[5]),
		.in_st_we(rv_st_we[1]), .in_st_idx(rv_st_idx1), .in_st_wdata(rv_st_wdata1),
		.in_cs_kick(rv_cs_kick[1]), .in_cs_mesh(rv_cs_mesh[1]), .in_lc_kick(rv_lc_kick[1]),
		.in_inv(rv_inv1), .in_scrub(rv_scrub[1]), .in_session_id(rv_sess1),
		.out_st_we(q_st_we[5]), .out_st_idx(q_st_idx5), .out_st_wdata(q_st_wdata5),
		.out_cs_kick(q_cs_kick[5]), .out_cs_mesh(q_cs_mesh[5]), .out_lc_kick(q_lc_kick[5]),
		.out_inv(q_inv5), .out_scrub(q_scrub[5]), .out_session_id(q_sess5),
		.in_busy(q_busy_in[5]), .in_scrub_busy(q_scrub_in[5]), .in_fault(q_fault_in[5]),
		.in_fault_addr(q_faddr_in5), .in_fault_stage(q_fstage_in5),
		.out_busy(rh_busy_out[5]), .out_scrub_busy(rh_scrub_out[5]), .out_fault(rh_fault_out[5]),
		.out_fault_addr(rh_faddr_out5), .out_fault_stage(rh_fstage_out5)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_h6 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[6]), .dn_req_ready(q_req_r[6]), .dn_req_data(q_req_d6), .dn_req_last(q_req_l[6]),
		.up_req_valid(rh_req_v[6]), .up_req_ready(rh_req_r[6]), .up_req_data(rh_req_d6), .up_req_last(rh_req_l[6]),
		.up_rsp_valid(rh_rsp_v[6]), .up_rsp_ready(rh_rsp_r[6]), .up_rsp_data(rh_rsp_d6),
		.dn_rsp_valid(q_rsp_v[6]), .dn_rsp_ready(q_rsp_r[6]), .dn_rsp_data(q_rsp_d6), .rsp_idle(rh_rsp_idle[6]),
		.in_st_we(rv_st_we[3]), .in_st_idx(rv_st_idx3), .in_st_wdata(rv_st_wdata3),
		.in_cs_kick(rv_cs_kick[3]), .in_cs_mesh(rv_cs_mesh[3]), .in_lc_kick(rv_lc_kick[3]),
		.in_inv(rv_inv3), .in_scrub(rv_scrub[3]), .in_session_id(rv_sess3),
		.out_st_we(q_st_we[6]), .out_st_idx(q_st_idx6), .out_st_wdata(q_st_wdata6),
		.out_cs_kick(q_cs_kick[6]), .out_cs_mesh(q_cs_mesh[6]), .out_lc_kick(q_lc_kick[6]),
		.out_inv(q_inv6), .out_scrub(q_scrub[6]), .out_session_id(q_sess6),
		.in_busy(q_busy_in[6]), .in_scrub_busy(q_scrub_in[6]), .in_fault(q_fault_in[6]),
		.in_fault_addr(q_faddr_in6), .in_fault_stage(q_fstage_in6),
		.out_busy(rh_busy_out[6]), .out_scrub_busy(rh_scrub_out[6]), .out_fault(rh_fault_out[6]),
		.out_fault_addr(rh_faddr_out6), .out_fault_stage(rh_fstage_out6)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_h7 (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(q_req_v[7]), .dn_req_ready(q_req_r[7]), .dn_req_data(q_req_d7), .dn_req_last(q_req_l[7]),
		.up_req_valid(rh_req_v[7]), .up_req_ready(rh_req_r[7]), .up_req_data(rh_req_d7), .up_req_last(rh_req_l[7]),
		.up_rsp_valid(rh_rsp_v[7]), .up_rsp_ready(rh_rsp_r[7]), .up_rsp_data(rh_rsp_d7),
		.dn_rsp_valid(q_rsp_v[7]), .dn_rsp_ready(q_rsp_r[7]), .dn_rsp_data(q_rsp_d7), .rsp_idle(rh_rsp_idle[7]),
		.in_st_we(rv_st_we[3]), .in_st_idx(rv_st_idx3), .in_st_wdata(rv_st_wdata3),
		.in_cs_kick(rv_cs_kick[3]), .in_cs_mesh(rv_cs_mesh[3]), .in_lc_kick(rv_lc_kick[3]),
		.in_inv(rv_inv3), .in_scrub(rv_scrub[3]), .in_session_id(rv_sess3),
		.out_st_we(q_st_we[7]), .out_st_idx(q_st_idx7), .out_st_wdata(q_st_wdata7),
		.out_cs_kick(q_cs_kick[7]), .out_cs_mesh(q_cs_mesh[7]), .out_lc_kick(q_lc_kick[7]),
		.out_inv(q_inv7), .out_scrub(q_scrub[7]), .out_session_id(q_sess7),
		.in_busy(q_busy_in[7]), .in_scrub_busy(q_scrub_in[7]), .in_fault(q_fault_in[7]),
		.in_fault_addr(q_faddr_in7), .in_fault_stage(q_fstage_in7),
		.out_busy(rh_busy_out[7]), .out_scrub_busy(rh_scrub_out[7]), .out_fault(rh_fault_out[7]),
		.out_fault_addr(rh_faddr_out7), .out_fault_stage(rh_fstage_out7)
	);

	/* Pairwise 2x1 NoC Routers: rt2_wn, rt2_en, rt2_ws, rt2_es */
	wire [3:0] rt2_rsp_idle;
	atg_rt2 #(.RBIT(10), .FW(FW), .RFW(RFW)) u_rt2_wn (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(rh_req_v[0]), .c0_req_ready(rh_req_r[0]), .c0_req_data(rh_req_d0), .c0_req_last(rh_req_l[0]),
		.c1_req_valid(rh_req_v[1]), .c1_req_ready(rh_req_r[1]), .c1_req_data(rh_req_d1), .c1_req_last(rh_req_l[1]),
		.p_req_valid(rt2_req_v[0]), .p_req_ready(rt2_req_r[0]), .p_req_data(rt2_req_d0), .p_req_last(rt2_req_l[0]),
		.p_rsp_valid(rt2_rsp_v[0]), .p_rsp_ready(rt2_rsp_r[0]), .p_rsp_data(rt2_rsp_d0),
		.c0_rsp_valid(rh_rsp_v[0]), .c0_rsp_ready(rh_rsp_r[0]), .c0_rsp_data(rh_rsp_d0),
		.c1_rsp_valid(rh_rsp_v[1]), .c1_rsp_ready(rh_rsp_r[1]), .c1_rsp_data(rh_rsp_d1),
		.rsp_idle(rt2_rsp_idle[0])
	);
	atg_rt2 #(.RBIT(10), .FW(FW), .RFW(RFW)) u_rt2_en (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(rh_req_v[4]), .c0_req_ready(rh_req_r[4]), .c0_req_data(rh_req_d4), .c0_req_last(rh_req_l[4]),
		.c1_req_valid(rh_req_v[5]), .c1_req_ready(rh_req_r[5]), .c1_req_data(rh_req_d5), .c1_req_last(rh_req_l[5]),
		.p_req_valid(rt2_req_v[1]), .p_req_ready(rt2_req_r[1]), .p_req_data(rt2_req_d1), .p_req_last(rt2_req_l[1]),
		.p_rsp_valid(rt2_rsp_v[1]), .p_rsp_ready(rt2_rsp_r[1]), .p_rsp_data(rt2_rsp_d1),
		.c0_rsp_valid(rh_rsp_v[4]), .c0_rsp_ready(rh_rsp_r[4]), .c0_rsp_data(rh_rsp_d4),
		.c1_rsp_valid(rh_rsp_v[5]), .c1_rsp_ready(rh_rsp_r[5]), .c1_rsp_data(rh_rsp_d5),
		.rsp_idle(rt2_rsp_idle[1])
	);
	atg_rt2 #(.RBIT(10), .FW(FW), .RFW(RFW)) u_rt2_ws (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(rh_req_v[2]), .c0_req_ready(rh_req_r[2]), .c0_req_data(rh_req_d2), .c0_req_last(rh_req_l[2]),
		.c1_req_valid(rh_req_v[3]), .c1_req_ready(rh_req_r[3]), .c1_req_data(rh_req_d3), .c1_req_last(rh_req_l[3]),
		.p_req_valid(rt2_req_v[2]), .p_req_ready(rt2_req_r[2]), .p_req_data(rt2_req_d2), .p_req_last(rt2_req_l[2]),
		.p_rsp_valid(rt2_rsp_v[2]), .p_rsp_ready(rt2_rsp_r[2]), .p_rsp_data(rt2_rsp_d2),
		.c0_rsp_valid(rh_rsp_v[2]), .c0_rsp_ready(rh_rsp_r[2]), .c0_rsp_data(rh_rsp_d2),
		.c1_rsp_valid(rh_rsp_v[3]), .c1_rsp_ready(rh_rsp_r[3]), .c1_rsp_data(rh_rsp_d3),
		.rsp_idle(rt2_rsp_idle[2])
	);
	atg_rt2 #(.RBIT(10), .FW(FW), .RFW(RFW)) u_rt2_es (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(rh_req_v[6]), .c0_req_ready(rh_req_r[6]), .c0_req_data(rh_req_d6), .c0_req_last(rh_req_l[6]),
		.c1_req_valid(rh_req_v[7]), .c1_req_ready(rh_req_r[7]), .c1_req_data(rh_req_d7), .c1_req_last(rh_req_l[7]),
		.p_req_valid(rt2_req_v[3]), .p_req_ready(rt2_req_r[3]), .p_req_data(rt2_req_d3), .p_req_last(rt2_req_l[3]),
		.p_rsp_valid(rt2_rsp_v[3]), .p_rsp_ready(rt2_rsp_r[3]), .p_rsp_data(rt2_rsp_d3),
		.c0_rsp_valid(rh_rsp_v[6]), .c0_rsp_ready(rh_rsp_r[6]), .c0_rsp_data(rh_rsp_d6),
		.c1_rsp_valid(rh_rsp_v[7]), .c1_rsp_ready(rh_rsp_r[7]), .c1_rsp_data(rh_rsp_d7),
		.rsp_idle(rt2_rsp_idle[3])
	);

	/* Vertical Repeaters: North = rep_v(2), South = rep_v(1) -> 4 Parallel Trunks */
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_v_wn (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(rt2_req_v[0]), .dn_req_ready(rt2_req_r[0]), .dn_req_data(rt2_req_d0), .dn_req_last(rt2_req_l[0]),
		.up_req_valid(trunk_req_valid[0]), .up_req_ready(trunk_req_ready[0]),
		.up_req_data(trunk_req_data[0*FW +: FW]), .up_req_last(trunk_req_last[0]),
		.up_rsp_valid(trunk_rsp_valid[0]), .up_rsp_ready(trunk_rsp_ready[0]),
		.up_rsp_data(trunk_rsp_data[0*RFW +: RFW]),
		.dn_rsp_valid(rt2_rsp_v[0]), .dn_rsp_ready(rt2_rsp_r[0]), .dn_rsp_data(rt2_rsp_d0), .rsp_idle(rv_rsp_idle[0]),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(rv_st_we[0]), .out_st_idx(rv_st_idx0), .out_st_wdata(rv_st_wdata0),
		.out_cs_kick(rv_cs_kick[0]), .out_cs_mesh(rv_cs_mesh[0]), .out_lc_kick(rv_lc_kick[0]),
		.out_inv(rv_inv0), .out_scrub(rv_scrub[0]), .out_session_id(rv_sess0),
		.in_busy(rh_busy_out[0] | rh_busy_out[1]), .in_scrub_busy(rh_scrub_out[0] | rh_scrub_out[1]),
		.in_fault(rh_fault_out[0] | rh_fault_out[1]),
		.in_fault_addr(rh_fault_out[0] ? rh_faddr_out0 : rh_faddr_out1),
		.in_fault_stage(rh_fault_out[0] ? rh_fstage_out0 : rh_fstage_out1),
		.out_busy(b_busy[0]), .out_scrub_busy(b_scrub_busy[0]), .out_fault(b_fault[0]),
		.out_fault_addr(b_faddr0), .out_fault_stage(b_fstage0)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(2)) u_rep_v_en (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(rt2_req_v[1]), .dn_req_ready(rt2_req_r[1]), .dn_req_data(rt2_req_d1), .dn_req_last(rt2_req_l[1]),
		.up_req_valid(trunk_req_valid[1]), .up_req_ready(trunk_req_ready[1]),
		.up_req_data(trunk_req_data[1*FW +: FW]), .up_req_last(trunk_req_last[1]),
		.up_rsp_valid(trunk_rsp_valid[1]), .up_rsp_ready(trunk_rsp_ready[1]),
		.up_rsp_data(trunk_rsp_data[1*RFW +: RFW]),
		.dn_rsp_valid(rt2_rsp_v[1]), .dn_rsp_ready(rt2_rsp_r[1]), .dn_rsp_data(rt2_rsp_d1), .rsp_idle(rv_rsp_idle[1]),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(rv_st_we[1]), .out_st_idx(rv_st_idx1), .out_st_wdata(rv_st_wdata1),
		.out_cs_kick(rv_cs_kick[1]), .out_cs_mesh(rv_cs_mesh[1]), .out_lc_kick(rv_lc_kick[1]),
		.out_inv(rv_inv1), .out_scrub(rv_scrub[1]), .out_session_id(rv_sess1),
		.in_busy(rh_busy_out[4] | rh_busy_out[5]), .in_scrub_busy(rh_scrub_out[4] | rh_scrub_out[5]),
		.in_fault(rh_fault_out[4] | rh_fault_out[5]),
		.in_fault_addr(rh_fault_out[4] ? rh_faddr_out4 : rh_faddr_out5),
		.in_fault_stage(rh_fault_out[4] ? rh_fstage_out4 : rh_fstage_out5),
		.out_busy(b_busy[1]), .out_scrub_busy(b_scrub_busy[1]), .out_fault(b_fault[1]),
		.out_fault_addr(b_faddr1), .out_fault_stage(b_fstage1)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_v_ws (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(rt2_req_v[2]), .dn_req_ready(rt2_req_r[2]), .dn_req_data(rt2_req_d2), .dn_req_last(rt2_req_l[2]),
		.up_req_valid(trunk_req_valid[2]), .up_req_ready(trunk_req_ready[2]),
		.up_req_data(trunk_req_data[2*FW +: FW]), .up_req_last(trunk_req_last[2]),
		.up_rsp_valid(trunk_rsp_valid[2]), .up_rsp_ready(trunk_rsp_ready[2]),
		.up_rsp_data(trunk_rsp_data[2*RFW +: RFW]),
		.dn_rsp_valid(rt2_rsp_v[2]), .dn_rsp_ready(rt2_rsp_r[2]), .dn_rsp_data(rt2_rsp_d2), .rsp_idle(rv_rsp_idle[2]),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(rv_st_we[2]), .out_st_idx(rv_st_idx2), .out_st_wdata(rv_st_wdata2),
		.out_cs_kick(rv_cs_kick[2]), .out_cs_mesh(rv_cs_mesh[2]), .out_lc_kick(rv_lc_kick[2]),
		.out_inv(rv_inv2), .out_scrub(rv_scrub[2]), .out_session_id(rv_sess2),
		.in_busy(rh_busy_out[2] | rh_busy_out[3]), .in_scrub_busy(rh_scrub_out[2] | rh_scrub_out[3]),
		.in_fault(rh_fault_out[2] | rh_fault_out[3]),
		.in_fault_addr(rh_fault_out[2] ? rh_faddr_out2 : rh_faddr_out3),
		.in_fault_stage(rh_fault_out[2] ? rh_fstage_out2 : rh_fstage_out3),
		.out_busy(b_busy[2]), .out_scrub_busy(b_scrub_busy[2]), .out_fault(b_fault[2]),
		.out_fault_addr(b_faddr2), .out_fault_stage(b_fstage2)
	);
	atg_rep #(.FW(FW), .RFW(RFW), .STAGES(1)) u_rep_v_es (
		.clk(clk), .rst_n(rst_n), .core_rst_n(rst_n), .flush(flush),
		.dn_req_valid(rt2_req_v[3]), .dn_req_ready(rt2_req_r[3]), .dn_req_data(rt2_req_d3), .dn_req_last(rt2_req_l[3]),
		.up_req_valid(trunk_req_valid[3]), .up_req_ready(trunk_req_ready[3]),
		.up_req_data(trunk_req_data[3*FW +: FW]), .up_req_last(trunk_req_last[3]),
		.up_rsp_valid(trunk_rsp_valid[3]), .up_rsp_ready(trunk_rsp_ready[3]),
		.up_rsp_data(trunk_rsp_data[3*RFW +: RFW]),
		.dn_rsp_valid(rt2_rsp_v[3]), .dn_rsp_ready(rt2_rsp_r[3]), .dn_rsp_data(rt2_rsp_d3), .rsp_idle(rv_rsp_idle[3]),
		.in_st_we(st_we), .in_st_idx(st_idx), .in_st_wdata(st_wdata),
		.in_cs_kick(cs_kick), .in_cs_mesh(cs_mesh), .in_lc_kick(lc_kick),
		.in_inv(inv), .in_scrub(scrub), .in_session_id(session_id),
		.out_st_we(rv_st_we[3]), .out_st_idx(rv_st_idx3), .out_st_wdata(rv_st_wdata3),
		.out_cs_kick(rv_cs_kick[3]), .out_cs_mesh(rv_cs_mesh[3]), .out_lc_kick(rv_lc_kick[3]),
		.out_inv(rv_inv3), .out_scrub(rv_scrub[3]), .out_session_id(rv_sess3),
		.in_busy(rh_busy_out[6] | rh_busy_out[7]), .in_scrub_busy(rh_scrub_out[6] | rh_scrub_out[7]),
		.in_fault(rh_fault_out[6] | rh_fault_out[7]),
		.in_fault_addr(rh_fault_out[6] ? rh_faddr_out6 : rh_faddr_out7),
		.in_fault_stage(rh_fault_out[6] ? rh_fstage_out6 : rh_fstage_out7),
		.out_busy(b_busy[3]), .out_scrub_busy(b_scrub_busy[3]), .out_fault(b_fault[3]),
		.out_fault_addr(b_faddr3), .out_fault_stage(b_fstage3)
	);

	/* Spine Hierarchy: 4 Pairs (K=2 each: wn=(0,1), en=(4,5), ws=(2,3), es=(6,7)) -> Root (K=4) */
	generate
	if (HAS_GFX != 0) begin : g_n32_gfx
		atg_warp_dist #(.K(4)) u_wdist_root (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(vl_req), .p_vl_gnt(vl_gnt), .p_vl_ptbase(vl_ptbase), .p_vl_avail(vl_avail),
			.p_vl_we(vl_we), .p_vl_reg(vl_reg), .p_vl_lane(vl_lane), .p_vl_data(vl_data),
			.p_vl_go(vl_go), .p_vl_mask(vl_mask), .p_vl_go_ptbase(vl_go_ptbase),
			.c_vl_req(p_vl_req), .c_vl_gnt(p_vl_gnt), .c_vl_ptbase(p_vl_ptbase), .c_vl_avail(p_vl_avail),
			.c_vl_we(p_vl_we), .c_vl_reg(w_vl_reg), .c_vl_lane(w_vl_lane), .c_vl_data(w_vl_data),
			.c_vl_go(p_vl_go), .c_vl_mask(w_vl_mask), .c_vl_go_ptbase(w_vl_go_ptbase),
			.p_fl_req(fl_req), .p_fl_gnt(fl_gnt), .p_fl_avail(fl_avail),
			.p_fl_we(fl_we), .p_fl_reg(fl_reg), .p_fl_lane(fl_lane), .p_fl_data(fl_data),
			.p_fl_pw_we(fl_pw_we), .p_fl_pw_addr(fl_pw_addr), .p_fl_pw_data(fl_pw_data),
			.p_fl_go(fl_go), .p_fl_mask(fl_mask), .p_fl_info(fl_info),
			.c_fl_req(p_fl_req), .c_fl_gnt(p_fl_gnt), .c_fl_avail(p_fl_avail),
			.c_fl_we(p_fl_we), .c_fl_reg(w_fl_reg), .c_fl_lane(w_fl_lane), .c_fl_data(w_fl_data),
			.c_fl_pw_we(p_fl_pw_we), .c_fl_pw_addr(w_fl_pw_addr), .c_fl_pw_data(w_fl_pw_data),
			.c_fl_go(p_fl_go), .c_fl_mask(w_fl_mask), .c_fl_info(w_fl_info)
		);
		atg_warp_dist #(.K(2)) u_wdist_wn (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(p_vl_req[0]), .p_vl_gnt(p_vl_gnt[0]), .p_vl_ptbase(p_vl_ptbase[0*8 +: 8]), .p_vl_avail(p_vl_avail[0]),
			.p_vl_we(p_vl_we[0]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
			.p_vl_go(p_vl_go[0]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
			.c_vl_req(c_vl_req[1:0]), .c_vl_gnt(c_vl_gnt[1:0]), .c_vl_ptbase(c_vl_ptbase[0*16 +: 16]), .c_vl_avail(c_vl_avail[1:0]),
			.c_vl_we(c_vl_we[1:0]), .c_vl_reg(p_vl_reg0), .c_vl_lane(p_vl_lane0), .c_vl_data(p_vl_data0),
			.c_vl_go(c_vl_go[1:0]), .c_vl_mask(p_vl_mask0), .c_vl_go_ptbase(p_vl_go_ptbase0),
			.p_fl_req(p_fl_req[0]), .p_fl_gnt(p_fl_gnt[0]), .p_fl_avail(p_fl_avail[0]),
			.p_fl_we(p_fl_we[0]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
			.p_fl_pw_we(p_fl_pw_we[0]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
			.p_fl_go(p_fl_go[0]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
			.c_fl_req(c_fl_req[1:0]), .c_fl_gnt(c_fl_gnt[1:0]), .c_fl_avail(c_fl_avail[1:0]),
			.c_fl_we(c_fl_we[1:0]), .c_fl_reg(p_fl_reg0), .c_fl_lane(p_fl_lane0), .c_fl_data(p_fl_data0),
			.c_fl_pw_we(c_fl_pw_we[1:0]), .c_fl_pw_addr(p_fl_pw_addr0), .c_fl_pw_data(p_fl_pw_data0),
			.c_fl_go(c_fl_go[1:0]), .c_fl_mask(p_fl_mask0), .c_fl_info(p_fl_info0)
		);
		atg_warp_dist #(.K(2)) u_wdist_en (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(p_vl_req[1]), .p_vl_gnt(p_vl_gnt[1]), .p_vl_ptbase(p_vl_ptbase[1*8 +: 8]), .p_vl_avail(p_vl_avail[1]),
			.p_vl_we(p_vl_we[1]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
			.p_vl_go(p_vl_go[1]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
			.c_vl_req(c_vl_req[5:4]), .c_vl_gnt(c_vl_gnt[5:4]), .c_vl_ptbase(c_vl_ptbase[4*8 +: 16]), .c_vl_avail(c_vl_avail[5:4]),
			.c_vl_we(c_vl_we[5:4]), .c_vl_reg(p_vl_reg1), .c_vl_lane(p_vl_lane1), .c_vl_data(p_vl_data1),
			.c_vl_go(c_vl_go[5:4]), .c_vl_mask(p_vl_mask1), .c_vl_go_ptbase(p_vl_go_ptbase1),
			.p_fl_req(p_fl_req[1]), .p_fl_gnt(p_fl_gnt[1]), .p_fl_avail(p_fl_avail[1]),
			.p_fl_we(p_fl_we[1]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
			.p_fl_pw_we(p_fl_pw_we[1]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
			.p_fl_go(p_fl_go[1]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
			.c_fl_req(c_fl_req[5:4]), .c_fl_gnt(c_fl_gnt[5:4]), .c_fl_avail(c_fl_avail[5:4]),
			.c_fl_we(c_fl_we[5:4]), .c_fl_reg(p_fl_reg1), .c_fl_lane(p_fl_lane1), .c_fl_data(p_fl_data1),
			.c_fl_pw_we(c_fl_pw_we[5:4]), .c_fl_pw_addr(p_fl_pw_addr1), .c_fl_pw_data(p_fl_pw_data1),
			.c_fl_go(c_fl_go[5:4]), .c_fl_mask(p_fl_mask1), .c_fl_info(p_fl_info1)
		);
		atg_warp_dist #(.K(2)) u_wdist_ws (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(p_vl_req[2]), .p_vl_gnt(p_vl_gnt[2]), .p_vl_ptbase(p_vl_ptbase[2*8 +: 8]), .p_vl_avail(p_vl_avail[2]),
			.p_vl_we(p_vl_we[2]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
			.p_vl_go(p_vl_go[2]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
			.c_vl_req(c_vl_req[3:2]), .c_vl_gnt(c_vl_gnt[3:2]), .c_vl_ptbase(c_vl_ptbase[2*8 +: 16]), .c_vl_avail(c_vl_avail[3:2]),
			.c_vl_we(c_vl_we[3:2]), .c_vl_reg(p_vl_reg2), .c_vl_lane(p_vl_lane2), .c_vl_data(p_vl_data2),
			.c_vl_go(c_vl_go[3:2]), .c_vl_mask(p_vl_mask2), .c_vl_go_ptbase(p_vl_go_ptbase2),
			.p_fl_req(p_fl_req[2]), .p_fl_gnt(p_fl_gnt[2]), .p_fl_avail(p_fl_avail[2]),
			.p_fl_we(p_fl_we[2]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
			.p_fl_pw_we(p_fl_pw_we[2]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
			.p_fl_go(p_fl_go[2]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
			.c_fl_req(c_fl_req[3:2]), .c_fl_gnt(c_fl_gnt[3:2]), .c_fl_avail(c_fl_avail[3:2]),
			.c_fl_we(c_fl_we[3:2]), .c_fl_reg(p_fl_reg2), .c_fl_lane(p_fl_lane2), .c_fl_data(p_fl_data2),
			.c_fl_pw_we(c_fl_pw_we[3:2]), .c_fl_pw_addr(p_fl_pw_addr2), .c_fl_pw_data(p_fl_pw_data2),
			.c_fl_go(c_fl_go[3:2]), .c_fl_mask(p_fl_mask2), .c_fl_info(p_fl_info2)
		);
		atg_warp_dist #(.K(2)) u_wdist_es (
			.clk(clk), .rst_n(rst_n),
			.p_vl_req(p_vl_req[3]), .p_vl_gnt(p_vl_gnt[3]), .p_vl_ptbase(p_vl_ptbase[3*8 +: 8]), .p_vl_avail(p_vl_avail[3]),
			.p_vl_we(p_vl_we[3]), .p_vl_reg(w_vl_reg), .p_vl_lane(w_vl_lane), .p_vl_data(w_vl_data),
			.p_vl_go(p_vl_go[3]), .p_vl_mask(w_vl_mask), .p_vl_go_ptbase(w_vl_go_ptbase),
			.c_vl_req(c_vl_req[7:6]), .c_vl_gnt(c_vl_gnt[7:6]), .c_vl_ptbase(c_vl_ptbase[6*8 +: 16]), .c_vl_avail(c_vl_avail[7:6]),
			.c_vl_we(c_vl_we[7:6]), .c_vl_reg(p_vl_reg3), .c_vl_lane(p_vl_lane3), .c_vl_data(p_vl_data3),
			.c_vl_go(c_vl_go[7:6]), .c_vl_mask(p_vl_mask3), .c_vl_go_ptbase(p_vl_go_ptbase3),
			.p_fl_req(p_fl_req[3]), .p_fl_gnt(p_fl_gnt[3]), .p_fl_avail(p_fl_avail[3]),
			.p_fl_we(p_fl_we[3]), .p_fl_reg(w_fl_reg), .p_fl_lane(w_fl_lane), .p_fl_data(w_fl_data),
			.p_fl_pw_we(p_fl_pw_we[3]), .p_fl_pw_addr(w_fl_pw_addr), .p_fl_pw_data(w_fl_pw_data),
			.p_fl_go(p_fl_go[3]), .p_fl_mask(w_fl_mask), .p_fl_info(w_fl_info),
			.c_fl_req(c_fl_req[7:6]), .c_fl_gnt(c_fl_gnt[7:6]), .c_fl_avail(c_fl_avail[7:6]),
			.c_fl_we(c_fl_we[7:6]), .c_fl_reg(p_fl_reg3), .c_fl_lane(p_fl_lane3), .c_fl_data(p_fl_data3),
			.c_fl_pw_we(c_fl_pw_we[7:6]), .c_fl_pw_addr(p_fl_pw_addr3), .c_fl_pw_data(p_fl_pw_data3),
			.c_fl_go(c_fl_go[7:6]), .c_fl_mask(p_fl_mask3), .c_fl_info(p_fl_info3)
		);

		atg_pt_exp_rt #(.K(2), .W(PT_W)) u_ptrt_wn (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v[1:0]), .c_ready(c_pt_exp_r[1:0]), .c_data(c_pt_exp_d[0*PT_W +: 2*PT_W]),
			.p_valid(p_pt_exp_v[0]), .p_ready(p_pt_exp_r[0]), .p_data(p_pt_exp_d[0*PT_W +: PT_W])
		);
		atg_pt_exp_rt #(.K(2), .W(PT_W)) u_ptrt_en (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v[5:4]), .c_ready(c_pt_exp_r[5:4]), .c_data(c_pt_exp_d[4*PT_W +: 2*PT_W]),
			.p_valid(p_pt_exp_v[1]), .p_ready(p_pt_exp_r[1]), .p_data(p_pt_exp_d[1*PT_W +: PT_W])
		);
		atg_pt_exp_rt #(.K(2), .W(PT_W)) u_ptrt_ws (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v[3:2]), .c_ready(c_pt_exp_r[3:2]), .c_data(c_pt_exp_d[2*PT_W +: 2*PT_W]),
			.p_valid(p_pt_exp_v[2]), .p_ready(p_pt_exp_r[2]), .p_data(p_pt_exp_d[2*PT_W +: PT_W])
		);
		atg_pt_exp_rt #(.K(2), .W(PT_W)) u_ptrt_es (
			.clk(clk), .rst_n(rst_n),
			.c_valid(c_pt_exp_v[7:6]), .c_ready(c_pt_exp_r[7:6]), .c_data(c_pt_exp_d[6*PT_W +: 2*PT_W]),
			.p_valid(p_pt_exp_v[3]), .p_ready(p_pt_exp_r[3]), .p_data(p_pt_exp_d[3*PT_W +: PT_W])
		);
		atg_pt_exp_rt #(.K(4), .W(PT_W)) u_ptrt_root (
			.clk(clk), .rst_n(rst_n),
			.c_valid(p_pt_exp_v), .c_ready(p_pt_exp_r), .c_data(p_pt_exp_d),
			.p_valid(pt_exp_valid), .p_ready(pt_exp_ready), .p_data(pt_exp_packed)
		);
	end else begin : g_n32_nogfx
		assign vl_gnt = 1'b0; assign vl_ptbase = 8'd0; assign vl_avail = 1'b0;
		assign fl_gnt = 1'b0; assign fl_avail = 1'b0;
		assign pt_exp_valid = 1'b0; assign pt_exp_packed = {PT_W{1'b0}};
		assign c_vl_req = 8'd0; assign c_vl_we = 8'd0; assign c_vl_go = 8'd0;
		assign c_fl_req = 8'd0; assign c_fl_we = 8'd0; assign c_fl_pw_we = 8'd0; assign c_fl_go = 8'd0;
		assign c_pt_exp_r = 8'hFF;
		assign p_vl_req = 4'd0; assign p_vl_we = 4'd0; assign p_vl_go = 4'd0;
		assign p_vl_reg0 = 6'd0; assign p_vl_reg1 = 6'd0; assign p_vl_reg2 = 6'd0; assign p_vl_reg3 = 6'd0;
		assign p_vl_lane0 = 5'd0; assign p_vl_lane1 = 5'd0; assign p_vl_lane2 = 5'd0; assign p_vl_lane3 = 5'd0;
		assign p_vl_data0 = 32'd0; assign p_vl_data1 = 32'd0; assign p_vl_data2 = 32'd0; assign p_vl_data3 = 32'd0;
		assign p_vl_mask0 = 32'd0; assign p_vl_mask1 = 32'd0; assign p_vl_mask2 = 32'd0; assign p_vl_mask3 = 32'd0;
		assign p_vl_go_ptbase0 = 8'd0; assign p_vl_go_ptbase1 = 8'd0; assign p_vl_go_ptbase2 = 8'd0; assign p_vl_go_ptbase3 = 8'd0;
		assign p_fl_req = 4'd0; assign p_fl_we = 4'd0; assign p_fl_pw_we = 4'd0; assign p_fl_go = 4'd0;
		assign p_fl_reg0 = 6'd0; assign p_fl_reg1 = 6'd0; assign p_fl_reg2 = 6'd0; assign p_fl_reg3 = 6'd0;
		assign p_fl_lane0 = 5'd0; assign p_fl_lane1 = 5'd0; assign p_fl_lane2 = 5'd0; assign p_fl_lane3 = 5'd0;
		assign p_fl_data0 = 32'd0; assign p_fl_data1 = 32'd0; assign p_fl_data2 = 32'd0; assign p_fl_data3 = 32'd0;
		assign p_fl_pw_addr0 = 12'd0; assign p_fl_pw_addr1 = 12'd0; assign p_fl_pw_addr2 = 12'd0; assign p_fl_pw_addr3 = 12'd0;
		assign p_fl_pw_data0 = 32'd0; assign p_fl_pw_data1 = 32'd0; assign p_fl_pw_data2 = 32'd0; assign p_fl_pw_data3 = 32'd0;
		assign p_fl_mask0 = 32'd0; assign p_fl_mask1 = 32'd0; assign p_fl_mask2 = 32'd0; assign p_fl_mask3 = 32'd0;
		assign p_fl_info0 = 64'd0; assign p_fl_info1 = 64'd0; assign p_fl_info2 = 64'd0; assign p_fl_info3 = 64'd0;
		assign w_vl_reg = 6'd0; assign w_vl_lane = 5'd0; assign w_vl_data = 32'd0; assign w_vl_mask = 32'd0; assign w_vl_go_ptbase = 8'd0;
		assign w_fl_reg = 6'd0; assign w_fl_lane = 5'd0; assign w_fl_data = 32'd0; assign w_fl_pw_addr = 12'd0; assign w_fl_pw_data = 32'd0; assign w_fl_mask = 32'd0; assign w_fl_info = 64'd0;
		assign p_pt_exp_v = 4'd0; assign p_pt_exp_r = 4'hF; assign p_pt_exp_d = {(4*PT_W){1'b0}};
		assign p_vl_gnt = 4'd0; assign p_vl_ptbase = 32'd0; assign p_vl_avail = 4'd0;
		assign p_fl_gnt = 4'd0; assign p_fl_avail = 4'd0;
	end

	if (HAS_TU != 0) begin : g_n32_tu
		atg_tx_rt #(.K(2), .TBIT(13)) u_txrt_wn (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v[1:0]), .c_tx_ready(c_tx_r[1:0]), .c_tx_op(c_tx_op[0*16 +: 16]),
			.c_tx_slot(c_tx_slot[0*8 +: 8]), .c_tx_samp_slot(c_tx_samp[0*8 +: 8]), .c_tx_vs(c_tx_vs[1:0]),
			.c_tx_mask(c_tx_mask[0*8 +: 8]), .c_tx_coord(c_tx_coord[0*640 +: 2*640]), .c_tx_off(c_tx_off[0*24 +: 24]),
			.c_tx_tag(c_tx_tag[0*32 +: 32]), .c_tx_last(c_tx_l[1:0]),
			.c_tr_valid(c_tr_v[1:0]), .c_tr_ready(c_tr_r[1:0]), .c_tr_tag(c_tr_tag[0*32 +: 32]),
			.c_tr_data(c_tr_data[0*512 +: 2*512]), .c_tr_last(c_tr_l[1:0]),
			.p_tx_valid(p_tx_v[0]), .p_tx_ready(p_tx_r[0]), .p_tx_op(p_tx_op[0*8 +: 8]),
			.p_tx_slot(p_tx_slot[0*4 +: 4]), .p_tx_samp_slot(p_tx_samp[0*4 +: 4]), .p_tx_vs(p_tx_vs[0]),
			.p_tx_mask(p_tx_mask[0*4 +: 4]), .p_tx_coord(p_tx_coord[0*640 +: 640]), .p_tx_off(p_tx_off[0*12 +: 12]),
			.p_tx_tag(p_tx_tag[0*16 +: 16]), .p_tx_last(p_tx_l[0]),
			.p_tr_valid(p_tr_v[0]), .p_tr_ready(p_tr_r[0]), .p_tr_tag(p_tr_tag[0*16 +: 16]),
			.p_tr_data(p_tr_data[0*512 +: 512]), .p_tr_last(p_tr_l[0])
		);
		atg_tx_rt #(.K(2), .TBIT(13)) u_txrt_en (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v[5:4]), .c_tx_ready(c_tx_r[5:4]), .c_tx_op(c_tx_op[4*8 +: 16]),
			.c_tx_slot(c_tx_slot[4*4 +: 8]), .c_tx_samp_slot(c_tx_samp[4*4 +: 8]), .c_tx_vs(c_tx_vs[5:4]),
			.c_tx_mask(c_tx_mask[4*4 +: 8]), .c_tx_coord(c_tx_coord[4*640 +: 2*640]), .c_tx_off(c_tx_off[4*12 +: 24]),
			.c_tx_tag(c_tx_tag[4*16 +: 32]), .c_tx_last(c_tx_l[5:4]),
			.c_tr_valid(c_tr_v[5:4]), .c_tr_ready(c_tr_r[5:4]), .c_tr_tag(c_tr_tag[4*16 +: 32]),
			.c_tr_data(c_tr_data[4*512 +: 2*512]), .c_tr_last(c_tr_l[5:4]),
			.p_tx_valid(p_tx_v[1]), .p_tx_ready(p_tx_r[1]), .p_tx_op(p_tx_op[1*8 +: 8]),
			.p_tx_slot(p_tx_slot[1*4 +: 4]), .p_tx_samp_slot(p_tx_samp[1*4 +: 4]), .p_tx_vs(p_tx_vs[1]),
			.p_tx_mask(p_tx_mask[1*4 +: 4]), .p_tx_coord(p_tx_coord[1*640 +: 640]), .p_tx_off(p_tx_off[1*12 +: 12]),
			.p_tx_tag(p_tx_tag[1*16 +: 16]), .p_tx_last(p_tx_l[1]),
			.p_tr_valid(p_tr_v[1]), .p_tr_ready(p_tr_r[1]), .p_tr_tag(p_tr_tag[1*16 +: 16]),
			.p_tr_data(p_tr_data[1*512 +: 512]), .p_tr_last(p_tr_l[1])
		);
		atg_tx_rt #(.K(2), .TBIT(13)) u_txrt_ws (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v[3:2]), .c_tx_ready(c_tx_r[3:2]), .c_tx_op(c_tx_op[2*8 +: 16]),
			.c_tx_slot(c_tx_slot[2*4 +: 8]), .c_tx_samp_slot(c_tx_samp[2*4 +: 8]), .c_tx_vs(c_tx_vs[3:2]),
			.c_tx_mask(c_tx_mask[2*4 +: 8]), .c_tx_coord(c_tx_coord[2*640 +: 2*640]), .c_tx_off(c_tx_off[2*12 +: 24]),
			.c_tx_tag(c_tx_tag[2*16 +: 32]), .c_tx_last(c_tx_l[3:2]),
			.c_tr_valid(c_tr_v[3:2]), .c_tr_ready(c_tr_r[3:2]), .c_tr_tag(c_tr_tag[2*16 +: 32]),
			.c_tr_data(c_tr_data[2*512 +: 2*512]), .c_tr_last(c_tr_l[3:2]),
			.p_tx_valid(p_tx_v[2]), .p_tx_ready(p_tx_r[2]), .p_tx_op(p_tx_op[2*8 +: 8]),
			.p_tx_slot(p_tx_slot[2*4 +: 4]), .p_tx_samp_slot(p_tx_samp[2*4 +: 4]), .p_tx_vs(p_tx_vs[2]),
			.p_tx_mask(p_tx_mask[2*4 +: 4]), .p_tx_coord(p_tx_coord[2*640 +: 640]), .p_tx_off(p_tx_off[2*12 +: 12]),
			.p_tx_tag(p_tx_tag[2*16 +: 16]), .p_tx_last(p_tx_l[2]),
			.p_tr_valid(p_tr_v[2]), .p_tr_ready(p_tr_r[2]), .p_tr_tag(p_tr_tag[2*16 +: 16]),
			.p_tr_data(p_tr_data[2*512 +: 512]), .p_tr_last(p_tr_l[2])
		);
		atg_tx_rt #(.K(2), .TBIT(13)) u_txrt_es (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(c_tx_v[7:6]), .c_tx_ready(c_tx_r[7:6]), .c_tx_op(c_tx_op[6*8 +: 16]),
			.c_tx_slot(c_tx_slot[6*4 +: 8]), .c_tx_samp_slot(c_tx_samp[6*4 +: 8]), .c_tx_vs(c_tx_vs[7:6]),
			.c_tx_mask(c_tx_mask[6*4 +: 8]), .c_tx_coord(c_tx_coord[6*640 +: 2*640]), .c_tx_off(c_tx_off[6*12 +: 24]),
			.c_tx_tag(c_tx_tag[6*16 +: 32]), .c_tx_last(c_tx_l[7:6]),
			.c_tr_valid(c_tr_v[7:6]), .c_tr_ready(c_tr_r[7:6]), .c_tr_tag(c_tr_tag[6*16 +: 32]),
			.c_tr_data(c_tr_data[6*512 +: 2*512]), .c_tr_last(c_tr_l[7:6]),
			.p_tx_valid(p_tx_v[3]), .p_tx_ready(p_tx_r[3]), .p_tx_op(p_tx_op[3*8 +: 8]),
			.p_tx_slot(p_tx_slot[3*4 +: 4]), .p_tx_samp_slot(p_tx_samp[3*4 +: 4]), .p_tx_vs(p_tx_vs[3]),
			.p_tx_mask(p_tx_mask[3*4 +: 4]), .p_tx_coord(p_tx_coord[3*640 +: 640]), .p_tx_off(p_tx_off[3*12 +: 12]),
			.p_tx_tag(p_tx_tag[3*16 +: 16]), .p_tx_last(p_tx_l[3]),
			.p_tr_valid(p_tr_v[3]), .p_tr_ready(p_tr_r[3]), .p_tr_tag(p_tr_tag[3*16 +: 16]),
			.p_tr_data(p_tr_data[3*512 +: 512]), .p_tr_last(p_tr_l[3])
		);
		atg_tx_rt #(.K(4), .TBIT(14)) u_txrt_root (
			.clk(clk), .rst_n(rst_n),
			.c_tx_valid(p_tx_v), .c_tx_ready(p_tx_r), .c_tx_op(p_tx_op),
			.c_tx_slot(p_tx_slot), .c_tx_samp_slot(p_tx_samp), .c_tx_vs(p_tx_vs),
			.c_tx_mask(p_tx_mask), .c_tx_coord(p_tx_coord), .c_tx_off(p_tx_off),
			.c_tx_tag(p_tx_tag), .c_tx_last(p_tx_l),
			.c_tr_valid(p_tr_v), .c_tr_ready(p_tr_r), .c_tr_tag(p_tr_tag),
			.c_tr_data(p_tr_data), .c_tr_last(p_tr_l),
			.p_tx_valid(tx_valid), .p_tx_ready(tx_ready), .p_tx_op(tx_op),
			.p_tx_slot(tx_slot), .p_tx_samp_slot(tx_samp_slot), .p_tx_vs(tx_vs),
			.p_tx_mask(tx_mask), .p_tx_coord(tx_coord), .p_tx_off(tx_off),
			.p_tx_tag(tx_tag), .p_tx_last(tx_last),
			.p_tr_valid(tr_valid), .p_tr_ready(tr_ready), .p_tr_tag(tr_tag),
			.p_tr_data(tr_data), .p_tr_last(tr_last)
		);
	end else begin : g_n32_notu
		assign tx_valid = 1'b0; assign tx_op = 8'd0; assign tx_slot = 4'd0; assign tx_samp_slot = 4'd0;
		assign tx_vs = 1'b0; assign tx_mask = 4'd0; assign tx_coord = 640'd0; assign tx_off = 12'd0;
		assign tx_tag = 16'd0; assign tx_last = 1'b0; assign tr_ready = 1'b1;
		assign c_tx_r = 8'd0; assign c_tr_v = 8'd0; assign c_tr_tag = 128'd0; assign c_tr_data = 4096'd0; assign c_tr_l = 8'd0;
		assign p_tx_v = 4'd0; assign p_tx_r = 4'd0; assign p_tx_op = 32'd0; assign p_tx_slot = 16'd0;
		assign p_tx_samp = 16'd0; assign p_tx_vs = 4'd0; assign p_tx_mask = 16'd0; assign p_tx_coord = {(4*640){1'b0}};
		assign p_tx_off = 48'd0; assign p_tx_tag = 64'd0; assign p_tx_l = 4'd0;
		assign p_tr_v = 4'd0; assign p_tr_r = 4'd0; assign p_tr_tag = 64'd0; assign p_tr_data = {(4*512){1'b0}}; assign p_tr_l = 4'd0;
	end

	if (HAS_ROP != 0) begin : g_n32_rop
		atg_ex_rt #(.K(2)) u_exrt_wn (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v[1:0]), .c_ex_ready(c_ex_r[1:0]), .c_ex_seq(c_ex_seq[0*16 +: 32]),
			.c_ex_xy(c_ex_xy[0*32 +: 64]), .c_ex_mask(c_ex_mask[0*4 +: 8]), .c_ex_color(c_ex_col[0*512 +: 2*512]),
			.c_ex_color1(c_ex_col1[0*512 +: 2*512]), .c_ex_has_src1(c_ex_hs1[1:0]), .c_ex_depth(c_ex_dep[0*128 +: 256]),
			.c_ex_last(c_ex_l[1:0]), .c_ex_aux(c_ex_aux[0*155 +: 2*155]), .c_ex_next(p_ex_next[0*16 +: 16]),
			.p_ex_valid(p_ex_v[0]), .p_ex_ready(p_ex_r[0]), .p_ex_seq(p_ex_seq[0*16 +: 16]),
			.p_ex_xy(p_ex_xy[0*32 +: 32]), .p_ex_mask(p_ex_mask[0*4 +: 4]), .p_ex_color(p_ex_col[0*512 +: 512]),
			.p_ex_color1(p_ex_col1[0*512 +: 512]), .p_ex_has_src1(p_ex_hs1[0]), .p_ex_depth(p_ex_dep[0*128 +: 128]),
			.p_ex_last(p_ex_l[0]), .p_ex_aux(p_ex_aux[0*155 +: 155]), .p_ex_next(w_ex_next)
		);
		atg_ex_rt #(.K(2)) u_exrt_en (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v[5:4]), .c_ex_ready(c_ex_r[5:4]), .c_ex_seq(c_ex_seq[4*16 +: 32]),
			.c_ex_xy(c_ex_xy[4*32 +: 64]), .c_ex_mask(c_ex_mask[4*4 +: 8]), .c_ex_color(c_ex_col[4*512 +: 2*512]),
			.c_ex_color1(c_ex_col1[4*512 +: 2*512]), .c_ex_has_src1(c_ex_hs1[5:4]), .c_ex_depth(c_ex_dep[4*128 +: 256]),
			.c_ex_last(c_ex_l[5:4]), .c_ex_aux(c_ex_aux[4*155 +: 2*155]), .c_ex_next(p_ex_next[1*16 +: 16]),
			.p_ex_valid(p_ex_v[1]), .p_ex_ready(p_ex_r[1]), .p_ex_seq(p_ex_seq[1*16 +: 16]),
			.p_ex_xy(p_ex_xy[1*32 +: 32]), .p_ex_mask(p_ex_mask[1*4 +: 4]), .p_ex_color(p_ex_col[1*512 +: 512]),
			.p_ex_color1(p_ex_col1[1*512 +: 512]), .p_ex_has_src1(p_ex_hs1[1]), .p_ex_depth(p_ex_dep[1*128 +: 128]),
			.p_ex_last(p_ex_l[1]), .p_ex_aux(p_ex_aux[1*155 +: 155]), .p_ex_next(w_ex_next)
		);
		atg_ex_rt #(.K(2)) u_exrt_ws (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v[3:2]), .c_ex_ready(c_ex_r[3:2]), .c_ex_seq(c_ex_seq[2*16 +: 32]),
			.c_ex_xy(c_ex_xy[2*32 +: 64]), .c_ex_mask(c_ex_mask[2*4 +: 8]), .c_ex_color(c_ex_col[2*512 +: 2*512]),
			.c_ex_color1(c_ex_col1[2*512 +: 2*512]), .c_ex_has_src1(c_ex_hs1[3:2]), .c_ex_depth(c_ex_dep[2*128 +: 256]),
			.c_ex_last(c_ex_l[3:2]), .c_ex_aux(c_ex_aux[2*155 +: 2*155]), .c_ex_next(p_ex_next[2*16 +: 16]),
			.p_ex_valid(p_ex_v[2]), .p_ex_ready(p_ex_r[2]), .p_ex_seq(p_ex_seq[2*16 +: 16]),
			.p_ex_xy(p_ex_xy[2*32 +: 32]), .p_ex_mask(p_ex_mask[2*4 +: 4]), .p_ex_color(p_ex_col[2*512 +: 512]),
			.p_ex_color1(p_ex_col1[2*512 +: 512]), .p_ex_has_src1(p_ex_hs1[2]), .p_ex_depth(p_ex_dep[2*128 +: 128]),
			.p_ex_last(p_ex_l[2]), .p_ex_aux(p_ex_aux[2*155 +: 155]), .p_ex_next(w_ex_next)
		);
		atg_ex_rt #(.K(2)) u_exrt_es (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(c_ex_v[7:6]), .c_ex_ready(c_ex_r[7:6]), .c_ex_seq(c_ex_seq[6*16 +: 32]),
			.c_ex_xy(c_ex_xy[6*32 +: 64]), .c_ex_mask(c_ex_mask[6*4 +: 8]), .c_ex_color(c_ex_col[6*512 +: 2*512]),
			.c_ex_color1(c_ex_col1[6*512 +: 2*512]), .c_ex_has_src1(c_ex_hs1[7:6]), .c_ex_depth(c_ex_dep[6*128 +: 256]),
			.c_ex_last(c_ex_l[7:6]), .c_ex_aux(c_ex_aux[6*155 +: 2*155]), .c_ex_next(p_ex_next[3*16 +: 16]),
			.p_ex_valid(p_ex_v[3]), .p_ex_ready(p_ex_r[3]), .p_ex_seq(p_ex_seq[3*16 +: 16]),
			.p_ex_xy(p_ex_xy[3*32 +: 32]), .p_ex_mask(p_ex_mask[3*4 +: 4]), .p_ex_color(p_ex_col[3*512 +: 512]),
			.p_ex_color1(p_ex_col1[3*512 +: 512]), .p_ex_has_src1(p_ex_hs1[3]), .p_ex_depth(p_ex_dep[3*128 +: 128]),
			.p_ex_last(p_ex_l[3]), .p_ex_aux(p_ex_aux[3*155 +: 155]), .p_ex_next(w_ex_next)
		);
		atg_ex_rt #(.K(4)) u_exrt_root (
			.clk(clk), .rst_n(rst_n),
			.c_ex_valid(p_ex_v), .c_ex_ready(p_ex_r), .c_ex_seq(p_ex_seq),
			.c_ex_xy(p_ex_xy), .c_ex_mask(p_ex_mask), .c_ex_color(p_ex_col),
			.c_ex_color1(p_ex_col1), .c_ex_has_src1(p_ex_hs1), .c_ex_depth(p_ex_dep),
			.c_ex_last(p_ex_l), .c_ex_aux(p_ex_aux), .c_ex_next(w_ex_next),
			.p_ex_valid(ex_valid), .p_ex_ready(ex_ready), .p_ex_seq(ex_seq),
			.p_ex_xy(ex_xy), .p_ex_mask(ex_mask), .p_ex_color(ex_color),
			.p_ex_color1(ex_color1), .p_ex_has_src1(ex_has_src1), .p_ex_depth(ex_depth),
			.p_ex_last(ex_last), .p_ex_aux(ex_aux), .p_ex_next(ex_next)
		);
	end else begin : g_n32_norop
		assign ex_valid = 1'b0; assign ex_seq = 16'd0; assign ex_xy = 32'd0; assign ex_mask = 4'd0;
		assign ex_color = 512'd0; assign ex_color1 = 512'd0; assign ex_has_src1 = 1'b0;
		assign ex_depth = 128'd0; assign ex_last = 1'b0; assign ex_aux = 155'd0;
		assign c_ex_r = 8'd0; assign w_ex_next = 16'd0; assign p_ex_next = 64'd0;
		assign p_ex_v = 4'd0; assign p_ex_r = 4'd0; assign p_ex_seq = 64'd0; assign p_ex_xy = 128'd0;
		assign p_ex_mask = 16'd0; assign p_ex_col = {(4*512){1'b0}}; assign p_ex_col1 = {(4*512){1'b0}};
		assign p_ex_hs1 = 4'd0; assign p_ex_dep = 512'd0; assign p_ex_l = 4'd0; assign p_ex_aux = {(4*155){1'b0}};
	end
	endgenerate

	atg_atom_rt #(.K(2), .ATOM_AW(30)) u_atomrt_wn (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v[1:0]), .c_at_ready(c_at_r[1:0]), .c_at_op(c_at_op[0*4 +: 8]),
		.c_at_addr(c_at_addr[0*30 +: 60]), .c_at_a(c_at_a[0*32 +: 64]), .c_at_b(c_at_b[0*32 +: 64]), .c_at_stage(c_at_stage[0*2 +: 4]),
		.c_at_rsp_valid(c_at_rsp_v[1:0]), .c_at_old(p_at_old[0*32 +: 32]), .c_at_error(p_at_err[0]),
		.p_at_valid(p_at_v[0]), .p_at_ready(p_at_r[0]), .p_at_op(p_at_op[0*4 +: 4]),
		.p_at_addr(p_at_addr[0*30 +: 30]), .p_at_a(p_at_a[0*32 +: 32]), .p_at_b(p_at_b[0*32 +: 32]), .p_at_stage(p_at_stage[0*2 +: 2]),
		.p_at_rsp_valid(p_at_rsp_v[0]), .p_at_old(w_at_old), .p_at_error(w_at_err)
	);
	atg_atom_rt #(.K(2), .ATOM_AW(30)) u_atomrt_en (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v[5:4]), .c_at_ready(c_at_r[5:4]), .c_at_op(c_at_op[4*4 +: 8]),
		.c_at_addr(c_at_addr[4*30 +: 60]), .c_at_a(c_at_a[4*32 +: 64]), .c_at_b(c_at_b[4*32 +: 64]), .c_at_stage(c_at_stage[4*2 +: 4]),
		.c_at_rsp_valid(c_at_rsp_v[5:4]), .c_at_old(p_at_old[1*32 +: 32]), .c_at_error(p_at_err[1]),
		.p_at_valid(p_at_v[1]), .p_at_ready(p_at_r[1]), .p_at_op(p_at_op[1*4 +: 4]),
		.p_at_addr(p_at_addr[1*30 +: 30]), .p_at_a(p_at_a[1*32 +: 32]), .p_at_b(p_at_b[1*32 +: 32]), .p_at_stage(p_at_stage[1*2 +: 2]),
		.p_at_rsp_valid(p_at_rsp_v[1]), .p_at_old(w_at_old), .p_at_error(w_at_err)
	);
	atg_atom_rt #(.K(2), .ATOM_AW(30)) u_atomrt_ws (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v[3:2]), .c_at_ready(c_at_r[3:2]), .c_at_op(c_at_op[2*4 +: 8]),
		.c_at_addr(c_at_addr[2*30 +: 60]), .c_at_a(c_at_a[2*32 +: 64]), .c_at_b(c_at_b[2*32 +: 64]), .c_at_stage(c_at_stage[2*2 +: 4]),
		.c_at_rsp_valid(c_at_rsp_v[3:2]), .c_at_old(p_at_old[2*32 +: 32]), .c_at_error(p_at_err[2]),
		.p_at_valid(p_at_v[2]), .p_at_ready(p_at_r[2]), .p_at_op(p_at_op[2*4 +: 4]),
		.p_at_addr(p_at_addr[2*30 +: 30]), .p_at_a(p_at_a[2*32 +: 32]), .p_at_b(p_at_b[2*32 +: 32]), .p_at_stage(p_at_stage[2*2 +: 2]),
		.p_at_rsp_valid(p_at_rsp_v[2]), .p_at_old(w_at_old), .p_at_error(w_at_err)
	);
	atg_atom_rt #(.K(2), .ATOM_AW(30)) u_atomrt_es (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(c_at_v[7:6]), .c_at_ready(c_at_r[7:6]), .c_at_op(c_at_op[6*4 +: 8]),
		.c_at_addr(c_at_addr[6*30 +: 60]), .c_at_a(c_at_a[6*32 +: 64]), .c_at_b(c_at_b[6*32 +: 64]), .c_at_stage(c_at_stage[6*2 +: 4]),
		.c_at_rsp_valid(c_at_rsp_v[7:6]), .c_at_old(p_at_old[3*32 +: 32]), .c_at_error(p_at_err[3]),
		.p_at_valid(p_at_v[3]), .p_at_ready(p_at_r[3]), .p_at_op(p_at_op[3*4 +: 4]),
		.p_at_addr(p_at_addr[3*30 +: 30]), .p_at_a(p_at_a[3*32 +: 32]), .p_at_b(p_at_b[3*32 +: 32]), .p_at_stage(p_at_stage[3*2 +: 2]),
		.p_at_rsp_valid(p_at_rsp_v[3]), .p_at_old(w_at_old), .p_at_error(w_at_err)
	);
	atg_atom_rt #(.K(4), .ATOM_AW(30)) u_atomrt_root (
		.clk(clk), .rst_n(rst_n),
		.c_at_valid(p_at_v), .c_at_ready(p_at_r), .c_at_op(p_at_op),
		.c_at_addr(p_at_addr), .c_at_a(p_at_a), .c_at_b(p_at_b), .c_at_stage(p_at_stage),
		.c_at_rsp_valid(p_at_rsp_v), .c_at_old(w_at_old), .c_at_error(w_at_err),
		.p_at_valid(at_valid), .p_at_ready(at_ready), .p_at_op(at_op),
		.p_at_addr(at_addr), .p_at_a(at_a), .p_at_b(at_b), .p_at_stage(at_stage),
		.p_at_rsp_valid(at_rsp_valid), .p_at_old(at_old), .p_at_error(at_error)
	);

	/* Max rep_v(2) + rep_h(2) round-trip guard = 9 cycles */
	reg [8:0] kick_flight_sr;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n)
			kick_flight_sr <= 9'd0;
		else
			kick_flight_sr <= {kick_flight_sr[7:0], cs_kick || lc_kick};
	end

	assign busy = (|b_busy) || (|kick_flight_sr);
	assign scrub_busy = |b_scrub_busy;
	assign fault = |b_fault;
	assign fault_addr = b_fault[0] ? b_faddr0 :
	                    b_fault[1] ? b_faddr1 :
	                    b_fault[2] ? b_faddr2 :
	                    b_fault[3] ? b_faddr3 : 32'd0;
	assign fault_stage = b_fault[0] ? b_fstage0 :
	                     b_fault[1] ? b_fstage1 :
	                     b_fault[2] ? b_fstage2 :
	                     b_fault[3] ? b_fstage3 : 4'd0;

	wire unused_ok = &{1'b0, pt_rd, pt_idx, pt_word, pt_free, pt_free_idx,
		rv_rsp_idle, rh_rsp_idle, rt2_rsp_idle,
		q_fsm0[15:4], q_fsm1, q_fsm2, q_fsm3, q_fsm4, q_fsm5, q_fsm6, q_fsm7,
		u_q_mv, u_q_ml, u_q_spv, u_q_spr, u_q_scv,
		u_q_mt1, u_q_mt2, u_q_mt3, u_q_mt4, u_q_mt5, u_q_mt6, u_q_mt7,
		u_q_mi1, u_q_mi2, u_q_mi3, u_q_mi4, u_q_mi5, u_q_mi6, u_q_mi7,
		u_q_spd1, u_q_spd2, u_q_spd3, u_q_spd4, u_q_spd5, u_q_spd6, u_q_spd7,
		u_q_scd1, u_q_scd2, u_q_scd3, u_q_scd4, u_q_scd5, u_q_scd6, u_q_scd7};
endmodule

`default_nettype wire
