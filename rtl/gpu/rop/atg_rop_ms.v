/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_ms: the render output's multisample coverage (docs/ghci.md
 * section 12.11), between atg_rop_order and atg_rop_ds: per quad the
 * samples that go on (o_smask, bit 4 l + s: sample s of lane l), the
 * depth of every sample (o_sdepth, at bits 32 (4 l + s)) and the colour
 * (alpha to one).
 *
 * MS_CTRL (0x05E): [3:0] = 2 four samples, else one; [8] alpha to
 * coverage; [9] alpha to one.  i_ms = {d_s[127:0], zexp[3:0], smask[15:0]}
 * from atg_su_exp (the direct path: every sample of a lane, its depth).
 *   Four samples: smask = i_ms's & the lanes of i_mask & (alpha to
 *   coverage: a mask of COLOR0's alpha: n = the number of 0.125, 0.375,
 *   0.625, 0.875 it reaches; n = 0 none, 1 {0}, 2 {0, 3}, 3 {0, 1, 3},
 *   4 all; NaN and negative alphas none); the depth of sample s of lane l
 *   is the exported depth (zexp) or clamp01(z + d_s) (fadd, RNE, then NaN
 *   and negatives 0, above 1 one), 16 adds one per cycle (24 cycles).
 *   One sample: bit 4 l = i_mask[l] & i_ms[4 l] (& alpha >= 0.5 with alpha
 *   to coverage), the depth i_depth's (no add).
 * Alpha to one sets COLOR0's alpha to 1.0 after alpha to coverage.  Neither
 * applies to the direct path (i_dbg: DEBUG_COLOR later).  A quad whose
 * smask is 0 is dropped.  States: IDLE → (four samples: Z →) OUT → IDLE.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_ms (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* From atg_rop_order */
	input wire i_valid,
	output wire i_ready,
	input wire [31:0] i_xy,
	input wire [3:0] i_mask,
	input wire [511:0] i_color,
	input wire [127:0] i_depth,
	input wire i_dbg,
	input wire [147:0] i_ms,
	/* To atg_rop_ds */
	output reg o_valid,
	input wire o_ready,
	output reg [31:0] o_xy,
	output reg [15:0] o_smask,
	output reg [511:0] o_color,
	output reg [511:0] o_sdepth,
	output reg o_dbg,
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [31:0] ONE = 32'h3F800000;

	reg ms4, a2c, a2one;
	always @(posedge clk)
		if (!rst_n) begin
			ms4 <= 1'b0;
			a2c <= 1'b0;
			a2one <= 1'b0;
		end else if (st_we && st_idx == GHCI_S_MS_CTRL) begin
			ms4 <= st_wdata[3:0] == 4'd2;
			a2c <= st_wdata[8];
			a2one <= st_wdata[9];
		end

	/* Alpha to coverage of one lane (fp32 alpha). */
	function [3:0] a2c_mask;
		input [31:0] a;
		input four;
		reg [2:0] n;
		begin
			n = 3'd0;
			if (!a[31] && !(a[30:23] == 8'hFF && a[22:0] != 23'd0)) begin
`ifdef MUT_A2C_STEP
				if (a >= 32'h3E800000) n = n + 3'd1;	/* 0.25 */
`else
				if (a >= 32'h3E000000) n = n + 3'd1;	/* 0.125 */
`endif
				if (a >= 32'h3EC00000) n = n + 3'd1;	/* 0.375 */
				if (a >= 32'h3F200000) n = n + 3'd1;	/* 0.625 */
				if (a >= 32'h3F600000) n = n + 3'd1;	/* 0.875 */
			end
			if (!four)
				a2c_mask = {3'd0, !a[31] && a >= 32'h3F000000 &&
					!(a[30:23] == 8'hFF && a[22:0] != 23'd0)};
			else
				a2c_mask = n == 3'd0 ? 4'b0000 : n == 3'd1 ? 4'b0001 :
					n == 3'd2 ? 4'b1001 : n == 3'd3 ? 4'b1011 : 4'b1111;
		end
	endfunction

	/* The quad's sample mask. */
	reg [15:0] sm;
	reg [3:0] am;
	integer l;
	always @(*) begin
		for (l = 0; l < 4; l = l + 1) begin
			am = a2c && !i_dbg ? a2c_mask(i_color[128 * l + 96 +: 32], ms4) : 4'hF;
			sm[4 * l +: 4] = ms4 ? i_ms[4 * l +: 4] & {4{i_mask[l]}} & am :
				{3'd0, i_ms[4 * l] & i_mask[l] & am[0]};
		end
	end

	localparam [1:0] S_IDLE = 2'd0, S_Z = 2'd1, S_OUT = 2'd2;
	reg [1:0] st;
	reg [4:0] c;
	reg [127:0] z;
	reg [127:0] ds;
	reg [3:0] zexp;
	wire [3:0] ci = c[3:0];	/* the add issued: lane ci[3:2], sample ci[1:0] */
	wire [3:0] co = c[3:0] - 4'd4;	/* the result arriving */
	wire fa_o;
	wire [31:0] fa_r;
	atg_rx_fadd fadd (.clk(clk), .rst_n(rst_n), .i_valid(st == S_Z && c < 5'd16),
		.i_a(z[32 * ci[3:2] +: 32]), .i_b(ds[32 * ci[1:0] +: 32]), .i_sub(1'b0),
		.o_valid(fa_o), .o_r(fa_r));
	wire [31:0] zcl = fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > ONE ? ONE : fa_r;

	assign i_ready = st == S_IDLE;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			o_valid <= 1'b0;
			c <= 5'd0;
		end else case (st)
		S_IDLE:
			if (i_valid && sm != 16'd0) begin
				o_xy <= i_xy;
				o_smask <= sm;
				o_dbg <= i_dbg;
				o_color <= i_color;
				if (a2one && !i_dbg)
					for (l = 0; l < 4; l = l + 1)
						o_color[128 * l + 96 +: 32] <= ONE;
				z <= i_depth;
				ds <= i_ms[147:20];
				zexp <= i_ms[19:16];
				c <= 5'd0;
				o_sdepth <= 512'd0;
				if (ms4)
					st <= S_Z;
				else begin
					for (l = 0; l < 4; l = l + 1)
						o_sdepth[128 * l +: 32] <= i_depth[32 * l +: 32];
					o_valid <= 1'b1;
					st <= S_OUT;
				end
			end
		S_Z: begin
			c <= c + 5'd1;
			if (c >= 5'd4)
				o_sdepth[32 * co +: 32] <= zexp[co[3:2]] ? z[32 * co[3:2] +: 32] : zcl;
			if (c == 5'd19) begin
				o_valid <= 1'b1;
				st <= S_OUT;
			end
		end
		default:	/* S_OUT */
			if (o_ready) begin
				o_valid <= 1'b0;
				st <= S_IDLE;
			end
		endcase
	end

	wire unused_ok = &{1'b0, st_wdata[31:10], st_wdata[7:4], fa_o};
endmodule

`default_nettype wire
