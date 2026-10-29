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
 * atg_fmt_cvt (pipelined) (a format without the vertex-buffer feature reads 0, 0,
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
	/* Vertex indices for gl_VertexIndex / gl_InstanceIndex delivery */
	input wire vb_valid,
	input wire vb_ready,
	input wire [31:0] vb_index,
	input wire [31:0] vb_inst,
	input wire [4:0] vb_lane,
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

	/* STATE: used_regs_vs (from GHCI_S_VS_WORDS or 0x029) */
	reg [7:0] s_used_regs_vs;
	always @(posedge clk) begin
		if (!rst_n)
			s_used_regs_vs <= 8'd0;
		else if (st_we && (st_idx == GHCI_S_VS_WORDS || st_idx == 9'h029))
			s_used_regs_vs <= st_wdata[7:0];
	end

	/* Vertex/Instance indices captured from vb stream */
	reg [31:0] v_idx_mem [0:31];
	reg [31:0] v_inst_mem [0:31];
	integer vi;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (vi = 0; vi < 32; vi = vi + 1) begin
				v_idx_mem[vi] <= 32'd0;
				v_inst_mem[vi] <= 32'd0;
			end
		end else if (vb_valid && vb_ready) begin
			v_idx_mem[vb_lane] <= vb_index;
			v_inst_mem[vb_lane] <= vb_inst;
		end
	end

	/* System input delivery FSM */
	reg [5:0] sys_cnt;
	reg sys_active;
	wire [4:0] sys_lane = sys_cnt[5:1];
	wire sys_is_inst = sys_cnt[0];
	wire [5:0] sys_cnt_next;
	wire sc_co_unused;
	am_add #(.W(6)) u_sys_cnt (.a(sys_cnt), .b(6'd0), .ci(1'b1), .s(sys_cnt_next), .co(sc_co_unused));

	/* The attribute being written. */
	reg c_v, c_last;
	reg [127:0] c_raw;
	reg [4:0] c_lane;
	reg [3:0] c_fmt;
	reg [7:0] c_dst;
	reg [7:0] c_vk;
	reg c_oob;
	reg [1:0] c_i;

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
	wire [67:0] vk_inf = atg_fmt_info(c_vk);
	wire [25:0] vk_feat = atg_fmt_feat(c_vk, 1'b0);
	wire vk_ok = vk_feat[19];	/* VERTEX_BUFFER */
	wire vk_int = vk_ok && (vk_inf[11:9] == ATG_FMT_UINT || vk_inf[11:9] == ATG_FMT_SINT);
	localparam [67:0] INF_H4 = atg_fmt_info(8'd97);

	/* Pipelined format converter: atg_fmt_cvt (7 stages) */
	wire [31:0] cvt_out;
	wire [67:0] cvt_inf = c_vk != 8'd0 ? vk_inf : INF_H4;
	atg_fmt_cvt u_cvt (
		.clk(clk),
		.i_raw(c_raw),
		.i_inf(cvt_inf),
		.i_k(c_i),
		.i_sten(1'b0),
		.o_val(cvt_out)
	);

	wire isint = c_vk != 8'd0 ? vk_int : isint_l;
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

	/* 7-stage pipeline shift registers without raw array declarations */
	reg [6:0] p_v;
	reg [41:0] p_reg;
	reg [34:0] p_lane;
	reg [13:0] p_i;
	reg [27:0] p_fmt;
	reg [55:0] p_vk;
	reg [6:0] p_vk_ok;
	reg [6:0] p_isint;
	reg [6:0] p_oob;
	reg [6:0] p_fill;
	reg [223:0] p_w32;
	reg [55:0] p_w8;
	reg [6:0] p_fin;

	wire in_v = c_v;
	wire [5:0] in_reg = reg_c;
	wire [4:0] in_lane = c_lane;
	wire [1:0] in_i = c_i;
	wire [3:0] in_fmt = c_fmt;
	wire [7:0] in_vk = c_vk;
	wire in_vk_ok = vk_ok;
	wire in_isint = isint;
	wire in_oob = c_oob;
	wire in_fill = (c_vk == 8'd0) && ({1'b0, c_i} >= ncomp);
	wire [31:0] in_w32 = c_raw[32 * c_i +: 32];
	wire [7:0] in_w8 = c_raw[8 * c_i +: 8];
	wire in_fin = (c_end && c_last) || (take && !t_en && af_last);

	always @(posedge clk) begin
		if (!rst_n) begin
			p_v <= 7'd0;
			p_reg <= 42'd0;
			p_lane <= 35'd0;
			p_i <= 14'd0;
			p_fmt <= 28'd0;
			p_vk <= 56'd0;
			p_vk_ok <= 7'd0;
			p_isint <= 7'd0;
			p_oob <= 7'd0;
			p_fill <= 7'd0;
			p_w32 <= 224'd0;
			p_w8 <= 56'd0;
			p_fin <= 7'd0;
		end else begin
			p_v <= {p_v[5:0], in_v};
			p_fin <= {p_fin[5:0], in_fin};
			p_vk_ok <= {p_vk_ok[5:0], in_vk_ok};
			p_isint <= {p_isint[5:0], in_isint};
			p_oob <= {p_oob[5:0], in_oob};
			p_fill <= {p_fill[5:0], in_fill};

			p_reg <= {p_reg[35:0], in_reg};
			p_lane <= {p_lane[29:0], in_lane};
			p_i <= {p_i[11:0], in_i};
			p_fmt <= {p_fmt[23:0], in_fmt};
			p_vk <= {p_vk[47:0], in_vk};
			p_w32 <= {p_w32[191:0], in_w32};
			p_w8 <= {p_w8[47:0], in_w8};
		end
	end

	wire [5:0] out_reg = p_reg[41:36];
	wire [4:0] out_lane = p_lane[34:30];
	wire [1:0] out_i = p_i[13:12];
	wire [3:0] out_fmt = p_fmt[27:24];
	wire [7:0] out_vk = p_vk[55:48];
	wire out_vk_ok = p_vk_ok[6];
	wire out_isint = p_isint[6];
	wire out_oob = p_oob[6];
	wire out_fill = p_fill[6];
	wire [31:0] out_w32 = p_w32[223:192];
	wire [7:0] out_w8 = p_w8[55:48];

	/* Output multiplexer after atg_fmt_cvt */
	reg [31:0] p_word;
	always @(*) begin
		if (out_oob || (out_vk != 8'd0 && !out_vk_ok))
			p_word = out_i != 2'd3 ? 32'd0 : out_isint ? 32'd1 : 32'h3F800000;
		else if (out_vk != 8'd0)
			p_word = cvt_out;
		else if (out_fill)
			p_word = out_i != 2'd3 ? 32'd0 : out_isint ? 32'd1 : 32'h3F800000;
		else
			case (out_fmt)
			4'd4: p_word = atg_rop_unorm8(out_w8);
			4'd5: p_word = {24'd0, out_w8};
			4'd6, 4'd7: p_word = cvt_out;
			default: p_word = out_w32;
			endcase
	end

	always @(posedge clk) begin
		if (!rst_n) begin
			c_v <= 1'b0;
			vl_we <= 1'b0;
			vl_reg <= 6'd0;
			vl_lane <= 5'd0;
			vl_data <= 32'd0;
			conv_done <= 1'b0;
			sys_cnt <= 6'd0;
			sys_active <= 1'b0;
		end else begin
			conv_done <= 1'b0;
			if (sys_active) begin
				vl_we <= 1'b1;
				vl_reg <= sys_is_inst ? 6'd61 : 6'd60;
				vl_lane <= sys_lane;
				vl_data <= sys_is_inst ? v_inst_mem[sys_lane] : v_idx_mem[sys_lane];
				sys_cnt <= sys_cnt_next;
				if (sys_cnt == 6'd63) begin
					sys_active <= 1'b0;
					conv_done <= 1'b1;
				end
			end else begin
				vl_we <= p_v[6];
				vl_reg <= out_reg;
				vl_lane <= out_lane;
				vl_data <= p_word;

				if (p_fin[6]) begin
					if (s_used_regs_vs >= 8'd62) begin
						sys_active <= 1'b1;
						sys_cnt <= 6'd0;
					end else begin
						conv_done <= 1'b1;
					end
				end

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
	end

	wire unused_ok = &{1'b0, st_wdata[23:20], st_wdata[15:8], s_off[8:5], vk_inf[67:12],
		vk_inf[8:0], vk_feat[25:20], vk_feat[18:0], sc_co_unused};
endmodule

`default_nettype wire
