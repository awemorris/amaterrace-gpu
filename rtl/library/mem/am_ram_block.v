/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_ram_block: Simple Dual-Port synchronous Block RAM with explicit
 * clock enable and write enable controls.
 *
 * Port A: Synchronous Write (clk, ena, wea, addra, dina).
 * Port B: Synchronous Read with registered output (clk, enb, addrb, doutb).
 * Read latency is 1 clock cycle.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_ram_block #(
	parameter W = 32,
	parameter ADDR_W = 8,
	parameter DEPTH = 1 << ADDR_W
) (
	input wire clk,
	/* Port A: Write */
	input wire ena,
	input wire wea,
	input wire [ADDR_W-1:0] addra,
	input wire [W-1:0] dina,
	/* Port B: Read */
	input wire enb,
	input wire [ADDR_W-1:0] addrb,
	output reg [W-1:0] doutb
);
`ifdef SYNTH_KINTEX7
	(* ram_style = "block" *)
	/* synthesis syn_ramstyle = "block" */
`else
	(* ram_style = "block" *)
`endif
	reg [W-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (ena) begin
			if (wea)
				mem[addra] <= dina;
		end
	end

	always @(posedge clk) begin
		if (enb)
			doutb <= mem[addrb];
	end
endmodule

`default_nettype wire
