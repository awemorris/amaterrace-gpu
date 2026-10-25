/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_amb_to_rt: the leaf of the MC's client tree (spec/common/am_amb_to_rt.md).
 * It turns one client's AMB port (design §4.1; the client does not change)
 * into the tree's flit packets and back:
 *
 *   request   a header flit, and for a write one data flit (the line)
 *   response  one flit: the header fields and the line
 *
 * Header flit (request), from bit 0: [0] priority (PRIO), [1] write,
 * [2] outside the VRAM window, [3] chk (session protection checks the
 * request), [11:4] tag, [19:12] client (CLIENT), then RW route bits (ROUTE:
 * the child taken at each router, the root's first), LAW line-address bits
 * (the line inside the VRAM window), LINE_BYTES byte enables, tbl (a write
 * of the protection table) and the 6-bit protection slot (spec
 * gpu/mc/atg_mc_prot.md; 0 where the client has none).  Response flit: [0] write, [1] error,
 * [9:2] tag, then RW route bits, then the line from bit 10+RW.
 *
 * A request is taken from the client (req_ready) when its last flit is
 * taken by the tree; the client holds it until then (the AMB rule).  A
 * line address whose bits above the VRAM window differ from VRAM_BASE's
 * is sent with the outside bit, and the MC answers it with an aperture
 * error.  While hold is 1 no new packet starts (the MC's quiesce); a
 * write whose header is already in the tree still sends its data flit, so
 * a router never waits for the rest of a packet.  Responses are always taken (the AMB has no back-pressure) and
 * given to the client in the same cycle.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_amb_to_rt #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter VRAM_AW = 32,	/* address bits of the VRAM window (LINE_SHIFT < VRAM_AW <= ADDR_W) */
	parameter [ADDR_W-1:0] VRAM_BASE = {ADDR_W{1'b0}},	/* the window's base (aligned to its size) */
	parameter RW = 1,	/* route bits */
	parameter [RW-1:0] ROUTE = {RW{1'b0}},
	parameter [7:0] CLIENT = 8'd0,
	parameter PRIO = 0,
	parameter FW = LINE_BYTES * 8,	/* request flit width (a line) */
	parameter RFW = LINE_BYTES * 8 + 10 + RW	/* response flit width */
) (
	input wire clk,
	input wire rst_n,
	input wire flush,
	input wire hold,	/* start no new packet (quiesce); a write's data flit still goes */

	/* The client's AMB port (this module is its server side). */
	input wire req_valid,
	output wire req_ready,
	input wire req_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	input wire [LINE_BYTES-1:0] req_be,
	input wire [LINE_BYTES*8-1:0] req_wdata,
	input wire [7:0] req_tag,
	input wire req_chk,	/* session protection: held with the request like the rest */
	input wire req_tbl,
	input wire [5:0] req_slot,
	output wire rsp_valid,
	output wire rsp_write,
	output wire [7:0] rsp_tag,
	output wire [LINE_BYTES*8-1:0] rsp_rdata,
	output wire rsp_error,

	/* The tree. */
	output wire t_req_valid,
	input wire t_req_ready,
	output wire [FW-1:0] t_req_data,
	output wire t_req_last,
	input wire t_rsp_valid,
	output wire t_rsp_ready,
	input wire [RFW-1:0] t_rsp_data
);
	localparam LAW = VRAM_AW - LINE_SHIFT;
	localparam HW = 20 + RW + LAW + LINE_BYTES + 7;
	localparam LINE_BITS = LINE_BYTES * 8;

	/* 0: the header goes next, 1: the data flit of a write. */
	reg data_phase;

	wire outside;
	generate
	if (VRAM_AW < ADDR_W) begin : g_window
		assign outside = req_line[ADDR_W-LINE_SHIFT-1:LAW] != VRAM_BASE[ADDR_W-1:VRAM_AW];
		wire unused_base = &{1'b0, VRAM_BASE[VRAM_AW-1:0]};
	end else begin : g_flat
		assign outside = 1'b0;
		wire unused_base = &{1'b0, VRAM_BASE};
	end
	endgenerate

	wire [HW-1:0] header = {req_slot, req_tbl, req_be, req_line[LAW-1:0], ROUTE, CLIENT, req_tag,
		req_chk, outside, req_write, PRIO != 0};

	wire go = data_phase || !hold;

	assign t_req_valid = req_valid && go;
	assign t_req_data = data_phase ? req_wdata : {{(FW - HW){1'b0}}, header};
	assign t_req_last = data_phase || !req_write;
	assign req_ready = t_req_ready && t_req_last && go;

	always @(posedge clk) begin
		if (!rst_n || flush)
			data_phase <= 1'b0;
		else if (t_req_valid && t_req_ready)
			data_phase <= !t_req_last;
	end

	assign t_rsp_ready = 1'b1;
	assign rsp_valid = t_rsp_valid;
	assign rsp_write = t_rsp_data[0];
	assign rsp_error = t_rsp_data[1];
	assign rsp_tag = t_rsp_data[9:2];
	assign rsp_rdata = t_rsp_data[10+RW +: LINE_BITS];

	wire unused_ok = &{1'b0, t_rsp_data[10 +: RW]};
endmodule

`default_nettype wire
