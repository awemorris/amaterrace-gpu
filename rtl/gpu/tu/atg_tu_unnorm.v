/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_unnorm: an unnormalized coordinate, floor(u × 256) clamped to
 * [−2^28, 2^28] (the former function tu_unnorm of include/atg_tu_fn.vh;
 * tools/tumodel.py unnorm_c).
 *
 * Latency:
 * - LAT = 0: combinational
 * - LAT = 1: 1 cycle pipeline register in internal atg_tu_fx32
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_unnorm #(
	parameter LAT = 0
) (
	input wire clk,
	input wire rst_n,
	input wire en,
	input wire [31:0] f,
	output wire signed [29:0] c
);
	(* dont_touch = "true" *) wire rst_inv = !rst_n;
	wire [31:0] tx_s0;
	atg_tu_fx32 #(.LAT(LAT >= 2 ? 2 : LAT)) u_tx (.clk(clk), .rst_n(rst_n), .en(en), .f(f), .sh(5'd8), .q(tx_s0));

	(* keep = "true", equivalent_register_removal = "no" *) reg [31:0] r_tx;
	always @(posedge clk) begin
		if (rst_inv)
			r_tx <= 32'd0;
		else if (en)
			r_tx <= tx_s0;
	end
	wire [31:0] tx = (LAT >= 2) ? r_tx : tx_s0;
	wire signed [31:0] txs = tx;
	(* keep = "true" *) wire tx_lt_min_lo = txs[31] && (txs[30:28] != 3'b111);
	(* keep = "true" *) wire tx_lt_min_hi = txs[31] && (txs[30:28] != 3'b111);
	(* keep = "true" *) wire tx_gt_max_lo = !txs[31] && (txs[30:28] != 3'b000 && (txs[30:28] != 3'b001 || txs[27:0] != 28'd0));
	(* keep = "true" *) wire tx_gt_max_hi = !txs[31] && (txs[30:28] != 3'b000 && (txs[30:28] != 3'b001 || txs[27:0] != 28'd0));
	wire [29:0] c_min = -30'sd268435456;
	wire [29:0] c_max =  30'sd268435456;
	assign c[14:0]  = tx_lt_min_lo ? c_min[14:0]  : tx_gt_max_lo ? c_max[14:0]  : tx[14:0];
	assign c[29:15] = tx_lt_min_hi ? c_min[29:15] : tx_gt_max_hi ? c_max[29:15] : tx[29:15];

	wire unused_lat0 = (LAT == 0) ? &{1'b0, clk, rst_n, en} : 1'b0;
	wire unused_ok = &{1'b0, unused_lat0};
endmodule

`default_nettype wire
