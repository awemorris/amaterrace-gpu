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

`include "atg_config.vh"
`ifdef CFG_BLT_ENABLE_SCALE
`define ATG_DEFAULT_BLT_ENABLE_SCALE (`CFG_BLT_ENABLE_SCALE != 0)
`else
`define ATG_DEFAULT_BLT_ENABLE_SCALE 1
`endif

`ifdef CFG_BLT_ENABLE_BLEND
`define ATG_DEFAULT_BLT_ENABLE_BLEND (`CFG_BLT_ENABLE_BLEND != 0)
`else
`define ATG_DEFAULT_BLT_ENABLE_BLEND 1
`endif

`ifdef CFG_BLT_ENABLE_TILE
`define ATG_DEFAULT_BLT_ENABLE_TILE (`CFG_BLT_ENABLE_TILE != 0)
`else
`define ATG_DEFAULT_BLT_ENABLE_TILE 1
`endif

module atg_blt #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter MS4 = 0,		/* RESOLVE (CAPS[29]) */
	parameter ENABLE_SCALE = `ATG_DEFAULT_BLT_ENABLE_SCALE,
	parameter ENABLE_BLEND = `ATG_DEFAULT_BLT_ENABLE_BLEND,
	parameter ENABLE_TILE = `ATG_DEFAULT_BLT_ENABLE_TILE
) (
	input wire clk,
	input wire rst_n,

	input wire st_we,
	input wire [8:0] st_idx,
	input wire [31:0] st_wdata,

	input wire kick,
	output wire busy,
	output wire [3:0] fsm,
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
`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) reg own;
`else
	reg own;
`endif
	(* keep = "true", dont_touch = "true" *) wire rst_blt_high = !rst_n;

	always @(posedge clk) begin
		if (rst_blt_high) begin
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
	wire [3:0] d_fsm;
	wire d_done;
	wire d_error;
	wire [3:0] d_kind;
	wire d_req_valid;
	wire d_req_write;
	wire [LA_W-1:0] d_req_line;
	wire [LINE_BYTES-1:0] d_req_be;
	wire [LBITS-1:0] d_req_wdata;
	wire [7:0] d_req_tag;

`ifdef SYNTH_KINTEX7
	(* max_fanout = 16 *) wire rsp_valid_b2d;
	(* max_fanout = 16 *) wire rsp_write_b2d;
	LUT1 #(.INIT(2'b10)) u_buf_rv (.I0(rsp_valid && !own), .O(rsp_valid_b2d));
	LUT1 #(.INIT(2'b10)) u_buf_rw (.I0(rsp_write), .O(rsp_write_b2d));
`else
	wire rsp_valid_b2d = rsp_valid && !own;
	wire rsp_write_b2d = rsp_write;
`endif
	wire [7:0] rsp_tag_b2d = rsp_tag;
	wire [8:0] st_idx_b2d = st_idx;

	atg_blt_2d #(
		.ADDR_W(ADDR_W),
		.LINE_BYTES(LINE_BYTES),
		.LINE_SHIFT(LINE_SHIFT),
		.ENABLE_SCALE(ENABLE_SCALE),
		.ENABLE_BLEND(ENABLE_BLEND),
		.ENABLE_TILE(ENABLE_TILE)
	) b2d (
		.clk(clk),
		.rst_n(rst_n),
		.st_we(st_we),
		.st_idx(st_idx_b2d),
		.st_wdata(st_wdata),
		.kick(kick && !op2),
		.busy(d_busy),
		.fsm(d_fsm),
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
		.rsp_valid(rsp_valid_b2d),
		.rsp_write(rsp_write_b2d),
		.rsp_tag(rsp_tag_b2d),
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
			assign r_kind = GHCI_FAULT_KIND_INVALID_OP;
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
`ifdef SYNTH_KINTEX7
	localparam NUM_WDATA_SLICES = LBITS / 16;
	localparam NUM_BE_SLICES = LINE_BYTES / 16;
	(* dont_touch = "true" *) wire [NUM_WDATA_SLICES-1:0] own_wd;
	(* dont_touch = "true" *) wire [NUM_BE_SLICES-1:0] own_be;
	(* dont_touch = "true" *) wire [1:0] own_line;
	(* dont_touch = "true" *) wire own_wr;
	(* dont_touch = "true" *) wire own_tg;

	LUT1 #(.INIT(2'b10)) u_ow_wr (.I0(own), .O(own_wr));
	LUT1 #(.INIT(2'b10)) u_ow_tg (.I0(own), .O(own_tg));
	LUT1 #(.INIT(2'b10)) u_ow_ln0 (.I0(own), .O(own_line[0]));
	LUT1 #(.INIT(2'b10)) u_ow_ln1 (.I0(own), .O(own_line[1]));

	wire [LBITS-1:0] blt_req_wdata;
	wire [LINE_BYTES-1:0] blt_req_be;
	genvar owi;
	generate
		for (owi = 0; owi < NUM_WDATA_SLICES; owi = owi + 1) begin : g_own_wd
			LUT1 #(.INIT(2'b10)) u_ow_wd (.I0(own), .O(own_wd[owi]));
			assign blt_req_wdata[owi*16 +: 16] = own_wd[owi] ? r_req_wdata[owi*16 +: 16] : d_req_wdata[owi*16 +: 16];
		end
		for (owi = 0; owi < NUM_BE_SLICES; owi = owi + 1) begin : g_own_be
			LUT1 #(.INIT(2'b10)) u_ow_be (.I0(own), .O(own_be[owi]));
			assign blt_req_be[owi*16 +: 16] = own_be[owi] ? r_req_be[owi*16 +: 16] : d_req_be[owi*16 +: 16];
		end
	endgenerate

	wire blt_req_write = own_wr ? r_req_write : d_req_write;
	wire [LA_W-1:0] blt_req_line = {
		own_line[1] ? r_req_line[LA_W-1:14] : d_req_line[LA_W-1:14],
		own_line[0] ? r_req_line[13:0] : d_req_line[13:0]
	};
	wire [7:0] blt_req_tag = own_tg ? r_req_tag : d_req_tag;

	reg req_valid_r;
	(* extract_reset = "no" *) reg req_write_r;
	(* extract_reset = "no" *) reg [LA_W-1:0] req_line_r;
	(* extract_reset = "no" *) reg [LINE_BYTES-1:0] req_be_r;
	(* extract_reset = "no" *) reg [LBITS-1:0] req_wdata_r;
	(* extract_reset = "no" *) reg [7:0] req_tag_r;
	always @(posedge clk) begin
		if (rst_blt_high)
			req_valid_r <= 1'b0;
		else
			req_valid_r <= d_req_valid || r_req_valid;
		req_write_r <= blt_req_write;
		req_line_r  <= blt_req_line;
		req_be_r    <= blt_req_be;
		req_wdata_r <= blt_req_wdata;
		req_tag_r   <= blt_req_tag;
	end
	assign req_valid = req_valid_r;
	assign req_write = req_write_r;
	assign req_line  = req_line_r;
	assign req_be    = req_be_r;
	assign req_wdata = req_wdata_r;
	assign req_tag   = req_tag_r;
`else
	assign req_valid = d_req_valid || r_req_valid;
	assign req_write = own ? r_req_write : d_req_write;
	assign req_line = own ? r_req_line : d_req_line;
	assign req_be = own ? r_req_be : d_req_be;
	assign req_wdata = own ? r_req_wdata : d_req_wdata;
	assign req_tag = own ? r_req_tag : d_req_tag;
`endif
`ifdef SYNTH_KINTEX7
	(* keep = "true" *) wire [3:0] fsm_buf;
	genvar g_fsm;
	generate
		for (g_fsm = 0; g_fsm < 4; g_fsm = g_fsm + 1) begin : g_fsm_b
			LUT1 #(.INIT(2'b10)) u_fsm (.I0(d_fsm[g_fsm]), .O(fsm_buf[g_fsm]));
		end
	endgenerate
	assign fsm = fsm_buf;
`else
	assign fsm = d_fsm;
`endif
endmodule

`default_nettype wire
