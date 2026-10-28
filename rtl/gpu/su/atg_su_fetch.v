/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_fetch: Instruction fetch: takes a (warp, pc, address) from the
 * scheduler, reads the 64-bit instruction from the I$ and hands it to the
 * decoder.
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_fetch.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_fetch #(
	parameter WARP_W = 2	/* log2(NWARPS) */
) (
	input wire clk,
	input wire rst_n,
	/* From atg_su_sched */
	input wire f_valid,
	output wire f_ready,
	input wire [WARP_W-1:0] f_warp,
	input wire [15:0] f_pc,
	input wire [31:0] f_addr,
	/* I$ port (atg_su_icache) */
	output wire ic_req,
	input wire ic_ready,
	output wire [31:0] ic_addr,
	input wire ic_rvalid,
	input wire [63:0] ic_rdata,
	/* To atg_su_dec */
	output wire d_valid,
	input wire d_ready,
	output wire [WARP_W-1:0] d_warp,
	output wire [15:0] d_pc,
	output wire [63:0] d_instr
);
	/* Two in-flight fetches in order: {warp, pc} at request, the
	 * instruction on ic_rvalid; the head leaves when it has its data.
	 * Force slice registers to prevent Distributed RAM inference and cut 1.5ns decode delay. */
	(* ram_style = "registers" *) reg [WARP_W-1:0] q_warp [0:1];
	(* ram_style = "registers" *) reg [15:0] q_pc [0:1];
	(* ram_style = "registers" *) reg [63:0] q_ins [0:1];
	reg [1:0] q_have;
	(* keep = "true", max_fanout = 16 *) reg [1:0] rp;
	reg [1:0] wp, fp;	/* request, read and fill pointers (mod 4, index bit 0) */
	wire [1:0] used;
	wire [1:0] wp_next;
	wire [1:0] fp_next;
	wire [1:0] rp_next;
	wire us_bo_unused, wp_co_unused, fp_co_unused, rp_co_unused;
	am_sub #(.W(2)) u_used (.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(us_bo_unused));
	am_add #(.W(2)) u_wp (.a(wp), .b(2'd0), .ci(1'b1), .s(wp_next), .co(wp_co_unused));
	am_add #(.W(2)) u_fp (.a(fp), .b(2'd0), .ci(1'b1), .s(fp_next), .co(fp_co_unused));
	am_add #(.W(2)) u_rp (.a(rp), .b(2'd0), .ci(1'b1), .s(rp_next), .co(rp_co_unused));
	wire room = used != 2'd2;

	assign ic_req = f_valid && room;
	assign ic_addr = f_addr;
	assign f_ready = room && ic_ready;
	wire push = f_valid && f_ready;

	wire h = rp[0];
	assign d_valid = used != 2'd0 && q_have[h];
	assign d_warp = q_warp[h];
	assign d_pc = q_pc[h];
	(* keep = "true", max_fanout = 16 *) wire [63:0] w_d_instr = q_ins[h];
	assign d_instr = w_d_instr;
	wire pop = d_valid && d_ready;

	always @(posedge clk) begin
		if (!rst_n) begin
			wp <= 2'd0;
			rp <= 2'd0;
			fp <= 2'd0;
			q_have <= 2'b00;
		end else begin
			if (push) begin
				q_warp[wp[0]] <= f_warp;
				q_pc[wp[0]] <= f_pc;
				q_have[wp[0]] <= 1'b0;
				wp <= wp_next;
			end
			if (ic_rvalid) begin
				q_ins[fp[0]] <= ic_rdata;
				q_have[fp[0]] <= 1'b1;
				fp <= fp_next;
			end
			if (pop)
				rp <= rp_next;
		end
	end
endmodule

`default_nettype wire
