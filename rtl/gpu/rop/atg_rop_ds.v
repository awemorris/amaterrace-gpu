/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_ds: ROP depth and stencil: reads the depth/stencil line of the
 * quad (DS_BASE/STRIDE, D32F or D24S8), tests (DEPTH func, STENCIL_*
 * front/back), updates and writes it back, and passes the surviving lanes.
 *
 * Each (lane, sample) entry is tested by atg_rop_dtest (CAPS[30]: depth
 * bounds, the stencil test and ops with the quad's facing, the depth test
 * of D16, D24S8 and D32F; the written bytes from its byte enables).  One
 * quad at a time: per row with covered lanes, read the line, test its
 * entries, write the changed bytes and wait for the write's response, so
 * the next quad reads what this one wrote.  D16 pixels are 2 bytes (sample
 * s of pixel x at byte 2 (S x + s) of the row), the others 4.  Quads with no lane are dropped.  The direct
 * path's quads (q_dbg) get DEBUG_COLOR as fp32 c/255.
 *
 * Multisampling (MS_CTRL[3:0] = 2, docs/ghci.md section 12.11): the
 * samples of a pixel are consecutive words (sample s of pixel x at word
 * 4 x + s of the row), so a quad's row is one line still; the test runs
 * per sample of the row's lanes (8 entries; 2 with one sample), each with
 * its own depth (q_sdepth), and the surviving samples go on (d_smask).
 * Beats (CAPS[30]): a quad comes as one beat per colour attachment
 * (q_beat = {rt, nocol, first}); the first beat is tested and written,
 * the later ones go on with its surviving samples without a memory access
 * (dropped with it).  A beat without colour goes on too (atg_rop counts
 * the first beats' samples for occlusion queries; atg_rop_wb drops it).
 * See spec/gpu/rop/atg_rop_ds.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_rop_ds #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter STENCIL = 0	/* Stencil present (ROP_STENCIL) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rop_order */
	input wire q_valid,
	output wire q_ready,
	input wire [31:0] q_xy,
	input wire [15:0] q_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] q_color,
	input wire [511:0] q_color1,
	input wire [511:0] q_sdepth,	/* sample s of lane l at 32 (4 l + s) */
	input wire q_dbg,
	input wire q_front,	/* front facing (CAPS[30]; the direct path: 1) */
	input wire [4:0] q_beat,	/* {rt[2:0], nocol, first} */
	/* To atg_rop_wb */
	output reg d_valid,
	input wire d_ready,
	(* max_fanout = 8 *) output reg [31:0] d_xy,
	output reg [15:0] d_smask,
	output reg [511:0] d_color,
	output reg [511:0] d_color1,
	output reg [4:0] d_beat,
	output wire busy,
	/* AMB client port (design §4.1) */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output reg [LINE_BYTES-1:0] req_be,
	output reg [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "atg_rop_unorm8.vh"
	`include "ghci_regs.vh"

	(* keep = "true", dont_touch = "true" *) wire rst_sync = !rst_n;

	/* Distributed ROM for unorm8 conversion to avoid BRAM inference */
	(* rom_style = "distributed" *) reg [31:0] rom_unorm8 [0:255];
	integer r_u8_i;
	initial begin
		for (r_u8_i = 0; r_u8_i < 256; r_u8_i = r_u8_i + 1)
			rom_unorm8[r_u8_i] = atg_rop_unorm8(r_u8_i[7:0]);
	end

	localparam WPL = LINE_BYTES / 4;	/* words per line */
	localparam WB = LINE_SHIFT - 2;	/* word index bits */
	integer k;

	/* STATE: DEBUG_COLOR 0x05C, DS_BASE 0x074, DS_STRIDE 0x075, DEPTH 0x076,
	 * STENCIL_FRONT, _OPS, _BACK 0x077-0x079, DEPTH_BOUNDS_MIN, _MAX 0x08B,
	 * 0x08C. */
	(* keep = "true", dont_touch = "true" *) reg [31:0] dbg_color_lo, dbg_color_hi;
	reg [31:0] ds_base, bmin, bmax;
	(* keep = "true", dont_touch = "true" *) reg [31:0] ds_stride_mul, ds_stride_add;
	reg [9:0] depth;
	(* keep = "true", dont_touch = "true" *) reg [7:0] depth_d24_rep;
	reg d16_r;
	reg [26:0] sfront, sback;
	reg [24:0] sops;
	(* keep = "true", dont_touch = "true" *) reg [2:0] ms4_rep;

`ifdef SYNTH_KINTEX7
	wire we_sfront_raw = st_we && (st_idx == GHCI_S_STENCIL_FRONT);
	wire we_sback_raw  = st_we && (st_idx == GHCI_S_STENCIL_BACK);
	wire we_sops_raw   = st_we && (st_idx == GHCI_S_STENCIL_OPS);
	wire we_bmin_raw   = st_we && (st_idx == GHCI_S_DEPTH_BOUNDS_MIN);
	wire we_bmax_raw   = st_we && (st_idx == GHCI_S_DEPTH_BOUNDS_MAX);
	wire we_dbg_raw    = st_we && (st_idx == GHCI_S_DEBUG_COLOR);
	wire we_base_raw   = st_we && (st_idx == GHCI_S_DS_BASE);
	wire we_stride_raw = st_we && (st_idx == GHCI_S_DS_STRIDE);
	wire we_depth_raw  = st_we && (st_idx == GHCI_S_DEPTH);
	wire we_ms_raw     = st_we && (st_idx == GHCI_S_MS_CTRL);

	wire [1:0] we_sfront_b, we_sback_b, we_sops_b, we_bmin_b, we_bmax_b, we_base_b;
	wire [3:0] we_dbg_b, we_stride_b;
	wire we_depth_b, we_ms_b;
	wire [10:0] d16_buf;
	genvar g_st_b;
	generate
	for (g_st_b = 0; g_st_b < 2; g_st_b = g_st_b + 1) begin : g_st_we2
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sf (.I0(we_sfront_raw), .O(we_sfront_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb (.I0(we_sback_raw),  .O(we_sback_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_so (.I0(we_sops_raw),   .O(we_sops_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bn (.I0(we_bmin_raw),   .O(we_bmin_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bx (.I0(we_bmax_raw),   .O(we_bmax_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bs (.I0(we_base_raw),   .O(we_base_b[g_st_b]));
	end
	for (g_st_b = 0; g_st_b < 4; g_st_b = g_st_b + 1) begin : g_st_we4
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_db (.I0(we_dbg_raw),    .O(we_dbg_b[g_st_b]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_st (.I0(we_stride_raw), .O(we_stride_b[g_st_b]));
	end
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_dp (.I0(we_depth_raw), .O(we_depth_b));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ms (.I0(we_ms_raw),    .O(we_ms_b));
	for (g_st_b = 0; g_st_b < 11; g_st_b = g_st_b + 1) begin : g_d16_b
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_d16 (.I0(d16_r), .O(d16_buf[g_st_b]));
	end
	endgenerate

	always @(posedge clk) begin
		if (rst_sync) begin
			ms4_rep <= 3'd0;
			dbg_color_lo <= 32'd0;
			dbg_color_hi <= 32'd0;
			ds_base <= 32'd0;
			ds_stride_mul <= 32'd0;
			ds_stride_add <= 32'd0;
			depth <= 10'd0;
			depth_d24_rep <= 8'd0;
			d16_r <= 1'b0;
			sfront <= 27'd0;
			sback <= 27'd0;
			sops <= 25'd0;
			bmin <= 32'd0;
			bmax <= 32'd0;
		end else begin
			if (we_sfront_b[0]) sfront[13:0]  <= st_wdata[13:0];
			if (we_sfront_b[1]) sfront[26:14] <= st_wdata[26:14];
			if (we_sback_b[0])  sback[13:0]   <= st_wdata[13:0];
			if (we_sback_b[1])  sback[26:14]  <= st_wdata[26:14];
			if (we_sops_b[0])   sops[12:0]    <= st_wdata[12:0];
			if (we_sops_b[1])   sops[24:13]   <= st_wdata[24:13];
			if (we_bmin_b[0])   bmin[15:0]    <= st_wdata[15:0];
			if (we_bmin_b[1])   bmin[31:16]   <= st_wdata[31:16];
			if (we_bmax_b[0])   bmax[15:0]    <= st_wdata[15:0];
			if (we_bmax_b[1])   bmax[31:16]   <= st_wdata[31:16];
			if (we_dbg_b[0])    dbg_color_lo[15:0]  <= st_wdata[15:0];
			if (we_dbg_b[1])    dbg_color_lo[31:16] <= st_wdata[31:16];
			if (we_dbg_b[2])    dbg_color_hi[15:0]  <= st_wdata[15:0];
			if (we_dbg_b[3])    dbg_color_hi[31:16] <= st_wdata[31:16];
			if (we_base_b[0])   ds_base[15:0]  <= st_wdata[15:0];
			if (we_base_b[1])   ds_base[31:16] <= st_wdata[31:16];
			if (we_stride_b[0]) ds_stride_mul[15:0]  <= st_wdata[15:0];
			if (we_stride_b[1]) ds_stride_mul[31:16] <= st_wdata[31:16];
			if (we_stride_b[2]) ds_stride_add[15:0]  <= st_wdata[15:0];
			if (we_stride_b[3]) ds_stride_add[31:16] <= st_wdata[31:16];
			if (we_depth_b) begin
				depth <= st_wdata[9:0];
				depth_d24_rep <= {8{st_wdata[7:5] == 3'b001}};
				d16_r <= (st_wdata[7:5] == 3'b100);
			end
			if (we_ms_b)
				ms4_rep <= {3{st_wdata[3:0] == 4'd2}};
		end
	end
`else
	wire [10:0] d16_buf = {11{d16_r}};
	always @(posedge clk)
		if (rst_sync) begin
			ms4_rep <= 3'd0;
			dbg_color_lo <= 32'd0;
			dbg_color_hi <= 32'd0;
			ds_base <= 32'd0;
			ds_stride_mul <= 32'd0;
			ds_stride_add <= 32'd0;
			depth <= 10'd0;
			depth_d24_rep <= 8'd0;
			d16_r <= 1'b0;
			sfront <= 27'd0;
			sback <= 27'd0;
			sops <= 25'd0;
			bmin <= 32'd0;
			bmax <= 32'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_STENCIL_FRONT)
				sfront <= st_wdata[26:0];
			if (st_idx == GHCI_S_STENCIL_BACK)
				sback <= st_wdata[26:0];
			if (st_idx == GHCI_S_STENCIL_OPS)
				sops <= st_wdata[24:0];
			if (st_idx == GHCI_S_DEPTH_BOUNDS_MIN)
				bmin <= st_wdata;
			if (st_idx == GHCI_S_DEPTH_BOUNDS_MAX)
				bmax <= st_wdata;
			if (st_idx == GHCI_S_DEBUG_COLOR) begin
				dbg_color_lo <= st_wdata;
				dbg_color_hi <= st_wdata;
			end
			if (st_idx == GHCI_S_DS_BASE)
				ds_base <= st_wdata;
			if (st_idx == GHCI_S_DS_STRIDE) begin
				ds_stride_mul <= st_wdata;
				ds_stride_add <= st_wdata;
			end
			if (st_idx == GHCI_S_DEPTH) begin
				depth <= st_wdata[9:0];
				depth_d24_rep <= {8{st_wdata[7:5] == 3'b001}};
				d16_r <= st_wdata[7:5] == 3'b100;
			end
			if (st_idx == GHCI_S_MS_CTRL)
				ms4_rep <= {3{st_wdata[3:0] == 4'd2}};
		end
`endif
	/* a test reads the line: exactly one format, and a test enabled */
	wire one_fmt = depth[7:5] == 3'b001 || depth[7:5] == 3'b010 || d16_buf[4];
	wire test = one_fmt && (depth[0] || (depth[8] && depth[7:5] == 3'b001) || depth[9]);

	localparam [3:0] S_IDLE = 4'd0, S_ROW_SETUP = 4'd1, S_ROW = 4'd2, S_RD = 4'd3,
		S_TEST0 = 4'd4, S_TEST0A = 4'd13, S_TEST0B = 4'd10, S_TEST1 = 4'd5,
		S_TEST2 = 4'd6, S_TEST2B = 4'd14, S_TEST3 = 4'd7,
		S_WR = 4'd8, S_OUT = 4'd9, S_ROW_SETUP1 = 4'd11, S_ROW_SETUP2 = 4'd12;
	(* max_fanout = 16 *) reg [3:0] st;
	(* keep = "true", dont_touch = "true" *) reg [4:0] r_rep;	/* row */
	(* keep = "true", dont_touch = "true" *) reg [31:0] ds_xy_int;
	reg [2:0] e;	/* entry of the row: {lane of the row, sample} */
	reg wait_rsp;
	reg [15:0] mask, pm;
	reg [511:0] z;
	reg [31:0] addr;
	reg [LINE_BYTES*8-1:0] line;
	reg wr_any;
	(* keep = "true", dont_touch = "true" *) reg [4:0] front_rep;

	/* Pipelined per-entry test staging registers */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] test_stored;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] test_zl;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] test_zun;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [23:0] test_zu24;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] test_zu16;
	reg [32:0] test_zkey;
	reg [32:0] test_skey;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] test_s_inc;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] test_s_dec;
	(* keep = "true", dont_touch = "true" *) reg [LINE_SHIFT-1:0] test_bo_rep [0:3];
	reg [3:0] test_sb;
	(* keep = "true", dont_touch = "true" *) reg [3:0] test_mask_rep;
	reg test_pass;
	(* keep = "true", dont_touch = "true" *) reg [31:0] test_wword_rep [0:1];
	(* keep = "true", dont_touch = "true" *) reg [3:0] test_wbe_rep [0:3];

	(* keep = "true", dont_touch = "true" *) reg [31:0] row_base0, row_base0_rb1;
	reg [31:0] row_base1;

	wire [1:0] lane = {r_rep[4], e[2]};
	wire [3:0] sb = {lane, e[1:0]};	/* the sample's bit */
`ifdef SYNTH_KINTEX7
	wire [3:0] sb_buf [0:7];
	wire [31:0] zl;
	genvar g_sb;
	generate
	for (g_sb = 0; g_sb < 8; g_sb = g_sb + 1) begin : g_buf_sb
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb0 (.I0(sb[0]), .O(sb_buf[g_sb][0]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb1 (.I0(sb[1]), .O(sb_buf[g_sb][1]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb2 (.I0(sb[2]), .O(sb_buf[g_sb][2]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_sb3 (.I0(sb[3]), .O(sb_buf[g_sb][3]));
		assign zl[4 * g_sb +: 4] = z[32 * sb_buf[g_sb] + 4 * g_sb +: 4];
	end
	endgenerate
`else
	wire [31:0] zl = z[32 * sb +: 32];
`endif

	/* Stage 0A: Pre-shift subtractors for u24 and u16, and LZC for zun */
	wire [47:0] u24_p;
	wire [39:0] u16_p;
	wire u24_p_bo, u16_p_bo, u24_r_co, u16_r_co;
	am_sub #(.W(48)) u_u24_p (.a({1'b1, test_zl[22:0], 24'd0}), .b({24'd0, 1'b1, test_zl[22:0]}), .bi(1'b0), .d(u24_p),
		.bo(u24_p_bo));
	am_sub #(.W(40)) u_u16_p (.a({1'b1, test_zl[22:0], 16'd0}), .b({16'd0, 1'b1, test_zl[22:0]}), .bi(1'b0), .d(u16_p),
		.bo(u16_p_bo));

	/* Pure-LUT 5'd30 - test_zl[27:23] (0 CARRY4s, 1 LUT5 per bit) */
	function [4:0] sub30_5;
		input [4:0] b;
		begin
			case (b)
			5'd0:  sub30_5 = 5'd30; 5'd1:  sub30_5 = 5'd29; 5'd2:  sub30_5 = 5'd28; 5'd3:  sub30_5 = 5'd27;
			5'd4:  sub30_5 = 5'd26; 5'd5:  sub30_5 = 5'd25; 5'd6:  sub30_5 = 5'd24; 5'd7:  sub30_5 = 5'd23;
			5'd8:  sub30_5 = 5'd22; 5'd9:  sub30_5 = 5'd21; 5'd10: sub30_5 = 5'd20; 5'd11: sub30_5 = 5'd19;
			5'd12: sub30_5 = 5'd18; 5'd13: sub30_5 = 5'd17; 5'd14: sub30_5 = 5'd16; 5'd15: sub30_5 = 5'd15;
			5'd16: sub30_5 = 5'd14; 5'd17: sub30_5 = 5'd13; 5'd18: sub30_5 = 5'd12; 5'd19: sub30_5 = 5'd11;
			5'd20: sub30_5 = 5'd10; 5'd21: sub30_5 = 5'd9;  5'd22: sub30_5 = 5'd8;  5'd23: sub30_5 = 5'd7;
			5'd24: sub30_5 = 5'd6;  5'd25: sub30_5 = 5'd5;  5'd26: sub30_5 = 5'd4;  5'd27: sub30_5 = 5'd3;
			5'd28: sub30_5 = 5'd2;  5'd29: sub30_5 = 5'd1;  5'd30: sub30_5 = 5'd0;  default: sub30_5 = 5'd31;
			endcase
		end
	endfunction

	(* keep = "true" *) wire [3:0] zl_mnz;
	assign zl_mnz[0] = (test_zl[5:0]   != 6'd0);
	assign zl_mnz[1] = (test_zl[11:6]  != 6'd0);
	assign zl_mnz[2] = (test_zl[17:12] != 6'd0);
	assign zl_mnz[3] = (test_zl[22:18] != 5'd0);
	wire zl_mant_nz = |zl_mnz;
	wire zl_st_w = zl_mant_nz || (test_zl[30:23] != 8'd126);

	reg [47:0] u24_s0a_p;
	reg [39:0] u16_s0a_p;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [4:0] u24_s0a_t;
	reg zl_s0a_st;
	reg [71:0] zun_s0a_r;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [4:0] zun_s0a_lz;
	(* keep = "true", dont_touch = "true" *) reg [3:0] zun_s0a_found;

	wire [47:0] u24_sh;
	wire [39:0] u16_sh;
	am_shift #(.W(48), .SW(5)) u_u24_z (.a(u24_s0a_p), .amt(u24_s0a_t), .left(1'b0), .arith(1'b0), .y(u24_sh));
	am_shift #(.W(40), .SW(5)) u_u16_z (.a(u16_s0a_p), .amt(u24_s0a_t), .left(1'b0), .arith(1'b0), .y(u16_sh));

	reg [23:0] u24_stage0_hi;
	reg u24_stage0_round;
	(* keep = "true", dont_touch = "true" *) reg [2:0] u24_stage0_zero;
	(* keep = "true", dont_touch = "true" *) reg [2:0] u24_stage0_max;

	reg [15:0] u16_stage0_hi;
	reg u16_stage0_round;
	(* keep = "true", dont_touch = "true" *) reg [1:0] u16_stage0_zero;
	(* keep = "true", dont_touch = "true" *) reg [1:0] u16_stage0_max;

	wire [23:0] u24_r;
	am_add #(.W(24)) u_u24_r (.a(u24_stage0_hi), .b(24'd0), .ci(u24_stage0_round), .s(u24_r),
		.co(u24_r_co));
	wire [23:0] u24_final = {
		u24_stage0_zero[2] ? 8'd0 : u24_stage0_max[2] ? 8'hFF : u24_r[23:16],
		u24_stage0_zero[1] ? 8'd0 : u24_stage0_max[1] ? 8'hFF : u24_r[15:8],
		u24_stage0_zero[0] ? 8'd0 : u24_stage0_max[0] ? 8'hFF : u24_r[7:0]
	};

	wire [15:0] u16_r;
	am_add #(.W(16)) u_u16_r (.a(u16_stage0_hi), .b(16'd0), .ci(u16_stage0_round), .s(u16_r),
		.co(u16_r_co));
	wire [15:0] u16_final = {
		u16_stage0_zero[1] ? 8'd0 : u16_stage0_max[1] ? 8'hFF : u16_r[15:8],
		u16_stage0_zero[0] ? 8'd0 : u16_stage0_max[0] ? 8'hFF : u16_r[7:0]
	};

	/* Pipelined zun depth conversion (replicated depth_d24_rep[7:0] keeps fanout <= 10 per FF) */
	wire [79:0] zun_d24_pat = {test_stored[23:0], test_stored[23:0], test_stored[23:0], test_stored[23:16]};
	wire [79:0] zun_d16_pat = {5{test_stored[15:0]}};
	(* keep = "true" *) wire [79:0] zun_r = {
		depth_d24_rep[7] ? zun_d24_pat[79:70] : zun_d16_pat[79:70],
		depth_d24_rep[6] ? zun_d24_pat[69:60] : zun_d16_pat[69:60],
		depth_d24_rep[5] ? zun_d24_pat[59:50] : zun_d16_pat[59:50],
		depth_d24_rep[4] ? zun_d24_pat[49:40] : zun_d16_pat[49:40],
		depth_d24_rep[3] ? zun_d24_pat[39:30] : zun_d16_pat[39:30],
		depth_d24_rep[2] ? zun_d24_pat[29:20] : zun_d16_pat[29:20],
		depth_d24_rep[1] ? zun_d24_pat[19:10] : zun_d16_pat[19:10],
		depth_d24_rep[0] ? zun_d24_pat[9:0]   : zun_d16_pat[9:0]
	};
	reg [4:0] zun_lz;
	reg zun_found;
	always @(*) begin
		zun_found = 1'b1;
		casez (zun_r[79:56])
		24'b1???????????????????????: zun_lz = 5'd0;
		24'b01??????????????????????: zun_lz = 5'd1;
		24'b001?????????????????????: zun_lz = 5'd2;
		24'b0001????????????????????: zun_lz = 5'd3;
		24'b00001???????????????????: zun_lz = 5'd4;
		24'b000001??????????????????: zun_lz = 5'd5;
		24'b0000001?????????????????: zun_lz = 5'd6;
		24'b00000001????????????????: zun_lz = 5'd7;
		24'b000000001???????????????: zun_lz = 5'd8;
		24'b0000000001??????????????: zun_lz = 5'd9;
		24'b00000000001?????????????: zun_lz = 5'd10;
		24'b000000000001????????????: zun_lz = 5'd11;
		24'b0000000000001???????????: zun_lz = 5'd12;
		24'b00000000000001??????????: zun_lz = 5'd13;
		24'b000000000000001?????????: zun_lz = 5'd14;
		24'b0000000000000001????????: zun_lz = 5'd15;
		24'b00000000000000001???????: zun_lz = 5'd16;
		24'b000000000000000001??????: zun_lz = 5'd17;
		24'b0000000000000000001?????: zun_lz = 5'd18;
		24'b00000000000000000001????: zun_lz = 5'd19;
		24'b000000000000000000001???: zun_lz = 5'd20;
		24'b0000000000000000000001??: zun_lz = 5'd21;
		24'b00000000000000000000001?: zun_lz = 5'd22;
		24'b000000000000000000000001: zun_lz = 5'd23;
		default: begin
			zun_lz = 5'd0;
			zun_found = 1'b0;
		end
		endcase
	end

	wire [71:0] zun_mn;
	am_shift #(.W(72), .SW(5)) u_zun_mn (.a(zun_s0a_r), .amt(zun_s0a_lz), .left(1'b1), .arith(1'b0), .y(zun_mn));

	/* Pure-LUT 8'd126 - lz and 8'd127 - lz for 5-bit lz (0 CARRY4s) */
	function [7:0] sub126_5;
		input [4:0] lz;
		begin
			case (lz)
			5'd0:  sub126_5 = 8'd126; 5'd1:  sub126_5 = 8'd125; 5'd2:  sub126_5 = 8'd124; 5'd3:  sub126_5 = 8'd123;
			5'd4:  sub126_5 = 8'd122; 5'd5:  sub126_5 = 8'd121; 5'd6:  sub126_5 = 8'd120; 5'd7:  sub126_5 = 8'd119;
			5'd8:  sub126_5 = 8'd118; 5'd9:  sub126_5 = 8'd117; 5'd10: sub126_5 = 8'd116; 5'd11: sub126_5 = 8'd115;
			5'd12: sub126_5 = 8'd114; 5'd13: sub126_5 = 8'd113; 5'd14: sub126_5 = 8'd112; 5'd15: sub126_5 = 8'd111;
			5'd16: sub126_5 = 8'd110; 5'd17: sub126_5 = 8'd109; 5'd18: sub126_5 = 8'd108; 5'd19: sub126_5 = 8'd107;
			5'd20: sub126_5 = 8'd106; 5'd21: sub126_5 = 8'd105; 5'd22: sub126_5 = 8'd104; 5'd23: sub126_5 = 8'd103;
			default: sub126_5 = 8'd102;
			endcase
		end
	endfunction

	reg [22:0] zun_s0_mn_hi;
	reg zun_s0_round;
	reg [7:0] zun_s0_e0, zun_s0_e1;
	(* keep = "true", dont_touch = "true" *) reg [3:0] zun_s0_found;

	wire [23:0] zun_q;
	wire zun_carry_unused;
	am_add #(.W(24)) u_zun_q (.a({1'b0, zun_s0_mn_hi}), .b(24'd0), .ci(zun_s0_round), .s(zun_q), .co(zun_carry_unused));
`ifdef SYNTH_KINTEX7
	wire [3:0] zun_q23_b;
	LUT1 #(.INIT(2'h2)) u_zq23_0 (.I0(zun_q[23]), .O(zun_q23_b[0]));
	LUT1 #(.INIT(2'h2)) u_zq23_1 (.I0(zun_q[23]), .O(zun_q23_b[1]));
	LUT1 #(.INIT(2'h2)) u_zq23_2 (.I0(zun_q[23]), .O(zun_q23_b[2]));
	LUT1 #(.INIT(2'h2)) u_zq23_3 (.I0(zun_q[23]), .O(zun_q23_b[3]));
`else
	wire [3:0] zun_q23_b = {4{zun_q[23]}};
`endif
	wire [7:0] zun_e = zun_q23_b[3] ? zun_s0_e1 : zun_s0_e0;
	wire [22:0] zun_m = {
		zun_q23_b[2] ? 7'd0 : zun_q[22:16],
		zun_q23_b[1] ? 8'd0 : zun_q[15:8],
		zun_q23_b[0] ? 8'd0 : zun_q[7:0]
	};
	wire [31:0] zun_final = {
		!zun_s0_found[3] ? 8'd0 : {1'b0, zun_e[7:1]},
		!zun_s0_found[2] ? 8'd0 : {zun_e[0], zun_m[22:16]},
		!zun_s0_found[1] ? 8'd0 : zun_m[15:8],
		!zun_s0_found[0] ? 8'd0 : zun_m[7:0]
	};

	/* the entry's byte in the line: (S x + s) ps from the row's address */
	wire [2:0] ent = ms4_rep[2] ? e : {2'b00, e[2]};
	wire [LINE_SHIFT-1:0] bo;
	wire bo_co_unused;
	am_add #(.W(LINE_SHIFT)) u_bo (.a(addr[LINE_SHIFT-1:0]),
		.b(d16_buf[4] ? {{(LINE_SHIFT-4){1'b0}}, ent, 1'b0} : {{(LINE_SHIFT-5){1'b0}}, ent, 2'b00}),
		.ci(1'b0), .s(bo), .co(bo_co_unused));
	/* The row's address: base + (y + r) stride + x S ps; the next entry. */
	wire [16:0] yr;
	wire [48:0] yrs;
	wire [15:0] xo_lo = ms4_rep[0] ? (d16_buf[5] ? {ds_xy_int[12:0], 3'b000} : {ds_xy_int[11:0], 4'b0000}) :
		(d16_buf[5] ? {ds_xy_int[14:0], 1'b0} : {ds_xy_int[13:0], 2'b00});
	wire [15:0] xo_hi = ms4_rep[1] ? (d16_buf[5] ? {13'd0, ds_xy_int[15:13]} : {12'd0, ds_xy_int[15:12]}) :
		(d16_buf[5] ? {15'd0, ds_xy_int[15]} : {14'd0, ds_xy_int[15:14]});
	wire [31:0] xo = {xo_hi, xo_lo};
	wire [31:0] row_a, row_base1_comb, cur_row_base, row_addr;
	wire [2:0] e_next = ms4_rep[2] ? {e[2] ^ (e[1] & e[0]), e[1] ^ e[0], ~e[0]} : {~e[2], e[1:0]};
	wire yr_co_unused, ra_co_unused, rb1_co_unused, rd_co_unused;
	am_add #(.W(17)) u_yr (.a({1'b0, (st == S_IDLE) ? q_xy[31:16] : ds_xy_int[31:16]}), .b(17'd0), .ci(1'b0), .s(yr), .co(yr_co_unused));
	am_mul #(.AW(17), .BW(32), .LAT(2)) u_yrs (.clk(clk), .en(1'b1), .a(yr), .b(ds_stride_mul), .p(yrs));
	am_add #(.W(32)) u_ra (.a(ds_base), .b(yrs[31:0]), .ci(1'b0), .s(row_a), .co(ra_co_unused));
	am_add #(.W(32)) u_rb1 (.a(row_base0_rb1), .b(ds_stride_add), .ci(1'b0), .s(row_base1_comb), .co(rb1_co_unused));
	assign cur_row_base = {
		r_rep[3] ? row_base1[31:24] : row_base0[31:24],
		r_rep[2] ? row_base1[23:16] : row_base0[23:16],
		r_rep[1] ? row_base1[15:8]  : row_base0[15:8],
		r_rep[0] ? row_base1[7:0]   : row_base0[7:0]
	};
	am_add #(.W(32)) u_rd (.a(cur_row_base), .b(xo), .ci(1'b0), .s(row_addr), .co(rd_co_unused));
	/* The entry's 32-bit word of the line and its half (D16), with buffered bo to keep fanout <= 12 */
	wire [31:0] lword;
`ifdef SYNTH_KINTEX7
	wire [LINE_SHIFT-1:2] bo_w_buf [0:3];
	wire [1:0] bo_h_buf;
	genvar g_bo, g_bob;
	generate
	for (g_bo = 0; g_bo < 4; g_bo = g_bo + 1) begin : g_bow
		for (g_bob = 2; g_bob < LINE_SHIFT; g_bob = g_bob + 1) begin : g_bob_bit
			(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_bow (.I0(bo[g_bob]), .O(bo_w_buf[g_bo][g_bob]));
		end
		assign lword[8 * g_bo +: 8] = line[32 * bo_w_buf[g_bo] + 8 * g_bo +: 8];
	end
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_boh0 (.I0(bo[1]), .O(bo_h_buf[0]));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_boh1 (.I0(bo[1]), .O(bo_h_buf[1]));
	endgenerate
	wire [15:0] stored_lo = {
		d16_buf[8] ? lword[16 * bo_h_buf[1] + 8 +: 8] : lword[15:8],
		d16_buf[6] ? lword[16 * bo_h_buf[0] +: 8]     : lword[7:0]
	};
`else
	assign lword = line[32 * bo[LINE_SHIFT-1:2] +: 32];
	wire [15:0] stored_lo = d16_buf[6] ? lword[16 * bo[1] +: 16] : lword[15:0];
`endif

	/* Pure-LUT keys and stencil +/-1 (0 CARRY4s on stencil, buffered zero-mask on depth keys) */
	wire [32:0] zkey_sm, skey_sm;
	wire zkey_co_unused, skey_co_unused;
	wire [2:0] zl_enz_buf, st_enz_buf;
	wire zl_exp_nz = (test_zl[30:23] != 8'd0);
	wire st_exp_nz = (test_stored[30:23] != 8'd0);
`ifdef SYNTH_KINTEX7
	genvar g_kz;
	generate
	for (g_kz = 0; g_kz < 3; g_kz = g_kz + 1) begin : g_key_enz
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_zenz (.I0(zl_exp_nz), .O(zl_enz_buf[g_kz]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_senz (.I0(st_exp_nz), .O(st_enz_buf[g_kz]));
	end
	endgenerate
`else
	assign zl_enz_buf = {3{zl_exp_nz}};
	assign st_enz_buf = {3{st_exp_nz}};
`endif
	am_addsub #(.W(33)) u_zkey_sm (.a(33'd0), .b({2'b00, test_zl[30:0]}), .sub(test_zl[31]), .s(zkey_sm), .co(zkey_co_unused));
	am_addsub #(.W(33)) u_skey_sm (.a(33'd0), .b({2'b00, test_stored[30:0]}), .sub(test_stored[31]), .s(skey_sm), .co(skey_co_unused));
	wire [32:0] conv_zkey = {
		zl_enz_buf[2] ? zkey_sm[32:22] : 11'd0,
		zl_enz_buf[1] ? zkey_sm[21:11] : 11'd0,
		zl_enz_buf[0] ? zkey_sm[10:0]  : 11'd0
	};
	wire [32:0] conv_skey = {
		st_enz_buf[2] ? skey_sm[32:22] : 11'd0,
		st_enz_buf[1] ? skey_sm[21:11] : 11'd0,
		st_enz_buf[0] ? skey_sm[10:0]  : 11'd0
	};
	wire [7:0] conv_s_inc, conv_s_dec;
	wire sinc_co_unused, sdec_bo_unused;
	am_add #(.W(8)) u_s_inc (.a(test_stored[31:24]), .b(8'd1), .ci(1'b0), .s(conv_s_inc), .co(sinc_co_unused));
	am_sub #(.W(8)) u_s_dec (.a(test_stored[31:24]), .b(8'd1), .bi(1'b0), .d(conv_s_dec), .bo(sdec_bo_unused));

	/* 2-stage pure-LUT depth/stencil evaluation (S_TEST2 -> S_TEST2B, 0 CARRY4s, <= 4 LUTs/stage) */
`ifdef MUT_STENCIL_FACE
	wire [4:0] face_sel = ~front_rep;
`else
	wire [4:0] face_sel = front_rep;
`endif
	(* keep = "true", dont_touch = "true" *) reg [7:0] face_ss_ref, face_cm, face_wm;
	(* keep = "true", dont_touch = "true" *) reg [2:0] face_ss_fn;
	(* keep = "true", dont_touch = "true" *) reg [8:0] face_so_lo, face_so_hi;
	always @(posedge clk) begin
		face_ss_ref <= face_sel[0] ? sfront[7:0]   : sback[7:0];
		face_cm     <= face_sel[1] ? sfront[15:8]  : sback[15:8];
		face_ss_fn  <= face_sel[1] ? sfront[26:24] : sback[26:24];
		face_so_lo  <= face_sel[2] ? sops[8:0]     : sops[24:16];
		face_so_hi  <= face_sel[3] ? sops[8:0]     : sops[24:16];
		face_wm     <= face_sel[4] ? sfront[23:16] : sback[23:16];
	end

	wire s2_bmin_st_w, s2_bmax_st_w, s2_bmin_zun_w, s2_bmax_zun_w;
	wire s2_lt_32_w, s2_eq_32_w, s2_nan_w, s2_lt_24_w, s2_eq_24_w, s2_lt_16_w, s2_eq_16_w;
	wire s2_s_cmp_w, s2_sch_f_w, s2_sch_dp_w, s2_sch_df_w;
	wire [7:0] s2_swr_f_w, s2_swr_dp_w, s2_swr_df_w;
	atg_rop_ds_eval_s2a u_eval_s2a (
		.ss_ref(face_ss_ref),
		.cm(face_cm),
		.ss_fn(face_ss_fn),
		.so_lo(face_so_lo),
		.so_hi(face_so_hi),
		.wm(face_wm),
		.bmin(bmin),
		.bmax(bmax),
		.zf(test_zl),
		.stored(test_stored),
		.zun(test_zun),
		.zu24(test_zu24),
		.zu16(test_zu16),
		.zkey(test_zkey),
		.skey(test_skey),
		.s_inc(test_s_inc),
		.s_dec(test_s_dec),
		.bmin_st(s2_bmin_st_w),
		.bmax_st(s2_bmax_st_w),
		.bmin_zun(s2_bmin_zun_w),
		.bmax_zun(s2_bmax_zun_w),
		.lt_32(s2_lt_32_w),
		.eq_32(s2_eq_32_w),
		.nan_32(s2_nan_w),
		.lt_24(s2_lt_24_w),
		.eq_24(s2_eq_24_w),
		.lt_16(s2_lt_16_w),
		.eq_16(s2_eq_16_w),
		.s_cmp(s2_s_cmp_w),
		.swr_fail(s2_swr_f_w),
		.swr_dpass(s2_swr_dp_w),
		.swr_dfail(s2_swr_df_w),
		.sch_fail(s2_sch_f_w),
		.sch_dpass(s2_sch_dp_w),
		.sch_dfail(s2_sch_df_w)
	);

	reg s2_bmin_st, s2_bmax_st, s2_bmin_zun, s2_bmax_zun;
	reg s2_lt_32, s2_eq_32, s2_nan, s2_lt_24, s2_eq_24, s2_lt_16, s2_eq_16;
	reg s2_s_cmp, s2_sch_f, s2_sch_dp, s2_sch_df;
	reg [7:0] s2_swr_f, s2_swr_dp, s2_swr_df;
	reg [31:0] s2_zf;
	reg [23:0] s2_zu24;
	reg [15:0] s2_zu16;

	wire eval_pass;
	wire [31:0] eval_wword;
	wire [3:0] eval_wbe;
	atg_rop_ds_eval_s2b u_eval_s2b (
		.depth(depth),
		.zf(s2_zf),
		.zu24(s2_zu24),
		.zu16(s2_zu16),
		.bmin_st(s2_bmin_st),
		.bmax_st(s2_bmax_st),
		.bmin_zun(s2_bmin_zun),
		.bmax_zun(s2_bmax_zun),
		.lt_32(s2_lt_32),
		.eq_32(s2_eq_32),
		.nan_32(s2_nan),
		.lt_24(s2_lt_24),
		.eq_24(s2_eq_24),
		.lt_16(s2_lt_16),
		.eq_16(s2_eq_16),
		.s_cmp(s2_s_cmp),
		.swr_fail(s2_swr_f),
		.swr_dpass(s2_swr_dp),
		.swr_dfail(s2_swr_df),
		.sch_fail(s2_sch_f),
		.sch_dpass(s2_sch_dp),
		.sch_dfail(s2_sch_df),
		.pass(eval_pass),
		.wword(eval_wword),
		.wbe(eval_wbe)
	);

	/* Registered debug color expansion (fanout of dbg_color_lo/hi <= 16, fanout of dbgf_r <= 4) */
	wire [31:0] dbgf_ch3_lo = rom_unorm8[dbg_color_lo[31:24]];
	wire [31:0] dbgf_ch3_hi = rom_unorm8[dbg_color_hi[31:24]];
	wire [31:0] dbgf_ch2_lo = rom_unorm8[dbg_color_lo[23:16]];
	wire [31:0] dbgf_ch2_hi = rom_unorm8[dbg_color_hi[23:16]];
	wire [31:0] dbgf_ch1_lo = rom_unorm8[dbg_color_lo[15:8]];
	wire [31:0] dbgf_ch1_hi = rom_unorm8[dbg_color_hi[15:8]];
	wire [31:0] dbgf_ch0_lo = rom_unorm8[dbg_color_lo[7:0]];
	wire [31:0] dbgf_ch0_hi = rom_unorm8[dbg_color_hi[7:0]];
	(* keep = "true", dont_touch = "true" *) reg [127:0] dbgf_r;
	always @(posedge clk) begin
		dbgf_r <= {
			dbgf_ch3_hi[31:16], dbgf_ch3_lo[15:0],
			dbgf_ch2_hi[31:16], dbgf_ch2_lo[15:0],
			dbgf_ch1_hi[31:16], dbgf_ch1_lo[15:0],
			dbgf_ch0_hi[31:16], dbgf_ch0_lo[15:0]
		};
	end

	assign q_ready = st == S_IDLE;
	assign busy = st != S_IDLE || d_valid;
	assign req_tag = 8'd0;

	localparam integer N_L16 = LINE_BYTES / 2;
	wire is_s_test3 = (st == S_TEST3);

	/* Per-byte write enable in S_TEST3 using replicated test_bo_rep, test_wbe_rep, test_mask_rep, d16_buf */
	(* keep = "true" *) wire [LINE_BYTES-1:0] s3_byte_we;
	genvar gk;
	generate
	for (gk = 0; gk < LINE_BYTES; gk = gk + 1) begin : g_s3_bwe
		localparam integer G_Q = (gk * 4) / LINE_BYTES;
		wire [LINE_SHIFT-1:0] bo_q = test_bo_rep[G_Q];
		wire [3:0] wbe_q = test_wbe_rep[G_Q];
		wire m_q = test_mask_rep[G_Q];
		wire d16_q = d16_buf[G_Q];
		wire [LINE_SHIFT-1:2] k_w = gk[LINE_SHIFT-1:2];
		wire k_h = gk[1];
		wire [1:0] b_idx = d16_q ? {1'b0, gk[0]} : gk[1:0];
		assign s3_byte_we[gk] = is_s_test3 && m_q && (k_w == bo_q[LINE_SHIFT-1:2]) &&
			(!d16_q || (k_h == bo_q[1])) && wbe_q[b_idx];
	end
	endgenerate

	wire en_row_addr = (st == S_ROW) && (mask[8 * r_rep[4] +: 8] != 8'd0);
	wire en_req_line = (st == S_RD) && !wait_rsp && !req_valid;
	wire [1:0] en_addr_buf, en_rline_buf;

`ifdef SYNTH_KINTEX7
	wire en_idle_qv = (st == S_IDLE) && q_valid;
	wire en_idle_qf = en_idle_qv && q_beat[0];
	wire en_rd_rsp = (st == S_RD) && wait_rsp && rsp_valid;
	wire [4:0] en_col_mid;
	wire [67:0] en_col_leaf;
	wire [2:0] en_qf_mid;
	wire [32:0] en_qf_leaf;
	wire [1:0] en_rd_mid;
	wire [N_L16-1:0] en_rd_leaf;
	wire [31:0] q_dbg_leaf;
	wire [1:0] q_dbg_mid;
	wire [LINE_BYTES-1:0] s3_bwe_leaf;
	genvar g_cm, g_cl, g_cq;
	generate
	for (g_cm = 0; g_cm < 2; g_cm = g_cm + 1) begin : g_buf_ar
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_adr (.I0(en_row_addr), .O(en_addr_buf[g_cm]));
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_rln (.I0(en_req_line), .O(en_rline_buf[g_cm]));
	end
	for (g_cm = 0; g_cm < 5; g_cm = g_cm + 1) begin : g_mid_col
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mcol (
			.I0(en_idle_qv), .O(en_col_mid[g_cm])
		);
	end
	for (g_cl = 0; g_cl < 68; g_cl = g_cl + 1) begin : g_leaf_col
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lcol (
			.I0(en_col_mid[g_cl / 14]), .O(en_col_leaf[g_cl])
		);
	end
	for (g_cm = 0; g_cm < 2; g_cm = g_cm + 1) begin : g_mid_dbg
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mdbg (
			.I0(q_dbg), .O(q_dbg_mid[g_cm])
		);
	end
	for (g_cl = 0; g_cl < 32; g_cl = g_cl + 1) begin : g_leaf_dbg
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_ldbg (
			.I0(q_dbg_mid[g_cl / 16]), .O(q_dbg_leaf[g_cl])
		);
	end
	wire [511:0] dbg_quad_col = {4{dbgf_r}};
	for (g_cq = 0; g_cq < 32; g_cq = g_cq + 1) begin : g_reg_dcol
		always @(posedge clk) begin
			if (en_col_leaf[g_cq])
				d_color[16 * g_cq +: 16] <= q_dbg_leaf[g_cq] ?
					dbg_quad_col[16 * g_cq +: 16] : q_color[16 * g_cq +: 16];
		end
		always @(posedge clk) begin
			if (rst_sync)
				d_color1[16 * g_cq +: 16] <= 16'd0;
			else if (en_col_leaf[32 + g_cq])
				d_color1[16 * g_cq +: 16] <= q_color1[16 * g_cq +: 16];
		end
	end
	for (g_cq = 0; g_cq < 2; g_cq = g_cq + 1) begin : g_reg_dxy
		always @(posedge clk) begin
			if (en_col_leaf[64 + g_cq])
				d_xy[16 * g_cq +: 16] <= q_xy[16 * g_cq +: 16];
			if (en_col_leaf[66 + g_cq])
				ds_xy_int[16 * g_cq +: 16] <= q_xy[16 * g_cq +: 16];
		end
	end

	/* Buffer en_idle_qf for z[511:0], mask[15:0] */
	for (g_cm = 0; g_cm < 3; g_cm = g_cm + 1) begin : g_mid_qf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mqf (
			.I0(en_idle_qf), .O(en_qf_mid[g_cm])
		);
	end
	for (g_cl = 0; g_cl < 33; g_cl = g_cl + 1) begin : g_leaf_qf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lqf (
			.I0(en_qf_mid[g_cl / 11]), .O(en_qf_leaf[g_cl])
		);
	end
	for (g_cq = 0; g_cq < 32; g_cq = g_cq + 1) begin : g_reg_z
		always @(posedge clk) begin
			if (en_qf_leaf[g_cq])
				z[16 * g_cq +: 16] <= q_sdepth[16 * g_cq +: 16];
		end
	end
	always @(posedge clk) begin
		if (en_qf_leaf[32])
			mask <= q_smask;
	end

	/* Buffer en_rd_rsp for line and req_be */
	for (g_cm = 0; g_cm < 2; g_cm = g_cm + 1) begin : g_mid_rd
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_mrd (
			.I0(en_rd_rsp), .O(en_rd_mid[g_cm])
		);
	end
	for (g_cl = 0; g_cl < N_L16; g_cl = g_cl + 1) begin : g_leaf_rd
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_lrd (
			.I0(en_rd_mid[g_cl / (N_L16 / 2)]), .O(en_rd_leaf[g_cl])
		);
	end
	for (g_cq = 0; g_cq < N_L16; g_cq = g_cq + 1) begin : g_reg_line
		always @(posedge clk) begin
			if (en_rd_leaf[g_cq]) begin
				line[16 * g_cq +: 16] <= rsp_rdata[16 * g_cq +: 16];
				req_be[2 * g_cq +: 2] <= 2'b00;
			end else begin
				if (s3_bwe_leaf[2 * g_cq])
					req_be[2 * g_cq] <= 1'b1;
				if (s3_bwe_leaf[2 * g_cq + 1])
					req_be[2 * g_cq + 1] <= 1'b1;
			end
		end
	end

	for (g_cl = 0; g_cl < LINE_BYTES; g_cl = g_cl + 1) begin : g_s3_buf
		(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_s3b (.I0(s3_byte_we[g_cl]), .O(s3_bwe_leaf[g_cl]));
	end
	endgenerate
`else
	assign en_addr_buf = {2{en_row_addr}};
	assign en_rline_buf = {2{en_req_line}};
	wire [LINE_BYTES-1:0] s3_bwe_leaf = s3_byte_we;
`endif

	wire u24_zero_w = (test_zl[30:23] == 8'd0) || test_zl[31] ||
	                  (test_zl[30:23] == 8'hFF && zl_mant_nz) || (test_zl[30:23] < 8'd102);
	wire u16_zero_w = (test_zl[30:23] == 8'd0) || test_zl[31] ||
	                  (test_zl[30:23] == 8'hFF && zl_mant_nz) || (test_zl[30:23] < 8'd103);
	wire u_max_w = (test_zl[30:23] >= 8'd127);
	wire [31:0] eval_wword_pre = d16_buf[7] ? {eval_wword[15:0], eval_wword[15:0]} : eval_wword;

	/* Free-running datapath registers for row base setup and S_TEST0..S_TEST2B pipeline */
	always @(posedge clk) begin
		row_base0 <= row_a;
		row_base0_rb1 <= row_a;
		row_base1 <= row_base1_comb;

		if (en_addr_buf[0]) addr[15:0]  <= row_addr[15:0];
		if (en_addr_buf[1]) addr[31:16] <= row_addr[31:16];
		if (en_rline_buf[0]) req_line[13:0] <= addr[LINE_SHIFT + 13 : LINE_SHIFT];
		if (en_rline_buf[1]) req_line[ADDR_W - LINE_SHIFT - 1 : 14] <= addr[ADDR_W - 1 : LINE_SHIFT + 14];

		/* S_TEST0 latches (inputs stationary throughout S_TEST0..S_TEST3) */
		test_stored[15:0] <= stored_lo;
		if (d16_buf[9])
			test_stored[23:16] <= 8'd0;
		else
			test_stored[23:16] <= lword[23:16];
		if (d16_buf[10])
			test_stored[31:24] <= 8'd0;
		else
			test_stored[31:24] <= lword[31:24];
		test_zl <= zl;
		test_bo_rep[0] <= bo;
		test_bo_rep[1] <= bo;
		test_bo_rep[2] <= bo;
		test_bo_rep[3] <= bo;
		test_sb <= sb;
		test_mask_rep <= {4{mask[sb]}};

		/* S_TEST0A latches */
		u24_s0a_p <= u24_p;
		u16_s0a_p <= u16_p;
		u24_s0a_t <= sub30_5(test_zl[27:23]);
		zl_s0a_st <= zl_st_w;
		zun_s0a_r <= zun_r[79:8];
		zun_s0a_lz <= zun_lz;
		zun_s0a_found <= {4{zun_found}};

		/* S_TEST0B latches */
		u24_stage0_hi <= u24_sh[47:24];
		u24_stage0_round <= u24_sh[23] && (zl_s0a_st || u24_sh[24]);
		u24_stage0_zero <= {3{u24_zero_w}};
		u24_stage0_max <= {3{u_max_w}};
		u16_stage0_hi <= u16_sh[39:24];
		u16_stage0_round <= u16_sh[23] && (zl_s0a_st || u16_sh[24]);
		u16_stage0_zero <= {2{u16_zero_w}};
		u16_stage0_max <= {2{u_max_w}};
		zun_s0_round <= zun_mn[47];
		zun_s0_found <= zun_s0a_found;
		zun_s0_mn_hi <= zun_mn[70:48];
		zun_s0_e0 <= sub126_5(zun_s0a_lz);
		zun_s0_e1 <= {3'b011, ~zun_s0a_lz};

		/* S_TEST1 latches */
		test_zun <= zun_final;
		test_zu24 <= u24_final;
		test_zu16 <= u16_final;
		test_zkey <= conv_zkey;
		test_skey <= conv_skey;
		test_s_inc <= conv_s_inc;
		test_s_dec <= conv_s_dec;

		/* S_TEST2 latches */
		s2_bmin_st  <= s2_bmin_st_w;
		s2_bmax_st  <= s2_bmax_st_w;
		s2_bmin_zun <= s2_bmin_zun_w;
		s2_bmax_zun <= s2_bmax_zun_w;
		s2_lt_32    <= s2_lt_32_w;
		s2_eq_32    <= s2_eq_32_w;
		s2_nan      <= s2_nan_w;
		s2_lt_24    <= s2_lt_24_w;
		s2_eq_24    <= s2_eq_24_w;
		s2_lt_16    <= s2_lt_16_w;
		s2_eq_16    <= s2_eq_16_w;
		s2_s_cmp    <= s2_s_cmp_w;
		s2_swr_f    <= s2_swr_f_w;
		s2_swr_dp   <= s2_swr_dp_w;
		s2_swr_df   <= s2_swr_df_w;
		s2_sch_f    <= s2_sch_f_w;
		s2_sch_dp   <= s2_sch_dp_w;
		s2_sch_df   <= s2_sch_df_w;
		s2_zf       <= test_zl;
		s2_zu24     <= test_zu24;
		s2_zu16     <= test_zu16;

		/* S_TEST2B latches */
		test_wword_rep[0] <= eval_wword_pre;
		test_wword_rep[1] <= eval_wword_pre;
		test_pass <= eval_pass;
		test_wbe_rep[0] <= eval_wbe;
		test_wbe_rep[1] <= eval_wbe;
		test_wbe_rep[2] <= eval_wbe;
		test_wbe_rep[3] <= eval_wbe;

		/* S_TEST3 byte writes (each s3_bwe_leaf[k] drives 8 data bits) */
		for (k = 0; k < LINE_BYTES; k = k + 1) begin
			if (s3_bwe_leaf[k])
				req_wdata[8 * k +: 8] <= test_wword_rep[(k * 2) / LINE_BYTES][8 * (k % 4) +: 8];
		end
	end

	/* Rule 1 fix: decouple st[2:1] from d_ready, and compute st[0], st[3], d_valid next-state
	 * via explicit single LUT4s on d_ready (so wb/cached_tag_x0/1 -> d_ready (3 LUTs) + 1 LUT = 4 LUTs) */
	reg [3:0] ds_st_next_nodr;
	always @(*) begin
		ds_st_next_nodr = st;
		case (st)
		S_IDLE: begin
			if (q_valid) begin
`ifdef MUT_DS_BEAT
				if (1'b0)
`else
				if (!q_beat[0])
`endif
					ds_st_next_nodr = S_OUT;
				else
					ds_st_next_nodr = (q_smask == 16'd0) ? S_IDLE : (test ? S_ROW_SETUP : S_OUT);
			end else begin
				ds_st_next_nodr = S_IDLE;
			end
		end
		S_ROW_SETUP:  ds_st_next_nodr = S_ROW_SETUP1;
		S_ROW_SETUP1: ds_st_next_nodr = S_ROW_SETUP2;
		S_ROW_SETUP2: ds_st_next_nodr = S_ROW;
		S_ROW: begin
			if (mask[8 * r_rep[4] +: 8] != 8'd0)
				ds_st_next_nodr = S_RD;
			else if (r_rep[4])
				ds_st_next_nodr = S_OUT;
			else
				ds_st_next_nodr = S_ROW;
		end
		S_RD:     ds_st_next_nodr = (wait_rsp && rsp_valid) ? S_TEST0 : S_RD;
		S_TEST0:  ds_st_next_nodr = S_TEST0A;
		S_TEST0A: ds_st_next_nodr = S_TEST0B;
		S_TEST0B: ds_st_next_nodr = S_TEST1;
		S_TEST1:  ds_st_next_nodr = S_TEST2;
		S_TEST2:  ds_st_next_nodr = S_TEST2B;
		S_TEST2B: ds_st_next_nodr = S_TEST3;
		S_TEST3:  ds_st_next_nodr = (e == (ms4_rep[2] ? 3'd7 : 3'd4)) ? S_WR : S_TEST0;
		S_WR: begin
			if (!wr_any || (wait_rsp && rsp_valid))
				ds_st_next_nodr = r_rep[4] ? S_OUT : S_ROW;
			else
				ds_st_next_nodr = S_WR;
		end
		default: /* S_OUT when !d_valid */
			ds_st_next_nodr = (pm == 16'd0) ? S_IDLE : S_OUT;
		endcase
	end

	(* keep = "true" *) wire ds_st0_base = !rst_sync && ds_st_next_nodr[0];
	(* keep = "true" *) wire ds_st3_base = !rst_sync && ds_st_next_nodr[3];
	(* keep = "true" *) wire ds_dval_set = !rst_sync && (st == S_OUT) && (pm != 16'd0);
	wire ds_st0_next, ds_st3_next, ds_dval_next;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT4 #(.INIT(16'h222E)) u_ds_st0 (
		.I0(ds_st0_base), .I1(d_valid), .I2(d_ready), .I3(rst_sync), .O(ds_st0_next)
	);
	(* keep = "true", dont_touch = "true" *) LUT4 #(.INIT(16'h222E)) u_ds_st3 (
		.I0(ds_st3_base), .I1(d_valid), .I2(d_ready), .I3(rst_sync), .O(ds_st3_next)
	);
	(* keep = "true", dont_touch = "true" *) LUT4 #(.INIT(16'h222E)) u_ds_dval (
		.I0(ds_dval_set), .I1(d_valid), .I2(d_ready), .I3(rst_sync), .O(ds_dval_next)
	);
`else
	assign ds_st0_next  = d_valid ? (!rst_sync && !d_ready) : ds_st0_base;
	assign ds_st3_next  = d_valid ? (!rst_sync && !d_ready) : ds_st3_base;
	assign ds_dval_next = d_valid ? (!rst_sync && !d_ready) : ds_dval_set;
`endif

	always @(posedge clk) begin
		st[0] <= ds_st0_next;
		st[3] <= ds_st3_next;
		if (rst_sync)
			st[2:1] <= 2'b00;
		else
			st[2:1] <= ds_st_next_nodr[2:1];
		d_valid <= ds_dval_next;
	end

	always @(posedge clk) begin
		if (rst_sync) begin
`ifndef SYNTH_KINTEX7
			d_color1 <= 512'd0;
`endif
			d_beat <= 5'd0;
			req_valid <= 1'b0;
			wait_rsp <= 1'b0;
			pm <= 16'd0;
			front_rep <= 5'd0;
			r_rep <= 5'd0;
		end else begin
`ifndef SYNTH_KINTEX7
			if (st == S_TEST3)
				req_be <= req_be | s3_bwe_leaf;
`endif
			case (st)
			S_IDLE:
				if (q_valid) begin
`ifndef SYNTH_KINTEX7
					d_xy <= q_xy;
					ds_xy_int <= q_xy;
					d_color <= q_dbg ? {4{dbgf_r}} : q_color;
					d_color1 <= q_color1;
`endif
					d_beat <= q_beat;
`ifdef MUT_DS_BEAT
					if (1'b1) begin
`else
					if (q_beat[0]) begin
`endif
`ifndef SYNTH_KINTEX7
						mask <= q_smask;
						z <= q_sdepth;
`endif
						pm <= q_smask;
						front_rep <= {5{q_front || q_dbg}};
						r_rep <= 5'd0;
					end
				end
			S_ROW_SETUP: begin end
			S_ROW_SETUP1: begin end
			S_ROW_SETUP2: begin end
			S_ROW:
				/* the row's address; skip a row without lanes */
				if (mask[8 * r_rep[4] +: 8] == 8'd0 && !r_rep[4])
					r_rep <= 5'h1F;
			S_RD:
				if (!wait_rsp) begin
					if (!req_valid) begin
						req_valid <= 1'b1;
						req_write <= 1'b0;
					end else if (req_ready) begin
						req_valid <= 1'b0;
						wait_rsp <= 1'b1;
					end
				end else if (rsp_valid) begin
					wait_rsp <= 1'b0;
`ifndef SYNTH_KINTEX7
					line <= rsp_rdata;
					req_be <= {LINE_BYTES{1'b0}};
`endif
					wr_any <= 1'b0;
					e <= 3'd0;
				end
			S_TEST0:  begin end
			S_TEST0A: begin end
			S_TEST0B: begin end
			S_TEST1:  begin end
			S_TEST2:  begin end
			S_TEST2B: begin end
			S_TEST3: begin
				if (test_mask_rep[0]) begin
					if (!test_pass)
						pm[test_sb] <= 1'b0;
					if (test_wbe_rep[0] != 4'd0)
						wr_any <= 1'b1;
				end
				e <= e_next;
			end
			S_WR:
				if (!wr_any) begin
					r_rep <= 5'h1F;
				end else if (!wait_rsp) begin
					if (!req_valid) begin
						req_valid <= 1'b1;
						req_write <= 1'b1;
					end else if (req_ready) begin
						req_valid <= 1'b0;
						wait_rsp <= 1'b1;
					end
				end else if (rsp_valid) begin
					wait_rsp <= 1'b0;
					wr_any <= 1'b0;
					r_rep <= 5'h1F;
				end
			default: begin	/* S_OUT */
				if (!d_valid)
					d_smask <= pm;
			end
			endcase
		end
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, STENCIL != 0, WPL != 0, WB != 0, bo[0], yrs[48:32],
		yr_co_unused, ra_co_unused, rb1_co_unused, rd_co_unused, bo_co_unused,
		u24_p_bo, u16_p_bo, u24_r_co, u16_r_co, u24_sh[22:0], u16_sh[22:0],
		zun_mn[71], zun_mn[46:0], zun_carry_unused, sinc_co_unused, sdec_bo_unused,
		zkey_co_unused, skey_co_unused, addr[LINE_SHIFT-1:0],
		dbgf_ch3_lo[31:16], dbgf_ch3_hi[15:0], dbgf_ch2_lo[31:16], dbgf_ch2_hi[15:0],
		dbgf_ch1_lo[31:16], dbgf_ch1_hi[15:0], dbgf_ch0_lo[31:16], dbgf_ch0_hi[15:0],
		test_bo_rep[0][0], test_bo_rep[1][0], test_bo_rep[2][0], test_bo_rep[3][0], sops[15:9]};
endmodule

/* Pure-LUT 33-bit signed lt/eq comparator (0 CARRY4s, lt <= 4 LUTs, eq <= 3 LUTs) */
module atg_rop_ds_cmp33 (
	input wire [32:0] a,
	input wire [32:0] b,
	output wire lt,
	output wire eq
);
	/* Flip sign bit [32] so signed comparison becomes unsigned comparison */
	wire [32:0] ua = {~a[32], a[31:0]};
	wire [32:0] ub = {~b[32], b[31:0]};

	(* keep = "true" *) wire [10:0] lt0, eq0;
	genvar i;
	generate
	for (i = 0; i < 11; i = i + 1) begin : g_s0
		wire [2:0] sa = ua[3 * i +: 3];
		wire [2:0] sb = ub[3 * i +: 3];
		assign eq0[i] = (sa == sb);
		assign lt0[i] = (~sa[2] & sb[2]) |
			((sa[2] ~^ sb[2]) & ((~sa[1] & sb[1]) | ((sa[1] ~^ sb[1]) & (~sa[0] & sb[0]))));
	end
	endgenerate

	(* keep = "true" *) wire [3:0] lt1, eq1;
	generate
	for (i = 0; i < 3; i = i + 1) begin : g_s1
		assign eq1[i] = eq0[3 * i + 2] & eq0[3 * i + 1] & eq0[3 * i];
		assign lt1[i] = lt0[3 * i + 2] | (eq0[3 * i + 2] & lt0[3 * i + 1]) |
			(eq0[3 * i + 2] & eq0[3 * i + 1] & lt0[3 * i]);
	end
	endgenerate
	assign eq1[3] = eq0[10] & eq0[9];
	assign lt1[3] = lt0[10] | (eq0[10] & lt0[9]);

	(* keep = "true" *) wire lt01 = lt1[1] | (eq1[1] & lt1[0]);
	assign lt = lt1[3] | (eq1[3] & lt1[2]) | (eq1[3] & eq1[2] & lt01);
	assign eq = &eq1;
endmodule

/* Stage 2A of depth/stencil test: pure-LUT comparators and stencil op pre-select (0 CARRY4s, <= 4 LUTs) */
module atg_rop_ds_eval_s2a (
	input wire [7:0] ss_ref,
	input wire [7:0] cm,
	input wire [2:0] ss_fn,
	input wire [8:0] so_lo,
	input wire [8:0] so_hi,
	input wire [7:0] wm,
	input wire [31:0] bmin,
	input wire [31:0] bmax,
	input wire [31:0] zf,
	input wire [31:0] stored,
	input wire [31:0] zun,
	input wire [23:0] zu24,
	input wire [15:0] zu16,
	input wire [32:0] zkey,
	input wire [32:0] skey,
	input wire [7:0] s_inc,
	input wire [7:0] s_dec,
	output wire bmin_st,
	output wire bmax_st,
	output wire bmin_zun,
	output wire bmax_zun,
	output wire lt_32,
	output wire eq_32,
	output wire nan_32,
	output wire lt_24,
	output wire eq_24,
	output wire lt_16,
	output wire eq_16,
	output wire s_cmp,
	output wire [7:0] swr_fail,
	output wire [7:0] swr_dpass,
	output wire [7:0] swr_dfail,
	output wire sch_fail,
	output wire sch_dpass,
	output wire sch_dfail
);
	/* 1. depth bounds (pure LUT, 0 LUTs before/after 4-LUT atg_rop_ms_fle) */
	atg_rop_ms_fle u_bmin_st  (.a(bmin),   .b(stored), .le(bmin_st));
	atg_rop_ms_fle u_bmax_st  (.a(stored), .b(bmax),   .le(bmax_st));
	atg_rop_ms_fle u_bmin_zun (.a(bmin),   .b(zun),    .le(bmin_zun));
	atg_rop_ms_fle u_bmax_zun (.a(zun),    .b(bmax),   .le(bmax_zun));

	/* 3. depth compare (pure LUT, <= 4 LUTs directly to FFs) */
	(* keep = "true" *) wire [3:0] zf_mnz, st_mnz;
	assign zf_mnz[0] = (zf[5:0]   != 6'd0);
	assign zf_mnz[1] = (zf[11:6]  != 6'd0);
	assign zf_mnz[2] = (zf[17:12] != 6'd0);
	assign zf_mnz[3] = (zf[22:18] != 5'd0);
	assign st_mnz[0] = (stored[5:0]   != 6'd0);
	assign st_mnz[1] = (stored[11:6]  != 6'd0);
	assign st_mnz[2] = (stored[17:12] != 6'd0);
	assign st_mnz[3] = (stored[22:18] != 5'd0);
	(* keep = "true" *) wire zf_e0 = (zf[30:26]     == 5'h1F);
	(* keep = "true" *) wire zf_e1 = (zf[25:23]     == 3'b111);
	(* keep = "true" *) wire st_e0 = (stored[30:26] == 5'h1F);
	(* keep = "true" *) wire st_e1 = (stored[25:23] == 3'b111);
	(* keep = "true" *) wire zf_nan = zf_e0 & zf_e1 & (|zf_mnz);
	(* keep = "true" *) wire st_nan = st_e0 & st_e1 & (|st_mnz);
	assign nan_32 = zf_nan | st_nan;

	atg_rop_ds_cmp33 u_dc32 (.a(zkey),          .b(skey),                  .lt(lt_32), .eq(eq_32));
	atg_rop_ds_cmp33 u_dc24 (.a({9'd0, zu24}),  .b({9'd0, stored[23:0]}),  .lt(lt_24), .eq(eq_24));
	atg_rop_ds_cmp33 u_dc16 (.a({17'd0, zu16}), .b({17'd0, stored[15:0]}), .lt(lt_16), .eq(eq_16));

	/* 2. stencil compare & pre-masked stencil write words (pure LUT, <= 3 LUTs) */
	wire [7:0] s_a = stored[31:24];
	wire [7:0] lhs = ss_ref & cm;
	wire [7:0] rhs = s_a & cm;
	(* keep = "true" *) wire [2:0] slt0, seq0;
	assign seq0[0] = (lhs[2:0] == rhs[2:0]);
	assign slt0[0] = (~lhs[2] & rhs[2]) | ((lhs[2] ~^ rhs[2]) & ((~lhs[1] & rhs[1]) | ((lhs[1] ~^ rhs[1]) & (~lhs[0] & rhs[0]))));
	assign seq0[1] = (lhs[5:3] == rhs[5:3]);
	assign slt0[1] = (~lhs[5] & rhs[5]) | ((lhs[5] ~^ rhs[5]) & ((~lhs[4] & rhs[4]) | ((lhs[4] ~^ rhs[4]) & (~lhs[3] & rhs[3]))));
	assign seq0[2] = (lhs[7:6] == rhs[7:6]);
	assign slt0[2] = (~lhs[7] & rhs[7]) | ((lhs[7] ~^ rhs[7]) & (~lhs[6] & rhs[6]));
	(* keep = "true" *) wire slt = slt0[2] | (seq0[2] & slt0[1]) | (seq0[2] & seq0[1] & slt0[0]);
	(* keep = "true" *) wire seq = &seq0;

	reg s_cmp_r;
	always @(*) begin
		case (ss_fn)
		3'd0: s_cmp_r = 1'b0;
		3'd1: s_cmp_r = slt;
		3'd2: s_cmp_r = seq;
		3'd3: s_cmp_r = slt || seq;
		3'd4: s_cmp_r = !slt && !seq;
		3'd5: s_cmp_r = !seq;
		3'd6: s_cmp_r = !slt;
		default: s_cmp_r = 1'b1;
		endcase
	end
	assign s_cmp = s_cmp_r;

	function [3:0] get_snew4;
		input [2:0] op;
		input [3:0] sa;
		input [3:0] sref;
		input [3:0] sinc;
		input [3:0] sdec;
		input is_ff;
		input is_z;
		begin
			case (op)
			3'd0: get_snew4 = sa;
			3'd1: get_snew4 = 4'd0;
			3'd2: get_snew4 = sref;
			3'd3: get_snew4 = is_ff ? 4'hF : sinc;
			3'd4: get_snew4 = is_z  ? 4'd0 : sdec;
			3'd5: get_snew4 = ~sa;
`ifdef MUT_STENCIL_WRAP
			3'd6: get_snew4 = is_ff ? 4'hF : sinc;
			default: get_snew4 = is_z ? 4'd0 : sdec;
`else
			3'd6: get_snew4 = sinc;
			default: get_snew4 = sdec;
`endif
			endcase
		end
	endfunction

	(* keep = "true" *) wire sa_ff_lo = (s_a == 8'hFF);
	(* keep = "true" *) wire sa_ff_hi = (s_a == 8'hFF);
	(* keep = "true" *) wire sa_z_lo  = (s_a == 8'd0);
	(* keep = "true" *) wire sa_z_hi  = (s_a == 8'd0);
	(* keep = "true" *) wire [7:0] snew_f = {
		get_snew4(so_hi[2:0], s_a[7:4], ss_ref[7:4], s_inc[7:4], s_dec[7:4], sa_ff_hi, sa_z_hi),
		get_snew4(so_lo[2:0], s_a[3:0], ss_ref[3:0], s_inc[3:0], s_dec[3:0], sa_ff_lo, sa_z_lo)
	};
	(* keep = "true" *) wire [7:0] snew_dp = {
		get_snew4(so_hi[5:3], s_a[7:4], ss_ref[7:4], s_inc[7:4], s_dec[7:4], sa_ff_hi, sa_z_hi),
		get_snew4(so_lo[5:3], s_a[3:0], ss_ref[3:0], s_inc[3:0], s_dec[3:0], sa_ff_lo, sa_z_lo)
	};
	(* keep = "true" *) wire [7:0] snew_df = {
		get_snew4(so_hi[8:6], s_a[7:4], ss_ref[7:4], s_inc[7:4], s_dec[7:4], sa_ff_hi, sa_z_hi),
		get_snew4(so_lo[8:6], s_a[3:0], ss_ref[3:0], s_inc[3:0], s_dec[3:0], sa_ff_lo, sa_z_lo)
	};
	assign swr_fail  = (s_a & ~wm) | (snew_f  & wm);
	assign swr_dpass = (s_a & ~wm) | (snew_dp & wm);
	assign swr_dfail = (s_a & ~wm) | (snew_df & wm);

	(* keep = "true" *) wire [1:0] sch_f_n, sch_dp_n, sch_df_n;
	assign sch_f_n[0]  = (((snew_f[3:0]  ^ s_a[3:0]) & wm[3:0]) != 4'd0);
	assign sch_f_n[1]  = (((snew_f[7:4]  ^ s_a[7:4]) & wm[7:4]) != 4'd0);
	assign sch_dp_n[0] = (((snew_dp[3:0] ^ s_a[3:0]) & wm[3:0]) != 4'd0);
	assign sch_dp_n[1] = (((snew_dp[7:4] ^ s_a[7:4]) & wm[7:4]) != 4'd0);
	assign sch_df_n[0] = (((snew_df[3:0] ^ s_a[3:0]) & wm[3:0]) != 4'd0);
	assign sch_df_n[1] = (((snew_df[7:4] ^ s_a[7:4]) & wm[7:4]) != 4'd0);
	assign sch_fail  = |sch_f_n;
	assign sch_dpass = |sch_dp_n;
	assign sch_dfail = |sch_df_n;

	wire unused_sops = &{1'b0, zf[31]};
endmodule

/* Stage 2B of depth/stencil test: final boolean combine and write word assembly (<= 4 LUTs, 0 CARRY4s) */
module atg_rop_ds_eval_s2b (
	input wire [9:0] depth,
	input wire [31:0] zf,
	input wire [23:0] zu24,
	input wire [15:0] zu16,
	input wire bmin_st,
	input wire bmax_st,
	input wire bmin_zun,
	input wire bmax_zun,
	input wire lt_32,
	input wire eq_32,
	input wire nan_32,
	input wire lt_24,
	input wire eq_24,
	input wire lt_16,
	input wire eq_16,
	input wire s_cmp,
	input wire [7:0] swr_fail,
	input wire [7:0] swr_dpass,
	input wire [7:0] swr_dfail,
	input wire sch_fail,
	input wire sch_dpass,
	input wire sch_dfail,
	output wire pass,
	output wire [31:0] wword,
	output wire [3:0] wbe
);
	wire d24_raw = depth[7:5] == 3'b001;
	wire d32_raw = depth[7:5] == 3'b010;
	wire d16 = depth[7:5] == 3'b100;
	wire d24_lo, d24_hi, d32_lo, d32_hi;
`ifdef SYNTH_KINTEX7
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_d24l (.I0(d24_raw), .O(d24_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_d24h (.I0(d24_raw), .O(d24_hi));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_d32l (.I0(d32_raw), .O(d32_lo));
	(* keep = "true", dont_touch = "true" *) LUT1 #(.INIT(2'h2)) u_d32h (.I0(d32_raw), .O(d32_hi));
`else
	assign d24_lo = d24_raw;
	assign d24_hi = d24_raw;
	assign d32_lo = d32_raw;
	assign d32_hi = d32_raw;
`endif
	wire has = d24_lo || d32_lo || d16;

	/* Level 1: format mux for depth lt/eq/nan, depth fn decode, and b_ok (each <= 6 inputs) */
	(* keep = "true" *) wire b_ok = !depth[9] || (d32_raw ? (bmin_st && bmax_st) : (bmin_zun && bmax_zun));
	(* keep = "true" *) wire d_lt = d32_raw ? (!nan_32 && lt_32) : (d24_raw ? lt_24 : lt_16);
	(* keep = "true" *) wire d_eq = d32_raw ? (!nan_32 && eq_32) : (d24_raw ? eq_24 : eq_16);

	wire [2:0] fn = depth[4:2];
	wire d_nan = d32_raw && nan_32;
	(* keep = "true" *) wire allow_lt = !depth[0] || (!d_nan && (fn == 3'd1 || fn == 3'd3 || fn == 3'd5 || fn == 3'd7));
	(* keep = "true" *) wire allow_eq = !depth[0] || (!d_nan && (fn == 3'd2 || fn == 3'd3 || fn == 3'd6 || fn == 3'd7));
	(* keep = "true" *) wire allow_gt = !depth[0] || (d_nan ? (fn == 3'd5 || fn == 3'd7) : (fn == 3'd4 || fn == 3'd5 || fn == 3'd6 || fn == 3'd7));

	/* Level 2: d_ok */
	(* keep = "true" *) wire d_ok = d_lt ? allow_lt : (d_eq ? allow_eq : allow_gt);

	wire s_on = depth[8] && d24_lo;
	wire [7:0] s_wr = !s_cmp ? swr_fail : (d_ok ? swr_dpass : swr_dfail);
	wire s_diff     = !s_cmp ? sch_fail : (d_ok ? sch_dpass : sch_dfail);
	wire s_ok = !s_on || s_cmp;

	wire live = has && b_ok;
	assign pass = !has ? 1'b1 : (live && s_ok && d_ok);
	wire d_wr = live && s_ok && d_ok && depth[1];
	wire s_ch = live && s_on && s_diff;
	assign wword = {
		d32_hi ? zf[31:16] : (d24_hi ? {s_wr, zu24[23:16]} : 16'd0),
		d32_lo ? zf[15:0]  : (d24_lo ? zu24[15:0]          : zu16)
	};
	assign wbe = d32_lo ? {4{d_wr}} : (d24_lo ? {s_ch, {3{d_wr}}} : {2'b00, {2{d_wr}}});
endmodule

`default_nettype wire
