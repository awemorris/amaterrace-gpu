/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_scrub: the address counter of a shader unit memory's scrub
 * (session protection, spec/gpu/su/atg_su_scrub.md): start for one cycle
 * makes on 1 for DEPTH cycles with a = 0, 1, ..., DEPTH - 1, one address
 * per cycle; the memory writes 0 at a through its own write port while
 * on.  A start while on starts again from 0.  rst_n stops it.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_scrub #(
	parameter DEPTH = 16,
	parameter AW = 4	/* clog2(DEPTH), at least 1 */
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	output reg on,
	output reg [AW-1:0] a
);
	wire [AW-1:0] a_next;
	wire a_co_unused;
	am_add #(.W(AW)) u_a (.a(a), .b({AW{1'b0}}), .ci(1'b1), .s(a_next), .co(a_co_unused));

	always @(posedge clk) begin
		if (!rst_n) begin
			on <= 1'b0;
			a <= {AW{1'b0}};
		end else if (start) begin
			on <= 1'b1;
			a <= {AW{1'b0}};
		end else if (on) begin
			if ({{(32-AW){1'b0}}, a} == DEPTH - 1)
				on <= 1'b0;
			else
				a <= a_next;
		end
	end
endmodule

`default_nettype wire
