/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_fmt: the FMT extended capability (GHCI capability id 10): the
 * register window through which a driver reads, format by format, the
 * VkFormatFeatureFlags of the GPU's fixed-function units, from the table
 * the units use (atg_fmt_feat).
 *
 * Registers (byte offsets from the window at HCR dword BASE): +0x0
 * FMT_INDEX (RW, [7:0] a VkFormat value), +0x4 FMT_OPTIMAL, +0x8
 * FMT_LINEAR (the same), +0xC FMT_BUFFER, +0x10 FMT_LIMITS ([3:0] NRT),
 * +0x14-+0x1C 0.  A write to FMT_INDEX is taken in every CP state; reads
 * have no side effects; hcr_rdata is 0 outside the window (atg_cp_regs
 * ORs it).  See spec/gpu/cp/atg_cp_fmt.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_fmt #(
	parameter [9:0] BASE = 10'h050,	/* the window's first HCR dword (byte 0x140) */
	parameter HAS_ETC = 0,	/* the TU has the ETC2/EAC decoder */
	parameter [3:0] NRT = 4'd4,	/* colour attachments */
	parameter HAS_BILINEAR = 1,	/* bilinear filtering supported in TU */
	parameter HAS_FFILT = 1,	/* TU fast filtering (FP16/FP32 filter linear) */
	parameter HAS_ROP_PACK = 1	/* ROP format packing (Path 2 integer attachments/blend) */
) (
	input wire clk,
	input wire rst_n,
	/* HCR snoop port (atg_cp_regs) */
	input wire hcr_we,
	input wire [9:0] hcr_widx,
	input wire [31:0] hcr_wdata,
	input wire [31:0] hcr_wmask,
	input wire [9:0] hcr_ridx,
	output reg [31:0] hcr_rdata
);
	`include "atg_fmt_info.vh"

	reg [7:0] idx;	/* FMT_INDEX */
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			idx <= 8'd0;
		else if (hcr_we && hcr_widx == BASE)
			idx <= (idx & ~hcr_wmask[7:0]) | (hcr_wdata[7:0] & hcr_wmask[7:0]);

	wire [25:0] feat = atg_fmt_feat(idx, HAS_ETC != 0);
	/* The register's index in the window: only its low 3 bits are used. */
	wire [2:0] off;
	wire off_bo;

	wire [67:0] info = atg_fmt_info(idx);
	wire is_fp = (info[11:9] == ATG_FMT_SFLOAT && !info[12]);
	wire is_p2 = (info[11:9] == ATG_FMT_UINT || info[11:9] == ATG_FMT_SINT ||
	              idx == 8'd100 || idx == 8'd103 || idx == 8'd109);

	wire eff_filter_linear = feat[12] && (HAS_BILINEAR != 0) && (!is_fp || (HAS_FFILT != 0));
	wire eff_color_att = feat[7] && (!is_p2 || (HAS_ROP_PACK != 0));
	wire eff_blend = feat[8] && (!is_p2 || (HAS_ROP_PACK != 0));
	wire eff_blit_dst = feat[11] && (!is_p2 || (HAS_ROP_PACK != 0));

	/* GHCI §4.1 format feature flags layout:
	 * bit 0: SAMPLE (feat[0])
	 * bit 1: FILTER_LINEAR (eff_filter_linear)
	 * bit 2: COLOR_ATTACHMENT (eff_color_att)
	 * bit 3: BLEND (eff_blend)
	 * bit 4: DEPTH_STENCIL (feat[9])
	 * bit 5: VERTEX_BUFFER (feat[19])
	 * bit 6: BLIT_SRC (feat[10])
	 * bit 7: BLIT_DST (eff_blit_dst)
	 * bit 8: STORAGE_IMAGE (0)
	 */
	wire [8:0] fmt_flags = {
		1'b0,
		eff_blit_dst,
		feat[10],
		feat[19],
		feat[9],
		eff_blend,
		eff_color_att,
		eff_filter_linear,
		feat[0]
	};

	am_sub #(.W(3)) off_sub (.a(hcr_ridx[2:0]), .b(BASE[2:0]), .bi(1'b0), .d(off), .bo(off_bo));
	always @(*)
		if (hcr_ridx < BASE || hcr_ridx >= BASE + 10'd8)
			hcr_rdata = 32'd0;
		else
			case (off[2:0])
			3'd0: hcr_rdata = {24'd0, idx};
			3'd1, 3'd2: hcr_rdata = {23'd0, fmt_flags};
			3'd3: hcr_rdata = {19'd0, feat[25:13]};
			3'd4: hcr_rdata = {28'd0, NRT};
			default: hcr_rdata = 32'd0;
			endcase

	wire unused_ok = &{1'b0, hcr_wdata[31:8], hcr_wmask[31:8], off_bo};
endmodule

`default_nettype wire
