/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_conv: Vertex Format Converter.
 * Convert up to 16 input attributes per vertex to internal 32-bit words
 * (fp32 or int32) and write into the SU vector registers (vl_we, vl_reg,
 * vl_lane, vl_data).
 *
 * Supports legacy formats 0..9 and extended VkFormat 1..184 via atg_fmt_info
 * and atg_fmt_cvt. Latency through converter is 7 cycles (matching atg_fmt_cvt).
 *
 * Output destination mapping:
 *   ATTR_DST[k] [5:0]  base SU vector register for attribute k
 *   ATTR_DST[k] [7:6]  number of 32-bit components to output minus 1 (0..3)
 *   ATTR_DST[k] [31:24] VkFormat (0 = legacy, >0 = extended)
 *
 * System input registers (VS inputs):
 *   Reg 60: gl_VertexIndex (lane 0..31)
 *   Reg 61: gl_InstanceIndex (lane 0..31)
 *   Delivered when GHCI_S_VS_WORDS >= 62 after the last attribute of the warp.
 */

`timescale 1ns / 1ps
`default_nettype none

(* ram_style = "registers", rom_style = "distributed" *)
module atg_vf_conv (
	input wire clk,
	input wire rst_n,

	/* State setup from GHCI MMIO */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	/* Input attribute stream from atg_vf_fetch */
	input wire af_valid,
	output wire af_ready,
	input wire [3:0] af_attr,
	input wire [4:0] af_lane,
	input wire [127:0] af_raw,
	input wire af_oob,
	input wire af_last,

	/* Vertex and instance indices from vb stream */
	input wire vb_valid,
	input wire vb_ready,
	input wire [31:0] vb_index,
	input wire [31:0] vb_inst,
	input wire [4:0] vb_lane,

	/* Output to SU register file */
	output reg vl_we,
	output reg [5:0] vl_reg,
	output reg [4:0] vl_lane,
	output reg [31:0] vl_data,
	output reg conv_done
);
	`include "ghci_regs.vh"
	`include "atg_srgb.vh"
	`include "atg_fmt_info.vh"
	`include "atg_rop_unorm8.vh"

	/* Active-high reset nets */
	wire rst = !rst_n;
	(* keep = "true" *) wire rst_p = rst;
	(* keep = "true" *) wire rst_c = rst;
	(* keep = "true" *) wire rst_sys = rst;

	/* Distributed ROM for unorm8 conversion to avoid BRAM inference */
	(* rom_style = "distributed" *) reg [31:0] rom_unorm8 [0:255];
	integer r_i;
	initial begin
		for (r_i = 0; r_i < 256; r_i = r_i + 1)
			rom_unorm8[r_i] = atg_rop_unorm8(r_i[7:0]);
	end

	/* Registered MMIO signals to guarantee <= 16 fanout on all ports and internal nets */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [8:0] st_idx_fmt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [8:0] st_idx_dst;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [8:0] st_idx_vk;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [8:0] st_idx_en;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [8:0] st_idx_vs;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] st_wdata_fmt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] st_wdata_dst;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] st_wdata_vk;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] st_wdata_en;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [31:0] st_wdata_vs;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg st_we_fmt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg st_we_dst;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg st_we_vk;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg st_we_en;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg st_we_vs;

	always @(posedge clk) begin
		st_idx_fmt   <= st_idx;
		st_idx_dst   <= st_idx;
		st_idx_vk    <= st_idx;
		st_idx_en    <= st_idx;
		st_idx_vs    <= st_idx;

		st_wdata_fmt <= st_wdata;
		st_wdata_dst <= st_wdata;
		st_wdata_vk  <= st_wdata;
		st_wdata_en  <= st_wdata;
		st_wdata_vs  <= st_wdata;

		if (rst_sys) begin
			st_we_fmt <= 1'b0;
			st_we_dst <= 1'b0;
			st_we_vk  <= 1'b0;
			st_we_en  <= 1'b0;
			st_we_vs  <= 1'b0;
		end else begin
			st_we_fmt <= st_we;
			st_we_dst <= st_we;
			st_we_vk  <= st_we;
			st_we_en  <= st_we;
			st_we_vs  <= st_we;
		end
	end

	wire st_match_dst = (st_idx_dst[8:4] == GHCI_S_ATTR_DST[8:4]);
	wire st_match_vk  = (st_idx_vk[8:4] == GHCI_S_ATTR_DST[8:4]);
	wire st_match_en  = (st_idx_en[8:4] == GHCI_S_ATTR_DST[8:4]);

	wire [8:0] s_off;
	wire so_bo_unused;
	am_sub #(.W(9)) u_s_off (.a(st_idx_fmt), .b(GHCI_S_ATTR), .bi(1'b0),
		.d(s_off), .bo(so_bo_unused));
	wire s_desc = st_idx_fmt >= GHCI_S_ATTR && st_idx_fmt < GHCI_S_ATTR + 9'd32 && s_off[0];

	wire s_en_val = ({st_wdata_en[31:24], st_wdata_en[7:0]} != 16'd0);

	/* STATE: ATTR[k]_DESC 0x031 + 2k, ATTR_DST[k] 0x1C0 + k.
	 * s_dst, s_vk, and s_en are updated in separate always blocks.
	 */
	(* ram_style = "registers" *) reg [3:0] s_fmt [0:15];
	(* ram_style = "registers" *) reg [7:0] s_dst [0:15];
	(* ram_style = "registers" *) reg [7:0] s_vk [0:15];
	(* ram_style = "registers" *) reg [7:0] s_en_lo;
	(* ram_style = "registers" *) reg [7:0] s_en_hi;

	integer s_init_i;
	initial begin
		s_en_lo = 8'd0;
		s_en_hi = 8'd0;
		for (s_init_i = 0; s_init_i < 16; s_init_i = s_init_i + 1) begin
			s_fmt[s_init_i] = 4'd0;
			s_dst[s_init_i] = 8'd0;
			s_vk[s_init_i] = 8'd0;
		end
	end

	always @(posedge clk) begin
		if (st_we_fmt && s_desc)
			s_fmt[s_off[4:1]] <= st_wdata_fmt[19:16];
	end

	always @(posedge clk) begin
		if (st_we_dst && st_match_dst)
			s_dst[st_idx_dst[3:0]] <= st_wdata_dst[7:0];
	end

	always @(posedge clk) begin
		if (st_we_vk && st_match_vk)
			s_vk[st_idx_vk[3:0]] <= st_wdata_vk[31:24];
	end

	always @(posedge clk) begin
		if (st_we_en && st_match_en) begin
			if (!st_idx_en[3])
				s_en_lo[st_idx_en[2:0]] <= s_en_val;
			else
				s_en_hi[st_idx_en[2:0]] <= s_en_val;
		end
	end

	/* STATE: used_regs_vs (from GHCI_S_VS_WORDS or 0x029) */
	reg [7:0] s_used_regs_vs;
	always @(posedge clk) begin
		if (rst_sys)
			s_used_regs_vs <= 8'd0;
		else if (st_we_vs && (st_idx_vs == GHCI_S_VS_WORDS || st_idx_vs == 9'h029))
			s_used_regs_vs <= st_wdata_vs[7:0];
	end

	/* Replicated vertex/instance input registers: equivalent_register_removal = "no" */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg b0_wr_i0, b0_wr_i1, b0_wr_s0, b0_wr_s1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg b1_wr_i0, b1_wr_i1, b1_wr_s0, b1_wr_s1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lane_b0_i0, lane_b0_i1, lane_b0_s0, lane_b0_s1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] lane_b1_i0, lane_b1_i1, lane_b1_s0, lane_b1_s1;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] vb_idx_lo_b0, vb_idx_hi_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] vb_idx_lo_b1, vb_idx_hi_b1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] vb_inst_lo_b0, vb_inst_hi_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [15:0] vb_inst_lo_b1, vb_inst_hi_b1;

	always @(posedge clk) begin
		b0_wr_i0 <= vb_valid && vb_ready && !vb_lane[4];
		b0_wr_i1 <= vb_valid && vb_ready && !vb_lane[4];
		b0_wr_s0 <= vb_valid && vb_ready && !vb_lane[4];
		b0_wr_s1 <= vb_valid && vb_ready && !vb_lane[4];

		b1_wr_i0 <= vb_valid && vb_ready && vb_lane[4];
		b1_wr_i1 <= vb_valid && vb_ready && vb_lane[4];
		b1_wr_s0 <= vb_valid && vb_ready && vb_lane[4];
		b1_wr_s1 <= vb_valid && vb_ready && vb_lane[4];

		lane_b0_i0 <= vb_lane[3:0];
		lane_b0_i1 <= vb_lane[3:0];
		lane_b0_s0 <= vb_lane[3:0];
		lane_b0_s1 <= vb_lane[3:0];

		lane_b1_i0 <= vb_lane[3:0];
		lane_b1_i1 <= vb_lane[3:0];
		lane_b1_s0 <= vb_lane[3:0];
		lane_b1_s1 <= vb_lane[3:0];

		vb_idx_lo_b0 <= vb_index[15:0];
		vb_idx_hi_b0 <= vb_index[31:16];
		vb_idx_lo_b1 <= vb_index[15:0];
		vb_idx_hi_b1 <= vb_index[31:16];

		vb_inst_lo_b0 <= vb_inst[15:0];
		vb_inst_hi_b0 <= vb_inst[31:16];
		vb_inst_lo_b1 <= vb_inst[15:0];
		vb_inst_hi_b1 <= vb_inst[31:16];
	end

	/* 2-Bank 16-entry register storage: 8 independent arrays with exactly 16 FFs per word */
	(* ram_style = "registers" *) reg [15:0] v_idx_b0_lo [0:15];
	(* ram_style = "registers" *) reg [15:0] v_idx_b0_hi [0:15];
	(* ram_style = "registers" *) reg [15:0] v_idx_b1_lo [0:15];
	(* ram_style = "registers" *) reg [15:0] v_idx_b1_hi [0:15];

	(* ram_style = "registers" *) reg [15:0] v_inst_b0_lo [0:15];
	(* ram_style = "registers" *) reg [15:0] v_inst_b0_hi [0:15];
	(* ram_style = "registers" *) reg [15:0] v_inst_b1_lo [0:15];
	(* ram_style = "registers" *) reg [15:0] v_inst_b1_hi [0:15];

	integer b_i;
	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b0_wr_i0 && (lane_b0_i0 == b_i[3:0]))
				v_idx_b0_lo[b_i] <= vb_idx_lo_b0;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b0_wr_i1 && (lane_b0_i1 == b_i[3:0]))
				v_idx_b0_hi[b_i] <= vb_idx_hi_b0;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b0_wr_s0 && (lane_b0_s0 == b_i[3:0]))
				v_inst_b0_lo[b_i] <= vb_inst_lo_b0;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b0_wr_s1 && (lane_b0_s1 == b_i[3:0]))
				v_inst_b0_hi[b_i] <= vb_inst_hi_b0;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b1_wr_i0 && (lane_b1_i0 == b_i[3:0]))
				v_idx_b1_lo[b_i] <= vb_idx_lo_b1;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b1_wr_i1 && (lane_b1_i1 == b_i[3:0]))
				v_idx_b1_hi[b_i] <= vb_idx_hi_b1;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b1_wr_s0 && (lane_b1_s0 == b_i[3:0]))
				v_inst_b1_lo[b_i] <= vb_inst_lo_b1;
		end
	end

	always @(posedge clk) begin
		for (b_i = 0; b_i < 16; b_i = b_i + 1) begin
			if (b1_wr_s1 && (lane_b1_s1 == b_i[3:0]))
				v_inst_b1_hi[b_i] <= vb_inst_hi_b1;
		end
	end

	/* System input delivery FSM */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [5:0] sys_cnt_idx;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [5:0] sys_cnt_inst;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [5:0] sys_cnt_ctrl;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_active;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_active_d0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_active_d1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_active_ctrl;

	wire sys_is_inst = sys_cnt_ctrl[0];
	wire [5:0] sys_cnt_idx_next;
	wire [5:0] sys_cnt_inst_next;
	wire [5:0] sys_cnt_ctrl_next;
	wire sc_idx_unused, sc_inst_unused, sc_ctrl_unused;
	am_add #(.W(6)) u_sys_cnt_idx  (.a(sys_cnt_idx),  .b(6'd0), .ci(1'b1), .s(sys_cnt_idx_next),  .co(sc_idx_unused));
	am_add #(.W(6)) u_sys_cnt_inst (.a(sys_cnt_inst), .b(6'd0), .ci(1'b1), .s(sys_cnt_inst_next), .co(sc_inst_unused));
	am_add #(.W(6)) u_sys_cnt_ctrl (.a(sys_cnt_ctrl), .b(6'd0), .ci(1'b1), .s(sys_cnt_ctrl_next), .co(sc_ctrl_unused));

	/* Replicated read address signals: each in its own block to prevent merged nets */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_i0_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_i1_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_s0_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_s1_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_i0_b1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_i1_b1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_s0_b1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] sys_lane_s1_b1;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_bank_i0, sys_bank_i1, sys_bank_s0, sys_bank_s1;
	reg [4:0] sys_lane_out;

	always @(posedge clk) sys_lane_i0_b0 <= sys_cnt_idx_next[5:2];
	always @(posedge clk) sys_lane_i1_b0 <= sys_cnt_idx_next[5:2];
	always @(posedge clk) sys_lane_i0_b1 <= sys_cnt_idx_next[5:2];
	always @(posedge clk) sys_lane_i1_b1 <= sys_cnt_idx_next[5:2];

	always @(posedge clk) sys_lane_s0_b0 <= sys_cnt_inst_next[5:2];
	always @(posedge clk) sys_lane_s1_b0 <= sys_cnt_inst_next[5:2];
	always @(posedge clk) sys_lane_s0_b1 <= sys_cnt_inst_next[5:2];
	always @(posedge clk) sys_lane_s1_b1 <= sys_cnt_inst_next[5:2];

	always @(posedge clk) sys_bank_i0    <= sys_cnt_ctrl_next[5] && sys_cnt_ctrl_next[1];
	always @(posedge clk) sys_bank_i1    <= sys_cnt_ctrl_next[5] && sys_cnt_ctrl_next[1];
	always @(posedge clk) sys_bank_s0    <= sys_cnt_ctrl_next[5] && sys_cnt_ctrl_next[1];
	always @(posedge clk) sys_bank_s1    <= sys_cnt_ctrl_next[5] && sys_cnt_ctrl_next[1];
	always @(posedge clk) sys_lane_out   <= sys_cnt_ctrl[5:1];

	wire [15:0] idx_b0_lo_rd = v_idx_b0_lo[sys_lane_i0_b0];
	wire [15:0] idx_b0_hi_rd = v_idx_b0_hi[sys_lane_i1_b0];
	wire [15:0] inst_b0_lo_rd = v_inst_b0_lo[sys_lane_s0_b0];
	wire [15:0] inst_b0_hi_rd = v_inst_b0_hi[sys_lane_s1_b0];

	wire [15:0] idx_b1_lo_rd = v_idx_b1_lo[sys_lane_i0_b1];
	wire [15:0] idx_b1_hi_rd = v_idx_b1_hi[sys_lane_i1_b1];
	wire [15:0] inst_b1_lo_rd = v_inst_b1_lo[sys_lane_s0_b1];
	wire [15:0] inst_b1_hi_rd = v_inst_b1_hi[sys_lane_s1_b1];

	reg [15:0] v_idx_lo_rd, v_idx_hi_rd;
	reg [15:0] v_inst_lo_rd, v_inst_hi_rd;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_is_inst_b0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_is_inst_b1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_is_inst_b2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg sys_is_inst_b3;
	reg sys_is_inst_reg;
	reg [4:0] sys_lane_r;
	reg sys_active_pipe;

	always @(posedge clk) begin
		v_idx_lo_rd <= sys_bank_i0 ? idx_b1_lo_rd : idx_b0_lo_rd;
		v_idx_hi_rd <= sys_bank_i1 ? idx_b1_hi_rd : idx_b0_hi_rd;
		v_inst_lo_rd <= sys_bank_s0 ? inst_b1_lo_rd : inst_b0_lo_rd;
		v_inst_hi_rd <= sys_bank_s1 ? inst_b1_hi_rd : inst_b0_hi_rd;
		sys_is_inst_b0 <= sys_is_inst;
		sys_is_inst_b1 <= sys_is_inst;
		sys_is_inst_b2 <= sys_is_inst;
		sys_is_inst_b3 <= sys_is_inst;
		sys_is_inst_reg <= sys_is_inst;
		sys_lane_r <= sys_lane_out;
		if (rst_sys)
			sys_active_pipe <= 1'b0;
		else
			sys_active_pipe <= sys_active;
	end

	wire [31:0] sys_data_pipe = {
		(sys_is_inst_b3 ? v_inst_hi_rd[15:8] : v_idx_hi_rd[15:8]),
		(sys_is_inst_b2 ? v_inst_hi_rd[7:0]  : v_idx_hi_rd[7:0]),
		(sys_is_inst_b1 ? v_inst_lo_rd[15:8] : v_idx_lo_rd[15:8]),
		(sys_is_inst_b0 ? v_inst_lo_rd[7:0]  : v_idx_lo_rd[7:0])
	};
	wire [5:0] sys_reg_pipe = sys_is_inst_reg ? 6'd61 : 6'd60;

	/* Forward declarations of stage c control signals needed by Stage 0 & Stage 1 */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg c_v;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg c_v_pipe;
	reg [7:0] c_dst;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] c_i;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] c_i_raw;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [1:0] c_i_cvt;
	wire c_end = c_v && (c_i == c_dst[7:6]);

	/* Stage 0 -> Stage 1 -> Stage c Elastic Pipeline Handshakes */
	reg s0_v;
	reg s1_v;
	wire c_ready = !c_v || c_end;
	wire s1_ready = !s1_v || c_ready;
	wire s0_ready = !s0_v || s1_ready;

	assign af_ready = !s0_v || s0_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_v     = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_meta  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_attr0 = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_attr1 = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw0  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw1  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw2  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw3  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw4  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw5  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw6  = af_valid && af_ready;
	(* keep = "true", max_fanout = 16 *) wire s0_take_raw7  = af_valid && af_ready;

	(* keep = "true", max_fanout = 16 *) wire s1_take_v0   = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_v1   = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_meta = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_cfg  = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_vk0  = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_vk1  = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_vk2  = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw0 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw1 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw2 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw3 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw4 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw5 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw6 = s0_v && s1_ready;
	(* keep = "true", max_fanout = 16 *) wire s1_take_raw7 = s0_v && s1_ready;

	wire c_take  = s1_v && c_ready;

	/* Stage 0: capture af_* inputs directly at module boundary */
	reg [127:0] s0_raw;
	reg [4:0] s0_lane;
	reg s0_oob;
	reg s0_last;

	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_fmt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_dst0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_dst1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_vk0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_vk1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] s0_attr_en;

	always @(posedge clk) begin
		if (rst_sys) begin
			s0_v <= 1'b0;
		end else begin
			if (s0_take_v)
				s0_v <= 1'b1;
			else if (s1_take_v0)
				s0_v <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (s0_take_meta) begin
			s0_lane <= af_lane;
			s0_oob  <= af_oob;
			s0_last <= af_last;
		end
	end

	always @(posedge clk) begin
		if (s0_take_attr0) begin
			s0_attr_fmt  <= af_attr;
			s0_attr_dst0 <= af_attr;
			s0_attr_dst1 <= af_attr;
		end
	end

	always @(posedge clk) begin
		if (s0_take_attr1) begin
			s0_attr_vk0  <= af_attr;
			s0_attr_vk1  <= af_attr;
			s0_attr_en   <= af_attr;
		end
	end

	always @(posedge clk) if (s0_take_raw0) s0_raw[15:0]    <= af_raw[15:0];
	always @(posedge clk) if (s0_take_raw1) s0_raw[31:16]   <= af_raw[31:16];
	always @(posedge clk) if (s0_take_raw2) s0_raw[47:32]   <= af_raw[47:32];
	always @(posedge clk) if (s0_take_raw3) s0_raw[63:48]   <= af_raw[63:48];
	always @(posedge clk) if (s0_take_raw4) s0_raw[79:64]   <= af_raw[79:64];
	always @(posedge clk) if (s0_take_raw5) s0_raw[95:80]   <= af_raw[95:80];
	always @(posedge clk) if (s0_take_raw6) s0_raw[111:96]  <= af_raw[111:96];
	always @(posedge clk) if (s0_take_raw7) s0_raw[127:112] <= af_raw[127:112];

	/* Stage 1: Read state tables using registered s0_attr_* addresses */
	wire [3:0] s_dst_lo_val = s_dst[s0_attr_dst0][3:0];
	wire [3:0] s_dst_hi_val = s_dst[s0_attr_dst1][7:4];
	wire [7:0] s_dst_val = {s_dst_hi_val, s_dst_lo_val};

	wire [3:0] s_vk_lo_val = s_vk[s0_attr_vk0][3:0];
	wire [3:0] s_vk_hi_val = s_vk[s0_attr_vk1][7:4];
	wire [7:0] s_vk_val = {s_vk_hi_val, s_vk_lo_val};

	wire [3:0] s_fmt_val = s_fmt[s0_attr_fmt];
	wire s_en_val_in = s0_attr_en[3] ? s_en_hi[s0_attr_en[2:0]] : s_en_lo[s0_attr_en[2:0]];

	reg [127:0] s1_raw;
	reg [4:0] s1_lane;
	reg s1_oob;
	reg s1_last;
	reg s1_en;
	reg [7:0] s1_dst;
	reg [3:0] s1_fmt;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] s1_vk_0;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] s1_vk_1;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] s1_vk_2;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] s1_vk_3;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [7:0] s1_vk_4;

	always @(posedge clk) begin
		if (rst_sys) begin
			s1_v <= 1'b0;
		end else begin
			if (s1_take_v1)
				s1_v <= 1'b1;
			else if (c_take)
				s1_v <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (s1_take_meta) begin
			s1_lane <= s0_lane;
			s1_oob  <= s0_oob;
			s1_last <= s0_last;
			s1_en   <= s_en_val_in;
		end
	end

	always @(posedge clk) begin
		if (s1_take_cfg) begin
			s1_dst  <= s_dst_val;
			s1_fmt  <= s_fmt_val;
		end
	end

	always @(posedge clk) begin
		if (s1_take_vk0) begin
			s1_vk_0 <= s_vk_val;
			s1_vk_1 <= s_vk_val;
		end
	end

	always @(posedge clk) begin
		if (s1_take_vk1) begin
			s1_vk_2 <= s_vk_val;
			s1_vk_3 <= s_vk_val;
		end
	end

	always @(posedge clk) begin
		if (s1_take_vk2) begin
			s1_vk_4 <= s_vk_val;
		end
	end

	always @(posedge clk) if (s1_take_raw0) s1_raw[15:0]    <= s0_raw[15:0];
	always @(posedge clk) if (s1_take_raw1) s1_raw[31:16]   <= s0_raw[31:16];
	always @(posedge clk) if (s1_take_raw2) s1_raw[47:32]   <= s0_raw[47:32];
	always @(posedge clk) if (s1_take_raw3) s1_raw[63:48]   <= s0_raw[63:48];
	always @(posedge clk) if (s1_take_raw4) s1_raw[79:64]   <= s0_raw[79:64];
	always @(posedge clk) if (s1_take_raw5) s1_raw[95:80]   <= s0_raw[95:80];
	always @(posedge clk) if (s1_take_raw6) s1_raw[111:96]  <= s0_raw[111:96];
	always @(posedge clk) if (s1_take_raw7) s1_raw[127:112] <= s0_raw[127:112];

	/* Stage c: Format conversion inputs */
	reg c_last;
	reg [15:0] c_raw_0, c_raw_1, c_raw_2, c_raw_3;
	reg [15:0] c_raw_4, c_raw_5, c_raw_6, c_raw_7;
	reg [4:0] c_lane;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] c_fmt_pipe;
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg [3:0] c_fmt_ncomp;
	(* ram_style = "registers" *) reg [7:0] c_vk;
	reg c_oob;

	wire [7:0] vk_eff0 = (s1_vk_0 != 8'd0) ? s1_vk_0 : 8'd97;
	wire [7:0] vk_eff1 = (s1_vk_1 != 8'd0) ? s1_vk_1 : 8'd97;
	wire [7:0] vk_eff2 = (s1_vk_2 != 8'd0) ? s1_vk_2 : 8'd97;
	wire [7:0] vk_eff3 = (s1_vk_3 != 8'd0) ? s1_vk_3 : 8'd97;
	wire [7:0] vk_eff4 = (s1_vk_4 != 8'd0) ? s1_vk_4 : 8'd97;

	wire [67:0] raw_inf0 = atg_fmt_info(vk_eff0);
	wire [67:0] raw_inf1 = atg_fmt_info(vk_eff1);
	wire [67:0] raw_inf2 = atg_fmt_info(vk_eff2);
	wire [67:0] raw_inf3 = atg_fmt_info(vk_eff3);
	wire [67:0] raw_inf4 = atg_fmt_info(vk_eff4);

	reg [13:0] c_inf_0;
	reg [13:0] c_inf_1;
	reg [13:0] c_inf_2;
	reg [13:0] c_inf_3;
	reg [11:0] c_inf_4;

	wire c_en = c_take && s1_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_r0 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_r1 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_meta0 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_meta1 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_meta2 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_inf0 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_inf1 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_inf2 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_inf3 = c_en;
	(* keep = "true", max_fanout = 16 *) wire c_en_inf4 = c_en;

	always @(posedge clk) begin
		if (c_en_r0) begin
			c_raw_0 <= s1_raw[15:0];
			c_raw_1 <= s1_raw[31:16];
			c_raw_2 <= s1_raw[47:32];
			c_raw_3 <= s1_raw[63:48];
		end
		if (c_en_r1) begin
			c_raw_4 <= s1_raw[79:64];
			c_raw_5 <= s1_raw[95:80];
			c_raw_6 <= s1_raw[111:96];
			c_raw_7 <= s1_raw[127:112];
		end

		if (c_en_meta0) begin
			c_lane <= s1_lane;
			c_fmt_pipe  <= s1_fmt;
			c_fmt_ncomp <= s1_fmt;
		end
		if (c_en_meta1) begin
			c_dst <= s1_dst;
		end
		if (c_en_meta2) begin
			c_vk   <= s1_vk_0;
			c_oob  <= s1_oob;
			c_last <= s1_last;
		end

		if (c_en_inf0) c_inf_0 <= raw_inf0[13:0];
		if (c_en_inf1) c_inf_1 <= raw_inf1[27:14];
		if (c_en_inf2) c_inf_2 <= raw_inf2[41:28];
		if (c_en_inf3) c_inf_3 <= raw_inf3[55:42];
		if (c_en_inf4) c_inf_4 <= raw_inf4[67:56];
	end

	wire [127:0] c_raw = {c_raw_7, c_raw_6, c_raw_5, c_raw_4,
	                      c_raw_3, c_raw_2, c_raw_1, c_raw_0};

	wire [31:0] cvt_out;
	wire [67:0] cvt_inf = {c_inf_4, c_inf_3, c_inf_2, c_inf_1, c_inf_0};

	(* ram_style = "distributed", rom_style = "distributed" *)
	atg_fmt_cvt u_cvt (
		.clk(clk),
		.i_raw(c_raw),
		.i_inf(cvt_inf),
		.i_k(c_i_cvt),
		.i_sten(1'b0),
		.o_val(cvt_out)
	);

	reg [2:0] ncomp;
	always @(*)
		case (c_fmt_ncomp)
		4'd0, 4'd8: ncomp = 3'd1;
		4'd1, 4'd6, 4'd9: ncomp = 3'd2;
		4'd2: ncomp = 3'd3;
		4'd3, 4'd4, 4'd5, 4'd7: ncomp = 3'd4;
		default: ncomp = 3'd0;
		endcase
	wire isint_l = c_fmt_ncomp == 4'd5 || c_fmt_ncomp == 4'd8 || c_fmt_ncomp == 4'd9;

	(* rom_style = "distributed" *) wire [25:0] vk_feat = atg_fmt_feat(c_vk, 1'b0);
	wire vk_ok = vk_feat[19];	/* VERTEX_BUFFER */
	wire vk_int = vk_ok && (cvt_inf[11:9] == ATG_FMT_UINT || cvt_inf[11:9] == ATG_FMT_SINT);
	wire isint = c_vk != 8'd0 ? vk_int : isint_l;

	/* The register of component c_i, and the next component. */
	wire [5:0] reg_c;
	wire [1:0] c_i_next;
	wire rc_co_unused, cn_co_unused;
	am_add #(.W(6)) u_reg (.a(c_dst[5:0]), .b({4'd0, c_i}), .ci(1'b0),
		.s(reg_c), .co(rc_co_unused));
	am_add #(.W(2)) u_c_i (.a(c_i), .b(2'd0), .ci(1'b1), .s(c_i_next), .co(cn_co_unused));

	/* Control logic for stage c with reset */
	always @(posedge clk) begin
		if (rst_c) begin
			c_v <= 1'b0;
			c_v_pipe <= 1'b0;
			c_i <= 2'd0;
			c_i_raw <= 2'd0;
			c_i_cvt <= 2'd0;
		end else begin
			if (c_v) begin
				c_i <= c_i_next;
				c_i_raw <= c_i_next;
				c_i_cvt <= c_i_next;
			end
			if (c_end) begin
				c_v <= 1'b0;
				c_v_pipe <= 1'b0;
			end
			if (c_take && s1_en) begin
				c_v <= 1'b1;
				c_v_pipe <= 1'b1;
				c_i <= 2'd0;
				c_i_raw <= 2'd0;
				c_i_cvt <= 2'd0;
			end
		end
	end

	/* 7-stage pipeline shift registers */
	(* ram_style = "registers", shreg_extract = "no", max_fanout = 16 *) reg [6:0] p_v;
	(* ram_style = "registers", shreg_extract = "no", max_fanout = 16 *) reg [41:0] p_reg;
	(* ram_style = "registers", shreg_extract = "no" *) reg [34:0] p_lane;
	(* ram_style = "registers", shreg_extract = "no", max_fanout = 16 *) reg [6:0] p_fin;

	wire in_v = c_v_pipe;
	wire [5:0] in_reg = reg_c;
	wire [4:0] in_lane = c_lane;
	wire [1:0] in_i = c_i;
	wire [3:0] in_fmt = c_fmt_pipe;
	wire [7:0] in_vk = c_vk;
	wire in_vk_ok = vk_ok;
	wire in_isint = isint;
	wire in_oob = c_oob;
	wire in_fill = (c_vk == 8'd0) && ({1'b0, c_i} >= ncomp);

	reg [31:0] in_w32;
	reg [7:0] in_w8;
	always @(*) begin
		case (c_i_raw)
		2'd0: begin in_w32 = c_raw[31:0]; in_w8 = c_raw[7:0]; end
		2'd1: begin in_w32 = c_raw[63:32]; in_w8 = c_raw[15:8]; end
		2'd2: begin in_w32 = c_raw[95:64]; in_w8 = c_raw[23:16]; end
		default: begin in_w32 = c_raw[127:96]; in_w8 = c_raw[31:24]; end
		endcase
	end

	wire in_fin = (c_end && c_last) || (c_take && !s1_en && s1_last);

	/* Precomputed legacy datapath classification to eliminate logic levels at output */
	wire in_use_cvt = !in_oob && (
		(in_vk != 8'd0 && in_vk_ok) ||
		(in_vk == 8'd0 && !in_fill && (in_fmt == 4'd6 || in_fmt == 4'd7))
	);
	wire in_is_fill = in_oob || (in_vk != 8'd0 && !in_vk_ok) || in_fill;
	wire [31:0] in_fill_val = (in_i != 2'd3) ? 32'd0 : (in_isint ? 32'd1 : 32'h3F800000);

	/* Stage 0 payload registers */
	(* equivalent_register_removal = "no", max_fanout = 16 *) reg p0_is_fill_lo, p0_is_fill_hi;
	reg [31:0] p0_fill_val;
	reg [3:0] p0_fmt;
	reg [7:0] p0_w8;
	reg [31:0] p0_w32;

	/* Stage 1 unorm8 ROM lookup */
	wire [31:0] p0_unorm8 = rom_unorm8[p0_w8];
	reg [15:0] p1_legacy_lo;
	reg [15:0] p1_legacy_hi;
	always @(*) begin
		if (p0_is_fill_lo)
			p1_legacy_lo = p0_fill_val[15:0];
		else if (p0_fmt == 4'd4)
			p1_legacy_lo = p0_unorm8[15:0];
		else if (p0_fmt == 4'd5)
			p1_legacy_lo = {8'd0, p0_w8};
		else
			p1_legacy_lo = p0_w32[15:0];

		if (p0_is_fill_hi)
			p1_legacy_hi = p0_fill_val[31:16];
		else if (p0_fmt == 4'd4)
			p1_legacy_hi = p0_unorm8[31:16];
		else if (p0_fmt == 4'd5)
			p1_legacy_hi = 16'd0;
		else
			p1_legacy_hi = p0_w32[31:16];
	end

	/* Pipelined legacy/fill/oob word generation */
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_1;
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_2;
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_3;
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_4;
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_5;
	(* ram_style = "registers", shreg_extract = "no" *) reg [31:0] p_legacy_6;

	(* ram_style = "registers", shreg_extract = "no", max_fanout = 16 *) reg [6:0] p_is_cvt;

	/* Shift register control signals with synchronous reset */
	always @(posedge clk) begin
		if (rst_p) begin
			p_v <= 7'd0;
			p_fin <= 7'd0;
			p_is_cvt <= 7'd0;
		end else begin
			p_v <= {p_v[5:0], in_v};
			p_fin <= {p_fin[5:0], in_fin};
			p_is_cvt <= {p_is_cvt[5:0], in_use_cvt};
		end
	end

	/* Shift register payload signals without reset */
	always @(posedge clk) begin
		p_reg <= {p_reg[35:0], in_reg};
		p_lane <= {p_lane[29:0], in_lane};

		p0_is_fill_lo <= in_is_fill;
		p0_is_fill_hi <= in_is_fill;
		p0_fill_val <= in_fill_val;
		p0_fmt <= in_fmt;
		p0_w8 <= in_w8;
		p0_w32 <= in_w32;

		p_legacy_1 <= {p1_legacy_hi, p1_legacy_lo};
		p_legacy_2 <= p_legacy_1;
		p_legacy_3 <= p_legacy_2;
		p_legacy_4 <= p_legacy_3;
		p_legacy_5 <= p_legacy_4;
		p_legacy_6 <= p_legacy_5;
	end

	wire [5:0] out_reg = p_reg[41:36];
	wire [4:0] out_lane = p_lane[34:30];

	/* Clean 1-LUT multiplexer for output data path */
	(* keep = "true", max_fanout = 16 *) wire p_is_cvt_lo = p_is_cvt[6];
	(* keep = "true", max_fanout = 16 *) wire p_is_cvt_hi = p_is_cvt[6];

	wire [15:0] p_word_lo = p_is_cvt_lo ? cvt_out[15:0] : p_legacy_6[15:0];
	wire [15:0] p_word_hi = p_is_cvt_hi ? cvt_out[31:16] : p_legacy_6[31:16];

	/* Replicated system input start triggers to limit fanout */
	wire sys_start = p_fin[6] && (s_used_regs_vs >= 8'd62);
	(* keep = "true", max_fanout = 16 *) wire sys_start_cnt  = sys_start;
	(* keep = "true", max_fanout = 16 *) wire sys_start_act  = sys_start;

	/* System input & output control logic with reset */
	always @(posedge clk) begin
		if (rst_sys) begin
			vl_we <= 1'b0;
			conv_done <= 1'b0;
			sys_active <= 1'b0;
			sys_active_d0 <= 1'b0;
			sys_active_d1 <= 1'b0;
			sys_active_ctrl <= 1'b0;
			sys_cnt_idx  <= 6'd0;
			sys_cnt_inst <= 6'd0;
			sys_cnt_ctrl <= 6'd0;
		end else begin
			conv_done <= 1'b0;
			if (sys_active) begin
				sys_cnt_idx  <= sys_cnt_idx_next;
				sys_cnt_inst <= sys_cnt_inst_next;
				sys_cnt_ctrl <= sys_cnt_ctrl_next;
				if (sys_cnt_ctrl == 6'd63) begin
					sys_active <= 1'b0;
					sys_active_d0 <= 1'b0;
					sys_active_d1 <= 1'b0;
					sys_active_ctrl <= 1'b0;
				end
			end else begin
				if (p_fin[6]) begin
					if (sys_start_act) begin
						sys_active <= 1'b1;
						sys_active_d0 <= 1'b1;
						sys_active_d1 <= 1'b1;
						sys_active_ctrl <= 1'b1;
					end else begin
						conv_done <= 1'b1;
					end
				end
				if (sys_start_cnt) begin
					sys_cnt_idx  <= 6'd0;
					sys_cnt_inst <= 6'd0;
					sys_cnt_ctrl <= 6'd0;
				end
			end

			if (sys_active_pipe) begin
				vl_we <= 1'b1;
				if (!sys_active && sys_cnt_ctrl == 6'd0)
					conv_done <= 1'b1;
			end else begin
				vl_we <= p_v[6];
			end
		end
	end

	/* Output data path registers without reset */
	always @(posedge clk) begin
		vl_reg <= sys_active_ctrl ? sys_reg_pipe : out_reg;
		vl_lane <= sys_active_ctrl ? sys_lane_r : out_lane;
		vl_data[15:0] <= sys_active_d0 ? sys_data_pipe[15:0] : p_word_lo;
		vl_data[31:16] <= sys_active_d1 ? sys_data_pipe[31:16] : p_word_hi;
	end

	wire unused_ok = &{1'b0, st_wdata[23:20], st_wdata[15:8], s_off[8:5], cvt_inf[67:12],
		cvt_inf[8:0], vk_feat[25:20], vk_feat[18:0], sc_idx_unused, sc_inst_unused, sc_ctrl_unused,
		s1_raw[63:16], s1_raw[127:80]};
endmodule

`default_nettype wire
