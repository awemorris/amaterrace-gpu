/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_conv: VF format conversion: turns raw attribute bytes (R32F …
 * RGBA16F, RGBA8 UNORM/UINT, R32/RG32 UINT) into 32-bit words and writes
 * them into the SU's registers at ATTR_DST[k].
 *
 * An af is taken whole (raw bytes, ATTR[k]_DESC format and ATTR_DST[k] at
 * that moment); its ATTR_DST count of words then go out one per cycle on
 * vl_* (registered), register ATTR_DST[5:0] + c (mod 64).  The next af is
 * taken in the cycle of the current one's last word, so the words of a warp
 * go out back to back.  Formats (design §2.3 ATTR_DESC[19:16]): fp32 and
 * uint32 words as they are, RGBA8_UNORM as c / 255 (round to nearest even,
 * include/atg_rop_unorm8.vh), RGBA8_UINT zero-extended, fp16 to fp32 exactly
 * (denormals kept, NaN 0x7FC00000).  Components beyond the format's and up
 * to ATTR_DST's count are (0, 0, 0, 1) (1.0 for float formats, 1 for the
 * UINT ones); the reserved formats 10-15 have no data components.  An
 * attribute whose ATTR_DST is 0 (disabled) writes nothing.  conv_done
 * pulses the cycle after the last word of the af with af_last (two cycles
 * after taking it when it writes nothing).  With ATTR_DST[k][31:24] (a
 * VkFormat, CAPS[30]) the format is that one instead, through
 * atg_fmt_comp (a format without the vertex-buffer feature reads 0, 0,
 * 0, 1.0); an af with af_oob (outside ATTR_LIMIT) writes (0, 0, 0, 1) in
 * the format's kind.  See spec/gpu/vf/atg_vf_conv.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_conv (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,
	/* Attribute data (atg_vf_fetch → atg_vf_conv) */
	input wire af_valid,
	output wire af_ready,
	input wire [3:0] af_attr,
	input wire [4:0] af_lane,
	input wire [127:0] af_raw,
	input wire af_oob,
	input wire af_last,
	/* Register writes to the SU (atg_su vl_*) */
	output reg vl_we,
	output reg [5:0] vl_reg,
	output reg [4:0] vl_lane,
	output reg [31:0] vl_data,
	output reg conv_done
);
	`include "atg_rop_unorm8.vh"
	`include "ghci_regs.vh"
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"

	/* STATE: ATTR[k]_DESC 0x031 + 2k (format [19:16]), ATTR_DST[k] 0x1C0 + k. */
	reg [3:0] s_fmt [0:15];
	reg [7:0] s_dst [0:15];
	reg [7:0] s_vk [0:15];	/* ATTR_DST[31:24] */
	wire [8:0] s_off;
	wire so_bo_unused;
	am_sub #(.W(9)) u_s_off (.a(st_idx), .b(GHCI_S_ATTR), .bi(1'b0),
		.d(s_off), .bo(so_bo_unused));
	wire s_desc = st_idx >= GHCI_S_ATTR && st_idx < GHCI_S_ATTR + 9'd32 && s_off[0];
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			for (i = 0; i < 16; i = i + 1) begin
				s_fmt[i] <= 4'd0;
				s_dst[i] <= 8'd0;
				s_vk[i] <= 8'd0;
			end
		end else if (st_we) begin
			if (s_desc)
				s_fmt[s_off[4:1]] <= st_wdata[19:16];
			if (st_idx[8:4] == GHCI_S_ATTR_DST[8:4]) begin
				s_dst[st_idx[3:0]] <= st_wdata[7:0];
				s_vk[st_idx[3:0]] <= st_wdata[31:24];
			end
		end

	/* The attribute being written. */
	reg c_v, c_last;
	reg [127:0] c_raw;
	reg [4:0] c_lane;
	reg [3:0] c_fmt;
	reg [7:0] c_dst;
	reg [7:0] c_vk;
	reg c_oob;
	reg [1:0] c_i;
	reg fin;

	reg [2:0] ncomp;
	always @(*)
		case (c_fmt)
		4'd0, 4'd8: ncomp = 3'd1;
		4'd1, 4'd6, 4'd9: ncomp = 3'd2;
		4'd2: ncomp = 3'd3;
		4'd3, 4'd4, 4'd5, 4'd7: ncomp = 3'd4;
		default: ncomp = 3'd0;
		endcase
	wire isint_l = c_fmt == 4'd5 || c_fmt == 4'd8 || c_fmt == 4'd9;
	/* The VkFormat path: every component at once (the af is held). */
	wire [67:0] vk_inf = atg_fmt_info(c_vk);
	wire [25:0] vk_feat = atg_fmt_feat(c_vk, 1'b0);
	wire vk_ok = vk_feat[19];	/* VERTEX_BUFFER */
	wire vk_int = vk_ok && (vk_inf[11:9] == ATG_FMT_UINT || vk_inf[11:9] == ATG_FMT_SINT);
	/* Component c_i (one a cycle) through one atg_fmt_comp: of the VkFormat,
	 * or for the fp16 formats 6 and 7 of R16G16B16A16_SFLOAT (component c
	 * at bit 16 c, fp16 to fp32 exactly: denormals normalised, NaN
	 * 0x7FC00000); the two are never needed in the same cycle. */
	localparam [67:0] INF_H4 = atg_fmt_info(8'd97);
	wire [31:0] vk_c;
	atg_fmt_comp u_comp (.raw(c_raw), .inf(c_vk != 8'd0 ? vk_inf : INF_H4), .k(c_i), .sten(1'b0),
		.v(vk_c));
	wire isint = c_vk != 8'd0 ? vk_int : isint_l;
	wire [31:0] w32 = c_raw[32 * c_i +: 32];
	wire [7:0] w8 = c_raw[8 * c_i +: 8];
	reg [31:0] word;
	always @(*) begin
		if (c_oob || (c_vk != 8'd0 && !vk_ok))
			word = c_i != 2'd3 ? 32'd0 : isint ? 32'd1 : 32'h3F800000;
		else if (c_vk != 8'd0)
			word = vk_c;
		else if ({1'b0, c_i} >= ncomp)
			word = c_i != 2'd3 ? 32'd0 : isint ? 32'd1 : 32'h3F800000;
		else
			case (c_fmt)
			4'd4: word = atg_rop_unorm8(w8);
			4'd5: word = {24'd0, w8};
			4'd6, 4'd7: word = vk_c;
			default: word = w32;
			endcase
	end

	wire c_end = c_v && c_i == c_dst[7:6];

	/* The register of component c_i, and the next component. */
	wire [5:0] reg_c;
	wire [1:0] c_i_next;
	wire rc_co_unused, cn_co_unused;
	am_add #(.W(6)) u_reg (.a(c_dst[5:0]), .b({4'd0, c_i}), .ci(1'b0),
		.s(reg_c), .co(rc_co_unused));
	am_add #(.W(2)) u_c_i (.a(c_i), .b(2'd0), .ci(1'b1), .s(c_i_next), .co(cn_co_unused));
	assign af_ready = !c_v || c_end;
	wire take = af_valid && af_ready;
	wire [7:0] t_dst = s_dst[af_attr];
	wire t_en = {s_vk[af_attr], t_dst} != 16'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			c_v <= 1'b0;
			vl_we <= 1'b0;
			fin <= 1'b0;
			conv_done <= 1'b0;
		end else begin
			vl_we <= c_v;
			vl_reg <= reg_c;
			vl_lane <= c_lane;
			vl_data <= word;
			fin <= (c_end && c_last) || (take && !t_en && af_last);
			conv_done <= fin;
			if (c_v)
				c_i <= c_i_next;
			if (c_end)
				c_v <= 1'b0;
			if (take && t_en) begin
				c_v <= 1'b1;
				c_i <= 2'd0;
				c_raw <= af_raw;
				c_lane <= af_lane;
				c_fmt <= s_fmt[af_attr];
				c_dst <= t_dst;
				c_vk <= s_vk[af_attr];
				c_oob <= af_oob;
				c_last <= af_last;
			end
		end
	end

	wire unused_ok = &{1'b0, st_wdata[23:20], st_wdata[15:8], s_off[8:5], vk_inf[67:12],
		vk_inf[8:0], vk_feat[25:20], vk_feat[18:0]};
endmodule

`default_nettype wire
