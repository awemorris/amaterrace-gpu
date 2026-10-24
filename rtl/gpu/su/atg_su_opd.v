/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_opd: operand collection.  Takes an issued instruction from
 * atg_su_sb and sends its 32/NPHYS lane groups on the execution bus x_*,
 * one per cycle while the uop's unit is ready.
 *
 * Two stages per group: A addresses the RF (and the constant bank, rq),
 * B selects each operand (GPR 0-62, rq 63, c0-c31 64-95, the specials
 * 96-127 of design §3.2), applies the n/a modifiers for the float units
 * (FPU, XU, PK; PK on both halves) and drives x_*.  i_valid -> first
 * x_valid is 2 cycles; i_ready while stage A is free or ends this cycle.
 * unit_ready 0 holds x_* (the RF output holds while r_en is 0).  The masks
 * come from q_exec/q_killed/q_info of the warp in stage B.  lidx is lidn
 * and lidy/lidz/prim are 0 in v0 (q_info carries no WG_SIZE; 1-D groups).
 * A uop that reads a pair and rs3 (a texture .c form: rs1, rs1+1, rs2 and
 * Dref = rs3) needs four operands: each of its groups goes out twice, the
 * second pass with rs3 as operand 1 (x_a) and TEX op bit 7 set on x_uop;
 * x_last is on the second pass of the last group.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_opd #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 104	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_sb */
	input wire i_valid,
	output wire i_ready,
	input wire [WARP_W-1:0] i_warp,
	input wire [15:0] i_pc,
	input wire [UOP_W-1:0] i_uop,
	input wire [SBE_W:0] i_sbe,
	/* Register file (atg_su_rf read port) */
	output wire r_en,
	output wire [WARP_W-1:0] r_warp,
	output wire [GRP_W-1:0] r_grp,
	output wire [17:0] r_regs,
	input wire [3*NPHYS*32-1:0] r_data,
	/* Constant bank (atg_su_cbank) */
	output wire cr_en,
	output wire [14:0] cr_idx,
	input wire [95:0] cr_data,
	/* Warp state */
	output wire [WARP_W-1:0] q_warp,
	input wire [159:0] q_info,
	input wire [31:0] q_exec,
	input wire [31:0] q_killed,
	/* rq (atg_su_rq) */
	output wire rq_pop,
	input wire [NPHYS*32-1:0] rq_data,
	/* Execution bus (to every unit) */
	output wire x_valid,
	output wire [WARP_W-1:0] x_warp,
	output wire [GRP_W-1:0] x_grp,
	output wire x_last,
	output wire [SBE_W:0] x_sbe,
	output wire [15:0] x_pc,
	output wire [UOP_W-1:0] x_uop,
	output wire [NPHYS*32-1:0] x_a,
	output wire [NPHYS*32-1:0] x_b,
	output wire [NPHYS*32-1:0] x_c,
	output wire [2*NPHYS-1:0] x_mask,
	output wire [31:0] x_info,
	input wire [15:0] unit_ready
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;

	/* Stage A: the instruction whose next group addresses the RF. */
	reg a_act;
	reg [WARP_W-1:0] a_warp;
	reg [15:0] a_pc;
	reg [UOP_W-1:0] a_uop;
	reg [SBE_W:0] a_sbe;
	reg [GRP_W-1:0] a_grp;
	reg a_pass;	/* the second operand pass of a four-operand uop */
	/* Stage B: the group on x_*. */
	reg b_valid, b_last;
	reg [WARP_W-1:0] b_warp;
	reg [15:0] b_pc;
	reg [UOP_W-1:0] b_uop;
	reg [SBE_W:0] b_sbe;
	reg [GRP_W-1:0] b_grp;
	reg b_pass;

	wire [3:0] b_unit = b_uop[ATG_UOP_UNIT +: 4];
	wire b_adv = !b_valid || unit_ready[b_unit];
	wire a_adv = a_act && b_adv;
	wire a_wide = a_uop[ATG_UOP_PAIR] && a_uop[ATG_UOP_USE3];
	wire a_last = {{(32-GRP_W){1'b0}}, a_grp} == G - 1 && (!a_wide || a_pass);
	assign i_ready = !a_act || (a_adv && a_last);
	wire take = i_valid && i_ready;

	/* Operand numbers; operand 3 is rs1+1 for the PAIR instructions;
	 * operand 1 is rs3 on a second pass. */
	wire [6:0] a_r1 = a_uop[ATG_UOP_RS1 +: 7];
	wire [6:0] a_n1 = a_pass ? a_uop[ATG_UOP_RS3 +: 7] : a_r1;
	wire [6:0] a_n2 = a_uop[ATG_UOP_RS2 +: 7];
	wire [6:0] a_n3 = a_uop[ATG_UOP_PAIR] ? a_r1 + 7'd1 : a_uop[ATG_UOP_RS3 +: 7];
	assign r_en = a_adv;
	assign r_warp = a_warp;
	assign r_grp = a_grp;
	assign r_regs = {a_n3[5:0], a_n2[5:0], a_n1[5:0]};
	assign cr_en = a_adv;
	assign cr_idx = {a_n3[4:0], a_n2[4:0], a_n1[4:0]};
	assign rq_pop = a_adv && a_uop[ATG_UOP_RQS] && !a_pass;

	always @(posedge clk) begin
		if (!rst_n) begin
			a_act <= 1'b0;
			b_valid <= 1'b0;
			a_warp <= {WARP_W{1'b0}};
			a_pc <= 16'd0;
			a_uop <= {UOP_W{1'b0}};
			a_sbe <= {(SBE_W+1){1'b0}};
			a_grp <= {GRP_W{1'b0}};
			a_pass <= 1'b0;
			b_pass <= 1'b0;
			b_last <= 1'b0;
			b_warp <= {WARP_W{1'b0}};
			b_pc <= 16'd0;
			b_uop <= {UOP_W{1'b0}};
			b_sbe <= {(SBE_W+1){1'b0}};
			b_grp <= {GRP_W{1'b0}};
		end else begin
			if (b_adv) begin
				b_valid <= a_act;
				if (a_act) begin
					b_warp <= a_warp;
					b_pc <= a_pc;
					b_uop <= a_uop;
					b_sbe <= a_sbe;
					b_grp <= a_grp;
					b_pass <= a_pass;
					b_last <= a_last;
				end
			end
			if (take) begin
				a_act <= 1'b1;
				a_warp <= i_warp;
				a_pc <= i_pc;
				a_uop <= i_uop;
				a_sbe <= i_sbe;
				a_grp <= {GRP_W{1'b0}};
				a_pass <= 1'b0;
			end else if (a_adv) begin
				if (a_wide && !a_pass) begin
					a_pass <= 1'b1;
				end else begin
					a_pass <= 1'b0;
					if (a_last)
						a_act <= 1'b0;
					else
						a_grp <= a_grp + 1'b1;
				end
			end
		end
	end

	/* Stage B: operand selection. */
	wire [6:0] b_r1 = b_uop[ATG_UOP_RS1 +: 7];
	wire [6:0] b_n1 = b_pass ? b_uop[ATG_UOP_RS3 +: 7] : b_r1;
	wire [6:0] b_n2 = b_uop[ATG_UOP_RS2 +: 7];
	wire [6:0] b_n3 = b_uop[ATG_UOP_PAIR] ? b_r1 + 7'd1 : b_uop[ATG_UOP_RS3 +: 7];
	wire [6:0] mods = b_uop[ATG_UOP_MOD +: 7];
	wire fp_unit = b_unit == ATG_UNIT_FPU || b_unit == ATG_UNIT_XU;
	wire pk_unit = b_unit == ATG_UNIT_PK;
	wire [31:0] grp_base = {{(32-GRP_W){1'b0}}, b_grp} * NPHYS;
	wire [31:0] exec_g = q_exec >> grp_base;
	wire [31:0] kill_g = q_killed >> grp_base;
	wire [31:0] cov_g = q_info[ATG_WI_MASK +: 32] >> grp_base;
	assign q_warp = b_warp;

	/* The value of operand n, split in two: the part that is the same in every
	 * lane (constants, warp and workgroup values, the constant word), made once
	 * per operand, and the lane's own part (its GPR, the rq word, its lane
	 * number, its killed bit), chosen per lane.  Everything they read is an
	 * argument (so that always @(*) sees it). */
	function [31:0] opc;
		input [6:0] n;
		input [31:0] cw;
		input [WARP_W-1:0] wn;
		input [159:0] qi;
		input [31:0] qe;
		begin
			if (n < 7'd96)
				opc = cw;
			else begin
				case (n)
				7'd96: opc = 32'd0;
				7'd97: opc = 32'h3F800000;
				7'd98: opc = 32'd1;
				7'd99: opc = 32'h3F000000;
				7'd100: opc = 32'h40000000;
				7'd101: opc = 32'hBF800000;
				7'd103: opc = {{(32-WARP_W){1'b0}}, wn};
				7'd104: opc = qe;
				7'd106: opc = {16'd0, qi[ATG_WI_WGX +: 16]};
				7'd107: opc = {16'd0, qi[ATG_WI_WGX + 16 +: 16]};
				7'd108: opc = {16'd0, qi[ATG_WI_WGX + 32 +: 16]};
				7'd109, 7'd112: opc = {24'd0, qi[ATG_WI_LID +: 8]};
				7'd114: opc = {32{qi[ATG_WI_FRONT]}};
				7'd115: opc = {16'd0, qi[ATG_WI_NWGX +: 16]};
				7'd116: opc = {16'd0, qi[ATG_WI_NWGX + 16 +: 16]};
				7'd117: opc = {16'd0, qi[ATG_WI_NWGX + 32 +: 16]};
				7'd118: opc = 32'h3C003C00;
				7'd119: opc = qi[ATG_WI_MASK +: 32];
				default: opc = 32'd0;
				endcase
			end
		end
	endfunction

	/* How the lane combines the common part: 0 = the common part, 1 = the GPR,
	 * 2 = rq, 3 = the lane number, 4 = the killed bit, 5 = common + lane
	 * (the local index). */
	function [2:0] opk;
		input [6:0] n;
		begin
			if (n < 7'd63)
				opk = 3'd1;
			else if (n == 7'd63)
				opk = 3'd2;
			else if (n == 7'd102)
				opk = 3'd3;
			else if (n == 7'd105)
				opk = 3'd4;
			else if (n == 7'd109 || n == 7'd112)
				opk = 3'd5;
			else
				opk = 3'd0;
		end
	endfunction

	function [31:0] opl;
		input [2:0] k;
		input [31:0] com, gpr, rq;
		input [4:0] lane;
		input kl;
		begin
			case (k)
			3'd1: opl = gpr;
			3'd2: opl = rq;
			3'd3: opl = {27'd0, lane};
			3'd4: opl = {32{kl}};
			3'd5: opl = com + {27'd0, lane};
			default: opl = com;
			endcase
		end
	endfunction

	/* The float modifiers: abs, then negate. */
	function [31:0] fmod;
		input [31:0] v;
		input ng, ab, fp, pk;
		reg [31:0] r;
		begin
			r = v;
			if (fp) begin
				if (ab)
					r[31] = 1'b0;
				if (ng)
					r[31] = !r[31];
			end else if (pk) begin
				if (ab) begin
					r[31] = 1'b0;
					r[15] = 1'b0;
				end
				if (ng) begin
					r[31] = !r[31];
					r[15] = !r[15];
				end
			end
			fmod = r;
		end
	endfunction

	reg [DW-1:0] va, vb, vc;
	reg [4:0] ln;
	integer l;

	/* The common part and the kind of each operand, once per instruction. */
	wire [31:0] com1 = opc(b_n1, cr_data[31:0], b_warp, q_info, q_exec);
	wire [31:0] com2 = opc(b_n2, cr_data[63:32], b_warp, q_info, q_exec);
	wire [31:0] com3 = opc(b_n3, cr_data[95:64], b_warp, q_info, q_exec);
	wire [2:0] k1 = opk(b_n1);
	wire [2:0] k2 = opk(b_n2);
	wire [2:0] k3 = opk(b_n3);

	always @(*) begin
		for (l = 0; l < NPHYS; l = l + 1) begin
			ln = grp_base[4:0] + l[4:0];
			va[l*32 +: 32] = fmod(opl(k1, com1, r_data[l*32 +: 32], rq_data[l*32 +: 32],
				ln, kill_g[l]), mods[0], mods[1], fp_unit, pk_unit);
			vb[l*32 +: 32] = fmod(opl(k2, com2, r_data[DW + l*32 +: 32], rq_data[l*32 +: 32],
				ln, kill_g[l]), mods[2], mods[3], fp_unit, pk_unit);
			vc[l*32 +: 32] = fmod(opl(k3, com3, r_data[2*DW + l*32 +: 32], rq_data[l*32 +: 32],
				ln, kill_g[l]), mods[4], mods[5], fp_unit, pk_unit);
		end
	end

	assign x_valid = b_valid;
	assign x_warp = b_warp;
	assign x_grp = b_grp;
	assign x_last = b_last;
	assign x_sbe = b_sbe;
	assign x_pc = b_pc;
	assign x_uop = b_uop | ({{(UOP_W-1){1'b0}}, b_pass} << (ATG_UOP_OP + ATG_TEX_PASS2));
	assign x_a = va;
	assign x_b = vb;
	assign x_c = vc;
	assign x_mask = {exec_g[NPHYS-1:0] & cov_g[NPHYS-1:0] & ~kill_g[NPHYS-1:0],
		exec_g[NPHYS-1:0]};
	assign x_info = {13'd0, q_info[ATG_WI_FRONT], q_info[ATG_WI_KIND +: 2],
		q_info[ATG_WI_SEQ +: 16]};

	wire unused_ok = &{1'b0, a_n1[6], a_n2[6], a_n3[6], mods[6], exec_g, kill_g, cov_g, grp_base, q_info};
endmodule

`default_nettype wire
