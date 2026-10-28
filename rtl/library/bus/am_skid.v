/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_skid: A full registered skid buffer (register slice) providing zero-bubble
 * 100% throughput while completely isolating both forward (valid/data) and
 * reverse (ready) paths using flip-flops.
 *
 * Both in_ready and out_valid/out_data are driven directly from registers,
 * breaking all combinational paths between upstream and downstream interfaces.
 * Internal 2-entry capacity ensures that when downstream deasserts out_ready,
 * in-flight data accepted via in_ready is captured into the skid register without loss.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_skid #(
	parameter W = 32,
	parameter WIDTH = W
) (
	input wire clk,
	input wire rst_n,

	input wire in_valid,
	output reg in_ready,
	input wire [WIDTH-1:0] in_data,

	output reg out_valid,
	input wire out_ready,
	output reg [WIDTH-1:0] out_data
);
	reg [WIDTH-1:0] skid_data;
	reg skid_valid;

	wire out_load = skid_valid ? out_ready : (in_valid && (out_ready || !out_valid));
	wire [WIDTH-1:0] out_next = skid_valid ? skid_data : in_data;

	always @(posedge clk) begin
		if (!rst_n) begin
			in_ready   <= 1'b1;
			out_valid  <= 1'b0;
			out_data   <= {WIDTH{1'b0}};
			skid_valid <= 1'b0;
			skid_data  <= {WIDTH{1'b0}};
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
			if (out_load) begin
				out_data <= out_next;
			end
			if (in_valid && in_ready) begin
				skid_data <= in_data;
			end
		end
	end

endmodule

`default_nettype wire
