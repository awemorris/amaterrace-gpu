/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_dec: Decodes a 64-bit GSI1 instruction (design §3.3, §3.4) into
 * the SU micro-op of include/atg_su_uop.vh: unit, operation, operand
 * numbers (7 bits), immediate, modifiers, latency class, destination
 * count, and the ISA-fault flag.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_dec.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_dec #(
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter UOP_W = 104,	/* Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh) */
	parameter NREGS = 32,	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
	parameter PACKED = 0,	/* 16-bit packed arithmetic present (else those opcodes are ISA faults; packh/unpackh always present) */
	parameter SUBGROUP = 0,	/* shfl/vote/ballot present (CAPS[24]) */
	parameter HAS_SA = 0	/* rq/sactl/qstat/sastat/qtag usable (always 0 in v1) */
) (
	input wire clk,
	input wire rst_n,
	input wire d_valid,
	output wire d_ready,
	input wire [WARP_W-1:0] d_warp,
	input wire [15:0] d_pc,
	input wire [63:0] d_instr,
	output wire u_valid,
	input wire u_ready,
	output wire [WARP_W-1:0] u_warp,
	output wire [15:0] u_pc,
	output wire [UOP_W-1:0] u_uop
);
	/* spec/gpu/su/atg_su_dec.md */
	assign d_ready = 1'd0;
	assign u_valid = 1'd0;
	assign u_warp = {WARP_W{1'b0}};
	assign u_pc = 16'd0;
	assign u_uop = {UOP_W{1'b0}};

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, d_valid, d_warp, d_pc, d_instr, u_ready, (NREGS != 0), (PACKED != 0),
		(SUBGROUP != 0), (HAS_SA != 0)};
endmodule

`default_nettype wire
