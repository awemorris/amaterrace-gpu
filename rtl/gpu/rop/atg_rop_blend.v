/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_blend: ROP blend: converts fp32 colour to the render-target
 * format, blends with the destination pixels (BLEND factors and ops,
 * BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by atg_rop_wb.
 *
 * Three stages, 4 pixels per cycle: (1) the source to unorm8 (RNE), the
 * destination unpacked to RGBA8; (2) the factor products; (3) the
 * operation, round(x / 255), WRITE_MASK and packing.  The blend runs on
 * 8-bit unorm channels.  With CAPS[30] b_rt chooses the attachment's
 * BLEND word (0x07A, BLEND1-3), write mask (WRITE_MASK[4 rt +: 4]) and
 * format (RT_FORMATS byte rt, or attachment 0's RT_FORMAT code when that
 * byte is 0): VkFormat 44 B8G8R8A8, 37 and 51 R8G8B8A8, 4 R5G6B5, 9 R8,
 * 16 R8G8, 8 A1R5G5B5 (the pixel in the low bytes of its 32-bit lane;
 * formats without alpha read a destination alpha of 255, missing colours 0
 * and are not written); any other format writes nothing.  The constant is
 * BLEND_CONST's bytes, or with ROP_CTRL[1] the fp32 BLEND_CONST_R-A
 * clamped and rounded to 8 bits when written.  See
 * spec/gpu/rop/atg_rop_blend.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_blend #(
	parameter LAT = 3	/* Pipeline cycles from b_valid to b_rvalid (the RTL has 3) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	input wire b_valid,
	input wire [511:0] b_src,
	input wire [127:0] b_dst,
	input wire [3:0] b_mask,
	input wire [1:0] b_rt,
	output reg b_rvalid,
	output reg [127:0] b_pix
);
	`include "ghci_regs.vh"
	/* Internal format codes (F_* in the 3-bit lane format). */
	localparam [2:0] F_BGRA8 = 3'd0, F_RGBA8 = 3'd1, F_565 = 3'd2, F_R8 = 3'd3, F_RG8 = 3'd4,
		F_1555 = 3'd5, F_NONE = 3'd7;
	function [2:0] fcode;
		input [7:0] vk;
		case (vk)
		8'd44: fcode = F_BGRA8;
		8'd37, 8'd51: fcode = F_RGBA8;
		8'd4: fcode = F_565;
		8'd9: fcode = F_R8;
		8'd16: fcode = F_RG8;
		8'd8: fcode = F_1555;
		default: fcode = F_NONE;
		endcase
	endfunction

	/* STATE: RT_FORMAT 0x072, BLEND 0x07A, BLEND_CONST 0x07B, WRITE_MASK 0x07C,
	 * RT_FORMATS 0x07D, BLEND1-3 0x084-0x086, BLEND_CONST_R-A 0x087-0x08A,
	 * ROP_CTRL 0x08D. */
	reg [1:0] fmt0;	/* RT_FORMAT */
	reg [31:0] fmts;	/* RT_FORMATS */
	reg [22:0] bls [0:3];
	reg [31:0] kc8, kcf;	/* BLEND_CONST; the fp32 constants as bytes */
	reg kc_sel;	/* ROP_CTRL[1] */
	reg [15:0] wms;
	wire [1:0] s_k = st_idx[1:0] - 2'd3;	/* BLEND1-3 and BLEND_CONST_R-A: k */
	wire [7:0] kcf_n = f2u8(st_wdata);
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			fmt0 <= 2'd0;
			fmts <= 32'd0;
			for (i = 0; i < 4; i = i + 1)
				bls[i] <= 23'd0;
			kc8 <= 32'd0;
			kcf <= 32'd0;
			kc_sel <= 1'b0;
			wms <= 16'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)
				fmts <= st_wdata;
			if (st_idx == GHCI_S_BLEND)
				bls[0] <= st_wdata[22:0];
			if (st_idx >= GHCI_S_BLEND1 && st_idx < GHCI_S_BLEND1 + 9'd3)
				bls[s_k] <= st_wdata[22:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				kc8 <= st_wdata;
			if (st_idx >= GHCI_S_BLEND_CONST_R && st_idx < GHCI_S_BLEND_CONST_R + 9'd4)
				kcf[8 * s_k +: 8] <= kcf_n;
			if (st_idx == GHCI_S_ROP_CTRL)
				kc_sel <= st_wdata[1];
			if (st_idx == GHCI_S_WRITE_MASK)
				wms <= st_wdata[15:0];
		end
	wire [31:0] kc = kc_sel ? kcf : kc8;
	/* the beat's attachment */
	wire [7:0] fvk = fmts[8 * b_rt +: 8];
	wire [2:0] fmt_n = b_rt == 2'd0 && fvk == 8'd0 ? (fmt0 == 2'd0 ? F_BGRA8 :
		fmt0 == 2'd1 ? F_RGBA8 : F_565) : fcode(fvk);
	wire [22:0] bl_n = bls[b_rt];
	wire [3:0] wm_n = wms[4 * b_rt +: 4];

	/* fp32 to unorm8: NaN, <= 0 to 0, >= 1 to 255, else RNE(f x 255). */
	function [7:0] f2u8;
		input [31:0] f;
		reg [31:0] p;
		reg [41:0] z;
		reg [3:0] t;
		begin
			p = {8'd0, 1'b1, f[22:0]} * 32'd255;
			t = 4'd14 - f[26:23];	/* s - 24 = 126 - e for e in 117..126 */
			z = {p, 10'd0} >> t;
			if (f[30:23] == 8'd0 || f[31] || (f[30:23] == 8'hFF && f[22:0] != 23'd0) ||
			    f[30:23] < 8'd117)
				f2u8 = 8'd0;
			else if (f[30:23] >= 8'd127)
				f2u8 = 8'd255;
			else
				f2u8 = z[41:34] + {7'd0, z[33] && (z[32:0] != 33'd0 || z[34])};
		end
	endfunction

	/* round(x / 255) for x <= 2 x 255 x 255 without a wide adder:
	 * y = x + 128; the low bytes give only a carry,
	 * c = (y[7:0] + y[15:8] + y[18:16]) >> 8, and the result is
	 * (y >> 8) + (y >> 16) + c.  Equal to (y + (y >> 8) + (y >> 16)) >> 8,
	 * checked exact against round(x / 255) over the whole range on
	 * 2026-10-24 (the earlier (x + 128) x 65793 >> 24 used 36-bit adds). */
	/* verilator lint_off UNUSEDSIGNAL */
	function [8:0] div255;
		input [17:0] x;
		reg [18:0] y;
		reg [9:0] lo;
		reg [10:0] hi;
		begin
			y = {1'b0, x} + 19'd128;
			lo = {2'd0, y[7:0]} + {2'd0, y[15:8]} + {7'd0, y[18:16]};
			hi = y[18:8] + {8'd0, y[18:16]} + {9'd0, lo[9:8]};
			div255 = hi[8:0];
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	function [7:0] factor;
		input [3:0] f;
		input [7:0] sc, dc, kcc, sa, da, ka;
		input is_a;
		case (f)
		4'd1: factor = 8'd255;
		4'd2: factor = sc;
		4'd3: factor = ~sc;
		4'd4: factor = dc;
		4'd5: factor = ~dc;
		4'd6: factor = sa;
		4'd7: factor = ~sa;
		4'd8: factor = da;
		4'd9: factor = ~da;
		4'd10: factor = kcc;
		4'd11: factor = ~kcc;
		4'd12: factor = ka;
		4'd13: factor = ~ka;
		4'd14: factor = is_a ? 8'd255 : (sa < ~da ? sa : ~da);
		default: factor = 8'd0;
		endcase
	endfunction

	/* 8 bits to 5 and 6: round(v x 31 / 255), round(v x 63 / 255). */
	/* verilator lint_off UNUSEDSIGNAL */
	function [4:0] div5;
		input [7:0] x;
		reg [8:0] t;
		begin
			t = div255({5'd0, x, 5'd0} - {10'd0, x});
			div5 = t[4:0];
		end
	endfunction
	function [5:0] div6;
		input [7:0] x;
		reg [8:0] t;
		begin
			t = div255({4'd0, x, 6'd0} - {10'd0, x});
			div6 = t[5:0];
		end
	endfunction
	/* verilator lint_on UNUSEDSIGNAL */

	integer l, c;

	/* Stage 1: RGBA8 per lane, channel c of lane l at [32l + 8c]. */
	reg [127:0] s1_n, d1_n;
	reg [31:0] dp;
	always @(*) begin
		for (l = 0; l < 4; l = l + 1) begin
			for (c = 0; c < 4; c = c + 1)
				s1_n[32 * l + 8 * c +: 8] = f2u8(b_src[128 * l + 32 * c +: 32]);
			dp = b_dst[32 * l +: 32];
			case (fmt_n)
			F_BGRA8: d1_n[32 * l +: 32] = {dp[31:24], dp[7:0], dp[15:8], dp[23:16]};
			F_RGBA8: d1_n[32 * l +: 32] = dp;
			F_R8: d1_n[32 * l +: 32] = {8'd255, 16'd0, dp[7:0]};
			F_RG8: d1_n[32 * l +: 32] = {8'd255, 8'd0, dp[15:0]};
			F_1555: d1_n[32 * l +: 32] = {{8{dp[15]}}, dp[4:0], dp[4:2], dp[9:5], dp[9:7],
				dp[14:10], dp[14:12]};
			default: d1_n[32 * l +: 32] = {8'd255, dp[4:0], dp[4:2], dp[10:5], dp[10:9],
				dp[15:11], dp[15:13]};
			endcase
		end
	end
	reg v1;
	reg [3:0] m1, wm1, wm2;
	reg [2:0] fmt1, fmt2;
	reg [22:0] bl1, bl2;
	reg [31:0] kc1;
	reg [127:0] s1, d1, o1;
	always @(posedge clk) begin
		v1 <= rst_n && b_valid;
		m1 <= b_mask;
		fmt1 <= fmt_n;
		bl1 <= bl_n;
		wm1 <= wm_n;
		kc1 <= kc;
		o1 <= b_dst;
		s1 <= s1_n;
		d1 <= d1_n;
	end

	/* Stage 2: p = s x Fs, q = d x Fd per channel (16 bits each, channel 4l + c). */
	reg [255:0] p_n, q_n;
	reg [7:0] sc, dc, kcc;
	always @(*)
		for (l = 0; l < 4; l = l + 1)
			for (c = 0; c < 4; c = c + 1) begin
				sc = s1[32 * l + 8 * c +: 8];
				dc = d1[32 * l + 8 * c +: 8];
				kcc = kc1[8 * c +: 8];
				p_n[16 * (4 * l + c) +: 16] = sc * factor(c == 3 ? bl1[15:12] : bl1[4:1], sc, dc,
					kcc, s1[32 * l + 24 +: 8], d1[32 * l + 24 +: 8], kc1[31:24], c == 3);
				q_n[16 * (4 * l + c) +: 16] = dc * factor(c == 3 ? bl1[19:16] : bl1[8:5], sc, dc,
					kcc, s1[32 * l + 24 +: 8], d1[32 * l + 24 +: 8], kc1[31:24], c == 3);
			end
	reg v2;
	reg [3:0] m2;
	reg [127:0] s2, d2, o2;
	reg [255:0] p2, q2;
	always @(posedge clk) begin
		v2 <= rst_n && v1;
		m2 <= m1;
		fmt2 <= fmt1;
		bl2 <= bl1;
		wm2 <= wm1;
		s2 <= s1;
		d2 <= d1;
		o2 <= o1;
		p2 <= p_n;
		q2 <= q_n;
	end

	/* Stage 3: the operation, the mask, the format. */
	reg [127:0] pix_n;
	reg [31:0] r8;
	reg [2:0] op;
	reg [8:0] v;
	reg [7:0] sv, dv;
	reg [15:0] pp, qq, keep, px16, px15, keep15;
	reg [31:0] px;
	always @(*)
		for (l = 0; l < 4; l = l + 1) begin
			for (c = 0; c < 4; c = c + 1) begin
				op = c == 3 ? bl2[22:20] : bl2[11:9];
				sv = s2[32 * l + 8 * c +: 8];
				dv = d2[32 * l + 8 * c +: 8];
				pp = p2[16 * (4 * l + c) +: 16];
				qq = q2[16 * (4 * l + c) +: 16];
				case (op)
				3'd1: v = pp > qq ? div255({2'd0, pp - qq}) : 9'd0;
				3'd2: v = qq > pp ? div255({2'd0, qq - pp}) : 9'd0;
				3'd3: v = {1'b0, sv < dv ? sv : dv};
				3'd4: v = {1'b0, sv > dv ? sv : dv};
				default: v = div255({2'd0, pp} + {2'd0, qq});
				endcase
				if (!bl2[0])
					v = {1'b0, sv};
				if (v[8])
					v = 9'd255;
				r8[8 * c +: 8] = wm2[c] ? v[7:0] : dv;
			end
			px16 = {div5(r8[7:0]), div6(r8[15:8]), div5(r8[23:16])};
			keep = {wm2[0] ? 5'd0 : 5'h1F, wm2[1] ? 6'd0 : 6'h3F, wm2[2] ? 5'd0 : 5'h1F};
			px15 = {r8[31], div5(r8[7:0]), div5(r8[15:8]), div5(r8[23:16])};
			keep15 = {!wm2[3], wm2[0] ? 5'd0 : 5'h1F, wm2[1] ? 5'd0 : 5'h1F,
				wm2[2] ? 5'd0 : 5'h1F};
			case (fmt2)
			F_BGRA8: px = {r8[31:24], r8[7:0], r8[15:8], r8[23:16]};
			F_RGBA8: px = r8;
			F_R8: px = {o2[32 * l + 8 +: 24], r8[7:0]};
			F_RG8: px = {o2[32 * l + 16 +: 16], r8[15:0]};
			F_1555: px = {o2[32 * l + 16 +: 16], (px15 & ~keep15) | (o2[32 * l +: 16] & keep15)};
			F_565: px = {o2[32 * l + 16 +: 16], (px16 & ~keep) | (o2[32 * l +: 16] & keep)};
			default: px = o2[32 * l +: 32];
			endcase
			pix_n[32 * l +: 32] = m2[l] ? px : o2[32 * l +: 32];
		end
	always @(posedge clk) begin
		b_rvalid <= rst_n && v2;
		b_pix <= pix_n;
	end

	wire unused_ok = &{LAT != 0, bl2[19:12], bl2[8:1]};
endmodule

`default_nettype wire
