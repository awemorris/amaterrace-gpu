/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_fetch: VF attribute fetch: for each vertex of a warp and each
 * enabled attribute k (ATTR[k]_BASE/DESC), computes the address
 * (per-vertex or per-instance with divisor) and reads the attribute's
 * bytes through the AMB.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_fetch #(
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
	/* Vertices of a warp (atg_vf_asm → atg_vf_fetch) */
	input wire vb_valid,
	output wire vb_ready,
	input wire [31:0] vb_index,
	input wire [31:0] vb_inst,
	input wire [4:0] vb_lane,
	input wire vb_last,
	/* Attribute data (atg_vf_fetch → atg_vf_conv) */
	output wire af_valid,
	input wire af_ready,
	output wire [3:0] af_attr,
	output wire [4:0] af_lane,
	output wire [127:0] af_raw,
	output wire af_oob,
	output wire af_last,
	output wire busy,
	/* AMB client port (design §4.1) */
	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"
	`include "atg_fmt_info.vh"
	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LB = LINE_BYTES * 8;

	/* Named synchronous reset net so asic-lint excludes it from data fanout checks */
	(* keep = "true" *) wire rst_sync = !rst_n;

	/*
	 * STATE (design §2.3): FIRST_INSTANCE 0x027, ATTR[k]_BASE 0x030 + 2k,
	 * ATTR[k]_DESC 0x031 + 2k, ATTR_DST[k] 0x1C0 + k, ATTR_LIMIT[k] 0x1D0 + k.
	 * Buffer st_wdata, st_we, and st_idx so every net has fanout <= 16.
	 */
	reg [31:0] s_finst;
	reg [31:0] a_base [0:15];
	reg [20:0] a_desc [0:15];	/* DESC[20:0]: stride, format, per-instance */
	reg [7:0]  a_div  [0:15];	/* DESC[31:24] */
	reg [15:0] en;
	reg [7:0]  a_vk   [0:15];	/* ATTR_DST[31:24]: the VkFormat, 0 = DESC[19:16] */
	reg [31:0] a_lim  [0:15];

	wire [31:0] st_wd_base;
	wire [31:0] st_wd_desc;
	wire [7:0]  st_wd_vk;
	wire [31:0] st_wd_lim;
	wire [3:0]  st_we_b;
	wire [8:0]  st_idx_b [0:3];

	genvar gb, gc;
	generate
		for (gb = 0; gb < 32; gb = gb + 1) begin : g_wd_buf32
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wb (.O(st_wd_base[gb]), .I0(st_wdata[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wd (.O(st_wd_desc[gb]), .I0(st_wdata[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wl (.O(st_wd_lim[gb]),  .I0(st_wdata[gb]));
`else
			assign st_wd_base[gb] = st_wdata[gb];
			assign st_wd_desc[gb] = st_wdata[gb];
			assign st_wd_lim[gb]  = st_wdata[gb];
`endif
		end
		for (gb = 0; gb < 8; gb = gb + 1) begin : g_wd_buf8
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wv (.O(st_wd_vk[gb]),   .I0(st_wdata[24 + gb]));
`else
			assign st_wd_vk[gb]   = st_wdata[24 + gb];
`endif
		end
		for (gb = 0; gb < 4; gb = gb + 1) begin : g_st_ctrl_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_we (.O(st_we_b[gb]), .I0(st_we));
`else
			assign st_we_b[gb] = st_we;
`endif
			for (gc = 0; gc < 9; gc = gc + 1) begin : g_idx
`ifdef SYNTH_KINTEX7
				(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
				LUT1 #(.INIT(2'b10)) u_ix (.O(st_idx_b[gb][gc]), .I0(st_idx[gc]));
`else
				assign st_idx_b[gb][gc] = st_idx[gc];
`endif
			end
		end
	endgenerate

	(* keep = "true" *) wire [5:0] wd_nz_c;
	assign wd_nz_c[0] = |st_wdata[5:0];
	assign wd_nz_c[1] = |st_wdata[11:6];
	assign wd_nz_c[2] = |st_wdata[17:12];
	assign wd_nz_c[3] = |st_wdata[23:18];
	assign wd_nz_c[4] = |st_wdata[29:24];
	assign wd_nz_c[5] = |st_wdata[31:30];
	wire wdata_nz = |wd_nz_c;

	wire we_finst = st_we && (st_idx == GHCI_S_FIRST_INSTANCE);
	wire [1:0] we_finst_b;

	wire [15:0] we_base_lo, we_base_hi;
	wire [15:0] we_desc_lo, we_desc_hi;
	wire [15:0] we_dst;
	wire [15:0] we_lim_lo, we_lim_hi;

`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_fi0 (.O(we_finst_b[0]), .I0(we_finst));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_fi1 (.O(we_finst_b[1]), .I0(we_finst));
`else
	assign we_finst_b[0] = we_finst;
	assign we_finst_b[1] = we_finst;
`endif

	generate
		for (gb = 0; gb < 16; gb = gb + 1) begin : g_attr_we
			localparam integer B = gb / 4;
			wire s_attr_g = (st_idx_b[B][8:4] == 5'h03) || (st_idx_b[B][8:4] == 5'h04);
			wire [3:0] attr_k_g = {!st_idx_b[B][4], st_idx_b[B][3:1]};
			wire wb = st_we_b[B] && s_attr_g && !st_idx_b[B][0] && (attr_k_g == gb[3:0]);
			wire wd = st_we_b[B] && s_attr_g &&  st_idx_b[B][0] && (attr_k_g == gb[3:0]);
			wire ws = st_we_b[B] && (st_idx_b[B][8:4] == GHCI_S_ATTR_DST[8:4])   && (st_idx_b[B][3:0] == gb[3:0]);
			wire wl = st_we_b[B] && (st_idx_b[B][8:4] == GHCI_S_ATTR_LIMIT[8:4]) && (st_idx_b[B][3:0] == gb[3:0]);
			assign we_dst[gb] = ws;
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wbl (.O(we_base_lo[gb]), .I0(wb));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wbh (.O(we_base_hi[gb]), .I0(wb));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wdl (.O(we_desc_lo[gb]), .I0(wd));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wdh (.O(we_desc_hi[gb]), .I0(wd));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wll (.O(we_lim_lo[gb]),  .I0(wl));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wlh (.O(we_lim_hi[gb]),  .I0(wl));
`else
			assign we_base_lo[gb] = wb;
			assign we_base_hi[gb] = wb;
			assign we_desc_lo[gb] = wd;
			assign we_desc_hi[gb] = wd;
			assign we_lim_lo[gb]  = wl;
			assign we_lim_hi[gb]  = wl;
`endif
		end
	endgenerate

	integer i;
	always @(posedge clk) begin
		if (rst_sync) begin
			s_finst <= 32'd0;
			en <= 16'd0;
			for (i = 0; i < 16; i = i + 1) begin
				a_base[i] <= 32'd0;
				a_desc[i] <= 21'd0;
				a_div[i]  <= 8'd0;
				a_vk[i]   <= 8'd0;
				a_lim[i]  <= 32'd0;
			end
		end else begin
			if (we_finst_b[0]) s_finst[15:0]  <= st_wdata[15:0];
			if (we_finst_b[1]) s_finst[31:16] <= st_wdata[31:16];
			for (i = 0; i < 16; i = i + 1) begin
				if (we_base_lo[i]) a_base[i][15:0]  <= st_wd_base[15:0];
				if (we_base_hi[i]) a_base[i][31:16] <= st_wd_base[31:16];
				if (we_desc_lo[i]) a_desc[i][15:0]  <= st_wd_desc[15:0];
				if (we_desc_hi[i]) begin
					a_desc[i][20:16] <= st_wd_desc[20:16];
					a_div[i]         <= st_wd_desc[31:24];
				end
				if (we_dst[i]) begin
					en[i]   <= wdata_nz;
					a_vk[i] <= st_wd_vk;
				end
				if (we_lim_lo[i])  a_lim[i][15:0]   <= st_wd_lim[15:0];
				if (we_lim_hi[i])  a_lim[i][31:16]  <= st_wd_lim[31:16];
			end
		end
	end

	/* 2-LUT 16-bit lowest-bit priority encoder */
	function [3:0] prio16;
		input [15:0] m;
		reg [3:0] g_nz;
		reg [1:0] hi;
		reg [3:0] sub;
		reg [1:0] lo;
		begin
			g_nz[0] = |m[3:0];
			g_nz[1] = |m[7:4];
			g_nz[2] = |m[11:8];
			g_nz[3] = |m[15:12];
			if (g_nz[0])      hi = 2'd0;
			else if (g_nz[1]) hi = 2'd1;
			else if (g_nz[2]) hi = 2'd2;
			else              hi = 2'd3;
			case (hi)
			2'd0: sub = m[3:0];
			2'd1: sub = m[7:4];
			2'd2: sub = m[11:8];
			2'd3: sub = m[15:12];
			endcase
			if (sub[0])      lo = 2'd0;
			else if (sub[1]) lo = 2'd1;
			else if (sub[2]) lo = 2'd2;
			else             lo = 2'd3;
			prio16 = {hi, lo};
		end
	endfunction

	/* 4-to-16 one-hot decoder (constant LUT mapping, 0 arithmetic operators) */
	function [15:0] dec16;
		input [3:0] in;
		begin
			case (in)
			4'd0:  dec16 = 16'h0001;
			4'd1:  dec16 = 16'h0002;
			4'd2:  dec16 = 16'h0004;
			4'd3:  dec16 = 16'h0008;
			4'd4:  dec16 = 16'h0010;
			4'd5:  dec16 = 16'h0020;
			4'd6:  dec16 = 16'h0040;
			4'd7:  dec16 = 16'h0080;
			4'd8:  dec16 = 16'h0100;
			4'd9:  dec16 = 16'h0200;
			4'd10: dec16 = 16'h0400;
			4'd11: dec16 = 16'h0800;
			4'd12: dec16 = 16'h1000;
			4'd13: dec16 = 16'h2000;
			4'd14: dec16 = 16'h4000;
			default: dec16 = 16'h8000;
			endcase
		end
	endfunction

	/* One-hot FSM state registers */
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg st_is_idle;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg st_is_idle_rdy;
	reg st_is_attr1;
	reg st_is_attr2;
	reg st_is_elem;
	reg st_is_div;
	reg st_is_div_add;
	reg st_is_mul1;
	reg st_is_mul2;
	reg st_is_mul3;
	reg st_is_mul4;
	reg st_is_addr;
	reg st_is_oob;
	reg st_is_tag;
	reg st_is_plan1;
	reg st_is_plan2;
	reg st_is_req;
	reg st_is_data;
	reg st_is_rd;
	reg st_is_sh1;
	reg st_is_sh2;
	reg st_is_sh3;
	reg st_is_emit;
	reg st_is_none;

	/* The vertex */
	reg [31:0] v_idx, v_inst;
	reg [4:0]  v_lane;
	reg        v_last;
	reg [15:0] rem;
	reg [15:0] rem_next_r;
	reg        rem_next_z_r;
	reg [3:0]  k_r;
	reg [3:0]  next_k_r;

	/*
	 * 2-level LUT1 buffer tree for k_r[3:0]:
	 * Level 1: 5 LUT1s per bit of k_r[1:0], 1 LUT1 per bit of k_r[3:2]
	 * Level 2: 36 LUT1s per bit of k_r[1:0] (k_lo_b[0..35], each fanout <= 16),
	 *          7 LUT1s per bit of k_r[3:2]  (k_hi_b[0..6],  each fanout <= 16).
	 */
	wire [1:0] k_lo_l1 [0:4];
	wire [1:0] k_hi_l1;
	wire [1:0] k_lo_b  [0:35];
	wire [1:0] k_hi_b  [0:6];

	generate
		for (gb = 0; gb < 5; gb = gb + 1) begin : g_klo_l1
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_0 (.O(k_lo_l1[gb][0]), .I0(k_r[0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_1 (.O(k_lo_l1[gb][1]), .I0(k_r[1]));
`else
			assign k_lo_l1[gb] = k_r[1:0];
`endif
		end
`ifdef SYNTH_KINTEX7
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_khi_l1_0 (.O(k_hi_l1[0]), .I0(k_r[2]));
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_khi_l1_1 (.O(k_hi_l1[1]), .I0(k_r[3]));
`else
		assign k_hi_l1 = k_r[3:2];
`endif
		for (gb = 0; gb < 36; gb = gb + 1) begin : g_klo_l2
			localparam integer L1G = gb / 8;
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_0 (.O(k_lo_b[gb][0]), .I0(k_lo_l1[L1G][0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_1 (.O(k_lo_b[gb][1]), .I0(k_lo_l1[L1G][1]));
`else
			assign k_lo_b[gb] = k_lo_l1[L1G];
`endif
		end
		for (gb = 0; gb < 7; gb = gb + 1) begin : g_khi_l2
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_0 (.O(k_hi_b[gb][0]), .I0(k_hi_l1[0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_1 (.O(k_hi_b[gb][1]), .I0(k_hi_l1[1]));
`else
			assign k_hi_b[gb] = k_hi_l1;
`endif
		end
	endgenerate

	/* Stage 1 attribute mux registers (4 groups, free-running to avoid 404-load CE/R) */
	reg [31:0] grp_base [0:3];
	reg [20:0] grp_desc [0:3];
	reg [7:0]  grp_div  [0:3];
	reg [7:0]  grp_vk   [0:3];
	reg [31:0] grp_lim  [0:3];

	/* Stage 2 selected attribute registers */
	reg [31:0] cur_base;
	reg [15:0] cur_stride;
	reg [3:0]  cur_fmt;
	reg        cur_per_inst;
	reg [7:0]  cur_div;
	reg [7:0]  cur_vk;
	reg [31:0] cur_lim;

	/* Format size registers */
	wire [67:0] vk_inf = atg_fmt_info(cur_vk);
	reg [4:0]  cur_vk_sz_r;
	reg        cur_vk_nz_r;
	reg [4:0]  cur_fmt_sz_r;
	reg [4:0]  cur_size;

	/* Per-instance element & 32-by-8 restoring divider */
	wire [31:0] num_w;
	wire [31:0] el_memo_w;
	wire [31:0] el_div_w;
	wire num_bo_unused, elm_co_unused, eld_co_unused;
	reg [31:0] num_r;
	reg [31:0] el_memo_r;
	reg        m_v;
	reg [31:0] m_num, m_q;
	reg [7:0]  m_div;
	reg        memo_hit_r;
	reg        div_bypass_r;

	am_sub #(.W(32)) u_nsub (.a(v_inst),  .b(s_finst), .bi(1'b0), .d(num_w),     .bo(num_bo_unused));
	am_add #(.W(32)) u_elm  (.a(s_finst), .b(m_q),     .ci(1'b0), .s(el_memo_w), .co(elm_co_unused));

	reg [7:0]  div_rem;
	reg [31:0] div_quo;
	reg [4:0]  div_cnt;
	wire [8:0] div_diff;
	wire       div_borrow;
	wire [4:0] div_cnt_next;
	wire       div_cnt_bo_unused;
	am_sub #(.W(9)) u_div_sub (.a({div_rem, div_quo[31]}), .b({1'b0, cur_div}), .bi(1'b0), .d(div_diff), .bo(div_borrow));
	am_sub #(.W(5)) u_div_cnt (.a(div_cnt), .b(5'd0), .bi(1'b1), .d(div_cnt_next), .bo(div_cnt_bo_unused));
	am_add #(.W(32)) u_eld    (.a(s_finst), .b(div_quo), .ci(1'b0), .s(el_div_w), .co(eld_co_unused));

	/* 6-chunk carry-free equality for m_num == num_r */
	(* keep = "true" *) wire [5:0] m_eq_c;
	assign m_eq_c[0] = (m_num[5:0]   == num_r[5:0]);
	assign m_eq_c[1] = (m_num[11:6]  == num_r[11:6]);
	assign m_eq_c[2] = (m_num[17:12] == num_r[17:12]);
	assign m_eq_c[3] = (m_num[23:18] == num_r[23:18]);
	assign m_eq_c[4] = (m_num[29:24] == num_r[29:24]);
	assign m_eq_c[5] = (m_num[31:30] == num_r[31:30]);
	wire memo_num_eq_w = &m_eq_c;

	/* Multiplier (LAT=3) and Address / Bound */
	reg [31:0] elem;
	wire [47:0] el_x;
	reg [47:0] boff;
	reg [31:0] addr;
	reg [31:0] bend32_r;
	reg        boff_hi_nz_r;
	reg        oob_r;

	am_mul #(.AW(32), .BW(16), .SIGNED(0), .LAT(3)) ml (
		.clk(clk), .en(1'b1), .a(elem), .b(cur_stride), .p(el_x)
	);

	wire [31:0] ad_s;
	wire [31:0] bend32_s;
	wire [30:0] lim_diff_unused;
	wire        lim_lt_bend;
	wire ad_co_unused, bnd_co_unused;
	am_add #(.W(32)) ad    (.a(cur_base),          .b(boff[31:0]),          .ci(1'b0), .s(ad_s),     .co(ad_co_unused));
	am_add #(.W(32)) u_bnd (.a({1'b0, boff[30:0]}), .b({27'd0, cur_size}),  .ci(1'b0), .s(bend32_s), .co(bnd_co_unused));
`ifdef MUT_ATTR_LIMIT_GE
	localparam LIM_BI = 1'b1;
`else
	localparam LIM_BI = 1'b0;
`endif
	am_sub #(.W(31)) u_lim_cmp (.a(cur_lim[30:0]), .b(bend32_r[30:0]), .bi(LIM_BI), .d(lim_diff_unused), .bo(lim_lt_bend));

	(* keep = "true" *) wire [2:0] boff_hi_c;
	assign boff_hi_c[0] = |boff[36:31];
	assign boff_hi_c[1] = |boff[42:37];
	assign boff_hi_c[2] = |boff[47:43];
	wire boff_hi_nz_w = |boff_hi_c;

	/* Line addresses and xline check */
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [LA_W-1:0] l1_r0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [LA_W-1:0] l1_r1;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [LA_W-1:0] l2_r0;
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [LA_W-1:0] l2_r1;
	reg [LINE_SHIFT-1:0] off_r;
	reg xline_r;

	/* LUT1 buffers for off_r[4:0] into sh1_r, sh2_r, af_raw_r (fanout <= 16) */
	wire [1:0] off_43_b [0:11];
	wire [1:0] off_21_b [0:8];
	wire       off_0_b  [0:7];
	generate
		for (gb = 0; gb < 12; gb = gb + 1) begin : g_off43_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_3 (.O(off_43_b[gb][0]), .I0(off_r[3]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_4 (.O(off_43_b[gb][1]), .I0(off_r[4]));
`else
			assign off_43_b[gb] = off_r[4:3];
`endif
		end
		for (gb = 0; gb < 9; gb = gb + 1) begin : g_off21_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_1 (.O(off_21_b[gb][0]), .I0(off_r[1]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_2 (.O(off_21_b[gb][1]), .I0(off_r[2]));
`else
			assign off_21_b[gb] = off_r[2:1];
`endif
		end
		for (gb = 0; gb < 8; gb = gb + 1) begin : g_off0_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_0 (.O(off_0_b[gb]), .I0(off_r[0]));
`else
			assign off_0_b[gb] = off_r[0];
`endif
		end
	endgenerate

	wire [LA_W-1:0] l2_w;
	wire [LINE_SHIFT:0] osum_w;
	wire l2_co_unused, osum_co_unused;
	am_add #(.W(LA_W)) nl (.a(addr[ADDR_W-1:LINE_SHIFT]), .b({LA_W{1'b0}}), .ci(1'b1), .s(l2_w), .co(l2_co_unused));
	am_add #(.W(LINE_SHIFT + 1)) os (.a({1'b0, addr[LINE_SHIFT-1:0]}), .b({{(LINE_SHIFT-4){1'b0}}, cur_size}),
		.ci(1'b0), .s(osum_w), .co(osum_co_unused));
	wire xline_w = osum_w[LINE_SHIFT] && (osum_w[LINE_SHIFT-1:0] != {LINE_SHIFT{1'b0}});

	/*
	 * Multi-stream line buffer (Phase 032):
	 * 4 streams (s = k_r[1:0]), 8 entries per stream (32 entries total).
	 * Data stored in 32 slices of 8-bit x 32-entry Distributed RAMs with
	 * dedicated per-slice registered addresses and outputs (Rule 4 & Rule 2).
	 */
	reg [LA_W-1:0] s_tag [0:31];
	reg [31:0]     s_val;
	reg [31:0]     s_pnd;
	reg [2:0]      s_rr [0:3];

	/* Stream-local latched tags & valid/pending masks */
	reg [LA_W-1:0] cur_stag [0:7];
	reg [7:0]      s_val_8_r;
	reg [7:0]      s_pnd_8_r;
	reg [2:0]      rr0_r;

	/* Buffered s_stream copies for cur_stag[0..7] 4:1 muxes (14 bits per buffer <= 16) */
	wire [1:0] s_stream = k_r[1:0];
	wire [1:0] s_str_stag_b [0:15];
	generate
		for (gb = 0; gb < 16; gb = gb + 1) begin : g_str_stag_buf
			localparam integer L1G = gb / 4;
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_0 (.O(s_str_stag_b[gb][0]), .I0(k_lo_l1[L1G][0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_1 (.O(s_str_stag_b[gb][1]), .I0(k_lo_l1[L1G][1]));
`else
			assign s_str_stag_b[gb] = k_lo_l1[L1G];
`endif
		end
	endgenerate

	/* Tag match results (latched in ST_TAG) */
	wire [7:0] tag_m1_8_w, tag_m2_8_w;
	generate
		for (gb = 0; gb < 8; gb = gb + 1) begin : g_stag_cmp
			wire [LA_W-1:0] ref_l1 = (gb < 4) ? l1_r0 : l1_r1;
			wire [LA_W-1:0] ref_l2 = (gb < 4) ? l2_r0 : l2_r1;
			(* keep = "true" *) wire [8:0] c1_p;
			(* keep = "true" *) wire [8:0] c2_p;
			genvar gp;
			for (gp = 0; gp < 9; gp = gp + 1) begin : g_p
				assign c1_p[gp] = (cur_stag[gb][3*gp +: 3] == ref_l1[3*gp +: 3]);
				assign c2_p[gp] = (cur_stag[gb][3*gp +: 3] == ref_l2[3*gp +: 3]);
			end
			(* keep = "true" *) wire m1_lo = &c1_p[4:0];
			(* keep = "true" *) wire m1_hi = &c1_p[8:5];
			(* keep = "true" *) wire m2_lo = &c2_p[4:0];
			(* keep = "true" *) wire m2_hi = &c2_p[8:5];
			assign tag_m1_8_w[gb] = m1_lo && m1_hi;
			assign tag_m2_8_w[gb] = m2_lo && m2_hi;
		end
	endgenerate

	reg [7:0] hit1_mask_r, pnd1_mask_r, hit2_mask_r, pnd2_mask_r, free_mask_r;

	function [2:0] inc3;
		input [2:0] v;
		case (v)
		3'd0: inc3 = 3'd1;
		3'd1: inc3 = 3'd2;
		3'd2: inc3 = 3'd3;
		3'd3: inc3 = 3'd4;
		3'd4: inc3 = 3'd5;
		3'd5: inc3 = 3'd6;
		3'd6: inc3 = 3'd7;
		default: inc3 = 3'd0;
		endcase
	endfunction

	function [7:0] dec8;
		input [2:0] idx;
		case (idx)
		3'd0: dec8 = 8'b00000001;
		3'd1: dec8 = 8'b00000010;
		3'd2: dec8 = 8'b00000100;
		3'd3: dec8 = 8'b00001000;
		3'd4: dec8 = 8'b00010000;
		3'd5: dec8 = 8'b00100000;
		3'd6: dec8 = 8'b01000000;
		3'd7: dec8 = 8'b10000000;
		default: dec8 = 8'b00000000;
		endcase
	endfunction

	function [2:0] prio8;
		input [7:0] m;
		casez (m)
		8'b???????1: prio8 = 3'd0;
		8'b??????10: prio8 = 3'd1;
		8'b?????100: prio8 = 3'd2;
		8'b????1000: prio8 = 3'd3;
		8'b???10000: prio8 = 3'd4;
		8'b??100000: prio8 = 3'd5;
		8'b?1000000: prio8 = 3'd6;
		8'b10000000: prio8 = 3'd7;
		default: prio8 = 3'd0;
		endcase
	endfunction

	function [2:0] prio8_hi;
		input [7:0] m;
		casez (m)
		8'b1???????: prio8_hi = 3'd7;
		8'b01??????: prio8_hi = 3'd6;
		8'b001?????: prio8_hi = 3'd5;
		8'b0001????: prio8_hi = 3'd4;
		8'b00001???: prio8_hi = 3'd3;
		8'b000001??: prio8_hi = 3'd2;
		8'b0000001?: prio8_hi = 3'd1;
		8'b00000001: prio8_hi = 3'd0;
		default: prio8_hi = 3'd0;
		endcase
	endfunction

	/*
	 * Plan stage 1 -> stage 2 registers:
	 * Note: free_mask_r = ~(s_val_8_r | s_pnd_8_r) is strictly disjoint from
	 * hp1_w and hp2_w (which are subsets of s_val_8_r | s_pnd_8_r).
	 * Therefore free_mask_r never collides with m1_idx_w or m2_idx_w!
	 * In ST_PLAN1 we precompute the lowest free slot (f1_idx_w = prio8(free_mask_r), 2 LUTs)
	 * and highest free slot (f2_idx_w = prio8_hi(free_mask_r), 2 LUTs).
	 * Free mask has >= 2 free slots iff f1_idx_r != f2_idx_r!
	 */
	(* keep = "true" *) wire [7:0] hp1_w = hit1_mask_r | pnd1_mask_r;
	(* keep = "true" *) wire [7:0] hp2_w = hit2_mask_r | pnd2_mask_r;
	wire       match1_w = |hp1_w;
	wire [2:0] m1_idx_w = prio8(hp1_w);
	wire       match2_w = |hp2_w;
	wire [2:0] m2_idx_w = prio8(hp2_w);

	wire [2:0] f1_idx_w = prio8(free_mask_r);
	wire       f1_v_w   = |free_mask_r;
	wire [2:0] f2_idx_w = prio8_hi(free_mask_r);

	reg        h1_hit_r, p1_pnd_r, h2_hit_r, p2_pnd_r;
	reg        match1_r, match2_r;
	reg [2:0]  m1_idx_r, m2_idx_r;
	reg        f1_v_r;
	reg [2:0]  f1_idx_r, f2_idx_r;

	wire [2:0] rr0_b;
`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rr0_0 (.O(rr0_b[0]), .I0(rr0_r[0]));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rr0_1 (.O(rr0_b[1]), .I0(rr0_r[1]));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rr0_2 (.O(rr0_b[2]), .I0(rr0_r[2]));
`else
	assign rr0_b = rr0_r;
`endif
	wire       f2_v_r = (f1_idx_r != f2_idx_r);
	wire [2:0] rr1_w  = inc3(rr0_b);
	(* keep = "true" *) wire vic1_avoid = match2_r && (rr0_b == m2_idx_r);
	wire [2:0] vic1_w = vic1_avoid ? rr1_w : rr0_b;

	(* keep = "true" *) wire [2:0] avoid2_idx = match1_r ? m1_idx_r : f1_idx_r;
	(* keep = "true" *) wire vic2_use_rr1 = (!match1_r && !f1_v_r) || (rr0_b == avoid2_idx);
	wire [2:0] vic2_w = vic2_use_rr1 ? rr1_w : rr0_b;

	(* keep = "true" *) wire [2:0] sel1_calc = match1_r ? m1_idx_r : (f1_v_r ? f1_idx_r : vic1_w);
	(* keep = "true" *) wire [2:0] sel2_calc = match2_r ? m2_idx_r :
		((match1_r && f1_v_r)  ? f1_idx_r :
		((!match1_r && f2_v_r) ? f2_idx_r : vic2_w));

	reg [2:0] sel1, sel2;
	reg       miss1, miss2;

	/* AMB Request / Response */
	reg            rq_pend;
	reg [7:0]      rq_tag;
	reg [LA_W-1:0] rq_line;
	assign req_valid = rq_pend;
	assign req_write = 1'b0;
	assign req_line  = rq_line;
	assign req_be    = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag   = rq_tag;

	wire rd_rsp = rsp_valid && !rsp_write;
	wire [4:0] rsp_idx = rsp_tag[4:0];
	reg        rsp_done_r;
	reg [4:0]  rsp_done_idx_r;
	wire [15:0] rsp_err_b;

	generate
		for (gb = 0; gb < 16; gb = gb + 1) begin : g_rsperr_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_re (.O(rsp_err_b[gb]), .I0(rsp_error));
`else
			assign rsp_err_b[gb] = rsp_error;
`endif
		end
	endgenerate

	/*
	 * 32 slices of 8-bit x 32-entry Distributed RAM for s_dat[0:31].
	 * Grouped into 4 banks of 8 slices. Each 8-bit slice has its own registered
	 * write/read addresses (separate waddr1_r/we1_r for mem1 and waddr2_r/we2_r
	 * for mem2 so RAM pin fanout is <= 12) and registered data outputs (Rule 4).
	 */
	wire [255:0] pair_lo;
	wire [255:0] pair_hi;
	(* keep = "true" *) wire [3:0]   rd_rsp_bank_b;
	wire [4:0]   rsp_idx_bank_b [0:3];
	(* keep = "true" *) wire [1:0]   p2_l1;
	(* keep = "true" *) wire [15:0]  p2_ce_b;
	wire [2:0]   sel1_bank_b [0:3];
	wire [2:0]   sel2_bank_b [0:3];
	wire [1:0]   sstr_bank_b [0:3];

	generate
`ifdef SYNTH_KINTEX7
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_p2_l1_0 (.O(p2_l1[0]), .I0(st_is_plan2));
		(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
		LUT1 #(.INIT(2'b10)) u_p2_l1_1 (.O(p2_l1[1]), .I0(st_is_plan2));
`else
		assign p2_l1 = {2{st_is_plan2}};
`endif
		for (gb = 0; gb < 4; gb = gb + 1) begin : g_ram_bank_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_rr (.O(rd_rsp_bank_b[gb]),    .I0(rd_rsp));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s10 (.O(sel1_bank_b[gb][0]),  .I0(sel1_calc[0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s11 (.O(sel1_bank_b[gb][1]),  .I0(sel1_calc[1]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s12 (.O(sel1_bank_b[gb][2]),  .I0(sel1_calc[2]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s20 (.O(sel2_bank_b[gb][0]),  .I0(sel2_calc[0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s21 (.O(sel2_bank_b[gb][1]),  .I0(sel2_calc[1]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s22 (.O(sel2_bank_b[gb][2]),  .I0(sel2_calc[2]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_st0 (.O(sstr_bank_b[gb][0]),  .I0(k_lo_l1[gb][0]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_st1 (.O(sstr_bank_b[gb][1]),  .I0(k_lo_l1[gb][1]));
`else
			assign rd_rsp_bank_b[gb] = rd_rsp;
			assign sel1_bank_b[gb]   = sel1_calc;
			assign sel2_bank_b[gb]   = sel2_calc;
			assign sstr_bank_b[gb]   = k_lo_l1[gb];
`endif
			for (gc = 0; gc < 5; gc = gc + 1) begin : g_ri
`ifdef SYNTH_KINTEX7
				(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
				LUT1 #(.INIT(2'b10)) u_ri (.O(rsp_idx_bank_b[gb][gc]), .I0(rsp_idx[gc]));
`else
				assign rsp_idx_bank_b[gb][gc] = rsp_idx[gc];
`endif
			end
		end
		for (gb = 0; gb < 16; gb = gb + 1) begin : g_p2_ce_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_p2 (.O(p2_ce_b[gb]), .I0(p2_l1[gb / 8]));
`else
			assign p2_ce_b[gb] = p2_l1[gb / 8];
`endif
		end
		for (gb = 0; gb < 32; gb = gb + 1) begin : g_sdat_slice
			localparam integer BK = gb / 8;
			localparam integer PG = gb / 2;
			(* ram_style = "distributed" *) reg [7:0] mem1 [0:31];
			(* ram_style = "distributed" *) reg [7:0] mem2 [0:31];
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg       we1_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg       we2_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] waddr1_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] waddr2_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [7:0] wdata_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] raddr1_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [4:0] raddr2_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [7:0] dout1_r;
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) reg [7:0] dout2_r;

			always @(posedge clk) begin
				wdata_r <= rsp_err_b[PG] ? 8'd0 : rsp_rdata[8*gb +: 8];
				if (rst_sync) begin
					we1_r    <= 1'b0;
					we2_r    <= 1'b0;
					waddr1_r <= 5'd0;
					waddr2_r <= 5'd0;
					raddr1_r <= 5'd0;
					raddr2_r <= 5'd0;
				end else begin
					we1_r    <= rd_rsp_bank_b[BK];
					we2_r    <= rd_rsp_bank_b[BK];
					waddr1_r <= rsp_idx_bank_b[BK];
					waddr2_r <= rsp_idx_bank_b[BK];
					if (p2_ce_b[PG]) begin
						raddr1_r <= {sstr_bank_b[BK], sel1_bank_b[BK]};
						raddr2_r <= {sstr_bank_b[BK], sel2_bank_b[BK]};
					end
				end
			end

			always @(posedge clk) begin
				if (we1_r)
					mem1[waddr1_r] <= wdata_r;
				if (we2_r)
					mem2[waddr2_r] <= wdata_r;
				dout1_r <= mem1[raddr1_r];
				dout2_r <= mem2[raddr2_r];
			end

			assign pair_lo[8*gb +: 8] = dout1_r;
			assign pair_hi[8*gb +: 8] = dout2_r;
		end
	endgenerate

	wire [511:0] pair_full = {pair_hi, pair_lo};

	/* 3-stage pipelined byte aligner (1 LUT level per stage, fanout <= 16) */
	reg [191:0] sh1_r;
	reg [135:0] sh2_r;
	reg [127:0] af_raw_r;
	reg         af_valid_r;
	reg [3:0]   af_attr_r;
	reg [4:0]   af_lane_r;
	reg         af_oob_r;
	reg         af_last_r;

	assign vb_ready = st_is_idle_rdy;
	assign af_valid = af_valid_r;
	assign af_attr  = af_attr_r;
	assign af_lane  = af_lane_r;
	assign af_raw   = af_raw_r;
	assign af_oob   = af_oob_r;
	assign af_last  = af_last_r;
	assign busy     = !st_is_idle;

	/* Buffered CEs for wide registers */
	wire ce_v_in = st_is_idle && vb_valid;
	wire [4:0] ce_vin_b;
	wire [1:0] ce_num_b, ce_elm_b, ce_remn_b;
	wire [2:0] ce_attr2_b;
	wire [1:0] ce_cbase_b, ce_clim_b;
	wire [1:0] ce_divq_b, sel_divq_b;
	wire [3:0] ce_elem_b, sel_el0_b, sel_el1_b, sel_divadd_b;
	wire [2:0] ce_boff_b;
	wire [1:0] ce_addr_b, ce_bnd_b;
	wire [1:0] ce_l1_0_b, ce_l1_1_b, ce_l2_0_b, ce_l2_1_b, ce_oob_b;
	wire [2:0] ce_tmask_b;
	wire [1:0] ce_mnum_b, ce_mq_b;
	wire [1:0] ce_plan1_b;
	wire [11:0] ce_sh1_b;
	wire [8:0]  ce_sh2_b;
	wire [7:0]  ce_afraw_b, sel_af_zero_b;
	wire [2:0]  emit_take_b;

	wire elem_in_elem = st_is_elem && (div_bypass_r || memo_hit_r);
	wire ce_elem_all = elem_in_elem || st_is_div_add;
	wire sel_el_0 = st_is_div_add || (cur_per_inst && (cur_div != 8'd1));
	wire sel_el_1 = st_is_div_add || (cur_per_inst && (cur_div != 8'd0));
	wire ce_divq_all = (st_is_elem && !elem_in_elem) || st_is_div;
	(* keep = "true" *) wire ce_afraw_all = st_is_none || (st_is_tag && oob_r) || st_is_sh3;
	wire sel_af_zero = !st_is_sh3;
	(* keep = "true" *) wire emit_take = st_is_emit && af_ready;
	(* keep = "true" *) wire ce_tag_masks = st_is_tag && !oob_r;

	generate
		for (gb = 0; gb < 2; gb = gb + 1) begin : g_ce2_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_nm (.O(ce_num_b[gb]),   .I0(st_is_attr1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_em (.O(ce_elm_b[gb]),   .I0(st_is_attr1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_rn (.O(ce_remn_b[gb]),  .I0(st_is_attr1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cb (.O(ce_cbase_b[gb]), .I0(st_is_attr2));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cl (.O(ce_clim_b[gb]),  .I0(st_is_attr2));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_dq (.O(ce_divq_b[gb]),  .I0(ce_divq_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_sd (.O(sel_divq_b[gb]), .I0(st_is_div));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ad (.O(ce_addr_b[gb]),  .I0(st_is_addr));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_bd (.O(ce_bnd_b[gb]),   .I0(st_is_addr));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_10 (.O(ce_l1_0_b[gb]),  .I0(st_is_oob));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_11 (.O(ce_l1_1_b[gb]),  .I0(st_is_oob));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_20 (.O(ce_l2_0_b[gb]),  .I0(st_is_oob));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_21 (.O(ce_l2_1_b[gb]),  .I0(st_is_oob));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ob (.O(ce_oob_b[gb]),   .I0(st_is_oob));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_mn (.O(ce_mnum_b[gb]),  .I0(st_is_div_add));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_mq (.O(ce_mq_b[gb]),    .I0(st_is_div_add));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_p1 (.O(ce_plan1_b[gb]), .I0(st_is_plan1));
`else
			assign ce_num_b[gb]   = st_is_attr1;
			assign ce_elm_b[gb]   = st_is_attr1;
			assign ce_remn_b[gb]  = st_is_attr1;
			assign ce_cbase_b[gb] = st_is_attr2;
			assign ce_clim_b[gb]  = st_is_attr2;
			assign ce_divq_b[gb]  = ce_divq_all;
			assign sel_divq_b[gb] = st_is_div;
			assign ce_addr_b[gb]  = st_is_addr;
			assign ce_bnd_b[gb]   = st_is_addr;
			assign ce_l1_0_b[gb]  = st_is_oob;
			assign ce_l1_1_b[gb]  = st_is_oob;
			assign ce_l2_0_b[gb]  = st_is_oob;
			assign ce_l2_1_b[gb]  = st_is_oob;
			assign ce_oob_b[gb]   = st_is_oob;
			assign ce_mnum_b[gb]  = st_is_div_add;
			assign ce_mq_b[gb]    = st_is_div_add;
			assign ce_plan1_b[gb] = st_is_plan1;
`endif
		end
		for (gb = 0; gb < 4; gb = gb + 1) begin : g_elem_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_el (.O(ce_elem_b[gb]),    .I0(ce_elem_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s0 (.O(sel_el0_b[gb]),    .I0(sel_el_0));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s1 (.O(sel_el1_b[gb]),    .I0(sel_el_1));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_da (.O(sel_divadd_b[gb]), .I0(st_is_div_add));
`else
			assign ce_elem_b[gb]    = ce_elem_all;
			assign sel_el0_b[gb]    = sel_el_0;
			assign sel_el1_b[gb]    = sel_el_1;
			assign sel_divadd_b[gb] = st_is_div_add;
`endif
		end
		for (gb = 0; gb < 5; gb = gb + 1) begin : g_vin_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_vi (.O(ce_vin_b[gb]), .I0(ce_v_in));
`else
			assign ce_vin_b[gb] = ce_v_in;
`endif
		end
		for (gb = 0; gb < 3; gb = gb + 1) begin : g_ce3_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_tm (.O(ce_tmask_b[gb]),  .I0(ce_tag_masks));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_a2 (.O(ce_attr2_b[gb]),  .I0(st_is_attr2));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_bf (.O(ce_boff_b[gb]),   .I0(st_is_mul4));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_et (.O(emit_take_b[gb]), .I0(emit_take));
`else
			assign ce_tmask_b[gb]  = ce_tag_masks;
			assign ce_attr2_b[gb]  = st_is_attr2;
			assign ce_boff_b[gb]   = st_is_mul4;
			assign emit_take_b[gb] = emit_take;
`endif
		end
		for (gb = 0; gb < 12; gb = gb + 1) begin : g_sh1_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s1 (.O(ce_sh1_b[gb]),   .I0(st_is_sh1));
`else
			assign ce_sh1_b[gb]   = st_is_sh1;
`endif
		end
		for (gb = 0; gb < 9; gb = gb + 1) begin : g_sh2_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_s2 (.O(ce_sh2_b[gb]),   .I0(st_is_sh2));
`else
			assign ce_sh2_b[gb]   = st_is_sh2;
`endif
		end
		for (gb = 0; gb < 8; gb = gb + 1) begin : g_af_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ar (.O(ce_afraw_b[gb]),    .I0(ce_afraw_all));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_az (.O(sel_af_zero_b[gb]), .I0(sel_af_zero));
`else
			assign ce_afraw_b[gb]    = ce_afraw_all;
			assign sel_af_zero_b[gb] = sel_af_zero;
`endif
		end
	endgenerate

	/*
	 * Buffered signals for s_tag[0..31], s_val[31:0], s_pnd[31:0] updates
	 * so every net (miss_idx, miss1, rq_line, s_tag CE, s_val/s_pnd R/CE) has fanout <= 16.
	 * Use k_lo_b[32..35] for stream indices so k_r[1:0] is never unbuffered.
	 */
	wire [4:0] e_sel1 = {k_lo_b[32], sel1};
	wire [4:0] e_sel2 = {k_lo_b[33], sel2};
	(* keep = "true" *) wire [4:0] miss_idx = {k_lo_b[34], miss1 ? sel1 : sel2};
	(* keep = "true" *) wire req_issue = st_is_req && !rq_pend && (miss1 || miss2);
	wire [1:0] miss1_line_b;
`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_m1l0 (.O(miss1_line_b[0]), .I0(miss1));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_m1l1 (.O(miss1_line_b[1]), .I0(miss1));
`else
	assign miss1_line_b = {2{miss1}};
`endif
	(* keep = "true" *) wire [LA_W-1:0] miss_line_w = {
		miss1_line_b[1] ? l1_r0[LA_W-1:14] : l2_r0[LA_W-1:14],
		miss1_line_b[0] ? l1_r0[13:0]      : l2_r0[13:0]
	};
	wire [LA_W-1:0] miss_line_b0, miss_line_b1;
	(* keep = "true" *) wire [3:0]      req_issue_b;
	wire [4:0]      miss_idx_b [0:3];
	wire [3:0]      rsp_done_b;
	wire [4:0]      rsp_didx_b [0:3];
	(* keep = "true" *) reg clr_cache_warp_r;
	always @(posedge clk) begin
		if (rst_sync)
			clr_cache_warp_r <= 1'b0;
		else
			clr_cache_warp_r <= emit_take && rem_next_z_r && v_last;
	end
	(* keep = "true" *) wire clr_cache_raw = rst_sync || clr_cache_warp_r;
	wire [3:0]      clr_cache_b;
	(* keep = "true" *) wire [31:0] req_hit_dec;
	(* keep = "true" *) wire [31:0] rsp_hit_dec;
	wire [31:0]     we_stag_lo, we_stag_hi;

	(* keep = "true" *) wire [1:0] ce_rqline_b;
	(* keep = "true" *) wire       ce_rqtag_b;
	(* keep = "true" *) wire       ce_rqpend_b;
`ifdef SYNTH_KINTEX7
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rql0 (.O(ce_rqline_b[0]), .I0(req_issue));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rql1 (.O(ce_rqline_b[1]), .I0(req_issue));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rqt  (.O(ce_rqtag_b),     .I0(req_issue));
	(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
	LUT1 #(.INIT(2'b10)) u_rqp  (.O(ce_rqpend_b),    .I0(req_issue));
`else
	assign ce_rqline_b = {2{req_issue}};
	assign ce_rqtag_b  = req_issue;
	assign ce_rqpend_b = req_issue;
`endif

	generate
		for (gb = 0; gb < LA_W; gb = gb + 1) begin : g_mline_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ml0 (.O(miss_line_b0[gb]), .I0(miss_line_w[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ml1 (.O(miss_line_b1[gb]), .I0(miss_line_w[gb]));
`else
			assign miss_line_b0[gb] = miss_line_w[gb];
			assign miss_line_b1[gb] = miss_line_w[gb];
`endif
		end
		for (gb = 0; gb < 4; gb = gb + 1) begin : g_midx_buf
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_ri (.O(req_issue_b[gb]), .I0(req_issue));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_rd (.O(rsp_done_b[gb]),  .I0(rsp_done_r));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_cc (.O(clr_cache_b[gb]), .I0(clr_cache_raw));
`else
			assign req_issue_b[gb] = req_issue;
			assign rsp_done_b[gb]  = rsp_done_r;
			assign clr_cache_b[gb] = clr_cache_raw;
`endif
			for (gc = 0; gc < 5; gc = gc + 1) begin : g_mi
`ifdef SYNTH_KINTEX7
				(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
				LUT1 #(.INIT(2'b10)) u_mi (.O(miss_idx_b[gb][gc]), .I0(miss_idx[gc]));
				(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
				LUT1 #(.INIT(2'b10)) u_di (.O(rsp_didx_b[gb][gc]), .I0(rsp_done_idx_r[gc]));
`else
				assign miss_idx_b[gb][gc] = miss_idx[gc];
				assign rsp_didx_b[gb][gc] = rsp_done_idx_r[gc];
`endif
			end
		end
		for (gb = 0; gb < 32; gb = gb + 1) begin : g_stag_we
			localparam integer QTR = gb / 8;
			assign req_hit_dec[gb] = req_issue_b[QTR] && (miss_idx_b[QTR] == gb[4:0]);
			assign rsp_hit_dec[gb] = rsp_done_b[QTR]  && (rsp_didx_b[QTR] == gb[4:0]);
`ifdef SYNTH_KINTEX7
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wl (.O(we_stag_lo[gb]), .I0(req_hit_dec[gb]));
			(* KEEP = "TRUE", DONT_TOUCH = "TRUE" *)
			LUT1 #(.INIT(2'b10)) u_wh (.O(we_stag_hi[gb]), .I0(req_hit_dec[gb]));
`else
			assign we_stag_lo[gb] = req_hit_dec[gb];
			assign we_stag_hi[gb] = req_hit_dec[gb];
`endif
		end
	endgenerate

	/* 2-level OR reduction for en != 0 */
	(* keep = "true" *) wire [2:0] en_nz_c;
	assign en_nz_c[0] = |en[5:0];
	assign en_nz_c[1] = |en[11:6];
	assign en_nz_c[2] = |en[15:12];
	wire en_nz_w = |en_nz_c;

	wire [3:0] k_init_w = prio16(en);
	wire [3:0] k_next_w = prio16(rem_next_r);

	/* 2-chunk 4-bit equality for m_div == grp_div[k_hi_b[5]] in ST_ATTR2 */
	wire [7:0] next_cur_div = grp_div[k_hi_b[5]];
	wire       next_per_inst = grp_desc[k_hi_b[5]][20];
	(* keep = "true" *) wire m_div_eq_lo = (m_div[3:0] == next_cur_div[3:0]);
	(* keep = "true" *) wire m_div_eq_hi = (m_div[7:4] == next_cur_div[7:4]);
	wire memo_hit_next = m_v && memo_num_eq_w && m_div_eq_lo && m_div_eq_hi;
	wire div_bypass_next = !next_per_inst || (next_cur_div == 8'd0) || (next_cur_div == 8'd1);

	integer si, sei, ri;

	/* Free-running pipeline registers for Stage 1 attribute mux and stream-local tags */
	always @(posedge clk) begin
		for (si = 0; si < 4; si = si + 1) begin
			grp_base[si][15:0]  <= a_base[{si[1:0], k_lo_b[2*si + 0]}][15:0];
			grp_base[si][31:16] <= a_base[{si[1:0], k_lo_b[2*si + 1]}][31:16];
			grp_desc[si][15:0]  <= a_desc[{si[1:0], k_lo_b[8 + si]}][15:0];
			grp_desc[si][20:16] <= a_desc[{si[1:0], k_lo_b[12 + si]}][20:16];
			grp_div[si]         <= a_div[{si[1:0],  k_lo_b[16 + si]}];
			grp_vk[si]          <= a_vk[{si[1:0],   k_lo_b[20 + si]}];
			grp_lim[si][15:0]   <= a_lim[{si[1:0],  k_lo_b[24 + si]}][15:0];
			grp_lim[si][31:16]  <= a_lim[{si[1:0],  k_lo_b[28 + si]}][31:16];
		end
		for (ri = 0; ri < 8; ri = ri + 1) begin
			cur_stag[ri][13:0]      <= s_tag[{s_str_stag_b[2*ri + 0], ri[2:0]}][13:0];
			cur_stag[ri][LA_W-1:14] <= s_tag[{s_str_stag_b[2*ri + 1], ri[2:0]}][LA_W-1:14];
		end
	end

	/* s_tag[0:31], s_val[31:0], s_pnd[31:0] updates with fanout <= 16 */
	always @(posedge clk) begin
		for (sei = 0; sei < 16; sei = sei + 1) begin
			if (we_stag_lo[sei]) s_tag[sei][13:0]      <= miss_line_b0[13:0];
			if (we_stag_hi[sei]) s_tag[sei][LA_W-1:14] <= miss_line_b0[LA_W-1:14];
			if (we_stag_lo[16 + sei]) s_tag[16 + sei][13:0]      <= miss_line_b1[13:0];
			if (we_stag_hi[16 + sei]) s_tag[16 + sei][LA_W-1:14] <= miss_line_b1[LA_W-1:14];
		end
		for (sei = 0; sei < 16; sei = sei + 1) begin
			if (clr_cache_b[0])
				s_val[sei] <= 1'b0;
			else if (req_hit_dec[sei])
				s_val[sei] <= 1'b0;
			else if (rsp_hit_dec[sei])
				s_val[sei] <= 1'b1;

			if (clr_cache_b[1])
				s_val[16 + sei] <= 1'b0;
			else if (req_hit_dec[16 + sei])
				s_val[16 + sei] <= 1'b0;
			else if (rsp_hit_dec[16 + sei])
				s_val[16 + sei] <= 1'b1;

			if (clr_cache_b[2])
				s_pnd[sei] <= 1'b0;
			else if (req_hit_dec[sei])
				s_pnd[sei] <= 1'b1;
			else if (rsp_hit_dec[sei])
				s_pnd[sei] <= 1'b0;

			if (clr_cache_b[3])
				s_pnd[16 + sei] <= 1'b0;
			else if (req_hit_dec[16 + sei])
				s_pnd[16 + sei] <= 1'b1;
			else if (rsp_hit_dec[16 + sei])
				s_pnd[16 + sei] <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (rst_sync) begin
			st_is_idle     <= 1'b1;
			st_is_idle_rdy <= 1'b1;
			st_is_attr1    <= 1'b0;
			st_is_attr2    <= 1'b0;
			st_is_elem     <= 1'b0;
			st_is_div      <= 1'b0;
			st_is_div_add  <= 1'b0;
			st_is_mul1     <= 1'b0;
			st_is_mul2     <= 1'b0;
			st_is_mul3     <= 1'b0;
			st_is_mul4     <= 1'b0;
			st_is_addr     <= 1'b0;
			st_is_oob      <= 1'b0;
			st_is_tag      <= 1'b0;
			st_is_plan1    <= 1'b0;
			st_is_plan2    <= 1'b0;
			st_is_req      <= 1'b0;
			st_is_data     <= 1'b0;
			st_is_rd       <= 1'b0;
			st_is_sh1      <= 1'b0;
			st_is_sh2      <= 1'b0;
			st_is_sh3      <= 1'b0;
			st_is_emit     <= 1'b0;
			st_is_none     <= 1'b0;
			v_idx <= 32'd0;
			v_inst <= 32'd0;
			v_lane <= 5'd0;
			v_last <= 1'b0;
			rem <= 16'd0;
			rem_next_r <= 16'd0;
			rem_next_z_r <= 1'b0;
			k_r <= 4'd0;
			next_k_r <= 4'd0;
			for (si = 0; si < 4; si = si + 1)
				s_rr[si] <= 3'd0;
			cur_base <= 32'd0;
			cur_stride <= 16'd0;
			cur_fmt <= 4'd0;
			cur_per_inst <= 1'b0;
			cur_div <= 8'd0;
			cur_vk <= 8'd0;
			cur_lim <= 32'd0;
			cur_vk_sz_r <= 5'd4;
			cur_vk_nz_r <= 1'b0;
			cur_fmt_sz_r <= 5'd4;
			cur_size <= 5'd4;
			num_r <= 32'd0;
			el_memo_r <= 32'd0;
			m_v <= 1'b0;
			m_num <= 32'd0;
			m_q <= 32'd0;
			m_div <= 8'd0;
			memo_hit_r <= 1'b0;
			div_bypass_r <= 1'b0;
			div_rem <= 8'd0;
			div_quo <= 32'd0;
			div_cnt <= 5'd0;
			elem <= 32'd0;
			boff <= 48'd0;
			addr <= 32'd0;
			bend32_r <= 32'd0;
			boff_hi_nz_r <= 1'b0;
			oob_r <= 1'b0;
			l1_r0 <= {LA_W{1'b0}};
			l1_r1 <= {LA_W{1'b0}};
			l2_r0 <= {LA_W{1'b0}};
			l2_r1 <= {LA_W{1'b0}};
			off_r <= {LINE_SHIFT{1'b0}};
			xline_r <= 1'b0;
			s_val_8_r <= 8'd0;
			s_pnd_8_r <= 8'd0;
			rr0_r <= 3'd0;
			hit1_mask_r <= 8'd0;
			pnd1_mask_r <= 8'd0;
			hit2_mask_r <= 8'd0;
			pnd2_mask_r <= 8'd0;
			free_mask_r <= 8'd0;
			h1_hit_r <= 1'b0;
			p1_pnd_r <= 1'b0;
			h2_hit_r <= 1'b0;
			p2_pnd_r <= 1'b0;
			match1_r <= 1'b0;
			match2_r <= 1'b0;
			m1_idx_r <= 3'd0;
			m2_idx_r <= 3'd0;
			f1_v_r <= 1'b0;
			f1_idx_r <= 3'd0;
			f2_idx_r <= 3'd0;
			sel1 <= 3'd0;
			sel2 <= 3'd0;
			miss1 <= 1'b0;
			miss2 <= 1'b0;
			rq_pend <= 1'b0;
			rq_tag <= 8'd0;
			rq_line <= {LA_W{1'b0}};
			rsp_done_r <= 1'b0;
			rsp_done_idx_r <= 5'd0;
			sh1_r <= 192'd0;
			sh2_r <= 136'd0;
			af_raw_r <= 128'd0;
			af_valid_r <= 1'b0;
			af_attr_r <= 4'd0;
			af_lane_r <= 5'd0;
			af_oob_r <= 1'b0;
			af_last_r <= 1'b0;
		end else begin
			/* Delayed s_val / s_pnd update aligned with Distributed RAM write */
			rsp_done_r     <= rd_rsp;
			rsp_done_idx_r <= rsp_idx;

			/* Wide datapath updates with buffered CEs (<= 16 loads per buffer) */
			if (ce_vin_b[0])   v_idx[15:0]   <= vb_index[15:0];
			if (ce_vin_b[1])   v_idx[31:16]  <= vb_index[31:16];
			if (ce_vin_b[2])   v_inst[15:0]  <= vb_inst[15:0];
			if (ce_vin_b[3])   v_inst[31:16] <= vb_inst[31:16];
			if (ce_vin_b[4]) begin
				v_lane <= vb_lane;
				v_last <= vb_last;
				rem    <= en;
				k_r    <= k_init_w;
			end

			if (ce_num_b[0])   num_r[15:0]     <= num_w[15:0];
			if (ce_num_b[1])   num_r[31:16]    <= num_w[31:16];
			if (ce_elm_b[0])   el_memo_r[15:0] <= el_memo_w[15:0];
			if (ce_elm_b[1])   el_memo_r[31:16] <= el_memo_w[31:16];
			if (ce_remn_b[0])  rem_next_r      <= rem & ~dec16(k_r);

			/* Stage 2 attribute 4:1 mux (1 LUT6 per bit, k_hi_b fanout <= 16) */
			if (ce_cbase_b[0]) cur_base[15:0]  <= grp_base[k_hi_b[0]][15:0];
			if (ce_cbase_b[1]) cur_base[31:16] <= grp_base[k_hi_b[1]][31:16];
			if (ce_clim_b[0])  cur_lim[15:0]   <= grp_lim[k_hi_b[2]][15:0];
			if (ce_clim_b[1])  cur_lim[31:16]  <= grp_lim[k_hi_b[3]][31:16];
			if (ce_attr2_b[0]) cur_stride      <= grp_desc[k_hi_b[4]][15:0];
			if (ce_attr2_b[1]) begin
				cur_fmt      <= grp_desc[k_hi_b[5]][19:16];
				cur_per_inst <= next_per_inst;
				cur_div      <= next_cur_div;
			end
			if (ce_attr2_b[2]) begin
				cur_vk       <= grp_vk[k_hi_b[6]];
				rem_next_z_r <= (rem_next_r == 16'd0);
				next_k_r     <= k_next_w;
				memo_hit_r   <= memo_hit_next;
				div_bypass_r <= div_bypass_next;
			end

			/* Element mux (4 groups of 8 bits, fanout <= 16) */
			for (ri = 0; ri < 4; ri = ri + 1) begin
				if (ce_elem_b[ri]) begin
					case ({sel_el1_b[ri], sel_el0_b[ri]})
					2'b00: elem[8*ri +: 8] <= v_idx[8*ri +: 8];
					2'b01: elem[8*ri +: 8] <= s_finst[8*ri +: 8];
					2'b10: elem[8*ri +: 8] <= v_inst[8*ri +: 8];
					2'b11: elem[8*ri +: 8] <= sel_divadd_b[ri] ? el_div_w[8*ri +: 8] : el_memo_r[8*ri +: 8];
					endcase
				end
			end

			/* 32-by-8 divider updates */
			if (ce_divq_b[0]) div_quo[15:0]  <= sel_divq_b[0] ? {div_quo[14:0], !div_borrow} : num_r[15:0];
			if (ce_divq_b[1]) div_quo[31:16] <= sel_divq_b[1] ? div_quo[30:15]               : num_r[31:16];
			if (st_is_div) begin
				div_rem <= div_borrow ? {div_rem[6:0], div_quo[31]} : div_diff[7:0];
				div_cnt <= div_cnt_next;
			end else if (st_is_elem) begin
				div_rem <= 8'd0;
				div_cnt <= 5'd31;
			end

			if (ce_mnum_b[0]) m_num[15:0]  <= num_r[15:0];
			if (ce_mnum_b[1]) m_num[31:16] <= num_r[31:16];
			if (ce_mq_b[0])   m_q[15:0]    <= div_quo[15:0];
			if (ce_mq_b[1])   m_q[31:16]   <= div_quo[31:16];
			if (st_is_div_add) begin
				m_v   <= 1'b1;
				m_div <= cur_div;
			end

			if (ce_boff_b[0]) boff[15:0]  <= el_x[15:0];
			if (ce_boff_b[1]) boff[31:16] <= el_x[31:16];
			if (ce_boff_b[2]) boff[47:32] <= el_x[47:32];

			if (ce_addr_b[0]) addr[15:0]     <= ad_s[15:0];
			if (ce_addr_b[1]) addr[31:16]    <= ad_s[31:16];
			if (ce_bnd_b[0])  bend32_r[15:0] <= bend32_s[15:0];
			if (ce_bnd_b[1])  bend32_r[31:16] <= bend32_s[31:16];
			if (st_is_addr)   boff_hi_nz_r   <= boff_hi_nz_w;

			if (ce_l1_0_b[0]) l1_r0[13:0]      <= addr[LINE_SHIFT+13:LINE_SHIFT];
			if (ce_l1_0_b[1]) l1_r0[LA_W-1:14] <= addr[ADDR_W-1:LINE_SHIFT+14];
			if (ce_l1_1_b[0]) l1_r1[13:0]      <= addr[LINE_SHIFT+13:LINE_SHIFT];
			if (ce_l1_1_b[1]) l1_r1[LA_W-1:14] <= addr[ADDR_W-1:LINE_SHIFT+14];
			if (ce_l2_0_b[0]) l2_r0[13:0]      <= l2_w[13:0];
			if (ce_l2_0_b[1]) l2_r0[LA_W-1:14] <= l2_w[LA_W-1:14];
			if (ce_l2_1_b[0]) l2_r1[13:0]      <= l2_w[13:0];
			if (ce_l2_1_b[1]) l2_r1[LA_W-1:14] <= l2_w[LA_W-1:14];

			/* 3-stage byte aligner updates */
			for (ri = 0; ri < 12; ri = ri + 1) begin
				if (ce_sh1_b[ri]) begin
					case (off_43_b[ri])
					2'd0: sh1_r[16*ri +: 16] <= pair_full[0   + 16*ri +: 16];
					2'd1: sh1_r[16*ri +: 16] <= pair_full[64  + 16*ri +: 16];
					2'd2: sh1_r[16*ri +: 16] <= pair_full[128 + 16*ri +: 16];
					2'd3: sh1_r[16*ri +: 16] <= pair_full[192 + 16*ri +: 16];
					endcase
				end
			end
			for (ri = 0; ri < 8; ri = ri + 1) begin
				if (ce_sh2_b[ri]) begin
					case (off_21_b[ri])
					2'd0: sh2_r[16*ri +: 16] <= sh1_r[0  + 16*ri +: 16];
					2'd1: sh2_r[16*ri +: 16] <= sh1_r[16 + 16*ri +: 16];
					2'd2: sh2_r[16*ri +: 16] <= sh1_r[32 + 16*ri +: 16];
					2'd3: sh2_r[16*ri +: 16] <= sh1_r[48 + 16*ri +: 16];
					endcase
				end
			end
			if (ce_sh2_b[8]) begin
				case (off_21_b[8])
				2'd0: sh2_r[135:128] <= sh1_r[135:128];
				2'd1: sh2_r[135:128] <= sh1_r[151:144];
				2'd2: sh2_r[135:128] <= sh1_r[167:160];
				2'd3: sh2_r[135:128] <= sh1_r[183:176];
				endcase
			end
			for (ri = 0; ri < 8; ri = ri + 1) begin
				if (ce_afraw_b[ri]) begin
					af_raw_r[16*ri +: 16] <= sel_af_zero_b[ri] ? 16'd0 :
						(off_0_b[ri] ? sh2_r[8 + 16*ri +: 16] : sh2_r[0 + 16*ri +: 16]);
				end
			end

			/* One-hot FSM transitions */
			if (st_is_idle && vb_valid) begin
				if (en_nz_w) begin
					st_is_idle     <= 1'b0;
					st_is_idle_rdy <= 1'b0;
					st_is_attr1    <= 1'b1;
				end else if (vb_last) begin
					st_is_idle     <= 1'b0;
					st_is_idle_rdy <= 1'b0;
					st_is_none     <= 1'b1;
				end
			end

			if (st_is_none) begin
				st_is_none   <= 1'b0;
				st_is_emit   <= 1'b1;
				rem_next_z_r <= 1'b1;
				af_valid_r   <= 1'b1;
				af_attr_r    <= 4'd0;
				af_lane_r    <= v_lane;
				af_oob_r     <= 1'b0;
				af_last_r    <= 1'b1;
			end

			if (st_is_attr1) begin
				st_is_attr1 <= 1'b0;
				st_is_attr2 <= 1'b1;
			end

			if (st_is_attr2) begin
				st_is_attr2 <= 1'b0;
				st_is_elem  <= 1'b1;
			end

			if (st_is_elem) begin
				cur_vk_sz_r  <= (vk_inf[0] && !vk_inf[14]) ? vk_inf[5:1] : 5'd4;
				cur_vk_nz_r  <= (cur_vk != 8'd0);
				case (cur_fmt)
				4'd1, 4'd7, 4'd9: cur_fmt_sz_r <= 5'd8;
				4'd2:             cur_fmt_sz_r <= 5'd12;
				4'd3:             cur_fmt_sz_r <= 5'd16;
				default:          cur_fmt_sz_r <= 5'd4;
				endcase
				st_is_elem <= 1'b0;
				if (elem_in_elem)
					st_is_mul1 <= 1'b1;
				else
					st_is_div  <= 1'b1;
			end

			if (st_is_div) begin
				if (div_cnt == 5'd0) begin
					st_is_div     <= 1'b0;
					st_is_div_add <= 1'b1;
				end
			end

			if (st_is_div_add) begin
				st_is_div_add <= 1'b0;
				st_is_mul1    <= 1'b1;
			end

			if (st_is_mul1) begin
				cur_size   <= cur_vk_nz_r ? cur_vk_sz_r : cur_fmt_sz_r;
				st_is_mul1 <= 1'b0;
				st_is_mul2 <= 1'b1;
			end

			if (st_is_mul2) begin
				st_is_mul2 <= 1'b0;
				st_is_mul3 <= 1'b1;
			end

			if (st_is_mul3) begin
				st_is_mul3 <= 1'b0;
				st_is_mul4 <= 1'b1;
			end

			if (st_is_mul4) begin
				st_is_mul4 <= 1'b0;
				st_is_addr <= 1'b1;
			end

			if (st_is_addr) begin
				st_is_addr <= 1'b0;
				st_is_oob  <= 1'b1;
			end

			if (ce_oob_b[0]) begin
				oob_r     <= cur_lim[31] && (boff_hi_nz_r || bend32_r[31] || lim_lt_bend);
				off_r     <= addr[LINE_SHIFT-1:0];
				xline_r   <= xline_w;
				rr0_r     <= s_rr[k_lo_b[35]];
				st_is_oob <= 1'b0;
				st_is_tag <= 1'b1;
			end
			if (ce_oob_b[1]) begin
				s_val_8_r <= s_val[{k_lo_b[35], 3'b000} +: 8];
				s_pnd_8_r <= s_pnd[{k_lo_b[35], 3'b000} +: 8];
			end

			if (ce_tmask_b[0]) begin
				hit1_mask_r <= s_val_8_r & tag_m1_8_w;
				pnd1_mask_r <= s_pnd_8_r & tag_m1_8_w;
			end
			if (ce_tmask_b[1]) begin
				hit2_mask_r <= s_val_8_r & tag_m2_8_w;
				pnd2_mask_r <= s_pnd_8_r & tag_m2_8_w;
			end
			if (ce_tmask_b[2]) begin
				free_mask_r <= ~(s_val_8_r | s_pnd_8_r);
				st_is_plan1 <= 1'b1;
			end
			if (st_is_tag) begin
				st_is_tag <= 1'b0;
				if (oob_r) begin
					st_is_emit <= 1'b1;
					af_valid_r <= 1'b1;
					af_attr_r  <= k_r;
					af_lane_r  <= v_lane;
					af_oob_r   <= 1'b1;
					af_last_r  <= v_last && rem_next_z_r;
				end
			end

			if (ce_plan1_b[0]) begin
				h1_hit_r    <= |hit1_mask_r;
				p1_pnd_r    <= |pnd1_mask_r;
				h2_hit_r    <= |hit2_mask_r;
				p2_pnd_r    <= |pnd2_mask_r;
				match1_r    <= match1_w;
				m1_idx_r    <= m1_idx_w;
				match2_r    <= match2_w;
				m2_idx_r    <= m2_idx_w;
				st_is_plan1 <= 1'b0;
				st_is_plan2 <= 1'b1;
			end
			if (ce_plan1_b[1]) begin
				f1_v_r   <= f1_v_w;
				f1_idx_r <= f1_idx_w;
				f2_idx_r <= f2_idx_w;
			end

			if (st_is_plan2) begin
				sel1  <= sel1_calc;
				sel2  <= sel2_calc;
				miss1 <= !h1_hit_r && !p1_pnd_r;
				miss2 <= xline_r && !h2_hit_r && !p2_pnd_r;
				st_is_plan2 <= 1'b0;
				if (h1_hit_r && (!xline_r || h2_hit_r))
					st_is_rd   <= 1'b1;
				else if (!(!h1_hit_r && !p1_pnd_r) && !(xline_r && !h2_hit_r && !p2_pnd_r))
					st_is_data <= 1'b1;
				else
					st_is_req  <= 1'b1;
			end

			if (ce_rqline_b[0]) rq_line[13:0]      <= miss_line_b0[13:0];
			if (ce_rqline_b[1]) rq_line[LA_W-1:14] <= miss_line_b0[LA_W-1:14];
			if (ce_rqtag_b)     rq_tag             <= {3'd0, miss_idx};

			if (st_is_req) begin
				if (rq_pend) begin
					if (req_ready) begin
						rq_pend <= 1'b0;
						if (miss1)
							miss1 <= 1'b0;
						else
							miss2 <= 1'b0;
					end
				end else if (ce_rqpend_b) begin
					rq_pend <= 1'b1;
					if (miss1 ? (sel1 == rr0_r) : (sel2 == rr0_r)) begin
						s_rr[k_lo_b[34]] <= rr1_w;
						rr0_r            <= rr1_w;
					end
				end else begin
					st_is_req  <= 1'b0;
					st_is_data <= 1'b1;
				end
			end

			if (st_is_data) begin
				if (s_val[e_sel1] && (!xline_r || s_val[e_sel2])) begin
					st_is_data <= 1'b0;
					st_is_rd   <= 1'b1;
				end
			end

			if (st_is_rd) begin
				st_is_rd  <= 1'b0;
				st_is_sh1 <= 1'b1;
			end

			if (st_is_sh1) begin
				st_is_sh1 <= 1'b0;
				st_is_sh2 <= 1'b1;
			end

			if (st_is_sh2) begin
				st_is_sh2 <= 1'b0;
				st_is_sh3 <= 1'b1;
			end

			if (st_is_sh3) begin
				st_is_sh3  <= 1'b0;
				st_is_emit <= 1'b1;
				af_valid_r <= 1'b1;
				af_attr_r  <= k_r;
				af_lane_r  <= v_lane;
				af_oob_r   <= 1'b0;
				af_last_r  <= v_last && rem_next_z_r;
			end

			if (emit_take_b[0]) begin
				rem <= rem_next_r;
			end
			if (emit_take_b[1]) begin
				af_valid_r <= 1'b0;
				st_is_emit <= 1'b0;
				k_r        <= next_k_r;
				if (!rem_next_z_r) begin
					st_is_attr1 <= 1'b1;
				end else begin
					st_is_idle     <= 1'b1;
					st_is_idle_rdy <= 1'b1;
				end
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:5], vk_inf[67:15], vk_inf[13:6],
		pair_full[511:384], sh1_r[191:184], div_diff[8], lim_diff_unused,
		num_bo_unused, elm_co_unused, eld_co_unused, div_cnt_bo_unused,
		ad_co_unused, bnd_co_unused, l2_co_unused, osum_co_unused,
		ce_remn_b[1], emit_take_b[2]};
endmodule

`default_nettype wire
