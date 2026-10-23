/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_sync: a two-flop synchroniser for W independent level signals that
 * change slowly relative to clk (resets, enables, status bits).  A bus whose
 * bits must arrive together does not go through here: it goes through
 * am_afifo or a handshake.  The output resets to RESET_VALUE.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_sync #(
	parameter W = 1,
	parameter [W-1:0] RESET_VALUE = {W{1'b0}}
) (
	input wire clk,
	input wire rst_n,
	input wire [W-1:0] d,
	output wire [W-1:0] q
);
	(* ASYNC_REG = "TRUE" *) reg [W-1:0] s1;
	(* ASYNC_REG = "TRUE" *) reg [W-1:0] s2;

	assign q = s2;

	always @(posedge clk) begin
		if (!rst_n) begin
			s1 <= RESET_VALUE;
			s2 <= RESET_VALUE;
		end else begin
			s1 <= d;
			s2 <= s1;
		end
	end
endmodule

`default_nettype wire
