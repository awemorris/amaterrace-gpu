/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rq: The reserved rq port (operand 63) and sactl to a systolic
 * array (design §3.9); with HAS_SA it would hold the push/pop FIFO ends.
 *
 * Reserved (v1 has no SA; deferred with atg_sa): a port-only placeholder,
 * every output is 0 (rq neither empty nor full, nothing
 * pushed, popped or sent to the SA).  The intended behaviour:
 * spec/gpu/su/atg_su_rq.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rq #(
	parameter NPHYS = 8,	/* Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter HAS_SA = 0	/* An SA is attached (v1: 0) */
) (
	input wire clk,
	input wire rst_n,
	/* SU side */
	input wire pop,
	output wire [NPHYS*32-1:0] pop_data,
	input wire push,
	input wire [NPHYS*32-1:0] push_data,
	output wire empty,
	output wire full,
	input wire ctl_valid,
	input wire [31:0] ctl_data,
	/* SA side (atg_su ports sa_*, to atg_sa) */
	output wire sa_push_valid,
	input wire sa_push_ready,
	output wire [NPHYS*32-1:0] sa_push_data,
	input wire sa_pop_valid,
	output wire sa_pop_ready,
	input wire [NPHYS*32-1:0] sa_pop_data,
	output wire sa_ctl_valid,
	output wire [31:0] sa_ctl_data,
	input wire [31:0] sa_qstat,
	input wire [31:0] sa_stat,
	input wire [31:0] sa_qtag
);
	/* spec/gpu/su/atg_su_rq.md */
	assign pop_data = {(NPHYS*32){1'b0}};
	assign empty = 1'd0;
	assign full = 1'd0;
	assign sa_push_valid = 1'd0;
	assign sa_push_data = {(NPHYS*32){1'b0}};
	assign sa_pop_ready = 1'd0;
	assign sa_ctl_valid = 1'd0;
	assign sa_ctl_data = 32'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, pop, push, push_data, ctl_valid, ctl_data, sa_push_ready, sa_pop_valid,
		sa_pop_data, sa_qstat, sa_stat, sa_qtag, (UOP_W != 0), (HAS_SA != 0)};
endmodule

`default_nettype wire
