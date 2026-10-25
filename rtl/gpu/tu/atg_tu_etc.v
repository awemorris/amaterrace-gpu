/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_etc: the ETC2 and EAC block decoder of the TU (VkFormat 147-156,
 * docs/ghci.md section 8.5): one 4 x 4 block and the
 * texel's column s and row t in it to that texel, written from the
 * Khronos Data Format Specification's ETC2 and EAC text (tools/etcmodel.py
 * is the reference, bit for bit).  Pipelined: the inputs in cycle 0,
 * o_kind and o_texel in cycle 2 (registers), one texel a cycle; E1 the
 * mode, the colours and the modifier (and EAC's modifier times the
 * multiplier), E2 the sums and the clamps.
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
	input wire clk,
	input wire [3:0] i_fmt,
	input wire [127:0] i_block,
	input wire [1:0] i_s,
	input wire [1:0] i_t,
	output reg [1:0] o_kind,
	output reg [31:0] o_texel
);
	integer c;

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
		input [3:0] x;
		ext4 = {x, x};
	endfunction

	function [7:0] ext5;
		input [4:0] x;
		ext5 = {x, x[4:2]};
	endfunction

	function [7:0] ext6;
		input [5:0] x;
		ext6 = {x, x[5:4]};
	endfunction

	function [7:0] ext7;
		input [6:0] x;
		ext7 = {x, x[6]};
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

	/* -x as 5 bits (x below 16). */
	function [4:0] neg5;
		input [3:0] x;
		case (x)
		4'd0: neg5 = 5'h00;
		4'd1: neg5 = 5'h1F;
		4'd2: neg5 = 5'h1E;
		4'd3: neg5 = 5'h1D;
		4'd4: neg5 = 5'h1C;
		4'd5: neg5 = 5'h1B;
		4'd6: neg5 = 5'h1A;
		4'd7: neg5 = 5'h19;
		4'd8: neg5 = 5'h18;
		4'd9: neg5 = 5'h17;
		4'd10: neg5 = 5'h16;
		4'd11: neg5 = 5'h15;
		4'd12: neg5 = 5'h14;
		4'd13: neg5 = 5'h13;
		4'd14: neg5 = 5'h12;
		default: neg5 = 5'h11;
		endcase
	endfunction

	/* The EAC modifier of table ti, index ix (signed). */
	function [4:0] eacm;
		input [3:0] ti;
		input [2:0] ix;
		reg [31:0] r;	/* the row: eight 4-bit magnitudes, the first four negative */
		reg [3:0] mg;
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
			mg = r[4 * ix +: 4];
			eacm = ix[2] ? {1'b0, mg} : neg5(mg);
		end
	endfunction

	/* The bit position of texel k's 3-bit index in an EAC block: 45 - 3k. */
	function [5:0] eacp;
		input [3:0] k;
		case (k)
		4'd0: eacp = 6'd45;
		4'd1: eacp = 6'd42;
		4'd2: eacp = 6'd39;
		4'd3: eacp = 6'd36;
		4'd4: eacp = 6'd33;
		4'd5: eacp = 6'd30;
		4'd6: eacp = 6'd27;
		4'd7: eacp = 6'd24;
		4'd8: eacp = 6'd21;
		4'd9: eacp = 6'd18;
		4'd10: eacp = 6'd15;
		4'd11: eacp = 6'd12;
		4'd12: eacp = 6'd9;
		4'd13: eacp = 6'd6;
		4'd14: eacp = 6'd3;
		default: eacp = 6'd0;
		endcase
	endfunction

	wire [63:0] wa = w64(i_block, 1'b0), wb = w64(i_block, 1'b1);
	wire [3:0] k = {i_s, i_t};
	wire [1:0] x = i_s, y = i_t;

	/* ---- E1, the colour block: w the block, punch RGB8A1 ---- */
	wire rgbb = i_fmt == 4'd4 || i_fmt == 4'd5;	/* RGBA8: the colour block second */
	wire [63:0] w = rgbb ? wb : wa;
	wire punch = !rgbb && i_fmt[1];
	wire [1:0] idx = {w[{2'b01, k}], w[{2'b00, k}]};
	wire opq = punch ? w[33] : 1'b1;
	wire trn = punch && !w[33] && idx == 2'd2;
	wire [4:0] r5 = w[63:59], g5 = w[55:51], b5 = w[47:43];
	wire [5:0] r2, g2, b2;	/* the differential colour: signed, bit 5 set outside 0-31 */
	wire [2:0] d_nc;

	am_add #(.W(6)) u_r2 (.a({1'b0, r5}), .b({{3{w[58]}}, w[58:56]}), .ci(1'b0), .s(r2),
		.co(d_nc[0]));
	am_add #(.W(6)) u_g2 (.a({1'b0, g5}), .b({{3{w[50]}}, w[50:48]}), .ci(1'b0), .s(g2),
		.co(d_nc[1]));
	am_add #(.W(6)) u_b2 (.a({1'b0, b5}), .b({{3{w[42]}}, w[42:40]}), .ci(1'b0), .s(b2),
		.co(d_nc[2]));

	wire indiv = !punch && !w[33];
	wire idv = indiv || (!r2[5] && !g2[5] && !b2[5]);	/* individual or differential */
	wire tm = !idv && r2[5];	/* T */
	wire hm = !idv && !r2[5] && g2[5];	/* H */
	wire pm = !idv && !r2[5] && !g2[5];	/* planar */

	/* individual and differential: the sub-block's colour and the modifier */
	wire [23:0] i_c1 = indiv ? {ext4(w[47:44]), ext4(w[55:52]), ext4(w[63:60])} :
		{ext5(b5), ext5(g5), ext5(r5)};
	wire [23:0] i_c2 = indiv ? {ext4(w[43:40]), ext4(w[51:48]), ext4(w[59:56])} :
		{ext5(b2[4:0]), ext5(g2[4:0]), ext5(r2[4:0])};
	wire sub = w[32] ? y[1] : x[1];
	wire [15:0] ab = mods(sub ? w[36:34] : w[39:37]);
	wire [7:0] mb = idx[0] ? ab[15:8] : ab[7:0];
	/* T and H: the colours and the distance */
	wire [23:0] t_c1 = {ext4(w[51:48]), ext4(w[55:52]), ext4({w[60:59], w[57:56]})};
	wire [23:0] t_c2 = {ext4(w[39:36]), ext4(w[43:40]), ext4(w[47:44])};
	wire [23:0] h_c1 = {ext4({w[51], w[49:47]}), ext4({w[58:56], w[52]}), ext4(w[62:59])};
	wire [23:0] h_c2 = {ext4(w[38:35]), ext4(w[42:39]), ext4(w[46:43])};
	wire [23:0] h_v1 = {h_c1[7:0], h_c1[15:8], h_c1[23:16]};
	wire [23:0] h_v2 = {h_c2[7:0], h_c2[15:8], h_c2[23:16]};
	wire [6:0] d = tm ? tdist({w[35:34], w[32]}) : tdist({w[34], w[32], h_v1 >= h_v2});
	/* The base colour and a signed offset of all three channels: q = base +
	 * delta (individual, differential, T, H). */
	wire [9:0] dmag = idv ? {2'b00, mb} : {3'd0, d};
	wire [9:0] dneg;
	wire dneg_nc;

	am_sub #(.W(10)) u_dneg (.a(10'd0), .b(dmag), .bi(1'b0), .d(dneg), .bo(dneg_nc));

	reg [23:0] base;
	reg [9:0] delta;
	always @(*) begin
		if (idv) begin
			base = sub ? i_c2 : i_c1;
			delta = !opq && !idx[0] ? 10'd0 : idx[1] ? dneg : dmag;
		end else if (tm) begin
			base = idx == 2'd0 ? t_c1 : t_c2;
			delta = idx == 2'd1 ? dmag : idx == 2'd3 ? dneg : 10'd0;
		end else begin
			base = idx[1] ? h_c2 : h_c1;
			delta = idx[0] ? dneg : dmag;
		end
	end

	/* planar: (x (h - o) + y (v - o) + 4 o + 2) >> 2, as t1 + 2 t2 + 4 o + 2
	 * with t1 = x[0] (h - o) + y[0] (v - o), t2 = x[1] (h - o) + y[1] (v - o)
	 * (12-bit signed, as the reference) */
	wire [23:0] po = {ext6({w[48], w[44:43], w[41:39]}), ext7({w[56], w[54:49]}), ext6(w[62:57])};
	wire [23:0] ph = {ext6(w[24:19]), ext7(w[31:25]), ext6({w[38:34], w[32]})};
	wire [23:0] pv = {ext6(w[5:0]), ext7(w[12:6]), ext6(w[18:13])};
	wire [11:0] dh [0:2];
	wire [11:0] dv [0:2];
	wire [11:0] t1 [0:2];
	wire [11:0] t2 [0:2];
	wire [11:0] p_nc;
	genvar g;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_pl
		am_sub #(.W(12)) u_dh (.a({4'd0, ph[g*8 +: 8]}), .b({4'd0, po[g*8 +: 8]}), .bi(1'b0),
			.d(dh[g]), .bo(p_nc[g*4]));
		am_sub #(.W(12)) u_dv (.a({4'd0, pv[g*8 +: 8]}), .b({4'd0, po[g*8 +: 8]}), .bi(1'b0),
			.d(dv[g]), .bo(p_nc[g*4 + 1]));
		am_add #(.W(12)) u_t1 (.a(x[0] ? dh[g] : 12'd0), .b(y[0] ? dv[g] : 12'd0), .ci(1'b0),
			.s(t1[g]), .co(p_nc[g*4 + 2]));
		am_add #(.W(12)) u_t2 (.a(x[1] ? dh[g] : 12'd0), .b(y[1] ? dv[g] : 12'd0), .ci(1'b0),
			.s(t2[g]), .co(p_nc[g*4 + 3]));
	end
	endgenerate

	/* ---- E1, the EAC blocks (wa: R or alpha, wb: G) ---- */
	wire r11 = !rgbb;	/* R11 (not RGBA8's 8-bit alpha) */
	wire sg = i_fmt[0];	/* signed R11 */
	wire [13:0] e_vb [0:1];	/* the base */
	wire [13:0] e_va [0:1];	/* the modifier term */
	wire [5:0] e_nc;
	generate
	for (g = 0; g < 2; g = g + 1) begin : g_eac
		wire [63:0] ew = g == 0 ? wa : wb;
		wire [4:0] m = eacm(ew[51:48], ew[eacp(k) +: 3]);
		wire [13:0] ms = {{9{m[4]}}, m};
		wire [3:0] mu = ew[55:52];
		wire [13:0] s01, s23, mm;
		/* m times the multiplier: shifts and adds */
		am_add #(.W(14)) u_s01 (.a(mu[0] ? ms : 14'd0), .b(mu[1] ? {ms[12:0], 1'b0} : 14'd0),
			.ci(1'b0), .s(s01), .co(e_nc[g*3]));
		am_add #(.W(14)) u_s23 (.a(mu[2] ? {ms[11:0], 2'b00} : 14'd0),
			.b(mu[3] ? {ms[10:0], 3'b000} : 14'd0), .ci(1'b0), .s(s23), .co(e_nc[g*3 + 1]));
		am_add #(.W(14)) u_mm (.a(s01), .b(s23), .ci(1'b0), .s(mm), .co(e_nc[g*3 + 2]));
		assign e_vb[g] = !r11 ? {6'd0, ew[63:56]} : !sg ? {3'd0, ew[63:56], 3'd4} :
			ew[63:56] == 8'h80 ? -14'sd1016 : {{3{ew[63]}}, ew[63:56], 3'd0};
		assign e_va[g] = !r11 ? mm : mu == 4'd0 ? ms : {mm[10:0], 3'b000};
	end
	endgenerate

	/* ---- E1 registers ---- */
	reg [3:0] fmt1;
	reg trn1, pm1;
	reg [23:0] base1, po1;
	reg [9:0] delta1;
	reg [11:0] t1_1 [0:2];
	reg [11:0] t2_1 [0:2];
	reg [13:0] vb1 [0:1];
	reg [13:0] va1 [0:1];
	always @(posedge clk) begin
		fmt1 <= i_fmt;
		trn1 <= trn && !pm;
		pm1 <= pm;
		base1 <= base;
		delta1 <= delta;
		po1 <= po;
		for (c = 0; c < 3; c = c + 1) begin
			t1_1[c] <= t1[c];
			t2_1[c] <= t2[c];
		end
		for (c = 0; c < 2; c = c + 1) begin
			vb1[c] <= e_vb[c];
			va1[c] <= e_va[c];
		end
	end

	/* ---- E2: the sums and the clamps ---- */
	wire [11:0] qn [0:2];	/* base + delta */
	wire [11:0] qa [0:2];
	wire [11:0] qp [0:2];	/* planar, before >> 2 */
	wire [13:0] ev [0:1];
	wire [10:0] q_nc;
	wire [23:0] pc;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_q
		am_add #(.W(12)) u_qn (.a({4'd0, base1[g*8 +: 8]}), .b({{2{delta1[9]}}, delta1}),
			.ci(1'b0), .s(qn[g]), .co(q_nc[g*3]));
		am_add #(.W(12)) u_qa (.a(t1_1[g]), .b({t2_1[g][10:0], 1'b0}), .ci(1'b0), .s(qa[g]),
			.co(q_nc[g*3 + 1]));
		am_add #(.W(12)) u_qp (.a(qa[g]), .b({2'd0, po1[g*8 +: 8], 2'b10}), .ci(1'b0),
			.s(qp[g]), .co(q_nc[g*3 + 2]));
		assign pc[g*8 +: 8] = pm1 ? clamp8({{2{qp[g][11]}}, qp[g][11:2]}) : clamp8(qn[g]);
	end
	for (g = 0; g < 2; g = g + 1) begin : g_ev
		am_add #(.W(14)) u_ev (.a(vb1[g]), .b(va1[g]), .ci(1'b0), .s(ev[g]), .co(q_nc[9 + g]));
	end
	endgenerate

	/* EAC: 8-bit alpha, unsigned or signed R11 */
	function [10:0] eacc;
		input signed [13:0] v;
		input e_r11, e_sg;
		eacc = !e_r11 ? {3'd0, v < 0 ? 8'd0 : v > 255 ? 8'd255 : v[7:0]} :
			!e_sg ? (v < 0 ? 11'd0 : v > 2047 ? 11'd2047 : v[10:0]) :
			(v < -1023 ? 11'h401 : v > 1023 ? 11'h3FF : v[10:0]);
	endfunction

	wire [31:0] rgbv = trn1 ? 32'd0 : {8'hFF, pc};
	wire [10:0] ea = eacc(ev[0], fmt1 != 4'd4 && fmt1 != 4'd5, fmt1[0]);
	wire [10:0] eb = eacc(ev[1], 1'b1, fmt1[0]);

	always @(posedge clk) begin
		o_kind <= 2'd0;
		o_texel <= 32'd0;
		case (fmt1)
		4'd0, 4'd1, 4'd2, 4'd3: begin
			o_kind <= {1'b0, fmt1[0]};
			o_texel <= rgbv;
		end
		4'd4, 4'd5: begin
			o_kind <= {1'b0, fmt1[0]};
			o_texel <= {ea[7:0], rgbv[23:0]};
		end
		4'd6, 4'd7, 4'd8, 4'd9: begin
			o_kind <= fmt1[0] ? 2'd3 : 2'd2;
			o_texel <= {5'd0, fmt1[3] ? eb : 11'd0, 5'd0, ea};
		end
		default: ;
		endcase
	end

	wire unused_ok = &{1'b0, d_nc, dneg_nc, p_nc, e_nc, q_nc, opq, hm, ea[10:8], rgbv[31:24]};
endmodule

`default_nettype wire
