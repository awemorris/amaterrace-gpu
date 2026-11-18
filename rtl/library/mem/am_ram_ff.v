/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_ram_ff: Explicit Flip-Flop Register Array (Standard Cell D-FF on ASIC / Registers on FPGA).
 *
 * Designed for small buffers and FIFOs (depth 2 to 16) where memory macro or LUTRAM
 * inference must be strictly prevented.
 * Under SYNTH_KINTEX7 / SYNTH_ZYNQ_ULTRASCALE, explicitly mapped to flip-flops (inhibits SRL and RAM inference).
 */

`timescale 1ns / 1ps
`default_nettype none

`ifdef SYNTH_KINTEX7
	`define _AM_XILINX_SYNTH
`endif
`ifdef SYNTH_ZYNQ_ULTRASCALE
	`define _AM_XILINX_SYNTH
`endif

module am_ram_ff #(
	parameter W = 32,
	parameter ADDR_W = 2,
	parameter DEPTH = 1 << ADDR_W,
	parameter PIPE = 0	/* 0: combinational MUX read (latency 0), 1: registered read (latency 1) */
) (
	input wire clk,
	input wire rst_n,
	/* Write port */
	input wire we,
	input wire [ADDR_W-1:0] waddr,
	input wire [W-1:0] wdata,
	/* Read port */
	input wire [ADDR_W-1:0] raddr,
	output wire [W-1:0] rdata
);
`ifdef _AM_XILINX_SYNTH
	(* ram_style = "registers" *)
	(* shreg_extract = "no" *)
	/* synthesis syn_ramstyle = "registers", syn_srl_style = "registers" */
`endif
	reg [W-1:0] mem [0:DEPTH-1];

	integer i;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			for (i = 0; i < DEPTH; i = i + 1)
				mem[i] <= {W{1'b0}};
		end else if (we) begin
			mem[waddr] <= wdata;
		end
	end

	generate
	if (PIPE != 0) begin : g_pipe
		reg [W-1:0] rdata_reg;
		always @(posedge clk or negedge rst_n) begin
			if (!rst_n)
				rdata_reg <= {W{1'b0}};
			else
				rdata_reg <= mem[raddr];
		end
		assign rdata = rdata_reg;
	end else begin : g_comb
		assign rdata = mem[raddr];
	end
	endgenerate
endmodule

`undef _AM_XILINX_SYNTH
`default_nettype wire
