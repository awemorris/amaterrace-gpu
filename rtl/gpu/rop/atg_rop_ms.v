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
 * coverage; [9] alpha to one.  i_aux[147:0] = {d_s, zexp, smask}
 * from atg_su_exp (the direct path: every sample of a lane, its depth).
 *   Four samples: smask = i_aux's & the lanes of i_mask & (alpha to
 *   coverage: a mask of COLOR0's alpha: n = the number of 0.125, 0.375,
 *   0.625, 0.875 it reaches; n = 0 none, 1 {0}, 2 {0, 3}, 3 {0, 1, 3},
 *   4 all; NaN and negative alphas none); the depth of sample s of lane l
 *   is the exported depth (zexp) or clamp01(z + d_s) (fadd, RNE, then NaN
 *   and negatives 0, above 1 one), 16 adds one per cycle (24 cycles).
 *   One sample: bit 4 l = i_mask[l] & i_aux[4 l] (& alpha >= 0.5 with alpha
 *   to coverage), the depth i_depth's (no add).
 * Alpha to one sets COLOR0's alpha to 1.0 after alpha to coverage.  Neither
 * applies to the direct path (i_dbg: DEBUG_COLOR later).  A quad whose
 * smask is 0 is dropped.  States: IDLE → (four samples: Z →) OUT → IDLE.
 * CAPS[30]: with DEPTH_CLAMP[1] (0x059, Vulkan's depth clipping in the
 * RX) z + d_s is not clamped to [0, 1]; with DEPTH_CLAMP[0] every
 * sample's depth (exported or not) is clamped to [min(n, f), max(n, f)],
 * n = VIEWPORT z offset (0x055), f = n + z scale (0x054; one fadd when
 * either is written, while the ROP is idle), a NaN to the minimum.  i_aux
 * [148] is the facing, passed on as o_front.
 * Beats (CAPS[30]): a quad comes as one beat per colour attachment; the
 * first (i_aux[150]) gives the coverage, the depths and, for alpha to
 * coverage, the alpha (the lowest attachment exported: attachment 0's
 * when it is); the later beats of the quad keep its o_smask and o_sdepth
 * (dropped with it), and alpha to one applies to every beat.  o_beat =
 * {rt, nocol, first} of i_aux[153:152], [149], [150].
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
	input wire [511:0] i_color1,
	input wire [127:0] i_depth,
	input wire i_dbg,
	input wire [154:0] i_aux,	/* {rt[2:0], qlast, qfirst, nocol, front, d_s, zexp, smask} */
	/* To atg_rop_ds */
	output reg o_valid,
	input wire o_ready,
	output reg [31:0] o_xy,
	output reg [15:0] o_smask,
	output reg [511:0] o_color,
	output reg [511:0] o_color1,
	output reg [511:0] o_sdepth,
	output reg o_dbg,
	output reg o_front,
	output reg [4:0] o_beat,	/* {rt[2:0], nocol, first} */
	output wire busy
);
	`include "ghci_regs.vh"
	localparam [31:0] ONE = 32'h3F800000;

	/* a <= b (fp32 order, -0 = +0); 0 with a NaN */
	function fle;
		input [31:0] a, b;
		reg [32:0] ka, kb;
		begin
			/* the signed keys ka <= kb, from the signs and the magnitudes */
			ka = {2'd0, a[30:0]};
			kb = {2'd0, b[30:0]};
			fle = !(a[30:23] == 8'hFF && a[22:0] != 23'd0) &&
				!(b[30:23] == 8'hFF && b[22:0] != 23'd0) &&
				(a[31] ? (b[31] ? ka >= kb : 1'b1) : (b[31] ? ka == 0 && kb == 0 : ka <= kb));
		end
	endfunction

	reg ms4, a2c, a2one;
	reg [1:0] dc;	/* DEPTH_CLAMP */
	reg [31:0] vzs, vzo, vzf;	/* VIEWPORT z scale, z offset; f = z offset + z scale */
	reg [31:0] zmin, zmax;
	reg [3:0] zt;	/* the fadd's issues of f, by age */
	wire vz_we = st_we && (st_idx == GHCI_S_VIEWPORT + 9'd4 || st_idx == GHCI_S_VIEWPORT + 9'd5);
	always @(posedge clk)
		if (!rst_n) begin
			ms4 <= 1'b0;
			a2c <= 1'b0;
			a2one <= 1'b0;
			dc <= 2'd0;
			vzs <= 32'd0;
			vzo <= 32'd0;
			vzf <= 32'd0;
			zmin <= 32'd0;
			zmax <= ONE;
			zt <= 4'd0;
		end else begin
			zt <= {zt[2:0], zf_go};
			if (st_we && st_idx == GHCI_S_MS_CTRL) begin
				ms4 <= st_wdata[3:0] == 4'd2;
				a2c <= st_wdata[8];
				a2one <= st_wdata[9];
			end
			if (st_we && st_idx == GHCI_S_DEPTH_CLAMP)
				dc <= st_wdata[1:0];
			if (st_we && st_idx == GHCI_S_VIEWPORT + 9'd4)
				vzs <= st_wdata;
			if (st_we && st_idx == GHCI_S_VIEWPORT + 9'd5)
				vzo <= st_wdata;
			if (zt[3]) begin
				vzf <= fa_r;
				zmin <= fle(vzo, fa_r) ? vzo : fa_r;
				zmax <= fle(vzo, fa_r) ? fa_r : vzo;
			end
		end
	/* f is added the cycle after a write of either word */
	reg zf_prep;
	reg zf_go;
	always @(posedge clk) begin
		if (!rst_n) begin
			zf_prep <= 1'b0;
			zf_go <= 1'b0;
		end else begin
			zf_prep <= vz_we;
			zf_go <= zf_prep;
		end
	end

	/* depth clamp: NaN to zmin */
	function [31:0] zclamp;
		input [31:0] x, lo, hi;
		zclamp = (x[30:23] == 8'hFF && x[22:0] != 23'd0) || fle(x, lo) ? lo :
			fle(hi, x) ? hi : x;
	endfunction

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
			sm[4 * l +: 4] = ms4 ? i_aux[4 * l +: 4] & {4{i_mask[l]}} & am :
				{3'd0, i_aux[4 * l] & i_mask[l] & am[0]};
		end
	end

	localparam [1:0] S_IDLE = 2'd0, S_Z = 2'd1, S_OUT = 2'd2;
	reg [1:0] st;
	reg [4:0] c;
	reg [127:0] z;
	reg [127:0] ds;
	reg [3:0] zexp;
	reg [31:0] zs_pipe;
	reg [3:0] co_pipe;
	reg zs_pipe_en;
	reg [31:0] fa_in_a;
	reg [31:0] fa_in_b;
	wire [3:0] co;	/* the result arriving: c - 4 */
	wire [4:0] c1;	/* c + 1 */
	wire co_bo_unused, c1_co_unused;
	am_sub #(.W(4)) u_co (.a(c[3:0]), .b(4'd4), .bi(1'b0), .d(co), .bo(co_bo_unused));
	am_add #(.W(5)) u_c1 (.a(c), .b(5'd0), .ci(1'b1), .s(c1), .co(c1_co_unused));
	wire fa_o;
	wire [31:0] fa_r;
	atg_rop_fadd #(.LAT(4)) fadd (.clk(clk), .rst_n(rst_n), .i_valid((st == S_Z && c < 5'd16) || zf_go),
		.i_a(fa_in_a), .i_b(fa_in_b),
		.i_sub(1'b0), .o_valid(fa_o), .o_r(fa_r));
	/* earlier: clamp01; DEPTH_CLAMP[1]: as added */
	wire [31:0] zcl = !dc[1] ? (fa_r[31] || (fa_r[30:23] == 8'hFF && fa_r[22:0] != 23'd0) ? 32'd0 :
		fa_r > ONE ? ONE : fa_r) : fa_r;
	wire [31:0] zs4 = zexp[co[3:2]] ? z[32 * co[3:2] +: 32] : zcl;
	wire [31:0] zs4c = dc[0] ? zclamp(zs4, zmin, zmax) : zs4;
	wire [127:0] d1c;
	genvar g;
	generate
	for (g = 0; g < 4; g = g + 1) begin : g_d1
		assign d1c[32 * g +: 32] = dc[0] ? zclamp(i_depth[32 * g +: 32], zmin, zmax) :
			i_depth[32 * g +: 32];
	end
	endgenerate

	wire first = i_aux[150];
	reg drop;	/* the quad's first beat had no sample */

	assign i_ready = st == S_IDLE;
	assign busy = st != S_IDLE;

	always @(posedge clk) begin
		if (!rst_n) begin
			st <= S_IDLE;
			o_valid <= 1'b0;
			o_color1 <= 512'd0;
			o_beat <= 5'd0;
			c <= 5'd0;
			drop <= 1'b0;
			zs_pipe <= 32'd0;
			co_pipe <= 4'd0;
			zs_pipe_en <= 1'b0;
			fa_in_a <= 32'd0;
			fa_in_b <= 32'd0;
		end else begin
			if (zf_prep) begin
				fa_in_a <= vzo;
				fa_in_b <= vzs;
			end
			case (st)
			S_IDLE:
				if (i_valid && !first) begin
					/* a later beat: the quad's coverage and depths stay */
					o_xy <= i_xy;
					o_dbg <= i_dbg;
					o_beat <= {i_aux[154:152], i_aux[149], 1'b0};
					o_color <= i_color;
					o_color1 <= i_color1;
					if (a2one && !i_dbg)
						for (l = 0; l < 4; l = l + 1)
							o_color[128 * l + 96 +: 32] <= ONE;
					if (!drop) begin
						o_valid <= 1'b1;
						st <= S_OUT;
					end
				end else if (i_valid) begin
					drop <= sm == 16'd0;
					o_xy <= i_xy;
					o_smask <= sm;
					o_dbg <= i_dbg;
					o_front <= i_aux[148];
					o_beat <= {i_aux[154:152], i_aux[149], 1'b1};
					o_color <= i_color;
					o_color1 <= i_color1;
					if (a2one && !i_dbg)
						for (l = 0; l < 4; l = l + 1)
							o_color[128 * l + 96 +: 32] <= ONE;
					z <= i_depth;
					ds <= i_aux[147:20];
					fa_in_a <= i_depth[31:0];
					fa_in_b <= i_aux[20 +: 32];
					zexp <= i_aux[19:16];
					c <= 5'd0;
					o_sdepth <= 512'd0;
					zs_pipe_en <= 1'b0;
					if (sm == 16'd0)
						st <= S_IDLE;
					else if (ms4)
						st <= S_Z;
					else begin
						for (l = 0; l < 4; l = l + 1)
							o_sdepth[128 * l +: 32] <= d1c[32 * l +: 32];
						o_valid <= 1'b1;
						st <= S_OUT;
					end
				end
			S_Z: begin
				c <= c1;
				fa_in_a <= z[32 * c1[3:2] +: 32];
				fa_in_b <= ds[32 * c1[1:0] +: 32];
				zs_pipe <= zs4c;
				co_pipe <= co;
				zs_pipe_en <= (c >= 5'd4);
				if (zs_pipe_en)
					o_sdepth[32 * co_pipe +: 32] <= zs_pipe;
				if (c == 5'd20) begin
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
	end

	wire unused_ok = &{1'b0, st_wdata[31:10], st_wdata[7:4], fa_o};
endmodule

`default_nettype wire
