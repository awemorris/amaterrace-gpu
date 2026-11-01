/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "yes" *)
module atg_blt_skid #(
	parameter W = 32
) (
	input wire clk,
	input wire rst_n,

	input wire in_valid,
	output reg in_ready,
	input wire [W-1:0] in_data,

	output reg out_valid,
	input wire out_ready,
	output wire [W-1:0] out_data
);
	reg skid_valid;

	wire load_out_raw = skid_valid ? out_ready : (in_valid && (out_ready || !out_valid));
	wire load_skid_raw = in_valid && in_ready && !out_ready && out_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			in_ready   <= 1'b1;
			out_valid  <= 1'b0;
			skid_valid <= 1'b0;
		end else begin
			if (skid_valid) begin
				if (out_ready) begin
					out_valid  <= 1'b1;
					skid_valid <= 1'b0;
					in_ready   <= 1'b1;
				end
			end else begin
				if (out_ready || !out_valid) begin
					out_valid <= in_valid;
				end else if (in_valid && in_ready) begin
					skid_valid <= 1'b1;
					in_ready   <= 1'b0;
				end
			end
		end
	end

	localparam NUM_SLICES = (W + 15) / 16;
	reg [W-1:0] r_out_data;
	reg [W-1:0] r_skid_data;
	assign out_data = r_out_data;

	genvar si;
	generate
		for (si = 0; si < NUM_SLICES; si = si + 1) begin : g_slice
			localparam LO = si * 16;
			localparam HI = (si == NUM_SLICES - 1) ? (W - 1) : (si * 16 + 15);
			localparam SW = HI - LO + 1;

`ifdef SYNTH_KINTEX7
			(* keep = "true", dont_touch = "true" *) wire ld_out_b;
			(* keep = "true", dont_touch = "true" *) wire ld_skid_b;
			(* keep = "true", dont_touch = "true" *) wire sk_valid_b;
			LUT4 #(.INIT(16'hF0C4)) u_ldo (
				.I0(out_valid),
				.I1(in_valid),
				.I2(out_ready),
				.I3(skid_valid),
				.O(ld_out_b)
			);
			LUT4 #(.INIT(16'h0080)) u_lds (
				.I0(out_valid),
				.I1(in_valid),
				.I2(in_ready),
				.I3(out_ready),
				.O(ld_skid_b)
			);
			LUT1 #(.INIT(2'b10)) u_skv (.I0(skid_valid), .O(sk_valid_b));
`else
			wire ld_out_b = load_out_raw;
			wire ld_skid_b = load_skid_raw;
			wire sk_valid_b = skid_valid;
`endif

			always @(posedge clk) begin
				if (ld_skid_b)
					r_skid_data[HI:LO] <= in_data[HI:LO];
				if (ld_out_b)
					r_out_data[HI:LO] <= sk_valid_b ? r_skid_data[HI:LO] : in_data[HI:LO];
			end
		end
	endgenerate
endmodule

`default_nettype wire
