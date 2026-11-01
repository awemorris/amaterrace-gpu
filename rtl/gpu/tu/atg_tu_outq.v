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
	localparam NUM_GRPS   = (NUM_SLICES + 3) / 4;

	(* dont_touch = "true" *) wire rst_inv = !rst_n;

	(* max_fanout = 16 *) reg [2:0] wp;
	(* max_fanout = 16 *) reg [2:0] rp;
	reg r_valid;
	reg r_ready;

	wire [2:0] used;
	wire unused_used_bo;
	am_sub #(.W(3)) u_used (
		.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(unused_used_bo)
	);

	(* keep = "true" *) wire push = in_valid && in_ready;
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
	wire will_full  = (used == 3'd3);
	assign count = used;
	assign in_ready = r_ready;
	assign out_valid = r_valid;

	always @(posedge clk) begin
		if (rst_inv) begin
			wp <= 3'd0;
			rp <= 3'd0;
			r_valid <= 1'b0;
			r_ready <= 1'b1;
		end else begin
			if (push)
				wp <= wp_next;
			if (pop)
				rp <= rp_next;
			case ({push, pop})
			2'b10: begin
				r_valid <= 1'b1;
				r_ready <= !will_full;
			end
			2'b01: begin
				r_valid <= !will_empty;
				r_ready <= 1'b1;
			end
			default: ;
			endcase
		end
	end

	(* keep = "true" *) wire [NUM_GRPS-1:0] push_g;
	(* keep = "true" *) wire [1:0] wp_g [0:NUM_GRPS-1];
	(* keep = "true" *) wire [1:0] rp_g [0:NUM_GRPS-1];

	genvar gi, si;
	generate
	for (gi = 0; gi < NUM_GRPS; gi = gi + 1) begin : g_grp
		assign push_g[gi] = push;
		assign wp_g[gi]   = wp[1:0];
		assign rp_g[gi]   = rp[1:0];
	end

	for (si = 0; si < NUM_SLICES; si = si + 1) begin : g_slice
		localparam LO = si * 16;
		localparam HI = (si == NUM_SLICES - 1) ? (W - 1) : (si * 16 + 15);
		localparam SW = HI - LO + 1;
		localparam G  = si / 4;

		(* keep = "true" *) wire we0 = push_g[G] && (wp_g[G] == 2'd0);
		(* keep = "true" *) wire we1 = push_g[G] && (wp_g[G] == 2'd1);
		(* keep = "true" *) wire we2 = push_g[G] && (wp_g[G] == 2'd2);
		(* keep = "true" *) wire we3 = push_g[G] && (wp_g[G] == 2'd3);
		(* keep = "true" *) wire [1:0] rp_b = rp_g[G];

		(* extract_reset = "no", ram_style = "registers" *) reg [SW-1:0] m0, m1, m2, m3;

		always @(posedge clk) begin
			if (we0) m0 <= in_data[HI:LO];
			if (we1) m1 <= in_data[HI:LO];
			if (we2) m2 <= in_data[HI:LO];
			if (we3) m3 <= in_data[HI:LO];
		end

		assign out_data[HI:LO] = (rp_b == 2'd0) ? m0 :
		                         (rp_b == 2'd1) ? m1 :
		                         (rp_b == 2'd2) ? m2 : m3;
	end
	endgenerate

	wire unused_ok = &{1'b0, unused_used_bo, unused_wp_co, unused_rp_co};
endmodule

`default_nettype wire
