/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt: the blitter.  It takes its parameters from the BLT range of the
 * state register file (docs/ghci.md section 8.2), seen as the CP writes
 * them (st_we), and runs one operation per kick through its AMB port
 * (atg_mc): FILL, COPY, TILE and UNTILE in atg_blt_2d, RESOLVE
 * (BLT_OP[2:0] = 4, with MS4) in atg_blt_rsv.  BLT_OP[2] at the kick picks
 * the engine (owner); the kick goes to it alone.
 *
 * The two engines never run at once: the CP kicks only an idle blitter.
 * The port: an idle engine holds no request, so req_valid is the OR of
 * the two, req_ready goes to both and the request's fields come from the
 * owner (a register, so that the mux is not on the request's path into
 * the MC).  The responses go to the owner only (an engine counts every
 * response it sees); the owner changes only at a kick, after every
 * response of the previous operation.  busy, done and error are the OR of
 * the engines'; error_kind is that of the engine whose error pulses.
 * Without MS4 there is no RESOLVE engine and a kick with BLT_OP[2] = 1 is
 * refused: error of kind OPCODE the next cycle, busy stays 0.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter MS4 = 0		/* RESOLVE (CAPS[29]) */
) (
	input wire clk,
	input wire rst_n,

	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	input wire kick,
	output wire busy,
	output wire done,
	output wire error,
	output wire [3:0] error_kind,

	output wire req_valid,
	input wire req_ready,
	output wire req_write,
	output wire [ADDR_W-LINE_SHIFT-1:0] req_line,
	output wire [LINE_BYTES-1:0] req_be,
	output wire [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,

	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	`include "ghci_regs.vh"

	localparam LA_W = ADDR_W - LINE_SHIFT;
	localparam LBITS = LINE_BYTES * 8;

	/* BLT_OP[2] as written, and the owner taken at the kick. */
	reg op2;
	reg own;

	always @(posedge clk) begin
		if (!rst_n) begin
			op2 <= 1'b0;
			own <= 1'b0;
		end else begin
			if (st_we && st_idx == GHCI_S_BLT_OP)
				op2 <= st_wdata[2];
			if (kick && !busy)
				own <= op2 && MS4 != 0;
		end
	end

	/* The 2D engine. */
	wire d_busy;
	wire d_done;
	wire d_error;
	wire [3:0] d_kind;
	wire d_req_valid;
	wire d_req_write;
	wire [LA_W-1:0] d_req_line;
	wire [LINE_BYTES-1:0] d_req_be;
	wire [LBITS-1:0] d_req_wdata;
	wire [7:0] d_req_tag;

	atg_blt_2d #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT)
	) b2d (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx),
		.st_wdata(st_wdata),
		.kick(kick && !op2),
		.busy(d_busy),
		.done(d_done),
		.error(d_error),
		.error_kind(d_kind),
		.req_valid(d_req_valid),
		.req_ready(req_ready),
		.req_write(d_req_write),
		.req_line(d_req_line),
		.req_be(d_req_be),
		.req_wdata(d_req_wdata),
		.req_tag(d_req_tag),
		.rsp_valid(rsp_valid && !own),
		.rsp_write(rsp_write),
		.rsp_tag(rsp_tag),
		.rsp_rdata(rsp_rdata),
		.rsp_error(rsp_error)
	);

	/* The RESOLVE engine, or the refusal of its kicks. */
	wire r_busy;
	wire r_done;
	wire r_error;
	wire [3:0] r_kind;
	wire r_req_valid;
	wire r_req_write;
	wire [LA_W-1:0] r_req_line;
	wire [LINE_BYTES-1:0] r_req_be;
	wire [LBITS-1:0] r_req_wdata;
	wire [7:0] r_req_tag;

	generate
		if (MS4 != 0) begin : g_rsv
			atg_blt_rsv #(
				.ADDR_W(ADDR_W),
				.LINE_BYTES(LINE_BYTES),
				.LINE_SHIFT(LINE_SHIFT)
			) rsv (
				.clk(clk),
				.rst_n(rst_n),
				.st_we(st_we),
				.st_idx(st_idx),
				.st_wdata(st_wdata),
				.kick(kick && op2),
				.busy(r_busy),
				.done(r_done),
				.error(r_error),
				.error_kind(r_kind),
				.req_valid(r_req_valid),
				.req_ready(req_ready),
				.req_write(r_req_write),
				.req_line(r_req_line),
				.req_be(r_req_be),
				.req_wdata(r_req_wdata),
				.req_tag(r_req_tag),
`ifdef MUT_RSV_RSP
				.rsp_valid(rsp_valid),
`else
				.rsp_valid(rsp_valid && own),
`endif
				.rsp_write(rsp_write),
				.rsp_tag(rsp_tag),
				.rsp_rdata(rsp_rdata),
				.rsp_error(rsp_error)
			);
		end else begin : g_nrsv
			reg w_error;

			always @(posedge clk)
				w_error <= rst_n && kick && op2;
			assign r_busy = 1'b0;
			assign r_done = 1'b0;
			assign r_error = w_error;
			assign r_kind = GHCI_FAULT_OPCODE;
			assign r_req_valid = 1'b0;
			assign r_req_write = 1'b0;
			assign r_req_line = {LA_W{1'b0}};
			assign r_req_be = {LINE_BYTES{1'b0}};
			assign r_req_wdata = {LBITS{1'b0}};
			assign r_req_tag = 8'd0;
		end
	endgenerate

	assign busy = d_busy || r_busy;
	assign done = d_done || r_done;
	assign error = d_error || r_error;
	assign error_kind = r_error ? r_kind : d_kind;
	assign req_valid = d_req_valid || r_req_valid;
	assign req_write = own ? r_req_write : d_req_write;
	assign req_line = own ? r_req_line : d_req_line;
	assign req_be = own ? r_req_be : d_req_be;
	assign req_wdata = own ? r_req_wdata : d_req_wdata;
	assign req_tag = own ? r_req_tag : d_req_tag;
endmodule

`default_nettype wire
