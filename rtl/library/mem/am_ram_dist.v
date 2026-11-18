/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_ram_dist: Distributed RAM (LUTRAM on FPGA / Register File on ASIC).
 *
 * Synchronous write, asynchronous (PIPE = 0) or registered (PIPE = 1) read.
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE, explicitly mapped to FPGA distributed RAM (SLICEM LUTRAM).
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_ram_dist #(
	parameter W = 32,
	parameter ADDR_W = 5,
	parameter DEPTH = 1 << ADDR_W,
	parameter PIPE = 0	/* 0: combinational asynchronous read, 1: registered read */
) (
	input wire clk,
	/* Write port */
	input wire we,
	input wire [ADDR_W-1:0] waddr,
	input wire [W-1:0] wdata,
	/* Read port */
	input wire [ADDR_W-1:0] raddr,
	output wire [W-1:0] rdata
);
`ifdef _AM_XILINX_SYNTH
	(* ram_style = "distributed" *)
	/* synthesis syn_ramstyle = "distributed" */
`endif
	reg [W-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (we)
			mem[waddr] <= wdata;
	end

	generate
	if (PIPE != 0) begin : g_pipe
		reg [W-1:0] rdata_reg;
		always @(posedge clk) begin
			rdata_reg <= mem[raddr];
		end
		assign rdata = rdata_reg;
	end else begin : g_async
		assign rdata = mem[raddr];
	end
	endgenerate
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
