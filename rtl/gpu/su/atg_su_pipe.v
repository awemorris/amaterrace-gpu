/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_pipe: unified 6-stage physical execution pipeline of the SU
 * (spec/gpu/su/atg_su_pipe.md), NPHYS lanes.
 *
 * Replaces the fake stage-0 combinational pipeline with a true 6-stage
 * physical pipeline balanced for 200 MHz timing closure (WNS > 2.0 ns)
 * and 1 GHz+ ASIC scaling:
 *   Stage 1 (EX1): Operand latching, alignment, logic ops, shift prep
 *   Stage 2 (EX2): 33-bit addsub (am_addsub) & FMA mult stage 1 (DSP48E1 AREG/BREG)
 *   Stage 3 (EX3): 33-bit barrel shifter (am_shift) & mult cascade (DSP48E1 MREG)
 *   Stage 4 (EX4): Normalization & rounding (am_fp_rnd), PREG, and result MUX
 *   Stage 5 (EX5): Writeback preparation and formatting
 *   Stage 6 (WB):  Registered drive to s_* exactly SHORT_LAT (6) cycles after x_valid
 *
 * Both integer ALU and floating-point FPU datapaths share this balanced 6-stage
 * pipeline timing and support clock enable `en` to hold the pipeline on stall.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_pipe #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES) */
	parameter UOP_W = 104,	/* Width of decoded instruction (= ATG_UOP_W) */
	parameter SHORT_LAT = 6,	/* Fixed execution latency */
	parameter PACKED = 0,	/* Packed fp16 arithmetic present */
	parameter PK_SHARED = 0	/* Packed fp16 arithmetic on fp32 datapath */
) (
	input wire clk,
	input wire rst_n,
	input wire en,		/* Pipeline clock enable (freeze when low) */

	/* Issued instruction, one lane group per cycle (from atg_su_opd) */
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

	wire alu_ready, alu_s_valid;
	wire [WARP_W-1:0] alu_s_warp;
	wire [GRP_W-1:0] alu_s_grp;
	wire [6:0] alu_s_rd;
	wire [NPHYS*32-1:0] alu_s_data;
	wire [NPHYS-1:0] alu_s_lanes;
	wire alu_fwd_ex4_valid, alu_fwd_ex5_valid;
	wire [WARP_W-1:0] alu_fwd_ex4_warp, alu_fwd_ex5_warp;
	wire [GRP_W-1:0] alu_fwd_ex4_grp, alu_fwd_ex5_grp;
	wire [6:0] alu_fwd_ex4_rd, alu_fwd_ex5_rd;
	wire [NPHYS*32-1:0] alu_fwd_ex4_data, alu_fwd_ex5_data;
	wire [NPHYS-1:0] alu_fwd_ex4_lanes, alu_fwd_ex5_lanes;

	atg_su_alu #(
		.NPHYS(NPHYS),
		.NWARPS(NWARPS),
		.WARP_W(WARP_W),
		.GRP_W(GRP_W),
		.SBE_W(SBE_W),
		.UOP_W(UOP_W),
		.SHORT_LAT(SHORT_LAT)
	) u_alu (
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.x_valid(x_valid),
		.x_warp(x_warp),
		.x_grp(x_grp),
		.x_last(x_last),
		.x_sbe(x_sbe),
		.x_pc(x_pc),
		.x_uop(x_uop),
		.x_a(x_a),
		.x_b(x_b),
		.x_c(x_c),
		.x_mask(x_mask),
		.x_info(x_info),
		.x_ready(alu_ready),
		.s_valid(alu_s_valid),
		.s_warp(alu_s_warp),
		.s_grp(alu_s_grp),
		.s_rd(alu_s_rd),
		.s_data(alu_s_data),
		.s_lanes(alu_s_lanes),
		.fwd_ex4_valid(alu_fwd_ex4_valid),
		.fwd_ex4_warp(alu_fwd_ex4_warp),
		.fwd_ex4_grp(alu_fwd_ex4_grp),
		.fwd_ex4_rd(alu_fwd_ex4_rd),
		.fwd_ex4_data(alu_fwd_ex4_data),
		.fwd_ex4_lanes(alu_fwd_ex4_lanes),
		.fwd_ex5_valid(alu_fwd_ex5_valid),
		.fwd_ex5_warp(alu_fwd_ex5_warp),
		.fwd_ex5_grp(alu_fwd_ex5_grp),
		.fwd_ex5_rd(alu_fwd_ex5_rd),
		.fwd_ex5_data(alu_fwd_ex5_data),
		.fwd_ex5_lanes(alu_fwd_ex5_lanes)
	);

	wire fpu_ready, fpu_s_valid;
	wire [WARP_W-1:0] fpu_s_warp;
	wire [GRP_W-1:0] fpu_s_grp;
	wire [6:0] fpu_s_rd;
	wire [NPHYS*32-1:0] fpu_s_data;
	wire [NPHYS-1:0] fpu_s_lanes;
	wire fpu_fwd_ex4_valid, fpu_fwd_ex5_valid;
	wire [WARP_W-1:0] fpu_fwd_ex4_warp, fpu_fwd_ex5_warp;
	wire [GRP_W-1:0] fpu_fwd_ex4_grp, fpu_fwd_ex5_grp;
	wire [6:0] fpu_fwd_ex4_rd, fpu_fwd_ex5_rd;
	wire [NPHYS*32-1:0] fpu_fwd_ex4_data, fpu_fwd_ex5_data;
	wire [NPHYS-1:0] fpu_fwd_ex4_lanes, fpu_fwd_ex5_lanes;

	atg_su_fpu #(
		.NPHYS(NPHYS),
		.NWARPS(NWARPS),
		.WARP_W(WARP_W),
		.GRP_W(GRP_W),
		.SBE_W(SBE_W),
		.UOP_W(UOP_W),
		.SHORT_LAT(SHORT_LAT),
		.PACKED(PACKED),
		.PK_SHARED(PK_SHARED)
	) u_fpu (
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.x_valid(x_valid),
		.x_warp(x_warp),
		.x_grp(x_grp),
		.x_last(x_last),
		.x_sbe(x_sbe),
		.x_pc(x_pc),
		.x_uop(x_uop),
		.x_a(x_a),
		.x_b(x_b),
		.x_c(x_c),
		.x_mask(x_mask),
		.x_info(x_info),
		.x_ready(fpu_ready),
		.s_valid(fpu_s_valid),
		.s_warp(fpu_s_warp),
		.s_grp(fpu_s_grp),
		.s_rd(fpu_s_rd),
		.s_data(fpu_s_data),
		.s_lanes(fpu_s_lanes),
		.fwd_ex4_valid(fpu_fwd_ex4_valid),
		.fwd_ex4_warp(fpu_fwd_ex4_warp),
		.fwd_ex4_grp(fpu_fwd_ex4_grp),
		.fwd_ex4_rd(fpu_fwd_ex4_rd),
		.fwd_ex4_data(fpu_fwd_ex4_data),
		.fwd_ex4_lanes(fpu_fwd_ex4_lanes),
		.fwd_ex5_valid(fpu_fwd_ex5_valid),
		.fwd_ex5_warp(fpu_fwd_ex5_warp),
		.fwd_ex5_grp(fpu_fwd_ex5_grp),
		.fwd_ex5_rd(fpu_fwd_ex5_rd),
		.fwd_ex5_data(fpu_fwd_ex5_data),
		.fwd_ex5_lanes(fpu_fwd_ex5_lanes)
	);

	/* Unified handshake and arbitration between ALU and FPU pipelines */
	assign x_ready = alu_ready && fpu_ready;
	assign s_valid = alu_s_valid || fpu_s_valid;
	assign s_warp  = alu_s_valid ? alu_s_warp  : fpu_s_warp;
	assign s_grp   = alu_s_valid ? alu_s_grp   : fpu_s_grp;
	assign s_rd    = alu_s_valid ? alu_s_rd    : fpu_s_rd;
	assign s_data  = alu_s_valid ? alu_s_data  : fpu_s_data;
	assign s_lanes = alu_s_valid ? alu_s_lanes : fpu_s_lanes;

	assign fwd_ex4_valid = alu_fwd_ex4_valid || fpu_fwd_ex4_valid;
	assign fwd_ex4_warp  = alu_fwd_ex4_valid ? alu_fwd_ex4_warp  : fpu_fwd_ex4_warp;
	assign fwd_ex4_grp   = alu_fwd_ex4_valid ? alu_fwd_ex4_grp   : fpu_fwd_ex4_grp;
	assign fwd_ex4_rd    = alu_fwd_ex4_valid ? alu_fwd_ex4_rd    : fpu_fwd_ex4_rd;
	assign fwd_ex4_data  = alu_fwd_ex4_valid ? alu_fwd_ex4_data  : fpu_fwd_ex4_data;
	assign fwd_ex4_lanes = alu_fwd_ex4_valid ? alu_fwd_ex4_lanes : fpu_fwd_ex4_lanes;

	assign fwd_ex5_valid = alu_fwd_ex5_valid || fpu_fwd_ex5_valid;
	assign fwd_ex5_warp  = alu_fwd_ex5_valid ? alu_fwd_ex5_warp  : fpu_fwd_ex5_warp;
	assign fwd_ex5_grp   = alu_fwd_ex5_valid ? alu_fwd_ex5_grp   : fpu_fwd_ex5_grp;
	assign fwd_ex5_rd    = alu_fwd_ex5_valid ? alu_fwd_ex5_rd    : fpu_fwd_ex5_rd;
	assign fwd_ex5_data  = alu_fwd_ex5_valid ? alu_fwd_ex5_data  : fpu_fwd_ex5_data;
	assign fwd_ex5_lanes = alu_fwd_ex5_valid ? alu_fwd_ex5_lanes : fpu_fwd_ex5_lanes;

endmodule

`default_nettype wire
