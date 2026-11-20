/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_noc: Unified Fat-Tree NoC interconnect for atg_mc (USE_NOC_FABRIC = 1).
 *
 * Drop-in replacement for atg_mc_tree for all ASIC configurations
 * (docs/noc_and_mmu_architecture.md §4.3):
 *   - ROOT_CLIENT (DC) gets the dedicated root channel s_* (route[0] = 0).
 *   - Tree root u_rt_root (atg_rt4) places:
 *       c0: Client 0 (CP, PRIO=1, 1 hop to root)
 *       c1: Fixed-Function subtree (BLT, CPU, VF, TU, ROP, ATOM, SA) via atg_noc_sub16
 *       c2: SU West trunk subtree via atg_noc_sub16
 *       c3: SU East trunk subtree via atg_noc_sub16
 *   - Strict Flop-to-Flop boundaries (am_skid inside every atg_rt2/3/4).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_noc #(
	parameter NCLIENT = 2,
	parameter [NCLIENT-1:0] HIGH_MASK = {NCLIENT{1'b0}},
	parameter HAS_ROOT = 0,
	parameter ROOT_SPLIT = 0,
	parameter ROOT_KEEP = 0,
	parameter ROOT_CLIENT = 0,
	parameter SU_BASE = NCLIENT,
	parameter RW = HAS_ROOT + 6,
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,
	parameter VRAM_AW = 32,
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire [NCLIENT-1:0] hold,

	/* The clients (packed, client 0 in the low bits). */
	input wire [NCLIENT-1:0] c_req_valid,
	output wire [NCLIENT-1:0] c_req_ready,
	input wire [NCLIENT-1:0] c_req_write,
	input wire [NCLIENT*(ADDR_W-LINE_SHIFT)-1:0] c_req_line,
	input wire [NCLIENT*LINE_BYTES-1:0] c_req_be,
	input wire [NCLIENT*LINE_BYTES*8-1:0] c_req_wdata,
	input wire [NCLIENT*8-1:0] c_req_tag,
	input wire [NCLIENT-1:0] c_req_chk,
	input wire [NCLIENT-1:0] c_req_tbl,
	input wire [NCLIENT*6-1:0] c_req_slot,
	input wire [NCLIENT*4-1:0] c_req_session,
	input wire [NCLIENT*2-1:0] c_req_exec_type,
	output wire [NCLIENT-1:0] c_rsp_valid,
	output wire [NCLIENT-1:0] c_rsp_write,
	output wire [NCLIENT*8-1:0] c_rsp_tag,
	output wire [NCLIENT*LINE_BYTES*8-1:0] c_rsp_rdata,
	output wire [NCLIENT-1:0] c_rsp_error,

	/* The root. */
	output wire r_req_valid,
	input wire r_req_ready,
	output wire [LINE_BYTES*8-1:0] r_req_data,
	output wire r_req_last,
	input wire r_rsp_valid,
	output wire r_rsp_ready,
	input wire [LINE_BYTES*8+10+RW-1:0] r_rsp_data,

	/* ROOT_CLIENT's own channel (ROOT_SPLIT; its responses always taken). */
	output wire s_req_valid,
	input wire s_req_ready,
	output wire [LINE_BYTES*8-1:0] s_req_data,
	output wire s_req_last,
	input wire s_rsp_valid,
	input wire [LINE_BYTES*8+10+RW-1:0] s_rsp_data,

	output wire rsp_idle
);
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;
	localparam FW = LB;
	localparam RFW = LB + 10 + RW;
	localparam SPLIT_ROOT = (HAS_ROOT != 0 && ROOT_SPLIT != 0) ? 1 : 0;
	localparam NX = SPLIT_ROOT ? (NCLIENT - 1) : NCLIENT;
	localparam N_NONCP = (NX > 1) ? (NX - 1) : 0;

	/* Count non-root clients below SU_BASE (excluding CP at j=0) */
	function integer calc_n_ff;
		input integer unused_arg;
		integer cc, jj, cnt;
		begin
			cnt = 0;
			if (SU_BASE > 0 && SU_BASE < NCLIENT) begin
				for (cc = 0; cc < NCLIENT; cc = cc + 1) begin
					if (!(SPLIT_ROOT && cc == ROOT_CLIENT)) begin
						jj = (SPLIT_ROOT && cc > ROOT_CLIENT) ? (cc - 1) : cc;
						if (jj > 0 && cc < SU_BASE)
							cnt = cnt + 1;
					end
				end
			end else begin
				cnt = (N_NONCP <= 4) ? N_NONCP : ((N_NONCP <= 16) ? 4 : ((N_NONCP + 2) / 3));
			end
			calc_n_ff = cnt;
		end
	endfunction

	localparam N_FF = calc_n_ff(0);
	localparam N_SU_C = N_NONCP - N_FF;
	localparam N_SU_W = (N_SU_C + 1) / 2;
	localparam N_SU_E = N_SU_C - N_SU_W;
	localparam RBIT0 = 10 + HAS_ROOT;
	localparam RBIT1 = RBIT0 + 2;
	localparam RBIT2 = RBIT0 + 4;

	function [RW-1:0] client_route;
		input integer c_idx;
		integer jj, idx;
		reg [1:0] p0, p1, p2;
		begin
			client_route = {RW{1'b0}};
			if (HAS_ROOT != 0 && c_idx == ROOT_CLIENT) begin
				client_route = {RW{1'b0}};
			end else begin
				if (HAS_ROOT != 0)
					client_route[0] = 1'b1;
				if (NX > 1) begin
					jj = (SPLIT_ROOT && c_idx > ROOT_CLIENT) ? (c_idx - 1) : c_idx;
					p0 = 2'd0;
					p1 = 2'd0;
					p2 = 2'd0;
					if (jj == 0) begin
						p0 = 2'd0;
					end else if (jj <= N_FF) begin
						p0 = 2'd1;
						idx = jj - 1;
						if (N_FF > 4) begin
							p1 = idx[3:2];
							p2 = idx[1:0];
						end else if (N_FF > 1) begin
							p1 = idx[1:0];
						end
					end else if (jj <= N_FF + N_SU_W) begin
						p0 = 2'd2;
						idx = jj - 1 - N_FF;
						if (N_SU_W > 4) begin
							p1 = idx[3:2];
							p2 = idx[1:0];
						end else if (N_SU_W > 1) begin
							p1 = idx[1:0];
						end
					end else begin
						p0 = 2'd3;
						idx = jj - 1 - N_FF - N_SU_W;
						if (N_SU_E > 4) begin
							p1 = idx[3:2];
							p2 = idx[1:0];
						end else if (N_SU_E > 1) begin
							p1 = idx[1:0];
						end
					end
					client_route[HAS_ROOT +: 2] = p0;
					client_route[HAS_ROOT + 2 +: 2] = p1;
					client_route[HAS_ROOT + 4 +: 2] = p2;
				end
			end
		end
	endfunction

	/* Tree leaf signals (NX non-root clients) */
	wire [NX-1:0] leaf_req_valid;
	wire [NX-1:0] leaf_req_ready;
	wire [NX*FW-1:0] leaf_req_data;
	wire [NX-1:0] leaf_req_last;
	wire [NX-1:0] leaf_rsp_valid;
	wire [NX-1:0] leaf_rsp_ready;
	wire [NX*RFW-1:0] leaf_rsp_data;

	genvar c;
	generate
	for (c = 0; c < NCLIENT; c = c + 1) begin : g_client
		localparam [7:0] C8 = c[7:0];
		localparam [3:0] C4_HI = c[11:8];
		if (SPLIT_ROOT && c == ROOT_CLIENT) begin : g_split_leaf
			wire rc_rsp_ready_unused;
			am_amb_to_rt #(
				.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE(client_route(c)),
				.CLIENT(C8), .CLIENT_HI(C4_HI), .PRIO(HIGH_MASK[c] ? 1 : 0)
			) leaf_split (
`ifdef MUT_MC_NOKEEP
				.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[c]),
`else
				.clk(clk), .rst_n(rst_n), .flush(flush && !(ROOT_KEEP != 0)),
				.hold(hold[c]),
`endif
				.req_valid(c_req_valid[c]), .req_ready(c_req_ready[c]),
				.req_write(c_req_write[c]), .req_line(c_req_line[c*LA_W +: LA_W]),
				.req_be(c_req_be[c*LINE_BYTES +: LINE_BYTES]),
				.req_wdata(c_req_wdata[c*LB +: LB]), .req_tag(c_req_tag[c*8 +: 8]),
				.req_chk(c_req_chk[c]), .req_tbl(c_req_tbl[c]),
				.req_slot(c_req_slot[c*6 +: 6]),
				.req_session(c_req_session[c*4 +: 4]),
				.req_exec_type(c_req_exec_type[c*2 +: 2]),
				.rsp_valid(c_rsp_valid[c]), .rsp_write(c_rsp_write[c]),
				.rsp_tag(c_rsp_tag[c*8 +: 8]), .rsp_rdata(c_rsp_rdata[c*LB +: LB]),
				.rsp_error(c_rsp_error[c]),
				.t_req_valid(s_req_valid), .t_req_ready(s_req_ready),
				.t_req_data(s_req_data), .t_req_last(s_req_last),
				.t_rsp_valid(s_rsp_valid), .t_rsp_ready(rc_rsp_ready_unused),
				.t_rsp_data(s_rsp_data)
			);
			wire unused_rc_rdy = rc_rsp_ready_unused;
		end else begin : g_tree_leaf
			localparam J = (SPLIT_ROOT && c > ROOT_CLIENT) ? (c - 1) : c;
			am_amb_to_rt #(
				.ADDR_W(ADDR_W), .LINE_BYTES(LINE_BYTES), .LINE_SHIFT(LINE_SHIFT),
				.VRAM_AW(VRAM_AW), .VRAM_BASE(VRAM_BASE), .RW(RW), .ROUTE(client_route(c)),
				.CLIENT(C8), .CLIENT_HI(C4_HI), .PRIO(HIGH_MASK[c] ? 1 : 0)
			) leaf_noc (
				.clk(clk), .rst_n(rst_n), .flush(flush), .hold(hold[c]),
				.req_valid(c_req_valid[c]), .req_ready(c_req_ready[c]),
				.req_write(c_req_write[c]), .req_line(c_req_line[c*LA_W +: LA_W]),
				.req_be(c_req_be[c*LINE_BYTES +: LINE_BYTES]),
				.req_wdata(c_req_wdata[c*LB +: LB]), .req_tag(c_req_tag[c*8 +: 8]),
				.req_chk(c_req_chk[c]), .req_tbl(c_req_tbl[c]),
				.req_slot(c_req_slot[c*6 +: 6]),
				.req_session(c_req_session[c*4 +: 4]),
				.req_exec_type(c_req_exec_type[c*2 +: 2]),
				.rsp_valid(c_rsp_valid[c]), .rsp_write(c_rsp_write[c]),
				.rsp_tag(c_rsp_tag[c*8 +: 8]), .rsp_rdata(c_rsp_rdata[c*LB +: LB]),
				.rsp_error(c_rsp_error[c]),
				.t_req_valid(leaf_req_valid[J]), .t_req_ready(leaf_req_ready[J]),
				.t_req_data(leaf_req_data[J*FW +: FW]), .t_req_last(leaf_req_last[J]),
				.t_rsp_valid(leaf_rsp_valid[J]), .t_rsp_ready(leaf_rsp_ready[J]),
				.t_rsp_data(leaf_rsp_data[J*RFW +: RFW])
			);
		end
	end

	if (!SPLIT_ROOT) begin : g_no_split
		assign s_req_valid = 1'b0;
		assign s_req_data = {FW{1'b0}};
		assign s_req_last = 1'b0;
		wire unused_split_inputs = &{1'b0, s_req_ready, s_rsp_valid, s_rsp_data};
	end

	if (NX == 1) begin : g_single
		am_skid #(.WIDTH(FW + 1), .RST_DATA(0)) u_req_skid (
			.clk(clk), .rst_n(rst_n && !flush),
			.in_valid(leaf_req_valid[0]), .in_ready(leaf_req_ready[0]),
			.in_data({leaf_req_last[0], leaf_req_data[FW-1:0]}),
			.out_valid(r_req_valid), .out_ready(r_req_ready),
			.out_data({r_req_last, r_req_data})
		);
		am_skid #(.WIDTH(RFW), .RST_DATA(0)) u_rsp_skid (
			.clk(clk), .rst_n(rst_n && !flush),
			.in_valid(r_rsp_valid), .in_ready(r_rsp_ready),
			.in_data(r_rsp_data),
			.out_valid(leaf_rsp_valid[0]), .out_ready(leaf_rsp_ready[0]),
			.out_data(leaf_rsp_data[RFW-1:0])
		);
		assign rsp_idle = !leaf_rsp_valid[0];
	end else begin : g_tree
		wire ff_req_v, ff_req_r, ff_req_l, ff_rsp_v, ff_rsp_r, ff_idle;
		wire [FW-1:0] ff_req_d;
		wire [RFW-1:0] ff_rsp_d;

		wire sw_req_v, sw_req_r, sw_req_l, sw_rsp_v, sw_rsp_r, sw_idle;
		wire [FW-1:0] sw_req_d;
		wire [RFW-1:0] sw_rsp_d;

		wire se_req_v, se_req_r, se_req_l, se_rsp_v, se_rsp_r, se_idle;
		wire [FW-1:0] se_req_d;
		wire [RFW-1:0] se_rsp_d;

		wire root_idle;

		if (N_FF > 0) begin : g_ff
			atg_noc_sub16 #(
				.N(N_FF), .FW(FW), .RFW(RFW), .RBIT1(RBIT1), .RBIT2(RBIT2)
			) u_sub_ff (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c_req_valid(leaf_req_valid[1 +: N_FF]),
				.c_req_ready(leaf_req_ready[1 +: N_FF]),
				.c_req_data(leaf_req_data[1*FW +: N_FF*FW]),
				.c_req_last(leaf_req_last[1 +: N_FF]),
				.p_req_valid(ff_req_v), .p_req_ready(ff_req_r),
				.p_req_data(ff_req_d), .p_req_last(ff_req_l),
				.p_rsp_valid(ff_rsp_v), .p_rsp_ready(ff_rsp_r), .p_rsp_data(ff_rsp_d),
				.c_rsp_valid(leaf_rsp_valid[1 +: N_FF]),
				.c_rsp_ready(leaf_rsp_ready[1 +: N_FF]),
				.c_rsp_data(leaf_rsp_data[1*RFW +: N_FF*RFW]),
				.rsp_idle(ff_idle)
			);
		end else begin : g_no_ff
			assign ff_req_v = 1'b0;
			assign ff_req_d = {FW{1'b0}};
			assign ff_req_l = 1'b0;
			assign ff_rsp_r = 1'b1;
			assign ff_idle = 1'b1;
			wire unused_ff = &{1'b0, ff_req_r, ff_rsp_v, ff_rsp_d};
		end

		if (N_SU_W > 0) begin : g_su_w
			localparam SW_BASE = 1 + N_FF;
			atg_noc_sub16 #(
				.N(N_SU_W), .FW(FW), .RFW(RFW), .RBIT1(RBIT1), .RBIT2(RBIT2)
			) u_sub_su_w (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c_req_valid(leaf_req_valid[SW_BASE +: N_SU_W]),
				.c_req_ready(leaf_req_ready[SW_BASE +: N_SU_W]),
				.c_req_data(leaf_req_data[SW_BASE*FW +: N_SU_W*FW]),
				.c_req_last(leaf_req_last[SW_BASE +: N_SU_W]),
				.p_req_valid(sw_req_v), .p_req_ready(sw_req_r),
				.p_req_data(sw_req_d), .p_req_last(sw_req_l),
				.p_rsp_valid(sw_rsp_v), .p_rsp_ready(sw_rsp_r), .p_rsp_data(sw_rsp_d),
				.c_rsp_valid(leaf_rsp_valid[SW_BASE +: N_SU_W]),
				.c_rsp_ready(leaf_rsp_ready[SW_BASE +: N_SU_W]),
				.c_rsp_data(leaf_rsp_data[SW_BASE*RFW +: N_SU_W*RFW]),
				.rsp_idle(sw_idle)
			);
		end else begin : g_no_su_w
			assign sw_req_v = 1'b0;
			assign sw_req_d = {FW{1'b0}};
			assign sw_req_l = 1'b0;
			assign sw_rsp_r = 1'b1;
			assign sw_idle = 1'b1;
			wire unused_sw = &{1'b0, sw_req_r, sw_rsp_v, sw_rsp_d};
		end

		if (N_SU_E > 0) begin : g_su_e
			localparam SE_BASE = 1 + N_FF + N_SU_W;
			atg_noc_sub16 #(
				.N(N_SU_E), .FW(FW), .RFW(RFW), .RBIT1(RBIT1), .RBIT2(RBIT2)
			) u_sub_su_e (
				.clk(clk), .rst_n(rst_n), .flush(flush),
				.c_req_valid(leaf_req_valid[SE_BASE +: N_SU_E]),
				.c_req_ready(leaf_req_ready[SE_BASE +: N_SU_E]),
				.c_req_data(leaf_req_data[SE_BASE*FW +: N_SU_E*FW]),
				.c_req_last(leaf_req_last[SE_BASE +: N_SU_E]),
				.p_req_valid(se_req_v), .p_req_ready(se_req_r),
				.p_req_data(se_req_d), .p_req_last(se_req_l),
				.p_rsp_valid(se_rsp_v), .p_rsp_ready(se_rsp_r), .p_rsp_data(se_rsp_d),
				.c_rsp_valid(leaf_rsp_valid[SE_BASE +: N_SU_E]),
				.c_rsp_ready(leaf_rsp_ready[SE_BASE +: N_SU_E]),
				.c_rsp_data(leaf_rsp_data[SE_BASE*RFW +: N_SU_E*RFW]),
				.rsp_idle(se_idle)
			);
		end else begin : g_no_su_e
			assign se_req_v = 1'b0;
			assign se_req_d = {FW{1'b0}};
			assign se_req_l = 1'b0;
			assign se_rsp_r = 1'b1;
			assign se_idle = 1'b1;
			wire unused_se = &{1'b0, se_req_r, se_rsp_v, se_rsp_d};
		end

		atg_rt4 #(.FW(FW), .RFW(RFW), .RBIT(RBIT0)) u_rt_root (
			.clk(clk), .rst_n(rst_n), .flush(flush),
			.c0_req_valid(leaf_req_valid[0]), .c0_req_ready(leaf_req_ready[0]),
			.c0_req_data(leaf_req_data[0*FW +: FW]), .c0_req_last(leaf_req_last[0]),
			.c1_req_valid(ff_req_v), .c1_req_ready(ff_req_r),
			.c1_req_data(ff_req_d), .c1_req_last(ff_req_l),
			.c2_req_valid(sw_req_v), .c2_req_ready(sw_req_r),
			.c2_req_data(sw_req_d), .c2_req_last(sw_req_l),
			.c3_req_valid(se_req_v), .c3_req_ready(se_req_r),
			.c3_req_data(se_req_d), .c3_req_last(se_req_l),
			.p_req_valid(r_req_valid), .p_req_ready(r_req_ready),
			.p_req_data(r_req_data), .p_req_last(r_req_last),
			.p_rsp_valid(r_rsp_valid), .p_rsp_ready(r_rsp_ready), .p_rsp_data(r_rsp_data),
			.c0_rsp_valid(leaf_rsp_valid[0]), .c0_rsp_ready(leaf_rsp_ready[0]),
			.c0_rsp_data(leaf_rsp_data[0*RFW +: RFW]),
			.c1_rsp_valid(ff_rsp_v), .c1_rsp_ready(ff_rsp_r), .c1_rsp_data(ff_rsp_d),
			.c2_rsp_valid(sw_rsp_v), .c2_rsp_ready(sw_rsp_r), .c2_rsp_data(sw_rsp_d),
			.c3_rsp_valid(se_rsp_v), .c3_rsp_ready(se_rsp_r), .c3_rsp_data(se_rsp_d),
			.rsp_idle(root_idle)
		);

		assign rsp_idle = root_idle && ff_idle && sw_idle && se_idle;
	end
	endgenerate

	wire unused_leaf_rdy = &{1'b0, leaf_rsp_ready};
endmodule

`default_nettype wire
