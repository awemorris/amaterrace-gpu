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

	wire [NWARPS*32-1:0] exec_r, kill_r;
	(* max_fanout = 12 *) wire mine = x_valid && x_uop[ATG_UOP_UNIT +: 4] == ATG_UNIT_EXEC;
	(* max_fanout = 12 *) wire [7:0] op = x_uop[ATG_UOP_OP +: 8];
	wire [31:0] imm = x_uop[ATG_UOP_IMM +: 32];
	(* max_fanout = 12 *) wire [31:0] wexec = exec_r[x_warp*32 +: 32];

	/* Direct group mux for NPHYS-aligned operations */
	(* max_fanout = 12 *) reg [NPHYS-1:0] wexec_g;
	integer gi;
	always @(*) begin
		wexec_g = {NPHYS{1'b0}};
		for (gi = 0; gi < 32/NPHYS; gi = gi + 1) begin
			if (x_grp == gi[GRP_W-1:0]) begin
				wexec_g = wexec[gi*NPHYS +: NPHYS];
			end
		end
	end

	/* Use local wexec_g directly, eliminating exec -> opd -> exec loop */
	wire [NPHYS-1:0] em = wexec_g;

	/* Per lane: the Boolean of rs1 (balanced 16-bit reduction). */
	(* max_fanout = 12 *) wire [NPHYS-1:0] bt;
	genvar gl;
	generate
		for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_bt
			wire bt_hi = |x_a[gl*32 + 16 +: 16];
			wire bt_lo = |x_a[gl*32 +: 16];
			assign bt[gl] = bt_hi | bt_lo;
		end
	endgenerate

	/* Branch conditions over the groups of one instruction. */
	(* max_fanout = 12 *) reg acc_any, acc_all;
	wire any_now = acc_any || |(bt & em);
	wire all_now = acc_all && &(bt | ~em);
	wire is_br = op <= ATG_EXEC_BEXZ;
	wire br_static_take = (op == ATG_EXEC_J) ||
	                      (op == ATG_EXEC_BEXNZ && wexec != 32'd0) ||
	                      (op == ATG_EXEC_BEXZ && wexec == 32'd0);

	/* exec.save: each lane's EXEC bit as a Boolean, written to every lane. */
	reg [DW-1:0] save_d;
	integer l;
	always @(*)
		for (l = 0; l < NPHYS; l = l + 1)
			save_d[l*32 +: 32] = {32{wexec_g[l]}};
	wire s_in = mine && op == ATG_EXEC_SAVE && x_uop[ATG_UOP_WRD];

	/* The next PC: parallel precomputation of branch target and PC + 1 */
	wire [15:0] pc_p1, pc_tgt;
	wire [1:0] pc_co_unused;
	am_add #(.W(16)) u_pc_p1 (.a(x_pc), .b(16'd1), .ci(1'b0), .s(pc_p1), .co(pc_co_unused[0]));
	am_add #(.W(16)) u_pc_tgt (.a(x_pc), .b(imm[15:0]), .ci(1'b0), .s(pc_tgt), .co(pc_co_unused[1]));

	(* shreg_extract = "no", max_fanout = 12 *) reg [EW-1:0] pipe [0:SHORT_LAT-1];
	(* max_fanout = 12 *) reg wc_v;
	(* max_fanout = 12 *) reg [WARP_W-1:0] wc_w;
	(* max_fanout = 12 *) reg [1:0] wc_o;
	(* max_fanout = 12 *) reg wc_is_br, wc_static, wc_any, wc_all;
	(* max_fanout = 12 *) reg [2:0] wc_br_op;
	(* max_fanout = 12 *) reg [15:0] wc_pc_tgt, wc_pc_p1;
	(* dont_touch = "true" *) wire rst_p = !rst_n;
	(* dont_touch = "true" *) wire wc_ce_ctrl = mine && x_last && (is_br || op == ATG_EXEC_END || op == ATG_EXEC_BAR);
	(* dont_touch = "true" *) wire wc_ce_tgt  = mine && x_last && (is_br || op == ATG_EXEC_END || op == ATG_EXEC_BAR);
	(* dont_touch = "true" *) wire wc_ce_p1   = mine && x_last && (is_br || op == ATG_EXEC_END || op == ATG_EXEC_BAR);
	integer k;
	always @(posedge clk) begin
		if (rst_p) begin
			wc_v <= 1'b0;
			wc_w <= {WARP_W{1'b0}};
			wc_o <= 2'd0;
			wc_is_br <= 1'b0;
			wc_static <= 1'b0;
			wc_any <= 1'b0;
			wc_all <= 1'b0;
			wc_br_op <= 3'd0;
			wc_pc_tgt <= 16'd0;
			wc_pc_p1 <= 16'd0;
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k][EW-1] <= 1'b0;
		end else begin
			wc_v <= wc_ce_ctrl;
			if (wc_ce_ctrl) begin
				wc_w <= x_warp;
				wc_o <= op == ATG_EXEC_END ? 2'd1 : op == ATG_EXEC_BAR ? 2'd2 : 2'd0;
				wc_is_br <= is_br;
				wc_static <= br_static_take;
				wc_any <= any_now;
				wc_all <= all_now;
				wc_br_op <= op[2:0];
			end
			pipe[0][EW-1] <= s_in;
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k][EW-1] <= pipe[k-1][EW-1];
			if (wc_ce_tgt)
				wc_pc_tgt <= pc_tgt;
			if (wc_ce_p1)
				wc_pc_p1 <= pc_p1;
		end
		pipe[0][EW-2:0] <= {x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], {NPHYS{1'b1}}, save_d};
		for (k = 1; k < SHORT_LAT; k = k + 1)
			pipe[k][EW-2:0] <= pipe[k-1][EW-2:0];
	end

	(* keep = "true", max_fanout = 16 *) wire wc_take = wc_is_br && (wc_static ||
	                            (wc_br_op == ATG_EXEC_BALL[2:0] && wc_all) ||
	                            (wc_br_op == ATG_EXEC_BANY[2:0] && wc_any) ||
	                            (wc_br_op == ATG_EXEC_BNONE[2:0] && !wc_any));

	genvar gw, gg;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_warp_state
			wire w_match = mine && (x_warp == gw[WARP_W-1:0]);
			wire exec_op_match = (op == ATG_EXEC_SET || op == ATG_EXEC_AND || op == ATG_EXEC_OR);

			for (gg = 0; gg < 32/NPHYS; gg = gg + 1) begin : g_grp_state
				(* dont_touch = "true" *) wire w_init_kl = init_valid && (init_warp == gw[WARP_W-1:0]);
				(* dont_touch = "true" *) wire w_init_ex = init_valid && (init_warp == gw[WARP_W-1:0]);
				wire g_match = w_match && (x_grp == gg[GRP_W-1:0]);
				(* dont_touch = "true" *) wire kill_ce = w_init_kl || (g_match && op == ATG_EXEC_KILL);
				(* max_fanout = 12 *) reg [NPHYS-1:0] exec_sl_r, kill_sl_r;
				wire [NPHYS-1:0] cur_exec = exec_sl_r;
				wire [NPHYS-1:0] cur_kill = kill_sl_r;
				wire [NPHYS-1:0] kill_d = w_init_kl ? {NPHYS{1'b0}} : (cur_kill | (bt & cur_exec));

				always @(posedge clk) begin
					if (rst_p)
						kill_sl_r <= {NPHYS{1'b0}};
					else if (kill_ce)
						kill_sl_r <= kill_d;
				end

				(* dont_touch = "true" *) wire exec_ce = w_init_ex || (g_match && exec_op_match);
				reg [NPHYS-1:0] exec_d;
				always @(*) begin
					if (w_init_ex)
						exec_d = init_mask[gg*NPHYS +: NPHYS];
					else case (op[1:0])
						ATG_EXEC_SET[1:0]: exec_d = bt;
						ATG_EXEC_AND[1:0]: exec_d = cur_exec & bt;
						default:           exec_d = cur_exec | bt;
					endcase
				end

				always @(posedge clk) begin
					if (rst_p)
						exec_sl_r <= {NPHYS{1'b0}};
					else if (exec_ce)
						exec_sl_r <= exec_d;
				end
				assign exec_r[gw*32 + gg*NPHYS +: NPHYS] = exec_sl_r;
				assign kill_r[gw*32 + gg*NPHYS +: NPHYS] = kill_sl_r;
			end
		end
	endgenerate

	always @(posedge clk) begin
		if (rst_p) begin
			acc_any <= 1'b0;
			acc_all <= 1'b1;
		end else if (mine) begin
			acc_any <= x_last ? 1'b0 : any_now;
			acc_all <= x_last ? 1'b1 : all_now;
		end
	end

	assign wc_valid = wc_v;
	assign wc_warp = wc_w;
	assign wc_op = wc_o;
	assign wc_pc = wc_take ? wc_pc_tgt : wc_pc_p1;
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

	wire unused_ok = &{1'b0, x_sbe, x_b, x_c, x_mask, x_info, x_uop,
		imm[31:16], pc_co_unused};
endmodule

`default_nettype wire
