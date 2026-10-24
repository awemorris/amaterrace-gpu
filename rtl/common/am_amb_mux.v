/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * am_amb_mux: Merges N AMB requesters into one AMB client port: fixed
 * priority (requester 0 first), the requester number in the top bits of
 * the tag, responses routed back by those bits.
 *
 * A requester's valid must stay up until its ready (docs/style.md): the
 * choice is locked while the offered request waits, so a lower-numbered
 * requester that becomes valid meanwhile does not change the payload.
 * The requesters' tags must leave their top ID_W bits 0.  Behaviour:
 * spec/common/am_amb_mux.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module am_amb_mux #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter N = 2,	/* Number of requesters, 2..4 */
	parameter ID_W = 1	/* log2(N) rounded up: the tag bits [7:8-ID_W] carry the requester */
) (
	input wire clk,
	input wire rst_n,
	/* Requesters (packed, requester 0 in the low bits) */
	input wire [N-1:0] i_req_valid,
	output wire [N-1:0] i_req_ready,
	input wire [N-1:0] i_req_write,
	input wire [N*(ADDR_W-LINE_SHIFT)-1:0] i_req_line,
	input wire [N*LINE_BYTES-1:0] i_req_be,
	input wire [N*LINE_BYTES*8-1:0] i_req_wdata,
	input wire [N*8-1:0] i_req_tag,
	output wire [N-1:0] i_rsp_valid,
	output wire i_rsp_write,
	output wire [7:0] i_rsp_tag,
	output wire [LINE_BYTES*8-1:0] i_rsp_rdata,
	output wire i_rsp_error,
	/* AMB client port (design §4.1) */
	output wire o_req_valid,
	input wire o_req_ready,
	output wire o_req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] o_req_line,
	output wire [LINE_BYTES-1:0] o_req_be,
	output wire [LINE_BYTES*8-1:0] o_req_wdata,
	output wire [7:0] o_req_tag,
	input wire o_rsp_valid,
	input wire o_rsp_write,
	input wire [7:0] o_rsp_tag,
	input wire [LINE_BYTES*8-1:0] o_rsp_rdata,
	input wire o_rsp_error
);
	localparam SLA_W = ADDR_W - LINE_SHIFT;
	localparam SLB = LINE_BYTES * 8;
	localparam TAG_LO = 8 - ID_W;

	/* The chosen requester: locked while its request waits for ready. */
	reg lock;
	reg [ID_W-1:0] lock_k;
	reg [ID_W-1:0] pick;
	reg any;
	integer i;

	always @(*) begin
		pick = {ID_W{1'b0}};
		any = 1'b0;
		for (i = N - 1; i >= 0; i = i - 1)
			if (i_req_valid[i]) begin
				/* verilator lint_off WIDTHTRUNC */
				pick = i;
				/* verilator lint_on WIDTHTRUNC */
				any = 1'b1;
			end
	end

	wire [ID_W-1:0] k = lock ? lock_k : pick;
	wire [7:0] tag_k = i_req_tag[k * 8 +: 8];

	assign o_req_valid = lock ? 1'b1 : any;
	assign o_req_write = i_req_write[k];
	assign o_req_line = i_req_line[k * SLA_W +: SLA_W];
	assign o_req_be = i_req_be[k * LINE_BYTES +: LINE_BYTES];
	assign o_req_wdata = i_req_wdata[k * SLB +: SLB];
	assign o_req_tag = {k, tag_k[TAG_LO-1:0]};

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : g_port
			assign i_req_ready[g] = o_req_valid && o_req_ready && k == g;
			assign i_rsp_valid[g] = o_rsp_valid && o_rsp_tag[7:TAG_LO] == g;
		end
	endgenerate

	assign i_rsp_write = o_rsp_write;
	assign i_rsp_tag = {{ID_W{1'b0}}, o_rsp_tag[TAG_LO-1:0]};
	assign i_rsp_rdata = o_rsp_rdata;
	assign i_rsp_error = o_rsp_error;

	always @(posedge clk) begin
		if (!rst_n) begin
			lock <= 1'b0;
			lock_k <= {ID_W{1'b0}};
		end else begin
			lock <= o_req_valid && !o_req_ready;
			lock_k <= k;
		end
	end

	wire unused_ok = &{1'b0, tag_k[7:TAG_LO]};
endmodule

`default_nettype wire
