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
	wire [31:0] wexec = exec_r[x_warp*32 +: 32];

	/* Direct group demux/mux for NPHYS-aligned operations (eliminates 3 generic barrel shifters) */
	reg [31:0] bt_w;
	reg [31:0] gmask;
	reg [NPHYS-1:0] wexec_g;
	integer gi;
	always @(*) begin
		bt_w = 32'd0;
		gmask = 32'd0;
		wexec_g = {NPHYS{1'b0}};
		for (gi = 0; gi < 32/NPHYS; gi = gi + 1) begin
			if (x_grp == gi[GRP_W-1:0]) begin
				bt_w[gi*NPHYS +: NPHYS] = bt;
				gmask[gi*NPHYS +: NPHYS] = {NPHYS{1'b1}};
				wexec_g = wexec[gi*NPHYS +: NPHYS];
			end
		end
	end

	/* Use local wexec_g directly, eliminating exec -> opd -> exec loop */
	wire [NPHYS-1:0] em = wexec_g;

	/* Per lane: the Boolean of rs1 (balanced 16-bit reduction). */
	wire [NPHYS-1:0] bt;
	genvar gl;
	generate
		for (gl = 0; gl < NPHYS; gl = gl + 1) begin : g_bt
			wire bt_hi = |x_a[gl*32 + 16 +: 16];
			wire bt_lo = |x_a[gl*32 +: 16];
			assign bt[gl] = bt_hi | bt_lo;
		end
	endgenerate

	/* Branch conditions over the groups of one instruction. */
	reg acc_any, acc_all;
	wire any_now = acc_any || |(bt & em);
	wire all_now = acc_all && &(bt | ~em);
	wire is_br = op <= ATG_EXEC_BEXZ;
	wire br_uses_all = op == ATG_EXEC_BALL;
	wire br_static_take = (op == ATG_EXEC_J) ||
	                      (op == ATG_EXEC_BEXNZ && wexec != 32'd0) ||
	                      (op == ATG_EXEC_BEXZ && wexec == 32'd0);
	wire take_cond = (br_uses_all && all_now) ||
	                 (op == ATG_EXEC_BANY && any_now) ||
	                 (op == ATG_EXEC_BNONE && !any_now);
	wire take = br_static_take || take_cond;

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

	reg [EW-1:0] pipe [0:SHORT_LAT-1];
	reg wc_v;
	reg [WARP_W-1:0] wc_w;
	reg [1:0] wc_o;
	reg wc_take;
	reg [15:0] wc_pc_tgt, wc_pc_p1;
	integer k;
	always @(posedge clk) begin
		if (!rst_n) begin
			wc_v <= 1'b0;
			wc_w <= {WARP_W{1'b0}};
			wc_o <= 2'd0;
			wc_take <= 1'b0;
			wc_pc_tgt <= 16'd0;
			wc_pc_p1 <= 16'd0;
			for (k = 0; k < SHORT_LAT; k = k + 1)
				pipe[k] <= {EW{1'b0}};
		end else begin
			pipe[0] <= {s_in, x_warp, x_grp, x_uop[ATG_UOP_RD +: 7], {NPHYS{1'b1}}, save_d};
			for (k = 1; k < SHORT_LAT; k = k + 1)
				pipe[k] <= pipe[k-1];
			wc_v <= 1'b0;
			if (mine) begin
				if (x_last) begin
					if (is_br || op == ATG_EXEC_END || op == ATG_EXEC_BAR) begin
						wc_v <= 1'b1;
						wc_w <= x_warp;
						wc_o <= op == ATG_EXEC_END ? 2'd1 : op == ATG_EXEC_BAR ? 2'd2 :
							2'd0;
						wc_take <= is_br && take;
						wc_pc_tgt <= pc_tgt;
						wc_pc_p1 <= pc_p1;
					end
				end
			end
		end
	end

	genvar gw;
	generate
		for (gw = 0; gw < NWARPS; gw = gw + 1) begin : g_warp_state
			wire w_match = mine && (x_warp == gw[WARP_W-1:0]);
			wire w_init = init_valid && (init_warp == gw[WARP_W-1:0]);

			wire kill_ce = w_init || (w_match && op == ATG_EXEC_KILL);
			wire [31:0] kill_d = w_init ? 32'd0 : (kill_r[gw*32 +: 32] | (bt_w & wexec));

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					kill_r[gw*32 +: 32] <= 32'd0;
				else if (kill_ce)
					kill_r[gw*32 +: 32] <= kill_d;
			end

			wire exec_op_match = (op == ATG_EXEC_SET || op == ATG_EXEC_AND || op == ATG_EXEC_OR);
			wire exec_ce = w_init || (w_match && exec_op_match);
			reg [31:0] exec_d;
			always @(*) begin
				if (w_init)
					exec_d = init_mask;
				else case (op)
					ATG_EXEC_SET: exec_d = (wexec & ~gmask) | bt_w;
					ATG_EXEC_AND: exec_d = wexec & (~gmask | bt_w);
					ATG_EXEC_OR:  exec_d = wexec | bt_w;
					default:      exec_d = wexec;
				endcase
			end

			always @(posedge clk or negedge rst_n) begin
				if (!rst_n)
					exec_r[gw*32 +: 32] <= 32'd0;
				else if (exec_ce)
					exec_r[gw*32 +: 32] <= exec_d;
			end
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
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
