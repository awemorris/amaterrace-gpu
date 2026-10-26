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

module atg_blt_cfg #(
	parameter LINE_BYTES = 32
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

	reg [31:0] s_op, s_dst_base, s_dst_stride, s_src_base, s_src_stride, s_dst_xy, s_src_xy;
	reg [31:0] s_size, s_clip_min, s_clip_max, s_resolve;
	reg [31:0] s_src_slice, s_dst_slice, s_depth;
	reg [127:0] s_color;	/* COLOR, COLOR1-COLOR3 */

	always @(posedge clk) begin
		if (!rst_n) begin
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
			s_clip_min <= 32'd0;
			s_clip_max <= 32'd0;
			s_resolve <= 32'd0;
		end else if (st_we) begin
			case (st_idx)
			GHCI_S_BLT_OP: s_op <= st_wdata;
			GHCI_S_BLT_DST_BASE: s_dst_base <= st_wdata;
			GHCI_S_BLT_DST_STRIDE: s_dst_stride <= st_wdata;
			GHCI_S_BLT_SRC_BASE: s_src_base <= st_wdata;
			GHCI_S_BLT_SRC_STRIDE: s_src_stride <= st_wdata;
			GHCI_S_BLT_SRC_SLICE: s_src_slice <= st_wdata;
			GHCI_S_BLT_DST_SLICE: s_dst_slice <= st_wdata;
			GHCI_S_BLT_DEPTH: s_depth <= st_wdata;
			GHCI_S_BLT_DST_XY: s_dst_xy <= st_wdata;
			GHCI_S_BLT_SRC_XY: s_src_xy <= st_wdata;
			GHCI_S_BLT_SIZE: s_size <= st_wdata;
			GHCI_S_BLT_COLOR: s_color[31:0] <= st_wdata;
			GHCI_S_BLT_COLOR1: s_color[63:32] <= st_wdata;
			GHCI_S_BLT_COLOR2: s_color[95:64] <= st_wdata;
			GHCI_S_BLT_COLOR3: s_color[127:96] <= st_wdata;
			GHCI_S_BLT_CLIP_MIN: s_clip_min <= st_wdata;
			GHCI_S_BLT_CLIP_MAX: s_clip_max <= st_wdata;
			GHCI_S_BLT_RESOLVE: s_resolve <= st_wdata;
			default: ;
			endcase
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
	assign psl = p128 ? 3'd4 : bpp == 2'd0 ? 3'd2 : bpp == 2'd1 ? 3'd1 : bpp == 2'd2 ? 3'd3 : 3'd0;
	wire tiled = op == GHCI_BLT_TILE || op == GHCI_BLT_UNTILE;
	assign op_ok = !(p128 && bpp != 2'd0) && !(blend && (psl != 3'd2 || tiled)) &&
		!(rev && tiled) && !(tiled && psl != 3'd1 && psl != 3'd2) &&
		!(keep != 4'd0 && (tiled || blend || psl != 3'd2));

	/* The clipped rectangle. */
	wire clip_en = s_clip_max != 32'd0;
	assign dx = {1'b0, s_dst_xy[15:0]};
	assign dy = {1'b0, s_dst_xy[31:16]};
	wire [16:0] dx_end, dy_end;
	wire [1:0] end_co_unused;

	am_add #(.W(17)) a_dxe (.a(dx), .b({1'b0, s_size[15:0]}), .ci(1'b0), .s(dx_end), .co(end_co_unused[0]));
	am_add #(.W(17)) a_dye (.a(dy), .b({1'b0, s_size[31:16]}), .ci(1'b0), .s(dy_end), .co(end_co_unused[1]));
	wire [16:0] cx0 = {1'b0, s_clip_min[15:0]};
	wire [16:0] cy0 = {1'b0, s_clip_min[31:16]};
	wire [16:0] cx1 = {1'b0, s_clip_max[15:0]};
	wire [16:0] cy1 = {1'b0, s_clip_max[31:16]};
	assign x0 = clip_en && cx0 > dx ? cx0 : dx;
	assign y0 = clip_en && cy0 > dy ? cy0 : dy;
	assign x1 = clip_en && cx1 < dx_end ? cx1 : dx_end;
	assign y1 = clip_en && cy1 < dy_end ? cy1 : dy_end;
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
	wire [31:0] low = low_bits(psl);
	wire [31:0] mask = ~low;
	assign dbase = s_dst_base & mask;
	assign sbase = s_src_base & mask;
	assign dstride = s_dst_stride & mask;
	assign sstride = s_src_stride & mask;
	assign src_slice = s_src_slice & mask;
	assign dst_slice = s_dst_slice & mask;
	assign depth = s_depth[15:0] != 16'd0 ? s_depth[15:0] : 16'd1;

	/* The FILL line. */
	genvar g;
	generate
		for (g = 0; g < LINE_BYTES; g = g + 1) begin : g_fill
			assign fill_line[g*8 +: 8] = s_color[(g & low)*8 +: 8];
		end
	endgenerate

	wire unused_ok = &{1'b0, s_op[31:20], s_op[15:14], s_op[11:10], s_op[7:5], s_op[3],
		s_resolve[31:9], end_co_unused, s_depth[31:16]};
endmodule

`default_nettype wire
