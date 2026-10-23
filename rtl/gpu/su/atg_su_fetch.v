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
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_fetch.md.
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
	 * instruction on ic_rvalid; the head leaves when it has its data. */
	reg [WARP_W-1:0] q_warp [0:1];
	reg [15:0] q_pc [0:1];
	reg [63:0] q_ins [0:1];
	reg [1:0] q_have;
	reg [1:0] wp, rp, fp;	/* request, read and fill pointers (mod 4, index bit 0) */
	wire [1:0] used = wp - rp;
	wire room = used != 2'd2;

	assign ic_req = f_valid && room;
	assign ic_addr = f_addr;
	assign f_ready = room && ic_ready;
	wire push = f_valid && f_ready;

	wire h = rp[0];
	assign d_valid = used != 2'd0 && q_have[h];
	assign d_warp = q_warp[h];
	assign d_pc = q_pc[h];
	assign d_instr = q_ins[h];
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
				wp <= wp + 2'd1;
			end
			if (ic_rvalid) begin
				q_ins[fp[0]] <= ic_rdata;
				q_have[fp[0]] <= 1'b1;
				fp <= fp + 2'd1;
			end
			if (pop)
				rp <= rp + 2'd1;
		end
	end
endmodule

`default_nettype wire
