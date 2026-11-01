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
 * o_kind and o_texel in cycle 4 (registers), one texel a cycle; E0 the
 * words; E1 the mode, the colours and the modifier, EAC's modifier; E1b
 * planar's terms, EAC's modifier times the multiplier; E2 the sums and the
 * clamps.
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
	(* extract_reset = "no" *) output reg [31:0] o_texel
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

	/* ---- E0: the block's two words, the colour block's word, pre-additions ---- */
	wire [63:0] wa_i = w64(i_block, 1'b0), wb_i = w64(i_block, 1'b1);
	wire rgbb_i_raw = i_fmt == 4'd4 || i_fmt == 4'd5;	/* RGBA8: the colour block second */
	(* dont_touch = "true" *) wire [7:0] rgbb_i_s = {8{rgbb_i_raw}};
	(* keep = "true" *) wire rgbb_i_eac = !rgbb_i_raw;
	(* keep = "true" *) wire [63:0] w_i = {
		rgbb_i_s[7] ? wb_i[63:56] : wa_i[63:56],
		rgbb_i_s[6] ? wb_i[55:48] : wa_i[55:48],
		rgbb_i_s[5] ? wb_i[47:40] : wa_i[47:40],
		rgbb_i_s[4] ? wb_i[39:32] : wa_i[39:32],
		rgbb_i_s[3] ? wb_i[31:24] : wa_i[31:24],
		rgbb_i_s[2] ? wb_i[23:16] : wa_i[23:16],
		rgbb_i_s[1] ? wb_i[15:8]  : wa_i[15:8],
		rgbb_i_s[0] ? wb_i[7:0]   : wa_i[7:0]
	};

	wire [5:0] r2_i, g2_i, b2_i;
	wire [2:0] d_nc;
	am_add #(.W(6)) u_r2 (.a({1'b0, w_i[63:59]}), .b({{3{w_i[58]}}, w_i[58:56]}), .ci(1'b0),
		.s(r2_i), .co(d_nc[0]));
	am_add #(.W(6)) u_g2 (.a({1'b0, w_i[55:51]}), .b({{3{w_i[50]}}, w_i[50:48]}), .ci(1'b0),
		.s(g2_i), .co(d_nc[1]));
	am_add #(.W(6)) u_b2 (.a({1'b0, w_i[47:43]}), .b({{3{w_i[42]}}, w_i[42:40]}), .ci(1'b0),
		.s(b2_i), .co(d_nc[2]));

	wire [23:0] h_c1_i = {ext4({w_i[51], w_i[49:47]}), ext4({w_i[58:56], w_i[52]}),
		ext4(w_i[62:59])};
	wire [23:0] h_c2_i = {ext4(w_i[38:35]), ext4(w_i[42:39]), ext4(w_i[46:43])};
	wire [23:0] h_v1_i = {h_c1_i[7:0], h_c1_i[15:8], h_c1_i[23:16]};
	wire [23:0] h_v2_i = {h_c2_i[7:0], h_c2_i[15:8], h_c2_i[23:16]};
	wire [23:0] hcmp_d;
	wire hcmp_bo;
	am_sub #(.W(24)) u_hcmp (.a(h_v1_i), .b(h_v2_i), .bi(1'b0), .d(hcmp_d), .bo(hcmp_bo));

	wire [23:0] po_i = {ext6({w_i[48], w_i[44:43], w_i[41:39]}), ext7({w_i[56], w_i[54:49]}),
		ext6(w_i[62:57])};
	wire [23:0] ph_i = {ext6(w_i[24:19]), ext7(w_i[31:25]), ext6({w_i[38:34], w_i[32]})};
	wire [23:0] pv_i = {ext6(w_i[5:0]), ext7(w_i[12:6]), ext6(w_i[18:13])};
	wire [11:0] dh_i [0:2];
	wire [11:0] dv_i [0:2];
	wire [5:0] p_nc;
	genvar g;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_pl
		am_sub #(.W(12)) u_dh (.a({4'd0, ph_i[g*8 +: 8]}), .b({4'd0, po_i[g*8 +: 8]}), .bi(1'b0),
			.d(dh_i[g]), .bo(p_nc[g*2]));
		am_sub #(.W(12)) u_dv (.a({4'd0, pv_i[g*8 +: 8]}), .b({4'd0, po_i[g*8 +: 8]}), .bi(1'b0),
			.d(dv_i[g]), .bo(p_nc[g*2 + 1]));
	end
	endgenerate

	/* ---- E0-E2, the EAC blocks (wa_i: R or alpha, wb_i: G) ---- */
	wire [10:0] ea, eb;

	atg_tu_eac eac_a (.clk(clk), .i_w(wa_i), .i_k({i_s, i_t}), .i_r11(rgbb_i_eac),
		.i_sg(i_fmt[0]), .o_v(ea));
	atg_tu_eac eac_b (.clk(clk), .i_w(wb_i), .i_k({i_s, i_t}), .i_r11(1'b1),
		.i_sg(i_fmt[0]), .o_v(eb));

	(* extract_reset = "no", max_fanout = 16 *) reg [63:0] w;
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] fmt0;
	(* extract_reset = "no", max_fanout = 16 *) reg [1:0] x, y;
	(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [1:0] x_t [0:2];
	(* extract_reset = "no", keep = "true", equivalent_register_removal = "no" *) reg [1:0] y_t [0:2];
	(* extract_reset = "no", max_fanout = 16 *) reg [5:0] r2, g2, b2;
	(* extract_reset = "no" *) reg h_ge_0;
	(* extract_reset = "no", max_fanout = 16 *) reg [11:0] dh0 [0:2];
	(* extract_reset = "no", max_fanout = 16 *) reg [11:0] dv0 [0:2];
	always @(posedge clk) begin
		w <= w_i;
		fmt0 <= i_fmt;
		x <= i_s;
		y <= i_t;
		for (c = 0; c < 3; c = c + 1) begin
			x_t[c] <= i_s;
			y_t[c] <= i_t;
		end
		r2 <= r2_i;
		g2 <= g2_i;
		b2 <= b2_i;
		h_ge_0 <= !hcmp_bo;
		for (c = 0; c < 3; c = c + 1) begin
			dh0[c] <= dh_i[c];
			dv0[c] <= dv_i[c];
		end
	end
	wire [3:0] k = {x, y};

	/* ---- E1, the colour block: w the block, punch RGB8A1 ---- */
	wire rgbb = fmt0 == 4'd4 || fmt0 == 4'd5;
	wire punch = !rgbb && fmt0[1];
	wire [1:0] idx_raw = {w[{2'b01, k}], w[{2'b00, k}]};
	(* keep = "true" *) wire [1:0] idx_lo = idx_raw;
	(* keep = "true" *) wire [1:0] idx_hi = idx_raw;
	(* keep = "true" *) wire [1:0] idx_ctl = idx_raw;
	wire opq = punch ? w[33] : 1'b1;
	wire trn = punch && !w[33] && idx_ctl == 2'd2;
	wire [4:0] r5 = w[63:59], g5 = w[55:51], b5 = w[47:43];

	wire indiv_raw = !punch && !w[33];
	(* keep = "true" *) wire indiv_lo = indiv_raw;
	(* keep = "true" *) wire indiv_hi = indiv_raw;
	wire idv_raw = indiv_raw || (!r2[5] && !g2[5] && !b2[5]);	/* individual or differential */
	(* keep = "true" *) wire idv_lo = idv_raw;
	(* keep = "true" *) wire idv_hi = idv_raw;
	(* keep = "true" *) wire idv_ctl = idv_raw;
	wire tm_raw = !idv_ctl && r2[5];	/* T */
	(* keep = "true" *) wire tm_lo = tm_raw;
	(* keep = "true" *) wire tm_hi = tm_raw;
	(* keep = "true" *) wire tm_ctl = tm_raw;
	wire hm = !idv_ctl && !r2[5] && g2[5];	/* H */
	wire pm = !idv_ctl && !r2[5] && !g2[5];	/* planar */

	/* individual and differential: the sub-block's colour and the modifier */
	wire [23:0] i_c1_raw0 = {ext4(w[47:44]), ext4(w[55:52]), ext4(w[63:60])};
	wire [23:0] i_c1_raw1 = {ext5(b5), ext5(g5), ext5(r5)};
	wire [23:0] i_c1 = {
		indiv_hi ? i_c1_raw0[23:12] : i_c1_raw1[23:12],
		indiv_lo ? i_c1_raw0[11:0]  : i_c1_raw1[11:0]
	};
	wire [23:0] i_c2_raw0 = {ext4(w[43:40]), ext4(w[51:48]), ext4(w[59:56])};
	wire [23:0] i_c2_raw1 = {ext5(b2[4:0]), ext5(g2[4:0]), ext5(r2[4:0])};
	wire [23:0] i_c2 = {
		indiv_hi ? i_c2_raw0[23:12] : i_c2_raw1[23:12],
		indiv_lo ? i_c2_raw0[11:0]  : i_c2_raw1[11:0]
	};
	wire sub_raw = w[32] ? y[1] : x[1];
	(* keep = "true" *) wire sub_lo = sub_raw;
	(* keep = "true" *) wire sub_hi = sub_raw;
	(* keep = "true" *) wire sub_ctl = sub_raw;
	wire [15:0] ab = mods(sub_ctl ? w[36:34] : w[39:37]);
	wire [7:0] mb = idx_ctl[0] ? ab[15:8] : ab[7:0];
	/* T and H: the colours and the distance */
	wire [23:0] t_c1 = {ext4(w[51:48]), ext4(w[55:52]), ext4({w[60:59], w[57:56]})};
	wire [23:0] t_c2 = {ext4(w[39:36]), ext4(w[43:40]), ext4(w[47:44])};
	wire [23:0] h_c1 = {ext4({w[51], w[49:47]}), ext4({w[58:56], w[52]}), ext4(w[62:59])};
	wire [23:0] h_c2 = {ext4(w[38:35]), ext4(w[42:39]), ext4(w[46:43])};
	wire [6:0] d = tm_ctl ? tdist({w[35:34], w[32]}) : tdist({w[34], w[32], h_ge_0});
	/* The base colour and a signed offset of all three channels: q = base +/-
	 * dmag (individual, differential, T, H). */
	wire dzero = idv_ctl ? (!opq && !idx_ctl[0]) : (tm_ctl && !idx_ctl[0]);
	wire [7:0] dmag_e1 = dzero ? 8'd0 : idv_ctl ? mb : {1'b0, d};
	wire dsub_e1 = idv_ctl ? idx_ctl[1] : tm_ctl ? (idx_ctl[1] && idx_ctl[0]) : idx_ctl[0];

	reg [23:0] base;
	always @(*) begin
		if (idv_lo)
			base[11:0] = sub_lo ? i_c2[11:0] : i_c1[11:0];
		else if (tm_lo)
			base[11:0] = idx_lo == 2'd0 ? t_c1[11:0] : t_c2[11:0];
		else
			base[11:0] = idx_lo[1] ? h_c2[11:0] : h_c1[11:0];

		if (idv_hi)
			base[23:12] = sub_hi ? i_c2[23:12] : i_c1[23:12];
		else if (tm_hi)
			base[23:12] = idx_hi == 2'd0 ? t_c1[23:12] : t_c2[23:12];
		else
			base[23:12] = idx_hi[1] ? h_c2[23:12] : h_c1[23:12];
	end

	wire [23:0] po = {ext6({w[48], w[44:43], w[41:39]}), ext7({w[56], w[54:49]}),
		ext6(w[62:57])};

	/* planar's t1, t2 computed in E1 from registered dh0, dv0 */
	wire [11:0] t1 [0:2];
	wire [11:0] t2 [0:2];
	wire [5:0] t_nc;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_t
		am_add #(.W(12)) u_t1 (.a(x_t[g][0] ? dh0[g] : 12'd0), .b(y_t[g][0] ? dv0[g] : 12'd0),
			.ci(1'b0), .s(t1[g]), .co(t_nc[g*2]));
		am_add #(.W(12)) u_t2 (.a(x_t[g][1] ? dh0[g] : 12'd0), .b(y_t[g][1] ? dv0[g] : 12'd0),
			.ci(1'b0), .s(t2[g]), .co(t_nc[g*2 + 1]));
	end
	endgenerate

	/* ---- E1 registers ---- */
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] fmt1;
	(* extract_reset = "no", max_fanout = 16 *) reg trn1, pm1;
	(* extract_reset = "no", max_fanout = 16 *) reg [23:0] base1, po1;
	(* extract_reset = "no", max_fanout = 16 *) reg [7:0] dmag1;
	(* extract_reset = "no", max_fanout = 16 *) reg dsub1;
	(* extract_reset = "no" *) reg [11:0] t1_1 [0:2];
	(* extract_reset = "no" *) reg [11:0] t2_1 [0:2];
	always @(posedge clk) begin
		fmt1 <= fmt0;
		trn1 <= trn && !pm;
		pm1 <= pm;
		base1 <= base;
		dmag1 <= dmag_e1;
		dsub1 <= dsub_e1;
		po1 <= po;
		for (c = 0; c < 3; c = c + 1) begin
			t1_1[c] <= t1[c];
			t2_1[c] <= t2[c];
		end
	end

	/* ---- E1b: the sums (qn = base1 +/- dmag1, qp = t1 + 2*t2 + 4*po + 2) ---- */
	wire [11:0] qn [0:2];
	wire [11:0] qp [0:2];
	wire [5:0] q_nc;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_q
		am_addsub #(.W(12)) u_qn (
			.a({4'd0, base1[g*8 +: 8]}), .b({4'd0, dmag1}),
			.sub(dsub1), .s(qn[g]), .co(q_nc[g*2])
		);
		wire [11:0] pa = t1_1[g];
		wire [11:0] pb = {t2_1[g][10:0], 1'b0};
		wire [11:0] pc_o = {2'd0, po1[g*8 +: 8], 2'b10};
		wire [11:0] ps = pa ^ pb ^ pc_o;
		wire [11:0] pcy = {(pa[10:0] & pb[10:0]) | (pa[10:0] & pc_o[10:0]) |
			(pb[10:0] & pc_o[10:0]), 1'b0};
		am_add #(.W(12)) u_qp (
			.a(ps), .b(pcy), .ci(1'b0), .s(qp[g]), .co(q_nc[g*2 + 1])
		);
	end
	endgenerate

	/* ---- E1b registers ---- */
	(* extract_reset = "no", max_fanout = 16 *) reg [3:0] fmt2;
	(* extract_reset = "no", max_fanout = 16 *) reg trn2, pm2;
	(* extract_reset = "no" *) reg [11:0] qn_2 [0:2];
	(* extract_reset = "no" *) reg [11:0] qp_2 [0:2];
	always @(posedge clk) begin
		fmt2 <= fmt1;
		trn2 <= trn1;
		pm2 <= pm1;
		for (c = 0; c < 3; c = c + 1) begin
			qn_2[c] <= qn[c];
			qp_2[c] <= qp[c];
		end
	end

	/* ---- E2: the clamps ---- */
	wire [23:0] pc;
	generate
	for (g = 0; g < 3; g = g + 1) begin : g_cl
		assign pc[g*8 +: 8] = pm2 ? clamp8({{2{qp_2[g][11]}}, qp_2[g][11:2]}) : clamp8(qn_2[g]);
	end
	endgenerate

	wire [31:0] rgbv = trn2 ? 32'd0 : {8'hFF, pc};

	always @(posedge clk) begin
		o_kind <= 2'd0;
		o_texel <= 32'd0;
		case (fmt2)
		4'd0, 4'd1, 4'd2, 4'd3: begin
			o_kind <= {1'b0, fmt2[0]};
			o_texel <= rgbv;
		end
		4'd4, 4'd5: begin
			o_kind <= {1'b0, fmt2[0]};
			o_texel <= {ea[7:0], rgbv[23:0]};
		end
		4'd6, 4'd7, 4'd8, 4'd9: begin
			o_kind <= fmt2[0] ? 2'd3 : 2'd2;
			o_texel <= {5'd0, fmt2[3] ? eb : 11'd0, 5'd0, ea};
		end
		default: ;
		endcase
	end

	wire unused_ok = &{1'b0, d_nc, hcmp_d, p_nc, t_nc, q_nc, opq, hm, ea[10:8],
		rgbv[31:24]};
endmodule

`default_nettype wire
