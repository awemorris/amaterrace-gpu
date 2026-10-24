/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_etc: the ETC2 and EAC block decoder of the TU (VkFormat 147-156,
 * docs/ghci.md section 8.5), combinational: one 4 x 4 block and the
 * texel's column s and row t in it to that texel, written from the
 * Khronos Data Format Specification's ETC2 and EAC text (tools/etcmodel.py
 * is the reference, bit for bit).
 *
 * i_fmt = VkFormat - 147: 0 ETC2_R8G8B8_UNORM, 1 its SRGB, 2
 * ETC2_R8G8B8A1_UNORM, 3 its SRGB, 4 ETC2_R8G8B8A8_UNORM, 5 its SRGB, 6
 * EAC_R11_UNORM, 7 EAC_R11_SNORM, 8 EAC_R11G11_UNORM, 9 EAC_R11G11_SNORM.
 * The block's bytes as stored (byte 0 in [7:0]); each 64-bit half is the
 * big-endian integer of its eight bytes.  The colour modes individual,
 * differential, T, H and planar; RGB8A1 without the individual mode, its
 * opaque bit and transparent index 2 (0, 0, 0, 0); RGBA8's alpha block
 * first; EAC R11 base x 8 + 4 + modifier x multiplier x 8 (multiplier 0:
 * the modifier alone), signed base x 8 + modifier x multiplier x 8 (base
 * -128 as -127), clamped to [0, 2047] and [-1023, 1023].
 * o_kind: 0 RGBA8 UNORM, 1 RGBA8 with sRGB R, G, B, 2 unsigned 11-bit, 3
 * signed 11-bit; o_texel: R in [7:0], G [15:8], B [23:16], A [31:24]
 * (alpha 255 without alpha), or R in [10:0], G in [26:16] (two's
 * complement for kind 3; G 0 for one channel).  i_fmt 10-15: 0, kind 0.
 * See spec/gpu/tu/atg_tu_etc.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_etc (
	input wire [3:0] i_fmt,
	input wire [127:0] i_block,
	input wire [1:0] i_s,
	input wire [1:0] i_t,
	output reg [1:0] o_kind,
	output reg [31:0] o_texel
);
	/* The 64-bit integer of bytes 8k..8k+7, byte 8k the most significant. */
	function [63:0] w64;
		input [127:0] b;
		input k;
		integer i;
		begin
			for (i = 0; i < 8; i = i + 1)
				w64[63 - 8 * i -: 8] = b[64 * k + 8 * i +: 8];
		end
	endfunction

	function [7:0] clamp8;
		input signed [11:0] v;
		clamp8 = v < 0 ? 8'd0 : v > 255 ? 8'd255 : v[7:0];
	endfunction

	function [7:0] ext4;
		input [3:0] c;
		ext4 = {c, c};
	endfunction

	function [7:0] ext5;
		input [4:0] c;
		ext5 = {c, c[4:2]};
	endfunction

	function [7:0] ext6;
		input [5:0] c;
		ext6 = {c, c[5:4]};
	endfunction

	function [7:0] ext7;
		input [6:0] c;
		ext7 = {c, c[6]};
	endfunction

	/* The modifier pairs (a, b) of the individual and differential modes,
	 * and the distances of T and H. */
	function [15:0] mods;
		input [2:0] i;
		case (i)
		3'd0: mods = {8'd8, 8'd2};
		3'd1: mods = {8'd17, 8'd5};
		3'd2: mods = {8'd29, 8'd9};
		3'd3: mods = {8'd42, 8'd13};
		3'd4: mods = {8'd60, 8'd18};
		3'd5: mods = {8'd80, 8'd24};
		3'd6: mods = {8'd106, 8'd33};
		default: mods = {8'd183, 8'd47};
		endcase
	endfunction

	function [6:0] tdist;
		input [2:0] i;
		case (i)
		3'd0: tdist = 7'd3;
		3'd1: tdist = 7'd6;
		3'd2: tdist = 7'd11;
		3'd3: tdist = 7'd16;
		3'd4: tdist = 7'd23;
`ifdef MUT_ETC_TMODE
		3'd5: tdist = 7'd33;	/* a deliberate error (the TB must fail) */
`else
		3'd5: tdist = 7'd32;
`endif
		3'd6: tdist = 7'd41;
		default: tdist = 7'd64;
		endcase
	endfunction

	/* The EAC modifier of table ti, index ix (signed). */
	function signed [4:0] eacm;
		input [3:0] ti;
		input [2:0] ix;
		reg [31:0] r;	/* the row: eight 4-bit magnitudes, the first four negative */
		begin
			case (ti)
			4'd0: r = 32'hE852F963;
			4'd1: r = 32'hC962DA73;
			4'd2: r = 32'hC741D852;
			4'd3: r = 32'hC531D642;
			4'd4: r = 32'hB752C863;
			4'd5: r = 32'hA862B973;
			4'd6: r = 32'hA763B874;
			4'd7: r = 32'hA742B853;
			4'd8: r = 32'h9751A862;
			4'd9: r = 32'h9741A852;
			4'd10: r = 32'h9731A842;
			4'd11: r = 32'h9641A752;
			4'd12: r = 32'h9632A743;
			4'd13: r = 32'h9210A321;
			4'd14: r = 32'h87539864;
			default: r = 32'h86429753;
			endcase
			eacm = ix[2] ? $signed({1'b0, r[4 * ix +: 4]}) : -$signed({1'b0, r[4 * ix +: 4]});
		end
	endfunction

	/* An RGB block's texel (x, y): {A, B, G, R}; punch: RGB8A1. */
	function [31:0] rgb;
		input [63:0] w;
		input [1:0] x;
		input [1:0] y;
		input punch;
		reg [3:0] k;
		reg [1:0] idx;
		reg opq, trn, sub;
		reg [4:0] r5, g5, b5;
		reg signed [5:0] r2, g2, b2;
		reg [23:0] c1, c2, cb, v1, v2;
		reg [15:0] ab;
		reg signed [9:0] m;
		reg [6:0] d;
		reg [23:0] pc;
		reg signed [11:0] q [0:2];
		reg [7:0] o [0:2];
		reg [7:0] h [0:2];
		reg [7:0] v [0:2];
		integer c;
		begin
			k = {x, y};
			idx = {w[{2'b01, k}], w[{2'b00, k}]};
			opq = punch ? w[33] : 1'b1;
			trn = punch && !w[33] && idx == 2'd2;
			r5 = w[63:59];
			g5 = w[55:51];
			b5 = w[47:43];
			r2 = $signed({1'b0, r5}) + $signed({{3{w[58]}}, w[58:56]});
			g2 = $signed({1'b0, g5}) + $signed({{3{w[50]}}, w[50:48]});
			b2 = $signed({1'b0, b5}) + $signed({{3{w[42]}}, w[42:40]});
			pc = 24'd0;
			m = 10'sd0;
			if ((!punch && !w[33]) || (r2 >= 0 && r2 <= 31 && g2 >= 0 && g2 <= 31 &&
			    b2 >= 0 && b2 <= 31)) begin
				/* individual or differential */
				if (!punch && !w[33]) begin
					c1 = {ext4(w[47:44]), ext4(w[55:52]), ext4(w[63:60])};
					c2 = {ext4(w[43:40]), ext4(w[51:48]), ext4(w[59:56])};
				end else begin
					c1 = {ext5(b5), ext5(g5), ext5(r5)};
					c2 = {ext5(b2[4:0]), ext5(g2[4:0]), ext5(r2[4:0])};
				end
				sub = w[32] ? y[1] : x[1];
				ab = mods(sub ? w[36:34] : w[39:37]);
				m = idx == 2'd0 ? $signed({2'b00, ab[7:0]}) : idx == 2'd1 ? $signed({2'b00, ab[15:8]}) :
					idx == 2'd2 ? -$signed({2'b00, ab[7:0]}) : -$signed({2'b00, ab[15:8]});
				if (!opq && !idx[0])
					m = 10'sd0;
				cb = sub ? c2 : c1;
				for (c = 0; c < 3; c = c + 1)
					pc[8 * c +: 8] = clamp8($signed({4'd0, cb[8 * c +: 8]}) + {{2{m[9]}}, m});
			end else if (r2 < 0 || r2 > 31 || g2 < 0 || g2 > 31) begin
				/* T or H */
				if (r2 < 0 || r2 > 31) begin
					c1 = {ext4(w[51:48]), ext4(w[55:52]), ext4({w[60:59], w[57:56]})};
					c2 = {ext4(w[39:36]), ext4(w[43:40]), ext4(w[47:44])};
					d = tdist({w[35:34], w[32]});
				end else begin
					c1 = {ext4({w[51], w[49:47]}), ext4({w[58:56], w[52]}), ext4(w[62:59])};
					c2 = {ext4(w[38:35]), ext4(w[42:39]), ext4(w[46:43])};
					v1 = {c1[7:0], c1[15:8], c1[23:16]};
					v2 = {c2[7:0], c2[15:8], c2[23:16]};
					d = tdist({w[34], w[32], v1 >= v2});
				end
				for (c = 0; c < 3; c = c + 1) begin
					if (r2 < 0 || r2 > 31)
						q[c] = idx == 2'd0 ? $signed({4'd0, c1[8 * c +: 8]}) :
							idx == 2'd2 ? $signed({4'd0, c2[8 * c +: 8]}) :
							idx == 2'd1 ? $signed({4'd0, c2[8 * c +: 8]}) + $signed({5'd0, d}) :
							$signed({4'd0, c2[8 * c +: 8]}) - $signed({5'd0, d});
					else
						q[c] = idx[1] ? (idx[0] ? $signed({4'd0, c2[8 * c +: 8]}) - $signed({5'd0, d}) :
							$signed({4'd0, c2[8 * c +: 8]}) + $signed({5'd0, d})) :
							(idx[0] ? $signed({4'd0, c1[8 * c +: 8]}) - $signed({5'd0, d}) :
							$signed({4'd0, c1[8 * c +: 8]}) + $signed({5'd0, d}));
					pc[8 * c +: 8] = clamp8(q[c]);
				end
			end else begin
				/* planar */
				trn = 1'b0;
				o[0] = ext6(w[62:57]);
				o[1] = ext7({w[56], w[54:49]});
				o[2] = ext6({w[48], w[44:43], w[41:39]});
				h[0] = ext6({w[38:34], w[32]});
				h[1] = ext7(w[31:25]);
				h[2] = ext6(w[24:19]);
				v[0] = ext6(w[18:13]);
				v[1] = ext7(w[12:6]);
				v[2] = ext6(w[5:0]);
				for (c = 0; c < 3; c = c + 1) begin
					q[c] = ($signed({10'd0, x}) * ($signed({4'd0, h[c]}) - $signed({4'd0, o[c]})) +
						$signed({10'd0, y}) * ($signed({4'd0, v[c]}) - $signed({4'd0, o[c]})) +
						$signed({2'd0, o[c], 2'd0}) + 12'sd2) >>> 2;
					pc[8 * c +: 8] = clamp8(q[c]);
				end
			end
			rgb = trn ? 32'd0 : {8'hFF, pc};
		end
	endfunction

	/* An EAC block's value of texel (x, y): s8 the 8-bit alpha (0) or
	 * R11 (1); sg signed R11. */
	function [10:0] eac;
		input [63:0] w;
		input [1:0] x;
		input [1:0] y;
		input r11;
		input sg;
		reg [3:0] k;
		reg [5:0] p;
		reg signed [4:0] m;
		reg signed [13:0] bs, mm, v;
		begin
			k = {x, y};
			p = 6'd45 - 6'd3 * {2'd0, k};
			m = eacm(w[51:48], w[p +: 3]);
			mm = $signed({{9{m[4]}}, m}) * $signed({10'd0, w[55:52]});
			if (!r11) begin
				v = $signed({6'd0, w[63:56]}) + mm;
				eac = {3'd0, v < 0 ? 8'd0 : v > 255 ? 8'd255 : v[7:0]};
			end else if (!sg) begin
				v = $signed({3'd0, w[63:56], 3'd4}) + (w[55:52] == 4'd0 ? $signed({{9{m[4]}}, m}) :
					mm <<< 3);
				eac = v < 0 ? 11'd0 : v > 2047 ? 11'd2047 : v[10:0];
			end else begin
				bs = w[63:56] == 8'h80 ? -14'sd1016 : $signed({{3{w[63]}}, w[63:56], 3'd0});
				v = bs + (w[55:52] == 4'd0 ? $signed({{9{m[4]}}, m}) : mm <<< 3);
				eac = v < -1023 ? 11'h401 : v > 1023 ? 11'h3FF : v[10:0];
			end
		end
	endfunction

	wire [63:0] wa = w64(i_block, 1'b0), wb = w64(i_block, 1'b1);
	reg [31:0] c;
	reg [10:0] a8;	/* the alpha in [7:0] */

	always @(*) begin
		o_kind = 2'd0;
		o_texel = 32'd0;
		c = 32'd0;
		a8 = 11'd0;
		case (i_fmt)
		4'd0, 4'd1, 4'd2, 4'd3: begin
			o_kind = {1'b0, i_fmt[0]};
			o_texel = rgb(wa, i_s, i_t, i_fmt[1]);
		end
		4'd4, 4'd5: begin
			o_kind = {1'b0, i_fmt[0]};
			c = rgb(wb, i_s, i_t, 1'b0);
			a8 = eac(wa, i_s, i_t, 1'b0, 1'b0);
			o_texel = {a8[7:0], c[23:0]};
		end
		4'd6, 4'd7, 4'd8, 4'd9: begin
			o_kind = i_fmt[0] ? 2'd3 : 2'd2;
			o_texel = {5'd0, i_fmt[3] ? eac(wb, i_s, i_t, 1'b1, i_fmt[0]) : 11'd0, 5'd0,
				eac(wa, i_s, i_t, 1'b1, i_fmt[0])};
		end
		default: ;
		endcase
	end

	wire unused_ok = &{1'b0, c[31:24], a8[10:8]};
endmodule

`default_nettype wire
