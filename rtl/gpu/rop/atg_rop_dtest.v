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

module atg_rop_dtest_conv (
	input wire d24,
	input wire [31:0] zf,
	input wire [31:0] stored,
	output wire [31:0] zun,
	output wire [23:0] zu24,
	output wire [15:0] zu16,
	output wire [32:0] zkey,
	output wire [32:0] skey,
	output wire [7:0] s_inc,
	output wire [7:0] s_dec
);
	/* 1. depth bounds stored unorm to fp32 */
	atg_fmt_unorm u_zun (.c(d24 ? stored[23:0] : {8'd0, stored[15:0]}), .w(d24 ? 6'd24 : 6'd16),
		.f(zun));
	/* 3. depth conversions */
	atg_fmt_depth_u24 u_zu24 (.f(zf), .u(zu24));
	atg_fmt_depth_key u_zkey (.f(zf), .k(zkey));
	atg_fmt_depth_key u_skey (.f(stored), .k(skey));
	atg_fmt_f2unorm u_zu16 (.f(zf), .w(6'd16), .u(zu16));

	/* 2. stencil pre-increment and decrement */
	wire [7:0] s_a = stored[31:24];
	wire inc_co_unused, dec_co_unused;
	am_add #(.W(8)) u_s_inc (.a(s_a), .b(8'd1), .ci(1'b0), .s(s_inc), .co(inc_co_unused));
	am_sub #(.W(8)) u_s_dec (.a(s_a), .b(8'd1), .bi(1'b0), .d(s_dec), .bo(dec_co_unused));
endmodule

module atg_rop_dtest_eval (
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
	input wire [31:0] zun,
	input wire [23:0] zu24,
	input wire [15:0] zu16,
	input wire [32:0] zkey,
	input wire [32:0] skey,
	input wire [7:0] s_inc,
	input wire [7:0] s_dec,
	output wire pass,
	output wire [31:0] wword,
	output wire [3:0] wbe
);
	`include "atg_depth.vh"

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
	wire [31:0] za = d32 ? stored : zun;
	wire b_ok = !depth[9] || (fle(bmin, za) && fle(za, bmax));

	/* 3. depth (needed by the stencil's op) */
	wire nan = (zf[30:23] == 8'hFF && zf[22:0] != 23'd0) ||
		(stored[30:23] == 8'hFF && stored[22:0] != 23'd0);
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

	function [7:0] get_snew;
		input [2:0] op;
		input [7:0] sa;
		input [7:0] sref;
		input [7:0] sinc;
		input [7:0] sdec;
		begin
			case (op)
			3'd0: get_snew = sa;
			3'd1: get_snew = 8'd0;
			3'd2: get_snew = sref;
			3'd3: get_snew = (sa == 8'hFF) ? 8'hFF : sinc;
			3'd4: get_snew = (sa == 8'd0) ? 8'd0 : sdec;
			3'd5: get_snew = ~sa;
`ifdef MUT_STENCIL_WRAP
			3'd6: get_snew = (sa == 8'hFF) ? 8'hFF : sinc;	/* wrap as clamp */
			default: get_snew = (sa == 8'd0) ? 8'd0 : sdec;
`else
			3'd6: get_snew = sinc;
			default: get_snew = sdec;
`endif
			endcase
		end
	endfunction

	wire [7:0] s_new_fail  = get_snew(so[2:0], s_a, ss[7:0], s_inc, s_dec);
	wire [7:0] s_new_dpass = get_snew(so[5:3], s_a, ss[7:0], s_inc, s_dec);
	wire [7:0] s_new_dfail = get_snew(so[8:6], s_a, ss[7:0], s_inc, s_dec);

	wire [7:0] s_new = !s_cmp ? s_new_fail : (d_ok ? s_new_dpass : s_new_dfail);
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
	wire [31:0] zun;
	wire [23:0] zu24;
	wire [15:0] zu16;
	wire [32:0] zkey, skey;
	wire [7:0] s_inc, s_dec;

	atg_rop_dtest_conv u_conv (
		.d24(depth[7:5] == 3'b001),
		.zf(zf),
		.stored(stored),
		.zun(zun),
		.zu24(zu24),
		.zu16(zu16),
		.zkey(zkey),
		.skey(skey),
		.s_inc(s_inc),
		.s_dec(s_dec)
	);

	atg_rop_dtest_eval u_eval (
		.depth(depth),
		.sfront(sfront),
		.sback(sback),
		.sops(sops),
		.bmin(bmin),
		.bmax(bmax),
		.cov(cov),
		.front(front),
		.zf(zf),
		.stored(stored),
		.zun(zun),
		.zu24(zu24),
		.zu16(zu16),
		.zkey(zkey),
		.skey(skey),
		.s_inc(s_inc),
		.s_dec(s_dec),
		.pass(pass),
		.wword(wword),
		.wbe(wbe)
	);
endmodule

`default_nettype wire
