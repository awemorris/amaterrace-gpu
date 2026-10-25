/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_alu: The integer ALU of the SU, NPHYS lanes:
 * add/sub/logic/shifts, Boolean compares (all ones/0), Zbb
 * min/max/andn/orn/xnor, sel (bitwise), lui/movi; results on the short
 * pipeline.
 *
 * Takes every group of a uop whose unit is ALU (x_ready is always 1) and
 * presents its result on s_* exactly SHORT_LAT cycles after x_valid, in
 * order.  Operand b is the immediate when OP bit ATG_ALU_IMMB is set.
 * s_lanes = the EXEC lanes of the group; lanes outside are not written.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_alu #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter SHORT_LAT = 6	/* Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1) */
) (
	input wire clk,
	input wire rst_n,
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
	output wire [NPHYS-1:0] s_lanes
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	/* One pipeline entry: {valid, warp, grp, rd, lanes, data}. */
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_ALU && x_uop[ATG_UOP_WRD];
	wire [4:0] op = x_uop[ATG_UOP_OP +: 5];
	wire immb = x_uop[ATG_UOP_OP + ATG_ALU_IMMB];
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];

	/* The bits of x in reverse order. */
	function [31:0] rev;
		input [31:0] x;
		integer k;
		for (k = 0; k < 32; k = k + 1)
			rev[k] = x[31 - k];
	endfunction

	/* One lane, given d (a + b for add, else a - b, as 33 bits: bit 32
	 * is a < b unsigned; with equal signs bit 31 is a < b signed: sub, the
	 * compares, min and max) and sh (the shifts' one arithmetic right
	 * shift; sll shifts the reversed a), each of one shared module. */
	function [31:0] alu;
		input [4:0] o;
		input [31:0] a, b, c, i;
		input [32:0] d;
		input [31:0] sh;
		reg ltu, lts;
		begin
			ltu = d[32];
			lts = a[31] != b[31] ? a[31] : d[31];
			case (o)
			ATG_ALU_ADD: alu = d[31:0];
			ATG_ALU_SUB: alu = d[31:0];
			ATG_ALU_SLL: alu = rev(sh);
			ATG_ALU_SLT: alu = {32{lts}};
			ATG_ALU_SLTU: alu = {32{ltu}};
			ATG_ALU_XOR: alu = a ^ b;
			ATG_ALU_SRL, ATG_ALU_SRA: alu = sh;
			ATG_ALU_OR: alu = a | b;
			ATG_ALU_AND: alu = a & b;
			ATG_ALU_MIN: alu = lts ? a : b;
			ATG_ALU_MAX: alu = lts ? b : a;
			ATG_ALU_MINU: alu = ltu ? a : b;
			ATG_ALU_MAXU: alu = ltu ? b : a;
			ATG_ALU_ANDN: alu = a & ~b;
			ATG_ALU_ORN: alu = a | ~b;
			ATG_ALU_XNOR: alu = ~(a ^ b);
			ATG_ALU_SEL: alu = (a & b) | (~a & c);
			ATG_ALU_MOVI: alu = i;
			default: alu = 32'd0;
			endcase
		end
	endfunction

	wire [DW-1:0] y;
	genvar l;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
			wire [31:0] la = x_a[l*32 +: 32];
			wire [31:0] lb = immb ? imm : x_b[l*32 +: 32];
			wire [31:0] sv = op == ATG_ALU_SLL ? rev(la) : la;
			wire [32:0] d;
			wire [32:0] sh;
			wire d_co_unused;
			am_addsub #(.W(33)) u_d (.a({1'b0, la}), .b({1'b0, lb}), .sub(op != ATG_ALU_ADD), .s(d),
				.co(d_co_unused));
			am_shift #(.W(33), .SW(5)) u_sh (.a({op == ATG_ALU_SRA && la[31], sv}), .amt(lb[4:0]),
				.left(1'b0), .arith(1'b1), .y(sh));
			assign y[l*32 +: 32] = alu(op, la, lb, x_c[l*32 +: 32], imm, d, sh[31:0]);
			wire unused_l = &{1'b0, sh[32]};
		end
	endgenerate

	/* SHORT_LAT stages; stage 0 is registered from x_*. */
	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {mine, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], x_mask[NPHYS-1:0], y};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
		end
	end

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];
	assign x_ready = 1'b1;

	wire unused_ok = &{1'b0, x_last, x_sbe, x_pc, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		(NWARPS != 0)};
endmodule

`default_nettype wire
