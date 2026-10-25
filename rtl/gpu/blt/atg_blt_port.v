/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_blt_port: the AMB port of the blitter's 2D engine (atg_blt_2d): the
 * request register, the outstanding reads and writes, the three line
 * buffers that the read responses fill (by tag: 0 and 1 the source lines,
 * 2 the destination line), and the error flag.
 *
 * issue (taken only while free, i.e. no request is held) loads the
 * request; it is held on req_* until the MC takes it.  rd_idle and wr_idle
 * are 1 when no read, no write is outstanding (the request register
 * included only once taken).  An error response sets fail until clr (the
 * kick).  The tag is {5'd0, write, slot}.  See spec/gpu/blt/atg_blt_port.md.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_blt_port #(
	parameter ADDR_W = 32,
	parameter LINE_BYTES = 32,
	parameter LINE_SHIFT = 5	/* log2(LINE_BYTES) */
) (
	input wire clk,
	input wire rst_n,
	input wire clr,
	/* The engine's request */
	input wire issue,
	input wire i_write,
	input wire [ADDR_W-LINE_SHIFT-1:0] i_line,
	input wire [1:0] i_slot,
	input wire [LINE_BYTES-1:0] i_be,
	input wire [LINE_BYTES*8-1:0] i_wdata,
	output wire free,
	output wire rd_idle,
	output wire wr_idle,
	output reg fail,
	output reg [LINE_BYTES*8-1:0] buf0,
	output reg [LINE_BYTES*8-1:0] buf1,
	output reg [LINE_BYTES*8-1:0] bufd,
	/* The AMB port */
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [ADDR_W-LINE_SHIFT-1:0] req_line,
	output reg [LINE_BYTES-1:0] req_be,
	output reg [LINE_BYTES*8-1:0] req_wdata,
	output wire [7:0] req_tag,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [LINE_BYTES*8-1:0] rsp_rdata,
	input wire rsp_error
);
	reg [1:0] slot;
	reg [3:0] wr_out;
	reg [1:0] rd_out;
	wire q_fire = req_valid && req_ready;
	wire rsp_rd = rsp_valid && !rsp_write;
	wire rsp_wr = rsp_valid && rsp_write;

	assign free = !req_valid;
	assign rd_idle = rd_out == 2'd0;
	assign wr_idle = wr_out == 4'd0;
	assign req_tag = {5'd0, req_write, slot};

	/* The writes and the reads outstanding: one more for a request, one fewer for a response. */
	wire [3:0] wr_up, wr_next;
	wire [1:0] rd_up, rd_next;
	wire [3:0] out_co_unused;

	am_add #(.W(4)) a_wr (.a(wr_out), .b(4'd0), .ci(q_fire && req_write), .s(wr_up), .co(out_co_unused[0]));
	am_sub #(.W(4)) s_wr (.a(wr_up), .b(4'd0), .bi(rsp_wr), .d(wr_next), .bo(out_co_unused[1]));
	am_add #(.W(2)) a_rd (.a(rd_out), .b(2'd0), .ci(q_fire && !req_write), .s(rd_up), .co(out_co_unused[2]));
	am_sub #(.W(2)) s_rd (.a(rd_up), .b(2'd0), .bi(rsp_rd), .d(rd_next), .bo(out_co_unused[3]));

	always @(posedge clk) begin
		if (!rst_n) begin
			req_valid <= 1'b0;
			req_write <= 1'b0;
			wr_out <= 4'd0;
			rd_out <= 2'd0;
			fail <= 1'b0;
		end else begin
			wr_out <= wr_next;
			rd_out <= rd_next;
			if (rsp_rd) begin
				case (rsp_tag[1:0])
				2'd0: buf0 <= rsp_rdata;
				2'd1: buf1 <= rsp_rdata;
				default: bufd <= rsp_rdata;
				endcase
			end
			if (clr)
				fail <= 1'b0;
			else if (rsp_valid && rsp_error)
				fail <= 1'b1;
			if (q_fire)
				req_valid <= 1'b0;
			if (issue && !req_valid) begin
				req_valid <= 1'b1;
				req_write <= i_write;
				req_line <= i_line;
				slot <= i_slot;
				req_be <= i_be;
				req_wdata <= i_wdata;
			end
		end
	end

	wire unused_ok = &{1'b0, rsp_tag[7:2], out_co_unused};
endmodule

`default_nettype wire
