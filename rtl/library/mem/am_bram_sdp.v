/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_bram_sdp: Simple Dual-Port synchronous Block RAM.
 *
 * Dedicated dual-port Block RAM (RAMB18E1 / RAMB36E1 on 7-series).
 * Port A: Synchronous Write (clk, we, waddr, wdata).
 * Port B: Synchronous Read with registered output (clk, re, raddr, rdata).
 * Read latency is 1 clock cycle.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_bram_sdp #(
	parameter W = 32,
	parameter ADDR_W = 8
) (
	input wire clk,
	/* Port A (Write) */
	input wire we,
	input wire [ADDR_W-1:0] waddr,
	input wire [W-1:0] wdata,
	/* Port B (Read) */
	input wire re,
	input wire [ADDR_W-1:0] raddr,
	output reg [W-1:0] rdata
);
	localparam DEPTH = 1 << ADDR_W;

	(* ram_style = "block" *) reg [W-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (we)
			mem[waddr] <= wdata;
	end

	always @(posedge clk) begin
		if (re)
			rdata <= mem[raddr];
	end
endmodule

`default_nettype wire
