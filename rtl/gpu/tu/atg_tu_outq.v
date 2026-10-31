/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_tu_outq: 4-entry wide FIFO (529 bits) partitioned into 16-bit slices
 * with tree-buffered write enable, write pointer and read pointer to strictly
 * comply with ASIC 5nm 1.5 GHz fanout limits (fanout <= 16 per net).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_tu_outq #(
	parameter W = 529
) (
	input  wire         clk,
	input  wire         rst_n,
	input  wire         in_valid,
	output wire         in_ready,
	input  wire [W-1:0] in_data,
	output wire         out_valid,
	input  wire         out_ready,
	output wire [W-1:0] out_data,
	output wire [2:0]   count
);
	localparam NUM_SLICES = (W + 15) / 16;

	reg [2:0] wp;
	reg [2:0] rp;
	reg r_valid;

	wire [2:0] used;
	wire unused_used_bo;
	am_sub #(.W(3)) u_used (
		.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(unused_used_bo)
	);

	wire push = in_valid && in_ready;
	wire pop  = out_valid && out_ready;

	wire [2:0] wp_next;
	wire unused_wp_co;
	am_add #(.W(3)) u_wp (
		.a(wp), .b(3'd0), .ci(1'b1), .s(wp_next), .co(unused_wp_co)
	);

	wire [2:0] rp_next;
	wire unused_rp_co;
	am_add #(.W(3)) u_rp (
		.a(rp), .b(3'd0), .ci(1'b1), .s(rp_next), .co(unused_rp_co)
	);

	wire will_empty = (rp_next == wp);
	assign count = used;
	assign in_ready = (wp[1:0] != rp[1:0]) || (wp[2] == rp[2]);
	assign out_valid = r_valid;

	always @(posedge clk) begin
		if (!rst_n) begin
			wp <= 3'd0;
			rp <= 3'd0;
			r_valid <= 1'b0;
		end else begin
			if (push)
				wp <= wp_next;
			if (pop)
				rp <= rp_next;
			case ({push, pop})
			2'b10: r_valid <= 1'b1;
			2'b01: r_valid <= !will_empty;
			default: ;
			endcase
		end
	end

	genvar si;
	generate
	for (si = 0; si < NUM_SLICES; si = si + 1) begin : g_slice
		localparam LO = si * 16;
		localparam HI = (si == NUM_SLICES - 1) ? (W - 1) : (si * 16 + 15);
		localparam SW = HI - LO + 1;

`ifdef SYNTH_KINTEX7
		(* keep = "true", dont_touch = "true" *) wire push_b;
		(* keep = "true", dont_touch = "true" *) wire [1:0] wp_b;
		(* keep = "true", dont_touch = "true" *) wire [1:0] rp_b;
		LUT1 #(.INIT(2'b10)) u_psh (.I0(push), .O(push_b));
		LUT1 #(.INIT(2'b10)) u_wp0 (.I0(wp[0]), .O(wp_b[0]));
		LUT1 #(.INIT(2'b10)) u_wp1 (.I0(wp[1]), .O(wp_b[1]));
		LUT1 #(.INIT(2'b10)) u_rp0 (.I0(rp[0]), .O(rp_b[0]));
		LUT1 #(.INIT(2'b10)) u_rp1 (.I0(rp[1]), .O(rp_b[1]));
`else
		wire push_b = push;
		wire [1:0] wp_b = wp[1:0];
		wire [1:0] rp_b = rp[1:0];
`endif

		(* ram_style = "registers" *) reg [SW-1:0] m0, m1, m2, m3;

		always @(posedge clk) begin
			if (push_b) begin
				case (wp_b)
				2'd0: m0 <= in_data[HI:LO];
				2'd1: m1 <= in_data[HI:LO];
				2'd2: m2 <= in_data[HI:LO];
				2'd3: m3 <= in_data[HI:LO];
				endcase
			end
		end

		assign out_data[HI:LO] = (rp_b == 2'd0) ? m0 :
		                         (rp_b == 2'd1) ? m1 :
		                         (rp_b == 2'd2) ? m2 : m3;
	end
	endgenerate

	wire unused_ok = &{1'b0, unused_used_bo, unused_wp_co, unused_rp_co};
endmodule

`default_nettype wire
