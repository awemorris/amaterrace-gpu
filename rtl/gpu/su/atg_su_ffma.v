/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_ffma: fused a * b + c with one rounding under rm, with its own
 * 24 x 24 multiplier of the significands (atg_su_ffma_p takes the
 * product); noc: no addend.  The former function atg_su_ffma of
 * include/atg_su_fp.vh (tools/gsi1fp.py).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_ffma (
	input wire [31:0] a0,
	input wire [31:0] b0,
	input wire [31:0] c0,
	input wire [2:0] rm,
	input wire noc,
	output wire [31:0] r
);
	/* the significands {!z, m} of the flushed operands (atg_su_fsig) */
	wire [23:0] ma = a0[30:23] != 8'd0 ? {1'b1, a0[22:0]} : 24'd0;
	wire [23:0] mb = b0[30:23] != 8'd0 ? {1'b1, b0[22:0]} : 24'd0;
	wire [47:0] pp;
	am_mul #(.AW(24), .BW(24)) u_pp (.clk(1'b0), .en(1'b1), .a(ma), .b(mb), .p(pp));
	atg_su_ffma_p u_f (.a0(a0), .b0(b0), .c0(c0), .rm(rm), .noc(noc), .p(pp), .r(r));
endmodule

`default_nettype wire
