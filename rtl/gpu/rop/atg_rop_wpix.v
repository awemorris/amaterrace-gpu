/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_wpix: the pixels of atg_rop_wb: the attachment's state (CAPS[30]
 * RT_FORMATS, RTk_BASE/STRIDE, WRITE_MASK, BLEND, BLEND1-3, the blend
 * constants), the place of each pixel in the lines, the choice of the
 * blend path and the new pixel bytes.  No state machine; it holds
 * atg_rop_fblend.
 *
 * The beat (i_xy, i_rt, i_smask, i_color) is attachment i_rt of a quad.
 * Its format is RT_FORMATS byte i_rt, or for attachment 0 with that byte 0
 * the earlier RT_FORMAT code (0 B8G8R8A8, 1 R8G8B8A8, 2 and 3 R5G6B5); the
 * pixel is ps = 1, 2, 4, 8 or 16 bytes, sample s of pixel x at (S x + s) ps
 * of the row (S = 4 with MS_CTRL[3:0] = 2, else 1).  A quad's row takes
 * 2 S ps bytes from o_addr (r = 0) on: one line, or (o_multi) o_nl + 1
 * whole lines (only S = 4 with 2 S ps > LINE_BYTES).
 *   One line per row: the quad's 4 lanes of sample g (pass i_g, o_np + 1
 *   passes) are the slots, lane k in entry k >> 1 at byte i_off + (S (k &
 *   1) + g) ps.
 *   Several lines: line i_j of row i_r holds the slots n = E i_j + k, k < E
 *   = LINE_BYTES / ps (lane 2 r + n / 4, sample n mod 4) at byte k ps of
 *   entry r; one pass per line.
 * o_mask: the slots whose sample survived; o_lw: the row (one line) or the
 * line (several) has such a slot.  o_drop: nothing is written (a format
 * without the colour-attachment feature, or no channel of the format in
 * the attachment's write mask).  o_read: the old pixels are needed (blend
 * on, or a write mask without every channel of the format).
 * Paths (o_path): 0 atg_rop_blend (B8G8R8A8, R8G8B8A8, A8B8G8R8, R5G6B5,
 * R8, R8G8, A1R5G5B5 UNORM; 4 slots in 3 cycles, b_pix), 1 atg_rop_fblend
 * (the sRGB formats, A2B10G10R10_UNORM, R16, R16G16, R16G16B16A16_SFLOAT;
 * f_go starts it, f_done the result, f_take takes it), 2 atg_fmt_pack of
 * the source without blending (the integer and 32-bit float formats;
 * Vulkan does not blend them).  o_res: slot k's new pixel at [128 k], ps
 * bytes (the bits the write mask keeps are the old ones).  See
 * spec/gpu/rop/atg_rop_wpix.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_wpix #(
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* The beat (atg_rop_wb's copy) and the place in it */
	input wire [31:0] i_xy,
	input wire [1:0] i_rt,
	input wire [15:0] i_smask,	/* bit 4 l + s: sample s of lane l */
	input wire [511:0] i_color,
	input wire i_r,	/* row */
	input wire [1:0] i_j,	/* line of the row (several lines) */
	input wire [1:0] i_g,	/* pass: the sample (one line) */
	/* The two line entries and the quad's first byte in each */
	input wire [LINE_BYTES*8-1:0] i_line0,
	input wire [LINE_BYTES*8-1:0] i_line1,
	input wire [LINE_SHIFT-1:0] i_off0,
	input wire [LINE_SHIFT-1:0] i_off1,
	/* The paths' results */
	input wire [127:0] b_pix,
	input wire f_go,
	output wire f_done,
	input wire f_take,
	/* To atg_rop_wb */
	output wire [31:0] o_addr,
	output wire [1:0] o_nl,
	output wire [1:0] o_np,
	output wire o_multi,
	output wire o_drop,
	output wire o_read,
	output wire [1:0] o_path,
	output wire o_lw,
	output wire [3:0] o_mask,
	output wire [511:0] o_bsrc,
	output wire [127:0] o_bdst,
	output wire [511:0] o_res,
	output wire [3:0] o_ent,
	output wire [4*LINE_SHIFT-1:0] o_soff,
	output wire [4:0] o_ps
);
	`include "ghci_regs.vh"
	`include "atg_rop_unorm8.vh"
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_fmt_unpack.vh"
	`include "atg_fmt_pack.vh"

	/* STATE: RT_BASE 0x070, RT_STRIDE 0x071, RT_FORMAT 0x072, BLEND 0x07A,
	 * BLEND_CONST 0x07B, WRITE_MASK 0x07C, RT_FORMATS 0x07D, RT1-3_BASE and
	 * _STRIDE 0x07E-0x083, BLEND1-3 0x084-0x086, BLEND_CONST_R-A
	 * 0x087-0x08A, ROP_CTRL 0x08D, MS_CTRL 0x05E. */
	reg [31:0] base [0:3];
	reg [31:0] stride [0:3];
	reg [22:0] bls [0:3];
	reg [31:0] kcf [0:3];
	reg [1:0] fmt0;
	reg [31:0] fmts, kc8;
	reg [15:0] wms;
	reg kc_sel, ms4;
	wire [8:0] s_rt = st_idx - GHCI_S_RT1_BASE;	/* 2 (k - 1) + stride */
	wire [8:0] s_bl = st_idx - GHCI_S_BLEND1;
	wire [8:0] s_kc = st_idx - GHCI_S_BLEND_CONST_R;
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			for (i = 0; i < 4; i = i + 1) begin
				base[i] <= 32'd0;
				stride[i] <= 32'd0;
				bls[i] <= 23'd0;
				kcf[i] <= 32'd0;
			end
			fmt0 <= 2'd0;
			fmts <= 32'd0;
			kc8 <= 32'd0;
			wms <= 16'd0;
			kc_sel <= 1'b0;
			ms4 <= 1'b0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_BASE)
				base[0] <= st_wdata;
			if (st_idx == GHCI_S_RT_STRIDE)
				stride[0] <= st_wdata;
			if (st_idx >= GHCI_S_RT1_BASE && st_idx < GHCI_S_RT1_BASE + 9'd6) begin
				if (s_rt[0])
					stride[s_rt[2:1] + 2'd1] <= st_wdata;
				else
					base[s_rt[2:1] + 2'd1] <= st_wdata;
			end
			if (st_idx == GHCI_S_RT_FORMAT)
				fmt0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)
				fmts <= st_wdata;
			if (st_idx == GHCI_S_BLEND)
				bls[0] <= st_wdata[22:0];
			if (st_idx >= GHCI_S_BLEND1 && st_idx < GHCI_S_BLEND1 + 9'd3)
				bls[s_bl[1:0] + 2'd1] <= st_wdata[22:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				kc8 <= st_wdata;
			if (st_idx >= GHCI_S_BLEND_CONST_R && st_idx < GHCI_S_BLEND_CONST_R + 9'd4)
				kcf[s_kc[1:0]] <= st_wdata;
			if (st_idx == GHCI_S_ROP_CTRL)
				kc_sel <= st_wdata[1];
			if (st_idx == GHCI_S_WRITE_MASK)
				wms <= st_wdata[15:0];
			if (st_idx == GHCI_S_MS_CTRL)
				ms4 <= st_wdata[3:0] == 4'd2;
		end

	/* The attachment's format, pixel size, channels and path. */
	wire [7:0] fsel = fmts[8 * i_rt +: 8];
	wire [7:0] vk = i_rt == 2'd0 && fsel == 8'd0 ? (fmt0 == 2'd0 ? 8'd44 : fmt0 == 2'd1 ? 8'd37 :
		8'd4) : fsel;
	wire [67:0] inf = atg_fmt_info(vk);
	wire [25:0] feat = atg_fmt_feat(vk, 1'b0);
	wire [4:0] ps = inf[5:1];
	wire [2:0] psl = ps[4] ? 3'd4 : ps[3] ? 3'd3 : ps[2] ? 3'd2 : ps[1] ? 3'd1 : 3'd0;
	wire [3:0] cmask = inf[8:6] >= 3'd4 ? 4'hF : inf[8:6] == 3'd3 ? 4'h7 :
		inf[8:6] == 3'd2 ? 4'h3 : 4'h1;
	wire [3:0] wm = wms[4 * i_rt +: 4];
	wire [22:0] bl = bls[i_rt];
	wire p_u8 = vk == 8'd44 || vk == 8'd37 || vk == 8'd51 || vk == 8'd4 || vk == 8'd9 ||
		vk == 8'd16 || vk == 8'd8;
	wire p_f32 = vk == 8'd43 || vk == 8'd50 || vk == 8'd57 || vk == 8'd64 || vk == 8'd76 ||
		vk == 8'd83 || vk == 8'd97;
	assign o_path = p_u8 ? 2'd0 : p_f32 ? 2'd1 : 2'd2;
	assign o_drop = !feat[7] || (wm & cmask) == 4'd0;	/* COLOR_ATTACHMENT */
	assign o_read = (bl[0] && (p_u8 || p_f32)) || (wm & cmask) != cmask;
	assign o_ps = ps;

	/* The row's bytes: 2 S ps = 2^segl; several lines when above a line. */
	wire [3:0] segl = {1'b0, psl} + (ms4 ? 4'd3 : 4'd1);
	localparam [31:0] LS32 = LINE_SHIFT;
	wire [3:0] ls4 = LS32[3:0];
	wire multi = segl > ls4;
	wire [3:0] nll = segl - ls4;	/* log2 of the lines (several) */
	assign o_multi = multi;
	assign o_nl = multi ? (nll == 4'd1 ? 2'd1 : 2'd3) : 2'd0;
	assign o_np = !multi && ms4 ? 2'd3 : 2'd0;
	wire [31:0] xoff = {16'd0, i_xy[15:0]} << (psl + (ms4 ? 3'd2 : 3'd0));
	assign o_addr = base[i_rt] + ({16'd0, i_xy[31:16]} + {31'd0, i_r}) * stride[i_rt] + xoff +
`ifdef MUT_WPIX_LINE
		32'd0;
`else
		(multi ? {{(30-LINE_SHIFT){1'b0}}, i_j, {LINE_SHIFT{1'b0}}} : 32'd0);
`endif

	/* The slots. */
	wire [2:0] el = ls4[2:0] - psl;	/* log2 E (several lines) */
	wire [LINE_BYTES*8+127:0] lpad0 = {128'd0, i_line0};
	wire [LINE_BYTES*8+127:0] lpad1 = {128'd0, i_line1};
	wire [127:0] kcv = kc_sel ? {kcf[3], kcf[2], kcf[1], kcf[0]} :
		{atg_rop_unorm8(kc8[31:24]), atg_rop_unorm8(kc8[23:16]), atg_rop_unorm8(kc8[15:8]),
		atg_rop_unorm8(kc8[7:0])};
	wire [255:0] f_dst, f_raw, f_keep;
	wire f_idle;	/* the wb starts it only after taking its result */
	wire [3:0] mk, en;
	wire [4*LINE_SHIFT-1:0] so;
	wire [511:0] src, dst;
	genvar k;
	generate
	for (k = 0; k < 4; k = k + 1) begin : g_slot
		/* one line: lane k, sample i_g; several: n = E i_j + k */
		wire [3:0] n = ({2'd0, i_j} << el) + k;
		wire [1:0] ln = multi ? {i_r, n[2]} : k;
		wire [LINE_SHIFT-1:0] o1 = (k >= 2 ? i_off1 : i_off0) +
			({{(LINE_SHIFT-3){1'b0}}, ms4 ? {k[0], i_g} : {2'b00, k[0]}} << psl);
		wire [LINE_SHIFT-1:0] om = {{(LINE_SHIFT-2){1'b0}}, k[1:0]} << psl;
		wire [LINE_SHIFT-1:0] o = multi ? om : o1;
		assign so[LINE_SHIFT * k +: LINE_SHIFT] = o;
		assign en[k] = multi ? i_r : k >= 2;
		assign mk[k] = multi ? (el == 3'd2 || k < 2) && i_smask[{ln, n[1:0]}] : i_smask[{ln, i_g}];
		assign dst[128 * k +: 128] = en[k] ? lpad1[8 * o +: 128] : lpad0[8 * o +: 128];
		assign src[128 * k +: 128] = i_color[128 * ln +: 128];
		wire unused_n = &{1'b0, n[3]};
	end
	endgenerate
	assign o_mask = mk;
	assign o_lw = multi ? mk != 4'd0 : i_smask[8 * i_r +: 8] != 8'd0;
	assign o_ent = en;
	assign o_soff = so;
	assign o_bsrc = src;
	assign o_bdst = {dst[384 +: 32], dst[256 +: 32], dst[128 +: 32], dst[0 +: 32]};
	assign f_dst = {dst[384 +: 64], dst[256 +: 64], dst[128 +: 64], dst[0 +: 64]};

	atg_rop_fblend fblend (.clk(clk), .rst_n(rst_n), .i_valid(f_go), .i_ready(f_idle),
		.i_lanes(mk), .i_src(src), .i_dst(f_dst), .i_fmt(vk), .i_blend(bl), .i_const(kcv),
		.i_wm(wm), .o_valid(f_done), .o_ready(f_take), .o_raw(f_raw), .o_keep(f_keep));

	/* atg_fmt_pack for the formats of path 2 (the colour-attachment formats
	 * that are neither path 0 nor 1), each with its format as a constant so
	 * that it reduces to its own bit placement; a format without the
	 * colour-attachment feature writes nothing, as in atg_fmt_pack.  For the
	 * formats of paths 0 and 1 the value is not used. */
	function [255:0] pack2;
		input [127:0] c;
		input [7:0] f;
		input [3:0] m;
		case (f)
		8'd13: pack2 = atg_fmt_pack(c, 8'd13, m);
		8'd14: pack2 = atg_fmt_pack(c, 8'd14, m);
		8'd20: pack2 = atg_fmt_pack(c, 8'd20, m);
		8'd21: pack2 = atg_fmt_pack(c, 8'd21, m);
		8'd41: pack2 = atg_fmt_pack(c, 8'd41, m);
		8'd42: pack2 = atg_fmt_pack(c, 8'd42, m);
		8'd55: pack2 = atg_fmt_pack(c, 8'd55, m);
		8'd56: pack2 = atg_fmt_pack(c, 8'd56, m);
		8'd68: pack2 = atg_fmt_pack(c, 8'd68, m);
		8'd74: pack2 = atg_fmt_pack(c, 8'd74, m);
		8'd75: pack2 = atg_fmt_pack(c, 8'd75, m);
		8'd81: pack2 = atg_fmt_pack(c, 8'd81, m);
		8'd82: pack2 = atg_fmt_pack(c, 8'd82, m);
		8'd95: pack2 = atg_fmt_pack(c, 8'd95, m);
		8'd96: pack2 = atg_fmt_pack(c, 8'd96, m);
		8'd98: pack2 = atg_fmt_pack(c, 8'd98, m);
		8'd99: pack2 = atg_fmt_pack(c, 8'd99, m);
		8'd100: pack2 = atg_fmt_pack(c, 8'd100, m);
		8'd101: pack2 = atg_fmt_pack(c, 8'd101, m);
		8'd102: pack2 = atg_fmt_pack(c, 8'd102, m);
		8'd103: pack2 = atg_fmt_pack(c, 8'd103, m);
		8'd107: pack2 = atg_fmt_pack(c, 8'd107, m);
		8'd108: pack2 = atg_fmt_pack(c, 8'd108, m);
		8'd109: pack2 = atg_fmt_pack(c, 8'd109, m);
		default: pack2 = {{128{1'b1}}, 128'd0};
		endcase
	endfunction

	/* The new pixels. */
	generate
	for (k = 0; k < 4; k = k + 1) begin : g_res
		wire [255:0] pk = pack2(src[128 * k +: 128], vk, wm);
		wire [63:0] fr = (f_raw[64 * k +: 64] & ~f_keep[64 * k +: 64]) |
			(dst[128 * k +: 64] & f_keep[64 * k +: 64]);
		assign o_res[128 * k +: 128] = p_u8 ? {96'd0, b_pix[32 * k +: 32]} :
`ifdef MUT_WPIX_KEEP
			p_f32 ? {64'd0, fr} : pk[127:0];
`else
			p_f32 ? {64'd0, fr} : (pk[127:0] & ~pk[255:128]) | (dst[128 * k +: 128] & pk[255:128]);
`endif
	end
	endgenerate

	wire unused_ok = &{1'b0, f_idle, LS32[31:4], inf[67:9], inf[0], feat[25:8], feat[6:0], s_rt[8:3], s_bl[8:2],
		s_kc[8:2], nll[3:2]};
endmodule

`default_nettype wire
