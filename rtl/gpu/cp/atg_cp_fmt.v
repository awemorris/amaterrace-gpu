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
	parameter [9:0] BASE = 10'h058,	/* the window's first HCR dword (byte 0x160) */
	parameter HAS_ETC = 0,	/* the TU has the ETC2/EAC decoder */
	parameter [3:0] NRT = 4'd4	/* colour attachments */
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
	always @(posedge clk)
		if (!rst_n)
			idx <= 8'd0;
		else if (hcr_we && hcr_widx == BASE)
			idx <= (idx & ~hcr_wmask[7:0]) | (hcr_wdata[7:0] & hcr_wmask[7:0]);

	wire [25:0] feat = atg_fmt_feat(idx, HAS_ETC != 0);
	wire [9:0] off = hcr_ridx - BASE;
	always @(*)
		if (hcr_ridx < BASE || hcr_ridx >= BASE + 10'd8)
			hcr_rdata = 32'd0;
		else
			case (off[2:0])
			3'd0: hcr_rdata = {24'd0, idx};
			3'd1, 3'd2: hcr_rdata = {19'd0, feat[12:0]};
			3'd3: hcr_rdata = {19'd0, feat[25:13]};
			3'd4: hcr_rdata = {28'd0, NRT};
			default: hcr_rdata = 32'd0;
			endcase

	wire unused_ok = &{1'b0, hcr_wdata[31:8], hcr_wmask[31:8], off[9:3]};
endmodule

`default_nettype wire
