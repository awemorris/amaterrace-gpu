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
 * 8-bit unorm channels.  See spec/gpu/rop/atg_rop_blend.md.
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
	output reg b_rvalid,
	output reg [127:0] b_pix
);
	`include "ghci_regs.vh"
	/* STATE: RT_FORMAT 0x072, BLEND 0x07A, BLEND_CONST 0x07B, WRITE_MASK 0x07C. */
	reg [1:0] fmt;
	reg [22:0] bl;
	reg [31:0] kc;
	reg [3:0] wm;
	always @(posedge clk)
		if (!rst_n) begin
			fmt <= 2'd0;
			bl <= 23'd0;
			kc <= 32'd0;
			wm <= 4'd0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt <= st_wdata[1:0];
			if (st_idx == GHCI_S_BLEND)
				bl <= st_wdata[22:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				kc <= st_wdata;
			if (st_idx == GHCI_S_WRITE_MASK)
				wm <= st_wdata[3:0];
		end

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
			case (fmt)
			2'd0: d1_n[32 * l +: 32] = {dp[31:24], dp[7:0], dp[15:8], dp[23:16]};
			2'd1: d1_n[32 * l +: 32] = dp;
			default: d1_n[32 * l +: 32] = {8'd255, dp[4:0], dp[4:2], dp[10:5], dp[10:9],
				dp[15:11], dp[15:13]};
			endcase
		end
	end
	reg v1;
	reg [3:0] m1;
	reg [127:0] s1, d1, o1;
	always @(posedge clk) begin
		v1 <= rst_n && b_valid;
		m1 <= b_mask;
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
				kcc = kc[8 * c +: 8];
				p_n[16 * (4 * l + c) +: 16] = sc * factor(c == 3 ? bl[15:12] : bl[4:1], sc, dc,
					kcc, s1[32 * l + 24 +: 8], d1[32 * l + 24 +: 8], kc[31:24], c == 3);
				q_n[16 * (4 * l + c) +: 16] = dc * factor(c == 3 ? bl[19:16] : bl[8:5], sc, dc,
					kcc, s1[32 * l + 24 +: 8], d1[32 * l + 24 +: 8], kc[31:24], c == 3);
			end
	reg v2;
	reg [3:0] m2;
	reg [127:0] s2, d2, o2;
	reg [255:0] p2, q2;
	always @(posedge clk) begin
		v2 <= rst_n && v1;
		m2 <= m1;
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
	reg [15:0] pp, qq, keep, px16;
	reg [31:0] px;
	always @(*)
		for (l = 0; l < 4; l = l + 1) begin
			for (c = 0; c < 4; c = c + 1) begin
				op = c == 3 ? bl[22:20] : bl[11:9];
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
				if (!bl[0])
					v = {1'b0, sv};
				if (v[8])
					v = 9'd255;
				r8[8 * c +: 8] = wm[c] ? v[7:0] : dv;
			end
			px16 = {div5(r8[7:0]), div6(r8[15:8]), div5(r8[23:16])};
			keep = {wm[0] ? 5'd0 : 5'h1F, wm[1] ? 6'd0 : 6'h3F, wm[2] ? 5'd0 : 5'h1F};
			case (fmt)
			2'd0: px = {r8[31:24], r8[7:0], r8[15:8], r8[23:16]};
			2'd1: px = r8;
			default: px = {o2[32 * l + 16 +: 16], (px16 & ~keep) | (o2[32 * l +: 16] & keep)};
			endcase
			pix_n[32 * l +: 32] = m2[l] ? px : o2[32 * l +: 32];
		end
	always @(posedge clk) begin
		b_rvalid <= rst_n && v2;
		b_pix <= pix_n;
	end

	wire unused_ok = LAT != 0;
endmodule

`default_nettype wire
