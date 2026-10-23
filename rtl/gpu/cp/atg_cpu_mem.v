/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_cpu_mem: IMEM and DMEM of the CP's CPU, block RAMs with initial
 * images from $readmemh.
 *
 * IMEM: port A is the core's fetch (read), port B the DMA's writes (the
 * CPFW image load).  DMEM: port A is the data port (byte writes), port B
 * the DMA (whole words).  Each read returns the word the cycle after its
 * enable and the output stays until the next enabled access (the BRAM
 * output register: atg_cpu_core relies on this for i_rdata).  A write
 * returns the old word (read-first).  Addresses are byte offsets; bits
 * above the size wrap.  x_rdata of an IMEM access is 0.  The contents are
 * not reset.  See spec/gpu/cp/atg_cpu_mem.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_cpu_mem #(
	parameter IMEM_WORDS = 8192,	/* IMEM size in 32-bit words (32 KiB) */
	parameter DMEM_WORDS = 4096,	/* DMEM size in words (16 KiB) */
	parameter IMEM_INIT = "",	/* $readmemh file of the IMEM image ("" = none) */
	parameter DMEM_INIT = ""	/* $readmemh file of the DMEM image */
) (
	input wire clk,
	/* Fetch (atg_cpu_core) */
	input wire i_en,
	input wire [31:0] i_addr,
	output reg [31:0] i_rdata,
	/* Data (from atg_cpu_win) */
	input wire d_en,
	input wire [3:0] d_we,
	input wire [31:0] d_addr,
	input wire [31:0] d_wdata,
	output reg [31:0] d_rdata,
	/* DMA (from atg_cpu_dma) */
	input wire x_en,
	input wire x_we,
	input wire x_imem,
	input wire [31:0] x_addr,
	input wire [31:0] x_wdata,
	output wire [31:0] x_rdata
);
	localparam IW = $clog2(IMEM_WORDS);
	localparam DW = $clog2(DMEM_WORDS);

	reg [31:0] imem [0:IMEM_WORDS-1];
	reg [31:0] dmem [0:DMEM_WORDS-1];

	initial begin
		if (IMEM_INIT != "")
			$readmemh(IMEM_INIT, imem);
		if (DMEM_INIT != "")
			$readmemh(DMEM_INIT, dmem);
	end

	wire [IW-1:0] ia = i_addr[IW+1:2];
	wire [IW-1:0] xia = x_addr[IW+1:2];
	wire [DW-1:0] da = d_addr[DW+1:2];
	wire [DW-1:0] xda = x_addr[DW+1:2];

	/* IMEM port A: fetch. */
	always @(posedge clk) begin
		if (i_en)
			i_rdata <= imem[ia];
	end

	/* IMEM port B: DMA writes. */
	always @(posedge clk) begin
		if (x_en && x_imem && x_we)
			imem[xia] <= x_wdata;
	end

	/* DMEM port A: data, byte writes. */
	always @(posedge clk) begin
		if (d_en) begin
			d_rdata <= dmem[da];
			if (d_we[0])
				dmem[da][7:0] <= d_wdata[7:0];
			if (d_we[1])
				dmem[da][15:8] <= d_wdata[15:8];
			if (d_we[2])
				dmem[da][23:16] <= d_wdata[23:16];
			if (d_we[3])
				dmem[da][31:24] <= d_wdata[31:24];
		end
	end

	/* DMEM port B: DMA, whole words. */
	reg [31:0] x_word;
	reg x_was_imem;

	always @(posedge clk) begin
		if (x_en) begin
			x_was_imem <= x_imem;
			if (!x_imem) begin
				x_word <= dmem[xda];
				if (x_we)
					dmem[xda] <= x_wdata;
			end
		end
	end

	assign x_rdata = x_was_imem ? 32'd0 : x_word;

	wire unused_ok = &{1'b0, i_addr[31:IW+2], i_addr[1:0], d_addr[31:DW+2], d_addr[1:0],
		x_addr[31:2], x_addr[1:0]};
endmodule

`default_nettype wire
