/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_cfg: the BLT state of the blitter's engines (atg_blt_2d,
 * atg_blt_rsv) and what it means: the copy of STATE[0x000..0x00E] as the
 * CP writes them, the operation, its pixel size and options, whether the
 * engine does it, the clipped destination rectangle, the bases and strides
 * without their bits below the pixel size, and the FILL pattern of a line.
 *
 * Pixel sizes (BLT_OP[9:8], [13], docs/ghci.md sections 8.2 and 8.5):
 * 0 32 bits, 1 16, 2 64, 3 8; [13] with [9:8] = 0 128 bits; psl = log2 of
 * the bytes.  Taken: FILL and COPY of every size; TILE and UNTILE of 16-
 * and 32-bit pixels; blend-over with 32-bit FILL and COPY; the reverse
 * direction with FILL and COPY; KEEP (BLT_OP[19:16], bytes of each pixel
 * not written) with FILL and COPY of 32-bit pixels without blend-over.
 * Anything else: op_ok = 0 (op_ok is the 2D engine's; atg_blt_rsv checks
 * its own combinations from the fields).  The rectangle is the destination ∩
 * [CLIP_MIN, CLIP_MAX) when CLIP_MAX is not 0 (combinational from the
 * copy; the CP writes no BLT state while the blitter is busy).
 * See spec/gpu/blt/atg_blt_cfg.md.
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_blt_cfg #(
	parameter LINE_BYTES = 32,
	parameter ENABLE_BLEND = 1,
	parameter ENABLE_TILE = 1
) (
	input wire clk,
	input wire rst_n,
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* The operation */
	output wire [1:0] op,
	output wire op2,	/* BLT_OP[2]: RESOLVE */
	output wire [8:0] resolve,	/* BLT_RESOLVE[8:0] */
	output wire blend,
	output wire rev,
	output wire [2:0] psl,	/* log2 of the pixel's bytes */
	output wire [3:0] keep,
	output wire op_ok,
	/* The clipped destination rectangle, the destination and source origins */
	output wire [16:0] x0,
	output wire [16:0] y0,
	output wire [16:0] x1,
	output wire [16:0] y1,
	output wire [16:0] dx,
	output wire [16:0] dy,
	output wire [31:0] src_xy,
	/* Bases and strides in bytes, multiples of the pixel size */
	output wire [31:0] dbase,
	output wire [31:0] sbase,
	output wire [31:0] dstride,
	output wire [31:0] sstride,
	output wire [31:0] src_slice,
	output wire [31:0] dst_slice,
	output wire [15:0] depth,
	/* The FILL line: the pixel repeated */
	output wire [LINE_BYTES*8-1:0] fill_line
);
	`include "ghci_regs.vh"

	(* max_fanout = 16 *) reg [31:0] s_op;
	(* max_fanout = 16 *) reg [31:0] s_dst_base, s_dst_stride, s_src_base, s_src_stride, s_dst_xy, s_src_xy;
	(* max_fanout = 16 *) reg [31:0] s_size, s_clip_min, s_clip_max, s_resolve;
	(* max_fanout = 16 *) reg [31:0] s_src_slice, s_dst_slice, s_depth;
	(* max_fanout = 16 *) reg [127:0] s_color;	/* COLOR, COLOR1-COLOR3 */
	(* max_fanout = 16 *) reg [127:0] s_color_1;
	(* max_fanout = 16 *) reg [127:0] s_color_2;
	(* max_fanout = 16 *) reg [127:0] s_color_3;

	(* keep = "true", dont_touch = "true" *) wire rst_cfg_high = !rst_n;

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) wire [7:0] idx_ok_b;
	genvar giok;
	generate
		for (giok = 0; giok < 8; giok = giok + 1) begin : g_idx_ok
			(* dont_touch = "true" *) LUT5 #(.INIT(32'h00000002)) u_iok (
				.I0(st_we), .I1(st_idx[5]), .I2(st_idx[6]), .I3(st_idx[7]), .I4(st_idx[8]),
				.O(idx_ok_b[giok])
			);
		end
	endgenerate
	wire idx_ok_0 = idx_ok_b[0];
	wire idx_ok_1 = idx_ok_b[1];
	wire idx_ok_2 = idx_ok_b[2];
	wire idx_ok_3 = idx_ok_b[3];
	wire idx_ok_4 = idx_ok_b[4];
	wire idx_ok_5 = idx_ok_b[5];
	wire idx_ok_6 = idx_ok_b[6];
	wire idx_ok_7 = idx_ok_b[7];
	(* dont_touch = "true" *) wire [4:0] st_idx_0, st_idx_1, st_idx_2, st_idx_3;
	(* dont_touch = "true" *) wire [31:0] st_wdata_a;
	(* dont_touch = "true" *) wire [31:0] st_wdata_b;
	(* dont_touch = "true" *) wire [31:0] st_wdata_c;
	genvar gwi;
	generate
		for (gwi = 0; gwi < 5; gwi = gwi + 1) begin : g_idx_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id0 (.I0(st_idx[gwi]), .O(st_idx_0[gwi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id1 (.I0(st_idx[gwi]), .O(st_idx_1[gwi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id2 (.I0(st_idx[gwi]), .O(st_idx_2[gwi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_id3 (.I0(st_idx[gwi]), .O(st_idx_3[gwi]));
		end
		for (gwi = 0; gwi < 32; gwi = gwi + 1) begin : g_wdata_buf
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wa (.I0(st_wdata[gwi]), .O(st_wdata_a[gwi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wb (.I0(st_wdata[gwi]), .O(st_wdata_b[gwi]));
			(* dont_touch = "true" *) LUT1 #(.INIT(2'b10)) u_buf_wc (.I0(st_wdata[gwi]), .O(st_wdata_c[gwi]));
		end
	endgenerate
`else
	wire idx_ok_0 = st_we && (st_idx[8:5] == 4'd0);
	wire idx_ok_1 = idx_ok_0;
	wire idx_ok_2 = idx_ok_0;
	wire idx_ok_3 = idx_ok_0;
	wire idx_ok_4 = idx_ok_0;
	wire idx_ok_5 = idx_ok_0;
	wire idx_ok_6 = idx_ok_0;
	wire idx_ok_7 = idx_ok_0;
	wire [4:0] st_idx_0 = st_idx[4:0];
	wire [4:0] st_idx_1 = st_idx[4:0];
	wire [4:0] st_idx_2 = st_idx[4:0];
	wire [4:0] st_idx_3 = st_idx[4:0];
	wire [31:0] st_wdata_a = st_wdata;
	wire [31:0] st_wdata_b = st_wdata;
	wire [31:0] st_wdata_c = st_wdata;
`endif

	(* keep = "true" *) wire we_op_lo         = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_OP[4:0]);
	(* keep = "true" *) wire we_op_hi         = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_OP[4:0]);
	(* keep = "true" *) wire we_dst_base_lo   = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_DST_BASE[4:0]);
	(* keep = "true" *) wire we_dst_base_hi   = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_DST_BASE[4:0]);
	(* keep = "true" *) wire we_dst_stride_lo = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_DST_STRIDE[4:0]);
	(* keep = "true" *) wire we_dst_stride_hi = idx_ok_0 && (st_idx_0 == GHCI_S_BLT_DST_STRIDE[4:0]);
	(* keep = "true" *) wire we_src_base_lo   = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_BASE[4:0]);
	(* keep = "true" *) wire we_src_base_hi   = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_BASE[4:0]);
	(* keep = "true" *) wire we_src_stride_lo = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_STRIDE[4:0]);
	(* keep = "true" *) wire we_src_stride_hi = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_STRIDE[4:0]);
	(* keep = "true" *) wire we_src_slice_lo  = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_SLICE[4:0]);
	(* keep = "true" *) wire we_src_slice_hi  = idx_ok_1 && (st_idx_0 == GHCI_S_BLT_SRC_SLICE[4:0]);
	(* keep = "true" *) wire we_dst_slice_lo  = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DST_SLICE[4:0]);
	(* keep = "true" *) wire we_dst_slice_hi  = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DST_SLICE[4:0]);
	(* keep = "true" *) wire we_depth_lo      = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DEPTH[4:0]);
	(* keep = "true" *) wire we_depth_hi      = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DEPTH[4:0]);
	(* keep = "true" *) wire we_dst_xy_lo     = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DST_XY[4:0]);
	(* keep = "true" *) wire we_dst_xy_hi     = idx_ok_2 && (st_idx_1 == GHCI_S_BLT_DST_XY[4:0]);
	(* keep = "true" *) wire we_src_xy_lo     = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_SRC_XY[4:0]);
	(* keep = "true" *) wire we_src_xy_hi     = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_SRC_XY[4:0]);
	(* keep = "true" *) wire we_size_lo       = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_SIZE[4:0]);
	(* keep = "true" *) wire we_size_hi       = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_SIZE[4:0]);
	(* keep = "true" *) wire we_clip_min_lo   = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_CLIP_MIN[4:0]);
	(* keep = "true" *) wire we_clip_min_hi   = idx_ok_3 && (st_idx_1 == GHCI_S_BLT_CLIP_MIN[4:0]);
	(* keep = "true" *) wire we_clip_max_lo   = idx_ok_4 && (st_idx_1 == GHCI_S_BLT_CLIP_MAX[4:0]);
	(* keep = "true" *) wire we_clip_max_hi   = idx_ok_4 && (st_idx_1 == GHCI_S_BLT_CLIP_MAX[4:0]);
	(* keep = "true" *) wire we_resolve_lo    = idx_ok_4 && (st_idx_1 == GHCI_S_BLT_RESOLVE[4:0]);
	(* keep = "true" *) wire we_resolve_hi    = idx_ok_4 && (st_idx_1 == GHCI_S_BLT_RESOLVE[4:0]);

	(* keep = "true" *) wire we_c0_a = idx_ok_4 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_b = idx_ok_4 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_c = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_d = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_e = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_f = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_g = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);
	(* keep = "true" *) wire we_c0_h = idx_ok_5 && (st_idx_2 == GHCI_S_BLT_COLOR[4:0]);

	(* keep = "true" *) wire we_c1_a = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_b = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_c = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_d = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_e = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_f = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_g = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);
	(* keep = "true" *) wire we_c1_h = idx_ok_6 && (st_idx_2 == GHCI_S_BLT_COLOR1[4:0]);

	(* keep = "true" *) wire we_c2_a = idx_ok_6 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_b = idx_ok_6 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_c = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_d = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_e = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_f = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_g = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);
	(* keep = "true" *) wire we_c2_h = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR2[4:0]);

	(* keep = "true" *) wire we_c3_a = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_b = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_c = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_d = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_e = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_f = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_g = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);
	(* keep = "true" *) wire we_c3_h = idx_ok_7 && (st_idx_3 == GHCI_S_BLT_COLOR3[4:0]);

`ifdef SYNTH_KINTEX7
	(* dont_touch = "true" *) wire we_dst_base_hi_buf;
	LUT1 #(.INIT(2'b10)) u_wdbh (.I0(we_dst_base_hi), .O(we_dst_base_hi_buf));
	(* dont_touch = "true" *) wire we_src_xy_hi_buf;
	LUT1 #(.INIT(2'b10)) u_wsxh (.I0(we_src_xy_hi), .O(we_src_xy_hi_buf));
	(* dont_touch = "true" *) wire we_c0_b_buf;
	LUT1 #(.INIT(2'b10)) u_wc0b (.I0(we_c0_b), .O(we_c0_b_buf));
	(* dont_touch = "true" *) wire we_c2_h_buf;
	LUT1 #(.INIT(2'b10)) u_wc2h (.I0(we_c2_h), .O(we_c2_h_buf));
	(* dont_touch = "true" *) wire we_c3_h_buf;
	LUT1 #(.INIT(2'b10)) u_wc3h (.I0(we_c3_h), .O(we_c3_h_buf));
`else
	wire we_dst_base_hi_buf = we_dst_base_hi;
	wire we_src_xy_hi_buf = we_src_xy_hi;
	wire we_c0_b_buf = we_c0_b;
	wire we_c2_h_buf = we_c2_h;
	wire we_c3_h_buf = we_c3_h;
`endif

	always @(posedge clk) begin
		if (rst_cfg_high) begin
			s_op <= 32'd0;
			s_dst_base <= 32'd0;
			s_dst_stride <= 32'd0;
			s_src_base <= 32'd0;
			s_src_stride <= 32'd0;
			s_src_slice <= 32'd0;
			s_dst_slice <= 32'd0;
			s_depth <= 32'd1;
			s_dst_xy <= 32'd0;
			s_src_xy <= 32'd0;
			s_size <= 32'd0;
			s_color <= 128'd0;
			s_color_1 <= 128'd0;
			s_color_2 <= 128'd0;
			s_color_3 <= 128'd0;
			s_clip_min <= 32'd0;
			s_clip_max <= 32'd0;
			s_resolve <= 32'd0;
		end else begin
			if (we_op_lo) s_op[15:0] <= st_wdata_a[15:0];
			if (we_op_hi) s_op[31:16] <= st_wdata_a[31:16];
			if (we_dst_base_lo) s_dst_base[15:0] <= st_wdata_a[15:0];
			if (we_dst_base_hi_buf) s_dst_base[31:16] <= st_wdata_a[31:16];
			if (we_dst_stride_lo) s_dst_stride[15:0] <= st_wdata_a[15:0];
			if (we_dst_stride_hi) s_dst_stride[31:16] <= st_wdata_a[31:16];
			if (we_src_base_lo) s_src_base[15:0] <= st_wdata_a[15:0];
			if (we_src_base_hi) s_src_base[31:16] <= st_wdata_a[31:16];
			if (we_src_stride_lo) s_src_stride[15:0] <= st_wdata_a[15:0];
			if (we_src_stride_hi) s_src_stride[31:16] <= st_wdata_a[31:16];
			if (we_src_slice_lo) s_src_slice[15:0] <= st_wdata_a[15:0];
			if (we_src_slice_hi) s_src_slice[31:16] <= st_wdata_a[31:16];
			if (we_dst_slice_lo) s_dst_slice[15:0] <= st_wdata_a[15:0];
			if (we_dst_slice_hi) s_dst_slice[31:16] <= st_wdata_a[31:16];
			if (we_depth_lo) s_depth[15:0] <= st_wdata_a[15:0];
			if (we_depth_hi) s_depth[31:16] <= st_wdata_a[31:16];
			if (we_dst_xy_lo) s_dst_xy[15:0] <= st_wdata_b[15:0];
			if (we_dst_xy_hi) s_dst_xy[31:16] <= st_wdata_b[31:16];
			if (we_src_xy_lo) s_src_xy[15:0] <= st_wdata_b[15:0];
			if (we_src_xy_hi_buf) s_src_xy[31:16] <= st_wdata_b[31:16];
			if (we_size_lo) s_size[15:0] <= st_wdata_b[15:0];
			if (we_size_hi) s_size[31:16] <= st_wdata_b[31:16];
			if (we_clip_min_lo) s_clip_min[15:0] <= st_wdata_b[15:0];
			if (we_clip_min_hi) s_clip_min[31:16] <= st_wdata_b[31:16];
			if (we_clip_max_lo) s_clip_max[15:0] <= st_wdata_b[15:0];
			if (we_clip_max_hi) s_clip_max[31:16] <= st_wdata_b[31:16];
			if (we_resolve_lo) s_resolve[15:0] <= st_wdata_b[15:0];
			if (we_resolve_hi) s_resolve[31:16] <= st_wdata_b[31:16];

			if (we_c0_a) s_color[15:0] <= st_wdata_b[15:0];
			if (we_c0_b_buf) s_color[31:16] <= st_wdata_b[31:16];
			if (we_c0_c) s_color_1[15:0] <= st_wdata_b[15:0];
			if (we_c0_d) s_color_1[31:16] <= st_wdata_b[31:16];
			if (we_c0_e) s_color_2[15:0] <= st_wdata_c[15:0];
			if (we_c0_f) s_color_2[31:16] <= st_wdata_c[31:16];
			if (we_c0_g) s_color_3[15:0] <= st_wdata_c[15:0];
			if (we_c0_h) s_color_3[31:16] <= st_wdata_c[31:16];

			if (we_c1_a) s_color[47:32] <= st_wdata_b[15:0];
			if (we_c1_b) s_color[63:48] <= st_wdata_b[31:16];
			if (we_c1_c) s_color_1[47:32] <= st_wdata_b[15:0];
			if (we_c1_d) s_color_1[63:48] <= st_wdata_b[31:16];
			if (we_c1_e) s_color_2[47:32] <= st_wdata_c[15:0];
			if (we_c1_f) s_color_2[63:48] <= st_wdata_c[31:16];
			if (we_c1_g) s_color_3[47:32] <= st_wdata_c[15:0];
			if (we_c1_h) s_color_3[63:48] <= st_wdata_c[31:16];

			if (we_c2_a) s_color[79:64] <= st_wdata_b[15:0];
			if (we_c2_b) s_color[95:80] <= st_wdata_b[31:16];
			if (we_c2_c) s_color_1[79:64] <= st_wdata_b[15:0];
			if (we_c2_d) s_color_1[95:80] <= st_wdata_b[31:16];
			if (we_c2_e) s_color_2[79:64] <= st_wdata_c[15:0];
			if (we_c2_f) s_color_2[95:80] <= st_wdata_c[31:16];
			if (we_c2_g) s_color_3[79:64] <= st_wdata_c[15:0];
			if (we_c2_h_buf) s_color_3[95:80] <= st_wdata_c[31:16];

			if (we_c3_a) s_color[111:96] <= st_wdata_b[15:0];
			if (we_c3_b) s_color[127:112] <= st_wdata_b[31:16];
			if (we_c3_c) s_color_1[111:96] <= st_wdata_b[15:0];
			if (we_c3_d) s_color_1[127:112] <= st_wdata_b[31:16];
			if (we_c3_e) s_color_2[111:96] <= st_wdata_c[15:0];
			if (we_c3_f) s_color_2[127:112] <= st_wdata_c[31:16];
			if (we_c3_g) s_color_3[111:96] <= st_wdata_c[15:0];
			if (we_c3_h_buf) s_color_3[127:112] <= st_wdata_c[31:16];
		end
	end

	/* The operation, its pixel size and whether the engine does it. */
	assign op = s_op[1:0];
	assign op2 = s_op[2];
	assign resolve = s_resolve[8:0];
	assign blend = s_op[GHCI_BLT_OP_BLEND];
	assign rev = s_op[GHCI_BLT_OP_REVERSE];
	assign keep = s_op[GHCI_BLT_OP_KEEP +: 4];
	wire p128 = s_op[GHCI_BLT_OP_PS128];
	wire [1:0] bpp = s_op[9:8];
	wire [2:0] psl_raw = p128 ? 3'd4 : bpp == 2'd0 ? 3'd2 : bpp == 2'd1 ? 3'd1 : bpp == 2'd2 ? 3'd3 : 3'd0;
	wire [2:0] psl_int;
`ifdef SYNTH_KINTEX7
	LUT1 #(.INIT(2'b10)) u_psl0 (.I0(psl_raw[0]), .O(psl_int[0]));
	LUT1 #(.INIT(2'b10)) u_psl1 (.I0(psl_raw[1]), .O(psl_int[1]));
	LUT1 #(.INIT(2'b10)) u_psl2 (.I0(psl_raw[2]), .O(psl_int[2]));
	LUT1 #(.INIT(2'b10)) u_psl_o0 (.I0(psl_raw[0]), .O(psl[0]));
	LUT1 #(.INIT(2'b10)) u_psl_o1 (.I0(psl_raw[1]), .O(psl[1]));
	LUT1 #(.INIT(2'b10)) u_psl_o2 (.I0(psl_raw[2]), .O(psl[2]));
`else
	assign psl_int = psl_raw;
	assign psl = psl_int;
`endif

	wire [1:0] op_in = st_wdata_a[1:0];
	wire blend_in = st_wdata_a[GHCI_BLT_OP_BLEND];
	wire rev_in = st_wdata_a[GHCI_BLT_OP_REVERSE];
	wire [3:0] keep_in = st_wdata_a[GHCI_BLT_OP_KEEP +: 4];
	wire p128_in = st_wdata_a[GHCI_BLT_OP_PS128];
	wire [1:0] bpp_in = st_wdata_a[9:8];
	wire [2:0] psl_in = p128_in ? 3'd4 : bpp_in == 2'd0 ? 3'd2 : bpp_in == 2'd1 ? 3'd1 : bpp_in == 2'd2 ? 3'd3 : 3'd0;
	wire tiled_in = op_in == GHCI_BLT_TILE || op_in == GHCI_BLT_UNTILE;
	wire op_ok_blend = (ENABLE_BLEND != 0) || !blend_in;
	wire op_ok_tile  = (ENABLE_TILE != 0) || !tiled_in;
	wire op_ok_in = op_ok_blend && op_ok_tile &&
		!(p128_in && bpp_in != 2'd0) && !(blend_in && (psl_in != 3'd2 || tiled_in)) &&
		!(rev_in && tiled_in) && !(tiled_in && psl_in != 3'd1 && psl_in != 3'd2) &&
		!(keep_in != 4'd0 && (tiled_in || blend_in || psl_in != 3'd2));

	(* max_fanout = 16 *) reg r_op_ok;
	always @(posedge clk) begin
		if (rst_cfg_high) begin
			r_op_ok <= 1'b1;
		end else if (we_op_lo) begin
			r_op_ok <= op_ok_in;
		end
	end

	assign op_ok = r_op_ok;

	/* The clipped rectangle. */
	(* keep = "true" *) wire clip_en_x0 = s_clip_max != 32'd0;
	(* keep = "true" *) wire clip_en_y0 = s_clip_max != 32'd0;
	(* keep = "true" *) wire clip_en_x1 = s_clip_max != 32'd0;
	(* keep = "true" *) wire clip_en_y1 = s_clip_max != 32'd0;
	(* keep = "true" *) wire clip_en_hi = s_clip_max != 32'd0;
	assign dx = {1'b0, s_dst_xy[15:0]};
	assign dy = {1'b0, s_dst_xy[31:16]};
	wire [16:0] dx_end, dy_end;
	wire [1:0] end_co_unused;

	am_add #(.W(17)) a_dxe (.a(dx), .b({1'b0, s_size[15:0]}), .ci(1'b0), .s(dx_end), .co(end_co_unused[0]));
	am_add #(.W(17)) a_dye (.a(dy), .b({1'b0, s_size[31:16]}), .ci(1'b0), .s(dy_end), .co(end_co_unused[1]));

	(* max_fanout = 16 *) reg [16:0] r_dx_end, r_dy_end;
	always @(posedge clk) begin
		if (!rst_n) begin
			r_dx_end <= 17'd0;
			r_dy_end <= 17'd0;
		end else begin
			r_dx_end <= dx_end;
			r_dy_end <= dy_end;
		end
	end

	wire [16:0] cx0 = {1'b0, s_clip_min[15:0]};
	wire [16:0] cy0 = {1'b0, s_clip_min[31:16]};
	wire [16:0] cx1 = {1'b0, s_clip_max[15:0]};
	wire [16:0] cy1 = {1'b0, s_clip_max[31:16]};
	(* keep = "true" *) wire cx0_gt_lo = cx0 > dx;
	(* keep = "true" *) wire cx0_gt_hi = cx0 > dx;
	(* keep = "true" *) wire cy0_gt_lo = cy0 > dy;
	(* keep = "true" *) wire cy0_gt_hi = cy0 > dy;
	(* keep = "true" *) wire cx1_lt_lo = cx1 < r_dx_end;
	(* keep = "true" *) wire cx1_lt_hi = cx1 < r_dx_end;
	(* keep = "true" *) wire cy1_lt_lo = cy1 < r_dy_end;
	(* keep = "true" *) wire cy1_lt_hi = cy1 < r_dy_end;
	assign x0[15:0] = (clip_en_x0 && cx0_gt_lo) ? cx0[15:0] : dx[15:0];
	assign x0[16]   = (clip_en_hi && cx0_gt_hi) ? cx0[16]   : dx[16];
	assign y0[15:0] = (clip_en_y0 && cy0_gt_lo) ? cy0[15:0] : dy[15:0];
	assign y0[16]   = (clip_en_hi && cy0_gt_hi) ? cy0[16]   : dy[16];
	assign x1[15:0] = (clip_en_x1 && cx1_lt_lo) ? cx1[15:0] : r_dx_end[15:0];
	assign x1[16]   = (clip_en_hi && cx1_lt_hi) ? cx1[16]   : r_dx_end[16];
	assign y1[15:0] = (clip_en_y1 && cy1_lt_lo) ? cy1[15:0] : r_dy_end[15:0];
	assign y1[16]   = (clip_en_hi && cy1_lt_hi) ? cy1[16]   : r_dy_end[16];
	assign src_xy = s_src_xy;

	/* The bits below the pixel size, 2^psl - 1, by table. */
	function [31:0] low_bits;
		input [2:0] l;
		case (l)
		3'd0: low_bits = 32'h00000000;
		3'd1: low_bits = 32'h00000001;
		3'd2: low_bits = 32'h00000003;
		3'd3: low_bits = 32'h00000007;
		3'd4: low_bits = 32'h0000000F;
		3'd5: low_bits = 32'h0000001F;
		3'd6: low_bits = 32'h0000003F;
		default: low_bits = 32'h0000007F;
		endcase
	endfunction

	/* Bases and strides without the bits below the pixel size. */
	(* keep = "true", dont_touch = "true" *) wire [31:0] low = low_bits(psl_int);
	(* keep = "true", dont_touch = "true" *) reg [3:0] r_low_base;
	always @(posedge clk) begin
		if (!rst_n) begin
			r_low_base <= 4'b0011;
		end else if (we_op_lo) begin
			r_low_base[3] <= st_wdata_a[GHCI_BLT_OP_PS128];
			r_low_base[2] <= st_wdata_a[GHCI_BLT_OP_PS128] || (st_wdata_a[9:8] == 2'd2);
			r_low_base[1] <= st_wdata_a[GHCI_BLT_OP_PS128] || (st_wdata_a[9:8] == 2'd2) || (st_wdata_a[9:8] == 2'd0);
			r_low_base[0] <= st_wdata_a[GHCI_BLT_OP_PS128] || (st_wdata_a[9:8] != 2'd3);
		end
	end
	wire [3:0] low_base = r_low_base;
	wire [31:0] mask = ~low;
	assign dbase = s_dst_base & mask;
	assign sbase = s_src_base & mask;
	assign dstride = s_dst_stride & mask;
	assign sstride = s_src_stride & mask;
	assign src_slice = s_src_slice & mask;
	assign dst_slice = s_dst_slice & mask;
	assign depth = s_depth[15:0] != 16'd0 ? s_depth[15:0] : 16'd1;

	/*
	 * Registered 128-bit FILL pattern (replicated across 16-byte chunks of fill_line).
	 * Updates 1 cycle after STATE_BLT_OP or STATE_BLT_COLOR* write, well before S_WR/S_BURST/S_BLEND.
	 */
	wire [127:0] w_fill_pat;
	(* dont_touch = "true" *) wire [3:0] low_grp [1:15][0:1];
	genvar g, gn;
`ifdef SYNTH_KINTEX7
	genvar gi;
`endif
	generate
`ifdef SYNTH_KINTEX7
		(* dont_touch = "true" *) wire [3:0] low_base_tree [0:1];
		for (gi = 0; gi < 4; gi = gi + 1) begin : g_lroot
			LUT1 #(.INIT(2'b10)) u_r0 (.I0(low_base[gi]), .O(low_base_tree[0][gi]));
			LUT1 #(.INIT(2'b10)) u_r1 (.I0(low_base[gi]), .O(low_base_tree[1][gi]));
		end
		for (g = 1; g < 16; g = g + 1) begin : g_low_grp
			for (gn = 0; gn < 2; gn = gn + 1) begin : g_lnib
				for (gi = 0; gi < 4; gi = gi + 1) begin : g_lbit
					LUT1 #(.INIT(2'b10)) u_lg (.I0(low_base_tree[g[3]][gi]), .O(low_grp[g][gn][gi]));
				end
			end
		end
`else
		for (g = 1; g < 16; g = g + 1) begin : g_low_grp
			for (gn = 0; gn < 2; gn = gn + 1) begin : g_lnib
				assign low_grp[g][gn] = low_base;
			end
		end
`endif
		for (g = 0; g < 16; g = g + 1) begin : g_fill_byte
			for (gn = 0; gn < 2; gn = gn + 1) begin : g_nib
				if (g == 0) begin : g_b0
					assign w_fill_pat[gn*4 +: 4] = s_color[gn*4 +: 4];
				end else if (g < 8) begin : g_blo
					assign w_fill_pat[g*8 + gn*4 +: 4] = s_color[{g[3:0] & low_grp[g][gn], gn[0], 2'b00} +: 4];
				end else begin : g_bhi
					assign w_fill_pat[g*8 + gn*4 +: 4] = s_color_1[{g[3:0] & low_grp[g][gn], gn[0], 2'b00} +: 4];
				end
			end
		end
	endgenerate

	(* dont_touch = "true", extract_reset = "no" *) reg [127:0] r_fill_pat [0:(LINE_BYTES/16)-1];
	genvar fk;
	generate
		for (fk = 0; fk < LINE_BYTES / 16; fk = fk + 1) begin : g_fill_rep
			always @(posedge clk) begin
				r_fill_pat[fk] <= w_fill_pat;
			end
			assign fill_line[fk*128 +: 128] = r_fill_pat[fk];
		end
	endgenerate

	wire unused_ok = &{1'b0, s_op[31:20], s_op[15:14], s_op[11:10], s_op[7:5], s_op[3],
		s_resolve[31:9], end_co_unused, s_depth[31:16], s_color_2, s_color_3};
endmodule

`default_nettype wire
