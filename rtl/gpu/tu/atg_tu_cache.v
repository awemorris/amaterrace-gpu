/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_cache: 4-way Set-Associative, 4-bank L1 texture cache.
 *
 * 8 KiB (KC705), 4 ways, 4 banks. 4 texels per cycle concurrent read
 * with zero bank conflicts for 2x2 bilinear footprints.
 * Tree-PLRU eviction policy per set.
 * Invalidate via inv (INVALIDATE[1] / DRAW).
 */

`timescale 1ns / 1ps
`default_nettype none

`include "atg_config.vh"

module atg_tu_cache #(
	parameter ADDR_W     = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter TC_BYTES   = 8192,	/* Size in bytes: 8 KiB (4 ways) */
	parameter WAYS       = 4,
	parameter NBANKS     = 4	/* Number of cache banks (1, 2, 4) */
) (
	input wire clk,
	input wire rst_n,
	input wire inv,
	/* From atg_tu_addr */
	input wire ta_valid,
	output wire ta_ready,
	input wire [511:0] ta_addr,
	input wire [15:0] ta_bord,
	input wire [127:0] ta_wts,
	input wire [15:0] ta_tag,
	input wire [3:0] ta_mask,
	input wire [49:0] ta_ctl,
	input wire [127:0] ta_value,
	input wire ta_last,
	/* To atg_tu_filter */
	output wire tc_valid,
	input wire tc_ready,
	(* keep = "true", extract_reset = "no" *) output reg [511:0] tc_texels,
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) output reg [15:0] tc_bord,
	(* keep = "true", extract_reset = "no" *) output reg [31:0] tc_lo,
	(* keep = "true", extract_reset = "no" *) output reg [127:0] tc_wts,
	(* keep = "true", extract_reset = "no" *) output reg [15:0] tc_tag,
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) output reg [3:0] tc_mask,
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) output reg [49:0] tc_ctl,
	(* keep = "true", extract_reset = "no" *) output reg [127:0] tc_value,
	(* keep = "true", extract_reset = "no" *) output reg tc_last,
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
	localparam LB = LINE_BYTES * 8;
	localparam NL = TC_BYTES / LINE_BYTES;
	localparam NSETS = NL / WAYS;
	localparam IW = $clog2(NSETS);
	localparam TW = ADDR_W - LINE_SHIFT - IW;
	localparam WW = LINE_SHIFT - 2;	/* word in the line */

	localparam [3:0] IDLE          = 4'd0,
	                 LANE_CHECK    = 4'd1,
	                 MREQ          = 4'd2,
	                 MWAIT         = 4'd3,
	                 MW_WRITE      = 4'd4,
	                 LANE_WAIT     = 4'd5,
	                 LANE_FETCH    = 4'd6,
	                 LANE_EXTRACT  = 4'd7,
	                 OUT           = 4'd8,
	                 LANE_TAG_RD   = 4'd9,
	                 LANE_CMP      = 4'd10,
	                 LANE_TAG_WAIT = 4'd11;

	localparam RAW_AW = IW + 2;
	localparam NS     = LB / 64;
	localparam NGRPS  = NSETS / 4;
	localparam GRP_W  = IW - 2;

	(* dont_touch = "true" *) wire rst_inv = !rst_n;

	/* 4 Banks of Block RAMs via library module am_bram_sdp (sliced into 64-bit RAMB36 units) */
	wire [LB-1:0] bank_q0;
	wire [LB-1:0] bank_q1;
	wire [LB-1:0] bank_q2;
	wire [LB-1:0] bank_q3;

	(* keep = "true", extract_reset = "no" *) reg [LB-1:0] q0_reg;
	(* keep = "true", extract_reset = "no" *) reg [LB-1:0] q1_reg;
	(* keep = "true", extract_reset = "no" *) reg [LB-1:0] q2_reg;
	(* keep = "true", extract_reset = "no" *) reg [LB-1:0] q3_reg;

	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [RAW_AW-1:0] b0_raddr_q, b1_raddr_q, b2_raddr_q, b3_raddr_q;
	(* keep = "true", equivalent_register_removal = "no" *) reg [NS-1:0] b0_we_q, b1_we_q, b2_we_q, b3_we_q;
	(* keep = "true", equivalent_register_removal = "no", max_fanout = 12, extract_reset = "no" *) reg [RAW_AW-1:0] b0_waddr_q, b1_waddr_q, b2_waddr_q, b3_waddr_q;
	(* keep = "true", extract_reset = "no" *) reg [LB-1:0] b_wdata_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] mline_set_s01_q, mline_set_s23_q;
	(* keep = "true", extract_reset = "no" *) reg [IW-1:0] mline_set_q;
	(* keep = "true", extract_reset = "no" *) reg [1:0] fill_way_q;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [TW-1:0] mline_tag_s01_q, mline_tag_s23_q;
	(* keep = "true", equivalent_register_removal = "no" *) reg [WAYS-1:0] tag_we_s01_q, tag_we_s23_q;
	(* keep = "true", extract_reset = "no" *) reg [3:0] err_match_q;

	/* Tag read and compare pipeline registers */
	wire [TW-1:0] s0_tag_rdata [0:WAYS-1];
	wire [TW-1:0] s1_tag_rdata [0:WAYS-1];
	wire [TW-1:0] s2_tag_rdata [0:WAYS-1];
	wire [TW-1:0] s3_tag_rdata [0:WAYS-1];
	(* keep = "true", extract_reset = "no" *) reg [TW-1:0] s0_tag_w_q [0:WAYS-1];
	(* keep = "true", extract_reset = "no" *) reg [TW-1:0] s1_tag_w_q [0:WAYS-1];
	(* keep = "true", extract_reset = "no" *) reg [TW-1:0] s2_tag_w_q [0:WAYS-1];
	(* keep = "true", extract_reset = "no" *) reg [TW-1:0] s3_tag_w_q [0:WAYS-1];
	(* keep = "true" *) reg [WAYS-1:0] s0_vld_q, s1_vld_q, s2_vld_q, s3_vld_q;
	(* keep = "true" *) reg [WAYS-1:0] s0_hit_w_q, s1_hit_w_q, s2_hit_w_q, s3_hit_w_q;
	(* keep = "true" *) reg            s0_need_q, s1_need_q, s2_need_q, s3_need_q;

	/* Pre-decoded group enables and one-hot set/way masks for vld and plru (fanout <= 16) */
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  rd_plru_old0, rd_plru_old1, rd_plru_old2, rd_plru_old3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg        rd_plru_en0_w, rd_plru_en1_w, rd_plru_en2_w, rd_plru_en3_w;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [NGRPS-1:0] lex_plru_grp_en0, lex_plru_grp_en1, lex_plru_grp_en2, lex_plru_grp_en3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  lex_set_oh0   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  lex_set_oh1   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  lex_set_oh2   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  lex_set_oh3   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  lex_plru_new0 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  lex_plru_new1 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  lex_plru_new2 [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  lex_plru_new3 [0:3];

	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  mw_plru_pre;
	(* keep = "true", equivalent_register_removal = "no" *) reg [NGRPS-1:0] mw_vld_grp_en, mw_plru_grp_en;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  mw_vld_set_oh  [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  mw_plru_set_oh [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [3:0]  mw_way_oh      [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [15:0] drop_q_rep;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [2:0]  mw_plru_new    [0:3];

	(* extract_reset = "no", ram_style = "registers" *) reg [WAYS-1:0] vld [0:NSETS-1];
	(* extract_reset = "no", ram_style = "registers" *) reg [2:0] plru [0:NSETS-1];

	(* keep = "true", max_fanout = 12 *) reg [3:0] st;
	(* keep = "true", max_fanout = 12 *) reg [1:0] lane;
	reg drop;
	(* keep = "true", extract_reset = "no" *) reg [ADDR_W-LINE_SHIFT-1:0] mline;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] mline_set_v0, mline_set_v1, mline_set_v2, mline_set_v3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] mline_set_p0, mline_set_p1, mline_set_p2;
	(* keep = "true", extract_reset = "no" *) reg [1:0] miss_slot;
	reg [3:0] slot_err;
	(* keep = "true", extract_reset = "no" *) reg [511:0] ta_addr_q;

	/* Current lane slot registers to decouple lane index fanout */
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [ADDR_W-1:0] cur_a0;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [ADDR_W-1:0] cur_a1;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [ADDR_W-1:0] cur_a2;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg [ADDR_W-1:0] cur_a3;
	(* keep = "true", extract_reset = "no" *) reg cur_bord0;
	(* keep = "true", extract_reset = "no" *) reg cur_bord1;
	(* keep = "true", extract_reset = "no" *) reg cur_bord2;
	(* keep = "true", extract_reset = "no" *) reg cur_bord3;
	(* keep = "true", max_fanout = 12, extract_reset = "no" *) reg cur_mask;

	/* Pipeline registers from LANE_CHECK to LANE_READ */
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] rd_set0_b0, rd_set0_b1, rd_set0_b2, rd_set0_cmp;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] rd_set1_b0, rd_set1_b1, rd_set1_b2, rd_set1_cmp;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] rd_set2_b0, rd_set2_b1, rd_set2_b2, rd_set2_cmp;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:0] rd_set3_b0, rd_set3_b1, rd_set3_b2, rd_set3_cmp;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    rd_set0_oh, rd_set1_oh, rd_set2_oh, rd_set3_oh;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [IW-1:2] rd_set0_grp, rd_set1_grp, rd_set2_grp, rd_set3_grp;
	(* keep = "true", extract_reset = "no" *) reg [1:0]    rd_way0, rd_way1, rd_way2, rd_way3;
	(* keep = "true", extract_reset = "no" *) reg          rd_hit0, rd_hit1, rd_hit2, rd_hit3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [WW-1:0] rd_pw0_lo, rd_pw0_hi, rd_pw1_lo, rd_pw1_hi, rd_pw2_lo, rd_pw2_hi, rd_pw3_lo, rd_pw3_hi;
	(* keep = "true", extract_reset = "no" *) reg [1:0]    rd_pby0, rd_pby1, rd_pby2, rd_pby3;
	(* keep = "true", extract_reset = "no" *) reg          rd_border0, rd_border1, rd_border2, rd_border3;
	(* keep = "true", extract_reset = "no" *) reg          rd_use0, rd_use1, rd_use2, rd_use3;
	(* keep = "true", extract_reset = "no" *) reg [1:0]    rd_lane;

	/* Registered per-slot controls in LANE_FETCH (1 cycle before LANE_EXTRACT) */
	(* keep = "true", extract_reset = "no" *) reg          braw_c_lo, braw_c_hi0, braw_c_hi1, braw_c_hi2, braw_c_hi3;
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [WW-1:0] f_pw_b0_q [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [WW-1:0] f_pw_b1_q [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [WW-1:0] f_pw_b2_q [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [WW-1:0] f_pw_b3_q [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    f_pby_q   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    f_pb_q    [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    f_use_q   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    f_b8_q    [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [1:0]    f_b16_q   [0:3];
	(* keep = "true", equivalent_register_removal = "no", extract_reset = "no" *) reg [31:0]   f_braw_q  [0:3];

	/* Quad controls */
	wire bil = tc_ctl[0];
	wire [1:0] lsl = (tc_ctl[26:25] == 2'd1) ? 2'd1 :
	                 (tc_ctl[26:25] == 2'd2) ? 2'd3 : 2'd0;

	/* 4 slot addresses for current lane */
	wire [ADDR_W-1:0] a0 = cur_a0;
	wire [ADDR_W-1:0] a1 = cur_a1;
	wire [ADDR_W-1:0] a2 = cur_a2;
	wire [ADDR_W-1:0] a3 = cur_a3;

	wire border0 = cur_bord0;
	wire border1 = cur_bord1;
	wire border2 = cur_bord2;
	wire border3 = cur_bord3;

	wire [WW-1:0] pw0 = a0[2 +: WW];
	wire [WW-1:0] pw1 = a1[2 +: WW];
	wire [WW-1:0] pw2 = a2[2 +: WW];
	wire [WW-1:0] pw3 = a3[2 +: WW];

	wire [1:0] pby0 = a0[1:0];
	wire [1:0] pby1 = a1[1:0];
	wire [1:0] pby2 = a2[1:0];
	wire [1:0] pby3 = a3[1:0];

	wire [3:0] use_slot;
	assign use_slot[0] = cur_mask;
	assign use_slot[1] = cur_mask && (bil || (tc_ctl[26:25] != 2'd0));
	assign use_slot[2] = cur_mask && (bil || (tc_ctl[26:25] == 2'd2));
	assign use_slot[3] = cur_mask && (bil || (tc_ctl[26:25] == 2'd2));

	/* Set indices and tags for the 4 slots */
	wire [IW-1:0] s0_set = a0[LINE_SHIFT +: IW];
	wire [IW-1:0] s1_set = a1[LINE_SHIFT +: IW];
	wire [IW-1:0] s2_set = a2[LINE_SHIFT +: IW];
	wire [IW-1:0] s3_set = a3[LINE_SHIFT +: IW];

	wire [TW-1:0] s0_tag = a0[ADDR_W-1 -: TW];
	wire [TW-1:0] s1_tag = a1[ADDR_W-1 -: TW];
	wire [TW-1:0] s2_tag = a2[ADDR_W-1 -: TW];
	wire [TW-1:0] s3_tag = a3[ADDR_W-1 -: TW];

	/* Tag hit detection across 4 ways (from registered LANE_CMP outputs) */
	wire s0_hit  = |s0_hit_w_q;
	wire [1:0] s0_way = s0_hit_w_q[3] ? 2'd3 : s0_hit_w_q[2] ? 2'd2 : s0_hit_w_q[1] ? 2'd1 : 2'd0;

	wire s1_hit  = |s1_hit_w_q;
	wire [1:0] s1_way = s1_hit_w_q[3] ? 2'd3 : s1_hit_w_q[2] ? 2'd2 : s1_hit_w_q[1] ? 2'd1 : 2'd0;

	wire s2_hit  = |s2_hit_w_q;
	wire [1:0] s2_way = s2_hit_w_q[3] ? 2'd3 : s2_hit_w_q[2] ? 2'd2 : s2_hit_w_q[1] ? 2'd1 : 2'd0;

	wire s3_hit  = |s3_hit_w_q;
	wire [1:0] s3_way = s3_hit_w_q[3] ? 2'd3 : s3_hit_w_q[2] ? 2'd2 : s3_hit_w_q[1] ? 2'd1 : 2'd0;

	/* Miss determination (fanout-bounded) */
	(* keep = "true" *) wire s0_miss = s0_need_q && !s0_hit;
	(* keep = "true" *) wire s1_miss = s1_need_q && !s1_hit;
	(* keep = "true" *) wire s2_miss = s2_need_q && !s2_hit;
	(* keep = "true" *) wire s3_miss = s3_need_q && !s3_hit;
	(* keep = "true" *) wire any_miss = s0_miss || s1_miss || s2_miss || s3_miss;

	(* dont_touch = "true" *) wire [1:0] miss_slot_next    = s0_miss ? 2'd0 : s1_miss ? 2'd1 : s2_miss ? 2'd2 : 2'd3;
	(* dont_touch = "true" *) wire [1:0] miss_slot_next_s0 = s0_miss ? 2'd0 : s1_miss ? 2'd1 : s2_miss ? 2'd2 : 2'd3;
	(* dont_touch = "true" *) wire [1:0] miss_slot_next_s1 = s0_miss ? 2'd0 : s1_miss ? 2'd1 : s2_miss ? 2'd2 : 2'd3;
	(* dont_touch = "true" *) wire [1:0] miss_slot_next_s2 = s0_miss ? 2'd0 : s1_miss ? 2'd1 : s2_miss ? 2'd2 : 2'd3;
	(* dont_touch = "true" *) wire [1:0] miss_slot_next_s3 = s0_miss ? 2'd0 : s1_miss ? 2'd1 : s2_miss ? 2'd2 : 2'd3;

	wire [6:0] miss_line_next_0 =
		(miss_slot_next_s0 == 2'd0) ? a0[LINE_SHIFT + 0  +: 7] :
		(miss_slot_next_s0 == 2'd1) ? a1[LINE_SHIFT + 0  +: 7] :
		(miss_slot_next_s0 == 2'd2) ? a2[LINE_SHIFT + 0  +: 7] :
		                              a3[LINE_SHIFT + 0  +: 7];
	wire [6:0] miss_line_next_1 =
		(miss_slot_next_s1 == 2'd0) ? a0[LINE_SHIFT + 7  +: 7] :
		(miss_slot_next_s1 == 2'd1) ? a1[LINE_SHIFT + 7  +: 7] :
		(miss_slot_next_s1 == 2'd2) ? a2[LINE_SHIFT + 7  +: 7] :
		                              a3[LINE_SHIFT + 7  +: 7];
	wire [6:0] miss_line_next_2 =
		(miss_slot_next_s2 == 2'd0) ? a0[LINE_SHIFT + 14 +: 7] :
		(miss_slot_next_s2 == 2'd1) ? a1[LINE_SHIFT + 14 +: 7] :
		(miss_slot_next_s2 == 2'd2) ? a2[LINE_SHIFT + 14 +: 7] :
		                              a3[LINE_SHIFT + 14 +: 7];
	wire [ADDR_W-LINE_SHIFT-22:0] miss_line_next_3 =
		(miss_slot_next_s3 == 2'd0) ? a0[ADDR_W-1 : LINE_SHIFT + 21] :
		(miss_slot_next_s3 == 2'd1) ? a1[ADDR_W-1 : LINE_SHIFT + 21] :
		(miss_slot_next_s3 == 2'd2) ? a2[ADDR_W-1 : LINE_SHIFT + 21] :
		                              a3[ADDR_W-1 : LINE_SHIFT + 21];
	(* keep = "true" *) wire [ADDR_W-LINE_SHIFT-1:0] miss_line_next = {miss_line_next_3, miss_line_next_2, miss_line_next_1, miss_line_next_0};

	/* 4 Banks read concurrently for the 4 slots */
	wire [IW-1:0] b0_set = s0_set;
	wire [1:0]    b0_way = s0_way;
	wire [IW-1:0] b1_set = s1_set;
	wire [1:0]    b1_way = s1_way;
	wire [IW-1:0] b2_set = s2_set;
	wire [1:0]    b2_way = s2_way;
	wire [IW-1:0] b3_set = s3_set;
	wire [1:0]    b3_way = s3_way;

	/* 4 Banks read addresses */
	wire [RAW_AW-1:0] b0_raddr = {b0_set, b0_way};
	wire [RAW_AW-1:0] b1_raddr = {b1_set, b1_way};
	wire [RAW_AW-1:0] b2_raddr = {b2_set, b2_way};
	wire [RAW_AW-1:0] b3_raddr = {b3_set, b3_way};

	/* Crossbar output to slots (directly from clean registered BRAM output) */
	wire [LB-1:0] slot_line_arr [0:3];
	assign slot_line_arr[0] = q0_reg;
	assign slot_line_arr[1] = q1_reg;
	assign slot_line_arr[2] = q2_reg;
	assign slot_line_arr[3] = q3_reg;

	/* Per-slot fanout-isolated texel extraction (<= 16 loads per FF) */
	(* keep = "true" *) wire [31:0] tex_masked [0:3];
	genvar gt;
	generate
	for (gt = 0; gt < 4; gt = gt + 1) begin : g_tex_slot
		wire [7:0]  wd_b0 = slot_line_arr[gt][{f_pw_b0_q[gt], 5'd0}  +: 8];
		wire [7:0]  wd_b1 = slot_line_arr[gt][{f_pw_b1_q[gt], 5'd8}  +: 8];
		wire [7:0]  wd_b2 = slot_line_arr[gt][{f_pw_b2_q[gt], 5'd16} +: 8];
		wire [7:0]  wd_b3 = slot_line_arr[gt][{f_pw_b3_q[gt], 5'd24} +: 8];
		wire [15:0] wd_lo = {wd_b1, wd_b0};
		wire [15:0] wd_hi = {wd_b3, wd_b2};
		wire [15:0] hw_s  = f_pby_q[gt][1] ? wd_hi : wd_lo;
		wire [7:0]  by_s  = (f_pby_q[gt] == 2'd0) ? wd_lo[7:0]  :
		                    (f_pby_q[gt] == 2'd1) ? wd_lo[15:8] :
		                    (f_pby_q[gt] == 2'd2) ? wd_hi[7:0]  : wd_hi[15:8];
		(* keep = "true" *) wire [15:0] raw_lo_s = f_pb_q[gt][0] ? f_braw_q[gt][15:0]  : f_b8_q[gt][0] ? {8'd0, by_s} : f_b16_q[gt][0] ? hw_s : wd_lo;
		(* keep = "true" *) wire [15:0] raw_hi_s = f_pb_q[gt][1] ? f_braw_q[gt][31:16] : (f_b8_q[gt][1] || f_b16_q[gt][1]) ? 16'd0 : wd_hi;
		assign tex_masked[gt] = {
			f_use_q[gt][1] ? raw_hi_s : 16'd0,
			f_use_q[gt][0] ? raw_lo_s : 16'd0
		};
	end
	endgenerate

	/* Tree-PLRU helper functions */
	function [1:0] get_victim;
		input [3:0] v;
		input [2:0] p;
		begin
			if (!v[0]) get_victim = 2'd0;
			else if (!v[1]) get_victim = 2'd1;
			else if (!v[2]) get_victim = 2'd2;
			else if (!v[3]) get_victim = 2'd3;
			else if (!p[0]) get_victim = p[1] ? 2'd1 : 2'd0;
			else get_victim = p[2] ? 2'd3 : 2'd2;
		end
	endfunction

	function [2:0] update_plru;
		input [2:0] p;
		input [1:0] w;
		begin
			case (w)
			2'd0: update_plru = {p[2], 1'b1, 1'b1};
			2'd1: update_plru = {p[2], 1'b0, 1'b1};
			2'd2: update_plru = {1'b1, p[1], 1'b0};
			2'd3: update_plru = {1'b0, p[1], 1'b0};
			default: update_plru = p;
			endcase
		end
	endfunction

	function [3:0] dec2to4;
		input [1:0] x;
		begin
			case (x)
			2'd0: dec2to4 = 4'b0001;
			2'd1: dec2to4 = 4'b0010;
			2'd2: dec2to4 = 4'b0100;
			2'd3: dec2to4 = 4'b1000;
			endcase
		end
	endfunction

	wire [1:0] nxt_lane;
	wire nxt_lane_co_unused;
	am_add #(.W(2)) u_inc_lane (.a(lane), .b(2'd1), .ci(1'b0), .s(nxt_lane), .co(nxt_lane_co_unused));

	wire no_more_lanes = (lane == 2'd0 && tc_mask[3:1] == 3'b000) ||
	                     (lane == 2'd1 && tc_mask[3:2] == 2'b00)  ||
	                     (lane == 2'd2 && !tc_mask[3])            ||
	                     (lane == 2'd3);

	assign ta_ready = st == IDLE;
	assign tc_valid = st == OUT;
	assign req_valid = st == MREQ;
	assign req_write = 1'b0;
	assign req_line = mline;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	wire [IW-1:0] mline_set = mline[IW-1:0];
	wire [3:0] mline_vld_cur  = {vld[mline_set_v3][3], vld[mline_set_v2][2], vld[mline_set_v1][1], vld[mline_set_v0][0]};
	wire [2:0] mline_plru_cur = {plru[mline_set_p2][2], plru[mline_set_p1][1], plru[mline_set_p0][0]};
	wire [1:0] fill_way = get_victim(mline_vld_cur, mline_plru_cur);
	wire [RAW_AW-1:0] b_waddr = {mline_set, fill_way};

	/* Tag BRAMs: 4 slots x 4 ways (Clean single-cycle memory: 0 LUTs on ADDR and DOUT) */
	genvar gw;
	generate
	for (gw = 0; gw < WAYS; gw = gw + 1) begin : g_tag_bram
		(* dont_touch = "true" *)
		am_bram_sdp #(.W(TW), .ADDR_W(IW)) u_tag_s0 (
			.clk(clk), .we(tag_we_s01_q[gw]), .waddr(mline_set_s01_q), .wdata(mline_tag_s01_q),
			.re(1'b1), .raddr(s0_set), .rdata(s0_tag_rdata[gw])
		);
		(* dont_touch = "true" *)
		am_bram_sdp #(.W(TW), .ADDR_W(IW)) u_tag_s1 (
			.clk(clk), .we(tag_we_s01_q[gw]), .waddr(mline_set_s01_q), .wdata(mline_tag_s01_q),
			.re(1'b1), .raddr(s1_set), .rdata(s1_tag_rdata[gw])
		);
		(* dont_touch = "true" *)
		am_bram_sdp #(.W(TW), .ADDR_W(IW)) u_tag_s2 (
			.clk(clk), .we(tag_we_s23_q[gw]), .waddr(mline_set_s23_q), .wdata(mline_tag_s23_q),
			.re(1'b1), .raddr(s2_set), .rdata(s2_tag_rdata[gw])
		);
		(* dont_touch = "true" *)
		am_bram_sdp #(.W(TW), .ADDR_W(IW)) u_tag_s3 (
			.clk(clk), .we(tag_we_s23_q[gw]), .waddr(mline_set_s23_q), .wdata(mline_tag_s23_q),
			.re(1'b1), .raddr(s3_set), .rdata(s3_tag_rdata[gw])
		);
	end
	endgenerate

	/* 4 Banks instantiated via 64-bit am_bram_sdp slices (1 RAMB36 per slice, fanout <= 8) */
	genvar gs;
	generate
	for (gs = 0; gs < NS; gs = gs + 1) begin : g_bank_slices
		(* dont_touch = "true" *)
		am_bram_sdp #(.W(64), .ADDR_W(RAW_AW)) u_bram_b0 (
			.clk(clk), .we(b0_we_q[gs]), .waddr(b0_waddr_q), .wdata(b_wdata_q[gs*64 +: 64]),
			.re(1'b1), .raddr(b0_raddr_q), .rdata(bank_q0[gs*64 +: 64])
		);
		if (NBANKS > 1) begin : g_b1
			(* dont_touch = "true" *)
			am_bram_sdp #(.W(64), .ADDR_W(RAW_AW)) u_bram_b1 (
				.clk(clk), .we(b1_we_q[gs]), .waddr(b1_waddr_q), .wdata(b_wdata_q[gs*64 +: 64]),
				.re(1'b1), .raddr(b1_raddr_q), .rdata(bank_q1[gs*64 +: 64])
			);
		end else begin : g_b1_shared
			assign bank_q1[gs*64 +: 64] = bank_q0[gs*64 +: 64];
		end
		if (NBANKS > 2) begin : g_b23
			(* dont_touch = "true" *)
			am_bram_sdp #(.W(64), .ADDR_W(RAW_AW)) u_bram_b2 (
				.clk(clk), .we(b2_we_q[gs]), .waddr(b2_waddr_q), .wdata(b_wdata_q[gs*64 +: 64]),
				.re(1'b1), .raddr(b2_raddr_q), .rdata(bank_q2[gs*64 +: 64])
			);
			(* dont_touch = "true" *)
			am_bram_sdp #(.W(64), .ADDR_W(RAW_AW)) u_bram_b3 (
				.clk(clk), .we(b3_we_q[gs]), .waddr(b3_waddr_q), .wdata(b_wdata_q[gs*64 +: 64]),
				.re(1'b1), .raddr(b3_raddr_q), .rdata(bank_q3[gs*64 +: 64])
			);
		end else begin : g_b23_shared
			assign bank_q2[gs*64 +: 64] = bank_q0[gs*64 +: 64];
			assign bank_q3[gs*64 +: 64] = bank_q1[gs*64 +: 64];
		end
	end
	endgenerate

	/* Fanout-decoupled slice enables for wide registers */
	(* keep = "true" *) wire [11:0] ta_vld_g   = {12{ta_valid}};
	(* keep = "true" *) wire [7:0]  tex_clr_g  = {8{(st == IDLE) && ta_vld_g[8]}};
	(* keep = "true" *) wire [7:0]  tex_we_g;
	(* keep = "true" *) wire [63:0] idle_ce_a;
	(* keep = "true" *) wire [7:0]  idle_ce_wts;
	(* keep = "true" *) wire [7:0]  idle_ce_val;
	(* keep = "true" *) wire [9:0]  idle_meta_ce = {{5{(st == IDLE) && ta_vld_g[10]}}, {5{(st == IDLE) && ta_vld_g[9]}}};
	(* keep = "true" *) wire [63:0] tex_clr_s;
	(* keep = "true" *) wire [63:0] tex_we_s;
	(* keep = "true" *) wire [1:0]  cur_idle_g = {2{(st == IDLE) && ta_vld_g[11]}};
	(* keep = "true" *) wire [1:0]  cur_step_g = {2{!no_more_lanes && ((st == LANE_EXTRACT) || ((st == LANE_TAG_RD) && !cur_mask))}};
	(* keep = "true" *) wire [15:0] cur_idle_s;
	(* keep = "true" *) wire [15:0] cur_step_s;
	(* keep = "true" *) wire [1:0]  nxt_lane_s [0:15];

	(* dont_touch = "true" *) wire [2:0]  lchk_en  = {3{st == LANE_CMP}};
	(* dont_touch = "true" *) wire [1:0]  lfetch_en = {2{st == LANE_WAIT}};
	(* keep = "true", equivalent_register_removal = "no" *) reg [28:0] lchk_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [3:0]  lwait_ce;
	(* keep = "true", equivalent_register_removal = "no" *) reg [15:0] lfetch_ce;
	(* dont_touch = "true" *) wire [5:0]  mreq_ce     = {6{st == MREQ}};
	(* dont_touch = "true" *) wire        mwait_ok_st = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_we0 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_we1 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_we2 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g0 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g1 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g2 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g3 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g4 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g5 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g6 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_ok_g7 = (st == MWAIT) && rsp_valid && !rsp_error;
	(* dont_touch = "true" *) wire        mwait_err_a = (st == MWAIT) && rsp_valid && rsp_error;
	(* dont_touch = "true" *) wire        mwait_err_b = (st == MWAIT) && rsp_valid && rsp_error;

	wire [17:0] inv_b;
	genvar gi;
	generate
	for (gi = 0; gi < 8; gi = gi + 1) begin : g_slice_8
		assign idle_ce_wts[gi] = (st == IDLE) && ta_vld_g[4];
		assign idle_ce_val[gi] = (st == IDLE) && ta_vld_g[5];
		assign tex_we_g[gi]    = (st == LANE_EXTRACT) && (rd_lane == gi[2:1]);
	end
	for (gi = 0; gi < 64; gi = gi + 1) begin : g_slice_64
		assign idle_ce_a[gi] = (st == IDLE) && ta_vld_g[gi / 16];
		assign tex_clr_s[gi] = tex_clr_g[gi / 8];
		assign tex_we_s[gi]  = tex_we_g[gi / 8];
	end
	for (gi = 0; gi < 16; gi = gi + 1) begin : g_slice_16
		assign cur_idle_s[gi] = cur_idle_g[gi / 8];
		assign cur_step_s[gi] = cur_step_g[gi / 8];
		assign nxt_lane_s[gi] = nxt_lane;
	end
	for (gi = 0; gi < 18; gi = gi + 1) begin : g_inv_buf
`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *)
		LUT1 #(.INIT(2'b10)) u_ibuf (.I0(inv), .O(inv_b[gi]));
`else
		assign inv_b[gi] = inv;
`endif
	end
	endgenerate

	integer j, g_idx, k_idx, w_idx;
	always @(posedge clk) begin
		/* Unconditional pipeline registers for BRAM write data and BRAM read data */
		b_wdata_q <= rsp_rdata;
		q0_reg    <= bank_q0;
		q1_reg    <= bank_q1;
		q2_reg    <= bank_q2;
		q3_reg    <= bank_q3;
		for (j = 0; j < WAYS; j = j + 1) begin
			s0_tag_w_q[j] <= s0_tag_rdata[j];
			s1_tag_w_q[j] <= s1_tag_rdata[j];
			s2_tag_w_q[j] <= s2_tag_rdata[j];
			s3_tag_w_q[j] <= s3_tag_rdata[j];
		end

		/* Slice-enabled wide input capture registers (fanout <= 8..16 per enable) */
		for (j = 0; j < 64; j = j + 1) begin
			if (idle_ce_a[j])
				ta_addr_q[j*8 +: 8] <= ta_addr[j*8 +: 8];
		end
		for (j = 0; j < 8; j = j + 1) begin
			if (idle_ce_wts[j])
				tc_wts[j*16 +: 16]   <= ta_wts[j*16 +: 16];
			if (idle_ce_val[j])
				tc_value[j*16 +: 16] <= ta_value[j*16 +: 16];
		end
		for (j = 0; j < 64; j = j + 1) begin
			if (tex_clr_s[j])
				tc_texels[j*8 +: 8] <= 8'd0;
			else if (tex_we_s[j])
				tc_texels[j*8 +: 8] <= tex_masked[j[3:2]][{j[1:0], 3'b000} +: 8];
		end

		if (idle_meta_ce[0]) tc_bord <= ta_bord;
		if (idle_meta_ce[1]) begin
			for (j = 0; j < 8; j = j + 1)
				tc_lo[{1'b0, j[2:0], 1'b0} +: 2] <= ta_addr[{1'b0, j[2:0], 5'b00000} +: 2];
		end
		if (idle_meta_ce[2]) begin
			for (j = 8; j < 16; j = j + 1)
				tc_lo[{j[3:0], 1'b0} +: 2] <= ta_addr[{j[3:0], 5'b00000} +: 2];
		end
		if (idle_meta_ce[3]) tc_tag <= ta_tag;
		if (idle_meta_ce[4]) tc_ctl[15:0]  <= ta_ctl[15:0];
		if (idle_meta_ce[5]) tc_ctl[31:16] <= ta_ctl[31:16];
		if (idle_meta_ce[6]) tc_ctl[47:32] <= ta_ctl[47:32];
		if (idle_meta_ce[7]) begin
			tc_ctl[49:48] <= ta_ctl[49:48];
			tc_mask       <= ta_mask;
			tc_last       <= ta_last;
		end

		if (lchk_ce[0]) begin
			mline[6:0]   <= miss_line_next[6:0];
			mline_set_v0 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[25]) begin
			mline[13:7] <= miss_line_next[13:7];
			miss_slot   <= miss_slot_next;
		end
		if (lchk_ce[1]) begin
			mline[20:14] <= miss_line_next[20:14];
			mline_set_v1 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[26]) begin
			mline[ADDR_W-LINE_SHIFT-1:21] <= miss_line_next[ADDR_W-LINE_SHIFT-1:21];
			rd_lane <= lane;
		end
		if (lchk_ce[2]) begin
			b0_raddr_q <= b0_raddr;
			b1_raddr_q <= b1_raddr;
		end
		if (lchk_ce[3]) begin
			b2_raddr_q <= b2_raddr;
			b3_raddr_q <= b3_raddr;
		end
		if (lchk_ce[4]) begin
			rd_set0_b0 <= s0_set;
			rd_set0_b1 <= s0_set;
			rd_way0    <= s0_way;
		end
		if (lchk_ce[5]) begin
			rd_set1_b0 <= s1_set;
			rd_set1_b1 <= s1_set;
			rd_way1    <= s1_way;
		end
		if (lchk_ce[6]) begin
			rd_set2_b0 <= s2_set;
			rd_set2_b1 <= s2_set;
			rd_way2    <= s2_way;
		end
		if (lchk_ce[7]) begin
			rd_set3_b0 <= s3_set;
			rd_set3_b1 <= s3_set;
			rd_way3    <= s3_way;
		end
		if (lchk_ce[27]) begin
			rd_set0_oh  <= s0_set[1:0];
			rd_set1_oh  <= s1_set[1:0];
			rd_set2_oh  <= s2_set[1:0];
			rd_set3_oh  <= s3_set[1:0];
		end
		if (lchk_ce[28]) begin
			rd_set0_grp <= s0_set[IW-1:2];
			rd_set1_grp <= s1_set[IW-1:2];
			rd_set2_grp <= s2_set[IW-1:2];
			rd_set3_grp <= s3_set[IW-1:2];
		end
		if (lchk_ce[8]) begin
			rd_hit0 <= use_slot[0] && !border0 && s0_hit;
			rd_hit1 <= use_slot[1] && !border1 && s1_hit;
			rd_hit2 <= use_slot[2] && !border2 && s2_hit;
			rd_hit3 <= use_slot[3] && !border3 && s3_hit;
			mline_set_v2 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[9]) begin
			rd_pw0_lo <= pw0;
			rd_pw0_hi <= pw0;
			mline_set_v3 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[10]) begin
			rd_pw1_lo <= pw1;
			rd_pw1_hi <= pw1;
			mline_set_p0 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[15]) begin
			rd_pw2_lo <= pw2;
			rd_pw2_hi <= pw2;
		end
		if (lchk_ce[16]) begin
			rd_pw3_lo <= pw3;
			rd_pw3_hi <= pw3;
		end
		if (lchk_ce[11]) begin
			rd_pby0 <= pby0;
			rd_pby1 <= pby1;
			mline_set_p1 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[12]) begin
			rd_pby2 <= pby2;
			rd_pby3 <= pby3;
			mline_set_p2 <= miss_line_next[IW-1:0];
		end
		if (lchk_ce[13]) begin
			rd_border0  <= border0;
			rd_border1  <= border1;
			rd_border2  <= border2;
			rd_border3  <= border3;
			rd_set0_b2  <= s0_set;
			rd_set0_cmp <= s0_set;
		end
		if (lchk_ce[14]) begin
			rd_use0     <= use_slot[0] && !slot_err[0];
			rd_use1     <= use_slot[1] && !slot_err[1];
			rd_use2     <= use_slot[2] && !slot_err[2];
			rd_use3     <= use_slot[3] && !slot_err[3];
			rd_set1_b2  <= s1_set;
			rd_set1_cmp <= s1_set;
		end
		if (lchk_ce[17]) begin
			rd_set2_b2  <= s2_set;
			rd_set2_cmp <= s2_set;
		end
		if (lchk_ce[18]) begin
			rd_set3_b2  <= s3_set;
			rd_set3_cmp <= s3_set;
		end

		for (j = 0; j < 4; j = j + 1) begin
			if (cur_idle_s[0 + j]) cur_a0[j*8 +: 8] <= ta_addr[0  + j*8 +: 8];
			else if (cur_step_s[0 + j]) cur_a0[j*8 +: 8] <= ta_addr_q[{nxt_lane_s[0 + j], 2'b00, j[1:0], 3'b000} +: 8];

			if (cur_idle_s[4 + j]) cur_a1[j*8 +: 8] <= ta_addr[32 + j*8 +: 8];
			else if (cur_step_s[4 + j]) cur_a1[j*8 +: 8] <= ta_addr_q[{nxt_lane_s[4 + j], 2'b01, j[1:0], 3'b000} +: 8];

			if (cur_idle_s[8 + j]) cur_a2[j*8 +: 8] <= ta_addr[64 + j*8 +: 8];
			else if (cur_step_s[8 + j]) cur_a2[j*8 +: 8] <= ta_addr_q[{nxt_lane_s[8 + j], 2'b10, j[1:0], 3'b000} +: 8];

			if (cur_idle_s[12 + j]) cur_a3[j*8 +: 8] <= ta_addr[96 + j*8 +: 8];
			else if (cur_step_s[12 + j]) cur_a3[j*8 +: 8] <= ta_addr_q[{nxt_lane_s[12 + j], 2'b11, j[1:0], 3'b000} +: 8];
		end

		if (lwait_ce[0]) begin
			rd_plru_old0  <= {plru[rd_set0_b2][2], plru[rd_set0_b1][1], plru[rd_set0_b0][0]};
			rd_plru_en0_w <= rd_hit0;
		end
		if (lwait_ce[1]) begin
			rd_plru_old1  <= {plru[rd_set1_b2][2], plru[rd_set1_b1][1], plru[rd_set1_b0][0]};
			rd_plru_en1_w <= rd_hit1 && (rd_set1_cmp != rd_set0_cmp || !rd_hit0);
		end
		if (lwait_ce[2]) begin
			rd_plru_old2  <= {plru[rd_set2_b2][2], plru[rd_set2_b1][1], plru[rd_set2_b0][0]};
			rd_plru_en2_w <= rd_hit2 &&
			                 (rd_set2_cmp != rd_set0_cmp || !rd_hit0) &&
			                 (rd_set2_cmp != rd_set1_cmp || !rd_hit1);
		end
		if (lwait_ce[3]) begin
			rd_plru_old3  <= {plru[rd_set3_b2][2], plru[rd_set3_b1][1], plru[rd_set3_b0][0]};
			rd_plru_en3_w <= rd_hit3 &&
			                 (rd_set3_cmp != rd_set0_cmp || !rd_hit0) &&
			                 (rd_set3_cmp != rd_set1_cmp || !rd_hit1) &&
			                 (rd_set3_cmp != rd_set2_cmp || !rd_hit2);
		end

		for (j = 0; j < 4; j = j + 1) begin
			if (lfetch_ce[2*j]) begin
				lex_set_oh0[j]   <= dec2to4(rd_set0_oh);
				lex_set_oh1[j]   <= dec2to4(rd_set1_oh);
				lex_set_oh2[j]   <= dec2to4(rd_set2_oh);
				lex_set_oh3[j]   <= dec2to4(rd_set3_oh);
			end
			if (lfetch_ce[2*j + 1]) begin
				lex_plru_new0[j] <= update_plru(rd_plru_old0, rd_way0);
				lex_plru_new1[j] <= update_plru(rd_plru_old1, rd_way1);
				lex_plru_new2[j] <= update_plru(rd_plru_old2, rd_way2);
				lex_plru_new3[j] <= update_plru(rd_plru_old3, rd_way3);
			end
		end
		if (lfetch_ce[12]) begin
			f_pw_b0_q[0] <= rd_pw0_lo; f_pw_b1_q[0] <= rd_pw0_lo;
			f_pw_b2_q[0] <= rd_pw0_hi; f_pw_b3_q[0] <= rd_pw0_hi;
			f_pby_q[0]   <= rd_pby0;   f_pb_q[0]    <= {2{rd_border0}};
			f_use_q[0]   <= {2{rd_use0}};
			f_b8_q[0]    <= {2{tc_ctl[24:23] == 2'd2}};
			f_b16_q[0]   <= {2{tc_ctl[19] || (tc_ctl[24:23] == 2'd1)}};
		end
		if (lfetch_ce[13]) begin
			f_pw_b0_q[1] <= rd_pw1_lo; f_pw_b1_q[1] <= rd_pw1_lo;
			f_pw_b2_q[1] <= rd_pw1_hi; f_pw_b3_q[1] <= rd_pw1_hi;
			f_pby_q[1]   <= rd_pby1;   f_pb_q[1]    <= {2{rd_border1}};
			f_use_q[1]   <= {2{rd_use1}};
			f_b8_q[1]    <= {2{tc_ctl[24:23] == 2'd2}};
			f_b16_q[1]   <= {2{tc_ctl[19] || (tc_ctl[24:23] == 2'd1)}};
		end
		if (lfetch_ce[14]) begin
			f_pw_b0_q[2] <= rd_pw2_lo; f_pw_b1_q[2] <= rd_pw2_lo;
			f_pw_b2_q[2] <= rd_pw2_hi; f_pw_b3_q[2] <= rd_pw2_hi;
			f_pby_q[2]   <= rd_pby2;   f_pb_q[2]    <= {2{rd_border2}};
			f_use_q[2]   <= {2{rd_use2}};
			f_b8_q[2]    <= {2{tc_ctl[24:23] == 2'd2}};
			f_b16_q[2]   <= {2{tc_ctl[19] || (tc_ctl[24:23] == 2'd1)}};
		end
		if (lfetch_ce[15]) begin
			f_pw_b0_q[3] <= rd_pw3_lo; f_pw_b1_q[3] <= rd_pw3_lo;
			f_pw_b2_q[3] <= rd_pw3_hi; f_pw_b3_q[3] <= rd_pw3_hi;
			f_pby_q[3]   <= rd_pby3;   f_pb_q[3]    <= {2{rd_border3}};
			f_use_q[3]   <= {2{rd_use3}};
			f_b8_q[3]    <= {2{tc_ctl[24:23] == 2'd2}};
			f_b16_q[3]   <= {2{tc_ctl[19] || (tc_ctl[24:23] == 2'd1)}};
		end
		for (j = 1; j < 4; j = j + 1) begin
			if (lchk_ce[17 + 2*j]) f_braw_q[j][15:0]  <= f_braw_q[0][15:0];
			if (lchk_ce[18 + 2*j]) f_braw_q[j][31:16] <= f_braw_q[0][31:16];
		end

		if (mreq_ce[0]) begin
			mline_set_q     <= mline_set;
			mline_set_s01_q <= mline_set;
			fill_way_q      <= fill_way;
		end
		if (mreq_ce[1]) begin
			mline_set_s23_q <= mline_set;
			mw_plru_pre     <= update_plru(mline_plru_cur, fill_way);
			err_match_q[0]  <= (a0[ADDR_W-1:LINE_SHIFT] == mline);
			err_match_q[1]  <= (a1[ADDR_W-1:LINE_SHIFT] == mline);
			err_match_q[2]  <= (a2[ADDR_W-1:LINE_SHIFT] == mline);
			err_match_q[3]  <= (a3[ADDR_W-1:LINE_SHIFT] == mline);
		end
		if (mreq_ce[2]) mline_tag_s01_q <= mline[ADDR_W-LINE_SHIFT-1 -: TW];
		if (mreq_ce[3]) mline_tag_s23_q <= mline[ADDR_W-LINE_SHIFT-1 -: TW];
		if (mreq_ce[4]) begin
			b0_waddr_q <= b_waddr;
			b1_waddr_q <= b_waddr;
		end
		if (mreq_ce[5]) begin
			b2_waddr_q <= b_waddr;
			b3_waddr_q <= b_waddr;
		end

		if (mwait_ok_g0) begin
			mw_vld_set_oh[0]  <= dec2to4(mline_set_q[1:0]);
			mw_plru_set_oh[0] <= dec2to4(mline_set_q[1:0]);
			mw_way_oh[0]      <= dec2to4(fill_way_q);
			drop_q_rep[3:0]   <= {4{drop || inv_b[17]}};
			mw_plru_new[0]    <= mw_plru_pre;
		end
		if (mwait_ok_g1) begin
			mw_vld_set_oh[1]  <= dec2to4(mline_set_q[1:0]);
			mw_plru_set_oh[1] <= dec2to4(mline_set_q[1:0]);
			mw_way_oh[1]      <= dec2to4(fill_way_q);
			drop_q_rep[7:4]   <= {4{drop || inv_b[17]}};
			mw_plru_new[1]    <= mw_plru_pre;
		end
		if (mwait_ok_g2) begin
			mw_vld_set_oh[2]  <= dec2to4(mline_set_q[1:0]);
			mw_plru_set_oh[2] <= dec2to4(mline_set_q[1:0]);
			mw_way_oh[2]      <= dec2to4(fill_way_q);
			drop_q_rep[11:8]  <= {4{drop || inv_b[17]}};
			mw_plru_new[2]    <= mw_plru_pre;
		end
		if (mwait_ok_g3) begin
			mw_vld_set_oh[3]  <= dec2to4(mline_set_q[1:0]);
			mw_plru_set_oh[3] <= dec2to4(mline_set_q[1:0]);
			mw_way_oh[3]      <= dec2to4(fill_way_q);
			drop_q_rep[15:12] <= {4{drop || inv_b[17]}};
			mw_plru_new[3]    <= mw_plru_pre;
		end

		for (g_idx = 0; g_idx < NGRPS; g_idx = g_idx + 1) begin
			for (k_idx = 0; k_idx < 4; k_idx = k_idx + 1) begin
				if (lex_plru_grp_en0[g_idx] && lex_set_oh0[g_idx >> 2][k_idx])
					plru[g_idx*4 + k_idx] <= lex_plru_new0[g_idx >> 2];
				else if (lex_plru_grp_en1[g_idx] && lex_set_oh1[g_idx >> 2][k_idx])
					plru[g_idx*4 + k_idx] <= lex_plru_new1[g_idx >> 2];
				else if (lex_plru_grp_en2[g_idx] && lex_set_oh2[g_idx >> 2][k_idx])
					plru[g_idx*4 + k_idx] <= lex_plru_new2[g_idx >> 2];
				else if (lex_plru_grp_en3[g_idx] && lex_set_oh3[g_idx >> 2][k_idx])
					plru[g_idx*4 + k_idx] <= lex_plru_new3[g_idx >> 2];
				else if (mw_plru_grp_en[g_idx] && mw_plru_set_oh[g_idx >> 2][k_idx])
					plru[g_idx*4 + k_idx] <= mw_plru_new[g_idx >> 2];
			end
		end

		if (rst_inv) begin
			st <= IDLE;
			lane <= 2'd0;
			drop <= 1'b0;
			slot_err <= 4'd0;
			lchk_ce <= 29'd0;
			lwait_ce <= 4'd0;
			lfetch_ce <= 16'd0;
			b0_we_q <= {NS{1'b0}};
			b1_we_q <= {NS{1'b0}};
			b2_we_q <= {NS{1'b0}};
			b3_we_q <= {NS{1'b0}};
			tag_we_s01_q <= {WAYS{1'b0}};
			tag_we_s23_q <= {WAYS{1'b0}};
			s0_vld_q <= {WAYS{1'b0}};
			s1_vld_q <= {WAYS{1'b0}};
			s2_vld_q <= {WAYS{1'b0}};
			s3_vld_q <= {WAYS{1'b0}};
			s0_hit_w_q <= {WAYS{1'b0}};
			s1_hit_w_q <= {WAYS{1'b0}};
			s2_hit_w_q <= {WAYS{1'b0}};
			s3_hit_w_q <= {WAYS{1'b0}};
			s0_need_q <= 1'b0;
			s1_need_q <= 1'b0;
			s2_need_q <= 1'b0;
			s3_need_q <= 1'b0;
			lex_plru_grp_en0 <= {NGRPS{1'b0}};
			lex_plru_grp_en1 <= {NGRPS{1'b0}};
			lex_plru_grp_en2 <= {NGRPS{1'b0}};
			lex_plru_grp_en3 <= {NGRPS{1'b0}};
			mw_vld_grp_en    <= {NGRPS{1'b0}};
			mw_plru_grp_en   <= {NGRPS{1'b0}};
			for (g_idx = 0; g_idx < NSETS; g_idx = g_idx + 1) begin
				vld[g_idx] <= {WAYS{1'b0}};
				plru[g_idx] <= 3'd0;
			end
		end else begin
			lchk_ce   <= {{9{lchk_en[2]}}, {10{lchk_en[1]}}, {10{lchk_en[0]}}};
			lwait_ce  <= {4{st == LANE_CHECK && !any_miss}};
			lfetch_ce <= {{8{lfetch_en[1]}}, {8{lfetch_en[0]}}};
			for (g_idx = 0; g_idx < NGRPS; g_idx = g_idx + 1) begin
				lex_plru_grp_en0[g_idx] <= lfetch_ce[8 + (g_idx >> 2)] && rd_plru_en0_w && (rd_set0_grp == g_idx[GRP_W-1:0]);
				lex_plru_grp_en1[g_idx] <= lfetch_ce[8 + (g_idx >> 2)] && rd_plru_en1_w && (rd_set1_grp == g_idx[GRP_W-1:0]);
				lex_plru_grp_en2[g_idx] <= lfetch_ce[8 + (g_idx >> 2)] && rd_plru_en2_w && (rd_set2_grp == g_idx[GRP_W-1:0]);
				lex_plru_grp_en3[g_idx] <= lfetch_ce[8 + (g_idx >> 2)] && rd_plru_en3_w && (rd_set3_grp == g_idx[GRP_W-1:0]);
				mw_vld_grp_en[g_idx]    <= ((g_idx < 4) ? mwait_ok_g4 : (g_idx < 8) ? mwait_ok_g5 : (g_idx < 12) ? mwait_ok_g6 : mwait_ok_g7) && (mline_set_q[IW-1:2] == g_idx[GRP_W-1:0]);
				mw_plru_grp_en[g_idx]   <= ((g_idx < 4) ? mwait_ok_g4 : (g_idx < 8) ? mwait_ok_g5 : (g_idx < 12) ? mwait_ok_g6 : mwait_ok_g7) && (mline_set_q[IW-1:2] == g_idx[GRP_W-1:0]);
				for (k_idx = 0; k_idx < 4; k_idx = k_idx + 1) begin
					if (inv_b[g_idx])
						vld[g_idx*4 + k_idx] <= {WAYS{1'b0}};
					else if (mw_vld_grp_en[g_idx] && mw_vld_set_oh[g_idx >> 2][k_idx]) begin
						for (w_idx = 0; w_idx < WAYS; w_idx = w_idx + 1) begin
							if (mw_way_oh[g_idx >> 2][w_idx])
								vld[g_idx*4 + k_idx][w_idx] <= !drop_q_rep[g_idx];
						end
					end
				end
			end

			case (st)
			IDLE: if (idle_meta_ce[9]) begin
				lane <= 2'd0;
				slot_err <= 4'd0;
				cur_bord0 <= ta_bord[0];
				cur_bord1 <= ta_bord[1];
				cur_bord2 <= ta_bord[2];
				cur_bord3 <= ta_bord[3];
				cur_mask <= ta_mask[0];
				st <= ta_ctl[2] ? OUT : LANE_TAG_RD;
			end
			LANE_TAG_RD: begin
				if (!cur_mask) begin
					/* Lane masked out */
					if (no_more_lanes)
						st <= OUT;
					else begin
						lane <= nxt_lane;
						cur_bord0 <= tc_bord[{nxt_lane, 2'b00}];
						cur_bord1 <= tc_bord[{nxt_lane, 2'b01}];
						cur_bord2 <= tc_bord[{nxt_lane, 2'b10}];
						cur_bord3 <= tc_bord[{nxt_lane, 2'b11}];
						cur_mask <= tc_mask[nxt_lane];
						slot_err <= 4'd0;
					end
				end else begin
					s0_vld_q <= inv_b[16] ? {WAYS{1'b0}} : vld[s0_set];
					s1_vld_q <= inv_b[16] ? {WAYS{1'b0}} : vld[s1_set];
					s2_vld_q <= inv_b[16] ? {WAYS{1'b0}} : vld[s2_set];
					s3_vld_q <= inv_b[16] ? {WAYS{1'b0}} : vld[s3_set];
					braw_c_lo  <= (tc_ctl[7:6] == 2'd2) && (tc_ctl[19] || !tc_ctl[8] || !tc_ctl[1]);
					braw_c_hi0 <= (tc_ctl[7:6] == 2'd2) && !tc_ctl[19] && (!tc_ctl[8] || !tc_ctl[1]);
					braw_c_hi1 <= (tc_ctl[7:6] == 2'd2) && !tc_ctl[19];
					braw_c_hi2 <= ((tc_ctl[7:6] == 2'd2) && !tc_ctl[19] && (!tc_ctl[8] || tc_ctl[1])) ||
					              ((tc_ctl[7:6] == 2'd1) && !tc_ctl[8] && !tc_ctl[19]);
					braw_c_hi3 <= ((tc_ctl[7:6] == 2'd2) && !tc_ctl[19] && !tc_ctl[8]) ||
					              ((tc_ctl[7:6] == 2'd1) && !tc_ctl[8] && !tc_ctl[19]);
					st <= LANE_TAG_WAIT;
				end
			end
			LANE_TAG_WAIT: begin
				f_braw_q[0] <= {{2{braw_c_hi3}}, {6{braw_c_hi2}}, braw_c_hi1, {7{braw_c_hi0}}, {16{braw_c_lo}}};
				st <= LANE_CMP;
			end
			LANE_CMP: begin
				for (j = 0; j < WAYS; j = j + 1) begin
					s0_hit_w_q[j] <= !inv_b[17] && ({s0_vld_q[j], s0_tag_w_q[j]} == {1'b1, s0_tag});
					s1_hit_w_q[j] <= !inv_b[17] && ({s1_vld_q[j], s1_tag_w_q[j]} == {1'b1, s1_tag});
					s2_hit_w_q[j] <= !inv_b[17] && ({s2_vld_q[j], s2_tag_w_q[j]} == {1'b1, s2_tag});
					s3_hit_w_q[j] <= !inv_b[17] && ({s3_vld_q[j], s3_tag_w_q[j]} == {1'b1, s3_tag});
				end
				s0_need_q <= use_slot[0] && !border0 && !slot_err[0];
				s1_need_q <= use_slot[1] && !border1 && !slot_err[1];
				s2_need_q <= use_slot[2] && !border2 && !slot_err[2];
				s3_need_q <= use_slot[3] && !border2 && 1'b0 ? 1'b0 : (use_slot[3] && !border3 && !slot_err[3]);
				st <= LANE_CHECK;
			end
			LANE_CHECK: begin
				if (any_miss) begin
					drop <= inv_b[17];
					st <= MREQ;
				end else begin
					st <= LANE_WAIT;
				end
			end
			LANE_WAIT: begin
				st <= LANE_FETCH;
			end
			LANE_FETCH: begin
				st <= LANE_EXTRACT;
			end
			LANE_EXTRACT: begin
				slot_err <= 4'd0;
				if (no_more_lanes)
					st <= OUT;
				else begin
					lane <= nxt_lane;
					cur_bord0 <= tc_bord[{nxt_lane, 2'b00}];
					cur_bord1 <= tc_bord[{nxt_lane, 2'b01}];
					cur_bord2 <= tc_bord[{nxt_lane, 2'b10}];
					cur_bord3 <= tc_bord[{nxt_lane, 2'b11}];
					cur_mask <= tc_mask[nxt_lane];
					st <= LANE_TAG_RD;
				end
			end
			MREQ: begin
				if (req_ready)
					st <= MWAIT;
			end
			MWAIT: begin
				if (mwait_err_a)
					slot_err <= slot_err | err_match_q;
				if (mwait_ok_we0) begin
					b0_we_q <= {NS{1'b1}};
					b1_we_q <= {NS{1'b1}};
				end
				if (mwait_ok_we1) begin
					b2_we_q <= {NS{1'b1}};
					b3_we_q <= {NS{1'b1}};
				end
				if (mwait_ok_we2) begin
					for (j = 0; j < WAYS; j = j + 1) begin
						tag_we_s01_q[j] <= (fill_way_q == j[1:0]);
						tag_we_s23_q[j] <= (fill_way_q == j[1:0]);
					end
				end
				if (mwait_err_b) begin
					/* Error region: texel stays 0, mark slot */
					st <= LANE_TAG_RD;
				end else if (mwait_ok_st) begin
					st <= MW_WRITE;
				end
			end
			MW_WRITE: begin
				b0_we_q <= {NS{1'b0}};
				b1_we_q <= {NS{1'b0}};
				b2_we_q <= {NS{1'b0}};
				b3_we_q <= {NS{1'b0}};
				tag_we_s01_q <= {WAYS{1'b0}};
				tag_we_s23_q <= {WAYS{1'b0}};
				st <= LANE_TAG_RD;
			end
			OUT: if (tc_ready) begin
				st <= IDLE;
			end
			default: st <= IDLE;
			endcase

			if (inv_b[16]) begin
				s0_vld_q <= {WAYS{1'b0}};
				s1_vld_q <= {WAYS{1'b0}};
				s2_vld_q <= {WAYS{1'b0}};
				s3_vld_q <= {WAYS{1'b0}};
			end
			if (inv_b[17]) begin
				s0_hit_w_q <= {WAYS{1'b0}};
				s1_hit_w_q <= {WAYS{1'b0}};
				s2_hit_w_q <= {WAYS{1'b0}};
				s3_hit_w_q <= {WAYS{1'b0}};
				drop <= 1'b1;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, nxt_lane_co_unused, idle_meta_ce[8],
	                   miss_slot, a0[ADDR_W-1:LINE_SHIFT], lsl, (NBANKS != 0)};
endmodule

`default_nettype wire
