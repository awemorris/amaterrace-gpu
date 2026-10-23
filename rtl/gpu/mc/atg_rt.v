/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_rt: a 2-way router of the MC's client tree (spec/gpu/mc/atg_rt.md).
 * Two child ports and one parent port, each a request channel (towards
 * the MC) and a response channel (towards the clients).
 *
 * Request: packets of flits {data, last}; the first flit is the header,
 * whose bit 0 is the priority bit.  At a packet boundary the router picks
 * one child: a waiting header with the priority bit beats one without;
 * otherwise the children take turns (the one not served last goes first).
 * The pick holds until the packet's last flit has passed, so packets are
 * never interleaved.  One register stage towards the parent; a child's
 * ready is the stage's (empty, or being emptied this cycle) and the pick.
 *
 * Response: one-flit packets; bit RBIT of the flit selects the child
 * (0 or 1).  One register stage towards the children.
 *
 * Order: a child's packets leave in the order they came, and so do the
 * responses for one child.  rsp_idle is 1 when the response stage is empty
 * (requests waiting in the tree do not count: they are not granted yet).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_rt #(
	parameter FW = 256,	/* request flit width */
	parameter RFW = 266,	/* response flit width */
	parameter RBIT = 10	/* the response flit's bit that selects the child */
) (
	input wire clk,
	input wire rst_n,
	input wire flush,

	input wire c0_req_valid,
	output wire c0_req_ready,
	input wire [FW-1:0] c0_req_data,
	input wire c0_req_last,
	input wire c1_req_valid,
	output wire c1_req_ready,
	input wire [FW-1:0] c1_req_data,
	input wire c1_req_last,
	output wire p_req_valid,
	input wire p_req_ready,
	output wire [FW-1:0] p_req_data,
	output wire p_req_last,

	input wire p_rsp_valid,
	output wire p_rsp_ready,
	input wire [RFW-1:0] p_rsp_data,
	output wire c0_rsp_valid,
	input wire c0_rsp_ready,
	output wire [RFW-1:0] c0_rsp_data,
	output wire c1_rsp_valid,
	input wire c1_rsp_ready,
	output wire [RFW-1:0] c1_rsp_data,

	output wire rsp_idle
);
	/* Request stage. */
	reg q_valid;
	reg [FW-1:0] q_data;
	reg q_last;
	reg lock;	/* a packet is passing */
	reg owner;	/* its child */
	reg last_won;	/* the child picked at the last packet start */

	wire both = c0_req_valid && c1_req_valid;
	wire pick_free = both ? (c0_req_data[0] != c1_req_data[0] ? c1_req_data[0] : !last_won) :
		c1_req_valid;
	wire pick = lock ? owner : pick_free;
	wire pick_valid = pick ? c1_req_valid : c0_req_valid;
	wire load = !q_valid || p_req_ready;
	wire take = load && pick_valid;

	assign c0_req_ready = load && !pick;
	assign c1_req_ready = load && pick;
	assign p_req_valid = q_valid;
	assign p_req_data = q_data;
	assign p_req_last = q_last;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			q_valid <= 1'b0;
			q_data <= {FW{1'b0}};
			q_last <= 1'b0;
			lock <= 1'b0;
			owner <= 1'b0;
			last_won <= 1'b1;
		end else begin
			if (load)
				q_valid <= pick_valid;
			if (take) begin
				q_data <= pick ? c1_req_data : c0_req_data;
				q_last <= pick ? c1_req_last : c0_req_last;
				if (!lock)
					last_won <= pick;
				lock <= !(pick ? c1_req_last : c0_req_last);
				owner <= pick;
			end
		end
	end

	/* Response stage. */
	reg r_valid;
	reg [RFW-1:0] r_data;
	wire r_dst = r_data[RBIT];
	wire r_out = r_dst ? c1_rsp_ready : c0_rsp_ready;

	assign p_rsp_ready = !r_valid || r_out;
	assign c0_rsp_valid = r_valid && !r_dst;
	assign c1_rsp_valid = r_valid && r_dst;
	assign c0_rsp_data = r_data;
	assign c1_rsp_data = r_data;

	always @(posedge clk) begin
		if (!rst_n || flush) begin
			r_valid <= 1'b0;
			r_data <= {RFW{1'b0}};
		end else if (p_rsp_ready) begin
			r_valid <= p_rsp_valid;
			if (p_rsp_valid)
				r_data <= p_rsp_data;
		end
	end

	assign rsp_idle = !r_valid;
endmodule

`default_nettype wire
