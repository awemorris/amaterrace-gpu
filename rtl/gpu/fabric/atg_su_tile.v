/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_tile: Single Shader Unit (SU) physical tile with integrated
 * 2-way local NoC router (atg_rt2) merging D$ (c0) and I$ (c1, EXEC=1)
 * onto one unified NoC port (docs/noc_and_mmu_architecture.md §5.1).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_tile #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter NREGS = 32,
	parameter SB_ENTRIES = 4,
	parameter SBE_W = 2,
	parameter NSU = 1,
	parameter SU_INDEX = 0,
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
	parameter SU_RW = 1,
	parameter [SU_RW-1:0] ROUTE_D = {SU_RW{1'b0}},
	parameter [SU_RW-1:0] ROUTE_I = {SU_RW{1'b0}},
	parameter RBIT_SU = 10,
	parameter FW = LINE_BYTES * 8,
	parameter RFW = LINE_BYTES * 8 + 10 + SU_RW,
	parameter PT_W = 1 + 3 + GRP_W + 7 + NPHYS + NPHYS * 32
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	/* Control broadcast (from atg_rep / Spine) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire cs_kick,
	input wire cs_mesh,
	input wire lc_kick,
	input wire [3:0] inv,
	input wire scrub,
	input wire [3:0] session_id,

	/* Vertex warps */
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

	/* Fragment warps */
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
	input wire [15:0] ex_next,
	output wire [154:0] ex_aux,

	/* Meshlet Primitive Export */
	output wire mesh_valid,
	input wire mesh_ready,
	output wire [701:0] mesh_tri,
	output wire mesh_last,
	output wire [15:0] mesh_id,

	/* Unified NoC Flit Port (D$ + I$ merged via local atg_rt2) */
	output wire t_req_valid,
	input wire t_req_ready,
	output wire [FW-1:0] t_req_data,
	output wire t_req_last,
	input wire t_rsp_valid,
	output wire t_rsp_ready,
	input wire [RFW-1:0] t_rsp_data,

	/* Atomics */
	output wire at_valid,
	output wire [1:0] at_stage,
	input wire at_ready,
	output wire [3:0] at_op,
	output wire [29:0] at_addr,
	output wire [31:0] at_a,
	output wire [31:0] at_b,
	input wire at_rsp_valid,
	input wire [31:0] at_old,
	input wire at_error,

	/* Systolic array */
	output wire sa_push_valid,
	input wire sa_push_ready,
	output wire [NPHYS*32-1:0] sa_push_data,
	input wire sa_pop_valid,
	output wire sa_pop_ready,
	input wire [NPHYS*32-1:0] sa_pop_data,
	output wire sa_ctl_valid,
	output wire [31:0] sa_ctl_data,
	input wire [31:0] sa_qstat,
	input wire [31:0] sa_stat,
	input wire [31:0] sa_qtag,

	/* Status */
	output wire busy,
	output wire scrub_busy,
	output wire fault,
	output wire [31:0] fault_addr,
	output wire [3:0] fault_stage,
	output wire [3:0] fsm
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LINE_BITS = LINE_BYTES * 8;
	localparam [11:0] SU_ID12 = SU_INDEX;
	localparam [7:0] SU_ID_LO = SU_ID12[7:0];
	localparam [3:0] SU_ID_HI = SU_ID12[11:8];

	wire [WARP_W-1:0] unused_vl_slot, unused_fl_slot;

	wire pt_exp_end;
	wire [2:0] pt_exp_blk;
	wire [GRP_W-1:0] pt_exp_grp;
	wire [6:0] pt_exp_word;
	wire [NPHYS-1:0] pt_exp_mask;
	wire [NPHYS*32-1:0] pt_exp_data;
	assign pt_exp_packed = {pt_exp_end, pt_exp_blk, pt_exp_grp, pt_exp_word, pt_exp_mask, pt_exp_data};

	wire d_req_valid, d_req_ready, d_req_write;
	wire [LA_W-1:0] d_req_line;
	wire [LINE_BYTES-1:0] d_req_be;
	wire [LINE_BITS-1:0] d_req_wdata;
	wire [7:0] d_req_tag;
	wire d_rsp_valid, d_rsp_write, d_rsp_error;
	wire [7:0] d_rsp_tag;
	wire [LINE_BITS-1:0] d_rsp_rdata;

	wire i_req_valid, i_req_ready, i_req_write;
	wire [LA_W-1:0] i_req_line;
	wire [LINE_BYTES-1:0] i_req_be;
	wire [LINE_BITS-1:0] i_req_wdata;
	wire [7:0] i_req_tag;
	wire i_rsp_valid, i_rsp_write, i_rsp_error;
	wire [7:0] i_rsp_tag;
	wire [LINE_BITS-1:0] i_rsp_rdata;

	atg_su #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W),
		.NREGS(NREGS), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .NSU(NSU),
		.SU_INDEX(SU_INDEX), .FRAG_RESERVE(FRAG_RESERVE), .PACKED(PACKED),
		.PK_SHARED(PK_SHARED), .SUBGROUP(SUBGROUP), .HAS_SA(HAS_SA), .MS4(MS4),
		.HAS_MESH(HAS_MESH), .LDS_BYTES(LDS_BYTES), .PT_ENTRIES(PT_ENTRIES),
		.VARY_WORDS(VARY_WORDS), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT), .MRT_COUNT(MRT_COUNT), .DUAL_SOURCE(DUAL_SOURCE),
		.SHARED_PT(SHARED_PT), .HAS_GFX(HAS_GFX), .HAS_TU(HAS_TU)
	) u_su (
		.clk(clk), .rst_n(rst_n),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick), .cs_mesh(cs_mesh), .lc_kick(lc_kick), .inv(inv),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(unused_vl_slot),
		.vl_ptbase(vl_ptbase), .vl_avail(vl_avail),
		.vl_we(vl_we), .vl_reg(vl_reg), .vl_lane(vl_lane), .vl_data(vl_data),
		.vl_go(vl_go), .vl_mask(vl_mask), .vl_go_ptbase(vl_go_ptbase),
		.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_slot(unused_fl_slot),
		.fl_avail(fl_avail),
		.fl_we(fl_we), .fl_reg(fl_reg), .fl_lane(fl_lane), .fl_data(fl_data),
		.fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data),
		.fl_go(fl_go), .fl_mask(fl_mask), .fl_info(fl_info),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx), .pt_done(pt_done),
		.pt_exp_valid(pt_exp_valid), .pt_exp_ready(pt_exp_ready),
		.pt_exp_end(pt_exp_end), .pt_exp_blk(pt_exp_blk),
		.pt_exp_grp(pt_exp_grp), .pt_exp_word(pt_exp_word),
		.pt_exp_mask(pt_exp_mask), .pt_exp_data(pt_exp_data),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op),
		.tx_slot(tx_slot), .tx_samp_slot(tx_samp_slot), .tx_vs(tx_vs),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off),
		.tx_tag(tx_tag), .tx_last(tx_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag),
		.tr_data(tr_data), .tr_last(tr_last),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_color1(ex_color1),
		.ex_has_src1(ex_has_src1), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next), .ex_aux(ex_aux),
		.mesh_valid(mesh_valid), .mesh_ready(mesh_ready), .mesh_tri(mesh_tri),
		.mesh_last(mesh_last), .mesh_id(mesh_id),
		.d_req_valid(d_req_valid), .d_req_ready(d_req_ready), .d_req_write(d_req_write),
		.d_req_line(d_req_line), .d_req_be(d_req_be), .d_req_wdata(d_req_wdata),
		.d_req_tag(d_req_tag),
		.d_rsp_valid(d_rsp_valid), .d_rsp_write(d_rsp_write), .d_rsp_tag(d_rsp_tag),
		.d_rsp_rdata(d_rsp_rdata), .d_rsp_error(d_rsp_error),
		.i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_write(i_req_write),
		.i_req_line(i_req_line), .i_req_be(i_req_be), .i_req_wdata(i_req_wdata),
		.i_req_tag(i_req_tag),
		.i_rsp_valid(i_rsp_valid), .i_rsp_write(i_rsp_write), .i_rsp_tag(i_rsp_tag),
		.i_rsp_rdata(i_rsp_rdata), .i_rsp_error(i_rsp_error),
		.at_valid(at_valid), .at_stage(at_stage), .at_ready(at_ready),
		.at_op(at_op), .at_addr(at_addr), .at_a(at_a), .at_b(at_b),
		.at_rsp_valid(at_rsp_valid), .at_old(at_old), .at_error(at_error),
		.sa_push_valid(sa_push_valid), .sa_push_ready(sa_push_ready),
		.sa_push_data(sa_push_data),
		.sa_pop_valid(sa_pop_valid), .sa_pop_ready(sa_pop_ready),
		.sa_pop_data(sa_pop_data),
		.sa_ctl_valid(sa_ctl_valid), .sa_ctl_data(sa_ctl_data),
		.sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag),
		.busy(busy), .fsm(fsm),
		.scrub(scrub), .scrub_busy(scrub_busy),
		.fault(fault), .fault_addr(fault_addr), .fault_stage(fault_stage)
	);

	wire d_t_req_v, d_t_req_r, d_t_req_l, d_t_rsp_v, d_t_rsp_r;
	wire [FW-1:0] d_t_req_d;
	wire [RFW-1:0] d_t_rsp_d;

	wire i_t_req_v, i_t_req_r, i_t_req_l, i_t_rsp_v, i_t_rsp_r;
	wire [FW-1:0] i_t_req_d;
	wire [RFW-1:0] i_t_rsp_d;

	am_amb_to_rt #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
		.VRAM_AW(ADDR_W), .VRAM_BASE({ADDR_W{1'b0}}),
		.RW(SU_RW), .ROUTE(ROUTE_D), .CLIENT(SU_ID_LO), .CLIENT_HI(SU_ID_HI),
		.PRIO(0), .FW(FW), .RFW(RFW)
	) u_d_to_rt (
		.clk(clk), .rst_n(rst_n), .flush(flush), .hold(1'b0),
		.req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write),
		.req_line(d_req_line), .req_be(d_req_be), .req_wdata(d_req_wdata),
		.req_tag(d_req_tag), .req_chk(1'b0), .req_tbl(1'b0), .req_slot(6'd0),
		.req_session(session_id), .req_exec_type(d_req_write ? 2'b01 : 2'b00),
		.rsp_valid(d_rsp_valid), .rsp_write(d_rsp_write), .rsp_tag(d_rsp_tag),
		.rsp_rdata(d_rsp_rdata), .rsp_error(d_rsp_error),
		.t_req_valid(d_t_req_v), .t_req_ready(d_t_req_r),
		.t_req_data(d_t_req_d), .t_req_last(d_t_req_l),
		.t_rsp_valid(d_t_rsp_v), .t_rsp_ready(d_t_rsp_r), .t_rsp_data(d_t_rsp_d)
	);

	am_amb_to_rt #(
		.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
		.VRAM_AW(ADDR_W), .VRAM_BASE({ADDR_W{1'b0}}),
		.RW(SU_RW), .ROUTE(ROUTE_I), .CLIENT(SU_ID_LO), .CLIENT_HI(SU_ID_HI),
		.PRIO(0), .FW(FW), .RFW(RFW)
	) u_i_to_rt (
		.clk(clk), .rst_n(rst_n), .flush(flush), .hold(1'b0),
		.req_valid(i_req_valid), .req_ready(i_req_ready), .req_write(i_req_write),
		.req_line(i_req_line), .req_be(i_req_be), .req_wdata(i_req_wdata),
		.req_tag(i_req_tag), .req_chk(1'b0), .req_tbl(1'b0), .req_slot(6'd0),
		.req_session(session_id), .req_exec_type(2'b10),
		.rsp_valid(i_rsp_valid), .rsp_write(i_rsp_write), .rsp_tag(i_rsp_tag),
		.rsp_rdata(i_rsp_rdata), .rsp_error(i_rsp_error),
		.t_req_valid(i_t_req_v), .t_req_ready(i_t_req_r),
		.t_req_data(i_t_req_d), .t_req_last(i_t_req_l),
		.t_rsp_valid(i_t_rsp_v), .t_rsp_ready(i_t_rsp_r), .t_rsp_data(i_t_rsp_d)
	);

	wire unused_rt2_idle;
	atg_rt2 #(.FW(FW), .RFW(RFW), .RBIT(RBIT_SU)) u_rt2_su (
		.clk(clk), .rst_n(rst_n), .flush(flush),
		.c0_req_valid(d_t_req_v), .c0_req_ready(d_t_req_r),
		.c0_req_data(d_t_req_d), .c0_req_last(d_t_req_l),
		.c1_req_valid(i_t_req_v), .c1_req_ready(i_t_req_r),
		.c1_req_data(i_t_req_d), .c1_req_last(i_t_req_l),
		.p_req_valid(t_req_valid), .p_req_ready(t_req_ready),
		.p_req_data(t_req_data), .p_req_last(t_req_last),
		.p_rsp_valid(t_rsp_valid), .p_rsp_ready(t_rsp_ready), .p_rsp_data(t_rsp_data),
		.c0_rsp_valid(d_t_rsp_v), .c0_rsp_ready(d_t_rsp_r), .c0_rsp_data(d_t_rsp_d),
		.c1_rsp_valid(i_t_rsp_v), .c1_rsp_ready(i_t_rsp_r), .c1_rsp_data(i_t_rsp_d),
		.rsp_idle(unused_rt2_idle)
	);

	wire unused_ok = &{1'b0, unused_vl_slot, unused_fl_slot, unused_rt2_idle,
		d_t_rsp_r, i_t_rsp_r};
endmodule

`default_nettype wire
