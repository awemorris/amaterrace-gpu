/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rop_regs: ROP State Register Bank (design §2.3, ws002-p001).
 * Captures broadcast STATE writes for the ROP range (0x070..0x08F)
 * and exposes decoded configuration signals for blend, logic op,
 * formats, write masks, constants, etc.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rop_regs (
	input wire clk,
	input wire rst_n,
	/* STATE broadcast (from atg_cp_state) */
	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	/* Decoded state outputs */
	output reg [1:0] rt_format0,
	output reg [31:0] rt_formats,
	output wire [4*27-1:0] blend_modes,
	output reg [15:0] write_mask,
	output reg [31:0] blend_const,
	output wire [31:0] blend_const_fp32,
	output reg kc_sel,
	output reg occ_en,
	output reg logic_op_en,
	output reg [3:0] logic_op,
	output wire [3:0] logic_op_ens,
	output wire [15:0] logic_ops,
	output reg dual_src_en
);
	`include "ghci_regs.vh"

	reg [26:0] bls [0:3];
	reg lop_en [0:3];
	reg [3:0] lop_op [0:3];
	reg [31:0] kcf;	/* fp32 constants as bytes */

	wire [1:0] s_k;
	wire s_k_co_unused;
	am_add #(.W(2)) u_s_k (.a(st_idx[1:0]), .b(2'd0), .ci(1'b1), .s(s_k), .co(s_k_co_unused));

	wire [7:0] kcf_n;
	atg_rop_f2u8 u_kcf (.f(st_wdata), .u(kcf_n));

	integer i;
	always @(posedge clk) begin
		if (!rst_n) begin
			rt_format0 <= 2'd0;
			rt_formats <= 32'd0;
			for (i = 0; i < 4; i = i + 1) begin
				bls[i] <= 27'd0;
				lop_en[i] <= 1'b0;
				lop_op[i] <= 4'd0;
			end
			write_mask <= 16'd0;
			blend_const <= 32'd0;
			kcf <= 32'd0;
			kc_sel <= 1'b0;
			occ_en <= 1'b0;
			logic_op_en <= 1'b0;
			logic_op <= 4'd0;
			dual_src_en <= 1'b0;
		end else if (st_we) begin
			if (st_idx == GHCI_S_RT_FORMAT)
				rt_format0 <= st_wdata[1:0];
			if (st_idx == GHCI_S_RT_FORMATS)
				rt_formats <= st_wdata;
			if (st_idx == GHCI_S_WRITE_MASK)
				write_mask <= st_wdata[15:0];
			if (st_idx == GHCI_S_BLEND)
				bls[0] <= st_wdata[26:0];
			if (st_idx >= GHCI_S_BLEND1 && st_idx < GHCI_S_BLEND1 + 9'd3)
				bls[s_k] <= st_wdata[26:0];
			if (st_idx == GHCI_S_BLEND_CONST)
				blend_const <= st_wdata;
			if (st_idx >= GHCI_S_BLEND_CONST_R && st_idx < GHCI_S_BLEND_CONST_R + 9'd4)
				kcf[8 * s_k +: 8] <= kcf_n;
			if (st_idx == GHCI_S_ROP_CTRL) begin
				occ_en <= st_wdata[0];
				kc_sel <= st_wdata[1];
				logic_op_en <= st_wdata[2];
				logic_op <= st_wdata[6:3];
				for (i = 0; i < 4; i = i + 1) begin
					lop_en[i] <= st_wdata[2];
					lop_op[i] <= st_wdata[6:3];
				end
				dual_src_en <= st_wdata[7];
			end
			if (st_idx == GHCI_S_LOGIC_OP) begin
				logic_op_en <= st_wdata[0];
				logic_op <= st_wdata[4:1];
				if (st_wdata[31:8] == 24'd0) begin
					for (i = 0; i < 4; i = i + 1) begin
						lop_en[i] <= st_wdata[0];
						lop_op[i] <= st_wdata[4:1];
					end
				end else begin
					lop_en[0] <= st_wdata[0];
					lop_op[0] <= st_wdata[4:1];
					lop_en[1] <= st_wdata[8];
					lop_op[1] <= st_wdata[12:9];
					lop_en[2] <= st_wdata[16];
					lop_op[2] <= st_wdata[20:17];
					lop_en[3] <= st_wdata[24];
					lop_op[3] <= st_wdata[28:25];
				end
			end
		end
	end

	assign blend_modes = {bls[3], bls[2], bls[1], bls[0]};
	assign blend_const_fp32 = kcf;
	assign logic_op_ens = {lop_en[3], lop_en[2], lop_en[1], lop_en[0]};
	assign logic_ops = {lop_op[3], lop_op[2], lop_op[1], lop_op[0]};

	wire unused_ok = &{1'b0, s_k_co_unused};
endmodule

`default_nettype wire
