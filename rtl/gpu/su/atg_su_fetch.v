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
	/* spec/gpu/su/atg_su_fetch.md */
	assign f_ready = 1'd0;
	assign ic_req = 1'd0;
	assign ic_addr = 32'd0;
	assign d_valid = 1'd0;
	assign d_warp = {WARP_W{1'b0}};
	assign d_pc = 16'd0;
	assign d_instr = 64'd0;

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, f_valid, f_warp, f_pc, f_addr, ic_ready, ic_rvalid, ic_rdata, d_ready};
endmodule

`default_nettype wire
