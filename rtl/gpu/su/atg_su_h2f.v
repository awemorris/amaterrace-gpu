/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_h2f: fp16 to fp32 (exact), denormals flushed, NaN 0x7FC00000
 * (the former function atg_su_h2f of include/atg_su_fp16.vh;
 * tools/gsi1fp.py).  Combinational.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_h2f (
	input wire [15:0] h,
	output wire [31:0] f
);
	wire [7:0] e;
	wire e_co_unused;
	am_add #(.W(8)) u_e (.a({3'd0, h[14:10]}), .b(8'd112), .ci(1'b0), .s(e), .co(e_co_unused));
	assign f = h[14:10] == 5'h1F ? (h[9:0] != 10'd0 ? 32'h7FC00000 : {h[15], 8'hFF, 23'd0}) :
		h[14:10] == 5'd0 ? {h[15], 31'd0} : {h[15], e, h[9:0], 13'd0};
endmodule

`default_nettype wire
