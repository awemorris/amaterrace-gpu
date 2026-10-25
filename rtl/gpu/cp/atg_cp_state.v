/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cp_state: the state register file STATE[0..767] (0x000-0x2FF;
 * 0x200-0x2FF the vertex stage's texture slots, CAPS[30]): written through
 * the host alias and the sequencer's µops, broadcast to the blocks (st_*),
 * read back by the host and by the CP's CPU.
 *
 * The RAM is held twice (two copies with the same writes): copy A answers
 * the host alias, copy B the CPU port and the replay.  A host write is
 * taken only when open and not to the BLT range (0x000-0x01F) while the
 * BLT is busy; otherwise it is dropped and lock_fault pulses.  A µop write
 * is always taken and wins over a host write in the same cycle (which is
 * then refused with lock_fault).
 *
 * Replay (the RESET order, design §2.6: STATE survives RESET, the blocks'
 * copies do not): a replay pulse broadcasts STATE[0..767] on st_* again,
 * one word per cycle, from the second cycle after the pulse; replay_busy
 * is 1 for 769 cycles from the cycle after the pulse.  Indices are 10
 * bits; the callers send none above 0x2FF (a read there answers an
 * undefined word).  During a replay
 * the CPU port's answer is undefined (the CPU is held in RESETTING).  The
 * RAM itself is never reset.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cp_state (
	input wire clk,
	input wire rst_n,
	/* Host alias (from atg_cp_regs) */
	input wire alias_we,
	input wire [9:0] alias_idx,
	input wire [31:0] alias_wdata,
	input wire [9:0] alias_ridx,
	output wire [31:0] alias_rdata,
	/* SET_REG and µop payloads (from atg_cp_seq) */
	input wire uop_we,
	input wire [9:0] uop_idx,
	input wire [31:0] uop_wdata,
	/* Locks (from atg_cp_ctl and the blocks) */
	input wire open,
	input wire blt_busy,
	output wire lock_fault,
	/* Broadcast to the blocks */
	output wire st_we,
	output wire [9:0] st_idx,
	output wire [31:0] st_wdata,
	/* CPU read port (atg_cpu window) */
	input wire [9:0] cpu_ridx,
	output wire [31:0] cpu_rdata,
	/* Replay after RESET (from atg_cp_ctl) */
	input wire replay,
	output wire replay_busy
);
	`include "ghci_regs.vh"
	reg [31:0] mem_a [0:767];
	reg [31:0] mem_b [0:767];
	reg [31:0] a_q;
	reg [31:0] b_q;

	wire host_locked = !open || (alias_idx < {1'b0, GHCI_S_VF} && blt_busy);
	wire host_take = alias_we && !host_locked && !uop_we;
	assign lock_fault = alias_we && !host_take;

	wire w = uop_we || host_take;
	wire [9:0] widx = uop_we ? uop_idx : alias_idx;
	wire [31:0] wdata = uop_we ? uop_wdata : alias_wdata;

	/* The replay: rp_rd reads word rp_idx, the next cycle broadcasts it. */
	reg rp_rd;
	reg rp_out;
	reg [9:0] rp_idx;
	wire [9:0] rp_idx_n;	/* rp_idx + 1 */
	wire rp_co;

	am_add #(.W(10)) rp_add (.a(rp_idx), .b(10'd0), .ci(1'b1), .s(rp_idx_n), .co(rp_co));
	reg [9:0] rp_oidx;

	always @(posedge clk) begin
		if (!rst_n) begin
			rp_rd <= 1'b0;
			rp_out <= 1'b0;
			rp_idx <= 10'd0;
			rp_oidx <= 10'd0;
		end else begin
			rp_out <= rp_rd;
			rp_oidx <= rp_idx;
			if (replay) begin
				rp_rd <= 1'b1;
				rp_idx <= 10'd0;
			end else if (rp_rd) begin
				if (rp_idx == 10'h2FF)
					rp_rd <= 1'b0;
				rp_idx <= rp_idx_n;
			end
		end
	end

	assign replay_busy = rp_rd || rp_out;

	always @(posedge clk) begin
		if (w) begin
			mem_a[widx] <= wdata;
			mem_b[widx] <= wdata;
		end
		a_q <= mem_a[alias_ridx];
		b_q <= mem_b[rp_rd ? rp_idx : cpu_ridx];
	end

	assign alias_rdata = a_q;
	assign cpu_rdata = b_q;

	assign st_we = w || rp_out;
	assign st_idx = w ? widx : rp_oidx;
	assign st_wdata = w ? wdata : b_q;
	wire unused_rp = &{1'b0, rp_co};
endmodule

`default_nettype wire
