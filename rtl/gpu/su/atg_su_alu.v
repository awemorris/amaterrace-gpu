/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_alu: the integer ALU of the SU (spec/gpu/su/atg_su_alu.md), NPHYS
 * lanes: add/sub, shifts, bitwise logic, Boolean compares (all ones/0),
 * Zbb min/max/andn/orn/xnor, sel (bitwise multiplexer), and lui/movi.
 *
 * Real 6-stage physical pipeline (ws001-p010):
 *   Stage 1 (EX1): Operand latching, bitwise logic, operand prep for add/sub and shift
 *   Stage 2 (EX2): 33-bit addition and subtraction (am_addsub)
 *   Stage 3 (EX3): 33-bit barrel shifter (am_shift) and comparison logic
 *   Stage 4 (EX4): Operation result multiplexer
 *   Stage 5 (EX5): Writeback preparation and formatting
 *   Stage 6 (WB):  Output registers driving s_* exactly SHORT_LAT (6) cycles after x_valid
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_alu #(
	parameter NPHYS = 8,
	parameter NWARPS = 4,
	parameter WARP_W = 2,
	parameter GRP_W = 2,
	parameter SBE_W = 2,
	parameter UOP_W = 104,
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result */
) (
	input wire clk,
	input wire rst_n,
	input wire en,

	/* Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units) */
	input wire x_valid,
	input wire [WARP_W-1:0] x_warp,
	input wire [GRP_W-1:0] x_grp,
	input wire x_last,
	input wire [SBE_W:0] x_sbe,
	input wire [15:0] x_pc,
	input wire [UOP_W-1:0] x_uop,
	input wire [NPHYS*32-1:0] x_a,
	input wire [NPHYS*32-1:0] x_b,
	input wire [NPHYS*32-1:0] x_c,
	input wire [2*NPHYS-1:0] x_mask,
	input wire [31:0] x_info,
	output wire x_ready,

	/* Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid) */
	output wire s_valid,
	output wire [WARP_W-1:0] s_warp,
	output wire [GRP_W-1:0] s_grp,
	output wire [6:0] s_rd,
	output wire [NPHYS*32-1:0] s_data,
	output wire [NPHYS-1:0] s_lanes,

	/* Forwarding buses (to atg_su_opd) */
	output wire fwd_ex4_valid,
	output wire [WARP_W-1:0] fwd_ex4_warp,
	output wire [GRP_W-1:0] fwd_ex4_grp,
	output wire [6:0] fwd_ex4_rd,
	output wire [NPHYS*32-1:0] fwd_ex4_data,
	output wire [NPHYS-1:0] fwd_ex4_lanes,

	output wire fwd_ex5_valid,
	output wire [WARP_W-1:0] fwd_ex5_warp,
	output wire [GRP_W-1:0] fwd_ex5_grp,
	output wire [6:0] fwd_ex5_rd,
	output wire [NPHYS*32-1:0] fwd_ex5_data,
	output wire [NPHYS-1:0] fwd_ex5_lanes
);
`include "atg_su_uop.vh"
	localparam DW = NPHYS * 32;

	/* Instruction fields */
	wire [3:0] unit = x_uop[ATG_UOP_UNIT +: 4];
	wire [4:0] op = x_uop[ATG_UOP_OP +: 5];
	wire immb = x_uop[ATG_UOP_OP + ATG_ALU_IMMB];
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	wire mine = x_valid && unit == ATG_UNIT_ALU && x_uop[ATG_UOP_WRD];

	function [31:0] rev;
		input [31:0] w;
		integer b;
		begin
			for (b = 0; b < 32; b = b + 1)
				rev[b] = w[31 - b];
		end
	endfunction

	/*
	 * Stage 1 (EX1): Latch inputs, compute basic bitwise logic, prepare addsub and shift
	 */
	reg s1_valid;
	reg [WARP_W-1:0] s1_warp;
	reg [GRP_W-1:0]  s1_grp;
	reg [6:0]        s1_rd;
	reg [NPHYS-1:0]  s1_mask;
	reg [4:0]        s1_op;

	reg [DW-1:0] s1_la, s1_lb;
	reg [DW-1:0] s1_and, s1_or, s1_xor, s1_andn, s1_orn, s1_xnor, s1_sel, s1_movi;
	reg [DW-1:0] s1_sv;
	reg [NPHYS-1:0] s1_sra;
	reg [NPHYS*5-1:0] s1_amt;
	reg s1_sub;

	integer i1;
	always @(posedge clk) begin
		if (!rst_n) begin
			s1_valid <= 1'b0;
			s1_warp  <= {WARP_W{1'b0}};
			s1_grp   <= {GRP_W{1'b0}};
			s1_rd    <= 7'd0;
			s1_mask  <= {NPHYS{1'b0}};
			s1_op    <= 5'd0;
			s1_la    <= {DW{1'b0}};
			s1_lb    <= {DW{1'b0}};
			s1_and   <= {DW{1'b0}};
			s1_or    <= {DW{1'b0}};
			s1_xor   <= {DW{1'b0}};
			s1_andn  <= {DW{1'b0}};
			s1_orn   <= {DW{1'b0}};
			s1_xnor  <= {DW{1'b0}};
			s1_sel   <= {DW{1'b0}};
			s1_movi  <= {DW{1'b0}};
			s1_sv    <= {DW{1'b0}};
			s1_sra   <= {NPHYS{1'b0}};
			s1_amt   <= {(NPHYS*5){1'b0}};
			s1_sub   <= 1'b0;
		end else if (en) begin
			s1_valid <= mine;
			s1_warp  <= x_warp;
			s1_grp   <= x_grp;
			s1_rd    <= x_uop[ATG_UOP_RD +: 7];
			s1_mask  <= x_mask[NPHYS-1:0];
			s1_op    <= op;
			s1_sub   <= (op != ATG_ALU_ADD);
			for (i1 = 0; i1 < NPHYS; i1 = i1 + 1) begin
				s1_la[i1*32 +: 32]   <= x_a[i1*32 +: 32];
				s1_lb[i1*32 +: 32]   <= immb ? imm : x_b[i1*32 +: 32];
				s1_and[i1*32 +: 32]  <= x_a[i1*32 +: 32] & (immb ? imm : x_b[i1*32 +: 32]);
				s1_or[i1*32 +: 32]   <= x_a[i1*32 +: 32] | (immb ? imm : x_b[i1*32 +: 32]);
				s1_xor[i1*32 +: 32]  <= x_a[i1*32 +: 32] ^ (immb ? imm : x_b[i1*32 +: 32]);
				s1_andn[i1*32 +: 32] <= x_a[i1*32 +: 32] & ~(immb ? imm : x_b[i1*32 +: 32]);
				s1_orn[i1*32 +: 32]  <= x_a[i1*32 +: 32] | ~(immb ? imm : x_b[i1*32 +: 32]);
				s1_xnor[i1*32 +: 32] <= ~(x_a[i1*32 +: 32] ^ (immb ? imm : x_b[i1*32 +: 32]));
				s1_sel[i1*32 +: 32]  <= (x_a[i1*32 +: 32] & (immb ? imm : x_b[i1*32 +: 32])) |
				                        (~x_a[i1*32 +: 32] & x_c[i1*32 +: 32]);
				s1_movi[i1*32 +: 32] <= imm;
				s1_sv[i1*32 +: 32]   <= (op == ATG_ALU_SLL) ? rev(x_a[i1*32 +: 32]) : x_a[i1*32 +: 32];
				s1_sra[i1]           <= (op == ATG_ALU_SRA) && x_a[i1*32 + 31];
				s1_amt[i1*5 +: 5]    <= immb ? imm[4:0] : x_b[i1*32 +: 5];
			end
		end
	end

	/*
	 * Stage 2 (EX2): 33-bit addition / subtraction
	 */
	wire [NPHYS*33-1:0] s2_d_comb;
	wire [NPHYS-1:0] s2_co_unused;

	genvar l2;
	generate
	for (l2 = 0; l2 < NPHYS; l2 = l2 + 1) begin : g_ex2_addsub
		am_addsub #(.W(33)) u_d (
			.a({1'b0, s1_la[l2*32 +: 32]}),
			.b({1'b0, s1_lb[l2*32 +: 32]}),
			.sub(s1_sub),
			.s(s2_d_comb[l2*33 +: 33]),
			.co(s2_co_unused[l2])
		);
	end
	endgenerate

	reg s2_valid;
	reg [WARP_W-1:0] s2_warp;
	reg [GRP_W-1:0]  s2_grp;
	reg [6:0]        s2_rd;
	reg [NPHYS-1:0]  s2_mask;
	reg [4:0]        s2_op;

	reg [NPHYS*33-1:0] s2_d;
	reg [DW-1:0] s2_la, s2_lb;
	reg [DW-1:0] s2_and, s2_or, s2_xor, s2_andn, s2_orn, s2_xnor, s2_sel, s2_movi;
	reg [DW-1:0] s2_sv;
	reg [NPHYS-1:0] s2_sra;
	reg [NPHYS*5-1:0] s2_amt;

	always @(posedge clk) begin
		if (!rst_n) begin
			s2_valid <= 1'b0;
			s2_warp  <= {WARP_W{1'b0}};
			s2_grp   <= {GRP_W{1'b0}};
			s2_rd    <= 7'd0;
			s2_mask  <= {NPHYS{1'b0}};
			s2_op    <= 5'd0;
			s2_d     <= {(NPHYS*33){1'b0}};
			s2_la    <= {DW{1'b0}};
			s2_lb    <= {DW{1'b0}};
			s2_and   <= {DW{1'b0}};
			s2_or    <= {DW{1'b0}};
			s2_xor   <= {DW{1'b0}};
			s2_andn  <= {DW{1'b0}};
			s2_orn   <= {DW{1'b0}};
			s2_xnor  <= {DW{1'b0}};
			s2_sel   <= {DW{1'b0}};
			s2_movi  <= {DW{1'b0}};
			s2_sv    <= {DW{1'b0}};
			s2_sra   <= {NPHYS{1'b0}};
			s2_amt   <= {(NPHYS*5){1'b0}};
		end else if (en) begin
			s2_valid <= s1_valid;
			s2_warp  <= s1_warp;
			s2_grp   <= s1_grp;
			s2_rd    <= s1_rd;
			s2_mask  <= s1_mask;
			s2_op    <= s1_op;
			s2_d     <= s2_d_comb;
			s2_la    <= s1_la;
			s2_lb    <= s1_lb;
			s2_and   <= s1_and;
			s2_or    <= s1_or;
			s2_xor   <= s1_xor;
			s2_andn  <= s1_andn;
			s2_orn   <= s1_orn;
			s2_xnor  <= s1_xnor;
			s2_sel   <= s1_sel;
			s2_movi  <= s1_movi;
			s2_sv    <= s1_sv;
			s2_sra   <= s1_sra;
			s2_amt   <= s1_amt;
		end
	end

	/*
	 * Stage 3 (EX3): 33-bit barrel shifter & comparison
	 */
	wire [NPHYS*33-1:0] s3_sh_comb;

	genvar l3;
	generate
	for (l3 = 0; l3 < NPHYS; l3 = l3 + 1) begin : g_ex3_shift
		am_shift #(.W(33), .SW(5)) u_sh (
			.a({s2_sra[l3], s2_sv[l3*32 +: 32]}),
			.amt(s2_amt[l3*5 +: 5]),
			.left(1'b0),
			.arith(1'b1),
			.y(s3_sh_comb[l3*33 +: 33])
		);
	end
	endgenerate

	reg s3_valid;
	reg [WARP_W-1:0] s3_warp;
	reg [GRP_W-1:0]  s3_grp;
	reg [6:0]        s3_rd;
	reg [NPHYS-1:0]  s3_mask;
	reg [4:0]        s3_op;

	reg [DW-1:0] s3_sh;
	reg [DW-1:0] s3_d;
	reg [DW-1:0] s3_la, s3_lb;
	reg [NPHYS-1:0] s3_slt, s3_ltu;
	reg [DW-1:0] s3_and, s3_or, s3_xor, s3_andn, s3_orn, s3_xnor, s3_sel, s3_movi;

	integer i3;
	always @(posedge clk) begin
		if (!rst_n) begin
			s3_valid <= 1'b0;
			s3_warp  <= {WARP_W{1'b0}};
			s3_grp   <= {GRP_W{1'b0}};
			s3_rd    <= 7'd0;
			s3_mask  <= {NPHYS{1'b0}};
			s3_op    <= 5'd0;
			s3_sh    <= {DW{1'b0}};
			s3_d     <= {DW{1'b0}};
			s3_la    <= {DW{1'b0}};
			s3_lb    <= {DW{1'b0}};
			s3_slt   <= {NPHYS{1'b0}};
			s3_ltu   <= {NPHYS{1'b0}};
			s3_and   <= {DW{1'b0}};
			s3_or    <= {DW{1'b0}};
			s3_xor   <= {DW{1'b0}};
			s3_andn  <= {DW{1'b0}};
			s3_orn   <= {DW{1'b0}};
			s3_xnor  <= {DW{1'b0}};
			s3_sel   <= {DW{1'b0}};
			s3_movi  <= {DW{1'b0}};
		end else if (en) begin
			s3_valid <= s2_valid;
			s3_warp  <= s2_warp;
			s3_grp   <= s2_grp;
			s3_rd    <= s2_rd;
			s3_mask  <= s2_mask;
			s3_op    <= s2_op;
			s3_la    <= s2_la;
			s3_lb    <= s2_lb;
			s3_and   <= s2_and;
			s3_or    <= s2_or;
			s3_xor   <= s2_xor;
			s3_andn  <= s2_andn;
			s3_orn   <= s2_orn;
			s3_xnor  <= s2_xnor;
			s3_sel   <= s2_sel;
			s3_movi  <= s2_movi;
			for (i3 = 0; i3 < NPHYS; i3 = i3 + 1) begin
				s3_sh[i3*32 +: 32] <= s3_sh_comb[i3*33 +: 32];
				s3_d[i3*32 +: 32]  <= s2_d[i3*33 +: 32];
				s3_slt[i3] <= (s2_la[i3*32 + 31] != s2_lb[i3*32 + 31]) ?
					s2_la[i3*32 + 31] : s2_d[i3*33 + 31];
				s3_ltu[i3] <= s2_d[i3*33 + 32];
			end
		end
	end

	/*
	 * Stage 4 (EX4): Operation result multiplexer
	 */
	reg [DW-1:0] s4_res_comb;
	integer i4;
	always @(*) begin
		s4_res_comb = {DW{1'b0}};
		for (i4 = 0; i4 < NPHYS; i4 = i4 + 1) begin
			case (s3_op)
			ATG_ALU_ADD:  s4_res_comb[i4*32 +: 32] = s3_d[i4*32 +: 32];
			ATG_ALU_SUB:  s4_res_comb[i4*32 +: 32] = s3_d[i4*32 +: 32];
			ATG_ALU_SLL:  s4_res_comb[i4*32 +: 32] = rev(s3_sh[i4*32 +: 32]);
			ATG_ALU_SLT:  s4_res_comb[i4*32 +: 32] = s3_slt[i4] ? 32'hFFFFFFFF : 32'd0;
			ATG_ALU_SLTU: s4_res_comb[i4*32 +: 32] = s3_ltu[i4] ? 32'hFFFFFFFF : 32'd0;
			ATG_ALU_XOR:  s4_res_comb[i4*32 +: 32] = s3_xor[i4*32 +: 32];
			ATG_ALU_SRL:  s4_res_comb[i4*32 +: 32] = s3_sh[i4*32 +: 32];
			ATG_ALU_SRA:  s4_res_comb[i4*32 +: 32] = s3_sh[i4*32 +: 32];
			ATG_ALU_OR:   s4_res_comb[i4*32 +: 32] = s3_or[i4*32 +: 32];
			ATG_ALU_AND:  s4_res_comb[i4*32 +: 32] = s3_and[i4*32 +: 32];
			ATG_ALU_MIN:  s4_res_comb[i4*32 +: 32] = s3_slt[i4] ? s3_la[i4*32 +: 32] : s3_lb[i4*32 +: 32];
			ATG_ALU_MAX:  s4_res_comb[i4*32 +: 32] = s3_slt[i4] ? s3_lb[i4*32 +: 32] : s3_la[i4*32 +: 32];
			ATG_ALU_MINU: s4_res_comb[i4*32 +: 32] = s3_ltu[i4] ? s3_la[i4*32 +: 32] : s3_lb[i4*32 +: 32];
			ATG_ALU_MAXU: s4_res_comb[i4*32 +: 32] = s3_ltu[i4] ? s3_lb[i4*32 +: 32] : s3_la[i4*32 +: 32];
			ATG_ALU_ANDN: s4_res_comb[i4*32 +: 32] = s3_andn[i4*32 +: 32];
			ATG_ALU_ORN:  s4_res_comb[i4*32 +: 32] = s3_orn[i4*32 +: 32];
			ATG_ALU_XNOR: s4_res_comb[i4*32 +: 32] = s3_xnor[i4*32 +: 32];
			ATG_ALU_SEL:  s4_res_comb[i4*32 +: 32] = s3_sel[i4*32 +: 32];
			ATG_ALU_MOVI: s4_res_comb[i4*32 +: 32] = s3_movi[i4*32 +: 32];
			default:      s4_res_comb[i4*32 +: 32] = 32'd0;
			endcase
		end
	end

	reg s4_valid;
	reg [WARP_W-1:0] s4_warp;
	reg [GRP_W-1:0]  s4_grp;
	reg [6:0]        s4_rd;
	reg [NPHYS-1:0]  s4_mask;
	reg [DW-1:0]     s4_data;

	always @(posedge clk) begin
		if (!rst_n) begin
			s4_valid <= 1'b0;
			s4_warp  <= {WARP_W{1'b0}};
			s4_grp   <= {GRP_W{1'b0}};
			s4_rd    <= 7'd0;
			s4_mask  <= {NPHYS{1'b0}};
			s4_data  <= {DW{1'b0}};
		end else if (en) begin
			s4_valid <= s3_valid;
			s4_warp  <= s3_warp;
			s4_grp   <= s3_grp;
			s4_rd    <= s3_rd;
			s4_mask  <= s3_mask;
			s4_data  <= s4_res_comb;
		end
	end

	/*
	 * Stage 5 (EX5): Writeback prep and pipeline alignment
	 */
	reg s5_valid;
	reg [WARP_W-1:0] s5_warp;
	reg [GRP_W-1:0]  s5_grp;
	reg [6:0]        s5_rd;
	reg [NPHYS-1:0]  s5_mask;
	reg [DW-1:0]     s5_data;

	always @(posedge clk) begin
		if (!rst_n) begin
			s5_valid <= 1'b0;
			s5_warp  <= {WARP_W{1'b0}};
			s5_grp   <= {GRP_W{1'b0}};
			s5_rd    <= 7'd0;
			s5_mask  <= {NPHYS{1'b0}};
			s5_data  <= {DW{1'b0}};
		end else if (en) begin
			s5_valid <= s4_valid;
			s5_warp  <= s4_warp;
			s5_grp   <= s4_grp;
			s5_rd    <= s4_rd;
			s5_mask  <= s4_mask;
			s5_data  <= s4_data;
		end
	end

	/*
	 * Stage 6 (WB): Registered drive to s_* exactly SHORT_LAT (6) cycles after x_valid
	 */
	reg s6_valid;
	reg [WARP_W-1:0] s6_warp;
	reg [GRP_W-1:0]  s6_grp;
	reg [6:0]        s6_rd;
	reg [NPHYS-1:0]  s6_lanes;
	reg [DW-1:0]     s6_data;

	always @(posedge clk) begin
		if (!rst_n) begin
			s6_valid <= 1'b0;
			s6_warp  <= {WARP_W{1'b0}};
			s6_grp   <= {GRP_W{1'b0}};
			s6_rd    <= 7'd0;
			s6_lanes <= {NPHYS{1'b0}};
			s6_data  <= {DW{1'b0}};
		end else if (en) begin
			s6_valid <= s5_valid;
			s6_warp  <= s5_warp;
			s6_grp   <= s5_grp;
			s6_rd    <= s5_rd;
			s6_lanes <= s5_mask;
			s6_data  <= s5_data;
		end
	end

	assign s_valid = s6_valid;
	assign s_warp  = s6_warp;
	assign s_grp   = s6_grp;
	assign s_rd    = s6_rd;
	assign s_lanes = s6_lanes;
	assign s_data  = s6_data;
	assign x_ready = 1'b1;

	assign fwd_ex4_valid = s4_valid;
	assign fwd_ex4_warp  = s4_warp;
	assign fwd_ex4_grp   = s4_grp;
	assign fwd_ex4_rd    = s4_rd;
	assign fwd_ex4_data  = s4_data;
	assign fwd_ex4_lanes = s4_mask;

	assign fwd_ex5_valid = s5_valid;
	assign fwd_ex5_warp  = s5_warp;
	assign fwd_ex5_grp   = s5_grp;
	assign fwd_ex5_rd    = s5_rd;
	assign fwd_ex5_data  = s5_data;
	assign fwd_ex5_lanes = s5_mask;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		s3_sh_comb[32], s2_co_unused, (NWARPS != 0)};
endmodule

`default_nettype wire
