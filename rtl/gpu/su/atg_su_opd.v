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
 * A uop that reads a pair and rs3 (a texture .c or .3 form: rs1, rs1+1, rs2
 * and rs3 = rs1+2, the .3 form with Dref also rs1+3) needs four or five
 * operands: each of its groups goes out twice, the second pass with rs3 as
 * operand 1 (x_a), rs3+1 as operand 3 (x_c) and TEX op bit 7 set on x_uop;
 * x_last is on the second pass of the last group.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_opd #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter WARP_BASE = 0,	/* The warp operand of slot 0: SU_INDEX x NWARPS, so warp numbers the GPU's resident warps */
	parameter REG_IO = 0	/* 1: RF has registered output q1_pipe/q2_pipe (2-cycle read latency) */
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
	/* Register file (atg_su_rf read port: dual read port) */
	output wire r_en,
	output wire [WARP_W-1:0] r_warp,
	output wire [GRP_W-1:0] r_grp,
	output wire [11:0] r_regs,
	input wire [2*NPHYS*32-1:0] r_data,
	/* Constant bank (atg_su_cbank) */
	output wire cr_en,
	output wire [14:0] cr_idx,
	input wire [95:0] cr_data,
	/* Warp state */
	output wire [WARP_W-1:0] a_q_warp,
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
	input wire [15:0] unit_ready,

	/* Forwarding buses (from ALU, FPU execution pipelines and WB) */
	input wire fwd_alu_ex3_valid,
	input wire [WARP_W-1:0] fwd_alu_ex3_warp,
	input wire [GRP_W-1:0] fwd_alu_ex3_grp,
	input wire [6:0] fwd_alu_ex3_rd,

	input wire fwd_alu_ex4_valid,
	input wire [WARP_W-1:0] fwd_alu_ex4_warp,
	input wire [GRP_W-1:0] fwd_alu_ex4_grp,
	input wire [6:0] fwd_alu_ex4_rd,
	input wire [NPHYS*32-1:0] fwd_alu_ex4_data,
	input wire [NPHYS-1:0] fwd_alu_ex4_lanes,

	input wire fwd_alu_ex5_valid,
	input wire [WARP_W-1:0] fwd_alu_ex5_warp,
	input wire [GRP_W-1:0] fwd_alu_ex5_grp,
	input wire [6:0] fwd_alu_ex5_rd,
	input wire [NPHYS*32-1:0] fwd_alu_ex5_data,
	input wire [NPHYS-1:0] fwd_alu_ex5_lanes,

	input wire fwd_fpu_ex4_valid,
	input wire [WARP_W-1:0] fwd_fpu_ex4_warp,
	input wire [GRP_W-1:0] fwd_fpu_ex4_grp,
	input wire [6:0] fwd_fpu_ex4_rd,
	input wire [NPHYS*32-1:0] fwd_fpu_ex4_data,
	input wire [NPHYS-1:0] fwd_fpu_ex4_lanes,

	input wire fwd_fpu_ex5_valid,
	input wire [WARP_W-1:0] fwd_fpu_ex5_warp,
	input wire [GRP_W-1:0] fwd_fpu_ex5_grp,
	input wire [6:0] fwd_fpu_ex5_rd,
	input wire [NPHYS*32-1:0] fwd_fpu_ex5_data,
	input wire [NPHYS-1:0] fwd_fpu_ex5_lanes,

	input wire fwd_wb_valid,
	input wire [WARP_W-1:0] fwd_wb_warp,
	input wire [GRP_W-1:0] fwd_wb_grp,
	input wire [6:0] fwd_wb_rd,
	input wire [NPHYS*32-1:0] fwd_wb_data,
	input wire [NPHYS-1:0] fwd_wb_lanes,
	output wire x_end_out
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam G = 32 / NPHYS;

	(* keep = "true" *) wire rst_p = !rst_n;

	/* Stage A: the instruction whose next group addresses the RF. */
	(* max_fanout = 12 *) reg a_act;
	(* max_fanout = 12 *) reg [WARP_W-1:0] a_warp;
	reg [15:0] a_pc;
	(* max_fanout = 12 *) reg [UOP_W-1:0] a_uop;
	reg [SBE_W:0] a_sbe;
	(* max_fanout = 12 *) reg [GRP_W-1:0] a_grp;
	(* max_fanout = 12 *) reg a_step;	/* 0 = step 0 (reads rs1, rs2), 1 = step 1 (reads rs3) */
	(* max_fanout = 12 *) reg a_pass;	/* the second operand pass of a four-operand uop */
	(* max_fanout = 12 *) reg a_wait;	/* 1 = waiting for registered RF output (when REG_IO == 1) */
	(* max_fanout = 12 *) reg a_wait_last;
	(* dont_touch = "true" *) reg [WARP_W-1:0] a_rf_warp_r;
	(* dont_touch = "true" *) reg [GRP_W-1:0] a_rf_grp_r;
	(* dont_touch = "true" *) reg [5:0] a_rf_r1_r;
	(* dont_touch = "true" *) reg [5:0] a_rf_r2_r;
	/* Stage B: the group on x_*. */
	(* max_fanout = 12 *) reg b_valid, b_last;
	(* max_fanout = 12 *) reg [3:0] b_unit_r;
	(* max_fanout = 12 *) reg b_sg_last_r;
	(* max_fanout = 12 *) reg [WARP_W-1:0] b_warp;
	reg [15:0] b_pc;
	(* max_fanout = 12 *) reg [UOP_W-1:0] b_uop;
	reg [SBE_W:0] b_sbe;
	(* max_fanout = 12 *) reg [GRP_W-1:0] b_grp;
	reg b_pass;
	reg b_step1;
	(* max_fanout = 12 *) reg [6:0] b_n1, b_n2, b_n3;
	reg b_is_gpr1, b_is_gpr2, b_is_gpr3;
	reg b_hit_rf_1, b_hit_rf_2, b_hit_rf_3;
	wire [DW-1:0] hold_r1;
	wire [DW-1:0] hold_r2;

	wire [3:0] b_unit = b_uop[ATG_UOP_UNIT +: 4];
	wire b_rdy = (REG_IO != 0) ?
		(b_sg_last_r ? unit_ready[ATG_UNIT_LANE] : ((b_unit_r == ATG_UNIT_LANE) ? 1'b1 : unit_ready[b_unit_r])) :
		unit_ready[b_unit];
	wire b_adv = !b_valid || b_rdy;
	assign x_end_out = b_valid && b_last && b_rdy;
	wire a_adv = a_act && ((REG_IO != 0) ? a_wait : b_adv);
	wire a_wide = a_uop[ATG_UOP_PAIR] && a_uop[ATG_UOP_USE3];
	wire a_needs_step1 = a_uop[ATG_UOP_USE3] || a_uop[ATG_UOP_PAIR];
	wire a_step_done = !a_needs_step1 || a_step;
	wire a_pass_done = (!a_wide || a_pass) && a_step_done;
	wire a_last = ({{(32-GRP_W){1'b0}}, a_grp} == G - 1) && a_pass_done;
	assign i_ready = !a_act || ((REG_IO != 0) ? a_wait_last : (a_adv && a_last));

	/* Operand numbers; operand 3 is rs1+1 for the PAIR instructions;
	 * operands 1 and 3 are rs3 and rs3+1 on a second pass. */
	wire [6:0] a_r1 = a_pass ? a_uop[ATG_UOP_RS3 +: 7] : a_uop[ATG_UOP_RS1 +: 7];
	wire [6:0] a_n1 = a_r1;
	wire [6:0] a_n2 = a_uop[ATG_UOP_RS2 +: 7];
	wire [6:0] a_r1p;
	wire [GRP_W-1:0] a_grp_next;
	wire ar_co_unused, ag_co_unused;
	am_add #(.W(7)) u_a_r1p (.a(a_r1), .b(7'd0), .ci(1'b1), .s(a_r1p), .co(ar_co_unused));
	am_add #(.W(GRP_W)) u_a_grp (.a(a_grp), .b({GRP_W{1'b0}}), .ci(1'b1), .s(a_grp_next),
		.co(ag_co_unused));
	wire [6:0] a_n3 = a_uop[ATG_UOP_PAIR] ? a_r1p : a_uop[ATG_UOP_RS3 +: 7];

	wire [6:0] a_rf_r1 = a_step ? a_n3 : a_r1;
	wire [6:0] a_rf_r2 = a_step ? 7'd0 : a_n2;

	assign r_en = a_act && (REG_IO ? !a_wait : 1'b1) && b_adv;
	assign r_warp = a_rf_warp_r;
	assign r_grp = a_rf_grp_r;
	assign r_regs = {a_rf_r2_r, a_rf_r1_r};
	assign cr_en = a_act && (REG_IO ? !a_wait : 1'b1) && b_adv && (!a_needs_step1 || !a_step);
	assign cr_idx = {a_n3[4:0], a_n2[4:0], a_n1[4:0]};
	assign rq_pop = a_act && (REG_IO ? !a_wait : 1'b1) && b_adv && a_uop[ATG_UOP_RQS] && !a_pass && (!a_needs_step1 || !a_step);

	wire a_match_wb_1 = fwd_wb_valid && (a_n1 < 7'd63) && (fwd_wb_rd < 7'd63) &&
	                    (fwd_wb_warp == a_warp) && (fwd_wb_grp == a_grp) && (fwd_wb_rd[5:0] == a_n1[5:0]);
	wire a_match_wb_2 = fwd_wb_valid && (a_n2 < 7'd63) && (fwd_wb_rd < 7'd63) &&
	                    (fwd_wb_warp == a_warp) && (fwd_wb_grp == a_grp) && (fwd_wb_rd[5:0] == a_n2[5:0]);
	wire a_match_wb_3 = fwd_wb_valid && (a_n3 < 7'd63) && (fwd_wb_rd < 7'd63) &&
	                    (fwd_wb_warp == a_warp) && (fwd_wb_grp == a_grp) && (fwd_wb_rd[5:0] == a_n3[5:0]);

	wire a_match_alu_ex4_1 = fwd_alu_ex3_valid && (a_n1 < 7'd63) && (fwd_alu_ex3_rd < 7'd63) &&
	                         (fwd_alu_ex3_warp == a_warp) && (fwd_alu_ex3_grp == a_grp) && (fwd_alu_ex3_rd[5:0] == a_n1[5:0]);
	wire a_match_alu_ex4_2 = fwd_alu_ex3_valid && (a_n2 < 7'd63) && (fwd_alu_ex3_rd < 7'd63) &&
	                         (fwd_alu_ex3_warp == a_warp) && (fwd_alu_ex3_grp == a_grp) && (fwd_alu_ex3_rd[5:0] == a_n2[5:0]);
	wire a_match_alu_ex4_3 = fwd_alu_ex3_valid && (a_n3 < 7'd63) && (fwd_alu_ex3_rd < 7'd63) &&
	                         (fwd_alu_ex3_warp == a_warp) && (fwd_alu_ex3_grp == a_grp) && (fwd_alu_ex3_rd[5:0] == a_n3[5:0]);

	wire a_match_alu_ex5_1 = fwd_alu_ex4_valid && (a_n1 < 7'd63) && (fwd_alu_ex4_rd < 7'd63) &&
	                         (fwd_alu_ex4_warp == a_warp) && (fwd_alu_ex4_grp == a_grp) && (fwd_alu_ex4_rd[5:0] == a_n1[5:0]);
	wire a_match_alu_ex5_2 = fwd_alu_ex4_valid && (a_n2 < 7'd63) && (fwd_alu_ex4_rd < 7'd63) &&
	                         (fwd_alu_ex4_warp == a_warp) && (fwd_alu_ex4_grp == a_grp) && (fwd_alu_ex4_rd[5:0] == a_n2[5:0]);
	wire a_match_alu_ex5_3 = fwd_alu_ex4_valid && (a_n3 < 7'd63) && (fwd_alu_ex4_rd < 7'd63) &&
	                         (fwd_alu_ex4_warp == a_warp) && (fwd_alu_ex4_grp == a_grp) && (fwd_alu_ex4_rd[5:0] == a_n3[5:0]);

	reg b_hit_alu_ex4_1, b_hit_alu_ex4_2, b_hit_alu_ex4_3;
	reg b_hit_alu_ex5_1, b_hit_alu_ex5_2, b_hit_alu_ex5_3;
	reg [159:0] b_q_info;

	/* Stage A precomputation registers for REG_IO != 0 */
	(* max_fanout = 12 *) reg [2:0] a_k1_r, a_k2_r, a_k3_r;
	(* max_fanout = 12 *) reg a_use_cw1_r, a_use_cw2_r, a_use_cw3_r;
	(* max_fanout = 12 *) reg a_is_104_1_r, a_is_104_2_r, a_is_104_3_r;
	reg [31:0] a_cval1_r, a_cval2_r, a_cval3_r;
	wire [DW-1:0] a_cl_r;
	reg [NPHYS-1:0] a_cov_g_r;
	reg [31:0] a_info_r;

	wire [DW-1:0] b_early_va, b_early_vb, b_early_vc;
	(* max_fanout = 12 *) reg b_use_rf1, b_use_rf2, b_use_rf3;
	(* max_fanout = 12 *) reg b_clr31_1, b_inv31_1, b_clr15_1, b_inv15_1;
	(* max_fanout = 12 *) reg b_clr31_2, b_inv31_2, b_clr15_2, b_inv15_2;
	(* max_fanout = 12 *) reg b_clr31_3, b_inv31_3, b_clr15_3, b_inv15_3;
	reg [2*NPHYS-1:0] b_mask_r;
	reg [31:0] b_info_r;

	wire [4:0] a_grp_base = (G > 1) ? {a_grp, {($clog2(NPHYS)){1'b0}}} : 5'd0;
	wire [DW-1:0] a_cl_comb;
	wire [NPHYS-1:0] a_cl_co_unused;
	genvar la;
	generate
		for (la = 0; la < NPHYS; la = la + 1) begin : g_acl
			wire [4:0] a_ln = a_grp_base[4:0] | la[4:0];
			wire [8:0] a_cl_s;
			am_add #(.W(9)) u_acl (
				.a({1'b0, q_info[ATG_WI_LID +: 8]}),
				.b({4'd0, a_ln}),
				.ci(1'b0),
				.s(a_cl_s),
				.co(a_cl_co_unused[la])
			);
			assign a_cl_comb[la*32 +: 32] = {23'd0, a_cl_s};
			(* shreg_extract = "no" *) reg [8:0] a_cl_l;
			(* keep = "true" *) wire a_cl_we_l = (REG_IO != 0) && a_act && !a_wait && b_adv;
			always @(posedge clk) begin
				if (rst_p)
					a_cl_l <= 9'd0;
				else if (a_cl_we_l)
					a_cl_l <= a_cl_s;
			end
			assign a_cl_r[la*32 +: 32] = {23'd0, a_cl_l};
		end
	endgenerate

	reg [NPHYS-1:0] a_exec_g, a_kill_g, a_cov_g;
	integer agi;
	always @(*) begin
		a_exec_g = {NPHYS{1'b0}};
		a_kill_g = {NPHYS{1'b0}};
		a_cov_g  = {NPHYS{1'b0}};
		for (agi = 0; agi < 32/NPHYS; agi = agi + 1) begin
			if (a_grp == agi[GRP_W-1:0]) begin
				a_exec_g = q_exec[agi*NPHYS +: NPHYS];
				a_kill_g = q_killed[agi*NPHYS +: NPHYS];
				a_cov_g  = q_info[ATG_WI_MASK + agi*NPHYS +: NPHYS];
			end
		end
	end

	wire [3:0] a_unit = a_uop[ATG_UOP_UNIT +: 4];
	wire [7:0] a_op = a_uop[ATG_UOP_OP +: 8];
	wire a_fp_unit = a_unit == ATG_UNIT_FPU || a_unit == ATG_UNIT_XU;
	wire a_pk_unit = a_unit == ATG_UNIT_PK;
	wire [6:0] a_mods = a_uop[ATG_UOP_MOD +: 7];
	wire [31:0] a_com1 = a_use_cw1_r ? cr_data[31:0]  : (a_is_104_1_r ? q_exec : a_cval1_r);
	wire [31:0] a_com2 = a_use_cw2_r ? cr_data[63:32] : (a_is_104_2_r ? q_exec : a_cval2_r);
	wire [31:0] a_com3 = a_use_cw3_r ? cr_data[95:64] : (a_is_104_3_r ? q_exec : a_cval3_r);
	wire [DW-1:0] a_early_va_comb, a_early_vb_comb, a_early_vc_comb;
	genvar lb, lbh;
	generate
		for (lb = 0; lb < NPHYS; lb = lb + 1) begin : g_aearly
			wire [4:0] a_ln = a_grp_base[4:0] | lb[4:0];
			wire [31:0] a_op1 = (a_k1_r == 3'd1) ? hold_r1[lb*32 +: 32] :
				opl(a_k1_r, a_com1, 32'd0, rq_data[lb*32 +: 32], a_ln, a_kill_g[lb], a_cl_r[lb*32 +: 32]);
			wire [31:0] a_op2 = (a_k2_r == 3'd1) ? hold_r2[lb*32 +: 32] :
				opl(a_k2_r, a_com2, 32'd0, rq_data[lb*32 +: 32], a_ln, a_kill_g[lb], a_cl_r[lb*32 +: 32]);
			wire [31:0] a_op3 = (a_k3_r == 3'd1) ? 32'd0 :
				opl(a_k3_r, a_com3, 32'd0, rq_data[lb*32 +: 32], a_ln, a_kill_g[lb], a_cl_r[lb*32 +: 32]);
			assign a_early_va_comb[lb*32 +: 32] = fmod(a_op1, a_mods[0], a_mods[1], a_fp_unit, a_pk_unit);
			assign a_early_vb_comb[lb*32 +: 32] = fmod(a_op2, a_mods[2], a_mods[3], a_fp_unit, a_pk_unit);
			assign a_early_vc_comb[lb*32 +: 32] = fmod(a_op3, a_mods[4], a_mods[5], a_fp_unit, a_pk_unit);
			for (lbh = 0; lbh < 2; lbh = lbh + 1) begin : g_b_early_h
				(* shreg_extract = "no" *) reg [15:0] b_va_h, b_vb_h, b_vc_h;
				(* shreg_extract = "no" *) reg [15:0] hold_r1_h, hold_r2_h;
				(* keep = "true" *) wire b_va_we_h = (REG_IO != 0) ? (a_adv && a_step_done) : (b_adv && a_adv && a_step_done);
				(* keep = "true" *) wire b_vb_we_h = (REG_IO != 0) ? (a_adv && a_step_done) : (b_adv && a_adv && a_step_done);
				(* keep = "true" *) wire b_vc_we_h = (REG_IO != 0) ? (a_adv && a_step_done) : (b_adv && a_adv && a_step_done);
				(* keep = "true" *) wire hold1_we_h = a_step && !a_wait;
				(* keep = "true" *) wire hold2_we_h = a_step && !a_wait;
				always @(posedge clk) begin
					if (rst_p) begin
						b_va_h <= 16'd0;
						b_vb_h <= 16'd0;
						b_vc_h <= 16'd0;
						hold_r1_h <= 16'd0;
						hold_r2_h <= 16'd0;
					end else begin
						if (b_va_we_h)
							b_va_h <= a_early_va_comb[lb*32 + lbh*16 +: 16];
						if (b_vb_we_h)
							b_vb_h <= a_early_vb_comb[lb*32 + lbh*16 +: 16];
						if (b_vc_we_h)
							b_vc_h <= a_early_vc_comb[lb*32 + lbh*16 +: 16];
						if (hold1_we_h)
							hold_r1_h <= r_data[lb*32 + lbh*16 +: 16];
						if (hold2_we_h)
							hold_r2_h <= r_data[DW + lb*32 + lbh*16 +: 16];
					end
				end
				assign b_early_va[lb*32 + lbh*16 +: 16] = b_va_h;
				assign b_early_vb[lb*32 + lbh*16 +: 16] = b_vb_h;
				assign b_early_vc[lb*32 + lbh*16 +: 16] = b_vc_h;
				assign hold_r1[lb*32 + lbh*16 +: 16] = hold_r1_h;
				assign hold_r2[lb*32 + lbh*16 +: 16] = hold_r2_h;
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			a_act <= 1'b0;
			b_valid <= 1'b0;
			b_unit_r <= 4'd0;
			b_sg_last_r <= 1'b0;
			a_warp <= {WARP_W{1'b0}};
			a_rf_warp_r <= {WARP_W{1'b0}};
			a_pc <= 16'd0;
			a_uop <= {UOP_W{1'b0}};
			a_sbe <= {(SBE_W+1){1'b0}};
			a_grp <= {GRP_W{1'b0}};
			a_rf_grp_r <= {GRP_W{1'b0}};
			a_step <= 1'b0;
			a_pass <= 1'b0;
			a_wait <= 1'b0;
			a_wait_last <= 1'b0;
			a_rf_r1_r <= 6'd0;
			a_rf_r2_r <= 6'd0;
			b_pass <= 1'b0;
			b_step1 <= 1'b0;
			b_n1 <= 7'd0;
			b_n2 <= 7'd0;
			b_n3 <= 7'd0;
			b_is_gpr1 <= 1'b0;
			b_is_gpr2 <= 1'b0;
			b_is_gpr3 <= 1'b0;
			b_hit_rf_1 <= 1'b0;
			b_hit_rf_2 <= 1'b0;
			b_hit_rf_3 <= 1'b0;
			b_hit_alu_ex4_1 <= 1'b0;
			b_hit_alu_ex4_2 <= 1'b0;
			b_hit_alu_ex4_3 <= 1'b0;
			b_hit_alu_ex5_1 <= 1'b0;
			b_hit_alu_ex5_2 <= 1'b0;
			b_hit_alu_ex5_3 <= 1'b0;
			b_last <= 1'b0;
			b_warp <= {WARP_W{1'b0}};
			b_q_info <= 160'd0;
			b_pc <= 16'd0;
			b_uop <= {UOP_W{1'b0}};
			b_sbe <= {(SBE_W+1){1'b0}};
			b_grp <= {GRP_W{1'b0}};
			a_k1_r <= 3'd0;
			a_k2_r <= 3'd0;
			a_k3_r <= 3'd0;
			a_use_cw1_r <= 1'b0;
			a_use_cw2_r <= 1'b0;
			a_use_cw3_r <= 1'b0;
			a_is_104_1_r <= 1'b0;
			a_is_104_2_r <= 1'b0;
			a_is_104_3_r <= 1'b0;
			a_cval1_r <= 32'd0;
			a_cval2_r <= 32'd0;
			a_cval3_r <= 32'd0;
			a_cov_g_r <= {NPHYS{1'b0}};
			a_info_r <= 32'd0;
			b_use_rf1 <= 1'b0;
			b_use_rf2 <= 1'b0;
			b_use_rf3 <= 1'b0;
			b_clr31_1 <= 1'b0; b_inv31_1 <= 1'b0; b_clr15_1 <= 1'b0; b_inv15_1 <= 1'b0;
			b_clr31_2 <= 1'b0; b_inv31_2 <= 1'b0; b_clr15_2 <= 1'b0; b_inv15_2 <= 1'b0;
			b_clr31_3 <= 1'b0; b_inv31_3 <= 1'b0; b_clr15_3 <= 1'b0; b_inv15_3 <= 1'b0;
			b_mask_r <= {(2*NPHYS){1'b0}};
			b_info_r <= 32'd0;
		end else begin
			if (REG_IO != 0 && a_act && !a_wait && b_adv) begin
				a_k1_r <= opk(a_n1, q_info[ATG_WI_KIND +: 2]);
				a_k2_r <= opk(a_n2, q_info[ATG_WI_KIND +: 2]);
				a_k3_r <= opk(a_n3, q_info[ATG_WI_KIND +: 2]);
				a_use_cw1_r <= (a_n1 < 7'd96);
				a_use_cw2_r <= (a_n2 < 7'd96);
				a_use_cw3_r <= (a_n3 < 7'd96);
				a_is_104_1_r <= (a_n1 == 7'd104);
				a_is_104_2_r <= (a_n2 == 7'd104);
				a_is_104_3_r <= (a_n3 == 7'd104);
				a_cval1_r <= opc(a_n1, 32'd0, a_warp, q_info, 32'd0);
				a_cval2_r <= opc(a_n2, 32'd0, a_warp, q_info, 32'd0);
				a_cval3_r <= opc(a_n3, 32'd0, a_warp, q_info, 32'd0);
				a_cov_g_r <= a_cov_g;
				a_info_r <= {13'd0, q_info[ATG_WI_FRONT], q_info[ATG_WI_KIND +: 2],
					q_info[ATG_WI_SEQ +: 16]};
			end
			if ((REG_IO != 0) ? (a_adv && a_step_done) : (b_adv && a_adv && a_step_done)) begin
				b_warp <= a_warp;
				b_q_info <= q_info;
				b_pc <= a_pc;
				b_uop <= (REG_IO != 0) ?
					(a_uop | ({{(UOP_W-1){1'b0}}, a_pass} << (ATG_UOP_OP + ATG_TEX_PASS2))) :
					a_uop;
				b_unit_r <= a_unit;
				b_sg_last_r <= a_last && (a_unit == ATG_UNIT_LANE) &&
					(a_op == ATG_LANE_SHFL || a_op == ATG_LANE_VOTE || a_op == ATG_LANE_BALLOT);
				b_sbe <= a_sbe;
				b_grp <= a_grp;
				b_pass <= a_pass;
				b_last <= a_last;
				b_step1 <= a_needs_step1;
				b_n1 <= a_n1;
				b_n2 <= a_n2;
				b_n3 <= a_n3;
				b_is_gpr1 <= a_n1 < 7'd63;
				b_is_gpr2 <= a_n2 < 7'd63;
				b_is_gpr3 <= a_n3 < 7'd63;
				b_use_rf1 <= (a_k1_r == 3'd1) && !a_needs_step1;
				b_use_rf2 <= (a_k2_r == 3'd1) && !a_needs_step1;
				b_use_rf3 <= (a_k3_r == 3'd1);
				b_clr31_1 <= (a_fp_unit || a_pk_unit) && a_mods[1];
				b_inv31_1 <= (a_fp_unit || a_pk_unit) && a_mods[0];
				b_clr15_1 <= a_pk_unit && a_mods[1];
				b_inv15_1 <= a_pk_unit && a_mods[0];
				b_clr31_2 <= (a_fp_unit || a_pk_unit) && a_mods[3];
				b_inv31_2 <= (a_fp_unit || a_pk_unit) && a_mods[2];
				b_clr15_2 <= a_pk_unit && a_mods[3];
				b_inv15_2 <= a_pk_unit && a_mods[2];
				b_clr31_3 <= (a_fp_unit || a_pk_unit) && a_mods[5];
				b_inv31_3 <= (a_fp_unit || a_pk_unit) && a_mods[4];
				b_clr15_3 <= a_pk_unit && a_mods[5];
				b_inv15_3 <= a_pk_unit && a_mods[4];
				b_mask_r <= {a_exec_g & a_cov_g_r & ~a_kill_g, a_exec_g};
				b_info_r <= a_info_r;
			end
			if (b_adv) begin
				if (a_adv) begin
					b_valid <= a_step_done;
					if (a_step_done) begin
						b_hit_rf_1 <= (REG_IO != 0) ? 1'b0 : a_match_wb_1;
						b_hit_rf_2 <= (REG_IO != 0) ? 1'b0 : a_match_wb_2;
						b_hit_rf_3 <= (REG_IO != 0) ? 1'b0 : a_match_wb_3;
						b_hit_alu_ex4_1 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex4_1;
						b_hit_alu_ex4_2 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex4_2;
						b_hit_alu_ex4_3 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex4_3;
						b_hit_alu_ex5_1 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex5_1;
						b_hit_alu_ex5_2 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex5_2;
						b_hit_alu_ex5_3 <= (REG_IO != 0) ? 1'b0 : a_match_alu_ex5_3;
					end
				end else begin
					b_valid <= 1'b0;
					b_hit_rf_1 <= 1'b0;
					b_hit_rf_2 <= 1'b0;
					b_hit_rf_3 <= 1'b0;
					b_hit_alu_ex4_1 <= 1'b0;
					b_hit_alu_ex4_2 <= 1'b0;
					b_hit_alu_ex4_3 <= 1'b0;
					b_hit_alu_ex5_1 <= 1'b0;
					b_hit_alu_ex5_2 <= 1'b0;
					b_hit_alu_ex5_3 <= 1'b0;
				end
			end else begin
				b_hit_alu_ex4_1 <= 1'b0;
				b_hit_alu_ex4_2 <= 1'b0;
				b_hit_alu_ex4_3 <= 1'b0;
				b_hit_alu_ex5_1 <= 1'b0;
				b_hit_alu_ex5_2 <= 1'b0;
				b_hit_alu_ex5_3 <= 1'b0;
			end
			if (REG_IO != 0) begin
				if (a_act && !a_wait && b_adv) begin
					a_wait <= 1'b1;
					a_wait_last <= a_last;
				end else if (a_adv) begin
					a_wait <= 1'b0;
					a_wait_last <= 1'b0;
				end
			end
			if (i_ready) begin
				a_warp <= i_warp;
				a_rf_warp_r <= i_warp;
				a_pc <= i_pc;
				a_uop <= i_uop;
				a_sbe <= i_sbe;
				a_rf_r1_r <= i_uop[ATG_UOP_RS1 +: 6];
				a_rf_r2_r <= i_uop[ATG_UOP_RS2 +: 6];
			end
			if (i_ready) begin
				a_act <= i_valid;
			end
			if (a_adv) begin
				if (a_needs_step1 && !a_step) begin
					a_step <= 1'b1;
					a_rf_r1_r <= a_n3[5:0];
					a_rf_r2_r <= 6'd0;
				end else begin
					a_step <= 1'b0;
					if (a_wide && !a_pass) begin
						a_pass <= 1'b1;
						a_rf_r1_r <= a_uop[ATG_UOP_RS3 +: 6];
						a_rf_r2_r <= a_uop[ATG_UOP_RS2 +: 6];
					end else begin
						a_pass <= 1'b0;
						if (a_last) begin
							a_grp <= {GRP_W{1'b0}};
							a_rf_grp_r <= {GRP_W{1'b0}};
						end else begin
							a_grp <= a_grp_next;
							a_rf_grp_r <= a_grp_next;
							a_rf_r1_r <= a_uop[ATG_UOP_RS1 +: 6];
							a_rf_r2_r <= a_uop[ATG_UOP_RS2 +: 6];
						end
					end
				end
			end
		end
	end

	/* Stage B: operand selection. */
	wire [6:0] mods = b_uop[ATG_UOP_MOD +: 7];
	wire fp_unit = b_unit == ATG_UNIT_FPU || b_unit == ATG_UNIT_XU;
	wire pk_unit = b_unit == ATG_UNIT_PK;
	wire [4:0] grp_base = (G > 1) ? {b_grp, {($clog2(NPHYS)){1'b0}}} : 5'd0;

	reg [NPHYS-1:0] exec_g, kill_g, cov_g;
	integer gi;
	always @(*) begin
		exec_g = {NPHYS{1'b0}};
		kill_g = {NPHYS{1'b0}};
		cov_g  = {NPHYS{1'b0}};
		for (gi = 0; gi < 32/NPHYS; gi = gi + 1) begin
			if (b_grp == gi[GRP_W-1:0]) begin
				exec_g = q_exec[gi*NPHYS +: NPHYS];
				kill_g = q_killed[gi*NPHYS +: NPHYS];
				cov_g  = b_q_info[ATG_WI_MASK + gi*NPHYS +: NPHYS];
			end
		end
	end
	assign a_q_warp = a_warp;
	assign q_warp = (REG_IO != 0) ? a_warp : b_warp;

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
				7'd103: opc = WARP_BASE[31:0] | {{(32-WARP_W){1'b0}}, wn};
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
				7'd120: opc = (qi[ATG_WI_KIND +: 2] == 2'd0) ? {24'd0, qi[ATG_WI_LID +: 8]} : 32'd0;
				7'd121: opc = 32'd0;
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
		input [1:0] kind;
		begin
			if (n < 7'd63)
				opk = 3'd1;
			else if (n == 7'd63)
				opk = 3'd2;
			else if (n == 7'd102)
				opk = 3'd3;
			else if (n == 7'd105)
				opk = 3'd4;
			else if (n == 7'd109 || n == 7'd112 || (n == 7'd120 && kind == 2'd0))
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
		input [31:0] com_lane;	/* com + lane */
		begin
			case (k)
			3'd1: opl = gpr;
			3'd2: opl = rq;
			3'd3: opl = {27'd0, lane};
			3'd4: opl = {32{kl}};
			3'd5: opl = com_lane;
			default: opl = com;
			endcase
		end
	endfunction

	/* The float modifiers: abs, then negate.
	 * Only bit 31 (for fp and pk) and bit 15 (for pk) are modified.
	 * Bits [30:16] and [14:0] pass straight through with zero logic. */
	function [31:0] fmod;
		input [31:0] v;
		input ng, ab, fp, pk;
		reg s31, s15;
		begin
			s31 = v[31];
			s15 = v[15];
			if (fp) begin
				if (ab)
					s31 = 1'b0;
				if (ng)
					s31 = !s31;
			end else if (pk) begin
				if (ab) begin
					s31 = 1'b0;
					s15 = 1'b0;
				end
				if (ng) begin
					s31 = !s31;
					s15 = !s15;
				end
			end
			fmod = {s31, v[30:16], s15, v[14:0]};
		end
	endfunction

	wire [DW-1:0] va, vb, vc;

	/* Register to catch RF write-read collision (1-cycle delay from fwd_wb) */
	reg [DW-1:0]     fwd_rf_data;
	reg [NPHYS-1:0]  fwd_rf_lanes;

	always @(posedge clk) begin
		if (rst_p) begin
			fwd_rf_data  <= {DW{1'b0}};
			fwd_rf_lanes <= {NPHYS{1'b0}};
		end else begin
			fwd_rf_data  <= fwd_wb_data;
			fwd_rf_lanes <= fwd_wb_lanes;
		end
	end

	/* The common part and the kind of each operand, once per instruction. */
	wire [31:0] com1 = opc(b_n1, cr_data[31:0], b_warp, b_q_info, q_exec);
	wire [31:0] com2 = opc(b_n2, cr_data[63:32], b_warp, b_q_info, q_exec);
	wire [31:0] com3 = opc(b_n3, cr_data[95:64], b_warp, b_q_info, q_exec);
	wire [2:0] k1 = opk(b_n1, b_q_info[ATG_WI_KIND +: 2]);
	wire [2:0] k2 = opk(b_n2, b_q_info[ATG_WI_KIND +: 2]);
	wire [2:0] k3 = opk(b_n3, b_q_info[ATG_WI_KIND +: 2]);

	/* Operand forwarding comparison for GPRs:
	 * - ALU EX4 is registered (s4_data is flip-flop output), safe to forward back-to-back.
	 * - FPU EX4 is combinational (fpu_res has ~21ns logic delay), completely cut.
	 * - Both ALU and FPU forward from EX5 (registered) and WB/RF.
	 */
	wire hit_alu_ex4_1 = (REG_IO == 0) ?
		(fwd_alu_ex4_valid && b_is_gpr1 && (fwd_alu_ex4_rd < 7'd63) && (fwd_alu_ex4_warp == b_warp) && (fwd_alu_ex4_grp == b_grp) && (fwd_alu_ex4_rd[5:0] == b_n1[5:0])) :
		b_hit_alu_ex4_1;
	wire hit_fpu_ex4_1 = 1'b0;
	wire hit_alu_ex5_1 = (REG_IO == 0) ?
		(fwd_alu_ex5_valid && b_is_gpr1 && (fwd_alu_ex5_rd < 7'd63) && (fwd_alu_ex5_warp == b_warp) && (fwd_alu_ex5_grp == b_grp) && (fwd_alu_ex5_rd[5:0] == b_n1[5:0])) :
		b_hit_alu_ex5_1;
	wire hit_fpu_ex5_1 = (REG_IO == 0) ?
		(fwd_fpu_ex5_valid && b_is_gpr1 && (fwd_fpu_ex5_rd < 7'd63) && (fwd_fpu_ex5_warp == b_warp) && (fwd_fpu_ex5_grp == b_grp) && (fwd_fpu_ex5_rd[5:0] == b_n1[5:0])) :
		1'b0;
	wire hit_wb_1      = (REG_IO == 0) ?
		(fwd_wb_valid && b_is_gpr1 && (fwd_wb_rd < 7'd63) && (fwd_wb_warp == b_warp) && (fwd_wb_grp == b_grp) && (fwd_wb_rd[5:0] == b_n1[5:0])) :
		1'b0;
	wire hit_rf_1      = b_hit_rf_1;

	wire hit_alu_ex4_2 = (REG_IO == 0) ?
		(fwd_alu_ex4_valid && b_is_gpr2 && (fwd_alu_ex4_rd < 7'd63) && (fwd_alu_ex4_warp == b_warp) && (fwd_alu_ex4_grp == b_grp) && (fwd_alu_ex4_rd[5:0] == b_n2[5:0])) :
		b_hit_alu_ex4_2;
	wire hit_fpu_ex4_2 = 1'b0;
	wire hit_alu_ex5_2 = (REG_IO == 0) ?
		(fwd_alu_ex5_valid && b_is_gpr2 && (fwd_alu_ex5_rd < 7'd63) && (fwd_alu_ex5_warp == b_warp) && (fwd_alu_ex5_grp == b_grp) && (fwd_alu_ex5_rd[5:0] == b_n2[5:0])) :
		b_hit_alu_ex5_2;
	wire hit_fpu_ex5_2 = (REG_IO == 0) ?
		(fwd_fpu_ex5_valid && b_is_gpr2 && (fwd_fpu_ex5_rd < 7'd63) && (fwd_fpu_ex5_warp == b_warp) && (fwd_fpu_ex5_grp == b_grp) && (fwd_fpu_ex5_rd[5:0] == b_n2[5:0])) :
		1'b0;
	wire hit_wb_2      = (REG_IO == 0) ?
		(fwd_wb_valid && b_is_gpr2 && (fwd_wb_rd < 7'd63) && (fwd_wb_warp == b_warp) && (fwd_wb_grp == b_grp) && (fwd_wb_rd[5:0] == b_n2[5:0])) :
		1'b0;
	wire hit_rf_2      = b_hit_rf_2;

	wire hit_alu_ex4_3 = (REG_IO == 0) ?
		(fwd_alu_ex4_valid && b_is_gpr3 && (fwd_alu_ex4_rd < 7'd63) && (fwd_alu_ex4_warp == b_warp) && (fwd_alu_ex4_grp == b_grp) && (fwd_alu_ex4_rd[5:0] == b_n3[5:0])) :
		b_hit_alu_ex4_3;
	wire hit_fpu_ex4_3 = 1'b0;
	wire hit_alu_ex5_3 = (REG_IO == 0) ?
		(fwd_alu_ex5_valid && b_is_gpr3 && (fwd_alu_ex5_rd < 7'd63) && (fwd_alu_ex5_warp == b_warp) && (fwd_alu_ex5_grp == b_grp) && (fwd_alu_ex5_rd[5:0] == b_n3[5:0])) :
		b_hit_alu_ex5_3;
	wire hit_fpu_ex5_3 = (REG_IO == 0) ?
		(fwd_fpu_ex5_valid && b_is_gpr3 && (fwd_fpu_ex5_rd < 7'd63) && (fwd_fpu_ex5_warp == b_warp) && (fwd_fpu_ex5_grp == b_grp) && (fwd_fpu_ex5_rd[5:0] == b_n3[5:0])) :
		1'b0;
	wire hit_wb_3      = (REG_IO == 0) ?
		(fwd_wb_valid && b_is_gpr3 && (fwd_wb_rd < 7'd63) && (fwd_wb_warp == b_warp) && (fwd_wb_grp == b_grp) && (fwd_wb_rd[5:0] == b_n3[5:0])) :
		1'b0;
	wire hit_rf_3      = b_hit_rf_3;

	/*
	 * Per lane: its number in the warp (the group's base and l: disjoint
	 * bits), local index (LID + ln, 9-bit adder independent of opc).
	 */
	wire [NPHYS-1:0] cl_co_unused;
	genvar l;
	generate
		for (l = 0; l < NPHYS; l = l + 1) begin : g_lane
			wire [4:0] ln = grp_base[4:0] | l[4:0];
			wire [8:0] cl_s;
			am_add #(.W(9)) u_cl (.a({1'b0, b_q_info[ATG_WI_LID +: 8]}), .b({4'd0, ln}), .ci(1'b0),
				.s(cl_s), .co(cl_co_unused[l]));
			wire [31:0] cl = {23'd0, cl_s};

			/* Early operand paths: evaluated in parallel from register sources */
			wire fwd_hit_1 = (hit_alu_ex4_1 && fwd_alu_ex4_lanes[l]) ||
			                 (hit_alu_ex5_1 && fwd_alu_ex5_lanes[l]) ||
			                 (hit_fpu_ex5_1 && fwd_fpu_ex5_lanes[l]) ||
			                 (hit_wb_1      && fwd_wb_lanes[l]) ||
			                 (hit_rf_1      && fwd_rf_lanes[l]);

			wire [31:0] fwd_data_1 = (hit_alu_ex4_1 && fwd_alu_ex4_lanes[l]) ? fwd_alu_ex4_data[l*32 +: 32] :
			                         (hit_alu_ex5_1 && fwd_alu_ex5_lanes[l]) ? fwd_alu_ex5_data[l*32 +: 32] :
			                         (hit_fpu_ex5_1 && fwd_fpu_ex5_lanes[l]) ? fwd_fpu_ex5_data[l*32 +: 32] :
			                         (hit_wb_1      && fwd_wb_lanes[l]) ? fwd_wb_data[l*32 +: 32] :
			                         fwd_rf_data[l*32 +: 32];

			wire use_rf1 = (k1 == 3'd1) && !fwd_hit_1 && !b_step1;
			wire [31:0] early_gpr1 = fwd_hit_1 ? fwd_data_1 : hold_r1[l*32 +: 32];
			wire [31:0] early_op1 = (k1 == 3'd1) ? early_gpr1 : opl(k1, com1, 32'd0, rq_data[l*32 +: 32], ln, kill_g[l], cl);
			wire [31:0] early_va1 = fmod(early_op1, mods[0], mods[1], fp_unit, pk_unit);
			wire [31:0] rf_va1_0 = fmod(r_data[l*32 +: 32], mods[0], mods[1], fp_unit, pk_unit);
			wire [31:0] rf_va1_r = {(r_data[l*32 + 31] & ~b_clr31_1) ^ b_inv31_1, r_data[l*32 + 16 +: 15],
				(r_data[l*32 + 15] & ~b_clr15_1) ^ b_inv15_1, r_data[l*32 +: 15]};
			assign va[l*32 +: 32] = (REG_IO != 0) ?
				(b_use_rf1 ? rf_va1_r : b_early_va[l*32 +: 32]) :
				(use_rf1 ? rf_va1_0 : early_va1);

			wire fwd_hit_2 = (hit_alu_ex4_2 && fwd_alu_ex4_lanes[l]) ||
			                 (hit_alu_ex5_2 && fwd_alu_ex5_lanes[l]) ||
			                 (hit_fpu_ex5_2 && fwd_fpu_ex5_lanes[l]) ||
			                 (hit_wb_2      && fwd_wb_lanes[l]) ||
			                 (hit_rf_2      && fwd_rf_lanes[l]);

			wire [31:0] fwd_data_2 = (hit_alu_ex4_2 && fwd_alu_ex4_lanes[l]) ? fwd_alu_ex4_data[l*32 +: 32] :
			                         (hit_alu_ex5_2 && fwd_alu_ex5_lanes[l]) ? fwd_alu_ex5_data[l*32 +: 32] :
			                         (hit_fpu_ex5_2 && fwd_fpu_ex5_lanes[l]) ? fwd_fpu_ex5_data[l*32 +: 32] :
			                         (hit_wb_2      && fwd_wb_lanes[l]) ? fwd_wb_data[l*32 +: 32] :
			                         fwd_rf_data[l*32 +: 32];

			wire use_rf2 = (k2 == 3'd1) && !fwd_hit_2 && !b_step1;
			wire [31:0] early_gpr2 = fwd_hit_2 ? fwd_data_2 : hold_r2[l*32 +: 32];
			wire [31:0] early_op2 = (k2 == 3'd1) ? early_gpr2 : opl(k2, com2, 32'd0, rq_data[l*32 +: 32], ln, kill_g[l], cl);
			wire [31:0] early_vb2 = fmod(early_op2, mods[2], mods[3], fp_unit, pk_unit);
			wire [31:0] rf_vb2_0 = fmod(r_data[DW + l*32 +: 32], mods[2], mods[3], fp_unit, pk_unit);
			wire [31:0] rf_vb2_r = {(r_data[DW + l*32 + 31] & ~b_clr31_2) ^ b_inv31_2, r_data[DW + l*32 + 16 +: 15],
				(r_data[DW + l*32 + 15] & ~b_clr15_2) ^ b_inv15_2, r_data[DW + l*32 +: 15]};
			assign vb[l*32 +: 32] = (REG_IO != 0) ?
				(b_use_rf2 ? rf_vb2_r : b_early_vb[l*32 +: 32]) :
				(use_rf2 ? rf_vb2_0 : early_vb2);

			wire fwd_hit_3 = (hit_alu_ex4_3 && fwd_alu_ex4_lanes[l]) ||
			                 (hit_alu_ex5_3 && fwd_alu_ex5_lanes[l]) ||
			                 (hit_fpu_ex5_3 && fwd_fpu_ex5_lanes[l]) ||
			                 (hit_wb_3      && fwd_wb_lanes[l]) ||
			                 (hit_rf_3      && fwd_rf_lanes[l]);

			wire [31:0] fwd_data_3 = (hit_alu_ex4_3 && fwd_alu_ex4_lanes[l]) ? fwd_alu_ex4_data[l*32 +: 32] :
			                         (hit_alu_ex5_3 && fwd_alu_ex5_lanes[l]) ? fwd_alu_ex5_data[l*32 +: 32] :
			                         (hit_fpu_ex5_3 && fwd_fpu_ex5_lanes[l]) ? fwd_fpu_ex5_data[l*32 +: 32] :
			                         (hit_wb_3      && fwd_wb_lanes[l]) ? fwd_wb_data[l*32 +: 32] :
			                         fwd_rf_data[l*32 +: 32];

			wire use_rf3 = (k3 == 3'd1) && !fwd_hit_3;
			wire [31:0] early_op3 = (k3 == 3'd1) ? fwd_data_3 : opl(k3, com3, 32'd0, rq_data[l*32 +: 32], ln, kill_g[l], cl);
			wire [31:0] early_vc3 = fmod(early_op3, mods[4], mods[5], fp_unit, pk_unit);
			wire [31:0] rf_vc3_0 = fmod(r_data[0 + l*32 +: 32], mods[4], mods[5], fp_unit, pk_unit);
			wire [31:0] rf_vc3_r = {(r_data[l*32 + 31] & ~b_clr31_3) ^ b_inv31_3, r_data[l*32 + 16 +: 15],
				(r_data[l*32 + 15] & ~b_clr15_3) ^ b_inv15_3, r_data[l*32 +: 15]};
			assign vc[l*32 +: 32] = (REG_IO != 0) ?
				(b_use_rf3 ? rf_vc3_r : b_early_vc[l*32 +: 32]) :
				(use_rf3 ? rf_vc3_0 : early_vc3);
		end
	endgenerate

	assign x_valid = b_valid;
	assign x_warp = b_warp;
	assign x_grp = b_grp;
	assign x_last = b_last;
	assign x_sbe = b_sbe;
	assign x_pc = b_pc;
	assign x_uop = (REG_IO != 0) ? b_uop : (b_uop | ({{(UOP_W-1){1'b0}}, b_pass} << (ATG_UOP_OP + ATG_TEX_PASS2)));
	assign x_a = va;
	assign x_b = vb;
	assign x_c = vc;
	assign x_mask = (REG_IO != 0) ? b_mask_r : {exec_g[NPHYS-1:0] & cov_g[NPHYS-1:0] & ~kill_g[NPHYS-1:0],
		exec_g[NPHYS-1:0]};
	assign x_info = (REG_IO != 0) ? b_info_r : {13'd0, b_q_info[ATG_WI_FRONT], b_q_info[ATG_WI_KIND +: 2],
		b_q_info[ATG_WI_SEQ +: 16]};

	wire unused_fwd_ex4 = &{1'b0,
		fwd_fpu_ex4_valid, fwd_fpu_ex4_warp, fwd_fpu_ex4_grp, fwd_fpu_ex4_rd, fwd_fpu_ex4_data, fwd_fpu_ex4_lanes,
		hit_fpu_ex4_1, hit_fpu_ex4_2, hit_fpu_ex4_3, a_cl_co_unused, a_mods[6]};
	wire unused_ok = &{1'b0, a_n1, a_n2[6], a_n3[6], a_rf_r1, a_rf_r2, a_wait, mods[6], exec_g, kill_g, cov_g, grp_base, b_q_info, unused_fwd_ex4, cl_co_unused};
endmodule

`default_nettype wire
