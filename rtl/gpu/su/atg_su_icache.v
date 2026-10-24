/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_su_icache: The SU's instruction cache: 2 KiB direct-mapped (256
 * instructions), lines of LINE_BYTES from the AMB, invalidated by
 * LOAD_PROGRAM / INVALIDATE[3].
 *
 * The behaviour, and where it differs from
 * the design: spec/gpu/su/atg_su_icache.md (§10 Status).
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_su_icache #(
	parameter ADDR_W = 32,	/* GPU address width */
	parameter LINE_BYTES = 32,	/* AMB line size: 32 (ZYBO) or 64 (KC705) */
	parameter LINE_SHIFT = 5,	/* log2(LINE_BYTES) */
	parameter IC_BYTES = 2048	/* Size in bytes */
) (
	input wire clk,
	input wire rst_n,
	input wire ic_req,
	output wire ic_ready,
	input wire [31:0] ic_addr,
	output wire ic_rvalid,
	output wire [63:0] ic_rdata,
	input wire inv,
	/* AMB client port (design §4.1) */
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
	localparam LB = LINE_BYTES * 8;
	localparam NLINES = IC_BYTES / LINE_BYTES;
	localparam IX_W = $clog2(NLINES);
	localparam OFF_W = $clog2(IC_BYTES);
	localparam TAG_W = ADDR_W - OFF_W;
	localparam WPL = LINE_BYTES / 8;	/* instructions per line */
	localparam WS_W = WPL > 1 ? $clog2(WPL) : 1;
	localparam [1:0] S_IDLE = 2'd0, S_MREQ = 2'd1, S_MWAIT = 2'd2, S_RESP = 2'd3;

	reg [1:0] state;
	reg [NLINES-1:0] valid;
	reg [TAG_W-1:0] tags [0:NLINES-1];
	reg [LB-1:0] data [0:NLINES-1];
	reg [ADDR_W-LINE_SHIFT-1:0] mline;	/* the line being filled */
	reg [LB-1:0] fill;
	reg inv_seen;

	wire [IX_W-1:0] idx = ic_addr[OFF_W-1:LINE_SHIFT];
	wire [TAG_W-1:0] tag = ic_addr[ADDR_W-1:OFF_W];
	wire [ADDR_W-LINE_SHIFT-1:0] line = ic_addr[ADDR_W-1:LINE_SHIFT];
	wire [WS_W-1:0] wsel = WPL > 1 ? ic_addr[LINE_SHIFT-1:3] : {WS_W{1'b0}};
	wire hit = valid[idx] && tags[idx] == tag;
	wire from_fill = state == S_RESP && line == mline;
	assign ic_ready = (state == S_IDLE && hit) || from_fill;
	wire take = ic_req && ic_ready;

	/* The answer, the cycle after the request. */
	reg rv, rfill;
	reg [WS_W-1:0] rsel;
	reg [LB-1:0] rline;
	assign ic_rvalid = rv;
	wire [LB-1:0] src = rfill ? fill : rline;
	assign ic_rdata = src[rsel*64 +: 64];

	assign req_valid = state == S_MREQ;
	assign req_write = 1'b0;
	assign req_line = mline;
	assign req_be = {LINE_BYTES{1'b0}};
	assign req_wdata = {LB{1'b0}};
	assign req_tag = 8'd0;

	always @(posedge clk) begin
		if (!rst_n) begin
			state <= S_IDLE;
			valid <= {NLINES{1'b0}};
			rv <= 1'b0;
			rfill <= 1'b0;
			rsel <= {WS_W{1'b0}};
			inv_seen <= 1'b0;
			mline <= {(ADDR_W-LINE_SHIFT){1'b0}};
		end else begin
			rv <= take;
			if (take) begin
				rfill <= from_fill;
				rsel <= wsel;
				rline <= data[idx];
			end
			case (state)
			S_IDLE:
				if (ic_req && !hit) begin
					state <= S_MREQ;
					mline <= line;
					inv_seen <= 1'b0;
				end
			S_MREQ:
				if (req_ready)
					state <= S_MWAIT;
			S_MWAIT:
				if (rsp_valid && !rsp_write) begin
					fill <= rsp_error ? {LB{1'b0}} : rsp_rdata;
					if (!rsp_error && !inv_seen && !inv) begin
						data[mline[IX_W-1:0]] <= rsp_rdata;
						tags[mline[IX_W-1:0]] <= mline[ADDR_W-LINE_SHIFT-1:IX_W];
					end
					state <= S_RESP;
				end
			default:	/* S_RESP: one cycle for the waiting request */
				state <= S_IDLE;
			endcase
			/* Valid bits: set by a clean fill, all cleared by inv. */
			if (inv) begin
				valid <= {NLINES{1'b0}};
				inv_seen <= 1'b1;
			end else if (state == S_MWAIT && rsp_valid && !rsp_write && !rsp_error && !inv_seen)
				valid[mline[IX_W-1:0]] <= 1'b1;
		end
	end

	wire unused_ok = &{1'b0, rsp_tag, ic_addr[2:0], (TAG_W == 0)};
endmodule

`default_nettype wire
