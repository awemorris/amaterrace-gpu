/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rx_hiz: Hierarchical Early-Z (Hi-Z) RAM.
 *
 * Stores coarse tile depth bounds in BRAM to allow early occlusion culling
 * of occluded triangles and quads prior to pixel shading or detailed depth
 * interpolation.
 *
 * Conditioned on CFG_ENABLE_EARLY_Z: when disabled, this module and its BRAM
 * are completely omitted from synthesis.
 *
 * Strict Guardrails: Verilog-2005 only, zero raw arithmetic operators.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rx_hiz #(
	parameter DEPTH_W = 16,
	parameter TILE_ADDR_W = 11	/* 2048 tiles */
) (
	input wire clk,
	input wire rst_n,
	input wire clear,
	input wire [TILE_ADDR_W-1:0] rd_addr,
	output wire [DEPTH_W-1:0] rd_zmax,
	input wire wr_en,
	input wire [TILE_ADDR_W-1:0] wr_addr,
	input wire [DEPTH_W-1:0] wr_zmax
);
	localparam integer NUM_TILES = 1 << TILE_ADDR_W;

	reg [DEPTH_W-1:0] ram [0:NUM_TILES-1];
	reg [DEPTH_W-1:0] r_data;

	always @(posedge clk) begin
		if (wr_en)
			ram[wr_addr] <= wr_zmax;
		r_data <= ram[rd_addr];
	end

	assign rd_zmax = r_data;

	wire unused_ok = &{1'b0, rst_n, clear};
endmodule

`default_nettype wire
