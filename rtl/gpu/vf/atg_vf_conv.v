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
 * after taking it when it writes nothing).  See spec/gpu/vf/atg_vf_conv.md.
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

	/* fp16 -> fp32, exact (denormals normalised); NaN -> 0x7FC00000. */
	function [31:0] h2f;
		input [15:0] h;
		integer j;
		reg [3:0] p;
		reg [9:0] fr;
		begin
			p = 4'd0;
			for (j = 0; j < 10; j = j + 1)
				if (h[j])
					/* verilator lint_off WIDTHTRUNC */
					p = j;
					/* verilator lint_on WIDTHTRUNC */
			fr = h[9:0] << (4'd10 - p);
			if (h[14:10] == 5'h1F)
				h2f = h[9:0] != 10'd0 ? 32'h7FC00000 : {h[15], 8'hFF, 23'd0};
			else if (h[14:10] == 5'd0)
				h2f = h[9:0] == 10'd0 ? {h[15], 31'd0} :
					{h[15], 8'd103 + {4'd0, p}, fr, 13'd0};
			else
				h2f = {h[15], {3'd0, h[14:10]} + 8'd112, h[9:0], 13'd0};
		end
	endfunction

	/* STATE: ATTR[k]_DESC 0x031 + 2k (format [19:16]), ATTR_DST[k] 0x1C0 + k. */
	reg [3:0] s_fmt [0:15];
	reg [7:0] s_dst [0:15];
	wire [8:0] s_off = st_idx - GHCI_S_ATTR;
	wire s_desc = st_idx >= GHCI_S_ATTR && st_idx < GHCI_S_ATTR + 9'd32 && s_off[0];
	integer i;
	always @(posedge clk)
		if (!rst_n) begin
			for (i = 0; i < 16; i = i + 1) begin
				s_fmt[i] <= 4'd0;
				s_dst[i] <= 8'd0;
			end
		end else if (st_we) begin
			if (s_desc)
				s_fmt[s_off[4:1]] <= st_wdata[19:16];
			if (st_idx[8:4] == GHCI_S_ATTR_DST[8:4])
				s_dst[st_idx[3:0]] <= st_wdata[7:0];
		end

	/* The attribute being written. */
	reg c_v, c_last;
	reg [127:0] c_raw;
	reg [4:0] c_lane;
	reg [3:0] c_fmt;
	reg [7:0] c_dst;
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
	wire isint = c_fmt == 4'd5 || c_fmt == 4'd8 || c_fmt == 4'd9;
	wire [31:0] w32 = c_raw[32 * c_i +: 32];
	wire [7:0] w8 = c_raw[8 * c_i +: 8];
	wire [15:0] w16 = c_raw[16 * c_i +: 16];
	reg [31:0] word;
	always @(*) begin
		if ({1'b0, c_i} >= ncomp)
			word = c_i != 2'd3 ? 32'd0 : isint ? 32'd1 : 32'h3F800000;
		else
			case (c_fmt)
			4'd4: word = atg_rop_unorm8(w8);
			4'd5: word = {24'd0, w8};
			4'd6, 4'd7: word = h2f(w16);
			default: word = w32;
			endcase
	end

	wire c_end = c_v && c_i == c_dst[7:6];
	assign af_ready = !c_v || c_end;
	wire take = af_valid && af_ready;
	wire [7:0] t_dst = s_dst[af_attr];

	always @(posedge clk) begin
		if (!rst_n) begin
			c_v <= 1'b0;
			vl_we <= 1'b0;
			fin <= 1'b0;
			conv_done <= 1'b0;
		end else begin
			vl_we <= c_v;
			vl_reg <= c_dst[5:0] + {4'd0, c_i};
			vl_lane <= c_lane;
			vl_data <= word;
			fin <= (c_end && c_last) || (take && t_dst == 8'd0 && af_last);
			conv_done <= fin;
			if (c_v)
				c_i <= c_i + 2'd1;
			if (c_end)
				c_v <= 1'b0;
			if (take && t_dst != 8'd0) begin
				c_v <= 1'b1;
				c_i <= 2'd0;
				c_raw <= af_raw;
				c_lane <= af_lane;
				c_fmt <= s_fmt[af_attr];
				c_dst <= t_dst;
				c_last <= af_last;
			end
		end
	end

	wire unused_ok = &{1'b0, st_wdata[31:20], st_wdata[15:8], s_off[8:5]};
endmodule

`default_nettype wire
