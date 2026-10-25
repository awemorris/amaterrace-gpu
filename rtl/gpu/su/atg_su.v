/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su: One shader unit (design §3): the warp scheduler, the front end
 * (fetch, I$, decode), the scoreboard issue stage, the register file and
 * operand collection, the execution units on one execution bus, the
 * write-back arbiter, and its memory ports (D$ client, I$+constant client,
 * atomics), the VF/RX inputs, the PT, the TU and ROP ports and the
 * reserved SA port.
 *
 * Wiring of its children; see spec/gpu/su/atg_su.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter NREGS = 32,	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
	parameter SB_ENTRIES = 4,	/* Scoreboard entries per warp (KC705 8) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6,	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
	parameter NSU = 1,	/* SUs in the GPU */
	parameter SU_INDEX = 0,	/* This SU's number */
	parameter FRAG_RESERVE = 1,	/* Slots kept for fragment warps */
	parameter PACKED = 0,	/* Packed fp16 arithmetic */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot */
	parameter HAS_SA = 0,	/* SA attached (v1 0) */
	parameter MS4 = 0,	/* 4x multisampling (CAPS[29]): texsz.s */
	parameter LDS_BYTES = 4096,	/* Shared memory bytes */
	parameter PT_ENTRIES = 64,	/* PT vertices */
	parameter VARY_WORDS = 16,	/* Varying words per vertex, at most 64 (KC705 64) */
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From the CP */
	input wire cs_kick,
	input wire lc_kick,
	input wire [3:0] inv,
	/* Vertex warps from the VF */
	input wire vl_req,
	output wire vl_gnt,
	output wire [WARP_W-1:0] vl_slot,
	output wire [7:0] vl_ptbase,
	input wire vl_we,
	input wire [5:0] vl_reg,
	input wire [4:0] vl_lane,
	input wire [31:0] vl_data,
	input wire vl_go,
	input wire [31:0] vl_mask,
	/* Fragment warps from the RX */
	input wire fl_req,
	output wire fl_gnt,
	output wire [WARP_W-1:0] fl_slot,
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
	/* PT read for the RX */
	input wire pt_rd,
	input wire [7:0] pt_idx,
	input wire [6:0] pt_word,
	output wire [31:0] pt_rdata,
	input wire pt_free,
	input wire [7:0] pt_free_idx,
	output wire [7:0] pt_done,
	/* TU */
	output wire tx_valid,
	input wire tx_ready,
	output wire [7:0] tx_op,
	output wire [3:0] tx_slot,
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
	output wire [127:0] ex_depth,
	output wire ex_last,
	input wire [15:0] ex_next,
	output wire [153:0] ex_aux,	/* {rt, qlast, qfirst, nocol, front, d_s, zexp, smask} (atg_su_exp) */
	/* AMB client port (design §4.1) */
	output wire d_req_valid,
	input wire d_req_ready,
	output wire d_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] d_req_line,
	output wire [LINE_BYTES-1:0] d_req_be,
	output wire [LINE_BYTES*8-1:0] d_req_wdata,
	output wire [7:0] d_req_tag,
	input wire d_rsp_valid,
	input wire d_rsp_write,
	input wire [7:0] d_rsp_tag,
	input wire [LINE_BYTES*8-1:0] d_rsp_rdata,
	input wire d_rsp_error,
	/* AMB client port (design §4.1) */
	output wire i_req_valid,
	input wire i_req_ready,
	output wire i_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] i_req_line,
	output wire [LINE_BYTES-1:0] i_req_be,
	output wire [LINE_BYTES*8-1:0] i_req_wdata,
	output wire [7:0] i_req_tag,
	input wire i_rsp_valid,
	input wire i_rsp_write,
	input wire [7:0] i_rsp_tag,
	input wire [LINE_BYTES*8-1:0] i_rsp_rdata,
	input wire i_rsp_error,
	/* Atomics (atg_mc_atom) */
	output wire at_valid,
	input wire at_ready,
	output wire [3:0] at_op,
	output wire [29:0] at_addr,
	output wire [31:0] at_a,
	output wire [31:0] at_b,
	input wire at_rsp_valid,
	input wire [31:0] at_old,
	input wire at_error,
	/* Systolic array (reserved, design §3.9) */
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
	output wire fault,
	output wire [31:0] fault_addr
);
	localparam DW = NPHYS * 32;
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;

	/* Front end. */
	wire f_valid, f_ready;
	wire [WARP_W-1:0] f_warp;
	wire [15:0] f_pc;
	wire [31:0] f_addr;
	wire ic_req, ic_ready, ic_rvalid;
	wire [31:0] ic_addr;
	wire [63:0] ic_rdata;
	wire d_valid, d_ready;
	wire [WARP_W-1:0] d_warp;
	wire [15:0] d_pc;
	wire [63:0] d_instr;
	wire u_valid, u_ready;
	wire [WARP_W-1:0] u_warp;
	wire [15:0] u_pc;
	wire [UOP_W-1:0] u_uop;
	wire i_valid, i_ready;
	wire [WARP_W-1:0] i_warp;
	wire [15:0] i_pc;
	wire [UOP_W-1:0] i_uop;
	wire [SBE_W:0] i_sbe;
	wire fb_valid;
	wire [WARP_W-1:0] fb_warp;
	wire [1:0] fb_kind;
	wire [NWARPS-1:0] wake;
	wire wc_valid;
	wire [WARP_W-1:0] wc_warp;
	wire [1:0] wc_op;
	wire [15:0] wc_pc;
	wire [WARP_W-1:0] q_warp;
	wire [159:0] q_info;
	wire [31:0] q_exec, q_killed;
	wire init_valid;
	wire [WARP_W-1:0] init_warp;
	wire [31:0] init_mask;
	wire pt_ok, xr_valid;
	wire [WARP_W-1:0] xr_warp;
	wire sched_busy, sb_busy, cbank_busy;
	wire sb_fault;
	wire [15:0] sb_fault_pc;
	/* Scoreboard releases, write port, rq. */
	wire rel_valid, wb_stall;
	wire [WARP_W-1:0] rel_warp;
	wire [SBE_W:0] rel_sbe;
	wire [2:0] rel_cls;
	wire w_en;
	wire [WARP_W-1:0] w_warp;
	wire [GRP_W-1:0] w_grp;
	wire [5:0] w_reg;
	wire [DW-1:0] w_data;
	wire [NPHYS-1:0] w_lanes;
	wire r_en;
	wire [WARP_W-1:0] r_warp;
	wire [GRP_W-1:0] r_grp;
	wire [17:0] r_regs;
	wire [DW-1:0] r_data1, r_data2, r_data3;
	wire cr_en;
	wire [14:0] cr_idx;
	wire [95:0] cr_data;
	wire rq_pop, rq_push, rq_empty, rq_full;
	wire [DW-1:0] rq_pop_data, rq_push_data;
	/* The execution bus. */
	wire x_valid, x_last;
	wire [WARP_W-1:0] x_warp;
	wire [GRP_W-1:0] x_grp;
	wire [SBE_W:0] x_sbe;
	wire [15:0] x_pc;
	wire [UOP_W-1:0] x_uop;
	wire [DW-1:0] x_a, x_b, x_c;
	wire [2*NPHYS-1:0] x_mask;
	wire [31:0] x_info;
	wire alu_ready;
	wire fpu_ready;
	wire pk_ready;
	wire lane_ready;
	wire lda_ready;
	wire exec_ready;
	wire lsu_ready;
	wire lds_ready;
	wire cbank_ready;
	wire tex_ready;
	wire xu_ready;
	wire div_ready;
	wire exp_ready;
	wire [15:0] unit_ready = {1'b1, 1'b1, exec_ready, lane_ready, lda_ready, exp_ready,
		tex_ready, cbank_ready, lds_ready, lsu_ready, div_ready, xu_ready, pk_ready, fpu_ready,
		alu_ready, 1'b1};
	/* The last group of an instruction leaves atg_su_opd (atg_su_sb's interlock). */
	wire x_end = x_valid && x_last && unit_ready[x_uop[3:0]];
	/* Short results. */
	wire alu_s_valid;
	wire [WARP_W-1:0] alu_s_warp;
	wire [GRP_W-1:0] alu_s_grp;
	wire [6:0] alu_s_rd;
	wire [DW-1:0] alu_s_data;
	wire [NPHYS-1:0] alu_s_lanes;
	wire fpu_s_valid;
	wire [WARP_W-1:0] fpu_s_warp;
	wire [GRP_W-1:0] fpu_s_grp;
	wire [6:0] fpu_s_rd;
	wire [DW-1:0] fpu_s_data;
	wire [NPHYS-1:0] fpu_s_lanes;
	wire pk_s_valid;
	wire [WARP_W-1:0] pk_s_warp;
	wire [GRP_W-1:0] pk_s_grp;
	wire [6:0] pk_s_rd;
	wire [DW-1:0] pk_s_data;
	wire [NPHYS-1:0] pk_s_lanes;
	wire lane_s_valid;
	wire [WARP_W-1:0] lane_s_warp;
	wire [GRP_W-1:0] lane_s_grp;
	wire [6:0] lane_s_rd;
	wire [DW-1:0] lane_s_data;
	wire [NPHYS-1:0] lane_s_lanes;
	wire lda_s_valid;
	wire [WARP_W-1:0] lda_s_warp;
	wire [GRP_W-1:0] lda_s_grp;
	wire [6:0] lda_s_rd;
	wire [DW-1:0] lda_s_data;
	wire [NPHYS-1:0] lda_s_lanes;
	wire exec_s_valid;
	wire [WARP_W-1:0] exec_s_warp;
	wire [GRP_W-1:0] exec_s_grp;
	wire [6:0] exec_s_rd;
	wire [DW-1:0] exec_s_data;
	wire [NPHYS-1:0] exec_s_lanes;
	/* Long results. */
	wire lsu_l_valid, lsu_l_ready, lsu_l_wr, lsu_l_last;
	wire [WARP_W-1:0] lsu_l_warp;
	wire [GRP_W-1:0] lsu_l_grp;
	wire [6:0] lsu_l_rd;
	wire [DW-1:0] lsu_l_data;
	wire [NPHYS-1:0] lsu_l_lanes;
	wire [SBE_W:0] lsu_l_sbe;
	wire [2:0] lsu_l_cls;
	wire lds_l_valid, lds_l_ready, lds_l_wr, lds_l_last;
	wire [WARP_W-1:0] lds_l_warp;
	wire [GRP_W-1:0] lds_l_grp;
	wire [6:0] lds_l_rd;
	wire [DW-1:0] lds_l_data;
	wire [NPHYS-1:0] lds_l_lanes;
	wire [SBE_W:0] lds_l_sbe;
	wire [2:0] lds_l_cls;
	wire cbank_l_valid, cbank_l_ready, cbank_l_wr, cbank_l_last;
	wire [WARP_W-1:0] cbank_l_warp;
	wire [GRP_W-1:0] cbank_l_grp;
	wire [6:0] cbank_l_rd;
	wire [DW-1:0] cbank_l_data;
	wire [NPHYS-1:0] cbank_l_lanes;
	wire [SBE_W:0] cbank_l_sbe;
	wire [2:0] cbank_l_cls;
	wire tex_l_valid, tex_l_ready, tex_l_wr, tex_l_last;
	wire [WARP_W-1:0] tex_l_warp;
	wire [GRP_W-1:0] tex_l_grp;
	wire [6:0] tex_l_rd;
	wire [DW-1:0] tex_l_data;
	wire [NPHYS-1:0] tex_l_lanes;
	wire [SBE_W:0] tex_l_sbe;
	wire [2:0] tex_l_cls;
	wire xu_l_valid, xu_l_ready, xu_l_wr, xu_l_last;
	wire [WARP_W-1:0] xu_l_warp;
	wire [GRP_W-1:0] xu_l_grp;
	wire [6:0] xu_l_rd;
	wire [DW-1:0] xu_l_data;
	wire [NPHYS-1:0] xu_l_lanes;
	wire [SBE_W:0] xu_l_sbe;
	wire [2:0] xu_l_cls;
	wire div_l_valid, div_l_ready, div_l_wr, div_l_last;
	wire [WARP_W-1:0] div_l_warp;
	wire [GRP_W-1:0] div_l_grp;
	wire [6:0] div_l_rd;
	wire [DW-1:0] div_l_data;
	wire [NPHYS-1:0] div_l_lanes;
	wire [SBE_W:0] div_l_sbe;
	wire [2:0] div_l_cls;
	/* The LSU's D$ port, and the I$ and constant bank behind one MC port. */
	wire dc_req_valid, dc_req_ready, dc_req_write, dc_rsp_valid, dc_rsp_write, dc_rsp_error;
	wire [LA_W-1:0] dc_req_line;
	wire [LINE_BYTES-1:0] dc_req_be;
	wire [LB-1:0] dc_req_wdata, dc_rsp_rdata;
	wire [7:0] dc_req_tag, dc_rsp_tag;
	wire ic_m_req_valid, ic_m_req_ready, ic_m_req_write, ic_m_rsp_valid, ic_m_rsp_write, ic_m_rsp_error;
	wire [LA_W-1:0] ic_m_req_line;
	wire [LINE_BYTES-1:0] ic_m_req_be;
	wire [LB-1:0] ic_m_req_wdata, ic_m_rsp_rdata;
	wire [7:0] ic_m_req_tag, ic_m_rsp_tag;
	wire cb_m_req_valid, cb_m_req_ready, cb_m_req_write, cb_m_rsp_valid, cb_m_rsp_write, cb_m_rsp_error;
	wire [LA_W-1:0] cb_m_req_line;
	wire [LINE_BYTES-1:0] cb_m_req_be;
	wire [LB-1:0] cb_m_req_wdata, cb_m_rsp_rdata;
	wire [7:0] cb_m_req_tag, cb_m_rsp_tag;
	wire dc_inv;
	wire [1:0] im_rsp_valid_v;
	wire im_rsp_write, im_rsp_error;
	wire [7:0] im_rsp_tag;
	wire [LB-1:0] im_rsp_rdata;

	atg_su_sched #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .NSU(NSU), .SU_INDEX(SU_INDEX),
		.FRAG_RESERVE(FRAG_RESERVE)
	) sched (
		.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata),
		.cs_kick(cs_kick),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_slot(vl_slot), .vl_go(vl_go), .vl_mask(vl_mask),
		.fl_req(fl_req), .fl_gnt(fl_gnt), .fl_slot(fl_slot), .fl_go(fl_go), .fl_mask(fl_mask),
		.fl_info(fl_info),
		.f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc), .f_addr(f_addr),
		.fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake),
		.wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
		.q_warp(q_warp), .q_info(q_info),
		.init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask),
		.pt_ok(pt_ok), .xr_valid(xr_valid), .xr_warp(xr_warp), .busy(sched_busy)
	);

	atg_su_fetch #(.WARP_W(WARP_W)) fetch (
		.clk(clk), .rst_n(rst_n),
		.f_valid(f_valid), .f_ready(f_ready), .f_warp(f_warp), .f_pc(f_pc), .f_addr(f_addr),
		.ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr), .ic_rvalid(ic_rvalid),
		.ic_rdata(ic_rdata),
		.d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc), .d_instr(d_instr)
	);

	atg_su_icache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) icache (
		.clk(clk), .rst_n(rst_n),
		.ic_req(ic_req), .ic_ready(ic_ready), .ic_addr(ic_addr), .ic_rvalid(ic_rvalid),
		.ic_rdata(ic_rdata), .inv(inv[3]),
		.req_valid(ic_m_req_valid), .req_ready(ic_m_req_ready), .req_write(ic_m_req_write), .req_line(ic_m_req_line), .req_be(ic_m_req_be), .req_wdata(ic_m_req_wdata), .req_tag(ic_m_req_tag), .rsp_valid(ic_m_rsp_valid), .rsp_write(ic_m_rsp_write), .rsp_tag(ic_m_rsp_tag), .rsp_rdata(ic_m_rsp_rdata), .rsp_error(ic_m_rsp_error)
	);

	atg_su_dec #(
		.WARP_W(WARP_W), .UOP_W(UOP_W), .NREGS(NREGS), .PACKED(PACKED), .SUBGROUP(SUBGROUP),
		.HAS_SA(HAS_SA), .MS4(MS4)
	) dec (
		.clk(clk), .rst_n(rst_n),
		.d_valid(d_valid), .d_ready(d_ready), .d_warp(d_warp), .d_pc(d_pc), .d_instr(d_instr),
		.u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc), .u_uop(u_uop)
	);

	atg_su_sb #(
		.NPHYS(NPHYS), .SHORT_LAT(SHORT_LAT), .NWARPS(NWARPS), .WARP_W(WARP_W), .SB_ENTRIES(SB_ENTRIES), .SBE_W(SBE_W), .UOP_W(UOP_W)
	) sb (
		.clk(clk), .rst_n(rst_n),
		.u_valid(u_valid), .u_ready(u_ready), .u_warp(u_warp), .u_pc(u_pc), .u_uop(u_uop),
		.i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop),
		.i_sbe(i_sbe), .x_end(x_end),
		.fb_valid(fb_valid), .fb_warp(fb_warp), .fb_kind(fb_kind), .wake(wake),
		.rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
		.wb_stall(wb_stall), .rq_empty(rq_empty), .rq_full(rq_full),
		.busy(sb_busy), .fault(sb_fault), .fault_pc(sb_fault_pc)
	);

	atg_su_rf #(
		.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .NREGS(NREGS)
	) rf (
		.clk(clk), .rst_n(rst_n),
		.w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data),
		.w_lanes(w_lanes),
		.r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_reg1(r_regs[5:0]), .r_reg2(r_regs[11:6]),
		.r_reg3(r_regs[17:12]), .r_data1(r_data1), .r_data2(r_data2), .r_data3(r_data3)
	);

	atg_su_opd #(
		.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W),
		.WARP_BASE(SU_INDEX * NWARPS)
	) opd (
		.clk(clk), .rst_n(rst_n),
		.i_valid(i_valid), .i_ready(i_ready), .i_warp(i_warp), .i_pc(i_pc), .i_uop(i_uop),
		.i_sbe(i_sbe),
		.r_en(r_en), .r_warp(r_warp), .r_grp(r_grp), .r_regs(r_regs),
		.r_data({r_data3, r_data2, r_data1}),
		.cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
		.q_warp(q_warp), .q_info(q_info), .q_exec(q_exec), .q_killed(q_killed),
		.rq_pop(rq_pop), .rq_data(rq_pop_data),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info),
		.unit_ready(unit_ready)
	);

	atg_su_alu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT)) alu (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(alu_ready),
		.s_valid(alu_s_valid), .s_warp(alu_s_warp), .s_grp(alu_s_grp), .s_rd(alu_s_rd),
		.s_data(alu_s_data), .s_lanes(alu_s_lanes)
	);

	atg_su_fpu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT)) fpu (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(fpu_ready),
		.s_valid(fpu_s_valid), .s_warp(fpu_s_warp), .s_grp(fpu_s_grp), .s_rd(fpu_s_rd),
		.s_data(fpu_s_data), .s_lanes(fpu_s_lanes)
	);

	atg_su_pk #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT), .PACKED(PACKED)) pk (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(pk_ready),
		.s_valid(pk_s_valid), .s_warp(pk_s_warp), .s_grp(pk_s_grp), .s_rd(pk_s_rd),
		.s_data(pk_s_data), .s_lanes(pk_s_lanes)
	);

	atg_su_lane #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT), .SUBGROUP(SUBGROUP)) lane (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(lane_ready),
		.s_valid(lane_s_valid), .s_warp(lane_s_warp), .s_grp(lane_s_grp), .s_rd(lane_s_rd),
		.s_data(lane_s_data), .s_lanes(lane_s_lanes)
	);

	atg_su_lda #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT), .VARY_WORDS(VARY_WORDS)) lda (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(lda_ready),
		.s_valid(lda_s_valid), .s_warp(lda_s_warp), .s_grp(lda_s_grp), .s_rd(lda_s_rd),
		.s_data(lda_s_data), .s_lanes(lda_s_lanes),
		.pw_we(fl_pw_we), .pw_warp(fl_slot), .pw_addr(fl_pw_addr), .pw_data(fl_pw_data)
	);

	atg_su_exec #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .SHORT_LAT(SHORT_LAT)) exec (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(exec_ready),
		.s_valid(exec_s_valid), .s_warp(exec_s_warp), .s_grp(exec_s_grp), .s_rd(exec_s_rd),
		.s_data(exec_s_data), .s_lanes(exec_s_lanes),
		.wc_valid(wc_valid), .wc_warp(wc_warp), .wc_op(wc_op), .wc_pc(wc_pc),
		.q_warp(q_warp), .q_exec(q_exec), .q_killed(q_killed),
		.init_valid(init_valid), .init_warp(init_warp), .init_mask(init_mask)
	);

	atg_su_lsu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) lsu (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(lsu_ready),
		.l_valid(lsu_l_valid), .l_ready(lsu_l_ready), .l_warp(lsu_l_warp),
		.l_grp(lsu_l_grp), .l_rd(lsu_l_rd), .l_data(lsu_l_data), .l_lanes(lsu_l_lanes),
		.l_wr(lsu_l_wr), .l_last(lsu_l_last), .l_sbe(lsu_l_sbe), .l_cls(lsu_l_cls),
		.dc_req_valid(dc_req_valid), .dc_req_ready(dc_req_ready), .dc_req_write(dc_req_write), .dc_req_line(dc_req_line), .dc_req_be(dc_req_be), .dc_req_wdata(dc_req_wdata), .dc_req_tag(dc_req_tag), .dc_rsp_valid(dc_rsp_valid), .dc_rsp_write(dc_rsp_write), .dc_rsp_tag(dc_rsp_tag), .dc_rsp_rdata(dc_rsp_rdata), .dc_rsp_error(dc_rsp_error),
		.at_valid(at_valid), .at_ready(at_ready), .at_op(at_op), .at_addr(at_addr),
		.at_a(at_a), .at_b(at_b), .at_rsp_valid(at_rsp_valid), .at_old(at_old),
		.at_error(at_error), .dc_inv(dc_inv)
	);

	atg_su_lds #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .LDS_BYTES(LDS_BYTES)) lds (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(lds_ready),
		.l_valid(lds_l_valid), .l_ready(lds_l_ready), .l_warp(lds_l_warp),
		.l_grp(lds_l_grp), .l_rd(lds_l_rd), .l_data(lds_l_data), .l_lanes(lds_l_lanes),
		.l_wr(lds_l_wr), .l_last(lds_l_last), .l_sbe(lds_l_sbe), .l_cls(lds_l_cls)
	);

	atg_su_cbank #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W), .ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) cbank (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(cbank_ready),
		.l_valid(cbank_l_valid), .l_ready(cbank_l_ready), .l_warp(cbank_l_warp),
		.l_grp(cbank_l_grp), .l_rd(cbank_l_rd), .l_data(cbank_l_data), .l_lanes(cbank_l_lanes),
		.l_wr(cbank_l_wr), .l_last(cbank_l_last), .l_sbe(cbank_l_sbe), .l_cls(cbank_l_cls),
		.cr_en(cr_en), .cr_idx(cr_idx), .cr_data(cr_data),
		.st_we(st_we), .st_idx(st_idx), .st_wdata(st_wdata), .lc_kick(lc_kick),
		.inv(inv[2]), .busy(cbank_busy),
		.req_valid(cb_m_req_valid), .req_ready(cb_m_req_ready), .req_write(cb_m_req_write), .req_line(cb_m_req_line), .req_be(cb_m_req_be), .req_wdata(cb_m_req_wdata), .req_tag(cb_m_req_tag), .rsp_valid(cb_m_rsp_valid), .rsp_write(cb_m_rsp_write), .rsp_tag(cb_m_rsp_tag), .rsp_rdata(cb_m_rsp_rdata), .rsp_error(cb_m_rsp_error)
	);

	atg_su_tex #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W)) tex (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(tex_ready),
		.l_valid(tex_l_valid), .l_ready(tex_l_ready), .l_warp(tex_l_warp),
		.l_grp(tex_l_grp), .l_rd(tex_l_rd), .l_data(tex_l_data), .l_lanes(tex_l_lanes),
		.l_wr(tex_l_wr), .l_last(tex_l_last), .l_sbe(tex_l_sbe), .l_cls(tex_l_cls),
		.tx_valid(tx_valid), .tx_ready(tx_ready), .tx_op(tx_op), .tx_slot(tx_slot), .tx_vs(tx_vs),
		.tx_mask(tx_mask), .tx_coord(tx_coord), .tx_off(tx_off), .tx_tag(tx_tag),
		.tx_last(tx_last),
		.tr_valid(tr_valid), .tr_ready(tr_ready), .tr_tag(tr_tag), .tr_data(tr_data),
		.tr_last(tr_last)
	);

	atg_su_xu #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W)) xu (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(xu_ready),
		.l_valid(xu_l_valid), .l_ready(xu_l_ready), .l_warp(xu_l_warp),
		.l_grp(xu_l_grp), .l_rd(xu_l_rd), .l_data(xu_l_data), .l_lanes(xu_l_lanes),
		.l_wr(xu_l_wr), .l_last(xu_l_last), .l_sbe(xu_l_sbe), .l_cls(xu_l_cls)
	);

	atg_su_div #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W)) div (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(div_ready),
		.l_valid(div_l_valid), .l_ready(div_l_ready), .l_warp(div_l_warp),
		.l_grp(div_l_grp), .l_rd(div_l_rd), .l_data(div_l_data), .l_lanes(div_l_lanes),
		.l_wr(div_l_wr), .l_last(div_l_last), .l_sbe(div_l_sbe), .l_cls(div_l_cls)
	);

	atg_su_dcache #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT)) dcache (
		.clk(clk), .rst_n(rst_n), .inv(inv[0] || dc_inv),
		.u_req_valid(dc_req_valid), .u_req_ready(dc_req_ready), .u_req_write(dc_req_write), .u_req_line(dc_req_line), .u_req_be(dc_req_be), .u_req_wdata(dc_req_wdata), .u_req_tag(dc_req_tag), .u_rsp_valid(dc_rsp_valid), .u_rsp_write(dc_rsp_write), .u_rsp_tag(dc_rsp_tag), .u_rsp_rdata(dc_rsp_rdata), .u_rsp_error(dc_rsp_error),
		.m_req_valid(d_req_valid), .m_req_ready(d_req_ready), .m_req_write(d_req_write), .m_req_line(d_req_line), .m_req_be(d_req_be), .m_req_wdata(d_req_wdata), .m_req_tag(d_req_tag), .m_rsp_valid(d_rsp_valid), .m_rsp_write(d_rsp_write), .m_rsp_tag(d_rsp_tag), .m_rsp_rdata(d_rsp_rdata), .m_rsp_error(d_rsp_error)
	);

	atg_su_exp #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .UOP_W(UOP_W)) exp (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_last(x_last), .x_sbe(x_sbe),
		.x_pc(x_pc), .x_uop(x_uop), .x_a(x_a), .x_b(x_b), .x_c(x_c), .x_mask(x_mask),
		.x_info(x_info), .x_ready(exp_ready),
		.ex_valid(ex_valid), .ex_ready(ex_ready), .ex_seq(ex_seq), .ex_xy(ex_xy),
		.ex_mask(ex_mask), .ex_color(ex_color), .ex_depth(ex_depth), .ex_last(ex_last),
		.ex_next(ex_next),
		.fl_we(fl_we), .fl_slot(fl_slot), .fl_reg(fl_reg), .fl_lane(fl_lane), .fl_data(fl_data),
		.fl_go(fl_go), .fl_info(fl_info),
		.fl_pw_we(fl_pw_we), .fl_pw_addr(fl_pw_addr), .fl_pw_data(fl_pw_data), .ex_aux(ex_aux),
		.xr_valid(xr_valid), .xr_warp(xr_warp),
		.wc_end(wc_valid && wc_op == 2'd1), .wc_warp(wc_warp)
	);

	atg_su_pt #(.NPHYS(NPHYS), .NWARPS(NWARPS), .WARP_W(WARP_W), .GRP_W(GRP_W), .UOP_W(UOP_W), .PT_ENTRIES(PT_ENTRIES), .VARY_WORDS(VARY_WORDS)) pt (
		.clk(clk), .rst_n(rst_n),
		.x_valid(x_valid), .x_warp(x_warp), .x_grp(x_grp), .x_uop(x_uop), .x_b(x_b),
		.x_mask(x_mask), .x_info(x_info),
		.pt_rd(pt_rd), .pt_idx(pt_idx), .pt_word(pt_word), .pt_rdata(pt_rdata),
		.pt_free(pt_free), .pt_free_idx(pt_free_idx),
		.pt_ok(pt_ok), .pt_take(vl_gnt), .pt_warp(vl_slot), .pt_base(vl_ptbase),
		.vl_go(vl_go), .vl_mask(vl_mask), .pt_done(pt_done),
		.wc_end(wc_valid && wc_op == 2'd1), .wc_warp(wc_warp)
	);

	atg_su_rq #(.NPHYS(NPHYS), .UOP_W(UOP_W), .HAS_SA(HAS_SA)) rq (
		.clk(clk), .rst_n(rst_n),
		.pop(rq_pop), .pop_data(rq_pop_data), .push(rq_push), .push_data(rq_push_data),
		.empty(rq_empty), .full(rq_full),
		.ctl_valid(x_valid && x_grp == {GRP_W{1'b0}} && x_uop[3:0] == 4'd15),
		.ctl_data(x_a[31:0]),
		.sa_push_valid(sa_push_valid), .sa_push_ready(sa_push_ready),
		.sa_push_data(sa_push_data), .sa_pop_valid(sa_pop_valid), .sa_pop_ready(sa_pop_ready),
		.sa_pop_data(sa_pop_data), .sa_ctl_valid(sa_ctl_valid), .sa_ctl_data(sa_ctl_data),
		.sa_qstat(sa_qstat), .sa_stat(sa_stat), .sa_qtag(sa_qtag)
	);

	atg_su_wb #(.NPHYS(NPHYS), .WARP_W(WARP_W), .GRP_W(GRP_W), .SBE_W(SBE_W), .NS(6), .NL(6)) wb (
		.clk(clk), .rst_n(rst_n),
		.s_valid({exec_s_valid, lda_s_valid, lane_s_valid, pk_s_valid, fpu_s_valid, alu_s_valid}),
		.s_warp({exec_s_warp, lda_s_warp, lane_s_warp, pk_s_warp, fpu_s_warp, alu_s_warp}),
		.s_grp({exec_s_grp, lda_s_grp, lane_s_grp, pk_s_grp, fpu_s_grp, alu_s_grp}),
		.s_rd({exec_s_rd, lda_s_rd, lane_s_rd, pk_s_rd, fpu_s_rd, alu_s_rd}),
		.s_data({exec_s_data, lda_s_data, lane_s_data, pk_s_data, fpu_s_data, alu_s_data}),
		.s_lanes({exec_s_lanes, lda_s_lanes, lane_s_lanes, pk_s_lanes, fpu_s_lanes, alu_s_lanes}),
		.l_valid({div_l_valid, xu_l_valid, tex_l_valid, cbank_l_valid, lds_l_valid, lsu_l_valid}),
		.l_ready({div_l_ready, xu_l_ready, tex_l_ready, cbank_l_ready, lds_l_ready, lsu_l_ready}),
		.l_warp({div_l_warp, xu_l_warp, tex_l_warp, cbank_l_warp, lds_l_warp, lsu_l_warp}),
		.l_grp({div_l_grp, xu_l_grp, tex_l_grp, cbank_l_grp, lds_l_grp, lsu_l_grp}),
		.l_rd({div_l_rd, xu_l_rd, tex_l_rd, cbank_l_rd, lds_l_rd, lsu_l_rd}),
		.l_data({div_l_data, xu_l_data, tex_l_data, cbank_l_data, lds_l_data, lsu_l_data}),
		.l_lanes({div_l_lanes, xu_l_lanes, tex_l_lanes, cbank_l_lanes, lds_l_lanes, lsu_l_lanes}),
		.l_wr({div_l_wr, xu_l_wr, tex_l_wr, cbank_l_wr, lds_l_wr, lsu_l_wr}),
		.l_last({div_l_last, xu_l_last, tex_l_last, cbank_l_last, lds_l_last, lsu_l_last}),
		.l_sbe({div_l_sbe, xu_l_sbe, tex_l_sbe, cbank_l_sbe, lds_l_sbe, lsu_l_sbe}),
		.l_cls({div_l_cls, xu_l_cls, tex_l_cls, cbank_l_cls, lds_l_cls, lsu_l_cls}),
		.in_we({fl_we, vl_we}), .in_warp({fl_slot, vl_slot}), .in_reg({fl_reg, vl_reg}),
		.in_lane({fl_lane, vl_lane}), .in_data({fl_data, vl_data}),
		.w_en(w_en), .w_warp(w_warp), .w_grp(w_grp), .w_reg(w_reg), .w_data(w_data),
		.w_lanes(w_lanes),
		.rel_valid(rel_valid), .rel_warp(rel_warp), .rel_sbe(rel_sbe), .rel_cls(rel_cls),
		.rq_push(rq_push), .rq_data(rq_push_data), .wb_stall(wb_stall)
	);

	/* The I$ (requester 0) and the constant bank (1) share MC client i_*. */
	am_amb_mux #(.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT), .N(2), .ID_W(1)) imux (
		.clk(clk), .rst_n(rst_n),
		.i_req_valid({cb_m_req_valid, ic_m_req_valid}),
		.i_req_ready({cb_m_req_ready, ic_m_req_ready}),
		.i_req_write({cb_m_req_write, ic_m_req_write}),
		.i_req_line({cb_m_req_line, ic_m_req_line}),
		.i_req_be({cb_m_req_be, ic_m_req_be}),
		.i_req_wdata({cb_m_req_wdata, ic_m_req_wdata}),
		.i_req_tag({cb_m_req_tag, ic_m_req_tag}),
		.i_rsp_valid(im_rsp_valid_v), .i_rsp_write(im_rsp_write), .i_rsp_tag(im_rsp_tag),
		.i_rsp_rdata(im_rsp_rdata), .i_rsp_error(im_rsp_error),
		.o_req_valid(i_req_valid), .o_req_ready(i_req_ready), .o_req_write(i_req_write), .o_req_line(i_req_line), .o_req_be(i_req_be), .o_req_wdata(i_req_wdata), .o_req_tag(i_req_tag), .o_rsp_valid(i_rsp_valid), .o_rsp_write(i_rsp_write), .o_rsp_tag(i_rsp_tag), .o_rsp_rdata(i_rsp_rdata), .o_rsp_error(i_rsp_error)
	);

	assign ic_m_rsp_valid = im_rsp_valid_v[0];
	assign cb_m_rsp_valid = im_rsp_valid_v[1];
	assign ic_m_rsp_write = im_rsp_write;
	assign cb_m_rsp_write = im_rsp_write;
	assign ic_m_rsp_tag = im_rsp_tag;
	assign cb_m_rsp_tag = im_rsp_tag;
	assign ic_m_rsp_rdata = im_rsp_rdata;
	assign cb_m_rsp_rdata = im_rsp_rdata;
	assign ic_m_rsp_error = im_rsp_error;
	assign cb_m_rsp_error = im_rsp_error;

	assign busy = sched_busy || sb_busy || cbank_busy;
	assign fault = sb_fault;
	assign fault_addr = {16'd0, sb_fault_pc};

	wire unused_ok = &{1'b0, inv[1]};	/* T$: the TU's */
endmodule

`default_nettype wire
