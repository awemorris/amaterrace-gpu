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
	parameter WIDTH = W,
	parameter RST_DATA = 1
) (
	input wire clk,
	input wire rst_n,

	input wire in_valid,
	output reg in_ready,
	input wire [WIDTH-1:0] in_data,

	output reg out_valid,
	input wire out_ready,
	(* max_fanout = 24 *) output reg [WIDTH-1:0] out_data
);
	(* max_fanout = 24 *) reg [WIDTH-1:0] skid_data;
	reg skid_valid;

	localparam integer SL_W = 16;
	localparam integer FULL_SL = (WIDTH > 32) ? (WIDTH / SL_W) : 0;
	localparam integer REM_W   = (WIDTH > 32) ? (WIDTH - FULL_SL * SL_W) : WIDTH;
	localparam integer SKID_SL = FULL_SL + ((REM_W > 0) ? 1 : 0);

	(* keep = "true", dont_touch = "true" *) reg [SKID_SL-1:0] skid_valid_sl;
	(* keep = "true", dont_touch = "true" *) reg [SKID_SL-1:0] out_valid_sl;
	(* keep = "true", dont_touch = "true" *) reg [SKID_SL-1:0] in_ready_sl;

	wire [SKID_SL-1:0] load_out_v;
	wire [SKID_SL-1:0] load_skid_v;
	wire [WIDTH-1:0]   next_out_v;

	genvar gs;
	generate
		for (gs = 0; gs < FULL_SL; gs = gs + 1) begin : g_full
			assign load_out_v[gs] = skid_valid_sl[gs] ? out_ready :
				(in_valid && (out_ready || !out_valid_sl[gs]));
			assign load_skid_v[gs] = in_valid && in_ready_sl[gs];
			assign next_out_v[gs*SL_W +: SL_W] = skid_valid_sl[gs] ?
				skid_data[gs*SL_W +: SL_W] : in_data[gs*SL_W +: SL_W];
			if (RST_DATA != 0) begin : g_rst
				always @(posedge clk or negedge rst_n) begin
					if (!rst_n) begin
						out_data[gs*SL_W +: SL_W]  <= {SL_W{1'b0}};
						skid_data[gs*SL_W +: SL_W] <= {SL_W{1'b0}};
					end else begin
						if (load_out_v[gs])
							out_data[gs*SL_W +: SL_W] <= next_out_v[gs*SL_W +: SL_W];
						if (load_skid_v[gs])
							skid_data[gs*SL_W +: SL_W] <= in_data[gs*SL_W +: SL_W];
					end
				end
			end else begin : g_norst
				always @(posedge clk) begin
					if (load_out_v[gs])
						out_data[gs*SL_W +: SL_W] <= next_out_v[gs*SL_W +: SL_W];
					if (load_skid_v[gs])
						skid_data[gs*SL_W +: SL_W] <= in_data[gs*SL_W +: SL_W];
				end
			end
		end
		if (REM_W > 0) begin : g_rem
			localparam integer R0 = FULL_SL * SL_W;
			localparam integer RS = FULL_SL;
			assign load_out_v[RS] = skid_valid_sl[RS] ? out_ready :
				(in_valid && (out_ready || !out_valid_sl[RS]));
			assign load_skid_v[RS] = in_valid && in_ready_sl[RS];
			assign next_out_v[R0 +: REM_W] = skid_valid_sl[RS] ?
				skid_data[R0 +: REM_W] : in_data[R0 +: REM_W];
			if (RST_DATA != 0) begin : g_rst_r
				always @(posedge clk or negedge rst_n) begin
					if (!rst_n) begin
						out_data[R0 +: REM_W]  <= {REM_W{1'b0}};
						skid_data[R0 +: REM_W] <= {REM_W{1'b0}};
					end else begin
						if (load_out_v[RS])
							out_data[R0 +: REM_W] <= next_out_v[R0 +: REM_W];
						if (load_skid_v[RS])
							skid_data[R0 +: REM_W] <= in_data[R0 +: REM_W];
					end
				end
			end else begin : g_norst_r
				always @(posedge clk) begin
					if (load_out_v[RS])
						out_data[R0 +: REM_W] <= next_out_v[R0 +: REM_W];
					if (load_skid_v[RS])
						skid_data[R0 +: REM_W] <= in_data[R0 +: REM_W];
				end
			end
		end
	endgenerate

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			in_ready      <= 1'b1;
			out_valid     <= 1'b0;
			skid_valid    <= 1'b0;
			skid_valid_sl <= {SKID_SL{1'b0}};
			out_valid_sl  <= {SKID_SL{1'b0}};
			in_ready_sl   <= {SKID_SL{1'b1}};
		end else begin
			if (skid_valid) begin
				if (out_ready) begin
					out_valid     <= 1'b1;
					skid_valid    <= 1'b0;
					in_ready      <= 1'b1;
					out_valid_sl  <= {SKID_SL{1'b1}};
					skid_valid_sl <= {SKID_SL{1'b0}};
					in_ready_sl   <= {SKID_SL{1'b1}};
				end
			end else begin
				if (out_ready || !out_valid) begin
					out_valid    <= in_valid;
					out_valid_sl <= {SKID_SL{in_valid}};
				end else if (in_valid && in_ready) begin
					skid_valid    <= 1'b1;
					in_ready      <= 1'b0;
					skid_valid_sl <= {SKID_SL{1'b1}};
					in_ready_sl   <= {SKID_SL{1'b0}};
				end
			end
		end
	end

endmodule

`default_nettype wire
