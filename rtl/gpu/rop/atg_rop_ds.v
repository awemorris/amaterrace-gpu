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
	input wire [511:0] q_sdepth,	/* sample s of lane l at 32 (4 l + s) */
	input wire q_dbg,
	input wire q_front,	/* front facing (CAPS[30]; the direct path: 1) */
	input wire [3:0] q_beat,	/* {rt, nocol, first} */
	/* To atg_rop_wb */
	output reg d_valid,
	input wire d_ready,
	output reg [31:0] d_xy,
	output reg [15:0] d_smask,
	output reg [511:0] d_color,
	output reg [3:0] d_beat,
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

	localparam WPL = LINE_BYTES / 4;	/* words per line */
	localparam WB = LINE_SHIFT - 2;	/* word index bits */
	integer k;

	/* STATE: DEBUG_COLOR 0x05C, DS_BASE 0x074, DS_STRIDE 0x075, DEPTH 0x076,
	 * STENCIL_FRONT, _OPS, _BACK 0x077-0x079, DEPTH_BOUNDS_MIN, _MAX 0x08B,
	 * 0x08C. */
	reg [31:0] dbg_color, ds_base, ds_stride, bmin, bmax;
	reg [9:0] depth;
	reg [26:0] sfront, sback;
	reg [24:0] sops;
	reg ms4;
	always @(posedge clk)
		if (!rst_n) begin
			ms4 <= 1'b0;
			dbg_color <= 32'd0;
			ds_base <= 32'd0;
			ds_stride <= 32'd0;
			depth <= 10'd0;
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
			if (st_idx == GHCI_S_DEBUG_COLOR)
				dbg_color <= st_wdata;
			if (st_idx == GHCI_S_DS_BASE)
				ds_base <= st_wdata;
			if (st_idx == GHCI_S_DS_STRIDE)
				ds_stride <= st_wdata;
			if (st_idx == GHCI_S_DEPTH)
				depth <= st_wdata[9:0];
			if (st_idx == GHCI_S_MS_CTRL)
				ms4 <= st_wdata[3:0] == 4'd2;
		end
	/* a test reads the line: exactly one format, and a test enabled */
	wire d16 = depth[7:5] == 3'b100;
	wire one_fmt = depth[7:5] == 3'b001 || depth[7:5] == 3'b010 || d16;
	wire test = one_fmt && (depth[0] || (depth[8] && depth[7:5] == 3'b001) || depth[9]);

	localparam [2:0] S_IDLE = 3'd0, S_ROW = 3'd1, S_RD = 3'd2, S_TEST = 3'd3, S_WR = 3'd4,
		S_OUT = 3'd5;
	reg [2:0] st;
	reg r;	/* row */
	reg [2:0] e;	/* entry of the row: {lane of the row, sample} */
	reg wait_rsp;
	reg [15:0] mask, pm;
	reg [511:0] z;
	reg [31:0] addr;
	reg [LINE_BYTES*8-1:0] line;
	reg wr_any;
	reg front;

	wire [1:0] lane = {r, e[2]};
	wire [3:0] sb = {lane, e[1:0]};	/* the sample's bit */
	wire [31:0] zl = z[32 * sb +: 32];
	/* the entry's byte in the line: (S x + s) ps from the row's address */
	wire [2:0] ent = ms4 ? e : {2'b00, e[2]};
	wire [LINE_SHIFT-1:0] bo = addr[LINE_SHIFT-1:0] +
		(d16 ? {{(LINE_SHIFT-4){1'b0}}, ent, 1'b0} : {{(LINE_SHIFT-5){1'b0}}, ent, 2'b00});
	/* The entry's 32-bit word of the line and its half (D16).  bo is a
	 * multiple of ps (the base and stride of docs/ghci.md section 8.5; the
	 * low bits of one that is not are ignored), so the entry is the whole
	 * word, or the half of it, that holds bo. */
	wire [31:0] lword = line[32 * bo[LINE_SHIFT-1:2] +: 32];
	wire [31:0] stored = d16 ? {16'd0, lword[16 * bo[1] +: 16]} : lword;
	wire pass;
	wire [31:0] wword;
	wire [3:0] wbe;
	atg_rop_dtest dtest (.depth(depth), .sfront(sfront), .sback(sback), .sops(sops),
		.bmin(bmin), .bmax(bmax), .cov(1'b1), .front(front), .zf(zl), .stored(stored),
		.pass(pass), .wword(wword), .wbe(wbe));
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
			pm <= 16'd0;
		end else case (st)
		S_IDLE:
			if (q_valid) begin
				d_xy <= q_xy;
				d_color <= q_dbg ? {4{dbgf[3], dbgf[2], dbgf[1], dbgf[0]}} : q_color;
				d_beat <= q_beat;
`ifdef MUT_DS_BEAT
				if (1'b0)
`else
				if (!q_beat[0])
`endif
					st <= S_OUT;	/* a later beat: the first one's samples */
				else begin
					mask <= q_smask;
					pm <= q_smask;
					z <= q_sdepth;
					front <= q_front || q_dbg;
					r <= 1'b0;
					st <= q_smask == 16'd0 ? S_IDLE : test ? S_ROW : S_OUT;
				end
			end
		S_ROW:
			/* the row's address; skip a row without lanes */
			if (mask[8 * r +: 8] != 8'd0) begin
				addr <= ds_base + ({16'd0, d_xy[31:16]} + {31'd0, r}) * ds_stride +
					(({14'd0, d_xy[15:0], 2'b00} << (ms4 ? 2 : 0)) >> (d16 ? 1 : 0));
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
				e <= 3'd0;
				st <= S_TEST;
			end
		S_TEST: begin
			/* sample e[1:0] of lane {r, e[2]}: the test, the new value into the write line */
			if (mask[sb]) begin
				if (!pass)
					pm[sb] <= 1'b0;
				if (wbe != 4'd0)
					wr_any <= 1'b1;
				/* byte k of the entry's word or half: byte b of the line */
				for (k = 0; k < LINE_BYTES; k = k + 1)
					if (k[LINE_SHIFT-1:2] == bo[LINE_SHIFT-1:2] && (!d16 || k[1] == bo[1]) &&
					    wbe[d16 ? {1'b0, k[0]} : k[1:0]]) begin
						req_wdata[8 * k +: 8] <= wword[{d16 ? {1'b0, k[0]} : k[1:0], 3'b000} +: 8];
						req_be[k] <= 1'b1;
					end
			end
			e <= e + (ms4 ? 3'd1 : 3'd4);
			if (e == (ms4 ? 3'd7 : 3'd4))
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
				d_valid <= pm != 16'd0;
				d_smask <= pm;
				if (pm == 16'd0)
					st <= S_IDLE;
			end else if (d_ready) begin
				d_valid <= 1'b0;
				st <= S_IDLE;
			end
		end
		endcase
	end

	wire unused_ok = &{1'b0, rsp_write, rsp_tag, rsp_error, STENCIL != 0, WPL != 0, WB != 0, bo[0]};
endmodule

`default_nettype wire
