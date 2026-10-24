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
 * Depth only so far (the stencil ops are not done yet: a D24S8
 * write keeps the stencil byte).  One quad at a time: per row with
 * covered lanes, read the line, test its two lanes, write the passing
 * ones (DEPTH[1]) and wait for the write's response, so the next quad
 * reads what this one wrote.  Quads with no lane are dropped.  The direct
 * path's quads (q_dbg) get DEBUG_COLOR as fp32 c/255.
 * See spec/gpu/rop/atg_rop_ds.md.
 */

`timescale 1ns / 1ps
`default_nettype none

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
	input wire [3:0] q_mask,
	input wire [511:0] q_color,
	input wire [127:0] q_depth,
	input wire q_dbg,
	/* To atg_rop_wb */
	output reg d_valid,
	input wire d_ready,
	output reg [31:0] d_xy,
	output reg [3:0] d_mask,
	output reg [511:0] d_color,
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
	`include "atg_depth.vh"
	`include "ghci_regs.vh"

	localparam WPL = LINE_BYTES / 4;	/* words per line */
	localparam WB = LINE_SHIFT - 2;	/* word index bits */

	/* STATE: DEBUG_COLOR 0x05C, DS_BASE 0x074, DS_STRIDE 0x075, DEPTH 0x076. */
	reg [31:0] dbg_color, ds_base, ds_stride;
	reg [6:0] depth;
	always @(posedge clk)
		if (!rst_n) begin
			dbg_color <= 32'd0;
			ds_base <= 32'd0;
			ds_stride <= 32'd0;
			depth <= 7'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_DEBUG_COLOR)
				dbg_color <= st_wdata;
			if (st_idx == GHCI_S_DS_BASE)
				ds_base <= st_wdata;
			if (st_idx == GHCI_S_DS_STRIDE)
				ds_stride <= st_wdata;
			if (st_idx == GHCI_S_DEPTH)
				depth <= st_wdata[6:0];
		end
	wire test = depth[0] && depth[6:5] != 2'b00;
	wire f32 = depth[6];
	wire [2:0] func = depth[4:2];

	/* f2u24, fkey and the compare: include/atg_depth.vh (shared with the TU). */

	localparam [2:0] S_IDLE = 3'd0, S_ROW = 3'd1, S_RD = 3'd2, S_TEST = 3'd3, S_WR = 3'd4,
		S_OUT = 3'd5;
	reg [2:0] st;
	reg r;	/* row */
	reg ln;	/* lane of the row */
	reg wait_rsp;
	reg [3:0] mask, pm;
	reg [127:0] z;
	reg [31:0] addr;
	reg [LINE_BYTES*8-1:0] line;
	reg wr_any;

	wire [1:0] lane = {r, ln};
	wire [31:0] zl = z[32 * lane +: 32];
	wire [WB-1:0] wi = addr[LINE_SHIFT-1:2] + {{(WB-1){1'b0}}, ln};
	wire [31:0] stored = line[32 * wi +: 32];
	wire nan = (zl[30:23] == 8'hFF && zl[22:0] != 23'd0) ||
		(stored[30:23] == 8'hFF && stored[22:0] != 23'd0);
	wire [23:0] zu = atg_depth_u24(zl);
	wire pass = f32 ? atg_depth_pass(func, atg_depth_key(zl), atg_depth_key(stored), nan) :
		atg_depth_pass(func, {9'd0, zu}, {9'd0, stored[23:0]}, 1'b0);
	wire [31:0] dbgf [0:3];
	assign dbgf[0] = atg_rop_unorm8(dbg_color[7:0]);
	assign dbgf[1] = atg_rop_unorm8(dbg_color[15:8]);
	assign dbgf[2] = atg_rop_unorm8(dbg_color[23:16]);
	assign dbgf[3] = atg_rop_unorm8(dbg_color[31:24]);

	assign q_ready = st == S_IDLE;
	assign busy = st != S_IDLE || d_valid;
	assign req_tag = 8'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			d_valid <= 1'b0;
			req_valid <= 1'b0;
			wait_rsp <= 1'b0;
		end else case (st)
		S_IDLE:
			if (q_valid) begin
				d_xy <= q_xy;
				d_color <= q_dbg ? {4{dbgf[3], dbgf[2], dbgf[1], dbgf[0]}} : q_color;
				mask <= q_mask;
				pm <= q_mask;
				z <= q_depth;
				r <= 1'b0;
				st <= q_mask == 4'd0 ? S_IDLE : test ? S_ROW : S_OUT;
			end
		S_ROW:
			/* the row's address; skip a row without lanes */
			if (mask[{r, 1'b0}] || mask[{r, 1'b1}]) begin
				addr <= ds_base + ({16'd0, d_xy[31:16]} + {31'd0, r}) * ds_stride +
					{14'd0, d_xy[15:0], 2'b00};
				st <= S_RD;
			end else if (r)
				st <= S_OUT;
			else
				r <= 1'b1;
		S_RD:
			if (!wait_rsp) begin
				if (!req_valid) begin
					req_valid <= 1'b1;
					req_write <= 1'b0;
					req_line <= addr[ADDR_W-1:LINE_SHIFT];
				end else if (req_ready) begin
					req_valid <= 1'b0;
					wait_rsp <= 1'b1;
				end
			end else if (rsp_valid) begin
				wait_rsp <= 1'b0;
				line <= rsp_rdata;
				req_be <= {LINE_BYTES{1'b0}};
				wr_any <= 1'b0;
				ln <= 1'b0;
				st <= S_TEST;
			end
		S_TEST: begin
			/* lane {r, ln}: the test, the new value into the write line */
			if (mask[lane]) begin
				if (!pass)
					pm[lane] <= 1'b0;
				else if (depth[1]) begin
					wr_any <= 1'b1;
					req_wdata[32 * wi +: 32] <= f32 ? zl : {stored[31:24], zu};
					req_be[4 * wi +: 4] <= f32 ? 4'hF : 4'h7;
				end
			end
			ln <= 1'b1;
			if (ln)
				st <= S_WR;
		end
		S_WR:
			if (!wr_any) begin
				st <= r ? S_OUT : S_ROW;
				r <= 1'b1;
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
				st <= r ? S_OUT : S_ROW;
				r <= 1'b1;
			end
		default: begin	/* S_OUT */
			if (!d_valid) begin
				d_valid <= pm != 4'd0;
				d_mask <= pm;
				if (pm == 4'd0)
					st <= S_IDLE;
			end else if (d_ready) begin
				d_valid <= 1'b0;
				st <= S_IDLE;
			end
		end
		endcase
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, STENCIL != 0, addr[1:0],
		WPL != 0};
endmodule

`default_nettype wire
