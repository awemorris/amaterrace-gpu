/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_rf: The SU's register file: NWARPS × NREGS × 32 lanes × 32 bits
 * in block RAM, three copies for three reads per cycle (design §3.5), one
 * write port (from atg_su_wb), banked per physical lane.
 *
 * WS288 p023 stub: ports and parameters only, every output is 0.
 * The behaviour is specified in spec/gpu/su/atg_su_rf.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_rf #(
	parameter NPHYS = 8,	/* Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles) */
	parameter NWARPS = 4,	/* Resident warps (slots): 2, 4 or 8 */
	parameter WARP_W = 2,	/* log2(NWARPS) */
	parameter GRP_W = 2,	/* log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit) */
	parameter NREGS = 32	/* GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq) */
) (
	input wire clk,
	input wire rst_n,
	/* Write (from atg_su_wb) */
	input wire w_en,
	input wire [WARP_W-1:0] w_warp,
	input wire [GRP_W-1:0] w_grp,
	input wire [5:0] w_reg,
	input wire [NPHYS*32-1:0] w_data,
	input wire [NPHYS-1:0] w_lanes,
	/* Read (from atg_su_opd) */
	input wire r_en,
	input wire [WARP_W-1:0] r_warp,
	input wire [GRP_W-1:0] r_grp,
	input wire [5:0] r_reg1,
	input wire [5:0] r_reg2,
	input wire [5:0] r_reg3,
	output wire [NPHYS*32-1:0] r_data1,
	output wire [NPHYS*32-1:0] r_data2,
	output wire [NPHYS*32-1:0] r_data3
);
	/* spec/gpu/su/atg_su_rf.md */
	assign r_data1 = {(NPHYS*32){1'b0}};
	assign r_data2 = {(NPHYS*32){1'b0}};
	assign r_data3 = {(NPHYS*32){1'b0}};

	/* The stub reads none of its inputs. */
	wire unused_ok = &{1'b0,
		clk, rst_n, w_en, w_warp, w_grp, w_reg, w_data, w_lanes, r_en, r_warp, r_grp, r_reg1,
		r_reg2, r_reg3, (NWARPS != 0), (NREGS != 0)};
endmodule

`default_nettype wire
