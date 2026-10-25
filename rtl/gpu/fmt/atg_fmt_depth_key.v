/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_fmt_depth_key: an fp32 order key, a 33-bit signed value that orders
 * as the fp32 does (−0 = +0, denormals are 0; the former atg_depth_key of
 * include/atg_depth.vh).  Shared by the ROP's depth test and the TU's
 * compare samplers (atg_tu_fpre).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_depth_key (
	input wire [31:0] f,
	output wire [32:0] k
);
	/* The magnitude, negated for a negative value. */
	wire [32:0] sm;
	wire sm_co_unused;
	am_addsub #(.W(33)) u_sm (.a(33'd0), .b({2'b00, f[30:0]}), .sub(f[31]), .s(sm), .co(sm_co_unused));

	assign k = f[30:23] == 8'd0 ? 33'd0 : sm;
endmodule

`default_nettype wire
