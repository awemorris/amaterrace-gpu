/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_dtest: the per-sample depth-bounds, stencil and depth test of
 * one (lane, sample) entry, in Vulkan's order (depth bounds, stencil,
 * depth), and the word to write back; combinational, atg_rop_ds keeps the
 * line and merges the writes.
 *
 * The format is the one bit of DEPTH[7:5] (D24_UNORM_S8_UINT, D32_SFLOAT,
 * D16_UNORM) that is set; with none or more there is no attachment: pass =
 * cov, nothing written.  z_a, the stored depth, is UNORM to fp32 (D16,
 * D24) or the word (D32F).  Bounds (DEPTH[9]): z_a outside [bmin, bmax]
 * (fp32 order, NaN outside) fails, no stencil op.  Stencil (DEPTH[8] and
 * D24S8, the face's state): (ref & cmask) op (s_a & cmask); the fail,
 * pass or depth-fail op (VkStencilOp) into the written mask's bits; byte 3
 * enabled when it changes.  Depth (DEPTH[0]): the compare op against z_a
 * (D16 RNE(clamp01(z) x 65535), D24 atg_fmt_depth_u24, D32F the fp32 order key of
 * atg_fmt_depth_key);
 * written with DEPTH[1] when the stencil and the depth passed.  See
 * spec/gpu/rop/atg_rop_dtest.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_dtest (
	input wire [9:0] depth,
	input wire [26:0] sfront,
	input wire [26:0] sback,
	input wire [24:0] sops,
	input wire [31:0] bmin,
	input wire [31:0] bmax,
	input wire cov,
	input wire front,
	input wire [31:0] zf,
	input wire [31:0] stored,
	output wire pass,
	output wire [31:0] wword,
	output wire [3:0] wbe
);
	`include "atg_depth.vh"
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_fmt_pack.vh"

	wire d24 = depth[7:5] == 3'b001;
	wire d32 = depth[7:5] == 3'b010;
	wire d16 = depth[7:5] == 3'b100;
	wire has = d24 || d32 || d16;

	/* fp32 a <= b, -0 = +0, denormals by value; 0 with a NaN */
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

	/* 1. depth bounds */
	wire [31:0] za = d32 ? stored : d24 ? atg_fmt_unorm(stored[23:0], 6'd24) :
		atg_fmt_unorm({8'd0, stored[15:0]}, 6'd16);
	wire b_ok = !depth[9] || (fle(bmin, za) && fle(za, bmax));

	/* 3. depth (needed by the stencil's op) */
	wire nan = (zf[30:23] == 8'hFF && zf[22:0] != 23'd0) ||
		(stored[30:23] == 8'hFF && stored[22:0] != 23'd0);
	wire [23:0] zu24;
	wire [32:0] zkey, skey;
	atg_fmt_depth_u24 u_zu24 (.f(zf), .u(zu24));
	atg_fmt_depth_key u_zkey (.f(zf), .k(zkey));
	atg_fmt_depth_key u_skey (.f(stored), .k(skey));
	wire [15:0] zu16 = atg_fmt_f2unorm(zf, 6'd16);
	wire d_cmp = d32 ? atg_depth_pass(depth[4:2], zkey, skey, nan) :
		d24 ? atg_depth_pass(depth[4:2], {9'd0, zu24}, {9'd0, stored[23:0]}, 1'b0) :
		atg_depth_pass(depth[4:2], {17'd0, zu16}, {17'd0, stored[15:0]}, 1'b0);
	wire d_ok = !depth[0] || d_cmp;

	/* 2. stencil */
`ifdef MUT_STENCIL_FACE
	wire face = !front;	/* the TB's mutation check: the faces swapped */
`else
	wire face = front;
`endif
	wire [26:0] ss = face ? sfront : sback;
	wire [8:0] so = face ? sops[8:0] : sops[24:16];
	wire s_on = depth[8] && d24;
	wire [7:0] s_a = stored[31:24];
	wire [7:0] cm = ss[15:8];
	wire s_cmp = atg_depth_pass(ss[26:24], {25'd0, ss[7:0] & cm}, {25'd0, s_a & cm}, 1'b0);
	wire [2:0] sop = !s_cmp ? so[2:0] : d_ok ? so[5:3] : so[8:6];
	/* s_a + 1 (ops 3, 6) or - 1 (ops 4, 7) */
	wire [7:0] s_pm;
	wire s_pm_co_unused;
	am_addsub #(.W(8)) u_s_pm (.a(s_a), .b(8'd1), .sub(sop == 3'd4 || sop == 3'd7), .s(s_pm),
		.co(s_pm_co_unused));
	reg [7:0] s_new;
	always @(*)
		case (sop)
		3'd0: s_new = s_a;
		3'd1: s_new = 8'd0;
		3'd2: s_new = ss[7:0];
		3'd3: s_new = s_a == 8'hFF ? 8'hFF : s_pm;
		3'd4: s_new = s_a == 8'd0 ? 8'd0 : s_pm;
		3'd5: s_new = ~s_a;
`ifdef MUT_STENCIL_WRAP
		3'd6: s_new = s_a == 8'hFF ? 8'hFF : s_pm;	/* wrap as clamp */
		default: s_new = s_a == 8'd0 ? 8'd0 : s_pm;
`else
		3'd6: s_new = s_pm;
		default: s_new = s_pm;
`endif
		endcase
	wire [7:0] wm = ss[23:16];
	wire [7:0] s_wr = (s_a & ~wm) | (s_new & wm);
	wire s_ok = !s_on || s_cmp;

	/* the result */
	wire live = cov && has && b_ok;
	assign pass = !has ? cov : live && s_ok && d_ok;
	wire d_wr = live && s_ok && d_ok && depth[1];
	wire s_ch = live && s_on && s_wr != s_a;
	assign wword = d32 ? zf : d24 ? {s_wr, zu24} : {16'd0, zu16};
	assign wbe = d32 ? {4{d_wr}} : d24 ? {s_ch, {3{d_wr}}} : {2'b00, {2{d_wr}}};

	wire unused_ok = &{1'b0, sops[15:9]};
endmodule

`default_nettype wire
