/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_exec: Warp control: EXEC and KILLED per warp, the
 * exec.set/and/or/save and kill instructions, warp-uniform branches
 * (bany/bnone/ball/j/bexnz/bexz), end and bar; tells the scheduler where
 * the warp continues.
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_exec.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_exec #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter SBE_W = 2,	/* log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits) */
	parameter UOP_W = 108,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
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
	output wire [NPHYS-1:0] s_lanes,
	/* Warp control (to atg_su_sched) */
	output wire wc_valid,
	output wire [WARP_W-1:0] wc_warp,
	output wire [1:0] wc_op,
	output wire [15:0] wc_pc,
	/* EXEC state */
	input wire [WARP_W-1:0] q_warp,
	output wire [31:0] q_exec,
	output wire [31:0] q_killed,
	input wire init_valid,
	input wire [WARP_W-1:0] init_warp,
	input wire [31:0] init_mask
);
`include "atg_su_uop.vh"

	localparam DW = NPHYS * 32;
	localparam EW = 1 + WARP_W + GRP_W + 7 + NPHYS + DW;

	reg [NWARPS*32-1:0] exec_r, kill_r;
	wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXEC;
	wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	wire [NPHYS-1:0] em = x_mask[NPHYS-1:0];
	wire [31:0] lane0 = {{(32-GRP_W){1'b0}}, x_grp} * NPHYS;
	wire [31:0] wexec = exec_r[x_warp*32 +: 32];

	/* Per lane: the Boolean of rs1. */
	reg [NPHYS-1:0] bt;
	integer l;
	always @(*)
		for (l = 0; l < NPHYS; l = l + 1)
			bt[l] = x_a[l*32 +: 32] != 32'd0;
	/* The group's bits in the warp's 32: the Booleans, the group's mask, and EXEC's bits of the group. */
	wire [31:0] bt_w;
	wire [31:0] gmask;
	wire [31:0] wexec_g;
	am_shift #(.W(32), .SW(6)) u_bt_w (.a({{(32-NPHYS){1'b0}}, bt}), .amt(lane0[5:0]), .left(1'b1),
		.arith(1'b0), .y(bt_w));
	am_shift #(.W(32), .SW(6)) u_gmask (.a({{(32-NPHYS){1'b0}}, {NPHYS{1'b1}}}), .amt(lane0[5:0]),
		.left(1'b1), .arith(1'b0), .y(gmask));
	am_shift #(.W(32), .SW(5)) u_wexec_g (.a(wexec), .amt(lane0[4:0]), .left(1'b0), .arith(1'b0),
		.y(wexec_g));

	/* Branch conditions over the groups of one instruction. */
	reg acc_any, acc_all;
	wire any_now = acc_any || |(bt & em);
	wire all_now = acc_all && &(bt | ~em);
	reg take;
	always @(*) begin
		case (op)
		ATG_EXEC_BANY: take = any_now;
		ATG_EXEC_BNONE: take = !any_now;
		ATG_EXEC_BALL: take = all_now;
		ATG_EXEC_J: take = 1'b1;
		ATG_EXEC_BEXNZ: take = wexec != 32'd0;
		default: take = wexec == 32'd0;	/* BEXZ */
		endcase
	end
	wire is_br = op <= ATG_EXEC_BEXZ;

	/* exec.save: each lane's EXEC bit as a Boolean, written to every lane. */
	reg [DW-1:0] save_d;
	always @(*)
		for (l = 0; l < NPHYS; l = l + 1)
			save_d[l*32 +: 32] = {32{wexec_g[l]}};
	wire s_in = mine && op == ATG_EXEC_SAVE && x_uop[ATG_UOP_WRD];

	/* The next PC: the branch target or PC + 1. */
	wire [15:0] pc_next;
	wire pc_co_unused;
	am_add #(.W(16)) u_pc (.a(x_pc), .b(is_br && take ? imm[15:0] : 16'd1), .ci(1'b0), .s(pc_next),
		.co(pc_co_unused));

	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	reg wc_v;
	reg [WARP_W-1:0] wc_w;
	reg [1:0] wc_o;
	reg [15:0] wc_p;
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			exec_r <= {(NWARPS*32){1'b0}};
			kill_r <= {(NWARPS*32){1'b0}};
			acc_any <= 1'b0;
			acc_all <= 1'b1;
			wc_v <= 1'b0;
			wc_w <= {WARP_W{1'b0}};
			wc_o <= 2'd0;
			wc_p <= 16'd0;
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {s_in, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], {NPHYS{1'b1}}, save_d};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
			wc_v <= 1'b0;
			if (mine) begin
				case (op)
				ATG_EXEC_SET: exec_r[x_warp*32 +: 32] <= (wexec & ~gmask) | bt_w;
				ATG_EXEC_AND: exec_r[x_warp*32 +: 32] <= wexec & (~gmask | bt_w);
				ATG_EXEC_OR: exec_r[x_warp*32 +: 32] <= wexec | bt_w;
				ATG_EXEC_KILL: kill_r[x_warp*32 +: 32] <= kill_r[x_warp*32 +: 32] |
					(bt_w & wexec);
				default: ;
				endcase
				if (x_last) begin
					acc_any <= 1'b0;
					acc_all <= 1'b1;
					if (is_br || op == ATG_EXEC_END || op == ATG_EXEC_BAR) begin
						wc_v <= 1'b1;
						wc_w <= x_warp;
						wc_o <= op == ATG_EXEC_END ? 2'd1 : op == ATG_EXEC_BAR ? 2'd2 :
							2'd0;
						wc_p <= pc_next;
					end
				end else begin
					acc_any <= any_now;
					acc_all <= all_now;
				end
			end
			if (init_valid) begin
				exec_r[init_warp*32 +: 32] <= init_mask;
				kill_r[init_warp*32 +: 32] <= 32'd0;
			end
		end
	end

	assign wc_valid = wc_v;
	assign wc_warp = wc_w;
	assign wc_op = wc_o;
	assign wc_pc = wc_p;
	assign q_exec = exec_r[q_warp*32 +: 32];
	assign q_killed = kill_r[q_warp*32 +: 32];

	wire [EW-1:0] o = pipe[SHORT_LAT-1];
	assign s_valid = o[EW-1];
	assign s_warp = o[EW-2 -: WARP_W];
	assign s_grp = o[EW-2-WARP_W -: GRP_W];
	assign s_rd = o[EW-2-WARP_W-GRP_W -: 7];
	assign s_lanes = o[DW +: NPHYS];
	assign s_data = o[DW-1:0];
	assign x_ready = 1'b1;

	wire unused_ok = &{1'b0, x_sbe, x_b, x_c, x_mask[2*NPHYS-1:NPHYS], x_info, x_uop,
		imm[31:16], lane0};
endmodule

`default_nettype wire
